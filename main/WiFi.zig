const std = @import("std");
const idf = @import("esp_idf");
const sys = idf.sys;

const log = std.log.scoped(.wifi);

retry_count: u32 = 0,
var blocking_task: idf.rtos.TaskHandle = null;

const Self = @This();

pub fn init(self: *Self, ssid: []const u8, pwd: []const u8, authmode: u8) !void {
    try idf.err.espCheckError(sys.esp_netif_init());
    try idf.event.loopCreateDefault();
    _ = sys.esp_netif_create_default_wifi_sta();

    var wifi_init_cfg = idf.wifi.init_config_default();
    try idf.err.espCheckError(sys.esp_wifi_init(&wifi_init_cfg));

    _ = try idf.event.handlerInstanceRegister(sys.WIFI_EVENT, idf.event.ANY_ID, &onWifiEvent, self);
    _ = try idf.event.handlerInstanceRegister(sys.IP_EVENT, sys.IP_EVENT_STA_GOT_IP, &onWifiEvent, self);

    var wifi_config = idf.wifi.wifiConfig{
        .sta = .{
            .threshold = .{ .rssi = 0, .rssi_5g_adjustment = 0, .authmode = authmode },
            .sae_pwe_h2e = sys.WPA3_SAE_PWE_BOTH,
        },
    };
    copyZ(&wifi_config.sta.ssid, ssid);
    copyZ(&wifi_config.sta.password, pwd);

    try idf.wifi.setMode(.WIFI_MODE_STA);
    try idf.wifi.setConfig(.WIFI_IF_STA, &wifi_config);
    try idf.wifi.start();
}

pub fn initBlocking(self: *Self, ssid: []const u8, pwd: []const u8, authmode: u8) !void {
    self.blocking_task = idf.rtos.Task.getCurrent();
    try self.init(ssid, pwd, authmode);
    _ = idf.rtos.Task.notifyWait(
        0, // UBaseType notification index
        0, // which bits to clear in the task's notification value before waiting
        0xff_ff_ff_ff, //  which bits to clear in the task's notification value after the notification is received
        null,
        sys.portMAX_DELAY, // ticks to wait
    );
    self.blocking_task = null;
}

pub fn initNvs(self: *Self) !void {
    const ns = try idf.nvs.open("wifi-defaults", .read_only);
    defer idf.nvs.close(ns);
    var buf: [32]u8 = undefined;
    const ssid = try nvsGetStr(ns, "ssid", &buf);
    const pwd = try nvsGetStr(ns, "password", buf[ssid.len..]);
    const authmode = try idf.nvs.getU8(ns, "authmode");

    blocking_task = idf.rtos.Task.getCurrent();
    try self.init(ssid, pwd, authmode);
    _ = idf.rtos.Task.notifyWait(
        0, // UBaseType notification index
        0, // which bits to clear in the task's notification value before waiting
        0xff_ff_ff_ff, //  which bits to clear in the task's notification value after the notification is received
        null,
        sys.portMAX_DELAY, // ticks to wait
    );

    sys.sntp_set_time_sync_notification_cb(sntpCallback);
    sys.sntp_setoperatingmode(sys.SNTP_OPMODE_POLL);
    sys.sntp_setservername(0, "pool.ntp.org");
    sys.sntp_set_time_sync_notification_cb(sntpCallback);
    sys.sntp_init();
    if (!idf.rtos.Task.notifyWait(0, 0, 0xff_ff_ff_ff, null, idf.rtos.msToTicks(10000))) {
        log.err("sntp sync missing in 10s", .{});
    }
    sys.sntp_set_time_sync_notification_cb(null);

    blocking_task = null;
}

export fn onWifiEvent(
    ptr: ?*anyopaque,
    event_base: sys.esp_event_base_t,
    event_id: i32,
    event_data: ?*anyopaque,
) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ptr.?));

    if (event_base == sys.WIFI_EVENT) {
        switch (event_id) {
            sys.WIFI_EVENT_STA_START => {
                idf.wifi.connect() catch |err|
                    log.err("connect() failed: {s}", .{@errorName(err)});
            },
            sys.WIFI_EVENT_STA_DISCONNECTED => {
                self.retry_count += 1;
                log.warn("disconnected, retry {}", .{self.retry_count});
                idf.wifi.connect() catch |err|
                    log.err("connect() failed: {s}", .{@errorName(err)});
            },
            else => {},
        }
    } else if (event_base == sys.IP_EVENT) {
        if (event_id == sys.IP_EVENT_STA_GOT_IP) {
            const ev = @as(*sys.ip_event_got_ip_t, @ptrCast(@alignCast(event_data)));
            const ip = ev.ip_info.ip.addr;
            log.debug("got IP: {}.{}.{}.{}", .{
                @as(u8, @truncate(ip)),
                @as(u8, @truncate(ip >> 8)),
                @as(u8, @truncate(ip >> 16)),
                @as(u8, @truncate(ip >> 24)),
            });
            self.retry_count = 0;
            if (blocking_task) |h| {
                idf.rtos.Task.notify(h, 0, sys.eSetValueWithOverwrite, 0) catch {};
            }
        }
    }
}

fn copyZ(dest: []u8, src: []const u8) void {
    const n = @min(dest.len - 1, src.len);
    @memcpy(dest[0..n], src[0..n]);
    dest[n] = 0;
}

fn nvsGetStr(handle: idf.nvs.Handle, key: [*:0]const u8, buf: []u8) ![]u8 {
    var key_len: usize = 0;
    try idf.nvs.getStr(handle, key, null, &key_len);
    if (key_len == 0) return buf[0..0];
    try idf.nvs.getStr(handle, key, buf.ptr, &key_len);
    return buf[0 .. key_len - 1];
}

fn sntpCallback(_: [*c]sys.struct_timeval) callconv(.c) void {
    if (blocking_task) |h| {
        idf.rtos.Task.notify(h, 0, sys.eSetValueWithOverwrite, 0) catch {};
    }
}
