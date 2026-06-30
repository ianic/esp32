const std = @import("std");
const idf = @import("esp_idf");
const log = std.log.scoped(.main);
const sys = idf.sys;

var wifi: @import("WiFi.zig") = .{};
const TempSensor = @import("temp_sensor.zig").TempSensor;
const RingBuffer = @import("ring_buffer.zig").RingBuffer(Reading, 1024 * 8);

fn main() !void {
    try idf.nvs.flashInitOrErase();
    try wifi.initNvs();

    var heap = idf.heap.HeapCapsAllocator.init(.{ .@"8bit" = true });
    const gpa = heap.allocator();

    log.debug("heap free size 0: {}, largestFreeBlock: {}", .{ heap.freeSize(), heap.largestFreeBlock() });
    const rb = try gpa.create(RingBuffer);
    rb.* = .{};
    log.debug("heap free size 1: {}", .{heap.freeSize()});

    const master_task = try idf.rtos.Task.create(master, "master", 4 * 1024, rb, 5);
    _ = try idf.rtos.Task.create(readTempWorker, "read temp", 2 * 1024, master_task, 5);
    log.debug("heap free size 2: {}", .{heap.freeSize()});
}

export fn app_main() callconv(.c) void {
    main() catch |err| {
        log.err("{}", .{err});
    };
}
pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = @import("log.zig").logFn,
};

fn readTempWorker(ptr: ?*anyopaque) callconv(.c) void {
    const task: idf.rtos.TaskHandle = @ptrCast(@alignCast(ptr.?));
    const ts: TempSensor = .init(temp_sensor_pin);
    while (true) {
        readTemp(ts, task) catch |err| {
            log.err("read temp worker task {}", .{err});
            idf.rtos.Task.delayMs(1000);
        };
    }
}

fn readTemp(ts: TempSensor, task: idf.rtos.TaskHandle) !void {
    try ts.convert();
    idf.rtos.Task.delayMs(1000);
    const actual16, _ = try ts.read();
    try idf.rtos.Task.notify(
        task,
        actual16,
        idf.sys.eSetValueWithOverwrite,
        temp_notification_index,
    );
}

const temp_sensor_pin: idf.gpio.Num() = .@"10";
const temp_notification_index = 0;

fn master(ptr: ?*anyopaque) callconv(.c) void {
    const rb: *RingBuffer = @ptrCast(@alignCast(ptr.?));
    _master(rb) catch |err| {
        log.err("master task {}", .{err});
    };
}

fn _master(rb: *RingBuffer) !void {
    //var rb: @import("ring_buffer.zig").RingBuffer(Reading, 512) = .{};

    const hwm = idf.rtos.Task.getStackHighWaterMark(null);
    log.debug("master stack high water mark {}", .{hwm});

    while (true) {
        var temp: u32 = 0;
        if (!idf.rtos.Task.notifyWait(
            temp_notification_index,
            0, // which bits to clear in the task's notification value before waiting
            0xff_ff_ff_ff, //  which bits to clear in the task's notification value after the notification is received
            &temp, // Optional: pointer to receive the u32 value
            idf.sys.portMAX_DELAY, // ticks to wait
        )) continue;

        // Get current system time (seconds and microseconds since epoch)
        var sec: u32 = 0;
        var us: u32 = 0;
        idf.lwip.SNTP.getSystemTime(&sec, &us);

        const reading: Reading = .{
            .ts = sec,
            .temp = @intCast(temp),
        };
        rb.add(reading);

        log.debug("{} got reading: {} in °C: {} and {}/16 readings: {} {}", .{
            sec,
            temp,
            temp / 16,
            temp % 16,
            rb.count(),
            rb.sequenceRange(),
        });
    }
}

const Reading = packed struct {
    ts: u32,
    temp: u16,
};
