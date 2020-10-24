// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const log = std.log;
const ascii = std.ascii;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const Request = @import("web.zig").Request;
const Headers = @import("web.zig").Headers;
const util = @import("util.zig");


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

    pub fn deinit(self: *Form) void {
        self.fields.deinit();
        self.files.deinit();
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

        // Check final boundary
        const final_boundary = try std.fmt.bufPrint(&buf, "--{}--", .{bounds});
        const final_boundary_index = mem.lastIndexOf(u8, data, final_boundary);
        if (final_boundary_index == null) {
            log.warn("Invalid multipart/form-data: no final boundary", .{});
            return error.MultipartFinalBoundaryMissing;
        }

        const separator = try std.fmt.bufPrint(&buf, "--{}\r\n", .{bounds});

        var fields = mem.split(data[0..final_boundary_index.?], separator);

        // TODO: Make these capacities configurable
        var headers = try Headers.initCapacity(self.allocator, 2);
        defer headers.deinit();
        var disp_params = try Headers.initCapacity(self.allocator, 2);
        defer disp_params.deinit();

        while (fields.next()) |part| {
            if (part.len == 0) {
                continue;
            }
            const header_sep = "\r\n\r\n";
            const eoh = mem.lastIndexOf(u8, part, header_sep);
            if (eoh == null) {
                log.warn("multipart/form-data missing headers: {}", .{part});
                continue;
            }

            const body = part[0..eoh.?+header_sep.len];
            // NOTE: Do not free, data is assumed to be owned
            // also do not do this after parsing or the it will cause a memory leak
            headers.reset();
            try headers.parseBuffer(body, body.len);


            const disp_header = headers.getDefault("Content-Disposition", "");
            disp_params.reset(); // NOTE: Do not free, data is assumed to be owned
            const disposition = try parseHeader(self.allocator, disp_header, &disp_params);

            if (!ascii.eqlIgnoreCase(disposition, "form-data")) {
                log.warn("Invalid multipart/form-data", .{});
                continue;
            }

            var field_name = disp_params.getDefault("name", "");
            if (mem.eql(u8, field_name, "")) {
                log.warn("multipart/form-data value missing name", .{});
                continue;
            }
            const field_value = part[body.len..part.len];

            if (disp_params.contains("filename")) {
                const content_type = headers.getDefault(
                    "Content-Type", "application/octet-stream");
                try self.files.append(field_name, HttpFile{
                    .filename = disp_params.getDefault("filename", ""),
                    .body = field_value,
                    .content_type = content_type,
                });
            } else {
                try self.fields.append(field_name, field_value);
            }
        }

    }

};



test "simple-form" {
    const content_type = "multipart/form-data; boundary=---------------------------389538318911445707002572116565";
    const body = "-----------------------------389538318911445707002572116565\r\n" ++
                 "Content-Disposition: form-data; name=\"name\"\r\n" ++
                 "\r\n" ++
                 "Your name" ++
                 "-----------------------------389538318911445707002572116565--\r\n"
    ;
    var form = Form.init(std.testing.allocator);
    defer form.deinit();
    try form.parseMultipart(content_type, body);
    testing.expect(form.fields.get("name") != null);
    const r = form.fields.get("name").?;
    log.warn("{}\n", .{r});
    testing.expectEqualSlices(u8, "Your name", r);
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



// Parse a header.
// return the first value and update the params with everything else
fn parseHeader(allocator: *Allocator, line: []const u8, params: *Headers) ![]const u8 {
    if (line.len == 0) return "";
    var it = mem.split(line, ";");

    // First part is returned as the main header value
    const value = if (it.next()) |p| mem.trim(u8, p, " \r\n") else "";

    // Now get the rest of the parameters
    while (it.next()) |p| {
        // Split on =
        var i = mem.indexOf(u8, p, "=");
        if (i == null) continue;

        const name = mem.trim(u8, p[0..i.?], " \r\n");
        const encoded_value = mem.trim(u8, p[i.?+1..], " \r\n");
        const decoded_value = try collapseRfc2231Value(allocator, encoded_value);
        try params.append(name, decoded_value);
    }
    try decodeRfc2231Params(allocator, params);
    return value;
}

fn collapseRfc2231Value(allocator: *Allocator, value: []const u8) ![]const u8 {
    // TODO: Implement this..
    return mem.trim(u8, value, "\"");
}

fn decodeRfc2231Params(allocator: *Allocator, params: *Headers) !void {
    // TODO: Implement this..
}

test "parse-content-disposition-header" {
    const allocator = std.testing.allocator;
    //const d = "form-data; foo=\"b\\\\a\\\"r\"; file*=utf-8''T%C3%A4st";
    const d = " form-data; name=\"fieldName\"; filename=\"filename.jpg\"";
    var params = try Headers.initCapacity(allocator, 5);
    defer params.deinit();
    var v = try parseHeader(allocator, d, &params);
    testing.expectEqualSlices(u8, "form-data", v);
    testing.expectEqualSlices(u8, "fieldName", try params.get("name"));
    testing.expectEqualSlices(u8, "filename.jpg", try params.get("filename"));
}

/// Inverse of parseHeader.
/// This always returns a copy so it must be cleaned up!
fn encodeHeader(allocator: *Allocator, key: []const u8, params: Headers) ![]const u8 {
    if (params.headers.items.len == 0) {
        return try mem.dupe(allocator, u8, key);
    }

    // I'm lazy
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var out = std.ArrayList([]const u8).init(&arena.allocator);
    try out.append(key);

    // Sort the parameters just to make it easy to test.
    for (params.headers.items) |entry| {
        if (entry.value.len == 0) {
            try out.append(entry.key);
        } else {
            // TODO: quote if necessary.
            try out.append(
                try std.fmt.allocPrint(&arena.allocator,
                    "{}={}", .{entry.key, entry.value}));
        }
    }
    return try mem.join(allocator, "; ", out.items);
}


test "encode-header" {
    const allocator = std.testing.allocator;
    var params = Headers.init(allocator);
    defer params.deinit();

    var r = try encodeHeader(allocator, "permessage-deflate", params);
    testing.expectEqualSlices(u8, "permessage-deflate", r);
    allocator.free(r);

    try params.append("client_no_context_takeover", "");
    try params.append("client_max_window_bits", "15");

    r = try encodeHeader(allocator, "permessage-deflate", params);
    testing.expectEqualSlices(u8, r,
        "permessage-deflate; client_no_context_takeover; client_max_window_bits=15");
    allocator.free(r);

}


