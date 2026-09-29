const std = @import("std");
const simd = @import("../root.zig");
const tag = simd.tag;
const highway = simd.aligned;

pub const vector_size: usize = tag.ScalableTag(u8).byte_count;
pub const storage_alignment: usize = @max(highway.alignment, vector_size);

pub const GeometryError = error{
    AliasedPlanes,
    AllocationSizeOverflow,
    BufferTooSmall,
    DimensionTooLarge,
    InvalidComponentSize,
    InsufficientRowPadding,
    InvalidShrink,
    InvalidStride,
    InvalidVectorSize,
    MisalignedStorage,
    PlaneSizeMismatch,
    PlaneStrideMismatch,
    RowSizeOverflow,
};
pub const Error = std.mem.Allocator.Error || GeometryError;

const Padding = enum {
    round_up,
    unaligned,
};

const Packing = enum {
    none,
    owned,
};

pub fn vectorSize() usize {
    return vector_size;
}

pub fn bytesPerRow(xsize: usize, component_size: usize) GeometryError!usize {
    return bytesPerRowFor(xsize, component_size, vector_size);
}

pub fn bytesPerRowFor(
    xsize: usize,
    component_size: usize,
    selected_vector_size: usize,
) GeometryError!usize {
    try validateGeometry(component_size, selected_vector_size);
    var valid_bytes = std.math.mul(usize, xsize, component_size) catch
        return error.RowSizeOverflow;
    if (selected_vector_size != 1) {
        valid_bytes = std.math.add(
            usize,
            valid_bytes,
            selected_vector_size - component_size,
        ) catch return error.RowSizeOverflow;
    }
    const alignment = @max(highway.alignment, selected_vector_size);
    var stride = try roundUp(valid_bytes, alignment);
    if (stride % highway.alignment == 0) {
        stride = std.math.add(usize, stride, alignment) catch
            return error.RowSizeOverflow;
    }
    std.debug.assert(stride % alignment == 0);
    return stride;
}

pub fn Image(comptime T: type) type {
    validateComponent(T);
    return struct {
        xsize_value: u32,
        ysize_value: u32,
        bytes_per_row_value: usize,
        storage: []u8,
        owned: bool,

        const Self = @This();

        pub fn empty() Self {
            return zeroDimensions(0, 0);
        }

        fn zeroDimensions(width: usize, height: usize) Self {
            return .{
                .xsize_value = @intCast(width),
                .ysize_value = @intCast(height),
                .bytes_per_row_value = 0,
                .storage = &.{},
                .owned = false,
            };
        }

        pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) Error!Self {
            try validateDimensions(width, height);
            if (width == 0 or height == 0) return zeroDimensions(width, height);
            const stride = try bytesPerRowFor(width, @sizeOf(T), vector_size);
            const allocation_size = std.math.mul(usize, stride, height) catch
                return error.AllocationSizeOverflow;
            const storage = try allocator.alignedAlloc(
                u8,
                .fromByteUnits(storage_alignment),
                allocation_size,
            );
            var result = Self{
                .xsize_value = @intCast(width),
                .ysize_value = @intCast(height),
                .bytes_per_row_value = stride,
                .storage = storage,
                .owned = true,
            };
            result.initializePadding(.round_up) catch |err| {
                allocator.free(storage);
                return err;
            };
            return result;
        }

        pub fn initBorrowed(
            width: usize,
            height: usize,
            stride: usize,
            storage: []u8,
        ) GeometryError!Self {
            try validateDimensions(width, height);
            if (width == 0 or height == 0) {
                if (stride != 0) return error.InvalidStride;
                return zeroDimensions(width, height);
            }
            if (stride % vector_size != 0 or stride % @alignOf(T) != 0) {
                return error.InvalidStride;
            }
            const valid_bytes = std.math.mul(usize, width, @sizeOf(T)) catch
                return error.RowSizeOverflow;
            if (stride < valid_bytes) return error.InvalidStride;
            const required = std.math.mul(usize, stride, height) catch
                return error.AllocationSizeOverflow;
            if (storage.len < required) return error.BufferTooSmall;
            if (@intFromPtr(storage.ptr) % @max(vector_size, @alignOf(T)) != 0) {
                return error.MisalignedStorage;
            }
            return .{
                .xsize_value = @intCast(width),
                .ysize_value = @intCast(height),
                .bytes_per_row_value = stride,
                .storage = storage[0..required],
                .owned = false,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.owned) {
                std.debug.assert(self.storage.len != 0);
                const aligned: []align(storage_alignment) u8 = @alignCast(self.storage);
                allocator.free(aligned);
            }
            self.* = empty();
        }

        pub fn swap(self: *Self, other: *Self) void {
            std.mem.swap(Self, self, other);
        }

        pub fn shrinkTo(self: *Self, width: usize, height: usize) GeometryError!void {
            if (width > self.xsize_value or height > self.ysize_value) {
                return error.InvalidShrink;
            }
            self.xsize_value = @intCast(width);
            self.ysize_value = @intCast(height);
        }

        pub fn initializePaddingForUnalignedAccesses(self: *Self) GeometryError!void {
            try self.initializePadding(.unaligned);
        }

        pub fn xsize(self: *const Self) usize {
            return self.xsize_value;
        }

        pub fn ysize(self: *const Self) usize {
            return self.ysize_value;
        }

        pub fn bytesPerRow(self: *const Self) usize {
            return self.bytes_per_row_value;
        }

        pub fn pixelsPerRow(self: *const Self) usize {
            return self.bytes_per_row_value / @sizeOf(T);
        }

        pub fn bytes(self: *Self) []u8 {
            return self.storage;
        }

        pub fn constBytes(self: *const Self) []const u8 {
            return self.storage;
        }

        pub fn constRow(self: *const Self, y: usize) []const T {
            std.debug.assert(y < self.ysize_value);
            if (self.bytes_per_row_value == 0) return &.{};
            const begin = y * self.bytes_per_row_value;
            const row = self.storage[begin..][0..self.bytes_per_row_value];
            const ptr: [*]const T = @ptrCast(@alignCast(row.ptr));
            return ptr[0..self.pixelsPerRow()];
        }

        pub fn mutableRow(self: *const Self, y: usize) []T {
            std.debug.assert(y < self.ysize_value);
            if (self.bytes_per_row_value == 0) return &.{};
            const begin = y * self.bytes_per_row_value;
            const row = self.storage[begin..][0..self.bytes_per_row_value];
            const ptr: [*]T = @ptrCast(@alignCast(row.ptr));
            return ptr[0..self.pixelsPerRow()];
        }

        fn initializePadding(self: *Self, mode: Padding) GeometryError!void {
            if (self.xsize_value == 0 or self.ysize_value == 0 or vector_size == 1) return;
            const valid_bytes = std.math.mul(
                usize,
                self.xsize_value,
                @sizeOf(T),
            ) catch return error.RowSizeOverflow;
            const initialize_size = switch (mode) {
                .round_up => try roundUp(valid_bytes, vector_size),
                .unaligned => std.math.add(
                    usize,
                    valid_bytes,
                    vector_size - @sizeOf(T),
                ) catch return error.RowSizeOverflow,
            };
            if (initialize_size > self.bytes_per_row_value) {
                return error.InsufficientRowPadding;
            }
            for (0..self.ysize_value) |y| {
                const begin = y * self.bytes_per_row_value + valid_bytes;
                @memset(self.storage[begin..][0 .. initialize_size - valid_bytes], 0);
            }
        }
    };
}

pub const ImageF = Image(f32);

pub fn Image3(comptime T: type) type {
    const ImageT = Image(T);
    return struct {
        planes: [3]ImageT,
        packed_storage: []u8,
        packing: Packing,

        const Self = @This();
        pub const num_planes: usize = 3;

        pub fn empty() Self {
            return .{
                .planes = .{ ImageT.empty(), ImageT.empty(), ImageT.empty() },
                .packed_storage = &.{},
                .packing = .none,
            };
        }

        pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) Error!Self {
            try validateDimensions(width, height);
            if (width == 0 or height == 0) {
                return .{
                    .planes = .{
                        ImageT.zeroDimensions(width, height),
                        ImageT.zeroDimensions(width, height),
                        ImageT.zeroDimensions(width, height),
                    },
                    .packed_storage = &.{},
                    .packing = .none,
                };
            }
            const stride = try bytesPerRowFor(width, @sizeOf(T), vector_size);
            const plane_size = std.math.mul(usize, stride, height) catch
                return error.AllocationSizeOverflow;
            const allocation_size = std.math.mul(usize, plane_size, num_planes) catch
                return error.AllocationSizeOverflow;
            const storage = try allocator.alignedAlloc(
                u8,
                .fromByteUnits(storage_alignment),
                allocation_size,
            );
            errdefer allocator.free(storage);
            var result = empty();
            result.packed_storage = storage;
            result.packing = .owned;
            for (&result.planes, 0..) |*current_plane, index| {
                const begin = index * plane_size;
                current_plane.* = try ImageT.initBorrowed(
                    width,
                    height,
                    stride,
                    storage[begin..][0..plane_size],
                );
                try current_plane.initializePadding(.round_up);
            }
            return result;
        }

        pub fn initBorrowed(
            width: usize,
            height: usize,
            stride: usize,
            buffers: [num_planes][]u8,
        ) GeometryError!Self {
            var result = empty();
            for (&result.planes, buffers) |*current_plane, buffer| {
                current_plane.* = try ImageT.initBorrowed(width, height, stride, buffer);
            }
            return result;
        }

        pub fn initPlanes(
            plane0: *ImageT,
            plane1: *ImageT,
            plane2: *ImageT,
        ) GeometryError!Self {
            if (plane0 == plane1 or plane0 == plane2 or plane1 == plane2) {
                return error.AliasedPlanes;
            }
            if (!sameSize(plane0, plane1) or !sameSize(plane0, plane2)) {
                return error.PlaneSizeMismatch;
            }
            if (plane0.bytesPerRow() != plane1.bytesPerRow() or
                plane0.bytesPerRow() != plane2.bytesPerRow())
            {
                return error.PlaneStrideMismatch;
            }
            const result = Self{
                .planes = .{ plane0.*, plane1.*, plane2.* },
                .packed_storage = &.{},
                .packing = .none,
            };
            plane0.* = ImageT.empty();
            plane1.* = ImageT.empty();
            plane2.* = ImageT.empty();
            return result;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.packing) {
                .owned => {
                    std.debug.assert(self.packed_storage.len != 0);
                    const aligned: []align(storage_alignment) u8 = @alignCast(self.packed_storage);
                    allocator.free(aligned);
                },
                .none => for (&self.planes) |*current_plane| current_plane.deinit(allocator),
            }
            self.* = empty();
        }

        pub fn swap(self: *Self, other: *Self) void {
            std.mem.swap(Self, self, other);
        }

        pub fn shrinkTo(self: *Self, width: usize, height: usize) GeometryError!void {
            if (width > self.xsize() or height > self.ysize()) {
                return error.InvalidShrink;
            }
            for (&self.planes) |*current_plane| try current_plane.shrinkTo(width, height);
        }

        pub fn xsize(self: *const Self) usize {
            return self.planes[0].xsize();
        }

        pub fn ysize(self: *const Self) usize {
            return self.planes[0].ysize();
        }

        pub fn bytesPerRow(self: *const Self) usize {
            return self.planes[0].bytesPerRow();
        }

        pub fn pixelsPerRow(self: *const Self) usize {
            return self.planes[0].pixelsPerRow();
        }

        pub fn plane(self: *const Self, index: usize) *const ImageT {
            std.debug.assert(index < num_planes);
            return &self.planes[index];
        }

        pub fn constPlaneRow(self: *const Self, component: usize, y: usize) []const T {
            std.debug.assert(component < num_planes);
            return self.planes[component].constRow(y);
        }

        pub fn mutablePlaneRow(self: *const Self, component: usize, y: usize) []T {
            std.debug.assert(component < num_planes);
            return self.planes[component].mutableRow(y);
        }
    };
}

pub const Image3F = Image3(f32);

pub const Rect = struct {
    x0_value: usize,
    y0_value: usize,
    xsize_value: usize,
    ysize_value: usize,

    pub fn empty() Rect {
        return init(0, 0, 0, 0);
    }

    pub fn init(xbegin: usize, ybegin: usize, width: usize, height: usize) Rect {
        return .{
            .x0_value = xbegin,
            .y0_value = ybegin,
            .xsize_value = width,
            .ysize_value = height,
        };
    }

    pub fn initClamped(
        xbegin: usize,
        ybegin: usize,
        xsize_max: usize,
        ysize_max: usize,
        xend: usize,
        yend: usize,
    ) Rect {
        return .{
            .x0_value = xbegin,
            .y0_value = ybegin,
            .xsize_value = clampedSize(xbegin, xsize_max, xend),
            .ysize_value = clampedSize(ybegin, ysize_max, yend),
        };
    }

    pub fn fromImage(image: anytype) Rect {
        return init(0, 0, image.xsize(), image.ysize());
    }

    pub fn subrect(
        self: Rect,
        xbegin: usize,
        ybegin: usize,
        xsize_max: usize,
        ysize_max: usize,
    ) GeometryError!Rect {
        const absolute_x = std.math.add(usize, self.x0_value, xbegin) catch
            return error.RowSizeOverflow;
        const absolute_y = std.math.add(usize, self.y0_value, ybegin) catch
            return error.RowSizeOverflow;
        const xend = std.math.add(usize, self.x0_value, self.xsize_value) catch
            return error.RowSizeOverflow;
        const yend = std.math.add(usize, self.y0_value, self.ysize_value) catch
            return error.RowSizeOverflow;
        return initClamped(
            absolute_x,
            absolute_y,
            xsize_max,
            ysize_max,
            xend,
            yend,
        );
    }

    pub fn isInside(self: Rect, image: anytype) bool {
        const xend = std.math.add(usize, self.x0_value, self.xsize_value) catch
            return false;
        const yend = std.math.add(usize, self.y0_value, self.ysize_value) catch
            return false;
        return xend <= image.xsize() and yend <= image.ysize();
    }

    pub fn constRow(self: Rect, comptime T: type, image: *const Image(T), y: usize) []const T {
        std.debug.assert(self.isInside(image));
        std.debug.assert(y < self.ysize_value);
        return image.constRow(y + self.y0_value)[self.x0_value..];
    }

    pub fn mutableRow(self: Rect, comptime T: type, image: *const Image(T), y: usize) []T {
        std.debug.assert(self.isInside(image));
        std.debug.assert(y < self.ysize_value);
        return image.mutableRow(y + self.y0_value)[self.x0_value..];
    }

    pub fn constPlaneRow(
        self: Rect,
        comptime T: type,
        image: *const Image3(T),
        component: usize,
        y: usize,
    ) []const T {
        std.debug.assert(self.isInside(image));
        std.debug.assert(y < self.ysize_value);
        return image.constPlaneRow(component, y + self.y0_value)[self.x0_value..];
    }

    pub fn mutablePlaneRow(
        self: Rect,
        comptime T: type,
        image: *const Image3(T),
        component: usize,
        y: usize,
    ) []T {
        std.debug.assert(self.isInside(image));
        std.debug.assert(y < self.ysize_value);
        return image.mutablePlaneRow(component, y + self.y0_value)[self.x0_value..];
    }

    pub fn x0(self: Rect) usize {
        return self.x0_value;
    }

    pub fn y0(self: Rect) usize {
        return self.y0_value;
    }

    pub fn xsize(self: Rect) usize {
        return self.xsize_value;
    }

    pub fn ysize(self: Rect) usize {
        return self.ysize_value;
    }
};

pub fn sameSize(first: anytype, second: anytype) bool {
    return first.xsize() == second.xsize() and first.ysize() == second.ysize();
}

pub fn mirror(coord: i64, size: usize) usize {
    std.debug.assert(size != 0);
    std.debug.assert(size <= std.math.maxInt(i64));
    const size_u64: u64 = @intCast(size);
    const period = 2 * size_u64;
    const phase = if (coord >= 0)
        @as(u64, @intCast(coord)) % period
    else blk: {
        const bits: u64 = @bitCast(coord);
        const remainder = (0 -% bits) % period;
        break :blk if (remainder == 0) 0 else period - remainder;
    };
    if (phase < size_u64) return @intCast(phase);
    return @intCast(period - 1 - phase);
}

pub const WrapMirror = struct {
    pub fn call(_: WrapMirror, coord: i64, size: usize) usize {
        return mirror(coord, size);
    }
};

pub const WrapUnchanged = struct {
    pub fn call(_: WrapUnchanged, coord: i64, size: usize) usize {
        std.debug.assert(coord >= 0);
        std.debug.assert(coord < size);
        return @intCast(coord);
    }
};

pub const WrapRowMirror = struct {
    first_row: [*]const f32,
    last_row: [*]const f32,

    pub fn init(image: anytype, ysize: usize) WrapRowMirror {
        std.debug.assert(ysize != 0);
        return .{
            .first_row = image.constRow(0).ptr,
            .last_row = image.constRow(ysize - 1).ptr,
        };
    }

    pub fn call(self: WrapRowMirror, row: [*]const f32, stride: i64) [*]const f32 {
        std.debug.assert(stride > 0);
        const first = @intFromPtr(self.first_row);
        const last = @intFromPtr(self.last_row);
        const address = @intFromPtr(row);
        const stride_elements: usize = @intCast(stride);
        if (address < first) {
            const distance_bytes = first - address;
            std.debug.assert(distance_bytes % @sizeOf(f32) == 0);
            const distance = distance_bytes / @sizeOf(f32);
            std.debug.assert(distance >= stride_elements);
            return self.first_row + (distance - stride_elements);
        }
        if (address > last) {
            const distance_bytes = address - last;
            std.debug.assert(distance_bytes % @sizeOf(f32) == 0);
            const distance = distance_bytes / @sizeOf(f32);
            std.debug.assert(distance >= stride_elements);
            return self.last_row - (distance - stride_elements);
        }
        return row;
    }
};

pub const WrapRowUnchanged = struct {
    pub fn call(_: WrapRowUnchanged, row: [*]const f32, _: i64) [*]const f32 {
        return row;
    }
};

fn validateComponent(comptime T: type) void {
    if (@sizeOf(T) != 1 and @sizeOf(T) != 2 and @sizeOf(T) != 4 and @sizeOf(T) != 8) {
        @compileError("Highway images require 1/2/4/8-byte component types");
    }
    if (@typeInfo(T) == .pointer or @typeInfo(T) == .optional) {
        @compileError("Highway images require plain component values");
    }
}

fn validateGeometry(component_size: usize, selected_vector_size: usize) GeometryError!void {
    if (component_size != 1 and component_size != 2 and
        component_size != 4 and component_size != 8)
    {
        return error.InvalidComponentSize;
    }
    if (!std.math.isPowerOfTwo(selected_vector_size)) return error.InvalidVectorSize;
    if (selected_vector_size != 1 and selected_vector_size < component_size) {
        return error.InvalidVectorSize;
    }
}

fn validateDimensions(xsize: usize, ysize: usize) GeometryError!void {
    if (xsize > std.math.maxInt(u32) or ysize > std.math.maxInt(u32)) {
        return error.DimensionTooLarge;
    }
}

fn roundUp(value: usize, alignment: usize) GeometryError!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    const biased = std.math.add(usize, value, mask) catch return error.RowSizeOverflow;
    return biased & ~mask;
}

fn clampedSize(begin: usize, size_max: usize, end: usize) usize {
    if (end <= begin) return 0;
    return @min(size_max, end - begin);
}
