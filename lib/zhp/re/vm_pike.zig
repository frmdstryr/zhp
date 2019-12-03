// PikeVM
//
// This is the default engine currently except for small regexes which we use a caching backtracking
// engine as this is faster according to most other mature regex engines in practice.
//
// This is a very simple version with no optimizations.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const parse = @import("parse.zig");
const compile = @import("compile.zig");

const Parser = parse.Parser;
const Assertion = parse.Assertion;
const Program = compile.Program;
const InstructionData = compile.InstructionData;
const Input = @import("input.zig").Input;

const Thread = struct {
    pc: usize,
    // We know the maximum slot entry in advance. Therefore, we allocate the entire array as needed
    // as this is easier (and probably quicker) than allocating only what we need in an ArrayList.
    slots: []?usize,
};

const ExecState = struct {
    const Self = @This();

    arena: ArenaAllocator,
    slot_count: usize,

    pub fn init(allocator: *Allocator, program: Program) Self {
        return Self{
            .arena = ArenaAllocator.init(allocator),
            .slot_count = program.slot_count,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn newSlot(self: *Self) ![]?usize {
        var slots = try self.arena.allocator.alloc(?usize, self.slot_count);
        mem.set(?usize, slots, null);
        return slots;
    }

    pub fn cloneSlots(self: *Self, other: []?usize) ![]?usize {
        var slots = try self.arena.allocator.alloc(?usize, self.slot_count);
        mem.copy(?usize, slots, other);
        return slots;
    }
};

pub const VmPike = struct {
    const Self = @This();

    allocator: *Allocator,

    pub fn init(allocator: *Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn exec(self: *Self, prog: Program, prog_start: usize, input: *Input, slots: *ArrayList(?usize)) !bool {
        var clist = ArrayList(Thread).init(self.allocator);
        defer clist.deinit();

        var nlist = ArrayList(Thread).init(self.allocator);
        defer nlist.deinit();

        var state = ExecState.init(self.allocator, prog);
        defer state.deinit();

        const t = Thread{
            .pc = prog_start,
            .slots = try state.newSlot(),
        };
        try clist.append(t);

        var matched: ?[]?usize = null;

        while (!input.isConsumed()) : (input.advance()) {
            while (clist.popOrNull()) |thread| {
                const inst = prog.insts[thread.pc];
                const at = input.current();

                switch (inst.data) {
                    InstructionData.Char => |ch| {
                        if (at != null and at.? == ch) {
                            try nlist.append(Thread{
                                .pc = inst.out,
                                .slots = thread.slots,
                            });
                        }
                    },
                    InstructionData.EmptyMatch => |assertion| {
                        if (input.isEmptyMatch(assertion)) {
                            try clist.append(Thread{
                                .pc = inst.out,
                                .slots = thread.slots,
                            });
                        }
                    },
                    InstructionData.ByteClass => |class| {
                        if (at != null and class.contains(at.?)) {
                            try nlist.append(Thread{
                                .pc = inst.out,
                                .slots = thread.slots,
                            });
                        }
                    },
                    InstructionData.AnyCharNotNL => {
                        if (at != null and at.? != '\n') {
                            try nlist.append(Thread{
                                .pc = inst.out,
                                .slots = thread.slots,
                            });
                        }
                    },
                    InstructionData.Match => {
                        // We always will have a complete capture in the 0, 1 index
                        if (matched) |last| {
                            // leftmost
                            if (thread.slots[0].? > last[0].?) {
                                continue;
                            }
                            // longest
                            if (thread.slots[1].? - thread.slots[0].? <= last[1].? - last[0].?) {
                                continue;
                            }
                        }

                        matched = try state.cloneSlots(thread.slots);

                        // TODO: Handle thread priority correctly so we can immediately finish all
                        // current threads in clits.
                        // clist.shrink(0);
                    },
                    InstructionData.Save => |slot| {
                        // We don't need a deep copy here since we only ever advance forward so
                        // all future captures are valid for any subsequent threads.
                        var new_thread = Thread{
                            .pc = inst.out,
                            .slots = thread.slots,
                        };

                        new_thread.slots[slot] = input.byte_pos;
                        try clist.append(new_thread);
                    },
                    InstructionData.Jump => {
                        try clist.append(Thread{
                            .pc = inst.out,
                            .slots = thread.slots,
                        });
                    },
                    InstructionData.Split => |split| {
                        // Split pushed first since we want to handle the branch secondary to the
                        // current thread (popped from end).
                        try clist.append(Thread{
                            .pc = split,
                            .slots = try state.cloneSlots(thread.slots),
                        });
                        try clist.append(Thread{
                            .pc = inst.out,
                            .slots = thread.slots,
                        });
                    },
                }
            }

            mem.swap(ArrayList(Thread), &clist, &nlist);
            nlist.shrink(0);
        }

        if (matched) |ok_matched| {
            slots.shrink(0);
            try slots.appendSlice(ok_matched);
            return true;
        }

        return false;
    }
};
