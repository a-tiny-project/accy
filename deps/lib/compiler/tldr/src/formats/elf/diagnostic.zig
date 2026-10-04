const root = @import("../../root.zig");
const format = @import("format.zig");
const parser = @import("parser.zig");

const model = root.model;
const ObjectFile = parser.ObjectFile;
const Rela = format.Rela;
const Symbol = format.Symbol;

pub fn recordUndefinedSymbol(
    options: model.LinkOptions,
    object: ObjectFile,
    symbol: Symbol,
) void {
    if (options.diagnostics) |diagnostics| {
        diagnostics.recordUndefinedSymbol(object.name, symbol.name);
    }
}

pub fn recordUnsupportedRelocation(
    options: model.LinkOptions,
    object: ObjectFile,
    section_index: usize,
    relocation: Rela,
) void {
    if (options.diagnostics) |diagnostics| {
        const section_name = if (section_index < object.sections.len)
            parser.sectionNameOrEmpty(object, section_index)
        else
            "";
        const symbol_name = if (relocation.symbolIndex() < object.symbols.len)
            object.symbols[@intCast(relocation.symbolIndex())].name
        else
            "";
        diagnostics.recordUnsupportedRelocation(
            object.name,
            section_name,
            symbol_name,
            relocation.relocationType(),
        );
    }
}
