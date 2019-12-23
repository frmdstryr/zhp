const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const testing = std.testing;
const Buffer = std.Buffer;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");

// https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers
// pub const Header = enum {
//     Accept,
//     AcceptCH,
//     AcceptCHLifetime,
//     AcceptCharset,
//     AcceptEncoding,
//     AcceptLanguage,
//     AcceptPatch,
//     AcceptRanges,
//     AccessControlAllowCredentials,
//     AccessControlAllowHeaders,
//     AccessControlAllowMethods,
//     AccessControlAllowOrigin,
//     AccessControlExposeHeaders,
//     AccessControlMaxAge,
//     AccessControlRequestHeaders,
//     AccessControlRequestMethod,
//     Age,
//     Allow,
//     AltSvc,
//     Authorization,
//     CacheControl,
//     ClearSiteData,
//     Connection,
//     ContentDisposition,
//     ContentEncoding,
//     ContentLanguage,
//     ContentLength,
//     ContentLocation,
//     ContentRange,
//     ContentSecurityPolicy,
//     ContentSecurityPolicyReportOnly,
//     ContentType,
//     Cookie,
//     Cookie2,
//     CrossOriginResourcePolicy,
//     DNT,
//     DPR,
//     Date,
//     DeviceMemory,
//     Digest,
//     ETag,
//     EarlyData,
//     Expect,
//     ExpectCT,
//     Expires,
//     FeaturePolicy,
//     Forwarded,
//     From,
//     Host,
//     IfMatch,
//     IfModifiedSince,
//     IfNoneMatch,
//     IfRange,
//     IfUnmodifiedSince,
//     Index,
//     KeepAlive,
//     LargeAllocation,
//     LastModified,
//     Link,
//     Location,
//     Origin,
//     Pragma,
//     ProxyAuthenticate,
//     ProxyAuthorization,
//     PublicKeyPins,
//     PublicKeyPinsReportOnly,
//     Range,
//     Referer,
//     ReferrerPolicy,
//     RetryAfter,
//     SaveData,
//     SecWebSocketAccept,
//     Server,
//     ServerTiming,
//     SetCookie,
//     SourceMap,
//     StrictTransportSecurity,
//     TE,
//     TimingAllowOrigin,
//     Tk,
//     Trailer,
//     TransferEncoding,
//     UpgradeInsecureRequests,
//     UserAgent,
//     Vary,
//     Via,
//     WWWAuthenticate,
//     WantDigest,
//     Warning,
//     XContentTypeOptions,
//     XDNSPrefetchControl,
//     XForwardedFor,
//     XForwardedHost,
//     XForwardedProto,
//     XFrameOptions,
//     XXSSProtection,
//     Unknown
// };


pub const HttpHeaders = struct {
    pub const Header = struct {
        key: []const u8,
        value: []const u8,
    };
    pub const HeaderList = std.ArrayList(Header);
    items: HeaderList,

    pub fn initCapacity(allocator: *Allocator, num: usize) !HttpHeaders {
        return HttpHeaders{
            .items = try HeaderList.initCapacity(allocator, num),
        };
    }

    pub fn deinit(self: *HttpHeaders) void {
        self.items.deinit();
    }

    // Get the value for the given key
    pub fn get(self: *HttpHeaders, key: []const u8) ![]const u8 {
        const i = try self.lookup(key);
        return self.items.at(i).value;
    }

    // Get the index of the  key
    pub fn lookup(self: *HttpHeaders, key: []const u8) !usize {
        var headers = self.items.toSlice();
        for (headers) |header, i| {
            if (ascii.eqlIgnoreCase(header.key, key)) return i;
        }
        return error.KeyError;
    }

    pub fn getDefault(self: *HttpHeaders, key: []const u8,
                      default: []const u8) []const u8 {
        return self.get(key) catch default;
    }

    pub fn contains(self: *HttpHeaders, key: []const u8) bool {
        const v = self.lookup(key) catch |err| return false;
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
        const i = self.lookup(key) catch |err| switch (err) {
            error.KeyError => {
                try self.items.append(Header{.key=key, .value=value});
                return;
            },
            else => return err,
        };
        self.items.set(i, Header{.key=key, .value=value});
    }

    // Put without checking for duplicates
    pub fn append(self: *HttpHeaders, key: []const u8, value: []const u8) !void {
        return self.items.append(Header{.key=key, .value=value});
    }

    pub fn remove(self: *HttpHeaders, key: []const u8) !void {
        const i = try self.lookup(key); // Throw error
        const v = self.items.swapRemove(i);
    }

    pub fn pop(self: *HttpHeaders, key: []const u8) ![]const u8 {
        const i = try self.lookup(key); // Throw error
        return self.items.swapRemove(i).value;
    }

    pub fn popDefault(self: *HttpHeaders, key: []const u8, default: []const u8) []const u8 {
        return self.pop(key) catch default;
    }

    // Reset to an empty header list
    pub fn reset(self: *HttpHeaders) void {
        self.items.len = 0;
    }

    pub fn toSlice(self: *HttpHeaders) []Header {
        return self.items.toSlice();
    }

};


test "headers-get" {
    var allocator = std.heap.direct_allocator;
    var headers = try HttpHeaders.initCapacity(allocator, 64);
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expectEqualSlices(u8, try headers.get("cookie"), "Nom;nom;nom");
    testing.expectEqualSlices(u8, try headers.get("cOOKie"), "Nom;nom;nom");
    testing.expectEqualSlices(u8,
        headers.getDefault("User-Agent" , "zig"), "zig");
    testing.expectEqualSlices(u8,
        headers.getDefault("cookie" , "zig"), "Nom;nom;nom");
}

test "headers-put" {
    var allocator = std.heap.direct_allocator;
    var headers = try HttpHeaders.initCapacity(allocator, 64);
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expectEqualSlices(u8, try headers.get("Cookie"), "Nom;nom;nom");
    try headers.put("COOKie", "ABC"); // Squash even if different
    std.debug.warn("Cookie is: {}", .{try headers.get("Cookie")});
    testing.expectEqualSlices(u8, try headers.get("Cookie"), "ABC");
}

test "headers-remove" {
    var allocator = std.heap.direct_allocator;
    var headers = try HttpHeaders.initCapacity(allocator, 64);
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(headers.contains("Cookie"));
    testing.expect(headers.contains("COOKIE"));
    try headers.remove("Cookie");
    testing.expect(!headers.contains("Cookie"));
}

test "headers-pop" {
    var allocator = std.heap.direct_allocator;
    var headers = try HttpHeaders.initCapacity(allocator, 64);
    testing.expectError(error.KeyError, headers.pop("Cookie"));
    try headers.put("Cookie", "Nom;nom;nom");
    testing.expect(mem.eql(u8, try headers.pop("Cookie"), "Nom;nom;nom"));
    testing.expect(!headers.contains("Cookie"));
    testing.expect(mem.eql(u8, headers.popDefault("Cookie", "Hello"), "Hello"));
}

