const std = @import("std");
const builtin = @import("builtin");
const ascii = std.ascii;
const mem = std.mem;
const time = std.time;

const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Headers = @import("headers.zig").Headers;
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


pub const Request = struct {
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

    pub const Scheme = enum {
        Http,
        Https,
        Unknown
    };

    // ------------------------------------------------------------------------
    // Common request fields
    // ------------------------------------------------------------------------
    method: Method = .Unknown,
    version: Version = .Unknown,
    scheme: Scheme = .Unknown,

    // Full request uri
    uri: []const u8 = "",

    // Host part of the uri
    host: []const u8 = "",

    // Path part of the uri
    path: []const u8 = "",

    // Query part of the uri
    // TODO: Parse this into a map
    query: []const u8 = "",

    // Content length pulled from the content-length header (if present)
    content_length: usize = 0,

    // All headers
    headers: Headers,

    // Body of request
    body: []const u8 = "",

    // ------------------------------------------------------------------------
    // Internal fields
    // ------------------------------------------------------------------------

    // Set once the read is complete and no more reads will be done on the
    // vafter which it's safe to defer processing to another thread
    read_finished: bool = false,

    // Holds the whole request (for now)
    buffer: Bytes,

    // Slice from the start to the body
    head: []const u8 = "",

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------

    pub fn init(allocator: *Allocator) !Request {
        return Request{
            .buffer = try Bytes.initCapacity(allocator, mem.page_size),
            .headers = try Headers.initCapacity(allocator, 64),
        };
    }

    pub fn initCapacity(allocator: *Allocator, buffer_size: usize,
                        max_headers: usize) !Request {
        return Request{
            .buffer = try Bytes.initCapacity(allocator, buffer_size),
            .headers = try Headers.initCapacity(allocator, max_headers),
        };
    }

    // ------------------------------------------------------------------------
    // Testing
    // ------------------------------------------------------------------------
    pub fn initTest(allocator: *Allocator, stream: *IOStream) !Request {
        //if (!builtin.is_test) @compileError("This is for testing only");
        return Request{
            .buffer = Bytes.fromOwnedSlice(allocator, stream.in_buffer),
            .headers = try Headers.initCapacity(allocator, 64),
        };
    }

    // ------------------------------------------------------------------------
    // Parsing
    // ------------------------------------------------------------------------

    // Parse using default sizes
    // See https://developer.mozilla.org/en-US/docs/Web/HTTP/Messages
    pub fn parse(self: *Request, stream: *IOStream) !usize {
        // Swap the buffer so no copying occurs while reading
        // Want to dump directly into the request buffer
        try self.buffer.resize(mem.page_size);
        stream.swapBuffer(self.buffer.toSlice());

        // TODO: This should retry if the error is EndOfBuffer which means
        // it got a partial request
        try stream.fillBuffer();
        return self.parseNoSwap(stream);
    }

    inline fn parseNoSwap(self: *Request, stream: *IOStream) !usize {
        const start = stream.readCount();

        // FIXME make these configurable
        try self.parseRequestLine(stream, 2048);
        try self.parseHeaders(stream, 32*1024);
        try self.parseContentLength(100*1024*1024);

        const end = stream.readCount();
        self.head = self.buffer.toSlice()[start..end];
        return end-start;
    }

    // Based on picohttpparser
    // FIXME: Use readByte instead of readByteFast
    // readByteFast is 3x faster but doesn't handle slowloris
    pub inline fn parseRequestLine(self: *Request, stream: *IOStream, max_size: usize) !void {
        const buf = &self.buffer;

        // FIXME: If the whole method is not in the initial read
        // buffer this bails out
        var ch: u8 = try stream.readByteFast();

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

        // Parse Uri
        try self.parseUri(stream, max_size);

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
    }

    // Parse the url, this populates, the uri, host, scheme, and query
    // when available. The trailing space is consumed.
    pub inline fn parseUri(self: *Request, stream: *IOStream, max_size: usize) !void {
        const buf = self.buffer.toSlice();
        const index = stream.readCount();

        var ch = try stream.readByteFast();
        switch (ch) {
            '/' => {},
            'h', 'H' => {
                // A complete URL, known as the absolute form
                inline for("ttp") |expected| {
                    ch = ascii.toLower(try stream.readByteFast());
                    if (ch != expected) return error.BadRequest;
                }

                ch = ascii.toLower(try stream.readByteFast());
                if (ch == 's') {
                    self.scheme = .Https;
                    ch = try stream.readByteFast();
                } else {
                    self.scheme = .Http;
                }
                if (ch != ':') return error.BadRequest;

                inline for("//") |expected| {
                    ch = try stream.readByteFast();
                    if (ch != expected) return error.BadRequest;
                }

                // Read host
                // TODO: This does not support the ip address format
                const host_start = stream.readCount();
                while (stream.readCount() < max_size) {
                    ch = try stream.readByteFast();
                    if (!ascii.isAlNum(ch) and ch != '.' and ch != '-') break;
                }

                if (ch == ':') {
                    // Read port, can be at most 5 digits (65535) so we
                    // want to read at least 6 bytes to ensure we catch the /
                    inline for("012345") |i| {
                        ch = try stream.readByteFast();
                        if (!ascii.isDigit(ch)) break;
                    }
                }
                self.host = buf[host_start..stream.readCount()-1];
            },
            '*' => {
                // The asterisk form, a simple asterisk ('*') is used with
                // OPTIONS, representing the server as a whole.
                ch = try stream.readByteFast();
                if (ch != ' ') return error.BadRequest;
                self.uri = buf[index..stream.readCount()];
                return;
            },
            // TODO: Authority form is unsupported
            else => return error.BadRequest,
        }

        if (ch != '/') return error.BadRequest;
        const end = try self.parseUriPath(stream, max_size);
        self.uri = buf[index..end];
    }

    pub inline fn parseUriPath(self: *Request, stream: *IOStream, max_size: usize) !usize {
        const buf = self.buffer.toSlice();
        const index = stream.readCount()-1;
        var query_start: ?usize = null;
        while (stream.readCount() < max_size) {
            const ch = try stream.readByteFast();
            if (!ascii.isGraph(ch)) {
                if (ch == ' ') break;
                return error.BadRequest;
            } else if (ch == '?') {
                if (query_start != null) return error.BadRequest;
                query_start = stream.readCount();
            }
        }
        if (stream.readCount() == max_size) return error.RequestUriTooLong; // Too Big

        const end = stream.readCount()-1;
        if (query_start) |q| {
            self.query = buf[q..end];
            self.path = buf[index..q-1];
        } else {
            self.path = buf[index..end];
        }
        return end;
    }

    pub inline fn parseHeaders(self: *Request, stream: *IOStream, max_size: usize) !void {
        const headers = &self.headers;

        // Reuse the request buffer for this
        const buf = &self.buffer;
        var index: usize = undefined;
        var key: ?[]u8 = null;
        var value: ?[]u8 = null;

        // Strip any whitespace
        while (headers.items.len < headers.items.capacity()) {
            // TODO: This assumes that the whole header in the buffer
            var ch = try stream.readByteFast();

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
    }

    pub inline fn parseContentLength(self: *Request, max_size: usize) !void {
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
        if (it.next()) |piece| {
            try headers.put("Content-Length", piece);
        }

        self.content_length = std.fmt.parseInt(u32, content_length_header, 10)
            catch return error.BadRequest;

        if (self.content_length > max_size) {
            return error.RequestEntityTooLarge;
        }
    }

    //pub fn parseCookie(self: *Request) !void {
    //    // TODO Do while parsing headers
    //}


    // ------------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------------

    // Reset the request to it's initial state so it can be reused
    // without needing to reallocate. Usefull when using an ObjectPool
    pub fn reset(self: *Request) void {
        self.method = .Unknown;
        self.scheme = .Unknown;
        self.path = "";
        self.uri = "";
        self.query = "";
        self.head = "";
        self.body = "";


        self.version = .Unknown;
        self.content_length = 0;
        self.read_finished = false;
        self.headers.reset();
        self.buffer.len = 0;
    }

    pub fn deinit(self: *Request) void {
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


const TEST_GET_2 =
    \\GET /pixel/of_doom.png?id=t3_25jzeq-t8_k2ii&hash=da31d967485cdbd459ce1e9a5dde279fef7fc381&r=1738649500 HTTP/1.1
    \\Host: pixel.redditmedia.com
    \\User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:15.0) Gecko/20100101 Firefox/15.0.1
    \\Accept: image/png,image/*;q=0.8,*/*;q=0.5
    \\Accept-Language: en-us,en;q=0.5
    \\Accept-Encoding: gzip, deflate
    \\Connection: keep-alive
    \\Referer: http://www.reddit.com/
    \\
    \\
;

const TEST_POST_1 =
    \\POST https://bs.serving-sys.com/BurstingPipe/adServer.bs?cn=tf&c=19&mc=imp&pli=9994987&PluID=0&ord=1400862593644&rtu=-1 HTTP/1.1
    \\Host: bs.serving-sys.com
    \\User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:15.0) Gecko/20100101 Firefox/15.0.1
    \\Accept: image/png,image/*;q=0.8,*/*;q=0.5
    \\Accept-Language: en-us,en;q=0.5
    \\Accept-Encoding: gzip, deflate
    \\Connection: keep-alive
    \\Referer: http://static.adzerk.net/reddit/ads.html?sr=-reddit.com&bust2
    \\
    \\
;

test "parse-request-line" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;
    var stream = try IOStream.initTest(allocator, TEST_GET_1);
    var request = try Request.initTest(allocator, &stream);
    stream.startTest();
    _ = try request.parseNoSwap(&stream);

    testing.expectEqual(request.method, Request.Method.Get);
    testing.expectEqual(request.version, Request.Version.Http1_1);
    testing.expectEqualSlices(u8, request.path,
        "/wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg");

    stream = try IOStream.initTest(allocator, TEST_GET_2);
    request = try Request.initTest(allocator, &stream);
    stream.startTest();
    _ = try request.parseNoSwap(&stream);
    testing.expectEqual(request.method, Request.Method.Get);
    testing.expectEqual(request.version, Request.Version.Http1_1);
    testing.expectEqualSlices(u8, request.uri,
        "/pixel/of_doom.png?id=t3_25jzeq-t8_k2ii&hash=da31d967485cdbd459ce1e9a5dde279fef7fc381&r=1738649500");
    testing.expectEqualSlices(u8, request.path, "/pixel/of_doom.png");
    testing.expectEqualSlices(u8, request.query,
        "id=t3_25jzeq-t8_k2ii&hash=da31d967485cdbd459ce1e9a5dde279fef7fc381&r=1738649500");

    stream = try IOStream.initTest(allocator, TEST_POST_1);
    request = try Request.initTest(allocator, &stream);
    stream.startTest();
    _ = try request.parseNoSwap(&stream);
    testing.expectEqual(request.method, Request.Method.Post);
    testing.expectEqual(request.version, Request.Version.Http1_1);
    testing.expectEqualSlices(u8, request.uri,
        "https://bs.serving-sys.com/BurstingPipe/adServer.bs?cn=tf&c=19&mc=imp&pli=9994987&PluID=0&ord=1400862593644&rtu=-1");
    testing.expectEqualSlices(u8, request.host, "bs.serving-sys.com");
    testing.expectEqualSlices(u8, request.path, "/BurstingPipe/adServer.bs");
    testing.expectEqualSlices(u8, request.query, "cn=tf&c=19&mc=imp&pli=9994987&PluID=0&ord=1400862593644&rtu=-1");

}

test "parse-request-multiple" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;
    const REQUESTS = TEST_GET_1 ++ TEST_GET_2 ++ TEST_POST_1;
    var stream = try IOStream.initTest(allocator, REQUESTS);
    var request = try Request.initTest(allocator, &stream);
    stream.startTest();

    var n = try request.parseNoSwap(&stream);
    testing.expectEqualSlices(u8, request.path,
        "/wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg");
    n = try request.parseNoSwap(&stream);
    testing.expectEqualSlices(u8, request.path, "/pixel/of_doom.png");
    n = try request.parseNoSwap(&stream);
    // I have no idea why but this seems to mess up the speed of the next test
    //testing.expectEqualSlices(u8, request.path, "/BurstingPipe/adServer.bs");

}

test "bench-parse-request-line" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;
    var stream = try IOStream.initTest(allocator, TEST_GET_1);
    var request = try Request.initTest(allocator, &stream);

    const requests: usize = 1000000;
    var n: usize = 0;
    var timer = try std.time.Timer.start();

    var i: usize = 0; // 1M
    while (i < requests) : (i += 1) {
        stream.startTest();

        // 10000k req/s 750MB/s (100 ns/req)
        try request.parseRequestLine(&stream, 2048);
        n = stream.readCount();
        request.reset();
        fba.reset();
        request.buffer.len = stream.in_buffer.len;
    }
    const ns = timer.lap();
    const ms = ns / 1000000;
    const bytes = requests * n / time.ms_per_s;
    std.debug.warn("\n    {}k req/s {}MB/s ({} ns/req)\n",
        .{requests/ms, bytes/ms, ns/requests});

    //stream.load("POST CRAP");
    //request = try Request.init(allocator);
    //testing.expectError(error.BadRequest,
    //    request.parseRequestLine(&stream, 0));

//     var line = try Request.StartLine.parse(a, "GET /foo HTTP/1.1");
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
    var request = try Request.initTest(allocator, &stream);
    stream.startTest();
    _ = try request.parseNoSwap(&stream);
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
    request = try Request.initTest(allocator, &stream);
    _ = try request.parseNoSwap(&stream);
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
    var request = try Request.initTest(allocator, &stream);

    const requests: usize = 1000000;
    var n: usize = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0; // 1M
    while (i < requests) : (i += 1) {
        //     1031k req/s 725MB/s (969 ns/req)
        n = try request.parseNoSwap(&stream);
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
