const std = @import("std");
const builtin = @import("builtin");
const idf = @import("idf");
const ver = idf.ver.Version;
const mem = std.mem;
const led = idf.led;

export fn app_main() callconv(.c) void {
    main() catch |err| {
        log.err("main failed {}", .{err});
    };
}

fn main() !void {
    log.info("LED Strip Example", .{});

    var led_strip: led.LedStripHandle = null;
    { // Configure and initialize LED strip
        const strip_config = led.LedStripConfig.ws2812(8, 1);
        const rmt_config = led.LedStripRmtConfig.default;
        _ = try led.newRmtDevice(&strip_config, &rmt_config, &led_strip);
    }

    // Increase stack size if you use logging in the functions, add >1K for logging
    const led_task = try idf.rtos.Task.create(ledTask, "led", 1024, led_strip, 5);
    _ = try idf.rtos.Task.create(sendColorTask, "change color", 512, led_task, 5);

    log.info("LED strip task started successfully", .{});
}

fn sendColorTask(ptr: ?*anyopaque) callconv(.c) void {
    const led_task: idf.rtos.TaskHandle = @ptrCast(@alignCast(ptr.?));
    const pallete = [_]u24{
        // === HIGHLY DISTINCT PRIMARY & SECONDARY ===
        0xFF0000, // 1. Pure Red       (Highly distinct)
        0x00FF00, // 2. Pure Green     (Brilliant, deep green)
        0x0000FF, // 3. Pure Blue      (Deep blue)
        0xFF00FF, // 4. Magenta        (Strong red-blue mix)
        0xFFFF00, // 5. Yellow         (Warm, stark contrast to green)
        0x00FFFF, // 6. Cyan           (Bright icy blue, distinctly non-blue)

        // === CONTRAST-CORRECTED INTERMEDIATES ===
        0xFF4000, // 7. Hardware Orange (Green slashed to 0x40 so it doesn't look yellow/green)
        0x10FF40, // 8. Mint Green     (Heavy green with a splash of blue/red to stand out)
        0x0080FF, // 9. Sky Blue       (A crisp, electric cyan-blue intermediate)
        0x7F00FF, // 10. Deep Purple   (A clean violet, far less red than Magenta)
        0xFF0055, // 11. Hot Pink      (A sharp pink, distinct from both Red and Magenta)
        0xFFFFFF, // 12. Solid White   (All channels active, completely neutral)

    };
    while (true) {
        for (pallete) |rgb| {
            idf.rtos.Task.notify(
                led_task,
                rgb, // u32 value to send
                idf.sys.eSetValueWithOverwrite, // sys.eNotifyAction (e.g., eSetBits, eIncrement)
                0, // UBaseType notification index
            ) catch {};
            idf.rtos.Task.delayMs(2000);
            // const hwm = idf.rtos.Task.getStackHighWaterMark(null);
            // log.debug("sendColorTask stack high water mark {}", .{hwm});
        }
    }
}

fn ledTask(ptr: ?*anyopaque) callconv(.c) void {
    _ledTask(ptr) catch {
        //log.err("led strip task failed {}", .{err});
        @panic("led strip task failed");
    };
    // TODO delete task or panic or...
}

fn _ledTask(ptr: ?*anyopaque) !void {
    const led_strip: led.LedStripHandle = @ptrCast(@alignCast(ptr.?));

    while (true) {
        var rgb: u32 = 0;
        if (!idf.rtos.Task.notifyWait(
            0, // UBaseType notification index
            0, // which bits to clear in the task's notification value before waiting
            0xff_ff_ff_ff, //  which bits to clear in the task's notification value after the notification is received
            &rgb, // Optional: pointer to receive the u32 value
            idf.sys.portMAX_DELAY, // ticks to wait
        )) continue;

        const r = (rgb & 0xff0000) >> 16;
        const g = (rgb & 0x00ff00) >> 8;
        const b = (rgb & 0x0000ff);
        //log.debug("rgb {x} {x} {x}", .{ r, g, b });
        try led.setPixel(led_strip, 0, @truncate(r), @truncate(g), @truncate(b));
        try led.refresh(led_strip);

        // const hwm = idf.rtos.Task.getStackHighWaterMark(null);
        // log.debug("LedTask stack high water mark {}", .{hwm});
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
    .logFn = @import("log.zig").logFn,
};
