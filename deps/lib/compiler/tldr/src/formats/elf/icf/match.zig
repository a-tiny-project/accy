const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const Rela = elf.format.Rela;
const Symbol = elf.format.Symbol;
const sectionBytes = elf.format.sectionBytes;

pub fn sections(
    left_object: ObjectFile,
    left_index: usize,
    right_object: ObjectFile,
    right_index: usize,
) model.Error!bool {
    const left = left_object.sections[left_index];
    const right = right_object.sections[right_index];
    if (left.section_type != right.section_type) return false;
    if (left.flags != right.flags) return false;
    if (@max(left.alignment, 1) != @max(right.alignment, 1)) return false;
    if (left.size != right.size) return false;

    const left_bytes = try sectionBytes(left_object.bytes, left);
    const right_bytes = try sectionBytes(right_object.bytes, right);
    if (!std.mem.eql(u8, left_bytes, right_bytes)) return false;

    return relocations(
        left_object,
        left_object.relocationsForSection(left_index),
        right_object,
        right_object.relocationsForSection(right_index),
    );
}

fn relocations(
    left_object: ObjectFile,
    left_relocations: []const Rela,
    right_object: ObjectFile,
    right_relocations: []const Rela,
) model.Error!bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (true) {
        const left = nextRelocation(left_relocations, &left_index);
        const right = nextRelocation(right_relocations, &right_index);
        if (left == null or right == null) return left == null and right == null;
        const left_relocation = left.?;
        const right_relocation = right.?;

        if (left_relocation.offset != right_relocation.offset) return false;
        if (left_relocation.relocationType() != right_relocation.relocationType()) return false;
        if (left_relocation.addend != right_relocation.addend) return false;
        if (left_relocation.symbolIndex() >= left_object.symbols.len) return error.UndefinedSymbol;
        if (right_relocation.symbolIndex() >= right_object.symbols.len) return error.UndefinedSymbol;
        if (!targets(
            left_object.symbols[@intCast(left_relocation.symbolIndex())],
            right_object.symbols[@intCast(right_relocation.symbolIndex())],
        )) return false;
    }
}

fn nextRelocation(relocations_input: []const Rela, index: *usize) ?Rela {
    while (index.* < relocations_input.len) {
        const entry = relocations_input[index.*];
        index.* += 1;
        if (!elf.relocation.isNone(entry)) return entry;
    }
    return null;
}

fn targets(left: Symbol, right: Symbol) bool {
    if (left.name.len == 0 or right.name.len == 0) return false;
    if (left.binding() == std.elf.STB_LOCAL or right.binding() == std.elf.STB_LOCAL) return false;
    if (left.kind() != right.kind()) return false;
    if (left.isUndefined() != right.isUndefined()) return false;
    if (left.isCommon() != right.isCommon()) return false;
    return std.mem.eql(u8, left.name, right.name);
}
