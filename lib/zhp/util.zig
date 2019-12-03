const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;



// A map of arrays
pub fn StringArrayMap(comptime T: type) type {
    return struct {
        const Self = @This();
        const Array = std.ArrayList(T);
        allocator: *Allocator,
        storage: std.StringHashMap(*Array),

        pub fn init(allocator: *Allocator) Self {
            return Self{
                .allocator = allocator,
                .storage = std.StringHashMap(*Array).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            // Deinit each array
            var it = self.storage.iterator();
            while (it.next()) |entry| {
                var array = entry.value;
                array.deinit();
            }
            self.storage.clear();
        }

        pub fn append(self: *Self, name: []const u8, arg: T) !void {
            if (!self.storage.contains(name)) {
                var ptr = try self.allocator.create(Array);
                ptr.* = Array.init(self.allocator);
                var entry = self.storage.put(name, ptr);
            }
            var array = self.get(name).?;
            try array.append(arg);
        }

        pub fn get(self: *Self, name: []const u8) ?*Array {
            return self.storage.getValue(name);
        }
    };
}


test "string-array-map" {
    const Map = StringArrayMap([]const u8);
    var map = Map.init(std.heap.direct_allocator);
    try map.append("query", "a");
    try map.append("query", "b");
    try map.append("query", "c");
    const query = map.get("query").?;
    std.debug.warn("First len {}", query.items[0].len);
    std.debug.warn("First {}", query.items[0]);
    testing.expect(query.count() == 3);
    testing.expect(mem.eql(u8, query.items[0], "a"));

    map.deinit();
}


pub fn tuple(comptime t1: type, comptime t2: type) type {
    return struct {first: t1, second: t2};
}

const GzipDecompressor = struct{
    allocator: *Allocator,
    unconsumed_tail: []const u8,

    pub fn decompress(
            self: *GzipDecompressor, data: []const u8, chunk_size: u32) []const u8 {
        return data; // TODO: Implement
    }

    pub fn flush(self: *GzipDecompressor) []const u8 {
        //?
        return self.unconsumed_tail;
    }
};


pub fn in(comptime T: type, a: var, comptime args: ...) bool {
    inline for (args) | arg | {
        if (mem.eql(T, a, arg)) return true;
    }
    return false;
}



test "in" {
    var method = "GET";
    testing.expect(!in(u8, method, "POST", "PUT", "PATCH"));
    method = "PUT";
    testing.expect(!in(u8, method, "POST", "PUT", "PATCH"));

    //const code = 404;
    //testing.expect(!in(u32, code, 204, 304));
}


// Remove quotes from a string
pub fn unquote(str: []const u8) ![]const u8 {
    if (str.len > 1) {
        if (mem.startsWith(u8, str, "\"") and mem.endsWith(u8, str, "\"")) {
            var buf: [str.len]u8 = undefined;
            var allocator = &std.heap.FixedBufferAllocator.init(&buf).allocator;
            var slice = replace(allocator, u8, str[1..str.len-1], "\\\\", "\\");
            return replace(allocator, u8, slice, "\\\\", "\"");
        }

        if (mem.startsWith(u8, str, "<") and mem.endsWith(u8, str, ">")) {
            return str[1..str.len-1];
        }
    }
    return str;
}


pub fn collapse_rfc2231_value(value: []const u8) ![]const u8 {
    // TODO: Implement
    return try unquote(value);
}

pub fn decode_rfc2231_params(
        allocator: *Allocator, params: *std.StringHashMap([]const u8)) !void {
    //
}


const indexOf = mem.indexOf;
const eql = mem.eql;
const dupe = mem.dupe;
const indexOfPos = mem.indexOfPos;
const copy = mem.copy;


/// Replace all occurances of needle in the haystack with the replacement
/// Caller owns the result
pub fn replace(allocator: *Allocator, comptime T: type,
        haystack: []const T, needle: []const T, replacement: []const T) ![]T {
    const first_match = indexOf(T, haystack, needle);
    if (first_match == null or eql(T, needle, replacement)) {
        return dupe(allocator, T, haystack);
    }

    var end = first_match;
    var start: usize = 0;
    const total_len: usize = blk: {
        if (needle.len == replacement.len) {
            break :blk haystack.len;
        }
        // TODO: Is it faster to search or use an expanding buffer?
        const diff = @intCast(isize, replacement.len) - @intCast(isize, needle.len);
        var sum = @intCast(isize, haystack.len);
        while (end != null) {
            sum += diff;
            start = end.? + needle.len;
            end = indexOfPos(T, haystack, start, needle);
        }
        break :blk @intCast(usize, sum);
    };
    if (total_len == 0) return &[0]T{};

    const buf = try allocator.alloc(T, total_len);
    errdefer allocator.free(buf);

    // Reset
    start = 0;
    end = first_match;

    var buf_index: usize = 0;
    var slice: []T = undefined;
    while (end != null) {
        slice = haystack[start..end.?];
        copy(T, buf[buf_index..], slice);
        buf_index += slice.len;

        // Copy replacment if needed
        if (replacement.len > 0) {
            copy(T, buf[buf_index..], replacement);
            buf_index += replacement.len;
        }

        // Skip needle and find nex
        start = end.? + needle.len;
        end = indexOfPos(T, haystack, start, needle);
    }

    // Copy rest
    if (start < haystack.len) {
        copy(T, buf[buf_index..], haystack[start..]);
    }

    // No need for shrink since buf is exactly the correct size.
    return buf;
}


test "replace" {
    var buf: [1024]u8 = undefined;
    const allocator = &std.heap.FixedBufferAllocator.init(&buf).allocator;
    const x = "value='true'";

    // Swap
    var result = try replace(allocator, u8, x, "'", "\"");
    testing.expectEqualSlices(u8, result, "value=\"true\"");

    // No matches
    result = try replace(allocator, u8, x, ":", "=");
    testing.expectEqualSlices(u8, result, x);

    // Bigger replace
    result = try replace(allocator, u8, x, "true", "false");
    testing.expectEqualSlices(u8, result, "value='false'");

    // Multi replace
    result = try replace(allocator, u8, "===", "=", "|");
    testing.expectEqualSlices(u8, result, "|||");

    // Equal replace
    result = try replace(allocator, u8, "===", "=", "=");
    testing.expectEqualSlices(u8, result, "===");

    // Empty result
    result = try replace(allocator, u8, "===", "=", "");
    testing.expectEqualSlices(u8, result, "");
}






