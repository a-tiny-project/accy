const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");

pub const registers = @import("../backends/aarch64/registers/root.zig");
pub const encoding = @import("../backends/aarch64/encoding/root.zig");

pub const GPR = registers.GPR;
pub const FPR = registers.FPR;
pub const GPRSize = registers.GPRSize;
pub const Condition = encoding.Condition;

pub const type_names = struct {
    pub const gpr = "aarch64.gpr";
    pub const fpr = "aarch64.fpr";
};

pub const attr_names = struct {
    pub const gpr_reg = "aarch64.gpr_reg";
    pub const fpr_reg = "aarch64.fpr_reg";
    pub const imm12 = "aarch64.imm12";
    pub const imm16 = "aarch64.imm16";
    pub const imm8 = "aarch64.imm8";
    pub const condition = "aarch64.condition";
    pub const gpr_size = "aarch64.gpr_size";
    pub const fp_type = "aarch64.fp_type";
    pub const frame_offset = "aarch64.frame_offset";
};

pub const AArch64Dialect = struct {
    pub const name = "aarch64";
    const op_specs = ir.dialects.opSpec.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .types = ir.dialects.typeNames(type_names),
    });

    pub const GetRegOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "get_reg",
            .required_attrs = &.{"reg"},
        });
        pub const operation_name = operation_spec.name;

        pub fn createGPR(ctx: *ir.Context, loc: ir.Location, reg: GPR) !GetRegOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("reg", try getGPRAttr(ctx, reg));
            return .{ .op = op };
        }

        pub fn createFPR(ctx: *ir.Context, loc: ir.Location, reg: FPR) !GetRegOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            try op.setAttr("reg", try getFPRAttr(ctx, reg));
            return .{ .op = op };
        }

        pub fn getResult(self: *const GetRegOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getGPR(self: GetRegOp) ?GPR {
            if (self.op.getAttr("reg")) |attr| {
                return getGPRValue(attr);
            }
            return null;
        }

        pub fn getFPR(self: GetRegOp) ?FPR {
            if (self.op.getAttr("reg")) |attr| {
                return getFPRValue(attr);
            }
            return null;
        }
    };

    pub const AddOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "add",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, size: GPRSize) !AddOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const AddOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getLhs(self: AddOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getRhs(self: AddOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getSize(self: AddOp) GPRSize {
            if (self.op.getAttr("size")) |attr| {
                return getGPRSizeValue(attr) orelse .x;
            }
            return .x;
        }
    };

    pub const AddImmOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "add_imm",
            .required_attrs = &.{ "imm", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, imm: u12, size: GPRSize) !AddImmOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("imm", try getImm12Attr(ctx, imm));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const AddImmOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: AddImmOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getImm(self: AddImmOp) u12 {
            if (self.op.getAttr("imm")) |attr| {
                return getImm12Value(attr) orelse 0;
            }
            return 0;
        }

        pub fn getSize(self: AddImmOp) GPRSize {
            if (self.op.getAttr("size")) |attr| {
                return getGPRSizeValue(attr) orelse .x;
            }
            return .x;
        }
    };

    pub const SubOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "sub",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, size: GPRSize) !SubOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const SubOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getLhs(self: SubOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getRhs(self: SubOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getSize(self: SubOp) GPRSize {
            if (self.op.getAttr("size")) |attr| {
                return getGPRSizeValue(attr) orelse .x;
            }
            return .x;
        }
    };

    pub const MulOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "mul",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, size: GPRSize) !MulOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const MulOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const SDivOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "sdiv",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, size: GPRSize) !SDivOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const SDivOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const UDivOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "udiv",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, size: GPRSize) !UDivOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const UDivOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const CmpOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "cmp",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, size: GPRSize) !CmpOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }
    };

    pub const CSetOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "cset",
            .required_attrs = &.{ "cond", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, cond: Condition, size: GPRSize) !CSetOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("cond", try getConditionAttr(ctx, cond));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const CSetOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getCondition(self: CSetOp) Condition {
            if (self.op.getAttr("cond")) |attr| {
                return getConditionValue(attr) orelse .al;
            }
            return .al;
        }
    };

    pub const CSelOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "csel",
            .required_attrs = &.{ "cond", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, rn: *ir.Value, rm: *ir.Value, cond: Condition, size: GPRSize) !CSelOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ rn, rm });
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("cond", try getConditionAttr(ctx, cond));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const CSelOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getRn(self: CSelOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getRm(self: CSelOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getCondition(self: CSelOp) Condition {
            if (self.op.getAttr("cond")) |attr| {
                return getConditionValue(attr) orelse .al;
            }
            return .al;
        }
    };

    pub const FAddOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fadd",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, ftype: encoding.FP2Source.FPType) !FAddOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FAddOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const FSubOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fsub",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, ftype: encoding.FP2Source.FPType) !FSubOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FSubOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const FMulOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fmul",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, ftype: encoding.FP2Source.FPType) !FMulOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FMulOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const FDivOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fdiv",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, ftype: encoding.FP2Source.FPType) !FDivOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FDivOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const FCmpOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fcmp",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value, ftype: encoding.FP2Source.FPType) !FCmpOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }
    };

    pub const FMovImmOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fmov_imm",
            .required_attrs = &.{ "ftype", "imm8" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, imm8: u8, ftype: encoding.FP2Source.FPType) !FMovImmOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const imm_payload = [_]u8{imm8};
            try op.setAttr("imm8", try ctx.getDialectAttr(attr_names.imm8, &imm_payload));
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FMovImmOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getImm8(self: *const FMovImmOp) u8 {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "imm8")) |dialect_attr| {
                if (dialect_attr.payload.len > 0) {
                    return dialect_attr.payload[0];
                }
            }
            return 0;
        }
    };

    pub const FMovFromGPROp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fmov_gpr",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, ftype: encoding.FP2Source.FPType) !FMovFromGPROp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FMovFromGPROp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: *const FMovFromGPROp) *ir.Value {
            return self.op.getOperand(0).?;
        }
    };

    pub const FMovFromFPROp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fmov_fpr",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, ftype: encoding.FP2Source.FPType) !FMovFromFPROp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FMovFromFPROp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: *const FMovFromFPROp) *ir.Value {
            return self.op.getOperand(0).?;
        }
    };

    pub const FMovOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fmov",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, ftype: encoding.FP2Source.FPType) !FMovOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FMovOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: *const FMovOp) *ir.Value {
            return self.op.getOperand(0).?;
        }

        pub fn getFType(self: FMovOp) encoding.FP2Source.FPType {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "ftype")) |dialect_attr| {
                if (dialect_attr.payload.len > 0) {
                    return @fromBackingInt(@intCast(dialect_attr.payload[0]));
                }
            }
            return .single;
        }
    };

    pub const FSqrtOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fsqrt",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, ftype: encoding.FP2Source.FPType) !FSqrtOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FSqrtOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: *const FSqrtOp) *ir.Value {
            return self.op.getOperand(0).?;
        }
    };

    pub const FNegOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fneg",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, ftype: encoding.FP2Source.FPType) !FNegOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FNegOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: *const FNegOp) *ir.Value {
            return self.op.getOperand(0).?;
        }
    };

    pub const FAbsOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "fabs",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, ftype: encoding.FP2Source.FPType) !FAbsOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const FAbsOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: *const FAbsOp) *ir.Value {
            return self.op.getOperand(0).?;
        }
    };

    pub const LdrOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "ldr",
            .required_attrs = &.{ "offset", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, base: *ir.Value, offset: u12, size: GPRSize) !LdrOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{base});
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("offset", try getImm12Attr(ctx, offset));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const LdrOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getBase(self: LdrOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getOffset(self: LdrOp) u12 {
            if (self.op.getAttr("offset")) |attr| {
                return getImm12Value(attr) orelse 0;
            }
            return 0;
        }
    };

    pub const StrOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "str",
            .required_attrs = &.{ "offset", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, value: *ir.Value, base: *ir.Value, offset: u12, size: GPRSize) !StrOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ value, base });

            const op = try builder.create(state);
            try op.setAttr("offset", try getImm12Attr(ctx, offset));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getValue(self: StrOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getBase(self: StrOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getOffset(self: StrOp) u12 {
            if (self.op.getAttr("offset")) |attr| {
                return getImm12Value(attr) orelse 0;
            }
            return 0;
        }
    };

    pub const BOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "b" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, target: *ir.Block) !BOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addSuccessors(&.{target});

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getTarget(self: BOp) *ir.Block {
            return self.op.getSuccessor(0).?;
        }
    };

    pub const BCondOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "b_cond",
            .required_attrs = &.{"cond"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, cond: Condition, true_target: *ir.Block, false_target: *ir.Block) !BCondOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addSuccessors(&.{ true_target, false_target });

            const op = try builder.create(state);
            try op.setAttr("cond", try getConditionAttr(ctx, cond));
            return .{ .op = op };
        }

        pub fn getCondition(self: BCondOp) Condition {
            if (self.op.getAttr("cond")) |attr| {
                return getConditionValue(attr) orelse .al;
            }
            return .al;
        }

        pub fn getTrueTarget(self: BCondOp) *ir.Block {
            return self.op.getSuccessor(0).?;
        }

        pub fn getFalseTarget(self: BCondOp) *ir.Block {
            return self.op.getSuccessor(1).?;
        }
    };

    pub const RetOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "ret" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !RetOp {
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);

            const op = try builder.create(state);
            return .{ .op = op };
        }
    };

    pub const BlOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "bl",
            .required_attrs = &.{"callee"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, callee: []const u8, args: []const *ir.Value, result_types: []const ir.Type) !BlOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(args);
            state.addTypes(result_types);

            const op = try builder.create(state);
            const name_attr = try ctx.getDialectAttr("choir.string", callee);
            try op.setAttr("callee", name_attr);
            return .{ .op = op };
        }
    };

    pub const PrologueOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "prologue",
            .required_attrs = &.{"frame_size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, frame_size: i32) !PrologueOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);

            const op = try builder.create(state);
            try op.setAttr("frame_size", try getFrameOffsetAttr(ctx, frame_size));
            return .{ .op = op };
        }

        pub fn getFrameSize(self: PrologueOp) i32 {
            if (self.op.getAttr("frame_size")) |attr| {
                return getFrameOffsetValue(attr) orelse 0;
            }
            return 0;
        }
    };

    pub const EpilogueOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "epilogue",
            .required_attrs = &.{"frame_size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, frame_size: i32) !EpilogueOp {
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);

            const op = try builder.create(state);
            try op.setAttr("frame_size", try getFrameOffsetAttr(ctx, frame_size));
            return .{ .op = op };
        }

        pub fn getFrameSize(self: EpilogueOp) i32 {
            if (self.op.getAttr("frame_size")) |attr| {
                return getFrameOffsetValue(attr) orelse 0;
            }
            return 0;
        }
    };

    pub const MovOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "mov",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, size: GPRSize) !MovOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const MovOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: MovOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const MovzOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "movz",
            .required_attrs = &.{ "imm", "shift", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, imm: u16, shift: u2, size: GPRSize) !MovzOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            var buf: [8]u8 = undefined;
            const imm_payload = try ir.format.intPayload(buf[0..], imm);
            try op.setAttr("imm", try ctx.getDialectAttr(attr_names.imm16, imm_payload));
            const shift_payload = [_]u8{shift};
            try op.setAttr("shift", try ctx.getDialectAttr("aarch64.shift", &shift_payload));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const MovzOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const MovnOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "movn",
            .required_attrs = &.{ "imm", "shift", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, imm: u16, shift: u2, size: GPRSize) !MovnOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            var buf: [8]u8 = undefined;
            const imm_payload = try ir.format.intPayload(buf[0..], imm);
            try op.setAttr("imm", try ctx.getDialectAttr(attr_names.imm16, imm_payload));
            const shift_payload = [_]u8{shift};
            try op.setAttr("shift", try ctx.getDialectAttr("aarch64.shift", &shift_payload));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const MovnOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const MovkOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "movk",
            .required_attrs = &.{ "imm", "shift", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, imm: u16, shift: u2, size: GPRSize) !MovkOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            var buf: [8]u8 = undefined;
            const imm_payload = try ir.format.intPayload(buf[0..], imm);
            try op.setAttr("imm", try ctx.getDialectAttr(attr_names.imm16, imm_payload));
            const shift_payload = [_]u8{shift};
            try op.setAttr("shift", try ctx.getDialectAttr("aarch64.shift", &shift_payload));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const MovkOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: *const MovkOp) *ir.Value {
            return self.op.getOperand(0).?;
        }
    };

    pub const CopyToRegOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "copy_to_reg",
            .required_attrs = &.{ "dest_reg", "size" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, dest_reg: u8, size: GPRSize) !CopyToRegOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            const reg_payload = [_]u8{dest_reg};
            try op.setAttr("dest_reg", try ctx.getDialectAttr("aarch64.reg_num", &reg_payload));
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const CopyToRegOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: CopyToRegOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getDestReg(self: CopyToRegOp) u8 {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "dest_reg")) |dialect_attr| {
                if (dialect_attr.payload.len > 0) {
                    return dialect_attr.payload[0];
                }
            }
            return 0;
        }

        pub fn getSize(self: CopyToRegOp) GPRSize {
            if (self.op.getAttr("size")) |attr| {
                return getGPRSizeValue(attr) orelse .x;
            }
            return .x;
        }
    };

    pub const CopyToSameRegAsOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "copy_to_same_reg",
            .required_attrs = &.{"size"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, target_ref: *ir.Value, size: GPRSize) !CopyToSameRegAsOp {
            var builder = ir.OperationBuilder.init(ctx);
            const gpr_type = try getGPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ src, target_ref });
            state.addTypes(&.{gpr_type});

            const op = try builder.create(state);
            try op.setAttr("size", try getGPRSizeAttr(ctx, size));
            return .{ .op = op };
        }

        pub fn getResult(self: *const CopyToSameRegAsOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: CopyToSameRegAsOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getTargetRef(self: CopyToSameRegAsOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getSize(self: CopyToSameRegAsOp) GPRSize {
            if (self.op.getAttr("size")) |attr| {
                return getGPRSizeValue(attr) orelse .x;
            }
            return .x;
        }
    };

    pub const CopyToSameFPRegAsOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "copy_to_same_fpreg",
            .required_attrs = &.{"ftype"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, target_ref: *ir.Value, ftype: encoding.FP2Source.FPType) !CopyToSameFPRegAsOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ src, target_ref });
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const CopyToSameFPRegAsOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: CopyToSameFPRegAsOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getTargetRef(self: CopyToSameFPRegAsOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getFType(self: CopyToSameFPRegAsOp) encoding.FP2Source.FPType {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "ftype")) |dialect_attr| {
                if (dialect_attr.payload.len > 0) {
                    return @fromBackingInt(@intCast(dialect_attr.payload[0]));
                }
            }
            return .single;
        }
    };

    pub const CopyToFPRegOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "copy_to_fpreg",
            .required_attrs = &.{ "dest_reg", "ftype" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, src: *ir.Value, dest_reg: u8, ftype: encoding.FP2Source.FPType) !CopyToFPRegOp {
            var builder = ir.OperationBuilder.init(ctx);
            const fpr_type = try getFPRType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{src});
            state.addTypes(&.{fpr_type});

            const op = try builder.create(state);
            const reg_payload = [_]u8{dest_reg};
            try op.setAttr("dest_reg", try ctx.getDialectAttr("aarch64.fpreg_num", &reg_payload));
            const type_payload = [_]u8{@backingInt(ftype)};
            try op.setAttr("ftype", try ctx.getDialectAttr(attr_names.fp_type, &type_payload));
            return .{ .op = op };
        }

        pub fn getResult(self: *const CopyToFPRegOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getSrc(self: CopyToFPRegOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getDestReg(self: CopyToFPRegOp) u8 {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "dest_reg")) |dialect_attr| {
                if (dialect_attr.payload.len > 0) {
                    return dialect_attr.payload[0];
                }
            }
            return 0;
        }

        pub fn getFType(self: CopyToFPRegOp) encoding.FP2Source.FPType {
            if (self.op.getAttrAs(ir.Attribute.DialectAttr, "ftype")) |dialect_attr| {
                if (dialect_attr.payload.len > 0) {
                    return @fromBackingInt(@intCast(dialect_attr.payload[0]));
                }
            }
            return .single;
        }
    };

    fn loadSpec(ctx: *ir.Context) !void {
        try ir.dialects.loadDialectSpec(ctx, spec);
    }

    pub fn getGPRType(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(type_names.gpr);
    }

    pub fn getFPRType(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(type_names.fpr);
    }

    pub fn getGPRAttr(ctx: *ir.Context, reg: GPR) !ir.Attribute {
        var buf: [4]u8 = undefined;
        const payload = try ir.format.intPayload(buf[0..], @backingInt(reg));
        return ctx.getDialectAttr(attr_names.gpr_reg, payload);
    }

    pub fn getGPRValue(attr: ir.Attribute) ?GPR {
        if (!std.mem.eql(u8, attr.abstract.name, attr_names.gpr_reg)) return null;
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
        const val = std.fmt.parseInt(u5, dialect_attr.payload, 10) catch return null;
        return @fromBackingInt(@intCast(val));
    }

    pub fn getFPRAttr(ctx: *ir.Context, reg: FPR) !ir.Attribute {
        var buf: [4]u8 = undefined;
        const payload = try ir.format.intPayload(buf[0..], @backingInt(reg));
        return ctx.getDialectAttr(attr_names.fpr_reg, payload);
    }

    pub fn getFPRValue(attr: ir.Attribute) ?FPR {
        if (!std.mem.eql(u8, attr.abstract.name, attr_names.fpr_reg)) return null;
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
        const val = std.fmt.parseInt(u5, dialect_attr.payload, 10) catch return null;
        return @fromBackingInt(@intCast(val));
    }

    pub fn getImm12Attr(ctx: *ir.Context, value: u12) !ir.Attribute {
        var buf: [8]u8 = undefined;
        const payload = try ir.format.intPayload(buf[0..], value);
        return ctx.getDialectAttr(attr_names.imm12, payload);
    }

    pub fn getImm12Value(attr: ir.Attribute) ?u12 {
        if (!std.mem.eql(u8, attr.abstract.name, attr_names.imm12)) return null;
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
        return std.fmt.parseInt(u12, dialect_attr.payload, 10) catch null;
    }

    pub fn getConditionAttr(ctx: *ir.Context, cond: Condition) !ir.Attribute {
        var buf: [4]u8 = undefined;
        const payload = try ir.format.intPayload(buf[0..], @backingInt(cond));
        return ctx.getDialectAttr(attr_names.condition, payload);
    }

    pub fn getConditionValue(attr: ir.Attribute) ?Condition {
        if (!std.mem.eql(u8, attr.abstract.name, attr_names.condition)) return null;
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
        const val = std.fmt.parseInt(u4, dialect_attr.payload, 10) catch return null;
        return @fromBackingInt(@intCast(val));
    }

    pub fn getGPRSizeAttr(ctx: *ir.Context, size: GPRSize) !ir.Attribute {
        const payload = [_]u8{@backingInt(size)};
        return ctx.getDialectAttr(attr_names.gpr_size, &payload);
    }

    pub fn getGPRSizeValue(attr: ir.Attribute) ?GPRSize {
        if (!std.mem.eql(u8, attr.abstract.name, attr_names.gpr_size)) return null;
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
        if (dialect_attr.payload.len != 1) return null;
        return @fromBackingInt(@intCast(dialect_attr.payload[0]));
    }

    pub fn getFrameOffsetAttr(ctx: *ir.Context, offset: i32) !ir.Attribute {
        var buf: [16]u8 = undefined;
        const payload = try ir.format.intPayload(buf[0..], offset);
        return ctx.getDialectAttr(attr_names.frame_offset, payload);
    }

    pub fn getFrameOffsetValue(attr: ir.Attribute) ?i32 {
        if (!std.mem.eql(u8, attr.abstract.name, attr_names.frame_offset)) return null;
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
        return std.fmt.parseInt(i32, dialect_attr.payload, 10) catch null;
    }
};

test "AArch64Dialect.AddOp creates addition" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();

    var r1 = try AArch64Dialect.GetRegOp.createGPR(&ctx, loc, .x1);
    var r2 = try AArch64Dialect.GetRegOp.createGPR(&ctx, loc, .x2);

    var add = try AArch64Dialect.AddOp.create(&ctx, loc, r1.getResult(), r2.getResult(), .x);

    try testing.expectEqualStrings("aarch64.add", add.op.name.name);
    try testing.expectEqual(GPRSize.x, add.getSize());
}

test "AArch64Dialect.GetRegOp materializes register" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();

    var get_reg = try AArch64Dialect.GetRegOp.createGPR(&ctx, loc, .x19);

    try testing.expectEqualStrings("aarch64.get_reg", get_reg.op.name.name);
    try testing.expectEqual(GPR.x19, get_reg.getGPR().?);
}

test "AArch64Dialect registers inherent attribute names" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, AArch64Dialect.spec);

    const add_info = ctx.lookupOperation(AArch64Dialect.AddOp.operation_name) orelse
        return error.TestExpectedOperationInfo;
    try testing.expect(add_info.hasInherentAttributeName("size"));

    const movk_info = ctx.lookupOperation(AArch64Dialect.MovkOp.operation_name) orelse
        return error.TestExpectedOperationInfo;
    try testing.expect(movk_info.hasInherentAttributeName("imm"));
    try testing.expect(movk_info.hasInherentAttributeName("shift"));
    try testing.expect(movk_info.hasInherentAttributeName("size"));

    const branch_info = ctx.lookupOperation(AArch64Dialect.BlOp.operation_name) orelse
        return error.TestExpectedOperationInfo;
    try testing.expect(branch_info.hasInherentAttributeName("callee"));

    const loc = ir.Location.getUnknown();
    var r1 = try AArch64Dialect.GetRegOp.createGPR(&ctx, loc, .x1);
    var r2 = try AArch64Dialect.GetRegOp.createGPR(&ctx, loc, .x2);
    const add = try AArch64Dialect.AddOp.create(&ctx, loc, r1.getResult(), r2.getResult(), .x);

    try testing.expect(!add.op.isDiscardableAttrName("size"));
    try testing.expectEqual(@as(usize, 0), add.op.countDiscardableAttrs());
}

test "AArch64Dialect.PrologueOp stores frame size" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();

    var prologue = try AArch64Dialect.PrologueOp.create(&ctx, loc, 32);

    try testing.expectEqual(@as(i32, 32), prologue.getFrameSize());
}

test "AArch64Dialect attribute helpers round trip" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const gpr_attr = try AArch64Dialect.getGPRAttr(&ctx, .x7);
    try testing.expectEqual(GPR.x7, AArch64Dialect.getGPRValue(gpr_attr).?);

    const fpr_attr = try AArch64Dialect.getFPRAttr(&ctx, .v3);
    try testing.expectEqual(FPR.v3, AArch64Dialect.getFPRValue(fpr_attr).?);

    const imm_attr = try AArch64Dialect.getImm12Attr(&ctx, 4095);
    try testing.expectEqual(@as(u12, 4095), AArch64Dialect.getImm12Value(imm_attr).?);

    const cond_attr = try AArch64Dialect.getConditionAttr(&ctx, .ne);
    try testing.expectEqual(Condition.ne, AArch64Dialect.getConditionValue(cond_attr).?);
}
