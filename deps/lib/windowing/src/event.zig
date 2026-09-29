const std = @import("std");
const Key = @import("key.zig").Key;
const MouseButton = @import("mouse.zig").MouseButton;
const Modifier = @import("modifier.zig").Modifier;

pub const max_text_input_bytes = 16;

pub const Limits = struct {
    retained_event_count: usize = 256,
};

pub const CapacityError = error{
    RetainedEventsEmpty,
    CapacityOverflow,
};

pub const Capacity = struct {
    retained_event_count: usize,
    retained_event_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.retained_event_count == 0) return error.RetainedEventsEmpty;
        const retained_event_bytes = std.math.mul(
            usize,
            limits.retained_event_count,
            @sizeOf(Event),
        ) catch return error.CapacityOverflow;
        std.debug.assert(retained_event_bytes / @sizeOf(Event) == limits.retained_event_count);
        return .{
            .retained_event_count = limits.retained_event_count,
            .retained_event_bytes = retained_event_bytes,
        };
    }
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifier = .{},
    repeated: bool = false,
};

pub const TextInputEvent = struct {
    bytes: [max_text_input_bytes]u8 = undefined,
    len: u8 = 0,
    modifiers: Modifier = .{},

    pub fn text(self: *const TextInputEvent) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    x: i32,
    y: i32,
    modifiers: Modifier = .{},
};

pub const MouseMoveEvent = struct {
    x: i32,
    y: i32,
};

pub const MouseWheelEvent = struct {
    x: i32,
    y: i32,
    delta_x: f32 = 0,
    delta_y: f32 = 0,
    modifiers: Modifier = .{},
};

pub const SizeEvent = struct {
    width: u32,
    height: u32,
};

pub const FocusEvent = struct {
    focused: bool,
};

pub const Event = union(enum) {
    key_press: KeyEvent,
    key_release: KeyEvent,
    text_input: TextInputEvent,
    mouse_press: MouseButtonEvent,
    mouse_release: MouseButtonEvent,
    mouse_move: MouseMoveEvent,
    mouse_wheel: MouseWheelEvent,
    window_resize: SizeEvent,
    window_close,
    window_focus: FocusEvent,

    pub fn textInput(bytes: []const u8, modifiers: Modifier) ?Event {
        const len = textInputLen(bytes) orelse return null;
        var event = TextInputEvent{
            .len = @intCast(len),
            .modifiers = modifiers,
        };
        @memcpy(event.bytes[0..len], bytes[0..len]);
        return .{ .text_input = event };
    }
};

fn textInputLen(bytes: []const u8) ?usize {
    if (bytes.len == 0 or bytes.len > max_text_input_bytes) return null;
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;

    var iterator = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or codepoint == 0x7f) return null;
    }
    return bytes.len;
}

pub const EventIterator = struct {
    events: []const Event,
    index: usize = 0,

    pub fn next(self: *EventIterator) ?Event {
        if (self.index >= self.events.len) return null;
        const ev = self.events[self.index];
        self.index += 1;
        return ev;
    }

    pub fn reset(self: *EventIterator) void {
        self.index = 0;
    }
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    items: []Event,
    retained_count: usize = 0,
    dropped_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Queue {
        std.debug.assert(capacity.retained_event_count > 0);
        std.debug.assert(
            capacity.retained_event_bytes / @sizeOf(Event) == capacity.retained_event_count,
        );
        return .{
            .allocator = allocator,
            .items = try allocator.alloc(Event, capacity.retained_event_count),
        };
    }

    pub fn deinit(self: *Queue) void {
        std.debug.assert(self.items.len > 0);
        std.debug.assert(self.retained_count <= self.items.len);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn beginPoll(self: *Queue) void {
        std.debug.assert(self.retained_count <= self.items.len);
        self.retained_count = 0;
    }

    pub fn push(self: *Queue, event: Event) bool {
        std.debug.assert(self.retained_count <= self.items.len);
        if (self.retained_count == self.items.len) {
            self.dropped_count +|= 1;
            return false;
        }
        self.items[self.retained_count] = event;
        self.retained_count += 1;
        return true;
    }

    pub fn iterator(self: *const Queue) EventIterator {
        std.debug.assert(self.retained_count <= self.items.len);
        return .{ .events = self.items[0..self.retained_count] };
    }

    pub fn droppedEventCount(self: *const Queue) u64 {
        return self.dropped_count;
    }
};

test "event queue capacity derives exact storage and rejects invalid limits" {
    const capacity = try Capacity.derive(.{});
    try std.testing.expectEqual(@as(usize, 256), capacity.retained_event_count);
    try std.testing.expectEqual(256 * @sizeOf(Event), capacity.retained_event_bytes);
    try std.testing.expectError(error.RetainedEventsEmpty, Capacity.derive(.{
        .retained_event_count = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_event_count = std.math.maxInt(usize) / @sizeOf(Event) + 1,
    }));
}

test "event queue retains its limit and allocates only during initialization" {
    const capacity = try Capacity.derive(.{ .retained_event_count = 2 });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var queue = try Queue.init(failing.allocator(), capacity);
    defer queue.deinit();
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);

    try std.testing.expect(queue.push(.window_close));
    try std.testing.expect(queue.push(.{ .window_focus = .{ .focused = true } }));
    try std.testing.expect(!queue.push(.{ .window_focus = .{ .focused = false } }));
    try std.testing.expectEqual(@as(u64, 1), queue.droppedEventCount());

    var retained = queue.iterator();
    try std.testing.expect(retained.next().? == .window_close);
    try std.testing.expect(retained.next().?.window_focus.focused);
    try std.testing.expect(retained.next() == null);

    queue.beginPoll();
    try std.testing.expect(queue.push(.{ .window_focus = .{ .focused = false } }));
    retained = queue.iterator();
    try std.testing.expect(!retained.next().?.window_focus.focused);
    try std.testing.expect(retained.next() == null);

    queue.dropped_count = std.math.maxInt(u64);
    try std.testing.expect(queue.push(.window_close));
    try std.testing.expect(!queue.push(.window_close));
    try std.testing.expectEqual(std.math.maxInt(u64), queue.droppedEventCount());
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
}

test "text input event stores valid UTF-8 text" {
    const event = Event.textInput("λ", .{ .ctrl = true }).?;
    try std.testing.expectEqualStrings("λ", event.text_input.text());
    try std.testing.expect(event.text_input.modifiers.ctrl);
}

test "text input event rejects controls and oversized chunks" {
    try std.testing.expect(Event.textInput("\n", .{}) == null);
    try std.testing.expect(
        Event.textInput(&(@as([(max_text_input_bytes + 1)]u8, @splat('x'))), .{}) == null,
    );
}
