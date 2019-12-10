const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const mem = std.mem;
const math = std.math;
const ascii = std.ascii;
const time = std.time;
const meta = std.meta;
const testing = std.testing;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const re = @import("re/regex.zig").Regex;
const responses = @import("status.zig");
const handlers = @import("handlers.zig");

const HttpHeaders = @import("headers.zig").HttpHeaders;
const HttpStatus = responses.HttpStatus;
const util = @import("util.zig");
const in = util.in;
const IOStream = util.IOStream;


pub const HttpRequest = struct {
    pub const Method = enum {
        Get,
        Put,
        Post,
        Patch,
        //Copy,
        //Move,
        //Lock,
        Head,
        // Mkcol,

        // Trace,
        Delete,
        Options,
        Unknown
    };
    method: Method = .Unknown,

    pub const Version = enum {
        Http1_0,
        Http1_1,
        Unknown
    };
    version: Version = .Unknown,
    path: []const u8 = "",
    content_length: usize = 0,
    _read_finished: bool = false,
    headers: HttpHeaders,

    // Holds path and headers
    buffer: std.Buffer,

    // Holds the rest
    body: std.Buffer,

    pub fn init(allocator: *Allocator) !HttpRequest {
        return HttpRequest{
            .headers = HttpHeaders.init(allocator),
            .buffer = try std.Buffer.initCapacity(allocator, mem.page_size),
            .body = try std.Buffer.initSize(allocator, 0),
        };
    }

    // Based on NGINX's parser
    pub fn parseRequestLine(self: *HttpRequest, stream: *IOStream,
                            timeout: u64, max_size: usize) !usize {
        var cnt: usize = 0;
        var ch: u8 = 0;

        // Skip any leading CRLFs
        while (true) : (cnt += 1) {
            if (cnt == max_size) return error.StreamTooLong; // Too Big
            ch = try stream.readByte();
            // Skip whitespace
            if (ch == '\r' or ch == '\n') continue;
            if ((ch < 'A' or ch > 'Z') and ch != '_' and ch != '-') {
                return error.MalformedHttpRequest;
            }
            break;
        }

        // Read the method
        switch (ch) {
            'G' => { // GET
                inline for("ET") |expected| {
                    ch = try stream.readByte();
                    if (ch != expected) return error.MalformedHttpRequest;
                }
                cnt += 3;
                self.method = Method.Get;
            },
            'P' => {
                ch = try stream.readByte();
                switch (ch) {
                    'U' => {
                        ch = try stream.readByte();
                        if (ch != 'T') return error.MalformedHttpRequest;
                        cnt += 3;
                        self.method = Method.Put;
                    },
                    'O' => {
                        inline for("ST") |expected| {
                            ch = try stream.readByte();
                            if (ch != expected) return error.MalformedHttpRequest;
                        }
                        cnt += 4;
                        self.method = Method.Post;
                    },
                    'A' => {
                        inline for("TCH") |expected| {
                            ch = try stream.readByte();
                            if (ch != expected) return error.MalformedHttpRequest;
                        }
                        cnt += 5;
                        self.method = Method.Patch;
                    },
                    else => return error.MalformedHttpRequest,
                }
            },
            'H' => {
                inline for("EAD") |expected| {
                    ch = try stream.readByte();
                    if (ch != expected) return error.MalformedHttpRequest;
                }
                cnt += 4;
                self.method = Method.Head;
            },
            'D' => {
                inline for("ELETE") |expected| {
                    ch = try stream.readByte();
                    if (ch != expected) return error.MalformedHttpRequest;
                }
                cnt += 6;
                self.method = Method.Delete;
            },
            'O' => {
                inline for("PTIONS") |expected| {
                    ch = try stream.readByte();
                    if (ch != expected) return error.MalformedHttpRequest;
                }
                cnt += 7;
                self.method = Method.Options;

            },
            else => return error.MalformedHttpRequest,
        }

        // Check separator
        ch = try stream.readByte();
        if (ch != ' ') return error.MalformedHttpRequest;
        cnt += 1;

        // TODO: Validate the path
        var buf = &self.buffer;
        var index = buf.len();
        while (true) : (cnt += 1) {
            if (cnt == max_size) return error.StreamTooLong; // Too Big
            ch = try stream.readByte();
            if (ch == ' ') {
                self.path = buf.toSlice()[index..buf.len()];
                break;
            } else if (!ascii.isPrint(ch)) {
                // TODO: @setCold(true);
                return error.MalformedHttpRequest;
            }
            try buf.appendByte(ch);
        }

        if (self.path.len == 0) return error.MalformedHttpRequest;

        // Read version
        inline for("HTTP/1.") |expected| {
            ch = try stream.readByte();
            if (ch != expected) return error.MalformedHttpRequest;
        }
        ch = try stream.readByte();
        self.version = switch (ch) {
            '0' => Version.Http1_0,
            '1' => Version.Http1_1,
            else => return error.UnsupportedHttpVersion,
        };
        cnt += 8;

        // Read to end of the line
        ch = try stream.readByte();
        if (ch == '\r') {
            ch = try stream.readByte();
            cnt += 1;
        }
        if (ch != '\n') return error.MalformedHttpRequest;
        return cnt;
    }


    pub fn parseHeaders(self: *HttpRequest, stream: *IOStream,
                        timeout: u64, max_size: usize) !usize {
        const State = enum {
            KeyStart,
            Key,
            Value,
            ValueStart,
            MaybeEnd,
        };
        var state: State = State.KeyStart;
        var headers = &self.headers;

        // Reuse the request buffer for this
        var buf = &self.buffer;
        var index = buf.len();

        var key: ?[]u8 = null;
        var cnt: usize = 0;
        var last_byte: u8 = '0';

        // Strip any whitespace
        while (true) : (cnt += 1) {
            if (cnt == max_size) return error.HeaderTooLong;
            var ch = try stream.readByte();
            switch (state) {
                .KeyStart => {
                    if (ch == '\r' or ch == '\n') continue;
                    if (ch == ' ' or ch == '\t') {
                        // first header line cannot start with whitespace
                        if (key == null) return error.HttpInputError;
                        state = .ValueStart; // Continuation of multi-line header
                        continue;
                    }
                    state = .Key;
                    try buf.appendByte(ch);
                },
                .Key => {
                    if (ch == ':') {
                        // Empty key
                        if (buf.len() == 0) return error.HttpInputError;
                        state = .ValueStart;
                        key = buf.toSlice()[index..buf.len()];
                        //std.debug.warn("Header '{}'=", key);
                        index = buf.len();
                        continue;
                    }
                    try buf.appendByte(ch);
                },

                // Ignore starting whitespace
                .ValueStart => {
                    if (ch == ' ' or ch == '\t') continue;
                    state = .Value;
                    try buf.appendByte(ch);
                },
                .Value => {
                    if (ch == '\r') continue;
                    if (ch == '\n') {
                        var value = mem.trimRight(u8,
                            buf.toSlice()[index..buf.len()], " \t");
                        index = buf.len();
                        try headers.put(key.?, value);
                        //std.debug.warn("'{}'\n", value);
                        state = .MaybeEnd;
                        continue;
                    }
                    try buf.appendByte(ch);
                },
                .MaybeEnd => {
                    if (ch == '\r') continue;
                    if (ch == '\n') {
                        try self.parseContentLength();
                        return cnt;
                    }
                    state = .KeyStart;
                    try buf.appendByte(ch);
                }
            }
        }
    }

    pub fn parseContentLength(self: *HttpRequest) !void {
        var headers = &self.headers;
        // Read content length
        if (!headers.contains("Content-Length")) {
            self.content_length = 0;
            return;
        }

        if (headers.contains("Transfer-Encoding")) {
            // Response cannot contain both Content-Length and
            // Transfer-Encoding headers.
            // http://tools.ietf.org/html/rfc7230#section-3.3.3
            return error.HttpInputError;
        }
        var content_length_header = try headers.get("Content-Length");

        // Proxies sometimes cause Content-Length headers to get
        // duplicated.  If all the values are identical then we can
        // use them but if they differ it's an error.
        var it = mem.separate(content_length_header, ",");
        while (it.next()) |piece| {
            try headers.put("Content-Length", piece);
            break; // TODO: Just use the first
        }

        self.content_length = std.fmt.parseInt(u32, content_length_header, 10)
            catch return error.HttpInputError;
    }


    pub fn dataReceived(self: *HttpRequest, data: []const u8) !void {
        try self.body.append(data);
    }

    // Callback
    //dataReceived: fn(self: *HttpRequest, data: []const u8) anyerror!void = onDataReceived,

    pub fn deinit(self: *HttpRequest) void {
        self.buffer.deinit();
        self.headers.deinit();
        self.body.deinit();
    }

};


test "parse-request-line" {
    const allocator = std.heap.direct_allocator;
    var stream = IOStream.initStdIo();
    stream.load("GET /foo HTTP/1.1\r\n");
    var request = try HttpRequest.init(allocator);
    var n = try request.parseRequestLine(&stream, 0, 2048);
    testing.expectEqual(request.method, HttpRequest.Method.Get);
    testing.expectEqual(request.version, HttpRequest.Version.Http1_1);
    testing.expectEqualSlices(u8, request.path, "/foo");

    //stream.load("POST CRAP");
    //request = try HttpRequest.init(allocator);
    //testing.expectError(error.MalformedHttpRequest,
    //    request.parseRequestLine(&stream, 0));

//     var line = try HttpRequest.StartLine.parse(a, "GET /foo HTTP/1.1");
//     testing.expect(mem.eql(u8, line.method, "GET"));
//     testing.expect(mem.eql(u8, line.path, "/foo"));
//     testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
//     line = try RequestStartLine.parse("POST / HTTP/1.1");
//     testing.expect(mem.eql(u8, line.method, "POST"));
//     testing.expect(mem.eql(u8, line.path, "/"));
//     testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
//
//     testing.expectError(error.MalformedHttpRequest,
//             RequestStartLine.parse(a, "POST CRAP"));
//     testing.expectError(error.MalformedHttpRequest,
//             RequestStartLine.parse(a, "POST /theform/ HTTP/1.1 DROP ALL TABLES"));
//     testing.expectError(error.UnsupportedHttpVersion,
//             RequestStartLine.parse(a, "POST / HTTP/2.0"));
}

test "parse-request-headers" {
    const allocator = std.heap.direct_allocator;
    var stream = IOStream.initStdIo();
    stream.load(
        \\Host: server
        \\User-Agent: Mozilla/5.0 (X11; Linux x86_64) Gecko/20130501 Firefox/30.0 AppleWebKit/600.00 Chrome/30.0.0000.0 Trident/10.0 Safari/600.00
        \\Cookie: uid=12345678901234567890; __utma=1.1234567890.1234567890.1234567890.1234567890.12; wd=2560x1600
        \\Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
        \\Accept-Language: en-US,en;q=0.5
        \\Connection: keep-alive
        \\
        \\
    );
    var request = try HttpRequest.init(allocator);
    var n = try request.parseHeaders(&stream, 0, 64000);
}


pub const HttpResponse = struct {
    request: *HttpRequest,
    headers: HttpHeaders,
    status: HttpStatus = responses.OK,
    disconnect_on_finish: bool = false,
    chunking_output: bool = false,
    body: std.Buffer,
    stream: std.io.BufferOutStream.Stream = std.io.BufferOutStream.Stream{
        .writeFn = HttpResponse.writeFn
    },
    _write_finished: bool = false,
    _finished: bool = false,

    pub const StartLine = struct {
        version: []const u8,
        code: u8,
        reason: []const u8,

        pub fn parse(allocator: *Allocator, line: []const u8) !StartLine {
            // FIXME: Do this comptime somehow?
            var pattern = try re.compile(allocator, "(HTTP/1\\.[0-9]) ([0-9]+) ([^\\r]*)");
            defer pattern.deinit();
            var match = (try re.captures(&pattern, line))
                orelse return error.MalformedHttpResponse;
            defer match.deinit();

            const code = try std.fmt.parseInt(u8, match.sliceAt(2).?, 10);

            return StartLine{
                .version = match.sliceAt(1).?,
                .code = code,
                .reason = match.sliceAt(3).?,
            };
        }
    };

    // Wri
    pub fn writeFn(out_stream: *std.io.BufferOutStream.Stream, bytes: []const u8) !void {
        const self = @fieldParentPtr(HttpResponse, "stream", out_stream);
        return self.body.append(bytes);
    }


    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
        self.request.deinit();
        self.body.deinit();
    }

};


//
// test "parse-response-line" {
//     const a = std.heap.direct_allocator;
//     var line = try HttpResponse.StartLine.parse(a, "HTTP/1.1 200 OK");
//     testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
//     testing.expect(line.code == 200);
//     testing.expect(mem.eql(u8, line.reason, "OK"));
//
//     testing.expectError(error.MalformedHttpResponse,
//         HttpResponse.StartLine.parse(a, "HTTP/1.1 ABC OK"));
// }



// A single client connection
// if the client requests keep-alive and the server allows
// the connection is reused to process futher requests.
pub const HttpServerConnection = struct {
    application: *Application,
    //buffer: std.heap.FixedBufferAllocator,
    allocator: *Allocator = undefined,
    io: IOStream,
    address: net.Address,
    closed: bool = false,

    // Handles a connection
    pub fn startRequestLoop(self: *HttpServerConnection) !void {
        //self.allocator = &self.buffer.allocator;
        defer self.connectionLost();
        const app = self.application;
        const params = &app.options;
        const stream = &self.io;
        var timer = try time.Timer.start();
        while (true) {
            //self.buffer.reset();
            var buffer: [1024*1024]u8 = undefined;
            self.allocator = &std.heap.FixedBufferAllocator.init(&buffer).allocator;

            //timer.reset();
            var request = self.readRequest() catch |err| switch(err) {
                error.HttpInputError,
                error.HeaderTooLong => {
                    try stream.write("HTTP/1.1 400 Bad Request\r\n\r\n");
                    self.loseConnection();
                    return;
                },
                //error.TimeoutError,
                //error.ConnectionResetByPeer,
                error.EndOfStream => {
                    self.loseConnection();
                    return;
                },
                else => return err,
            };
            //defer request.deinit();
            //std.debug.warn("readRequest: {}ns\n", timer.lap());

            const keep_alive = self.canKeepAlive(request);
            var response = try self.buildResponse(request);
            //std.debug.warn("buildResp: {}ns\n", timer.lap());
            //defer response.deinit();

            var factory = try app.processRequest(self, request, response);
            if (factory != null) {
                self.readBody(request, response) catch |err| switch(err) {
                    error.HttpInputError,
                    error.ImproperlyTerminatedChunk,
                    error.BodyTooLong => {
                        try stream.write("HTTP/1.1 400 Bad Request\r\n\r\n");
                        self.loseConnection();
                        return;
                    },
                    //error.TimeoutError,
                    error.EndOfStream => {
                        self.loseConnection();
                        return;
                    },
                    else => {
                        return err;
                    }
                };
                var handler = try self.buildHandler(factory.?, response);
                //defer handler.deinit();
                handler.execute() catch |err| {
                     var error_handler = try self.buildHandler(
                        app.error_handler, response);
                     //defer error_handler.deinit();
                     try error_handler.execute();

                 };
            }
            try app.processResponse(self, response);
            //std.debug.warn("process: {}ns\n", timer.lap());

            // TODO: Write in chunks
            if (self.closed) return;
            try self.sendResponse(response);
            if (self.closed or !keep_alive) return;
            //std.debug.warn("[{}] {} {} in {}ns\n",
            //    self.address, request.method, request.path,
            //    timer.lap());
        }
    }

    fn buildHandler(self: *HttpServerConnection, factory: Handler,
                    response: *HttpResponse) !*RequestHandler {
        return factory(self.allocator, self.application, response);
    }

    // Read a new request from the stream
    // this does not read the body of the request.
    pub fn readRequest(self: *HttpServerConnection) !*HttpRequest {
        const request = try self.allocator.create(HttpRequest);

        const stream = &self.io;//.file.inStream().stream;
        const params = &self.application.options;
        const timeout = params.header_timeout * 1000; // ms to ns
        request.buffer = try std.Buffer.initCapacity(
            self.allocator, mem.page_size);
        var n = try request.parseRequestLine(stream, timeout, 2048);
        request.headers = HttpHeaders.init(self.allocator);
        n = try request.parseHeaders(stream, timeout, params.max_header_size);
        request.body = try std.Buffer.initSize(self.allocator, 0);

//         const header_data = try self.readUntilDoubleNewline();
//         const result = try self.parseHeaders(header_data);
//         const start_line = try HttpRequest.StartLine.parse(
//            self.allocator, result.first_line);
//         request.* = HttpRequest{
//             .headers = result.headers,
//             .method = start_line.method,
//             .version = start_line.version,
//             .path = start_line.path,
//             .content_length = result.content_length,
//             .body = try std.Buffer.initCapacity(self.allocator,
//                 result.content_length),
//         };
        return request;
    }

    pub fn buildResponse(self: *HttpServerConnection,
                     request: *HttpRequest) !*HttpResponse {
        const response = try self.allocator.create(HttpResponse);
        response.request = request;
        response.headers = HttpHeaders.init(self.allocator);
        response.body = try std.Buffer.initCapacity(
            self.allocator, mem.page_size);
        return response;
    }

    // Read the until we get a \r\n\r\n this is the stop of the headers
    pub fn readUntilDoubleNewline(self: *HttpServerConnection,) ![]u8 {
        const stream = &self.io;//.file.inStream().stream;
        const params = &self.application.options;
        const expiry = params.header_timeout * 1000; // ms to ns

        //var buf = try self.allocator.alloc(u8, params.max_header_size);
        var buf = try std.Buffer.initCapacity(self.allocator, mem.page_size);
        //defer buf.deinit();

        // FIXME: they can just block on readByte
        //var timer = try time.Timer.start();

        var last_byte: u8 = '0';
        var i: usize = 0;
        while (true) : (i += 1) {
            var byte: u8 = try stream.readByte();
            if (byte == '\n' and last_byte == '\n') {
                //std.debug.warn("Read header took {}us", timer.read()/1000);
                return buf.toOwnedSlice();
            } else if (byte == '\r' and last_byte == '\n') {
                // Ignore \r if we just had \n
            } else {
                last_byte = byte;
            }

            if (i == params.max_header_size) {
                return error.HeaderTooLong;
            }

            // FIXME: This is a syscall per byte
            //if (timer.read() >= expiry) return error.TimeoutError;
            try buf.appendByte(byte);
            //std.debug.warn("Loop took {}us\n", timer.lap()/1000);
        }
    }

    const ParseResult = struct {
        first_line: []const u8,
        headers: HttpHeaders,
        content_length: usize,
    };

    pub fn parseHeaders(self: *HttpServerConnection, data: []const u8) !ParseResult {
        const params = &self.application.options;

        var eol: usize = mem.indexOf(u8, data, "\n") orelse 0;
        var headers = try HttpHeaders.parse(self.allocator, data[eol..]);
        if (data[eol-1] == '\r') eol -= 1; // Strip \r

        // Read content length
        var content_length: usize = 0;
        if (headers.contains("Content-Length")) {
            if (headers.contains("Transfer-Encoding")) {
                // Response cannot contain both Content-Length and
                // Transfer-Encoding headers.
                // http://tools.ietf.org/html/rfc7230#section-3.3.3
                return error.HttpInputError;
            }
            var content_length_header = try headers.get("Content-Length");
            if (mem.indexOf(u8, content_length_header, ",") != null) {
                // Proxies sometimes cause Content-Length headers to get
                // duplicated.  If all the values are identical then we can
                // use them but if they differ it's an error.
                var it = mem.separate(content_length_header, ",");
                while (it.next()) |piece| {
                    try headers.put("Content-Length", piece);
                    break;
                }

            }

            content_length = std.fmt.parseInt(u32, content_length_header, 10)
                catch return error.HttpInputError;
            if (content_length > params.max_body_size) {
                return error.BodyTooLong;
            }
        }

        return ParseResult{
            .first_line = data[0..eol],
            .headers = headers,
            .content_length = content_length
        };
    }

    fn readBody(self: *HttpServerConnection, request: *HttpRequest,
                response: *HttpResponse) !void {
        const params = &self.application.options;
        const content_length = request.content_length;
        var headers = &request.headers;
        const code = response.status.code;

        if (request.content_length > params.max_body_size) {
            //std.debug.warn("Content length {} is too long {}", .{
            //    request.content_length, params.max_body_size});
            return error.BodyTooLong;
        }

        if (headers.eqlIgnoreCase("Expect", "100-continue")) {
            response.status = responses.CONTINUE;
        }

        if (code == 204) {
            // This response code is not allowed to have a non-empty body,
            // and has an implicit length of zero instead of read-until-close.
            // http://www.w3.org/Protocols/rfc2616/rfc2616-sec4.html#sec4.3
            if (headers.contains("Transfer-Encoding") or !(content_length == 0)) {
                //std.debug.warn(
                //    "Response with code {} should not have a body", .{code});
                return error.HttpInputError;
            }
            return;
        }

        if (content_length > 0) {
            try self.readFixedBody(request);
        } else if (headers.eqlIgnoreCase("Transfer-Encoding", "chunked")) {
            try self.readChunkedBody(request);
        } // else if (self.is_client) {
        //    return self.readBodyUntilClose(request);
        //}
        request._read_finished = true;
    }

    fn readFixedBody(self: *HttpServerConnection, request: *HttpRequest) !void {
        const params = &self.application.options;
        var buf = try std.Buffer.initSize(self.allocator, params.chunk_size);
        defer buf.deinit();

        const stream = &self.io;//&self.io.file.inStream().stream;
        var left = request.content_length;
        const expiry = params.body_timeout * 1000; // ms to ns
        //var timer = try time.Timer.start();

        while (left > 0) {
            try stream.readAllBuffer(
                &buf, math.min(params.chunk_size, left));

            left -= @intCast(u32, buf.len());
            try request.dataReceived(buf.toSlice());

            // FIXME: This is a syscall per byte
            //if (timer.read() >= expiry) return error.TimeoutError;
        }
    }

    fn readChunkedBody(self: *HttpServerConnection, request: *HttpRequest) !void {
        // TODO: "chunk extensions" http://tools.ietf.org/html/rfc2616#section-3.6.1
        const stream = &self.io;//&self.io.file.inStream().stream;
        var total_size: u32 = 0;

        const params = &self.application.options;
        const expiry = params.body_timeout * 1000; // ms to ns

        const chunk_size = params.chunk_size;
        var buf = try std.Buffer.initCapacity(self.allocator, chunk_size);
        defer buf.deinit();

        //var timer = try time.Timer.start();
        while (true) {
            try stream.readUntilDelimiterBuffer(&buf, '\n', 64);
            const chunk_len = try std.fmt.parseInt(
                u32, mem.trim(u8, buf.toSlice(), " \r\n"), 16);
            if (chunk_len == 0) {
                try stream.readUntilDelimiterBuffer(&buf, '\n', 2);
                if (!mem.eql(u8, buf.toSlice(), "\r\n")) {
                    // Improperly terminated chunked request
                    return error.ImproperlyTerminatedChunk;
                }
                return;
            }

            total_size += chunk_len;
            if (total_size > params.max_body_size) {
                // Chunked body too large
                return error.BodyTooLong;
            }

            var bytes_to_read: u32 = chunk_len;
            while (bytes_to_read > 0) {
                try stream.readAllBuffer
                    (&buf, math.min(bytes_to_read, chunk_size));
                bytes_to_read -= @intCast(u32, buf.len());
                try request.dataReceived(buf.toSlice());
                    // FIXME: This is a syscall per byte
                //if (timer.read() >= expiry) return error.TimeoutError;
            }

            // Chunk ends with \r\n
            try stream.readUntilDelimiterBuffer(&buf, '\n', 2);
            if (!mem.eql(u8, buf.toSlice(), "\r\n")) {
                return error.ImproperlyTerminatedChunk;
            }
            //if (timer.read() >= expiry) return error.TimeoutError;
        }
    }

    fn readBodyUntilClose(self: *HttpServerConnection, request: *HttpRequest) !void {
        const stream = &self.io.file.inStream().stream;
        const body = try stream.readAllAlloc(
            self.allocator, self.application.options.max_body_size);
        try request.dataReceived(body);
    }

    fn canKeepAlive(self: *HttpServerConnection, request: *HttpRequest) bool {
        if (self.application.options.no_keep_alive) {
            return false;
        }
        var headers = request.headers;
        if (request.version == .Http1_1) {
            return !headers.eqlIgnoreCase("Connection", "close");
        } else if (headers.contains("Content-Length")
                    or headers.eqlIgnoreCase("Transfer-Encoding", "chunked")
                    or request.method == .Head or request.method == .Get){
            return headers.eqlIgnoreCase("Connection", "keep-alive");
        }
        return false;
    }

    // Write the request
    pub fn sendResponse(self: *HttpServerConnection, response: *HttpResponse) !void {
        const stream = &self.io;//&self.io.file.outStream().stream;
        const request = response.request;

        // Finalize any headers
        if (request.version == .Http1_1 and response.disconnect_on_finish) {
            try response.headers.put("Connection", "close");
        }

        if (request.version == .Http1_0
                and request.headers.eqlIgnoreCase("Connection", "keep-alive")) {
            try response.headers.put("Connection", "keep-alive");
        }

        if (response.chunking_output) {
            try response.headers.put("Transfer-Encoding", "chunked");
        }

        // Write status line
        try stream.print("HTTP/1.1 {} {}\r\n", .{
            response.status.code,
            response.status.phrase
        });

        // Write headers
        var it = response.headers.iterator();

        while (it.next()) |header| {
            try stream.print("{}: {}\r\n", .{header.key, header.value});
        }

        // Send content length if missing otherwise the client hangs reading
        if (!response.headers.contains("Content-Length")) {
            try stream.print("Content-Length: {}\n\n", .{response.body.len()});
        }

        // Write body
        if (response.chunking_output) {
            //var start = 0;
            // TODO

            try stream.write("0\r\n\r\n");
        } else if (response.body.len() > 0) {
            try stream.write(response.body.toSlice());
        }

        // Flush anything left
        try stream.flush();

        // Finish
        // If the app finished the request while we're still reading,
        // divert any remaining data away from the delegate and
        // close the connection when we're done sending our response.
        // Closing the connection is the only way to avoid reading the
        // whole input body.
        if (!request._read_finished) {
            self.loseConnection();
        }
    }

    pub fn loseConnection(self: *HttpServerConnection) void {
        self.io.close();
        self.closed = true;
    }

    pub fn connectionLost(self: *HttpServerConnection) void {
        if (!self.closed) {
            self.loseConnection();
        }
    }

};


pub const RequestHandler = struct {
    allocator: *Allocator,
    application: *Application,
    request: *HttpRequest,
    response: *HttpResponse,

    const request_handler = fn(self: *RequestHandler) anyerror!void;

    pub fn execute(self: *RequestHandler) !void {
        return self.dispatch(self);
    }

    // Dispatches to the other handlers
    fn default_dispatch(self: *RequestHandler) !void {
        const handler = switch (self.request.method) {
            .Get => self.get,
            .Post => self.post,
            .Put => self.put,
            .Patch => self.patch,
            .Head => self.head,
            .Delete => self.delete,
            .Options => self.options,
            else => _unimplemented
        };
        return handler(self);
    }

    // Generic dispatch to handle
    dispatch: request_handler = default_dispatch,

    // Default handlers
    head: request_handler = _unimplemented,
    get: request_handler = _unimplemented,
    post: request_handler = _unimplemented,
    delete: request_handler = _unimplemented,
    patch: request_handler = _unimplemented,
    put: request_handler = _unimplemented,
    options: request_handler = _unimplemented,

    // Deinit
    pub fn deinit(self: *RequestHandler) void {
        self.destroy(self);
    }
    destroy: fn(self: *RequestHandler) void,

};

// Default handler request implementation
fn _unimplemented(self: *RequestHandler) !void {
    self.response.status = responses.METHOD_NOT_ALLOWED;
    return error.HttpError;
}


// A handler is simply a a factory function which returns a RequestHandler
pub const Handler = fn(allocator: *Allocator, app: *Application,
                       response: *HttpResponse) anyerror!*RequestHandler;

// This seems a bit excessive....
pub fn createHandler(comptime T: type) Handler {
    const RequestDispatcher = struct {
        const Self  = @This();

        pub fn create(allocator: *Allocator, app: *Application,
                      response: *HttpResponse) !*RequestHandler {
            const self = try allocator.create(T); // Create a dangling pointer lol
            self.* = T{
                .handler = RequestHandler{
                    .application = app,
                    .allocator = allocator,
                    .request = response.request,
                    .response = response,
                    .dispatch = if (@hasDecl(T, "dispatch"))
                        Self.dispatch else RequestHandler.default_dispatch,
                    .head = if (@hasDecl(T, "head"))
                        Self.head else _unimplemented,
                    .get = if (@hasDecl(T, "get"))
                        Self.get else _unimplemented,
                    .post = if (@hasDecl(T, "post"))
                        Self.post else _unimplemented,
                    .delete = if (@hasDecl(T, "delete"))
                        Self.delete else _unimplemented,
                    .patch = if (@hasDecl(T, "patch"))
                        Self.patch else _unimplemented,
                    .put = if (@hasDecl(T, "put"))
                        Self.put else _unimplemented,
                    .options = if (@hasDecl(T, "options"))
                        Self.options else _unimplemented,
                    .destroy = Self.destroy,
                },
            };
            return &self.handler;
        }

        pub fn dispatch(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.dispatch(req.response);
        }

        pub fn head(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.head(req.response);
        }

        pub fn get(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.get(req.response);
        }

        pub fn post(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.post(req.response);
        }

        pub fn delete(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.delete(req.response);
        }

        pub fn patch(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.patch(req.response);
        }

        pub fn put(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.put(req.response);
        }

        pub fn options(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.options(req.response);
        }

        pub fn destroy(req: *RequestHandler) void {
            const handler = @fieldParentPtr(T, "handler", req);
            req.allocator.destroy(handler);
        }
    };

    return RequestDispatcher.create;
}

pub const Route = struct {
    name: []const u8, // Reverse url name
    path: []const u8, // Path pattern
    handler: Handler,

    // Create a route for the handler
    pub fn create(name: []const u8, path: []const u8, comptime T: type) Route {
        return Route{.name=name, .path=path, .handler=createHandler(T)};
    }
};


pub const Router = struct {
    routes: []Route,

    pub fn init(routes: []Route) Router {
        return Router{
            .routes = routes,
        };
    }
    pub fn findHandler(self: *Router, request: *HttpRequest) !Handler {
        for (self.routes) |route| {
            if (mem.eql(u8, route.path, request.path)) {
                return route.handler;
            }
        }
        return error.NotFound;

    }

    pub fn reverseUrl(self: *Router, name: []const u8, args: ...) ![]const u8 {
        for (self.routes) |route| {
            if (mem.eql(u8, route.name, name)) {
                return route.path;
            }
        }
        return error.NotFound;
    }

};

const Middleware = struct {
    // Process the request and return the reponse
    processRequest: fn(self: *Middleware, request: *HttpRequest, response: *HttpResponse) anyerror!bool,
    processResponse: fn(self: *Middleware, response: *HttpResponse) anyerror!void,
};


pub const Application = struct {
    allocator: *Allocator,
    router: Router,
    server: net.StreamServer,
    lock: std.Mutex,
    const ConnectionMap = std.AutoHashMap(*HttpServerConnection, *@Frame(startServing));

    pub const Connection = struct {
        // This is the max memory allowed per request
        buffer: [1024*1024]u8 = undefined,
        file: fs.File,
        address: net.Address,
        server_conn: *HttpServerConnection,
        frame: *@Frame(startServing),
    };

    connections: ConnectionMap,
    const ConnectionPool = std.TailQueue(*Connection);
    const FramesList = std.ArrayList(*@Frame(startServing));
    active_connections: ConnectionPool,
    free_connections: ConnectionPool,
    frames: FramesList,

    middleware: std.ArrayList(*Middleware),


    // ------------------------------------------------------------------------
    // Default handlers
    // ------------------------------------------------------------------------
    error_handler: Handler = createHandler(handlers.ServerErrorHandler),
    not_found_handler: Handler = createHandler(handlers.NotFoundHandler),

    // ------------------------------------------------------------------------
    // Server setup
    // ------------------------------------------------------------------------
    pub const Options = struct {
        // Routes
        routes: []Route,
        allocator: *Allocator = std.heap.page_allocator,
        xheaders: bool = false,
        no_keep_alive: bool = false,
        protocol: []const u8 = "HTTP/1.1",
        decompress_request: bool = false,
        chunk_size: u32 = 65536,
        max_header_size: u32 = 65536,

        // Timeout in millis
        idle_connection_timeout: u32 = 300 * time.ms_per_s,  // 5 min
        header_timeout: u32 = 300 * time.ms_per_s,  // 5 min
        body_timeout: u32 = 900 * time.ms_per_s, // 15 minn
        max_body_size: u64 = 100*1000*1000, // 100 MB

        // List of trusted downstream (ie proxy) servers
        trusted_downstream: ?[][]const u8 = null,
        server_options: net.StreamServer.Options = net.StreamServer.Options{},
    };
    options: Options,

    // ------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------
    pub fn init(options: Options) Application {
        const allocator = options.allocator;
        return Application{
            .allocator = allocator,
            .router = Router.init(options.routes),
            .options = options,
            .server = net.StreamServer.init(options.server_options),
            .lock = std.Mutex.init(),
            .connections = ConnectionMap.init(allocator),
            .frames = FramesList.init(allocator),
            .active_connections = ConnectionPool.init(),
            .free_connections = ConnectionPool.init(),
            .middleware = std.ArrayList(*Middleware).init(allocator),
        };
    }

    pub fn listen(self: *Application, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp4(address, port);
        try self.server.listen(addr);
        std.debug.warn("Listing on {}:{}\n", .{address, port});
    }

    // Start serving requests For each incoming connection.
    // The connections may be kept alive to handle more than one request.
    pub fn start(self: *Application) !void {
        const allocator = self.allocator;

        while (true) {
            const conn = try self.server.accept();
//             var conn: *ConnectionPool.Node = undefined;
//             const lock = self.lock.acquire();
//                 if (self.free_connections.pop()) |c| {
//                     conn = c;
//                 } else {
//                     const c = try allocator.create(Connection);
//                     c.server_conn = try allocator.create(HttpServerConnection);
//                     c.frame = try allocator.create(@Frame(startServing));
//                     conn = try self.active_connections.createNode(c, allocator);
//                 }
//             self.active_connections.append(conn);
//             lock.release();
//
//             conn.data.address = client.address;
//             conn.data.file = client.file;
            const server_conn = try allocator.create(HttpServerConnection);
            const frame = try allocator.create(@Frame(Application.startServing));
            //try self.frames.append(frame);
            var e = try self.connections.put(server_conn, frame);

            // Spawn the async stuff
            if (comptime std.io.is_async) {
                frame.* = async self.startServing(conn, server_conn);
            } else {
                try self.startServing(conn, server_conn);
            }
        }
    }

    // ------------------------------------------------------------------------
    // Handling
    // ------------------------------------------------------------------------
    fn startServing(self: *Application, conn: net.StreamServer.Connection,
                    server_conn: *HttpServerConnection) !void {
        //const conn = storage.data;

        // Bulild the connection
        server_conn.* = HttpServerConnection{
            .io = IOStream.init(conn.file),
            //.buffer = std.heap.FixedBufferAllocator.init(&buffer),
            .address = conn.address,
            .application = self,
        };

        // Send it
        server_conn.startRequestLoop() catch |err| {
            //std.debug.warn("{} {}\n", .{conn.address, err});
            return err; // TODO: Catch and log
        };

         // Free the connection and set the frame to be cleaned up later
         var lock = self.lock.acquire();
         //self.free_connections.append(storage);
         //self.active_connections.remove(storage);
         lock.release();
    }

    // ------------------------------------------------------------------------
    // Routing and Middleware
    // ------------------------------------------------------------------------
    pub fn processRequest(self: *Application, server_conn: *HttpServerConnection,
                        request: *HttpRequest, response: *HttpResponse) !?Handler {
        var it = self.middleware.iterator();
        while (it.next()) |middleware| {
            var done = try middleware.processRequest(
                middleware, request, response);
            if (done) return null;
        }

        const handler = self.router.findHandler(request) catch |err| {
            if (err == error.NotFound) {
                return self.not_found_handler;
            } else {
                return self.error_handler;
            }
        };

        // Set default content type
        try response.headers.put("Content-Type", "text/html; charset=UTF-8");

        return handler;
    }

    pub fn processResponse(self: *Application, server_conn: *HttpServerConnection,
                           response: *HttpResponse) !void {

        // Add server headers
        try response.headers.put("Server", "ZHP/0.1");
        try response.headers.put("Date",
            try HttpHeaders.formatDate(server_conn.allocator, time.milliTimestamp()));

        var it = self.middleware.iterator();
        while (it.next()) |middleware| {
            try middleware.processResponse(middleware, response);
        }

        //std.debug.warn("[{}] {} {} {}\n", server_conn.address,
        //    response.request.method, response.request.path,
        //    response.status.code);
    }

    pub fn deinit(self: *Application) void {
        self.server.deinit();
        //self.connections.deinit();
        self.middleware.deinit();
    }

};
