// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const math = std.math;
const assert = std.debug.assert;
const builtin = @import("builtin");
const Buffer = std.Buffer;


pub const IOStream = struct {
    pub const WriteError = File.WriteError;
    pub const ReadError = File.ReadError;
    allocator: *Allocator,
    in_buffer: []u8 = undefined,
    _in_start_index: usize = 0,
    _in_end_index: usize = 0,
    _in_count: usize = 0,
    _out_count: usize = 0,
    out_buffer: []u8 = undefined,
    _out_index: usize = 0,
    closed: bool = false,
    unbuffered: bool = false,

    const Self = @This();
    in_file: File,
    out_file: File,

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------

    pub fn init(file: File) IOStream {
        return IOStream{
            .in_file = file,
            .out_file = file,
            .in_buffer = &[_]u8{},
            .out_buffer = &[_]u8{},
        };
    }

    pub fn initCapacity(allocator: *Allocator, file: ?File,
                        in_capacity: usize, out_capacity: usize) !IOStream {
        return IOStream{
            .allocator = allocator,
            .in_file = if (file) |f| f else try std.fs.openFileAbsolute("/dev/null", .{.read=true}),
            .out_file = if (file) |f| f else try std.fs.openFileAbsolute("/dev/null", .{.write=true}),
            .in_buffer = try allocator.alloc(u8, in_capacity),
            .out_buffer = try allocator.alloc(u8, out_capacity),
            ._in_start_index = in_capacity,
            ._in_end_index = in_capacity,
        };
    }

    // ------------------------------------------------------------------------
    // Testing utilities
    // ------------------------------------------------------------------------
    pub fn initTest(allocator: *Allocator, in_buffer: []const u8) !IOStream {
        return IOStream{
            .allocator = allocator,
            .in_file = try std.fs.openFileAbsolute("/dev/null", .{.read=true}),
            .out_file = try std.fs.openFileAbsolute("/dev/null", .{.write=true}),
            .in_buffer = try mem.dupe(allocator, u8, in_buffer),
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

    // Reset the stream to the "unread" state for testing
    pub fn startTest(self: *Self) void {
        //if (!builtin.is_test) @compileError("This is for testing only");
        self._in_start_index = 0;
        self._in_end_index = self.in_buffer.len;
        self._in_count = 0;
        self.closed = false;
        self.unbuffered = false;
        //if (buffer.len == 0) return error.EndOfStream;
        return;
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
    pub fn reinit(self: *Self, file: File) void {
        self.close(); // Close old files
        self.in_file = file;
        self.out_file = file;
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

        // Don't toss previous bytes
        self.in_buffer = buffer; // Set it right away
        self._in_start_index = buffer.len;
        self._in_end_index = buffer.len;
        self.unbuffered = false;
    }

    // Switch between buffered and unbuffered reads
    pub fn readUnbuffered(self: *Self, unbuffered: bool) void {
        self.unbuffered = unbuffered;
    }

    // ------------------------------------------------------------------------
    // InStream
    // ------------------------------------------------------------------------
    // Return the amount of bytes waiting in the input buffer
    pub inline fn amountBuffered(self: *Self) usize {
        return self._in_end_index-self._in_start_index;
    }

    pub inline fn readCount(self: *Self) usize {
        //return self._in_count + self._in_start_index;
        return self._in_start_index;
    }

    pub inline fn consumeBuffered(self: *Self, size: usize) usize {
        const n = math.min(size, self.amountBuffered());
        self._in_start_index += n;
        return n;
    }

    fn readFn(self: *Self, dest: []u8) !usize {
        //const self = @fieldParentPtr(BufferedReader, "stream", in_stream);
        if (self.unbuffered) return try self.in_file.read(dest);

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
                    self._in_end_index = try self.in_file.read(self.in_buffer[0..]);
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
                    const amt_read = try self.in_file.read(dest[dest_index..]);
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

    pub fn read(self: *Self, buffer: []u8) !usize {
        if (comptime std.io.is_async) {
            var f = async self.readFn(buffer);
            return await f;
        } else {
            return self.readFn(buffer);
        }
    }

    pub fn fillBuffer(self: *Self) !void {
        const n = try self.read(self.in_buffer);
        if (n == 0) return error.EndOfStream;
        self._in_start_index = 0;
        self._in_end_index = n;
    }

    /// Returns the number of bytes read. If the number read is smaller than buf.len, it
    /// means the stream reached the end. Reaching the end of a stream is not an error
    /// condition.
    pub fn readFull(self: *Self, buffer: []u8) !usize {
        var index: usize = 0;
        while (index != buffer.len) {
            const amt = try self.read(buffer[index..]);
            if (amt == 0) return index;
            index += amt;
        }
        return index;
    }

    /// Returns the number of bytes read. If the number read would be smaller than buf.len,
    /// error.EndOfStream is returned instead.
    pub fn readNoEof(self: *Self, buf: []u8) !void {
        const amt_read = try self.readFull(buf);
        if (amt_read < buf.len) return error.EndOfStream;
    }

    /// Replaces `buffer` contents by reading from the stream until it is finished.
    /// If `buffer.len()` would exceed `max_size`, `error.StreamTooLong` is returned and
    /// the contents read from the stream are lost.
    pub fn readAllBuffer(self: *Self, buffer: *Buffer, max_size: usize) !void {
        try buffer.resize(0);

        var actual_buf_len: usize = 0;
        while (true) {
            const dest_slice = buffer.toSlice()[actual_buf_len..];
            const bytes_read = try self.readFull(dest_slice);
            actual_buf_len += bytes_read;

            if (bytes_read != dest_slice.len) {
                buffer.shrink(actual_buf_len);
                return;
            }

            const new_buf_size = math.min(max_size, actual_buf_len + mem.page_size);
            if (new_buf_size == actual_buf_len) return error.StreamTooLong;
            try buffer.resize(new_buf_size);
        }
    }

    /// Allocates enough memory to hold all the contents of the stream. If the allocated
    /// memory would be greater than `max_size`, returns `error.StreamTooLong`.
    /// Caller owns returned memory.
    /// If this function returns an error, the contents from the stream read so far are lost.
    pub fn readAllAlloc(self: *Self, allocator: *mem.Allocator, max_size: usize) ![]u8 {
        var buf = Buffer.initNull(allocator);
        defer buf.deinit();

        try self.readAllBuffer(&buf, max_size);
        return buf.toOwnedSlice();
    }

    /// Replaces `buffer` contents by reading from the stream until `delimiter` is found.
    /// Does not include the delimiter in the result.
    /// If `buffer.len()` would exceed `max_size`, `error.StreamTooLong` is returned and the contents
    /// read from the stream so far are lost.
    pub fn readUntilDelimiterBuffer(self: *Self, buffer: *Buffer, delimiter: u8, max_size: usize) !void {
        try buffer.resize(0);

        while (true) {
            var byte: u8 = try self.readByte();

            if (byte == delimiter) {
                return;
            }

            if (buffer.len() == max_size) {
                return error.StreamTooLong;
            }

            try buffer.appendByte(byte);
        }
    }

    /// Allocates enough memory to read until `delimiter`. If the allocated
    /// memory would be greater than `max_size`, returns `error.StreamTooLong`.
    /// Caller owns returned memory.
    /// If this function returns an error, the contents from the stream read so far are lost.
    pub fn readUntilDelimiterAlloc(self: *Self, allocator: *mem.Allocator, delimiter: u8, max_size: usize) ![]u8 {
        var buf = Buffer.initNull(allocator);
        defer buf.deinit();

        try self.readUntilDelimiterBuffer(&buf, delimiter, max_size);
        return buf.toOwnedSlice();
    }

    /// Reads from the stream until specified byte is found. If the buffer is not
    /// large enough to hold the entire contents, `error.StreamTooLong` is returned.
    /// If end-of-stream is found, returns the rest of the stream. If this
    /// function is called again after that, returns null.
    /// Returns a slice of the stream data, with ptr equal to `buf.ptr`. The
    /// delimiter byte is not included in the returned slice.
    pub fn readUntilDelimiterOrEof(self: *Self, buf: []u8, delimiter: u8) !?[]u8 {
        var index: usize = 0;
        while (true) {
            const byte = self.readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (index == 0) {
                        return null;
                    } else {
                        return buf[0..index];
                    }
                },
                else => |e| return e,
            };

            if (byte == delimiter) return buf[0..index];
            if (index >= buf.len) return error.StreamTooLong;

            buf[index] = byte;
            index += 1;
        }
    }

    /// Reads from the stream until specified byte is found, discarding all data,
    /// including the delimiter.
    /// If end-of-stream is found, this function succeeds.
    pub fn skipUntilDelimiterOrEof(self: *Self, delimiter: u8) !void {
        while (true) {
            const byte = self.readByte() catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            if (byte == delimiter) return;
        }
    }

    /// Reads 1 byte from the stream or returns `error.EndOfStream`.
    pub fn readByte(self: *Self) !u8 {
        if (self._in_end_index == self._in_start_index) {
            // Do a direct read into the input buffer
            self._in_end_index = try self.read(
                self.in_buffer[0..self.in_buffer.len]);
            self._in_start_index = 0;
            if (self._in_end_index < 1) return error.EndOfStream;
        }
        const c = self.in_buffer[self._in_start_index];
        self._in_start_index += 1;
        //self._in_count += 1;
        return c;
    }

    pub inline fn readByteFast(self: *Self) !u8 {
        if (self._in_end_index == self._in_start_index) {
            return error.EndOfBuffer;
        }
        const c = self.in_buffer[self._in_start_index];
        self._in_start_index += 1;
        //self._in_count += 1;
        return c;
    }

    pub inline fn lastByte(self: *Self) u8 {
        return self.in_buffer[self._in_start_index];
    }

    /// Same as `readByte` except the returned byte is signed.
    pub fn readByteSigned(self: *Self) !i8 {
        return @bitCast(i8, try self.readByte());
    }

    /// Reads a native-endian integer
    pub fn readIntNative(self: *Self, comptime T: type) !T {
        var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
        try self.readNoEof(bytes[0..]);
        return mem.readIntNative(T, &bytes);
    }

    /// Reads a foreign-endian integer
    pub fn readIntForeign(self: *Self, comptime T: type) !T {
        var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
        try self.readNoEof(bytes[0..]);
        return mem.readIntForeign(T, &bytes);
    }

    pub fn readIntLittle(self: *Self, comptime T: type) !T {
        var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
        try self.readNoEof(bytes[0..]);
        return mem.readIntLittle(T, &bytes);
    }

    pub fn readIntBig(self: *Self, comptime T: type) !T {
        var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
        try self.readNoEof(bytes[0..]);
        return mem.readIntBig(T, &bytes);
    }

    pub fn readInt(self: *Self, comptime T: type, endian: builtin.Endian) !T {
        var bytes: [(T.bit_count + 7) / 8]u8 = undefined;
        try self.readNoEof(bytes[0..]);
        return mem.readInt(T, &bytes, endian);
    }

    pub fn readVarInt(self: *Self, comptime ReturnType: type, endian: builtin.Endian, size: usize) !ReturnType {
        assert(size <= @sizeOf(ReturnType));
        var bytes_buf: [@sizeOf(ReturnType)]u8 = undefined;
        const bytes = bytes_buf[0..size];
        try self.readNoEof(bytes);
        return mem.readVarInt(ReturnType, bytes, endian);
    }

    pub fn skipBytes(self: *Self, num_bytes: u64) !void {
        var i: u64 = 0;
        while (i < num_bytes) : (i += 1) {
            _ = try self.readByte();
        }
    }

    pub fn readStruct(self: *Self, comptime T: type) !T {
        // Only extern and packed structs have defined in-memory layout.
        comptime assert(@typeInfo(T).Struct.layout != builtin.TypeInfo.ContainerLayout.Auto);
        var res: [1]T = undefined;
        try self.readNoEof(@sliceToBytes(res[0..]));
        return res[0];
    }

    /// Reads an integer with the same size as the given enum's tag type. If the integer matches
    /// an enum tag, casts the integer to the enum tag and returns it. Otherwise, returns an error.
    /// TODO optimization taking advantage of most fields being in order
    pub fn readEnum(self: *Self, comptime Enum: type, endian: builtin.Endian) !Enum {
        const E = error{
            /// An integer was read, but it did not match any of the tags in the supplied enum.
            InvalidValue,
        };
        const type_info = @typeInfo(Enum).Enum;
        const tag = try self.readInt(type_info.tag_type, endian);

        inline for (std.meta.fields(Enum)) |field| {
            if (tag == field.value) {
                return @field(Enum, field.name);
            }
        }

        return E.InvalidValue;
    }

    // ------------------------------------------------------------------------
    // OutStream
    // ------------------------------------------------------------------------
    fn writeFn(self: *Self, bytes: []const u8) !void {
        if (bytes.len == 1) {
            self.out_buffer[self._out_index] = bytes[0];
            self._out_index += 1;
            if (self._out_index == self.out_buffer.len) {
                try self.flushFn();
            }
            return;
        } else if (bytes.len >= self.out_buffer.len) {
            try self.flushFn();
            return self.out_file.write(bytes);
        }
        var src_index: usize = 0;

        while (src_index < bytes.len) {
            const dest_space_left = self.out_buffer.len - self._out_index;
            const copy_amt = math.min(dest_space_left, bytes.len - src_index);
            mem.copy(u8, self.out_buffer[self._out_index..], bytes[src_index .. src_index + copy_amt]);
            self._out_index += copy_amt;
            assert(self._out_index <= self.out_buffer.len);
            if (self._out_index == self.out_buffer.len) {
                try self.flushFn();
            }
            src_index += copy_amt;
        }
    }

    fn flushFn(self: *Self) !void {
        try self.out_file.write(self.out_buffer[0..self._out_index]);
        self._out_index = 0;
    }

    pub fn write(self: *Self, bytes: []const u8) !void {
        if (comptime std.io.is_async) {
            var f = async self.writeFn(bytes);
            return await f;
        } else {
            return self.writeFn(bytes);
        }
    }

    pub fn flush(self: *Self) !void {
        if (comptime std.io.is_async) {
            var f = async self.flushFn();
            return await f;
        } else {
            return self.flushFn();
        }
    }

    // Read directly into the output buffer then flush it out
    pub fn writeFromInStream(self: *Self, in_stream: *std.io.InStream(ReadError)) !usize {
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

    pub fn writeByte(self: *Self, byte: u8) !void {
        const slice = @as(*const [1]u8, &byte)[0..];
        return self.writeFn(self, slice);
    }

    pub fn print(self: *Self, comptime format: []const u8, args: var) !void {
        return std.fmt.format(self, WriteError, Self.writeFn, format, args);
    }

    // ------------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------------
    pub fn close(self: *Self) void {
        if (self.closed) return;
        self.closed = true;
        self.in_file.close();
        if (self.in_file.handle != self.out_file.handle) {
            self.out_file.close();
        }
    }

    pub fn deinit(self: *IOStream) void {
        if (!self.closed) self.close();
        self.allocator.free(self.in_buffer);
        self.allocator.free(self.out_buffer);
    }

};



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
        lock: std.Mutex = std.Mutex.init(),

        pub fn init(allocator: *Allocator) Self {
            return Self{
                .allocator = allocator,
                .objects = ObjectList.init(allocator),
                .free_objects = ObjectList.init(allocator),
            };
        }

        // Get an object released back into the pool
        pub fn get(self: *Self) ?*T {
            if (self.free_objects.len == 0) return null;
            return self.free_objects.swapRemove(0); // Pull the oldest
        }

        // Create an object and allocate space for it in the pool
        pub fn create(self: *Self) !*T {
            const obj = try self.allocator.create(T);
            try self.objects.append(obj);
            try self.free_objects.ensureCapacity(self.objects.len);
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


// A map of arrays
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
                entry.value.deinit();
            }
            self.storage.clear();
        }

        pub fn append(self: *Self, name: []const u8, arg: T) !void {
            if (!self.storage.contains(name)) {
                const ptr = try self.allocator.create(Array);
                ptr.* = Array.init(self.allocator);
                _ = try self.storage.put(name, ptr);
            }
            var array = self.get(name).?;
            try array.append(arg);
        }

        pub fn get(self: *Self, name: []const u8) ?*Array {
            return self.storage.getValue(name);
        }
    };
}


test "string-array-map" {
    const Map = StringArrayMap([]const u8);
    var map = Map.init(std.heap.page_allocator);
    try map.append("query", "a");
    try map.append("query", "b");
    try map.append("query", "c");
    const query = map.get("query").?;
    testing.expect(query.len == 3);
    testing.expect(mem.eql(u8, query.items[0], "a"));

    map.deinit();
}
