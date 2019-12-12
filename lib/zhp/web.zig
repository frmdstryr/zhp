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

//const re = @import("re/regex.zig").Regex;
const responses = @import("status.zig");
const handlers = @import("handlers.zig");

const HttpHeaders = @import("headers.zig").HttpHeaders;
const HttpStatus = responses.HttpStatus;
const util = @import("util.zig");
const IOStream = util.IOStream;

pub const HttpRequest = @import("request.zig").HttpRequest;
pub const HttpResponse = @import("response.zig").HttpResponse;



// A single client connection
// if the client requests keep-alive and the server allows
// the connection is reused to process futher requests.
pub const HttpServerConnection = struct {
    application: *Application,
    buffer: std.heap.FixedBufferAllocator,
    allocator: *Allocator = undefined,
    file: fs.File,
    io: IOStream = undefined,
    address: net.Address,
    closed: bool = false,

    // Handles a connection
    pub fn startRequestLoop(self: *HttpServerConnection) !void {
        defer self.connectionLost();
        self.allocator = &self.buffer.allocator;
        self.io = try IOStream.initCapacity(
            self.allocator, self.file, mem.page_size);
        const app = self.application;
        const params = &app.options;
        const stream = &self.io;
        var timer = try time.Timer.start();
        while (true) {
            defer self.buffer.reset();
            var request = self.readRequest() catch |err| switch (err) {
                error.BadRequest => {
                    try stream.write("HTTP/1.1 400 Bad Request\r\n\r\n");
                    self.loseConnection();
                    return;
                },
                error.MethodNotAllowed => {
                    try stream.write("HTTP/1.1 405 Method Not Allowed\r\n\r\n");
                    self.loseConnection();
                    return;
                },
                error.RequestEntityTooLarge => {
                    try stream.write("HTTP/1.1 413 Request Entity Too Large\r\n\r\n");
                    self.loseConnection();
                    return;
                },
                error.RequestUriTooLong => {
                    try stream.write("HTTP/1.1 413 Request-URI Too Long\r\n\r\n");
                    self.loseConnection();
                    return;
                },
                error.RequestHeaderFieldsTooLarge => {
                    try stream.write("HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n");
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
            std.debug.warn("readRequest took: {}ns\n", .{timer.lap()});

            const keep_alive = self.canKeepAlive(request);
            var response = try self.buildResponse(request);
            std.debug.warn("buildResponse took: {}ns\n", .{timer.lap()});

            var factory = try app.processRequest(self, request, response);
            if (factory != null) {
                self.readBody(request, response) catch |err| switch(err) {
                    error.BadRequest,
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
            std.debug.warn("processResponse took: {}ns\n", .{timer.lap()});

            // TODO: Write in chunks
            if (self.closed) return;
            try self.sendResponse(response);
            if (self.closed or !keep_alive) return;
            std.debug.warn("sendResponse took: {}ns\n\n", .{timer.lap()});
            //std.debug.warn("[{}] {} {} in {}ns\n", .{
            //    self.address, request.method, request.path,
            //    timer.lap()});
        }
    }

    // Build the request handler to generate a response
    fn buildHandler(self: *HttpServerConnection, factory: Handler,
                    response: *HttpResponse) !*RequestHandler {
        return factory(self.allocator, self.application, response);
    }

    // Read a new request from the stream
    // this does not read the body of the request.
    pub fn readRequest(self: *HttpServerConnection) !*HttpRequest {
        var timer = try std.time.Timer.start();
        const request = try self.allocator.create(HttpRequest);
        const stream = &self.io;//.file.inStream().stream;
        const params = &self.application.options;
        const timeout = params.header_timeout * 1000; // ms to ns
        request.* = try HttpRequest.initCapacity(self.allocator, 4096, 32);
        std.debug.warn("  createRequest took: {}ns\n", .{timer.lap()});
        const n = try request.parse(stream);
        std.debug.warn("  parseRequest took: {}ns\n", .{timer.lap()});
        return request;
    }

    pub fn buildResponse(self: *HttpServerConnection,
                     request: *HttpRequest) !*HttpResponse {
        const response = try self.allocator.create(HttpResponse);
        response.* = try HttpResponse.initCapacity(self.allocator,
            request, mem.page_size, 10);
        return response;
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
                return error.BadRequest;
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
        const stream = &self.io;
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
        const stream = &self.io;
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
        for (response.headers.toSlice()) |header| {
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
    processRequest: fn(self: *Middleware,
        request: *HttpRequest, response: *HttpResponse) anyerror!bool,
    processResponse: fn(self: *Middleware,
        response: *HttpResponse) anyerror!void,
};


pub const Application = struct {
    allocator: *Allocator,
    router: Router,
    server: net.StreamServer,
    lock: std.Mutex,


    pub const Context = struct {
        // This is the max memory allowed per request
        buffer: [1024*1024]u8 = undefined,
        server_conn: HttpServerConnection,
    };
    const ConnectionMap = std.AutoHashMap(*Context, *@Frame(startServing));

    used_connections: ConnectionMap,
    free_connections: ConnectionMap,

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
            .used_connections = ConnectionMap.init(allocator),
            .free_connections = ConnectionMap.init(allocator),
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
            //const arena = ArenaAllocator.init(allocator);
            const conn = try self.server.accept();

            const lock = self.lock.acquire();
                var context: *Context = undefined;
                var frame: *@Frame(startServing) = undefined;
                var it = self.free_connections.iterator();
                if (it.next()) |entry| {
                    context = entry.key;
                    frame = entry.value;
                    const r = self.free_connections.remove(entry.key);
                } else {
                    context = try allocator.create(Context);
                    frame = try allocator.create(@Frame(startServing));
                }
                const e = try self.used_connections.put(context, frame);
            lock.release();

            //conn.file = client.file;
            //conn.address = client.address;


            // Spawn the async stuff
            if (comptime std.io.is_async) {
                frame.* = async self.startServing(conn, context);
            } else {
                try self.startServing(conn, context);
            }
        }
    }

    // ------------------------------------------------------------------------
    // Handling
    // ------------------------------------------------------------------------
    fn startServing(self: *Application, conn: net.StreamServer.Connection,
                    context: *Context) !void {
        const server_conn = &context.server_conn;
        const buffer = &context.buffer;
        //std.debug.warn("Start serving {}\n", .{conn.file.handle});

        // Bulild the connection
        server_conn.* = HttpServerConnection{
            .buffer = std.heap.FixedBufferAllocator.init(buffer),
            .file = conn.file,
            .address = conn.address,
            .application = self,
        };

        // Send it
        server_conn.startRequestLoop() catch |err| {
            //std.debug.warn("Error {} {}\n", .{conn.file.handle, err});
            switch (err) {
                error.ConnectionResetByPeer => {}, // Ignore
                else => return err,
            }
        };

        //std.debug.warn("Done serving {}\n", .{conn.file.handle});

        // Free the connection and set the frame to be cleaned up later
        var lock = self.lock.acquire();
            if (self.used_connections.remove(context)) |e| {
                const r = try self.free_connections.put(context, e.value);
            }
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
            try util.formatDate(server_conn.allocator, time.milliTimestamp()));

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
        self.free_connections.deinit();
        self.used_connections.deinit();
        self.middleware.deinit();
    }

};
