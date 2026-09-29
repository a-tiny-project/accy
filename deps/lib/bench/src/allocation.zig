const std = @import("std");

const timing = @import("timing.zig");

const Allocator = std.mem.Allocator;

/// Records the allocation traffic and the outstanding-byte high water of one
/// counted allocator. A counted allocator holds one of these and updates it on
/// every request that passes through it.
pub const Counts = struct {
    /// Counts the allocation requests the backing allocator satisfied.
    alloc_count: u64 = 0,
    /// Counts the free requests.
    free_count: u64 = 0,
    /// Counts the bytes handed out by allocations and by resizes that grew.
    alloc_bytes: u64 = 0,
    /// Bytes handed out and not yet freed. The total carries across a reset.
    live_bytes: u64 = 0,
    /// The largest live-byte total reached since the counted allocator started
    /// or since its last reset.
    peak_live_bytes: u64 = 0,
};

pub const CountingAllocator = struct {
    backing: Allocator,
    counts: Counts = .{},
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(backing: Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Zeroes the traffic counters and sets the high water back to the live
    /// total. The live-byte total survives the reset, because memory handed out
    /// earlier is still outstanding. The high water restarts at the live total,
    /// so the next window reports the peak that window itself reached.
    pub fn reset(self: *CountingAllocator) void {
        self.lock();
        defer self.mutex.unlock();
        const live = self.counts.live_bytes;
        self.counts = .{ .live_bytes = live, .peak_live_bytes = live };
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.lock();
        defer self.mutex.unlock();
        self.counts.alloc_count +|= 1;
        self.counts.alloc_bytes +|= timing.saturatingU64(len);
        self.growLive(timing.saturatingU64(len));
        return ptr;
    }

    fn rawResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const resized = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (resized) self.recordLength(memory.len, new_len);
        return resized;
    }

    fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.recordLength(memory.len, new_len);
        return ptr;
    }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.lock();
        defer self.mutex.unlock();
        self.counts.free_count +|= 1;
        self.counts.live_bytes -|= timing.saturatingU64(memory.len);
    }

    fn recordLength(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const grew = timing.saturatingU64(new_len - old_len);
            self.lock();
            defer self.mutex.unlock();
            self.counts.alloc_bytes +|= grew;
            self.counts.live_bytes +|= grew;
            self.counts.peak_live_bytes = @max(
                self.counts.peak_live_bytes,
                self.counts.live_bytes,
            );
            return;
        }
        if (new_len == old_len) return;
        self.lock();
        defer self.mutex.unlock();
        self.counts.live_bytes -|= timing.saturatingU64(old_len - new_len);
    }

    fn growLive(self: *CountingAllocator, bytes: u64) void {
        self.counts.live_bytes +|= bytes;
        self.counts.peak_live_bytes = @max(
            self.counts.peak_live_bytes,
            self.counts.live_bytes,
        );
    }

    fn lock(self: *CountingAllocator) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

test "allocation counters retain concurrent updates" {
    const worker_count = 4;
    const allocations_per_worker = 256;
    const allocation_size = 64;
    const Worker = struct {
        fn run(allocator: Allocator) void {
            for (0..allocations_per_worker) |_| {
                const memory = allocator.alloc(u8, allocation_size) catch @panic("allocation failed");
                allocator.free(memory);
            }
        }
    };
    var counting = CountingAllocator.init(std.testing.allocator);
    const allocator = counting.allocator();
    var threads: [worker_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{allocator});
    }
    for (threads) |thread| thread.join();
    const expected = worker_count * allocations_per_worker;
    try std.testing.expectEqual(@as(u64, expected), counting.counts.alloc_count);
    try std.testing.expectEqual(@as(u64, expected), counting.counts.free_count);
    try std.testing.expectEqual(
        @as(u64, expected * allocation_size),
        counting.counts.alloc_bytes,
    );
    try std.testing.expectEqual(@as(u64, 0), counting.counts.live_bytes);
}

test "allocation counters report a window high water" {
    const block_bytes = 4096;
    var counting = CountingAllocator.init(std.testing.allocator);
    const allocator = counting.allocator();
    const retained = try allocator.alloc(u8, block_bytes);
    defer allocator.free(retained);
    counting.reset();
    try std.testing.expectEqual(@as(u64, block_bytes), counting.counts.live_bytes);
    try std.testing.expectEqual(@as(u64, block_bytes), counting.counts.peak_live_bytes);

    const transient = try allocator.alloc(u8, block_bytes * 3);
    allocator.free(transient);
    try std.testing.expectEqual(@as(u64, block_bytes), counting.counts.live_bytes);
    try std.testing.expectEqual(@as(u64, block_bytes * 4), counting.counts.peak_live_bytes);
    try std.testing.expectEqual(@as(u64, block_bytes * 3), counting.counts.alloc_bytes);
}
