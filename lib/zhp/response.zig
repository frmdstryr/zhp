const std = @import("std");
const Allocator = std.mem.Allocator;

const responses = @import("status.zig");
const HttpStatus = @import("status.zig").HttpStatus;
const HttpHeaders = @import("headers.zig").HttpHeaders;
const HttpRequest = @import("request.zig").HttpRequest;


pub const Bytes = std.ArrayList(u8);


pub const HttpResponse = struct {
    request: *HttpRequest,
    headers: HttpHeaders,
    status: HttpStatus = responses.OK,
    disconnect_on_finish: bool = false,
    chunking_output: bool = false,
    body: Bytes,
    stream: std.io.BufferOutStream.Stream = std.io.BufferOutStream.Stream{
        .writeFn = HttpResponse.writeFn
    },
    _write_finished: bool = false,
    _finished: bool = false,

    pub fn initCapacity(allocator: *Allocator, request: *HttpRequest,
        buffer_size: usize, max_headers: usize) !HttpResponse {
        return HttpResponse{
            .request = request,
            .headers = try HttpHeaders.initCapacity(allocator, max_headers),
            .body = try Bytes.initCapacity(allocator, buffer_size),
        };
    }

    pub fn reset(self: *HttpResponse) void {
        self.body.len = 0;
        self.headers.reset();
        self.status = responses.OK;
        self.disconnect_on_finish = false;
        self.chunking_output = false;
        self._write_finished = false;
        self._finished = false;
    }

    // Wri
    pub fn writeFn(out_stream: *std.io.BufferOutStream.Stream, bytes: []const u8) !void {
        const self = @fieldParentPtr(HttpResponse, "stream", out_stream);
        return self.body.appendSlice(bytes);
    }


    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
        self.request.deinit();
        self.body.deinit();
    }

};




//
// test "parse-response-line" {
//     const a = std.heap.direct_allocator;
//     var line = try HttpResponse.StartLine.parse(a, "HTTP/1.1 200 OK");
//     testing.expect(mem.eql(u8, line.version, "HTTP/1.1"));
//     testing.expect(line.code == 200);
//     testing.expect(mem.eql(u8, line.reason, "OK"));
//
//     testing.expectError(error.MalformedHttpResponse,
//         HttpResponse.StartLine.parse(a, "HTTP/1.1 ABC OK"));
// }
