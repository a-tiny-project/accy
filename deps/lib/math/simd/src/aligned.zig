const std = @import("std");
const builtin = @import("builtin");

pub const alignment: usize = 128;
pub const native_vector_bytes: usize = std.simd.suggestVectorLength(u8) orelse 1;

pub const Error = std.mem.Allocator.Error || error{
    AllocationSizeOverflow,
    DimensionOverflow,
    EmptyAllocation,
    IndexOutOfBounds,
    InvalidVectorBytes,
    MisalignedStorage,
    ShapeExpansion,
    StorageTooSmall,
    ZeroDimension,
};

const allocation_alignment: usize = switch (builtin.target.cpu.arch) {
    .riscv32, .riscv64 => if (std.Target.riscv.featureSetHas(
        builtin.target.cpu.features,
        .v,
    )) @max(alignment, 4096) else alignment,
    else => alignment,
};
const alias_bytes: usize = switch (builtin.target.cpu.arch) {
    .x86, .x86_64 => @max(allocation_alignment, 1024),
    else => allocation_alignment,
};
const alias_groups: usize = alias_bytes / allocation_alignment;

var next_offset = std.atomic.Value(usize).init(0);

pub fn isAligned(pointer: anytype) bool {
    return isAlignedTo(pointer, alignment);
}

pub fn isAlignedTo(pointer: anytype, byte_alignment: usize) bool {
    std.debug.assert(byte_alignment != 0);
    return @intFromPtr(pointer) % byte_alignment == 0;
}

pub fn isDescriptorAligned(comptime D: type, pointer: anytype) bool {
    const Child = switch (@typeInfo(@TypeOf(pointer))) {
        .pointer => |info| info.child,
        else => @compileError("descriptor alignment requires a pointer"),
    };
    return isAlignedTo(pointer, D.lane_count * @sizeOf(Child));
}

pub fn Allocation(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError("aligned allocations require nonzero-sized values");
    if (@alignOf(T) > allocation_alignment) {
        @compileError("value alignment exceeds the Highway allocation alignment");
    }

    return struct {
        allocation: []u8,
        values: []align(allocation_alignment) T,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, count: usize) Error!Self {
            if (count == 0) return error.EmptyAllocation;
            const payload_bytes = std.math.mul(usize, count, @sizeOf(T)) catch
                return error.AllocationSizeOverflow;
            if (payload_bytes >= std.math.maxInt(usize) / 2) {
                return error.AllocationSizeOverflow;
            }
            const offset = nextAlignedOffset();
            const prefix_bytes = std.math.add(usize, alias_bytes, offset) catch
                return error.AllocationSizeOverflow;
            const allocated_bytes = std.math.add(usize, prefix_bytes, payload_bytes) catch
                return error.AllocationSizeOverflow;
            const allocation = try allocator.alloc(u8, allocated_bytes);
            errdefer allocator.free(allocation);
            const aligned_base = std.mem.alignBackward(
                usize,
                @intFromPtr(allocation.ptr) + alias_bytes,
                alias_bytes,
            );
            const payload_address = aligned_base + offset;
            std.debug.assert(payload_address >= @intFromPtr(allocation.ptr));
            std.debug.assert(payload_address + payload_bytes <=
                @intFromPtr(allocation.ptr) + allocation.len);
            std.debug.assert(payload_address % allocation_alignment == 0);
            const payload_offset = payload_address - @intFromPtr(allocation.ptr);
            const byte_pointer: [*]align(allocation_alignment) u8 =
                @alignCast(allocation.ptr + payload_offset);
            const pointer: [*]align(allocation_alignment) T = @ptrCast(byte_pointer);
            return .{
                .allocation = allocation,
                .values = pointer[0..count],
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.allocation);
            self.* = undefined;
        }

        pub fn slice(self: *Self) []T {
            return self.values;
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.values;
        }
    };
}

pub fn Vector(comptime T: type) type {
    return struct {
        storage: ?Allocation(T) = null,
        len_value: usize = 0,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            initial: []const T,
        ) Error!Self {
            var self = try initCapacity(allocator, initial.len);
            if (initial.len != 0) {
                @memcpy(self.storage.?.values[0..initial.len], initial);
                self.len_value = initial.len;
            }
            return self;
        }

        pub fn initCapacity(
            allocator: std.mem.Allocator,
            capacity_value: usize,
        ) Error!Self {
            if (capacity_value == 0) return .{};
            return .{ .storage = try Allocation(T).init(allocator, capacity_value) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.storage) |*storage| storage.deinit(allocator);
            self.* = .{};
        }

        pub fn len(self: *const Self) usize {
            return self.len_value;
        }

        pub fn capacity(self: *const Self) usize {
            return if (self.storage) |storage| storage.values.len else 0;
        }

        pub fn items(self: *Self) []T {
            if (self.storage) |*storage| return storage.values[0..self.len_value];
            return @constCast((&[_]T{})[0..]);
        }

        pub fn constItems(self: *const Self) []const T {
            if (self.storage) |*storage| return storage.values[0..self.len_value];
            return &.{};
        }

        pub fn append(
            self: *Self,
            allocator: std.mem.Allocator,
            value: T,
        ) Error!void {
            const required = std.math.add(usize, self.len_value, 1) catch
                return error.AllocationSizeOverflow;
            try self.ensureTotalCapacity(allocator, required);
            self.storage.?.values[self.len_value] = value;
            self.len_value += 1;
        }

        pub fn appendSlice(
            self: *Self,
            allocator: std.mem.Allocator,
            values: []const T,
        ) Error!void {
            if (values.len == 0) return;
            const required = std.math.add(usize, self.len_value, values.len) catch
                return error.AllocationSizeOverflow;
            try self.ensureTotalCapacity(allocator, required);
            @memcpy(self.storage.?.values[self.len_value..required], values);
            self.len_value = required;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len_value == 0) return null;
            self.len_value -= 1;
            return self.storage.?.values[self.len_value];
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len_value = 0;
        }

        pub fn ensureTotalCapacity(
            self: *Self,
            allocator: std.mem.Allocator,
            required: usize,
        ) Error!void {
            const current_capacity = self.capacity();
            if (required <= current_capacity) return;
            const grown = std.math.mul(usize, current_capacity, 2) catch required;
            const new_capacity = @max(required, @max(@as(usize, 8), grown));
            var replacement = try Allocation(T).init(allocator, new_capacity);
            if (self.storage) |*storage| {
                @memcpy(replacement.values[0..self.len_value], storage.values[0..self.len_value]);
                storage.deinit(allocator);
            }
            self.storage = replacement;
        }
    };
}

pub fn Layout(comptime axes: usize) type {
    if (axes == 0) @compileError("aligned arrays require at least one axis");

    return struct {
        shape_value: [axes]usize,
        memory_shape_value: [axes]usize,
        sizes: [axes + 1]usize,
        memory_sizes: [axes + 1]usize,
        vector_bytes: usize,

        const Self = @This();

        pub fn init(shape_value: [axes]usize) Error!Self {
            return initFor(shape_value, native_vector_bytes);
        }

        pub fn initFor(
            shape_value: [axes]usize,
            vector_bytes: usize,
        ) Error!Self {
            if (!std.math.isPowerOfTwo(vector_bytes)) return error.InvalidVectorBytes;
            for (shape_value) |dimension| {
                if (dimension == 0) return error.ZeroDimension;
            }
            var memory_shape_value = shape_value;
            memory_shape_value[axes - 1] = try roundUp(
                memory_shape_value[axes - 1],
                vector_bytes,
            );
            return .{
                .shape_value = shape_value,
                .memory_shape_value = memory_shape_value,
                .sizes = try computeSizes(axes, shape_value),
                .memory_sizes = try computeSizes(axes, memory_shape_value),
                .vector_bytes = vector_bytes,
            };
        }

        pub fn shape(self: *const Self) [axes]usize {
            return self.shape_value;
        }

        pub fn memoryShape(self: *const Self) [axes]usize {
            return self.memory_shape_value;
        }

        pub fn len(self: *const Self) usize {
            return self.sizes[0];
        }

        pub fn memoryLen(self: *const Self) usize {
            return self.memory_sizes[0];
        }

        pub fn memoryBytes(self: *const Self, comptime T: type) Error!usize {
            return std.math.mul(usize, self.memoryLen(), @sizeOf(T)) catch
                error.AllocationSizeOverflow;
        }

        pub fn rowLen(self: *const Self) usize {
            return self.shape_value[axes - 1];
        }

        pub fn rowOffset(
            self: *const Self,
            indices: [axes - 1]usize,
        ) Error!usize {
            var offset: usize = 0;
            for (indices, 0..) |index, axis| {
                if (index >= self.shape_value[axis]) return error.IndexOutOfBounds;
                offset += self.memory_sizes[axis + 1] * index;
            }
            return offset;
        }

        pub fn truncate(self: *Self, new_shape: [axes]usize) Error!void {
            for (new_shape, self.shape_value) |new_dimension, old_dimension| {
                if (new_dimension > old_dimension) return error.ShapeExpansion;
            }
            self.shape_value = new_shape;
            self.sizes = try computeSizes(axes, new_shape);
        }
    };
}

pub fn View(comptime T: type, comptime axes: usize) type {
    return struct {
        layout: Layout(axes),
        storage: []T,

        const Self = @This();

        pub fn init(storage: []T, shape_value: [axes]usize) Error!Self {
            return initFor(storage, shape_value, native_vector_bytes);
        }

        pub fn initFor(
            storage: []T,
            shape_value: [axes]usize,
            vector_bytes: usize,
        ) Error!Self {
            if (!isAligned(storage.ptr)) return error.MisalignedStorage;
            const layout = try Layout(axes).initFor(shape_value, vector_bytes);
            if (storage.len < layout.memoryLen()) return error.StorageTooSmall;
            return .{
                .layout = layout,
                .storage = storage[0..layout.memoryLen()],
            };
        }

        pub fn row(self: *Self, indices: [axes - 1]usize) Error![]T {
            const offset = try self.layout.rowOffset(indices);
            return self.storage[offset..][0..self.layout.rowLen()];
        }

        pub fn constRow(
            self: *const Self,
            indices: [axes - 1]usize,
        ) Error![]const T {
            const offset = try self.layout.rowOffset(indices);
            return self.storage[offset..][0..self.layout.rowLen()];
        }

        pub fn truncate(self: *Self, new_shape: [axes]usize) Error!void {
            try self.layout.truncate(new_shape);
        }
    };
}

pub fn Array(comptime T: type, comptime axes: usize) type {
    return struct {
        layout: Layout(axes),
        allocation: Allocation(T),

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            shape_value: [axes]usize,
        ) Error!Self {
            return initFor(allocator, shape_value, native_vector_bytes);
        }

        pub fn initFor(
            allocator: std.mem.Allocator,
            shape_value: [axes]usize,
            vector_bytes: usize,
        ) Error!Self {
            const layout = try Layout(axes).initFor(shape_value, vector_bytes);
            _ = try layout.memoryBytes(T);
            const allocation = try Allocation(T).init(allocator, layout.memoryLen());
            @memset(allocation.values, std.mem.zeroes(T));
            return .{
                .layout = layout,
                .allocation = allocation,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.allocation.deinit(allocator);
            self.* = undefined;
        }

        pub fn row(self: *Self, indices: [axes - 1]usize) Error![]T {
            const offset = try self.layout.rowOffset(indices);
            return self.allocation.values[offset..][0..self.layout.rowLen()];
        }

        pub fn constRow(
            self: *const Self,
            indices: [axes - 1]usize,
        ) Error![]const T {
            const offset = try self.layout.rowOffset(indices);
            return self.allocation.values[offset..][0..self.layout.rowLen()];
        }

        pub fn shape(self: *const Self) [axes]usize {
            return self.layout.shape();
        }

        pub fn memoryShape(self: *const Self) [axes]usize {
            return self.layout.memoryShape();
        }

        pub fn len(self: *const Self) usize {
            return self.layout.len();
        }

        pub fn memoryLen(self: *const Self) usize {
            return self.layout.memoryLen();
        }

        pub fn data(self: *Self) []T {
            return self.allocation.values;
        }

        pub fn constData(self: *const Self) []const T {
            return self.allocation.values;
        }

        pub fn truncate(self: *Self, new_shape: [axes]usize) Error!void {
            try self.layout.truncate(new_shape);
        }
    };
}

fn nextAlignedOffset() usize {
    const ordinal = next_offset.fetchAdd(1, .monotonic);
    var offset = allocation_alignment * (ordinal % alias_groups);
    if (offset == 0) offset = allocation_alignment;
    return offset;
}

fn roundUp(value: usize, multiple: usize) Error!usize {
    const adjusted = std.math.add(usize, value, multiple - 1) catch
        return error.DimensionOverflow;
    return adjusted & ~(multiple - 1);
}

fn computeSizes(comptime axes: usize, shape_value: [axes]usize) Error![axes + 1]usize {
    var sizes: [axes + 1]usize = undefined;
    sizes[axes] = 1;
    var axis = axes;
    while (axis != 0) {
        axis -= 1;
        sizes[axis] = std.math.mul(usize, sizes[axis + 1], shape_value[axis]) catch
            return error.DimensionOverflow;
    }
    return sizes;
}

fn shiftCount(value: usize) usize {
    return if (value <= 1) 0 else 1 + shiftCount(value / 2);
}

fn checkArrayInitFailures(allocator: std.mem.Allocator) !void {
    var array = try Array(f32, 3).init(allocator, .{ 3, 5, 7 });
    array.deinit(allocator);
}

test "Highway aligned allocation preserves alignment ownership and payload" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var allocation = try Allocation(u8).init(counting.allocator(), 7777);
    defer allocation.deinit(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try std.testing.expect(isAligned(allocation.values.ptr));
    var digest: usize = 0;
    for (allocation.values, 0..) |*value, index| {
        value.* = @intCast(index & 0x7f);
        if (index != 0) digest +%= @as(usize, value.*) * allocation.values[index - 1];
    }
    try std.testing.expect(digest != 0);
}

test "Highway descriptor alignment uses active lanes and pointer element size" {
    const D = @import("tag.zig").FixedTag(u32, 8);
    var storage: [9]u32 align(32) = @splat(0);
    try std.testing.expect(isDescriptorAligned(D, &storage[0]));
    try std.testing.expect(!isDescriptorAligned(D, &storage[1]));
}

test "Highway aligned allocation cycles x86 alias groups" {
    var counts: [alias_groups]usize = @splat(0);
    for (0..alias_groups) |_| {
        var allocation = try Allocation(u8).init(std.testing.allocator, 1);
        const group = (@intFromPtr(allocation.values.ptr) % alias_bytes) /
            allocation_alignment;
        counts[group] += 1;
        allocation.deinit(std.testing.allocator);
    }
    if (comptime alias_groups == 1) {
        try std.testing.expectEqual(@as(usize, 1), counts[0]);
    } else {
        try std.testing.expectEqual(@as(usize, 0), counts[0]);
        try std.testing.expectEqual(@as(usize, 2), counts[1]);
        for (counts[2..]) |count| try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "Highway typed allocation rejects every multiplication overflow" {
    const maximum = std.math.maxInt(usize);
    const most_significant = (maximum >> 1) + 1;
    try std.testing.expectError(
        error.AllocationSizeOverflow,
        Allocation(u32).init(std.testing.allocator, maximum / 2),
    );
    try std.testing.expectError(
        error.AllocationSizeOverflow,
        Allocation(u32).init(std.testing.allocator, maximum / 3),
    );
    try std.testing.expectError(
        error.AllocationSizeOverflow,
        Allocation([5]u8).init(std.testing.allocator, maximum / 4),
    );
    try std.testing.expectError(
        error.AllocationSizeOverflow,
        Allocation(u16).init(std.testing.allocator, most_significant),
    );
    try std.testing.expectError(
        error.AllocationSizeOverflow,
        Allocation(f64).init(std.testing.allocator, most_significant + 1),
    );
    try std.testing.expectError(
        error.AllocationSizeOverflow,
        Allocation([10]u8).init(std.testing.allocator, most_significant / 4),
    );
    try std.testing.expectEqual(@as(usize, 0), shiftCount(1));
    try std.testing.expectEqual(@as(usize, 1), shiftCount(2));
    try std.testing.expectEqual(@as(usize, 3), shiftCount(8));
}

test "Highway aligned arrays zero rows and retain padded geometry" {
    var one = try Array(f32, 1).init(std.testing.allocator, .{4});
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &@as([4]f32, @splat(0)), try one.constRow(.{}));
    (try one.row(.{}))[2] = 3.4;
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 3.4, 0 }, try one.constRow(.{}));

    var two = try Array(f32, 2).init(std.testing.allocator, .{ 2, 3 });
    defer two.deinit(std.testing.allocator);
    @memcpy(try two.row(.{0}), &[_]f32{ 1, 2, 3 });
    @memcpy(try two.row(.{1}), &[_]f32{ 4, 5, 6 });
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, try two.constRow(.{0}));
    try std.testing.expectEqualSlices(f32, &.{ 4, 5, 6 }, try two.constRow(.{1}));
    try std.testing.expectEqual(@as(usize, 6), two.len());
    try std.testing.expectEqual([2]usize{ 2, 3 }, two.shape());
    try std.testing.expectEqual([2]usize{ 2, native_vector_bytes }, two.memoryShape());
}

test "pinned Highway aligned array oracle matches dispatched geometry" {
    var array = try Array(f32, 2).initFor(std.testing.allocator, .{ 2, 3 }, 64);
    defer array.deinit(std.testing.allocator);
    try std.testing.expectEqual([2]usize{ 2, 3 }, array.shape());
    try std.testing.expectEqual([2]usize{ 2, 64 }, array.memoryShape());
    try std.testing.expectEqual(@as(usize, 6), array.len());
    try std.testing.expectEqual(@as(usize, 128), array.memoryLen());
    try std.testing.expect(isAligned((try array.row(.{0})).ptr));
    try std.testing.expect(isAligned((try array.row(.{1})).ptr));
    @memcpy(try array.row(.{0}), &[_]f32{ 1, 2, 3 });
    @memcpy(try array.row(.{1}), &[_]f32{ 4, 5, 6 });
    var digest: f64 = 0;
    for (0..2) |row_index| {
        for (try array.constRow(.{row_index})) |value| digest += value;
    }
    try array.truncate(.{ 1, 2 });
    try std.testing.expectEqual(@as(f64, 21), digest);
    try std.testing.expectEqual([2]usize{ 1, 2 }, array.shape());
    try std.testing.expectEqual([2]usize{ 2, 64 }, array.memoryShape());
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, try array.constRow(.{0}));
}

test "Highway aligned array rows retain native vector alignment" {
    var array = try Array(f32, 4).init(std.testing.allocator, .{ 3, 3, 3, 3 });
    defer array.deinit(std.testing.allocator);
    for (0..3) |d0| {
        for (0..3) |d1| {
            for (0..3) |d2| {
                const row = try array.row(.{ d0, d1, d2 });
                try std.testing.expect(isAlignedTo(row.ptr, native_vector_bytes));
            }
        }
    }
}

test "Highway aligned array truncation preserves memory layout and values" {
    var array = try Array(usize, 4).init(std.testing.allocator, .{ 8, 8, 8, 8 });
    defer array.deinit(std.testing.allocator);
    const memory_shape = array.memoryShape();
    for (0..8) |d0| {
        for (0..8) |d1| {
            for (0..8) |d2| {
                const row = try array.row(.{ d0, d1, d2 });
                for (row, 0..) |*value, d3| {
                    value.* = d0 * 8 * 8 * 8 + d1 * 8 * 8 + d2 * 8 + d3;
                }
            }
        }
    }
    try array.truncate(.{ 7, 7, 7, 7 });
    try array.truncate(.{ 6, 5, 4, 3 });
    try std.testing.expectEqual([4]usize{ 6, 5, 4, 3 }, array.shape());
    try std.testing.expectEqual(memory_shape, array.memoryShape());
    for (0..6) |d0| {
        for (0..5) |d1| {
            for (0..4) |d2| {
                const row = try array.constRow(.{ d0, d1, d2 });
                for (row, 0..) |value, d3| {
                    try std.testing.expectEqual(
                        d0 * 8 * 8 * 8 + d1 * 8 * 8 + d2 * 8 + d3,
                        value,
                    );
                }
            }
        }
    }
    try std.testing.expectError(error.ShapeExpansion, array.truncate(.{ 7, 5, 4, 3 }));
}

test "Highway aligned vector growth preserves elements and capacity" {
    var empty = try Vector(usize).initCapacity(std.testing.allocator, 0);
    defer empty.deinit(std.testing.allocator);
    try empty.appendSlice(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqual(@as(usize, 0), empty.capacity());

    var vector = try Vector(usize).init(std.testing.allocator, &.{ 0, 1, 2, 3, 4 });
    defer vector.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), vector.pop().?);
    try vector.appendSlice(std.testing.allocator, &.{ 4, 5 });
    const initial_capacity = vector.capacity();
    var value = vector.len();
    while (value < initial_capacity + 10) : (value += 1) {
        try vector.append(std.testing.allocator, value);
    }
    try std.testing.expect(vector.capacity() > initial_capacity);
    for (vector.constItems(), 0..) |item, index| try std.testing.expectEqual(index, item);
    vector.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), vector.len());
    try std.testing.expect(vector.capacity() > 0);
}

test "aligned owners reject invalid geometry before mutation" {
    try std.testing.expectError(
        error.EmptyAllocation,
        Allocation(u8).init(std.testing.allocator, 0),
    );
    try std.testing.expectError(
        error.ZeroDimension,
        Layout(2).initFor(.{ 2, 0 }, 16),
    );
    try std.testing.expectError(
        error.InvalidVectorBytes,
        Layout(2).initFor(.{ 2, 3 }, 3),
    );
    try std.testing.expectError(
        error.DimensionOverflow,
        Layout(1).initFor(.{std.math.maxInt(usize)}, 2),
    );
    try std.testing.expectError(
        error.DimensionOverflow,
        Layout(2).initFor(.{ std.math.maxInt(usize), 2 }, 1),
    );
    var storage: [260]u8 align(alignment) = undefined;
    try std.testing.expectError(
        error.MisalignedStorage,
        View(u8, 2).initFor(storage[1..], .{ 2, 3 }, 4),
    );
    try std.testing.expectError(
        error.StorageTooSmall,
        View(u8, 2).initFor(storage[0..4], .{ 2, 3 }, 4),
    );
    var view = try View(u8, 2).initFor(&storage, .{ 2, 3 }, 4);
    try std.testing.expectError(error.IndexOutOfBounds, view.row(.{2}));
    try std.testing.expectError(error.ShapeExpansion, view.truncate(.{ 3, 3 }));
}

test "aligned vector growth failure preserves the original owner" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    var vector = try Vector(u32).init(failing.allocator(), &.{ 1, 2, 3, 4, 5 });
    defer vector.deinit(failing.allocator());
    const original_pointer = vector.storage.?.values.ptr;
    const original_capacity = vector.capacity();
    try std.testing.expectError(error.OutOfMemory, vector.append(failing.allocator(), 6));
    try std.testing.expectEqual(original_pointer, vector.storage.?.values.ptr);
    try std.testing.expectEqual(original_capacity, vector.capacity());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5 }, vector.constItems());
}

test "Highway aligned array allocation failures are transactional" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkArrayInitFailures,
        .{},
    );
}
