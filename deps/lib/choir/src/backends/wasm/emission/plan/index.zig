const std = @import("std");
const ir = @import("../../../../core/root.zig");
const plan = @import("root.zig");

const empty = std.math.maxInt(u32);
const pointer_hash_multiplier: usize = switch (@bitSizeOf(usize)) {
    32 => 0x9e3779b9,
    64 => 0x9e3779b97f4a7c15,
    else => @compileError("unsupported pointer width"),
};

pub fn slotsFor(count: usize) error{CapacityOverflow}!usize {
    if (count == 0) return 0;
    const scaled = std.math.mul(usize, count, 4) catch return error.CapacityOverflow;
    const rounded = std.math.add(usize, scaled, 2) catch return error.CapacityOverflow;
    const minimum = rounded / 3;
    return std.math.ceilPowerOfTwo(usize, @max(@as(usize, 4), minimum)) catch
        error.CapacityOverflow;
}

pub fn storageIsValid(entry_count: usize, slots: []const u32) bool {
    const required = slotsFor(entry_count) catch return false;
    return slots.len == required;
}

pub fn clear(slots: []u32) void {
    @memset(slots, empty);
}

pub fn insertFunction(
    slots: []u32,
    functions: []const plan.FunctionPlan,
    ordinal: u32,
) error{ CodeGenFailed, InputChanged }!void {
    var slot = hashBytes(functions[ordinal].name) & (slots.len - 1);
    for (0..slots.len) |_| {
        const existing = slots[slot];
        if (existing == empty) {
            slots[slot] = ordinal;
            return;
        }
        if (std.mem.eql(u8, functions[existing].name, functions[ordinal].name)) {
            return error.CodeGenFailed;
        }
        slot = advance(slot, slots.len);
    }
    return error.InputChanged;
}

pub fn insertValue(
    slots: []u32,
    values: []const plan.ValuePlan,
    value_index: u32,
) error{ CodeGenFailed, InputChanged }!void {
    var slot = hashPointer(values[value_index].value) & (slots.len - 1);
    for (0..slots.len) |_| {
        const existing = slots[slot];
        if (existing == empty) {
            slots[slot] = value_index;
            return;
        }
        if (values[existing].value == values[value_index].value) {
            return error.CodeGenFailed;
        }
        slot = advance(slot, slots.len);
    }
    return error.InputChanged;
}

pub fn findFunction(
    slots: []const u32,
    functions: []const plan.FunctionPlan,
    name: []const u8,
) ?u32 {
    if (slots.len == 0) return null;
    var slot = hashBytes(name) & (slots.len - 1);
    for (0..slots.len) |_| {
        const ordinal = slots[slot];
        if (ordinal == empty) return null;
        const entry = functions[ordinal];
        if (std.mem.eql(u8, name, entry.name)) return entry.function_index;
        slot = advance(slot, slots.len);
    }
    return null;
}

pub fn findLocal(
    slots: []const u32,
    values: []const plan.ValuePlan,
    function_plan: plan.FunctionPlan,
    value: *ir.Value,
) ?u32 {
    if (slots.len == 0) return null;
    const start: usize = function_plan.value_start;
    const end = start + function_plan.value_count;
    var slot = hashPointer(value) & (slots.len - 1);
    for (0..slots.len) |_| {
        const value_index = slots[slot];
        if (value_index == empty) return null;
        const entry = values[value_index];
        if (entry.value == value) {
            if (value_index < start or value_index >= end) return null;
            return entry.local_index;
        }
        slot = advance(slot, slots.len);
    }
    return null;
}

fn advance(slot: usize, slot_count: usize) usize {
    return (slot + 1) & (slot_count - 1);
}

fn hashBytes(bytes: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0, bytes));
}

fn hashPointer(value: *const ir.Value) usize {
    return hashAddress(@intFromPtr(value));
}

fn hashAddress(address: usize) usize {
    return std.math.rotl(
        usize,
        address *% pointer_hash_multiplier,
        @bitSizeOf(usize) / 2,
    );
}

test "WASM plan index capacity preserves its load bound" {
    try std.testing.expectEqual(@as(usize, 0), try slotsFor(0));
    try std.testing.expectEqual(@as(usize, 4), try slotsFor(1));
    try std.testing.expectEqual(@as(usize, 4), try slotsFor(3));
    try std.testing.expectEqual(@as(usize, 8), try slotsFor(4));
}

test "WASM plan index storage requires the exact derived capacity" {
    var four: [4]u32 = undefined;
    var eight: [8]u32 = undefined;

    try std.testing.expect(storageIsValid(0, &.{}));
    try std.testing.expect(storageIsValid(1, &four));
    try std.testing.expect(storageIsValid(3, &four));
    try std.testing.expect(storageIsValid(4, &eight));
    try std.testing.expect(!storageIsValid(0, &four));
    try std.testing.expect(!storageIsValid(1, &eight));
    try std.testing.expect(!storageIsValid(4, &four));
    try std.testing.expect(!storageIsValid(std.math.maxInt(usize), &.{}));
}

test "WASM plan index capacity rejects overflow" {
    try std.testing.expectError(error.CapacityOverflow, slotsFor(std.math.maxInt(usize)));
}

test "WASM plan indices probe through function and value collisions" {
    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    var first_name_by_slot = @as([4]?usize, @splat(null));
    var name_pair: ?[2]usize = null;
    for (names, 0..) |name, name_index| {
        const slot = hashBytes(name) & 3;
        if (first_name_by_slot[slot]) |first_name| {
            name_pair = .{ first_name, name_index };
            break;
        }
        first_name_by_slot[slot] = name_index;
    }
    const colliding_names = name_pair.?;
    const functions = [_]plan.FunctionPlan{
        .{
            .name = names[colliding_names[0]],
            .value_start = 0,
            .value_count = 0,
            .param_count = 0,
            .local_count = 0,
            .function_index = 7,
            .body_bytes = 0,
        },
        .{
            .name = names[colliding_names[1]],
            .value_start = 0,
            .value_count = 0,
            .param_count = 0,
            .local_count = 0,
            .function_index = 11,
            .body_bytes = 0,
        },
    };
    var function_slots: [4]u32 = undefined;
    clear(&function_slots);
    try insertFunction(&function_slots, &functions, 0);
    try insertFunction(&function_slots, &functions, 1);
    try std.testing.expectEqual(@as(?u32, 7), findFunction(&function_slots, &functions, functions[0].name));
    try std.testing.expectEqual(@as(?u32, 11), findFunction(&function_slots, &functions, functions[1].name));

    var raw_values: [5]ir.Value = undefined;
    var first_value_by_slot = @as([4]?usize, @splat(null));
    var value_pair: ?[2]usize = null;
    for (&raw_values, 0..) |*value, value_index| {
        const slot = hashPointer(value) & 3;
        if (first_value_by_slot[slot]) |first_value| {
            value_pair = .{ first_value, value_index };
            break;
        }
        first_value_by_slot[slot] = value_index;
    }
    const colliding_values = value_pair.?;
    const values = [_]plan.ValuePlan{
        .{
            .value = &raw_values[colliding_values[0]],
            .local_index = 3,
            .value_type = .i32,
        },
        .{
            .value = &raw_values[colliding_values[1]],
            .local_index = 5,
            .value_type = .i32,
        },
    };
    var value_slots: [4]u32 = undefined;
    clear(&value_slots);
    try insertValue(&value_slots, &values, 0);
    try insertValue(&value_slots, &values, 1);
    const function_plan = plan.FunctionPlan{
        .name = "values",
        .value_start = 0,
        .value_count = 2,
        .param_count = 0,
        .local_count = 2,
        .function_index = 0,
        .body_bytes = 0,
    };
    try std.testing.expectEqual(
        @as(?u32, 3),
        findLocal(&value_slots, &values, function_plan, values[0].value),
    );
    try std.testing.expectEqual(
        @as(?u32, 5),
        findLocal(&value_slots, &values, function_plan, values[1].value),
    );
}

test "WASM value pointer hash disperses aligned addresses" {
    const slot_count = 512;
    var values: [256]ir.Value = undefined;
    var value_loads = @as([slot_count]u8, @splat(0));
    for (&values) |*value| {
        value_loads[hashPointer(value) & (slot_count - 1)] += 1;
    }
    for (value_loads) |load| try std.testing.expect(load <= 2);

    for ([_]usize{ 8, 16, 32, 64, 128 }) |stride| {
        var loads = @as([slot_count]u8, @splat(0));
        for (0..256) |index| {
            const address = 0x1000 + index * stride;
            loads[hashAddress(address) & (slot_count - 1)] += 1;
        }
        for (loads) |load| try std.testing.expect(load <= 2);
    }
}
