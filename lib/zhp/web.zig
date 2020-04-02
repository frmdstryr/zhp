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

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;


const responses = @import("status.zig");
const handlers = @import("handlers.zig");
const Datetime = @import("time/datetime.zig").Datetime;
const mimetypes = @import("mimetypes.zig");


pub const util = @import("util.zig");
pub const IOStream = util.IOStream;

pub const Headers = @import("headers.zig").Headers;
pub const Status = responses.Status;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const Middleware = @import("middleware.zig").Middleware;


pub const ServerRequest = struct {
    allocator: *Allocator,
    application: *Application,
    stack_frame: []align(std.Target.stack_align) u8 = undefined,

    // Storage the fixed buffer allocator used for each request handler
    storage: []u8 = undefined,
    buffer: std.heap.FixedBufferAllocator = undefined,

    // Request and response passed to the request handler
    request: Request,
    response: Response,

    pub fn init(allocator: *Allocator, application: *Application) !ServerRequest {
        return ServerRequest{
            .allocator = allocator,
            .application = application,
            .stack_frame = try allocator.alignedAlloc(u8, std.Target.stack_align, 1024),
            .storage = try allocator.alloc(u8, 1024*1024),
            .request = try Request.initCapacity(allocator, mem.page_size, 32),
            .response = try Response.initCapacity(allocator, mem.page_size, 10),
        };
    }

    // This should be in init but doesn't work due to return results being copied
    pub fn prepare(self: *ServerRequest) void {
        // TODO: Use custom ArenaAllocator with pre-allocated storage
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
            //var stack_frame: [1*1024]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(self.stack_frame, {}, factoryFn,
                self.application, request, response);
        } else {
            return factoryFn(self.application, response, response);
        }
    }

    // Reset so it can be reused
    pub fn reset(self: *ServerRequest) void {
        self.buffer.reset();
        self.request.reset();
        self.response.reset();
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
        self.allocator.free(self.stack_frame);
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
    io: IOStream,
    address: net.Address = undefined,
    frame: *Frame,
    // Outstanding requests
    //requests: RequestList,

    pub fn init(allocator: *Allocator, application: *Application) !ServerConnection {
        return ServerConnection{
            .application = application,
            //.storage = try allocator.alloc(u8, 100*1024),
            .io = try IOStream.initCapacity(
                allocator, null, 0, mem.page_size),
            .frame = try allocator.create(Frame),
            //.server_request = try ServerRequest.init(allocator, application),
            //.requests = try RequestList.initCapacity(allocator, 8),
        };
    }

    // Handles a connection
    pub fn startRequestLoop(self: *ServerConnection,
                            conn: net.StreamServer.Connection) !void {
        self.address = conn.address;
        const app = self.application;
        const params = &app.options;
        const stream = &self.io.outStream();
        self.io.reinit(conn.file);
        defer self.io.close();
        defer self.release();

        // Grab a request
        // at some point this should be moved into the loop to handle
        // multiplexing but it currently makes it slower
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

        // Start serving requests
        while (true) {
            defer server_request.reset();

            // Parse the request line and headers
            const n = request.parse(&self.io) catch |err| switch (err) {
                error.BadRequest => {
                    _ = try stream.write("HTTP/1.1 400 Bad Request\r\n\r\n");
                    return;
                },
                error.MethodNotAllowed => {
                    _= try stream.write("HTTP/1.1 405 Method Not Allowed\r\n\r\n");
                    return;
                },
                error.RequestEntityTooLarge => {
                    _ = try stream.write("HTTP/1.1 413 Request Entity Too Large\r\n\r\n");
                    return;
                },
                error.RequestUriTooLong => {
                    _ = try stream.write("HTTP/1.1 413 Request-URI Too Long\r\n\r\n");
                    return;
                },
                error.RequestHeaderFieldsTooLarge => {
                    _ = try stream.write("HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n");
                    return;
                },
                //error.TimeoutError,
                error.ConnectionResetByPeer,
                error.EndOfStream => return,
                else => return err,
            };

            const keep_alive = self.canKeepAlive(request);

            // Get the handler
            const factoryFn = try app.processRequest(self, request, response);

            // Read the body if any
            self.readBody(request, response) catch |err| switch(err) {
                //error.ImproperlyTerminatedChunk,
                error.BadRequest => {
                    _ = try stream.write("HTTP/1.1 400 Bad Request\r\n\r\n");
                    return;
                },
                error.RequestEntityTooLarge => {
                    _ = try stream.write("HTTP/1.1 413 Request Entity Too Large\r\n\r\n");
                    return;
                },
                // error.TimeoutError,
                error.ConnectionResetByPeer,
                error.EndOfStream => return,
                else => return err,
            };

            // At this point all reads on the request are done
            // this could be spawn off into an async response for http/2
            if (factoryFn) |factory| {
                var handler = try server_request.buildHandler(
                    factory, request, response);
                handler.execute() catch |err| {
                    handler.deinit();
                    var error_handler = try server_request.buildHandler(
                        app.error_handler, request, response);
                    defer error_handler.deinit();
                    error_handler.err = err;
                    try error_handler.execute();
                };
                //handler.deinit();
            }

             try app.processResponse(self, request, response);

            // Request handler already sent the response
            if (self.io.closed or response.finished) return;
            try self.sendResponse(request, response);
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
                //std.debug.warn(
                //    "Response with code {} should not have a body", .{code});
                return error.BadRequest;
            }
            return;
        }

        // FIXME: There needs to be some limit here
        if (content_length > 0) {
            if (content_length > params.max_body_size) {
                return error.RequestEntityTooLarge;
            }
            try self.readFixedBody(request);
        }
        //} else if (headers.eqlIgnoreCase("Transfer-Encoding", "chunked")) {
        //    try self.readChunkedBody(request);
        //}
        request.read_finished = true;
    }

    fn readFixedBody(self: *ServerConnection, request: *Request) !void {
        const params = &self.application.options;
        const stream = &self.io.inStream();

        // End of the request
        const end_of_request = request.head.len;

        // Resize the buffer to fit the rest
        try request.buffer.resize(request.content_length + end_of_request);

        // Anything else is the body
        var body = request.buffer.span()[end_of_request..];

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
        } // otherwise the body is already in the request buffer

        request.body = body;
        return;
    }

    // Write the request
    pub fn sendResponse(self: *ServerConnection, request: *Request,
                        response: *Response) !void {
        const stream = &self.io.outStream();

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
        for (response.headers.span()) |header| {
            try stream.print("{}: {}\r\n", .{header.key, header.value});
        }

        // Set default content type
        if (!response.headers.contains("Content-Type")) {
            _= try stream.write("Content-Type: text/html\r\n");
        }

        // Send content length if missing otherwise the client hangs reading
        if (!response.headers.contains("Content-Length")) {
            try stream.print("Content-Length: {}\r\n", .{response.body.len});
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
        if (response.source_stream != null)  {
            const in_stream = &response.source_stream.?;

            // Empty the output buffer
            try self.io.flush();
            // Send the stream
            total_wrote = try self.io.writeFromInStream(in_stream);
        } else if (response.body.len > 0) {
            try stream.writeAll(response.body.span());
            total_wrote += response.body.len;
        }

        // Flush anything left
        try self.io.flush();

        // Make sure the content-length was correct otherwise the client
        // will hang waiting
        if (total_wrote != response.body.len) {
            std.debug.warn("Invalid content-length: {} != {}\n",
                .{total_wrote, response.body.len});
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
    application: *Application,
    request: *Request,
    response: *Response,
    err: ?anyerror = null,

    // Request handler signature
    const request_handler = if (std.io.is_async)
            async fn(self: *RequestHandler) anyerror!void
        else
            fn(self: *RequestHandler) anyerror!void;

    // Execute the request handler by running the dispatch function
    // By default the dispatch function calls the method matching
    // the request method
    pub fn execute(self: *RequestHandler) !void {
        if (std.io.is_async) {
            var stack_frame: [100*1024]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {}, self.dispatch, self);
        } else {
            try self.dispatch(self);
        }
    }

    // Dispatches to the other handlers based on the parsed request method
    // This can be replaced with a custom handler if necessary
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
            var stack_frame: [98*1024]u8 align(std.Target.stack_align) = undefined;
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

    pub fn sortLongestPath(lhs: Route, rhs: Route) bool {
        return lhs.path.len > rhs.path.len;
    }

    pub fn init(routes: []Route) Router {
        std.sort.sort(Route, routes, sortLongestPath);
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

    pub fn reverseUrl(self: *Router, name: []const u8, args: var) ![]const u8 {
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

    allocator: *Allocator,
    router: Router,
    server: net.StreamServer,
    connection_pool: ConnectionPool,
    request_pool: RequestPool,
    middleware: std.ArrayList(*Middleware),
    mimetypes: mimetypes.Registry,

    // Global instance
    pub var instance: ?*Application = null;

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
        server_options: net.StreamServer.Options = net.StreamServer.Options{
            .kernel_backlog = 1024,
            .reuse_address = true,
        },

        // Debugging
        debug: bool = false,
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
        for (self.middleware.span()) |middleware| {
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

        for (self.middleware.span()) |middleware| {
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
        for (self.connection_pool.objects.span()) |server_conn| {
            if (!server_conn.io.closed) continue;
            server_conn.io.close();
            n += 1;
        }
        std.debug.warn(" Closed {} connections.\n", .{n});
    }

    pub fn deinit(self: *Application) void {
        std.debug.warn(" Shutting down...\n", .{});
        self.closeAllConnections();
        self.server.deinit();
        self.connection_pool.deinit();
        self.request_pool.deinit();
        self.middleware.deinit();
    }

};
