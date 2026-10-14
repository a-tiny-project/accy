//! IR modules and memory probes that execution tests share. Test support only: nothing a
//! consumer reaches imports this.

const std = @import("std");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");
const backends = @import("../../root.zig");
const artifact = backends.artifact;
const machine = backends.machine_code;
const sys = @import("sys");
const Handle = @import("../image.zig").Handle;
const execution = @import("../root.zig");

/// A host function compiled code calls as an external symbol.
/// The native runtime a test product builds. These witnesses belong to an inspected product,
/// and on macOS that product declares the non-hardened publication policy, which ordinary
/// `init` never assumes for an Apple host.
pub fn nativeRuntime(
    allocator: std.mem.Allocator,
    limits: execution.Limits,
) execution.InitError!execution.native.Runtime {
    if (comptime sys.capabilities.current.os == .macos) {
        return execution.native.Runtime.initWithExecutablePolicy(
            allocator,
            limits,
            .macos_non_hardened,
        );
    }
    return execution.native.Runtime.init(allocator, limits);
}

pub fn declAdd1(value: i64) callconv(.c) i64 {
    return value + 1;
}

/// The signature of a function of no arguments returning one `i64`.
pub const nullary_integer = artifact.Signature.init(&.{}, &.{.{ .scalar = .i64 }}) catch unreachable;

/// How many operations a context holds, to show a compile left the IR as it found it.
pub const IrResourceCounts = struct {
    operations: usize,

    pub fn capture(ctx: *const ir.Context) IrResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    pub fn expectEqual(self: IrResourceCounts, ctx: *const ir.Context) !void {
        try std.testing.expectEqual(self.operations, ctx.operationCount());
    }
};

/// Builds `name` returning `value`.
pub fn constantFunction(ctx: *ir.Context, name: []const u8, value: i64) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("temporary-jit.choir", 1, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const constant = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, value);
    try entry.addOperation(constant.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{constant.getResult()});
    try entry.addOperation(ret.op);
    return func.op;
}

/// Builds `name` returning what `callee` returns.
pub fn callingFunction(ctx: *ir.Context, name: []const u8, callee: []const u8) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("temporary-jit.choir", 3, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const call = try FuncDialect.CallOp.create(ctx, loc, callee, &.{}, &.{i64_type});
    try entry.addOperation(call.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{call.getResult(0).?});
    try entry.addOperation(ret.op);
    return func.op;
}

/// A module holding one `constantFunction`.
pub fn constantModule(ctx: *ir.Context, name: []const u8, value: i64) !*ir.Operation {
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, ir.Location.getUnknown());
    errdefer module.op.erase();
    const function = try constantFunction(ctx, name, value);
    errdefer function.erase();
    try module.getBodyBlock().addOperation(function);
    return module.op;
}

/// A module holding `name`, which returns its memref argument.
pub fn memrefIdentityModule(ctx: *ir.Context, name: []const u8) !*ir.Operation {
    const i32_type = try dialects.ArithDialect.getScalarType(ctx, .i32);
    const memref_type = try dialects.MemrefDialect.getMemrefType1D(ctx, 4, i32_type, .host);
    const loc = ir.Location.getFile("temporary-jit.choir", 2, 1);
    const types = [_]ir.Type{memref_type};
    const function = try dialects.FuncDialect.FuncOp.create(ctx, loc, name, &types, &types);
    errdefer function.op.erase();
    const ret = try dialects.FuncDialect.ReturnOp.create(ctx, loc, &.{function.getArgument(0)});
    try function.getEntryBlock().addOperation(ret.op);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, loc);
    errdefer module.op.erase();
    try module.getBodyBlock().addOperation(function.op);
    return module.op;
}

/// Appends an integer constant that carries the attributes of `symbol`, so it evaluates to the
/// address of the bytes instead of its value, 7.
pub fn appendDataConstant(
    ctx: *ir.Context,
    block: *ir.Block,
    symbol: machine.DataSymbol,
) !*ir.Value {
    const ArithDialect = dialects.ArithDialect;
    const names = machine.data_symbol_attr_names;
    const loc = ir.Location.getFile("data-jit.choir", 2, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const constant = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 7);
    try block.addOperation(constant.op);
    try constant.op.setAttr(names.name, try ctx.getStringAttr(symbol.name));
    try constant.op.setAttr(names.bytes, try ctx.getStringAttr(symbol.bytes));
    try constant.op.setAttr(names.alignment, try ctx.getI64Attr(@intCast(symbol.alignment)));
    return constant.getResult();
}

/// Builds `name` returning the address of `symbol`.
pub fn dataFunction(
    ctx: *ir.Context,
    name: []const u8,
    symbol: machine.DataSymbol,
) !*ir.Operation {
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("data-jit.choir", 1, 1);
    const i64_type = try dialects.ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const address = try appendDataConstant(ctx, entry, symbol);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{address});
    try entry.addOperation(ret.op);
    return func.op;
}

/// Builds `name` returning `(address + delta) - address` for the address of `symbol`.
pub fn dataDeltaFunction(
    ctx: *ir.Context,
    name: []const u8,
    symbol: machine.DataSymbol,
    delta: i64,
) !*ir.Operation {
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const loc = ir.Location.getFile("data-jit.choir", 3, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{}, &.{i64_type});
    errdefer func.op.erase();
    const entry = func.getEntryBlock();
    const address = try appendDataConstant(ctx, entry, symbol);
    const offset = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, delta);
    try entry.addOperation(offset.op);
    const sum = try ArithDialect.AddOp.create(ctx, loc, address, offset.getResult());
    try entry.addOperation(sum.op);
    const difference = try ArithDialect.SubOp.create(ctx, loc, sum.getResult(), address);
    try entry.addOperation(difference.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{difference.getResult()});
    try entry.addOperation(ret.op);
    return func.op;
}

/// A module holding one `dataFunction`.
pub fn dataModule(
    ctx: *ir.Context,
    name: []const u8,
    symbol: machine.DataSymbol,
) !*ir.Operation {
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, ir.Location.getUnknown());
    errdefer module.op.erase();
    const function = try dataFunction(ctx, name, symbol);
    errdefer function.erase();
    try module.getBodyBlock().addOperation(function);
    return module.op;
}

/// A module holding one function, `name(x: i64) -> i64`, whose body is a single `scf.while`
/// carrying `count` copies of `x`. Its condition is false, so the loop runs no iteration and the
/// function returns `x`. It is the shape `Bounds.while_values` bounds.
pub fn carryingModule(
    ctx: *ir.Context,
    allocator: std.mem.Allocator,
    name: []const u8,
    count: usize,
) !*ir.Operation {
    std.debug.assert(count > 0);
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;
    const loc = ir.Location.getFile("temporary-jit.choir", 5, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, ir.Location.getUnknown());
    errdefer module.op.erase();
    const func = try FuncDialect.FuncOp.create(ctx, loc, name, &.{i64_type}, &.{i64_type});
    try addFunction(module.op, func.op);

    const inits = try allocator.alloc(*ir.Value, count);
    defer allocator.free(inits);
    @memset(inits, func.getArgument(0));
    const types = try allocator.alloc(ir.Type, count);
    defer allocator.free(types);
    @memset(types, i64_type);
    const loop = try ScfDialect.WhileOp.create(ctx, loc, inits, types);
    const entry = func.getEntryBlock();
    try entry.addOperation(loop.op);

    const before = loop.getBeforeBlock();
    const stop = try ArithDialect.ConstantOp.createBool(ctx, loc, false);
    try before.addOperation(stop.op);
    const carried = before.arguments.items;
    const condition = try ScfDialect.ConditionOp.create(ctx, loc, stop.getResult(), carried);
    try before.addOperation(condition.op);
    const after = loop.getAfterBlock();
    const yield = try ScfDialect.YieldOp.create(ctx, loc, after.arguments.items);
    try after.addOperation(yield.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{loop.op.getResult(0).?});
    try entry.addOperation(ret.op);
    return module.op;
}

/// A module holding `count` on one axis of `execution.Bounds`: `count` constants for operations
/// and values, `count` nested `scf.if`s for control depth, one `scf.if` yielding `count` values,
/// `count` defined functions, a function taking `count` parameters, a call to a declared
/// function passing `count` arguments, or a `func.syscall` passing `count` arguments. Every
/// function it defines answers 7, or what its call or syscall answers.
pub fn axisModule(
    ctx: *ir.Context,
    allocator: std.mem.Allocator,
    bound: execution.Bound,
    count: usize,
) !*ir.Operation {
    std.debug.assert(count > 0);
    const ArithDialect = dialects.ArithDialect;
    const FuncDialect = dialects.FuncDialect;
    const ScfDialect = dialects.ScfDialect;
    const loc = ir.Location.getFile("temporary-jit.choir", 6, 1);
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);
    const module = try dialects.BuiltinDialect.ModuleOp.create(ctx, ir.Location.getUnknown());
    errdefer module.op.erase();
    if (bound == .module_functions) {
        for (0..count) |index| {
            var spelled: [24]u8 = undefined;
            const name = try std.fmt.bufPrint(&spelled, "axis{d}", .{index});
            try addFunction(module.op, try constantFunction(ctx, name, 7));
        }
        return module.op;
    }

    const words = try allocator.alloc(ir.Type, count);
    defer allocator.free(words);
    @memset(words, i64_type);
    const parameters: []const ir.Type = if (bound == .parameters) words else &.{};
    const func = try FuncDialect.FuncOp.create(ctx, loc, "axis", parameters, &.{i64_type});
    try addFunction(module.op, func.op);
    const entry = func.getEntryBlock();
    const seven = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, 7);
    try entry.addOperation(seven.op);
    var answer = seven.getResult();
    switch (bound) {
        .parameters => {},
        .call_arguments => {
            const arguments = try allocator.alloc(*ir.Value, count);
            defer allocator.free(arguments);
            @memset(arguments, seven.getResult());
            const wide = try FuncDialect.FuncOp.createDeclaration(ctx, loc, "wide", words, &.{i64_type});
            try addFunction(module.op, wide.op);
            const call = try FuncDialect.CallOp.create(ctx, loc, "wide", arguments, &.{i64_type});
            try entry.addOperation(call.op);
            answer = call.getResult(0).?;
        },
        .syscall_arguments => {
            // `SyscallOp.create` refuses past the kernel's registers, so a program past them is
            // built from the operation's bare state, which only the verifier checks.
            const operands = try allocator.alloc(*ir.Value, count + 1);
            defer allocator.free(operands);
            @memset(operands, seven.getResult());
            var state = ir.Operation.State.init(FuncDialect.SyscallOp.operation_name, loc);
            state.addOperands(operands);
            state.addTypes(&.{i64_type});
            const syscall = try ctx.createOperation(state);
            try entry.addOperation(syscall);
            answer = syscall.getResult(0).?;
        },
        .operations, .values => for (1..count) |index| {
            const filler = try ArithDialect.ConstantOp.createInt(ctx, loc, i64_type, @intCast(index));
            try entry.addOperation(filler.op);
        },
        .control_depth => {
            const truth = try ArithDialect.ConstantOp.createBool(ctx, loc, true);
            try entry.addOperation(truth.op);
            var block = entry;
            var opened = std.ArrayListUnmanaged(*ir.Block).empty;
            defer opened.deinit(allocator);
            for (0..count) |_| {
                const branch = try ScfDialect.IfOp.createWithoutElse(ctx, loc, truth.getResult());
                try block.addOperation(branch.op);
                block = branch.getThenBlock();
                try opened.append(allocator, block);
            }
            for (opened.items) |nested| {
                const yield = try ScfDialect.YieldOp.create(ctx, loc, &.{});
                try nested.addOperation(yield.op);
            }
        },
        .yielded_values => {
            const truth = try ArithDialect.ConstantOp.createBool(ctx, loc, true);
            try entry.addOperation(truth.op);
            const types = try allocator.alloc(ir.Type, count);
            defer allocator.free(types);
            @memset(types, i64_type);
            const values = try allocator.alloc(*ir.Value, count);
            defer allocator.free(values);
            @memset(values, seven.getResult());
            const branch = try ScfDialect.IfOp.create(ctx, loc, truth.getResult(), types);
            try entry.addOperation(branch.op);
            for ([_]*ir.Block{ branch.getThenBlock(), branch.getElseBlock().? }) |arm| {
                const yield = try ScfDialect.YieldOp.create(ctx, loc, values);
                try arm.addOperation(yield.op);
            }
            answer = branch.op.getResult(0).?;
        },
        else => unreachable,
    }
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{answer});
    try entry.addOperation(ret.op);
    return module.op;
}

/// Appends `function` to `module`, erasing it if that fails.
pub fn addFunction(module: *ir.Operation, function: *ir.Operation) !void {
    errdefer function.erase();
    try module.getRegion(0).?.getEntryBlock().?.addOperation(function);
}

/// Calls `name`, a function of no arguments returning an address, and returns that address.
pub fn addressFrom(runtime: anytype, handle: Handle, name: []const u8) !usize {
    const Address = *const fn () callconv(.c) i64;
    return @intCast((try runtime.getFunction(handle, name, Address))());
}

/// The `len` bytes at `address`.
pub fn bytesAt(address: usize, len: usize) []const u8 {
    const bytes: [*]const u8 = @ptrFromInt(address);
    return bytes[0..len];
}

/// This process's `/proc/self/maps`, owned by the caller.
pub fn readProcSelfMaps(allocator: std.mem.Allocator) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, "/proc/self/maps", .{});
    defer file.close(std.Options.debug_io);
    var maps: std.ArrayList(u8) = .empty;
    errdefer maps.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try sys.fd.read(file.handle, &buffer);
        if (count == 0) break;
        try maps.appendSlice(allocator, buffer[0..count]);
    }
    return try maps.toOwnedSlice(allocator);
}

/// Returns the permission field of the `/proc/self/maps` line whose range holds `address`.
pub fn mappingPermissions(maps: []const u8, address: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse continue;
        const permissions = fields.next() orelse continue;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = std.fmt.parseInt(usize, range[0..dash], 16) catch continue;
        const end = std.fmt.parseInt(usize, range[dash + 1 ..], 16) catch continue;
        if (start <= address and address < end) return permissions;
    }
    return null;
}
