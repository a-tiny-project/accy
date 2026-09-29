const std = @import("std");

const native_u64_atomics = @bitSizeOf(usize) >= 64;

const AtomicU32 = std.atomic.Value(u32);

pub const AtomicU64 = if (native_u64_atomics) std.atomic.Value(u64) else SplitAtomicU64;
pub const AtomicUsize = std.atomic.Value(usize);

const SplitAtomicU64 = struct {
    low: AtomicU32,
    high: AtomicU32,

    pub fn init(value: u64) SplitAtomicU64 {
        return .{
            .low = AtomicU32.init(@truncate(value)),
            .high = AtomicU32.init(@intCast(value >> 32)),
        };
    }

    pub fn load(counter: *const SplitAtomicU64, comptime order: std.builtin.AtomicOrder) u64 {
        const high = counter.high.load(order);
        const low = counter.low.load(order);
        return (@as(u64, high) << 32) | low;
    }

    pub fn store(counter: *SplitAtomicU64, value: u64, comptime order: std.builtin.AtomicOrder) void {
        counter.low.store(@truncate(value), order);
        counter.high.store(@intCast(value >> 32), order);
    }

    pub fn fetchAdd(counter: *SplitAtomicU64, amount: u64, comptime order: std.builtin.AtomicOrder) u64 {
        const low_amount: u32 = @truncate(amount);
        const high_amount: u32 = @intCast(amount >> 32);
        const previous_low = counter.low.fetchAdd(low_amount, order);
        const carry: u32 = if (@as(u64, previous_low) + low_amount > std.math.maxInt(u32)) 1 else 0;
        const high_delta = high_amount +% carry;
        const previous_high = if (high_delta == 0)
            counter.high.load(order)
        else
            counter.high.fetchAdd(high_delta, order);
        return (@as(u64, previous_high) << 32) | previous_low;
    }
};

pub const Stats = struct {
    small_allocations: u64 = 0,
    small_frees: u64 = 0,
    large_allocations: u64 = 0,
    large_frees: u64 = 0,
    pages_allocated: u64 = 0,
    pages_freed: u64 = 0,
    empty_page_discards: u64 = 0,
    retained_empty_pages: usize = 0,
    discarded_small_bytes: usize = 0,
    active_small_bytes: usize = 0,
    active_large_bytes: usize = 0,
    mapped_small_bytes: usize = 0,
};

pub const AtomicStats = struct {
    small_allocations: AtomicU64 = AtomicU64.init(0),
    small_frees: AtomicU64 = AtomicU64.init(0),
    large_allocations: AtomicU64 = AtomicU64.init(0),
    large_frees: AtomicU64 = AtomicU64.init(0),
    pages_allocated: AtomicU64 = AtomicU64.init(0),
    pages_freed: AtomicU64 = AtomicU64.init(0),
    empty_page_discards: AtomicU64 = AtomicU64.init(0),
    retained_empty_pages: AtomicUsize = AtomicUsize.init(0),
    discarded_small_bytes: AtomicUsize = AtomicUsize.init(0),
    active_small_bytes: AtomicUsize = AtomicUsize.init(0),
    active_large_bytes: AtomicUsize = AtomicUsize.init(0),
    mapped_small_bytes: AtomicUsize = AtomicUsize.init(0),

    pub fn snapshot(stats: *const AtomicStats) Stats {
        return .{
            .small_allocations = stats.small_allocations.load(.monotonic),
            .small_frees = stats.small_frees.load(.monotonic),
            .large_allocations = stats.large_allocations.load(.monotonic),
            .large_frees = stats.large_frees.load(.monotonic),
            .pages_allocated = stats.pages_allocated.load(.monotonic),
            .pages_freed = stats.pages_freed.load(.monotonic),
            .empty_page_discards = stats.empty_page_discards.load(.monotonic),
            .retained_empty_pages = stats.retained_empty_pages.load(.monotonic),
            .discarded_small_bytes = stats.discarded_small_bytes.load(.monotonic),
            .active_small_bytes = stats.active_small_bytes.load(.monotonic),
            .active_large_bytes = stats.active_large_bytes.load(.monotonic),
            .mapped_small_bytes = stats.mapped_small_bytes.load(.monotonic),
        };
    }

    pub fn reset(stats: *AtomicStats) void {
        stats.small_allocations.store(0, .monotonic);
        stats.small_frees.store(0, .monotonic);
        stats.large_allocations.store(0, .monotonic);
        stats.large_frees.store(0, .monotonic);
        stats.pages_allocated.store(0, .monotonic);
        stats.pages_freed.store(0, .monotonic);
        stats.empty_page_discards.store(0, .monotonic);
        stats.retained_empty_pages.store(0, .monotonic);
        stats.discarded_small_bytes.store(0, .monotonic);
        stats.active_small_bytes.store(0, .monotonic);
        stats.active_large_bytes.store(0, .monotonic);
        stats.mapped_small_bytes.store(0, .monotonic);
    }
};

pub fn addU64(counter: *AtomicU64, amount: u64) void {
    _ = counter.fetchAdd(amount, .monotonic);
}

pub fn addUsize(counter: *AtomicUsize, amount: usize) void {
    _ = counter.fetchAdd(amount, .monotonic);
}

pub fn subUsize(counter: *AtomicUsize, amount: usize) void {
    const previous = counter.fetchSub(amount, .monotonic);
    std.debug.assert(previous >= amount);
}

test "split u64 counter carries across low word" {
    var counter = SplitAtomicU64.init(std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), counter.load(.monotonic));
    _ = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)) + 1, counter.load(.monotonic));
    counter.store((@as(u64, 3) << 32) + 7, .monotonic);
    try std.testing.expectEqual((@as(u64, 3) << 32) + 7, counter.load(.monotonic));
}
