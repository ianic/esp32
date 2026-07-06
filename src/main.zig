const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    //const gpa = init.gpa;

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/Code/esp32/data", .{});

    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", 4242);
    const socket = try addr.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });
    defer socket.close(io);

    while (true) {
        var buf: [1472]u8 = undefined;
        const raw = try socket.receive(io, &buf);

        //log.debug("recived raw len {} from: {}", .{ raw.data.len, raw.from });
        var rdr = std.Io.Reader.fixed(raw.data);

        const message_type = try rdr.takeByte();
        const update_type = try rdr.takeByte();
        _ = message_type;
        _ = update_type;

        // identification
        const device_id = try rdr.takeInt(u32, .little);
        const session_id = try rdr.takeInt(u32, .little);

        const file = try open(io, root_dir, device_id, session_id);
        defer file.close(io);

        const last_ts = if (try last(Temp, io, file)) |l| l.ts else 0;
        var found = false;

        var added: usize = 0;
        var write_buf: [4096]u8 = undefined;
        var fw = file.writer(io, &write_buf);
        try fw.seekTo(try file.length(io));
        const w = &fw.interface;
        const count = try rdr.takeInt(u16, .little);
        for (0..count) |_| {
            const rec = try Temp.parse(&rdr);

            if (found) {
                try rec.encode(w);
                added += 1;
            } else if (rec.ts == last_ts) found = true;
            //log.debug("last_ts {} rec {}", .{ last_ts, rec });
        }
        try fw.flush();

        log.debug(
            "device_id: {d}, session_id: {d}, last_ts: {}, count: {d}, added: {}, found: {}",
            .{ device_id, session_id, last_ts, count, added, found },
        );
    }
}

fn open(io: Io, root_dir: Io.Dir, device_id: u32, session_id: u32) !Io.File {
    var buf: [20]u8 = undefined;
    const dir_name = try std.fmt.bufPrint(&buf, "{:0>10}", .{device_id});
    const file_name = try std.fmt.bufPrint(buf[dir_name.len..], "{:0>10}", .{session_id});

    const dir = try root_dir.createDirPathOpen(io, dir_name, .{});

    return dir.openFile(io, file_name, .{ .mode = .read_write }) catch |err| {
        if (err == error.FileNotFound) {
            return try dir.createFile(io, file_name, .{ .truncate = false });
        }
        return err;
    };
}

fn last(comptime T: type, io: Io, file: Io.File) !?T {
    const file_len = try file.length(io);
    if (file_len == 0) return null;
    var buf: [6]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, file_len - buf.len);
    var r = std.Io.Reader.fixed(&buf);
    return try T.parse(&r);
}

const Temp = struct {
    ts: u32,
    temp: u16,

    const bytes = 6;

    fn parse(r: *Io.Reader) !Temp {
        const ts = try r.takeInt(u32, .little);
        const temp = try r.takeInt(u16, .little);
        return .{ .ts = ts, .temp = temp };
    }

    fn encode(self: Temp, w: *Io.Writer) !void {
        try w.writeInt(u32, self.ts, .little);
        try w.writeInt(u16, self.temp, .little);
    }
};
