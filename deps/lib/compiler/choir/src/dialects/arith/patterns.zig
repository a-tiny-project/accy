const std = @import("std");
const ir = @import("../../core/root.zig");
const rewrite = ir.rewrite;
const fold_mod = @import("folds.zig");

pub fn Patterns(comptime Dialect: type) type {
    return struct {
        const folds = fold_mod.Folds(Dialect);

        pub const canonicalization_patterns = [_]rewrite.RewritePattern{
            rewrite.RewritePattern.init(
                .{
                    .name = "arith-select-canonicalization",
                    .root_op_name = Dialect.SelectOp.operation_name,
                    .benefit = 50,
                    .products = .{ .operations = &.{Dialect.NotOp.operation_name} },
                },
                rewriteSelectCanonicalization,
            ),
            rewrite.RewritePattern.init(
                .{
                    .name = "arith-not-canonicalization",
                    .root_op_name = Dialect.NotOp.operation_name,
                    .benefit = 50,
                    .products = .{ .operations = &.{Dialect.ConstantOp.operation_name} },
                },
                rewriteNotCanonicalization,
            ),
        };

        fn rewriteSelectCanonicalization(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
            var declaration = ir.interfaces.effects.inspect(op.allocator, op) catch return .failure;
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return .failure;
            if (op.getNumResults() != 1) return .failure;
            const select = Dialect.SelectOp{ .op = op };
            const condition_value = select.getCondition();
            const true_value = select.getTrueValue();
            const false_value = select.getFalseValue();
            if (true_value == false_value) return rewriteSameTypeForwarding(op, true_value, rewriter);
            if (true_value == condition_value) {
                if (folds.constantBoolEquals(false_value, false)) return rewriteSameTypeForwarding(op, condition_value, rewriter);
                if (folds.constantBoolEquals(false_value, true)) return rewriteSameTypeForwarding(op, false_value, rewriter);
            }
            if (false_value == condition_value) {
                if (folds.constantBoolEquals(true_value, true)) return rewriteSameTypeForwarding(op, condition_value, rewriter);
                if (folds.constantBoolEquals(true_value, false)) return rewriteSameTypeForwarding(op, true_value, rewriter);
            }
            if (folds.constantBoolEquals(true_value, true) and folds.constantBoolEquals(false_value, false)) {
                return rewriteSameTypeForwarding(op, condition_value, rewriter);
            }
            if (folds.constantBoolEquals(true_value, false) and folds.constantBoolEquals(false_value, true)) {
                return rewriteBoolNot(op, condition_value, rewriter);
            }
            const condition = folds.constantBoolFromValue(condition_value) orelse return .failure;
            return rewriteSameTypeForwarding(op, if (condition) true_value else false_value, rewriter);
        }

        fn rewriteNotCanonicalization(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
            var declaration = ir.interfaces.effects.inspect(op.allocator, op) catch return .failure;
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return .failure;
            if (op.getNumResults() != 1) return .failure;
            const not = Dialect.NotOp{ .op = op };
            const input = not.getInput();
            if (folds.constantBoolFromValue(input)) |value| {
                return rewriteBoolConstant(op, !value, rewriter);
            }

            const def_any = input.getDefiningOp() orelse return .failure;
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
            if (!std.mem.eql(u8, def_op.name.name, Dialect.NotOp.operation_name)) return .failure;
            const inner_not = Dialect.NotOp{ .op = def_op };
            return rewriteSameTypeForwarding(op, inner_not.getInput(), rewriter);
        }

        fn rewriteSameTypeForwarding(
            op: *ir.Operation,
            input: *ir.Value,
            rewriter: *rewrite.PatternRewriter,
        ) rewrite.PatternResult {
            if (op.getNumResults() != 1) return .failure;
            const result = op.getResult(0) orelse return .failure;
            if (!result.type.eql(input.type)) return .failure;
            rewriter.replaceOpWithValue(op, input) catch return .failure;
            return .success;
        }

        fn rewriteBoolConstant(
            op: *ir.Operation,
            value: bool,
            rewriter: *rewrite.PatternRewriter,
        ) rewrite.PatternResult {
            if (op.getNumResults() != 1) return .failure;
            const result = op.getResult(0) orelse return .failure;
            if (!folds.isBoolType(result.type)) return .failure;

            rewriter.setInsertionPointBefore(op);
            var state = ir.Operation.State.init(Dialect.ConstantOp.operation_name, op.location);
            state.addTypes(&.{result.type});
            const attr = Dialect.getBoolAttr(rewriter.ir_ctx, value) catch return .failure;
            const uses_properties = state.setPropertiesAttrIfRegistered(rewriter.ir_ctx, attr) catch return .failure;
            if (!uses_properties) state.addAttributes(&.{.{ .name = "value", .value = attr }});
            _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
            return .success;
        }

        fn rewriteBoolNot(
            op: *ir.Operation,
            input: *ir.Value,
            rewriter: *rewrite.PatternRewriter,
        ) rewrite.PatternResult {
            if (op.getNumResults() != 1) return .failure;
            const result = op.getResult(0) orelse return .failure;
            if (!result.type.eql(input.type) or !folds.isBoolType(result.type)) return .failure;

            rewriter.setInsertionPointBefore(op);
            var state = ir.Operation.State.init(Dialect.NotOp.operation_name, op.location);
            state.addOperands(&.{input});
            state.addTypes(&.{result.type});
            _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
            return .success;
        }
    };
}
