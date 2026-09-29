const std = @import("std");
const choir = @import("choir");
const accy_root = @import("../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const ArithDialect = dialects.ArithDialect;
const FuncDialect = dialects.FuncDialect;
const GpuDialect = dialects.gpu.GpuDialect;
const MemrefDialect = dialects.MemrefDialect;
const ScfDialect = dialects.ScfDialect;
const lowerKernelToHostLoop = choir.backends.gpu.cpu.lowerKernelToHostLoop;

fn containsOperationNamed(op: *ir.Operation, name: []const u8) bool {
    if (std.mem.eql(u8, op.name.name, name)) return true;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_iter = block.getOperations();
            while (op_iter.next()) |child| {
                if (containsOperationNamed(child, name)) return true;
            }
        }
    }
    return false;
}

fn countOperationNamed(op: *ir.Operation, name: []const u8) usize {
    var count: usize = if (std.mem.eql(u8, op.name.name, name)) 1 else 0;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_iter = block.getOperations();
            while (op_iter.next()) |child| {
                count += countOperationNamed(child, name);
            }
        }
    }
    return count;
}

fn containsResultTypeNamed(op: *ir.Operation, name: []const u8, type_name: []const u8) bool {
    if (std.mem.eql(u8, op.name.name, name)) {
        for (op.results.items) |result| {
            if (result.type.getDialectTypeName()) |found| {
                if (std.mem.eql(u8, found, type_name)) return true;
            }
        }
    }
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_iter = block.getOperations();
            while (op_iter.next()) |child| {
                if (containsResultTypeNamed(child, name, type_name)) return true;
            }
        }
    }
    return false;
}

fn containsStoreValueTypeNamed(op: *ir.Operation, type_name: []const u8) bool {
    if (std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name)) {
        const store = MemrefDialect.StoreOp{ .op = op };
        if (store.getValue().type.getDialectTypeName()) |found| {
            if (std.mem.eql(u8, found, type_name)) return true;
        }
    }
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_iter = block.getOperations();
            while (op_iter.next()) |child| {
                if (containsStoreValueTypeNamed(child, type_name)) return true;
            }
        }
    }
    return false;
}

fn firstFunction(module: *ir.Operation) ?FuncDialect.FuncOp {
    const region = module.getRegion(0) orelse return null;
    const block = region.getEntryBlock() orelse return null;
    var iter = block.getOperations();
    while (iter.next()) |op| {
        if (std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) return .{ .op = op };
    }
    return null;
}

test "cpu lowering wraps global x kernel body in host scf loop" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_copy_f32", &.{
        kernel.dynamicBuffer(.f32),
        kernel.dynamicBuffer(.f32),
    });
    errdefer builder.deinit();

    const src = builder.argument(0);
    const dst = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(src, index);
    try builder.store(value, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{ .entry_name = "cpu_copy_f32" });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expect(!host_func.isKernel());
    try std.testing.expectEqual(@as(usize, 10), host_func.getNumArguments());
    try std.testing.expect(containsOperationNamed(host_func.op, ScfDialect.ForOp.operation_name));
    try std.testing.expect(!containsOperationNamed(host_func.op, GpuDialect.GlobalIdxOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, ArithDialect.RemOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, dialects.MemrefDialect.LoadOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, dialects.MemrefDialect.StoreOp.operation_name));
}

test "cpu lowering vectorizes straight line global x add kernel" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_vectorized_add_f32", &.{
        kernel.dynamicBuffer(.f32),
        kernel.dynamicBuffer(.f32),
        kernel.dynamicBuffer(.f32),
    });
    errdefer builder.deinit();

    const axis = try builder.axis("i", 4);
    try builder.bind(axis, .thread_x);
    const dst = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const index = try builder.globalId(.x);
    const lhs_value = try builder.load(lhs, index);
    const rhs_value = try builder.load(rhs, index);
    const sum = try builder.add(lhs_value, rhs_value);
    try builder.store(sum, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{
        .entry_name = "cpu_vectorized_add_f32",
        .vector_width = 4,
    });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expect(!containsOperationNamed(host_func.op, GpuDialect.GlobalIdxOp.operation_name));
    try std.testing.expect(containsResultTypeNamed(host_func.op, MemrefDialect.LoadOp.operation_name, "arith.vec4xf32"));
    try std.testing.expect(containsResultTypeNamed(host_func.op, ArithDialect.AddOp.operation_name, "arith.vec4xf32"));
    try std.testing.expect(containsStoreValueTypeNamed(host_func.op, "arith.vec4xf32"));
}

test "cpu lowering leaves unsupported packed cpu vector width unvectorized" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_f64_add_width_four", &.{
        kernel.dynamicBuffer(.f64),
        kernel.dynamicBuffer(.f64),
        kernel.dynamicBuffer(.f64),
    });
    errdefer builder.deinit();

    const axis = try builder.axis("i", 4);
    try builder.bind(axis, .thread_x);
    const dst = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const index = try builder.globalId(.x);
    const lhs_value = try builder.load(lhs, index);
    const rhs_value = try builder.load(rhs, index);
    const sum = try builder.add(lhs_value, rhs_value);
    try builder.store(sum, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{
        .entry_name = "cpu_f64_add_width_four",
        .vector_width = 4,
    });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expect(!containsResultTypeNamed(host_func.op, MemrefDialect.LoadOp.operation_name, "arith.vec4xf64"));
    try std.testing.expect(!containsResultTypeNamed(host_func.op, ArithDialect.AddOp.operation_name, "arith.vec4xf64"));
    try std.testing.expect(!containsStoreValueTypeNamed(host_func.op, "arith.vec4xf64"));
}

test "cpu lowering vectorizes straight line global x f64 add kernel at supported width" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_vectorized_add_f64", &.{
        kernel.dynamicBuffer(.f64),
        kernel.dynamicBuffer(.f64),
        kernel.dynamicBuffer(.f64),
    });
    errdefer builder.deinit();

    const axis = try builder.axis("i", 2);
    try builder.bind(axis, .thread_x);
    const dst = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const index = try builder.globalId(.x);
    const lhs_value = try builder.load(lhs, index);
    const rhs_value = try builder.load(rhs, index);
    const sum = try builder.add(lhs_value, rhs_value);
    try builder.store(sum, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{
        .entry_name = "cpu_vectorized_add_f64",
        .vector_width = 2,
    });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expect(containsResultTypeNamed(host_func.op, MemrefDialect.LoadOp.operation_name, "arith.vec2xf64"));
    try std.testing.expect(containsResultTypeNamed(host_func.op, ArithDialect.AddOp.operation_name, "arith.vec2xf64"));
    try std.testing.expect(containsStoreValueTypeNamed(host_func.op, "arith.vec2xf64"));
}

test "cpu lowering vectorizes scalar argument splat and scalar tail" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_scalar_argument_add_f32", &.{
        kernel.dynamicBuffer(.f32),
        kernel.scalar(.f32),
        kernel.dynamicBuffer(.f32),
    });
    errdefer builder.deinit();

    const axis = try builder.axis("i", 6);
    try builder.bind(axis, .thread_x);
    const dst = builder.argument(0);
    const bias = builder.argument(1);
    const src = builder.argument(2);
    const index = try builder.globalId(.x);
    const value = try builder.load(src, index);
    const sum = try builder.add(value, bias);
    try builder.store(sum, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{
        .entry_name = "cpu_scalar_argument_add_f32",
        .vector_width = 4,
    });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expectEqual(@as(usize, 2), countOperationNamed(host_func.op, ScfDialect.ForOp.operation_name));
    try std.testing.expect(containsResultTypeNamed(host_func.op, MemrefDialect.LoadOp.operation_name, "arith.vec4xf32"));
    try std.testing.expect(containsResultTypeNamed(host_func.op, ArithDialect.SplatOp.operation_name, "arith.vec4xf32"));
    try std.testing.expect(containsResultTypeNamed(host_func.op, ArithDialect.AddOp.operation_name, "arith.vec4xf32"));
    try std.testing.expect(containsStoreValueTypeNamed(host_func.op, "arith.vec4xf32"));
}

test "cpu lowering vectorizes expanded pure op coverage" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_vectorized_max_neg_f32", &.{
        kernel.dynamicBuffer(.f32),
        kernel.dynamicBuffer(.f32),
        kernel.dynamicBuffer(.f32),
    });
    errdefer builder.deinit();

    const axis = try builder.axis("i", 4);
    try builder.bind(axis, .thread_x);
    const dst = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const index = try builder.globalId(.x);
    const lhs_value = try builder.load(lhs, index);
    const rhs_value = try builder.load(rhs, index);
    const larger = try builder.max(lhs_value, rhs_value);
    const value = try builder.neg(larger);
    try builder.store(value, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{
        .entry_name = "cpu_vectorized_max_neg_f32",
        .vector_width = 4,
    });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expect(containsResultTypeNamed(host_func.op, ArithDialect.MaxOp.operation_name, "arith.vec4xf32"));
    try std.testing.expect(containsResultTypeNamed(host_func.op, ArithDialect.NegOp.operation_name, "arith.vec4xf32"));
    try std.testing.expect(containsStoreValueTypeNamed(host_func.op, "arith.vec4xf32"));
}

test "cpu lowering derives global y and z from flat launch shape" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_global_yz", &.{});
    errdefer builder.deinit();

    _ = try builder.globalId(.y);
    _ = try builder.globalId(.z);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{ .entry_name = "cpu_global_yz" });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expectEqual(@as(usize, 8), host_func.getNumArguments());
    try std.testing.expect(!containsOperationNamed(host_func.op, GpuDialect.GlobalIdxOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, ArithDialect.DivOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, ArithDialect.RemOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, ArithDialect.MulOp.operation_name));
}

test "cpu lowering derives thread block and launch dimension ops" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_thread_block_dims", &.{});
    errdefer builder.deinit();

    _ = try builder.threadId(.x);
    _ = try builder.blockId(.x);
    _ = try builder.blockDim(.x);
    _ = try builder.gridDim(.x);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    const lowered = try lowerKernelToHostLoop(allocator, program.kernelModule(), .{ .entry_name = "cpu_thread_block_dims" });
    defer lowered.erase();

    try ir.verifyOperation(lowered, ir.verify.default_options);
    const host_func = firstFunction(lowered) orelse return error.ExpectedHostFunction;
    try std.testing.expectEqual(@as(usize, 8), host_func.getNumArguments());
    try std.testing.expect(!containsOperationNamed(host_func.op, GpuDialect.ThreadIdxOp.operation_name));
    try std.testing.expect(!containsOperationNamed(host_func.op, GpuDialect.BlockIdxOp.operation_name));
    try std.testing.expect(!containsOperationNamed(host_func.op, GpuDialect.BlockDimOp.operation_name));
    try std.testing.expect(!containsOperationNamed(host_func.op, GpuDialect.GridDimOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, ArithDialect.DivOp.operation_name));
    try std.testing.expect(containsOperationNamed(host_func.op, ArithDialect.RemOp.operation_name));
}

test "cpu lowering rejects unsupported gpu lane context ops" {
    const allocator = std.testing.allocator;
    const kernel = accy_root.kernel;

    var builder = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "cpu_lane_id_reject", &.{});
    errdefer builder.deinit();

    _ = try builder.laneId();
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();

    try std.testing.expectError(
        error.UnsupportedOperation,
        lowerKernelToHostLoop(allocator, program.kernelModule(), .{ .entry_name = "cpu_lane_id_reject" }),
    );
}
