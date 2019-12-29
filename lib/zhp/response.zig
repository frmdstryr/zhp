const std = @import("std");
const Allocator = std.mem.Allocator;

const responses = @import("status.zig");
const Status = @import("status.zig").Status;
const Headers = @import("headers.zig").Headers;
const Request = @import("request.zig").Request;


pub const Bytes = std.ArrayList(u8);


pub const Response = struct {
    // Allocator for this response
    allocator: *Allocator = undefined,
    headers: Headers,
    status: Status = responses.OK,
    disconnect_on_finish: bool = false,
    chunking_output: bool = false,

    // Buffer for output body, if the response is too big use source_stream
    body: Bytes,

    // Use this to print directly into the body buffer
    stream: std.io.BufferOutStream.Stream = std.io.BufferOutStream.Stream{
        .writeFn = Response.writeFn
    },

    // If this is set, the response will read from the stream
    source_stream: ?std.fs.File.InStream = null,

    // Set to true if your request handler already sent everything
    finished: bool = false,

    pub fn initCapacity(allocator: *Allocator, buffer_size: usize, max_headers: usize) !Response {
        return Response{
            .headers = try Headers.initCapacity(allocator, max_headers),
            .body = try Bytes.initCapacity(allocator, buffer_size),
        };
    }

    // Reset the request so it can be reused without reallocating memory
    pub fn reset(self: *Response) void {
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
        const self = @fieldParentPtr(Response, "stream", out_stream);
        return self.body.appendSlice(bytes);
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.body.deinit();
    }

};
