const std = @import("std");
const hypothesis = @import("hypothesis");
const xkb = @import("xkb");

const Keysym = xkb.keysym.Keysym;

fn settings() hypothesis.Settings {
    var value = hypothesis.Settings.quick()
        .withSeed(0x584b_425f_434f_4d50)
        .withDatabase("zig-out/hypothesis-failures/xkb-compose");
    value.max_examples = 256;
    value.target_examples = 256;
    return value;
}

const sequences = [_][]const u8{
    "a",
    "bc",
    "bd",
    "efg",
};

const outputs = [_][]const u8{
    "one",
    "two",
    "three",
    "four",
};

const Model = struct {
    prefix: [3]u8 = undefined,
    length: usize = 0,
    status: xkb.compose.Status = .nothing,
    output_index: ?usize = null,

    fn reset(self: *Model) void {
        self.length = 0;
        self.status = .nothing;
        self.output_index = null;
    }

    fn feed(self: *Model, symbol: u8) void {
        const previous_status = self.status;
        if (previous_status != .composing) self.length = 0;
        self.output_index = null;
        if (self.length == self.prefix.len) {
            self.status = if (previous_status == .composing) .cancelled else .nothing;
            return;
        }
        self.prefix[self.length] = symbol;
        self.length += 1;

        var has_prefix = false;
        for (sequences, 0..) |sequence, index| {
            if (self.length > sequence.len) continue;
            if (!std.mem.eql(u8, self.prefix[0..self.length], sequence[0..self.length])) continue;
            if (self.length == sequence.len) {
                self.status = .composed;
                self.output_index = index;
                return;
            }
            has_prefix = true;
        }
        if (has_prefix) {
            self.status = .composing;
        } else {
            self.status = if (previous_status == .composing) .cancelled else .nothing;
        }
    }
};

pub const StateProperty = struct {
    pub fn property(conjecture: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const compose_text =
            \\<a> : "one"
            \\<b> <c> : "two"
            \\<b> <d> : "three"
            \\<e> <f> <g> : "four"
        ;
        var storage = try xkb.compose.Storage.init(allocator, .{
            .sequence_symbols = compose_text.len,
            .text_bytes = compose_text.len,
        });
        defer storage.deinit(allocator);
        var scratch_storage = try xkb.compose.ScratchStorage.init(
            allocator,
            xkb.compose.default_scratch_limits,
        );
        defer scratch_storage.deinit(allocator);
        storage.activate();
        scratch_storage.activate();
        const table = try xkb.compose.compile(
            &storage,
            &scratch_storage,
            compose_text,
            .{ .locale = "C" },
        );
        defer storage.reset();
        var state = xkb.compose.State.init(&table);
        var model = Model{};
        const symbols = [_]u32{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', '7', 0xffe1 };
        const operations: usize = @intCast(try conjecture.drawInteger(1, 64, 8));
        for (0..operations) |_| {
            if (try conjecture.drawBoolean()) {
                state.reset();
                model.reset();
            } else {
                const index: usize = @intCast(try conjecture.drawInteger(0, symbols.len - 1, 0));
                const symbol: Keysym = @fromBackingInt(@intCast(symbols[index]));
                const result = state.feed(symbol);
                if (xkb.keysym.isModifier(symbol)) {
                    try std.testing.expectEqual(xkb.compose.FeedResult.ignored, result);
                } else {
                    try std.testing.expectEqual(xkb.compose.FeedResult.accepted, result);
                    model.feed(@intCast(symbols[index]));
                }
            }
            try std.testing.expectEqual(model.status, state.status());
            if (model.output_index) |index| {
                var buffer: [8]u8 = undefined;
                try std.testing.expectEqualStrings(outputs[index], (try state.writeUtf8(&buffer)).?);
            }
        }
    }
};

test "pbt: Compose state follows the prefix model across resets and modifiers" {
    try hypothesis.checkNamed(StateProperty, "xkb-compose-prefix-model", settings());
}
