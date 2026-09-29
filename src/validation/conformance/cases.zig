const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const accy = @import("accy");
const conformance = @import("root.zig");

const harness = conformance.harness;
const SemanticBuilder = harness.SemanticBuilder;
const FunctionBuilder = harness.FunctionBuilder;
const Value = harness.Value;
const DType = harness.DType;
const Bf16 = harness.Bf16;
const kernel_limits = accy.kernel.Limits.standard;

const element_count = 256;

const BinaryOp = enum { add, sub, mul, div, min, max, pow };
const UnaryOp = enum { neg, abs, exp, log, sqrt, sin, cos, tanh, floor, round, trunc };
const FillKind = enum { default, positive, lhs_positive, rhs_positive };

fn Binary(
    comptime case_name: []const u8,
    comptime dtype: DType,
    comptime op: BinaryOp,
    comptime fill_kind: FillKind,
    comptime case_tolerance: f32,
    comptime case_expectation: harness.Expectation,
) type {
    return struct {
        pub const name = case_name;
        pub const expectation = case_expectation;
        pub const inputs = [_]harness.Tensor{
            harness.vec(dtype, element_count),
            harness.vec(dtype, element_count),
        };
        pub const output = harness.vec(dtype, element_count);
        pub const tolerance: f32 = case_tolerance;

        pub fn body(_: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const lhs = function.parameter(0);
            const rhs = function.parameter(1);
            return switch (op) {
                .add => try function.add(lhs, rhs),
                .sub => try function.sub(lhs, rhs),
                .mul => try function.mul(lhs, rhs),
                .div => try function.div(lhs, rhs),
                .min => try function.min(lhs, rhs),
                .max => try function.max(lhs, rhs),
                .pow => try function.pow(lhs, rhs),
            };
        }

        pub fn fill(input_index: usize, buffer: []u8) void {
            fillByKind(dtype, fill_kind, input_index, buffer);
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const lhs = std.mem.bytesAsSlice(T, views[0]);
            const rhs = std.mem.bytesAsSlice(T, views[1]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (out, lhs, rhs) |*value, a, b| value.* = binaryReference(T, op, a, b);
        }
    };
}

fn Unary(
    comptime case_name: []const u8,
    comptime dtype: DType,
    comptime op: UnaryOp,
    comptime fill_kind: FillKind,
    comptime case_tolerance: f32,
    comptime case_expectation: harness.Expectation,
) type {
    return struct {
        pub const name = case_name;
        pub const expectation = case_expectation;
        pub const inputs = [_]harness.Tensor{harness.vec(dtype, element_count)};
        pub const output = harness.vec(dtype, element_count);
        pub const tolerance: f32 = case_tolerance;

        pub fn body(_: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const input = function.parameter(0);
            return switch (op) {
                .neg => try function.neg(input),
                .abs => try function.abs(input),
                .exp => try function.exp(input),
                .log => try function.log(input),
                .sqrt => try function.sqrt(input),
                .sin => try function.sin(input),
                .cos => try function.cos(input),
                .tanh => try function.tanh(input),
                .floor => try function.floor(input),
                .round => try function.round(input),
                .trunc => try function.trunc(input),
            };
        }

        pub fn fill(input_index: usize, buffer: []u8) void {
            fillByKind(dtype, fill_kind, input_index, buffer);
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const input = std.mem.bytesAsSlice(T, views[0]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (out, input) |*value, a| value.* = unaryReference(T, op, a);
        }
    };
}

fn fillByKind(comptime dtype: DType, comptime fill_kind: FillKind, input_index: usize, buffer: []u8) void {
    const positive = switch (fill_kind) {
        .default => false,
        .positive => true,
        .lhs_positive => input_index == 0,
        .rhs_positive => input_index == 1,
    };
    if (positive) {
        harness.positiveFill(dtype, input_index, buffer);
    } else {
        harness.defaultFill(dtype, input_index, buffer);
    }
}

fn isUnsignedType(comptime T: type) bool {
    return @typeInfo(T) == .int and @typeInfo(T).int.signedness == .unsigned;
}

fn isIntType(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn floatLikeFromF32(comptime T: type, value: f32) T {
    if (comptime T == Bf16) return Bf16.fromF32(value);
    return @floatCast(value);
}

fn numericLikeFromF32(comptime T: type, value: f32) T {
    if (comptime T == Bf16) return Bf16.fromF32(value);
    return switch (@typeInfo(T)) {
        .float => @floatCast(value),
        .int => @intFromFloat(value),
        else => @compileError("unsupported conformance element type"),
    };
}

fn literalForDType(comptime dtype: DType, comptime float_value: f32, comptime int_value: comptime_int) dtype.ZigType() {
    const T = dtype.ZigType();
    if (comptime T == Bf16) return Bf16.fromF32(float_value);
    return if (comptime dtype.isFloat()) @floatCast(float_value) else @intCast(int_value);
}

fn iotaValue(comptime dtype: DType, index: usize) dtype.ZigType() {
    const T = dtype.ZigType();
    if (comptime T == Bf16) return Bf16.fromF32(@floatFromInt(index));
    return if (comptime dtype.isFloat()) @floatFromInt(index) else @intCast(index);
}

fn addReference(comptime T: type, a: T, b: T) T {
    return binaryReference(T, .add, a, b);
}

fn reduceInitValue(comptime dtype: DType, comptime kind: ReducerKind) dtype.ZigType() {
    const T = dtype.ZigType();
    if (comptime T == Bf16) {
        return Bf16.fromF32(switch (kind) {
            .sum => 0,
            .max => -std.math.inf(f32),
            .min => std.math.inf(f32),
        });
    }
    return switch (kind) {
        .sum => 0,
        .max => if (comptime dtype.isFloat()) -std.math.inf(T) else std.math.minInt(T),
        .min => if (comptime dtype.isFloat()) std.math.inf(T) else std.math.maxInt(T),
    };
}

fn binaryReference(comptime T: type, comptime op: BinaryOp, a: T, b: T) T {
    if (comptime T == Bf16) {
        const lhs = a.toF32();
        const rhs = b.toF32();
        const result = switch (op) {
            .add => lhs + rhs,
            .sub => lhs - rhs,
            .mul => lhs * rhs,
            .div => lhs / rhs,
            .min => @min(lhs, rhs),
            .max => @max(lhs, rhs),
            .pow => std.math.pow(f32, lhs, rhs),
        };
        return Bf16.fromF32(result);
    }
    return switch (op) {
        .add => if (comptime isIntType(T)) a +% b else a + b,
        .sub => if (comptime isIntType(T)) a -% b else a - b,
        .mul => if (comptime isIntType(T)) a *% b else a * b,
        .div => switch (@typeInfo(T)) {
            .float => a / b,
            .int => |info| if (info.signedness == .signed) @divTrunc(a, b) else a / b,
            else => @compileError("unsupported conformance element type"),
        },
        .min => @min(a, b),
        .max => @max(a, b),
        .pow => powReference(T, a, b),
    };
}

fn powReference(comptime T: type, a: T, b: T) T {
    if (comptime T == Bf16) return Bf16.fromF32(std.math.pow(f32, a.toF32(), b.toF32()));
    if (comptime @typeInfo(T) != .float) unreachable;
    if (comptime T == f16) {
        return @floatCast(std.math.pow(f32, @floatCast(a), @floatCast(b)));
    }
    return std.math.pow(T, a, b);
}

fn unaryReference(comptime T: type, comptime op: UnaryOp, a: T) T {
    if (comptime T == Bf16) {
        return switch (op) {
            .neg => Bf16.fromF32(-a.toF32()),
            .abs => Bf16.fromF32(@abs(a.toF32())),
            .exp, .log, .sqrt, .sin, .cos, .tanh, .floor, .round, .trunc => floatUnaryReference(T, op, a),
        };
    }
    return switch (op) {
        .neg => if (comptime isUnsignedType(T)) 0 -% a else -a,
        .abs => switch (@typeInfo(T)) {
            .float => @abs(a),
            .int => @intCast(@abs(a)),
            else => @compileError("unsupported conformance element type"),
        },
        .exp => floatUnaryReference(T, .exp, a),
        .log => floatUnaryReference(T, .log, a),
        .sqrt => floatUnaryReference(T, .sqrt, a),
        .sin => floatUnaryReference(T, .sin, a),
        .cos => floatUnaryReference(T, .cos, a),
        .tanh => floatUnaryReference(T, .tanh, a),
        .floor => floatUnaryReference(T, .floor, a),
        .round => floatUnaryReference(T, .round, a),
        .trunc => floatUnaryReference(T, .trunc, a),
    };
}

fn floatUnaryReference(comptime T: type, comptime op: UnaryOp, a: T) T {
    if (comptime T == Bf16) return Bf16.fromF32(floatUnaryF32(op, a.toF32()));
    if (comptime @typeInfo(T) != .float) unreachable;
    return switch (op) {
        .exp => @exp(a),
        .log => @log(a),
        .sqrt => @sqrt(a),
        .sin => @sin(a),
        .cos => @cos(a),
        .tanh => @floatCast(std.math.tanh(@as(f32, @floatCast(a)))),
        .floor => @floor(a),
        .round => @round(a),
        .trunc => @trunc(a),
        .neg, .abs => unreachable,
    };
}

fn floatUnaryF32(comptime op: UnaryOp, a: f32) f32 {
    return switch (op) {
        .exp => @exp(a),
        .log => @log(a),
        .sqrt => @sqrt(a),
        .sin => @sin(a),
        .cos => @cos(a),
        .tanh => std.math.tanh(a),
        .floor => @floor(a),
        .round => @round(a),
        .trunc => @trunc(a),
        .neg, .abs => unreachable,
    };
}

const TanhAddF32 = struct {
    pub const name = "tanh_add_f32_256";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{
        harness.vec(.f32, element_count),
        harness.vec(.f32, element_count),
    };
    pub const output = harness.vec(.f32, element_count);
    pub const tolerance: f32 = 0.00001;

    pub fn body(_: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const sum = try function.add(function.parameter(0), function.parameter(1));
        return try function.tanh(sum);
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const lhs = std.mem.bytesAsSlice(f32, views[0]);
        const rhs = std.mem.bytesAsSlice(f32, views[1]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (out, lhs, rhs) |*value, a, b| value.* = std.math.tanh(a + b);
    }
};

const BiasBroadcastF32 = struct {
    pub const name = "bias_broadcast_f32_8x32";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{
        harness.mat(.f32, 8, 32),
        harness.vec(.f32, 32),
    };
    pub const output = harness.mat(.f32, 8, 32);
    pub const tolerance: f32 = 0.0;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const result_type = try builder.tensor(.f32, &.{ 8, 32 });
        const bias = try function.broadcastInDim(function.parameter(1), result_type, &.{ 8, 32 }, &.{1});
        return try function.add(function.parameter(0), bias);
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const matrix = std.mem.bytesAsSlice(f32, views[0]);
        const bias = std.mem.bytesAsSlice(f32, views[1]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (out, 0..) |*value, index| value.* = matrix[index] + bias[index % 32];
    }
};

const DotRectF32 = struct {
    pub const name = "dot_general_f32_8x24x12";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{
        harness.mat(.f32, 8, 24),
        harness.mat(.f32, 24, 12),
    };
    pub const output = harness.mat(.f32, 8, 12);
    pub const tolerance: f32 = 0.0001;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const result_type = try builder.tensor(.f32, &.{ 8, 12 });
        return try function.dotGeneral(
            function.parameter(0),
            function.parameter(1),
            result_type,
            &.{1},
            &.{0},
            &.{},
            &.{},
        );
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        dotReference(f32, views, output_bytes, 8, 24, 12);
    }
};

fn dotReference(
    comptime T: type,
    views: []const []const u8,
    output_bytes: []u8,
    comptime rows: usize,
    comptime inner: usize,
    comptime cols: usize,
) void {
    if (comptime T == f16 or T == Bf16) {
        const lhs = std.mem.bytesAsSlice(T, views[0]);
        const rhs = std.mem.bytesAsSlice(T, views[1]);
        const out = std.mem.bytesAsSlice(T, output_bytes);
        for (0..rows) |row| {
            for (0..cols) |col| {
                var acc: f32 = 0;
                for (0..inner) |axis| {
                    acc += harness.numericToF32(T, lhs[row * inner + axis]) * harness.numericToF32(T, rhs[axis * cols + col]);
                }
                out[row * cols + col] = floatLikeFromF32(T, acc);
            }
        }
        return;
    }

    const lhs = std.mem.bytesAsSlice(T, views[0]);
    const rhs = std.mem.bytesAsSlice(T, views[1]);
    const out = std.mem.bytesAsSlice(T, output_bytes);
    for (0..rows) |row| {
        for (0..cols) |col| {
            var acc: T = 0;
            for (0..inner) |axis| {
                acc += lhs[row * inner + axis] * rhs[axis * cols + col];
            }
            out[row * cols + col] = acc;
        }
    }
}

const EinsumMatmulF32 = struct {
    pub const name = "einsum_matmul_f32_8x16x12";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{
        harness.mat(.f32, 8, 16),
        harness.mat(.f32, 16, 12),
    };
    pub const output = harness.mat(.f32, 8, 12);
    pub const tolerance: f32 = 0.0001;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const result_type = try builder.tensor(.f32, &.{ 8, 12 });
        return try function.einsum(
            &.{ function.parameter(0), function.parameter(1) },
            result_type,
            "ij,jk->ik",
        );
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        dotReference(f32, views, output_bytes, 8, 16, 12);
    }
};

const EinsumPermuteF32 = struct {
    pub const name = "einsum_permute_f32_8x16";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{harness.mat(.f32, 8, 16)};
    pub const output = harness.mat(.f32, 16, 8);
    pub const tolerance: f32 = 0.0;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const result_type = try builder.tensor(.f32, &.{ 16, 8 });
        return try function.einsum(&.{function.parameter(0)}, result_type, "ij->ji");
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const input = std.mem.bytesAsSlice(f32, views[0]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (0..16) |row| {
            for (0..8) |col| {
                out[row * 8 + col] = input[col * 16 + row];
            }
        }
    }
};

const ReduceSumAxisZeroF32 = struct {
    pub const name = "reduce_sum_axis0_f32_16x16";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{harness.mat(.f32, 16, 16)};
    pub const output = harness.vec(.f32, 16);
    pub const tolerance: f32 = 0.0001;
    const init_value: f32 = 0.0;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const scalar_type = try builder.tensor(.f32, &.{});
        const result_type = try builder.tensor(.f32, &.{16});
        const init = try function.constant(scalar_type, std.mem.asBytes(&init_value));
        return try function.reduce(function.parameter(0), init, result_type, "sum", &.{0});
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const input = std.mem.bytesAsSlice(f32, views[0]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (0..16) |col| {
            var acc: f32 = init_value;
            for (0..16) |row| acc += input[row * 16 + col];
            out[col] = acc;
        }
    }
};

const ReduceSumAllF32 = struct {
    pub const name = "reduce_sum_all_f32_16x16";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{harness.mat(.f32, 16, 16)};
    pub const output = harness.Tensor{ .dtype = .f32, .dims = &.{} };
    pub const tolerance: f32 = 0.001;
    const init_value: f32 = 0.0;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const scalar_type = try builder.tensor(.f32, &.{});
        const init = try function.constant(scalar_type, std.mem.asBytes(&init_value));
        return try function.reduce(function.parameter(0), init, scalar_type, "sum", &.{ 0, 1 });
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const input = std.mem.bytesAsSlice(f32, views[0]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        var acc: f32 = init_value;
        for (input) |value| acc += value;
        out[0] = acc;
    }
};

const AddRankThreeF32 = struct {
    pub const name = "add_f32_4x8x8";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{
        .{ .dtype = .f32, .dims = &.{ 4, 8, 8 } },
        .{ .dtype = .f32, .dims = &.{ 4, 8, 8 } },
    };
    pub const output = harness.Tensor{ .dtype = .f32, .dims = &.{ 4, 8, 8 } };
    pub const tolerance: f32 = 0.0;

    pub fn body(_: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        return try function.add(function.parameter(0), function.parameter(1));
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const lhs = std.mem.bytesAsSlice(f32, views[0]);
        const rhs = std.mem.bytesAsSlice(f32, views[1]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (out, lhs, rhs) |*value, a, b| value.* = a + b;
    }
};

const ReduceSumRankThreeTrailingF32 = struct {
    pub const name = "reduce_sum_axis2_f32_4x8x8";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{.{ .dtype = .f32, .dims = &.{ 4, 8, 8 } }};
    pub const output = harness.mat(.f32, 4, 8);
    pub const tolerance: f32 = 0.0001;
    const init_value: f32 = 0.0;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const scalar_type = try builder.tensor(.f32, &.{});
        const result_type = try builder.tensor(.f32, &.{ 4, 8 });
        const init = try function.constant(scalar_type, std.mem.asBytes(&init_value));
        return try function.reduce(function.parameter(0), init, result_type, "sum", &.{2});
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const input = std.mem.bytesAsSlice(f32, views[0]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (0..4) |outer| {
            for (0..8) |middle| {
                var acc: f32 = init_value;
                for (0..8) |inner| acc += input[outer * 64 + middle * 8 + inner];
                out[outer * 8 + middle] = acc;
            }
        }
    }
};

const ReduceSumRankThreeF32 = struct {
    pub const name = "reduce_sum_axis1_f32_4x8x8";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{.{ .dtype = .f32, .dims = &.{ 4, 8, 8 } }};
    pub const output = harness.mat(.f32, 4, 8);
    pub const tolerance: f32 = 0.0001;
    const init_value: f32 = 0.0;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const scalar_type = try builder.tensor(.f32, &.{});
        const result_type = try builder.tensor(.f32, &.{ 4, 8 });
        const init = try function.constant(scalar_type, std.mem.asBytes(&init_value));
        return try function.reduce(function.parameter(0), init, result_type, "sum", &.{1});
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const input = std.mem.bytesAsSlice(f32, views[0]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (0..4) |outer| {
            for (0..8) |inner| {
                var acc: f32 = init_value;
                for (0..8) |middle| acc += input[outer * 64 + middle * 8 + inner];
                out[outer * 8 + inner] = acc;
            }
        }
    }
};

const ReduceMaxRankThreeF32 = struct {
    pub const name = "reduce_max_axis1_f32_4x8x8";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{.{ .dtype = .f32, .dims = &.{ 4, 8, 8 } }};
    pub const output = harness.mat(.f32, 4, 8);
    pub const tolerance: f32 = 0.0;
    const init_value: f32 = -std.math.inf(f32);

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const scalar_type = try builder.tensor(.f32, &.{});
        const result_type = try builder.tensor(.f32, &.{ 4, 8 });
        const init = try function.constant(scalar_type, std.mem.asBytes(&init_value));
        return try function.reduce(function.parameter(0), init, result_type, "max", &.{1});
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const input = std.mem.bytesAsSlice(f32, views[0]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (0..4) |outer| {
            for (0..8) |inner| {
                var acc: f32 = init_value;
                for (0..8) |middle| acc = @max(acc, input[outer * 64 + middle * 8 + inner]);
                out[outer * 8 + inner] = acc;
            }
        }
    }
};

const ReduceSumSplitAxesF32 = struct {
    pub const name = "reduce_sum_axes02_f32_4x8x8";
    pub const expectation: harness.Expectation = .unsupported;
    pub const inputs = [_]harness.Tensor{.{ .dtype = .f32, .dims = &.{ 4, 8, 8 } }};
    pub const output = harness.vec(.f32, 8);
    pub const tolerance: f32 = 0.0001;
    const init_value: f32 = 0.0;

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const scalar_type = try builder.tensor(.f32, &.{});
        const result_type = try builder.tensor(.f32, &.{8});
        const init = try function.constant(scalar_type, std.mem.asBytes(&init_value));
        return try function.reduce(function.parameter(0), init, result_type, "sum", &.{ 0, 2 });
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const input = std.mem.bytesAsSlice(f32, views[0]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (0..8) |middle| {
            var acc: f32 = init_value;
            for (0..4) |outer| {
                for (0..8) |inner| acc += input[outer * 64 + middle * 8 + inner];
            }
            out[middle] = acc;
        }
    }
};

const GatherClampF32 = struct {
    pub const name = "gather_clamp_f32_6x8_axis0";
    pub const expectation: harness.Expectation = .verified;
    pub const inputs = [_]harness.Tensor{
        harness.mat(.f32, 6, 8),
        harness.vec(.i32, 4),
    };
    pub const output = harness.mat(.f32, 4, 8);
    pub const tolerance: f32 = 0.0;
    const index_values = [_]i32{ -3, 9, 5, 0 };

    pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
        const result_type = try builder.tensor(.f32, &.{ 4, 8 });
        return try function.gather(function.parameter(0), function.parameter(1), result_type, 0);
    }

    pub fn fill(input_index: usize, buffer: []u8) void {
        if (input_index == 1) {
            const values = std.mem.bytesAsSlice(i32, buffer);
            for (values, 0..) |*value, position| value.* = index_values[position];
            return;
        }
        harness.defaultFill(.f32, input_index, buffer);
    }

    pub fn reference(views: []const []const u8, output_bytes: []u8) void {
        const data = std.mem.bytesAsSlice(f32, views[0]);
        const indices = std.mem.bytesAsSlice(i32, views[1]);
        const out = std.mem.bytesAsSlice(f32, output_bytes);
        for (0..4) |row| {
            const clamped = std.math.clamp(indices[row], 0, 5);
            const source: usize = @intCast(clamped);
            for (0..8) |col| out[row * 8 + col] = data[source * 8 + col];
        }
    }
};

fn ScatterCase(
    comptime case_name: []const u8,
    comptime dtype: DType,
    comptime case_expectation: harness.Expectation,
    comptime index_values: [4]i32,
) type {
    return struct {
        pub const name = case_name;
        pub const expectation: harness.Expectation = case_expectation;
        pub const inputs = [_]harness.Tensor{
            harness.mat(dtype, 6, 8),
            harness.vec(.i32, 4),
            harness.mat(dtype, 4, 8),
        };
        pub const output = harness.mat(dtype, 6, 8);
        pub const tolerance: f32 = 0.0;

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{ 6, 8 });
            return try function.scatter(
                function.parameter(0),
                function.parameter(1),
                function.parameter(2),
                result_type,
                0,
            );
        }

        pub fn fill(input_index: usize, buffer: []u8) void {
            if (input_index == 1) {
                const values = std.mem.bytesAsSlice(i32, buffer);
                for (values, 0..) |*value, position| value.* = index_values[position];
                return;
            }
            harness.defaultFill(dtype, input_index, buffer);
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const data = std.mem.bytesAsSlice(T, views[0]);
            const indices = std.mem.bytesAsSlice(i32, views[1]);
            const updates = std.mem.bytesAsSlice(T, views[2]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (out, data) |*value, source| value.* = source;
            for (0..4) |position| {
                const target = indices[position];
                if (target < 0 or target >= 6) continue;
                const row: usize = @intCast(target);
                for (0..8) |col| out[row * 8 + col] = updates[position * 8 + col];
            }
        }
    };
}

const BoolMovementOp = enum { transpose, slice, concatenate, pad, gather, scatter };

fn BoolMovement(comptime op: BoolMovementOp) type {
    return struct {
        pub const name = switch (op) {
            .transpose => "transpose_i1_8x16",
            .slice => "slice_i1_16x16",
            .concatenate => "concatenate_i1_64x2",
            .pad => "pad_i1_6x6",
            .gather => "gather_i1_6x8_axis0",
            .scatter => "scatter_i1_6x8_axis0",
        };
        pub const expectation: harness.Expectation = .verified;
        pub const inputs = switch (op) {
            .transpose => [_]harness.Tensor{harness.mat(.i1, 8, 16)},
            .slice => [_]harness.Tensor{harness.mat(.i1, 16, 16)},
            .concatenate => [_]harness.Tensor{ harness.vec(.i1, 64), harness.vec(.i1, 64) },
            .pad => [_]harness.Tensor{harness.mat(.i1, 6, 6)},
            .gather => [_]harness.Tensor{ harness.mat(.i1, 6, 8), harness.vec(.i32, 4) },
            .scatter => [_]harness.Tensor{
                harness.mat(.i1, 6, 8),
                harness.vec(.i32, 4),
                harness.mat(.i1, 4, 8),
            },
        };
        pub const output = switch (op) {
            .transpose => harness.mat(.i1, 16, 8),
            .slice => harness.mat(.i1, 8, 8),
            .concatenate => harness.vec(.i1, 128),
            .pad => harness.mat(.i1, 8, 8),
            .gather => harness.mat(.i1, 4, 8),
            .scatter => harness.mat(.i1, 6, 8),
        };
        pub const tolerance: f32 = 0.0;
        const gather_indices = [_]i32{ 5, 0, 3, 2 };
        const scatter_indices = [_]i32{ 5, 0, 3, 2 };
        const pad_value = true;

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            return switch (op) {
                .transpose => blk: {
                    const result_type = try builder.tensor(.i1, &.{ 16, 8 });
                    break :blk try function.transpose(function.parameter(0), result_type, &.{ 1, 0 });
                },
                .slice => blk: {
                    const result_type = try builder.tensor(.i1, &.{ 8, 8 });
                    break :blk try function.slice(function.parameter(0), result_type, &.{ 2, 4 }, &.{ 10, 12 }, &.{ 1, 1 });
                },
                .concatenate => blk: {
                    const result_type = try builder.tensor(.i1, &.{128});
                    break :blk try function.concatenate(
                        &.{ function.parameter(0), function.parameter(1) },
                        result_type,
                        0,
                    );
                },
                .pad => blk: {
                    const scalar_type = try builder.tensor(.i1, &.{});
                    const result_type = try builder.tensor(.i1, &.{ 8, 8 });
                    const padding = try function.constant(scalar_type, std.mem.asBytes(&pad_value));
                    break :blk try function.pad(
                        function.parameter(0),
                        padding,
                        result_type,
                        &.{ 1, 1 },
                        &.{ 1, 1 },
                        &.{ 0, 0 },
                    );
                },
                .gather => blk: {
                    const result_type = try builder.tensor(.i1, &.{ 4, 8 });
                    break :blk try function.gather(function.parameter(0), function.parameter(1), result_type, 0);
                },
                .scatter => blk: {
                    const result_type = try builder.tensor(.i1, &.{ 6, 8 });
                    break :blk try function.scatter(
                        function.parameter(0),
                        function.parameter(1),
                        function.parameter(2),
                        result_type,
                        0,
                    );
                },
            };
        }

        pub fn fill(input_index: usize, buffer: []u8) void {
            if ((op == .gather or op == .scatter) and input_index == 1) {
                const values = std.mem.bytesAsSlice(i32, buffer);
                const selected = if (op == .gather) gather_indices else scatter_indices;
                for (values, 0..) |*value, position| value.* = selected[position];
                return;
            }
            harness.defaultFill(.i1, input_index, buffer);
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            switch (op) {
                .transpose => {
                    const input = std.mem.bytesAsSlice(bool, views[0]);
                    const out = std.mem.bytesAsSlice(bool, output_bytes);
                    for (0..16) |row| {
                        for (0..8) |col| out[row * 8 + col] = input[col * 16 + row];
                    }
                },
                .slice => {
                    const input = std.mem.bytesAsSlice(bool, views[0]);
                    const out = std.mem.bytesAsSlice(bool, output_bytes);
                    for (0..8) |row| {
                        for (0..8) |col| out[row * 8 + col] = input[(row + 2) * 16 + (col + 4)];
                    }
                },
                .concatenate => {
                    const first = std.mem.bytesAsSlice(bool, views[0]);
                    const second = std.mem.bytesAsSlice(bool, views[1]);
                    const out = std.mem.bytesAsSlice(bool, output_bytes);
                    for (first, 0..) |value, index| out[index] = value;
                    for (second, 0..) |value, index| out[64 + index] = value;
                },
                .pad => {
                    const input = std.mem.bytesAsSlice(bool, views[0]);
                    const out = std.mem.bytesAsSlice(bool, output_bytes);
                    for (0..8) |row| {
                        for (0..8) |col| {
                            const interior = row >= 1 and row < 7 and col >= 1 and col < 7;
                            out[row * 8 + col] = if (interior) input[(row - 1) * 6 + (col - 1)] else pad_value;
                        }
                    }
                },
                .gather => {
                    const data = std.mem.bytesAsSlice(bool, views[0]);
                    const indices = std.mem.bytesAsSlice(i32, views[1]);
                    const out = std.mem.bytesAsSlice(bool, output_bytes);
                    for (0..4) |row| {
                        const source: usize = @intCast(indices[row]);
                        for (0..8) |col| out[row * 8 + col] = data[source * 8 + col];
                    }
                },
                .scatter => {
                    const data = std.mem.bytesAsSlice(bool, views[0]);
                    const indices = std.mem.bytesAsSlice(i32, views[1]);
                    const updates = std.mem.bytesAsSlice(bool, views[2]);
                    const out = std.mem.bytesAsSlice(bool, output_bytes);
                    for (out, data) |*value, source| value.* = source;
                    for (0..4) |position| {
                        const target = indices[position];
                        if (target < 0 or target >= 6) continue;
                        const row: usize = @intCast(target);
                        for (0..8) |col| out[row * 8 + col] = updates[position * 8 + col];
                    }
                },
            }
        }
    };
}

fn boolMovementRows() [6]type {
    return .{
        BoolMovement(.transpose),
        BoolMovement(.slice),
        BoolMovement(.concatenate),
        BoolMovement(.pad),
        BoolMovement(.gather),
        BoolMovement(.scatter),
    };
}

const ReducerKind = enum { sum, max, min };

fn subgroupReduceRequirement() gpu_abi.SubgroupRequirements {
    return .{ .supported = true, .arithmetic = true };
}

fn subgroupScanRequirement() gpu_abi.SubgroupRequirements {
    return .{ .supported = true, .arithmetic = true, .scan = true };
}

fn scatterAddRequiredFeatures(
    comptime dtype: DType,
    comptime variant: accy.kernel.library.indexing.ScatterAddVariant,
) gpu_abi.Features {
    return switch (dtype) {
        .i32 => .{ .atomic_i32 = true },
        .f32 => switch (variant) {
            .direct => .{ .atomic_f32_add_device = true },
            .shared_bins => .{
                .atomic_f32_add_device = true,
                .atomic_f32_add_shared = true,
            },
        },
        else => .{ .unsupported_atomic = true },
    };
}

fn segmentSumRequiredSubgroup(
    comptime granularity: accy.kernel.library.segmented.SegmentSumGranularity,
) gpu_abi.SubgroupRequirements {
    return switch (granularity) {
        .thread => .{},
        .warp => subgroupReduceRequirement(),
    };
}

fn spmvCsrRequiredSubgroup(
    comptime structure: accy.kernel.library.sparse.SpmvCsrStructure,
) gpu_abi.SubgroupRequirements {
    return switch (structure) {
        .row_thread => .{},
        .row_warp => subgroupReduceRequirement(),
    };
}

fn spmvCooRequiredFeatures(
    comptime structure: accy.kernel.library.sparse.SpmvCooStructure,
    comptime dtype: DType,
) gpu_abi.Features {
    if (comptime structure != .element_thread) return .{};
    return switch (dtype) {
        .f32 => .{ .atomic_f32_add_device = true },
        else => .{ .unsupported_atomic = true },
    };
}

fn caseName(comptime op_name: []const u8, comptime dtype: DType, comptime suffix: []const u8) []const u8 {
    @setEvalBranchQuota(200_000);
    return std.fmt.comptimePrint("{s}_{s}_{s}", .{ op_name, @tagName(dtype), suffix });
}

fn arithmeticExpectation(comptime dtype: DType) harness.Expectation {
    return switch (dtype) {
        .f32, .i8, .i16, .i32, .u8, .u16, .u32, .i64, .u64, .f16, .bf16, .f64 => .verified,
        else => .unsupported,
    };
}

fn floatOnlyExpectation(comptime dtype: DType) harness.Expectation {
    if (comptime !dtype.isFloat()) return .invalid;
    return switch (dtype) {
        .f32, .f16 => .verified,
        else => .unsupported,
    };
}

fn shapeExpectation(comptime dtype: DType) harness.Expectation {
    return switch (dtype) {
        .f32, .i8, .i16, .i32, .u8, .u16, .u32, .i64, .u64, .f16, .bf16, .f64 => .verified,
        else => .unsupported,
    };
}

fn computeExpectation(comptime dtype: DType) harness.Expectation {
    return switch (dtype) {
        .f32, .i32, .u32, .f16 => .verified,
        else => .unsupported,
    };
}

fn exactTolerance(comptime dtype: DType) f32 {
    return switch (dtype) {
        .f16 => 0.001,
        .bf16 => 0.01,
        else => 0.0,
    };
}

fn divTolerance(comptime dtype: DType) f32 {
    return switch (dtype) {
        .f32, .f64 => 0.00001,
        .f16 => 0.001,
        .bf16 => 0.01,
        else => 0.0,
    };
}

fn powTolerance(comptime dtype: DType) f32 {
    return switch (dtype) {
        .f32, .f64 => 0.0001,
        .f16 => 0.005,
        .bf16 => 0.05,
        else => 0.0,
    };
}

fn transcendentalTolerance(comptime dtype: DType) f32 {
    return switch (dtype) {
        .f32, .f64 => 0.00001,
        .f16 => 0.005,
        .bf16 => 0.05,
        else => 0.0,
    };
}

fn binaryRowsFor(comptime dtype: DType) [7]type {
    return .{
        Binary(caseName("add", dtype, "256"), dtype, .add, .default, exactTolerance(dtype), arithmeticExpectation(dtype)),
        Binary(caseName("sub", dtype, "256"), dtype, .sub, .default, exactTolerance(dtype), arithmeticExpectation(dtype)),
        Binary(caseName("mul", dtype, "256"), dtype, .mul, .default, exactTolerance(dtype), arithmeticExpectation(dtype)),
        Binary(caseName("div", dtype, "256"), dtype, .div, .rhs_positive, divTolerance(dtype), arithmeticExpectation(dtype)),
        Binary(caseName("min", dtype, "256"), dtype, .min, .default, exactTolerance(dtype), arithmeticExpectation(dtype)),
        Binary(caseName("max", dtype, "256"), dtype, .max, .default, exactTolerance(dtype), arithmeticExpectation(dtype)),
        Binary(caseName("pow", dtype, "256"), dtype, .pow, .lhs_positive, powTolerance(dtype), floatOnlyExpectation(dtype)),
    };
}

fn unaryRowsFor(comptime dtype: DType) [11]type {
    return .{
        Unary(caseName("neg", dtype, "256"), dtype, .neg, .default, exactTolerance(dtype), arithmeticExpectation(dtype)),
        Unary(caseName("abs", dtype, "256"), dtype, .abs, .default, exactTolerance(dtype), arithmeticExpectation(dtype)),
        Unary(caseName("exp", dtype, "256"), dtype, .exp, .default, transcendentalTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("log", dtype, "256"), dtype, .log, .positive, transcendentalTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("sqrt", dtype, "256"), dtype, .sqrt, .positive, transcendentalTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("sin", dtype, "256"), dtype, .sin, .default, transcendentalTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("cos", dtype, "256"), dtype, .cos, .default, transcendentalTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("tanh", dtype, "256"), dtype, .tanh, .default, transcendentalTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("floor", dtype, "256"), dtype, .floor, .default, exactTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("round", dtype, "256"), dtype, .round, .default, exactTolerance(dtype), floatOnlyExpectation(dtype)),
        Unary(caseName("trunc", dtype, "256"), dtype, .trunc, .default, exactTolerance(dtype), floatOnlyExpectation(dtype)),
    };
}

fn Iota(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("iota", dtype, "64");
        pub const expectation = shapeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{};
        pub const output = harness.vec(dtype, 64);
        pub const tolerance: f32 = 0.0;

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{64});
            return try function.iota(result_type, 0);
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            _ = views;
            const T = dtype.ZigType();
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (out, 0..) |*value, index| {
                value.* = iotaValue(dtype, index);
            }
        }
    };
}

fn Transpose(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("transpose", dtype, "8x16");
        pub const expectation = shapeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{harness.mat(dtype, 8, 16)};
        pub const output = harness.mat(dtype, 16, 8);
        pub const tolerance: f32 = 0.0;

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{ 16, 8 });
            return try function.transpose(function.parameter(0), result_type, &.{ 1, 0 });
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const input = std.mem.bytesAsSlice(T, views[0]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (0..16) |row| {
                for (0..8) |col| {
                    out[row * 8 + col] = input[col * 16 + row];
                }
            }
        }
    };
}

fn ReshapeAdd(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("reshape_add", dtype, "4x32");
        pub const expectation = shapeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{
            harness.mat(dtype, 4, 32),
            harness.vec(dtype, 128),
        };
        pub const output = harness.vec(dtype, 128);
        pub const tolerance: f32 = exactTolerance(dtype);

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{128});
            const flat = try function.reshape(function.parameter(0), result_type, &.{128});
            return try function.add(flat, function.parameter(1));
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const matrix = std.mem.bytesAsSlice(T, views[0]);
            const addend = std.mem.bytesAsSlice(T, views[1]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (out, matrix, addend) |*value, a, b| value.* = addReference(T, a, b);
        }
    };
}

fn Slice(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("slice", dtype, "16x16");
        pub const expectation = shapeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{harness.mat(dtype, 16, 16)};
        pub const output = harness.mat(dtype, 8, 8);
        pub const tolerance: f32 = 0.0;

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{ 8, 8 });
            return try function.slice(function.parameter(0), result_type, &.{ 2, 4 }, &.{ 10, 12 }, &.{ 1, 1 });
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const input = std.mem.bytesAsSlice(T, views[0]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (0..8) |row| {
                for (0..8) |col| {
                    out[row * 8 + col] = input[(row + 2) * 16 + (col + 4)];
                }
            }
        }
    };
}

fn Concatenate(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("concatenate", dtype, "64x2");
        pub const expectation = shapeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{
            harness.vec(dtype, 64),
            harness.vec(dtype, 64),
        };
        pub const output = harness.vec(dtype, 128);
        pub const tolerance: f32 = 0.0;

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{128});
            return try function.concatenate(
                &.{ function.parameter(0), function.parameter(1) },
                result_type,
                0,
            );
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const first = std.mem.bytesAsSlice(T, views[0]);
            const second = std.mem.bytesAsSlice(T, views[1]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (first, 0..) |value, index| out[index] = value;
            for (second, 0..) |value, index| out[64 + index] = value;
        }
    };
}

fn Pad(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("pad", dtype, "6x6");
        pub const expectation = shapeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{harness.mat(dtype, 6, 6)};
        pub const output = harness.mat(dtype, 8, 8);
        pub const tolerance: f32 = 0.0;
        const T: type = dtype.ZigType();
        const pad_value: T = literalForDType(dtype, 0.5, 7);

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const scalar_type = try builder.tensor(dtype, &.{});
            const result_type = try builder.tensor(dtype, &.{ 8, 8 });
            const padding = try function.constant(scalar_type, std.mem.asBytes(&pad_value));
            return try function.pad(
                function.parameter(0),
                padding,
                result_type,
                &.{ 1, 1 },
                &.{ 1, 1 },
                &.{ 0, 0 },
            );
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const input = std.mem.bytesAsSlice(T, views[0]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (0..8) |row| {
                for (0..8) |col| {
                    const interior = row >= 1 and row < 7 and col >= 1 and col < 7;
                    out[row * 8 + col] = if (interior) input[(row - 1) * 6 + (col - 1)] else pad_value;
                }
            }
        }
    };
}

fn Gather(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("gather", dtype, "6x8_axis0");
        pub const expectation = shapeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{
            harness.mat(dtype, 6, 8),
            harness.vec(.i32, 4),
        };
        pub const output = harness.mat(dtype, 4, 8);
        pub const tolerance: f32 = 0.0;
        const index_values = [_]i32{ 5, 0, 3, 2 };

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{ 4, 8 });
            return try function.gather(function.parameter(0), function.parameter(1), result_type, 0);
        }

        pub fn fill(input_index: usize, buffer: []u8) void {
            if (input_index == 1) {
                const values = std.mem.bytesAsSlice(i32, buffer);
                for (values, 0..) |*value, position| value.* = index_values[position];
                return;
            }
            harness.defaultFill(dtype, input_index, buffer);
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            const T = dtype.ZigType();
            const data = std.mem.bytesAsSlice(T, views[0]);
            const indices = std.mem.bytesAsSlice(i32, views[1]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (0..4) |row| {
                const source: usize = @intCast(indices[row]);
                for (0..8) |col| out[row * 8 + col] = data[source * 8 + col];
            }
        }
    };
}

fn Reduce(comptime kind: ReducerKind, comptime dtype: DType) type {
    return struct {
        pub const name = caseName("reduce_" ++ @tagName(kind), dtype, "16x16");
        pub const expectation = computeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{harness.mat(dtype, 16, 16)};
        pub const output = harness.vec(dtype, 16);
        pub const tolerance: f32 = switch (kind) {
            .sum => if (dtype == .f32 or dtype == .f64) 0.0001 else exactTolerance(dtype),
            .max, .min => exactTolerance(dtype),
        };
        const T: type = dtype.ZigType();
        const init_value: T = reduceInitValue(dtype, kind);

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const scalar_type = try builder.tensor(dtype, &.{});
            const result_type = try builder.tensor(dtype, &.{16});
            const init = try function.constant(scalar_type, std.mem.asBytes(&init_value));
            return try function.reduce(function.parameter(0), init, result_type, @tagName(kind), &.{1});
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            if (comptime T == f16 or T == Bf16) {
                const input = std.mem.bytesAsSlice(T, views[0]);
                const out = std.mem.bytesAsSlice(T, output_bytes);
                for (0..16) |row| {
                    var acc: f32 = switch (kind) {
                        .sum => 0,
                        .max => -std.math.inf(f32),
                        .min => std.math.inf(f32),
                    };
                    for (0..16) |col| {
                        const value = harness.numericToF32(T, input[row * 16 + col]);
                        acc = switch (kind) {
                            .sum => acc + value,
                            .max => @max(acc, value),
                            .min => @min(acc, value),
                        };
                    }
                    out[row] = floatLikeFromF32(T, acc);
                }
                return;
            }

            const input = std.mem.bytesAsSlice(T, views[0]);
            const out = std.mem.bytesAsSlice(T, output_bytes);
            for (0..16) |row| {
                var acc: T = init_value;
                for (0..16) |col| {
                    const value = input[row * 16 + col];
                    acc = switch (kind) {
                        .sum => acc + value,
                        .max => @max(acc, value),
                        .min => @min(acc, value),
                    };
                }
                out[row] = acc;
            }
        }
    };
}

fn Dot(comptime dtype: DType) type {
    return struct {
        pub const name = caseName("dot_general", dtype, "16x16");
        pub const expectation = computeExpectation(dtype);
        pub const inputs = [_]harness.Tensor{
            harness.mat(dtype, 16, 16),
            harness.mat(dtype, 16, 16),
        };
        pub const output = harness.mat(dtype, 16, 16);
        pub const tolerance: f32 = if (dtype == .f32 or dtype == .f64) 0.0001 else exactTolerance(dtype);

        pub fn body(builder: *SemanticBuilder, function: *FunctionBuilder) !*Value {
            const result_type = try builder.tensor(dtype, &.{ 16, 16 });
            return try function.dotGeneral(
                function.parameter(0),
                function.parameter(1),
                result_type,
                &.{1},
                &.{0},
                &.{},
                &.{},
            );
        }

        pub fn reference(views: []const []const u8, output_bytes: []u8) void {
            dotReference(dtype.ZigType(), views, output_bytes, 16, 16, 16);
        }
    };
}

fn shapeRowsFor(comptime dtype: DType) [8]type {
    return .{
        Iota(dtype),
        Transpose(dtype),
        ReshapeAdd(dtype),
        Slice(dtype),
        Concatenate(dtype),
        Pad(dtype),
        Gather(dtype),
        ScatterCase(caseName("scatter", dtype, "6x8_axis0"), dtype, shapeExpectation(dtype), .{ 5, 0, 3, 2 }),
    };
}

fn computeRowsFor(comptime dtype: DType) [4]type {
    return .{
        Dot(dtype),
        Reduce(.sum, dtype),
        Reduce(.max, dtype),
        Reduce(.min, dtype),
    };
}

fn productRowsFor(comptime dtype: DType) [30]type {
    return binaryRowsFor(dtype) ++ unaryRowsFor(dtype) ++ shapeRowsFor(dtype) ++ computeRowsFor(dtype);
}

fn linalgFamilyBlockCount(extent: u64, threads: u32) u32 {
    return @intCast((extent + threads - 1) / threads);
}

fn linalgFamilySignedPattern(element: usize, comptime modulus: usize, comptime shift: i32) f32 {
    return @floatFromInt(@as(i32, @intCast(element % modulus)) - shift);
}

const MatrixProductFamilyCase = struct {
    const linalg = accy.kernel.library.linalg;
    const instance = linalg.MatrixProduct{
        .m = 5,
        .n = 7,
        .k = 3,
        .threads = .{ .x = 4, .y = 2 },
    };

    pub const name = "matrix_product_family_f32_5x7x3";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.f32, instance.m * instance.n), .access = .inout },
        .{ .tensor = harness.vec(.f32, instance.m * instance.k) },
        .{ .tensor = harness.vec(.f32, instance.k * instance.n) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ linalgFamilyBlockCount(instance.n, instance.threads.x), linalgFamilyBlockCount(instance.m, instance.threads.y), 1 },
        .threadgroup = .{ instance.threads.x, instance.threads.y, 1 },
    };

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                value.* = 0;
            },
            1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element, 7, 3);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element * 2 + 1, 9, 4);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
        return linalg.matrixProductRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try linalg.matrixProductFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try linalg.MatrixProductRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/matrix-product-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        const lhs = std.mem.bytesAsSlice(f32, seeded[1]);
        const rhs = std.mem.bytesAsSlice(f32, seeded[2]);
        const out = std.mem.bytesAsSlice(f32, expected);
        for (0..instance.m) |row| {
            for (0..instance.n) |col| {
                var sum: f32 = 0;
                for (0..instance.k) |offset| {
                    sum += lhs[row * instance.k + offset] * rhs[offset * instance.n + col];
                }
                out[row * instance.n + col] = sum;
            }
        }
    }
};

const BatchedMatrixProductFamilyCase = struct {
    const linalg = accy.kernel.library.linalg;
    const instance = linalg.BatchedMatrixProduct{
        .batch = 3,
        .m = 5,
        .n = 6,
        .k = 4,
        .threads = .{ .x = 4, .y = 2, .z = 2 },
    };

    pub const name = "batched_matrix_product_family_f32_3x5x6x4";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.f32, instance.batch * instance.m * instance.n), .access = .inout },
        .{ .tensor = harness.vec(.f32, instance.batch * instance.m * instance.k) },
        .{ .tensor = harness.vec(.f32, instance.batch * instance.k * instance.n) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{
            linalgFamilyBlockCount(instance.n, instance.threads.x),
            linalgFamilyBlockCount(instance.m, instance.threads.y),
            linalgFamilyBlockCount(instance.batch, instance.threads.z),
        },
        .threadgroup = .{ instance.threads.x, instance.threads.y, instance.threads.z },
    };

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                value.* = 0;
            },
            1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element + 3, 11, 5);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element * 3 + 1, 13, 6);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![4]gpu_abi.ScalarArgument {
        return linalg.batchedMatrixProductRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try linalg.batchedMatrixProductFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try linalg.BatchedMatrixProductRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/batched-matrix-product-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        const lhs = std.mem.bytesAsSlice(f32, seeded[1]);
        const rhs = std.mem.bytesAsSlice(f32, seeded[2]);
        const out = std.mem.bytesAsSlice(f32, expected);
        for (0..instance.batch) |batch| {
            for (0..instance.m) |row| {
                for (0..instance.n) |col| {
                    var sum: f32 = 0;
                    for (0..instance.k) |offset| {
                        const lhs_index = batch * instance.m * instance.k + row * instance.k + offset;
                        const rhs_index = batch * instance.k * instance.n + offset * instance.n + col;
                        sum += lhs[lhs_index] * rhs[rhs_index];
                    }
                    out[batch * instance.m * instance.n + row * instance.n + col] = sum;
                }
            }
        }
    }
};

const MatrixVectorProductFamilyCase = struct {
    const linalg = accy.kernel.library.linalg;
    const instance = linalg.MatrixVectorProduct{
        .m = 5,
        .k = 3,
        .threads = 4,
    };

    pub const name = "matrix_vector_product_family_f32_5x3";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.f32, instance.m), .access = .inout },
        .{ .tensor = harness.vec(.f32, instance.m * instance.k) },
        .{ .tensor = harness.vec(.f32, instance.k) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ linalgFamilyBlockCount(instance.m, instance.threads), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                value.* = 0;
            },
            1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element, 9, 4);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element * 2, 7, 3);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![2]gpu_abi.ScalarArgument {
        return linalg.matrixVectorProductRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try linalg.matrixVectorProductFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try linalg.MatrixVectorProductRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/matrix-vector-product-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        const matrix = std.mem.bytesAsSlice(f32, seeded[1]);
        const vector = std.mem.bytesAsSlice(f32, seeded[2]);
        const out = std.mem.bytesAsSlice(f32, expected);
        for (0..instance.m) |row| {
            var sum: f32 = 0;
            for (0..instance.k) |offset| {
                sum += matrix[row * instance.k + offset] * vector[offset];
            }
            out[row] = sum;
        }
    }
};

const OuterProductFamilyCase = struct {
    const linalg = accy.kernel.library.linalg;
    const instance = linalg.OuterProduct{
        .m = 5,
        .n = 6,
        .threads = .{ .x = 4, .y = 2 },
    };

    pub const name = "outer_product_family_f32_5x6";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.f32, instance.m * instance.n), .access = .inout },
        .{ .tensor = harness.vec(.f32, instance.m) },
        .{ .tensor = harness.vec(.f32, instance.n) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ linalgFamilyBlockCount(instance.n, instance.threads.x), linalgFamilyBlockCount(instance.m, instance.threads.y), 1 },
        .threadgroup = .{ instance.threads.x, instance.threads.y, 1 },
    };

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                value.* = 0;
            },
            1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element, 7, 3);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                value.* = linalgFamilySignedPattern(element * 2 + 1, 9, 4);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![2]gpu_abi.ScalarArgument {
        return linalg.outerProductRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try linalg.outerProductFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try linalg.OuterProductRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/outer-product-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        const lhs = std.mem.bytesAsSlice(f32, seeded[1]);
        const rhs = std.mem.bytesAsSlice(f32, seeded[2]);
        const out = std.mem.bytesAsSlice(f32, expected);
        for (0..instance.m) |row| {
            for (0..instance.n) |col| {
                out[row * instance.n + col] = lhs[row] * rhs[col];
            }
        }
    }
};

fn GatherFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
) type {
    return struct {
        const indexing = accy.kernel.library.indexing;
        const T: type = case_dtype.ZigType();
        const outer = 2;
        const axis_size = 5;
        const gathered = 6;
        const inner = 3;
        const threads = 32;
        const instance = indexing.Gather{
            .outer = outer,
            .axis_size = axis_size,
            .gathered = gathered,
            .inner = inner,
            .dtype = case_dtype,
            .threads = threads,
        };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, instance.total()), .access = .inout },
            .{ .tensor = harness.vec(case_dtype, outer * axis_size * inner) },
            .{ .tensor = harness.vec(.i32, gathered) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ blockCount(), 1, 1 },
            .threadgroup = .{ threads, 1, 1 },
        };

        fn blockCount() u32 {
            return @intCast((instance.total() + instance.threads - 1) / instance.threads);
        }

        fn dataAt(element: usize) T {
            return @floatFromInt(element * 2 + 1);
        }

        fn indexAt(position: usize) i32 {
            const indices = [_]i32{ 4, 1, -2, 3, 7, 0 };
            return indices[position];
        }

        fn clampIndex(index: i32) usize {
            if (index <= 0) return 0;
            return @min(@as(usize, @intCast(index)), axis_size - 1);
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => for (std.mem.bytesAsSlice(T, buffer)) |*value| {
                    value.* = @floatFromInt(0);
                },
                1 => for (std.mem.bytesAsSlice(T, buffer), 0..) |*value, element| {
                    value.* = dataAt(element);
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, position| {
                    value.* = indexAt(position);
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![5]gpu_abi.ScalarArgument {
            return indexing.gatherRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try indexing.gatherFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .f32 => try indexing.GatherRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try indexing.GatherRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => unreachable,
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/gather-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded[0];
            const data = std.mem.bytesAsSlice(T, seeded[1]);
            const indices = std.mem.bytesAsSlice(i32, seeded[2]);
            const out = std.mem.bytesAsSlice(T, expected);
            for (0..outer) |outer_index| {
                for (0..gathered) |position| {
                    const source_axis = clampIndex(indices[position]);
                    for (0..inner) |within| {
                        const output = outer_index * gathered * inner + position * inner + within;
                        const source = outer_index * axis_size * inner + source_axis * inner + within;
                        out[output] = data[source];
                    }
                }
            }
        }
    };
}

fn ScatterFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
) type {
    return struct {
        const indexing = accy.kernel.library.indexing;
        const T: type = case_dtype.ZigType();
        const outer = 2;
        const axis_size = 5;
        const updates = 6;
        const inner = 3;
        const threads = 32;
        const instance = indexing.Scatter{
            .outer = outer,
            .axis_size = axis_size,
            .updates = updates,
            .inner = inner,
            .dtype = case_dtype,
            .threads = threads,
        };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, instance.total()), .access = .inout },
            .{ .tensor = harness.vec(case_dtype, instance.total()) },
            .{ .tensor = harness.vec(.i32, updates) },
            .{ .tensor = harness.vec(case_dtype, outer * updates * inner) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ blockCount(), 1, 1 },
            .threadgroup = .{ threads, 1, 1 },
        };

        fn blockCount() u32 {
            return @intCast((instance.total() + instance.threads - 1) / instance.threads);
        }

        fn dataAt(element: usize) T {
            return @floatFromInt(element + 10);
        }

        fn updateAt(element: usize) T {
            return @floatFromInt(element + 100);
        }

        fn indexAt(position: usize) i32 {
            const indices = [_]i32{ 4, 1, -2, 1, 6, 0 };
            return indices[position];
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => for (std.mem.bytesAsSlice(T, buffer)) |*value| {
                    value.* = @floatFromInt(0);
                },
                1 => for (std.mem.bytesAsSlice(T, buffer), 0..) |*value, element| {
                    value.* = dataAt(element);
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, position| {
                    value.* = indexAt(position);
                },
                3 => for (std.mem.bytesAsSlice(T, buffer), 0..) |*value, element| {
                    value.* = updateAt(element);
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![5]gpu_abi.ScalarArgument {
            return indexing.scatterRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try indexing.scatterFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .f32 => try indexing.ScatterRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try indexing.ScatterRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => unreachable,
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/scatter-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded[0];
            const data = std.mem.bytesAsSlice(T, seeded[1]);
            const indices = std.mem.bytesAsSlice(i32, seeded[2]);
            const update_values = std.mem.bytesAsSlice(T, seeded[3]);
            const out = std.mem.bytesAsSlice(T, expected);
            for (out, data) |*value, initial| value.* = initial;
            for (0..outer) |outer_index| {
                for (0..updates) |update_position| {
                    const target = indices[update_position];
                    if (target < 0 or target >= axis_size) continue;
                    const target_axis: usize = @intCast(target);
                    for (0..inner) |within| {
                        const output = outer_index * axis_size * inner + target_axis * inner + within;
                        const update = outer_index * updates * inner + update_position * inner + within;
                        out[output] = update_values[update];
                    }
                }
            }
        }
    };
}

fn ScatterAddFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
    comptime case_variant: accy.kernel.library.indexing.ScatterAddVariant,
    comptime case_tolerance: f32,
) type {
    return struct {
        const indexing = accy.kernel.library.indexing;
        const bin_count = 16;
        const update_count = 64;
        const instance = indexing.ScatterAdd{
            .axis_size = bin_count,
            .updates = update_count,
            .dtype = case_dtype,
            .variant = case_variant,
            .threads = 32,
        };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = case_tolerance;
        pub const required_features = scatterAddRequiredFeatures(case_dtype, case_variant);
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, bin_count), .access = .inout },
            .{ .tensor = harness.vec(case_dtype, bin_count) },
            .{ .tensor = harness.vec(.i32, update_count) },
            .{ .tensor = harness.vec(case_dtype, update_count) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ update_count / 32, 1, 1 },
            .threadgroup = .{ 32, 1, 1 },
        };

        fn indexAt(update: usize) i32 {
            if (update == 7) return -3;
            if (update == 13) return bin_count + 4;
            return @intCast((update * 5 + 3) % bin_count);
        }

        fn updateAt(comptime T: type, update: usize) T {
            return switch (@typeInfo(T)) {
                .int => @intCast((update % 11) + 1),
                else => 0.25 + @as(T, @floatFromInt(update % 11)) * 0.5,
            };
        }

        fn seedAt(comptime T: type, bin: usize) T {
            return switch (@typeInfo(T)) {
                .int => @intCast(bin % 3),
                else => @as(T, @floatFromInt(bin % 3)) * 0.5,
            };
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0, 1 => switch (case_dtype) {
                    .i32 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, bin| {
                        value.* = seedAt(i32, bin);
                    },
                    .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, bin| {
                        value.* = seedAt(f32, bin);
                    },
                    else => unreachable,
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, update| {
                    value.* = indexAt(update);
                },
                3 => switch (case_dtype) {
                    .i32 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, update| {
                        value.* = updateAt(i32, update);
                    },
                    .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, update| {
                        value.* = updateAt(f32, update);
                    },
                    else => unreachable,
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![5]gpu_abi.ScalarArgument {
            return indexing.scatterAddRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try indexing.scatterAddFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .i32 => try indexing.ScatterAddRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f32 => try indexing.ScatterAddRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => unreachable,
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/scatter-add-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            switch (case_dtype) {
                .i32 => referenceTyped(i32, seeded, expected),
                .f32 => referenceTyped(f32, seeded, expected),
                else => unreachable,
            }
        }

        fn referenceTyped(comptime T: type, seeded: []const []const u8, expected: []u8) void {
            const dst = std.mem.bytesAsSlice(T, expected);
            const seed = std.mem.bytesAsSlice(T, seeded[0]);
            for (dst, seed) |*value, initial| value.* = initial;
            const indices = std.mem.bytesAsSlice(i32, seeded[2]);
            const updates = std.mem.bytesAsSlice(T, seeded[3]);
            for (indices, updates) |index, update| {
                if (index < 0 or index >= bin_count) continue;
                switch (@typeInfo(T)) {
                    .int => dst[@intCast(index)] +%= update,
                    else => dst[@intCast(index)] += update,
                }
            }
        }
    };
}

fn PrefixSumFamilyCase(
    comptime case_name: []const u8,
    comptime dtype: DType,
    comptime case_mode: accy.kernel.library.scan.PrefixSumMode,
) type {
    return struct {
        const scan = accy.kernel.library.scan;
        const extent = 64;
        const instance = scan.PrefixSum{
            .extent = extent,
            .dtype = dtype,
            .mode = case_mode,
            .threads = 64,
        };
        const Data: type = dtype.ZigType();

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const required_subgroup = subgroupScanRequirement();
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(dtype, extent), .access = .inout },
            .{ .tensor = harness.vec(dtype, extent) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ 1, 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            const values = std.mem.bytesAsSlice(Data, buffer);
            switch (index) {
                0 => for (values) |*value| {
                    value.* = numericLikeFromF32(Data, 0);
                },
                1 => for (values, 0..) |*value, element| {
                    value.* = numericLikeFromF32(Data, @floatFromInt((element % 7) + 1));
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
            return scan.prefixSumRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try scan.prefixSumFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (dtype) {
                .f32 => try scan.PrefixSumRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try scan.PrefixSumRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                .u32 => try scan.PrefixSumRuntimeFamilyU32.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported prefix sum conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/prefix-sum-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            const data = std.mem.bytesAsSlice(Data, seeded[1]);
            const out = std.mem.bytesAsSlice(Data, expected);
            var running: Data = numericLikeFromF32(Data, 0);
            for (out, data) |*value, element| {
                switch (case_mode) {
                    .inclusive => {
                        running += element;
                        value.* = running;
                    },
                    .exclusive => {
                        value.* = running;
                        running += element;
                    },
                }
            }
        }
    };
}

fn SegmentSumFamilyCase(
    comptime case_name: []const u8,
    comptime case_granularity: accy.kernel.library.segmented.SegmentSumGranularity,
) type {
    return struct {
        const segmented = accy.kernel.library.segmented;
        const segments = 8;
        const total = 80;
        const threads = 64;
        const instance = segmented.SegmentSum{
            .segments = segments,
            .total = total,
            .granularity = case_granularity,
            .threads = threads,
        };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const required_subgroup = segmentSumRequiredSubgroup(case_granularity);
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(.f32, segments), .access = .inout },
            .{ .tensor = harness.vec(.f32, total) },
            .{ .tensor = harness.vec(.i32, segments + 1) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ blockCount(), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        fn blockCount() u32 {
            const extent = instance.launchExtent();
            return @intCast((extent + instance.threads - 1) / instance.threads);
        }

        fn dataAt(element: usize) f32 {
            const magnitude: f32 = @floatFromInt((element % 11) + 1);
            return if (element % 2 == 0) magnitude else -magnitude;
        }

        fn offsetAt(segment_boundary: usize) i32 {
            const offsets = [_]i32{ -3, 4, 4, 17, 65, 90, 72, 80, 120 };
            return offsets[segment_boundary];
        }

        fn clampOffset(offset: i32, upper: usize) usize {
            if (offset <= 0) return 0;
            return @min(@as(usize, @intCast(offset)), upper);
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                    value.* = -999;
                },
                1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                    value.* = dataAt(element);
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, segment_boundary| {
                    value.* = offsetAt(segment_boundary);
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![2]gpu_abi.ScalarArgument {
            return segmented.segmentSumRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try segmented.segmentSumFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = try segmented.SegmentSumRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/segment-sum-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            const data = std.mem.bytesAsSlice(f32, seeded[1]);
            const offsets = std.mem.bytesAsSlice(i32, seeded[2]);
            const out = std.mem.bytesAsSlice(f32, expected);
            for (out, 0..) |*value, segment| {
                const end = clampOffset(offsets[segment + 1], total);
                const begin = @min(clampOffset(offsets[segment], total), end);
                var sum: f32 = 0;
                for (begin..end) |element| sum += data[element];
                value.* = sum;
            }
        }
    };
}

fn FilterFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
    comptime case_predicate: accy.kernel.library.entry.CompactionPredicate,
) type {
    return struct {
        const compaction = accy.kernel.library.compaction;
        const extent = if (case_dtype == .f32) 70 else 40;
        const threads = 32;
        const blocks = (extent + threads - 1) / threads;
        const padded = extent + blocks;
        const instance = compaction.Filter{
            .extent = extent,
            .dtype = case_dtype,
            .predicate = case_predicate,
            .threads = threads,
        };
        const RuntimeArguments: type = if (case_predicate == .nonzero)
            [1]gpu_abi.ScalarArgument
        else
            [2]gpu_abi.ScalarArgument;

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const required_subgroup = subgroupScanRequirement();
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, padded), .access = .inout },
            .{ .tensor = harness.vec(case_dtype, extent) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ blocks, 1, 1 },
            .threadgroup = .{ threads, 1, 1 },
        };

        fn dataAtF32(element: usize) f32 {
            if (element % 9 == 0) return 0;
            const magnitude: f32 = @floatFromInt((element % 7) + 1);
            return if (element % 2 == 0) magnitude else -magnitude * 0.5;
        }

        fn dataAtI32(element: usize) i32 {
            if (element % 5 == 0) return 0;
            const raw: i32 = @intCast((element * 7 + 5) % 17);
            return raw - 6;
        }

        fn seedAtF32(element: usize) f32 {
            return -777.0 - @as(f32, @floatFromInt(element % 5)) * 0.125;
        }

        fn seedAtI32(element: usize) i32 {
            return -777 - @as(i32, @intCast(element % 5));
        }

        fn thresholdArgument() gpu_abi.ScalarArgument {
            return switch (case_dtype) {
                .f32 => .{ .f32 = 0.5 },
                .i32 => .{ .i32 = 3 },
                else => unreachable,
            };
        }

        fn seededSlice(comptime T: type, bytes: []const u8) []const T {
            const aligned: []align(@alignOf(T)) const u8 = @alignCast(bytes);
            return std.mem.bytesAsSlice(T, aligned);
        }

        fn expectedSlice(comptime T: type, bytes: []u8) []T {
            const aligned: []align(@alignOf(T)) u8 = @alignCast(bytes);
            return std.mem.bytesAsSlice(T, aligned);
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => switch (case_dtype) {
                    .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                        value.* = seedAtF32(element);
                    },
                    .i32 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                        value.* = seedAtI32(element);
                    },
                    else => unreachable,
                },
                1 => switch (case_dtype) {
                    .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                        value.* = dataAtF32(element);
                    },
                    .i32 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                        value.* = dataAtI32(element);
                    },
                    else => unreachable,
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() !RuntimeArguments {
            if (case_predicate == .nonzero) return compaction.filterRuntimeArguments(instance);
            return compaction.filterGreaterRuntimeArguments(instance, thresholdArgument());
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try compaction.filterFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_predicate) {
                .nonzero => switch (case_dtype) {
                    .f32 => try compaction.FilterRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                    .i32 => try compaction.FilterRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance),
                    else => unreachable,
                },
                .greater_than => switch (case_dtype) {
                    .f32 => try compaction.FilterGreaterRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                    .i32 => try compaction.FilterGreaterRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance),
                    else => unreachable,
                },
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/filter-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            @memcpy(expected, seeded[0]);
            switch (case_predicate) {
                .nonzero => switch (case_dtype) {
                    .f32 => compaction.filterBlocksExpectedF32(
                        seededSlice(f32, seeded[1]),
                        threads,
                        expectedSlice(f32, expected),
                    ),
                    .i32 => compaction.filterBlocksExpectedI32(
                        seededSlice(i32, seeded[1]),
                        threads,
                        expectedSlice(i32, expected),
                    ),
                    else => unreachable,
                },
                .greater_than => switch (case_dtype) {
                    .f32 => compaction.filterBlocksGreaterExpectedF32(
                        seededSlice(f32, seeded[1]),
                        threads,
                        thresholdArgument().f32,
                        expectedSlice(f32, expected),
                    ),
                    .i32 => compaction.filterBlocksGreaterExpectedI32(
                        seededSlice(i32, seeded[1]),
                        threads,
                        thresholdArgument().i32,
                        expectedSlice(i32, expected),
                    ),
                    else => unreachable,
                },
            }
        }
    };
}

const BitonicBlockFamilyCase = struct {
    const sort = accy.kernel.library.sort;
    const extent = 45;
    const threads = 64;
    const instance = sort.BitonicBlock{
        .extent = extent,
        .threads = threads,
    };

    pub const name = "bitonic_block_family_i32_45x64";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, extent), .access = .inout },
        .{ .tensor = harness.vec(.i32, extent) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ 1, 1, 1 },
        .threadgroup = .{ threads, 1, 1 },
    };

    fn keyAt(element: usize) i32 {
        const raw: i32 = @intCast((element * 37 + 11) % 53);
        return if (element % 3 == 0) -raw else raw - 19;
    }

    fn seededSlice(comptime T: type, bytes: []const u8) []const T {
        const aligned: []align(@alignOf(T)) const u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(T, aligned);
    }

    fn expectedSlice(comptime T: type, bytes: []u8) []T {
        const aligned: []align(@alignOf(T)) u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(T, aligned);
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                value.* = -5000 - @as(i32, @intCast(element));
            },
            1 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                value.* = keyAt(element);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
        return sort.bitonicBlockRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try sort.bitonicBlockFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try sort.BitonicBlockRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/bitonic-block-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        @memcpy(expected, seeded[0]);
        const keys = seededSlice(i32, seeded[1]);
        const out = expectedSlice(i32, expected);
        @memcpy(out, keys);
        std.mem.sort(i32, out, {}, std.sort.asc(i32));
    }
};

const TopKBlockFamilyCase = struct {
    const sort = accy.kernel.library.sort;
    const extent = 45;
    const top_count = 8;
    const threads = 64;
    const instance = sort.TopKBlock{
        .extent = extent,
        .k = top_count,
        .threads = threads,
    };

    pub const name = "top_k_block_family_i32_8of45x64";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, top_count), .access = .inout },
        .{ .tensor = harness.vec(.i32, extent) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ 1, 1, 1 },
        .threadgroup = .{ threads, 1, 1 },
    };

    fn keyAt(element: usize) i32 {
        const raw: i32 = @intCast((element * 41 + 5) % 67);
        return if (element % 4 == 0) -raw else raw - 23;
    }

    fn seededSlice(comptime T: type, bytes: []const u8) []const T {
        const aligned: []align(@alignOf(T)) const u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(T, aligned);
    }

    fn expectedSlice(comptime T: type, bytes: []u8) []T {
        const aligned: []align(@alignOf(T)) u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(T, aligned);
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                value.* = -9000 - @as(i32, @intCast(element));
            },
            1 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                value.* = keyAt(element);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
        return sort.topKBlockRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try sort.topKBlockFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try sort.TopKBlockRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/top-k-block-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        @memcpy(expected, seeded[0]);
        const keys = seededSlice(i32, seeded[1]);
        const out = expectedSlice(i32, expected);
        var sorted: [extent]i32 = undefined;
        @memcpy(sorted[0..], keys);
        std.mem.sort(i32, sorted[0..], {}, std.sort.asc(i32));
        @memcpy(out, sorted[0..top_count]);
    }
};

fn TopKBlockPairsFamilyCase(
    comptime case_name: []const u8,
    comptime case_observed: usize,
) type {
    return struct {
        const sort = accy.kernel.library.sort;
        const extent = 45;
        const top_count = 8;
        const threads = 64;
        const instance = sort.TopKBlockPairs{
            .extent = extent,
            .k = top_count,
            .threads = threads,
        };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(.i32, top_count), .access = .inout },
            .{ .tensor = harness.vec(.i32, top_count), .access = .inout },
            .{ .tensor = harness.vec(.i32, extent) },
            .{ .tensor = harness.vec(.i32, extent) },
        };
        pub const observed: usize = case_observed;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ 1, 1, 1 },
            .threadgroup = .{ threads, 1, 1 },
        };

        fn keyAt(element: usize) i32 {
            const raw: i32 = @intCast((element * 41 + 5) % 23);
            return if (element % 4 == 0) -raw else raw - 11;
        }

        fn seededSlice(comptime T: type, bytes: []const u8) []const T {
            const aligned: []align(@alignOf(T)) const u8 = @alignCast(bytes);
            return std.mem.bytesAsSlice(T, aligned);
        }

        fn expectedSlice(comptime T: type, bytes: []u8) []T {
            const aligned: []align(@alignOf(T)) u8 = @alignCast(bytes);
            return std.mem.bytesAsSlice(T, aligned);
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0, 1 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                    value.* = -9100 - @as(i32, @intCast(index * 100 + element));
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                    value.* = keyAt(element);
                },
                3 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                    value.* = @intCast(element);
                },
                else => unreachable,
            }
            if (index == 2) {
                const values = std.mem.bytesAsSlice(i32, buffer);
                values[7] = values[4];
                values[13] = values[4];
                values[29] = std.math.minInt(i32);
            }
        }

        pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
            return sort.topKBlockPairsRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try sort.topKBlockPairsFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = try sort.TopKBlockPairsRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance);
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/top-k-block-pairs-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            @memcpy(expected, seeded[case_observed]);
            const keys = seededSlice(i32, seeded[2]);
            const values = seededSlice(i32, seeded[3]);
            const out = expectedSlice(i32, expected);
            const Pair = struct {
                key: i32,
                value: i32,

                fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
                    return lhs.key < rhs.key or (lhs.key == rhs.key and lhs.value < rhs.value);
                }
            };
            var sorted: [extent]Pair = undefined;
            for (&sorted, keys, values) |*pair, key, value| pair.* = .{ .key = key, .value = value };
            std.mem.sort(Pair, sorted[0..], {}, Pair.lessThan);
            for (out, sorted[0..top_count]) |*slot, pair| {
                slot.* = if (case_observed == 0) pair.key else pair.value;
            }
        }
    };
}

fn deviceScanConformanceAccumulatorDType(comptime dtype: DType) DType {
    return switch (dtype) {
        .f16, .f32 => .f32,
        .u32 => .u32,
        else => @compileError("unsupported device scan conformance dtype"),
    };
}

fn DeviceScanBlockScanFamilyCase(
    comptime case_name: []const u8,
    comptime dtype: DType,
    comptime case_observed: usize,
) type {
    return struct {
        const scan = accy.kernel.library.scan;
        const extent = 90;
        const threads = 32;
        const blocks = 3;
        const instance = scan.DeviceScan{ .extent = extent, .dtype = dtype, .threads = threads };
        const Out: type = deviceScanBlockScanConformanceOutputDType(dtype).ZigType();
        const Data: type = dtype.ZigType();
        const Sum: type = deviceScanConformanceAccumulatorDType(dtype).ZigType();

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = if (dtype == .f16) 0.001 else 0;
        pub const required_subgroup = subgroupScanRequirement();
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(deviceScanBlockScanConformanceOutputDType(dtype), extent), .access = .inout },
            .{ .tensor = harness.vec(dtype, extent) },
            .{ .tensor = harness.vec(deviceScanConformanceAccumulatorDType(dtype), blocks), .access = .inout },
        };
        pub const observed: usize = case_observed;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ blocks, 1, 1 },
            .threadgroup = .{ threads, 1, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => {
                    const values = std.mem.bytesAsSlice(Out, buffer);
                    for (values) |*value| value.* = numericLikeFromF32(Out, 0);
                },
                1 => {
                    const values = std.mem.bytesAsSlice(Data, buffer);
                    for (values, 0..) |*value, element| {
                        value.* = numericLikeFromF32(Data, @floatFromInt((element % 7) + 1));
                    }
                },
                2 => {
                    const values = std.mem.bytesAsSlice(Sum, buffer);
                    for (values) |*value| value.* = numericLikeFromF32(Sum, 0);
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
            return scan.deviceScanRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try scan.deviceScanBlockScanFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (dtype) {
                .f32 => try scan.DeviceScanBlockScanRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try scan.DeviceScanBlockScanRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                .u32 => try scan.DeviceScanBlockScanRuntimeFamilyU32.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported device scan conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/device-scan-block-scan-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            const data = std.mem.bytesAsSlice(Data, seeded[1]);
            const out = std.mem.bytesAsSlice(Out, expected);
            switch (case_observed) {
                0 => {
                    var running: f32 = 0;
                    for (out, data, 0..) |*value, element, index| {
                        if (index % threads == 0) running = 0;
                        running += harness.numericToF32(Data, element);
                        value.* = numericLikeFromF32(Out, running);
                    }
                },
                2 => for (out, 0..) |*value, block| {
                    var total: f32 = 0;
                    const begin = block * threads;
                    const end = @min(begin + threads, extent);
                    for (data[begin..end]) |element| total += harness.numericToF32(Data, element);
                    value.* = numericLikeFromF32(Out, total);
                },
                else => unreachable,
            }
        }
    };
}

fn deviceScanBlockScanConformanceOutputDType(comptime dtype: DType) DType {
    return deviceScanConformanceAccumulatorDType(dtype);
}

fn DeviceScanAddBaseFamilyCase(
    comptime case_name: []const u8,
    comptime dtype: DType,
) type {
    return struct {
        const scan = accy.kernel.library.scan;
        const extent = 90;
        const threads = 32;
        const blocks = 3;
        const instance = scan.DeviceScan{ .extent = extent, .dtype = dtype, .threads = threads };
        const Out: type = dtype.ZigType();
        const Base: type = deviceScanConformanceAccumulatorDType(dtype).ZigType();

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = if (dtype == .f16) 0.001 else 0;
        pub const buffers = switch (dtype) {
            .f32, .u32 => [_]harness.FamilyBuffer{
                .{ .tensor = harness.vec(dtype, extent), .access = .inout },
                .{ .tensor = harness.vec(deviceScanConformanceAccumulatorDType(dtype), blocks) },
            },
            .f16 => [_]harness.FamilyBuffer{
                .{ .tensor = harness.vec(.f16, extent), .access = .inout },
                .{ .tensor = harness.vec(.f32, extent) },
                .{ .tensor = harness.vec(.f32, blocks) },
            },
            else => @compileError("unsupported device scan conformance dtype"),
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ blocks, 1, 1 },
            .threadgroup = .{ threads, 1, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (dtype) {
                .f32, .u32 => {
                    const T = if (index == 0) Out else Base;
                    const values = std.mem.bytesAsSlice(T, buffer);
                    switch (index) {
                        0 => for (values, 0..) |*value, element| {
                            value.* = numericLikeFromF32(T, @floatFromInt((element % 5) + 1));
                        },
                        1 => for (values, 0..) |*value, block| {
                            value.* = numericLikeFromF32(T, @floatFromInt(block * 10));
                        },
                        else => unreachable,
                    }
                },
                .f16 => switch (index) {
                    0 => {
                        const values = std.mem.bytesAsSlice(f16, buffer);
                        for (values) |*value| value.* = 0;
                    },
                    1 => {
                        const values = std.mem.bytesAsSlice(f32, buffer);
                        for (values, 0..) |*value, element| {
                            value.* = @floatFromInt((element % 5) + 1);
                        }
                    },
                    2 => {
                        const values = std.mem.bytesAsSlice(f32, buffer);
                        for (values, 0..) |*value, block| {
                            value.* = @floatFromInt(block * 10);
                        }
                    },
                    else => unreachable,
                },
                else => @compileError("unsupported device scan conformance dtype"),
            }
        }

        pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
            return scan.deviceScanRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try scan.deviceScanAddBaseFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (dtype) {
                .f32 => try scan.DeviceScanAddBaseRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try scan.DeviceScanAddBaseRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                .u32 => try scan.DeviceScanAddBaseRuntimeFamilyU32.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported device scan conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/device-scan-add-base-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            const out = std.mem.bytesAsSlice(Out, expected);
            switch (dtype) {
                .f32, .u32 => {
                    const seed_dst = std.mem.bytesAsSlice(Out, seeded[0]);
                    const base = std.mem.bytesAsSlice(Base, seeded[1]);
                    for (out, seed_dst, 0..) |*value, initial, index| {
                        value.* = numericLikeFromF32(
                            Out,
                            harness.numericToF32(Out, initial) + harness.numericToF32(Base, base[index / threads]),
                        );
                    }
                },
                .f16 => {
                    const local = std.mem.bytesAsSlice(f32, seeded[1]);
                    const base = std.mem.bytesAsSlice(f32, seeded[2]);
                    for (out, local, 0..) |*value, prefix, index| {
                        value.* = floatLikeFromF32(Out, prefix + base[index / threads]);
                    }
                },
                else => @compileError("unsupported device scan conformance dtype"),
            }
        }
    };
}

fn SpmvCsrFamilyCase(
    comptime case_name: []const u8,
    comptime case_structure: accy.kernel.library.sparse.SpmvCsrStructure,
    comptime case_dtype: DType,
) type {
    return struct {
        const sparse = accy.kernel.library.sparse;
        const rows = 48;
        const max_row_nnz = 6;
        const nnz = total_nnz;
        const cols_n = 32;
        const instance = sparse.SpmvCsr{
            .rows = rows,
            .dtype = case_dtype,
            .accumulation_dtype = sparse.spmvCsrAccumulationDType(case_dtype).?,
            .threads = 64,
            .structure = case_structure,
        };

        const total_nnz = blk: {
            var count: usize = 0;
            for (0..rows) |row| count += rowNnz(row);
            break :blk count;
        };

        fn rowNnz(row: usize) usize {
            return switch (row % 4) {
                0 => 0,
                1 => 2,
                2 => max_row_nnz,
                else => 3,
            };
        }

        fn rowBegin(row: usize) usize {
            var count: usize = 0;
            for (0..row) |prior| count += rowNnz(prior);
            return count;
        }

        fn colAt(element: usize) i32 {
            return @intCast((element * 7 + 3) % cols_n);
        }

        fn valueAt(element: usize) f32 {
            return @floatFromInt((element % 9) + 1);
        }

        fn xAt(index: usize) f32 {
            return @floatFromInt((index % 5) + 1);
        }

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = if (case_dtype == .f16) 0.001 else 0;
        pub const required_subgroup = spmvCsrRequiredSubgroup(case_structure);
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, rows), .access = .inout },
            .{ .tensor = harness.vec(.i32, rows + 1) },
            .{ .tensor = harness.vec(.i32, nnz) },
            .{ .tensor = harness.vec(case_dtype, nnz) },
            .{ .tensor = harness.vec(case_dtype, cols_n) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(sparse.spmvCsrBlockCount(instance)), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => fillFloatBuffer(buffer, -1),
                1 => {
                    const row_ptr = std.mem.bytesAsSlice(i32, buffer);
                    for (row_ptr, 0..) |*value, row| value.* = @intCast(rowBegin(row));
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                    value.* = colAt(element);
                },
                3 => fillIndexedFloatBuffer(buffer, valueAt),
                4 => fillIndexedFloatBuffer(buffer, xAt),
                else => unreachable,
            }
        }

        fn fillFloatBuffer(buffer: []u8, value: f32) void {
            switch (case_dtype) {
                .f64 => {
                    for (std.mem.bytesAsSlice(f64, buffer)) |*item| item.* = @floatCast(value);
                },
                .f32 => {
                    for (std.mem.bytesAsSlice(f32, buffer)) |*item| item.* = value;
                },
                .f16 => {
                    for (std.mem.bytesAsSlice(f16, buffer)) |*item| item.* = @floatCast(value);
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        fn fillIndexedFloatBuffer(buffer: []u8, comptime valueFn: fn (usize) f32) void {
            switch (case_dtype) {
                .f64 => for (std.mem.bytesAsSlice(f64, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, index| {
                    value.* = valueFn(index);
                },
                .f16 => for (std.mem.bytesAsSlice(f16, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
            return sparse.spmvCsrRuntimeArguments(instance, nnz, cols_n);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try sparse.spmvCsrFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .f64 => try sparse.SpmvCsrRuntimeFamilyF64.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f32 => try sparse.SpmvCsrRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try sparse.SpmvCsrRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported sparse conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/spmv-csr-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            for (0..rows) |row| {
                var sum: f32 = 0;
                const begin = rowBegin(row);
                const end = begin + rowNnz(row);
                for (begin..end) |element| {
                    sum += valueAt(element) * xAt(@intCast(colAt(element)));
                }
                setExpected(expected, row, sum);
            }
        }

        fn setExpected(expected: []u8, row: usize, value: f32) void {
            switch (case_dtype) {
                .f64 => std.mem.bytesAsSlice(f64, expected)[row] = @floatCast(value),
                .f32 => std.mem.bytesAsSlice(f32, expected)[row] = value,
                .f16 => std.mem.bytesAsSlice(f16, expected)[row] = @floatCast(value),
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }
    };
}

fn SpmvCooFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
) type {
    return struct {
        const sparse = accy.kernel.library.sparse;
        const rows = 48;
        const nnz = 96;
        const x_extent = 32;
        const instance = sparse.SpmvCoo{
            .rows = rows,
            .nnz = nnz,
            .x_extent = x_extent,
            .dtype = case_dtype,
            .accumulation_dtype = sparse.spmvCooAccumulationDType(case_dtype).?,
            .threads = 64,
            .structure = sparse.spmvCooDefaultStructure(case_dtype).?,
        };

        fn rowAt(element: usize) i32 {
            if (element == 5) return -2;
            if (element == 17) return @intCast(rows + 4);
            if (element == 24 or element == 25) return 4;
            return @intCast((element * 5 + 2) % rows);
        }

        fn colAt(element: usize) i32 {
            if (element == 11) return -3;
            if (element == 29) return @intCast(x_extent + 2);
            if (element == 24 or element == 25) return 6;
            return @intCast((element * 7 + 3) % x_extent);
        }

        fn valueAt(element: usize) f32 {
            return 0.25 + @as(f32, @floatFromInt(element % 11)) * 0.5;
        }

        fn xAt(index: usize) f32 {
            return @floatFromInt((index % 5) + 1);
        }

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = if (case_dtype == .f16) 0.001 else 0;
        pub const required_features = spmvCooRequiredFeatures(instance.structure, case_dtype);
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, rows), .access = .inout },
            .{ .tensor = harness.vec(.i32, nnz) },
            .{ .tensor = harness.vec(.i32, nnz) },
            .{ .tensor = harness.vec(case_dtype, nnz) },
            .{ .tensor = harness.vec(case_dtype, x_extent) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(sparse.spmvCooBlockCount(instance)), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => fillFloatBuffer(buffer, 0),
                1 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                    value.* = rowAt(element);
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                    value.* = colAt(element);
                },
                3 => fillIndexedFloatBuffer(buffer, valueAt),
                4 => fillIndexedFloatBuffer(buffer, xAt),
                else => unreachable,
            }
        }

        fn fillFloatBuffer(buffer: []u8, value: f32) void {
            switch (case_dtype) {
                .f64 => for (std.mem.bytesAsSlice(f64, buffer)) |*item| {
                    item.* = @floatCast(value);
                },
                .f32 => for (std.mem.bytesAsSlice(f32, buffer)) |*item| {
                    item.* = value;
                },
                .f16 => for (std.mem.bytesAsSlice(f16, buffer)) |*item| {
                    item.* = @floatCast(value);
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        fn fillIndexedFloatBuffer(buffer: []u8, comptime valueFn: fn (usize) f32) void {
            switch (case_dtype) {
                .f64 => for (std.mem.bytesAsSlice(f64, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, index| {
                    value.* = valueFn(index);
                },
                .f16 => for (std.mem.bytesAsSlice(f16, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
            return sparse.spmvCooRuntimeArguments(instance, nnz, x_extent);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try sparse.spmvCooFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .f64 => try sparse.SpmvCooRuntimeFamilyF64.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f32 => try sparse.SpmvCooRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try sparse.SpmvCooRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported sparse conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/spmv-coo-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            var sums: [rows]f32 = undefined;
            for (&sums, 0..) |*value, row| value.* = seededValue(seeded[0], row);
            const row_indices = std.mem.bytesAsSlice(i32, seeded[1]);
            const cols = std.mem.bytesAsSlice(i32, seeded[2]);
            for (0..nnz) |element| {
                const row = row_indices[element];
                const col = cols[element];
                if (row < 0 or row >= @as(i32, @intCast(rows)) or col < 0 or col >= @as(i32, @intCast(x_extent))) continue;
                sums[@intCast(row)] += seededValue(seeded[3], element) * seededValue(seeded[4], @intCast(col));
            }
            for (sums, 0..) |value, row| {
                setExpected(expected, row, value);
            }
        }

        fn seededValue(buffer: []const u8, index: usize) f32 {
            return switch (case_dtype) {
                .f64 => @floatCast(std.mem.bytesAsSlice(f64, @constCast(buffer))[index]),
                .f32 => std.mem.bytesAsSlice(f32, @constCast(buffer))[index],
                .f16 => @floatCast(std.mem.bytesAsSlice(f16, @constCast(buffer))[index]),
                else => @compileError("unsupported sparse conformance dtype"),
            };
        }

        fn setExpected(expected: []u8, row: usize, value: f32) void {
            switch (case_dtype) {
                .f64 => std.mem.bytesAsSlice(f64, expected)[row] = @floatCast(value),
                .f32 => std.mem.bytesAsSlice(f32, expected)[row] = value,
                .f16 => std.mem.bytesAsSlice(f16, expected)[row] = @floatCast(value),
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }
    };
}

fn SpmvEllFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
) type {
    return struct {
        const sparse = accy.kernel.library.sparse;
        const rows = 48;
        const slots = 6;
        const x_extent = 32;
        const instance = sparse.SpmvEll{
            .rows = rows,
            .slots = slots,
            .x_extent = x_extent,
            .dtype = case_dtype,
            .accumulation_dtype = sparse.spmvEllAccumulationDType(case_dtype).?,
            .threads = 64,
        };

        fn rowSlots(row: usize) usize {
            return switch (row % 5) {
                0 => 0,
                1 => 1,
                2 => 3,
                3 => slots,
                else => 4,
            };
        }

        fn ellIndex(slot: usize, row: usize) usize {
            return slot * rows + row;
        }

        fn colAt(row: usize, slot: usize) i32 {
            return @intCast((row * 7 + slot * 11 + 3) % x_extent);
        }

        fn valueAt(row: usize, slot: usize) f32 {
            return @floatFromInt(((row * 5 + slot * 7) % 9) + 1);
        }

        fn xAt(index: usize) f32 {
            return @floatFromInt((index % 5) + 1);
        }

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = if (case_dtype == .f16) 0.001 else 0;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, rows), .access = .inout },
            .{ .tensor = harness.mat(.i32, slots, rows) },
            .{ .tensor = harness.mat(case_dtype, slots, rows) },
            .{ .tensor = harness.vec(case_dtype, x_extent) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(sparse.spmvEllBlockCount(instance)), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => fillFloatBuffer(buffer, -1),
                1 => {
                    const cols = std.mem.bytesAsSlice(i32, buffer);
                    for (0..slots) |slot| {
                        for (0..rows) |row| {
                            cols[ellIndex(slot, row)] = if (slot < rowSlots(row)) colAt(row, slot) else -1;
                        }
                    }
                },
                2 => fillEllValues(buffer),
                3 => fillIndexedFloatBuffer(buffer, xAt),
                else => unreachable,
            }
        }

        fn fillFloatBuffer(buffer: []u8, value: f32) void {
            switch (case_dtype) {
                .f64 => {
                    for (std.mem.bytesAsSlice(f64, buffer)) |*item| item.* = @floatCast(value);
                },
                .f32 => {
                    for (std.mem.bytesAsSlice(f32, buffer)) |*item| item.* = value;
                },
                .f16 => {
                    for (std.mem.bytesAsSlice(f16, buffer)) |*item| item.* = @floatCast(value);
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        fn fillEllValues(buffer: []u8) void {
            switch (case_dtype) {
                .f64 => {
                    const values = std.mem.bytesAsSlice(f64, buffer);
                    for (0..slots) |slot| {
                        for (0..rows) |row| {
                            values[ellIndex(slot, row)] = @floatCast(valueAt(row, slot));
                        }
                    }
                },
                .f32 => {
                    const values = std.mem.bytesAsSlice(f32, buffer);
                    for (0..slots) |slot| {
                        for (0..rows) |row| {
                            values[ellIndex(slot, row)] = valueAt(row, slot);
                        }
                    }
                },
                .f16 => {
                    const values = std.mem.bytesAsSlice(f16, buffer);
                    for (0..slots) |slot| {
                        for (0..rows) |row| {
                            values[ellIndex(slot, row)] = @floatCast(valueAt(row, slot));
                        }
                    }
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        fn fillIndexedFloatBuffer(buffer: []u8, comptime valueFn: fn (usize) f32) void {
            switch (case_dtype) {
                .f64 => for (std.mem.bytesAsSlice(f64, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, index| {
                    value.* = valueFn(index);
                },
                .f16 => for (std.mem.bytesAsSlice(f16, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
            return sparse.spmvEllRuntimeArguments(instance, slots, x_extent);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try sparse.spmvEllFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .f64 => try sparse.SpmvEllRuntimeFamilyF64.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f32 => try sparse.SpmvEllRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try sparse.SpmvEllRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported sparse conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/spmv-ell-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            for (0..rows) |row| {
                var sum: f32 = 0;
                for (0..rowSlots(row)) |slot| {
                    sum += valueAt(row, slot) * xAt(@intCast(colAt(row, slot)));
                }
                setExpected(expected, row, sum);
            }
        }

        fn setExpected(expected: []u8, row: usize, value: f32) void {
            switch (case_dtype) {
                .f64 => std.mem.bytesAsSlice(f64, expected)[row] = @floatCast(value),
                .f32 => std.mem.bytesAsSlice(f32, expected)[row] = value,
                .f16 => std.mem.bytesAsSlice(f16, expected)[row] = @floatCast(value),
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }
    };
}

fn SpmvSellFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
) type {
    return struct {
        const sparse = accy.kernel.library.sparse;
        const rows = 48;
        const slice_size = 8;
        const slices = (rows + slice_size - 1) / slice_size;
        const x_extent = 32;
        const values_size = total_values_size;
        const instance = sparse.SpmvSell{
            .rows = rows,
            .slice_size = slice_size,
            .values_size = values_size,
            .x_extent = x_extent,
            .dtype = case_dtype,
            .accumulation_dtype = sparse.spmvSellAccumulationDType(case_dtype).?,
            .threads = 64,
        };

        const total_values_size = blk: {
            var count: usize = 0;
            for (0..slices) |slice| count += sliceSlots(slice) * slice_size;
            break :blk count;
        };

        fn rowSlots(row: usize) usize {
            return switch (row % 7) {
                0 => 0,
                1 => 1,
                2 => 2,
                3 => 7,
                4 => 4,
                5 => 6,
                else => 3,
            };
        }

        fn sliceSlots(slice: usize) usize {
            var count: usize = 0;
            for (0..slice_size) |local| {
                const row = slice * slice_size + local;
                if (row < rows) count = @max(count, rowSlots(row));
            }
            return count;
        }

        fn sliceBegin(slice: usize) usize {
            var count: usize = 0;
            for (0..slice) |prior| count += sliceSlots(prior) * slice_size;
            return count;
        }

        fn sellIndex(row: usize, slot: usize) usize {
            const slice = row / slice_size;
            const local = row - slice * slice_size;
            return sliceBegin(slice) + slot * slice_size + local;
        }

        fn colAt(row: usize, slot: usize) i32 {
            return @intCast((row * 7 + slot * 11 + 3) % x_extent);
        }

        fn valueAt(row: usize, slot: usize) f32 {
            return @floatFromInt(((row * 5 + slot * 7) % 9) + 1);
        }

        fn xAt(index: usize) f32 {
            return @floatFromInt((index % 5) + 1);
        }

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = if (case_dtype == .f16) 0.001 else 0;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(case_dtype, rows), .access = .inout },
            .{ .tensor = harness.vec(.i32, slices + 1) },
            .{ .tensor = harness.vec(.i32, values_size) },
            .{ .tensor = harness.vec(case_dtype, values_size) },
            .{ .tensor = harness.vec(case_dtype, x_extent) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(sparse.spmvSellBlockCount(instance)), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => fillFloatBuffer(buffer, -1),
                1 => {
                    const slice_offsets = std.mem.bytesAsSlice(i32, buffer);
                    for (slice_offsets, 0..) |*value, slice| value.* = @intCast(sliceBegin(slice));
                },
                2 => {
                    const cols = std.mem.bytesAsSlice(i32, buffer);
                    for (cols) |*value| value.* = -1;
                    for (0..rows) |row| {
                        for (0..rowSlots(row)) |slot| {
                            cols[sellIndex(row, slot)] = colAt(row, slot);
                        }
                    }
                },
                3 => fillSellValues(buffer),
                4 => fillIndexedFloatBuffer(buffer, xAt),
                else => unreachable,
            }
        }

        fn fillFloatBuffer(buffer: []u8, value: f32) void {
            switch (case_dtype) {
                .f64 => {
                    for (std.mem.bytesAsSlice(f64, buffer)) |*item| item.* = @floatCast(value);
                },
                .f32 => {
                    for (std.mem.bytesAsSlice(f32, buffer)) |*item| item.* = value;
                },
                .f16 => {
                    for (std.mem.bytesAsSlice(f16, buffer)) |*item| item.* = @floatCast(value);
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        fn fillSellValues(buffer: []u8) void {
            fillFloatBuffer(buffer, 97);
            switch (case_dtype) {
                .f64 => {
                    const values = std.mem.bytesAsSlice(f64, buffer);
                    for (0..rows) |row| {
                        for (0..rowSlots(row)) |slot| {
                            values[sellIndex(row, slot)] = @floatCast(valueAt(row, slot));
                        }
                    }
                },
                .f32 => {
                    const values = std.mem.bytesAsSlice(f32, buffer);
                    for (0..rows) |row| {
                        for (0..rowSlots(row)) |slot| {
                            values[sellIndex(row, slot)] = valueAt(row, slot);
                        }
                    }
                },
                .f16 => {
                    const values = std.mem.bytesAsSlice(f16, buffer);
                    for (0..rows) |row| {
                        for (0..rowSlots(row)) |slot| {
                            values[sellIndex(row, slot)] = @floatCast(valueAt(row, slot));
                        }
                    }
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        fn fillIndexedFloatBuffer(buffer: []u8, comptime valueFn: fn (usize) f32) void {
            switch (case_dtype) {
                .f64 => for (std.mem.bytesAsSlice(f64, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, index| {
                    value.* = valueFn(index);
                },
                .f16 => for (std.mem.bytesAsSlice(f16, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
            return sparse.spmvSellRuntimeArguments(instance, values_size, x_extent);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try sparse.spmvSellFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .f64 => try sparse.SpmvSellRuntimeFamilyF64.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f32 => try sparse.SpmvSellRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try sparse.SpmvSellRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported sparse conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/spmv-sell-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            for (0..rows) |row| {
                var sum: f32 = 0;
                for (0..rowSlots(row)) |slot| {
                    sum += valueAt(row, slot) * xAt(@intCast(colAt(row, slot)));
                }
                setExpected(expected, row, sum);
            }
        }

        fn setExpected(expected: []u8, row: usize, value: f32) void {
            switch (case_dtype) {
                .f64 => std.mem.bytesAsSlice(f64, expected)[row] = @floatCast(value),
                .f32 => std.mem.bytesAsSlice(f32, expected)[row] = value,
                .f16 => std.mem.bytesAsSlice(f16, expected)[row] = @floatCast(value),
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }
    };
}

fn SpmmCsrFamilyCase(
    comptime case_name: []const u8,
    comptime case_dtype: DType,
) type {
    return struct {
        const sparse = accy.kernel.library.sparse;
        const rows = 32;
        const columns = 9;
        const max_row_nnz = 5;
        const nnz = total_nnz;
        const x_extent = 17;
        const instance = sparse.SpmmCsr{
            .rows = rows,
            .columns = columns,
            .x_extent = x_extent,
            .dtype = case_dtype,
            .accumulation_dtype = sparse.spmmCsrAccumulationDType(case_dtype).?,
            .threads = .{ .x = 8, .y = 4 },
        };

        const total_nnz = blk: {
            var count: usize = 0;
            for (0..rows) |row| count += rowNnz(row);
            break :blk count;
        };

        fn rowNnz(row: usize) usize {
            return switch (row % 5) {
                0 => 0,
                1 => 1,
                2 => max_row_nnz,
                3 => 3,
                else => 2,
            };
        }

        fn rowBegin(row: usize) usize {
            var count: usize = 0;
            for (0..row) |prior| count += rowNnz(prior);
            return count;
        }

        fn colAt(element: usize) i32 {
            return @intCast((element * 5 + 2) % x_extent);
        }

        fn valueAt(element: usize) f32 {
            return @floatFromInt((element % 7) + 1);
        }

        fn xAt(index: usize) f32 {
            return @floatFromInt((index % 11) + 1);
        }

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = if (case_dtype == .f16) 0.001 else 0;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.mat(case_dtype, rows, columns), .access = .inout },
            .{ .tensor = harness.vec(.i32, rows + 1) },
            .{ .tensor = harness.vec(.i32, nnz) },
            .{ .tensor = harness.vec(case_dtype, nnz) },
            .{ .tensor = harness.mat(case_dtype, x_extent, columns) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(sparse.spmmCsrBlockCountX(instance)), @intCast(sparse.spmmCsrBlockCountY(instance)), 1 },
            .threadgroup = .{ instance.threads.x, instance.threads.y, 1 },
        };

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => fillFloatBuffer(buffer, -1),
                1 => {
                    const row_ptr = std.mem.bytesAsSlice(i32, buffer);
                    for (row_ptr, 0..) |*value, row| value.* = @intCast(rowBegin(row));
                },
                2 => for (std.mem.bytesAsSlice(i32, buffer), 0..) |*value, element| {
                    value.* = colAt(element);
                },
                3 => fillIndexedFloatBuffer(buffer, valueAt),
                4 => fillIndexedFloatBuffer(buffer, xAt),
                else => unreachable,
            }
        }

        fn fillFloatBuffer(buffer: []u8, value: f32) void {
            switch (case_dtype) {
                .f64 => {
                    for (std.mem.bytesAsSlice(f64, buffer)) |*item| item.* = @floatCast(value);
                },
                .f32 => {
                    for (std.mem.bytesAsSlice(f32, buffer)) |*item| item.* = value;
                },
                .f16 => {
                    for (std.mem.bytesAsSlice(f16, buffer)) |*item| item.* = @floatCast(value);
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        fn fillIndexedFloatBuffer(buffer: []u8, comptime valueFn: fn (usize) f32) void {
            switch (case_dtype) {
                .f64 => for (std.mem.bytesAsSlice(f64, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                .f32 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, index| {
                    value.* = valueFn(index);
                },
                .f16 => for (std.mem.bytesAsSlice(f16, buffer), 0..) |*value, index| {
                    value.* = @floatCast(valueFn(index));
                },
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }

        pub fn runtimeArguments() ![4]gpu_abi.ScalarArgument {
            return sparse.spmmCsrRuntimeArguments(instance, nnz, x_extent, columns);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try sparse.spmmCsrFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = switch (case_dtype) {
                .f64 => try sparse.SpmmCsrRuntimeFamilyF64.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f32 => try sparse.SpmmCsrRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance),
                .f16 => try sparse.SpmmCsrRuntimeFamilyF16.buildNamed(allocator, kernel_limits, entry_name, instance),
                else => @compileError("unsupported sparse conformance dtype"),
            };
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/spmm-csr-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            for (0..rows) |row| {
                for (0..columns) |column| {
                    var sum: f32 = 0;
                    const begin = rowBegin(row);
                    const end = begin + rowNnz(row);
                    for (begin..end) |element| {
                        const x_index: usize = @as(usize, @intCast(colAt(element))) * columns + column;
                        sum += valueAt(element) * xAt(x_index);
                    }
                    setExpected(expected, row * columns + column, sum);
                }
            }
        }

        fn setExpected(expected: []u8, index: usize, value: f32) void {
            switch (case_dtype) {
                .f64 => std.mem.bytesAsSlice(f64, expected)[index] = @floatCast(value),
                .f32 => std.mem.bytesAsSlice(f32, expected)[index] = value,
                .f16 => std.mem.bytesAsSlice(f16, expected)[index] = @floatCast(value),
                else => @compileError("unsupported sparse conformance dtype"),
            }
        }
    };
}

const GridCellsFamilyCase = struct {
    const spatial = accy.kernel.library.spatial;
    const count = 96;
    const instance = spatial.GridCells{ .count = count, .threads = 32 };
    const grid = spatial.GridGeometry{
        .origin_x = -1.0,
        .origin_y = -1.0,
        .inv_cell_size = 4.0,
        .dims_x = 8,
        .dims_y = 8,
    };

    pub const name = "grid_cells_family_f32_96points";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, count), .access = .inout },
        .{ .tensor = harness.vec(.f32, count) },
        .{ .tensor = harness.vec(.f32, count) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ @intCast(spatial.gridCellsBlockCount(count, instance.threads)), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn coordAt(comptime axis: usize, point: usize) f32 {
        const mixed = point * 37 + axis * 11;
        return @as(f32, @floatFromInt(mixed % 1000)) / 250.0 - 2.0;
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer)) |*value| {
                value.* = -1;
            },
            1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                value.* = coordAt(0, point);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                value.* = coordAt(1, point);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![6]gpu_abi.ScalarArgument {
        return spatial.gridCellsRuntimeArguments(instance, grid);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try spatial.gridCellsFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try spatial.GridCellsRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/grid-cells-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        const out = std.mem.bytesAsSlice(i32, expected);
        for (out, 0..) |*value, point| {
            const fx = (coordAt(0, point) - grid.origin_x) * grid.inv_cell_size;
            const fy = (coordAt(1, point) - grid.origin_y) * grid.inv_cell_size;
            const cx = std.math.clamp(@as(i32, @intFromFloat(fx)), 0, @as(i32, @intCast(grid.dims_x - 1)));
            const cy = std.math.clamp(@as(i32, @intFromFloat(fy)), 0, @as(i32, @intCast(grid.dims_y - 1)));
            value.* = cy * @as(i32, @intCast(grid.dims_x)) + cx;
        }
    }
};

const ImageBlurPassFamilyCase = struct {
    const image = accy.kernel.library.image;
    const width = 24;
    const height = 10;
    const pixel_count = width * height;
    const instance = image.BlurPass{ .radius = 2, .axis = .horizontal, .threads = .{ .x = 8, .y = 4 } };
    const weights = [_]f32{ 0.0625, 0.25, 0.375, 0.25, 0.0625 };

    pub const name = "image_blur_pass_family_r2h_rgba8_24x10";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.u32, pixel_count), .access = .inout },
        .{ .tensor = harness.vec(.u32, pixel_count) },
        .{ .tensor = harness.vec(.f32, weights.len) },
    };
    pub const observed: usize = 0;
    pub const geometry = image.imageLaunchGeometry(instance.threads, width, height);

    fn pixelAt(index: usize) u32 {
        var value: u32 = @truncate(index *% 2654435761);
        value ^= value >> 13;
        value *%= 0x5bd1e995;
        value ^= value >> 15;
        return value;
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(u32, buffer)) |*value| {
                value.* = 0;
            },
            1 => for (std.mem.bytesAsSlice(u32, buffer), 0..) |*value, pixel| {
                value.* = pixelAt(pixel);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), weights) |*value, weight| {
                value.* = weight;
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![2]gpu_abi.ScalarArgument {
        return image.blurPassRuntimeArguments(width, height);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try image.blurPassFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try image.BlurPassFamilyRgba8.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/image-blur-pass-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        var src_pixels: [pixel_count]u32 = undefined;
        for (&src_pixels, 0..) |*value, pixel| value.* = pixelAt(pixel);
        const out = std.mem.bytesAsSlice(u32, expected);
        image.referenceBlurPass(@alignCast(out), src_pixels[0..], weights[0..], width, height, instance.axis);
    }
};

const ImageResizeFamilyCase = struct {
    const image = accy.kernel.library.image;
    const src_width = 20;
    const src_height = 12;
    const dst_width = 11;
    const dst_height = 7;
    const instance = image.Resize{ .threads = .{ .x = 8, .y = 4 } };

    pub const name = "image_resize_bilinear_family_rgba8_20x12_to_11x7";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.u32, dst_width * dst_height), .access = .inout },
        .{ .tensor = harness.vec(.u32, src_width * src_height) },
    };
    pub const observed: usize = 0;
    pub const geometry = image.imageLaunchGeometry(instance.threads, dst_width, dst_height);

    fn pixelAt(index: usize) u32 {
        var value: u32 = @truncate((index +% 31) *% 2246822519);
        value ^= value >> 15;
        value *%= 0x9e3779b1;
        value ^= value >> 13;
        return value;
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(u32, buffer)) |*value| {
                value.* = 0;
            },
            1 => for (std.mem.bytesAsSlice(u32, buffer), 0..) |*value, pixel| {
                value.* = pixelAt(pixel);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![7]gpu_abi.ScalarArgument {
        return image.resizeRuntimeArguments(dst_width, dst_height, src_width, src_height);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try image.resizeFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try image.ResizeBilinearFamilyRgba8.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/image-resize-bilinear-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        var src_pixels: [src_width * src_height]u32 = undefined;
        for (&src_pixels, 0..) |*value, pixel| value.* = pixelAt(pixel);
        const out = std.mem.bytesAsSlice(u32, expected);
        image.referenceResizeBilinear(@alignCast(out), src_pixels[0..], dst_width, dst_height, src_width, src_height);
    }
};

fn SdfGridSampleGradient2DCase(comptime case_name: []const u8, comptime observed_index: usize) type {
    return struct {
        const sdf = accy.kernel.library.sdf;
        const nx = 17;
        const ny = 13;
        const count = 96;
        const origin: f32 = -1.0;
        const spacing: f32 = 0.125;
        const instance = sdf.GridSample{ .gradient = true, .threads = 32 };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0.000001;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(.f32, count), .access = .inout },
            .{ .tensor = harness.vec(.f32, count), .access = .inout },
            .{ .tensor = harness.vec(.f32, count), .access = .inout },
            .{ .tensor = harness.vec(.f32, nx * ny) },
            .{ .tensor = harness.vec(.f32, count) },
            .{ .tensor = harness.vec(.f32, count) },
        };
        pub const observed: usize = observed_index;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(sdf.gridSampleBlockCount(count, instance.threads)), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        fn gridValueAt(index: usize) f32 {
            const ix = index % nx;
            const iy = index / nx;
            const x = origin + @as(f32, @floatFromInt(ix)) * spacing;
            const y = origin + @as(f32, @floatFromInt(iy)) * spacing;
            return @sqrt(x * x + y * y) - 0.75;
        }

        fn queryAt(comptime axis: usize, point: usize) f32 {
            const mixed = point * 41 + axis * 13;
            return -1.4 + @as(f32, @floatFromInt(mixed % 1000)) / 340.0;
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0, 1, 2 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                    value.* = 0;
                },
                3 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, cell| {
                    value.* = gridValueAt(cell);
                },
                4 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                    value.* = queryAt(0, point);
                },
                5 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                    value.* = queryAt(1, point);
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![7]gpu_abi.ScalarArgument {
            return .{
                .{ .i32 = count },
                .{ .f32 = origin },
                .{ .f32 = origin },
                .{ .f32 = 1.0 / spacing },
                .{ .f32 = 1.0 / spacing },
                .{ .i32 = nx },
                .{ .i32 = ny },
            };
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            var graph = try sdf.GridSampleGradientFamily2D.build(allocator, kernel_limits, instance);
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/sdf-grid-sample-gradient-2d-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            var grid_values: [nx * ny]f32 = undefined;
            for (&grid_values, 0..) |*value, cell| value.* = gridValueAt(cell);
            const grid = sdf.ReferenceGrid2{
                .values = grid_values[0..],
                .nx = nx,
                .ny = ny,
                .origin_x = origin,
                .origin_y = origin,
                .inv_dx = 1.0 / spacing,
                .inv_dy = 1.0 / spacing,
            };
            const out = std.mem.bytesAsSlice(f32, expected);
            for (0..count) |point| {
                var gradient: [2]f32 = undefined;
                const distance = sdf.referenceGridSample2(grid, queryAt(0, point), queryAt(1, point), &gradient);
                out[point] = switch (observed_index) {
                    0 => distance,
                    1 => gradient[0],
                    2 => gradient[1],
                    else => unreachable,
                };
            }
        }
    };
}

const SdfGridSample3DFamilyCase = struct {
    const sdf = accy.kernel.library.sdf;
    const nx = 9;
    const ny = 7;
    const nz = 6;
    const count = 64;
    const origin: f32 = -1.0;
    const spacing: f32 = 0.3;
    const instance = sdf.GridSample{ .threads = 32 };

    pub const name = "sdf_grid_sample_family_f32_3d_64points";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.f32, count), .access = .inout },
        .{ .tensor = harness.vec(.f32, nx * ny * nz) },
        .{ .tensor = harness.vec(.f32, count) },
        .{ .tensor = harness.vec(.f32, count) },
        .{ .tensor = harness.vec(.f32, count) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ @intCast(sdf.gridSampleBlockCount(count, instance.threads)), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn gridValueAt(index: usize) f32 {
        const iz = index / (nx * ny);
        const rem = index % (nx * ny);
        const iy = rem / nx;
        const ix = rem % nx;
        const x = origin + @as(f32, @floatFromInt(ix)) * spacing;
        const y = origin + @as(f32, @floatFromInt(iy)) * spacing;
        const z = origin + @as(f32, @floatFromInt(iz)) * spacing;
        return @sqrt(x * x + y * y + z * z) - 0.9;
    }

    fn queryAt(comptime axis: usize, point: usize) f32 {
        const mixed = point * 53 + axis * 19;
        return -1.5 + @as(f32, @floatFromInt(mixed % 1000)) / 310.0;
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                value.* = 0;
            },
            1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, cell| {
                value.* = gridValueAt(cell);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                value.* = queryAt(0, point);
            },
            3 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                value.* = queryAt(1, point);
            },
            4 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                value.* = queryAt(2, point);
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![10]gpu_abi.ScalarArgument {
        return .{
            .{ .i32 = count },
            .{ .f32 = origin },
            .{ .f32 = origin },
            .{ .f32 = origin },
            .{ .f32 = 1.0 / spacing },
            .{ .f32 = 1.0 / spacing },
            .{ .f32 = 1.0 / spacing },
            .{ .i32 = nx },
            .{ .i32 = ny },
            .{ .i32 = nz },
        };
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        var graph = try sdf.GridSampleFamily3D.build(allocator, kernel_limits, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/sdf-grid-sample-3d-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        var grid_values: [nx * ny * nz]f32 = undefined;
        for (&grid_values, 0..) |*value, cell| value.* = gridValueAt(cell);
        const grid = sdf.ReferenceGrid3{
            .values = grid_values[0..],
            .nx = nx,
            .ny = ny,
            .nz = nz,
            .origin_x = origin,
            .origin_y = origin,
            .origin_z = origin,
            .inv_dx = 1.0 / spacing,
            .inv_dy = 1.0 / spacing,
            .inv_dz = 1.0 / spacing,
        };
        const out = std.mem.bytesAsSlice(f32, expected);
        for (0..count) |point| {
            out[point] = sdf.referenceGridSample3(grid, queryAt(0, point), queryAt(1, point), queryAt(2, point), null);
        }
    }
};

const BatchedCholeskyFamilyCase = struct {
    const factor = accy.kernel.library.factor;
    const n = 3;
    const batch = 48;
    const instance = factor.BatchedCholesky{ .batch = batch, .n = n, .threads = 32 };

    pub const name = "batched_cholesky_family_f32_48x3";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0.00001;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.f32, batch * n * n), .access = .inout },
        .{ .tensor = harness.vec(.f32, batch * n * n) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ @intCast(factor.batchedCholeskyBlockCount(batch, instance.threads)), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn tileEntry(system: usize, row: usize, col: usize) f32 {
        var sum: f32 = 0;
        for (0..n) |c| {
            sum += mixedEntry(system, row, c) * mixedEntry(system, col, c);
        }
        if (row == col) sum += @floatFromInt(n);
        return sum;
    }

    fn mixedEntry(system: usize, row: usize, col: usize) f32 {
        const mixed = system * 131 + row * 17 + col * 7;
        return @as(f32, @floatFromInt(mixed % 1000)) / 1000.0;
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                value.* = -1;
            },
            1 => {
                const values = std.mem.bytesAsSlice(f32, buffer);
                for (0..batch) |system| {
                    for (0..n) |row| {
                        for (0..n) |col| {
                            values[system * n * n + row * n + col] = tileEntry(system, row, col);
                        }
                    }
                }
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
        return factor.batchedCholeskyRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try factor.batchedCholeskyFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try factor.BatchedCholeskyRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/batched-cholesky-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        const out = std.mem.bytesAsSlice(f32, expected);
        for (0..batch) |system| {
            var a_tile: [n * n]f32 = undefined;
            for (0..n) |row| {
                for (0..n) |col| {
                    a_tile[row * n + col] = tileEntry(system, row, col);
                }
            }
            var l_tile: [n * n]f32 = @as([(n * n)]f32, @splat(0));
            for (0..n) |j| {
                var diagonal = a_tile[j * n + j];
                for (0..j) |c| {
                    diagonal -= l_tile[j * n + c] * l_tile[j * n + c];
                }
                l_tile[j * n + j] = @sqrt(diagonal);
                for (j + 1..n) |i| {
                    var sum = a_tile[i * n + j];
                    for (0..j) |c| {
                        sum -= l_tile[i * n + c] * l_tile[j * n + c];
                    }
                    l_tile[i * n + j] = sum / l_tile[j * n + j];
                }
            }
            for (0..n * n) |slot| {
                out[system * n * n + slot] = l_tile[slot];
            }
        }
    }
};

const BatchedCholeskyInterleavedFamilyCase = struct {
    const factor = accy.kernel.library.factor;
    const n = 3;
    const batch = 48;
    const instance = factor.BatchedCholesky{ .batch = batch, .n = n, .threads = 32, .layout = .interleaved };

    pub const name = "batched_cholesky_family_f32_48x3_interleaved";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0.00001;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.f32, batch * n * n), .access = .inout },
        .{ .tensor = harness.vec(.f32, batch * n * n) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ @intCast(factor.batchedCholeskyBlockCount(batch, instance.threads)), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn mixedEntry(system: usize, row: usize, col: usize) f32 {
        const mixed = system * 131 + row * 17 + col * 7;
        return @as(f32, @floatFromInt(mixed % 1000)) / 1000.0;
    }

    fn tileEntry(system: usize, row: usize, col: usize) f32 {
        var sum: f32 = 0;
        for (0..n) |c| {
            sum += mixedEntry(system, row, c) * mixedEntry(system, col, c);
        }
        if (row == col) sum += @floatFromInt(n);
        return sum;
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                value.* = -1;
            },
            1 => {
                const values = std.mem.bytesAsSlice(f32, buffer);
                for (0..batch) |system| {
                    for (0..n) |row| {
                        for (0..n) |col| {
                            values[(row * n + col) * batch + system] = tileEntry(system, row, col);
                        }
                    }
                }
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
        return factor.batchedCholeskyRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try factor.batchedCholeskyFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try factor.BatchedCholeskyRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/batched-cholesky-interleaved-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        const out = std.mem.bytesAsSlice(f32, expected);
        for (0..batch) |system| {
            var a_tile: [n * n]f32 = undefined;
            for (0..n) |row| {
                for (0..n) |col| {
                    a_tile[row * n + col] = tileEntry(system, row, col);
                }
            }
            var l_tile: [n * n]f32 = @as([(n * n)]f32, @splat(0));
            for (0..n) |j| {
                var diagonal = a_tile[j * n + j];
                for (0..j) |c| {
                    diagonal -= l_tile[j * n + c] * l_tile[j * n + c];
                }
                l_tile[j * n + j] = @sqrt(diagonal);
                for (j + 1..n) |i| {
                    var sum = a_tile[i * n + j];
                    for (0..j) |c| {
                        sum -= l_tile[i * n + c] * l_tile[j * n + c];
                    }
                    l_tile[i * n + j] = sum / l_tile[j * n + j];
                }
            }
            for (0..n * n) |slot| {
                out[slot * batch + system] = l_tile[slot];
            }
        }
    }
};

fn BatchedCholeskySolveFamilyCase(
    comptime case_name: []const u8,
    comptime case_layout: accy.kernel.library.factor.TileLayout,
) type {
    return struct {
        const factor = accy.kernel.library.factor;
        const n = 3;
        const batch = 48;
        const instance = factor.BatchedCholeskySolve{ .batch = batch, .n = n, .threads = 32, .layout = case_layout };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0.00001;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(.f32, batch * n), .access = .inout },
            .{ .tensor = harness.vec(.f32, batch * n * n) },
            .{ .tensor = harness.vec(.f32, batch * n) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(factor.batchedCholeskyBlockCount(batch, instance.threads)), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        fn mixedEntry(system: usize, row: usize, col: usize) f32 {
            const mixed = system * 131 + row * 17 + col * 7;
            return @as(f32, @floatFromInt(mixed % 1000)) / 1000.0;
        }

        fn tileEntry(system: usize, row: usize, col: usize) f32 {
            var sum: f32 = 0;
            for (0..n) |c| {
                sum += mixedEntry(system, row, c) * mixedEntry(system, col, c);
            }
            if (row == col) sum += @floatFromInt(n);
            return sum;
        }

        fn rhsEntry(system: usize, row: usize) f32 {
            const mixed = system * 37 + row * 11;
            return @as(f32, @floatFromInt(mixed % 1000)) / 500.0 - 1.0;
        }

        fn tileIndex(system: usize, slot: usize) usize {
            return switch (case_layout) {
                .row_major => system * n * n + slot,
                .interleaved => slot * batch + system,
            };
        }

        fn vectorIndex(system: usize, slot: usize) usize {
            return switch (case_layout) {
                .row_major => system * n + slot,
                .interleaved => slot * batch + system,
            };
        }

        fn lowerTile(system: usize, l_tile: *[n * n]f32) void {
            var a_tile: [n * n]f32 = undefined;
            for (0..n) |row| {
                for (0..n) |col| {
                    a_tile[row * n + col] = tileEntry(system, row, col);
                }
            }
            for (l_tile) |*value| value.* = 0;
            for (0..n) |j| {
                var diagonal = a_tile[j * n + j];
                for (0..j) |c| {
                    diagonal -= l_tile[j * n + c] * l_tile[j * n + c];
                }
                l_tile[j * n + j] = @sqrt(diagonal);
                for (j + 1..n) |i| {
                    var sum = a_tile[i * n + j];
                    for (0..j) |c| {
                        sum -= l_tile[i * n + c] * l_tile[j * n + c];
                    }
                    l_tile[i * n + j] = sum / l_tile[j * n + j];
                }
            }
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                    value.* = -1;
                },
                1 => {
                    const values = std.mem.bytesAsSlice(f32, buffer);
                    for (0..batch) |system| {
                        var l_tile: [n * n]f32 = undefined;
                        lowerTile(system, &l_tile);
                        for (0..n * n) |slot| {
                            values[tileIndex(system, slot)] = l_tile[slot];
                        }
                    }
                },
                2 => {
                    const values = std.mem.bytesAsSlice(f32, buffer);
                    for (0..batch) |system| {
                        for (0..n) |row| {
                            values[vectorIndex(system, row)] = rhsEntry(system, row);
                        }
                    }
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
            return factor.batchedCholeskySolveRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try factor.batchedCholeskySolveFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = try factor.BatchedCholeskySolveRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = switch (case_layout) {
                    .row_major => "conformance/batched-cholesky-solve-family",
                    .interleaved => "conformance/batched-cholesky-solve-family-interleaved",
                },
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            const out = std.mem.bytesAsSlice(f32, expected);
            for (0..batch) |system| {
                var l_tile: [n * n]f32 = undefined;
                lowerTile(system, &l_tile);
                var solution: [n]f32 = undefined;
                for (0..n) |i| {
                    var sum = rhsEntry(system, i);
                    for (0..i) |j| {
                        sum -= l_tile[i * n + j] * solution[j];
                    }
                    solution[i] = sum / l_tile[i * n + i];
                }
                var row: usize = n;
                while (row > 0) {
                    row -= 1;
                    var sum = solution[row];
                    for (row + 1..n) |j| {
                        sum -= l_tile[j * n + row] * solution[j];
                    }
                    solution[row] = sum / l_tile[row * n + row];
                }
                for (0..n) |slot| {
                    out[vectorIndex(system, slot)] = solution[slot];
                }
            }
        }
    };
}

fn BatchedInverseFamilyCase(
    comptime case_name: []const u8,
    comptime case_layout: accy.kernel.library.factor.TileLayout,
) type {
    return struct {
        const factor = accy.kernel.library.factor;
        const n = 3;
        const batch = 48;
        const instance = factor.BatchedInverse{ .batch = batch, .n = n, .threads = 32, .layout = case_layout };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0.001;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(.f32, batch * n * n), .access = .inout },
            .{ .tensor = harness.vec(.f32, batch * n * n) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ @intCast(factor.batchedCholeskyBlockCount(batch, instance.threads)), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        };

        fn mixedEntry(system: usize, row: usize, col: usize) f32 {
            const mixed = system * 131 + row * 17 + col * 7;
            return @as(f32, @floatFromInt(mixed % 1000)) / 1000.0;
        }

        fn tileEntry(system: usize, row: usize, col: usize) f32 {
            var sum: f32 = 0;
            for (0..n) |c| {
                sum += mixedEntry(system, row, c) * mixedEntry(system, col, c);
            }
            if (row == col) sum += @floatFromInt(n);
            return sum;
        }

        fn tileIndex(system: usize, slot: usize) usize {
            return switch (case_layout) {
                .row_major => system * n * n + slot,
                .interleaved => slot * batch + system,
            };
        }

        fn invertTile(system: usize, inv_tile: *[n * n]f32) void {
            var a_tile: [n * n]f32 = undefined;
            for (0..n) |row| {
                for (0..n) |col| {
                    a_tile[row * n + col] = tileEntry(system, row, col);
                    inv_tile[row * n + col] = if (row == col) 1 else 0;
                }
            }
            for (0..n) |pivot_index| {
                const pivot = a_tile[pivot_index * n + pivot_index];
                for (0..n) |col| {
                    a_tile[pivot_index * n + col] /= pivot;
                    inv_tile[pivot_index * n + col] /= pivot;
                }
                for (0..n) |row| {
                    if (row == pivot_index) continue;
                    const scale = a_tile[row * n + pivot_index];
                    for (0..n) |col| {
                        a_tile[row * n + col] -= scale * a_tile[pivot_index * n + col];
                        inv_tile[row * n + col] -= scale * inv_tile[pivot_index * n + col];
                    }
                }
            }
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => for (std.mem.bytesAsSlice(f32, buffer)) |*value| {
                    value.* = -1;
                },
                1 => {
                    const values = std.mem.bytesAsSlice(f32, buffer);
                    for (0..batch) |system| {
                        for (0..n) |row| {
                            for (0..n) |col| {
                                values[tileIndex(system, row * n + col)] = tileEntry(system, row, col);
                            }
                        }
                    }
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![1]gpu_abi.ScalarArgument {
            return factor.batchedInverseRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try factor.batchedInverseFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = try factor.BatchedInverseRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = switch (case_layout) {
                    .row_major => "conformance/batched-inverse-family",
                    .interleaved => "conformance/batched-inverse-family-interleaved",
                },
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            const out = std.mem.bytesAsSlice(f32, expected);
            for (0..batch) |system| {
                var inv_tile: [n * n]f32 = undefined;
                invertTile(system, &inv_tile);
                for (0..n * n) |slot| {
                    out[tileIndex(system, slot)] = inv_tile[slot];
                }
            }
        }
    };
}

const GridNeighborCountFamilyCase = struct {
    const spatial = accy.kernel.library.spatial;
    const count = 96;
    const cells_total = 16;
    const radius: f32 = 0.75;
    const instance = spatial.GridNeighborCount{ .count = count, .threads = 32 };
    const grid = spatial.GridGeometry{
        .origin_x = 0.0,
        .origin_y = 0.0,
        .inv_cell_size = 1.0,
        .dims_x = 4,
        .dims_y = 4,
    };

    pub const name = "grid_neighbor_count_family_f32_96points";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, count), .access = .inout },
        .{ .tensor = harness.vec(.f32, count) },
        .{ .tensor = harness.vec(.f32, count) },
        .{ .tensor = harness.vec(.i32, count) },
        .{ .tensor = harness.vec(.f32, cells_total) },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ @intCast(spatial.gridCellsBlockCount(count, instance.threads)), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn coordAt(comptime axis: usize, point: usize) f32 {
        const mixed = point * 53 + axis * 17;
        return @as(f32, @floatFromInt(mixed % 1000)) / 250.0 - 0.5;
    }

    fn cellIdAt(point: usize) i32 {
        const fx = (coordAt(0, point) - grid.origin_x) * grid.inv_cell_size;
        const fy = (coordAt(1, point) - grid.origin_y) * grid.inv_cell_size;
        const cx = std.math.clamp(@as(i32, @intFromFloat(fx)), 0, @as(i32, @intCast(grid.dims_x - 1)));
        const cy = std.math.clamp(@as(i32, @intFromFloat(fy)), 0, @as(i32, @intCast(grid.dims_y - 1)));
        return cy * @as(i32, @intCast(grid.dims_x)) + cx;
    }

    fn sortedOrder() [count]i32 {
        var order: [count]i32 = undefined;
        for (&order, 0..) |*value, index| value.* = @intCast(index);
        var sort_index: usize = 1;
        while (sort_index < count) : (sort_index += 1) {
            const key = order[sort_index];
            const key_cell = cellIdAt(@intCast(key));
            var slot = sort_index;
            while (slot > 0 and cellIdAt(@intCast(order[slot - 1])) > key_cell) : (slot -= 1) {
                order[slot] = order[slot - 1];
            }
            order[slot] = key;
        }
        return order;
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer)) |*value| {
                value.* = -1;
            },
            1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                value.* = coordAt(0, point);
            },
            2 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, point| {
                value.* = coordAt(1, point);
            },
            3 => {
                const order = sortedOrder();
                for (std.mem.bytesAsSlice(i32, buffer), order) |*value, sorted| {
                    value.* = sorted;
                }
            },
            4 => {
                var counts = @as([cells_total]u32, @splat(0));
                for (0..count) |point| counts[@intCast(cellIdAt(point))] += 1;
                var prefix: u32 = 0;
                for (std.mem.bytesAsSlice(f32, buffer), counts) |*value, cell_count| {
                    value.* = @floatFromInt(prefix);
                    prefix += cell_count;
                }
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![8]gpu_abi.ScalarArgument {
        return spatial.gridNeighborCountRuntimeArguments(instance, grid, 1, radius);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try spatial.gridNeighborCountFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try spatial.GridNeighborCountRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/grid-neighbor-count-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        const out = std.mem.bytesAsSlice(i32, expected);
        for (out, 0..) |*value, a| {
            var total: i32 = 0;
            for (0..count) |b| {
                if (a == b) continue;
                const dx = coordAt(0, a) - coordAt(0, b);
                const dy = coordAt(1, a) - coordAt(1, b);
                if (dx * dx + dy * dy <= radius * radius) total += 1;
            }
            value.* = total;
        }
    }
};

const PhiloxFillFamilyI32 = struct {
    const random = accy.kernel.library.random;
    const count = 64;
    const instance = random.Philox{
        .count = count,
        .dtype = .i32,
        .threads = 32,
        .seed = 0x00c0ffee_deadbeef,
    };

    pub const name = "philox_fill_family_i32_64";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, count), .access = .inout },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ 1, 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => @memset(buffer, 0),
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
        return random.philoxRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try random.philoxFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try random.PhiloxRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/philox-fill-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        const out = std.mem.bytesAsSlice(i32, expected);
        var generator: u32 = 0;
        while (generator * 4 < count) : (generator += 1) {
            const words = random.philoxBlock(
                random.philox_default_rounds,
                .{ generator, 0, 0, 0 },
                .{ instance.seedLo(), instance.seedHi() },
            );
            for (words, 0..) |word, lane| {
                const element = generator * 4 + lane;
                if (element >= count) continue;
                out[element] = @bitCast(word);
            }
        }
    }
};

const ThreefryFillFamilyI32 = struct {
    const random = accy.kernel.library.random;
    const count = 65;
    const observed_count = 66;
    const sentinel: i32 = 0x13579bdf;
    const instance = random.Threefry{
        .count = count,
        .dtype = .i32,
        .threads = 32,
        .seed = 0x01234567_89abcdef,
    };

    pub const name = "threefry_fill_family_i32_65";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, observed_count), .access = .inout },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ blockCount(), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn blockCount() u32 {
        const generators = instance.generators();
        return @intCast((generators + instance.threads - 1) / instance.threads);
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer)) |*value| {
                value.* = sentinel;
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
        return random.threefryRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try random.threefryFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try random.ThreefryRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/threefry-fill-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        const seed = std.mem.bytesAsSlice(i32, seeded[0]);
        const out = std.mem.bytesAsSlice(i32, expected);
        for (out, seed) |*value, initial| value.* = initial;
        var generator: u32 = 0;
        while (generator * 2 < count) : (generator += 1) {
            const words = random.threefryBlock(
                random.threefry_default_rounds,
                .{ generator, 0 },
                .{ instance.seedLo(), instance.seedHi() },
            );
            for (words, 0..) |word, lane| {
                const element = generator * 2 + lane;
                if (element >= count) continue;
                out[element] = @bitCast(word);
            }
        }
    }
};

const SquaresFillFamilyI32 = struct {
    const random = accy.kernel.library.random;
    const count = 63;
    const observed_count = 64;
    const sentinel: i32 = 0x13579bdf;
    const instance = random.Squares{
        .count = count,
        .dtype = .i32,
        .threads = 32,
        .key = 0x11223344_55667788,
    };

    pub const name = "squares_fill_family_i32_63";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, observed_count), .access = .inout },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ blockCount(), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn blockCount() u32 {
        const generators = instance.generators();
        return @intCast((generators + instance.threads - 1) / instance.threads);
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer)) |*value| {
                value.* = sentinel;
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
        return random.squaresRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try random.squaresFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try random.SquaresRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/squares-fill-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        const seed = std.mem.bytesAsSlice(i32, seeded[0]);
        const out = std.mem.bytesAsSlice(i32, expected);
        for (out, seed) |*value, initial| value.* = initial;
        for (0..count) |element| {
            out[element] = @bitCast(random.squaresBlock(@intCast(element), instance.key));
        }
    }
};

const WhileTriangularI32 = struct {
    const kernel = accy.kernel;
    const count = 64;
    const threads = 32;
    const sentinel: i32 = -1;

    pub const name = "scf_while_triangular_i32_64";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, count), .access = .inout },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ count / threads, 1, 1 },
        .threadgroup = .{ threads, 1, 1 },
    };

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer)) |*value| {
                value.* = sentinel;
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![0]gpu_abi.ScalarArgument {
        return .{};
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.standard, "accy_conformance_while_triangular", &.{
            kernel.dynamicBuffer(.i32),
        });
        errdefer builder.deinit();

        const dst = builder.argument(0);
        const index = try builder.globalId(.x);
        const start = try builder.cast(index, .i32);
        const zero = try builder.constantInt(.i32, 0);
        const one = try builder.constantInt(.i32, 1);

        var scope = try builder.whileScope(&.{ start, zero }, &.{ start.valueType(), zero.valueType() });
        errdefer scope.abort();
        const remaining = scope.beforeArg(0).?;
        const total = scope.beforeArg(1).?;
        const proceed = try builder.compare(.gt, remaining, zero);
        try scope.condition(proceed, &.{ remaining, total });
        const after_remaining = scope.afterArg(0).?;
        const after_total = scope.afterArg(1).?;
        const next_total = try builder.add(after_total, after_remaining);
        const next_remaining = try builder.sub(after_remaining, one);
        try scope.leave(&.{ next_remaining, next_total });

        try builder.store(scope.result(1).?, dst, index);
        try builder.return_();

        var graph = try builder.finish();
        defer graph.deinit();
        return kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/scf-while-triangular",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        _ = seeded;
        const out = std.mem.bytesAsSlice(i32, expected);
        for (out, 0..) |*value, lane| {
            var total: i64 = 0;
            var remaining: i64 = @intCast(lane);
            while (remaining > 0) : (remaining -= 1) total += remaining;
            value.* = @intCast(total);
        }
    }
};

const FeistelPermutationFamilyI32 = struct {
    const random = accy.kernel.library.random;
    const count = 64;
    const observed_count = 65;
    const sentinel: i32 = -1;
    const instance = random.Feistel{
        .count = count,
        .rounds = 6,
        .dtype = .i32,
        .threads = 32,
        .seed = 0x10203040_55667788,
    };

    pub const name = "feistel_permutation_family_i32_64";
    pub const expectation: harness.Expectation = .verified;
    pub const tolerance: f32 = 0;
    pub const buffers = [_]harness.FamilyBuffer{
        .{ .tensor = harness.vec(.i32, observed_count), .access = .inout },
    };
    pub const observed: usize = 0;
    pub const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ blockCount(), 1, 1 },
        .threadgroup = .{ instance.threads, 1, 1 },
    };

    fn blockCount() u32 {
        return @intCast((instance.count + instance.threads - 1) / instance.threads);
    }

    pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
        switch (index) {
            0 => for (std.mem.bytesAsSlice(i32, buffer)) |*value| {
                value.* = sentinel;
            },
            else => unreachable,
        }
    }

    pub fn runtimeArguments() ![3]gpu_abi.ScalarArgument {
        return random.feistelRuntimeArguments(instance);
    }

    pub fn buildArtifact(
        allocator: std.mem.Allocator,
        handle: harness.BackendHandle,
    ) !gpu.KernelArtifact {
        const entry_name = try random.feistelFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try random.FeistelRuntimeFamilyI32.buildNamed(allocator, kernel_limits, entry_name, instance);
        defer graph.deinit();
        return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
            .authored_kernel_diagnostic_id = "conformance/feistel-permutation-family",
        });
    }

    pub fn reference(seeded: []const []const u8, expected: []u8) void {
        const seed = std.mem.bytesAsSlice(i32, seeded[0]);
        const out = std.mem.bytesAsSlice(i32, expected);
        for (out, seed) |*value, initial| value.* = initial;
        const bits = instance.domainBits().?;
        for (0..count) |element| {
            out[element] = @intCast(random.feistelPermuteReference(@intCast(element), instance.rounds, instance.seed, bits));
        }
    }
};

fn HistogramFamilyCase(
    comptime case_name: []const u8,
    comptime case_variant: accy.kernel.library.histogram.HistogramVariant,
) type {
    return struct {
        const histogram = accy.kernel.library.histogram;
        const bin_count = 16;
        const element_count_local = 96;
        const instance = histogram.Histogram{
            .bins = bin_count,
            .count = element_count_local,
            .lo = -1.0,
            .width = 0.25,
            .variant = case_variant,
            .threads = 32,
        };

        pub const name = case_name;
        pub const expectation: harness.Expectation = .verified;
        pub const tolerance: f32 = 0;
        pub const buffers = [_]harness.FamilyBuffer{
            .{ .tensor = harness.vec(.i32, bin_count), .access = .inout },
            .{ .tensor = harness.vec(.f32, element_count_local) },
        };
        pub const observed: usize = 0;
        pub const geometry = gpu_abi.LaunchGeometry{
            .grid = .{ element_count_local / 32, 1, 1 },
            .threadgroup = .{ 32, 1, 1 },
        };

        fn valueAt(element: usize) f32 {
            return -1.6 + @as(f32, @floatFromInt((element * 13) % 41)) * 0.125;
        }

        pub fn fillBuffer(comptime index: usize, buffer: []u8) void {
            switch (index) {
                0 => @memset(buffer, 0),
                1 => for (std.mem.bytesAsSlice(f32, buffer), 0..) |*value, element| {
                    value.* = valueAt(element);
                },
                else => unreachable,
            }
        }

        pub fn runtimeArguments() ![4]gpu_abi.ScalarArgument {
            return histogram.histogramRuntimeArguments(instance);
        }

        pub fn buildArtifact(
            allocator: std.mem.Allocator,
            handle: harness.BackendHandle,
        ) !gpu.KernelArtifact {
            const entry_name = try histogram.histogramFamilyEntryName(allocator, instance);
            defer allocator.free(entry_name);
            var graph = try histogram.HistogramRuntimeFamilyF32.buildNamed(allocator, kernel_limits, entry_name, instance);
            defer graph.deinit();
            return accy.kernel.createKernelArtifact(allocator, handle, &graph, .{
                .authored_kernel_diagnostic_id = "conformance/histogram-family",
            });
        }

        pub fn reference(seeded: []const []const u8, expected: []u8) void {
            _ = seeded;
            const out = std.mem.bytesAsSlice(i32, expected);
            for (out) |*value| value.* = 0;
            for (0..element_count_local) |element| {
                const value = valueAt(element);
                if (histogram.histogramBinForValue(instance, value)) |bin| out[bin] += 1;
            }
        }
    };
}

pub const all = productRowsFor(.f32) ++
    productRowsFor(.i8) ++
    productRowsFor(.i16) ++
    productRowsFor(.i32) ++
    productRowsFor(.u8) ++
    productRowsFor(.u16) ++
    productRowsFor(.u32) ++
    productRowsFor(.i64) ++
    productRowsFor(.u64) ++
    productRowsFor(.f16) ++
    productRowsFor(.bf16) ++
    productRowsFor(.f64) ++
    boolMovementRows() ++
    [_]type{
        TanhAddF32,
        BiasBroadcastF32,
        DotRectF32,
        EinsumMatmulF32,
        EinsumPermuteF32,
        ReduceSumAxisZeroF32,
        ReduceSumAllF32,
        AddRankThreeF32,
        ReduceSumRankThreeTrailingF32,
        ReduceSumRankThreeF32,
        ReduceMaxRankThreeF32,
        ReduceSumSplitAxesF32,
        GatherClampF32,
        ScatterCase("scatter_duplicate_f32_6x8_axis0", .f32, .verified, .{ 2, 0, 2, 5 }),
        ScatterCase("scatter_oob_f32_6x8_axis0", .f32, .verified, .{ -1, 9, 3, 0 }),
        MatrixProductFamilyCase,
        BatchedMatrixProductFamilyCase,
        MatrixVectorProductFamilyCase,
        OuterProductFamilyCase,
        GatherFamilyCase("gather_family_f32_2x5x6x3", .f32),
        GatherFamilyCase("gather_family_f16_2x5x6x3", .f16),
        ScatterFamilyCase("scatter_family_f32_2x5x6x3", .f32),
        ScatterFamilyCase("scatter_family_f16_2x5x6x3", .f16),
        ScatterAddFamilyCase("scatter_add_family_direct_i32_16x64", .i32, .direct, 0),
        ScatterAddFamilyCase("scatter_add_family_shared_i32_16x64", .i32, .shared_bins, 0),
        ScatterAddFamilyCase("scatter_add_family_direct_f32_16x64", .f32, .direct, 0.001),
        PrefixSumFamilyCase("prefix_sum_family_inclusive_f32_64", .f32, .inclusive),
        PrefixSumFamilyCase("prefix_sum_family_exclusive_f32_64", .f32, .exclusive),
        PrefixSumFamilyCase("prefix_sum_family_inclusive_u32_64", .u32, .inclusive),
        PrefixSumFamilyCase("prefix_sum_family_exclusive_u32_64", .u32, .exclusive),
        SegmentSumFamilyCase("segment_sum_family_thread_f32_8x80", .thread),
        SegmentSumFamilyCase("segment_sum_family_warp_f32_8x80", .warp),
        FilterFamilyCase("filter_family_nonzero_f32_70x32", .f32, .nonzero),
        FilterFamilyCase("filter_family_greater_i32_40x32", .i32, .greater_than),
        BitonicBlockFamilyCase,
        TopKBlockFamilyCase,
        TopKBlockPairsFamilyCase("top_k_block_pairs_family_keys_i32_8of45x64", 0),
        TopKBlockPairsFamilyCase("top_k_block_pairs_family_values_i32_8of45x64", 1),
        DeviceScanBlockScanFamilyCase("device_scan_block_scan_family_dst_f32_3x32", .f32, 0),
        DeviceScanBlockScanFamilyCase("device_scan_block_scan_family_sums_f32_3x32", .f32, 2),
        DeviceScanBlockScanFamilyCase("device_scan_block_scan_family_dst_f16_3x32", .f16, 0),
        DeviceScanBlockScanFamilyCase("device_scan_block_scan_family_sums_f16_3x32", .f16, 2),
        DeviceScanBlockScanFamilyCase("device_scan_block_scan_family_dst_u32_3x32", .u32, 0),
        DeviceScanBlockScanFamilyCase("device_scan_block_scan_family_sums_u32_3x32", .u32, 2),
        DeviceScanAddBaseFamilyCase("device_scan_add_base_family_f32_3x32", .f32),
        DeviceScanAddBaseFamilyCase("device_scan_add_base_family_f16_3x32", .f16),
        DeviceScanAddBaseFamilyCase("device_scan_add_base_family_u32_3x32", .u32),
        BatchedCholeskyFamilyCase,
        BatchedCholeskyInterleavedFamilyCase,
        BatchedCholeskySolveFamilyCase("batched_cholesky_solve_family_f32_48x3", .row_major),
        BatchedCholeskySolveFamilyCase("batched_cholesky_solve_family_f32_48x3_interleaved", .interleaved),
        BatchedInverseFamilyCase("batched_inverse_family_f32_48x3", .row_major),
        BatchedInverseFamilyCase("batched_inverse_family_f32_48x3_interleaved", .interleaved),
        GridCellsFamilyCase,
        ImageBlurPassFamilyCase,
        ImageResizeFamilyCase,
        SdfGridSampleGradient2DCase("sdf_grid_sample_gradient_family_f32_2d_96points_dist", 0),
        SdfGridSampleGradient2DCase("sdf_grid_sample_gradient_family_f32_2d_96points_gx", 1),
        SdfGridSampleGradient2DCase("sdf_grid_sample_gradient_family_f32_2d_96points_gy", 2),
        SdfGridSample3DFamilyCase,
        GridNeighborCountFamilyCase,
        SpmvCsrFamilyCase("spmv_csr_row_warp_family_f32_48rows", .row_warp, .f32),
        SpmvCsrFamilyCase("spmv_csr_row_thread_family_f32_48rows", .row_thread, .f32),
        SpmvCsrFamilyCase("spmv_csr_row_warp_family_f16_48rows", .row_warp, .f16),
        SpmvCsrFamilyCase("spmv_csr_row_thread_family_f16_48rows", .row_thread, .f16),
        SpmvCsrFamilyCase("spmv_csr_row_warp_family_f64_48rows", .row_warp, .f64),
        SpmvCsrFamilyCase("spmv_csr_row_thread_family_f64_48rows", .row_thread, .f64),
        SpmvCooFamilyCase("spmv_coo_element_thread_family_f32_48x96", .f32),
        SpmvCooFamilyCase("spmv_coo_row_thread_family_f16_48x96", .f16),
        SpmvCooFamilyCase("spmv_coo_row_thread_family_f64_48x96", .f64),
        SpmvEllFamilyCase("spmv_ell_row_thread_family_f32_48x6", .f32),
        SpmvEllFamilyCase("spmv_ell_row_thread_family_f16_48x6", .f16),
        SpmvEllFamilyCase("spmv_ell_row_thread_family_f64_48x6", .f64),
        SpmvSellFamilyCase("spmv_sell_row_thread_slice8_family_f32_48x8", .f32),
        SpmvSellFamilyCase("spmv_sell_row_thread_slice8_family_f16_48x8", .f16),
        SpmvSellFamilyCase("spmv_sell_row_thread_slice8_family_f64_48x8", .f64),
        SpmmCsrFamilyCase("spmm_csr_row_column_thread_family_f32_32x9", .f32),
        SpmmCsrFamilyCase("spmm_csr_row_column_thread_family_f16_32x9", .f16),
        SpmmCsrFamilyCase("spmm_csr_row_column_thread_family_f64_32x9", .f64),
        PhiloxFillFamilyI32,
        ThreefryFillFamilyI32,
        SquaresFillFamilyI32,
        FeistelPermutationFamilyI32,
        WhileTriangularI32,
        HistogramFamilyCase("histogram_family_direct_f32_16x96", .direct),
        HistogramFamilyCase("histogram_family_shared_f32_16x96", .shared_bins),
    };

test "conformance family rows declare backend feature and subgroup requirements" {
    const ScatterF32 = ScatterAddFamilyCase("require_scatter_add_f32", .f32, .direct, 0.001);
    try std.testing.expect(harness.requiredFeatures(ScatterF32).atomic_f32_add_device);

    const Prefix = PrefixSumFamilyCase("require_prefix_sum", .f32, .inclusive);
    try std.testing.expect(harness.requiredSubgroup(Prefix).scan);

    const SegmentThread = SegmentSumFamilyCase("require_segment_thread", .thread);
    try std.testing.expect(std.meta.eql(gpu_abi.SubgroupRequirements{}, harness.requiredSubgroup(SegmentThread)));
    const SegmentWarp = SegmentSumFamilyCase("require_segment_warp", .warp);
    try std.testing.expect(harness.requiredSubgroup(SegmentWarp).arithmetic);

    const Filter = FilterFamilyCase("require_filter", .f32, .nonzero);
    try std.testing.expect(harness.requiredSubgroup(Filter).scan);

    const DeviceScan = DeviceScanBlockScanFamilyCase("require_device_scan", .f32, 0);
    try std.testing.expect(harness.requiredSubgroup(DeviceScan).scan);

    const CsrThread = SpmvCsrFamilyCase("require_csr_thread", .row_thread, .f32);
    try std.testing.expect(std.meta.eql(gpu_abi.SubgroupRequirements{}, harness.requiredSubgroup(CsrThread)));
    const CsrWarp = SpmvCsrFamilyCase("require_csr_warp", .row_warp, .f32);
    try std.testing.expect(harness.requiredSubgroup(CsrWarp).arithmetic);

    const CooF32 = SpmvCooFamilyCase("require_coo_f32", .f32);
    try std.testing.expect(harness.requiredFeatures(CooF32).atomic_f32_add_device);
    const CooF16 = SpmvCooFamilyCase("require_coo_f16", .f16);
    try std.testing.expect(std.meta.eql(gpu_abi.Features{}, harness.requiredFeatures(CooF16)));
}

test "conformance case names are unique" {
    comptime {
        @setEvalBranchQuota(4_000_000);
        for (all, 0..) |Spec, index| {
            for (all, 0..) |Other, other_index| {
                if (index != other_index and std.mem.eql(u8, Spec.name, Other.name)) {
                    @compileError("duplicate conformance case name: " ++ Spec.name);
                }
            }
        }
    }
}

test "conformance case modules build and verify" {
    @setEvalBranchQuota(200_000);
    inline for (all) |Spec| {
        if (comptime @hasDecl(Spec, "buildArtifact")) continue;
        if (comptime Spec.expectation == .invalid) {
            if (harness.buildModule(Spec, std.testing.allocator)) |module| {
                module.deinit();
                return error.TestUnexpectedResult;
            } else |_| {}
        } else {
            const module = try harness.buildModule(Spec, std.testing.allocator);
            module.deinit();
        }
    }
}

test "conformance float references stay finite on their fills" {
    @setEvalBranchQuota(200_000);
    inline for (all) |Spec| {
        if (comptime @hasDecl(Spec, "buildArtifact")) continue;
        if (comptime (Spec.output.dtype.isFloat() and Spec.expectation != .invalid)) {
            var views: [Spec.inputs.len][]const u8 = undefined;
            var buffers: [Spec.inputs.len][]align(16) u8 = undefined;
            inline for (Spec.inputs, 0..) |input, index| {
                const buffer = try std.testing.allocator.alignedAlloc(u8, .@"16", input.byteCount());
                if (@hasDecl(Spec, "fill")) {
                    Spec.fill(index, buffer);
                } else {
                    harness.defaultFill(input.dtype, index, buffer);
                }
                buffers[index] = buffer;
                views[index] = buffer;
            }
            defer {
                inline for (0..Spec.inputs.len) |index| std.testing.allocator.free(buffers[index]);
            }

            const output_bytes = try std.testing.allocator.alignedAlloc(u8, .@"16", Spec.output.byteCount());
            defer std.testing.allocator.free(output_bytes);
            Spec.reference(&views, output_bytes);

            const T = comptime Spec.output.dtype.ZigType();
            const values = std.mem.bytesAsSlice(T, output_bytes);
            for (values) |value| {
                try std.testing.expect(std.math.isFinite(harness.numericToF32(T, value)));
            }
        }
    }
}

test "conformance references are deterministic" {
    var lhs: [element_count * 4]u8 align(16) = undefined;
    var rhs: [element_count * 4]u8 align(16) = undefined;
    harness.defaultFill(.f32, 0, lhs[0..]);
    harness.defaultFill(.f32, 1, rhs[0..]);
    var first: [element_count * 4]u8 align(16) = undefined;
    var second: [element_count * 4]u8 align(16) = undefined;
    TanhAddF32.reference(&.{ lhs[0..], rhs[0..] }, first[0..]);
    TanhAddF32.reference(&.{ lhs[0..], rhs[0..] }, second[0..]);
    try std.testing.expectEqualSlices(u8, first[0..], second[0..]);
    try std.testing.expect(harness.checksum(.f32, first[0..]) != 0);
}
