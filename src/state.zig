const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const root_dir = try std.Io.Dir.openDirAbsolute(io, "/home/ianic/data/1", .{ .iterate = true });
    defer root_dir.close(io);

    const device_id = 2213142505;
    const dir_name = try std.fmt.allocPrint(arena, "{:0>10}", .{device_id});
    const dir = try root_dir.openDir(io, dir_name, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var files: std.ArrayList(u32) = .empty;
    defer files.deinit(gpa);
    while (try walker.next(io)) |entry| {
        if (!(entry.kind == .file and entry.depth() == 1)) continue;

        const ts = std.fmt.parseInt(u32, entry.basename, 10) catch |err| {
            log.err("filed to parse {s} as timestamp {}", .{ entry.basename, err });
            continue;
        };
        try files.append(gpa, ts);
    }
    std.mem.sort(u32, files.items, {}, std.sort.desc(u32));

    // for (files.items) |ts| {
    //     const dt = Datetime.fromUnix(ts);
    //     log.debug(
    //         "{} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
    //         .{ ts, dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec },
    //     );
    // }

    const data_file_ts = files.items[0];

    const data_file_name = try std.fmt.allocPrint(arena, "{:0>10}", .{data_file_ts});
    const data_file = try dir.openFile(io, data_file_name, .{});
    defer data_file.close(io);
    var reader_buf: [4096]u8 = undefined;
    var fr = data_file.reader(io, &reader_buf);
    const rdr = &fr.interface;

    const csv_file_name = try std.fmt.allocPrint(arena, "{:0>10}.csv", .{data_file_ts});
    const csv_file = try dir.createFile(io, csv_file_name, .{ .truncate = true });
    defer csv_file.close(io);
    var writer_buf: [4096]u8 = undefined;
    var wr = csv_file.writer(io, &writer_buf);
    const w = &wr.interface;

    try w.print(
        "timestamp,time,value,temp\n",
        .{},
    );
    while (true) {
        const rec = Temp.parse(rdr) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        const dt = Datetime.fromUnix(rec.ts);
        const f = @as(f64, @floatFromInt(rec.temp)) / 16;
        if (f > 100) {
            try w.print(
                "{},{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2},{},{}\n",
                .{ rec.ts, dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec, rec.temp, f },
            );

            log.debug(
                "{} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {} {}°C {b}",
                .{ rec.ts, dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec, rec.temp, f, rec.temp },
            );
        }
        //log.debug("{}", .{rec});
    }
    try w.flush();
}

const Temp = @import("sink.zig").Temp;

pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    min: u8,
    sec: u8,

    pub fn fromUnix(ts: u32) Datetime {
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = ts };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return .{
            .year = year_day.year,
            .month = @intFromEnum(month_day.month),
            .day = month_day.day_index + 1,
            .hour = day_seconds.getHoursIntoDay(),
            .min = day_seconds.getMinutesIntoHour(),
            .sec = day_seconds.getSecondsIntoMinute(),
        };
    }
};
