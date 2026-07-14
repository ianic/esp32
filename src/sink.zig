const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const http = std.http;
const log = std.log.scoped(.main);
const assert = std.debug.assert;
const testing = std.testing;
const msg = @import("message.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/data", .{ .iterate = true });
    defer root_dir.close(io);

    const Result = union(enum) {
        a: anyerror!void,
        b: anyerror!void,
    };
    var results: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &results);
    defer _ = select.cancel();
    try select.concurrent(.a, httpServer, .{ io, gpa, root_dir });
    try select.concurrent(.b, udpSink, .{ io, root_dir });
    switch (try select.await()) {
        .a => |ret| ret catch |err| log.err("http server exit with {}", .{err}),
        .b => |ret| ret catch |err| log.err("udp sink exit with {}", .{err}),
    }
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
        fn handle(ptr: *anyopaque, rec: msg.Temp) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (rec.celsius() < 0 and rec.ts < 1784040543) {
                return;
            }
            if (rec.isEmpty()) {
                log.warn("empty record at position {}", .{self.count});
                return;
            }
            try self.w.print("{},{}\n", .{ rec.ts, rec.celsius() });
            self.count += 1;
        }
    };
    var ctx: Ctx = .{ .w = w };

    try w.print("timestamp,temperature\n", .{});
    try msg.iterate(msg.Temp, gpa, io, dir, from_ts, to_ts, &ctx, Ctx.handle);
    try w.flush();
    try request.respond(w.buffered(), .{});

    log.debug(
        "target: {s} count: {}",
        .{ target, ctx.count },
    );
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

        const header = try msg.Header.parse(rdr);
        const file = try open(io, root_dir, header);
        defer file.close(io);
        const last_rec = try secondToLast(msg.Temp, io, file);
        var fw = file.writer(io, &write_buf);
        const w = &fw.interface;

        // If there is continuation, previous record is found in update packet
        var can_append = false;
        var appended_records: usize = 0;
        var last_appended: msg.Temp = .empty;
        if (last_rec) |lr| {
            try fw.seekTo(try file.length(io) - msg.Temp.bytes); // always replace last record
            const count = try rdr.takeInt(u16, .little);
            for (0..count) |_| {
                const rec = try msg.Temp.parse(rdr);
                if (can_append) {
                    try rec.encode(w);
                    last_appended = rec;
                    appended_records += 1;
                } else if (rec.ts == lr.ts)
                    can_append = true;
            }
        }
        if (!can_append) { // read full state
            try fw.seekTo(try file.length(io));
            var addr = packet.from;
            addr.setPort(4243);
            const conn = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer conn.close(io);
            var soc_rdr = conn.reader(io, &packet_buf);
            rdr = &soc_rdr.interface;

            const state_header = try msg.Header.parse(rdr);
            assert(state_header.device_id == header.device_id);
            if (state_header.session_id != header.session_id) continue;

            const count = try rdr.takeInt(u16, .little);
            for (0..count) |i| {
                const rec = try msg.Temp.parse(rdr);
                if (i == 0) if (last_rec) |lr| if (rec.ts > lr.ts) {
                    // If there is gap between last and new state add empty record
                    try msg.Temp.empty.encode(w);
                };
                if (last_rec == null or rec.ts > last_rec.?.ts) {
                    try rec.encode(w);
                    last_appended = rec;
                    appended_records += 1;
                }
            }
        }
        try fw.flush();

        log.debug(
            "{d}/{d}, records: {d}, last: {}",
            .{ header.device_id, header.session_id, appended_records, last_appended },
        );
    }
}

fn open(io: Io, root_dir: Io.Dir, header: msg.Header) !Io.File {
    var buf: [15 + 10]u8 = undefined;
    const dir_name = try std.fmt.bufPrint(&buf, "{x:0>12}-{x}", .{ header.device_id, header.message_type });
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

// read second to last record from the file
fn secondToLast(comptime T: type, io: Io, file: Io.File) !?T {
    const file_len = try file.length(io);
    if (file_len < T.bytes * 2) return null;
    var buf: [T.bytes]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, file_len - (T.bytes * 2));
    var r = std.Io.Reader.fixed(&buf);
    return try T.parse(&r);
}

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

// .rw-r--r-- 158k ianic 10 Jul 18:01 󰡯 1783436665
// .rw-r--r--  88k ianic 10 Jul 18:01 󰡯 1783448708
// .rw-r--r-- 173k ianic 10 Jul 18:01 󰡯 1783449276

// 173394 /home/ianic/data/2213142505/1783449276
//     158286 /home/ianic/data/2213142505/1783436665
//     87858 /home/ianic/data/2213142505/1783448708

// http://your-api.com/data.csv?from=${__from}&to=${__to}
// ${__from:date:seconds}
