// External high-level Regex api.
//
// This hides details such as what matching engine is used internally and the parsing/compilation
// stages are merged into a single wrapper function.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const parse = @import("parse.zig");
const compile = @import("compile.zig");
const exec = @import("exec.zig");

const Parser = parse.Parser;
const Expr = parse.Expr;
const Compiler = compile.Compiler;
const Program = compile.Program;
const Instruction = compile.Instruction;

const InputBytes = @import("input.zig").InputBytes;

pub const Regex = struct {
    // Internal allocator
    allocator: *Allocator,
    // A compiled set of instructions
    compiled: Program,
    // Capture slots
    slots: ArrayList(?usize),
    // Original regex string
    string: []const u8,

    // Compile a regex, possibly returning any error which occurred.
    pub fn compile(a: *Allocator, re: []const u8) !Regex {
        var p = Parser.init(a);
        defer p.deinit();

        const expr = try p.parse(re);

        var c = Compiler.init(a);
        defer c.deinit();

        return Regex{
            .allocator = a,
            .compiled = try c.compile(expr),
            .slots = ArrayList(?usize).init(a),
            .string = re,
        };
    }

    pub fn deinit(re: *Regex) void {
        re.compiled.deinit();
    }

    // Does the regex match at the start of the string?
    pub fn match(re: *Regex, input_str: []const u8) !bool {
        var input_bytes = InputBytes.init(input_str);
        return exec.exec(re.allocator, re.compiled, re.compiled.start, &input_bytes.input, &re.slots);
    }

    // Does the regex match anywhere in the string?
    pub fn partialMatch(re: *Regex, input_str: []const u8) !bool {
        var input_bytes = InputBytes.init(input_str);
        return exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input_bytes.input, &re.slots);
    }

    // Where in the string does the regex and its capture groups match?
    //
    // Zero capture is the entire match.
    pub fn captures(re: *Regex, input_str: []const u8) !?Captures {
        var input_bytes = InputBytes.init(input_str);
        const is_match = try exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input_bytes.input, &re.slots);

        if (is_match) {
            return Captures.init(input_str, &re.slots);
        } else {
            return null;
        }
    }
};

// A pair of bounds used to index into an associated slice.
pub const Span = struct {
    lower: usize,
    upper: usize,
};

// A set of captures of a Regex on an input slice.
pub const Captures = struct {
    const Self = @This();

    input: []const u8,
    allocator: *Allocator,
    slots: []const ?usize,

    pub fn init(input: []const u8, slots: *ArrayList(?usize)) Captures {
        return Captures{
            .input = input,
            .allocator = slots.allocator,
            .slots = slots.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.slots);
    }

    pub fn len(self: *const Self) usize {
        return self.slots.len / 2;
    }

    // Return the slice of the matching string for the specified capture index.
    // If the index did not participate in the capture group null is returned.
    pub fn sliceAt(self: *const Self, n: usize) ?[]const u8 {
        if (self.boundsAt(n)) |span| {
            return self.input[span.lower..span.upper];
        }

        return null;
    }

    // Return the substring slices of the input directly.
    pub fn boundsAt(self: *const Self, n: usize) ?Span {
        const base = 2 * n;

        if (base < self.slots.len) {
            if (self.slots[base]) |lower| {
                const upper = self.slots[base + 1].?;
                return Span{
                    .lower = lower,
                    .upper = upper,
                };
            }
        }

        return null;
    }
};
