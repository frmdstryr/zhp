// Run with
// zig run --pkg-begin zhp lib/zhp/zhp.zig --pkg-end --release-fast tests/basic.zig
//
const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const web = @import("zhp").web;

pub const io_mode = .evented;


pub fn main() anyerror!void {
    const allocator = std.heap.direct_allocator;
    const req_listen_addr = try net.Address.parseIp4("127.0.0.1", 9000);

    var server = net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(req_listen_addr);

    std.debug.warn("listening at {}\n", .{server.listen_address});


    while (true) {
        const frame = try allocator.create(@Frame(handleConn));
        const conn = try server.accept();
        frame.* = async handleConn(conn);
    }
}

pub fn handleConn(conn: net.StreamServer.Connection) !void {
    //std.debug.warn("connected to {}\n", .{conn.address});
    const allocator = std.heap.direct_allocator;
    var stream = try web.IOStream.initCapacity(allocator, conn.file, 0, 4096);
    defer stream.deinit();
    var request = try web.Request.init(allocator);
    defer request.deinit();
    var cnt: usize = 0;
    while (true) {
        cnt += 1;
        defer request.reset();
        var n = request.parse(&stream) catch |err| switch (err) {
            error.EndOfStream,
            error.ConnectionResetByPeer => break,
            else => return err,
        };

        try conn.file.write(
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 15\r\n" ++
            "Connection: keep-alive\r\n" ++
            "Content-Type: text/plain; charset=UTF-8\r\n" ++
            "Server: Example\r\n" ++
            "Date: Wed, 17 Apr 2013 12:00:00 GMT\r\n" ++
            "\r\n" ++
            "Hello, World!\r\n" ++
            "\r\n"
        );
    }
}


