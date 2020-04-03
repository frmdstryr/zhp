// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const web = @import("web.zig");
const Request = web.Request;
const Response = web.Response;


pub const Middleware = struct {
    pub const STACK_SIZE = 100*1024;

    // Process the request and return the reponse
    pub fn processRequest(self: *Middleware, request: *Request, response: *Response) !bool {
        if (comptime std.io.is_async) {
            var stack_frame: [STACK_SIZE]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {},
                self.processRequestFn, self, request, response);
        } else {
            return self.processRequestFn(self, request, response);
        }
    }

    pub fn processResponse(self: *Middleware, request: *Request, response: *Response) !void {
        if (comptime std.io.is_async) {
            var stack_frame: [STACK_SIZE ]u8 align(std.Target.stack_align) = undefined;
            return await @asyncCall(&stack_frame, {},
                self.processResponseFn, self, request, response);
        } else {
            try self.processResponseFn(self, request, response);
        }
    }

    const RequestFn = if (std.io.is_async)
            async fn(self: *Middleware, request: *Request, response: *Response) anyerror!bool
        else
            fn(self: *Middleware, request: *Request, response: *Response) anyerror!bool;

    processRequestFn: RequestFn,

    const ResponseFn = if (std.io.is_async)
            async fn(self: *Middleware, request: *Request, response: *Response) anyerror!void
        else
            fn(self: *Middleware, request: *Request, response: *Response) anyerror!void;

    processResponseFn: ResponseFn,
};


pub const LoggingMiddleware = struct {

    middleware: Middleware = Middleware{
        .processRequestFn = LoggingMiddleware.processRequest,
        .processResponseFn = LoggingMiddleware.processResponse,
    },

    pub fn processRequest(middleware: *Middleware, request: *Request, response: *Response) !bool {
        const self = @fieldParentPtr(LoggingMiddleware, "middleware", middleware);
        return false;
    }

    pub fn processResponse(middleware: *Middleware, request: *Request, response: *Response) !void {
        const self = @fieldParentPtr(LoggingMiddleware, "middleware", middleware);

        // TODO: This is not async
        std.debug.warn("{} {} {} ({}) {}\n", .{
            response.status.code,
            @tagName(request.method),
            request.path,
            request.client,
            response.body.len});
    }
};
