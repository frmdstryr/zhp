// Run with
// zig run --pkg-begin zhp lib/zhp/zhp.zig --pkg-end -OReleaseSafe tests/parser.zig
//
const std = @import("std");
const net = std.net;
const fs = std.fs;
const os = std.os;
const web = @import("zhp");

pub const io_mode = .evented;

const Test = struct {
    path: []const u8,
    count: usize,
};

const tests = [_]Test{
    .{.path="tests/http-requests.txt", .count=55},
    .{.path="tests/bigger.txt", .count=275},
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = &gpa.allocator;

pub fn main() !void {
    defer std.debug.assert(!gpa.deinit());
    var timer = try std.time.Timer.start();
    for (tests) |t| {
        std.debug.warn("Parsing {}...", .{t.path});
        var file = try fs.cwd().openFile(t.path, .{});
        timer.reset();
        const cnt = try parseRequests(file);
        std.debug.warn("Done! ({} ns)\n", .{timer.read()});
        std.testing.expectEqual(t.count, cnt);
    }
}

pub fn parseRequests(file: fs.File) !usize {
    var stream = try web.IOStream.initCapacity(allocator, file, 0, 4096);
    defer stream.deinit();
    var request = try web.Request.initCapacity(allocator, 1024*10, 32);
    defer request.deinit();
    var cnt: usize = 0;
    var end: usize = 0;
    while (true) {
        cnt += 1;
        defer request.reset();
        var n = request.parse(&stream, .{}) catch |err| switch (err) {
            error.EndOfStream, error.BrokenPipe,
            error.ConnectionResetByPeer => break,
            else => {
                std.debug.warn("Stream {}:\n'{}'\n", .{
                    end, stream.in_buffer[0..end]});
                std.debug.warn("Error parsing:\n'{}'\n", .{
                    request.buffer.items[0..stream.readCount()]});
                return err;
            },
        };
        //std.debug.warn("{}\n", .{request});
        end = stream.readCount();
    }
    return cnt;
}
