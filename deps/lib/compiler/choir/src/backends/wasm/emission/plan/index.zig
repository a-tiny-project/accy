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
