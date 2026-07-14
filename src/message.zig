const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const log = std.log.scoped(.msg);

pub const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const Temp = struct {
    ts: u32,
    temp: u16,

    pub const bytes = 6;
    pub const empty: Temp = .{ .ts = 0, .temp = 0 };
    const sign_mask: u16 = 0xf800;

    pub fn parse(r: *Io.Reader) !Temp {
        const ts = try r.takeInt(u32, .little);
        const temp = try r.takeInt(u16, .little);
        return .{ .ts = ts, .temp = temp };
    }

    pub fn encode(self: Temp, w: *Io.Writer) !void {
        try w.writeInt(u32, self.ts, .little);
        try w.writeInt(u16, self.temp, .little);
    }

    pub fn celsius(self: Temp) f64 {
        return @as(f64, @floatFromInt(self.value())) / 16;
    }

    pub fn value(self: Temp) i16 {
        const neg = self.temp & sign_mask == sign_mask;
        const sign: i16 = if (neg) -1 else 1;
        return @as(i16, @intCast(self.temp & ~sign_mask)) * sign;
    }

    pub fn equal(a: Temp, b: Temp) bool {
        return @abs(a.value() - b.value()) <= 1;
    }

    test "negative" {
        const n1 = 0b11111_11100100000;
        try testing.expectEqual(-0b11100100000 / 16, (Temp{ .ts = 0, .temp = n1 }).celsius());
    }

    test equal {
        const cases: []const struct { a: u16, b: u16, eql: bool } = &.{
            .{ .a = 16, .b = 16, .eql = true },
            .{ .a = 16, .b = 15, .eql = true },
            .{ .a = 16, .b = 17, .eql = true },
            .{ .a = 16, .b = 14, .eql = false },
            .{ .a = 16, .b = 18, .eql = false },

            .{ .a = 16 | sign_mask, .b = 16 | sign_mask, .eql = true },
            .{ .a = 16 | sign_mask, .b = 15 | sign_mask, .eql = true },
            .{ .a = 16 | sign_mask, .b = 17 | sign_mask, .eql = true },
            .{ .a = 16 | sign_mask, .b = 14 | sign_mask, .eql = false },
            .{ .a = 16 | sign_mask, .b = 18 | sign_mask, .eql = false },

            .{ .a = 16 | sign_mask, .b = 16, .eql = false },
            .{ .a = 16, .b = 16 | sign_mask, .eql = false },

            .{ .a = 0, .b = 1, .eql = true },
            .{ .a = 0, .b = 2 | sign_mask, .eql = false },
            .{ .a = 0, .b = 1 | sign_mask, .eql = true },
        };
        for (cases) |c| {
            const a: Temp = .{ .temp = c.a, .ts = 0 };
            const b: Temp = .{ .temp = c.b, .ts = 0 };
            try testing.expect(a.equal(b) == c.eql);
        }
    }
};

pub const Type = enum(u8) {
    temperature_reading = 0xaa,
};

pub const Header = struct {
    const Flags = packed struct {
        state: bool = false,
        _: u7 = 0,
    };

    device_id: u48,
    message_type: Type,
    flags: Flags = .{},
    session_id: u32,

    pub fn parse(rdr: *Io.Reader) !Header {
        const device_id = try rdr.takeInt(u48, .little);
        const message_type = std.enums.fromInt(Type, try rdr.takeByte()) orelse return error.InvalidMessageType;
        const flags: Flags = @bitCast(try rdr.takeByte());
        const session_id = try rdr.takeInt(u32, .little);

        return .{
            .device_id = device_id,
            .message_type = message_type,
            .flags = flags,
            .session_id = session_id,
        };
    }

    pub fn encode(self: Header, w: *Io.Writer) !void {
        try w.writeInt(u48, self.device_id, .little);
        try w.writeByte(@intFromEnum(self.message_type));
        try w.writeByte(@bitCast(self.flags));
        try w.writeInt(u32, self.session_id, .little);
    }

    test {
        const mac: [6]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
        const device_id: u48 = mem.readInt(u48, &mac, .big);

        const h: Header = .{
            .device_id = device_id,
            .message_type = .temperature_reading,
            .session_id = 0x77889900,
            .flags = .{ .state = true },
        };

        var buf: [12]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        try h.encode(&w);

        var r = Io.Reader.fixed(&buf);
        const h2 = try Header.parse(&r);
        try testing.expectEqualDeep(h, h2);

        // change message type byte
        buf[6] = 0xff;
        //std.debug.print("{x}", .{buf});
        r = Io.Reader.fixed(&buf);
        try testing.expectError(error.InvalidMessageType, Header.parse(&r));
    }
};

test {
    _ = Temp;
    _ = Header;
}

pub fn iterate(
    comptime T: type,
    gpa: mem.Allocator,
    io: Io,
    dir: Io.Dir,
    from_ts: u32,
    to_ts: u32,
    ctx: *anyopaque,
    callback: *const fn (*anyopaque, T) anyerror!void,
) !void {
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var files: std.ArrayList(u32) = .empty;
    defer files.deinit(gpa);
    while (try walker.next(io)) |entry| {
        if (!(entry.kind == .file and entry.depth() == 1)) continue;
        if (std.ascii.endsWithIgnoreCase(entry.basename, ".csv")) continue;

        const ts = std.fmt.parseInt(u32, entry.basename, 10) catch |err| {
            log.err("filed to parse {s} as timestamp {}", .{ entry.basename, err });
            continue;
        };

        try files.append(gpa, ts);
    }
    std.mem.sort(u32, files.items, {}, std.sort.asc(u32));

    for (files.items, 0..) |data_file_ts, idx| {
        if (data_file_ts < from_ts) {
            if (idx < files.items.len - 1) {
                if (files.items[idx + 1] < from_ts) continue;
            }
        }
        if (data_file_ts > to_ts) break;

        //std.debug.print("opening file: {} {} {}\n", .{ data_file_ts, from_ts, to_ts });

        const data_file_name = try std.fmt.allocPrint(gpa, "{:0>10}", .{data_file_ts});
        defer gpa.free(data_file_name);
        const data_file = try dir.openFile(io, data_file_name, .{});
        defer data_file.close(io);

        var reader_buf: [4096]u8 = undefined;
        var fr = data_file.reader(io, &reader_buf);
        const rdr = &fr.interface;

        while (true) {
            const rec = T.parse(rdr) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            //if (rec.value() < 0) continue;
            if (rec.ts < from_ts) continue;
            if (rec.ts > to_ts) break;
            try callback(ctx, rec);
        }
    }
}

test iterate {
    const io = testing.io;
    const gpa = testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var ts: u32 = 1;
    for (0..10) |_| {
        var buf: [10]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&buf, "{:0>10}", .{ts});

        const file = try tmp.dir.createFile(io, file_name, .{});
        defer file.close(io);
        var write_buf: [64]u8 = undefined;
        var fw = file.writer(io, &write_buf);
        const w = &fw.interface;

        for (0..10) |_| {
            const rec: Temp = .{ .ts = ts, .temp = 0 };
            try rec.encode(w);
            ts += 1;
        }
        try w.flush();
    }

    const Ctx = struct {
        count: usize = 0,
        min_ts: u32 = std.math.maxInt(u32),
        max_ts: u32 = 0,
        fn handle(ptr: *anyopaque, rec: Temp) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.min_ts = @min(rec.ts, self.min_ts);
            self.max_ts = @max(rec.ts, self.max_ts);
            self.count += 1;
        }
    };

    var ctx: Ctx = .{};
    try iterate(Temp, gpa, io, tmp.dir, 0, 100, &ctx, Ctx.handle);
    try testing.expectEqual(100, ctx.count);
    try testing.expectEqual(1, ctx.min_ts);
    try testing.expectEqual(100, ctx.max_ts);

    ctx = .{};
    try iterate(Temp, gpa, io, tmp.dir, 55, 74, &ctx, Ctx.handle);
    try testing.expectEqual(20, ctx.count);
    try testing.expectEqual(55, ctx.min_ts);
    try testing.expectEqual(74, ctx.max_ts);

    ctx = .{};
    try iterate(Temp, gpa, io, tmp.dir, 95, 100, &ctx, Ctx.handle);
    try testing.expectEqual(6, ctx.count);
    try testing.expectEqual(95, ctx.min_ts);
    try testing.expectEqual(100, ctx.max_ts);
}
