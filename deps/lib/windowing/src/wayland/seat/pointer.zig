const std = @import("std");
const native = @import("wayland");
const windowing = @import("../../root.zig");

const core = native.protocol.core;
const runtime = native.runtime;

pub const max_version: u32 = 9;

pub const Position = struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const ButtonState = enum(u32) {
    released = 0,
    pressed = 1,
};

pub const AxisSource = enum(u32) {
    wheel = 0,
    finger = 1,
    continuous = 2,
    wheel_tilt = 3,
};

pub const RelativeDirection = enum(u32) {
    identical = 0,
    inverted = 1,
};

pub const AxisUnit = enum {
    none,
    continuous,
    discrete,
    value120,
};

pub const EnterEvent = struct {
    serial: u32,
    surface: u32,
    position: Position,
};

pub const LeaveEvent = struct {
    serial: u32,
    surface: u32,
    position: Position,
};

pub const MotionEvent = struct {
    time: u32,
    surface: ?u32,
    position: Position,
};

pub const ButtonEvent = struct {
    serial: u32,
    time: u32,
    surface: ?u32,
    position: Position,
    button: windowing.MouseButton,
    state: ButtonState,
};

pub const AxisValue = struct {
    delta: f64 = 0,
    unit: AxisUnit = .none,
    motion_time: ?u32 = null,
    stop_time: ?u32 = null,
    relative_direction: ?RelativeDirection = null,
};

pub const AxisEvent = struct {
    surface: ?u32,
    position: Position,
    source: ?AxisSource,
    horizontal: AxisValue,
    vertical: AxisValue,
};

pub const Callbacks = struct {
    entered: ?*const fn (context: *anyopaque, event: EnterEvent) void = null,
    left: ?*const fn (context: *anyopaque, event: LeaveEvent) void = null,
    moved: ?*const fn (context: *anyopaque, event: MotionEvent) void = null,
    button: ?*const fn (context: *anyopaque, event: ButtonEvent) void = null,
    axis: ?*const fn (context: *anyopaque, event: AxisEvent) void = null,
};

pub const Pointer = struct {
    context: *anyopaque,
    callbacks: Callbacks,
    object_id: ?u32 = null,
    version: u32 = 0,
    active: bool = false,
    focus_surface: ?u32 = null,
    position: Position = .{},
    enter_serial: ?u32 = null,
    cursor_on_screen: bool = false,
    pending: PendingFrame = .{},

    pub fn init(context: *anyopaque, callbacks: Callbacks) Pointer {
        return .{ .context = context, .callbacks = callbacks };
    }

    pub fn attach(self: *Pointer, object_id: u32, version: u32) void {
        std.debug.assert(self.object_id == null);
        self.object_id = object_id;
        self.version = @min(version, max_version);
        self.active = true;
    }

    pub fn deactivate(self: *Pointer, client: *runtime.Client) void {
        const object_id = self.object_id orelse return;
        if (self.version >= core.wl_pointer.requests.release.since) {
            client.request(object_id, core.wl_pointer.requests.release.opcode, &.{}, &.{}) catch {};
            self.object_id = null;
            self.version = 0;
        }
        self.active = false;
        self.focus_surface = null;
        self.enter_serial = null;
        self.cursor_on_screen = false;
        self.pending = .{};
    }

    pub fn deinit(self: *Pointer, client: *runtime.Client) void {
        self.deactivate(client);
        self.object_id = null;
        self.version = 0;
    }

    pub fn cursorSerial(self: *const Pointer) ?u32 {
        return if (self.active and self.cursor_on_screen) self.enter_serial else null;
    }

    pub fn dispatch(self: *Pointer, event: *runtime.RoutedView) !void {
        if (event.object_id != self.object_id) return error.InvalidPointerEvent;
        if (!self.active) return;
        var decoder = try event.borrowedDecoder();
        switch (event.metadata.opcode) {
            core.wl_pointer.events.enter.opcode => {
                const serial = try decoder.unsigned();
                const surface = (try decoder.object()).raw;
                const x = (try decoder.fixed()).toF64();
                const y = (try decoder.fixed()).toF64();
                try decoder.finish();
                self.handleEnter(serial, surface, .{ .x = x, .y = y });
            },
            core.wl_pointer.events.leave.opcode => {
                const serial = try decoder.unsigned();
                const surface = (try decoder.object()).raw;
                try decoder.finish();
                try self.handleLeave(serial, surface);
            },
            core.wl_pointer.events.motion.opcode => {
                const time = try decoder.unsigned();
                const x = (try decoder.fixed()).toF64();
                const y = (try decoder.fixed()).toF64();
                try decoder.finish();
                self.handleMotion(time, .{ .x = x, .y = y });
            },
            core.wl_pointer.events.button.opcode => {
                const serial = try decoder.unsigned();
                const time = try decoder.unsigned();
                const button = try decoder.unsigned();
                const state = try decoder.unsigned();
                try decoder.finish();
                try self.handleButton(serial, time, button, state);
            },
            core.wl_pointer.events.axis.opcode => {
                const time = try decoder.unsigned();
                const axis = try decoder.unsigned();
                const value = (try decoder.fixed()).toF64();
                try decoder.finish();
                try self.handleAxis(time, axis, value);
            },
            core.wl_pointer.events.frame.opcode => {
                try decoder.finish();
                self.flushAxes();
            },
            core.wl_pointer.events.axis_source.opcode => {
                const source = try decoder.unsigned();
                try decoder.finish();
                try self.handleAxisSource(source);
            },
            core.wl_pointer.events.axis_stop.opcode => {
                const time = try decoder.unsigned();
                const axis = try decoder.unsigned();
                try decoder.finish();
                try self.handleAxisStop(time, axis);
            },
            core.wl_pointer.events.axis_discrete.opcode => {
                const axis = try decoder.unsigned();
                const discrete = try decoder.signed();
                try decoder.finish();
                try self.handleAxisDiscrete(axis, discrete);
            },
            core.wl_pointer.events.axis_value120.opcode => {
                const axis = try decoder.unsigned();
                const value120 = try decoder.signed();
                try decoder.finish();
                try self.handleAxisValue120(axis, value120);
            },
            core.wl_pointer.events.axis_relative_direction.opcode => {
                const axis = try decoder.unsigned();
                const direction = try decoder.unsigned();
                try decoder.finish();
                try self.handleAxisRelativeDirection(axis, direction);
            },
            else => return error.InvalidPointerEvent,
        }
    }

    fn handleEnter(self: *Pointer, serial: u32, surface: u32, position: Position) void {
        self.focus_surface = surface;
        self.position = position;
        self.enter_serial = serial;
        self.cursor_on_screen = true;
        if (self.callbacks.entered) |callback| callback(self.context, .{
            .serial = serial,
            .surface = surface,
            .position = position,
        });
    }

    fn handleLeave(self: *Pointer, serial: u32, surface: u32) !void {
        if (self.focus_surface != surface) return error.InvalidPointerEvent;
        self.focus_surface = null;
        self.enter_serial = null;
        self.cursor_on_screen = false;
        if (self.callbacks.left) |callback| callback(self.context, .{
            .serial = serial,
            .surface = surface,
            .position = self.position,
        });
    }

    fn handleMotion(self: *Pointer, time: u32, position: Position) void {
        self.position = position;
        if (self.callbacks.moved) |callback| callback(self.context, .{
            .time = time,
            .surface = self.focus_surface,
            .position = self.position,
        });
    }

    fn handleButton(self: *Pointer, serial: u32, time: u32, raw_button: u32, raw_state: u32) !void {
        const button = buttonFromLinux(raw_button) orelse return;
        const state: ButtonState = switch (raw_state) {
            0 => .released,
            1 => .pressed,
            else => return error.InvalidPointerEvent,
        };
        if (self.callbacks.button) |callback| callback(self.context, .{
            .serial = serial,
            .time = time,
            .surface = self.focus_surface,
            .position = self.position,
            .button = button,
            .state = state,
        });
    }

    fn handleAxis(self: *Pointer, time: u32, raw_axis: u32, value: f64) !void {
        const axis = self.pending.axis(raw_axis) orelse return error.InvalidPointerEvent;
        self.pending.capture(self.focus_surface, self.position);
        axis.continuous += normalizedDelta(raw_axis, value) orelse return error.InvalidPointerEvent;
        axis.has_continuous = true;
        axis.touched = true;
        axis.motion_time = time;
        if (self.version < core.wl_pointer.events.frame.since) self.flushAxes();
    }

    fn handleAxisSource(self: *Pointer, raw_source: u32) !void {
        self.pending.capture(self.focus_surface, self.position);
        self.pending.source = switch (raw_source) {
            0 => .wheel,
            1 => .finger,
            2 => .continuous,
            3 => .wheel_tilt,
            else => return error.InvalidPointerEvent,
        };
    }

    fn handleAxisStop(self: *Pointer, time: u32, raw_axis: u32) !void {
        const axis = self.pending.axis(raw_axis) orelse return error.InvalidPointerEvent;
        self.pending.capture(self.focus_surface, self.position);
        axis.stop_time = time;
        axis.touched = true;
    }

    fn handleAxisDiscrete(self: *Pointer, raw_axis: u32, discrete: i32) !void {
        const axis = self.pending.axis(raw_axis) orelse return error.InvalidPointerEvent;
        self.pending.capture(self.focus_surface, self.position);
        axis.discrete += normalizedDelta(raw_axis, @floatFromInt(discrete)) orelse return error.InvalidPointerEvent;
        axis.has_discrete = true;
        axis.touched = true;
    }

    fn handleAxisValue120(self: *Pointer, raw_axis: u32, value120: i32) !void {
        const axis = self.pending.axis(raw_axis) orelse return error.InvalidPointerEvent;
        self.pending.capture(self.focus_surface, self.position);
        const steps = @as(f64, @floatFromInt(value120)) / 120.0;
        axis.value120 += normalizedDelta(raw_axis, steps) orelse return error.InvalidPointerEvent;
        axis.has_value120 = true;
        axis.touched = true;
    }

    fn handleAxisRelativeDirection(self: *Pointer, raw_axis: u32, raw_direction: u32) !void {
        const axis = self.pending.axis(raw_axis) orelse return error.InvalidPointerEvent;
        self.pending.capture(self.focus_surface, self.position);
        axis.relative_direction = switch (raw_direction) {
            0 => .identical,
            1 => .inverted,
            else => return error.InvalidPointerEvent,
        };
        axis.touched = true;
    }

    fn flushAxes(self: *Pointer) void {
        if (!self.pending.hasAxisEvent()) return;
        const event = AxisEvent{
            .surface = self.pending.surface,
            .position = self.pending.position,
            .source = self.pending.source,
            .horizontal = self.pending.horizontal.finish(),
            .vertical = self.pending.vertical.finish(),
        };
        self.pending = .{};
        if (self.callbacks.axis) |callback| callback(self.context, event);
    }
};

pub fn buttonFromLinux(code: u32) ?windowing.MouseButton {
    return switch (code) {
        0x110 => .left,
        0x111 => .right,
        0x112 => .middle,
        0x113 => .x1,
        0x114 => .x2,
        else => null,
    };
}

const PendingFrame = struct {
    captured: bool = false,
    surface: ?u32 = null,
    position: Position = .{},
    source: ?AxisSource = null,
    horizontal: PendingAxis = .{},
    vertical: PendingAxis = .{},

    fn capture(self: *PendingFrame, surface: ?u32, position: Position) void {
        if (self.captured) return;
        self.captured = true;
        self.surface = surface;
        self.position = position;
    }

    fn axis(self: *PendingFrame, raw: u32) ?*PendingAxis {
        return switch (raw) {
            0 => &self.vertical,
            1 => &self.horizontal,
            else => null,
        };
    }

    fn hasAxisEvent(self: PendingFrame) bool {
        return self.horizontal.touched or self.vertical.touched;
    }
};

const PendingAxis = struct {
    continuous: f64 = 0,
    discrete: f64 = 0,
    value120: f64 = 0,
    has_continuous: bool = false,
    has_discrete: bool = false,
    has_value120: bool = false,
    touched: bool = false,
    motion_time: ?u32 = null,
    stop_time: ?u32 = null,
    relative_direction: ?RelativeDirection = null,

    fn finish(self: PendingAxis) AxisValue {
        const unit: AxisUnit = if (self.has_value120)
            .value120
        else if (self.has_discrete)
            .discrete
        else if (self.has_continuous)
            .continuous
        else
            .none;
        const delta = switch (unit) {
            .value120 => self.value120,
            .discrete => self.discrete,
            .continuous => self.continuous / 10.0,
            .none => 0,
        };
        return .{
            .delta = delta,
            .unit = unit,
            .motion_time = self.motion_time,
            .stop_time = self.stop_time,
            .relative_direction = self.relative_direction,
        };
    }
};

fn normalizedDelta(axis: u32, value: f64) ?f64 {
    return switch (axis) {
        0 => -value,
        1 => value,
        else => null,
    };
}

test "pointer preserves logical coordinates and enter serial" {
    const Probe = struct {
        enter_count: usize = 0,
        leave_count: usize = 0,
        motion_count: usize = 0,
        last_motion: MotionEvent = undefined,

        fn entered(context: *anyopaque, _: EnterEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.enter_count += 1;
        }

        fn left(context: *anyopaque, _: LeaveEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.leave_count += 1;
        }

        fn moved(context: *anyopaque, event: MotionEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.motion_count += 1;
            self.last_motion = event;
        }
    };

    var probe = Probe{};
    var pointer = Pointer.init(&probe, .{
        .entered = Probe.entered,
        .left = Probe.left,
        .moved = Probe.moved,
    });
    pointer.attach(20, max_version);
    pointer.handleEnter(41, 12, .{ .x = 12.5, .y = 7.25 });
    try std.testing.expect(pointer.cursor_on_screen);
    try std.testing.expectEqual(@as(?u32, 41), pointer.cursorSerial());
    try std.testing.expectEqual(@as(?u32, 12), pointer.focus_surface);
    try std.testing.expectEqual(@as(usize, 1), probe.enter_count);

    pointer.handleMotion(900, .{ .x = -2.5, .y = 20.75 });
    try std.testing.expectEqual(Position{ .x = -2.5, .y = 20.75 }, probe.last_motion.position);
    try std.testing.expectEqual(@as(usize, 1), probe.motion_count);

    try pointer.handleLeave(42, 12);
    try std.testing.expect(!pointer.cursor_on_screen);
    try std.testing.expect(pointer.cursorSerial() == null);
    try std.testing.expectEqual(@as(usize, 1), probe.leave_count);
}

test "pointer maps Linux mouse buttons and ignores future codes" {
    try std.testing.expectEqual(windowing.MouseButton.left, buttonFromLinux(0x110).?);
    try std.testing.expectEqual(windowing.MouseButton.x2, buttonFromLinux(0x114).?);
    try std.testing.expect(buttonFromLinux(0x115) == null);

    const Probe = struct {
        count: usize = 0,
        event: ButtonEvent = undefined,

        fn button(context: *anyopaque, event: ButtonEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.event = event;
        }
    };

    var probe = Probe{};
    var pointer = Pointer.init(&probe, .{ .button = Probe.button });
    pointer.position = .{ .x = 3.5, .y = 9.25 };
    try pointer.handleButton(7, 1200, 0x113, 1);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(windowing.MouseButton.x1, probe.event.button);
    try std.testing.expectEqual(ButtonState.pressed, probe.event.state);
    try pointer.handleButton(7, 1200, 0xffff, 1);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
}

test "pointer frames prefer value120 then discrete then continuous axes" {
    const Probe = struct {
        count: usize = 0,
        event: AxisEvent = undefined,

        fn axis(context: *anyopaque, event: AxisEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.event = event;
        }
    };

    var probe = Probe{};
    var pointer = Pointer.init(&probe, .{ .axis = Probe.axis });
    pointer.version = max_version;
    pointer.position = .{ .x = 4.5, .y = 8.25 };
    try pointer.handleAxis(10, 1, 30);
    try pointer.handleAxis(11, 0, 20);
    try pointer.handleAxisDiscrete(1, 2);
    try pointer.handleAxisValue120(0, 30);
    try pointer.handleAxisValue120(0, 90);
    try pointer.handleAxisSource(0);
    try pointer.handleAxisRelativeDirection(1, 1);
    try pointer.handleAxisStop(88, 0);
    pointer.flushAxes();

    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(AxisUnit.discrete, probe.event.horizontal.unit);
    try std.testing.expectEqual(@as(f64, 2), probe.event.horizontal.delta);
    try std.testing.expectEqual(RelativeDirection.inverted, probe.event.horizontal.relative_direction.?);
    try std.testing.expectEqual(AxisUnit.value120, probe.event.vertical.unit);
    try std.testing.expectEqual(@as(f64, -1), probe.event.vertical.delta);
    try std.testing.expectEqual(@as(?u32, 88), probe.event.vertical.stop_time);
}

test "pointer versions before frame events flush continuous axes immediately" {
    const Probe = struct {
        count: usize = 0,
        delta_y: f64 = 0,

        fn axis(context: *anyopaque, event: AxisEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.delta_y = event.vertical.delta;
        }
    };

    var probe = Probe{};
    var pointer = Pointer.init(&probe, .{ .axis = Probe.axis });
    pointer.version = 4;
    try pointer.handleAxis(100, 0, 20);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(@as(f64, -2), probe.delta_y);
}
