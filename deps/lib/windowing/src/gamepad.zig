const std = @import("std");
const sys = @import("sys");

const rescan_poll_interval = 120;
const gamecontroller = sys.apple.gamecontroller;

const SourceKind = enum {
    evdev,
    gamecontroller,
    unsupported,
};

const source_kind: SourceKind = if (gamecontroller.supported)
    .gamecontroller
else if (sys.evdev.supported)
    .evdev
else
    .unsupported;

pub const Limits = struct {
    retained_gamepad_count: usize = 4,
    retained_name_byte_count_per_gamepad: usize = 64,
    read_event_count: usize = 32,
    scanned_source_count: u32 = 32,
};

pub const CapacityError = error{
    GamepadStorageEmpty,
    NameStorageEmpty,
    NameStorageTooLarge,
    EventReadStorageEmpty,
    SourceScanEmpty,
    CapacityOverflow,
};

pub const Capacity = struct {
    retained_gamepad_count: usize,
    retained_name_byte_count_per_gamepad: usize,
    read_event_count: usize,
    scanned_source_count: u32,
    slot_bytes: usize,
    name_bytes: usize,
    read_event_bytes: usize,
    retained_storage_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.retained_gamepad_count == 0) return error.GamepadStorageEmpty;
        if (limits.retained_name_byte_count_per_gamepad == 0) return error.NameStorageEmpty;
        if (source_kind == .evdev and
            limits.retained_name_byte_count_per_gamepad > sys.evdev.max_query_bytes)
        {
            return error.NameStorageTooLarge;
        }
        if (source_kind == .evdev and limits.read_event_count == 0) {
            return error.EventReadStorageEmpty;
        }
        if (limits.scanned_source_count == 0) return error.SourceScanEmpty;
        const slot_bytes = std.math.mul(
            usize,
            limits.retained_gamepad_count,
            @sizeOf(?Slot),
        ) catch return error.CapacityOverflow;
        const name_bytes = std.math.mul(
            usize,
            limits.retained_gamepad_count,
            limits.retained_name_byte_count_per_gamepad,
        ) catch return error.CapacityOverflow;
        const read_event_count = if (source_kind == .evdev) limits.read_event_count else 0;
        const read_event_bytes = if (source_kind == .evdev)
            std.math.mul(
                usize,
                read_event_count,
                @sizeOf(sys.evdev.InputEvent),
            ) catch return error.CapacityOverflow
        else
            0;
        const retained_gamepad_bytes = std.math.add(
            usize,
            slot_bytes,
            name_bytes,
        ) catch return error.CapacityOverflow;
        const retained_storage_bytes = std.math.add(
            usize,
            retained_gamepad_bytes,
            read_event_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .retained_gamepad_count = limits.retained_gamepad_count,
            .retained_name_byte_count_per_gamepad = limits.retained_name_byte_count_per_gamepad,
            .read_event_count = read_event_count,
            .scanned_source_count = limits.scanned_source_count,
            .slot_bytes = slot_bytes,
            .name_bytes = name_bytes,
            .read_event_bytes = read_event_bytes,
            .retained_storage_bytes = retained_storage_bytes,
        };
    }
};

pub const Status = struct {
    rejected_discovery_count: u64,
};

pub const Button = enum(u4) {
    south = 0,
    east = 1,
    west = 2,
    north = 3,
    left_bumper = 4,
    right_bumper = 5,
    select = 6,
    start = 7,
    guide = 8,
    left_thumb = 9,
    right_thumb = 10,
    dpad_up = 11,
    dpad_down = 12,
    dpad_left = 13,
    dpad_right = 14,
};

pub const Axis = enum(u3) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,
};

pub const button_count = @typeInfo(Button).@"enum".field_names.len;
pub const axis_count = @typeInfo(Axis).@"enum".field_names.len;

pub const Gamepad = struct {
    connected: bool = false,
    name_bytes: []const u8 = &.{},
    buttons: [button_count]bool = @splat(false),
    pressed: [button_count]bool = @splat(false),
    released: [button_count]bool = @splat(false),
    axes: [axis_count]f32 = @splat(0),

    pub fn name(self: *const Gamepad) []const u8 {
        return self.name_bytes;
    }

    pub fn isDown(self: *const Gamepad, control: Button) bool {
        return self.buttons[@backingInt(control)];
    }

    pub fn isPressed(self: *const Gamepad, control: Button) bool {
        return self.pressed[@backingInt(control)];
    }

    pub fn isReleased(self: *const Gamepad, control: Button) bool {
        return self.released[@backingInt(control)];
    }

    pub fn axisValue(self: *const Gamepad, control: Axis) f32 {
        return self.axes[@backingInt(control)];
    }

    fn beginPoll(self: *Gamepad) void {
        @memset(&self.pressed, false);
        @memset(&self.released, false);
    }

    fn setButton(self: *Gamepad, control: Button, down: bool) void {
        const index = @backingInt(control);
        if (down and !self.buttons[index]) self.pressed[index] = true;
        if (!down and self.buttons[index]) self.released[index] = true;
        self.buttons[index] = down;
    }

    fn setAxis(self: *Gamepad, control: Axis, value: f32) void {
        self.axes[@backingInt(control)] = value;
    }
};

const EvdevSlot = struct {
    device: sys.evdev.Device,
    event_index: u32 = 0,
    pad: Gamepad = .{},
    axis_ranges: [axis_count]sys.evdev.AbsInfo = @splat(.{
        .value = 0,
        .minimum = 0,
        .maximum = 0,
        .fuzz = 0,
        .flat = 0,
        .resolution = 0,
    }),
};

const GameControllerSlot = struct {
    controller: gamecontroller.Controller,
    seen: bool = false,
    pad: Gamepad = .{},
};

const UnsupportedSlot = struct {
    pad: Gamepad = .{},
};

const Slot = switch (source_kind) {
    .evdev => EvdevSlot,
    .gamecontroller => GameControllerSlot,
    .unsupported => UnsupportedSlot,
};

const GameControllerRuntime = if (gamecontroller.supported)
    ?gamecontroller.Runtime
else
    void;

pub const State = struct {
    allocator: std.mem.Allocator,
    slots: []?Slot,
    names: []u8,
    read_events: []sys.evdev.InputEvent,
    retained_name_byte_count_per_gamepad: usize,
    scanned_source_count: u32,
    gamecontroller_runtime: GameControllerRuntime,
    polls_until_rescan: u32 = 0,
    rejected_discovery_count: u64 = 0,
    disconnected: Gamepad = .{},

    pub fn init(allocator: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!State {
        std.debug.assert(capacity.retained_gamepad_count > 0);
        std.debug.assert(capacity.retained_name_byte_count_per_gamepad > 0);
        if (comptime source_kind == .evdev) {
            std.debug.assert(
                capacity.retained_name_byte_count_per_gamepad <= sys.evdev.max_query_bytes,
            );
            std.debug.assert(capacity.read_event_count > 0);
        } else {
            std.debug.assert(capacity.read_event_count == 0);
            std.debug.assert(capacity.read_event_bytes == 0);
        }
        std.debug.assert(capacity.scanned_source_count > 0);
        std.debug.assert(capacity.slot_bytes % @sizeOf(?Slot) == 0);
        std.debug.assert(
            capacity.slot_bytes / @sizeOf(?Slot) == capacity.retained_gamepad_count,
        );
        std.debug.assert(
            capacity.name_bytes % capacity.retained_name_byte_count_per_gamepad == 0,
        );
        std.debug.assert(
            capacity.name_bytes / capacity.retained_name_byte_count_per_gamepad ==
                capacity.retained_gamepad_count,
        );
        if (comptime source_kind == .evdev) {
            std.debug.assert(capacity.read_event_bytes % @sizeOf(sys.evdev.InputEvent) == 0);
            std.debug.assert(
                capacity.read_event_bytes / @sizeOf(sys.evdev.InputEvent) ==
                    capacity.read_event_count,
            );
        }
        const slots = try allocator.alloc(?Slot, capacity.retained_gamepad_count);
        errdefer allocator.free(slots);
        @memset(slots, null);
        const names = try allocator.alloc(u8, capacity.name_bytes);
        errdefer allocator.free(names);
        const read_events: []sys.evdev.InputEvent = if (comptime source_kind == .evdev)
            try allocator.alloc(sys.evdev.InputEvent, capacity.read_event_count)
        else
            @constCast((&[_]sys.evdev.InputEvent{})[0..]);
        return .{
            .allocator = allocator,
            .slots = slots,
            .names = names,
            .read_events = read_events,
            .retained_name_byte_count_per_gamepad = capacity.retained_name_byte_count_per_gamepad,
            .scanned_source_count = capacity.scanned_source_count,
            .gamecontroller_runtime = if (comptime gamecontroller.supported)
                gamecontroller.Runtime.init()
            else {},
        };
    }

    pub fn deinit(self: *State) void {
        std.debug.assert(self.slots.len > 0);
        std.debug.assert(
            self.names.len == self.slots.len * self.retained_name_byte_count_per_gamepad,
        );
        if (comptime source_kind == .evdev) {
            std.debug.assert(self.read_events.len > 0);
        } else {
            std.debug.assert(self.read_events.len == 0);
        }
        for (self.slots) |*slot| releaseSlot(slot);
        if (comptime source_kind == .evdev) self.allocator.free(self.read_events);
        self.allocator.free(self.names);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn poll(self: *State) void {
        switch (comptime source_kind) {
            .evdev => self.pollEvdev(),
            .gamecontroller => self.pollGameControllers(),
            .unsupported => {},
        }
    }

    fn pollEvdev(self: *State) void {
        if (self.polls_until_rescan == 0) {
            self.rescan();
            self.polls_until_rescan = rescan_poll_interval;
        }
        self.polls_until_rescan -= 1;

        for (self.slots) |*slot_ref| {
            const slot = &(slot_ref.* orelse continue);
            slot.pad.beginPoll();
            while (true) {
                const count = slot.device.readEvents(self.read_events) catch {
                    slot.device.close();
                    slot_ref.* = null;
                    break;
                };
                if (count == 0) break;
                for (self.read_events[0..count]) |event| {
                    applyEvent(slot, event);
                }
            }
        }
    }

    fn pollGameControllers(self: *State) void {
        const runtime = if (self.gamecontroller_runtime) |*value| value else return;
        beginGameControllerPoll(self);
        var controllers = runtime.controllers();
        defer controllers.deinit();

        const scan_count = @min(
            controllers.count,
            @as(usize, self.scanned_source_count),
        );
        std.debug.assert(scan_count <= @as(usize, self.scanned_source_count));
        var index: usize = 0;
        while (index < scan_count) : (index += 1) {
            updateTrackedGameController(self, runtime, controllers.at(index));
        }
        finishGameControllerPoll(self);
        index = 0;
        while (index < scan_count) : (index += 1) {
            adoptGameController(self, runtime, controllers.at(index));
        }
        if (controllers.count > scan_count) {
            self.rejectDiscoveries(controllers.count - scan_count);
        }
    }

    pub fn rescan(self: *State) void {
        if (comptime !sys.evdev.supported) return;
        var index: u32 = 0;
        while (index < self.scanned_source_count) : (index += 1) {
            var path_buffer: [32]u8 = undefined;
            const path = sys.evdev.eventPath(&path_buffer, index) catch continue;
            if (self.tracksEventIndex(index)) continue;
            const device = sys.evdev.Device.open(path) catch continue;
            if (!adoptEvdev(self, device, index)) device.close();
        }
    }

    fn tracksEventIndex(self: *const State, index: u32) bool {
        for (self.slots) |slot| {
            if (slot) |held| {
                if (held.event_index == index) return true;
            }
        }
        return false;
    }

    pub fn connectedCount(self: *const State) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot != null) count += 1;
        }
        return count;
    }

    pub fn gamepad(self: *const State, index: usize) *const Gamepad {
        if (index >= self.slots.len) return &self.disconnected;
        if (self.slots[index]) |*slot| return &slot.pad;
        return &self.disconnected;
    }

    pub fn status(self: *const State) Status {
        return .{ .rejected_discovery_count = self.rejected_discovery_count };
    }

    fn availableSlotIndex(self: *State) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (slot == null) return index;
        }
        self.rejected_discovery_count +|= 1;
        return null;
    }

    fn rejectDiscoveries(self: *State, count: usize) void {
        const increment = std.math.cast(u64, count) orelse std.math.maxInt(u64);
        self.rejected_discovery_count +|= increment;
    }

    fn nameStorage(self: *State, index: usize) []u8 {
        std.debug.assert(index < self.slots.len);
        const start = index * self.retained_name_byte_count_per_gamepad;
        const end = start + self.retained_name_byte_count_per_gamepad;
        std.debug.assert(end <= self.names.len);
        return self.names[start..end];
    }
};

fn releaseSlot(slot: *?Slot) void {
    if (slot.*) |held| switch (comptime source_kind) {
        .evdev => held.device.close(),
        .gamecontroller => held.controller.release(),
        .unsupported => {},
    };
    slot.* = null;
}

fn adoptEvdev(state: *State, device: sys.evdev.Device, index: u32) bool {
    var key_bits: sys.evdev.KeyBits = undefined;
    device.keyBits(&key_bits) catch return false;
    if (!sys.evdev.isGamepad(&key_bits)) return false;

    const slot_index = state.availableSlotIndex() orelse return false;
    var slot = EvdevSlot{ .device = device, .event_index = index };
    slot.pad.connected = true;
    const name_storage = state.nameStorage(slot_index);
    if (device.name(name_storage)) |device_name| {
        slot.pad.name_bytes = device_name;
    } else |_| {}
    for (axis_codes, 0..) |code, axis_index| {
        if (device.absInfo(code)) |info| {
            slot.axis_ranges[axis_index] = info;
        } else |_| {}
    }
    state.slots[slot_index] = slot;
    return true;
}

fn beginGameControllerPoll(state: *State) void {
    for (state.slots) |*slot_ref| {
        const slot = &(slot_ref.* orelse continue);
        slot.seen = false;
        slot.pad.beginPoll();
    }
}

fn updateTrackedGameController(
    state: *State,
    runtime: *const gamecontroller.Runtime,
    controller: gamecontroller.Controller,
) void {
    const profile = runtime.extendedGamepad(controller) orelse return;
    for (state.slots) |*slot_ref| {
        const slot = &(slot_ref.* orelse continue);
        if (!slot.controller.eql(controller)) continue;
        slot.seen = true;
        applyGameControllerProfile(runtime, &slot.pad, profile);
        return;
    }
}

fn adoptGameController(
    state: *State,
    runtime: *const gamecontroller.Runtime,
    controller: gamecontroller.Controller,
) void {
    const profile = runtime.extendedGamepad(controller) orelse return;
    for (state.slots) |slot| {
        const held = slot orelse continue;
        if (held.controller.eql(controller)) return;
    }

    const slot_index = state.availableSlotIndex() orelse return;
    var slot = GameControllerSlot{
        .controller = controller.retain(),
        .seen = true,
    };
    slot.pad.connected = true;
    slot.pad.name_bytes = copyGameControllerName(state, slot_index, runtime, controller);
    applyGameControllerProfile(runtime, &slot.pad, profile);
    state.slots[slot_index] = slot;
}

fn finishGameControllerPoll(state: *State) void {
    for (state.slots) |*slot_ref| {
        const slot = &(slot_ref.* orelse continue);
        if (!slot.seen) releaseSlot(slot_ref);
    }
}

fn copyGameControllerName(
    state: *State,
    slot_index: usize,
    runtime: *const gamecontroller.Runtime,
    controller: gamecontroller.Controller,
) []const u8 {
    const fallback = "Game Controller";
    const source = if (runtime.controllerName(controller)) |name|
        std.mem.span(name)
    else
        fallback;
    const storage = state.nameStorage(slot_index);
    const byte_count = @min(source.len, storage.len);
    @memcpy(storage[0..byte_count], source[0..byte_count]);
    return storage[0..byte_count];
}

const gamecontroller_button_map = [_]struct {
    source: gamecontroller.Button,
    target: Button,
}{
    .{ .source = .a, .target = .south },
    .{ .source = .b, .target = .east },
    .{ .source = .x, .target = .west },
    .{ .source = .y, .target = .north },
    .{ .source = .left_shoulder, .target = .left_bumper },
    .{ .source = .right_shoulder, .target = .right_bumper },
    .{ .source = .options, .target = .select },
    .{ .source = .menu, .target = .start },
    .{ .source = .home, .target = .guide },
    .{ .source = .left_thumbstick, .target = .left_thumb },
    .{ .source = .right_thumbstick, .target = .right_thumb },
    .{ .source = .dpad_up, .target = .dpad_up },
    .{ .source = .dpad_down, .target = .dpad_down },
    .{ .source = .dpad_left, .target = .dpad_left },
    .{ .source = .dpad_right, .target = .dpad_right },
};

const gamecontroller_axis_map = [_]struct {
    source: gamecontroller.Axis,
    target: Axis,
    scale: f32,
}{
    .{ .source = .left_thumbstick_x, .target = .left_x, .scale = 1 },
    .{ .source = .left_thumbstick_y, .target = .left_y, .scale = -1 },
    .{ .source = .right_thumbstick_x, .target = .right_x, .scale = 1 },
    .{ .source = .right_thumbstick_y, .target = .right_y, .scale = -1 },
    .{ .source = .left_trigger, .target = .left_trigger, .scale = 1 },
    .{ .source = .right_trigger, .target = .right_trigger, .scale = 1 },
};

fn applyGameControllerProfile(
    runtime: *const gamecontroller.Runtime,
    pad: *Gamepad,
    profile: gamecontroller.Profile,
) void {
    for (gamecontroller_button_map) |mapping| {
        pad.setButton(mapping.target, runtime.buttonPressed(profile, mapping.source));
    }
    for (gamecontroller_axis_map) |mapping| {
        pad.setAxis(
            mapping.target,
            runtime.axisValue(profile, mapping.source) * mapping.scale,
        );
    }
}

const axis_codes = [axis_count]u16{
    sys.evdev.axis.x,
    sys.evdev.axis.y,
    sys.evdev.axis.rx,
    sys.evdev.axis.ry,
    sys.evdev.axis.z,
    sys.evdev.axis.rz,
};

fn applyEvent(slot: *EvdevSlot, event: sys.evdev.InputEvent) void {
    switch (event.kind) {
        sys.evdev.event_kind.key => {
            const control = buttonFromCode(event.code) orelse return;
            slot.pad.setButton(control, event.value != 0);
        },
        sys.evdev.event_kind.abs => applyAbs(slot, event.code, event.value),
        else => {},
    }
}

fn applyAbs(slot: *EvdevSlot, code: u16, value: i32) void {
    switch (code) {
        sys.evdev.axis.hat0x => {
            slot.pad.setButton(.dpad_left, value < 0);
            slot.pad.setButton(.dpad_right, value > 0);
        },
        sys.evdev.axis.hat0y => {
            slot.pad.setButton(.dpad_up, value < 0);
            slot.pad.setButton(.dpad_down, value > 0);
        },
        else => {
            const control = axisFromCode(code) orelse return;
            const info = slot.axis_ranges[@backingInt(control)];
            const normalized = switch (control) {
                .left_trigger, .right_trigger => sys.evdev.normalizeTrigger(info, value),
                else => sys.evdev.normalizeAxis(info, value),
            };
            slot.pad.setAxis(control, normalized);
        },
    }
}

fn buttonFromCode(code: u16) ?Button {
    return switch (code) {
        sys.evdev.button.south => .south,
        sys.evdev.button.east => .east,
        sys.evdev.button.west => .west,
        sys.evdev.button.north => .north,
        sys.evdev.button.left_bumper => .left_bumper,
        sys.evdev.button.right_bumper => .right_bumper,
        sys.evdev.button.select => .select,
        sys.evdev.button.start => .start,
        sys.evdev.button.mode => .guide,
        sys.evdev.button.left_thumb => .left_thumb,
        sys.evdev.button.right_thumb => .right_thumb,
        sys.evdev.button.dpad_up => .dpad_up,
        sys.evdev.button.dpad_down => .dpad_down,
        sys.evdev.button.dpad_left => .dpad_left,
        sys.evdev.button.dpad_right => .dpad_right,
        else => null,
    };
}

fn axisFromCode(code: u16) ?Axis {
    return switch (code) {
        sys.evdev.axis.x => .left_x,
        sys.evdev.axis.y => .left_y,
        sys.evdev.axis.rx => .right_x,
        sys.evdev.axis.ry => .right_y,
        sys.evdev.axis.z => .left_trigger,
        sys.evdev.axis.rz => .right_trigger,
        else => null,
    };
}

fn initTestState(limits: Limits) !State {
    return State.init(std.testing.allocator, try Capacity.derive(limits));
}

test "gamepad capacity derives exact storage and rejects invalid limits" {
    const capacity = try Capacity.derive(.{});
    const expected_read_event_count: usize = if (source_kind == .evdev) 32 else 0;
    const expected_read_event_bytes = expected_read_event_count *
        @sizeOf(sys.evdev.InputEvent);
    try std.testing.expectEqual(@as(usize, 4), capacity.retained_gamepad_count);
    try std.testing.expectEqual(@as(usize, 64), capacity.retained_name_byte_count_per_gamepad);
    try std.testing.expectEqual(expected_read_event_count, capacity.read_event_count);
    try std.testing.expectEqual(@as(u32, 32), capacity.scanned_source_count);
    try std.testing.expectEqual(4 * @sizeOf(?Slot), capacity.slot_bytes);
    try std.testing.expectEqual(@as(usize, 4 * 64), capacity.name_bytes);
    try std.testing.expectEqual(expected_read_event_bytes, capacity.read_event_bytes);
    try std.testing.expectEqual(
        capacity.slot_bytes + capacity.name_bytes + capacity.read_event_bytes,
        capacity.retained_storage_bytes,
    );
    try std.testing.expectError(error.GamepadStorageEmpty, Capacity.derive(.{
        .retained_gamepad_count = 0,
    }));
    try std.testing.expectError(error.NameStorageEmpty, Capacity.derive(.{
        .retained_name_byte_count_per_gamepad = 0,
    }));
    if (comptime source_kind == .evdev) {
        try std.testing.expectError(error.NameStorageTooLarge, Capacity.derive(.{
            .retained_name_byte_count_per_gamepad = sys.evdev.max_query_bytes + 1,
        }));
        try std.testing.expectError(error.EventReadStorageEmpty, Capacity.derive(.{
            .read_event_count = 0,
        }));
    }
    try std.testing.expectError(error.SourceScanEmpty, Capacity.derive(.{
        .scanned_source_count = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_gamepad_count = std.math.maxInt(usize) / @sizeOf(?Slot) + 1,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_gamepad_count = std.math.maxInt(usize) / sys.evdev.max_query_bytes + 1,
        .retained_name_byte_count_per_gamepad = sys.evdev.max_query_bytes,
    }));
    if (comptime source_kind == .evdev) {
        try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
            .read_event_count = std.math.maxInt(usize) / @sizeOf(sys.evdev.InputEvent) + 1,
        }));
    }
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_gamepad_count = std.math.maxInt(usize) / sys.evdev.max_query_bytes,
        .retained_name_byte_count_per_gamepad = sys.evdev.max_query_bytes,
    }));
}

test "gamepad storage retains nondefault limits and rejects max plus one" {
    const capacity = try Capacity.derive(.{
        .retained_gamepad_count = 2,
        .retained_name_byte_count_per_gamepad = 5,
        .read_event_count = 3,
        .scanned_source_count = 7,
    });
    const allocation_count: usize = if (source_kind == .evdev) 3 else 2;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = allocation_count },
    );
    var state = try State.init(failing.allocator(), capacity);
    defer state.deinit();
    try std.testing.expectEqual(allocation_count, failing.allocations);
    try std.testing.expectEqual(@as(usize, 2), state.slots.len);
    try std.testing.expectEqual(@as(usize, 10), state.names.len);
    const expected_read_event_count: usize = if (source_kind == .evdev) 3 else 0;
    try std.testing.expectEqual(expected_read_event_count, state.read_events.len);
    try std.testing.expectEqual(@as(u32, 7), state.scanned_source_count);
    const read_events_pointer = state.read_events.ptr;
    state.polls_until_rescan = 1;
    state.poll();
    try std.testing.expectEqual(read_events_pointer, state.read_events.ptr);
    try std.testing.expectEqual(allocation_count, failing.allocations);

    const first_name = state.nameStorage(0);
    const second_name = state.nameStorage(1);
    try std.testing.expectEqual(@as(usize, 5), first_name.len);
    try std.testing.expectEqual(@as(usize, 5), second_name.len);
    try std.testing.expectEqual(@intFromPtr(first_name.ptr) + 5, @intFromPtr(second_name.ptr));
    @memcpy(first_name[0..3], "one");
    @memcpy(second_name[0..3], "two");

    if (comptime source_kind != .evdev) return;

    const first_index = state.availableSlotIndex().?;
    state.slots[first_index] = EvdevSlot{
        .device = .{ .fd = -1 },
        .event_index = 3,
        .pad = .{ .connected = true, .name_bytes = first_name[0..3] },
    };
    const second_index = state.availableSlotIndex().?;
    state.slots[second_index] = EvdevSlot{
        .device = .{ .fd = -1 },
        .event_index = 5,
        .pad = .{ .connected = true, .name_bytes = second_name[0..3] },
    };
    try std.testing.expectEqual(@as(usize, 2), state.connectedCount());
    try std.testing.expectEqualStrings("one", state.gamepad(0).name());
    try std.testing.expectEqualStrings("two", state.gamepad(1).name());
    try std.testing.expect(state.availableSlotIndex() == null);
    try std.testing.expectEqual(Status{ .rejected_discovery_count = 1 }, state.status());
    state.rejected_discovery_count = std.math.maxInt(u64);
    try std.testing.expect(state.availableSlotIndex() == null);
    try std.testing.expectEqual(
        Status{ .rejected_discovery_count = std.math.maxInt(u64) },
        state.status(),
    );
    try std.testing.expectEqual(@as(u32, 3), state.slots[0].?.event_index);
    try std.testing.expectEqual(@as(u32, 5), state.slots[1].?.event_index);
    state.slots[0] = null;
    try std.testing.expectEqual(@as(usize, 0), state.availableSlotIndex().?);
    try std.testing.expectEqual(
        Status{ .rejected_discovery_count = std.math.maxInt(u64) },
        state.status(),
    );
    try std.testing.expectEqual(allocation_count, failing.allocations);
    @memset(state.slots, null);
}

test "gamepad storage initialization cleans up every allocation failure" {
    const capacity = try Capacity.derive(.{
        .retained_gamepad_count = 2,
        .retained_name_byte_count_per_gamepad = 5,
        .read_event_count = 3,
    });
    const allocation_count: usize = if (source_kind == .evdev) 3 else 2;
    var fail_index: usize = 0;
    while (fail_index < allocation_count) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(error.OutOfMemory, State.init(failing.allocator(), capacity));
    }

    var state = try State.init(std.testing.allocator, capacity);
    state.deinit();
}

test "buttons track press and release edges" {
    var pad = Gamepad{ .connected = true };
    pad.beginPoll();
    pad.setButton(.south, true);
    try std.testing.expect(pad.isDown(.south));
    try std.testing.expect(pad.isPressed(.south));
    try std.testing.expect(!pad.isReleased(.south));

    pad.beginPoll();
    pad.setButton(.south, true);
    try std.testing.expect(!pad.isPressed(.south));

    pad.beginPoll();
    pad.setButton(.south, false);
    try std.testing.expect(!pad.isDown(.south));
    try std.testing.expect(pad.isReleased(.south));
}

test "hat events become dpad buttons and axes normalize" {
    if (comptime source_kind != .evdev) return error.SkipZigTest;

    var slot = EvdevSlot{ .device = .{ .fd = -1 } };
    slot.axis_ranges[@backingInt(Axis.left_x)] = .{
        .value = 0,
        .minimum = -32768,
        .maximum = 32767,
        .fuzz = 0,
        .flat = 0,
        .resolution = 0,
    };

    applyAbs(&slot, sys.evdev.axis.hat0x, -1);
    try std.testing.expect(slot.pad.isDown(.dpad_left));
    applyAbs(&slot, sys.evdev.axis.hat0x, 0);
    try std.testing.expect(!slot.pad.isDown(.dpad_left));

    applyAbs(&slot, sys.evdev.axis.x, 32767);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), slot.pad.axisValue(.left_x), 0.001);

    applyEvent(&slot, .{
        .seconds = 0,
        .microseconds = 0,
        .kind = sys.evdev.event_kind.key,
        .code = sys.evdev.button.start,
        .value = 1,
    });
    try std.testing.expect(slot.pad.isDown(.start));
}

test "GameController snapshot maps standard buttons and axes" {
    if (comptime source_kind != .gamecontroller) return error.SkipZigTest;

    var state = try initTestState(.{});
    defer state.deinit();
    const runtime = gamecontroller.Runtime.init().?;
    const controller = runtime.createRetainedSnapshot().?;
    defer controller.release();
    const profile = runtime.extendedGamepad(controller).?;
    const button_cases = [_]struct {
        source: gamecontroller.Button,
        target: Button,
    }{
        .{ .source = .a, .target = .south },
        .{ .source = .b, .target = .east },
        .{ .source = .x, .target = .west },
        .{ .source = .y, .target = .north },
        .{ .source = .left_shoulder, .target = .left_bumper },
        .{ .source = .right_shoulder, .target = .right_bumper },
        .{ .source = .menu, .target = .start },
        .{ .source = .dpad_up, .target = .dpad_up },
    };
    for (button_cases) |case| {
        if (case.source == .dpad_up) continue;
        try std.testing.expect(runtime.setButtonValue(profile, case.source, 1));
    }
    try std.testing.expect(runtime.setDirectionPadValue(profile, 0, 1));
    try std.testing.expect(runtime.setAxisValue(profile, .left_thumbstick_x, 0.25));
    try std.testing.expect(runtime.setAxisValue(profile, .left_thumbstick_y, 0.5));
    try std.testing.expect(runtime.setAxisValue(profile, .right_thumbstick_y, -0.75));
    try std.testing.expect(runtime.setAxisValue(profile, .right_trigger, 0.6));

    beginGameControllerPoll(&state);
    finishGameControllerPoll(&state);
    adoptGameController(&state, &runtime, controller);
    const pad = state.gamepad(0);
    for (button_cases) |case| {
        try std.testing.expect(pad.isDown(case.target));
        try std.testing.expect(pad.isPressed(case.target));
    }
    try std.testing.expect(pad.name().len > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), pad.axisValue(.left_x), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), pad.axisValue(.left_y), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), pad.axisValue(.right_y), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), pad.axisValue(.right_trigger), 0.001);
}

test "GameController reconciliation preserves edges and replaces disconnected slots" {
    if (comptime source_kind != .gamecontroller) return error.SkipZigTest;

    var state = try initTestState(.{ .retained_gamepad_count = 1 });
    defer state.deinit();
    const runtime = gamecontroller.Runtime.init().?;
    const first = runtime.createRetainedSnapshot().?;
    defer first.release();
    const second = runtime.createRetainedSnapshot().?;
    defer second.release();
    const first_profile = runtime.extendedGamepad(first).?;
    try std.testing.expect(runtime.setButtonValue(first_profile, .a, 1));

    beginGameControllerPoll(&state);
    updateTrackedGameController(&state, &runtime, first);
    updateTrackedGameController(&state, &runtime, second);
    finishGameControllerPoll(&state);
    adoptGameController(&state, &runtime, first);
    adoptGameController(&state, &runtime, second);
    try std.testing.expectEqual(@as(usize, 1), state.connectedCount());
    try std.testing.expect(state.gamepad(0).isPressed(.south));
    try std.testing.expectEqual(Status{ .rejected_discovery_count = 1 }, state.status());

    beginGameControllerPoll(&state);
    updateTrackedGameController(&state, &runtime, first);
    finishGameControllerPoll(&state);
    adoptGameController(&state, &runtime, first);
    try std.testing.expect(!state.gamepad(0).isPressed(.south));
    try std.testing.expect(runtime.setButtonValue(first_profile, .a, 0));
    beginGameControllerPoll(&state);
    updateTrackedGameController(&state, &runtime, first);
    finishGameControllerPoll(&state);
    try std.testing.expect(state.gamepad(0).isReleased(.south));

    beginGameControllerPoll(&state);
    updateTrackedGameController(&state, &runtime, second);
    finishGameControllerPoll(&state);
    adoptGameController(&state, &runtime, second);
    try std.testing.expectEqual(@as(usize, 1), state.connectedCount());
    try std.testing.expectEqual(Status{ .rejected_discovery_count = 1 }, state.status());
    beginGameControllerPoll(&state);
    finishGameControllerPoll(&state);
    try std.testing.expectEqual(@as(usize, 0), state.connectedCount());
}

test "state hands out a disconnected pad for empty slots" {
    var state = try initTestState(.{});
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.connectedCount());
    try std.testing.expect(!state.gamepad(0).connected);
    try std.testing.expect(!state.gamepad(99).connected);
}

test "live GameController connection enters bounded state" {
    if (comptime source_kind != .gamecontroller) return error.SkipZigTest;

    var state = try initTestState(.{});
    defer state.deinit();
    state.poll();
    if (state.connectedCount() == 0) return error.SkipZigTest;

    const pad = state.gamepad(0);
    try std.testing.expect(pad.connected);
    try std.testing.expect(pad.name().len > 0);
    try std.testing.expect(pad.axisValue(.left_x) >= -1);
    try std.testing.expect(pad.axisValue(.left_x) <= 1);
    try std.testing.expect(pad.axisValue(.left_y) >= -1);
    try std.testing.expect(pad.axisValue(.left_y) <= 1);
    try std.testing.expect(pad.axisValue(.left_trigger) >= 0);
    try std.testing.expect(pad.axisValue(.left_trigger) <= 1);
}

test "live gamepad reports buttons and axes" {
    if (comptime !sys.evdev.supported) return error.SkipZigTest;

    var state = try initTestState(.{});
    defer state.deinit();
    state.rescan();
    if (state.connectedCount() == 0) return error.SkipZigTest;

    var saw_south = false;
    var saw_axis = false;
    var waited_ms: u32 = 0;
    while (waited_ms < 5000 and !(saw_south and saw_axis)) : (waited_ms += 20) {
        state.poll();
        const pad = state.gamepad(0);
        if (pad.isDown(.south) or pad.isPressed(.south)) saw_south = true;
        if (@abs(pad.axisValue(.left_x)) > 0.9) saw_axis = true;
        sys.time.sleepMilliseconds(20);
    }

    try std.testing.expect(state.gamepad(0).name().len > 0);
    try std.testing.expect(saw_south);
    try std.testing.expect(saw_axis);
}
