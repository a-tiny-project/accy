const std = @import("std");
const gpu = @import("gpu");

const entry = @import("entry.zig");
const kernel = @import("../root.zig");

const RowNormalizationParameterization = entry.RowNormalizationParameterization;

pub const Threads2D = struct {
    x: u32 = 4,
    y: u32 = 2,
};

pub const Row = struct {
    rows: u64,
    cols: u64,
    threads: Threads2D = .{},
    row_axis: []const u8 = "row",
    col_axis: []const u8 = "col",
};

const RowDistribution = enum {
    softmax,
    log_softmax,
};

fn rowDistributionName(comptime kind: RowDistribution) []const u8 {
    return switch (kind) {
        .softmax => "softmax",
        .log_softmax => "log_softmax",
    };
}

fn rowDistributionOperator(comptime kind: RowDistribution) entry.RowNormalizationOperator {
    return switch (kind) {
        .softmax => .softmax,
        .log_softmax => .log_softmax,
    };
}

fn indexUpper(comptime extent: u64) i64 {
    if (extent > @as(u64, @intCast(std.math.maxInt(i64)))) {
        @compileError("kernel library normalization extent overflows index range");
    }
    return @intCast(extent);
}

fn floatExtent(comptime extent: u64) f64 {
    return @floatFromInt(extent);
}

fn rowDomain(comptime spec: Row) kernel.logical.Domain2D {
    return .{
        .x = kernel.logical.axis(spec.col_axis, spec.cols),
        .y = kernel.logical.axis(spec.row_axis, spec.rows),
    };
}

fn rowMatrixShape(comptime spec: Row) entry.Shape {
    return entry.shape2D(spec.row_axis, spec.rows, spec.col_axis, spec.cols);
}

fn rowShape(comptime spec: Row) entry.Shape {
    return entry.shape1D(spec.row_axis, spec.rows);
}

fn columnShape(comptime spec: Row) entry.Shape {
    return entry.shape1D(spec.col_axis, spec.cols);
}

fn rowLaunch(comptime spec: Row) entry.Launch {
    return entry.launch2D(spec.cols, spec.rows, spec.threads.x, spec.threads.y);
}

fn rowOffset(k: anytype, index: kernel.Index2D, comptime spec: Row) !kernel.Value {
    const cols_stride = try k.constantIndex(indexUpper(spec.cols));
    return k.mul(index.y.index, cols_stride);
}

fn rowItemIndex(k: anytype, index: kernel.Index2D, offset: kernel.Value) !kernel.Value {
    return k.add(offset, index.x.index);
}

fn foldColumnsFrom(
    k: anytype,
    comptime spec: Row,
    comptime lower: i64,
    initial: anytype,
    context: anytype,
    comptime body: anytype,
) !@TypeOf(initial) {
    return k.foldRange(lower, indexUpper(spec.cols), 1, initial, context, body);
}

fn foldColumns(k: anytype, comptime spec: Row, initial: anytype, context: anytype, comptime body: anytype) !@TypeOf(initial) {
    return foldColumnsFrom(k, spec, 0, initial, context, body);
}

fn rowDistributionSpecialization(comptime spec: Row, comptime kind: RowDistribution) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .row_normalization = rowDistributionOperator(kind) },
        .inputs = &.{rowMatrixShape(spec)},
        .outputs = &.{rowMatrixShape(spec)},
        .reductions = &.{
            entry.reduction("row_max", .maximum, columnShape(spec)),
            entry.dependentReduction("row_exp_sum", .sum_exp_shifted, columnShape(spec), &.{"row_max"}),
        },
        .reduction_reuse = &.{
            entry.reductionReuse("row_max", rowShape(spec)),
            entry.reductionReuse("row_exp_sum", rowShape(spec)),
        },
        .launch = rowLaunch(spec),
        .schedule = entry.threadBlocks2D(spec.col_axis, spec.cols, spec.row_axis, spec.rows, spec.threads.x, spec.threads.y),
    };
}

fn rowWeightedSpecialization(comptime spec: Row) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .row_normalization = .{ .rmsnorm = .scale } },
        .inputs = &.{
            rowMatrixShape(spec),
            columnShape(spec),
        },
        .outputs = &.{rowMatrixShape(spec)},
        .reductions = &.{entry.reduction("row_sum_squares", .sum_squares, columnShape(spec))},
        .reduction_reuse = &.{entry.reductionReuse("row_sum_squares", rowShape(spec))},
        .launch = rowLaunch(spec),
        .schedule = entry.threadBlocks2D(spec.col_axis, spec.cols, spec.row_axis, spec.rows, spec.threads.x, spec.threads.y),
    };
}

fn rowResidualRmsNormSpecialization(comptime spec: Row) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .row_normalization = .{ .rmsnorm = .scale } },
        .inputs = &.{
            rowMatrixShape(spec),
            rowMatrixShape(spec),
            columnShape(spec),
        },
        .outputs = &.{rowMatrixShape(spec)},
        .reductions = &.{entry.reduction("row_sum_squares", .sum_squares, columnShape(spec))},
        .reduction_reuse = &.{entry.reductionReuse("row_sum_squares", rowShape(spec))},
        .input_transforms = &.{entry.inputTransform(.residual_add, 1, rowMatrixShape(spec))},
        .launch = rowLaunch(spec),
        .schedule = entry.threadBlocks2D(spec.col_axis, spec.cols, spec.row_axis, spec.rows, spec.threads.x, spec.threads.y),
    };
}

fn rowLayerNormName(comptime parameterization: RowNormalizationParameterization) []const u8 {
    return switch (parameterization) {
        .none => "layernorm",
        .scale => "layernorm_scale",
        .scale_bias => "layernorm_affine",
    };
}

fn rowLayerNormInputs(comptime spec: Row, comptime parameterization: RowNormalizationParameterization) []const entry.Shape {
    return switch (parameterization) {
        .none => &.{rowMatrixShape(spec)},
        .scale => &.{
            rowMatrixShape(spec),
            columnShape(spec),
        },
        .scale_bias => &.{
            rowMatrixShape(spec),
            columnShape(spec),
            columnShape(spec),
        },
    };
}

fn rowLayerNormSpecialization(comptime spec: Row, comptime parameterization: RowNormalizationParameterization) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .row_normalization = .{ .layernorm = parameterization } },
        .inputs = rowLayerNormInputs(spec, parameterization),
        .outputs = &.{rowMatrixShape(spec)},
        .reductions = &.{
            entry.reduction("row_sum", .sum, columnShape(spec)),
            entry.dependentReduction("row_variance_sum", .sum_squared_difference, columnShape(spec), &.{"row_sum"}),
        },
        .reduction_reuse = &.{
            entry.reductionReuse("row_sum", rowShape(spec)),
            entry.reductionReuse("row_variance_sum", rowShape(spec)),
        },
        .launch = rowLaunch(spec),
        .schedule = entry.threadBlocks2D(spec.col_axis, spec.cols, spec.row_axis, spec.rows, spec.threads.x, spec.threads.y),
    };
}

fn rowDistributionValue(
    inner: anytype,
    comptime kind: RowDistribution,
    shifted: kernel.Value,
    denominator: kernel.Value,
) !kernel.Value {
    return switch (kind) {
        .softmax => blk: {
            const numerator = try inner.exp(shifted);
            break :blk try inner.div(numerator, denominator);
        },
        .log_softmax => blk: {
            const log_denominator = try inner.log(denominator);
            break :blk try inner.sub(shifted, log_denominator);
        },
    };
}

fn row_distribution_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const row_offset = try rowOffset(inner, index, ctx.spec);
    const item_index = try rowItemIndex(inner, index, row_offset);
    const each_args = ctx.args;
    const src = each_args.param(.src);
    const dst = each_args.param(.dst);
    const first = try src.load(inner, row_offset);
    const row_max = try foldColumnsFrom(inner, ctx.spec, 1, first.raw(), .{
        .src = src,
        .row_offset = row_offset,
    }, row_distribution_row_max);
    const current = try src.load(inner, item_index);
    const shifted = try inner.sub(current.raw(), row_max);
    const zero = try inner.constantFloat(.f32, 0.0);
    const denominator = try foldColumns(inner, ctx.spec, zero, .{
        .src = src,
        .row_offset = row_offset,
        .row_max = row_max,
    }, row_distribution_denominator);
    const normalized = try rowDistributionValue(inner, ctx.kind, shifted, denominator);
    try dst.store(inner, normalized, item_index);
}

fn row_distribution_row_max(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const reduce_index = try fold_inner.add(ctx.row_offset, offset);
    const value = try ctx.src.load(fold_inner, reduce_index);
    return fold_inner.max(acc, value.raw());
}

fn row_distribution_denominator(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const reduce_index = try fold_inner.add(ctx.row_offset, offset);
    const value = try ctx.src.load(fold_inner, reduce_index);
    const reduce_shifted = try fold_inner.sub(value.raw(), ctx.row_max);
    const exp_value = try fold_inner.exp(reduce_shifted);
    return fold_inner.add(acc, exp_value);
}

fn rowDistributionProgram(comptime spec: Row, comptime kind: RowDistribution) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach2D(rowDomain(spec), .{ .spec = spec, .kind = kind, .args = args }, row_distribution_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_normalization_{s}{}x{}_{}x{}_f32",
            .{ rowDistributionName(kind), spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

fn rowDistributionF32(comptime spec: Row, comptime kind: RowDistribution) type {
    return entry.Entry(rowDistributionProgram(spec, kind), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.normalization.{s}{}x{}_{}x{}_f32",
            .{ rowDistributionName(kind), spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .layer = .logical,
        .category = .normalization,
        .specialization = rowDistributionSpecialization(spec, kind),
    });
}

pub fn rowSoftmaxF32(comptime spec: Row) type {
    return rowDistributionF32(spec, .softmax);
}

pub fn rowLogSoftmaxF32(comptime spec: Row) type {
    return rowDistributionF32(spec, .log_softmax);
}

pub const RowSoftmax2x4F32 = rowSoftmaxF32(.{
    .rows = 2,
    .cols = 4,
    .threads = .{ .x = 4, .y = 2 },
});
pub const RowSoftmax2x4ThreadBlocks2x2F32 = rowSoftmaxF32(.{
    .rows = 2,
    .cols = 4,
    .threads = .{ .x = 2, .y = 2 },
});
pub const RowLogSoftmax2x4F32 = rowLogSoftmaxF32(.{
    .rows = 2,
    .cols = 4,
    .threads = .{ .x = 4, .y = 2 },
});

fn row_rms_norm_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const row_offset = try rowOffset(inner, index, ctx.spec);
    const item_index = try rowItemIndex(inner, index, row_offset);
    const each_args = ctx.args;
    const src = each_args.param(.src);
    const scale = each_args.param(.scale);
    const zero = try inner.constantFloat(.f32, 0.0);
    const sum_squares = try foldColumns(inner, ctx.spec, zero, .{
        .src = src,
        .row_offset = row_offset,
    }, row_rms_norm_sum_squares);
    const cols_count = try inner.constantFloat(.f32, floatExtent(ctx.spec.cols));
    const mean_square = try inner.div(sum_squares, cols_count);
    const stabilized = try inner.add(mean_square, each_args.param(.epsilon).raw());
    const root = try inner.sqrt(stabilized);
    const value = try src.load(inner, item_index);
    const normalized = try inner.div(value.raw(), root);
    const weight = try scale.load(inner, index.x.index);
    const weighted = try inner.mul(normalized, weight.raw());
    try each_args.param(.dst).store(inner, weighted, item_index);
}

fn row_rms_norm_sum_squares(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const reduce_index = try fold_inner.add(ctx.row_offset, offset);
    const value = try ctx.src.load(fold_inner, reduce_index);
    const square = try fold_inner.mul(value.raw(), value.raw());
    return fold_inner.add(acc, square);
}

fn rowRmsNormProgram(comptime spec: Row) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach2D(rowDomain(spec), .{ .spec = spec, .args = args }, row_rms_norm_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_normalization_rmsnorm{}x{}_{}x{}_f32",
            .{ spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
            .scale = kernel.dynamicBuffer(.f32),
            .epsilon = kernel.scalar(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

pub fn rowRmsNormF32(comptime spec: Row) type {
    return entry.Entry(rowRmsNormProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.normalization.rmsnorm{}x{}_{}x{}_f32",
            .{ spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .layer = .logical,
        .category = .normalization,
        .specialization = rowWeightedSpecialization(spec),
    });
}

pub const RowRmsNorm2x4F32 = rowRmsNormF32(.{
    .rows = 2,
    .cols = 4,
    .threads = .{ .x = 4, .y = 2 },
});

fn row_residual_rms_norm_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const row_offset = try rowOffset(inner, index, ctx.spec);
    const item_index = try rowItemIndex(inner, index, row_offset);
    const each_args = ctx.args;
    const src = each_args.param(.src);
    const residual = each_args.param(.residual);
    const scale = each_args.param(.scale);
    const zero = try inner.constantFloat(.f32, 0.0);
    const sum_squares = try foldColumns(inner, ctx.spec, zero, .{
        .src = src,
        .residual = residual,
        .row_offset = row_offset,
    }, row_residual_rms_norm_sum_squares);
    const cols_count = try inner.constantFloat(.f32, floatExtent(ctx.spec.cols));
    const mean_square = try inner.div(sum_squares, cols_count);
    const stabilized = try inner.add(mean_square, each_args.param(.epsilon).raw());
    const root = try inner.sqrt(stabilized);
    const value = try src.load(inner, item_index);
    const residual_value = try residual.load(inner, item_index);
    const combined = try inner.add(value.raw(), residual_value.raw());
    const normalized = try inner.div(combined, root);
    const weight = try scale.load(inner, index.x.index);
    const weighted = try inner.mul(normalized, weight.raw());
    try each_args.param(.dst).store(inner, weighted, item_index);
}

fn row_residual_rms_norm_sum_squares(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const reduce_index = try fold_inner.add(ctx.row_offset, offset);
    const value = try ctx.src.load(fold_inner, reduce_index);
    const residual_value = try ctx.residual.load(fold_inner, reduce_index);
    const combined = try fold_inner.add(value.raw(), residual_value.raw());
    const square = try fold_inner.mul(combined, combined);
    return fold_inner.add(acc, square);
}

fn rowResidualRmsNormProgram(comptime spec: Row) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach2D(rowDomain(spec), .{ .spec = spec, .args = args }, row_residual_rms_norm_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_fused_row_residual_rmsnorm{}x{}_{}x{}_f32",
            .{ spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
            .residual = kernel.dynamicBuffer(.f32),
            .scale = kernel.dynamicBuffer(.f32),
            .epsilon = kernel.scalar(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

pub fn rowResidualRmsNormF32(comptime spec: Row) type {
    return entry.Entry(rowResidualRmsNormProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.fused.row_residual_rmsnorm{}x{}_{}x{}_f32",
            .{ spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .layer = .logical,
        .category = .fused,
        .specialization = rowResidualRmsNormSpecialization(spec),
    });
}

pub const RowResidualRmsNorm2x4F32 = rowResidualRmsNormF32(.{
    .rows = 2,
    .cols = 4,
    .threads = .{ .x = 4, .y = 2 },
});

fn rowLayerNormOutput(
    inner: anytype,
    index: kernel.Index2D,
    normalized: kernel.Value,
    each_args: anytype,
    comptime parameterization: RowNormalizationParameterization,
) !kernel.Value {
    return switch (parameterization) {
        .none => normalized,
        .scale => blk: {
            const scale = each_args.param(.scale);
            const weight = try scale.load(inner, index.x.index);
            break :blk try inner.mul(normalized, weight.raw());
        },
        .scale_bias => blk: {
            const scale = each_args.param(.scale);
            const bias = each_args.param(.bias);
            const weight = try scale.load(inner, index.x.index);
            const scaled = try inner.mul(normalized, weight.raw());
            const shift = try bias.load(inner, index.x.index);
            break :blk try inner.add(scaled, shift.raw());
        },
    };
}

fn row_layer_norm_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const row_offset = try rowOffset(inner, index, ctx.spec);
    const item_index = try rowItemIndex(inner, index, row_offset);
    const each_args = ctx.args;
    const src = each_args.param(.src);
    const zero = try inner.constantFloat(.f32, 0.0);
    const sum = try foldColumns(inner, ctx.spec, zero, .{
        .src = src,
        .row_offset = row_offset,
    }, row_layer_norm_sum);
    const cols_count = try inner.constantFloat(.f32, floatExtent(ctx.spec.cols));
    const mean = try inner.div(sum, cols_count);
    const variance_sum = try foldColumns(inner, ctx.spec, zero, .{
        .src = src,
        .row_offset = row_offset,
        .mean = mean,
    }, row_layer_norm_variance_sum);
    const variance = try inner.div(variance_sum, cols_count);
    const stabilized = try inner.add(variance, each_args.param(.epsilon).raw());
    const root = try inner.sqrt(stabilized);
    const value = try src.load(inner, item_index);
    const centered = try inner.sub(value.raw(), mean);
    const normalized = try inner.div(centered, root);
    const output = try rowLayerNormOutput(inner, index, normalized, each_args, ctx.parameterization);
    try each_args.param(.dst).store(inner, output, item_index);
}

fn row_layer_norm_sum(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const reduce_index = try fold_inner.add(ctx.row_offset, offset);
    const value = try ctx.src.load(fold_inner, reduce_index);
    return fold_inner.add(acc, value.raw());
}

fn row_layer_norm_variance_sum(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const reduce_index = try fold_inner.add(ctx.row_offset, offset);
    const value = try ctx.src.load(fold_inner, reduce_index);
    const centered = try fold_inner.sub(value.raw(), ctx.mean);
    const square = try fold_inner.mul(centered, centered);
    return fold_inner.add(acc, square);
}

fn rowLayerNormProgram(comptime spec: Row, comptime parameterization: RowNormalizationParameterization) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach2D(rowDomain(spec), .{ .spec = spec, .parameterization = parameterization, .args = args }, row_layer_norm_each);
        }
    };

    return switch (parameterization) {
        .none => kernel.logical.Program(.{
            .name = std.fmt.comptimePrint(
                "accy_kernel_normalization_{s}{}x{}_{}x{}_f32",
                .{ rowLayerNormName(parameterization), spec.rows, spec.cols, spec.threads.x, spec.threads.y },
            ),
            .parameters = .{
                .dst = kernel.dynamicBuffer(.f32),
                .src = kernel.dynamicBuffer(.f32),
                .epsilon = kernel.scalar(.f32),
            },
            .body = Body.run,
        }).withSchedule(kernel.logical.schedule.threadBlocks(.{
            .x = spec.threads.x,
            .y = spec.threads.y,
        })),
        .scale => kernel.logical.Program(.{
            .name = std.fmt.comptimePrint(
                "accy_kernel_normalization_{s}{}x{}_{}x{}_f32",
                .{ rowLayerNormName(parameterization), spec.rows, spec.cols, spec.threads.x, spec.threads.y },
            ),
            .parameters = .{
                .dst = kernel.dynamicBuffer(.f32),
                .src = kernel.dynamicBuffer(.f32),
                .scale = kernel.dynamicBuffer(.f32),
                .epsilon = kernel.scalar(.f32),
            },
            .body = Body.run,
        }).withSchedule(kernel.logical.schedule.threadBlocks(.{
            .x = spec.threads.x,
            .y = spec.threads.y,
        })),
        .scale_bias => kernel.logical.Program(.{
            .name = std.fmt.comptimePrint(
                "accy_kernel_normalization_{s}{}x{}_{}x{}_f32",
                .{ rowLayerNormName(parameterization), spec.rows, spec.cols, spec.threads.x, spec.threads.y },
            ),
            .parameters = .{
                .dst = kernel.dynamicBuffer(.f32),
                .src = kernel.dynamicBuffer(.f32),
                .scale = kernel.dynamicBuffer(.f32),
                .bias = kernel.dynamicBuffer(.f32),
                .epsilon = kernel.scalar(.f32),
            },
            .body = Body.run,
        }).withSchedule(kernel.logical.schedule.threadBlocks(.{
            .x = spec.threads.x,
            .y = spec.threads.y,
        })),
    };
}

fn rowParameterizedLayerNormF32(comptime spec: Row, comptime parameterization: RowNormalizationParameterization) type {
    return entry.Entry(rowLayerNormProgram(spec, parameterization), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.normalization.{s}{}x{}_{}x{}_f32",
            .{ rowLayerNormName(parameterization), spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .layer = .logical,
        .category = .normalization,
        .specialization = rowLayerNormSpecialization(spec, parameterization),
    });
}

pub fn rowLayerNormF32(comptime spec: Row) type {
    return rowParameterizedLayerNormF32(spec, .none);
}

pub fn rowAffineLayerNormF32(comptime spec: Row) type {
    return rowParameterizedLayerNormF32(spec, .scale_bias);
}

pub const RowLayerNorm2x4F32 = rowLayerNormF32(.{
    .rows = 2,
    .cols = 4,
    .threads = .{ .x = 4, .y = 2 },
});
pub const RowAffineLayerNorm2x4F32 = rowAffineLayerNormF32(.{
    .rows = 2,
    .cols = 4,
    .threads = .{ .x = 4, .y = 2 },
});

test "normalization row softmax entry runs on CPU" {
    var src = [_]f32{
        1.0, 2.0, 3.0, 4.0,
        1.0, 1.0, 1.0, 1.0,
    };
    var dst = @as([8]f32, @splat(0.0));

    try RowSoftmax2x4F32.runCpu(std.testing.allocator, RowSoftmax2x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });

    const expected = [_]f32{
        0.032058604, 0.08714432, 0.23688282, 0.6439143,
        0.25,        0.25,       0.25,       0.25,
    };
    for (expected, dst) |expected_value, actual| {
        try std.testing.expectApproxEqAbs(expected_value, actual, 0.0001);
    }

    const launch_value = try RowSoftmax2x4F32.launch(std.testing.allocator, RowSoftmax2x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "normalization row log softmax entry runs on CPU" {
    var src = [_]f32{
        1.0, 2.0, 3.0, 4.0,
        1.0, 1.0, 1.0, 1.0,
    };
    var dst = @as([8]f32, @splat(0.0));

    try RowLogSoftmax2x4F32.runCpu(std.testing.allocator, RowLogSoftmax2x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });

    const expected = [_]f32{
        -3.4401898, -2.4401898, -1.4401897, -0.4401897,
        -1.3862944, -1.3862944, -1.3862944, -1.3862944,
    };
    for (expected, dst) |expected_value, actual| {
        try std.testing.expectApproxEqAbs(expected_value, actual, 0.0001);
    }

    const launch_value = try RowLogSoftmax2x4F32.launch(std.testing.allocator, RowLogSoftmax2x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "normalization row rmsnorm entry runs on CPU" {
    var src = [_]f32{
        1.0, 2.0, 3.0,  4.0,
        2.0, 0.0, -2.0, 0.0,
    };
    var scale = [_]f32{ 1.0, 0.5, 2.0, -1.0 };
    var dst = @as([8]f32, @splat(0.0));

    try RowRmsNorm2x4F32.runCpu(std.testing.allocator, RowRmsNorm2x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, scale[0..]),
        kernel.argumentF32(0.00001),
    });

    const expected = [_]f32{
        0.36514813, 0.36514813, 2.1908886,  -1.4605925,
        1.4142101,  0.0,        -2.8284202, -0.0,
    };
    for (expected, dst) |expected_value, actual| {
        try std.testing.expectApproxEqAbs(expected_value, actual, 0.0001);
    }

    const launch_value = try RowRmsNorm2x4F32.launch(std.testing.allocator, RowRmsNorm2x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "fused row residual rmsnorm entry runs on CPU" {
    var src = [_]f32{
        1.0, 2.0, 3.0,  4.0,
        2.0, 0.0, -2.0, 0.0,
    };
    var residual = [_]f32{
        0.5,  -0.5, 1.0, -1.0,
        -1.0, 1.0,  0.5, -0.5,
    };
    var scale = [_]f32{ 1.0, 0.5, 2.0, -1.0 };
    var dst = @as([8]f32, @splat(0.0));

    try RowResidualRmsNorm2x4F32.runCpu(std.testing.allocator, RowResidualRmsNorm2x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, residual[0..]),
        kernel.argumentBuffer(f32, scale[0..]),
        kernel.argumentF32(0.00001),
    });

    const expected = [_]f32{
        0.5523444, 0.2761722, 2.9458368,  -1.1046888,
        0.9428049, 0.4714024, -2.8284146, 0.4714024,
    };
    for (expected, dst) |expected_value, actual| {
        try std.testing.expectApproxEqAbs(expected_value, actual, 0.0001);
    }

    const launch_value = try RowResidualRmsNorm2x4F32.launch(std.testing.allocator, RowResidualRmsNorm2x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
    try std.testing.expectEqual(entry.Category.fused, RowResidualRmsNorm2x4F32.category);
    try std.testing.expect(RowResidualRmsNorm2x4F32.specialization.operationIs(.{ .row_normalization = .{ .rmsnorm = .scale } }));
    try std.testing.expect(RowResidualRmsNorm2x4F32.specialization.inputTransformMatches(0, .{
        .operator = .residual_add,
        .input_index = 1,
        .extents = &.{ 2, 4 },
    }));
    try std.testing.expect(RowResidualRmsNorm2x4F32.specialization.reductionMatches(0, .{
        .name = "row_sum_squares",
        .operator = .sum_squares,
        .extents = &.{4},
    }));
    try std.testing.expectEqualDeep(RowResidualRmsNorm2x4F32.specialization.launch.?, RowResidualRmsNorm2x4F32.specialization.schedule.?.launch());
}

test "normalization row layernorm entry runs on CPU" {
    var src = [_]f32{
        1.0, 2.0, 3.0,  4.0,
        2.0, 0.0, -2.0, 0.0,
    };
    var dst = @as([8]f32, @splat(0.0));

    try RowLayerNorm2x4F32.runCpu(std.testing.allocator, RowLayerNorm2x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentF32(0.00001),
    });

    const expected = [_]f32{
        -1.3416355, -0.44721183, 0.44721183, 1.3416355,
        1.4142101,  0.0,         -1.4142101, 0.0,
    };
    for (expected, dst) |expected_value, actual| {
        try std.testing.expectApproxEqAbs(expected_value, actual, 0.0001);
    }

    const launch_value = try RowLayerNorm2x4F32.launch(std.testing.allocator, RowLayerNorm2x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "normalization row affine layernorm entry runs on CPU" {
    var src = [_]f32{
        1.0, 2.0, 3.0,  4.0,
        2.0, 0.0, -2.0, 0.0,
    };
    var scale = [_]f32{ 1.0, 0.5, 2.0, -1.0 };
    var bias = [_]f32{ 0.1, -0.2, 0.3, 0.4 };
    var dst = @as([8]f32, @splat(0.0));

    try RowAffineLayerNorm2x4F32.runCpu(std.testing.allocator, RowAffineLayerNorm2x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, scale[0..]),
        kernel.argumentBuffer(f32, bias[0..]),
        kernel.argumentF32(0.00001),
    });

    const expected = [_]f32{
        -1.2416355, -0.4236059, 1.1944237,  -0.9416355,
        1.5142101,  -0.2,       -2.5284202, 0.4,
    };
    for (expected, dst) |expected_value, actual| {
        try std.testing.expectApproxEqAbs(expected_value, actual, 0.0001);
    }

    const launch_value = try RowAffineLayerNorm2x4F32.launch(std.testing.allocator, RowAffineLayerNorm2x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "normalization constructor creates independent shape-specialized entries" {
    const RowSoftmax3x5F32 = rowSoftmaxF32(.{
        .rows = 3,
        .cols = 5,
        .threads = .{ .x = 5, .y = 1 },
    });
    const RowLogSoftmax3x5F32 = rowLogSoftmaxF32(.{
        .rows = 3,
        .cols = 5,
        .threads = .{ .x = 5, .y = 1 },
    });
    const RowRmsNorm3x5F32 = rowRmsNormF32(.{
        .rows = 3,
        .cols = 5,
        .threads = .{ .x = 5, .y = 1 },
    });
    const RowResidualRmsNorm3x5F32 = rowResidualRmsNormF32(.{
        .rows = 3,
        .cols = 5,
        .threads = .{ .x = 5, .y = 1 },
    });
    const RowLayerNorm3x5F32 = rowLayerNormF32(.{
        .rows = 3,
        .cols = 5,
        .threads = .{ .x = 5, .y = 1 },
    });
    const RowAffineLayerNorm3x5F32 = rowAffineLayerNormF32(.{
        .rows = 3,
        .cols = 5,
        .threads = .{ .x = 5, .y = 1 },
    });

    try std.testing.expectEqualStrings("accy.kernel.normalization.softmax2x4_4x2_f32", RowSoftmax2x4F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.softmax2x4_2x2_f32", RowSoftmax2x4ThreadBlocks2x2F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.softmax3x5_5x1_f32", RowSoftmax3x5F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.log_softmax2x4_4x2_f32", RowLogSoftmax2x4F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.log_softmax3x5_5x1_f32", RowLogSoftmax3x5F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.rmsnorm2x4_4x2_f32", RowRmsNorm2x4F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.rmsnorm3x5_5x1_f32", RowRmsNorm3x5F32.target);
    try std.testing.expectEqualStrings("accy.kernel.fused.row_residual_rmsnorm2x4_4x2_f32", RowResidualRmsNorm2x4F32.target);
    try std.testing.expectEqualStrings("accy.kernel.fused.row_residual_rmsnorm3x5_5x1_f32", RowResidualRmsNorm3x5F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.layernorm2x4_4x2_f32", RowLayerNorm2x4F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.layernorm3x5_5x1_f32", RowLayerNorm3x5F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.layernorm_affine2x4_4x2_f32", RowAffineLayerNorm2x4F32.target);
    try std.testing.expectEqualStrings("accy.kernel.normalization.layernorm_affine3x5_5x1_f32", RowAffineLayerNorm3x5F32.target);
    try std.testing.expectEqual(entry.Category.normalization, RowSoftmax2x4F32.category);
    try std.testing.expectEqual(entry.Category.normalization, RowSoftmax2x4ThreadBlocks2x2F32.category);
    try std.testing.expectEqual(entry.Category.normalization, RowLogSoftmax2x4F32.category);
    try std.testing.expectEqual(entry.Category.normalization, RowRmsNorm2x4F32.category);
    try std.testing.expectEqual(entry.Category.fused, RowResidualRmsNorm2x4F32.category);
    try std.testing.expectEqual(entry.Category.normalization, RowLayerNorm2x4F32.category);
    try std.testing.expectEqual(entry.Category.normalization, RowAffineLayerNorm2x4F32.category);
    try std.testing.expect(RowSoftmax3x5F32.specialization.operationIs(.{ .row_normalization = .softmax }));
    try std.testing.expect(RowSoftmax2x4ThreadBlocks2x2F32.specialization.operationIs(.{ .row_normalization = .softmax }));
    try std.testing.expect(RowLogSoftmax3x5F32.specialization.operationIs(.{ .row_normalization = .log_softmax }));
    try std.testing.expectEqual(@as(usize, 1), RowSoftmax3x5F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), RowSoftmax3x5F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(usize, 2), RowSoftmax3x5F32.specialization.reductions.len);
    try std.testing.expectEqualStrings("row_max", RowSoftmax3x5F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.maximum, RowSoftmax3x5F32.specialization.reductions[0].operator);
    try std.testing.expectEqual(@as(u64, 5), RowSoftmax3x5F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expectEqualStrings("row_exp_sum", RowSoftmax3x5F32.specialization.reductions[1].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum_exp_shifted, RowSoftmax3x5F32.specialization.reductions[1].operator);
    try std.testing.expectEqual(@as(usize, 1), RowSoftmax3x5F32.specialization.reductions[1].dependencies.len);
    try std.testing.expectEqualStrings("row_max", RowSoftmax3x5F32.specialization.reductions[1].dependencies[0]);
    try std.testing.expect(RowSoftmax3x5F32.specialization.reductionReuseScopesAreValid());
    try std.testing.expectEqual(@as(usize, 2), RowSoftmax3x5F32.specialization.reduction_reuse.len);
    try std.testing.expect(RowSoftmax3x5F32.specialization.reductionReuseMatches(0, .{ .reduction = "row_max", .extents = &.{3} }));
    try std.testing.expect(RowSoftmax3x5F32.specialization.reductionReuseMatches(1, .{ .reduction = "row_exp_sum", .extents = &.{3} }));
    try std.testing.expectEqual(@as(u64, 30), RowSoftmax3x5F32.specialization.estimatedElementOps().?);
    try std.testing.expectEqual(@as(u32, 1), RowSoftmax3x5F32.specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), RowSoftmax3x5F32.specialization.launch.?.grid[1]);
    try std.testing.expectEqualDeep(RowSoftmax3x5F32.specialization.launch.?, RowSoftmax3x5F32.specialization.schedule.?.launch());
    try std.testing.expectEqual(@as(usize, 3), RowSoftmax3x5F32.specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("col", RowSoftmax3x5F32.specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_x, RowSoftmax3x5F32.specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("row_tile", RowSoftmax3x5F32.specialization.schedule.?.bindings[1].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_y, RowSoftmax3x5F32.specialization.schedule.?.bindings[1].target);
    try std.testing.expectEqualStrings("row_lane", RowSoftmax3x5F32.specialization.schedule.?.bindings[2].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_y, RowSoftmax3x5F32.specialization.schedule.?.bindings[2].target);
    var softmax_snapshot = try RowSoftmax3x5F32.scheduleSnapshot(std.testing.allocator, RowSoftmax3x5F32.Limits.testing);
    defer softmax_snapshot.deinit(std.testing.allocator);
    try std.testing.expect(RowSoftmax3x5F32.specialization.schedule.?.matchesSnapshot(&softmax_snapshot));

    try std.testing.expectEqual(@as(usize, 1), RowLogSoftmax3x5F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), RowLogSoftmax3x5F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(usize, 2), RowLogSoftmax3x5F32.specialization.reductions.len);
    try std.testing.expectEqualStrings("row_max", RowLogSoftmax3x5F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.maximum, RowLogSoftmax3x5F32.specialization.reductions[0].operator);
    try std.testing.expectEqualStrings("row_exp_sum", RowLogSoftmax3x5F32.specialization.reductions[1].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum_exp_shifted, RowLogSoftmax3x5F32.specialization.reductions[1].operator);
    try std.testing.expectEqual(@as(usize, 1), RowLogSoftmax3x5F32.specialization.reductions[1].dependencies.len);
    try std.testing.expectEqualStrings("row_max", RowLogSoftmax3x5F32.specialization.reductions[1].dependencies[0]);
    try std.testing.expect(RowLogSoftmax3x5F32.specialization.reductionReuseScopesAreValid());
    try std.testing.expectEqual(@as(usize, 2), RowLogSoftmax3x5F32.specialization.reduction_reuse.len);
    try std.testing.expect(RowLogSoftmax3x5F32.specialization.reductionReuseMatches(0, .{ .reduction = "row_max", .extents = &.{3} }));
    try std.testing.expect(RowLogSoftmax3x5F32.specialization.reductionReuseMatches(1, .{ .reduction = "row_exp_sum", .extents = &.{3} }));
    try std.testing.expectEqual(@as(u64, 30), RowLogSoftmax3x5F32.specialization.estimatedElementOps().?);
    try std.testing.expectEqualDeep(RowLogSoftmax3x5F32.specialization.launch.?, RowLogSoftmax3x5F32.specialization.schedule.?.launch());

    try std.testing.expect(RowRmsNorm3x5F32.specialization.operationIs(.{ .row_normalization = .{ .rmsnorm = .scale } }));
    try std.testing.expectEqual(@as(usize, 2), RowRmsNorm3x5F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), RowRmsNorm3x5F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 5), RowRmsNorm3x5F32.specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 15), RowRmsNorm3x5F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings("row_sum_squares", RowRmsNorm3x5F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum_squares, RowRmsNorm3x5F32.specialization.reductions[0].operator);
    try std.testing.expectEqual(@as(u64, 5), RowRmsNorm3x5F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expect(RowRmsNorm3x5F32.specialization.reductionReuseScopesAreValid());
    try std.testing.expectEqual(@as(usize, 1), RowRmsNorm3x5F32.specialization.reduction_reuse.len);
    try std.testing.expect(RowRmsNorm3x5F32.specialization.reductionReuseMatches(0, .{ .reduction = "row_sum_squares", .extents = &.{3} }));
    try std.testing.expectEqual(@as(u64, 15), RowRmsNorm3x5F32.specialization.estimatedElementOps().?);
    try std.testing.expectEqualDeep(RowRmsNorm3x5F32.specialization.launch.?, RowRmsNorm3x5F32.specialization.schedule.?.launch());

    try std.testing.expect(RowResidualRmsNorm3x5F32.specialization.operationIs(.{ .row_normalization = .{ .rmsnorm = .scale } }));
    try std.testing.expectEqual(@as(usize, 3), RowResidualRmsNorm3x5F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), RowResidualRmsNorm3x5F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 15), RowResidualRmsNorm3x5F32.specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 5), RowResidualRmsNorm3x5F32.specialization.inputs[2].elementCount().?);
    try std.testing.expectEqual(@as(u64, 15), RowResidualRmsNorm3x5F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(usize, 1), RowResidualRmsNorm3x5F32.specialization.input_transforms.len);
    try std.testing.expect(RowResidualRmsNorm3x5F32.specialization.inputTransformMatches(0, .{
        .operator = .residual_add,
        .input_index = 1,
        .extents = &.{ 3, 5 },
    }));
    try std.testing.expectEqualStrings("row_sum_squares", RowResidualRmsNorm3x5F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum_squares, RowResidualRmsNorm3x5F32.specialization.reductions[0].operator);
    try std.testing.expectEqual(@as(u64, 5), RowResidualRmsNorm3x5F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expect(RowResidualRmsNorm3x5F32.specialization.reductionReuseScopesAreValid());
    try std.testing.expectEqual(@as(usize, 1), RowResidualRmsNorm3x5F32.specialization.reduction_reuse.len);
    try std.testing.expect(RowResidualRmsNorm3x5F32.specialization.reductionReuseMatches(0, .{ .reduction = "row_sum_squares", .extents = &.{3} }));
    try std.testing.expectEqual(@as(u64, 15), RowResidualRmsNorm3x5F32.specialization.estimatedElementOps().?);
    try std.testing.expectEqualDeep(RowResidualRmsNorm3x5F32.specialization.launch.?, RowResidualRmsNorm3x5F32.specialization.schedule.?.launch());

    try std.testing.expect(RowLayerNorm3x5F32.specialization.operationIs(.{ .row_normalization = .{ .layernorm = .none } }));
    try std.testing.expectEqual(@as(usize, 1), RowLayerNorm3x5F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), RowLayerNorm3x5F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 15), RowLayerNorm3x5F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(usize, 2), RowLayerNorm3x5F32.specialization.reductions.len);
    try std.testing.expectEqualStrings("row_sum", RowLayerNorm3x5F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum, RowLayerNorm3x5F32.specialization.reductions[0].operator);
    try std.testing.expectEqual(@as(u64, 5), RowLayerNorm3x5F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expectEqualStrings("row_variance_sum", RowLayerNorm3x5F32.specialization.reductions[1].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum_squared_difference, RowLayerNorm3x5F32.specialization.reductions[1].operator);
    try std.testing.expectEqual(@as(usize, 1), RowLayerNorm3x5F32.specialization.reductions[1].dependencies.len);
    try std.testing.expectEqualStrings("row_sum", RowLayerNorm3x5F32.specialization.reductions[1].dependencies[0]);
    try std.testing.expect(RowLayerNorm3x5F32.specialization.reductionReuseScopesAreValid());
    try std.testing.expectEqual(@as(usize, 2), RowLayerNorm3x5F32.specialization.reduction_reuse.len);
    try std.testing.expect(RowLayerNorm3x5F32.specialization.reductionReuseMatches(0, .{ .reduction = "row_sum", .extents = &.{3} }));
    try std.testing.expect(RowLayerNorm3x5F32.specialization.reductionReuseMatches(1, .{ .reduction = "row_variance_sum", .extents = &.{3} }));
    try std.testing.expectEqual(@as(u64, 30), RowLayerNorm3x5F32.specialization.estimatedElementOps().?);
    try std.testing.expectEqualDeep(RowLayerNorm3x5F32.specialization.launch.?, RowLayerNorm3x5F32.specialization.schedule.?.launch());

    try std.testing.expect(RowAffineLayerNorm3x5F32.specialization.operationIs(.{ .row_normalization = .{ .layernorm = .scale_bias } }));
    try std.testing.expectEqual(@as(usize, 3), RowAffineLayerNorm3x5F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), RowAffineLayerNorm3x5F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 5), RowAffineLayerNorm3x5F32.specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 5), RowAffineLayerNorm3x5F32.specialization.inputs[2].elementCount().?);
    try std.testing.expectEqual(@as(u64, 15), RowAffineLayerNorm3x5F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(usize, 2), RowAffineLayerNorm3x5F32.specialization.reductions.len);
    try std.testing.expectEqualStrings("row_sum", RowAffineLayerNorm3x5F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum, RowAffineLayerNorm3x5F32.specialization.reductions[0].operator);
    try std.testing.expectEqualStrings("row_variance_sum", RowAffineLayerNorm3x5F32.specialization.reductions[1].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum_squared_difference, RowAffineLayerNorm3x5F32.specialization.reductions[1].operator);
    try std.testing.expectEqual(@as(usize, 1), RowAffineLayerNorm3x5F32.specialization.reductions[1].dependencies.len);
    try std.testing.expectEqualStrings("row_sum", RowAffineLayerNorm3x5F32.specialization.reductions[1].dependencies[0]);
    try std.testing.expect(RowAffineLayerNorm3x5F32.specialization.reductionReuseScopesAreValid());
    try std.testing.expectEqual(@as(usize, 2), RowAffineLayerNorm3x5F32.specialization.reduction_reuse.len);
    try std.testing.expect(RowAffineLayerNorm3x5F32.specialization.reductionReuseMatches(0, .{ .reduction = "row_sum", .extents = &.{3} }));
    try std.testing.expect(RowAffineLayerNorm3x5F32.specialization.reductionReuseMatches(1, .{ .reduction = "row_variance_sum", .extents = &.{3} }));
    try std.testing.expectEqual(@as(u64, 30), RowAffineLayerNorm3x5F32.specialization.estimatedElementOps().?);
    try std.testing.expectEqualDeep(RowAffineLayerNorm3x5F32.specialization.launch.?, RowAffineLayerNorm3x5F32.specialization.schedule.?.launch());
}

test "normalization row softmax entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try RowSoftmax2x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = RowSoftmax2x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(RowSoftmax2x4F32.target, RowSoftmax2x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(RowSoftmax2x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 2), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(RowSoftmax2x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(RowSoftmax2x4F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(RowSoftmax2x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(RowSoftmax2x4F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "normalization row log softmax entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try RowLogSoftmax2x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = RowLogSoftmax2x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(RowLogSoftmax2x4F32.target, RowLogSoftmax2x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(RowLogSoftmax2x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 2), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(RowLogSoftmax2x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(RowLogSoftmax2x4F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(RowLogSoftmax2x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(RowLogSoftmax2x4F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "normalization row rmsnorm entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try RowRmsNorm2x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = RowRmsNorm2x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(RowRmsNorm2x4F32.target, RowRmsNorm2x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(RowRmsNorm2x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 4), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(RowRmsNorm2x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(RowRmsNorm2x4F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(RowRmsNorm2x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(RowRmsNorm2x4F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "fused row residual rmsnorm entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try RowResidualRmsNorm2x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = RowResidualRmsNorm2x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(RowResidualRmsNorm2x4F32.target, RowResidualRmsNorm2x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(RowResidualRmsNorm2x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 5), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(RowResidualRmsNorm2x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(RowResidualRmsNorm2x4F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(RowResidualRmsNorm2x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(RowResidualRmsNorm2x4F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "normalization row layernorm entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try RowLayerNorm2x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = RowLayerNorm2x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(RowLayerNorm2x4F32.target, RowLayerNorm2x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(RowLayerNorm2x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(RowLayerNorm2x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(RowLayerNorm2x4F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(RowLayerNorm2x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(RowLayerNorm2x4F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "normalization row affine layernorm entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try RowAffineLayerNorm2x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = RowAffineLayerNorm2x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(RowAffineLayerNorm2x4F32.target, RowAffineLayerNorm2x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(RowAffineLayerNorm2x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 5), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(RowAffineLayerNorm2x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(RowAffineLayerNorm2x4F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(RowAffineLayerNorm2x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(RowAffineLayerNorm2x4F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}
