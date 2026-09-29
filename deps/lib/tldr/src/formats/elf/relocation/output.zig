const std = @import("std");
const elf = @import("../root.zig");

const format = elf.format;
const output_section = elf.output_section;
const parser = elf.parser;

const ObjectFile = parser.ObjectFile;
const debugOutputIndexForName = output_section.debugOutputIndexForName;
const sectionIsAllocated = format.sectionIsAllocated;
const sectionNameOrEmpty = parser.sectionNameOrEmpty;

pub fn sectionRelocationsAffectOutput(object: ObjectFile, section_index: usize) bool {
    if (section_index >= object.sections.len) return false;
    const section = object.sections[section_index];
    if (sectionIsAllocated(section)) return true;
    if (section.section_type != std.elf.SHT_PROGBITS) return false;
    return debugOutputIndexForName(sectionNameOrEmpty(object, section_index)) != null;
}
