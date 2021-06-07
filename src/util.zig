// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Stream = std.net.Stream;
const assert = std.debug.assert;

pub const Bytes = std.ArrayList(u8);
pub const native_endian = std.builtin.target.cpu.arch.endian();


pub fn isCtrlChar(ch: u8) callconv(.Inline) bool {
    return (ch < @as(u8, 40) and ch != '\t') or ch == @as(u8, 177);
}


test "is-control-char" {
    try testing.expect(isCtrlChar('A') == false);
    try testing.expect(isCtrlChar('\t') == false);
    try testing.expect(isCtrlChar('\r') == true);
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

pub fn isTokenChar(ch: u8) callconv(.Inline) bool {
    return token_map[ch] == 1;
}

pub const IOStream = struct {
    pub const invalid_stream = Stream{.handle=0};
    pub const Error = Stream.WriteError;
    pub const ReadError = Stream.ReadError;
    const Self = @This();

    allocator: ?*Allocator = null,
    in_buffer: []u8 = undefined,
    out_buffer: []u8 = undefined,
    _in_start_index: usize = 0,
    _in_end_index: usize = 0,
    _in_count: usize = 0,
    _out_count: usize = 0,
    _out_index: usize = 0,
    closed: bool = false,
    owns_in_buffer: bool = true,
    unbuffered: bool = false,
    in_stream: Stream,
    out_stream: Stream,

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------
    pub fn init(stream: Stream) IOStream {
        return IOStream{
            .in_stream = stream,
            .out_stream = stream,
            .in_buffer = &[_]u8{},
            .out_buffer = &[_]u8{},
        };
    }

    pub fn initCapacity(allocator: *Allocator, stream: ?Stream,
                        in_capacity: usize, out_capacity: usize) !IOStream {
        return IOStream{
            .allocator = allocator,
            .in_stream = if (stream) |s| s else invalid_stream,
            .out_stream = if (stream) |s| s else invalid_stream,
            .in_buffer = try allocator.alloc(u8, in_capacity),
            .out_buffer = try allocator.alloc(u8, out_capacity),
            .owns_in_buffer = in_capacity == 0,
            ._in_start_index = in_capacity,
            ._in_end_index = in_capacity,
        };
    }

    // Used to read only from a fixed buffer
    // the buffer must exist for the lifetime of the stream (or until swapped)
    pub fn fromBuffer(in_buffer: []u8) IOStream {
        return IOStream{
            .in_stream = invalid_stream,
            .out_stream = invalid_stream,
            .in_buffer = in_buffer,
            .owns_in_buffer = false,
            ._in_start_index = 0,
            ._in_end_index = in_buffer.len,
        };
    }

    // ------------------------------------------------------------------------
    // Testing utilities
    // ------------------------------------------------------------------------
    pub fn initTest(allocator: *Allocator, in_buffer: []const u8) !IOStream {
        return IOStream{
            .allocator = allocator,
            .in_stream = invalid_stream,
            .out_stream = invalid_stream,
            .in_buffer = try mem.dupe(allocator, u8, in_buffer),
            .owns_in_buffer = in_buffer.len > 0,
            ._in_start_index = 0,
            ._in_end_index = in_buffer.len,
        };
    }

    // Load into the in buffer for testing purposes
    pub fn load(self: *Self, allocator: *Allocator, in_buffer: []const u8) !void {
        self.in_buffer = try mem.dupe(allocator, u8, in_buffer);
        self._in_start_index = 0;
        self._in_end_index = in_buffer.len;
    }

    // ------------------------------------------------------------------------
    // Custom Stream API
    // ------------------------------------------------------------------------
    pub fn reset(self: *Self) void {
        self._in_start_index = 0;
        self._in_count = 0;
        self._out_count = 0;
        self.closed = false;
        self.unbuffered = false;
    }

    // Reset the the initial state without reallocating
    pub fn reinit(self: *Self, stream: Stream) void {
        self.close(); // Close old files
        self.in_stream = stream;
        self.out_stream = stream;
        self._in_start_index = self.in_buffer.len;
        self._in_end_index = self.in_buffer.len;
        self._in_count = 0;
        self._out_index = 0;
        self._out_count = 0;
        self.closed = false;
        self.unbuffered = false;
    }

    // Swap the current buffer with a new buffer copying any unread bytes
    // into the new buffer
    pub fn swapBuffer(self: *Self, buffer: []u8) void {
        //const left = self.amountBuffered();
        // Reset counter
        self._in_count = 0;

        // No swap needed
        if (buffer.ptr == self.in_buffer.ptr) return;

        // So we know not to free the in buf at deinit
        self.owns_in_buffer = false;
        self.unbuffered = false;

        // Copy what is left
        const remaining = self.readBuffered();
        if (remaining.len > 0) {
            std.mem.copy(u8, buffer, remaining);
            self.in_buffer = buffer; // Set it right away
            self._in_start_index = 0;
            self._in_end_index = remaining.len;
        } else {
            self.in_buffer = buffer; // Set it right away
            self._in_start_index = buffer.len;
            self._in_end_index = buffer.len;
        }
    }

    // Switch between buffered and unbuffered reads
    pub fn readUnbuffered(self: *Self, unbuffered: bool) void {
        self.unbuffered = unbuffered;
    }

    // TODO: Inline is broken
    pub fn shiftAndFillBuffer(self: *Self, start: usize) !usize {
        self.unbuffered = true;
        defer self.unbuffered = false;

        // Move buffer to beginning
        const end = self.readCount();
        const remaining = self.in_buffer[start..end];
        std.mem.copyBackwards(u8, self.in_buffer, remaining);

        // Try to read more
        if (remaining.len >= self.in_buffer.len) {
            return error.EndOfBuffer;
        }
        const n = try self.reader().read(self.in_buffer[remaining.len..]);
        self._in_start_index = 0;
        self._in_end_index = remaining.len + n;
        return n;
    }

    // ------------------------------------------------------------------------
    // Reader
    // ------------------------------------------------------------------------
    pub const Reader = std.io.Reader(*IOStream, Stream.ReadError, IOStream.readFn);

    pub fn reader(self: *Self) Reader {
        return Reader{.context=self};
    }

    // Return the amount of bytes waiting in the input buffer
    pub fn amountBuffered(self: *Self) callconv(.Inline) usize {
        return self._in_end_index-self._in_start_index;
    }

    pub fn isEmpty(self: *Self) callconv(.Inline) bool {
        return self._in_end_index == self._in_start_index;
    }

    pub fn readCount(self: *Self) callconv(.Inline) usize {
        //return self._in_count + self._in_start_index;
        return self._in_start_index;
    }

    pub fn consumeBuffered(self: *Self, size: usize) callconv(.Inline) usize {
        const n = math.min(size, self.amountBuffered());
        self._in_start_index += n;
        return n;
    }

    pub fn skipBytes(self: *Self, n: usize) callconv(.Inline) void {
        self._in_start_index += n;
    }

    pub fn readBuffered(self: *Self) callconv(.Inline) []u8 {
        return self.in_buffer[self._in_start_index..self._in_end_index];
    }

    // Read any generic type from a stream as long as it is
    // a multiple of 8 bytes. This does a an endianness conversion if needed
    pub fn readType(self: *Self, comptime T: type, comptime endian: std.builtin.Endian) !T {
        const n = @sizeOf(T);
        const I = switch (n) {
            1 => u8,
            2 => u16,
            4 => u32,
            8 => u64,
            16 => u128,
            else => @compileError("Not implemented"),
        };
        while (self.amountBuffered() < n) {
            try self.fillBuffer();
        }
        const d = @bitCast(I, self.readBuffered()[0..n].*);
        const r = if (endian != native_endian) @byteSwap(I, d) else d;
        self.skipBytes(n);
        return @bitCast(T, r);
    }

    pub fn readFn(self: *Self, dest: []u8) !usize {
        //const self = @fieldParentPtr(BufferedReader, "stream", in_stream);
        if (self.unbuffered) return try self.in_stream.read(dest);

        // Hot path for one byte reads
        if (dest.len == 1 and self._in_end_index > self._in_start_index) {
            dest[0] = self.in_buffer[self._in_start_index];
            self._in_start_index += 1;
            return 1;
        }

        var dest_index: usize = 0;
        while (true) {
            const dest_space = dest.len - dest_index;
            if (dest_space == 0) {
                return dest_index;
            }
            const amt_buffered = self.amountBuffered();
            if (amt_buffered == 0) {
                assert(self._in_end_index <= self.in_buffer.len);
                // Make sure the last read actually gave us some data
                if (self._in_end_index == 0) {
                    // reading from the unbuffered stream returned nothing
                    // so we have nothing left to read.
                    return dest_index;
                }
                // we can read more data from the unbuffered stream
                if (dest_space < self.in_buffer.len) {
                    self._in_start_index = 0;
                    self._in_end_index = try self.in_stream.read(self.in_buffer[0..]);
                    //self._in_count += self._in_end_index;

                    // Shortcut
                    if (self._in_end_index >= dest_space) {
                        mem.copy(u8, dest[dest_index..], self.in_buffer[0..dest_space]);
                        self._in_start_index = dest_space;
                        return dest.len;
                    }
                } else {
                    // asking for so much data that buffering is actually less efficient.
                    // forward the request directly to the unbuffered stream
                    const amt_read = try self.in_stream.read(dest[dest_index..]);
                    //self._in_count += amt_read;
                    return dest_index + amt_read;
                }
            }

            const copy_amount = math.min(dest_space, amt_buffered);
            const copy_end_index = self._in_start_index + copy_amount;
            mem.copy(u8, dest[dest_index..], self.in_buffer[self._in_start_index..copy_end_index]);
            self._in_start_index = copy_end_index;
            dest_index += copy_amount;
        }
    }


    // TODO: Inline is broken
    pub fn fillBuffer(self: *Self) !void {
        const n = try self.readFn(self.in_buffer);
        if (n == 0) return error.EndOfStream;
        self._in_start_index = 0;
        self._in_end_index = n;
    }

    /// Reads 1 byte from the stream or returns `error.EndOfStream`.
    pub fn readByte(self: *Self) !u8 {
        if (self._in_end_index == self._in_start_index) {
            // Do a direct read into the input buffer
            self._in_end_index = try self.readFn(
                self.in_buffer[0..self.in_buffer.len]);
            self._in_start_index = 0;
            if (self._in_end_index < 1) return error.EndOfStream;
        }
        const c = self.in_buffer[self._in_start_index];
        self._in_start_index += 1;
        //self._in_count += 1;
        return c;
    }

    pub fn readByteSafe(self: *Self) callconv(.Inline) !u8 {
        if (self._in_end_index == self._in_start_index) {
            return error.EndOfBuffer;
        }
        return self.readByteUnsafe();
    }

    pub fn readByteUnsafe(self: *Self) callconv(.Inline) u8 {
        const c = self.in_buffer[self._in_start_index];
        self._in_start_index += 1;
        return c;
    }

    pub fn lastByte(self: *Self) callconv(.Inline) u8 {
        return self.in_buffer[self._in_start_index];
    }

    // Read up to limit bytes from the stream buffer until the expression
    // returns true or the limit is hit. The initial value is checked first.
    pub fn readUntilExpr(
            self: *Self,
            comptime expr: fn(ch: u8) bool,
            initial: u8,
            limit: usize) u8 {
        var found = false;
        var ch: u8 = initial;
        while (!found and self.readCount() + 8 < limit) {
            inline for ("01234567") |_| {
                if (expr(ch)) {
                    found = true;
                    break;
                }
                ch = self.readByteUnsafe();
            }
        }
        if (!found) {
            while (self.readCount() < limit) {
                if (expr(ch)) {
                    break;
                }
                ch = self.readByteUnsafe();
            }
        }
        return ch;
    }

    // Read up to limit bytes from the stream buffer until the expression
    // returns true or the limit is hit. The initial value is checked first.
    // If the expression returns an error abort.
    pub fn readUntilExprValidate(
            self: *Self,
            comptime ErrorType: type,
            comptime expr: fn(ch: u8) ErrorType!bool,
            initial: u8,
            limit: usize) !u8 {
        var found = false;
        var ch: u8 = initial;
        while (!found and self.readCount() + 8 < limit) {
            inline for ("01234567") |_| {
                if (try expr(ch)) {
                    found = true;
                    break;
                }
                ch = self.readByteUnsafe();
            }
        }
        if (!found) {
            while (self.readCount() < limit) {
                if (try expr(ch)) {
                    break;
                }
                ch = self.readByteUnsafe();
            }
        }
        return ch;
    }

    // ------------------------------------------------------------------------
    // OutStream
    // ------------------------------------------------------------------------
    pub const Writer = std.io.Writer(*IOStream, Stream.WriteError, IOStream.writeFn);

    pub fn writer(self: *Self) Writer {
        return Writer{.context=self};
    }

    fn writeFn(self: *Self, bytes: []const u8) !usize {
        if (bytes.len == 1) {
            self.out_buffer[self._out_index] = bytes[0];
            self._out_index += 1;
            if (self._out_index == self.out_buffer.len) {
                try self.flush();
            }
            return @as(usize, 1);
        } else if (bytes.len >= self.out_buffer.len) {
            try self.flush();
            return self.out_stream.write(bytes);
        }
        var src_index: usize = 0;

        while (src_index < bytes.len) {
            const dest_space_left = self.out_buffer.len - self._out_index;
            const copy_amt = math.min(dest_space_left, bytes.len - src_index);
            mem.copy(u8, self.out_buffer[self._out_index..], bytes[src_index .. src_index + copy_amt]);
            self._out_index += copy_amt;
            assert(self._out_index <= self.out_buffer.len);
            if (self._out_index == self.out_buffer.len) {
                try self.flush();
            }
            src_index += copy_amt;
        }
        return src_index;
    }

    pub fn flush(self: *Self) !void {
        try self.out_stream.writer().writeAll(self.out_buffer[0..self._out_index]);
        self._out_index = 0;
    }

    // Flush 'size' bytes from the start of the buffer out the stream
    pub fn flushBuffered(self: *Self, size: usize) !void {
        self._out_index = std.math.min(size, self.out_buffer.len);
        try self.flush();
    }

    // Read directly into the output buffer then flush it out
    pub fn writeFromReader(self: *Self, in_stream: anytype) !usize {
        var total_wrote: usize = 0;
        if (self._out_index != 0) {
            total_wrote += self._out_index;
            try self.flush();
        }

        while (true) {
            self._out_index = try in_stream.read(self.out_buffer);
            if (self._out_index == 0) break;

            total_wrote += self._out_index;
            try self.flush();
        }
        return total_wrote;
    }

    // ------------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------------
    pub fn close(self: *Self) void {
        if (self.closed) return;
        self.closed = true;
        // TODO: Doesn't need closed?
//         const in_stream = &self.in_stream;
//         const out_stream = &self.out_stream ;
//         if (in_stream.handle != 0) in_stream.close();
//         std.debug.warn("Close in={} out={}\n", .{in_stream, out_stream});
//         if (in_stream.handle != out_stream.handle and out_stream.handle != 0) {
//             out_stream.close();
//         }
    }

    pub fn deinit(self: *Self) void {
        if (!self.closed) self.close();
        if (self.allocator) |allocator| {

            // If the buffer was swapped assume that it is no longer owned
            if (self.owns_in_buffer) {
                allocator.free(self.in_buffer);
            }
            allocator.free(self.out_buffer);
        }
    }

};

// The event based lock doesn't work without evented io
pub const Lock = if (std.io.is_async) std.event.Lock else std.Thread.Mutex;

pub fn ObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ObjectList = std.ArrayList(*T);

        allocator: *Allocator,
        // Stores all created objects
        objects: ObjectList,

        // Stores objects that have been released
        free_objects: ObjectList,

        // Lock to use if using threads
        lock: Lock = Lock{},

        pub fn init(allocator: *Allocator) Self {
            return Self{
                .allocator = allocator,
                .objects = ObjectList.init(allocator),
                .free_objects = ObjectList.init(allocator),
            };
        }

        // Get an object released back into the pool
        pub fn get(self: *Self) ?*T {
            if (self.free_objects.items.len == 0) return null;
            return self.free_objects.swapRemove(0); // Pull the oldest
        }

        // Create an object and allocate space for it in the pool
        pub fn create(self: *Self) !*T {
            const obj = try self.allocator.create(T);
            try self.objects.append(obj);
            try self.free_objects.ensureCapacity(self.objects.items.len);
            return obj;
        }

        // Return a object back to the pool, this assumes it was created
        // using create (which ensures capacity to return this quickly).
        pub fn release(self: *Self, object: *T) void {
            return self.free_objects.appendAssumeCapacity(object);
        }

        pub fn deinit(self: *Self) void {
            while (self.objects.popOrNull()) |obj| {
                self.allocator.destroy(obj);
            }
            self.objects.deinit();
            self.free_objects.deinit();
        }

    };
}


test "object-pool" {
    const Point = struct {
        x: u8,
        y: u8,
    };
    var pool = ObjectPool(Point).init(std.testing.allocator);
    defer pool.deinit();

    // Pool is empty
    try testing.expect(pool.get() == null);

    // Create
    var test_point = Point{.x=10, .y=3};
    const pt = try pool.create();
    pt.* = test_point;

    // Pool is still empty
    try testing.expect(pool.get() == null);

    // Relase
    pool.release(pt);

    // Should get the same thing back
    try testing.expectEqual(pool.get().?.*, test_point);
}


// An unmanaged map of arrays
pub fn StringArrayMap(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Array = std.ArrayList(T);
        pub const Map = std.StringHashMap(*Array);
        allocator: *Allocator,
        storage: Map,

        pub fn init(allocator: *Allocator) Self {
            return Self{
                .allocator = allocator,
                .storage = Map.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            // Deinit each array
            var it = self.storage.iterator();
            while (it.next()) |entry| {
                const array = entry.value;
                array.deinit();
                self.allocator.destroy(array);
            }
            self.storage.deinit();
        }

        pub fn reset(self: *Self) void {
            // Deinit each array
            var it = self.storage.iterator();
            while (it.pop()) |entry| {
                const array = entry.value;
                array.deinit();
                self.allocator.destroy(array);
            }
        }

        pub fn append(self: *Self, name: []const u8, arg: T) !void {
            if (!self.storage.contains(name)) {
                const ptr = try self.allocator.create(Array);
                ptr.* = Array.init(self.allocator);
                _ = try self.storage.put(name, ptr);
            }
            var array = self.getArray(name).?;
            try array.append(arg);
        }

        // Return entire set
        pub fn getArray(self: *Self, name: []const u8) ?*Array {
            if (self.storage.getEntry(name)) |entry| {
                return entry.value_ptr.*;
            }
            return null;
        }

        // Return first field
        pub fn get(self: *Self, name: []const u8) ?T {
            if (self.getArray(name)) |array| {
                return if (array.items.len > 0) array.items[0] else null;
            }
            return null;
        }
    };
}



test "string-array-map" {
    const Map = StringArrayMap([]const u8);
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try map.append("query", "a");
    try map.append("query", "b");
    try map.append("query", "c");
    const query = map.getArray("query").?;
    try testing.expect(query.items.len == 3);
    try testing.expect(mem.eql(u8, query.items[0], "a"));

}
