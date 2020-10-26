// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
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
const assert = std.debug.assert;
const log = std.log;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;


pub const responses = @import("status.zig");
const handlers = @import("handlers.zig");
const Datetime = @import("time/datetime.zig").Datetime;
const mimetypes = @import("mimetypes.zig");
pub const forms = @import("forms.zig");

pub const util = @import("util.zig");
pub const IOStream = util.IOStream;

pub const Headers = @import("headers.zig").Headers;
pub const Status = responses.Status;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const Middleware = @import("middleware.zig").Middleware;


pub const ServerRequest = struct {
    const STACK_SIZE = 10*1024;
    allocator: *Allocator,
    application: *Application,
    //stack_frame: []align(std.Target.stack_align) u8 = undefined,

    // Storage the fixed buffer allocator used for each request handler
    storage: []u8 = undefined,
    buffer: std.heap.FixedBufferAllocator = undefined,

    // Request and response passed to the request handler
    request: Request,
    response: Response,

    err: ?anyerror = null,

    pub fn init(allocator: *Allocator, application: *Application) !ServerRequest {
        return ServerRequest{
            .allocator = allocator,
            .application = application,
            //.stack_frame = try allocator.alignedAlloc(u8, std.Target.stack_align, 1024),
            .storage = try allocator.alloc(
                u8, application.options.handler_buffer_size),
            .request = try Request.initCapacity(
                allocator,
                application.options.request_buffer_size,
                application.options.max_header_count),
            .response = try Response.initCapacity(
                allocator,
                application.options.response_buffer_size,
                application.options.response_header_count),
        };
    }

    // This should be in init but doesn't work due to return results being copied
    pub fn prepare(self: *ServerRequest) void {
        self.buffer = std.heap.FixedBufferAllocator.init(self.storage);

        // Setup the stream
        self.response.prepare();

        // Replace the allocator so request handlers have limited memory
        self.response.allocator = &self.buffer.allocator;
    }

    // Build the request handler to generate a response
    fn buildHandler(self: *ServerRequest, factoryFn: Handler,
                    request: *Request, response: *Response) !*RequestHandler {
        if (std.io.is_async) {
            var stack_frame: [STACK_SIZE]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {}, factoryFn,
                .{self.application, request, response});
        } else {
            return factoryFn(self.application, response, response);
        }
    }

    // Reset so it can be reused
    pub fn reset(self: *ServerRequest) void {
        self.buffer.reset();
        self.request.reset();
        self.response.reset();
        self.err = null;
    }

    // Release this request back into the pool
    pub fn release(self: *ServerRequest) void {
        //self.reset();
        const app = self.application;
        const lock = app.request_pool.lock.acquire();
        app.request_pool.release(self);
        lock.release();
    }

    pub fn deinit(self: *ServerConnection) void {
        self.request.deinit();
        self.response.deinit();
        //self.allocator.free(self.stack_frame);
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
    handler: ?*RequestHandler = null,
    // Outstanding requests
    //requests: RequestList,

    pub fn init(allocator: *Allocator, application: *Application) !ServerConnection {
        return ServerConnection{
            .application = application,
            //.storage = try allocator.alloc(u8, 100*1024),
            .io = try IOStream.initCapacity(allocator, null, 0, mem.page_size),
            .frame = try allocator.create(Frame),
            //.server_request = try ServerRequest.init(allocator, application),
            //.requests = try RequestList.initCapacity(allocator, 8),
        };
    }

    // Handles a connection
    pub fn startRequestLoop(self: *ServerConnection,
                            conn: net.StreamServer.Connection) !void {
        self.requestLoop(conn) catch |err| {
            log.err("server error: {}", .{@errorName(err)});
        };
        log.debug("Closed {}", .{conn});
    }

    fn requestLoop(self: *ServerConnection, conn: net.StreamServer.Connection) !void {
        self.address = conn.address;
        const app = self.application;
        const params = &app.options;
        const stream = &self.io.writer();
        self.io.reinit(conn.file);
        defer self.io.close();
        defer self.release();

        // Grab a request
        // at some point this should be moved into the loop to handle
        // pipelining but it currently makes it slower
        const lock = app.request_pool.lock.acquire();
            var server_request: *ServerRequest = undefined;
            if (app.request_pool.get()) |c| {
                server_request = c;
            } else {
                server_request = try app.request_pool.create();
                server_request.* = try ServerRequest.init(
                    app.allocator, app);
                server_request.prepare();
            }
        lock.release();
        defer server_request.release();

        const request = &server_request.request;
        const response = &server_request.response;

        request.client = conn.address;

        // Start serving requests
        while (true) {
            defer server_request.reset();
            defer if (self.handler) |handler| {
                handler.deinit();
                self.handler = null;
            };

            // Parse the request line and headers
            _ = request.parse(&self.io) catch |err| {
                server_request.err = err;
            };

            // If no error occurred read the body
            if (server_request.err == null) {
                self.readBody(request, response) catch |err| {
                    server_request.err = err;
                };
            }

            // Body read ok, now read the request
            if (server_request.err == null) {
                // Get the handler
                const factoryFn = try app.processRequest(self, request, response);

                // At this point all reads on the request are done
                // this could be spawn off into an async response for http/2
                if (factoryFn) |factory| {
                    self.handler = try server_request.buildHandler(
                        factory, request, response);

                    const handler = self.handler.?;
                    handler.execute() catch |err| {
                        server_request.err = err;
                    };
                }
            }

            // If an error ocurred during parsing or running the handler
            // invoke the error handler
            if (server_request.err) |err| {
                log.debug("Handling error: {}", .{err});
                self.handler = try server_request.buildHandler(
                    app.error_handler, request, response);
                const handler = self.handler.?;
                handler.err = err;
                try handler.execute();
                switch (err) {
                    error.EndOfStream, error.ConnectionResetByPeer => {
                        self.io.closed = true; // Make sure no response is sent
                    },
                    else=>{},
                }
            }

            try app.processResponse(self, request, response);

            // Request handler already sent the response
            if (self.io.closed or response.finished) return;
            try self.sendResponse(request, response);

            const keep_alive = self.canKeepAlive(request);
            if (self.io.closed or !keep_alive) return;
        }
    }

    fn canKeepAlive(self: *ServerConnection, request: *Request) bool {
        if (self.application.options.no_keep_alive) {
            return false;
        }
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

    fn readBody(self: *ServerConnection, request: *Request,
                response: *Response) !void {
        const params = &self.application.options;
        const content_length = request.content_length;
        const headers = &request.headers;
        const code = response.status.code;

        if (headers.eqlIgnoreCase("Expect", "100-continue")) {
            response.status = responses.CONTINUE;
        }

        if (code == 204) {
            // This response code is not allowed to have a non-empty body,
            // and has an implicit length of zero instead of read-until-close.
            // http://www.w3.org/Protocols/rfc2616/rfc2616-sec4.html#sec4.3
            if (headers.contains("Transfer-Encoding") or !(content_length == 0)) {
                //log.warn(
                //    "Response with code {} should not have a body", .{code});
                return error.BadRequest;
            }
            return;
        }

        // FIXME: There needs to be some limit here
        if (content_length > params.max_body_size) {
            return error.RequestEntityTooLarge;
        } else if (content_length > 0) {
            try self.readFixedBody(request);
        }
        //} else if (headers.eqlIgnoreCase("Transfer-Encoding", "chunked")) {
        //    try self.readChunkedBody(request);
        //}
        request.read_finished = true;
    }

    fn readFixedBody(self: *ServerConnection, request: *Request) !void {
        const params = &self.application.options;
        const stream = &self.io.reader();

        // End of the request
        const end_of_request = request.head.len;

        // Anything else is the body
        const end_of_body = request.content_length + end_of_request;
        const end = std.math.min(request.buffer.capacity, end_of_body);
        const body = request.buffer.items[end_of_request..end];

        // Take whatever is still buffered
        const amt = self.io.consumeBuffered(request.content_length);

        if (amt < request.content_length) {
            // We need to read more
            var buf = body[amt..];

            // Switch the stream to unbuffered mode and read directly to the request
            // buffer
            // TODO: Should do read in chunks
            self.io.readUnbuffered(true);
            defer self.io.readUnbuffered(false);
            try stream.readNoEof(buf);

            if (end != end_of_body) {
                // FIXME: Need to spool to file
                return error.RequestTooLarge;
            }

        } // otherwise the body is already in the request buffer

        request.body = body;
        return;
    }

    // Write the request
    pub fn sendResponse(self: *ServerConnection, request: *Request,
                        response: *Response) !void {
        const stream = &self.io.writer();

        // Finalize any headers
        if (request.version == .Http1_1 and response.disconnect_on_finish) {
            try response.headers.append("Connection", "close");
        } else if (request.version == .Http1_0
                and request.headers.eqlIgnoreCase("Connection", "keep-alive")) {
            try response.headers.append("Connection", "keep-alive");
        }

        if (response.chunking_output) {
            try response.headers.append("Transfer-Encoding", "chunked");
        }

        // Write status line
        try stream.print("HTTP/1.1 {} {}\r\n", .{
            response.status.code,
            response.status.phrase
        });

        // Write headers
        for (response.headers.headers.items) |header| {
            try stream.print("{}: {}\r\n", .{header.key, header.value});
        }

        // Set default content type
        if (!response.headers.contains("Content-Type")) {
            _= try stream.write("Content-Type: text/html\r\n");
        }

        // Send content length if missing otherwise the client hangs reading
        if (!response.send_stream and !response.headers.contains("Content-Length")) {
            try stream.print("Content-Length: {}\r\n", .{response.body.items.len});
        }

        // End of headers
        _= try stream.write("\r\n");

        // Write body
//         if (response.chunking_output) {
//             var start = 0;
//             TODO
//
//             try stream.write("0\r\n\r\n");
//         }
        var total_wrote: usize = 0;
        if (response.send_stream) {
            // Empty the output buffer
            try self.io.flush();
            if (self.handler) |handler| {
                total_wrote += try handler.startStreaming(&self.io);
            } else {
                return error.ServerError; // Stream set but no stream fn!
            }
        } else if (response.body.items.len > 0) {
            try stream.writeAll(response.body.items);
            total_wrote += response.body.items.len;
        }

        // Flush anything left
        try self.io.flush();

        // Make sure the content-length was correct otherwise the client
        // will hang waiting
        if (!response.send_stream and total_wrote != response.body.items.len) {
            log.warn("Invalid content-length: {} != {}",
                .{total_wrote, response.body.items.len});
            return error.InvalidContentLength;
        }


        // Finish
        // If the app finished the request while we're still reading,
        // divert any remaining data away from the delegate and
        // close the connection when we're done sending our response.
        // Closing the connection is the only way to avoid reading the
        // whole input body.
        if (!request.read_finished) {
            self.io.close();
        }

        response.finished = true;
    }

    pub fn release(self: *ServerConnection) void {
        const app = self.application;
        const lock = app.connection_pool.lock.acquire();
            app.connection_pool.release(self);
        lock.release();
    }

    pub fn deinit(self: *ServerConnection) void {
        const allocator = self.application.allocator;
        allocator.destroy(self.frame);
        self.io.deinit();
    }

};


pub const RequestHandler = struct {
    const STACK_SIZE = 100*1024;

    // Request handler signature
    const HandlerFn = if (std.io.is_async)
            fn(self: *RequestHandler) callconv(.Async) anyerror!void
        else
            fn(self: *RequestHandler) anyerror!void;
    const StreamFn = if (std.io.is_async)
            fn(self: *RequestHandler, out_stream: *IOStream) callconv(.Async) anyerror!usize
        else
            fn(self: *RequestHandler, out_stream: *IOStream) anyerror!usize;

    application: *Application,
    request: *Request,
    response: *Response,
    err: ?anyerror = null,

    // Generic dispatch to handle
    dispatch: HandlerFn = defaultDispatch,

    // Default handlers
    head: HandlerFn = defaultHandler,
    get: HandlerFn = defaultHandler,
    post: HandlerFn = defaultHandler,
    delete: HandlerFn = defaultHandler,
    patch: HandlerFn = defaultHandler,
    put: HandlerFn = defaultHandler,
    options: HandlerFn = defaultHandler,
    stream: ?StreamFn = null,
    destroy: fn(self: *RequestHandler) void,

    // Execute the request handler by running the dispatch function
    // By default the dispatch function calls the method matching
    // the request method
    pub fn execute(self: *RequestHandler) !void {
        if (std.io.is_async) {
            var stack_frame: [STACK_SIZE * 2]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {}, self.dispatch, .{self});
        } else {
            try self.dispatch(self);
        }
    }

    // Dispatches to the other handlers based on the parsed request method
    // This can be replaced with a custom handler if necessary
    pub fn defaultDispatch(self: *RequestHandler) anyerror!void {
        const handler: HandlerFn = switch (self.request.method) {
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
            var stack_frame: [STACK_SIZE]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {}, handler, .{self});
        } else {
            return handler(self);
        }
    }

    // Default handler request implementation
    pub fn defaultHandler(self: *RequestHandler) anyerror!void {
        self.response.status = responses.METHOD_NOT_ALLOWED;
        return error.HttpError;
    }

    // Deinit
    pub fn deinit(self: *RequestHandler) void {
        self.destroy(self);
    }

    pub fn startStreaming(self: *RequestHandler, out_stream: *IOStream) !usize {
        if (self.stream) |stream_fn| {
            var stack_frame: [STACK_SIZE]u8 align(std.Target.stack_align) = undefined;
            var f = await @asyncCall(&stack_frame, {}, stream_fn, .{self, out_stream});
            return try f;
        }
        return 0;
    }

};


// A handler is simply a a factory function which returns a RequestHandler
pub const Handler = fn(app: *Application, request: *Request, response: *Response) anyerror!*RequestHandler;

// This seems a bit excessive....
pub fn createHandler(comptime T: type) Handler {
    const RequestDispatcher = struct {
        const Self  = @This();

        pub fn create(app: *Application, request: *Request, response: *Response) !*RequestHandler {
            comptime const defaultDispatch = RequestHandler.defaultDispatch;
            comptime const defaultHandler = RequestHandler.defaultHandler;
            const self = try response.allocator.create(T);
            self.* = T{
                .handler = RequestHandler{
                    .application = app,
                    .request = request,
                    .response = response,
                    .dispatch = if (@hasDecl(T, "dispatch")) Self.dispatch else defaultDispatch,
                    .head = if (@hasDecl(T, "head")) Self.head else defaultHandler,
                    .get = if (@hasDecl(T, "get")) Self.get else defaultHandler,
                    .post = if (@hasDecl(T, "post")) Self.post else defaultHandler,
                    .delete = if (@hasDecl(T, "delete")) Self.delete else defaultHandler,
                    .patch = if (@hasDecl(T, "patch")) Self.patch else defaultHandler,
                    .put = if (@hasDecl(T, "put")) Self.put else defaultHandler,
                    .options = if (@hasDecl(T, "options")) Self.options else defaultHandler,
                    .stream = if (@hasDecl(T, "stream")) Self.stream else null,
                    .destroy = Self.destroy,
                },
            };
            return &self.handler;
        }

        pub fn dispatch(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.dispatch(req.request, req.response);
        }

        pub fn head(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.head(req.request, req.response);
        }

        pub fn get(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.get(req.request, req.response);
        }

        pub fn post(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.post(req.request, req.response);
        }

        pub fn delete(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.delete(req.request, req.response);
        }

        pub fn patch(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.patch(req.request, req.response);
        }

        pub fn put(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.put(req.request, req.response);
        }

        pub fn options(req: *RequestHandler) !void {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.options(req.request, req.response);
        }

        pub fn destroy(req: *RequestHandler) void {
            const handler = @fieldParentPtr(T, "handler", req);
            //req.allocator.destroy(handler);
        }

        pub fn stream(req: *RequestHandler, out_stream: *IOStream) !usize {
            const handler = @fieldParentPtr(T, "handler", req);
            return handler.stream(out_stream);
        }
    };

    return RequestDispatcher.create;
}

pub const Route = struct {
    name: []const u8, // Reverse url name
    path: []const u8, // Path pattern
    startswith: bool = false,
    handler: Handler,

    // Create a route for the handler
    // It uses a django style format for parameters, eg
    // /pages/<int>/edit
    pub fn create(comptime name: []const u8, comptime path: []const u8, comptime T: type) Route {
        if (path[0] != '/') {
            @compileError("Route url path must start with /");
        }
        return Route{.name=name, .path=path, .handler=createHandler(T)};
    }

    pub fn static(comptime name: []const u8, comptime path: []const u8) Route {
        if (path[0] != '/' or path[path.len-1] != '/') {
            @compileError("Route url path must start and end with /");
        }
        return Route{
            .name=name,
            .path=path,
            .startswith=true,
            .handler=createHandler(handlers.StaticFileHandler(path, name)),
        };
    }

    // Check if the request path matches this route
    pub fn matches(self: *const Route, path: []const u8) bool {
        // TODO: This is not at all correct
        if (self.startswith) {
            return mem.startsWith(u8, path, self.path);
        }
        return mem.eql(u8, path, self.path);
    }
};


pub const Router = struct {
    routes: []Route,

    pub fn sortLongestPath(context: void, lhs: Route, rhs: Route) bool {
        return lhs.path.len > rhs.path.len;
    }

    pub fn init(routes: []Route) Router {
        std.sort.sort(Route, routes, {}, sortLongestPath);
        return Router{
            .routes = routes,
        };
    }
    pub fn findHandler(self: *Router, request: *Request) !Handler {
        for (self.routes) |route| {
            if (route.matches(request.path)) {
                //std.debug.warn("Route: name={} path={}\n", .{route.name, request.path});
                return route.handler;
            }
        }
        //std.debug.warn("Route: Not found for path={}\n", .{request.path});
        return error.NotFound;
    }

    pub fn reverseUrl(self: *Router, name: []const u8, args: anytype) ![]const u8 {
        for (self.routes) |route| {
            if (mem.eql(u8, route.name, name)) {
                return route.path;
            }
        }
        return error.NotFound;
    }

};


pub const Application = struct {
    pub const ConnectionPool = util.ObjectPool(ServerConnection);
    pub const RequestPool = util.ObjectPool(ServerRequest);

    // Global instance
    pub var instance: ?*Application = null;

    // ------------------------------------------------------------------------
    // Server setup
    // ------------------------------------------------------------------------
    pub const Options = struct {
        // Routes
        routes: []Route,
        allocator: *Allocator,
        xheaders: bool = false,
        no_keep_alive: bool = false,
        protocol: []const u8 = "HTTP/1.1",
        decompress_request: bool = false,
        chunk_size: u32 = 65536,

        /// Will only parse this many request headers
        max_header_count: u8 = 32,

        /// Size of request buffer
        request_buffer_size: u32 = 65536,

        // Fixed memory buffer size for request handlers to allocate in
        handler_buffer_size: u32 = 5*1024,

        // If the content length is over the request buffer size
        // it will spool to a temp file on disk up to this size
        max_body_size: u64 = 5*1000*1000, // 5 MB

        /// Size of response buffer
        response_buffer_size: u32 = 65536,

        /// Initial number of response headers to allocate
        response_header_count: u8 = 12,

        // Timeout in millis
        idle_connection_timeout: u32 = 300 * time.ms_per_s,  // 5 min
        header_timeout: u32 = 300 * time.ms_per_s,  // 5 min
        body_timeout: u32 = 900 * time.ms_per_s, // 15 min


        // List of trusted downstream (ie proxy) servers
        trusted_downstream: ?[][]const u8 = null,
        server_options: net.StreamServer.Options = net.StreamServer.Options{
            .kernel_backlog = 1024,
            .reuse_address = true,
        },

        // Debugging
        debug: bool = false,
    };

    allocator: *Allocator,
    router: Router,
    server: net.StreamServer,
    connection_pool: ConnectionPool,
    request_pool: RequestPool,
    middleware: std.ArrayList(*Middleware),
    mimetypes: mimetypes.Registry,

    // ------------------------------------------------------------------------
    // Default handlers
    // ------------------------------------------------------------------------
    error_handler: Handler = createHandler(handlers.ServerErrorHandler),
    not_found_handler: Handler = createHandler(handlers.NotFoundHandler),
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
            .middleware = std.ArrayList(*Middleware).init(allocator),
            .connection_pool = ConnectionPool.init(allocator),
            .request_pool = RequestPool.init(allocator),
            .mimetypes = mimetypes.Registry.init(allocator),
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
        try self.mimetypes.load();

        Application.instance = self;
        while (true) {
            // Grab a frame
            const lock = self.connection_pool.lock.acquire();
                var server_conn: *ServerConnection = undefined;
                if (self.connection_pool.get()) |c| {
                    server_conn = c;
                } else {
                    server_conn = try self.connection_pool.create();
                    server_conn.* = try ServerConnection.init(self.allocator, self);
                    //server_conn.server_request.prepare();
               }
            lock.release();

            const conn = try self.server.accept();
            log.debug("Accepted {}", .{conn});

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
    pub fn processRequest(self: *Application, server_conn: *ServerConnection,
                          request: *Request, response: *Response) !?Handler {

        // Let middleware process the request
        // the request body has not yet been read at this point
        // if the middleware returns true the response is considered to be
        // handled and request processing stops here
        for (self.middleware.items) |middleware| {
            var done = try middleware.processRequest(request, response);
            if (done) return null;
        }

        // Find the handler to perform this request
        // if no handler is found the not_found_handler is used.
        return self.router.findHandler(request) catch |err| {
            if (err == error.NotFound) {
                return self.not_found_handler;
            } else {
                return self.error_handler;
            }
        };
    }

    pub fn processResponse(self: *Application, server_conn: *ServerConnection,
                           request: *Request, response: *Response) !void {

        // Add server headers
        try response.headers.append("Server", "ZHP/0.1");
        try response.headers.append("Date",
            try Datetime.formatHttpFromTimestamp(
                response.allocator, time.milliTimestamp()));

        for (self.middleware.items) |middleware| {
            try middleware.processResponse(request, response);
        }
    }

    // ------------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------------
    pub fn closeAllConnections(self: *Application) void {
        const lock = self.connection_pool.lock.acquire();
        defer lock.release();
        var n: usize = 0;
        for (self.connection_pool.objects.items) |server_conn| {
            if (!server_conn.io.closed) continue;
            server_conn.io.close();
            n += 1;
        }
        log.info(" Closed {} connections.", .{n});
    }

    pub fn deinit(self: *Application) void {
        log.info(" Shutting down...", .{});
        self.closeAllConnections();
        self.server.deinit();
        self.connection_pool.deinit();
        self.request_pool.deinit();
        self.middleware.deinit();
    }

};
