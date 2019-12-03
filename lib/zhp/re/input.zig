// A generic iterator of some input bytes.
//
// This is intended to handle different decoding patterns. The intent is to have a Utf-8 and byte
// input abstraction. Execution engines can be generic over these two types.
//
// Technically we could encode Utf-8 into associated bytes when constructing the program. This is
// typically slower on the match however as for large unicode states many more states need to be
// traversed.

const Assertion = @import("parse.zig").Assertion;

pub const Input = struct {
    bytes: []const u8,
    byte_pos: usize,

    currentFn: fn (input: Input) ?u8,
    advanceFn: fn (input: *Input) void,
    isNextWordCharFn: fn (input: Input) bool,
    isPrevWordCharFn: fn (input: Input) bool,

    pub fn advance(self: *Input) void {
        self.advanceFn(self);
    }

    pub fn current(self: Input) ?u8 {
        return self.currentFn(self);
    }

    // Note: We extend the range here to one past the end of the input. This is done in order to
    // handle complete matches correctly.
    pub fn isConsumed(self: Input) bool {
        return self.byte_pos > self.bytes.len;
    }

    pub fn isEmptyMatch(self: Input, match: Assertion) bool {
        switch (match) {
            Assertion.None => {
                return true;
            },
            Assertion.BeginLine => {
                return self.byte_pos == 0;
            },
            Assertion.EndLine => {
                return self.byte_pos >= self.bytes.len - 1;
            },
            Assertion.BeginText => {
                // TODO: Handle different modes.
                return self.byte_pos == 0;
            },
            Assertion.EndText => {
                return self.byte_pos >= self.bytes.len - 1;
            },
            Assertion.WordBoundaryAscii => {
                return self.isPrevWordCharFn(self) != self.isNextWordCharFn(self);
            },
            Assertion.NotWordBoundaryAscii => {
                return self.isPrevWordCharFn(self) == self.isNextWordCharFn(self);
            },
        }
    }

    // Create a new instance using the same interface functions.
    pub fn clone(self: Input) Input {
        return Input{
            .bytes = self.bytes,
            .byte_pos = self.byte_pos,

            .currentFn = self.currentFn,
            .advanceFn = self.advanceFn,
            .isNextWordCharFn = self.isNextWordCharFn,
            .isPrevWordCharFn = self.isPrevWordCharFn,
        };
    }
};

pub const InputBytes = struct {
    input: Input,

    pub fn init(bytes: []const u8) InputBytes {
        return InputBytes{
            .input = Input{
                .bytes = bytes,
                .byte_pos = 0,

                .currentFn = current,
                .advanceFn = advance,
                .isNextWordCharFn = isNextWordChar,
                .isPrevWordCharFn = isPrevWordChar,
            },
        };
    }

    // TODO: When we can compare ?usize == usize this will be a bit nicer.
    fn current(self: Input) ?u8 {
        if (self.byte_pos < self.bytes.len) {
            return self.bytes[self.byte_pos];
        } else {
            return null;
        }
    }

    fn advance(self: *Input) void {
        if (self.byte_pos <= self.bytes.len) {
            self.byte_pos += 1;
        }
    }

    fn isWordChar(c: u8) bool {
        return switch (c) {
            '0'...'9', 'a'...'z', 'A'...'Z' => true,
            else => false,
        };
    }

    fn isNextWordChar(self: Input) bool {
        return (self.byte_pos == 0) or isWordChar(self.bytes[self.byte_pos - 1]);
    }

    fn isPrevWordChar(self: Input) bool {
        return (self.byte_pos >= self.bytes.len - 1) or isWordChar(self.bytes[self.byte_pos + 1]);
    }
};
