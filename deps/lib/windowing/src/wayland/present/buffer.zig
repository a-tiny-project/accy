const std = @import("std");
const native = @import("wayland");
const windowing = @import("../../root.zig");

pub const damage = @import("damage.zig");

const runtime = native.runtime;

const Buffer = native.shm.Buffer;
pub const Format = native.shm.Format;
pub const SwapchainError = native.shm.Error ||
    error{RetiredCapacityExceeded};

const BufferIndex = u32;
const no_buffer = std.math.maxInt(BufferIndex);

pub const CapacityError = error{
    ActiveBuffersEmpty,
    RetiredBuffersEmpty,
    BufferSlotsTooMany,
    CapacityOverflow,
};

pub const Capacity = struct {
    active_buffer_count: usize,
    retired_buffer_count: usize,
    buffer_slot_count: usize,
    buffer_slot_bytes: usize,
    active_index_bytes: usize,
    replacement_index_bytes: usize,
    retired_index_bytes: usize,
    dirty_region_bytes: usize,
    metadata_storage_bytes: usize,

    pub fn derive(
        active_buffer_count: usize,
        retired_buffer_count: usize,
    ) CapacityError!Capacity {
        if (active_buffer_count == 0) return error.ActiveBuffersEmpty;
        if (retired_buffer_count == 0) return error.RetiredBuffersEmpty;
        const working_buffer_count = std.math.mul(
            usize,
            active_buffer_count,
            2,
        ) catch return error.CapacityOverflow;
        const buffer_slot_count = std.math.add(
            usize,
            working_buffer_count,
            retired_buffer_count,
        ) catch return error.CapacityOverflow;
        if (buffer_slot_count > std.math.maxInt(BufferIndex)) {
            return error.BufferSlotsTooMany;
        }
        const buffer_slot_bytes = std.math.mul(
            usize,
            buffer_slot_count,
            @sizeOf(?Buffer),
        ) catch return error.CapacityOverflow;
        const active_index_bytes = try indexBytes(active_buffer_count);
        const replacement_index_bytes = active_index_bytes;
        const retired_index_bytes = try indexBytes(retired_buffer_count);
        const dirty_region_bytes = std.math.mul(
            usize,
            buffer_slot_count,
            @sizeOf(damage.Region),
        ) catch return error.CapacityOverflow;
        const metadata_storage_bytes = try sum(&.{
            buffer_slot_bytes,
            dirty_region_bytes,
            active_index_bytes,
            replacement_index_bytes,
            retired_index_bytes,
        });
        return .{
            .active_buffer_count = active_buffer_count,
            .retired_buffer_count = retired_buffer_count,
            .buffer_slot_count = buffer_slot_count,
            .buffer_slot_bytes = buffer_slot_bytes,
            .active_index_bytes = active_index_bytes,
            .replacement_index_bytes = replacement_index_bytes,
            .retired_index_bytes = retired_index_bytes,
            .dirty_region_bytes = dirty_region_bytes,
            .metadata_storage_bytes = metadata_storage_bytes,
        };
    }
};

fn indexBytes(count: usize) CapacityError!usize {
    return std.math.mul(usize, count, @sizeOf(BufferIndex)) catch
        error.CapacityOverflow;
}

fn sum(terms: []const usize) CapacityError!usize {
    var total: usize = 0;
    for (terms) |term| {
        total = std.math.add(usize, total, term) catch return error.CapacityOverflow;
    }
    return total;
}

const Storage = struct {
    buffers: []?Buffer,
    dirty: []damage.Region,
    working_indices: []BufferIndex,
    retired: []BufferIndex,
    active_buffer_count: usize,
    retired_count: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Storage {
        std.debug.assert(capacity.active_buffer_count > 0);
        std.debug.assert(capacity.retired_buffer_count > 0);
        std.debug.assert(capacity.buffer_slot_count <= std.math.maxInt(BufferIndex));
        std.debug.assert(capacity.active_buffer_count <= std.math.maxInt(usize) / 2);
        std.debug.assert(
            capacity.active_buffer_count * 2 <=
                std.math.maxInt(usize) - capacity.retired_buffer_count,
        );
        std.debug.assert(
            capacity.active_buffer_count * 2 + capacity.retired_buffer_count ==
                capacity.buffer_slot_count,
        );
        std.debug.assert(capacity.buffer_slot_bytes % @sizeOf(?Buffer) == 0);
        std.debug.assert(
            capacity.buffer_slot_bytes / @sizeOf(?Buffer) == capacity.buffer_slot_count,
        );
        std.debug.assert(capacity.active_index_bytes % @sizeOf(BufferIndex) == 0);
        std.debug.assert(
            capacity.active_index_bytes / @sizeOf(BufferIndex) ==
                capacity.active_buffer_count,
        );
        std.debug.assert(capacity.replacement_index_bytes == capacity.active_index_bytes);
        std.debug.assert(capacity.retired_index_bytes % @sizeOf(BufferIndex) == 0);
        std.debug.assert(
            capacity.retired_index_bytes / @sizeOf(BufferIndex) ==
                capacity.retired_buffer_count,
        );

        const buffers = try allocator.alloc(?Buffer, capacity.buffer_slot_count);
        errdefer allocator.free(buffers);
        @memset(buffers, null);
        const working_indices = try allocator.alloc(
            BufferIndex,
            capacity.active_buffer_count * 2,
        );
        errdefer allocator.free(working_indices);
        @memset(working_indices, no_buffer);
        const retired = try allocator.alloc(BufferIndex, capacity.retired_buffer_count);
        errdefer allocator.free(retired);
        const dirty = try allocator.alloc(damage.Region, capacity.buffer_slot_count);
        @memset(dirty, .{});
        return .{
            .buffers = buffers,
            .dirty = dirty,
            .working_indices = working_indices,
            .retired = retired,
            .active_buffer_count = capacity.active_buffer_count,
        };
    }

    fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.retired_count <= self.retired.len);
        for (self.buffers) |slot| std.debug.assert(slot == null);
        allocator.free(self.dirty);
        allocator.free(self.retired);
        allocator.free(self.working_indices);
        allocator.free(self.buffers);
        self.* = undefined;
    }

    fn active(self: *Storage) []BufferIndex {
        return self.working_indices[0..self.active_buffer_count];
    }

    fn replacement(self: *Storage) []BufferIndex {
        return self.working_indices[self.active_buffer_count..];
    }
};

/// A pair of one buffer the compositor is done with and that buffer's
/// accumulator. A present takes the pair, writes the listed rectangles into the
/// buffer, and then sends the buffer.
pub const Acquired = struct {
    buffer: *Buffer,
    dirty: *damage.Region,

    /// Copies every rectangle the buffer owes out of `source` into the buffer,
    /// converting each pixel to the compositor's byte order, so a present
    /// brings the buffer up to the logical frame. `source` holds the whole
    /// frame at the buffer's extent, and each rectangle is read from the same
    /// offsets it is written to. The call empties the accumulator once every
    /// rectangle is written, so the buffer owes nothing until the next change
    /// arrives. The call returns four bytes for each pixel of the listed
    /// rectangles. The accumulator has to hold at least one rectangle when the
    /// call starts. A failure from the pixel copy comes back as the call's
    /// error, with the accumulator left as it was.
    pub fn write(self: Acquired, source: []const u8) native.shm.PixelError!usize {
        std.debug.assert(!self.dirty.isEmpty());
        var written: usize = 0;
        for (self.dirty.slice()) |region| {
            try self.buffer.writeRgba8(source, .{
                .x = region.x,
                .y = region.y,
                .width = region.width,
                .height = region.height,
            });
            written += region.pixelCount() * 4;
        }
        std.debug.assert(written == self.dirty.pixelCount() * 4);
        self.dirty.clear();
        return written;
    }
};

pub const Swapchain = struct {
    allocator: std.mem.Allocator,
    client: *runtime.Client,
    storage: Storage,
    shm: u32 = 0,
    format: Format = .xrgb8888,
    configured: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    retired_capacity_rejection_count: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *runtime.Client,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Swapchain {
        return .{
            .allocator = allocator,
            .client = client,
            .storage = try Storage.init(allocator, capacity),
        };
    }

    pub fn configure(self: *Swapchain, shm: u32, format: Format) void {
        std.debug.assert(!self.configured);
        self.shm = shm;
        self.format = format;
        self.configured = true;
    }

    pub fn deinit(self: *Swapchain) void {
        for (self.storage.buffers) |*slot| {
            if (slot.*) |*value| value.deinit(self.client);
            slot.* = null;
        }
        self.storage.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dispatch(self: *Swapchain, event: *runtime.RoutedView) !bool {
        for (self.storage.buffers) |*slot| {
            if (slot.*) |*value| {
                if (value.object_id != event.object_id) continue;
                try value.dispatch(event);
                return true;
            }
        }
        return false;
    }

    pub fn ensure(self: *Swapchain, width: u32, height: u32) SwapchainError!void {
        std.debug.assert(self.configured);
        self.collectRetired();
        const active = self.storage.active();
        if (self.width == width and self.height == height and active[0] != no_buffer) return;

        var busy_count: usize = 0;
        for (active) |index| {
            if (index != no_buffer and self.buffer(index).busy) busy_count += 1;
        }
        if (!self.admitRetirement(busy_count)) return error.RetiredCapacityExceeded;

        errdefer self.clearReplacement();
        for (self.storage.replacement()) |*slot| {
            std.debug.assert(slot.* == no_buffer);
            const index = self.findFreeBuffer() orelse unreachable;
            const value = try Buffer.open(
                self.client,
                self.shm,
                width,
                height,
                self.format,
            );
            self.installBuffer(index, value, width, height);
            slot.* = index;
        }

        self.commitReplacement();
        self.width = width;
        self.height = height;
    }

    /// Destroys every retired buffer the compositor has released. The call
    /// hands back the first active buffer that is free, together with that
    /// buffer's accumulator, so a present finds a buffer it may write now. The
    /// returned accumulator lists where that buffer differs from the logical
    /// frame, so a present writes those rectangles and then clears the list.
    /// The call returns null when the compositor holds every active buffer, and
    /// the presenter then keeps the frame for a later send.
    pub fn acquire(self: *Swapchain) ?Acquired {
        self.collectRetired();
        for (self.storage.active()) |index| {
            if (index == no_buffer) continue;
            const value = self.buffer(index);
            if (value.busy) continue;
            return .{ .buffer = value, .dirty = &self.storage.dirty[@intCast(index)] };
        }
        return null;
    }

    /// Adds the rectangle `region` to the accumulator of every active buffer,
    /// busy or free, because the change applies to all of them. The presenter
    /// calls this at every present so each buffer learns what it will have to
    /// rewrite when its turn comes. The call answers `.collapsed` when at least
    /// one of those accumulators ran out of room, and `.exact` when none did.
    pub fn markDamage(self: *Swapchain, region: windowing.PresentRegion) damage.Addition {
        var addition: damage.Addition = .exact;
        for (self.storage.active()) |index| {
            if (index == no_buffer) continue;
            if (self.storage.dirty[@intCast(index)].add(region) == .collapsed) {
                addition = .collapsed;
            }
        }
        return addition;
    }

    pub fn collectRetired(self: *Swapchain) void {
        var position = self.storage.retired_count;
        while (position > 0) {
            position -= 1;
            const index = self.storage.retired[position];
            if (self.buffer(index).busy) continue;
            self.storage.retired_count -= 1;
            self.storage.retired[position] = self.storage.retired[self.storage.retired_count];
            self.destroy(index);
        }
    }

    pub fn retiredCapacityRejectionCount(self: *const Swapchain) u64 {
        return self.retired_capacity_rejection_count;
    }

    fn admitRetirement(self: *Swapchain, busy_count: usize) bool {
        std.debug.assert(self.storage.retired_count <= self.storage.retired.len);
        if (busy_count <= self.storage.retired.len - self.storage.retired_count) return true;
        self.retired_capacity_rejection_count +|= 1;
        return false;
    }

    fn commitReplacement(self: *Swapchain) void {
        const active = self.storage.active();
        for (active) |*slot| {
            const index = slot.*;
            if (index == no_buffer) continue;
            if (self.buffer(index).busy) {
                std.debug.assert(self.storage.retired_count < self.storage.retired.len);
                self.storage.retired[self.storage.retired_count] = index;
                self.storage.retired_count += 1;
            } else {
                self.destroy(index);
            }
            slot.* = no_buffer;
        }

        const replacement = self.storage.replacement();
        for (active, replacement) |*active_slot, *replacement_slot| {
            std.debug.assert(replacement_slot.* != no_buffer);
            active_slot.* = replacement_slot.*;
            replacement_slot.* = no_buffer;
        }
    }

    fn clearReplacement(self: *Swapchain) void {
        for (self.storage.replacement()) |*slot| {
            if (slot.* != no_buffer) self.destroy(slot.*);
            slot.* = no_buffer;
        }
    }

    /// Stores a newly created buffer in an empty slot and covers that slot's
    /// accumulator with the whole extent, so the first present into that buffer
    /// writes all of it. A new buffer holds none of the frame's pixels yet,
    /// which is why it owes every one of them. The slot has to be empty.
    fn installBuffer(
        self: *Swapchain,
        index: BufferIndex,
        value: Buffer,
        width: u32,
        height: u32,
    ) void {
        std.debug.assert(self.storage.buffers[@intCast(index)] == null);
        self.storage.buffers[@intCast(index)] = value;
        self.storage.dirty[@intCast(index)].cover(width, height);
    }

    fn findFreeBuffer(self: *const Swapchain) ?BufferIndex {
        for (self.storage.buffers, 0..) |slot, index| {
            if (slot == null) return @intCast(index);
        }
        return null;
    }

    fn buffer(self: *Swapchain, index: BufferIndex) *Buffer {
        std.debug.assert(index != no_buffer);
        if (self.storage.buffers[@intCast(index)]) |*value| return value;
        unreachable;
    }

    fn destroy(self: *Swapchain, index: BufferIndex) void {
        const value = self.buffer(index);
        value.deinit(self.client);
        self.storage.buffers[@intCast(index)] = null;
        self.storage.dirty[@intCast(index)].clear();
    }
};

test "swapchain capacity derives exact transient metadata and rejects invalid limits" {
    const capacity = try Capacity.derive(3, 5);
    try std.testing.expectEqual(@as(usize, 3), capacity.active_buffer_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.retired_buffer_count);
    try std.testing.expectEqual(@as(usize, 11), capacity.buffer_slot_count);
    try std.testing.expectEqual(11 * @sizeOf(?Buffer), capacity.buffer_slot_bytes);
    try std.testing.expectEqual(3 * @sizeOf(BufferIndex), capacity.active_index_bytes);
    try std.testing.expectEqual(3 * @sizeOf(BufferIndex), capacity.replacement_index_bytes);
    try std.testing.expectEqual(5 * @sizeOf(BufferIndex), capacity.retired_index_bytes);
    try std.testing.expectEqual(11 * @sizeOf(damage.Region), capacity.dirty_region_bytes);
    try std.testing.expectEqual(
        capacity.buffer_slot_bytes +
            capacity.dirty_region_bytes +
            capacity.active_index_bytes +
            capacity.replacement_index_bytes +
            capacity.retired_index_bytes,
        capacity.metadata_storage_bytes,
    );
    try std.testing.expectError(error.ActiveBuffersEmpty, Capacity.derive(0, 1));
    try std.testing.expectError(error.RetiredBuffersEmpty, Capacity.derive(1, 0));
    if (@sizeOf(usize) > @sizeOf(BufferIndex)) {
        try std.testing.expectError(
            error.BufferSlotsTooMany,
            Capacity.derive(std.math.maxInt(BufferIndex) / 2, 2),
        );
    }
    try std.testing.expectError(
        error.CapacityOverflow,
        Capacity.derive(std.math.maxInt(usize) / 2 + 1, 1),
    );
}

test "swapchain metadata acquires every region at initialization" {
    const capacity = try Capacity.derive(2, 2);
    const client: *runtime.Client = undefined;
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(
            error.OutOfMemory,
            Swapchain.init(failing.allocator(), client, capacity),
        );
    }

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var swapchain = try Swapchain.init(failing.allocator(), client, capacity);
    defer swapchain.deinit();
    try std.testing.expectEqual(@as(usize, 4), failing.allocations);
    try std.testing.expectEqual(@as(usize, 2), swapchain.storage.active().len);
    try std.testing.expectEqual(@as(usize, 2), swapchain.storage.replacement().len);
    try std.testing.expectEqual(@as(usize, 2), swapchain.storage.retired.len);
}

test "swapchain metadata commits one full retirement and rejects max plus one" {
    const capacity = try Capacity.derive(2, 2);
    const client: *runtime.Client = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var swapchain = try Swapchain.init(failing.allocator(), client, capacity);
    defer swapchain.deinit();
    try std.testing.expect(swapchain.admitRetirement(2));
    var mapped: [1]u8 align(std.heap.page_size_min) = undefined;
    for (swapchain.storage.buffers[0..4], 0..) |*slot, index| {
        slot.* = Buffer{
            .object_id = @intCast(index + 1),
            .mapping = mapped[0..],
            .byte_len = 1,
            .width = 1,
            .height = 1,
            .stride = 4,
            .format = .xbgr8888,
            .busy = index < 2,
        };
    }
    swapchain.storage.active()[0] = 0;
    swapchain.storage.active()[1] = 1;
    swapchain.storage.replacement()[0] = 2;
    swapchain.storage.replacement()[1] = 3;
    swapchain.commitReplacement();
    try std.testing.expectEqualSlices(BufferIndex, &.{ 2, 3 }, swapchain.storage.active());
    try std.testing.expectEqualSlices(
        BufferIndex,
        &.{ no_buffer, no_buffer },
        swapchain.storage.replacement(),
    );
    try std.testing.expectEqual(@as(usize, 2), swapchain.storage.retired_count);
    try std.testing.expectEqualSlices(BufferIndex, &.{ 0, 1 }, swapchain.storage.retired);

    const active_before = [2]BufferIndex{
        swapchain.storage.active()[0],
        swapchain.storage.active()[1],
    };
    try std.testing.expect(!swapchain.admitRetirement(1));
    try std.testing.expectEqualSlices(BufferIndex, &active_before, swapchain.storage.active());
    try std.testing.expectEqual(@as(usize, 2), swapchain.storage.retired_count);
    try std.testing.expectEqual(@as(u64, 1), swapchain.retiredCapacityRejectionCount());
    swapchain.retired_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expect(!swapchain.admitRetirement(1));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        swapchain.retiredCapacityRejectionCount(),
    );
    try std.testing.expectEqual(@as(usize, 4), failing.allocations);

    @memset(swapchain.storage.buffers, null);
    @memset(swapchain.storage.working_indices, no_buffer);
    swapchain.storage.retired_count = 0;
}

test "swapchain metadata reuses a released buffer slot" {
    const capacity = try Capacity.derive(2, 2);
    const client: *runtime.Client = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var swapchain = try Swapchain.init(failing.allocator(), client, capacity);
    defer swapchain.deinit();
    var mapped: [1]u8 align(std.heap.page_size_min) = undefined;
    const first = swapchain.findFreeBuffer().?;
    swapchain.storage.buffers[@intCast(first)] = Buffer{
        .object_id = 9,
        .mapping = mapped[0..],
        .byte_len = 1,
        .width = 1,
        .height = 1,
        .stride = 4,
        .format = .xbgr8888,
    };
    try std.testing.expect(swapchain.findFreeBuffer().? != first);
    swapchain.storage.buffers[@intCast(first)] = null;
    try std.testing.expectEqual(first, swapchain.findFreeBuffer().?);
    try std.testing.expectEqual(@as(usize, 4), failing.allocations);
}

test "XRGB conversion writes protocol byte order" {
    var bytes: [8]u8 align(std.heap.page_size_min) = undefined;
    var value = Buffer{
        .object_id = 10,
        .mapping = @alignCast(bytes[0..]),
        .byte_len = bytes.len,
        .width = 2,
        .height = 1,
        .stride = 8,
        .format = .xrgb8888,
    };
    try value.writeRgba8(&.{ 1, 2, 3, 4, 10, 20, 30, 40 }, value.fullRegion());
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255, 30, 20, 10, 255 }, &bytes);
}

const rotation_width: u32 = 16;
const rotation_height: u32 = 12;
const rotation_bytes: usize = rotation_width * rotation_height * 4;
const rotation_slots: usize = 3;

/// A test harness that builds a swapchain of three buffers whose pixel storage
/// comes from the test allocator. Tests use the harness to drive a present
/// rotation over real pixel storage and compare the buffers byte for byte. Each
/// buffer starts zeroed and owes its whole extent. `use` marks one buffer free
/// and the other two busy, so a test picks the buffer the next acquire returns.
/// A rotation driven this way needs no compositor and no socket, and the tests
/// pass a client pointer they leave unread.
const Rotation = struct {
    swapchain: Swapchain,
    allocator: std.mem.Allocator,

    fn init(
        allocator: std.mem.Allocator,
        client: *runtime.Client,
        width: u32,
        height: u32,
    ) !Rotation {
        const capacity = try Capacity.derive(rotation_slots, 2);
        var chain = try Swapchain.init(allocator, client, capacity);
        chain.configured = true;
        chain.width = width;
        chain.height = height;
        const byte_len = @as(usize, width) * height * 4;
        for (chain.storage.active()) |*slot| {
            const index = chain.findFreeBuffer().?;
            const mapping = try allocator.alignedAlloc(
                u8,
                .fromByteUnits(std.heap.page_size_min),
                byte_len,
            );
            @memset(mapping, 0);
            chain.installBuffer(index, .{
                .object_id = @as(u32, index) + 1,
                .mapping = mapping,
                .byte_len = byte_len,
                .width = width,
                .height = height,
                .stride = width * 4,
                .format = .xrgb8888,
            }, width, height);
            slot.* = index;
        }
        return .{ .swapchain = chain, .allocator = allocator };
    }

    fn deinit(self: *Rotation) void {
        for (self.swapchain.storage.buffers) |*slot| {
            if (slot.*) |value| self.allocator.free(value.mapping);
            slot.* = null;
        }
        self.swapchain.storage.deinit(self.allocator);
        self.* = undefined;
    }

    fn use(self: *Rotation, position: usize) Acquired {
        for (self.swapchain.storage.active(), 0..) |index, slot| {
            self.swapchain.buffer(index).busy = slot != position;
        }
        return self.swapchain.acquire().?;
    }
};

fn paintRegion(frame: []u8, region: windowing.PresentRegion, seed: u8) void {
    var row: u32 = 0;
    while (row < region.height) : (row += 1) {
        var column: u32 = 0;
        while (column < region.width) : (column += 1) {
            const offset =
                (@as(usize, region.y + row) * rotation_width + region.x + column) * 4;
            frame[offset] = seed +% @as(u8, @truncate(offset));
            frame[offset + 1] = seed *% 3 +% @as(u8, @truncate(row));
            frame[offset + 2] = seed *% 7 +% @as(u8, @truncate(column));
            frame[offset + 3] = 0xff;
        }
    }
}

fn nextRegion(random: std.Random) windowing.PresentRegion {
    const x = random.uintLessThan(u32, rotation_width);
    const y = random.uintLessThan(u32, rotation_height);
    return .{
        .x = x,
        .y = y,
        .width = 1 + random.uintLessThan(u32, rotation_width - x),
        .height = 1 + random.uintLessThan(u32, rotation_height - y),
    };
}

test "region presents leave every slot equal to the full presents they replace" {
    const allocator = std.testing.allocator;
    const client: *runtime.Client = undefined;
    var region = try Rotation.init(allocator, client, rotation_width, rotation_height);
    defer region.deinit();
    var whole = try Rotation.init(allocator, client, rotation_width, rotation_height);
    defer whole.deinit();

    var frame: [rotation_bytes]u8 = @splat(0);
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const random = prng.random();
    const schedule = [_]usize{ 0, 1, 2, 0, 0, 1, 2, 0 };
    var region_written: usize = 0;
    var whole_written: usize = 0;
    for (schedule, 0..) |position, step| {
        const dirty = nextRegion(random);
        paintRegion(&frame, dirty, @truncate(step *% 37 +% 11));
        _ = region.swapchain.markDamage(dirty);
        const partial = region.use(position);
        region_written += try partial.write(&frame);
        const full = whole.use(position);
        full.dirty.cover(rotation_width, rotation_height);
        whole_written += try full.write(&frame);
        try std.testing.expectEqualSlices(
            u8,
            full.buffer.mapping,
            partial.buffer.mapping,
        );
    }
    try std.testing.expectEqual(@as(usize, 8 * rotation_bytes), whole_written);
    try std.testing.expect(region_written < whole_written);
}

test "three disjoint region presents leave every slot able to reach the frame" {
    const allocator = std.testing.allocator;
    const client: *runtime.Client = undefined;
    var rotation = try Rotation.init(allocator, client, rotation_width, rotation_height);
    defer rotation.deinit();
    var reference = try Rotation.init(allocator, client, rotation_width, rotation_height);
    defer reference.deinit();

    var frame: [rotation_bytes]u8 = @splat(0x07);
    for (0..rotation_slots) |position| {
        const slot = rotation.use(position);
        try std.testing.expectEqual(rotation_bytes, try slot.write(&frame));
    }

    const disjoint = [_]windowing.PresentRegion{
        .{ .x = 0, .y = 0, .width = 3, .height = 2 },
        .{ .x = 10, .y = 8, .width = 4, .height = 3 },
        .{ .x = 6, .y = 1, .width = 2, .height = 2 },
    };
    for (disjoint, 0..) |dirty, step| {
        paintRegion(&frame, dirty, @truncate(step *% 53 +% 29));
        _ = rotation.swapchain.markDamage(dirty);
        const slot = rotation.use(step);
        _ = try slot.write(&frame);
    }

    const whole = reference.use(0);
    whole.dirty.cover(rotation_width, rotation_height);
    _ = try whole.write(&frame);
    for (0..rotation_slots) |position| {
        const slot = rotation.use(position);
        if (!slot.dirty.isEmpty()) _ = try slot.write(&frame);
        try std.testing.expectEqualSlices(
            u8,
            whole.buffer.mapping,
            slot.buffer.mapping,
        );
    }
}

const cell_columns: u32 = 8;
const cell_extent: u32 = 2;
const listed_round_count: usize = 6;
const listed_frame_count: usize = 48;
const OwedMask = [rotation_width * rotation_height]bool;

fn markOwed(owed: *OwedMask, region: windowing.PresentRegion) void {
    var row: u32 = 0;
    while (row < region.height) : (row += 1) {
        const start = (region.y + row) * rotation_width + region.x;
        @memset(owed[start..][0..region.width], true);
    }
}

fn drawDisjoint(
    random: std.Random,
    regions: *[damage.max_rects]windowing.PresentRegion,
) []const windowing.PresentRegion {
    comptime std.debug.assert(cell_columns * cell_extent == rotation_width);
    comptime std.debug.assert(damage.max_rects / cell_columns * cell_extent == rotation_height);
    var cells: [damage.max_rects]u8 = undefined;
    for (&cells, 0..) |*cell, index| cell.* = @intCast(index);
    random.shuffle(u8, &cells);
    const limit: usize = if (random.boolean()) 12 else damage.max_rects;
    const count = 1 + random.uintLessThan(usize, limit);
    for (regions[0..count], cells[0..count]) |*region, cell| {
        const width = 1 + random.uintLessThan(u32, cell_extent);
        const height = 1 + random.uintLessThan(u32, cell_extent);
        const x_slack = random.uintLessThan(u32, cell_extent - width + 1);
        const y_slack = random.uintLessThan(u32, cell_extent - height + 1);
        region.* = .{
            .x = (cell % cell_columns) * cell_extent + x_slack,
            .y = (cell / cell_columns) * cell_extent + y_slack,
            .width = width,
            .height = height,
        };
    }
    return regions[0..count];
}

const Differential = struct {
    listed: *Rotation,
    whole: *Rotation,
    frame: [rotation_bytes]u8 = @splat(0),
    owed: [rotation_slots]OwedMask = @splat(@splat(false)),
    collapsed: [rotation_slots]bool = @splat(false),
    written: [rotation_slots]bool = @splat(false),
    last: [rotation_slots]usize = @splat(0),
    ages: [5]bool = @splat(false),
    exact_writes: usize = 0,
    collapsed_writes: usize = 0,

    fn mark(self: *Differential, regions: []const windowing.PresentRegion, seed: u8) void {
        for (regions) |region| {
            paintRegion(&self.frame, region, seed);
            const addition = self.listed.swapchain.markDamage(region);
            for (&self.owed, &self.collapsed) |*owed, *collapsed| {
                markOwed(owed, region);
                if (addition == .collapsed) collapsed.* = true;
            }
        }
    }

    fn pick(self: *const Differential, random: std.Random, step: usize) usize {
        for (self.written, self.last, 0..) |written, last, position| {
            if (!written or step - last == 4) return position;
        }
        return random.uintLessThan(usize, rotation_slots);
    }

    fn present(self: *Differential, position: usize, step: usize) !void {
        try self.expectSlotReaches(position);
        if (self.written[position]) {
            const age = step - self.last[position];
            std.debug.assert(age >= 1);
            std.debug.assert(age <= 4);
            self.ages[age] = true;
        }
        self.written[position] = true;
        self.last[position] = step;
    }

    fn expectSlotReaches(self: *Differential, position: usize) !void {
        const partial = self.listed.use(position);
        try self.expectOwed(position, partial.dirty);
        if (!partial.dirty.isEmpty()) _ = try partial.write(&self.frame);
        self.owed[position] = @splat(false);
        self.collapsed[position] = false;
        const full = self.whole.use(position);
        full.dirty.cover(rotation_width, rotation_height);
        _ = try full.write(&self.frame);
        try std.testing.expectEqualSlices(u8, full.buffer.mapping, partial.buffer.mapping);
    }

    fn expectOwed(self: *Differential, position: usize, dirty: *const damage.Region) !void {
        if (!self.written[position]) return;
        var covered: OwedMask = @splat(false);
        for (dirty.slice()) |region| markOwed(&covered, region);
        if (self.collapsed[position]) {
            for (self.owed[position], covered) |owes, listed| {
                if (owes) try std.testing.expect(listed);
            }
            self.collapsed_writes += 1;
        } else {
            try std.testing.expectEqualSlices(bool, &self.owed[position], &covered);
            self.exact_writes += 1;
        }
    }
};

test "listed region presents match full presents at every slot age from one to four" {
    const allocator = std.testing.allocator;
    const client: *runtime.Client = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed_7e96_d4a3_0048);
    const random = prng.random();
    var ages: [5]bool = @splat(false);
    var exact_writes: usize = 0;
    var collapsed_writes: usize = 0;
    var regions: [damage.max_rects]windowing.PresentRegion = undefined;
    for (0..listed_round_count) |_| {
        var listed = try Rotation.init(allocator, client, rotation_width, rotation_height);
        defer listed.deinit();
        var whole = try Rotation.init(allocator, client, rotation_width, rotation_height);
        defer whole.deinit();
        var run = Differential{ .listed = &listed, .whole = &whole };
        for (1..listed_frame_count + 1) |step| {
            run.mark(drawDisjoint(random, &regions), @truncate(step *% 41 +% 7));
            try run.present(run.pick(random, step), step);
        }
        for (0..rotation_slots) |position| try run.expectSlotReaches(position);
        for (&ages, run.ages) |*seen, reached| seen.* = seen.* or reached;
        exact_writes += run.exact_writes;
        collapsed_writes += run.collapsed_writes;
    }
    try std.testing.expect(!ages[0]);
    for (ages[1..]) |seen| try std.testing.expect(seen);
    try std.testing.expect(exact_writes > 0);
    try std.testing.expect(collapsed_writes > 0);
}

test "a slot recreated at a new extent owes every byte of its buffer" {
    const allocator = std.testing.allocator;
    const client: *runtime.Client = undefined;
    var rotation = try Rotation.init(allocator, client, rotation_width, rotation_height);
    defer rotation.deinit();

    var frame: [rotation_bytes]u8 = @splat(0x21);
    for (0..rotation_slots) |position| {
        const slot = rotation.use(position);
        _ = try slot.write(&frame);
        try std.testing.expect(slot.dirty.isEmpty());
    }

    _ = rotation.swapchain.markDamage(.{ .x = 1, .y = 1, .width = 2, .height = 2 });
    for (rotation.swapchain.storage.active()) |index| {
        const value = rotation.swapchain.buffer(index).*;
        rotation.swapchain.storage.buffers[@intCast(index)] = null;
        rotation.swapchain.installBuffer(index, value, rotation_width, rotation_height);
        try std.testing.expectEqualSlices(
            windowing.PresentRegion,
            &.{windowing.PresentRegion.full(rotation_width, rotation_height)},
            rotation.swapchain.storage.dirty[@intCast(index)].slice(),
        );
    }
    const slot = rotation.use(0);
    try std.testing.expectEqual(rotation_bytes, try slot.write(&frame));
}

test "a slot that missed presents owes each rectangle it missed" {
    const allocator = std.testing.allocator;
    const client: *runtime.Client = undefined;
    var rotation = try Rotation.init(allocator, client, rotation_width, rotation_height);
    defer rotation.deinit();

    var frame: [rotation_bytes]u8 = @splat(0x33);
    for (0..rotation_slots) |position| {
        const slot = rotation.use(position);
        _ = try slot.write(&frame);
    }

    const first = windowing.PresentRegion{ .x = 1, .y = 1, .width = 2, .height = 2 };
    const second = windowing.PresentRegion{ .x = 9, .y = 7, .width = 3, .height = 2 };
    try std.testing.expectEqual(damage.Addition.exact, rotation.swapchain.markDamage(first));
    try std.testing.expectEqual(damage.Addition.exact, rotation.swapchain.markDamage(second));
    for (rotation.swapchain.storage.active()) |index| {
        try std.testing.expectEqualSlices(
            windowing.PresentRegion,
            &.{ first, second },
            rotation.swapchain.storage.dirty[@intCast(index)].slice(),
        );
    }
    const slot = rotation.use(0);
    const owed_bytes = (first.pixelCount() + second.pixelCount()) * 4;
    try std.testing.expectEqual(owed_bytes, try slot.write(&frame));
    try std.testing.expect(slot.dirty.isEmpty());
}

fn spacedPixel(index: usize) windowing.PresentRegion {
    std.debug.assert(index < damage.max_rects);
    return .{
        .x = @intCast(2 * (index % 8)),
        .y = @intCast(2 * (index / 8)),
        .width = 1,
        .height = 1,
    };
}

test "a slot that missed forty nine rectangles owes their bounding box" {
    const allocator = std.testing.allocator;
    const client: *runtime.Client = undefined;
    var rotation = try Rotation.init(allocator, client, rotation_width, rotation_height);
    defer rotation.deinit();
    var frame: [rotation_bytes]u8 = @splat(0x44);
    for (0..rotation_slots) |position| _ = try rotation.use(position).write(&frame);

    for (0..damage.max_rects) |index| {
        const addition = rotation.swapchain.markDamage(spacedPixel(index));
        try std.testing.expectEqual(damage.Addition.exact, addition);
    }
    const listed = rotation.use(0);
    try std.testing.expectEqual(damage.max_rects, listed.dirty.slice().len);
    try std.testing.expectEqual(damage.max_rects * 4, try listed.write(&frame));

    const corner = windowing.PresentRegion{ .x = 15, .y = 11, .width = 1, .height = 1 };
    try std.testing.expectEqual(damage.Addition.collapsed, rotation.swapchain.markDamage(corner));
    const fresh = rotation.use(0);
    try std.testing.expectEqualSlices(windowing.PresentRegion, &.{corner}, fresh.dirty.slice());
    try std.testing.expectEqual(@as(usize, 4), try fresh.write(&frame));
    const stale = rotation.use(1);
    const whole = windowing.PresentRegion.full(rotation_width, rotation_height);
    try std.testing.expectEqualSlices(windowing.PresentRegion, &.{whole}, stale.dirty.slice());
    try std.testing.expectEqual(rotation_bytes, try stale.write(&frame));
}

test "a caret and a clock at opposite corners write two rectangles per present" {
    const allocator = std.testing.allocator;
    const client: *runtime.Client = undefined;
    const width: u32 = 3840;
    const height: u32 = 2160;
    var rotation = try Rotation.init(allocator, client, width, height);
    defer rotation.deinit();
    const frame = try allocator.alloc(u8, @as(usize, width) * height * 4);
    defer allocator.free(frame);
    @memset(frame, 0x5c);
    for (0..rotation_slots) |position| _ = try rotation.use(position).write(frame);

    const caret = windowing.PresentRegion{ .x = 0, .y = 0, .width = 64, .height = 64 };
    const clock = windowing.PresentRegion{
        .x = width - 64,
        .y = height - 64,
        .width = 64,
        .height = 64,
    };
    const tile_bytes: usize = 16 * 1024;
    try std.testing.expectEqual(tile_bytes, caret.pixelCount() * 4);
    try std.testing.expectEqual(damage.Addition.exact, rotation.swapchain.markDamage(caret));
    try std.testing.expectEqual(tile_bytes, try rotation.use(0).write(frame));

    for (1..13) |step| {
        const region = if (step % 2 == 1) clock else caret;
        try std.testing.expectEqual(damage.Addition.exact, rotation.swapchain.markDamage(region));
        const slot = rotation.use(step % rotation_slots);
        const owed = slot.dirty.slice();
        try std.testing.expectEqual(@as(usize, 2), owed.len);
        try std.testing.expect(std.meta.eql(owed[0], caret) or std.meta.eql(owed[1], caret));
        try std.testing.expect(std.meta.eql(owed[0], clock) or std.meta.eql(owed[1], clock));
        try std.testing.expectEqual(2 * tile_bytes, try slot.write(frame));
    }
}
