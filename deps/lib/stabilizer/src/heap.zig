const std = @import("std");

const config = @import("config.zig");
const Marsaglia = @import("rng.zig").Marsaglia;

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const HeapConfig = config.HeapConfig;

const allocation_magic: usize = 0x51ab_11e5_7ab1_1e5;

const AllocationState = enum {
    inactive,
    active,
};

const Header = extern struct {
    magic: usize,
    base_addr: usize,
    base_len: usize,
    class_size: usize,
    requested_len: usize,
    alignment: usize,
    allocated: bool,
    tracked: bool,
};

const Slot = struct {
    memory: []u8,
};

const Pool = struct {
    class_size: usize,
    alignment: Alignment,
    pointer_validation: bool,
    slots: []Slot,

    fn init(
        heap: *ShuffleAllocator,
        class_size: usize,
        alignment: Alignment,
        pointer_validation: bool,
    ) !Pool {
        const count = heap.normalizedSlots();
        const slots = try heap.backing.alloc(Slot, count);
        var filled: usize = 0;
        errdefer {
            for (slots[0..filled]) |slot| heap.destroySlot(slot);
            heap.backing.free(slots);
        }

        while (filled < count) : (filled += 1) {
            slots[filled] = .{ .memory = try heap.createUserMemory(
                class_size,
                alignment,
                class_size,
                pointer_validation,
                .inactive,
            ) };
        }
        fisherYatesSlots(slots, &heap.rng);
        return .{
            .class_size = class_size,
            .alignment = alignment,
            .pointer_validation = pointer_validation,
            .slots = slots,
        };
    }

    fn deinit(self: *Pool, heap: *ShuffleAllocator) void {
        for (self.slots) |slot| heap.destroySlot(slot);
        heap.backing.free(self.slots);
        self.* = undefined;
    }
};

pub const ShuffleAllocator = struct {
    backing: Allocator,
    config: HeapConfig,
    rng: Marsaglia,
    pools: std.ArrayListUnmanaged(Pool) = .empty,
    known: std.AutoHashMapUnmanaged(usize, AllocationState) = .empty,

    pub fn init(backing: Allocator, heap_config: HeapConfig, seed: u64) ShuffleAllocator {
        return .{
            .backing = backing,
            .config = normalizeHeapConfig(heap_config),
            .rng = Marsaglia.init(seed),
        };
    }

    pub fn deinit(self: *ShuffleAllocator) void {
        for (self.pools.items) |*pool| pool.deinit(self);
        self.pools.deinit(self.backing);
        self.known.deinit(self.backing);
        self.* = undefined;
    }

    pub fn allocator(self: *ShuffleAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn malloc(self: *ShuffleAllocator, len: usize) ![*]u8 {
        return try self.alloc(len, Alignment.fromByteUnits(1), true, @returnAddress());
    }

    pub fn calloc(self: *ShuffleAllocator, count: usize, len: usize) ![*]u8 {
        const total = std.math.mul(usize, count, len) catch return error.OutOfMemory;
        const memory = try self.malloc(total);
        @memset(memory[0..total], 0);
        return memory;
    }

    pub fn realloc(self: *ShuffleAllocator, ptr: ?[*]u8, new_len: usize) !?[*]u8 {
        const memory = ptr orelse return try self.malloc(new_len);
        const state = self.known.get(@intFromPtr(memory)) orelse return error.InvalidAllocation;
        if (state == .inactive) return error.InvalidAllocation;
        const header = checkedHeader(memory) orelse return error.InvalidAllocation;
        if (!header.allocated) return error.InvalidAllocation;
        const alignment = Alignment.fromByteUnits(header.alignment);
        const old_len = header.requested_len;
        const old_memory = memory[0..old_len];

        if (new_len == 0) {
            self.free(old_memory, alignment, @returnAddress());
            return null;
        }

        if (self.resize(old_memory, alignment, new_len, @returnAddress())) return memory;

        const new_memory = try self.alloc(new_len, alignment, true, @returnAddress());
        @memcpy(new_memory[0..@min(old_len, new_len)], old_memory[0..@min(old_len, new_len)]);
        self.free(old_memory, alignment, @returnAddress());
        return new_memory;
    }

    pub fn freePointer(self: *ShuffleAllocator, ptr: ?[*]u8) void {
        _ = self.freePointerIfOwned(ptr);
    }

    pub fn freePointerIfOwned(self: *ShuffleAllocator, ptr: ?[*]u8) bool {
        const memory = ptr orelse return true;
        const state = self.known.get(@intFromPtr(memory)) orelse return false;
        if (state == .inactive) reportDoubleFreeError();
        const header = checkedHeader(memory) orelse return false;
        self.free(memory[0..header.requested_len], Alignment.fromByteUnits(header.alignment), @returnAddress());
        return true;
    }

    pub fn ownsPointer(self: *const ShuffleAllocator, ptr: ?[*]u8) bool {
        const memory = ptr orelse return false;
        return self.known.get(@intFromPtr(memory)) != null;
    }

    pub fn requestedLength(ptr: [*]u8) ?usize {
        const header = checkedHeader(ptr) orelse return null;
        if (!header.allocated) return null;
        return header.requested_len;
    }

    fn normalizedSlots(self: *const ShuffleAllocator) usize {
        return if (self.config.shuffle_slots == 0) 1 else self.config.shuffle_slots;
    }

    fn alloc(
        self: *ShuffleAllocator,
        len: usize,
        alignment: Alignment,
        pointer_validation: bool,
        ret_addr: usize,
    ) ![*]u8 {
        if (!self.config.enabled or len > self.config.max_shuffled_size) {
            const memory = try self.createUserMemory(
                len,
                alignment,
                0,
                pointer_validation,
                .active,
            );
            _ = ret_addr;
            return memory.ptr;
        }

        const class_size = try sizeClass(len, self.config.min_class_size);
        const pool = try self.getPool(class_size, alignment, pointer_validation);
        const index = self.rng.bounded(pool.slots.len);
        const replacement = Slot{ .memory = try self.createUserMemory(
            class_size,
            alignment,
            class_size,
            pointer_validation,
            .inactive,
        ) };
        const selected = pool.slots[index];
        const header = headerFromUser(selected.memory.ptr);
        if (header.allocated) reportDoubleFreeError();
        if (pointer_validation) self.activatePointer(selected.memory.ptr);
        pool.slots[index] = replacement;

        header.requested_len = len;
        header.allocated = true;
        return selected.memory.ptr;
    }

    fn resize(self: *ShuffleAllocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = self;
        _ = ret_addr;
        const header = checkedHeader(memory.ptr) orelse return false;
        if (!header.allocated) return false;
        if (header.alignment != alignment.toByteUnits()) return false;
        const current_class = header.class_size;
        if (current_class == 0) {
            if (new_len <= header.base_len - headerOffset(memory.ptr, header)) {
                header.requested_len = new_len;
                return true;
            }
            return false;
        }
        if (new_len <= current_class) {
            header.requested_len = new_len;
            return true;
        }
        return false;
    }

    fn remap(self: *ShuffleAllocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = self;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(self: *ShuffleAllocator, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const header = checkedHeader(memory.ptr) orelse return;
        if (header.alignment != alignment.toByteUnits()) return;
        if (!header.allocated) reportDoubleFreeError();
        header.allocated = false;
        if (header.tracked) {
            const state = self.known.getPtr(@intFromPtr(memory.ptr)) orelse unreachable;
            std.debug.assert(state.* == .active);
            state.* = .inactive;
        }
        if (header.class_size == 0 or !self.config.enabled) {
            self.destroyUserMemory(memory.ptr, ret_addr);
            return;
        }

        const pool = self.findPool(header.class_size, alignment, header.tracked) orelse {
            self.destroyUserMemory(memory.ptr, ret_addr);
            return;
        };
        const index = self.rng.bounded(pool.slots.len);
        const evicted = pool.slots[index];
        pool.slots[index] = .{ .memory = memory.ptr[0..header.class_size] };
        self.destroySlot(evicted);
    }

    fn getPool(
        self: *ShuffleAllocator,
        class_size: usize,
        alignment: Alignment,
        pointer_validation: bool,
    ) !*Pool {
        if (self.findPool(class_size, alignment, pointer_validation)) |pool| return pool;
        var pool = try Pool.init(self, class_size, alignment, pointer_validation);
        errdefer pool.deinit(self);
        try self.pools.append(self.backing, pool);
        return &self.pools.items[self.pools.items.len - 1];
    }

    fn findPool(
        self: *ShuffleAllocator,
        class_size: usize,
        alignment: Alignment,
        pointer_validation: bool,
    ) ?*Pool {
        for (self.pools.items) |*pool| {
            if (pool.class_size == class_size and
                pool.alignment == alignment and
                pool.pointer_validation == pointer_validation)
            {
                return pool;
            }
        }
        return null;
    }

    fn createUserMemory(
        self: *ShuffleAllocator,
        len: usize,
        alignment: Alignment,
        class_size: usize,
        pointer_validation: bool,
        state: AllocationState,
    ) ![]u8 {
        const user_alignment = Alignment.max(alignment, .of(Header));
        const alignment_bytes = user_alignment.toByteUnits();
        const overhead = std.math.add(usize, @sizeOf(Header), alignment_bytes - 1) catch
            return error.OutOfMemory;
        const base_len = std.math.add(usize, len, overhead) catch return error.OutOfMemory;
        const base = try self.backing.alloc(u8, base_len);
        const user_addr = user_alignment.forward(@intFromPtr(base.ptr) + @sizeOf(Header));
        const header: *Header = @ptrFromInt(user_addr - @sizeOf(Header));
        header.* = .{
            .magic = allocation_magic,
            .base_addr = @intFromPtr(base.ptr),
            .base_len = base_len,
            .class_size = class_size,
            .requested_len = len,
            .alignment = alignment.toByteUnits(),
            .allocated = class_size == 0,
            .tracked = false,
        };
        errdefer self.backing.free(base);
        if (pointer_validation) {
            try self.known.put(self.backing, user_addr, state);
            header.tracked = true;
        }
        return @as([*]u8, @ptrFromInt(user_addr))[0..len];
    }

    fn activatePointer(self: *ShuffleAllocator, ptr: [*]u8) void {
        const header = headerFromUser(ptr);
        std.debug.assert(header.tracked);
        const state = self.known.getPtr(@intFromPtr(ptr)) orelse unreachable;
        std.debug.assert(state.* == .inactive);
        state.* = .active;
    }

    fn destroySlot(self: *ShuffleAllocator, slot: Slot) void {
        self.destroyUserMemory(slot.memory.ptr, @returnAddress());
    }

    fn destroyUserMemory(self: *ShuffleAllocator, ptr: [*]u8, ret_addr: usize) void {
        _ = ret_addr;
        const header = checkedHeader(ptr) orelse return;
        const base: [*]u8 = @ptrFromInt(header.base_addr);
        if (header.tracked) std.debug.assert(self.known.remove(@intFromPtr(ptr)));
        self.backing.free(base[0..header.base_len]);
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ShuffleAllocator = @ptrCast(@alignCast(ctx));
        return self.alloc(len, alignment, self.config.pointer_validation, ret_addr) catch null;
    }

    fn rawResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ShuffleAllocator = @ptrCast(@alignCast(ctx));
        return self.resize(memory, alignment, new_len, ret_addr);
    }

    fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ShuffleAllocator = @ptrCast(@alignCast(ctx));
        return self.remap(memory, alignment, new_len, ret_addr);
    }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ShuffleAllocator = @ptrCast(@alignCast(ctx));
        self.free(memory, alignment, ret_addr);
    }
};

fn normalizeHeapConfig(heap_config: HeapConfig) HeapConfig {
    var out = heap_config;
    if (out.shuffle_slots == 0) out.shuffle_slots = 1;
    if (out.min_class_size == 0) out.min_class_size = 1;
    out.min_class_size = std.math.ceilPowerOfTwoAssert(usize, out.min_class_size);
    return out;
}

fn headerFromUser(ptr: [*]u8) *Header {
    return @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
}

fn checkedHeader(ptr: [*]u8) ?*Header {
    const header = headerFromUser(ptr);
    if (header.magic != allocation_magic) return null;
    return header;
}

fn headerOffset(ptr: [*]u8, header: *const Header) usize {
    return @intFromPtr(ptr) - header.base_addr;
}

pub fn sizeClass(len: usize, min_class_size: usize) !usize {
    const minimum = if (min_class_size == 0) 1 else std.math.ceilPowerOfTwoAssert(usize, min_class_size);
    return try std.math.ceilPowerOfTwo(usize, @max(len, minimum));
}

fn fisherYatesSlots(slots: []Slot, rng: *Marsaglia) void {
    if (slots.len <= 1) return;
    var index = slots.len - 1;
    while (index > 0) : (index -= 1) {
        const swap_index = rng.bounded(index + 1);
        std.mem.swap(Slot, &slots[index], &slots[swap_index]);
    }
}

fn reportDoubleFreeError() noreturn {
    @panic("Double free error");
}

fn exerciseTrackedPoolAllocationFailures(allocator: Allocator) !void {
    var heap = ShuffleAllocator.init(allocator, .{
        .shuffle_slots = 4,
        .max_shuffled_size = 1024,
    }, 1234);
    defer heap.deinit();

    const shuffled = heap.allocator();
    const memory = try shuffled.alloc(u8, 24);
    defer shuffled.free(memory);
    @memset(memory, 0xa5);
}

test "shuffle allocator exposes upstream c heap operations" {
    var heap = ShuffleAllocator.init(std.testing.allocator, .{
        .shuffle_slots = 4,
        .max_shuffled_size = 1024,
    }, 1234);
    defer heap.deinit();

    var ptr: ?[*]u8 = try heap.calloc(4, 8);
    defer heap.freePointer(ptr);

    try std.testing.expectEqual(@as(usize, 32), ShuffleAllocator.requestedLength(ptr.?).?);
    for (ptr.?[0..32]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    ptr.?[0] = 0xaa;
    ptr = (try heap.realloc(ptr, 128)).?;
    try std.testing.expectEqual(@as(usize, 128), ShuffleAllocator.requestedLength(ptr.?).?);
    try std.testing.expectEqual(@as(u8, 0xaa), ptr.?[0]);

    @memset(ptr.?[0..128], 0xbb);
    ptr = (try heap.realloc(ptr, 16)).?;
    try std.testing.expectEqual(@as(usize, 16), ShuffleAllocator.requestedLength(ptr.?).?);
    for (ptr.?[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xbb), byte);

    const freed = ptr.?;
    try std.testing.expect((try heap.realloc(ptr, 0)) == null);
    try std.testing.expect(ShuffleAllocator.requestedLength(freed) == null);
    ptr = null;
    heap.freePointer(null);
}

test "shuffle allocator marks freed shuffled pointers inactive" {
    var heap = ShuffleAllocator.init(std.testing.allocator, .{
        .shuffle_slots = 4,
        .max_shuffled_size = 1024,
    }, 1234);
    defer heap.deinit();

    const ptr = try heap.malloc(24);
    try std.testing.expect(heap.ownsPointer(ptr));
    try std.testing.expectEqual(@as(usize, 24), ShuffleAllocator.requestedLength(ptr).?);
    heap.freePointer(ptr);
    try std.testing.expect(heap.ownsPointer(ptr));
    try std.testing.expect(ShuffleAllocator.requestedLength(ptr) == null);
    try std.testing.expectError(error.InvalidAllocation, heap.realloc(ptr, 24));

    var foreign = [_]u8{0};
    try std.testing.expect(!heap.ownsPointer(foreign[0..].ptr));
    try std.testing.expect(!heap.freePointerIfOwned(foreign[0..].ptr));
}

test "allocator pointer validation is explicit and C pointers remain tracked" {
    var heap = ShuffleAllocator.init(std.testing.allocator, .{
        .pointer_validation = false,
        .shuffle_slots = 4,
        .max_shuffled_size = 1024,
    }, 1234);
    defer heap.deinit();

    const allocator = heap.allocator();
    const raw = try allocator.alloc(u8, 24);
    try std.testing.expectEqual(@as(usize, 0), heap.known.count());
    try std.testing.expect(!heap.ownsPointer(raw.ptr));
    allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 0), heap.known.count());

    const pointer = try heap.malloc(24);
    try std.testing.expect(heap.ownsPointer(pointer));
    try std.testing.expectEqual(AllocationState.active, heap.known.get(@intFromPtr(pointer)).?);
    heap.freePointer(pointer);
    try std.testing.expectEqual(AllocationState.inactive, heap.known.get(@intFromPtr(pointer)).?);

    const next_raw = try allocator.alloc(u8, 24);
    try std.testing.expect(next_raw.ptr != pointer);
    try std.testing.expect(!heap.ownsPointer(next_raw.ptr));
    try std.testing.expectEqual(@as(usize, 4), heap.known.count());
    allocator.free(next_raw);
    try std.testing.expectEqual(@as(usize, 2), heap.pools.items.len);
}

test "allocator pointer validation defaults to tracked pointers" {
    var heap = ShuffleAllocator.init(std.testing.allocator, .{
        .shuffle_slots = 1,
        .max_shuffled_size = 1024,
    }, 1234);
    defer heap.deinit();

    const allocator = heap.allocator();
    const memory = try allocator.alloc(u8, 24);
    try std.testing.expect(heap.ownsPointer(memory.ptr));
    allocator.free(memory);
    try std.testing.expect(heap.ownsPointer(memory.ptr));
}

test "pointer tracking allocation failure releases direct memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var heap = ShuffleAllocator.init(failing.allocator(), .{
        .enabled = false,
        .pointer_validation = false,
    }, 1234);
    defer heap.deinit();

    try std.testing.expectError(error.OutOfMemory, heap.malloc(24));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "tracked pool releases every failed initialization allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTrackedPoolAllocationFailures,
        .{},
    );
}

test "pooled pointer tracking failure preserves the selected slot" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var heap = ShuffleAllocator.init(failing.allocator(), .{
        .pointer_validation = false,
        .shuffle_slots = 1,
        .max_shuffled_size = 1024,
    }, 1234);

    const alignment = Alignment.fromByteUnits(1);
    const pool = try heap.getPool(32, alignment, true);
    const selected = pool.slots[0].memory.ptr;
    var dummy_key: usize = 1;
    while (heap.known.available > 0) : (dummy_key += 1) {
        heap.known.putAssumeCapacity(dummy_key, .inactive);
    }
    const known_count = heap.known.count();
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, heap.malloc(24));
    try std.testing.expectEqual(selected, pool.slots[0].memory.ptr);
    try std.testing.expect(!headerFromUser(selected).allocated);
    try std.testing.expectEqual(known_count, heap.known.count());
    try std.testing.expectEqual(AllocationState.inactive, heap.known.get(@intFromPtr(selected)).?);

    failing.fail_index = std.math.maxInt(usize);
    const pointer = try heap.malloc(24);
    heap.freePointer(pointer);
    heap.deinit();
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "realloc tracking failure preserves the old allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var heap = ShuffleAllocator.init(failing.allocator(), .{
        .pointer_validation = false,
        .shuffle_slots = 1,
        .max_shuffled_size = 1024,
    }, 1234);

    const pointer = try heap.malloc(24);
    pointer[0] = 0xa5;
    var dummy_key: usize = 1;
    while (heap.known.available > 0) : (dummy_key += 1) {
        heap.known.putAssumeCapacity(dummy_key, .inactive);
    }
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, heap.realloc(pointer, 2048));
    try std.testing.expectEqual(@as(u8, 0xa5), pointer[0]);
    try std.testing.expectEqual(@as(usize, 24), ShuffleAllocator.requestedLength(pointer).?);
    try std.testing.expect(heap.ownsPointer(pointer));

    failing.fail_index = std.math.maxInt(usize);
    heap.freePointer(pointer);
    heap.deinit();
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "untracked direct allocations resize remap and free without the address map" {
    var heap = ShuffleAllocator.init(std.testing.allocator, .{
        .pointer_validation = false,
        .max_shuffled_size = 8,
    }, 1234);
    defer heap.deinit();

    const allocator = heap.allocator();
    var memory = try allocator.alloc(u8, 64);
    @memset(memory, 0x5a);
    try std.testing.expect(allocator.resize(memory, 32));
    memory = memory.ptr[0..32];
    try std.testing.expectEqual(@as(usize, 0), heap.known.count());

    memory = try allocator.realloc(memory, 128);
    for (memory[0..32]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    try std.testing.expectEqual(@as(usize, 0), heap.known.count());
    allocator.free(memory);
    try std.testing.expectEqual(@as(usize, 0), heap.known.count());
}

test "allocation size overflow is reported as out of memory" {
    var heap = ShuffleAllocator.init(std.testing.allocator, .{
        .enabled = false,
        .pointer_validation = false,
    }, 1234);
    defer heap.deinit();

    try std.testing.expectError(error.OutOfMemory, heap.malloc(std.math.maxInt(usize)));
}
