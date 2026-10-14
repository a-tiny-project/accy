const std = @import("std");
const ir = @import("../../core/root.zig");
const format = ir.format;
const types = @import("types.zig");
const fold_mod = @import("folds.zig");
const predicate_mod = @import("predicate.zig");

const admission = @import("root.zig").admission;

const commutative_op_traits = ir.OperationTraits{ .is_commutative = true };
const CmpPredicate = predicate_mod.CmpPredicate;

pub const ArithDialect = struct {
    pub const name = "arith";
    const op_specs = ir.dialects.opSpec.dialect(@This());
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    const folds = fold_mod.Folds(@This());
    const spec = ir.dialects.dialectSpec(@This(), .{
        .types = types.registeredTypeSpecs(),
    });

    pub const ScalarTypeKind: type = types.ScalarKind;

    pub const ConstantOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "constant",
            .operands = 0,
            .results = 1,
            .required_attrs = &.{"value"},
            .properties = ir.singleAttributePropertiesModel("arith.constant.properties", "value"),
            .interfaces = admission.entries(.constant),
        });
        pub const operation_name = operation_spec.name;

        pub fn createInt(ctx: *ir.Context, loc: ir.Location, result_type: ir.Type, value: i64) !ConstantOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{result_type});
            const value_attr = try getIntAttr(ctx, value);
            const uses_properties = try state.setPropertiesAttrIfRegistered(ctx, value_attr);

            const op = try builder.create(state);
            errdefer op.erase();
            if (!uses_properties) try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn createFloat(ctx: *ir.Context, loc: ir.Location, result_type: ir.Type, value: f64) !ConstantOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{result_type});
            const value_attr = try getFloatAttr(ctx, value);
            const uses_properties = try state.setPropertiesAttrIfRegistered(ctx, value_attr);

            const op = try builder.create(state);
            errdefer op.erase();
            if (!uses_properties) try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn createBool(ctx: *ir.Context, loc: ir.Location, value: bool) !ConstantOp {
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try getScalarType(ctx, .bool);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{bool_type});
            const value_attr = try getBoolAttr(ctx, value);
            const uses_properties = try state.setPropertiesAttrIfRegistered(ctx, value_attr);

            const op = try builder.create(state);
            errdefer op.erase();
            if (!uses_properties) try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const ConstantOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getIntValue(self: ConstantOp) ?i64 {
            const int_attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "value") orelse return null;
            return int_attr.getValue();
        }

        pub fn getFloatValue(self: ConstantOp) ?f64 {
            const float_attr = self.op.getAttrAs(ir.Attribute.FloatAttr, "value") orelse return null;
            return float_attr.getValue();
        }
    };

    pub const AddOp: type = op_templates.binarySameTypeFold("add", effectOptions(.add, commutativeSameTypeOptions()), folds.foldAdd);

    pub const SubOp: type = op_templates.binarySameTypeFold(
        "sub",
        effectOptions(.sub, sameTypeOptions(.{})),
        folds.foldSub,
    );

    pub const MulOp: type = op_templates.binarySameTypeFold("mul", effectOptions(.mul, commutativeSameTypeOptions()), folds.foldMul);

    pub const UmulhiOp: type = op_templates.binarySameType("umulhi", effectOptions(.umulhi, commutativeSameTypeOptions()));

    /// Overflow arithmetic returns the exact result modulo 2^64, then whether the exact
    /// mathematical result is unrepresentable in the operand type. Only i64 is admitted today.
    /// These operations neither trap nor inherit the single-result operations' folds.
    pub const AddoOp = overflowOp("addo", .addo);
    pub const SuboOp = overflowOp("subo", .subo);
    pub const MuloOp = overflowOp("mulo", .mulo);

    pub const DivOp: type = op_templates.binarySameTypeFold(
        "div",
        effectOptions(.div, sameTypeOptions(.{})),
        folds.foldDiv,
    );

    pub const MaxOp: type = op_templates.binarySameType("max", effectOptions(.max, sameTypeOptions(.{})));

    pub const MinOp: type = op_templates.binarySameType("min", effectOptions(.min, sameTypeOptions(.{})));

    pub const CmpOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "cmp",
            .interfaces = admission.entries(.cmp),
            .operands = 2,
            .results = 1,
            .required_attrs = &.{"predicate"},
            .result_types = admission.exactResults(.compare),
            .dynamic_traits = .{ir.traits.SameTypeOperands},
        });
        pub const operation_name = operation_spec.name;
        pub const fold = folds.foldCmp;

        pub fn create(ctx: *ir.Context, loc: ir.Location, predicate: CmpPredicate, lhs: *ir.Value, rhs: *ir.Value) !CmpOp {
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try getScalarType(ctx, .bool);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{bool_type});

            const op = try builder.create(state);
            errdefer op.erase();

            var buf: [8]u8 = undefined;
            const pred_str = try std.fmt.bufPrint(&buf, "{s}", .{predicate.toString()});
            const pred_attr = try ctx.getDialectAttr("arith.predicate", pred_str);
            try op.setAttr("predicate", pred_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const CmpOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getPredicate(self: CmpOp) ?CmpPredicate {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "predicate")) |dialect_attr| {
                inline for (@typeInfo(CmpPredicate).@"enum".field_names, std.meta.tags(CmpPredicate)) |field_name, value| {
                    if (std.mem.eql(u8, dialect_attr.payload, field_name)) {
                        return value;
                    }
                }
            }
            return null;
        }
    };

    pub const CastOp: type = op_templates.unaryExplicitTypeFold(
        "cast",
        effectOptions(.cast, .{}),
        folds.foldSameTypeUnary,
    );

    pub const SelectOp: type = op_templates.selectSameTypeFold("select", .{
        .interfaces = admission.entries(.select),
        .traits = .{},
        .dynamic_traits = ir.dialects.opSpec.dynamicTraits(.{
            ir.traits.TypesMatchWith(.{
                .label = "select_result_eq_true",
                .target = .{ .result = 0 },
                .source = .{ .operand = 1 },
            }),
            ir.traits.TypesMatchWith(.{
                .label = "select_true_eq_false",
                .target = .{ .operand = 1 },
                .source = .{ .operand = 2 },
            }),
        }),
        .operand_types = admission.exactOperands(.select),
    }, folds.foldSelect);

    pub const RemOp: type = op_templates.binarySameType("rem", effectOptions(.rem, sameTypeOptions(.{})));

    pub const FmaOp: type = op_templates.ternarySameType("fma", effectOptions(.fma, sameTypeOptions(.{})));

    pub const NegOp: type = op_templates.unarySameType("neg", effectOptions(.neg, sameTypeOptions(.{})));

    pub const AbsOp: type = op_templates.unarySameType("abs", effectOptions(.abs, sameTypeOptions(.{})));

    pub const SqrtOp: type = op_templates.unarySameType("sqrt", effectOptions(.sqrt, sameTypeOptions(.{})));

    pub const ExpOp: type = op_templates.unarySameType("exp", effectOptions(.exp, sameTypeOptions(.{})));

    pub const LogOp: type = op_templates.unarySameType("log", effectOptions(.log, sameTypeOptions(.{})));

    pub const Log1pOp: type = op_templates.unarySameType("log1p", effectOptions(.log1p, sameTypeOptions(.{})));

    pub const Expm1Op: type = op_templates.unarySameType("expm1", effectOptions(.expm1, sameTypeOptions(.{})));

    pub const TanhOp: type = op_templates.unarySameType("tanh", effectOptions(.tanh, sameTypeOptions(.{})));

    pub const SinOp: type = op_templates.unarySameType("sin", effectOptions(.sin, sameTypeOptions(.{})));

    pub const CosOp: type = op_templates.unarySameType("cos", effectOptions(.cos, sameTypeOptions(.{})));

    pub const TanOp: type = op_templates.unarySameType("tan", effectOptions(.tan, sameTypeOptions(.{})));

    pub const FloorOp: type = op_templates.unarySameType("floor", effectOptions(.floor, sameTypeOptions(.{})));

    pub const RoundOp: type = op_templates.unarySameType("round", effectOptions(.round, sameTypeOptions(.{})));

    pub const TruncOp: type = op_templates.unarySameType("trunc", effectOptions(.trunc, sameTypeOptions(.{})));

    pub const Tf32RoundOp: type = op_templates.unarySameType("tf32_round", sameTypeOptions(.{}));

    pub const PowOp: type = op_templates.binarySameType("pow", effectOptions(.pow, sameTypeOptions(.{})));

    pub const Atan2Op: type = op_templates.binarySameType("atan2", sameTypeOptions(.{}));

    pub const AndOp: type = op_templates.binarySameTypeFold(
        "and",
        effectOptions(.@"and", commutativeSameTypeOptions()),
        folds.foldAnd,
    );

    pub const OrOp: type = op_templates.binarySameTypeFold(
        "or",
        effectOptions(.@"or", commutativeSameTypeOptions()),
        folds.foldOr,
    );

    pub const XorOp: type = op_templates.binarySameTypeFold(
        "xor",
        effectOptions(.xor, commutativeSameTypeOptions()),
        folds.foldXor,
    );

    pub const NotOp: type = op_templates.unarySameTypeFold(
        "not",
        effectOptions(.not, sameTypeOptions(.{})),
        folds.foldNot,
    );

    pub const PopCountOp: type = op_templates.unarySameType(
        "popcount",
        effectOptions(.popcount, sameTypeOptions(.{})),
    );

    pub const ShlOp: type = op_templates.binarySameTypeFold(
        "shl",
        effectOptions(.shl, sameTypeOptions(.{})),
        folds.foldShift,
    );

    pub const ShrOp: type = op_templates.binarySameTypeFold(
        "shr",
        effectOptions(.shr, sameTypeOptions(.{})),
        folds.foldShift,
    );

    pub const UshrOp: type = op_templates.binarySameTypeFold(
        "ushr",
        effectOptions(.ushr, sameTypeOptions(.{})),
        folds.foldShift,
    );

    pub const BitcastOp: type = op_templates.unaryExplicitTypeFold(
        "bitcast",
        effectOptions(.bitcast, .{}),
        folds.foldSameTypeUnary,
    );

    pub const SplatOp: type = op_templates.unaryExplicitType("splat", effectOptions(.splat, .{}));

    pub const ExtractOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "extract",
            .interfaces = admission.entries(.extract),
            .operands = 1,
            .results = 1,
            .required_attrs = &.{"index"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            vector: *ir.Value,
            index: i64,
            result_type: ir.Type,
        ) !ExtractOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{vector});
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            errdefer op.erase();
            const idx_attr = try getIntAttr(ctx, index);
            try op.setAttr("index", idx_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const ExtractOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getVector(self: ExtractOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndex(self: ExtractOp) ?i64 {
            const int_attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "index") orelse return null;
            return int_attr.getValue();
        }
    };

    pub const InsertOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "insert",
            .interfaces = admission.entries(.insert),
            .operands = 2,
            .results = 1,
            .required_attrs = &.{"index"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            vector: *ir.Value,
            scalar: *ir.Value,
            index: i64,
        ) !InsertOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ vector, scalar });
            state.addTypes(&.{vector.type});

            const op = try builder.create(state);
            errdefer op.erase();
            const idx_attr = try getIntAttr(ctx, index);
            try op.setAttr("index", idx_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const InsertOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getVector(self: InsertOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getScalar(self: InsertOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getIndex(self: InsertOp) ?i64 {
            const int_attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "index") orelse return null;
            return int_attr.getValue();
        }
    };

    pub const VecCmpOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "vec_cmp",
            .interfaces = admission.entries(.vec_cmp),
            .operands = 2,
            .results = 1,
            .required_attrs = &.{"predicate"},
            .dynamic_traits = .{ir.traits.SameTypeOperands},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            predicate: CmpPredicate,
            lhs: *ir.Value,
            rhs: *ir.Value,
            result_type: ir.Type,
        ) !VecCmpOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            errdefer op.erase();

            var buf: [8]u8 = undefined;
            const pred_str = try std.fmt.bufPrint(&buf, "{s}", .{predicate.toString()});
            const pred_attr = try ctx.getDialectAttr(ArithDialect.name ++ ".predicate", pred_str);
            try op.setAttr("predicate", pred_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const VecCmpOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getPredicate(self: VecCmpOp) ?CmpPredicate {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "predicate")) |dialect_attr| {
                inline for (
                    @typeInfo(CmpPredicate).@"enum".field_names,
                    std.meta.tags(CmpPredicate),
                ) |field_name, value| {
                    if (std.mem.eql(u8, dialect_attr.payload, field_name)) {
                        return value;
                    }
                }
            }
            return null;
        }
    };

    pub const VecShuffleOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "vec_shuffle",
            .interfaces = admission.entries(.vec_shuffle),
            .operands = 1,
            .results = 1,
            .required_attrs = &.{"indices"},
        });
        pub const operation_name = operation_spec.name;

        pub const IndexParseError = error{
            MissingIndices,
            InvalidIndices,
            TooManyIndices,
        };

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            vector: *ir.Value,
            result_type: ir.Type,
            indices: []const i64,
        ) !VecShuffleOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{vector});
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            errdefer op.erase();

            var buf: [256]u8 = undefined;
            var pos: usize = 0;
            for (indices, 0..) |idx, i| {
                if (i != 0) {
                    if (pos >= buf.len) return error.OutOfMemory;
                    buf[pos] = ',';
                    pos += 1;
                }
                pos = format.appendFmt(buf[0..], pos, "{d}", .{idx}) catch return error.OutOfMemory;
            }

            const indices_attr = try ctx.getStringAttr(buf[0..pos]);
            try op.setAttr("indices", indices_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const VecShuffleOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getVector(self: VecShuffleOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndices(self: VecShuffleOp, out: []i64) IndexParseError![]i64 {
            const str_attr = self.op.getAttrAs(ir.Attribute.StringAttr, "indices") orelse {
                if (self.op.getAttr("indices") == null) return error.MissingIndices;
                return error.InvalidIndices;
            };

            var it = std.mem.splitScalar(u8, str_attr.value, ',');
            var count: usize = 0;
            while (it.next()) |chunk| {
                if (chunk.len == 0) return error.InvalidIndices;
                if (count >= out.len) return error.TooManyIndices;
                const value = std.fmt.parseInt(i64, chunk, 10) catch return error.InvalidIndices;
                out[count] = value;
                count += 1;
            }
            return out[0..count];
        }
    };

    pub const VecConstantOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "vec_constant",
            .interfaces = admission.entries(.vec_constant),
            .operands = 0,
            .results = 1,
            .required_attrs = &.{"value"},
            .properties = ir.singleAttributePropertiesModel("arith.vec_constant.properties", "value"),
        });
        pub const operation_name = operation_spec.name;

        pub fn createInt(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
            value: i64,
        ) !VecConstantOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{result_type});
            const value_attr = try getIntAttr(ctx, value);
            const uses_properties = try state.setPropertiesAttrIfRegistered(ctx, value_attr);

            const op = try builder.create(state);
            errdefer op.erase();
            if (!uses_properties) try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn createFloat(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
            value: f64,
        ) !VecConstantOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{result_type});
            const value_attr = try getFloatAttr(ctx, value);
            const uses_properties = try state.setPropertiesAttrIfRegistered(ctx, value_attr);

            const op = try builder.create(state);
            errdefer op.erase();
            if (!uses_properties) try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const VecConstantOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getIntValue(self: VecConstantOp) ?i64 {
            const int_attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "value") orelse return null;
            return int_attr.getValue();
        }

        pub fn getFloatValue(self: VecConstantOp) ?f64 {
            const float_attr = self.op.getAttrAs(ir.Attribute.FloatAttr, "value") orelse return null;
            return float_attr.getValue();
        }
    };

    fn overflowOp(comptime mnemonic: []const u8, comptime kind: admission.Operation) type {
        return struct {
            op: *ir.Operation,

            pub const operation_spec = op_specs.leaf(.{
                .mnemonic = mnemonic,
                .operands = 2,
                .results = 2,
                .operand_types = admission.exactOperands(.overflow),
                .result_types = admission.exactResults(.overflow),
                .traits = ir.OperationTraits{ .is_commutative = kind != .subo },
                .interfaces = admission.entries(kind),
            });
            pub const operation_name = operation_spec.name;

            pub fn create(
                ctx: *ir.Context,
                loc: ir.Location,
                lhs: *ir.Value,
                rhs: *ir.Value,
            ) !@This() {
                var builder = ir.OperationBuilder.init(ctx);
                var state = op_specs.state(@This(), loc);
                state.addOperands(&.{ lhs, rhs });
                state.addTypes(&.{ lhs.type, try getScalarType(ctx, .bool) });
                return .{ .op = try builder.create(state) };
            }

            pub fn getResult(self: @This()) *ir.Value {
                return self.op.getResult(0).?;
            }

            pub fn getOverflow(self: @This()) *ir.Value {
                return self.op.getResult(1).?;
            }
        };
    }

    fn loadSpec(ctx: *ir.Context) !void {
        try ir.dialects.loadDialectSpec(ctx, spec);
    }

    fn sameTypeOptions(comptime traits: ir.OperationTraits) ir.dialects.opSpec.Options {
        return .{
            .traits = traits,
            .dynamic_traits = ir.dialects.opSpec.dynamicTraits(.{ir.traits.SameOperandsAndResultType}),
        };
    }

    fn effectOptions(
        comptime kind: admission.Operation,
        base: ir.dialects.opSpec.Options,
    ) ir.dialects.opSpec.Options {
        var result = base;
        result.interfaces = admission.entries(kind);
        return result;
    }

    fn commutativeSameTypeOptions() ir.dialects.opSpec.Options {
        return sameTypeOptions(commutative_op_traits);
    }

    pub fn getScalarType(ctx: *ir.Context, kind: ScalarTypeKind) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(types.scalarTypeName(kind));
    }

    pub fn getI8Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .i8);
    }

    pub fn getI16Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .i16);
    }

    pub fn getU8Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .u8);
    }

    pub fn getU16Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .u16);
    }

    pub fn getI32Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .i32);
    }

    pub fn getU32Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .u32);
    }

    pub fn getU64Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .u64);
    }

    pub fn getF16Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .f16);
    }

    pub fn getBf16Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .bf16);
    }

    pub fn getF64Type(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .f64);
    }

    pub fn getIndexType(ctx: *ir.Context) !ir.Type {
        return getScalarType(ctx, .index);
    }

    pub fn getVecType(ctx: *ir.Context, width: u32, element_type_name: []const u8) !?ir.Type {
        try loadSpec(ctx);
        const vec_name = types.vectorTypeNameForElement(width, element_type_name) orelse return null;
        return try ctx.getDialectTypeFromName(vec_name);
    }

    pub fn getVec4xF32Type(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(types.type_names.vec4xf32);
    }

    pub fn getVec4xI32Type(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(types.type_names.vec4xi32);
    }

    pub fn getVec8xF32Type(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(types.type_names.vec8xf32);
    }

    pub fn getVec8xI32Type(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(types.type_names.vec8xi32);
    }

    pub fn getIntAttr(ctx: *ir.Context, value: i64) !ir.Attribute {
        return ctx.getI64Attr(value);
    }

    pub fn getIntValue(attr: ir.Attribute) ?i64 {
        const int_attr = attr.cast(ir.Attribute.IntegerAttr) orelse return null;
        return int_attr.getValue();
    }

    pub fn getFloatAttr(ctx: *ir.Context, value: f64) !ir.Attribute {
        return ctx.getF64Attr(value);
    }

    pub fn getFloatValue(attr: ir.Attribute) ?f64 {
        const float_attr = attr.cast(ir.Attribute.FloatAttr) orelse return null;
        return float_attr.getValue();
    }

    pub fn getBoolAttr(ctx: *ir.Context, value: bool) !ir.Attribute {
        return ctx.getBoolAttr(value);
    }

    pub fn getBoolValue(attr: ir.Attribute) ?bool {
        const bool_attr = attr.cast(ir.Attribute.BoolAttr) orelse return null;
        return bool_attr.getValue();
    }
};

comptime {
    admission.assertCommonVerifier(ArithDialect);
}

const ConstructorResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) ConstructorResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: ConstructorResourceCounts, ctx: *const ir.Context) !void {
        try std.testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn expectConstructorCleanup(
    baseline: ConstructorResourceCounts,
    ctx: *ir.Context,
    constructed: anytype,
) !void {
    const value = constructed catch |err| {
        try baseline.expectEqual(ctx);
        return err;
    };
    value.op.erase();
    try baseline.expectEqual(ctx);
}

fn checkArithConstructorAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const vec4xi32_type = try ArithDialect.getVec4xI32Type(&ctx);
    const vec4xf32_type = try ArithDialect.getVec4xF32Type(&ctx);
    var lhs = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 10);
    var rhs = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 20);
    var scalar = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 3.0);
    var vector = try ArithDialect.VecConstantOp.createInt(&ctx, loc, vec4xi32_type, 1);
    var vector_rhs = try ArithDialect.VecConstantOp.createInt(&ctx, loc, vec4xi32_type, 2);
    const baseline = ConstructorResourceCounts.capture(&ctx);

    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 30),
    );
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 4.0),
    );
    try expectConstructorCleanup(baseline, &ctx, ArithDialect.ConstantOp.createBool(&ctx, loc, true));
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.CmpOp.create(&ctx, loc, .lt, lhs.getResult(), rhs.getResult()),
    );
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.ExtractOp.create(&ctx, loc, vector.getResult(), 3, i32_type),
    );
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.InsertOp.create(&ctx, loc, vector.getResult(), lhs.getResult(), 2),
    );
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.VecCmpOp.create(
            &ctx,
            loc,
            .gt,
            vector.getResult(),
            vector_rhs.getResult(),
            vec4xi32_type,
        ),
    );
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.VecShuffleOp.create(
            &ctx,
            loc,
            vector.getResult(),
            vec4xi32_type,
            &.{ 3, 1, 2, 0 },
        ),
    );
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.VecConstantOp.createInt(&ctx, loc, vec4xi32_type, 5),
    );
    try expectConstructorCleanup(
        baseline,
        &ctx,
        ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32_type, 6.0),
    );
    try std.testing.expectEqual(@as(f64, 3.0), scalar.getFloatValue().?);
}
