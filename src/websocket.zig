// -------------------------------------------------------------------------- //
// Copyright (c) 2020, Jairus Martin.                                         //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const web = @import("zhp.zig");
const log = std.log;

pub const Opcode = enum(u4) {
    Continue = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Res3 = 0x3,
    Res4 = 0x4,
    Res5 = 0x5,
    Res6 = 0x6,
    Res7 = 0x7,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    ResB = 0xB,
    ResC = 0xC,
    ResD = 0xD,
    ResE = 0xE,
    ResF = 0xF,

    pub fn isControl(opcode: Opcode) bool {
        return @enumToInt(opcode) & 0x8 != 0;
    }

};

pub const WebsocketHeader = packed struct {
    len: u7,
    mask: bool,
    opcode: Opcode,
    rsv3: u1 = 0,
    rsv2: u1 = 0,
    compressed: bool = false, // rsv1
    final: bool = true,

    pub fn packLength(length: usize) u7 {
        return switch (length) {
            0...126 => @truncate(u7, length),
            127...0xFFFF => 126,
            else => 127
        };
    }
};

pub const WebsocketDataFrame = struct {
    header: WebsocketHeader,
    mask: [4]u8 = undefined,
    data: []const u8,

    pub fn isValid(dataframe: WebsocketDataFrame) bool {
        // Validate control frame
        if (dataframe.header.opcode.isControl()) {
            if (!dataframe.header.final) {
                return false; // Control frames cannot be fragmented
            }
            if (dataframe.data.len > 125) {
                return false; // Control frame payloads cannot exceed 125 bytes
            }
        }

        // Validate header len field
        const expected = switch (dataframe.data.len) {
            0...126 => dataframe.data.len,
            127...0xFFFF => 126,
            else => 127
        };
        return dataframe.header.len == expected;
    }
};

// Create a buffered writer
// TODO: This will still split packets
pub fn Writer(comptime size: usize, comptime opcode: Opcode) type {
    const WriterType = switch (opcode) {
        .Text => Websocket.TextFrameWriter,
        .Binary => Websocket.BinaryFrameWriter,
        else => @compileError("Unsupported writer opcode"),
    };
    return std.io.BufferedWriter(size, WriterType);
}


pub const Websocket = struct {
    pub const WriteError = error{
        InvalidMessage,
        MessageTooLarge,
        EndOfStream,
    } || std.fs.File.WriteError;

    request: *web.Request,
    response: *web.Response,
    io: *web.IOStream,
    err: ?anyerror = null,

    // ------------------------------------------------------------------------
    // Stream API
    // ------------------------------------------------------------------------
    pub const TextFrameWriter = std.io.Writer(*Websocket, WriteError, Websocket.writeText);
    pub const BinaryFrameWriter = std.io.Writer(*Websocket, WriteError, Websocket.writeBinary);

    // A buffered writer that will buffer up to size bytes before writing out
    pub fn writer(self: *Websocket, comptime size: usize, comptime opcode: Opcode) Writer(size, opcode) {
        const BufferedWriter = Writer(size, opcode);
        const frame_writer = switch(opcode) {
            .Text => TextFrameWriter{.context=self},
            .Binary => BinaryFrameWriter{.context=self},
            else => @compileError("Unsupported writer type"),
        };
        return BufferedWriter{.unbuffered_writer=frame_writer};
    }

    // Close and send the status
    pub fn close(self: Websocket, code: u16) !void {
        const c = if (std.builtin.endian == .Big) code else @byteSwap(u16, code);
        const data = @bitCast([2]u8, c);
        _ = try self.writeMessage(.Close, &data);
    }

    // ------------------------------------------------------------------------
    // Low level API
    // ------------------------------------------------------------------------

    // Flush any buffered data out the underlying stream
    pub fn flush(self: *Websocket) !void {
        try self.io.flush();
    }

    pub fn writeText(self: *Websocket, data: []const u8) !usize {
        return self.writeMessage(.Text, data);
    }

    pub fn writeBinary(self: *Websocket, data: []const u8) !usize {
        return self.writeMessage(.Binary, data);
    }

    // Write a final message packet with the given opcode
    pub fn writeMessage(self: Websocket, opcode: Opcode, message: []const u8) !usize {
        return self.writeSplitMessage(opcode, true, message);
    }

    // Write a message packet with the given opcode and final flag
    pub fn writeSplitMessage(self: Websocket, opcode: Opcode, final: bool, message: []const u8) !usize {
        return self.writeDataFrame(WebsocketDataFrame{
            .header = WebsocketHeader{
                .final = final,
                .opcode = opcode,
                .mask = false, // Server to client is not masked
                .len = WebsocketHeader.packLength(message.len),
            },
            .data = message,
        });
    }

    // Write a raw data frame
    pub fn writeDataFrame(self: Websocket, dataframe: WebsocketDataFrame) !usize {
        const stream = self.io.writer();

        if (!dataframe.isValid()) return error.InvalidMessage;

        try stream.writeIntBig(u16, @bitCast(u16, dataframe.header));

        // Write extended length if needed
        const n = dataframe.data.len;
        switch (n) {
            0...126 => {}, // Included in header
            127...0xFFFF => try stream.writeIntBig(u16, @truncate(u16, n)),
            else => try stream.writeIntBig(u64, n),
        }

        // TODO: Handle compression
        if (dataframe.header.compressed) return error.InvalidMessage;

        if (dataframe.header.mask) {
            const mask = &dataframe.mask;
            try stream.writeAll(mask);

            // Encode
            for (dataframe.data) |c, i| {
                try stream.writeByte(c ^ mask[i % 4]);
            }
        } else {
            try stream.writeAll(dataframe.data);
        }

        try self.io.flush();

        return dataframe.data.len;
    }

    pub fn readDataFrame(self: Websocket) !WebsocketDataFrame {
        // Read and retry if we hit the end of the stream buffer
        var start = self.io.readCount();
        while (true) {
            return self.readDataFrameInBuffer() catch |err| switch (err) {
                error.EndOfBuffer => {
                    // TODO: This can make the request buffer invalid
                    const n = try self.io.shiftAndFillBuffer(start);
                    if (n == 0) return error.EndOfStream;
                    start = 0;
                    continue;
                },
                else => return err,
            };
        }
    }

    // Read assuming everything can fit before the stream hits the end of
    // it's buffer
    pub fn readDataFrameInBuffer(self: Websocket) !WebsocketDataFrame {
        const stream = self.io;

        const header = try stream.readType(WebsocketHeader, .Big);

        if (header.rsv2 != 0 or header.rsv3 != 0) {
            log.debug("Websocket reserved bits set! {}", .{header});
            return error.InvalidMessage; // Reserved bits are not yet used
        }

        if (!header.mask) {
            log.debug("Websocket client mask header not set! {}", .{header});
            return error.InvalidMessage; // Expected a client message!
        }

        if (header.opcode.isControl() and (header.len >= 126 or !header.final)) {
            log.debug("Websocket control message is invalid! {}", .{header});
            return error.InvalidMessage; // Abort, frame is invalid
        }

        // Decode length
        const length: u64 = switch (header.len) {
            0...125 => header.len,
            126 => try stream.readType(u16, .Big),
            127 => blk: {
                const l = try stream.readType(u64, .Big);
                // Most significant bit must be 0
                if (l >> 63 == 1) {
                    log.debug("Websocket is out of range!", .{});
                    return error.InvalidMessage;
                }
                break :blk l;
            },
        };

        // TODO: Make configurable
        if (length > stream.in_buffer.len) {
            try self.close(1009); // Abort
            return error.MessageTooLarge;
        } else if (length + stream.readCount() > stream.in_buffer.len) {
            return error.EndOfBuffer; // Need to retry
        }

        const start: usize = if (header.mask) 4 else 0;
        const end = start + length;

        // Keep reading until it's filled
        while (stream.amountBuffered() < end) {
            try stream.fillBuffer();
        }

        const buf = stream.readBuffered();
        defer stream.skipBytes(end);

        const mask: [4]u8 = if (header.mask) buf[0..4].* else undefined;
        const data = buf[start..end];
        if (header.mask) {
            // Decode data in place
            for (data) |c, i| {
                data[i] = c ^ mask[i % 4];
            }
        }

        return WebsocketDataFrame{
            .header = header,
            .mask = mask,
            .data = data,
        };
    }

};

