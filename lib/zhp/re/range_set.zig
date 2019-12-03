// A set of ordered disconnected non-empty ranges. These are stored in a flat array as opposed
// to a tree structure. Insertions maintain order by rearranging as needed. Asymptotically
// worse than a tree range-set but given the size of the typical range-sets we work with this
// implementation is undoubtedly quicker.

const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// A single inclusive range (a, b) and a <= b
pub fn Range(comptime T: type) type {
    return struct {
        min: T,
        max: T,

        pub fn new(min: T, max: T) Range(T) {
            debug.assert(min <= max);
            return Range(T){ .min = min, .max = max };
        }

        pub fn single(item: T) Range(T) {
            return Range(T){ .min = item, .max = item };
        }
    };
}

// A contiguous set of ranges which manages merging of sub-ranges and negation of the entire class.
pub fn RangeSet(comptime T: type) type {
    return struct {
        const Self = @This();
        const RangeType = Range(T);

        // for any consecutive x, y in ranges, the following hold:
        //  - x.min <= x.max
        //  - x.max < y.min
        ranges: ArrayList(RangeType),

        pub fn init(a: *Allocator) Self {
            return Self{ .ranges = ArrayList(RangeType).init(a) };
        }

        pub fn deinit(self: *Self) void {
            self.ranges.deinit();
        }

        // Add a range into the current class, preserving the structure invariants.
        pub fn addRange(self: *Self, range: RangeType) !void {
            var ranges = &self.ranges;

            if (ranges.len == 0) {
                try ranges.append(range);
                return;
            }

            // Insert range.
            for (ranges.toSlice()) |r, i| {
                if (range.min <= r.min) {
                    try ranges.insert(i, range);
                    break;
                }
            } else {
                try ranges.append(range);
            }

            // Merge overlapping runs.
            var index: usize = 0;
            var merge = ranges.at(0);

            for (ranges.toSlice()[1..]) |r| {
                // Overlap (or directly adjacent)
                const upper = math.add(T, merge.max, 1) catch math.maxInt(T);
                if (r.min <= upper) {
                    merge.max = math.max(merge.max, r.max);
                }
                // No overlap
                else {
                    ranges.toSlice()[index] = merge;
                    merge = r;
                    index += 1;
                }
            }

            ranges.toSlice()[index] = merge;
            index += 1;
            ranges.shrink(index);
        }

        // Merge two classes into one.
        pub fn mergeClass(self: *Self, other: Self) !void {
            for (other.ranges.toSliceConst()) |r| {
                try self.addRange(r);
            }
        }

        // Inverting a class means the resulting class the contains method will match
        // the inverted set. i.e. contains(a, byte) == !contains(b, byte) if a == b.negated().
        //
        // The negation is performed in place.
        pub fn negate(self: *Self) !void {
            var ranges = &self.ranges;
            // NOTE: Append to end of array then copy and shrink.
            var negated = ArrayList(RangeType).init(self.ranges.allocator);

            if (ranges.len == 0) {
                try negated.append(RangeType.new(math.minInt(T), math.maxInt(T)));
                mem.swap(ArrayList(RangeType), ranges, &negated);
                negated.deinit();
                return;
            }

            var low: T = math.minInt(T);
            for (ranges.toSliceConst()) |r| {
                // NOTE: Can only occur on first element.
                if (r.min != math.minInt(T)) {
                    try negated.append(RangeType.new(low, r.min - 1));
                }

                low = math.add(T, r.max, 1) catch math.maxInt(T);
            }

            // Highest segment will be remaining.
            const lastRange = ranges.at(ranges.len - 1);
            if (lastRange.max != math.maxInt(T)) {
                try negated.append(RangeType.new(low, math.maxInt(T)));
            }

            mem.swap(ArrayList(RangeType), ranges, &negated);
            negated.deinit();
        }

        pub fn contains(self: Self, value: T) bool {
            // TODO: Binary search required for large unicode sets.
            for (self.ranges.toSliceConst()) |range| {
                if (range.min <= value and value <= range.max) {
                    return true;
                }
            }
            return false;
        }
    };
}

pub const ByteClassTemplates = struct {
    const ByteRange = Range(u8);
    const ByteClass = RangeSet(u8);

    pub fn Whitespace(a: *Allocator) !ByteClass {
        var rs = ByteClass.init(a);
        errdefer rs.deinit();

        // \t, \n, \v, \f, \r
        try rs.addRange(ByteRange.new('\x09', '\x0D'));
        // ' '
        try rs.addRange(ByteRange.single(' '));

        return rs;
    }

    pub fn NonWhitespace(a: *Allocator) !ByteClass {
        var rs = try Whitespace(a);
        errdefer rs.deinit();

        try rs.negate();
        return rs;
    }

    pub fn AlphaNumeric(a: *Allocator) !ByteClass {
        var rs = ByteClass.init(a);
        errdefer rs.deinit();

        try rs.addRange(ByteRange.new('0', '9'));
        try rs.addRange(ByteRange.new('A', 'Z'));
        try rs.addRange(ByteRange.new('a', 'z'));

        return rs;
    }

    pub fn NonAlphaNumeric(a: *Allocator) !ByteClass {
        var rs = try AlphaNumeric(a);
        errdefer rs.deinit();

        try rs.negate();
        return rs;
    }

    pub fn Digits(a: *Allocator) !ByteClass {
        var rs = ByteClass.init(a);
        errdefer rs.deinit();

        try rs.addRange(ByteRange.new('0', '9'));

        return rs;
    }

    pub fn NonDigits(a: *Allocator) !ByteClass {
        var rs = try Digits(a);
        errdefer rs.deinit();

        try rs.negate();
        return rs;
    }
};

var alloc = debug.global_allocator;

test "class simple" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 54));

    debug.assert(a.contains(0));
    debug.assert(a.contains(23));
    debug.assert(a.contains(54));
    debug.assert(!a.contains(58));
}

test "class simple negate" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 54));

    debug.assert(a.contains(0));
    debug.assert(a.contains(23));
    debug.assert(a.contains(54));
    debug.assert(!a.contains(58));

    try a.negate();
    // Match the negation

    debug.assert(!a.contains(0));
    debug.assert(!a.contains(23));
    debug.assert(!a.contains(54));
    debug.assert(a.contains(55));
    debug.assert(a.contains(58));

    try a.negate();
    // negate is idempotent

    debug.assert(a.contains(0));
    debug.assert(a.contains(23));
    debug.assert(a.contains(54));
    debug.assert(!a.contains(58));
}

test "class multiple" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 20));
    try a.addRange(Range(u8).new(80, 100));
    try a.addRange(Range(u8).new(230, 255));

    debug.assert(a.contains(20));
    debug.assert(!a.contains(21));
    debug.assert(!a.contains(79));
    debug.assert(a.contains(80));
    debug.assert(!a.contains(229));
    debug.assert(a.contains(230));
    debug.assert(a.contains(255));
}

test "class multiple negated" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(0, 20));
    try a.addRange(Range(u8).new(80, 100));
    try a.addRange(Range(u8).new(230, 255));

    debug.assert(a.contains(20));
    debug.assert(!a.contains(21));
    debug.assert(!a.contains(79));
    debug.assert(a.contains(80));
    debug.assert(!a.contains(229));
    debug.assert(a.contains(230));
    debug.assert(a.contains(255));

    try a.negate();

    debug.assert(!a.contains(20));
    debug.assert(a.contains(21));
    debug.assert(a.contains(79));
    debug.assert(!a.contains(80));
    debug.assert(a.contains(229));
    debug.assert(!a.contains(230));
    debug.assert(!a.contains(255));

    try a.negate();

    debug.assert(a.contains(20));
    debug.assert(!a.contains(21));
    debug.assert(!a.contains(79));
    debug.assert(a.contains(80));
    debug.assert(!a.contains(229));
    debug.assert(a.contains(230));
    debug.assert(a.contains(255));
}

test "class out of order" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(80, 100));
    try a.addRange(Range(u8).new(20, 30));

    debug.assert(a.contains(80));
    debug.assert(!a.contains(79));
    debug.assert(!a.contains(101));
    debug.assert(!a.contains(45));
    debug.assert(!a.contains(19));
}

test "class merging" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(20, 100));
    try a.addRange(Range(u8).new(50, 80));
    try a.addRange(Range(u8).new(50, 140));

    debug.assert(!a.contains(19));
    debug.assert(a.contains(20));
    debug.assert(a.contains(80));
    debug.assert(a.contains(140));
    debug.assert(!a.contains(141));
}

test "class merging boundary" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(20, 40));
    try a.addRange(Range(u8).new(40, 60));

    debug.assert(a.ranges.len == 1);
}

test "class merging adjacent" {
    var a = RangeSet(u8).init(alloc);
    try a.addRange(Range(u8).new(56, 56));
    try a.addRange(Range(u8).new(57, 57));
    try a.addRange(Range(u8).new(58, 58));

    debug.assert(a.ranges.len == 1);
}
