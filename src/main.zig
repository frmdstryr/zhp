const std = @import("std");
const web = @import("zhp").web;

pub const io_mode = .evented;

const MainHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *MainHandler, response: *web.HttpResponse) !void {
        try response.headers.put("Content-Type", "text/plain");
        try response.body.append("Hello, World!");
    }

};

const StreamHandler = struct {
    handler: web.RequestHandler,

    // Dump a random stream of crap
    pub fn get(self: *StreamHandler, response: *web.HttpResponse) !void {
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

    pub fn get(self: *JsonHandler, response: *web.HttpResponse) !void {
        try response.headers.put("Content-Type", "application/json");
        // TODO: dump object to json?
        try response.stream.write("{\"message\": \"Hello, World!\"}");
    }

};

const ErrorTestHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *ErrorTestHandler, response: *web.HttpResponse) !void {
        try response.stream.write("Do some work");
        return error.Ooops;
    }

};


pub fn main() anyerror!void {
    var routes = [_]web.Route{
        web.Route.create("home", "/", MainHandler),
        web.Route.create("json", "/json/", JsonHandler),
        web.Route.create("stream", "/stream/", StreamHandler),
        web.Route.create("error", "/500/", ErrorTestHandler),
    };
    var app = web.Application.init(.{
        //.allocator=allocator,
        .routes=routes[0..],
    });
    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}
