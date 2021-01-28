// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const time = std.time;
const Address = std.net.Address;

const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AtomicFile = std.fs.AtomicFile;
const Headers = @import("headers.zig").Headers;
const Cookies = @import("cookies.zig").Cookies;

const util = @import("util.zig");
const Bytes = util.Bytes;
const IOStream = util.IOStream;

const simd = @import("simd.zig");

const GET_ = @bitCast(u32, [4]u8{'G', 'E', 'T', ' '});
const PUT_ = @bitCast(u32, [4]u8{'P', 'U', 'T', ' '});
const POST = @bitCast(u32, [4]u8{'P', 'O', 'S', 'T'});
const HEAD = @bitCast(u32, [4]u8{'H', 'E', 'A', 'D'});
const PATC = @bitCast(u32, [4]u8{'P', 'A', 'T', 'C'});
const DELE = @bitCast(u32, [4]u8{'D', 'E', 'L', 'E'});
const OPTI = @bitCast(u32, [4]u8{'O', 'P', 'T', 'I'});
const ONS_ = @bitCast(u32, [4]u8{'O', 'N', 'S', '_'});
const HTTP = @bitCast(u32, [4]u8{'H', 'T', 'T', 'P'});
const V1p1 = @bitCast(u32, [4]u8{'/', '1', '.', '1'});
const V1p0 = @bitCast(u32, [4]u8{'/', '1', '.', '0'});
const V2p0 = @bitCast(u32, [4]u8{'/', '2', '.', '0'});
const V3p0 = @bitCast(u32, [4]u8{'/', '3', '.', '0'});


fn skipGraphFindSpaceOrQuestionMark(ch: u8) !bool {
    if (!ascii.isGraph(ch)) {
        return if (ch == ' ') true else error.BadRequest;
    }
    return ch == '?';
}

fn skipGraphFindSpace(ch: u8) !bool {
    if (!ascii.isGraph(ch)) {
        return if (ch == ' ') true else error.BadRequest;
    }
    return if (ch == '?') error.BadRequest else false;
}

fn skipHostChar(ch: u8) bool {
    return !ascii.isAlNum(ch) and !(ch == '.' or ch == '-');
}


pub const Request = struct {
    pub const Content = struct {
        pub const StorageType = enum {
            Buffer,
            TempFile,
        };
        type: StorageType,
        data: union {
            buffer: []const u8,
            file: AtomicFile,
        },
    };

    pub const ParseOptions = struct {
        // If request line is longer than this throw an error
        max_request_line_size: usize = 2048,

        // If the whole request header is larger than this throw an error
        max_header_size: usize = 10*1024,

        // If the content length is larger than this throw an error
        max_content_length: usize = 1000*1024*1024,
    };

    pub const Method = enum {
        Unknown,
        Get,
        Put,
        Post,
        Patch,
        Head,
        Delete,
        Options,
    };

    pub const Version = enum {
        Unknown,
        Http1_0,
        Http1_1,
        Http2_0,
        Http3_0,
    };

    pub const Scheme = enum {
        Unknown,
        Http,
        Https,
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

    // Slice from the start to the body
    head: []const u8 = "",

    // Content length pulled from the content-length header (if present)
    content_length: usize = 0,

    // Set once the read is complete and no more reads will be done on the
    // after which it's safe to defer processing to another thread
    read_finished: bool = false,

    // Url captures
    args: ?[]?[]const u8 = null,

    // All headers
    headers: Headers,

    // Cookies
    // this is not parsed by default, if you need cookies use readCookies
    cookies: Cookies,

    // Holds the whole request (for now)
    buffer: Bytes,

    // Stream used for reading
    stream: ?*IOStream = null,

    // Body of request will be one of these depending on the size
    content: ?Content = null,

    // Client address
    client: Address = undefined,

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------
    pub fn initCapacity(allocator: *Allocator,
                        buffer_size: usize,
                        max_headers: usize,
                        max_cookies: usize) !Request {
        return Request{
            .buffer = try Bytes.initCapacity(allocator, buffer_size),
            .headers = try Headers.initCapacity(allocator, max_headers),
            .cookies = try Cookies.initCapacity(allocator, max_cookies),
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
            .cookies = try Cookies.initCapacity(allocator, 64),
        };
    }

    // ------------------------------------------------------------------------
    // Parsing
    // ------------------------------------------------------------------------
    pub fn parse(self: *Request, stream: *IOStream, options: ParseOptions) !void {
        // Swap the buffer so no copying occurs while reading
        // Want to dump directly into the request buffer
        self.buffer.expandToCapacity();
        stream.swapBuffer(self.buffer.items);

        if (stream.amountBuffered() == 0) {
            try stream.fillBuffer();
        }

        var start = stream.readCount();

//         std.log.warn(
//            \\
//            \\========== Buffer at {} ==========
//            \\{}
//            \\==============================
//            , .{start, stream.readBuffered()});
//

        while (true) {
            self.parseNoSwap(stream, options) catch |err| switch (err) {
                error.EndOfBuffer => {
                    const n = try stream.shiftAndFillBuffer(start);
                    if (n == 0) return error.EndOfStream;
                    start = 0;
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    inline fn parseTest(self: *Request, stream: *IOStream) !void {
        return self.parseNoSwap(stream, .{});
    }

    fn parseNoSwap(self: *Request, stream: *IOStream, options: ParseOptions) !void {
        const start = stream.readCount();

        try self.parseRequestLine(stream, options.max_request_line_size);
        try self.headers.parse(&self.buffer, stream, options.max_header_size);
        try self.parseContentLength(options.max_content_length);

        const end = stream.readCount();
        self.head = self.buffer.items[start..end];
    }

    pub fn parseRequestLine(self: *Request, stream: *IOStream, max_size: usize) !void {
        if (stream.isEmpty()) return error.EndOfBuffer;

        // Skip leading newline if any
        var ch: u8 = stream.lastByte();
        switch (ch) {
            '\r' => {
                stream.skipBytes(1);
                ch = try stream.readByteSafe();
                if (ch != '\n') return error.BadRequest;
            },
            '\n' => {
                stream.skipBytes(1);
            },
            else => {},
        }

        // Parse method
        try self.parseMethod(stream);

        // Parse path
        try self.parseUri(stream, max_size);

        // Read version
        try self.parseVersion(stream);

        // Read to end of the line
        ch = try stream.readByteSafe();
        if (ch == '\r') {
            ch = try stream.readByteSafe();
        }
        if (ch != '\n') return error.BadRequest;
    }

    // Parses first 8 bytes and checks the space
    pub fn parseMethod(self: *Request, stream: *IOStream) !void {
        const buf = stream.readBuffered();
        if (buf.len < 8) return error.EndOfBuffer;
        stream.skipBytes(4);
        const method = @bitCast(u32, buf[0..4].*);
        self.method = switch (method) {
            GET_ => Method.Get,
            PUT_ => Method.Put,
            POST => if (stream.readByteUnsafe() == ' ') Method.Post else Method.Unknown,
            HEAD => if (stream.readByteUnsafe() == ' ') Method.Head else Method.Unknown,
            DELE => if (stream.readByteUnsafe() == 'T' and
                        stream.readByteUnsafe() == 'E' and
                        stream.readByteUnsafe() == ' ') Method.Delete
                    else Method.Unknown,
            PATC => if (stream.readByteUnsafe() == 'H' and
                        stream.readByteUnsafe() == ' ') Method.Patch
                    else Method.Unknown,
            OPTI => blk: {
                stream.skipBytes(4);
                const r = if (@bitCast(u32, buf[4..8].*) != ONS_) Method.Options
                    else Method.Unknown;
                break :blk r;
            },
            else => Method.Unknown, // Unknown method or doesn't have a space
        };
        if (self.method == .Unknown) return error.BadRequest;
    }

    // Parses HTTP/X.Y
    pub fn parseVersion(self: *Request, stream: *IOStream) !void {
        const buf = stream.readBuffered();
        if (buf.len < 8) return error.EndOfBuffer;
        if (@bitCast(u32, buf[0..4].*) != HTTP) return error.BadRequest;
        self.version = switch (@bitCast(u32, buf[4..8].*)) {
            V1p0 => .Http1_0,
            V1p1 => .Http1_1,
            V2p0 => .Http2_0,
            V3p0 => .Http3_0,
            else => .Unknown,
        };
        if (self.version == .Unknown) return error.UnsupportedHttpVersion;
        stream.skipBytes(8);
    }

    // Parse the url, this populates, the uri, host, scheme, and query
    // when available. The trailing space is consumed.
    pub fn parseUri(self: *Request, stream: *IOStream, max_size: usize) !void {
        //@setRuntimeSafety(false); // We already check it
        const buf = self.buffer.items;
        const index = stream.readCount();
        const limit = std.math.min(max_size, stream.amountBuffered());
        const read_limit = limit + stream.readCount();

        // Bounds check, Must have "/ HTTP/x.x\n\n"
        if (stream.amountBuffered() < 12) return error.EndOfBuffer;

        // Parse host if any
        var path_start = index;
        var ch = stream.readByteUnsafe();
        switch (ch) {
            '/' => {},
            'h', 'H' => {
                // A complete URL, known as the absolute form
                inline for("ttp") |expected| {
                    ch = ascii.toLower(stream.readByteUnsafe());
                    if (ch != expected) return error.BadRequest;
                }

                ch = stream.readByteUnsafe();
                if (ch == 's' or ch == 'S') {
                    self.scheme = .Https;
                    ch = stream.readByteUnsafe();
                } else {
                    self.scheme = .Http;
                }
                if (ch != ':') return error.BadRequest;

                inline for("//") |expected| {
                    ch = stream.readByteUnsafe();
                    if (ch != expected) return error.BadRequest;
                }

                // Read host
                const host_start = stream.readCount();
                ch = stream.readByteUnsafe();
                ch = stream.readUntilExpr(skipHostChar, ch, read_limit);
                if (stream.readCount() >= read_limit) {
                    if (stream.isEmpty()) return error.EndOfBuffer;
                    return error.RequestUriTooLong; // Too Big
                }

                if (ch == ':') {
                    // Read port, can be at most 5 digits (65535) so we
                    // want to read at least 6 bytes to ensure we catch the /
                    inline for("012345") |i| {
                        ch = try stream.readByteSafe();
                        if (!ascii.isDigit(ch)) break;
                    }
                }
                if (ch != '/') return error.BadRequest;
                path_start = stream.readCount()-1;
                self.host = buf[host_start..path_start];

            },
            '*' => {
                // The asterisk form, a simple asterisk ('*') is used with
                // OPTIONS, representing the server as a whole.
                ch = stream.readByteUnsafe();
                if (ch != ' ') return error.BadRequest;
                self.uri = buf[index..stream.readCount()];
                return;
            },
            // TODO: Authority form is unsupported
            else => return error.BadRequest,
        }

        // Read path
        ch = try stream.readUntilExprValidate(error{BadRequest},
                skipGraphFindSpaceOrQuestionMark, ch, read_limit);
        var end = stream.readCount()-1;
        self.path = buf[path_start..end];

        // Read query
        if (ch == '?') {
            const q = stream.readCount();
            ch = try stream.readByteSafe();
            ch = try stream.readUntilExprValidate(error{BadRequest},
                skipGraphFindSpace, ch, read_limit);
            end = stream.readCount()-1;
            self.query = buf[q..end];
        }
        if (stream.readCount() >= read_limit) {
            if (stream.isEmpty()) return error.EndOfBuffer;
            return error.RequestUriTooLong; // Too Big
        }
        if (ch != ' ') return error.BadRequest;
        self.uri = buf[index..end];
    }

    pub fn parseContentLength(self: *Request, max_size: usize) !void {
        const headers = &self.headers;
        // Read content length
        const header: ?[]const u8 = headers.get("Content-Length") catch null;
        if (header) |content_length| {
            if (headers.contains("Transfer-Encoding")) {
                // Response cannot contain both Content-Length and
                // Transfer-Encoding headers.
                // http://tools.ietf.org/html/rfc7230#section-3.3.3
                return error.BadRequest;
            }

            // Proxies sometimes cause Content-Length headers to get
            // duplicated.  If all the values are identical then we can
            // use them but if they differ it's an error.
            if (mem.indexOf(u8, content_length, ",")) |i| {
                try headers.put("Content-Length", content_length[0..i]);
            }

            self.content_length = std.fmt.parseInt(u32, content_length, 10)
                catch return error.BadRequest;

            if (self.content_length > max_size) {
                return error.RequestEntityTooLarge;
            }
        } // Should already be 0
    }

    // Read the cookie header and return a pointer to the cookies if
    // they exist
    pub fn readCookies(self: *Request) !?*Cookies {
        if (self.cookies.parsed) return &self.cookies;
        if (self.headers.getOptional("Cookie")) |header| {
            try self.cookies.parse(header);
            return &self.cookies;
        }
        return null;
    }

    pub fn readBody(self: *Request, stream: *IOStream) !void {
        defer self.read_finished = true;
        if (self.content_length > 0) {
            try self.readFixedBody(stream);
        } else if (self.headers.eqlIgnoreCase("Transfer-Encoding", "chunked")) {
            try self.readChunkedBody(stream);
        }
    }

    pub fn readFixedBody(self: *Request, stream: *IOStream) !void {
        // End of the request
        const end_of_headers = stream.readCount();

        // Anything else is the body
        const end_of_body = end_of_headers + self.content_length;

        // Take whatever is still buffered from the initial read up to the
        // end of the body
        const amt = stream.consumeBuffered(end_of_body);
        const start = end_of_headers + amt;

        // Check if we can fit everything in the request buffer
        // if not, write the body to a temp file
        if (end_of_body > self.buffer.capacity) {
            std.log.warn("Write to temp file", .{});
            // TODO: Write the body to a file
            const tmp = std.fs.cwd();//.openDir("/tmp/");
            var f = try tmp.atomicFile("zhp.tmp", .{});

            // Copy what was buffered
            var writer = f.file.writer();
            try writer.writeAll(self.buffer.items[end_of_headers..start]);

            // Switch the stream to unbuffered mode and read directly
            // into the request buffer
            stream.readUnbuffered(true);
            defer stream.readUnbuffered(false);

            var reader = stream.reader();
            var left: usize = end_of_body - start;
            while (left > 0) {
                var buf: [4096]u8 = undefined;
                const end = std.math.min(left, buf.len);
                const n = try reader.read(buf[0..end]);
                if (n == 0) break;
                try writer.writeAll(buf[0..n]);
                left -= n;
            }

            self.content = Content{
                .type = .TempFile,
                .data = .{.file=f},
            };
        } else {
            // We can fit it in memory
            const body = self.buffer.items[end_of_headers..end_of_body];

            // Check if the full body was already read into the buffer
            if (start < end_of_body) {
                // We need to read more
                // Switch the stream to unbuffered mode and read directly
                // into the request buffer
                stream.readUnbuffered(true);
                defer stream.readUnbuffered(false);
                const rest_of_body = self.buffer.items[start..end_of_body];
                try stream.reader().readNoEof(rest_of_body);
            }
            self.content = Content{
                .type = .Buffer,
                .data = .{.buffer=body},
            };
        }
    }

    pub fn readChunkedBody(self: *Request, stream: *IOStream) !void {
        return error.NotImplemented; // TODO: This
    }

    pub fn format(
        self: Request,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        try std.fmt.format(out_stream, "Request{{\n", .{});
        try std.fmt.format(out_stream, "  .client=\"{s}\",\n", .{self.client});
        try std.fmt.format(out_stream, "  .method={s},\n", .{self.method});
        try std.fmt.format(out_stream, "  .version={s},\n", .{self.version});
        try std.fmt.format(out_stream, "  .scheme={s},\n", .{self.scheme});
        try std.fmt.format(out_stream, "  .host=\"{s}\",\n", .{self.host});
        try std.fmt.format(out_stream, "  .path=\"{s}\",\n", .{self.path});
        try std.fmt.format(out_stream, "  .query=\"{s}\",\n", .{self.query});
        try std.fmt.format(out_stream, "  .headers={s},\n", .{self.headers});
        if (self.content) |content| {
            const n = std.math.min(self.content_length, 1024);
            switch (content.type) {
                .TempFile => {
//                     content.data.file
//                     try std.fmt.format(out_stream, "   .body='{}',\n", .{
//                         content.data.file[0..n]});
                },
                .Buffer => {
                    try std.fmt.format(out_stream, "  .body=\"{}\",\n", .{
                        content.data.buffer[0..n]});
                }
            }

        }
        try std.fmt.format(out_stream, "}}", .{});
    }

    // ------------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------------

    // Reset the request to it's initial state so it can be reused
    // without needing to reallocate. Usefull when using an ObjectPool
    pub fn reset(self: *Request) void {
        self.method = .Unknown;
        self.version = .Unknown;
        self.scheme = .Unknown;
        self.uri = "";
        self.host = "";
        self.path = "";
        self.query = "";
        self.head = "";
        self.content_length = 0;
        self.read_finished = false;
        self.args = null;
        self.buffer.items.len = 0;
        self.headers.reset();
        self.cookies.reset();
        self.cleanup();
    }

    pub fn cleanup(self: *Request) void {
        if (self.content) |*content| {
            switch (content.type) {
                .TempFile => {
                    content.data.file.deinit();
                },
                .Buffer => {}
            }
            self.content = null;
        }
    }

    pub fn deinit(self: *Request) void {
        self.buffer.deinit();
        self.headers.deinit();
        self.cookies.deinit();
        self.cleanup();
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



fn expectParseResult(buf: []const u8,  request: Request) !void {
    var buffer: [1024*1024]u8 = undefined;
    const allocator = &std.heap.FixedBufferAllocator.init(&buffer).allocator;
    var stream = try IOStream.initTest(allocator, buf);
    var r = try Request.initTest(allocator, &stream);
    try r.parseTest(&stream);

    testing.expectEqual(request.method, r.method);
    testing.expectEqual(request.version, r.version);
    if (request.scheme != .Unknown) {
        testing.expectEqual(request.scheme, r.scheme);
    }
    testing.expectEqualStrings(request.uri, r.uri);
    testing.expectEqualStrings(request.path, r.path);
    testing.expectEqualStrings(request.query, r.query);
    testing.expectEqualStrings(request.host, r.host);
}

fn expectParseError(err: anyerror, buf: []const u8) void {
    var buffer: [1024*1024]u8 = undefined;
    const allocator = &std.heap.FixedBufferAllocator.init(&buffer).allocator;
    var stream = IOStream.initTest(allocator, buf) catch unreachable;
    var request = Request.initTest(allocator, &stream) catch unreachable;
    testing.expectError(err, request.parseTest(&stream));
}

test "01-parse-request-get" {
    try expectParseResult(
        \\GET / HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    , .{
        .headers = undefined, // Dont care
        .buffer = undefined, // Dont care
        .client = undefined, // Dont care
        .cookies = undefined, // Don't care
        .method = .Get,
        .version = .Http1_1,
        .uri = "/",
        .path = "/",
    });
}

test "01-parse-request-get-path" {
    try expectParseResult(TEST_GET_1, .{
        .headers = undefined, // Dont care
        .buffer = undefined, // Dont care
        .client = undefined, // Dont care
        .cookies = undefined, // Don't care
        .method = .Get,
        .version = .Http1_1,
        .uri = "/wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg",
        .path = "/wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg",

    });
}

test "01-parse-request-get-query" {
    try expectParseResult(TEST_GET_2, .{
        .headers = undefined, // Dont care
        .buffer = undefined, // Dont care
        .client = undefined, // Dont care
        .cookies = undefined, // Don't care
        .method = .Get,
        .version = .Http1_1,
        .uri = "/pixel/of_doom.png?id=t3_25jzeq-t8_k2ii&hash=da31d967485cdbd459ce1e9a5dde279fef7fc381&r=1738649500",
        .path = "/pixel/of_doom.png",
        .query = "id=t3_25jzeq-t8_k2ii&hash=da31d967485cdbd459ce1e9a5dde279fef7fc381&r=1738649500"
    });
}

test "01-parse-request-post-proxy" {
    try expectParseResult(TEST_POST_1, .{
        .headers = undefined, // Dont care
        .buffer = undefined, // Dont care
        .client = undefined, // Dont care
        .cookies = undefined, // Don't care
        .method = .Post,
        .version = .Http1_1,
        .uri = "https://bs.serving-sys.com/BurstingPipe/adServer.bs?cn=tf&c=19&mc=imp&pli=9994987&PluID=0&ord=1400862593644&rtu=-1",
        .host = "bs.serving-sys.com",
        .path = "/BurstingPipe/adServer.bs",
        .query = "cn=tf&c=19&mc=imp&pli=9994987&PluID=0&ord=1400862593644&rtu=-1",
    });
}

test "01-parse-request-delete" {
    try expectParseResult(
        \\DELETE /api/users/12/ HTTP/1.0
        \\Host: bs.serving-sys.com
        \\Connection: keep-alive
        \\
        \\
    , .{
        .headers = undefined, // Dont care
        .buffer = undefined, // Dont care
        .client = undefined, // Dont care
        .cookies = undefined, // Don't care
        .method = .Delete,
        .version = .Http1_0,
        .path = "/api/users/12/",
        .uri = "/api/users/12/",
    });
}

test "01-parse-request-proxy" {
    try expectParseResult(
        \\PUT https://127.0.0.1/upload/ HTTP/1.1
        \\Connection: keep-alive
        \\
        \\
    , .{
        .headers = undefined, // Dont care
        .buffer = undefined, // Dont care
        .client = undefined, // Dont care
        .cookies = undefined, // Don't care
        .method = .Put,
        .version = .Http1_1,
        .scheme = .Https,
        .host = "127.0.0.1",
        .uri = "https://127.0.0.1/upload/",
        .path = "/upload/",
    });
}


test "01-parse-request-port" {
    try expectParseResult(
        \\PATCH https://127.0.0.1:8080/upload/ HTTP/1.1
        \\Connection: keep-alive
        \\
        \\
    , .{
        .headers = undefined, // Dont care
        .buffer = undefined, // Dont care
        .client = undefined, // Dont care
        .cookies = undefined, // Don't care
        .method = .Patch,
        .version = .Http1_1,
        .scheme = .Https,
        .host = "127.0.0.1:8080",
        .uri = "https://127.0.0.1:8080/upload/",
        .path = "/upload/",
    });
}

test "01-invalid-method" {
    expectParseError(error.BadRequest,
        \\GOT /this/path/is/nonsense HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-invalid-host-char" {
    expectParseError(error.BadRequest,
        \\GET http://not;valid/ HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-invalid-host-scheme" {
    expectParseError(error.BadRequest,
        \\GET htx://192.168.0.0/ HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-invalid-host-scheme-1" {
    expectParseError(error.BadRequest,
        \\GET HTTP:/localhost/ HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-invalid-host-port" {
    expectParseError(error.BadRequest,
        \\GET HTTP://localhost:aef/ HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-invalid-method-2" {
    expectParseError(error.BadRequest,
        \\DEL TE /api/users/12/ HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-no-space" {
    expectParseError(error.BadRequest,
        \\GET/this/path/is/nonsense HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-bad-url" {
    expectParseError(error.BadRequest,
        \\GET 0000000000000000000000000 HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-bad-url-character" {
    expectParseError(error.BadRequest,
        "GET /"++ [_]u8{0} ++"/ HTTP/1.1\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n\r\n"
    );
}

test "01-bad-url-character-2" {
    expectParseError(error.BadRequest,
        "GET /\t HTTP/1.1\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n\r\n"
    );
}

test "01-bad-query" {
    expectParseError(error.BadRequest,
        \\GET /this/is?query1?query2 HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}


test "01-empty-request-line" {
    expectParseError(error.BadRequest,
        \\
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-unsupported-version" {
    expectParseError(error.UnsupportedHttpVersion,
        \\GET / HTTP/7.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-version-malformed" {
    expectParseError(error.BadRequest,
        \\GET / HXX/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-url-malformed" {
    expectParseError(error.BadRequest,
        \\GET /what?are? HTTP/1.1
        \\Host: localhost:8000
        \\
        \\
    );
}

test "01-empty-header" {
    expectParseError(error.BadRequest,
        \\GET /api/something/ HTTP/1.0
        \\: localhost:8000
        \\
        \\
    );
}

test "01-invalid-header-name" {
    expectParseError(error.BadRequest,
        \\GET /api/something/ HTTP/1.0
        \\Host?: localhost:8000
        \\
        \\
    );
}

test "01-header-too-long" {
    const opts = Request.ParseOptions{};
    const name = [_]u8{'x'} ** (opts.max_header_size+1024);
    expectParseError(error.RequestHeaderFieldsTooLarge,
        "GET /api/something/ HTTP/1.0\r\n" ++
        name ++ ": foo\r\n" ++
        "\r\n\r\n"
    );
}

test "01-partial-request" {
    expectParseError(error.EndOfBuffer,
        "GET /api/something/ HTTP/1.0\r\n" ++
        "Host: localhost\r"
    );
}

test "01-partial-request-line" {
    expectParseError(error.EndOfBuffer,
        "GET /api/somethithing/long/path/slow"
    );
}

test "02-parse-request-multiple" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;
    const REQUESTS = TEST_GET_1 ++ TEST_GET_2 ++ TEST_POST_1;
    var stream = try IOStream.initTest(allocator, REQUESTS);
    var request = try Request.initTest(allocator, &stream);
    try request.parseTest(&stream);
    testing.expectEqualSlices(u8, request.path,
        "/wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg");
    try request.parseTest(&stream);
    testing.expectEqualSlices(u8, request.path, "/pixel/of_doom.png");
    try request.parseTest(&stream);
    // I have no idea why but this seems to mess up the speed of the next test
    //testing.expectEqualSlices(u8, request.path, "/BurstingPipe/adServer.bs");

}


test "03-bench-parse-request-line" {
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

        // 10000k req/s 750MB/s (100 ns/req)
        try request.parseRequestLine(&stream, 2048);
        n = stream.readCount();
        request.reset();
        fba.reset();
        request.buffer.items.len = stream.in_buffer.len;
        stream.reset();
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

test "04-parse-request-headers" {
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
    try request.parseTest(&stream);
    var h = &request.headers;

    testing.expectEqual(@as(usize, 6), h.headers.items.len);

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

}

test "04-parse-request-cookies" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;

    var stream = try IOStream.initTest(allocator, TEST_GET_1);
    var request = try Request.initTest(allocator, &stream);
    try request.parseTest(&stream);
    const h = &request.headers;

    testing.expectEqual(@as(usize, 9), h.headers.items.len);

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

    const cookies = (try request.readCookies()).?;
    testing.expectEqualStrings("2", try cookies.get("wp_ozh_wsa_visits"));
    testing.expectEqualStrings("xxxxxxxxxx", try cookies.get("wp_ozh_wsa_visit_lasttime"));
    testing.expectEqualStrings("xxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.x", try cookies.get("__utma"));
    testing.expectEqualStrings("xxxxxxxxx.xxxxxxxxxx.x.x.utmccn=(referral)|utmcsr=reader.livedoor.com|utmcct=/reader/|utmcmd=referral", try cookies.get("__utmz"));

}

test "05-bench-parse-request-headers" {
    var buffer: [1024*1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = &fba.allocator;

    var stream = try IOStream.initTest(allocator, TEST_GET_1);
    var request = try Request.initTest(allocator, &stream);

    const requests: usize = 1000000;
    var timer = try std.time.Timer.start();
    var i: usize = 0; // 1M
    while (i < requests) : (i += 1) {
        // HACK: For testing we "fake" filling the buffer...
        // since this test is only concerned with the parser speed
        request.buffer.items.len = TEST_GET_1.len;

        //     1031k req/s 725MB/s (969 ns/req)
        try request.parseTest(&stream);
        request.reset();
        fba.reset();
        stream.reset();
    }

    const n = TEST_GET_1.len;
    const ns = timer.lap();
    const ms = ns / 1000000;
    const bytes = requests * n / time.ms_per_s;
    std.debug.warn("\n    {}k req/s {}MB/s ({} ns/req)\n",
        .{requests/ms, bytes/ms, ns/requests});
}
