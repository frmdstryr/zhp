// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2022, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const mem = std.mem;
const ascii = std.ascii;
const Allocator = mem.Allocator;
const testing = std.testing;

pub const known_files = &[_][]const u8{
    "/etc/mime.types",
    "/etc/httpd/mime.types", // Mac OS X
    "/etc/httpd/conf/mime.types", // Apache
    "/etc/apache/mime.types", // Apache 1
    "/etc/apache2/mime.types", // Apache 2
    "/usr/local/etc/httpd/conf/mime.types",
    "/usr/local/lib/netscape/mime.types",
    "/usr/local/etc/httpd/conf/mime.types", // Apache 1.2
    "/usr/local/etc/mime.types", // Apache 1.3
};

pub const suffix_map = &[_][2][]const u8{
    .{ ".svgz", ".svg.gz" },
    .{ ".tgz", ".tar.gz" },
    .{ ".taz", ".tar.gz" },
    .{ ".tz", ".tar.gz" },
    .{ ".tbz2", ".tar.bz2" },
    .{ ".txz", ".tar.xz" },
};

pub const encodings_map = &[_][2][]const u8{
    .{ ".gz", "gzip" },
    .{ ".Z", "compress" },
    .{ ".bz2", "bzip2" },
    .{ ".xz", "xz" },
};

// Before adding new types, make sure they are either registered with IANA,
// at http://www.isi.edu/in-notes/iana/assignments/media-types
// or extensions, i.e. using the x- prefix
// If you add to these, please keep them sorted!
pub const extension_map = &[_][2][]const u8{
    .{ ".a", "application/octet-stream" },
    .{ ".ai", "application/postscript" },
    .{ ".aif", "audio/x-aiff" },
    .{ ".aifc", "audio/x-aiff" },
    .{ ".aiff", "audio/x-aiff" },
    .{ ".au", "audio/basic" },
    .{ ".avi", "video/x-msvideo" },
    .{ ".bat", "text/plain" },
    .{ ".bcpio", "application/x-bcpio" },
    .{ ".bin", "application/octet-stream" },
    .{ ".bmp", "image/x-ms-bmp" },
    .{ ".c", "text/plain" },
    .{ ".cdf", "application/x-cdf" }, // Dup
    .{ ".cdf", "application/x-netcdf" },
    .{ ".cpio", "application/x-cpio" },
    .{ ".csh", "application/x-csh" },
    .{ ".css", "text/css" },
    .{ ".csv", "text/csv" },
    .{ ".dll", "application/octet-stream" },
    .{ ".doc", "application/msword" },
    .{ ".dot", "application/msword" },
    .{ ".dvi", "application/x-dvi" },
    .{ ".eml", "message/rfc822" },
    .{ ".eps", "application/postscript" },
    .{ ".etx", "text/x-setext" },
    .{ ".exe", "application/octet-stream" },
    .{ ".gif", "image/gif" },
    .{ ".gtar", "application/x-gtar" },
    .{ ".h", "text/plain" },
    .{ ".hdf", "application/x-hdf" },
    .{ ".htm", "text/html" },
    .{ ".html", "text/html" },
    .{ ".ico", "image/vnd.microsoft.icon" },
    .{ ".ief", "image/ief" },
    .{ ".jpe", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".jpg", "image/jpeg" },
    .{ ".js", "application/javascript" },
    .{ ".json", "application/json" },
    .{ ".ksh", "text/plain" },
    .{ ".latex", "application/x-latex" },
    .{ ".m1v", "video/mpeg" },
    .{ ".man", "application/x-troff-man" },
    .{ ".me", "application/x-troff-me" },
    .{ ".mht", "message/rfc822" },
    .{ ".mhtml", "message/rfc822" },
    .{ ".mid", "audio/midi" },
    .{ ".midi", "audio/midi" },
    .{ ".mif", "application/x-mif" },
    .{ ".mjs", "application/javascript" },
    .{ ".mov", "video/quicktime" },
    .{ ".movie", "video/x-sgi-movie" },
    .{ ".mp2", "audio/mpeg" },
    .{ ".mp3", "audio/mpeg" },
    .{ ".mp4", "video/mp4" },
    .{ ".mpa", "video/mpeg" },
    .{ ".mpe", "video/mpeg" },
    .{ ".mpeg", "video/mpeg" },
    .{ ".mpg", "video/mpeg" },
    .{ ".ms", "application/x-troff-ms" },
    .{ ".nc", "application/x-netcdf" },
    .{ ".nws", "message/rfc822" },
    .{ ".o", "application/octet-stream" },
    .{ ".obj", "application/octet-stream" },
    .{ ".oda", "application/oda" },
    .{ ".p12", "application/x-pkcs12" },
    .{ ".p7c", "application/pkcs7-mime" },
    .{ ".pbm", "image/x-portable-bitmap" },
    .{ ".pdf", "application/pdf" },
    .{ ".pfx", "application/x-pkcs12" },
    .{ ".pgm", "image/x-portable-graymap" },
    .{ ".pct", "image/pict" },
    .{ ".pic", "image/pict" },
    .{ ".pict", "image/pict" },
    .{ ".pl", "text/plain" },
    .{ ".png", "image/png" },
    .{ ".pnm", "image/x-portable-anymap" },
    .{ ".pot", "application/vnd.ms-powerpoint" },
    .{ ".ppa", "application/vnd.ms-powerpoint" },
    .{ ".ppm", "image/x-portable-pixmap" },
    .{ ".pps", "application/vnd.ms-powerpoint" },
    .{ ".ppt", "application/vnd.ms-powerpoint" },
    .{ ".ps", "application/postscript" },
    .{ ".pwz", "application/vnd.ms-powerpoint" },
    .{ ".py", "text/x-python" },
    .{ ".pyc", "application/x-python-code" },
    .{ ".pyo", "application/x-python-code" },
    .{ ".qt", "video/quicktime" },
    .{ ".ra", "audio/x-pn-realaudio" },
    .{ ".ram", "application/x-pn-realaudio" },
    .{ ".ras", "image/x-cmu-raster" },
    .{ ".rdf", "application/xml" },
    .{ ".rgb", "image/x-rgb" },
    .{ ".roff", "application/x-troff" },
    .{ ".rtf", "application/rtf" },
    .{ ".rtx", "text/richtext" },
    .{ ".sgm", "text/x-sgml" },
    .{ ".sgml", "text/x-sgml" },
    .{ ".sh", "application/x-sh" },
    .{ ".shar", "application/x-shar" },
    .{ ".snd", "audio/basic" },
    .{ ".so", "application/octet-stream" },
    .{ ".src", "application/x-wais-source" },
    .{ ".sv4cpio", "application/x-sv4cpio" },
    .{ ".sv4crc", "application/x-sv4crc" },
    .{ ".svg", "image/svg+xml" },
    .{ ".swf", "application/x-shockwave-flash" },
    .{ ".t", "application/x-troff" },
    .{ ".tar", "application/x-tar" },
    .{ ".tcl", "application/x-tcl" },
    .{ ".tex", "application/x-tex" },
    .{ ".texi", "application/x-texinfo" },
    .{ ".texinfo", "application/x-texinfo" },
    .{ ".tif", "image/tiff" },
    .{ ".tiff", "image/tiff" },
    .{ ".tr", "application/x-troff" },
    .{ ".tsv", "text/tab-separated-values" },
    .{ ".txt", "text/plain" },
    .{ ".ustar", "application/x-ustar" },
    .{ ".vcf", "text/x-vcard" },
    .{ ".wav", "audio/x-wav" },
    .{ ".webm", "video/webm" },
    .{ ".wiz", "application/msword" },
    .{ ".wsdl", "application/xml" },
    .{ ".xbm", "image/x-xbitmap" },
    .{ ".xlb", "application/vnd.ms-excel" },
    .{ ".xls", "application/excel" },
    .{ ".xls", "application/vnd.ms-excel" }, // Dup
    .{ ".xml", "text/xml" },
    .{ ".xpdl", "application/xml" },
    .{ ".xpm", "image/x-xpixmap" },
    .{ ".xsl", "application/xml" },
    .{ ".xwd", "image/x-xwindowdump" },
    .{ ".xul", "text/xul" },
    .{ ".zip", "application/zip" },
};

// Whitespace characters
const WS = " \t\r\n";

// Replace inplace
fn replace(line: []u8, find: u8, replacement: u8) void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == find) line[i] = replacement;
    }
}

// Trim that doesn't require a const slice
fn trim(slice: []u8, values: []const u8) []u8 {
    var begin: usize = 0;
    var end: usize = slice.len;
    while (begin < end and mem.indexOfScalar(u8, values, slice[begin]) != null) : (begin += 1) {}
    while (end > begin and mem.indexOfScalar(u8, values, slice[end - 1]) != null) : (end -= 1) {}
    return slice[begin..end];
}

pub const Registry = struct {
    const StringMap = std.StringHashMap([]const u8);
    const StringArray = std.ArrayList([]const u8);
    const StringArrayMap = std.StringHashMap(*StringArray);

    loaded: bool = false,
    arena: std.heap.ArenaAllocator,

    // Maps extension type to mime type
    type_map: StringMap,

    // Maps mime type to list of extensions
    type_map_inv: StringArrayMap,

    pub fn init(allocator: Allocator) Registry {
        // Must call load separately to avoid https://github.com/ziglang/zig/issues/2765
        return Registry{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .type_map = StringMap.init(allocator),
            .type_map_inv = StringArrayMap.init(allocator),
        };
    }

    // Add a mapping between a type and an extension.
    // this copies both and will overwrite any existing entries
    pub fn addType(self: *Registry, ext: []const u8, mime_type: []const u8) !void {
        // Add '.' if necessary
        const allocator = self.arena.allocator();
        const extension =
            if (mem.startsWith(u8, ext, "."))
            try allocator.dupe(u8, mem.trim(u8, ext, WS))
        else
            try mem.concat(allocator, u8, &[_][]const u8{ ".", mem.trim(u8, ext, WS) });
        return self.addTypeInternal(extension, try allocator.dupe(u8, mem.trim(u8, mime_type, WS)));
    }

    // Add a mapping between a type and an extension.
    // this assumes the entries added are already owend
    fn addTypeInternal(self: *Registry, ext: []const u8, mime_type: []const u8) !void {
        // std.log.warn("  adding {}: {} to registry...\n", .{ext, mime_type});
        const allocator = self.arena.allocator();
        _ = try self.type_map.put(ext, mime_type);

        if (self.type_map_inv.getEntry(mime_type)) |entry| {
            // Check if it's already there
            const type_map = entry.value_ptr.*;
            for (type_map.items) |e| {
                if (mem.eql(u8, e, ext)) return; // Already there
            }
            try type_map.append(ext);
        } else {
            // Create a new list of extensions
            const extensions = try allocator.create(StringArray);
            extensions.* = StringArray.init(allocator);
            _ = try self.type_map_inv.put(mime_type, extensions);
            try extensions.append(ext);
        }
    }

    pub fn load(self: *Registry) !void {
        if (self.loaded) return;
        self.loaded = true;
        // Load defaults
        for (extension_map) |entry| {
            try self.addType(entry[0], entry[1]);
        }

        // Load from system
        if (builtin.os.tag == .windows) {
            // TODO: Windows
        } else {
            try self.loadRegistryLinux();
        }
    }

    pub fn loadRegistryLinux(self: *Registry) !void {
        for (known_files) |path| {
            var file = fs.openFileAbsolute(path, .{ .read = true }) catch continue;
            // std.log.warn("Loading {}...\n", .{path});
            try self.loadRegistryFile(file);
        }
    }

    // Read a single mime.types-format file.
    pub fn loadRegistryFile(self: *Registry, file: fs.File) !void {
        var stream = &std.io.bufferedReader(file.reader()).reader();
        var buf: [1024]u8 = undefined;
        while (true) {
            const result = try stream.readUntilDelimiterOrEof(&buf, '\n');
            if (result == null) break; // EOF
            var line = trim(result.?, WS);

            // Strip comments
            const end = mem.indexOf(u8, line, "#") orelse line.len;
            line = line[0..end];

            // Replace tabs with spaces to normalize so tokenize works
            replace(line, '\t', ' ');

            // Empty or no spaces
            if (line.len == 0 or mem.indexOf(u8, line, " ") == null) continue;

            var it = mem.tokenize(u8, line, " ");
            const mime_type = it.next() orelse continue;
            while (it.next()) |ext| {
                try self.addType(ext, mime_type);
            }
        }
    }

    // Guess the mime type from the filename
    pub fn getTypeFromFilename(self: *Registry, filename: []const u8) ?[]const u8 {
        const last_dot = mem.lastIndexOf(u8, filename, ".");
        if (last_dot) |i| return self.getTypeFromExtension(filename[i..]);
        return null;
    }

    // Guess the type of a file based on its URL.
    pub fn getTypeFromExtension(self: *Registry, ext: []const u8) ?[]const u8 {
        if (self.type_map.getEntry(ext)) |entry| {
            return entry.value_ptr.*;
        }
        return null;
    }

    pub fn getExtensionsByType(self: *Registry, mime_type: []const u8) ?*StringArray {
        if (self.type_map_inv.getEntry(mime_type)) |entry| {
            return entry.value_ptr.*;
        }
        return null;
    }

    pub fn deinit(self: *Registry) void {
        // Free type
        self.type_map.deinit();

        // Free the type map
        self.type_map_inv.deinit();

        // And free anything else
        self.arena.deinit();
    }
};

pub var instance: ?Registry = null;

test "guess-ext" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.load();

    try testing.expectEqualSlices(u8, "image/png", registry.getTypeFromFilename("an-image.png").?);
    try testing.expectEqualSlices(u8, "application/javascript", registry.getTypeFromFilename("wavascript.js").?);
}

test "guess-ext-from-file" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.load();

    // This ext is not in the list above
    try testing.expectEqualSlices(u8, "application/x-7z-compressed", registry.getTypeFromFilename("archive.7z").?);
}

test "guess-ext-unknown" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.load();

    // This ext is not in the list above
    try testing.expect(registry.getTypeFromFilename("notanext") == null);
}
