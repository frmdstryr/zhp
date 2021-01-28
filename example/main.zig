// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const web = @import("zhp");
const Request = web.Request;
const Response = web.Response;


var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub const io_mode = .evented;
//pub const log_level = .info;


/// This handler demonstrates how to send a template resrponse using
/// zig's built-in formatting.
const TemplateHandler = struct {
    const template = @embedFile("templates/cover.html");

    pub fn get(self: *TemplateHandler, req: *Request, resp: *Response) !void {
        @setEvalBranchQuota(100000);
        try resp.stream.print(template, .{"ZHP"});
    }

};


/// This handler demonstrates how to set headers and
/// write to the response stream. The response stream is buffered.
/// in memory until the handler completes.
const HelloHandler = struct {
    pub fn get(self: *HelloHandler, req: *Request, resp: *Response) !void {
        try resp.headers.append("Content-Type", "text/plain");
        try resp.stream.writeAll("Hello, World!");
    }

};


/// This handler demonstrates how to send a streaming response.
/// since ZHP buffers the handler output use `send_stream = true` to tell
/// it to invoke the stream method to complete the response.
const StreamHandler = struct {
    const template = @embedFile("templates/stream.html");
    allocator: ?*std.mem.Allocator = null,

    pub fn get(self: *StreamHandler, req: *Request, resp: *Response) !void {
        if (std.mem.eql(u8, req.path, "/stream/live/")) {
            try resp.headers.append("Content-Type", "audio/mpeg");
            try resp.headers.append("Cache-Control", "no-cache");

            // This tells the framework to invoke stream fn after sending the
            // headers
            resp.send_stream = true;
            self.allocator = resp.allocator;
        } else {
            try resp.stream.writeAll(template);
        }
    }

    pub fn stream(self: *StreamHandler, io: *web.IOStream) !usize {
        std.log.info("Starting audio stream", .{});
        const n = self.forward(io) catch |err| {
            std.log.info("Error streaming: {s}", .{err});
            return 0;
        };
        return n;
    }

    fn forward(self: *StreamHandler, io: *web.IOStream) !usize {
        const writer = io.writer();
        std.debug.assert(self.allocator != null);
        const a = self.allocator.?;
        // http://streams.sevenfm.nl/live

        std.log.info("Connecting...", .{});
        const conn = try std.net.tcpConnectToHost(a, "streams.sevenfm.nl", 80);
        defer conn.close();
        std.log.info("Connected!", .{});
        try conn.writer().writeAll(
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


/// This handler shows how to read headers and cookies from the request.
/// It also shows another way to write to the response stream.
/// Finally it shows one way to use "static" storage that persists between
/// requests.
const JsonHandler = struct {
    // Static storage
    var counter = std.atomic.Int(usize).init(0);

    pub fn get(self: *JsonHandler, req: *Request, resp: *Response) !void {
        try resp.headers.append("Content-Type", "application/json");

        var jw = std.json.writeStream(resp.stream, 4);
        try jw.beginObject();
        for (req.headers.headers.items) |h| {
            try jw.objectField(h.key);
            try jw.emitString(h.value);
        }

        // Cookies aren't parsed by default
        // If you know they're parsed (eg by middleware) you can just
        // use request.cookies directly
        if (try req.readCookies()) |cookies| {
            try jw.objectField("Cookie");
            try jw.beginObject();
            for (cookies.cookies.items) |c| {
                try jw.objectField(c.key);
                try jw.emitString(c.value);
            }
            try jw.endObject();
        }

        try jw.objectField("Request-Count");
        try jw.emitNumber(counter.fetchAdd(1));

        try jw.endObject();
    }

};


/// This handler demonstrates how to use url arguments. The
/// `request.args` is the result of ctregex's parsing of the url.
const ApiHandler = struct {
    pub fn get(self: *ApiHandler, req: *Request, resp: *Response) !void {
        try resp.headers.append("Content-Type", "application/json");

        var jw = std.json.writeStream(resp.stream, 4);
        try jw.beginObject();
        const args = req.args.?;
        try jw.objectField(args[0].?);
        try jw.emitString(args[1].?);
        try jw.endObject();
    }

};


/// When an error is returned the framework will return the error handler response
const ErrorTestHandler = struct {
    pub fn get(self: *ErrorTestHandler, req: *Request, resp: *Response) !void {
        try resp.stream.writeAll("Do some work");
        return error.Ooops;
    }

};


/// Redirect shortcut
const RedirectHandler = struct {
    // Shows how to redirect
    pub fn get(self: *RedirectHandler, req: *Request, resp: *Response) !void {
        // Redirect to home
        try resp.redirect("/");
    }

};


/// Work in progress... shows one way to render and post a form.
const FormHandler = struct {
    const template = @embedFile("templates/form.html");
    const key = "{% form %}";
    const start = std.mem.indexOf(u8, template, key).?;
    const end = start + key.len;

    pub fn get(self: *FormHandler, req: *Request, resp: *Response) !void {
        // Split the template on the key
        const form =
        \\<form action="/form/" method="post" enctype="multipart/form-data">
            \\<input type="text" name="name" value="Your name"><br />
            \\<input type="checkbox" name="agree" /><label>Do you like Zig?</label><br />
            \\<input type="file" name="image" /><label>Upload</label><br />
            \\<button type="submit">Submit</button>
        \\</form>
        ;
        try resp.stream.writeAll(template[0..start]);
        try resp.stream.writeAll(form);
        try resp.stream.writeAll(template[end..]);
    }

    pub fn post(self: *FormHandler, req: *Request, resp: *Response) !void {
        var content_type = req.headers.getDefault("Content-Type", "");
        if (std.mem.startsWith(u8, content_type, "multipart/form-data")) {
            var form = web.forms.Form.init(resp.allocator);
            form.parse(req) catch |err| switch (err) {
                error.NotImplemented => {
                    resp.status = web.responses.REQUEST_ENTITY_TOO_LARGE;
                    try resp.stream.writeAll("TODO: Handle large uploads");
                    return;
                },
                else => return err,
            };
            try resp.stream.writeAll(template[0..start]);

            try resp.stream.print(
                \\<h1>Hello: {s}</h1>
                , .{if (form.fields.get("name")) |name| name else ""}
            );

            if (form.fields.get("agree")) |f| {
                try resp.stream.writeAll("Me too!");
            } else {
                try resp.stream.writeAll("Aww sorry!");
            }
            try resp.stream.writeAll(template[end..]);
        } else {
            resp.status = web.responses.BAD_REQUEST;
        }
    }
};



const ChatHandler = struct {
    const template = @embedFile("templates/chat.html");
    pub fn get(self: *ChatHandler, req: *Request, resp: *Response) !void {
        try resp.stream.writeAll(template);
    }
};


/// Demonstrates the useage of the websocket protocol
const ChatWebsocketHandler = struct {
    var client_id = std.atomic.Int(usize).init(0);
    var chat_handlers = std.ArrayList(*ChatWebsocketHandler).init(&gpa.allocator);

    websocket: web.Websocket,
    stream: ?web.websocket.Writer(1024, .Text) = null,
    username: []const u8 = "",

    pub fn connected(self: *ChatWebsocketHandler) !void {
        std.log.debug("Websocket connected!", .{});

        // Initialze the stream
        self.stream = self.websocket.writer(1024, .Text);
        const stream = &self.stream.?;

        var jw = std.json.writeStream(stream.writer(), 4);
        try jw.beginObject();
        try jw.objectField("type");
        try jw.emitString("id");
        try jw.objectField("id");
        try jw.emitNumber(client_id.fetchAdd(1));
        try jw.objectField("date");
        try jw.emitNumber(std.time.milliTimestamp());
        try jw.endObject();
        try stream.flush();

        try chat_handlers.append(self);
    }

    pub fn onMessage(self: *ChatWebsocketHandler, message: []const u8, binary: bool) !void {
        std.log.debug("Websocket message: {s}", .{message});
        const allocator = self.websocket.response.allocator;
        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();
        var obj = try parser.parse(message);
        defer obj.deinit();
        const msg = obj.root.Object;
        const t = msg.get("type").?.String;
        if (std.mem.eql(u8, t, "message")) {
            try self.sendMessage(self.username, msg.get("text").?.String);
        } else if (std.mem.eql(u8, t, "username")) {
            self.username = try std.mem.dupe(allocator, u8, msg.get("name").?.String);
            try self.sendUserList();
        }
    }

    pub fn sendUserList(self: *ChatWebsocketHandler) !void {
        const t = std.time.milliTimestamp();
        for (chat_handlers.items) |handler| {
            const stream = &handler.stream.?;
            var jw = std.json.writeStream(stream.writer(), 4);
            try jw.beginObject();
            try jw.objectField("type");
            try jw.emitString("userlist");
            try jw.objectField("users");
            try jw.beginArray();
            for (chat_handlers.items) |obj| {
                try jw.arrayElem();
                try jw.emitString(obj.username);
            }
            try jw.endArray();
            try jw.objectField("date");
            try jw.emitNumber(t);
            try jw.endObject();
            try stream.flush();
        }
    }

    pub fn sendMessage(self: *ChatWebsocketHandler, name: []const u8, message: []const u8) !void {
        const t = std.time.milliTimestamp();
        for (chat_handlers.items) |handler| {
            const stream = &handler.stream.?;
            var jw = std.json.writeStream(stream.writer(), 4);
            try jw.beginObject();
            try jw.objectField("type");
            try jw.emitString("message");
            try jw.objectField("text");
            try jw.emitString(message);
            try jw.objectField("name");
            try jw.emitString(name);
            try jw.objectField("date");
            try jw.emitNumber(t);
            try jw.endObject();
            try stream.flush();
        }
    }

    pub fn disconnected(self: *ChatWebsocketHandler) !void {
        if (self.websocket.err) |err| {
            std.log.debug("Websocket error: {s}", .{err});
        } else {
            std.log.debug("Websocket closed!", .{});
        }

        for (chat_handlers.items) |handler, i| {
            if (handler == self) {
                _ = chat_handlers.swapRemove(i);
                break;
            }
        }
    }
};


// The routes must be defined in the "root"
pub const routes = [_]web.Route{
    web.Route.create("cover", "/", TemplateHandler),
    web.Route.create("hello", "/hello", HelloHandler),
    web.Route.create("api", "/api/([a-z]+)/(\\d+)/", ApiHandler),
    web.Route.create("json", "/json/", JsonHandler),
    web.Route.create("stream", "/stream/", StreamHandler),
    web.Route.create("stream-media", "/stream/live/", StreamHandler),
    web.Route.create("redirect", "/redirect/", RedirectHandler),
    web.Route.create("error", "/500/", ErrorTestHandler),
    web.Route.create("form", "/form/", FormHandler),
    web.Route.create("chat", "/chat/", ChatHandler),
    web.Route.websocket("websocket", "/chat/ws/", ChatWebsocketHandler),
    web.Route.static("static", "/static/", "example/static/"),
};


pub const middleware = [_]web.Middleware{
    //web.Middleware.create(web.middleware.LoggingMiddleware),
};

pub fn main() !void {
    defer std.debug.assert(!gpa.deinit());
    const allocator = &gpa.allocator;

    var app = web.Application.init(allocator, .{.debug=true});

    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}
