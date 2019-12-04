// on youtube
const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const mem = std.mem;
const math = std.math;
const ascii = std.ascii;
const time = std.time;
const meta = std.meta;

const Allocator = std.mem.Allocator;

const re = @import("re/regex.zig").Regex;
const responses = @import("status.zig");
const handlers = @import("handlers.zig");

const HttpHeaders = @import("headers.zig").HttpHeaders;
const HttpStatus = responses.HttpStatus;
const util = @import("util.zig");
const in = util.in;
const IOStream = util.IOStream;

const STACK_SIZE = 1*1024*1024;
const MAX_HANDLER_SIZE = 1*1024*1024;

pub const HttpRequest = struct {
    headers: HttpHeaders,
    body: std.Buffer,
    method: []const u8,
    path: []const u8,
    version: []const u8,
    content_length: usize = 0,
    _read_finished: bool = false,

    pub const StartLine = struct {
        method: []const u8,
        path: []const u8,
        version: []const u8,

        pub fn parse(allocator: *Allocator, line: []const u8) !StartLine {
            var it = mem.separate(line, " ");
            const method = it.next() orelse return error.MalformedHttpRequest;
            const path = it.next() orelse return error.MalformedHttpRequest;
            const version = it.next() orelse return error.MalformedHttpRequest;
            if (it.next() != null) return error.MalformedHttpRequest;
            var pattern = try re.compile(allocator, "^HTTP/1\\.[0-9]$");
            defer pattern.deinit();
            if (!try re.match(&pattern, version)) {
                return error.UnsupportedHttpVersion;
            }

            return StartLine{
                .method = method,
                .path = path,
                .version = version
            };
        }

    };

    pub fn dataReceived(self: *HttpRequest, data: []const u8) !void {
        try self.body.append(data);
    }

    // Callback
    //dataReceived: fn(self: *HttpRequest, data: []const u8) anyerror!void = onDataReceived,

    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
        self.body.deinit();
    }

};


test "parse-request-line" {
    const a = std.heap.direct_allocator;
    var line = try HttpRequest.StartLine.parse(a, "GET /foo HTTP/1.1");
    testing.expect(mem.eql(u8, line.method, "GET"));
    testing.expect(mem.eql(u8, line.path, "/foo"));
    testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
    line = try RequestStartLine.parse("POST / HTTP/1.1");
    testing.expect(mem.eql(u8, line.method, "POST"));
    testing.expect(mem.eql(u8, line.path, "/"));
    testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));

    testing.expectError(error.MalformedHttpRequest,
            RequestStartLine.parse(a, "POST CRAP"));
    testing.expectError(error.MalformedHttpRequest,
            RequestStartLine.parse(a, "POST /theform/ HTTP/1.1 DROP ALL TABLES"));
    testing.expectError(error.UnsupportedHttpVersion,
            RequestStartLine.parse(a, "POST / HTTP/2.0"));
}


pub const HttpResponse = struct {
    request: *HttpRequest,
    headers: HttpHeaders,
    status: HttpStatus = responses.OK,
    disconnect_on_finish: bool = true,
    chunking_output: bool = false,
    body: std.Buffer,
    stream: std.io.BufferOutStream.Stream,
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
    }

};



test "parse-response-line" {
    const a = std.heap.direct_allocator;
    var line = try HttpResponse.StartLine.parse(a, "HTTP/1.1 200 OK");
    testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
    testing.expect(line.code == 200);
    testing.expect(mem.eql(u8, line.reason, "OK"));

    testing.expectError(error.MalformedHttpResponse,
        Response.StartLine.parse(a, "HTTP/1.1 ABC OK"));
}



// A single client connection
// if the client requests keep-alive and the server allows
// the connection is reused to process futher requests.
pub const HttpServerConnection = struct {
    application: *Application,
    allocator: *Allocator,
    file: fs.File,
    io: IOStream,
    address: net.Address,
    closed: bool = false,
    on_close: fn(app: *Application, server_conn: *HttpServerConnection) void,
    frame: @Frame(startRequestLoop),

    // Handles a connection
    pub async fn startRequestLoop(self: *HttpServerConnection) !void {

        // Setup IO Stream
        self.io.prepare();

        defer self.connectionLost();
        const app = self.application;
        const params = app.options;
        var buf: [MAX_HANDLER_SIZE]u8 = undefined;
        const allocator = &std.heap.FixedBufferAllocator.init(buf[0..]).allocator;
        const stream = &self.io.out.stream;
        var timer = try time.Timer.start();
        while (true) {
            timer.reset();
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
                else => {
                    return err;
                }
            };
            defer request.deinit();
            //std.debug.warn("readRequest: {}us\n", timer.read()/1000);

            const keep_alive = self.canKeepAlive(&request);
            var response = HttpResponse{
                .request = &request,
                .headers = HttpHeaders.init(allocator),
                .body = try std.Buffer.initSize(allocator,0),
                //.connection = self,
                .disconnect_on_finish = keep_alive,
                .stream = std.io.BufferOutStream.Stream{
                    .writeFn = HttpResponse.writeFn},
            };
            defer response.deinit();

            var factory = try app.processRequest(self, &request, &response);
            if (factory != null) {
                self.readBody(&request, &response) catch |err| switch(err) {
                    error.HttpInputError, error.ImproperlyTerminatedChunk,
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

                var handler = try self.buildHandler(
                    allocator, factory.?, &response);
                handler.execute() catch |err| {
                     var error_handler = try self.buildHandler(
                        allocator, app.error_handler, &response);

                     try error_handler.execute();
                 };
            }
            try app.processResponse(self, &response);

            // TODO: Write in chunks
            if (self.closed) return;
            try self.sendResponse(&response);
            if (self.closed or !keep_alive) return;
            //std.debug.warn("finishRequest: {}\n", timer.read()/1000);
        }
    }

    fn buildHandler(self: *HttpServerConnection, allocator: *Allocator,
                    factory: Handler, response: *HttpResponse) !*RequestHandler {
        return factory(allocator, self.application, response);
    }

    // Read a new request from the stream
    // this does not read the body of the request.
    fn readRequest(self: *HttpServerConnection) !HttpRequest {
        const header_data = try self.readUntilDoubleNewline();
        var result = try self.parseHeaders(header_data);
        var start_line = try HttpRequest.StartLine.parse(
            self.allocator, result.first_line);
        return HttpRequest{
            .headers = result.headers,
            .method = start_line.method,
            .version = start_line.version,
            .path = start_line.path,
            .content_length = result.content_length,
            .body = try std.Buffer.initSize(self.allocator,
                result.content_length),
        };
    }

    // Read the until we get a \r\n\r\n this is the stop of the headers
    fn readUntilDoubleNewline(self: *HttpServerConnection) ![]u8 {
        const stream = &self.io.in.stream;
        const params = self.application.options;
        const expiry = params.header_timeout * 1000; // ms to ns

        var buf = try std.Buffer.initCapacity(self.allocator, mem.page_size);
        defer buf.deinit();

        // FIXME: they can just block on readByte
        //var timer = try time.Timer.start();

        var last_byte: ?u8 = null;
        while (true) {
            var byte: u8 = try stream.readByte();
            if (byte == '\n' and last_byte != null and last_byte.?== '\n') {
                //std.debug.warn("Read header took {}us", timer.read()/1000);
                return buf.toOwnedSlice();
            } else if (byte == '\r' and last_byte != null and last_byte.? == '\n') {
                // Ignore \r if we just had \n
            } else {
                last_byte = byte;
            }

            if (buf.len() == params.max_header_size) {
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

    fn parseHeaders(self: *HttpServerConnection, data: []const u8) !ParseResult {
        const params = self.application.options;

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
        const params = self.application.options;
        const content_length = request.content_length;
        var headers = request.headers;
        const code = response.status.code;

        if (headers.eqlIgnoreCase("Expect", "100-continue")) {
            response.status = responses.CONTINUE;
        }

        if (code == 204) {
            // This response code is not allowed to have a non-empty body,
            // and has an implicit length of zero instead of read-until-close.
            // http://www.w3.org/Protocols/rfc2616/rfc2616-sec4.html#sec4.3
            if (headers.contains("Transfer-Encoding") or !(content_length == 0)) {
                std.debug.warn(
                    "Response with code {} should not have a body", code);
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
        const params = self.application.options;
        var buf = try std.Buffer.initSize(self.allocator, params.chunk_size);
        defer buf.deinit();

        const stream = &self.io.in.stream;
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
        const stream = &self.io.in.stream;
        var total_size: u32 = 0;

        const params = self.application.options;
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
        const stream = &self.io.in.stream;
        const body = try stream.readAllAlloc(
            self.allocator, self.application.options.max_body_size);
        try request.dataReceived(body);
    }

    fn canKeepAlive(self: *HttpServerConnection, request: *HttpRequest) bool {
        if (self.application.options.no_keep_alive) {
            return false;
        }
        var headers = request.headers;
        if (mem.eql(u8, request.version, "HTTP/1.1")) {
            return !headers.eqlIgnoreCase("Connection", "close");
        } else if (headers.contains("Content-Length")
                    or headers.eqlIgnoreCase("Transfer-Encoding", "chunked")
                    or in(u8, request.method, "HEAD", "GET")){
            return headers.eqlIgnoreCase("Connection", "keep-alive");
        }
        return false;
    }

    // Write the request
    pub fn sendResponse(self: *HttpServerConnection, response: *HttpResponse) !void {
        const stream = &self.io.out.stream;
        const request = response.request;

        // Finalize any headers
        if (mem.eql(u8, request.version, "HTTP/1.1")
                and response.disconnect_on_finish) {
            try response.headers.put("Connection", "close");
        }

        if (mem.eql(u8, request.version, "HTTP/1.0")
                and request.headers.eqlIgnoreCase("Connection", "keep-alive")) {
            try response.headers.put("Connection", "keep-alive");
        }

        if (response.chunking_output) {
            try response.headers.put("Transfer-Encoding", "chunked");
        }

        // Write status line
        try stream.print("HTTP/1.1 {} {}\r\n",
            response.status.code,
            response.status.phrase);

        // Write headers
        var it = response.headers.iterator();

        while (it.next()) |header| {
            // Only in debug builds??
            if (mem.indexOf(u8, header.key, "\n") != null or
                mem.indexOf(u8, header.value, "\n") != null) {
                std.debug.warn(
                    "Header invalid '{}: {}'", header.key, header.value);
                return error.ResponseHeaderInvalid;
            }
            try stream.print("{}: {}\r\n", header.key, header.value);
        }

        // Send content length if missing otherwise the client hangs reading
        if (!response.headers.contains("Content-Length")) {
            try stream.print("Content-Length: {}\n\n", response.body.len());
        }

        // Write body
        if (response.chunking_output) {
            //var start = 0;
            // TODO

            try stream.write("0\r\n\r\n");
        } else if (response.body.len() > 0) {
            var chunk = response.body.toSlice();
            try stream.write(chunk);
        }

        // Flush anything left
        try self.io.out.flush();

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
        self.file.close();
        self.closed = true;
    }

    pub fn connectionLost(self: *HttpServerConnection) void {
        if (!self.closed) {
            self.loseConnection();
        }
        self.on_close(self.application, self);
    }

};


pub const RequestHandler = struct {
    application: *Application,
    request: *HttpRequest,
    response: *HttpResponse,

    const requestHandler = fn(self: *RequestHandler) anyerror!void;

    pub fn execute(self: *RequestHandler) !void {
        //var stack_frame: [STACK_SIZE]u8 align(std.Target.stack_align) = undefined;
        //return await @asyncCall(&stack_frame, {}, self.dispatch, self);
        return self.dispatch(self);
    }

    // Dispatches to the other handlers
    fn default_dispatch(self: *RequestHandler) !void {
        const method = self.request.method;
        var handler: requestHandler = _unimplemented;
        if (ascii.eqlIgnoreCase(method, "GET")) {
            handler = self.get;
        } else if (ascii.eqlIgnoreCase(method, "POST")) {
            handler = self.post;
        } else if (ascii.eqlIgnoreCase(method, "PUT")) {
            handler = self.put;
        } else if (ascii.eqlIgnoreCase(method, "HEAD")) {
            handler = self.head;
        } else if (ascii.eqlIgnoreCase(method, "PATCH")) {
            handler = self.patch;
        } else if (ascii.eqlIgnoreCase(method, "DELETE")) {
            handler = self.delete;
        } else if (ascii.eqlIgnoreCase(method, "OPTIONS")) {
            handler = self.options;
        }

        return handler(self);
    }


    dispatch: requestHandler = default_dispatch,

    // Default handlers
    head: requestHandler = _unimplemented,
    get: requestHandler = _unimplemented,
    post: requestHandler = _unimplemented,
    delete: requestHandler = _unimplemented,
    patch: requestHandler = _unimplemented,
    put: requestHandler = _unimplemented,
    options: requestHandler = _unimplemented,

};

// Default handler request implementation
fn _unimplemented(self: *RequestHandler) !void {
    self.response.status = responses.METHOD_NOT_ALLOWED;
    return error.HttpError;
}


// A handler is simply a a factory function which returns a RequestHandler
pub const Handler = fn(allocator: *Allocator, app: *Application, response: *HttpResponse) anyerror!*RequestHandler;

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
    connections: std.AutoHashMap(*HttpServerConnection, void),
    middleware: std.ArrayList(*Middleware),
    error_handler: Handler = createHandler(handlers.ServerErrorHandler),
    not_found_handler: Handler = createHandler(handlers.NotFoundHandler),

    pub const Options = struct {
        // Routes
        routes: []Route,
        allocator: *Allocator = std.heap.direct_allocator,
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

    pub fn init(options: Options) Application {
        const allocator = options.allocator;
        return Application{
            .allocator = allocator,
            .router = Router.init(options.routes),
            .options = options,
            .server = net.StreamServer.init(options.server_options),
            .lock = std.Mutex.init(),
            .connections = std.AutoHashMap(*HttpServerConnection, void).init(allocator),
            .middleware = std.ArrayList(*Middleware).init(allocator),
        };
    }

    pub fn listen(self: *Application, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp4(address, port);
        try self.server.listen(addr);
        std.debug.warn("Listing on {}:{}\n", address, port);
    }

    pub fn start(self: *Application) !void {
        while (true) {
            const conn = try self.server.accept();
            self.connectionMade(conn.file, conn.address) catch |err| {
                return err; // TODO: Catch and log
            };
        }
    }

    // Handle a single connection by delegating it to the HttpServerConnection
    // request loop
    pub fn connectionMade(self: *Application, file: fs.File, addr: net.Address) !void {
        const server_conn = try self.allocator.create(HttpServerConnection);
        //var allocator = &std.heap.ArenaAllocator.init(std.heap.page_allocator).allocator;
        server_conn.* = HttpServerConnection{
            .allocator = self.allocator,
            .file = file,
            .io = IOStream.init(file),
            .address = addr,
            .application = self,
            .on_close = Application.connectionLost,
            .frame = async server_conn.startRequestLoop()
        };

        var lock = self.lock.acquire();
        const entry = try self.connections.put(server_conn, {});
        lock.release();
    }

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

    pub fn connectionLost(self: *Application, server_conn: *HttpServerConnection) void {
        //server_conn.deinit();
        var lock = self.lock.acquire();
        defer lock.release();
        const entry = self.connections.remove(server_conn);

    }

    pub fn deinit(self: *Application) void {
        self.server.deinit();
        self.connections.deinit();
        self.middleware.deinit();
    }

};
