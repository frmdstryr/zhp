// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const zhp = @import("zhp");
const web = zhp.web;

pub const io_mode = .evented;

const MainHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *MainHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.headers.append("Content-Type", "text/plain");
        try response.stream.writeAll("Hello, World!");
    }

};

const StreamHandler = struct {
    handler: web.RequestHandler,

    // Dump a random stream of crap
    pub fn get(self: *StreamHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.headers.append("Content-Type", "text/plain");
        //try response.headers.append("Content-Disposition",
        //    "attachment; filename=\"stream.txt\"");

        // This will cause the application to send the headers
        // then invoke the stream function which can send an unlimited
        // amount of data
        response.send_stream = true;
    }

    pub fn stream(self: *StreamHandler, io: *web.IOStream) !usize {
        defer io.close();
        var total_wrote: usize = 0;
        var i: usize = 0;
        var writer = io.writer();
        while (i < 10) : (i += 1) {
            // Copy directly to output buffer

            try writer.print("{}\n", .{"Hello world"});
            try io.flush(); // Send it out the pipe
            //total_wrote += io.out_buffer.len;

            // Simulate doing something...
            // TODO: Non blocking?
            std.time.sleep(1*std.time.ns_per_s);
        }
        return total_wrote;
    }

};


const TemplateHandler = struct {
    handler: web.RequestHandler,
    const template = @embedFile("templates/cover.html");

    pub fn get(self: *TemplateHandler, request: *web.Request,
               response: *web.Response) !void {
        @setEvalBranchQuota(100000);
        try response.stream.print(template, .{"ZHP"});
    }

};

const JsonHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *JsonHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.headers.append("Content-Type", "application/json");

        var jw = std.json.writeStream(response.stream, 4);
        try jw.beginObject();
        for (request.headers.headers.items) |h| {
            try jw.objectField(h.key);
            try jw.emitString(h.value);
        }
        try jw.endObject();
    }

};

const ErrorTestHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *ErrorTestHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.stream.writeAll("Do some work");
        return error.Ooops;
    }

};


const FormHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *FormHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.stream.writeAll(
            \\<form action="/form/" method="post" enctype="multipart/form-data">
            \\<input type="text" name="name" value="Your name"><br />
            \\<input type="checkbox" name="agree" /><label>Do you like Zig?</label><br />
            \\<input type="file" name="image" /><label>Upload</label><br />
            \\<button type="submit">Submit</button>
            \\</form>
        );
    }

    pub fn post(self: *FormHandler, request: *web.Request,
               response: *web.Response) !void {
        var content_type = request.headers.get("Content-Type") catch |err| switch (err) {
            error.KeyError => "",
            else => return err,
        };
        if (std.mem.startsWith(u8, content_type, "multipart/form-data")) {
            var form = web.forms.Form.init(response.allocator);
            try form.parse(request);
            try response.stream.print(
                \\<h1>Hello: {}</h1>
                , .{if (form.fields.get("name")) |name| name else ""}
            );

            if (form.fields.get("agree")) |f| {
                try response.stream.writeAll("Me too!");
            } else {
                try response.stream.writeAll("Aww sorry!");
            }

            try response.stream.print(
                \\<h1>Request: {}</h1>
                , .{request.body});
        } else {
            response.status = web.responses.BAD_REQUEST;
            try response.stream.writeAll("<h1>BAD REQUEST</h1>");
            return;
        }
    }
};


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = &gpa.allocator;

    const routes = &[_]web.Route{
        web.Route.create("cover", "/", TemplateHandler),
        web.Route.create("hello", "/hello", MainHandler),
        web.Route.create("json", "/json/", JsonHandler),
        web.Route.create("stream", "/stream/", StreamHandler),
        web.Route.create("error", "/500/", ErrorTestHandler),
        web.Route.create("form", "/form/", FormHandler),
        web.Route.static("static", "/static/"),
    };

    var app = web.Application.init(.{
        .allocator=allocator,
        .routes=routes[0..],
        //.debug=true,
    });

    // Logger
    var logger = zhp.middleware.LoggingMiddleware{};
    //try app.middleware.append(&logger.middleware);

    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}
