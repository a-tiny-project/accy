const std = @import("std");
const hypothesis = @import("hypothesis");
const stabilizer = @import("stabilizer");

const Allocator = std.mem.Allocator;

const stack_alignment = stabilizer.stack_alignment;
const max_stack_pad_unit = stabilizer.max_stack_pad_unit;

const Marsaglia = stabilizer.Marsaglia;
const StackPads = stabilizer.StackPads;
const FunctionEntryState = stabilizer.FunctionEntryState;
const CodeRandomizer = stabilizer.CodeRandomizer;
const Runtime = stabilizer.Runtime;

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

test "stack pad draw stays within byte aligned range" {
    var runtime = try Runtime.init(std.testing.allocator, .{ .seed = 1 });
    defer runtime.deinit();

    var index: usize = 0;
    while (index < 1024) : (index += 1) {
        const pad = runtime.nextStackPad();
        try std.testing.expect(pad.unit <= max_stack_pad_unit);
        try std.testing.expectEqual(@as(usize, pad.unit) * stack_alignment, pad.bytes);
    }
}

test "stack config preserves upstream sixteen byte multiplier" {
    var rng = Marsaglia.init(10);
    var pads = try StackPads.init(std.testing.allocator, .{
        .entries = 4,
        .alignment = 3,
    }, &rng);
    defer pads.deinit();

    var index: usize = 0;
    while (index < 16) : (index += 1) {
        const pad = pads.next(&rng);
        try std.testing.expectEqual(@as(usize, pad.unit) * stack_alignment, pad.bytes);
    }
}

test "code randomizer refreshes function stack pad on relocation" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    const function = try code.registerFunction(.{
        .code_size = 64,
        .stack_pad_unit = 0,
    });
    try std.testing.expectEqual(@as(u8, 0), code.stackPadUnit(function).?);

    _ = try code.relocate(function);
    const first = code.stackPad(function).?;
    try std.testing.expectEqual(@as(usize, first.unit) * stack_alignment, first.bytes);

    _ = try code.relocate(function);
    const second = code.stackPad(function).?;
    try std.testing.expectEqual(@as(usize, second.unit) * stack_alignment, second.bytes);
}

test "runtime refills stack pads only before code functions register" {
    var expected_rng = Marsaglia.init(9);
    _ = expected_rng.nextByte();
    const expected_refill = expected_rng.nextByte();

    var runtime = try Runtime.init(std.testing.allocator, .{
        .seed = 9,
        .stack = .{ .entries = 1 },
        .code = .{ .enabled = true },
    });
    defer runtime.deinit();

    runtime.stack.entries[0] = 0;
    runtime.rerandomize();
    try std.testing.expectEqual(expected_refill, runtime.stack.entries[0]);
    try std.testing.expect(runtime.code.rerandomizing);

    runtime.stack.entries[0] = 0xaa;
    const function = try runtime.code.registerFunction(.{
        .code_size = 64,
        .stack_pad_unit = 0,
    });
    _ = try runtime.enterFunction(function, &.{});
    runtime.rerandomize();
    try std.testing.expectEqual(@as(u8, 0xaa), runtime.stack.entries[0]);
    try std.testing.expect(runtime.code.rerandomizing);
    try std.testing.expectEqual(FunctionEntryState.trap, runtime.code.entryState(function).?);
}

test "code randomizer patches stack pad table slots on first image relocation" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    var table = @as([(@sizeOf(usize) * 2)]u8, @splat(0));
    const function = try code.registerFunctionImage(.{
        .code = &.{ 0xaa, 0xbb, 0xcc },
        .table = &table,
        .table_adjacent = true,
        .stack_pad_unit = 0,
        .stack_pad_table_offsets = &.{@sizeOf(usize)},
    });
    try std.testing.expect(code.stackPadAddress(function) == null);

    const first = try code.relocate(function);
    const address = code.stackPadAddress(function).?;
    try std.testing.expectEqual(
        address,
        std.mem.readInt(usize, first.contents[3 + @sizeOf(usize) ..][0..@sizeOf(usize)], .little),
    );

    const second = try code.relocate(function);
    try std.testing.expectEqual(address, code.stackPadAddress(function).?);
    try std.testing.expectEqual(
        address,
        std.mem.readInt(usize, second.contents[3 + @sizeOf(usize) ..][0..@sizeOf(usize)], .little),
    );
}

test "code randomizer rejects invalid stack pad table slots" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    var table = @as([@sizeOf(usize)]u8, @splat(0));
    try std.testing.expectError(
        error.InvalidStackPadTableOffset,
        code.registerFunctionImage(.{
            .code = &.{0xaa},
            .table = &table,
            .stack_pad_unit = 0,
            .stack_pad_table_offsets = &.{1},
        }),
    );
    try std.testing.expectError(
        error.InvalidStackPadTableOffset,
        code.registerFunctionImage(.{
            .code = &.{0xaa},
            .table = table[0 .. table.len - 1],
            .stack_pad_unit = 0,
            .stack_pad_table_offsets = &.{0},
        }),
    );
}

const StackProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        const entries = try drawUsize(data, 1, 32, 8);
        const configured_alignment = try drawUsize(data, 1, 64, stack_alignment);
        var rng = Marsaglia.init(try data.drawInteger(1, std.math.maxInt(u32), 1));
        var pads = try StackPads.init(allocator, .{
            .entries = entries,
            .alignment = configured_alignment,
        }, &rng);
        defer pads.deinit();

        var index: usize = 0;
        while (index < entries * 4) : (index += 1) {
            const pad = pads.next(&rng);
            try std.testing.expectEqual(@as(usize, pad.unit) * stack_alignment, pad.bytes);
        }
    }
};

test "pbt: stack pads multiply byte draws by alignment" {
    try hypothesis.checkNamed(StackProperty, "stabilizer-stack", settings());
}
