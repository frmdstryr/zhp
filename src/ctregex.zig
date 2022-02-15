const std = @import("std");

// Compile time regular expressions for zig
// by alexnask
// https://github.com/alexnask/ctregex.zig

fn utf16leCharSequenceLength(first_char: u16) !u2 {
    const c0: u21 = first_char;
    if (first_char & ~@as(u21, 0x03ff) == 0xd800) {
        return 2;
    } else if (c0 & ~@as(u21, 0x03ff) == 0xdc00) {
        return error.UnexpectedSecondSurrogateHalf;
    }
    return 1;
}

fn utf16leDecode(chars: []const u16) !u21 {
    const c0: u21 = chars[0];
    if (c0 & ~@as(u21, 0x03ff) == 0xd800) {
        const c1: u21 = chars[1];
        if (c1 & ~@as(u21, 0x03ff) != 0xdc00) return error.ExpectedSecondSurrogateHalf;
        return 0x10000 + (((c0 & 0x03ff) << 10) | (c1 & 0x03ff));
    } else if (c0 & ~@as(u21, 0x03ff) == 0xdc00) {
        return error.UnexpectedSecondSurrogateHalf;
    } else {
        return c0;
    }
}

fn ctUtf8EncodeChar(comptime codepoint: u21) []const u8 {
    var buf: [4]u8 = undefined;
    return buf[0 .. std.unicode.utf8Encode(codepoint, &buf) catch unreachable];
}

fn checkAscii(comptime codepoint: u21) void {
    if (codepoint > 127) @compileError("Cannot match character '" ++ ctUtf8EncodeChar(codepoint) ++ "' in ascii mode.");
}

fn charLenInEncoding(comptime codepoint: u21, comptime encoding: Encoding) usize {
    switch (encoding) {
        .ascii => {
            checkAscii(codepoint);
            return 1;
        },
        .utf8 => return std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable,
        .utf16le => return if (codepoint < 0x10000) 1 else 2,
        .codepoint => return 1,
    }
}

fn ctEncode(comptime str: []const u21, comptime encoding: Encoding) []const encoding.CharT() {
    if (encoding == .codepoint) return str;

    var len: usize = 0;
    for (str) |c| len += charLenInEncoding(c, encoding);

    var result: [len]encoding.CharT() = undefined;
    var idx: usize = 0;
    for (str) |c| {
        switch (encoding) {
            .ascii => {
                result[idx] = @truncate(u8, c);
                idx += 1;
            },
            .utf8 => idx += std.unicode.utf8Encode(c, result[idx..]) catch unreachable,
            .utf16le => {
                const utf8_c = ctUtf8EncodeChar(c);
                idx += std.unicode.utf8ToUtf16Le(result[idx..], utf8_c) catch unreachable;
            },
            .codepoint => unreachable,
        }
    }
    return &result;
}

fn ctIntStr(comptime int: anytype) []const u8 {
    var buf: [16]u8 = undefined;
    return std.fmt.bufPrint(&buf, "{}", .{int}) catch unreachable;
}

/// Regex grammar
/// ```
/// root ::= expr?
/// expr ::= subexpr ('|' expr)?
/// subexpr ::= atom ('*' | '+' | '?' | ('{' digit+ (',' (digit+)?)? '}'))? subexpr?
/// atom ::= grouped | brackets | '.' | char_class | '\' special | '\' | rest_char
/// grouped ::= '(' ('?' (':' | ('<' ascii_ident '>'))? expr ')'
/// brackets ::= '[' '^'? (brackets_rule)+ ']'
/// brackets_rule ::= brackets_atom | brackets_atom '-' brackets_atom
/// brackets_atom ::= ('\' special_brackets | '\' | rest_brackets)+
/// special_brackets ::= '-' | ']' | '^'
/// rest_brackets ::=  <char>-special_brackets
/// special ::= '.' | '[' | ']'| '(' | ')' | '|' | '*' | '+' | '?' | '^' | '{' | '}'
/// rest_char ::= <char>-special
/// char_class ::= '\d' | '\s'
/// ```
const RegexParser = struct {
    iterator: std.unicode.Utf8Iterator,
    captures: []const *const Grouped = &[0]*const Grouped{},
    curr_capture: usize = 0,

    fn init(comptime source: []const u8) RegexParser {
        const view = comptime std.unicode.Utf8View.initComptime(source);
        return .{
            .iterator = comptime view.iterator(),
        };
    }

    fn parse(comptime source: []const u8) ?ParseResult {
        var parser = RegexParser.init(source);
        return parser.parseRoot();
    }

    fn skipWhitespace(comptime parser: *RegexParser) void {
        while (parser.iterator.i < parser.iterator.bytes.len and
            (parser.iterator.bytes[parser.iterator.i] == ' ' or
            parser.iterator.bytes[parser.iterator.i] == '\t')) : (parser.iterator.i += 1)
        {}
    }

    fn peek(comptime parser: *RegexParser) ?u21 {
        if (parser.atEnd()) return null;

        const curr_i = parser.iterator.i;
        const next = parser.iterator.nextCodepoint() orelse @compileError("Incomplete codepoint at the end of the regex string");
        parser.iterator.i = curr_i;
        return next;
    }

    fn peekOneOf(comptime parser: *RegexParser, chars: anytype) ?u21 {
        const c = parser.peek() orelse return null;
        for (chars) |candidate| {
            if (c == candidate) return c;
        }
        return null;
    }

    fn atEnd(comptime parser: RegexParser) bool {
        return parser.iterator.i >= parser.iterator.bytes.len;
    }

    fn consumeNotOneOf(comptime parser: *RegexParser, chars: anytype) ?u21 {
        const c = parser.peek() orelse return null;
        for (chars) |candidate| {
            if (c == candidate) return null;
        }
        return parser.iterator.nextCodepoint().?;
    }

    fn consumeOneOf(comptime parser: *RegexParser, chars: anytype) ?u21 {
        const c = parser.peek() orelse return null;
        for (chars) |candidate| {
            if (c == candidate) {
                return parser.iterator.nextCodepoint().?;
            }
        }
        return null;
    }

    fn consumeChar(comptime parser: *RegexParser, char: u21) bool {
        const c = parser.peek() orelse return false;
        if (c == char) {
            _ = parser.iterator.nextCodepoint().?;
            return true;
        }
        return false;
    }

    fn raiseError(comptime parser: *RegexParser, comptime fmt: []const u8, args: anytype) void {
        var start_idx: usize = 0;
        while (parser.iterator.i - start_idx >= 40) {
            start_idx += std.unicode.utf8ByteSequenceLength(parser.iterator.bytes[start_idx]) catch unreachable;
        }
        var start_spaces: usize = 0;
        {
            var idx: usize = start_idx;
            while (idx < parser.iterator.i) {
                const n = std.unicode.utf8ByteSequenceLength(parser.iterator.bytes[idx]) catch unreachable;
                idx += n;
                if (n > 1) {
                    start_spaces += 2;
                } else {
                    start_spaces += 1;
                }
            }
        }
        var end_idx: usize = parser.iterator.i;
        while (end_idx - parser.iterator.i <= 40 and end_idx < parser.iterator.bytes.len) {
            end_idx += std.unicode.utf8ByteSequenceLength(parser.iterator.bytes[end_idx]) catch unreachable;
        }

        const line_prefix = if (start_idx == 0) "\n" else "\n[...] ";
        const line_suffix = if (end_idx == parser.iterator.bytes.len) "\n" else " [...]\n";

        const ArgTuple = struct {
            tuple: anytype = .{},
        };
        var arg_list = ArgTuple{};
        for (args) |arg| {
            if (@TypeOf(arg) == ?u21) {
                if (arg) |cp| {
                    arg_list.tuple = arg_list.tuple ++ .{ctUtf8EncodeChar(cp)};
                } else {
                    arg_list.tuple = arg_list.tuple ++ .{"null"};
                }
            } else if (@TypeOf(arg) == u21) {
                arg_list.tuple = arg_list.tuple ++ .{ctUtf8EncodeChar(arg)};
            } else {
                arg_list.tuple = arg_list.tuple ++ .{arg};
            }
        }

        var error_buf: [128]u8 = undefined;
        const error_slice = std.fmt.bufPrint(&error_buf, "error: {}: " ++ fmt, .{parser.iterator.i - 1} ++ arg_list.tuple) catch unreachable;
        @compileError("\n" ++ error_slice ++ line_prefix ++ parser.iterator.bytes[start_idx..end_idx] ++ line_suffix ++ " " ** (start_spaces + line_prefix.len - 2) ++ "^");
    }

    const ParseResult = struct {
        root: Expr,
        captures: []const *const Grouped,
    };

    // root ::= expr?
    fn parseRoot(comptime parser: *RegexParser) ?ParseResult {
        comptime {
            if (parser.parseExpr()) |expr| {
                if (!parser.atEnd())
                    parser.raiseError("Invalid regex, stopped parsing here", .{});
                return ParseResult{ .root = expr, .captures = parser.captures };
            }
            return null;
        }
    }

    // expr ::= subexpr ('|' expr)?
    fn parseExpr(comptime parser: *RegexParser) ?Expr {
        const sub_expr = parser.parseSubExpr() orelse return null;
        parser.skipWhitespace();

        if (parser.consumeChar('|')) {
            const rhs = parser.parseExpr() orelse parser.raiseError("Expected expression after '|'", .{});
            return Expr{ .lhs = sub_expr, .rhs = &rhs };
        }

        return Expr{ .lhs = sub_expr, .rhs = null };
    }

    const modifiers = .{ '*', '+', '?' };
    const special_chars = .{ '.', '[', ']', '(', ')', '|', '*', '+', '?', '^', '{', '}' };

    // subexpr ::= atom ('*' | '+' | '?' | ('{' digit+ (',' (digit+)?)? '}'))? subexpr?
    fn parseSubExpr(comptime parser: *RegexParser) ?SubExpr {
        const atom = parser.parseAtom() orelse return null;
        parser.skipWhitespace();

        var lhs = SubExpr{ .atom = .{ .data = atom } };
        if (parser.consumeOneOf(modifiers)) |mod| {
            lhs.atom.mod = .{ .char = mod };
            parser.skipWhitespace();
        } else if (parser.consumeChar('{')) {
            parser.skipWhitespace();
            const min_reps = parser.parseNaturalNum();
            parser.skipWhitespace();
            if (parser.consumeChar(',')) {
                parser.skipWhitespace();
                const max_reps = if (parser.maybeParseNaturalNum()) |reps| block: {
                    if (reps <= min_reps)
                        parser.raiseError("Expected repetition upper bound to be greater or equal to {}", .{min_reps});
                    break :block reps;
                } else 0;
                lhs.atom.mod = .{
                    .repetitions_range = .{
                        .min = min_reps,
                        .max = max_reps,
                    },
                };
            } else {
                if (min_reps == 0) parser.raiseError("Exactly zero repetitions requested...", .{});

                lhs.atom.mod = .{
                    .exact_repetitions = min_reps,
                };
            }
            parser.skipWhitespace();
            if (!parser.consumeChar('}'))
                parser.raiseError("Expected closing '}' after repetition modifier", .{});
        }

        if (parser.parseSubExpr()) |rhs| {
            const old_lhs = lhs;
            return SubExpr{ .concat = .{ .lhs = &old_lhs, .rhs = &rhs } };
        }
        return lhs;
    }

    // atom ::= grouped | brackets | '.' | char_class | '\' special | '\' | rest_char
    fn parseAtom(comptime parser: *RegexParser) ?Atom {
        parser.skipWhitespace();

        if (parser.parseGrouped()) |grouped| {
            return Atom{ .grouped = grouped };
        }

        if (parser.parseBrackets()) |brackets| {
            return Atom{ .brackets = brackets };
        }

        if (parser.consumeChar('.')) {
            return Atom.any;
        }

        var str: []const u21 = &[0]u21{};
        // char_class | ('\' special | '\\' | rest_char)+
        if (parser.consumeChar('\\')) block: {
            // char_class := '\d' | '\s'
            if (parser.consumeOneOf(char_classes)) |class| {
                return Atom{ .char_class = class };
            }

            // special := '.' | '[' | ']'| '(' | ')' | '|' | '*' | '+' | '?' | '^' | '{' | '}'
            if (parser.consumeOneOf(special_chars ++ .{ ' ', '\t', '\\' })) |c| {
                str = str ++ &[1]u21{c};
                break :block;
            }
            parser.raiseError("Invalid character '{}' after escape \\", .{parser.peek()});
        }

        charLoop: while (true) {
            parser.skipWhitespace();
            if (parser.consumeChar('\\')) {
                if (parser.consumeOneOf(special_chars ++ .{ ' ', '\t', '\\' })) |c| {
                    str = str ++ &[1]u21{c};
                    continue :charLoop;
                }
                if (parser.peekOneOf(char_classes) != null) {
                    // We know the backslash is 1 byte long
                    // So we can safely do this
                    parser.iterator.i -= 1;
                    break :charLoop;
                }
                parser.raiseError("Invalid character '{}' after escape \\", .{parser.peek()});
            } else if (parser.peekOneOf(modifiers ++ .{'{'}) != null) {
                if (str.len == 1) return Atom{ .literal = str };
                if (str.len == 0) parser.raiseError("Stray modifier character '{}' applies to no expression", .{parser.peek()});
                parser.iterator.i -= std.unicode.utf8CodepointSequenceLength(str[str.len - 1]) catch unreachable;
                return Atom{ .literal = str[0 .. str.len - 1] };
            }
            // rest_char := <char>-special
            str = str ++ &[1]u21{parser.consumeNotOneOf(special_chars) orelse break :charLoop};
        }
        if (str.len == 0) return null;
        return Atom{ .literal = str };
    }

    fn parseAsciiIdent(comptime parser: *RegexParser) []const u8 {
        var c = parser.peek() orelse parser.raiseError("Expected ascii identifier", .{});
        if (c > 127) parser.raiseError("Expected ascii character in identifier, got '{}'", .{c});
        if (c != '_' and !std.ascii.isAlpha(@truncate(u8, c))) {
            parser.raiseError("Identifier must start with '_' or a letter, got '{}''", .{c});
        }
        var res: []const u8 = &[1]u8{@truncate(u8, parser.iterator.nextCodepoint() orelse unreachable)};
        readChars: while (true) {
            c = parser.peek() orelse break :readChars;
            if (c > 127 or (c != '_' and !std.ascii.isAlNum(@truncate(u8, c))))
                break :readChars;
            res = res ++ &[1]u8{@truncate(u8, parser.iterator.nextCodepoint() orelse unreachable)};
        }
        return res;
    }

    fn parseNaturalNum(comptime parser: *RegexParser) usize {
        return parser.maybeParseNaturalNum() orelse parser.raiseError("Expected natural number", .{});
    }

    fn maybeParseNaturalNum(comptime parser: *RegexParser) ?usize {
        var c = parser.peek() orelse return null;
        if (c > 127 or !std.ascii.isDigit(@truncate(u8, c))) return null;
        var res: usize = (parser.iterator.nextCodepoint() orelse unreachable) - '0';
        readChars: while (true) {
            c = parser.peek() orelse break :readChars;
            if (c > 127 or !std.ascii.isDigit(@truncate(u8, c))) break :readChars;
            res = res * 10 + ((parser.iterator.nextCodepoint() orelse unreachable) - '0');
        }
        return res;
    }

    // grouped := '(' expr ')'
    fn parseGrouped(comptime parser: *RegexParser) ?Grouped {
        if (!parser.consumeChar('(')) return null;
        parser.skipWhitespace();

        var grouped_expr = Grouped{ .capture_info = .{ .idx = parser.curr_capture, .name = null }, .expr = undefined };

        if (parser.consumeChar('?')) {
            parser.skipWhitespace();
            if (parser.consumeChar(':')) {
                grouped_expr.capture_info = null;
            } else if (parser.consumeChar('<')) {
                // TODO Support unicode names?
                // TODO Check for name redefinition
                grouped_expr.capture_info.?.name = parser.parseAsciiIdent();
                if (!parser.consumeChar('>')) parser.raiseError("Expected > after grouped expression name", .{});
            } else {
                parser.raiseError("Expected : or < after ? at the start of a grouped expression.", .{});
            }
        }

        const expr = parser.parseExpr() orelse parser.raiseError("Expected expression after '('", .{});
        parser.skipWhitespace();
        if (!parser.consumeChar(')')) parser.raiseError("Expected ')' after expression", .{});
        grouped_expr.expr = &expr;

        if (grouped_expr.capture_info != null) {
            parser.captures = parser.captures ++ &[1]*const Grouped{&grouped_expr};
            parser.curr_capture += 1;
        }

        return grouped_expr;
    }

    // brackets ::= '[' '^'? (brackets_rule)+ ']'
    fn parseBrackets(comptime parser: *RegexParser) ?Brackets {
        if (!parser.consumeChar('[')) return null;
        parser.skipWhitespace();

        const is_exclusive = parser.consumeChar('^');
        if (is_exclusive) parser.skipWhitespace();

        var brackets = Brackets{
            .rules = &[1]Brackets.Rule{
                parser.parseBracketsRule() orelse parser.raiseError("Expected at least one bracket rule", .{}),
            },
            .is_exclusive = is_exclusive,
        };

        while (parser.parseBracketsRule()) |rule| {
            brackets.rules = brackets.rules ++ &[1]Brackets.Rule{rule};
            parser.skipWhitespace();
        }
        if (!parser.consumeChar(']')) parser.raiseError("Missing matching closing bracket", .{});

        return brackets;
    }

    // brackets_rule ::= brackets_atom | brackets_atom '-' brackets_atom
    // brackets_atom := '\' special_brackets | '\\' | rest_brackets
    // special_brackets := '-' | ']'
    // rest_brackets :=  <char>-special_brackets
    fn parseBracketsRule(comptime parser: *RegexParser) ?Brackets.Rule {
        const special_brackets = .{ '-', ']', '^' };

        const first_char = if (parser.consumeChar('\\')) block: {
            if (parser.consumeOneOf(special_brackets ++ .{ ' ', '\t', '\\' })) |char| {
                break :block char;
            } else if (parser.consumeOneOf(char_classes)) |char| {
                return Brackets.Rule{ .char_class = char };
            }
            parser.raiseError("Invalid character '{}' after escape \\", .{parser.peek()});
        } else parser.consumeNotOneOf(special_brackets) orelse return null;

        parser.skipWhitespace();
        if (parser.consumeChar('-')) {
            parser.skipWhitespace();
            const second_char = if (parser.consumeChar('\\')) block: {
                if (parser.consumeOneOf(special_brackets ++ .{ ' ', '\t', '\\' })) |char| {
                    break :block char;
                }
                parser.raiseError("Invalid character '{}' after escape \\", .{parser.peek()});
            } else parser.consumeNotOneOf(special_brackets) orelse parser.raiseError("Expected a valid character after - in bracket rule, got character '{}'", .{parser.peek()});

            if (first_char >= second_char) {
                parser.raiseError("Invalid range '{}-{}', start should be smaller than end", .{ first_char, second_char });
            }
            // TODO Check if the char is already in some other rule and error?
            return Brackets.Rule{ .range = .{ .start = first_char, .end = second_char } };
        }
        return Brackets.Rule{ .char = first_char };
    }

    const SubExpr = union(enum) {
        atom: struct {
            data: Atom,
            mod: union(enum) {
                char: u8,
                exact_repetitions: usize,
                repetitions_range: struct {
                    min: usize,
                    /// Zero for max means unbounded
                    max: usize,
                },
                none,
            } = .none,
        },
        concat: struct {
            lhs: *const SubExpr,
            rhs: *const SubExpr,
        },

        fn ctStr(comptime self: SubExpr) []const u8 {
            switch (self) {
                .atom => |atom| {
                    const atom_str = atom.data.ctStr();
                    switch (atom.mod) {
                        .none => {},
                        .exact_repetitions => |reps| return atom_str ++ "{" ++ ctIntStr(reps) ++ "}",
                        .repetitions_range => |range| return atom_str ++ "{" ++ ctIntStr(range.min) ++ if (range.max == 0)
                            ",<inf>}"
                        else
                            (", " ++ ctIntStr(range.max) ++ "}"),
                        .char => |c| return atom_str ++ &[1]u8{c},
                    }
                    return atom_str;
                },
                .concat => |concat| {
                    return concat.lhs.ctStr() ++ " " ++ concat.rhs.ctStr();
                },
            }
            return "";
        }

        fn minLen(comptime self: SubExpr, comptime encoding: Encoding) usize {
            switch (self) {
                .atom => |atom| {
                    const atom_min_len = atom.data.minLen(encoding);
                    switch (atom.mod) {
                        .char => |c| if (c == '*' or c == '?') return 0,
                        .exact_repetitions => |reps| return reps * atom_min_len,
                        .repetitions_range => |range| return range.min * atom_min_len,
                        .none => {},
                    }
                    return atom_min_len;
                },
                .concat => |concat| return concat.lhs.minLen(encoding) + concat.rhs.minLen(encoding),
            }
        }
    };

    const char_classes = .{ 'd', 's' };
    fn charClassToString(class: u21) []const u8 {
        return switch (class) {
            'd' => "<digit>",
            's' => "<whitespace>",
            else => unreachable,
        };
    }

    fn charClassMinLen(comptime class: u21, comptime encoding: Encoding) usize {
        _ = class;
        _ = encoding;
        return 1;
    }

    const Expr = struct {
        lhs: SubExpr,
        rhs: ?*const Expr,

        fn ctStr(comptime self: Expr) []const u8 {
            var str: []const u8 = self.lhs.ctStr();
            if (self.rhs) |rhs| {
                str = str ++ " | " ++ rhs.ctStr();
            }
            return str;
        }

        fn minLen(comptime self: Expr, comptime encoding: Encoding) usize {
            const lhs_len = self.lhs.minLen(encoding);
            if (self.rhs) |rhs| {
                const rhs_len = rhs.minLen(encoding);
                return std.math.min(lhs_len, rhs_len);
            }
            return lhs_len;
        }
    };

    const Atom = union(enum) {
        grouped: Grouped,
        brackets: Brackets,
        any,
        char_class: u21,
        literal: []const u21,

        fn ctStr(comptime self: Atom) []const u8 {
            return switch (self) {
                .grouped => |grouped| grouped.ctStr(),
                .brackets => |bracks| bracks.ctStr(),
                .any => "<any_char>",
                .char_class => |class| charClassToString(class),
                .literal => |codepoint_str| block: {
                    var str: []const u8 = "literal<";
                    for (codepoint_str) |codepoint| {
                        str = str ++ ctUtf8EncodeChar(codepoint);
                    }
                    break :block str ++ ">";
                },
            };
        }

        fn minLen(comptime self: Atom, comptime encoding: Encoding) usize {
            return switch (self) {
                .grouped => |grouped| grouped.minLen(encoding),
                .brackets => |brackets| brackets.minLen(encoding),
                .any => 1,
                .char_class => |class| charClassMinLen(class, encoding),
                .literal => |codepoint_str| block: {
                    var len: usize = 0;
                    for (codepoint_str) |cp| {
                        len += charLenInEncoding(cp, encoding);
                    }
                    break :block len;
                },
            };
        }
    };

    const Grouped = struct {
        expr: *const Expr,
        capture_info: ?struct {
            idx: usize,
            name: ?[]const u8,
        },

        fn ctStr(comptime self: Grouped) []const u8 {
            const str = "(" ++ self.expr.ctStr() ++ ")";
            if (self.capture_info) |info| {
                return "capture<" ++ (if (info.name) |n| n ++ ", " else "") ++ str ++ ">";
            }
            return str;
        }

        fn minLen(comptime self: Grouped, comptime encoding: Encoding) usize {
            return self.expr.minLen(encoding);
        }
    };

    const Brackets = struct {
        is_exclusive: bool,
        rules: []const Rule,

        const Rule = union(enum) {
            char: u21,
            range: struct {
                start: u21,
                end: u21,
            },
            char_class: u21,
        };

        fn ctStr(comptime self: Brackets) []const u8 {
            var str: []const u8 = "[";
            if (self.is_exclusive) str = str ++ "<not> ";
            for (self.rules) |rule, idx| {
                if (idx > 0) str = str ++ " ";
                str = str ++ switch (rule) {
                    .char => |c| ctUtf8EncodeChar(c),
                    .range => |r| ctUtf8EncodeChar(r.start) ++ "-" ++ ctUtf8EncodeChar(r.end),
                    .char_class => |class| charClassToString(class),
                };
            }

            return str ++ "]";
        }

        fn minLen(comptime self: Brackets, comptime encoding: Encoding) usize {
            if (self.is_exclusive) return 1;
            var min_len: usize = std.math.maxInt(usize);
            for (self.rules) |rule| {
                var curr_len: usize = switch (rule) {
                    .char => |c| charLenInEncoding(c, encoding),
                    .range => |range| charLenInEncoding(range.start, encoding),
                    .char_class => |class| charClassMinLen(class, encoding),
                };
                if (curr_len < min_len) min_len = curr_len;
                if (min_len == 1) return 1;
            }
            return min_len;
        }
    };
};

pub const Encoding = enum {
    ascii,
    utf8,
    utf16le,
    codepoint,

    pub fn CharT(self: Encoding) type {
        return switch (self) {
            .ascii, .utf8 => u8,
            .utf16le => u16,
            .codepoint => u21,
        };
    }
};

inline fn readOneChar(comptime options: MatchOptions, str: []const options.encoding.CharT()) !@TypeOf(str) {
    switch (options.encoding) {
        .ascii, .codepoint => return str[0..1],
        .utf8 => return str[0..try std.unicode.utf8ByteSequenceLength(str[0])],
        .utf16le => return str[0..try utf16leCharSequenceLength(str[0])],
    }
}

inline fn inCharClass(comptime class: u21, cp: u21) bool {
    switch (class) {
        'd' => return cp >= '0' and cp <= '9',
        's' => {
            // TODO Include same chars as PCRE
            return cp == ' ' or cp == '\t';
        },
        else => unreachable,
    }
}

inline fn readCharClass(comptime class: u21, comptime options: MatchOptions, str: []const options.encoding.CharT()) ?@TypeOf(str) {
    switch (class) {
        'd' => {
            switch (options.encoding) {
                .ascii, .utf8 => return if (std.ascii.isDigit(str[0])) str[0..1] else null,
                .codepoint, .utf16le => return if (str[0] >= '0' and str[0] <= '9') str[0..1] else null,
            }
        },
        's' => {
            // TODO Include same chars as PCRE
            return if (str[0] == ' ' or str[0] == '\t') str[0..1] else null;
        },
        else => unreachable,
    }
}

inline fn matchAtom(comptime atom: RegexParser.Atom, comptime options: MatchOptions, str: []const options.encoding.CharT(), result: anytype) !?@TypeOf(str) {
    const min_len = comptime atom.minLen(options.encoding);
    if (str.len < min_len) return null;

    switch (atom) {
        .grouped => |grouped| {
            const ret = (try matchExpr(grouped.expr.*, options, str, result)) orelse return null;
            if (grouped.capture_info) |info| {
                result.captures[info.idx] = ret;
            }
            return ret;
        },
        .any => return try readOneChar(options, str),
        .char_class => |class| return readCharClass(class, options, str),
        .literal => |lit| {
            const encoded_lit = comptime ctEncode(lit, options.encoding);
            if (std.mem.eql(options.encoding.CharT(), encoded_lit, str[0..encoded_lit.len])) {
                return str[0..encoded_lit.len];
            }
            return null;
        },
        .brackets => |brackets| {
            var this_slice: @TypeOf(str) = undefined;

            const this_cp: u21 = switch (options.encoding) {
                .codepoint, .ascii => block: {
                    this_slice = str[0..1];
                    break :block str[0];
                },
                .utf8 => block: {
                    this_slice = str[0..try std.unicode.utf8ByteSequenceLength(str[0])];
                    break :block try std.unicode.utf8Decode(this_slice);
                },
                .utf16le => block: {
                    this_slice = str[0..try utf16leCharSequenceLength(str[0])];
                    break :block try utf16leDecode(this_slice);
                },
            };

            inline for (brackets.rules) |rule| {
                switch (rule) {
                    .char => |c| {
                        if (c == this_cp)
                            return if (brackets.is_exclusive) null else this_slice;
                    },
                    .range => |range| {
                        if (options.encoding == .ascii) {
                            checkAscii(range.start);
                            checkAscii(range.end);
                        }

                        if (this_cp >= range.start and this_cp <= range.end)
                            return if (brackets.is_exclusive) null else this_slice;
                    },
                    .char_class => |class| if (inCharClass(class, this_cp))
                        return if (brackets.is_exclusive) null else this_slice,
                }
            }
            return if (brackets.is_exclusive) try readOneChar(options, str) else null;
        },
    }
}

inline fn matchSubExpr(comptime sub_expr: RegexParser.SubExpr, comptime options: MatchOptions, str: []const options.encoding.CharT(), result: anytype) !?@TypeOf(str) {
    const min_len = comptime sub_expr.minLen(options.encoding);
    if (str.len < min_len) return null;

    switch (sub_expr) {
        .atom => |atom| {
            switch (atom.mod) {
                .none => return try matchAtom(atom.data, options, str, result),
                .char => |c| switch (c) {
                    // TODO Abstract this somehow?
                    '*' => {
                        if (try matchAtom(atom.data, options, str, result)) |ret_slice| {
                            var curr_slice: @TypeOf(str) = str[0..ret_slice.len];
                            while (try matchAtom(atom.data, options, str[curr_slice.len..], result)) |matched_slice| {
                                curr_slice = str[0 .. matched_slice.len + curr_slice.len];
                            }
                            return curr_slice;
                        } else {
                            return str[0..0];
                        }
                    },
                    '+' => {
                        const ret_slice = (try matchAtom(atom.data, options, str, result)) orelse return null;
                        var curr_slice: @TypeOf(str) = str[0..ret_slice.len];
                        while (try matchAtom(atom.data, options, str[curr_slice.len..], result)) |matched_slice| {
                            curr_slice = str[0 .. matched_slice.len + curr_slice.len];
                        }
                        return curr_slice;
                    },
                    '?' => {
                        return (try matchAtom(atom.data, options, str, result)) orelse str[0..0];
                    },
                    else => unreachable,
                },
                .exact_repetitions => |reps| {
                    var curr_slice: @TypeOf(str) = str[0..0];
                    // TODO Using an inline while here crashes the compiler in codegen
                    var curr_rep: usize = reps;
                    while (curr_rep > 0) : (curr_rep -= 1) {
                        if (try matchAtom(atom.data, options, str[curr_slice.len..], result)) |matched_slice| {
                            curr_slice = str[0 .. matched_slice.len + curr_slice.len];
                        } else return null;
                    }
                    return curr_slice;
                },
                .repetitions_range => |range| {
                    var curr_slice: @TypeOf(str) = str[0..0];
                    // Do minimum reps
                    // TODO Using an inline while here crashes the compiler in codegen
                    var curr_rep: usize = 0;
                    while (curr_rep < range.min) : (curr_rep += 1) {
                        if (try matchAtom(atom.data, options, str[curr_slice.len..], result)) |matched_slice| {
                            curr_slice = str[0 .. matched_slice.len + curr_slice.len];
                        } else return null;
                    }

                    // 0 maximum reps means keep going on forever
                    if (range.max == 0) {
                        while (try matchAtom(atom.data, options, str[curr_slice.len..], result)) |matched_slice| {
                            curr_slice = str[0 .. matched_slice.len + curr_slice.len];
                        }
                    } else {
                        // TODO Using an inline while here crashes the compiler in codegen
                        while (curr_rep < range.max) : (curr_rep += 1) {
                            if (try matchAtom(atom.data, options, str[curr_slice.len..], result)) |matched_slice| {
                                curr_slice = str[0 .. matched_slice.len + curr_slice.len];
                            } else return curr_slice;
                        }
                    }
                    return curr_slice;
                },
            }
        },
        .concat => |concat| {
            if (try matchSubExpr(concat.lhs.*, options, str, result)) |lhs_slice| {
                if (try matchSubExpr(concat.rhs.*, options, str[lhs_slice.len..], result)) |rhs_slice| {
                    return str[0 .. lhs_slice.len + rhs_slice.len];
                }
            }
            return null;
        },
    }

    return null;
}

inline fn matchExpr(comptime expr: RegexParser.Expr, comptime options: MatchOptions, str: []const options.encoding.CharT(), result: anytype) !?@TypeOf(str) {
    const min_len = comptime expr.minLen(options.encoding);
    if (str.len < min_len) return null;

    if (try matchSubExpr(expr.lhs, options, str, result)) |lhs_slice| {
        return lhs_slice;
    }
    if (expr.rhs) |rhs| {
        if (try matchExpr(rhs.*, options, str, result)) |rhs_slice| {
            return rhs_slice;
        }
    }
    return null;
}

pub const MatchOptions = struct {
    encoding: Encoding = .utf8,
};

pub fn MatchResult(comptime regex: []const u8, comptime options: MatchOptions) type {
    const CharT = options.encoding.CharT();

    if (RegexParser.parse(regex)) |parsed| {
        const capture_len = parsed.captures.len;
        var capture_names: [capture_len]?[]const u8 = undefined;
        for (parsed.captures) |capt, idx| {
            if (capt.capture_info) |info| {
                capture_names[idx] = info.name;
            }
        }

        return struct {
            const Self = @This();

            slice: []const CharT,
            captures: [capture_len]?[]const CharT = [1]?[]const CharT{null} ** capture_len,

            inline fn resetCaptures(self: *Self) void {
                self.captures = [1]?[]const CharT{null} ** capture_len;
            }

            pub usingnamespace if (capture_len != 0)
                struct {
                    pub fn capture(self: Self, comptime name: []const u8) ?[]const CharT {
                        inline for (Self.capture_names) |maybe_name, curr_idx| {
                            if (maybe_name) |curr_name| {
                                if (comptime std.mem.eql(u8, name, curr_name))
                                    return self.captures[curr_idx];
                            }
                        }
                        @compileError("No capture named '" ++ name ++ "'");
                    }
                }
            else
                struct {};
        };
    }
    return void;
}

pub fn match(comptime regex: []const u8, comptime options: MatchOptions, str: []const options.encoding.CharT()) !?MatchResult(regex, options) {
    if (comptime RegexParser.parse(regex)) |parsed| {
        var result: MatchResult(regex, options) = .{
            .slice = undefined,
        };
        if (try matchExpr(parsed.root, options, str, &result)) |slice| {
            // TODO More than just complete matches.
            if (slice.len != str.len) return null;
            result.slice = slice;
            return result;
        }
        return null;
    }

    return {};
}

pub fn search(comptime regex: []const u8, comptime options: MatchOptions, str: []const options.encoding.CharT()) !?MatchResult(regex, options) {
    if (comptime RegexParser.parse(regex)) |parsed| {
        var result: MatchResult(regex, options) = .{
            .slice = undefined,
        };
        const min_len = comptime parsed.root.minLen(options.encoding);
        if (str.len < min_len) return null;
        // TODO Better strategy.
        var start_idx: usize = 0;
        while (start_idx <= (str.len - min_len)) : (start_idx += 1) {
            if (matchExpr(parsed.root, options, str[start_idx..], &result) catch |err| {
                if (options.encoding == .utf8 and err == error.Utf8InvalidStartByte) continue;
                if (options.encoding == .utf16le and err == error.UnexpectedSecondSurrogateHalf) continue;
                return err;
            }) |slice| {
                result.slice = slice;
                return result;
            }
            result.resetCaptures();
        }
        return null;
    }

    return {};
}

// TODO findAll, etc.
// TODO Convert to DFA when we can (otherwise some mix of DFA + DFS?)
// TODO More features, aim for PCRE compatibility
// TODO Add an ignoreUnicodeErrros option

