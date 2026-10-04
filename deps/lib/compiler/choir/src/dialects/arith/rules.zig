const std = @import("std");
const ir = @import("../../core/root.zig");
const egraph = @import("../../egraph/root.zig");
const types = @import("types.zig");
const fold_mod = @import("folds.zig");

pub fn Rules(comptime Dialect: type) type {
    return struct {
        const folds = fold_mod.Folds(Dialect);
        fn classifyEGraphType(ty: ir.Type) egraph.TypeClass {
            if (folds.isBoolType(ty)) return .boolean;
            if (folds.isIntegerLikeType(ty)) return .integer;
            const type_name = ty.getDialectTypeName() orelse return .other;
            if (std.mem.eql(u8, type_name, types.type_names.float16) or
                std.mem.eql(u8, type_name, types.type_names.float32) or
                std.mem.eql(u8, type_name, types.type_names.float64))
            {
                return .float;
            }
            return .other;
        }

        pub fn egraphConstantModel() egraph.ConstantModel {
            return .{
                .op_name = Dialect.ConstantOp.operation_name,
                .classify = classifyEGraphType,
                .storage = .properties,
            };
        }

        pub fn egraphCostModel() egraph.CostModel {
            return .{
                .operation = 4,
                .constant = 1,
                .constant_op_name = Dialect.ConstantOp.operation_name,
                .overrides = &.{
                    .{ .name = Dialect.ShlOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.ShrOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.UshrOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.AndOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.OrOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.XorOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.NotOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.NegOp.operation_name, .cost = 2 },
                    .{ .name = Dialect.MulOp.operation_name, .cost = 5 },
                    .{ .name = Dialect.DivOp.operation_name, .cost = 16 },
                    .{ .name = Dialect.RemOp.operation_name, .cost = 16 },
                },
            };
        }

        const integer_only: []const egraph.TypeClass = &.{.integer};
        const boolean_only: []const egraph.TypeClass = &.{.boolean};
        const integer_or_boolean: []const egraph.TypeClass = &.{ .integer, .boolean };
        const integer_or_float: []const egraph.TypeClass = &.{ .integer, .float };
        const float_only: []const egraph.TypeClass = &.{.float};

        pub const egraph_rules = [_]egraph.PatternRule{
            .{
                .name = "arith-add-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.AddOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-sub-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.SubOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-sub-self",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.SubOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .variable = 0 } } },
                .rhs = .{ .constant = .{ .int = 0 } },
            },
            .{
                .name = "arith-mul-one",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.MulOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 1 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-mul-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.MulOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .constant = .{ .int = 0 } },
            },
            .{
                .name = "arith-div-one",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.DivOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 1 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-rem-one",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.RemOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 1 } } } },
                .rhs = .{ .constant = .{ .int = 0 } },
            },
            .{
                .name = "arith-shl-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.ShlOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-shr-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.ShrOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-ushr-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.UshrOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-and-self",
                .classes = integer_or_boolean,
                .lhs = .{ .name = Dialect.AndOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .variable = 0 } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-or-self",
                .classes = integer_or_boolean,
                .lhs = .{ .name = Dialect.OrOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .variable = 0 } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-xor-self",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.XorOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .variable = 0 } } },
                .rhs = .{ .constant = .{ .int = 0 } },
            },
            .{
                .name = "arith-xor-self-bool",
                .classes = boolean_only,
                .lhs = .{ .name = Dialect.XorOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .variable = 0 } } },
                .rhs = .{ .constant = .{ .boolean = false } },
            },
            .{
                .name = "arith-and-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.AndOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .constant = .{ .int = 0 } },
            },
            .{
                .name = "arith-or-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.OrOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-xor-zero",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.XorOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-and-true",
                .classes = boolean_only,
                .lhs = .{ .name = Dialect.AndOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .boolean = true } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-and-false",
                .classes = boolean_only,
                .lhs = .{ .name = Dialect.AndOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .boolean = false } } } },
                .rhs = .{ .constant = .{ .boolean = false } },
            },
            .{
                .name = "arith-or-true",
                .classes = boolean_only,
                .lhs = .{ .name = Dialect.OrOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .boolean = true } } } },
                .rhs = .{ .constant = .{ .boolean = true } },
            },
            .{
                .name = "arith-or-false",
                .classes = boolean_only,
                .lhs = .{ .name = Dialect.OrOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .boolean = false } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-xor-false",
                .classes = boolean_only,
                .lhs = .{ .name = Dialect.XorOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .boolean = false } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-not-not",
                .classes = integer_or_boolean,
                .lhs = .{ .name = Dialect.NotOp.operation_name, .operands = &.{
                    .{ .operation = .{ .name = Dialect.NotOp.operation_name, .operands = &.{.{ .variable = 0 }} } },
                } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-neg-neg",
                .classes = integer_or_float,
                .lhs = .{ .name = Dialect.NegOp.operation_name, .operands = &.{
                    .{ .operation = .{ .name = Dialect.NegOp.operation_name, .operands = &.{.{ .variable = 0 }} } },
                } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-mul-two-shl",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.MulOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 2 } } } },
                .rhs = .{ .operation = .{ .name = Dialect.ShlOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 1 } } } } },
            },
            .{
                .name = "arith-mul-four-shl",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.MulOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 4 } } } },
                .rhs = .{ .operation = .{ .name = Dialect.ShlOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 2 } } } } },
            },
            .{
                .name = "arith-mul-eight-shl",
                .classes = integer_only,
                .lhs = .{ .name = Dialect.MulOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 8 } } } },
                .rhs = .{ .operation = .{ .name = Dialect.ShlOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 3 } } } } },
            },
            .{
                .name = "arith-fmul-one",
                .classes = float_only,
                .lhs = .{ .name = Dialect.MulOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .float = 1.0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-fdiv-one",
                .classes = float_only,
                .lhs = .{ .name = Dialect.DivOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .float = 1.0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-fsub-zero",
                .classes = float_only,
                .lhs = .{ .name = Dialect.SubOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .float = 0.0 } } } },
                .rhs = .{ .variable = 0 },
            },
            .{
                .name = "arith-fadd-negzero",
                .classes = float_only,
                .lhs = .{ .name = Dialect.AddOp.operation_name, .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .float = -0.0 } } } },
                .rhs = .{ .variable = 0 },
            },
        };

        pub fn populateEGraphRules(rule_set: *egraph.RewriteSet) anyerror!void {
            rule_set.setConstantModel(egraphConstantModel());
            rule_set.setCostModel(egraphCostModel());
            try rule_set.addPatterns(&egraph_rules);
        }
    };
}
