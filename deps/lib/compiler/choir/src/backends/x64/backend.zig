const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const contract = @import("../root.zig").contract;
const artifact = @import("../root.zig").artifact;
const interface = @import("../root.zig").interface;
const machine = @import("../root.zig").machine_code;
const passes = @import("../../passes/root.zig");
const execution = @import("../execution/root.zig");
const object = @import("object.zig");
const x86_64 = @import("root.zig");
const sys = @import("sys");

const BackendError = interface.BackendError;
const Allocator = std.mem.Allocator;

const profile = sys.capabilities.current;
const executes = profile.os == .linux and profile.arch == .x86_64 and profile.pointerWidthBits() == 64;
const Runtime = execution.native.Runtime;

pub const ModuleObjectCompileOptions = struct {
    max_threads: usize = 1,
    worker_allocator: ?Allocator = null,
    verification_diagnostic: ?*contract.VerificationDiagnostic = null,
};

/// Lowers Choir modules for x86_64 and compiles them into machine-code artifacts or object files.
/// `execution.native.Runtime` runs them.
pub const Backend = struct {
    allocator: Allocator,
    ctx: *ir.Context,

    /// Loads the arith dialect, failing with `error.OutOfMemory` when that cannot allocate.
    pub fn init(allocator: Allocator, ctx: *ir.Context) Allocator.Error!Backend {
        try contract.loadArithDialect(ctx);
        return .{ .allocator = allocator, .ctx = ctx };
    }

    pub fn deinit(self: *Backend) void {
        self.* = undefined;
    }

    pub fn verify(self: *Backend, module: *ir.Operation) BackendError!void {
        return self.verifyWithDiagnostic(module, null);
    }

    pub fn verifyWithDiagnostic(
        self: *Backend,
        module: *ir.Operation,
        diagnostic: ?*contract.VerificationDiagnostic,
    ) BackendError!void {
        _ = self;
        return contract.verifyModuleWithDiagnostic(verify_stage, module, diagnostic);
    }

    /// The operations `lower` may add for each operation of the module it is
    /// given.
    ///
    /// A CALLER SIZES A CONTEXT FROM THIS AND NOT FROM A CORPUS. `lower` runs
    /// transforms that build operations, and the operations they build are
    /// charged to the context the module lives in, so a caller that reserves
    /// bytes for that context needs a figure it can read before it lowers
    /// anything. This is that figure, and it is the sum of what each transform
    /// `lower` runs declares for itself.
    ///
    /// Only promotion adds operations today. `legalizeMemrefViews` rewrites the
    /// views an operation names and adds none, so it contributes nothing here.
    /// A transform that starts adding operations adds its own declared figure
    /// to this sum, and a caller reading this sees the change without reading
    /// this file.
    pub const operations_added_per_operation: usize =
        passes.promotion.operations_created_per_operation;

    pub fn lower(self: *Backend, module: *ir.Operation) BackendError!*ir.Operation {
        return self.lowerWithDiagnostic(module, null);
    }

    pub fn lowerWithDiagnostic(
        self: *Backend,
        module: *ir.Operation,
        diagnostic: ?*contract.VerificationDiagnostic,
    ) BackendError!*ir.Operation {
        return lowerModule(self.allocator, module, diagnostic);
    }

    pub fn compileFunctionToMachineCodeWithRelocations(
        self: *Backend,
        module: *ir.Operation,
        function_name: []const u8,
    ) BackendError!machine.MachineCode {
        const lowered = try self.lower(module);
        const func = ir.inspection.functionDefinitionByName(lowered, function_name) orelse return BackendError.FunctionNotFound;
        return try object.emitFunctionMachineCode(self.allocator, func);
    }

    pub fn compileFunctionToArtifact(
        self: *Backend,
        module: *ir.Operation,
        function_name: []const u8,
    ) BackendError!artifact.Artifact {
        const lowered = try self.lower(module);
        const func = ir.inspection.functionDefinitionByName(lowered, function_name) orelse return BackendError.FunctionNotFound;
        return try object.compileFunctionToArtifact(self.allocator, func, function_name);
    }

    pub fn compileFunctionToObjectFile(
        self: *Backend,
        module: *ir.Operation,
        function_name: []const u8,
    ) BackendError!artifact.Artifact {
        const lowered = try self.lower(module);
        const func = ir.inspection.functionDefinitionByName(lowered, function_name) orelse return BackendError.FunctionNotFound;
        return try object.compileFunctionToObjectFile(self.allocator, func, function_name);
    }

    pub fn compileModuleToObjectFile(
        self: *Backend,
        module: *ir.Operation,
        entry_name: []const u8,
    ) BackendError!artifact.Artifact {
        return try self.compileModuleToObjectFileWithOptions(module, entry_name, .{});
    }

    pub fn compileModuleToObjectFileWithOptions(
        self: *Backend,
        module: *ir.Operation,
        entry_name: []const u8,
        options: ModuleObjectCompileOptions,
    ) BackendError!artifact.Artifact {
        const lowered = try self.lowerWithDiagnostic(module, options.verification_diagnostic);
        return try object.compileModuleToObjectFile(self.allocator, lowered, entry_name, .{
            .max_threads = options.max_threads,
            .worker_allocator = options.worker_allocator,
        });
    }

    /// Writes the raw machine code of one function.
    /// Raw bytes carry no relocations, so a function that calls or references a symbol fails.
    pub fn emit(
        self: *Backend,
        module: *ir.Operation,
        options: interface.EmitOptions,
        writer: *std.Io.Writer,
    ) BackendError!void {
        const entry = options.entry orelse return BackendError.FunctionNotFound;
        const lowered = try self.lower(module);
        const func = ir.inspection.functionDefinitionByName(lowered, entry) orelse
            return BackendError.FunctionNotFound;
        var machine_code = try object.emitFunctionMachineCode(self.allocator, func);
        defer machine_code.deinit(self.allocator);
        if (machine_code.relocations.len != 0) return BackendError.UnsupportedOperation;
        if (machine_code.data_relocations.len != 0) return BackendError.UnsupportedOperation;
        writer.writeAll(machine_code.code) catch return BackendError.CodeGenFailed;
    }
};

const verify_stage = "backend/x86_64/verify";

/// Legalizes memref views, promotes, verifies and checks x86_64 legality, in that order. Both
/// `Backend` and the execution target lower through this one sequence.
pub fn lowerModule(
    allocator: Allocator,
    module: *ir.Operation,
    diagnostic: ?*contract.VerificationDiagnostic,
) BackendError!*ir.Operation {
    passes.memref_views.legalizeMemrefViews(module, allocator) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        else => return BackendError.CodeGenFailed,
    };
    _ = passes.promotion.promote(module, allocator) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        error.InvalidPromotion => return BackendError.CodeGenFailed,
    };
    try contract.verifyModuleWithDiagnostic(verify_stage, module, diagnostic);
    try x86_64.legality.checkModule(module);
    return module;
}

pub fn initHandle(allocator: Allocator, ctx: *ir.Context) BackendError!interface.BackendHandle {
    return interface.initHandle(
        Backend,
        allocator,
        ctx,
        interface.BackendTarget.x86_64,
        "x86_64",
        .{ .artifact = .{ .machine_code = true, .object_file = true } },
    );
}

fn choirSum7(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64) callconv(.c) i64 {
    return a + b + c + d + e + f + g;
}

fn choirHandleAdd1(value: i64) callconv(.c) i64 {
    return value + 1;
}

fn choirRegallocAddFive(value: i64) callconv(.c) i64 {
    return value + 5;
}

fn choirHandleFalseWithDirtyHighBits() callconv(.c) usize {
    return 0x100;
}

test "x86_64 JIT executes generic arith.add over vec2xf64 through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 2, dialects.arith.type_names.float64)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "generic_add_vec2f64", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createFloat(&ir_ctx, loc, vec_type, 0.0);
    try entry.addOperation(zero.op);
    var lhs0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 1.0);
    try entry.addOperation(lhs0.op);
    var lhs_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lhs0.getResult(), 0);
    try entry.addOperation(lhs_lane0.op);
    var lhs1 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 2.0);
    try entry.addOperation(lhs1.op);
    var lhs = try ArithDialect.InsertOp.create(&ir_ctx, loc, lhs_lane0.getResult(), lhs1.getResult(), 1);
    try entry.addOperation(lhs.op);

    var rhs0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 10.0);
    try entry.addOperation(rhs0.op);
    var rhs_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), rhs0.getResult(), 0);
    try entry.addOperation(rhs_lane0.op);
    var rhs1 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 20.0);
    try entry.addOperation(rhs1.op);
    var rhs = try ArithDialect.InsertOp.create(&ir_ctx, loc, rhs_lane0.getResult(), rhs1.getResult(), 1);
    try entry.addOperation(rhs.op);

    const add = try ArithDialect.AddOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(add.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{add.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "generic_add_vec2f64");

    try testing.expectEqual(artifact.ScalarType.f64, result.element);
    try testing.expectEqual(@as(u8, 2), result.lanes);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 11.0))), result.bits[0]);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 22.0))), result.bits[1]);
}

test "x86_64 JIT executes vec2xf64 neg through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 2, dialects.arith.type_names.float64)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "neg_vec2f64", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createFloat(&ir_ctx, loc, vec_type, 0.0);
    try entry.addOperation(zero.op);
    var lane0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 1.5);
    try entry.addOperation(lane0.op);
    var with_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lane0.getResult(), 0);
    try entry.addOperation(with_lane0.op);
    var lane1 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, -2.25);
    try entry.addOperation(lane1.op);
    var input = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane0.getResult(), lane1.getResult(), 1);
    try entry.addOperation(input.op);

    const neg = try ArithDialect.NegOp.create(&ir_ctx, loc, input.getResult());
    try entry.addOperation(neg.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{neg.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "neg_vec2f64");

    try testing.expectEqual(artifact.ScalarType.f64, result.element);
    try testing.expectEqual(@as(u8, 2), result.lanes);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -1.5))), result.bits[0]);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 2.25))), result.bits[1]);
}

test "x86_64 JIT executes vec2xf64 splat and shuffle through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 2, dialects.arith.type_names.float64)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "splat_shuffle_vec2f64", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var fill = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 4.0);
    try entry.addOperation(fill.op);
    var splat = try ArithDialect.SplatOp.create(&ir_ctx, loc, fill.getResult(), vec_type);
    try entry.addOperation(splat.op);
    var lane0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 1.25);
    try entry.addOperation(lane0.op);
    var input = try ArithDialect.InsertOp.create(&ir_ctx, loc, splat.getResult(), lane0.getResult(), 0);
    try entry.addOperation(input.op);
    const indices = [_]i64{ 1, 0 };
    const shuffle = try ArithDialect.VecShuffleOp.create(&ir_ctx, loc, input.getResult(), vec_type, indices[0..]);
    try entry.addOperation(shuffle.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{shuffle.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "splat_shuffle_vec2f64");

    try testing.expectEqual(artifact.ScalarType.f64, result.element);
    try testing.expectEqual(@as(u8, 2), result.lanes);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 4.0))), result.bits[0]);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.25))), result.bits[1]);
}

test "x86_64 JIT executes vec4xf32 through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.float32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "packed_vec4f32", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createFloat(&ir_ctx, loc, vec_type, 0.0);
    try entry.addOperation(zero.op);
    var lane0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 1.0);
    try entry.addOperation(lane0.op);
    var with_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lane0.getResult(), 0);
    try entry.addOperation(with_lane0.op);
    var lane1 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 2.0);
    try entry.addOperation(lane1.op);
    var with_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane0.getResult(), lane1.getResult(), 1);
    try entry.addOperation(with_lane1.op);
    var lane2 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 3.0);
    try entry.addOperation(lane2.op);
    var with_lane2 = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane1.getResult(), lane2.getResult(), 2);
    try entry.addOperation(with_lane2.op);
    var lane3 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 4.0);
    try entry.addOperation(lane3.op);
    var input = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane2.getResult(), lane3.getResult(), 3);
    try entry.addOperation(input.op);

    var fill = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 10.0);
    try entry.addOperation(fill.op);
    var splat = try ArithDialect.SplatOp.create(&ir_ctx, loc, fill.getResult(), vec_type);
    try entry.addOperation(splat.op);
    const add = try ArithDialect.AddOp.create(&ir_ctx, loc, input.getResult(), splat.getResult());
    try entry.addOperation(add.op);
    const indices = [_]i64{ 3, 2, 1, 0 };
    const shuffle = try ArithDialect.VecShuffleOp.create(&ir_ctx, loc, add.getResult(), vec_type, indices[0..]);
    try entry.addOperation(shuffle.op);
    const neg = try ArithDialect.NegOp.create(&ir_ctx, loc, shuffle.getResult());
    try entry.addOperation(neg.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{neg.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "packed_vec4f32");

    try testing.expectEqual(artifact.ScalarType.f32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -14.0)))), result.bits[0]);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -13.0)))), result.bits[1]);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -12.0)))), result.bits[2]);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -11.0)))), result.bits[3]);
}

test "x86_64 JIT executes arith.select over vec4xu32 with scalar bool condition" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const Case = struct {
        name: []const u8,
        condition: bool,
        expected: u64,
    };
    const cases = [_]Case{
        .{ .name = "select_vec4u32_true", .condition = true, .expected = 7 },
        .{ .name = "select_vec4u32_false", .condition = false, .expected = 3 },
    };

    for (cases) |case| {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

        const loc = ir.Location.getUnknown();
        const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();

        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, case.name, &.{}, &.{vec_type});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, case.condition);
        try entry.addOperation(cond.op);
        var true_value = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 7);
        try entry.addOperation(true_value.op);
        var false_value = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 3);
        try entry.addOperation(false_value.op);
        const selected = try ArithDialect.SelectOp.create(&ir_ctx, loc, cond.getResult(), true_value.getResult(), false_value.getResult());
        try entry.addOperation(selected.op);
        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{selected.getResult()});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        const compiled = try runtime.compile(module.op);

        const result = try vectorResult(&runtime, compiled, case.name);
        try testing.expectEqual(artifact.ScalarType.u32, result.element);
        try testing.expectEqual(@as(u8, 4), result.lanes);
        try testing.expectEqual(case.expected, result.bits[0]);
        try testing.expectEqual(case.expected, result.bits[1]);
        try testing.expectEqual(case.expected, result.bits[2]);
        try testing.expectEqual(case.expected, result.bits[3]);
    }
}

test "x86_64 JIT executes arith.umulhi over vec4xu32 through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "umulhi_vec4u32", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 0xffff_ffff);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 2);
    try entry.addOperation(rhs.op);
    const high = try ArithDialect.UmulhiOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(high.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{high.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "umulhi_vec4u32");
    try testing.expectEqual(artifact.ScalarType.u32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, 1), result.bits[0]);
    try testing.expectEqual(@as(u64, 1), result.bits[1]);
    try testing.expectEqual(@as(u64, 1), result.bits[2]);
    try testing.expectEqual(@as(u64, 1), result.bits[3]);
}

test "x86_64 JIT executes arith.popcount over vec4xu32 through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "popcount_vec4u32", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var input = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 0xf0f0_00ff);
    try entry.addOperation(input.op);
    const count = try ArithDialect.PopCountOp.create(&ir_ctx, loc, input.getResult());
    try entry.addOperation(count.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{count.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "popcount_vec4u32");
    try testing.expectEqual(artifact.ScalarType.u32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, 16), result.bits[0]);
    try testing.expectEqual(@as(u64, 16), result.bits[1]);
    try testing.expectEqual(@as(u64, 16), result.bits[2]);
    try testing.expectEqual(@as(u64, 16), result.bits[3]);
}

test "x86_64 JIT executes arith.popcount over vec2xu64 through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 2, dialects.arith.type_names.uint64)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "popcount_vec2u64", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var input = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, -1);
    try entry.addOperation(input.op);
    const count = try ArithDialect.PopCountOp.create(&ir_ctx, loc, input.getResult());
    try entry.addOperation(count.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{count.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "popcount_vec2u64");
    try testing.expectEqual(artifact.ScalarType.u64, result.element);
    try testing.expectEqual(@as(u8, 2), result.lanes);
    try testing.expectEqual(@as(u64, 64), result.bits[0]);
    try testing.expectEqual(@as(u64, 64), result.bits[1]);
}

test "x86_64 JIT executes generic arith.max over vec4xu32" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "generic_max_vec4u32", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 0);
    try entry.addOperation(zero.op);
    var lhs0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x8000_0000);
    try entry.addOperation(lhs0.op);
    var lhs_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lhs0.getResult(), 0);
    try entry.addOperation(lhs_lane0.op);
    var lhs1 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 1);
    try entry.addOperation(lhs1.op);
    var lhs_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, lhs_lane0.getResult(), lhs1.getResult(), 1);
    try entry.addOperation(lhs_lane1.op);
    var lhs2 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0xffff_ffff);
    try entry.addOperation(lhs2.op);
    var lhs_lane2 = try ArithDialect.InsertOp.create(&ir_ctx, loc, lhs_lane1.getResult(), lhs2.getResult(), 2);
    try entry.addOperation(lhs_lane2.op);
    var lhs3 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 7);
    try entry.addOperation(lhs3.op);
    var lhs = try ArithDialect.InsertOp.create(&ir_ctx, loc, lhs_lane2.getResult(), lhs3.getResult(), 3);
    try entry.addOperation(lhs.op);

    var rhs0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 1);
    try entry.addOperation(rhs0.op);
    var rhs_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), rhs0.getResult(), 0);
    try entry.addOperation(rhs_lane0.op);
    var rhs1 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x8000_0000);
    try entry.addOperation(rhs1.op);
    var rhs_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, rhs_lane0.getResult(), rhs1.getResult(), 1);
    try entry.addOperation(rhs_lane1.op);
    var rhs2 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 2);
    try entry.addOperation(rhs2.op);
    var rhs_lane2 = try ArithDialect.InsertOp.create(&ir_ctx, loc, rhs_lane1.getResult(), rhs2.getResult(), 2);
    try entry.addOperation(rhs_lane2.op);
    var rhs3 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0xffff_fffe);
    try entry.addOperation(rhs3.op);
    var rhs = try ArithDialect.InsertOp.create(&ir_ctx, loc, rhs_lane2.getResult(), rhs3.getResult(), 3);
    try entry.addOperation(rhs.op);

    const maximum = try ArithDialect.MaxOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(maximum.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{maximum.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "generic_max_vec4u32");

    try testing.expectEqual(artifact.ScalarType.u32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, 0x8000_0000), result.bits[0]);
    try testing.expectEqual(@as(u64, 0x8000_0000), result.bits[1]);
    try testing.expectEqual(@as(u64, 0xffff_ffff), result.bits[2]);
    try testing.expectEqual(@as(u64, 0xffff_fffe), result.bits[3]);
}

test "x86_64 JIT executes generic arith.min over vec4xf32 with NaN lanes" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.float32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "generic_min_vec4f32_nan", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createFloat(&ir_ctx, loc, vec_type, 0.0);
    try entry.addOperation(zero.op);
    var lhs0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, std.math.nan(f32));
    try entry.addOperation(lhs0.op);
    var lhs_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lhs0.getResult(), 0);
    try entry.addOperation(lhs_lane0.op);
    var lhs1 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 5.0);
    try entry.addOperation(lhs1.op);
    var lhs_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, lhs_lane0.getResult(), lhs1.getResult(), 1);
    try entry.addOperation(lhs_lane1.op);
    var lhs2 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, -8.0);
    try entry.addOperation(lhs2.op);
    var lhs_lane2 = try ArithDialect.InsertOp.create(&ir_ctx, loc, lhs_lane1.getResult(), lhs2.getResult(), 2);
    try entry.addOperation(lhs_lane2.op);
    var lhs3 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, -5.0);
    try entry.addOperation(lhs3.op);
    var lhs = try ArithDialect.InsertOp.create(&ir_ctx, loc, lhs_lane2.getResult(), lhs3.getResult(), 3);
    try entry.addOperation(lhs.op);

    var rhs0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 5.0);
    try entry.addOperation(rhs0.op);
    var rhs_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), rhs0.getResult(), 0);
    try entry.addOperation(rhs_lane0.op);
    var rhs1 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, std.math.nan(f32));
    try entry.addOperation(rhs1.op);
    var rhs_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, rhs_lane0.getResult(), rhs1.getResult(), 1);
    try entry.addOperation(rhs_lane1.op);
    var rhs2 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, -1.0);
    try entry.addOperation(rhs2.op);
    var rhs_lane2 = try ArithDialect.InsertOp.create(&ir_ctx, loc, rhs_lane1.getResult(), rhs2.getResult(), 2);
    try entry.addOperation(rhs_lane2.op);
    var rhs3 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, -3.0);
    try entry.addOperation(rhs3.op);
    var rhs = try ArithDialect.InsertOp.create(&ir_ctx, loc, rhs_lane2.getResult(), rhs3.getResult(), 3);
    try entry.addOperation(rhs.op);

    const minimum = try ArithDialect.MinOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(minimum.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{minimum.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "generic_min_vec4f32_nan");

    try testing.expectEqual(artifact.ScalarType.f32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 5.0)))), result.bits[0]);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 5.0)))), result.bits[1]);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -8.0)))), result.bits[2]);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -5.0)))), result.bits[3]);
}

test "x86_64 JIT executes vec4xu32 splat through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "splat_vec4u32", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var fill = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x8000_0003);
    try entry.addOperation(fill.op);
    var splat = try ArithDialect.SplatOp.create(&ir_ctx, loc, fill.getResult(), vec_type);
    try entry.addOperation(splat.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{splat.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "splat_vec4u32");

    try testing.expectEqual(artifact.ScalarType.u32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, 0x8000_0003), result.bits[0]);
    try testing.expectEqual(@as(u64, 0x8000_0003), result.bits[1]);
    try testing.expectEqual(@as(u64, 0x8000_0003), result.bits[2]);
    try testing.expectEqual(@as(u64, 0x8000_0003), result.bits[3]);
}

test "x86_64 JIT executes vec4xu32 shuffle through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "shuffle_vec4u32", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 0);
    try entry.addOperation(zero.op);
    var lane0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x8000_0000);
    try entry.addOperation(lane0.op);
    var with_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lane0.getResult(), 0);
    try entry.addOperation(with_lane0.op);
    var lane1 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 1);
    try entry.addOperation(lane1.op);
    var with_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane0.getResult(), lane1.getResult(), 1);
    try entry.addOperation(with_lane1.op);
    var lane2 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0xffff_ffff);
    try entry.addOperation(lane2.op);
    var with_lane2 = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane1.getResult(), lane2.getResult(), 2);
    try entry.addOperation(with_lane2.op);
    var lane3 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 7);
    try entry.addOperation(lane3.op);
    var input = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane2.getResult(), lane3.getResult(), 3);
    try entry.addOperation(input.op);

    const indices = [_]i64{ 3, 2, 1, 0 };
    const shuffle = try ArithDialect.VecShuffleOp.create(&ir_ctx, loc, input.getResult(), vec_type, indices[0..]);
    try entry.addOperation(shuffle.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{shuffle.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "shuffle_vec4u32");

    try testing.expectEqual(artifact.ScalarType.u32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, 7), result.bits[0]);
    try testing.expectEqual(@as(u64, 0xffff_ffff), result.bits[1]);
    try testing.expectEqual(@as(u64, 1), result.bits[2]);
    try testing.expectEqual(@as(u64, 0x8000_0000), result.bits[3]);
}

test "x86_64 JIT executes vec4xu32 extract through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "extract_vec4u32", &.{}, &.{u32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 0);
    try entry.addOperation(zero.op);
    var lane0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x10);
    try entry.addOperation(lane0.op);
    var with_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lane0.getResult(), 0);
    try entry.addOperation(with_lane0.op);
    var lane1 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x20);
    try entry.addOperation(lane1.op);
    var with_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane0.getResult(), lane1.getResult(), 1);
    try entry.addOperation(with_lane1.op);
    var lane2 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x1234_5678);
    try entry.addOperation(lane2.op);
    var input = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane1.getResult(), lane2.getResult(), 2);
    try entry.addOperation(input.op);
    const extract = try ArithDialect.ExtractOp.create(&ir_ctx, loc, input.getResult(), 2, u32_type);
    try entry.addOperation(extract.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{extract.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "extract_vec4u32", &.{});
    try testing.expectEqual(@as(i64, 0x1234_5678), try integerOf(exec_result));
}

test "x86_64 JIT executes generic arith.neg over vec4xu32 through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "generic_neg_vec4u32", &.{}, &.{vec_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try ArithDialect.VecConstantOp.createInt(&ir_ctx, loc, vec_type, 0);
    try entry.addOperation(zero.op);
    var lane0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x8000_0000);
    try entry.addOperation(lane0.op);
    var with_lane0 = try ArithDialect.InsertOp.create(&ir_ctx, loc, zero.getResult(), lane0.getResult(), 0);
    try entry.addOperation(with_lane0.op);
    var lane1 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 1);
    try entry.addOperation(lane1.op);
    var with_lane1 = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane0.getResult(), lane1.getResult(), 1);
    try entry.addOperation(with_lane1.op);
    var lane2 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0xffff_ffff);
    try entry.addOperation(lane2.op);
    var with_lane2 = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane1.getResult(), lane2.getResult(), 2);
    try entry.addOperation(with_lane2.op);
    var lane3 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 7);
    try entry.addOperation(lane3.op);
    var input = try ArithDialect.InsertOp.create(&ir_ctx, loc, with_lane2.getResult(), lane3.getResult(), 3);
    try entry.addOperation(input.op);

    const neg = try ArithDialect.NegOp.create(&ir_ctx, loc, input.getResult());
    try entry.addOperation(neg.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{neg.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const result = try vectorResult(&runtime, compiled, "generic_neg_vec4u32");

    try testing.expectEqual(artifact.ScalarType.u32, result.element);
    try testing.expectEqual(@as(u8, 4), result.lanes);
    try testing.expectEqual(@as(u64, 0x8000_0000), result.bits[0]);
    try testing.expectEqual(@as(u64, 0xffff_ffff), result.bits[1]);
    try testing.expectEqual(@as(u64, 1), result.bits[2]);
    try testing.expectEqual(@as(u64, 0xffff_fff9), result.bits[3]);
}

test "x86_64 JIT executes vec4xf32 memref add through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.float32)).?;
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, f32_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "memref_vec4f32_add", &.{ memref_type, memref_type, memref_type }, &.{});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var idx0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(idx0.op);

    var lhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(1), idx0.getResult(), vec_type);
    try entry.addOperation(lhs.op);
    var rhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(2), idx0.getResult(), vec_type);
    try entry.addOperation(rhs.op);
    const add = try ArithDialect.AddOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(add.op);
    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, add.getResult(), func.getArgument(0), idx0.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    var dst = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    var lhs_data = [_]f32{ 1.0, -2.5, 3.25, 10.0 };
    var rhs_data = [_]f32{ 4.0, 2.0, -1.25, -11.5 };

    try runtime.call(compiled, "memref_vec4f32_add", &.{
        .{ .memref = @intFromPtr(&dst[0]) },
        .{ .memref = @intFromPtr(&lhs_data[0]) },
        .{ .memref = @intFromPtr(&rhs_data[0]) },
    }, &.{});

    try testing.expectApproxEqAbs(@as(f32, 5.0), dst[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), dst[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), dst[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.5), dst[3], 1e-6);
}

test "x86_64 JIT executes vec4xu32 memref add through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 4, dialects.arith.type_names.uint32)).?;
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, u32_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "memref_vec4u32_add", &.{ memref_type, memref_type, memref_type }, &.{});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var idx0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(idx0.op);

    var lhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(1), idx0.getResult(), vec_type);
    try entry.addOperation(lhs.op);
    var rhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(2), idx0.getResult(), vec_type);
    try entry.addOperation(rhs.op);
    const add = try ArithDialect.AddOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(add.op);
    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, add.getResult(), func.getArgument(0), idx0.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    var dst = [_]u32{ 0, 0, 0, 0 };
    var lhs_data = [_]u32{ 1, 0x8000_0000, 0xffff_ffff, 7 };
    var rhs_data = [_]u32{ 4, 0x8000_0000, 2, 0xffff_fffe };

    try runtime.call(compiled, "memref_vec4u32_add", &.{
        .{ .memref = @intFromPtr(&dst[0]) },
        .{ .memref = @intFromPtr(&lhs_data[0]) },
        .{ .memref = @intFromPtr(&rhs_data[0]) },
    }, &.{});

    try testing.expectEqualSlices(u32, &.{ 5, 0, 1, 5 }, dst[0..]);
}

test "x86_64 JIT executes vec2xf64 memref add through native packed path" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const vec_type = (try ArithDialect.getVecType(&ir_ctx, 2, dialects.arith.type_names.float64)).?;
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, f64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "memref_vec2f64_add", &.{ memref_type, memref_type, memref_type }, &.{});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var idx0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(idx0.op);

    var lhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(1), idx0.getResult(), vec_type);
    try entry.addOperation(lhs.op);
    var rhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(2), idx0.getResult(), vec_type);
    try entry.addOperation(rhs.op);
    const add = try ArithDialect.AddOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(add.op);
    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, add.getResult(), func.getArgument(0), idx0.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    var dst = [_]f64{ 0.0, 0.0 };
    var lhs_data = [_]f64{ 1.25, -3.5 };
    var rhs_data = [_]f64{ 2.75, 1.0 };

    try runtime.call(compiled, "memref_vec2f64_add", &.{
        .{ .memref = @intFromPtr(&dst[0]) },
        .{ .memref = @intFromPtr(&lhs_data[0]) },
        .{ .memref = @intFromPtr(&rhs_data[0]) },
    }, &.{});

    try testing.expectApproxEqAbs(@as(f64, 4.0), dst[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -2.5), dst[1], 1e-12);
}

test "x86_64 external call passes stack args with aligned call frame" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const sum7_decl = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        loc,
        "choir_sum7",
        &.{ i64_type, i64_type, i64_type, i64_type, i64_type, i64_type, i64_type },
        &.{i64_type},
    );
    try module_block.addOperation(sum7_decl.op);

    var func = try FuncDialect.FuncOp.create(
        &ir_ctx,
        loc,
        "main",
        &.{},
        &.{i64_type},
    );
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c1 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(c1.op);
    var c2 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 2);
    try entry.addOperation(c2.op);
    var c3 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 3);
    try entry.addOperation(c3.op);
    var c4 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 4);
    try entry.addOperation(c4.op);
    var c5 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 5);
    try entry.addOperation(c5.op);
    var c6 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 6);
    try entry.addOperation(c6.op);
    var c7 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 7);
    try entry.addOperation(c7.op);

    var call_op = try FuncDialect.CallOp.create(
        &ir_ctx,
        loc,
        "choir_sum7",
        &.{
            c1.getResult(),
            c2.getResult(),
            c3.getResult(),
            c4.getResult(),
            c5.getResult(),
            c6.getResult(),
            c7.getResult(),
        },
        &.{i64_type},
    );
    try entry.addOperation(call_op.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{call_op.getResult(0).?});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
    try testing.expectEqual(x86_64.GPR.rdi, emitter.value_locations.get(c4.getResult()).?);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();

    try runtime.registerExternalSymbol("choir_sum7", @intFromPtr(&choirSum7));
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "main", &.{});
    try testing.expectEqual(@as(i64, 28), try integerOf(exec_result));
}

test "x86_64 external call uses register homes for scalar args and results" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const decl_name = "choir_regalloc_add_five";
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        loc,
        decl_name,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(declaration.op);

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "call_regalloc_homes", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(one.op);
    var shifted = try ArithDialect.AddOp.create(&ir_ctx, loc, func.getArgument(0), one.getResult());
    try entry.addOperation(shifted.op);
    var call = try FuncDialect.CallOp.create(&ir_ctx, loc, decl_name, &.{shifted.getResult()}, &.{i64_type});
    try entry.addOperation(call.op);
    const call_result = call.getResult(0) orelse return error.TestFailure;
    var two = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 2);
    try entry.addOperation(two.op);
    var result = try ArithDialect.AddOp.create(&ir_ctx, loc, call_result, two.getResult());
    try entry.addOperation(result.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result.getResult()});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
    try testing.expect(emitter.value_locations.contains(shifted.getResult()));
    try testing.expect(emitter.value_locations.contains(call_result));

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();

    try runtime.registerExternalSymbol(decl_name, @intFromPtr(&choirRegallocAddFive));
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(
        &runtime,
        compiled,
        "call_regalloc_homes",
        &.{.{ .i64 = 10 }},
    );
    try testing.expectEqual(@as(i64, 18), try integerOf(exec_result));
}

test "x86_64 backend links externs and exposes compiled symbols" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const decl_name = "choir_handle_add1";
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        loc,
        decl_name,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(declaration.op);

    var caller = try FuncDialect.FuncOp.create(&ir_ctx, loc, "call_handle_decl", &.{}, &.{i64_type});
    try module_block.addOperation(caller.op);

    const entry = caller.getEntryBlock();
    var forty_one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 41);
    try entry.addOperation(forty_one.op);

    var call = try FuncDialect.CallOp.create(&ir_ctx, loc, decl_name, &.{forty_one.getResult()}, &.{i64_type});
    try entry.addOperation(call.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);

    var handle = try initHandle(allocator, &ir_ctx);
    defer handle.deinit();
    try testing.expect(interface.BackendTarget.x86_64.eql(handle.target));
    try testing.expect(handle.capabilities.artifact.object_file);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol(decl_name, @intFromPtr(&choirHandleAdd1));
    const compiled = try runtime.compile(module.op);

    const address = try runtime.functionAddress(compiled, "call_handle_decl");
    try testing.expect(address != 0);

    const exec_result = try onlyResult(&runtime, compiled, "call_handle_decl", &.{});
    try testing.expectEqual(@as(i64, 42), try integerOf(exec_result));
}

test "x86_64 backend materializes serialized machine code artifacts" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const ir_allocator = arena.allocator();
    var ir_ctx = try ir.Context.init(ir_allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(ir_allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const location = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, location);
    const module_block = module.getBodyBlock();
    const external_symbol = "choir_artifact_add_five";
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &ir_ctx,
        location,
        external_symbol,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(declaration.op);
    const export_symbol = "artifact_call_external";
    var function = try FuncDialect.FuncOp.create(
        &ir_ctx,
        location,
        export_symbol,
        &.{i64_type},
        &.{i64_type},
    );
    try module_block.addOperation(function.op);
    const entry = function.getEntryBlock();
    var call = try FuncDialect.CallOp.create(
        &ir_ctx,
        location,
        external_symbol,
        &.{function.getArgument(0)},
        &.{i64_type},
    );
    try entry.addOperation(call.op);
    const return_op = try FuncDialect.ReturnOp.create(&ir_ctx, location, &.{call.getResult(0).?});
    try entry.addOperation(return_op.op);

    var producer = try Backend.init(testing.allocator, &ir_ctx);
    defer producer.deinit();
    var serialized = try producer.compileFunctionToArtifact(module.op, export_symbol);
    var serialized_owned = true;
    defer if (serialized_owned) serialized.deinit();
    try testing.expectEqual(artifact.ArtifactKind.machine_code, serialized.metadata.kind);
    try testing.expect(serialized.linkage.hasProvided(export_symbol));
    try testing.expectEqual(@as(usize, 1), serialized.linkage.relocations.items.len);

    var consumer = try Runtime.init(testing.allocator, .testing);
    defer consumer.deinit();
    try consumer.registerExternalSymbol(external_symbol, @intFromPtr(&choirRegallocAddFive));
    const loaded = try consumer.loadArtifact(&serialized);
    const reloaded = try consumer.loadArtifact(&serialized);
    const address = try consumer.functionAddress(loaded, export_symbol);
    try testing.expect(address != try consumer.functionAddress(reloaded, export_symbol));

    serialized.deinit();
    serialized_owned = false;
    try consumer.release(reloaded);
    const loaded_entry: *const fn (i64) callconv(.c) i64 = @ptrFromInt(address);
    try testing.expectEqual(@as(i64, 42), loaded_entry(37));
}

test "x86_64 backend canonicalizes extern bool results" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const decl_name = "choir_handle_false_dirty";
    const declaration = try FuncDialect.FuncOp.createDeclaration(&ir_ctx, loc, decl_name, &.{}, &.{bool_type});
    try module_block.addOperation(declaration.op);

    var caller = try FuncDialect.FuncOp.create(&ir_ctx, loc, "call_dirty_bool_decl", &.{}, &.{i64_type});
    try module_block.addOperation(caller.op);

    const entry = caller.getEntryBlock();
    var call = try FuncDialect.CallOp.create(&ir_ctx, loc, decl_name, &.{}, &.{bool_type});
    try entry.addOperation(call.op);

    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, call.getResult(0).?, &.{i64_type});
    try entry.addOperation(if_op.op);

    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try if_op.getThenBlock().addOperation(one.op);
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{one.getResult()});
    try if_op.getThenBlock().addOperation(then_yield.op);

    var two = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 2);
    try if_op.getElseBlock().?.addOperation(two.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{two.getResult()});
    try if_op.getElseBlock().?.addOperation(else_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{if_op.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try runtime.registerExternalSymbol(decl_name, @intFromPtr(&choirHandleFalseWithDirtyHighBits));
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "call_dirty_bool_decl", &.{});
    try testing.expectEqual(@as(i64, 2), try integerOf(exec_result));
}

test "x86_64 register allocation preserves scf if branch homes" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "branch_regalloc", &.{bool_type}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, func.getArgument(0), &.{i64_type});
    try entry.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var then_a = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 10);
    try then_block.addOperation(then_a.op);
    var then_b = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 32);
    try then_block.addOperation(then_b.op);
    var then_sum = try ArithDialect.AddOp.create(&ir_ctx, loc, then_a.getResult(), then_b.getResult());
    try then_block.addOperation(then_sum.op);
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{then_sum.getResult()});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    var else_a = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 100);
    try else_block.addOperation(else_a.op);
    var else_b = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 23);
    try else_block.addOperation(else_b.op);
    var else_sum = try ArithDialect.AddOp.create(&ir_ctx, loc, else_a.getResult(), else_b.getResult());
    try else_block.addOperation(else_sum.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{else_sum.getResult()});
    try else_block.addOperation(else_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{if_op.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();

    const compiled = try runtime.compile(module.op);

    const true_result = try onlyResult(
        &runtime,
        compiled,
        "branch_regalloc",
        &.{.{ .bool = true }},
    );
    try testing.expectEqual(@as(i64, 42), try integerOf(true_result));

    const false_result = try onlyResult(
        &runtime,
        compiled,
        "branch_regalloc",
        &.{.{ .bool = false }},
    );
    try testing.expectEqual(@as(i64, 123), try integerOf(false_result));
}

test "x86_64 scf.if yields resolve register-home swaps" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(
        &ir_ctx,
        loc,
        "branch_swap_regalloc",
        &.{ bool_type, i64_type, i64_type, i64_type },
        &.{i64_type},
    );
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    const cond = func.getArgument(0);
    const keep = func.getArgument(1);
    const lhs = func.getArgument(2);
    const rhs = func.getArgument(3);

    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, cond, &.{ i64_type, i64_type });
    try entry.addOperation(if_op.op);

    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{ rhs, lhs });
    try if_op.getThenBlock().addOperation(then_yield.op);

    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{ lhs, rhs });
    try if_op.getElseBlock().?.addOperation(else_yield.op);

    const first = if_op.getResult(0) orelse return error.TestFailure;
    const second = if_op.getResult(1) orelse return error.TestFailure;
    var diff = try ArithDialect.SubOp.create(&ir_ctx, loc, first, second);
    try entry.addOperation(diff.op);
    var result = try ArithDialect.AddOp.create(&ir_ctx, loc, diff.getResult(), keep);
    try entry.addOperation(result.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();

    const compiled = try runtime.compile(module.op);

    const true_result = try onlyResult(&runtime, compiled, "branch_swap_regalloc", &.{
        .{ .bool = true }, .{ .i64 = 100 }, .{ .i64 = 10 }, .{ .i64 = 3 },
    });
    try testing.expectEqual(@as(i64, 93), try integerOf(true_result));

    const false_result = try onlyResult(&runtime, compiled, "branch_swap_regalloc", &.{
        .{ .bool = false }, .{ .i64 = 100 }, .{ .i64 = 10 }, .{ .i64 = 3 },
    });
    try testing.expectEqual(@as(i64, 107), try integerOf(false_result));
}

test "x86_64 scf.while zero exit spills live merge values" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    const Helpers = struct {
        fn countdownWhile(
            ctx: *ir.Context,
            loc: ir.Location,
            i64_type: ir.Type,
            entry: *ir.Block,
            initial_count: *ir.Value,
            initial_acc: *ir.Value,
        ) !ScfDialect.WhileOp {
            var while_op = try ScfDialect.WhileOp.create(ctx, loc, &.{ initial_count, initial_acc }, &.{ i64_type, i64_type });
            try entry.addOperation(while_op.op);

            const before = while_op.getBeforeBlock();
            const before_count = before.arguments.items[0];
            const before_acc = before.arguments.items[1];
            var before_zero = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 0);
            try before.addOperation(before_zero.op);
            var keep_going = try ArithDialect.CmpOp.create(ctx, loc, .gt, before_count, before_zero.getResult());
            try before.addOperation(keep_going.op);
            const condition = try ScfDialect.ConditionOp.create(ctx, loc, keep_going.getResult(), &.{ before_count, before_acc });
            try before.addOperation(condition.op);

            const after = while_op.getAfterBlock();
            const after_count = after.arguments.items[0];
            const after_acc = after.arguments.items[1];
            var one = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 1);
            try after.addOperation(one.op);
            var next_count = try ArithDialect.SubOp.create(ctx, loc, after_count, one.getResult());
            try after.addOperation(next_count.op);
            var next_acc = try ArithDialect.AddOp.create(ctx, loc, after_acc, after_count);
            try after.addOperation(next_acc.op);
            const yield = try ScfDialect.YieldOp.create(ctx, loc, &.{ next_count.getResult(), next_acc.getResult() });
            try after.addOperation(yield.op);

            return while_op;
        }
    };

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var helper = try FuncDialect.FuncOp.create(&ir_ctx, loc, "while_merge_helper", &.{ i64_type, i64_type, i64_type, i64_type }, &.{i64_type});
    try module_block.addOperation(helper.op);
    const helper_entry = helper.getEntryBlock();
    var helper_sum = try ArithDialect.AddOp.create(&ir_ctx, loc, helper.getArgument(0), helper.getArgument(1));
    try helper_entry.addOperation(helper_sum.op);
    var helper_xor = try ArithDialect.XorOp.create(&ir_ctx, loc, helper.getArgument(2), helper.getArgument(3));
    try helper_entry.addOperation(helper_xor.op);
    var helper_three = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 3);
    try helper_entry.addOperation(helper_three.op);
    var helper_scaled = try ArithDialect.MulOp.create(&ir_ctx, loc, helper_sum.getResult(), helper_three.getResult());
    try helper_entry.addOperation(helper_scaled.op);
    var helper_result = try ArithDialect.SubOp.create(&ir_ctx, loc, helper_scaled.getResult(), helper_xor.getResult());
    try helper_entry.addOperation(helper_result.op);
    const helper_ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{helper_result.getResult()});
    try helper_entry.addOperation(helper_ret.op);

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "while_merge_spill", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);
    const entry = func.getEntryBlock();

    var seed = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, -32768);
    try entry.addOperation(seed.op);
    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(zero.op);
    var first_while = try Helpers.countdownWhile(&ir_ctx, loc, i64_type, entry, zero.getResult(), seed.getResult());
    var first_call = try FuncDialect.CallOp.create(&ir_ctx, loc, "while_merge_helper", &.{ seed.getResult(), seed.getResult(), first_while.op.getResult(0).?, seed.getResult() }, &.{i64_type});
    try entry.addOperation(first_call.op);
    var neg_two = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, -2);
    try entry.addOperation(neg_two.op);
    var div = try ArithDialect.DivOp.create(&ir_ctx, loc, seed.getResult(), neg_two.getResult());
    try entry.addOperation(div.op);
    var second_zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(second_zero.op);
    var second_while = try Helpers.countdownWhile(&ir_ctx, loc, i64_type, entry, second_zero.getResult(), neg_two.getResult());
    var second_call = try FuncDialect.CallOp.create(&ir_ctx, loc, "while_merge_helper", &.{ first_while.op.getResult(0).?, second_while.op.getResult(0).?, first_call.getResult(0).?, first_while.op.getResult(1).? }, &.{i64_type});
    try entry.addOperation(second_call.op);
    var salt = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, -21051);
    try entry.addOperation(salt.op);
    const min = try ArithDialect.MinOp.create(&ir_ctx, loc, seed.getResult(), second_while.op.getResult(1).?);
    try entry.addOperation(min.op);
    const cmp = try ArithDialect.CmpOp.create(&ir_ctx, loc, .ne, first_while.op.getResult(0).?, first_call.getResult(0).?);
    try entry.addOperation(cmp.op);
    var thousand = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, -1000);
    try entry.addOperation(thousand.op);
    var rem = try ArithDialect.RemOp.create(&ir_ctx, loc, second_while.op.getResult(1).?, thousand.getResult());
    try entry.addOperation(rem.op);
    var third_call = try FuncDialect.CallOp.create(&ir_ctx, loc, "while_merge_helper", &.{ second_while.op.getResult(1).?, second_call.getResult(0).?, first_call.getResult(0).?, first_while.op.getResult(1).? }, &.{i64_type});
    try entry.addOperation(third_call.op);
    var shift_count = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 42);
    try entry.addOperation(shift_count.op);
    const shifted = try ArithDialect.ShlOp.create(&ir_ctx, loc, rem.getResult(), shift_count.getResult());
    try entry.addOperation(shifted.op);
    var final_call = try FuncDialect.CallOp.create(&ir_ctx, loc, "while_merge_helper", &.{ div.getResult(), third_call.getResult(0).?, salt.getResult(), second_call.getResult(0).? }, &.{i64_type});
    try entry.addOperation(final_call.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{final_call.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();

    const compiled = try runtime.compile(module.op);
    const result = try onlyResult(&runtime, compiled, "while_merge_spill", &.{});
    try testing.expectEqual(@as(i64, -1633751), try integerOf(result));
}

test "x86_64 memref alloc returns sane pointer" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "alloc_only", &.{}, &.{memref_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var size = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 4);
    try entry.addOperation(size.op);

    var alloc = try MemrefDialect.AllocOp.createDynamic(&ir_ctx, loc, size.getResult(), memref_type);
    try entry.addOperation(alloc.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{alloc.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "alloc_only", &.{});
    const ptr_int = exec_result.memref;
    try testing.expect(ptr_int != 0);
    try testing.expect(@as(u64, @intCast(ptr_int)) > 0x10000);
    try testing.expect(@as(u64, @intCast(ptr_int)) % 8 == 0);

    sys.heap.freeAddress(@as(usize, @intCast(ptr_int)));
}

test "x86_64 memref alloc/free roundtrip" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "alloc_free", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var size = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(size.op);
    var alloc = try MemrefDialect.AllocOp.createDynamic(&ir_ctx, loc, size.getResult(), memref_type);
    try entry.addOperation(alloc.op);

    var idx0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(idx0.op);
    var value = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 77);
    try entry.addOperation(value.op);

    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, value.getResult(), alloc.getResult(), idx0.getResult());
    try entry.addOperation(store.op);
    var load = try MemrefDialect.LoadOp.create(&ir_ctx, loc, alloc.getResult(), idx0.getResult(), i64_type);
    try entry.addOperation(load.op);

    const dealloc = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc.getResult());
    try entry.addOperation(dealloc.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "alloc_free", &.{});
    try testing.expectEqual(@as(i64, 77), try integerOf(exec_result));
}

test "x86_64 memref f32 add load" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, f32_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "f32_memref_add", &.{}, &.{f32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var size = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 2);
    try entry.addOperation(size.op);
    var alloc = try MemrefDialect.AllocOp.createDynamic(&ir_ctx, loc, size.getResult(), memref_type);
    try entry.addOperation(alloc.op);

    var idx0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(idx0.op);
    var idx1 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(idx1.op);

    var v0 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 1.25);
    try entry.addOperation(v0.op);
    var v1 = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 2.75);
    try entry.addOperation(v1.op);

    const store0 = try MemrefDialect.StoreOp.create(&ir_ctx, loc, v0.getResult(), alloc.getResult(), idx0.getResult());
    try entry.addOperation(store0.op);
    const store1 = try MemrefDialect.StoreOp.create(&ir_ctx, loc, v1.getResult(), alloc.getResult(), idx1.getResult());
    try entry.addOperation(store1.op);

    var load0 = try MemrefDialect.LoadOp.create(&ir_ctx, loc, alloc.getResult(), idx0.getResult(), f32_type);
    try entry.addOperation(load0.op);
    var load1 = try MemrefDialect.LoadOp.create(&ir_ctx, loc, alloc.getResult(), idx1.getResult(), f32_type);
    try entry.addOperation(load1.op);

    var add = try ArithDialect.AddOp.create(&ir_ctx, loc, load0.getResult(), load1.getResult());
    try entry.addOperation(add.op);

    const dealloc = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc.getResult());
    try entry.addOperation(dealloc.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{add.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "f32_memref_add", &.{});
    try testing.expectApproxEqAbs(@as(f64, 4.0), try floatOf(exec_result), 1e-6);
}

test "x86_64 f32 dot product loop" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(&ir_ctx, 4, f32_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "dot_f32_loop", &.{}, &.{f32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var alloc_a = try MemrefDialect.AllocOp.createStatic(&ir_ctx, loc, memref_type);
    try entry.addOperation(alloc_a.op);
    var alloc_b = try MemrefDialect.AllocOp.createStatic(&ir_ctx, loc, memref_type);
    try entry.addOperation(alloc_b.op);

    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    for (values, 0..) |val, i| {
        var idx = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, @intCast(i));
        try entry.addOperation(idx.op);
        var fval = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, val);
        try entry.addOperation(fval.op);

        const store_a = try MemrefDialect.StoreOp.create(&ir_ctx, loc, fval.getResult(), alloc_a.getResult(), idx.getResult());
        try entry.addOperation(store_a.op);
        const store_b = try MemrefDialect.StoreOp.create(&ir_ctx, loc, fval.getResult(), alloc_b.getResult(), idx.getResult());
        try entry.addOperation(store_b.op);
    }

    var lo = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(lo.op);
    var hi = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 4);
    try entry.addOperation(hi.op);
    var step = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(step.op);
    var acc_init = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 0.0);
    try entry.addOperation(acc_init.op);

    var for_op = try ScfDialect.ForOp.create(
        &ir_ctx,
        loc,
        lo.getResult(),
        hi.getResult(),
        step.getResult(),
        &.{acc_init.getResult()},
        &.{f32_type},
    );
    try entry.addOperation(for_op.op);

    const body = for_op.getBodyBlock();
    const iv = body.arguments.items[0];
    const acc = body.arguments.items[1];

    var load_a = try MemrefDialect.LoadOp.create(&ir_ctx, loc, alloc_a.getResult(), iv, f32_type);
    try body.addOperation(load_a.op);
    var load_b = try MemrefDialect.LoadOp.create(&ir_ctx, loc, alloc_b.getResult(), iv, f32_type);
    try body.addOperation(load_b.op);

    var mul = try ArithDialect.MulOp.create(&ir_ctx, loc, load_a.getResult(), load_b.getResult());
    try body.addOperation(mul.op);
    var add = try ArithDialect.AddOp.create(&ir_ctx, loc, acc, mul.getResult());
    try body.addOperation(add.op);

    const yield_op = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{add.getResult()});
    try body.addOperation(yield_op.op);

    const dealloc_a = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc_a.getResult());
    try entry.addOperation(dealloc_a.op);
    const dealloc_b = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc_b.getResult());
    try entry.addOperation(dealloc_b.op);

    const result = for_op.getResult(0) orelse return error.TestFailure;
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "dot_f32_loop", &.{});
    try testing.expectApproxEqAbs(@as(f64, 30.0), try floatOf(exec_result), 1e-6);
}

test "x86_64 scf while carries integer values" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "while_sum", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var n_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 5);
    try entry.addOperation(n_init.op);
    var acc_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(acc_init.op);

    var while_op = try ScfDialect.WhileOp.create(
        &ir_ctx,
        loc,
        &.{ n_init.getResult(), acc_init.getResult() },
        &.{ i64_type, i64_type },
    );
    try entry.addOperation(while_op.op);

    const before = while_op.getBeforeBlock();
    const before_n = before.arguments.items[0];
    const before_acc = before.arguments.items[1];
    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try before.addOperation(zero.op);
    var keep_going = try ArithDialect.CmpOp.create(&ir_ctx, loc, .gt, before_n, zero.getResult());
    try before.addOperation(keep_going.op);
    const condition = try ScfDialect.ConditionOp.create(&ir_ctx, loc, keep_going.getResult(), &.{ before_n, before_acc });
    try before.addOperation(condition.op);

    const after = while_op.getAfterBlock();
    const after_n = after.arguments.items[0];
    const after_acc = after.arguments.items[1];
    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try after.addOperation(one.op);
    var next_n = try ArithDialect.SubOp.create(&ir_ctx, loc, after_n, one.getResult());
    try after.addOperation(next_n.op);
    var next_acc = try ArithDialect.AddOp.create(&ir_ctx, loc, after_acc, after_n);
    try after.addOperation(next_acc.op);
    const yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{ next_n.getResult(), next_acc.getResult() });
    try after.addOperation(yield.op);

    const result = while_op.op.getResult(1) orelse return error.TestFailure;
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
    try testing.expect((emitter.value_locations.get(before_n) orelse return error.TestFailure).isCallerSaved());
    try testing.expect((emitter.value_locations.get(before_acc) orelse return error.TestFailure).isCallerSaved());
    try testing.expect((emitter.value_locations.get(result) orelse return error.TestFailure).isCallerSaved());
    try testing.expectEqual(@as(usize, 0), emitter.reserved_callee_saved);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "while_sum", &.{});
    try testing.expectEqual(@as(i64, 15), try integerOf(exec_result));
}

test "x86_64 scf.while result feeds post-loop select" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "while_select", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    const pressure_seed = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, -18823);
    try entry.addOperation(pressure_seed.op);
    var true_const = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(true_const.op);
    const pressure_false = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false);
    try entry.addOperation(pressure_false.op);
    var count_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 2);
    try entry.addOperation(count_init.op);

    var while_op = try ScfDialect.WhileOp.create(
        &ir_ctx,
        loc,
        &.{ count_init.getResult(), func.getArgument(0) },
        &.{ i64_type, i64_type },
    );
    try entry.addOperation(while_op.op);

    const before = while_op.getBeforeBlock();
    const before_count = before.arguments.items[0];
    const before_acc = before.arguments.items[1];
    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try before.addOperation(zero.op);
    var keep_going = try ArithDialect.CmpOp.create(&ir_ctx, loc, .gt, before_count, zero.getResult());
    try before.addOperation(keep_going.op);
    const condition = try ScfDialect.ConditionOp.create(&ir_ctx, loc, keep_going.getResult(), &.{ before_count, before_acc });
    try before.addOperation(condition.op);

    const after = while_op.getAfterBlock();
    const after_count = after.arguments.items[0];
    const after_acc = after.arguments.items[1];
    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try after.addOperation(one.op);
    var next_count = try ArithDialect.SubOp.create(&ir_ctx, loc, after_count, one.getResult());
    try after.addOperation(next_count.op);
    var next_acc = try ArithDialect.AddOp.create(&ir_ctx, loc, after_acc, after_count);
    try after.addOperation(next_acc.op);
    const yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{ next_count.getResult(), next_acc.getResult() });
    try after.addOperation(yield.op);

    const pressure_select = try ArithDialect.SelectOp.create(&ir_ctx, loc, true_const.getResult(), func.getArgument(0), while_op.op.getResult(1).?);
    try entry.addOperation(pressure_select.op);
    const pressure_extra = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, -20440);
    try entry.addOperation(pressure_extra.op);

    var result_select = try ArithDialect.SelectOp.create(&ir_ctx, loc, true_const.getResult(), while_op.op.getResult(0).?, func.getArgument(0));
    try entry.addOperation(result_select.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_select.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "while_select", &.{.{ .i64 = -32767 }});
    try testing.expectEqual(@as(i64, 0), try integerOf(exec_result));
}

test "x86_64 register homes initialize stack-passed arguments" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const arg_types = [_]ir.Type{ i64_type, i64_type, i64_type, i64_type, i64_type, i64_type, i64_type };

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "stack_arg_home", &arg_types, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    const first_arg = func.getArgument(0);
    const stack_arg = func.getArgument(6);

    var acc = try ArithDialect.AddOp.create(&ir_ctx, loc, stack_arg, stack_arg);
    try entry.addOperation(acc.op);
    inline for (0..5) |_| {
        const next = try ArithDialect.AddOp.create(&ir_ctx, loc, acc.getResult(), stack_arg);
        try entry.addOperation(next.op);
        acc = next;
    }
    var result = try ArithDialect.AddOp.create(&ir_ctx, loc, acc.getResult(), first_arg);
    try entry.addOperation(result.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result.getResult()});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
    try testing.expect(emitter.value_locations.contains(stack_arg));

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "stack_arg_home", &.{
        .{ .i64 = 1 }, .{ .i64 = 2 }, .{ .i64 = 3 },  .{ .i64 = 4 },
        .{ .i64 = 5 }, .{ .i64 = 6 }, .{ .i64 = 11 },
    });
    try testing.expectEqual(@as(i64, 78), try integerOf(exec_result));
}

test "x86_64 scf.while preserves overlapping carried values" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "while_swap_loop", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var n_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 5);
    try entry.addOperation(n_init.op);
    var x_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 10);
    try entry.addOperation(x_init.op);
    var y_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(y_init.op);
    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(zero.op);
    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(one.op);

    var while_op = try ScfDialect.WhileOp.create(
        &ir_ctx,
        loc,
        &.{ n_init.getResult(), x_init.getResult(), y_init.getResult() },
        &.{ i64_type, i64_type, i64_type },
    );
    try entry.addOperation(while_op.op);

    const before = while_op.getBeforeBlock();
    const before_n = before.arguments.items[0];
    const before_x = before.arguments.items[1];
    const before_y = before.arguments.items[2];
    var keep_going = try ArithDialect.CmpOp.create(&ir_ctx, loc, .gt, before_n, zero.getResult());
    try before.addOperation(keep_going.op);
    const condition = try ScfDialect.ConditionOp.create(&ir_ctx, loc, keep_going.getResult(), &.{ before_n, before_x, before_y });
    try before.addOperation(condition.op);

    const after = while_op.getAfterBlock();
    const after_n = after.arguments.items[0];
    const after_x = after.arguments.items[1];
    const after_y = after.arguments.items[2];
    var next_n = try ArithDialect.SubOp.create(&ir_ctx, loc, after_n, one.getResult());
    try after.addOperation(next_n.op);
    const loop_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{ next_n.getResult(), after_y, after_x });
    try after.addOperation(loop_yield.op);

    const result_x = while_op.op.getResult(1) orelse return error.TestFailure;
    const result_y = while_op.op.getResult(2) orelse return error.TestFailure;
    var difference = try ArithDialect.SubOp.create(&ir_ctx, loc, result_x, result_y);
    try entry.addOperation(difference.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{difference.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "while_swap_loop", &.{});
    try testing.expectEqual(@as(i64, -9), try integerOf(exec_result));
}

test "x86_64 scf.while preserves high arity overlapping carried values" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "while_rotate_loop", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var n_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(n_init.op);
    var v0_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(v0_init.op);
    var v1_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 2);
    try entry.addOperation(v1_init.op);
    var v2_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 3);
    try entry.addOperation(v2_init.op);
    var v3_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 4);
    try entry.addOperation(v3_init.op);
    var v4_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 5);
    try entry.addOperation(v4_init.op);
    var v5_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 6);
    try entry.addOperation(v5_init.op);
    var v6_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 7);
    try entry.addOperation(v6_init.op);
    var v7_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 8);
    try entry.addOperation(v7_init.op);
    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(zero.op);
    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try entry.addOperation(one.op);

    var while_op = try ScfDialect.WhileOp.create(
        &ir_ctx,
        loc,
        &.{
            n_init.getResult(),
            v0_init.getResult(),
            v1_init.getResult(),
            v2_init.getResult(),
            v3_init.getResult(),
            v4_init.getResult(),
            v5_init.getResult(),
            v6_init.getResult(),
            v7_init.getResult(),
        },
        &.{
            i64_type,
            i64_type,
            i64_type,
            i64_type,
            i64_type,
            i64_type,
            i64_type,
            i64_type,
            i64_type,
        },
    );
    try entry.addOperation(while_op.op);

    const before = while_op.getBeforeBlock();
    const before_n = before.arguments.items[0];
    var keep_going = try ArithDialect.CmpOp.create(&ir_ctx, loc, .gt, before_n, zero.getResult());
    try before.addOperation(keep_going.op);
    const condition = try ScfDialect.ConditionOp.create(&ir_ctx, loc, keep_going.getResult(), &.{
        before_n,
        before.arguments.items[1],
        before.arguments.items[2],
        before.arguments.items[3],
        before.arguments.items[4],
        before.arguments.items[5],
        before.arguments.items[6],
        before.arguments.items[7],
        before.arguments.items[8],
    });
    try before.addOperation(condition.op);

    const after = while_op.getAfterBlock();
    const after_n = after.arguments.items[0];
    var next_n = try ArithDialect.SubOp.create(&ir_ctx, loc, after_n, one.getResult());
    try after.addOperation(next_n.op);
    const loop_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{
        next_n.getResult(),
        after.arguments.items[2],
        after.arguments.items[3],
        after.arguments.items[4],
        after.arguments.items[5],
        after.arguments.items[6],
        after.arguments.items[7],
        after.arguments.items[8],
        after.arguments.items[1],
    });
    try after.addOperation(loop_yield.op);

    const result_v0 = while_op.op.getResult(1) orelse return error.TestFailure;
    const result_v7 = while_op.op.getResult(8) orelse return error.TestFailure;
    var difference = try ArithDialect.SubOp.create(&ir_ctx, loc, result_v0, result_v7);
    try entry.addOperation(difference.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{difference.getResult()});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
    var uses_r11 = false;
    var homes = emitter.value_locations.iterator();
    while (homes.next()) |home_entry| {
        if (home_entry.value_ptr.* == .r11) {
            uses_r11 = true;
            break;
        }
    }
    try testing.expect(uses_r11);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "while_rotate_loop", &.{});
    try testing.expectEqual(@as(i64, 1), try integerOf(exec_result));
}

test "x86_64 memref i8 load/store" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i8_type = try ArithDialect.getScalarType(&ir_ctx, .i8);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, i8_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "i8_memref_roundtrip", &.{}, &.{i8_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var size = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(size.op);
    var alloc = try MemrefDialect.AllocOp.createDynamic(&ir_ctx, loc, size.getResult(), memref_type);
    try entry.addOperation(alloc.op);

    var idx0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(idx0.op);
    var value = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i8_type, 42);
    try entry.addOperation(value.op);

    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, value.getResult(), alloc.getResult(), idx0.getResult());
    try entry.addOperation(store.op);
    var load = try MemrefDialect.LoadOp.create(&ir_ctx, loc, alloc.getResult(), idx0.getResult(), i8_type);
    try entry.addOperation(load.op);

    const dealloc = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc.getResult());
    try entry.addOperation(dealloc.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "i8_memref_roundtrip", &.{});
    try testing.expectEqual(@as(i64, 42), try integerOf(exec_result));
}

test "x86_64 memref i16 load/store" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i16_type = try ArithDialect.getScalarType(&ir_ctx, .i16);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, i16_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "i16_memref_roundtrip", &.{}, &.{i16_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var size = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(size.op);
    var alloc = try MemrefDialect.AllocOp.createDynamic(&ir_ctx, loc, size.getResult(), memref_type);
    try entry.addOperation(alloc.op);

    var idx0 = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(idx0.op);
    var value = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i16_type, 32000);
    try entry.addOperation(value.op);

    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, value.getResult(), alloc.getResult(), idx0.getResult());
    try entry.addOperation(store.op);
    var load = try MemrefDialect.LoadOp.create(&ir_ctx, loc, alloc.getResult(), idx0.getResult(), i16_type);
    try entry.addOperation(load.op);

    const dealloc = try MemrefDialect.DeallocOp.create(&ir_ctx, loc, alloc.getResult());
    try entry.addOperation(dealloc.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{load.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "i16_memref_roundtrip", &.{});
    try testing.expectEqual(@as(i64, 32000), try integerOf(exec_result));
}

const ScalarOpKind = enum {
    neg,
    max,
    min,
    sqrt,
    abs,
    sin,
    cos,
    tan,
    exp,
    log,
    tanh,
    floor,
    pow,
    div,
    rem,
    umulhi,
    band,
    bor,
    bxor,
    bnot,
    popcount,
    shl,
    shr,
    ushr,
};

fn runIntOp(
    comptime kind: ScalarOpKind,
    int_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    name: []const u8,
    c_lhs: i64,
    c_rhs: i64,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const int_type = try ArithDialect.getScalarType(&ir_ctx, int_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{int_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_lhs);
    try entry.addOperation(lhs.op);

    const result_value = switch (kind) {
        .neg => blk: {
            const op = try ArithDialect.NegOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .abs => blk: {
            const op = try ArithDialect.AbsOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .max => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.MaxOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .min => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.MinOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .div => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.DivOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .rem => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.RemOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .umulhi => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.UmulhiOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .band => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.AndOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .bor => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.OrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .bxor => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.XorOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .bnot => blk: {
            const op = try ArithDialect.NotOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .popcount => blk: {
            const op = try ArithDialect.PopCountOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .shl => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.ShlOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .shr => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.ShrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .ushr => blk: {
            var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, int_type, c_rhs);
            try entry.addOperation(rhs.op);
            const op = try ArithDialect.UshrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .sqrt, .sin, .cos, .tan, .exp, .log, .tanh, .floor, .pow => @compileError(
            "runIntOp does not handle float-only ops — use runFloatUnaryOp / runFloatBinaryOpRaw",
        ),
    };

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec_result);
}

fn runFloatUnaryOp(
    comptime kind: ScalarOpKind,
    float_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    name: []const u8,
    c_lhs: f64,
) !f64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const float_type = try ArithDialect.getScalarType(&ir_ctx, float_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{float_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, float_type, c_lhs);
    try entry.addOperation(lhs.op);

    const result_value = switch (kind) {
        .sqrt => blk: {
            const op = try ArithDialect.SqrtOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .floor => blk: {
            const op = try ArithDialect.FloorOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .neg => blk: {
            const op = try ArithDialect.NegOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .abs => blk: {
            const op = try ArithDialect.AbsOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        else => @compileError("runFloatUnaryOp only handles .sqrt/.floor/.neg/.abs"),
    };

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, name, &.{});
    return floatOf(exec_result);
}

fn runFloatUnaryOpRaw(
    comptime kind: ScalarOpKind,
    comptime FT: type,
    name: []const u8,
    c_lhs: FT,
) !FT {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const float_kind: ArithDialect.ScalarTypeKind = comptime blk: {
        if (FT == f32) break :blk .f32;
        if (FT == f64) break :blk .f64;
        @compileError("runFloatUnaryOpRaw: FT must be f32 or f64");
    };

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const float_type = try ArithDialect.getScalarType(&ir_ctx, float_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{float_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, float_type, @floatCast(c_lhs));
    try entry.addOperation(lhs.op);

    const result_value = switch (kind) {
        .neg => blk: {
            const op = try ArithDialect.NegOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .abs => blk: {
            const op = try ArithDialect.AbsOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .sqrt => blk: {
            const op = try ArithDialect.SqrtOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .floor => blk: {
            const op = try ArithDialect.FloorOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .sin => blk: {
            const op = try ArithDialect.SinOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .cos => blk: {
            const op = try ArithDialect.CosOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .tan => blk: {
            const op = try ArithDialect.TanOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .exp => blk: {
            const op = try ArithDialect.ExpOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .log => blk: {
            const op = try ArithDialect.LogOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .tanh => blk: {
            const op = try ArithDialect.TanhOp.create(&ir_ctx, loc, lhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        else => @compileError("runFloatUnaryOpRaw only handles unary float ops"),
    };

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) FT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
}

fn runFloatBinaryOpRaw(
    comptime kind: ScalarOpKind,
    comptime FT: type,
    name: []const u8,
    c_lhs: FT,
    c_rhs: FT,
) !FT {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const float_kind: ArithDialect.ScalarTypeKind = comptime blk: {
        if (FT == f32) break :blk .f32;
        if (FT == f64) break :blk .f64;
        @compileError("runFloatBinaryOpRaw: FT must be f32 or f64");
    };

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const float_type = try ArithDialect.getScalarType(&ir_ctx, float_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{float_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, float_type, @floatCast(c_lhs));
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, float_type, @floatCast(c_rhs));
    try entry.addOperation(rhs.op);

    const result_value = switch (kind) {
        .pow => blk: {
            const op = try ArithDialect.PowOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .max => blk: {
            const op = try ArithDialect.MaxOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .min => blk: {
            const op = try ArithDialect.MinOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        else => @compileError("runFloatBinaryOpRaw only handles .pow/.max/.min"),
    };

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) FT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
}

const FloatTernaryOpKind = enum { fma };

fn runFloatTernaryOpRaw(
    comptime kind: FloatTernaryOpKind,
    comptime FT: type,
    name: []const u8,
    c_a: FT,
    c_b: FT,
    c_c: FT,
) !FT {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const float_kind: ArithDialect.ScalarTypeKind = comptime blk: {
        if (FT == f32) break :blk .f32;
        if (FT == f64) break :blk .f64;
        @compileError("runFloatTernaryOpRaw: FT must be f32 or f64");
    };

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const float_type = try ArithDialect.getScalarType(&ir_ctx, float_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{float_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var a = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, float_type, @floatCast(c_a));
    try entry.addOperation(a.op);
    var b = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, float_type, @floatCast(c_b));
    try entry.addOperation(b.op);
    var c = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, float_type, @floatCast(c_c));
    try entry.addOperation(c.op);

    const result_value = switch (kind) {
        .fma => blk: {
            const op = try ArithDialect.FmaOp.create(&ir_ctx, loc, a.getResult(), b.getResult(), c.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
    };

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) FT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
}

test "x86_64 arith.neg over i32 negates value (signed return marshalling)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -5), try runIntOp(.neg, .i32, "neg_i32_pos5", 5, 0));
    try testing.expectEqual(@as(i64, 7), try runIntOp(.neg, .i32, "neg_i32_neg7", -7, 0));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.neg, .i32, "neg_i32_zero", 0, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i32)),
        try runIntOp(.neg, .i32, "neg_i32_min", std.math.minInt(i32), 0),
    );
}

test "x86_64 arith.neg over i64 negates value (and wraps INT_MIN)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -5), try runIntOp(.neg, .i64, "neg_i64_pos", 5, 0));
    try testing.expectEqual(@as(i64, 7), try runIntOp(.neg, .i64, "neg_i64_neg", -7, 0));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.neg, .i64, "neg_i64_zero", 0, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i64)),
        try runIntOp(.neg, .i64, "neg_i64_min", std.math.minInt(i64), 0),
    );
}

test "x86_64 arith.max over i32 picks the larger operand" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 7), try runIntOp(.max, .i32, "max_i32_a", 3, 7));
    try testing.expectEqual(@as(i64, 7), try runIntOp(.max, .i32, "max_i32_b", 7, 3));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.max, .i32, "max_i32_eq", 0, 0));
    try testing.expectEqual(@as(i64, -3), try runIntOp(.max, .i32, "max_i32_neg", -5, -3));
}

test "x86_64 arith.max over i64 picks the larger operand" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try runIntOp(
        .max,
        .i64,
        "max_i64",
        std.math.minInt(i64),
        std.math.maxInt(i64),
    ));
    try testing.expectEqual(@as(i64, -3), try runIntOp(.max, .i64, "max_i64_neg", -5, -3));
}

test "x86_64 arith.min over i32 picks the smaller operand" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 3), try runIntOp(.min, .i32, "min_i32_a", 3, 7));
    try testing.expectEqual(@as(i64, 3), try runIntOp(.min, .i32, "min_i32_b", 7, 3));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.min, .i32, "min_i32_zero", 0, 5));
    try testing.expectEqual(@as(i64, -5), try runIntOp(.min, .i32, "min_i32_neg", -5, -3));
}

test "x86_64 arith.min over i64 picks the smaller operand" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try runIntOp(
        .min,
        .i64,
        "min_i64",
        std.math.minInt(i64),
        std.math.maxInt(i64),
    ));
    try testing.expectEqual(@as(i64, -5), try runIntOp(.min, .i64, "min_i64_neg", -5, -3));
}

test "x86_64 arith.div over integers returns quotient" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 3), try runIntOp(.div, .i32, "div_i32_pos", 17, 5));
    try testing.expectEqual(@as(i64, -4), try runIntOp(.div, .i64, "div_i64_neg", -21, 5));
}

test "x86_64 arith.rem over integers returns remainder" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 2), try runIntOp(.rem, .i32, "rem_i32_pos", 17, 5));
    try testing.expectEqual(@as(i64, -1), try runIntOp(.rem, .i64, "rem_i64_neg", -21, 5));
}

test "x86_64 arith.div and rem over u64 use unsigned high-bit semantics" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    const high_bit: i64 = @bitCast(@as(u64, 0x8000_0000_0000_0000));
    try testing.expectEqual(
        @as(i64, @bitCast(@as(u64, 0x4000_0000_0000_0000))),
        try runIntOp(.div, .u64, "div_u64_high_bit_2", high_bit, 2),
    );
    try testing.expectEqual(
        @as(i64, @bitCast(@as(u64, 0x7fff_ffff_ffff_ffff))),
        try runIntOp(.div, .u64, "div_u64_max_2", -1, 2),
    );
    try testing.expectEqual(@as(i64, 1), try runIntOp(.rem, .u64, "rem_u64_max_2", -1, 2));
}

test "x86_64 arith.div and rem over u32 use unsigned high-bit semantics" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0x4000_0000), try runIntOp(.div, .u32, "div_u32_high_bit_2", 0x8000_0000, 2));
    try testing.expectEqual(@as(i64, 0x7fff_ffff), try runIntOp(.div, .u32, "div_u32_max_2", 0xffff_ffff, 2));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.rem, .u32, "rem_u32_max_2", 0xffff_ffff, 2));
}

test "x86_64 arith.umulhi over integers returns unsigned high half" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 1), try runIntOp(.umulhi, .u32, "umulhi_u32_max_2", 0xffff_ffff, 2));
    try testing.expectEqual(@as(i64, 2), try runIntOp(.umulhi, .i32, "umulhi_i32_high_4", std.math.minInt(i32), 4));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.umulhi, .u64, "umulhi_u64_max_2", -1, 2));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.umulhi, .i64, "umulhi_i64_high_2", std.math.minInt(i64), 2));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.umulhi, .u8, "umulhi_u8_max_2", 0xff, 2));
    try testing.expectEqual(@as(i64, -2), try runIntOp(.umulhi, .i16, "umulhi_i16_max_max", -1, -1));
}

test "x86_64 arith.popcount over integers counts bits" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0), try runIntOp(.popcount, .i32, "popcount_i32_zero", 0, 0));
    try testing.expectEqual(@as(i64, 16), try runIntOp(.popcount, .u32, "popcount_u32_half", 0x5555_5555, 0));
    try testing.expectEqual(@as(i64, 32), try runIntOp(.popcount, .i32, "popcount_i32_full", -1, 0));
    try testing.expectEqual(@as(i64, 64), try runIntOp(.popcount, .u64, "popcount_u64_full", -1, 0));
    try testing.expectEqual(@as(i64, 8), try runIntOp(.popcount, .u8, "popcount_u8_full", 0xff, 0));
    try testing.expectEqual(@as(i64, 64), try runIntOp(.popcount, .index, "popcount_index_full", -1, 0));
}

test "x86_64 arith.neg over i8 / i16 wraps INT_MIN (movsx load path)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -7), try runIntOp(.neg, .i8, "neg_i8_pos", 7, 0));
    try testing.expectEqual(@as(i64, 50), try runIntOp(.neg, .i8, "neg_i8_neg", -50, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i8)),
        try runIntOp(.neg, .i8, "neg_i8_min", std.math.minInt(i8), 0),
    );

    try testing.expectEqual(@as(i64, -1234), try runIntOp(.neg, .i16, "neg_i16_pos", 1234, 0));
    try testing.expectEqual(@as(i64, 9999), try runIntOp(.neg, .i16, "neg_i16_neg", -9999, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i16)),
        try runIntOp(.neg, .i16, "neg_i16_min", std.math.minInt(i16), 0),
    );
}

test "x86_64 arith.max / min over i8 / i16 with negative operands" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -3), try runIntOp(.max, .i8, "max_i8_neg", -7, -3));
    try testing.expectEqual(@as(i64, -7), try runIntOp(.min, .i8, "min_i8_neg", -7, -3));
    try testing.expectEqual(@as(i64, std.math.maxInt(i8)), try runIntOp(
        .max,
        .i8,
        "max_i8_extremes",
        std.math.minInt(i8),
        std.math.maxInt(i8),
    ));

    try testing.expectEqual(@as(i64, -3), try runIntOp(.max, .i16, "max_i16_neg", -7, -3));
    try testing.expectEqual(@as(i64, -7), try runIntOp(.min, .i16, "min_i16_neg", -7, -3));
}

test "x86_64 arith.max over arith.index uses unsigned cmov (cmovb path)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const idx_type = try ArithDialect.getIndexType(&ir_ctx);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "max_index", &.{}, &.{idx_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, -1);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, 1);
    try entry.addOperation(rhs.op);
    var max_op = try ArithDialect.MaxOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(max_op.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{max_op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "max_index", &.{});
    try testing.expectEqual(@as(i64, -1), try integerOf(exec_result));
}

test "x86_64 arith.min over arith.index uses unsigned cmov (cmova path)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const idx_type = try ArithDialect.getIndexType(&ir_ctx);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "min_index", &.{}, &.{idx_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, 1);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, -1);
    try entry.addOperation(rhs.op);
    var min_op = try ArithDialect.MinOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(min_op.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{min_op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result = try onlyResult(&runtime, compiled, "min_index", &.{});
    try testing.expectEqual(@as(i64, 1), try integerOf(exec_result));
}

test "x86_64 arith.max / min over arith.index — taken cmov path (reversed operands)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    inline for (.{
        .{ .op = ScalarOpKind.max, .lhs = @as(i64, 1), .rhs = @as(i64, -1), .name = "max_idx_taken", .expected = @as(i64, -1) },
        .{ .op = ScalarOpKind.min, .lhs = @as(i64, -1), .rhs = @as(i64, 1), .name = "min_idx_taken", .expected = @as(i64, 1) },
    }) |case| {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

        const loc = ir.Location.getUnknown();
        const idx_type = try ArithDialect.getIndexType(&ir_ctx);

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();

        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, case.name, &.{}, &.{idx_type});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var lhs_op = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, case.lhs);
        try entry.addOperation(lhs_op.op);
        var rhs_op = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, case.rhs);
        try entry.addOperation(rhs_op.op);
        const result_value = switch (case.op) {
            .max => blk: {
                const op = try ArithDialect.MaxOp.create(&ir_ctx, loc, lhs_op.getResult(), rhs_op.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .min => blk: {
                const op = try ArithDialect.MinOp.create(&ir_ctx, loc, lhs_op.getResult(), rhs_op.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            else => unreachable,
        };
        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        const compiled = try runtime.compile(module.op);

        const exec_result = try onlyResult(&runtime, compiled, case.name, &.{});
        try testing.expectEqual(case.expected, try integerOf(exec_result));
    }
}

test "x86_64 arith.max and min over u64 use unsigned order" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -1), try runIntOp(.max, .u64, "max_u64_high", -1, 1));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.min, .u64, "min_u64_high", -1, 1));
}

test "x86_64 arith.max and min over u32 use unsigned order" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0x8000_0000), try runIntOp(.max, .u32, "max_u32_high", 0x8000_0000, 1));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.min, .u32, "min_u32_high", 0x8000_0000, 1));
}

test "x86_64 arith.max and min over u8 and u16 use unsigned order" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0xff), try runIntOp(.max, .u8, "max_u8_high", 0xff, 1));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.min, .u8, "min_u8_high", 0xff, 1));
    try testing.expectEqual(@as(i64, 0x8000), try runIntOp(.max, .u16, "max_u16_high", 0x8000, 1));
    try testing.expectEqual(@as(i64, 1), try runIntOp(.min, .u16, "min_u16_high", 0x8000, 1));
}

test "x86_64 arith.min over i8 INT_MIN" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, std.math.minInt(i8)), try runIntOp(
        .min,
        .i8,
        "min_i8_extremes",
        std.math.minInt(i8),
        std.math.maxInt(i8),
    ));
}

test "x86_64 arith.sqrt over f32 / f64 (sqrtss / sqrtsd)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 2.0), try runFloatUnaryOp(.sqrt, .f32, "sqrt_f32_4", 4.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try runFloatUnaryOp(.sqrt, .f32, "sqrt_f32_0", 0.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3.0), try runFloatUnaryOp(.sqrt, .f64, "sqrt_f64_9", 9.0), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4.0), try runFloatUnaryOp(.sqrt, .f64, "sqrt_f64_16", 16.0), 1e-12);
}

test "x86_64 arith.abs over signed integers (mov+neg+cmovns)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 5), try runIntOp(.abs, .i32, "abs_i32_pos", 5, 0));
    try testing.expectEqual(@as(i64, 5), try runIntOp(.abs, .i32, "abs_i32_neg", -5, 0));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.abs, .i32, "abs_i32_zero", 0, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i32)),
        try runIntOp(.abs, .i32, "abs_i32_min", std.math.minInt(i32), 0),
    );

    try testing.expectEqual(@as(i64, 1234567890), try runIntOp(.abs, .i64, "abs_i64_pos", 1234567890, 0));
    try testing.expectEqual(@as(i64, 1234567890), try runIntOp(.abs, .i64, "abs_i64_neg", -1234567890, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i64)),
        try runIntOp(.abs, .i64, "abs_i64_min", std.math.minInt(i64), 0),
    );

    try testing.expectEqual(@as(i64, 7), try runIntOp(.abs, .i8, "abs_i8_neg", -7, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i8)),
        try runIntOp(.abs, .i8, "abs_i8_min", std.math.minInt(i8), 0),
    );
    try testing.expectEqual(@as(i64, 1234), try runIntOp(.abs, .i16, "abs_i16_neg", -1234, 0));
    try testing.expectEqual(
        @as(i64, std.math.minInt(i16)),
        try runIntOp(.abs, .i16, "abs_i16_min", std.math.minInt(i16), 0),
    );
}

test "x86_64 arith.abs over u64 is identity" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    const high_bit: i64 = @bitCast(@as(u64, 0x8000_0000_0000_0000));
    try testing.expectEqual(high_bit, try runIntOp(.abs, .u64, "abs_u64_high_bit", high_bit, 0));
    try testing.expectEqual(@as(i64, -1), try runIntOp(.abs, .u64, "abs_u64_max", -1, 0));
}

test "x86_64 arith.neg over f32 (pcmpeqd + pslld + xorps sign-flip)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, -5.0), try runFloatUnaryOpRaw(.neg, f32, "neg_f32_pos", 5.0));
    try testing.expectEqual(@as(f32, 3.5), try runFloatUnaryOpRaw(.neg, f32, "neg_f32_neg", -3.5));

    const neg_pos_zero = try runFloatUnaryOpRaw(.neg, f32, "neg_f32_pzero", 0.0);
    try testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(neg_pos_zero)));
    const neg_neg_zero = try runFloatUnaryOpRaw(.neg, f32, "neg_f32_nzero", -0.0);
    try testing.expectEqual(@as(u32, 0x00000000), @as(u32, @bitCast(neg_neg_zero)));

    const neg_nan = try runFloatUnaryOpRaw(.neg, f32, "neg_f32_nan", std.math.nan(f32));
    try testing.expect(std.math.isNan(neg_nan));
}

test "x86_64 arith.neg over f64 (pcmpeqd + psllq + xorpd sign-flip)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f64, -5.0), try runFloatUnaryOpRaw(.neg, f64, "neg_f64_pos", 5.0));
    try testing.expectEqual(@as(f64, 3.5), try runFloatUnaryOpRaw(.neg, f64, "neg_f64_neg", -3.5));

    const neg_pos_zero = try runFloatUnaryOpRaw(.neg, f64, "neg_f64_pzero", 0.0);
    try testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(neg_pos_zero)));
    const neg_neg_zero = try runFloatUnaryOpRaw(.neg, f64, "neg_f64_nzero", -0.0);
    try testing.expectEqual(@as(u64, 0x0000000000000000), @as(u64, @bitCast(neg_neg_zero)));

    const neg_nan = try runFloatUnaryOpRaw(.neg, f64, "neg_f64_nan", std.math.nan(f64));
    try testing.expect(std.math.isNan(neg_nan));
}

test "x86_64 arith.abs over f32 (pcmpeqd + psrld + andps sign-clear)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 5.0), try runFloatUnaryOpRaw(.abs, f32, "abs_f32_pos", 5.0));
    try testing.expectEqual(@as(f32, 3.5), try runFloatUnaryOpRaw(.abs, f32, "abs_f32_neg", -3.5));

    const abs_neg_zero = try runFloatUnaryOpRaw(.abs, f32, "abs_f32_nzero", -0.0);
    try testing.expectEqual(@as(u32, 0x00000000), @as(u32, @bitCast(abs_neg_zero)));
    const abs_pos_zero = try runFloatUnaryOpRaw(.abs, f32, "abs_f32_pzero", 0.0);
    try testing.expectEqual(@as(u32, 0x00000000), @as(u32, @bitCast(abs_pos_zero)));

    const abs_nan = try runFloatUnaryOpRaw(.abs, f32, "abs_f32_nan", std.math.nan(f32));
    try testing.expect(std.math.isNan(abs_nan));
}

test "x86_64 arith.abs over f64 (pcmpeqd + psrlq + andpd sign-clear)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f64, 5.0), try runFloatUnaryOpRaw(.abs, f64, "abs_f64_pos", 5.0));
    try testing.expectEqual(@as(f64, 3.5), try runFloatUnaryOpRaw(.abs, f64, "abs_f64_neg", -3.5));

    const abs_neg_zero = try runFloatUnaryOpRaw(.abs, f64, "abs_f64_nzero", -0.0);
    try testing.expectEqual(@as(u64, 0x0000000000000000), @as(u64, @bitCast(abs_neg_zero)));
    const abs_pos_zero = try runFloatUnaryOpRaw(.abs, f64, "abs_f64_pzero", 0.0);
    try testing.expectEqual(@as(u64, 0x0000000000000000), @as(u64, @bitCast(abs_pos_zero)));

    const abs_nan = try runFloatUnaryOpRaw(.abs, f64, "abs_f64_nan", std.math.nan(f64));
    try testing.expect(std.math.isNan(abs_nan));
}

test "x86_64 arith.floor over f32 / f64 via libm floorf / floor" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 1.0), try runFloatUnaryOpRaw(.floor, f32, "floor_f32_pos", 1.75));
    try testing.expectEqual(@as(f32, -2.0), try runFloatUnaryOpRaw(.floor, f32, "floor_f32_neg", -1.25));
    try testing.expectEqual(@as(f64, 1.0), try runFloatUnaryOpRaw(.floor, f64, "floor_f64_pos", 1.75));
    try testing.expectEqual(@as(f64, -2.0), try runFloatUnaryOpRaw(.floor, f64, "floor_f64_neg", -1.25));
    const floor_nan = try runFloatUnaryOpRaw(.floor, f64, "floor_f64_nan", std.math.nan(f64));
    try testing.expect(std.math.isNan(floor_nan));
}

test "x86_64 arith.sin over f32 / f64 via libm sinf / sin" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        try runFloatUnaryOpRaw(.sin, f32, "sin_f32_zero", 0.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        try runFloatUnaryOpRaw(.sin, f32, "sin_f32_pi_over_2", std.math.pi / 2.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.0),
        try runFloatUnaryOpRaw(.sin, f64, "sin_f64_zero", 0.0),
        1e-12,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try runFloatUnaryOpRaw(.sin, f64, "sin_f64_pi_over_2", std.math.pi / 2.0),
        1e-12,
    );
    const sin_nan = try runFloatUnaryOpRaw(.sin, f64, "sin_f64_nan", std.math.nan(f64));
    try testing.expect(std.math.isNan(sin_nan));
}

test "x86_64 arith.cos over f32 / f64 via libm cosf / cos" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        try runFloatUnaryOpRaw(.cos, f32, "cos_f32_zero", 0.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        try runFloatUnaryOpRaw(.cos, f32, "cos_f32_pi_over_2", std.math.pi / 2.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try runFloatUnaryOpRaw(.cos, f64, "cos_f64_zero", 0.0),
        1e-12,
    );
    try testing.expectApproxEqAbs(
        @as(f64, -1.0),
        try runFloatUnaryOpRaw(.cos, f64, "cos_f64_pi", std.math.pi),
        1e-12,
    );
}

test "x86_64 arith.tan over f32 / f64 via libm tanf / tan" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        try runFloatUnaryOpRaw(.tan, f32, "tan_f32_zero", 0.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try runFloatUnaryOpRaw(.tan, f64, "tan_f64_pi_over_4", std.math.pi / 4.0),
        1e-12,
    );
}

test "x86_64 arith.exp over f32 / f64 via libm expf / exp" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        try runFloatUnaryOpRaw(.exp, f32, "exp_f32_zero", 0.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f32, std.math.e),
        try runFloatUnaryOpRaw(.exp, f32, "exp_f32_one", 1.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try runFloatUnaryOpRaw(.exp, f64, "exp_f64_zero", 0.0),
        1e-12,
    );
    try testing.expectApproxEqAbs(
        @as(f64, std.math.e),
        try runFloatUnaryOpRaw(.exp, f64, "exp_f64_one", 1.0),
        1e-12,
    );
}

test "x86_64 arith.log over f32 / f64 via libm logf / log" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        try runFloatUnaryOpRaw(.log, f32, "log_f32_one", 1.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        try runFloatUnaryOpRaw(.log, f32, "log_f32_e", std.math.e),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.0),
        try runFloatUnaryOpRaw(.log, f64, "log_f64_one", 1.0),
        1e-12,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        try runFloatUnaryOpRaw(.log, f64, "log_f64_e", std.math.e),
        1e-12,
    );
}

test "x86_64 arith.tanh over f32 / f64 via libm tanhf / tanh" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        try runFloatUnaryOpRaw(.tanh, f32, "tanh_f32_zero", 0.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f32, 1.0),
        try runFloatUnaryOpRaw(.tanh, f32, "tanh_f32_large", 20.0),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.0),
        try runFloatUnaryOpRaw(.tanh, f64, "tanh_f64_zero", 0.0),
        1e-12,
    );
    try testing.expectApproxEqAbs(
        @as(f64, -1.0),
        try runFloatUnaryOpRaw(.tanh, f64, "tanh_f64_neg_large", -20.0),
        1e-12,
    );
}

test "x86_64 arith.pow over f32 / f64 via libm powf / pow" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectApproxEqAbs(
        @as(f32, 1024.0),
        try runFloatBinaryOpRaw(.pow, f32, "pow_f32_2_10", 2.0, 10.0),
        1e-3,
    );
    try testing.expectApproxEqAbs(
        @as(f32, std.math.sqrt2),
        try runFloatBinaryOpRaw(.pow, f32, "pow_f32_2_half", 2.0, 0.5),
        1e-5,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1024.0),
        try runFloatBinaryOpRaw(.pow, f64, "pow_f64_2_10", 2.0, 10.0),
        1e-9,
    );
    try testing.expectApproxEqAbs(
        @as(f64, std.math.sqrt2),
        try runFloatBinaryOpRaw(.pow, f64, "pow_f64_2_half", 2.0, 0.5),
        1e-12,
    );
}

test "x86_64 arith.pow rejects mismatched base / exponent types" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "pow_mismatched", &.{}, &.{f32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var base = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 2.0);
    try entry.addOperation(base.op);
    var exponent = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 3.0);
    try entry.addOperation(exponent.op);
    var op = try ArithDialect.PowOp.create(&ir_ctx, loc, base.getResult(), exponent.getResult());
    try entry.addOperation(op.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.VerificationFailed, runtime.compile(module.op));
}

test "x86_64 arith.max over f32: ordered + NaN-aware contract" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 7.0), try runFloatBinaryOpRaw(.max, f32, "max_f32_ord_a", 3.0, 7.0));
    try testing.expectEqual(@as(f32, 7.0), try runFloatBinaryOpRaw(.max, f32, "max_f32_ord_b", 7.0, 3.0));
    try testing.expectEqual(@as(f32, -3.0), try runFloatBinaryOpRaw(.max, f32, "max_f32_negs", -5.0, -3.0));
    try testing.expectEqual(
        @as(f32, 5.0),
        try runFloatBinaryOpRaw(.max, f32, "max_f32_nan_lhs", std.math.nan(f32), 5.0),
    );
    try testing.expectEqual(
        @as(f32, 5.0),
        try runFloatBinaryOpRaw(.max, f32, "max_f32_nan_rhs", 5.0, std.math.nan(f32)),
    );
    const both_nan = try runFloatBinaryOpRaw(.max, f32, "max_f32_both_nan", std.math.nan(f32), std.math.nan(f32));
    try testing.expect(std.math.isNan(both_nan));
}

test "x86_64 arith.max over f64: ordered + NaN-aware contract" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f64, 7.0), try runFloatBinaryOpRaw(.max, f64, "max_f64_ord_a", 3.0, 7.0));
    try testing.expectEqual(@as(f64, 7.0), try runFloatBinaryOpRaw(.max, f64, "max_f64_ord_b", 7.0, 3.0));
    try testing.expectEqual(@as(f64, -3.0), try runFloatBinaryOpRaw(.max, f64, "max_f64_negs", -5.0, -3.0));
    try testing.expectEqual(
        @as(f64, 5.0),
        try runFloatBinaryOpRaw(.max, f64, "max_f64_nan_lhs", std.math.nan(f64), 5.0),
    );
    try testing.expectEqual(
        @as(f64, 5.0),
        try runFloatBinaryOpRaw(.max, f64, "max_f64_nan_rhs", 5.0, std.math.nan(f64)),
    );
    const both_nan = try runFloatBinaryOpRaw(.max, f64, "max_f64_both_nan", std.math.nan(f64), std.math.nan(f64));
    try testing.expect(std.math.isNan(both_nan));
}

test "x86_64 arith.min over f32: ordered + NaN-aware contract" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 3.0), try runFloatBinaryOpRaw(.min, f32, "min_f32_ord_a", 3.0, 7.0));
    try testing.expectEqual(@as(f32, 3.0), try runFloatBinaryOpRaw(.min, f32, "min_f32_ord_b", 7.0, 3.0));
    try testing.expectEqual(@as(f32, -5.0), try runFloatBinaryOpRaw(.min, f32, "min_f32_negs", -5.0, -3.0));
    try testing.expectEqual(
        @as(f32, 5.0),
        try runFloatBinaryOpRaw(.min, f32, "min_f32_nan_lhs", std.math.nan(f32), 5.0),
    );
    try testing.expectEqual(
        @as(f32, 5.0),
        try runFloatBinaryOpRaw(.min, f32, "min_f32_nan_rhs", 5.0, std.math.nan(f32)),
    );
    const both_nan = try runFloatBinaryOpRaw(.min, f32, "min_f32_both_nan", std.math.nan(f32), std.math.nan(f32));
    try testing.expect(std.math.isNan(both_nan));
}

test "x86_64 arith.min over f64: ordered + NaN-aware contract" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f64, 3.0), try runFloatBinaryOpRaw(.min, f64, "min_f64_ord_a", 3.0, 7.0));
    try testing.expectEqual(@as(f64, 3.0), try runFloatBinaryOpRaw(.min, f64, "min_f64_ord_b", 7.0, 3.0));
    try testing.expectEqual(@as(f64, -5.0), try runFloatBinaryOpRaw(.min, f64, "min_f64_negs", -5.0, -3.0));
    try testing.expectEqual(
        @as(f64, 5.0),
        try runFloatBinaryOpRaw(.min, f64, "min_f64_nan_lhs", std.math.nan(f64), 5.0),
    );
    try testing.expectEqual(
        @as(f64, 5.0),
        try runFloatBinaryOpRaw(.min, f64, "min_f64_nan_rhs", 5.0, std.math.nan(f64)),
    );
    const both_nan = try runFloatBinaryOpRaw(.min, f64, "min_f64_both_nan", std.math.nan(f64), std.math.nan(f64));
    try testing.expect(std.math.isNan(both_nan));
}

test "x86_64 Backend.init wires the arith verifier traits even on a bare context (tick-33 [P2] closure)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ir_ctx);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "add_mismatched", &.{}, &.{i32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 1);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 2);
    try entry.addOperation(rhs.op);
    var add = try ArithDialect.AddOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(add.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{add.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.VerificationFailed, runtime.compile(module.op));
}

test "x86_64 arith.max rejects mismatched lhs / rhs types" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "max_mismatched", &.{}, &.{f32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 2.0);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 3.0);
    try entry.addOperation(rhs.op);
    var op = try ArithDialect.MaxOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(op.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.VerificationFailed, runtime.compile(module.op));
}

test "x86_64 arith.max/min handle signed zero ordered inputs" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(
        @as(f32, 0.0),
        try runFloatBinaryOpRaw(.max, f32, "max_f32_signed_zeros", 0.0, -0.0),
    );
    try testing.expectEqual(
        @as(f32, 0.0),
        try runFloatBinaryOpRaw(.min, f32, "min_f32_signed_zeros", 0.0, -0.0),
    );
    try testing.expectEqual(
        @as(f64, 0.0),
        try runFloatBinaryOpRaw(.max, f64, "max_f64_signed_zeros", 0.0, -0.0),
    );
    try testing.expectEqual(
        @as(f64, 0.0),
        try runFloatBinaryOpRaw(.min, f64, "min_f64_signed_zeros", 0.0, -0.0),
    );
}

test "x86_64 arith.and over signed integers" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0x0F00), try runIntOp(.band, .i32, "and_i32_a", 0xFF00, 0x0F0F));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.band, .i32, "and_i32_zero", 0xFFFF, 0));
    try testing.expectEqual(@as(i64, 0x0F0F), try runIntOp(.band, .i32, "and_i32_id", 0xFFFF, 0x0F0F));
    try testing.expectEqual(@as(i64, 0x0F00), try runIntOp(.band, .i64, "and_i64_a", 0xFF00, 0x0F0F));
    try testing.expectEqual(
        @as(i64, std.math.maxInt(i64)),
        try runIntOp(.band, .i64, "and_i64_mask_high", -1, std.math.maxInt(i64)),
    );
}

test "x86_64 arith.or over signed integers" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0xFF0F), try runIntOp(.bor, .i32, "or_i32_a", 0xFF00, 0x0F0F));
    try testing.expectEqual(@as(i64, 0xFFFF), try runIntOp(.bor, .i32, "or_i32_full", 0xFF00, 0x00FF));
    try testing.expectEqual(@as(i64, 0xFF0F), try runIntOp(.bor, .i64, "or_i64_a", 0xFF00, 0x0F0F));
}

test "x86_64 arith.xor over signed integers" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0xF00F), try runIntOp(.bxor, .i32, "xor_i32_a", 0xFF00, 0x0F0F));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.bxor, .i32, "xor_i32_self", 0x12345678, 0x12345678));
    try testing.expectEqual(@as(i64, 0x12345678), try runIntOp(.bxor, .i32, "xor_i32_id", 0x12345678, 0));
    try testing.expectEqual(@as(i64, 0xF00F), try runIntOp(.bxor, .i64, "xor_i64_a", 0xFF00, 0x0F0F));
}

test "x86_64 arith.not over signed integers" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -1), try runIntOp(.bnot, .i32, "not_i32_zero", 0, 0));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.bnot, .i32, "not_i32_neg1", -1, 0));
    try testing.expectEqual(@as(i64, -6), try runIntOp(.bnot, .i32, "not_i32_5", 5, 0));
    try testing.expectEqual(@as(i64, -1), try runIntOp(.bnot, .i64, "not_i64_zero", 0, 0));
    try testing.expectEqual(@as(i64, 0), try runIntOp(.bnot, .i64, "not_i64_neg1", -1, 0));
}

test "x86_64 arith.shl over signed integers (shift left)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 16), try runIntOp(.shl, .i32, "shl_i32_1_4", 1, 4));
    try testing.expectEqual(@as(i64, 1024), try runIntOp(.shl, .i32, "shl_i32_1_10", 1, 10));
    try testing.expectEqual(@as(i64, 5), try runIntOp(.shl, .i32, "shl_i32_5_0", 5, 0));
    try testing.expectEqual(@as(i64, 16), try runIntOp(.shl, .i64, "shl_i64_1_4", 1, 4));
    try testing.expectEqual(
        @as(i64, @as(i64, 1) << 32),
        try runIntOp(.shl, .i64, "shl_i64_1_32", 1, 32),
    );
}

test "x86_64 arith.shr over signed integers (arithmetic / sign-extending)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 4), try runIntOp(.shr, .i32, "shr_i32_16_2", 16, 2));
    try testing.expectEqual(@as(i64, -4), try runIntOp(.shr, .i32, "shr_i32_neg16_2", -16, 2));
    try testing.expectEqual(@as(i64, -16), try runIntOp(.shr, .i32, "shr_i32_neg16_0", -16, 0));
    try testing.expectEqual(@as(i64, 4), try runIntOp(.shr, .i64, "shr_i64_16_2", 16, 2));
    try testing.expectEqual(@as(i64, -1), try runIntOp(.shr, .i64, "shr_i64_neg1_5", -1, 5));
}

test "x86_64 arith.ushr over signed integers (logical / zero-extending)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 4), try runIntOp(.ushr, .i32, "ushr_i32_16_2", 16, 2));
    try testing.expectEqual(
        @as(i64, 0x3FFFFFFC),
        try runIntOp(.ushr, .i32, "ushr_i32_neg16_2", -16, 2),
    );
    try testing.expectEqual(
        @as(i64, std.math.maxInt(i64)),
        try runIntOp(.ushr, .i64, "ushr_i64_neg1_1", -1, 1),
    );
    try testing.expectEqual(@as(i64, 127), try runIntOp(.ushr, .i8, "ushr_i8_neg1_1", -1, 1));
}

test "x86_64 arith.ushr over u64 is logical" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try runIntOp(.ushr, .u64, "ushr_u64_max_1", -1, 1));
}

test "x86_64 arith.ushr over u32 is logical" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0x4000_0000), try runIntOp(.ushr, .u32, "ushr_u32_high_1", 0x8000_0000, 1));
}

test "x86_64 arith.shr over arith.index is rejected (unsigned-but-arithmetic mismatch)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const idx_type = try ArithDialect.getScalarType(&ir_ctx, .index);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "shr_index", &.{}, &.{idx_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, 16);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, 2);
    try entry.addOperation(rhs.op);
    var op = try ArithDialect.ShrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(op.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
}

test "x86_64 arith.shr over u64 is rejected" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u64_type = try ArithDialect.getScalarType(&ir_ctx, .u64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "shr_u64", &.{}, &.{u64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u64_type, -1);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u64_type, 1);
    try entry.addOperation(rhs.op);
    var op = try ArithDialect.ShrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(op.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
}

test "x86_64 arith.shr over u32 is rejected" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "shr_u32", &.{}, &.{u32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0x8000_0000);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 1);
    try entry.addOperation(rhs.op);
    var op = try ArithDialect.ShrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try entry.addOperation(op.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
}

fn runCastInt(
    input_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    output_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    name: []const u8,
    c_in: i64,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const in_type = try ArithDialect.getScalarType(&ir_ctx, input_kind);
    const out_type = try ArithDialect.getScalarType(&ir_ctx, output_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, in_type, c_in);
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), out_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec_result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec_result);
}

fn runCastFloatToFloat(
    comptime InFT: type,
    comptime OutFT: type,
    name: []const u8,
    c_in: InFT,
) !OutFT {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const in_kind: ArithDialect.ScalarTypeKind = comptime if (InFT == f32) .f32 else if (InFT == f64) .f64 else @compileError("InFT");
    const out_kind: ArithDialect.ScalarTypeKind = comptime if (OutFT == f32) .f32 else if (OutFT == f64) .f64 else @compileError("OutFT");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const in_type = try ArithDialect.getScalarType(&ir_ctx, in_kind);
    const out_type = try ArithDialect.getScalarType(&ir_ctx, out_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, in_type, @floatCast(c_in));
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), out_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) OutFT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
}

fn runCastIntToFloat(
    input_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    comptime OutFT: type,
    name: []const u8,
    c_in: i64,
) !OutFT {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const out_kind: ArithDialect.ScalarTypeKind = comptime if (OutFT == f32) .f32 else if (OutFT == f64) .f64 else @compileError("OutFT");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const in_type = try ArithDialect.getScalarType(&ir_ctx, input_kind);
    const out_type = try ArithDialect.getScalarType(&ir_ctx, out_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, in_type, c_in);
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), out_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) OutFT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
}

fn runCastFloatToInt(
    comptime InFT: type,
    output_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    name: []const u8,
    c_in: InFT,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const in_kind: ArithDialect.ScalarTypeKind = comptime if (InFT == f32) .f32 else if (InFT == f64) .f64 else @compileError("InFT");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const in_type = try ArithDialect.getScalarType(&ir_ctx, in_kind);
    const out_type = try ArithDialect.getScalarType(&ir_ctx, output_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, in_type, @floatCast(c_in));
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), out_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec_result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec_result);
}

test "x86_64 arith.cast: int -> int (sign-extend, truncate, same-kind)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -5), try runCastInt(.i32, .i64, "cast_i32_i64_neg", -5));
    try testing.expectEqual(@as(i64, 1234567), try runCastInt(.i32, .i64, "cast_i32_i64_pos", 1234567));
    try testing.expectEqual(@as(i64, 5), try runCastInt(.i64, .i32, "cast_i64_i32_pos", 5));
    try testing.expectEqual(@as(i64, -5), try runCastInt(.i64, .i32, "cast_i64_i32_neg", -5));
    try testing.expectEqual(@as(i64, 42), try runCastInt(.i32, .i32, "cast_i32_i32_same", 42));
    try testing.expectEqual(@as(i64, 100), try runCastInt(.index, .i64, "cast_index_i64", 100));
    try testing.expectEqual(@as(i64, -1), try runCastInt(.i32, .i8, "cast_i32_i8_neg1", -1));
}

test "x86_64 arith.cast: u32 int casts preserve unsigned high bits" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0x8000_0000), try runCastInt(.u32, .i64, "cast_u32_i64_high", 0x8000_0000));
    try testing.expectEqual(@as(i64, 0xffff_ffff), try runCastInt(.u32, .index, "cast_u32_index_max", 0xffff_ffff));
    try testing.expectEqual(@as(i64, 0xffff_ffff), try runCastInt(.i64, .u32, "cast_i64_u32_neg1", -1));
    try testing.expectEqual(@as(i64, -1), try runCastInt(.u32, .i32, "cast_u32_i32_max", 0xffff_ffff));
}

test "x86_64 arith.cast: float -> float (cvtss2sd / cvtsd2ss)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f64, 3.5), try runCastFloatToFloat(f32, f64, "cast_f32_f64", 3.5));
    try testing.expectEqual(@as(f64, -2.0), try runCastFloatToFloat(f32, f64, "cast_f32_f64_neg", -2.0));
    try testing.expectEqual(@as(f32, 3.5), try runCastFloatToFloat(f64, f32, "cast_f64_f32", 3.5));
    try testing.expectEqual(@as(f32, 1.25), try runCastFloatToFloat(f32, f32, "cast_f32_f32_same", 1.25));
}

test "x86_64 arith.cast: int -> float (cvtsi2ss / cvtsi2sd)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 5.0), try runCastIntToFloat(.i32, f32, "cast_i32_f32", 5));
    try testing.expectEqual(@as(f32, -7.0), try runCastIntToFloat(.i32, f32, "cast_i32_f32_neg", -7));
    try testing.expectEqual(@as(f64, 1234567890.0), try runCastIntToFloat(.i32, f64, "cast_i32_f64", 1234567890));
    try testing.expectEqual(@as(f64, 100.0), try runCastIntToFloat(.i64, f64, "cast_i64_f64", 100));
    try testing.expectEqual(@as(f64, 42.0), try runCastIntToFloat(.index, f64, "cast_index_f64", 42));
}

test "x86_64 arith.cast: u32 -> float uses unsigned high-bit values" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f64, 2147483648.0), try runCastIntToFloat(.u32, f64, "cast_u32_f64_2pow31", 0x8000_0000));
    try testing.expectEqual(@as(f64, 4294967295.0), try runCastIntToFloat(.u32, f64, "cast_u32_f64_max", 0xffff_ffff));
    try testing.expectEqual(@as(f32, @floatFromInt(@as(u32, 0xffff_ffff))), try runCastIntToFloat(.u32, f32, "cast_u32_f32_max", 0xffff_ffff));
}

test "x86_64 arith.cast: arith.index -> f64 high-bit values (Hacker's Delight)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(
        @as(f64, 0.0),
        try runCastIntToFloat(.index, f64, "cast_index_f64_zero", 0),
    );
    try testing.expectEqual(
        @as(f64, 1.0),
        try runCastIntToFloat(.index, f64, "cast_index_f64_one", 1),
    );
    try testing.expectEqual(
        @as(f64, @floatFromInt(@as(i64, std.math.maxInt(i64)))),
        try runCastIntToFloat(.index, f64, "cast_index_f64_i64max", std.math.maxInt(i64)),
    );

    const two_to_63: f64 = @bitCast(@as(u64, 0x43E0000000000000));
    try testing.expectEqual(
        two_to_63,
        try runCastIntToFloat(.index, f64, "cast_index_f64_2pow63", @as(i64, @bitCast(@as(u64, 0x8000000000000000)))),
    );

    const expected_sticky: f64 = @bitCast(@as(u64, 0x43E0000000000001));
    try testing.expectEqual(
        expected_sticky,
        try runCastIntToFloat(.index, f64, "cast_index_f64_sticky", @as(i64, @bitCast(@as(u64, 0x8000000000000401)))),
    );

    const two_to_64: f64 = @bitCast(@as(u64, 0x43F0000000000000));
    try testing.expectEqual(
        two_to_64,
        try runCastIntToFloat(.index, f64, "cast_index_f64_u64max", @as(i64, @bitCast(@as(u64, 0xFFFFFFFFFFFFFFFF)))),
    );
}

test "x86_64 arith.cast: u64 -> f64 high-bit values" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    const two_to_64: f64 = @bitCast(@as(u64, 0x43F0000000000000));
    try testing.expectEqual(
        two_to_64,
        try runCastIntToFloat(.u64, f64, "cast_u64_f64_u64max", -1),
    );
}

test "x86_64 arith.cast: arith.index -> f32 high-bit values (Hacker's Delight)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    const two_to_63_f32: f32 = @bitCast(@as(u32, 0x5F000000));
    try testing.expectEqual(
        two_to_63_f32,
        try runCastIntToFloat(.index, f32, "cast_index_f32_2pow63", @as(i64, @bitCast(@as(u64, 0x8000000000000000)))),
    );

    const two_to_64_f32: f32 = @bitCast(@as(u32, 0x5F800000));
    try testing.expectEqual(
        two_to_64_f32,
        try runCastIntToFloat(.index, f32, "cast_index_f32_u64max", @as(i64, @bitCast(@as(u64, 0xFFFFFFFFFFFFFFFF)))),
    );
}

test "x86_64 arith.cast: float -> int (cvttss2si / cvttsd2si truncating)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 3), try runCastFloatToInt(f32, .i32, "cast_f32_i32_pos", 3.7));
    try testing.expectEqual(@as(i64, -3), try runCastFloatToInt(f32, .i32, "cast_f32_i32_neg", -3.7));
    try testing.expectEqual(@as(i64, 7), try runCastFloatToInt(f64, .i32, "cast_f64_i32", 7.99));
    try testing.expectEqual(@as(i64, 100), try runCastFloatToInt(f64, .i64, "cast_f64_i64", 100.5));
    try testing.expectEqual(@as(i64, -7), try runCastFloatToInt(f64, .i64, "cast_f64_i64_neg", -7.99));
}

test "x86_64 arith.cast: float -> u32 uses unsigned high-bit values" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0x8000_0000), try runCastFloatToInt(f64, .u32, "cast_f64_u32_2pow31", 2147483648.0));
    try testing.expectEqual(@as(i64, 0xffff_ffff), try runCastFloatToInt(f64, .u32, "cast_f64_u32_max", 4294967295.0));
    try testing.expectEqual(@as(i64, 0x8000_0000), try runCastFloatToInt(f32, .u32, "cast_f32_u32_2pow31", @as(f32, 2147483648.0)));
}

test "x86_64 arith.cast: f64 -> arith.index for high-bit values (2^63-split)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(
        @as(i64, 0),
        try runCastFloatToInt(f64, .index, "cast_f64_idx_zero", 0.0),
    );
    try testing.expectEqual(
        @as(i64, 1),
        try runCastFloatToInt(f64, .index, "cast_f64_idx_one", 1.0),
    );

    const low_boundary_f64: f64 = @bitCast(@as(u64, 0x43DFFFFFFFFFFFFF));
    const low_boundary_idx: i64 = @bitCast(@as(u64, 0x7FFFFFFFFFFFFC00));
    try testing.expectEqual(
        low_boundary_idx,
        try runCastFloatToInt(f64, .index, "cast_f64_idx_low_boundary", low_boundary_f64),
    );

    const two_to_63_f64: f64 = @bitCast(@as(u64, 0x43E0000000000000));
    const two_to_63_idx: i64 = @bitCast(@as(u64, 0x8000000000000000));
    try testing.expectEqual(
        two_to_63_idx,
        try runCastFloatToInt(f64, .index, "cast_f64_idx_2pow63", two_to_63_f64),
    );

    const residual_f64: f64 = @bitCast(@as(u64, 0x43E0000000000001));
    const residual_idx: i64 = @bitCast(@as(u64, 0x8000000000000800));
    try testing.expectEqual(
        residual_idx,
        try runCastFloatToInt(f64, .index, "cast_f64_idx_residual", residual_f64),
    );

    const near_max_f64: f64 = @bitCast(@as(u64, 0x43EFFFFFFFFFFFFF));
    const near_max_idx: i64 = @bitCast(@as(u64, 0xFFFFFFFFFFFFF800));
    try testing.expectEqual(
        near_max_idx,
        try runCastFloatToInt(f64, .index, "cast_f64_idx_near_max", near_max_f64),
    );
}

test "x86_64 arith.cast: f64 -> u64 high-bit values" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    const two_to_63_f64: f64 = @bitCast(@as(u64, 0x43E0000000000000));
    const two_to_63_u64: i64 = @bitCast(@as(u64, 0x8000000000000000));
    try testing.expectEqual(
        two_to_63_u64,
        try runCastFloatToInt(f64, .u64, "cast_f64_u64_2pow63", two_to_63_f64),
    );
}

test "x86_64 arith.cast: f32 -> arith.index for high-bit values (2^63-split)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    const two_to_63_f32: f32 = @bitCast(@as(u32, 0x5F000000));
    const two_to_63_idx: i64 = @bitCast(@as(u64, 0x8000000000000000));
    try testing.expectEqual(
        two_to_63_idx,
        try runCastFloatToInt(f32, .index, "cast_f32_idx_2pow63", two_to_63_f32),
    );

    try testing.expectEqual(
        @as(i64, 1),
        try runCastFloatToInt(f32, .index, "cast_f32_idx_one", 1.0),
    );
}

test "x86_64 arith.cast: i32 -> index sign-extends (movsxd, post-review fix)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, -1), try runCastInt(.i32, .index, "cast_i32_index_neg1", -1));
    try testing.expectEqual(@as(i64, 100), try runCastInt(.i32, .index, "cast_i32_index_pos", 100));
}

test "x86_64 arith.cast: bool -> bool identity passes (post-review fix)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "cast_bool_bool_id", &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), bool_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const result = try onlyResult(&runtime, compiled, "cast_bool_bool_id", &.{});
    try testing.expectEqual(@as(i64, 1), try integerOf(result));
}

fn runBoolBitwise(
    comptime kind: ScalarOpKind,
    name: []const u8,
    lhs_value: bool,
    rhs_value: bool,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var lhs = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, lhs_value);
    try entry.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, rhs_value);
    try entry.addOperation(rhs.op);

    const result_value = switch (kind) {
        .band => blk: {
            const op = try ArithDialect.AndOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .bor => blk: {
            const op = try ArithDialect.OrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .bxor => blk: {
            const op = try ArithDialect.XorOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        else => return error.UnsupportedType,
    };
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(result);
}

test "x86_64 arith.and/or/xor over bool slots" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0), try runBoolBitwise(.band, "and_bool_false", true, false));
    try testing.expectEqual(@as(i64, 1), try runBoolBitwise(.band, "and_bool_true", true, true));
    try testing.expectEqual(@as(i64, 1), try runBoolBitwise(.bor, "or_bool_true", true, false));
    try testing.expectEqual(@as(i64, 0), try runBoolBitwise(.bor, "or_bool_false", false, false));
    try testing.expectEqual(@as(i64, 1), try runBoolBitwise(.bxor, "xor_bool_true", true, false));
    try testing.expectEqual(@as(i64, 0), try runBoolBitwise(.bxor, "xor_bool_false", true, true));
}

fn runBoolNot(name: []const u8, bool_val: bool) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var value = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, bool_val);
    try entry.addOperation(value.op);
    var not_op = try ArithDialect.NotOp.create(&ir_ctx, loc, value.getResult());
    try entry.addOperation(not_op.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{not_op.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(result);
}

test "x86_64 arith.not over bool slots" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 0), try runBoolNot("not_bool_true", true));
    try testing.expectEqual(@as(i64, 1), try runBoolNot("not_bool_false", false));
}

fn runCastBoolToInt(
    output_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    name: []const u8,
    bool_val: bool,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const out_type = try ArithDialect.getScalarType(&ir_ctx, output_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, bool_val);
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), out_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec);
}

fn runCastBoolToFloat(
    comptime OutFT: type,
    name: []const u8,
    bool_val: bool,
) !OutFT {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const out_kind: ArithDialect.ScalarTypeKind = comptime if (OutFT == f32) .f32 else if (OutFT == f64) .f64 else @compileError("OutFT");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const out_type = try ArithDialect.getScalarType(&ir_ctx, out_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, bool_val);
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), out_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) OutFT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
}

fn runCastIntToBool(
    input_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    name: []const u8,
    c_in: i64,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const in_type = try ArithDialect.getScalarType(&ir_ctx, input_kind);
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, in_type, c_in);
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), bool_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec);
}

fn runCastFloatToBool(
    comptime InFT: type,
    name: []const u8,
    c_in: InFT,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const in_kind: ArithDialect.ScalarTypeKind = comptime if (InFT == f32) .f32 else if (InFT == f64) .f64 else @compileError("InFT");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const in_type = try ArithDialect.getScalarType(&ir_ctx, in_kind);
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{bool_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, in_type, @floatCast(c_in));
    try entry.addOperation(c.op);
    var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), bool_type);
    try entry.addOperation(cast.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{cast.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec);
}

test "x86_64 arith.cast: bool -> integer (slot copy with width adjust)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 1), try runCastBoolToInt(.i32, "cast_bool_i32_t", true));
    try testing.expectEqual(@as(i64, 0), try runCastBoolToInt(.i32, "cast_bool_i32_f", false));
    try testing.expectEqual(@as(i64, 1), try runCastBoolToInt(.i8, "cast_bool_i8_t", true));
    try testing.expectEqual(@as(i64, 1), try runCastBoolToInt(.i16, "cast_bool_i16_t", true));
    try testing.expectEqual(@as(i64, 1), try runCastBoolToInt(.i64, "cast_bool_i64_t", true));
    try testing.expectEqual(@as(i64, 0), try runCastBoolToInt(.i64, "cast_bool_i64_f", false));
}

test "x86_64 arith.cast: bool -> float (cvtsi2ss / cvtsi2sd on 0 or 1)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 1.0), try runCastBoolToFloat(f32, "cast_bool_f32_t", true));
    try testing.expectEqual(@as(f32, 0.0), try runCastBoolToFloat(f32, "cast_bool_f32_f", false));
    try testing.expectEqual(@as(f64, 1.0), try runCastBoolToFloat(f64, "cast_bool_f64_t", true));
    try testing.expectEqual(@as(f64, 0.0), try runCastBoolToFloat(f64, "cast_bool_f64_f", false));
}

test "x86_64 arith.cast: integer -> bool (cmp + setne)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 1), try runCastIntToBool(.i32, "cast_i32_bool_5", 5));
    try testing.expectEqual(@as(i64, 0), try runCastIntToBool(.i32, "cast_i32_bool_0", 0));
    try testing.expectEqual(@as(i64, 1), try runCastIntToBool(.i32, "cast_i32_bool_neg", -1));
    try testing.expectEqual(@as(i64, 1), try runCastIntToBool(.i64, "cast_i64_bool_max", std.math.maxInt(i64)));
    try testing.expectEqual(@as(i64, 0), try runCastIntToBool(.i64, "cast_i64_bool_zero", 0));
}

test "x86_64 arith.cast: float -> bool (ordered-NE; NaN and ±0 are false)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 1), try runCastFloatToBool(f32, "cast_f32_bool_pos", 3.5));
    try testing.expectEqual(@as(i64, 1), try runCastFloatToBool(f32, "cast_f32_bool_neg", -3.5));
    try testing.expectEqual(@as(i64, 0), try runCastFloatToBool(f32, "cast_f32_bool_pzero", 0.0));
    try testing.expectEqual(@as(i64, 0), try runCastFloatToBool(f32, "cast_f32_bool_nzero", -0.0));
    try testing.expectEqual(@as(i64, 0), try runCastFloatToBool(f32, "cast_f32_bool_nan", std.math.nan(f32)));

    try testing.expectEqual(@as(i64, 1), try runCastFloatToBool(f64, "cast_f64_bool_pos", 1e10));
    try testing.expectEqual(@as(i64, 0), try runCastFloatToBool(f64, "cast_f64_bool_zero", 0.0));
    try testing.expectEqual(@as(i64, 0), try runCastFloatToBool(f64, "cast_f64_bool_nan", std.math.nan(f64)));
}

test "x86_64 arith.bitcast: i32 ↔ f32 round-trips bit pattern" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ir_ctx);
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "bitcast_round_trip", &.{}, &.{i32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 0x40490FDB);
    try entry.addOperation(c.op);
    var as_f32 = try ArithDialect.BitcastOp.create(&ir_ctx, loc, c.getResult(), f32_type);
    try entry.addOperation(as_f32.op);
    var back_to_i32 = try ArithDialect.BitcastOp.create(&ir_ctx, loc, as_f32.getResult(), i32_type);
    try entry.addOperation(back_to_i32.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{back_to_i32.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "bitcast_round_trip", &.{});
    try testing.expectEqual(@as(i64, 0x40490FDB), try integerOf(exec));
}

test "x86_64 arith.bitcast: u32 ↔ f32 round-trips high bit pattern" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(&ir_ctx, .u32);
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "bitcast_u32_round_trip", &.{}, &.{u32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, u32_type, 0xFFC00001);
    try entry.addOperation(c.op);
    var as_f32 = try ArithDialect.BitcastOp.create(&ir_ctx, loc, c.getResult(), f32_type);
    try entry.addOperation(as_f32.op);
    var back_to_u32 = try ArithDialect.BitcastOp.create(&ir_ctx, loc, as_f32.getResult(), u32_type);
    try entry.addOperation(back_to_u32.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{back_to_u32.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "bitcast_u32_round_trip", &.{});
    try testing.expectEqual(@as(i64, 0xFFC00001), try integerOf(exec));
}

test "x86_64 arith.bitcast: i64 ↔ f64 round-trips bit pattern" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "bitcast_64_round_trip", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, @bitCast(@as(u64, 0x400921FB54442D18)));
    try entry.addOperation(c.op);
    var as_f64 = try ArithDialect.BitcastOp.create(&ir_ctx, loc, c.getResult(), f64_type);
    try entry.addOperation(as_f64.op);
    var back_to_i64 = try ArithDialect.BitcastOp.create(&ir_ctx, loc, as_f64.getResult(), i64_type);
    try entry.addOperation(back_to_i64.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{back_to_i64.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "bitcast_64_round_trip", &.{});
    try testing.expectEqual(
        @as(i64, @bitCast(@as(u64, 0x400921FB54442D18))),
        try integerOf(exec),
    );
}

test "x86_64 arith.bitcast: width mismatch + bool reject cleanly" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

        const loc = ir.Location.getUnknown();
        const i32_type = try ArithDialect.getI32Type(&ir_ctx);
        const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();
        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "bitcast_width_mismatch", &.{}, &.{f64_type});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 1);
        try entry.addOperation(c.op);
        var bc = try ArithDialect.BitcastOp.create(&ir_ctx, loc, c.getResult(), f64_type);
        try entry.addOperation(bc.op);
        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{bc.getResult()});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
    }

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

        const loc = ir.Location.getUnknown();
        const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();
        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "bitcast_bool", &.{}, &.{i64_type});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var c = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
        try entry.addOperation(c.op);
        var bc = try ArithDialect.BitcastOp.create(&ir_ctx, loc, c.getResult(), i64_type);
        try entry.addOperation(bc.op);
        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{bc.getResult()});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
    }
}

test "x86_64 arith.bitcast: index reject (post-review whitelist fix)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const idx_type = try ArithDialect.getIndexType(&ir_ctx);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "bitcast_index", &.{}, &.{i64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, idx_type, 7);
    try entry.addOperation(c.op);
    var bc = try ArithDialect.BitcastOp.create(&ir_ctx, loc, c.getResult(), i64_type);
    try entry.addOperation(bc.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{bc.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
}

fn runSelectInt(
    output_kind: @import("../../dialects/root.zig").ArithDialect.ScalarTypeKind,
    name: []const u8,
    cond: bool,
    true_val: i64,
    false_val: i64,
) !i64 {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const out_type = try ArithDialect.getScalarType(&ir_ctx, output_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c_cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, cond);
    try entry.addOperation(c_cond.op);
    const c_true_op = if (output_kind == .bool)
        try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true_val != 0)
    else
        try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, out_type, true_val);
    try entry.addOperation(c_true_op.op);
    const c_false_op = if (output_kind == .bool)
        try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false_val != 0)
    else
        try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, out_type, false_val);
    try entry.addOperation(c_false_op.op);
    var sel = try ArithDialect.SelectOp.create(&ir_ctx, loc, c_cond.getResult(), c_true_op.getResult(), c_false_op.getResult());
    try entry.addOperation(sel.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{sel.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec);
}

fn runSelectFloat(
    comptime FT: type,
    name: []const u8,
    cond: bool,
    true_val: FT,
    false_val: FT,
) !FT {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const out_kind: ArithDialect.ScalarTypeKind = comptime if (FT == f32) .f32 else if (FT == f64) .f64 else @compileError("FT");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const out_type = try ArithDialect.getScalarType(&ir_ctx, out_kind);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{out_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c_cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, cond);
    try entry.addOperation(c_cond.op);
    var c_true = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, out_type, @floatCast(true_val));
    try entry.addOperation(c_true.op);
    var c_false = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, out_type, @floatCast(false_val));
    try entry.addOperation(c_false.op);
    var sel = try ArithDialect.SelectOp.create(&ir_ctx, loc, c_cond.getResult(), c_true.getResult(), c_false.getResult());
    try entry.addOperation(sel.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{sel.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) FT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
}

test "x86_64 arith.select: integer cmov path (i32, i64, index, bool)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(i64, 7), try runSelectInt(.i32, "select_i32_t", true, 7, -3));
    try testing.expectEqual(@as(i64, -3), try runSelectInt(.i32, "select_i32_f", false, 7, -3));

    try testing.expectEqual(
        @as(i64, std.math.maxInt(i64)),
        try runSelectInt(.i64, "select_i64_max", true, std.math.maxInt(i64), -1),
    );
    try testing.expectEqual(
        @as(i64, std.math.minInt(i64)),
        try runSelectInt(.i64, "select_i64_min", false, 0, std.math.minInt(i64)),
    );

    try testing.expectEqual(@as(i64, 100), try runSelectInt(.index, "select_idx_t", true, 100, 200));

    try testing.expectEqual(@as(i64, 1), try runSelectInt(.bool, "select_bool_tt", true, 1, 0));
    try testing.expectEqual(@as(i64, 0), try runSelectInt(.bool, "select_bool_ff", false, 1, 0));
}

test "x86_64 arith.select: float branched path (f32, f64)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 3.5), try runSelectFloat(f32, "select_f32_t", true, 3.5, -2.0));
    try testing.expectEqual(@as(f32, -2.0), try runSelectFloat(f32, "select_f32_f", false, 3.5, -2.0));
    try testing.expectEqual(@as(f64, 3.5), try runSelectFloat(f64, "select_f64_t", true, 3.5, -2.0));
    try testing.expectEqual(@as(f64, -2.0), try runSelectFloat(f64, "select_f64_f", false, 3.5, -2.0));
}

test "x86_64 arith.select inside scf.if body (dispatchOp parity)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ir_ctx);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "select_in_if", &.{}, &.{i32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var outer_cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(outer_cond.op);
    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, outer_cond.getResult(), &.{i32_type});
    try entry.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var inner_cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false);
    try then_block.addOperation(inner_cond.op);
    var t_val = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 42);
    try then_block.addOperation(t_val.op);
    var f_val = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, -7);
    try then_block.addOperation(f_val.op);
    var sel = try ArithDialect.SelectOp.create(&ir_ctx, loc, inner_cond.getResult(), t_val.getResult(), f_val.getResult());
    try then_block.addOperation(sel.op);
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{sel.getResult()});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    var else_const = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 0);
    try else_block.addOperation(else_const.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{else_const.getResult()});
    try else_block.addOperation(else_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{if_op.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "select_in_if", &.{});
    try testing.expectEqual(@as(i64, -7), try integerOf(exec));
}

test "x86_64 arith.select rejects mismatched true/false types (trait verifier fires)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ir_ctx);
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "select_mismatched", &.{}, &.{i32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var c_cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(c_cond.op);
    var c_true = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 1);
    try entry.addOperation(c_true.op);
    var c_false = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 2);
    try entry.addOperation(c_false.op);
    var sel = try ArithDialect.SelectOp.create(&ir_ctx, loc, c_cond.getResult(), c_true.getResult(), c_false.getResult());
    try entry.addOperation(sel.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{sel.getResult()});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    try testing.expectError(error.VerificationFailed, runtime.compile(module.op));
}

test "x86_64 arith.fma over f32 computes a*b+c with libm fmaf" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    try testing.expectEqual(
        @as(f32, 10.0),
        try runFloatTernaryOpRaw(.fma, f32, "fma_f32_basic", 2.0, 3.0, 4.0),
    );
}

test "x86_64 arith.fma over f64 computes a*b+c with libm fma" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    try testing.expectEqual(
        @as(f64, 10.0),
        try runFloatTernaryOpRaw(.fma, f64, "fma_f64_basic", 2.0, 3.0, 4.0),
    );
}

test "x86_64 arith.fma proves single-rounding via representable sentinel (f64)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const a: f64 = @bitCast(@as(u64, 0x3FF0000000000001));
    const b: f64 = a;
    const c: f64 = @bitCast(@as(u64, 0xBFF0000000000002));
    const expected: f64 = @bitCast(@as(u64, 0x3970000000000000));
    try testing.expectEqual(
        expected,
        try runFloatTernaryOpRaw(.fma, f64, "fma_f64_single_round", a, b, c),
    );
}

test "x86_64 arith.fma proves single-rounding via representable sentinel (f32)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const a: f32 = @bitCast(@as(u32, 0x3F800001));
    const b: f32 = a;
    const c: f32 = @bitCast(@as(u32, 0xBF800002));
    const expected: f32 = @bitCast(@as(u32, 0x28800000));
    try testing.expectEqual(
        expected,
        try runFloatTernaryOpRaw(.fma, f32, "fma_f32_single_round", a, b, c),
    );
}

test "x86_64 arith.fma rejects f16, integers, and mismatched operand types" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);
        const loc = ir.Location.getUnknown();
        const i32_type = try ArithDialect.getScalarType(&ir_ctx, .i32);

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();
        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "fma_int_reject", &.{}, &.{i32_type});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var ca = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 2);
        try entry.addOperation(ca.op);
        var cb = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 3);
        try entry.addOperation(cb.op);
        var cc = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 4);
        try entry.addOperation(cc.op);

        var state = ir.Operation.State.init(ArithDialect.FmaOp.operation_name, loc);
        state.addOperands(&.{ ca.getResult(), cb.getResult(), cc.getResult() });
        state.addTypes(&.{i32_type});
        const fma_op = try ir_ctx.createOperation(state);
        try entry.addOperation(fma_op);
        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{fma_op.getResult(0).?});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
    }

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);
        const loc = ir.Location.getUnknown();
        const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
        const f64_type = try ArithDialect.getF64Type(&ir_ctx);

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();
        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "fma_mismatch", &.{}, &.{f32_type});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var ca = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 1.0);
        try entry.addOperation(ca.op);
        var cb = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f32_type, 2.0);
        try entry.addOperation(cb.op);
        var cc = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 3.0);
        try entry.addOperation(cc.op);
        var fma = try ArithDialect.FmaOp.create(&ir_ctx, loc, ca.getResult(), cb.getResult(), cc.getResult());
        try entry.addOperation(fma.op);
        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{fma.getResult()});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        try testing.expectError(error.VerificationFailed, runtime.compile(module.op));
    }
}

test "x86_64 arith.cast: f16 still rejected (no Float16 capability)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

        const loc = ir.Location.getUnknown();
        const i32_type = try ArithDialect.getI32Type(&ir_ctx);
        const f16_type = try ArithDialect.getF16Type(&ir_ctx);

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();
        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "cast_i32_f16", &.{}, &.{i32_type});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var c = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 1);
        try entry.addOperation(c.op);
        var cast = try ArithDialect.CastOp.create(&ir_ctx, loc, c.getResult(), f16_type);
        try entry.addOperation(cast.op);
        var back = try ArithDialect.CastOp.create(&ir_ctx, loc, cast.getResult(), i32_type);
        try entry.addOperation(back.op);
        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{back.getResult()});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        try testing.expectError(error.JitCompileFailed, runtime.compile(module.op));
    }
}

fn runUnaryFloatInScfIf(
    name: []const u8,
    op_kind: enum { sqrt, exp },
    input: f64,
    else_val: f64,
    expected: f64,
    tol: f64,
) !void {
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getF64Type(&ir_ctx);
    const bool_type = try ArithDialect.getScalarType(&ir_ctx, .bool);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, name, &.{}, &.{f64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(cond.op);

    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, cond.getResult(), &.{f64_type});
    try entry.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var then_const = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, input);
    try then_block.addOperation(then_const.op);
    const then_result = blk: {
        switch (op_kind) {
            .sqrt => {
                var op = try ArithDialect.SqrtOp.create(&ir_ctx, loc, then_const.getResult());
                try then_block.addOperation(op.op);
                break :blk op.getResult();
            },
            .exp => {
                var op = try ArithDialect.ExpOp.create(&ir_ctx, loc, then_const.getResult());
                try then_block.addOperation(op.op);
                break :blk op.getResult();
            },
        }
    };
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{then_result});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    var else_const = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, else_val);
    try else_block.addOperation(else_const.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{else_const.getResult()});
    try else_block.addOperation(else_yield.op);

    const result = if_op.op.getResult(0).?;
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result});
    try entry.addOperation(ret.op);
    _ = bool_type;

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec_result = try onlyResult(&runtime, compiled, name, &.{});
    const got = try floatOf(exec_result);
    try std.testing.expectApproxEqAbs(expected, got, tol);
}

test "x86_64 arith.sqrt inside scf.if body (emitArithSqrt via dispatchOp)" {
    if (!executes) return error.SkipZigTest;
    try runUnaryFloatInScfIf("sqrt_in_if", .sqrt, 16.0, 0.0, 4.0, 1e-12);
}

test "x86_64 arith.exp inside scf.if body (emitArithLibmUnary via dispatchOp)" {
    if (!executes) return error.SkipZigTest;
    try runUnaryFloatInScfIf("exp_in_if", .exp, 0.0, 0.0, 1.0, 1e-12);
}

test "x86_64 arith.pow inside scf.if body (emitArithLibmBinary via dispatchOp)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getF64Type(&ir_ctx);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "pow_in_if", &.{}, &.{f64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(cond.op);

    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, cond.getResult(), &.{f64_type});
    try entry.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var base = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 2.0);
    try then_block.addOperation(base.op);
    var exp = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 10.0);
    try then_block.addOperation(exp.op);
    var pow = try ArithDialect.PowOp.create(&ir_ctx, loc, base.getResult(), exp.getResult());
    try then_block.addOperation(pow.op);
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{pow.getResult()});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    var else_const = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 0.0);
    try else_block.addOperation(else_const.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{else_const.getResult()});
    try else_block.addOperation(else_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{if_op.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "pow_in_if", &.{});
    try testing.expectApproxEqAbs(@as(f64, 1024.0), try floatOf(exec), 1e-9);
}

test "x86_64 arith.and / arith.not inside scf.if body (emitArithBitwiseBinary + emitArithNot via dispatchOp)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ir_ctx);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "and_not_in_if", &.{}, &.{i32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(cond.op);

    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, cond.getResult(), &.{i32_type});
    try entry.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var lhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 0xFF00);
    try then_block.addOperation(lhs.op);
    var rhs = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 0x0F0F);
    try then_block.addOperation(rhs.op);
    var and_op = try ArithDialect.AndOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
    try then_block.addOperation(and_op.op);
    var not_op = try ArithDialect.NotOp.create(&ir_ctx, loc, and_op.getResult());
    try then_block.addOperation(not_op.op);
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{not_op.getResult()});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    var else_const = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 0);
    try else_block.addOperation(else_const.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{else_const.getResult()});
    try else_block.addOperation(else_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{if_op.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "and_not_in_if", &.{});
    try testing.expectEqual(@as(i64, -3841), try integerOf(exec));
}

test "x86_64 arith.shl inside scf.if body (emitArithShift via dispatchOp)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ir_ctx);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "shl_in_if", &.{}, &.{i32_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(cond.op);

    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, cond.getResult(), &.{i32_type});
    try entry.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var v = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 1);
    try then_block.addOperation(v.op);
    var n = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 4);
    try then_block.addOperation(n.op);
    var shl = try ArithDialect.ShlOp.create(&ir_ctx, loc, v.getResult(), n.getResult());
    try then_block.addOperation(shl.op);
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{shl.getResult()});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    var else_const = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i32_type, 0);
    try else_block.addOperation(else_const.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{else_const.getResult()});
    try else_block.addOperation(else_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{if_op.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "shl_in_if", &.{});
    try testing.expectEqual(@as(i64, 16), try integerOf(exec));
}

test "x86_64 arith.max (float branch) inside scf.if body (emitArithMinMax via dispatchOp)" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getF64Type(&ir_ctx);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "max_in_if", &.{}, &.{f64_type});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var cond = try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true);
    try entry.addOperation(cond.op);

    var if_op = try ScfDialect.IfOp.create(&ir_ctx, loc, cond.getResult(), &.{f64_type});
    try entry.addOperation(if_op.op);

    const then_block = if_op.getThenBlock();
    var a = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 3.0);
    try then_block.addOperation(a.op);
    var b = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 7.0);
    try then_block.addOperation(b.op);
    var max_op = try ArithDialect.MaxOp.create(&ir_ctx, loc, a.getResult(), b.getResult());
    try then_block.addOperation(max_op.op);
    const then_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{max_op.getResult()});
    try then_block.addOperation(then_yield.op);

    const else_block = if_op.getElseBlock().?;
    var else_const = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 0.0);
    try else_block.addOperation(else_const.op);
    const else_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{else_const.getResult()});
    try else_block.addOperation(else_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{if_op.op.getResult(0).?});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, "max_in_if", &.{});
    try testing.expectEqual(@as(f64, 7.0), try floatOf(exec));
}

test "x86_64 unsupported scalar arith dtype/op pairs are rejected" {
    if (!executes) return error.SkipZigTest;
    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;

    const RejectCase = struct {
        dtype: ArithDialect.ScalarTypeKind,
        op_kind: ScalarOpKind,
    };
    const cases: []const RejectCase = &.{
        .{ .dtype = .index, .op_kind = .neg },
        .{ .dtype = .i32, .op_kind = .sqrt },
        .{ .dtype = .i64, .op_kind = .sqrt },
        .{ .dtype = .index, .op_kind = .sqrt },
        .{ .dtype = .bool, .op_kind = .sqrt },
        .{ .dtype = .i32, .op_kind = .floor },
        .{ .dtype = .bool, .op_kind = .floor },
        .{ .dtype = .index, .op_kind = .abs },
        .{ .dtype = .f16, .op_kind = .neg },
        .{ .dtype = .f16, .op_kind = .abs },
        .{ .dtype = .f16, .op_kind = .sqrt },
        .{ .dtype = .f16, .op_kind = .floor },
        .{ .dtype = .f16, .op_kind = .max },
        .{ .dtype = .f16, .op_kind = .min },
        .{ .dtype = .f16, .op_kind = .sin },
        .{ .dtype = .f16, .op_kind = .cos },
        .{ .dtype = .f16, .op_kind = .tan },
        .{ .dtype = .f16, .op_kind = .exp },
        .{ .dtype = .f16, .op_kind = .log },
        .{ .dtype = .f16, .op_kind = .tanh },
        .{ .dtype = .f16, .op_kind = .pow },
        .{ .dtype = .bool, .op_kind = .neg },
        .{ .dtype = .bool, .op_kind = .abs },
        .{ .dtype = .bool, .op_kind = .max },
        .{ .dtype = .bool, .op_kind = .min },
        .{ .dtype = .bool, .op_kind = .div },
        .{ .dtype = .bool, .op_kind = .rem },
        .{ .dtype = .bool, .op_kind = .umulhi },
        .{ .dtype = .bool, .op_kind = .popcount },
        .{ .dtype = .bool, .op_kind = .sin },
        .{ .dtype = .bool, .op_kind = .pow },
        .{ .dtype = .i32, .op_kind = .sin },
        .{ .dtype = .i32, .op_kind = .cos },
        .{ .dtype = .i32, .op_kind = .tan },
        .{ .dtype = .i32, .op_kind = .exp },
        .{ .dtype = .i32, .op_kind = .log },
        .{ .dtype = .i32, .op_kind = .tanh },
        .{ .dtype = .i32, .op_kind = .pow },
        .{ .dtype = .index, .op_kind = .pow },
        .{ .dtype = .f32, .op_kind = .band },
        .{ .dtype = .f32, .op_kind = .bor },
        .{ .dtype = .f32, .op_kind = .bxor },
        .{ .dtype = .f32, .op_kind = .bnot },
        .{ .dtype = .f32, .op_kind = .shl },
        .{ .dtype = .f32, .op_kind = .shr },
        .{ .dtype = .f32, .op_kind = .ushr },
        .{ .dtype = .f32, .op_kind = .rem },
        .{ .dtype = .f32, .op_kind = .umulhi },
        .{ .dtype = .f32, .op_kind = .popcount },
        .{ .dtype = .f64, .op_kind = .band },
        .{ .dtype = .f64, .op_kind = .shl },
        .{ .dtype = .f64, .op_kind = .rem },
        .{ .dtype = .f64, .op_kind = .umulhi },
        .{ .dtype = .f64, .op_kind = .popcount },
        .{ .dtype = .index, .op_kind = .umulhi },
        .{ .dtype = .bool, .op_kind = .shl },
        .{ .dtype = .f16, .op_kind = .band },
        .{ .dtype = .f16, .op_kind = .bor },
        .{ .dtype = .f16, .op_kind = .bxor },
        .{ .dtype = .f16, .op_kind = .bnot },
        .{ .dtype = .f16, .op_kind = .shl },
        .{ .dtype = .f16, .op_kind = .shr },
        .{ .dtype = .f16, .op_kind = .ushr },
        .{ .dtype = .f16, .op_kind = .umulhi },
        .{ .dtype = .f16, .op_kind = .popcount },
    };

    for (cases) |case| {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ir_ctx.deinit(allocator);
        try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

        const loc = ir.Location.getUnknown();
        const t = try ArithDialect.getScalarType(&ir_ctx, case.dtype);

        const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
        const module_block = module.getBodyBlock();

        var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "rejected", &.{}, &.{t});
        try module_block.addOperation(func.op);

        const entry = func.getEntryBlock();
        var lhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
            try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 1.0)
        else if (case.dtype == .bool)
            try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, true)
        else
            try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 1);
        try entry.addOperation(lhs.op);

        const result_value = switch (case.op_kind) {
            .neg => blk: {
                const op = try ArithDialect.NegOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .abs => blk: {
                const op = try ArithDialect.AbsOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .sqrt => blk: {
                const op = try ArithDialect.SqrtOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .floor => blk: {
                const op = try ArithDialect.FloorOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .max => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.MaxOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .min => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.MinOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .div => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.DivOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .rem => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.RemOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .umulhi => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.UmulhiOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .popcount => blk: {
                const op = try ArithDialect.PopCountOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .sin => blk: {
                const op = try ArithDialect.SinOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .cos => blk: {
                const op = try ArithDialect.CosOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .tan => blk: {
                const op = try ArithDialect.TanOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .exp => blk: {
                const op = try ArithDialect.ExpOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .log => blk: {
                const op = try ArithDialect.LogOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .tanh => blk: {
                const op = try ArithDialect.TanhOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .pow => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.PowOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .band => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.AndOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .bor => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.OrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .bxor => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.XorOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .bnot => blk: {
                const op = try ArithDialect.NotOp.create(&ir_ctx, loc, lhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .shl => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.ShlOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .shr => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.ShrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
            .ushr => blk: {
                var rhs = if (case.dtype == .f16 or case.dtype == .f32 or case.dtype == .f64)
                    try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, t, 2.0)
                else if (case.dtype == .bool)
                    try ArithDialect.ConstantOp.createBool(&ir_ctx, loc, false)
                else
                    try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, t, 2);
                try entry.addOperation(rhs.op);
                const op = try ArithDialect.UshrOp.create(&ir_ctx, loc, lhs.getResult(), rhs.getResult());
                try entry.addOperation(op.op);
                break :blk op.getResult();
            },
        };

        const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result_value});
        try entry.addOperation(ret.op);

        var runtime = try Runtime.init(allocator, .testing);
        defer runtime.deinit();
        const expected = if (case.dtype == .f16)
            error.UnsupportedOperation
        else
            error.JitCompileFailed;
        try testing.expectError(expected, runtime.compile(module.op));
    }
}

test "x86_64 scf.while loop-invariant home survives body register reuse" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "while_invariant", &.{i64_type}, &.{i64_type});
    try module_block.addOperation(func.op);
    const limit = func.getArgument(0);

    const entry = func.getEntryBlock();
    var fuel_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 100);
    try entry.addOperation(fuel_init.op);
    var acc_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(acc_init.op);

    var while_op = try ScfDialect.WhileOp.create(
        &ir_ctx,
        loc,
        &.{ fuel_init.getResult(), acc_init.getResult() },
        &.{ i64_type, i64_type },
    );
    try entry.addOperation(while_op.op);

    const before = while_op.getBeforeBlock();
    const before_fuel = before.arguments.items[0];
    const before_acc = before.arguments.items[1];
    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try before.addOperation(zero.op);
    var has_fuel = try ArithDialect.CmpOp.create(&ir_ctx, loc, .gt, before_fuel, zero.getResult());
    try before.addOperation(has_fuel.op);
    var below = try ArithDialect.CmpOp.create(&ir_ctx, loc, .lt, before_acc, limit);
    try before.addOperation(below.op);
    var both = try ArithDialect.AndOp.create(&ir_ctx, loc, has_fuel.getResult(), below.getResult());
    try before.addOperation(both.op);
    const condition = try ScfDialect.ConditionOp.create(&ir_ctx, loc, both.getResult(), &.{ before_fuel, before_acc });
    try before.addOperation(condition.op);

    const after = while_op.getAfterBlock();
    const after_fuel = after.arguments.items[0];
    const after_acc = after.arguments.items[1];
    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 1);
    try after.addOperation(one.op);
    var fuel_next = try ArithDialect.SubOp.create(&ir_ctx, loc, after_fuel, one.getResult());
    try after.addOperation(fuel_next.op);

    var chain_zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try after.addOperation(chain_zero.op);
    var chain: *ir.Value = chain_zero.getResult();
    var chain_index: usize = 0;
    while (chain_index < 10) : (chain_index += 1) {
        var link = try ArithDialect.SubOp.create(&ir_ctx, loc, chain, one.getResult());
        try after.addOperation(link.op);
        chain = link.getResult();
    }
    var zero_term = try ArithDialect.SubOp.create(&ir_ctx, loc, chain, chain);
    try after.addOperation(zero_term.op);
    var acc_bump = try ArithDialect.AddOp.create(&ir_ctx, loc, after_acc, one.getResult());
    try after.addOperation(acc_bump.op);
    var acc_next = try ArithDialect.AddOp.create(&ir_ctx, loc, acc_bump.getResult(), zero_term.getResult());
    try after.addOperation(acc_next.op);
    const yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{ fuel_next.getResult(), acc_next.getResult() });
    try after.addOperation(yield.op);

    const result = while_op.op.getResult(1) orelse return error.TestFailure;
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{result});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const exec_result =
        try onlyResult(&runtime, compiled, "while_invariant", &.{.{ .i64 = 10 }});
    try testing.expectEqual(@as(i64, 10), try integerOf(exec_result));
}

test "x86_64 scf.for memref kernel is register allocated and correct" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_i64 = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, i64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "for_sum", &.{ i64_type, memref_i64, memref_i64 }, &.{});
    try module_block.addOperation(func.op);
    const entry = func.getEntryBlock();

    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    var bound = try ArithDialect.CastOp.create(&ir_ctx, loc, func.getArgument(0), index_type);
    try entry.addOperation(bound.op);
    var step = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(step.op);
    var acc_init = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, i64_type, 0);
    try entry.addOperation(acc_init.op);

    var for_op = try ScfDialect.ForOp.create(&ir_ctx, loc, zero.getResult(), bound.getResult(), step.getResult(), &.{acc_init.getResult()}, &.{i64_type});
    try entry.addOperation(for_op.op);
    const body = for_op.getBodyBlock();
    const iv = body.arguments.items[0];
    const acc = body.arguments.items[1];

    var x = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(1), iv, i64_type);
    try body.addOperation(x.op);
    var next = try ArithDialect.AddOp.create(&ir_ctx, loc, acc, x.getResult());
    try body.addOperation(next.op);
    const yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{next.getResult()});
    try body.addOperation(yield.op);

    const total = for_op.op.getResult(0) orelse return error.TestFailure;
    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, total, func.getArgument(2), zero.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
    try testing.expect(emitter.value_location_ranges.items.len > 0);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const SumFn = *const fn (i64, [*]const i64, [*]i64) callconv(.c) void;
    const kernel = try runtime.getFunction(compiled, "for_sum", SumFn);

    var input: [100]i64 = undefined;
    for (&input, 0..) |*slot, i| slot.* = @intCast(i);
    var output: [1]i64 = .{-1};
    kernel(input.len, &input, &output);
    try testing.expectEqual(@as(i64, 4950), output[0]);
}

test "x86_64 nested scf.for float accumulator stays slot carried" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_f64 = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, f64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "for_dot", &.{ i64_type, memref_f64, memref_f64, memref_f64 }, &.{});
    try module_block.addOperation(func.op);
    const entry = func.getEntryBlock();

    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    var bound = try ArithDialect.CastOp.create(&ir_ctx, loc, func.getArgument(0), index_type);
    try entry.addOperation(bound.op);
    var step = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(step.op);
    var acc_init = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 0.0);
    try entry.addOperation(acc_init.op);

    var for_op = try ScfDialect.ForOp.create(&ir_ctx, loc, zero.getResult(), bound.getResult(), step.getResult(), &.{acc_init.getResult()}, &.{f64_type});
    try entry.addOperation(for_op.op);
    const body = for_op.getBodyBlock();
    const iv = body.arguments.items[0];
    const acc = body.arguments.items[1];

    var x = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(1), iv, f64_type);
    try body.addOperation(x.op);
    var y = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(2), iv, f64_type);
    try body.addOperation(y.op);
    var product = try ArithDialect.MulOp.create(&ir_ctx, loc, x.getResult(), y.getResult());
    try body.addOperation(product.op);
    var next = try ArithDialect.AddOp.create(&ir_ctx, loc, acc, product.getResult());
    try body.addOperation(next.op);
    const yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{next.getResult()});
    try body.addOperation(yield.op);

    const total = for_op.op.getResult(0) orelse return error.TestFailure;
    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, total, func.getArgument(3), zero.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const DotFn = *const fn (i64, [*]const f64, [*]const f64, [*]f64) callconv(.c) void;
    const kernel = try runtime.getFunction(compiled, "for_dot", DotFn);

    var xs: [64]f64 = undefined;
    var ys: [64]f64 = undefined;
    var expected: f64 = 0.0;
    for (&xs, &ys, 0..) |*xv, *yv, i| {
        xv.* = @floatFromInt(i);
        yv.* = 0.5;
        expected += @as(f64, @floatFromInt(i)) * 0.5;
    }
    var out: [1]f64 = .{-1.0};
    kernel(xs.len, &xs, &ys, &out);
    try testing.expectEqual(expected, out[0]);
}

test "x86_64 float loop result survives trailing body ops" {
    if (!executes) return error.SkipZigTest;

    const testing = std.testing;
    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const f64_type = try ArithDialect.getScalarType(&ir_ctx, .f64);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const memref_f64 = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, f64_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "sum_and_squares", &.{ i64_type, memref_f64, memref_f64, memref_f64 }, &.{});
    try module_block.addOperation(func.op);
    const entry = func.getEntryBlock();

    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    var one_index = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(one_index.op);
    var bound = try ArithDialect.CastOp.create(&ir_ctx, loc, func.getArgument(0), index_type);
    try entry.addOperation(bound.op);
    var acc_init = try ArithDialect.ConstantOp.createFloat(&ir_ctx, loc, f64_type, 0.0);
    try entry.addOperation(acc_init.op);

    var for_op = try ScfDialect.ForOp.create(&ir_ctx, loc, zero.getResult(), bound.getResult(), one_index.getResult(), &.{acc_init.getResult()}, &.{f64_type});
    try entry.addOperation(for_op.op);
    {
        const body = for_op.getBodyBlock();
        const iv = body.arguments.items[0];
        const acc = body.arguments.items[1];
        var x = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(1), iv, f64_type);
        try body.addOperation(x.op);
        var next = try ArithDialect.AddOp.create(&ir_ctx, loc, acc, x.getResult());
        try body.addOperation(next.op);
        var square = try ArithDialect.MulOp.create(&ir_ctx, loc, x.getResult(), x.getResult());
        try body.addOperation(square.op);
        const square_store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, square.getResult(), func.getArgument(2), iv);
        try body.addOperation(square_store.op);
        const yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{next.getResult()});
        try body.addOperation(yield.op);
    }
    const total = for_op.op.getResult(0) orelse return error.TestFailure;

    const total_store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, total, func.getArgument(3), zero.getResult());
    try entry.addOperation(total_store.op);
    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const KernelFn = *const fn (i64, [*]const f64, [*]f64, [*]f64) callconv(.c) void;
    const kernel = try runtime.getFunction(compiled, "sum_and_squares", KernelFn);

    var xs: [16]f64 = undefined;
    var expected_sum: f64 = 0.0;
    for (&xs, 0..) |*xv, i| {
        xv.* = @floatFromInt(i + 1);
        expected_sum += xv.*;
    }
    var squares: [16]f64 = undefined;
    var out: [1]f64 = .{-1.0};
    kernel(xs.len, &xs, &squares, &out);
    try testing.expectEqual(expected_sum, out[0]);
    try testing.expectEqual(@as(f64, 256.0), squares[15]);
}

test "x86_64 packed vec4xf32 loop keeps values in xmm registers" {
    if (!executes) return error.SkipZigTest;

    const dialects = @import("../../dialects/root.zig");
    const ArithDialect = dialects.ArithDialect;
    const BuiltinDialect = dialects.BuiltinDialect;
    const FuncDialect = dialects.FuncDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const ScfDialect = dialects.ScfDialect;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ir_ctx);

    const loc = ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(&ir_ctx, .i64);
    const f32_type = try ArithDialect.getScalarType(&ir_ctx, .f32);
    const index_type = try ArithDialect.getIndexType(&ir_ctx);
    const vec_type = try ir_ctx.getDialectTypeFromName("arith.vec4xf32");
    const memref_f32 = try MemrefDialect.getMemrefTypeDynamic(&ir_ctx, f32_type, .host);

    const module = try BuiltinDialect.ModuleOp.create(&ir_ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try FuncDialect.FuncOp.create(&ir_ctx, loc, "vaffine", &.{ i64_type, f32_type, memref_f32, memref_f32, memref_f32 }, &.{});
    try module_block.addOperation(func.op);
    const entry = func.getEntryBlock();

    var zero = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    var four = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 4);
    try entry.addOperation(four.op);
    var bound = try ArithDialect.CastOp.create(&ir_ctx, loc, func.getArgument(0), index_type);
    try entry.addOperation(bound.op);

    var remainder = try ArithDialect.RemOp.create(&ir_ctx, loc, bound.getResult(), four.getResult());
    try entry.addOperation(remainder.op);
    var vector_upper = try ArithDialect.SubOp.create(&ir_ctx, loc, bound.getResult(), remainder.getResult());
    try entry.addOperation(vector_upper.op);
    var one = try ArithDialect.ConstantOp.createInt(&ir_ctx, loc, index_type, 1);
    try entry.addOperation(one.op);

    var for_op = try ScfDialect.ForOp.create(&ir_ctx, loc, zero.getResult(), vector_upper.getResult(), four.getResult(), &.{}, &.{});
    try entry.addOperation(for_op.op);
    const body = for_op.getBodyBlock();
    const iv = body.arguments.items[0];

    var scale_vec = try ArithDialect.SplatOp.create(&ir_ctx, loc, func.getArgument(1), vec_type);
    try body.addOperation(scale_vec.op);
    var lhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(2), iv, vec_type);
    try body.addOperation(lhs.op);
    var rhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(3), iv, vec_type);
    try body.addOperation(rhs.op);
    var scaled = try ArithDialect.MulOp.create(&ir_ctx, loc, scale_vec.getResult(), lhs.getResult());
    try body.addOperation(scaled.op);
    var sum = try ArithDialect.AddOp.create(&ir_ctx, loc, scaled.getResult(), rhs.getResult());
    try body.addOperation(sum.op);
    const store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, sum.getResult(), func.getArgument(4), iv);
    try body.addOperation(store.op);
    const yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{});
    try body.addOperation(yield.op);

    var tail_op = try ScfDialect.ForOp.create(&ir_ctx, loc, vector_upper.getResult(), bound.getResult(), one.getResult(), &.{}, &.{});
    try entry.addOperation(tail_op.op);
    const tail = tail_op.getBodyBlock();
    const tail_iv = tail.arguments.items[0];
    var tail_lhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(2), tail_iv, f32_type);
    try tail.addOperation(tail_lhs.op);
    var tail_rhs = try MemrefDialect.LoadOp.create(&ir_ctx, loc, func.getArgument(3), tail_iv, f32_type);
    try tail.addOperation(tail_rhs.op);
    var tail_scaled = try ArithDialect.MulOp.create(&ir_ctx, loc, func.getArgument(1), tail_lhs.getResult());
    try tail.addOperation(tail_scaled.op);
    var tail_sum = try ArithDialect.AddOp.create(&ir_ctx, loc, tail_scaled.getResult(), tail_rhs.getResult());
    try tail.addOperation(tail_sum.op);
    const tail_store = try MemrefDialect.StoreOp.create(&ir_ctx, loc, tail_sum.getResult(), func.getArgument(4), tail_iv);
    try tail.addOperation(tail_store.op);
    const tail_yield = try ScfDialect.YieldOp.create(&ir_ctx, loc, &.{});
    try tail.addOperation(tail_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(func.op);
    var packed_ranges: usize = 0;
    for (emitter.xmm_location_ranges.items) |range| {
        if (emitter.vector_slot_map.get(range.value) != null) packed_ranges += 1;
    }
    try std.testing.expect(packed_ranges > 0);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const AffineFn = *const fn (i64, f32, [*]const f32, [*]const f32, [*]f32) callconv(.c) void;
    const kernel = try runtime.getFunction(compiled, "vaffine", AffineFn);

    var lhs_buf: [19]f32 = undefined;
    var rhs_buf: [19]f32 = undefined;
    for (&lhs_buf, &rhs_buf, 0..) |*a, *b, i| {
        a.* = @floatFromInt(i + 1);
        b.* = @floatFromInt(100 + i);
    }
    var out: [19]f32 = @splat(-1.0);
    kernel(out.len, 2.0, &lhs_buf, &rhs_buf, &out);
    for (out, 0..) |value, i| {
        const expected = @as(f32, @floatFromInt(i + 1)) * 2.0 + @as(f32, @floatFromInt(100 + i));
        try std.testing.expectEqual(expected, value);
    }
}

test "x86_64 byte arguments widen through a stored unsigned result" {
    if (!executes) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const arith = dialects.ArithDialect;
    const memref = dialects.MemrefDialect;
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);
    const location = ir.Location.getUnknown();
    const byte = try arith.getScalarType(&context, .u8);
    const word = try arith.getScalarType(&context, .i64);
    const index_type = try arith.getScalarType(&context, .index);
    const buffer = try memref.getMemrefType1D(&context, 1, byte, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&context, location);
    var function = try dialects.FuncDialect.FuncOp.create(
        &context,
        location,
        "byte_sum",
        &.{ byte, byte },
        &.{word},
    );
    try module.getBodyBlock().addOperation(function.op);
    const block = function.getEntryBlock();
    var cells = try memref.AllocaOp.createStatic(&context, location, buffer);
    try block.addOperation(cells.op);
    var zero = try arith.ConstantOp.createInt(&context, location, index_type, 0);
    try block.addOperation(zero.op);
    var sum = try arith.AddOp.create(
        &context,
        location,
        function.getArgument(0),
        function.getArgument(1),
    );
    try block.addOperation(sum.op);
    const store = try memref.StoreOp.create(
        &context,
        location,
        sum.getResult(),
        cells.getResult(),
        zero.getResult(),
    );
    try block.addOperation(store.op);
    var loaded = try memref.LoadOp.create(
        &context,
        location,
        cells.getResult(),
        zero.getResult(),
        byte,
    );
    try block.addOperation(loaded.op);
    var widened = try arith.CastOp.create(&context, location, loaded.getResult(), word);
    try block.addOperation(widened.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(
        &context,
        location,
        &.{widened.getResult()},
    );
    try block.addOperation(ret.op);
    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const ByteSum = *const fn (u8, u8) callconv(.c) i64;
    const call = try runtime.getFunction(compiled, "byte_sum", ByteSum);
    for (0..256) |left| for (0..256) |right| {
        const expected: i64 = @intCast((left + right) % 256);
        try std.testing.expectEqual(expected, call(@intCast(left), @intCast(right)));
    };
}

test "x86_64 compare and swap loop increments a word one hundred times" {
    if (!executes) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const arith = dialects.ArithDialect;
    const memref = dialects.MemrefDialect;
    const scf = dialects.ScfDialect;
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);
    const location = ir.Location.getUnknown();
    const word = try arith.getScalarType(&context, .i64);
    const index_type = try arith.getScalarType(&context, .index);
    const buffer = try memref.getMemrefType1D(&context, 1, word, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&context, location);
    var function = try dialects.FuncDialect.FuncOp.create(
        &context,
        location,
        "cas_count",
        &.{},
        &.{word},
    );
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const cells = try memref.AllocaOp.createStatic(&context, location, buffer);
    try entry.addOperation(cells.op);
    const first = try arith.ConstantOp.createInt(&context, location, index_type, 0);
    try entry.addOperation(first.op);
    const start = try arith.ConstantOp.createInt(&context, location, word, 0);
    try entry.addOperation(start.op);
    const clear = try memref.AtomicStoreOp.create(
        &context,
        location,
        start.getResult(),
        cells.getResult(),
        first.getResult(),
        .release,
    );
    try entry.addOperation(clear.op);

    const loop = try scf.WhileOp.create(&context, location, &.{start.getResult()}, &.{word});
    try entry.addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const limit = try arith.ConstantOp.createInt(&context, location, word, 100);
    try before.addOperation(limit.op);
    const below = try arith.CmpOp.create(
        &context,
        location,
        .lt,
        before.arguments.items[0],
        limit.getResult(),
    );
    try before.addOperation(below.op);
    const condition = try scf.ConditionOp.create(
        &context,
        location,
        below.getResult(),
        &.{before.arguments.items[0]},
    );
    try before.addOperation(condition.op);

    const after = loop.getAfterBlock();
    const one = try arith.ConstantOp.createInt(&context, location, word, 1);
    try after.addOperation(one.op);
    const none = try arith.ConstantOp.createInt(&context, location, word, 0);
    try after.addOperation(none.op);
    const seen = try memref.AtomicLoadOp.create(
        &context,
        location,
        cells.getResult(),
        first.getResult(),
        word,
        .acquire,
    );
    try after.addOperation(seen.op);
    const bumped = try arith.AddOp.create(&context, location, seen.getResult(), one.getResult());
    try after.addOperation(bumped.op);
    const exchanged = try memref.AtomicCasOp.createOrdered(
        &context,
        location,
        seen.getResult(),
        bumped.getResult(),
        cells.getResult(),
        first.getResult(),
        word,
        .acq_rel,
    );
    try after.addOperation(exchanged.op);
    const won = try arith.CmpOp.create(
        &context,
        location,
        .eq,
        exchanged.getResult(),
        seen.getResult(),
    );
    try after.addOperation(won.op);
    const step = try arith.SelectOp.create(
        &context,
        location,
        won.getResult(),
        one.getResult(),
        none.getResult(),
    );
    try after.addOperation(step.op);
    const advanced = try arith.AddOp.create(
        &context,
        location,
        after.arguments.items[0],
        step.getResult(),
    );
    try after.addOperation(advanced.op);
    const yield = try scf.YieldOp.create(&context, location, &.{advanced.getResult()});
    try after.addOperation(yield.op);

    const total = try memref.AtomicLoadOp.create(
        &context,
        location,
        cells.getResult(),
        first.getResult(),
        word,
        .seq_cst,
    );
    try entry.addOperation(total.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(&context, location, &.{total.getResult()});
    try entry.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function.op);
    try std.testing.expectEqual(@as(u32, 0), emitter.value_locations.count());
    try std.testing.expectEqual(@as(usize, 0), emitter.value_location_ranges.items.len);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const answer = try onlyResult(&runtime, compiled, "cas_count", &.{});
    try std.testing.expectEqual(@as(i64, 100), try integerOf(answer));
}

test "x86_64 half word compare and swap answers what it saw and writes on a match" {
    if (!executes) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const arith = dialects.ArithDialect;
    const memref = dialects.MemrefDialect;
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);
    const location = ir.Location.getUnknown();
    const half = try arith.getScalarType(&context, .i32);
    const index_type = try arith.getScalarType(&context, .index);
    const buffer = try memref.getMemrefType1D(&context, 2, half, .host);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&context, location);
    var function = try dialects.FuncDialect.FuncOp.create(
        &context,
        location,
        "cas_half",
        &.{},
        &.{half},
    );
    try module.getBodyBlock().addOperation(function.op);
    const block = function.getEntryBlock();
    const cells = try memref.AllocaOp.createStatic(&context, location, buffer);
    try block.addOperation(cells.op);
    const second = try arith.ConstantOp.createInt(&context, location, index_type, 1);
    try block.addOperation(second.op);
    var ints: [7]*ir.Value = undefined;
    for (&ints, [_]i64{ 7, 3, 9, 11, 1, 0, 10 }) |*constant, value| {
        const made = try arith.ConstantOp.createInt(&context, location, half, value);
        try block.addOperation(made.op);
        constant.* = made.getResult();
    }
    const seven, const three, const nine, const eleven, const one, const zero, const ten = ints;
    const hundred = try arith.MulOp.create(&context, location, ten, ten);
    try block.addOperation(hundred.op);

    const published = try memref.AtomicStoreOp.create(
        &context,
        location,
        seven,
        cells.getResult(),
        second.getResult(),
        .seq_cst,
    );
    try block.addOperation(published.op);
    const missed = try memref.AtomicCasOp.create(
        &context,
        location,
        three,
        nine,
        cells.getResult(),
        second.getResult(),
        half,
    );
    try block.addOperation(missed.op);
    const kept = try memref.AtomicLoadOp.create(
        &context,
        location,
        cells.getResult(),
        second.getResult(),
        half,
        .acquire,
    );
    try block.addOperation(kept.op);
    const matched = try memref.AtomicCasOp.createOrdered(
        &context,
        location,
        seven,
        eleven,
        cells.getResult(),
        second.getResult(),
        half,
        .release,
    );
    try block.addOperation(matched.op);
    const fence = try memref.FenceOp.create(&context, location, .system, .seq_cst);
    try block.addOperation(fence.op);
    const written = try memref.AtomicLoadOp.create(
        &context,
        location,
        cells.getResult(),
        second.getResult(),
        half,
        .seq_cst,
    );
    try block.addOperation(written.op);

    const miss_flag = try arith.CmpOp.create(&context, location, .eq, missed.getResult(), three);
    try block.addOperation(miss_flag.op);
    const miss_bit = try arith.SelectOp.create(
        &context,
        location,
        miss_flag.getResult(),
        one,
        zero,
    );
    try block.addOperation(miss_bit.op);
    const match_flag = try arith.CmpOp.create(&context, location, .eq, matched.getResult(), seven);
    try block.addOperation(match_flag.op);
    const match_bit = try arith.SelectOp.create(
        &context,
        location,
        match_flag.getResult(),
        one,
        zero,
    );
    try block.addOperation(match_bit.op);

    var digits = [_]*ir.Value{
        missed.getResult(),
        kept.getResult(),
        matched.getResult(),
        written.getResult(),
    };
    var packed_value = miss_bit.getResult();
    for (&digits) |digit| {
        const shifted = try arith.MulOp.create(
            &context,
            location,
            packed_value,
            hundred.getResult(),
        );
        try block.addOperation(shifted.op);
        const added = try arith.AddOp.create(&context, location, shifted.getResult(), digit);
        try block.addOperation(added.op);
        packed_value = added.getResult();
    }
    const flagged = try arith.MulOp.create(&context, location, packed_value, ten);
    try block.addOperation(flagged.op);
    const answer_value = try arith.AddOp.create(
        &context,
        location,
        flagged.getResult(),
        match_bit.getResult(),
    );
    try block.addOperation(answer_value.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(
        &context,
        location,
        &.{answer_value.getResult()},
    );
    try block.addOperation(ret.op);

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const answer = try onlyResult(&runtime, compiled, "cas_half", &.{});
    try std.testing.expectEqual(@as(i64, 70_707_111), try integerOf(answer));
}

test "x86_64 atomic operations lower to the instructions their orderings need" {
    if (!executes) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const arith = dialects.ArithDialect;
    const memref = dialects.MemrefDialect;
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);
    const location = ir.Location.getUnknown();
    const word = try arith.getScalarType(&context, .i64);
    const half = try arith.getScalarType(&context, .i32);
    const index_type = try arith.getScalarType(&context, .index);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&context, location);
    var function = try dialects.FuncDialect.FuncOp.create(
        &context,
        location,
        "atomic_windows",
        &.{},
        &.{},
    );
    try module.getBodyBlock().addOperation(function.op);
    const block = function.getEntryBlock();
    const words = try memref.AllocaOp.createStatic(
        &context,
        location,
        try memref.getMemrefType1D(&context, 2, word, .host),
    );
    try block.addOperation(words.op);
    const halves = try memref.AllocaOp.createStatic(
        &context,
        location,
        try memref.getMemrefType1D(&context, 2, half, .host),
    );
    try block.addOperation(halves.op);
    const slot = try arith.ConstantOp.createInt(&context, location, index_type, 1);
    try block.addOperation(slot.op);
    const w = try arith.ConstantOp.createInt(&context, location, word, 5);
    try block.addOperation(w.op);
    const h = try arith.ConstantOp.createInt(&context, location, half, 5);
    try block.addOperation(h.op);

    const operations = [_]*ir.Operation{
        (try memref.AtomicLoadOp.create(
            &context,
            location,
            words.getResult(),
            slot.getResult(),
            word,
            .acquire,
        )).op,
        (try memref.AtomicLoadOp.create(
            &context,
            location,
            halves.getResult(),
            slot.getResult(),
            half,
            .seq_cst,
        )).op,
        (try memref.AtomicStoreOp.create(
            &context,
            location,
            w.getResult(),
            words.getResult(),
            slot.getResult(),
            .release,
        )).op,
        (try memref.AtomicStoreOp.create(
            &context,
            location,
            w.getResult(),
            words.getResult(),
            slot.getResult(),
            .seq_cst,
        )).op,
        (try memref.AtomicStoreOp.create(
            &context,
            location,
            h.getResult(),
            halves.getResult(),
            slot.getResult(),
            .release,
        )).op,
        (try memref.AtomicStoreOp.create(
            &context,
            location,
            h.getResult(),
            halves.getResult(),
            slot.getResult(),
            .seq_cst,
        )).op,
        (try memref.AtomicCasOp.create(
            &context,
            location,
            w.getResult(),
            w.getResult(),
            words.getResult(),
            slot.getResult(),
            word,
        )).op,
        (try memref.AtomicCasOp.createOrdered(
            &context,
            location,
            h.getResult(),
            h.getResult(),
            halves.getResult(),
            slot.getResult(),
            half,
            .acquire,
        )).op,
        (try memref.FenceOp.create(&context, location, .device, .acquire)).op,
        (try memref.FenceOp.create(&context, location, .workgroup, .release)).op,
        (try memref.FenceOp.create(&context, location, .system, .acq_rel)).op,
        (try memref.FenceOp.create(&context, location, .device, .seq_cst)).op,
    };
    for (operations) |op| try block.addOperation(op);
    const ret = try dialects.FuncDialect.ReturnOp.create(&context, location, &.{});
    try block.addOperation(ret.op);

    var emitter = x86_64.Emitter.init(allocator);
    defer emitter.deinit();
    try emitter.emitFunction(function.op);
    const code = emitter.code.items;
    const windows = [_][]const u8{
        &.{ 0x48, 0x8B, 0x04, 0xD1 },
        &.{ 0x8B, 0x04, 0x91 },
        &.{ 0x4C, 0x89, 0x04, 0xD1 },
        &.{ 0x4C, 0x87, 0x04, 0xD1 },
        &.{ 0x44, 0x89, 0x04, 0x91 },
        &.{ 0x44, 0x87, 0x04, 0x91 },
        &.{ 0xF0, 0x4C, 0x0F, 0xB1, 0x04, 0xD1 },
        &.{ 0xF0, 0x44, 0x0F, 0xB1, 0x04, 0x91 },
    };
    var cursor: usize = 0;
    for (windows) |window| {
        const found = std.mem.indexOfPos(u8, code, cursor, window) orelse
            return error.TestExpectedEqual;
        cursor = found + window.len;
    }
    const mfence = [_]u8{ 0x0F, 0xAE, 0xF0 };
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, &mfence));
    try std.testing.expect(std.mem.indexOfPos(u8, code, cursor, &mfence) != null);
}

test "x86_64 scf while condition survives an operation between the compare and the condition" {
    if (!executes) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const arith = dialects.ArithDialect;
    const scf = dialects.ScfDialect;
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);
    const location = ir.Location.getUnknown();
    const word = try arith.getScalarType(&context, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&context, location);
    var function = try dialects.FuncDialect.FuncOp.create(
        &context,
        location,
        "separated",
        &.{},
        &.{word},
    );
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const start = try arith.ConstantOp.createInt(&context, location, word, 0);
    try entry.addOperation(start.op);
    const loop = try scf.WhileOp.create(&context, location, &.{start.getResult()}, &.{word});
    try entry.addOperation(loop.op);
    const before = loop.getBeforeBlock();
    const limit = try arith.ConstantOp.createInt(&context, location, word, 5);
    try before.addOperation(limit.op);
    const below = try arith.CmpOp.create(
        &context,
        location,
        .lt,
        before.arguments.items[0],
        limit.getResult(),
    );
    try before.addOperation(below.op);
    const one = try arith.ConstantOp.createInt(&context, location, word, 1);
    try before.addOperation(one.op);
    const next = try arith.AddOp.create(
        &context,
        location,
        before.arguments.items[0],
        one.getResult(),
    );
    try before.addOperation(next.op);
    const condition = try scf.ConditionOp.create(
        &context,
        location,
        below.getResult(),
        &.{next.getResult()},
    );
    try before.addOperation(condition.op);
    const after = loop.getAfterBlock();
    const yield = try scf.YieldOp.create(&context, location, &.{after.arguments.items[0]});
    try after.addOperation(yield.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(
        &context,
        location,
        &.{loop.op.getResult(0).?},
    );
    try entry.addOperation(ret.op);
    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const answer = try onlyResult(&runtime, compiled, "separated", &.{});
    try std.testing.expectEqual(@as(i64, 6), try integerOf(answer));
}

const BranchShape = enum { fused, separated };

/// Builds `name(a, b) = if a <pred> b { 1 } else { 0 }`. The separated shape puts an addition
/// between the comparison and the branch, which writes the flags, so the comparison has to keep
/// its materialized boolean.
fn buildPredicateBranch(
    context: *ir.Context,
    module: @import("../../dialects/root.zig").BuiltinDialect.ModuleOp,
    name: []const u8,
    predicate: @import("../../dialects/root.zig").arith.CmpPredicate,
    shape: BranchShape,
) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const arith = dialects.ArithDialect;
    const scf = dialects.ScfDialect;
    const location = ir.Location.getUnknown();
    const word = try arith.getScalarType(context, .i64);
    var function = try dialects.FuncDialect.FuncOp.create(
        context,
        location,
        name,
        &.{ word, word },
        &.{word},
    );
    try module.getBodyBlock().addOperation(function.op);
    const entry = function.getEntryBlock();
    const compare = try arith.CmpOp.create(
        context,
        location,
        predicate,
        function.getArgument(0),
        function.getArgument(1),
    );
    try entry.addOperation(compare.op);
    var carried = function.getArgument(0);
    if (shape == .separated) {
        const sum = try arith.AddOp.create(
            context,
            location,
            function.getArgument(0),
            function.getArgument(1),
        );
        try entry.addOperation(sum.op);
        carried = sum.getResult();
    }
    const branch = try scf.IfOp.create(context, location, compare.getResult(), &.{word});
    try entry.addOperation(branch.op);
    const yes = try arith.ConstantOp.createInt(context, location, word, 1);
    try branch.getThenBlock().addOperation(yes.op);
    try branch.getThenBlock().addOperation(
        (try scf.YieldOp.create(context, location, &.{yes.getResult()})).op,
    );
    const no = try arith.ConstantOp.createInt(context, location, word, 0);
    try branch.getElseBlock().?.addOperation(no.op);
    try branch.getElseBlock().?.addOperation(
        (try scf.YieldOp.create(context, location, &.{no.getResult()})).op,
    );
    const answer = try arith.AddOp.create(context, location, branch.op.getResult(0).?, carried);
    try entry.addOperation(answer.op);
    const difference = try arith.SubOp.create(context, location, answer.getResult(), carried);
    try entry.addOperation(difference.op);
    const returned = [_]*ir.Value{difference.getResult()};
    const ret = try dialects.FuncDialect.ReturnOp.create(context, location, &returned);
    try entry.addOperation(ret.op);
    return function.op;
}

/// Whether `code` holds a `setcc` (0F 90 through 0F 9F), the instruction that turns flags into
/// a boolean. A byte scan can see one inside an immediate, so a caller asserting absence must own
/// code without such immediates.
fn containsSetcc(code: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, code, at, 0x0F)) |found| : (at = found + 1) {
        if (found + 1 == code.len) return false;
        if (code[found + 1] >= 0x90 and code[found + 1] <= 0x9F) return true;
    }
    return false;
}

fn predicateHolds(
    predicate: @import("../../dialects/root.zig").arith.CmpPredicate,
    a: i64,
    b: i64,
) bool {
    const ua: u64 = @bitCast(a);
    const ub: u64 = @bitCast(b);
    return switch (predicate) {
        .eq => a == b,
        .ne => a != b,
        .lt, .slt => a < b,
        .le, .sle => a <= b,
        .gt, .sgt => a > b,
        .ge, .sge => a >= b,
        .ult => ua < ub,
        .ule => ua <= ub,
        .ugt => ua > ub,
        .uge => ua >= ub,
    };
}

test "x86_64 a comparison only a branch reads decides from the flags what its boolean did" {
    if (!executes) return error.SkipZigTest;
    const dialects = @import("../../dialects/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);
    const module = try dialects.BuiltinDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const predicates = std.enums.values(dialects.arith.CmpPredicate);
    var names: [2][16][24]u8 = undefined;
    var name_lengths: [2][16]usize = undefined;
    std.debug.assert(predicates.len <= 16);

    for (predicates, 0..) |predicate, index| {
        for ([_]BranchShape{ .fused, .separated }, 0..) |shape, shape_index| {
            const name = try std.fmt.bufPrint(
                &names[shape_index][index],
                "{s}_{s}",
                .{ @tagName(shape), @tagName(predicate) },
            );
            name_lengths[shape_index][index] = name.len;
            const function = try buildPredicateBranch(&context, module, name, predicate, shape);
            var emitter = x86_64.Emitter.init(allocator);
            defer emitter.deinit();
            try emitter.emitFunction(function);
            const code = emitter.code.items;
            const compare_result = function.getRegion(0).?.getEntryBlock().?.operations.head.?;
            const compare_op: *ir.Operation = @ptrCast(@alignCast(compare_result));
            const materialized = containsSetcc(code);
            switch (shape) {
                .fused => {
                    try std.testing.expect(!materialized);
                    try std.testing.expect(!emitter.slot_map.contains(compare_op.getResult(0).?));
                },
                .separated => try std.testing.expect(materialized),
            }
        }
    }

    var runtime = try Runtime.init(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const samples = [_]i64{ std.math.minInt(i64), -7, -1, 0, 1, 7, std.math.maxInt(i64) };
    for (predicates, 0..) |predicate, index| {
        for (0..2) |shape_index| {
            const name = names[shape_index][index][0..name_lengths[shape_index][index]];
            for (samples) |a| for (samples) |b| {
                const arguments = [_]execution.Value{ .{ .i64 = a }, .{ .i64 = b } };
                const answer = try onlyResult(&runtime, compiled, name, &arguments);
                const expected: i64 = @intFromBool(predicateHolds(predicate, a, b));
                try std.testing.expectEqual(expected, try integerOf(answer));
            };
        }
    }
}

fn onlyResult(
    runtime: *const Runtime,
    compiled: execution.Handle,
    name: []const u8,
    args: []const execution.Value,
) !execution.Value {
    var results: [1]execution.Value = undefined;
    try runtime.call(compiled, name, args, &results);
    return results[0];
}

fn vectorResult(
    runtime: *const Runtime,
    compiled: execution.Handle,
    name: []const u8,
) !execution.Vector {
    return switch (try onlyResult(runtime, compiled, name, &.{})) {
        .vector => |vector| vector,
        else => error.TestFailure,
    };
}

fn integerOf(value: execution.Value) !i64 {
    return switch (value) {
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32 => |integer| integer,
        .u64, .index => |word| @bitCast(word),
        .bool => |flag| @intFromBool(flag),
        else => error.NoIntResult,
    };
}

fn floatOf(value: execution.Value) !f64 {
    return switch (value) {
        inline .f32, .f64 => |float| float,
        else => error.NoFloatResult,
    };
}

/// Builds a module whose one function stores through a `memref.subview`, which
/// is the shape `legalizeMemrefViews` rewrites and therefore allocates for: it
/// parses the subview's shape and stride out of its layout attributes.
fn buildViewModule(ctx: *ir.Context) !*ir.Operation {
    const dialects = @import("../../dialects/root.zig");
    const loc = ir.Location.getUnknown();

    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const index_type = try dialects.ArithDialect.getIndexType(ctx);
    const source_type = try dialects.MemrefDialect.getMemrefType1D(ctx, 8, i64_type, .host);
    const view_type = try dialects.MemrefDialect.getMemrefType1D(ctx, 4, i64_type, .host);

    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    const module_block = module.getBodyBlock();
    var func = try dialects.FuncDialect.FuncOp.create(ctx, loc, "through_view", &.{i64_type}, &.{});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    var zero = try dialects.ArithDialect.ConstantOp.createInt(ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    var storage = try dialects.MemrefDialect.AllocaOp.createStatic(ctx, loc, source_type);
    try entry.addOperation(storage.op);
    var subview = try dialects.MemrefDialect.SubviewOp.create(
        ctx,
        loc,
        storage.getResult(),
        view_type,
    );
    try dialects.MemrefDialect.setLayoutAttrs(subview.op, ctx, .{
        .offset = 1,
        .shape = &.{4},
        .stride = &.{1},
    });
    try entry.addOperation(subview.op);
    const stored = try dialects.MemrefDialect.StoreOp.create(
        ctx,
        loc,
        func.getArgument(0),
        subview.getResult(),
        zero.getResult(),
    );
    try entry.addOperation(stored.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{});
    try entry.addOperation(ret.op);
    return module.op;
}

/// The number of allocations `Backend.init` spends, so a test can fail the one
/// after them. That one is necessarily the first allocation view legalization
/// asks for, because legalization is the first thing `lower` runs.
fn backendInitAllocations(allocator: std.mem.Allocator, ctx: *ir.Context) !usize {
    var counter = std.testing.FailingAllocator.init(allocator, .{});
    var probe = try Backend.init(counter.allocator(), ctx);
    probe.deinit();
    return counter.alloc_index;
}

test "x86_64 view legalization that cannot allocate answers a shortfall and not a refusal" {
    const dialects = @import("../../dialects/root.zig");
    const allocator = std.testing.allocator;

    var ir_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ir_ctx.deinit(allocator);
    try dialects.registerAllDialects(&ir_ctx);

    const for_pass = try buildViewModule(&ir_ctx);
    var first = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        passes.memref_views.legalizeMemrefViews(for_pass, first.allocator()),
    );

    const spent = try backendInitAllocations(allocator, &ir_ctx);
    const for_backend = try buildViewModule(&ir_ctx);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = spent });
    var backend = try Backend.init(failing.allocator(), &ir_ctx);
    defer backend.deinit();
    try std.testing.expectError(error.OutOfMemory, backend.lower(for_backend));
}
