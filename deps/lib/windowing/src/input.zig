const std = @import("std");
const event = @import("event.zig");
const Key = @import("key.zig").Key;
const MouseButton = @import("mouse.zig").MouseButton;
const Modifier = @import("modifier.zig").Modifier;

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Wheel = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Limits = struct {
    retained_pressed_key_count: usize = 256,
    retained_text_codepoint_count: usize = 256,
};

pub const CapacityError = error{
    PressedKeyHistoryEmpty,
    TextCodepointHistoryEmpty,
    CapacityOverflow,
};

pub const Capacity = struct {
    retained_pressed_key_count: usize,
    retained_text_codepoint_count: usize,
    pressed_key_bytes: usize,
    text_codepoint_bytes: usize,
    retained_history_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.retained_pressed_key_count == 0) return error.PressedKeyHistoryEmpty;
        if (limits.retained_text_codepoint_count == 0) return error.TextCodepointHistoryEmpty;
        const pressed_key_bytes = std.math.mul(
            usize,
            limits.retained_pressed_key_count,
            @sizeOf(Key),
        ) catch return error.CapacityOverflow;
        const text_codepoint_bytes = std.math.mul(
            usize,
            limits.retained_text_codepoint_count,
            @sizeOf(u21),
        ) catch return error.CapacityOverflow;
        const retained_history_bytes = std.math.add(
            usize,
            pressed_key_bytes,
            text_codepoint_bytes,
        ) catch return error.CapacityOverflow;
        std.debug.assert(pressed_key_bytes / @sizeOf(Key) == limits.retained_pressed_key_count);
        std.debug.assert(
            text_codepoint_bytes / @sizeOf(u21) == limits.retained_text_codepoint_count,
        );
        return .{
            .retained_pressed_key_count = limits.retained_pressed_key_count,
            .retained_text_codepoint_count = limits.retained_text_codepoint_count,
            .pressed_key_bytes = pressed_key_bytes,
            .text_codepoint_bytes = text_codepoint_bytes,
            .retained_history_bytes = retained_history_bytes,
        };
    }
};

pub const Status = struct {
    dropped_pressed_key_count: u64,
    dropped_text_codepoint_count: u64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    keys: [key_state_capacity]bool = @as([key_state_capacity]bool, @splat(false)),
    key_pressed: [key_state_capacity]bool = @as([key_state_capacity]bool, @splat(false)),
    key_released: [key_state_capacity]bool = @as([key_state_capacity]bool, @splat(false)),
    pressed_keys: History(Key),
    mouse_buttons: [mouse_button_count]bool = @as([mouse_button_count]bool, @splat(false)),
    mouse_pressed: [mouse_button_count]bool = @as([mouse_button_count]bool, @splat(false)),
    mouse_released: [mouse_button_count]bool = @as([mouse_button_count]bool, @splat(false)),
    mouse_position: Point = .{},
    mouse_delta: Point = .{},
    mouse_wheel: Wheel = .{},
    text_codepoints: History(u21),

    pub fn init(allocator: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!State {
        std.debug.assert(capacity.retained_pressed_key_count > 0);
        std.debug.assert(capacity.retained_text_codepoint_count > 0);
        std.debug.assert(
            capacity.pressed_key_bytes / @sizeOf(Key) == capacity.retained_pressed_key_count,
        );
        std.debug.assert(
            capacity.text_codepoint_bytes / @sizeOf(u21) == capacity.retained_text_codepoint_count,
        );
        const pressed_keys = try allocator.alloc(Key, capacity.retained_pressed_key_count);
        errdefer allocator.free(pressed_keys);
        const text_codepoints = try allocator.alloc(u21, capacity.retained_text_codepoint_count);
        return .{
            .allocator = allocator,
            .pressed_keys = History(Key).init(pressed_keys),
            .text_codepoints = History(u21).init(text_codepoints),
        };
    }

    pub fn deinit(self: *State) void {
        std.debug.assert(self.pressed_keys.items.len > 0);
        std.debug.assert(self.text_codepoints.items.len > 0);
        self.allocator.free(self.text_codepoints.items);
        self.allocator.free(self.pressed_keys.items);
        self.* = undefined;
    }

    pub fn beginPoll(self: *State) void {
        @memset(&self.key_pressed, false);
        @memset(&self.key_released, false);
        self.pressed_keys.reset();
        @memset(&self.mouse_pressed, false);
        @memset(&self.mouse_released, false);
        self.mouse_delta = .{};
        self.mouse_wheel = .{};
        self.text_codepoints.reset();
    }

    pub fn pressKey(self: *State, key: Key) void {
        const index = keyIndex(key) orelse return;
        self.keys[index] = true;
        self.key_pressed[index] = true;
        self.pushPressedKey(key);
    }

    pub fn releaseKey(self: *State, key: Key) void {
        const index = keyIndex(key) orelse return;
        self.keys[index] = false;
        self.key_released[index] = true;
    }

    pub fn isKeyDown(self: *const State, key: Key) bool {
        const index = keyIndex(key) orelse return false;
        return self.keys[index];
    }

    pub fn isKeyPressed(self: *const State, key: Key) bool {
        const index = keyIndex(key) orelse return false;
        return self.key_pressed[index];
    }

    pub fn isKeyReleased(self: *const State, key: Key) bool {
        const index = keyIndex(key) orelse return false;
        return self.key_released[index];
    }

    pub fn nextPressedKey(self: *State) ?Key {
        return self.pressed_keys.next();
    }

    pub fn modifiers(self: *const State) Modifier {
        return .{
            .shift = self.isKeyDown(.left_shift) or self.isKeyDown(.right_shift),
            .ctrl = self.isKeyDown(.left_ctrl) or self.isKeyDown(.right_ctrl),
            .alt = self.isKeyDown(.left_alt) or self.isKeyDown(.right_alt),
            .super = self.isKeyDown(.left_super) or self.isKeyDown(.right_super),
        };
    }

    pub fn pressMouse(self: *State, button: MouseButton) void {
        const index = mouseButtonIndex(button);
        self.mouse_buttons[index] = true;
        self.mouse_pressed[index] = true;
    }

    pub fn releaseMouse(self: *State, button: MouseButton) void {
        const index = mouseButtonIndex(button);
        self.mouse_buttons[index] = false;
        self.mouse_released[index] = true;
    }

    pub fn isMouseButtonDown(self: *const State, button: MouseButton) bool {
        return self.mouse_buttons[mouseButtonIndex(button)];
    }

    pub fn isMouseButtonPressed(self: *const State, button: MouseButton) bool {
        return self.mouse_pressed[mouseButtonIndex(button)];
    }

    pub fn isMouseButtonReleased(self: *const State, button: MouseButton) bool {
        return self.mouse_released[mouseButtonIndex(button)];
    }

    pub fn setMousePosition(self: *State, x: i32, y: i32) void {
        self.mouse_position = .{ .x = x, .y = y };
    }

    pub fn moveMouse(self: *State, x: i32, y: i32) void {
        const previous = self.mouse_position;
        self.mouse_position = .{ .x = x, .y = y };
        self.mouse_delta.x = saturatingI32Add(self.mouse_delta.x, saturatingI32Diff(x, previous.x));
        self.mouse_delta.y = saturatingI32Add(self.mouse_delta.y, saturatingI32Diff(y, previous.y));
    }

    pub fn addMouseWheel(self: *State, x: f32, y: f32) void {
        self.mouse_wheel.x += x;
        self.mouse_wheel.y += y;
    }

    pub fn pushTextInput(self: *State, bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > event.max_text_input_bytes) return false;
        if (!std.unicode.utf8ValidateSlice(bytes)) return false;

        var iterator = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint < 0x20 or codepoint == 0x7f) return false;
        }

        iterator = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            self.pushTextCodepoint(codepoint);
        }
        return true;
    }

    pub fn nextTextCodepoint(self: *State) ?u21 {
        return self.text_codepoints.next();
    }

    pub fn status(self: *const State) Status {
        return .{
            .dropped_pressed_key_count = self.pressed_keys.dropped_count,
            .dropped_text_codepoint_count = self.text_codepoints.dropped_count,
        };
    }

    fn pushPressedKey(self: *State, key: Key) void {
        _ = self.pressed_keys.push(key);
    }

    fn pushTextCodepoint(self: *State, codepoint: u21) void {
        _ = self.text_codepoints.push(codepoint);
    }
};

const key_state_capacity: usize = blk: {
    var max_value: comptime_int = 0;
    for (@typeInfo(Key).@"enum".field_values) |field_value| {
        if (field_value > max_value) max_value = field_value;
    }
    break :blk max_value + 1;
};

const mouse_button_count = @typeInfo(MouseButton).@"enum".field_names.len;

fn History(comptime T: type) type {
    return struct {
        items: []T,
        read_index: usize = 0,
        retained_count: usize = 0,
        dropped_count: u64 = 0,

        fn init(items: []T) @This() {
            std.debug.assert(items.len > 0);
            return .{ .items = items };
        }

        fn reset(self: *@This()) void {
            std.debug.assert(self.read_index <= self.retained_count);
            std.debug.assert(self.retained_count <= self.items.len);
            self.read_index = 0;
            self.retained_count = 0;
        }

        fn push(self: *@This(), item: T) bool {
            std.debug.assert(self.retained_count <= self.items.len);
            if (self.retained_count == self.items.len) {
                self.dropped_count +|= 1;
                return false;
            }
            self.items[self.retained_count] = item;
            self.retained_count += 1;
            return true;
        }

        fn next(self: *@This()) ?T {
            std.debug.assert(self.read_index <= self.retained_count);
            std.debug.assert(self.retained_count <= self.items.len);
            if (self.read_index == self.retained_count) return null;
            const item = self.items[self.read_index];
            self.read_index += 1;
            return item;
        }
    };
}

fn keyIndex(key: Key) ?usize {
    const raw = @backingInt(key);
    inline for (
        @typeInfo(Key).@"enum".field_names,
        @typeInfo(Key).@"enum".field_values,
    ) |field_name, field_name_value| {
        const field = .{ .name = field_name, .value = field_name_value };
        if (raw == field.value) {
            if (raw == @backingInt(Key.unknown)) return null;
            return @intCast(raw);
        }
    }
    return null;
}

fn mouseButtonIndex(button: MouseButton) usize {
    return @intCast(@backingInt(button));
}

fn saturatingI32FromI64(value: i64) i32 {
    if (value < std.math.minInt(i32)) return std.math.minInt(i32);
    if (value > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(value);
}

fn saturatingI32Add(left: i32, right: i32) i32 {
    return std.math.add(i32, left, right) catch if (right < 0)
        std.math.minInt(i32)
    else
        std.math.maxInt(i32);
}

fn saturatingI32Diff(next: i32, previous: i32) i32 {
    return saturatingI32FromI64(@as(i64, next) - @as(i64, previous));
}

fn initTestState() !State {
    return State.init(std.testing.allocator, try Capacity.derive(.{}));
}

test "input history capacity derives exact storage and rejects invalid limits" {
    const capacity = try Capacity.derive(.{});
    try std.testing.expectEqual(@as(usize, 256), capacity.retained_pressed_key_count);
    try std.testing.expectEqual(@as(usize, 256), capacity.retained_text_codepoint_count);
    try std.testing.expectEqual(256 * @sizeOf(Key), capacity.pressed_key_bytes);
    try std.testing.expectEqual(256 * @sizeOf(u21), capacity.text_codepoint_bytes);
    try std.testing.expectEqual(
        capacity.pressed_key_bytes + capacity.text_codepoint_bytes,
        capacity.retained_history_bytes,
    );
    try std.testing.expectError(error.PressedKeyHistoryEmpty, Capacity.derive(.{
        .retained_pressed_key_count = 0,
    }));
    try std.testing.expectError(error.TextCodepointHistoryEmpty, Capacity.derive(.{
        .retained_text_codepoint_count = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_pressed_key_count = std.math.maxInt(usize) / @sizeOf(Key) + 1,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_pressed_key_count = std.math.maxInt(usize) / @sizeOf(Key),
        .retained_text_codepoint_count = 1,
    }));
}

test "input histories retain their limits and allocate only during initialization" {
    const capacity = try Capacity.derive(.{
        .retained_pressed_key_count = 2,
        .retained_text_codepoint_count = 2,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var state = try State.init(failing.allocator(), capacity);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);

    state.pressKey(.a);
    state.pressKey(.b);
    state.pressKey(.enter);
    try std.testing.expect(state.isKeyDown(.enter));
    try std.testing.expect(state.pushTextInput("abc"));
    try std.testing.expectEqual(Status{
        .dropped_pressed_key_count = 1,
        .dropped_text_codepoint_count = 1,
    }, state.status());
    try std.testing.expectEqual(Key.a, state.nextPressedKey().?);
    try std.testing.expectEqual(Key.b, state.nextPressedKey().?);
    try std.testing.expect(state.nextPressedKey() == null);
    try std.testing.expectEqual(@as(u21, 'a'), state.nextTextCodepoint().?);
    try std.testing.expectEqual(@as(u21, 'b'), state.nextTextCodepoint().?);
    try std.testing.expect(state.nextTextCodepoint() == null);

    state.beginPoll();
    state.pressKey(.tab);
    try std.testing.expect(state.pushTextInput("λ"));
    try std.testing.expectEqual(Key.tab, state.nextPressedKey().?);
    try std.testing.expectEqual(@as(u21, 'λ'), state.nextTextCodepoint().?);
    try std.testing.expectEqual(Status{
        .dropped_pressed_key_count = 1,
        .dropped_text_codepoint_count = 1,
    }, state.status());

    state.pressed_keys.dropped_count = std.math.maxInt(u64);
    state.text_codepoints.dropped_count = std.math.maxInt(u64);
    state.beginPoll();
    state.pressKey(.a);
    state.pressKey(.b);
    state.pressKey(.enter);
    try std.testing.expect(state.pushTextInput("abc"));
    try std.testing.expectEqual(Status{
        .dropped_pressed_key_count = std.math.maxInt(u64),
        .dropped_text_codepoint_count = std.math.maxInt(u64),
    }, state.status());
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "input state tracks keys and ignores unknown keys" {
    var state = try initTestState();
    defer state.deinit();

    try std.testing.expect(!state.isKeyDown(.a));
    try std.testing.expect(!state.isKeyPressed(.a));
    state.pressKey(.a);
    try std.testing.expect(state.isKeyDown(.a));
    try std.testing.expect(state.isKeyPressed(.a));
    try std.testing.expect(!state.isKeyReleased(.a));
    try std.testing.expectEqual(Key.a, state.nextPressedKey().?);
    try std.testing.expect(state.nextPressedKey() == null);
    state.releaseKey(.a);
    try std.testing.expect(!state.isKeyDown(.a));
    try std.testing.expect(state.isKeyReleased(.a));

    state.pressKey(.unknown);
    try std.testing.expect(!state.isKeyDown(.unknown));
    try std.testing.expect(!state.isKeyPressed(.unknown));
    try std.testing.expect(state.nextPressedKey() == null);
    state.pressKey(@fromBackingInt(@intCast(100)));
    try std.testing.expect(!state.isKeyDown(@fromBackingInt(@intCast(100))));
    try std.testing.expect(!state.isKeyPressed(@fromBackingInt(@intCast(100))));
    try std.testing.expect(state.nextPressedKey() == null);
    try std.testing.expect(!state.isKeyDown(@fromBackingInt(@intCast(4096))));
}

test "input state queues pressed keys in poll order" {
    var state = try initTestState();
    defer state.deinit();

    state.pressKey(.b);
    state.pressKey(.a);

    try std.testing.expectEqual(Key.b, state.nextPressedKey().?);
    try std.testing.expectEqual(Key.a, state.nextPressedKey().?);
    try std.testing.expect(state.nextPressedKey() == null);
}

test "input state derives active modifiers from key state" {
    var state = try initTestState();
    defer state.deinit();

    state.pressKey(.left_ctrl);
    state.pressKey(.right_shift);

    var modifiers = state.modifiers();
    try std.testing.expect(modifiers.ctrl);
    try std.testing.expect(modifiers.shift);
    try std.testing.expect(!modifiers.alt);
    try std.testing.expect(!modifiers.super);

    state.releaseKey(.left_ctrl);
    modifiers = state.modifiers();
    try std.testing.expect(!modifiers.ctrl);
    try std.testing.expect(modifiers.shift);
}

test "input state tracks mouse buttons" {
    var state = try initTestState();
    defer state.deinit();

    try std.testing.expect(!state.isMouseButtonDown(.left));
    try std.testing.expect(!state.isMouseButtonPressed(.left));
    state.pressMouse(.left);
    try std.testing.expect(state.isMouseButtonDown(.left));
    try std.testing.expect(state.isMouseButtonPressed(.left));
    try std.testing.expect(!state.isMouseButtonReleased(.left));
    state.releaseMouse(.left);
    try std.testing.expect(!state.isMouseButtonDown(.left));
    try std.testing.expect(state.isMouseButtonReleased(.left));
}

test "input state resets per-poll transient accumulators" {
    var state = try initTestState();
    defer state.deinit();

    state.pressKey(.enter);
    state.releaseKey(.tab);
    state.pressMouse(.right);
    state.releaseMouse(.middle);
    try std.testing.expect(state.pushTextInput("xλ"));
    state.setMousePosition(10, 20);
    state.moveMouse(15, 12);
    state.addMouseWheel(1.5, -2.0);

    try std.testing.expect(state.isKeyPressed(.enter));
    try std.testing.expect(state.isKeyReleased(.tab));
    try std.testing.expectEqual(Key.enter, state.nextPressedKey().?);
    try std.testing.expectEqual(@as(u21, 'x'), state.nextTextCodepoint().?);
    try std.testing.expectEqual(@as(u21, 'λ'), state.nextTextCodepoint().?);
    try std.testing.expect(state.isMouseButtonPressed(.right));
    try std.testing.expect(state.isMouseButtonReleased(.middle));
    try std.testing.expectEqual(Point{ .x = 15, .y = 12 }, state.mouse_position);
    try std.testing.expectEqual(Point{ .x = 5, .y = -8 }, state.mouse_delta);
    try std.testing.expectEqual(Wheel{ .x = 1.5, .y = -2.0 }, state.mouse_wheel);

    state.beginPoll();
    try std.testing.expect(!state.isKeyPressed(.enter));
    try std.testing.expect(!state.isKeyReleased(.tab));
    try std.testing.expect(state.nextPressedKey() == null);
    try std.testing.expect(state.nextTextCodepoint() == null);
    try std.testing.expect(!state.isMouseButtonPressed(.right));
    try std.testing.expect(!state.isMouseButtonReleased(.middle));
    try std.testing.expectEqual(Point{}, state.mouse_delta);
    try std.testing.expectEqual(Wheel{}, state.mouse_wheel);
    try std.testing.expectEqual(Point{ .x = 15, .y = 12 }, state.mouse_position);
}

test "input state clamps extreme pointer deltas" {
    var state = try initTestState();
    defer state.deinit();

    state.setMousePosition(std.math.maxInt(i32), 0);
    state.moveMouse(std.math.minInt(i32), 0);

    try std.testing.expectEqual(Point{ .x = std.math.minInt(i32), .y = 0 }, state.mouse_delta);
}

test "input state queues valid text codepoints" {
    var state = try initTestState();
    defer state.deinit();

    try std.testing.expect(state.pushTextInput("aλ"));
    try std.testing.expectEqual(@as(u21, 'a'), state.nextTextCodepoint().?);
    try std.testing.expectEqual(@as(u21, 'λ'), state.nextTextCodepoint().?);
    try std.testing.expect(state.nextTextCodepoint() == null);

    try std.testing.expect(!state.pushTextInput("\n"));
    try std.testing.expect(!state.pushTextInput(&(@as([(event.max_text_input_bytes + 1)]u8, @splat('x')))));
    try std.testing.expect(state.nextTextCodepoint() == null);
}
