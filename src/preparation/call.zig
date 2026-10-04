const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const kernel_library = @import("../kernel/library/root.zig");

const ir = choir.ir;
const rewrite = ir.rewrite;
const dialects = choir.dialects;
const dialect_mod = accy_choir.dialect;
const semantic = accy_choir.semantic;

pub const CatalogCallOptions = struct {
    has_side_effects: bool = false,
    operand_effects: ?[]const semantic.KernelOperandEffect = null,
    result_aliases: ?[]const ?usize = null,
    runtime_scalars: ?[]const dialect_mod.AccyDialect.KernelCallScalar = null,
};

pub fn catalogCallScalars(
    comptime count: usize,
    arguments: [count]gpu_abi.ScalarArgument,
) [count]dialect_mod.AccyDialect.KernelCallScalar {
    var scalars: [count]dialect_mod.AccyDialect.KernelCallScalar = undefined;
    for (arguments, 0..) |argument, index| {
        scalars[index] = switch (argument) {
            .i32 => |value| .{ .kind = .i32, .bits = @as(u32, @bitCast(value)) },
            .u32 => |value| .{ .kind = .u32, .bits = value },
            .i64 => |value| .{ .kind = .i64, .bits = @bitCast(value) },
            .u64 => |value| .{ .kind = .u64, .bits = value },
            .f32 => |value| .{ .kind = .f32, .bits = @as(u32, @bitCast(value)) },
            .f64 => |value| .{ .kind = .f64, .bits = @bitCast(value) },
        };
    }
    return scalars;
}

pub const CatalogCallRequest = struct {
    descriptor: kernel_library.CatalogDescriptor,
    operands: []const *ir.Value,
    result_types: []const ir.Type,
    options: CatalogCallOptions = .{},
};

pub fn insertCatalogCall(
    rewriter: *rewrite.PatternRewriter,
    request: CatalogCallRequest,
) !dialect_mod.AccyDialect.KernelCallOp {
    const operand_effects = try kernelOperandEffects(
        rewriter.allocator,
        request.operands.len,
        request.options.operand_effects,
    );
    defer if (request.options.operand_effects == null) rewriter.allocator.free(operand_effects);

    const result_aliases = try kernelResultAliases(
        rewriter.allocator,
        request.result_types.len,
        request.options.result_aliases,
    );
    defer if (request.options.result_aliases == null) rewriter.allocator.free(result_aliases);

    const metadata = request.descriptor.metadata;
    const call = try dialect_mod.AccyDialect.KernelCallOp.create(
        rewriter.ir_ctx,
        ir.Location.getUnknown(),
        request.operands,
        request.result_types,
        metadata.target,
        metadata.version,
        request.options.has_side_effects,
        operand_effects,
        result_aliases,
    );
    if (request.options.runtime_scalars) |scalars| {
        try dialect_mod.AccyDialect.setKernelCallRuntimeScalars(rewriter.ir_ctx, call.op, scalars);
    }
    _ = try rewriter.insert(call.op);
    return call;
}

fn kernelOperandEffects(
    allocator: std.mem.Allocator,
    operand_count: usize,
    provided: ?[]const semantic.KernelOperandEffect,
) ![]const semantic.KernelOperandEffect {
    if (provided) |effects| {
        if (effects.len != operand_count) return error.InvalidKernelCallContract;
        return effects;
    }

    const effects = try allocator.alloc(semantic.KernelOperandEffect, operand_count);
    @memset(effects, .read);
    return effects;
}

fn kernelResultAliases(
    allocator: std.mem.Allocator,
    result_count: usize,
    provided: ?[]const ?usize,
) ![]const ?usize {
    if (provided) |aliases| {
        if (aliases.len != result_count) return error.InvalidKernelCallContract;
        return aliases;
    }

    const aliases = try allocator.alloc(?usize, result_count);
    @memset(aliases, null);
    return aliases;
}

fn findOpNamed(op: *ir.Operation, name: []const u8) ?*ir.Operation {
    if (std.mem.eql(u8, op.name.name, name)) return op;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                if (findOpNamed(current_op, name)) |found| return found;
                current = current_op.next_op;
            }
        }
    }
    return null;
}

const testing = std.testing;
