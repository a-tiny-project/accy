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

/// A global's address is the constant the data layout gives it. Loads and stores through it check
/// it as they check any address.
pub fn writeGlobalAddress(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    operation: *ir.Operation,
) emission.Error!void {
    const get = MemrefDialect.GetGlobalOp{ .op = operation };
    const name = get.getSymName() orelse return error.CodeGenFailed;
    const global = dialects.memref.findGlobal(operation, name) orelse return error.CodeGenFailed;
    try writer.out.writeByte(0x41); // i32.const
    try wasm.binary.writeSleb(writer.out, @as(i32, @bitCast(try emission.data.offset(global))));
    try writer.writeLocalSet(try writer.localFor(get.getResult()));
}

/// The memory32 address of element `index` past `memref`, checked before any access. Let b be the
/// base read as u32, i the index read at its declared width, E the element size and L = 2^32. The
/// access must satisfy 0 <= i, b <= L - E and i <= (L - E - b) / E, which proves b + i*E + E <= L
/// in i64, so the address is formed only after that and then wrapped to i32. A failed check stops
/// before the load or the store.
fn writeAddress(
    comptime Out: type,
    writer: *instruction.Writer(Out),
    memref: *ir.Value,
    index: *ir.Value,
    layout: MemrefDialect.MemrefParams,
) emission.Error!void {
    try requireMemoryAddressSpace(layout);
    const element_size = try elementByteSize(layout.element_type_name);
    const shift = try scaleShift(element_size);
    const kind = emission.types.scalarKindForType(index.type) orelse
        return error.UnsupportedOperation;
    const signed = switch (kind) {
        .i8, .i16, .i32, .i64 => true,
        .u8, .u16, .u32, .u64, .index, .bool => false,
        else => return error.UnsupportedOperation,
    };
    const limit: i64 = (1 << 32) - @as(i64, element_size);
    const operands: Operands(Out) = .{ .writer = writer, .memref = memref, .index = index };
    if (signed) {
        try operands.writeIndex();
        try writeWord(Out, writer, 0);
        try writer.out.writeByte(0x53); // i64.lt_s
    }
    try operands.writeBase();
    try writeWord(Out, writer, limit);
    try writer.out.writeByte(0x56); // i64.gt_u
    if (signed) try writer.out.writeByte(0x72); // i32.or
    try operands.writeIndex();
    try writeWord(Out, writer, limit);
    try operands.writeBase();
    try writer.out.writeByte(0x7d); // i64.sub
    if (shift != 0) {
        try writeWord(Out, writer, shift);
        try writer.out.writeByte(0x88); // i64.shr_u
    }
    try writer.out.writeByte(0x56); // i64.gt_u
    try writer.out.writeByte(0x72); // i32.or
    try writer.out.writeAll(&.{ 0x04, 0x40, 0x00, 0x0b }); // if (failed) { unreachable }
    try operands.writeBase();
    try operands.writeIndex();
    if (shift != 0) {
        try writeWord(Out, writer, shift);
        try writer.out.writeByte(0x86); // i64.shl
    }
    try writer.out.writeByte(0x7c); // i64.add
    try writer.out.writeByte(0xa7); // i32.wrap_i64
}

fn Operands(comptime Out: type) type {
    return struct {
        writer: *instruction.Writer(Out),
        memref: *ir.Value,
        index: *ir.Value,

        /// The base pointer, an unsigned 32-bit address, zero-extended.
        fn writeBase(self: @This()) emission.Error!void {
            try self.writer.writeValue(self.memref);
            try self.writer.out.writeByte(0xad); // i64.extend_i32_u
        }

        /// The index at its declared width, extended by its sign.
        fn writeIndex(self: @This()) emission.Error!void {
            try self.writer.writeValue(self.index);
            const kind = emission.types.scalarKindForType(self.index.type).?;
            switch (kind) {
                .i64, .u64 => {},
                else => {
                    try instruction.call.writeReceived(self.writer.out, self.index.type);
                    const signed = kind == .i8 or kind == .i16 or kind == .i32;
                    try self.writer.out.writeByte(if (signed) 0xac else 0xad);
                },
            }
        }
    };
}

/// log2 of an element size the address check can scale by a shift. Any other size is refused.
fn scaleShift(size: u32) error{UnsupportedOperation}!u8 {
    return switch (size) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => error.UnsupportedOperation,
    };
}

fn writeWord(comptime Out: type, writer: *instruction.Writer(Out), value: i64) emission.Error!void {
    try writer.out.writeByte(0x42); // i64.const
    try wasm.binary.writeSleb(writer.out, value);
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
