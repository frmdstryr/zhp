const std = @import("std");
const web = @import("zhp").web;

pub const io_mode = .evented;

const MainHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *MainHandler, response: *web.HttpResponse) !void {
        try response.headers.put("Content-Type", "text/plain");
        try response.stream.write("Hello, World!");
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
    std.event.Loop.instance.?.beginOneEvent();

    var allocator = &std.heap.ArenaAllocator.init(std.heap.page_allocator).allocator;
    var routes = [_]web.Route{
        web.Route.create("home", "/", MainHandler),
        web.Route.create("json", "/json/", JsonHandler),
        web.Route.create("error", "/500/", ErrorTestHandler),
    };
    var app = web.Application.init(.{
        .allocator=allocator,
        .routes=routes[0..],
    });
    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}
