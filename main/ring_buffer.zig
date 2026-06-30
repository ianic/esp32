const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        head: usize,
        sequence: usize = 0,

        pub fn init(items: []T) Self {
            return .{
                .items = items,
                .head = items.len - 1,
                .sequence = 0,
            };
        }

        pub fn add(self: *Self, t: T) void {
            const idx = self.next();
            self.items[idx] = t;
            self.head = idx;
            self.sequence += 1;
        }

        pub fn last(self: *Self) ?T {
            if (self.sequence == 0) return null;
            return self.items[self.head];
        }

        pub fn first(self: *Self) ?T {
            if (self.tail()) |idx| {
                return self.items[idx];
            }
            return null;
        }

        // Minimum and maximum sequence in the buffer.
        // Range is inclusive.
        pub fn sequenceRange(self: *Self) struct { usize, usize } {
            if (self.sequence == 0) return .{ 0, 0 };
            if (self.sequence <= self.items.len) return .{ 1, self.sequence };
            return .{ self.sequence - self.items.len + 1, self.sequence };
        }

        pub fn count(self: *Self) usize {
            if (self.sequence == 0) return 0;
            if (self.sequence < self.items.len) return self.sequence;
            return self.items.len;
        }

        fn next(self: *Self) usize {
            return (self.head + 1) % self.items.len;
        }

        fn tail(self: *Self) ?usize {
            if (self.sequence == 0) return null;
            if (self.sequence <= self.items.len) return 0;
            return (self.head + 1) % self.items.len;
        }

        fn content(self: *Self) struct { []T, []T } {
            if (self.sequence < self.items.len) return .{ self.items[0..self.sequence], &.{} };
            return .{ self.items[self.head + 1 ..], self.items[0 .. self.head + 1] };
        }

        /// Backward iterator
        pub fn iterator(self: *Self) Iterator {
            const ls, const rs = self.content();
            return .{
                .s1 = ls,
                .s2 = rs,
            };
        }

        pub const Iterator = struct {
            s1: []T,
            s2: []T,

            pub fn next(itr: *Iterator) ?T {
                if (itr.s2.len == 0 and itr.s1.len == 0) {
                    return null;
                }
                if (itr.s2.len > 0) {
                    const value, itr.s2 = right(itr.s2);
                    return value;
                }
                const value, itr.s1 = right(itr.s1);
                return value;
            }

            fn right(slice: []T) struct { T, []T } {
                const i = slice.len - 1;
                return .{ slice[i], slice[0..i] };
            }
        };
    };
}

test RingBuffer {
    const T = struct {
        ts: u32 = 0,
    };
    var buf: [8]T = undefined;
    var cb: RingBuffer(T) = .init(&buf);

    try testing.expectEqual(null, cb.tail());
    var s1, var s2 = cb.content();
    try testing.expectEqual(0, s1.len);
    try testing.expectEqual(0, s2.len);

    for (1..8) |i| {
        cb.add(.{ .ts = @intCast(i) });
        try testing.expectEqual(cb.head, i - 1);
        try testing.expectEqual(i, cb.sequence);
        try testing.expectEqual(0, cb.tail().?);
        const min_seq, const seq = cb.sequenceRange();
        try testing.expectEqual(1, min_seq);
        try testing.expectEqual(i, seq);
    }

    // slices s1: 1,2,3,4,5,6,7
    s1, s2 = cb.content();
    try testing.expectEqual(7, s1.len);
    try testing.expectEqual(0, s2.len);
    for (s1, 1..) |v, i| {
        try testing.expectEqual(i, v.ts);
    }
    try testing.expectEqual(7, cb.count());

    // backward iterator 7,6,5,4,3,2,1
    {
        var i: usize = 7;
        var iter = cb.iterator();
        while (iter.next()) |v| {
            try testing.expectEqual(i, v.ts);
            i -= 1;
        }
    }

    cb.add(.{ .ts = 8 });
    try testing.expectEqual(8, cb.count());
    {
        const min_seq, const seq = cb.sequenceRange();
        try testing.expectEqual(1, min_seq);
        try testing.expectEqual(8, seq);
    }
    cb.add(.{ .ts = 9 });
    try testing.expectEqual(8, cb.count());
    {
        const min_seq, const seq = cb.sequenceRange();
        try testing.expectEqual(2, min_seq);
        try testing.expectEqual(9, seq);
    }

    for (10..13) |i| {
        cb.add(.{ .ts = @intCast(i) });
        const min_seq, const seq = cb.sequenceRange();
        try testing.expectEqual(i - 7, min_seq);
        try testing.expectEqual(i, seq);
    }
    try testing.expectEqual(8, cb.count());

    // slice s1: 5,6,7,8
    // slice s2: 9,10,11,12
    s1, s2 = cb.content();
    {
        try testing.expectEqual(4, s1.len);
        try testing.expectEqual(4, s2.len);
        for (s1, 5..) |v, i| {
            try testing.expectEqual(i, v.ts);
        }
        for (s2, 9..) |v, i| {
            try testing.expectEqual(i, v.ts);
        }
    }

    cb.add(.{ .ts = 13 });
    try testing.expectEqual(13, cb.sequence);

    // s1: 6,7,8
    // s2: 9,10,11,12,13
    s1, s2 = cb.content();
    {
        try testing.expectEqual(3, s1.len);
        try testing.expectEqual(5, s2.len);
        for (s1, 6..) |v, i| {
            try testing.expectEqual(i, v.ts);
        }
        for (s2, 9..) |v, i| {
            try testing.expectEqual(i, v.ts);
        }
    }

    // iterator: 13,12,11,10,9,8,7,6
    {
        var i: usize = 13;
        var iter = cb.iterator();
        while (iter.next()) |v| {
            try testing.expectEqual(i, v.ts);
            i -= 1;
            //std.debug.print("{}\n", .{v});
        }
    }
    try testing.expectEqual(8, cb.count());
}

const Reading = packed struct {
    ts: u32,
    temp: u16,
};

test "size" {
    std.debug.print("reading size {}\n", .{@sizeOf(Reading)});
    std.debug.print("reading ring buffer size {}\n", .{@sizeOf(RingBuffer(Reading))});
}
