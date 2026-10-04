const std = @import("std");
const wasm = @import("../../../root.zig");
const ir = @import("../../../../../core/root.zig");
const dialects = @import("../../../../../dialects/root.zig");
const emission = @import("../../root.zig");
const instruction = @import("root.zig");

const MemrefDialect = dialects.MemrefDialect;

pub fn writeLoad(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    const load = MemrefDialect.LoadOp{ .op = operation };
    const layout = try memrefParams(load.getMemref().type);
    try writeAddress(Out, writer, load.getMemref(), load.getIndex(), layout);
    try writer.out.writeByte(try loadOpcode(layout.element_type_name));
    try wasm.binary.writeUleb(
        writer.out,
        alignmentPower(try elementByteSize(layout.element_type_name)),
    );
    try wasm.binary.writeUleb(writer.out, @as(u32, 0));
    try writer.writeLocalSet(try writer.localFor(load.getResult()));
}

pub fn writeStore(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    const store = MemrefDialect.StoreOp{ .op = operation };
    const layout = try memrefParams(store.getMemref().type);
    try writeAddress(Out, writer, store.getMemref(), store.getIndex(), layout);
    try writer.writeValue(store.getValue());
    try writer.out.writeByte(try storeOpcode(layout.element_type_name));
    try wasm.binary.writeUleb(
        writer.out,
        alignmentPower(try elementByteSize(layout.element_type_name)),
    );
    try wasm.binary.writeUleb(writer.out, @as(u32, 0));
}

fn writeAddress(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    memref: *ir.Value,
    index: *ir.Value,
    layout: MemrefDialect.MemrefParams,
) emission.Error!void {
    try requireMemoryAddressSpace(layout);
    const element_size = try elementByteSize(layout.element_type_name);
    try writer.writeValue(memref);
    try writer.writeValue(index);
    if (element_size != 1) {
        try writer.out.writeByte(0x41);
        try wasm.binary.writeSleb(writer.out, @intCast(element_size));
        try writer.out.writeByte(0x6c);
    }
    try writer.out.writeByte(0x6a);
}

fn memrefParams(memref_type: ir.Type) error{CodeGenFailed}!MemrefDialect.MemrefParams {
    const key = memref_type.getDialectParamKey() orelse return error.CodeGenFailed;
    return MemrefDialect.parseMemrefParams(key) orelse return error.CodeGenFailed;
}

fn requireMemoryAddressSpace(layout: MemrefDialect.MemrefParams) error{CodeGenFailed}!void {
    if (layout.addr_space != .host and layout.addr_space != .unified) {
        return error.CodeGenFailed;
    }
}

fn elementByteSize(element_type_name: []const u8) error{CodeGenFailed}!u32 {
    const kind = dialects.arith.scalarKindFromTypeName(element_type_name) orelse
        return error.CodeGenFailed;
    return switch (kind) {
        .i8, .u8 => 1,
        .i16, .u16, .f16, .bf16 => 2,
        .i32, .u32, .f32, .index, .bool => 4,
        .i64, .u64, .f64 => 8,
    };
}

fn alignmentPower(size: u32) u32 {
    return switch (size) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => 0,
    };
}

fn loadOpcode(element_type_name: []const u8) error{CodeGenFailed}!u8 {
    const kind = dialects.arith.scalarKindFromTypeName(element_type_name) orelse
        return error.CodeGenFailed;
    return switch (kind) {
        .i8 => 0x2c,
        .u8 => 0x2d,
        .i16 => 0x2e,
        .u16 => 0x2f,
        .i32, .u32, .index, .bool => 0x28,
        .i64, .u64 => 0x29,
        .f32 => 0x2a,
        .f64 => 0x2b,
        .f16, .bf16 => error.CodeGenFailed,
    };
}

fn storeOpcode(element_type_name: []const u8) error{CodeGenFailed}!u8 {
    const kind = dialects.arith.scalarKindFromTypeName(element_type_name) orelse
        return error.CodeGenFailed;
    return switch (kind) {
        .i8, .u8 => 0x3a,
        .i16, .u16 => 0x3b,
        .i32, .u32, .index, .bool => 0x36,
        .i64, .u64 => 0x37,
        .f32 => 0x38,
        .f64 => 0x39,
        .f16, .bf16 => error.CodeGenFailed,
    };
}

test "wasm memory opcodes preserve element width and signedness" {
    try std.testing.expectEqual(@as(u32, 1), try elementByteSize("arith.i8"));
    try std.testing.expectEqual(@as(u32, 2), try elementByteSize("arith.f16"));
    try std.testing.expectEqual(@as(u32, 4), try elementByteSize("arith.index"));
    try std.testing.expectEqual(@as(u32, 8), try elementByteSize("arith.f64"));
    try std.testing.expectEqual(@as(u8, 0x2c), try loadOpcode("arith.i8"));
    try std.testing.expectEqual(@as(u8, 0x2d), try loadOpcode("arith.u8"));
    try std.testing.expectEqual(@as(u8, 0x3a), try storeOpcode("arith.i8"));
    try std.testing.expectEqual(@as(u8, 0x3a), try storeOpcode("arith.u8"));
    try std.testing.expectEqual(@as(u32, 0), alignmentPower(1));
    try std.testing.expectEqual(@as(u32, 3), alignmentPower(8));
}

test "wasm memory accepts only host-visible address spaces" {
    const base = MemrefDialect.MemrefParams{
        .size = null,
        .element_type_name = "arith.i32",
        .addr_space = .host,
    };
    try requireMemoryAddressSpace(base);

    var unified = base;
    unified.addr_space = .unified;
    try requireMemoryAddressSpace(unified);

    var device = base;
    device.addr_space = .device;
    try std.testing.expectError(error.CodeGenFailed, requireMemoryAddressSpace(device));
}
