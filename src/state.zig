const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/Code/esp32/data", .{});

    const addr = try std.Io.net.IpAddress.parse("192.168.207.145", 4243);
    const conn = try addr.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer conn.close(io);

    var buf: [65535]u8 = undefined;
    var soc_rdr = conn.reader(io, &buf);
    var rdr = &soc_rdr.interface;

    const message_type = try rdr.takeByte();
    const update_type = try rdr.takeByte();

    const device_id = try rdr.takeInt(u32, .little);
    const session_id = try rdr.takeInt(u32, .little);

    const dir_name = try std.fmt.allocPrint(gpa, "{:0>10}", .{device_id});
    defer gpa.free(dir_name);
    const file_name = try std.fmt.allocPrint(gpa, "{:0>10}", .{session_id});
    defer gpa.free(file_name);

    const dir = try root_dir.createDirPathOpen(io, dir_name, .{});

    var file = dir.openFile(io, file_name, .{ .mode = .read_write }) catch |err| brk: {
        if (err == error.FileNotFound) {
            break :brk try dir.createFile(io, file_name, .{ .truncate = false });
        }
        return err;
    };
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    var last_ts: u32 = 0;
    {
        const file_len = try file.length(io);
        if (file_len > 0) {
            var rec_buf: [6]u8 = undefined;
            _ = try file.readPositionalAll(io, &rec_buf, file_len - 6);
            var rr = std.Io.Reader.fixed(&rec_buf);
            last_ts = try rr.takeInt(u32, .little);
            _ = try rr.takeInt(u16, .little);
            try fw.seekTo(file_len);
            //log.debug("last ts: {}", .{last_ts});
        }
    }
    var w = &fw.interface;

    const count = try rdr.takeInt(u16, .little);
    var added: usize = 0;
    for (0..count) |_| {
        const ts = try rdr.takeInt(u32, .little);
        const temp = try rdr.takeInt(u16, .little);
        if (ts > last_ts) {
            try w.writeInt(u32, ts, .little);
            try w.writeInt(u16, temp, .little);
            last_ts = ts;
            added += 1;
        }
    }
    try w.flush();

    log.debug("file: {s}/{s} received: {} added: {}", .{ dir_name, file_name, count, added });

    _ = message_type;
    _ = update_type;
}
