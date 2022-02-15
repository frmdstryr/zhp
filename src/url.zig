// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const testing = std.testing;
const assert = std.debug.assert;

// Percent encode the source data
pub fn encode(dest: []u8, source: []const u8) ![]const u8 {
    assert(dest.len >= source.len);
    var i: usize = 0;
    for (source) |ch| {
        if (ascii.isAlNum(ch)) {
            dest[i] = ch;
            i += 1;
        } else if (ch == ' ') {
            dest[i] = '+';
            i += 1;
        } else {
            const end = i + 3;
            if (end > dest.len) return error.NoSpaceLeft;
            dest[i] = '%';
            _ = try std.fmt.bufPrint(dest[i + 1 .. end], "{X}", .{ch});
            i = end;
        }
    }
    return dest[0..i];
}

test "url-encode" {
    var buf: [256]u8 = undefined;
    const encoded = try encode(&buf, "hOlmDALJCWWdjzfBV4ZxJPmrdCLWB/tq7Z/" ++
        "fp4Q/xXbVPPREuMJMVGzKraTuhhNWxCCwi6yFEZg=");
    try testing.expectEqualStrings("hOlmDALJCWWdjzfBV4ZxJPmrdCLWB%2Ftq7Z%2F" ++
        "fp4Q%2FxXbVPPREuMJMVGzKraTuhhNWxCCwi6yFEZg%3D", encoded);
}

// Percent decode the source data
pub fn decode(dest: []u8, source: []const u8) ![]const u8 {
    assert(dest.len >= source.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        switch (ch) {
            '%' => {
                i += 1;
                const end = i + 2;
                if (source.len < end) return error.DecodeError;
                dest[j] = try std.fmt.parseInt(u8, source[i..end], 16);
                i += 1;
            },
            '+' => {
                dest[j] = ' ';
            },
            else => {
                dest[j] = ch;
            },
        }
        j += 1;
    }
    return dest[0..j];
}

test "url-decode" {
    var buf: [256]u8 = undefined;
    const decoded = try decode(&buf, "hOlmDALJCWWdjzfBV4ZxJPmrdCLWB%2Ftq7Z%2F" ++
        "fp4Q%2FxXbVPPREuMJMVGzKraTuhhNWxCCwi6yFEZg%3D");
    try testing.expectEqualStrings("hOlmDALJCWWdjzfBV4ZxJPmrdCLWB/tq7Z/" ++
        "fp4Q/xXbVPPREuMJMVGzKraTuhhNWxCCwi6yFEZg=", decoded);
}

// Look for host in a url
//
pub fn findHost(url: []const u8) []const u8 {
    var host = url;
    if (mem.indexOf(u8, host, "://")) |start| {
        host = host[start + 3 ..];
        if (mem.indexOf(u8, host, "/")) |end| {
            host = host[0..end];
        }
    }
    return host;
}

test "url-find-host" {
    const url = "http://localhost:9000";
    try testing.expectEqualStrings("localhost:9000", findHost(url));
    const url2 = "localhost:9000";
    try testing.expectEqualStrings("localhost:9000", findHost(url2));
}
