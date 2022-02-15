// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const ascii = std.ascii;
const log = std.log;
const web = @import("zhp.zig");
const responses = web.responses;
const Datetime = web.datetime.Datetime;

pub var default_stylesheet = @embedFile("templates/style.css");


pub const IndexHandler = struct {
    pub fn get(self: *IndexHandler, request: *web.Request, response: *web.Response) !void {
        _ = self;
        _ = request;
        try response.stream.writeAll(
            \\No routes are defined
            \\Please add a list of routes in your main zig file.
        );
    }
};


pub const ServerErrorHandler = struct {
    const TemplateContext = struct {
        style: []const u8,
        request: *web.Request,
    };
    const template = web.template.FileTemplate(TemplateContext , "templates/error.html");

    server_request: *web.ServerRequest,

    pub fn dispatch(self: *ServerErrorHandler, request: *web.Request,
                    response: *web.Response) anyerror!void {
        const app = web.Application.instance.?;
        response.status = responses.INTERNAL_SERVER_ERROR;

        // Clear any existing data
        try response.body.resize(0);


        if (app.options.debug) {
            // Split the template on the key
            const context = TemplateContext{.style=default_stylesheet, .request=request};

            inline for (template.sections) |part| {
                if (part.is("stacktrace")) {
                    // Dump stack trace
                    if (self.server_request.err) |err| {
                        try response.stream.print("error: {s}\n", .{err});
                    }
                    if (@errorReturnTrace()) |trace| {
                        try std.debug.writeStackTrace(
                            trace.*,
                            &response.stream,
                            response.allocator,
                            try std.debug.getSelfDebugInfo(),
                            .no_color);
                    }
                } else {
                    try part.render(context, response.stream);
                }
            }
        } else {
            if (@errorReturnTrace()) |trace| {
                const stderr = std.io.getStdErr().writer();
                const held = std.debug.getStderrMutex();
                held.lock();
                defer held.unlock();

                try std.debug.writeStackTrace(
                    trace.*,
                    &stderr,
                    response.allocator,
                    try std.debug.getSelfDebugInfo(),
                    std.debug.detectTTYConfig());
            }

            try response.stream.writeAll("<h1>Server Error</h1>");
        }
    }

};

pub const NotFoundHandler = struct {
    const template = @embedFile("templates/not-found.html");
    pub fn dispatch(self: *NotFoundHandler, request: *web.Request,
                    response: *web.Response) !void {
        _ = self;
        _ = request;
        response.status = responses.NOT_FOUND;
        try response.stream.print(template, .{default_stylesheet});
    }

};


pub fn StaticFileHandler(comptime static_url: []const u8,
                         comptime static_root: []const u8) type {
    if (!fs.path.isAbsolute(static_url)) {
        @compileError("The static url must be absolute");
    }
    // TODO: Should the root be checked if it exists?
    return  struct {
        const Self = @This();
        //handler: web.RequestHandler,
        file: ?std.fs.File = null,
        start: usize = 0,
        end: usize = 0,
        server_request: *web.ServerRequest,

        pub fn get(self: *Self, request: *web.Request,
                   response: *web.Response) !void {
            const allocator = response.allocator;
            const mimetypes = &web.mimetypes.instance.?;

            // Determine path relative to the url root
            const rel_path = try fs.path.relative(
                allocator, static_url, request.path);

            // Cannot be outside the root folder
            if (rel_path.len == 0 or rel_path[0] == '.') {
                return self.renderNotFound(request, response);
            }

            const full_path = try fs.path.join(allocator, &[_][]const u8{
                static_root, rel_path
            });

            const file = fs.cwd().openFile(full_path, .{.read=true}) catch |err| {
                // TODO: Handle debug page
                log.warn("Static file error: {}", .{err});
                return self.renderNotFound(request, response);
            };
            errdefer file.close();

            // Get file info
            const stat = try file.stat();
            var modified = Datetime.fromModifiedTime(stat.mtime);

            // If the file was not modified, return 304
            if (self.checkNotModified(request, modified)) {
                response.status = web.responses.NOT_MODIFIED;
                file.close();
                return;
            }

            try response.headers.append("Accept-Ranges", "bytes");

            // Set etag header
            if (self.getETagHeader()) |etag| {
                try response.headers.append("ETag", etag);
            }

            // Set last modified time for caching purposes
            // NOTE: The modified result doesn't need freed since the response handles that
            var buf = try response.allocator.alloc(u8, 32);
            try response.headers.append("Last-Modified",
                try modified.formatHttpBuf(buf));

            // TODO: cache control

            self.end = stat.size;
            var size: usize = stat.size;

            if (request.headers.getOptional("Range")) |range_header| {
                // As per RFC 2616 14.16, if an invalid Range header is specified,
                // the request will be treated as if the header didn't exist.
                // response.status = responses.PARTIAL_CONTENT;
                if (range_header.len > 8 and mem.startsWith(u8, range_header, "bytes=")) {
                    var it = mem.split(u8, range_header[6..], ",");

                    // Only support the first range
                    const range = mem.trim(u8, it.next().?, " ");
                    var tokens = mem.split(u8, range, "-");
                    var range_end: ?[]const u8 = null;

                    if (range[0] == '-') {
                        range_end = tokens.next().?; // First one never fails
                    } else {
                        const range_start = tokens.next().?; // First one never fails
                        self.start = std.fmt.parseInt(usize, range_start, 10) catch 0;
                        range_end = tokens.next();
                    }

                    if (range_end) |value| {
                        const end = std.fmt.parseInt(usize, value, 10) catch 0;
                        if (end > self.start) {
                            // Clients sometimes blindly use a large range to limit their
                            // download size; cap the endpoint at the actual file size.
                            self.end = std.math.min(end, size);
                        }
                    }

                    if (self.start >= size or self.end <= self.start) {
                        // A byte-range-spec is invalid if the last-byte-pos value is present
                        // and less than the first-byte-pos.
                        // https://tools.ietf.org/html/rfc7233#section-2.1
                        response.status = web.responses.REQUESTED_RANGE_NOT_SATISFIABLE;
                        try response.headers.append("Content-Type", "text/plain");
                        try response.headers.append("Content-Range",
                            try std.fmt.allocPrint(allocator, "bytes */{}", .{size}));
                        file.close();
                        return;
                    }

                    // Determine the actual size
                    size = self.end - self.start;

                    if (size != stat.size) {
                        // If it's not the full file  se it as a partial response
                        response.status = web.responses.PARTIAL_CONTENT;
                        try response.headers.append("Content-Range",
                            try std.fmt.allocPrint(allocator, "bytes {}-{}/{}", .{
                                self.start, self.end, size}));
                    }
                }
            }

            // Try to get the content type
            const content_type = mimetypes.getTypeFromFilename(full_path)
                orelse "application/octet-stream";
            try response.headers.append("Content-Type", content_type);
            try response.headers.append("Content-Length",
                try std.fmt.allocPrint(allocator, "{}", .{size}));
            self.file = file;
            response.send_stream = true;
        }

        // Return true if not modified and a 304 can be returned
        pub fn checkNotModified(self: *Self, request: *web.Request, mtime: Datetime) bool {
            // If client sent If-None-Match, use it, ignore If-Modified-Since
            // See https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/ETag
            if (request.headers.getOptional("If-None-Match")) |etag| {
                return self.checkETagHeader(etag);
            }

            // Check if the file was modified since the header
            // See https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/If-Modified-Since
            const v = request.headers.getDefault("If-Modified-Since", "");
            const since = Datetime.parseModifiedSince(v) catch return false;
            return since.gte(mtime);
        }

        // Get a hash of the file
        pub fn getETagHeader(self: *Self) ?[]const u8 {
            _ = self;
            // TODO: This
            return null;
        }

        pub fn checkETagHeader(self: *Self, etag: []const u8) bool {
            // TODO: Support other formats
            if (self.getETagHeader()) |tag| {
                return mem.eql(u8, tag, etag);
            }
            return false;
        }

        // Stream the file
        pub fn stream(self: *Self, io: *web.IOStream) !usize {
            std.debug.assert(self.end > self.start);
            const total_wrote = self.end - self.start;
            var bytes_left: usize = total_wrote;
            if (self.file) |file| {
                defer file.close();

                // Jump to requested range
                if (self.start > 0) {
                    try file.seekTo(self.start);
                }

                // Send it
                var reader = file.reader();
                try io.flush();
                while (bytes_left > 0) {
                    // Read into buffer
                    const end = std.math.min(bytes_left, io.out_buffer.len);
                    const n = try reader.read(io.out_buffer[0..end]);
                    if (n == 0) break; // Unexpected EOF
                    bytes_left -= n;
                    try io.flushBuffered(n);
                }
            }
            return total_wrote - bytes_left;
        }

        pub fn renderNotFound(self: *Self, request: *web.Request, response: *web.Response) !void {
            _ = self;
            var handler = NotFoundHandler{};
            try handler.dispatch(request, response);
        }

    };
}


/// Handles a websocket connection
/// See https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers
pub fn WebsocketHandler(comptime Protocol: type) type {
    return struct {
        const Self = @This();

        // The app will allocate this in the response's allocator buffer
        accept_key: [28]u8 = undefined,
        server_request: *web.ServerRequest,

        pub fn get(self: *Self, request: *web.Request, response: *web.Response) !void {
            return self.doHandshake(request, response) catch |err| switch (err) {
                error.BadRequest => self.respondError(web.responses.BAD_REQUEST),
                error.Forbidden => self.respondError(web.responses.FORBIDDEN),
                error.UpgradeRequired => self.respondError(web.responses.UPGRADE_REQUIRED),
                else => err,
            };
        }

        fn respondError(self: *Self, status: web.responses.Status) void {
            self.server_request.request.read_finished = true; // Skip reading the body
            self.server_request.response.disconnect_on_finish = true;
            self.server_request.response.status = status;
        }

        fn doHandshake(self: *Self, request: *web.Request, response: *web.Response) !void {
            // Check upgrade headers
            try self.checkUpgradeHeaders(request);

            // Make sure this is not a cross origin request
            if (!self.checkOrigin(request)) {
                return error.Forbidden; // Cross origin websockets are forbidden
            }

            // Check websocket version
            const version = try self.getWebsocketVersion(request);
            switch (version) {
                7, 8, 13 => {},
                else => {
                    // Unsupported version
                    // Set header to indicate to the client which versions are supported
                    try response.headers.append("Sec-WebSocket-Version", "7, 8, 13");
                    return error.UpgradeRequired;
                }
            }

            // Create the accept key
            const key = try self.getWebsocketAcceptKey(request);

            // At this point the connection is valid so switch to stream mode
            try response.headers.append("Connection", "Upgrade");
            try response.headers.append("Upgrade", "websocket");
            try response.headers.append("Sec-WebSocket-Accept", key);

            // Optionally select a subprotocol
            // The function should set the Sec-WebSocket-Protocol
            // or return BadRequest
            if (@hasDecl(Protocol, "selectProtocol")) {
                try Protocol.selectProtocol(request, response);
            }

            response.send_stream = true;
            response.status = web.responses.SWITCHING_PROTOCOLS;
        }

        fn checkUpgradeHeaders(self: *Self, request: *web.Request) !void {
            _ = self;
            if (!request.headers.eqlIgnoreCase("Upgrade", "websocket")) {
                log.debug("Cannot only upgrade to 'websocket'", .{});
                return error.BadRequest; // Can only upgrade to websocket
            }

            // Some proxies/load balancers will mess with the connection header
            // and browsers also send multiple values here
            const header = request.headers.getDefault("Connection", "");
            var it = std.mem.split(u8, header, ",");
            while (it.next()) |part| {
                const conn = std.mem.trim(u8, part, " ");
                if (ascii.eqlIgnoreCase(conn, "upgrade")) {
                    return;
                }
            }
            // If we didn't find it, give an error
            log.debug("Connection must be 'upgrade'", .{});
            return error.BadRequest; // Connection must be upgrade
        }

        /// As a safety measure make sure the origin header matches the host header
        fn checkOrigin(self: *Self, request: *web.Request) bool {
            _ = self;
            if (@hasDecl(Protocol, "checkOrigin")) {
                return Protocol.checkOrigin(request);
            } else {
                // Version 13 uses "Origin", others use "Sec-Websocket-Origin"
                var origin = web.url.findHost(
                    if (request.headers.getOptional("Origin")) |o| o else
                        request.headers.getDefault("Sec-Websocket-Origin", ""));

                const host = request.headers.getDefault("Host", "");
                if (origin.len == 0 or host.len == 0 or !ascii.eqlIgnoreCase(origin, host)) {
                    log.debug("Cross origin websockets are not allowed ('{s}' != '{s}')", .{
                        origin, host
                    });
                    return false;
                }
                return true;
            }
        }

        fn getWebsocketVersion(self: *Self, request: *web.Request) !u8 {
            _ = self;
            const v = request.headers.getDefault("Sec-WebSocket-Version", "");
            return std.fmt.parseInt(u8, v, 10) catch error.BadRequest;
        }

        fn getWebsocketAcceptKey(self: *Self, request: *web.Request) ![]const u8 {
            const key = request.headers.getDefault("Sec-WebSocket-Key", "");
            if (key.len < 8) {
                // TODO: Must it be a certain length?
                log.debug("Insufficent websocket key length", .{});
                return error.BadRequest;
            }

            var hash = std.crypto.hash.Sha1.init(.{});
            var out: [20]u8 = undefined;
            hash.update(key);
            hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
            hash.final(&out);

            // Encode it
            return std.base64.standard.Encoder.encode(&self.accept_key, &out);
        }

        pub fn stream(self: *Self, io: *web.IOStream) !usize {
            const request = &self.server_request.request;
            const response = &self.server_request.response;

            // Always close
            defer io.close();

            // Flush the request
            try io.flush();

            // Delegate handler
            var protocol = Protocol{
                .websocket = web.Websocket{
                    .request = request,
                    .response = response,
                    .io = io,
                },
            };
            try protocol.connected();
            self.processStream(&protocol) catch |err| {
                protocol.websocket.err = err;
            };
            try protocol.disconnected();
            return 0;
        }

        fn processStream(self: *Self, protocol: *Protocol) !void {
            _ = self;
            const ws = &protocol.websocket;
            while (true) {
                const dataframe = try ws.readDataFrame();
                if (@hasDecl(Protocol, "onDataFrame")) {
                    // Let the user handle it
                    try protocol.onDataFrame(dataframe);
                } else {
                    switch (dataframe.header.opcode) {
                        .Text => try protocol.onMessage(dataframe.data, false),
                        .Binary => try protocol.onMessage(dataframe.data, true),
                        .Ping => {
                            _ = try ws.writeMessage(.Pong, "");
                        },
                        .Pong => {
                            _ = try ws.writeMessage(.Ping, "");
                        },
                        .Close => {
                            try ws.close(1000);
                            break; // Client requsted close
                        },
                        else => return error.UnexpectedOpcode,
                    }
                }
            }
        }

    };
}
