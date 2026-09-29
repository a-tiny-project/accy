const std = @import("std");
const eval = @import("root.zig");

test {
    std.testing.refAllDecls(eval);
}

const arena_alloc = @import("alloc_arena");
const ir = @import("../core/root.zig");
const dialects = @import("../dialects/root.zig");
const Arith = dialects.ArithDialect;
const Scf = dialects.ScfDialect;
const Func = dialects.FuncDialect;

const ControlFixture = struct {
    arena: arena_alloc.Arena,
    ctx: ir.Context,
    function: Func.FuncOp,
    evaluator: eval.Evaluator,

    fn init(self: *ControlFixture, kind: dialects.arith.ScalarKind, arg_count: usize) !void {
        self.arena = arena_alloc.Arena.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        try dialects.registerAllDialects(&self.ctx);
        const typ = try Arith.getScalarType(&self.ctx, kind);
        const types = try allocator.alloc(ir.Type, arg_count);
        @memset(types, typ);
        self.function = try Func.FuncOp.create(&self.ctx, .unknown, "control", types, &.{typ});
        self.evaluator = eval.Evaluator.init(allocator, &self.ctx);
    }

    fn deinit(self: *ControlFixture) void {
        self.evaluator.deinit();
        self.ctx.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    fn constant(self: *ControlFixture, value: i64) !*ir.Value {
        const op = try Arith.ConstantOp.createInt(&self.ctx, .unknown, self.function.getResultTypes()[0], value);
        try self.function.getEntryBlock().addOperation(op.op);
        return op.getResult();
    }

    fn binary(self: *ControlFixture, block: *ir.Block, comptime Op: type, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try Op.create(&self.ctx, .unknown, lhs, rhs);
        try block.addOperation(op.op);
        return op.getResult();
    }

    fn condition(self: *ControlFixture, loop: Scf.WhileOp, upper: *ir.Value) !void {
        const block = loop.getBeforeBlock();
        const cmp = try Arith.CmpOp.create(&self.ctx, .unknown, .slt, block.arguments.items[0], upper);
        try block.addOperation(cmp.op);
        const op = try Scf.ConditionOp.create(&self.ctx, .unknown, cmp.getResult(), block.arguments.items);
        try block.addOperation(op.op);
    }

    fn yield(self: *ControlFixture, block: *ir.Block, values: []const *ir.Value) !void {
        const op = try Scf.YieldOp.create(&self.ctx, .unknown, values);
        try block.addOperation(op.op);
    }

    fn ret(self: *ControlFixture, value: *ir.Value) !void {
        const op = try Func.ReturnOp.create(&self.ctx, .unknown, &.{value});
        try self.function.getEntryBlock().addOperation(op.op);
    }

    fn expect(self: *ControlFixture, args: []const i64, expected: i64) !void {
        const attrs = try self.arena.allocator().alloc(ir.Attribute, args.len);
        for (args, attrs) |arg, *attr| attr.* = try self.ctx.getI64Attr(arg);
        const result = try self.evaluator.evaluateFunctionOp(self.function.op, attrs);
        try std.testing.expectEqual(expected, result.cast(ir.Attribute.IntegerAttr).?.getValue());
    }
};

test "Evaluator structured regions capture arguments and rebind nested loop values" {
    for ([_]bool{ false, true }) |nested| {
        var fixture: ControlFixture = undefined;
        try fixture.init(.i64, 1);
        defer fixture.deinit();
        const zero = try fixture.constant(0);
        const one = try fixture.constant(1);
        const loop = try Scf.WhileOp.create(&fixture.ctx, .unknown, &.{zero}, &.{zero.type});
        try fixture.function.getEntryBlock().addOperation(loop.op);
        try fixture.condition(loop, fixture.function.getArgument(0));
        const after = loop.getAfterBlock();
        const next = try fixture.binary(after, Arith.AddOp, after.arguments.items[0], one);
        const result = if (nested) result: {
            const inner = try Scf.WhileOp.create(&fixture.ctx, .unknown, &.{after.arguments.items[0]}, &.{zero.type});
            try after.addOperation(inner.op);
            try fixture.condition(inner, next);
            const inner_after = inner.getAfterBlock();
            const advanced = try fixture.binary(inner_after, Arith.AddOp, after.arguments.items[0], one);
            try fixture.yield(inner_after, &.{advanced});
            break :result inner.op.getResult(0).?;
        } else next;
        try fixture.yield(after, &.{result});
        try fixture.ret(loop.op.getResult(0).?);
        for ([_]i64{ 3, 0, 1, 19, 2 }) |upper| try fixture.expect(&.{upper}, upper);
        try std.testing.expectEqual(@as(usize, 0), fixture.evaluator.frames.items.len);
    }
}

/// Allocating a handle gives an observable, monotonically increasing effect result.
const CaptureEffect = struct {
    fn canEval(_: *const anyopaque) bool {
        return true;
    }

    fn evaluate(op_ptr: *const anyopaque, _: []const ir.Attribute, ctx: *const ir.interfaces.EvalContext) ir.interfaces.EvalError!ir.Attribute {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        const handle = try ctx.allocHandle(ctx.state, 1);
        return op.getContext().getI64Attr(handle) catch return error.OutOfMemory;
    }
};

test "Evaluator structured regions reuse captured effect results across iterations" {
    var fixture: ControlFixture = undefined;
    try fixture.init(.i64, 1);
    defer fixture.deinit();
    _ = try fixture.ctx.registerOperation("arith.capture_effect", .{});
    try fixture.ctx.registerOperationInterface("arith.capture_effect", ir.interfaces.Evaluatable.entryFor(CaptureEffect.canEval, CaptureEffect.evaluate));
    const zero = try fixture.constant(0);
    const one = try fixture.constant(1);
    const loop = try Scf.WhileOp.create(&fixture.ctx, .unknown, &.{ zero, zero }, &.{ zero.type, zero.type });
    try fixture.function.getEntryBlock().addOperation(loop.op);
    try fixture.condition(loop, fixture.function.getArgument(0));
    const after = loop.getAfterBlock();
    var builder = ir.OperationBuilder.init(&fixture.ctx);
    var state = ir.Operation.State.init("arith.capture_effect", .unknown);
    state.addTypes(&.{zero.type});
    const effect = try builder.create(state);
    try after.addOperation(effect);
    const condition = try Arith.CmpOp.create(&fixture.ctx, .unknown, .eq, after.arguments.items[0], zero);
    try after.addOperation(condition.op);
    const branch = try Scf.IfOp.create(&fixture.ctx, .unknown, condition.getResult(), &.{zero.type});
    try after.addOperation(branch.op);
    try fixture.yield(branch.getThenBlock(), &.{effect.getResult(0).?});
    try fixture.yield(branch.getElseBlock().?, &.{effect.getResult(0).?});
    const inner = try Scf.WhileOp.create(&fixture.ctx, .unknown, &.{ zero, zero }, &.{ zero.type, zero.type });
    try after.addOperation(inner.op);
    const inner_before = inner.getBeforeBlock();
    const stop = try Arith.ConstantOp.createBool(&fixture.ctx, .unknown, false);
    try inner_before.addOperation(stop.op);
    const forwarded = try Scf.ConditionOp.create(&fixture.ctx, .unknown, stop.getResult(), &.{ zero, branch.getResult(0).? });
    try inner_before.addOperation(forwarded.op);
    try fixture.yield(inner.getAfterBlock(), inner.getAfterBlock().arguments.items);
    const next = try fixture.binary(after, Arith.AddOp, after.arguments.items[0], one);
    try fixture.yield(after, &.{ next, inner.op.getResult(1).? });
    try fixture.ret(loop.op.getResult(1).?);
    try fixture.expect(&.{3}, 2);
    try std.testing.expectEqual(@as(usize, 3), fixture.evaluator.handle_table.items.len);
    try fixture.expect(&.{2}, 4);
    try std.testing.expectEqual(@as(usize, 5), fixture.evaluator.handle_table.items.len);
}

test "Evaluator function frames isolate caller values and preserve caller bindings" {
    var fixture: ControlFixture = undefined;
    try fixture.init(.i64, 1);
    defer fixture.deinit();
    const argument = fixture.function.getArgument(0);
    try fixture.ret(argument);
    const saved = try fixture.ctx.getI64Attr(99);
    try fixture.evaluator.setValue(argument, saved);
    try fixture.expect(&.{7}, 7);
    try std.testing.expectEqual(saved, fixture.evaluator.getValue(argument).?);

    const callee = try Func.FuncOp.create(&fixture.ctx, .unknown, "isolated", &.{}, &.{argument.type});
    const ret = try Func.ReturnOp.create(&fixture.ctx, .unknown, &.{argument});
    try callee.getEntryBlock().addOperation(ret.op);
    try std.testing.expectError(error.ValueNotFound, fixture.evaluator.evaluateFunctionOp(callee.op, &.{}));
    try std.testing.expectEqual(saved, fixture.evaluator.getValue(argument).?);
}

test "Evaluator structured if captures arguments and keeps branch bindings local" {
    var fixture: ControlFixture = undefined;
    try fixture.init(.i64, 1);
    defer fixture.deinit();
    const zero = try fixture.constant(0);
    const entry = fixture.function.getEntryBlock();
    const condition = try Arith.CmpOp.create(&fixture.ctx, .unknown, .eq, fixture.function.getArgument(0), zero);
    try entry.addOperation(condition.op);
    const branch = try Scf.IfOp.create(&fixture.ctx, .unknown, condition.getResult(), &.{zero.type});
    try entry.addOperation(branch.op);
    const yes = try fixture.binary(branch.getThenBlock(), Arith.AddOp, fixture.function.getArgument(0), zero);
    const no = try fixture.binary(branch.getElseBlock().?, Arith.AddOp, fixture.function.getArgument(0), zero);
    try fixture.yield(branch.getThenBlock(), &.{yes});
    try fixture.yield(branch.getElseBlock().?, &.{no});
    try fixture.ret(branch.getResult(0).?);
    for ([_]i64{ 0, 7, -4, 0 }) |value| try fixture.expect(&.{value}, value);

    try fixture.evaluator.setValue(fixture.function.getArgument(0), try fixture.ctx.getI64Attr(0));
    _ = try fixture.evaluator.evaluate(branch.op);
    try std.testing.expect(fixture.evaluator.getValue(yes) == null);
}

const CountedFixture = struct {
    fn sum(fixture: *ControlFixture, lower: i64, upper: i64, step: i64, initial: i64) !Scf.ForOp {
        const lo = try fixture.constant(lower);
        const hi = try fixture.constant(upper);
        const stride = try fixture.constant(step);
        const init = try fixture.constant(initial);
        const loop = try Scf.ForOp.create(&fixture.ctx, .unknown, lo, hi, stride, &.{init}, &.{init.type});
        try fixture.function.getEntryBlock().addOperation(loop.op);
        const body = loop.getBodyBlock();
        const next = try fixture.binary(body, Arith.AddOp, body.arguments.items[1], body.arguments.items[0]);
        try fixture.yield(body, &.{next});
        try fixture.ret(loop.getResult(0).?);
        try ir.verifyOperation(loop.op, ir.verify.default_options);
        return loop;
    }
};

test "Evaluator scf.for reduced sum and signed wrapping induction" {
    const Case = struct { lower: i64, upper: i64, step: i64, initial: i64 = 0, expected: i64 };
    const minimum = std.math.minInt(i64);
    const maximum = std.math.maxInt(i64);
    for ([_]Case{
        .{ .lower = 0, .upper = 4, .step = 1, .expected = 6 },
        .{ .lower = 0, .upper = 0, .step = 1, .initial = 7, .expected = 7 },
        .{ .lower = 0, .upper = 1, .step = 1, .initial = 7, .expected = 7 },
        .{ .lower = 0, .upper = 17, .step = 1, .expected = 136 },
        .{ .lower = 5, .upper = 3, .step = 1, .initial = 7, .expected = 7 },
        .{ .lower = -3, .upper = 4, .step = 2, .initial = 7, .expected = 7 },
        .{ .lower = 0, .upper = 7, .step = 2, .expected = 12 },
        .{ .lower = 1, .upper = 0, .step = 0, .initial = 7, .expected = 7 },
        .{ .lower = 1, .upper = 0, .step = -1, .initial = 7, .expected = 7 },
        .{ .lower = minimum, .upper = minimum + 1, .step = -1, .expected = minimum },
        .{ .lower = 1, .upper = 2, .step = maximum, .expected = minimum },
    }) |case| {
        var fixture: ControlFixture = undefined;
        try fixture.init(.index, 0);
        defer fixture.deinit();
        _ = try CountedFixture.sum(&fixture, case.lower, case.upper, case.step, case.initial);
        try fixture.expect(&.{}, case.expected);
        try fixture.expect(&.{}, case.expected);
    }
}

test "Evaluator scf.for guard fuel at and past the configured limit" {
    const guard_limit: u32 = 4;
    for ([_]bool{ false, true }) |branch_limit| {
        for ([_]i64{ guard_limit - 1, guard_limit }) |upper| {
            var fixture: ControlFixture = undefined;
            try fixture.init(.index, 0);
            defer fixture.deinit();
            _ = try CountedFixture.sum(&fixture, 0, upper, 1, 0);
            fixture.evaluator.iteration_fuel = if (branch_limit) guard_limit + 1 else guard_limit;
            fixture.evaluator.branch_fuel = if (branch_limit) guard_limit else guard_limit + 1;
            if (upper == guard_limit - 1) {
                try fixture.expect(&.{}, 3);
                const remaining = if (branch_limit) fixture.evaluator.branch_fuel else fixture.evaluator.iteration_fuel;
                try std.testing.expectEqual(@as(u32, 0), remaining);
            } else {
                const expected = if (branch_limit) error.BranchQuotaExceeded else error.IterationQuotaExceeded;
                try std.testing.expectError(expected, fixture.evaluator.evaluateFunctionOp(fixture.function.op, &.{}));
            }
            try std.testing.expectEqual(@as(usize, 0), fixture.evaluator.frames.items.len);
        }
    }
    for ([_]i64{ 0, -1 }) |step| {
        var fixture: ControlFixture = undefined;
        try fixture.init(.index, 0);
        defer fixture.deinit();
        _ = try CountedFixture.sum(&fixture, 0, 1, step, 0);
        fixture.evaluator.iteration_fuel = guard_limit;
        try std.testing.expectError(error.IterationQuotaExceeded, fixture.evaluator.evaluateFunctionOp(fixture.function.op, &.{}));
    }
}

test "Evaluator scf.for simultaneous carried rotations across nesting and ARM carried boundary" {
    const arm_carried_limit = 16;
    for ([_]usize{ 0, 1, arm_carried_limit, arm_carried_limit + 1 }) |count| {
        for ([_]bool{ false, true }) |nested| {
            var fixture: ControlFixture = undefined;
            try fixture.init(.index, 1);
            defer fixture.deinit();
            const allocator = fixture.arena.allocator();
            const zero = try fixture.constant(0);
            const one = try fixture.constant(1);
            const values = try allocator.alloc(*ir.Value, count);
            const types = try allocator.alloc(ir.Type, count);
            for (values, types, 0..) |*value, *typ, index| {
                value.* = try fixture.constant(@intCast(index + 1));
                typ.* = zero.type;
            }
            const loop = try Scf.ForOp.create(&fixture.ctx, .unknown, zero, fixture.function.getArgument(0), one, values, types);
            try fixture.function.getEntryBlock().addOperation(loop.op);
            const body = loop.getBodyBlock();
            const rotation = if (nested) rotation: {
                const end = try fixture.binary(body, Arith.AddOp, loop.getInductionVar(), one);
                const inner = try Scf.ForOp.create(&fixture.ctx, .unknown, loop.getInductionVar(), end, one, loop.getIterArgs(), types);
                try body.addOperation(inner.op);
                for (values, 0..) |*value, index| value.* = inner.getIterArgs()[(index + 1) % count];
                try fixture.yield(inner.getBodyBlock(), values);
                for (values, 0..) |*value, index| value.* = inner.getResult(index).?;
                break :rotation values;
            } else rotation: {
                for (values, 0..) |*value, index| value.* = loop.getIterArgs()[(index + 1) % count];
                break :rotation values;
            };
            try fixture.yield(body, rotation);
            var total = zero;
            for (0..count) |index| {
                const weight = try fixture.constant(@intCast(index + 1));
                const term = try fixture.binary(fixture.function.getEntryBlock(), Arith.MulOp, loop.getResult(index).?, weight);
                total = try fixture.binary(fixture.function.getEntryBlock(), Arith.AddOp, total, term);
            }
            try fixture.ret(total);
            try ir.verifyOperation(loop.op, ir.verify.default_options);
            for ([_]usize{ 0, 1, 7 }) |iterations| {
                var expected: i64 = 0;
                for (0..count) |index| expected += @intCast((index + 1) * ((index + iterations) % count + 1));
                try fixture.expect(&.{@intCast(iterations)}, expected);
            }
        }
    }
}

test "Evaluator scf.for native integer widths use signed guards and wrapping increments" {
    for ([_]dialects.arith.ScalarKind{ .i32, .u32, .i64, .u64 }) |kind| {
        const bits = dialects.arith.scalarBitWidth(kind);
        for ([_]bool{ false, true }) |wrap| {
            var fixture: ControlFixture = undefined;
            try fixture.init(kind, 0);
            defer fixture.deinit();
            const maximum: i64 = if (bits == 32) std.math.maxInt(i32) else std.math.maxInt(i64);
            const minimum: i64 = if (bits == 32) std.math.minInt(i32) else std.math.minInt(i64);
            const lower: i64 = if (bits == 32) 0xffffffff else -1;
            _ = try CountedFixture.sum(&fixture, if (wrap) 1 else lower, if (wrap) 2 else 1, if (wrap) maximum else 1, 0);
            try fixture.expect(&.{}, if (wrap) minimum else -1);
        }
    }
}

test "Evaluator scf.for refuses unresolved narrow induction by operation name" {
    var fixture: ControlFixture = undefined;
    try fixture.init(.i8, 0);
    defer fixture.deinit();
    const loop = try CountedFixture.sum(&fixture, 0, 4, 1, 0);
    try std.testing.expectError(error.UnsupportedOperation, fixture.evaluator.evaluate(loop.op));
    const diagnostics = fixture.evaluator.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics[0].message, "scf.for") != null);
}

test "Evaluator scf.for preserves heterogeneous carried attributes" {
    var fixture: ControlFixture = undefined;
    try fixture.init(.index, 0);
    defer fixture.deinit();
    const zero = try fixture.constant(0);
    const upper = try fixture.constant(3);
    const step = try fixture.constant(1);
    const f64_type = try Arith.getScalarType(&fixture.ctx, .f64);
    const initial = try Arith.ConstantOp.createFloat(&fixture.ctx, .unknown, f64_type, 0.5);
    const flag = try Arith.ConstantOp.createBool(&fixture.ctx, .unknown, true);
    const loop = try Scf.ForOp.create(&fixture.ctx, .unknown, zero, upper, step, &.{ initial.getResult(), flag.getResult() }, &.{ f64_type, flag.getResult().type });
    const next = try fixture.binary(loop.getBodyBlock(), Arith.AddOp, loop.getIterArgs()[0], initial.getResult());
    try fixture.yield(loop.getBodyBlock(), &.{ next, loop.getIterArgs()[1] });
    try ir.verifyOperation(loop.op, ir.verify.default_options);
    const result = try fixture.evaluator.evaluate(loop.op);
    const values = result.cast(ir.Attribute.ArrayAttr).?.getValues();
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@as(f64, 2), values[0].cast(ir.Attribute.FloatAttr).?.getValue());
    try std.testing.expect(values[1].cast(ir.Attribute.BoolAttr).?.getValue());
}

test "Evaluator scf.for reaches an invalid body operation only on its iteration" {
    var fixture: ControlFixture = undefined;
    try fixture.init(.index, 1);
    defer fixture.deinit();
    const zero = try fixture.constant(0);
    const one = try fixture.constant(1);
    const three = try fixture.constant(3);
    const loop = try Scf.ForOp.create(&fixture.ctx, .unknown, zero, fixture.function.getArgument(0), one, &.{zero}, &.{zero.type});
    try fixture.function.getEntryBlock().addOperation(loop.op);
    const body = loop.getBodyBlock();
    const denominator = try fixture.binary(body, Arith.SubOp, three, loop.getInductionVar());
    _ = try fixture.binary(body, Arith.DivOp, one, denominator);
    try fixture.yield(body, &.{loop.getInductionVar()});
    try fixture.ret(loop.getResult(0).?);
    try fixture.expect(&.{0}, 0);
    try fixture.expect(&.{1}, 0);
    try fixture.expect(&.{3}, 2);
    const four = try fixture.ctx.getI64Attr(4);
    try std.testing.expectError(error.InvalidOperand, fixture.evaluator.evaluateFunctionOp(fixture.function.op, &.{four}));
    try fixture.expect(&.{2}, 1);
}
