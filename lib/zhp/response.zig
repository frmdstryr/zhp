const std = @import("std");
const Allocator = std.mem.Allocator;

const responses = @import("status.zig");
const HttpStatus = @import("status.zig").HttpStatus;
const HttpHeaders = @import("headers.zig").HttpHeaders;
const HttpRequest = @import("request.zig").HttpRequest;


pub const Bytes = std.ArrayList(u8);


pub const HttpResponse = struct {
    // Allocator for this response
    allocator: *Allocator = undefined,
    headers: HttpHeaders,
    status: HttpStatus = responses.OK,
    disconnect_on_finish: bool = false,
    chunking_output: bool = false,

    // Buffer for output body, if the response is too big use source_stream
    body: Bytes,

    // Use this to print directly into the body buffer
    stream: std.io.BufferOutStream.Stream = std.io.BufferOutStream.Stream{
        .writeFn = HttpResponse.writeFn
    },

    // If this is set, the response will read from the stream
    source_stream: ?std.fs.File.InStream = null,

    // Set to true if your request handler already sent everything
    finished: bool = false,

    pub fn initCapacity(allocator: *Allocator, buffer_size: usize, max_headers: usize) !HttpResponse {
        return HttpResponse{
            .headers = try HttpHeaders.initCapacity(allocator, max_headers),
            .body = try Bytes.initCapacity(allocator, buffer_size),
        };
    }

    // Reset the request so it can be reused without reallocating memory
    pub fn reset(self: *HttpResponse) void {
        self.body.len = 0;
        self.headers.reset();
        self.status = responses.OK;
        self.disconnect_on_finish = false;
        self.chunking_output = false;
        self.finished = false;
        if (self.source_stream) |stream| {
            stream.file.close();
            self.source_stream = null;
        }
    }

    // Write into the body buffer
    pub fn writeFn(out_stream: *std.io.BufferOutStream.Stream, bytes: []const u8) !void {
        const self = @fieldParentPtr(HttpResponse, "stream", out_stream);
        return self.body.appendSlice(bytes);
    }

    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
        self.body.deinit();
    }

};
