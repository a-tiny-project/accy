const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const layout = elf.layout;
const merge = elf.merge;
const section_state = elf.section_state;

const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const SectionContribution = layout.SectionContribution;
const contributionAt = layout.contributionAt;
const foldedSection = section_state.foldedSection;

pub fn symbol(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    object_index: usize,
    symbol_index: usize,
) model.Error!SectionContribution {
    const object = objects[object_index];
    const object_layout = layouts[object_index];
    if (symbol_index >= object.symbols.len) return error.UndefinedSymbol;
    const symbol_record = object.symbols[symbol_index];
    if (symbol_record.isCommon()) {
        if (symbol_index >= object_layout.common_symbols.len) return error.UnsupportedRelocation;
        return (contributionAt(object_layout.common_symbols, symbol_index) orelse return error.MissingSection).*;
    }
    if (symbol_record.section_index >= object.sections.len) return error.UnsupportedRelocation;
    if (merge.contribution(object_layout, object, symbol_record.section_index, symbol_record.value)) |symbol_contribution| {
        return symbol_contribution;
    }
    if (foldedSection(object, symbol_record.section_index)) |canonical| {
        return (contributionAt(layouts[canonical.object_index].sections, canonical.section_index) orelse return error.MissingSection).*;
    }
    return (contributionAt(object_layout.sections, symbol_record.section_index) orelse return error.MissingSection).*;
}
