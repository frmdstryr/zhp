// This is the original file written by andrewrk in his chat demo
// on youtube
const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;

const zhp = @import("zhp");
const web = zhp.web;

pub const io_mode = .evented;

const MainHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *MainHandler, response: *web.HttpResponse) !void {
        try response.headers.put("Content-Type", "text/plain");
        try response.body.append("Hello, World!");
    }

};

pub fn main() anyerror!void {
    //var buf: [10 * 1024 * 1024]u8 = undefined;
    var allocator = &std.heap.ArenaAllocator.init(std.heap.page_allocator).allocator;
    var routes = [_]web.Route{
        web.Route.create("home", "/", MainHandler),
    };
    var app = web.Application.init(.{
        .allocator=allocator,
        .routes=routes[0..],
    });
    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}
