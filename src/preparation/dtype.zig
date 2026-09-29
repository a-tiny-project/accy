const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const dialect_mod = accy_choir.dialect;
const shape_analysis = @import("shape/root.zig");

const ir = choir.ir;
const passes = choir.passes;
const work = passes.pass.work;

pub const dtype_legalization_pass_name = "accy-choir-legalize-dtypes";
pub const dtype_legalization_pass_description =
    "Check Accy Choir dtypes supported by backend lowering";

pub fn dtypeLegalizationPass() passes.Pass {
    return .{
        .name = dtype_legalization_pass_name,
        .description = dtype_legalization_pass_description,
        .run_fn = runDTypeLegalizationPass,
        .work_contract = .{
            .identity = .{ .name = dtype_legalization_pass_name, .version = 1 },
            .estimate = dtypePassWork,
        },
    };
}

fn dtypePassWork(input: work.Input) !work.Bounds {
    const counts = try work.Census.inspect(input.operation);
    const units = try work.add(try work.add(counts.atoms, counts.input_bytes), 1);
    const values = try work.add(try work.add(counts.values, counts.operands), 1);
    return .{ .work = .{
        .input_bytes = counts.input_bytes,
        .structural_visits = try work.multiply(256, try work.multiply(units, values)),
    } };
}

fn runDTypeLegalizationPass(pass_ctx: *passes.PassContext) passes.PassResult {
    const analysis = shape_analysis.getShapeLayoutAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    if (!legalizeOnOp(pass_ctx.op, analysis)) return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn legalizeOnOp(op: *ir.Operation, analysis: *const shape_analysis.ShapeLayoutAnalysis) bool {
    if (!checkResults(op, analysis, .signature)) return false;

    if (std.mem.startsWith(u8, op.name.name, "accy.")) {
        if (!legalizeAccyOp(op, analysis)) return false;
    } else if (std.mem.eql(u8, op.name.name, "func.return")) {
        if (!checkOperands(op, analysis, .signature)) return false;
    }

    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            for (block.arguments.items) |arg| {
                if (!checkValue(arg, analysis, .signature)) return false;
            }
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                if (!legalizeOnOp(current_op, analysis)) return false;
                current = current_op.next_op;
            }
        }
    }
    return true;
}

fn legalizeAccyOp(op: *ir.Operation, analysis: *const shape_analysis.ShapeLayoutAnalysis) bool {
    if (!checkOperands(op, analysis, .signature)) return false;
    if (!checkResults(op, analysis, .signature)) return false;

    const name = op.name.name;
    if (isName(name, dialect_mod.AccyDialect.AddOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.SubOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.MulOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.DivOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.MaxOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.MinOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.NegOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.AbsOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.ReduceOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.DotGeneralOp.operation_name))
    {
        return checkOperands(op, analysis, .numeric) and checkResults(op, analysis, .numeric);
    }

    if (isName(name, dialect_mod.AccyDialect.PowOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.Atan2Op.operation_name) or
        isName(name, dialect_mod.AccyDialect.ExpOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.LogOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.TanhOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.SqrtOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.SinOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.CosOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.TanOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.FloorOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.RoundOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.TruncOp.operation_name))
    {
        return checkOperands(op, analysis, .float) and checkResults(op, analysis, .float);
    }

    if (isName(name, dialect_mod.AccyDialect.CompareOp.operation_name)) {
        return op.getNumOperands() == 2 and
            op.getNumResults() == 1 and
            checkOperands(op, analysis, .numeric) and
            checkResults(op, analysis, .bool_only);
    }

    if (isName(name, dialect_mod.AccyDialect.ConvertOp.operation_name)) {
        return op.getNumOperands() == 1 and
            op.getNumResults() == 1 and
            checkOperands(op, analysis, .numeric) and
            checkResults(op, analysis, .numeric);
    }

    if (isName(name, dialect_mod.AccyDialect.SelectOp.operation_name)) {
        return op.getNumOperands() == 3 and
            op.getNumResults() == 1 and
            checkOperandAt(op, 0, analysis, .bool_only) and
            checkOperandAt(op, 1, analysis, .selectable) and
            checkOperandAt(op, 2, analysis, .selectable) and
            checkResults(op, analysis, .selectable);
    }

    if (isName(name, dialect_mod.AccyDialect.IotaOp.operation_name)) {
        return op.getNumOperands() == 0 and checkResults(op, analysis, .numeric);
    }

    if (isName(name, dialect_mod.AccyDialect.GatherOp.operation_name)) {
        return op.getNumOperands() == 2 and
            op.getNumResults() == 1 and
            checkOperandAt(op, 0, analysis, .signature) and
            checkOperandAt(op, 1, analysis, .index_integer) and
            checkResults(op, analysis, .signature);
    }

    if (isName(name, dialect_mod.AccyDialect.ScatterOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.ScatterAddOp.operation_name))
    {
        return op.getNumOperands() == 3 and
            op.getNumResults() == 1 and
            checkOperandAt(op, 0, analysis, .signature) and
            checkOperandAt(op, 1, analysis, .index_integer) and
            checkOperandAt(op, 2, analysis, .signature) and
            checkResults(op, analysis, .signature);
    }

    if (isName(name, dialect_mod.AccyDialect.PadOp.operation_name)) {
        return op.getNumOperands() == 2 and
            op.getNumResults() == 1 and
            checkOperands(op, analysis, .signature) and
            checkResults(op, analysis, .signature);
    }

    if (isName(name, dialect_mod.AccyDialect.ConstantOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.ReshapeOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.BroadcastOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.TransposeOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.SliceOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.KernelCallOp.operation_name) or
        isName(name, dialect_mod.AccyDialect.ConcatenateOp.operation_name))
    {
        return true;
    }

    if (isName(name, dialect_mod.AccyDialect.IterateOp.operation_name)) {
        return checkOperands(op, analysis, .iterable) and checkResults(op, analysis, .iterable);
    }

    if (isName(name, dialect_mod.AccyDialect.CumsumOp.operation_name)) {
        return checkOperandAt(op, 0, analysis, .numeric) and checkResults(op, analysis, .numeric);
    }

    if (isName(name, dialect_mod.AccyDialect.ScratchOp.operation_name)) {
        return true;
    }

    if (isName(name, dialect_mod.AccyDialect.IterateYieldOp.operation_name)) {
        return op.getNumOperands() >= 2 and
            checkOperandAt(op, 0, analysis, .bool_only);
    }

    return false;
}

fn isName(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

const DTypeSet = enum {
    signature,
    numeric,
    float,
    bool_only,
    index_integer,
    selectable,
    iterable,
};

fn checkOperands(
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    set: DTypeSet,
) bool {
    for (op.operands.items) |operand| {
        if (!checkValue(operand.value, analysis, set)) return false;
    }
    return true;
}

fn checkResults(
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    set: DTypeSet,
) bool {
    for (op.results.items) |*result| {
        if (!checkValue(result, analysis, set)) return false;
    }
    return true;
}

fn checkOperandAt(
    op: *ir.Operation,
    index: usize,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    set: DTypeSet,
) bool {
    const value = op.getOperand(index) orelse return false;
    return checkValue(value, analysis, set);
}

fn checkValue(
    value: *ir.Value,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    set: DTypeSet,
) bool {
    const info = analysis.get(value) orelse return true;
    return dtypeAllowed(info.dtype, set);
}

fn dtypeAllowed(dtype: gpu_abi.DType, set: DTypeSet) bool {
    return switch (set) {
        .signature => isSignatureDType(dtype),
        .numeric => isNumericDType(dtype),
        .float => dtype == .f32 or dtype == .f64 or dtype == .f16 or dtype == .bf16,
        .bool_only => dtype == .i1,
        .index_integer => isIntegerDType(dtype),
        .selectable => isNumericDType(dtype) or dtype == .i1,
        .iterable => isNumericDType(dtype) or dtype == .i1,
    };
}

fn isSignatureDType(dtype: gpu_abi.DType) bool {
    return isNumericDType(dtype) or dtype == .i1 or dtype == .key;
}

fn isNumericDType(dtype: gpu_abi.DType) bool {
    return switch (dtype) {
        .f32, .f64, .f16, .bf16 => true,
        else => isIntegerDType(dtype),
    };
}

fn isIntegerDType(dtype: gpu_abi.DType) bool {
    return dtype.isSignedInt() or dtype.isUnsignedInt();
}

const testing = std.testing;
const semantic = accy_choir.semantic;

test "dtype legalization accepts static numeric lowering dtypes" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("legalize_add4", &.{ f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
    try testing.expectEqual(@as(u64, 1), pm.stats.analysis_misses);
}

test "dtype legalization accepts unsigned arithmetic before backend capability checks" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const u32_4 = try builder.tensor(.u32, &.{4});
    var fb = try builder.beginFunction("legalize_unsigned_add4", &.{ u32_4, u32_4 }, &.{u32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "dtype legalization accepts indexing and padding ops" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_scalar = try builder.tensor(.f32, &.{});
    const f32_4 = try builder.tensor(.f32, &.{4});
    const i32_4 = try builder.tensor(.i32, &.{4});
    var fb = try builder.beginFunction("legalize_indexing_pad", &.{ f32_4, i32_4 }, &.{f32_4});
    const zero: f32 = 0;
    const padding = try fb.constant(f32_scalar, std.mem.asBytes(&zero));
    const gathered = try fb.gather(fb.parameter(0), fb.parameter(1), f32_4, 0);
    const scattered = try fb.scatter(fb.parameter(0), fb.parameter(1), gathered, f32_4, 0);
    const accumulated = try fb.scatterAdd(scattered, fb.parameter(1), gathered, f32_4, 0);
    const padded = try fb.pad(accumulated, padding, f32_4, &.{1}, &.{-1}, &.{0});
    try fb.return_(&.{padded});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "dtype legalization accepts unsigned indexing dtypes" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    const u32_4 = try builder.tensor(.u32, &.{4});
    var fb = try builder.beginFunction("legalize_unsigned_indexing", &.{ f32_4, u32_4 }, &.{f32_4});
    const gathered = try fb.gather(fb.parameter(0), fb.parameter(1), f32_4, 0);
    try fb.return_(&.{gathered});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "dtype legalization accepts kernel_call contracts" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("legalize_kernel_call", &.{f32_4}, &.{f32_4});
    const call = try fb.kernelCall(
        &.{fb.parameter(0)},
        &.{f32_4},
        .{
            .target = "accy.custom.scale",
            .operand_effects = &.{.read},
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "dtype legalization accepts bf16 arithmetic before backend capability checks" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const bf16_4 = try builder.tensor(.bf16, &.{4});
    var fb = try builder.beginFunction("legalize_bf16_add", &.{ bf16_4, bf16_4 }, &.{bf16_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "dtype legalization accepts key kernel_call boundaries" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const key_8 = try builder.tensor(.key, &.{8});
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("legalize_key_kernel_call", &.{key_8}, &.{f32_8});
    const call = try fb.kernelCall(
        &.{fb.parameter(0)},
        &.{f32_8},
        .{
            .target = "accy.kernel.random.philox_key_uniform_family_10r_64_f32",
            .operand_effects = &.{.read},
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "dtype legalization accepts bool iterate carries" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const bool_4 = try builder.tensor(.i1, &.{4});
    var fb = try builder.beginFunction("legalize_bool_iterate", &.{bool_4}, &.{bool_4});
    var iterate = try fb.beginIterate(&.{fb.parameter(0)}, 4);
    try iterate.yield_(iterate.carry(0), &.{iterate.carry(0)});
    try fb.return_(&.{iterate.result(0)});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "key arithmetic is rejected upstream by the semantic dialect" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const key_4 = try builder.tensor(.key, &.{4});
    var fb = try builder.beginFunction("illegal_key_add", &.{ key_4, key_4 }, &.{key_4});
    try testing.expectError(error.UnsupportedDType, fb.add(fb.parameter(0), fb.parameter(1)));
}

test "dtype legalization rejects bool iota before lowering" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const bool_4 = try builder.tensor(.i1, &.{4});
    var fb = try builder.beginFunction("illegal_bool_iota", &.{}, &.{bool_4});
    const ramp = try fb.iota(bool_4, 0);
    try fb.return_(&.{ramp});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(dtypeLegalizationPass());

    try testing.expectEqual(passes.PassResult.failure, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_failures);
}
