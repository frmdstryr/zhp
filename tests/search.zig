const std = @import("std");

pub fn main() anyerror!void {
    const find = "\n\n"; // The \r are already stripped out
    const n = 275;
    const buf = @embedFile("./bigger.txt");
    //const buf = @embedFile("./http-requests.txt");
    //const n = 55;
    //const find = "\r\n\r\n"; // The \r are already stripped out

    var ptrs1: [n][]const u8 = undefined;
    var ptrs2: [n][]const u8= undefined;

    var timer = try std.time.Timer.start();
    var it1 = std.mem.split(buf, find);
    var cnt: usize = 0;

    while (it1.next()) |req| {
        ptrs1[cnt] = req;
        cnt += 1;
    }
    const t1 = timer.lap();
    std.testing.expectEqual(cnt, n);


    var it2 = split(buf, find);
    cnt = 0;
    while (it2.next()) |req| {
        ptrs2[cnt] = req;
        cnt += 1;
    }
    const t2 = timer.lap();

    std.testing.expectEqual(cnt, n);
    std.testing.expectEqual(ptrs1, ptrs2);

    timer.reset();
    for (ptrs1) |src, i| {
         const dst = ptrs2[i];
         std.testing.expect(std.mem.eql(u8, src, dst));
    }
    const t3 = timer.lap();
    for (ptrs1) |src, i| {
        const dst = ptrs2[i];
        std.testing.expect(eql(u8, src, dst));
    }
    const t4 = timer.lap();

    var dest: [4096]u8 = undefined;
    timer.reset();
    for (ptrs1) |src, i| {
         std.mem.copy(u8, &dest, src);
    }
    const t5 = timer.lap();

    for (ptrs1) |src, i| {
         copy(u8, &dest, src);
    }
    const t6 = timer.lap();

    std.log.warn("split std: {}ns", .{t1});
    std.log.warn("split SIMD: {}ns", .{t2});
    std.log.warn("split diff: {}", .{@intToFloat(f32, t1)/@intToFloat(f32, t2)});

    std.log.warn("eql std: {}ns", .{t3});
    std.log.warn("eql SIMD: {}ns", .{t4});
    std.log.warn("eql diff: {}", .{@intToFloat(f32, t3)/@intToFloat(f32, t4)});

    std.log.warn("copy std: {}ns", .{t5});
    std.log.warn("copy SIMD: {}ns", .{t6});
    std.log.warn("copy diff: {}", .{@intToFloat(f32, t5)/@intToFloat(f32, t6)});
}

pub fn copy(comptime T: type, dest: []T, source: []const T) callconv(.Inline) void {
    const n = 32; // TODO: Adjust based on bitSizeOf T
    const V = @Vector(n, T);
    if (source.len < n) return std.mem.copy(T, dest, source);
    var end: usize = n;
    while (end < source.len) {
        const start = end - n;
        const source_chunk: V = source[start..end][0..n].*;
        const dest_chunk = &@as(V, dest[start..end][0..n].*);
        dest_chunk.* = source_chunk;
        end = std.math.min(end + n, source.len);
    }
}

pub fn eql(comptime T: type, a: []const T, b: []const T) callconv(.Inline) bool {
    const n = 32;
    const V8x32 = @Vector(n, T);
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;
    if (a.len < n) {
        // Too small to fit, fallback to standard eql
        for (a) |item, index| {
            if (b[index] != item) return false;
        }
    } else {
        var end: usize = n;
        while (end < a.len) {
            const start = end - n;
            const a_chunk: V8x32 = a[start..end][0..n].*;
            const b_chunk: V8x32 = b[start..end][0..n].*;
            if (!@reduce(.And, a_chunk == b_chunk)) {
                return false;
            }
            end = std.math.min(end+n, a.len);
        }
    }
    return true;
}


pub fn indexOf(comptime T: type, buf: []const u8, delimiter: []const u8) ?usize {
    return indexOfAnyPos(T, buf, 0, delimiter);
}

pub fn indexOfAnyPos(comptime T: type, buf: []const T, start_index: usize, delimiter: []const T) ?usize {
    const n = 32;
    const k = delimiter.len;
    const V8x32 = @Vector(n, T);
    const V1x32 = @Vector(n, u1);
    const Vbx32 = @Vector(n, bool);
    const first = @splat(n, delimiter[0]);
    const last = @splat(n, delimiter[k-1]);

    if (buf.len < n) {
        return std.mem.indexOfAnyPos(T, buf, start_index, delimiter);
    }

    var end: usize = start_index + n;
    while (end < buf.len) {
        const start = end - n;
        const last_end = std.math.min(end+k-1, buf.len);
        const last_start = last_end - n;

        // Look for the first character in the delimter
        const first_chunk: V8x32 = buf[start..end][0..n].*;
        const last_chunk: V8x32 = buf[last_start..last_end][0..n].*;
        const mask = @bitCast(V1x32, first == first_chunk) & @bitCast(V1x32, last == last_chunk);
        if (@reduce(.Or, mask) != 0) {
            for (@as([n]bool, @bitCast(Vbx32, mask))) |match, i| {
                if (match and eql(T, buf[start+i..start+i+k], delimiter)) {
                    return start+i;
                }
            }
        }
        end = std.math.min(end + n, buf.len);
    }
    return null; // Not found
}

pub fn split(buffer: []const u8, delimiter: []const u8) SplitIterator {
    return SplitIterator{.buffer=buffer, .delimiter=delimiter};
}

pub const SplitIterator = struct {
        index: ?usize = 0,
        buffer: []const u8,
        delimiter: []const u8,

    /// Returns a slice of the next field, or null if splitting is complete.
    pub fn next(self: *SplitIterator) ?[]const u8 {
        const start = self.index orelse return null;
        const end = if (indexOfAnyPos(u8, self.buffer, start, self.delimiter)) |delim_start| blk: {
            self.index = delim_start + self.delimiter.len;
            break :blk delim_start;
        } else blk: {
            self.index = null;
            break :blk self.buffer.len;
        };
        return self.buffer[start..end];
    }

    /// Returns a slice of the remaining bytes. Does not affect iterator state.
    pub fn rest(self: SplitIterator) []const u8 {
        const end = self.buffer.len;
        const start = self.index orelse end;
        return self.buffer[start..end];
    }

};
