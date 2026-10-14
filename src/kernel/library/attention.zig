const std = @import("std");
const gpu = @import("gpu");

const entry = @import("entry.zig");
const kernel = @import("../root.zig");

pub const ScaledDotProduct = struct {
    batch: u64,
    queries: u64,
    keys: u64,
    qk: u64,
    value: u64,
    threads: entry.Threads3D = .{},
    batch_axis: []const u8 = "b",
    query_axis: []const u8 = "q",
    key_axis: []const u8 = "k",
    qk_axis: []const u8 = "h",
    value_axis: []const u8 = "v",
};

fn indexUpper(comptime extent: u64) i64 {
    if (extent > @as(u64, @intCast(std.math.maxInt(i64)))) {
        @compileError("kernel library attention extent overflows index range");
    }
    return @intCast(extent);
}

fn checkedProduct(comptime lhs: u64, comptime rhs: u64) u64 {
    return std.math.mul(u64, lhs, rhs) catch @compileError(
        "kernel library attention shape product overflow",
    );
}

fn floatExtent(comptime extent: u64) f64 {
    return @floatFromInt(extent);
}

fn queryShape(comptime spec: ScaledDotProduct) entry.Shape {
    return entry.shape3D(
        spec.batch_axis,
        spec.batch,
        spec.query_axis,
        spec.queries,
        spec.qk_axis,
        spec.qk,
    );
}

fn keyShape(comptime spec: ScaledDotProduct) entry.Shape {
    return entry.shape3D(
        spec.batch_axis,
        spec.batch,
        spec.key_axis,
        spec.keys,
        spec.qk_axis,
        spec.qk,
    );
}

fn valueShape(comptime spec: ScaledDotProduct) entry.Shape {
    return entry.shape3D(
        spec.batch_axis,
        spec.batch,
        spec.key_axis,
        spec.keys,
        spec.value_axis,
        spec.value,
    );
}

fn outputShape(comptime spec: ScaledDotProduct) entry.Shape {
    return entry.shape3D(
        spec.batch_axis,
        spec.batch,
        spec.query_axis,
        spec.queries,
        spec.value_axis,
        spec.value,
    );
}

fn queryRowShape(comptime spec: ScaledDotProduct) entry.Shape {
    return entry.shape2D(spec.batch_axis, spec.batch, spec.query_axis, spec.queries);
}

fn scoreShape(comptime spec: ScaledDotProduct) entry.Shape {
    return entry.shape3D(
        spec.batch_axis,
        spec.batch,
        spec.query_axis,
        spec.queries,
        spec.key_axis,
        spec.keys,
    );
}

fn scaledDotProductSpecialization(comptime spec: ScaledDotProduct) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .attention = .scaled_dot_product },
        .equation = "bqh,bkh,bkv->bqv",
        .inputs = &.{
            queryShape(spec),
            keyShape(spec),
            valueShape(spec),
        },
        .outputs = &.{outputShape(spec)},
        .reductions = &.{
            entry.reduction("score_dot", .dot_product, entry.shape1D(spec.qk_axis, spec.qk)),
            entry.dependentReduction(
                "score_max",
                .maximum,
                entry.shape1D(spec.key_axis, spec.keys),
                &.{"score_dot"},
            ),
            entry.dependentReduction(
                "score_exp_sum",
                .sum_exp_shifted,
                entry.shape1D(spec.key_axis, spec.keys),
                &.{"score_max"},
            ),
            entry.dependentReduction(
                "value_weighted_sum",
                .weighted_sum,
                entry.shape1D(spec.key_axis, spec.keys),
                &.{"score_exp_sum"},
            ),
        },
        .reduction_reuse = &.{
            entry.reductionReuse("score_dot", scoreShape(spec)),
            entry.reductionReuse("score_max", queryRowShape(spec)),
            entry.reductionReuse("score_exp_sum", queryRowShape(spec)),
        },
        .launch = entry.launch3D(
            spec.value,
            spec.queries,
            spec.batch,
            spec.threads.x,
            spec.threads.y,
            spec.threads.z,
        ),
        .schedule = entry.threadBlocks3D(
            spec.value_axis,
            spec.value,
            spec.query_axis,
            spec.queries,
            spec.batch_axis,
            spec.batch,
            spec.threads.x,
            spec.threads.y,
            spec.threads.z,
        ),
    };
}

fn queryIndex(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    batch: kernel.Value,
    query: kernel.Value,
    feature: kernel.Value,
) !kernel.Value {
    const batch_stride = try inner.constantIndex(indexUpper(checkedProduct(spec.queries, spec.qk)));
    const query_stride = try inner.constantIndex(indexUpper(spec.qk));
    const batch_offset = try inner.mul(batch, batch_stride);
    const query_offset = try inner.mul(query, query_stride);
    const batch_query_offset = try inner.add(batch_offset, query_offset);
    return inner.add(batch_query_offset, feature);
}

fn keyIndex(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    batch: kernel.Value,
    key: kernel.Value,
    feature: kernel.Value,
) !kernel.Value {
    const batch_stride = try inner.constantIndex(indexUpper(checkedProduct(spec.keys, spec.qk)));
    const key_stride = try inner.constantIndex(indexUpper(spec.qk));
    const batch_offset = try inner.mul(batch, batch_stride);
    const key_offset = try inner.mul(key, key_stride);
    const batch_key_offset = try inner.add(batch_offset, key_offset);
    return inner.add(batch_key_offset, feature);
}

fn valueIndex(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    batch: kernel.Value,
    key: kernel.Value,
    value: kernel.Value,
) !kernel.Value {
    const batch_stride = try inner.constantIndex(indexUpper(checkedProduct(spec.keys, spec.value)));
    const key_stride = try inner.constantIndex(indexUpper(spec.value));
    const batch_offset = try inner.mul(batch, batch_stride);
    const key_offset = try inner.mul(key, key_stride);
    const batch_key_offset = try inner.add(batch_offset, key_offset);
    return inner.add(batch_key_offset, value);
}

fn outputIndex(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    batch: kernel.Value,
    query: kernel.Value,
    value: kernel.Value,
) !kernel.Value {
    const batch_stride = try inner.constantIndex(
        indexUpper(checkedProduct(spec.queries, spec.value)),
    );
    const query_stride = try inner.constantIndex(indexUpper(spec.value));
    const batch_offset = try inner.mul(batch, batch_stride);
    const query_offset = try inner.mul(query, query_stride);
    const batch_query_offset = try inner.add(batch_offset, query_offset);
    return inner.add(batch_query_offset, value);
}

fn scaled_score_dot(
    fold_inner: anytype,
    feature: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const query_index = try queryIndex(fold_inner, ctx.spec, ctx.batch, ctx.query, feature);
    const key_index = try keyIndex(fold_inner, ctx.spec, ctx.batch, ctx.key, feature);
    const query_value = try ctx.query_buffer.load(fold_inner, query_index);
    const key_value = try ctx.key_buffer.load(fold_inner, key_index);
    const product = try query_value.mul(fold_inner, key_value);
    return fold_inner.add(acc, product.raw());
}

fn scaledScore(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    query_buffer: anytype,
    key_buffer: anytype,
    batch: kernel.Value,
    query: kernel.Value,
    key: kernel.Value,
) !kernel.Value {
    const zero = try inner.constantFloat(.f32, 0.0);
    const dot = try inner.foldRange(0, indexUpper(spec.qk), 1, zero, .{
        .spec = spec,
        .query_buffer = query_buffer,
        .key_buffer = key_buffer,
        .batch = batch,
        .query = query,
        .key = key,
    }, scaled_score_dot);
    const scale = try inner.constantFloat(.f32, 1.0 / @sqrt(floatExtent(spec.qk)));
    return inner.mul(dot, scale);
}

fn score_max_reduce(
    fold_inner: anytype,
    key: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const score = try scaledScore(
        fold_inner,
        ctx.spec,
        ctx.query_buffer,
        ctx.key_buffer,
        ctx.batch,
        ctx.query,
        key,
    );
    return fold_inner.max(acc, score);
}

fn scoreMax(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    query_buffer: anytype,
    key_buffer: anytype,
    batch: kernel.Value,
    query: kernel.Value,
) !kernel.Value {
    const first_key = try inner.constantIndex(0);
    const first = try scaledScore(inner, spec, query_buffer, key_buffer, batch, query, first_key);
    return inner.foldRange(1, indexUpper(spec.keys), 1, first, .{
        .spec = spec,
        .query_buffer = query_buffer,
        .key_buffer = key_buffer,
        .batch = batch,
        .query = query,
    }, score_max_reduce);
}

fn score_denominator_reduce(
    fold_inner: anytype,
    key: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const score = try scaledScore(
        fold_inner,
        ctx.spec,
        ctx.query_buffer,
        ctx.key_buffer,
        ctx.batch,
        ctx.query,
        key,
    );
    const shifted = try fold_inner.sub(score, ctx.row_max);
    const exp_score = try fold_inner.exp(shifted);
    return fold_inner.add(acc, exp_score);
}

fn scoreDenominator(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    query_buffer: anytype,
    key_buffer: anytype,
    batch: kernel.Value,
    query: kernel.Value,
    row_max: kernel.Value,
) !kernel.Value {
    const zero = try inner.constantFloat(.f32, 0.0);
    return inner.foldRange(0, indexUpper(spec.keys), 1, zero, .{
        .spec = spec,
        .query_buffer = query_buffer,
        .key_buffer = key_buffer,
        .batch = batch,
        .query = query,
        .row_max = row_max,
    }, score_denominator_reduce);
}

fn weighted_value_sum_reduce(
    fold_inner: anytype,
    key: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
    const score = try scaledScore(
        fold_inner,
        ctx.spec,
        ctx.query_buffer,
        ctx.key_buffer,
        ctx.batch,
        ctx.query,
        key,
    );
    const shifted = try fold_inner.sub(score, ctx.row_max);
    const exp_score = try fold_inner.exp(shifted);
    const weight = try fold_inner.div(exp_score, ctx.denominator);
    const value_index = try valueIndex(fold_inner, ctx.spec, ctx.batch, key, ctx.value);
    const value_item = try ctx.value_buffer.load(fold_inner, value_index);
    const weighted = try fold_inner.mul(weight, value_item.raw());
    return fold_inner.add(acc, weighted);
}

fn weightedValueSum(
    inner: anytype,
    comptime spec: ScaledDotProduct,
    query_buffer: anytype,
    key_buffer: anytype,
    value_buffer: anytype,
    batch: kernel.Value,
    query: kernel.Value,
    value: kernel.Value,
) !kernel.Value {
    const row_max = try scoreMax(inner, spec, query_buffer, key_buffer, batch, query);
    const denominator = try scoreDenominator(
        inner,
        spec,
        query_buffer,
        key_buffer,
        batch,
        query,
        row_max,
    );
    const zero = try inner.constantFloat(.f32, 0.0);
    return inner.foldRange(0, indexUpper(spec.keys), 1, zero, .{
        .spec = spec,
        .query_buffer = query_buffer,
        .key_buffer = key_buffer,
        .value_buffer = value_buffer,
        .batch = batch,
        .query = query,
        .value = value,
        .row_max = row_max,
        .denominator = denominator,
    }, weighted_value_sum_reduce);
}

fn scaled_dot_product_each(inner: anytype, index: kernel.Index3D, ctx: anytype) !void {
    const output_value = try weightedValueSum(
        inner,
        ctx.spec,
        ctx.args.param(.query),
        ctx.args.param(.key),
        ctx.args.param(.value),
        index.z.index,
        index.y.index,
        index.x.index,
    );
    const out_index = try outputIndex(inner, ctx.spec, index.z.index, index.y.index, index.x.index);
    try ctx.args.param(.dst).store(inner, output_value, out_index);
}

fn scaledDotProductProgram(comptime spec: ScaledDotProduct) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach3D(.{
                .x = kernel.logical.axis(spec.value_axis, spec.value),
                .y = kernel.logical.axis(spec.query_axis, spec.queries),
                .z = kernel.logical.axis(spec.batch_axis, spec.batch),
            }, .{ .spec = spec, .args = args }, scaled_dot_product_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_attention_sdpa{}x{}x{}x{}x{}_{}x{}x{}_f32",
            .{
                spec.batch,
                spec.queries,
                spec.keys,
                spec.qk,
                spec.value,
                spec.threads.x,
                spec.threads.y,
                spec.threads.z,
            },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .query = kernel.dynamicBuffer(.f32),
            .key = kernel.dynamicBuffer(.f32),
            .value = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
        .z = spec.threads.z,
    }));
}

pub fn scaledDotProductF32(comptime spec: ScaledDotProduct) type {
    return entry.Entry(scaledDotProductProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.attention.sdpa{}x{}x{}x{}x{}_{}x{}x{}_f32",
            .{
                spec.batch,
                spec.queries,
                spec.keys,
                spec.qk,
                spec.value,
                spec.threads.x,
                spec.threads.y,
                spec.threads.z,
            },
        ),
        .layer = .logical,
        .category = .attention,
        .specialization = scaledDotProductSpecialization(spec),
    });
}

pub const ScaledDotProductAttention2x2x3x2x2F32 = scaledDotProductF32(.{
    .batch = 2,
    .queries = 2,
    .keys = 3,
    .qk = 2,
    .value = 2,
    .threads = .{ .x = 2, .y = 2, .z = 1 },
});

fn expectedOutput(
    comptime spec: ScaledDotProduct,
    query_values: []const f32,
    key_values: []const f32,
    value_values: []const f32,
    batch: usize,
    query: usize,
    value: usize,
) f32 {
    var scores: [spec.keys]f32 = undefined;
    const scale: f32 = @floatCast(1.0 / @sqrt(floatExtent(spec.qk)));
    var max_score = -std.math.inf(f32);
    for (0..spec.keys) |key| {
        var dot: f32 = 0.0;
        for (0..spec.qk) |feature| {
            const query_offset = batch * spec.queries * spec.qk + query * spec.qk + feature;
            const key_offset = batch * spec.keys * spec.qk + key * spec.qk + feature;
            dot += query_values[query_offset] * key_values[key_offset];
        }
        const score = dot * scale;
        scores[key] = score;
        if (score > max_score) max_score = score;
    }

    var denominator: f32 = 0.0;
    for (scores) |score| {
        denominator += @exp(score - max_score);
    }

    var sum: f32 = 0.0;
    for (0..spec.keys) |key| {
        const weight = @exp(scores[key] - max_score) / denominator;
        const value_offset = batch * spec.keys * spec.value + key * spec.value + value;
        sum += weight * value_values[value_offset];
    }
    return sum;
}
