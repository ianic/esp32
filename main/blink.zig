const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const ver = idf.ver.Version;
const mem = std.mem;
const led = idf.led;

comptime {
    @export(&main, .{ .name = "app_main" });
}

fn main() callconv(.c) void {
    _main() catch |err| {
        log.err("main failed {}", .{err});
    };
}

fn _main() !void {
    log.info("LED Strip Example", .{});

    var led_strip: led.LedStripHandle = null;
    { // Configure and initialize LED strip
        const strip_config = led.LedStripConfig.ws2812(8, 1);
        const rmt_config = led.LedStripRmtConfig.default;
        _ = try led.newRmtDevice(&strip_config, &rmt_config, &led_strip);
    }

    // Create LED strip control task
    _ = try idf.rtos.Task.create(ledStripTask, "led_strip", 1024 * 4, led_strip, 5);

    log.info("LED strip task started successfully", .{});
}

fn ledStripTask(ptr: ?*anyopaque) callconv(.c) void {
    palette(ptr) catch |err| {
        log.err("led strip task failed {}", .{err});
    };
    // TODO delete task or panic or...
}

fn rgbOff(ptr: ?*anyopaque) !void {
    const led_strip: led.LedStripHandle = @ptrCast(@alignCast(ptr.?));
    var led_on_off: usize = 0;

    log.info("Start blinking LED strip", .{});

    while (true) {
        if (led_on_off % 4 == 0) {
            try led.clear(led_strip); // Set all LED off to clear all pixels
            log.info("LED OFF!", .{});
        } else {
            const red: u8 = if (led_on_off % 4 == 1) 0xff else 0;
            const green: u8 = if (led_on_off % 4 == 2) 0xff else 0;
            const blue: u8 = if (led_on_off % 4 == 3) 0xff else 0;
            try led.setPixel(led_strip, 0, red, green, blue);
            try led.refresh(led_strip); // Refresh the strip to send data
            log.info("LED ON {}!", .{led_on_off});
        }

        led_on_off += 1;
        idf.rtos.Task.delayMs(1000);
    }
}

fn palette(ptr: ?*anyopaque) !void {
    const led_strip: led.LedStripHandle = @ptrCast(@alignCast(ptr.?));
    const colors = [_]u24{
        // Retro Neon Palette
        0xFF0000, // Pure Red
        0x00FF00, // Pure Green
        0x0000FF, // Pure Blue
        0xFF00FF, // Magenta
        0x00FFFF, // Cyan
        0xFFFF00, // Yellow
        // Vaporwave Cyberpunk
        0xFF0055, // Hot Pink
        0x9900FF, // Deep Purple
        0x0022FF, // Electric Blue
        0x00FFCC, // Bright Teal
        0xFF5500, // Neon Orange
        0x330033, // Dim Night-Glow
        // Aurora Borealis
        0x00FF33, // Bright Mint
        0x00AAFF, // Sky Blue
        0x000088, // Deep Royal Blue
        0x7700FF, // Violet
        0x00FF88, // Emerald Green
        0x113300, // Forest Undertone
    };
    while (true) {
        for (colors) |rgb| {
            const r = (rgb & 0xff0000) >> 16;
            const g = (rgb & 0x00ff00) >> 8;
            const b = (rgb & 0x0000ff);
            log.info("rgb {x} {x} {x}", .{ r, g, b });
            try led.setPixel(led_strip, 0, @truncate(r), @truncate(g), @truncate(b));
            try led.refresh(led_strip);
            idf.rtos.Task.delayMs(1000);
        }
    }
}

fn allColors(ptr: ?*anyopaque) !void {
    const led_strip: led.LedStripHandle = @ptrCast(@alignCast(ptr.?));

    while (true) {
        for (0..0xff) |r| {
            for (0..0xff) |g| {
                for (0..0xff) |b| {
                    try led.setPixel(led_strip, 0, @truncate(r), @truncate(g), @truncate(b));
                    try led.refresh(led_strip);
                    idf.rtos.Task.delayMs(1);
                }
            }
        }
    }
}

// Override the std panic function with idf.panic
pub const panic = idf.esp_panic.panic;

const log = std.log.scoped(.@"led-strip");
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    // Define logFn to override the std implementation
    .logFn = idf.log.espLogFn,
};
