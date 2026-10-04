const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const boundary = @import("boundary.zig");

const model = root.model;
const layout = elf.layout;
const section_state = elf.section_state;

const GlobalSymbol = layout.GlobalSymbol;
const ObjectFile = elf.parser.ObjectFile;
const SymbolRef = layout.SymbolRef;
const symbolSectionDiscarded = section_state.symbolSectionDiscarded;

pub fn symbol(
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    object_index: usize,
    symbol_index: usize,
) model.Error!u64 {
    if (symbol_index >= objects[object_index].symbols.len) return error.UndefinedSymbol;
    const symbol_record = objects[object_index].symbols[symbol_index];
    if (symbol_record.isUndefined()) {
        const global = globals.get(symbol_record.name) orelse {
            if (symbol_record.isWeakUndefined()) return 0;
            if (boundary.forSymbol(symbol_record.name) != null) return 0;
            return error.UndefinedSymbol;
        };
        return symbol(objects, globals, global.ref.object_index, global.ref.symbol_index);
    }
    if (symbolSectionDiscarded(objects[object_index], symbol_record) and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.MissingSection;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (global.ref.eql(current_ref)) return error.MissingSection;
        return symbol(objects, globals, global.ref.object_index, global.ref.symbol_index);
    }
    if (symbol_record.isCommon() and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.UndefinedSymbol;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (!global.ref.eql(current_ref)) return symbol(objects, globals, global.ref.object_index, global.ref.symbol_index);
    }
    return symbol_record.size;
}
