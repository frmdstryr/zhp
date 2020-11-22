// -------------------------------------------------------------------------- //
// Copyright (c) 2020, Jairus Martin.                                         //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const mem = std.mem;
const simd = @import("simd.zig");

const Section = struct {
    pub const Type = enum {
        Template,
        Variable,
        Content,
        Yield,
    };
    content: []const u8,
    type: Type,
    start: usize,
    end: usize,

    pub fn is(comptime self: Section, comptime name: []const u8) bool {
        return self.type == .Yield and mem.eql(u8, self.content, name);
    }

    pub fn render(comptime self: Section, context: anytype, stream: anytype) @TypeOf(stream).Error!void {
        switch (self.type) {
            .Content => {
                try stream.writeAll(self.content);
            },
            .Variable => {
                // TODO: Support arbitrary lookups
                const v =
                    if (comptime mem.eql(u8, self.content, "self"))
                        context
                    else if (comptime mem.indexOf(u8, self.content, ".")) |offset|
                        @field(@field(context, self.content[0..offset]), self.content[offset+1..])
                    else
                        @field(context, self.content);

                // TODO: Escape
                try stream.print("{}", .{v});
            },
            .Template => {
                // TODO: Support sub contexts...
                const subtemplate = @embedFile(self.content);
                try stream.writeAll(subtemplate);
            },
            .Yield => {},
        }
    }
};



pub fn parse(comptime Context: type, comptime template: []const u8) []const Section {
    @setEvalBranchQuota(100000);

    // Count number of sections this will probably be off
    comptime var max_sections: usize = 2;
    comptime {
        var vars = simd.split(template, "{{");
        while (vars.next()) |i| {max_sections += 1;}
        var blocks = simd.split(template, "{%");
        while (blocks.next()) |i| {max_sections += 1;}
    }

    // Now parse each section
    comptime var sections: [max_sections]Section = undefined;
    comptime var pos: usize = 0;
    comptime var index: usize = 0;
    while (simd.indexOfPos(u8, template, pos, "{")) |i| {
        if (i != pos) {
            // Content before
            sections[index] = Section{
                .content=template[pos..i],
                .type=.Content,
                .start=pos,
                .end=i
            };
            index += 1;
        }

        const remainder = template[i..];
        if (mem.startsWith(u8, remainder, "{{")) {
            const start = i + 2;
            if (simd.indexOfPos(u8, template, start, "}}")) |end| {
                const format = std.mem.trim(u8, template[start..end], " ");
                pos = end + 2;
                sections[index] = Section{
                    .content=format,
                    .type=.Variable,
                    .start=i,
                    .end=pos,
                };
                index += 1;
                continue;
            }
            @compileError("Incomplete variable expression");
        } else if (mem.startsWith(u8, remainder, "{%")) {
            if (mem.startsWith(u8, remainder, "{% yield ")) {
                const start = i + 9;
                if (simd.indexOfPos(u8, template, start, "%}")) |end| {
                    pos = end + 2;
                    sections[index] = Section{
                        .content = mem.trim(u8, template[start..end], " "),
                        .type = .Yield,
                        .start = i,
                        .end = pos,
                    };
                    index += 1;
                    continue;
                }
                @compileError("Incomplete yield declaration at " ++ template[i..]);
            } else if (mem.startsWith(u8, remainder, "{% include ")) {
                const start = i + 12;
                if (simd.indexOfPos(u8, template, start, "%}")) |end| {
                    pos = end + 2;
                    sections[index] = Section{
                        .content=mem.trim(u8, template[start..end], " "),
                        .type=.Template,
                        .start=i,
                        .end=pos,
                    };
                    index += 1;
                    continue;
                }
                @compileError("Incomplete include declaration");
            }
            @compileError("Incomplete template");
        } else {
            pos = i + 1;
        }
    }

    // Final section
    if (pos < template.len) {
        sections[index] = Section{
            .content=template[pos..],
            .type=.Content,
            .start=pos,
            .end=template.len,
        };
        index += 1;
    }

    return sections[0..index];
}

///
/// Generate a template that supports some what "django" like formatting
/// - Use {{ field }} or {{ field.subfield }} for varibles
/// - Use {% include 'path/to/another/template' %} to embed a template
/// - Use {% yield 'blockname' %} to return to your code to manually render stuff
pub fn Template(comptime Context: type, comptime template: []const u8) type {
    return struct {
        pub const ContextType = Context;
        pub const source = template;
        pub const sections = parse(Context, template);

        const Self = @This();

        pub fn dump() void {
            std.debug.warn("Template (length = {})\n", .{template.len});
            inline for(sections) |s| {
                std.debug.warn("{} (\"{}\")\n", .{s, template[s.start..s.end]});
            }
        }

        // Render the whole template ignoring any yield statements
        pub fn render(context: Context, stream: anytype) @TypeOf(stream).Error!void {
            inline for (sections) |s, i| {
                try s.render(context, stream);
            }
        }
    };
}


pub fn FileTemplate(comptime Context: type, comptime filename: []const u8) type {
    return Template(Context, @embedFile(filename));
}


fn expectRender(comptime T: type, context: anytype, result: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try T.render(context, stream.writer());
    std.testing.expectEqualStrings(result, stream.getWritten());
}

test "template-variable" {
    const Context = struct {
        name: []const u8,
    };
    const Tmpl = Template(Context, "Hello {{name}}!");
    try expectRender(Tmpl, .{.name="World"}, "Hello World!");
}

test "template-variable-self" {
    const Context = struct {
        name: []const u8,
    };
    const Tmpl = Template(Context, "{{self}}!");
    try expectRender(Tmpl, .{.name="World"}, "Context{ .name = World }!");
}

test "template-variable-nested" {
    const User = struct {
        name: []const u8,
    };
    const Context = struct {
        user: User,
    };
    const Tmpl = Template(Context, "Hello {{user.name}}!");
    try expectRender(Tmpl, .{.user=User{.name="World"}}, "Hello World!");
}

test "template-multiple-variables" {
    const Context = struct {
        name: []const u8,
        age: u8,
    };
    const Tmpl = Template(Context, "User {{name}} is {{age}}!");
    try expectRender(Tmpl, .{.name="Bob", .age=74}, "User Bob is 74!");
}


test "template-variables-whitespace-is-ignored" {
    const Context = struct {
        name: []const u8,
        age: u8,
    };
    const Tmpl = Template(Context, "User {{ name }} is {{  age}}!");
    try expectRender(Tmpl, .{.name="Bob", .age=74}, "User Bob is 74!");
}


test "template-yield" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = stream.writer();
    const Context = struct {
        unused: u8 = 0,
    };
    const template = Template(Context, "Before {% yield one %} after");
    const context = Context{};
    inline for (template.sections) |s| {
        if (s.is("one")) {
            try writer.writeAll("then");
        } else {
            try s.render(context, writer);
        }
    }
    std.testing.expectEqualStrings("Before then after", stream.getWritten());
}

test "template-yield-variables" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = stream.writer();
    const Context = struct {
        what: []const u8 = "base",
    };
    const template = Template(Context, "All {% yield name %} {{what}} are belong to {% yield who %}");
    //T.dump();
    const context = Context{};

    inline for (template.sections) |s| {
        if (s.is("name")) {
            try writer.writeAll("your");
        } else if (s.is("who")) {
            try writer.writeAll("us");
        } else {
            try s.render(context, writer);
        }
    }
    std.testing.expectEqualStrings("All your base are belong to us", stream.getWritten());
}
