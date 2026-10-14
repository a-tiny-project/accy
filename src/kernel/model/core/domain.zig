const std = @import("std");
const gpu_abi = @import("gpu_abi");

const builder = @import("builder.zig");
const schedule = @import("schedule/root.zig");
const typed = @import("typed.zig");
const vector = @import("vector.zig");

const DType = gpu_abi.DType;

pub const Vec2 = vector.Vec2;
pub const Vec3 = vector.Vec3;
pub const TypedValue = typed.Value;
pub const TypedVec2 = typed.Vec2;
pub const TypedVec3 = typed.Vec3;

pub const Index1D = struct {
    domain: schedule.AxisId,
    tile: ?schedule.Split = null,
    index: builder.Value,
    bound: builder.Value,
    extent: u64,

    pub fn linear(self: Index1D, k: anytype) !builder.Value {
        _ = k;
        return self.index;
    }

    pub fn linearValue(self: Index1D, k: anytype, comptime dtype: DType) !TypedValue(dtype) {
        return k.castValue(try self.linear(k), dtype);
    }

    pub fn cellCenter(
        self: Index1D,
        k: anytype,
        comptime dtype: DType,
        origin: anytype,
        spacing: anytype,
    ) !CellCenterResult(dtype, @TypeOf(origin)) {
        return wrapCellCenterResult(dtype, origin, try cellCenter1D(
            k,
            dtype,
            self.index,
            try scalarInputValue(k, dtype, origin),
            try scalarInputValue(k, dtype, spacing),
        ));
    }
};

pub const VectorIndex1D = struct {
    domain: schedule.AxisId,
    tile: ?schedule.Split = null,
    packet: builder.Value,
    packet_bound: builder.Value,
    base: builder.Value,
    bound: builder.Value,
    extent: u64,
    width: u32,
    packets: u64,

    pub fn linear(self: VectorIndex1D, k: anytype) !builder.Value {
        _ = k;
        return self.base;
    }

    pub fn linearValue(self: VectorIndex1D, k: anytype, comptime dtype: DType) !TypedValue(dtype) {
        return k.castValue(try self.linear(k), dtype);
    }
};

pub const DomainAxis = struct {
    name: []const u8,
    extent: u64,
    threads_per_block: u32,
};

pub const Domain2D = struct {
    x: DomainAxis,
    y: DomainAxis,
};

pub const Domain3D = struct {
    x: DomainAxis,
    y: DomainAxis,
    z: DomainAxis,
};

pub const Index2D = struct {
    x: Index1D,
    y: Index1D,

    pub fn linear(self: Index2D, k: anytype) !builder.Value {
        const width = try constantIndexFromU64(k, self.x.extent);
        const row = try k.mul(self.y.index, width);
        return k.add(row, self.x.index);
    }

    pub fn linearValue(self: Index2D, k: anytype, comptime dtype: DType) !TypedValue(dtype) {
        return k.castValue(try self.linear(k), dtype);
    }

    pub fn cellCenter(
        self: Index2D,
        k: anytype,
        comptime dtype: DType,
        origin: anytype,
        spacing: anytype,
    ) !CellCenterVec2Result(dtype, @TypeOf(origin)) {
        const x = try cellCenter1D(
            k,
            dtype,
            self.x.index,
            try vec2InputX(k, dtype, origin),
            try vec2InputX(k, dtype, spacing),
        );
        const y = try cellCenter1D(
            k,
            dtype,
            self.y.index,
            try vec2InputY(k, dtype, origin),
            try vec2InputY(k, dtype, spacing),
        );
        return wrapCellCenterVec2Result(dtype, origin, x, y);
    }
};

pub const Index3D = struct {
    x: Index1D,
    y: Index1D,
    z: Index1D,

    pub fn linear(self: Index3D, k: anytype) !builder.Value {
        const width = try constantIndexFromU64(k, self.x.extent);
        const plane_extent = try checkedExtentProduct(self.x.extent, self.y.extent);
        const plane = try constantIndexFromU64(k, plane_extent);
        const z_base = try k.mul(self.z.index, plane);
        const y_base = try k.mul(self.y.index, width);
        const yz_base = try k.add(z_base, y_base);
        return k.add(yz_base, self.x.index);
    }

    pub fn linearValue(self: Index3D, k: anytype, comptime dtype: DType) !TypedValue(dtype) {
        return k.castValue(try self.linear(k), dtype);
    }

    pub fn cellCenter(
        self: Index3D,
        k: anytype,
        comptime dtype: DType,
        origin: anytype,
        spacing: anytype,
    ) !CellCenterVec3Result(dtype, @TypeOf(origin)) {
        const x = try cellCenter1D(
            k,
            dtype,
            self.x.index,
            try vec3InputX(k, dtype, origin),
            try vec3InputX(k, dtype, spacing),
        );
        const y = try cellCenter1D(
            k,
            dtype,
            self.y.index,
            try vec3InputY(k, dtype, origin),
            try vec3InputY(k, dtype, spacing),
        );
        const z = try cellCenter1D(
            k,
            dtype,
            self.z.index,
            try vec3InputZ(k, dtype, origin),
            try vec3InputZ(k, dtype, spacing),
        );
        return wrapCellCenterVec3Result(dtype, origin, x, y, z);
    }
};

pub fn domainAxis(name: []const u8, extent: u64, threads_per_block: u32) DomainAxis {
    return .{
        .name = name,
        .extent = extent,
        .threads_per_block = threads_per_block,
    };
}

fn constantIndexFromU64(k: anytype, value: u64) !builder.Value {
    return k.constantIndex(std.math.cast(i64, value) orelse return error.LaunchDimensionOverflow);
}

fn checkedExtentProduct(lhs: u64, rhs: u64) !u64 {
    return std.math.mul(u64, lhs, rhs) catch return error.LaunchDimensionOverflow;
}

fn cellCenter1D(
    k: anytype,
    dtype: DType,
    index: builder.Value,
    origin: builder.Value,
    spacing: builder.Value,
) !builder.Value {
    const index_float = try k.cast(index, dtype);
    const half = try k.constantFloat(dtype, 0.5);
    const centered = try k.add(index_float, half);
    const scaled = try k.mul(centered, spacing);
    return k.add(origin, scaled);
}

fn hasScalarRaw(comptime ValueType: type) bool {
    return switch (comptime @typeInfo(ValueType)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(ValueType, "scalar_dtype") and @hasDecl(
            ValueType,
            "raw",
        ) and @TypeOf(@as(ValueType, undefined).raw()) == builder.Value,
        else => false,
    };
}

fn CellCenterResult(comptime dtype: DType, comptime Origin: type) type {
    if (Origin == builder.Value) return builder.Value;
    if (hasScalarRaw(Origin)) return Origin;
    return switch (comptime @typeInfo(Origin)) {
        .int, .comptime_int, .float, .comptime_float => TypedValue(dtype),
        else => @compileError("cellCenter scalar origin must be a raw Choir value, typed scalar " ++
            "value, or scalar literal"),
    };
}

fn CellCenterVec2Result(comptime dtype: DType, comptime Origin: type) type {
    if (Origin == Vec2 or Origin == builder.Value) return Vec2;
    if (Origin == TypedVec2(dtype) or hasScalarRaw(Origin)) return TypedVec2(dtype);
    return switch (comptime @typeInfo(Origin)) {
        .int, .comptime_int, .float, .comptime_float => TypedVec2(dtype),
        else => @compileError("2D cellCenter origin must be a raw vector, typed vector, scalar " ++
            "value, or scalar literal"),
    };
}

fn CellCenterVec3Result(comptime dtype: DType, comptime Origin: type) type {
    if (Origin == Vec3 or Origin == builder.Value) return Vec3;
    if (Origin == TypedVec3(dtype) or hasScalarRaw(Origin)) return TypedVec3(dtype);
    return switch (comptime @typeInfo(Origin)) {
        .int, .comptime_int, .float, .comptime_float => TypedVec3(dtype),
        else => @compileError("3D cellCenter origin must be a raw vector, typed vector, scalar " ++
            "value, or scalar literal"),
    };
}

fn scalarInputValue(k: anytype, comptime dtype: DType, input: anytype) !builder.Value {
    const Input = @TypeOf(input);
    if (comptime Input == builder.Value) return input;
    if (comptime hasScalarRaw(Input)) return input.raw();
    return (try TypedValue(dtype).from(k, input)).raw();
}

fn wrapCellCenterResult(
    comptime dtype: DType,
    origin: anytype,
    value: builder.Value,
) !CellCenterResult(dtype, @TypeOf(origin)) {
    const Origin = @TypeOf(origin);
    if (comptime Origin == builder.Value) return value;
    if (comptime hasScalarRaw(Origin)) return Origin.init(value);
    return TypedValue(dtype).init(value);
}

fn isVec2Input(comptime dtype: DType, comptime Input: type) bool {
    return Input == Vec2 or Input == TypedVec2(dtype);
}

fn isVec3Input(comptime dtype: DType, comptime Input: type) bool {
    return Input == Vec3 or Input == TypedVec3(dtype);
}

fn vec2InputX(k: anytype, comptime dtype: DType, input: anytype) !builder.Value {
    const Input = @TypeOf(input);
    if (comptime isVec2Input(dtype, Input)) return scalarInputValue(k, dtype, input.x);
    return scalarInputValue(k, dtype, input);
}

fn vec2InputY(k: anytype, comptime dtype: DType, input: anytype) !builder.Value {
    const Input = @TypeOf(input);
    if (comptime isVec2Input(dtype, Input)) return scalarInputValue(k, dtype, input.y);
    return scalarInputValue(k, dtype, input);
}

fn vec3InputX(k: anytype, comptime dtype: DType, input: anytype) !builder.Value {
    const Input = @TypeOf(input);
    if (comptime isVec3Input(dtype, Input)) return scalarInputValue(k, dtype, input.x);
    return scalarInputValue(k, dtype, input);
}

fn vec3InputY(k: anytype, comptime dtype: DType, input: anytype) !builder.Value {
    const Input = @TypeOf(input);
    if (comptime isVec3Input(dtype, Input)) return scalarInputValue(k, dtype, input.y);
    return scalarInputValue(k, dtype, input);
}

fn vec3InputZ(k: anytype, comptime dtype: DType, input: anytype) !builder.Value {
    const Input = @TypeOf(input);
    if (comptime isVec3Input(dtype, Input)) return scalarInputValue(k, dtype, input.z);
    return scalarInputValue(k, dtype, input);
}

fn wrapCellCenterVec2Result(
    comptime dtype: DType,
    origin: anytype,
    x: builder.Value,
    y: builder.Value,
) CellCenterVec2Result(dtype, @TypeOf(origin)) {
    const Origin = @TypeOf(origin);
    if (comptime Origin == Vec2 or Origin == builder.Value) return Vec2.init(x, y);
    return TypedVec2(dtype).init(TypedValue(dtype).init(x), TypedValue(dtype).init(y));
}

fn wrapCellCenterVec3Result(
    comptime dtype: DType,
    origin: anytype,
    x: builder.Value,
    y: builder.Value,
    z: builder.Value,
) CellCenterVec3Result(dtype, @TypeOf(origin)) {
    const Origin = @TypeOf(origin);
    if (comptime Origin == Vec3 or Origin == builder.Value) return Vec3.init(x, y, z);
    return TypedVec3(dtype).init(
        TypedValue(dtype).init(x),
        TypedValue(dtype).init(y),
        TypedValue(dtype).init(z),
    );
}
