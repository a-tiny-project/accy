const std = @import("std");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const ObjectFile = elf.parser.ObjectFile;
const MergeSectionLayout = elf.layout.MergeSectionLayout;
const SectionHeader = elf.format.SectionHeader;

pub fn ensure(
    allocator: Allocator,
    object: ObjectFile,
    merge_sections: *[]MergeSectionLayout,
) Allocator.Error![]MergeSectionLayout {
    if (merge_sections.*.len != 0) return merge_sections.*;
    const sections = try allocator.alloc(MergeSectionLayout, object.sections.len);
    @memset(sections, .{});
    merge_sections.* = sections;
    return sections;
}

pub fn fixed(section: SectionHeader) bool {
    if ((section.flags & std.elf.SHF_ALLOC) == 0) return false;
    if ((section.flags & std.elf.SHF_MERGE) == 0) return false;
    if ((section.flags & std.elf.SHF_STRINGS) != 0) return false;
    if (section.section_type != std.elf.SHT_PROGBITS) return false;
    if (section.entry_size == 0) return false;
    return true;
}

pub fn string(section: SectionHeader) bool {
    if ((section.flags & std.elf.SHF_ALLOC) == 0) return false;
    if ((section.flags & std.elf.SHF_MERGE) == 0) return false;
    if ((section.flags & std.elf.SHF_STRINGS) == 0) return false;
    if (section.section_type != std.elf.SHT_PROGBITS) return false;
    if (section.entry_size > 1) return false;
    if (section.alignment > 1) return false;
    return true;
}
