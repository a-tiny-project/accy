const std = @import("std");
const wasm = @import("../../../../root.zig");
const ir = @import("../../../../../../core/root.zig");
const dialects = @import("../../../../../../dialects/root.zig");
const emission = @import("../../../root.zig");
const instruction = @import("../root.zig");
const arithmetic = @import("root.zig");

const ArithDialect = dialects.ArithDialect;

const UnaryKind = enum {
    neg,
    abs,
    sqrt,
};

pub fn writeConstant(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    const constant = ArithDialect.ConstantOp{ .op = operation };
    const result = constant.getResult();
    const scalar = emission.types.scalarKindForType(result.type) orelse
        return error.CodeGenFailed;
    switch (scalar) {
        .bool => {
            const attr = operation.getAttrAs(ir.Attribute.BoolAttr, "value") orelse
                return error.CodeGenFailed;
            try writer.out.writeByte(0x41);
            try wasm.binary.writeSleb(writer.out, if (attr.getValue()) 1 else 0);
        },
        .i8, .i16, .i32, .u8, .u16, .u32 => {
            const value = constant.getIntValue() orelse return error.CodeGenFailed;
            try writer.out.writeByte(0x41);
            try wasm.binary.writeSleb(writer.out, word32(value, scalar));
        },
        .index => {
            // The evaluator's index is 64 bits and this backend's is 32. Below 2^31 both
            // readings of the word agree, and past it the constant is refused.
            const value = constant.getIntValue() orelse return error.CodeGenFailed;
            if (value < 0 or value > std.math.maxInt(i32)) return error.UnsupportedOperation;
            try writer.out.writeByte(0x41);
            try wasm.binary.writeSleb(writer.out, value);
        },
        .i64, .u64 => {
            const value = constant.getIntValue() orelse return error.CodeGenFailed;
            try writer.out.writeByte(0x42);
            try wasm.binary.writeSleb(writer.out, value);
        },
        .f32 => {
            const attr = operation.getAttrAs(ir.Attribute.FloatAttr, "value") orelse
                return error.CodeGenFailed;
            try writer.out.writeByte(0x43);
            try wasm.binary.writeF32(writer.out, attr.getF32Value());
        },
        .f64 => {
            const value = constant.getFloatValue() orelse return error.CodeGenFailed;
            try writer.out.writeByte(0x44);
            try wasm.binary.writeF64(writer.out, value);
        },
        .f16, .bf16 => return error.CodeGenFailed,
    }
    try writer.writeLocalSet(try writer.localFor(result));
}

/// The evaluator's carrier for `kind`, then the signed reading of its 32-bit pattern, the one
/// spelling an `i32.const` immediate admits.
pub fn word32(value: i64, kind: dialects.arith.ScalarKind) i32 {
    const canonical: u64 = @bitCast(dialects.arith.eval.canonicalInteger(value, kind));
    return @bitCast(@as(u32, @truncate(canonical)));
}

pub fn writeBinary(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
    kind: arithmetic.opcode.BinaryKind,
) emission.Error!void {
    const lhs = operation.getOperand(0) orelse return error.CodeGenFailed;
    const rhs = operation.getOperand(1) orelse return error.CodeGenFailed;
    const result = operation.getResult(0) orelse return error.CodeGenFailed;
    const scalar = emission.types.scalarKindForType(result.type) orelse
        return error.CodeGenFailed;
    try arithmetic.opcode.requireNoSubwordArithmetic(scalar);
    switch (kind) {
        .shl, .shr, .ushr => try writeShiftGuard(Out, writer, rhs, scalar),
        .rem => try writeRemainderGuard(Out, writer, lhs, rhs, scalar),
        else => {},
    }
    try writer.writeValue(lhs);
    try writer.writeValue(rhs);
    try writer.out.writeByte(try arithmetic.opcode.binary(kind, scalar));
    try writer.writeLocalSet(try writer.localFor(result));
}

/// The evaluator fails a shift whose count, read unsigned, reaches the width, where a wasm
/// shift takes the count modulo the width. Stop there instead, before the shift and whether
/// or not its result is used. A constant count below the width needs no test.
fn writeShiftGuard(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    count: *ir.Value,
    scalar: dialects.arith.ScalarKind,
) emission.Error!void {
    // The kind's width, capped by the wasm value's, so a wider index widens this guard.
    const wide = switch (scalar) {
        .bool, .i32, .u32, .index => false,
        .i64, .u64 => true,
        else => return error.CodeGenFailed,
    };
    const width: u64 = @min(dialects.arith.scalarBitWidth(scalar), @as(u64, if (wide) 64 else 32));
    if (count.getDefiningOp()) |defining| {
        const operation: *ir.Operation = @ptrCast(@alignCast(defining));
        if (std.mem.eql(u8, operation.name.name, ArithDialect.ConstantOp.operation_name)) {
            const constant = ArithDialect.ConstantOp{ .op = operation };
            if (constant.getIntValue()) |value| {
                const canonical = dialects.arith.eval.canonicalInteger(value, scalar);
                if (@as(u64, @bitCast(canonical)) < width) return;
            }
        }
    }
    try writer.writeValue(count);
    // ge_u against the width.
    if (wide) {
        try writer.out.writeByte(0x42);
        try wasm.binary.writeSleb(writer.out, @intCast(width));
        try writer.out.writeByte(0x5a);
    } else {
        try writer.out.writeByte(0x41);
        try wasm.binary.writeSleb(writer.out, @intCast(width));
        try writer.out.writeByte(0x4f);
    }
    try writeStop(Out, writer);
}

/// The evaluator fails the signed minimum over -1, whose remainder wasm's rem_s answers as 0.
/// A zero divisor keeps rem_s's own trap.
fn writeRemainderGuard(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    lhs: *ir.Value,
    rhs: *ir.Value,
    scalar: dialects.arith.ScalarKind,
) emission.Error!void {
    const constant: u8, const eq: u8, const minimum: i64 = switch (scalar) {
        .i32 => .{ 0x41, 0x46, std.math.minInt(i32) },
        .i64 => .{ 0x42, 0x51, std.math.minInt(i64) },
        else => return,
    };
    try writer.writeValue(lhs);
    try writer.out.writeByte(constant);
    try wasm.binary.writeSleb(writer.out, minimum);
    try writer.out.writeByte(eq);
    try writer.writeValue(rhs);
    try writer.out.writeByte(constant);
    try wasm.binary.writeSleb(writer.out, -1);
    try writer.out.writeByte(eq);
    try writer.out.writeByte(0x71); // i32.and of the two tests
    try writeStop(Out, writer);
}

/// `if (cond) { unreachable }` on the i32 condition the caller left on the stack.
fn writeStop(comptime Out: type, writer: *instruction.Writer(Out)) emission.Error!void {
    try writer.out.writeAll(&.{ 0x04, 0x40, 0x00, 0x0b });
}

pub fn writeCmp(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    const cmp = ArithDialect.CmpOp{ .op = operation };
    const predicate = cmp.getPredicate() orelse return error.CodeGenFailed;
    const lhs = operation.getOperand(0) orelse return error.CodeGenFailed;
    const rhs = operation.getOperand(1) orelse return error.CodeGenFailed;
    const scalar = emission.types.scalarKindForType(lhs.type) orelse
        return error.CodeGenFailed;
    try arithmetic.opcode.requireNoSubwordArithmetic(scalar);
    try writer.writeValue(lhs);
    try writer.writeValue(rhs);
    try writer.out.writeByte(try arithmetic.opcode.comparison(predicate, scalar));
    try writer.writeLocalSet(try writer.localFor(cmp.getResult()));
}

pub fn writeSelect(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    const condition = operation.getOperand(0) orelse return error.CodeGenFailed;
    const when_true = operation.getOperand(1) orelse return error.CodeGenFailed;
    const when_false = operation.getOperand(2) orelse return error.CodeGenFailed;
    const result = operation.getResult(0) orelse return error.CodeGenFailed;
    try writer.writeValue(when_true);
    try writer.writeValue(when_false);
    try writer.writeValue(condition);
    try writer.out.writeByte(0x1b);
    try writer.writeLocalSet(try writer.localFor(result));
}

pub fn writeNeg(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    try writeUnary(Out, writer, operation, .neg);
}

pub fn writeAbs(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    try writeUnary(Out, writer, operation, .abs);
}

pub fn writeSqrt(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    try writeUnary(Out, writer, operation, .sqrt);
}

fn writeUnary(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
    kind: UnaryKind,
) emission.Error!void {
    const operand = operation.getOperand(0) orelse return error.CodeGenFailed;
    const result = operation.getResult(0) orelse return error.CodeGenFailed;
    const scalar = emission.types.scalarKindForType(result.type) orelse
        return error.CodeGenFailed;
    try arithmetic.opcode.requireNoSubwordArithmetic(scalar);
    switch (kind) {
        .neg => switch (scalar) {
            .i32, .u32, .index, .bool => {
                try writer.out.writeByte(0x41);
                try wasm.binary.writeSleb(writer.out, 0);
                try writer.writeValue(operand);
                try writer.out.writeByte(0x6b);
            },
            .i64, .u64 => {
                try writer.out.writeByte(0x42);
                try wasm.binary.writeSleb(writer.out, 0);
                try writer.writeValue(operand);
                try writer.out.writeByte(0x7d);
            },
            .f32 => {
                try writer.writeValue(operand);
                try writer.out.writeByte(0x8c);
            },
            .f64 => {
                try writer.writeValue(operand);
                try writer.out.writeByte(0x9a);
            },
            else => return error.CodeGenFailed,
        },
        .abs => {
            try writer.writeValue(operand);
            try writer.out.writeByte(switch (scalar) {
                .f32 => 0x8b,
                .f64 => 0x99,
                else => return error.CodeGenFailed,
            });
        },
        .sqrt => {
            try writer.writeValue(operand);
            try writer.out.writeByte(switch (scalar) {
                .f32 => 0x91,
                .f64 => 0x9f,
                else => return error.CodeGenFailed,
            });
        },
    }
    try writer.writeLocalSet(try writer.localFor(result));
}
