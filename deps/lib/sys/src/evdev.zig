const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .linux;
pub const max_query_bytes: usize = std.math.maxInt(u14);

pub const Error = error{
    UnsupportedPlatform,
    AccessDenied,
    OpenFailed,
    QueryFailed,
    ReadFailed,
};

pub const event_kind = struct {
    pub const syn: u16 = 0x00;
    pub const key: u16 = 0x01;
    pub const abs: u16 = 0x03;
};

pub const button = struct {
    pub const south: u16 = 0x130;
    pub const east: u16 = 0x131;
    pub const north: u16 = 0x133;
    pub const west: u16 = 0x134;
    pub const left_bumper: u16 = 0x136;
    pub const right_bumper: u16 = 0x137;
    pub const select: u16 = 0x13A;
    pub const start: u16 = 0x13B;
    pub const mode: u16 = 0x13C;
    pub const left_thumb: u16 = 0x13D;
    pub const right_thumb: u16 = 0x13E;
    pub const dpad_up: u16 = 0x220;
    pub const dpad_down: u16 = 0x221;
    pub const dpad_left: u16 = 0x222;
    pub const dpad_right: u16 = 0x223;
    pub const gamepad_marker: u16 = south;
};

pub const axis = struct {
    pub const x: u16 = 0x00;
    pub const y: u16 = 0x01;
    pub const z: u16 = 0x02;
    pub const rx: u16 = 0x03;
    pub const ry: u16 = 0x04;
    pub const rz: u16 = 0x05;
    pub const hat0x: u16 = 0x10;
    pub const hat0y: u16 = 0x11;
};

pub const key_bit_count = 0x300;
pub const abs_bit_count = 0x40;
pub const KeyBits = [key_bit_count / 8]u8;
pub const AbsBits = [abs_bit_count / 8]u8;

pub const InputEvent = extern struct {
    seconds: u64,
    microseconds: u64,
    kind: u16,
    code: u16,
    value: i32,
};

pub const AbsInfo = extern struct {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
};

pub fn hasBit(bits: []const u8, index: u16) bool {
    const byte = index / 8;
    if (byte >= bits.len) return false;
    return (bits[byte] >> @intCast(index % 8)) & 1 != 0;
}

pub fn isGamepad(key_bits: *const KeyBits) bool {
    return hasBit(key_bits, button.gamepad_marker);
}

pub fn normalizeAxis(info: AbsInfo, value: i32) f32 {
    if (info.maximum <= info.minimum) return 0;
    const span: f32 = @floatFromInt(info.maximum - info.minimum);
    const offset: f32 = @floatFromInt(value - info.minimum);
    const unit = (offset / span) * 2.0 - 1.0;
    return std.math.clamp(unit, -1.0, 1.0);
}

pub fn normalizeTrigger(info: AbsInfo, value: i32) f32 {
    if (info.maximum <= info.minimum) return 0;
    const span: f32 = @floatFromInt(info.maximum - info.minimum);
    const offset: f32 = @floatFromInt(value - info.minimum);
    return std.math.clamp(offset / span, 0.0, 1.0);
}

pub fn eventPath(buffer: []u8, index: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "/dev/input/event{d}", .{index});
}

const linux = std.os.linux;

fn ioctlRead(fd: i32, nr: u8, out: []u8) Error!void {
    if (comptime !supported) return error.UnsupportedPlatform;
    if (out.len > max_query_bytes) return error.QueryFailed;
    const request: u32 = (2 << 30) | (@as(u32, @intCast(out.len)) << 16) | (@as(u32, 'E') << 8) | nr;
    const rc = linux.ioctl(fd, request, @intFromPtr(out.ptr));
    if (linux.errno(rc) != .SUCCESS) return error.QueryFailed;
}

pub const Device = struct {
    fd: i32,

    pub fn open(path: []const u8) Error!Device {
        if (comptime !supported) return error.UnsupportedPlatform;
        var path_buffer: [128]u8 = undefined;
        if (path.len >= path_buffer.len) return error.OpenFailed;
        @memcpy(path_buffer[0..path.len], path);
        path_buffer[path.len] = 0;
        const rc = linux.open(
            path_buffer[0..path.len :0],
            .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true },
            0,
        );
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            .ACCES, .PERM => error.AccessDenied,
            else => error.OpenFailed,
        };
    }

    pub fn close(self: Device) void {
        if (comptime !supported) return;
        _ = linux.close(self.fd);
    }

    pub fn name(self: Device, buffer: []u8) Error![]const u8 {
        try ioctlRead(self.fd, 0x06, buffer);
        const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
        return buffer[0..len];
    }

    pub fn keyBits(self: Device, bits: *KeyBits) Error!void {
        @memset(bits, 0);
        try ioctlRead(self.fd, 0x20 + @as(u8, @intCast(event_kind.key)), bits);
    }

    pub fn absBits(self: Device, bits: *AbsBits) Error!void {
        @memset(bits, 0);
        try ioctlRead(self.fd, 0x20 + @as(u8, @intCast(event_kind.abs)), bits);
    }

    pub fn absInfo(self: Device, code: u16) Error!AbsInfo {
        var info: AbsInfo = undefined;
        try ioctlRead(self.fd, 0x40 + @as(u8, @intCast(code)), std.mem.asBytes(&info));
        return info;
    }

    pub fn readEvents(self: Device, events: []InputEvent) Error!usize {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (events.len == 0) return 0;
        const rc = linux.read(self.fd, @ptrCast(events.ptr), events.len * @sizeOf(InputEvent));
        return switch (linux.errno(rc)) {
            .SUCCESS => @as(usize, @intCast(rc)) / @sizeOf(InputEvent),
            .AGAIN => 0,
            else => error.ReadFailed,
        };
    }
};

test "bit probing reads packed capability masks" {
    var bits: KeyBits = @splat(0);
    bits[button.gamepad_marker / 8] = 1 << (button.gamepad_marker % 8);
    try std.testing.expect(hasBit(&bits, button.gamepad_marker));
    try std.testing.expect(isGamepad(&bits));
    try std.testing.expect(!hasBit(&bits, button.start));

    const empty: KeyBits = @splat(0);
    try std.testing.expect(!isGamepad(&empty));
    try std.testing.expect(!hasBit(empty[0..1], 800));
}

test "axis normalization spans the device range" {
    const info = AbsInfo{ .value = 0, .minimum = -32768, .maximum = 32767, .fuzz = 0, .flat = 0, .resolution = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), normalizeAxis(info, -32768), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), normalizeAxis(info, 32767), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), normalizeAxis(info, 0), 0.01);

    const trigger = AbsInfo{ .value = 0, .minimum = 0, .maximum = 255, .fuzz = 0, .flat = 0, .resolution = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), normalizeTrigger(trigger, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), normalizeTrigger(trigger, 255), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), normalizeTrigger(trigger, 128), 0.01);

    const degenerate = AbsInfo{ .value = 0, .minimum = 5, .maximum = 5, .fuzz = 0, .flat = 0, .resolution = 0 };
    try std.testing.expectEqual(@as(f32, 0), normalizeAxis(degenerate, 5));
}

test "input event layout matches the kernel wire size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("/dev/input/event7", try eventPath(&buffer, 7));
}

test "query buffers reject lengths outside the ioctl encoding" {
    if (comptime !supported) return error.SkipZigTest;
    var oversized: [max_query_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.QueryFailed, ioctlRead(-1, 0, &oversized));
}
