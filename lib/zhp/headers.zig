const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const testing = std.testing;
const Buffer = std.Buffer;
const Allocator = std.mem.Allocator;

const direct_allocator = std.heap.direct_allocator;

const re = @import("re").Regex;

const util = @import("util.zig");
const Datetime = @import("time/calendar.zig").Datetime;


/// Map a header name to Http-Header-Case.
/// The caller owns the returned bytes
pub fn normalize_header(allocator: *Allocator, name: []const u8) ![] u8 {
    const result = try allocator.alloc(u8, name.len);
    var last: ?u8 = null;
    for (result) |*c, i| {
        var char: u8 = name[i];
        if (last==null or last.? == '-') {
            c.* = ascii.toUpper(char);
        } else {
            c.* = ascii.toLower(char);
        }
        last = char;
    }
    return result;
}


test "normalize-header" {
    var key = try normalize_header(direct_allocator, "coNtent-TYPE");
    defer direct_allocator.free(key);
    testing.expect(mem.eql(u8, key, "Content-Type"));
}

const StringStringHashMap = std.StringHashMap([]const u8);

pub const HttpHeaders = struct {
    allocator: *Allocator,
    entries: StringStringHashMap,
    _last_key: ?[]const u8 = null,

    pub fn init(allocator: *Allocator) HttpHeaders {
        return HttpHeaders{
            .allocator = allocator,
            .entries = StringStringHashMap.init(allocator),
        };
    }

    pub fn deinit(self: *HttpHeaders) void {
        self.entries.deinit();
    }

    /// Returns a headers from HTTP header text.
    pub fn parse(allocator: *Allocator, headers: []const u8) !HttpHeaders {
        var h = HttpHeaders.init(allocator);
        var it = mem.separate(headers, "\n");
        while (it.next()) |line| {
            var end = line.len;
            if (mem.endsWith(u8, line, "\r")) {
                end -= 1;
            }
            if (end > 0) {
                try h.parseLine(line[0..end]);
            }
        }
        return h;
    }

    pub fn parseLine(self: *HttpHeaders, line: []const u8) !void {
        if (mem.startsWith(u8, line, " ")) {
            if (self._last_key == null) {
                // first header line cannot start with whitespace
                return error.HttpInputError;
            }
            // continuation of a multi-line header
            var value = try self.get(self._last_key.?);
            value = try mem.concat(self.allocator, u8, &[_][]const u8{
                value, " ", mem.trimLeft(u8, line, " \r\n")});
            try self.put(self._last_key.?, value);
        } else {
            const i = mem.indexOf(u8, line, ":") orelse 0;
            if (i == 0 or i == line.len) {
                return error.HttpInputError; // No colon or empty value
            }
            try self.put(line[0..i], mem.trim(u8, line[i+1..], " \r\n"));
        }
    }

    pub fn get(self: *HttpHeaders, key: []const u8) ![]const u8 {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (ascii.eqlIgnoreCase(entry.key, key)) {
                return entry.value;
            }
        }
        return error.KeyError;
    }

    // Get the case insensitve key for the key
    pub fn lookup(self: *HttpHeaders, key: []const u8) ![]const u8 {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (ascii.eqlIgnoreCase(entry.key, key)) {
                return entry.key;
            }
        }
        return error.KeyError;
    }

    pub fn getDefault(self: *HttpHeaders, key: []const u8,
                      default: []const u8) []const u8 {
        return self.get(key) catch default;
    }

    pub fn contains(self: *HttpHeaders, key: []const u8) bool {
        const v = self.get(key) catch |err| return false;
        return true;
    }

    // Check if the header equals the other
    pub fn eql(self: *HttpHeaders, key: []const u8, other: []const u8) bool {
        const v = self.get(key) catch |err| return false;
        return mem.eql(u8, v, other);
    }

    pub fn eqlIgnoreCase(self: *HttpHeaders, key: []const u8, other: []const u8) bool {
        const v = self.get(key) catch |err| return false;
        return ascii.eqlIgnoreCase(v, other);
    }

    pub fn put(self: *HttpHeaders, key: []const u8, value: []const u8) !void {
        // If the key already exists under a different name don't add it again
        const k = self.lookup(key) catch key;
        self._last_key = k;
        const r = try self.entries.put(k, value);
    }

    pub fn remove(self: *HttpHeaders, key: []const u8) !void {
        const k = try self.lookup(key); // Throw error
        const entry = self.entries.remove(k); // Ignore value
    }

    pub fn pop(self: *HttpHeaders, key: []const u8) ![]const u8 {
        const k = try self.lookup(key); // Throw error
        const entry = self.entries.remove(k).?;
        return entry.value;
    }

    pub fn popDefault(self: *HttpHeaders, key: []const u8, default: []const u8) []const u8 {
        return self.pop(key) catch default;
    }

    pub fn iterator(self: *HttpHeaders) StringStringHashMap.Iterator {
        return self.entries.iterator();
    }


    // Formats a timestamp in the format used by HTTP.
    // eg "Tue, 15 Nov 1994 08:12:31 GMT"
    pub fn formatDate(allocator: *Allocator, timestamp: u64) ![]const u8 {
        const d = Datetime.fromTimestamp(timestamp);
        return try std.fmt.allocPrint(allocator, "{}, {} {} {} {}:{}:{} {}", .{
            d.date.weekdayName()[0..3],
            d.date.day,
            d.date.monthName()[0..3],
            d.date.year,
            d.time.hour,
            d.time.minute,
            d.time.second,
            d.time.zone.name
        });
    }

};


test "headers-get" {
    var headers = HttpHeaders.init(direct_allocator);
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(mem.eql(u8, try headers.get("cookie"), "Nom;nom;nom"));
    testing.expect(mem.eql(u8, try headers.get("cOOKie"), "Nom;nom;nom"));
    testing.expect(mem.eql(u8, headers.getDefault("User-Agent" , "zig"), "zig"));
}

test "headers-put" {
    var headers = HttpHeaders.init(direct_allocator);
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(mem.eql(u8, try headers.get("Cookie"), "Nom;nom;nom"));
    try headers.put("COOKie", "ABC"); // Squash even if different
    testing.expect(mem.eql(u8, try headers.get("Cookie"), "ABC"));
}

test "headers-remove" {
    var headers = HttpHeaders.init(direct_allocator);
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(headers.contains("Cookie"));
    testing.expect(headers.contains("COOKIE"));
    try headers.remove("Cookie");
    testing.expect(!headers.contains("Cookie"));
}

test "headers-pop" {
    var headers = HttpHeaders.init(direct_allocator);
    testing.expectError(error.KeyError, headers.pop("Cookie"));
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(mem.eql(u8, try headers.pop("Cookie"), "Nom;nom;nom"));
    testing.expect(!headers.contains("Cookie"));
    testing.expect(mem.eql(u8, headers.popDefault("Cookie", "Hello"), "Hello"));
}


test "headers-parse" {
    var headers = try HttpHeaders.parse(direct_allocator,
        "Content-Type: text/html\r\nContent-Length: 42\r\n");
    var value = try headers.get("Content-Type");
    testing.expect(mem.eql(u8, value, "text/html"));
    value = try headers.get("Content-Length");
    testing.expect(mem.eql(u8, value, "42"));
    testing.expect(headers.contains("Content-Type"));
    testing.expect(!headers.contains("Cookie"));
}

test "headers-parse-line" {
    var headers = HttpHeaders.init(direct_allocator);
    try headers.parseLine("Content-Type: text/html");
    var value = try headers.get("content-type");
    testing.expect(mem.eql(u8, value, "text/html"));
}

