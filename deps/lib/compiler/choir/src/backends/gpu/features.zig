const std = @import("std");
const abi = @import("gpu_abi");
const choir = @import("../../root.zig");
const gpu = @import("../../dialects/gpu/root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const arith = dialects.arith;
const MemrefDialect = dialects.memref.MemrefDialect;
const GpuDialect = gpu.GpuDialect;

pub fn requirementsForModule(module: *ir.Operation) abi.Features {
    var requirements: abi.Features = .{};
    appendRequirements(&requirements, module);
    return requirements;
}

pub fn requirementsForOperation(op: *ir.Operation) abi.Features {
    const name = op.name.name;
    if (isName(name, MemrefDialect.AllocOp.operation_name)) return memrefAllocRequirements(MemrefDialect.AllocOp{ .op = op });
    if (isName(name, MemrefDialect.AtomicRmwOp.operation_name)) return memrefAtomicRmwRequirements(MemrefDialect.AtomicRmwOp{ .op = op });
    if (isName(name, MemrefDialect.AtomicCasOp.operation_name)) return memrefAtomicCasRequirements(MemrefDialect.AtomicCasOp{ .op = op });
    if (isName(name, GpuDialect.AtomicLoadOp.operation_name)) return .{ .unsupported_atomic = true };
    if (isName(name, GpuDialect.AtomicStoreOp.operation_name)) return .{ .unsupported_atomic = true };
    if (isName(name, GpuDialect.AtomicAddOp.operation_name)) return .{ .unsupported_atomic = true };
    if (isName(name, GpuDialect.AtomicMaxOp.operation_name)) return .{ .unsupported_atomic = true };
    if (isName(name, GpuDialect.AtomicCasOp.operation_name)) return .{ .unsupported_atomic = true };
    if (isName(name, GpuDialect.MemcpyAsyncOp.operation_name)) return .{ .async_copy = true };
    if (isName(name, GpuDialect.MmaSyncOp.operation_name)) return .{ .tensor_cores = true };
    if (isName(name, GpuDialect.CpAsyncSharedOp.operation_name)) return .{ .tensor_cores = true };
    if (isName(name, GpuDialect.CpAsyncCommitOp.operation_name)) return .{ .tensor_cores = true };
    if (isName(name, GpuDialect.CpAsyncWaitOp.operation_name)) return .{ .tensor_cores = true };
    if (isName(name, arith.ArithDialect.Tf32RoundOp.operation_name)) return .{ .tensor_cores = true };
    return .{};
}

fn appendRequirements(requirements: *abi.Features, op: *ir.Operation) void {
    mergeRequirements(requirements, requirementsForOperation(op));
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

fn mergeRequirements(requirements: *abi.Features, required: abi.Features) void {
    requirements.atomic_i32 = requirements.atomic_i32 or required.atomic_i32;
    requirements.atomic_u32 = requirements.atomic_u32 or required.atomic_u32;
    requirements.atomic_index = requirements.atomic_index or required.atomic_index;
    requirements.atomic_f32_add_device = requirements.atomic_f32_add_device or required.atomic_f32_add_device;
    requirements.atomic_f32_add_shared = requirements.atomic_f32_add_shared or required.atomic_f32_add_shared;
    requirements.unsupported_atomic = requirements.unsupported_atomic or required.unsupported_atomic;
    requirements.async_copy = requirements.async_copy or required.async_copy;
    requirements.tensor_cores = requirements.tensor_cores or required.tensor_cores;
    requirements.cooperative_matrix = requirements.cooperative_matrix or required.cooperative_matrix;
    requirements.dynamic_shared_memory = requirements.dynamic_shared_memory or required.dynamic_shared_memory;
    requirements.indirect_launch = requirements.indirect_launch or required.indirect_launch;
}

fn isName(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

fn memrefAllocRequirements(op: MemrefDialect.AllocOp) abi.Features {
    if (op.getDynamicSize() == null) return .{};
    const params = memrefParams(op.getResult().type) orelse return .{};
    return switch (params.addr_space) {
        .shared => .{ .dynamic_shared_memory = true },
        .host, .device, .constant, .unified, .local => .{},
    };
}

fn memrefAtomicRmwRequirements(op: MemrefDialect.AtomicRmwOp) abi.Features {
    const params = memrefParams(op.getMemref().type) orelse return .{ .unsupported_atomic = true };
    const kind = op.getKind() orelse return .{ .unsupported_atomic = true };
    const scalar = arith.scalarKindFromTypeName(params.element_type_name) orelse return .{ .unsupported_atomic = true };
    return atomicRmwRequirements(kind, scalar, params.addr_space);
}

fn memrefAtomicCasRequirements(op: MemrefDialect.AtomicCasOp) abi.Features {
    const params = memrefParams(op.getMemref().type) orelse return .{ .unsupported_atomic = true };
    if (params.addr_space == .local) return .{ .unsupported_atomic = true };
    const scalar = arith.scalarKindFromTypeName(params.element_type_name) orelse return .{ .unsupported_atomic = true };
    return atomicIntegerRequirements(scalar);
}

fn memrefParams(memref_type: ir.Type) ?MemrefDialect.MemrefParams {
    if (!isName(memref_type.getDialectTypeName() orelse return null, MemrefDialect.name)) return null;
    return MemrefDialect.parseMemrefParams(memref_type.getDialectParamKey() orelse return null);
}

fn atomicRmwRequirements(
    kind: dialects.AtomicRmwKind,
    scalar: arith.ScalarKind,
    addr_space: dialects.AddressSpace,
) abi.Features {
    if (addr_space == .local) return .{ .unsupported_atomic = true };
    switch (scalar) {
        .i32, .u32, .index => return atomicIntegerRequirements(scalar),
        .f32 => {
            if (kind != .add) return .{ .unsupported_atomic = true };
            return switch (addr_space) {
                .host, .device, .unified => .{ .atomic_f32_add_device = true },
                .shared => .{ .atomic_f32_add_shared = true },
                .constant, .local => .{ .unsupported_atomic = true },
            };
        },
        .i8, .i16, .i64, .u8, .u16, .u64, .f16, .bf16, .f64, .bool => return .{ .unsupported_atomic = true },
    }
}

fn atomicIntegerRequirements(scalar: arith.ScalarKind) abi.Features {
    return switch (scalar) {
        .i32 => .{ .atomic_i32 = true },
        .u32 => .{ .atomic_u32 = true },
        .index => .{ .atomic_index = true },
        else => .{ .unsupported_atomic = true },
    };
}
