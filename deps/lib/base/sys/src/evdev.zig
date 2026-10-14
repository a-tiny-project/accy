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

/// Bytes a virtual device's name may hold, the kernel's `UINPUT_MAX_NAME_SIZE`
/// less its terminating zero.
pub const virtual_name_capacity: usize = 79;
/// Keys and axes one virtual device may declare. A gamepad declares about 20
/// keys and 8 axes.
pub const virtual_key_capacity: usize = 64;
pub const virtual_axis_capacity: usize = abs_bit_count;

pub const VirtualError = error{
    UnsupportedPlatform,
    AccessDenied,
    OpenFailed,
    /// The options name more keys or axes than the capacities above, a name
    /// longer than `virtual_name_capacity`, or a code outside the kernel's
    /// key or axis range.
    InvalidOptions,
    CreateFailed,
    WriteFailed,
};

/// One absolute axis of a virtual device and the range it reports.
pub const VirtualAxis = struct {
    code: u16,
    minimum: i32,
    maximum: i32,
    fuzz: i32 = 0,
    flat: i32 = 0,
};

pub const VirtualOptions = struct {
    name: []const u8,
    /// The kernel's `BUS_VIRTUAL`.
    bus: u16 = 0x06,
    vendor: u16 = 0,
    product: u16 = 0,
    version: u16 = 1,
    keys: []const u16,
    axes: []const VirtualAxis,
};

/// One change a virtual device reports: a key's state (0 up, 1 down) or an
/// axis's value.
pub const Change = struct {
    kind: u16,
    code: u16,
    value: i32,
};

/// A device the kernel creates through `/dev/uinput`, which every reader of
/// `/dev/input` sees as hardware. Reports reach readers when `emit` writes
/// them, each batch closed by a synchronization report.
pub const Virtual = struct {
    fd: i32,

    pub fn create(path: []const u8, options: VirtualOptions) VirtualError!Virtual {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (options.name.len == 0 or options.name.len > virtual_name_capacity) return error.InvalidOptions;
        if (options.keys.len > virtual_key_capacity) return error.InvalidOptions;
        if (options.axes.len > virtual_axis_capacity) return error.InvalidOptions;
        for (options.keys) |code| if (code >= key_bit_count) return error.InvalidOptions;
        for (options.axes) |entry| if (entry.code >= abs_bit_count) return error.InvalidOptions;

        var path_buffer: [128]u8 = undefined;
        if (path.len >= path_buffer.len) return error.OpenFailed;
        @memcpy(path_buffer[0..path.len], path);
        path_buffer[path.len] = 0;
        const rc = linux.open(
            path_buffer[0..path.len :0],
            .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true },
            0,
        );
        const fd: i32 = switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.OpenFailed,
        };
        errdefer _ = linux.close(fd);

        try control(fd, uinput.set_event_bit, event_kind.syn);
        if (options.keys.len > 0) try control(fd, uinput.set_event_bit, event_kind.key);
        for (options.keys) |code| try control(fd, uinput.set_key_bit, code);
        if (options.axes.len > 0) try control(fd, uinput.set_event_bit, event_kind.abs);
        for (options.axes) |entry| {
            try control(fd, uinput.set_abs_bit, entry.code);
            var setup = UinputAbsSetup{
                .code = entry.code,
                .info = .{
                    .value = 0,
                    .minimum = entry.minimum,
                    .maximum = entry.maximum,
                    .fuzz = entry.fuzz,
                    .flat = entry.flat,
                    .resolution = 0,
                },
            };
            try control(fd, uinput.abs_setup, @intFromPtr(&setup));
        }
        var setup = UinputSetup{
            .bus = options.bus,
            .vendor = options.vendor,
            .product = options.product,
            .version = options.version,
            .name = @splat(0),
            .effects_max = 0,
        };
        @memcpy(setup.name[0..options.name.len], options.name);
        try control(fd, uinput.device_setup, @intFromPtr(&setup));
        try control(fd, uinput.device_create, 0);
        return .{ .fd = fd };
    }

    /// Removes the device from every reader and closes it.
    pub fn destroy(self: Virtual) void {
        if (comptime !supported) return;
        _ = linux.ioctl(self.fd, uinput.device_destroy, 0);
        _ = linux.close(self.fd);
    }

    /// Writes the changes and one synchronization report in a single write, so
    /// a reader sees them as one state.
    pub fn emit(self: Virtual, changes: []const Change) VirtualError!void {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (changes.len > virtual_emit_capacity) return error.InvalidOptions;
        var events: [virtual_emit_capacity + 1]InputEvent = undefined;
        for (changes, events[0..changes.len]) |change, *event| {
            event.* = .{
                .seconds = 0,
                .microseconds = 0,
                .kind = change.kind,
                .code = change.code,
                .value = change.value,
            };
        }
        events[changes.len] = .{
            .seconds = 0,
            .microseconds = 0,
            .kind = event_kind.syn,
            .code = 0,
            .value = 0,
        };
        const bytes = std.mem.sliceAsBytes(events[0 .. changes.len + 1]);
        const rc = linux.write(self.fd, bytes.ptr, bytes.len);
        if (linux.errno(rc) != .SUCCESS or rc != bytes.len) return error.WriteFailed;
    }

    /// The kernel's name for the device under `/sys/devices/virtual/input`,
    /// such as `input42`, written into `buffer`.
    pub fn systemName(self: Virtual, buffer: []u8) VirtualError![]const u8 {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (buffer.len == 0 or buffer.len > max_query_bytes) return error.InvalidOptions;
        const request: u32 = (2 << 30) | (@as(u32, @intCast(buffer.len)) << 16) | (@as(u32, 'U') << 8) | 44;
        const rc = linux.ioctl(self.fd, request, @intFromPtr(buffer.ptr));
        if (linux.errno(rc) != .SUCCESS) return error.CreateFailed;
        const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
        return buffer[0..len];
    }
};

/// Changes one `emit` call writes, its synchronization report excluded.
pub const virtual_emit_capacity: usize = 64;

/// The kernel's `struct uinput_setup`.
const UinputSetup = extern struct {
    bus: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [virtual_name_capacity + 1]u8,
    effects_max: u32,
};

/// The kernel's `struct uinput_abs_setup`.
const UinputAbsSetup = extern struct {
    code: u16,
    info: AbsInfo,
};

const uinput = struct {
    fn write(nr: u8, comptime T: type) u32 {
        return (1 << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, 'U') << 8) | nr;
    }

    const device_create: u32 = (@as(u32, 'U') << 8) | 1;
    const device_destroy: u32 = (@as(u32, 'U') << 8) | 2;
    const device_setup = write(3, UinputSetup);
    const abs_setup = write(4, UinputAbsSetup);
    const set_event_bit = write(100, c_int);
    const set_key_bit = write(101, c_int);
    const set_abs_bit = write(103, c_int);
};

fn control(fd: i32, request: u32, argument: usize) VirtualError!void {
    const rc = linux.ioctl(fd, request, argument);
    if (linux.errno(rc) != .SUCCESS) return error.CreateFailed;
}

fn findDevice(name: []const u8) ?Device {
    var path_buffer: [32]u8 = undefined;
    var name_buffer: [virtual_name_capacity + 1]u8 = undefined;
    for (0..256) |index| {
        const path = eventPath(&path_buffer, @intCast(index)) catch unreachable;
        const device = Device.open(path) catch continue;
        const device_name = device.name(&name_buffer) catch {
            device.close();
            continue;
        };
        if (std.mem.eql(u8, device_name, name)) return device;
        device.close();
    }
    return null;
}
