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

test "catalog call insertion emits descriptor target and default contract" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("catalog_call_insertion", &.{ f32_8, f32_8 }, &.{f32_8});
    const lhs = fb.parameter(0);
    const rhs = fb.parameter(1);
    const out = try fb.add(lhs, rhs);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const return_op = findOpNamed(
        module.choir_module,
        dialects.FuncDialect.ReturnOp.operation_name,
    ) orelse {
        return error.TestExpectedReturn;
    };
    var rewriter = rewrite.PatternRewriter.init(allocator, module.context());
    defer rewriter.deinit();
    rewriter.setInsertionPointBefore(return_op);

    const result_types = [_]ir.Type{f32_8};
    const descriptor = kernel_library.findEntry(
        kernel_library.elementwise.VectorAdd8F32.target,
        kernel_library.elementwise.VectorAdd8F32.version,
    ) orelse return error.TestExpectedCatalogDescriptor;
    const call = try insertCatalogCall(&rewriter, .{
        .descriptor = descriptor,
        .operands = &.{ lhs, rhs },
        .result_types = &result_types,
    });

    try module.verify();
    const target_attr = call.op.getAttr("target") orelse return error.TestExpectedTarget;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse
        return error.TestExpectedTarget;
    try testing.expectEqualStrings(
        dialect_mod.AccyDialect.KernelCallOp.target_attr_name,
        target_attr.abstract.name,
    );
    try testing.expectEqualStrings(kernel_library.elementwise.VectorAdd8F32.target, target.payload);

    const version = call.op.getAttrAs(ir.Attribute.IntegerAttr, "version") orelse
        return error.TestExpectedVersion;
    try testing.expectEqual(
        @as(i64, kernel_library.elementwise.VectorAdd8F32.version),
        version.getValue(),
    );

    const effects_attr = call.op.getAttr("operand_effects") orelse {
        return error.TestExpectedOperandEffects;
    };
    const effects = effects_attr.cast(ir.Attribute.DialectAttr) orelse
        return error.TestExpectedOperandEffects;
    try testing.expectEqualStrings(
        dialect_mod.AccyDialect.KernelCallOp.operand_effects_attr_name,
        effects_attr.abstract.name,
    );
    try testing.expectEqual(@as(usize, 2), effects.payload.len);
    try testing.expectEqual(@backingInt(semantic.KernelOperandEffect.read), effects.payload[0]);
    try testing.expectEqual(@backingInt(semantic.KernelOperandEffect.read), effects.payload[1]);

    const aliases_attr = call.op.getAttr("result_aliases") orelse {
        return error.TestExpectedResultAliases;
    };
    const aliases = aliases_attr.cast(ir.Attribute.DialectAttr) orelse
        return error.TestExpectedResultAliases;
    try testing.expectEqualStrings(
        dialect_mod.AccyDialect.KernelCallOp.result_aliases_attr_name,
        aliases_attr.abstract.name,
    );
    try testing.expectEqual(@as(usize, @sizeOf(i64)), aliases.payload.len);
    const values = std.mem.bytesAsSlice(i64, aliases.payload);
    try testing.expectEqual(@as(i64, -1), values[0]);
}
