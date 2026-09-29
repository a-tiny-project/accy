const std = @import("std");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const spirv_target = @import("../root.zig");
const gpu_target = @import("../../../../dialects/gpu/root.zig");
const catalog = @import("catalog.zig");

const GpuDialect = gpu_target.GpuDialect;
const Stage = gpu_target.Stage;
const FuncDialect = dialects.func.FuncDialect;
const MemrefDialect = dialects.memref.MemrefDialect;
const SpirvDialect = spirv_target.SpirvDialect;
const BuiltinDialect = dialects.builtin.BuiltinDialect;

pub fn isFunctionOp(op: *ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name) or
        std.mem.eql(u8, op.name.name, GpuDialect.FuncOp.operation_name);
}

pub fn validateModule(module: *ir.Operation) !void {
    if (!std.mem.eql(u8, module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
        return error.InvalidModule;
    }

    const region = module.getRegion(0) orelse return error.InvalidModule;
    const block = region.getEntryBlock() orelse return error.InvalidModule;

    var saw_entry = false;
    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (isFunctionOp(op)) {
            const stage = gpu_target.stage.stageOf(op);
            if (op.getAttr("kernel") != null) {
                if (stage != null) return error.InvalidModule;
                saw_entry = true;
                try validateEntryOp(op, null);
            } else if (stage != null) {
                saw_entry = true;
                try validateEntryOp(op, stage);
            } else if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) {
                return error.UnsupportedOperation;
            }
        } else {
            return error.UnsupportedOperation;
        }
        op_iter = op.next_op;
    }

    if (!saw_entry) return error.InvalidModule;
}

/// The ops a stage function takes beyond the gpu stage vocabulary: scalar
/// arithmetic and structured control flow. Buffers, shared memory and the
/// compute builtins that lower into SPIR-V ops stay in kernels.
fn stageAdmits(op_name: []const u8) bool {
    const prefixes = [_][]const u8{ "arith.", "scf.", "func.", "gpu." };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, op_name, prefix)) return true;
    }
    if (std.mem.eql(u8, op_name, MemrefDialect.AllocaOp.operation_name) or
        std.mem.eql(u8, op_name, MemrefDialect.LoadOp.operation_name) or
        std.mem.eql(u8, op_name, MemrefDialect.StoreOp.operation_name)) return true;
    const lowered = [_][]const u8{
        SpirvDialect.ConstantOp.operation_name,
        SpirvDialect.IAddOp.operation_name,
        SpirvDialect.FAddOp.operation_name,
        SpirvDialect.ISubOp.operation_name,
        SpirvDialect.FSubOp.operation_name,
        SpirvDialect.IMulOp.operation_name,
        SpirvDialect.FMulOp.operation_name,
        SpirvDialect.UDivOp.operation_name,
        SpirvDialect.SDivOp.operation_name,
        SpirvDialect.FDivOp.operation_name,
    };
    for (lowered) |name| {
        if (std.mem.eql(u8, op_name, name)) return true;
    }
    return false;
}

fn validateEntryOp(func_op: *ir.Operation, stage: ?Stage) !void {
    if (func_op.getResultTypes().len != 0) return error.UnsupportedFunctionSignature;

    const region = func_op.getRegion(0) orelse return error.InvalidModule;
    if (!region.hasOneBlock()) return error.UnsupportedControlFlow;
    const entry = region.getEntryBlock() orelse return error.InvalidModule;

    var op_iter = entry.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        try validateOperationTree(op, stage, false);
        op_iter = op.next_op;
    }
}

pub fn validateHelperOp(func_op: *ir.Operation) !void {
    if (func_op.getResultTypes().len > 1) return error.UnsupportedFunctionSignature;
    const region = func_op.getRegion(0) orelse return error.InvalidModule;
    if (!region.hasOneBlock()) return error.UnsupportedControlFlow;
    var ops = region.getEntryBlock().?.getOperations();
    while (ops.next()) |op| try validateOperationTree(op, null, true);
}

fn validateOperationTree(op: *ir.Operation, stage: ?Stage, helper: bool) !void {
    if (!catalog.supports(op.name.name)) return error.UnsupportedOperation;
    if (!gpu_target.stage.admits(stage, op.name.name)) return error.UnsupportedOperation;
    if (stage != null and !stageAdmits(op.name.name)) return error.UnsupportedOperation;
    if (helper and !stageAdmits(op.name.name)) return error.UnsupportedOperation;
    if (helper and std.mem.startsWith(u8, op.name.name, "gpu.")) return error.UnsupportedOperation;

    var region_index: usize = 0;
    while (region_index < op.getNumRegions()) : (region_index += 1) {
        const region = op.getRegion(region_index) orelse continue;
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var child_iter = block.operations.head;
            while (child_iter) |child_ptr| {
                const child: *ir.Operation = @ptrCast(@alignCast(child_ptr));
                try validateOperationTree(child, stage, helper);
                child_iter = child.next_op;
            }
        }
    }
}

test "spirv validation rejects module without kernel" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    try std.testing.expectError(error.InvalidModule, validateModule(module.op));
}

test "spirv kernel catalog excludes module and function boundaries" {
    try std.testing.expect(!catalog.supports(BuiltinDialect.ModuleOp.operation_name));
    try std.testing.expect(!catalog.supports(FuncDialect.FuncOp.operation_name));
    try std.testing.expect(!catalog.supports(GpuDialect.FuncOp.operation_name));
    try std.testing.expect(!catalog.supports(SpirvDialect.ModuleOp.operation_name));
}

test "spirv validation rejects a noncatalog boundary inside a kernel" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{});
    try module.getBodyBlock().addOperation(func.op);

    const unsupported = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    try func.getEntryBlock().addOperation(unsupported.op);

    try std.testing.expectError(error.UnsupportedOperation, validateModule(module.op));
}
