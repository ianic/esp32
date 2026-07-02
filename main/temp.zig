const std = @import("std");
const idf = @import("idf");
const sys = idf.sys;
const lwip = idf.lwip;
const rtos = idf.rtos;
const task = rtos.Task;
const log = std.log.scoped(.main);

var wifi: @import("WiFi.zig") = .{};
const TempSensor = @import("temp_sensor.zig").TempSensor;
const Readings = @import("ring_buffer.zig").RingBuffer(Reading);

var device_id: u32 = 0;
var session_id: u32 = 0;
var sink_addr: lwip.SockAddrIn = undefined;
var update_socket: lwip.Socket = undefined;

fn main() !void {
    try idf.nvs.flashInitOrErase();
    try wifi.initNvs();
    // var heap = idf.heap.HeapCapsAllocator.init(.{ .@"8bit" = true });
    // log.debug("heap free size 1: {} {}", .{ heap.freeSize(), heap.largestFreeBlock() });

    {
        update_socket = try lwip.Socket.create(idf.sys.AF_INET, idf.sys.SOCK_DGRAM, 0);
        sink_addr.sin_family = sys.AF_INET;
        sink_addr.sin_port = lwip.htons(4242);
        sink_addr.sin_addr.s_addr = idf.sys.ipaddr_addr("192.168.207.181");
    }
    {
        device_id = deviceID();
        session_id = timestamp();
    }

    const master_task = try task.create(master, "master", 4 * 1024, null, 2);
    // priority 19 above lwip
    _ = try task.create(readTempWorker, "read temp", 4 * 1024, master_task, 19);
    _ = try task.create(acceptWorker, "socket accept", 4 * 1024, master_task, 2);

    //log.debug("heap free size 2: {} {}", .{ heap.freeSize(), heap.largestFreeBlock() });
}

export fn app_main() callconv(.c) void {
    main() catch |err| {
        log.err("main failed {s}", .{@errorName(err)});
    };
}

fn readTempWorker(ptr: ?*anyopaque) callconv(.c) void {
    const hnd: task.Handle = @ptrCast(@alignCast(ptr.?));
    const ts: TempSensor = .init(temp_sensor_pin);
    while (true) {
        readTemp(ts, hnd) catch |err| {
            log.err("read temp worker task failed {s}", .{@errorName(err)});
            if (err == error.CrcFail) continue;
            task.delayMs(1000);
        };
    }
}

fn readTemp(ts: TempSensor, hnd: task.Handle) !void {
    try ts.convert();
    task.delayMs(1000);
    const temp, _ = try ts.read();
    try task.notify(hnd, temp, idf.sys.eSetValueWithOverwrite, temp_notification_index);
}

const temp_sensor_pin: idf.gpio.Num() = .@"10";
const temp_notification_index = 0;
const socket_notification_index = 1;
const clear_none = 0;
const clear_all = 0xff_ff_ff_ff;

fn master(_: ?*anyopaque) callconv(.c) void {
    _master() catch |err| {
        log.err("master task {}", .{err});
    };
}

fn _master() !void {
    var heap = idf.heap.HeapCapsAllocator.init(.{ .@"32bit" = true });
    const gpa = heap.allocator();
    const count: u16 = @min(
        (heap.largestFreeBlock() - 32) / @sizeOf(Reading),
        std.math.maxInt(u16),
    );
    log.debug("allocating {} readings, {} bytes, {} largestFreeBlock", .{
        count,
        count * @sizeOf(Reading),
        heap.largestFreeBlock(),
    });
    const readings_buf = try gpa.alloc(Reading, count);
    var readings: Readings = .init(readings_buf);

    { // DUMMY
        for (0..count) |i| {
            readings.add(.{
                .ts = i,
                .temp = @truncate(i),
            });
        }
    }

    // const hwm = task.getStackHighWaterMark(null);
    // log.debug("master stack high water mark {}", .{hwm});

    var buf: [1460]u8 = undefined;
    while (true) {
        var temp: u32 = 0;
        if (task.notifyWait(temp_notification_index, clear_none, clear_all, &temp, 0)) {
            const reading: Reading = .{
                .ts = timestamp(),
                .temp = @intCast(temp),
            };
            readings.add(reading);

            const msg = writeUpdateMessage(&buf, &readings) catch |err| {
                log.err("writeUpdateMessage {s}", .{@errorName(err)});
                continue;
            };
            const msg_len = update_socket.sendTo(msg, 0, @ptrCast(&sink_addr), @sizeOf(lwip.SockAddrIn)) catch |err| {
                log.err("udp send {s}", .{@errorName(err)});
                continue;
            };

            log.debug("{d} got reading: {d} in °C: {d} and {d}/16 readings: {d} {}, msg_len: {d}", .{
                reading.ts,
                temp,
                temp / 16,
                temp % 16,
                readings.count(),
                readings.sequenceRange(),
                msg_len,
            });
        }
        var fd: u32 = 0;
        if (task.notifyWait(socket_notification_index, clear_none, clear_all, &fd, rtos.msToTicks(500))) {
            const socket: lwip.Socket = .{ .fd = @intCast(fd) };
            defer socket.close() catch {};
            sendState(socket, &readings, &buf) catch |err| {
                log.err("send state failed {s}", .{@errorName(err)});
            };
        }
    }
}

fn sendState(socket: lwip.Socket, readings: *Readings, buf: []u8) !void {
    var w = std.Io.Writer.fixed(buf);
    // identification
    try w.writeInt(u32, device_id, .little);
    try w.writeInt(u32, session_id, .little);
    // TODO treba li mi timestamp i message type temp reading state, temp reading update
    // my state
    const min_seq, const max_seq = readings.sequenceRange();
    try w.writeInt(u32, min_seq, .little);
    try w.writeInt(u32, max_seq, .little);
    try w.writeInt(u16, @intCast(readings.count()), .little);

    var seq = min_seq;
    var iter = readings.iterator();
    while (iter.next()) |r| {
        if (w.unusedCapacityLen() < 4 + 4 + 2) {
            while (w.end > 0) {
                const n = try socket.send(w.buffered(), 0);
                _ = w.consume(n);
            }
        }
        try w.writeInt(u32, seq, .little);
        try w.writeInt(u32, r.ts, .little);
        try w.writeInt(u16, r.temp, .little);
        seq += 1;
    }
    while (w.end > 0) {
        const n = try socket.send(w.buffered(), 0);
        _ = w.consume(n);
    }
}

const Reading = packed struct {
    ts: u32,
    temp: u16,
};

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = @import("log.zig").logFn,
};

fn writeUpdateMessage(buf: []u8, readings: *Readings) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);

    // identification
    try w.writeInt(u32, device_id, .little);
    try w.writeInt(u32, session_id, .little);
    // my state
    const min_seq, const max_seq = readings.sequenceRange();
    try w.writeInt(u32, min_seq, .little);
    try w.writeInt(u32, max_seq, .little);
    // readings
    const count: u8 = @min(
        (buf.len - w.buffered().len - 5) / 6,
        max_seq - min_seq + 1,
        255,
        //16,
    );
    //
    try w.writeInt(u8, count, .little);
    try w.writeInt(u32, max_seq, .little);

    var iter = readings.iterator();
    for (0..count) |_| {
        const r = iter.next().?;
        try w.writeInt(u32, r.ts, .little);
        try w.writeInt(u16, r.temp, .little);
    }
    return w.buffered();
}

pub fn deviceID() u32 {
    var mac: [6]u8 = undefined;
    _ = sys.esp_efuse_mac_get_default(&mac);

    // Hash all 6 unique bytes using the Zig standard library CRC32 algorithm
    return std.hash.Crc32.hash(&mac);
}

fn timestamp() u32 {
    // Get current system time (seconds and microseconds since epoch)
    var sec: u32 = 0;
    var us: u32 = 0;
    idf.lwip.SNTP.getSystemTime(&sec, &us);
    return sec;
}

fn acceptWorker(ptr: ?*anyopaque) callconv(.c) void {
    const hnd: task.Handle = @ptrCast(@alignCast(ptr.?));
    accept(hnd) catch |err| {
        log.err("accept task failed {s}", .{@errorName(err)});
    };
}
fn accept(hnd: task.Handle) !void {
    var addr: lwip.SockAddrIn = undefined;
    addr.sin_family = sys.AF_INET;
    addr.sin_port = lwip.htons(4243);
    addr.sin_addr.s_addr = idf.sys.ipaddr_addr("0.0.0.0");

    var tcp_socket = try lwip.Socket.create(idf.sys.AF_INET, sys.SOCK_STREAM, 0);
    try tcp_socket.bind(@ptrCast(&addr), @sizeOf(lwip.SockAddrIn));
    try tcp_socket.listen(1);

    while (true) {
        const conn = try tcp_socket.accept(null, null);
        task.notify(hnd, @intCast(conn.fd), sys.eSetValueWithoutOverwrite, socket_notification_index) catch |err| {
            try conn.close();
            log.err("accept {s}", .{@errorName(err)});
        };
    }
}
