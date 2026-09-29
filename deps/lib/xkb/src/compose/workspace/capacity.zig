const std = @import("std");
const alloc_phase = @import("alloc_phase");

pub const max_include_depth: usize = 5;
pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const max_registry_bytes: usize = 8 * 1024 * 1024;
pub const max_path_bytes: usize = 4096;
pub const file_line_slot_count: usize = max_include_depth + 1;
pub const registry_line_slot_index: usize = file_line_slot_count;
pub const line_slot_count: usize = file_line_slot_count + 1;
pub const file_path_slot_count: usize = max_include_depth + 1;
pub const auxiliary_path_slot_count: usize = 2;
pub const path_slot_count: usize = file_path_slot_count + auxiliary_path_slot_count;

pub const Limits = struct {
    line_bytes: usize,
    path_bytes: usize,
};

pub const default_limits = Limits{
    .line_bytes = 256,
    .path_bytes = max_path_bytes,
};

pub const DeriveError = error{
    LineByteLimitZero,
    LineByteLimitExceeded,
    PathByteLimitZero,
    PathByteLimitExceeded,
    CapacityOverflow,
};

pub const Capacity = struct {
    limits: Limits,
    line_bytes_per_slot: usize,
    line_slot_count: usize,
    line_offset: usize,
    line_storage_bytes: usize,
    path_slot_count: usize,
    path_offset: usize,
    path_storage_bytes: usize,
    storage_bytes: usize,

    pub fn derive(limits: Limits) DeriveError!Capacity {
        if (limits.line_bytes == 0) return error.LineByteLimitZero;
        if (limits.line_bytes > max_file_bytes) return error.LineByteLimitExceeded;
        if (limits.path_bytes == 0) return error.PathByteLimitZero;
        if (limits.path_bytes > max_path_bytes) return error.PathByteLimitExceeded;
        const line_bytes_per_slot = try added(limits.line_bytes, 1);
        const line_storage_bytes = try multiplied(line_slot_count, line_bytes_per_slot);
        const path_storage_bytes = try multiplied(path_slot_count, limits.path_bytes);
        return .{
            .limits = limits,
            .line_bytes_per_slot = line_bytes_per_slot,
            .line_slot_count = line_slot_count,
            .line_offset = 0,
            .line_storage_bytes = line_storage_bytes,
            .path_slot_count = path_slot_count,
            .path_offset = line_storage_bytes,
            .path_storage_bytes = path_storage_bytes,
            .storage_bytes = try added(line_storage_bytes, path_storage_bytes),
        };
    }
};

fn added(left: usize, right: usize) DeriveError!usize {
    return std.math.add(usize, left, right) catch error.CapacityOverflow;
}

fn multiplied(left: usize, right: usize) DeriveError!usize {
    return std.math.mul(usize, left, right) catch error.CapacityOverflow;
}

fn modelCapacity(limits: Limits) DeriveError!Capacity {
    if (limits.line_bytes == 0) return error.LineByteLimitZero;
    if (limits.line_bytes > max_file_bytes) return error.LineByteLimitExceeded;
    if (limits.path_bytes == 0) return error.PathByteLimitZero;
    if (limits.path_bytes > max_path_bytes) return error.PathByteLimitExceeded;
    const line_bytes_per_slot = @as(u128, limits.line_bytes) + 1;
    const line_storage_bytes = @as(u128, line_slot_count) * line_bytes_per_slot;
    const path_storage_bytes = @as(u128, path_slot_count) * limits.path_bytes;
    const storage_bytes = line_storage_bytes + path_storage_bytes;
    const values = [_]u128{ line_bytes_per_slot, line_storage_bytes, path_storage_bytes, storage_bytes };
    for (values) |value| {
        if (value > std.math.maxInt(usize)) return error.CapacityOverflow;
    }
    return .{
        .limits = limits,
        .line_bytes_per_slot = @intCast(line_bytes_per_slot),
        .line_slot_count = line_slot_count,
        .line_offset = 0,
        .line_storage_bytes = @intCast(line_storage_bytes),
        .path_slot_count = path_slot_count,
        .path_offset = @intCast(line_storage_bytes),
        .path_storage_bytes = @intCast(path_storage_bytes),
        .storage_bytes = @intCast(storage_bytes),
    };
}

test "Compose scratch capacity matches an independent slot model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("./root.zig").Storage,
                "xkb_compose_scratch_capacity",
            ),
        );
    }

    const capacity = try Capacity.derive(default_limits);
    try std.testing.expectEqual(try modelCapacity(default_limits), capacity);
    try std.testing.expectEqual(@as(usize, 34_567), capacity.storage_bytes);
    try std.testing.expectEqual(@as(usize, 7), capacity.line_slot_count);
    try std.testing.expectEqual(@as(usize, 8), capacity.path_slot_count);
}

test "Compose scratch capacity rejects invalid semantic limits" {
    try std.testing.expectError(
        error.LineByteLimitZero,
        Capacity.derive(.{ .line_bytes = 0, .path_bytes = 1 }),
    );
    try std.testing.expectError(
        error.LineByteLimitExceeded,
        Capacity.derive(.{ .line_bytes = max_file_bytes + 1, .path_bytes = 1 }),
    );
    try std.testing.expectError(
        error.PathByteLimitZero,
        Capacity.derive(.{ .line_bytes = 1, .path_bytes = 0 }),
    );
    try std.testing.expectError(
        error.PathByteLimitExceeded,
        Capacity.derive(.{ .line_bytes = 1, .path_bytes = max_path_bytes + 1 }),
    );
}
