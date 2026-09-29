const std = @import("std");

pub fn IndexedDeltaTotals(comptime count: usize) type {
    return struct {
        before_total: [count]u128 = @as([count]u128, @splat(0)),
        after_total: [count]u128 = @as([count]u128, @splat(0)),
        delta_total: [count]i128 = @as([count]i128, @splat(0)),

        pub fn record(
            self: *@This(),
            index: usize,
            before: u64,
            after: u64,
            delta: i128,
        ) void {
            std.debug.assert(index < count);
            self.before_total[index] += before;
            self.after_total[index] += after;
            self.delta_total[index] += delta;
        }

        pub fn meanBefore(self: *const @This(), index: usize, sample_count: u32) f64 {
            std.debug.assert(index < count);
            return meanU128(self.before_total[index], sample_count);
        }

        pub fn meanAfter(self: *const @This(), index: usize, sample_count: u32) f64 {
            std.debug.assert(index < count);
            return meanU128(self.after_total[index], sample_count);
        }

        pub fn meanDelta(self: *const @This(), index: usize, sample_count: u32) f64 {
            std.debug.assert(index < count);
            return meanI128(self.delta_total[index], sample_count);
        }
    };
}

pub fn IndexedMemoryTotals(comptime count: usize) type {
    return struct {
        alloc_count_total: [count]u128 = @as([count]u128, @splat(0)),
        free_count_total: [count]u128 = @as([count]u128, @splat(0)),
        alloc_bytes_total: [count]u128 = @as([count]u128, @splat(0)),

        pub fn record(
            self: *@This(),
            index: usize,
            alloc_count: u64,
            free_count: u64,
            alloc_bytes: u64,
        ) void {
            std.debug.assert(index < count);
            self.alloc_count_total[index] += alloc_count;
            self.free_count_total[index] += free_count;
            self.alloc_bytes_total[index] += alloc_bytes;
        }

        pub fn meanAllocCount(self: *const @This(), index: usize, sample_count: u32) f64 {
            std.debug.assert(index < count);
            return meanU128(self.alloc_count_total[index], sample_count);
        }

        pub fn meanFreeCount(self: *const @This(), index: usize, sample_count: u32) f64 {
            std.debug.assert(index < count);
            return meanU128(self.free_count_total[index], sample_count);
        }

        pub fn meanAllocBytes(self: *const @This(), index: usize, sample_count: u32) f64 {
            std.debug.assert(index < count);
            return meanU128(self.alloc_bytes_total[index], sample_count);
        }
    };
}

pub fn nsPerUnit(ns: f64, units: u64) f64 {
    return valuePerUnit(ns, units);
}

pub fn valuePerUnit(value: f64, units: u64) f64 {
    if (units == 0) return 0;
    return value / @as(f64, @floatFromInt(units));
}

pub fn nsPerFloatUnit(ns: f64, units: f64) f64 {
    return valuePerFloatUnit(ns, units);
}

pub fn valuePerFloatUnit(value: f64, units: f64) f64 {
    if (units == 0) return 0;
    return value / units;
}

fn meanU128(total: u128, sample_count: u32) f64 {
    if (sample_count == 0) return 0;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(sample_count));
}

fn meanI128(total: i128, sample_count: u32) f64 {
    if (sample_count == 0) return 0;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(sample_count));
}
