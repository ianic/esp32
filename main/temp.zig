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
var socket: lwip.Socket = undefined;

fn main() !void {
    try idf.nvs.flashInitOrErase();
    try wifi.initNvs();
    // var heap = idf.heap.HeapCapsAllocator.init(.{ .@"8bit" = true });
    // log.debug("heap free size 1: {} {}", .{ heap.freeSize(), heap.largestFreeBlock() });

    {
        socket = try lwip.Socket.create(idf.sys.AF_INET, idf.sys.SOCK_DGRAM, 0);
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
    _ = try task.create(socketAccept, "socket accept", 4 * 1024, master_task, 2);

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
    const n = (heap.largestFreeBlock() - 32) / @sizeOf(Reading);
    log.debug("allocating {} readings, {} bytes, {} largestFreeBlock", .{
        n,
        n * @sizeOf(Reading),
        heap.largestFreeBlock(),
    });
    const readings_buf = try gpa.alloc(Reading, n);
    var readings: Readings = .init(readings_buf);

    // const hwm = task.getStackHighWaterMark(null);
    // log.debug("master stack high water mark {}", .{hwm});

    while (true) {
        var temp: u32 = 0;
        if (task.notifyWait(temp_notification_index, clear_none, clear_all, &temp, 0)) {
            const reading: Reading = .{
                .ts = timestamp(),
                .temp = @intCast(temp),
            };
            readings.add(reading);

            var buf: [1472]u8 = undefined;
            const msg = writeUpdateMessage(&buf, &readings) catch |err| {
                log.err("writeUpdateMessage {s}", .{@errorName(err)});
                continue;
            };
            const msg_len = socket.sendTo(msg, 0, @ptrCast(&sink_addr), @sizeOf(lwip.SockAddrIn)) catch |err| {
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
        var state_socket: u32 = 0;
        if (task.notifyWait(socket_notification_index, clear_none, clear_all, &state_socket, rtos.msToTicks(500))) {}
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
    return buf[0..w.end];
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

fn socketAccept(ptr: ?*anyopaque) callconv(.c) void {
    const hnd: task.Handle = @ptrCast(@alignCast(ptr.?));
    _ = hnd;
    while (true) {
        task.delayMs(1000);
    }
}
