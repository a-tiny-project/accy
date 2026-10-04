const std = @import("std");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const binary = @import("module.zig");
const spirv_ops = @import("ops.zig");

const arith = dialects.arith;
const ArithDialect = arith.ArithDialect;
const ModuleBuilder = binary.Builder;
const SpirvOp = spirv_ops.SpirvOp;

pub const GLSLstd450 = struct {
    pub const Trunc: u32 = 3;
    pub const FAbs: u32 = 4;
    pub const SAbs: u32 = 5;
    pub const Floor: u32 = 8;
    pub const Sin: u32 = 13;
    pub const Cos: u32 = 14;
    pub const Tan: u32 = 15;
    pub const Tanh: u32 = 21;
    pub const Atan2: u32 = 25;
    pub const Pow: u32 = 26;
    pub const Exp: u32 = 27;
    pub const Log: u32 = 28;
    pub const Sqrt: u32 = 31;
    pub const Fma: u32 = 50;
    pub const FMin: u32 = 37;
    pub const UMin: u32 = 38;
    pub const SMin: u32 = 39;
    pub const FMax: u32 = 40;
    pub const UMax: u32 = 41;
    pub const SMax: u32 = 42;
    pub const NMin: u32 = 79;
    pub const NMax: u32 = 80;
};

pub const Kind = enum {
    void,
    bool,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f16,
    f32,
    f64,
};

pub fn kindFromName(name: []const u8) ?Kind {
    const scalar_kind = arith.scalarKindFromTypeName(name) orelse return null;
    return switch (scalar_kind) {
        .bool => .bool,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f16 => .f16,
        .bf16 => null,
        .f32 => .f32,
        .f64 => .f64,
        .index => .u32,
    };
}

pub fn kindFromType(ty: ir.Type) ?Kind {
    const name = ty.getDialectTypeName() orelse return null;
    return kindFromName(name);
}

pub fn emitConstant(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.UnsupportedOperation;
    const type_id = try self.getTypeForValue(result);

    const constant = ArithDialect.ConstantOp{ .op = op };

    if (constant.getIntValue()) |int_value| {
        const kind = kindFromType(result.type) orelse return error.UnsupportedType;
        const const_id = try self.getIntConstant(type_id, kind, int_value);
        try self.bindValue(result, const_id);
        return;
    }

    if (constant.getFloatValue()) |float_value| {
        const kind = kindFromType(result.type) orelse return error.UnsupportedType;
        const const_id = try self.getFloatConstant(type_id, kind, float_value);
        try self.bindValue(result, const_id);
        return;
    }

    if (op.getAttrAs(ir.Attribute.BoolAttr, "value")) |bool_attr| {
        const const_id = try self.getBoolConstant(bool_attr.getValue());
        try self.bindValue(result, const_id);
        return;
    }

    return error.UnsupportedOperation;
}

pub const BinaryKind = enum { add, sub, mul, div, rem };

/// The opcode for `op_kind` on `kind`, for every pair but a signed `rem`,
/// which `emitBinaryIds` writes as three instructions.
fn binaryOpcode(kind: Kind, op_kind: BinaryKind) error{UnsupportedType}!u16 {
    return switch (kind) {
        .f16, .f32, .f64 => switch (op_kind) {
            .add => SpirvOp.FAdd,
            .sub => SpirvOp.FSub,
            .mul => SpirvOp.FMul,
            .div => SpirvOp.FDiv,
            .rem => error.UnsupportedType,
        },
        .i8, .i16, .i32, .i64 => switch (op_kind) {
            .add => SpirvOp.IAdd,
            .sub => SpirvOp.ISub,
            .mul => SpirvOp.IMul,
            .div => SpirvOp.SDiv,
            .rem => unreachable,
        },
        .u8, .u16, .u32, .u64 => switch (op_kind) {
            .add => SpirvOp.IAdd,
            .sub => SpirvOp.ISub,
            .mul => SpirvOp.IMul,
            .div => SpirvOp.UDiv,
            .rem => SpirvOp.UMod,
        },
        else => error.UnsupportedType,
    };
}

/// Writes `op_kind` on `kind` and returns the result id. Integer `div` and
/// `rem` truncate toward zero, as arith folds them. An unsigned `rem`,
/// `index` included, is OpUMod. A signed `rem` is `a - (a / b) * b` through
/// OpSDiv, because the Vulkan environment leaves OpSRem and OpSMod undefined
/// when an operand is negative unless VK_KHR_maintenance8 is enabled, and
/// the RTX 4090 driver then returns the unsigned remainder. The divisor
/// obligation belongs to the front end: SPIR-V leaves a zero divisor and
/// signed MIN / -1 undefined, and arith states both as requirements this
/// emitter assumes discharged. A float `rem` is refused.
fn emitBinaryIds(
    self: anytype,
    type_id: u32,
    kind: Kind,
    op_kind: BinaryKind,
    lhs_id: u32,
    rhs_id: u32,
) !u32 {
    const signed_rem = op_kind == .rem and switch (kind) {
        .i8, .i16, .i32, .i64 => true,
        else => false,
    };
    if (signed_rem) {
        const quotient_id = try emitOpcode(self, SpirvOp.SDiv, type_id, lhs_id, rhs_id);
        const product_id = try emitOpcode(self, SpirvOp.IMul, type_id, quotient_id, rhs_id);
        return emitOpcode(self, SpirvOp.ISub, type_id, lhs_id, product_id);
    }
    return emitOpcode(self, try binaryOpcode(kind, op_kind), type_id, lhs_id, rhs_id);
}

fn emitOpcode(self: anytype, opcode: u16, type_id: u32, lhs_id: u32, rhs_id: u32) !u32 {
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        type_id,
        result_id,
        lhs_id,
        rhs_id,
    });
    return result_id;
}

pub fn emitBinaryArith(self: anytype, op: *ir.Operation, kind: BinaryKind) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const lhs_id = try self.getValue(lhs);
    const rhs_id = try self.getValue(rhs);
    const result_type_id = try self.getTypeForValue(result);

    const type_kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const result_id = try emitBinaryIds(self, result_type_id, type_kind, kind, lhs_id, rhs_id);
    try self.bindValue(result, result_id);
}

pub fn emitBinaryArithIds(
    self: anytype,
    kind: Kind,
    lhs_id: u32,
    rhs_id: u32,
    op_kind: BinaryKind,
) !u32 {
    const result_type_id = try self.getScalarType(kind);
    return emitBinaryIds(self, result_type_id, kind, op_kind, lhs_id, rhs_id);
}

pub fn emitNegArith(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 1) return error.UnsupportedOperation;
    const input = op.operands.items[0].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const input_id = try self.getValue(input);
    const result_type_id = try self.getTypeForValue(result);

    const kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const result_id = self.builder.newId();
    if (isUnsignedInt(kind)) {
        const zero_id = try self.getIntConstant(result_type_id, kind, 0);
        try self.builder.emit(&self.builder.functions, SpirvOp.ISub, &.{
            result_type_id,
            result_id,
            zero_id,
            input_id,
        });
    } else {
        const opcode = if (isFloat(kind))
            SpirvOp.FNegate
        else if (isSignedInt(kind))
            SpirvOp.SNegate
        else
            return error.UnsupportedType;
        try self.builder.emit(&self.builder.functions, opcode, &.{
            result_type_id,
            result_id,
            input_id,
        });
    }
    try self.bindValue(result, result_id);
}

pub const FloatExtConstraint = enum {
    float16_or_32,
    any_float,
};

const RoundBits = struct {
    kind: Kind,
    sign_mask: i64,
    magnitude_mask: i64,
};

fn floatKindAllowedFor(constraint: FloatExtConstraint, kind: Kind) bool {
    return switch (constraint) {
        .float16_or_32 => kind == .f16 or kind == .f32,
        .any_float => isFloat(kind),
    };
}

fn roundBitsFor(kind: Kind) ?RoundBits {
    return switch (kind) {
        .f16 => .{ .kind = .u16, .sign_mask = 0x8000, .magnitude_mask = 0x7fff },
        .f32 => .{ .kind = .u32, .sign_mask = 0x80000000, .magnitude_mask = 0x7fffffff },
        else => null,
    };
}

pub fn emitGlslExtUnary(
    self: anytype,
    op: *ir.Operation,
    ext_opcode: u32,
    constraint: FloatExtConstraint,
) !void {
    if (op.operands.items.len != 1) return error.UnsupportedOperation;
    const input = op.operands.items[0].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const kind = kindFromType(result.type) orelse return error.UnsupportedType;
    if (!floatKindAllowedFor(constraint, kind)) return error.UnsupportedType;

    const input_id = try self.getValue(input);
    const result_type_id = try self.getTypeForValue(result);
    const set_id = try self.builder.importGlslStd450();

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.ExtInst, &.{
        result_type_id,
        result_id,
        set_id,
        ext_opcode,
        input_id,
    });
    try self.builder.emitNoContraction(result_id);
    try self.bindValue(result, result_id);
}

pub fn emitRoundArith(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 1) return error.UnsupportedOperation;
    const input = op.operands.items[0].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const input_kind = kindFromType(input.type) orelse return error.UnsupportedType;
    if (kind != input_kind) return error.UnsupportedType;
    const bits = roundBitsFor(kind) orelse return error.UnsupportedType;

    const input_id = try self.getValue(input);
    const float_type_id = try self.getScalarType(kind);
    const int_type_id = try self.getScalarType(bits.kind);
    const set_id = try self.builder.importGlslStd450();

    const abs_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.ExtInst, &.{
        float_type_id,
        abs_id,
        set_id,
        GLSLstd450.FAbs,
        input_id,
    });
    try self.builder.emitNoContraction(abs_id);

    const half_id = try self.getFloatConstant(float_type_id, kind, 0.5);
    const shifted_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.FAdd, &.{
        float_type_id,
        shifted_id,
        abs_id,
        half_id,
    });

    const rounded_abs_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.ExtInst, &.{
        float_type_id,
        rounded_abs_id,
        set_id,
        GLSLstd450.Floor,
        shifted_id,
    });
    try self.builder.emitNoContraction(rounded_abs_id);

    const input_bits_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Bitcast, &.{
        int_type_id,
        input_bits_id,
        input_id,
    });

    const rounded_bits_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Bitcast, &.{
        int_type_id,
        rounded_bits_id,
        rounded_abs_id,
    });

    const sign_mask_id = try self.getIntConstant(int_type_id, bits.kind, bits.sign_mask);
    const sign_bits_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.BitwiseAnd, &.{
        int_type_id,
        sign_bits_id,
        input_bits_id,
        sign_mask_id,
    });

    const magnitude_mask_id = try self.getIntConstant(int_type_id, bits.kind, bits.magnitude_mask);
    const magnitude_bits_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.BitwiseAnd, &.{
        int_type_id,
        magnitude_bits_id,
        rounded_bits_id,
        magnitude_mask_id,
    });

    const result_bits_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.BitwiseOr, &.{
        int_type_id,
        result_bits_id,
        magnitude_bits_id,
        sign_bits_id,
    });

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Bitcast, &.{
        float_type_id,
        result_id,
        result_bits_id,
    });
    try self.bindValue(result, result_id);
}

fn emitGlslExtBinary(
    self: anytype,
    op: *ir.Operation,
    ext_opcode: u32,
    constraint: FloatExtConstraint,
) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const kind = kindFromType(result.type) orelse return error.UnsupportedType;
    if (!floatKindAllowedFor(constraint, kind)) return error.UnsupportedType;
    if (!lhs.type.eql(result.type)) return error.UnsupportedType;
    if (!rhs.type.eql(result.type)) return error.UnsupportedType;

    const lhs_id = try self.getValue(lhs);
    const rhs_id = try self.getValue(rhs);
    const result_type_id = try self.getTypeForValue(result);
    const set_id = try self.builder.importGlslStd450();

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.ExtInst, &.{
        result_type_id,
        result_id,
        set_id,
        ext_opcode,
        lhs_id,
        rhs_id,
    });
    try self.builder.emitNoContraction(result_id);
    try self.bindValue(result, result_id);
}

pub fn emitPowArith(self: anytype, op: *ir.Operation) !void {
    return emitGlslExtBinary(self, op, GLSLstd450.Pow, .float16_or_32);
}

pub fn emitAtan2Arith(self: anytype, op: *ir.Operation) !void {
    return emitGlslExtBinary(self, op, GLSLstd450.Atan2, .float16_or_32);
}

fn emitGlslExtTernary(
    self: anytype,
    op: *ir.Operation,
    ext_opcode: u32,
    constraint: FloatExtConstraint,
) !void {
    if (op.operands.items.len != 3) return error.UnsupportedOperation;
    const a = op.operands.items[0].value;
    const b = op.operands.items[1].value;
    const c = op.operands.items[2].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const kind = kindFromType(result.type) orelse return error.UnsupportedType;
    if (!floatKindAllowedFor(constraint, kind)) return error.UnsupportedType;
    if (!a.type.eql(result.type)) return error.UnsupportedType;
    if (!b.type.eql(result.type)) return error.UnsupportedType;
    if (!c.type.eql(result.type)) return error.UnsupportedType;

    const a_id = try self.getValue(a);
    const b_id = try self.getValue(b);
    const c_id = try self.getValue(c);
    const result_type_id = try self.getTypeForValue(result);
    const set_id = try self.builder.importGlslStd450();

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.ExtInst, &.{
        result_type_id,
        result_id,
        set_id,
        ext_opcode,
        a_id,
        b_id,
        c_id,
    });
    try self.builder.emitNoContraction(result_id);
    try self.bindValue(result, result_id);
}

pub fn emitFmaArith(self: anytype, op: *ir.Operation) !void {
    return emitGlslExtTernary(self, op, GLSLstd450.Fma, .any_float);
}

pub fn emitSqrtArith(self: anytype, op: *ir.Operation) !void {
    return emitGlslExtUnary(self, op, GLSLstd450.Sqrt, .any_float);
}

pub fn emitAbsArith(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 1) return error.UnsupportedOperation;
    const input = op.operands.items[0].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const input_id = try self.getValue(input);
    if (isUnsignedInt(kind)) {
        try self.bindValue(result, input_id);
        return;
    }

    const ext_opcode: u32 = if (isFloat(kind))
        GLSLstd450.FAbs
    else if (isSignedInt(kind))
        GLSLstd450.SAbs
    else
        return error.UnsupportedType;

    const result_type_id = try self.getTypeForValue(result);
    const set_id = try self.builder.importGlslStd450();

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.ExtInst, &.{
        result_type_id,
        result_id,
        set_id,
        ext_opcode,
        input_id,
    });
    if (isFloat(kind)) try self.builder.emitNoContraction(result_id);
    try self.bindValue(result, result_id);
}

pub const BitwiseBinaryKind = enum { band, bor, bxor };
pub const ShiftKind = enum { shl, shr, ushr };

pub fn emitBitwiseBinary(
    self: anytype,
    op: *ir.Operation,
    kind: BitwiseBinaryKind,
) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const result_kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const lhs_kind = kindFromType(lhs.type) orelse return error.UnsupportedType;
    const rhs_kind = kindFromType(rhs.type) orelse return error.UnsupportedType;
    if (result_kind != lhs_kind or result_kind != rhs_kind) return error.UnsupportedType;
    const opcode: u16 = if (result_kind == .bool) switch (kind) {
        .band => SpirvOp.LogicalAnd,
        .bor => SpirvOp.LogicalOr,
        .bxor => SpirvOp.LogicalNotEqual,
    } else blk: {
        if (!isInt(result_kind)) return error.UnsupportedType;
        break :blk switch (kind) {
            .band => SpirvOp.BitwiseAnd,
            .bor => SpirvOp.BitwiseOr,
            .bxor => SpirvOp.BitwiseXor,
        };
    };

    const lhs_id = try self.getValue(lhs);
    const rhs_id = try self.getValue(rhs);
    const result_type_id = try self.getTypeForValue(result);

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        lhs_id,
        rhs_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitNotArith(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 1) return error.UnsupportedOperation;
    const input = op.operands.items[0].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const result_kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const input_kind = kindFromType(input.type) orelse return error.UnsupportedType;
    if (result_kind != input_kind) return error.UnsupportedType;
    const opcode: u16 = switch (result_kind) {
        .bool => SpirvOp.LogicalNot,
        else => blk: {
            if (!isInt(result_kind)) return error.UnsupportedType;
            break :blk SpirvOp.Not;
        },
    };

    const input_id = try self.getValue(input);
    const result_type_id = try self.getTypeForValue(result);

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        input_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitShiftArith(
    self: anytype,
    op: *ir.Operation,
    kind: ShiftKind,
) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const value = op.operands.items[0].value;
    const count = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const result_kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const value_kind = kindFromType(value.type) orelse return error.UnsupportedType;
    const count_kind = kindFromType(count.type) orelse return error.UnsupportedType;
    if (result_kind != value_kind or result_kind != count_kind) return error.UnsupportedType;
    if (!isInt(result_kind)) return error.UnsupportedType;

    if (kind == .shr and !isSignedInt(result_kind)) return error.UnsupportedType;

    const opcode: u16 = switch (kind) {
        .shl => SpirvOp.ShiftLeftLogical,
        .shr => SpirvOp.ShiftRightArithmetic,
        .ushr => SpirvOp.ShiftRightLogical,
    };

    const value_id = try self.getValue(value);
    const count_id = try self.getValue(count);
    const result_type_id = try self.getTypeForValue(result);

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        value_id,
        count_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitUmulhi(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const result_kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const lhs_kind = kindFromType(lhs.type) orelse return error.UnsupportedType;
    const rhs_kind = kindFromType(rhs.type) orelse return error.UnsupportedType;
    if (result_kind != lhs_kind or result_kind != rhs_kind) return error.UnsupportedType;
    if (!isInt(result_kind)) return error.UnsupportedType;

    const lhs_id = try self.getValue(lhs);
    const rhs_id = try self.getValue(rhs);
    const result_type_id = try self.getTypeForValue(result);
    const pair_type_id = try self.getPairStructType(result_type_id);

    const pair_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.UMulExtended, &.{
        pair_type_id,
        pair_id,
        lhs_id,
        rhs_id,
    });

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.CompositeExtract, &.{
        result_type_id,
        result_id,
        pair_id,
        1,
    });
    try self.bindValue(result, result_id);
}

pub const MinMaxKind = enum { max, min };

pub fn emitMinMaxArith(
    self: anytype,
    op: *ir.Operation,
    kind_op: MinMaxKind,
) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const lhs_id = try self.getValue(lhs);
    const rhs_id = try self.getValue(rhs);
    const result_type_id = try self.getTypeForValue(result);

    const scalar_kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const ext_opcode: u32 = if (isFloat(scalar_kind))
        switch (kind_op) {
            .max => GLSLstd450.NMax,
            .min => GLSLstd450.NMin,
        }
    else if (isSignedInt(scalar_kind))
        switch (kind_op) {
            .max => GLSLstd450.SMax,
            .min => GLSLstd450.SMin,
        }
    else if (isUnsignedInt(scalar_kind))
        switch (kind_op) {
            .max => GLSLstd450.UMax,
            .min => GLSLstd450.UMin,
        }
    else
        return error.UnsupportedType;

    const set_id = try self.builder.importGlslStd450();
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.ExtInst, &.{
        result_type_id,
        result_id,
        set_id,
        ext_opcode,
        lhs_id,
        rhs_id,
    });
    if (isFloat(scalar_kind)) try self.builder.emitNoContraction(result_id);
    try self.bindValue(result, result_id);
}

pub fn emitCast(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 1) return error.UnsupportedOperation;
    const input = op.operands.items[0].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const input_kind = kindFromType(input.type) orelse return error.UnsupportedType;
    const result_kind = kindFromType(result.type) orelse return error.UnsupportedType;
    const input_id = try self.getValue(input);

    if (input_kind == result_kind) {
        try self.bindValue(result, input_id);
        return;
    }

    const result_type_id = try self.getScalarType(result_kind);

    if (input_kind == .bool and result_kind != .bool) {
        const result_id = self.builder.newId();
        if (isFloat(result_kind)) {
            const zero = try self.getFloatConstant(result_type_id, result_kind, 0.0);
            const one = try self.getFloatConstant(result_type_id, result_kind, 1.0);
            try self.builder.emit(&self.builder.functions, SpirvOp.Select, &.{
                result_type_id,
                result_id,
                input_id,
                one,
                zero,
            });
        } else {
            const zero = try self.getIntConstant(result_type_id, result_kind, 0);
            const one = try self.getIntConstant(result_type_id, result_kind, 1);
            try self.builder.emit(&self.builder.functions, SpirvOp.Select, &.{
                result_type_id,
                result_id,
                input_id,
                one,
                zero,
            });
        }
        try self.bindValue(result, result_id);
        return;
    }

    if (result_kind == .bool and input_kind != .bool) {
        const bool_type_id = try self.getScalarType(.bool);
        const result_id = self.builder.newId();
        if (isFloat(input_kind)) {
            // Unordered, so a NaN reads true, as a CPU's `x != 0` does.
            const zero = try self.getFloatConstant(try self.getScalarType(input_kind), input_kind, 0.0);
            try self.builder.emit(&self.builder.functions, SpirvOp.FUnordNotEqual, &.{
                bool_type_id,
                result_id,
                input_id,
                zero,
            });
        } else {
            const zero = try self.getIntConstant(try self.getScalarType(input_kind), input_kind, 0);
            try self.builder.emit(&self.builder.functions, SpirvOp.INotEqual, &.{
                bool_type_id,
                result_id,
                input_id,
                zero,
            });
        }
        try self.bindValue(result, result_id);
        return;
    }

    const opcode: u16 = if (isInt(input_kind) and isInt(result_kind)) blk: {
        if (bitWidth(input_kind) == bitWidth(result_kind)) {
            break :blk SpirvOp.Bitcast;
        }
        break :blk if (isSignedInt(input_kind)) SpirvOp.SConvert else SpirvOp.UConvert;
    } else if (isFloat(input_kind) and isFloat(result_kind)) blk: {
        break :blk SpirvOp.FConvert;
    } else if (isInt(input_kind) and isFloat(result_kind)) blk: {
        break :blk if (isSignedInt(input_kind)) SpirvOp.ConvertSToF else SpirvOp.ConvertUToF;
    } else if (isFloat(input_kind) and isInt(result_kind)) blk: {
        break :blk if (isSignedInt(result_kind)) SpirvOp.ConvertFToS else SpirvOp.ConvertFToU;
    } else {
        return error.UnsupportedType;
    };

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        input_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitBitcast(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 1) return error.UnsupportedOperation;
    const input = op.operands.items[0].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const input_kind = kindFromType(input.type) orelse return error.UnsupportedType;
    const result_kind = kindFromType(result.type) orelse return error.UnsupportedType;

    if (input_kind == .bool or result_kind == .bool) return error.UnsupportedType;

    if (bitWidth(input_kind) != bitWidth(result_kind)) return error.UnsupportedType;

    const input_id = try self.getValue(input);

    if (input_kind == result_kind) {
        try self.bindValue(result, input_id);
        return;
    }

    const result_type_id = try self.getTypeForValue(result);
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Bitcast, &.{
        result_type_id,
        result_id,
        input_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitCmp(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const cmp = ArithDialect.CmpOp{ .op = op };
    const pred = cmp.getPredicate() orelse return error.MissingAttribute;

    const kind = kindFromType(lhs.type) orelse return error.UnsupportedType;
    const lhs_id = try self.getValue(lhs);
    const rhs_id = try self.getValue(rhs);
    const result_type_id = try self.getTypeForValue(result);

    const opcode: u16 = if (isFloat(kind)) switch (pred) {
        .eq => SpirvOp.FOrdEqual,
        // IEEE's `!=` is the one unordered comparison: true when either
        // operand is a NaN.
        .ne => SpirvOp.FUnordNotEqual,
        .lt, .slt, .ult => SpirvOp.FOrdLessThan,
        .le, .sle, .ule => SpirvOp.FOrdLessThanEqual,
        .gt, .sgt, .ugt => SpirvOp.FOrdGreaterThan,
        .ge, .sge, .uge => SpirvOp.FOrdGreaterThanEqual,
    } else switch (pred) {
        .eq => SpirvOp.IEqual,
        .ne => SpirvOp.INotEqual,
        .lt => if (isSignedInt(kind)) SpirvOp.SLessThan else SpirvOp.ULessThan,
        .le => if (isSignedInt(kind)) SpirvOp.SLessThanEqual else SpirvOp.ULessThanEqual,
        .gt => if (isSignedInt(kind)) SpirvOp.SGreaterThan else SpirvOp.UGreaterThan,
        .ge => if (isSignedInt(kind)) SpirvOp.SGreaterThanEqual else SpirvOp.UGreaterThanEqual,
        .slt => SpirvOp.SLessThan,
        .sle => SpirvOp.SLessThanEqual,
        .sgt => SpirvOp.SGreaterThan,
        .sge => SpirvOp.SGreaterThanEqual,
        .ult => SpirvOp.ULessThan,
        .ule => SpirvOp.ULessThanEqual,
        .ugt => SpirvOp.UGreaterThan,
        .uge => SpirvOp.UGreaterThanEqual,
    };

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        lhs_id,
        rhs_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitSelect(self: anytype, op: *ir.Operation) !void {
    const select = ArithDialect.SelectOp{ .op = op };
    const cond_id = try self.getValue(select.getCondition());
    const true_id = try self.getValue(select.getTrueValue());
    const false_id = try self.getValue(select.getFalseValue());
    const result = select.getResult();
    const result_type_id = try self.getTypeForValue(result);

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Select, &.{
        result_type_id,
        result_id,
        cond_id,
        true_id,
        false_id,
    });
    try self.bindValue(result, result_id);
}

pub fn elementByteSize(kind: Kind) ?usize {
    return switch (kind) {
        .i8, .u8 => 1,
        .i16, .u16, .f16 => 2,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64 => 8,
        .bool => 1,
        .void => null,
    };
}

pub fn isFloat(kind: Kind) bool {
    return switch (kind) {
        .f16, .f32, .f64 => true,
        else => false,
    };
}

pub fn isSignedInt(kind: Kind) bool {
    return switch (kind) {
        .i8, .i16, .i32, .i64 => true,
        else => false,
    };
}

pub fn isUnsignedInt(kind: Kind) bool {
    return switch (kind) {
        .u8, .u16, .u32, .u64 => true,
        else => false,
    };
}

pub fn isInt(kind: Kind) bool {
    return isSignedInt(kind) or isUnsignedInt(kind);
}

pub fn bitWidth(kind: Kind) u32 {
    return switch (kind) {
        .i8, .u8 => 8,
        .i16, .u16, .f16 => 16,
        .i32, .u32, .f32 => 32,
        .i64, .u64, .f64 => 64,
        .bool => 1,
        .void => 0,
    };
}

pub fn isFullMaskConstant(kind: Kind, value: i64) bool {
    if (!isInt(kind)) return false;
    const bits = bitWidth(kind);
    if (bits == 0 or bits > 64) return false;
    const raw: u64 = @bitCast(value);
    if (bits == 64) return raw == ~@as(u64, 0);
    const shift: u6 = @intCast(bits);
    const full_mask: u64 = (@as(u64, 1) << shift) - 1;
    return (raw & full_mask) == full_mask;
}

pub const IntBits = struct {
    word0: u32,
    word1: u32,
    word_count: u32,
};

pub fn integerConstantBits(kind: Kind, value: i64) ?IntBits {
    switch (kind) {
        .i8 => {
            const v = std.math.cast(i8, value) orelse return null;
            const raw: u8 = @bitCast(v);
            return .{ .word0 = @as(u32, raw), .word1 = 0, .word_count = 1 };
        },
        .i16 => {
            const v = std.math.cast(i16, value) orelse return null;
            const raw: u16 = @bitCast(v);
            return .{ .word0 = @as(u32, raw), .word1 = 0, .word_count = 1 };
        },
        .i32 => {
            const v = std.math.cast(i32, value) orelse return null;
            return .{ .word0 = @bitCast(v), .word1 = 0, .word_count = 1 };
        },
        .u8 => {
            if (value < 0) return null;
            const v = std.math.cast(u8, @as(u64, @intCast(value))) orelse return null;
            return .{ .word0 = v, .word1 = 0, .word_count = 1 };
        },
        .u16 => {
            if (value < 0) return null;
            const v = std.math.cast(u16, @as(u64, @intCast(value))) orelse return null;
            return .{ .word0 = v, .word1 = 0, .word_count = 1 };
        },
        .u32 => {
            if (value < 0) return null;
            const v = std.math.cast(u32, @as(u64, @intCast(value))) orelse return null;
            return .{ .word0 = v, .word1 = 0, .word_count = 1 };
        },
        .i64 => {
            const v = value;
            const bits: u64 = @bitCast(v);
            return .{ .word0 = @intCast(bits & 0xffffffff), .word1 = @intCast(bits >> 32), .word_count = 2 };
        },
        .u64 => {
            if (value < 0) return null;
            const v: u64 = @intCast(value);
            return .{ .word0 = @intCast(v & 0xffffffff), .word1 = @intCast(v >> 32), .word_count = 2 };
        },
        else => return null,
    }
}

pub const FloatBits = struct {
    word0: u32,
    word1: u32,
    word_count: u32,
};

pub fn floatConstantBits(kind: Kind, value: f64) ?FloatBits {
    switch (kind) {
        .f16 => {
            const bits: u16 = @bitCast(@as(f16, @floatCast(value)));
            return .{ .word0 = @as(u32, bits), .word1 = 0, .word_count = 1 };
        },
        .f32 => {
            const bits: u32 = @bitCast(@as(f32, @floatCast(value)));
            return .{ .word0 = bits, .word1 = 0, .word_count = 1 };
        },
        .f64 => {
            const bits: u64 = @bitCast(value);
            return .{ .word0 = @intCast(bits & 0xffffffff), .word1 = @intCast(bits >> 32), .word_count = 2 };
        },
        else => return null,
    }
}

const BinaryIdsRecorder = struct {
    builder: ModuleBuilder,
    scalar_type_id: u32,

    fn init(allocator: std.mem.Allocator) BinaryIdsRecorder {
        return .{
            .builder = ModuleBuilder.init(allocator),
            .scalar_type_id = 99,
        };
    }

    fn deinit(self: *BinaryIdsRecorder) void {
        self.builder.deinit();
    }

    pub fn getScalarType(self: *BinaryIdsRecorder, kind: Kind) !u32 {
        try std.testing.expectEqual(Kind.f32, kind);
        return self.scalar_type_id;
    }
};
