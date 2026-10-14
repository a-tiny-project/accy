const std = @import("std");
const abi = @import("gpu_abi");
const choir = @import("../../root.zig");
const gpu = @import("../../dialects/gpu/root.zig");

const ir = choir.ir;

pub fn requirementsForModule(module: *ir.Operation) abi.SubgroupRequirements {
    var requirements: abi.SubgroupRequirements = .{};
    appendRequirements(&requirements, module);
    return requirements;
}

pub fn requirementsForOperation(op: *ir.Operation) abi.SubgroupRequirements {
    const GpuDialect = gpu.GpuDialect;
    if (isName(op.name.name, GpuDialect.LaneIdOp.operation_name)) return .{ .supported = true };
    if (isName(op.name.name, GpuDialect.WarpIdOp.operation_name)) return .{ .supported = true };
    if (isName(op.name.name, GpuDialect.ActiveMaskOp.operation_name)) return .{ .supported = true, .ballot = true };
    if (isName(op.name.name, GpuDialect.SyncWarpOp.operation_name)) return .{ .supported = true };
    if (isName(op.name.name, GpuDialect.ShflSyncOp.operation_name)) return .{ .supported = true, .shuffle = true };
    if (isName(op.name.name, GpuDialect.AllSyncOp.operation_name)) return .{ .supported = true, .vote = true };
    if (isName(op.name.name, GpuDialect.AnySyncOp.operation_name)) return .{ .supported = true, .vote = true };
    if (isName(op.name.name, GpuDialect.BallotSyncOp.operation_name)) return .{ .supported = true, .ballot = true };
    if (isName(op.name.name, GpuDialect.MatchAnyOp.operation_name)) return .{ .supported = true, .ballot = true, .vote = true };
    if (isName(op.name.name, GpuDialect.MatchAllOp.operation_name)) return .{ .supported = true, .ballot = true, .vote = true };
    if (isName(op.name.name, GpuDialect.WarpReduceOp.operation_name)) return .{ .supported = true, .arithmetic = true };
    if (isName(op.name.name, GpuDialect.WarpScanOp.operation_name)) return .{ .supported = true, .arithmetic = true, .scan = true };
    if (isName(op.name.name, GpuDialect.BarrierOp.operation_name)) {
        return requirementsForScope((GpuDialect.BarrierOp{ .op = op }).getScope());
    }
    if (isName(op.name.name, GpuDialect.FenceOp.operation_name)) {
        return requirementsForScope((GpuDialect.FenceOp{ .op = op }).getScope());
    }
    return .{};
}

fn appendRequirements(requirements: *abi.SubgroupRequirements, op: *ir.Operation) void {
    mergeRequirement(requirements, requirementsForOperation(op));
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                appendRequirements(requirements, current_op);
                current = current_op.next_op;
            }
        }
    }
}

fn requirementsForScope(scope: ?gpu.Scope) abi.SubgroupRequirements {
    if (scope) |value| {
        if (value == .warp) return .{ .supported = true };
    }
    return .{};
}

fn mergeRequirement(requirements: *abi.SubgroupRequirements, required: abi.SubgroupRequirements) void {
    requirements.* = requirements.*.merge(required);
}

fn isName(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}
