// C-api for the regex backend.

const std = @import("std");
const cstr = std.cstr;

const regex = @import("regex.zig");
const Regex = regex.Regex;

export const zre_regex = @OpaqueType();

var allocator = std.heap.c_allocator;

export fn zre_compile(input: ?*const u8) ?*zre_regex {
    var r = allocator.create(Regex) catch return null;
    *r = Regex.compile(allocator, cstr.toSliceConst(??input)) catch return null;
    return @ptrCast(?*zre_regex, r);
}

export fn zre_match(re: ?*zre_regex, input: ?*const u8) bool {
    var r = @ptrCast(*Regex, @alignCast(4, re));
    return r.match(cstr.toSliceConst(??input)) catch return false;
}

export fn zre_partial_match(re: ?*zre_regex, input: ?*const u8) bool {
    var r = @ptrCast(*Regex, @alignCast(4, re));
    return r.partialMatch(cstr.toSliceConst(??input)) catch return false;
}

export fn zre_deinit(re: ?*zre_regex) void {
    var r = @ptrCast(*Regex, @alignCast(4, re));
    r.deinit();
}
