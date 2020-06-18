// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const Allocator = std.mem.Allocator;

const responses = @import("status.zig");
const Status = @import("status.zig").Status;
const Headers = @import("headers.zig").Headers;
const Request = @import("request.zig").Request;

pub const Bytes = std.ArrayList(u8);



pub const Response = struct {
    pub const WriteError = error{OutOfMemory};
    pub const Writer = std.io.Writer(*Response, WriteError, Response.writeFn);

    // Allocator for this response
    allocator: *Allocator = undefined,
    headers: Headers,
    status: Status = responses.OK,
    disconnect_on_finish: bool = false,
    chunking_output: bool = false,

    stream: Writer = undefined,

    // Buffer for output body, if the response is too big use source_stream
    body: Bytes,

    // If this is set, the response will read from the stream
    source_stream: ?std.fs.File.Reader = null,

    // Set to true if your request handler already sent everything
    finished: bool = false,

    pub fn initCapacity(allocator: *Allocator, buffer_size: usize, max_headers: usize) !Response {
        return Response{
            .allocator = allocator,
            .headers = try Headers.initCapacity(allocator, max_headers),
            .body = try Bytes.initCapacity(allocator, buffer_size),
        };
    }

    // Must be called before writing
    pub fn prepare(self: *Response) void {
        self.stream = Writer{.context = self};
    }

    // Reset the request so it can be reused without reallocating memory
    pub fn reset(self: *Response) void {
        self.body.items.len = 0;
        self.headers.reset();
        self.status = responses.OK;
        self.disconnect_on_finish = false;
        self.chunking_output = false;
        self.finished = false;
        if (self.source_stream) |stream| {
            stream.context.close();
            self.source_stream = null;
        }
    }

    // Write into the body buffer
    pub fn writeFn(self: *Response, bytes: []const u8) WriteError!usize {
        try self.body.appendSlice(bytes);
        return bytes.len;
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.body.deinit();
    }

};


test "response" {
    const allocator = std.heap.page_allocator;
    var response = try Response.initCapacity(allocator, 4096, 1096);
    response.prepare();
    defer response.deinit();
    _ = try response.stream.write("Hello world!\n");
    std.testing.expectEqualSlices(u8, "Hello world!\n", response.body.items);

    _ = try response.stream.print("{}\n", .{"Testing!"});
    std.debug.warn("'{}'\n", .{response.body.items});
    std.testing.expectEqualSlices(u8, "Hello world!\nTesting!\n", response.body.items);

    try response.headers.put("Content-Type", "Keep-Alive");
}
