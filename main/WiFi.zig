const std = @import("std");
const idf = @import("esp_idf");
const sys = idf.sys;

const log = std.log.scoped(.wifi);

retry_count: u32 = 0,
blocking_task: idf.rtos.TaskHandle = null,

const Self = @This();

pub fn init(self: *Self, ssid: [*:0]const u8, pwd: [*:0]const u8, authmode: u8) !void {
    // Network interface + default event loop
    try idf.err.espCheckError(sys.esp_netif_init());
    try idf.event.loopCreateDefault();
    _ = sys.esp_netif_create_default_wifi_sta();

    // WiFi driver init
    var wifi_init_cfg = idf.wifi.init_config_default();
    try idf.err.espCheckError(sys.esp_wifi_init(&wifi_init_cfg));

    // Register event handlers (new wrapper API)
    _ = try idf.event.handlerInstanceRegister(sys.WIFI_EVENT, idf.event.ANY_ID, &onWifiEvent, self);
    _ = try idf.event.handlerInstanceRegister(sys.IP_EVENT, sys.IP_EVENT_STA_GOT_IP, &onWifiEvent, self);

    // Build WiFi STA config from sdkconfig values
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

    log.info("WiFi station started, connecting to \"{s}\"...", .{ssid});

    _ = idf.rtos.Task.notifyWait(
        0, // UBaseType notification index
        0, // which bits to clear in the task's notification value before waiting
        0xff_ff_ff_ff, //  which bits to clear in the task's notification value after the notification is received
        null,
        sys.portMAX_DELAY, // ticks to wait
    );
}

pub fn initBlocking(self: *Self, ssid: [*:0]const u8, pwd: [*:0]const u8, authmode: u8) !void {
    self.blocking_task = idf.rtos.Task.getCurrent();
    try self.init(ssid, pwd, authmode);
    self.blocking_task = null;
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
                log.info("STA started, connecting...", .{});
                idf.wifi.connect() catch |err|
                    log.err("connect() failed: {s}", .{@errorName(err)});
            },
            sys.WIFI_EVENT_STA_DISCONNECTED => {
                self.retry_count += 1;
                log.warn("Disconnected, retry {}", .{self.retry_count});
                idf.wifi.connect() catch {};
            },
            else => {},
        }
    } else if (event_base == sys.IP_EVENT) {
        if (event_id == sys.IP_EVENT_STA_GOT_IP) {
            const ev = @as(*sys.ip_event_got_ip_t, @ptrCast(@alignCast(event_data)));
            const ip = ev.ip_info.ip.addr;
            log.info("Got IP: {}.{}.{}.{}", .{
                @as(u8, @truncate(ip)),
                @as(u8, @truncate(ip >> 8)),
                @as(u8, @truncate(ip >> 16)),
                @as(u8, @truncate(ip >> 24)),
            });
            self.retry_count = 0;
            if (self.blocking_task) |h| {
                idf.rtos.Task.notify(h, 0, sys.eSetValueWithOverwrite, 0) catch {};
            }
        }
    }
}

fn copyZ(dest: []u8, src: [*:0]const u8) void {
    const n = std.mem.len(src) + 1;
    @memcpy(dest[0..n], src[0..n]);
}
