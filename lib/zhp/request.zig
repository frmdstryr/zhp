const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const time = std.time;

const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const HttpHeaders = @import("headers.zig").HttpHeaders;
const IOStream = @import("util.zig").IOStream;


// TODO: Is it better to use ascii.isPrint ??
inline fn isPrintableAscii(ch: u8) bool {
    return ascii.isPrint(ch);//@subWithOverflow(ch, @as(u8, 40)) < @as(u8, 137);
}

inline fn isCtrlChar(ch: u8) bool {
    return (ch < @as(u8, 40) and ch != '\t') or ch == @as(u8, 177);
}

inline fn isTokenChar(ch: u8) bool {
    return HttpHeaders.token_map[ch] == 0;
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
    _read_finished: bool = false,
    headers: HttpHeaders,

    // Holds path and headers
    buffer: Bytes,

    // Holds the rest
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
        self._read_finished = false;
        self.headers.reset();
        self.buffer.len = 0;
    }

    // Based on picohttpparser
    // FIXME: Use readByte instead of readByteFast
    // readByteFast is 3x faster but doesn't handle slowloris
    pub fn parseRequestLine(self: *HttpRequest, stream: *IOStream,
                            timeout: u64, max_size: usize) !usize {
        // Want to ensure we can dump directly into the buffer
        try self.buffer.resize(max_size);
        const buf = &self.buffer;
        try stream.swapBuffer(buf.toSlice());
        //self.buffer.len = 0;

        var ch: u8 = 0;

        // Skip any leading CRLFs
        while (stream.readCount() < max_size) {
            ch = try stream.readByteFast();
            switch (ch) {
                '\r' => {
                    ch = try stream.readByteFast();
                    if (ch != '\n') return error.HttpInputError;
                    continue;
                },
                '\n' => continue,
                else => break,
            }
        }
        if (stream.readCount() == max_size) return error.StreamTooLong; // Too Big

        // Read the method
        switch (ch) {
            'G' => { // GET
                inline for("ET") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.HttpInputError;
                }
                self.method = Method.Get;
            },
            'P' => {
                ch = try stream.readByteFast();
                switch (ch) {
                    'U' => {
                        ch = try stream.readByteFast();
                        if (ch != 'T') return error.HttpInputError;
                        self.method = Method.Put;
                    },
                    'O' => {
                        inline for("ST") |expected| {
                            ch = try stream.readByteFast();
                            if (ch != expected) return error.HttpInputError;
                        }
                        self.method = Method.Post;
                    },
                    'A' => {
                        inline for("TCH") |expected| {
                            ch = try stream.readByteFast();
                            if (ch != expected) return error.HttpInputError;
                        }
                        self.method = Method.Patch;
                    },
                    else => return error.HttpInputError,
                }
            },
            'H' => {
                inline for("EAD") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.HttpInputError;
                }
                self.method = Method.Head;
            },
            'D' => {
                inline for("ELETE") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.HttpInputError;
                }
                self.method = Method.Delete;
            },
            'O' => {
                inline for("PTIONS") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.HttpInputError;
                }
                self.method = Method.Options;

            },
            else => {
                //std.debug.warn("Unexpected method: {c}", .{ch});
                return error.HttpInputError;
            }
        }

        // Check separator
        ch = try stream.readByteFast();
        if (ch != ' ') return error.HttpInputError;

        // TODO: Validate the path
        //const index = buf.len;
        const index = stream.readCount();
        while (stream.readCount() < max_size) {
            ch = try stream.readByteFast();
            if (ch == ' ') {
                //self.path = buf.toSlice()[index..];
                self.path = buf.toSlice()[index..stream.readCount()-1];
                break;
            } else if (!isPrintableAscii(ch)) {
                return error.HttpInputError;
            }
            //buf.appendAssumeCapacity(ch); // We checked capacity already
        }
        if (self.path.len == 0) return error.HttpInputError;
        if (stream.readCount() == max_size) return error.StreamTooLong; // Too Big

        // Read version
        inline for("HTTP/1.") |expected| {
            ch = try stream.readByteFast();
            if (ch != expected) return error.HttpInputError;
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
        if (ch != '\n') return error.HttpInputError;
        return stream.readCount();
    }

    pub fn parseHeaders(self: *HttpRequest, stream: *IOStream,
                        timeout: u64, max_size: usize) !usize {
        const headers = &self.headers;

        // Reuse the request buffer for this
        const buf = &self.buffer;
        var index: usize = undefined;
        var key: ?[]u8 = null;
        var value: ?[]u8 = null;
        var ch: u8 = 0;

        // Strip any whitespace
        while (headers.items.len < headers.items.capacity()) {
            ch = try stream.readByteFast();
            switch (ch) {
                '\r' => {
                    ch = try stream.readByteFast();
                    if (ch != '\n') return error.HttpInputError;
                    break; // Empty line, we're done
                },
                '\n' => break, // Empty line, we're done
                ' ', '\t' => {
                    // Continuation of multi line header
                    if (key == null) return error.HttpInputError;
                },
                ':' => return error.HttpInputError, // Empty key
                else => {
                    //index = buf.len;
                    index = stream.readCount()-1;

                    // Read Key
                    while (stream.readCount() < max_size) {
                        if (ch == ':') {
                            //key = buf.toSlice()[index..];
                            key = buf.toSlice()[index..stream.readCount()-1];
                            break;
                        } else if (isTokenChar(ch)) {
                            return error.HttpInputError;
                        }
                        //try buf.append(ch);
                        ch = try stream.readByteFast();
                    }

                    // Strip whitespace
                    while (stream.readCount() < max_size) {
                        ch = try stream.readByteFast();
                        if (!(ch == ' ' or ch == '\t')) break;
                    }
                },
            }

            // Read value
            //index = buf.len;
            index = stream.readCount()-1;
            while (stream.readCount() < max_size) {
                if (!isPrintableAscii(ch)) {
                    if (isCtrlChar(ch)) break;
                }
                //try buf.append(ch);
                ch = try stream.readByteFast();
            }

            // TODO: Strip trailing spaces and tabs
            value = buf.toSlice()[index..stream.readCount()-1];
            //value = buf.toSlice()[index..buf.len];

            // Ignore
            while (stream.readCount() < max_size) {
                if (!isPrintableAscii(ch)) {
                    if (isCtrlChar(ch)) break;
                }
                ch = try stream.readByteFast();
            }

            // Check CRLF
            if (ch == '\r') {
                ch = try stream.readByteFast();
                if (ch != '\n') return error.HttpInputError;
            } else if (ch != '\n') {
                return error.HttpInputError;
            }

            //std.debug.warn("Found header: {}={}\n", .{key.?, value.?});

            // Next
            try headers.append(key.?, value.?);
        }
        if (stream.readCount() == max_size) return error.HeaderTooLong;
        return stream.readCount();
    }

    pub fn parseContentLength(self: *HttpRequest) !void {
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
            return error.HttpInputError;
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
            catch return error.HttpInputError;
    }


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
    "User-Agent: Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; ja-JP-mac; rv:1.9.2.3) Gecko/20100401 Firefox/3.6.3 " ++
    "Pathtraq/0.9\r\n" ++
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
    request.buffer = Bytes.fromOwnedSlice(allocator, stream._in_buffer);

    var n = try request.parseRequestLine(&stream, 0, 2048);
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
    request.buffer = Bytes.fromOwnedSlice(allocator, stream._in_buffer);

    const requests: usize = 1000000;
    var n: usize = 0;
    var timer = try std.time.Timer.start();

    var i: usize = 0; // 1M
    while (i < requests) : (i += 1) {
        // 10000k req/s 750MB/s (100 ns/req)
        n = try request.parseRequestLine(&stream, 0, 2048);
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
    //testing.expectError(error.HttpInputError,
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
//     testing.expectError(error.HttpInputError,
//             RequestStartLine.parse(a, "POST CRAP"));
//     testing.expectError(error.HttpInputError,
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
    request.buffer = Bytes.fromOwnedSlice(allocator, stream._in_buffer);

    var n = try request.parseRequestLine(&stream, 0, 2048);
    n = try request.parseHeaders(&stream, 0, 64000);
    var h = &request.headers;

    testing.expectEqual(@as(usize, 6), h.items.count());

    testing.expectEqualSlices(u8, "server", try h.get("Host"));
    testing.expectEqualSlices(u8, "Mozilla/5.0 (X11; Linux x86_64) Gecko/20130501 Firefox/30.0 AppleWebKit/600.00 Chrome/30.0.0000.0 Trident/10.0 Safari/600.00",
        try h.get("User-Agent"));
    testing.expectEqualSlices(u8, "uid=012345678901234532323; __utma=1.1234567890.1234567890.1234567890.1234567890.12; wd=2560x1600",
        try h.get("Cookie"));

}

test "bench-parse-request-headers" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;

    var stream = try IOStream.initTest(allocator, TEST_GET_1);
    var request = try HttpRequest.init(allocator);
    request.buffer = Bytes.fromOwnedSlice(allocator, stream._in_buffer);

    const requests: usize = 1000000;
    var n: usize = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0; // 1M
    while (i < requests) : (i += 1) {
        //     1031k req/s 725MB/s (969 ns/req)
        n = try request.parseRequestLine(&stream, 0, 2048);
        n = try request.parseHeaders(&stream, 0, 64000);
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


