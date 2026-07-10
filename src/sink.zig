const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);
const assert = std.debug.assert;
const testing = std.testing;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    //const gpa = init.gpa;

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/data/1", .{});
    defer root_dir.close(io);

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
    var buf: [6]u8 = undefined;
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
