const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const OutStream = std.io.OutStream;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const parse = @import("parse.zig");
const Parser = parse.Parser;
const Expr = parse.Expr;
const ParseError = parse.ParseError;

// Note: Switch to OutStream
var global_buffer: [2048]u8 = undefined;

const StaticOutStream = struct {
    buffer: []u8,
    last: usize,
    stream: Stream,

    pub const Error = error{OutOfMemory};
    pub const Stream = OutStream(Error);

    pub fn init(buffer: []u8) StaticOutStream {
        return StaticOutStream{
            .buffer = buffer,
            .last = 0,
            .stream = Stream{ .writeFn = writeFn },
        };
    }

    fn writeFn(out_stream: *Stream, bytes: []const u8) Error!void {
        const self = @fieldParentPtr(StaticOutStream, "stream", out_stream);
        mem.copy(u8, self.buffer[self.last..], bytes);
        self.last += bytes.len;
    }

    pub fn printCharEscaped(self: *StaticOutStream, ch: u8) !void {
        switch (ch) {
            '\t' => {
                try self.stream.print("\\t");
            },
            '\r' => {
                try self.stream.print("\\r");
            },
            '\n' => {
                try self.stream.print("\\n");
            },
            // printable characters
            32...126 => {
                try self.stream.print("{c}", ch);
            },
            else => {
                try self.stream.print("0x{x}", ch);
            },
        }
    }
};

// Return a minimal string representation of the expression tree.
fn repr(e: *Expr) ![]u8 {
    var stream = StaticOutStream.init(global_buffer[0..]);
    try reprIndent(&stream, e, 0);
    return global_buffer[0..stream.last];
}

fn reprIndent(out: *StaticOutStream, e: *Expr, indent: usize) anyerror!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.stream.print(" ");
    }

    switch (e.*) {
        Expr.AnyCharNotNL => {
            try out.stream.print("dot\n");
        },
        Expr.EmptyMatch => |assertion| {
            try out.stream.print("empty({})\n", @tagName(assertion));
        },
        Expr.Literal => |lit| {
            try out.stream.print("lit(");
            try out.printCharEscaped(lit);
            try out.stream.print(")\n");
        },
        Expr.Capture => |subexpr| {
            try out.stream.print("cap\n");
            try reprIndent(out, subexpr, indent + 1);
        },
        Expr.Repeat => |repeat| {
            try out.stream.print("rep(");
            if (repeat.min == 0 and repeat.max == null) {
                try out.stream.print("*");
            } else if (repeat.min == 1 and repeat.max == null) {
                try out.stream.print("+");
            } else if (repeat.min == 0 and repeat.max != null and repeat.max.? == 1) {
                try out.stream.print("?");
            } else {
                try out.stream.print("{{{},", repeat.min);
                if (repeat.max) |ok| {
                    try out.stream.print("{}", ok);
                }
                try out.stream.print("}}");
            }

            if (!repeat.greedy) {
                try out.stream.print("?");
            }
            try out.stream.print(")\n");

            try reprIndent(out, repeat.subexpr, indent + 1);
        },
        Expr.ByteClass => |class| {
            try out.stream.print("bset(");
            for (class.ranges.toSliceConst()) |r| {
                try out.stream.print("[");
                try out.printCharEscaped(r.min);
                try out.stream.print("-");
                try out.printCharEscaped(r.max);
                try out.stream.print("]");
            }
            try out.stream.print(")\n");
        },
        // TODO: Can we get better type unification on enum variants with the same type?
        Expr.Concat => |subexprs| {
            try out.stream.print("cat\n");
            for (subexprs.toSliceConst()) |s|
                try reprIndent(out, s, indent + 1);
        },
        Expr.Alternate => |subexprs| {
            try out.stream.print("alt\n");
            for (subexprs.toSliceConst()) |s|
                try reprIndent(out, s, indent + 1);
        },
        // NOTE: Shouldn't occur ever in returned output.
        Expr.PseudoLeftParen => {
            try out.stream.print("{}\n", @tagName(e.*));
        },
    }
}

// Debug global allocator is too small for our tests
var fbuffer: [800000]u8 = undefined;
var fixed_allocator = FixedBufferAllocator.init(fbuffer[0..]);

fn check(re: []const u8, expected_ast: []const u8) void {
    var p = Parser.init(&fixed_allocator.allocator);
    const expr = p.parse(re) catch unreachable;

    var ast = repr(expr) catch unreachable;

    const spaces = [_]u8{ ' ', '\n' };
    const trimmed_ast = mem.trim(u8, ast, spaces);
    const trimmed_expected_ast = mem.trim(u8, expected_ast, spaces);

    if (!mem.eql(u8, trimmed_ast, trimmed_expected_ast)) {
        debug.warn(
            \\
            \\-- parsed the regex
            \\
            \\{}
            \\
            \\-- expected the following
            \\
            \\{}
            \\
            \\-- but instead got
            \\
            \\{}
            \\
        ,
            re,
            trimmed_expected_ast,
            trimmed_ast,
        );

        @panic("assertion failure");
    }
}

// These are taken off rust-regex for the moment.
test "parse simple" {
    check(
        \\
    ,
        \\empty(None)
    );

    check(
        \\a
    ,
        \\lit(a)
    );

    check(
        \\ab
    ,
        \\cat
        \\ lit(a)
        \\ lit(b)
    );

    check(
        \\^a
    ,
        \\cat
        \\ empty(BeginLine)
        \\ lit(a)
    );

    check(
        \\a?
    ,
        \\rep(?)
        \\ lit(a)
    );

    check(
        \\ab?
    ,
        \\cat
        \\ lit(a)
        \\ rep(?)
        \\  lit(b)
    );

    check(
        \\a??
    ,
        \\rep(??)
        \\ lit(a)
    );

    check(
        \\a+
    ,
        \\rep(+)
        \\ lit(a)
    );

    check(
        \\a+?
    ,
        \\rep(+?)
        \\ lit(a)
    );

    check(
        \\a*?
    ,
        \\rep(*?)
        \\ lit(a)
    );

    check(
        \\a{5}
    ,
        \\rep({5,5})
        \\ lit(a)
    );

    check(
        \\a{5,}
    ,
        \\rep({5,})
        \\ lit(a)
    );

    check(
        \\a{5,10}
    ,
        \\rep({5,10})
        \\ lit(a)
    );

    check(
        \\a{5}?
    ,
        \\rep({5,5}?)
        \\ lit(a)
    );

    check(
        \\a{5,}?
    ,
        \\rep({5,}?)
        \\ lit(a)
    );

    check(
        \\a{ 5     }
    ,
        \\rep({5,5})
        \\ lit(a)
    );

    check(
        \\(a)
    ,
        \\cap
        \\ lit(a)
    );

    check(
        \\(ab)
    ,
        \\cap
        \\ cat
        \\  lit(a)
        \\  lit(b)
    );

    check(
        \\a|b
    ,
        \\alt
        \\ lit(a)
        \\ lit(b)
    );

    check(
        \\a|b|c
    ,
        \\alt
        \\ lit(a)
        \\ lit(b)
        \\ lit(c)
    );

    check(
        \\(a|b)
    ,
        \\cap
        \\ alt
        \\  lit(a)
        \\  lit(b)
    );

    check(
        \\(a|b|c)
    ,
        \\cap
        \\ alt
        \\  lit(a)
        \\  lit(b)
        \\  lit(c)
    );

    check(
        \\(ab|bc|cd)
    ,
        \\cap
        \\ alt
        \\  cat
        \\   lit(a)
        \\   lit(b)
        \\  cat
        \\   lit(b)
        \\   lit(c)
        \\  cat
        \\   lit(c)
        \\   lit(d)
    );

    check(
        \\(ab|(bc|(cd)))
    ,
        \\cap
        \\ alt
        \\  cat
        \\   lit(a)
        \\   lit(b)
        \\  cap
        \\   alt
        \\    cat
        \\     lit(b)
        \\     lit(c)
        \\    cap
        \\     cat
        \\      lit(c)
        \\      lit(d)
    );

    check(
        \\.
    ,
        \\dot
    );
}

test "parse escape" {
    check(
        \\\a\f\t\n\r\v
    ,
        \\cat
        \\ lit(0x7)
        \\ lit(0xc)
        \\ lit(\t)
        \\ lit(\n)
        \\ lit(\r)
        \\ lit(0xb)
    );

    check(
        \\\\\.\+\*\?\(\)\|\[\]\{\}\^\$
    ,
        \\cat
        \\ lit(\)
        \\ lit(.)
        \\ lit(+)
        \\ lit(*)
        \\ lit(?)
        \\ lit(()
        \\ lit())
        \\ lit(|)
        \\ lit([)
        \\ lit(])
        \\ lit({)
        \\ lit(})
        \\ lit(^)
        \\ lit($)
    );

    check("\\123",
        \\lit(S)
    );

    check("\\1234",
        \\cat
        \\ lit(S)
        \\ lit(4)
    );

    check("\\x53",
        \\lit(S)
    );

    check("\\x534",
        \\cat
        \\ lit(S)
        \\ lit(4)
    );

    check("\\x{53}",
        \\lit(S)
    );

    check("\\x{53}4",
        \\cat
        \\ lit(S)
        \\ lit(4)
    );
}

test "parse character classes" {
    check(
        \\[a]
    ,
        \\bset([a-a])
    );

    check(
        \\[\x00]
    ,
        \\bset([0x0-0x0])
    );

    check(
        \\[\n]
    ,
        \\bset([\n-\n])
    );

    check(
        \\[^a]
    ,
        \\bset([0x0-`][b-0xff])
    );

    check(
        \\[^\x00]
    ,
        \\bset([0x1-0xff])
    );

    check(
        \\[^\n]
    ,
        \\bset([0x0-\t][0xb-0xff])
    );

    check(
        \\[]]
    ,
        \\bset([]-]])
    );

    check(
        \\[]\[]
    ,
        \\bset([[-[][]-]])
    );

    check(
        \\[\[]]
    ,
        \\cat
        \\ bset([[-[])
        \\ lit(])
    );

    check(
        \\[]-]
    ,
        \\bset([---][]-]])
    );

    check(
        \\[-]]
    ,
        \\cat
        \\ bset([---])
        \\ lit(])
    );
}

fn checkError(re: []const u8, expected_err: ParseError) void {
    var p = Parser.init(debug.global_allocator);
    const parse_result = p.parse(re);

    if (parse_result) |expr| {
        const ast = repr(expr) catch unreachable;
        const spaces = [_]u8{ ' ', '\n' };
        const trimmed_ast = mem.trim(u8, ast, spaces);

        debug.warn(
            \\
            \\-- parsed the regex
            \\
            \\{}
            \\
            \\-- expected the following
            \\
            \\{}
            \\
            \\-- but instead got
            \\
            \\{}
            \\
            \\
        ,
            re,
            @errorName(expected_err),
            trimmed_ast,
        );

        @panic("assertion failure");
    } else |found_err| {
        if (found_err != expected_err) {
            debug.warn(
                \\
                \\-- parsed the regex
                \\
                \\{}
                \\
                \\-- expected the following
                \\
                \\{}
                \\
                \\-- but instead got
                \\
                \\{}
                \\
                \\
            ,
                re,
                @errorName(expected_err),
                @errorName(found_err),
            );

            @panic("assertion failure");
        }
    }
}

test "parse errors repeat" {
    checkError(
        \\*
    , ParseError.MissingRepeatOperand);

    checkError(
        \\(*
    , ParseError.MissingRepeatOperand);

    checkError(
        \\({5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\{5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a**
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a|*
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a*{5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a|{5}
    , ParseError.MissingRepeatOperand);

    checkError(
        \\a{}
    , ParseError.InvalidRepeatArgument);

    checkError(
        \\a{5
    , ParseError.UnclosedRepeat);

    checkError(
        \\a{xyz
    , ParseError.InvalidRepeatArgument);

    checkError(
        \\a{12,xyz
    , ParseError.InvalidRepeatArgument);

    checkError(
        \\a{999999999999}
    , ParseError.ExcessiveRepeatCount);

    checkError(
        \\a{1,999999999999}
    , ParseError.ExcessiveRepeatCount);

    checkError(
        \\a{12x}
    , ParseError.UnclosedRepeat);

    checkError(
        \\a{1,12x}
    , ParseError.UnclosedRepeat);
}

test "parse errors alternate" {
    checkError(
        \\|a
    , ParseError.EmptyAlternate);

    checkError(
        \\(|a)
    , ParseError.EmptyAlternate);

    checkError(
        \\a||
    , ParseError.EmptyAlternate);

    checkError(
        \\)
    , ParseError.UnopenedParentheses);

    checkError(
        \\ab)
    , ParseError.UnopenedParentheses);

    checkError(
        \\a|b)
    , ParseError.UnopenedParentheses);

    checkError(
        \\(a|b
    , ParseError.UnclosedParentheses);

    //checkError(
    //    \\(a|)
    //,
    //    ParseError.UnopenedParentheses
    //);

    //checkError(
    //    \\()
    //,
    //    ParseError.UnopenedParentheses
    //);

    checkError(
        \\ab(xy
    , ParseError.UnclosedParentheses);

    //checkError(
    //    \\()
    //,
    //    ParseError.UnopenedParentheses
    //);

    //checkError(
    //    \\a|
    //,
    //    ParseError.UnbalancedParentheses
    //);
}

test "parse errors escape" {
    checkError("\\", ParseError.OpenEscapeCode);

    checkError("\\m", ParseError.UnrecognizedEscapeCode);

    checkError("\\x", ParseError.InvalidHexDigit);

    //checkError(
    //    "\\xA"
    //,
    //    ParseError.UnrecognizedEscapeCode
    //);

    //checkError(
    //    "\\xAG"
    //,
    //    ParseError.UnrecognizedEscapeCode
    //);

    checkError("\\x{", ParseError.InvalidHexDigit);

    checkError("\\x{A", ParseError.UnclosedHexCharacterCode);

    checkError("\\x{AG}", ParseError.UnclosedHexCharacterCode);

    checkError("\\x{D800}", ParseError.InvalidHexDigit);

    checkError("\\x{110000}", ParseError.InvalidHexDigit);

    checkError("\\x{99999999999999}", ParseError.InvalidHexDigit);
}

test "parse errors character class" {
    checkError(
        \\[
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^
    , ParseError.UnclosedBrackets);

    checkError(
        \\[a
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^a
    , ParseError.UnclosedBrackets);

    checkError(
        \\[a-
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^a-
    , ParseError.UnclosedBrackets);

    checkError(
        \\[---
    , ParseError.UnclosedBrackets);

    checkError(
        \\[\A]
    , ParseError.UnrecognizedEscapeCode);

    //checkError(
    //    \\[a-\d]
    //,
    //    ParseError.UnclosedBrackets
    //);

    //checkError(
    //    \\[a-\A]
    //,
    //    ParseError.UnrecognizedEscapeCode
    //);

    checkError(
        \\[\A-a]
    , ParseError.UnrecognizedEscapeCode);

    //checkError(
    //    \\[z-a]
    //,
    //    ParseError.UnclosedBrackets
    //);

    checkError(
        \\[]
    , ParseError.UnclosedBrackets);

    checkError(
        \\[^]
    , ParseError.UnclosedBrackets);

    //checkError(
    //    \\[^\d\D]
    //,
    //    ParseError.UnclosedBrackets
    //);

    //checkError(
    //    \\[+--]
    //,
    //    ParseError.UnclosedBrackets
    //);

    //checkError(
    //    \\[a-a--\xFF]
    //,
    //    ParseError.UnclosedBrackets
    //);
}
