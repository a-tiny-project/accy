const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const pretty = @import("timing_runner_pretty");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const executable = @import("../executable/root.zig");
const kernel_library = @import("../kernel/library/root.zig");
const indexing_lowering = @import("indexing.zig");
const loss_lowering = @import("loss.zig");

const ir = choir.ir;
const passes = choir.passes;
const dialect_mod = accy_choir.dialect;
const AccyDialect = dialect_mod.AccyDialect;
const SemanticBuilder = accy_choir.SemanticBuilder;
const SemanticModule = accy_choir.SemanticModule;

fn compileAndLoadSemanticModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    module: *SemanticModule,
    options: executable.FragmentCompilerOptions,
) !*executable.LoadedFragment {
    const compiled = try executable.compileFragmentFromSemanticModule(allocator, handle, module, options);
    return try executable.loadFragment(allocator, handle, compiled, options);
}

const BuildFn = *const fn (std.mem.Allocator) anyerror!*SemanticModule;

const CheckFn = *const fn (std.mem.Allocator) anyerror!void;

const Coverage = union(enum) {
    covered: BuildFn,
    checked: CheckFn,
    uncovered,
    structural,
};

const Entry = struct {
    operation: []const u8,
    coverage: Coverage,
};

const table = [_]Entry{
    .{ .operation = AccyDialect.AddOp.operation_name, .coverage = .{ .covered = binaryModule(.add) } },
    .{ .operation = AccyDialect.SubOp.operation_name, .coverage = .{ .covered = binaryModule(.sub) } },
    .{ .operation = AccyDialect.MulOp.operation_name, .coverage = .{ .covered = binaryModule(.mul) } },
    .{ .operation = AccyDialect.DivOp.operation_name, .coverage = .{ .covered = binaryModule(.div) } },
    .{ .operation = AccyDialect.MaxOp.operation_name, .coverage = .{ .covered = binaryModule(.max) } },
    .{ .operation = AccyDialect.MinOp.operation_name, .coverage = .{ .covered = binaryModule(.min) } },
    .{ .operation = AccyDialect.NegOp.operation_name, .coverage = .{ .covered = unaryModule(.neg) } },
    .{ .operation = AccyDialect.ExpOp.operation_name, .coverage = .{ .covered = unaryModule(.exp) } },
    .{ .operation = AccyDialect.LogOp.operation_name, .coverage = .{ .covered = unaryModule(.log) } },
    .{ .operation = AccyDialect.SqrtOp.operation_name, .coverage = .{ .covered = unaryModule(.sqrt) } },
    .{ .operation = AccyDialect.TanhOp.operation_name, .coverage = .{ .covered = unaryModule(.tanh) } },
    .{ .operation = AccyDialect.AbsOp.operation_name, .coverage = .{ .covered = unaryModule(.abs) } },
    .{ .operation = AccyDialect.SinOp.operation_name, .coverage = .{ .covered = unaryModule(.sin) } },
    .{ .operation = AccyDialect.CosOp.operation_name, .coverage = .{ .covered = unaryModule(.cos) } },
    .{ .operation = AccyDialect.TanOp.operation_name, .coverage = .{ .covered = unaryModule(.tan) } },
    .{ .operation = AccyDialect.FloorOp.operation_name, .coverage = .{ .covered = unaryModule(.floor) } },
    .{ .operation = AccyDialect.RoundOp.operation_name, .coverage = .{ .covered = unaryModule(.round) } },
    .{ .operation = AccyDialect.TruncOp.operation_name, .coverage = .{ .covered = unaryModule(.trunc) } },
    .{ .operation = AccyDialect.PowOp.operation_name, .coverage = .{ .covered = binaryModule(.pow) } },
    .{ .operation = AccyDialect.Atan2Op.operation_name, .coverage = .{ .covered = binaryModule(.atan2) } },
    .{ .operation = AccyDialect.SelectOp.operation_name, .coverage = .{ .covered = compareSelectModule } },
    .{ .operation = AccyDialect.EinsumOp.operation_name, .coverage = .{ .covered = einsumModule } },
    .{ .operation = AccyDialect.DotGeneralOp.operation_name, .coverage = .{ .covered = dotGeneralModule } },
    .{ .operation = AccyDialect.BroadcastInDimOp.operation_name, .coverage = .{ .covered = broadcastInDimModule } },
    .{ .operation = AccyDialect.ReshapeOp.operation_name, .coverage = .{ .covered = reshapeModule } },
    .{ .operation = AccyDialect.TransposeOp.operation_name, .coverage = .{ .covered = transposeModule } },
    .{ .operation = AccyDialect.IotaOp.operation_name, .coverage = .{ .covered = iotaModule } },
    .{ .operation = AccyDialect.ConstantOp.operation_name, .coverage = .{ .covered = constantModule } },
    .{ .operation = AccyDialect.ActivationOp.operation_name, .coverage = .{ .covered = activationModule } },
    .{ .operation = AccyDialect.CompareOp.operation_name, .coverage = .{ .covered = compareSelectModule } },
    .{ .operation = AccyDialect.ConvertOp.operation_name, .coverage = .{ .covered = convertModule } },
    .{ .operation = AccyDialect.ReduceOp.operation_name, .coverage = .{ .covered = reduceModule } },
    .{ .operation = AccyDialect.BroadcastOp.operation_name, .coverage = .{ .covered = broadcastModule } },
    .{ .operation = AccyDialect.SliceOp.operation_name, .coverage = .{ .covered = sliceModule } },
    .{ .operation = AccyDialect.GatherOp.operation_name, .coverage = .{ .covered = gatherModule } },
    .{ .operation = AccyDialect.ScatterOp.operation_name, .coverage = .{ .covered = scatterModule } },
    .{ .operation = AccyDialect.ScatterAddOp.operation_name, .coverage = .{ .checked = scatterAddLowers } },
    .{ .operation = AccyDialect.SparseCrossEntropyOp.operation_name, .coverage = .{ .checked = sparseCrossEntropyLowers } },
    .{ .operation = AccyDialect.PadOp.operation_name, .coverage = .{ .covered = padModule } },
    .{ .operation = AccyDialect.ConcatenateOp.operation_name, .coverage = .{ .covered = concatenateModule } },
    .{ .operation = AccyDialect.KernelCallOp.operation_name, .coverage = .{ .checked = kernelCallLowers } },
    .{ .operation = AccyDialect.IterateOp.operation_name, .coverage = .{ .checked = iterateLowers } },
    .{ .operation = AccyDialect.CumsumOp.operation_name, .coverage = .{ .checked = cumsumLowers } },
    .{ .operation = AccyDialect.ScratchOp.operation_name, .coverage = .structural },
    .{ .operation = AccyDialect.IterateYieldOp.operation_name, .coverage = .structural },
    .{ .operation = AccyDialect.ReturnOp.operation_name, .coverage = .structural },
};

fn cumsumLowers(allocator: std.mem.Allocator) anyerror!void {
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8192});
    var fb = try builder.beginFunction("coverage_cumsum", &.{vec_ty}, &.{vec_ty});
    const out = try fb.cumsum(fb.parameter(0), vec_ty, 0);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();
    if (fragment.kernelCount() < 1) return error.CoverageExpectedKernel;
}

fn iterateLowers(allocator: std.mem.Allocator) anyerror!void {
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const module = try iterateModule(allocator);
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();
    if (fragment.kernelCount() < 1) return error.CoverageExpectedKernel;
}

fn iterateModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    const pred_ty = try builder.tensor(.i1, &.{8});
    var fb = try builder.beginFunction("coverage_iterate", &.{vec_ty}, &.{vec_ty});

    var it = try fb.beginIterate(&.{fb.parameter(0)}, 4);
    const body = it.inner();
    const ones: [8]f32 = @splat(1.0);
    const limits: [8]f32 = @splat(5.0);
    const one = try body.constant(vec_ty, std.mem.sliceAsBytes(ones[0..]));
    const limit = try body.constant(vec_ty, std.mem.sliceAsBytes(limits[0..]));
    const stepped = try body.add(it.carry(0), one);
    const active = try body.compare(stepped, limit, pred_ty, .lt);
    try it.yield_(active, &.{stepped});

    try fb.return_(&.{it.result(0)});
    try fb.finish();
    return try builder.finish();
}

fn inventory() []const []const u8 {
    comptime {
        @setEvalBranchQuota(20000);
        var names: []const []const u8 = &.{};
        for (@typeInfo(AccyDialect).@"struct".decl_names) |decl_name| {
            if (@TypeOf(@field(AccyDialect, decl_name)) != type) continue;
            const Op = @field(AccyDialect, decl_name);
            if (@typeInfo(Op) != .@"struct") continue;
            if (!@hasDecl(Op, "operation_name")) continue;
            names = names ++ &[_][]const u8{Op.operation_name};
        }
        return names;
    }
}

const BinaryKind = enum { add, sub, mul, div, max, min, pow, atan2 };
const UnaryKind = enum { neg, exp, log, sqrt, tanh, abs, sin, cos, tan, floor, round, trunc };
const ReduceKind = enum { sum, max, min };

fn binaryModule(comptime kind: BinaryKind) BuildFn {
    return binaryModuleTyped(.f32, kind);
}

fn binaryModuleTyped(comptime dtype: gpu_abi.DType, comptime kind: BinaryKind) BuildFn {
    return struct {
        fn build(allocator: std.mem.Allocator) anyerror!*SemanticModule {
            var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
            errdefer builder.deinit();
            const vec_ty = try builder.tensor(dtype, &.{8});
            var fb = try builder.beginFunction(
                "coverage_" ++ @tagName(kind),
                &.{ vec_ty, vec_ty },
                &.{vec_ty},
            );
            const lhs = fb.parameter(0);
            const rhs = fb.parameter(1);
            const out = switch (kind) {
                .add => try fb.add(lhs, rhs),
                .sub => try fb.sub(lhs, rhs),
                .mul => try fb.mul(lhs, rhs),
                .div => try fb.div(lhs, rhs),
                .max => try fb.max(lhs, rhs),
                .min => try fb.min(lhs, rhs),
                .pow => try fb.pow(lhs, rhs),
                .atan2 => try fb.atan2(lhs, rhs),
            };
            try fb.return_(&.{out});
            try fb.finish();
            return try builder.finish();
        }
    }.build;
}

fn unaryModule(comptime kind: UnaryKind) BuildFn {
    return unaryModuleTyped(.f32, kind);
}

fn unaryModuleTyped(comptime dtype: gpu_abi.DType, comptime kind: UnaryKind) BuildFn {
    return struct {
        fn build(allocator: std.mem.Allocator) anyerror!*SemanticModule {
            var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
            errdefer builder.deinit();
            const vec_ty = try builder.tensor(dtype, &.{8});
            var fb = try builder.beginFunction(
                "coverage_" ++ @tagName(kind),
                &.{vec_ty},
                &.{vec_ty},
            );
            const out = switch (kind) {
                .neg => try fb.neg(fb.parameter(0)),
                .exp => try fb.exp(fb.parameter(0)),
                .log => try fb.log(fb.parameter(0)),
                .sqrt => try fb.sqrt(fb.parameter(0)),
                .tanh => try fb.tanh(fb.parameter(0)),
                .abs => try fb.abs(fb.parameter(0)),
                .sin => try fb.sin(fb.parameter(0)),
                .cos => try fb.cos(fb.parameter(0)),
                .tan => try fb.tan(fb.parameter(0)),
                .floor => try fb.floor(fb.parameter(0)),
                .round => try fb.round(fb.parameter(0)),
                .trunc => try fb.trunc(fb.parameter(0)),
            };
            try fb.return_(&.{out});
            try fb.finish();
            return try builder.finish();
        }
    }.build;
}

fn einsumModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 3, 4 });
    const rhs_ty = try builder.tensor(.f32, &.{ 4, 5 });
    const out_ty = try builder.tensor(.f32, &.{ 3, 5 });
    var fb = try builder.beginFunction("coverage_einsum", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "ik,kj->ij");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn dotGeneralModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 3, 4 });
    const rhs_ty = try builder.tensor(.f32, &.{ 4, 5 });
    const out_ty = try builder.tensor(.f32, &.{ 3, 5 });
    var fb = try builder.beginFunction("coverage_dot_general", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.dotGeneral(fb.parameter(0), fb.parameter(1), out_ty, &.{1}, &.{0}, &.{}, &.{});
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn broadcastInDimModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{ 2, 4 });
    var fb = try builder.beginFunction("coverage_broadcast_in_dim", &.{ vec_ty, out_ty }, &.{out_ty});
    const widened = try fb.broadcastInDim(fb.parameter(0), out_ty, &.{ 2, 4 }, &.{1});
    const out = try fb.add(widened, fb.parameter(1));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn reshapeModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const out_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("coverage_reshape", &.{ in_ty, out_ty }, &.{out_ty});
    const reshaped = try fb.reshape(fb.parameter(0), out_ty, &.{8});
    const out = try fb.add(reshaped, fb.parameter(1));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn transposeModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const out_ty = try builder.tensor(.f32, &.{ 4, 2 });
    var fb = try builder.beginFunction("coverage_transpose", &.{ in_ty, out_ty }, &.{out_ty});
    const transposed = try fb.transpose(fb.parameter(0), out_ty, &.{ 1, 0 });
    const out = try fb.add(transposed, fb.parameter(1));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn compareSelectModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    const pred_ty = try builder.tensor(.i1, &.{8});
    var fb = try builder.beginFunction("coverage_compare_select", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const pred = try fb.compare(fb.parameter(0), fb.parameter(1), pred_ty, .lt);
    const out = try fb.select(pred, fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn compareMaskModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    const pred_ty = try builder.tensor(.i1, &.{8});
    var fb = try builder.beginFunction("coverage_compare_mask", &.{ vec_ty, vec_ty }, &.{pred_ty});
    const out = try fb.compare(fb.parameter(0), fb.parameter(1), pred_ty, .lt);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn selectMaskModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    const pred_ty = try builder.tensor(.i1, &.{8});
    var fb = try builder.beginFunction("coverage_select_mask", &.{ pred_ty, vec_ty, vec_ty }, &.{vec_ty});
    const out = try fb.select(fb.parameter(0), fb.parameter(1), fb.parameter(2));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn convertModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{8});
    const out_ty = try builder.tensor(.i32, &.{8});
    var fb = try builder.beginFunction("coverage_convert", &.{in_ty}, &.{out_ty});
    const out = try fb.convert(fb.parameter(0), out_ty, .i32);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn iotaModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("coverage_iota", &.{vec_ty}, &.{vec_ty});
    const ramp = try fb.iota(vec_ty, 0);
    const out = try fb.add(ramp, fb.parameter(0));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn constantModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("coverage_constant", &.{vec_ty}, &.{vec_ty});
    const values = [_]f32{ 1.0, -2.0, 0.5, 4.0 };
    const fixed = try fb.constant(vec_ty, std.mem.sliceAsBytes(values[0..]));
    const out = try fb.add(fixed, fb.parameter(0));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn activationModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("coverage_activation", &.{vec_ty}, &.{vec_ty});
    const out = try fb.activation(fb.parameter(0), .gelu);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn reduceModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const init_ty = try builder.tensor(.f32, &.{});
    const out_ty = try builder.tensor(.f32, &.{2});
    var fb = try builder.beginFunction("coverage_reduce", &.{in_ty}, &.{out_ty});
    const zero = [_]f32{0.0};
    const init = try fb.constant(init_ty, std.mem.sliceAsBytes(zero[0..]));
    const out = try fb.reduce(fb.parameter(0), init, out_ty, "sum", &.{1});
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn reduceParameterInitModuleTyped(comptime dtype: gpu_abi.DType, comptime kind: ReduceKind) BuildFn {
    return struct {
        fn build(allocator: std.mem.Allocator) anyerror!*SemanticModule {
            var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
            errdefer builder.deinit();
            const in_ty = try builder.tensor(dtype, &.{ 2, 4 });
            const init_ty = try builder.tensor(dtype, &.{});
            const out_ty = try builder.tensor(dtype, &.{2});
            var fb = try builder.beginFunction(
                "coverage_reduce_param_init_" ++ @tagName(dtype) ++ "_" ++ @tagName(kind),
                &.{ in_ty, init_ty },
                &.{out_ty},
            );
            const out = try fb.reduce(fb.parameter(0), fb.parameter(1), out_ty, @tagName(kind), &.{1});
            try fb.return_(&.{out});
            try fb.finish();
            return try builder.finish();
        }
    }.build;
}

fn broadcastModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{ 2, 4 });
    var fb = try builder.beginFunction("coverage_broadcast", &.{ vec_ty, out_ty }, &.{out_ty});
    const widened = try fb.broadcast(fb.parameter(0), out_ty, &.{2});
    const out = try fb.add(widened, fb.parameter(1));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn sliceModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{8});
    const out_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("coverage_slice", &.{ in_ty, out_ty }, &.{out_ty});
    const taken = try fb.slice(fb.parameter(0), out_ty, &.{0}, &.{8}, &.{2});
    const out = try fb.add(taken, fb.parameter(1));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn gatherModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{8});
    const indices_ty = try builder.tensor(.i32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("coverage_gather", &.{ in_ty, indices_ty }, &.{out_ty});
    const out = try fb.gather(fb.parameter(0), fb.parameter(1), out_ty, 0);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn scatterModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{8});
    const indices_ty = try builder.tensor(.i32, &.{4});
    const updates_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("coverage_scatter", &.{ in_ty, indices_ty, updates_ty }, &.{in_ty});
    const out = try fb.scatter(fb.parameter(0), fb.parameter(1), fb.parameter(2), in_ty, 0);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn scatterAddModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 8, 3 });
    const indices_ty = try builder.tensor(.i32, &.{5});
    const updates_ty = try builder.tensor(.f32, &.{ 2, 5, 3 });
    var fb = try builder.beginFunction("coverage_scatter_add", &.{ in_ty, indices_ty, updates_ty }, &.{in_ty});
    const out = try fb.scatterAdd(fb.parameter(0), fb.parameter(1), fb.parameter(2), in_ty, 1);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn scatterAddLowers(allocator: std.mem.Allocator) anyerror!void {
    const module = try scatterAddModule(allocator);
    defer module.deinit();

    var options = indexing_lowering.Options{
        .kernel_library = .enabled,
        .scatter_add_schedule = .{ .thread_blocks = 16 },
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(indexing_lowering.indexingLoweringPassWithOptions(&options));

    try std.testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try std.testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, AccyDialect.ScatterAddOp.operation_name));
    try std.testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, AccyDialect.KernelCallOp.operation_name));
}

fn sparseCrossEntropyModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const logits_ty = try builder.tensor(.f32, &.{ 6, 11 });
    const targets_ty = try builder.tensor(.i32, &.{6});
    const losses_ty = try builder.tensor(.f32, &.{6});
    var fb = try builder.beginFunction("coverage_sparse_cross_entropy", &.{ logits_ty, targets_ty }, &.{losses_ty});
    const out = try fb.sparseCrossEntropy(fb.parameter(0), fb.parameter(1), losses_ty);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn sparseCrossEntropyLowers(allocator: std.mem.Allocator) anyerror!void {
    const module = try sparseCrossEntropyModule(allocator);
    defer module.deinit();

    var options = loss_lowering.Options{
        .kernel_library = .enabled,
        .row_sparse_cross_entropy_schedule = .{ .thread_blocks = 4 },
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(loss_lowering.lossLoweringPassWithOptions(&options));

    try std.testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try std.testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, AccyDialect.SparseCrossEntropyOp.operation_name));
    try std.testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, AccyDialect.KernelCallOp.operation_name));
}

fn padModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{4});
    const fill_ty = try builder.tensor(.f32, &.{});
    const out_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("coverage_pad", &.{ in_ty, fill_ty }, &.{out_ty});
    const out = try fb.pad(fb.parameter(0), fb.parameter(1), out_ty, &.{2}, &.{2}, &.{0});
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn concatenateModule(allocator: std.mem.Allocator) anyerror!*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("coverage_concatenate", &.{ vec_ty, vec_ty }, &.{out_ty});
    const out = try fb.concatenate(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, 0);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn kernelCallLowers(allocator: std.mem.Allocator) anyerror!void {
    const elementwise = kernel_library.elementwise;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var call_artifact = try elementwise.VectorAdd8F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = .testing });
    defer call_artifact.deinit();

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("coverage_kernel_call", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const call = try fb.kernelCall(&.{ fb.parameter(0), fb.parameter(1) }, &.{vec_ty}, .{
        .target = elementwise.VectorAdd8F32.target,
        .operand_effects = &.{ .read, .read },
        .result_aliases = &.{null},
    });
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();
    if (fragment.kernelCount() < 1) return error.CoverageExpectedKernel;
}

test "preparation coverage table is a bijection with the dialect inventory" {
    const operations = comptime inventory();
    try std.testing.expectEqual(operations.len, table.len);
    inline for (operations) |operation| {
        var matches: usize = 0;
        for (table) |entry| {
            if (std.mem.eql(u8, entry.operation, operation)) matches += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
}

const Target = struct {
    kind: gpu.BackendKind,
    format: gpu.ArtifactFormat,
};

const Gap = struct {
    operation: []const u8,
    format: gpu.ArtifactFormat,
};

const DtypeCase = struct {
    name: []const u8,
    build: BuildFn,
};

const dtype_cases = [_]DtypeCase{
    .{ .name = "i1 compare mask", .build = compareMaskModule },
    .{ .name = "i1 select mask", .build = selectMaskModule },
    .{ .name = "f32 reduce sum parameter init", .build = reduceParameterInitModuleTyped(.f32, .sum) },
    .{ .name = "f32 reduce max parameter init", .build = reduceParameterInitModuleTyped(.f32, .max) },
    .{ .name = "f32 reduce min parameter init", .build = reduceParameterInitModuleTyped(.f32, .min) },
    .{ .name = "i32 reduce sum parameter init", .build = reduceParameterInitModuleTyped(.i32, .sum) },
    .{ .name = "i32 reduce max parameter init", .build = reduceParameterInitModuleTyped(.i32, .max) },
    .{ .name = "i32 reduce min parameter init", .build = reduceParameterInitModuleTyped(.i32, .min) },
    .{ .name = "f16 reduce sum parameter init", .build = reduceParameterInitModuleTyped(.f16, .sum) },
    .{ .name = "f16 reduce max parameter init", .build = reduceParameterInitModuleTyped(.f16, .max) },
    .{ .name = "f16 reduce min parameter init", .build = reduceParameterInitModuleTyped(.f16, .min) },
    .{ .name = "i32 add", .build = binaryModuleTyped(.i32, .add) },
    .{ .name = "i32 sub", .build = binaryModuleTyped(.i32, .sub) },
    .{ .name = "i32 mul", .build = binaryModuleTyped(.i32, .mul) },
    .{ .name = "i32 div", .build = binaryModuleTyped(.i32, .div) },
    .{ .name = "i32 min", .build = binaryModuleTyped(.i32, .min) },
    .{ .name = "i32 max", .build = binaryModuleTyped(.i32, .max) },
    .{ .name = "i32 neg", .build = unaryModuleTyped(.i32, .neg) },
    .{ .name = "i32 abs", .build = unaryModuleTyped(.i32, .abs) },
    .{ .name = "f16 add", .build = binaryModuleTyped(.f16, .add) },
    .{ .name = "f16 mul", .build = binaryModuleTyped(.f16, .mul) },
    .{ .name = "f16 exp", .build = unaryModuleTyped(.f16, .exp) },
    .{ .name = "f16 tanh", .build = unaryModuleTyped(.f16, .tanh) },
    .{ .name = "f16 sqrt", .build = unaryModuleTyped(.f16, .sqrt) },
};

const DtypeGap = struct {
    name: []const u8,
    format: gpu.ArtifactFormat,
};

const dtype_known_gaps = [_]DtypeGap{};

fn isDtypeKnownGap(name: []const u8, format: gpu.ArtifactFormat) bool {
    for (dtype_known_gaps) |gap| {
        if (gap.format == format and std.mem.eql(u8, gap.name, name)) return true;
    }
    return false;
}

const known_gaps = [_]Gap{};

fn isKnownGap(operation: []const u8, format: gpu.ArtifactFormat) bool {
    for (known_gaps) |gap| {
        if (gap.format == format and std.mem.eql(u8, gap.operation, operation)) return true;
    }
    return false;
}

const targets = [_]Target{
    .{ .kind = .cuda, .format = .cuda_ptx },
    .{ .kind = .vulkan, .format = .vulkan_spirv },
    .{ .kind = .metal, .format = .metal_msl },
};

test "preparation lowers every covered operation on every recording backend" {
    const allocator = std.testing.allocator;
    for (targets) |target| {
        for (table) |entry| {
            const build = switch (entry.coverage) {
                .covered => |build| build,
                .checked => |check| {
                    if (target.format == .cuda_ptx) try check(allocator);
                    continue;
                },
                .uncovered, .structural => continue,
            };
            if (isKnownGap(entry.operation, target.format)) continue;
            var state = gpu.recording.BackendState{
                .allocator = allocator,
                .kind = target.kind,
                .format = target.format,
            };
            const module = try build(allocator);
            var fragment = compileAndLoadSemanticModule(
                allocator,
                state.handle(),
                module,
                .{},
            ) catch |err| {
                pretty.diagnostic.writeStderrText(
                    "coverage lowering failed for {s} on {t}: {t}\n",
                    .{ entry.operation, target.format, err },
                );
                return err;
            };
            defer fragment.deinit();
            try std.testing.expect(fragment.kernelCount() >= 1);
        }
    }
}

test "preparation lowers reduce with non-identity constant init" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const init_ty = try builder.tensor(.f32, &.{});
    const out_ty = try builder.tensor(.f32, &.{2});
    var fb = try builder.beginFunction("coverage_reduce_init", &.{in_ty}, &.{out_ty});
    const bias = [_]f32{5.0};
    const init = try fb.constant(init_ty, std.mem.sliceAsBytes(bias[0..]));
    const out = try fb.reduce(fb.parameter(0), init, out_ty, "sum", &.{1});
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();
    try std.testing.expect(fragment.kernelCount() >= 1);
}

test "preparation lowers integer and half dtype cases on every recording backend" {
    const allocator = std.testing.allocator;
    for (targets) |target| {
        for (dtype_cases) |case| {
            if (isDtypeKnownGap(case.name, target.format)) continue;
            var state = gpu.recording.BackendState{
                .allocator = allocator,
                .kind = target.kind,
                .format = target.format,
            };
            const module = try case.build(allocator);
            var fragment = compileAndLoadSemanticModule(
                allocator,
                state.handle(),
                module,
                .{},
            ) catch |err| {
                pretty.diagnostic.writeStderrText(
                    "dtype coverage failed for {s} on {t}: {t}\n",
                    .{ case.name, target.format, err },
                );
                return err;
            };
            defer fragment.deinit();
            try std.testing.expect(fragment.kernelCount() >= 1);
        }
    }
}
