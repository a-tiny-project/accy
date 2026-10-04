const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_fixed = @import("alloc_fixed");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const generated_guard = @import("guard.zig");
const generated_name = @import("name.zig");
const generated_schedule = @import("schedule.zig");
const preparation = @import("../../root.zig");

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const kernel_root = common.kernel_root;
const bufferization = common.bufferization;
const kernelization_model = @import("../model/root.zig");
const schedule_planning = common.schedule_planning;
const target_facts = preparation.target;
const bufferSlotById = common.bufferSlotById;
const externalInputIndex = common.externalInputIndex;
const isName = common.isName;

const LoweredKernel = kernelization_model.LoweredKernel;
const Schedule = target_facts.GeneratedScanSchedule;

const block_schedules = [_]Schedule{
    .{ .threads = 512, .items = 16 },
    .{ .threads = 256, .items = 16 },
};

pub const schedule_version: u32 = 1;
pub const max_schedule_candidates = block_schedules.len;

pub fn scheduleCandidates(
    total: u64,
    format: ?gpu.ArtifactFormat,
    buffer: *[max_schedule_candidates]Schedule,
) []const Schedule {
    if (format != .cuda_ptx) return buffer[0..0];
    var count: usize = 0;
    for (block_schedules) |schedule| {
        if (!scheduleViable(schedule, total)) continue;
        buffer[count] = schedule;
        count += 1;
    }
    return buffer[0..count];
}

fn scheduleViable(schedule: Schedule, total: u64) bool {
    const tile = @as(u64, schedule.threads) * schedule.items;
    if (total % tile != 0) return false;
    return std.math.cast(u32, total / tile) != null;
}

const ScanDescription = struct {
    total: u64,
    blocks: u32,
    input: *ir.Value,
    scratch: ?*ir.Value,
};

fn BlockScanBodyType(comptime scan_threads: u32, comptime scan_items: u32) type {
    return struct {
        fn emit(logical: anytype, ctx: anytype) !void {
            try emitBlockScanBodyScheduled(scan_threads, scan_items, logical, ctx);
        }
    };
}

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    format: ?gpu.ArtifactFormat,
    scan_schedules: ?[]const u8,
) common.LoweringError!LoweredKernel {
    const desc = try scanDescriptionForWork(work);

    const input_dtypes = allocator.alloc(
        gpu_abi.DType,
        outline.inputCount(),
    ) catch return error.OutOfMemory;
    defer allocator.free(input_dtypes);
    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        input_dtypes[index] = slot.dtype;
    }

    var abi = try generated_abi.flatTyped(allocator, .f32, input_dtypes);
    defer abi.deinit(allocator);

    if (format == .cuda_ptx) {
        if (scan_schedules) |encoded| {
            if (try target_facts.resolveGeneratedScanSchedule(encoded, desc.total)) |schedule| {
                if (scheduleViable(schedule, desc.total)) {
                    if (try lowerBlockScanSchedule(
                        schedule,
                        allocator,
                        ir_ctx,
                        outline,
                        work,
                        buffer_plan,
                        desc,
                        abi,
                    )) |lowered| {
                        return lowered;
                    }
                }
            }
        }
        var candidate_buffer: [max_schedule_candidates]Schedule = undefined;
        for (scheduleCandidates(desc.total, format, &candidate_buffer)) |schedule| {
            if (try lowerBlockScanSchedule(
                schedule,
                allocator,
                ir_ctx,
                outline,
                work,
                buffer_plan,
                desc,
                abi,
            )) |lowered| {
                return lowered;
            }
        }
    }

    const entry_name = try generated_name.scanSerial(allocator, desc.total, work.id);
    errdefer allocator.free(entry_name);
    return generated_builder.withoutLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flat(),
        .{
            .abi = abi,
            .allocator = allocator,
            .desc = desc,
            .outline = outline,
            .buffer_plan = buffer_plan,
        },
        emitSerialScanBody,
    );
}

fn scanDescriptionForWork(
    work: schedule_planning.ScheduleWorkItem,
) common.LoweringError!ScanDescription {
    if (work.kind != .scan) return error.UnsupportedOperation;
    if (work.ops.len != 1) return error.UnsupportedOperation;
    const op = work.ops[0];
    if (!isName(op.name.name, dialect_mod.AccyDialect.CumsumOp.operation_name)) {
        return error.UnsupportedOperation;
    }

    const axis_attr = op.getAttrAs(ir.Attribute.IntegerAttr, "axis") orelse
        return error.InvalidArtifact;
    if (axis_attr.getValue() != 0) return error.UnsupportedOperation;

    const input = op.getOperand(0) orelse return error.InvalidArtifact;
    var dims_arena_buffer: [256]u8 = undefined;
    var dims_arena = alloc_fixed.FixedBuffer.init(dims_arena_buffer[0..]);
    const input_type = dialect_mod.decodeTensorType(
        dims_arena.allocator(),
        input.type,
    ) catch return error.InvalidArtifact;
    if (input_type.dtype != .f32 or input_type.dims.len != 1) return error.UnsupportedOperation;
    if (input_type.dims[0] < 1) return error.UnsupportedOperation;
    const total: u64 = @intCast(input_type.dims[0]);
    return .{
        .total = total,
        .blocks = 0,
        .input = input,
        .scratch = op.getOperand(1),
    };
}

fn lowerBlockScanSchedule(
    schedule: Schedule,
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    desc: ScanDescription,
    abi: generated_abi.Flat,
) common.LoweringError!?LoweredKernel {
    inline for (block_schedules) |candidate| {
        if (candidate.threads == schedule.threads and candidate.items == schedule.items) {
            return lowerBlockScan(
                candidate.threads,
                candidate.items,
                BlockScanBodyType(candidate.threads, candidate.items).emit,
                allocator,
                ir_ctx,
                outline,
                work,
                buffer_plan,
                desc,
                abi,
            );
        }
    }
    return null;
}

fn lowerBlockScan(
    comptime scan_threads: u32,
    comptime scan_items: u32,
    comptime emit_body: anytype,
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    desc: ScanDescription,
    abi: generated_abi.Flat,
) common.LoweringError!?LoweredKernel {
    const scan_tile = scan_threads * scan_items;
    if (desc.total % scan_tile != 0) return null;
    const blocks = std.math.cast(u32, desc.total /
        scan_tile) orelse return error.UnsupportedOperation;
    var scheduled_desc = desc;
    scheduled_desc.blocks = blocks;
    if (blocks == 1) {
        scheduled_desc.scratch = null;
    } else if (scheduled_desc.scratch == null) {
        return null;
    }

    const entry_name = try generated_name.scanLookback(
        allocator,
        scheduled_desc.total,
        scheduled_desc.blocks,
        work.id,
    );
    errdefer allocator.free(entry_name);
    var lowered = try generated_builder.withoutLaunch(
        allocator,
        ir_ctx,
        work.id,
        entry_name,
        abi.params(),
        generated_schedule.flatThreads(scan_threads),
        .{
            .abi = abi,
            .allocator = allocator,
            .desc = scheduled_desc,
            .outline = outline,
            .buffer_plan = buffer_plan,
        },
        emit_body,
    );
    lowered.body = .{ .scan = .{
        .blocks = scheduled_desc.blocks,
        .threads = scan_threads,
        .items = scan_items,
    } };
    if (scheduled_desc.scratch != null) lowered.scratch_fill_pattern = 0;
    return lowered;
}

fn claim_scan_block(inner: anytype, guard_ctx: anytype) !void {
    const bid = try inner.atomicRmw(
        .add,
        guard_ctx.one,
        guard_ctx.scratch,
        guard_ctx.zero,
    );
    try inner.storeIndex(bid, guard_ctx.bid_share, guard_ctx.zero);
}

fn initialize_single_scan_block(inner: anytype, guard_ctx: anytype) !void {
    try inner.storeIndex(guard_ctx.zero_u, guard_ctx.bid_share, guard_ctx.zero);
}

fn store_scan_warp_sum(inner: anytype, guard_ctx: anytype) !void {
    try inner.storeIndex(guard_ctx.value, guard_ctx.warp_sums, guard_ctx.warp);
}

fn publish_scan_lookback(inner: anytype, guard_ctx: anytype) !void {
    const total_bits = try inner.bitcast(guard_ctx.block_total, .u32);
    try inner.storeIndex(
        total_bits,
        guard_ctx.scratch,
        try inner.add(guard_ctx.partial_base, guard_ctx.bid),
    );
    try inner.fence(.device);
    _ = try inner.atomicRmw(
        .add,
        guard_ctx.one_u,
        guard_ctx.scratch,
        try inner.add(guard_ctx.status_base, guard_ctx.bid),
    );

    var lookback = try inner.whileScope(
        &.{ guard_ctx.bid, guard_ctx.zero_f },
        &.{ guard_ctx.bid.valueType(), guard_ctx.zero_f.valueType() },
    );
    errdefer lookback.abort();
    const remaining = lookback.beforeArg(0) orelse return error.UnsupportedOperation;
    const prefix = lookback.beforeArg(1) orelse return error.UnsupportedOperation;
    const keep_going = try inner.compare(.gt, remaining, guard_ctx.zero);
    try lookback.condition(keep_going, &.{ remaining, prefix });

    const body_remaining = lookback.afterArg(0) orelse return error.UnsupportedOperation;
    const body_prefix = lookback.afterArg(1) orelse return error.UnsupportedOperation;
    const body_j = try inner.sub(body_remaining, try inner.constantIndex(1));
    const status_index = try inner.add(guard_ctx.status_base, body_j);

    var spin = try inner.whileScope(&.{guard_ctx.zero_u}, &.{guard_ctx.zero_u.valueType()});
    errdefer spin.abort();
    _ = spin.beforeArg(0) orelse return error.UnsupportedOperation;
    const observed = try inner.atomicRmw(.add, guard_ctx.zero_u, guard_ctx.scratch, status_index);
    const still_waiting = try inner.compare(.eq, observed, guard_ctx.zero_u);
    try spin.condition(still_waiting, &.{observed});
    const spin_after = spin.afterArg(0) orelse return error.UnsupportedOperation;
    try spin.leave(&.{spin_after});
    const status = spin.result(0) orelse return error.UnsupportedOperation;

    try inner.fence(.device);
    const done = try inner.compare(.eq, status, try inner.constantInt(.u32, 2));
    const partial_bits = try inner.loadIndex(
        guard_ctx.scratch,
        try inner.add(guard_ctx.partial_base, body_j),
    );
    const inclusive_bits = try inner.loadIndex(
        guard_ctx.scratch,
        try inner.add(guard_ctx.inclusive_base, body_j),
    );
    const partial = try inner.bitcast(partial_bits, .f32);
    const inclusive = try inner.bitcast(inclusive_bits, .f32);
    const take = try inner.select(done, inclusive, partial);
    const next_prefix = try inner.add(body_prefix, take);
    const next_remaining = try inner.select(done, guard_ctx.zero, body_j);
    try lookback.leave(&.{ next_remaining, next_prefix });

    const final_prefix = lookback.result(1) orelse return error.UnsupportedOperation;
    const inclusive_total = try inner.add(final_prefix, guard_ctx.block_total);
    const inclusive_total_bits = try inner.bitcast(inclusive_total, .u32);
    try inner.storeIndex(
        inclusive_total_bits,
        guard_ctx.scratch,
        try inner.add(guard_ctx.inclusive_base, guard_ctx.bid),
    );
    try inner.fence(.device);
    _ = try inner.atomicRmw(
        .add,
        guard_ctx.one_u,
        guard_ctx.scratch,
        try inner.add(guard_ctx.status_base, guard_ctx.bid),
    );

    try inner.storeIndex(final_prefix, guard_ctx.prefix_share, guard_ctx.zero);
}

fn emitBlockScanBodyScheduled(
    comptime scan_threads: u32,
    comptime scan_items: u32,
    logical: anytype,
    ctx: anytype,
) !void {
    const scan_tile = scan_threads * scan_items;
    const scan_warp_count = scan_threads / 32;
    const desc: ScanDescription = ctx.desc;

    _ = try logical.index1D("lane", @as(u64, desc.blocks) * scan_threads);
    const tid = try logical.threadId(.x);

    const input_slot = ctx.buffer_plan.getSlot(desc.input) orelse return error.UnsupportedOperation;
    const input_index = externalInputIndex(ctx.outline, input_slot.id) orelse
        return error.UnsupportedOperation;
    const input = ctx.abi.input(logical, input_index);
    const out = ctx.abi.output(logical);

    var scratch_value: ?kernel_root.Value = null;
    if (desc.scratch) |scratch_ir| {
        const scratch_slot = ctx.buffer_plan.getSlot(scratch_ir) orelse
            return error.UnsupportedOperation;
        const scratch_index = externalInputIndex(ctx.outline, scratch_slot.id) orelse
            return error.UnsupportedOperation;
        scratch_value = ctx.abi.input(logical, scratch_index);
    }

    const bid_share = try logical.sharedBuffer(.u32, 1);
    const prefix_share = try logical.sharedBuffer(.f32, 1);
    const warp_sums = try logical.sharedBuffer(.f32, scan_warp_count);
    const tile_share = try logical.sharedBuffer(.f32, scan_tile);

    const zero_index = try logical.constantIndex(0);
    const one_u32 = try logical.constantInt(.u32, 1);
    const zero_u32 = try logical.constantInt(.u32, 0);
    const zero_f = try logical.constantFloat(.f32, 0.0);

    const tid_zero = try logical.compare(.eq, tid, zero_index);

    if (scratch_value) |scratch| {
        try logical.guardDo(
            tid_zero,
            .{ .scratch = scratch, .bid_share = bid_share, .one = one_u32, .zero = zero_index },
            claim_scan_block,
        );
        try logical.barrier(.block);
    } else {
        try logical.guardDo(
            tid_zero,
            .{ .bid_share = bid_share, .zero = zero_index, .zero_u = zero_u32 },
            initialize_single_scan_block,
        );
        try logical.barrier(.block);
    }

    const bid_u = try logical.loadIndex(bid_share, zero_index);
    const bid = try logical.castIndex(bid_u);

    const tile_extent = try logical.constantIndex(scan_tile);
    const items_extent = try logical.constantIndex(scan_items);

    const tile_base = try logical.mul(bid, tile_extent);
    {
        var chunk: u32 = 0;
        while (chunk < scan_items / 4) : (chunk += 1) {
            const flat_quad = try logical.add(try logical.mul(
                try logical.constantIndex(@as(i64, chunk) * scan_threads),
                try logical.constantIndex(4),
            ), try logical.mul(tid, try logical.constantIndex(4)));
            const loaded = try logical.loadVector(input, try logical.add(tile_base, flat_quad), 4);
            try logical.storeIndex(loaded, tile_share, flat_quad);
        }
    }
    try logical.barrier(.block);

    var values: [scan_items]kernel_root.Value = undefined;
    {
        const local_base = try logical.mul(tid, items_extent);
        var quad: u32 = 0;
        while (quad < scan_items / 4) : (quad += 1) {
            const loaded = try logical.loadVector(tile_share, try logical.add(
                local_base,
                try logical.constantIndex(@as(i64, quad) * 4),
            ), 4);
            for (0..4) |lane_index| {
                values[
                    quad * 4 + lane_index
                ] = try logical.extractLane(loaded, @intCast(lane_index), .f32);
            }
        }
    }

    var running: [scan_items]kernel_root.Value = undefined;
    running[0] = values[0];
    for (1..scan_items) |i| {
        running[i] = try logical.add(running[i - 1], values[i]);
    }
    const thread_total = running[scan_items - 1];

    const warp_inclusive = try logical.warpScan(.add, .inclusive, thread_total);
    const warp_exclusive = try logical.sub(warp_inclusive, thread_total);

    const warp_extent = try logical.constantIndex(32);
    const warp = try logical.div(tid, warp_extent);
    const lane = try logical.sub(tid, try logical.mul(warp, warp_extent));
    const lane_last = try logical.compare(.eq, lane, try logical.constantIndex(31));
    try logical.guardDo(
        lane_last,
        .{ .warp_sums = warp_sums, .warp = warp, .value = warp_inclusive },
        store_scan_warp_sum,
    );
    try logical.barrier(.block);

    var warp_offset = zero_f;
    var block_total = zero_f;
    for (0..scan_warp_count) |w| {
        const w_extent = try logical.constantIndex(@as(i64, @intCast(w)));
        const w_sum = try logical.loadIndex(warp_sums, w_extent);
        const before = try logical.compare(.lt, w_extent, warp);
        const contribution = try logical.select(before, w_sum, zero_f);
        warp_offset = try logical.add(warp_offset, contribution);
        block_total = try logical.add(block_total, w_sum);
    }

    var block_prefix = zero_f;
    if (scratch_value) |scratch| {
        const blocks_extent = try logical.constantIndex(desc.blocks);
        const status_base = try logical.constantIndex(1);
        const partial_base = try logical.add(status_base, blocks_extent);
        const inclusive_base = try logical.add(partial_base, blocks_extent);

        try logical.guardDo(tid_zero, .{
            .scratch = scratch,
            .prefix_share = prefix_share,
            .bid = bid,
            .block_total = block_total,
            .status_base = status_base,
            .partial_base = partial_base,
            .inclusive_base = inclusive_base,
            .one_u = one_u32,
            .zero_u = zero_u32,
            .zero = zero_index,
            .zero_f = zero_f,
        }, publish_scan_lookback);
        try logical.barrier(.block);
        block_prefix = try logical.loadIndex(prefix_share, zero_index);
    }

    const base_value = try logical.add(block_prefix, try logical.add(warp_offset, warp_exclusive));
    try logical.barrier(.block);
    {
        const local_base = try logical.mul(tid, items_extent);
        var quad: u32 = 0;
        while (quad < scan_items / 4) : (quad += 1) {
            var lanes: [4]kernel_root.Value = undefined;
            for (0..4) |lane_index| {
                lanes[lane_index] = try logical.add(base_value, running[quad * 4 + lane_index]);
            }
            const packed_values = try logical.packVector(lanes);
            try logical.storeIndex(packed_values, tile_share, try logical.add(
                local_base,
                try logical.constantIndex(@as(i64, quad) * 4),
            ));
        }
    }
    try logical.barrier(.block);
    {
        var chunk: u32 = 0;
        while (chunk < scan_items / 4) : (chunk += 1) {
            const flat_quad = try logical.add(try logical.mul(
                try logical.constantIndex(@as(i64, chunk) * scan_threads),
                try logical.constantIndex(4),
            ), try logical.mul(tid, try logical.constantIndex(4)));
            const quad_values = try logical.loadVector(tile_share, flat_quad, 4);
            try logical.storeIndex(quad_values, out, try logical.add(tile_base, flat_quad));
        }
    }
}

fn emit_serial_scan_index(
    inner: anytype,
    domain_index: kernel_root.Index1D,
    guard_ctx: anytype,
) !void {
    _ = domain_index;
    const desc_inner: ScanDescription = guard_ctx.desc;
    const input_slot = guard_ctx.buffer_plan.getSlot(desc_inner.input) orelse
        return error.UnsupportedOperation;
    const input_index = externalInputIndex(guard_ctx.outline, input_slot.id) orelse
        return error.UnsupportedOperation;
    const input = guard_ctx.abi.input(inner, input_index);
    const out = guard_ctx.abi.output(inner);

    const zero_f = try inner.constantFloat(.f32, 0.0);
    const total_extent = try inner.constantIndex(@as(i64, @intCast(desc_inner.total)));
    const one = try inner.constantIndex(1);
    var scope = try inner.forScope(
        try inner.constantIndex(0),
        total_extent,
        one,
        &.{zero_f},
        &.{zero_f.valueType()},
    );
    errdefer scope.abort();
    const j = scope.inductionVar();
    const running = scope.iterArg(0) orelse return error.UnsupportedOperation;
    const value = try inner.loadIndex(input, j);
    const next = try inner.add(running, value);
    try inner.storeIndex(next, out, j);
    try scope.leave(&.{next});
}

fn emitSerialScanBody(logical: anytype, ctx: anytype) !void {
    const desc: ScanDescription = ctx.desc;
    const domain = try logical.index1D("row", 1);
    try generated_guard.countIndexDo(logical, domain, ctx.abi.count(logical), .{
        .abi = ctx.abi,
        .desc = desc,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
    }, emit_serial_scan_index);
}
