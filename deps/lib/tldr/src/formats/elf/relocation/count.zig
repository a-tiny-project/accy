const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const relocation_model = @import("model.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const format = elf.format;
const output_section = elf.output_section;
const rela_size = format.rela_size;
const SectionHeader = format.SectionHeader;
const ObjectParseOptions = relocation_model.ObjectParseOptions;
const RelocationCounts = relocation_model.RelocationCounts;
const SectionMetadata = relocation_model.SectionMetadata;
const sectionBytes = format.sectionBytes;
const stringFromTable = format.stringFromTable;
const readU64 = format.readU64;
const debugOutputIndexForName = output_section.debugOutputIndexForName;

fn sectionNameFromTableOrEmpty(section_names: []const u8, section: SectionHeader) []const u8 {
    return stringFromTable(section_names, section.name_offset) catch "";
}

pub fn scanSectionMetadata(sections: []const SectionHeader) SectionMetadata {
    var metadata = SectionMetadata{};
    for (sections, 0..) |section, index| {
        if (metadata.symtab_index == null and section.section_type == std.elf.SHT_SYMTAB) metadata.symtab_index = index;
        if (section.section_type == std.elf.SHT_GROUP) metadata.has_group_sections = true;
        if (section.section_type == std.elf.SHT_REL or section.section_type == std.elf.SHT_RELA) {
            metadata.has_relocation_sections = true;
        }
    }
    return metadata;
}

pub fn countRelocationsBySection(
    allocator: Allocator,
    bytes: []const u8,
    sections: []const SectionHeader,
    section_names: []const u8,
    symtab_index: ?usize,
    parse_options: ObjectParseOptions,
) model.Error!RelocationCounts {
    if (symtab_index == null) return error.MissingSymbolTable;

    const relocation_counts = try allocator.alloc(usize, sections.len);
    errdefer allocator.free(relocation_counts);
    @memset(relocation_counts, 0);

    var duplicate_targets = false;
    for (sections) |section| {
        if (section.section_type == std.elf.SHT_REL or section.section_type == std.elf.SHT_RELA) {
            if (try relocationSectionSkipped(section, sections, section_names, parse_options)) continue;
        }
        if (section.section_type == std.elf.SHT_REL) return error.UnsupportedRelocation;
        if (section.section_type != std.elf.SHT_RELA) continue;
        if (section.entry_size != rela_size or section.size % rela_size != 0) return error.InvalidObject;
        if (section.info >= sections.len) return error.MissingSection;

        const rela_bytes = try sectionBytes(bytes, section);
        const rela_count = rela_bytes.len / rela_size;
        const effective_count = if (relocationSectionAllNone(rela_bytes)) 0 else rela_count;
        if (relocation_counts[section.info] != 0 and effective_count != 0) duplicate_targets = true;
        if (effective_count > std.math.maxInt(usize) - relocation_counts[section.info]) return error.InvalidObject;
        relocation_counts[section.info] += effective_count;
    }

    return .{
        .counts = relocation_counts,
        .duplicate_targets = duplicate_targets,
    };
}

pub fn relocationSectionSkipped(
    section: SectionHeader,
    sections: []const SectionHeader,
    section_names: []const u8,
    parse_options: ObjectParseOptions,
) model.Error!bool {
    if (!parse_options.strip_debug) return false;
    if (section.info >= sections.len) return error.MissingSection;
    return debugOutputIndexForName(sectionNameFromTableOrEmpty(section_names, sections[section.info])) != null;
}

pub fn relocationSectionAllNone(rela_bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < rela_bytes.len) : (offset += rela_size) {
        if (@as(u32, @truncate(readU64(rela_bytes, offset + 8))) != @backingInt(std.elf.R_X86_64.NONE)) return false;
    }
    return true;
}
