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
        .i8, .i16, .i32, .u8, .u16, .u32, .index => {
            const value = constant.getIntValue() orelse return error.CodeGenFailed;
            try writer.out.writeByte(0x41);
            try wasm.binary.writeSleb(writer.out, @intCast(value));
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
    try writer.writeValue(lhs);
    try writer.writeValue(rhs);
    try writer.out.writeByte(try arithmetic.opcode.binary(kind, scalar));
    try writer.writeLocalSet(try writer.localFor(result));
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
