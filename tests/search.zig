const std = @import("std");

pub fn main() anyerror!void {
    const buf = @embedFile("./bigger.txt");

    const find = "\n\n"; // The \r are already stripped out

    var ptrs1: [275][]const u8 = undefined;
    var ptrs2: [275][]const u8= undefined;

    var timer = try std.time.Timer.start();
    var split = std.mem.split(buf, find);
    var cnt: usize = 0;

    while (split.next()) |req| {
        ptrs1[cnt] = req;
        cnt += 1;
    }
    const t1 = timer.lap();
    std.testing.expectEqual(cnt, 275);
    std.log.warn("std: {}ns", .{t1});

    var simd = Splitter.init(buf, find);
    cnt = 0;
    while (simd.next()) |req| {
        ptrs2[cnt] = req;
        cnt += 1;
    }
    const t2 = timer.lap();
    std.testing.expectEqual(cnt, 275);
    std.testing.expectEqual(ptrs1, ptrs2);
    std.log.warn("SIMD: {}ns", .{t2});
    std.log.warn("Speedup: {}", .{@intToFloat(f32, t1)/@intToFloat(f32, t2)});
}


pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
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
            if (@reduce(.Xor, a_chunk == b_chunk) != 0) {
                return false;
            }
            end = std.math.min(end+n, src.len);
        }
    }
    return true;
}


pub fn indexOfAnyPos(buf: []const u8, start_index: usize, delimiter: []const u8) ?usize {
    const n = 32;
    const k = delimiter.len;
    const V8x32 = @Vector(n, u8);
    const V1x32 = @Vector(n, u1);
    const Vbx32 = @Vector(n, bool);
    const first = @splat(n, delimiter[0]);
    const last = @splat(n, delimiter[k-1]);

    if (buf.len < n) {
        return std.mem.indexOfAnyPos(u8, buf, start_index, delimiter);
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
                if (match and std.mem.eql(u8, buf[start+i..start+i+k], delimiter)) {
                    return start+i;
                }
            }
        }
        end = std.math.min(end + n, buf.len);
    }
    return null; // Not found
}

pub const Splitter = struct {
        index: ?usize,
        buffer: []const u8,
        delimiter: []const u8,

    pub fn init(buf: []const u8, delimiter: []const u8) Splitter {
        return Splitter{.buffer = buf, .index = 0, .delimiter=delimiter};
    }

        /// Returns a slice of the next field, or null if splitting is complete.
    pub fn next(self: *Splitter) ?[]const u8 {
        const start = self.index orelse return null;
        const end = if (indexOfAnyPos(self.buffer, start, self.delimiter)) |delim_start| blk: {
            self.index = delim_start + self.delimiter.len;
            break :blk delim_start;
        } else blk: {
            self.index = null;
            break :blk self.buffer.len;
        };
        return self.buffer[start..end];
    }

    /// Returns a slice of the remaining bytes. Does not affect iterator state.
    pub fn rest(self: Self) []const u8 {
        const end = self.buffer.len;
        const start = self.index orelse end;
        return self.buffer[start..end];
    }

};
