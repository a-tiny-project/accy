const std = @import("std");
const wasm = @import("../../root.zig");
pub const ir = @import("../../../../core/root.zig");
const dialects = @import("../../../../dialects/root.zig");
const emission = @import("../root.zig");

pub const BuiltinDialect = dialects.BuiltinDialect;
pub const FuncDialect = dialects.FuncDialect;

pub fn moduleOperation(module: *ir.Operation) emission.Error!BuiltinDialect.ModuleOp {
    if (!std.mem.eql(u8, module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
        return error.CodeGenFailed;
    }
    return .{ .op = module };
}

pub fn functionOperation(operation: *ir.Operation) emission.Error!FuncDialect.FuncOp {
    if (!std.mem.eql(u8, operation.name.name, FuncDialect.FuncOp.operation_name)) {
        return error.CodeGenFailed;
    }
    return .{ .op = operation };
}

pub fn writeTypeVector(out: anytype, types: []const ir.Type) emission.Error!void {
    _ = try requireU32(types.len);
    try wasm.binary.writeUleb(out, types.len);
    for (types) |typ| {
        try wasm.binary.writeValueType(out, try emission.types.wasmTypeForType(typ));
    }
}

pub fn writeSectionHeader(
    out: anytype,
    section: wasm.binary.Section,
    body_bytes: usize,
) emission.Error!void {
    _ = try requireU32(body_bytes);
    try wasm.binary.writeSectionHeader(out, section, body_bytes);
}

pub fn writeName(out: anytype, name: []const u8) emission.Error!void {
    _ = try requireU32(name.len);
    try wasm.binary.writeName(out, name);
}

pub fn requireU32(value: usize) emission.Error!usize {
    if (value > std.math.maxInt(u32)) return error.CapacityOverflow;
    return value;
}
