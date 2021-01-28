// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const Bytes = util.Bytes;
const IOStream = util.IOStream;

fn isColonValidateToken(ch: u8) !bool {
    if (ch == ':') return true;
    if (!util.isTokenChar(ch)) return error.BadRequest;
    return false;
}

fn isControlOrPrint(ch: u8) bool {
    return !ascii.isPrint(ch) and util.isCtrlChar(ch);
}

pub const Headers = struct {
    pub const Header = struct {
        key: []const u8,
        value: []const u8,
    };
    pub const HeaderList = std.ArrayList(Header);
    headers: HeaderList,

    pub fn init(allocator: *Allocator) Headers {
        return Headers{
            .headers = HeaderList.init(allocator),
        };
    }

    pub fn initCapacity(allocator: *Allocator, num: usize) !Headers {
        return Headers{
            .headers = try HeaderList.initCapacity(allocator, num),
        };
    }

    pub fn deinit(self: *Headers) void {
        self.headers.deinit();
    }

    pub fn format(
        self: Headers,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        try std.fmt.format(out_stream, "Headers{{", .{});
        for (self.headers.items) |header| {
            try std.fmt.format(out_stream, "\"{s}\": \"{s}\", ", .{header.key, header.value});
        }
        try std.fmt.format(out_stream, "}}", .{});
    }

    // Get the index of the  key
    pub fn lookup(self: *Headers, key: []const u8) !usize {
        for (self.headers.items) |header, i| {
            if (ascii.eqlIgnoreCase(header.key, key)) return i;
        }
        return error.KeyError;
    }

    // Get the value for the given key
    pub fn get(self: *Headers, key: []const u8) ![]const u8 {
        const i = try self.lookup(key);
        return self.headers.items[i].value;
    }

    pub fn getOptional(self: *Headers, key: []const u8) ?[]const u8 {
        return self.get(key) catch null;
    }

    pub fn getDefault(self: *Headers, key: []const u8,
                      default: []const u8) []const u8 {
        return self.get(key) catch default;
    }

    pub fn contains(self: *Headers, key: []const u8) bool {
        const v = self.lookup(key) catch |err| return false;
        return true;
    }

    // Check if the header equals the other
    pub fn eql(self: *Headers, key: []const u8, other: []const u8) bool {
        const v = self.get(key) catch |err| return false;
        return mem.eql(u8, v, other);
    }

    pub fn eqlIgnoreCase(self: *Headers, key: []const u8, other: []const u8) bool {
        const v = self.get(key) catch |err| return false;
        return ascii.eqlIgnoreCase(v, other);
    }

    pub fn put(self: *Headers, key: []const u8, value: []const u8) !void {
        // If the key already exists under a different name don't add it again
        const i = self.lookup(key) catch |err| switch (err) {
            error.KeyError => {
                try self.headers.append(Header{.key=key, .value=value});
                return;
            },
            else => return err,
        };
        self.headers.items[i] = Header{.key=key, .value=value};
    }

    // Put without checking for duplicates
    pub fn append(self: *Headers, key: []const u8, value: []const u8) !void {
        return self.headers.append(Header{.key=key, .value=value});
    }

    pub fn appendAssumeCapacity(self: *Headers, key: []const u8, value: []const u8) void {
        return self.headers.appendAssumeCapacity(Header{.key=key, .value=value});
    }

    pub fn remove(self: *Headers, key: []const u8) !void {
        const i = try self.lookup(key); // Throw error
        const v = self.headers.swapRemove(i);
    }

    pub fn pop(self: *Headers, key: []const u8) ![]const u8 {
        const i = try self.lookup(key); // Throw error
        return self.headers.swapRemove(i).value;
    }

    pub fn popDefault(self: *Headers, key: []const u8, default: []const u8) []const u8 {
        return self.pop(key) catch default;
    }

    // Reset to an empty header list
    pub fn reset(self: *Headers) void {
        self.headers.items.len = 0;
    }

    /// Assumes the streams current buffer will exist for the lifetime
    /// of the headers.
    /// Note readbyteFast will not modify the buffer internal buffer
    pub fn parse(self: *Headers, buf: *Bytes, stream: *IOStream, max_size: usize) !void {
        // Reuse the request buffer for this
        var index: usize = undefined;
        var key: ?[]u8 = null;
        var value: ?[]u8 = null;

        const limit = std.math.min(max_size, stream.amountBuffered());
        const read_limit = limit + stream.readCount();
        var read_all_headers: bool = false;

        while (self.headers.items.len < self.headers.capacity) {
            var ch = try stream.readByteSafe();
            defer key = null;

            switch (ch) {
                '\r' => {
                    ch = try stream.readByteSafe();
                    if (ch != '\n') return error.BadRequest;
                    read_all_headers = true;
                    break; // Empty line, we're done
                },
                '\n' => {
                    read_all_headers = true;
                    break; // Empty line, we're done
                },
                ' ', '\t' => {
                    // Continuation of multi line header
                    if (key == null) return error.BadRequest;
                },
                ':' => return error.BadRequest, // Empty key
                else => {
                    index = stream.readCount()-1;

                    // Read header name
                    ch = try stream.readUntilExprValidate(
                        error{BadRequest}, isColonValidateToken, ch, read_limit);

                    // Header name
                    key = buf.items[index..stream.readCount()-1];

                    // Strip whitespace
                    while (stream.readCount() < read_limit) {
                        ch = stream.readByteUnsafe();
                        if (!(ch == ' ' or ch == '\t')) break;
                    }
                },
            }

            // Read value
            index = stream.readCount()-1;
            ch = stream.readUntilExpr(isControlOrPrint, ch, read_limit);

            // TODO: Strip trailing spaces and tabs?
            value = buf.items[index..stream.readCount()-1];

            // Ignore any remaining non-print characters
            ch = stream.readUntilExpr(isControlOrPrint, ch, read_limit);

            if (stream.readCount() >= read_limit) {
                if (stream.isEmpty()) return error.EndOfBuffer;
                return error.RequestHeaderFieldsTooLarge;
            }

            // Check CRLF
            if (ch == '\r') {
                ch = try stream.readByteSafe();
            }
            if (ch != '\n') {
                return error.BadRequest;
            }

            //std.debug.warn("Found header: '{}'='{}'\n", .{key.?, value.?});
            self.appendAssumeCapacity(key.?, value.?);
        }

        if (!read_all_headers) {
            // If you hit this the capacity needs increased
            return error.RequestHeaderFieldsTooLarge;
        }
    }

    pub fn parseBuffer(self: *Headers, data: []const u8, max_size: usize) !void {
        const hack = @bitCast([]u8, data); // HACK: Explicitly violate const
        var fba = std.heap.FixedBufferAllocator.init(hack);
        fba.end_index = data.len; // Ensure we don't modify the buffer

        // Don't deinit since we don't actually own the data
        var buf = Bytes.fromOwnedSlice(&fba.allocator, fba.buffer);
        var stream = IOStream.fromBuffer(fba.buffer);
        try self.parse(&buf, &stream, max_size);
    }

};


test "headers-get" {
    const allocator = std.testing.allocator;
    var headers = try Headers.initCapacity(allocator, 64);
    defer headers.deinit();
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expectError(error.KeyError, headers.get("Accept-Type"));
    testing.expectEqualSlices(u8, try headers.get("cookie"), "Nom;nom;nom");
    testing.expectEqualSlices(u8, try headers.get("cOOKie"), "Nom;nom;nom");
    testing.expectEqualSlices(u8,
        headers.getDefault("User-Agent" , "zig"), "zig");
    testing.expectEqualSlices(u8,
        headers.getDefault("cookie" , "zig"), "Nom;nom;nom");
}

test "headers-put" {
    const allocator = std.testing.allocator;
    var headers = try Headers.initCapacity(allocator, 64);
    defer headers.deinit();
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expectEqualSlices(u8, try headers.get("Cookie"), "Nom;nom;nom");
    try headers.put("COOKie", "ABC"); // Squash even if different
    std.debug.warn("Cookie is: {s}", .{try headers.get("Cookie")});
    testing.expectEqualSlices(u8, try headers.get("Cookie"), "ABC");
}

test "headers-remove" {
    const allocator = std.testing.allocator;
    var headers = try Headers.initCapacity(allocator, 64);
    defer headers.deinit();
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(headers.contains("Cookie"));
    testing.expect(headers.contains("COOKIE"));
    try headers.remove("Cookie");
    testing.expect(!headers.contains("Cookie"));
}

test "headers-pop" {
    const allocator = std.testing.allocator;
    var headers = try Headers.initCapacity(allocator, 64);
    defer headers.deinit();
    testing.expectError(error.KeyError, headers.pop("Cookie"));
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(mem.eql(u8, try headers.pop("Cookie"), "Nom;nom;nom"));
    testing.expect(!headers.contains("Cookie"));
    testing.expect(mem.eql(u8, headers.popDefault("Cookie", "Hello"), "Hello"));
}


test "headers-parse" {
    const HEADERS =
        \\Host: bs.serving-sys.com
        \\User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:15.0) Gecko/20100101 Firefox/15.0.1
        \\Accept: image/png,image/*;q=0.8,*/*;q=0.5
        \\Accept-Language: en-us,en;q=0.5
        \\Accept-Encoding: gzip, deflate
        \\Connection: keep-alive
        \\Referer: http://static.adzerk.net/reddit/ads.html?sr=-reddit.com&bust2
        \\
        \\
    ;

    const allocator = std.testing.allocator;
    var headers = try Headers.initCapacity(allocator, 64);
    defer headers.deinit();
    try headers.parseBuffer(HEADERS[0..], 1024);

    testing.expect(mem.eql(u8, try headers.get("Host"), "bs.serving-sys.com"));
    testing.expect(mem.eql(u8, try headers.get("Connection"), "keep-alive"));
}
