const std = @import("std");
const size_class = @import("../root.zig").class;

pub const capacity: u16 = 960;
pub const extra_bin_capacity: u16 = 1088;
pub const target_bytes: usize = 64 * 1024;
pub const refill_max: usize = 256;
pub const tight_class_size: usize = 80;
pub const tight_class_capacity: u16 = 512;
pub const preload_class_size: usize = 96;
pub const preload_class_refill_max: usize = 512;
pub const extra_class_sizes = [_]usize{ 32, 48 };
pub const extra_class_capacities = [_]u16{ 1088, 405 };
pub const extra_class_count: usize = extra_class_sizes.len;
pub const extra_class_refill_max: usize = 512;
pub const fixed_class_count: usize = 20;

const class_limits = buildClassLimits();
const extra_class_indices = buildExtraClassIndices();

pub fn classLimit(class_index: usize) u16 {
    return class_limits[class_index];
}

fn buildClassLimits() [size_class.count]u16 {
    var limits: [size_class.count]u16 = undefined;
    for (&limits, 0..) |*limit, class_index| {
        const class_size = size_class.size(class_index);
        const by_bytes = @max(@as(usize, 1), target_bytes / class_size);
        const by_slots = slotCapacity(class_index);
        limit.* = @intCast(@min(by_slots, by_bytes));
    }
    return limits;
}

fn slotCapacity(class_index: usize) usize {
    const class_size = size_class.size(class_index);
    if (class_size == tight_class_size) return tight_class_capacity;
    return @as(usize, capacity) + extraCapacity(class_index);
}

pub fn extraCapacity(class_index: usize) u16 {
    return if (extraClassIndex(class_index)) |extra_index| extra_class_capacities[extra_index] else 0;
}

pub fn extraClassIndex(class_index: usize) ?usize {
    inline for (extra_class_indices, 0..) |extra_class_index, extra_index| {
        if (class_index == extra_class_index) return extra_index;
    }
    return null;
}

pub fn refillCount(class_index: usize) usize {
    const cache_limit = classLimit(class_index);
    if (extraClassIndex(class_index) != null) return @min(extra_class_refill_max, cache_limit);
    if (size_class.size(class_index) == preload_class_size) return @min(preload_class_refill_max, cache_limit);
    return @min(refill_max, cache_limit);
}

pub fn drainCount(cache_limit: u16) usize {
    return @max(@as(usize, 1), @as(usize, cache_limit) / 2);
}

fn buildExtraClassIndices() [extra_class_count]usize {
    var indices: [extra_class_count]usize = undefined;
    for (extra_class_sizes, 0..) |extra_class_size, extra_index| {
        for (size_class.sizes, 0..) |class_size, class_index| {
            if (class_size == extra_class_size) {
                indices[extra_index] = class_index;
                break;
            }
        } else {
            @compileError("missing thread extra size class");
        }
    }
    return indices;
}
