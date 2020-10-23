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

pub const Bytes = std.ArrayList(u8);


pub inline fn isCtrlChar(ch: u8) bool {
    return (ch < @as(u8, 40) and ch != '\t') or ch == @as(u8, 177);
}


test "is-control-char" {
    testing.expect(isCtrlChar('A') == false);
    testing.expect(isCtrlChar('\t') == false);
    testing.expect(isCtrlChar('\r') == true);
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

pub inline fn isTokenChar(ch: u8) bool {
    return token_map[ch] == 1;
}

pub const IOStream = struct {
    pub const invalid_file = File{.handle=0};
    pub const Error = File.WriteError;
    pub const ReadError = File.ReadError;
    const Self = @This();

    allocator: ?*Allocator = null,
    in_buffer: []const u8 = undefined,
    out_buffer: []u8 = undefined,
    _in_start_index: usize = 0,
    _in_end_index: usize = 0,
    _in_count: usize = 0,
    _out_count: usize = 0,
    _out_index: usize = 0,
    closed: bool = false,
    unbuffered: bool = false,
    in_file: File,
    out_file: File,

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------
    pub fn init(file: File) IOStream {
        return IOStream{
            .in_file = file,
            .out_file = file,
            .in_buffer = &[_]const u8{},
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

    // Used to read only from a fixed buffer
    // the buffer must exist for the lifetime of the stream (or until swapped)
    pub fn fromBuffer(buffer: *Bytes) IOStream {
        return IOStream{
            .in_file = invalid_file,
            .out_file = invalid_file,
            .in_buffer = buffer.items,
            ._in_start_index = 0,
            ._in_end_index = buffer.items.len,
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
            .in_buffer = in_buffer,
            ._in_start_index = 0,
            ._in_end_index = in_buffer.len,
        };
    }

    // Load into the in buffer for testing purposes
    pub fn load(self: *Self, allocator: *Allocator, in_buffer: []const u8) !void {
        self.in_buffer = in_buffer;
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
    pub fn swapBuffer(self: *Self, buffer: []const u8) void {
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
    // Reader
    // ------------------------------------------------------------------------
    pub const Reader = std.io.Reader(*IOStream, File.ReadError, IOStream.readFn);

    pub fn reader(self: *Self) Reader {
        return Reader{.context=self};
    }

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

    // ------------------------------------------------------------------------
    // OutStream
    // ------------------------------------------------------------------------
    pub const Writer = std.io.Writer(*IOStream, File.WriteError, IOStream.writeFn);

    pub fn writer(self: *Self) Writer {
        return Writer{.context=self};
    }

    fn writeFn(self: *Self, bytes: []const u8) !usize {
        if (bytes.len == 1) {
            self.out_buffer[self._out_index] = bytes[0];
            self._out_index += 1;
            if (self._out_index == self.out_buffer.len) {
                try self.flushFn();
            }
            return @as(usize, 1);
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
        return src_index;
    }

    fn flushFn(self: *Self) !void {
        try self.out_file.writeAll(self.out_buffer[0..self._out_index]);
        self._out_index = 0;
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
        self.in_file.close();
        if (self.in_file.handle != self.out_file.handle) {
            self.out_file.close();
        }
    }

    pub fn deinit(self: *Self) void {
        if (!self.closed) self.close();
        if (self.allocator) |allocator| {
            allocator.free(self.in_buffer);
            allocator.free(self.out_buffer);
        }
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
        lock: std.Mutex = std.Mutex{},

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
    testing.expect(pool.get() == null);

    // Create
    var test_point = Point{.x=10, .y=3};
    const pt = try pool.create();
    pt.* = test_point;

    // Pool is still empty
    testing.expect(pool.get() == null);

    // Relase
    pool.release(pt);

    // Should get the same thing back
    testing.expectEqual(pool.get().?.*, test_point);
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
                return entry.value;
            }
            return null;
        }

        // Return first field
        pub fn get(self: *Self, name: []const u8) ?[]const u8 {
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
    testing.expect(query.items.len == 3);
    testing.expect(mem.eql(u8, query.items[0], "a"));

}
