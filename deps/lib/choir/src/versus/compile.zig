const std = @import("std");
const alloc_arena = @import("alloc_arena");
const dialects = @import("../dialects/root.zig");
const ir = @import("../core/root.zig");

const ArithDialect = dialects.ArithDialect;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const ScfDialect = dialects.ScfDialect;

pub const Shape = enum {
    arith_chain,
    fold_cse_grid,
    control_loop,
    symbol_call_forest,

    pub fn name(self: Shape) []const u8 {
        return switch (self) {
            .arith_chain => "arith_chain",
            .fold_cse_grid => "fold_cse_grid",
            .control_loop => "control_loop",
            .symbol_call_forest => "symbol_call_forest",
        };
    }
};

pub const Workload = struct {
    name: []const u8,
    shape: Shape,
    functions: u32,
    ops_per_function: u32,

    pub fn sourceOps(self: Workload) u64 {
        return @as(u64, self.functions) * @as(u64, self.ops_per_function);
    }
};

pub const matrix = [_]Workload{
    .{ .name = "compile_arith_1x32", .shape = .arith_chain, .functions = 1, .ops_per_function = 32 },
    .{ .name = "compile_arith_8x128", .shape = .arith_chain, .functions = 8, .ops_per_function = 128 },
    .{ .name = "compile_foldcse_4x64", .shape = .fold_cse_grid, .functions = 4, .ops_per_function = 64 },
    .{ .name = "compile_control_4x32", .shape = .control_loop, .functions = 4, .ops_per_function = 32 },
    .{ .name = "compile_calls_8x32", .shape = .symbol_call_forest, .functions = 8, .ops_per_function = 32 },
};

pub fn byName(name: []const u8) ?Workload {
    for (matrix) |workload| {
        if (std.mem.eql(u8, workload.name, name)) return workload;
    }
    return null;
}

pub fn build(ctx: *ir.Context, workload: Workload) !BuiltinDialect.ModuleOp {
    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(ctx, loc);
    const i32_type = try ArithDialect.getScalarType(ctx, .i32);
    const module_block = module.getBodyBlock();

    for (0..workload.functions) |function_index_usize| {
        const function_index: u32 = @intCast(function_index_usize);
        const name = try std.fmt.allocPrint(ir.context.transientAllocator(ctx), "compile_f_{d}", .{function_index});
        const func = try FuncDialect.FuncOp.create(
            ctx,
            loc,
            name,
            &.{ i32_type, i32_type },
            &.{i32_type},
        );
        try module_block.addOperation(func.op);
        try populateFunction(ctx, loc, func, i32_type, workload, function_index);
    }

    return module;
}

fn populateFunction(
    ctx: *ir.Context,
    loc: ir.Location,
    func: FuncDialect.FuncOp,
    i32_type: ir.Type,
    workload: Workload,
    function_index: u32,
) !void {
    const entry = func.getEntryBlock();
    var current = func.getArgument(0);
    const rhs = func.getArgument(1);

    for (0..workload.ops_per_function) |op_index_usize| {
        const op_index: u32 = @intCast(op_index_usize);
        current = switch (workload.shape) {
            .arith_chain => blk: {
                const constant = try appendConstant(ctx, loc, entry, i32_type, @intCast((op_index % 17) + 1));
                break :blk try appendArithChainOp(ctx, loc, entry, current, rhs, constant.getResult(), op_index);
            },
            .fold_cse_grid => blk: {
                const constant = try appendConstant(ctx, loc, entry, i32_type, @intCast((op_index % 17) + 1));
                break :blk try appendFoldCseGridOp(ctx, loc, entry, current, rhs, constant.getResult(), i32_type, function_index, op_index);
            },
            .control_loop => try appendControlLoopOp(ctx, loc, entry, current, rhs, i32_type, op_index),
            .symbol_call_forest => blk: {
                const constant = try appendConstant(ctx, loc, entry, i32_type, @intCast((op_index % 23) + 1));
                break :blk try appendSymbolCallForestOp(ctx, loc, entry, current, rhs, constant.getResult(), i32_type, function_index, op_index);
            },
        };
    }

    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{current});
    try entry.addOperation(ret.op);
}

fn appendConstant(
    ctx: *ir.Context,
    loc: ir.Location,
    entry: *ir.Block,
    i32_type: ir.Type,
    value: i64,
) !ArithDialect.ConstantOp {
    const constant = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, value);
    try entry.addOperation(constant.op);
    return constant;
}

fn appendArithChainOp(
    ctx: *ir.Context,
    loc: ir.Location,
    entry: *ir.Block,
    current: *ir.Value,
    rhs: *ir.Value,
    constant: *ir.Value,
    op_index: u32,
) !*ir.Value {
    switch (op_index % 4) {
        0 => {
            var op = try ArithDialect.AddOp.create(ctx, loc, current, constant);
            try entry.addOperation(op.op);
            return op.getResult();
        },
        1 => {
            var op = try ArithDialect.MulOp.create(ctx, loc, current, rhs);
            try entry.addOperation(op.op);
            return op.getResult();
        },
        2 => {
            var op = try ArithDialect.SubOp.create(ctx, loc, current, constant);
            try entry.addOperation(op.op);
            return op.getResult();
        },
        else => {
            var op = try ArithDialect.AddOp.create(ctx, loc, current, rhs);
            try entry.addOperation(op.op);
            return op.getResult();
        },
    }
}

fn appendFoldCseGridOp(
    ctx: *ir.Context,
    loc: ir.Location,
    entry: *ir.Block,
    current: *ir.Value,
    rhs: *ir.Value,
    constant: *ir.Value,
    i32_type: ir.Type,
    function_index: u32,
    op_index: u32,
) !*ir.Value {
    var lhs_dead = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, @intCast(function_index % 11));
    var rhs_dead = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, @intCast(op_index % 13));
    const folded_dead = try ArithDialect.AddOp.create(ctx, loc, lhs_dead.getResult(), rhs_dead.getResult());
    try entry.addOperation(lhs_dead.op);
    try entry.addOperation(rhs_dead.op);
    try entry.addOperation(folded_dead.op);

    var next = try ArithDialect.AddOp.create(ctx, loc, current, constant);
    try entry.addOperation(next.op);
    const duplicate = try ArithDialect.AddOp.create(ctx, loc, current, constant);
    try entry.addOperation(duplicate.op);
    var mixed = try ArithDialect.MulOp.create(ctx, loc, next.getResult(), rhs);
    try entry.addOperation(mixed.op);
    return mixed.getResult();
}

fn appendControlLoopOp(
    ctx: *ir.Context,
    loc: ir.Location,
    entry: *ir.Block,
    current: *ir.Value,
    rhs: *ir.Value,
    i32_type: ir.Type,
    op_index: u32,
) !*ir.Value {
    var lower = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, 0);
    var upper = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, @intCast((op_index % 31) + 2));
    var step = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, 1);
    try entry.addOperation(lower.op);
    try entry.addOperation(upper.op);
    try entry.addOperation(step.op);

    var for_op = try ScfDialect.ForOp.create(ctx, loc, lower.getResult(), upper.getResult(), step.getResult(), &.{current}, &.{i32_type});
    try entry.addOperation(for_op.op);
    const body = for_op.getBodyBlock();
    const iter_args = for_op.getIterArgs();
    const iter_arg = iter_args[0];
    var invariant_const = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, @intCast((op_index % 17) + 1));
    try body.addOperation(invariant_const.op);
    var invariant = try ArithDialect.AddOp.create(ctx, loc, rhs, invariant_const.getResult());
    try body.addOperation(invariant.op);
    var carried = try ArithDialect.AddOp.create(ctx, loc, iter_arg, invariant.getResult());
    try body.addOperation(carried.op);
    var stepped = try ArithDialect.AddOp.create(ctx, loc, carried.getResult(), for_op.getInductionVar());
    try body.addOperation(stepped.op);
    const yield = try ScfDialect.YieldOp.create(ctx, loc, &.{stepped.getResult()});
    try body.addOperation(yield.op);
    return for_op.getResult(0).?;
}

fn appendSymbolCallForestOp(
    ctx: *ir.Context,
    loc: ir.Location,
    entry: *ir.Block,
    current: *ir.Value,
    rhs: *ir.Value,
    constant: *ir.Value,
    i32_type: ir.Type,
    function_index: u32,
    op_index: u32,
) !*ir.Value {
    if (function_index == 0) {
        return appendArithChainOp(ctx, loc, entry, current, rhs, constant, op_index);
    }

    var lhs_dead = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, @intCast((function_index % 17) + 3));
    var rhs_dead = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, @intCast((op_index % 19) + 5));
    const folded_dead = try ArithDialect.AddOp.create(ctx, loc, lhs_dead.getResult(), rhs_dead.getResult());
    try entry.addOperation(lhs_dead.op);
    try entry.addOperation(rhs_dead.op);
    try entry.addOperation(folded_dead.op);

    const callee_name = try symbolCallCalleeName(ctx, function_index, op_index);
    var call = try FuncDialect.CallOp.create(ctx, loc, callee_name, &.{ current, rhs }, &.{i32_type});
    try entry.addOperation(call.op);

    var combined = try ArithDialect.AddOp.create(ctx, loc, call.getResult(0).?, constant);
    try entry.addOperation(combined.op);
    return combined.getResult();
}

fn symbolCallCalleeName(ctx: *ir.Context, function_index: u32, op_index: u32) ![]const u8 {
    const window = @min(function_index, 4);
    const callee_index = function_index - 1 - (op_index % window);
    return try std.fmt.allocPrint(ir.context.transientAllocator(ctx), "compile_f_{d}", .{callee_index});
}

test "compile matrix names resolve" {
    for (matrix) |workload| {
        try std.testing.expectEqual(workload.shape, byName(workload.name).?.shape);
        try std.testing.expect(workload.sourceOps() > 0);
    }
    try std.testing.expect(byName("missing") == null);
}

test "compile matrix workloads build modules" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();

    for (matrix) |workload| {
        var ctx = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
        defer ctx.deinit(arena.allocator());
        try dialects.registerAllDialects(&ctx);
        const module = try build(&ctx, workload);
        try ir.verifyOperation(module.op, ir.verify.default_options);
        try std.testing.expect(ir.inspection.countOperationsNamed(module.op, FuncDialect.FuncOp.operation_name) > 0);
    }
}
