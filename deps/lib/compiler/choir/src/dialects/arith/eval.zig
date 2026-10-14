const std = @import("std");
const ir = @import("../../core/root.zig");
const predicate_mod = @import("predicate.zig");
const scalar = @import("scalar.zig");
const types = @import("types.zig");

const Operation = ir.Operation;
const Attribute = ir.Attribute;
const interfaces = ir.interfaces;
const EvalError = interfaces.EvalError;
const EvalContext = interfaces.EvalContext;
const CmpPredicate = predicate_mod.CmpPredicate;

const arith_prefix = "arith.";

const ArithOp = enum {
    constant,
    add,
    sub,
    mul,
    div,
    rem,
    max,
    min,
    cmp,
    select,
    neg,
    abs,
    not,
    band,
    bor,
    bxor,
    shl,
    shr,
    ushr,
    cast,
    sqrt,
    popcount,
    umulhi,
    addo,
    subo,
    mulo,
};

fn classify(op: *const Operation) ?ArithOp {
    const name = op.name.name;
    if (!std.mem.startsWith(u8, name, arith_prefix)) return null;
    const suffix = name[arith_prefix.len..];
    if (std.mem.eql(u8, suffix, "constant")) return .constant;
    if (std.mem.eql(u8, suffix, "add")) return .add;
    if (std.mem.eql(u8, suffix, "sub")) return .sub;
    if (std.mem.eql(u8, suffix, "mul")) return .mul;
    if (std.mem.eql(u8, suffix, "div")) return .div;
    if (std.mem.eql(u8, suffix, "rem")) return .rem;
    if (std.mem.eql(u8, suffix, "max")) return .max;
    if (std.mem.eql(u8, suffix, "min")) return .min;
    if (std.mem.eql(u8, suffix, "cmp")) return .cmp;
    if (std.mem.eql(u8, suffix, "select")) return .select;
    if (std.mem.eql(u8, suffix, "neg")) return .neg;
    if (std.mem.eql(u8, suffix, "abs")) return .abs;
    if (std.mem.eql(u8, suffix, "not")) return .not;
    if (std.mem.eql(u8, suffix, "and")) return .band;
    if (std.mem.eql(u8, suffix, "or")) return .bor;
    if (std.mem.eql(u8, suffix, "xor")) return .bxor;
    if (std.mem.eql(u8, suffix, "shl")) return .shl;
    if (std.mem.eql(u8, suffix, "shr")) return .shr;
    if (std.mem.eql(u8, suffix, "ushr")) return .ushr;
    if (std.mem.eql(u8, suffix, "cast")) return .cast;
    if (std.mem.eql(u8, suffix, "sqrt")) return .sqrt;
    if (std.mem.eql(u8, suffix, "popcount")) return .popcount;
    if (std.mem.eql(u8, suffix, "umulhi")) return .umulhi;
    if (std.mem.eql(u8, suffix, "addo")) return .addo;
    if (std.mem.eql(u8, suffix, "subo")) return .subo;
    if (std.mem.eql(u8, suffix, "mulo")) return .mulo;
    return null;
}

fn intResultKind(op: *const Operation) ?types.ScalarKind {
    if (op.results.items.len != 1) return null;
    const type_name = op.results.items[0].type.getDialectTypeName() orelse return null;
    const kind = types.scalarKindFromTypeName(type_name) orelse return null;
    if (!types.scalarKindIsInteger(kind)) return null;
    return kind;
}

fn intOperandKind(op: *const Operation, index: usize) ?types.ScalarKind {
    if (op.operands.items.len <= index) return null;
    const type_name = op.operands.items[index].value.type.getDialectTypeName() orelse return null;
    const kind = types.scalarKindFromTypeName(type_name) orelse return null;
    if (!types.scalarKindIsInteger(kind)) return null;
    return kind;
}

fn cmpOperandKind(op: *const Operation) ?types.ScalarKind {
    const lhs_kind = intOperandKind(op, 0) orelse return null;
    const rhs_kind = intOperandKind(op, 1) orelse return null;
    if (lhs_kind != rhs_kind) return null;
    return lhs_kind;
}

fn intOperand(attr: Attribute) ?i64 {
    const int_attr = attr.cast(Attribute.IntegerAttr) orelse return null;
    return int_attr.getValue();
}

fn boolOperand(attr: Attribute) ?bool {
    if (attr.cast(Attribute.BoolAttr)) |value| return value.getValue();
    if (attr.cast(Attribute.IntegerAttr)) |value| return value.getValue() != 0;
    return null;
}

fn makeInt(ctx: *ir.Context, value: i64) EvalError!Attribute {
    return ctx.getI64Attr(value) catch error.OutOfMemory;
}

/// The one carrier of an integer of `kind`: its bits at the kind's width, sign-extended to 64 for
/// a signed kind and zero-extended for an unsigned kind and for `index`. Every integer result is
/// written in this form, and every operand is read at its width, so the carrier a value arrived
/// in (a raw constant attribute, an argument, another operation's result) never changes an answer.
pub fn canonicalInteger(value: i64, kind: types.ScalarKind) i64 {
    const bits = types.scalarBitWidth(kind);
    if (usesUnsignedOrder(kind)) return scalar.unsignedResult(scalar.maskToBits(value, bits), bits);
    return scalar.truncate(value, bits);
}

/// The one carrier of a float of `kind`: an f64 holding the kind's value exactly. A NaN keeps
/// its sign, its quiet bit and the payload bits the kind holds, at every float kind. Rounding a
/// number to the kind is a separate matter and never sees a NaN.
pub fn canonicalFloat(value: f64, kind: types.ScalarKind) EvalError!f64 {
    if (std.math.isNan(value)) return switch (kind) {
        .f16 => scalar.nanCarrier(value, 10),
        .bf16 => scalar.nanCarrier(value, 7),
        .f32 => scalar.nanCarrier(value, 23),
        .f64 => value,
        else => error.UnsupportedOperation,
    };
    return switch (kind) {
        .f32 => scalar.float32Carrier(scalar.float32Bits(value)),
        else => roundedFloat(value, kind),
    };
}

fn makeCanonicalInt(ctx: *ir.Context, value: i64, kind: types.ScalarKind) EvalError!Attribute {
    return makeInt(ctx, canonicalInteger(value, kind));
}

fn makeBool(ctx: *ir.Context, value: bool) EvalError!Attribute {
    return ctx.getBoolAttr(value) catch error.OutOfMemory;
}

fn cmpPredicate(op: *const Operation) ?CmpPredicate {
    const attr = op.getAttrAs(Attribute.DialectAttr, "predicate") orelse return null;
    inline for (
        @typeInfo(CmpPredicate).@"enum".field_names,
        std.meta.tags(CmpPredicate),
    ) |field_name, value| {
        if (std.mem.eql(u8, attr.payload, field_name)) return value;
    }
    return null;
}

fn usesUnsignedOrder(kind: types.ScalarKind) bool {
    return switch (kind) {
        .u8, .u16, .u32, .u64, .index => true,
        else => false,
    };
}

/// The absolute value of one integer of `result_kind`, a function of its typed value alone.
///
/// A SIGNED VALUE IS READ AT ITS WIDTH BEFORE ITS SIGN IS. An `i8` operand of 255 and one of -1 are
/// the same value, and both answer 1; the minimum answers itself, as two's complement wraps. AN
/// UNSIGNED OR INDEX VALUE IS ALREADY ITS OWN ABSOLUTE VALUE, so it answers itself in unsigned form:
/// a `u8` of 255 answers 255 whether it arrived as 255 or as the -1 a wrapping subtraction leaves.
/// The emitters agree: x86_64 and aarch64 move an unsigned operand through unchanged, aarch64 treats
/// `index` as unsigned, and x86_64 refuses `index` absolute value.
fn absInt(value: i64, result_kind: types.ScalarKind) i64 {
    const bits = types.scalarBitWidth(result_kind);
    if (usesUnsignedOrder(result_kind)) return scalar.unsignedResult(scalar.maskToBits(value, bits), bits);
    return scalar.absWrap(value, bits);
}

fn minMaxInt(kind: ArithOp, lhs: i64, rhs: i64, result_kind: types.ScalarKind) i64 {
    const bits = types.scalarBitWidth(result_kind);
    if (usesUnsignedOrder(result_kind)) {
        const left = scalar.maskToBits(lhs, bits);
        const right = scalar.maskToBits(rhs, bits);
        const selected = switch (kind) {
            .max => if (left >= right) left else right,
            .min => if (left <= right) left else right,
            else => unreachable,
        };
        return scalar.unsignedResult(selected, bits);
    }

    const left = scalar.truncate(lhs, bits);
    const right = scalar.truncate(rhs, bits);
    return switch (kind) {
        .max => if (left >= right) left else right,
        .min => if (left <= right) left else right,
        else => unreachable,
    };
}

fn cmpInt(predicate: CmpPredicate, lhs: i64, rhs: i64, bits: u8) bool {
    const lhs_u = scalar.maskToBits(lhs, bits);
    const rhs_u = scalar.maskToBits(rhs, bits);
    const lhs_s = scalar.truncate(lhs, bits);
    const rhs_s = scalar.truncate(rhs, bits);
    return switch (predicate) {
        .eq => lhs_u == rhs_u,
        .ne => lhs_u != rhs_u,
        .lt, .slt => lhs_s < rhs_s,
        .le, .sle => lhs_s <= rhs_s,
        .gt, .sgt => lhs_s > rhs_s,
        .ge, .sge => lhs_s >= rhs_s,
        .ult => lhs_u < rhs_u,
        .ule => lhs_u <= rhs_u,
        .ugt => lhs_u > rhs_u,
        .uge => lhs_u >= rhs_u,
    };
}

fn canEval(op_ptr: *const anyopaque) bool {
    const op: *const Operation = @ptrCast(@alignCast(op_ptr));
    const kind = classify(op) orelse return false;
    if (kind == .constant) return true;
    if (kind == .addo or kind == .subo or kind == .mulo) return overflowShape(op);
    if (op.getNumResults() != 1) return false;
    if (kind == .cmp) return op.getNumOperands() == 2;
    return types.scalarKindFromType(op.results.items[0].type) != null;
}

fn evaluate(
    op_ptr: *const anyopaque,
    operands: []const Attribute,
    eval_ctx: *const EvalContext,
) EvalError!Attribute {
    _ = eval_ctx;
    const op: *const Operation = @ptrCast(@alignCast(op_ptr));
    const kind = classify(op) orelse return error.UnsupportedOperation;
    const ctx = op.getContext();

    if (kind == .constant) return evaluateConstant(op);

    if (kind == .addo or kind == .subo or kind == .mulo) {
        if (!overflowShape(op)) return error.UnsupportedOperation;
        if (operands.len != 2) return error.InvalidOperand;
        const lhs: i128 = intOperand(operands[0]) orelse return error.InvalidOperand;
        const rhs: i128 = intOperand(operands[1]) orelse return error.InvalidOperand;
        const exact = switch (kind) {
            .addo => lhs + rhs,
            .subo => lhs - rhs,
            .mulo => lhs * rhs,
            else => unreachable,
        };
        const wrapped: i64 = @truncate(exact);
        const overflow = exact < std.math.minInt(i64) or exact > std.math.maxInt(i64);
        return ctx.getArrayAttr(&.{
            try makeInt(ctx, wrapped),
            try makeBool(ctx, overflow),
        }) catch error.OutOfMemory;
    }

    if (kind == .cmp) {
        if (operands.len != 2) return error.InvalidOperand;
        const operand_type = types.scalarKindFromType(op.operands.items[0].value.type) orelse
            return error.UnsupportedOperation;
        if (types.scalarKindIsFloat(operand_type)) {
            return evaluateFloatCmp(op, operands, operand_type);
        }
        if (operand_type == .bool) return evaluateBoolCmp(op, operands);
        const operand_kind = cmpOperandKind(op) orelse return error.UnsupportedOperation;
        const lhs = intOperand(operands[0]) orelse return error.InvalidOperand;
        const rhs = intOperand(operands[1]) orelse return error.InvalidOperand;
        const predicate = cmpPredicate(op) orelse return error.InvalidOperand;
        return makeBool(ctx, cmpInt(predicate, lhs, rhs, types.scalarBitWidth(operand_kind)));
    }

    if (kind == .cast) return evaluateCast(op, operands);
    const result_class = types.scalarKindFromType(op.results.items[0].type) orelse
        return error.UnsupportedOperation;
    if (types.scalarKindIsFloat(result_class)) {
        return evaluateFloat(op, kind, operands, result_class);
    }
    if (result_class == .bool) return evaluateBool(ctx, kind, operands);
    const result_kind = intResultKind(op) orelse return error.UnsupportedOperation;
    return evaluateInteger(ctx, kind, operands, result_kind);
}

/// A constant's value in its kind's canonical carrier. The attribute may spell the same bits in
/// another carrier: an `i8` constant of 255 is -1, and a `u8` constant of -1 is 255.
fn evaluateConstant(op: *const Operation) EvalError!Attribute {
    const attr = op.getAttr("value") orelse return error.InvalidConstant;
    const ctx = op.getContext();
    if (op.results.items.len != 1) return attr;
    const kind = types.scalarKindFromType(op.results.items[0].type) orelse return attr;
    // An attribute of another class than its kind's is not this function's to judge: the verifier
    // and the effect declaration refuse it, and it is handed on as it is.
    if (kind == .bool) return makeBool(ctx, boolOperand(attr) orelse return attr);
    if (types.scalarKindIsInteger(kind)) {
        return makeCanonicalInt(ctx, intOperand(attr) orelse return attr, kind);
    }
    // The unspecified NaN is an evaluator result and never a constant's value.
    if (unspecifiedNanKind(attr) != null) return error.AbstractValueInConstant;
    const float = attr.cast(Attribute.FloatAttr) orelse return attr;
    return makeFloat(ctx, try canonicalFloat(float.getValue(), kind));
}

fn overflowShape(op: *const Operation) bool {
    if (op.getNumOperands() != 2 or op.getNumResults() != 2) return false;
    if (types.scalarKindFromType(op.results.items[0].type) != .i64) return false;
    if (types.scalarKindFromType(op.results.items[1].type) != .bool) return false;
    for (op.getOperandValues()) |operand| {
        if (types.scalarKindFromType(operand.type) != .i64) return false;
    }
    return op.regions.items.len == 0;
}

fn evaluateInteger(
    ctx: *ir.Context,
    kind: ArithOp,
    operands: []const Attribute,
    result_kind: types.ScalarKind,
) EvalError!Attribute {
    const bits = types.scalarBitWidth(result_kind);

    if (kind == .select) {
        if (operands.len != 3) return error.InvalidOperand;
        const cond = boolOperand(operands[0]) orelse return error.InvalidOperand;
        const selected = intOperand(if (cond) operands[1] else operands[2]) orelse
            return error.InvalidOperand;
        return makeCanonicalInt(ctx, selected, result_kind);
    }

    switch (kind) {
        .neg, .abs, .not, .popcount => {
            if (operands.len != 1) return error.InvalidOperand;
            const value = intOperand(operands[0]) orelse return error.InvalidOperand;
            const folded: i64 = switch (kind) {
                .neg => scalar.negWrap(value, bits),
                .abs => absInt(value, result_kind),
                .not => scalar.bitNot(value, bits),
                .popcount => @intCast(@popCount(scalar.maskToBits(value, bits))),
                else => unreachable,
            };
            return makeCanonicalInt(ctx, folded, result_kind);
        },
        else => {},
    }

    if (operands.len != 2) return error.InvalidOperand;
    const lhs = intOperand(operands[0]) orelse return error.InvalidOperand;
    const rhs = intOperand(operands[1]) orelse return error.InvalidOperand;
    const folded: i64 = switch (kind) {
        .add => scalar.addWrap(lhs, rhs, bits),
        .sub => scalar.subWrap(lhs, rhs, bits),
        .mul => scalar.mulWrap(lhs, rhs, bits),
        .umulhi => scalar.unsignedResult(@intCast(
            (@as(u128, scalar.maskToBits(lhs, bits)) * scalar.maskToBits(rhs, bits)) >>
                @intCast(bits),
        ), bits),
        .div, .rem => try divide(kind, lhs, rhs, result_kind),
        .max, .min => minMaxInt(kind, lhs, rhs, result_kind),
        .band => scalar.bitAnd(lhs, rhs, bits),
        .bor => scalar.bitOr(lhs, rhs, bits),
        .bxor => scalar.bitXor(lhs, rhs, bits),
        .shl, .shr, .ushr => blk: {
            // The count is an operand of the same kind, so it is read at the kind's width as an
            // unsigned number: a raw carrier of 256 at width 8 is a count of zero.
            const typed_count: i64 = @bitCast(scalar.maskToBits(rhs, bits));
            const count = scalar.shiftCount(typed_count, bits) orelse
                return error.InvalidShiftAmount;
            break :blk switch (kind) {
                .shl => scalar.shiftLeftWrap(lhs, count, bits),
                .shr => scalar.shiftRightArithmetic(lhs, count, bits),
                .ushr => scalar.shiftRightLogical(lhs, count, bits),
                else => unreachable,
            };
        },
        else => return error.UnsupportedOperation,
    };
    return makeCanonicalInt(ctx, folded, result_kind);
}

/// The quotient or remainder of two integers of `result_kind`, or the failure arith declares for
/// them: `DivisionByZero` for a zero divisor, and `SignedDivisionOverflow` for the signed minimum
/// over -1, whose quotient the kind cannot hold. The names are the declaration's `failure_name`s.
fn divide(kind: ArithOp, lhs: i64, rhs: i64, result_kind: types.ScalarKind) EvalError!i64 {
    const bits = types.scalarBitWidth(result_kind);
    if (scalar.maskToBits(rhs, bits) == 0) return error.DivisionByZero;
    if (usesUnsignedOrder(result_kind)) return switch (kind) {
        .div => scalar.divTruncUnsignedChecked(lhs, rhs, bits).?,
        .rem => scalar.remTruncUnsignedChecked(lhs, rhs, bits).?,
        else => unreachable,
    };
    return switch (kind) {
        .div => scalar.divTruncChecked(lhs, rhs, bits),
        .rem => scalar.remTruncChecked(lhs, rhs, bits),
        else => unreachable,
    } orelse error.SignedDivisionOverflow;
}

fn floatOperand(attr: Attribute) EvalError!f64 {
    return (attr.cast(Attribute.FloatAttr) orelse return error.InvalidOperand).getValue();
}

const unspecified_nan_name = "arith.unspecified_nan";

/// The evaluator's answer for an arithmetic result that is a NaN: a quiet NaN of `kind` whose
/// sign and payload IEEE 754 leaves to the implementation. It carries no bits, so a reader
/// cannot mistake it for a NaN whose bits are known, and it is no `FloatAttr`, so nothing that
/// writes a float constant can write it. It exists in evaluator results only.
pub fn unspecifiedNan(ctx: *ir.Context, kind: types.ScalarKind) EvalError!Attribute {
    std.debug.assert(types.scalarKindIsFloat(kind));
    return ctx.getDialectAttr(unspecified_nan_name, @tagName(kind)) catch error.OutOfMemory;
}

/// The float kind `attr` is an unspecified NaN of, or null when it is any other attribute.
pub fn unspecifiedNanKind(attr: Attribute) ?types.ScalarKind {
    if (!std.mem.eql(u8, attr.abstract.name, unspecified_nan_name)) return null;
    const dialect = attr.cast(Attribute.DialectAttr) orelse return null;
    return std.meta.stringToEnum(types.ScalarKind, dialect.payload);
}

/// A float operand: a value whose every bit is known, or the unspecified NaN.
const Float = union(enum) { exact: f64, unspecified };

/// Read an operand of `kind`. An unspecified NaN of another kind is malformed: a cast is the
/// only way from one float kind to another, and it answers the result's kind.
fn floatRead(attr: Attribute, kind: types.ScalarKind) EvalError!Float {
    if (unspecifiedNanKind(attr)) |held| {
        if (held != kind) return error.InvalidOperand;
        return .unspecified;
    }
    return .{ .exact = try floatOperand(attr) };
}

fn makeFloat(ctx: *ir.Context, value: f64) EvalError!Attribute {
    return ctx.getF64Attr(value) catch error.OutOfMemory;
}

fn evaluateBool(ctx: *ir.Context, kind: ArithOp, operands: []const Attribute) EvalError!Attribute {
    if (kind == .select) {
        if (operands.len != 3) return error.InvalidOperand;
        const condition = boolOperand(operands[0]) orelse return error.InvalidOperand;
        const selected = operands[if (condition) @as(usize, 1) else 2];
        return makeBool(ctx, boolOperand(selected) orelse return error.InvalidOperand);
    }
    if (operands.len == 0) return error.InvalidOperand;
    const lhs = boolOperand(operands[0]) orelse return error.InvalidOperand;
    if (kind == .not and operands.len == 1) return makeBool(ctx, !lhs);
    if (operands.len != 2) return error.InvalidOperand;
    const rhs = boolOperand(operands[1]) orelse return error.InvalidOperand;
    return makeBool(ctx, switch (kind) {
        .band => lhs and rhs,
        .bor => lhs or rhs,
        .bxor => lhs != rhs,
        else => return error.UnsupportedOperation,
    });
}

fn evaluateBoolCmp(op: *const Operation, operands: []const Attribute) EvalError!Attribute {
    const lhs = boolOperand(operands[0]) orelse return error.InvalidOperand;
    const rhs = boolOperand(operands[1]) orelse return error.InvalidOperand;
    const predicate = cmpPredicate(op) orelse return error.InvalidPredicate;
    return makeBool(op.getContext(), switch (predicate) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        else => return error.InvalidPredicate,
    });
}

fn evaluateFloatCmp(
    op: *const Operation,
    operands: []const Attribute,
    kind: types.ScalarKind,
) EvalError!Attribute {
    if (!op.getContext().arithmetic_policy.permitsFloatingValues()) {
        return error.RequiresDynamicInfo;
    }
    // An unspecified NaN compares as any NaN does, and the answer is an exact bool.
    const lhs = switch (try floatRead(operands[0], kind)) {
        .exact => |value| try roundedFloat(value, kind),
        .unspecified => std.math.nan(f64),
    };
    const rhs = switch (try floatRead(operands[1], kind)) {
        .exact => |value| try roundedFloat(value, kind),
        .unspecified => std.math.nan(f64),
    };
    const predicate = cmpPredicate(op) orelse return error.InvalidPredicate;
    return makeBool(op.getContext(), switch (predicate) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt => lhs < rhs,
        .le => lhs <= rhs,
        .gt => lhs > rhs,
        .ge => lhs >= rhs,
        else => return error.InvalidPredicate,
    });
}

fn evaluateFloat(
    op: *const Operation,
    kind: ArithOp,
    operands: []const Attribute,
    typ: types.ScalarKind,
) EvalError!Attribute {
    const ctx = op.getContext();
    if (!ctx.arithmetic_policy.permitsFloatingValues()) {
        return error.RequiresDynamicInfo;
    }
    // Selection and the two sign operations move bits. They never round, and a NaN leaves them
    // with the payload it came in with: neg flips the sign bit and abs clears it. An unspecified
    // NaN has no bits to move and stays what it is. Selection reads the chosen arm only.
    const sign_bit: u64 = 1 << 63;
    switch (kind) {
        .select => {
            if (operands.len != 3) return error.InvalidOperand;
            const condition = boolOperand(operands[0]) orelse return error.InvalidOperand;
            const selected = operands[if (condition) @as(usize, 1) else 2];
            return switch (try floatRead(selected, typ)) {
                .exact => |value| makeFloat(ctx, try canonicalFloat(value, typ)),
                .unspecified => selected,
            };
        },
        .neg, .abs => {
            if (operands.len != 1) return error.InvalidOperand;
            const operand = switch (try floatRead(operands[0], typ)) {
                .exact => |value| value,
                .unspecified => return operands[0],
            };
            const carried: u64 = @bitCast(try canonicalFloat(operand, typ));
            const moved = if (kind == .neg) carried ^ sign_bit else carried & ~sign_bit;
            return makeFloat(ctx, @bitCast(moved));
        },
        else => {},
    }
    const value = switch (typ) {
        .f32 => try floatArithmetic(f32, typ, kind, operands),
        .f64 => try floatArithmetic(f64, typ, kind, operands),
        else => return error.UnsupportedOperation,
    };
    return makeFloat(ctx, value orelse return unspecifiedNan(ctx, typ));
}

/// The `T` an operand of `typ` carries, with its exact bits, or null for an unspecified NaN.
fn typedFloat(comptime T: type, typ: types.ScalarKind, attr: Attribute) EvalError!?T {
    const carried = switch (try floatRead(attr, typ)) {
        .exact => |value| value,
        .unspecified => return null,
    };
    if (T == f32) return @as(f32, @bitCast(scalar.float32Bits(carried)));
    return carried;
}

/// One arithmetic operation at `T`'s precision, rounded once. Null is the unspecified NaN: a NaN
/// result has neither its sign nor its payload fixed by the standard, whether it came from an
/// operand that was already unspecified or was made here. sqrt of a negative number is such a
/// NaN: arith declares sqrt total.
fn floatArithmetic(
    comptime T: type,
    typ: types.ScalarKind,
    kind: ArithOp,
    operands: []const Attribute,
) EvalError!?f64 {
    if (operands.len == 0 or operands.len > 2) return error.InvalidOperand;
    const lhs = try typedFloat(T, typ, operands[0]);
    if (operands.len == 1) {
        if (kind != .sqrt) return error.UnsupportedOperation;
        const result = @sqrt(lhs orelse return null);
        return if (std.math.isNan(result)) null else result;
    }
    const rhs = try typedFloat(T, typ, operands[1]);
    switch (kind) {
        .add, .sub, .mul, .div => {},
        else => return error.UnsupportedOperation,
    }
    const left = lhs orelse return null;
    const right = rhs orelse return null;
    const result: T = switch (kind) {
        .add => left + right,
        .sub => left - right,
        .mul => left * right,
        .div => left / right,
        else => unreachable,
    };
    return if (std.math.isNan(result)) null else result;
}

pub fn roundedFloat(value: f64, kind: types.ScalarKind) EvalError!f64 {
    return switch (kind) {
        .f16 => @as(f16, @floatCast(value)),
        .bf16 => scalar.roundBfloat(value),
        .f32 => @as(f32, @floatCast(value)),
        .f64 => value,
        else => error.UnsupportedOperation,
    };
}

fn integerValue(value: i64, kind: types.ScalarKind) i128 {
    const bits = types.scalarBitWidth(kind);
    return if (usesUnsignedOrder(kind))
        scalar.maskToBits(value, bits)
    else
        scalar.truncate(value, bits);
}

fn integerFloat(value: i128, kind: types.ScalarKind) EvalError!f64 {
    return switch (kind) {
        .f16 => @as(f16, @floatFromInt(value)),
        .f32 => @as(f32, @floatFromInt(value)),
        .f64 => @floatFromInt(value),
        .bf16 => integerBfloat(value),
        else => error.UnsupportedOperation,
    };
}

/// Round an exact integer directly to eight significant bits, avoiding double rounding.
fn integerBfloat(value: i128) f64 {
    const magnitude: u128 = @intCast(if (value < 0) -value else value);
    if (magnitude < 256) return @floatFromInt(value);
    const exponent = std.math.log2_int(u128, magnitude);
    const shift: u7 = @intCast(exponent - 7);
    const half = @as(u128, 1) << (shift - 1);
    const remainder = magnitude & ((half << 1) - 1);
    var significant = magnitude >> shift;
    if (remainder > half or (remainder == half and significant & 1 != 0)) significant += 1;
    const rounded: f64 = @floatFromInt(significant << shift);
    return if (value < 0) -rounded else rounded;
}

fn evaluateCast(op: *const Operation, operands: []const Attribute) EvalError!Attribute {
    if (operands.len != 1) return error.InvalidOperand;
    const source = types.scalarKindFromType(op.operands.items[0].value.type) orelse
        return error.UnsupportedOperation;
    const result = types.scalarKindFromType(op.results.items[0].type) orelse
        return error.UnsupportedOperation;
    if (source == .bool or result == .bool) {
        if (source != result) return error.UnsupportedOperation;
        return makeBool(op.getContext(), boolOperand(operands[0]) orelse return error.InvalidOperand);
    }
    if (types.scalarKindIsFloat(source) or types.scalarKindIsFloat(result)) {
        if (!op.getContext().arithmetic_policy.permitsFloatingValues()) {
            return error.RequiresDynamicInfo;
        }
    }
    if (types.scalarKindIsInteger(source)) {
        const raw = intOperand(operands[0]) orelse return error.InvalidOperand;
        const value = integerValue(raw, source);
        if (types.scalarKindIsFloat(result)) {
            return makeFloat(op.getContext(), try integerFloat(value, result));
        }
        const bits: u64 = @truncate(@as(u128, @bitCast(value)));
        const narrowed = scalar.unsignedResult(bits, types.scalarBitWidth(result));
        const result_value = if (usesUnsignedOrder(result))
            narrowed
        else
            scalar.truncate(narrowed, types.scalarBitWidth(result));
        return makeInt(op.getContext(), result_value);
    }
    if (types.scalarKindIsFloat(source) and types.scalarKindIsInteger(result)) {
        const operand = switch (try floatRead(operands[0], source)) {
            .exact => |value| value,
            .unspecified => return error.InvalidFloatToInteger,
        };
        const value = try roundedFloat(operand, source);
        const integer = scalar.floatToInt(
            value,
            types.scalarBitWidth(result),
            types.scalarKindIsSignedInteger(result) and result != .index,
        ) orelse return error.InvalidFloatToInteger;
        return makeInt(op.getContext(), integer);
    }
    if (types.scalarKindIsFloat(source) and types.scalarKindIsFloat(result)) {
        const ctx = op.getContext();
        const operand = switch (try floatRead(operands[0], source)) {
            .exact => |value| value,
            .unspecified => return if (source == result) operands[0] else unspecifiedNan(ctx, result),
        };
        // A cast to the operand's own kind is a move: every bit is kept, a signaling NaN's too.
        if (source == result) return makeFloat(ctx, try canonicalFloat(operand, source));
        // A conversion is arithmetic: it quiets a NaN and may not keep its payload.
        const value = try roundedFloat(operand, source);
        if (std.math.isNan(value)) return unspecifiedNan(ctx, result);
        return makeFloat(ctx, try roundedFloat(value, result));
    }
    return error.UnsupportedOperation;
}

const evaluatable_vtable = interfaces.Evaluatable.VTable{
    .canEval = canEval,
    .evaluate = evaluate,
};

pub fn fallback(op: *const Operation) ?*const anyopaque {
    _ = op;
    return &evaluatable_vtable;
}
