const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const effects = ir.interfaces.effects;

pub const ScfDialect = struct {
    pub const name = "scf";
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .op_interface_fallbacks = &.{
            .{ .id = ir.interfaces.Evaluatable.id, .fallback = ScfEval.fallback },
        },
    });

    pub const VerifyError = error{
        ScfIfMissingCondition,
        ScfIfMissingThenRegion,
        ScfIfMissingThenBlock,
        ScfIfMissingElseRegion,
        ScfIfMultipleBlocks,
        ScfIfYieldMissing,
        ScfIfYieldNotTerminal,
        ScfIfYieldArityMismatch,
        ScfIfYieldTypeMismatch,
        ScfForMissingBounds,
        ScfForRegionArityMismatch,
        ScfForMissingBody,
        ScfForMultipleBlocks,
        ScfForBlockArgCountMismatch,
        ScfForResultArityMismatch,
        ScfForBoundsTypeMismatch,
        ScfForInductionTypeMismatch,
        ScfForIterArgTypeMismatch,
        ScfForResultTypeMismatch,
        ScfForYieldMissing,
        ScfForYieldNotTerminal,
        ScfForYieldArityMismatch,
        ScfForYieldTypeMismatch,
        ScfForMultipleYields,
    };

    const yield_vtable = ir.interfaces.YieldOpInterface.VTable{
        .getYieldOperandCount = getYieldOperandCount,
        .getYieldOperand = getYieldOperand,
    };

    const ScfEval = struct {
        const arith = @import("arith/root.zig");

        fn canEval(op_ptr: *const anyopaque) bool {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, ForOp.operation_name)) {
                return forInductionBits(op) != null;
            }
            return std.mem.eql(u8, op.name.name, IfOp.operation_name) or
                std.mem.eql(u8, op.name.name, WhileOp.operation_name) or
                std.mem.eql(u8, op.name.name, ConditionOp.operation_name) or
                std.mem.eql(u8, op.name.name, YieldOp.operation_name);
        }

        /// The x64 guard and increment explicitly distinguish native 32/64-bit homes.
        fn forInductionBits(op: *const ir.Operation) ?u8 {
            if (op.operands.items.len < 3) return null;
            const typ = op.operands.items[0].value.type;
            if (!typ.eql(op.operands.items[1].value.type) or
                !typ.eql(op.operands.items[2].value.type)) return null;
            return switch (arith.scalarKindFromType(typ) orelse return null) {
                .index, .i64, .u64 => 64,
                .i32, .u32 => 32,
                else => null,
            };
        }

        fn arrayValues(attr: ir.Attribute) ?[]const ir.Attribute {
            const array_attr = attr.cast(ir.Attribute.ArrayAttr) orelse return null;
            return array_attr.getValues();
        }

        fn boolValue(attr: ir.Attribute) ?bool {
            const bool_attr = attr.cast(ir.Attribute.BoolAttr) orelse return null;
            return bool_attr.getValue();
        }

        fn makeArray(ctx: *ir.Context, values: []const ir.Attribute) ir.interfaces.EvalError!ir.Attribute {
            return ctx.getArrayAttr(values) catch error.OutOfMemory;
        }

        fn makeResults(ctx: *ir.Context, values: []const ir.Attribute, count: usize) ir.interfaces.EvalError!ir.Attribute {
            if (values.len != count) return error.InvalidOperand;
            if (count == 1) return values[0];
            return makeArray(ctx, values);
        }

        fn evaluateIf(
            op: *const ir.Operation,
            operands: []const ir.Attribute,
            eval_ctx: *const ir.interfaces.EvalContext,
        ) ir.interfaces.EvalError!ir.Attribute {
            if (operands.len != 1) return error.InvalidOperand;
            const if_op = IfOp{ .op = @constCast(op) };
            const take_then = boolValue(operands[0]) orelse return error.InvalidOperand;
            try eval_ctx.consumeBranchFuel(eval_ctx.state);

            const selected = if (take_then)
                if_op.getThenRegion()
            else
                if_op.getElseRegion() orelse {
                    if (op.results.items.len == 0) return makeArray(op.getContext(), &.{});
                    return error.InvalidOperand;
                };

            const branch_attr = try eval_ctx.evaluateRegion(eval_ctx.state, selected);
            if (arrayValues(branch_attr)) |values| {
                return makeResults(op.getContext(), values, op.results.items.len);
            }
            return makeResults(op.getContext(), &.{branch_attr}, op.results.items.len);
        }

        /// Each signed guard, including the exit guard, consumes both fuel budgets.
        /// Yield replaces the carried tuple before the wrapping induction increment.
        fn evaluateFor(
            op: *const ir.Operation,
            operands: []const ir.Attribute,
            eval_ctx: *const ir.interfaces.EvalContext,
        ) ir.interfaces.EvalError!ir.Attribute {
            const bits = forInductionBits(op) orelse return error.UnsupportedOperation;
            verifyForOpInternal(@constCast(op)) catch return error.InvalidOperand;
            std.debug.assert(operands.len == op.operands.items.len);
            const body = @constCast(op).getRegion(0) orelse return error.InvalidOperand;
            const lower = operands[0].cast(ir.Attribute.IntegerAttr) orelse return error.InvalidOperand;
            const upper = operands[1].cast(ir.Attribute.IntegerAttr) orelse return error.InvalidOperand;
            const step = operands[2].cast(ir.Attribute.IntegerAttr) orelse return error.InvalidOperand;
            var induction = arith.scalar.truncate(lower.getValue(), bits);
            const bound = arith.scalar.truncate(upper.getValue(), bits);
            const stride = step.getValue();
            const current = eval_ctx.allocator.alloc(ir.Attribute, operands.len - 2) catch return error.OutOfMemory;
            defer eval_ctx.allocator.free(current);
            const carried = current[1..];
            std.debug.assert(carried.len == op.results.items.len);
            @memcpy(carried, operands[3..]);

            while (true) {
                try eval_ctx.consumeIterationFuel(eval_ctx.state);
                try eval_ctx.consumeBranchFuel(eval_ctx.state);
                if (induction >= bound) return makeResults(op.getContext(), carried, carried.len);
                current[0] = op.getContext().getI64Attr(induction) catch return error.OutOfMemory;
                const result = try eval_ctx.evaluateRegionWithArgs(eval_ctx.state, body, current);
                const yielded = arrayValues(result) orelse return error.InvalidOperand;
                if (yielded.len != carried.len) return error.InvalidOperand;
                @memcpy(carried, yielded);
                induction = arith.scalar.addWrap(induction, stride, bits);
            }
        }

        fn evaluateWhile(
            op: *const ir.Operation,
            operands: []const ir.Attribute,
            eval_ctx: *const ir.interfaces.EvalContext,
        ) ir.interfaces.EvalError!ir.Attribute {
            const while_op = WhileOp{ .op = @constCast(op) };
            const result_count = op.results.items.len;
            if (result_count != operands.len) return error.InvalidOperand;

            const current = eval_ctx.allocator.alloc(ir.Attribute, operands.len) catch return error.OutOfMemory;
            defer eval_ctx.allocator.free(current);
            @memcpy(current, operands);

            while (true) {
                try eval_ctx.consumeIterationFuel(eval_ctx.state);
                const condition_attr = try eval_ctx.evaluateRegionWithArgs(eval_ctx.state, while_op.getBeforeRegion(), current);
                const condition_values = arrayValues(condition_attr) orelse return error.InvalidOperand;
                if (condition_values.len != operands.len + 1) return error.InvalidOperand;
                const keep_going = boolValue(condition_values[0]) orelse return error.InvalidOperand;
                const carried = condition_values[1..];
                if (!keep_going) return makeResults(op.getContext(), carried, result_count);

                const yield_attr = try eval_ctx.evaluateRegionWithArgs(eval_ctx.state, while_op.getAfterRegion(), carried);
                const yielded = arrayValues(yield_attr) orelse return error.InvalidOperand;
                if (yielded.len != operands.len) return error.InvalidOperand;
                @memcpy(current, yielded);
            }
        }

        fn evaluate(
            op_ptr: *const anyopaque,
            operands: []const ir.Attribute,
            eval_ctx: *const ir.interfaces.EvalContext,
        ) ir.interfaces.EvalError!ir.Attribute {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, IfOp.operation_name)) {
                return evaluateIf(op, operands, eval_ctx);
            }
            if (std.mem.eql(u8, op.name.name, ForOp.operation_name)) {
                return evaluateFor(op, operands, eval_ctx);
            }
            if (std.mem.eql(u8, op.name.name, WhileOp.operation_name)) {
                return evaluateWhile(op, operands, eval_ctx);
            }
            if (std.mem.eql(u8, op.name.name, ConditionOp.operation_name)) {
                if (operands.len == 0) return error.InvalidOperand;
                return makeArray(op.getContext(), operands);
            }
            if (std.mem.eql(u8, op.name.name, YieldOp.operation_name)) {
                return makeArray(op.getContext(), operands);
            }
            return error.UnsupportedOperation;
        }

        const vtable = ir.interfaces.Evaluatable.VTable{
            .canEval = canEval,
            .evaluate = evaluate,
        };

        fn fallback(_: *const ir.Operation) ?*const anyopaque {
            return &vtable;
        }
    };

    pub const IfOp = struct {
        op: *ir.Operation,

        const def = op_templates.explicit(@This(), .{
            .mnemonic = "if",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .capacity = .{ .entries = 1, .per_region = 1, .per_result = 1 },
                .enumerate = conditionalEffects,
            })},
            .operands = .{"condition"},
            .regions = ir.dialects.shape.atLeast(1),
            .region_names = .{ "then", "else" },
            .successors = 0,
            .operand_types = &.{ir.dialects.typeConstraint.exact(0, "arith.bool")},
            .dynamic_traits = .{
                ir.traits.AtLeastNRegions(1),
                ir.traits.SingleBlock,
            },
        });
        pub const operation_spec = def.operation_spec;
        pub const operation_name = def.operation_name;
        pub const createOperation = def.createOperation;
        pub const getOperand = def.getOperand;
        pub const getRegion = def.getRegion;
        pub const verify = verifyIfOp;
        pub const verifyRegions = verifyIfOpRegions;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            condition: *ir.Value,
            result_types: []const ir.Type,
        ) !IfOp {
            try loadSpec(ctx);
            var then_body = ir.context.initRegion(ctx);
            defer then_body.deinit();
            var then_builder = ir.OperationBuilder.init(ctx);
            _ = try then_builder.createBlock(&then_body, &.{}, &.{});
            var else_body = ir.context.initRegion(ctx);
            defer else_body.deinit();
            var else_builder = ir.OperationBuilder.init(ctx);
            _ = try else_builder.createBlock(&else_body, &.{}, &.{});
            var regions = [_]*ir.Region{ &then_body, &else_body };
            return try @This().createOperation(ctx, loc, &.{condition}, result_types, &regions, &.{});
        }

        pub fn createWithoutElse(
            ctx: *ir.Context,
            loc: ir.Location,
            condition: *ir.Value,
        ) !IfOp {
            try loadSpec(ctx);
            var then_body = ir.context.initRegion(ctx);
            defer then_body.deinit();
            var then_builder = ir.OperationBuilder.init(ctx);
            _ = try then_builder.createBlock(&then_body, &.{}, &.{});
            var regions = [_]*ir.Region{&then_body};
            return try @This().createOperation(ctx, loc, &.{condition}, &.{}, &regions, &.{});
        }

        pub fn getCondition(self: IfOp) *ir.Value {
            return self.getOperand("condition");
        }

        pub fn getThenRegion(self: IfOp) *ir.Region {
            return self.getRegion("then");
        }

        pub fn getThenBlock(self: IfOp) *ir.Block {
            return self.getThenRegion().getEntryBlock().?;
        }

        pub fn getElseRegion(self: IfOp) ?*ir.Region {
            return self.op.getRegion(1);
        }

        pub fn getElseBlock(self: IfOp) ?*ir.Block {
            if (self.getElseRegion()) |region| {
                return region.getEntryBlock();
            }
            return null;
        }

        pub fn getResult(self: *const IfOp, index: usize) ?*ir.Value {
            return self.op.getResult(index);
        }

        pub fn getNumResults(self: IfOp) usize {
            return self.op.results.items.len;
        }
    };

    pub const ForOp = struct {
        op: *ir.Operation,

        const def = op_templates.explicit(@This(), .{
            .mnemonic = "for",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .capacity = .{ .entries = 1, .per_region = 1, .per_result = 1 },
                .enumerate = loopEffects,
            })},
            .operands = ir.dialects.shape.atLeast(3),
            .operand_names = .{ "lower_bound", "upper_bound", "step" },
            .regions = .{"body"},
            .successors = 0,
            .dynamic_traits = .{ ir.traits.OneRegion, ir.traits.SingleBlock },
        });
        pub const operation_spec = def.operation_spec;
        pub const operation_name = def.operation_name;
        pub const createOperation = def.createOperation;
        pub const getOperand = def.getOperand;
        pub const getRegion = def.getRegion;
        pub const verify = verifyForOp;
        pub const verifyRegions = verifyForOpRegions;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            lower_bound: *ir.Value,
            upper_bound: *ir.Value,
            step: *ir.Value,
            init_args: []const *ir.Value,
            result_types: []const ir.Type,
        ) !ForOp {
            try loadSpec(ctx);
            var operands: std.ArrayList(*ir.Value) = .empty;
            const allocator = ir.context.transientAllocator(ctx);
            defer operands.deinit(allocator);
            try operands.append(allocator, lower_bound);
            try operands.append(allocator, upper_bound);
            try operands.append(allocator, step);
            for (init_args) |arg| {
                try operands.append(allocator, arg);
            }
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            const body_block = try body_builder.createBlock(&body, &.{}, &.{});

            _ = try body_block.addArgument(lower_bound.type, loc);

            for (init_args) |init_arg| {
                _ = try body_block.addArgument(init_arg.type, loc);
            }
            var regions = [_]*ir.Region{&body};
            return try @This().createOperation(ctx, loc, operands.items, result_types, &regions, &.{});
        }

        pub fn getLowerBound(self: ForOp) *ir.Value {
            return self.getOperand("lower_bound");
        }

        pub fn getUpperBound(self: ForOp) *ir.Value {
            return self.getOperand("upper_bound");
        }

        pub fn getStep(self: ForOp) *ir.Value {
            return self.getOperand("step");
        }

        pub fn getInitArgs(self: ForOp) []const *ir.Value {
            return self.op.getOperandValues()[3..];
        }

        pub fn getBodyRegion(self: ForOp) *ir.Region {
            return self.getRegion("body");
        }

        pub fn getBodyBlock(self: ForOp) *ir.Block {
            return self.getBodyRegion().getEntryBlock().?;
        }

        pub fn getInductionVar(self: ForOp) *ir.Value {
            return self.getBodyBlock().arguments.items[0];
        }

        pub fn getIterArgs(self: ForOp) []*ir.Value {
            return self.getBodyBlock().arguments.items[1..];
        }

        pub fn getResult(self: *const ForOp, index: usize) ?*ir.Value {
            return self.op.getResult(index);
        }
    };

    pub const WhileOp = struct {
        op: *ir.Operation,

        const def = op_templates.explicit(@This(), .{
            .mnemonic = "while",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .capacity = .{ .entries = 1, .per_region = 1, .per_result = 1 },
                .enumerate = loopEffects,
            })},
            .regions = 2,
            .region_names = .{ "before", "after" },
            .successors = 0,
            .dynamic_traits = .{ir.traits.SingleBlock},
        });
        pub const operation_spec = def.operation_spec;
        pub const operation_name = def.operation_name;
        pub const createOperation = def.createOperation;
        pub const getRegion = def.getRegion;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            init_args: []const *ir.Value,
            result_types: []const ir.Type,
        ) !WhileOp {
            try loadSpec(ctx);
            var operands: std.ArrayList(*ir.Value) = .empty;
            const allocator = ir.context.transientAllocator(ctx);
            defer operands.deinit(allocator);
            for (init_args) |arg| {
                try operands.append(allocator, arg);
            }

            var before_body = ir.context.initRegion(ctx);
            defer before_body.deinit();
            var before_builder = ir.OperationBuilder.init(ctx);
            const before_block = try before_builder.createBlock(&before_body, &.{}, &.{});
            for (init_args) |init_arg| {
                _ = try before_block.addArgument(init_arg.type, loc);
            }

            var after_body = ir.context.initRegion(ctx);
            defer after_body.deinit();
            var after_builder = ir.OperationBuilder.init(ctx);
            const after_block = try after_builder.createBlock(&after_body, &.{}, &.{});
            for (init_args) |init_arg| {
                _ = try after_block.addArgument(init_arg.type, loc);
            }
            var regions = [_]*ir.Region{ &before_body, &after_body };
            return try @This().createOperation(ctx, loc, operands.items, result_types, &regions, &.{});
        }

        pub fn getBeforeRegion(self: WhileOp) *ir.Region {
            return self.getRegion("before");
        }

        pub fn getAfterRegion(self: WhileOp) *ir.Region {
            return self.getRegion("after");
        }

        pub fn getBeforeBlock(self: WhileOp) *ir.Block {
            return self.getBeforeRegion().getEntryBlock().?;
        }

        pub fn getAfterBlock(self: WhileOp) *ir.Block {
            return self.getAfterRegion().getEntryBlock().?;
        }
    };

    pub const YieldOp = struct {
        op: *ir.Operation,

        const term = op_templates.explicitTerminator(@This(), .{
            .mnemonic = "yield",
            .interfaces = &.{
                ir.interfaces.YieldOpInterface.entry(&yield_vtable),
                effects.EffectOpInterface.entryFor(.{}),
            },
        });
        pub const operation_spec = term.operation_spec;
        pub const operation_name = term.operation_name;
        pub const createTerminator = term.createTerminator;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            results: []const *ir.Value,
        ) !YieldOp {
            try loadSpec(ctx);
            return try @This().createTerminator(ctx, loc, results, &.{});
        }

        pub fn getOperands(self: YieldOp) []const *ir.Value {
            return self.op.getOperandValues();
        }
    };

    pub const ConditionOp = struct {
        op: *ir.Operation,

        const term = op_templates.explicitTerminator(@This(), .{
            .mnemonic = "condition",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{})},
            .operands = ir.dialects.shape.atLeast(1),
            .operand_names = .{"condition"},
            .operand_types = &.{ir.dialects.typeConstraint.exact(0, "arith.bool")},
        });
        pub const operation_spec = term.operation_spec;
        pub const operation_name = term.operation_name;
        pub const createTerminator = term.createTerminator;
        pub const getOperand = term.getOperand;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            condition: *ir.Value,
            args: []const *ir.Value,
        ) !ConditionOp {
            try loadSpec(ctx);
            var operands: std.ArrayList(*ir.Value) = .empty;
            const allocator = ir.context.transientAllocator(ctx);
            defer operands.deinit(allocator);
            try operands.append(allocator, condition);
            for (args) |arg| {
                try operands.append(allocator, arg);
            }
            return try @This().createTerminator(ctx, loc, operands.items, &.{});
        }

        pub fn getCondition(self: ConditionOp) *ir.Value {
            return self.getOperand("condition");
        }

        pub fn getArgs(self: ConditionOp) []const *ir.Value {
            return self.op.getOperandValues()[1..];
        }
    };

    fn loadSpec(ctx: *ir.Context) !void {
        try ir.dialects.loadDialectSpec(ctx, spec);
    }

    fn getYieldOperandCount(op_ptr: *const anyopaque) usize {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return op.getOperandValues().len;
    }

    fn getYieldOperand(op_ptr: *const anyopaque, index: usize) ?*ir.Value {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return op.getOperand(index);
    }

    fn verifyForOp(op_ptr: *const anyopaque) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        if (op.operands.items.len < 3) return error.ScfForMissingBounds;
        if (op.regions.items.len != 1) return error.ScfForRegionArityMismatch;
    }

    fn verifyIfOp(op_ptr: *const anyopaque) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        if (op.operands.items.len != 1) return error.ScfIfMissingCondition;
        if (op.regions.items.len < 1) return error.ScfIfMissingThenRegion;
        if (op.results.items.len > 0 and op.regions.items.len < 2) return error.ScfIfMissingElseRegion;
    }

    fn verifyForOpRegions(op_ptr: *const anyopaque) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try verifyForOpInternal(op);
    }

    fn verifyIfOpRegions(op_ptr: *const anyopaque) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try verifyIfOpInternal(op);
    }

    fn verifyIfOpInternal(op: *ir.Operation) VerifyError!void {
        if (op.operands.items.len != 1) return error.ScfIfMissingCondition;
        if (op.regions.items.len < 1) return error.ScfIfMissingThenRegion;

        const result_count = op.results.items.len;
        if (result_count == 0) return;
        if (op.regions.items.len < 2) return error.ScfIfMissingElseRegion;

        try verifyIfYield(op, op.getRegion(0) orelse return error.ScfIfMissingThenRegion);
        try verifyIfYield(op, op.getRegion(1) orelse return error.ScfIfMissingElseRegion);
    }

    fn verifyIfYield(op: *ir.Operation, region: *ir.Region) VerifyError!void {
        const block = region.getEntryBlock() orelse return error.ScfIfMissingThenBlock;
        if (!region.hasOneBlock()) return error.ScfIfMultipleBlocks;

        var yield_op: ?*ir.Operation = null;
        var op_iter = block.operations.head;
        while (op_iter) |opaque_op| {
            const current: *ir.Operation = @ptrCast(@alignCast(opaque_op));
            if (std.mem.eql(u8, current.name.name, YieldOp.operation_name)) {
                if (current.next_op != null) return error.ScfIfYieldNotTerminal;
                yield_op = current;
            }
            op_iter = current.next_op;
        }

        const yield_final = yield_op orelse return error.ScfIfYieldMissing;
        if (yield_final.operands.items.len != op.results.items.len) return error.ScfIfYieldArityMismatch;

        for (op.results.items, 0..) |result, index| {
            const yield_type = yield_final.operands.items[index].value.type;
            if (!result.type.eql(yield_type)) return error.ScfIfYieldTypeMismatch;
        }
    }

    fn verifyForOpInternal(op: *ir.Operation) VerifyError!void {
        if (op.operands.items.len < 3) return error.ScfForMissingBounds;
        if (op.regions.items.len != 1) return error.ScfForRegionArityMismatch;

        const body_region = op.getRegion(0) orelse return error.ScfForMissingBody;
        const body_block = body_region.getEntryBlock() orelse return error.ScfForMissingBody;
        if (!body_region.hasOneBlock()) return error.ScfForMultipleBlocks;

        const iter_count = op.operands.items.len - 3;
        if (op.results.items.len != iter_count) return error.ScfForResultArityMismatch;
        if (body_block.arguments.items.len != iter_count + 1) return error.ScfForBlockArgCountMismatch;

        const lower_type = op.operands.items[0].value.type;
        const upper_type = op.operands.items[1].value.type;
        const step_type = op.operands.items[2].value.type;
        if (!lower_type.eql(upper_type) or !lower_type.eql(step_type)) {
            return error.ScfForBoundsTypeMismatch;
        }
        if (!body_block.arguments.items[0].type.eql(lower_type)) {
            return error.ScfForInductionTypeMismatch;
        }

        var yield_op: ?*ir.Operation = null;
        var op_iter = body_block.operations.head;
        while (op_iter) |opaque_op| {
            const current: *ir.Operation = @ptrCast(@alignCast(opaque_op));
            if (std.mem.eql(u8, current.name.name, YieldOp.operation_name)) {
                if (yield_op != null) return error.ScfForMultipleYields;
                if (current.next_op != null) return error.ScfForYieldNotTerminal;
                yield_op = current;
            }
            op_iter = current.next_op;
        }

        const yield_final = yield_op orelse return error.ScfForYieldMissing;
        if (yield_final.operands.items.len != iter_count) return error.ScfForYieldArityMismatch;

        for (0..iter_count) |i| {
            const init_type = op.operands.items[3 + i].value.type;
            const block_type = body_block.arguments.items[1 + i].type;
            if (!init_type.eql(block_type)) return error.ScfForIterArgTypeMismatch;
            const result_type = op.results.items[i].type;
            if (!init_type.eql(result_type)) return error.ScfForResultTypeMismatch;
            const yield_type = yield_final.operands.items[i].value.type;
            if (!init_type.eql(yield_type)) return error.ScfForYieldTypeMismatch;
        }
    }
};

fn conditionalEffects(op: *const ir.Operation, collector: *effects.Collector) void {
    regionEffects(op, collector, .conditional);
}

fn loopEffects(op: *const ir.Operation, collector: *effects.Collector) void {
    collector.append(.{ .event = .{ .kind = .diverge } });
    regionEffects(op, collector, .repeated);
}

fn regionEffects(
    op: *const ir.Operation,
    collector: *effects.Collector,
    execution: effects.Execution,
) void {
    for (0..op.getNumRegions()) |index| collector.append(.{ .region = .{
        .index = index,
        .execution = execution,
        .may_diverge = execution == .repeated,
    } });
    for (0..op.getNumResults()) |index| collector.append(.{ .result = .{ .index = index } });
}
