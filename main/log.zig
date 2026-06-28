const std = @import("std");
const idf = @import("esp_idf");

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const esp_level = comptime idf.log.levelToEsp(level);
    const color = comptime idf.log.levelColor(level);
    const prefix = color ++ "[" ++ comptime level.asText() ++ "] (" ++ @tagName(scope) ++ "): ";

    const tag = "logging";
    const fmt = prefix ++ format ++ idf.log.LOG_RESET_COLOR ++ "\n";

    var buf: [256]u8 = undefined;
    const str: [:0]u8 = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    idf.sys.esp_log_write(esp_level, tag, "%s", str.ptr);
}
