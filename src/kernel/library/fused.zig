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
