const std = @import("std");

const common = @import("common.zig");
const scalar = @import("scalar.zig");

const DType = common.DType;
const TypedValue = common.TypedValue;

pub fn constantValue(owner: anytype, comptime dtype: DType, value: anytype) !TypedValue(dtype) {
    return scalar.typedValue(owner, dtype, switch (dtype) {
        .i1 => try owner.constantBool(value),
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => try owner.constantInt(
            dtype,
            std.math.cast(i64, value) orelse return error.IntegerOutOfBounds,
        ),
        .f16, .f32, .f64 => try owner.constantFloat(dtype, literalFloat(value)),
        else => return error.UnsupportedDType,
    });
}

fn literalFloat(value: anytype) f64 {
    const Value = @TypeOf(value);
    return switch (comptime @typeInfo(Value)) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("float constants require numeric literals or numeric values"),
    };
}
