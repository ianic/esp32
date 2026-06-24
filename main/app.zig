const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const mem = std.mem;

comptime {
    @export(&main, .{ .name = "app_main" });
}

fn main() callconv(.c) void {
    // This allocator is safe to use as the backing allocator w/ arena allocator

    // custom allocators (based on old raw_c_allocator)
    // idf.heap.HeapCapsAllocator
    // idf.heap.MultiHeapAllocator
    // idf.heap.VPortAllocator

    var heap = idf.heap.HeapCapsAllocator.init(.{ .@"8bit" = true });
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    log.info("Hello, world from Zig!", .{});

    log.info(
        \\[Zig Info]
        \\* Version: {s}
        \\* Compiler Backend: {s}
    , .{
        @as([]const u8, builtin.zig_version_string),
        @tagName(builtin.zig_backend),
    });

    log.info(
        \\[ESP-IDF Info]
        \\* Version: {s}
    , .{ver.get().toString(allocator)});

    log.info(
        \\[Memory Info]
        \\* Total: {d}
        \\* Free: {d}
        \\* Minimum: {d}
    , .{
        heap.totalSize(),
        heap.freeSize(),
        heap.minimumFreeSize(),
    });

    log.info("Let's have a look at your shiny {s} - {s} system! :)", .{
        @tagName(builtin.cpu.arch),
        builtin.cpu.model.name,
    });

    if (builtin.mode == .Debug)
        heap.dump();
}

pub const panic = idf.esp_panic.panic;
const log = std.log.scoped(idf.log.default_log_scope);
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = idf.log.espLogFn,
};
