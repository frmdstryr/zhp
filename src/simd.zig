// -------------------------------------------------------------------------- //
// Copyright (c) 2020, Jairus Martin.                                         //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");

pub fn copy(comptime T: type, dest: []T, source: []const T) void {
    const n = 32; // TODO: Adjust based on bitSizeOf T
    const V = @Vector(n, T);
    if (source.len < n) return std.mem.copy(T, dest, source);
    var end: usize = n;
    while (end < source.len) {
        const start = end - n;
        const source_chunk: V = source[start..end][0..n].*;
        const dest_chunk: *V = &@as(V, dest[start..end][0..n].*);
        dest_chunk.* = source_chunk;
        end = std.math.min(end + n, source.len);
    }
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
            if (!@reduce(.And, a_chunk == b_chunk)) {
                return false;
            }
            end = std.math.min(end + n, a.len);
        }
    }
    return true;
}

pub fn lastIndexOf(comptime T: type, buf: []const u8, delimiter: []const u8) ?usize {
    const n = 32;
    const k = delimiter.len;
    const V8x32 = @Vector(n, T);
    const V1x32 = @Vector(n, u1);
    //const Vbx32 = @Vector(n, bool);
    const first = @splat(n, delimiter[0]);
    const last = @splat(n, delimiter[k - 1]);

    if (buf.len < n) {
        return std.mem.lastIndexOfPos(T, buf, 0, delimiter);
    }

    var start: usize = buf.len - n;
    while (start > 0) {
        const end = start + n;
        const last_end = std.math.min(end + k - 1, buf.len);
        const last_start = last_end - n;

        // Look for the first character in the delimter
        const first_chunk: V8x32 = buf[start..end][0..n].*;
        const last_chunk: V8x32 = buf[last_start..last_end][0..n].*;
        const mask = @bitCast(V1x32, first == first_chunk) & @bitCast(V1x32, last == last_chunk);
        if (@reduce(.Or, mask) != 0) {
            // TODO: Use __builtin_ctz???
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                if (mask[i] == 1 and eql(T, buf[start + i .. start + i + k], delimiter)) {
                    return start + i;
                }
            }
        }
        start = std.math.max(start - n, 0);
    }
    return null; // Not found
}

pub fn indexOf(comptime T: type, buf: []const u8, delimiter: []const u8) ?usize {
    return indexOfPos(T, buf, 0, delimiter);
}

pub fn indexOfPos(comptime T: type, buf: []const u8, start_index: usize, delimiter: []const u8) ?usize {
    const n = 32;
    const k = delimiter.len;
    const V8x32 = @Vector(n, T);
    const V1x32 = @Vector(n, u1);
    const Vbx32 = @Vector(n, bool);
    const first = @splat(n, delimiter[0]);
    const last = @splat(n, delimiter[k - 1]);

    var end: usize = start_index + n;
    var start: usize = end - n;
    while (end < buf.len) {
        start = end - n;
        const last_end = std.math.min(end + k - 1, buf.len);
        const last_start = last_end - n;

        // Look for the first character in the delimter
        const first_chunk: V8x32 = buf[start..end][0..n].*;
        const last_chunk: V8x32 = buf[last_start..last_end][0..n].*;
        const mask = @bitCast(V1x32, first == first_chunk) & @bitCast(V1x32, last == last_chunk);
        if (@reduce(.Or, mask) != 0) {
            // TODO: Use __builtin_clz???
            for (@as([n]bool, @bitCast(Vbx32, mask))) |match, i| {
                if (match and eql(T, buf[start + i .. start + i + k], delimiter)) {
                    return start + i;
                }
            }
        }
        end = std.math.min(end + n, buf.len);
    }
    if (start < buf.len) return std.mem.indexOfPos(T, buf, start_index, delimiter);
    return null; // Not found
}

pub fn split(comptime T: type, buffer: []const T, delimiter: []const T) SplitIterator(T) {
    const Iterator = SplitIterator(T);
    return Iterator{ .buffer = buffer, .delimiter = delimiter };
}

pub fn SplitIterator(comptime T: type) type {
    return struct {
        const Self = @This();
        index: ?usize = 0,
        buffer: []const T,
        delimiter: []const T,

        /// Returns a slice of the next field, or null if splitting is complete.
        pub fn next(self: *Self) ?[]const T {
            const start = self.index orelse return null;
            const end = if (indexOfPos(T, self.buffer, start, self.delimiter)) |delim_start| blk: {
                self.index = delim_start + self.delimiter.len;
                break :blk delim_start;
            } else blk: {
                self.index = null;
                break :blk self.buffer.len;
            };
            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            const end = self.buffer.len;
            const start = self.index orelse end;
            return self.buffer[start..end];
        }
    };
}
