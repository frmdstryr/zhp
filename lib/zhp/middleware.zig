const std = @import("std");
const web = @import("web.zig");



pub const Middleware = struct {
    stack_frame: []align(std.Target.stack_align) u8,

    // Process the request and return the reponse
    pub fn processRequest(self: *Middleware, request: *web.HttpRequest,
                          response: *web.HttpResponse) !bool {
        if (std.io.is_async) {
            return await @asyncCall(self.stack_frame, {},
                self.processRequestFn, self, request, response);
        } else {
            return self.processRequestFn(self, request, response);
        }
    }

    pub fn processResponse(self: *Middleware, request: *web.HttpRequest,
                           response: *web.HttpResponse) !void {
        if (std.io.is_async) {
            return await @asyncCall(self.stack_frame, {},
                self.processResponseFn, self, request, response);
        } else {
            try self.processResponseFn(self, request, response);
        }
    }

    processRequestFn: fn(self: *Middleware,
        request: *web.HttpRequest, response: *web.HttpResponse) anyerror!bool,
    processResponseFn: fn(self: *Middleware,
         request: *web.HttpRequest, response: *web.HttpResponse) anyerror!void,
};

