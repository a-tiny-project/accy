const std = @import("std");
const observe = @import("alloc_observe");
const fixed = @import("root.zig");

const Recorder = struct {
    events: [32]observe.Event = undefined,
    count: usize = 0,

    fn sink(self: *Recorder) observe.Sink {
        return .{ .context = self, .record = record };
    }

    fn record(context: *anyopaque, event: observe.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        std.debug.assert(self.count < self.events.len);
        self.events[self.count] = event;
        self.count += 1;
    }
};

test "owned fixed buffer preserves standard behavior" {
    var storage: [512]u8 align(64) = undefined;
    var owner = fixed.FixedBuffer.init(&storage);
    const allocator = owner.allocator();
    const first = try allocator.alloc(u8, 37);
    const second = try allocator.alignedAlloc(u32, .@"16", 11);
    @memset(first, 0x51);
    @memset(second, 0x52525252);
    try std.testing.expect(fixed.used(&owner) >= first.len + @sizeOf(u32) * second.len);
    allocator.free(second);
    allocator.free(first);
    owner.reset();
    try std.testing.expectEqual(@as(usize, 0), fixed.used(&owner));
}

test "tracked fixed storage reports exact capacity and exhaustion" {
    var bytes: [64]u8 align(16) = undefined;
    var tracked = fixed.Tracked.init(&bytes);
    const allocator = tracked.allocator();
    const memory = try allocator.alloc(u8, bytes.len);

    try std.testing.expectEqual(bytes.len, tracked.status().used_bytes);
    try std.testing.expectEqual(bytes.len, tracked.status().peak_bytes);
    try std.testing.expectEqual(bytes.len, tracked.status().high_water_bytes);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(tracked.status().exhausted);

    allocator.free(memory);
    tracked.reset();
    try std.testing.expectEqual(@as(usize, 0), tracked.status().used_bytes);
    try std.testing.expectEqual(@as(usize, 0), tracked.status().peak_bytes);
    try std.testing.expectEqual(bytes.len, tracked.status().high_water_bytes);
    try std.testing.expect(!tracked.status().exhausted);
    _ = try tracked.allocator().alloc(u8, bytes.len);
}

test "chunked fixed buffer retains committed storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counting = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var owner = fixed.Chunks.init(counting.allocator(), 64, 256);
    const allocator = owner.allocator();
    const first = try allocator.alloc(u8, 37);
    const second = try allocator.alloc(u8, 41);
    @memset(first, 0x51);
    @memset(second, 0x52);
    try std.testing.expectEqual(@as(usize, 2), counting.alloc_index);
    owner.retain();
    for (first) |byte| try std.testing.expectEqual(@as(u8, 0x51), byte);
    for (second) |byte| try std.testing.expectEqual(@as(u8, 0x52), byte);
}

test "chunked fixed buffer discards uncommitted storage" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var owner = fixed.Chunks.init(counting.allocator(), 64, 256);
    _ = try owner.allocator().alloc(u8, 37);
    _ = try owner.allocator().alloc(u8, 41);
    owner.discard();
    try std.testing.expectEqual(@as(usize, 2), counting.alloc_index);
}

test "chunked fixed buffer caps scheduled growth" {
    var backing_storage: [496]u8 align(16) = undefined;
    var backing = fixed.FixedBuffer.init(&backing_storage);
    var counting = std.testing.FailingAllocator.init(backing.allocator(), .{});
    var owner = fixed.Chunks.init(counting.allocator(), 64, 128);
    const allocator = owner.allocator();
    for (0..4) |_| _ = try allocator.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 4), counting.alloc_index);
    try std.testing.expectEqual(backing_storage.len, fixed.used(&backing));
}

test "chunked fixed buffer bounds rollback metadata" {
    var owner = fixed.Chunks.init(std.testing.allocator, 16, 16);
    defer owner.discard();
    const allocator = owner.allocator();
    for (0..fixed.Chunks.maximum_chunk_count) |_| {
        _ = try allocator.alloc(u8, 16);
    }
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 16));
}

test "recycling chunks stay distinct from retained output chunks" {
    var retained = fixed.Chunks.init(std.testing.allocator, 64, 256);
    defer retained.discard();
    var recycling = fixed.Recycling.init(std.testing.allocator, 64, 256);
    defer recycling.discard();

    try std.testing.expect(fixed.Chunks.isAllocator(retained.allocator()));
    try std.testing.expect(!fixed.Chunks.isAllocator(recycling.allocator()));
}

test "recycling chunks rewind retained storage without backing growth" {
    var storage_bytes: [448]u8 align(16) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var owner = fixed.Recycling.init(storage_owner.allocator(), 64, 256);
    defer owner.discard();
    const allocator = owner.allocator();

    const small = try allocator.alloc(u8, 48);
    const large = try allocator.alloc(u8, 96);
    @memset(small, 0x51);
    @memset(large, 0x52);
    try std.testing.expectEqual(@as(usize, 192), storage_owner.status().used_bytes);

    owner.reset();
    const reused_large = try allocator.alloc(u8, large.len);
    const reused_small = try allocator.alloc(u8, small.len);
    try std.testing.expectEqual(@intFromPtr(large.ptr), @intFromPtr(reused_large.ptr));
    try std.testing.expectEqual(@intFromPtr(small.ptr), @intFromPtr(reused_small.ptr));
    _ = try allocator.alloc(u8, 129);
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().used_bytes);
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().high_water_bytes);
}

test "recycling chunks preserve a live sibling while alternating" {
    var storage_bytes: [192]u8 align(16) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var owners = [2]fixed.Recycling{
        fixed.Recycling.init(storage_owner.allocator(), 96, 256),
        fixed.Recycling.init(storage_owner.allocator(), 96, 256),
    };
    defer owners[1].discard();
    defer owners[0].discard();

    const first = try owners[0].allocator().alloc(u8, 96);
    @memset(first, 0x51);
    const second = try owners[1].allocator().alloc(u8, 96);
    @memset(second, 0x52);
    const warmed_high_water = storage_owner.status().high_water_bytes;

    owners[0].reset();
    const reused_first = try owners[0].allocator().alloc(u8, 96);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused_first.ptr));
    for (second) |byte| try std.testing.expectEqual(@as(u8, 0x52), byte);
    @memset(reused_first, 0x53);
    try std.testing.expectEqual(warmed_high_water, storage_owner.status().high_water_bytes);

    owners[1].reset();
    const reused_second = try owners[1].allocator().alloc(u8, 96);
    try std.testing.expectEqual(@intFromPtr(second.ptr), @intFromPtr(reused_second.ptr));
    for (reused_first) |byte| try std.testing.expectEqual(@as(u8, 0x53), byte);
    try std.testing.expectEqual(warmed_high_water, storage_owner.status().high_water_bytes);
}

test "recycling chunks retain aligned storage after first acquisition" {
    var storage_bytes: [256]u8 align(128) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var owner = fixed.Recycling.init(storage_owner.allocator(), 64, 256);
    defer owner.discard();
    const allocator = owner.allocator();

    _ = try allocator.alloc(u8, 64);
    owner.reset();
    const alignment = comptime std.mem.Alignment.fromByteUnits(128);
    const aligned = try allocator.alignedAlloc(u8, alignment, 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 128);
    const warmed_high_water = storage_owner.status().high_water_bytes;

    owner.reset();
    const reused = try allocator.alignedAlloc(u8, alignment, 64);
    try std.testing.expectEqual(@intFromPtr(aligned.ptr), @intFromPtr(reused.ptr));
    try std.testing.expectEqual(warmed_high_water, storage_owner.status().high_water_bytes);
}

test "recycling chunks leave maximum plus one to the backing owner" {
    var storage_bytes: [128]u8 align(16) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var owner = fixed.Recycling.init(storage_owner.allocator(), 128, 128);
    const allocator = owner.allocator();

    _ = try allocator.alloc(u8, storage_bytes.len);
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().high_water_bytes);
    owner.reset();
    try std.testing.expectError(
        error.OutOfMemory,
        allocator.alloc(u8, storage_bytes.len + 1),
    );
    try std.testing.expect(storage_owner.status().exhausted);
    try std.testing.expect(!owner.metadataExhausted());
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().high_water_bytes);

    owner.discard();
    storage_owner.reset();
    var retry = fixed.Recycling.init(storage_owner.allocator(), 128, 128);
    defer retry.discard();
    _ = try retry.allocator().alloc(u8, storage_bytes.len);
}

test "recycling chunks distinguish metadata exhaustion" {
    const chunk_bytes = 16;
    const storage_size = (fixed.Recycling.maximum_chunk_count + 1) * chunk_bytes;
    var storage_bytes: [storage_size]u8 align(16) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var owner = fixed.Recycling.init(
        storage_owner.allocator(),
        chunk_bytes,
        chunk_bytes,
    );
    defer owner.discard();
    const allocator = owner.allocator();

    for (0..fixed.Recycling.maximum_chunk_count) |_| {
        _ = try allocator.alloc(u8, chunk_bytes);
    }
    try std.testing.expectError(
        error.OutOfMemory,
        allocator.alloc(u8, chunk_bytes),
    );
    try std.testing.expect(owner.metadataExhausted());
    try std.testing.expect(!storage_owner.status().exhausted);
    try std.testing.expectEqual(
        storage_size - chunk_bytes,
        storage_owner.status().used_bytes,
    );

    owner.reset();
    try std.testing.expect(!owner.metadataExhausted());
    _ = try allocator.alloc(u8, chunk_bytes);
    try std.testing.expectEqual(
        storage_size - chunk_bytes,
        storage_owner.status().high_water_bytes,
    );
}

test "recycling chunks unwind a failed nested chunk transaction" {
    var storage_bytes: [640]u8 align(16) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var failing = std.testing.FailingAllocator.init(
        storage_owner.allocator(),
        .{ .fail_index = 2 },
    );
    var owner = fixed.Recycling.init(failing.allocator(), 128, 256);

    var failed = fixed.Chunks.init(owner.allocator(), 64, 256);
    _ = try failed.allocator().alloc(u8, 48);
    _ = try failed.allocator().alloc(u8, 96);
    try std.testing.expectError(
        error.OutOfMemory,
        failed.allocator().alloc(u8, 192),
    );
    failed.discard();

    failing.fail_index = std.math.maxInt(usize);
    var retry = fixed.Chunks.init(owner.allocator(), 64, 256);
    _ = try retry.allocator().alloc(u8, 48);
    _ = try retry.allocator().alloc(u8, 96);
    _ = try retry.allocator().alloc(u8, 192);
    retry.retain();
    try std.testing.expectEqual(@as(usize, 3), failing.alloc_index);
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().used_bytes);

    owner.discard();
    try std.testing.expectEqual(@as(usize, 0), storage_owner.status().used_bytes);
}

test "recycling chunks rewind alignment padding across chunks" {
    var storage_bytes: [64]u8 align(16) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var owner = fixed.Recycling.init(storage_owner.allocator(), 32, 32);
    defer owner.discard();
    const allocator = owner.allocator();

    const first = try allocator.alloc(u8, 1);
    const padded = try allocator.alignedAlloc(u8, .@"16", 1);
    const overflow = try allocator.alloc(u8, 16);
    try std.testing.expectEqual(
        @as(usize, 15),
        @intFromPtr(padded.ptr) - @intFromPtr(first.ptr) - first.len,
    );
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().used_bytes);

    allocator.free(overflow);
    allocator.free(padded);
    allocator.free(first);
    const reused_first = try allocator.alloc(u8, 32);
    const reused_second = try allocator.alloc(u8, 32);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused_first.ptr));
    try std.testing.expectEqual(@intFromPtr(overflow.ptr), @intFromPtr(reused_second.ptr));
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().high_water_bytes);
}

test "recycling chunks release relocated allocations" {
    var storage_bytes: [72]u8 align(16) = undefined;
    var storage_owner = fixed.Tracked.init(&storage_bytes);
    var owner = fixed.Recycling.init(storage_owner.allocator(), 32, 40);
    defer owner.discard();
    const allocator = owner.allocator();

    const initial = try allocator.alloc(u8, 24);
    @memset(initial, 0x51);
    const relocated = try allocator.realloc(initial, 40);
    try std.testing.expect(initial.ptr != relocated.ptr);
    for (relocated[0..initial.len]) |byte| {
        try std.testing.expectEqual(@as(u8, 0x51), byte);
    }
    allocator.free(relocated);

    const reused_first = try allocator.alloc(u8, 32);
    const reused_second = try allocator.alloc(u8, 40);
    try std.testing.expectEqual(@intFromPtr(initial.ptr), @intFromPtr(reused_first.ptr));
    try std.testing.expectEqual(@intFromPtr(relocated.ptr), @intFromPtr(reused_second.ptr));
    try std.testing.expectEqual(storage_bytes.len, storage_owner.status().high_water_bytes);
}

test "monotonic fixed chunks preserve tails around oversized allocations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counting = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var owner = fixed.Monotonic.init(counting.allocator(), 64);
    const allocator = owner.allocator();
    const first = try allocator.alloc(u8, 37);
    const second = try allocator.alloc(u8, 41);
    const oversized = try allocator.alloc(u8, 100);
    const tail = try allocator.alloc(u8, 20);
    @memset(first, 0x51);
    @memset(second, 0x52);
    @memset(oversized, 0x53);
    @memset(tail, 0x54);
    try std.testing.expectEqual(@as(usize, 3), counting.alloc_index);
    for (first) |byte| try std.testing.expectEqual(@as(u8, 0x51), byte);
    for (second) |byte| try std.testing.expectEqual(@as(u8, 0x52), byte);
    for (oversized) |byte| try std.testing.expectEqual(@as(u8, 0x53), byte);
    for (tail) |byte| try std.testing.expectEqual(@as(u8, 0x54), byte);
}

test "monotonic fixed chunks grow and release the current allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counting = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var owner = fixed.Monotonic.init(counting.allocator(), 64);
    const allocator = owner.allocator();
    const initial = try allocator.alloc(u8, 16);
    @memset(initial, 0x51);
    const grown = try allocator.realloc(initial, 32);
    try std.testing.expect(grown.ptr == initial.ptr);
    for (grown[0..initial.len]) |byte| {
        try std.testing.expectEqual(@as(u8, 0x51), byte);
    }
    allocator.free(grown);
    _ = try allocator.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
}

test "fixed fallback routes only excess storage to its backing allocator" {
    var storage: [64]u8 align(16) = undefined;
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var owner = fixed.Fallback.init(&storage, counting.allocator());
    const allocator = owner.allocator();
    const fixed_bytes = try allocator.alloc(u8, 48);
    const spilled = try allocator.alloc(u8, 32);
    @memset(fixed_bytes, 0x51);
    @memset(spilled, 0x52);
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    allocator.free(spilled);
    allocator.free(fixed_bytes);
}

test "instrumented fixed buffer records logical operations and failures" {
    if (!observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();

    var storage: [64]u8 align(16) = undefined;
    var owner = fixed.FixedBuffer.init(&storage);
    const allocator = owner.allocator();
    const first = try allocator.alloc(u8, 32);
    const second = try allocator.alloc(u8, 8);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 64));
    allocator.free(second);
    allocator.free(first);

    try std.testing.expectEqual(@as(usize, 5), recorder.count);
    try std.testing.expectEqual(observe.Operation.alloc, recorder.events[0].operation);
    try std.testing.expectEqual(observe.Operation.alloc, recorder.events[1].operation);
    try std.testing.expectEqual(observe.Operation.alloc, recorder.events[2].operation);
    try std.testing.expect(!recorder.events[2].succeeded);
    try std.testing.expectEqual(observe.Operation.free, recorder.events[3].operation);
    try std.testing.expectEqual(observe.Operation.free, recorder.events[4].operation);
    const producer_id = recorder.events[0].producer_id;
    try std.testing.expect(producer_id != 0);
    for (recorder.events[0..recorder.count]) |event| {
        try std.testing.expectEqual(observe.Producer.fixed_buffer, event.producer);
        try std.testing.expectEqual(producer_id, event.producer_id);
        try std.testing.expect(event.return_address != 0);
    }
}

test "thread-safe fixed buffer uses the observed vtable" {
    if (!observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();

    var storage: [64]u8 align(16) = undefined;
    var owner = fixed.FixedBuffer.init(&storage);
    const allocator = owner.threadSafeAllocator();
    const bytes = try allocator.alloc(u8, 8);
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
}

test "owned fixed-buffer package namespace" {
    std.testing.refAllDecls(fixed);
}
