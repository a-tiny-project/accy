const std = @import("std");
const hypothesis = @import("hypothesis");
const stabilizer = @import("stabilizer");

const Allocator = std.mem.Allocator;

const ConstructorFn = stabilizer.ConstructorFn;
const FunctionEntryState = stabilizer.FunctionEntryState;
const FunctionId = stabilizer.FunctionId;
const Marsaglia = stabilizer.Marsaglia;
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

var constructor_trace: [64]u8 = undefined;
var constructor_trace_len: usize = 0;

fn resetConstructorTrace() void {
    @memset(&constructor_trace, 0);
    constructor_trace_len = 0;
}

fn appendConstructorTrace(value: u8) void {
    constructor_trace[constructor_trace_len] = value;
    constructor_trace_len += 1;
}

fn traceConstructor0() callconv(.c) void {
    appendConstructorTrace(0);
}

fn traceConstructor1() callconv(.c) void {
    appendConstructorTrace(1);
}

fn traceConstructor2() callconv(.c) void {
    appendConstructorTrace(2);
}

fn traceConstructor3() callconv(.c) void {
    appendConstructorTrace(3);
}

fn traceProgramMain() u8 {
    appendConstructorTrace(9);
    return 42;
}

const trace_constructors = [_]ConstructorFn{
    traceConstructor0,
    traceConstructor1,
    traceConstructor2,
    traceConstructor3,
};

const StackPadRegistryProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        const seed = try data.drawInteger(1, std.math.maxInt(u32), 1);
        const entries = try drawUsize(data, 1, 8, 1);
        const registered = try drawUsize(data, 0, 8, 2);

        var expected_rng = Marsaglia.init(seed);
        var index: usize = 0;
        while (index < entries) : (index += 1) _ = expected_rng.nextByte();

        var runtime = try Runtime.init(allocator, .{
            .seed = seed,
            .stack = .{ .entries = entries },
            .code = .{ .enabled = false },
        });
        defer runtime.deinit();

        var slots = @as([8]u8, @splat(0));
        index = 0;
        while (index < registered) : (index += 1) {
            try runtime.registerStackPad(&slots[index]);
            try runtime.registerStackPad(&slots[index]);
        }
        try std.testing.expectEqual(registered, runtime.registeredStackPadCount());

        var expected_entries: [8]u8 = undefined;
        index = 0;
        while (index < entries) : (index += 1) expected_entries[index] = expected_rng.nextByte();
        var expected_slots = @as([8]u8, @splat(0));
        index = 0;
        while (index < registered) : (index += 1) expected_slots[index] = expected_rng.nextByte();

        runtime.rerandomize();

        index = 0;
        while (index < entries) : (index += 1) {
            try std.testing.expectEqual(expected_entries[index], runtime.nextStackPad().unit);
        }
        index = 0;
        while (index < slots.len) : (index += 1) {
            try std.testing.expectEqual(expected_slots[index], slots[index]);
        }
    }
};

test "pbt: registered stack pad slots follow stack-only rerandomization" {
    try hypothesis.checkNamed(StackPadRegistryProperty, "stabilizer-stack-pad-registry", settings());
}

const ConstructorRegistryProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        resetConstructorTrace();

        var runtime = try Runtime.init(allocator, .{});
        defer runtime.deinit();

        const count = try drawUsize(data, 0, 32, 0);
        var expected: [32]u8 = undefined;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const slot = try drawUsize(data, 0, trace_constructors.len - 1, 0);
            expected[index] = @intCast(slot);
            try runtime.registerConstructor(trace_constructors[slot]);
        }
        try std.testing.expectEqual(count, runtime.constructorCount());

        runtime.runConstructors();

        try std.testing.expectEqual(count, constructor_trace_len);
        try std.testing.expectEqualSlices(u8, expected[0..count], constructor_trace[0..constructor_trace_len]);
    }
};

test "pbt: constructor registry preserves insertion order" {
    try hypothesis.checkNamed(ConstructorRegistryProperty, "stabilizer-constructors", settings());
}

const RuntimeLifecycleProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        resetConstructorTrace();

        var runtime = try Runtime.init(allocator, .{
            .code = .{ .enabled = true },
        });
        defer runtime.deinit();

        const functions = try drawUsize(data, 1, 8, 2);
        var ids: [8]FunctionId = undefined;
        var index: usize = 0;
        while (index < functions) : (index += 1) {
            ids[index] = try runtime.code.registerFunction(.{
                .code_size = try drawUsize(data, 1, 256, 64),
            });
            if (try data.drawBoolean()) _ = try runtime.enterFunction(ids[index], &.{});
        }

        const constructor_count = try drawUsize(data, 0, 16, 0);
        var expected: [17]u8 = undefined;
        index = 0;
        while (index < constructor_count) : (index += 1) {
            const slot = try drawUsize(data, 0, trace_constructors.len - 1, 0);
            expected[index] = @intCast(slot);
            try runtime.registerConstructor(trace_constructors[slot]);
        }
        expected[constructor_count] = 9;

        try std.testing.expectEqual(@as(u8, 42), runtime.runProgram(traceProgramMain, .{}));

        index = 0;
        while (index < functions) : (index += 1) {
            try std.testing.expectEqual(FunctionEntryState.trap, runtime.code.entryState(ids[index]).?);
        }
        try std.testing.expectEqual(@as(usize, 0), runtime.code.live.items.len);
        try std.testing.expect(!runtime.code.rerandomizing);
        try std.testing.expectEqualSlices(u8, expected[0 .. constructor_count + 1], constructor_trace[0..constructor_trace_len]);
    }
};

test "pbt: runtime lifecycle arms code before constructors and main" {
    try hypothesis.checkNamed(RuntimeLifecycleProperty, "stabilizer-runtime-lifecycle", settings());
}

const RuntimeRerandomizeProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        var runtime = try Runtime.init(allocator, .{
            .code = .{ .enabled = true },
        });
        defer runtime.deinit();

        const functions = try drawUsize(data, 1, 8, 2);
        var ids: [8]FunctionId = undefined;
        var index: usize = 0;
        while (index < functions) : (index += 1) {
            ids[index] = try runtime.code.registerFunction(.{
                .code_size = try drawUsize(data, 1, 256, 64),
            });
        }

        const active_index = try drawUsize(data, 0, functions - 1, 0);
        const active_base = (try runtime.enterFunction(ids[active_index], &.{})).?;
        const active_original = runtime.code.originalBase(ids[active_index]).?;
        try std.testing.expectEqual(active_base, runtime.rerandomizeAt(active_original));

        index = 0;
        while (index < functions) : (index += 1) {
            try std.testing.expectEqual(FunctionEntryState.trap, runtime.code.entryState(ids[index]).?);
        }
        try std.testing.expect(runtime.code.rerandomizing);
        try std.testing.expectEqual(@as(usize, 0), runtime.code.live.items.len);

        const non_entry = active_original + try drawUsize(data, 1, 128, 1);
        try std.testing.expectEqual(non_entry, runtime.rerandomizeAt(non_entry));
    }
};

test "pbt: runtime rerandomizeAt forwards only live function entries" {
    try hypothesis.checkNamed(RuntimeRerandomizeProperty, "stabilizer-runtime-rerandomize-at", settings());
}

const RuntimeAddressAdjustmentProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        var runtime = try Runtime.init(allocator, .{
            .code = .{ .shuffle_slots = 16 },
        });
        defer runtime.deinit();

        const function = try runtime.code.registerFunction(.{
            .code_size = try drawUsize(data, 1, 512, 64),
            .table_size = try drawUsize(data, 0, 128, 0),
            .table_adjacent = try data.drawBoolean(),
        });
        const original = runtime.code.originalBase(function).?;
        const allocation_size = runtime.code.allocationSize(function).?;
        const relocations = try drawUsize(data, 1, 6, 2);
        var bases: [6]usize = undefined;
        var index: usize = 0;
        while (index < relocations) : (index += 1) {
            const location = try runtime.code.relocate(function);
            bases[index] = location.base;
        }

        const offset = try drawUsize(data, 0, allocation_size - 1, 0);
        index = 0;
        while (index < relocations) : (index += 1) {
            try std.testing.expectEqual(original + offset, runtime.adjustAddress(bases[index] + offset));
        }

        const unrelated = bases[relocations - 1] + allocation_size + try drawUsize(data, 1, 4096, 1);
        try std.testing.expectEqual(unrelated, runtime.adjustAddress(unrelated));

        var real_backtrace: [7]usize = undefined;
        var expected_backtrace: [7]usize = undefined;
        index = 0;
        while (index < relocations) : (index += 1) {
            real_backtrace[index] = bases[index] + offset;
            expected_backtrace[index] = original + offset;
        }
        real_backtrace[relocations] = unrelated;
        expected_backtrace[relocations] = unrelated;

        var adjusted_backtrace: [7]usize = undefined;
        const adjusted = runtime.adjustBacktrace(adjusted_backtrace[0..], real_backtrace[0 .. relocations + 1]);
        try std.testing.expectEqual(relocations + 1, adjusted.len);
        try std.testing.expectEqualSlices(usize, expected_backtrace[0 .. relocations + 1], adjusted);
    }
};

test "pbt: runtime address adjustment preserves original code offsets" {
    try hypothesis.checkNamed(RuntimeAddressAdjustmentProperty, "stabilizer-runtime-address-adjustment", settings());
}
