const std = @import("std");
const web = @import("zhp").web;

pub const io_mode = .evented;

const MainHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *MainHandler, request: *web.HttpRequest,
               response: *web.HttpResponse) !void {
        try response.headers.put("Content-Type", "text/plain");
        try response.stream.write("Hello, World!");
    }

};

const StreamHandler = struct {
    handler: web.RequestHandler,

    // Dump a random stream of crap
    pub fn get(self: *StreamHandler, request: *web.HttpRequest,
               response: *web.HttpResponse) !void {
        try response.headers.put("Content-Type", "application/octet-stream");
        try response.headers.put("Content-Disposition",
            "attachment; filename=\"random.bin\"");
        //try response.headers.put("Content-Length", "4096000");

        // TODO: Support streamign somehow
        //response.streaming = true;
        var r = std.rand.DefaultPrng.init(765432);
        var buf: [4096]u8 = undefined;
        r.random.bytes(buf[0..]);
        var i: usize = 1000;
        while (i >= 0) : (i -= 1) {
            try response.stream.write(buf[0..]);
        }
        std.debug.warn("Done!\n");
    }

};

const JsonHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *JsonHandler, request: *web.HttpRequest,
               response: *web.HttpResponse) !void {
        try response.headers.put("Content-Type", "application/json");
        // TODO: dump object to json?
        try response.stream.write("{\"message\": \"Hello, World!\"}");
    }

};

const ErrorTestHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *ErrorTestHandler, request: *web.HttpRequest,
               response: *web.HttpResponse) !void {
        try response.stream.write("Do some work");
        return error.Ooops;
    }

};



const FormHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *FormHandler, request: *web.HttpRequest,
               response: *web.HttpResponse) !void {
        try response.stream.write(
            \\<form action="/form/" method="post" enctype="multipart/form-data">
            \\<input type="text" name="description" value="some text">
            \\<input type="file" name="myFile">
            \\<button type="submit">Submit</button>
            \\</form>
        );
    }

    pub fn post(self: *FormHandler, request: *web.HttpRequest,
               response: *web.HttpResponse) !void {
        try response.stream.write(
            \\<h1>Thanks!</h1>
        );
    }
};


pub fn main() anyerror!void {

    const routes = [_]web.Route{
        web.Route.create("home", "/", MainHandler),
        web.Route.create("json", "/json/", JsonHandler),
        web.Route.create("stream", "/stream/", StreamHandler),
        web.Route.create("error", "/500/", ErrorTestHandler),
        web.Route.create("form", "/form/", FormHandler),
        web.Route.static("static", "/static/"),
    };

    var app = web.Application.init(.{
        .routes=routes[0..],
        .debug=true,
    });
    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}
