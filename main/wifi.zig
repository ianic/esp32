const std = @import("std");
const builtin = @import("builtin");
const idf = @import("idf");
const log = std.log.scoped(.main);
const lwip = idf.lwip;

var wifi: @import("WiFi.zig") = .{};

fn main() !void {
    try idf.nvs.flashInitOrErase();
    try wifi.initNvs();
}

export fn app_main() callconv(.c) void {
    main() catch |err| {
        log.err("{}", .{err});
    };
}
pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = @import("log.zig").logFn,
};
