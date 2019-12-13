const std = @import("std");
const web = @import("web.zig");
const responses = @import("status.zig");


pub const ServerErrorHandler = struct {
    handler: web.RequestHandler,

    pub fn dispatch(self: *ServerErrorHandler, response: *web.HttpResponse) anyerror!void {
        response.status = responses.INTERNAL_SERVER_ERROR;
        try response.body.resize(0);

        if (@errorReturnTrace()) |trace| {
            try response.stream.write("<h1>Server Error</h1>");
            //std.debug.dumpStackTrace(trace.*);

            try response.stream.print(
                "<h3>Request</h3><pre>{}</pre>", .{response.request});
            try response.stream.write("<h3>Error Trace</h3><pre>");
            try std.debug.writeStackTrace(
                trace.*,
                &response.stream,
                self.handler.application.allocator,
                try std.debug.getSelfDebugInfo(),
                false);
            try response.stream.write("</pre>");
        } else {
            try response.stream.write("<h1>Server Error</h1>");
        }
    }

};

pub const NotFoundHandler = struct {
    handler: web.RequestHandler,
    pub fn dispatch(self: *NotFoundHandler, response: *web.HttpResponse) !void {
        response.status = responses.NOT_FOUND;
        try response.stream.write("<h1>Not Found</h1>");
    }

};

