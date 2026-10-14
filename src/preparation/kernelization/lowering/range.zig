const std = @import("std");
const gpu_abi = @import("gpu_abi");
const alloc_fixed = @import("alloc_fixed");
const common = @import("common.zig");

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const isName = common.isName;

const NumericRange = struct {
    lower: f64,
    upper: f64,
    lower_sound: bool,
    upper_sound: bool,
    integral: bool,

    fn unknown() NumericRange {
        return .{
            .lower = -std.math.inf(f64),
            .upper = std.math.inf(f64),
            .lower_sound = true,
            .upper_sound = true,
            .integral = false,
        };
    }

    fn unsound() NumericRange {
        return .{
            .lower = -std.math.inf(f64),
            .upper = std.math.inf(f64),
            .lower_sound = false,
            .upper_sound = false,
            .integral = false,
        };
    }

    fn exact(value: f64, integral: bool) NumericRange {
        return .{
            .lower = value,
            .upper = value,
            .lower_sound = true,
            .upper_sound = true,
            .integral = integral,
        };
    }

    fn hasFiniteBounds(self: NumericRange) bool {
        return self.lower_sound and
            self.upper_sound and std.math.isFinite(self.lower) and std.math.isFinite(self.upper);
    }

    fn add(lhs: NumericRange, rhs: NumericRange) NumericRange {
        return .{
            .lower = if (lhs.lower_sound and rhs.lower_sound)
                lhs.lower + rhs.lower
            else
                -std.math.inf(f64),
            .upper = if (lhs.upper_sound and rhs.upper_sound)
                lhs.upper + rhs.upper
            else
                std.math.inf(f64),
            .lower_sound = lhs.lower_sound and rhs.lower_sound,
            .upper_sound = lhs.upper_sound and rhs.upper_sound,
            .integral = lhs.integral and rhs.integral,
        };
    }

    fn sub(lhs: NumericRange, rhs: NumericRange) NumericRange {
        return .{
            .lower = if (lhs.lower_sound and rhs.upper_sound)
                lhs.lower - rhs.upper
            else
                -std.math.inf(f64),
            .upper = if (lhs.upper_sound and rhs.lower_sound)
                lhs.upper - rhs.lower
            else
                std.math.inf(f64),
            .lower_sound = lhs.lower_sound and rhs.upper_sound,
            .upper_sound = lhs.upper_sound and rhs.lower_sound,
            .integral = lhs.integral and rhs.integral,
        };
    }

    fn mul(lhs: NumericRange, rhs: NumericRange) NumericRange {
        if (!lhs.hasFiniteBounds() or !rhs.hasFiniteBounds()) return unsound();
        const p0 = lhs.lower * rhs.lower;
        const p1 = lhs.lower * rhs.upper;
        const p2 = lhs.upper * rhs.lower;
        const p3 = lhs.upper * rhs.upper;
        return .{
            .lower = @min(@min(p0, p1), @min(p2, p3)),
            .upper = @max(@max(p0, p1), @max(p2, p3)),
            .lower_sound = true,
            .upper_sound = true,
            .integral = lhs.integral and rhs.integral,
        };
    }

    fn min(lhs: NumericRange, rhs: NumericRange) NumericRange {
        const lower_sound = lhs.lower_sound and rhs.lower_sound;
        const upper_sound = lhs.upper_sound or rhs.upper_sound;
        return .{
            .lower = if (lower_sound) @min(lhs.lower, rhs.lower) else -std.math.inf(f64),
            .upper = if (lhs.upper_sound and rhs.upper_sound)
                @min(lhs.upper, rhs.upper)
            else if (lhs.upper_sound) lhs.upper else rhs.upper,
            .lower_sound = lower_sound,
            .upper_sound = upper_sound,
            .integral = lhs.integral and rhs.integral,
        };
    }

    fn max(lhs: NumericRange, rhs: NumericRange) NumericRange {
        const lower_sound = lhs.lower_sound or rhs.lower_sound;
        const upper_sound = lhs.upper_sound and rhs.upper_sound;
        return .{
            .lower = if (lhs.lower_sound and rhs.lower_sound)
                @max(lhs.lower, rhs.lower)
            else if (lhs.lower_sound) lhs.lower else rhs.lower,
            .upper = if (upper_sound) @max(lhs.upper, rhs.upper) else std.math.inf(f64),
            .lower_sound = lower_sound,
            .upper_sound = upper_sound,
            .integral = lhs.integral and rhs.integral,
        };
    }

    fn floor(self: NumericRange) NumericRange {
        return .{
            .lower = if (self.lower_sound) floorBound(self.lower) else -std.math.inf(f64),
            .upper = if (self.upper_sound) floorBound(self.upper) else std.math.inf(f64),
            .lower_sound = self.lower_sound,
            .upper_sound = self.upper_sound,
            .integral = true,
        };
    }

    fn toNonNegativeInteger(self: NumericRange) NumericRange {
        if (!self.hasFiniteBounds() or self.lower < 0) return unknown();
        return .{
            .lower = @floor(self.lower),
            .upper = @floor(self.upper),
            .lower_sound = true,
            .upper_sound = true,
            .integral = true,
        };
    }
};

const RangeKernel = enum {
    convert,
    add,
    sub,
    mul,
    min,
    max,
    floor,
};

pub fn gatherIndexProvenInBounds(
    value: *ir.Value,
    axis_size: i64,
    depth: usize,
) common.LoweringError!bool {
    if (axis_size <= 0) return false;
    const range = try numericRangeForValue(value, depth);
    if (!range.integral or !range.hasFiniteBounds() or
        range.lower < 0 or range.upper > @as(f64, @floatFromInt(axis_size - 1))) return false;
    return nonNegativeRangeFitsDType(range, try dtypeForValue(value));
}

fn numericRangeForValue(value: *ir.Value, depth: usize) common.LoweringError!NumericRange {
    if (depth == 0) return NumericRange.unknown();
    const def_any = value.getDefiningOp() orelse return NumericRange.unknown();
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));

    if (isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        return numericRangeForConstant(def_op) orelse NumericRange.unknown();
    }
    if (isName(def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
        const operands = def_op.getOperandValues();
        if (operands.len != 1) return error.InvalidArtifact;
        return numericRangeForValue(operands[0], depth - 1);
    }
    if (isName(def_op.name.name, dialect_mod.AccyDialect.IotaOp.operation_name)) {
        return numericRangeForIota(def_op, value);
    }

    const kind = rangeKernelForOperation(def_op) orelse return NumericRange.unknown();
    const operands = def_op.getOperandValues();
    switch (kind) {
        .convert => {
            if (operands.len != 1) return error.InvalidArtifact;
            const source = try numericRangeForValue(operands[0], depth - 1);
            const result_dtype = try dtypeForValue(value);
            if (result_dtype.isSignedInt() or result_dtype.isUnsignedInt()) {
                const converted = source.toNonNegativeInteger();
                if (!converted.hasFiniteBounds() or !nonNegativeRangeFitsDType(
                    converted,
                    result_dtype,
                )) return NumericRange.unknown();
                return converted;
            }
            if (result_dtype.isFloat()) return constrainFloatConversion(source, result_dtype);
            return NumericRange.unknown();
        },
        .add, .sub, .mul, .min, .max => {
            if (operands.len != 2) return error.InvalidArtifact;
            const lhs = try numericRangeForValue(operands[0], depth - 1);
            const rhs = try numericRangeForValue(operands[1], depth - 1);
            const result = switch (kind) {
                .add => lhs.add(rhs),
                .sub => lhs.sub(rhs),
                .mul => lhs.mul(rhs),
                .min => lhs.min(rhs),
                .max => lhs.max(rhs),
                else => unreachable,
            };
            return constrainOperationResult(result, try dtypeForValue(value), kind);
        },
        .floor => {
            if (operands.len != 1) return error.InvalidArtifact;
            return constrainOperationResult(
                (try numericRangeForValue(operands[0], depth - 1)).floor(),
                try dtypeForValue(value),
                kind,
            );
        },
    }
}

fn numericRangeForIota(def_op: *ir.Operation, value: *ir.Value) common.LoweringError!NumericRange {
    const axis_attr = def_op.getAttrAs(
        ir.Attribute.IntegerAttr,
        "iota_dimension",
    ) orelse return error.InvalidArtifact;
    const axis = axis_attr.getValue();
    if (axis < 0) return error.InvalidArtifact;

    var type_arena_buffer: [256]u8 = undefined;
    var type_arena = alloc_fixed.FixedBuffer.init(type_arena_buffer[0..]);
    const result_type = dialect_mod.decodeTensorType(
        type_arena.allocator(),
        value.type,
    ) catch return error.InvalidArtifact;
    if (axis >= result_type.dims.len) return error.InvalidArtifact;
    const axis_dim = result_type.dims[@intCast(axis)];
    if (axis_dim <= 0) return error.CapabilityMismatch;
    return .{
        .lower = 0,
        .upper = @floatFromInt(axis_dim - 1),
        .lower_sound = true,
        .upper_sound = true,
        .integral = true,
    };
}

fn numericRangeForConstant(op: *ir.Operation) ?NumericRange {
    const constant = dialect_mod.AccyDialect.ConstantOp{ .op = op };
    const payload = constant.getPayload() orelse return null;
    const result = op.getResult(0) orelse return null;
    var type_arena_buffer: [256]u8 = undefined;
    var type_arena = alloc_fixed.FixedBuffer.init(type_arena_buffer[0..]);
    const result_type = dialect_mod.decodeTensorType(
        type_arena.allocator(),
        result.type,
    ) catch return null;
    return switch (result_type.dtype) {
        .f32 => numericRangeForSplat(f32, payload),
        .i32 => numericRangeForSplat(i32, payload),
        .u32 => numericRangeForSplat(u32, payload),
        else => null,
    };
}

fn numericRangeForSplat(comptime T: type, payload: []const u8) ?NumericRange {
    if (payload.len < @sizeOf(T) or payload.len % @sizeOf(T) != 0) return null;
    var first: T = undefined;
    @memcpy(std.mem.asBytes(&first), payload[0..@sizeOf(T)]);
    var offset: usize = @sizeOf(T);
    while (offset < payload.len) : (offset += @sizeOf(T)) {
        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), payload[offset..][0..@sizeOf(T)]);
        if (value != first) return null;
    }
    const value = switch (@typeInfo(T)) {
        .float => @as(f64, @floatCast(first)),
        .int => @as(f64, @floatFromInt(first)),
        else => return null,
    };
    return NumericRange.exact(value, rangeValueIsIntegral(value));
}

fn nonNegativeRangeFitsDType(range: NumericRange, dtype: gpu_abi.DType) bool {
    if (!range.hasFiniteBounds() or range.lower < 0) return false;
    return switch (dtype) {
        .i8 => range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i8))),
        .i16 => range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i16))),
        .i32 => range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i32))),
        .i64 => range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i64))),
        .u8 => range.upper <= @as(f64, @floatFromInt(std.math.maxInt(u8))),
        .u16 => range.upper <= @as(f64, @floatFromInt(std.math.maxInt(u16))),
        .u32 => range.upper <= @as(f64, @floatFromInt(std.math.maxInt(u32))),
        .u64 => true,
        else => false,
    };
}

fn rangeFitsDType(range: NumericRange, dtype: gpu_abi.DType) bool {
    if (!range.hasFiniteBounds()) return false;
    return switch (dtype) {
        .i8 => range.lower >= @as(f64, @floatFromInt(std.math.minInt(i8))) and
            range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i8))),
        .i16 => range.lower >= @as(
            f64,
            @floatFromInt(std.math.minInt(i16)),
        ) and range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i16))),
        .i32 => range.lower >= @as(
            f64,
            @floatFromInt(std.math.minInt(i32)),
        ) and range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i32))),
        .i64 => range.lower >= @as(
            f64,
            @floatFromInt(std.math.minInt(i64)),
        ) and range.upper <= @as(f64, @floatFromInt(std.math.maxInt(i64))),
        .u8 => range.lower >= 0 and range.upper <= @as(f64, @floatFromInt(std.math.maxInt(u8))),
        .u16 => range.lower >= 0 and range.upper <= @as(f64, @floatFromInt(std.math.maxInt(u16))),
        .u32 => range.lower >= 0 and range.upper <= @as(f64, @floatFromInt(std.math.maxInt(u32))),
        .u64 => range.lower >= 0 and range.upper <= @as(f64, @floatFromInt(std.math.maxInt(u64))),
        else => false,
    };
}

fn constrainOperationResult(
    range: NumericRange,
    dtype: gpu_abi.DType,
    kind: RangeKernel,
) NumericRange {
    if (dtype.isSignedInt() or dtype.isUnsignedInt()) {
        if (!rangeFitsDType(range, dtype)) return NumericRange.unsound();
        return .{
            .lower = range.lower,
            .upper = range.upper,
            .lower_sound = range.lower_sound,
            .upper_sound = range.upper_sound,
            .integral = true,
        };
    }
    if (!dtype.isFloat()) return NumericRange.unknown();
    if ((kind == .add or kind == .sub or kind ==
        .mul) and (!range.integral or !floatIntegralRangeExactlyRepresentable(range, dtype)))
    {
        return NumericRange.unsound();
    }
    return range;
}

fn constrainFloatConversion(range: NumericRange, dtype: gpu_abi.DType) NumericRange {
    if (range.integral and floatIntegralRangeExactlyRepresentable(range, dtype)) return range;
    return NumericRange.unsound();
}

fn floatIntegralRangeExactlyRepresentable(range: NumericRange, dtype: gpu_abi.DType) bool {
    if (!range.integral or !range.hasFiniteBounds()) return false;
    const limit: f64 = switch (dtype) {
        .f16 => 2048,
        .bf16 => 256,
        .f32 => 16777216,
        .f64 => 9007199254740992,
        else => return false,
    };
    return range.lower >= -limit and range.upper <= limit;
}

fn rangeValueIsIntegral(value: f64) bool {
    return std.math.isFinite(value) and @floor(value) == value;
}

fn floorBound(value: f64) f64 {
    if (!std.math.isFinite(value)) return value;
    return @floor(value);
}

fn dtypeForValue(value: *ir.Value) common.LoweringError!gpu_abi.DType {
    var type_arena_buffer: [256]u8 = undefined;
    var type_arena = alloc_fixed.FixedBuffer.init(type_arena_buffer[0..]);
    return (dialect_mod.decodeTensorType(
        type_arena.allocator(),
        value.type,
    ) catch return error.InvalidArtifact).dtype;
}

fn rangeKernelForOperation(op: *ir.Operation) ?RangeKernel {
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ConvertOp.operation_name)) {
        return .convert;
    }
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.AddOp.operation_name)) return .add;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.SubOp.operation_name)) return .sub;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MulOp.operation_name)) return .mul;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MinOp.operation_name)) return .min;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MaxOp.operation_name)) return .max;
    if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.FloorOp.operation_name)) {
        return .floor;
    }
    return null;
}
