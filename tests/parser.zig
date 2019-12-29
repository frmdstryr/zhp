// Run with
// zig run --pkg-begin zhp lib/zhp/zhp.zig --pkg-end --release-safe tests/parser.zig
//
const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const web = @import("zhp").web;

pub const io_mode = .evented;

const Test = struct {
    path: []const u8,
    count: usize,
};

const tests = [_]Test{
    .{.path="tests/http-requests.txt", .count=55},
    .{.path="tests/bigger.txt", .count=275},
};

pub fn main() !void {
    var timer = try std.time.Timer.start();
    for (tests) |t| {
        std.debug.warn("Parsing {}...", .{t.path});
        var file = try fs.File.openRead(t.path);
        timer.reset();
        const cnt = try parseRequests(file);
        std.debug.warn("Done! ({} ns)\n", .{timer.read()});
        std.testing.expectEqual(t.count, cnt);
    }
}

pub fn parseRequests(file: fs.File) !usize {
    const allocator = std.heap.direct_allocator;
    var stream = try web.IOStream.initCapacity(allocator, file, 0, 4096);
    defer stream.deinit();
    var request = try web.Request.init(allocator);
    defer request.deinit();
    var cnt: usize = 0;
    while (true) {
        cnt += 1;
        std.debug.warn("Parsing: {}\n", .{cnt});
        defer request.reset();
        var n = request.parse(&stream) catch |err| switch (err) {
            error.EndOfStream,
            error.ConnectionResetByPeer => break,
            else => {
                std.debug.warn("Error parsing: {}\n", .{
                    stream.in_buffer[stream.readCount()..]});
                return err;
            },
        };
    }
    return cnt;
}
