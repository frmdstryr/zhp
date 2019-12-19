const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const web = @import("web.zig");
const responses = @import("status.zig");
const mimetypes = @import("mimetypes.zig");
const Datetime = @import("time/datetime.zig").Datetime;


pub const ServerErrorHandler = struct {
    handler: web.RequestHandler,

    pub fn dispatch(self: *ServerErrorHandler, request: *web.HttpRequest,
                    response: *web.HttpResponse) anyerror!void {
        response.status = responses.INTERNAL_SERVER_ERROR;
        try response.body.resize(0);

        if (@errorReturnTrace()) |trace| {
            try response.stream.write("<h1>Server Error</h1>");
            //std.debug.dumpStackTrace(trace.*);

            try response.stream.print(
                "<h3>Request</h3><pre>{}</pre>", .{request});
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
    pub fn dispatch(self: *NotFoundHandler, request: *web.HttpRequest,
                    response: *web.HttpResponse) !void {
        response.status = responses.NOT_FOUND;
        try response.stream.write("<h1>Not Found</h1>");
    }

};


pub fn StaticFileHandler(comptime static_url: []const u8,
                         comptime static_root: []const u8) type {
    if (!fs.path.isAbsolute(static_url)) {
        @compileError("Url use relative paths");
    }
    // TODO: Should the root be checked if it exists?
    return  struct {
        handler: web.RequestHandler,
        const Self = @This();

        pub fn get(self: *Self, request: *web.HttpRequest,
                   response: *web.HttpResponse) !void {
            const allocator = response.allocator;

            // Determine path relative to the url root
            const rel_path = try fs.path.relative(
                allocator, static_url, request.path);

            //std.debug.warn("Rel path {}\n", .{rel_path});

            // Cannot be outside the root folder
            if (rel_path.len == 0 or rel_path[0] == '.') {
                return self.renderNotFound(response);
            }

            const full_path = try fs.path.join(allocator, &[_][]const u8{
                static_root, rel_path
            });

            //std.debug.warn("Full path {}\n", .{full_path});

            const file = fs.File.openRead(full_path) catch |err| {
                // TODO: Handle debug page
                // std.debug.warn("Static fille error: {}\n", .{err});
                return self.renderNotFound(response);
            };

            // Get file info
            const stat = try file.stat();

            // TODO: Determine actual content type
            const content_type = mimetypes.guessFromFilename(full_path)
                orelse "application/octet-stream";
            try response.headers.put("Content-Type", content_type);

            // Set last modified time for caching purposes
            try response.headers.put("Last-Modified",
                try Datetime.formatHttpFromModifiedDate(allocator, stat.mtime));

            const range_header = request.headers.getDefault("Range", "");
            if (range_header.len > 0) {
                // TODO: Parse range header
                // As per RFC 2616 14.16, if an invalid Range header is specified,
                // the request will be treated as if the header didn't exist.
                // response.status = responses.PARTIAL_CONTENT;
            }

            response.status = responses.OK;
            response.body.len = stat.size; // This sets the content length
            response.source_stream = file.inStream();
        }

        pub fn renderNotFound(self: *Self, response: *web.HttpResponse) !void {
            response.status = responses.NOT_FOUND;
            try response.stream.write("<h1>Not Found</h1>");
        }

    };
}
