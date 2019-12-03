const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const compile = @import("compile.zig");
const Program = compile.Program;

const VmBacktrack = @import("vm_backtrack.zig").VmBacktrack;
const VmPike = @import("vm_pike.zig").VmPike;
const Input = @import("input.zig").Input;

pub fn exec(allocator: *Allocator, prog: Program, prog_start: usize, input: *Input, slots: *ArrayList(?usize)) !bool {
    if (VmBacktrack.shouldExec(prog, input)) {
        var engine = VmBacktrack.init(allocator);
        return engine.exec(prog, prog_start, input, slots);
    } else {
        var engine = VmPike.init(allocator);
        return engine.exec(prog, prog_start, input, slots);
    }
}
