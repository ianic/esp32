const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const http = std.http;
const log = std.log.scoped(.main);

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
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    defer conn.close(io);

    var read_buffer: [1024]u8 = undefined;
    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &.{});

    var http_server = http.Server.init(&reader.interface, &writer.interface);
    var request = try http_server.receiveHead();

    log.debug("target: {s}", .{request.head.target});

    const target = request.head.target;
    const query_pos = std.mem.indexOfScalar(u8, target, '?');
    const device_id = target[if (target[0] == '/') 1 else 0..if (query_pos) |qp| qp else target.len];
    var from: u32 = 0;
    var to: u32 = 0;
    var records: usize = 0;

    if (query_pos) |qp| {
        var pairs = std.mem.splitSequence(u8, target[qp + 1 ..], "&");
        while (pairs.next()) |pair| {
            var parts = std.mem.splitSequence(u8, pair, "=");
            const key = parts.next() orelse continue;
            if (mem.eql(u8, key, "from")) {
                from = try std.fmt.parseInt(u32, parts.next() orelse return error.MissingValue, 10);
            }
            if (mem.eql(u8, key, "to")) {
                to = try std.fmt.parseInt(u32, parts.next() orelse return error.MissingValue, 10);
            }
        }
    }

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/data", .{ .iterate = true });
    defer root_dir.close(io);

    const dir = try root_dir.openDir(io, device_id, .{ .iterate = true });
    defer dir.close(io);

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
    std.mem.sort(u32, files.items, {}, std.sort.desc(u32));

    const data_file_ts = files.items[0];

    const data_file_name = try std.fmt.allocPrint(arena, "{:0>10}", .{data_file_ts});
    const data_file = try dir.openFile(io, data_file_name, .{});
    defer data_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = data_file.reader(io, &reader_buf);
    const rdr = &fr.interface;

    var wr: Io.Writer.Allocating = .init(gpa);
    defer wr.deinit();
    const w = &wr.writer;

    try w.print("timestamp,temperature\n", .{});
    while (true) {
        const rec = Temp.parse(rdr) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (rec.value() < 0) continue;
        try w.print("{},{}\n", .{ rec.ts, rec.value() });
        records += 1;
    }
    try w.flush();
    try request.respond(w.buffered(), .{});

    log.debug("device: {s} from: {} to: {} records count: {}", .{ device_id, from, to, records });
}

const Temp = @import("sink.zig").Temp;
const Datetime = @import("state.zig").Datetime;

// http://your-api.com/data.csv?from=${__from}&to=${__to}
// ${__from:date:seconds}
