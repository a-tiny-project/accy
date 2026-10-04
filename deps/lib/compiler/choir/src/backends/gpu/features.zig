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

test "target features infer atomics from memref atomic operations" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try dialects.arith.ArithDialect.getI32Type(&ctx);
    const index_type = try dialects.arith.ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);
    const alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    const idx = try dialects.arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);
    const value = try dialects.arith.ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    const atomic = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        value.getResult(),
        alloc.getResult(),
        idx.getResult(),
        i32_type,
    );

    try std.testing.expect(requirementsForOperation(atomic.op).atomic_i32);
}

test "target features infer dynamic shared memory from shared dynamic allocation" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try dialects.arith.ArithDialect.getScalarType(&ctx, .f32);
    const index_type = try dialects.arith.ArithDialect.getIndexType(&ctx);
    const size = try dialects.arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 16);

    const shared_type = try MemrefDialect.getMemrefType1D(&ctx, 16, f32_type, .shared);
    const shared = try MemrefDialect.AllocOp.createDynamic(&ctx, loc, size.getResult(), shared_type);
    const shared_requirements = requirementsForOperation(shared.op);
    try std.testing.expect(shared_requirements.dynamic_shared_memory);

    const static_shared = try MemrefDialect.AllocOp.createStatic(&ctx, loc, shared_type);
    try std.testing.expect(!requirementsForOperation(static_shared.op).dynamic_shared_memory);

    const device_type = try MemrefDialect.getMemrefType1D(&ctx, 16, f32_type, .device);
    const device = try MemrefDialect.AllocOp.createDynamic(&ctx, loc, size.getResult(), device_type);
    try std.testing.expect(!requirementsForOperation(device.op).dynamic_shared_memory);
}

test "target features classify f32 atomic add by address space" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try dialects.arith.ArithDialect.getScalarType(&ctx, .f32);
    const index_type = try dialects.arith.ArithDialect.getIndexType(&ctx);
    const idx = try dialects.arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);
    const value = try dialects.arith.ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);

    const device_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);
    const device = try MemrefDialect.AllocOp.createStatic(&ctx, loc, device_type);
    const device_atomic = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        value.getResult(),
        device.getResult(),
        idx.getResult(),
        f32_type,
    );
    const device_requirements = requirementsForOperation(device_atomic.op);
    try std.testing.expect(device_requirements.atomic_f32_add_device);
    try std.testing.expect(!device_requirements.atomic_f32_add_shared);
    try std.testing.expect(!device_requirements.unsupported_atomic);

    const shared_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .shared);
    const shared = try MemrefDialect.AllocOp.createStatic(&ctx, loc, shared_type);
    const shared_atomic = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        value.getResult(),
        shared.getResult(),
        idx.getResult(),
        f32_type,
    );
    const shared_requirements = requirementsForOperation(shared_atomic.op);
    try std.testing.expect(!shared_requirements.atomic_f32_add_device);
    try std.testing.expect(shared_requirements.atomic_f32_add_shared);
    try std.testing.expect(!shared_requirements.unsupported_atomic);
}

test "target features mark unsupported atomic dtype and float kind" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try dialects.arith.ArithDialect.getScalarType(&ctx, .f32);
    const f64_type = try dialects.arith.ArithDialect.getF64Type(&ctx);
    const index_type = try dialects.arith.ArithDialect.getIndexType(&ctx);
    const idx = try dialects.arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);
    const f32_value = try dialects.arith.ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    const f64_value = try dialects.arith.ArithDialect.ConstantOp.createFloat(&ctx, loc, f64_type, 1.0);

    const f32_memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);
    const f32_memref = try MemrefDialect.AllocOp.createStatic(&ctx, loc, f32_memref_type);
    const exchange = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .exchange,
        f32_value.getResult(),
        f32_memref.getResult(),
        idx.getResult(),
        f32_type,
    );
    try std.testing.expect(requirementsForOperation(exchange.op).unsupported_atomic);

    const f64_memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f64_type, .device);
    const f64_memref = try MemrefDialect.AllocOp.createStatic(&ctx, loc, f64_memref_type);
    const add = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        f64_value.getResult(),
        f64_memref.getResult(),
        idx.getResult(),
        f64_type,
    );
    try std.testing.expect(requirementsForOperation(add.op).unsupported_atomic);
}

test "target features infer async copy from gpu memcpy async operations" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try dialects.arith.ArithDialect.getI32Type(&ctx);
    const index_type = try dialects.arith.ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ctx, 16, i32_type, .device);
    const src = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    const dst = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_type);
    const size = try dialects.arith.ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 16);
    const copy = try GpuDialect.MemcpyAsyncOp.create(
        &ctx,
        loc,
        src.getResult(),
        dst.getResult(),
        size.getResult(),
        null,
        null,
    );

    const requirements = requirementsForOperation(copy.op);
    try std.testing.expect(requirements.async_copy);
    try std.testing.expect(!requirements.atomic_i32);
    try std.testing.expect(!requirements.atomic_f32_add_device);
    try std.testing.expect(!requirements.unsupported_atomic);
}

test "target features infer tensor cores from gpu mma operations" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try dialects.arith.ArithDialect.getScalarType(&ctx, .f32);
    const shape = gpu.MmaShape{ .m = 16, .n = 8, .k = 8 };

    try ctx.allowUnregistered();
    var builder = ir.OperationBuilder.init(&ctx);
    var source_state = ir.Operation.State.init("test.frag_source", loc);
    source_state.addTypes(&.{ f32_type, f32_type, f32_type, f32_type, f32_type, f32_type, f32_type, f32_type, f32_type, f32_type });
    const source = try builder.create(source_state);

    const mma = try GpuDialect.MmaSyncOp.create(&ctx, loc, .{
        source.getResult(0).?,
        source.getResult(1).?,
        source.getResult(2).?,
        source.getResult(3).?,
    }, .{
        source.getResult(4).?,
        source.getResult(5).?,
    }, .{
        source.getResult(6).?,
        source.getResult(7).?,
        source.getResult(8).?,
        source.getResult(9).?,
    }, shape);

    const round = try dialects.arith.ArithDialect.Tf32RoundOp.create(&ctx, loc, source.getResult(0).?);

    try std.testing.expect(requirementsForOperation(mma.op).tensor_cores);
    try std.testing.expect(requirementsForOperation(round.op).tensor_cores);
    try std.testing.expect(!requirementsForOperation(source).tensor_cores);
}
