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
pub const util = @import("util.zig");
pub const IOStream = util.IOStream;

pub const HttpRequest = @import("request.zig").HttpRequest;
pub const HttpResponse = @import("response.zig").HttpResponse;



// A single client connection
// if the client requests keep-alive and the server allows
// the connection is reused to process futher requests.
pub const HttpServerConnection = struct {
    application: *Application,
    storage: [1024*1024]u8 = undefined,
    buffer: std.heap.FixedBufferAllocator,
    allocator: *Allocator = undefined,
    io: IOStream,
    address: net.Address = undefined,
    closed: bool = false,
    const Frame = @Frame(startRequestLoop);
    frame: *Frame,


    // Handles a connection
    pub fn startRequestLoop(self: *HttpServerConnection,
                            conn: net.StreamServer.Connection) !void {
        self.address = conn.address;
        self.closed = false;
        self.allocator = &self.buffer.allocator;
        const app = self.application;
        const params = &app.options;
        const stream = &self.io;
        stream.reinit(conn.file);
        defer self.connectionLost();

        var request = try HttpRequest.initCapacity(self.allocator, 4096, 32);
        var response = try HttpResponse.initCapacity(self.allocator,
            &request, mem.page_size, 10);

        var timer = try time.Timer.start();
        while (true) {
            defer self.buffer.reset();
            defer request.reset();
            defer response.reset();

            const n = request.parse(stream) catch |err| switch (err) {
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
                error.ConnectionResetByPeer,
                error.EndOfStream => {
                    self.loseConnection();
                    return;
                },
                else => return err,
            };
            //defer request.deinit();
            //std.debug.warn("readRequest took: {}ns\n", .{timer.lap()});

            const keep_alive = self.canKeepAlive(&request);
            //std.debug.warn("buildResponse took: {}ns\n", .{timer.lap()});

            const factoryFn = try app.processRequest(self, &request, &response);
            if (factoryFn) |factory| {
                self.readBody(&request, &response) catch |err| switch(err) {
                    error.BadRequest,
                    error.ImproperlyTerminatedChunk => {
                        try stream.write("HTTP/1.1 400 Bad Request\r\n\r\n");
                        self.loseConnection();
                        return;
                    },
                    error.RequestEntityTooLarge => {
                        try stream.write("HTTP/1.1 413 Request Entity Too Large\r\n\r\n");
                        self.loseConnection();
                        return;
                    },
                    // error.TimeoutError,
                    error.ConnectionResetByPeer,
                    error.EndOfStream => {
                        self.loseConnection();
                        return;
                    },
                    else => {
                        return err;
                    }
                };

                var handler = try self.buildHandler(factory, &response);
                handler.execute() catch |err| {
                    handler.deinit();
                    var error_handler = try self.buildHandler(
                        app.error_handler, &response);
                    defer error_handler.deinit();
                    try error_handler.execute();
                };
                //handler.deinit();
            }
            try app.processResponse(self, &response);
            //std.debug.warn("processResponse took: {}ns\n", .{timer.lap()});

            // TODO: Write in chunks
            if (self.closed) return;
            try self.sendResponse(&response);
            if (self.closed or !keep_alive) return;
            //std.debug.warn("sendResponse took: {}ns\n\n", .{timer.lap()});
            //std.debug.warn("[{}] {} {} in {}ns\n", .{
            //    self.address, request.method, request.path,
            //    timer.lap()});
        }
    }

    // Build the request handler to generate a response
    fn buildHandler(self: *HttpServerConnection, factory: Handler,
                    response: *HttpResponse) !*RequestHandler {
        if (std.io.is_async) {
            var stack_frame: [1*1024]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {},
                factory, self.allocator, self.application, response);
        } else {
            return factory(self.allocator, self.application, response);
        }
    }


    fn readBody(self: *HttpServerConnection, request: *HttpRequest,
                response: *HttpResponse) !void {
        const params = &self.application.options;
        const content_length = request.content_length;
        var headers = &request.headers;
        const code = response.status.code;

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
        }
        request._read_finished = true;
    }

    fn readFixedBody(self: *HttpServerConnection, request: *HttpRequest) !void {
        const params = &self.application.options;
        var buf = try std.Buffer.initSize(self.allocator, params.chunk_size);
        defer buf.deinit();

        const stream = &self.io;
        var left = request.content_length;
        //var timer = try time.Timer.start();

        while (left > 0) {
            try stream.readAllBuffer(
                &buf, math.min(params.chunk_size, left));

            left -= @intCast(u32, buf.len());
            try request.dataReceived(buf.toSlice());

            // FIXME: This is a syscall per byte
            //if (timer.read() >= params.body_timeout) return error.TimeoutError;
        }
    }

    fn readChunkedBody(self: *HttpServerConnection, request: *HttpRequest) !void {
        // TODO: "chunk extensions" http://tools.ietf.org/html/rfc2616#section-3.6.1
        const stream = &self.io;//&self.io.file.inStream().stream;
        var total_size: u32 = 0;

        const params = &self.application.options;

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
                return error.RequestEntityTooLarge;
            }

            var bytes_to_read: u32 = chunk_len;
            while (bytes_to_read > 0) {
                try stream.readAllBuffer
                    (&buf, math.min(bytes_to_read, chunk_size));
                bytes_to_read -= @intCast(u32, buf.len());
                try request.dataReceived(buf.toSlice());
                    // FIXME: This is a syscall per byte
                //if (timer.read() >= params.body_timeout) return error.TimeoutError;
            }

            // Chunk ends with \r\n
            try stream.readUntilDelimiterBuffer(&buf, '\n', 2);
            if (!mem.eql(u8, buf.toSlice(), "\r\n")) {
                return error.ImproperlyTerminatedChunk;
            }
            //if (timer.read() >= params.body_timeout) return error.TimeoutError;
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
            try stream.print("Content-Length: {}\n\n", .{response.body.len});
        }

        // Write body
        if (response.chunking_output) {
            //var start = 0;
            // TODO

            try stream.write("0\r\n\r\n");
        } else if (response.body.len > 0) {
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
        const app = self.application;
        const lock = app.lock.acquire();
            app.connection_pool.release(self);
        lock.release();
    }

};


pub const RequestHandler = struct {
    allocator: *Allocator,
    application: *Application,
    request: *HttpRequest,
    response: *HttpResponse,

    const request_handler = if (std.io.is_async)
            // FIXME: This does not work
            fn(self: *RequestHandler) anyerror!void
        else
            fn(self: *RequestHandler) anyerror!void;

    pub fn execute(self: *RequestHandler) !void {
        if (std.io.is_async) {
            var stack_frame: [1*1024]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {}, self.dispatch, self);
        } else {
            try self.dispatch(self);
        }
    }

    // Dispatches to the other handlers for now this can't be modified
    pub fn defaultDispatch(self: *RequestHandler) anyerror!void {
        const handler: request_handler = switch (self.request.method) {
            .Get => self.get,
            .Put => self.put,
            .Post => self.post,
            .Patch => self.patch,
            .Head => self.head,
            .Delete => self.delete,
            .Options => self.options,
            else => RequestHandler.defaultHandler,
        };
        if (std.io.is_async) {
            // Give a good chunk to the handler
            var stack_frame: [100*1024]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {}, handler, self);
        } else {
            return handler(self);
        }
    }

    // Default handler request implementation
    pub fn defaultHandler(self: *RequestHandler) anyerror!void {
        self.response.status = responses.METHOD_NOT_ALLOWED;
        return error.HttpError;
    }

    // Generic dispatch to handle
    dispatch: request_handler = defaultDispatch,

    // Default handlers
    head: request_handler = defaultHandler,
    get: request_handler = defaultHandler,
    post: request_handler = defaultHandler,
    delete: request_handler = defaultHandler,
    patch: request_handler = defaultHandler,
    put: request_handler = defaultHandler,
    options: request_handler = defaultHandler,

    // Deinit
    pub fn deinit(self: *RequestHandler) void {
        self.destroy(self);
    }
    destroy: fn(self: *RequestHandler) void,

};


// A handler is simply a a factory function which returns a RequestHandler
pub const Handler = fn(allocator: *Allocator, app: *Application,
                       response: *HttpResponse) error{OutOfMemory}!*RequestHandler;

// This seems a bit excessive....
pub fn createHandler(comptime T: type) Handler {
    const RequestDispatcher = struct {
        const Self  = @This();

        pub fn create(allocator: *Allocator, app: *Application,
                      response: *HttpResponse) !*RequestHandler {
            const self = try allocator.create(T); // Create a dangling pointer lol
            comptime const defaultDispatch = RequestHandler.defaultDispatch;
            comptime const defaultHandler = RequestHandler.defaultHandler;
            self.* = T{
                .handler = RequestHandler{
                    .application = app,
                    .allocator = allocator,
                    .request = response.request,
                    .response = response,
                    .dispatch = if (@hasDecl(T, "dispatch")) Self.dispatch else defaultDispatch,
                    .head = if (@hasDecl(T, "head")) Self.head else defaultHandler,
                    .get = if (@hasDecl(T, "get")) Self.get else defaultHandler,
                    .post = if (@hasDecl(T, "post")) Self.post else defaultHandler,
                    .delete = if (@hasDecl(T, "delete")) Self.delete else defaultHandler,
                    .patch = if (@hasDecl(T, "patch")) Self.patch else defaultHandler,
                    .put = if (@hasDecl(T, "put")) Self.put else defaultHandler,
                    .options = if (@hasDecl(T, "options")) Self.options else defaultHandler,
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
    stack_frame: []align(std.Target.stack_align) u8,

    // Process the request and return the reponse
    pub fn processRequest(self: *Middleware, request: *HttpRequest,
                          response: *HttpResponse) !bool {
        if (std.io.is_async) {
            return await @asyncCall(self.stack_frame, {},
                self.processRequestFn, self, request, response);
        } else {
            return self.processRequestFn(self, request, response);
        }
    }

    pub fn processResponse(self: *Middleware, response: *HttpResponse) !void {
        if (std.io.is_async) {
            return await @asyncCall(self.stack_frame, {},
                self.processResponseFn, self, response);
        } else {
            try self.processResponseFn(self, response);
        }
    }

    processRequestFn: fn(self: *Middleware,
        request: *HttpRequest, response: *HttpResponse) anyerror!bool,
    processResponseFn: fn(self: *Middleware,
        response: *HttpResponse) anyerror!void,
};


pub const ConnectionPool = struct {
    allocator: *Allocator,
    pub const ConnectionList = std.ArrayList(*HttpServerConnection);
    connections: ConnectionList,

    pub fn init(allocator: *Allocator) ConnectionPool {
        return ConnectionPool{
            .allocator = allocator,
            .connections = ConnectionList.init(allocator),
        };
    }

    // Pop the last released buffer or create a new one
    pub fn get(self: *ConnectionPool) ?*HttpServerConnection {
        return self.connections.popOrNull();
    }

    pub fn create(self: *ConnectionPool) !*HttpServerConnection {
        try self.connections.ensureCapacity(self.connections.len + 1);
        return self.allocator.create(HttpServerConnection);
    }

    pub fn release(self: *ConnectionPool, conn: *HttpServerConnection) void {
        return self.connections.appendAssumeCapacity(conn);
    }

    pub fn deinit(self: *ConnectionPool) void {
        while (self.connections.popOrNull()) |conn| {
            self.allocator.destroy(conn);
        }
    }

};


pub const Application = struct {
    allocator: *Allocator,
    router: Router,
    server: net.StreamServer,
    lock: std.Mutex,
    //const Frame = @Frame(startServing);
    //const FrameList = std.ArrayList(*Frame);
    //frames: FrameList,
    connection_pool: ConnectionPool,
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
        body_timeout: u32 = 900 * time.ms_per_s, // 15 min
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
            .middleware = std.ArrayList(*Middleware).init(allocator),
            .connection_pool = ConnectionPool.init(allocator),
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

            // Grab a frame
            const lock = self.lock.acquire();
                var server_conn: *HttpServerConnection = undefined;
                if (self.connection_pool.get()) |c| {
                    server_conn = c;
                } else {
                    server_conn = try self.connection_pool.create();
                    server_conn.* = HttpServerConnection{
                        .application = self,
                        .buffer = std.heap.FixedBufferAllocator.init(
                            &server_conn.storage),
                        .io = try IOStream.initCapacity(
                            allocator, conn.file, 0, mem.page_size),
                        .frame = try allocator.create(HttpServerConnection.Frame)
                    };
                }
            lock.release();

            // Start processing requests
            if (std.io.is_async) {
                server_conn.frame.* = async server_conn.startRequestLoop(conn);
            } else {
                try server_conn.startRequestLoop(conn);
            }
        }
    }

    // ------------------------------------------------------------------------
    // Routing and Middleware
    // ------------------------------------------------------------------------
    pub fn processRequest(self: *Application, server_conn: *HttpServerConnection,
                        request: *HttpRequest, response: *HttpResponse) !?Handler {
        for (self.middleware.toSlice()) |middleware| {
            var done = try middleware.processRequest(request, response);
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

        for (self.middleware.toSlice()) |middleware| {
            try middleware.processResponse(response);
        }
    }

    pub fn deinit(self: *Application) void {
        self.server.deinit();
        self.connection_pool.deinit();
        self.middleware.deinit();
    }

};
