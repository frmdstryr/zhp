// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const web = @import("zhp");

pub const io_mode = .evented;
pub const log_level = .info;

const MainHandler = struct {
    pub fn get(self: *MainHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.headers.append("Content-Type", "text/plain");
        try response.stream.writeAll("Hello, World!");
    }

};

const StreamHandler = struct {
    const template = @embedFile("templates/stream.html");
    allocator: ?*std.mem.Allocator = null,

    // Dump a random stream of crap
    pub fn get(self: *StreamHandler, request: *web.Request,
               response: *web.Response) !void {
        if (std.mem.eql(u8, request.path, "/stream/live/")) {
            try response.headers.append("Content-Type", "audio/mpeg");
            try response.headers.append("Cache-Control", "no-cache");
            response.send_stream = true;
            self.allocator = response.allocator;
        } else {
            try response.stream.writeAll(template);
        }
    }

    pub fn stream(self: *StreamHandler, io: *web.IOStream) !usize {
        std.log.info("Starting audio stream", .{});
        const n = self.forward(io) catch |err| {
            std.log.info("Error streaming: {}", .{err});
            return 0;
        };
        return n;
    }

    pub fn forward(self: *StreamHandler, io: *web.IOStream) !usize {
        const writer = io.writer();
        std.debug.assert(self.allocator != null);
        const a = self.allocator.?;
        // http://streams.sevenfm.nl/live

        std.log.info("Connecting...", .{});
        const conn = try std.net.tcpConnectToHost(a, "streams.sevenfm.nl", 80);
        defer conn.close();
        std.log.info("Connected!", .{});
        try conn.writeAll(
            "GET /live HTTP/1.1\r\n" ++
            "Host: streams.sevenfm.nl\r\n" ++
            "Accept: */*\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n");

        var buf: [4096]u8 = undefined;
        var total_sent: usize = 0;

        // On the first response skip their server's headers
        // but include the icecast stream headers from their response
        const end = try conn.read(buf[0..]);
        const offset = if (std.mem.indexOf(u8, buf[0..end], "icy-br:")) |o| o else 0;
        try writer.writeAll(buf[offset..end]);
        total_sent += end-offset;

        // Now just forward the stream data
        while (true) {
            const n = try conn.read(buf[0..]);
            if (n == 0) {
                std.log.info("Stream disconnected", .{});
                break;
            }
            total_sent += n;
            try writer.writeAll(buf[0..n]);
            try io.flush(); // Send it out the pipe
        }
        return total_sent;
    }

};


const TemplateHandler = struct {
    const template = @embedFile("templates/cover.html");

    pub fn get(self: *TemplateHandler, request: *web.Request,
               response: *web.Response) !void {
        @setEvalBranchQuota(100000);
        try response.stream.print(template, .{"ZHP"});
    }

};

const JsonHandler = struct {
    // Static storage
    var counter = std.atomic.Int(usize).init(0);

    pub fn get(self: *JsonHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.headers.append("Content-Type", "application/json");

        var jw = std.json.writeStream(response.stream, 4);
        try jw.beginObject();
        for (request.headers.headers.items) |h| {
            try jw.objectField(h.key);
            try jw.emitString(h.value);
        }
        try jw.objectField("Request-Count");
        try jw.emitNumber(counter.fetchAdd(1));

        try jw.endObject();
    }

};

const ApiHandler = struct {
    pub fn get(self: *ApiHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.headers.append("Content-Type", "application/json");

        var jw = std.json.writeStream(response.stream, 4);
        try jw.beginObject();
        const args = request.args.?;
        try jw.objectField(args[0].?);
        try jw.emitString(args[1].?);
        try jw.endObject();
    }

};

const ErrorTestHandler = struct {
    pub fn get(self: *ErrorTestHandler, request: *web.Request,
               response: *web.Response) !void {
        try response.stream.writeAll("Do some work");
        return error.Ooops;
    }

};

const FormHandler = struct {
    const template = @embedFile("templates/form.html");
    const key = "{% form %}";
    const start = std.mem.indexOf(u8, template, key).?;
    const end = start + key.len;

    pub fn get(self: *FormHandler, request: *web.Request, response: *web.Response) !void {
        // Split the template on the key
        const form =
        \\<form action="/form/" method="post" enctype="multipart/form-data">
            \\<input type="text" name="name" value="Your name"><br />
            \\<input type="checkbox" name="agree" /><label>Do you like Zig?</label><br />
            \\<input type="file" name="image" /><label>Upload</label><br />
            \\<button type="submit">Submit</button>
        \\</form>
        ;
        try response.stream.writeAll(template[0..start]);
        try response.stream.writeAll(form);
        try response.stream.writeAll(template[end..]);
    }

    pub fn post(self: *FormHandler, request: *web.Request,
               response: *web.Response) !void {
        var content_type = request.headers.getDefault("Content-Type", "");
        if (std.mem.startsWith(u8, content_type, "multipart/form-data")) {
            var form = web.forms.Form.init(response.allocator);
            form.parse(request) catch |err| switch (err) {
                error.NotImplemented => {
                    response.status = web.responses.REQUEST_ENTITY_TOO_LARGE;
                    try response.stream.writeAll("TODO: Handle large uploads");
                    return;
                },
                else => return err,
            };
            try response.stream.writeAll(template[0..start]);

            try response.stream.print(
                \\<h1>Hello: {}</h1>
                , .{if (form.fields.get("name")) |name| name else ""}
            );

            if (form.fields.get("agree")) |f| {
                try response.stream.writeAll("Me too!");
            } else {
                try response.stream.writeAll("Aww sorry!");
            }
            try response.stream.writeAll(template[end..]);
        } else {
            response.status = web.responses.BAD_REQUEST;
        }
    }
};

pub const routes = [_]web.Route{
    web.Route.create("cover", "/", TemplateHandler),
    web.Route.create("hello", "/hello", MainHandler),
    web.Route.create("api", "/api/([a-z]+)/(\\d+)/", ApiHandler),
    web.Route.create("json", "/json/", JsonHandler),
    web.Route.create("stream", "/stream/", StreamHandler),
    web.Route.create("stream-media", "/stream/live/", StreamHandler),
    web.Route.create("error", "/500/", ErrorTestHandler),
    web.Route.create("form", "/form/", FormHandler),
    web.Route.static("static", "/static/", "src/static/"),
};


pub const middleware = [_]web.Middleware{
    web.Middleware.create(web.middleware.LoggingMiddleware),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = &gpa.allocator;

    var app = web.Application.init(allocator, .{.debug=true});

    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}
