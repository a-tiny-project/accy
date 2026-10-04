//! Data-symbol attributes on x86_64 integer constants, and the symbols a `memref.global`
//! declares.
//!
//! A constant that carries them evaluates to the address of its read-only bytes, not to its
//! integer value. A `memref.global` marked `constant` is the same thing spelled as a
//! declaration, so both arrive here and both leave as a `machine.DataSymbol`.

const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const machine = @import("../root.zig").machine_code;
const memref = @import("../../dialects/memref.zig");
const encoding = @import("encoding.zig");
const shared = @import("../data.zig");

const names = machine.data_symbol_attr_names;
const ConstantOp = dialects.ArithDialect.ConstantOp;
const GlobalOp = memref.MemrefDialect.GlobalOp;

pub const Error = shared.Error;

/// The data symbol that a `memref.global` declares.
///
/// The three placements the dialect distinguishes are the three sections a symbol can land in,
/// and this is the only place that mapping is written. A zeroed global becomes a symbol with a
/// stated size and no bytes rather than an empty one.
pub const symbolOfGlobal = shared.symbolOfGlobal;

/// Adds the symbol of every `memref.global` in `module`'s body to `set`.
///
/// An object path calls this because a declaration is a linker interface: the symbol belongs in
/// `.symtab` whether or not code in this translation unit addresses it, and dropping an
/// unreferenced one is how a module ends up charging for storage nothing emits. The JIT keeps
/// the use-site rule instead, because a global no function names has no address any caller there
/// could obtain. Re-adding a symbol an emitter already recorded is safe: `symbolOfGlobal` is a
/// function of the declaration alone, so the two agree and `put` keeps the one entry.
pub fn appendModuleGlobals(
    allocator: std.mem.Allocator,
    set: *machine.DataSymbolSet,
    module: *ir.Operation,
) (std.mem.Allocator.Error || Error || machine.DataSymbolError)!void {
    const region = module.getRegion(0) orelse return;
    const block = region.getEntryBlock() orelse return;
    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        op_iter = op.next_op;
        if (!std.mem.eql(u8, op.name.name, GlobalOp.operation_name)) continue;
        try set.put(allocator, try symbolOfGlobal(.{ .op = op }));
    }
}

/// Loads the address of `symbol` into `result` through a 64-bit immediate a data relocation
/// fills, and records the symbol so the object or the JIT mapping carries it.
///
/// Both an `arith.constant` carrying data attributes and a `memref.get_global` reach a symbol
/// this way, so the instruction and the relocation that completes it are written once.
pub fn emitAddress(self: anytype, result: *ir.Value, symbol: machine.DataSymbol) !void {
    std.debug.assert(symbol.isValid());
    const slot = try self.slotFor(result);
    std.debug.assert(slot.width == 64);
    try self.data_symbols.put(self.allocator, symbol);
    const mov = encoding.movRegImm64(.rax, 0);
    const mov_offset = self.code.items.len;
    try self.emitEncoding(mov);
    try self.data_relocations.append(self.allocator, .{
        .offset = mov_offset + (mov.len - 8),
        .target = symbol.name,
    });
    try self.storeFrom(result, .rax);
}

/// Reports whether `op` carries any data-symbol attribute, well formed or not.
pub fn hasAttributes(op: *ir.Operation) bool {
    return op.getAttr(names.name) != null or
        op.getAttr(names.bytes) != null or
        op.getAttr(names.alignment) != null;
}

/// Returns the data symbol that `op` names, or `null` when `op` carries no data-symbol attribute.
/// Fails unless `op` is an `arith.constant` of type `arith.i64`, `arith.u64`, or `arith.index` with
/// a nonempty string name, nonempty string bytes, and an optional integer alignment that is a power
/// of two up to `machine.max_data_alignment`.
pub fn symbolOf(op: *ir.Operation) Error!?machine.DataSymbol {
    if (!hasAttributes(op)) return null;
    if (!isAddressConstant(op)) return error.InvalidDataSymbol;
    const name = op.getAttrAs(ir.Attribute.StringAttr, names.name) orelse
        return error.InvalidDataSymbol;
    const bytes = op.getAttrAs(ir.Attribute.StringAttr, names.bytes) orelse
        return error.InvalidDataSymbol;
    const symbol = machine.DataSymbol{
        .name = name.getValue(),
        .bytes = bytes.getValue(),
        .alignment = try alignmentOf(op),
    };
    if (!symbol.isValid()) return error.InvalidDataSymbol;
    return symbol;
}

fn alignmentOf(op: *ir.Operation) Error!usize {
    if (op.getAttr(names.alignment) == null) return 1;
    const attr = op.getAttrAs(ir.Attribute.IntegerAttr, names.alignment) orelse
        return error.InvalidDataSymbol;
    const value = attr.getValue();
    if (value < 1 or value > machine.max_data_alignment) return error.InvalidDataSymbol;
    return @intCast(value);
}

fn isAddressConstant(op: *ir.Operation) bool {
    if (!std.mem.eql(u8, op.name.name, ConstantOp.operation_name)) return false;
    if (op.results.items.len != 1) return false;
    const type_name = op.results.items[0].type.getDialectTypeName() orelse return false;
    return std.mem.eql(u8, type_name, "arith.i64") or
        std.mem.eql(u8, type_name, "arith.u64") or
        std.mem.eql(u8, type_name, "arith.index");
}

const Attributes = struct {
    name: ?[]const u8 = "table",
    bytes: ?[]const u8 = "\x01\x02\x03",
    alignment: ?i64 = null,
};

fn attach(ctx: *ir.Context, op: *ir.Operation, attributes: Attributes) !*ir.Operation {
    if (attributes.name) |value| try op.setAttr(names.name, try ctx.getStringAttr(value));
    if (attributes.bytes) |value| try op.setAttr(names.bytes, try ctx.getStringAttr(value));
    if (attributes.alignment) |value| {
        try op.setAttr(names.alignment, try ctx.getI64Attr(value));
    }
    return op;
}
