const std = @import("std");
const gpu_abi = @import("gpu_abi");
const alloc_arena = @import("alloc_arena");
const alloc_fixed = @import("alloc_fixed");
const builtin = @import("builtin");
const choir = @import("choir");
const ir = choir.ir;
const dialects_mod = choir.dialects;
const semantics = @import("semantics.zig");
const arith_mod = dialects_mod.arith;

const native_endian = builtin.cpu.arch.endian();

const effect_facts = ir.interfaces.effects;

pub const AccyChoirVerifyError = error{
    UnknownAccyOperation,
    ExpectedAccyTensorType,
    MalformedAccyTensorType,
    UnknownAccyDType,
    MissingAttribute,
    AttributeKindMismatch,
    ResultTypeMismatch,
    UnsupportedDType,
    ConstantPayloadLengthMismatch,
    InvalidKernelContract,
};

pub const AccyDialect = struct {
    pub const name = "accy";
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    const op_attr = ir.dialects.attribute;
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .types = &.{ir.dialects.typeName(tensor_type_name)},
    });

    pub const IotaOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "iota",
            .interfaces = &.{accyEffectsEntry()},
            .operands = 0,
            .results = .{"result"},

            .required_attrs = .{op_attr.integer("iota_dimension")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
            iota_dimension: i64,
        ) !IotaOp {
            const self = try leaf.createLeaf(ctx, loc, &.{}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "iota_dimension", iota_dimension);
            return self;
        }
    };

    pub const ConstantOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "constant",
            .interfaces = &.{accyEffectsEntry()},
            .operands = 0,
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("payload", "accy.constant_payload")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const payload_attr_name = leaf.dialectAttrName("payload");

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            payload: []const u8,
            result_type: ir.Type,
        ) !ConstantOp {
            const self = try leaf.createLeaf(ctx, loc, &.{}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "payload", payload);
            return self;
        }

        pub fn getPayload(self: ConstantOp) ?[]const u8 {
            return leaf.getDialectAttrPayload(self, "payload");
        }
    };

    pub const AddOp: type = op_templates.binarySameType("add", verifiedOptions());
    pub const SubOp: type = op_templates.binarySameType("sub", verifiedOptions());
    pub const MulOp: type = op_templates.binarySameType("mul", verifiedOptions());
    pub const DivOp: type = op_templates.binarySameType("div", verifiedOptions());
    pub const MaxOp: type = op_templates.binarySameType("max", verifiedOptions());
    pub const MinOp: type = op_templates.binarySameType("min", verifiedOptions());
    pub const NegOp: type = op_templates.unarySameType("neg", verifiedOptions());
    pub const ExpOp: type = op_templates.unarySameType("exp", verifiedOptions());
    pub const LogOp: type = op_templates.unarySameType("log", verifiedOptions());
    pub const TanhOp: type = op_templates.unarySameType("tanh", verifiedOptions());
    pub const SqrtOp: type = op_templates.unarySameType("sqrt", verifiedOptions());

    pub const ActivationOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "activation",
            .operands = .{"input"},
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("activation_kind", "accy.activation_kind")},
            .interfaces = &.{ ir.dialects.opSpec.verifier(verifyAccyChoirOp), accyEffectsEntry() },
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;
        pub const activation_kind_attr_name = leaf.dialectAttrName("activation_kind");

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            result_type: ir.Type,
            kind: semantics.ActivationKind,
        ) !ActivationOp {
            const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "activation_kind", @tagName(kind));
            return self;
        }

        pub fn getKind(self: ActivationOp) ?[]const u8 {
            return leaf.getDialectAttrPayload(self, "activation_kind");
        }
    };

    pub const AbsOp: type = op_templates.unarySameType("abs", verifiedOptions());
    pub const SinOp: type = op_templates.unarySameType("sin", verifiedOptions());
    pub const CosOp: type = op_templates.unarySameType("cos", verifiedOptions());
    pub const TanOp: type = op_templates.unarySameType("tan", verifiedOptions());
    pub const FloorOp: type = op_templates.unarySameType("floor", verifiedOptions());
    pub const RoundOp: type = op_templates.unarySameType("round", verifiedOptions());
    pub const TruncOp: type = op_templates.unarySameType("trunc", verifiedOptions());
    pub const PowOp: type = op_templates.binarySameType("pow", verifiedOptions());
    pub const Atan2Op: type = op_templates.binarySameType("atan2", verifiedOptions());

    pub const CompareOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "compare",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "lhs", "rhs" },
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("compare_direction", "accy.compare_direction")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            lhs: *ir.Value,
            rhs: *ir.Value,
            result_type: ir.Type,
            direction: []const u8,
        ) !CompareOp {
            const self = try leaf.createLeaf(ctx, loc, &.{ lhs, rhs }, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "compare_direction", direction);
            return self;
        }
    };

    pub const ConvertOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "convert",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{"input"},
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("convert_to", "accy.convert_to")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            result_type: ir.Type,
            target_dtype: []const u8,
        ) !ConvertOp {
            const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "convert_to", target_dtype);
            return self;
        }
    };

    pub const SelectOp: type = op_templates.selectSameType("select", verifiedOptions());

    pub const ReduceOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "reduce",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "operand", "init" },
            .results = .{"result"},

            .required_attrs = .{
                op_attr.dialect("dimensions", "accy.reduce_dimensions"),
                op_attr.dialect("reducer_kind", "accy.reducer_kind"),
            },
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operand: *ir.Value,
            init: *ir.Value,
            result_type: ir.Type,
            reducer_kind: []const u8,
            dimensions: []const i64,
        ) !ReduceOp {
            const self = try leaf.createLeaf(ctx, loc, &.{ operand, init }, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "reducer_kind", reducer_kind);
            try leaf.setDialectAttrPayload(self, "dimensions", std.mem.sliceAsBytes(dimensions));
            return self;
        }
    };

    pub const DotGeneralOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "dot_general",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "lhs", "rhs" },
            .results = .{"result"},

            .required_attrs = .{
                op_attr.dialect("lhs_batch", "accy.dot_lhs_batch"),
                op_attr.dialect("lhs_contract", "accy.dot_lhs_contract"),
                op_attr.dialect("rhs_batch", "accy.dot_rhs_batch"),
                op_attr.dialect("rhs_contract", "accy.dot_rhs_contract"),
            },
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            lhs: *ir.Value,
            rhs: *ir.Value,
            result_type: ir.Type,
            lhs_batch: []const i64,
            rhs_batch: []const i64,
            lhs_contract: []const i64,
            rhs_contract: []const i64,
        ) !DotGeneralOp {
            const self = try leaf.createLeaf(ctx, loc, &.{ lhs, rhs }, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "lhs_batch", std.mem.sliceAsBytes(lhs_batch));
            try leaf.setDialectAttrPayload(self, "rhs_batch", std.mem.sliceAsBytes(rhs_batch));
            try leaf.setDialectAttrPayload(
                self,
                "lhs_contract",
                std.mem.sliceAsBytes(lhs_contract),
            );
            try leaf.setDialectAttrPayload(
                self,
                "rhs_contract",
                std.mem.sliceAsBytes(rhs_contract),
            );
            return self;
        }

        pub fn getLhsBatchPayload(self: DotGeneralOp) ?[]const u8 {
            return leaf.getDialectAttrPayload(self, "lhs_batch");
        }

        pub fn getRhsBatchPayload(self: DotGeneralOp) ?[]const u8 {
            return leaf.getDialectAttrPayload(self, "rhs_batch");
        }

        pub fn getLhsContractPayload(self: DotGeneralOp) ?[]const u8 {
            return leaf.getDialectAttrPayload(self, "lhs_contract");
        }

        pub fn getRhsContractPayload(self: DotGeneralOp) ?[]const u8 {
            return leaf.getDialectAttrPayload(self, "rhs_contract");
        }
    };

    pub const EinsumOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "einsum",
            .operands = ir.dialects.shape.atLeast(1),
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("equation", "accy.einsum_equation")},
            .interfaces = &.{ ir.dialects.opSpec.verifier(verifyAccyChoirOp), accyEffectsEntry() },
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;
        pub const equation_attr_name = leaf.dialectAttrName("equation");

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: []const *ir.Value,
            result_type: ir.Type,
            equation: []const u8,
        ) !EinsumOp {
            const self = try leaf.createLeaf(ctx, loc, operands, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "equation", equation);
            return self;
        }

        pub fn getEquation(self: EinsumOp) ?[]const u8 {
            return leaf.getDialectAttrPayload(self, "equation");
        }
    };

    pub const BroadcastOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "broadcast",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{"input"},
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("sizes", "accy.broadcast_sizes")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            result_type: ir.Type,
            sizes: []const i64,
        ) !BroadcastOp {
            const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "sizes", std.mem.sliceAsBytes(sizes));
            return self;
        }
    };

    pub const BroadcastInDimOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "broadcast_in_dim",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{"input"},
            .results = .{"result"},

            .required_attrs = .{
                op_attr.dialect("broadcast_dims", "accy.broadcast_dims"),
                op_attr.dialect("result_shape", "accy.broadcast_result_shape"),
            },
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            result_type: ir.Type,
            broadcast_dims: []const i64,
            result_shape: []const i64,
        ) !BroadcastInDimOp {
            const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(
                self,
                "broadcast_dims",
                std.mem.sliceAsBytes(broadcast_dims),
            );
            try leaf.setDialectAttrPayload(
                self,
                "result_shape",
                std.mem.sliceAsBytes(result_shape),
            );
            return self;
        }
    };

    pub const ReshapeOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "reshape",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{"input"},
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("new_shape", "accy.reshape_new_shape")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            result_type: ir.Type,
            new_shape: []const i64,
        ) !ReshapeOp {
            const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "new_shape", std.mem.sliceAsBytes(new_shape));
            return self;
        }
    };

    pub const TransposeOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "transpose",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{"input"},
            .results = .{"result"},

            .required_attrs = .{op_attr.dialect("permutation", "accy.transpose_permutation")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            result_type: ir.Type,
            permutation: []const i64,
        ) !TransposeOp {
            const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "permutation", std.mem.sliceAsBytes(permutation));
            return self;
        }
    };

    pub const SliceOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "slice",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{"input"},
            .results = .{"result"},

            .required_attrs = .{
                op_attr.dialect("limits", "accy.slice_limits"),
                op_attr.dialect("starts", "accy.slice_starts"),
                op_attr.dialect("strides", "accy.slice_strides"),
            },
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            result_type: ir.Type,
            starts: []const i64,
            limits: []const i64,
            strides: []const i64,
        ) !SliceOp {
            const self = try leaf.createLeaf(ctx, loc, &.{input}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "starts", std.mem.sliceAsBytes(starts));
            try leaf.setDialectAttrPayload(self, "limits", std.mem.sliceAsBytes(limits));
            try leaf.setDialectAttrPayload(self, "strides", std.mem.sliceAsBytes(strides));
            return self;
        }
    };

    pub const GatherOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "gather",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "input", "indices" },
            .results = .{"result"},

            .required_attrs = .{op_attr.integer("axis")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            indices: *ir.Value,
            result_type: ir.Type,
            axis: i64,
        ) !GatherOp {
            const self = try leaf.createLeaf(ctx, loc, &.{ input, indices }, &.{result_type});
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "axis", axis);
            return self;
        }

        pub fn getAxis(self: GatherOp) ?i64 {
            const attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "axis") orelse return null;
            return attr.getValue();
        }
    };

    pub const ScatterOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "scatter",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "input", "indices", "updates" },
            .results = .{"result"},

            .required_attrs = .{op_attr.integer("axis")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            indices: *ir.Value,
            updates: *ir.Value,
            result_type: ir.Type,
            axis: i64,
        ) !ScatterOp {
            const self = try leaf.createLeaf(
                ctx,
                loc,
                &.{ input, indices, updates },
                &.{result_type},
            );
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "axis", axis);
            return self;
        }

        pub fn getAxis(self: ScatterOp) ?i64 {
            const attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "axis") orelse return null;
            return attr.getValue();
        }
    };

    pub const ScatterAddOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "scatter_add",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "input", "indices", "updates" },
            .results = .{"result"},

            .required_attrs = .{op_attr.integer("axis")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            indices: *ir.Value,
            updates: *ir.Value,
            result_type: ir.Type,
            axis: i64,
        ) !ScatterAddOp {
            const self = try leaf.createLeaf(
                ctx,
                loc,
                &.{ input, indices, updates },
                &.{result_type},
            );
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "axis", axis);
            return self;
        }

        pub fn getAxis(self: ScatterAddOp) ?i64 {
            const attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "axis") orelse return null;
            return attr.getValue();
        }
    };

    pub const SparseCrossEntropyOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "sparse_cross_entropy",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "logits", "targets" },
            .results = .{"result"},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            logits: *ir.Value,
            targets: *ir.Value,
            result_type: ir.Type,
        ) !SparseCrossEntropyOp {
            return try leaf.createLeaf(ctx, loc, &.{ logits, targets }, &.{result_type});
        }
    };

    pub const PadOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "pad",
            .interfaces = &.{accyEffectsEntry()},
            .operands = .{ "input", "padding_value" },
            .results = .{"result"},

            .required_attrs = .{
                op_attr.dialect("edge_high", "accy.pad_edge_high"),
                op_attr.dialect("edge_low", "accy.pad_edge_low"),
                op_attr.dialect("interior", "accy.pad_interior"),
            },
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            input: *ir.Value,
            padding_value: *ir.Value,
            result_type: ir.Type,
            edge_low: []const i64,
            edge_high: []const i64,
            interior: []const i64,
        ) !PadOp {
            const self = try leaf.createLeaf(ctx, loc, &.{ input, padding_value }, &.{result_type});
            errdefer self.op.erase();
            try leaf.setDialectAttrPayload(self, "edge_low", std.mem.sliceAsBytes(edge_low));
            try leaf.setDialectAttrPayload(self, "edge_high", std.mem.sliceAsBytes(edge_high));
            try leaf.setDialectAttrPayload(self, "interior", std.mem.sliceAsBytes(interior));
            return self;
        }
    };

    pub const ConcatenateOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "concatenate",
            .interfaces = &.{accyEffectsEntry()},
            .operands = ir.dialects.shape.atLeast(1),
            .results = .{"result"},

            .required_attrs = .{op_attr.integer("dimension")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: []const *ir.Value,
            result_type: ir.Type,
            dimension: i64,
        ) !ConcatenateOp {
            const self = try leaf.createLeaf(ctx, loc, operands, &.{result_type});
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "dimension", dimension);
            return self;
        }
    };

    pub const KernelCallOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "kernel_call",
            .results = ir.dialects.shape.atLeast(1),
            .required_attrs = .{
                op_attr.dialect("target", "accy.kernel_call_target"),
                op_attr.integer("version"),
                op_attr.boolean("has_side_effects"),
                op_attr.dialect("operand_effects", "accy.kernel_call_operand_effects"),
                op_attr.dialect("result_aliases", "accy.kernel_call_result_aliases"),
            },
            .interfaces = &.{
                ir.dialects.opSpec.verifier(verifyAccyChoirOp),
                effect_facts.EffectOpInterface.entryFor(.{
                    .capacity = .{ .entries = 2, .per_operand = 2, .per_result = 1 },
                    .enumerate = kernelCallEffects,
                }),
            },
        });
        pub const operation_name = leaf.operation_name;
        pub const verify = verifyAccyChoirOp;
        pub const target_attr_name = leaf.dialectAttrName("target");
        pub const operand_effects_attr_name = leaf.dialectAttrName("operand_effects");
        pub const result_aliases_attr_name = leaf.dialectAttrName("result_aliases");
        pub const runtime_scalars_attr_name = "accy.kernel_call_runtime_scalars";
        pub const dialectAttrName = leaf.dialectAttrName;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: []const *ir.Value,
            result_types: []const ir.Type,
            target: []const u8,
            version: u32,
            has_side_effects: bool,
            operand_effects: []const semantics.KernelOperandEffect,
            result_aliases: []const ?usize,
        ) !KernelCallOp {
            const kernel_call = try leaf.createLeaf(ctx, loc, operands, result_types);
            errdefer kernel_call.op.erase();
            try leaf.setDialectAttrPayload(kernel_call, "target", target);
            try leaf.setI64Attr(kernel_call, "version", @intCast(version));
            try leaf.setBoolAttr(kernel_call, "has_side_effects", has_side_effects);
            try leaf.setDialectAttrPayload(
                kernel_call,
                "operand_effects",
                std.mem.sliceAsBytes(operand_effects),
            );
            try setKernelCallResultAliasesAttr(ctx, kernel_call.op, result_aliases);
            return kernel_call;
        }

        pub fn getResult(self: KernelCallOp, index: usize) ?*ir.Value {
            return self.op.getResult(index);
        }

        pub fn getFirstResult(self: KernelCallOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const KernelCallScalarKind = enum(u64) {
        i32,
        u32,
        i64,
        u64,
        f32,
        f64,
    };

    pub const KernelCallScalar = extern struct {
        kind: KernelCallScalarKind,
        bits: u64,
    };

    pub const max_kernel_call_runtime_scalars = 16;

    pub const KernelCallRuntimeScalars = struct {
        count: usize = 0,
        items: [max_kernel_call_runtime_scalars]KernelCallScalar = undefined,

        pub fn slice(self: *const KernelCallRuntimeScalars) []const KernelCallScalar {
            return self.items[0..self.count];
        }
    };

    pub const ScratchOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "scratch",
            .interfaces = &.{accyEffectsEntry()},
            .results = .{"result"},
            .required_attrs = .{op_attr.integer("words")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
            words: i64,
        ) !ScratchOp {
            const self = try leaf.createLeaf(ctx, loc, &.{}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "words", words);
            return self;
        }
    };

    pub const CumsumOp = struct {
        op: *ir.Operation,

        pub const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "cumsum",
            .interfaces = &.{accyEffectsEntry()},
            .operands = ir.dialects.shape.between(1, 2),
            .results = .{"result"},

            .required_attrs = .{op_attr.integer("axis")},
        });
        pub const operation_name = leaf.operation_name;
        pub const getResult = leaf.getResult;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operand: *ir.Value,
            result_type: ir.Type,
            axis: i64,
        ) !CumsumOp {
            const self = try leaf.createLeaf(ctx, loc, &.{operand}, &.{result_type});
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "axis", axis);
            return self;
        }

        pub fn createWithScratch(
            ctx: *ir.Context,
            loc: ir.Location,
            operand: *ir.Value,
            scratch: *ir.Value,
            result_type: ir.Type,
            axis: i64,
        ) !CumsumOp {
            const self = try leaf.createLeaf(ctx, loc, &.{ operand, scratch }, &.{result_type});
            errdefer self.op.erase();
            try leaf.setI64Attr(self, "axis", axis);
            return self;
        }
    };

    pub const IterateOp = struct {
        op: *ir.Operation,

        pub const template = op_templates.explicit(@This(), .{
            .mnemonic = "iterate",
            .interfaces = &.{accyEffectsEntry()},
            .operands = ir.dialects.shape.atLeast(1),
            .results = ir.dialects.shape.atLeast(1),
            .regions = ir.dialects.shape.exactly(1),
            .region_names = .{"body"},

            .required_attrs = .{op_attr.integer("max_iters")},
        });
        pub const operation_name = template.operation_name;
        pub const verify = verifyAccyChoirOp;
        pub const getRegion = template.getRegion;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            carries: []const *ir.Value,
            max_iters: i64,
        ) !IterateOp {
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            var carry_types_buffer: [8]ir.Type = undefined;
            if (carries.len > carry_types_buffer.len) return error.OutOfMemory;
            for (carries, 0..) |carry, index| {
                carry_types_buffer[index] = carry.type;
            }
            _ = try body_builder.createBlockWithLoc(&body, carry_types_buffer[0..carries.len], loc);
            var regions = [_]*ir.Region{&body};
            const self = try template.createOperation(
                ctx,
                loc,
                carries,
                carry_types_buffer[0..carries.len],
                &regions,
                &.{},
            );
            errdefer self.op.erase();
            try template.setI64Attr(self, "max_iters", max_iters);
            return self;
        }

        pub fn bodyBlock(self: IterateOp) ?*ir.Block {
            const region = self.op.getRegion(0) orelse return null;
            return region.getEntryBlock();
        }

        pub fn getMaxIters(self: IterateOp) ?i64 {
            return template.getI64Attr(self, "max_iters");
        }

        pub fn getResult(self: IterateOp, index: usize) ?*ir.Value {
            return self.op.getResult(index);
        }
    };

    pub const IterateYieldOp = struct {
        op: *ir.Operation,

        pub const term = op_templates.explicitTerminator(@This(), .{
            .mnemonic = "iterate_yield",
            .interfaces = &.{accyEffectsEntry()},
        });
        pub const operation_name = term.operation_name;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            predicate: *ir.Value,
            carries: []const *ir.Value,
        ) !IterateYieldOp {
            var operands_buffer: [9]*ir.Value = undefined;
            if (carries.len + 1 > operands_buffer.len) return error.OutOfMemory;
            operands_buffer[0] = predicate;
            for (carries, 0..) |carry, index| {
                operands_buffer[index + 1] = carry;
            }
            return try term.createTerminator(ctx, loc, operands_buffer[0 .. carries.len + 1], &.{});
        }
    };

    pub const ReturnOp = struct {
        op: *ir.Operation,

        pub const term = op_templates.explicitTerminator(@This(), .{
            .mnemonic = "return",
        });
        pub const operation_name = term.operation_name;
        pub const verify = verifyAccyChoirOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: []const *ir.Value,
        ) !ReturnOp {
            return try term.createTerminator(ctx, loc, operands, &.{});
        }
    };

    fn verifiedOptions() ir.dialects.opSpec.Options {
        return .{
            .interfaces = &.{ ir.dialects.opSpec.verifier(verifyAccyChoirOp), accyEffectsEntry() },
        };
    }

    pub fn setKernelCallRuntimeScalars(
        ctx: *ir.Context,
        op: *ir.Operation,
        scalars: []const KernelCallScalar,
    ) !void {
        if (scalars.len > max_kernel_call_runtime_scalars) return error.InvalidKernelCallContract;
        try op.setAttr(
            "runtime_scalars",
            try ctx.getDialectAttr(
                KernelCallOp.runtime_scalars_attr_name,
                std.mem.sliceAsBytes(scalars),
            ),
        );
    }

    pub fn kernelCallRuntimeScalars(op: *const ir.Operation) !?KernelCallRuntimeScalars {
        const attr = op.getAttr("runtime_scalars") orelse return null;
        if (!std.mem.eql(u8, attr.abstract.name, KernelCallOp.runtime_scalars_attr_name)) {
            return error.InvalidKernelCallContract;
        }
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse
            return error.InvalidKernelCallContract;
        const payload = dialect_attr.payload;
        const record_size = @sizeOf(KernelCallScalar);
        if (payload.len % record_size != 0) return error.InvalidKernelCallContract;
        const count = payload.len / record_size;
        if (count > max_kernel_call_runtime_scalars) return error.InvalidKernelCallContract;

        var decoded = KernelCallRuntimeScalars{ .count = count };
        for (0..count) |index| {
            const record = payload[index * record_size ..][0..record_size];
            const kind_bits = std.mem.readInt(u64, record[0..8], native_endian);
            const kind = std.enums.fromInt(KernelCallScalarKind, kind_bits) orelse {
                return error.InvalidKernelCallContract;
            };
            decoded.items[index] = .{
                .kind = kind,
                .bits = std.mem.readInt(u64, record[8..16], native_endian),
            };
        }
        return decoded;
    }
};

fn setKernelCallResultAliasesAttr(
    ctx: *ir.Context,
    op: *ir.Operation,
    result_aliases: []const ?usize,
) !void {
    const allocator = ir.context.transientAllocator(ctx);
    const aliases = try allocator.alloc(i64, result_aliases.len);
    defer allocator.free(aliases);
    for (result_aliases, 0..) |alias, i| {
        aliases[i] = if (alias) |operand_index| @intCast(operand_index) else -1;
    }
    try op.setAttr(
        "result_aliases",
        try ctx.getDialectAttr(
            AccyDialect.KernelCallOp.result_aliases_attr_name,
            std.mem.sliceAsBytes(aliases),
        ),
    );
}

fn verifyAccyChoirOp(op_ptr: *const anyopaque) anyerror!void {
    const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
    const kind = accyKindFromChoirName(op.name.name) orelse
        return AccyChoirVerifyError.UnknownAccyOperation;

    var stack_buffer: [8192]u8 = undefined;
    var stack_fallback = alloc_fixed.Fallback.init(
        &stack_buffer,
        ir.context.transientAllocator(op.context),
    );
    var arena_state = alloc_arena.Arena.init(stack_fallback.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input_types = try arena.alloc(semantics.Type, op.getNumOperands());
    for (op.getOperandValues(), 0..) |operand, i| {
        input_types[i] = try decodeTensorType(arena, operand.type);
    }

    const result_types = try arena.alloc(semantics.Type, op.getNumResults());
    for (op.getResultTypes(), 0..) |typ, i| {
        result_types[i] = try decodeTensorType(arena, typ);
    }

    const attrs = try decodeAttrsForAccyOp(arena, op, kind, result_types);
    const inferred = try semantics.inferShape(kind, arena, input_types, attrs);
    try verifyDTypeLegality(kind, input_types, inferred);

    if (inferred.len != result_types.len) return AccyChoirVerifyError.ResultTypeMismatch;
    for (inferred, result_types) |expected, actual| {
        if (!expected.eql(actual)) return AccyChoirVerifyError.ResultTypeMismatch;
    }

    if (kind == .constant and result_types.len == 1 and attrs.len >= 1) {
        try verifyConstantPayloadLength(result_types[0], attrs[0].bytes.len);
    }

    if (kind == .iterate) {
        try verifyIterateRegion(op);
    }
}

fn verifyIterateRegion(op: *ir.Operation) anyerror!void {
    if (op.regions.items.len != 1) return AccyChoirVerifyError.InvalidKernelContract;
    const iterate = AccyDialect.IterateOp{ .op = op };
    const block = iterate.bodyBlock() orelse return AccyChoirVerifyError.InvalidKernelContract;
    const carry_count = op.getNumOperands();
    if (block.arguments.items.len != carry_count) return AccyChoirVerifyError.InvalidKernelContract;
    for (block.arguments.items, op.getOperandValues()) |arg, operand| {
        if (!arg.type.eql(operand.type)) return AccyChoirVerifyError.ResultTypeMismatch;
    }
    const terminator_any = block.operations.tail orelse
        return AccyChoirVerifyError.InvalidKernelContract;
    const terminator: *ir.Operation = @ptrCast(@alignCast(terminator_any));
    if (!std.mem.eql(u8, terminator.name.name, AccyDialect.IterateYieldOp.operation_name)) {
        return AccyChoirVerifyError.InvalidKernelContract;
    }
    if (terminator.getNumOperands() != carry_count + 1) {
        return AccyChoirVerifyError.InvalidKernelContract;
    }
    const yields = terminator.getOperandValues();
    for (yields[1..], op.getOperandValues()) |yielded, operand| {
        if (!yielded.type.eql(operand.type)) return AccyChoirVerifyError.ResultTypeMismatch;
    }
}

fn accyKindFromChoirName(choir_name: []const u8) ?semantics.OpKind {
    const prefix = "accy.";
    if (!std.mem.startsWith(u8, choir_name, prefix)) return null;
    const local_name = choir_name[prefix.len..];
    inline for (
        @typeInfo(semantics.OpKind).@"enum".field_names,
        @typeInfo(semantics.OpKind).@"enum".field_values,
    ) |field_name, field_name_value| {
        const field = .{ .name = field_name, .value = field_name_value };
        const kind: semantics.OpKind = @fromBackingInt(@intCast(field.value));
        if (std.mem.eql(u8, local_name, semantics.info(kind).name)) return kind;
    }
    return null;
}

pub fn decodeTensorType(arena: std.mem.Allocator, typ: ir.Type) !semantics.Type {
    const type_name = typ.getDialectTypeName() orelse
        return AccyChoirVerifyError.ExpectedAccyTensorType;
    if (!std.mem.eql(u8, type_name, tensor_type_name)) {
        return AccyChoirVerifyError.ExpectedAccyTensorType;
    }
    const key = typ.getDialectParamKey() orelse return AccyChoirVerifyError.MalformedAccyTensorType;
    const comma = std.mem.indexOfScalar(u8, key, ',') orelse
        return AccyChoirVerifyError.MalformedAccyTensorType;
    const dtype_name = key[0..comma];
    const dtype = gpu_abi.DType.fromName(dtype_name) orelse
        return AccyChoirVerifyError.UnknownAccyDType;
    const dims_text = key[comma + 1 ..];
    if (dims_text.len == 0) {
        return .{ .dtype = dtype, .dims = try arena.alloc(i64, 0) };
    }

    var dim_count: usize = 1;
    for (dims_text) |ch| {
        if (ch == 'x') dim_count += 1;
    }
    const dims = try arena.alloc(i64, dim_count);
    var iter = std.mem.splitScalar(u8, dims_text, 'x');
    var index: usize = 0;
    while (iter.next()) |part| {
        if (part.len == 0) return AccyChoirVerifyError.MalformedAccyTensorType;
        const dim = std.fmt.parseInt(
            i64,
            part,
            10,
        ) catch return AccyChoirVerifyError.MalformedAccyTensorType;
        if (dim < 0) return AccyChoirVerifyError.MalformedAccyTensorType;
        dims[index] = dim;
        index += 1;
    }
    if (index != dim_count) return AccyChoirVerifyError.MalformedAccyTensorType;
    return .{ .dtype = dtype, .dims = dims };
}

fn decodeAttrsForAccyOp(
    arena: std.mem.Allocator,
    op: *ir.Operation,
    kind: semantics.OpKind,
    result_types: []const semantics.Type,
) ![]const semantics.Attribute {
    switch (kind) {
        .constant => {
            const result_type = try requireSingleResultType(result_types);
            const attrs = try arena.alloc(semantics.Attribute, 3);
            attrs[0] = .{ .bytes = try requireDialectPayload(
                op,
                "payload",
                AccyDialect.ConstantOp.payload_attr_name,
            ) };
            attrs[1] = .{ .dtype = result_type.dtype };
            attrs[2] = .{ .i64_list = result_type.dims };
            return attrs;
        },
        .iota => {
            const result_type = try requireSingleResultType(result_types);
            const attrs = try arena.alloc(semantics.Attribute, 3);
            attrs[0] = .{ .i64 = try requireIntegerAttr(op, "iota_dimension") };
            attrs[1] = .{ .dtype = result_type.dtype };
            attrs[2] = .{ .i64_list = result_type.dims };
            return attrs;
        },
        .compare => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            const payload = try requireDialectPayload(
                op,
                "compare_direction",
                AccyDialect.CompareOp.dialectAttrName("compare_direction"),
            );
            attrs[0] = .{
                .compare_direction = try parseEnumTag(semantics.CompareDirection, payload),
            };
            return attrs;
        },
        .activation => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            const payload = try requireDialectPayload(
                op,
                "activation_kind",
                AccyDialect.ActivationOp.activation_kind_attr_name,
            );
            attrs[0] = .{ .activation_kind = try parseEnumTag(semantics.ActivationKind, payload) };
            return attrs;
        },
        .convert => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            const payload = try requireDialectPayload(
                op,
                "convert_to",
                AccyDialect.ConvertOp.dialectAttrName("convert_to"),
            );
            attrs[0] = .{ .dtype = gpu_abi.DType.fromName(payload) orelse
                return AccyChoirVerifyError.UnknownAccyDType };
            return attrs;
        },
        .reduce => {
            const attrs = try arena.alloc(semantics.Attribute, 2);
            const reducer_payload = try requireDialectPayload(
                op,
                "reducer_kind",
                AccyDialect.ReduceOp.dialectAttrName("reducer_kind"),
            );
            attrs[0] = .{
                .reducer_kind = try parseEnumTag(semantics.ReducerKind, reducer_payload),
            };
            attrs[1] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "dimensions",
                AccyDialect.ReduceOp.dialectAttrName("dimensions"),
            ) };
            return attrs;
        },
        .dot_general => {
            const result_type = try requireSingleResultType(result_types);
            const attrs = try arena.alloc(semantics.Attribute, 5);
            attrs[0] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "lhs_batch",
                AccyDialect.DotGeneralOp.dialectAttrName("lhs_batch"),
            ) };
            attrs[1] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "rhs_batch",
                AccyDialect.DotGeneralOp.dialectAttrName("rhs_batch"),
            ) };
            attrs[2] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "lhs_contract",
                AccyDialect.DotGeneralOp.dialectAttrName("lhs_contract"),
            ) };
            attrs[3] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "rhs_contract",
                AccyDialect.DotGeneralOp.dialectAttrName("rhs_contract"),
            ) };
            attrs[4] = .{ .dtype = result_type.dtype };
            return attrs;
        },
        .einsum => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .einsum = try requireDialectPayload(
                op,
                "equation",
                AccyDialect.EinsumOp.equation_attr_name,
            ) };
            return attrs;
        },
        .broadcast => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "sizes",
                AccyDialect.BroadcastOp.dialectAttrName("sizes"),
            ) };
            return attrs;
        },
        .broadcast_in_dim => {
            const attrs = try arena.alloc(semantics.Attribute, 2);
            attrs[0] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "broadcast_dims",
                AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims"),
            ) };
            attrs[1] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "result_shape",
                AccyDialect.BroadcastInDimOp.dialectAttrName("result_shape"),
            ) };
            return attrs;
        },
        .reshape => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "new_shape",
                AccyDialect.ReshapeOp.dialectAttrName("new_shape"),
            ) };
            return attrs;
        },
        .transpose => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "permutation",
                AccyDialect.TransposeOp.dialectAttrName("permutation"),
            ) };
            return attrs;
        },
        .slice => {
            const attrs = try arena.alloc(semantics.Attribute, 3);
            attrs[0] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "starts",
                AccyDialect.SliceOp.dialectAttrName("starts"),
            ) };
            attrs[1] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "limits",
                AccyDialect.SliceOp.dialectAttrName("limits"),
            ) };
            attrs[2] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "strides",
                AccyDialect.SliceOp.dialectAttrName("strides"),
            ) };
            return attrs;
        },
        .gather => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64 = try requireIntegerAttr(op, "axis") };
            return attrs;
        },
        .iterate => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64 = try requireIntegerAttr(op, "max_iters") };
            return attrs;
        },
        .cumsum => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64 = try requireIntegerAttr(op, "axis") };
            return attrs;
        },
        .scratch => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64 = try requireIntegerAttr(op, "words") };
            return attrs;
        },
        .scatter, .scatter_add => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64 = try requireIntegerAttr(op, "axis") };
            return attrs;
        },
        .pad => {
            const attrs = try arena.alloc(semantics.Attribute, 3);
            attrs[0] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "edge_low",
                AccyDialect.PadOp.dialectAttrName("edge_low"),
            ) };
            attrs[1] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "edge_high",
                AccyDialect.PadOp.dialectAttrName("edge_high"),
            ) };
            attrs[2] = .{ .i64_list = try requireI64ListAttr(
                arena,
                op,
                "interior",
                AccyDialect.PadOp.dialectAttrName("interior"),
            ) };
            return attrs;
        },
        .concatenate => {
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .i64 = try requireIntegerAttr(op, "dimension") };
            return attrs;
        },
        .kernel_call => {
            const version_i64 = try requireIntegerAttr(op, "version");
            if (version_i64 < 0 or version_i64 > std.math.maxInt(u32)) {
                return AccyChoirVerifyError.AttributeKindMismatch;
            }
            const attrs = try arena.alloc(semantics.Attribute, 1);
            attrs[0] = .{ .kernel_call = .{
                .target = try requireDialectPayload(
                    op,
                    "target",
                    AccyDialect.KernelCallOp.target_attr_name,
                ),
                .version = @intCast(version_i64),
                .has_side_effects = try requireBoolAttr(op, "has_side_effects"),
                .operand_effects = try requireKernelOperandEffectsAttr(
                    arena,
                    op,
                    op.getNumOperands(),
                ),
                .result_aliases = try requireKernelResultAliasesAttr(arena, op, op.getNumResults()),
                .results = result_types,
            } };
            return attrs;
        },
        .parameter,
        => return AccyChoirVerifyError.UnknownAccyOperation,
        .add,
        .sub,
        .mul,
        .div,
        .max,
        .min,
        .pow,
        .atan2,
        .neg,
        .exp,
        .log,
        .tanh,
        .sqrt,
        .abs,
        .sin,
        .cos,
        .tan,
        .floor,
        .round,
        .trunc,
        .select,
        .sparse_cross_entropy,
        .iterate_yield,
        .@"return",
        => return arena.alloc(semantics.Attribute, 0),
    }
}

fn requireSingleResultType(
    result_types: []const semantics.Type,
) AccyChoirVerifyError!semantics.Type {
    if (result_types.len != 1) return AccyChoirVerifyError.ResultTypeMismatch;
    return result_types[0];
}

fn requireDialectPayload(
    op: *const ir.Operation,
    attr_name: []const u8,
    dialect_attr_name: []const u8,
) AccyChoirVerifyError![]const u8 {
    const attr = op.getAttr(attr_name) orelse return AccyChoirVerifyError.MissingAttribute;
    if (!std.mem.eql(u8, attr.abstract.name, dialect_attr_name)) {
        return AccyChoirVerifyError.AttributeKindMismatch;
    }
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse
        return AccyChoirVerifyError.AttributeKindMismatch;
    return dialect_attr.payload;
}

fn requireIntegerAttr(op: *const ir.Operation, attr_name: []const u8) AccyChoirVerifyError!i64 {
    const attr = op.getAttr(attr_name) orelse return AccyChoirVerifyError.MissingAttribute;
    if (!std.mem.eql(u8, attr.abstract.name, "builtin.integer")) {
        return AccyChoirVerifyError.AttributeKindMismatch;
    }
    const int_attr = attr.cast(ir.Attribute.IntegerAttr) orelse
        return AccyChoirVerifyError.AttributeKindMismatch;
    return int_attr.getValue();
}

fn requireBoolAttr(op: *const ir.Operation, attr_name: []const u8) AccyChoirVerifyError!bool {
    const attr = op.getAttr(attr_name) orelse return AccyChoirVerifyError.MissingAttribute;
    if (!std.mem.eql(u8, attr.abstract.name, "builtin.bool")) {
        return AccyChoirVerifyError.AttributeKindMismatch;
    }
    const bool_attr = attr.cast(ir.Attribute.BoolAttr) orelse
        return AccyChoirVerifyError.AttributeKindMismatch;
    return bool_attr.getValue();
}

fn requireI64ListAttr(
    arena: std.mem.Allocator,
    op: *const ir.Operation,
    attr_name: []const u8,
    dialect_attr_name: []const u8,
) ![]const i64 {
    const payload = try requireDialectPayload(op, attr_name, dialect_attr_name);
    if (payload.len % @sizeOf(i64) != 0) return AccyChoirVerifyError.AttributeKindMismatch;
    const values = try arena.alloc(i64, payload.len / @sizeOf(i64));
    for (values, 0..) |*value, i| {
        const start = i * @sizeOf(i64);
        @memcpy(std.mem.asBytes(value), payload[start..][0..@sizeOf(i64)]);
    }
    return values;
}

fn requireKernelOperandEffectsAttr(
    arena: std.mem.Allocator,
    op: *const ir.Operation,
    expected_len: usize,
) ![]const semantics.KernelOperandEffect {
    const payload = try requireDialectPayload(
        op,
        "operand_effects",
        AccyDialect.KernelCallOp.operand_effects_attr_name,
    );
    if (payload.len != expected_len) return AccyChoirVerifyError.InvalidKernelContract;
    const effects = try arena.alloc(semantics.KernelOperandEffect, payload.len);
    for (payload, 0..) |byte, i| {
        effects[i] = semantics.KernelOperandEffect.fromByte(byte) orelse
            return AccyChoirVerifyError.InvalidKernelContract;
    }
    return effects;
}

fn requireKernelResultAliasesAttr(
    arena: std.mem.Allocator,
    op: *const ir.Operation,
    expected_len: usize,
) ![]const ?usize {
    const values = try requireI64ListAttr(
        arena,
        op,
        "result_aliases",
        AccyDialect.KernelCallOp.result_aliases_attr_name,
    );
    if (values.len != expected_len) return AccyChoirVerifyError.InvalidKernelContract;
    const aliases = try arena.alloc(?usize, values.len);
    for (values, 0..) |value, i| {
        aliases[i] = if (value == -1) null else blk: {
            if (value < 0) return AccyChoirVerifyError.InvalidKernelContract;
            break :blk @intCast(value);
        };
    }
    return aliases;
}

fn parseEnumTag(comptime E: type, payload: []const u8) AccyChoirVerifyError!E {
    inline for (
        @typeInfo(E).@"enum".field_names,
        @typeInfo(E).@"enum".field_values,
    ) |field_name, field_name_value| {
        const field = .{ .name = field_name, .value = field_name_value };
        if (std.mem.eql(u8, payload, field.name)) return @fromBackingInt(@intCast(field.value));
    }
    return AccyChoirVerifyError.AttributeKindMismatch;
}

fn verifyDTypeLegality(
    kind: semantics.OpKind,
    input_types: []const semantics.Type,
    inferred: []const semantics.Type,
) AccyChoirVerifyError!void {
    const op_info = semantics.info(kind);
    if (input_types.len > 0) {
        for (input_types) |typ| {
            if (!op_info.supported_dtypes.allows(typ.dtype)) {
                return AccyChoirVerifyError.UnsupportedDType;
            }
        }
        return;
    }
    for (inferred) |typ| {
        if (!op_info.supported_dtypes.allows(typ.dtype)) {
            return AccyChoirVerifyError.UnsupportedDType;
        }
    }
}

fn verifyConstantPayloadLength(
    result_type: semantics.Type,
    payload_len: usize,
) AccyChoirVerifyError!void {
    var elements: usize = 1;
    for (result_type.dims) |dim| {
        if (dim < 0) return AccyChoirVerifyError.MalformedAccyTensorType;
        const dim_usize: usize = @intCast(dim);
        elements = std.math.mul(
            usize,
            elements,
            dim_usize,
        ) catch return AccyChoirVerifyError.ConstantPayloadLengthMismatch;
    }
    const expected = std.math.mul(
        usize,
        elements,
        result_type.dtype.sizeOf(),
    ) catch return AccyChoirVerifyError.ConstantPayloadLengthMismatch;
    if (payload_len != expected) return AccyChoirVerifyError.ConstantPayloadLengthMismatch;
}

fn loadAccyDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, AccyDialect.spec);
}

pub const tensor_type_name: []const u8 = "accy.tensor";

pub fn accyTensorType(
    ctx: *ir.Context,
    dt: gpu_abi.DType,
    dims: []const i64,
) !ir.Type {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const allocator = ir.context.transientAllocator(ctx);
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, dt.name());
    try buf.append(allocator, ',');
    var num_buf: [24]u8 = undefined;
    for (dims, 0..) |d, i| {
        if (i > 0) try buf.append(allocator, 'x');
        const num_str = try std.fmt.bufPrint(num_buf[0..], "{d}", .{d});
        try buf.appendSlice(allocator, num_str);
    }
    return ctx.getDialectTypeFromNameWithKey(tensor_type_name, buf.items);
}

pub const accy_package_extension = choir.extensions.PackageExtension{
    .name = "accy-choir-dialect",
    .dialects = &.{.{
        .name = "accy",
        .load = loadAccyDialect,
    }},
};

pub fn registerAccyDialect(ctx: *ir.Context) !void {
    try accy_package_extension.registerContext(ctx);
}

const testing = std.testing;

const FactoryResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) FactoryResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: FactoryResourceCounts, ctx: *const ir.Context) !void {
        try testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn exerciseAttributedFactories(ctx: *ir.Context) !void {
    const loc = ir.Location.getUnknown();
    const tensor_type = try accyTensorType(ctx, .f32, &.{4});
    const scalar_type = try accyTensorType(ctx, .f32, &.{});
    const indices_type = try accyTensorType(ctx, .i32, &.{4});
    const predicate_type = try accyTensorType(ctx, .i1, &.{4});

    const lhs = try AccyDialect.IotaOp.create(ctx, loc, tensor_type, 0);
    defer lhs.op.erase();
    const rhs = try AccyDialect.IotaOp.create(ctx, loc, tensor_type, 0);
    defer rhs.op.erase();
    const indices = try AccyDialect.IotaOp.create(ctx, loc, indices_type, 0);
    defer indices.op.erase();
    const predicate = try AccyDialect.IotaOp.create(ctx, loc, predicate_type, 0);
    defer predicate.op.erase();

    const tensor_payload = [_]f32{ 0, 1, 2, 3 };
    const constant = try AccyDialect.ConstantOp.create(
        ctx,
        loc,
        std.mem.sliceAsBytes(&tensor_payload),
        tensor_type,
    );
    defer constant.op.erase();
    const scalar_payload = [_]f32{0};
    const padding_value = try AccyDialect.ConstantOp.create(
        ctx,
        loc,
        std.mem.sliceAsBytes(&scalar_payload),
        scalar_type,
    );
    defer padding_value.op.erase();

    const activation = try AccyDialect.ActivationOp.create(
        ctx,
        loc,
        lhs.getResult(),
        tensor_type,
        .gelu,
    );
    defer activation.op.erase();
    const compare = try AccyDialect.CompareOp.create(
        ctx,
        loc,
        lhs.getResult(),
        rhs.getResult(),
        predicate_type,
        "lt",
    );
    defer compare.op.erase();
    const convert = try AccyDialect.ConvertOp.create(
        ctx,
        loc,
        lhs.getResult(),
        indices_type,
        "i32",
    );
    defer convert.op.erase();
    const reduce = try AccyDialect.ReduceOp.create(
        ctx,
        loc,
        lhs.getResult(),
        padding_value.getResult(),
        scalar_type,
        "sum",
        &.{0},
    );
    defer reduce.op.erase();
    const dot_general = try AccyDialect.DotGeneralOp.create(
        ctx,
        loc,
        lhs.getResult(),
        rhs.getResult(),
        tensor_type,
        &.{},
        &.{},
        &.{0},
        &.{0},
    );
    defer dot_general.op.erase();
    const einsum = try AccyDialect.EinsumOp.create(
        ctx,
        loc,
        &.{ lhs.getResult(), rhs.getResult() },
        tensor_type,
        "i,i->i",
    );
    defer einsum.op.erase();
    const broadcast = try AccyDialect.BroadcastOp.create(
        ctx,
        loc,
        padding_value.getResult(),
        tensor_type,
        &.{4},
    );
    defer broadcast.op.erase();
    const broadcast_in_dim = try AccyDialect.BroadcastInDimOp.create(
        ctx,
        loc,
        lhs.getResult(),
        tensor_type,
        &.{0},
        &.{4},
    );
    defer broadcast_in_dim.op.erase();
    const reshape = try AccyDialect.ReshapeOp.create(ctx, loc, lhs.getResult(), tensor_type, &.{4});
    defer reshape.op.erase();
    const transpose = try AccyDialect.TransposeOp.create(
        ctx,
        loc,
        lhs.getResult(),
        tensor_type,
        &.{0},
    );
    defer transpose.op.erase();
    const slice = try AccyDialect.SliceOp.create(
        ctx,
        loc,
        lhs.getResult(),
        tensor_type,
        &.{0},
        &.{4},
        &.{1},
    );
    defer slice.op.erase();
    const gather = try AccyDialect.GatherOp.create(
        ctx,
        loc,
        lhs.getResult(),
        indices.getResult(),
        tensor_type,
        0,
    );
    defer gather.op.erase();
    const scatter = try AccyDialect.ScatterOp.create(
        ctx,
        loc,
        lhs.getResult(),
        indices.getResult(),
        rhs.getResult(),
        tensor_type,
        0,
    );
    defer scatter.op.erase();
    const scatter_add = try AccyDialect.ScatterAddOp.create(
        ctx,
        loc,
        lhs.getResult(),
        indices.getResult(),
        rhs.getResult(),
        tensor_type,
        0,
    );
    defer scatter_add.op.erase();
    const pad = try AccyDialect.PadOp.create(
        ctx,
        loc,
        lhs.getResult(),
        padding_value.getResult(),
        tensor_type,
        &.{1},
        &.{1},
        &.{0},
    );
    defer pad.op.erase();
    const concatenate = try AccyDialect.ConcatenateOp.create(
        ctx,
        loc,
        &.{ lhs.getResult(), rhs.getResult() },
        tensor_type,
        0,
    );
    defer concatenate.op.erase();
    const kernel_call = try AccyDialect.KernelCallOp.create(
        ctx,
        loc,
        &.{lhs.getResult()},
        &.{tensor_type},
        "allocation_failure_test",
        1,
        false,
        &.{.read},
        &.{null},
    );
    defer kernel_call.op.erase();
    const scratch = try AccyDialect.ScratchOp.create(ctx, loc, indices_type, 4);
    defer scratch.op.erase();
    const cumsum = try AccyDialect.CumsumOp.create(ctx, loc, lhs.getResult(), tensor_type, 0);
    defer cumsum.op.erase();
    const cumsum_with_scratch = try AccyDialect.CumsumOp.createWithScratch(
        ctx,
        loc,
        lhs.getResult(),
        scratch.getResult(),
        tensor_type,
        0,
    );
    defer cumsum_with_scratch.op.erase();
    const iterate = try AccyDialect.IterateOp.create(ctx, loc, &.{predicate.getResult()}, 4);
    defer iterate.op.erase();
}

fn checkAttributedFactoryAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try registerAccyDialect(&ctx);
    _ = try ctx.getOrLoadDialect("accy");
    const baseline = FactoryResourceCounts.capture(&ctx);
    exerciseAttributedFactories(&ctx) catch |err| {
        try baseline.expectEqual(&ctx);
        return err;
    };
    try baseline.expectEqual(&ctx);
}

comptime {
    _ = arith_mod;
}

fn kernelCallEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    collector.append(.{ .event = .{ .kind = .foreign } });
    collector.append(.{ .requirement = .{ .kind = .callee_contract, .subject = .operation } });
    kernelCallAccessEffects(op, collector);
    const aliases = op.getAttrAs(ir.Attribute.DialectAttr, "result_aliases");
    for (0..op.getNumResults()) |index| {
        var result = effect_facts.ResultFact{ .index = index };
        if (aliases) |attribute| {
            const width = @sizeOf(i64);
            if (index < attribute.payload.len / width) {
                const bytes = attribute.payload[index * width ..][0..width];
                const alias = std.mem.readInt(i64, bytes, native_endian);
                if (std.math.cast(usize, alias)) |operand_index| {
                    if (operand_index < op.getNumOperands()) {
                        result.alias = .{ .operand = operand_index };
                    }
                }
            }
        }
        collector.append(.{ .result = result });
    }
}

fn kernelCallAccessEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    const raw = op.getAttr("operand_effects") orelse return;
    const attribute = raw.cast(ir.Attribute.DialectAttr) orelse return;
    if (!std.mem.eql(u8, raw.abstract.name, AccyDialect.KernelCallOp.operand_effects_attr_name)) {
        return;
    }
    const count = @min(op.getNumOperands(), attribute.payload.len);
    for (attribute.payload[0..count], 0..) |byte, index| {
        const access = semantics.KernelOperandEffect.fromByte(byte) orelse continue;
        const resource = effect_facts.Resource{ .subject = .{ .operand = index } };
        if (access == .read or access == .read_write) {
            collector.append(.{ .event = .{ .kind = .read, .resource = resource } });
        }
        if (access == .write or access == .read_write) {
            collector.append(.{ .event = .{ .kind = .write, .resource = resource } });
        }
    }
}

fn accyEffectsEntry() ir.interfaces.InterfaceEntry {
    return effect_facts.EffectOpInterface.entryFor(.{
        .capacity = .{ .entries = 6, .per_operand = 1, .per_result = 1, .per_region = 1 },
        .enumerate = accyEffects,
    });
}

const StaticTensor = struct {
    dtype: gpu_abi.DType,
    elements: usize,
    dimensions: []const u8,

    fn extent(self: StaticTensor, axis: usize) ?usize {
        var dims = std.mem.splitScalar(u8, self.dimensions, 'x');
        var index: usize = 0;
        while (dims.next()) |part| : (index += 1) {
            if (index == axis) return std.fmt.parseInt(usize, part, 10) catch null;
        }
        return null;
    }

    fn rank(self: StaticTensor) usize {
        if (self.dimensions.len == 0) return 0;
        return std.mem.count(u8, self.dimensions, "x") + 1;
    }
};

fn staticTensor(typ: ir.Type) ?StaticTensor {
    if (!std.mem.eql(u8, typ.getDialectTypeName() orelse return null, tensor_type_name)) {
        return null;
    }
    const key = typ.getDialectParamKey() orelse return null;
    const comma = std.mem.indexOfScalar(u8, key, ',') orelse return null;
    const dtype = gpu_abi.DType.fromName(key[0..comma]) orelse return null;
    const dimensions = key[comma + 1 ..];
    var elements: usize = 1;
    if (dimensions.len != 0) {
        var dims = std.mem.splitScalar(u8, dimensions, 'x');
        while (dims.next()) |part| {
            const dim = std.fmt.parseInt(usize, part, 10) catch return null;
            elements = std.math.mul(usize, elements, dim) catch return null;
        }
    }
    return .{ .dtype = dtype, .elements = elements, .dimensions = dimensions };
}

fn accyEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    const kind = accyKindFromChoirName(op.name.name) orelse return;
    if (op.getAttr("has_side_effects") != null) return;
    switch (kind) {
        .kernel_call, .@"return", .parameter => return,
        .scratch => return scratchEffects(op, collector),
        .iterate, .iterate_yield => return iterationEffects(op, collector),
        else => {},
    }
    var floating = false;
    for (op.operands.items) |operand| {
        const typ = staticTensor(operand.value.type) orelse return;
        floating = floating or typ.dtype.isFloat();
    }
    for (op.results.items) |result| {
        const typ = staticTensor(result.type) orelse return;
        floating = floating or typ.dtype.isFloat();
    }
    switch (kind) {
        .max, .min, .neg, .abs => if (!floating) return,
        else => {},
    }
    collector.complete = true;
    collector.valueResults(op);
    if (floating) floatingEnvironmentEffects(op, collector);
    switch (kind) {
        .div => integerDivisionEffects(op, collector),
        .convert => conversionEffects(op, collector),
        .gather, .scatter, .scatter_add, .sparse_cross_entropy => indexEffects(op, kind, collector),
        .constant,
        .iota,
        .add,
        .sub,
        .mul,
        .max,
        .min,
        .pow,
        .compare,
        .neg,
        .exp,
        .log,
        .tanh,
        .sqrt,
        .activation,
        .abs,
        .sin,
        .cos,
        .tan,
        .floor,
        .round,
        .trunc,
        .atan2,
        .reduce,
        .dot_general,
        .einsum,
        .broadcast,
        .broadcast_in_dim,
        .reshape,
        .transpose,
        .slice,
        .pad,
        .concatenate,
        .select,
        .cumsum,
        => {},
        .kernel_call, .@"return", .parameter, .scratch, .iterate, .iterate_yield => unreachable,
    }
}

fn floatingEnvironmentEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    if (op.getContext().arithmetic_policy.permitsFloatingValues()) {
        collector.append(.{ .premise = .floating_environment });
        return;
    }
    collector.append(.{ .event = .{
        .kind = .state_observe,
        .resource = .{
            .subject = .{ .global = "arithmetic.environment" },
            .state_key = "floating_environment",
        },
    } });
    collector.append(.{ .requirement = .{ .kind = .execution_context, .subject = .operation } });
}

fn conditionedFailure(
    collector: *effect_facts.Collector,
    kind: effect_facts.RequirementKind,
    subject: effect_facts.Subject,
    name: []const u8,
) void {
    collector.append(.{ .requirement = .{ .kind = kind, .subject = subject } });
    collector.append(.{ .event = .{ .kind = .failure, .failure_name = name } });
}

const ConstantTensor = struct {
    typ: StaticTensor,
    payload: []const u8,

    fn number(self: ConstantTensor, index: usize) union(enum) { integer: i128, float: f64 } {
        std.debug.assert(index < self.typ.elements);
        const width = self.typ.dtype.sizeOf();
        const bytes = self.payload[index * width ..][0..width];
        return switch (self.typ.dtype) {
            .i1 => .{ .integer = if (bytes[0] == 0) 0 else 1 },
            .key => unreachable,
            .bf16 => .{ .float = (gpu_abi.Bf16{ .bits = std.mem.readInt(
                u16,
                bytes[0..2],
                native_endian,
            ) }).toF32() },
            inline else => |dt| value: {
                const T = dt.ZigType();
                const value = std.mem.bytesAsValue(T, bytes[0..@sizeOf(T)]).*;
                if (comptime dt.isFloat()) break :value .{ .float = @floatCast(value) };
                break :value .{ .integer = @intCast(value) };
            },
        };
    }
};

fn constantTensor(value: *ir.Value) ?ConstantTensor {
    const typ = staticTensor(value.type) orelse return null;
    if (typ.dtype == .key) return null;
    const raw = value.getDefiningOp() orelse return null;
    const op: *ir.Operation = @ptrCast(@alignCast(raw));
    if (!std.mem.eql(u8, op.name.name, AccyDialect.ConstantOp.operation_name)) return null;
    const payload = (AccyDialect.ConstantOp{ .op = op }).getPayload() orelse return null;
    const bytes = std.math.mul(usize, typ.elements, typ.dtype.sizeOf()) catch return null;
    if (payload.len != bytes) return null;
    return .{ .typ = typ, .payload = payload };
}

fn integerDivisionEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    if (op.getNumOperands() != 2) return;
    const lhs = op.getOperand(0).?;
    const rhs = op.getOperand(1).?;
    const typ = staticTensor(rhs.type) orelse return;
    if (typ.dtype.isFloat()) return;
    const divisor = constantTensor(rhs);
    const dividend = constantTensor(lhs);
    var nonzero = divisor != null;
    var representable = !typ.dtype.isSignedInt() or divisor != null;
    if (divisor) |constant| {
        const bits: u7 = @intCast(typ.dtype.sizeOf() * 8);
        const minimum = -(@as(i128, 1) << @intCast(bits - 1));
        for (0..constant.typ.elements) |index| {
            const d = constant.number(index).integer;
            if (d == 0) nonzero = false;
            if (typ.dtype.isSignedInt() and d == -1) {
                if (dividend) |numerator| {
                    if (index >= numerator.typ.elements) {
                        representable = false;
                    } else if (numerator.number(index).integer == minimum) {
                        representable = false;
                    }
                } else representable = false;
            }
        }
    }
    if (!nonzero) conditionedFailure(collector, .nonzero, .{ .operand = 1 }, "DivisionByZero");
    if (!representable) {
        conditionedFailure(
            collector,
            .quotient_representable,
            .operation,
            "SignedDivisionOverflow",
        );
    }
}

fn conversionEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return;
    const input = op.getOperand(0).?;
    const source = staticTensor(input.type) orelse return;
    const target = staticTensor(op.results.items[0].type) orelse return;
    if (!source.dtype.isFloat() or target.dtype.isFloat()) return;
    if (floatConversionInRange(input, target.dtype)) return;
    conditionedFailure(
        collector,
        .conversion_representable,
        .{ .operand = 0 },
        "InvalidFloatToInteger",
    );
}

fn floatConversionInRange(input: *ir.Value, target: gpu_abi.DType) bool {
    const constant = constantTensor(input) orelse return false;
    if (!target.isSignedInt() and !target.isUnsignedInt() and target != .i1) return false;
    const bits: u7 = if (target == .i1) 1 else @intCast(target.sizeOf() * 8);
    const exponent = bits - @as(u7, if (target.isSignedInt()) 1 else 0);
    const upper: f64 = @floatFromInt(@as(u128, 1) << exponent);
    const lower: f64 = if (target.isSignedInt()) -upper else 0;
    for (0..constant.typ.elements) |index| {
        const value = @trunc(constant.number(index).float);
        if (!std.math.isFinite(value) or value < lower or value >= upper) return false;
    }
    return true;
}

fn indexEffects(
    op: *const ir.Operation,
    kind: semantics.OpKind,
    collector: *effect_facts.Collector,
) void {
    if (op.getNumOperands() < 2) return;
    const source = staticTensor(op.getOperand(0).?.type) orelse return;
    const axis: ?usize = if (kind == .sparse_cross_entropy) blk: {
        if (source.rank() == 0) break :blk 0;
        break :blk source.rank() - 1;
    } else blk: {
        const attr = op.getAttrAs(ir.Attribute.IntegerAttr, "axis") orelse break :blk null;
        break :blk std.math.cast(usize, attr.value);
    };
    const extent = if (axis) |value| source.extent(value) else null;
    const indices = constantTensor(op.getOperand(1).?);
    if (extent != null and indices != null and !indices.?.typ.dtype.isFloat()) {
        var in_bounds = true;
        for (0..indices.?.typ.elements) |index| {
            const value = indices.?.number(index).integer;
            if (value < 0 or value >= extent.?) in_bounds = false;
        }
        if (in_bounds) return;
    }
    conditionedFailure(collector, .in_bounds, .{ .operand = 1 }, "IndexOutOfBounds");
}

fn scratchEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    collector.append(.{ .event = .{
        .kind = .allocate,
        .resource = .{ .allocator_domain = "accy.scratch" },
    } });
    collector.append(.{ .event = .{ .kind = .failure, .failure_name = "AllocationFailure" } });
    for (0..op.getNumResults()) |index| {
        collector.append(.{ .result = .{
            .index = index,
            .fresh_identity = true,
            .ownership = .owned,
        } });
    }
}

fn iterationEffects(op: *const ir.Operation, collector: *effect_facts.Collector) void {
    for (0..op.getNumResults()) |index| collector.append(.{ .result = .{ .index = index } });
    for (0..op.getNumRegions()) |index| {
        collector.append(.{ .region = .{ .index = index, .execution = .repeated } });
        for (0..op.getNumOperands()) |argument| {
            collector.append(.{ .binding = .{
                .region = index,
                .argument = argument,
                .source = .{ .operand = argument },
            } });
        }
    }
    if (op.getNumRegions() == 0) {
        for (0..op.getNumOperands()) |index| {
            collector.append(.{ .event = .{
                .kind = .move,
                .resource = .{ .subject = .{ .operand = index } },
            } });
        }
    }
}

fn effectScalar(ctx: *ir.Context, comptime T: type, value: T) !*ir.Value {
    const dtype = gpu_abi.DType.fromZigType(T) orelse unreachable;
    const typ = try accyTensorType(ctx, dtype, &.{});
    const bytes = [1]T{value};
    return (try AccyDialect.ConstantOp.create(
        ctx,
        .unknown,
        std.mem.sliceAsBytes(&bytes),
        typ,
    )).getResult();
}

fn expectAccyPermission(op: *ir.Operation, expected: bool) !void {
    var declaration = try effect_facts.inspect(std.testing.allocator, op);
    defer declaration.deinit(std.testing.allocator);
    try testing.expectEqual(expected, effect_facts.discard(declaration.facts));
    try testing.expectEqual(expected, effect_facts.duplicate(declaration.facts, .{}));
    try testing.expectEqual(expected, effect_facts.speculate(declaration.facts, true));
}

fn divisionMotionCase(divisor_value: ?i32, numerator_value: ?i32, allowed: bool) !void {
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try registerAccyDialect(&ctx);
    try dialects_mod.registerChoirDialect(&ctx);
    const module = try dialects_mod.BuiltinDialect.ModuleOp.create(&ctx, .unknown);
    const body = module.getBodyBlock();
    const tensor = try accyTensorType(&ctx, .i32, &.{});
    const numerator = if (numerator_value) |v| value: {
        break :value try effectScalar(&ctx, i32, v);
    } else try body.addArgument(
        tensor,
        .unknown,
    );
    const divisor = if (divisor_value) |v| try effectScalar(&ctx, i32, v) else try body.addArgument(
        tensor,
        .unknown,
    );
    for ([_]*ir.Value{ numerator, divisor }) |value| {
        if (value.getDefiningOp()) |raw| {
            const op: *ir.Operation = @ptrCast(@alignCast(raw));
            try body.addOperation(op);
        }
    }
    const arith = dialects_mod.ArithDialect;
    const index_type = try arith.getScalarType(&ctx, .i64);
    const zero = try arith.ConstantOp.createInt(&ctx, .unknown, index_type, 0);
    const one = try arith.ConstantOp.createInt(&ctx, .unknown, index_type, 1);
    try body.addOperation(zero.op);
    try body.addOperation(one.op);
    const scf = dialects_mod.ScfDialect;
    const loop = try scf.ForOp.create(
        &ctx,
        .unknown,
        zero.getResult(),
        zero.getResult(),
        one.getResult(),
        &.{},
        &.{},
    );
    try body.addOperation(loop.op);
    const loop_body = loop.op.getRegion(0).?.getEntryBlock().?;
    const division = try AccyDialect.DivOp.create(&ctx, .unknown, numerator, divisor);
    try loop_body.addOperation(division.op);
    const yield = try scf.YieldOp.create(&ctx, .unknown, &.{});
    try loop_body.addOperation(yield.op);
    var motion = choir.passes.PassManager.init(testing.allocator);
    defer motion.deinit();
    try motion.addPass(choir.passes.createLoopInvariantCodeMotionPass());
    try testing.expectEqual(choir.passes.PassResult.success, motion.run(module.op, &ctx));
    try testing.expectEqual(if (allowed) body else loop_body, division.op.getBlock().?);
    try expectAccyPermission(division.op, allowed);
    var dce = choir.passes.PassManager.init(testing.allocator);
    defer dce.deinit();
    try dce.addPass(choir.passes.createDeadCodeEliminationPass());
    try testing.expectEqual(choir.passes.PassResult.success, dce.run(module.op, &ctx));
    try testing.expectEqual(
        @as(usize, if (allowed) 0 else 1),
        ir.inspection.countOperationsNamed(module.op, AccyDialect.DivOp.operation_name),
    );
}
