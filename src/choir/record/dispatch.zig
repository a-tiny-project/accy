const std = @import("std");
const gpu_abi = @import("gpu_abi");
const reference = @import("root.zig").reference;

pub const ScheduleResourceEstimate = struct {
    element_count: u64,
    element_size: u64,
    op_count: usize,
    external_input_value_count: usize = 0,
    external_operand_count: usize = 0,
    chain_operand_count: usize = 0,
    static_read_bytes: u64 = 0,
    static_write_bytes: u64 = 0,
    static_total_bytes: u64 = 0,
    estimated_element_ops: u64 = 0,
    static_bytes_complete: bool = true,

    pub fn elementOpsPerKiB(self: ScheduleResourceEstimate) u64 {
        if (self.static_total_bytes == 0) return 0;
        return (std.math.mul(u64, self.estimated_element_ops, 1024) catch
            std.math.maxInt(u64)) / self.static_total_bytes;
    }
};

pub const ScheduleWorkKind = enum {
    elementwise_single,
    elementwise_fusion,
    shape,
    dot_general,
    reduction,
    kernel_call,
    row_pipeline,
    iterate,
    flash_attention,
    scan,
};

pub const FusionClusterKind = enum {
    elementwise,
    dot_epilogue,
    reduction_input,
    row_pipeline,
    flash_attention,
};

pub const Cluster = struct {
    ops: []const reference.Operation,
    kind: FusionClusterKind,
};

pub const Fusion = struct {
    clusters: []const Cluster,
    elided: []const reference.Operation,
    fused_op_count: usize,
    max_cluster_len: usize,
};

pub const WorkItem = struct {
    id: usize,
    kind: ScheduleWorkKind,
    root: reference.Operation,
    ops: []const reference.Operation,
    output_value: reference.Value,
    dtype: gpu_abi.DType,
    rank: usize,
    element_count: u64,
    resources: ScheduleResourceEstimate,
};

pub const Schedule = struct {
    work_items: []const WorkItem,
    single_work_count: usize,
    fusion_work_count: usize,
    kernel_call_work_count: usize,
    scheduled_op_count: usize,
    total_static_elements: u64,
};

pub const Record = struct { fusion: Fusion, schedule: Schedule };

pub fn validate(allocator: std.mem.Allocator, value: Record) !void {
    const seen = try allocator.alloc(bool, value.schedule.work_items.len);
    defer allocator.free(seen);
    @memset(seen, false);
    for (value.schedule.work_items) |item| {
        if (item.id >= seen.len) return error.InvalidStageRecord;
        if (seen[item.id]) return error.InvalidStageRecord;
        seen[item.id] = true;
    }
    try validateCounters(value);
}

fn validateCounters(value: Record) !void {
    var fused: usize = 0;
    var longest: usize = 0;
    for (value.fusion.clusters) |cluster| {
        fused = std.math.add(usize, fused, cluster.ops.len) catch return error.InvalidStageRecord;
        longest = @max(longest, cluster.ops.len);
    }
    if (fused != value.fusion.fused_op_count or longest != value.fusion.max_cluster_len) {
        return error.InvalidStageRecord;
    }
    var single: usize = 0;
    var fusion: usize = 0;
    var calls: usize = 0;
    var ops: usize = 0;
    var elements: u64 = 0;
    for (value.schedule.work_items) |item| {
        switch (item.kind) {
            .elementwise_single, .shape, .dot_general, .reduction, .iterate, .scan => single += 1,
            .elementwise_fusion, .row_pipeline, .flash_attention => fusion += 1,
            .kernel_call => calls += 1,
        }
        ops = std.math.add(usize, ops, item.ops.len) catch return error.InvalidStageRecord;
        elements = std.math.add(
            u64,
            elements,
            item.element_count,
        ) catch return error.InvalidStageRecord;
    }
    const schedule = value.schedule;
    if (single != schedule.single_work_count or fusion != schedule.fusion_work_count or
        calls != schedule.kernel_call_work_count or ops != schedule.scheduled_op_count or
        elements != schedule.total_static_elements) return error.InvalidStageRecord;
}
