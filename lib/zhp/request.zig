const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const time = std.time;

const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const HttpHeaders = @import("headers.zig").HttpHeaders;
const IOStream = @import("util.zig").IOStream;


inline fn isCtrlChar(ch: u8) bool {
    return (ch < @as(u8, 40) and ch != '\t') or ch == @as(u8, 177);
}


const token_map = [_]u1{
    //  0, 1, 2, 3, 4, 5, 6, 7 ,8, 9,10,11,12,13,14,15
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,

    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0,

    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,

    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

inline fn isTokenChar(ch: u8) bool {
    return token_map[ch] == 1;
}

pub const Bytes = std.ArrayList(u8);


pub const HttpRequest = struct {
    pub const Method = enum {
        Get,
        Put,
        Post,
        Patch,
        Head,
        Delete,
        Options,
        Unknown
    };

    pub const Version = enum {
        Http1_0,
        Http1_1,
        Unknown
    };
    method: Method = .Unknown,
    version: Version = .Unknown,
    path: []const u8 = "",
    content_length: usize = 0,
    read_finished: bool = false,
    headers: HttpHeaders,

    // Holds the whole request (for now)
    buffer: Bytes,

    // Slice from the start to the body
    head: []const u8 = "",

    // Body of request
    body: []const u8 = "",

    pub fn init(allocator: *Allocator) !HttpRequest {
        return HttpRequest{
            .buffer = try Bytes.initCapacity(allocator, mem.page_size),
            .headers = try HttpHeaders.initCapacity(allocator, 64),
        };
    }

    pub fn initCapacity(allocator: *Allocator, buffer_size: usize,
                        max_headers: usize) !HttpRequest {
        return HttpRequest{
            .buffer = try Bytes.initCapacity(allocator, buffer_size),
            .headers = try HttpHeaders.initCapacity(allocator, max_headers),
        };
    }

    // Reset the request to it's initial state so it can be reused
    // without needing to reallocate
    pub fn reset(self: *HttpRequest) void {
        self.method = .Unknown;
        self.path = "";
        self.body = "";
        self.version = .Unknown;
        self.content_length = 0;
        self.read_finished = false;
        self.headers.reset();
        self.buffer.len = 0;
    }

    // Parse using default sizes
    pub fn parse(self: *HttpRequest, stream: *IOStream) !usize {
        var n = try self.parseRequestLine(stream, 2048);
        n += try self.parseHeaders(stream, 32*1024);
        try self.parseContentLength(100*1024*1024);
        const buf = &self.buffer;
        self.head = buf.toSlice()[0..n];
        return n;
    }

    // Based on picohttpparser
    // FIXME: Use readByte instead of readByteFast
    // readByteFast is 3x faster but doesn't handle slowloris
    pub fn parseRequestLine(self: *HttpRequest, stream: *IOStream, max_size: usize) !usize {
        // Want to ensure we can dump directly into the buffer
        try self.buffer.resize(max_size);
        const buf = &self.buffer;
        stream.swapBuffer(buf.toSlice());

        // FIXME: If the whole method is not in the initial read
        // buffer this bails out
        var ch: u8 = try stream.readByte();

        // Skip any leading CRLFs
        while (stream.readCount() < max_size) {
            switch (ch) {
                '\r' => {
                    ch = try stream.readByteFast();
                    if (ch != '\n') return error.BadRequest;
                },
                '\n' => {},
                else => break,
            }
            ch = try stream.readByteFast();
        }
        if (stream.readCount() == max_size) return error.RequestUriTooLong; // Too Big

        // Read the method
        switch (ch) {
            'G' => { // GET
                inline for("ET") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.BadRequest;
                }
                self.method = Method.Get;
            },
            'P' => {
                ch = try stream.readByteFast();
                switch (ch) {
                    'U' => {
                        ch = try stream.readByteFast();
                        if (ch != 'T') return error.BadRequest;
                        self.method = Method.Put;
                    },
                    'O' => {
                        inline for("ST") |expected| {
                            ch = try stream.readByteFast();
                            if (ch != expected) return error.BadRequest;
                        }
                        self.method = Method.Post;
                    },
                    'A' => {
                        inline for("TCH") |expected| {
                            ch = try stream.readByteFast();
                            if (ch != expected) return error.BadRequest;
                        }
                        self.method = Method.Patch;
                    },
                    else => return error.BadRequest,
                }
            },
            'H' => {
                inline for("EAD") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.BadRequest;
                }
                self.method = Method.Head;
            },
            'D' => {
                inline for("ELETE") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.BadRequest;
                }
                self.method = Method.Delete;
            },
            'O' => {
                inline for("PTIONS") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.BadRequest;
                }
                self.method = Method.Options;

            },
            else => return error.MethodNotAllowed,
        }

        // Check separator
        ch = try stream.readByteFast();
        if (ch != ' ') return error.BadRequest;

        // TODO: Validate the path
        // FIXME: If the whole request path is not in the initial read
        // buffer this bails out early
        //const index = buf.len;
        const index = stream.readCount();
        while (stream.readCount() < max_size) {
            ch = try stream.readByteFast();
            if (!ascii.isGraph(ch)) {
                if (ch == ' ') break;
                return error.BadRequest;
            }
        }
        if (stream.readCount() == max_size) return error.RequestUriTooLong; // Too Big

        self.path = buf.toSlice()[index..stream.readCount()-1];
        if (self.path.len == 0) return error.BadRequest;

        // Read version
        inline for("HTTP/1.") |expected| {
            ch = try stream.readByteFast();
            if (ch != expected) return error.BadRequest;
        }
        ch = try stream.readByteFast();
        self.version = switch (ch) {
            '0' => Version.Http1_0,
            '1' => Version.Http1_1,
            else => return error.UnsupportedHttpVersion,
        };

        // Read to end of the line
        ch = try stream.readByteFast();

        if (ch == '\r') {
            ch = try stream.readByteFast();
        }
        if (ch != '\n') return error.BadRequest;
        return stream.readCount();
    }

    pub fn parseHeaders(self: *HttpRequest, stream: *IOStream,
                        max_size: usize) !usize {
        const headers = &self.headers;

        // Reuse the request buffer for this
        const buf = &self.buffer;
        var index: usize = undefined;
        var key: ?[]u8 = null;
        var value: ?[]u8 = null;
        var ch: u8 = 0;

        // Strip any whitespace
        while (headers.items.len < headers.items.capacity()) {
            // TODO: This assumes that the whole header in the buffer
            ch = try stream.readByteFast();

            switch (ch) {
                '\r' => {
                    ch = try stream.readByteFast();
                    if (ch != '\n') return error.BadRequest;
                    break; // Empty line, we're done
                },
                '\n' => break, // Empty line, we're done
                ' ', '\t' => {
                    // Continuation of multi line header
                    if (key == null) return error.BadRequest;
                },
                ':' => return error.BadRequest, // Empty key
                else => {
                    //index = buf.len;
                    index = stream.readCount()-1;

                    // Read Key
                    while (stream.readCount() < max_size) {
                        if (ch == ':') break;
                        if (!isTokenChar(ch)) return error.BadRequest;
                        ch = try stream.readByteFast();
                    }

                    // Header name
                    key = buf.toSlice()[index..stream.readCount()-1];

                    // Strip whitespace
                    while (stream.readCount() < max_size) {
                        ch = try stream.readByteFast();
                        if (!(ch == ' ' or ch == '\t')) break;
                    }
                },
            }

            // Read value
            index = stream.readCount()-1;
            while (stream.readCount() < max_size) {
                if (!ascii.isPrint(ch) and isCtrlChar(ch)) break;
                ch = try stream.readByteFast();
            }

            // TODO: Strip trailing spaces and tabs
            value = buf.toSlice()[index..stream.readCount()-1];
            //value = buf.toSlice()[index..buf.len];

            // Ignore any remaining non-print characters
            while (stream.readCount() < max_size) {
                if (!ascii.isPrint(ch) and isCtrlChar(ch)) break;
                ch = try stream.readByteFast();
            }

            // Check CRLF
            if (ch == '\r') {
                ch = try stream.readByteFast();
                if (ch != '\n') return error.BadRequest;
            } else if (ch != '\n') {
                return error.BadRequest;
            }

            //std.debug.warn("Found header: {}={}\n", .{key.?, value.?});

            // Next
            try headers.append(key.?, value.?);
        }
        if (stream.readCount() == max_size) {
            return error.RequestHeaderFieldsTooLarge;
        }
        return stream.readCount();
    }

    pub fn parseContentLength(self: *HttpRequest, max_size: usize) !void {
        var headers = &self.headers;
        // Read content length
        if (!headers.contains("Content-Length")) {
            self.content_length = 0;
            return;
        }

        if (headers.contains("Transfer-Encoding")) {
            // Response cannot contain both Content-Length and
            // Transfer-Encoding headers.
            // http://tools.ietf.org/html/rfc7230#section-3.3.3
            return error.BadRequest;
        }
        var content_length_header = try headers.get("Content-Length");

        // Proxies sometimes cause Content-Length headers to get
        // duplicated.  If all the values are identical then we can
        // use them but if they differ it's an error.
        var it = mem.separate(content_length_header, ",");
        while (it.next()) |piece| {
            try headers.put("Content-Length", piece);
            break; // TODO: Just use the first
        }

        self.content_length = std.fmt.parseInt(u32, content_length_header, 10)
            catch return error.BadRequest;

        if (self.content_length > max_size) {
            return error.RequestEntityTooLarge;
        }
    }

    //pub fn parseCookie(self: *HttpRequest) !void {
    //    // TODO Do while parsing headers
    //}


    pub fn dataReceived(self: *HttpRequest, data: []const u8) !void {
        try self.buffer.appendSlice(data);
    }

    // Callback
    //dataReceived: fn(self: *HttpRequest, data: []const u8) anyerror!void = onDataReceived,

    pub fn deinit(self: *HttpRequest) void {
        self.buffer.deinit();
        self.headers.deinit();
    }

};


const TEST_GET_1 =
    "GET /wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg HTTP/1.1\r\n" ++
    "Host: www.kittyhell.com\r\n" ++
    "User-Agent: Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; ja-JP-mac; rv:1.9.2.3) Gecko/20100401 Firefox/3.6.3 Pathtraq/0.9\r\n" ++
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" ++
    "Accept-Language: ja,en-us;q=0.7,en;q=0.3\r\n" ++
    "Accept-Encoding: gzip,deflate\r\n" ++
    "Accept-Charset: Shift_JIS,utf-8;q=0.7,*;q=0.7\r\n" ++
    "Keep-Alive: 115\r\n" ++
    "Connection: keep-alive\r\n" ++
    "Cookie: wp_ozh_wsa_visits=2; wp_ozh_wsa_visit_lasttime=xxxxxxxxxx; " ++
    "__utma=xxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.x; " ++
    "__utmz=xxxxxxxxx.xxxxxxxxxx.x.x.utmccn=(referral)|utmcsr=reader.livedoor.com|utmcct=/reader/|utmcmd=referral\r\n" ++
    "\r\n";


test "parse-request-line" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;
    var stream = try IOStream.initTest(allocator, TEST_GET_1);
    var request = try HttpRequest.init(allocator);
    request.buffer = Bytes.fromOwnedSlice(allocator, stream.in_buffer);

    var n = try request.parse(&stream);
    testing.expectEqual(request.method, HttpRequest.Method.Get);
    testing.expectEqual(request.version, HttpRequest.Version.Http1_1);
    testing.expectEqualSlices(u8, request.path,
        "/wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg");

}

test "bench-parse-request-line" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;
    var stream = try IOStream.initTest(allocator, TEST_GET_1);

    var request = try HttpRequest.init(allocator);
    request.buffer = Bytes.fromOwnedSlice(allocator, stream.in_buffer);

    const requests: usize = 1000000;
    var n: usize = 0;
    var timer = try std.time.Timer.start();

    var i: usize = 0; // 1M
    while (i < requests) : (i += 1) {
        // 10000k req/s 750MB/s (100 ns/req)
        n = try request.parseRequestLine(&stream, 2048);
        request.reset();
        fba.reset();
        stream.reset();
    }
    const ns = timer.lap();
    const ms = ns / 1000000;
    const bytes = requests * n / time.ms_per_s;
    std.debug.warn("\n    {}k req/s {}MB/s ({} ns/req)\n",
        .{requests/ms, bytes/ms, ns/requests});

    //stream.load("POST CRAP");
    //request = try HttpRequest.init(allocator);
    //testing.expectError(error.BadRequest,
    //    request.parseRequestLine(&stream, 0));

//     var line = try HttpRequest.StartLine.parse(a, "GET /foo HTTP/1.1");
//     testing.expect(mem.eql(u8, line.method, "GET"));
//     testing.expect(mem.eql(u8, line.path, "/foo"));
//     testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
//     line = try RequestStartLine.parse("POST / HTTP/1.1");
//     testing.expect(mem.eql(u8, line.method, "POST"));
//     testing.expect(mem.eql(u8, line.path, "/"));
//     testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
//
//     testing.expectError(error.BadRequest,
//             RequestStartLine.parse(a, "POST CRAP"));
//     testing.expectError(error.BadRequest,
//             RequestStartLine.parse(a, "POST /theform/ HTTP/1.1 DROP ALL TABLES"));
//     testing.expectError(error.UnsupportedHttpVersion,
//             RequestStartLine.parse(a, "POST / HTTP/2.0"));
}

test "parse-request-headers" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;

    var stream = try IOStream.initTest(allocator,
        \\GET / HTTP/1.1
        \\Host: server
        \\User-Agent: Mozilla/5.0 (X11; Linux x86_64) Gecko/20130501 Firefox/30.0 AppleWebKit/600.00 Chrome/30.0.0000.0 Trident/10.0 Safari/600.00
        \\Cookie: uid=012345678901234532323; __utma=1.1234567890.1234567890.1234567890.1234567890.12; wd=2560x1600
        \\Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
        \\Accept-Language: en-US,en;q=0.5
        \\Connection: keep-alive
        \\
        \\
    );
    var request = try HttpRequest.init(allocator);
    request.buffer = Bytes.fromOwnedSlice(allocator, stream.in_buffer);

    var n = try request.parse(&stream);
    var h = &request.headers;

    testing.expectEqual(@as(usize, 6), h.items.len);

    testing.expectEqualSlices(u8, "server", try h.get("Host"));
    testing.expectEqualSlices(u8, "Mozilla/5.0 (X11; Linux x86_64) Gecko/20130501 Firefox/30.0 AppleWebKit/600.00 Chrome/30.0.0000.0 Trident/10.0 Safari/600.00",
        try h.get("User-Agent"));
    testing.expectEqualSlices(u8, "uid=012345678901234532323; __utma=1.1234567890.1234567890.1234567890.1234567890.12; wd=2560x1600",
        try h.get("Cookie"));
    testing.expectEqualSlices(u8, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        try h.get("Accept"));
    testing.expectEqualSlices(u8, "en-US,en;q=0.5",
        try h.get("Accept-Language"));
    testing.expectEqualSlices(u8, "keep-alive",
        try h.get("Connection"));

    // Next
    try stream.load(allocator, TEST_GET_1);
    request.reset();
    request.buffer = Bytes.fromOwnedSlice(allocator, stream.in_buffer);
    n = try request.parse(&stream);
    h = &request.headers;

    testing.expectEqual(@as(usize, 9), h.items.len);

    testing.expectEqualSlices(u8, "www.kittyhell.com", try h.get("Host"));
    testing.expectEqualSlices(u8, "Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; ja-JP-mac; rv:1.9.2.3) Gecko/20100401 Firefox/3.6.3 Pathtraq/0.9",
        try h.get("User-Agent"));
    testing.expectEqualSlices(u8, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        try h.get("Accept"));
    testing.expectEqualSlices(u8, "ja,en-us;q=0.7,en;q=0.3",
        try h.get("Accept-Language"));
    testing.expectEqualSlices(u8, "gzip,deflate",
        try h.get("Accept-Encoding"));
    testing.expectEqualSlices(u8, "Shift_JIS,utf-8;q=0.7,*;q=0.7",
        try h.get("Accept-Charset"));
    testing.expectEqualSlices(u8, "115",
        try h.get("Keep-Alive"));
    testing.expectEqualSlices(u8, "keep-alive",
        try h.get("Connection"));
    testing.expectEqualSlices(u8,
        "wp_ozh_wsa_visits=2; wp_ozh_wsa_visit_lasttime=xxxxxxxxxx; " ++
        "__utma=xxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.x; " ++
        "__utmz=xxxxxxxxx.xxxxxxxxxx.x.x.utmccn=(referral)|utmcsr=reader.livedoor.com|utmcct=/reader/|utmcmd=referral",
        try h.get("Cookie"));

}

test "bench-parse-request-headers" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;

    var stream = try IOStream.initTest(allocator, TEST_GET_1);
    var request = try HttpRequest.init(allocator);
    request.buffer = Bytes.fromOwnedSlice(allocator, stream.in_buffer);

    const requests: usize = 1000000;
    var n: usize = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0; // 1M
    while (i < requests) : (i += 1) {
        //     1031k req/s 725MB/s (969 ns/req)
        n = try request.parse(&stream);
        request.reset();
        fba.reset();
        stream.reset();
    }

    const ns = timer.lap();
    const ms = ns / 1000000;
    const bytes = requests * n / time.ms_per_s;
    std.debug.warn("\n    {}k req/s {}MB/s ({} ns/req)\n",
        .{requests/ms, bytes/ms, ns/requests});
}


