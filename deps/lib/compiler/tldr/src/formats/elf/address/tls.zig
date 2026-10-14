const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const cache = @import("cache.zig");
const contribution_module = @import("contribution.zig");

const model = root.model;
const format = elf.format;
const layout = elf.layout;
const program = elf.program;
const section_state = elf.section_state;

const Cache = cache.Cache;
const GlobalSymbol = layout.GlobalSymbol;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const Symbol = format.Symbol;
const SymbolRef = layout.SymbolRef;
const symbolSectionDiscarded = section_state.symbolSectionDiscarded;
const tlsSegment = program.tlsSegment;

pub fn offset(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *Cache,
    object_index: usize,
    symbol_index: usize,
) model.Error!u64 {
    if (symbol_index >= objects[object_index].symbols.len) return error.UndefinedSymbol;

    const object = objects[object_index];
    const symbol_record = object.symbols[symbol_index];
    if (symbol_record.isUndefined()) {
        const global = globals.get(symbol_record.name) orelse {
            if (symbol_record.isWeakUndefined()) return 0;
            return error.UndefinedSymbol;
        };
        return offset(objects, layouts, output_sections, globals, symbol_addresses, global.ref.object_index, global.ref.symbol_index);
    }
    if (symbolSectionDiscarded(object, symbol_record) and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.MissingSection;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (global.ref.eql(current_ref)) return error.MissingSection;
        return offset(objects, layouts, output_sections, globals, symbol_addresses, global.ref.object_index, global.ref.symbol_index);
    }
    if (symbol_record.isCommon() and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.UndefinedSymbol;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (!global.ref.eql(current_ref)) return offset(objects, layouts, output_sections, globals, symbol_addresses, global.ref.object_index, global.ref.symbol_index);
    }
    if (symbol_record.isAbsolute() or symbol_record.isCommon()) return error.UnsupportedRelocation;
    if (!isSymbol(object, symbol_record)) return error.UnsupportedRelocation;

    const symbol_contribution = try contribution_module.symbol(objects, layouts, object_index, symbol_index);
    const output = output_sections[symbol_contribution.outputIndex()];
    if (!output.kind.isTls()) return error.UnsupportedRelocation;
    const segment = tlsSegment(output_sections) orelse return error.MissingSection;
    return output.address - segment.address + symbol_contribution.offset + symbol_record.value;
}

pub fn isSymbol(object: ObjectFile, symbol_record: Symbol) bool {
    if (symbol_record.kind() == std.elf.STT_TLS) return true;
    if (symbol_record.isUndefined() or symbol_record.isCommon() or symbol_record.isAbsolute()) return false;
    if (symbol_record.section_index >= object.sections.len) return false;
    return (object.sections[symbol_record.section_index].flags & std.elf.SHF_TLS) != 0;
}
