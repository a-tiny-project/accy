const std = @import("std");
const records = @import("root.zig");
const schedule = @import("../../kernel/model/root.zig").core.schedule;

pub const DotGeneralMmaTile = struct {
    bm: u32 = 128,
    bn: u32 = 64,
    bk: u32 = 16,
    warps_m: u32 = 2,
    warps_n: u32 = 2,
    stages: u32 = 1,
    splits: u32 = 1,

    pub fn warps(self: DotGeneralMmaTile) u32 {
        return self.warps_m * self.warps_n;
    }

    pub fn warpTileM(self: DotGeneralMmaTile) u32 {
        return self.bm / self.warps_m;
    }

    pub fn warpTileN(self: DotGeneralMmaTile) u32 {
        return self.bn / self.warps_n;
    }

    pub fn threads(self: DotGeneralMmaTile) u32 {
        return self.warps() * 32;
    }

    pub fn exact(self: DotGeneralMmaTile, dims: DotGeneralStaticDims) bool {
        return dims.m % self.bm == 0 and dims.n % self.bn == 0 and dims.k % self.bk == 0;
    }
};

pub const ReductionAtomicPlan = struct {
    threads: u32,
    blocks: u32,

    pub fn stride(self: ReductionAtomicPlan) u64 {
        return @as(u64, self.threads) * self.blocks;
    }
};

pub const DotGeneralBlockTile = struct {
    bm: u32 = 64,
    bn: u32 = 64,
    bk: u32 = 16,
    tm: u32 = 4,
    tn: u32 = 4,
    splits: u32 = 1,
    stages: u32 = 2,

    pub fn threadsX(self: DotGeneralBlockTile) u32 {
        return self.bn / self.tn;
    }

    pub fn threadsY(self: DotGeneralBlockTile) u32 {
        return self.bm / self.tm;
    }

    pub fn exact(self: DotGeneralBlockTile, dims: DotGeneralStaticDims) bool {
        return dims.m % self.bm == 0 and dims.n % self.bn == 0 and dims.k % self.bk == 0;
    }
};

pub const DotGeneralStaticDims = struct {
    m: u32,
    n: u32,
    k: u32,
    batch: u32 = 1,
};

pub const ReductionWarpRowsPlan = struct {
    threads: u32,
    rows: u32,
};

pub const ElementwiseVectorPlan = struct {
    quads: u64,
};

pub const LoweredKernelBody = union(enum) {
    generic,
    dot_block_tile: DotGeneralBlockTile,
    dot_mma_tile: DotGeneralMmaTile,
    reduction_single_block: u32,
    reduction_atomic: ReductionAtomicPlan,
    reduction_warp_rows: ReductionWarpRowsPlan,
    row_pipeline: RowPipelinePlan,
    flash_attention: FlashAttentionPlan,
    scan: ScanPlan,
    elementwise_rank2: ElementwiseRank2Plan,
    elementwise_vector: ElementwiseVectorPlan,
};

pub const ElementwiseRank2Plan = struct {
    rows: u32,
    cols: u32,
    threads_x: u32,
    threads_y: u32,
};

pub const ScanPlan = struct {
    blocks: u32,
    threads: u32,
    items: u32,
};

pub const FlashAttentionPlan = struct {
    seq: u32,
    dim: u32,
    br: u32,
    bc: u32,
    threads_x: u32,
    threads_y: u32,
};

pub const RowPipelinePlan = struct {
    threads: u32,
    rows: u32,
    cols: u32,
    warps: u32,
};

pub const GeneratedSchedule = struct {
    kind: GeneratedScheduleKind,
    threads: @import("../../kernel/model/root.zig").logical.schedule.Threads,
};

pub const GeneratedScheduleKind = enum {
    flat,
    matrix,
};

pub const KernelOutlineKind = enum {
    elementwise,
    shape,
    dot_general,
    reduction,
    kernel_call,
    row_pipeline,
    iterate,
    flash_attention,
    scan,
};

pub const Outline = struct {
    id: usize,
    name: []const u8,
    kind: KernelOutlineKind,
    work_item_id: usize,
    root: records.reference.Operation,
    input_slot_ids: []const usize,
    output_slot_id: usize,
    element_count: u64,
    op_count: usize,
};

pub const Outlines = struct {
    kernels: []const Outline,
    total_input_slots: usize,
    total_scheduled_ops: usize,
};

pub const Lowered = struct {
    work_item_id: usize,
    entry_name: []const u8,
    program: records.program.Record,
    argument_count: u32,
    body_fingerprint: u64,
    dynamic_shared_memory_bytes: u32,
    schedule: GeneratedSchedule,
    launch: ?schedule.Launch,
    output_fill_pattern: ?u32,
    scratch_fill_pattern: ?u32,
    body: LoweredKernelBody,
};

pub const Generated = struct {
    kernels: []const Lowered,
};

pub const Record = struct {
    outlines: Outlines,
    generated: Generated,
};

pub fn validate(
    allocator: std.mem.Allocator,
    value: Record,
    memory: records.memory.Record,
) !void {
    var work = std.AutoHashMapUnmanaged(usize, bool).empty;
    defer work.deinit(allocator);
    const count = std.math.cast(u32, value.outlines.kernels.len) orelse
        return error.InvalidStageRecord;
    try work.ensureTotalCapacity(allocator, count);
    var inputs: usize = 0;
    var operations: usize = 0;
    for (value.outlines.kernels, 0..) |outline, index| {
        if (outline.id != index or outline.output_slot_id >= memory.buffers.slots.len) {
            return error.InvalidStageRecord;
        }
        for (outline.input_slot_ids) |slot| {
            if (slot >= memory.buffers.slots.len) return error.InvalidStageRecord;
        }
        const entry = work.getOrPutAssumeCapacity(outline.work_item_id);
        if (entry.found_existing) return error.InvalidStageRecord;
        entry.value_ptr.* = false;
        inputs = std.math.add(usize, inputs, outline.input_slot_ids.len) catch
            return error.InvalidStageRecord;
        operations = std.math.add(usize, operations, outline.op_count) catch
            return error.InvalidStageRecord;
    }
    if (inputs != value.outlines.total_input_slots or
        operations != value.outlines.total_scheduled_ops) return error.InvalidStageRecord;
    for (value.generated.kernels) |kernel| {
        const seen = work.getPtr(kernel.work_item_id) orelse return error.InvalidStageRecord;
        if (seen.*) return error.InvalidStageRecord;
        seen.* = true;
        if (kernel.argument_count != kernel.program.params.len) return error.InvalidStageRecord;
    }
}
