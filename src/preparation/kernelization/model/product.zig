const records = @import("../../../choir/root.zig").record;
const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const kernel_program = @import("../../../kernel/model/program/root.zig");
const kernel_schedule = @import("../../../kernel/model/core/schedule/root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const MemrefDialect = dialects.MemrefDialect;
const accounting = choir.passes.pass.work;

pub const ElementwiseKernel = enum {
    add,
    sub,
    mul,
    div,
    min,
    max,
    neg,
    abs,
    sqrt,
    exp,
    log,
    tanh,
    sin,
    cos,
    tan,
    floor,
    round,
    trunc,
    pow,
    atan2,
    convert,
    compare,
    select,
};

pub const ShapeKernel = enum {
    broadcast_in_dim,
    iota,
    reshape,
    transpose,
    slice,
    pad,
    concatenate,
    gather,
    scatter,
};

pub const GeneratedScheduleKind = records.kernel.GeneratedScheduleKind;

pub const GeneratedSchedule = records.kernel.GeneratedSchedule;

pub const GeneratedKernelProgram = kernel_program.Program;

pub const GeneratedKernelSummary = struct {
    work_item_id: usize,
    entry_name: []const u8,
    argument_count: u32,
    body_fingerprint: u64,
    dynamic_shared_memory_bytes: u32 = 0,
    schedule: GeneratedSchedule,
    launch_geometry: ?gpu_abi.LaunchGeometry,
};

pub const GeneratedKernelSummaries = struct {
    allocator: std.mem.Allocator,
    items: []GeneratedKernelSummary,

    pub fn deinit(self: *GeneratedKernelSummaries) void {
        for (self.items) |item| {
            self.allocator.free(item.entry_name);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn len(self: *const GeneratedKernelSummaries) usize {
        return self.items.len;
    }

    pub fn summary(
        self: *const GeneratedKernelSummaries,
        kernel_index: usize,
    ) !GeneratedKernelSummary {
        if (kernel_index >= self.items.len) return error.InvalidIndex;
        return self.items[kernel_index];
    }

    pub fn summaryForWork(
        self: *const GeneratedKernelSummaries,
        work_item_id: usize,
    ) !GeneratedKernelSummary {
        for (self.items) |item| {
            if (item.work_item_id == work_item_id) return item;
        }
        return error.MissingKernelization;
    }
};

pub const RowPipelinePlan = records.kernel.RowPipelinePlan;

pub const FlashAttentionPlan = records.kernel.FlashAttentionPlan;

pub const ScanPlan = records.kernel.ScanPlan;

pub const ElementwiseRank2Plan = records.kernel.ElementwiseRank2Plan;

pub const LoweredKernelBody = records.kernel.LoweredKernelBody;

pub const ElementwiseVectorPlan = records.kernel.ElementwiseVectorPlan;

pub const ReductionWarpRowsPlan = records.kernel.ReductionWarpRowsPlan;

pub const LoweredKernel = struct {
    work_item_id: usize,
    entry_name: []u8,
    program: kernel_program.Program,
    argument_count: u32,
    body_fingerprint: u64,
    dynamic_shared_memory_bytes: u32 = 0,
    schedule: GeneratedSchedule,
    launch: ?kernel_schedule.Launch = null,
    output_fill_pattern: ?u32 = null,
    scratch_fill_pattern: ?u32 = null,
    body: LoweredKernelBody = .generic,

    pub fn deinit(self: *LoweredKernel, allocator: std.mem.Allocator) void {
        self.program.deinit();
        allocator.free(self.entry_name);
        self.* = undefined;
    }

    pub fn runtimeScalarArgumentCount(self: *const LoweredKernel) u32 {
        var count: u32 = 0;
        for (self.program.params()) |param| {
            switch (param) {
                .scalar => count += 1,
                .buffer => {},
            }
        }
        return count;
    }

    pub fn requiredDTypes(self: *const LoweredKernel) gpu.DTypeSet {
        var dtypes: gpu.DTypeSet = .{};
        for (self.program.params()) |param| {
            switch (param) {
                .scalar => |dtype| dtypes.insert(dtype),
                .buffer => |buffer| dtypes.insert(buffer.dtype),
            }
        }
        return dtypes;
    }

    pub fn launchGeometry(self: *const LoweredKernel) ?gpu_abi.LaunchGeometry {
        const launch_value = self.launch orelse return null;
        return .{
            .grid = launch_value.grid,
            .threadgroup = launch_value.block,
            .dynamic_shared_memory_bytes = self.dynamic_shared_memory_bytes,
        };
    }

    pub fn summary(self: *const LoweredKernel) GeneratedKernelSummary {
        return .{
            .work_item_id = self.work_item_id,
            .entry_name = self.entry_name,
            .argument_count = self.argument_count,
            .body_fingerprint = self.body_fingerprint,
            .dynamic_shared_memory_bytes = self.dynamic_shared_memory_bytes,
            .schedule = self.schedule,
            .launch_geometry = self.launchGeometry(),
        };
    }
};

pub const KernelizationAnalysis = struct {
    allocator: std.mem.Allocator,
    context: *ir.Context,
    kernels: std.ArrayListUnmanaged(LoweredKernel),
    work_to_kernel: std.AutoHashMap(usize, usize),

    /// The kernel stage calls this for its work bound to charge the result object before any kernel
    /// is generated, so compilation can refuse a pass that would exceed the caller's limits. That
    /// bound is the costs a pass declares before it runs. The bound covers the result object, its
    /// shared compiler context, and the list of kernels and the map from a scheduled unit of work
    /// to kernel, sized for `kernel_count` kernels. That context is the object that owns the
    /// operations and values of the generated kernels. Generated programs, names, generation
    /// scratch and the analyses it depends on are charged separately.
    pub fn baseStorageBound(limits: ir.Context.Limits, kernel_count: u64) !u64 {
        const context = ir.Context.Capacity.derive(limits) catch return error.WorkOverflow;
        var bytes: u64 = @sizeOf(KernelizationAnalysis) + @alignOf(KernelizationAnalysis);
        bytes = try accounting.add(bytes, @sizeOf(ir.Context) + @alignOf(ir.Context));
        bytes = try accounting.add(bytes, context.storage_bytes);
        bytes = try accounting.add(bytes, context.storage_alignment.toByteUnits());
        const kernels = try accounting.arrayListGrowth(LoweredKernel, kernel_count);
        bytes = try accounting.add(bytes, kernels);
        bytes = try accounting.add(bytes, try accounting.hashMapGrowth(usize, usize, kernel_count));
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }

    pub fn reserveKernelCapacity(self: *KernelizationAnalysis, count: usize) !void {
        const map_count = std.math.cast(u32, count) orelse return error.InvalidArtifact;
        try self.kernels.ensureTotalCapacity(self.allocator, count);
        try self.work_to_kernel.ensureTotalCapacity(map_count);
    }

    pub fn init(allocator: std.mem.Allocator, limits: ir.Context.Limits) !KernelizationAnalysis {
        const context = try ir.Context.create(allocator, limits);
        errdefer {
            context.deinit(allocator);
            allocator.destroy(context);
        }
        dialects.registerChoirDialect(context) catch |err| {
            return if (err == error.OutOfMemory) error.WorkExhausted else err;
        };
        return .{
            .allocator = allocator,
            .context = context,
            .kernels = .empty,
            .work_to_kernel = std.AutoHashMap(usize, usize).init(allocator),
        };
    }

    pub fn deinit(self: *KernelizationAnalysis) void {
        for (self.kernels.items) |*kernel| {
            kernel.deinit(self.allocator);
        }
        self.kernels.deinit(self.allocator);
        self.work_to_kernel.deinit();
        self.context.deinit(self.allocator);
        self.allocator.destroy(self.context);
        self.* = undefined;
    }

    pub fn kernelCount(self: KernelizationAnalysis) usize {
        return self.kernels.items.len;
    }

    pub fn getForWork(
        self: *const KernelizationAnalysis,
        work_item_id: usize,
    ) ?*const LoweredKernel {
        const index = self.work_to_kernel.get(work_item_id) orelse return null;
        return &self.kernels.items[index];
    }

    pub fn kernelSummary(
        self: *const KernelizationAnalysis,
        kernel_index: usize,
    ) !GeneratedKernelSummary {
        const kernel_value = try self.kernelAt(kernel_index);
        return kernel_value.summary();
    }

    pub fn kernelProgram(
        self: *const KernelizationAnalysis,
        kernel_index: usize,
    ) !*const GeneratedKernelProgram {
        const kernel_value = try self.kernelAt(kernel_index);
        return &kernel_value.program;
    }

    pub fn kernelSummaryForWork(
        self: *const KernelizationAnalysis,
        work_item_id: usize,
    ) !GeneratedKernelSummary {
        const kernel_value = self.getForWork(work_item_id) orelse return error.MissingKernelization;
        return kernel_value.summary();
    }

    pub fn kernelProgramForWork(
        self: *const KernelizationAnalysis,
        work_item_id: usize,
    ) !*const GeneratedKernelProgram {
        const kernel_value = self.getForWork(work_item_id) orelse return error.MissingKernelization;
        return &kernel_value.program;
    }

    pub fn copyKernelSummaries(
        self: *const KernelizationAnalysis,
        result_allocator: std.mem.Allocator,
    ) !GeneratedKernelSummaries {
        const items = try result_allocator.alloc(GeneratedKernelSummary, self.kernels.items.len);
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |summary| {
                result_allocator.free(summary.entry_name);
            }
            result_allocator.free(items);
        }

        for (items, self.kernels.items) |*item, *kernel_value| {
            item.* = kernel_value.summary();
            item.entry_name = try result_allocator.dupe(u8, kernel_value.entry_name);
            copied += 1;
        }

        return .{
            .allocator = result_allocator,
            .items = items,
        };
    }

    fn kernelAt(
        self: *const KernelizationAnalysis,
        kernel_index: usize,
    ) !*const LoweredKernel {
        if (kernel_index >= self.kernels.items.len) return error.InvalidIndex;
        return &self.kernels.items[kernel_index];
    }
};

pub const DotGeneralStaticDims = records.kernel.DotGeneralStaticDims;

pub const DotGeneralDescription = struct {
    input_dtype: gpu_abi.DType,
    output_dtype: gpu_abi.DType,
    dims: DotGeneralStaticDims,
};

pub const DotGeneralBlockTile = records.kernel.DotGeneralBlockTile;

pub const reduction_single_block_threads: u32 = 256;
const reduction_single_block_min_extent: u32 = 256;
pub const reduction_warp_rows_threads: u32 = 256;
const reduction_warp_rows_min_cols: u32 = 128;

pub fn reductionWarpRowsThreads(dims: ReductionStaticDims) ?u32 {
    if (dims.input_rank != 2 or dims.axis != 1) return null;
    if (dims.cols < reduction_warp_rows_min_cols) return null;
    return reduction_warp_rows_threads;
}

pub fn reductionSingleBlockThreads(dims: ReductionStaticDims) ?u32 {
    if (dims.output_element_count != 1) return null;
    if (dims.input_element_count < reduction_single_block_min_extent) return null;
    return reduction_single_block_threads;
}

pub const ReductionAtomicPlan = records.kernel.ReductionAtomicPlan;

const reduction_atomic_min_extent: u32 = 4096;
const reduction_atomic_max_blocks: u32 = 512;
const reduction_atomic_target_chain: u32 = 32;

pub fn reductionAtomicPlanFor(
    dims: ReductionStaticDims,
    kind: ReductionKind,
    input_dtype: gpu_abi.DType,
    init_is_constant: bool,
) ?ReductionAtomicPlan {
    if (dims.output_element_count != 1) return null;
    if (dims.input_element_count < reduction_atomic_min_extent) return null;
    if (kind != .sum) return null;
    if (!init_is_constant) return null;
    switch (input_dtype) {
        .f32, .i32, .u32 => {},
        else => return null,
    }
    const threads = reduction_single_block_threads;
    const per_block = @as(u64, threads) * reduction_atomic_target_chain;
    const wanted = (dims.input_element_count + per_block - 1) / per_block;
    const blocks: u32 = @intCast(@min(@max(wanted, 1), reduction_atomic_max_blocks));
    return .{ .threads = threads, .blocks = blocks };
}

pub const DotGeneralMmaTile = records.kernel.DotGeneralMmaTile;

const mma_pipeline_max_blocks = 512;

pub fn dotGeneralMmaTileFor(desc: DotGeneralDescription) ?DotGeneralMmaTile {
    if (desc.input_dtype != .f32 or desc.output_dtype != .f32) return null;
    var tile = DotGeneralMmaTile{};
    if (!tile.exact(desc.dims)) return null;
    const blocks = @as(u64, desc.dims.batch) * (desc.dims.m / tile.bm) * (desc.dims.n / tile.bn);
    if (blocks < mma_pipeline_max_blocks) {
        tile.stages = 2;
    }
    if (desc.dims.batch == 1 and blocks < 32) {
        while (tile.splits < split_k_max) {
            const doubled = tile.splits * 2;
            if (blocks * tile.splits >= 128) break;
            if (desc.dims.k % doubled != 0) break;
            const chunk = desc.dims.k / doubled;
            if (chunk % (2 * @as(u64, tile.bk)) != 0 or chunk < 4 * @as(u64, tile.bk)) break;
            tile.splits = doubled;
        }
    }
    return tile;
}

const block_tile_min_blocks = 64;
const wide_block_tile_min_blocks = 128;

const wide_block_tile = DotGeneralBlockTile{ .bm = 128, .bn = 128, .bk = 16, .tm = 8, .tn = 8 };

const split_k_target_blocks = 256;
const split_k_max = 8;

pub fn dotGeneralBlockTileFor(desc: DotGeneralDescription) ?DotGeneralBlockTile {
    if (desc.input_dtype != .f32 or desc.output_dtype != .f32) return null;
    if (desc.dims.k >= 128 and blockTileFits(
        wide_block_tile,
        desc.dims,
        wide_block_tile_min_blocks,
    )) return wide_block_tile;
    var tile = DotGeneralBlockTile{ .stages = 4 };
    if (!blockTileFits(tile, desc.dims, block_tile_min_blocks)) return null;
    if (desc.dims.batch == 1) {
        const tiles = (desc.dims.m / tile.bm) * (desc.dims.n / tile.bn);
        while (tile.splits < split_k_max) {
            const doubled = tile.splits * 2;
            if (tiles * tile.splits >= split_k_target_blocks) break;
            if (desc.dims.k % doubled != 0) break;
            const chunk = desc.dims.k / doubled;
            if (chunk % tile.bk != 0 or chunk < 2 * tile.bk) break;
            tile.splits = doubled;
        }
    }
    return tile;
}

fn blockTileFits(tile: DotGeneralBlockTile, dims: DotGeneralStaticDims, min_blocks: u64) bool {
    if (dims.m < tile.bm or dims.n < tile.bn) return false;
    if (dims.k < tile.bk) return false;
    const threads = @as(u64, tile.threadsX()) * tile.threadsY();
    if ((@as(u64, tile.bm) * tile.bk) % threads != 0) return false;
    if ((@as(u64, tile.bk) * tile.bn) % threads != 0) return false;
    const tiles_m = (dims.m + tile.bm - 1) / tile.bm;
    const tiles_n = (dims.n + tile.bn - 1) / tile.bn;
    const blocks = @as(u64, dims.batch) * tiles_m * tiles_n;
    return blocks >= min_blocks;
}

pub const ReductionStaticDims = struct {
    input_rank: u8,
    axis: u8,
    input_element_count: u32,
    output_element_count: u32,
    rows: u32 = 1,
    cols: u32 = 1,
    inner: u32 = 1,
};

pub const ReductionKind = enum {
    sum,
    max,
    min,
};

pub const ReductionInitValue = union(enum) {
    f32: f32,
    i32: i32,
    u32: u32,
    f16: f16,
};

pub const ReductionInit = union(enum) {
    constant: ReductionInitValue,
    input_buffer,
};

pub const ReductionDescription = struct {
    kind: ReductionKind,
    input_dtype: gpu_abi.DType,
    output_dtype: gpu_abi.DType,
    dims: ReductionStaticDims,
    init: ReductionInit,
};

pub fn addKernel(analysis: *KernelizationAnalysis, kernel: LoweredKernel) !void {
    const index = analysis.kernels.items.len;
    try analysis.work_to_kernel.put(kernel.work_item_id, index);
    errdefer _ = analysis.work_to_kernel.remove(kernel.work_item_id);
    try analysis.kernels.append(analysis.allocator, kernel);
}

pub fn dynamicSharedMemoryBytes(module: *ir.Operation) gpu.BackendError!u32 {
    var state = DynamicSharedMemoryState{};
    _ = module.walk(
        .{ .order = .pre_order },
        &state,
        DynamicSharedMemoryState.visit,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArtifact => return error.InvalidArtifact,
        else => return error.InvalidArtifact,
    };
    return state.bytes;
}

const DynamicSharedMemoryState = struct {
    bytes: u32 = 0,

    fn visit(self: *@This(), op: *ir.Operation) gpu.BackendError!ir.Operation.WalkResult {
        if (!std.mem.eql(u8, op.name.name, MemrefDialect.AllocOp.operation_name)) return .advance;
        const alloc = MemrefDialect.AllocOp{ .op = op };
        if (alloc.getDynamicSize() == null) return .advance;
        const result = alloc.getResult();
        const params = dynamicSharedMemrefParams(result.type) orelse return error.InvalidArtifact;
        if (params.addr_space != .shared) return .advance;
        const size = params.size orelse return error.InvalidArtifact;
        const element_bytes = try dynamicSharedElementByteSize(params.element_type_name);
        const bytes = std.math.mul(u64, size, element_bytes) catch return error.InvalidArtifact;
        const end = std.math.add(
            u64,
            try dynamicSharedByteOffset(op),
            bytes,
        ) catch return error.InvalidArtifact;
        self.bytes = @max(self.bytes, std.math.cast(u32, end) orelse return error.InvalidArtifact);
        return .advance;
    }
};

fn dynamicSharedMemrefParams(typ: ir.Type) ?MemrefDialect.MemrefParams {
    const name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, name, MemrefDialect.name)) return null;
    return MemrefDialect.parseMemrefParams(typ.getDialectParamKey() orelse return null);
}

fn dynamicSharedByteOffset(op: *ir.Operation) gpu.BackendError!u32 {
    const attr_name = choir.dialects.gpu.attr_names.dynamic_shared_byte_offset;
    const attr = op.getAttrAs(ir.Attribute.IntegerAttr, attr_name) orelse return 0;
    const value = attr.getValue();
    if (value < 0) return error.InvalidArtifact;
    return std.math.cast(u32, value) orelse return error.InvalidArtifact;
}

fn dynamicSharedElementByteSize(type_name: []const u8) gpu.BackendError!u32 {
    const kind = dialects.arith.scalarKindFromTypeName(type_name) orelse
        return error.InvalidArtifact;
    return switch (kind) {
        .bool => 1,
        .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i64, .u64 => 8,
        .f64 => 8,
        .f16 => 2,
        .bf16 => 2,
        .index, .i32, .u32, .f32 => 4,
    };
}

test "kernelization model counts generated dynamic shared memory bytes" {
    const allocator = std.testing.allocator;

    var builder = try kernel_program.Builder.init(
        allocator,
        kernel_program.Builder.Limits.testing,
        "accy_dynamic_shared_product",
        &.{},
    );
    errdefer builder.deinit();

    _ = try builder.dynamicSharedBuffer(.f32, 4, 0);
    _ = try builder.dynamicSharedBuffer(.f32, 4, 64);
    _ = try builder.sharedBuffer(.f32, 256);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const entry_name = try allocator.dupe(u8, "accy_dynamic_shared_product");
    defer allocator.free(entry_name);

    try std.testing.expectEqual(@as(u32, 80), try dynamicSharedMemoryBytes(program.kernelModule()));
    try std.testing.expectEqual(@as(u32, 80), (LoweredKernel{
        .work_item_id = 0,
        .entry_name = entry_name,
        .program = program,
        .argument_count = 0,
        .body_fingerprint = 0,
        .dynamic_shared_memory_bytes = 80,
        .schedule = .{
            .kind = .flat,
            .threads = .{ .x = 64 },
        },
        .launch = .{
            .grid = .{ 1, 1, 1 },
            .block = .{ 64, 1, 1 },
        },
    }).summary().dynamic_shared_memory_bytes);
}

test "kernelization analysis storage bounds its real shared Context and containers" {
    for ([_]usize{ 0, 1, 7, 8, 63, 64, 257 }) |count| {
        try checkAnalysisStorage(ir.Context.Limits.testing, count);
    }
    try checkAnalysisStorage(ir.Context.Limits.standard, 1);
}

fn checkAnalysisStorage(limits: ir.Context.Limits, count: usize) !void {
    const bound = try KernelizationAnalysis.baseStorageBound(limits, count);
    const bytes = try std.testing.allocator.alloc(u8, @intCast(bound));
    defer std.testing.allocator.free(bytes);
    var buffer = std.heap.FixedBufferAllocator.init(bytes);
    const base = buffer.allocator();
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = base.vtable.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    };
    const allocator: std.mem.Allocator = .{ .ptr = base.ptr, .vtable = &vtable };
    const analysis = try allocator.create(KernelizationAnalysis);
    defer allocator.destroy(analysis);
    analysis.* = try KernelizationAnalysis.init(allocator, limits);
    defer analysis.deinit();
    try analysis.reserveKernelCapacity(count);
    try std.testing.expect(analysis.kernels.capacity >= count);
    try std.testing.expect(analysis.work_to_kernel.capacity() >= count);
    const reserved = buffer.end_index;
    for (0..count) |index| try analysis.work_to_kernel.put(index, index);
    try analysis.reserveKernelCapacity(count);
    try std.testing.expectEqual(reserved, buffer.end_index);
    try std.testing.expectEqual(count, analysis.work_to_kernel.count());
    try std.testing.expect(buffer.end_index <= bound);
    try std.testing.expectEqualDeep(limits, analysis.context.capacity.asLimits());
    try std.testing.expect(analysis.context.exhaustedSegment() == null);
}

test "kernelization analysis storage rejects unrepresentable bounds" {
    const standard = ir.Context.Limits.standard;
    try std.testing.expectError(
        error.WorkOverflow,
        KernelizationAnalysis.baseStorageBound(standard, std.math.maxInt(u64)),
    );
    try std.testing.expectError(
        error.WorkOverflow,
        KernelizationAnalysis.baseStorageBound(standard, std.math.maxInt(u32)),
    );
    var limits = standard;
    limits.operations.storage_bytes = std.math.maxInt(usize);
    try std.testing.expectError(
        error.WorkOverflow,
        KernelizationAnalysis.baseStorageBound(limits, 0),
    );
}

test "kernelization analysis storage cleans up failed container reservations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testAnalysisReservation, .{});
}

fn testAnalysisReservation(allocator: std.mem.Allocator) !void {
    var analysis = try KernelizationAnalysis.init(allocator, ir.Context.Limits.testing);
    defer analysis.deinit();
    try analysis.reserveKernelCapacity(257);
    try std.testing.expect(analysis.kernels.capacity >= 257);
    try std.testing.expect(analysis.work_to_kernel.capacity() >= 257);
}

test "kernelization model owns its Context through constructor failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testAnalysisContext, .{});
    var limits = ir.Context.Limits.standard;
    limits.configuration.table_bytes = 0;
    try std.testing.expectError(
        error.WorkExhausted,
        KernelizationAnalysis.init(std.testing.allocator, limits),
    );
    limits = ir.Context.Limits.standard;
    limits.operations.storage_bytes = std.math.maxInt(usize);
    try std.testing.expectError(
        error.CapacityOverflow,
        KernelizationAnalysis.init(std.testing.allocator, limits),
    );
}

fn testAnalysisContext(allocator: std.mem.Allocator) !void {
    var analysis = try KernelizationAnalysis.init(allocator, ir.Context.Limits.standard);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 0), analysis.kernelCount());
    try std.testing.expectEqualDeep(
        ir.Context.Limits.standard,
        analysis.context.capacity.asLimits(),
    );
    try std.testing.expectEqual(
        @as(?ir.Context.Segment, null),
        analysis.context.exhaustedSegment(),
    );
}
