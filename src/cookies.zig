// -------------------------------------------------------------------------- //
// Copyright (c) 2020, Jairus Martin.                                         //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const simd = @import("simd.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Cookies = struct {
    pub const Cookie = struct {
        key: []const u8,
        value: []const u8,
    };
    pub const List = std.ArrayList(Cookie);
    cookies: List,
    parsed: bool = false,

    pub fn init(allocator: Allocator) Cookies {
        return Cookies{ .cookies = List.init(allocator) };
    }

    pub fn initCapacity(allocator: Allocator, capacity: usize) !Cookies {
        return Cookies{
            .cookies = try List.initCapacity(allocator, capacity),
        };
    }

    // Parse up to capacity cookies
    pub fn parse(self: *Cookies, header: []const u8) !void {
        var it = simd.split(u8, header, "; ");
        defer self.parsed = true;
        while (self.cookies.items.len < self.cookies.capacity) {
            const pair = it.next() orelse break;
            // Errors are ignored
            const pos = simd.indexOf(u8, pair, "=") orelse continue;
            const key = pair[0..pos];
            const end = pos + 1;
            if (pair.len > end) {
                const value = pair[end..];
                self.cookies.appendAssumeCapacity(Cookie{ .key = key, .value = value });
            }
        }
    }

    pub fn lookup(self: Cookies, key: []const u8) !usize {
        for (self.cookies.items) |cookie, i| {
            if (std.mem.eql(u8, cookie.key, key)) return i;
        }
        return error.KeyError;
    }

    pub fn get(self: Cookies, key: []const u8) ![]const u8 {
        const i = try self.lookup(key);
        return self.cookies.items[i].value;
    }

    pub fn getOptional(self: Cookies, key: []const u8) ?[]const u8 {
        return self.get(key) catch null;
    }

    pub fn getDefault(self: Cookies, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) catch default;
    }

    pub fn contains(self: Cookies, key: []const u8) bool {
        _ = self.lookup(key) catch {
            return false;
        };
        return true;
    }

    pub fn reset(self: *Cookies) void {
        self.cookies.items.len = 0;
        self.parsed = false;
    }

    pub fn deinit(self: *Cookies) void {
        self.cookies.deinit();
    }
};

test "cookie-parse-api" {
    const header = "azk=ue1-5eb08aeed9a7401c9195cb933eb7c966";
    var cookies = try Cookies.initCapacity(std.testing.allocator, 32);
    defer cookies.deinit();
    try cookies.parse(header);

    // Not case sensitive
    try testing.expect(cookies.contains("azk"));
    try testing.expect(!cookies.contains("AZK"));

    try testing.expectEqualStrings("ue1-5eb08aeed9a7401c9195cb933eb7c966", try cookies.get("azk"));

    try testing.expectEqual(cookies.getOptional("user"), null);
    try testing.expectEqualStrings("default", cookies.getDefault("user", "default"));
}

test "cookie-parse-multiple" {
    const header = "S_9994987=6754579095859875029; A4=01fmFvgRnI09SF00000; u2=d1263d39-874b-4a89-86cd-a2ab0860ed4e3Zl040";
    var cookies = try Cookies.initCapacity(std.testing.allocator, 32);
    defer cookies.deinit();
    try cookies.parse(header);

    try testing.expectEqualStrings("6754579095859875029", try cookies.get("S_9994987"));

    try testing.expectEqualStrings("01fmFvgRnI09SF00000", try cookies.get("A4"));

    try testing.expectEqualStrings("d1263d39-874b-4a89-86cd-a2ab0860ed4e3Zl040", try cookies.get("u2"));
}

test "cookie-parse-empty-ignored" {
    const header = "S_9994987=6754579095859875029; ; u2=d1263d39-874b-4a89-86cd-a2ab0860ed4e3Zl040";
    var cookies = try Cookies.initCapacity(std.testing.allocator, 32);
    defer cookies.deinit();
    try cookies.parse(header);

    try testing.expectEqualStrings("6754579095859875029", try cookies.get("S_9994987"));

    try testing.expectEqualStrings("d1263d39-874b-4a89-86cd-a2ab0860ed4e3Zl040", try cookies.get("u2"));
}
