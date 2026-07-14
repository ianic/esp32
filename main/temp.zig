const std = @import("std");
const idf = @import("idf");
const sys = idf.sys;
const lwip = idf.lwip;
const rtos = idf.rtos;
const task = rtos.Task;
const log = std.log.scoped(.main);
const msg = @import("msg");

var wifi: @import("WiFi.zig") = .{};
const TempSensor = @import("temp_sensor.zig").TempSensor;
const Readings = msg.RingBuffer(msg.Temp);

var device_id: u32 = 0;
var session_id: u32 = 0;
var bcast: struct {
    addr: lwip.SockAddrIn,
    socket: lwip.Socket,
} = undefined;

fn main() !void {
    try idf.nvs.flashInitOrErase();
    try wifi.initNvs();

    {
        bcast.socket = try lwip.Socket.create(idf.sys.AF_INET, idf.sys.SOCK_DGRAM, 0);
        bcast.addr.sin_family = sys.AF_INET;
        bcast.addr.sin_port = lwip.htons(4242);
        bcast.addr.sin_addr.s_addr = idf.sys.ipaddr_addr("224.0.0.1");
    }
    device_id = deviceID();

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
    // allocate readings in the largest heap free block
    var heap = idf.heap.HeapCapsAllocator.init(.{ .@"32bit" = true });
    const gpa = heap.allocator();
    const count: usize = @min(
        (heap.largestFreeBlock() - 32) / @sizeOf(msg.Temp),
        std.math.maxInt(u16),
    );
    log.debug("allocating {} readings, {} bytes, {} largestFreeBlock", .{
        count,
        count * @sizeOf(msg.Temp),
        heap.largestFreeBlock(),
    });
    const readings_buf = try gpa.alloc(msg.Temp, count);
    var readings: Readings = .init(readings_buf);

    var net_buf: [1460]u8 = undefined;

    while (true) {
        var val: u32 = 0;
        if (task.notifyWait(temp_notification_index, clear_none, clear_all, &val, 0)) {
            const reading: msg.Temp = .{ .ts = timestamp(), .temp = @intCast(val) };
            if (session_id == 0) {
                session_id = reading.ts;
            }
            readings.append(reading);
            sendUpdate(&readings, &net_buf) catch |err| {
                log.err("send update failed {}", .{err});
                continue;
            };

            log.debug("{d} got reading: {d} in °C: {d} and {d}/16 readings: {d} {}", .{
                reading.ts,
                reading.temp,
                reading.temp / 16,
                reading.temp % 16,
                readings.count(),
                readings.sequenceRange(),
            });
        }

        if (task.notifyWait(socket_notification_index, clear_none, clear_all, &val, rtos.msToTicks(500))) {
            const socket: lwip.Socket = .{ .fd = @intCast(val) };
            defer socket.close() catch {};
            sendState(socket, &readings, &net_buf) catch |err| {
                log.err("send state failed {s}", .{@errorName(err)});
            };
        }
    }
}

fn sendState(socket: lwip.Socket, readings: *Readings, buf: []u8) !void {
    var w = std.Io.Writer.fixed(buf);

    try w.writeByte(0); // message type = temp
    try w.writeByte(1); // update or state

    // identification
    try w.writeInt(u32, device_id, .little);
    try w.writeInt(u32, session_id, .little);

    try w.writeInt(u16, @intCast(readings.count()), .little);
    var iter = readings.iterator();
    while (iter.next()) |r| {
        if (w.unusedCapacityLen() < 4 + 2) {
            while (w.end > 0) {
                const n = try socket.send(w.buffered(), 0);
                _ = w.consume(n);
            }
        }
        try r.encode(&w);
    }
    while (w.end > 0) {
        const n = try socket.send(w.buffered(), 0);
        _ = w.consume(n);
    }
}

fn sendUpdate(readings: *Readings, buf: []u8) !void {
    var w = std.Io.Writer.fixed(buf);

    try w.writeByte(0); // message type = temp
    try w.writeByte(0); // update or state

    // identification
    try w.writeInt(u32, device_id, .little);
    try w.writeInt(u32, session_id, .little);

    // number of readings which fit into buf
    const count: u16 = @min(
        (w.unusedCapacityLen() - 2) / 6,
        readings.count(),
        std.math.maxInt(u16),
    );

    //
    try w.writeInt(u16, count, .little);
    var iter = readings.iterator();
    var skip: usize = readings.count() - count;
    var added: usize = 0;
    while (iter.next()) |r| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        added += 1;
        try r.encode(&w);
    }

    _ = try bcast.socket.sendTo(w.buffered(), 0, @ptrCast(&bcast.addr), @sizeOf(lwip.SockAddrIn));
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

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = @import("log.zig").logFn,
};
