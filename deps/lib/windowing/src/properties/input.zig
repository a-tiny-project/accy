const std = @import("std");
const hypothesis = @import("hypothesis");
const windowing = @import("windowing");

const State = windowing.input.State;
const Point = windowing.input.Point;
const Wheel = windowing.input.Wheel;
const Key = windowing.Key;
const MouseButton = windowing.MouseButton;

const input_limits = windowing.input.Limits{
    .retained_pressed_key_count = 8,
    .retained_text_codepoint_count = 8,
};
const pressed_key_capacity = input_limits.retained_pressed_key_count;
const text_codepoint_capacity = input_limits.retained_text_codepoint_count;
const max_text_input_bytes = @typeInfo(@TypeOf((windowing.TextInputEvent{}).bytes)).array.len;

const valid_keys = [_]Key{
    .a,
    .b,
    .enter,
    .tab,
    .left_shift,
    .right_shift,
    .left_ctrl,
    .right_ctrl,
    .left_alt,
    .right_alt,
    .left_super,
    .right_super,
};
const invalid_keys = [_]Key{
    .unknown,
    @fromBackingInt(@intCast(1)),
    @fromBackingInt(@intCast(31)),
    @fromBackingInt(@intCast(100)),
    @fromBackingInt(@intCast(349)),
    @fromBackingInt(@intCast(4096)),
    @fromBackingInt(@intCast(std.math.maxInt(u16))),
};
const mouse_buttons = [_]MouseButton{
    .left,
    .right,
    .middle,
    .x1,
    .x2,
};
const coordinates = [_]i32{
    std.math.minInt(i32),
    std.math.minInt(i32) + 1,
    -1024,
    -1,
    0,
    1,
    1024,
    std.math.maxInt(i32) - 1,
    std.math.maxInt(i32),
};
const wheel_values = [_]f32{
    -120.0,
    -1.5,
    -0.25,
    0.0,
    0.25,
    1.5,
    120.0,
};
const text_inputs = [_][]const u8{
    "",
    "\n",
    "\x7f",
    "\xff",
    "a",
    "z",
    "A",
    " ",
    "lambda",
    "a\xce\xbb",
    "1234567890123456",
    "12345678901234567",
};

pub fn settings() hypothesis.Settings {
    return hypothesis.Settings.quick()
        .withSeed(0x5447_4657_494e_5055)
        .withDatabase("zig-out/hypothesis-failures/windowing");
}

fn drawUsize(
    data: *hypothesis.ConjectureData,
    min: usize,
    max: usize,
    shrink_towards: usize,
) !usize {
    return @intCast(try data.drawInteger(
        @intCast(min),
        @intCast(max),
        @intCast(shrink_towards),
    ));
}

fn drawCoordinate(data: *hypothesis.ConjectureData) !i32 {
    if (try data.drawBoolean()) {
        return coordinates[try drawUsize(data, 0, coordinates.len - 1, 4)];
    }
    const raw = try drawUsize(data, 0, 2048, 1024);
    return @as(i32, @intCast(raw)) - 1024;
}

fn drawKey(data: *hypothesis.ConjectureData) !Key {
    if (try data.drawBoolean()) {
        return valid_keys[try drawUsize(data, 0, valid_keys.len - 1, 0)];
    }
    return invalid_keys[try drawUsize(data, 0, invalid_keys.len - 1, 0)];
}

fn drawMouseButton(data: *hypothesis.ConjectureData) !MouseButton {
    return mouse_buttons[try drawUsize(data, 0, mouse_buttons.len - 1, 0)];
}

fn drawWheel(data: *hypothesis.ConjectureData) !f32 {
    return wheel_values[try drawUsize(data, 0, wheel_values.len - 1, 3)];
}

const TextAppend = struct {
    accepted: bool,
    codepoints: [max_text_input_bytes]u21 = undefined,
    count: usize = 0,
};

const Model = struct {
    keys: [valid_keys.len]bool = @as([valid_keys.len]bool, @splat(false)),
    pressed: [valid_keys.len]bool = @as([valid_keys.len]bool, @splat(false)),
    released: [valid_keys.len]bool = @as([valid_keys.len]bool, @splat(false)),
    pressed_keys: [pressed_key_capacity]Key = undefined,
    pressed_key_read_index: usize = 0,
    pressed_key_count: usize = 0,
    dropped_pressed_key_count: u64 = 0,
    mouse_buttons: [mouse_buttons.len]bool = @as([mouse_buttons.len]bool, @splat(false)),
    mouse_pressed: [mouse_buttons.len]bool = @as([mouse_buttons.len]bool, @splat(false)),
    mouse_released: [mouse_buttons.len]bool = @as([mouse_buttons.len]bool, @splat(false)),
    mouse_position: Point = .{},
    mouse_delta: Point = .{},
    mouse_wheel: Wheel = .{},
    text_codepoints: [text_codepoint_capacity]u21 = undefined,
    text_read_index: usize = 0,
    text_count: usize = 0,
    dropped_text_codepoint_count: u64 = 0,

    fn beginPoll(self: *Model) void {
        @memset(&self.pressed, false);
        @memset(&self.released, false);
        self.pressed_key_read_index = 0;
        self.pressed_key_count = 0;
        @memset(&self.mouse_pressed, false);
        @memset(&self.mouse_released, false);
        self.mouse_delta = .{};
        self.mouse_wheel = .{};
        self.text_read_index = 0;
        self.text_count = 0;
    }

    fn pressKey(self: *Model, key: Key) void {
        const index = validKeyIndex(key) orelse return;
        self.keys[index] = true;
        self.pressed[index] = true;
        if (self.pressed_key_count < self.pressed_keys.len) {
            self.pressed_keys[self.pressed_key_count] = key;
            self.pressed_key_count += 1;
        } else {
            self.dropped_pressed_key_count +|= 1;
        }
    }

    fn releaseKey(self: *Model, key: Key) void {
        const index = validKeyIndex(key) orelse return;
        self.keys[index] = false;
        self.released[index] = true;
    }

    fn nextPressedKey(self: *Model) ?Key {
        if (self.pressed_key_read_index >= self.pressed_key_count) return null;
        const key = self.pressed_keys[self.pressed_key_read_index];
        self.pressed_key_read_index += 1;
        return key;
    }

    fn pressMouse(self: *Model, button: MouseButton) void {
        const index = mouseIndex(button);
        self.mouse_buttons[index] = true;
        self.mouse_pressed[index] = true;
    }

    fn releaseMouse(self: *Model, button: MouseButton) void {
        const index = mouseIndex(button);
        self.mouse_buttons[index] = false;
        self.mouse_released[index] = true;
    }

    fn setMousePosition(self: *Model, x: i32, y: i32) void {
        self.mouse_position = .{ .x = x, .y = y };
    }

    fn moveMouse(self: *Model, x: i32, y: i32) void {
        const previous = self.mouse_position;
        self.mouse_position = .{ .x = x, .y = y };
        self.mouse_delta.x = saturatingI32Add(
            self.mouse_delta.x,
            saturatingI32Diff(x, previous.x),
        );
        self.mouse_delta.y = saturatingI32Add(
            self.mouse_delta.y,
            saturatingI32Diff(y, previous.y),
        );
    }

    fn addMouseWheel(self: *Model, x: f32, y: f32) void {
        self.mouse_wheel.x += x;
        self.mouse_wheel.y += y;
    }

    fn pushTextInput(self: *Model, bytes: []const u8) bool {
        const validated = validateText(bytes);
        if (!validated.accepted) return false;

        var index: usize = 0;
        while (index < validated.count) : (index += 1) {
            if (self.text_count >= self.text_codepoints.len) {
                self.dropped_text_codepoint_count +|= 1;
                continue;
            }
            self.text_codepoints[self.text_count] = validated.codepoints[index];
            self.text_count += 1;
        }
        return true;
    }

    fn nextTextCodepoint(self: *Model) ?u21 {
        if (self.text_read_index >= self.text_count) return null;
        const codepoint = self.text_codepoints[self.text_read_index];
        self.text_read_index += 1;
        return codepoint;
    }
};

fn expectState(state: *State, model: *const Model) !void {
    for (valid_keys, 0..) |key, index| {
        try std.testing.expectEqual(model.keys[index], state.isKeyDown(key));
        try std.testing.expectEqual(model.pressed[index], state.isKeyPressed(key));
        try std.testing.expectEqual(model.released[index], state.isKeyReleased(key));
    }

    for (invalid_keys) |key| {
        try std.testing.expect(!state.isKeyDown(key));
        try std.testing.expect(!state.isKeyPressed(key));
        try std.testing.expect(!state.isKeyReleased(key));
    }

    const modifiers = state.modifiers();
    try std.testing.expectEqual(
        model.keys[validKeyIndex(.left_shift).?] or model.keys[validKeyIndex(.right_shift).?],
        modifiers.shift,
    );
    try std.testing.expectEqual(
        model.keys[validKeyIndex(.left_ctrl).?] or model.keys[validKeyIndex(.right_ctrl).?],
        modifiers.ctrl,
    );
    try std.testing.expectEqual(
        model.keys[validKeyIndex(.left_alt).?] or model.keys[validKeyIndex(.right_alt).?],
        modifiers.alt,
    );
    try std.testing.expectEqual(
        model.keys[validKeyIndex(.left_super).?] or model.keys[validKeyIndex(.right_super).?],
        modifiers.super,
    );

    for (mouse_buttons, 0..) |button, index| {
        try std.testing.expectEqual(model.mouse_buttons[index], state.isMouseButtonDown(button));
        try std.testing.expectEqual(model.mouse_pressed[index], state.isMouseButtonPressed(button));
        try std.testing.expectEqual(model.mouse_released[index], state.isMouseButtonReleased(button));
    }

    try std.testing.expectEqual(model.mouse_position, state.mouse_position);
    try std.testing.expectEqual(model.mouse_delta, state.mouse_delta);
    try std.testing.expectEqual(model.mouse_wheel, state.mouse_wheel);
    try std.testing.expectEqual(windowing.input.Status{
        .dropped_pressed_key_count = model.dropped_pressed_key_count,
        .dropped_text_codepoint_count = model.dropped_text_codepoint_count,
    }, state.status());
}

fn expectDrainedQueues(state: *State, model: *Model) !void {
    while (true) {
        const expected = model.nextPressedKey();
        const actual = state.nextPressedKey();
        if (expected) |key| {
            try std.testing.expect(actual != null);
            try std.testing.expectEqual(@backingInt(key), @backingInt(actual.?));
        } else {
            try std.testing.expect(actual == null);
            break;
        }
    }

    while (true) {
        const expected = model.nextTextCodepoint();
        const actual = state.nextTextCodepoint();
        if (expected) |codepoint| {
            try std.testing.expect(actual != null);
            try std.testing.expectEqual(codepoint, actual.?);
        } else {
            try std.testing.expect(actual == null);
            break;
        }
    }
}

fn validKeyIndex(key: Key) ?usize {
    for (valid_keys, 0..) |candidate, index| {
        if (candidate == key) return index;
    }
    return null;
}

fn mouseIndex(button: MouseButton) usize {
    return @backingInt(button);
}

fn validateText(bytes: []const u8) TextAppend {
    if (bytes.len == 0 or bytes.len > max_text_input_bytes) return .{ .accepted = false };
    if (!std.unicode.utf8ValidateSlice(bytes)) return .{ .accepted = false };

    var out = TextAppend{ .accepted = true };
    var iterator = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or codepoint == 0x7f) return .{ .accepted = false };
        out.codepoints[out.count] = codepoint;
        out.count += 1;
    }
    return out;
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

pub const TraceProperty = struct {
    pub fn property(conjecture: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        var state = try State.init(allocator, try windowing.input.Capacity.derive(input_limits));
        defer state.deinit();
        var expected = Model{};

        const step_count = try drawUsize(conjecture, 1, 128, 16);
        var step_index: usize = 0;
        while (step_index < step_count) : (step_index += 1) {
            switch (try drawUsize(conjecture, 0, 9, 0)) {
                0 => {
                    state.beginPoll();
                    expected.beginPoll();
                },
                1 => {
                    const key = try drawKey(conjecture);
                    state.pressKey(key);
                    expected.pressKey(key);
                },
                2 => {
                    const key = try drawKey(conjecture);
                    state.releaseKey(key);
                    expected.releaseKey(key);
                },
                3 => {
                    const expected_key = expected.nextPressedKey();
                    const actual = state.nextPressedKey();
                    if (expected_key) |key| {
                        try std.testing.expect(actual != null);
                        try std.testing.expectEqual(@backingInt(key), @backingInt(actual.?));
                    } else {
                        try std.testing.expect(actual == null);
                    }
                },
                4 => {
                    const button = try drawMouseButton(conjecture);
                    state.pressMouse(button);
                    expected.pressMouse(button);
                },
                5 => {
                    const button = try drawMouseButton(conjecture);
                    state.releaseMouse(button);
                    expected.releaseMouse(button);
                },
                6 => {
                    const x = try drawCoordinate(conjecture);
                    const y = try drawCoordinate(conjecture);
                    state.setMousePosition(x, y);
                    expected.setMousePosition(x, y);
                },
                7 => {
                    const x = try drawCoordinate(conjecture);
                    const y = try drawCoordinate(conjecture);
                    state.moveMouse(x, y);
                    expected.moveMouse(x, y);
                },
                8 => {
                    const x = try drawWheel(conjecture);
                    const y = try drawWheel(conjecture);
                    state.addMouseWheel(x, y);
                    expected.addMouseWheel(x, y);
                },
                else => {
                    const bytes = text_inputs[try drawUsize(conjecture, 0, text_inputs.len - 1, 4)];
                    try std.testing.expectEqual(expected.pushTextInput(bytes), state.pushTextInput(bytes));
                },
            }

            try expectState(&state, &expected);
        }

        try expectDrainedQueues(&state, &expected);
        try expectState(&state, &expected);
    }
};

test "property: input state matches generated trace model" {
    try hypothesis.checkNamed(TraceProperty, "windowing-input-trace", settings());
}
