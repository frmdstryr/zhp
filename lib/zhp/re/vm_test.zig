const exec = @import("exec.zig").exec;
const debug = @import("std").debug;
const Parser = @import("parse.zig").Parser;
const Regex = @import("regex.zig").Regex;
const InputBytes = @import("input.zig").InputBytes;
const re_debug = @import("debug.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const mem = std.mem;

// vms to test
const VmBacktrack = @import("vm_backtrack.zig").VmBacktrack;
const VmPike = @import("vm_pike.zig").VmPike;

// Debug global allocator is too small for our tests
var buffer: [800000]u8 = undefined;
var fixed_allocator = FixedBufferAllocator.init(buffer[0..]);

fn nullableEql(comptime T: type, a: []const ?T, b: []const ?T) bool {
    if (a.len != b.len) {
        return false;
    }

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != null and b[i] != null) {
            if (a[i].? != b[i].?) {
                return false;
            }
            // ok
        } else if (a[i] == null and b[i] == null) {
            // ok
        } else {
            return false;
        }
    }

    return true;
}

fn check(re_input: []const u8, to_match: []const u8, expected: bool) void {
    var re = Regex.compile(&fixed_allocator.allocator, re_input) catch unreachable;

    // This is just an engine comparison test but we should also test against fixed vectors
    var backtrack = VmBacktrack.init(re.allocator);
    var backtrack_slots = ArrayList(?usize).init(re.allocator);
    var pike = VmPike.init(re.allocator);
    var pike_slots = ArrayList(?usize).init(re.allocator);

    var input1 = InputBytes.init(to_match).input;
    const pike_result = pike.exec(re.compiled, re.compiled.find_start, &input1, &pike_slots) catch unreachable;

    var input2 = InputBytes.init(to_match).input;
    const backtrack_result = backtrack.exec(re.compiled, re.compiled.find_start, &input2, &backtrack_slots) catch unreachable;

    const slots_equal = nullableEql(usize, pike_slots.toSliceConst(), backtrack_slots.toSliceConst());

    // Note: slot entries are invalid on non-match
    if (pike_result != backtrack_result or (expected == true and !slots_equal)) {
        debug.warn(
            \\
            \\ -- Failure! ----------------
            \\
            \\
            \\pikevm:    {}
            \\backtrack: {}
            \\
        , pike_result, backtrack_result);

        debug.warn(
            \\
            \\ -- Slots -------------------
            \\
            \\pikevm
            \\
        );
        for (pike_slots.toSliceConst()) |entry| {
            debug.warn("{} ", entry);
        }
        debug.warn("\n");

        debug.warn(
            \\
            \\
            \\backtrack
            \\
        );
        for (backtrack_slots.toSliceConst()) |entry| {
            debug.warn("{} ", entry);
        }
        debug.warn("\n");

        debug.warn(
            \\
            \\ -- Regex ------------------
            \\
            \\Regex:    '{}'
            \\String:   '{}'
            \\Expected: {}
            \\
        , re_input, to_match, expected);

        // Dump expression tree and bytecode
        var p = Parser.init(debug.global_allocator);
        defer p.deinit();
        const expr = p.parse(re_input) catch unreachable;

        debug.warn(
            \\
            \\ -- Expression Tree ------------
            \\
        );
        re_debug.dumpExpr(expr.*);

        debug.warn(
            \\
            \\ -- Bytecode -------------------
            \\
        );
        re_debug.dumpProgram(re.compiled);

        debug.warn(
            \\
            \\ -------------------------------
            \\
        );

        @panic("assertion failure");
    }
}

test "pikevm == backtrackvm" {
    // Taken from tiny-regex-c
    check("\\d", "5", true);
    check("\\w+", "hej", true);
    check("\\s", "\t \n", true);
    check("\\S", "\t \n", false);
    check("[\\s]", "\t \n", true);
    check("[\\S]", "\t \n", false);
    check("\\D", "5", false);
    check("\\W+", "hej", false);
    check("[0-9]+", "12345", true);
    check("\\D", "hej", true);
    check("\\d", "hej", false);
    check("[^\\w]", "\\", true);
    check("[\\W]", "\\", true);
    check("[\\w]", "\\", false);
    check("[^\\d]", "d", true);
    check("[\\d]", "d", false);
    check("[^\\D]", "d", false);
    check("[\\D]", "d", true);
    check("^.*\\\\.*$", "c:\\Tools", true);
    check("^[\\+-]*[\\d]+$", "+27", true);
    check("[abc]", "1c2", true);
    check("[abc]", "1C2", false);
    check("[1-5]+", "0123456789", true);
    check("[.2]", "1C2", true);
    check("a*$", "Xaa", true);
    check("a*$", "Xaa", true);
    //check("[a-h]+", "abcdefghxxx", true); // TODO: 0-8 in backtrack vs. 0-7 in backtrack
    check("[a-h]+", "ABCDEFGH", false);
    //check("[A-H]+", "ABCDEFGH", true);
    check("[A-H]+", "abcdefgh", false);
    check("[^\\s]+", "abc def", true);
    check("[^fc]+", "abc def", true);
    check("[^d\\sf]+", "abc def", true);
    check("\n", "abc\ndef", true);
    //check("b.\\s*\n", "aa\r\nbb\r\ncc\r\n\r\n", true);
    check(".*c", "abcabc", true);
    check(".+c", "abcabc", true);
    check("[b-z].*", "ab", true);
    check("b[k-z]*", "ab", true);
    check("[0-9]", "  - ", false);
    check("[^0-9]", "  - ", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello world !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "hello world !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello World !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello world!   ", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "Hello world  !", true);
    check("[Hh]ello [Ww]orld\\s*[!]?", "hello World    !", true);
    check("[^\\w][^-1-4]", ")T", true);
    check("[^\\w][^-1-4]", ")^", true);
    check("[^\\w][^-1-4]", "*)", true);
    check("[^\\w][^-1-4]", "!.", true);
    check("[^\\w][^-1-4]", " x", true);
    check("[^\\w][^-1-4]", "$b", true);
}
