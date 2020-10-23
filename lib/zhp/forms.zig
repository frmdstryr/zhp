// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const Request = @import("web.zig").Request;
const Headers = @import("web.zig").Headers;
const util = @import("util.zig");
const IOStream = util.IOStream;


pub const HttpFile = struct {
    // Represents a file uploaded via a form.

    filename: []const u8,
    content_type: []const u8,
    body: []const u8,

};


pub const ArgMap = util.StringArrayMap([]const u8);
pub const FileMap = util.StringArrayMap(HttpFile);
const WS = " \t\r\n";


pub const Form = struct {
    allocator: *Allocator,
    fields: ArgMap,
    files: FileMap,

    pub fn init(allocator: *Allocator) Form {
        return Form{
            .allocator = allocator,
            .fields = ArgMap.init(allocator),
            .files = FileMap.init(allocator),
        };
    }

    pub fn parse(self: *Form, request: *Request) !void {
        const content_type = try request.headers.get("Content-Type");
        try self.parseMultipart(content_type, request.body);
    }

    pub fn parseMultipart(self: *Form, content_type: []const u8, data: []const u8) !void {
        var iter = mem.split(content_type, ";");
        while (iter.next()) |part| {
            const pair = mem.trim(u8, part, WS);
            const key = "boundary=";
            if (pair.len > key.len and mem.startsWith(u8, pair, key)) {
                const boundary = pair[key.len..];
                try self.parseMultipartFormData(boundary, data);
            }
        }

    }

    pub fn parseMultipartFormData(self: *Form, boundary: []const u8, data: []const u8) !void {
        var bounds = boundary[0..];
        if (mem.startsWith(u8, boundary, "\"") and mem.endsWith(u8, boundary, "\"")) {
            bounds = boundary[1..bounds.len-1];
        }
        if (bounds.len > 70) {
            return error.MultipartBoundaryTooLong;
        }

        var buf: [74]u8 = undefined;
        const final_boundary = try std.fmt.bufPrint(&buf, "--{}--", .{bounds});
        const final_boundary_index = mem.lastIndexOf(u8, data, final_boundary);
        if (final_boundary_index == null) {
            //std.debug.warn("Invalid multipart/form-data: no final boundary");
            return error.MultipartFinalBoundaryMissing;
        }

        const separator = try std.fmt.bufPrint(&buf, "--{}\r\n", .{bounds});

        var disp_params = std.StringHashMap([]const u8).init(self.allocator);
        defer disp_params.deinit();

        var parts = mem.split(data[0..final_boundary_index.?], separator);
        while (parts.next()) |part| {
            if (part.len == 0) {
                continue;
            }
            const eoh = mem.indexOf(u8, part, "\r\n\r\n");
            if (eoh == null) {
                std.debug.warn("multipart/form-data missing headers", .{});
                continue;
            }

            // TODO: Use a buffer
            var headers = try Headers.parse(allocator,
                IOStream.fromFixedBuffer(part[0..eoh.?]), 1024);
            defer headers.deinit();

            const disp_header = headers.getDefault("Content-Disposition", "");
            disp_params.clearAndFree();
            const disposition = try parseHeader(disp_header, disp_params);
            if (!mem.eql(u8, disposition, "form-data")
                    or !mem.endsWith(u8, part, "\r\n")) {
                std.debug.warn("Invalid multipart/form-data", .{});
                continue;
            }

            var param = disp_params.getEntry("name");
            if (param == null or param.?.value.len == 0) {
                std.debug.warn("multipart/form-data value missing name", .{});
                continue;
            }
            const name = param.?.value;
            const value = part[eoh+4..part.len-2];

            if (disp_params.contains("filename")) {
                var content_type = headers.get_default(
                    "Content-Type", "application/unknown");
                try self.files.append(name, HttpFile{
                    .filename = disp_params.getEntry("filename").?.value,
                    .body = value,
                    .content_type = content_type,
                });
            } else {
                try self.fields.append(name, value);
            }
        }

    }

};



test "simple-form" {
    const content_type = "multipart/form-data; boundary=---------------------------389538318911445707002572116565";
    const body = \\-----------------------------389538318911445707002572116565
                 \\Content-Disposition: form-data; name="name"
                 \\
                 \\Your name
                 \\-----------------------------389538318911445707002572116565--
    ;
    var form = Form.init(std.heap.page_allocator);
    try form.parseMultipart(content_type, body);
}

// fn _parseparam(param: []const u8) SplitIterator {
//     var s = param[..];
//     while (mem.startsWith(u8, s, ";")) {
//         s = s[1:];
//         var end = mem.indexOf(u8, s, ";");
//         if (end == null) {
//
//         }
//         while (end > 0 and (s.count('"', 0, end) - s.count("\\\"", 0, end)) % 2:
//             end = s.find(";", end + 1)
//         if end < 0:
//             end = len(s)
//         f = s[:end]
//         yield f.strip()
//         s = s[end:];
//     }
// }



// Parse a Content-type like header.
// Return the main content-type and update the params
fn parseHeader(allocator: *Allocator, line: []const u8,
               params: *std.StringHashMap([]const u8)) ![]const u8 {
    if (line.len == 0) return "";
    var it = mem.split(line, ";");
    var header: ?[]const u8 = null;
    var first = false;
    while (it.next()) |p| {
        if (first) {
            first = false;
            header = try ascii.allocLowerString(allocator,
                mem.trim(u8, p, " \r\n"));
            continue;
        }
        var i = mem.indexOf(u8, p, "=");
        if (i == null) continue;

        const name = try ascii.allocLowerString(allocator,
            mem.trim(u8, p[0..i.?], " \r\n"));

        var value = try collapseRfc2231Value(allocator,
            mem.trim(u8, p[i.?..], " \r\n"));

        try params.put(name, value);
    }
    try decodeRfc2231Params(allocator, params);
    return header.?;
}

fn collapseRfc2231Value(allocator: *Allocator, value: []const u8) ![]const u8 {
    // TODO: Implement this..
    return value;
}

fn decodeRfc2231Params(allocator: *Allocator, params: *std.StringHashMap([]const u8)) !void {
    // TODO: Implement this..
}

test "parse-header" {
    const allocator = std.heap.page_allocator;
    const d = "form-data; foo=\"b\\\\a\\\"r\"; file*=utf-8''T%C3%A4st";
    var params = std.StringHashMap([]const u8).init(allocator);
    var ct = try parseHeader(allocator, d, params);
    testing.expectEqualSlices(u8, ct, "form-data");
    testing.expect(params.contains("file"));
    testing.expect(params.contains("foo"));
}

// Inverse of parseHeader.
fn encodeHeader(allocator: *Allocator, key: []const u8,
                  params: std.StringHashMap([]const u8)) ![]const u8 {
    if (params.count() == 0) {
        return key;
    }
    var out = std.ArrayList([]const u8).init(allocator);
    defer out.deinit();
    try out.append(key);
    // Sort the parameters just to make it easy to test.
    var it = params.iterator();
    while (it.next()) |entry| {
        if (entry.value.len == 0) {
            try out.append(entry.key);
        } else {
            // TODO: quote if necessary.
            try out.append(
                try std.fmt.allocPrint(allocator,
                    "{}={}", .{entry.key, entry.value}));
        }
    }
    return try mem.join(allocator, "; ", out.items);
}


test "encode-header" {
    const allocator = std.heap.page_allocator;
    var params = std.StringHashMap([]const u8).init(allocator);

    testing.expectEqualSlices(u8,
        try encodeHeader(allocator, "permessage-deflate", params),
        "permessage-deflate");

    var e = try params.put("client_max_window_bits", "15");
    e = try params.put("client_no_context_takeover", "");

    var header = try encodeHeader(allocator, "permessage-deflate", params);
    testing.expectEqualSlices(u8, header,
        "permessage-deflate; client_no_context_takeover; client_max_window_bits=15");
}


