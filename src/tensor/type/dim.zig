const std = @import("std");
const gpu_abi = @import("gpu_abi");

pub const DType = gpu_abi.DType;

pub const generated_prefix: u8 = '#';

pub const Error = error{
    InvalidDimension,
    ShapeElementOverflow,
    ShapeByteOverflow,
    ShapeMismatch,
    DTypeMismatch,
    RankMismatch,
    AxisOutOfRange,
    AxisNotFound,
    AxisNameEmpty,
    AxisNameReserved,
    AxisExtentMismatch,
    DuplicateAxis,
    InvalidPermutation,
    ReshapeElementMismatch,
    BroadcastRankMismatch,
    BroadcastDimensionMismatch,
    ContractDTypeMismatch,
    SplitExtentMismatch,
    MergeExtentOverflow,
    ReduceInitNotScalar,
    PayloadLengthMismatch,
};

pub const Dim = struct {
    name: []const u8,
    extent: i64,
};

pub const Spec = struct {
    dtype: DType,
    dims: []const Dim,

    pub fn init(dtype: DType, dims: []const Dim) Spec {
        return .{ .dtype = dtype, .dims = dims };
    }
};

pub const Type = struct {
    dtype: DType,
    dims: []const Dim,

    pub fn init(allocator: std.mem.Allocator, dtype: DType, dims: []const Dim) !Type {
        return .{
            .dtype = dtype,
            .dims = try copyDims(allocator, dims),
        };
    }

    pub fn fromSpec(allocator: std.mem.Allocator, value: Spec) !Type {
        return init(allocator, value.dtype, value.dims);
    }

    pub fn scalar(dtype: DType) Type {
        return .{ .dtype = dtype, .dims = &.{} };
    }

    pub fn eql(self: Type, other: Type) bool {
        return self.dtype == other.dtype and sameDims(self.dims, other.dims);
    }

    pub fn rank(self: Type) usize {
        return self.dims.len;
    }

    pub fn extent(self: Type, index: usize) i64 {
        return self.dims[index].extent;
    }

    pub fn find(self: Type, name: []const u8) ?usize {
        return findDim(self.dims, name);
    }

    pub fn elementCount(self: Type) !usize {
        return dimsElementCount(self.dims);
    }

    pub fn byteCount(self: Type) !usize {
        return std.math.mul(usize, try self.elementCount(), self.dtype.sizeOf()) catch error.ShapeByteOverflow;
    }
};

pub fn spec(comptime dtype: DType, comptime dims_struct: anytype) Spec {
    const dims_array = comptime blk: {
        var array: [dimCount(@TypeOf(dims_struct))]Dim = undefined;
        fillDims(dims_struct, &array);
        break :blk array;
    };
    return .{ .dtype = dtype, .dims = &dims_array };
}

pub fn specDims(dtype: DType, dims: []const Dim) Spec {
    return Spec.init(dtype, dims);
}

pub fn dimCount(comptime Dims: type) usize {
    const info = @typeInfo(Dims);
    if (info != .@"struct") {
        @compileError("tensor dims must be a struct literal mapping axis names to extents");
    }
    if (info.@"struct".field_names.len == 0) return 0;
    if (info.@"struct".is_tuple) {
        @compileError("tensor dims must be a struct literal mapping axis names to extents");
    }
    return info.@"struct".field_names.len;
}

pub fn fillDims(dims_struct: anytype, buffer: *[dimCount(@TypeOf(dims_struct))]Dim) void {
    const field_names = @typeInfo(@TypeOf(dims_struct)).@"struct".field_names;
    inline for (field_names, 0..) |field_name, index| {
        buffer[index] = .{
            .name = field_name,
            .extent = @intCast(@field(dims_struct, field_name)),
        };
    }
}

pub fn axisCount(comptime axes: anytype) usize {
    const Axes = @TypeOf(axes);
    return switch (@typeInfo(Axes)) {
        .enum_literal => 1,
        .@"struct" => |info| blk: {
            if (!info.is_tuple) {
                @compileError("tensor axes must be an enum literal or a tuple of enum literals");
            }
            break :blk info.field_names.len;
        },
        else => @compileError("tensor axes must be an enum literal or a tuple of enum literals"),
    };
}

pub fn axisNames(comptime axes: anytype) *const [axisCount(axes)][]const u8 {
    comptime var names: [axisCount(axes)][]const u8 = undefined;
    switch (@typeInfo(@TypeOf(axes))) {
        .enum_literal => names[0] = @tagName(axes),
        .@"struct" => |info| {
            inline for (info.field_names, 0..) |field_name, index| {
                const value = @field(axes, field_name);
                if (@typeInfo(@TypeOf(value)) != .enum_literal) {
                    @compileError("tensor axes tuple entries must be enum literals");
                }
                names[index] = @tagName(value);
            }
        },
        else => unreachable,
    }
    const final = names;
    return &final;
}

pub fn isNameSlice(comptime Axes: type) bool {
    return Axes == []const []const u8 or Axes == [][]const u8;
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.AxisNameEmpty;
}

pub fn validateAuthoredName(name: []const u8) !void {
    try validateName(name);
    if (name[0] == generated_prefix) return error.AxisNameReserved;
}

pub fn validateDims(dims: []const Dim) !void {
    for (dims, 0..) |dim, index| {
        try validateName(dim.name);
        if (dim.extent < 0) return error.InvalidDimension;
        for (dims[0..index]) |seen| {
            if (std.mem.eql(u8, seen.name, dim.name)) return error.DuplicateAxis;
        }
    }
}

pub fn validateAuthoredDims(dims: []const Dim) !void {
    try validateDims(dims);
    for (dims) |dim| {
        try validateAuthoredName(dim.name);
    }
}

pub fn copyDims(allocator: std.mem.Allocator, dims: []const Dim) ![]const Dim {
    try validateDims(dims);
    const owned = try allocator.alloc(Dim, dims.len);
    for (dims, owned) |dim, *slot| {
        slot.* = .{
            .name = try allocator.dupe(u8, dim.name),
            .extent = dim.extent,
        };
    }
    return owned;
}

pub fn findDim(dims: []const Dim, name: []const u8) ?usize {
    for (dims, 0..) |dim, index| {
        if (std.mem.eql(u8, dim.name, name)) return index;
    }
    return null;
}

pub fn sameDims(lhs: []const Dim, rhs: []const Dim) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left.extent != right.extent) return false;
        if (!std.mem.eql(u8, left.name, right.name)) return false;
    }
    return true;
}

pub fn dimsElementCount(dims: []const Dim) !usize {
    var count: usize = 1;
    for (dims) |dim| {
        if (dim.extent < 0) return error.InvalidDimension;
        count = std.math.mul(usize, count, @intCast(dim.extent)) catch return error.ShapeElementOverflow;
    }
    return count;
}

pub fn extents(allocator: std.mem.Allocator, dims: []const Dim) ![]const i64 {
    const owned = try allocator.alloc(i64, dims.len);
    for (dims, owned) |dim, *slot| {
        slot.* = dim.extent;
    }
    return owned;
}

pub fn sameType(lhs: Type, rhs: Type) !void {
    if (lhs.dtype != rhs.dtype) return error.DTypeMismatch;
    if (!sameDims(lhs.dims, rhs.dims)) return error.ShapeMismatch;
}

test "dims literal parsing preserves declaration order" {
    const parsed = spec(.f32, .{ .point = 16, .sample = 8 });
    try std.testing.expectEqual(@as(usize, 2), parsed.dims.len);
    try std.testing.expectEqualStrings("point", parsed.dims[0].name);
    try std.testing.expectEqual(@as(i64, 16), parsed.dims[0].extent);
    try std.testing.expectEqualStrings("sample", parsed.dims[1].name);
    try std.testing.expectEqual(@as(i64, 8), parsed.dims[1].extent);
}

test "axis names parse from literals and tuples" {
    const single = axisNames(.sample);
    try std.testing.expectEqualStrings("sample", single[0]);

    const pair = axisNames(.{ .point, .sample });
    try std.testing.expectEqualStrings("point", pair[0]);
    try std.testing.expectEqualStrings("sample", pair[1]);
}

test "type owns validated dims and computes byte count" {
    const ty = try Type.init(std.testing.allocator, .f32, &.{
        .{ .name = "a", .extent = 2 },
        .{ .name = "b", .extent = 3 },
        .{ .name = "c", .extent = 4 },
    });
    defer freeTestType(std.testing.allocator, ty);

    try std.testing.expectEqual(@as(usize, 3), ty.rank());
    try std.testing.expectEqual(@as(usize, 24), try ty.elementCount());
    try std.testing.expectEqual(@as(usize, 96), try ty.byteCount());
    try std.testing.expectEqual(@as(?usize, 1), ty.find("b"));
    try std.testing.expectEqual(@as(?usize, null), ty.find("missing"));
}

test "dims validation rejects bad names and extents" {
    try std.testing.expectError(error.InvalidDimension, Type.init(
        std.testing.allocator,
        .f32,
        &.{.{ .name = "a", .extent = -1 }},
    ));
    try std.testing.expectError(error.DuplicateAxis, Type.init(
        std.testing.allocator,
        .f32,
        &.{ .{ .name = "a", .extent = 2 }, .{ .name = "a", .extent = 3 } },
    ));
    try std.testing.expectError(error.AxisNameEmpty, Type.init(
        std.testing.allocator,
        .f32,
        &.{.{ .name = "", .extent = 2 }},
    ));
    try std.testing.expectError(error.AxisNameReserved, validateAuthoredDims(&.{
        .{ .name = "#batch", .extent = 2 },
    }));
    try validateDims(&.{.{ .name = "#batch", .extent = 2 }});
}

pub fn freeTestType(allocator: std.mem.Allocator, ty: Type) void {
    for (ty.dims) |dim| allocator.free(dim.name);
    allocator.free(ty.dims);
}

pub fn expectExtents(expected: []const i64, ty: Type) !void {
    try std.testing.expectEqual(expected.len, ty.dims.len);
    for (expected, ty.dims) |extent, dim| {
        try std.testing.expectEqual(extent, dim.extent);
    }
}
