const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;

pub const io_mode = .evented;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = &gpa.allocator;

pub fn main() anyerror!void {
    const req_listen_addr = try net.Address.parseIp4("127.0.0.1", 9000);
    defer std.debug.assert(!gpa.deinit());

    // Ignore sigpipe
    var act = os.Sigaction{
        .handler = .{.sigaction = os.SIG_IGN },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    os.sigaction(os.SIGPIPE, &act, null);

    var server = net.StreamServer.init(.{.reuse_address=true});
    defer server.close();
    defer server.deinit();

    try server.listen(req_listen_addr);

    std.log.warn("Listening at {}\n", .{server.listen_address});

    while (true) {
        const conn = try server.accept();
        std.log.warn("{}\n", .{conn});
        const frame = try allocator.create(@Frame(serve));
        frame.* = async serve(conn);
        // Don't wait!
    }
}

pub fn serve(conn: net.StreamServer.Connection) !void {
    defer conn.stream.close();
    handleConn(conn) catch |err| {
        std.log.warn("Disconnected {}: {}\n", .{conn, err});
    };
}

pub fn handleConn(conn: net.StreamServer.Connection) !void {
    var reader = conn.stream.reader();
    var writer = conn.stream.writer();
    var buf: [64*1024]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        var it = std.mem.split(buf[0..n], "\r\n\r\n");
        while (it.next()) |req| {
            try writer.writeAll(
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
}
