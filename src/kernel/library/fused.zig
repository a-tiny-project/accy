const std = @import("std");
const gpu = @import("gpu");

const activation_mod = @import("../../choir/root.zig").activation;
const elementwise = @import("elementwise.zig");
const entry = @import("entry.zig");
const kernel = @import("../root.zig");
const linalg = @import("linalg.zig");

fn activationName(comptime activation: activation_mod.Kind) []const u8 {
    return switch (activation) {
        .gelu => "gelu",
        .relu => "relu",
        .silu => "silu",
    };
}

fn activationValue(
    inner: anytype,
    comptime activation: activation_mod.Kind,
    value: anytype,
) !@TypeOf(value) {
    return switch (activation) {
        .gelu => elementwise.geluTanhApprox(inner, value),
        .relu => elementwise.relu(inner, value),
        .silu => elementwise.silu(inner, value),
    };
}

fn biasActivationSpecialization(
    comptime spec: entry.Vector1D,
    comptime activation: activation_mod.Kind,
) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .elementwise = .add },
        .inputs = &.{
            entry.shape1D(spec.axis, spec.extent),
            entry.shape1D(spec.axis, spec.extent),
        },
        .outputs = &.{entry.shape1D(spec.axis, spec.extent)},
        .epilogues = &.{entry.epilogue(.{ .activation = activation })},
        .launch = entry.launch1D(spec.extent, spec.threads),
        .schedule = entry.threadBlocks1D(spec.axis, spec.extent, spec.threads),
    };
}

fn bias_activation_each(inner: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const value = try ctx.args.param(.src).load(inner, index);
    const bias = try ctx.args.param(.bias).load(inner, index);
    const shifted = try value.add(inner, bias);
    const activated = try activationValue(inner, ctx.activation, shifted);
    try ctx.args.param(.dst).store(inner, activated, index);
}

fn biasActivationProgram(
    comptime spec: entry.Vector1D,
    comptime activation: activation_mod.Kind,
) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.axis, spec.extent, .{
                .args = args,
                .activation = activation,
            }, bias_activation_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_fused_bias_{s}{}x{}_f32",
            .{ activationName(activation), spec.extent, spec.threads },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
            .bias = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

fn biasActivationF32(comptime spec: entry.Vector1D, comptime activation: activation_mod.Kind) type {
    return entry.Entry(biasActivationProgram(spec, activation), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.fused.bias_{s}{}x{}_f32",
            .{ activationName(activation), spec.extent, spec.threads },
        ),
        .layer = .logical,
        .category = .fused,
        .specialization = biasActivationSpecialization(spec, activation),
    });
}

pub fn biasGeluF32(comptime spec: entry.Vector1D) type {
    return biasActivationF32(spec, .gelu);
}

pub fn biasReluF32(comptime spec: entry.Vector1D) type {
    return biasActivationF32(spec, .relu);
}

pub fn biasSiluF32(comptime spec: entry.Vector1D) type {
    return biasActivationF32(spec, .silu);
}

pub const BiasGelu8F32 = biasGeluF32(.{ .extent = 8, .threads = 4 });
pub const BiasRelu8F32 = biasReluF32(.{ .extent = 8, .threads = 4 });
pub const BiasSilu8F32 = biasSiluF32(.{ .extent = 8, .threads = 4 });

const GatedActivation = activation_mod.Kind;

fn gatedActivationName(comptime activation: GatedActivation) []const u8 {
    return switch (activation) {
        .gelu => "geglu",
        .relu => "reglu",
        .silu => "swiglu",
    };
}

fn gatedActivationValue(
    inner: anytype,
    comptime activation: GatedActivation,
    value: anytype,
) !@TypeOf(value) {
    return activationValue(inner, activation, value);
}

fn gatedActivationSpecialization(
    comptime spec: entry.Vector1D,
    comptime activation: GatedActivation,
) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .elementwise = .mul },
        .inputs = &.{
            entry.shape1D(spec.axis, spec.extent),
            entry.shape1D(spec.axis, spec.extent),
        },
        .outputs = &.{entry.shape1D(spec.axis, spec.extent)},
        .input_transforms = &.{entry.inputTransform(
            .{ .activation = activation },
            0,
            entry.shape1D(spec.axis, spec.extent),
        )},
        .launch = entry.launch1D(spec.extent, spec.threads),
        .schedule = entry.threadBlocks1D(spec.axis, spec.extent, spec.threads),
    };
}

fn gated_activation_each(inner: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const gate = try ctx.args.param(.gate).load(inner, index);
    const value = try ctx.args.param(.value).load(inner, index);
    const activated = try gatedActivationValue(inner, ctx.activation, gate);
    const output = try activated.mul(inner, value);
    try ctx.args.param(.dst).store(inner, output, index);
}

fn gatedActivationProgram(
    comptime spec: entry.Vector1D,
    comptime activation: GatedActivation,
) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.axis, spec.extent, .{
                .args = args,
                .activation = activation,
            }, gated_activation_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_fused_{s}{}x{}_f32",
            .{ gatedActivationName(activation), spec.extent, spec.threads },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .gate = kernel.dynamicBuffer(.f32),
            .value = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

fn gatedActivationF32(comptime spec: entry.Vector1D, comptime activation: GatedActivation) type {
    return entry.Entry(gatedActivationProgram(spec, activation), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.fused.{s}{}x{}_f32",
            .{ gatedActivationName(activation), spec.extent, spec.threads },
        ),
        .layer = .logical,
        .category = .fused,
        .specialization = gatedActivationSpecialization(spec, activation),
    });
}

pub fn geGluF32(comptime spec: entry.Vector1D) type {
    return gatedActivationF32(spec, .gelu);
}

pub fn reGluF32(comptime spec: entry.Vector1D) type {
    return gatedActivationF32(spec, .relu);
}

pub fn swiGluF32(comptime spec: entry.Vector1D) type {
    return gatedActivationF32(spec, .silu);
}

pub const GeGlu8F32 = geGluF32(.{ .extent = 8, .threads = 4 });
pub const ReGlu8F32 = reGluF32(.{ .extent = 8, .threads = 4 });
pub const SwiGlu8F32 = swiGluF32(.{ .extent = 8, .threads = 4 });

fn matrixProductBiasActivationSpecialization(
    comptime spec: linalg.MatrixProduct,
    comptime activation: activation_mod.Kind,
) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .linalg = .matrix_product },
        .equation = "mk,kn,n->mn",
        .inputs = &.{
            entry.shape2D(spec.row_axis, spec.m, spec.reduction_axis, spec.k),
            entry.shape2D(spec.reduction_axis, spec.k, spec.col_axis, spec.n),
            entry.shape1D(spec.col_axis, spec.n),
        },
        .outputs = &.{entry.shape2D(spec.row_axis, spec.m, spec.col_axis, spec.n)},
        .reductions = &.{
            entry.reduction("dot", .dot_product, entry.shape1D(spec.reduction_axis, spec.k)),
        },
        .epilogues = &.{
            entry.inputEpilogue(.bias_add, 2, entry.shape1D(spec.col_axis, spec.n)),
            entry.epilogue(.{ .activation = activation }),
        },
        .launch = entry.launch2D(spec.n, spec.m, spec.threads.x, spec.threads.y),
        .schedule = entry.threadBlocks2D(
            spec.col_axis,
            spec.n,
            spec.row_axis,
            spec.m,
            spec.threads.x,
            spec.threads.y,
        ),
    };
}

fn matrix_product_bias_activation_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const sum = try linalg.matrixProductCellSum(
        inner,
        ctx.spec,
        ctx.args.param(.lhs),
        ctx.args.param(.rhs),
        index.y.index,
        index.x.index,
    );
    const bias = try ctx.args.param(.bias).load(inner, index.x.index);
    const shifted = try bias.add(inner, sum);
    const activated = try activationValue(inner, ctx.activation, shifted);
    const out_index = try linalg.matrixProductOutputIndex(
        inner,
        ctx.spec,
        index.y.index,
        index.x.index,
    );
    try ctx.args.param(.dst).store(inner, activated, out_index);
}

fn matrixProductBiasActivationProgram(
    comptime spec: linalg.MatrixProduct,
    comptime activation: activation_mod.Kind,
) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach2D(.{
                .x = kernel.logical.axis(spec.col_axis, spec.n),
                .y = kernel.logical.axis(spec.row_axis, spec.m),
            }, .{
                .spec = spec,
                .activation = activation,
                .args = args,
            }, matrix_product_bias_activation_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_fused_matmul_bias_{s}{}x{}x{}_{}x{}_f32",
            .{ activationName(activation), spec.m, spec.n, spec.k, spec.threads.x, spec.threads.y },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .lhs = kernel.dynamicBuffer(.f32),
            .rhs = kernel.dynamicBuffer(.f32),
            .bias = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

fn matrixProductBiasActivationF32(
    comptime spec: linalg.MatrixProduct,
    comptime activation: activation_mod.Kind,
) type {
    return entry.Entry(matrixProductBiasActivationProgram(spec, activation), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.fused.matmul_bias_{s}{}x{}x{}_{}x{}_f32",
            .{ activationName(activation), spec.m, spec.n, spec.k, spec.threads.x, spec.threads.y },
        ),
        .layer = .logical,
        .category = .fused,
        .specialization = matrixProductBiasActivationSpecialization(spec, activation),
    });
}

pub fn matrixProductBiasGeluF32(comptime spec: linalg.MatrixProduct) type {
    return matrixProductBiasActivationF32(spec, .gelu);
}

pub fn matrixProductBiasReluF32(comptime spec: linalg.MatrixProduct) type {
    return matrixProductBiasActivationF32(spec, .relu);
}

pub fn matrixProductBiasSiluF32(comptime spec: linalg.MatrixProduct) type {
    return matrixProductBiasActivationF32(spec, .silu);
}

pub const MatrixProductBiasGelu2x3x4F32 = matrixProductBiasGeluF32(.{
    .m = 2,
    .n = 3,
    .k = 4,
    .threads = .{ .x = 2, .y = 2 },
});
pub const MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32 = matrixProductBiasGeluF32(.{
    .m = 2,
    .n = 3,
    .k = 4,
    .threads = .{ .x = 1, .y = 2 },
});
pub const MatrixProductBiasRelu2x3x4F32 = matrixProductBiasReluF32(.{
    .m = 2,
    .n = 3,
    .k = 4,
    .threads = .{ .x = 2, .y = 2 },
});
pub const MatrixProductBiasSilu2x3x4F32 = matrixProductBiasSiluF32(.{
    .m = 2,
    .n = 3,
    .k = 4,
    .threads = .{ .x = 2, .y = 2 },
});

fn matrixVectorProductBiasActivationSpecialization(
    comptime spec: linalg.MatrixVectorProduct,
    comptime activation: activation_mod.Kind,
) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .linalg = .matrix_vector_product },
        .equation = "mk,k,m->m",
        .inputs = &.{
            entry.shape2D(spec.row_axis, spec.m, spec.reduction_axis, spec.k),
            entry.shape1D(spec.reduction_axis, spec.k),
            entry.shape1D(spec.row_axis, spec.m),
        },
        .outputs = &.{entry.shape1D(spec.row_axis, spec.m)},
        .reductions = &.{
            entry.reduction("dot", .dot_product, entry.shape1D(spec.reduction_axis, spec.k)),
        },
        .epilogues = &.{
            entry.inputEpilogue(.bias_add, 2, entry.shape1D(spec.row_axis, spec.m)),
            entry.epilogue(.{ .activation = activation }),
        },
        .launch = entry.launch1D(spec.m, spec.threads),
        .schedule = entry.threadBlocks1D(spec.row_axis, spec.m, spec.threads),
    };
}

fn matrix_vector_product_bias_activation_each(
    inner: anytype,
    index: kernel.Index1D,
    ctx: anytype,
) !void {
    const sum = try linalg.matrixVectorProductRowSum(
        inner,
        ctx.spec,
        ctx.args.param(.matrix),
        ctx.args.param(.vector),
        index.index,
    );
    const bias = try ctx.args.param(.bias).load(inner, index);
    const shifted = try bias.add(inner, sum);
    const activated = try activationValue(inner, ctx.activation, shifted);
    try ctx.args.param(.dst).store(inner, activated, index);
}

fn matrixVectorProductBiasActivationProgram(
    comptime spec: linalg.MatrixVectorProduct,
    comptime activation: activation_mod.Kind,
) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.row_axis, spec.m, .{
                .spec = spec,
                .activation = activation,
                .args = args,
            }, matrix_vector_product_bias_activation_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_fused_matvec_bias_{s}{}x{}_{}x_f32",
            .{ activationName(activation), spec.m, spec.k, spec.threads },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .matrix = kernel.dynamicBuffer(.f32),
            .vector = kernel.dynamicBuffer(.f32),
            .bias = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

fn matrixVectorProductBiasActivationF32(
    comptime spec: linalg.MatrixVectorProduct,
    comptime activation: activation_mod.Kind,
) type {
    return entry.Entry(matrixVectorProductBiasActivationProgram(spec, activation), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.fused.matvec_bias_{s}{}x{}_{}x_f32",
            .{ activationName(activation), spec.m, spec.k, spec.threads },
        ),
        .layer = .logical,
        .category = .fused,
        .specialization = matrixVectorProductBiasActivationSpecialization(spec, activation),
    });
}

pub fn matrixVectorProductBiasGeluF32(comptime spec: linalg.MatrixVectorProduct) type {
    return matrixVectorProductBiasActivationF32(spec, .gelu);
}

pub fn matrixVectorProductBiasReluF32(comptime spec: linalg.MatrixVectorProduct) type {
    return matrixVectorProductBiasActivationF32(spec, .relu);
}

pub fn matrixVectorProductBiasSiluF32(comptime spec: linalg.MatrixVectorProduct) type {
    return matrixVectorProductBiasActivationF32(spec, .silu);
}

pub const MatrixVectorProductBiasGelu4x8F32 = matrixVectorProductBiasGeluF32(.{
    .m = 4,
    .k = 8,
    .threads = 4,
});
pub const MatrixVectorProductBiasRelu4x8F32 = matrixVectorProductBiasReluF32(.{
    .m = 4,
    .k = 8,
    .threads = 4,
});
pub const MatrixVectorProductBiasSilu4x8F32 = matrixVectorProductBiasSiluF32(.{
    .m = 4,
    .k = 8,
    .threads = 4,
});

fn expectedActivation(comptime activation: activation_mod.Kind, value: f32) f32 {
    return switch (activation) {
        .gelu => 0.5 * value * (1.0 + std.math.tanh(
            0.7978845608028654 * (value + 0.044715 * value * value * value),
        )),
        .relu => if (value > 0.0) value else 0.0,
        .silu => value / (1.0 + @exp(-value)),
    };
}

fn expectedBiasActivation(comptime activation: activation_mod.Kind, value: f32, bias: f32) f32 {
    return expectedActivation(activation, value + bias);
}

fn expectedSwiGlu(gate: f32, value: f32) f32 {
    return gate / (1.0 + @exp(-gate)) * value;
}

fn expectedGeGlu(gate: f32, value: f32) f32 {
    return expectedActivation(.gelu, gate) * value;
}

fn expectedReGlu(gate: f32, value: f32) f32 {
    if (gate > 0.0) return gate * value;
    return 0.0;
}

test "fused bias gelu entry runs on CPU and records fused operation" {
    var src = [_]f32{ -3.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 4.0 };
    var bias = [_]f32{ 0.25, -0.5, 0.5, 1.0, -0.25, 0.75, -1.0, 0.0 };
    var dst = @as([8]f32, @splat(0.0));

    try BiasGelu8F32.runCpu(std.testing.allocator, BiasGelu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, bias[0..]),
    });
    for (src, bias, dst) |input, bias_value, actual| {
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.gelu, input, bias_value),
            actual,
            0.0001,
        );
    }

    const launch_value = try BiasGelu8F32.launch(
        std.testing.allocator,
        BiasGelu8F32.Limits.testing,
    );
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(entry.Category.fused, BiasGelu8F32.category);
    try std.testing.expect(BiasGelu8F32.specialization.operationIs(.{ .elementwise = .add }));
    try std.testing.expect(
        BiasGelu8F32.specialization.epilogueMatches(0, .{ .operator = .{ .activation = .gelu } }),
    );
    try std.testing.expectEqual(@as(usize, 2), BiasGelu8F32.specialization.inputs.len);
    try std.testing.expectEqual(
        @as(u64, 8),
        BiasGelu8F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expectEqualDeep(
        BiasGelu8F32.specialization.launch.?,
        BiasGelu8F32.specialization.schedule.?.launch(),
    );

    var snapshot = try BiasGelu8F32.scheduleSnapshot(
        std.testing.allocator,
        BiasGelu8F32.Limits.testing,
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(BiasGelu8F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "fused bias relu and silu entries run on CPU" {
    var src = [_]f32{ -3.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 4.0 };
    var bias = [_]f32{ 0.25, -0.5, 0.5, 1.0, -0.25, 0.75, -1.0, 0.0 };
    var relu_dst = @as([8]f32, @splat(0.0));
    var silu_dst = @as([8]f32, @splat(0.0));

    try BiasRelu8F32.runCpu(std.testing.allocator, BiasRelu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, relu_dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, bias[0..]),
    });
    try BiasSilu8F32.runCpu(std.testing.allocator, BiasSilu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, silu_dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, bias[0..]),
    });
    for (src, bias, relu_dst, silu_dst) |input, bias_value, relu_actual, silu_actual| {
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.relu, input, bias_value),
            relu_actual,
            0.0001,
        );
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.silu, input, bias_value),
            silu_actual,
            0.0001,
        );
    }

    try std.testing.expect(
        BiasRelu8F32.specialization.epilogueMatches(0, .{ .operator = .{ .activation = .relu } }),
    );
    try std.testing.expect(
        BiasSilu8F32.specialization.epilogueMatches(0, .{ .operator = .{ .activation = .silu } }),
    );
}

test "fused swiglu entry runs on CPU and records input transform" {
    var gate = [_]f32{ -5.0, -2.0, -1.0, 0.0, 0.5, 1.0, 3.0, 6.0 };
    var value = [_]f32{ 2.0, -1.0, 0.5, 3.0, -2.0, 4.0, 0.25, -0.5 };
    var dst = @as([8]f32, @splat(0.0));

    try SwiGlu8F32.runCpu(std.testing.allocator, SwiGlu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, gate[0..]),
        kernel.argumentBuffer(f32, value[0..]),
    });
    for (gate, value, dst) |gate_value, input_value, actual| {
        try std.testing.expectApproxEqAbs(expectedSwiGlu(gate_value, input_value), actual, 0.0001);
    }

    const launch_value = try SwiGlu8F32.launch(std.testing.allocator, SwiGlu8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(entry.Category.fused, SwiGlu8F32.category);
    try std.testing.expect(SwiGlu8F32.specialization.operationIs(.{ .elementwise = .mul }));
    try std.testing.expect(SwiGlu8F32.specialization.inputTransformMatches(0, .{
        .operator = .{ .activation = .silu },
        .input_index = 0,
        .extents = &.{8},
    }));
    try std.testing.expectEqual(@as(usize, 2), SwiGlu8F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 8), SwiGlu8F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualDeep(
        SwiGlu8F32.specialization.launch.?,
        SwiGlu8F32.specialization.schedule.?.launch(),
    );

    var snapshot = try SwiGlu8F32.scheduleSnapshot(
        std.testing.allocator,
        SwiGlu8F32.Limits.testing,
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(SwiGlu8F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "fused geglu entry runs on CPU and records input transform" {
    var gate = [_]f32{ -5.0, -2.0, -1.0, 0.0, 0.5, 1.0, 3.0, 6.0 };
    var value = [_]f32{ 2.0, -1.0, 0.5, 3.0, -2.0, 4.0, 0.25, -0.5 };
    var dst = @as([8]f32, @splat(0.0));

    try GeGlu8F32.runCpu(std.testing.allocator, GeGlu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, gate[0..]),
        kernel.argumentBuffer(f32, value[0..]),
    });
    for (gate, value, dst) |gate_value, input_value, actual| {
        try std.testing.expectApproxEqAbs(expectedGeGlu(gate_value, input_value), actual, 0.0001);
    }

    const launch_value = try GeGlu8F32.launch(std.testing.allocator, GeGlu8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(entry.Category.fused, GeGlu8F32.category);
    try std.testing.expect(GeGlu8F32.specialization.operationIs(.{ .elementwise = .mul }));
    try std.testing.expect(GeGlu8F32.specialization.inputTransformMatches(0, .{
        .operator = .{ .activation = .gelu },
        .input_index = 0,
        .extents = &.{8},
    }));
    try std.testing.expectEqual(@as(usize, 2), GeGlu8F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 8), GeGlu8F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualDeep(
        GeGlu8F32.specialization.launch.?,
        GeGlu8F32.specialization.schedule.?.launch(),
    );

    var snapshot = try GeGlu8F32.scheduleSnapshot(std.testing.allocator, GeGlu8F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(GeGlu8F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "fused reglu entry runs on CPU and records input transform" {
    var gate = [_]f32{ -5.0, -2.0, -1.0, 0.0, 0.5, 1.0, 3.0, 6.0 };
    var value = [_]f32{ 2.0, -1.0, 0.5, 3.0, -2.0, 4.0, 0.25, -0.5 };
    var dst = @as([8]f32, @splat(0.0));

    try ReGlu8F32.runCpu(std.testing.allocator, ReGlu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, gate[0..]),
        kernel.argumentBuffer(f32, value[0..]),
    });
    for (gate, value, dst) |gate_value, input_value, actual| {
        try std.testing.expectApproxEqAbs(expectedReGlu(gate_value, input_value), actual, 0.0001);
    }

    const launch_value = try ReGlu8F32.launch(std.testing.allocator, ReGlu8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(entry.Category.fused, ReGlu8F32.category);
    try std.testing.expect(ReGlu8F32.specialization.operationIs(.{ .elementwise = .mul }));
    try std.testing.expect(ReGlu8F32.specialization.inputTransformMatches(0, .{
        .operator = .{ .activation = .relu },
        .input_index = 0,
        .extents = &.{8},
    }));
    try std.testing.expectEqual(@as(usize, 2), ReGlu8F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 8), ReGlu8F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualDeep(
        ReGlu8F32.specialization.launch.?,
        ReGlu8F32.specialization.schedule.?.launch(),
    );

    var snapshot = try ReGlu8F32.scheduleSnapshot(std.testing.allocator, ReGlu8F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(ReGlu8F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "fused matrix product bias gelu entry runs on CPU and records epilogue operation" {
    var lhs = [_]f32{
        1.0, 2.0, 3.0, 4.0,
        5.0, 6.0, 7.0, 8.0,
    };
    var rhs = [_]f32{
        1.0, 0.0, 2.0,
        0.0, 1.0, 3.0,
        1.0, 1.0, 0.0,
        2.0, 0.0, 1.0,
    };
    var bias = [_]f32{ 0.25, -1.0, 0.5 };
    var dst = @as([6]f32, @splat(0.0));

    try MatrixProductBiasGelu2x3x4F32.runCpu(
        std.testing.allocator,
        MatrixProductBiasGelu2x3x4F32.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, dst[0..]),
            kernel.argumentBuffer(f32, lhs[0..]),
            kernel.argumentBuffer(f32, rhs[0..]),
            kernel.argumentBuffer(f32, bias[0..]),
        },
    );
    const dot = [_]f32{ 12.0, 5.0, 12.0, 28.0, 13.0, 36.0 };
    for (dot, dst, 0..) |sum, actual, index| {
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.gelu, sum, bias[index % 3]),
            actual,
            0.0001,
        );
    }

    const launch_value = try MatrixProductBiasGelu2x3x4F32.launch(
        std.testing.allocator,
        MatrixProductBiasGelu2x3x4F32.Limits.testing,
    );
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
    try std.testing.expectEqual(entry.Category.fused, MatrixProductBiasGelu2x3x4F32.category);
    try std.testing.expect(
        MatrixProductBiasGelu2x3x4F32.specialization.operationIs(.{ .linalg = .matrix_product }),
    );
    try std.testing.expectEqualStrings(
        "mk,kn,n->mn",
        MatrixProductBiasGelu2x3x4F32.specialization.equation.?,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        MatrixProductBiasGelu2x3x4F32.specialization.inputs.len,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        MatrixProductBiasGelu2x3x4F32.specialization.inputs[2].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        MatrixProductBiasGelu2x3x4F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expect(MatrixProductBiasGelu2x3x4F32.specialization.epilogueMatches(0, .{
        .operator = .bias_add,
        .input_index = 2,
        .extents = &.{3},
    }));
    try std.testing.expect(MatrixProductBiasGelu2x3x4F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .gelu } },
    ));
    try std.testing.expectEqualDeep(
        MatrixProductBiasGelu2x3x4F32.specialization.launch.?,
        MatrixProductBiasGelu2x3x4F32.specialization.schedule.?.launch(),
    );

    var snapshot = try MatrixProductBiasGelu2x3x4F32.scheduleSnapshot(
        std.testing.allocator,
        MatrixProductBiasGelu2x3x4F32.Limits.testing,
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(
        MatrixProductBiasGelu2x3x4F32.specialization.schedule.?.matchesSnapshot(&snapshot),
    );
}

test "fused matrix product bias relu and silu entries run on CPU" {
    var lhs = [_]f32{
        1.0, 2.0, 3.0, 4.0,
        5.0, 6.0, 7.0, 8.0,
    };
    var rhs = [_]f32{
        1.0, 0.0, 2.0,
        0.0, 1.0, 3.0,
        1.0, 1.0, 0.0,
        2.0, 0.0, 1.0,
    };
    var bias = [_]f32{ 0.25, -20.0, 0.5 };
    var relu_dst = @as([6]f32, @splat(0.0));
    var silu_dst = @as([6]f32, @splat(0.0));

    try MatrixProductBiasRelu2x3x4F32.runCpu(
        std.testing.allocator,
        MatrixProductBiasRelu2x3x4F32.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, relu_dst[0..]),
            kernel.argumentBuffer(f32, lhs[0..]),
            kernel.argumentBuffer(f32, rhs[0..]),
            kernel.argumentBuffer(f32, bias[0..]),
        },
    );
    try MatrixProductBiasSilu2x3x4F32.runCpu(
        std.testing.allocator,
        MatrixProductBiasSilu2x3x4F32.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, silu_dst[0..]),
            kernel.argumentBuffer(f32, lhs[0..]),
            kernel.argumentBuffer(f32, rhs[0..]),
            kernel.argumentBuffer(f32, bias[0..]),
        },
    );

    const dot = [_]f32{ 12.0, 5.0, 12.0, 28.0, 13.0, 36.0 };
    for (dot, relu_dst, silu_dst, 0..) |sum, relu_actual, silu_actual, index| {
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.relu, sum, bias[index % 3]),
            relu_actual,
            0.0001,
        );
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.silu, sum, bias[index % 3]),
            silu_actual,
            0.0001,
        );
    }

    try std.testing.expect(MatrixProductBiasRelu2x3x4F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .relu } },
    ));
    try std.testing.expect(MatrixProductBiasSilu2x3x4F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .silu } },
    ));
    try std.testing.expectEqualDeep(
        MatrixProductBiasRelu2x3x4F32.specialization.launch.?,
        MatrixProductBiasRelu2x3x4F32.specialization.schedule.?.launch(),
    );
    try std.testing.expectEqualDeep(
        MatrixProductBiasSilu2x3x4F32.specialization.launch.?,
        MatrixProductBiasSilu2x3x4F32.specialization.schedule.?.launch(),
    );
}

test "fused matrix vector product bias gelu entry runs on CPU and records epilogue operation" {
    var matrix = [_]f32{
        1.0,  2.0,  3.0,  4.0, 5.0,  6.0, 7.0,  8.0,
        2.0,  0.0,  -2.0, 0.0, 1.0,  0.0, -1.0, 0.0,
        0.5,  1.0,  1.5,  2.0, 2.5,  3.0, 3.5,  4.0,
        -1.0, -2.0, 3.0,  4.0, -5.0, 6.0, 7.0,  -8.0,
    };
    var vector = [_]f32{ 1.0, 0.5, -1.0, 2.0, 0.25, -0.5, 1.5, -2.0 };
    var bias = [_]f32{ 0.25, -1.0, 0.5, -20.0 };
    var dst = @as([4]f32, @splat(0.0));

    try MatrixVectorProductBiasGelu4x8F32.runCpu(
        std.testing.allocator,
        MatrixVectorProductBiasGelu4x8F32.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, dst[0..]),
            kernel.argumentBuffer(f32, matrix[0..]),
            kernel.argumentBuffer(f32, vector[0..]),
            kernel.argumentBuffer(f32, bias[0..]),
        },
    );
    const dot = [_]f32{ -0.25, 2.75, -0.125, 25.25 };
    for (dot, bias, dst) |sum, bias_value, actual| {
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.gelu, sum, bias_value),
            actual,
            0.0001,
        );
    }

    const launch_value = try MatrixVectorProductBiasGelu4x8F32.launch(
        std.testing.allocator,
        MatrixVectorProductBiasGelu4x8F32.Limits.testing,
    );
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(entry.Category.fused, MatrixVectorProductBiasGelu4x8F32.category);
    try std.testing.expect(MatrixVectorProductBiasGelu4x8F32.specialization.operationIs(
        .{ .linalg = .matrix_vector_product },
    ));
    try std.testing.expectEqualStrings(
        "mk,k,m->m",
        MatrixVectorProductBiasGelu4x8F32.specialization.equation.?,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        MatrixVectorProductBiasGelu4x8F32.specialization.inputs.len,
    );
    try std.testing.expectEqual(
        @as(u64, 4),
        MatrixVectorProductBiasGelu4x8F32.specialization.inputs[2].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 4),
        MatrixVectorProductBiasGelu4x8F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expect(MatrixVectorProductBiasGelu4x8F32.specialization.epilogueMatches(0, .{
        .operator = .bias_add,
        .input_index = 2,
        .extents = &.{4},
    }));
    try std.testing.expect(MatrixVectorProductBiasGelu4x8F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .gelu } },
    ));
    try std.testing.expectEqualDeep(
        MatrixVectorProductBiasGelu4x8F32.specialization.launch.?,
        MatrixVectorProductBiasGelu4x8F32.specialization.schedule.?.launch(),
    );

    var snapshot = try MatrixVectorProductBiasGelu4x8F32.scheduleSnapshot(
        std.testing.allocator,
        MatrixVectorProductBiasGelu4x8F32.Limits.testing,
    );
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(
        MatrixVectorProductBiasGelu4x8F32.specialization.schedule.?.matchesSnapshot(&snapshot),
    );
}

test "fused matrix vector product bias relu and silu entries run on CPU" {
    var matrix = [_]f32{
        1.0,  2.0,  3.0,  4.0, 5.0,  6.0, 7.0,  8.0,
        2.0,  0.0,  -2.0, 0.0, 1.0,  0.0, -1.0, 0.0,
        0.5,  1.0,  1.5,  2.0, 2.5,  3.0, 3.5,  4.0,
        -1.0, -2.0, 3.0,  4.0, -5.0, 6.0, 7.0,  -8.0,
    };
    var vector = [_]f32{ 1.0, 0.5, -1.0, 2.0, 0.25, -0.5, 1.5, -2.0 };
    var bias = [_]f32{ 0.25, -1.0, 0.5, -20.0 };
    var relu_dst = @as([4]f32, @splat(0.0));
    var silu_dst = @as([4]f32, @splat(0.0));

    try MatrixVectorProductBiasRelu4x8F32.runCpu(
        std.testing.allocator,
        MatrixVectorProductBiasRelu4x8F32.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, relu_dst[0..]),
            kernel.argumentBuffer(f32, matrix[0..]),
            kernel.argumentBuffer(f32, vector[0..]),
            kernel.argumentBuffer(f32, bias[0..]),
        },
    );
    try MatrixVectorProductBiasSilu4x8F32.runCpu(
        std.testing.allocator,
        MatrixVectorProductBiasSilu4x8F32.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, silu_dst[0..]),
            kernel.argumentBuffer(f32, matrix[0..]),
            kernel.argumentBuffer(f32, vector[0..]),
            kernel.argumentBuffer(f32, bias[0..]),
        },
    );

    const dot = [_]f32{ -0.25, 2.75, -0.125, 25.25 };
    for (dot, bias, relu_dst, silu_dst) |sum, bias_value, relu_actual, silu_actual| {
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.relu, sum, bias_value),
            relu_actual,
            0.0001,
        );
        try std.testing.expectApproxEqAbs(
            expectedBiasActivation(.silu, sum, bias_value),
            silu_actual,
            0.0001,
        );
    }

    try std.testing.expect(MatrixVectorProductBiasRelu4x8F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .relu } },
    ));
    try std.testing.expect(MatrixVectorProductBiasSilu4x8F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .silu } },
    ));
    try std.testing.expectEqualDeep(
        MatrixVectorProductBiasRelu4x8F32.specialization.launch.?,
        MatrixVectorProductBiasRelu4x8F32.specialization.schedule.?.launch(),
    );
    try std.testing.expectEqualDeep(
        MatrixVectorProductBiasSilu4x8F32.specialization.launch.?,
        MatrixVectorProductBiasSilu4x8F32.specialization.schedule.?.launch(),
    );
}

test "fused bias gelu constructor creates independent shape-specialized entries" {
    const BiasGelu16F32 = biasGeluF32(.{ .extent = 16, .threads = 8 });

    try std.testing.expectEqualStrings("accy.kernel.fused.bias_gelu8x4_f32", BiasGelu8F32.target);
    try std.testing.expectEqualStrings("accy.kernel.fused.bias_gelu16x8_f32", BiasGelu16F32.target);
    try std.testing.expectEqual(
        @as(u64, 8),
        BiasGelu8F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 16),
        BiasGelu16F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expect(BiasGelu16F32.specialization.operationIs(.{ .elementwise = .add }));
    try std.testing.expect(
        BiasGelu16F32.specialization.epilogueMatches(0, .{ .operator = .{ .activation = .gelu } }),
    );
    try std.testing.expectEqual(@as(u32, 8), BiasGelu16F32.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), BiasGelu16F32.specialization.launch.?.grid[0]);
}

test "fused swiglu constructor creates independent shape-specialized entries" {
    const SwiGlu16F32 = swiGluF32(.{ .extent = 16, .threads = 8 });

    try std.testing.expectEqualStrings("accy.kernel.fused.swiglu8x4_f32", SwiGlu8F32.target);
    try std.testing.expectEqualStrings("accy.kernel.fused.swiglu16x8_f32", SwiGlu16F32.target);
    try std.testing.expectEqual(@as(u64, 8), SwiGlu8F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(
        @as(u64, 16),
        SwiGlu16F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expect(SwiGlu16F32.specialization.operationIs(.{ .elementwise = .mul }));
    try std.testing.expect(SwiGlu16F32.specialization.inputTransformMatches(0, .{
        .operator = .{ .activation = .silu },
        .input_index = 0,
        .extents = &.{16},
    }));
    try std.testing.expectEqual(@as(u32, 8), SwiGlu16F32.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), SwiGlu16F32.specialization.launch.?.grid[0]);
}

test "fused geglu constructor creates independent shape-specialized entries" {
    const GeGlu16F32 = geGluF32(.{ .extent = 16, .threads = 8 });

    try std.testing.expectEqualStrings("accy.kernel.fused.geglu8x4_f32", GeGlu8F32.target);
    try std.testing.expectEqualStrings("accy.kernel.fused.geglu16x8_f32", GeGlu16F32.target);
    try std.testing.expectEqual(@as(u64, 8), GeGlu8F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(
        @as(u64, 16),
        GeGlu16F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expect(GeGlu16F32.specialization.operationIs(.{ .elementwise = .mul }));
    try std.testing.expect(GeGlu16F32.specialization.inputTransformMatches(0, .{
        .operator = .{ .activation = .gelu },
        .input_index = 0,
        .extents = &.{16},
    }));
    try std.testing.expectEqual(@as(u32, 8), GeGlu16F32.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), GeGlu16F32.specialization.launch.?.grid[0]);
}

test "fused reglu constructor creates independent shape-specialized entries" {
    const ReGlu16F32 = reGluF32(.{ .extent = 16, .threads = 8 });

    try std.testing.expectEqualStrings("accy.kernel.fused.reglu8x4_f32", ReGlu8F32.target);
    try std.testing.expectEqualStrings("accy.kernel.fused.reglu16x8_f32", ReGlu16F32.target);
    try std.testing.expectEqual(@as(u64, 8), ReGlu8F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(
        @as(u64, 16),
        ReGlu16F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expect(ReGlu16F32.specialization.operationIs(.{ .elementwise = .mul }));
    try std.testing.expect(ReGlu16F32.specialization.inputTransformMatches(0, .{
        .operator = .{ .activation = .relu },
        .input_index = 0,
        .extents = &.{16},
    }));
    try std.testing.expectEqual(@as(u32, 8), ReGlu16F32.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), ReGlu16F32.specialization.launch.?.grid[0]);
}

test "fused matrix product bias gelu constructor creates independent shape-specialized entries" {
    const MatrixProductBiasGelu4x5x6F32 = matrixProductBiasGeluF32(.{
        .m = 4,
        .n = 5,
        .k = 6,
        .threads = .{ .x = 4, .y = 2 },
    });

    try std.testing.expectEqualStrings(
        "accy.kernel.fused.matmul_bias_gelu2x3x4_2x2_f32",
        MatrixProductBiasGelu2x3x4F32.target,
    );
    try std.testing.expectEqualStrings(
        "accy.kernel.fused.matmul_bias_gelu2x3x4_1x2_f32",
        MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.target,
    );
    try std.testing.expectEqualStrings(
        "accy.kernel.fused.matmul_bias_gelu4x5x6_4x2_f32",
        MatrixProductBiasGelu4x5x6F32.target,
    );
    try std.testing.expect(MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.specialization.operationIs(
        .{ .linalg = .matrix_product },
    ));
    try std.testing.expectEqual(
        @as(u32, 1),
        MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.specialization.launch.?.threadgroup[0],
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.specialization.launch.?.threadgroup[1],
    );
    try std.testing.expectEqualDeep(
        MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.specialization.launch.?,
        MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.specialization.schedule.?.launch(),
    );
    try std.testing.expect(
        MatrixProductBiasGelu4x5x6F32.specialization.operationIs(.{ .linalg = .matrix_product }),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        MatrixProductBiasGelu4x5x6F32.specialization.inputs.len,
    );
    try std.testing.expectEqual(
        @as(u64, 24),
        MatrixProductBiasGelu4x5x6F32.specialization.inputs[0].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 30),
        MatrixProductBiasGelu4x5x6F32.specialization.inputs[1].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        MatrixProductBiasGelu4x5x6F32.specialization.inputs[2].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 20),
        MatrixProductBiasGelu4x5x6F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expectEqual(
        entry.ReductionOperator.dot_product,
        MatrixProductBiasGelu4x5x6F32.specialization.reductions[0].operator,
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        MatrixProductBiasGelu4x5x6F32.specialization.reductions[0].shape.elementCount().?,
    );
    try std.testing.expect(MatrixProductBiasGelu4x5x6F32.specialization.epilogueMatches(0, .{
        .operator = .bias_add,
        .input_index = 2,
        .extents = &.{5},
    }));
    try std.testing.expect(MatrixProductBiasGelu4x5x6F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .gelu } },
    ));
    try std.testing.expectEqualDeep(
        MatrixProductBiasGelu4x5x6F32.specialization.launch.?,
        MatrixProductBiasGelu4x5x6F32.specialization.schedule.?.launch(),
    );
}

test "fused matrix vector product bias gelu constructor creates independent shape-specialized entries" {
    const MatrixVectorProductBiasGelu5x6F32 = matrixVectorProductBiasGeluF32(.{
        .m = 5,
        .k = 6,
        .threads = 4,
    });

    try std.testing.expectEqualStrings(
        "accy.kernel.fused.matvec_bias_gelu4x8_4x_f32",
        MatrixVectorProductBiasGelu4x8F32.target,
    );
    try std.testing.expectEqualStrings(
        "accy.kernel.fused.matvec_bias_gelu5x6_4x_f32",
        MatrixVectorProductBiasGelu5x6F32.target,
    );
    try std.testing.expect(MatrixVectorProductBiasGelu5x6F32.specialization.operationIs(
        .{ .linalg = .matrix_vector_product },
    ));
    try std.testing.expectEqual(
        @as(usize, 3),
        MatrixVectorProductBiasGelu5x6F32.specialization.inputs.len,
    );
    try std.testing.expectEqual(
        @as(u64, 30),
        MatrixVectorProductBiasGelu5x6F32.specialization.inputs[0].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        MatrixVectorProductBiasGelu5x6F32.specialization.inputs[1].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        MatrixVectorProductBiasGelu5x6F32.specialization.inputs[2].elementCount().?,
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        MatrixVectorProductBiasGelu5x6F32.specialization.outputs[0].elementCount().?,
    );
    try std.testing.expectEqual(
        entry.ReductionOperator.dot_product,
        MatrixVectorProductBiasGelu5x6F32.specialization.reductions[0].operator,
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        MatrixVectorProductBiasGelu5x6F32.specialization.reductions[0].shape.elementCount().?,
    );
    try std.testing.expect(MatrixVectorProductBiasGelu5x6F32.specialization.epilogueMatches(0, .{
        .operator = .bias_add,
        .input_index = 2,
        .extents = &.{5},
    }));
    try std.testing.expect(MatrixVectorProductBiasGelu5x6F32.specialization.epilogueMatches(
        1,
        .{ .operator = .{ .activation = .gelu } },
    ));
    try std.testing.expectEqualDeep(
        MatrixVectorProductBiasGelu5x6F32.specialization.launch.?,
        MatrixVectorProductBiasGelu5x6F32.specialization.schedule.?.launch(),
    );
}

test "fused bias gelu entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try BiasGelu8F32.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = BiasGelu8F32.Limits.testing },
    );
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(
        BiasGelu8F32.target,
        BiasGelu8F32.version,
        .cuda_ptx,
    ) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(BiasGelu8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(
                BiasGelu8F32.specialization.launch.?.grid[0],
                geometry.grid[0],
            );
            try std.testing.expectEqual(
                BiasGelu8F32.specialization.launch.?.threadgroup[0],
                geometry.threadgroup[0],
            );
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "fused swiglu entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try SwiGlu8F32.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = SwiGlu8F32.Limits.testing },
    );
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(
        SwiGlu8F32.target,
        SwiGlu8F32.version,
        .cuda_ptx,
    ) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(SwiGlu8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(
                SwiGlu8F32.specialization.launch.?.grid[0],
                geometry.grid[0],
            );
            try std.testing.expectEqual(
                SwiGlu8F32.specialization.launch.?.threadgroup[0],
                geometry.threadgroup[0],
            );
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "fused geglu entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try GeGlu8F32.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = GeGlu8F32.Limits.testing },
    );
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(
        GeGlu8F32.target,
        GeGlu8F32.version,
        .cuda_ptx,
    ) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(GeGlu8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(
                GeGlu8F32.specialization.launch.?.grid[0],
                geometry.grid[0],
            );
            try std.testing.expectEqual(
                GeGlu8F32.specialization.launch.?.threadgroup[0],
                geometry.threadgroup[0],
            );
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "fused reglu entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try ReGlu8F32.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = ReGlu8F32.Limits.testing },
    );
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(
        ReGlu8F32.target,
        ReGlu8F32.version,
        .cuda_ptx,
    ) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(ReGlu8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(
                ReGlu8F32.specialization.launch.?.grid[0],
                geometry.grid[0],
            );
            try std.testing.expectEqual(
                ReGlu8F32.specialization.launch.?.threadgroup[0],
                geometry.threadgroup[0],
            );
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "fused matrix product bias gelu entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try MatrixProductBiasGelu2x3x4F32.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = MatrixProductBiasGelu2x3x4F32.Limits.testing },
    );
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(
        MatrixProductBiasGelu2x3x4F32.target,
        MatrixProductBiasGelu2x3x4F32.version,
        .cuda_ptx,
    ) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(MatrixProductBiasGelu2x3x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 4), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(
                MatrixProductBiasGelu2x3x4F32.specialization.launch.?.grid[0],
                geometry.grid[0],
            );
            try std.testing.expectEqual(
                MatrixProductBiasGelu2x3x4F32.specialization.launch.?.grid[1],
                geometry.grid[1],
            );
            try std.testing.expectEqual(
                MatrixProductBiasGelu2x3x4F32.specialization.launch.?.threadgroup[0],
                geometry.threadgroup[0],
            );
            try std.testing.expectEqual(
                MatrixProductBiasGelu2x3x4F32.specialization.launch.?.threadgroup[1],
                geometry.threadgroup[1],
            );
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "fused matrix vector product bias gelu entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try MatrixVectorProductBiasGelu4x8F32.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = MatrixVectorProductBiasGelu4x8F32.Limits.testing },
    );
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(
        MatrixVectorProductBiasGelu4x8F32.target,
        MatrixVectorProductBiasGelu4x8F32.version,
        .cuda_ptx,
    ) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(MatrixVectorProductBiasGelu4x8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 4), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(
                MatrixVectorProductBiasGelu4x8F32.specialization.launch.?.grid[0],
                geometry.grid[0],
            );
            try std.testing.expectEqual(
                MatrixVectorProductBiasGelu4x8F32.specialization.launch.?.threadgroup[0],
                geometry.threadgroup[0],
            );
        },
        else => return error.TestExpectedFixedLaunch,
    }
}
