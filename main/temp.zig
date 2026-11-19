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
const SensorHealth = @import("temp_sensor.zig").SensorHealth;
const Readings = msg.RingBuffer(msg.Temp);

var device_id: u48 = 0;
var session_id: u32 = 0;
var bcast: struct {
    addr: lwip.SockAddrIn,
    socket: lwip.Socket,
} = undefined;

const led_pin: idf.gpio.Num() = .@"21";
const relay_pin: idf.gpio.Num() = .@"9";

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

    try idf.gpio.Direction.set(led_pin, .output);
    try idf.gpio.Direction.set(relay_pin, .output);

    const master_task = try task.create(masterC, "master", 4 * 1024, null, 2);
    // priority 19 above lwip
    _ = try task.create(readTempWorker, "read temp", 4 * 1024, master_task, 19);
    _ = try task.create(acceptWorker, "socket accept", 4 * 1024, master_task, 2);

    try startHttpServer(master_task);

    try idf.err.espCheckError(sys.esp_ota_mark_app_valid_cancel_rollback());

    const partition = sys.esp_ota_get_running_partition();
    log.info(
        "Running partition: {s}, address: {x}, size: {x}",
        .{ std.mem.span(@as([*c]const u8, &partition.*.label)), partition.*.address, partition.*.size },
    );

    // log.debug("heap free size 2: {} {}", .{ heap.freeSize(), heap.largestFreeBlock() });
}

export fn app_main() callconv(.c) void {
    main() catch |err| {
        log.err("main failed {s}", .{@errorName(err)});
    };
}

fn readTempWorker(ptr: ?*anyopaque) callconv(.c) void {
    const hnd: task.Handle = @ptrCast(@alignCast(ptr.?));
    const ts: TempSensor = .init(temp_sensor_pin);
    var sh: SensorHealth = .{};
    while (true) {
        readTemp(ts, hnd) catch |err| {
            sh.fail();
            if (!sh.healthy()) {
                log.err(
                    "temp sensor measurements: {d}, successes: {d}, failures: {d}, recents: {b} error: {s}",
                    .{ sh.measurements, sh.successes, sh.failures, sh.recent, @errorName(err) },
                );
            }
            if (err != error.CrcFail)
                task.delayMs(1000);
            continue;
        };
        sh.success();
        if (sh.measurements % 32 == 0) {
            log.info("temp sensor measurements: {d}, successes: {d}, failures: {d}, recents: {b}", .{
                sh.measurements, sh.successes, sh.failures, sh.recent,
            });
        }
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
const ota_notification_index = 2;
const clear_none = 0;
const clear_all = 0xff_ff_ff_ff;

fn masterC(_: ?*anyopaque) callconv(.c) void {
    master() catch |err| {
        log.err("master task {}", .{err});
    };
}

fn master() !void {
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

    var led_on: u1 = 0;
    while (true) {
        var val: u32 = 0;

        if (task.notifyWait(ota_notification_index, clear_none, clear_all, &val, 0)) {
            log.info("ota notification restarting", .{});
            sys.esp_restart();
            return;
        }

        if (task.notifyWait(temp_notification_index, clear_none, clear_all, &val, 0)) {
            const reading: msg.Temp = .{ .ts = timestamp(), .temp = @intCast(val) };
            if (session_id == 0) {
                session_id = reading.ts;
            }
            if (readings.last()) |l| {
                if (@abs(l.celsius() - reading.celsius()) > 10) continue;
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
            led_on ^= 1;
            idf.gpio.Level.set(led_pin, led_on) catch {};
            //idf.gpio.Level.set(relay_pin, led_on) catch {};
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

    const header: msg.Header = .{
        .device_id = device_id,
        .message_type = .temperature_reading,
        .session_id = session_id,
        .flags = .{ .state = true },
    };
    try header.encode(&w);

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

    const header: msg.Header = .{
        .device_id = device_id,
        .message_type = .temperature_reading,
        .session_id = session_id,
    };
    try header.encode(&w);

    // number of readings which fit into buf
    const count: u16 = @min(
        (w.unusedCapacityLen() - 2) / 6,
        readings.count(),
        std.math.maxInt(u16),
    );
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

pub fn deviceID() u48 {
    var mac: [6]u8 = undefined;
    _ = sys.esp_efuse_mac_get_default(&mac);
    return std.mem.readInt(u48, &mac, .big);
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
        .debug => .debug,
        else => .info,
    },
    .logFn = @import("log.zig").logFn,
};

fn startHttpServer(hnd: task.Handle) !void {
    var config = sys.zig_httpd_default_config();
    config.global_user_ctx = hnd;

    const server = try idf.http.Server.start(&config);

    const root_uri = sys.httpd_uri_t{
        .uri = "/",
        .method = sys.HTTP_GET,
        .handler = &handleRoot,
        .user_ctx = null,
    };
    try idf.http.Server.registerUri(server, &root_uri);

    const api_uri = sys.httpd_uri_t{
        .uri = "/update",
        .method = sys.HTTP_GET,
        .handler = &handleUpdateC,
        .user_ctx = null,
    };
    try idf.http.Server.registerUri(server, &api_uri);

    // log.info("HTTP server started on port 80", .{});
}

const index_html =
    \\<!DOCTYPE html><html><body>
    \\<h1>Hello from Zig on ESP32!</h1>
    \\<p>This page is served by the Zig HTTP server wrapper.</p>
    \\</body></html>
;

export fn handleRoot(req: [*c]sys.httpd_req_t) callconv(.c) sys.esp_err_t {
    idf.http.Server.Response.sendStr(req, index_html) catch |err| {
        log.err("sendStr: {s}", .{@errorName(err)});
        return sys.ESP_FAIL;
    };
    return sys.ESP_OK;
}

export fn handleUpdateC(req: [*c]sys.httpd_req_t) callconv(.c) sys.esp_err_t {
    handleUpdate(req) catch |err| {
        log.err("handleUpdate: {s}", .{@errorName(err)});
        return sys.ESP_FAIL;
    };
    return sys.ESP_OK;
}

fn handleUpdate(req: [*c]sys.httpd_req_t) !void {
    const len = idf.http.Server.Request.getUrlQueryLen(req);
    const ctx = sys.httpd_get_global_user_ctx(req.*.handle);
    const hnd: task.Handle = @ptrCast(@alignCast(ctx));
    if (len > 0) {
        var buf: [128]u8 = undefined;
        try idf.http.Server.Request.getUrlQueryStr(req, @ptrCast(&buf), len + 1); // zero terminated
        const query_str = buf[0..len]; // zig string
        if (getKey(query_str, "url")) |val| {
            @memmove(buf[0..val.len], val);
            buf[val.len] = 0;
            const url = buf[0..val.len]; // Zig string, buf is zero terminated

            log.info("ota update starting with url: '{s}'", .{url});
            try otaUpdate(@ptrCast(url.ptr));
            log.info("ota update ok", .{});
            try idf.http.Server.Response.sendStr(req, @ptrCast(&buf));

            try task.notify(hnd, 0, idf.sys.eSetValueWithOverwrite, ota_notification_index);
        }
    }
}

fn getKey(query_str: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query_str, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            if (std.mem.eql(u8, pair[0..eq_pos], key)) {
                return pair[eq_pos + 1 ..];
            }
        }
    }
    return null;
}

fn otaUpdate(url: [*c]const u8) !void {
    const config: sys.esp_http_client_config_t = .{
        .url = url,
    };
    const ota_config: sys.esp_https_ota_config_t = .{
        .http_config = &config,
    };
    try idf.err.espCheckError(sys.esp_https_ota(@ptrCast(&ota_config)));
}
