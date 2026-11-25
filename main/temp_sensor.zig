const std = @import("std");
const idf = @import("idf");
const gpio = idf.gpio;
const Pin = gpio.Num();
const testing = std.testing;

const OneWire = struct {
    pin: Pin,

    pub fn init(pin: Pin) OneWire {
        return .{ .pin = pin };
    }

    fn direction(self: OneWire, mode: gpio.Mode) void {
        gpio.Direction.set(self.pin, mode) catch {};
    }

    fn write(self: OneWire, level: u1) void {
        gpio.Level.set(self.pin, level) catch {};
    }

    fn read(self: OneWire) u1 {
        return if (idf.gpio.Level.get(self.pin)) 1 else 0;
    }

    // Raises error if no devices are present on the data bus
    pub fn reset(self: OneWire) !void {
        self.direction(.output);

        // bring low for 480us
        self.write(0);
        sleepUs(480);

        self.direction(.input); // let the data line float high
        sleepUs(70);
        const presence = self.read() == 0; // see if any devices are pulling the data line low
        sleepUs(410);

        if (!presence) return error.NoDevices;
    }

    fn putBit(self: OneWire, bit: bool) void {
        self.direction(.output);

        self.write(0);
        sleepUs(3);
        if (bit) {
            self.write(1);
            sleepUs(55);
        } else {
            sleepUs(60);
            self.write(1);
            sleepUs(5);
        }
    }

    fn getBit(self: OneWire) bool {
        self.direction(.output);
        self.write(0);
        sleepUs(3);

        self.direction(.input);
        sleepUs(3);
        const res = self.read() == 1;
        sleepUs(45);

        return res;
    }

    fn putByte(self: OneWire, b: u8) void {
        var byte = b;
        for (0..8) |_| {
            self.putBit(byte & 0x01 > 0);
            byte = byte >> 1;
        }
    }

    fn getByte(self: OneWire) u8 {
        var byte: u8 = 0;
        for (0..8) |_| {
            byte = byte >> 1;
            if (self.getBit()) {
                byte = byte | 0x80;
            }
        }
        return byte;
    }
};

fn sleepUs(us: u32) void {
    idf.sys.esp_rom_delay_us(us);
}

// DS18B20
pub const TempSensor = struct {
    ow: OneWire,

    pub fn init(pin: Pin) TempSensor {
        return .{ .ow = .init(pin) };
    }

    // Initiates a single temperature conversion
    // Leave 750ms before reading
    pub fn convert(self: TempSensor) !void {
        try self.ow.reset();
        self.ow.putByte(0xcc);
        self.ow.putByte(0x44);
    }

    pub fn read(self: TempSensor) !struct { u16, f32 } {
        // read the contents of the scratchpad
        try self.ow.reset();
        self.ow.putByte(0xcc);
        self.ow.putByte(0xbe);
        var res: [9]u8 = @splat(0);
        for (&res) |*r| {
            const b = self.ow.getByte();
            r.* = b;
        }
        // check crc
        if (crc(res[0..8]) != res[8]) return error.CrcFail;
        // temperature bytes
        const lsb = res[0];
        const msb = res[1];
        const temp: u16 = ((@as(u16, @intCast(msb)) << 8) | lsb);
        return .{ temp, @as(f32, @floatFromInt(temp)) / 16 };
    }

    fn crc(bytes: []const u8) u8 {
        var res: u8 = 0;
        for (bytes) |byte| {
            var b = byte;
            for (0..8) |_| {
                const mix = ((res ^ b) & 0x01) > 0;
                res >>= 1;
                if (mix) res ^= 0x8C;
                b >>= 1;
            }
        }
        return res;
    }

    test crc {
        const data: [8]u8 = .{ 112, 1, 0, 0, 127, 225, 60, 170 };
        try std.testing.expectEqual(103, crc(&data));
    }
};

test {
    _ = TempSensor;
    _ = SensorHealth;
}

pub const SensorHealth = struct {
    measurements: u32 = 0,
    successes: u32 = 0,
    failures: u32 = 0,
    recent: u32 = 0,

    pub fn success(self: *SensorHealth) void {
        self.measurements += 1;
        self.successes += 1;
        self.recent = (self.recent << 1) | 1;
    }

    pub fn fail(self: *SensorHealth) void {
        self.measurements += 1;
        self.failures += 1;
        self.recent = (self.recent << 1);
    }

    pub fn healthy(self: *SensorHealth) bool {
        if (self.measurements < 32) {
            if (self.successes > self.failures and self.successes - self.failures < 2) return true;
            return false;
        }
        return @popCount(self.recent) >= 30;
    }

    test {
        var sh: SensorHealth = .{};
        sh.success();
        try std.testing.expect(sh.healthy());
        sh.fail();
        try std.testing.expect(!sh.healthy());
        for (0..30) |_| {
            sh.success();
        }
        try std.testing.expect(sh.healthy());
        try testing.expectEqual(31, @popCount(sh.recent));

        sh.fail();
        try std.testing.expect(sh.healthy());
        try testing.expectEqual(30, @popCount(sh.recent));
        sh.fail();
        try std.testing.expect(sh.healthy());
        try testing.expectEqual(30, @popCount(sh.recent));
        sh.fail();
        try std.testing.expect(!sh.healthy());
        try testing.expectEqual(29, @popCount(sh.recent));
    }
};

pub const Target = struct {
    day: u8, // 1/2 celsisus
    night: u8,
    day_from: u8, // 1/2 hour
    day_to: u8,

    pub const default: Target = .{
        .day = 22 * 2,
        .night = 15 * 2,
        .day_from = 7 * 2,
        .day_to = 23 * 2,
    };

    pub fn get(self: Target, ts: u32) u16 {
        const sec = ts % 86400;
        const sec_from: u32 = @as(u32, self.day_from) * 1800;
        const sec_to: u32 = @as(u32, self.day_to) * 1800;
        if ((sec_from < sec_to and (sec >= sec_from and sec < sec_to)) or
            (sec_from > sec_to and (sec >= sec_from or sec < sec_to)))
        {
            return @as(u16, self.day) * 4;
        }
        return @as(u16, self.night) * 4;
    }

    test {
        var t: Target = .{
            .day = 22 * 2,
            .night = 15 * 2,
            .day_from = 7 * 2,
            .day_to = 23 * 2,
        };
        try testing.expectEqual(15 * 8, t.get(0));
        try testing.expectEqual(15 * 8, t.get(7 * 3600 - 1));
        try testing.expectEqual(22 * 8, t.get(7 * 3600));
        try testing.expectEqual(22 * 8, t.get(23 * 3600 - 1));
        try testing.expectEqual(15 * 8, t.get(23 * 3600));
        t = .{
            .day = 22 * 2,
            .night = 15 * 2,
            .day_from = 10 * 2,
            .day_to = 1 * 2,
        };
        try testing.expectEqual(22 * 8, t.get(0));
        try testing.expectEqual(22 * 8, t.get(1 * 3600 - 1));
        try testing.expectEqual(15 * 8, t.get(1 * 3600));
        try testing.expectEqual(15 * 8, t.get(10 * 3600 - 1));
        try testing.expectEqual(22 * 8, t.get(10 * 3600));
        try testing.expectEqual(22 * 8, t.get(23 * 3600));
    }
};

pub const Relay = struct {
    last_change: u32 = 0,
    heating: u1 = 0,
    target: Target,

    pub fn set(self: *Relay, ts: u32, temp: u16) bool {
        if (ts - self.last_change < 60) return false;
        const target_temp = self.target.get(ts);
        if (target_temp > temp and self.heating == 0 and target_temp - temp >= 4) {
            self.last_change = ts;
            self.heating = 1;
            return true;
        }
        if (target_temp < temp and self.heating == 1 and temp - target_temp >= 4) {
            self.last_change = ts;
            self.heating = 0;
            return true;
        }
        return false;
    }

    test {
        const target: Target = .{
            .day = 22 * 2,
            .night = 15 * 2,
            .day_from = 7 * 2,
            .day_to = 23 * 2,
        };
        var r: Relay = .{ .target = target };
        try testing.expect(!r.set(0, 20 * 8));
        try testing.expect(!r.set(0, 10 * 8));
        try testing.expect(r.heating == 0);
        try testing.expect(r.set(60, 10 * 8));
        try testing.expect(r.heating == 1);
        try testing.expect(!r.set(119, 22 * 8));
        try testing.expect(!r.set(120, 15 * 8));
        try testing.expect(r.heating == 1);
        try testing.expect(r.set(120, 15 * 8 + 4));
        try testing.expect(r.heating == 0);
        try testing.expectEqual(120, r.last_change);
    }
};

test {
    _ = Target;
    _ = Relay;
}
