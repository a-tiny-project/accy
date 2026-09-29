const std = @import("std");
const alloc_phase = @import("alloc_phase");
const model = @import("model.zig");

pub const storage_alignment: usize = @max(@alignOf(model.Slot), @alignOf(model.Entry));

pub const Limits = struct {
    categories: usize,
    label_bytes: usize,
    joined_label_bytes: usize,
};

pub const DeriveError = error{
    CapacityOverflow,
    CategoryCapacityTooSmall,
    LabelStorageTooSmall,
};

pub const Capacity = struct {
    categories: usize,
    table_slots: usize,
    table_bytes: usize,
    table_offset: usize,
    summary_entries: usize,
    summary_bytes: usize,
    summary_offset: usize,
    label_bytes: usize,
    label_offset: usize,
    joined_label_bytes: usize,
    joined_label_offset: usize,
    storage_bytes: usize,

    pub fn derive(limits: Limits) DeriveError!Capacity {
        if (limits.categories == 0) return error.CategoryCapacityTooSmall;
        if (limits.label_bytes == 0) return error.LabelStorageTooSmall;

        const doubled_categories = try multiplied(limits.categories, 2);
        const table_slots = std.math.ceilPowerOfTwo(usize, doubled_categories) catch
            return error.CapacityOverflow;
        const table = try placed(model.Slot, 0, table_slots);
        const summary = try placed(model.Entry, table.end, limits.categories);
        const label_offset = summary.end;
        const joined_label_offset = try added(label_offset, limits.label_bytes);
        const storage_bytes = try added(joined_label_offset, limits.joined_label_bytes);

        return .{
            .categories = limits.categories,
            .table_slots = table_slots,
            .table_bytes = table.bytes,
            .table_offset = table.start,
            .summary_entries = limits.categories,
            .summary_bytes = summary.bytes,
            .summary_offset = summary.start,
            .label_bytes = limits.label_bytes,
            .label_offset = label_offset,
            .joined_label_bytes = limits.joined_label_bytes,
            .joined_label_offset = joined_label_offset,
            .storage_bytes = storage_bytes,
        };
    }
};

const Region = struct {
    start: usize,
    bytes: usize,
    end: usize,
};

fn added(left: usize, right: usize) DeriveError!usize {
    return std.math.add(usize, left, right) catch error.CapacityOverflow;
}

fn multiplied(left: usize, right: usize) DeriveError!usize {
    return std.math.mul(usize, left, right) catch error.CapacityOverflow;
}

fn aligned(offset: usize, alignment: usize) DeriveError!usize {
    const mask = alignment - 1;
    const padded = try added(offset, mask);
    return padded & ~mask;
}

fn placed(comptime T: type, offset: usize, count: usize) DeriveError!Region {
    const start = try aligned(offset, @alignOf(T));
    const bytes = try multiplied(count, @sizeOf(T));
    const end = try added(start, bytes);
    return .{ .start = start, .bytes = bytes, .end = end };
}

fn modelCapacity(limits: Limits) DeriveError!Capacity {
    if (limits.categories == 0) return error.CategoryCapacityTooSmall;
    if (limits.label_bytes == 0) return error.LabelStorageTooSmall;

    const doubled_categories = @as(u128, limits.categories) * 2;
    var table_slots: u128 = 1;
    while (table_slots < doubled_categories) table_slots *= 2;
    const table_offset = alignedModel(0, @alignOf(model.Slot));
    const table_bytes = table_slots * @sizeOf(model.Slot);
    const summary_offset = alignedModel(table_offset + table_bytes, @alignOf(model.Entry));
    const summary_bytes = @as(u128, limits.categories) * @sizeOf(model.Entry);
    const label_offset = summary_offset + summary_bytes;
    const joined_label_offset = label_offset + limits.label_bytes;
    const storage_bytes = joined_label_offset + limits.joined_label_bytes;

    const values = [_]u128{
        table_slots,
        table_offset,
        table_bytes,
        summary_offset,
        summary_bytes,
        label_offset,
        joined_label_offset,
        storage_bytes,
    };
    for (values) |value| {
        if (value > std.math.maxInt(usize)) return error.CapacityOverflow;
    }

    return .{
        .categories = limits.categories,
        .table_slots = @intCast(table_slots),
        .table_bytes = @intCast(table_bytes),
        .table_offset = @intCast(table_offset),
        .summary_entries = limits.categories,
        .summary_bytes = @intCast(summary_bytes),
        .summary_offset = @intCast(summary_offset),
        .label_bytes = limits.label_bytes,
        .label_offset = @intCast(label_offset),
        .joined_label_bytes = limits.joined_label_bytes,
        .joined_label_offset = @intCast(joined_label_offset),
        .storage_bytes = @intCast(storage_bytes),
    };
}

fn alignedModel(offset: u128, alignment: usize) u128 {
    const mask = @as(u128, alignment - 1);
    return (offset + mask) & ~mask;
}

test "Census capacity matches an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "memtrace_census_capacity"),
        );
    }

    const limits = Limits{
        .categories = 3,
        .label_bytes = 64,
        .joined_label_bytes = 31,
    };
    const capacity = try Capacity.derive(limits);
    const independent = try modelCapacity(limits);

    try std.testing.expectEqual(independent, capacity);
    try std.testing.expectEqual(@as(usize, 8), capacity.table_slots);
    try std.testing.expectEqual(capacity.storage_bytes, capacity.joined_label_offset + capacity.joined_label_bytes);
}

test "census capacity rejects unusable and overflowing limits" {
    try std.testing.expectError(error.CategoryCapacityTooSmall, Capacity.derive(.{
        .categories = 0,
        .label_bytes = 1,
        .joined_label_bytes = 0,
    }));
    try std.testing.expectError(error.LabelStorageTooSmall, Capacity.derive(.{
        .categories = 1,
        .label_bytes = 0,
        .joined_label_bytes = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .categories = std.math.maxInt(usize) / 2 + 1,
        .label_bytes = 1,
        .joined_label_bytes = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .categories = 1,
        .label_bytes = std.math.maxInt(usize),
        .joined_label_bytes = 1,
    }));
}
