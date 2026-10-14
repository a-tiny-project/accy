const std = @import("std");
const record = @import("record.zig");

const Allocator = std.mem.Allocator;
const Symbol = record.Symbol;

pub const SectionRef = struct {
    object_index: usize,
    section_index: usize,
};

pub fn ensureDiscardedSections(allocator: Allocator, object: anytype) Allocator.Error![]bool {
    if (object.discarded_sections.len != 0) return object.discarded_sections;
    object.discarded_sections = try allocator.alloc(bool, object.sections.len);
    @memset(object.discarded_sections, false);
    return object.discarded_sections;
}

pub fn ensureFoldedSections(allocator: Allocator, object: anytype) Allocator.Error![]?SectionRef {
    if (object.folded_sections.len != 0) return object.folded_sections;
    object.folded_sections = try allocator.alloc(?SectionRef, object.sections.len);
    @memset(object.folded_sections, null);
    return object.folded_sections;
}

pub inline fn sectionDiscarded(object: anytype, section_index: usize) bool {
    if (section_index >= object.discarded_sections.len) return false;
    return object.discarded_sections[section_index];
}

pub inline fn foldedSection(object: anytype, section_index: usize) ?SectionRef {
    if (section_index >= object.folded_sections.len) return null;
    return object.folded_sections[section_index];
}

pub fn symbolSectionDiscarded(object: anytype, symbol: Symbol) bool {
    if (symbol.isUndefined() or symbol.isCommon() or symbol.isAbsolute()) return false;
    return sectionDiscarded(object, symbol.section_index);
}
