const std = @import("std");
const hypothesis = @import("hypothesis");
const stabilizer = @import("stabilizer");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const ShuffleAllocator = stabilizer.ShuffleAllocator;

fn settings() hypothesis.Settings {
    return hypothesis.Settings.quick()
        .withSeed(0x57ab_11e5)
        .withDatabase("zig-out/hypothesis-failures/stabilizer");
}

fn drawUsize(data: *hypothesis.ConjectureData, min: usize, max: usize, shrink_towards: usize) !usize {
    return @intCast(try data.drawInteger(
        @intCast(min),
        @intCast(max),
        @intCast(shrink_towards),
    ));
}

fn drawAlignment(data: *hypothesis.ConjectureData) !Alignment {
    const shift = try drawUsize(data, 0, 8, 0);
    return .fromByteUnits(@as(usize, 1) << @as(u6, @intCast(shift)));
}

test "shuffle allocator reuses frees through the vector" {
    var heap = ShuffleAllocator.init(std.testing.allocator, .{
        .shuffle_slots = 4,
        .max_shuffled_size = 1024,
    }, 1234);
    defer heap.deinit();
    const allocator = heap.allocator();

    const first = try allocator.alloc(u8, 24);
    @memset(first, 0xaa);
    allocator.free(first);

    const second = try allocator.alloc(u8, 24);
    @memset(second, 0xbb);
    allocator.free(second);

    try std.testing.expect(heap.pools.items.len == 1);
}

const AllocatorRecord = struct {
    slice: []u8,
    alignment: Alignment,
    fill: u8,
};

const AllocatorProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        var heap = ShuffleAllocator.init(allocator, .{
            .pointer_validation = try data.drawBoolean(),
            .shuffle_slots = 8,
            .max_shuffled_size = 4096,
        }, 0x1234_5678);
        defer heap.deinit();
        const shuffled = heap.allocator();

        var active: std.ArrayListUnmanaged(AllocatorRecord) = .empty;
        defer active.deinit(allocator);
        defer {
            for (active.items) |record| {
                shuffled.rawFree(record.slice, record.alignment, @returnAddress());
            }
        }

        const steps = try drawUsize(data, 1, 96, 16);
        var step: usize = 0;
        while (step < steps) : (step += 1) {
            const op = try drawUsize(data, 0, 99, 0);
            if (op < 55 or active.items.len == 0) {
                const len = try drawUsize(data, 1, 2048, 1);
                const alignment = try drawAlignment(data);
                const ptr = shuffled.rawAlloc(len, alignment, @returnAddress()) orelse return error.OutOfMemory;
                const slice = ptr[0..len];
                const fill: u8 = @truncate(step);
                @memset(slice, fill);
                try std.testing.expect(std.mem.isAligned(@intFromPtr(slice.ptr), alignment.toByteUnits()));
                try active.append(allocator, .{ .slice = slice, .alignment = alignment, .fill = fill });
            } else if (op < 80) {
                const slot = try drawUsize(data, 0, active.items.len - 1, 0);
                var record = &active.items[slot];
                const old = record.slice;
                const new_len = try drawUsize(data, 1, 2048, 1);
                const resized_ptr = shuffled.rawAlloc(new_len, record.alignment, @returnAddress()) orelse return error.OutOfMemory;
                const resized = resized_ptr[0..new_len];
                const prefix_len = @min(old.len, new_len);
                @memcpy(resized[0..prefix_len], old[0..prefix_len]);
                shuffled.rawFree(old, record.alignment, @returnAddress());
                for (resized[0..prefix_len]) |byte| try std.testing.expectEqual(record.fill, byte);
                @memset(resized, record.fill);
                record.slice = resized;
            } else {
                const slot = try drawUsize(data, 0, active.items.len - 1, 0);
                shuffled.rawFree(active.items[slot].slice, active.items[slot].alignment, @returnAddress());
                _ = active.swapRemove(slot);
            }

            for (active.items) |record| {
                for (record.slice) |byte| try std.testing.expectEqual(record.fill, byte);
            }
        }
    }
};

test "pbt: shuffled allocator preserves active allocation contents" {
    try hypothesis.checkNamed(AllocatorProperty, "stabilizer-allocator", settings());
}

const CHeapRecord = struct {
    ptr: [*]u8,
    len: usize,
    fill: u8,
};

const CHeapProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        var heap = ShuffleAllocator.init(allocator, .{
            .pointer_validation = false,
            .shuffle_slots = 8,
            .max_shuffled_size = 4096,
        }, 0x4845_4150);
        defer heap.deinit();

        var active: std.ArrayListUnmanaged(CHeapRecord) = .empty;
        defer active.deinit(allocator);
        defer {
            for (active.items) |record| {
                heap.freePointer(record.ptr);
            }
        }

        const steps = try drawUsize(data, 1, 96, 16);
        var step: usize = 0;
        while (step < steps) : (step += 1) {
            const op = try drawUsize(data, 0, 99, 0);
            if (op < 55 or active.items.len == 0) {
                const fill: u8 = @truncate(step);
                const use_calloc = try data.drawBoolean();
                if (use_calloc) {
                    const count = try drawUsize(data, 0, 64, 1);
                    const len = try drawUsize(data, 0, 64, 1);
                    const total = count * len;
                    const ptr = try heap.calloc(count, len);
                    try std.testing.expectEqual(total, ShuffleAllocator.requestedLength(ptr).?);
                    for (ptr[0..total]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
                    @memset(ptr[0..total], fill);
                    try active.append(allocator, .{ .ptr = ptr, .len = total, .fill = fill });
                } else {
                    const len = try drawUsize(data, 0, 2048, 1);
                    const ptr = try heap.malloc(len);
                    try std.testing.expectEqual(len, ShuffleAllocator.requestedLength(ptr).?);
                    @memset(ptr[0..len], fill);
                    try active.append(allocator, .{ .ptr = ptr, .len = len, .fill = fill });
                }
            } else if (op < 80) {
                const slot = try drawUsize(data, 0, active.items.len - 1, 0);
                const old = active.items[slot];
                const new_len = try drawUsize(data, 0, 2048, 1);
                const maybe_resized = try heap.realloc(old.ptr, new_len);
                if (maybe_resized) |resized| {
                    const prefix_len = @min(old.len, new_len);
                    for (resized[0..prefix_len]) |byte| try std.testing.expectEqual(old.fill, byte);
                    try std.testing.expectEqual(new_len, ShuffleAllocator.requestedLength(resized).?);
                    @memset(resized[0..new_len], old.fill);
                    active.items[slot] = .{ .ptr = resized, .len = new_len, .fill = old.fill };
                } else {
                    try std.testing.expect(ShuffleAllocator.requestedLength(old.ptr) == null);
                    _ = active.swapRemove(slot);
                }
            } else {
                const slot = try drawUsize(data, 0, active.items.len - 1, 0);
                const freed = active.items[slot].ptr;
                heap.freePointer(freed);
                try std.testing.expect(ShuffleAllocator.requestedLength(freed) == null);
                _ = active.swapRemove(slot);
            }

            for (active.items) |record| {
                try std.testing.expectEqual(record.len, ShuffleAllocator.requestedLength(record.ptr).?);
                for (record.ptr[0..record.len]) |byte| try std.testing.expectEqual(record.fill, byte);
            }
        }
    }
};

test "pbt: c heap operations preserve active allocation contents" {
    try hypothesis.checkNamed(CHeapProperty, "stabilizer-c-heap", settings());
}
