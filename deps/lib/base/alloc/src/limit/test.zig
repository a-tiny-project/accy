const std = @import("std");
const limit = @import("alloc_limit");

const LimitAllocator = limit.LimitAllocator;

const BlockingAllocator = struct {
    backing: std.mem.Allocator,
    armed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    blocked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fail: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn init(backing: std.mem.Allocator) BlockingAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *BlockingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn arm(self: *BlockingAllocator, fail: bool) void {
        std.debug.assert(!self.armed.load(.acquire));
        self.blocked.store(false, .release);
        self.released.store(false, .release);
        self.fail.store(fail, .release);
        self.armed.store(true, .release);
    }

    fn release(self: *BlockingAllocator) void {
        self.released.store(true, .release);
    }

    fn waitUntilBlocked(self: *const BlockingAllocator) !void {
        for (0..1_000_000) |_| {
            if (self.blocked.load(.acquire)) return;
            std.Thread.yield() catch {};
        }
        return error.BackingAllocatorDidNotBlock;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn rawAlloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BlockingAllocator = @ptrCast(@alignCast(context));
        if (self.armed.cmpxchgStrong(
            true,
            false,
            .acq_rel,
            .acquire,
        ) == null) {
            self.blocked.store(true, .release);
            while (!self.released.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            if (self.fail.load(.acquire)) return null;
        }
        return self.backing.rawAlloc(length, alignment, return_address);
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) bool {
        const self: *BlockingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(
            memory,
            alignment,
            new_length,
            return_address,
        );
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BlockingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(
            memory,
            alignment,
            new_length,
            return_address,
        );
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *BlockingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

const AllocationWorker = struct {
    allocator: *LimitAllocator,
    bytes: usize,
    memory: ?[]u8 = null,
    failure: ?LimitAllocator.ClassifiedError = null,

    fn run(self: *AllocationWorker) void {
        self.memory = self.allocator.allocClassified(u8, self.bytes) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "limit allocator rejects growth beyond exact live byte capacity" {
    const testing = std.testing;
    var limited = LimitAllocator.init(testing.allocator, 16);
    defer limited.deinit();
    const allocator = limited.allocator();

    const first = try allocator.alloc(u8, 10);
    defer allocator.free(first);
    const second = try allocator.alloc(u8, 6);
    try testing.expectEqual(@as(usize, 16), limited.liveBytes());
    try testing.expectEqual(@as(usize, 16), limited.peakLiveBytes());
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try testing.expectEqual(@as(u64, 1), limited.deniedAllocations());
    const full = limited.snapshot();
    try testing.expectEqual(@as(usize, 16), full.capacity_bytes);
    try testing.expectEqual(@as(usize, 16), full.live_bytes);
    try testing.expectEqual(@as(usize, 0), full.reserved_bytes);
    try testing.expectEqual(@as(usize, 16), full.peak_live_bytes);
    try testing.expectEqual(@as(u64, 1), full.denied_allocations);
    allocator.free(second);
    try testing.expectEqual(@as(usize, 10), limited.liveBytes());
    try testing.expectEqual(@as(usize, 16), limited.peakLiveBytes());
}

test "limit allocator snapshot observes reserved commit and cancellation" {
    const testing = std.testing;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var backing = BlockingAllocator.init(testing.allocator);
    var limited = LimitAllocator.init(backing.allocator(), 16);
    defer limited.deinit();
    const allocator = limited.allocator();
    const seed = try allocator.alloc(u8, 4);
    defer allocator.free(seed);

    backing.arm(false);
    var admitted = AllocationWorker{ .allocator = &limited, .bytes = 6 };
    const admitted_thread = try std.Thread.spawn(.{}, AllocationWorker.run, .{&admitted});
    var admitted_joined = false;
    defer if (!admitted_joined) {
        backing.release();
        admitted_thread.join();
    };
    try backing.waitUntilBlocked();
    const reserved_admitted = limited.snapshot();
    backing.release();
    admitted_thread.join();
    admitted_joined = true;

    try testing.expectEqual(@as(usize, 16), reserved_admitted.capacity_bytes);
    try testing.expectEqual(@as(usize, 4), reserved_admitted.live_bytes);
    try testing.expectEqual(@as(usize, 6), reserved_admitted.reserved_bytes);
    try testing.expectEqual(@as(usize, 4), reserved_admitted.peak_live_bytes);
    try testing.expectEqual(@as(u64, 0), reserved_admitted.denied_allocations);
    try testing.expect(admitted.failure == null);
    const admitted_memory = admitted.memory orelse return error.ExpectedAllocation;
    const committed = limited.snapshot();
    try testing.expectEqual(@as(usize, 10), committed.live_bytes);
    try testing.expectEqual(@as(usize, 0), committed.reserved_bytes);
    try testing.expectEqual(@as(usize, 10), committed.peak_live_bytes);
    allocator.free(admitted_memory);

    backing.arm(true);
    var cancelled = AllocationWorker{ .allocator = &limited, .bytes = 5 };
    const cancelled_thread = try std.Thread.spawn(.{}, AllocationWorker.run, .{&cancelled});
    var cancelled_joined = false;
    defer if (!cancelled_joined) {
        backing.release();
        cancelled_thread.join();
    };
    try backing.waitUntilBlocked();
    const reserved_cancelled = limited.snapshot();
    backing.release();
    cancelled_thread.join();
    cancelled_joined = true;

    try testing.expectEqual(@as(usize, 4), reserved_cancelled.live_bytes);
    try testing.expectEqual(@as(usize, 5), reserved_cancelled.reserved_bytes);
    try testing.expectEqual(@as(usize, 10), reserved_cancelled.peak_live_bytes);
    try testing.expectEqual(@as(u64, 0), reserved_cancelled.denied_allocations);
    try testing.expect(cancelled.memory == null);
    try testing.expectEqual(error.OutOfMemory, cancelled.failure.?);
    const after_cancel = limited.snapshot();
    try testing.expectEqual(@as(usize, 4), after_cancel.live_bytes);
    try testing.expectEqual(@as(usize, 0), after_cancel.reserved_bytes);
    try testing.expectEqual(@as(usize, 10), after_cancel.peak_live_bytes);
    try testing.expectEqual(@as(u64, 0), after_cancel.denied_allocations);
}

test "limit allocator accounts successful resize and remap ownership" {
    const testing = std.testing;
    var backing_memory: [32]u8 = undefined;
    var backing = std.heap.FixedBufferAllocator.init(&backing_memory);
    var limited = LimitAllocator.init(backing.allocator(), 16);
    defer limited.deinit();
    const allocator = limited.allocator();

    var memory = try allocator.alloc(u8, 8);
    try testing.expect(allocator.resize(memory, 12));
    memory = memory.ptr[0..12];
    try testing.expectEqual(@as(usize, 12), limited.liveBytes());
    memory = allocator.remap(memory, 16) orelse return error.ExpectedRemap;
    try testing.expectEqual(@as(usize, 16), limited.liveBytes());
    try testing.expect(allocator.remap(memory, 17) == null);
    try testing.expectEqual(@as(usize, 16), limited.liveBytes());
    memory = allocator.remap(memory, 4) orelse return error.ExpectedRemap;
    try testing.expectEqual(@as(usize, 4), limited.liveBytes());
    allocator.free(memory);
}

test "limit allocator classifies owner capacity and backing exhaustion" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    var limited = LimitAllocator.init(failing.allocator(), 16);
    defer limited.deinit();

    try testing.expectError(
        error.OutOfMemory,
        limited.alignedAllocClassified(u8, .@"8", 8),
    );
    try testing.expectEqual(@as(usize, 0), limited.liveBytes());
    try testing.expectEqual(@as(usize, 0), limited.peakLiveBytes());
    try testing.expectEqual(@as(u64, 0), limited.deniedAllocations());

    failing.fail_index = std.math.maxInt(usize);
    const admitted = try limited.alignedAllocClassified(u8, .@"8", 16);
    defer limited.allocator().free(admitted);
    try testing.expectEqual(@as(usize, 16), limited.liveBytes());
    try testing.expectError(
        error.AllocationLimitExceeded,
        limited.allocClassified(u8, 1),
    );
    try testing.expectEqual(@as(u64, 1), limited.deniedAllocations());
}

test "limit allocator request classification is isolated" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var limited = LimitAllocator.init(failing.allocator(), 8);
    defer limited.deinit();
    var first = LimitAllocator.Request.init(&limited);
    var second = LimitAllocator.Request.init(&limited);

    const admitted = try first.allocator().alloc(u8, 8);
    try testing.expectError(
        error.OutOfMemory,
        second.allocator().alloc(u8, 1),
    );
    try testing.expectEqual(
        error.AllocationLimitExceeded,
        second.classify(error.OutOfMemory),
    );
    first.allocator().free(admitted);

    failing.fail_index = failing.alloc_index;
    first.reset();
    try testing.expectError(
        error.OutOfMemory,
        first.allocator().alloc(u8, 1),
    );
    try testing.expectEqual(
        error.OutOfMemory,
        first.classify(error.OutOfMemory),
    );
    try testing.expectEqual(
        error.AllocationLimitExceeded,
        second.classify(error.OutOfMemory),
    );
}
