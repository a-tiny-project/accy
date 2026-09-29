const std = @import("std");
const hypothesis = @import("hypothesis");
const stabilizer = @import("stabilizer");

const Allocator = std.mem.Allocator;

const code_alignment = stabilizer.code_alignment;

const FunctionId = stabilizer.FunctionId;
const FunctionEntryState = stabilizer.FunctionEntryState;
const CodeRandomizer = stabilizer.CodeRandomizer;

fn settings() hypothesis.Settings {
    return hypothesis.Settings.quick()
        .withSeed(0x57ab_11e5)
        .withDatabase("zig-out/hypothesis-failures/stabilizer");
}

fn drawUsize(data: *hypothesis.ConjectureData, min: usize, max: usize, shrink_towards: usize) !usize {
    return @intCast(try data.drawInteger(
        @intCast(min),
        @intCast(max),
        @intCast(shrink_towards),
    ));
}

test "code randomizer preserves live defunct locations across marked sweep" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    const function = try code.registerFunction(.{ .code_size = 64, .table_size = 16, .table_adjacent = true });
    const first = try code.relocate(function);
    const root = first.base + 4;
    _ = try code.relocate(function);
    code.beginRerandomization();
    _ = try code.trap(function, &.{root});

    try std.testing.expect(code.locationCount() >= 2);
    var saw_marked_survivor = false;
    for (code.locations.items) |location| {
        if (location.base == first.base) saw_marked_survivor = true;
    }
    try std.testing.expect(saw_marked_survivor);
}

test "code randomizer adjusts relocated addresses back to original code" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    const function = try code.registerFunction(.{ .code_size = 64, .table_size = 16, .table_adjacent = true });
    const original = code.originalBase(function).?;
    const first = try code.relocate(function);
    const first_base = first.base;
    const first_size = first.size;
    try std.testing.expectEqual(original + 5, code.adjustAddress(first_base + 5));
    try std.testing.expectEqual(original + 70, code.adjustAddress(first_base + 70));

    const unrelated = first_base + first_size + 1024;
    try std.testing.expectEqual(unrelated, code.adjustAddress(unrelated));

    const second = try code.relocate(function);
    const second_base = second.base;
    try std.testing.expectEqual(original + 9, code.adjustAddress(first_base + 9));
    try std.testing.expectEqual(original + 9, code.adjustAddress(second_base + 9));

    code.sweep();
    try std.testing.expectEqual(first_base + 9, code.adjustAddress(first_base + 9));
    try std.testing.expectEqual(original + 9, code.adjustAddress(second_base + 9));
}

test "code randomizer forwards timer interrupts at live function entries" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    const active = try code.registerFunction(.{ .code_size = 64 });
    const inactive = try code.registerFunction(.{ .code_size = 64 });
    const active_location = try code.relocate(active);
    const active_base = active_location.base;
    const active_original = code.originalBase(active).?;
    const inactive_original = code.originalBase(inactive).?;

    try std.testing.expectEqual(active_base, code.beginRerandomizationAt(active_original));
    try std.testing.expectEqual(FunctionEntryState.trap, code.entryState(active).?);
    try std.testing.expectEqual(FunctionEntryState.trap, code.entryState(inactive).?);
    try std.testing.expectEqual(@as(usize, 0), code.live.items.len);
    try std.testing.expect(code.rerandomizing);

    const offset_entry = active_original + 1;
    try std.testing.expectEqual(offset_entry, code.beginRerandomizationAt(offset_entry));
    try std.testing.expectEqual(inactive_original, code.beginRerandomizationAt(inactive_original));
}

test "code randomizer models trap and forwarding entry states" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    const function = try code.registerFunction(.{ .code_size = 64 });
    try std.testing.expectEqual(FunctionEntryState.trap, code.entryState(function).?);

    const first = (try code.enterFunction(function, &.{})).?;
    try std.testing.expectEqual(FunctionEntryState.forwarding, code.entryState(function).?);
    try std.testing.expectEqual(@as(usize, 1), code.locationCount());

    const forwarded = (try code.enterFunction(function, &.{})).?;
    try std.testing.expectEqual(first.id, forwarded.id);
    try std.testing.expectEqual(@as(usize, 1), code.locationCount());

    code.beginRerandomization();
    try std.testing.expectEqual(FunctionEntryState.trap, code.entryState(function).?);
    const second = (try code.enterFunction(function, &.{})).?;
    try std.testing.expect(second.id != first.id);
    try std.testing.expectEqual(FunctionEntryState.forwarding, code.entryState(function).?);
    try std.testing.expectEqual(@as(usize, 2), code.locationCount());
}

test "disabled code randomizer is inert" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .enabled = false }, 55);
    defer code.deinit();

    try std.testing.expectError(
        error.CodeRandomizationDisabled,
        code.registerFunction(.{ .code_size = 64 }),
    );
    try std.testing.expectError(
        error.CodeRandomizationDisabled,
        code.registerFunctionImage(.{ .code = &.{0xaa} }),
    );
    code.beginRerandomization();
    try std.testing.expect(!code.rerandomizing);
    try std.testing.expectEqual(@as(usize, 0), code.locationCount());
    try std.testing.expectError(error.CodeRandomizationDisabled, code.relocate(1));
    try std.testing.expectError(error.CodeRandomizationDisabled, code.trap(1, &.{}));
    code.markAddress(0);
    code.sweep();
    try std.testing.expectEqual(@as(usize, 0), code.locationCount());
}

const CodeProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        var code = CodeRandomizer.init(allocator, .{
            .shuffle_slots = 16,
            .alignment = code_alignment,
        }, 0x434f_4445);
        defer code.deinit();

        const functions = try drawUsize(data, 1, 8, 2);
        var ids: [8]FunctionId = undefined;
        var index: usize = 0;
        while (index < functions) : (index += 1) {
            ids[index] = try code.registerFunction(.{
                .code_size = try drawUsize(data, 1, 512, 64),
                .table_size = try drawUsize(data, 0, 128, 0),
                .table_adjacent = try data.drawBoolean(),
            });
        }

        const steps = try drawUsize(data, 1, 64, 8);
        index = 0;
        while (index < steps) : (index += 1) {
            const id = ids[try drawUsize(data, 0, functions - 1, 0)];
            if (try data.drawBoolean()) code.beginRerandomization();
            const current = code.currentLocation(id);
            var roots_buf: [1]usize = undefined;
            const roots: []const usize = if (current) |location| blk: {
                roots_buf[0] = location.base;
                break :blk roots_buf[0..1];
            } else &.{};
            const location = try code.trap(id, roots);
            try std.testing.expect(std.mem.isAligned(location.base, code_alignment));
            try std.testing.expect(location.size == code.allocationSize(id).?);
            try std.testing.expect(code.currentLocation(id).?.id == location.id);
        }
    }
};

test "pbt: code relocation model keeps current locations coherent" {
    try hypothesis.checkNamed(CodeProperty, "stabilizer-code", settings());
}

const FunctionRangeProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        var code = CodeRandomizer.init(allocator, .{
            .shuffle_slots = 16,
            .alignment = code_alignment,
        }, 0x5241_4e47);
        defer code.deinit();

        const code_len = try drawUsize(data, 1, 64, 4);
        const image_code = try allocator.alloc(u8, code_len);
        defer allocator.free(image_code);
        for (image_code, 0..) |*byte, index| byte.* = @truncate(index);

        const table_words = try drawUsize(data, 0, 8, 2);
        const table_len = table_words * @sizeOf(usize);
        const table = try allocator.alloc(u8, table_len);
        defer allocator.free(table);

        var stack_pad: u8 = @truncate(try drawUsize(data, 0, 255, 0));
        const stack_pad_address = @intFromPtr(&stack_pad);
        var expected_offsets: [8]usize = undefined;
        var expected_values: [8]usize = undefined;
        var expected_count: usize = 0;
        var word: usize = 0;
        while (word < table_words) : (word += 1) {
            const offset = word * @sizeOf(usize);
            const use_stack_pad = try data.drawBoolean();
            const value = if (use_stack_pad) stack_pad_address else 0x1000 + word * 17;
            std.mem.writeInt(usize, table[offset..][0..@sizeOf(usize)], value, .little);
            expected_values[word] = value;
            if (use_stack_pad) {
                expected_offsets[expected_count] = offset;
                expected_count += 1;
            }
        }

        const adjacent = try data.drawBoolean();
        const function = try code.registerFunctionRange(.{
            .code_base = image_code.ptr,
            .code_limit = image_code.ptr + image_code.len,
            .table_base = if (table.len == 0) null else table.ptr,
            .table_size = table.len,
            .table_adjacent = adjacent,
            .stack_pad = &stack_pad,
        });
        try std.testing.expectEqual(@as(usize, 1), code.functionCount());
        try std.testing.expectEqual(stack_pad, code.stackPadUnit(function).?);

        const location = try code.relocate(function);
        const expected_len = if (adjacent) image_code.len + table.len else image_code.len;
        try std.testing.expectEqual(expected_len, location.contents.len);
        try std.testing.expectEqualSlices(u8, image_code, location.contents[0..image_code.len]);

        if (expected_count > 0) {
            const relocated_stack_pad_address = code.stackPadAddress(function).?;
            var index: usize = 0;
            while (index < expected_count) : (index += 1) {
                const offset = expected_offsets[index];
                if (adjacent) {
                    try std.testing.expectEqual(relocated_stack_pad_address, std.mem.readInt(
                        usize,
                        location.contents[image_code.len + offset ..][0..@sizeOf(usize)],
                        .little,
                    ));
                }
            }
        } else {
            try std.testing.expect(code.stackPadAddress(function) == null);
        }

        if (adjacent) {
            word = 0;
            while (word < table_words) : (word += 1) {
                const offset = word * @sizeOf(usize);
                const value = std.mem.readInt(
                    usize,
                    location.contents[image_code.len + offset ..][0..@sizeOf(usize)],
                    .little,
                );
                if (expected_values[word] != stack_pad_address) {
                    try std.testing.expectEqual(expected_values[word], value);
                }
            }
        }
    }
};

test "pbt: function range registration patches stack pad table entries" {
    try hypothesis.checkNamed(FunctionRangeProperty, "stabilizer-function-range", settings());
}
