# ZHP

[![Build Status](https://travis-ci.org/frmdstryr/zhp.svg?branch=master)](https://travis-ci.org/frmdstryr/zhp)

A Http server written in [Zig](https://ziglang.org/).  It uses a zero-copy
parser and aims to compete with these [parser_benchmarks](https://github.com/rust-bakery/parser_benchmarks/tree/master/http).

See how it compares in the [http benchmarks](https://gist.github.com/kprotty/3f369f46293a421f09190b829cfb48f7#file-newresults-md)
done by kprotty.

It's a work in progress... feel free to contribute!


### Demo

I deployed this at [https://zhp.codelv.com](https://zhp.codelv.com) if you
want to try it out.

> Note: If you try to benchmark the server it'll ban you, please run it locally
> or on your own server to do benchmarks.

To make and deploy your own app see:
- [demo project](https://github.com/frmdstryr/zhp-demo)
- [zig buildpack](https://github.com/frmdstryr/zig-buildpack)


### Example

```zig
const std = @import("std");
const web = @import("zhp").web;

pub const io_mode = .evented;

const MainHandler = struct {
    handler: web.RequestHandler,

    pub fn get(self: *MainHandler, request: *web.Request, response: *web.Response) !void {
        try response.headers.put("Content-Type", "text/plain");
        try response.stream.write("Hello, World!");
    }

};


pub fn main() anyerror!void {
    const routes = [_]web.Route{
        web.Route.create("home", "/", MainHandler),
    };

    var app = web.Application.init(.{
        .routes=routes[0..],
    });
    defer app.deinit();
    try app.listen("127.0.0.1", 9000);
    try app.start();
}

```
