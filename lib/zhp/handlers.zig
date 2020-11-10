// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const log = std.log;
const web = @import("zhp.zig");
const responses = web.responses;
const Datetime = web.datetime.Datetime;

pub var default_stylesheet = @embedFile("templates/style.css");


pub const ServerErrorHandler = struct {
    const template = @embedFile("templates/error.html");
    server_request: ?*web.ServerRequest = null,
    pub fn dispatch(self: *ServerErrorHandler, request: *web.Request,
                    response: *web.Response) anyerror!void {
        const app = web.Application.instance.?;
        response.status = responses.INTERNAL_SERVER_ERROR;

        // Clear any existing data
        try response.body.resize(0);

        // Split the template on the key
        comptime const key = "{% stacktrace %}";
        comptime const start = mem.indexOf(u8, template, key).?;
        comptime const end = start + key.len;
        //@breakpoint();

        if (app.options.debug) {
            // Send it
            try response.stream.print(template[0..start], .{default_stylesheet});

            // Dump stack trace
            if (self.server_request.?.err) |err| {
                try response.stream.print("error: {}\n", .{@errorName(err)});
            }
            if (@errorReturnTrace()) |trace| {
                try std.debug.writeStackTrace(
                    trace.*,
                    &response.stream,
                    response.allocator,
                    try std.debug.getSelfDebugInfo(),
                    .no_color);
            }

            // Dump request and end of page
            try response.stream.print(template[end..], .{request});
        } else {
            if (@errorReturnTrace()) |trace| {
                const stderr = std.io.getStdErr().writer();
                const held = std.debug.getStderrMutex().acquire();
                defer held.release();

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
        file: ?fs.File = null,
        start: usize = 0,
        end: usize = 0,
        server_request: ?*web.ServerRequest = null,

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
                //log.warn("Static file error: {}", .{err});
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
                try modified.formatHttp(buf));

            // TODO: cache control

            self.end = stat.size;
            var size: usize = stat.size;

            if (request.headers.getOptional("Range")) |range_header| {
                // As per RFC 2616 14.16, if an invalid Range header is specified,
                // the request will be treated as if the header didn't exist.
                // response.status = responses.PARTIAL_CONTENT;
                if (range_header.len > 8 and mem.startsWith(u8, range_header, "bytes=")) {
                    var it = mem.split(range_header[6..], ",");

                    // Only support the first range
                    const range = mem.trim(u8, it.next().?, " ");
                    var tokens = mem.split(range, "-");
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
            var handler = NotFoundHandler{};
            try handler.dispatch(request, response);
        }

    };
}
