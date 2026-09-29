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
const runtimeExtentArgument = extent_mod.runtimeExtentArgument;

pub const SpmvCsrStructure = enum {
    row_thread,
    row_warp,
};

pub const SpmvCsr = struct {
    rows: u64,
    nnz: u64 = 1,
    x_extent: u64 = 1,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    threads: u32 = 256,
    structure: SpmvCsrStructure = .row_warp,
    row_axis: []const u8 = "r",
};

pub const SpmvCooStructure = enum {
    element_thread,
    row_thread,
};

pub const SpmvCoo = struct {
    rows: u64,
    nnz: u64 = 1,
    x_extent: u64 = 1,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    threads: u32 = 256,
    structure: SpmvCooStructure = .element_thread,
    row_axis: []const u8 = "r",
    nonzero_axis: []const u8 = "n",
    x_axis: []const u8 = "x",
};

pub const SpmvEllStructure = enum {
    row_thread,
};

pub const SpmvEll = struct {
    rows: u64,
    slots: u64 = 1,
    x_extent: u64 = 1,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    threads: u32 = 256,
    structure: SpmvEllStructure = .row_thread,
    row_axis: []const u8 = "r",
    slot_axis: []const u8 = "s",
    x_axis: []const u8 = "x",
};

pub const SpmvSellStructure = enum {
    row_thread,
};

pub const SpmvSell = struct {
    rows: u64,
    slice_size: u64 = 32,
    values_size: u64 = 1,
    x_extent: u64 = 1,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    threads: u32 = 256,
    structure: SpmvSellStructure = .row_thread,
    row_axis: []const u8 = "r",
    slice_axis: []const u8 = "z",
    value_axis: []const u8 = "n",
    x_axis: []const u8 = "x",
};

pub const SpmmCsrStructure = enum {
    row_column_thread,
};

pub const SpmmCsr = struct {
    rows: u64,
    columns: u64,
    nnz: u64 = 1,
    x_extent: u64 = 1,
    dtype: DType = .f32,
    accumulation_dtype: DType = .f32,
    threads: entry.Threads2D = .{},
    structure: SpmmCsrStructure = .row_column_thread,
    row_axis: []const u8 = "r",
    column_axis: []const u8 = "c",
    x_axis: []const u8 = "x",
};

pub const spmv_csr_family_version: u32 = 1;
pub const spmv_coo_family_version: u32 = 1;
pub const spmv_ell_family_version: u32 = 1;
pub const spmv_sell_family_version: u32 = 1;
pub const spmm_csr_family_version: u32 = 1;
pub const spmv_csr_warp_size: u32 = 32;
pub const spmv_csr_max_threads: u32 = 1024;
pub const spmv_coo_max_threads: u32 = 1024;
pub const spmv_ell_max_threads: u32 = 1024;
pub const spmv_sell_max_threads: u32 = 1024;
pub const spmm_csr_max_threads: u32 = 1024;

const spmv_ell_thread_caps = geometry_mod.ThreadCaps1D{ .budget = spmv_ell_max_threads };
const spmv_sell_thread_caps = geometry_mod.ThreadCaps1D{ .budget = spmv_sell_max_threads };
const spmm_csr_thread_caps = geometry_mod.ThreadCaps{
    .budget = 256,
    .x_max = 64,
    .y_max = 16,
};

pub fn spmvCsrWarpsPerBlock(threads: u32) u32 {
    return threads / spmv_csr_warp_size;
}

pub fn spmvCsrRowsPerBlock(instance: SpmvCsr) u32 {
    return switch (instance.structure) {
        .row_thread => instance.threads,
        .row_warp => spmvCsrWarpsPerBlock(instance.threads),
    };
}

pub fn spmvCsrBlockCount(instance: SpmvCsr) u64 {
    return spmvCsrBlockCountChecked(instance).?;
}

fn sparseFloatAccumulationDType(dtype: DType) ?DType {
    return switch (dtype) {
        .f64 => .f64,
        .f32, .f16 => .f32,
        else => null,
    };
}

pub fn sparseAccumulationDType(dtype: DType) ?DType {
    return sparseFloatAccumulationDType(dtype);
}

pub fn spmvCsrAccumulationDType(dtype: DType) ?DType {
    return sparseAccumulationDType(dtype);
}

pub fn spmvCooAccumulationDType(dtype: DType) ?DType {
    const structure = spmvCooDefaultStructure(dtype) orelse return null;
    return spmvCooAccumulationDTypeForStructure(structure, dtype);
}

pub fn spmvCooDefaultStructure(dtype: DType) ?SpmvCooStructure {
    return switch (dtype) {
        .f32 => .element_thread,
        .f16, .f64 => .row_thread,
        else => null,
    };
}

pub fn spmvCooAccumulationDTypeForStructure(structure: SpmvCooStructure, dtype: DType) ?DType {
    return switch (structure) {
        .element_thread => switch (dtype) {
            .f32 => .f32,
            else => null,
        },
        .row_thread => sparseAccumulationDType(dtype),
    };
}

pub fn spmvEllAccumulationDType(dtype: DType) ?DType {
    return sparseAccumulationDType(dtype);
}

pub fn spmvSellAccumulationDType(dtype: DType) ?DType {
    return sparseAccumulationDType(dtype);
}

pub fn spmmCsrAccumulationDType(dtype: DType) ?DType {
    return sparseAccumulationDType(dtype);
}

fn spmvCsrBlockCountChecked(instance: SpmvCsr) ?u64 {
    const rows_per_block = spmvCsrRowsPerBlock(instance);
    if (rows_per_block == 0) return null;
    const biased = std.math.add(u64, instance.rows, rows_per_block - 1) catch return null;
    return biased / rows_per_block;
}

pub fn spmvCsrInstanceValid(instance: SpmvCsr) bool {
    const accumulation_dtype = spmvCsrAccumulationDType(instance.dtype) orelse return false;
    if (instance.accumulation_dtype != accumulation_dtype) return false;
    if (instance.rows == 0) return false;
    if (instance.nnz == 0) return false;
    if (instance.x_extent == 0) return false;
    if (instance.threads == 0 or instance.threads > spmv_csr_max_threads) return false;
    if (spmvCsrLaunchExtentChecked(instance) == null) return false;
    if (spmvCsrBlockCountChecked(instance) == null) return false;
    return switch (instance.structure) {
        .row_thread => true,
        .row_warp => instance.threads % spmv_csr_warp_size == 0,
    };
}

fn spmvCooBlockCountChecked(instance: SpmvCoo) ?u64 {
    if (instance.threads == 0) return null;
    const extent = spmvCooLaunchExtentChecked(instance) orelse return null;
    const biased = std.math.add(u64, extent, instance.threads - 1) catch return null;
    return biased / instance.threads;
}

pub fn spmvCooBlockCount(instance: SpmvCoo) u64 {
    return spmvCooBlockCountChecked(instance).?;
}

pub fn spmvCooInstanceValid(instance: SpmvCoo) bool {
    const accumulation_dtype = spmvCooAccumulationDTypeForStructure(instance.structure, instance.dtype) orelse return false;
    if (instance.accumulation_dtype != accumulation_dtype) return false;
    if (instance.rows == 0 or instance.nnz == 0 or instance.x_extent == 0) return false;
    if (instance.threads == 0 or instance.threads > spmv_coo_max_threads) return false;
    if (spmvCooLaunchExtentChecked(instance) == null) return false;
    if (spmvCooBlockCountChecked(instance) == null) return false;
    return switch (instance.structure) {
        .element_thread => true,
        .row_thread => true,
    };
}

fn sparseFloatAccumulationZero(inner_builder: anytype, accumulation_dtype: DType) !kernel.Value {
    return switch (accumulation_dtype) {
        .f64 => inner_builder.constantFloat(.f64, 0.0),
        .f32 => inner_builder.constantFloat(.f32, 0.0),
        else => error.UnsupportedDType,
    };
}

fn spmvCsrAccumulationZero(inner_builder: anytype, instance: SpmvCsr) !kernel.Value {
    return sparseFloatAccumulationZero(inner_builder, instance.accumulation_dtype);
}

fn sparseFloatAccumulationValue(inner_builder: anytype, accumulation_dtype: DType, value: anytype) !kernel.Value {
    return switch (accumulation_dtype) {
        .f64 => if (comptime @TypeOf(value).scalar_dtype == .f64) value.raw() else (try value.cast(inner_builder, .f64)).raw(),
        .f32 => if (comptime @TypeOf(value).scalar_dtype == .f32) value.raw() else (try value.cast(inner_builder, .f32)).raw(),
        else => error.UnsupportedDType,
    };
}

fn spmvCsrAccumulationValue(inner_builder: anytype, instance: SpmvCsr, value: anytype) !kernel.Value {
    return sparseFloatAccumulationValue(inner_builder, instance.accumulation_dtype, value);
}

fn sparseFloatOutputValue(inner_builder: anytype, dtype: DType, accumulation_dtype: DType, value: kernel.Value) !kernel.Value {
    if (dtype == accumulation_dtype) return value;
    return switch (dtype) {
        .f64 => inner_builder.cast(value, .f64),
        .f32 => inner_builder.cast(value, .f32),
        .f16 => inner_builder.cast(value, .f16),
        else => error.UnsupportedDType,
    };
}

fn spmvCsrOutputValue(inner_builder: anytype, instance: SpmvCsr, value: kernel.Value) !kernel.Value {
    return sparseFloatOutputValue(inner_builder, instance.dtype, instance.accumulation_dtype, value);
}

fn spmvCooAccumulationValue(inner_builder: anytype, instance: SpmvCoo, value: anytype) !kernel.Value {
    return sparseFloatAccumulationValue(inner_builder, instance.accumulation_dtype, value);
}

fn spmvCooAccumulationZero(inner_builder: anytype, instance: SpmvCoo) !kernel.Value {
    return sparseFloatAccumulationZero(inner_builder, instance.accumulation_dtype);
}

fn spmvCooOutputValue(inner_builder: anytype, instance: SpmvCoo, value: kernel.Value) !kernel.Value {
    return sparseFloatOutputValue(inner_builder, instance.dtype, instance.accumulation_dtype, value);
}

fn spmv_csr_row_value_apply(fold_builder: anytype, element: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const column_loaded = try ctx.args.param(.cols).load(fold_builder, element);
    const column_index = try fold_builder.castIndex(column_loaded.raw());
    const column_lower = try fold_builder.max(column_index, ctx.zero);
    const x_last = try fold_builder.sub(ctx.x_extent, ctx.one);
    const column = try fold_builder.min(column_lower, x_last);
    const x_value = try ctx.args.param(.x).load(fold_builder, column);
    const matrix_value = try ctx.args.param(.values).load(fold_builder, element);
    const matrix_acc = try spmvCsrAccumulationValue(fold_builder, ctx.instance, matrix_value);
    const x_acc = try spmvCsrAccumulationValue(fold_builder, ctx.instance, x_value);
    const product = try fold_builder.mul(matrix_acc, x_acc);
    return fold_builder.add(current, product);
}

fn spmvCsrRowValue(
    inner_builder: anytype,
    instance: SpmvCsr,
    args: anytype,
    row: kernel.Value,
    lane: kernel.Value,
    nnz: kernel.Value,
    x_extent: kernel.Value,
) !kernel.Value {
    const one = try inner_builder.constantIndex(1);
    const next = try inner_builder.add(row, one);
    const begin_loaded = try args.param(.row_ptr).load(inner_builder, row);
    const end_loaded = try args.param(.row_ptr).load(inner_builder, next);
    const begin_index = try inner_builder.castIndex(begin_loaded.raw());
    const end_index = try inner_builder.castIndex(end_loaded.raw());
    const zero = try inner_builder.constantIndex(0);
    const end_lower = try inner_builder.max(end_index, zero);
    const end_clamped = try inner_builder.min(end_lower, nnz);
    const begin_lower = try inner_builder.max(begin_index, zero);
    const begin_clamped = try inner_builder.min(begin_lower, end_clamped);
    const lane_begin = try inner_builder.add(begin_clamped, lane);
    const stride = try inner_builder.constantIndex(spmv_csr_warp_size);

    const acc_zero = try spmvCsrAccumulationZero(inner_builder, instance);
    const partial = try inner_builder.fold(lane_begin, end_clamped, stride, acc_zero, .{
        .instance = instance,
        .args = args,
        .x_extent = x_extent,
        .zero = zero,
        .one = one,
    }, spmv_csr_row_value_apply);
    return inner_builder.warpReduce(.add, partial);
}

fn spmv_csr_row_thread_value_apply(fold_builder: anytype, element: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const column_loaded = try ctx.args.param(.cols).load(fold_builder, element);
    const column_index = try fold_builder.castIndex(column_loaded.raw());
    const column_lower = try fold_builder.max(column_index, ctx.zero);
    const x_last = try fold_builder.sub(ctx.x_extent, ctx.one);
    const column = try fold_builder.min(column_lower, x_last);
    const x_value = try ctx.args.param(.x).load(fold_builder, column);
    const matrix_value = try ctx.args.param(.values).load(fold_builder, element);
    const matrix_acc = try spmvCsrAccumulationValue(fold_builder, ctx.instance, matrix_value);
    const x_acc = try spmvCsrAccumulationValue(fold_builder, ctx.instance, x_value);
    const product = try fold_builder.mul(matrix_acc, x_acc);
    return fold_builder.add(current, product);
}

fn spmvCsrRowThreadValue(
    inner_builder: anytype,
    instance: SpmvCsr,
    args: anytype,
    row: kernel.Value,
    nnz: kernel.Value,
    x_extent: kernel.Value,
) !kernel.Value {
    const one = try inner_builder.constantIndex(1);
    const next = try inner_builder.add(row, one);
    const begin_loaded = try args.param(.row_ptr).load(inner_builder, row);
    const end_loaded = try args.param(.row_ptr).load(inner_builder, next);
    const begin_index = try inner_builder.castIndex(begin_loaded.raw());
    const end_index = try inner_builder.castIndex(end_loaded.raw());
    const zero = try inner_builder.constantIndex(0);
    const end_lower = try inner_builder.max(end_index, zero);
    const end_clamped = try inner_builder.min(end_lower, nnz);
    const begin_lower = try inner_builder.max(begin_index, zero);
    const begin_clamped = try inner_builder.min(begin_lower, end_clamped);

    const acc_zero = try spmvCsrAccumulationZero(inner_builder, instance);
    return inner_builder.fold(begin_clamped, end_clamped, one, acc_zero, .{
        .instance = instance,
        .args = args,
        .x_extent = x_extent,
        .zero = zero,
        .one = one,
    }, spmv_csr_row_thread_value_apply);
}

fn spmv_csr_row_thread_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const sum = try spmvCsrRowThreadValue(inner_builder, ctx.instance, ctx.args, ctx.row, ctx.nnz, ctx.x_extent);
    const result = try spmvCsrOutputValue(inner_builder, ctx.instance, sum);
    try ctx.args.param(.y).store(inner_builder, result, ctx.row);
}

fn spmvCsrRowThreadRuntimeBody(k: anytype, spec: SpmvCsr, args: anytype) !void {
    if (!spmvCsrInstanceValid(spec)) return error.UnsupportedSpmvCsrInstance;
    const row = try k.globalId(.x);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const nnz = try k.castIndex(args.param(.nnz).raw());
    const x_extent = try k.castIndex(args.param(.x_extent).raw());
    const active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(active, .{
        .args = args,
        .row = row,
        .nnz = nnz,
        .x_extent = x_extent,
        .instance = spec,
    }, spmv_csr_row_thread_runtime_body_active);
}

fn spmvCsrRuntimeBody(k: anytype, spec: SpmvCsr, args: anytype) !void {
    return switch (spec.structure) {
        .row_thread => spmvCsrRowThreadRuntimeBody(k, spec, args),
        .row_warp => spmvCsrRowWarpRuntimeBody(k, spec, args),
    };
}

fn spmv_csr_row_warp_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const sum = try spmvCsrRowValue(inner_builder, ctx.instance, ctx.args, ctx.row, ctx.lane, ctx.nnz, ctx.x_extent);
    const result = try spmvCsrOutputValue(inner_builder, ctx.instance, sum);
    const zero = try inner_builder.constantIndex(0);
    const writer = try inner_builder.compare(.eq, ctx.lane, zero);
    try inner_builder.guardDo(writer, .{
        .args = ctx.args,
        .row = ctx.row,
        .sum = result,
    }, spmv_csr_row_warp_runtime_body_writer);
}

fn spmv_csr_row_warp_runtime_body_writer(writer_builder: anytype, writer_ctx: anytype) !void {
    try writer_ctx.args.param(.y).store(writer_builder, writer_ctx.sum, writer_ctx.row);
}

fn spmvCsrRowWarpRuntimeBody(k: anytype, spec: SpmvCsr, args: anytype) !void {
    if (!spmvCsrInstanceValid(spec)) return error.UnsupportedSpmvCsrInstance;
    const element_thread = try k.globalId(.x);
    const lane = try k.laneId();
    const warp_size = try k.constantIndex(spmv_csr_warp_size);
    const row = try k.div(element_thread, warp_size);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const nnz = try k.castIndex(args.param(.nnz).raw());
    const x_extent = try k.castIndex(args.param(.x_extent).raw());
    const active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(active, .{
        .args = args,
        .row = row,
        .lane = lane,
        .nnz = nnz,
        .x_extent = x_extent,
        .instance = spec,
    }, spmv_csr_row_warp_runtime_body_active);
}

fn spmvCsrFamilySchedule(instance: SpmvCsr) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn spmvCsrRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_sparse_spmv_csr_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .y = kernel.dynamicBuffer(dtype),
            .row_ptr = kernel.dynamicBuffer(.i32),
            .cols = kernel.dynamicBuffer(.i32),
            .values = kernel.dynamicBuffer(dtype),
            .x = kernel.dynamicBuffer(dtype),
            .rows = kernel.scalar(.i32),
            .nnz = kernel.scalar(.i32),
            .x_extent = kernel.scalar(.i32),
        },
        .Instance = SpmvCsr,
        .schedule = spmvCsrFamilySchedule,
        .body = spmvCsrRuntimeBody,
    });
}

pub const SpmvCsrRuntimeFamilyF64 = spmvCsrRuntimeFamily(.f64);
pub const SpmvCsrRuntimeFamilyF32 = spmvCsrRuntimeFamily(.f32);
pub const SpmvCsrRuntimeFamilyF16 = spmvCsrRuntimeFamily(.f16);

pub fn spmvCsrFamilyTarget(allocator: std.mem.Allocator, instance: SpmvCsr) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sparse.spmv_csr_{s}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.threads, instance.dtype.name() },
    );
}

pub fn spmvCsrFamilyEntryName(allocator: std.mem.Allocator, instance: SpmvCsr) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sparse_spmv_csr_{s}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.threads, instance.dtype.name() },
    );
}

pub fn spmvCsrRuntimeArguments(
    instance: SpmvCsr,
    nnz: u64,
    x_extent: u64,
) ![3]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.rows) },
        .{ .u32 = try runtimeExtentArgument(nnz) },
        .{ .u32 = try runtimeExtentArgument(x_extent) },
    };
}

pub fn spmvCsrMaxRows(instance: SpmvCsr) u64 {
    _ = instance;
    return std.math.maxInt(u32);
}

pub fn spmvCsrShapeProfileDimensions(instance: SpmvCsr) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = spmvCsrMaxRows(instance) },
        },
    };
}

fn spmvCsrLaunch(instance: SpmvCsr) !artifact_product.KernelCallLaunch {
    if (!spmvCsrInstanceValid(instance)) return error.UnsupportedSpmvCsrInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = spmvCsrRowsPerBlock(instance) } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn spmvCsrShapeFamily(backing_allocator: std.mem.Allocator, instance: SpmvCsr) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "spmv_csr");
    errdefer builder.deinit();
    const rows = try builder.symbol(instance.row_axis);
    const rows_expr = try builder.symbolExpression(rows);
    _ = try builder.tensor("y", &.{rows_expr});
    try builder.assumeBounds(rows_expr, .{ .min = 1, .max = spmvCsrMaxRows(instance) });
    return builder.finish();
}

pub fn spmvCsrFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: SpmvCsr) !u64 {
    var family = try spmvCsrShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn spmvCsrTuningExtents(instance: SpmvCsr) [3]u64 {
    return .{ instance.rows, instance.nnz, instance.x_extent };
}

pub fn spmvCsrTuningOperation(instance: SpmvCsr) entry.Operation {
    _ = instance;
    return .{ .sparse = .csr_spmv };
}

pub fn spmvCsrFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: SpmvCsr,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try spmvCsrFamilyFingerprint(backing_allocator, instance);
    const extents = spmvCsrTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(spmvCsrTuningOperation(instance)),
        instance.dtype,
        spmv_csr_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveSpmvCsrStructure(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: SpmvCsr,
) !?SpmvCsrStructure {
    const key = try spmvCsrFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    const structures = [_]SpmvCsrStructure{ .row_thread, .row_warp };
    for (structures) |structure| {
        var candidate = instance;
        candidate.structure = structure;
        candidate.threads = spmvCsrRepresentableThreads(candidate) orelse continue;
        if (!spmvCsrInstanceValid(candidate)) continue;
        const target = try spmvCsrFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return structure;
    }
    return null;
}

pub fn createSpmvCsrFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: SpmvCsr,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!spmvCsrInstanceValid(instance)) return error.UnsupportedSpmvCsrInstance;
    const target = try spmvCsrFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try spmvCsrFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try spmvCsrFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = spmvCsrShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "spmv_csr",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f64 => try SpmvCsrRuntimeFamilyF64.buildNamed(allocator, options.limits, entry_name, instance),
        .f32 => try SpmvCsrRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .f16 => try SpmvCsrRuntimeFamilyF16.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = spmv_csr_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spmvCsrLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

fn spmv_coo_element_thread_runtime_body_active(guard_builder: anytype, ctx: anytype) !void {
    const row_loaded = try ctx.args.param(.row_indices).load(guard_builder, ctx.element);
    const zero_i32 = try guard_builder.constantInt(.i32, 0);
    const row_non_negative = try guard_builder.compare(.ge, row_loaded.raw(), zero_i32);
    try guard_builder.guardDo(row_non_negative, .{
        .args = ctx.args,
        .element = ctx.element,
        .instance = ctx.instance,
        .row_raw = row_loaded.raw(),
    }, spmv_coo_element_thread_runtime_body_row_non_negative);
}

fn spmv_coo_element_thread_runtime_body_row_non_negative(row_builder: anytype, row_ctx: anytype) !void {
    const col_loaded = try row_ctx.args.param(.cols).load(row_builder, row_ctx.element);
    const zero_i32_inner = try row_builder.constantInt(.i32, 0);
    const col_non_negative = try row_builder.compare(.ge, col_loaded.raw(), zero_i32_inner);
    try row_builder.guardDo(col_non_negative, .{
        .args = row_ctx.args,
        .element = row_ctx.element,
        .instance = row_ctx.instance,
        .row_raw = row_ctx.row_raw,
        .col_raw = col_loaded.raw(),
    }, spmv_coo_element_thread_runtime_body_col_non_negative);
}

fn spmv_coo_element_thread_runtime_body_col_non_negative(col_builder: anytype, col_ctx: anytype) !void {
    const rows_extent = try col_builder.castIndex(col_ctx.args.param(.rows).raw());
    const x_extent = try col_builder.castIndex(col_ctx.args.param(.x_extent).raw());
    const row = try col_builder.castIndex(col_ctx.row_raw);
    const col = try col_builder.castIndex(col_ctx.col_raw);
    const row_in_range = try col_builder.compare(.lt, row, rows_extent);
    try col_builder.guardDo(row_in_range, .{
        .args = col_ctx.args,
        .element = col_ctx.element,
        .instance = col_ctx.instance,
        .row = row,
        .col = col,
        .x_extent = x_extent,
    }, spmv_coo_element_thread_runtime_body_row_in_range);
}

fn spmv_coo_element_thread_runtime_body_row_in_range(row_range_builder: anytype, row_range_ctx: anytype) !void {
    const col_in_range = try row_range_builder.compare(.lt, row_range_ctx.col, row_range_ctx.x_extent);
    try row_range_builder.guardDo(col_in_range, .{
        .args = row_range_ctx.args,
        .element = row_range_ctx.element,
        .instance = row_range_ctx.instance,
        .row = row_range_ctx.row,
        .col = row_range_ctx.col,
    }, spmv_coo_element_thread_runtime_body_col_in_range);
}

fn spmv_coo_element_thread_runtime_body_col_in_range(atomic_builder: anytype, atomic_ctx: anytype) !void {
    const x_value = try atomic_ctx.args.param(.x).load(atomic_builder, atomic_ctx.col);
    const matrix_value = try atomic_ctx.args.param(.values).load(atomic_builder, atomic_ctx.element);
    const matrix_acc = try spmvCooAccumulationValue(atomic_builder, atomic_ctx.instance, matrix_value);
    const x_acc = try spmvCooAccumulationValue(atomic_builder, atomic_ctx.instance, x_value);
    const product = try atomic_builder.mul(matrix_acc, x_acc);
    _ = try atomic_ctx.args.param(.y).atomicRmw(atomic_builder, .add, product, atomic_ctx.row);
}

fn spmvCooElementThreadRuntimeBody(k: anytype, spec: SpmvCoo, args: anytype) !void {
    if (!spmvCooInstanceValid(spec)) return error.UnsupportedSpmvCooInstance;
    const element = try k.globalId(.x);
    const nnz = try k.castIndex(args.param(.nnz).raw());
    const active = try k.compare(.lt, element, nnz);
    try k.guardDo(active, .{
        .args = args,
        .element = element,
        .instance = spec,
    }, spmv_coo_element_thread_runtime_body_active);
}

fn spmv_coo_row_thread_value_apply(fold_builder: anytype, element: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const row_loaded = try ctx.args.param(.row_indices).load(fold_builder, element);
    const row_i32 = try fold_builder.cast(ctx.row, .i32);
    const row_matches = try fold_builder.compare(.eq, row_loaded.raw(), row_i32);
    const col_loaded = try ctx.args.param(.cols).load(fold_builder, element);
    const zero_i32 = try fold_builder.constantInt(.i32, 0);
    const col_non_negative = try fold_builder.compare(.ge, col_loaded.raw(), zero_i32);
    const x_extent_i32 = try fold_builder.cast(ctx.x_extent, .i32);
    const col_in_range = try fold_builder.compare(.lt, col_loaded.raw(), x_extent_i32);
    const column_index = try fold_builder.castIndex(col_loaded.raw());
    const column_lower = try fold_builder.max(column_index, ctx.zero);
    const x_last = try fold_builder.sub(ctx.x_extent, ctx.one);
    const column = try fold_builder.min(column_lower, x_last);
    const x_value = try ctx.args.param(.x).load(fold_builder, column);
    const matrix_value = try ctx.args.param(.values).load(fold_builder, element);
    const matrix_acc = try spmvCooAccumulationValue(fold_builder, ctx.instance, matrix_value);
    const x_acc = try spmvCooAccumulationValue(fold_builder, ctx.instance, x_value);
    const product = try fold_builder.mul(matrix_acc, x_acc);
    const row_contribution = try fold_builder.select(row_matches, product, ctx.acc_zero);
    const non_negative_contribution = try fold_builder.select(col_non_negative, row_contribution, ctx.acc_zero);
    const contribution = try fold_builder.select(col_in_range, non_negative_contribution, ctx.acc_zero);
    return fold_builder.add(current, contribution);
}

fn spmvCooRowThreadValue(
    inner_builder: anytype,
    instance: SpmvCoo,
    args: anytype,
    row: kernel.Value,
    nnz: kernel.Value,
    x_extent: kernel.Value,
) !kernel.Value {
    const zero = try inner_builder.constantIndex(0);
    const one = try inner_builder.constantIndex(1);
    const acc_zero = try spmvCooAccumulationZero(inner_builder, instance);
    return inner_builder.fold(zero, nnz, one, acc_zero, .{
        .instance = instance,
        .args = args,
        .row = row,
        .x_extent = x_extent,
        .zero = zero,
        .one = one,
        .acc_zero = acc_zero,
    }, spmv_coo_row_thread_value_apply);
}

fn spmv_coo_row_thread_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const sum = try spmvCooRowThreadValue(
        inner_builder,
        ctx.instance,
        ctx.args,
        ctx.row,
        ctx.nnz,
        ctx.x_extent,
    );
    const initial = try ctx.args.param(.y).load(inner_builder, ctx.row);
    const initial_acc = try spmvCooAccumulationValue(inner_builder, ctx.instance, initial);
    const total = try inner_builder.add(initial_acc, sum);
    const result = try spmvCooOutputValue(inner_builder, ctx.instance, total);
    try ctx.args.param(.y).store(inner_builder, result, ctx.row);
}

fn spmvCooRowThreadRuntimeBody(k: anytype, spec: SpmvCoo, args: anytype) !void {
    if (!spmvCooInstanceValid(spec)) return error.UnsupportedSpmvCooInstance;
    const row = try k.globalId(.x);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const nnz = try k.castIndex(args.param(.nnz).raw());
    const x_extent = try k.castIndex(args.param(.x_extent).raw());
    const active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(active, .{
        .args = args,
        .row = row,
        .nnz = nnz,
        .x_extent = x_extent,
        .instance = spec,
    }, spmv_coo_row_thread_runtime_body_active);
}

fn spmvCooRuntimeBody(k: anytype, spec: SpmvCoo, args: anytype) !void {
    return switch (spec.structure) {
        .element_thread => spmvCooElementThreadRuntimeBody(k, spec, args),
        .row_thread => spmvCooRowThreadRuntimeBody(k, spec, args),
    };
}

fn spmvCooFamilySchedule(instance: SpmvCoo) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn spmvCooRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_sparse_spmv_coo_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .y = kernel.dynamicBuffer(dtype),
            .row_indices = kernel.dynamicBuffer(.i32),
            .cols = kernel.dynamicBuffer(.i32),
            .values = kernel.dynamicBuffer(dtype),
            .x = kernel.dynamicBuffer(dtype),
            .rows = kernel.scalar(.i32),
            .nnz = kernel.scalar(.i32),
            .x_extent = kernel.scalar(.i32),
        },
        .Instance = SpmvCoo,
        .schedule = spmvCooFamilySchedule,
        .body = spmvCooRuntimeBody,
    });
}

pub const SpmvCooRuntimeFamilyF64 = spmvCooRuntimeFamily(.f64);
pub const SpmvCooRuntimeFamilyF32 = spmvCooRuntimeFamily(.f32);
pub const SpmvCooRuntimeFamilyF16 = spmvCooRuntimeFamily(.f16);

pub fn spmvCooFamilyTarget(allocator: std.mem.Allocator, instance: SpmvCoo) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sparse.spmv_coo_{s}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.threads, instance.dtype.name() },
    );
}

pub fn spmvCooFamilyEntryName(allocator: std.mem.Allocator, instance: SpmvCoo) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sparse_spmv_coo_{s}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.threads, instance.dtype.name() },
    );
}

pub fn spmvCooRuntimeArguments(
    instance: SpmvCoo,
    nnz: u64,
    x_extent: u64,
) ![3]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.rows) },
        .{ .u32 = try runtimeExtentArgument(nnz) },
        .{ .u32 = try runtimeExtentArgument(x_extent) },
    };
}

pub fn spmvCooMaxRows(instance: SpmvCoo) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvCooMaxNnz(instance: SpmvCoo) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvCooMaxXExtent(instance: SpmvCoo) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvCooShapeProfileDimensions(instance: SpmvCoo) [2]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = spmvCooMaxRows(instance) },
        },
        .{
            .name = instance.nonzero_axis,
            .runtime_scalar_argument_index = 1,
            .bounds = .{ .min = 1, .max = spmvCooMaxNnz(instance) },
        },
    };
}

fn spmvCooLaunch(instance: SpmvCoo) !artifact_product.KernelCallLaunch {
    if (!spmvCooInstanceValid(instance)) return error.UnsupportedSpmvCooInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = spmvCooLaunchArgumentIndex(instance), .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn spmvCooShapeFamily(backing_allocator: std.mem.Allocator, instance: SpmvCoo) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "spmv_coo");
    errdefer builder.deinit();
    const rows = try builder.symbol(instance.row_axis);
    const nnz = try builder.symbol(instance.nonzero_axis);
    const x_extent = try builder.symbol(instance.x_axis);
    const rows_expr = try builder.symbolExpression(rows);
    const nnz_expr = try builder.symbolExpression(nnz);
    const x_extent_expr = try builder.symbolExpression(x_extent);
    _ = try builder.tensor("row_indices", &.{nnz_expr});
    _ = try builder.tensor("cols", &.{nnz_expr});
    _ = try builder.tensor("values", &.{nnz_expr});
    _ = try builder.tensor("x", &.{x_extent_expr});
    _ = try builder.tensor("y", &.{rows_expr});
    const bounds = shape.Bounds{ .min = 1, .max = extent_mod.runtime_extent_max };
    try builder.assumeBounds(rows_expr, bounds);
    try builder.assumeBounds(nnz_expr, bounds);
    try builder.assumeBounds(x_extent_expr, bounds);
    return builder.finish();
}

pub fn spmvCooFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: SpmvCoo) !u64 {
    var family = try spmvCooShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn spmvCooTuningExtents(instance: SpmvCoo) [3]u64 {
    return .{ instance.rows, instance.nnz, instance.x_extent };
}

pub fn spmvCooTuningOperation(instance: SpmvCoo) entry.Operation {
    _ = instance;
    return .{ .sparse = .coo_spmv };
}

pub fn spmvCooFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: SpmvCoo,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try spmvCooFamilyFingerprint(backing_allocator, instance);
    const extents = spmvCooTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(spmvCooTuningOperation(instance)),
        instance.dtype,
        spmv_coo_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveSpmvCooStructure(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: SpmvCoo,
) !?SpmvCooStructure {
    const key = try spmvCooFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    const structures = [_]SpmvCooStructure{ .element_thread, .row_thread };
    for (structures) |structure| {
        var candidate = instance;
        candidate.structure = structure;
        candidate.accumulation_dtype = spmvCooAccumulationDTypeForStructure(structure, instance.dtype) orelse continue;
        candidate.threads = spmvCooRepresentableThreads(candidate) orelse continue;
        if (!spmvCooInstanceValid(candidate)) continue;
        const target = try spmvCooFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return structure;
    }
    return null;
}

pub fn createSpmvCooFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: SpmvCoo,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!spmvCooInstanceValid(instance)) return error.UnsupportedSpmvCooInstance;
    const target = try spmvCooFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try spmvCooFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try spmvCooFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = spmvCooShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "spmv_coo",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f64 => try SpmvCooRuntimeFamilyF64.buildNamed(allocator, options.limits, entry_name, instance),
        .f32 => try SpmvCooRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .f16 => try SpmvCooRuntimeFamilyF16.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = spmv_coo_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spmvCooLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

fn spmvEllBlockCountChecked(instance: SpmvEll) ?u64 {
    if (instance.threads == 0) return null;
    const biased = std.math.add(u64, instance.rows, instance.threads - 1) catch return null;
    return biased / instance.threads;
}

pub fn spmvEllBlockCount(instance: SpmvEll) u64 {
    return spmvEllBlockCountChecked(instance).?;
}

fn spmvEllElementCountChecked(instance: SpmvEll) ?u64 {
    return std.math.mul(u64, instance.rows, instance.slots) catch null;
}

pub fn spmvEllInstanceValid(instance: SpmvEll) bool {
    const accumulation_dtype = spmvEllAccumulationDType(instance.dtype) orelse return false;
    if (instance.accumulation_dtype != accumulation_dtype) return false;
    if (instance.rows == 0 or instance.slots == 0 or instance.x_extent == 0) return false;
    if (instance.threads == 0 or instance.threads > spmv_ell_max_threads) return false;
    if (spmvEllLaunchExtentChecked(instance) == null) return false;
    if (spmvEllBlockCountChecked(instance) == null) return false;
    if (spmvEllElementCountChecked(instance) == null) return false;
    return switch (instance.structure) {
        .row_thread => true,
    };
}

fn spmvSellBlockCountChecked(instance: SpmvSell) ?u64 {
    if (instance.threads == 0) return null;
    const biased = std.math.add(u64, instance.rows, instance.threads - 1) catch return null;
    return biased / instance.threads;
}

pub fn spmvSellBlockCount(instance: SpmvSell) u64 {
    return spmvSellBlockCountChecked(instance).?;
}

fn spmvSellSliceCountChecked(instance: SpmvSell) ?u64 {
    if (instance.rows == 0 or instance.slice_size == 0) return null;
    const biased = std.math.add(u64, instance.rows, instance.slice_size - 1) catch return null;
    return biased / instance.slice_size;
}

pub fn spmvSellSliceCount(instance: SpmvSell) u64 {
    return spmvSellSliceCountChecked(instance).?;
}

pub fn spmvSellInstanceValid(instance: SpmvSell) bool {
    const accumulation_dtype = spmvSellAccumulationDType(instance.dtype) orelse return false;
    if (instance.accumulation_dtype != accumulation_dtype) return false;
    if (instance.rows == 0 or instance.slice_size == 0) return false;
    if (instance.values_size == 0 or instance.x_extent == 0) return false;
    if (instance.threads == 0 or instance.threads > spmv_sell_max_threads) return false;
    if (spmvSellLaunchExtentChecked(instance) == null) return false;
    if (spmvSellBlockCountChecked(instance) == null) return false;
    if (spmvSellSliceCountChecked(instance) == null) return false;
    return switch (instance.structure) {
        .row_thread => true,
    };
}

fn spmvEllAccumulationZero(inner_builder: anytype, instance: SpmvEll) !kernel.Value {
    return sparseFloatAccumulationZero(inner_builder, instance.accumulation_dtype);
}

fn spmvEllAccumulationValue(inner_builder: anytype, instance: SpmvEll, value: anytype) !kernel.Value {
    return sparseFloatAccumulationValue(inner_builder, instance.accumulation_dtype, value);
}

fn spmvEllOutputValue(inner_builder: anytype, instance: SpmvEll, value: kernel.Value) !kernel.Value {
    return sparseFloatOutputValue(inner_builder, instance.dtype, instance.accumulation_dtype, value);
}

fn spmv_ell_row_thread_value_apply(fold_builder: anytype, slot: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const slot_offset = try fold_builder.mul(slot, ctx.rows);
    const element = try fold_builder.add(slot_offset, ctx.row);
    const column_loaded = try ctx.args.param(.cols).load(fold_builder, element);
    const active = try fold_builder.compare(.ge, column_loaded.raw(), try fold_builder.constantInt(.i32, 0));
    const column_index = try fold_builder.castIndex(column_loaded.raw());
    const column_lower = try fold_builder.max(column_index, ctx.zero);
    const x_last = try fold_builder.sub(ctx.x_extent, ctx.one);
    const column = try fold_builder.min(column_lower, x_last);
    const x_value = try ctx.args.param(.x).load(fold_builder, column);
    const matrix_value = try ctx.args.param(.values).load(fold_builder, element);
    const matrix_acc = try spmvEllAccumulationValue(fold_builder, ctx.instance, matrix_value);
    const x_acc = try spmvEllAccumulationValue(fold_builder, ctx.instance, x_value);
    const product = try fold_builder.mul(matrix_acc, x_acc);
    const next = try fold_builder.add(current, product);
    return fold_builder.select(active, next, current);
}

fn spmvEllRowThreadValue(
    inner_builder: anytype,
    instance: SpmvEll,
    args: anytype,
    row: kernel.Value,
    rows: kernel.Value,
    slots: kernel.Value,
    x_extent: kernel.Value,
) !kernel.Value {
    const zero = try inner_builder.constantIndex(0);
    const one = try inner_builder.constantIndex(1);
    const acc_zero = try spmvEllAccumulationZero(inner_builder, instance);
    return inner_builder.fold(zero, slots, one, acc_zero, .{
        .instance = instance,
        .args = args,
        .row = row,
        .rows = rows,
        .x_extent = x_extent,
        .zero = zero,
        .one = one,
    }, spmv_ell_row_thread_value_apply);
}

fn spmv_ell_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const sum = try spmvEllRowThreadValue(
        inner_builder,
        ctx.instance,
        ctx.args,
        ctx.row,
        ctx.rows,
        ctx.slots,
        ctx.x_extent,
    );
    const result = try spmvEllOutputValue(inner_builder, ctx.instance, sum);
    try ctx.args.param(.y).store(inner_builder, result, ctx.row);
}

fn spmvEllRuntimeBody(k: anytype, spec: SpmvEll, args: anytype) !void {
    if (!spmvEllInstanceValid(spec)) return error.UnsupportedSpmvEllInstance;
    const row = try k.globalId(.x);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const slots = try k.castIndex(args.param(.slots).raw());
    const x_extent = try k.castIndex(args.param(.x_extent).raw());
    const active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(active, .{
        .args = args,
        .row = row,
        .rows = rows_extent,
        .slots = slots,
        .x_extent = x_extent,
        .instance = spec,
    }, spmv_ell_runtime_body_active);
}

fn spmvEllFamilySchedule(instance: SpmvEll) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn spmvEllRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_sparse_spmv_ell_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .y = kernel.dynamicBuffer(dtype),
            .cols = kernel.dynamicBuffer(.i32),
            .values = kernel.dynamicBuffer(dtype),
            .x = kernel.dynamicBuffer(dtype),
            .rows = kernel.scalar(.i32),
            .slots = kernel.scalar(.i32),
            .x_extent = kernel.scalar(.i32),
        },
        .Instance = SpmvEll,
        .schedule = spmvEllFamilySchedule,
        .body = spmvEllRuntimeBody,
    });
}

pub const SpmvEllRuntimeFamilyF64 = spmvEllRuntimeFamily(.f64);
pub const SpmvEllRuntimeFamilyF32 = spmvEllRuntimeFamily(.f32);
pub const SpmvEllRuntimeFamilyF16 = spmvEllRuntimeFamily(.f16);

pub fn spmvEllFamilyTarget(allocator: std.mem.Allocator, instance: SpmvEll) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sparse.spmv_ell_{s}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.threads, instance.dtype.name() },
    );
}

pub fn spmvEllFamilyEntryName(allocator: std.mem.Allocator, instance: SpmvEll) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sparse_spmv_ell_{s}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.threads, instance.dtype.name() },
    );
}

pub fn spmvEllRuntimeArguments(
    instance: SpmvEll,
    slots: u64,
    x_extent: u64,
) ![3]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.rows) },
        .{ .u32 = try runtimeExtentArgument(slots) },
        .{ .u32 = try runtimeExtentArgument(x_extent) },
    };
}

pub fn spmvEllMaxRows(instance: SpmvEll) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvEllMaxSlots(instance: SpmvEll) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvEllMaxXExtent(instance: SpmvEll) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvEllShapeProfileDimensions(instance: SpmvEll) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = spmvEllMaxRows(instance) },
        },
    };
}

fn spmvEllLaunch(instance: SpmvEll) !artifact_product.KernelCallLaunch {
    if (!spmvEllInstanceValid(instance)) return error.UnsupportedSpmvEllInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn spmvEllShapeFamily(backing_allocator: std.mem.Allocator, instance: SpmvEll) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "spmv_ell");
    errdefer builder.deinit();
    const rows = try builder.symbol(instance.row_axis);
    const slots = try builder.symbol(instance.slot_axis);
    const x_extent = try builder.symbol(instance.x_axis);
    const rows_expr = try builder.symbolExpression(rows);
    const slots_expr = try builder.symbolExpression(slots);
    const x_extent_expr = try builder.symbolExpression(x_extent);
    _ = try builder.tensor("cols", &.{ slots_expr, rows_expr });
    _ = try builder.tensor("values", &.{ slots_expr, rows_expr });
    _ = try builder.tensor("x", &.{x_extent_expr});
    _ = try builder.tensor("y", &.{rows_expr});
    try builder.assumeBounds(rows_expr, .{ .min = 1, .max = spmvEllMaxRows(instance) });
    try builder.assumeBounds(slots_expr, .{ .min = 1, .max = spmvEllMaxSlots(instance) });
    try builder.assumeBounds(x_extent_expr, .{ .min = 1, .max = spmvEllMaxXExtent(instance) });
    return builder.finish();
}

pub fn spmvEllFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: SpmvEll) !u64 {
    var family = try spmvEllShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn spmvEllTuningExtents(instance: SpmvEll) [3]u64 {
    return .{ instance.rows, instance.slots, instance.x_extent };
}

pub fn spmvEllTuningOperation(instance: SpmvEll) entry.Operation {
    _ = instance;
    return .{ .sparse = .ell_spmv };
}

pub fn spmvEllFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: SpmvEll,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try spmvEllFamilyFingerprint(backing_allocator, instance);
    const extents = spmvEllTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(spmvEllTuningOperation(instance)),
        instance.dtype,
        spmv_ell_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveSpmvEllThreads(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: SpmvEll,
) !?u32 {
    const key = try spmvEllFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    var default_candidate = instance;
    default_candidate.threads = spmvEllRepresentableThreads(default_candidate) orelse return null;
    if (spmvEllInstanceValid(default_candidate)) {
        const target = try spmvEllFamilyTarget(backing_allocator, default_candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return default_candidate.threads;
    }
    const thread_candidates = spmvEllThreadCandidatesForRows(instance.rows);
    for (thread_candidates.slice()) |threads| {
        var candidate = instance;
        candidate.threads = threads;
        candidate.threads = spmvEllRepresentableThreads(candidate) orelse continue;
        if (!spmvEllInstanceValid(candidate)) continue;
        const target = try spmvEllFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return candidate.threads;
    }
    return null;
}

pub fn createSpmvEllFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: SpmvEll,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!spmvEllInstanceValid(instance)) return error.UnsupportedSpmvEllInstance;
    const target = try spmvEllFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try spmvEllFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try spmvEllFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = spmvEllShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "spmv_ell",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f64 => try SpmvEllRuntimeFamilyF64.buildNamed(allocator, options.limits, entry_name, instance),
        .f32 => try SpmvEllRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .f16 => try SpmvEllRuntimeFamilyF16.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = spmv_ell_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spmvEllLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

fn spmvSellAccumulationZero(inner_builder: anytype, instance: SpmvSell) !kernel.Value {
    return sparseFloatAccumulationZero(inner_builder, instance.accumulation_dtype);
}

fn spmvSellAccumulationValue(inner_builder: anytype, instance: SpmvSell, value: anytype) !kernel.Value {
    return sparseFloatAccumulationValue(inner_builder, instance.accumulation_dtype, value);
}

fn spmvSellOutputValue(inner_builder: anytype, instance: SpmvSell, value: kernel.Value) !kernel.Value {
    return sparseFloatOutputValue(inner_builder, instance.dtype, instance.accumulation_dtype, value);
}

fn spmv_sell_row_thread_value_apply(fold_builder: anytype, element: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const column_loaded = try ctx.args.param(.cols).load(fold_builder, element);
    const active = try fold_builder.compare(.ge, column_loaded.raw(), try fold_builder.constantInt(.i32, 0));
    const column_index = try fold_builder.castIndex(column_loaded.raw());
    const column_lower = try fold_builder.max(column_index, ctx.zero);
    const x_last = try fold_builder.sub(ctx.x_extent, ctx.one);
    const column = try fold_builder.min(column_lower, x_last);
    const x_value = try ctx.args.param(.x).load(fold_builder, column);
    const matrix_value = try ctx.args.param(.values).load(fold_builder, element);
    const matrix_acc = try spmvSellAccumulationValue(fold_builder, ctx.instance, matrix_value);
    const x_acc = try spmvSellAccumulationValue(fold_builder, ctx.instance, x_value);
    const product = try fold_builder.mul(matrix_acc, x_acc);
    const next = try fold_builder.add(current, product);
    return fold_builder.select(active, next, current);
}

fn spmvSellRowThreadValue(
    inner_builder: anytype,
    instance: SpmvSell,
    args: anytype,
    row: kernel.Value,
    values_size: kernel.Value,
    x_extent: kernel.Value,
) !kernel.Value {
    const zero = try inner_builder.constantIndex(0);
    const one = try inner_builder.constantIndex(1);
    const slice_size = try inner_builder.constantIndex(@intCast(instance.slice_size));
    const slice = try inner_builder.div(row, slice_size);
    const slice_base = try inner_builder.mul(slice, slice_size);
    const local = try inner_builder.sub(row, slice_base);
    const next_slice = try inner_builder.add(slice, one);
    const begin_loaded = try args.param(.slice_offsets).load(inner_builder, slice);
    const end_loaded = try args.param(.slice_offsets).load(inner_builder, next_slice);
    const begin_index = try inner_builder.castIndex(begin_loaded.raw());
    const end_index = try inner_builder.castIndex(end_loaded.raw());
    const end_lower = try inner_builder.max(end_index, zero);
    const end_clamped = try inner_builder.min(end_lower, values_size);
    const begin_lower = try inner_builder.max(begin_index, zero);
    const begin_clamped = try inner_builder.min(begin_lower, end_clamped);
    const row_begin_unclamped = try inner_builder.add(begin_clamped, local);
    const row_begin = try inner_builder.min(row_begin_unclamped, end_clamped);

    const acc_zero = try spmvSellAccumulationZero(inner_builder, instance);
    return inner_builder.fold(row_begin, end_clamped, slice_size, acc_zero, .{
        .instance = instance,
        .args = args,
        .x_extent = x_extent,
        .zero = zero,
        .one = one,
    }, spmv_sell_row_thread_value_apply);
}

fn spmv_sell_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const one = try inner_builder.constantIndex(1);
    const bounded_x = try inner_builder.max(ctx.x_extent, one);
    const sum = try spmvSellRowThreadValue(
        inner_builder,
        ctx.instance,
        ctx.args,
        ctx.row,
        ctx.values_size,
        bounded_x,
    );
    const result = try spmvSellOutputValue(inner_builder, ctx.instance, sum);
    try ctx.args.param(.y).store(inner_builder, result, ctx.row);
}

fn spmvSellRuntimeBody(k: anytype, spec: SpmvSell, args: anytype) !void {
    if (!spmvSellInstanceValid(spec)) return error.UnsupportedSpmvSellInstance;
    const row = try k.globalId(.x);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const values_size = try k.castIndex(args.param(.values_size).raw());
    const x_extent = try k.castIndex(args.param(.x_extent).raw());
    const active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(active, .{
        .args = args,
        .row = row,
        .values_size = values_size,
        .x_extent = x_extent,
        .instance = spec,
    }, spmv_sell_runtime_body_active);
}

fn spmvSellFamilySchedule(instance: SpmvSell) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn spmvSellRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_sparse_spmv_sell_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .y = kernel.dynamicBuffer(dtype),
            .slice_offsets = kernel.dynamicBuffer(.i32),
            .cols = kernel.dynamicBuffer(.i32),
            .values = kernel.dynamicBuffer(dtype),
            .x = kernel.dynamicBuffer(dtype),
            .rows = kernel.scalar(.i32),
            .values_size = kernel.scalar(.i32),
            .x_extent = kernel.scalar(.i32),
        },
        .Instance = SpmvSell,
        .schedule = spmvSellFamilySchedule,
        .body = spmvSellRuntimeBody,
    });
}

pub const SpmvSellRuntimeFamilyF64 = spmvSellRuntimeFamily(.f64);
pub const SpmvSellRuntimeFamilyF32 = spmvSellRuntimeFamily(.f32);
pub const SpmvSellRuntimeFamilyF16 = spmvSellRuntimeFamily(.f16);

pub fn spmvSellFamilyTarget(allocator: std.mem.Allocator, instance: SpmvSell) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sparse.spmv_sell_{s}_slice{d}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.slice_size, instance.threads, instance.dtype.name() },
    );
}

pub fn spmvSellFamilyEntryName(allocator: std.mem.Allocator, instance: SpmvSell) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sparse_spmv_sell_{s}_slice{d}_family_{d}_{s}",
        .{ @tagName(instance.structure), instance.slice_size, instance.threads, instance.dtype.name() },
    );
}

pub fn spmvSellRuntimeArguments(
    instance: SpmvSell,
    values_size: u64,
    x_extent: u64,
) ![3]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.rows) },
        .{ .u32 = try runtimeExtentArgument(values_size) },
        .{ .u32 = try runtimeExtentArgument(x_extent) },
    };
}

pub fn spmvSellMaxRows(instance: SpmvSell) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvSellMaxValuesSize(instance: SpmvSell) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvSellMaxXExtent(instance: SpmvSell) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmvSellShapeProfileDimensions(instance: SpmvSell) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = .{ .min = 1, .max = spmvSellMaxRows(instance) },
        },
    };
}

fn spmvSellLaunch(instance: SpmvSell) !artifact_product.KernelCallLaunch {
    if (!spmvSellInstanceValid(instance)) return error.UnsupportedSpmvSellInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

pub fn spmvSellShapeFamily(backing_allocator: std.mem.Allocator, instance: SpmvSell) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "spmv_sell");
    errdefer builder.deinit();
    const rows = try builder.symbol(instance.row_axis);
    const slices = try builder.symbol(instance.slice_axis);
    const values_size = try builder.symbol(instance.value_axis);
    const x_extent = try builder.symbol(instance.x_axis);
    const rows_expr = try builder.symbolExpression(rows);
    const slices_expr = try builder.symbolExpression(slices);
    const slice_offsets_expr = try builder.addExpression(slices_expr, builder.constantExpression(1));
    const values_size_expr = try builder.symbolExpression(values_size);
    const x_extent_expr = try builder.symbolExpression(x_extent);
    _ = try builder.tensor("slice_offsets", &.{slice_offsets_expr});
    _ = try builder.tensor("cols", &.{values_size_expr});
    _ = try builder.tensor("values", &.{values_size_expr});
    _ = try builder.tensor("x", &.{x_extent_expr});
    _ = try builder.tensor("y", &.{rows_expr});
    const bounds = shape.Bounds{ .min = 1, .max = extent_mod.runtime_extent_max };
    try builder.assumeBounds(rows_expr, bounds);
    try builder.assumeBounds(slices_expr, bounds);
    try builder.assumeBounds(values_size_expr, bounds);
    try builder.assumeBounds(x_extent_expr, bounds);
    return builder.finish();
}

pub fn spmvSellFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: SpmvSell) !u64 {
    var family = try spmvSellShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn spmvSellTuningExtents(instance: SpmvSell) [4]u64 {
    return .{ instance.rows, instance.slice_size, instance.values_size, instance.x_extent };
}

pub fn spmvSellTuningOperation(instance: SpmvSell) entry.Operation {
    _ = instance;
    return .{ .sparse = .sell_spmv };
}

pub fn spmvSellFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: SpmvSell,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try spmvSellFamilyFingerprint(backing_allocator, instance);
    const extents = spmvSellTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(spmvSellTuningOperation(instance)),
        instance.dtype,
        spmv_sell_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveSpmvSellThreads(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: SpmvSell,
) !?u32 {
    const key = try spmvSellFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    var default_candidate = instance;
    default_candidate.threads = spmvSellRepresentableThreads(default_candidate) orelse return null;
    if (spmvSellInstanceValid(default_candidate)) {
        const target = try spmvSellFamilyTarget(backing_allocator, default_candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return default_candidate.threads;
    }
    const thread_candidates = spmvSellThreadCandidatesForRows(instance.rows);
    for (thread_candidates.slice()) |threads| {
        var candidate = instance;
        candidate.threads = threads;
        candidate.threads = spmvSellRepresentableThreads(candidate) orelse continue;
        if (!spmvSellInstanceValid(candidate)) continue;
        const target = try spmvSellFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return candidate.threads;
    }
    return null;
}

pub fn createSpmvSellFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: SpmvSell,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!spmvSellInstanceValid(instance)) return error.UnsupportedSpmvSellInstance;
    const target = try spmvSellFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try spmvSellFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try spmvSellFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = spmvSellShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "spmv_sell",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f64 => try SpmvSellRuntimeFamilyF64.buildNamed(allocator, options.limits, entry_name, instance),
        .f32 => try SpmvSellRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .f16 => try SpmvSellRuntimeFamilyF16.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = spmv_sell_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spmvSellLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

fn spmmCsrThreadCountChecked(instance: SpmmCsr) ?u32 {
    if (instance.threads.x == 0 or instance.threads.y == 0) return null;
    const count = std.math.mul(u32, instance.threads.x, instance.threads.y) catch return null;
    if (count == 0 or count > spmm_csr_max_threads) return null;
    return count;
}

fn spmmCsrBlockCountAxisChecked(extent: u64, threads: u32) ?u64 {
    if (extent == 0 or threads == 0) return null;
    const biased = std.math.add(u64, extent, threads - 1) catch return null;
    const blocks = biased / threads;
    if (blocks > std.math.maxInt(u32)) return null;
    return blocks;
}

pub fn spmmCsrBlockCountX(instance: SpmmCsr) u64 {
    return spmmCsrBlockCountXChecked(instance).?;
}

fn spmmCsrBlockCountXChecked(instance: SpmmCsr) ?u64 {
    return spmmCsrBlockCountAxisChecked(instance.columns, instance.threads.x);
}

pub fn spmmCsrBlockCountY(instance: SpmmCsr) u64 {
    return spmmCsrBlockCountYChecked(instance).?;
}

fn spmmCsrBlockCountYChecked(instance: SpmmCsr) ?u64 {
    return spmmCsrBlockCountAxisChecked(instance.rows, instance.threads.y);
}

pub fn spmmCsrInstanceValid(instance: SpmmCsr) bool {
    const accumulation_dtype = spmmCsrAccumulationDType(instance.dtype) orelse return false;
    if (instance.accumulation_dtype != accumulation_dtype) return false;
    if (instance.rows == 0 or instance.columns == 0) return false;
    if (instance.nnz == 0 or instance.x_extent == 0) return false;
    if (spmmCsrThreadCountChecked(instance) == null) return false;
    if (spmmCsrBlockCountXChecked(instance) == null) return false;
    if (spmmCsrBlockCountYChecked(instance) == null) return false;
    return switch (instance.structure) {
        .row_column_thread => true,
    };
}

fn spmmCsrAccumulationZero(inner_builder: anytype, instance: SpmmCsr) !kernel.Value {
    return sparseFloatAccumulationZero(inner_builder, instance.accumulation_dtype);
}

fn spmmCsrAccumulationValue(inner_builder: anytype, instance: SpmmCsr, value: anytype) !kernel.Value {
    return sparseFloatAccumulationValue(inner_builder, instance.accumulation_dtype, value);
}

fn spmmCsrOutputValue(inner_builder: anytype, instance: SpmmCsr, value: kernel.Value) !kernel.Value {
    return sparseFloatOutputValue(inner_builder, instance.dtype, instance.accumulation_dtype, value);
}

fn spmmCsrOutputIndex(inner_builder: anytype, row: kernel.Value, column: kernel.Value, columns: kernel.Value) !kernel.Value {
    const row_offset = try inner_builder.mul(row, columns);
    return inner_builder.add(row_offset, column);
}

fn spmm_csr_cell_value_apply(fold_builder: anytype, element: kernel.Value, current: kernel.Value, ctx: anytype) !kernel.Value {
    const column_loaded = try ctx.args.param(.cols).load(fold_builder, element);
    const column_index = try fold_builder.castIndex(column_loaded.raw());
    const column_lower = try fold_builder.max(column_index, ctx.zero);
    const x_last = try fold_builder.sub(ctx.x_extent, ctx.one);
    const sparse_column = try fold_builder.min(column_lower, x_last);
    const x_row_offset = try fold_builder.mul(sparse_column, ctx.columns);
    const x_index = try fold_builder.add(x_row_offset, ctx.column);
    const x_value = try ctx.args.param(.x).load(fold_builder, x_index);
    const matrix_value = try ctx.args.param(.values).load(fold_builder, element);
    const matrix_acc = try spmmCsrAccumulationValue(fold_builder, ctx.instance, matrix_value);
    const x_acc = try spmmCsrAccumulationValue(fold_builder, ctx.instance, x_value);
    const product = try fold_builder.mul(matrix_acc, x_acc);
    return fold_builder.add(current, product);
}

fn spmmCsrCellValue(
    inner_builder: anytype,
    instance: SpmmCsr,
    args: anytype,
    row: kernel.Value,
    column: kernel.Value,
    nnz: kernel.Value,
    x_extent: kernel.Value,
    columns: kernel.Value,
) !kernel.Value {
    const one = try inner_builder.constantIndex(1);
    const next = try inner_builder.add(row, one);
    const begin_loaded = try args.param(.row_ptr).load(inner_builder, row);
    const end_loaded = try args.param(.row_ptr).load(inner_builder, next);
    const begin_index = try inner_builder.castIndex(begin_loaded.raw());
    const end_index = try inner_builder.castIndex(end_loaded.raw());
    const zero = try inner_builder.constantIndex(0);
    const end_lower = try inner_builder.max(end_index, zero);
    const end_clamped = try inner_builder.min(end_lower, nnz);
    const begin_lower = try inner_builder.max(begin_index, zero);
    const begin_clamped = try inner_builder.min(begin_lower, end_clamped);

    const acc_zero = try spmmCsrAccumulationZero(inner_builder, instance);
    return inner_builder.fold(begin_clamped, end_clamped, one, acc_zero, .{
        .instance = instance,
        .args = args,
        .column = column,
        .columns = columns,
        .x_extent = x_extent,
        .zero = zero,
        .one = one,
    }, spmm_csr_cell_value_apply);
}

fn spmm_csr_runtime_body_row_active(inner_builder: anytype, ctx: anytype) !void {
    const column_active = try inner_builder.compare(.lt, ctx.column, ctx.columns);
    try inner_builder.guardDo(column_active, ctx, spmm_csr_runtime_body_column_active);
}

fn spmm_csr_runtime_body_column_active(active_builder: anytype, active_ctx: anytype) !void {
    const sum = try spmmCsrCellValue(
        active_builder,
        active_ctx.instance,
        active_ctx.args,
        active_ctx.row,
        active_ctx.column,
        active_ctx.nnz,
        active_ctx.x_extent,
        active_ctx.columns,
    );
    const result = try spmmCsrOutputValue(active_builder, active_ctx.instance, sum);
    const output_index = try spmmCsrOutputIndex(active_builder, active_ctx.row, active_ctx.column, active_ctx.columns);
    try active_ctx.args.param(.y).store(active_builder, result, output_index);
}

fn spmmCsrRuntimeBody(k: anytype, spec: SpmmCsr, args: anytype) !void {
    if (!spmmCsrInstanceValid(spec)) return error.UnsupportedSpmmCsrInstance;
    const row = try k.globalId(.y);
    const column = try k.globalId(.x);
    const rows_extent = try k.castIndex(args.param(.rows).raw());
    const columns_extent = try k.castIndex(args.param(.columns).raw());
    const nnz = try k.castIndex(args.param(.nnz).raw());
    const x_extent = try k.castIndex(args.param(.x_extent).raw());
    const row_active = try k.compare(.lt, row, rows_extent);
    try k.guardDo(row_active, .{
        .args = args,
        .row = row,
        .column = column,
        .columns = columns_extent,
        .nnz = nnz,
        .x_extent = x_extent,
        .instance = spec,
    }, spmm_csr_runtime_body_row_active);
}

fn spmmCsrFamilySchedule(instance: SpmmCsr) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads.x, .y = instance.threads.y });
}

fn spmmCsrRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_sparse_spmm_csr_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .y = kernel.dynamicBuffer(dtype),
            .row_ptr = kernel.dynamicBuffer(.i32),
            .cols = kernel.dynamicBuffer(.i32),
            .values = kernel.dynamicBuffer(dtype),
            .x = kernel.dynamicBuffer(dtype),
            .rows = kernel.scalar(.i32),
            .nnz = kernel.scalar(.i32),
            .x_extent = kernel.scalar(.i32),
            .columns = kernel.scalar(.i32),
        },
        .Instance = SpmmCsr,
        .schedule = spmmCsrFamilySchedule,
        .body = spmmCsrRuntimeBody,
    });
}

pub const SpmmCsrRuntimeFamilyF64 = spmmCsrRuntimeFamily(.f64);
pub const SpmmCsrRuntimeFamilyF32 = spmmCsrRuntimeFamily(.f32);
pub const SpmmCsrRuntimeFamilyF16 = spmmCsrRuntimeFamily(.f16);

pub fn spmmCsrFamilyTarget(allocator: std.mem.Allocator, instance: SpmmCsr) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.sparse.spmm_csr_{s}_family_{d}x{d}_{s}",
        .{ @tagName(instance.structure), instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn spmmCsrFamilyEntryName(allocator: std.mem.Allocator, instance: SpmmCsr) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_sparse_spmm_csr_{s}_family_{d}x{d}_{s}",
        .{ @tagName(instance.structure), instance.threads.x, instance.threads.y, instance.dtype.name() },
    );
}

pub fn spmmCsrRuntimeArguments(
    instance: SpmmCsr,
    nnz: u64,
    x_extent: u64,
    columns: u64,
) ![4]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.rows) },
        .{ .u32 = try runtimeExtentArgument(nnz) },
        .{ .u32 = try runtimeExtentArgument(x_extent) },
        .{ .u32 = try runtimeExtentArgument(columns) },
    };
}

pub fn spmmCsrMaxRows(instance: SpmmCsr) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmmCsrMaxColumns(instance: SpmmCsr) u64 {
    _ = instance;
    return extent_mod.runtime_extent_max;
}

pub fn spmmCsrShapeProfileDimensions(instance: SpmmCsr) [2]artifact_product.KernelCallShapeProfileDimension {
    const bounds = shape.Bounds{ .min = 1, .max = extent_mod.runtime_extent_max };
    return .{
        .{
            .name = instance.row_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = bounds,
        },
        .{
            .name = instance.column_axis,
            .runtime_scalar_argument_index = 3,
            .bounds = bounds,
        },
    };
}

fn spmmCsrLaunch(instance: SpmmCsr) !artifact_product.KernelCallLaunch {
    if (!spmmCsrInstanceValid(instance)) return error.UnsupportedSpmmCsrInstance;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 3, .divisor = instance.threads.x } },
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = instance.threads.y } },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads.x, instance.threads.y, 1 },
    } };
}

pub fn spmmCsrShapeFamily(backing_allocator: std.mem.Allocator, instance: SpmmCsr) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, "spmm_csr");
    errdefer builder.deinit();
    const rows = try builder.symbol(instance.row_axis);
    const nnz = try builder.symbol(spmv_csr_nonzero_axis);
    const x_extent = try builder.symbol(instance.x_axis);
    const columns = try builder.symbol(instance.column_axis);
    const rows_expr = try builder.symbolExpression(rows);
    const row_ptr_expr = try builder.addExpression(rows_expr, builder.constantExpression(1));
    const nnz_expr = try builder.symbolExpression(nnz);
    const x_extent_expr = try builder.symbolExpression(x_extent);
    const columns_expr = try builder.symbolExpression(columns);
    _ = try builder.tensor("row_ptr", &.{row_ptr_expr});
    _ = try builder.tensor("cols", &.{nnz_expr});
    _ = try builder.tensor("values", &.{nnz_expr});
    _ = try builder.tensor("x", &.{ x_extent_expr, columns_expr });
    _ = try builder.tensor("y", &.{ rows_expr, columns_expr });
    const bounds = shape.Bounds{ .min = 1, .max = extent_mod.runtime_extent_max };
    try builder.assumeBounds(rows_expr, bounds);
    try builder.assumeBounds(nnz_expr, bounds);
    try builder.assumeBounds(x_extent_expr, bounds);
    try builder.assumeBounds(columns_expr, bounds);
    return builder.finish();
}

pub fn spmmCsrFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: SpmmCsr) !u64 {
    var family = try spmmCsrShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn spmmCsrTuningExtents(instance: SpmmCsr) [4]u64 {
    return .{ instance.rows, instance.columns, instance.nnz, instance.x_extent };
}

pub fn spmmCsrTuningOperation(instance: SpmmCsr) entry.Operation {
    _ = instance;
    return .{ .sparse = .csr_spmm };
}

pub fn spmmCsrFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: SpmmCsr,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try spmmCsrFamilyFingerprint(backing_allocator, instance);
    const extents = spmmCsrTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(spmmCsrTuningOperation(instance)),
        instance.dtype,
        spmm_csr_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn resolveSpmmCsrThreads(
    backing_allocator: std.mem.Allocator,
    reader: tuning.FamilyTuningReader,
    instance: SpmmCsr,
) !?entry.Threads2D {
    const key = try spmmCsrFamilyTuningKey(backing_allocator, reader.device_fingerprint, instance);
    const record = reader.table.find(key) orelse return null;
    var default_candidate = instance;
    default_candidate.threads = spmmCsrRepresentableThreads(default_candidate) orelse return null;
    {
        const target = try spmmCsrFamilyTarget(backing_allocator, default_candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return default_candidate.threads;
    }
    const thread_candidates = spmmCsrThreadCandidatesForExtents(instance.rows, instance.columns);
    for (thread_candidates.slice()) |threads| {
        var candidate = instance;
        candidate.threads = threads;
        candidate.threads = spmmCsrRepresentableThreads(candidate) orelse continue;
        const target = try spmmCsrFamilyTarget(backing_allocator, candidate);
        defer backing_allocator.free(target);
        if (std.mem.eql(u8, target, record.target)) return candidate.threads;
    }
    return null;
}

pub fn createSpmmCsrFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: SpmmCsr,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!spmmCsrInstanceValid(instance)) return error.UnsupportedSpmmCsrInstance;
    const target = try spmmCsrFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try spmmCsrFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try spmmCsrFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = spmmCsrShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "spmm_csr",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f64 => try SpmmCsrRuntimeFamilyF64.buildNamed(allocator, options.limits, entry_name, instance),
        .f32 => try SpmmCsrRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .f16 => try SpmmCsrRuntimeFamilyF16.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = spmm_csr_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try spmmCsrLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 4 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

const testing = std.testing;

fn sparseFamilyTuningTestCapabilities(device_id: u32) gpu.BackendCapabilities {
    return .{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "sparse-family-tuning-test-device",
        .vendor_id = 0x10de,
        .device_id = device_id,
    } };
}

fn spmvTestValue(comptime dtype: DType, value: f32) dtype.ZigType() {
    return switch (dtype) {
        .f64 => @floatCast(value),
        .f32 => value,
        .f16 => @floatCast(value),
        else => @compileError("unsupported SpMV CSR test dtype"),
    };
}

fn spmvTestFloat(comptime dtype: DType, value: dtype.ZigType()) f32 {
    return switch (dtype) {
        .f64 => @floatCast(value),
        .f32 => value,
        .f16 => @floatCast(value),
        else => @compileError("unsupported SpMV CSR test dtype"),
    };
}

fn expectSpmvCsrMatchesDense(comptime dtype: DType, comptime structure: SpmvCsrStructure, comptime threads: u32) !void {
    const allocator = testing.allocator;
    const Scalar = dtype.ZigType();
    const rows: usize = 70;
    const cols_n: usize = 40;
    const instance = SpmvCsr{
        .rows = rows,
        .dtype = dtype,
        .accumulation_dtype = spmvCsrAccumulationDType(dtype).?,
        .threads = threads,
        .structure = structure,
    };
    const blocks: u32 = @intCast(spmvCsrBlockCount(instance));
    try testing.expect(blocks > 1);

    var row_ptr: [rows + 1]i32 = undefined;
    var cols_storage: [rows * 8]i32 = undefined;
    var values_storage: [rows * 8]Scalar = undefined;
    var seed: u32 = 0x2545f491;
    var nnz: usize = 0;
    row_ptr[0] = 0;
    for (0..rows) |row| {
        const row_nnz: usize = switch (row % 5) {
            0 => 0,
            1 => 1,
            2 => 3,
            3 => 8,
            else => 5,
        };
        var produced: usize = 0;
        while (produced < row_nnz) : (produced += 1) {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            cols_storage[nnz] = @intCast(seed % cols_n);
            values_storage[nnz] = spmvTestValue(dtype, @floatFromInt((seed >> 8) % 9 + 1));
            nnz += 1;
        }
        row_ptr[row + 1] = @intCast(nnz);
    }

    var x: [cols_n]Scalar = undefined;
    for (&x, 0..) |*value, index| value.* = spmvTestValue(dtype, @floatFromInt((index % 7) + 1));

    var y = @as([rows]Scalar, @splat(spmvTestValue(dtype, -1)));
    var graph = switch (dtype) {
        .f64 => try SpmvCsrRuntimeFamilyF64.build(allocator, SpmvCsrRuntimeFamilyF64.Limits.testing, instance),
        .f32 => try SpmvCsrRuntimeFamilyF32.build(allocator, SpmvCsrRuntimeFamilyF32.Limits.testing, instance),
        .f16 => try SpmvCsrRuntimeFamilyF16.build(allocator, SpmvCsrRuntimeFamilyF16.Limits.testing, instance),
        else => @compileError("unsupported SpMV CSR test dtype"),
    };
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(Scalar, y[0..]),
        kernel.argumentBuffer(i32, row_ptr[0..]),
        kernel.argumentBuffer(i32, cols_storage[0..nnz]),
        kernel.argumentBuffer(Scalar, values_storage[0..nnz]),
        kernel.argumentBuffer(Scalar, x[0..]),
        kernel.argumentI32(@intCast(rows)),
        kernel.argumentI32(@intCast(nnz)),
        kernel.argumentI32(@intCast(cols_n)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (0..rows) |row| {
        var expected: f32 = 0;
        const begin: usize = @intCast(row_ptr[row]);
        const end: usize = @intCast(row_ptr[row + 1]);
        for (begin..end) |element| {
            expected += spmvTestFloat(dtype, values_storage[element]) * spmvTestFloat(dtype, x[@intCast(cols_storage[element])]);
        }
        const expected_output = spmvTestFloat(dtype, spmvTestValue(dtype, expected));
        try testing.expectApproxEqAbs(expected_output, spmvTestFloat(dtype, y[row]), 0.001);
    }
}

test "sparse spmv csr matches the dense reference on both structures" {
    try expectSpmvCsrMatchesDense(.f64, .row_warp, 64);
    try expectSpmvCsrMatchesDense(.f64, .row_thread, 64);
    try expectSpmvCsrMatchesDense(.f32, .row_warp, 64);
    try expectSpmvCsrMatchesDense(.f32, .row_thread, 64);
    try expectSpmvCsrMatchesDense(.f32, .row_thread, 48);
    try expectSpmvCsrMatchesDense(.f16, .row_warp, 64);
    try expectSpmvCsrMatchesDense(.f16, .row_thread, 64);
}

fn expectSpmvCooMatchesDense(comptime dtype: DType, comptime structure: SpmvCooStructure, threads: u32) !void {
    const Scalar = dtype.ZigType();
    const allocator = testing.allocator;
    const rows: usize = 17;
    const nnz: usize = 37;
    const x_extent: usize = 13;
    const instance = SpmvCoo{
        .rows = rows,
        .nnz = nnz,
        .x_extent = x_extent,
        .dtype = dtype,
        .accumulation_dtype = spmvCooAccumulationDTypeForStructure(structure, dtype).?,
        .threads = threads,
        .structure = structure,
    };
    const blocks: u32 = @intCast(spmvCooBlockCount(instance));
    try testing.expect(blocks > 1);

    var row_indices: [nnz]i32 = undefined;
    var cols_storage: [nnz]i32 = undefined;
    var values_storage: [nnz]Scalar = undefined;
    for (0..nnz) |element| {
        row_indices[element] = @intCast((element * 5 + 2) % rows);
        cols_storage[element] = @intCast((element * 7 + 1) % x_extent);
        values_storage[element] = spmvTestValue(dtype, @floatFromInt((element % 9) + 1));
    }
    row_indices[3] = -1;
    row_indices[9] = @intCast(rows + 5);
    cols_storage[14] = -4;
    cols_storage[21] = @intCast(x_extent + 3);
    row_indices[24] = 4;
    row_indices[25] = 4;
    cols_storage[24] = 6;
    cols_storage[25] = 6;

    var x: [x_extent]Scalar = undefined;
    for (&x, 0..) |*value, index| value.* = spmvTestValue(dtype, @floatFromInt((index % 5) + 1));

    var y: [rows]Scalar = undefined;
    var expected: [rows]f32 = undefined;
    for (&y, &expected, 0..) |*actual, *want, row| {
        const seed = @as(f32, @floatFromInt(row % 3)) * 0.25;
        actual.* = spmvTestValue(dtype, seed);
        want.* = seed;
    }

    var graph = switch (dtype) {
        .f64 => try SpmvCooRuntimeFamilyF64.build(allocator, SpmvCooRuntimeFamilyF64.Limits.testing, instance),
        .f32 => try SpmvCooRuntimeFamilyF32.build(allocator, SpmvCooRuntimeFamilyF32.Limits.testing, instance),
        .f16 => try SpmvCooRuntimeFamilyF16.build(allocator, SpmvCooRuntimeFamilyF16.Limits.testing, instance),
        else => @compileError("unsupported SpMV COO test dtype"),
    };
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(Scalar, y[0..]),
        kernel.argumentBuffer(i32, row_indices[0..]),
        kernel.argumentBuffer(i32, cols_storage[0..]),
        kernel.argumentBuffer(Scalar, values_storage[0..]),
        kernel.argumentBuffer(Scalar, x[0..]),
        kernel.argumentI32(@intCast(rows)),
        kernel.argumentI32(@intCast(nnz)),
        kernel.argumentI32(@intCast(x_extent)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (0..nnz) |element| {
        const row = row_indices[element];
        const col = cols_storage[element];
        if (row < 0 or row >= @as(i32, @intCast(rows)) or col < 0 or col >= @as(i32, @intCast(x_extent))) continue;
        expected[@intCast(row)] += spmvTestFloat(dtype, values_storage[element]) * spmvTestFloat(dtype, x[@intCast(col)]);
    }

    for (y, expected) |actual, want| {
        const expected_output = spmvTestFloat(dtype, spmvTestValue(dtype, want));
        try testing.expectApproxEqAbs(expected_output, spmvTestFloat(dtype, actual), 0.001);
    }
}

test "sparse spmv coo accumulates matching the dense reference" {
    try expectSpmvCooMatchesDense(.f32, .element_thread, 16);
    try expectSpmvCooMatchesDense(.f32, .row_thread, 8);
    try expectSpmvCooMatchesDense(.f16, .row_thread, 8);
    try expectSpmvCooMatchesDense(.f64, .row_thread, 8);
}

fn expectSpmvEllMatchesDense(comptime dtype: DType) !void {
    const allocator = testing.allocator;
    const Scalar = dtype.ZigType();
    const rows: usize = 70;
    const slots: usize = 8;
    const x_extent: usize = 40;
    const instance = SpmvEll{
        .rows = rows,
        .slots = slots,
        .x_extent = x_extent,
        .dtype = dtype,
        .accumulation_dtype = spmvEllAccumulationDType(dtype).?,
        .threads = 48,
    };
    const blocks: u32 = @intCast(spmvEllBlockCount(instance));
    try testing.expect(blocks > 1);

    var cols_storage = @as([(rows * slots)]i32, @splat(-1));
    var values_storage = @as([(rows * slots)]Scalar, @splat(spmvTestValue(dtype, 97)));
    var seed: u32 = 0x6a09e667;
    for (0..rows) |row| {
        const row_slots: usize = switch (row % 5) {
            0 => 0,
            1 => 1,
            2 => 3,
            3 => slots,
            else => 5,
        };
        for (0..row_slots) |slot| {
            seed = seed *% 22695477 +% 1;
            const element = slot * rows + row;
            cols_storage[element] = @intCast(seed % x_extent);
            values_storage[element] = spmvTestValue(dtype, @floatFromInt((seed >> 9) % 7 + 1));
        }
    }

    var x: [x_extent]Scalar = undefined;
    for (&x, 0..) |*value, index| value.* = spmvTestValue(dtype, @floatFromInt((index % 11) + 1));

    var y = @as([rows]Scalar, @splat(spmvTestValue(dtype, -1)));
    var graph = switch (dtype) {
        .f64 => try SpmvEllRuntimeFamilyF64.build(allocator, SpmvEllRuntimeFamilyF64.Limits.testing, instance),
        .f32 => try SpmvEllRuntimeFamilyF32.build(allocator, SpmvEllRuntimeFamilyF32.Limits.testing, instance),
        .f16 => try SpmvEllRuntimeFamilyF16.build(allocator, SpmvEllRuntimeFamilyF16.Limits.testing, instance),
        else => @compileError("unsupported SpMV ELL test dtype"),
    };
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(Scalar, y[0..]),
        kernel.argumentBuffer(i32, cols_storage[0..]),
        kernel.argumentBuffer(Scalar, values_storage[0..]),
        kernel.argumentBuffer(Scalar, x[0..]),
        kernel.argumentI32(@intCast(rows)),
        kernel.argumentI32(@intCast(slots)),
        kernel.argumentI32(@intCast(x_extent)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (0..rows) |row| {
        var expected: f32 = 0;
        for (0..slots) |slot| {
            const element = slot * rows + row;
            const column = cols_storage[element];
            if (column >= 0) {
                expected += spmvTestFloat(dtype, values_storage[element]) * spmvTestFloat(dtype, x[@intCast(column)]);
            }
        }
        const expected_output = spmvTestFloat(dtype, spmvTestValue(dtype, expected));
        try testing.expectApproxEqAbs(expected_output, spmvTestFloat(dtype, y[row]), 0.001);
    }
}

test "sparse spmv ell matches the dense reference with padded slots" {
    try expectSpmvEllMatchesDense(.f64);
    try expectSpmvEllMatchesDense(.f32);
    try expectSpmvEllMatchesDense(.f16);
}

fn expectSpmvSellMatchesDense(comptime dtype: DType) !void {
    const allocator = testing.allocator;
    const Scalar = dtype.ZigType();
    const rows: usize = 70;
    const slice_size: usize = 8;
    const slices: usize = (rows + slice_size - 1) / slice_size;
    const x_extent: usize = 40;

    var slice_offsets: [slices + 1]i32 = undefined;
    var cols_storage = @as([(slices * slice_size * 8)]i32, @splat(-1));
    var values_storage = @as([(slices * slice_size * 8)]Scalar, @splat(spmvTestValue(dtype, 97)));
    var seed: u32 = 0x243f6a88;
    var values_size: usize = 0;
    for (0..slices) |slice| {
        slice_offsets[slice] = @intCast(values_size);
        var slice_slots: usize = 0;
        for (0..slice_size) |local| {
            const row = slice * slice_size + local;
            if (row < rows) slice_slots = @max(slice_slots, sellTestRowSlots(row));
        }
        for (0..slice_slots) |slot| {
            for (0..slice_size) |local| {
                const row = slice * slice_size + local;
                const element = values_size + slot * slice_size + local;
                if (row < rows and slot < sellTestRowSlots(row)) {
                    seed = seed *% 1103515245 +% 12345;
                    cols_storage[element] = @intCast(seed % x_extent);
                    values_storage[element] = spmvTestValue(dtype, @floatFromInt((seed >> 10) % 9 + 1));
                }
            }
        }
        values_size += slice_slots * slice_size;
    }
    slice_offsets[slices] = @intCast(values_size);

    const instance = SpmvSell{
        .rows = rows,
        .slice_size = slice_size,
        .values_size = values_size,
        .x_extent = x_extent,
        .dtype = dtype,
        .accumulation_dtype = spmvSellAccumulationDType(dtype).?,
        .threads = 48,
    };
    const blocks: u32 = @intCast(spmvSellBlockCount(instance));
    try testing.expect(blocks > 1);
    try testing.expectEqual(@as(u64, slices), spmvSellSliceCount(instance));

    var x: [x_extent]Scalar = undefined;
    for (&x, 0..) |*value, index| value.* = spmvTestValue(dtype, @floatFromInt((index % 11) + 1));

    var y = @as([rows]Scalar, @splat(spmvTestValue(dtype, -1)));
    var graph = switch (dtype) {
        .f64 => try SpmvSellRuntimeFamilyF64.build(allocator, SpmvSellRuntimeFamilyF64.Limits.testing, instance),
        .f32 => try SpmvSellRuntimeFamilyF32.build(allocator, SpmvSellRuntimeFamilyF32.Limits.testing, instance),
        .f16 => try SpmvSellRuntimeFamilyF16.build(allocator, SpmvSellRuntimeFamilyF16.Limits.testing, instance),
        else => @compileError("unsupported SpMV SELL test dtype"),
    };
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(Scalar, y[0..]),
        kernel.argumentBuffer(i32, slice_offsets[0..]),
        kernel.argumentBuffer(i32, cols_storage[0..values_size]),
        kernel.argumentBuffer(Scalar, values_storage[0..values_size]),
        kernel.argumentBuffer(Scalar, x[0..]),
        kernel.argumentI32(@intCast(rows)),
        kernel.argumentI32(@intCast(values_size)),
        kernel.argumentI32(@intCast(x_extent)),
    }, .{
        .grid = .{ blocks, 1, 1 },
        .block = .{ instance.threads, 1, 1 },
    });

    for (0..rows) |row| {
        const slice = row / slice_size;
        const local = row - slice * slice_size;
        const begin: usize = @intCast(slice_offsets[slice]);
        const end: usize = @intCast(slice_offsets[slice + 1]);
        var expected: f32 = 0;
        var element = begin + local;
        while (element < end) : (element += slice_size) {
            const column = cols_storage[element];
            if (column >= 0) {
                expected += spmvTestFloat(dtype, values_storage[element]) * spmvTestFloat(dtype, x[@intCast(column)]);
            }
        }
        const expected_output = spmvTestFloat(dtype, spmvTestValue(dtype, expected));
        try testing.expectApproxEqAbs(expected_output, spmvTestFloat(dtype, y[row]), 0.001);
    }
}

fn sellTestRowSlots(row: usize) usize {
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

test "sparse spmv sell matches the dense reference with sliced padding" {
    try expectSpmvSellMatchesDense(.f64);
    try expectSpmvSellMatchesDense(.f32);
    try expectSpmvSellMatchesDense(.f16);
}

fn expectSpmmCsrMatchesDense(comptime dtype: DType) !void {
    const allocator = testing.allocator;
    const Scalar = dtype.ZigType();
    const rows: usize = 37;
    const columns: usize = 11;
    const x_extent: usize = 23;
    const instance = SpmmCsr{
        .rows = rows,
        .columns = columns,
        .x_extent = x_extent,
        .dtype = dtype,
        .accumulation_dtype = spmmCsrAccumulationDType(dtype).?,
        .threads = .{ .x = 8, .y = 4 },
    };

    var row_ptr: [rows + 1]i32 = undefined;
    var cols_storage: [rows * 6]i32 = undefined;
    var values_storage: [rows * 6]Scalar = undefined;
    var seed: u32 = 0x9e3779b9;
    var nnz: usize = 0;
    row_ptr[0] = 0;
    for (0..rows) |row| {
        const row_nnz: usize = switch (row % 5) {
            0 => 0,
            1 => 1,
            2 => 4,
            3 => 6,
            else => 3,
        };
        var produced: usize = 0;
        while (produced < row_nnz) : (produced += 1) {
            seed = seed *% 1664525 +% 1013904223;
            cols_storage[nnz] = @intCast(seed % x_extent);
            values_storage[nnz] = spmvTestValue(dtype, @floatFromInt((seed >> 9) % 7 + 1));
            nnz += 1;
        }
        row_ptr[row + 1] = @intCast(nnz);
    }

    var x: [x_extent * columns]Scalar = undefined;
    for (&x, 0..) |*value, index| value.* = spmvTestValue(dtype, @floatFromInt((index % 13) + 1));

    var y = @as([(rows * columns)]Scalar, @splat(spmvTestValue(dtype, -1)));
    var graph = switch (dtype) {
        .f64 => try SpmmCsrRuntimeFamilyF64.build(allocator, SpmmCsrRuntimeFamilyF64.Limits.testing, instance),
        .f32 => try SpmmCsrRuntimeFamilyF32.build(allocator, SpmmCsrRuntimeFamilyF32.Limits.testing, instance),
        .f16 => try SpmmCsrRuntimeFamilyF16.build(allocator, SpmmCsrRuntimeFamilyF16.Limits.testing, instance),
        else => @compileError("unsupported SpMM CSR test dtype"),
    };
    defer graph.deinit();
    try graph.runCpuWithLaunch(allocator, &.{
        kernel.argumentBuffer(Scalar, y[0..]),
        kernel.argumentBuffer(i32, row_ptr[0..]),
        kernel.argumentBuffer(i32, cols_storage[0..nnz]),
        kernel.argumentBuffer(Scalar, values_storage[0..nnz]),
        kernel.argumentBuffer(Scalar, x[0..]),
        kernel.argumentI32(@intCast(rows)),
        kernel.argumentI32(@intCast(nnz)),
        kernel.argumentI32(@intCast(x_extent)),
        kernel.argumentI32(@intCast(columns)),
    }, .{
        .grid = .{ @intCast(spmmCsrBlockCountX(instance)), @intCast(spmmCsrBlockCountY(instance)), 1 },
        .block = .{ instance.threads.x, instance.threads.y, 1 },
    });

    for (0..rows) |row| {
        for (0..columns) |column| {
            var expected: f32 = 0;
            const begin: usize = @intCast(row_ptr[row]);
            const end: usize = @intCast(row_ptr[row + 1]);
            for (begin..end) |element| {
                const x_index: usize = @as(usize, @intCast(cols_storage[element])) * columns + column;
                expected += spmvTestFloat(dtype, values_storage[element]) * spmvTestFloat(dtype, x[x_index]);
            }
            const expected_output = spmvTestFloat(dtype, spmvTestValue(dtype, expected));
            const output_index = row * columns + column;
            try testing.expectApproxEqAbs(expected_output, spmvTestFloat(dtype, y[output_index]), 0.001);
        }
    }
}

test "sparse spmm csr matches the dense matrix reference" {
    try expectSpmmCsrMatchesDense(.f64);
    try expectSpmmCsrMatchesDense(.f32);
    try expectSpmmCsrMatchesDense(.f16);
}

test "sparse spmv csr identity validity and artifact contract" {
    const allocator = testing.allocator;
    const instance = SpmvCsr{ .rows = 1000, .threads = 64 };

    const target = try spmvCsrFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_csr_row_warp_family_64_f32", target);
    const thread_target = try spmvCsrFamilyTarget(allocator, .{ .rows = 1000, .threads = 64, .structure = .row_thread });
    defer allocator.free(thread_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_csr_row_thread_family_64_f32", thread_target);
    const f16_target = try spmvCsrFamilyTarget(allocator, .{ .rows = 1000, .dtype = .f16, .threads = 64 });
    defer allocator.free(f16_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_csr_row_warp_family_64_f16", f16_target);
    const f64_target = try spmvCsrFamilyTarget(allocator, .{ .rows = 1000, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 });
    defer allocator.free(f64_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_csr_row_warp_family_64_f64", f64_target);

    try testing.expectEqual(DType.f64, spmvCsrAccumulationDType(.f64).?);
    try testing.expectEqual(DType.f32, spmvCsrAccumulationDType(.f16).?);
    try testing.expect(spmvCsrInstanceValid(instance));
    try testing.expect(spmvCsrInstanceValid(.{ .rows = 10, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 }));
    try testing.expect(!spmvCsrInstanceValid(.{ .rows = 10, .dtype = .f64, .accumulation_dtype = .f32, .threads = 64 }));
    try testing.expect(spmvCsrInstanceValid(.{ .rows = 10, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 }));
    try testing.expect(!spmvCsrInstanceValid(.{ .rows = 10, .dtype = .f16, .accumulation_dtype = .f16, .threads = 64 }));
    try testing.expect(!spmvCsrInstanceValid(.{ .rows = 0, .threads = 64 }));
    try testing.expect(!spmvCsrInstanceValid(.{ .rows = 10, .threads = 48 }));
    try testing.expect(spmvCsrInstanceValid(.{ .rows = 10, .threads = 48, .structure = .row_thread }));
    try testing.expect(spmvCsrInstanceValid(.{ .rows = 10, .threads = 1, .structure = .row_thread }));
    try testing.expect(!spmvCsrInstanceValid(.{ .rows = 10, .threads = 0, .structure = .row_thread }));

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var family_artifact = try createSpmvCsrFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    const family_entry = family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_csr_row_warp_family_64_f32", family_entry.entry_name);
    try testing.expectEqual(@as(u32, 8), family_entry.argument_count);
    try testing.expectEqual(@as(u32, 3), family_entry.runtime_scalar_argument_count);
    switch (family_entry.launch) {
        .derived => |launch| {
            try testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| try testing.expectEqual(@as(u32, 2), axis.divisor),
                else => return error.TestExpectedDerivedGrid,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }

    var f16_family_artifact = try createSpmvCsrFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
        .{ .limits = .testing },
    );
    defer f16_family_artifact.deinit();
    const f16_family_entry = f16_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_csr_row_warp_family_64_f16", f16_family_entry.entry_name);
    try testing.expect(f16_family_entry.required_dtypes.contains(.f16));
    try testing.expect(f16_family_entry.required_dtypes.contains(.i32));

    var f64_family_artifact = try createSpmvCsrFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
        .{ .limits = .testing },
    );
    defer f64_family_artifact.deinit();
    const f64_family_entry = f64_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_csr_row_warp_family_64_f64", f64_family_entry.entry_name);
    try testing.expect(f64_family_entry.required_dtypes.contains(.f64));
    try testing.expect(f64_family_entry.required_dtypes.contains(.i32));
}

test "sparse spmv csr family tuning keys discriminate dtype device and extents" {
    const allocator = testing.allocator;
    const device = tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x2684));

    const row_warp = try spmvCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .threads = 256,
        .structure = .row_warp,
    });
    const row_thread = try spmvCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .threads = 64,
        .structure = .row_thread,
    });
    try testing.expect(row_warp.eql(row_thread));

    const other_nnz = try spmvCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 90,
        .x_extent = 40,
    });
    try testing.expect(!row_warp.eql(other_nnz));

    const half = try spmvCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .dtype = .f16,
        .accumulation_dtype = .f32,
    });
    try testing.expect(!row_warp.eql(half));

    const other_device = try spmvCsrFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x1b80)),
        .{
            .rows = 70,
            .nnz = 560,
            .x_extent = 40,
        },
    );
    try testing.expect(!row_warp.eql(other_device));
}

test "sparse spmv csr family tuning resolves structure" {
    const allocator = testing.allocator;
    const caps = sparseFamilyTuningTestCapabilities(0x2684);
    const device = tuning.deviceFingerprint(caps);
    const probe = SpmvCsr{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .threads = 256,
        .structure = .row_warp,
    };
    var winner = probe;
    winner.structure = .row_thread;
    winner.threads = spmvCsrRepresentableThreads(winner) orelse return error.TestExpectedSparseStructure;
    const winner_target = try spmvCsrFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvCsrFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    const resolved = (try resolveSpmvCsrStructure(allocator, reader, probe)) orelse
        return error.TestExpectedSparseStructure;
    try testing.expectEqual(SpmvCsrStructure.row_thread, resolved);

    const miss = try resolveSpmvCsrStructure(allocator, reader, .{
        .rows = 70,
        .nnz = 90,
        .x_extent = 40,
        .threads = 256,
        .structure = .row_thread,
    });
    try testing.expectEqual(@as(?SpmvCsrStructure, null), miss);

    const stale_records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvCsrFamilyTuningKey(allocator, device, probe),
        .target = "accy.kernel.sparse.spmv_csr_row_group_family_256_f32",
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const stale_reader = tuning.FamilyTuningReader.init(caps, .{ .records = stale_records[0..] });
    try testing.expectEqual(
        @as(?SpmvCsrStructure, null),
        try resolveSpmvCsrStructure(allocator, stale_reader, probe),
    );
}

test "sparse spmv coo family tuning keys discriminate dtype device and extents" {
    const allocator = testing.allocator;
    const device = tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x2684));

    const element_thread = try spmvCooFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .threads = 256,
        .structure = .element_thread,
    });
    const row_thread = try spmvCooFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .threads = 70,
        .structure = .row_thread,
    });
    try testing.expect(element_thread.eql(row_thread));

    const other_nnz = try spmvCooFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 90,
        .x_extent = 40,
    });
    try testing.expect(!element_thread.eql(other_nnz));

    const half = try spmvCooFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .dtype = .f16,
        .accumulation_dtype = .f32,
        .threads = 70,
        .structure = .row_thread,
    });
    try testing.expect(!element_thread.eql(half));

    const other_device = try spmvCooFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x1b80)),
        .{
            .rows = 70,
            .nnz = 560,
            .x_extent = 40,
        },
    );
    try testing.expect(!element_thread.eql(other_device));
}

test "sparse spmv coo family tuning resolves structure" {
    const allocator = testing.allocator;
    const caps = sparseFamilyTuningTestCapabilities(0x2684);
    const device = tuning.deviceFingerprint(caps);
    const probe = SpmvCoo{
        .rows = 70,
        .nnz = 560,
        .x_extent = 40,
        .threads = 256,
        .structure = .element_thread,
    };
    var winner = probe;
    winner.structure = .row_thread;
    winner.threads = spmvCooRepresentableThreads(winner) orelse return error.TestExpectedSparseStructure;
    const winner_target = try spmvCooFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvCooFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    const resolved = (try resolveSpmvCooStructure(allocator, reader, probe)) orelse
        return error.TestExpectedSparseStructure;
    try testing.expectEqual(SpmvCooStructure.row_thread, resolved);

    const miss = try resolveSpmvCooStructure(allocator, reader, .{
        .rows = 70,
        .nnz = 90,
        .x_extent = 40,
        .threads = 256,
        .structure = .element_thread,
    });
    try testing.expectEqual(@as(?SpmvCooStructure, null), miss);

    const stale_records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvCooFamilyTuningKey(allocator, device, probe),
        .target = "accy.kernel.sparse.spmv_coo_warp_group_family_256_f32",
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const stale_reader = tuning.FamilyTuningReader.init(caps, .{ .records = stale_records[0..] });
    try testing.expectEqual(
        @as(?SpmvCooStructure, null),
        try resolveSpmvCooStructure(allocator, stale_reader, probe),
    );
}

test "sparse spmv ell family tuning keys discriminate dtype device and fixed layout" {
    const allocator = testing.allocator;
    const device = tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x2684));

    const block_256 = try spmvEllFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slots = 8,
        .x_extent = 40,
        .threads = 256,
    });
    const block_64 = try spmvEllFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slots = 8,
        .x_extent = 40,
        .threads = 64,
    });
    try testing.expect(block_256.eql(block_64));

    const other_slots = try spmvEllFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slots = 16,
        .x_extent = 40,
    });
    try testing.expect(!block_256.eql(other_slots));

    const other_x = try spmvEllFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slots = 8,
        .x_extent = 41,
    });
    try testing.expect(!block_256.eql(other_x));

    const half = try spmvEllFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slots = 8,
        .x_extent = 40,
        .dtype = .f16,
        .accumulation_dtype = .f32,
    });
    try testing.expect(!block_256.eql(half));

    const other_device = try spmvEllFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x1b80)),
        .{
            .rows = 70,
            .slots = 8,
            .x_extent = 40,
        },
    );
    try testing.expect(!block_256.eql(other_device));
}

test "sparse spmv ell family tuning resolves thread blocks" {
    const allocator = testing.allocator;
    const caps = sparseFamilyTuningTestCapabilities(0x2684);
    const device = tuning.deviceFingerprint(caps);
    const probe = SpmvEll{
        .rows = 70,
        .slots = 8,
        .x_extent = 40,
        .threads = 256,
    };
    var winner = probe;
    winner.threads = 64;
    const winner_target = try spmvEllFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvEllFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    const resolved = (try resolveSpmvEllThreads(allocator, reader, probe)) orelse
        return error.TestExpectedSparseStructure;
    try testing.expectEqual(@as(u32, 64), resolved);

    const miss = try resolveSpmvEllThreads(allocator, reader, .{
        .rows = 70,
        .slots = 9,
        .x_extent = 40,
        .threads = 256,
    });
    try testing.expectEqual(@as(?u32, null), miss);

    const stale_records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvEllFamilyTuningKey(allocator, device, probe),
        .target = "accy.kernel.sparse.spmv_ell_warp_group_family_256_f32",
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const stale_reader = tuning.FamilyTuningReader.init(caps, .{ .records = stale_records[0..] });
    try testing.expectEqual(
        @as(?u32, null),
        try resolveSpmvEllThreads(allocator, stale_reader, probe),
    );
}

test "sparse spmv sell family tuning keys discriminate dtype device and fixed layout" {
    const allocator = testing.allocator;
    const device = tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x2684));

    const block_256 = try spmvSellFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slice_size = 8,
        .values_size = 400,
        .x_extent = 40,
        .threads = 256,
    });
    const block_64 = try spmvSellFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slice_size = 8,
        .values_size = 400,
        .x_extent = 40,
        .threads = 64,
    });
    try testing.expect(block_256.eql(block_64));

    const other_slice = try spmvSellFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slice_size = 16,
        .values_size = 400,
        .x_extent = 40,
    });
    try testing.expect(!block_256.eql(other_slice));

    const other_values = try spmvSellFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slice_size = 8,
        .values_size = 512,
        .x_extent = 40,
    });
    try testing.expect(!block_256.eql(other_values));

    const half = try spmvSellFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .slice_size = 8,
        .values_size = 400,
        .x_extent = 40,
        .dtype = .f16,
        .accumulation_dtype = .f32,
    });
    try testing.expect(!block_256.eql(half));

    const other_device = try spmvSellFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x1b80)),
        .{
            .rows = 70,
            .slice_size = 8,
            .values_size = 400,
            .x_extent = 40,
        },
    );
    try testing.expect(!block_256.eql(other_device));
}

test "sparse spmv sell family tuning resolves thread blocks" {
    const allocator = testing.allocator;
    const caps = sparseFamilyTuningTestCapabilities(0x2684);
    const device = tuning.deviceFingerprint(caps);
    const probe = SpmvSell{
        .rows = 70,
        .slice_size = 8,
        .values_size = 400,
        .x_extent = 40,
        .threads = 256,
    };
    var winner = probe;
    winner.threads = 64;
    winner.threads = spmvSellRepresentableThreads(winner) orelse return error.TestExpectedSparseStructure;
    const winner_target = try spmvSellFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvSellFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    const resolved = (try resolveSpmvSellThreads(allocator, reader, probe)) orelse
        return error.TestExpectedSparseStructure;
    try testing.expectEqual(@as(u32, 64), resolved);

    const miss = try resolveSpmvSellThreads(allocator, reader, .{
        .rows = 70,
        .slice_size = 16,
        .values_size = 400,
        .x_extent = 40,
        .threads = 256,
    });
    try testing.expectEqual(@as(?u32, null), miss);

    const stale_records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmvSellFamilyTuningKey(allocator, device, probe),
        .target = "accy.kernel.sparse.spmv_sell_row_thread_slice8_family_96_f32",
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const stale_reader = tuning.FamilyTuningReader.init(caps, .{ .records = stale_records[0..] });
    try testing.expectEqual(
        @as(?u32, null),
        try resolveSpmvSellThreads(allocator, stale_reader, probe),
    );
}

test "sparse spmm csr family tuning keys discriminate dtype device and extents" {
    const allocator = testing.allocator;
    const device = tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x2684));

    const block_16 = try spmmCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .columns = 45,
        .nnz = 512,
        .x_extent = 40,
        .threads = .{ .x = 16, .y = 16 },
    });
    const block_8 = try spmmCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .columns = 45,
        .nnz = 512,
        .x_extent = 40,
        .threads = .{ .x = 8, .y = 8 },
    });
    try testing.expect(block_16.eql(block_8));

    const other_columns = try spmmCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .columns = 46,
        .nnz = 512,
        .x_extent = 40,
    });
    try testing.expect(!block_16.eql(other_columns));

    const other_nnz = try spmmCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .columns = 45,
        .nnz = 768,
        .x_extent = 40,
    });
    try testing.expect(!block_16.eql(other_nnz));

    const half = try spmmCsrFamilyTuningKey(allocator, device, .{
        .rows = 70,
        .columns = 45,
        .nnz = 512,
        .x_extent = 40,
        .dtype = .f16,
        .accumulation_dtype = .f32,
    });
    try testing.expect(!block_16.eql(half));

    const other_device = try spmmCsrFamilyTuningKey(
        allocator,
        tuning.deviceFingerprint(sparseFamilyTuningTestCapabilities(0x1b80)),
        .{
            .rows = 70,
            .columns = 45,
            .nnz = 512,
            .x_extent = 40,
        },
    );
    try testing.expect(!block_16.eql(other_device));
}

test "sparse spmm csr family tuning resolves thread blocks" {
    const allocator = testing.allocator;
    const caps = sparseFamilyTuningTestCapabilities(0x2684);
    const device = tuning.deviceFingerprint(caps);
    const probe = SpmmCsr{
        .rows = 70,
        .columns = 45,
        .nnz = 512,
        .x_extent = 40,
        .threads = spmmCsrThreadsForExtents(70, 45),
    };
    const candidates = spmmCsrThreadCandidatesForExtents(probe.rows, probe.columns);
    try testing.expect(candidates.count > 1);
    var winner = probe;
    winner.threads = candidates.items[1];
    winner.threads = spmmCsrRepresentableThreads(winner) orelse return error.TestExpectedSparseStructure;
    const winner_target = try spmmCsrFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmmCsrFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const reader = tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    const resolved = (try resolveSpmmCsrThreads(allocator, reader, probe)) orelse
        return error.TestExpectedSparseStructure;
    try testing.expectEqual(winner.threads.x, resolved.x);
    try testing.expectEqual(winner.threads.y, resolved.y);

    const miss = try resolveSpmmCsrThreads(allocator, reader, .{
        .rows = 70,
        .columns = 46,
        .nnz = 512,
        .x_extent = 40,
        .threads = spmmCsrThreadsForExtents(70, 46),
    });
    try testing.expectEqual(@as(?entry.Threads2D, null), miss);

    const stale_records = [_]tuning.FamilyTuningRecord{.{
        .key = try spmmCsrFamilyTuningKey(allocator, device, probe),
        .target = "accy.kernel.sparse.spmm_csr_row_column_thread_family_96x4_f32",
        .winner_median_ns = 800,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const stale_reader = tuning.FamilyTuningReader.init(caps, .{ .records = stale_records[0..] });
    try testing.expectEqual(
        @as(?entry.Threads2D, null),
        try resolveSpmmCsrThreads(allocator, stale_reader, probe),
    );
}

test "sparse spmv coo identity validity and artifact contract" {
    const allocator = testing.allocator;
    const instance = SpmvCoo{ .rows = 1000, .nnz = 4096, .x_extent = 64, .threads = 64 };

    const target = try spmvCooFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_coo_element_thread_family_64_f32", target);

    try testing.expectEqual(DType.f32, spmvCooAccumulationDType(.f32).?);
    try testing.expectEqual(DType.f64, spmvCooAccumulationDType(.f64).?);
    try testing.expectEqual(DType.f32, spmvCooAccumulationDType(.f16).?);
    try testing.expectEqual(DType.f32, spmvCooAccumulationDTypeForStructure(.row_thread, .f32).?);
    try testing.expectEqual(@as(?DType, null), spmvCooAccumulationDTypeForStructure(.element_thread, .f64));
    try testing.expectEqual(@as(?DType, null), spmvCooAccumulationDTypeForStructure(.element_thread, .f16));
    try testing.expect(spmvCooInstanceValid(instance));
    try testing.expect(!spmvCooInstanceValid(.{ .rows = 0, .nnz = 16, .x_extent = 4, .threads = 64 }));
    try testing.expect(!spmvCooInstanceValid(.{ .rows = 10, .nnz = 0, .x_extent = 4, .threads = 64 }));
    try testing.expect(!spmvCooInstanceValid(.{ .rows = 10, .nnz = 16, .x_extent = 0, .threads = 64 }));
    try testing.expect(!spmvCooInstanceValid(.{ .rows = 10, .nnz = 16, .x_extent = 4, .threads = 0 }));
    try testing.expect(!spmvCooInstanceValid(.{ .rows = 10, .nnz = 16, .x_extent = 4, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 }));
    try testing.expect(spmvCooInstanceValid(.{ .rows = 10, .nnz = 16, .x_extent = 4, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64, .structure = .row_thread }));
    try testing.expect(spmvCooInstanceValid(.{ .rows = 10, .nnz = 16, .x_extent = 4, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64, .structure = .row_thread }));

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var family_artifact = try createSpmvCooFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    const family_entry = family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_coo_element_thread_family_64_f32", family_entry.entry_name);
    try testing.expectEqual(@as(u32, 8), family_entry.argument_count);
    try testing.expectEqual(@as(u32, 3), family_entry.runtime_scalar_argument_count);
    switch (family_entry.launch) {
        .derived => |launch| {
            try testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| {
                    try testing.expectEqual(@as(u32, 1), axis.argument_index);
                    try testing.expectEqual(@as(u32, 64), axis.divisor);
                },
                else => return error.TestExpectedDerivedGrid,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }
    try testing.expect(family_entry.required_dtypes.contains(.f32));
    try testing.expect(family_entry.required_dtypes.contains(.i32));

    var f64_family_artifact = try createSpmvCooFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .nnz = 4096, .x_extent = 64, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64, .structure = .row_thread },
        .{ .limits = .testing },
    );
    defer f64_family_artifact.deinit();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_coo_row_thread_family_64_f64", f64_family_artifact.entry().entry_name);

    var f16_family_artifact = try createSpmvCooFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .nnz = 4096, .x_extent = 64, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64, .structure = .row_thread },
        .{ .limits = .testing },
    );
    defer f16_family_artifact.deinit();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_coo_row_thread_family_64_f16", f16_family_artifact.entry().entry_name);
}

test "sparse spmv ell identity validity and artifact contract" {
    const allocator = testing.allocator;
    const instance = SpmvEll{ .rows = 1000, .slots = 8, .x_extent = 64, .threads = 64 };

    const target = try spmvEllFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_ell_row_thread_family_64_f32", target);
    const f16_target = try spmvEllFamilyTarget(
        allocator,
        .{ .rows = 1000, .slots = 8, .x_extent = 64, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
    );
    defer allocator.free(f16_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_ell_row_thread_family_64_f16", f16_target);
    const f64_target = try spmvEllFamilyTarget(
        allocator,
        .{ .rows = 1000, .slots = 8, .x_extent = 64, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
    );
    defer allocator.free(f64_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_ell_row_thread_family_64_f64", f64_target);

    try testing.expectEqual(DType.f64, spmvEllAccumulationDType(.f64).?);
    try testing.expectEqual(DType.f32, spmvEllAccumulationDType(.f16).?);
    try testing.expect(spmvEllInstanceValid(instance));
    try testing.expect(spmvEllInstanceValid(.{ .rows = 10, .slots = 3, .x_extent = 4, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 }));
    try testing.expect(!spmvEllInstanceValid(.{ .rows = 10, .slots = 3, .x_extent = 4, .dtype = .f64, .accumulation_dtype = .f32, .threads = 64 }));
    try testing.expect(spmvEllInstanceValid(.{ .rows = 10, .slots = 3, .x_extent = 4, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 }));
    try testing.expect(!spmvEllInstanceValid(.{ .rows = 10, .slots = 3, .x_extent = 4, .dtype = .f16, .accumulation_dtype = .f16, .threads = 64 }));
    try testing.expect(!spmvEllInstanceValid(.{ .rows = 0, .slots = 3, .x_extent = 4, .threads = 64 }));
    try testing.expect(!spmvEllInstanceValid(.{ .rows = 10, .slots = 0, .x_extent = 4, .threads = 64 }));
    try testing.expect(!spmvEllInstanceValid(.{ .rows = 10, .slots = 3, .x_extent = 0, .threads = 64 }));
    try testing.expect(!spmvEllInstanceValid(.{ .rows = 10, .slots = 3, .x_extent = 4, .threads = 0 }));

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var family_artifact = try createSpmvEllFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    const family_entry = family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_ell_row_thread_family_64_f32", family_entry.entry_name);
    try testing.expectEqual(@as(u32, 7), family_entry.argument_count);
    try testing.expectEqual(@as(u32, 3), family_entry.runtime_scalar_argument_count);
    switch (family_entry.launch) {
        .derived => |launch| {
            try testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| try testing.expectEqual(@as(u32, 64), axis.divisor),
                else => return error.TestExpectedDerivedGrid,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }

    var f16_family_artifact = try createSpmvEllFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .slots = 8, .x_extent = 64, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
        .{ .limits = .testing },
    );
    defer f16_family_artifact.deinit();
    const f16_family_entry = f16_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_ell_row_thread_family_64_f16", f16_family_entry.entry_name);
    try testing.expect(f16_family_entry.required_dtypes.contains(.f16));
    try testing.expect(f16_family_entry.required_dtypes.contains(.i32));

    var f64_family_artifact = try createSpmvEllFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .slots = 8, .x_extent = 64, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
        .{ .limits = .testing },
    );
    defer f64_family_artifact.deinit();
    const f64_family_entry = f64_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_ell_row_thread_family_64_f64", f64_family_entry.entry_name);
    try testing.expect(f64_family_entry.required_dtypes.contains(.f64));
    try testing.expect(f64_family_entry.required_dtypes.contains(.i32));
}

test "sparse spmv sell identity validity and artifact contract" {
    const allocator = testing.allocator;
    const instance = SpmvSell{ .rows = 1000, .slice_size = 32, .values_size = 4096, .x_extent = 64, .threads = 64 };

    const target = try spmvSellFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_sell_row_thread_slice32_family_64_f32", target);
    const f16_target = try spmvSellFamilyTarget(
        allocator,
        .{ .rows = 1000, .slice_size = 32, .values_size = 4096, .x_extent = 64, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
    );
    defer allocator.free(f16_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_sell_row_thread_slice32_family_64_f16", f16_target);
    const f64_target = try spmvSellFamilyTarget(
        allocator,
        .{ .rows = 1000, .slice_size = 32, .values_size = 4096, .x_extent = 64, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
    );
    defer allocator.free(f64_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmv_sell_row_thread_slice32_family_64_f64", f64_target);

    try testing.expectEqual(DType.f64, spmvSellAccumulationDType(.f64).?);
    try testing.expectEqual(DType.f32, spmvSellAccumulationDType(.f16).?);
    try testing.expectEqual(@as(u64, 32), spmvSellSliceCount(instance));
    try testing.expect(spmvSellInstanceValid(instance));
    try testing.expect(spmvSellInstanceValid(.{ .rows = 10, .slice_size = 4, .values_size = 24, .x_extent = 4, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 }));
    try testing.expect(!spmvSellInstanceValid(.{ .rows = 10, .slice_size = 4, .values_size = 24, .x_extent = 4, .dtype = .f64, .accumulation_dtype = .f32, .threads = 64 }));
    try testing.expect(spmvSellInstanceValid(.{ .rows = 10, .slice_size = 4, .values_size = 24, .x_extent = 4, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 }));
    try testing.expect(!spmvSellInstanceValid(.{ .rows = 10, .slice_size = 4, .values_size = 24, .x_extent = 4, .dtype = .f16, .accumulation_dtype = .f16, .threads = 64 }));
    try testing.expect(!spmvSellInstanceValid(.{ .rows = 0, .slice_size = 4, .values_size = 24, .x_extent = 4, .threads = 64 }));
    try testing.expect(!spmvSellInstanceValid(.{ .rows = 10, .slice_size = 0, .values_size = 24, .x_extent = 4, .threads = 64 }));
    try testing.expect(!spmvSellInstanceValid(.{ .rows = 10, .slice_size = 4, .values_size = 0, .x_extent = 4, .threads = 64 }));
    try testing.expect(!spmvSellInstanceValid(.{ .rows = 10, .slice_size = 4, .values_size = 24, .x_extent = 0, .threads = 64 }));
    try testing.expect(!spmvSellInstanceValid(.{ .rows = 10, .slice_size = 4, .values_size = 24, .x_extent = 4, .threads = 0 }));

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var family_artifact = try createSpmvSellFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    const family_entry = family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_sell_row_thread_slice32_family_64_f32", family_entry.entry_name);
    try testing.expectEqual(@as(u32, 8), family_entry.argument_count);
    try testing.expectEqual(@as(u32, 3), family_entry.runtime_scalar_argument_count);
    switch (family_entry.launch) {
        .derived => |launch| {
            try testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| try testing.expectEqual(@as(u32, 64), axis.divisor),
                else => return error.TestExpectedDerivedGrid,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }

    var f16_family_artifact = try createSpmvSellFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .slice_size = 32, .values_size = 4096, .x_extent = 64, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
        .{ .limits = .testing },
    );
    defer f16_family_artifact.deinit();
    const f16_family_entry = f16_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_sell_row_thread_slice32_family_64_f16", f16_family_entry.entry_name);
    try testing.expect(f16_family_entry.required_dtypes.contains(.f16));
    try testing.expect(f16_family_entry.required_dtypes.contains(.i32));

    var f64_family_artifact = try createSpmvSellFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .slice_size = 32, .values_size = 4096, .x_extent = 64, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
        .{ .limits = .testing },
    );
    defer f64_family_artifact.deinit();
    const f64_family_entry = f64_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmv_sell_row_thread_slice32_family_64_f64", f64_family_entry.entry_name);
    try testing.expect(f64_family_entry.required_dtypes.contains(.f64));
    try testing.expect(f64_family_entry.required_dtypes.contains(.i32));
}

test "sparse spmm csr identity validity and artifact contract" {
    const allocator = testing.allocator;
    const instance = SpmmCsr{
        .rows = 1000,
        .columns = 37,
        .x_extent = 80,
        .threads = .{ .x = 8, .y = 4 },
    };

    const target = try spmmCsrFamilyTarget(allocator, instance);
    defer allocator.free(target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmm_csr_row_column_thread_family_8x4_f32", target);
    const f16_target = try spmmCsrFamilyTarget(allocator, .{
        .rows = 1000,
        .columns = 37,
        .x_extent = 80,
        .dtype = .f16,
        .accumulation_dtype = .f32,
        .threads = .{ .x = 8, .y = 4 },
    });
    defer allocator.free(f16_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmm_csr_row_column_thread_family_8x4_f16", f16_target);
    const f64_target = try spmmCsrFamilyTarget(allocator, .{
        .rows = 1000,
        .columns = 37,
        .x_extent = 80,
        .dtype = .f64,
        .accumulation_dtype = .f64,
        .threads = .{ .x = 8, .y = 4 },
    });
    defer allocator.free(f64_target);
    try testing.expectEqualStrings("accy.kernel.sparse.spmm_csr_row_column_thread_family_8x4_f64", f64_target);

    try testing.expectEqual(DType.f64, spmmCsrAccumulationDType(.f64).?);
    try testing.expectEqual(DType.f32, spmmCsrAccumulationDType(.f16).?);
    try testing.expect(spmmCsrInstanceValid(instance));
    try testing.expect(spmmCsrInstanceValid(.{ .rows = 10, .columns = 3, .dtype = .f64, .accumulation_dtype = .f64 }));
    try testing.expect(!spmmCsrInstanceValid(.{ .rows = 10, .columns = 3, .dtype = .f64, .accumulation_dtype = .f32 }));
    try testing.expect(spmmCsrInstanceValid(.{ .rows = 10, .columns = 3, .dtype = .f16, .accumulation_dtype = .f32 }));
    try testing.expect(!spmmCsrInstanceValid(.{ .rows = 10, .columns = 3, .dtype = .f16, .accumulation_dtype = .f16 }));
    try testing.expect(!spmmCsrInstanceValid(.{ .rows = 0, .columns = 3 }));
    try testing.expect(!spmmCsrInstanceValid(.{ .rows = 10, .columns = 0 }));
    try testing.expect(!spmmCsrInstanceValid(.{ .rows = 10, .columns = 3, .threads = .{ .x = 0, .y = 4 } }));
    try testing.expect(!spmmCsrInstanceValid(.{ .rows = 10, .columns = 3, .threads = .{ .x = 33, .y = 33 } }));

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var family_artifact = try createSpmmCsrFamilyArtifact(allocator, state.handle(), instance, .{ .limits = .testing });
    defer family_artifact.deinit();
    const family_entry = family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmm_csr_row_column_thread_family_8x4_f32", family_entry.entry_name);
    try testing.expectEqual(@as(u32, 9), family_entry.argument_count);
    try testing.expectEqual(@as(u32, 4), family_entry.runtime_scalar_argument_count);
    switch (family_entry.launch) {
        .derived => |launch| {
            try testing.expectEqual(@as(u32, 8), launch.threadgroup[0]);
            try testing.expectEqual(@as(u32, 4), launch.threadgroup[1]);
            switch (launch.grid[0]) {
                .runtime_u32_ceil_div => |axis| {
                    try testing.expectEqual(@as(u32, 3), axis.argument_index);
                    try testing.expectEqual(@as(u32, 8), axis.divisor);
                },
                else => return error.TestExpectedDerivedGrid,
            }
            switch (launch.grid[1]) {
                .runtime_u32_ceil_div => |axis| {
                    try testing.expectEqual(@as(u32, 0), axis.argument_index);
                    try testing.expectEqual(@as(u32, 4), axis.divisor);
                },
                else => return error.TestExpectedDerivedGrid,
            }
        },
        else => return error.TestExpectedDerivedLaunch,
    }
    const profile = family_entry.shape_profile orelse return error.TestExpectedShapeProfile;
    try testing.expectEqual(@as(usize, 2), profile.dimensions.len);

    var f16_family_artifact = try createSpmmCsrFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .columns = 37, .x_extent = 80, .dtype = .f16, .accumulation_dtype = .f32, .threads = .{ .x = 8, .y = 4 } },
        .{ .limits = .testing },
    );
    defer f16_family_artifact.deinit();
    const f16_family_entry = f16_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmm_csr_row_column_thread_family_8x4_f16", f16_family_entry.entry_name);
    try testing.expect(f16_family_entry.required_dtypes.contains(.f16));
    try testing.expect(f16_family_entry.required_dtypes.contains(.i32));

    var f64_family_artifact = try createSpmmCsrFamilyArtifact(
        allocator,
        state.handle(),
        .{ .rows = 1000, .columns = 37, .x_extent = 80, .dtype = .f64, .accumulation_dtype = .f64, .threads = .{ .x = 8, .y = 4 } },
        .{ .limits = .testing },
    );
    defer f64_family_artifact.deinit();
    const f64_family_entry = f64_family_artifact.entry();
    try testing.expectEqualStrings("accy_kernel_sparse_spmm_csr_row_column_thread_family_8x4_f64", f64_family_entry.entry_name);
    try testing.expect(f64_family_entry.required_dtypes.contains(.f64));
    try testing.expect(f64_family_entry.required_dtypes.contains(.i32));
}

pub const spmv_csr_nonzero_axis = "n";
pub const spmv_csr_column_axis = "x";
pub const spmv_sell_slice_size_parameter = "slice_size";

pub fn spmvCsrLaunchExtent(instance: SpmvCsr) u64 {
    return spmvCsrLaunchExtentChecked(instance).?;
}

fn spmvCsrLaunchExtentChecked(instance: SpmvCsr) ?u64 {
    return switch (instance.structure) {
        .row_thread => instance.rows,
        .row_warp => std.math.mul(u64, instance.rows, spmv_csr_warp_size) catch null,
    };
}

pub fn spmvCsrRepresentableThreads(instance: SpmvCsr) ?u32 {
    const launch_extent = spmvCsrLaunchExtentChecked(instance) orelse return null;
    return std.math.cast(u32, @min(@as(u64, instance.threads), launch_extent));
}

pub fn spmvCsrFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: SpmvCsr,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows + 1);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, spmv_csr_nonzero_axis, instance.nnz);
    inputs[2] = try entry.runtimeShape1D(lifetime_allocator, spmv_csr_nonzero_axis, instance.nnz);
    inputs[3] = try entry.runtimeShape1D(lifetime_allocator, spmv_csr_column_axis, instance.x_extent);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows);

    owned.value = .{
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .operation = .{ .sparse = .csr_spmv },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.row_axis,
            spmvCsrLaunchExtent(instance),
            instance.threads,
        ),
        .structure = @tagName(instance.structure),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try spmvCsrShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn spmvCsrInstanceFromSpecialization(specialization: entry.Specialization) ?SpmvCsr {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .sparse = .csr_spmv })) return null;
    const dtype = specialization.dtype orelse return null;
    const accumulation_dtype = spmvCsrAccumulationDType(dtype) orelse return null;
    if (specialization.accumulation_dtype != accumulation_dtype) return null;
    if (specialization.inputs.len != 4 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const row_ptr = specialization.inputs[0];
    const cols = specialization.inputs[1];
    const values = specialization.inputs[2];
    const x = specialization.inputs[3];
    const y = specialization.outputs[0];
    if (row_ptr.axes.len != 1 or cols.axes.len != 1 or values.axes.len != 1 or x.axes.len != 1 or y.axes.len != 1) return null;
    if (y.axes[0].name.len == 0) return null;
    if (cols.axes[0].extent == 0 or x.axes[0].extent == 0) return null;
    const row_ptr_extent = std.math.add(u64, y.axes[0].extent, 1) catch return null;
    if (!sparseAxisMatches(row_ptr.axes[0], y.axes[0].name, row_ptr_extent)) return null;
    if (!sparseAxisMatches(cols.axes[0], spmv_csr_nonzero_axis, cols.axes[0].extent)) return null;
    if (!sparseAxisMatches(values.axes[0], spmv_csr_nonzero_axis, cols.axes[0].extent)) return null;
    if (!sparseAxisMatches(x.axes[0], spmv_csr_column_axis, x.axes[0].extent)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const structure_name = specialization.structure orelse return null;
    const structure = std.meta.stringToEnum(SpmvCsrStructure, structure_name) orelse return null;
    const instance = SpmvCsr{
        .rows = y.axes[0].extent,
        .nnz = cols.axes[0].extent,
        .x_extent = x.axes[0].extent,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = launch.threadgroup[0],
        .structure = structure,
        .row_axis = y.axes[0].name,
    };
    if (!spmvCsrInstanceValid(instance)) return null;
    if (!spmvCsrScheduleMatchesInstance(schedule, instance)) return null;
    return instance;
}

fn sparseAxisMatches(axis: entry.Axis, name: []const u8, extent: u64) bool {
    if (name.len == 0) return false;
    if (!std.mem.eql(u8, axis.name, name)) return false;
    return axis.extent == extent;
}

fn sparseScheduleAxisNameMatches(actual: []const u8, row_axis: []const u8, suffix: []const u8) bool {
    if (actual.len != row_axis.len + suffix.len) return false;
    return std.mem.eql(u8, actual[0..row_axis.len], row_axis) and
        std.mem.eql(u8, actual[row_axis.len..], suffix);
}

fn spmvCsrScheduleMatchesInstance(schedule: entry.Schedule, instance: SpmvCsr) bool {
    const extent = spmvCsrLaunchExtentChecked(instance) orelse return false;
    if (extent <= instance.threads) {
        if (schedule.bindings.len != 1) return false;
        const binding = schedule.bindings[0];
        return sparseAxisMatches(.{ .name = binding.axis, .extent = binding.extent }, instance.row_axis, extent) and
            binding.target == .thread_x;
    }
    if (schedule.bindings.len != 2) return false;
    const tile = schedule.bindings[0];
    const lane = schedule.bindings[1];
    const blocks = spmvCsrBlockCountChecked(instance) orelse return false;
    return tile.target == .block_x and
        tile.extent == blocks and
        sparseScheduleAxisNameMatches(tile.axis, instance.row_axis, "_tile") and
        lane.target == .thread_x and
        lane.extent == instance.threads and
        sparseScheduleAxisNameMatches(lane.axis, instance.row_axis, "_lane");
}

pub fn spmvCooLaunchExtent(instance: SpmvCoo) u64 {
    return spmvCooLaunchExtentChecked(instance).?;
}

fn spmvCooLaunchExtentChecked(instance: SpmvCoo) ?u64 {
    return switch (instance.structure) {
        .element_thread => instance.nnz,
        .row_thread => instance.rows,
    };
}

pub fn spmvCooRepresentableThreads(instance: SpmvCoo) ?u32 {
    const launch_extent = spmvCooLaunchExtentChecked(instance) orelse return null;
    return std.math.cast(u32, @min(@as(u64, instance.threads), launch_extent));
}

fn spmvCooLaunchArgumentIndex(instance: SpmvCoo) u32 {
    return switch (instance.structure) {
        .element_thread => 1,
        .row_thread => 0,
    };
}

fn spmvCooScheduleAxis(instance: SpmvCoo) []const u8 {
    return switch (instance.structure) {
        .element_thread => instance.nonzero_axis,
        .row_thread => instance.row_axis,
    };
}

pub fn spmvCooFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: SpmvCoo,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.nonzero_axis, instance.nnz);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.nonzero_axis, instance.nnz);
    inputs[2] = try entry.runtimeShape1D(lifetime_allocator, instance.nonzero_axis, instance.nnz);
    inputs[3] = try entry.runtimeShape1D(lifetime_allocator, instance.x_axis, instance.x_extent);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows);

    owned.value = .{
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .operation = .{ .sparse = .coo_spmv },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            spmvCooScheduleAxis(instance),
            spmvCooLaunchExtent(instance),
            instance.threads,
        ),
        .structure = @tagName(instance.structure),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try spmvCooShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn spmvCooInstanceFromSpecialization(specialization: entry.Specialization) ?SpmvCoo {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .sparse = .coo_spmv })) return null;
    const dtype = specialization.dtype orelse return null;
    if (specialization.inputs.len != 4 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const row_indices = specialization.inputs[0];
    const cols = specialization.inputs[1];
    const values = specialization.inputs[2];
    const x = specialization.inputs[3];
    const y = specialization.outputs[0];
    if (row_indices.axes.len != 1 or cols.axes.len != 1 or values.axes.len != 1 or x.axes.len != 1 or y.axes.len != 1) return null;
    if (row_indices.axes[0].name.len == 0 or x.axes[0].name.len == 0 or y.axes[0].name.len == 0) return null;
    if (row_indices.axes[0].extent == 0 or x.axes[0].extent == 0 or y.axes[0].extent == 0) return null;
    if (!sparseAxisMatches(cols.axes[0], row_indices.axes[0].name, row_indices.axes[0].extent)) return null;
    if (!sparseAxisMatches(values.axes[0], row_indices.axes[0].name, row_indices.axes[0].extent)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const structure_name = specialization.structure orelse return null;
    const structure = std.meta.stringToEnum(SpmvCooStructure, structure_name) orelse return null;
    const accumulation_dtype = spmvCooAccumulationDTypeForStructure(structure, dtype) orelse return null;
    if (specialization.accumulation_dtype != accumulation_dtype) return null;
    const instance = SpmvCoo{
        .rows = y.axes[0].extent,
        .nnz = row_indices.axes[0].extent,
        .x_extent = x.axes[0].extent,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = launch.threadgroup[0],
        .structure = structure,
        .row_axis = y.axes[0].name,
        .nonzero_axis = row_indices.axes[0].name,
        .x_axis = x.axes[0].name,
    };
    if (!spmvCooInstanceValid(instance)) return null;
    if (!spmvCooScheduleMatchesInstance(schedule, instance)) return null;
    return instance;
}

fn spmvCooScheduleMatchesInstance(schedule: entry.Schedule, instance: SpmvCoo) bool {
    const extent = spmvCooLaunchExtentChecked(instance) orelse return false;
    const axis = spmvCooScheduleAxis(instance);
    if (extent <= instance.threads) {
        if (schedule.bindings.len != 1) return false;
        const binding = schedule.bindings[0];
        return sparseAxisMatches(.{ .name = binding.axis, .extent = binding.extent }, axis, extent) and
            binding.target == .thread_x;
    }
    if (schedule.bindings.len != 2) return false;
    const tile = schedule.bindings[0];
    const lane = schedule.bindings[1];
    const blocks = spmvCooBlockCountChecked(instance) orelse return false;
    return tile.target == .block_x and
        tile.extent == blocks and
        sparseScheduleAxisNameMatches(tile.axis, axis, "_tile") and
        lane.target == .thread_x and
        lane.extent == instance.threads and
        sparseScheduleAxisNameMatches(lane.axis, axis, "_lane");
}

pub fn spmvEllLaunchExtent(instance: SpmvEll) u64 {
    return spmvEllLaunchExtentChecked(instance).?;
}

fn spmvEllLaunchExtentChecked(instance: SpmvEll) ?u64 {
    return switch (instance.structure) {
        .row_thread => instance.rows,
    };
}

pub fn spmvEllRepresentableThreads(instance: SpmvEll) ?u32 {
    const launch_extent = spmvEllLaunchExtentChecked(instance) orelse return null;
    if (launch_extent > std.math.maxInt(u32)) return null;
    return @min(instance.threads, @as(u32, @intCast(launch_extent)));
}

pub fn spmvEllThreadCandidatesForRows(rows: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(rows, spmv_ell_thread_caps);
}

pub fn spmvEllFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: SpmvEll,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 3);
    inputs[0] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.slot_axis,
        instance.slots,
        instance.row_axis,
        instance.rows,
    );
    inputs[1] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.slot_axis,
        instance.slots,
        instance.row_axis,
        instance.rows,
    );
    inputs[2] = try entry.runtimeShape1D(lifetime_allocator, instance.x_axis, instance.x_extent);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows);

    owned.value = .{
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .operation = .{ .sparse = .ell_spmv },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.row_axis,
            spmvEllLaunchExtent(instance),
            instance.threads,
        ),
        .structure = @tagName(instance.structure),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try spmvEllShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn spmvEllInstanceFromSpecialization(specialization: entry.Specialization) ?SpmvEll {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .sparse = .ell_spmv })) return null;
    const dtype = specialization.dtype orelse return null;
    const accumulation_dtype = spmvEllAccumulationDType(dtype) orelse return null;
    if (specialization.accumulation_dtype != accumulation_dtype) return null;
    if (specialization.inputs.len != 3 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const cols = specialization.inputs[0];
    const values = specialization.inputs[1];
    const x = specialization.inputs[2];
    const y = specialization.outputs[0];
    if (cols.axes.len != 2 or values.axes.len != 2 or x.axes.len != 1 or y.axes.len != 1) return null;
    if (cols.axes[0].name.len == 0 or y.axes[0].name.len == 0 or x.axes[0].name.len == 0) return null;
    if (cols.axes[0].extent == 0 or x.axes[0].extent == 0) return null;
    if (!sparseAxisMatches(cols.axes[1], y.axes[0].name, y.axes[0].extent)) return null;
    if (!sparseAxisMatches(values.axes[0], cols.axes[0].name, cols.axes[0].extent)) return null;
    if (!sparseAxisMatches(values.axes[1], y.axes[0].name, y.axes[0].extent)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const structure_name = specialization.structure orelse return null;
    const structure = std.meta.stringToEnum(SpmvEllStructure, structure_name) orelse return null;
    const instance = SpmvEll{
        .rows = y.axes[0].extent,
        .slots = cols.axes[0].extent,
        .x_extent = x.axes[0].extent,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = launch.threadgroup[0],
        .structure = structure,
        .row_axis = y.axes[0].name,
        .slot_axis = cols.axes[0].name,
        .x_axis = x.axes[0].name,
    };
    if (!spmvEllInstanceValid(instance)) return null;
    if (!spmvEllScheduleMatchesInstance(schedule, instance)) return null;
    return instance;
}

fn spmvEllScheduleMatchesInstance(schedule: entry.Schedule, instance: SpmvEll) bool {
    const extent = spmvEllLaunchExtentChecked(instance) orelse return false;
    if (extent <= instance.threads) {
        if (schedule.bindings.len != 1) return false;
        const binding = schedule.bindings[0];
        return sparseAxisMatches(.{ .name = binding.axis, .extent = binding.extent }, instance.row_axis, extent) and
            binding.target == .thread_x;
    }
    if (schedule.bindings.len != 2) return false;
    const tile = schedule.bindings[0];
    const lane = schedule.bindings[1];
    const blocks = spmvEllBlockCountChecked(instance) orelse return false;
    return tile.target == .block_x and
        tile.extent == blocks and
        sparseScheduleAxisNameMatches(tile.axis, instance.row_axis, "_tile") and
        lane.target == .thread_x and
        lane.extent == instance.threads and
        sparseScheduleAxisNameMatches(lane.axis, instance.row_axis, "_lane");
}

pub fn spmvSellLaunchExtent(instance: SpmvSell) u64 {
    return spmvSellLaunchExtentChecked(instance).?;
}

fn spmvSellLaunchExtentChecked(instance: SpmvSell) ?u64 {
    return switch (instance.structure) {
        .row_thread => instance.rows,
    };
}

pub fn spmvSellRepresentableThreads(instance: SpmvSell) ?u32 {
    const launch_extent = spmvSellLaunchExtentChecked(instance) orelse return null;
    return std.math.cast(u32, @min(@as(u64, instance.threads), launch_extent));
}

pub fn spmvSellThreadCandidatesForRows(rows: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(rows, spmv_sell_thread_caps);
}

pub fn spmmCsrThreadsForExtents(rows: u64, columns: u64) entry.Threads2D {
    return geometry_mod.threadsForGrid(.{ .rows = rows, .cols = columns }, spmm_csr_thread_caps);
}

pub fn spmmCsrThreadCandidatesForExtents(rows: u64, columns: u64) geometry_mod.ThreadCandidates {
    return geometry_mod.threadCandidatesForGrid(.{ .rows = rows, .cols = columns }, spmm_csr_thread_caps);
}

pub fn spmmCsrRepresentableThreads(instance: SpmmCsr) ?entry.Threads2D {
    if (instance.threads.x == 0 or instance.threads.y == 0) return null;
    const x = @min(@as(u64, instance.threads.x), instance.columns);
    const y = @min(@as(u64, instance.threads.y), instance.rows);
    if (x == 0 or y == 0) return null;
    var candidate = instance;
    candidate.threads = .{ .x = @intCast(x), .y = @intCast(y) };
    if (!spmmCsrInstanceValid(candidate)) return null;
    return candidate.threads;
}

pub fn spmvSellFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: SpmvSell,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
    inputs[0] = try entry.runtimeShape1D(
        lifetime_allocator,
        instance.slice_axis,
        spmvSellSliceCount(instance) + 1,
    );
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, instance.value_axis, instance.values_size);
    inputs[2] = try entry.runtimeShape1D(lifetime_allocator, instance.value_axis, instance.values_size);
    inputs[3] = try entry.runtimeShape1D(lifetime_allocator, instance.x_axis, instance.x_extent);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows);

    const static_parameters = try lifetime_allocator.alloc(entry.StaticParameter, 1);
    static_parameters[0] = try entry.runtimeStaticParameter(
        lifetime_allocator,
        spmv_sell_slice_size_parameter,
        instance.slice_size,
    );

    owned.value = .{
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .operation = .{ .sparse = .sell_spmv },
        .inputs = inputs,
        .outputs = outputs,
        .static_parameters = static_parameters,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.row_axis,
            spmvSellLaunchExtent(instance),
            instance.threads,
        ),
        .structure = @tagName(instance.structure),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try spmvSellShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn spmvSellInstanceFromSpecialization(specialization: entry.Specialization) ?SpmvSell {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.staticParametersAreValid()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .sparse = .sell_spmv })) return null;
    const dtype = specialization.dtype orelse return null;
    const accumulation_dtype = spmvSellAccumulationDType(dtype) orelse return null;
    if (specialization.accumulation_dtype != accumulation_dtype) return null;
    if (specialization.inputs.len != 4 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    if (specialization.static_parameters.len != 1) return null;
    const slice_offsets = specialization.inputs[0];
    const cols = specialization.inputs[1];
    const values = specialization.inputs[2];
    const x = specialization.inputs[3];
    const y = specialization.outputs[0];
    if (slice_offsets.axes.len != 1 or cols.axes.len != 1 or values.axes.len != 1 or x.axes.len != 1 or y.axes.len != 1) return null;
    if (slice_offsets.axes[0].name.len == 0 or cols.axes[0].name.len == 0 or x.axes[0].name.len == 0 or y.axes[0].name.len == 0) return null;
    if (slice_offsets.axes[0].extent <= 1 or cols.axes[0].extent == 0 or x.axes[0].extent == 0) return null;
    const slice_size = specialization.staticParameterValue(spmv_sell_slice_size_parameter) orelse return null;
    if (slice_size == 0 or slice_size > extent_mod.runtime_extent_max) return null;
    if (!sparseAxisMatches(values.axes[0], cols.axes[0].name, cols.axes[0].extent)) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const structure_name = specialization.structure orelse return null;
    const structure = std.meta.stringToEnum(SpmvSellStructure, structure_name) orelse return null;
    const instance = SpmvSell{
        .rows = y.axes[0].extent,
        .slice_size = slice_size,
        .values_size = cols.axes[0].extent,
        .x_extent = x.axes[0].extent,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = launch.threadgroup[0],
        .structure = structure,
        .row_axis = y.axes[0].name,
        .slice_axis = slice_offsets.axes[0].name,
        .value_axis = cols.axes[0].name,
        .x_axis = x.axes[0].name,
    };
    if (!spmvSellInstanceValid(instance)) return null;
    const slice_offsets_extent = std.math.add(u64, spmvSellSliceCount(instance), 1) catch return null;
    if (!sparseAxisMatches(slice_offsets.axes[0], instance.slice_axis, slice_offsets_extent)) return null;
    if (!spmvSellScheduleMatchesInstance(schedule, instance)) return null;
    return instance;
}

fn spmvSellScheduleMatchesInstance(schedule: entry.Schedule, instance: SpmvSell) bool {
    const extent = spmvSellLaunchExtentChecked(instance) orelse return false;
    if (extent <= instance.threads) {
        if (schedule.bindings.len != 1) return false;
        const binding = schedule.bindings[0];
        return sparseAxisMatches(.{ .name = binding.axis, .extent = binding.extent }, instance.row_axis, extent) and
            binding.target == .thread_x;
    }
    if (schedule.bindings.len != 2) return false;
    const tile = schedule.bindings[0];
    const lane = schedule.bindings[1];
    const blocks = spmvSellBlockCountChecked(instance) orelse return false;
    return tile.target == .block_x and
        tile.extent == blocks and
        sparseScheduleAxisNameMatches(tile.axis, instance.row_axis, "_tile") and
        lane.target == .thread_x and
        lane.extent == instance.threads and
        sparseScheduleAxisNameMatches(lane.axis, instance.row_axis, "_lane");
}

pub fn spmmCsrFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: SpmmCsr,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.row_axis, instance.rows + 1);
    inputs[1] = try entry.runtimeShape1D(lifetime_allocator, spmv_csr_nonzero_axis, instance.nnz);
    inputs[2] = try entry.runtimeShape1D(lifetime_allocator, spmv_csr_nonzero_axis, instance.nnz);
    inputs[3] = try entry.runtimeShape2D(
        lifetime_allocator,
        instance.x_axis,
        instance.x_extent,
        instance.column_axis,
        instance.columns,
    );

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape2D(lifetime_allocator, instance.row_axis, instance.rows, instance.column_axis, instance.columns);

    owned.value = .{
        .dtype = instance.dtype,
        .accumulation_dtype = instance.accumulation_dtype,
        .operation = .{ .sparse = .csr_spmm },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks2D(
            lifetime_allocator,
            instance.column_axis,
            instance.columns,
            instance.row_axis,
            instance.rows,
            instance.threads.x,
            instance.threads.y,
        ),
        .structure = @tagName(instance.structure),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try spmmCsrShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn spmmCsrInstanceFromSpecialization(specialization: entry.Specialization) ?SpmmCsr {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const schedule = specialization.schedule orelse return null;
    if (!specialization.operationIs(.{ .sparse = .csr_spmm })) return null;
    const dtype = specialization.dtype orelse return null;
    const accumulation_dtype = spmmCsrAccumulationDType(dtype) orelse return null;
    if (specialization.accumulation_dtype != accumulation_dtype) return null;
    if (specialization.inputs.len != 4 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const row_ptr = specialization.inputs[0];
    const cols = specialization.inputs[1];
    const values = specialization.inputs[2];
    const x = specialization.inputs[3];
    const y = specialization.outputs[0];
    if (row_ptr.axes.len != 1 or cols.axes.len != 1 or values.axes.len != 1 or x.axes.len != 2 or y.axes.len != 2) return null;
    if (y.axes[0].name.len == 0 or y.axes[1].name.len == 0) return null;
    if (cols.axes[0].extent == 0 or x.axes[0].extent == 0 or x.axes[1].extent == 0) return null;
    const row_ptr_extent = std.math.add(u64, y.axes[0].extent, 1) catch return null;
    if (!sparseAxisMatches(row_ptr.axes[0], y.axes[0].name, row_ptr_extent)) return null;
    if (!sparseAxisMatches(cols.axes[0], spmv_csr_nonzero_axis, cols.axes[0].extent)) return null;
    if (!sparseAxisMatches(values.axes[0], spmv_csr_nonzero_axis, cols.axes[0].extent)) return null;
    if (!sparseAxisMatches(x.axes[1], y.axes[1].name, y.axes[1].extent)) return null;
    if (x.axes[0].name.len == 0) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0 or launch.threadgroup[1] == 0) return null;
    const structure_name = specialization.structure orelse return null;
    const structure = std.meta.stringToEnum(SpmmCsrStructure, structure_name) orelse return null;
    const instance = SpmmCsr{
        .rows = y.axes[0].extent,
        .columns = y.axes[1].extent,
        .nnz = cols.axes[0].extent,
        .x_extent = x.axes[0].extent,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = .{ .x = launch.threadgroup[0], .y = launch.threadgroup[1] },
        .structure = structure,
        .row_axis = y.axes[0].name,
        .column_axis = y.axes[1].name,
        .x_axis = x.axes[0].name,
    };
    if (!spmmCsrInstanceValid(instance)) return null;
    if (!spmmCsrScheduleMatchesInstance(schedule, instance)) return null;
    return instance;
}

fn sparseScheduleBindingMatches(binding: entry.ScheduleBinding, axis: []const u8, extent: u64, target: kernel.BindTarget) bool {
    return binding.target == target and sparseAxisMatches(.{ .name = binding.axis, .extent = binding.extent }, axis, extent);
}

fn sparseScheduleTiledAxisMatches(
    tile: entry.ScheduleBinding,
    lane: entry.ScheduleBinding,
    axis: []const u8,
    blocks: u64,
    threads: u32,
    block_target: kernel.BindTarget,
    thread_target: kernel.BindTarget,
) bool {
    return tile.target == block_target and
        tile.extent == blocks and
        sparseScheduleAxisNameMatches(tile.axis, axis, "_tile") and
        lane.target == thread_target and
        lane.extent == threads and
        sparseScheduleAxisNameMatches(lane.axis, axis, "_lane");
}

fn spmmCsrScheduleMatchesInstance(schedule: entry.Schedule, instance: SpmmCsr) bool {
    const x_tiled = instance.columns > instance.threads.x;
    const y_tiled = instance.rows > instance.threads.y;
    const expected_count: usize = @as(usize, if (x_tiled) 2 else 1) + @as(usize, if (y_tiled) 2 else 1);
    if (schedule.bindings.len != expected_count) return false;
    var index: usize = 0;
    if (x_tiled) {
        const blocks = spmmCsrBlockCountXChecked(instance) orelse return false;
        if (!sparseScheduleTiledAxisMatches(
            schedule.bindings[index],
            schedule.bindings[index + 1],
            instance.column_axis,
            blocks,
            instance.threads.x,
            .block_x,
            .thread_x,
        )) return false;
        index += 2;
    } else {
        if (!sparseScheduleBindingMatches(schedule.bindings[index], instance.column_axis, instance.columns, .thread_x)) return false;
        index += 1;
    }
    if (y_tiled) {
        const blocks = spmmCsrBlockCountYChecked(instance) orelse return false;
        if (!sparseScheduleTiledAxisMatches(
            schedule.bindings[index],
            schedule.bindings[index + 1],
            instance.row_axis,
            blocks,
            instance.threads.y,
            .block_y,
            .thread_y,
        )) return false;
    } else {
        if (!sparseScheduleBindingMatches(schedule.bindings[index], instance.row_axis, instance.rows, .thread_y)) return false;
    }
    return true;
}

test "sparse spmv csr specialization round-trips both structures" {
    const allocator = testing.allocator;

    inline for ([_]SpmvCsrStructure{ .row_thread, .row_warp }) |structure| {
        var owned = try spmvCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64, .structure = structure },
        );
        defer owned.deinit();
        try testing.expect(owned.value.structureIs(@tagName(structure)));
        try testing.expect(owned.value.operationIs(.{ .sparse = .csr_spmv }));
        const recovered = spmvCsrInstanceFromSpecialization(owned.value) orelse {
            return error.TestExpectedSpmvCsrInstance;
        };
        try testing.expectEqual(@as(u64, 70), recovered.rows);
        try testing.expectEqual(@as(u64, 512), recovered.nnz);
        try testing.expectEqual(@as(u64, 40), recovered.x_extent);
        try testing.expectEqual(@as(u32, 64), recovered.threads);
        try testing.expectEqual(structure, recovered.structure);
    }

    var f16_owned = try spmvCsrFamilySpecialization(
        allocator,
        .{ .rows = 70, .nnz = 512, .x_extent = 40, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
    );
    defer f16_owned.deinit();
    try testing.expectEqual(@as(?DType, .f16), f16_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f32), f16_owned.value.accumulation_dtype);
    const f16_recovered = spmvCsrInstanceFromSpecialization(f16_owned.value) orelse {
        return error.TestExpectedSpmvCsrInstance;
    };
    try testing.expectEqual(DType.f16, f16_recovered.dtype);
    try testing.expectEqual(DType.f32, f16_recovered.accumulation_dtype);

    var f64_owned = try spmvCsrFamilySpecialization(
        allocator,
        .{ .rows = 70, .nnz = 512, .x_extent = 40, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
    );
    defer f64_owned.deinit();
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.accumulation_dtype);
    const f64_recovered = spmvCsrInstanceFromSpecialization(f64_owned.value) orelse {
        return error.TestExpectedSpmvCsrInstance;
    };
    try testing.expectEqual(DType.f64, f64_recovered.dtype);
    try testing.expectEqual(DType.f64, f64_recovered.accumulation_dtype);
    try testing.expectEqual(@as(?SpmvCsr, null), spmvCsrInstanceFromSpecialization(.{}));
}

test "sparse spmv coo specialization round-trips element-thread metadata" {
    const allocator = testing.allocator;

    var owned = try spmvCooFamilySpecialization(
        allocator,
        .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64 },
    );
    defer owned.deinit();
    try testing.expect(owned.value.structureIs("element_thread"));
    try testing.expect(owned.value.operationIs(.{ .sparse = .coo_spmv }));
    const recovered = spmvCooInstanceFromSpecialization(owned.value) orelse {
        return error.TestExpectedSpmvCooInstance;
    };
    try testing.expectEqual(@as(u64, 70), recovered.rows);
    try testing.expectEqual(@as(u64, 512), recovered.nnz);
    try testing.expectEqual(@as(u64, 40), recovered.x_extent);
    try testing.expectEqual(@as(u32, 64), recovered.threads);
    try testing.expectEqual(SpmvCooStructure.element_thread, recovered.structure);
    try testing.expectEqualStrings("n", recovered.nonzero_axis);
    try testing.expectEqualStrings("x", recovered.x_axis);

    var f16_owned = try spmvCooFamilySpecialization(
        allocator,
        .{ .rows = 70, .nnz = 512, .x_extent = 40, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64, .structure = .row_thread },
    );
    defer f16_owned.deinit();
    try testing.expect(f16_owned.value.structureIs("row_thread"));
    try testing.expectEqual(@as(?DType, .f16), f16_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f32), f16_owned.value.accumulation_dtype);
    const f16_recovered = spmvCooInstanceFromSpecialization(f16_owned.value) orelse {
        return error.TestExpectedSpmvCooInstance;
    };
    try testing.expectEqual(DType.f16, f16_recovered.dtype);
    try testing.expectEqual(DType.f32, f16_recovered.accumulation_dtype);
    try testing.expectEqual(SpmvCooStructure.row_thread, f16_recovered.structure);

    var f64_owned = try spmvCooFamilySpecialization(
        allocator,
        .{ .rows = 70, .nnz = 512, .x_extent = 40, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64, .structure = .row_thread },
    );
    defer f64_owned.deinit();
    try testing.expect(f64_owned.value.structureIs("row_thread"));
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.accumulation_dtype);
    const f64_recovered = spmvCooInstanceFromSpecialization(f64_owned.value) orelse {
        return error.TestExpectedSpmvCooInstance;
    };
    try testing.expectEqual(DType.f64, f64_recovered.dtype);
    try testing.expectEqual(DType.f64, f64_recovered.accumulation_dtype);
    try testing.expectEqual(SpmvCooStructure.row_thread, f64_recovered.structure);

    try testing.expectEqual(@as(?SpmvCoo, null), spmvCooInstanceFromSpecialization(.{}));
}

test "sparse spmv ell specialization round-trips padded matrix metadata" {
    const allocator = testing.allocator;

    var owned = try spmvEllFamilySpecialization(
        allocator,
        .{ .rows = 70, .slots = 8, .x_extent = 40, .threads = 64 },
    );
    defer owned.deinit();
    try testing.expect(owned.value.structureIs("row_thread"));
    try testing.expect(owned.value.operationIs(.{ .sparse = .ell_spmv }));
    const recovered = spmvEllInstanceFromSpecialization(owned.value) orelse {
        return error.TestExpectedSpmvEllInstance;
    };
    try testing.expectEqual(@as(u64, 70), recovered.rows);
    try testing.expectEqual(@as(u64, 8), recovered.slots);
    try testing.expectEqual(@as(u64, 40), recovered.x_extent);
    try testing.expectEqual(@as(u32, 64), recovered.threads);
    try testing.expectEqual(SpmvEllStructure.row_thread, recovered.structure);
    try testing.expectEqualStrings("s", recovered.slot_axis);
    try testing.expectEqualStrings("x", recovered.x_axis);

    var f16_owned = try spmvEllFamilySpecialization(
        allocator,
        .{ .rows = 70, .slots = 8, .x_extent = 40, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
    );
    defer f16_owned.deinit();
    try testing.expectEqual(@as(?DType, .f16), f16_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f32), f16_owned.value.accumulation_dtype);
    const f16_recovered = spmvEllInstanceFromSpecialization(f16_owned.value) orelse {
        return error.TestExpectedSpmvEllInstance;
    };
    try testing.expectEqual(DType.f16, f16_recovered.dtype);
    try testing.expectEqual(DType.f32, f16_recovered.accumulation_dtype);

    var f64_owned = try spmvEllFamilySpecialization(
        allocator,
        .{ .rows = 70, .slots = 8, .x_extent = 40, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
    );
    defer f64_owned.deinit();
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.accumulation_dtype);
    const f64_recovered = spmvEllInstanceFromSpecialization(f64_owned.value) orelse {
        return error.TestExpectedSpmvEllInstance;
    };
    try testing.expectEqual(DType.f64, f64_recovered.dtype);
    try testing.expectEqual(DType.f64, f64_recovered.accumulation_dtype);
    try testing.expectEqual(@as(?SpmvEll, null), spmvEllInstanceFromSpecialization(.{}));
}

test "sparse spmv sell specialization round-trips sliced matrix metadata" {
    const allocator = testing.allocator;

    var owned = try spmvSellFamilySpecialization(
        allocator,
        .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
    );
    defer owned.deinit();
    try testing.expect(owned.value.structureIs("row_thread"));
    try testing.expect(owned.value.operationIs(.{ .sparse = .sell_spmv }));
    try testing.expect(owned.value.staticParameterMatches(spmv_sell_slice_size_parameter, 8));
    const recovered = spmvSellInstanceFromSpecialization(owned.value) orelse {
        return error.TestExpectedSpmvSellInstance;
    };
    try testing.expectEqual(@as(u64, 70), recovered.rows);
    try testing.expectEqual(@as(u64, 8), recovered.slice_size);
    try testing.expectEqual(@as(u64, 400), recovered.values_size);
    try testing.expectEqual(@as(u64, 40), recovered.x_extent);
    try testing.expectEqual(@as(u32, 64), recovered.threads);
    try testing.expectEqual(SpmvSellStructure.row_thread, recovered.structure);
    try testing.expectEqualStrings("z", recovered.slice_axis);
    try testing.expectEqualStrings("n", recovered.value_axis);
    try testing.expectEqualStrings("x", recovered.x_axis);

    var f16_owned = try spmvSellFamilySpecialization(
        allocator,
        .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .dtype = .f16, .accumulation_dtype = .f32, .threads = 64 },
    );
    defer f16_owned.deinit();
    try testing.expectEqual(@as(?DType, .f16), f16_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f32), f16_owned.value.accumulation_dtype);
    const f16_recovered = spmvSellInstanceFromSpecialization(f16_owned.value) orelse {
        return error.TestExpectedSpmvSellInstance;
    };
    try testing.expectEqual(DType.f16, f16_recovered.dtype);
    try testing.expectEqual(DType.f32, f16_recovered.accumulation_dtype);
    try testing.expectEqual(@as(u64, 8), f16_recovered.slice_size);

    var f64_owned = try spmvSellFamilySpecialization(
        allocator,
        .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .dtype = .f64, .accumulation_dtype = .f64, .threads = 64 },
    );
    defer f64_owned.deinit();
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.accumulation_dtype);
    const f64_recovered = spmvSellInstanceFromSpecialization(f64_owned.value) orelse {
        return error.TestExpectedSpmvSellInstance;
    };
    try testing.expectEqual(DType.f64, f64_recovered.dtype);
    try testing.expectEqual(DType.f64, f64_recovered.accumulation_dtype);
    try testing.expectEqual(@as(u64, 8), f64_recovered.slice_size);
    try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(.{}));
}

test "sparse spmm csr specialization round-trips matrix metadata" {
    const allocator = testing.allocator;

    var owned = try spmmCsrFamilySpecialization(
        allocator,
        .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40, .threads = .{ .x = 8, .y = 4 } },
    );
    defer owned.deinit();
    try testing.expect(owned.value.structureIs("row_column_thread"));
    try testing.expect(owned.value.operationIs(.{ .sparse = .csr_spmm }));
    const recovered = spmmCsrInstanceFromSpecialization(owned.value) orelse {
        return error.TestExpectedSpmmCsrInstance;
    };
    try testing.expectEqual(@as(u64, 70), recovered.rows);
    try testing.expectEqual(@as(u64, 45), recovered.columns);
    try testing.expectEqual(@as(u64, 512), recovered.nnz);
    try testing.expectEqual(@as(u64, 40), recovered.x_extent);
    try testing.expectEqual(@as(u32, 8), recovered.threads.x);
    try testing.expectEqual(@as(u32, 4), recovered.threads.y);
    try testing.expectEqual(SpmmCsrStructure.row_column_thread, recovered.structure);

    var f16_owned = try spmmCsrFamilySpecialization(
        allocator,
        .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40, .dtype = .f16, .accumulation_dtype = .f32, .threads = .{ .x = 8, .y = 4 } },
    );
    defer f16_owned.deinit();
    try testing.expectEqual(@as(?DType, .f16), f16_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f32), f16_owned.value.accumulation_dtype);
    const f16_recovered = spmmCsrInstanceFromSpecialization(f16_owned.value) orelse {
        return error.TestExpectedSpmmCsrInstance;
    };
    try testing.expectEqual(DType.f16, f16_recovered.dtype);
    try testing.expectEqual(DType.f32, f16_recovered.accumulation_dtype);

    var f64_owned = try spmmCsrFamilySpecialization(
        allocator,
        .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40, .dtype = .f64, .accumulation_dtype = .f64, .threads = .{ .x = 8, .y = 4 } },
    );
    defer f64_owned.deinit();
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.dtype);
    try testing.expectEqual(@as(?DType, .f64), f64_owned.value.accumulation_dtype);
    const f64_recovered = spmmCsrInstanceFromSpecialization(f64_owned.value) orelse {
        return error.TestExpectedSpmmCsrInstance;
    };
    try testing.expectEqual(DType.f64, f64_recovered.dtype);
    try testing.expectEqual(DType.f64, f64_recovered.accumulation_dtype);
    try testing.expectEqual(@as(?SpmmCsr, null), spmmCsrInstanceFromSpecialization(.{}));
}

test "sparse spmv csr specialization rejects malformed descriptor facts" {
    const allocator = testing.allocator;

    {
        var owned = try spmvCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64, .structure = .row_thread },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = try entry.runtimeShape1D(lifetime_allocator, "bad_x", 40);
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvCsr, null), spmvCsrInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64, .structure = .row_thread },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        const zero_x_axes = try lifetime_allocator.alloc(entry.Axis, 1);
        zero_x_axes[0] = .{ .name = spmv_csr_column_axis, .extent = 0 };
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = .{ .axes = zero_x_axes };
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvCsr, null), spmvCsrInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64, .structure = .row_thread },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
        const y_axes = try lifetime_allocator.alloc(entry.Axis, 1);
        y_axes[0] = .{ .name = "r", .extent = std.math.maxInt(u64) };
        outputs[0] = .{ .axes = y_axes };
        owned.value.outputs = outputs;
        try testing.expectEqual(@as(?SpmvCsr, null), spmvCsrInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64, .structure = .row_warp },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const rows = std.math.maxInt(u64) / @as(u64, spmv_csr_warp_size) + 1;
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        const row_ptr_axes = try lifetime_allocator.alloc(entry.Axis, 1);
        row_ptr_axes[0] = .{ .name = "r", .extent = rows + 1 };
        inputs[0] = .{ .axes = row_ptr_axes };
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = owned.value.inputs[3];
        owned.value.inputs = inputs;
        const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
        const y_axes = try lifetime_allocator.alloc(entry.Axis, 1);
        y_axes[0] = .{ .name = "r", .extent = rows };
        outputs[0] = .{ .axes = y_axes };
        owned.value.outputs = outputs;
        try testing.expectEqual(@as(?SpmvCsr, null), spmvCsrInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64, .structure = .row_warp },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "r", 70, 64);
        owned.value.launch = owned.value.schedule.?.launch();
        try testing.expectEqual(@as(?SpmvCsr, null), spmvCsrInstanceFromSpecialization(owned.value));
    }
}

test "sparse spmv coo specialization rejects malformed descriptor facts" {
    const allocator = testing.allocator;

    {
        var owned = try spmvCooFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = try entry.runtimeShape1D(lifetime_allocator, "bad_n", 512);
        inputs[2] = owned.value.inputs[2];
        inputs[3] = owned.value.inputs[3];
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvCoo, null), spmvCooInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvCooFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        const zero_nnz_axes = try lifetime_allocator.alloc(entry.Axis, 1);
        zero_nnz_axes[0] = .{ .name = "n", .extent = 0 };
        inputs[0] = .{ .axes = zero_nnz_axes };
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = owned.value.inputs[3];
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvCoo, null), spmvCooInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvCooFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "r", 70, 64);
        owned.value.launch = owned.value.schedule.?.launch();
        try testing.expectEqual(@as(?SpmvCoo, null), spmvCooInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvCooFamilySpecialization(
            allocator,
            .{ .rows = 70, .nnz = 512, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        owned.value.structure = "row_thread";
        try testing.expectEqual(@as(?SpmvCoo, null), spmvCooInstanceFromSpecialization(owned.value));
    }
}

test "sparse spmv ell specialization rejects malformed descriptor facts" {
    const allocator = testing.allocator;

    {
        var owned = try spmvEllFamilySpecialization(
            allocator,
            .{ .rows = 70, .slots = 8, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 3);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = try entry.runtimeShape2D(lifetime_allocator, "s", 8, "bad_r", 70);
        inputs[2] = owned.value.inputs[2];
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvEll, null), spmvEllInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvEllFamilySpecialization(
            allocator,
            .{ .rows = 70, .slots = 8, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 3);
        const zero_slot_axes = try lifetime_allocator.alloc(entry.Axis, 2);
        zero_slot_axes[0] = .{ .name = "s", .extent = 0 };
        zero_slot_axes[1] = .{ .name = "r", .extent = 70 };
        inputs[0] = .{ .axes = zero_slot_axes };
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvEll, null), spmvEllInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvEllFamilySpecialization(
            allocator,
            .{ .rows = 70, .slots = 8, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 3);
        const zero_x_axes = try lifetime_allocator.alloc(entry.Axis, 1);
        zero_x_axes[0] = .{ .name = "x", .extent = 0 };
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = .{ .axes = zero_x_axes };
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvEll, null), spmvEllInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvEllFamilySpecialization(
            allocator,
            .{ .rows = 70, .slots = 8, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "bad_r", 70, 64);
        owned.value.launch = owned.value.schedule.?.launch();
        try testing.expectEqual(@as(?SpmvEll, null), spmvEllInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvEllFamilySpecialization(
            allocator,
            .{ .rows = 70, .slots = 8, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        owned.value.structure = "row_warp";
        try testing.expectEqual(@as(?SpmvEll, null), spmvEllInstanceFromSpecialization(owned.value));
    }
}

test "sparse spmv sell specialization rejects malformed descriptor facts" {
    const allocator = testing.allocator;

    {
        var owned = try spmvSellFamilySpecialization(
            allocator,
            .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        owned.value.static_parameters = &.{};
        try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvSellFamilySpecialization(
            allocator,
            .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const static_parameters = try lifetime_allocator.alloc(entry.StaticParameter, 2);
        static_parameters[0] = owned.value.static_parameters[0];
        static_parameters[1] = try entry.runtimeStaticParameter(lifetime_allocator, spmv_sell_slice_size_parameter, 8);
        owned.value.static_parameters = static_parameters;
        try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvSellFamilySpecialization(
            allocator,
            .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const static_parameters = try lifetime_allocator.alloc(entry.StaticParameter, 2);
        static_parameters[0] = owned.value.static_parameters[0];
        static_parameters[1] = try entry.runtimeStaticParameter(lifetime_allocator, "unused", 1);
        owned.value.static_parameters = static_parameters;
        try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvSellFamilySpecialization(
            allocator,
            .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        inputs[0] = try entry.runtimeShape1D(lifetime_allocator, "z", 9);
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = owned.value.inputs[3];
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvSellFamilySpecialization(
            allocator,
            .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = try entry.runtimeShape1D(lifetime_allocator, "bad_n", 400);
        inputs[3] = owned.value.inputs[3];
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvSellFamilySpecialization(
            allocator,
            .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "bad_r", 70, 64);
        owned.value.launch = owned.value.schedule.?.launch();
        try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmvSellFamilySpecialization(
            allocator,
            .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40, .threads = 64 },
        );
        defer owned.deinit();
        owned.value.structure = "row_warp";
        try testing.expectEqual(@as(?SpmvSell, null), spmvSellInstanceFromSpecialization(owned.value));
    }
}

test "sparse spmm csr specialization rejects malformed descriptor facts" {
    const allocator = testing.allocator;

    {
        var owned = try spmmCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40, .threads = .{ .x = 8, .y = 4 } },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = try entry.runtimeShape2D(lifetime_allocator, "x", 40, "bad_c", 45);
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmmCsr, null), spmmCsrInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmmCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40, .threads = .{ .x = 8, .y = 4 } },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        const zero_x_axes = try lifetime_allocator.alloc(entry.Axis, 2);
        zero_x_axes[0] = .{ .name = "x", .extent = 0 };
        zero_x_axes[1] = .{ .name = "c", .extent = 45 };
        inputs[0] = owned.value.inputs[0];
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = .{ .axes = zero_x_axes };
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmmCsr, null), spmmCsrInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmmCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40, .threads = .{ .x = 8, .y = 4 } },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
        inputs[0] = try entry.runtimeShape1D(lifetime_allocator, "r", 70);
        inputs[1] = owned.value.inputs[1];
        inputs[2] = owned.value.inputs[2];
        inputs[3] = owned.value.inputs[3];
        owned.value.inputs = inputs;
        try testing.expectEqual(@as(?SpmmCsr, null), spmmCsrInstanceFromSpecialization(owned.value));
    }

    {
        var owned = try spmmCsrFamilySpecialization(
            allocator,
            .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40, .threads = .{ .x = 8, .y = 4 } },
        );
        defer owned.deinit();
        const lifetime_allocator = owned.allocator();
        owned.value.schedule = try entry.runtimeThreadBlocks2D(lifetime_allocator, "bad_c", 45, "r", 70, 8, 4);
        owned.value.launch = owned.value.schedule.?.launch();
        try testing.expectEqual(@as(?SpmmCsr, null), spmmCsrInstanceFromSpecialization(owned.value));
    }
}
