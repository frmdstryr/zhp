// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const os = std.os;
const mem = std.mem;
const log = std.log;
const net = std.net;
const time = std.time;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;


const web = @import("zhp.zig");
const util = @import("util.zig");

const Datetime = web.datetime.Datetime;
const mimetypes = web.mimetypes;
const Request = web.Request;
const Response = web.Response;
const IOStream = util.IOStream;
const handlers = web.handlers;

const root = @import("root");
const regex = @import("ctregex.zig");


// A handler is simply a a factory function which returns a RequestHandler
pub const Handler = if (std.io.is_async)
        fn(app: *Application, server_request: *ServerRequest) callconv(.Async) anyerror!void
    else
        fn(app: *Application, server_request: *ServerRequest) anyerror!void;


// A utility function so the user doesn't have to use @fieldParentPtr all the time
// This seems a bit excessive...
pub fn createHandler(comptime T: type) Handler {
    const RequestHandler = struct {

        pub fn execute(app: *Application, server_request: *ServerRequest) anyerror!void {
            _ = app;
            const request = &server_request.request;
            const response = &server_request.response;

            switch (server_request.state) {
                .Start => {
                    const self = try response.allocator.create(T);

                    // Create the request handler
                    if (@hasField(T, "server_request")) {
                        self.* = T{
                            .server_request = server_request
                        };
                    } else {
                        self.* = T{};
                    }

                    if (@bitSizeOf(T) > 0) {
                        server_request.handler = @ptrToInt(self);
                    } else if (@hasDecl(T, "stream")) {
                        // We need to be able to store the pointer
                        @compileError("Stream handlers must contain context");
                    }

                    if (@hasDecl(T, "dispatch")) {
                        return try self.dispatch(request, response);
                    } else {
                        inline for (std.meta.fields(Request.Method)) |f| {
                            const name = comptime [_]u8{std.ascii.toLower(f.name[0])} ++ f.name[1..];
                            if (@hasDecl(T, name)) {
                                if (request.method == @intToEnum(Request.Method, f.value)) {
                                    const handler = @field(self, name);
                                    return try handler(request, response);
                                }
                            }
                        }
                        response.status = web.responses.METHOD_NOT_ALLOWED;
                        return;
                    }
                },
                .Finish => {
                    if (@hasDecl(T, "stream")) {
                        if (server_request.handler) |addr| {
                            const self = @intToPtr(*T, addr);
                            _ = try self.stream(server_request.stream.?);
                            return;
                        }
                        return error.ServerError; // Something is missing here...
                    }
                }

            }

        }
    };

    return RequestHandler.execute;
}


pub const ServerRequest = struct {
    pub const State = enum {
        Start,
        Finish
    };
    allocator: Allocator,
    application: *Application,

    // Storage the fixed buffer allocator used for each request handler
    storage: []u8 = undefined,
    buffer: std.heap.FixedBufferAllocator = undefined,

    // Request and response passed to the request handler
    request: Request,
    response: Response,
    stream: ?*IOStream = null,

    // Pointer to the handler that is used for streaming
    state: State = .Start,
    handler: ?usize = null,

    // Request parse error or some handler error
    err: ?anyerror = null,

    pub fn init(allocator: Allocator, app: *Application) !ServerRequest {
        return ServerRequest{
            .allocator = allocator,
            .application = app,
            .storage = try allocator.alloc(
                u8, app.options.handler_buffer_size),
            .request = try Request.initCapacity(
                allocator,
                app.options.request_buffer_size,
                app.options.max_header_count,
                app.options.max_cookie_count),
            .response = try Response.initCapacity(
                allocator,
                app.options.response_buffer_size,
                app.options.response_header_count),
        };
    }

    // This should be in init but doesn't work due to return results being copied
    pub fn prepare(self: *ServerRequest) void {
        self.buffer = std.heap.FixedBufferAllocator.init(self.storage);

        // Setup the stream
        self.response.prepare();

        // Replace the allocator so request handlers have limited memory
        self.response.allocator = self.buffer.allocator();
    }

    // Reset so it can be reused
    pub fn reset(self: *ServerRequest) void {
        self.buffer.reset();
        self.request.reset();
        self.response.reset();
        self.err = null;
        self.handler = null;
        self.state = .Start;
    }

    // Release this request back into the pool
    pub fn release(self: *ServerRequest) void {
        self.stream = null;
        const app = self.application;
        app.request_pool.lock();
        defer app.request_pool.unlock();
        app.request_pool.release(self);
    }

    pub fn deinit(self: *ServerRequest) void {
        self.request.deinit();
        self.response.deinit();
        self.allocator.free(self.storage);
    }


};

// A single client connection
// if the client requests keep-alive and the server allows
// the connection is reused to process futher requests.
pub const ServerConnection = struct {
    const Frame = @Frame(startRequestLoop);
    const RequestList = std.ArrayList(*ServerRequest);
    application: *Application,
    io: IOStream = undefined,
    address: net.Address = undefined,
    frame: *Frame,
    // Outstanding requests
    //requests: RequestList,

    pub fn init(allocator: Allocator, app: *Application) !ServerConnection {
        return ServerConnection{
            .application = app,
            .io = try IOStream.initCapacity(allocator, null, 0, mem.page_size),
            .frame = try allocator.create(Frame),
        };
    }

    // Handles a connection
    pub fn startRequestLoop(self: *ServerConnection,
                            conn: net.StreamServer.Connection) !void {
        defer self.release();
        self.requestLoop(conn) catch |err| {
            log.err("unexpected error: {s}", .{@errorName(err)});
        };
        // log.debug("Closed {}", .{conn});
    }

    fn requestLoop(self: *ServerConnection, conn: net.StreamServer.Connection) !void {
        self.address = conn.address;
        const app = self.application;
        const params = &app.options;
        //const stream = &self.io.writer();
        self.io.reinit(conn.stream);
        defer self.io.close();

        // Grab a request
        // at some point this should be moved into the loop to handle
        // pipelining but it currently makes it slower
        var server_request: *ServerRequest = undefined;
        {
            app.request_pool.lock();
            defer app.request_pool.unlock();

            if (app.request_pool.get()) |c| {
                server_request = c;
            } else {
                server_request = try app.request_pool.create();
                server_request.* = try ServerRequest.init(app.allocator, app);
                server_request.prepare();
            }
        }
        server_request.stream = &self.io;
        defer server_request.release();

        const request = &server_request.request;
        const response = &server_request.response;
        const options = Request.ParseOptions{
            .max_request_line_size = params.max_request_line_size,
            .max_header_size = params.max_request_headers_size,
            .max_content_length = params.max_content_length,
            .dump_buffer = params.dump_request_buffer,
        };

        request.client = conn.address;
        request.stream = &self.io;
        defer request.stream = null;

        // Start serving requests
        while (true) {
            defer server_request.reset();
            var processed_response = false;

            // Parse the request line and headers
            request.parse(&self.io, options) catch |err| switch (err) {
                error.ConnectionResetByPeer,
                error.BrokenPipe,
                error.EndOfStream => return, // Ignore
                else => {
                    server_request.err = err;

//                     if (params.debug) {
//                         if (@errorReturnTrace()) |trace| {
//                             try std.debug.writeStackTrace(
//                                 trace.*,
//                                 &std.io.getStdErr().writer(),
//                                 response.allocator,
//                                 try std.debug.getSelfDebugInfo(),
//                                 std.debug.detectTTYConfig());
//                         }
//                     }
                }
            };

            // Get the function used to build the handler for the request
            // if this is null it means that handler should not be used
            // as one of the middleware handlers took care of it
            const intercepted = try app.processRequest(server_request);

            // Let middleware cleanup
            errdefer if (!processed_response) app.processResponse(server_request) catch |err| {
                log.err("unexpected processing response: {}", .{err});
            };

            if (server_request.err == null and !intercepted) {
                app.execute(server_request) catch |err| {
                    server_request.err = err;
                };
            }

            // If the request handler didn't read the body, do it now
            if (!request.read_finished) {
                request.readBody(&self.io) catch |err| {
                    if (server_request.err == null) {
                        server_request.err = err;
                    }
                };
            }

            // If an error ocurred during parsing or running the handler
            // invoke the error handler
            if (server_request.err) |err| {
                try app.error_handler(server_request);

                switch (err) {
                    error.BrokenPipe,
                    error.EndOfStream,
                    error.ConnectionResetByPeer,
                    error.NotOpenForReading => {
                        self.io.closed = true; // Make sure no response is sent

                        // Only log if it was a partial request
                        if (request.method != .Unknown) {
                            log.warn("connection error: {} {}", .{err, self.address});
                        }
                    },
                    else => {
                        if (self.application.options.debug) {
                            log.warn("server error: {} {}", .{err, request});
                        } else {
                            log.warn("server error: {} {}", .{err, self.address});
                        }
                    },
                }
            }

            // Let middleware process the response
            processed_response = true;
            try app.processResponse(server_request);

            // Request handler already sent the response
            if (self.io.closed or response.finished) return;
            try self.sendResponse(server_request);

            const keep_alive = self.canKeepAlive(request);
            if (self.io.closed or !keep_alive) return;
        }
    }

    fn canKeepAlive(self: *ServerConnection, request: *Request) bool {
        _ = self;
        const headers = &request.headers;
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
    pub fn sendResponse(self: *ServerConnection, server_request: *ServerRequest) !void {
        const request = &server_request.request;
        const response = &server_request.response;
        const stream = &self.io.writer();
        const content_length = response.body.items.len;

        // Write status line
        try stream.print("HTTP/1.1 {d} {s}\r\n", .{
            response.status.code,
            response.status.phrase
        });

        // Write headers
        for (response.headers.headers.items) |header| {
            try stream.print("{s}: {s}\r\n", .{header.key, header.value});
        }

        // Set default content type
        if (!response.headers.contains("Content-Type")) {
            _ = try stream.write("Content-Type: text/html\r\n");
        }

        // Send content length if missing otherwise the client hangs reading
        if (!response.send_stream and !response.headers.contains("Content-Length")) {
            try stream.print("Content-Length: {d}\r\n", .{content_length});
        }

        // End of headers
        try stream.writeAll("\r\n");

        server_request.state = .Finish;

        // Write body
//         if (response.chunking_output) {
//             var start = 0;
//             TODO
//
//             try stream.write("0\r\n\r\n");
//         }
        var total_wrote: usize = 0;
        if (response.send_stream) {
            try self.application.execute(server_request);
        } else if (response.body.items.len > 0) {
            try stream.writeAll(response.body.items);
            total_wrote += response.body.items.len;
        }

        // Flush anything left
        try self.io.flush();

        // Make sure the content-length was correct otherwise the client
        // will hang waiting
        if (!response.send_stream and total_wrote != content_length) {
            log.warn("Response content-length is invalid: {} != {}",
                .{total_wrote, content_length});
            return error.ServerError;
        }

        // Finish
        // If the app finished the request while we're still reading,
        // divert any remaining data away from the delegate and
        // close the connection when we're done sending our response.
        // Closing the connection is the only way to avoid reading the
        // whole input body.
        if (!request.read_finished or response.disconnect_on_finish) {
            self.io.close();
        }

        response.finished = true;
    }

    pub fn release(self: *ServerConnection) void {
        const app = self.application;
        app.connection_pool.lock();
        defer app.connection_pool.unlock();
        app.connection_pool.release(self);
    }

    pub fn deinit(self: *ServerConnection) void {
        const allocator = self.application.allocator;
        allocator.destroy(self.frame);
        self.io.deinit();
    }

};


pub const Route = struct {
    name: []const u8, // Reverse url name
    pattern: []const u8,
    handler: Handler,

    // Create a route for the handler
    // It uses a django style format for parameters, eg
    // /pages/<int>/edit
    pub fn create(comptime name: []const u8, comptime path: []const u8, comptime T: type) Route {
        if (path[0] != '/') {
            @compileError("Route url path must start with /");
        }
        return Route{
            .name=name,
            .pattern=path,
            .handler=createHandler(T)
        };
    }

    pub fn static(comptime name: []const u8, comptime path: []const u8, comptime file_path: []const u8) Route {
        if (path.len < 2 or path[0] != '/' or path[path.len-1] != '/') {
            @compileError("Route url path must start and end with /");
        }
        return Route{
            .name=name,
            .pattern=path++".*",
            .handler=createHandler(handlers.StaticFileHandler(path, file_path)),
        };
    }

    pub fn websocket(comptime name: []const u8, comptime path: []const u8, comptime T: type) Route {
        return create(name, path, handlers.WebsocketHandler(T));
    }

};


pub const Clock = struct {
    buffer: [32]u8 = undefined,
    last_updated: i64 = 0,
    lock: util.Lock = util.Lock{},
    value: []const u8 = "",

    pub fn get(self: *Clock) []const u8 {
        var lock = self.lock.acquire();
        defer lock.release();
        return self.value;
    }

    pub fn update(self: *Clock) void {
        const t = time.milliTimestamp();
        if (t - self.last_updated > 1000) {
            var lock = self.lock.acquire();
            defer lock.release();
            self.value = Datetime.formatHttpFromTimestamp(
                &self.buffer, t) catch unreachable;
            self.last_updated = t;
        }
    }

};


const default_route = [_]Route{
    Route.create("index", "/", handlers.IndexHandler),
};


pub const Middleware = struct {
    init: ?fn(app: *Application) anyerror!void = null,
    processRequest: ?Handler = null,
    processResponse: ?Handler = null,
    deinit: ?fn(app: *Application) void = null,

    pub fn create(comptime T: type) Middleware {
        return Middleware{
            .init = if (@hasDecl(T, "init")) T.init else null,
            .processRequest = if (@hasDecl(T, "processRequest")) T.processRequest else null,
            .processResponse = if (@hasDecl(T, "processResponse")) T.processResponse else null,
            .deinit = if (@hasDecl(T, "deinit")) T.deinit else null,
        };
    }

};

const default_middleware = [_]Middleware{};

pub const Application = struct {

    pub const ConnectionPool = util.ObjectPool(ServerConnection);
    pub const RequestPool = util.ObjectPool(ServerRequest);

    pub const Options = struct {
        xheaders: bool = false,
        protocol: []const u8 = "HTTP/1.1",
        decompress_request: bool = false,
        chunk_size: u32 = 65536,

        /// Will only parse this many request headers
        max_header_count: usize = 32,
        max_cookie_count: usize = 32,

        // If headers are longer than this return a request headers too large error
        max_request_headers_size: u32 = 10*1024,

        /// Size of request buffer
        request_buffer_size: u32 = 65536,

        // Fixed memory buffer size for request handlers to allocate in
        handler_buffer_size: u32 = 5*1024,

        // If request line is longer than this return a request uri too long error
        max_request_line_size: u32 = 4096,

        // Log request buffer
        dump_request_buffer: bool = false,

        // If the content length is over the request buffer size
        // it will spool to a temp file on disk up to this size
        max_content_length: u64 = 50*1024*1024, // 50 MB

        /// Size of response buffer
        response_buffer_size: u32 = 65536,

        /// Initial number of response headers to allocate
        response_header_count: u8 = 12,

        // Timeout in millis
        idle_connection_timeout: u32 = 300 * time.ms_per_s,  // 5 min
        header_timeout: u32 = 300 * time.ms_per_s,  // 5 min
        body_timeout: u32 = 900 * time.ms_per_s, // 15 min

        // Set tcp TCP_NODELAY
        tcp_nodelay: bool = true,

        // List of trusted downstream (ie proxy) servers
        trust_x_headers: bool = true,
        server_options: net.StreamServer.Options = net.StreamServer.Options{
            .kernel_backlog = 1024,
            .reuse_address = true,
        },

        // Salt
        secret_key: []const u8 = "DoNotUSEthis_in[production]",

        // Debugging
        debug: bool = false,
    };


    // ------------------------------------------------------------------------
    // Server Config
    // ------------------------------------------------------------------------
    pub const routes: []const Route = if (@hasDecl(root, "routes"))
        root.routes[0..] else default_route[0..];

    pub const middleware: []const Middleware = if (@hasDecl(root, "middleware"))
        root.middleware[0..] else default_middleware[0..];

    pub const error_handler = createHandler(if (@hasDecl(root, "error_handler"))
        root.error_handler else handlers.ServerErrorHandler);
    pub const not_found_handler = createHandler(if (@hasDecl(root, "not_found_handler"))
        root.not_found_handler else handlers.NotFoundHandler);

    pub var instance: ?*Application = null;

    // ------------------------------------------------------------------------
    // Server setup
    // ------------------------------------------------------------------------
    allocator: Allocator,
    server: net.StreamServer,
    connection_pool: ConnectionPool,
    request_pool: RequestPool,
    running: bool = false,
    options: Options,
    clock: Clock = Clock{},

    // ------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------
    pub fn init(allocator: Allocator, options: Options,) Application {
        mimetypes.instance = mimetypes.Registry.init(allocator);
        return Application{
            .allocator = allocator,
            .options = options,
            .server = net.StreamServer.init(options.server_options),
            .connection_pool = ConnectionPool.init(allocator),
            .request_pool = RequestPool.init(allocator),
        };
    }

    pub fn listen(self: *Application, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp4(address, port);
        try self.server.listen(addr);
        if (@hasDecl(os, "TCP_NODELAY") and self.options.tcp_nodelay) {
            const SOL_TCP = 6;
            try os.setsockopt(
                self.server.sockfd.?,
                SOL_TCP,
                os.TCP_NODELAY,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }
        log.info("Listening on http://{s}:{d}", .{address, port});
    }

    // Start serving requests For each incoming connection.
    // The connections may be kept alive to handle more than one request.
    pub fn start(self: *Application) !void {
        try mimetypes.instance.?.load();
        self.clock.update();

        // Ignore sigpipe
        var act = os.Sigaction{
            .handler = .{.sigaction = os.SIG.IGN },
            .mask = os.empty_sigset,
            .flags = 0,
        };
        os.sigaction(os.SIG.PIPE, &act, null);

        Application.instance = self;
        self.running = true;

        // Init middleware
        inline for (middleware) |m| {
            if (m.init) |f| {
                try f(self);
            }
        }

        var background = async self.backgroundLoop();

        // Make sure the background task stops if an error occurs
        defer {
            self.running = false;
            await background;
        }

        while (self.running) {
            // Grab a frame
            self.connection_pool.lock();
            var server_conn: *ServerConnection = undefined;
            if (self.connection_pool.get()) |c| {
                server_conn = c;
            } else {
                server_conn = try self.connection_pool.create();
                server_conn.* = try ServerConnection.init(self.allocator, self);
                //server_conn.server_request.prepare();
            }
            self.connection_lock.unlock();

            const conn = try self.server.accept();
            //log.debug("Accepted {s}", .{conn});

            // Start processing requests
            if (comptime std.io.is_async) {
                server_conn.frame.* = async server_conn.startRequestLoop(conn);
            } else {
                try server_conn.startRequestLoop(conn);
            }
        }

    }

    // ------------------------------------------------------------------------
    // Routing and Middleware
    // ------------------------------------------------------------------------
    pub fn processRequest(self: *Application, server_request: *ServerRequest) !bool {
        // Let middleware process the request
        // the request body has not yet been read at this point
        // if the middleware returns true the response is considered to be
        // handled and request processing stops here
        inline for (middleware) |m| {
            if (m.processRequest) |f| {
                try f(self, server_request);
                if (server_request.response.finished) return true;
            }
        }
        return false;
    }

    pub fn execute(self: *Application, server_request: *ServerRequest) !void {
        // Inline the routing to avoid using function pointers and async call
        // which seems to have a pretty significant effect on speed
        @setEvalBranchQuota(50000);
        const path = server_request.request.path;
        inline for (routes) |*route| {
            if (try regex.match(route.pattern, .{.encoding=.ascii}, path)) |*match| {
                //std.log.warn("Route: name={s} path={s}\n", .{route.name, request.path});
                if (match.captures.len > 0) {
                    server_request.request.args = match.captures[0..];
                }
                try route.handler(self, server_request);
                return;
            }
        }
        try self.not_found_handler(server_request);
    }

    pub fn processResponse(self: *Application, server_request: *ServerRequest) !void {
        //const request = &server_request.request;
        const response = &server_request.response;

        // Add server headers
        try response.headers.append("Server", "ZHP/0.1");
        // TODO: Does this need to use the lock
        try response.headers.append("Date", self.clock.value);

        inline for (middleware) |m| {
            if (m.processResponse) |f| {
                try f(self, server_request);
            }
        }
    }

    // ------------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------------

    // Periodically go through the pools and cleanup
    pub fn backgroundLoop(self: *Application) void {
        while (self.running) {
            time.sleep(1*time.ns_per_s);
            self.clock.update();
            {
                self.connection_pool.lock();
                defer self.connection_pool.unlock();
                if (self.connection_pool.free_objects.popOrNull()) |conn| {
                    conn.deinit();
                    self.connection_pool.allocator.destroy(conn);
                }
            }

            {
                self.request_pool.lock();
                defer self.request_pool.release();
                if (self.request_pool.free_objects.popOrNull()) |req| {
                    req.deinit();
                    self.request_pool.allocator.destroy(req);
                }
            }
        }
    }

    pub fn closeAllConnections(self: *Application) void {
        const lock = self.connection_pool.lock.acquire();
        defer lock.release();
        var n: usize = 0;
        for (self.connection_pool.objects.items) |server_conn| {
            if (!server_conn.io.closed) continue;
            server_conn.io.close();
            n += 1;
        }
        log.info(" Closed {d} connections.", .{n});
    }

    pub fn deinit(self: *Application) void {
        log.info(" Shutting down...", .{});
        // Init middleware
        inline for (middleware) |m| {
            if (m.deinit) |f| {
                f(self);
            }
        }

        self.closeAllConnections();
        self.server.deinit();
        self.connection_pool.deinit();
        self.request_pool.deinit();
    }

};

test "app" {
    std.testing.refAllDecls(@This());
}
