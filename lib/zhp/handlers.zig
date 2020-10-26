// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const log = std.log;
const web = @import("web.zig");
const responses = @import("status.zig");
const Datetime = @import("time/datetime.zig").Datetime;

pub var default_stylesheet = @embedFile("templates/style.css");



pub const ServerErrorHandler = struct {
    handler: web.RequestHandler,
    const template = @embedFile("templates/error.html");
    pub fn dispatch(self: *ServerErrorHandler, request: *web.Request,
                    response: *web.Response) anyerror!void {
        response.status = responses.INTERNAL_SERVER_ERROR;

        // Clear any existing data
        try response.body.resize(0);

        // Split the template on the key
        comptime const key = "{% stacktrace %}";
        comptime const start = mem.indexOf(u8, template, key).?;
        comptime const end = start + key.len;
        //@breakpoint();


        if (self.handler.application.options.debug) {
            // Send it
            try response.stream.print(template[0..start], .{default_stylesheet});

            // Dump stack trace
            if (self.handler.err) |err| {
                try response.stream.print("error: {}\n", .{@errorName(err)});
            }
            if (@errorReturnTrace()) |trace| {
                try std.debug.writeStackTrace(
                    trace.*,
                    &response.stream,
                    response.allocator,
                    try std.debug.getSelfDebugInfo(),
                    .no_color);
            }

            // Dump request and end of page
            try response.stream.print(template[end..], .{request});
        } else {
            if (@errorReturnTrace()) |trace| {
                const stderr = std.io.getStdErr().writer();
                const held = std.debug.getStderrMutex().acquire();
                defer held.release();

                try std.debug.writeStackTrace(
                    trace.*,
                    &stderr,
                    response.allocator,
                    try std.debug.getSelfDebugInfo(),
                    std.debug.detectTTYConfig());
            }

            try response.stream.writeAll("<h1>Server Error</h1>");
        }
    }

};

pub const NotFoundHandler = struct {
    handler: web.RequestHandler,
    const template = @embedFile("templates/not-found.html");
    pub fn dispatch(self: *NotFoundHandler, request: *web.Request,
                    response: *web.Response) !void {
        response.status = responses.NOT_FOUND;
        try response.stream.print(template, .{default_stylesheet});
    }

};


pub fn StaticFileHandler(comptime static_url: []const u8,
                         comptime static_root: []const u8) type {
    if (!fs.path.isAbsolute(static_url)) {
        @compileError("The static url must be absolute");
    }
    // TODO: Should the root be checked if it exists?
    return  struct {
        const Self = @This();
        handler: web.RequestHandler,
        file: ?fs.File = null,

        pub fn get(self: *Self, request: *web.Request,
                   response: *web.Response) !void {
            const allocator = response.allocator;
            const mimetypes = &self.handler.application.mimetypes;

            // Determine path relative to the url root
            const rel_path = try fs.path.relative(
                allocator, static_url, request.path);

            // Cannot be outside the root folder
            if (rel_path.len == 0 or rel_path[0] == '.') {
                return self.renderNotFound(request, response);
            }

            const full_path = try fs.path.join(allocator, &[_][]const u8{
                static_root, rel_path
            });

            const file = fs.cwd().openFile(full_path, .{.read=true}) catch |err| {
                // TODO: Handle debug page
                //log.warn("Static file error: {}", .{err});
                return self.renderNotFound(request, response);
            };

            // Get file info
            const stat = try file.stat();

            // TODO: Determine actual content type
            const content_type = mimetypes.getTypeFromFilename(full_path)
                orelse "application/octet-stream";
            try response.headers.append("Content-Type", content_type);

            // Set last modified time for caching purposes
            try response.headers.append("Last-Modified",
                try Datetime.formatHttpFromModifiedDate(allocator, stat.mtime));

            const range_header = request.headers.getDefault("Range", "");
            if (range_header.len > 0) {
                // TODO: Parse range header
                // As per RFC 2616 14.16, if an invalid Range header is specified,
                // the request will be treated as if the header didn't exist.
                // response.status = responses.PARTIAL_CONTENT;
            }

            response.status = responses.OK;
            var l = try std.fmt.allocPrint(response.allocator, "{}", .{stat.size});
            try response.headers.append("Content-Length", l);
            self.file = file;
            response.send_stream = true;
        }

        pub fn stream(self: *Self, io: *web.IOStream) !usize {
            var total_wrote: usize = 0;
            if (self.file) |file| {
                defer file.close();
                total_wrote = try io.writeFromReader(file.reader());
            }
            return total_wrote;
        }

        pub fn renderNotFound(self: *Self, request: *web.Request, response: *web.Response) !void {
            var handler = NotFoundHandler{.handler=self.handler};
            try handler.dispatch(request, response);
        }

    };
}
