const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../../artifact/model/root.zig");
const shape = @import("../../choir/shape/root.zig");
const entry = @import("entry.zig");
const extent_mod = @import("extent.zig");
const geometry_mod = @import("geometry.zig");
const kernel = @import("../root.zig");
const tuning = @import("tuning.zig");

const DType = gpu_abi.DType;
const indexExtent = extent_mod.indexExtent;
const indexProduct = extent_mod.indexProduct;
const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

pub const MatrixProduct = struct {
    m: u64,
    n: u64,
    k: u64,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    threads: entry.Threads2D = .{},
    row_axis: []const u8 = "m",
    col_axis: []const u8 = "n",
    reduction_axis: []const u8 = "k",
};

pub const BatchedMatrixProduct = struct {
    batch: u64,
    m: u64,
    n: u64,
    k: u64,
    threads: entry.Threads3D = .{},
    batch_axis: []const u8 = "b",
    row_axis: []const u8 = "m",
    col_axis: []const u8 = "n",
    reduction_axis: []const u8 = "k",
};

pub const MatrixVectorProduct = struct {
    m: u64,
    k: u64,
    threads: u32 = 8,
    row_axis: []const u8 = "m",
    reduction_axis: []const u8 = "k",
};

pub const OuterProduct = struct {
    m: u64,
    n: u64,
    threads: entry.Threads2D = .{},
    lhs_axis: []const u8 = "m",
    rhs_axis: []const u8 = "n",
};

pub fn matrixProductAccumulationDType(dtype: DType) ?DType {
    return switch (dtype) {
        .f32, .f16 => .f32,
        else => null,
    };
}

fn matrixProductAccumulationZero(inner: anytype, spec: MatrixProduct) !kernel.Value {
    return switch (spec.accumulation_dtype) {
        .f32 => inner.constantFloat(.f32, 0.0),
        .f16 => inner.constantFloat(.f16, 0.0),
        else => error.UnsupportedDType,
    };
}

fn matrixProductAccumulationValue(inner: anytype, spec: MatrixProduct, value: anytype) !kernel.Value {
    return switch (spec.accumulation_dtype) {
        .f32 => if (comptime @TypeOf(value).scalar_dtype == .f32) value.raw() else (try value.cast(inner, .f32)).raw(),
        .f16 => if (comptime @TypeOf(value).scalar_dtype == .f16) value.raw() else (try value.cast(inner, .f16)).raw(),
        else => error.UnsupportedDType,
    };
}

fn matrixProductOutputValue(inner: anytype, spec: MatrixProduct, value: kernel.Value) !kernel.Value {
    if (spec.dtype == spec.accumulation_dtype) return value;
    return switch (spec.dtype) {
        .f32 => inner.cast(value, .f32),
        .f16 => inner.cast(value, .f16),
        else => error.UnsupportedDType,
    };
}

fn matrixProductSpecialization(comptime spec: MatrixProduct) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .accumulation_dtype = spec.accumulation_dtype,
        .operation = .{ .linalg = .matrix_product },
        .equation = "mk,kn->mn",
        .inputs = &.{
            entry.shape2D(spec.row_axis, spec.m, spec.reduction_axis, spec.k),
            entry.shape2D(spec.reduction_axis, spec.k, spec.col_axis, spec.n),
        },
        .outputs = &.{entry.shape2D(spec.row_axis, spec.m, spec.col_axis, spec.n)},
        .reductions = &.{entry.reduction("dot", .dot_product, entry.shape1D(spec.reduction_axis, spec.k))},
        .launch = entry.launch2D(spec.n, spec.m, spec.threads.x, spec.threads.y),
        .schedule = entry.threadBlocks2D(spec.col_axis, spec.n, spec.row_axis, spec.m, spec.threads.x, spec.threads.y),
    };
}

fn batchedMatrixProductSpecialization(comptime spec: BatchedMatrixProduct) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .linalg = .batched_matrix_product },
        .equation = "bmk,bkn->bmn",
        .inputs = &.{
            entry.shape3D(spec.batch_axis, spec.batch, spec.row_axis, spec.m, spec.reduction_axis, spec.k),
            entry.shape3D(spec.batch_axis, spec.batch, spec.reduction_axis, spec.k, spec.col_axis, spec.n),
        },
        .outputs = &.{entry.shape3D(spec.batch_axis, spec.batch, spec.row_axis, spec.m, spec.col_axis, spec.n)},
        .reductions = &.{entry.reduction("dot", .dot_product, entry.shape1D(spec.reduction_axis, spec.k))},
        .launch = entry.launch3D(spec.n, spec.m, spec.batch, spec.threads.x, spec.threads.y, spec.threads.z),
        .schedule = entry.threadBlocks3D(spec.col_axis, spec.n, spec.row_axis, spec.m, spec.batch_axis, spec.batch, spec.threads.x, spec.threads.y, spec.threads.z),
    };
}

fn matrixVectorProductSpecialization(comptime spec: MatrixVectorProduct) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .linalg = .matrix_vector_product },
        .equation = "mk,k->m",
        .inputs = &.{
            entry.shape2D(spec.row_axis, spec.m, spec.reduction_axis, spec.k),
            entry.shape1D(spec.reduction_axis, spec.k),
        },
        .outputs = &.{entry.shape1D(spec.row_axis, spec.m)},
        .reductions = &.{entry.reduction("dot", .dot_product, entry.shape1D(spec.reduction_axis, spec.k))},
        .launch = entry.launch1D(spec.m, spec.threads),
        .schedule = entry.threadBlocks1D(spec.row_axis, spec.m, spec.threads),
    };
}

fn outerProductSpecialization(comptime spec: OuterProduct) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .linalg = .outer_product },
        .equation = "m,n->mn",
        .inputs = &.{
            entry.shape1D(spec.lhs_axis, spec.m),
            entry.shape1D(spec.rhs_axis, spec.n),
        },
        .outputs = &.{entry.shape2D(spec.lhs_axis, spec.m, spec.rhs_axis, spec.n)},
        .launch = entry.launch2D(spec.n, spec.m, spec.threads.x, spec.threads.y),
        .schedule = entry.threadBlocks2D(spec.rhs_axis, spec.n, spec.lhs_axis, spec.m, spec.threads.x, spec.threads.y),
    };
}

fn matrix_product_cell_sum_accumulate(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const k_stride = try fold_inner.constantIndex(ctx.k_extent);
    const n_stride = try fold_inner.constantIndex(ctx.n_extent);
    const lhs_row_offset = try fold_inner.mul(ctx.row, k_stride);
    const lhs_index = try fold_inner.add(lhs_row_offset, offset);
    const rhs_row_offset = try fold_inner.mul(offset, n_stride);
    const rhs_index = try fold_inner.add(rhs_row_offset, ctx.col);
    const lhs_value = try ctx.lhs.load(fold_inner, lhs_index);
    const rhs_value = try ctx.rhs.load(fold_inner, rhs_index);
    const lhs_acc = try matrixProductAccumulationValue(fold_inner, ctx.spec, lhs_value);
    const rhs_acc = try matrixProductAccumulationValue(fold_inner, ctx.spec, rhs_value);
    const product = try fold_inner.mul(lhs_acc, rhs_acc);
    return fold_inner.add(acc, product);
}

pub fn matrixProductCellSum(
    inner: anytype,
    spec: MatrixProduct,
    lhs: anytype,
    rhs: anytype,
    row: kernel.Value,
    col: kernel.Value,
) !kernel.Value {
    const zero = try matrixProductAccumulationZero(inner, spec);
    return inner.foldRange(0, try indexExtent(spec.k), 1, zero, .{
        .spec = spec,
        .lhs = lhs,
        .rhs = rhs,
        .row = row,
        .col = col,
        .k_extent = try indexExtent(spec.k),
        .n_extent = try indexExtent(spec.n),
    }, matrix_product_cell_sum_accumulate);
}

pub fn outerProductCell(
    inner: anytype,
    lhs: anytype,
    rhs: anytype,
    row: kernel.Value,
    col: kernel.Value,
) !kernel.Value {
    const lhs_value = try lhs.load(inner, row);
    const rhs_value = try rhs.load(inner, col);
    const product = try lhs_value.mul(inner, rhs_value);
    return product.raw();
}

pub fn matrixProductOutputIndex(inner: anytype, spec: MatrixProduct, row: kernel.Value, col: kernel.Value) !kernel.Value {
    const n_stride = try inner.constantIndex(try indexExtent(spec.n));
    const out_row_offset = try inner.mul(row, n_stride);
    return inner.add(out_row_offset, col);
}

pub fn outerProductOutputIndex(inner: anytype, spec: OuterProduct, row: kernel.Value, col: kernel.Value) !kernel.Value {
    const n_stride = try inner.constantIndex(try indexExtent(spec.n));
    const out_row_offset = try inner.mul(row, n_stride);
    return inner.add(out_row_offset, col);
}

fn outerProductRuntimeOutputIndex(inner: anytype, row: kernel.Value, col: kernel.Value, n_extent: kernel.Value) !kernel.Value {
    const out_row_offset = try inner.mul(row, n_extent);
    return inner.add(out_row_offset, col);
}

fn batched_matrix_product_cell_sum_accumulate(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const lhs_batch_stride = try fold_inner.constantIndex(ctx.lhs_batch_extent);
    const lhs_row_stride = try fold_inner.constantIndex(ctx.k_extent);
    const rhs_batch_stride = try fold_inner.constantIndex(ctx.rhs_batch_extent);
    const rhs_row_stride = try fold_inner.constantIndex(ctx.n_extent);
    const lhs_batch_offset = try fold_inner.mul(ctx.batch, lhs_batch_stride);
    const lhs_row_offset = try fold_inner.mul(ctx.row, lhs_row_stride);
    const lhs_batch_row_offset = try fold_inner.add(lhs_batch_offset, lhs_row_offset);
    const lhs_index = try fold_inner.add(lhs_batch_row_offset, offset);
    const rhs_batch_offset = try fold_inner.mul(ctx.batch, rhs_batch_stride);
    const rhs_row_offset = try fold_inner.mul(offset, rhs_row_stride);
    const rhs_batch_row_offset = try fold_inner.add(rhs_batch_offset, rhs_row_offset);
    const rhs_index = try fold_inner.add(rhs_batch_row_offset, ctx.col);
    const lhs_value = try ctx.lhs.load(fold_inner, lhs_index);
    const rhs_value = try ctx.rhs.load(fold_inner, rhs_index);
    const product = try lhs_value.mul(fold_inner, rhs_value);
    return fold_inner.add(acc, product.raw());
}

pub fn batchedMatrixProductCellSum(
    inner: anytype,
    spec: BatchedMatrixProduct,
    lhs: anytype,
    rhs: anytype,
    batch: kernel.Value,
    row: kernel.Value,
    col: kernel.Value,
) !kernel.Value {
    const zero = try inner.constantFloat(.f32, 0.0);
    return inner.foldRange(0, try indexExtent(spec.k), 1, zero, .{
        .lhs = lhs,
        .rhs = rhs,
        .batch = batch,
        .row = row,
        .col = col,
        .lhs_batch_extent = try indexProduct(spec.m, spec.k),
        .k_extent = try indexExtent(spec.k),
        .rhs_batch_extent = try indexProduct(spec.k, spec.n),
        .n_extent = try indexExtent(spec.n),
    }, batched_matrix_product_cell_sum_accumulate);
}

pub fn batchedMatrixProductOutputIndex(
    inner: anytype,
    spec: BatchedMatrixProduct,
    batch: kernel.Value,
    row: kernel.Value,
    col: kernel.Value,
) !kernel.Value {
    const batch_stride = try inner.constantIndex(try indexProduct(spec.m, spec.n));
    const row_stride = try inner.constantIndex(try indexExtent(spec.n));
    const batch_offset = try inner.mul(batch, batch_stride);
    const row_offset = try inner.mul(row, row_stride);
    const batch_row_offset = try inner.add(batch_offset, row_offset);
    return inner.add(batch_row_offset, col);
}

fn batchedMatrixProductRuntimeOutputIndex(
    inner: anytype,
    batch: kernel.Value,
    row: kernel.Value,
    col: kernel.Value,
    m_extent: kernel.Value,
    n_extent: kernel.Value,
) !kernel.Value {
    const batch_stride = try inner.mul(m_extent, n_extent);
    const batch_offset = try inner.mul(batch, batch_stride);
    const row_offset = try inner.mul(row, n_extent);
    const batch_row_offset = try inner.add(batch_offset, row_offset);
    return inner.add(batch_row_offset, col);
}

fn matrix_vector_product_row_sum_accumulate(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const k_stride = try fold_inner.constantIndex(ctx.k_extent);
    const matrix_row_offset = try fold_inner.mul(ctx.row, k_stride);
    const matrix_index = try fold_inner.add(matrix_row_offset, offset);
    const matrix_value = try ctx.matrix.load(fold_inner, matrix_index);
    const vector_value = try ctx.vector.load(fold_inner, offset);
    const product = try matrix_value.mul(fold_inner, vector_value);
    return fold_inner.add(acc, product.raw());
}

pub fn matrixVectorProductRowSum(
    inner: anytype,
    spec: MatrixVectorProduct,
    matrix: anytype,
    vector: anytype,
    row: kernel.Value,
) !kernel.Value {
    const zero = try inner.constantFloat(.f32, 0.0);
    return inner.foldRange(0, try indexExtent(spec.k), 1, zero, .{
        .matrix = matrix,
        .vector = vector,
        .row = row,
        .k_extent = try indexExtent(spec.k),
    }, matrix_vector_product_row_sum_accumulate);
}

fn matrix_vector_product_body_each(inner: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const sum = try matrixVectorProductRowSum(inner, ctx.spec, ctx.args.param(.matrix), ctx.args.param(.vector), index.index);
    try ctx.args.param(.dst).store(inner, sum, index);
}

fn matrixVectorProductBody(k: anytype, spec: MatrixVectorProduct, args: anytype) !void {
    _ = try k.forEach1D(spec.row_axis, spec.m, .{ .spec = spec, .args = args }, matrix_vector_product_body_each);
}

fn outer_product_body_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const value = try outerProductCell(inner, ctx.args.param(.lhs), ctx.args.param(.rhs), index.y.index, index.x.index);
    const out_index = try outerProductOutputIndex(inner, ctx.spec, index.y.index, index.x.index);
    try ctx.args.param(.dst).store(inner, value, out_index);
}

fn outerProductBody(k: anytype, spec: OuterProduct, args: anytype) !void {
    _ = try k.forEach2D(.{
        .x = kernel.logical.axis(spec.rhs_axis, spec.n),
        .y = kernel.logical.axis(spec.lhs_axis, spec.m),
    }, .{ .spec = spec, .args = args }, outer_product_body_each);
}

fn batched_matrix_product_body_each(inner: anytype, index: kernel.Index3D, ctx: anytype) !void {
    const sum = try batchedMatrixProductCellSum(inner, ctx.spec, ctx.args.param(.lhs), ctx.args.param(.rhs), index.z.index, index.y.index, index.x.index);
    const out_index = try batchedMatrixProductOutputIndex(inner, ctx.spec, index.z.index, index.y.index, index.x.index);
    try ctx.args.param(.dst).store(inner, sum, out_index);
}

fn batchedMatrixProductBody(k: anytype, spec: BatchedMatrixProduct, args: anytype) !void {
    _ = try k.forEach3D(.{
        .x = kernel.logical.axis(spec.col_axis, spec.n),
        .y = kernel.logical.axis(spec.row_axis, spec.m),
        .z = kernel.logical.axis(spec.batch_axis, spec.batch),
    }, .{ .spec = spec, .args = args }, batched_matrix_product_body_each);
}

fn matrix_vector_product_runtime_row_sum_accumulate(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const matrix_row_offset = try fold_inner.mul(ctx.row, ctx.k_extent);
    const matrix_index = try fold_inner.add(matrix_row_offset, offset);
    const matrix_value = try ctx.matrix.load(fold_inner, matrix_index);
    const vector_value = try ctx.vector.load(fold_inner, offset);
    const product = try matrix_value.mul(fold_inner, vector_value);
    return fold_inner.add(acc, product.raw());
}

fn matrixVectorProductRuntimeRowSum(
    inner: anytype,
    matrix: anytype,
    vector: anytype,
    row: kernel.Value,
    k_extent: kernel.Value,
) !kernel.Value {
    const lower = try inner.constantIndex(0);
    const step = try inner.constantIndex(1);
    const zero = try inner.constantFloat(.f32, 0.0);
    return inner.fold(lower, k_extent, step, zero, .{
        .matrix = matrix,
        .vector = vector,
        .row = row,
        .k_extent = k_extent,
    }, matrix_vector_product_runtime_row_sum_accumulate);
}

fn matrix_product_body_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const sum = try matrixProductCellSum(inner, ctx.spec, ctx.args.param(.lhs), ctx.args.param(.rhs), index.y.index, index.x.index);
    const out_index = try matrixProductOutputIndex(inner, ctx.spec, index.y.index, index.x.index);
    try ctx.args.param(.dst).store(inner, try matrixProductOutputValue(inner, ctx.spec, sum), out_index);
}

fn matrixProductBody(k: anytype, spec: MatrixProduct, args: anytype) !void {
    _ = try k.forEach2D(.{
        .x = kernel.logical.axis(spec.col_axis, spec.n),
        .y = kernel.logical.axis(spec.row_axis, spec.m),
    }, .{ .spec = spec, .args = args }, matrix_product_body_each);
}

fn matrix_product_runtime_cell_sum_accumulate(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const lhs_row_offset = try fold_inner.mul(ctx.row, ctx.k_extent);
    const lhs_index = try fold_inner.add(lhs_row_offset, offset);
    const rhs_row_offset = try fold_inner.mul(offset, ctx.n_extent);
    const rhs_index = try fold_inner.add(rhs_row_offset, ctx.col);
    const lhs_value = try ctx.lhs.load(fold_inner, lhs_index);
    const rhs_value = try ctx.rhs.load(fold_inner, rhs_index);
    const lhs_acc = try matrixProductAccumulationValue(fold_inner, ctx.spec, lhs_value);
    const rhs_acc = try matrixProductAccumulationValue(fold_inner, ctx.spec, rhs_value);
    const product = try fold_inner.mul(lhs_acc, rhs_acc);
    return fold_inner.add(acc, product);
}

fn matrixProductRuntimeCellSum(
    inner: anytype,
    spec: MatrixProduct,
    lhs: anytype,
    rhs: anytype,
    row: kernel.Value,
    col: kernel.Value,
    n_extent: kernel.Value,
    k_extent: kernel.Value,
) !kernel.Value {
    const lower = try inner.constantIndex(0);
    const step = try inner.constantIndex(1);
    const zero = try matrixProductAccumulationZero(inner, spec);
    return inner.fold(lower, k_extent, step, zero, .{
        .spec = spec,
        .lhs = lhs,
        .rhs = rhs,
        .row = row,
        .col = col,
        .n_extent = n_extent,
        .k_extent = k_extent,
    }, matrix_product_runtime_cell_sum_accumulate);
}

fn matrixProductRuntimeOutputIndex(inner: anytype, row: kernel.Value, col: kernel.Value, n_extent: kernel.Value) !kernel.Value {
    const out_row_offset = try inner.mul(row, n_extent);
    return inner.add(out_row_offset, col);
}

fn batched_matrix_product_runtime_cell_sum_accumulate(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const lhs_batch_stride = try fold_inner.mul(ctx.m_extent, ctx.k_extent);
    const lhs_batch_offset = try fold_inner.mul(ctx.batch, lhs_batch_stride);
    const lhs_row_offset = try fold_inner.mul(ctx.row, ctx.k_extent);
    const lhs_batch_row_offset = try fold_inner.add(lhs_batch_offset, lhs_row_offset);
    const lhs_index = try fold_inner.add(lhs_batch_row_offset, offset);
    const rhs_batch_stride = try fold_inner.mul(ctx.k_extent, ctx.n_extent);
    const rhs_batch_offset = try fold_inner.mul(ctx.batch, rhs_batch_stride);
    const rhs_row_offset = try fold_inner.mul(offset, ctx.n_extent);
    const rhs_batch_row_offset = try fold_inner.add(rhs_batch_offset, rhs_row_offset);
    const rhs_index = try fold_inner.add(rhs_batch_row_offset, ctx.col);
    const lhs_value = try ctx.lhs.load(fold_inner, lhs_index);
    const rhs_value = try ctx.rhs.load(fold_inner, rhs_index);
    const product = try lhs_value.mul(fold_inner, rhs_value);
    return fold_inner.add(acc, product.raw());
}

fn batchedMatrixProductRuntimeCellSum(
    inner: anytype,
    lhs: anytype,
    rhs: anytype,
    batch: kernel.Value,
    row: kernel.Value,
    col: kernel.Value,
    m_extent: kernel.Value,
    n_extent: kernel.Value,
    k_extent: kernel.Value,
) !kernel.Value {
    const lower = try inner.constantIndex(0);
    const step = try inner.constantIndex(1);
    const zero = try inner.constantFloat(.f32, 0.0);
    return inner.fold(lower, k_extent, step, zero, .{
        .lhs = lhs,
        .rhs = rhs,
        .batch = batch,
        .row = row,
        .col = col,
        .m_extent = m_extent,
        .n_extent = n_extent,
        .k_extent = k_extent,
    }, batched_matrix_product_runtime_cell_sum_accumulate);
}

fn matrix_product_runtime_body_row_active(inner: anytype, ctx: anytype) !void {
    const col_active = try inner.compare(.lt, ctx.col, ctx.n_extent);
    try inner.guardDo(col_active, ctx, matrix_product_runtime_body_col_active);
}

fn matrix_product_runtime_body_col_active(active_inner: anytype, active_ctx: anytype) !void {
    const sum = try matrixProductRuntimeCellSum(
        active_inner,
        active_ctx.spec,
        active_ctx.args.param(.lhs),
        active_ctx.args.param(.rhs),
        active_ctx.row,
        active_ctx.col,
        active_ctx.n_extent,
        active_ctx.k_extent,
    );
    const out_index = try matrixProductRuntimeOutputIndex(active_inner, active_ctx.row, active_ctx.col, active_ctx.n_extent);
    try active_ctx.args.param(.dst).store(active_inner, try matrixProductOutputValue(active_inner, active_ctx.spec, sum), out_index);
}

fn matrixProductRuntimeBody(k: anytype, spec: MatrixProduct, args: anytype) !void {
    const row = try k.globalId(.y);
    const col = try k.globalId(.x);
    const m_extent = try k.castIndex(args.param(.m).raw());
    const n_extent = try k.castIndex(args.param(.n).raw());
    const k_extent = try k.castIndex(args.param(.k).raw());
    const row_active = try k.compare(.lt, row, m_extent);
    try k.guardDo(row_active, .{
        .args = args,
        .spec = spec,
        .row = row,
        .col = col,
        .n_extent = n_extent,
        .k_extent = k_extent,
    }, matrix_product_runtime_body_row_active);
}

fn batched_matrix_product_runtime_body_batch_active(inner: anytype, ctx: anytype) !void {
    const row_active = try inner.compare(.lt, ctx.row, ctx.m_extent);
    try inner.guardDo(row_active, ctx, batched_matrix_product_runtime_body_row_active);
}

fn batched_matrix_product_runtime_body_row_active(row_inner: anytype, row_ctx: anytype) !void {
    const col_active = try row_inner.compare(.lt, row_ctx.col, row_ctx.n_extent);
    try row_inner.guardDo(col_active, row_ctx, batched_matrix_product_runtime_body_col_active);
}

fn batched_matrix_product_runtime_body_col_active(active_inner: anytype, active_ctx: anytype) !void {
    const sum = try batchedMatrixProductRuntimeCellSum(
        active_inner,
        active_ctx.args.param(.lhs),
        active_ctx.args.param(.rhs),
        active_ctx.batch,
        active_ctx.row,
        active_ctx.col,
        active_ctx.m_extent,
        active_ctx.n_extent,
        active_ctx.k_extent,
    );
    const out_index = try batchedMatrixProductRuntimeOutputIndex(
        active_inner,
        active_ctx.batch,
        active_ctx.row,
        active_ctx.col,
        active_ctx.m_extent,
        active_ctx.n_extent,
    );
    try active_ctx.args.param(.dst).store(active_inner, sum, out_index);
}

fn batchedMatrixProductRuntimeBody(k: anytype, spec: BatchedMatrixProduct, args: anytype) !void {
    _ = spec;
    const batch = try k.globalId(.z);
    const row = try k.globalId(.y);
    const col = try k.globalId(.x);
    const batch_extent = try k.castIndex(args.param(.batch).raw());
    const m_extent = try k.castIndex(args.param(.m).raw());
    const n_extent = try k.castIndex(args.param(.n).raw());
    const k_extent = try k.castIndex(args.param(.k).raw());
    const batch_active = try k.compare(.lt, batch, batch_extent);
    try k.guardDo(batch_active, .{
        .args = args,
        .batch = batch,
        .row = row,
        .col = col,
        .m_extent = m_extent,
        .n_extent = n_extent,
        .k_extent = k_extent,
    }, batched_matrix_product_runtime_body_batch_active);
}

fn matrix_vector_product_runtime_body_row_active(inner: anytype, ctx: anytype) !void {
    const sum = try matrixVectorProductRuntimeRowSum(
        inner,
        ctx.args.param(.matrix),
        ctx.args.param(.vector),
        ctx.row,
        ctx.k_extent,
    );
    try ctx.args.param(.dst).store(inner, sum, ctx.row);
}

fn matrixVectorProductRuntimeBody(k: anytype, spec: MatrixVectorProduct, args: anytype) !void {
    _ = spec;
    const row = try k.globalId(.x);
    const m_extent = try k.castIndex(args.param(.m).raw());
    const k_extent = try k.castIndex(args.param(.k).raw());
    const row_active = try k.compare(.lt, row, m_extent);
    try k.guardDo(row_active, .{
        .args = args,
        .row = row,
        .k_extent = k_extent,
    }, matrix_vector_product_runtime_body_row_active);
}

fn outer_product_runtime_body_row_active(inner: anytype, ctx: anytype) !void {
    const col_active = try inner.compare(.lt, ctx.col, ctx.n_extent);
    try inner.guardDo(col_active, ctx, outer_product_runtime_body_col_active);
}

fn outer_product_runtime_body_col_active(active_inner: anytype, active_ctx: anytype) !void {
    const value = try outerProductCell(
        active_inner,
        active_ctx.args.param(.lhs),
        active_ctx.args.param(.rhs),
        active_ctx.row,
        active_ctx.col,
    );
    const out_index = try outerProductRuntimeOutputIndex(active_inner, active_ctx.row, active_ctx.col, active_ctx.n_extent);
    try active_ctx.args.param(.dst).store(active_inner, value, out_index);
}

fn outerProductRuntimeBody(k: anytype, spec: OuterProduct, args: anytype) !void {
    _ = spec;
    const row = try k.globalId(.y);
    const col = try k.globalId(.x);
    const m_extent = try k.castIndex(args.param(.m).raw());
    const n_extent = try k.castIndex(args.param(.n).raw());
    const row_active = try k.compare(.lt, row, m_extent);
    try k.guardDo(row_active, .{
        .args = args,
        .row = row,
        .col = col,
        .n_extent = n_extent,
    }, outer_product_runtime_body_row_active);
}

fn matrixProductFamilySchedule(instance: MatrixProduct) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{
        .x = instance.threads.x,
        .y = instance.threads.y,
    });
}

fn matrixVectorProductFamilySchedule(instance: MatrixVectorProduct) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn batchedMatrixProductFamilySchedule(instance: BatchedMatrixProduct) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{
        .x = instance.threads.x,
        .y = instance.threads.y,
        .z = instance.threads.z,
    });
}

fn outerProductFamilySchedule(instance: OuterProduct) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{
        .x = instance.threads.x,
        .y = instance.threads.y,
    });
}

fn matrixProductFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_matmul_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .lhs = kernel.dynamicBuffer(dtype),
            .rhs = kernel.dynamicBuffer(dtype),
        },
        .Instance = MatrixProduct,
        .schedule = matrixProductFamilySchedule,
        .body = matrixProductBody,
    });
}

fn matrixProductRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_matmul_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .lhs = kernel.dynamicBuffer(dtype),
            .rhs = kernel.dynamicBuffer(dtype),
            .m = kernel.scalar(.i32),
            .n = kernel.scalar(.i32),
            .k = kernel.scalar(.i32),
        },
        .Instance = MatrixProduct,
        .schedule = matrixProductFamilySchedule,
        .body = matrixProductRuntimeBody,
    });
}

fn matrixVectorProductFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_matvec_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .matrix = kernel.dynamicBuffer(dtype),
            .vector = kernel.dynamicBuffer(dtype),
        },
        .Instance = MatrixVectorProduct,
        .schedule = matrixVectorProductFamilySchedule,
        .body = matrixVectorProductBody,
    });
}

fn matrixVectorProductRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_matvec_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .matrix = kernel.dynamicBuffer(dtype),
            .vector = kernel.dynamicBuffer(dtype),
            .m = kernel.scalar(.i32),
            .k = kernel.scalar(.i32),
        },
        .Instance = MatrixVectorProduct,
        .schedule = matrixVectorProductFamilySchedule,
        .body = matrixVectorProductRuntimeBody,
    });
}

fn batchedMatrixProductFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_batched_matmul_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .lhs = kernel.dynamicBuffer(dtype),
            .rhs = kernel.dynamicBuffer(dtype),
        },
        .Instance = BatchedMatrixProduct,
        .schedule = batchedMatrixProductFamilySchedule,
        .body = batchedMatrixProductBody,
    });
}

fn batchedMatrixProductRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_batched_matmul_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .lhs = kernel.dynamicBuffer(dtype),
            .rhs = kernel.dynamicBuffer(dtype),
            .batch = kernel.scalar(.i32),
            .m = kernel.scalar(.i32),
            .n = kernel.scalar(.i32),
            .k = kernel.scalar(.i32),
        },
        .Instance = BatchedMatrixProduct,
        .schedule = batchedMatrixProductFamilySchedule,
        .body = batchedMatrixProductRuntimeBody,
    });
}

fn outerProductFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_outer_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .lhs = kernel.dynamicBuffer(dtype),
            .rhs = kernel.dynamicBuffer(dtype),
        },
        .Instance = OuterProduct,
        .schedule = outerProductFamilySchedule,
        .body = outerProductBody,
    });
}

fn outerProductRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_linalg_outer_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .lhs = kernel.dynamicBuffer(dtype),
            .rhs = kernel.dynamicBuffer(dtype),
            .m = kernel.scalar(.i32),
            .n = kernel.scalar(.i32),
        },
        .Instance = OuterProduct,
        .schedule = outerProductFamilySchedule,
        .body = outerProductRuntimeBody,
    });
}

pub const MatrixProductFamilyF32 = matrixProductFamily(.f32);
pub const MatrixProductFamilyF16 = matrixProductFamily(.f16);
pub const MatrixProductRuntimeFamilyF32 = matrixProductRuntimeFamily(.f32);
pub const MatrixProductRuntimeFamilyF16 = matrixProductRuntimeFamily(.f16);
pub const MatrixVectorProductFamilyF32 = matrixVectorProductFamily(.f32);
pub const MatrixVectorProductRuntimeFamilyF32 = matrixVectorProductRuntimeFamily(.f32);
pub const BatchedMatrixProductFamilyF32 = batchedMatrixProductFamily(.f32);
pub const BatchedMatrixProductRuntimeFamilyF32 = batchedMatrixProductRuntimeFamily(.f32);
pub const OuterProductFamilyF32 = outerProductFamily(.f32);
pub const OuterProductRuntimeFamilyF32 = outerProductRuntimeFamily(.f32);

pub const matrix_product_family_version: u32 = 1;
pub const matrix_vector_product_family_version: u32 = 1;
pub const batched_matrix_product_family_version: u32 = 1;
pub const outer_product_family_version: u32 = 1;
const matrix_product_thread_caps = geometry_mod.ThreadCaps{
    .budget = 256,
    .x_max = 64,
    .y_max = 16,
};
const batched_matrix_product_thread_budget: u32 = 256;
const batched_matrix_product_z_max: u32 = 8;
const matrix_vector_product_thread_caps = geometry_mod.ThreadCaps1D{};
const outer_product_thread_caps = geometry_mod.ThreadCaps{
    .budget = 256,
    .x_max = 64,
    .y_max = 16,
};

pub fn matrixProductThreadsForExtents(m: u64, n: u64) entry.Threads2D {
    return geometry_mod.threadsForGrid(.{ .rows = m, .cols = n }, matrix_product_thread_caps);
}

pub fn matrixProductThreadCandidatesForExtents(m: u64, n: u64) geometry_mod.ThreadCandidates {
    return geometry_mod.threadCandidatesForGrid(.{ .rows = m, .cols = n }, matrix_product_thread_caps);
}

pub fn batchedMatrixProductThreadsForExtents(batch: u64, m: u64, n: u64) entry.Threads3D {
    const matrix_threads = matrixProductThreadsForExtents(m, n);
    const xy_threads = matrix_threads.x * matrix_threads.y;
    const z_budget = @max(@as(u32, 1), batched_matrix_product_thread_budget / xy_threads);
    const z_extent: u32 = @intCast(@max(@as(u64, 1), @min(batch, @min(@as(u64, batched_matrix_product_z_max), @as(u64, z_budget)))));
    return .{ .x = matrix_threads.x, .y = matrix_threads.y, .z = z_extent };
}

pub fn matrixVectorProductThreadsForExtents(m: u64) u32 {
    return geometry_mod.threadsForExtent(m, matrix_vector_product_thread_caps);
}

pub fn matrixVectorProductThreadCandidatesForExtents(m: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(m, matrix_vector_product_thread_caps);
}

pub fn outerProductThreadsForExtents(m: u64, n: u64) entry.Threads2D {
    return geometry_mod.threadsForGrid(.{ .rows = m, .cols = n }, outer_product_thread_caps);
}

pub fn matrixProductInstanceTarget(allocator: std.mem.Allocator, instance: MatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.matmul{d}x{d}x{d}_{d}x{d}_{s}",
        .{ instance.m, instance.n, instance.k, instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn matrixProductInstanceEntryName(allocator: std.mem.Allocator, instance: MatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_matmul{d}x{d}x{d}_{d}x{d}_{s}",
        .{ instance.m, instance.n, instance.k, instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn matrixProductFamilyTarget(allocator: std.mem.Allocator, instance: MatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.matmul_family_{d}x{d}_{s}",
        .{ instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn matrixProductFamilyEntryName(allocator: std.mem.Allocator, instance: MatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_matmul_family_{d}x{d}_{s}",
        .{ instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn batchedMatrixProductInstanceTarget(allocator: std.mem.Allocator, instance: BatchedMatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.batched_matmul{d}x{d}x{d}x{d}_{d}x{d}x{d}_f32",
        .{ instance.batch, instance.m, instance.n, instance.k, instance.threads.x, instance.threads.y, instance.threads.z },
    );
}

pub fn batchedMatrixProductInstanceEntryName(allocator: std.mem.Allocator, instance: BatchedMatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_batched_matmul{d}x{d}x{d}x{d}_{d}x{d}x{d}_f32",
        .{ instance.batch, instance.m, instance.n, instance.k, instance.threads.x, instance.threads.y, instance.threads.z },
    );
}

pub fn batchedMatrixProductFamilyTarget(allocator: std.mem.Allocator, instance: BatchedMatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.batched_matmul_family_{d}x{d}x{d}_f32",
        .{ instance.threads.x, instance.threads.y, instance.threads.z },
    );
}

pub fn batchedMatrixProductFamilyEntryName(allocator: std.mem.Allocator, instance: BatchedMatrixProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_batched_matmul_family_{d}x{d}x{d}_f32",
        .{ instance.threads.x, instance.threads.y, instance.threads.z },
    );
}

pub fn matrixVectorProductInstanceTarget(allocator: std.mem.Allocator, instance: MatrixVectorProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.matvec{d}x{d}_{d}x_f32",
        .{ instance.m, instance.k, instance.threads },
    );
}

pub fn matrixVectorProductInstanceEntryName(allocator: std.mem.Allocator, instance: MatrixVectorProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_matvec{d}x{d}_{d}x_f32",
        .{ instance.m, instance.k, instance.threads },
    );
}

pub fn matrixVectorProductFamilyTarget(allocator: std.mem.Allocator, instance: MatrixVectorProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.matvec_family_{d}x_f32",
        .{instance.threads},
    );
}

pub fn matrixVectorProductFamilyEntryName(allocator: std.mem.Allocator, instance: MatrixVectorProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_matvec_family_{d}x_f32",
        .{instance.threads},
    );
}

pub fn outerProductInstanceTarget(allocator: std.mem.Allocator, instance: OuterProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.outer{d}x{d}_{d}x{d}_f32",
        .{ instance.m, instance.n, instance.threads.x, instance.threads.y },
    );
}

pub fn outerProductInstanceEntryName(allocator: std.mem.Allocator, instance: OuterProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_outer{d}x{d}_{d}x{d}_f32",
        .{ instance.m, instance.n, instance.threads.x, instance.threads.y },
    );
}

pub fn outerProductFamilyTarget(allocator: std.mem.Allocator, instance: OuterProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.linalg.outer_family_{d}x{d}_f32",
        .{ instance.threads.x, instance.threads.y },
    );
}

pub fn outerProductFamilyEntryName(allocator: std.mem.Allocator, instance: OuterProduct) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_linalg_outer_family_{d}x{d}_f32",
        .{ instance.threads.x, instance.threads.y },
    );
}

pub fn matrixProductTuningExtents(instance: MatrixProduct) [3]u64 {
    return .{ instance.m, instance.n, instance.k };
}

pub fn matrixProductTuningOperation(instance: MatrixProduct) entry.Operation {
    _ = instance;
    return .{ .linalg = .matrix_product };
}

pub fn matrixProductFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: MatrixProduct,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try matrixProductFamilyFingerprint(backing_allocator, instance);
    const extents = matrixProductTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(matrixProductTuningOperation(instance)),
        instance.dtype,
        matrix_product_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveMatrixProductSchedule(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: MatrixProduct,
) !?entry.Threads2D {
    const key = try matrixProductFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    const thread_candidates = matrixProductThreadCandidatesForExtents(instance.m, instance.n);
    for (thread_candidates.slice()) |threads| {
        var candidate = instance;
        candidate.threads = threads;
        const target = try matrixProductFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return threads;
    }
    return null;
}

/// A caller builds this reader from tuning records, each a measured winner pairing a device and
/// problem key with the fastest thread shape, so matrix-product kernels use the fastest known
/// thread shape on one device. The reader holds a device identity, a code format, and a list of
/// tuning records. `resolve` returns the recorded thread shape for a matrix product, or null when
/// the product has fewer than two possible thread shapes or no record matches, and null leaves the
/// default schedule in place. `resolve` returns `error.InvalidArtifact` when a matching record
/// names a thread shape outside the product's possible shapes. The reader borrows the records and
/// the device name strings, so the caller keeps them alive while the reader is used, and a stage
/// recipe that stores the reader copies their values.
pub const MatrixProductScheduleReader = struct {
    device: gpu.DeviceIdentity,
    format: gpu.ArtifactFormat,
    records: []const tuning.MatrixProductFamilyScheduleTuningRecord = &.{},

    pub fn resolve(
        self: MatrixProductScheduleReader,
        instance: MatrixProduct,
    ) gpu.BackendError!?entry.Threads2D {
        const threads = matrixProductThreadCandidatesForExtents(instance.m, instance.n);
        const candidates = threads.slice();
        if (candidates.len < 2) return null;
        const capacity = tuning.matrix_product_family_schedule_tuning_max_candidates;
        std.debug.assert(candidates.len <= capacity);
        var values: [capacity]tuning.MatrixProductFamilyScheduleThreads = undefined;
        for (candidates, 0..) |candidate, index| {
            values[index] = .{ .x = candidate.x, .y = candidate.y };
        }
        const key = try tuning.MatrixProductFamilyScheduleTuningKey.init(self.device, .{
            .format = self.format,
            .m = instance.m,
            .n = instance.n,
            .k = instance.k,
            .dtype = instance.dtype,
            .accumulation_dtype = instance.accumulation_dtype,
            .family_version = matrix_product_family_version,
            .candidates = values[0..candidates.len],
        });
        for (self.records) |record| {
            if (!record.key.eql(key)) continue;
            for (candidates) |candidate| {
                if (candidate.x == record.selection.threads.x and
                    candidate.y == record.selection.threads.y) return candidate;
            }
            return error.InvalidArtifact;
        }
        return null;
    }

    pub fn eql(self: MatrixProductScheduleReader, other: MatrixProductScheduleReader) bool {
        if (self.format != other.format or !sameDevice(self.device, other.device)) return false;
        if (self.records.len != other.records.len) return false;
        for (self.records, other.records) |lhs, rhs| {
            if (lhs.version != rhs.version or !lhs.key.eql(rhs.key)) return false;
            if (!std.meta.eql(lhs.selection, rhs.selection)) return false;
        }
        return true;
    }

    fn sameDevice(lhs: gpu.DeviceIdentity, rhs: gpu.DeviceIdentity) bool {
        if (lhs.backend != rhs.backend or lhs.family != rhs.family or
            lhs.vendor_id != rhs.vendor_id or lhs.device_id != rhs.device_id) return false;
        if (!std.mem.eql(u8, lhs.name, rhs.name)) return false;
        if (lhs.driver_version == null or rhs.driver_version == null) {
            return lhs.driver_version == null and rhs.driver_version == null;
        }
        return std.mem.eql(u8, lhs.driver_version.?, rhs.driver_version.?);
    }
};

pub fn matrixProductRuntimeArguments(instance: MatrixProduct) ![3]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.m) },
        .{ .u32 = try runtimeExtentArgument(instance.n) },
        .{ .u32 = try runtimeExtentArgument(instance.k) },
    };
}

pub fn matrixProductShapeProfileDimensions(instance: MatrixProduct) [3]artifact_product.KernelCallShapeProfileDimension {
    const bounds = matrixProductRuntimeExtentBounds();
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = instance.col_axis,
            .runtime_scalar_argument_index = 1,
            .bounds = bounds,
        },
        .{
            .name = instance.reduction_axis,
            .runtime_scalar_argument_index = 2,
            .bounds = bounds,
        },
    };
}

pub fn batchedMatrixProductRuntimeArguments(instance: BatchedMatrixProduct) ![4]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.batch) },
        .{ .u32 = try runtimeExtentArgument(instance.m) },
        .{ .u32 = try runtimeExtentArgument(instance.n) },
        .{ .u32 = try runtimeExtentArgument(instance.k) },
    };
}

pub fn batchedMatrixProductShapeProfileDimensions(instance: BatchedMatrixProduct) [4]artifact_product.KernelCallShapeProfileDimension {
    const bounds = batchedMatrixProductRuntimeExtentBounds();
    return .{
        .{
            .name = instance.batch_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 1,
            .bounds = bounds,
        },
        .{
            .name = instance.col_axis,
            .runtime_scalar_argument_index = 2,
            .bounds = bounds,
        },
        .{
            .name = instance.reduction_axis,
            .runtime_scalar_argument_index = 3,
            .bounds = bounds,
        },
    };
}

pub fn matrixVectorProductRuntimeArguments(instance: MatrixVectorProduct) ![2]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.m) },
        .{ .u32 = try runtimeExtentArgument(instance.k) },
    };
}

pub fn matrixVectorProductShapeProfileDimensions(instance: MatrixVectorProduct) [2]artifact_product.KernelCallShapeProfileDimension {
    const bounds = matrixVectorProductRuntimeExtentBounds();
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = instance.reduction_axis,
            .runtime_scalar_argument_index = 1,
            .bounds = bounds,
        },
    };
}

pub fn outerProductRuntimeArguments(instance: OuterProduct) ![2]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.m) },
        .{ .u32 = try runtimeExtentArgument(instance.n) },
    };
}

pub fn outerProductShapeProfileDimensions(instance: OuterProduct) [2]artifact_product.KernelCallShapeProfileDimension {
    const bounds = outerProductRuntimeExtentBounds();
    return .{
        .{
            .name = instance.lhs_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = instance.rhs_axis,
            .runtime_scalar_argument_index = 1,
            .bounds = bounds,
        },
    };
}

fn matrixProductDerivedLaunch(instance: MatrixProduct) !artifact_product.KernelCallLaunch {
    if (instance.threads.x == 0 or instance.threads.y == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = instance.threads.x } },
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads.y } },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads.x, instance.threads.y, 1 },
    } };
}

fn batchedMatrixProductDerivedLaunch(instance: BatchedMatrixProduct) !artifact_product.KernelCallLaunch {
    if (instance.threads.x == 0 or instance.threads.y == 0 or instance.threads.z == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 2, .divisor = instance.threads.x } },
            .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = instance.threads.y } },
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads.z } },
        },
        .threadgroup = .{ instance.threads.x, instance.threads.y, instance.threads.z },
    } };
}

fn matrixVectorProductDerivedLaunch(instance: MatrixVectorProduct) !artifact_product.KernelCallLaunch {
    if (instance.threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

fn outerProductDerivedLaunch(instance: OuterProduct) !artifact_product.KernelCallLaunch {
    if (instance.threads.x == 0 or instance.threads.y == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = instance.threads.x } },
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads.y } },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads.x, instance.threads.y, 1 },
    } };
}

pub fn createMatrixProductFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: MatrixProduct,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try matrixProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try matrixProductFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try matrixProductFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = matrixProductShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "matrix_product",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try MatrixProductRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .f16 => try MatrixProductRuntimeFamilyF16.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = matrix_product_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try matrixProductDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createBatchedMatrixProductFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: BatchedMatrixProduct,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try batchedMatrixProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try batchedMatrixProductFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try batchedMatrixProductFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = batchedMatrixProductShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "batched_matrix_product",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try BatchedMatrixProductRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance);
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = batched_matrix_product_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try batchedMatrixProductDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 4 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createMatrixVectorProductFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: MatrixVectorProduct,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try matrixVectorProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try matrixVectorProductFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try matrixVectorProductFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = matrixVectorProductShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "matrix_vector_product",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try MatrixVectorProductRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance);
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = matrix_vector_product_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try matrixVectorProductDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 2 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createOuterProductFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: OuterProduct,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try outerProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try outerProductFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try outerProductFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = outerProductShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "outer_product",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try OuterProductRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance);
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = outer_product_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try outerProductDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 2 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn matrixProductFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: MatrixProduct) !u64 {
    var family = try matrixProductShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn matrixProductShapeFamily(backing_allocator: std.mem.Allocator, instance: MatrixProduct) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "matrix_product");
    errdefer builder.deinit();

    const m = try builder.symbol(instance.row_axis);
    const n = try builder.symbol(instance.col_axis);
    const k = try builder.symbol(instance.reduction_axis);

    const m_expr = try builder.symbolExpression(m);
    const n_expr = try builder.symbolExpression(n);
    const k_expr = try builder.symbolExpression(k);

    _ = try builder.tensor("lhs", &.{ m_expr, k_expr });
    _ = try builder.tensor("rhs", &.{ k_expr, n_expr });
    _ = try builder.tensor("out", &.{ m_expr, n_expr });
    try builder.assumeBounds(m_expr, matrixProductRuntimeExtentBounds());
    try builder.assumeBounds(n_expr, matrixProductRuntimeExtentBounds());
    try builder.assumeBounds(k_expr, matrixProductRuntimeExtentBounds());

    return builder.finish();
}

fn matrixProductRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

pub fn batchedMatrixProductFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: BatchedMatrixProduct) !u64 {
    var family = try batchedMatrixProductShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn batchedMatrixProductShapeFamily(backing_allocator: std.mem.Allocator, instance: BatchedMatrixProduct) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "batched_matrix_product");
    errdefer builder.deinit();

    const batch = try builder.symbol(instance.batch_axis);
    const m = try builder.symbol(instance.row_axis);
    const n = try builder.symbol(instance.col_axis);
    const k = try builder.symbol(instance.reduction_axis);

    const batch_expr = try builder.symbolExpression(batch);
    const m_expr = try builder.symbolExpression(m);
    const n_expr = try builder.symbolExpression(n);
    const k_expr = try builder.symbolExpression(k);

    _ = try builder.tensor("lhs", &.{ batch_expr, m_expr, k_expr });
    _ = try builder.tensor("rhs", &.{ batch_expr, k_expr, n_expr });
    _ = try builder.tensor("out", &.{ batch_expr, m_expr, n_expr });
    try builder.assumeBounds(batch_expr, batchedMatrixProductRuntimeExtentBounds());
    try builder.assumeBounds(m_expr, batchedMatrixProductRuntimeExtentBounds());
    try builder.assumeBounds(n_expr, batchedMatrixProductRuntimeExtentBounds());
    try builder.assumeBounds(k_expr, batchedMatrixProductRuntimeExtentBounds());

    return builder.finish();
}

fn batchedMatrixProductRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

pub fn matrixVectorProductFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: MatrixVectorProduct) !u64 {
    var family = try matrixVectorProductShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn matrixVectorProductShapeFamily(backing_allocator: std.mem.Allocator, instance: MatrixVectorProduct) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "matrix_vector_product");
    errdefer builder.deinit();

    const m = try builder.symbol(instance.row_axis);
    const k = try builder.symbol(instance.reduction_axis);

    const m_expr = try builder.symbolExpression(m);
    const k_expr = try builder.symbolExpression(k);

    _ = try builder.tensor("matrix", &.{ m_expr, k_expr });
    _ = try builder.tensor("vector", &.{k_expr});
    _ = try builder.tensor("out", &.{m_expr});
    try builder.assumeBounds(m_expr, matrixVectorProductRuntimeExtentBounds());
    try builder.assumeBounds(k_expr, matrixVectorProductRuntimeExtentBounds());

    return builder.finish();
}

fn matrixVectorProductRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

pub fn outerProductFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: OuterProduct) !u64 {
    var family = try outerProductShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn outerProductShapeFamily(backing_allocator: std.mem.Allocator, instance: OuterProduct) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "outer_product");
    errdefer builder.deinit();

    const m = try builder.symbol(instance.lhs_axis);
    const n = try builder.symbol(instance.rhs_axis);

    const m_expr = try builder.symbolExpression(m);
    const n_expr = try builder.symbolExpression(n);

    _ = try builder.tensor("lhs", &.{m_expr});
    _ = try builder.tensor("rhs", &.{n_expr});
    _ = try builder.tensor("out", &.{ m_expr, n_expr });
    try builder.assumeBounds(m_expr, outerProductRuntimeExtentBounds());
    try builder.assumeBounds(n_expr, outerProductRuntimeExtentBounds());

    return builder.finish();
}

fn outerProductRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

pub fn matrixProductFamilySpecialization(backing_allocator: std.mem.Allocator, instance: MatrixProduct) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape2D(lifetime_allocator, instance.row_axis, instance.m, instance.reduction_axis, instance.k);
    inputs[1] = try entry.runtimeShape2D(lifetime_allocator, instance.reduction_axis, instance.k, instance.col_axis, instance.n);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(lifetime_allocator, instance.row_axis, instance.m, instance.col_axis, instance.n);

    const reductions = try lifetime_allocator.alloc(entry.Reduction, 1);
    reductions[0] = try entry.runtimeReduction(
        lifetime_allocator,
        "dot",
        .dot_product,
        try entry.runtimeShape1D(lifetime_allocator, instance.reduction_axis, instance.k),
    );

    owned.value = .{
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .operation = .{ .linalg = .matrix_product },
        .equation = "mk,kn->mn",
        .inputs = inputs,
        .outputs = outputs,
        .reductions = reductions,
        .schedule = try entry.runtimeThreadBlocks2D(lifetime_allocator, instance.col_axis, instance.n, instance.row_axis, instance.m, instance.threads.x, instance.threads.y),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try matrixProductShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn matrixProductInstanceFromSpecialization(specialization: entry.Specialization) ?MatrixProduct {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .linalg = .matrix_product })) return null;
    const dtype = specialization.dtype orelse return null;
    const accumulation_dtype = specialization.accumulation_dtype orelse return null;
    if (matrixProductAccumulationDType(dtype) != accumulation_dtype) return null;
    const equation = specialization.equation orelse return null;
    if (!std.mem.eql(u8, equation, "mk,kn->mn")) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1 or specialization.reductions.len != 1) return null;
    const lhs = specialization.inputs[0];
    const rhs = specialization.inputs[1];
    const output = specialization.outputs[0];
    const reduction = specialization.reductions[0];
    if (lhs.axes.len != 2 or rhs.axes.len != 2 or output.axes.len != 2) return null;
    if (reduction.shape.axes.len != 1) return null;
    const m = lhs.axes[0].extent;
    const k = lhs.axes[1].extent;
    const n = rhs.axes[1].extent;
    if (!std.mem.eql(u8, lhs.axes[1].name, rhs.axes[0].name)) return null;
    if (!std.mem.eql(u8, lhs.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, rhs.axes[1].name, output.axes[1].name)) return null;
    if (!std.mem.eql(u8, reduction.shape.axes[0].name, lhs.axes[1].name)) return null;
    if (rhs.axes[0].extent != k) return null;
    if (output.axes[0].extent != m or output.axes[1].extent != n) return null;
    if (reduction.shape.axes[0].extent != k) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0 or launch.threadgroup[1] == 0) return null;
    return .{
        .m = m,
        .n = n,
        .k = k,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = .{ .x = launch.threadgroup[0], .y = launch.threadgroup[1] },
        .row_axis = lhs.axes[0].name,
        .col_axis = rhs.axes[1].name,
        .reduction_axis = lhs.axes[1].name,
    };
}

pub fn batchedMatrixProductFamilySpecialization(backing_allocator: std.mem.Allocator, instance: BatchedMatrixProduct) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape3D(lifetime_allocator, instance.batch_axis, instance.batch, instance.row_axis, instance.m, instance.reduction_axis, instance.k);
    inputs[1] = try entry.runtimeShape3D(lifetime_allocator, instance.batch_axis, instance.batch, instance.reduction_axis, instance.k, instance.col_axis, instance.n);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape3D(lifetime_allocator, instance.batch_axis, instance.batch, instance.row_axis, instance.m, instance.col_axis, instance.n);

    const reductions = try lifetime_allocator.alloc(entry.Reduction, 1);
    reductions[0] = try entry.runtimeReduction(
        lifetime_allocator,
        "dot",
        .dot_product,
        try entry.runtimeShape1D(lifetime_allocator, instance.reduction_axis, instance.k),
    );

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .linalg = .batched_matrix_product },
        .equation = "bmk,bkn->bmn",
        .inputs = inputs,
        .outputs = outputs,
        .reductions = reductions,
        .schedule = try entry.runtimeThreadBlocks3D(
            lifetime_allocator,
            instance.col_axis,
            instance.n,
            instance.row_axis,
            instance.m,
            instance.batch_axis,
            instance.batch,
            instance.threads.x,
            instance.threads.y,
            instance.threads.z,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try batchedMatrixProductShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn batchedMatrixProductInstanceFromSpecialization(specialization: entry.Specialization) ?BatchedMatrixProduct {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .linalg = .batched_matrix_product })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    const equation = specialization.equation orelse return null;
    if (!std.mem.eql(u8, equation, "bmk,bkn->bmn")) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1 or specialization.reductions.len != 1) return null;
    const lhs = specialization.inputs[0];
    const rhs = specialization.inputs[1];
    const output = specialization.outputs[0];
    const reduction = specialization.reductions[0];
    if (lhs.axes.len != 3 or rhs.axes.len != 3 or output.axes.len != 3) return null;
    if (reduction.shape.axes.len != 1) return null;
    const batch = lhs.axes[0].extent;
    const m = lhs.axes[1].extent;
    const k = lhs.axes[2].extent;
    const n = rhs.axes[2].extent;
    if (!std.mem.eql(u8, lhs.axes[0].name, rhs.axes[0].name)) return null;
    if (!std.mem.eql(u8, lhs.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, lhs.axes[1].name, output.axes[1].name)) return null;
    if (!std.mem.eql(u8, lhs.axes[2].name, rhs.axes[1].name)) return null;
    if (!std.mem.eql(u8, lhs.axes[2].name, reduction.shape.axes[0].name)) return null;
    if (!std.mem.eql(u8, rhs.axes[2].name, output.axes[2].name)) return null;
    if (rhs.axes[0].extent != batch or output.axes[0].extent != batch) return null;
    if (output.axes[1].extent != m or rhs.axes[1].extent != k or reduction.shape.axes[0].extent != k or output.axes[2].extent != n) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0 or launch.threadgroup[1] == 0 or launch.threadgroup[2] == 0) return null;
    return .{
        .batch = batch,
        .m = m,
        .n = n,
        .k = k,
        .threads = .{ .x = launch.threadgroup[0], .y = launch.threadgroup[1], .z = launch.threadgroup[2] },
        .batch_axis = lhs.axes[0].name,
        .row_axis = lhs.axes[1].name,
        .col_axis = rhs.axes[2].name,
        .reduction_axis = lhs.axes[2].name,
    };
}

pub fn matrixVectorProductFamilySpecialization(backing_allocator: std.mem.Allocator, instance: MatrixVectorProduct) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape2D(lifetime_allocator, instance.row_axis, instance.m, instance.reduction_axis, instance.k);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.reduction_axis, instance.k);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.m);

    const reductions = try lifetime_allocator.alloc(entry.Reduction, 1);
    reductions[0] = try entry.runtimeReduction(
        lifetime_allocator,
        "dot",
        .dot_product,
        try entry.runtimeShape1D(lifetime_allocator, instance.reduction_axis, instance.k),
    );

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .linalg = .matrix_vector_product },
        .equation = "mk,k->m",
        .inputs = inputs,
        .outputs = outputs,
        .reductions = reductions,
        .schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, instance.row_axis, instance.m, instance.threads),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try matrixVectorProductShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn matrixVectorProductInstanceFromSpecialization(specialization: entry.Specialization) ?MatrixVectorProduct {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .linalg = .matrix_vector_product })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    const equation = specialization.equation orelse return null;
    if (!std.mem.eql(u8, equation, "mk,k->m")) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1 or specialization.reductions.len != 1) return null;
    const matrix = specialization.inputs[0];
    const vector = specialization.inputs[1];
    const output = specialization.outputs[0];
    const reduction = specialization.reductions[0];
    if (matrix.axes.len != 2 or vector.axes.len != 1 or output.axes.len != 1) return null;
    if (reduction.shape.axes.len != 1) return null;
    const m = matrix.axes[0].extent;
    const k = matrix.axes[1].extent;
    if (!std.mem.eql(u8, matrix.axes[1].name, vector.axes[0].name)) return null;
    if (!std.mem.eql(u8, matrix.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, reduction.shape.axes[0].name, matrix.axes[1].name)) return null;
    if (vector.axes[0].extent != k) return null;
    if (output.axes[0].extent != m) return null;
    if (reduction.shape.axes[0].extent != k) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .m = m,
        .k = k,
        .threads = launch.threadgroup[0],
        .row_axis = matrix.axes[0].name,
        .reduction_axis = matrix.axes[1].name,
    };
}

pub fn outerProductFamilySpecialization(backing_allocator: std.mem.Allocator, instance: OuterProduct) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.lhs_axis, instance.m);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.rhs_axis, instance.n);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(lifetime_allocator, instance.lhs_axis, instance.m, instance.rhs_axis, instance.n);

    owned.value = .{
        .dtype = .f32,
        .operation = .{ .linalg = .outer_product },
        .equation = "m,n->mn",
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks2D(lifetime_allocator, instance.rhs_axis, instance.n, instance.lhs_axis, instance.m, instance.threads.x, instance.threads.y),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try outerProductShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn outerProductInstanceFromSpecialization(specialization: entry.Specialization) ?OuterProduct {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .linalg = .outer_product })) return null;
    const dtype = specialization.dtype orelse return null;
    if (dtype != .f32) return null;
    const equation = specialization.equation orelse return null;
    if (!std.mem.eql(u8, equation, "m,n->mn")) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1 or specialization.reductions.len != 0) return null;
    const lhs = specialization.inputs[0];
    const rhs = specialization.inputs[1];
    const output = specialization.outputs[0];
    if (lhs.axes.len != 1 or rhs.axes.len != 1 or output.axes.len != 2) return null;
    const m = lhs.axes[0].extent;
    const n = rhs.axes[0].extent;
    if (!std.mem.eql(u8, lhs.axes[0].name, output.axes[0].name)) return null;
    if (!std.mem.eql(u8, rhs.axes[0].name, output.axes[1].name)) return null;
    if (output.axes[0].extent != m or output.axes[1].extent != n) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0 or launch.threadgroup[1] == 0) return null;
    return .{
        .m = m,
        .n = n,
        .threads = .{ .x = launch.threadgroup[0], .y = launch.threadgroup[1] },
        .lhs_axis = lhs.axes[0].name,
        .rhs_axis = rhs.axes[0].name,
    };
}

fn batchedMatrixProductProgram(comptime spec: BatchedMatrixProduct) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try batchedMatrixProductBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_linalg_batched_matmul{}x{}x{}x{}_{}x{}x{}_f32",
            .{ spec.batch, spec.m, spec.n, spec.k, spec.threads.x, spec.threads.y, spec.threads.z },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .lhs = kernel.dynamicBuffer(.f32),
            .rhs = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
        .z = spec.threads.z,
    }));
}

fn matrixProductProgram(comptime spec: MatrixProduct) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try matrixProductBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_linalg_matmul{}x{}x{}_{}x{}_{s}",
            .{ spec.m, spec.n, spec.k, spec.threads.x, spec.threads.y, spec.dtype.name() },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .lhs = kernel.dynamicBuffer(spec.dtype),
            .rhs = kernel.dynamicBuffer(spec.dtype),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

fn matrixVectorProductProgram(comptime spec: MatrixVectorProduct) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try matrixVectorProductBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_linalg_matvec{}x{}_{}x_f32",
            .{ spec.m, spec.k, spec.threads },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .matrix = kernel.dynamicBuffer(.f32),
            .vector = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

fn outerProductProgram(comptime spec: OuterProduct) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try outerProductBody(k, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_linalg_outer{}x{}_{}x{}_f32",
            .{ spec.m, spec.n, spec.threads.x, spec.threads.y },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .lhs = kernel.dynamicBuffer(.f32),
            .rhs = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

pub fn batchedMatrixProductF32(comptime spec: BatchedMatrixProduct) type {
    return entry.Entry(batchedMatrixProductProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.linalg.batched_matmul{}x{}x{}x{}_{}x{}x{}_f32",
            .{ spec.batch, spec.m, spec.n, spec.k, spec.threads.x, spec.threads.y, spec.threads.z },
        ),
        .layer = .logical,
        .category = .linalg,
        .specialization = batchedMatrixProductSpecialization(spec),
    });
}

pub fn matrixProductF32(comptime spec: MatrixProduct) type {
    return entry.Entry(matrixProductProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.linalg.matmul{}x{}x{}_{}x{}_{s}",
            .{ spec.m, spec.n, spec.k, spec.threads.x, spec.threads.y, spec.dtype.name() },
        ),
        .layer = .logical,
        .category = .linalg,
        .specialization = matrixProductSpecialization(spec),
    });
}

pub fn matrixVectorProductF32(comptime spec: MatrixVectorProduct) type {
    return entry.Entry(matrixVectorProductProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.linalg.matvec{}x{}_{}x_f32",
            .{ spec.m, spec.k, spec.threads },
        ),
        .layer = .logical,
        .category = .linalg,
        .specialization = matrixVectorProductSpecialization(spec),
    });
}

pub fn outerProductF32(comptime spec: OuterProduct) type {
    return entry.Entry(outerProductProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.linalg.outer{}x{}_{}x{}_f32",
            .{ spec.m, spec.n, spec.threads.x, spec.threads.y },
        ),
        .layer = .logical,
        .category = .linalg,
        .specialization = outerProductSpecialization(spec),
    });
}

pub const BatchedMatrixProduct2x2x3x4F32 = batchedMatrixProductF32(.{
    .batch = 2,
    .m = 2,
    .n = 3,
    .k = 4,
    .threads = .{ .x = 3, .y = 2, .z = 2 },
});

pub const MatrixProduct2x3x4F32 = matrixProductF32(.{
    .m = 2,
    .n = 3,
    .k = 4,
    .threads = .{ .x = 2, .y = 2 },
});

pub const MatrixProduct4x16x8F32 = matrixProductF32(.{
    .m = 4,
    .n = 16,
    .k = 8,
    .threads = .{ .x = 8, .y = 4 },
});

pub const MatrixProduct4x16x8ThreadBlocks4x2F32 = matrixProductF32(.{
    .m = 4,
    .n = 16,
    .k = 8,
    .threads = .{ .x = 4, .y = 2 },
});

pub const MatrixProduct8x12x16F32 = matrixProductF32(.{
    .m = 8,
    .n = 12,
    .k = 16,
    .threads = .{ .x = 4, .y = 4 },
});

pub const MatrixVectorProduct4x8F32 = matrixVectorProductF32(.{
    .m = 4,
    .k = 8,
    .threads = 4,
});

pub const OuterProduct4x3F32 = outerProductF32(.{
    .m = 4,
    .n = 3,
    .threads = .{ .x = 3, .y = 2 },
});

test "linalg batched matrix product entry runs on CPU and records schedule" {
    var lhs = [_]f32{
        1.0, 2.0, 3.0,  4.0,
        5.0, 6.0, 7.0,  8.0,
        2.0, 0.0, -2.0, 1.0,
        1.0, 3.0, 5.0,  7.0,
    };
    var rhs = [_]f32{
        1.0,  0.0,  2.0,
        0.0,  1.0,  3.0,
        1.0,  1.0,  0.0,
        2.0,  0.0,  1.0,
        -1.0, 2.0,  0.0,
        3.0,  1.0,  -2.0,
        0.0,  4.0,  1.0,
        2.0,  -1.0, 3.0,
    };
    var dst = @as([12]f32, @splat(0.0));

    try BatchedMatrixProduct2x2x3x4F32.runCpu(std.testing.allocator, BatchedMatrixProduct2x2x3x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 12.0, 5.0, 12.0, 28.0, 13.0, 36.0, 0.0, -5.0, 1.0, 22.0, 18.0, 20.0 }, dst[0..]);

    const launch_value = try BatchedMatrixProduct2x2x3x4F32.launch(std.testing.allocator, BatchedMatrixProduct2x2x3x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[2]);
    try std.testing.expectEqual(@as(u32, 3), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[2]);
}

test "linalg batched matrix product entry carries einsum specialization metadata" {
    const BatchedMatrixProduct3x2x4x5F32 = batchedMatrixProductF32(.{
        .batch = 3,
        .m = 2,
        .n = 4,
        .k = 5,
        .threads = .{ .x = 2, .y = 2, .z = 1 },
    });

    try std.testing.expect(BatchedMatrixProduct3x2x4x5F32.specialization.operationIs(.{ .linalg = .batched_matrix_product }));
    try std.testing.expectEqualStrings("bmk,bkn->bmn", BatchedMatrixProduct3x2x4x5F32.specialization.equation.?);
    try std.testing.expectEqualStrings("accy.kernel.linalg.batched_matmul3x2x4x5_2x2x1_f32", BatchedMatrixProduct3x2x4x5F32.target);
    try std.testing.expectEqual(@as(usize, 2), BatchedMatrixProduct3x2x4x5F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 30), BatchedMatrixProduct3x2x4x5F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 60), BatchedMatrixProduct3x2x4x5F32.specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 24), BatchedMatrixProduct3x2x4x5F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings("dot", BatchedMatrixProduct3x2x4x5F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.dot_product, BatchedMatrixProduct3x2x4x5F32.specialization.reductions[0].operator);
    try std.testing.expectEqual(@as(u64, 5), BatchedMatrixProduct3x2x4x5F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expectEqual(@as(u32, 2), BatchedMatrixProduct3x2x4x5F32.specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), BatchedMatrixProduct3x2x4x5F32.specialization.launch.?.grid[1]);
    try std.testing.expectEqual(@as(u32, 3), BatchedMatrixProduct3x2x4x5F32.specialization.launch.?.grid[2]);
    try std.testing.expectEqualDeep(BatchedMatrixProduct3x2x4x5F32.specialization.launch.?, BatchedMatrixProduct3x2x4x5F32.specialization.schedule.?.launch());
    try std.testing.expectEqual(@as(usize, 5), BatchedMatrixProduct3x2x4x5F32.specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("n_tile", BatchedMatrixProduct3x2x4x5F32.specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, BatchedMatrixProduct3x2x4x5F32.specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("b_lane", BatchedMatrixProduct3x2x4x5F32.specialization.schedule.?.bindings[4].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_z, BatchedMatrixProduct3x2x4x5F32.specialization.schedule.?.bindings[4].target);

    var snapshot = try BatchedMatrixProduct3x2x4x5F32.scheduleSnapshot(std.testing.allocator, BatchedMatrixProduct3x2x4x5F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(BatchedMatrixProduct3x2x4x5F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "linalg batched matrix product entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try BatchedMatrixProduct2x2x3x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = BatchedMatrixProduct2x2x3x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(BatchedMatrixProduct2x2x3x4F32.target, BatchedMatrixProduct2x2x3x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(BatchedMatrixProduct2x2x3x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(BatchedMatrixProduct2x2x3x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(BatchedMatrixProduct2x2x3x4F32.specialization.launch.?.grid[2], geometry.grid[2]);
            try std.testing.expectEqual(BatchedMatrixProduct2x2x3x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(BatchedMatrixProduct2x2x3x4F32.specialization.launch.?.threadgroup[2], geometry.threadgroup[2]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "linalg batched matrix product family matches the fixed entry at its extents" {
    const instance = BatchedMatrixProduct{
        .batch = 2,
        .m = 2,
        .n = 3,
        .k = 4,
        .threads = .{ .x = 3, .y = 2, .z = 2 },
    };

    const family_launch = try BatchedMatrixProductFamilyF32.launch(std.testing.allocator, BatchedMatrixProductFamilyF32.Limits.testing, instance);
    const fixed_launch = try BatchedMatrixProduct2x2x3x4F32.launch(std.testing.allocator, BatchedMatrixProduct2x2x3x4F32.Limits.testing);
    try std.testing.expectEqualDeep(fixed_launch, family_launch);

    var family_snapshot = try BatchedMatrixProductFamilyF32.scheduleSnapshot(std.testing.allocator, BatchedMatrixProductFamilyF32.Limits.testing, instance);
    defer family_snapshot.deinit(std.testing.allocator);
    var fixed_snapshot = try BatchedMatrixProduct2x2x3x4F32.scheduleSnapshot(std.testing.allocator, BatchedMatrixProduct2x2x3x4F32.Limits.testing);
    defer fixed_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(fixed_snapshot.fingerprint(), family_snapshot.fingerprint());

    var lhs = [_]f32{
        1.0, 2.0, 3.0,  4.0,
        5.0, 6.0, 7.0,  8.0,
        2.0, 0.0, -2.0, 1.0,
        1.0, 3.0, 5.0,  7.0,
    };
    var rhs = [_]f32{
        1.0,  0.0,  2.0,
        0.0,  1.0,  3.0,
        1.0,  1.0,  0.0,
        2.0,  0.0,  1.0,
        -1.0, 2.0,  0.0,
        3.0,  1.0,  -2.0,
        0.0,  4.0,  1.0,
        2.0,  -1.0, 3.0,
    };
    var family_dst = @as([12]f32, @splat(0.0));
    var fixed_dst = @as([12]f32, @splat(0.0));

    try BatchedMatrixProductFamilyF32.runCpu(std.testing.allocator, BatchedMatrixProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, family_dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try BatchedMatrixProduct2x2x3x4F32.runCpu(std.testing.allocator, BatchedMatrixProduct2x2x3x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, fixed_dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, fixed_dst[0..], family_dst[0..]);
}

test "linalg batched matrix product family executes fresh runtime extents" {
    const instance = BatchedMatrixProduct{
        .batch = 3,
        .m = 5,
        .n = 6,
        .k = 4,
        .threads = .{ .x = 4, .y = 2, .z = 2 },
    };

    var lhs: [3 * 5 * 4]f32 = undefined;
    for (&lhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 11)) * 0.25 - 1.0;
    var rhs: [3 * 4 * 6]f32 = undefined;
    for (&rhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 13)) * 0.125 - 0.5;

    var expected: [3 * 5 * 6]f32 = undefined;
    for (0..3) |batch| {
        for (0..5) |row| {
            for (0..6) |col| {
                var sum: f32 = 0.0;
                for (0..4) |offset| {
                    const lhs_index = batch * 5 * 4 + row * 4 + offset;
                    const rhs_index = batch * 4 * 6 + offset * 6 + col;
                    sum += lhs[lhs_index] * rhs[rhs_index];
                }
                expected[batch * 5 * 6 + row * 6 + col] = sum;
            }
        }
    }

    var dst = @as([(3 * 5 * 6)]f32, @splat(0.0));
    try BatchedMatrixProductFamilyF32.runCpu(std.testing.allocator, BatchedMatrixProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);

    const launch_value = try BatchedMatrixProductFamilyF32.launch(std.testing.allocator, BatchedMatrixProductFamilyF32.Limits.testing, instance);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[2]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[2]);
}

test "linalg batched matrix product family identity and metadata" {
    const instance = BatchedMatrixProduct{
        .batch = 3,
        .m = 5,
        .n = 6,
        .k = 4,
        .threads = .{ .x = 4, .y = 2, .z = 2 },
        .batch_axis = "batches",
        .row_axis = "rows",
        .col_axis = "cols",
        .reduction_axis = "depth",
    };
    var owned = try batchedMatrixProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const specialization = owned.value;

    const fixed_target = try batchedMatrixProductInstanceTarget(std.testing.allocator, .{
        .batch = 2,
        .m = 2,
        .n = 3,
        .k = 4,
        .threads = .{ .x = 3, .y = 2, .z = 2 },
    });
    defer std.testing.allocator.free(fixed_target);
    try std.testing.expectEqualStrings(BatchedMatrixProduct2x2x3x4F32.target, fixed_target);

    const fixed_entry = try batchedMatrixProductInstanceEntryName(std.testing.allocator, .{
        .batch = 2,
        .m = 2,
        .n = 3,
        .k = 4,
        .threads = .{ .x = 3, .y = 2, .z = 2 },
    });
    defer std.testing.allocator.free(fixed_entry);
    try std.testing.expectEqualStrings(BatchedMatrixProduct2x2x3x4F32.name, fixed_entry);

    const family_target = try batchedMatrixProductFamilyTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.batched_matmul_family_4x2x2_f32", family_target);

    const family_entry = try batchedMatrixProductFamilyEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_entry);
    try std.testing.expectEqualStrings("accy_kernel_linalg_batched_matmul_family_4x2x2_f32", family_entry);
    try std.testing.expectEqual(BatchedMatrixProduct2x2x3x4F32.version, batched_matrix_product_family_version);

    try std.testing.expect(specialization.operationIs(.{ .linalg = .batched_matrix_product }));
    try std.testing.expectEqualStrings("bmk,bkn->bmn", specialization.equation.?);
    try std.testing.expectEqual(@as(usize, 2), specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 60), specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 72), specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 90), specialization.outputs[0].elementCount().?);
    try std.testing.expect(specialization.reductionMatches(0, .{ .name = "dot", .operator = .dot_product, .extents = &.{4} }));
    try std.testing.expectEqualStrings("batches", specialization.inputs[0].axes[0].name);
    try std.testing.expectEqualStrings("rows", specialization.inputs[0].axes[1].name);
    try std.testing.expectEqualStrings("depth", specialization.inputs[0].axes[2].name);
    try std.testing.expectEqualStrings("cols", specialization.inputs[1].axes[2].name);
    try std.testing.expect(specialization.scheduleMatchesLaunch());
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.grid[1]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.grid[2]);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[2]);
    try std.testing.expectEqual(@as(usize, 6), specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("cols_tile", specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("batches_lane", specialization.schedule.?.bindings[5].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_z, specialization.schedule.?.bindings[5].target);
    try std.testing.expect(specialization.shape_family != null);
    try std.testing.expectEqual(try batchedMatrixProductFamilyFingerprint(std.testing.allocator, instance), specialization.shapeFamilyFingerprint().?);
}

test "linalg batched matrix product reconstructs family instance from specialization" {
    const instance = BatchedMatrixProduct{
        .batch = 3,
        .m = 5,
        .n = 6,
        .k = 4,
        .threads = .{ .x = 4, .y = 2, .z = 2 },
        .batch_axis = "batches",
        .row_axis = "rows",
        .col_axis = "cols",
        .reduction_axis = "depth",
    };
    var owned = try batchedMatrixProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const reconstructed = batchedMatrixProductInstanceFromSpecialization(owned.value) orelse return error.TestExpectedBatchedMatrixProductInstance;

    try std.testing.expectEqual(instance.batch, reconstructed.batch);
    try std.testing.expectEqual(instance.m, reconstructed.m);
    try std.testing.expectEqual(instance.n, reconstructed.n);
    try std.testing.expectEqual(instance.k, reconstructed.k);
    try std.testing.expectEqual(instance.threads.x, reconstructed.threads.x);
    try std.testing.expectEqual(instance.threads.y, reconstructed.threads.y);
    try std.testing.expectEqual(instance.threads.z, reconstructed.threads.z);
    try std.testing.expectEqualStrings(instance.batch_axis, reconstructed.batch_axis);
    try std.testing.expectEqualStrings(instance.row_axis, reconstructed.row_axis);
    try std.testing.expectEqualStrings(instance.col_axis, reconstructed.col_axis);
    try std.testing.expectEqualStrings(instance.reduction_axis, reconstructed.reduction_axis);
}

test "linalg batched matrix product runtime family executes explicit runtime extents" {
    const allocator = std.testing.allocator;
    const compiled = BatchedMatrixProduct{
        .batch = 1,
        .m = 1,
        .n = 1,
        .k = 1,
        .threads = .{ .x = 4, .y = 2, .z = 2 },
    };
    const runtime = BatchedMatrixProduct{
        .batch = 2,
        .m = 3,
        .n = 4,
        .k = 5,
        .threads = compiled.threads,
    };

    var graph = try BatchedMatrixProductRuntimeFamilyF32.build(allocator, BatchedMatrixProductRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var lhs: [2 * 3 * 5]f32 = undefined;
    for (&lhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 9)) * 0.5 - 1.0;
    var rhs: [2 * 5 * 4]f32 = undefined;
    for (&rhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 7)) * 0.25 - 0.5;

    var expected: [2 * 3 * 4]f32 = undefined;
    for (0..2) |batch| {
        for (0..3) |row| {
            for (0..4) |col| {
                var sum: f32 = 0.0;
                for (0..5) |offset| {
                    const lhs_index = batch * 3 * 5 + row * 5 + offset;
                    const rhs_index = batch * 5 * 4 + offset * 4 + col;
                    sum += lhs[lhs_index] * rhs[rhs_index];
                }
                expected[batch * 3 * 4 + row * 4 + col] = sum;
            }
        }
    }

    var dst = @as([(2 * 3 * 4)]f32, @splat(0.0));
    const launch_value = try entry.runtimeLaunch3D(runtime.n, runtime.m, runtime.batch, runtime.threads.x, runtime.threads.y, runtime.threads.z);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentI32(@intCast(runtime.batch)),
        kernel.argumentI32(@intCast(runtime.m)),
        kernel.argumentI32(@intCast(runtime.n)),
        kernel.argumentI32(@intCast(runtime.k)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "linalg batched matrix product family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = BatchedMatrixProduct{
        .batch = 3,
        .m = 5,
        .n = 6,
        .k = 4,
        .threads = .{ .x = 4, .y = 2, .z = 2 },
    };

    var family_artifact = try createBatchedMatrixProductFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    var fixed_artifact = try BatchedMatrixProduct2x2x3x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = BatchedMatrixProduct2x2x3x4F32.Limits.testing });
    defer fixed_artifact.deinit();

    const family_entry = family_artifact.entry();
    const fixed_entry = fixed_artifact.entry();
    try std.testing.expect(!std.mem.eql(u8, fixed_entry.target, family_entry.target));
    try std.testing.expectEqualStrings("accy.kernel.linalg.batched_matmul_family_4x2x2_f32", family_entry.target);
    try std.testing.expectEqualStrings("accy_kernel_linalg_batched_matmul_family_4x2x2_f32", family_entry.entry_name);
    try std.testing.expectEqual(@as(u32, 7), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 4), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.f32));
    try std.testing.expect(family_entry.required_dtypes.contains(.i32));
    try std.testing.expect(fixed_entry.shape_family_fingerprint == null);
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("batched_matrix_product", profile.name);
    try std.testing.expectEqual(family_entry.shape_family_fingerprint.?, profile.fingerprint);
    try std.testing.expectEqual(@as(usize, 4), profile.dimensions.len);
    const batch_dimension = profile.runtimeScalarDimension(0) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("b", batch_dimension.name);
    const m_dimension = profile.runtimeScalarDimension(1) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("m", m_dimension.name);
    const n_dimension = profile.runtimeScalarDimension(2) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("n", n_dimension.name);
    const k_dimension = profile.runtimeScalarDimension(3) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("k", k_dimension.name);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[1]);
            try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[2]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 2), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 4), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            switch (launch.grid[1]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 1), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 2), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            switch (launch.grid[2]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 0), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 2), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            const args = try batchedMatrixProductRuntimeArguments(instance);
            const geometry = try launch.geometry(args[0..]);
            try std.testing.expectEqual(@as(u32, 2), geometry.grid[0]);
            try std.testing.expectEqual(@as(u32, 3), geometry.grid[1]);
            try std.testing.expectEqual(@as(u32, 2), geometry.grid[2]);
            try std.testing.expectEqual(@as(u32, 4), geometry.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 2), geometry.threadgroup[1]);
            try std.testing.expectEqual(@as(u32, 2), geometry.threadgroup[2]);
        },
        .fixed => return error.TestExpectedDerivedLaunch,
    }
}

test "linalg matrix product entry runs on CPU and records schedule" {
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
    var dst = @as([6]f32, @splat(0.0));

    try MatrixProduct2x3x4F32.runCpu(std.testing.allocator, MatrixProduct2x3x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 12.0, 5.0, 12.0, 28.0, 13.0, 36.0 }, dst[0..]);

    const launch_value = try MatrixProduct2x3x4F32.launch(std.testing.allocator, MatrixProduct2x3x4F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "linalg matrix product family matches the fixed entry at its extents" {
    const instance = MatrixProduct{ .m = 2, .n = 3, .k = 4, .threads = .{ .x = 2, .y = 2 } };

    const family_launch = try MatrixProductFamilyF32.launch(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance);
    const fixed_launch = try MatrixProduct2x3x4F32.launch(std.testing.allocator, MatrixProduct2x3x4F32.Limits.testing);
    try std.testing.expectEqualDeep(fixed_launch, family_launch);

    var family_snapshot = try MatrixProductFamilyF32.scheduleSnapshot(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance);
    defer family_snapshot.deinit(std.testing.allocator);
    var fixed_snapshot = try MatrixProduct2x3x4F32.scheduleSnapshot(std.testing.allocator, MatrixProduct2x3x4F32.Limits.testing);
    defer fixed_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(fixed_snapshot.fingerprint(), family_snapshot.fingerprint());

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
    var family_dst = @as([6]f32, @splat(0.0));
    var fixed_dst = @as([6]f32, @splat(0.0));

    try MatrixProductFamilyF32.runCpu(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, family_dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try MatrixProduct2x3x4F32.runCpu(std.testing.allocator, MatrixProduct2x3x4F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, fixed_dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, fixed_dst[0..], family_dst[0..]);
}

fn expectApproxF16Slices(expected: []const f16, actual: []const f16) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(
            @as(f32, @floatCast(expected_value)),
            @as(f32, @floatCast(actual_value)),
            0.001,
        );
    }
}

test "linalg matrix product f16 family accumulates in f32" {
    const instance = MatrixProduct{
        .m = 2,
        .n = 3,
        .k = 4,
        .dtype = .f16,
        .accumulation_dtype = .f32,
        .threads = .{ .x = 2, .y = 2 },
    };

    var lhs = [_]f16{
        0.5, -1.0, 2.25, 0.125,
        3.0, -0.5, 1.5,  -2.0,
    };
    var rhs = [_]f16{
        1.0,  -0.5, 2.0,
        0.25, 1.5,  -1.0,
        -2.0, 0.75, 0.5,
        3.0,  -4.0, 0.25,
    };
    var expected: [6]f16 = undefined;
    for (0..2) |row| {
        for (0..3) |col| {
            var sum: f32 = 0.0;
            for (0..4) |offset| {
                sum += @as(f32, @floatCast(lhs[row * 4 + offset])) * @as(f32, @floatCast(rhs[offset * 3 + col]));
            }
            expected[row * 3 + col] = @floatCast(sum);
        }
    }

    var dst = @as([6]f16, @splat(0.0));
    try MatrixProductFamilyF16.runCpu(std.testing.allocator, MatrixProductFamilyF16.Limits.testing, instance, &.{
        kernel.argumentBuffer(f16, dst[0..]),
        kernel.argumentBuffer(f16, lhs[0..]),
        kernel.argumentBuffer(f16, rhs[0..]),
    });
    try expectApproxF16Slices(expected[0..], dst[0..]);

    var owned = try matrixProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    try std.testing.expectEqual(@as(?DType, .f16), owned.value.dtype);
    try std.testing.expectEqual(@as(?DType, .f32), owned.value.accumulation_dtype);

    var plan = try MatrixProductFamilyF16.createCheckedPlan(std.testing.allocator, MatrixProductFamilyF16.Limits.testing, instance, .{});
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 3), plan.argument_count);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_f16", plan.entry_name);
}

fn matrixProductOccupancy(m: u64, n: u64, threads: entry.Threads2D) f64 {
    const grid_x = (n + threads.x - 1) / threads.x;
    const grid_y = (m + threads.y - 1) / threads.y;
    const launched = grid_x * grid_y * threads.x * threads.y;
    return @as(f64, @floatFromInt(m * n)) / @as(f64, @floatFromInt(launched));
}

test "linalg matrix product thread heuristic keeps occupancy high" {
    const skinny = matrixProductThreadsForExtents(1, 1000);
    try std.testing.expectEqual(@as(u32, 1), skinny.y);
    try std.testing.expectEqual(@as(u32, 64), skinny.x);
    try std.testing.expect(matrixProductOccupancy(1, 1000, skinny) >= 0.9);
    try std.testing.expect(matrixProductOccupancy(1, 1000, .{ .x = 16, .y = 16 }) < 0.07);

    const tall = matrixProductThreadsForExtents(1000, 2);
    try std.testing.expectEqual(@as(u32, 16), tall.y);
    try std.testing.expectEqual(@as(u32, 2), tall.x);
    try std.testing.expect(matrixProductOccupancy(1000, 2, tall) >= 0.9);

    const tiny = matrixProductThreadsForExtents(5, 7);
    try std.testing.expectEqual(@as(u32, 5), tiny.y);
    try std.testing.expectEqual(@as(u32, 7), tiny.x);
    try std.testing.expect(matrixProductOccupancy(5, 7, tiny) == 1.0);

    const dense = matrixProductThreadsForExtents(1024, 1024);
    try std.testing.expectEqual(@as(u32, 16), dense.y);
    try std.testing.expectEqual(@as(u32, 16), dense.x);
    try std.testing.expect(matrixProductOccupancy(1024, 1024, dense) == 1.0);

    const just_over_square = matrixProductThreadsForExtents(17, 17);
    try std.testing.expectEqual(@as(u32, 9), just_over_square.y);
    try std.testing.expectEqual(@as(u32, 17), just_over_square.x);
    try std.testing.expect(matrixProductOccupancy(17, 17, just_over_square) >= 0.9);

    const just_over_rect = matrixProductThreadsForExtents(17, 9);
    try std.testing.expectEqual(@as(u32, 9), just_over_rect.y);
    try std.testing.expectEqual(@as(u32, 9), just_over_rect.x);
    try std.testing.expect(matrixProductOccupancy(17, 9, just_over_rect) >= 0.9);

    const larger_square = matrixProductThreadsForExtents(33, 33);
    try std.testing.expectEqual(@as(u32, 7), larger_square.y);
    try std.testing.expectEqual(@as(u32, 33), larger_square.x);
    try std.testing.expect(matrixProductOccupancy(33, 33, larger_square) >= 0.9);

    const larger_rect = matrixProductThreadsForExtents(33, 17);
    try std.testing.expectEqual(@as(u32, 11), larger_rect.y);
    try std.testing.expectEqual(@as(u32, 17), larger_rect.x);
    try std.testing.expect(matrixProductOccupancy(33, 17, larger_rect) == 1.0);
}

fn expectMatrixProductThreadCandidatesLegal(
    candidates: geometry_mod.ThreadCandidates,
    m: u64,
    n: u64,
) !void {
    try std.testing.expect(candidates.count != 0);
    for (candidates.slice(), 0..) |candidate, index| {
        try std.testing.expect(candidate.x != 0);
        try std.testing.expect(candidate.y != 0);
        try std.testing.expect(candidate.x <= @min(@max(n, 1), matrix_product_thread_caps.x_max));
        try std.testing.expect(candidate.y <= @min(@max(m, 1), matrix_product_thread_caps.y_max));
        try std.testing.expect(candidate.x * candidate.y <= matrix_product_thread_caps.budget);
        for (candidates.slice()[0..index]) |previous| {
            try std.testing.expect(!geometry_mod.threadCandidatesEqual(previous, candidate));
        }
    }
}

fn expectMatrixProductThreadCandidatesContain(
    candidates: geometry_mod.ThreadCandidates,
    expected: entry.Threads2D,
) !void {
    for (candidates.slice()) |candidate| {
        if (geometry_mod.threadCandidatesEqual(candidate, expected)) return;
    }
    return error.TestExpectedMatrixProductThreadCandidate;
}

test "linalg matrix product thread candidates expose stable family variants" {
    const near_square = matrixProductThreadCandidatesForExtents(17, 17);
    try expectMatrixProductThreadCandidatesLegal(near_square, 17, 17);
    try std.testing.expect(near_square.count > 2);
    try std.testing.expectEqual(@as(u32, 17), near_square.items[0].x);
    try std.testing.expectEqual(@as(u32, 9), near_square.items[0].y);
    try expectMatrixProductThreadCandidatesContain(near_square, .{ .x = 16, .y = 16 });

    const skinny = matrixProductThreadCandidatesForExtents(1, 1000);
    try expectMatrixProductThreadCandidatesLegal(skinny, 1, 1000);
    try std.testing.expect(skinny.count > 1);
    try std.testing.expectEqual(@as(u32, 64), skinny.items[0].x);
    try std.testing.expectEqual(@as(u32, 1), skinny.items[0].y);

    const first = MatrixProduct{ .m = 17, .n = 17, .k = 13, .threads = near_square.items[0] };
    const second = MatrixProduct{ .m = 17, .n = 17, .k = 13, .threads = near_square.items[1] };
    const first_target = try matrixProductFamilyTarget(std.testing.allocator, first);
    defer std.testing.allocator.free(first_target);
    const second_target = try matrixProductFamilyTarget(std.testing.allocator, second);
    defer std.testing.allocator.free(second_target);
    try std.testing.expect(!std.mem.eql(u8, first_target, second_target));
}

test "linalg matrix product family instance identity matches fixed entry strings" {
    const instance = MatrixProduct{ .m = 2, .n = 3, .k = 4, .threads = .{ .x = 2, .y = 2 } };

    const target = try matrixProductInstanceTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(MatrixProduct2x3x4F32.target, target);

    const entry_name = try matrixProductInstanceEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(entry_name);
    try std.testing.expectEqualStrings(MatrixProduct2x3x4F32.name, entry_name);

    try std.testing.expectEqual(MatrixProduct2x3x4F32.version, matrix_product_family_version);

    const fresh = MatrixProduct{ .m = 5, .n = 7, .k = 3, .threads = .{ .x = 4, .y = 2 } };
    const fresh_target = try matrixProductInstanceTarget(std.testing.allocator, fresh);
    defer std.testing.allocator.free(fresh_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul5x7x3_4x2_f32", fresh_target);

    const family_target = try matrixProductFamilyTarget(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul_family_4x2_f32", family_target);

    const family_entry = try matrixProductFamilyEntryName(std.testing.allocator, fresh);
    defer std.testing.allocator.free(family_entry);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_family_4x2_f32", family_entry);

    const fresh_f16 = MatrixProduct{ .m = 5, .n = 7, .k = 3, .dtype = .f16, .threads = .{ .x = 4, .y = 2 } };
    const fresh_f16_target = try matrixProductInstanceTarget(std.testing.allocator, fresh_f16);
    defer std.testing.allocator.free(fresh_f16_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul5x7x3_4x2_f16", fresh_f16_target);

    const family_f16_target = try matrixProductFamilyTarget(std.testing.allocator, fresh_f16);
    defer std.testing.allocator.free(family_f16_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul_family_4x2_f16", family_f16_target);
}

fn linalgFamilyTuningTestCapabilities() gpu.BackendCapabilities {
    return .{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "linalg-family-tuning-test-device",
        .vendor_id = 0x10de,
        .device_id = 0x2684,
    } };
}

test "linalg matrix product family tuning keys discriminate dtype and device" {
    const allocator = std.testing.allocator;
    const caps = linalgFamilyTuningTestCapabilities();
    const device = tuning.deviceFingerprint(caps);

    const single = try matrixProductFamilyTuningKey(allocator, device, .{
        .m = 64,
        .n = 64,
        .k = 32,
        .dtype = .f32,
    });
    const half = try matrixProductFamilyTuningKey(allocator, device, .{
        .m = 64,
        .n = 64,
        .k = 32,
        .dtype = .f16,
        .accumulation_dtype = .f32,
    });
    try std.testing.expect(!single.eql(half));
    try std.testing.expect(single.family_fingerprint == half.family_fingerprint);
    try std.testing.expect(single.operation_fingerprint == half.operation_fingerprint);

    const other_device = try matrixProductFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(.{ .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .name = "other-linalg-family-tuning-test-device",
            .vendor_id = 0x10de,
            .device_id = 0x1b80,
        } }),
        .{ .m = 64, .n = 64, .k = 32 },
    );
    try std.testing.expect(!other_device.eql(single));
    try std.testing.expectEqual(single.family_fingerprint, other_device.family_fingerprint);
    try std.testing.expectEqual(single.operation_fingerprint, other_device.operation_fingerprint);
}

test "linalg matrix product family tuning resolves schedules" {
    const allocator = std.testing.allocator;
    const caps = linalgFamilyTuningTestCapabilities();
    const device = tuning.deviceFingerprint(caps);

    const probe = MatrixProduct{ .m = 64, .n = 64, .k = 32 };
    const candidates = matrixProductThreadCandidatesForExtents(probe.m, probe.n);
    try std.testing.expect(candidates.slice().len >= 2);
    var winner_instance = probe;
    winner_instance.threads = candidates.slice()[candidates.slice().len - 1];
    const winner_target = try matrixProductFamilyTarget(allocator, winner_instance);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = try matrixProductFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    const resolved = (try resolveMatrixProductSchedule(allocator, reader, probe)) orelse
        return error.TestExpectedSchedule;
    try std.testing.expectEqual(winner_instance.threads, resolved);

    const miss = try resolveMatrixProductSchedule(allocator, reader, .{ .m = 32, .n = 32, .k = 32 });
    try std.testing.expectEqual(@as(?entry.Threads2D, null), miss);
}

test "linalg matrix product family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = MatrixProduct{ .m = 2, .n = 3, .k = 4, .threads = .{ .x = 2, .y = 2 } };

    var family_artifact = try createMatrixProductFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    var fixed_artifact = try MatrixProduct2x3x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = MatrixProduct2x3x4F32.Limits.testing });
    defer fixed_artifact.deinit();

    const family_entry = family_artifact.entry();
    const fixed_entry = fixed_artifact.entry();
    try std.testing.expect(!std.mem.eql(u8, fixed_entry.target, family_entry.target));
    try std.testing.expectEqual(fixed_entry.version, family_entry.version);
    try std.testing.expectEqual(fixed_entry.format, family_entry.format);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul_family_2x2_f32", family_entry.target);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_family_2x2_f32", family_entry.entry_name);
    try std.testing.expectEqual(@as(u32, 6), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 3), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.i32));
    try std.testing.expect(fixed_entry.shape_family_fingerprint == null);
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("matrix_product", profile.name);
    try std.testing.expectEqual(family_entry.shape_family_fingerprint.?, profile.fingerprint);
    try std.testing.expectEqual(@as(usize, 3), profile.dimensions.len);
    const m_dimension = profile.runtimeScalarDimension(0) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("m", m_dimension.name);
    try std.testing.expectEqual(@as(?u64, extent_mod.runtime_extent_max), m_dimension.bounds.max);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[1]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 1), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 2), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            switch (launch.grid[1]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 0), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 2), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
        },
        .fixed => return error.TestExpectedDerivedLaunch,
    }
}

test "linalg matrix product family artifact resolves fresh extents in registry" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = MatrixProduct{ .m = 5, .n = 7, .k = 3, .threads = .{ .x = 4, .y = 2 } };

    var call_artifact = try createMatrixProductFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer call_artifact.deinit();

    const sibling = MatrixProduct{ .m = 11, .n = 13, .k = 17, .threads = .{ .x = 4, .y = 2 } };
    const sibling_target = try matrixProductFamilyTarget(allocator, sibling);
    defer allocator.free(sibling_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul_family_4x2_f32", sibling_target);

    const artifact = call_artifact.registry().find(
        "accy.kernel.linalg.matmul_family_4x2_f32",
        matrix_product_family_version,
        .cuda_ptx,
    ) orelse return error.TestExpectedKernelCallArtifact;
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_family_4x2_f32", artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 6), artifact.argument_count);
    try std.testing.expectEqual(@as(u32, 3), artifact.runtime_scalar_argument_count);
    try std.testing.expectEqual(try matrixProductFamilyFingerprint(allocator, instance), artifact.shape_family_fingerprint.?);
    const profile = artifact.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("matrix_product", profile.name);
    try std.testing.expectEqual(artifact.shape_family_fingerprint.?, profile.fingerprint);
    const k_dimension = profile.dimension("k") orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqual(@as(u32, 2), k_dimension.runtime_scalar_argument_index);
    switch (artifact.launch) {
        .derived => |launch| {
            const args = try matrixProductRuntimeArguments(instance);
            const geometry = try launch.geometry(args[0..]);
            try std.testing.expectEqual(@as(u32, 2), geometry.grid[0]);
            try std.testing.expectEqual(@as(u32, 3), geometry.grid[1]);
            try std.testing.expectEqual(@as(u32, 4), geometry.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 2), geometry.threadgroup[1]);
        },
        .fixed => return error.TestExpectedDerivedLaunch,
    }
}

test "linalg matrix product f16 family artifact carries dtype contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = MatrixProduct{
        .m = 5,
        .n = 7,
        .k = 3,
        .dtype = .f16,
        .accumulation_dtype = .f32,
        .threads = .{ .x = 4, .y = 2 },
    };

    var call_artifact = try createMatrixProductFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(
        "accy.kernel.linalg.matmul_family_4x2_f16",
        matrix_product_family_version,
        .cuda_ptx,
    ) orelse return error.TestExpectedKernelCallArtifact;
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_family_4x2_f16", artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 6), artifact.argument_count);
    try std.testing.expect(artifact.required_dtypes.contains(.f16));
    try std.testing.expect(artifact.required_dtypes.contains(.i32));
}

test "linalg matrix product runtime family executes explicit runtime extents" {
    const allocator = std.testing.allocator;
    const compiled = MatrixProduct{ .m = 1, .n = 1, .k = 1, .threads = .{ .x = 4, .y = 2 } };
    const runtime = MatrixProduct{ .m = 3, .n = 4, .k = 2, .threads = compiled.threads };

    var graph = try MatrixProductRuntimeFamilyF32.build(allocator, MatrixProductRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var lhs: [6]f32 = undefined;
    for (&lhs, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    var rhs: [8]f32 = undefined;
    for (&rhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index)) * 0.25 + 1.0;

    var expected: [12]f32 = undefined;
    for (0..3) |row| {
        for (0..4) |col| {
            var sum: f32 = 0.0;
            for (0..2) |offset| {
                sum += lhs[row * 2 + offset] * rhs[offset * 4 + col];
            }
            expected[row * 4 + col] = sum;
        }
    }

    var dst = @as([12]f32, @splat(0.0));
    const launch_value = try entry.runtimeLaunch2D(runtime.n, runtime.m, runtime.threads.x, runtime.threads.y);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentI32(@intCast(runtime.m)),
        kernel.argumentI32(@intCast(runtime.n)),
        kernel.argumentI32(@intCast(runtime.k)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "linalg matrix product family records fixed-entry specialization metadata" {
    const instance = MatrixProduct{ .m = 2, .n = 3, .k = 4, .threads = .{ .x = 2, .y = 2 } };
    var owned = try matrixProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const specialization = owned.value;

    try std.testing.expect(specialization.operationIs(.{ .linalg = .matrix_product }));
    try std.testing.expectEqualStrings(MatrixProduct2x3x4F32.specialization.equation.?, specialization.equation.?);
    try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.dtype, specialization.dtype);
    try std.testing.expectEqual(@as(usize, 2), specialization.inputs.len);
    try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.inputs[0].elementCount().?, specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.inputs[1].elementCount().?, specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.outputs[0].elementCount().?, specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings(MatrixProduct2x3x4F32.specialization.inputs[0].axes[0].name, specialization.inputs[0].axes[0].name);
    try std.testing.expectEqualStrings(MatrixProduct2x3x4F32.specialization.inputs[1].axes[1].name, specialization.inputs[1].axes[1].name);
    try std.testing.expectEqualStrings("dot", specialization.reductions[0].name);
    try std.testing.expect(specialization.reductionMatches(0, .{ .name = "dot", .operator = .dot_product, .extents = &.{4} }));
    try std.testing.expect(specialization.reductionDependenciesAreValid());
    try std.testing.expectEqualDeep(MatrixProduct2x3x4F32.specialization.launch.?, specialization.launch.?);
    try std.testing.expectEqualDeep(MatrixProduct2x3x4F32.specialization.schedule.?.launch(), specialization.schedule.?.launch());
    try std.testing.expect(specialization.shape_family != null);
    try std.testing.expectEqual(try matrixProductFamilyFingerprint(std.testing.allocator, instance), specialization.shapeFamilyFingerprint().?);

    var snapshot = try MatrixProductFamilyF32.scheduleSnapshot(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "linalg matrix product family executes fresh runtime extents" {
    const instance = MatrixProduct{ .m = 5, .n = 7, .k = 3, .threads = .{ .x = 4, .y = 2 } };

    var lhs: [15]f32 = undefined;
    for (&lhs, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    var rhs: [21]f32 = undefined;
    for (&rhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index)) * 0.5 - 2.0;

    var expected: [35]f32 = undefined;
    for (0..5) |row| {
        for (0..7) |col| {
            var sum: f32 = 0.0;
            for (0..3) |offset| {
                sum += lhs[row * 3 + offset] * rhs[offset * 7 + col];
            }
            expected[row * 7 + col] = sum;
        }
    }

    var dst = @as([35]f32, @splat(0.0));
    try MatrixProductFamilyF32.runCpu(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);

    const launch_value = try MatrixProductFamilyF32.launch(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);

    var plan = try MatrixProductFamilyF32.createCheckedPlan(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance, .{});
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 3), plan.argument_count);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_f32", plan.entry_name);
}

test "linalg matrix product family records fresh runtime specialization metadata" {
    const instance = MatrixProduct{
        .m = 5,
        .n = 7,
        .k = 3,
        .threads = .{ .x = 4, .y = 2 },
        .row_axis = "rows",
        .col_axis = "columns",
        .reduction_axis = "depth",
    };
    var owned = try matrixProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const specialization = owned.value;

    try std.testing.expect(specialization.operationIs(.{ .linalg = .matrix_product }));
    try std.testing.expectEqualStrings("mk,kn->mn", specialization.equation.?);
    try std.testing.expectEqual(@as(usize, 2), specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 21), specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 35), specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings("rows", specialization.inputs[0].axes[0].name);
    try std.testing.expectEqualStrings("depth", specialization.inputs[0].axes[1].name);
    try std.testing.expectEqualStrings("columns", specialization.outputs[0].axes[1].name);
    try std.testing.expect(specialization.reductionMatches(0, .{ .name = "dot", .operator = .dot_product, .extents = &.{3} }));
    try std.testing.expectEqual(@as(u64, 210), specialization.estimatedElementOps().?);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
    try std.testing.expect(specialization.scheduleMatchesLaunch());
    try std.testing.expectEqual(@as(usize, 4), specialization.schedule.?.bindings.len);
    try std.testing.expect(specialization.shape_family != null);
    try std.testing.expectEqual(try matrixProductFamilyFingerprint(std.testing.allocator, instance), specialization.shapeFamilyFingerprint().?);
    try std.testing.expectEqualStrings("columns_tile", specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("columns_lane", specialization.schedule.?.bindings[1].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_x, specialization.schedule.?.bindings[1].target);
    try std.testing.expectEqualStrings("rows_tile", specialization.schedule.?.bindings[2].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_y, specialization.schedule.?.bindings[2].target);
    try std.testing.expectEqualStrings("rows_lane", specialization.schedule.?.bindings[3].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_y, specialization.schedule.?.bindings[3].target);

    var snapshot = try MatrixProductFamilyF32.scheduleSnapshot(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "linalg matrix product reconstructs family instance from specialization" {
    const instance = MatrixProduct{
        .m = 5,
        .n = 7,
        .k = 3,
        .threads = .{ .x = 4, .y = 2 },
        .row_axis = "rows",
        .col_axis = "columns",
        .reduction_axis = "depth",
    };
    var owned = try matrixProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const reconstructed = matrixProductInstanceFromSpecialization(owned.value) orelse return error.TestExpectedMatrixProductInstance;

    try std.testing.expectEqual(instance.m, reconstructed.m);
    try std.testing.expectEqual(instance.n, reconstructed.n);
    try std.testing.expectEqual(instance.k, reconstructed.k);
    try std.testing.expectEqual(instance.dtype, reconstructed.dtype);
    try std.testing.expectEqual(instance.accumulation_dtype, reconstructed.accumulation_dtype);
    try std.testing.expectEqual(instance.threads.x, reconstructed.threads.x);
    try std.testing.expectEqual(instance.threads.y, reconstructed.threads.y);
    try std.testing.expectEqualStrings(instance.row_axis, reconstructed.row_axis);
    try std.testing.expectEqualStrings(instance.col_axis, reconstructed.col_axis);
    try std.testing.expectEqualStrings(instance.reduction_axis, reconstructed.reduction_axis);
}

test "linalg matrix product family records untiled runtime launch metadata" {
    const instance = MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    var owned = try matrixProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const specialization = owned.value;
    const launch_value = try MatrixProductFamilyF32.launch(std.testing.allocator, MatrixProductFamilyF32.Limits.testing, instance);

    try std.testing.expectEqual(launch_value.grid[0], specialization.launch.?.grid[0]);
    try std.testing.expectEqual(launch_value.grid[1], specialization.launch.?.grid[1]);
    try std.testing.expectEqual(launch_value.block[0], specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(launch_value.block[1], specialization.launch.?.threadgroup[1]);
    try std.testing.expectEqual(@as(u32, 1), specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), specialization.launch.?.grid[1]);
    try std.testing.expectEqual(@as(u32, 7), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[1]);
    try std.testing.expect(specialization.scheduleMatchesLaunch());
}

test "linalg matrix product family fingerprint names symbolic family not point extents" {
    const first = MatrixProduct{ .m = 5, .n = 7, .k = 3, .threads = .{ .x = 4, .y = 2 } };
    const second = MatrixProduct{ .m = 11, .n = 13, .k = 17, .threads = .{ .x = 8, .y = 4 } };
    const renamed = MatrixProduct{
        .m = 5,
        .n = 7,
        .k = 3,
        .row_axis = "row",
        .col_axis = "col",
        .reduction_axis = "depth",
    };

    try std.testing.expectEqual(
        try matrixProductFamilyFingerprint(std.testing.allocator, first),
        try matrixProductFamilyFingerprint(std.testing.allocator, second),
    );
    try std.testing.expect(
        try matrixProductFamilyFingerprint(std.testing.allocator, first) !=
            try matrixProductFamilyFingerprint(std.testing.allocator, renamed),
    );
}

test "linalg matrix product shape family bounds runtime extents" {
    const instance = MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    var family = try matrixProductShapeFamily(std.testing.allocator, instance);
    defer family.deinit();

    var bound_count: usize = 0;
    const expected_bounds = matrixProductRuntimeExtentBounds();
    for (family.facts) |fact| {
        switch (fact.predicate) {
            .bound => |bound| {
                try std.testing.expectEqual(shape.FactMode.assume, fact.mode);
                try std.testing.expectEqual(expected_bounds.min, bound.bounds.min);
                try std.testing.expectEqual(expected_bounds.opt, bound.bounds.opt);
                try std.testing.expectEqual(expected_bounds.max, bound.bounds.max);
                bound_count += 1;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), bound_count);
}

test "linalg matrix product runtime arguments enforce extent bounds" {
    const largest = MatrixProduct{ .m = extent_mod.runtime_extent_max, .n = 1, .k = 1 };
    const largest_args = try matrixProductRuntimeArguments(largest);
    switch (largest_args[0]) {
        .u32 => |value| try std.testing.expectEqual(@as(u32, @intCast(extent_mod.runtime_extent_max)), value),
        else => return error.TestExpectedRuntimeExtent,
    }

    const zero = MatrixProduct{ .m = 0, .n = 1, .k = 1 };
    try std.testing.expectError(error.ExtentOverflowsIndexRange, matrixProductRuntimeArguments(zero));

    const too_large = MatrixProduct{ .m = extent_mod.runtime_extent_max + 1, .n = 1, .k = 1 };
    try std.testing.expectError(error.ExtentOverflowsIndexRange, matrixProductRuntimeArguments(too_large));
}

test "linalg matrix product entry carries einsum specialization metadata" {
    const MatrixProduct4x5x6F32 = matrixProductF32(.{
        .m = 4,
        .n = 5,
        .k = 6,
        .threads = .{ .x = 4, .y = 2 },
    });

    try std.testing.expect(MatrixProduct4x5x6F32.specialization.operationIs(.{ .linalg = .matrix_product }));
    try std.testing.expectEqualStrings("mk,kn->mn", MatrixProduct4x5x6F32.specialization.equation.?);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul4x5x6_4x2_f32", MatrixProduct4x5x6F32.target);
    try std.testing.expectEqual(@as(usize, 2), MatrixProduct4x5x6F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 24), MatrixProduct4x5x6F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 30), MatrixProduct4x5x6F32.specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 20), MatrixProduct4x5x6F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings("dot", MatrixProduct4x5x6F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.dot_product, MatrixProduct4x5x6F32.specialization.reductions[0].operator);
    try std.testing.expectEqual(@as(u64, 6), MatrixProduct4x5x6F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expectEqual(@as(u32, 2), MatrixProduct4x5x6F32.specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), MatrixProduct4x5x6F32.specialization.launch.?.grid[1]);
    try std.testing.expectEqualDeep(MatrixProduct4x5x6F32.specialization.launch.?, MatrixProduct4x5x6F32.specialization.schedule.?.launch());
    try std.testing.expectEqual(@as(usize, 4), MatrixProduct4x5x6F32.specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("n_tile", MatrixProduct4x5x6F32.specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, MatrixProduct4x5x6F32.specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("m_lane", MatrixProduct4x5x6F32.specialization.schedule.?.bindings[3].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_y, MatrixProduct4x5x6F32.specialization.schedule.?.bindings[3].target);

    var snapshot = try MatrixProduct4x5x6F32.scheduleSnapshot(std.testing.allocator, MatrixProduct4x5x6F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(MatrixProduct4x5x6F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "linalg matrix product entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try MatrixProduct2x3x4F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = MatrixProduct2x3x4F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(MatrixProduct2x3x4F32.target, MatrixProduct2x3x4F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(MatrixProduct2x3x4F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(MatrixProduct2x3x4F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "linalg matrix vector product entry runs on CPU and records schedule" {
    var matrix = [_]f32{
        1.0,  2.0,  3.0,  4.0, 5.0,  6.0, 7.0,  8.0,
        2.0,  0.0,  -2.0, 0.0, 1.0,  0.0, -1.0, 0.0,
        0.5,  1.0,  1.5,  2.0, 2.5,  3.0, 3.5,  4.0,
        -1.0, -2.0, 3.0,  4.0, -5.0, 6.0, 7.0,  -8.0,
    };
    var vector = [_]f32{ 1.0, 0.5, -1.0, 2.0, 0.25, -0.5, 1.5, -2.0 };
    var dst = @as([4]f32, @splat(0.0));

    try MatrixVectorProduct4x8F32.runCpu(std.testing.allocator, MatrixVectorProduct4x8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, matrix[0..]),
        kernel.argumentBuffer(f32, vector[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ -0.25, 2.75, -0.125, 25.25 }, dst[0..]);

    const launch_value = try MatrixVectorProduct4x8F32.launch(std.testing.allocator, MatrixVectorProduct4x8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
}

test "linalg matrix vector product entry carries einsum specialization metadata" {
    const MatrixVectorProduct5x6F32 = matrixVectorProductF32(.{
        .m = 5,
        .k = 6,
        .threads = 4,
    });

    try std.testing.expect(MatrixVectorProduct5x6F32.specialization.operationIs(.{ .linalg = .matrix_vector_product }));
    try std.testing.expectEqualStrings("mk,k->m", MatrixVectorProduct5x6F32.specialization.equation.?);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matvec5x6_4x_f32", MatrixVectorProduct5x6F32.target);
    try std.testing.expectEqual(@as(usize, 2), MatrixVectorProduct5x6F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 30), MatrixVectorProduct5x6F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 6), MatrixVectorProduct5x6F32.specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 5), MatrixVectorProduct5x6F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings("dot", MatrixVectorProduct5x6F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.dot_product, MatrixVectorProduct5x6F32.specialization.reductions[0].operator);
    try std.testing.expectEqual(@as(u64, 6), MatrixVectorProduct5x6F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expectEqual(@as(u32, 2), MatrixVectorProduct5x6F32.specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), MatrixVectorProduct5x6F32.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqualDeep(MatrixVectorProduct5x6F32.specialization.launch.?, MatrixVectorProduct5x6F32.specialization.schedule.?.launch());
    try std.testing.expectEqual(@as(usize, 2), MatrixVectorProduct5x6F32.specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("m_tile", MatrixVectorProduct5x6F32.specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, MatrixVectorProduct5x6F32.specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("m_lane", MatrixVectorProduct5x6F32.specialization.schedule.?.bindings[1].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_x, MatrixVectorProduct5x6F32.specialization.schedule.?.bindings[1].target);

    var snapshot = try MatrixVectorProduct5x6F32.scheduleSnapshot(std.testing.allocator, MatrixVectorProduct5x6F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(MatrixVectorProduct5x6F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "linalg matrix vector product entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try MatrixVectorProduct4x8F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = MatrixVectorProduct4x8F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(MatrixVectorProduct4x8F32.target, MatrixVectorProduct4x8F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(MatrixVectorProduct4x8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(MatrixVectorProduct4x8F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(MatrixVectorProduct4x8F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "linalg matrix vector product family matches the fixed entry at its extents" {
    const instance = MatrixVectorProduct{ .m = 4, .k = 8, .threads = 4 };

    const family_launch = try MatrixVectorProductFamilyF32.launch(std.testing.allocator, MatrixVectorProductFamilyF32.Limits.testing, instance);
    const fixed_launch = try MatrixVectorProduct4x8F32.launch(std.testing.allocator, MatrixVectorProduct4x8F32.Limits.testing);
    try std.testing.expectEqualDeep(fixed_launch, family_launch);

    var family_snapshot = try MatrixVectorProductFamilyF32.scheduleSnapshot(std.testing.allocator, MatrixVectorProductFamilyF32.Limits.testing, instance);
    defer family_snapshot.deinit(std.testing.allocator);
    var fixed_snapshot = try MatrixVectorProduct4x8F32.scheduleSnapshot(std.testing.allocator, MatrixVectorProduct4x8F32.Limits.testing);
    defer fixed_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(fixed_snapshot.fingerprint(), family_snapshot.fingerprint());

    var matrix = [_]f32{
        1.0,  2.0,  3.0,  4.0, 5.0,  6.0, 7.0,  8.0,
        2.0,  0.0,  -2.0, 0.0, 1.0,  0.0, -1.0, 0.0,
        0.5,  1.0,  1.5,  2.0, 2.5,  3.0, 3.5,  4.0,
        -1.0, -2.0, 3.0,  4.0, -5.0, 6.0, 7.0,  -8.0,
    };
    var vector = [_]f32{ 1.0, 0.5, -1.0, 2.0, 0.25, -0.5, 1.5, -2.0 };
    var family_dst = @as([4]f32, @splat(0.0));
    var fixed_dst = @as([4]f32, @splat(0.0));

    try MatrixVectorProductFamilyF32.runCpu(std.testing.allocator, MatrixVectorProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, family_dst[0..]),
        kernel.argumentBuffer(f32, matrix[0..]),
        kernel.argumentBuffer(f32, vector[0..]),
    });
    try MatrixVectorProduct4x8F32.runCpu(std.testing.allocator, MatrixVectorProduct4x8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, fixed_dst[0..]),
        kernel.argumentBuffer(f32, matrix[0..]),
        kernel.argumentBuffer(f32, vector[0..]),
    });
    try std.testing.expectEqualSlices(f32, fixed_dst[0..], family_dst[0..]);
}

test "linalg matrix vector product family executes fresh runtime extents" {
    const instance = MatrixVectorProduct{ .m = 5, .k = 3, .threads = 4 };

    var matrix: [15]f32 = undefined;
    for (&matrix, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index)) * 0.5 - 1.0;
    var vector = [_]f32{ 2.0, -1.0, 0.25 };

    var expected: [5]f32 = undefined;
    for (0..5) |row| {
        var sum: f32 = 0.0;
        for (0..3) |offset| {
            sum += matrix[row * 3 + offset] * vector[offset];
        }
        expected[row] = sum;
    }

    var dst = @as([5]f32, @splat(0.0));
    try MatrixVectorProductFamilyF32.runCpu(std.testing.allocator, MatrixVectorProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, matrix[0..]),
        kernel.argumentBuffer(f32, vector[0..]),
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);

    const launch_value = try MatrixVectorProductFamilyF32.launch(std.testing.allocator, MatrixVectorProductFamilyF32.Limits.testing, instance);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
}

test "linalg matrix vector product family identity and metadata" {
    const instance = MatrixVectorProduct{
        .m = 5,
        .k = 3,
        .threads = 4,
        .row_axis = "rows",
        .reduction_axis = "depth",
    };
    var owned = try matrixVectorProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const specialization = owned.value;

    const fixed_target = try matrixVectorProductInstanceTarget(std.testing.allocator, .{ .m = 4, .k = 8, .threads = 4 });
    defer std.testing.allocator.free(fixed_target);
    try std.testing.expectEqualStrings(MatrixVectorProduct4x8F32.target, fixed_target);

    const fixed_entry = try matrixVectorProductInstanceEntryName(std.testing.allocator, .{ .m = 4, .k = 8, .threads = 4 });
    defer std.testing.allocator.free(fixed_entry);
    try std.testing.expectEqualStrings(MatrixVectorProduct4x8F32.name, fixed_entry);

    const family_target = try matrixVectorProductFamilyTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matvec_family_4x_f32", family_target);

    const family_entry = try matrixVectorProductFamilyEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_entry);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matvec_family_4x_f32", family_entry);
    try std.testing.expectEqual(MatrixVectorProduct4x8F32.version, matrix_vector_product_family_version);

    try std.testing.expect(specialization.operationIs(.{ .linalg = .matrix_vector_product }));
    try std.testing.expectEqualStrings("mk,k->m", specialization.equation.?);
    try std.testing.expectEqual(@as(usize, 2), specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 15), specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 3), specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 5), specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings("rows", specialization.inputs[0].axes[0].name);
    try std.testing.expectEqualStrings("depth", specialization.inputs[0].axes[1].name);
    try std.testing.expect(specialization.reductionMatches(0, .{ .name = "dot", .operator = .dot_product, .extents = &.{3} }));
    try std.testing.expect(specialization.scheduleMatchesLaunch());
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(usize, 2), specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("rows_tile", specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("rows_lane", specialization.schedule.?.bindings[1].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_x, specialization.schedule.?.bindings[1].target);
    try std.testing.expect(specialization.shape_family != null);
    try std.testing.expectEqual(try matrixVectorProductFamilyFingerprint(std.testing.allocator, instance), specialization.shapeFamilyFingerprint().?);
}

test "linalg matrix vector product reconstructs family instance from specialization" {
    const instance = MatrixVectorProduct{
        .m = 5,
        .k = 3,
        .threads = 4,
        .row_axis = "rows",
        .reduction_axis = "depth",
    };
    var owned = try matrixVectorProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const reconstructed = matrixVectorProductInstanceFromSpecialization(owned.value) orelse return error.TestExpectedMatrixVectorProductInstance;

    try std.testing.expectEqual(instance.m, reconstructed.m);
    try std.testing.expectEqual(instance.k, reconstructed.k);
    try std.testing.expectEqual(instance.threads, reconstructed.threads);
    try std.testing.expectEqualStrings(instance.row_axis, reconstructed.row_axis);
    try std.testing.expectEqualStrings(instance.reduction_axis, reconstructed.reduction_axis);
}

test "linalg matrix vector product runtime family executes explicit runtime extents" {
    const allocator = std.testing.allocator;
    const compiled = MatrixVectorProduct{ .m = 1, .k = 1, .threads = 4 };
    const runtime = MatrixVectorProduct{ .m = 3, .k = 4, .threads = compiled.threads };

    var graph = try MatrixVectorProductRuntimeFamilyF32.build(allocator, MatrixVectorProductRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var matrix: [12]f32 = undefined;
    for (&matrix, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index + 1));
    var vector = [_]f32{ 0.5, -1.0, 2.0, 0.25 };

    var expected: [3]f32 = undefined;
    for (0..3) |row| {
        var sum: f32 = 0.0;
        for (0..4) |offset| {
            sum += matrix[row * 4 + offset] * vector[offset];
        }
        expected[row] = sum;
    }

    var dst = @as([3]f32, @splat(0.0));
    const launch_value = try entry.runtimeLaunch1D(runtime.m, runtime.threads);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, matrix[0..]),
        kernel.argumentBuffer(f32, vector[0..]),
        kernel.argumentI32(@intCast(runtime.m)),
        kernel.argumentI32(@intCast(runtime.k)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "linalg matrix vector product family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = MatrixVectorProduct{ .m = 5, .k = 3, .threads = 4 };

    var family_artifact = try createMatrixVectorProductFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    var fixed_artifact = try MatrixVectorProduct4x8F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = MatrixVectorProduct4x8F32.Limits.testing });
    defer fixed_artifact.deinit();

    const family_entry = family_artifact.entry();
    const fixed_entry = fixed_artifact.entry();
    try std.testing.expect(!std.mem.eql(u8, fixed_entry.target, family_entry.target));
    try std.testing.expectEqualStrings("accy.kernel.linalg.matvec_family_4x_f32", family_entry.target);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matvec_family_4x_f32", family_entry.entry_name);
    try std.testing.expectEqual(@as(u32, 5), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 2), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.f32));
    try std.testing.expect(family_entry.required_dtypes.contains(.i32));
    try std.testing.expect(fixed_entry.shape_family_fingerprint == null);
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("matrix_vector_product", profile.name);
    try std.testing.expectEqual(family_entry.shape_family_fingerprint.?, profile.fingerprint);
    try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
    const m_dimension = profile.runtimeScalarDimension(0) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("m", m_dimension.name);
    const k_dimension = profile.runtimeScalarDimension(1) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("k", k_dimension.name);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 0), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 4), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            const args = try matrixVectorProductRuntimeArguments(instance);
            const geometry = try launch.geometry(args[0..]);
            try std.testing.expectEqual(@as(u32, 2), geometry.grid[0]);
            try std.testing.expectEqual(@as(u32, 4), geometry.threadgroup[0]);
        },
        .fixed => return error.TestExpectedDerivedLaunch,
    }
}

test "linalg outer product entry runs on CPU and records schedule" {
    var lhs = [_]f32{ 1.0, -2.0, 0.5, 3.0 };
    var rhs = [_]f32{ 4.0, -1.0, 2.0 };
    var dst = @as([12]f32, @splat(0.0));

    try OuterProduct4x3F32.runCpu(std.testing.allocator, OuterProduct4x3F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 4.0, -1.0, 2.0, -8.0, 2.0, -4.0, 2.0, -0.5, 1.0, 12.0, -3.0, 6.0 }, dst[0..]);

    const launch_value = try OuterProduct4x3F32.launch(std.testing.allocator, OuterProduct4x3F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 3), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "linalg outer product entry carries einsum specialization metadata" {
    const OuterProduct5x6F32 = outerProductF32(.{
        .m = 5,
        .n = 6,
        .threads = .{ .x = 4, .y = 2 },
    });

    try std.testing.expect(OuterProduct5x6F32.specialization.operationIs(.{ .linalg = .outer_product }));
    try std.testing.expectEqualStrings("m,n->mn", OuterProduct5x6F32.specialization.equation.?);
    try std.testing.expectEqualStrings("accy.kernel.linalg.outer5x6_4x2_f32", OuterProduct5x6F32.target);
    try std.testing.expectEqual(@as(usize, 2), OuterProduct5x6F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 5), OuterProduct5x6F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 6), OuterProduct5x6F32.specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 30), OuterProduct5x6F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(usize, 0), OuterProduct5x6F32.specialization.reductions.len);
    try std.testing.expectEqual(@as(u32, 2), OuterProduct5x6F32.specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), OuterProduct5x6F32.specialization.launch.?.grid[1]);
    try std.testing.expectEqualDeep(OuterProduct5x6F32.specialization.launch.?, OuterProduct5x6F32.specialization.schedule.?.launch());
    try std.testing.expectEqual(@as(usize, 4), OuterProduct5x6F32.specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("n_tile", OuterProduct5x6F32.specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, OuterProduct5x6F32.specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("m_lane", OuterProduct5x6F32.specialization.schedule.?.bindings[3].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_y, OuterProduct5x6F32.specialization.schedule.?.bindings[3].target);

    var snapshot = try OuterProduct5x6F32.scheduleSnapshot(std.testing.allocator, OuterProduct5x6F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(OuterProduct5x6F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "linalg outer product entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try OuterProduct4x3F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = OuterProduct4x3F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(OuterProduct4x3F32.target, OuterProduct4x3F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(OuterProduct4x3F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(OuterProduct4x3F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(OuterProduct4x3F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(OuterProduct4x3F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(OuterProduct4x3F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "linalg outer product family matches the fixed entry at its extents" {
    const instance = OuterProduct{ .m = 4, .n = 3, .threads = .{ .x = 3, .y = 2 } };

    const family_launch = try OuterProductFamilyF32.launch(std.testing.allocator, OuterProductFamilyF32.Limits.testing, instance);
    const fixed_launch = try OuterProduct4x3F32.launch(std.testing.allocator, OuterProduct4x3F32.Limits.testing);
    try std.testing.expectEqualDeep(fixed_launch, family_launch);

    var family_snapshot = try OuterProductFamilyF32.scheduleSnapshot(std.testing.allocator, OuterProductFamilyF32.Limits.testing, instance);
    defer family_snapshot.deinit(std.testing.allocator);
    var fixed_snapshot = try OuterProduct4x3F32.scheduleSnapshot(std.testing.allocator, OuterProduct4x3F32.Limits.testing);
    defer fixed_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(fixed_snapshot.fingerprint(), family_snapshot.fingerprint());

    var lhs = [_]f32{ 1.0, -2.0, 0.5, 3.0 };
    var rhs = [_]f32{ 4.0, -1.0, 2.0 };
    var family_dst = @as([12]f32, @splat(0.0));
    var fixed_dst = @as([12]f32, @splat(0.0));

    try OuterProductFamilyF32.runCpu(std.testing.allocator, OuterProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, family_dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try OuterProduct4x3F32.runCpu(std.testing.allocator, OuterProduct4x3F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, fixed_dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, fixed_dst[0..], family_dst[0..]);
}

test "linalg outer product family executes fresh runtime extents" {
    const instance = OuterProduct{ .m = 5, .n = 6, .threads = .{ .x = 4, .y = 2 } };

    var lhs = [_]f32{ 2.0, -1.0, 0.5, 3.0, -4.0 };
    var rhs = [_]f32{ 1.5, -2.0, 0.25, 4.0, -0.5, 2.5 };
    var expected: [30]f32 = undefined;
    for (0..5) |row| {
        for (0..6) |col| {
            expected[row * 6 + col] = lhs[row] * rhs[col];
        }
    }

    var dst = @as([30]f32, @splat(0.0));
    try OuterProductFamilyF32.runCpu(std.testing.allocator, OuterProductFamilyF32.Limits.testing, instance, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);

    const launch_value = try OuterProductFamilyF32.launch(std.testing.allocator, OuterProductFamilyF32.Limits.testing, instance);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
}

test "linalg outer product family identity and metadata" {
    const instance = OuterProduct{
        .m = 5,
        .n = 6,
        .threads = .{ .x = 4, .y = 2 },
        .lhs_axis = "rows",
        .rhs_axis = "cols",
    };
    var owned = try outerProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const specialization = owned.value;

    const fixed_target = try outerProductInstanceTarget(std.testing.allocator, .{ .m = 4, .n = 3, .threads = .{ .x = 3, .y = 2 } });
    defer std.testing.allocator.free(fixed_target);
    try std.testing.expectEqualStrings(OuterProduct4x3F32.target, fixed_target);

    const fixed_entry = try outerProductInstanceEntryName(std.testing.allocator, .{ .m = 4, .n = 3, .threads = .{ .x = 3, .y = 2 } });
    defer std.testing.allocator.free(fixed_entry);
    try std.testing.expectEqualStrings(OuterProduct4x3F32.name, fixed_entry);

    const family_target = try outerProductFamilyTarget(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_target);
    try std.testing.expectEqualStrings("accy.kernel.linalg.outer_family_4x2_f32", family_target);

    const family_entry = try outerProductFamilyEntryName(std.testing.allocator, instance);
    defer std.testing.allocator.free(family_entry);
    try std.testing.expectEqualStrings("accy_kernel_linalg_outer_family_4x2_f32", family_entry);
    try std.testing.expectEqual(OuterProduct4x3F32.version, outer_product_family_version);

    try std.testing.expect(specialization.operationIs(.{ .linalg = .outer_product }));
    try std.testing.expectEqualStrings("m,n->mn", specialization.equation.?);
    try std.testing.expectEqual(@as(usize, 2), specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 5), specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 6), specialization.inputs[1].elementCount().?);
    try std.testing.expectEqual(@as(u64, 30), specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(usize, 0), specialization.reductions.len);
    try std.testing.expectEqualStrings("rows", specialization.inputs[0].axes[0].name);
    try std.testing.expectEqualStrings("cols", specialization.inputs[1].axes[0].name);
    try std.testing.expect(specialization.scheduleMatchesLaunch());
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.grid[0]);
    try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
    try std.testing.expectEqual(@as(usize, 4), specialization.schedule.?.bindings.len);
    try std.testing.expectEqualStrings("cols_tile", specialization.schedule.?.bindings[0].axis);
    try std.testing.expectEqual(kernel.BindTarget.block_x, specialization.schedule.?.bindings[0].target);
    try std.testing.expectEqualStrings("rows_lane", specialization.schedule.?.bindings[3].axis);
    try std.testing.expectEqual(kernel.BindTarget.thread_y, specialization.schedule.?.bindings[3].target);
    try std.testing.expect(specialization.shape_family != null);
    try std.testing.expectEqual(try outerProductFamilyFingerprint(std.testing.allocator, instance), specialization.shapeFamilyFingerprint().?);
}

test "linalg outer product reconstructs family instance from specialization" {
    const instance = OuterProduct{
        .m = 5,
        .n = 6,
        .threads = .{ .x = 4, .y = 2 },
        .lhs_axis = "rows",
        .rhs_axis = "cols",
    };
    var owned = try outerProductFamilySpecialization(std.testing.allocator, instance);
    defer owned.deinit();
    const reconstructed = outerProductInstanceFromSpecialization(owned.value) orelse return error.TestExpectedOuterProductInstance;

    try std.testing.expectEqual(instance.m, reconstructed.m);
    try std.testing.expectEqual(instance.n, reconstructed.n);
    try std.testing.expectEqual(instance.threads.x, reconstructed.threads.x);
    try std.testing.expectEqual(instance.threads.y, reconstructed.threads.y);
    try std.testing.expectEqualStrings(instance.lhs_axis, reconstructed.lhs_axis);
    try std.testing.expectEqualStrings(instance.rhs_axis, reconstructed.rhs_axis);
}

test "linalg outer product runtime family executes explicit runtime extents" {
    const allocator = std.testing.allocator;
    const compiled = OuterProduct{ .m = 1, .n = 1, .threads = .{ .x = 4, .y = 2 } };
    const runtime = OuterProduct{ .m = 3, .n = 4, .threads = compiled.threads };

    var graph = try OuterProductRuntimeFamilyF32.build(allocator, OuterProductRuntimeFamilyF32.Limits.testing, compiled);
    defer graph.deinit();

    var lhs = [_]f32{ 2.0, -1.0, 0.5 };
    var rhs = [_]f32{ 1.5, -2.0, 0.25, 4.0 };
    var expected: [12]f32 = undefined;
    for (0..3) |row| {
        for (0..4) |col| {
            expected[row * 4 + col] = lhs[row] * rhs[col];
        }
    }

    var dst = @as([12]f32, @splat(0.0));
    const launch_value = try entry.runtimeLaunch2D(runtime.n, runtime.m, runtime.threads.x, runtime.threads.y);
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentI32(@intCast(runtime.m)),
        kernel.argumentI32(@intCast(runtime.n)),
    }, .{
        .grid = launch_value.grid,
        .block = launch_value.threadgroup,
    });
    try std.testing.expectEqualSlices(f32, expected[0..], dst[0..]);
}

test "linalg outer product family artifact carries runtime launch contract" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const instance = OuterProduct{ .m = 5, .n = 6, .threads = .{ .x = 4, .y = 2 } };

    var family_artifact = try createOuterProductFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    var fixed_artifact = try OuterProduct4x3F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = OuterProduct4x3F32.Limits.testing });
    defer fixed_artifact.deinit();

    const family_entry = family_artifact.entry();
    const fixed_entry = fixed_artifact.entry();
    try std.testing.expect(!std.mem.eql(u8, fixed_entry.target, family_entry.target));
    try std.testing.expectEqualStrings("accy.kernel.linalg.outer_family_4x2_f32", family_entry.target);
    try std.testing.expectEqualStrings("accy_kernel_linalg_outer_family_4x2_f32", family_entry.entry_name);
    try std.testing.expectEqual(@as(u32, 5), family_entry.argument_count);
    try std.testing.expectEqual(@as(u32, 2), family_entry.runtime_scalar_argument_count);
    try std.testing.expect(family_entry.required_dtypes.contains(.f32));
    try std.testing.expect(family_entry.required_dtypes.contains(.i32));
    try std.testing.expect(fixed_entry.shape_family_fingerprint == null);
    try std.testing.expect(family_entry.shape_family_fingerprint != null);
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("outer_product", profile.name);
    try std.testing.expectEqual(family_entry.shape_family_fingerprint.?, profile.fingerprint);
    try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
    const m_dimension = profile.runtimeScalarDimension(0) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("m", m_dimension.name);
    const n_dimension = profile.runtimeScalarDimension(1) orelse return error.TestExpectedShapeProfile;
    try std.testing.expectEqualStrings("n", n_dimension.name);
    switch (family_entry.launch) {
        .derived => |launch| {
            try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[1]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 1), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 4), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            switch (launch.grid[1]) {
                .runtime_u32_ceil_div => |axis| {
                    try std.testing.expectEqual(@as(u32, 0), axis.argument_index);
                    try std.testing.expectEqual(@as(u32, 2), axis.divisor);
                },
                else => return error.TestExpectedDerivedLaunch,
            }
            const args = try outerProductRuntimeArguments(instance);
            const geometry = try launch.geometry(args[0..]);
            try std.testing.expectEqual(@as(u32, 2), geometry.grid[0]);
            try std.testing.expectEqual(@as(u32, 3), geometry.grid[1]);
            try std.testing.expectEqual(@as(u32, 4), geometry.threadgroup[0]);
            try std.testing.expectEqual(@as(u32, 2), geometry.threadgroup[1]);
        },
        .fixed => return error.TestExpectedDerivedLaunch,
    }
}
