const std = @import("std");
const root = @import("../../root.zig");
const format = @import("format.zig");
const elf_object = @import("object/root.zig");
const relocation = @import("relocation/root.zig");
const section_state = @import("sections.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const trace = root.trace;

const ehdr_size = format.ehdr_size;
const shdr_size = format.shdr_size;
const sym_size = format.sym_size;
const native_endian = format.native_endian;
const SectionHeader = format.SectionHeader;
const Symbol = format.Symbol;
const Rela = format.Rela;
const symbolBindingIsExternalDefinition = format.symbolBindingIsExternalDefinition;
const sectionBytes = format.sectionBytes;
const requireRange = format.requireRange;
const stringFromTable = format.stringFromTable;
const decodeSectionHeaders = format.decodeSectionHeaders;
const readSymbol = format.readSymbol;
const readU16 = format.readU16;
const readU64 = format.readU64;
pub const RelocationRange = relocation.RelocationRange;
pub const ObjectParseOptions = relocation.ObjectParseOptions;
const RelocationCounts = relocation.RelocationCounts;
const scanSectionMetadata = relocation.scanSectionMetadata;
const countRelocationsBySection = relocation.countRelocationsBySection;
const parseRelocationsBySection = relocation.parseRelocationsBySection;

pub const SectionRef = section_state.SectionRef;

pub const ObjectFile = struct {
    name: []const u8,
    input_index: usize = 0,
    bytes: []const u8,
    sections: []SectionHeader,
    section_names: []const u8,
    section_name_ends: []u32,
    symbols: []Symbol,
    relocations: []const Rela,
    relocations_owned: bool,
    has_common_symbols: bool,
    has_named_strong_undefined_symbols: bool,
    has_ifunc_definitions: bool,
    has_group_sections: bool,
    relocation_ranges: []RelocationRange,
    discarded_sections: []bool = &.{},
    folded_sections: []?SectionRef = &.{},

    pub fn deinit(self: *ObjectFile, allocator: Allocator) void {
        allocator.free(self.sections);
        allocator.free(self.section_name_ends);
        allocator.free(self.symbols);
        if (self.relocations_owned and self.relocations.len != 0) allocator.free(@constCast(self.relocations));
        if (self.relocation_ranges.len != 0) allocator.free(self.relocation_ranges);
        if (self.discarded_sections.len != 0) allocator.free(self.discarded_sections);
        if (self.folded_sections.len != 0) allocator.free(self.folded_sections);
    }

    pub fn relocationsForSection(self: ObjectFile, section_index: usize) []const Rela {
        if (self.relocation_ranges.len == 0) return &.{};
        const range = self.relocation_ranges[section_index];
        return self.relocations[range.start..][0..range.count];
    }
};

pub const ObjectSelectionSummary = struct {
    name: []const u8,
    bytes: []const u8,
    sections: []SectionHeader,
    section_names: []const u8,
    symbols: []Symbol,
    has_common_symbols: bool,
    has_named_strong_undefined_symbols: bool,
    has_ifunc_definitions: bool,
    has_group_sections: bool,
    symtab_index: ?usize,

    pub fn deinit(self: *ObjectSelectionSummary, allocator: Allocator) void {
        allocator.free(self.sections);
        allocator.free(self.symbols);
        self.* = undefined;
    }
};

pub fn sectionName(object: ObjectFile, section_index: usize) model.Error![]const u8 {
    if (section_index >= object.sections.len) return error.MissingSection;
    const name_end = object.section_name_ends[section_index];
    if (name_end == invalid_section_name_end) return error.InvalidStringTable;
    return object.section_names[object.sections[section_index].name_offset..name_end];
}

const invalid_section_name_end = std.math.maxInt(u32);

fn resolveSectionNameEnds(
    allocator: Allocator,
    sections: []const SectionHeader,
    section_names: []const u8,
) Allocator.Error![]u32 {
    const name_ends = try allocator.alloc(u32, sections.len);
    errdefer allocator.free(name_ends);
    for (sections, name_ends) |section, *name_end| {
        if (section.name_offset >= section_names.len) {
            name_end.* = invalid_section_name_end;
            continue;
        }
        const terminator = std.mem.indexOfScalarPos(u8, section_names, section.name_offset, 0) orelse {
            name_end.* = invalid_section_name_end;
            continue;
        };
        name_end.* = @intCast(terminator);
    }
    return name_ends;
}

pub fn sectionNameOrEmpty(object: ObjectFile, section_index: usize) []const u8 {
    return sectionName(object, section_index) catch "";
}

pub fn sectionNameFromTableOrEmpty(section_names: []const u8, section: SectionHeader) []const u8 {
    return stringFromTable(section_names, section.name_offset) catch "";
}

pub fn parseObjectMetadata(allocator: Allocator, input: model.Input) model.Error!root.Object {
    var object = try parseObject(allocator, input);
    defer object.deinit(allocator);

    const sections = try allocator.alloc(root.ObjectSection, object.sections.len);
    errdefer allocator.free(sections);
    for (sections, 0..) |*section, index| {
        const source = object.sections[index];
        section.* = .{
            .name = sectionNameOrEmpty(object, index),
            .address = source.address,
            .size = source.size,
            .offset = source.offset,
            .alignment = source.alignment,
            .flags = source.flags,
            .section_type = source.section_type,
            .relocation_count = @intCast(object.relocationsForSection(index).len),
        };
    }

    const symbols = try allocator.alloc(root.ObjectSymbol, object.symbols.len);
    errdefer allocator.free(symbols);
    for (symbols, 0..) |*symbol, index| {
        const source = object.symbols[index];
        symbol.* = .{
            .name = source.name,
            .section_index = source.section_index,
            .value = source.value,
            .size = source.size,
            .kind = source.kind(),
            .binding = source.binding(),
            .external = symbolBindingIsExternalDefinition(source.binding()),
            .undefined = source.isUndefined(),
        };
    }

    return .{
        .target = .linux_x86_64_elf,
        .sections = sections,
        .symbols = symbols,
    };
}

pub fn parseObject(allocator: Allocator, input: model.Input) model.Error!ObjectFile {
    return parseObjectWithOptions(allocator, input, .{});
}

pub fn parseObjectSelectionSummary(allocator: Allocator, input: model.Input) model.Error!ObjectSelectionSummary {
    const phase = trace.product(.input_discovery);
    defer phase.end();
    const bytes = input.bytes;
    if (bytes.len < ehdr_size) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return error.InvalidElfHeader;
    if (bytes[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return error.UnsupportedFormat;
    if (bytes[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return error.UnsupportedFormat;
    if (readU16(bytes, 16) != @backingInt(std.elf.ET.REL)) return error.UnsupportedOutputKind;
    if (readU16(bytes, 18) != @backingInt(std.elf.EM.X86_64)) return error.UnsupportedArchitecture;

    const shoff = readU64(bytes, 40);
    const shentsize = readU16(bytes, 58);
    const shnum = readU16(bytes, 60);
    const shstrndx = readU16(bytes, 62);
    if (shentsize != shdr_size or shnum == 0 or shstrndx >= shnum) return error.InvalidElfHeader;
    try requireRange(bytes, shoff, @as(u64, shnum) * shdr_size);

    const sections = try allocator.alloc(SectionHeader, shnum);
    errdefer allocator.free(sections);
    decodeSectionHeaders(bytes, shoff, sections);

    const shstrtab = try sectionBytes(bytes, sections[shstrndx]);
    const section_metadata = scanSectionMetadata(sections);

    var has_common_symbols = false;
    var has_named_strong_undefined_symbols = false;
    var has_ifunc_definitions = false;
    const symbols = if (section_metadata.symtab_index) |index| blk: {
        const symtab = sections[index];
        if (symtab.entry_size != sym_size or symtab.size % sym_size != 0) return error.InvalidObject;
        if (symtab.link >= sections.len) return error.MissingStringTable;
        const strtab = try sectionBytes(bytes, sections[symtab.link]);
        const symtab_bytes = try sectionBytes(bytes, symtab);
        const symbol_count = symtab_bytes.len / sym_size;
        if (symbol_count != 0 and (strtab.len == 0 or strtab[0] != 0)) return error.InvalidStringTable;

        const parsed_symbols = try allocator.alloc(Symbol, symbol_count);
        errdefer allocator.free(parsed_symbols);
        for (parsed_symbols, 0..) |*symbol, symbol_index| {
            symbol.* = readSymbol(symtab_bytes[symbol_index * sym_size ..][0..sym_size]);
            symbol.name = if (symbol.name_offset == 0) "" else try stringFromTable(strtab, symbol.name_offset);
            if (symbol.isCommon()) has_common_symbols = true;
            if (symbol.kind() == std.elf.STT_GNU_IFUNC and !symbol.isUndefined()) has_ifunc_definitions = true;
            if (symbol.isUndefined() and symbol.name.len != 0 and !symbol.isWeakUndefined()) {
                has_named_strong_undefined_symbols = true;
            }
        }
        break :blk parsed_symbols;
    } else try allocator.alloc(Symbol, 0);
    errdefer allocator.free(symbols);

    return .{
        .name = input.name,
        .bytes = bytes,
        .sections = sections,
        .section_names = shstrtab,
        .symbols = symbols,
        .has_common_symbols = has_common_symbols,
        .has_named_strong_undefined_symbols = has_named_strong_undefined_symbols,
        .has_ifunc_definitions = has_ifunc_definitions,
        .has_group_sections = section_metadata.has_group_sections,
        .symtab_index = section_metadata.symtab_index,
    };
}

pub fn parseObjectWithSelectionSummary(
    allocator: Allocator,
    summary: ObjectSelectionSummary,
    parse_options: ObjectParseOptions,
) model.Error!ObjectFile {
    const phase = trace.product(.input_discovery);
    defer phase.end();
    var relocation_counts: RelocationCounts = .{};
    defer relocation_counts.deinit(allocator);
    const section_metadata = scanSectionMetadata(summary.sections);
    if (section_metadata.has_relocation_sections) {
        relocation_counts = try countRelocationsBySection(
            allocator,
            summary.bytes,
            summary.sections,
            summary.section_names,
            summary.symtab_index,
            parse_options,
        );
    }

    const relocation_data = try parseRelocationsBySection(
        allocator,
        summary.bytes,
        summary.sections,
        summary.section_names,
        relocation_counts,
        parse_options,
    );
    errdefer relocation_data.deinit(allocator);

    const section_name_ends = try resolveSectionNameEnds(allocator, summary.sections, summary.section_names);
    errdefer allocator.free(section_name_ends);

    return .{
        .name = summary.name,
        .bytes = summary.bytes,
        .sections = summary.sections,
        .section_names = summary.section_names,
        .section_name_ends = section_name_ends,
        .symbols = summary.symbols,
        .relocations = relocation_data.relocations,
        .relocations_owned = relocation_data.owned,
        .has_common_symbols = summary.has_common_symbols,
        .has_named_strong_undefined_symbols = summary.has_named_strong_undefined_symbols,
        .has_ifunc_definitions = summary.has_ifunc_definitions,
        .has_group_sections = summary.has_group_sections,
        .relocation_ranges = relocation_data.ranges,
    };
}

pub fn parseObjectWithOptions(allocator: Allocator, input: model.Input, parse_options: ObjectParseOptions) model.Error!ObjectFile {
    const phase = trace.product(.input_discovery);
    defer phase.end();
    const bytes = input.bytes;
    if (bytes.len < ehdr_size) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return error.InvalidElfHeader;
    if (bytes[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return error.UnsupportedFormat;
    if (bytes[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return error.UnsupportedFormat;
    if (readU16(bytes, 16) != @backingInt(std.elf.ET.REL)) return error.UnsupportedOutputKind;
    if (readU16(bytes, 18) != @backingInt(std.elf.EM.X86_64)) return error.UnsupportedArchitecture;

    const shoff = readU64(bytes, 40);
    const shentsize = readU16(bytes, 58);
    const shnum = readU16(bytes, 60);
    const shstrndx = readU16(bytes, 62);
    if (shentsize != shdr_size or shnum == 0 or shstrndx >= shnum) return error.InvalidElfHeader;
    try requireRange(bytes, shoff, @as(u64, shnum) * shdr_size);

    const sections = try allocator.alloc(SectionHeader, shnum);
    errdefer allocator.free(sections);
    decodeSectionHeaders(bytes, shoff, sections);

    const shstrtab = try sectionBytes(bytes, sections[shstrndx]);

    const section_metadata = scanSectionMetadata(sections);
    const symtab_index = section_metadata.symtab_index;
    var has_common_symbols = false;
    var has_named_strong_undefined_symbols = false;
    var has_ifunc_definitions = false;
    const symbols = if (symtab_index) |index| blk: {
        const symtab = sections[index];
        if (symtab.entry_size != sym_size or symtab.size % sym_size != 0) return error.InvalidObject;
        if (symtab.link >= sections.len) return error.MissingStringTable;
        const strtab = try sectionBytes(bytes, sections[symtab.link]);
        const symtab_bytes = try sectionBytes(bytes, symtab);
        const symbol_count = symtab_bytes.len / sym_size;
        if (symbol_count != 0 and (strtab.len == 0 or strtab[0] != 0)) return error.InvalidStringTable;

        const parsed_symbols = try allocator.alloc(Symbol, symbol_count);
        errdefer allocator.free(parsed_symbols);
        for (parsed_symbols, 0..) |*symbol, symbol_index| {
            symbol.* = readSymbol(symtab_bytes[symbol_index * sym_size ..][0..sym_size]);
            symbol.name = if (symbol.name_offset == 0) "" else try stringFromTable(strtab, symbol.name_offset);
            if (symbol.isCommon()) has_common_symbols = true;
            if (symbol.kind() == std.elf.STT_GNU_IFUNC and !symbol.isUndefined()) has_ifunc_definitions = true;
            if (symbol.isUndefined() and symbol.name.len != 0 and !symbol.isWeakUndefined()) {
                has_named_strong_undefined_symbols = true;
            }
        }
        break :blk parsed_symbols;
    } else try allocator.alloc(Symbol, 0);
    errdefer allocator.free(symbols);

    var relocation_counts: RelocationCounts = .{};
    defer relocation_counts.deinit(allocator);
    if (section_metadata.has_relocation_sections) {
        relocation_counts = try countRelocationsBySection(allocator, bytes, sections, shstrtab, symtab_index, parse_options);
    }

    const relocation_data = try parseRelocationsBySection(allocator, bytes, sections, shstrtab, relocation_counts, parse_options);
    errdefer relocation_data.deinit(allocator);

    const section_name_ends = try resolveSectionNameEnds(allocator, sections, shstrtab);
    errdefer allocator.free(section_name_ends);

    return .{
        .name = input.name,
        .bytes = bytes,
        .sections = sections,
        .section_names = shstrtab,
        .section_name_ends = section_name_ends,
        .symbols = symbols,
        .relocations = relocation_data.relocations,
        .relocations_owned = relocation_data.owned,
        .has_common_symbols = has_common_symbols,
        .has_named_strong_undefined_symbols = has_named_strong_undefined_symbols,
        .has_ifunc_definitions = has_ifunc_definitions,
        .has_group_sections = section_metadata.has_group_sections,
        .relocation_ranges = relocation_data.ranges,
    };
}
