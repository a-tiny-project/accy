const std = @import("std");
const ir = @import("../../../../../core/root.zig");
const dialects = @import("../../../../../dialects/root.zig");
const emission = @import("../../root.zig");
const instruction = @import("root.zig");

const ScalarKind = dialects.arith.ScalarKind;

pub fn write(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
    bitcast: bool,
) emission.Error!void {
    const operand = operation.getOperand(0) orelse return error.CodeGenFailed;
    const result = operation.getResult(0) orelse return error.CodeGenFailed;
    const source = emission.types.scalarKindForType(operand.type) orelse
        return error.CodeGenFailed;
    const target = emission.types.scalarKindForType(result.type) orelse
        return error.CodeGenFailed;
    try writer.writeValue(operand);
    if (!scalarCastIsWasmNoop(source, target)) {
        const opcode = if (bitcast)
            try bitcastOpcode(source, target)
        else
            try castOpcode(source, target);
        try writer.out.writeByte(opcode);
    }
    try writer.writeLocalSet(try writer.localFor(result));
}

fn bitcastOpcode(source: ScalarKind, target: ScalarKind) error{CodeGenFailed}!u8 {
    return switch (source) {
        .i32, .u32, .index, .bool => switch (target) {
            .f32 => 0xbe,
            else => error.CodeGenFailed,
        },
        .i64, .u64 => switch (target) {
            .f64 => 0xbf,
            else => error.CodeGenFailed,
        },
        .f32 => switch (target) {
            .i32, .u32, .index => 0xbc,
            else => error.CodeGenFailed,
        },
        .f64 => switch (target) {
            .i64, .u64 => 0xbd,
            else => error.CodeGenFailed,
        },
        else => error.CodeGenFailed,
    };
}

fn castOpcode(source: ScalarKind, target: ScalarKind) error{CodeGenFailed}!u8 {
    return switch (source) {
        .i32, .index, .bool => switch (target) {
            .i64 => 0xac,
            .u64 => 0xad,
            .f32 => 0xb2,
            .f64 => 0xb7,
            else => error.CodeGenFailed,
        },
        .u32 => switch (target) {
            .i64, .u64 => 0xad,
            .f32 => 0xb3,
            .f64 => 0xb8,
            else => error.CodeGenFailed,
        },
        .i64 => switch (target) {
            .i32, .u32, .index => 0xa7,
            .f32 => 0xb4,
            .f64 => 0xb9,
            else => error.CodeGenFailed,
        },
        .u64 => switch (target) {
            .i32, .u32, .index => 0xa7,
            .f32 => 0xb5,
            .f64 => 0xba,
            else => error.CodeGenFailed,
        },
        .f32 => switch (target) {
            .f64 => 0xbb,
            else => error.CodeGenFailed,
        },
        .f64 => switch (target) {
            .f32 => 0xb6,
            else => error.CodeGenFailed,
        },
        else => error.CodeGenFailed,
    };
}

fn scalarCastIsWasmNoop(source: ScalarKind, target: ScalarKind) bool {
    if (source == target) return true;
    return switch (source) {
        .i32, .u32, .index, .bool => switch (target) {
            .i32, .u32, .index => true,
            else => false,
        },
        .i64, .u64 => switch (target) {
            .i64, .u64 => true,
            else => false,
        },
        else => false,
    };
}
