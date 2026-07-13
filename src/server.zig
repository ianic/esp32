const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const http = std.http;
const log = std.log.scoped(.main);
const assert = std.debug.assert;
const testing = std.testing;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/data", .{ .iterate = true });
    defer root_dir.close(io);

    var server_future = io.async(httpServer, .{ io, gpa, root_dir });
    _ = io.async(udpSink, .{ io, root_dir });
    try server_future.await(io);
}

fn httpServer(io: Io, gpa: mem.Allocator, root_dir: Io.Dir) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", 4244);
    var server = try addr.listen(io, .{ .reuse_address = true });

    while (true) {
        const conn = try server.accept(io);
        _ = io.async(onConnect, .{ io, gpa, conn, root_dir });
    }
}

fn onConnect(io: Io, gpa: mem.Allocator, conn: Io.net.Stream, root_dir: Io.Dir) void {
    onConnect_(io, gpa, conn, root_dir) catch |err| {
        log.err("http connection failed {s}", .{@errorName(err)});
    };
}

fn onConnect_(io: Io, gpa: mem.Allocator, conn: Io.net.Stream, root_dir: Io.Dir) !void {
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

fn udpSink(io: Io, root_dir: Io.Dir) !void {
    const listen_addr = try std.Io.net.IpAddress.parse("0.0.0.0", 4242);
    const socket = try listen_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);
    try joinMcast(socket.handle, try std.Io.net.IpAddress.parse("224.0.0.1", 0));

    var packet_buf: [65536]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    while (true) {
        const packet = try socket.receive(io, &packet_buf);
        var fr = std.Io.Reader.fixed(packet.data);
        var rdr = &fr;

        const header = try Header.parse(rdr);
        const file = try open(io, root_dir, header);
        defer file.close(io);
        const last_rec = try lastRec(Temp, io, file);
        var fw = file.writer(io, &write_buf);
        try fw.seekTo(try file.length(io));
        const w = &fw.interface;

        // If there is continuation, previous record is found in update packet
        var can_append = false;
        var appended_records: usize = 0;
        var state_records: usize = 0;
        var last: Temp = .empty;
        if (last_rec) |lr| {
            const count = try rdr.takeInt(u16, .little);
            for (0..count) |_| {
                const rec = try Temp.parse(rdr);
                if (can_append) {
                    try rec.encode(w);
                    appended_records += 1;
                    last = rec;
                } else if (rec.ts == lr.ts)
                    can_append = true;
            }
        }
        if (!can_append) {
            var addr = packet.from;
            addr.setPort(4243);
            const conn = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer conn.close(io);
            var soc_rdr = conn.reader(io, &packet_buf);
            rdr = &soc_rdr.interface;

            const state_header = try Header.parse(rdr);
            assert(state_header.device_id == header.device_id);
            if (state_header.session_id != header.session_id) continue;

            const count = try rdr.takeInt(u16, .little);
            for (0..count) |i| {
                const rec = try Temp.parse(rdr);
                if (i == 0) if (last_rec) |lr| if (rec.ts > lr.ts) {
                    // If there is gap between last and new state add empty record
                    try Temp.empty.encode(w);
                };
                if (last_rec == null or rec.ts > last_rec.?.ts) {
                    try rec.encode(w);
                    last = rec;
                    state_records += 1;
                }
            }
        }
        try fw.flush();

        log.debug(
            "{d}/{d}, records: {d}, last: {}",
            .{ header.device_id, header.session_id, appended_records + state_records, last },
        );
    }
}

fn open(io: Io, root_dir: Io.Dir, header: Header) !Io.File {
    var buf: [20]u8 = undefined;
    const dir_name = try std.fmt.bufPrint(&buf, "{:0>10}", .{header.device_id});
    const file_name = try std.fmt.bufPrint(buf[dir_name.len..], "{:0>10}", .{header.session_id});

    const dir = try root_dir.createDirPathOpen(io, dir_name, .{});
    defer dir.close(io);

    return dir.openFile(io, file_name, .{ .mode = .read_write }) catch |err| {
        if (err == error.FileNotFound) {
            return try dir.createFile(io, file_name, .{ .truncate = false });
        }
        return err;
    };
}

fn lastRec(comptime T: type, io: Io, file: Io.File) !?T {
    const file_len = try file.length(io);
    if (file_len == 0) return null;
    var buf: [T.bytes]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, file_len - buf.len);
    var r = std.Io.Reader.fixed(&buf);
    return try T.parse(&r);
}

pub const Temp = struct {
    ts: u32,
    temp: u16,

    const bytes = 6;
    const empty: Temp = .{ .ts = 0, .temp = 0 };

    pub fn parse(r: *Io.Reader) !Temp {
        const ts = try r.takeInt(u32, .little);
        const temp = try r.takeInt(u16, .little);
        return .{ .ts = ts, .temp = temp };
    }

    pub fn encode(self: Temp, w: *Io.Writer) !void {
        try w.writeInt(u32, self.ts, .little);
        try w.writeInt(u16, self.temp, .little);
    }

    pub fn value(self: Temp) f64 {
        const mask: u16 = 0xf800;
        const neg = self.temp & mask == mask;
        const sign: f64 = if (neg) -1 else 1;
        return sign * @as(f64, @floatFromInt(self.temp & ~mask)) / 16;
    }

    test "negative" {
        const n1 = 0b11111_11100100000;
        try testing.expectEqual(-0b11100100000 / 16, (Temp{ .ts = 0, .temp = n1 }).value());
    }
};

const Header = struct {
    message_type: u8,
    update_type: u8,
    device_id: u32,
    session_id: u32,

    fn parse(rdr: *Io.Reader) !Header {
        const message_type = try rdr.takeByte();
        const update_type = try rdr.takeByte();
        const device_id = try rdr.takeInt(u32, .little);
        const session_id = try rdr.takeInt(u32, .little);

        return .{
            .message_type = message_type,
            .update_type = update_type,
            .device_id = device_id,
            .session_id = session_id,
        };
    }
};

pub fn joinMcast(fd: std.os.linux.socket_t, addr: Io.net.IpAddress) !void {
    const ip_mreq = extern struct {
        imr_multiaddr: [4]u8, // The IPv4 multicast group address to join/leave
        imr_interface: [4]u8, // The local network interface IPv4 address to listen on
    };

    const mreq = ip_mreq{
        .imr_multiaddr = addr.ip4.bytes,
        .imr_interface = .{ 0, 0, 0, 0 },
    };
    try std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.IP,
        std.posix.IP.ADD_MEMBERSHIP,
        std.mem.asBytes(&mreq),
    );
}

test {
    _ = Temp;
}

// .rw-r--r-- 158k ianic 10 Jul 18:01 󰡯 1783436665
// .rw-r--r--  88k ianic 10 Jul 18:01 󰡯 1783448708
// .rw-r--r-- 173k ianic 10 Jul 18:01 󰡯 1783449276

// 173394 /home/ianic/data/2213142505/1783449276
//     158286 /home/ianic/data/2213142505/1783436665
//     87858 /home/ianic/data/2213142505/1783448708

// http://your-api.com/data.csv?from=${__from}&to=${__to}
// ${__from:date:seconds}
