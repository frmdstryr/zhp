const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;

const parser = @import("parse.zig");
const Parser = parser.Parser;
const ByteClass = parser.ByteClass;
const Expr = parser.Expr;
const Assertion = parser.Assertion;

pub const InstructionData = union(enum) {
    // Match the specified character.
    Char: u8,
    // Match the specified character ranges.
    ByteClass: ByteClass,
    // Matches the AnyChar special cases
    AnyCharNotNL,
    // Empty match (\w assertion)
    EmptyMatch: Assertion,
    // Stop the thread, found a match
    Match,
    // Jump to the instruction at address x
    Jump,
    // Split execution, spawing a new thread and continuing in lockstep
    Split: usize,
    // Slot to save position in
    Save: usize,
};

// Represents instructions for the VM.
pub const Instruction = struct {
    // Next instruction to execute
    out: usize,
    // Associated data with this
    data: InstructionData,

    pub fn new(out: usize, data: InstructionData) Instruction {
        return Instruction{
            .out = out,
            .data = data,
        };
    }
};

// Represents an instruction with unpatched holes.
const InstHole = union(enum) {
    // Match with an unfilled output
    Char: u8,
    // Match a character class range
    ByteClass: ByteClass,
    // Empty Match assertion
    EmptyMatch: Assertion,
    // Match any character
    AnyCharNotNL,
    // Split with no unfilled branch
    Split,
    // Split with a filled first branch
    Split1: usize,
    // Split with a filled second branch
    Split2: usize,
    // Save capture
    Save: usize,
};

// Represents a partial instruction. During compilation the instructions will be a mix of compiled
// and un-compiled. All instructions must be in the compiled state when we finish processing.
const PartialInst = union(enum) {
    // A completely compiled instruction
    Compiled: Instruction,

    // A partially compiled instruction, the back-links are not yet filled
    Uncompiled: InstHole,

    // Modify the current instruction to point to the specified instruction.
    pub fn fill(s: *PartialInst, i: usize) void {
        switch (s.*) {
            PartialInst.Uncompiled => |ih| {
                var comp: Instruction = undefined;

                // Generate the corresponding compiled instruction. All simply goto the specified
                // instruction, except for the dual split case, in which both outgoing pointers
                // go to the same place.
                const compiled = switch (ih) {
                    InstHole.Char => |ch| Instruction.new(i, InstructionData{ .Char = ch }),

                    InstHole.EmptyMatch => |assertion| Instruction.new(i, InstructionData{ .EmptyMatch = assertion }),

                    InstHole.AnyCharNotNL => Instruction.new(i, InstructionData.AnyCharNotNL),

                    InstHole.ByteClass => |class| Instruction.new(i, InstructionData{ .ByteClass = class }),

                    InstHole.Split =>
                    // If we both point to the same output, we can encode as a jump
                    Instruction.new(i, InstructionData.Jump),

                    // 1st was already filled
                    InstHole.Split1 => |split| Instruction.new(split, InstructionData{ .Split = i }),

                    // 2nd was already filled
                    InstHole.Split2 => |split| Instruction.new(i, InstructionData{ .Split = split }),

                    InstHole.Save => |slot| Instruction.new(i, InstructionData{ .Save = slot }),
                };

                s.* = PartialInst{ .Compiled = compiled };
            },
            PartialInst.Compiled => {
                // nothing to do, already filled
            },
        }
    }
};

// A program represents the compiled bytecode of an NFA.
pub const Program = struct {
    // Sequence of instructions representing an NFA
    insts: []const Instruction,
    // Start instruction
    start: usize,
    // Find Start instruction
    find_start: usize,
    // Max number of slots required
    slot_count: usize,
    // Allocator which owns the instructions
    allocator: *Allocator,

    pub fn init(allocator: *Allocator, a: []const Instruction, find_start: usize, slot_count: usize) Program {
        return Program{
            .allocator = allocator,
            .insts = a,
            .start = 0,
            .find_start = find_start,
            .slot_count = slot_count,
        };
    }

    pub fn deinit(p: *Program) void {
        p.allocator.free(p.insts);
    }
};

// A Hole represents the outgoing node of a partially compiled Fragment.
//
// If None, the Hole needs to be back-patched as we do not yet know which instruction this
// points to yet.
const Hole = union(enum) {
    None,
    One: usize,
    Many: ArrayList(Hole),
};

// A patch represents an unpatched output for a contigious sequence of instructions.
const Patch = struct {
    // The address of the first instruction
    entry: usize,
    // The output hole of this instruction (to be filled to an actual address/es)
    hole: Hole,
};

// A Compiler compiles a regex expression into a bytecode representation of the NFA.
pub const Compiler = struct {
    // Stores all partial instructions
    insts: ArrayList(PartialInst),
    allocator: *Allocator,
    // Capture state
    capture_index: usize,

    pub fn init(a: *Allocator) Compiler {
        return Compiler{
            .insts = ArrayList(PartialInst).init(a),
            .allocator = a,
            .capture_index = 0,
        };
    }

    pub fn deinit(c: *Compiler) void {
        c.insts.deinit();
    }

    fn nextCaptureIndex(c: *Compiler) usize {
        const s = c.capture_index;
        c.capture_index += 2;
        return s;
    }

    // Compile the regex expression
    pub fn compile(c: *Compiler, expr: *const Expr) !Program {
        // surround in a full program match
        const entry = c.insts.len;
        const index = c.nextCaptureIndex();
        try c.pushCompiled(Instruction.new(entry + 1, InstructionData{ .Save = index }));

        // compile the main expression
        const patch = try c.compileInternal(expr);

        // not iterating over an empty correctly in backtrack
        c.fillToNext(patch.hole);
        const h = try c.pushHole(InstHole{ .Save = index + 1 });

        // fill any holes to end at the next instruction which will be a match
        c.fillToNext(h);
        try c.pushCompiled(Instruction.new(0, InstructionData.Match));

        var p = ArrayList(Instruction).init(c.allocator);
        defer p.deinit();

        for (c.insts.toSliceConst()) |e| {
            switch (e) {
                PartialInst.Compiled => |x| {
                    try p.append(x);
                },
                else => |inner| {
                    @panic("uncompiled instruction encountered during compilation");
                },
            }
        }

        // To facilitate fast finding (matching non-anchored to the start) we simply append a
        // .*? to the start of our instructions. We push the fragment with this set of instructions
        // at the end of the compiled set. We perform an anchored search by entering normally and
        // a non-anchored by jumping to this patch before starting.
        //
        // 1: compiled instructions
        // 2: match
        // ... # We add the following
        // 3: split 1, 4
        // 4: any 3
        const fragment_start = c.insts.len;
        const fragment = [_]Instruction{
            Instruction.new(0, InstructionData{ .Split = fragment_start + 1 }),
            Instruction.new(fragment_start, InstructionData.AnyCharNotNL),
        };
        try p.appendSlice(&fragment);

        return Program.init(p.allocator, p.toOwnedSlice(), fragment_start, c.capture_index);
    }

    fn compileInternal(c: *Compiler, expr: *const Expr) Allocator.Error!Patch {
        switch (expr.*) {
            Expr.Literal => |lit| {
                const h = try c.pushHole(InstHole{ .Char = lit });
                return Patch{ .hole = h, .entry = c.insts.len - 1 };
            },
            Expr.ByteClass => |classes| {
                // Similar, we use a special instruction.
                const h = try c.pushHole(InstHole{ .ByteClass = classes });
                return Patch{ .hole = h, .entry = c.insts.len - 1 };
            },
            Expr.AnyCharNotNL => {
                const h = try c.pushHole(InstHole.AnyCharNotNL);
                return Patch{ .hole = h, .entry = c.insts.len - 1 };
            },
            Expr.EmptyMatch => |assertion| {
                const h = try c.pushHole(InstHole{ .EmptyMatch = assertion });
                return Patch{ .hole = h, .entry = c.insts.len - 1 };
            },
            Expr.Repeat => |repeat| {
                // Case 1: *
                if (repeat.min == 0 and repeat.max == null) {
                    return c.compileStar(repeat.subexpr, repeat.greedy);
                }
                // Case 2: +
                else if (repeat.min == 1 and repeat.max == null) {
                    return c.compilePlus(repeat.subexpr, repeat.greedy);
                }
                // Case 3: ?
                else if (repeat.min == 0 and repeat.max != null and repeat.max.? == 1) {
                    return c.compileQuestion(repeat.subexpr, repeat.greedy);
                }
                // Case 4: {m,}
                else if (repeat.max == null) {
                    // e{2,} => eee*

                    // fixed min concatenation
                    const p = try c.compileInternal(repeat.subexpr);
                    var hole = p.hole;
                    const entry = p.entry;

                    var i: usize = 0;
                    while (i < repeat.min) : (i += 1) {
                        const ep = try c.compileInternal(repeat.subexpr);
                        c.fill(hole, ep.entry);
                        hole = ep.hole;
                    }

                    // add final e* infinite capture
                    const st = try c.compileStar(repeat.subexpr, repeat.greedy);
                    c.fill(hole, st.entry);

                    return Patch{ .hole = st.hole, .entry = entry };
                }
                // Case 5: {m,n} and {m}
                else {
                    // e{3,6} => eee?e?e?e?
                    const p = try c.compileInternal(repeat.subexpr);
                    var hole = p.hole;
                    const entry = p.entry;

                    var i: usize = 1;
                    while (i < repeat.min) : (i += 1) {
                        const ep = try c.compileInternal(repeat.subexpr);
                        c.fill(hole, ep.entry);
                        hole = ep.hole;
                    }

                    // repeated optional concatenations
                    while (i < repeat.max.?) : (i += 1) {
                        const ep = try c.compileQuestion(repeat.subexpr, repeat.greedy);
                        c.fill(hole, ep.entry);
                        hole = ep.hole;
                    }

                    return Patch{ .hole = hole, .entry = entry };
                }
            },
            Expr.Concat => |subexprs| {
                // Compile each item in the sub-expression
                var f = subexprs.toSliceConst()[0];

                // First patch
                const p = try c.compileInternal(f);
                var hole = p.hole;
                const entry = p.entry;

                // tie together patches from concat arguments
                for (subexprs.toSliceConst()[1..]) |e| {
                    const ep = try c.compileInternal(e);
                    // fill the previous patch hole to the current entry
                    c.fill(hole, ep.entry);
                    // current hole is now the next fragment
                    hole = ep.hole;
                }

                return Patch{ .hole = hole, .entry = entry };
            },
            Expr.Capture => |subexpr| {
                // 1: save 1, 2
                // 2: subexpr
                // 3: restore 1, 4
                // ...

                // Create a partial instruction with a hole outgoing at the current location.
                const entry = c.insts.len;

                const index = c.nextCaptureIndex();

                try c.pushCompiled(Instruction.new(entry + 1, InstructionData{ .Save = index }));
                const p = try c.compileInternal(subexpr);
                c.fillToNext(p.hole);

                const h = try c.pushHole(InstHole{ .Save = index + 1 });

                return Patch{ .hole = h, .entry = entry };
            },
            Expr.Alternate => |subexprs| {
                // Alternation with one path does not make sense
                debug.assert(subexprs.len >= 2);

                // Alternates are simply a series of splits into the sub-expressions, with each
                // subexpr having the same output hole (after the final subexpr).
                //
                // 1: split 2, 4
                // 2: subexpr1
                // 3: jmp 8
                // 4: split 5, 7
                // 5: subexpr2
                // 6: jmp 8
                // 7: subexpr3
                // 8: ...

                const entry = c.insts.len;
                var holes = ArrayList(Hole).init(c.allocator);
                errdefer holes.deinit();

                // TODO: Doees this need to be dynamically allocated?
                var last_hole = try c.allocator.create(Hole);
                defer c.allocator.destroy(last_hole);

                // This compiles one branch of the split at a time.
                for (subexprs.toSliceConst()[0 .. subexprs.len - 1]) |subexpr| {
                    c.fillToNext(last_hole.*);

                    // next entry will be a sub-expression
                    //
                    // We fill the second part of this hole on the next sub-expression.
                    last_hole.* = try c.pushHole(InstHole{ .Split1 = c.insts.len + 1 });

                    // compile the subexpression
                    const p = try c.compileInternal(subexpr);

                    // store outgoing hole for the subexpression
                    try holes.append(p.hole);
                }

                // one entry left, push a sub-expression so we end with a double-subexpression.
                const p = try c.compileInternal(subexprs.toSliceConst()[subexprs.len - 1]);
                c.fill(last_hole.*, p.entry);

                // push the last sub-expression hole
                try holes.append(p.hole);

                // return many holes which are all to be filled to the next instruction
                return Patch{ .hole = Hole{ .Many = holes }, .entry = entry };
            },
            Expr.PseudoLeftParen => {
                @panic("internal error, encountered PseudoLeftParen");
            },
        }

        return Patch{ .hole = Hole.None, .entry = c.insts.len };
    }

    fn compileStar(c: *Compiler, expr: *Expr, greedy: bool) !Patch {
        // 1: split 2, 4
        // 2: subexpr
        // 3: jmp 1
        // 4: ...

        // We do not know where the second branch in this split will go (unsure yet of
        // the length of the following subexpr. Need a hole.

        // Create a partial instruction with a hole outgoing at the current location.
        const entry = c.insts.len;

        // * or *? variant, simply switch the branches, the matcher manages precedence
        // of the executing threads.
        const partial_inst = if (greedy)
            InstHole{ .Split1 = c.insts.len + 1 }
        else
            InstHole{ .Split2 = c.insts.len + 1 };

        const h = try c.pushHole(partial_inst);

        // compile the subexpression
        const p = try c.compileInternal(expr);

        // sub-expression to jump
        c.fillToNext(p.hole);

        // Jump back to the entry split
        try c.pushCompiled(Instruction.new(entry, InstructionData.Jump));

        // Return a filled patch set to the first split instruction.
        return Patch{ .hole = h, .entry = entry };
    }

    fn compilePlus(c: *Compiler, expr: *Expr, greedy: bool) !Patch {
        // 1: subexpr
        // 2: split 1, 3
        // 3: ...
        //
        // NOTE: We can do a lookahead on non-greedy here to improve performance.
        const p = try c.compileInternal(expr);

        // Create the next expression in place
        c.fillToNext(p.hole);

        // split 3, 1 (non-greedy)
        // Point back to the upcoming next instruction (will always be filled).
        const partial_inst = if (greedy)
            InstHole{ .Split1 = p.entry }
        else
            InstHole{ .Split2 = p.entry };

        const h = try c.pushHole(partial_inst);

        // split to the next instruction
        return Patch{ .hole = h, .entry = p.entry };
    }

    fn compileQuestion(c: *Compiler, expr: *Expr, greedy: bool) !Patch {
        // 1: split 2, 3

        // 2: subexpr
        // 3: ...

        // Create a partial instruction with a hole outgoing at the current location.
        const partial_inst = if (greedy)
            InstHole{ .Split1 = c.insts.len + 1 }
        else
            InstHole{ .Split2 = c.insts.len + 1 };

        const h = try c.pushHole(partial_inst);

        // compile the subexpression
        const p = try c.compileInternal(expr);

        var holes = ArrayList(Hole).init(c.allocator);
        errdefer holes.deinit();
        try holes.append(h);
        try holes.append(p.hole);

        // Return a filled patch set to the first split instruction.
        return Patch{ .hole = Hole{ .Many = holes }, .entry = p.entry - 1 };
    }

    // Push a compiled instruction directly onto the stack.
    fn pushCompiled(c: *Compiler, i: Instruction) !void {
        try c.insts.append(PartialInst{ .Compiled = i });
    }

    // Push a instruction with a hole onto the set
    fn pushHole(c: *Compiler, i: InstHole) !Hole {
        const h = c.insts.len;
        try c.insts.append(PartialInst{ .Uncompiled = i });
        return Hole{ .One = h };
    }

    // Patch an individual hole with the specified output address.
    fn fill(c: *Compiler, hole: Hole, goto1: usize) void {
        switch (hole) {
            Hole.None => {},
            Hole.One => |pc| c.insts.toSlice()[pc].fill(goto1),
            Hole.Many => |holes| {
                for (holes.toSliceConst()) |hole1|
                    c.fill(hole1, goto1);
            },
        }
    }

    // Patch a hole to point to the next instruction
    fn fillToNext(c: *Compiler, hole: Hole) void {
        c.fill(hole, c.insts.len);
    }
};
