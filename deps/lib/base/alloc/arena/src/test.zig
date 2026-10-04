const std = @import("std");
const observe = @import("alloc_observe");
const arena = @import("root.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Recorder = struct {
    events: [16]observe.Event = undefined,
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

const FixedChild = struct {
    fixed: std.heap.FixedBufferAllocator,
    alloc_lengths: [4]usize = @splat(0),
    resize_lengths: [8]usize = @splat(0),
    remap_lengths: [4]usize = @splat(0),
    alloc_count: usize = 0,
    resize_count: usize = 0,
    remap_count: usize = 0,
    free_count: usize = 0,

    fn init(bytes: []u8) FixedChild {
        return .{ .fixed = .init(bytes) };
    }

    fn allocator(self: *FixedChild) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn used(self: *const FixedChild) usize {
        return self.fixed.end_index;
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FixedChild = @ptrCast(@alignCast(context));
        std.debug.assert(self.alloc_count < self.alloc_lengths.len);
        self.alloc_lengths[self.alloc_count] = len;
        self.alloc_count += 1;
        return self.fixed.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        );
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *FixedChild = @ptrCast(@alignCast(context));
        std.debug.assert(self.resize_count < self.resize_lengths.len);
        self.resize_lengths[self.resize_count] = new_len;
        self.resize_count += 1;
        return self.fixed.allocator().rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FixedChild = @ptrCast(@alignCast(context));
        std.debug.assert(self.remap_count < self.remap_lengths.len);
        self.remap_lengths[self.remap_count] = new_len;
        self.remap_count += 1;
        return self.fixed.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *FixedChild = @ptrCast(@alignCast(context));
        self.free_count += 1;
        self.fixed.allocator().rawFree(
            memory,
            alignment,
            return_address,
        );
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

const RemapChild = struct {
    const storage_count = 3;
    const storage_bytes = 1_024;

    mode: enum { move, refuse },
    storage: [storage_count][storage_bytes]u8 align(@alignOf(usize)) = undefined,
    active: [storage_count]bool = @splat(false),
    active_lengths: [storage_count]usize = @splat(0),
    alloc_lengths: [2]usize = @splat(0),
    resize_lengths: [4]usize = @splat(0),
    remap_lengths: [2]usize = @splat(0),
    free_order: [2]usize = @splat(0),
    next_storage: usize = 0,
    alloc_count: usize = 0,
    resize_count: usize = 0,
    remap_count: usize = 0,
    free_count: usize = 0,

    fn allocator(self: *RemapChild) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        _: usize,
    ) ?[*]u8 {
        const self: *RemapChild = @ptrCast(@alignCast(context));
        std.debug.assert(self.alloc_count < self.alloc_lengths.len);
        self.alloc_lengths[self.alloc_count] = len;
        self.alloc_count += 1;
        if (len > storage_bytes or self.next_storage == storage_count) {
            return null;
        }
        const index = self.next_storage;
        self.next_storage += 1;
        const pointer = self.storage[index][0..len].ptr;
        if (@intFromPtr(pointer) % alignment.toByteUnits() != 0) return null;
        self.active[index] = true;
        self.active_lengths[index] = len;
        return pointer;
    }

    fn rawResize(
        context: *anyopaque,
        _: []u8,
        _: Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        const self: *RemapChild = @ptrCast(@alignCast(context));
        std.debug.assert(self.resize_count < self.resize_lengths.len);
        self.resize_lengths[self.resize_count] = new_len;
        self.resize_count += 1;
        return false;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        _: usize,
    ) ?[*]u8 {
        const self: *RemapChild = @ptrCast(@alignCast(context));
        std.debug.assert(self.remap_count < self.remap_lengths.len);
        self.remap_lengths[self.remap_count] = new_len;
        self.remap_count += 1;
        if (self.mode == .refuse or new_len > storage_bytes) return null;
        const source = self.storageIndex(memory.ptr) orelse return null;
        if (!self.active[source] or self.next_storage == storage_count) {
            return null;
        }
        const destination = self.next_storage;
        self.next_storage += 1;
        const pointer = self.storage[destination][0..new_len].ptr;
        if (@intFromPtr(pointer) % alignment.toByteUnits() != 0) return null;
        @memcpy(pointer[0..memory.len], memory);
        self.active[source] = false;
        self.active_lengths[source] = 0;
        self.active[destination] = true;
        self.active_lengths[destination] = new_len;
        return pointer;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        _: Alignment,
        _: usize,
    ) void {
        const self: *RemapChild = @ptrCast(@alignCast(context));
        const index = self.storageIndex(memory.ptr) orelse unreachable;
        std.debug.assert(self.active[index]);
        std.debug.assert(self.active_lengths[index] == memory.len);
        std.debug.assert(self.free_count < self.free_order.len);
        self.free_order[self.free_count] = index;
        self.free_count += 1;
        self.active[index] = false;
        self.active_lengths[index] = 0;
    }

    fn storageIndex(self: *RemapChild, pointer: [*]u8) ?usize {
        const address = @intFromPtr(pointer);
        for (&self.storage, 0..) |*bytes, index| {
            if (address == @intFromPtr(bytes.ptr)) return index;
        }
        return null;
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

test "owned arena preserves standard arena behavior" {
    var owner = arena.Arena.init(std.testing.allocator);
    defer owner.deinit();
    const allocator = owner.allocator();
    const first = try allocator.alloc(u8, 37);
    const second = try allocator.alignedAlloc(u32, .@"16", 11);
    @memset(first, 0x51);
    @memset(second, 0x52525252);
    try std.testing.expect(
        owner.queryCapacity() >=
            first.len + @sizeOf(u32) * second.len,
    );
    allocator.free(second);
    allocator.free(first);
    try std.testing.expect(owner.reset(.retain_capacity));
}

test "sequential scope fits exact fixed child capacity" {
    const capacity_bytes = 16 * 1024 * 1024;
    const prefix_bytes = 736;
    const first_bytes = 11_183_098;
    const second_bytes = 5_591_598;
    const final_bytes = 1_024;

    const storage = try std.testing.allocator.alignedAlloc(
        u8,
        .of(usize),
        capacity_bytes,
    );
    defer std.testing.allocator.free(storage);

    var recorder = Recorder{};
    var sink = recorder.sink();
    var observation: ?observe.Session = null;
    if (observe.enabled) observation = try observe.install(&sink);
    defer if (observation) |*session| session.deinit();

    var child = FixedChild.init(storage);
    const child_allocator = child.allocator();
    const prefix = try child_allocator.alignedAlloc(
        u8,
        .of(usize),
        prefix_bytes,
    );
    var owner = arena.SequentialScope.init(child_allocator);
    var owner_live = true;
    defer if (owner_live) {
        owner.deinit();
        child_allocator.free(prefix);
        std.debug.assert(child.used() == 0);
    };
    const scoped = owner.allocator();
    _ = try scoped.alignedAlloc(u8, .of(usize), first_bytes);
    _ = try scoped.alloc(u8, second_bytes);
    try std.testing.expectEqual(
        prefix_bytes + 16_774_720,
        child.used(),
    );
    const final = try scoped.alignedAlloc(
        u8,
        .of(usize),
        final_bytes,
    );
    try std.testing.expectEqual(final_bytes, final.len);
    try std.testing.expectEqual(
        @as(usize, 16_776_480),
        child.used(),
    );
    try std.testing.expectEqual(@as(usize, 2), child.alloc_count);
    try std.testing.expectEqual(@as(usize, 2), child.resize_count);
    try std.testing.expectEqual(@as(usize, 1), child.remap_count);
    try std.testing.expectEqual(
        @as(usize, 11_183_122),
        child.alloc_lengths[1],
    );
    try std.testing.expectEqual(
        @as(usize, 16_774_720),
        child.remap_lengths[0],
    );
    try std.testing.expectEqual(
        @as(usize, 25_163_652),
        child.resize_lengths[0],
    );
    try std.testing.expectEqual(
        @as(usize, 16_775_744),
        child.resize_lengths[1],
    );
    try std.testing.expectEqual(
        @as(usize, 16_775_720),
        owner.queryCapacity(),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        scoped.alloc(u8, 737),
    );
    try std.testing.expectEqual(
        @as(usize, 16_776_480),
        child.used(),
    );
    const retry = try scoped.alloc(u8, 736);
    try std.testing.expectEqual(@as(usize, 736), retry.len);
    try std.testing.expectEqual(capacity_bytes, child.used());
    try std.testing.expectEqual(@as(usize, 3), child.alloc_count);
    try std.testing.expectEqual(@as(usize, 6), child.resize_count);
    try std.testing.expectEqual(
        @as(usize, 25_164_748),
        child.resize_lengths[2],
    );
    try std.testing.expectEqual(
        @as(usize, 16_776_481),
        child.resize_lengths[3],
    );
    try std.testing.expectEqual(
        @as(usize, 761),
        child.alloc_lengths[2],
    );
    try std.testing.expectEqual(
        @as(usize, 25_164_746),
        child.resize_lengths[4],
    );
    try std.testing.expectEqual(
        @as(usize, 16_776_480),
        child.resize_lengths[5],
    );
    owner.deinit();
    child_allocator.free(prefix);
    owner_live = false;
    try std.testing.expectEqual(@as(usize, 0), child.used());
    try std.testing.expectEqual(@as(usize, 2), child.free_count);
    if (observe.enabled) {
        try std.testing.expectEqual(@as(usize, 6), recorder.count);
        for (recorder.events[0..3]) |event| {
            try std.testing.expectEqual(observe.Operation.alloc, event.operation);
            try std.testing.expect(event.succeeded);
        }
        try std.testing.expectEqual(observe.Operation.alloc, recorder.events[3].operation);
        try std.testing.expect(!recorder.events[3].succeeded);
        try std.testing.expectEqual(observe.Operation.alloc, recorder.events[4].operation);
        try std.testing.expect(recorder.events[4].succeeded);
        try std.testing.expectEqual(observe.Operation.lifecycle, recorder.events[5].operation);
        try std.testing.expectEqual(observe.LifecycleReason.deinit, recorder.events[5].lifecycle_reason);
    }
}

test "sequential scope decides fresh remap before publication" {
    const node_bytes = 3 * @sizeOf(usize);
    {
        var child = RemapChild{ .mode = .move };
        var owner = arena.SequentialScope.init(child.allocator());
        const scoped = owner.allocator();
        const allocation = try scoped.alignedAlloc(u8, .of(usize), 64);
        try std.testing.expectEqual(
            @intFromPtr(child.storage[1][node_bytes..].ptr),
            @intFromPtr(allocation.ptr),
        );
        try std.testing.expectEqual(@as(usize, 88), child.alloc_lengths[0]);
        try std.testing.expectEqual(@as(usize, 168), child.remap_lengths[0]);
        try std.testing.expectEqual(@as(usize, 144), owner.queryCapacity());
        owner.deinit();
        try std.testing.expectEqual(@as(usize, 1), child.free_count);
        try std.testing.expectEqual(@as(usize, 1), child.free_order[0]);
    }
    {
        var child = RemapChild{ .mode = .refuse };
        var owner = arena.SequentialScope.init(child.allocator());
        const scoped = owner.allocator();
        _ = try scoped.alignedAlloc(u8, .of(usize), 64);
        _ = try scoped.alloc(u8, 400);
        try std.testing.expectEqualSlices(
            usize,
            &.{ 88, 424 },
            child.alloc_lengths[0..child.alloc_count],
        );
        try std.testing.expectEqualSlices(
            usize,
            &.{ 758, 488 },
            child.resize_lengths[0..child.resize_count],
        );
        try std.testing.expectEqualSlices(
            usize,
            &.{ 168, 758 },
            child.remap_lengths[0..child.remap_count],
        );
        try std.testing.expectEqual(@as(usize, 464), owner.queryCapacity());
        owner.deinit();
        try std.testing.expectEqualSlices(
            usize,
            &.{ 1, 0 },
            child.free_order[0..child.free_count],
        );
    }
}

test "instrumented owned arena records every logical operation" {
    if (!observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();

    var owner = arena.Arena.init(std.testing.allocator);
    defer owner.deinit();
    const allocator = owner.allocator();
    const first = try allocator.alloc(u8, 32);
    const second = try allocator.alloc(u8, 8);
    allocator.free(second);
    allocator.free(first);

    try std.testing.expectEqual(@as(usize, 4), recorder.count);
    try std.testing.expectEqual(
        observe.Operation.alloc,
        recorder.events[0].operation,
    );
    try std.testing.expectEqual(
        observe.Operation.alloc,
        recorder.events[1].operation,
    );
    try std.testing.expectEqual(
        observe.Operation.free,
        recorder.events[2].operation,
    );
    try std.testing.expectEqual(
        observe.Operation.free,
        recorder.events[3].operation,
    );
    const producer_id = recorder.events[0].producer_id;
    try std.testing.expect(producer_id != 0);
    for (recorder.events[0..recorder.count]) |event| {
        try std.testing.expectEqual(observe.Producer.arena, event.producer);
        try std.testing.expectEqual(producer_id, event.producer_id);
        try std.testing.expect(event.return_address != 0);
    }
}

test "arena reset advances generation before same-address reuse" {
    if (!observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();

    var owner = arena.Arena.init(std.testing.allocator);
    const allocator = owner.allocator();
    const first = try allocator.alloc(u8, 32);
    const first_address = @intFromPtr(first.ptr);
    try std.testing.expect(owner.reset(.retain_capacity));
    const second = try allocator.alloc(u8, 32);
    allocator.free(second);
    owner.deinit();

    try std.testing.expectEqual(first_address, @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(usize, 5), recorder.count);
    try std.testing.expectEqual(observe.Operation.alloc, recorder.events[0].operation);
    try std.testing.expectEqual(@as(u64, 0), recorder.events[0].generation);
    try std.testing.expectEqual(observe.Operation.lifecycle, recorder.events[1].operation);
    try std.testing.expectEqual(
        observe.LifecycleDisposition.invalidate,
        recorder.events[1].lifecycle_disposition,
    );
    try std.testing.expectEqual(
        observe.LifecycleReason.reset,
        recorder.events[1].lifecycle_reason,
    );
    try std.testing.expectEqual(@as(u64, 0), recorder.events[1].generation);
    try std.testing.expectEqual(observe.Operation.alloc, recorder.events[2].operation);
    try std.testing.expectEqual(@as(u64, 1), recorder.events[2].generation);
    try std.testing.expectEqual(observe.Operation.free, recorder.events[3].operation);
    try std.testing.expectEqual(@as(u64, 1), recorder.events[3].generation);
    try std.testing.expectEqual(observe.Operation.lifecycle, recorder.events[4].operation);
    try std.testing.expectEqual(
        observe.LifecycleDisposition.end,
        recorder.events[4].lifecycle_disposition,
    );
    try std.testing.expectEqual(
        observe.LifecycleReason.deinit,
        recorder.events[4].lifecycle_reason,
    );
    for (recorder.events[0..recorder.count]) |event| {
        try std.testing.expectEqual(
            observe.Identity.movable(
                event.producer_id,
                .arena,
                event.generation,
            ).owner_cookie,
            event.owner_cookie,
        );
    }
}

test "arena observation identity survives value movement" {
    if (!observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();

    var original = arena.Arena.init(std.testing.allocator);
    _ = try original.allocator().alloc(u8, 32);
    var moved = original;
    original = undefined;
    moved.deinit();

    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqual(
        observe.Operation.alloc,
        recorder.events[0].operation,
    );
    try std.testing.expectEqual(
        observe.Operation.lifecycle,
        recorder.events[1].operation,
    );
    try std.testing.expectEqual(
        recorder.events[0].owner_cookie,
        recorder.events[1].owner_cookie,
    );
    try std.testing.expect(recorder.events[0].owner_cookie != 0);
}

test "owned arena package namespace" {
    std.testing.refAllDecls(arena);
}
