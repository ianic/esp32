const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const log = std.log.scoped(.main);
const lwip = idf.lwip;

var wifi: @import("WiFi.zig") = .{};

export fn app_main() callconv(.c) void {
    main() catch |err| {
        log.err("{}", .{err});
    };
}

fn nvsGetStr(handle: idf.nvs.Handle, key: [*:0]const u8, buf: []u8) !struct { [*:0]u8, usize } {
    var key_len: usize = 0;
    try idf.nvs.getStr(handle, key, null, &key_len);
    try idf.nvs.getStr(handle, key, buf.ptr, &key_len);
    return .{ buf[0 .. key_len - 1 :0], key_len };
}

fn main() !void {
    try idf.nvs.flashInitOrErase();

    const ns = try idf.nvs.open("wifi-defaults", .read_only);
    defer idf.nvs.close(ns);
    var buf: [32]u8 = undefined;
    const ssid, const len = try nvsGetStr(ns, "ssid", &buf);
    const pwd, _ = try nvsGetStr(ns, "password", buf[len..]);
    const authmode = try idf.nvs.getU8(ns, "authmode");
    log.debug("nvs.storage: {s} {s} {}", .{ ssid, pwd, authmode });

    try wifi.initBlocking(ssid, pwd, authmode);

    // Create UDP socket (AF_INET = IPv4, SOCK_DGRAM = UDP)
    const socket = try lwip.Socket.create(idf.sys.AF_INET, idf.sys.SOCK_DGRAM, 0);
    defer socket.close() catch {};

    // Bind to local address (optional for sending only)
    var local_addr: lwip.SockAddrIn = undefined;
    local_addr.sin_family = idf.sys.AF_INET;
    local_addr.sin_port = lwip.htons(8080);
    local_addr.sin_addr.s_addr = idf.sys.INADDR_ANY;

    socket.bind(@ptrCast(&local_addr), @sizeOf(lwip.SockAddrIn)) catch |err| {
        std.log.err("Bind failed: {}", .{err});
    };

    // Send UDP packet
    var dest_addr: lwip.SockAddrIn = undefined;
    dest_addr.sin_family = idf.sys.AF_INET;
    dest_addr.sin_port = lwip.htons(8080);
    dest_addr.sin_addr.s_addr = idf.sys.ipaddr_addr("192.168.207.181");
    //dest_addr.sin_addr.s_addr = idf.sys.ipaddr_addr("192.168.190.235");

    const message = "Hello UDP";
    _ = try socket.sendTo(message, 0, @ptrCast(&dest_addr), @sizeOf(lwip.SockAddrIn));

    // Receive UDP packet
    var recv_buf: [256]u8 = undefined;
    var from_addr: lwip.SockAddrIn = undefined;
    var from_len: lwip.SockLen = @sizeOf(lwip.SockAddrIn);

    const n = socket.recvFrom(&recv_buf, 0, @ptrCast(&from_addr), &from_len) catch |err| brk: {
        std.log.err("Recv failed: {}", .{err});
        break :brk 0;
    };

    if (n > 0) {
        std.log.info("Received {} bytes", .{n});
    }

    _ = idf.rtos.Task.getName(null);
    idf.rtos.Task.delete(null);
    const hwm = idf.rtos.Task.getStackHighWaterMark(null);
    log.debug("stack high water mark {}", .{hwm});
}

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = @import("log.zig").logFn,
};
