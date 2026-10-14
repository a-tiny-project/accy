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
