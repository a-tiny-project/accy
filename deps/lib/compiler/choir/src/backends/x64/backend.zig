const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const contract = @import("../root.zig").contract;
const artifact = @import("../root.zig").artifact;
const interface = @import("../root.zig").interface;
const machine = @import("../root.zig").machine_code;
const passes = @import("../../passes/root.zig");
const execution = @import("../execution/root.zig");
const execution_fixture = @import("../execution/fixture/root.zig");
const object = @import("object.zig");
const x86_64 = @import("root.zig");
const sys = @import("sys");

const BackendError = interface.BackendError;
const Allocator = std.mem.Allocator;

const profile = sys.capabilities.current;
const executes = (profile.os == .linux or profile.os == .macos) and
    profile.arch == .x86_64 and profile.pointerWidthBits() == 64;
const Runtime = execution.native.Runtime;

pub const ModuleObjectCompileOptions = struct {
    max_threads: usize = 1,
    worker_allocator: ?Allocator = null,
    pool: ?*ir.ThreadingPool = null,
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
        return lowerModule(self.allocator, module, diagnostic, null);
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
            .pool = options.pool,
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
/// `Backend` and the execution target lower through this one sequence. A non-null `refused`
/// receives the operation verification or legality refused and, past a bound, its figures.
pub fn lowerModule(
    allocator: Allocator,
    module: *ir.Operation,
    diagnostic: ?*contract.VerificationDiagnostic,
    refused: ?*execution.Refused,
) BackendError!*ir.Operation {
    passes.memref_views.legalizeMemrefViews(module, allocator) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        else => return BackendError.CodeGenFailed,
    };
    _ = passes.promotion.promote(module, allocator) catch |err| switch (err) {
        error.OutOfMemory => return BackendError.OutOfMemory,
        error.InvalidPromotion => return BackendError.CodeGenFailed,
    };
    var verification: contract.VerificationDiagnostic = .{};
    contract.verifyModuleWithDiagnostic(verify_stage, module, &verification) catch |err| {
        if (diagnostic) |captured| captured.* = verification;
        if (refused) |into| {
            if (verification.failure) |failure| into.* = verificationRefusal(failure.operation);
        }
        return err;
    };
    try x86_64.legality.checkModule(module, refused);
    return module;
}

/// The refusal a verifier failure at `op` makes. The dialect refuses a `func.syscall` past the
/// kernel's argument registers before legality runs, and those registers are this target's
/// syscall bound, so that refusal carries the target's figures.
fn verificationRefusal(op: *ir.Operation) execution.Refused {
    const FuncDialect = @import("../../dialects/root.zig").FuncDialect;
    if (!std.mem.eql(u8, op.name.name, FuncDialect.SyscallOp.operation_name) or op.operands.items.len == 0)
        return .{ .operation = op };
    const arguments = op.operands.items.len - 1;
    return .{
        .operation = op,
        .excess = execution.Excess.of(.syscall_arguments, x86_64.bounds.syscall_arguments.?, 0, arguments),
    };
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) FT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec_result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec_result);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(result);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const result = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(result);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec = try onlyResult(&runtime, compiled, name, &.{});
    return integerOf(exec);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);

    const FnPtr = *const fn () callconv(.c) FT;
    const fn_ptr = try runtime.getFunction(compiled, name, FnPtr);
    return fn_ptr();
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

    var runtime = try execution_fixture.nativeRuntime(allocator, .testing);
    defer runtime.deinit();
    const compiled = try runtime.compile(module.op);
    const exec_result = try onlyResult(&runtime, compiled, name, &.{});
    const got = try floatOf(exec_result);
    try std.testing.expectApproxEqAbs(expected, got, tol);
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
