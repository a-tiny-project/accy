const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const Symbol = elf.format.Symbol;
const hashU64 = elf.format.hashU64;
const sectionBytes = elf.format.sectionBytes;

pub fn section(object: ObjectFile, section_index: usize) model.Error!u64 {
    const input_section = object.sections[section_index];
    var value: u64 = 0x9ae16a3b2f90404f;
    value = hashU64(value, input_section.section_type);
    value = hashU64(value, input_section.flags);
    value = hashU64(value, @max(input_section.alignment, 1));
    value = hashU64(value, input_section.size);
    value = std.hash.Wyhash.hash(value, try sectionBytes(object.bytes, input_section));
    for (object.relocationsForSection(section_index)) |entry| {
        if (elf.relocation.isNone(entry)) continue;
        value = hashU64(value, entry.offset);
        value = hashU64(value, entry.relocationType());
        value = hashU64(value, @as(u64, @bitCast(entry.addend)));
        if (entry.symbolIndex() >= object.symbols.len) return error.UndefinedSymbol;
        value = relocationTarget(value, object.symbols[@intCast(entry.symbolIndex())]);
    }
    return value;
}

fn relocationTarget(seed: u64, symbol: Symbol) u64 {
    var value = seed;
    value = hashU64(value, symbol.binding());
    value = hashU64(value, symbol.kind());
    value = hashU64(value, symbol.section_index);
    return std.hash.Wyhash.hash(value, symbol.name);
}
