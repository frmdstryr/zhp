const std = @import("std");

const server_cmd = [_][]const u8{
    "timeout", "-s", "SIGINT", "15s", "./zig-cache/bin/zhttpd",
};

const wrk_cmd = [_][]const u8{ "docker", "run", "--rm", "--net", "host", "williamyeh/wrk", "-t2", "-c10", "-d10s", "--latency", "http://127.0.0.1:9000/" };

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    var server_process = try std.ChildProcess.init(server_cmd[0..], allocator);
    defer server_process.deinit();
    try server_process.spawn();

    // Wait for it to start
    std.time.sleep(1 * std.time.ns_per_s);

    var wrk_process = try std.ChildProcess.init(wrk_cmd[0..], allocator);
    defer wrk_process.deinit();
    try wrk_process.spawn();

    var r = wrk_process.wait();
    r = server_process.wait();
}
