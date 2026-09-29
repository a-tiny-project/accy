const std = @import("std");
const xkb = @import("../root.zig");
const compose = @import("root.zig");

const Keysym = xkb.keysym.Keysym;

pub const Status = enum {
    nothing,
    composing,
    composed,
    cancelled,
};

pub const FeedResult = enum {
    ignored,
    accepted,
};

pub const TextError = error{BufferTooSmall};

pub const State = struct {
    table: compose.View,
    previous: ?u32 = 0,
    current: ?u32 = 0,

    pub fn init(table: *const compose.Table) State {
        return .{ .table = table.view() };
    }

    pub fn reset(self: *State) void {
        self.previous = 0;
        self.current = 0;
    }

    pub fn feed(self: *State, input_symbol: Keysym) FeedResult {
        if (xkb.keysym.isModifier(input_symbol)) return .ignored;

        const start = if (self.current) |node|
            if (node == 0 or self.table.result(node) == null) node else 0
        else
            0;
        self.previous = self.current;
        self.current = self.table.transition(start, input_symbol);
        return .accepted;
    }

    pub fn status(self: *const State) Status {
        const current = self.current orelse {
            const previous = self.previous orelse return .nothing;
            if (previous != 0 and self.table.result(previous) == null) {
                return .cancelled;
            }
            return .nothing;
        };
        if (current == 0) return .nothing;
        return if (self.table.result(current) == null) .composing else .composed;
    }

    pub fn symbol(self: *const State) ?Keysym {
        const current = self.current orelse return null;
        const result_value = self.table.result(current) orelse return null;
        return result_value.symbol;
    }

    pub fn writeUtf8(self: *const State, buffer: []u8) TextError!?[]const u8 {
        const current = self.current orelse return null;
        const result_value = self.table.result(current) orelse return null;
        if (result_value.text) |text| {
            if (text.len > buffer.len) return error.BufferTooSmall;
            @memcpy(buffer[0..text.len], text);
            return buffer[0..text.len];
        }
        const symbol_value = result_value.symbol orelse return null;
        const codepoint = xkb.keysym.codepoint(symbol_value) orelse return null;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch return null;
        if (length > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[0..length], encoded[0..length]);
        return buffer[0..length];
    }
};

test "state distinguishes composing composed cancelled and fresh input" {
    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 8,
        .text_bytes = 8,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    const table = try compose.compile(
        &storage,
        &scratch_storage,
        \\<Multi_key> <a> : "å" aring
        \\<A> : dollar
    ,
        .{ .locale = "C" },
    );
    defer storage.reset();
    var state = State.init(&table);

    const multi: Keysym = @fromBackingInt(@intCast(0xff20));
    const a: Keysym = @fromBackingInt(@intCast('a'));
    const upper_a: Keysym = @fromBackingInt(@intCast('A'));
    const unknown: Keysym = @fromBackingInt(@intCast('7'));
    try std.testing.expectEqual(Status.nothing, state.status());
    try std.testing.expectEqual(FeedResult.accepted, state.feed(multi));
    try std.testing.expectEqual(Status.composing, state.status());
    try std.testing.expectEqual(FeedResult.ignored, state.feed(@fromBackingInt(@intCast(0xffe1))));
    try std.testing.expectEqual(Status.composing, state.status());
    try std.testing.expectEqual(FeedResult.accepted, state.feed(a));
    try std.testing.expectEqual(Status.composed, state.status());
    try std.testing.expectEqual(@as(?Keysym, @fromBackingInt(@intCast(0x00e5))), state.symbol());
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("å", (try state.writeUtf8(&buffer)).?);

    _ = state.feed(unknown);
    try std.testing.expectEqual(Status.nothing, state.status());
    _ = state.feed(multi);
    _ = state.feed(unknown);
    try std.testing.expectEqual(Status.cancelled, state.status());
    _ = state.feed(upper_a);
    try std.testing.expectEqual(Status.composed, state.status());
    try std.testing.expectEqualStrings("$", (try state.writeUtf8(&buffer)).?);
    state.reset();
    try std.testing.expectEqual(Status.nothing, state.status());
}

test "keysym-only results derive UTF-8 and enforce caller capacity" {
    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 1,
        .text_bytes = 0,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    const table = try compose.compile(
        &storage,
        &scratch_storage,
        "<A> : U1F600\n",
        .{ .locale = "C" },
    );
    defer storage.reset();
    var state = State.init(&table);
    _ = state.feed(@fromBackingInt(@intCast('A')));
    var short: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, state.writeUtf8(&short));
    var enough: [4]u8 = undefined;
    try std.testing.expectEqualStrings("😀", (try state.writeUtf8(&enough)).?);
}
