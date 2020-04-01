// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //

pub const HttpFile = struct {
    // Represents a file uploaded via a form.

    filename: []const u8,
    content_type: []const u8,
    body: []const u8,

};


pub const ArgMap = utils.StringArrayMap([]const u8);
pub const FileMap = utils.StringArrayMap(HttpFile);



// Parses a ``multipart/form-data`` body.
//
// The arguments and files parameters will be updated with the contents of the body.
pub fn parse_multipart_form_data(
        allocator: *Allocator, boundary: []const u8, data: []const u8,
        arguments: *ArgMap, files: *FileMap) !void {
    // The standard allows for the boundary to be quoted in the header,
    // although it's rare (it happens at least for google app engine
    // xmpp).  I think we're also supposed to handle backslash-escapes
    // here but I'll save that until we see a client that uses them
    // in the wild.
    var bounds = boundary[0..];
    if (mem.startsWith(u8, boundary, "\"") and mem.endsWith(u8, boundary, "\"")) {
        bounds = boundary[1..bounds.len-1];
    }
    var buf = [bounds.len+4]u8;
    const final_boundary = try fmt.bufPrint(buf, "--{}--", bounds);
    const final_boundary_index = mem.lastIndexOf(u8, data, final_boundary);
    if (final_boundary_index == null) {
        std.debug.warn("Invalid multipart/form-data: no final boundary");
        return;
    }
    const separator = try fmt.bufPrint(buf, "--{}\r\n", bounds);

    var disp_params = try std.StringHashMap([]const u8).init(allocator);
    defer disp_params.deinit();

    var parts = mem.separate(u8, data[0..final_boundary_index.?]);
    while (parts.next()) |part| {
        if (part.len == 0) {
            continue;
        }
        const eoh = mem.indexOf("\r\n\r\n");
        if (eoh == null) {
            std.debug.warn("multipart/form-data missing headers");
            continue;
        }

        // TODO: Use a buffer
        var headers = try HttpHeaders.parse(allocator, part[0..eoh.?]);
        defer headers.deinit();

        const disp_header = headers.get_default("Content-Disposition", "");
        disp_params.clear();
        const disposition = try _parse_header(disp_header, disp_params);
        if (!mem.eql(u8, disposition, "form-data")
                or !mem.endsWith(u8, part, "\r\n")) {
            std.debug.warn("Invalid multipart/form-data");
            continue;
        }

        var name = disp_params.getValue("name");
        if (name==null or name.?.len == 0) {
            std.debug.warn("multipart/form-data value missing name");
            continue;
        }
        const value = part[eoh+4..part.len-2];

        if (disp_params.contains("filename")) {
            var content_type = headers.get_default(
                "Content-Type", "application/unknown");
            try files.append(name, HttpFile{
                .filename = disp_params.getValue("filename").?,
                .body = value,
                .content_type = content_type,
            });
        } else {
            try arguments.append(name, value);
        }
    }


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
fn _parse_header(allocator: *Allocator, line: []const u8,
                 params: std.StringHashMap([]const u8)) ![]const u8 {
    if (line.len == 0) return "";
    var it = mem.separate(line, ";");
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

        var name = try ascii.allocLowerString(allocator,
            mem.trim(u8, p[0..i.?], " \r\n"));
        var value = try util.collapse_rfc2231_value(
            mem.trim(u8, p[i.?..], " \r\n"));
        try params.put(name, value);
    }
    try util.decode_rfc2231_params(allocator, params);
    return header.?;
}

test "parse-header" {
    const d = "form-data; foo=\"b\\\\a\\\"r\"; file*=utf-8''T%C3%A4st";
    var params = std.StringHashMap([]const u8).init(direct_allocator);
    var ct = try _parse_header(direct_allocator, d, params);
    testing.expectEqualSlices(u8, ct, "form-data");
    testing.expect(params.contains("file"));
    testing.expect(params.contains("foo"));
}

// Inverse of _parse_header.
fn _encode_header(allocator: *Allocator, key: []const u8,
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
                    "{}={}", entry.key, entry.value));
        }
    }
    return try mem.join(allocator, "; ", out.toSliceConst());
}


test "encode-header" {
    var params = std.StringHashMap([]const u8).init(direct_allocator);

    testing.expectEqualSlices(u8,
        try _encode_header(direct_allocator, "permessage-deflate", params),
        "permessage-deflate");

    var e = try params.put("client_max_window_bits", "15");
    e = try params.put("client_no_context_takeover", "");

    var header = try _encode_header(direct_allocator, "permessage-deflate", params);
    testing.expectEqualSlices(u8, header,
        "permessage-deflate; client_no_context_takeover; client_max_window_bits=15");
}


