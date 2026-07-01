const std = @import("std");
const idf = @import("idf");
const gpio = idf.gpio;
const Pin = gpio.Num();

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
        const temp: u16 = (@as(u16, @intCast(msb)) << 8 | lsb);
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
}
