const std = @import("std");
const sys = @import("sys");
const native = @import("wayland");
const windowing = @import("../../root.zig");
const wayland = @import("../root.zig");

pub const clipboard = @import("clipboard.zig");
pub const keyboard = @import("keyboard.zig");
pub const pointer = @import("pointer.zig");

const core = native.protocol.core;
const desktop = native.protocol.desktop;
const runtime = native.runtime;
const session = wayland.session;
const support = @import("support.zig");

pub const Callbacks = struct {
    context: *anyopaque,
    event: *const fn (context: *anyopaque, value: windowing.Event) void,
    focus_changed: *const fn (context: *anyopaque, focused: bool) void,
    synchronize: *const fn (context: *anyopaque, timeout_ms: u32) anyerror!void,
};

pub const Seat = struct {
    allocator: std.mem.Allocator = undefined,
    client: ?*runtime.Client = null,
    callbacks: ?Callbacks = null,
    seat_id: ?u32 = null,
    data_device_manager: ?u32 = null,
    cursor_shape_manager: ?u32 = null,
    cursor_device: ?u32 = null,
    keyboard_id: ?u32 = null,
    keyboard_version: u32 = 0,
    keyboard_active: bool = false,
    pointer_state: ?pointer.Pointer = null,
    keyboard_state: ?keyboard.Keyboard = null,
    clipboard_state: ?clipboard.Clipboard = null,
    surface: ?u32 = null,
    input: windowing.input.State = undefined,
    cursor_shape: windowing.CursorShape = .default,
    cursor_on_screen: bool = false,
    last_input_serial: ?u32 = null,
    callback_failed: bool = false,

    pub fn open(
        self: *Seat,
        allocator: std.mem.Allocator,
        client: *runtime.Client,
        globals: *const session.Globals,
        input_capacity: windowing.input.Capacity,
        clipboard_capacity: windowing.clipboard.Capacity,
        compose_limits: keyboard.ComposeLimits,
        compose_scratch_limits: keyboard.ComposeScratchLimits,
        callbacks: Callbacks,
    ) !void {
        const input_state = try windowing.input.State.init(allocator, input_capacity);
        self.* = .{
            .allocator = allocator,
            .client = client,
            .callbacks = callbacks,
            .input = input_state,
        };
        errdefer self.deinit();
        self.pointer_state = pointer.Pointer.init(self, .{
            .entered = pointerEntered,
            .left = pointerLeft,
            .moved = pointerMoved,
            .button = pointerButton,
            .axis = pointerAxis,
        });
        self.keyboard_state = try keyboard.Keyboard.init(allocator, .{
            .context = self,
            .focus = keyboardFocus,
            .key = keyboardKey,
            .text = keyboardText,
        }, .{
            .compose_limits = compose_limits,
            .compose_scratch_limits = compose_scratch_limits,
        });
        self.clipboard_state = try clipboard.Clipboard.init(allocator, client, clipboard_capacity);
        try self.setGlobals(globals);
    }

    pub fn deinit(self: *Seat) void {
        const client = self.client orelse {
            self.* = .{};
            return;
        };
        if (self.clipboard_state) |*state| state.deinit();
        self.clipboard_state = null;
        self.destroyCursorDevice();
        if (self.pointer_state) |*state| state.deinit(client);
        self.pointer_state = null;
        self.destroyKeyboard(true);
        if (self.keyboard_state) |*state| state.deinit();
        self.keyboard_state = null;
        self.input.deinit();
        self.* = .{};
    }

    pub fn dispatch(self: *Seat, event: *runtime.RoutedView) !bool {
        if (self.pointer_state) |*state| {
            if (event.object_id == state.object_id) {
                try state.dispatch(event);
                return true;
            }
        }
        if (event.object_id == self.keyboard_id) {
            if (self.keyboard_active) {
                const state = if (self.keyboard_state) |*value| value else return error.KeyboardUnavailable;
                try state.dispatch(event);
            }
            return true;
        }
        if (self.clipboard_state) |*state| {
            if (try state.dispatch(event)) return true;
        }
        return false;
    }

    pub fn setGlobals(self: *Seat, globals: *const session.Globals) !void {
        self.data_device_manager = globals.data_device_manager;
        self.cursor_shape_manager = globals.cursor_shape_manager;
        if (self.seat_id == globals.seat) return;
        self.seatRemoved();
        self.seat_id = globals.seat;
        const manager = self.data_device_manager orelse return;
        const seat = self.seat_id orelse return;
        const state = if (self.clipboard_state) |*value| value else return;
        try state.bindSeat(manager, seat);
    }

    pub fn setSurface(self: *Seat, surface: ?u32) void {
        self.surface = surface;
        if (self.keyboard_state) |*state| state.setSurface(surface);
    }

    pub fn capabilities(self: *Seat, value: u32) void {
        self.updatePointerCapability((value & 1) != 0);
        self.updateKeyboardCapability((value & 2) != 0);
    }

    pub fn seatRemoved(self: *Seat) void {
        if (self.clipboard_state) |*state| state.unbindSeat();
        self.updatePointerCapability(false);
        self.updateKeyboardCapability(false);
        self.last_input_serial = null;
        self.seat_id = null;
    }

    pub fn poll(self: *Seat) !void {
        if (self.callback_failed) return error.CallbackFailed;
        if (self.keyboard_state) |*state| {
            if (state.takeFailure() != null) return error.KeyboardFailed;
            const milliseconds = sys.time.milliTimestamp();
            const now: u32 = if (milliseconds <= 0) 0 else @truncate(@as(u64, @intCast(milliseconds)));
            _ = try state.dispatchRepeat(now);
        }
    }

    pub fn inputState(self: *const Seat) *const windowing.input.State {
        return &self.input;
    }

    pub fn inputStateMut(self: *Seat) *windowing.input.State {
        return &self.input;
    }

    pub fn modifiers(self: *const Seat) windowing.Modifier {
        if (self.keyboard_state) |*state| return state.modifiers();
        return self.input.modifiers();
    }

    pub fn setCursor(self: *Seat, shape: windowing.CursorShape) void {
        self.cursor_shape = shape;
        self.applyCursorShape();
    }

    pub fn getClipboardTextAlloc(self: *Seat, allocator: std.mem.Allocator) !?[]u8 {
        const state = if (self.clipboard_state) |*value| value else return null;
        return state.getTextAlloc(allocator, .{
            .context = self,
            .run = synchronizeClipboard,
        });
    }

    pub fn setClipboardText(
        self: *Seat,
        text: []const u8,
    ) windowing.clipboard.PublishError!void {
        const serial = self.last_input_serial orelse return error.Unavailable;
        const state = if (self.clipboard_state) |*value| value else return error.Unavailable;
        try state.setText(text, serial);
    }

    pub fn clipboardStatus(self: *const Seat) windowing.clipboard.Status {
        const state = if (self.clipboard_state) |*value| value else return .{};
        return state.status();
    }

    fn updatePointerCapability(self: *Seat, available: bool) void {
        const client = self.client orelse return;
        const state = if (self.pointer_state) |*value| value else return;
        if (!available) {
            self.destroyCursorDevice();
            state.deactivate(client);
            self.cursor_on_screen = false;
            self.releaseMouseButtons();
            return;
        }
        if (state.object_id != null) {
            state.active = true;
            self.ensureCursorDevice();
            return;
        }
        const seat = self.seat_id orelse {
            self.callback_failed = true;
            return;
        };
        var created: [1]u32 = undefined;
        client.request(
            seat,
            core.wl_seat.requests.get_pointer.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        ) catch {
            self.callback_failed = true;
            return;
        };
        const version = (client.object(created[0]) orelse {
            self.callback_failed = true;
            return;
        }).version;
        state.attach(created[0], version);
        self.ensureCursorDevice();
    }

    fn updateKeyboardCapability(self: *Seat, available: bool) void {
        const client = self.client orelse return;
        if (!available) {
            self.destroyKeyboard(false);
            return;
        }
        if (self.keyboard_id != null) {
            self.keyboard_active = true;
            return;
        }
        const seat = self.seat_id orelse {
            self.callback_failed = true;
            return;
        };
        var created: [1]u32 = undefined;
        client.request(
            seat,
            core.wl_seat.requests.get_keyboard.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        ) catch {
            self.callback_failed = true;
            return;
        };
        const version = (client.object(created[0]) orelse {
            self.callback_failed = true;
            return;
        }).version;
        self.keyboard_id = created[0];
        self.keyboard_version = version;
        self.keyboard_active = true;
    }

    fn ensureCursorDevice(self: *Seat) void {
        if (self.cursor_device != null) return;
        const client = self.client orelse return;
        const manager = self.cursor_shape_manager orelse return;
        const state = if (self.pointer_state) |*value| value else return;
        const pointer_id = state.object_id orelse return;
        var created: [1]u32 = undefined;
        client.request(
            manager,
            desktop.wp_cursor_shape_manager_v1.requests.get_pointer.opcode,
            &.{ .{ .new_id = .fixed }, .{ .object = pointer_id } },
            &created,
        ) catch {
            self.callback_failed = true;
            return;
        };
        self.cursor_device = created[0];
    }

    fn applyCursorShape(self: *Seat) void {
        const client = self.client orelse return;
        const device = self.cursor_device orelse return;
        const state = if (self.pointer_state) |*value| value else return;
        const serial = state.cursorSerial() orelse return;
        client.request(
            device,
            desktop.wp_cursor_shape_device_v1.requests.set_shape.opcode,
            &.{ .{ .uint = serial }, .{ .uint = cursorShapeValue(self.cursor_shape) } },
            &.{},
        ) catch {
            self.callback_failed = true;
        };
    }

    fn destroyCursorDevice(self: *Seat) void {
        const client = self.client orelse return;
        const device = self.cursor_device orelse return;
        client.request(
            device,
            desktop.wp_cursor_shape_device_v1.requests.destroy.opcode,
            &.{},
            &.{},
        ) catch {};
        self.cursor_device = null;
    }

    fn destroyKeyboard(self: *Seat, final: bool) void {
        if (self.keyboard_state) |*state| state.clearFocus();
        const client = self.client orelse return;
        const object_id = self.keyboard_id orelse return;
        if (self.keyboard_version >= core.wl_keyboard.requests.release.since) {
            client.request(object_id, core.wl_keyboard.requests.release.opcode, &.{}, &.{}) catch {};
            self.keyboard_id = null;
            self.keyboard_version = 0;
        } else if (final) {
            self.keyboard_id = null;
            self.keyboard_version = 0;
        }
        self.keyboard_active = false;
    }

    fn ownsSurface(self: *const Seat, candidate: ?u32) bool {
        const expected = self.surface orelse return false;
        const actual = candidate orelse return false;
        return expected == actual;
    }

    fn push(self: *Seat, event: windowing.Event) void {
        if (self.callbacks) |callbacks| callbacks.event(callbacks.context, event);
    }

    fn pointerEntered(context: *anyopaque, event: pointer.EnterEvent) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (!self.ownsSurface(event.surface)) return;
        self.cursor_on_screen = true;
        self.input.setMousePosition(coordinate(event.position.x), coordinate(event.position.y));
        self.applyCursorShape();
    }

    fn pointerLeft(context: *anyopaque, event: pointer.LeaveEvent) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (!self.ownsSurface(event.surface)) return;
        self.cursor_on_screen = false;
    }

    fn pointerMoved(context: *anyopaque, event: pointer.MotionEvent) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (!self.ownsSurface(event.surface)) return;
        const x = coordinate(event.position.x);
        const y = coordinate(event.position.y);
        self.input.moveMouse(x, y);
        self.push(.{ .mouse_move = .{ .x = x, .y = y } });
    }

    fn pointerButton(context: *anyopaque, event: pointer.ButtonEvent) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (!self.ownsSurface(event.surface)) return;
        self.last_input_serial = event.serial;
        const x = coordinate(event.position.x);
        const y = coordinate(event.position.y);
        switch (event.state) {
            .pressed => {
                self.input.pressMouse(event.button);
                self.push(.{ .mouse_press = .{
                    .button = event.button,
                    .x = x,
                    .y = y,
                    .modifiers = self.modifiers(),
                } });
            },
            .released => {
                self.input.releaseMouse(event.button);
                self.push(.{ .mouse_release = .{
                    .button = event.button,
                    .x = x,
                    .y = y,
                    .modifiers = self.modifiers(),
                } });
            },
        }
    }

    fn pointerAxis(context: *anyopaque, event: pointer.AxisEvent) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (!self.ownsSurface(event.surface)) return;
        const delta_x: f32 = @floatCast(event.horizontal.delta);
        const delta_y: f32 = @floatCast(event.vertical.delta);
        if (delta_x == 0 and delta_y == 0) return;
        self.input.addMouseWheel(delta_x, delta_y);
        self.push(.{ .mouse_wheel = .{
            .x = coordinate(event.position.x),
            .y = coordinate(event.position.y),
            .delta_x = delta_x,
            .delta_y = delta_y,
            .modifiers = self.modifiers(),
        } });
    }

    fn keyboardFocus(context: *anyopaque, focused: bool) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (self.callbacks) |callbacks| callbacks.focus_changed(callbacks.context, focused);
    }

    fn keyboardKey(context: *anyopaque, action: keyboard.KeyAction) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (action.pressed) {
            self.input.pressKey(action.key);
            if (action.emit_event) self.push(.{ .key_press = .{
                .key = action.key,
                .modifiers = action.modifiers,
                .repeated = action.repeated,
            } });
        } else {
            self.input.releaseKey(action.key);
            if (action.emit_event) self.push(.{ .key_release = .{
                .key = action.key,
                .modifiers = action.modifiers,
            } });
        }
    }

    fn keyboardText(context: *anyopaque, bytes: []const u8, active_modifiers: windowing.Modifier) void {
        const self: *Seat = @ptrCast(@alignCast(context));
        if (!self.input.pushTextInput(bytes)) return;
        if (windowing.Event.textInput(bytes, active_modifiers)) |event| self.push(event);
    }

    fn synchronizeClipboard(context: ?*anyopaque) anyerror!void {
        const self: *Seat = @ptrCast(@alignCast(context orelse return error.ConnectionLost));
        const callbacks = self.callbacks orelse return error.ConnectionLost;
        try callbacks.synchronize(callbacks.context, clipboard.receive_timeout_ms);
    }

    fn releaseMouseButtons(self: *Seat) void {
        inline for (
            @typeInfo(windowing.MouseButton).@"enum".field_names,
            @typeInfo(windowing.MouseButton).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            const button: windowing.MouseButton = @fromBackingInt(@intCast(field.value));
            if (self.input.isMouseButtonDown(button)) self.input.releaseMouse(button);
        }
    }
};

const coordinate = support.coordinate;
const cursorShapeValue = support.cursorShapeValue;
