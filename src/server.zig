const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const http = std.http;
const log = std.log.scoped(.main);
const testing = std.testing;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    //const arena = init.arena.allocator();

    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", 4244);
    var server = try addr.listen(io, .{ .reuse_address = true });

    while (true) {
        const stream = try server.accept(io);
        _ = io.async(handle, .{ io, gpa, stream });
    }
}

fn handle(io: Io, gpa: mem.Allocator, stream: Io.net.Stream) void {
    handleFallible(io, gpa, stream) catch |err| {
        log.err("{} {}", .{ stream.socket.handle, err });
    };
}

fn handleFallible(io: Io, gpa: mem.Allocator, conn: Io.net.Stream) !void {
    defer conn.close(io);

    var read_buffer: [1024]u8 = undefined;
    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &.{});

    var http_server = http.Server.init(&reader.interface, &writer.interface);
    var request = try http_server.receiveHead();

    const target = request.head.target;
    const query_pos = std.mem.indexOfScalar(u8, target, '?');
    const device_id = target[if (target[0] == '/') 1 else 0..if (query_pos) |qp| qp else target.len];
    var from_ts: u32 = 0;
    var to_ts: u32 = std.math.maxInt(u32);

    if (query_pos) |qp| {
        var pairs = std.mem.splitSequence(u8, target[qp + 1 ..], "&");
        while (pairs.next()) |pair| {
            var parts = std.mem.splitSequence(u8, pair, "=");
            const key = parts.next() orelse continue;
            if (mem.eql(u8, key, "from")) {
                from_ts = try std.fmt.parseInt(u32, parts.next() orelse return error.MissingValue, 10);
            }
            if (mem.eql(u8, key, "to")) {
                to_ts = try std.fmt.parseInt(u32, parts.next() orelse return error.MissingValue, 10);
            }
        }
    }

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/data", .{ .iterate = true });
    defer root_dir.close(io);

    const dir = try root_dir.openDir(io, device_id, .{ .iterate = true });
    defer dir.close(io);

    var wr: Io.Writer.Allocating = .init(gpa);
    defer wr.deinit();
    const w = &wr.writer;

    const Ctx = struct {
        w: *Io.Writer,
        count: usize = 0,
        fn handle(ptr: *anyopaque, rec: Temp) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (rec.value() < 0) return;
            try self.w.print("{},{}\n", .{ rec.ts, rec.value() });
            self.count += 1;
        }
    };
    var ctx: Ctx = .{ .w = w };

    try w.print("timestamp,temperature\n", .{});
    try iterate(gpa, io, dir, from_ts, to_ts, &ctx, Ctx.handle);
    try w.flush();
    try request.respond(w.buffered(), .{});

    log.debug(
        "target: {s} count: {}",
        .{ target, ctx.count },
    );
}

const Temp = @import("sink.zig").Temp;
const Datetime = @import("state.zig").Datetime;

// http://your-api.com/data.csv?from=${__from}&to=${__to}
// ${__from:date:seconds}

fn iterate(
    gpa: mem.Allocator,
    io: Io,
    dir: Io.Dir,
    from_ts: u32,
    to_ts: u32,
    ctx: *anyopaque,
    callback: *const fn (*anyopaque, Temp) anyerror!void,
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
            const rec = Temp.parse(rdr) catch |err| switch (err) {
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

test "iterate0" {
    if (true) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/data", .{});
    defer root_dir.close(io);

    const dir = try root_dir.openDir(io, "2213142505", .{ .iterate = true });
    defer dir.close(io);

    const Ctx = struct {
        count: usize = 0,
        fn handle(ptr: *anyopaque, rec: Temp) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = rec;
            self.count += 1;
        }
    };

    var ctx: Ctx = .{};
    try iterate(gpa, io, dir, 1783448708, 1883436665, &ctx, Ctx.handle);
    try testing.expectEqual(41490, ctx.count);
}

test "iterate" {
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
    try iterate(gpa, io, tmp.dir, 0, 100, &ctx, Ctx.handle);
    try testing.expectEqual(100, ctx.count);
    try testing.expectEqual(1, ctx.min_ts);
    try testing.expectEqual(100, ctx.max_ts);

    ctx = .{};
    try iterate(gpa, io, tmp.dir, 55, 74, &ctx, Ctx.handle);
    try testing.expectEqual(20, ctx.count);
    try testing.expectEqual(55, ctx.min_ts);
    try testing.expectEqual(74, ctx.max_ts);

    ctx = .{};
    try iterate(gpa, io, tmp.dir, 95, 100, &ctx, Ctx.handle);
    try testing.expectEqual(6, ctx.count);
    try testing.expectEqual(95, ctx.min_ts);
    try testing.expectEqual(100, ctx.max_ts);
}

// .rw-r--r-- 158k ianic 10 Jul 18:01 󰡯 1783436665
// .rw-r--r--  88k ianic 10 Jul 18:01 󰡯 1783448708
// .rw-r--r-- 173k ianic 10 Jul 18:01 󰡯 1783449276

// 173394 /home/ianic/data/2213142505/1783449276
//     158286 /home/ianic/data/2213142505/1783436665
//     87858 /home/ianic/data/2213142505/1783448708
