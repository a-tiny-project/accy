const std = @import("std");
const binary = @import("../binary/root.zig");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");

const MemrefDialect = dialects.MemrefDialect;

pub const Error = error{CodeGenFailed};

pub fn typeIsMemref(typ: ir.Type) bool {
    const type_name = typ.getDialectTypeName() orelse return false;
    return std.mem.eql(u8, type_name, MemrefDialect.name);
}

pub fn wasmTypeForType(typ: ir.Type) Error!binary.ValueType {
    if (typeIsMemref(typ)) return .i32;
    const scalar = scalarKindForType(typ) orelse return error.CodeGenFailed;
    return switch (scalar) {
        .i8, .i16, .i32, .u8, .u16, .u32, .index, .bool => .i32,
        .i64, .u64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        .f16, .bf16 => error.CodeGenFailed,
    };
}

pub fn scalarKindForType(typ: ir.Type) ?dialects.arith.ScalarKind {
    const type_name = typ.getDialectTypeName() orelse return null;
    return dialects.arith.scalarKindFromTypeName(type_name);
}
