const Regex = @import("regex.zig").Regex;
const debug = @import("std").debug;
const Parser = @import("parse.zig").Parser;
const re_debug = @import("debug.zig");

const FixedBufferAllocator = @import("std").heap.FixedBufferAllocator;
const mem = @import("std").mem;

// Debug global allocator is too small for our tests
var buffer: [800000]u8 = undefined;
var fixed_allocator = FixedBufferAllocator.init(buffer[0..]);

fn check(re_input: []const u8, to_match: []const u8, expected: bool) void {
    var re = Regex.compile(&fixed_allocator.allocator, re_input) catch unreachable;

    if ((re.partialMatch(to_match) catch unreachable) != expected) {
        debug.warn(
            \\
            \\ -- Failure! ------------------
            \\
            \\Regex:    '{}'
            \\String:   '{}'
            \\Expected: {}
            \\
        ,
            re_input,
            to_match,
            expected,
        );

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

test "regex sanity tests" {
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
    check("[a-h]+", "abcdefghxxx", true);
    check("[a-h]+", "ABCDEFGH", false);
    check("[A-H]+", "ABCDEFGH", true);
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

test "regex captures" {
    var r = Regex.compile(debug.global_allocator, "ab(\\d+)") catch unreachable;

    debug.assert(try r.partialMatch("xxxxab0123a"));

    const caps = if (try r.captures("xxxxab0123a")) |caps| caps else unreachable;

    debug.assert(mem.eql(u8, "ab0123", caps.sliceAt(0).?));
    debug.assert(mem.eql(u8, "0123", caps.sliceAt(1).?));
}
