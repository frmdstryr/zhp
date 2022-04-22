# ZHP

[![status](https://github.com/frmdstryr/zhp/actions/workflows/ci.yml/badge.svg)](https://github.com/frmdstryr/zhp/actions)

A (work in progress) Http server written in [Zig](https://ziglang.org/).

If you have suggestions on improving the design please feel free to comment!

### Features

- A zero-copy parser and aims to compete with these [parser_benchmarks](https://github.com/rust-bakery/parser_benchmarks/tree/master/http)
while still rejecting nonsense requests. It currently runs around ~1000MB/s.
- Regex url routing thanks to [ctregex](https://github.com/alexnask/ctregex.zig)
- Struct based handlers where the method maps to the function name
- A builtin static file handler, error page handler, and not found page handler
- Middleware support
- Parses forms encoded with `multipart/form-data`
- Streaming responses
- Websockets

See how it compares in the [http benchmarks](https://gist.github.com/kprotty/3f369f46293a421f09190b829cfb48f7#file-newresults-md)
done by kprotty (now very old).

It's a work in progress... feel free to contribute!


### Demo

Try out the demo at [https://zhp.codelv.com](https://zhp.codelv.com).

> Note: If you try to benchmark the server it'll ban you, please run it locally
> or on your own server to do benchmarks.

To make and deploy your own app see:
- [demo project](https://github.com/frmdstryr/zhp-demo)
- [zig buildpack](https://github.com/frmdstryr/zig-buildpack)


### Example

See the `example` folder for a more detailed example.

```zig
const std = @import("std");
const web = @import("zhp");

pub const io_mode = .evented;
pub const log_level = .info;

const MainHandler = struct {
    pub fn get(self: *MainHandler, request: *web.Request, response: *web.Response) !void {
        try response.headers.put("Content-Type", "text/plain");
        try response.stream.write("Hello, World!");
    }

};

pub const routes = [_]web.Route{
    web.Route.create("home", "/", MainHandler),
};

pub const middleware = [_]web.Middleware{
    web.Middleware.create(web.middleware.LoggingMiddleware);
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = &gpa.allocator;

    var app = web.Application.init(allocator, .{.debug=true});
    defer app.deinit();

    try app.listen("127.0.0.1", 9000);
    try app.start();
}

```
