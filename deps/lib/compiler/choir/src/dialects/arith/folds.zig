const std = @import("std");
const ir = @import("../../core/root.zig");
const predicate_mod = @import("predicate.zig");
const types = @import("types.zig");

const CmpPredicate = predicate_mod.CmpPredicate;

const FoldBinaryOperands = struct {
    lhs: *ir.Value,
    rhs: *ir.Value,
};

pub fn Folds(comptime Dialect: type) type {
    return struct {
        fn appendFoldValue(
            results: *ir.interfaces.FoldResults,
            value: *ir.Value,
        ) !void {
            try results.append(.{ .value = value });
        }

        fn appendFoldAttribute(
            results: *ir.interfaces.FoldResults,
            attr: ir.Attribute,
        ) !void {
            try results.append(.{ .attribute = attr });
        }

        fn foldBinaryOperands(op: *const ir.Operation) ?FoldBinaryOperands {
            if (op.operands.items.len != 2) return null;
            if (op.results.items.len != 1) return null;
            return .{
                .lhs = op.operands.items[0].value,
                .rhs = op.operands.items[1].value,
            };
        }

        fn appendFoldValueForResult(
            op: *const ir.Operation,
            results: *ir.interfaces.FoldResults,
            value: *ir.Value,
        ) !void {
            if (op.results.items.len != 1) return;
            if (!op.results.items[0].type.eql(value.type)) return;
            try appendFoldValue(results, value);
        }

        fn appendIntFoldAttributeForResult(
            op: *const ir.Operation,
            results: *ir.interfaces.FoldResults,
            value: i64,
        ) !void {
            if (op.results.items.len != 1) return;
            if (!isIntegerLikeType(op.results.items[0].type)) return;
            const attr = try Dialect.getIntAttr(op.getContext(), value);
            try appendFoldAttribute(results, attr);
        }

        fn appendBoolFoldAttributeForResult(
            op: *const ir.Operation,
            results: *ir.interfaces.FoldResults,
            value: bool,
        ) !void {
            if (op.results.items.len != 1) return;
            if (!isBoolType(op.results.items[0].type)) return;
            const attr = try Dialect.getBoolAttr(op.getContext(), value);
            try appendFoldAttribute(results, attr);
        }

        fn constantDefiningOp(value: *ir.Value) ?*ir.Operation {
            const def_any = value.getDefiningOp() orelse return null;
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
            if (!std.mem.eql(u8, def_op.name.name, Dialect.ConstantOp.operation_name)) return null;
            return def_op;
        }

        pub fn constantIntFromValue(value: *ir.Value) ?i64 {
            if (!isIntegerLikeType(value.type)) return null;
            const def_op = constantDefiningOp(value) orelse return null;
            const int_attr = def_op.getAttrAs(ir.Attribute.IntegerAttr, "value") orelse return null;
            return int_attr.getValue();
        }

        pub fn constantBoolFromValue(value: *ir.Value) ?bool {
            const def_op = constantDefiningOp(value) orelse return null;
            if (def_op.getAttrAs(ir.Attribute.BoolAttr, "value")) |bool_attr| return bool_attr.getValue();
            if (def_op.getAttrAs(ir.Attribute.IntegerAttr, "value")) |int_attr| {
                const int_value = int_attr.getValue();
                if (!isBoolType(value.type)) return null;
                return int_value != 0;
            }
            return null;
        }

        pub fn constantIntEquals(value: *ir.Value, expected: i64) bool {
            return (constantIntFromValue(value) orelse return false) == expected;
        }

        pub fn constantBoolEquals(value: *ir.Value, expected: bool) bool {
            return (constantBoolFromValue(value) orelse return false) == expected;
        }

        pub fn isBoolType(ty: ir.Type) bool {
            return types.scalarKindFromType(ty) == .bool;
        }

        pub fn isIntegerLikeType(ty: ir.Type) bool {
            const kind = types.scalarKindFromType(ty) orelse return false;
            return types.scalarKindIsInteger(kind);
        }

        pub fn foldSameTypeUnary(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            if (op.operands.items.len != 1) return;
            if (op.results.items.len != 1) return;
            const input = op.operands.items[0].value;
            if (!op.results.items[0].type.eql(input.type)) return;
            try appendFoldValue(results, input);
        }

        pub fn foldSelect(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            if (op.operands.items.len != 3) return;
            if (op.results.items.len != 1) return;
            const true_value = op.operands.items[1].value;
            const false_value = op.operands.items[2].value;
            if (true_value != false_value) return;
            if (!op.results.items[0].type.eql(true_value.type)) return;
            try appendFoldValue(results, true_value);
        }

        pub fn foldAdd(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (constantIntEquals(operands.rhs, 0)) return appendFoldValueForResult(op, results, operands.lhs);
            if (constantIntEquals(operands.lhs, 0)) return appendFoldValueForResult(op, results, operands.rhs);
        }

        pub fn foldSub(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (constantIntEquals(operands.rhs, 0)) return appendFoldValueForResult(op, results, operands.lhs);
            if (operands.lhs == operands.rhs) return appendIntFoldAttributeForResult(op, results, 0);
        }

        pub fn foldMul(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (constantIntEquals(operands.rhs, 0)) return appendFoldValueForResult(op, results, operands.rhs);
            if (constantIntEquals(operands.lhs, 0)) return appendFoldValueForResult(op, results, operands.lhs);
            if (constantIntEquals(operands.rhs, 1)) return appendFoldValueForResult(op, results, operands.lhs);
            if (constantIntEquals(operands.lhs, 1)) return appendFoldValueForResult(op, results, operands.rhs);
        }

        pub fn foldDiv(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (constantIntEquals(operands.rhs, 1)) return appendFoldValueForResult(op, results, operands.lhs);
        }

        pub fn foldAnd(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (operands.lhs == operands.rhs) return appendFoldValueForResult(op, results, operands.lhs);
            if (constantBoolEquals(operands.rhs, false) or constantIntEquals(operands.rhs, 0)) {
                return appendFoldValueForResult(op, results, operands.rhs);
            }
            if (constantBoolEquals(operands.lhs, false) or constantIntEquals(operands.lhs, 0)) {
                return appendFoldValueForResult(op, results, operands.lhs);
            }
            if (constantBoolEquals(operands.rhs, true) or constantIntEquals(operands.rhs, -1)) {
                return appendFoldValueForResult(op, results, operands.lhs);
            }
            if (constantBoolEquals(operands.lhs, true) or constantIntEquals(operands.lhs, -1)) {
                return appendFoldValueForResult(op, results, operands.rhs);
            }
        }

        pub fn foldOr(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (operands.lhs == operands.rhs) return appendFoldValueForResult(op, results, operands.lhs);
            if (constantBoolEquals(operands.rhs, true) or constantIntEquals(operands.rhs, -1)) {
                return appendFoldValueForResult(op, results, operands.rhs);
            }
            if (constantBoolEquals(operands.lhs, true) or constantIntEquals(operands.lhs, -1)) {
                return appendFoldValueForResult(op, results, operands.lhs);
            }
            if (constantBoolEquals(operands.rhs, false) or constantIntEquals(operands.rhs, 0)) {
                return appendFoldValueForResult(op, results, operands.lhs);
            }
            if (constantBoolEquals(operands.lhs, false) or constantIntEquals(operands.lhs, 0)) {
                return appendFoldValueForResult(op, results, operands.rhs);
            }
        }

        pub fn foldXor(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (operands.lhs == operands.rhs) {
                if (isBoolType(op.results.items[0].type)) return appendBoolFoldAttributeForResult(op, results, false);
                return appendIntFoldAttributeForResult(op, results, 0);
            }
            if (constantBoolEquals(operands.rhs, false) or constantIntEquals(operands.rhs, 0)) {
                return appendFoldValueForResult(op, results, operands.lhs);
            }
            if (constantBoolEquals(operands.lhs, false) or constantIntEquals(operands.lhs, 0)) {
                return appendFoldValueForResult(op, results, operands.rhs);
            }
        }

        pub fn foldShift(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (constantIntEquals(operands.rhs, 0)) return appendFoldValueForResult(op, results, operands.lhs);
        }

        pub fn foldNot(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            if (op.operands.items.len != 1) return;
            if (op.results.items.len != 1) return;
            const value = constantBoolFromValue(op.operands.items[0].value) orelse return;
            try appendBoolFoldAttributeForResult(op, results, !value);
        }

        fn cmpSelfResult(predicate_value: CmpPredicate, ty: ir.Type) ?bool {
            if (isBoolType(ty)) {
                return switch (predicate_value) {
                    .eq => true,
                    .ne => false,
                    else => null,
                };
            }
            if (!isIntegerLikeType(ty)) return null;
            return switch (predicate_value) {
                .eq, .le, .ge, .sle, .sge, .ule, .uge => true,
                .ne, .lt, .gt, .slt, .sgt, .ult, .ugt => false,
            };
        }

        pub fn foldCmp(
            op_ptr: *const anyopaque,
            results: *ir.interfaces.FoldResults,
        ) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var declaration = try ir.interfaces.effects.inspect(op.allocator, @constCast(op));
            defer declaration.deinit(op.allocator);
            if (!ir.interfaces.effects.repeatableExpression(declaration.facts)) return;
            const operands = foldBinaryOperands(op) orelse return;
            if (operands.lhs != operands.rhs) return;
            const cmp = Dialect.CmpOp{ .op = @constCast(op) };
            const predicate = cmp.getPredicate() orelse return;
            const folded = cmpSelfResult(predicate, operands.lhs.type) orelse return;
            try appendBoolFoldAttributeForResult(op, results, folded);
        }
    };
}
