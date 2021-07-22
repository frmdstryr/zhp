// Run with
// zig run --pkg-begin zhp src/zhp.zig --pkg-begin ctregex src/bundled_depends/ctregex/ctregex.zig --pkg-end --pkg-begin datetime src/bundled_depends/datetime/datetime.zig --pkg-end --pkg-end -OReleaseSafe tests/basic.zig
//
const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const web = @import("zhp");

pub const io_mode = .evented;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = &gpa.allocator;

pub fn main() anyerror!void {
    const req_listen_addr = try net.Address.parseIp4("127.0.0.1", 9000);
    defer std.debug.assert(!gpa.deinit());

    var server = net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(req_listen_addr);

    std.debug.warn("Listening at {}\n", .{server.listen_address});


    while (true) {
        const conn = try server.accept();
        std.debug.warn("Connected to {}\n", .{conn.address});
        var frame = async handleConn(conn);
        await frame catch |err| {
            std.debug.warn("Disconnected {}: {}\n", .{conn.address, err});
        };
    }
}

pub fn handleConn(conn: net.StreamServer.Connection) !void {
    var stream = try web.IOStream.initCapacity(allocator, conn.file, 0, 4096);
    defer stream.deinit();
    var request = try web.Request.initCapacity(allocator, 1024*10, 32, 32);
    defer request.deinit();
    var cnt: usize = 0;
    while (true) {
        cnt += 1;
        defer request.reset();
        request.parse(&stream, .{}) catch |err| switch (err) {
            error.EndOfStream, error.BrokenPipe,
            error.ConnectionResetByPeer => break,
            else => return err,
        };

        try conn.file.writeAll(
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
    return error.ClosedCleanly;
}


