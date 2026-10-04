const std = @import("std");
const gpu = @import("gpu");
const accy = @import("accy");
const sys = @import("sys");
const namespace = @import("root.zig");
const backend = namespace.backend;
const assemble = namespace.assemble;

const kernel_mod = accy.kernel;
const Allocator = std.mem.Allocator;

test "ptxas: accy validation ptx namespace" {
    _ = backend;
    _ = assemble;
}

test "ptxas: validates Choir-generated CUDA PTX artifact" {
    var artifact = try createAddArtifact(std.testing.allocator, "accy_choir_ptxas_add");
    defer artifact.deinit();
    try acceptWithHostPtxas(std.testing.allocator, artifact);
}

test "ptxas: validates Choir-generated CUDA PTX scalar ops artifact" {
    var artifact = try createScalarOpsArtifact(
        std.testing.allocator,
        "accy_choir_ptxas_scalar_ops",
    );
    defer artifact.deinit();
    try acceptWithHostPtxas(std.testing.allocator, artifact);
}

test "ptxas: validates Choir-generated CUDA PTX warp control artifact" {
    var artifact = try createWarpOpsArtifact(std.testing.allocator, "accy_choir_ptxas_warp_ops");
    defer artifact.deinit();
    try acceptWithHostPtxas(std.testing.allocator, artifact);
}

test "ptxas: validates Choir-generated CUDA PTX shared memory artifact" {
    var artifact = try createSharedMemoryArtifact(
        std.testing.allocator,
        "accy_choir_ptxas_shared_memory",
    );
    defer artifact.deinit();
    try acceptWithHostPtxas(std.testing.allocator, artifact);
}

test "ptxas: validates Choir-generated CUDA PTX dynamic shared memory artifact" {
    var artifact = try createDynamicSharedMemoryArtifact(
        std.testing.allocator,
        "accy_choir_ptxas_dynamic_shared_memory",
    );
    defer artifact.deinit();
    try acceptWithHostPtxas(std.testing.allocator, artifact);
}

fn acceptWithHostPtxas(allocator: Allocator, artifact: gpu.KernelArtifact) !void {
    const target = (try assemble.probeTarget(allocator)) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.parent_dir.realPathFileAlloc(
        sys.fs.debugIo(),
        tmp.sub_path[0..],
        allocator,
    );
    defer allocator.free(tmp_root);

    try assemble.acceptArtifact(allocator, tmp_root, target, artifact);
}

fn createAddArtifact(
    allocator: Allocator,
    name: []const u8,
) !gpu.KernelArtifact {
    const params = [_]kernel_mod.Param{
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.i32),
    };
    var builder = try kernel_mod.Builder.init(
        allocator,
        kernel_mod.Builder.Limits.testing,
        name,
        &params,
    );
    errdefer builder.deinit();
    const axis = try builder.axis("i", 1);
    try builder.bind(axis, .thread_x);

    const out = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const count_buffer = builder.argument(3);
    const index = try builder.globalId(.x);
    const zero = try builder.constantIndex(0);
    const count = try builder.load(count_buffer, zero);
    const index_i32 = try builder.cast(index, .i32);
    const in_bounds = try builder.compare(.lt, index_i32, count);
    var if_op = try builder.if_(in_bounds, &.{});
    const previous = builder.insertionBlock();
    builder.setInsertionBlock(if_op.thenBlock());
    const left = try builder.load(lhs, index);
    const right = try builder.load(rhs, index);
    const sum = try builder.add(left, right);
    try builder.store(sum, out, index);
    try builder.yield_(&.{});
    builder.setInsertionBlock(if_op.elseBlock().?);
    try builder.yield_(&.{});
    builder.setInsertionBlock(previous);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    var state = backend.State.init(allocator);
    return try accy.kernel.createKernelArtifact(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ptxas",
    });
}

fn createScalarOpsArtifact(
    allocator: Allocator,
    name: []const u8,
) !gpu.KernelArtifact {
    const params = [_]kernel_mod.Param{
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.i32),
        kernel_mod.dynamicBuffer(.i32),
    };
    var builder = try kernel_mod.Builder.init(
        allocator,
        kernel_mod.Builder.Limits.testing,
        name,
        &params,
    );
    errdefer builder.deinit();
    const axis = try builder.axis("i", 1);
    try builder.bind(axis, .thread_x);

    const f_out = builder.argument(0);
    const f_in = builder.argument(1);
    const i_out = builder.argument(2);
    const i_in = builder.argument(3);
    const index = try builder.globalId(.x);

    const x = try builder.load(f_in, index);
    const zero = try builder.constantFloat(.f32, 0.0);
    const two = try builder.constantFloat(.f32, 2.0);
    const abs_x = try builder.abs(x);
    const root = try builder.sqrt(abs_x);
    const s = try builder.sin(x);
    const c = try builder.cos(x);
    const t = try builder.tan(x);
    const p = try builder.pow(abs_x, two);
    const fma = try builder.fma(s, c, root);
    const divided = try builder.div(fma, two);
    const sum = try builder.add(try builder.add(divided, t), p);
    const pred = try builder.compare(.gt, x, zero);
    const selected = try builder.select(pred, sum, abs_x);
    const bits = try builder.bitcast(selected, .i32);
    const roundtrip = try builder.bitcast(bits, .f32);
    try builder.store(roundtrip, f_out, index);

    const int_value = try builder.load(i_in, index);
    const one = try builder.constantInt(.i32, 1);
    const shl = try builder.shl(int_value, one);
    const shr = try builder.shr(int_value, one);
    const ushr = try builder.ushr(int_value, one);
    const anded = try builder.and_(shl, ushr);
    const ored = try builder.or_(anded, one);
    const xored = try builder.xor(ored, shr);
    const inverted = try builder.not(xored);
    try builder.store(inverted, i_out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    var state = backend.State.init(allocator);
    return try accy.kernel.createKernelArtifact(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ptxas/scalar",
    });
}

fn createWarpOpsArtifact(
    allocator: Allocator,
    name: []const u8,
) !gpu.KernelArtifact {
    const params = [_]kernel_mod.Param{
        kernel_mod.dynamicBuffer(.i32),
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.f32),
    };
    var builder = try kernel_mod.Builder.init(
        allocator,
        kernel_mod.Builder.Limits.testing,
        name,
        &params,
    );
    errdefer builder.deinit();
    const axis = try builder.axis("i", 1);
    try builder.bind(axis, .thread_x);

    const i_out = builder.argument(0);
    const f_out = builder.argument(1);
    const f_in = builder.argument(2);
    const index = try builder.globalId(.x);

    const lane = try builder.laneId();
    _ = try builder.warpId();
    _ = try builder.activeMask();
    const lane_i32 = try builder.cast(lane, .i32);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);
    const is_lane_zero = try builder.compare(.eq, lane_i32, zero);
    _ = try builder.allSync(is_lane_zero);
    _ = try builder.anySync(is_lane_zero);
    const ballot = try builder.ballotSync(is_lane_zero);
    const shuffled_lane = try builder.shuffleSync(.xor, lane_i32, one);
    const reduced_lane = try builder.warpReduce(.add, lane_i32);
    const scanned_lane = try builder.warpScan(.xor, .inclusive, lane_i32);
    const ballot_rank = try builder.popcount(ballot);
    const folded_vote = try builder.xor(try builder.xor(ballot, shuffled_lane), ballot_rank);
    const folded_scan = try builder.xor(reduced_lane, scanned_lane);
    const folded = try builder.xor(folded_vote, folded_scan);
    try builder.store(folded, i_out, index);

    const x = try builder.load(f_in, index);
    const shuffled_x = try builder.shuffleSync(.down, x, one);
    const reduced_x = try builder.warpReduce(.max, x);
    const scanned_x = try builder.warpScan(.add, .exclusive, x);
    const folded_x = try builder.add(try builder.add(shuffled_x, reduced_x), scanned_x);
    try builder.store(folded_x, f_out, index);
    try builder.syncWarp();
    try builder.barrier(.warp);
    try builder.barrier(.block);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    var state = backend.State.init(allocator);
    return try accy.kernel.createKernelArtifact(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ptxas/warp",
    });
}

fn createSharedMemoryArtifact(
    allocator: Allocator,
    name: []const u8,
) !gpu.KernelArtifact {
    const params = [_]kernel_mod.Param{
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.f32),
    };
    var builder = try kernel_mod.Builder.init(
        allocator,
        kernel_mod.Builder.Limits.testing,
        name,
        &params,
    );
    errdefer builder.deinit();
    const axis = try builder.axis("i", 32);
    try builder.bind(axis, .thread_x);

    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const lane = try builder.laneId();
    const shared = try builder.sharedBuffer(.f32, 32);

    const x = try builder.load(input, index);
    try builder.store(x, shared, lane);
    try builder.barrier(.block);
    const y = try builder.load(shared, lane);
    try builder.store(y, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    var state = backend.State.init(allocator);
    return try accy.kernel.createKernelArtifact(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ptxas/shared",
    });
}

fn createDynamicSharedMemoryArtifact(
    allocator: Allocator,
    name: []const u8,
) !gpu.KernelArtifact {
    const params = [_]kernel_mod.Param{
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.f32),
    };
    var builder = try kernel_mod.Builder.init(
        allocator,
        kernel_mod.Builder.Limits.testing,
        name,
        &params,
    );
    errdefer builder.deinit();
    const axis = try builder.axis("i", 32);
    try builder.bind(axis, .thread_x);

    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const lane = try builder.laneId();
    const first = try builder.dynamicSharedBuffer(.f32, 32, 0);
    const second = try builder.dynamicSharedBuffer(.f32, 32, 128);

    const x = try builder.load(input, index);
    try builder.store(x, first, lane);
    try builder.store(x, second, lane);
    try builder.barrier(.block);
    const y = try builder.load(second, lane);
    try builder.store(y, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    var state = backend.State.init(allocator);
    return try accy.kernel.createKernelArtifact(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ptxas/dynamic-shared",
    });
}

test "ptxas: validates Choir-generated CUDA PTX atomic ops artifact" {
    var artifact = try createAtomicOpsArtifact(
        std.testing.allocator,
        "accy_choir_ptxas_atomic_ops",
    );
    defer artifact.deinit();
    try acceptWithHostPtxas(std.testing.allocator, artifact);
}

fn createAtomicOpsArtifact(
    allocator: Allocator,
    name: []const u8,
) !gpu.KernelArtifact {
    const params = [_]kernel_mod.Param{
        kernel_mod.dynamicBuffer(.f32),
        kernel_mod.dynamicBuffer(.i32),
        kernel_mod.dynamicBuffer(.i32),
    };
    var builder = try kernel_mod.Builder.init(
        allocator,
        kernel_mod.Builder.Limits.testing,
        name,
        &params,
    );
    errdefer builder.deinit();
    const axis = try builder.axis("i", 1);
    try builder.bind(axis, .thread_x);

    const f_bins = builder.argument(0);
    const i_bins = builder.argument(1);
    const olds = builder.argument(2);
    const index = try builder.globalId(.x);
    const slot = try builder.constantIndex(0);
    const f_delta = try builder.constantFloat(.f32, 2.5);
    const i_zero = try builder.constantInt(.i32, 0);
    const i_one = try builder.constantInt(.i32, 1);
    const i_three = try builder.constantInt(.i32, 3);

    _ = try builder.atomicRmw(.add, f_delta, f_bins, slot);
    const old_add = try builder.atomicRmw(.add, i_one, i_bins, slot);
    const old_min = try builder.atomicRmw(.min, old_add, i_bins, slot);
    const old_max = try builder.atomicRmw(.max, old_min, i_bins, slot);
    const old_and = try builder.atomicRmw(.bit_and, old_max, i_bins, slot);
    const old_or = try builder.atomicRmw(.bit_or, old_and, i_bins, slot);
    const old_xor = try builder.atomicRmw(.bit_xor, old_or, i_bins, slot);
    _ = try builder.atomicCas(i_zero, i_three, i_bins, slot);
    const old_exch = try builder.atomicRmw(.exchange, old_xor, i_bins, slot);
    try builder.store(old_exch, olds, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    var state = backend.State.init(allocator);
    return try accy.kernel.createKernelArtifact(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ptxas",
    });
}

test "ptxas: validates Choir-generated CUDA PTX shared atomic ops artifact" {
    var artifact = try createSharedAtomicOpsArtifact(
        std.testing.allocator,
        "accy_choir_ptxas_shared_atomic_ops",
    );
    defer artifact.deinit();
    try acceptWithHostPtxas(std.testing.allocator, artifact);
}

fn createSharedAtomicOpsArtifact(
    allocator: Allocator,
    name: []const u8,
) !gpu.KernelArtifact {
    const params = [_]kernel_mod.Param{
        kernel_mod.dynamicBuffer(.i32),
    };
    var builder = try kernel_mod.Builder.init(
        allocator,
        kernel_mod.Builder.Limits.testing,
        name,
        &params,
    );
    errdefer builder.deinit();
    const axis = try builder.axis("i", 1);
    try builder.bind(axis, .thread_x);

    const out = builder.argument(0);
    const index = try builder.globalId(.x);
    const bins = try builder.sharedBuffer(.i32, 16);
    const slot = try builder.constantIndex(0);
    const one = try builder.constantInt(.i32, 1);
    const three = try builder.constantInt(.i32, 3);

    const old = try builder.atomicRmw(.add, one, bins, slot);
    _ = try builder.atomicCas(one, three, bins, slot);
    try builder.barrier(.block);
    _ = try builder.atomicRmw(.add, old, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    var state = backend.State.init(allocator);
    return try accy.kernel.createKernelArtifact(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ptxas",
    });
}
