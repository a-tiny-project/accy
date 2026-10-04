const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const record = @import("record.zig");

const model = root.model;
const format = elf.format;
const layout = elf.layout;
const parser = elf.parser;
const output_section = elf.output_section;
const section_state = elf.section_state;
const ObjectFile = parser.ObjectFile;
const SectionHeader = format.SectionHeader;
const Rela = format.Rela;
const OutputSection = layout.OutputSection;
const SectionContribution = layout.SectionContribution;
const EhFrameCieLayout = layout.EhFrameCieLayout;
const GlobalSymbol = layout.GlobalSymbol;
const SymbolRef = layout.SymbolRef;
const output_section_count = output_section.output_section_count;
const readU32 = format.readU32;
const validateAlignment = format.validateAlignment;
const alignForwardU64 = format.alignForwardU64;
const contributionReserveSize = layout.contributionReserveSize;
const sectionDiscarded = section_state.sectionDiscarded;
const foldedSection = section_state.foldedSection;
const sectionNameOrEmpty = parser.sectionNameOrEmpty;
const sectionIsAllocated = format.sectionIsAllocated;

pub fn is(object: ObjectFile, section_index: usize, section: SectionHeader) bool {
    if (!sectionIsAllocated(section)) return false;
    if (section.section_type == std.elf.SHT_X86_64_UNWIND) return true;
    return std.mem.eql(u8, sectionNameOrEmpty(object, section_index), ".eh_frame");
}

pub fn walk(
    objects: []const ObjectFile,
    object_index: usize,
    bytes: []const u8,
    source_relocations: []const Rela,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    consumer: anytype,
) model.Error!u64 {
    var window_cursor = record.Cursor.init(source_relocations);
    var query_cursor = window_cursor;

    var input_offset: u64 = 0;
    var output_size: u64 = 0;
    while (input_offset < bytes.len) {
        const record_start: usize = @intCast(input_offset);
        if (bytes.len - record_start < 4) return error.InvalidObject;
        const record_length = readU32(bytes, record_start);
        if (record_length == 0xffffffff) return error.UnsupportedFormat;
        const record_size = @as(u64, record_length) + 4;
        if (record_size < 4) return error.InvalidObject;
        if (input_offset > std.math.maxInt(u64) - record_size) return error.InvalidObject;
        const record_end = input_offset + record_size;
        if (record_end > bytes.len) return error.InvalidObject;

        if (record_length == 0) {
            emitRelocations(&window_cursor, input_offset, record_size, output_size, consumer);
            consumer.piece(.{
                .input_offset = input_offset,
                .size = record_size,
                .output_offset = output_size,
            });
            output_size += record_size;
            break;
        }

        if (record_length < 4) return error.InvalidObject;
        const record_id = readU32(bytes, record_start + 4);
        var keep_record = true;
        var patch_cie_pointer = false;
        var cie_pointer: u32 = 0;
        if (record_id == 0) {
            consumer.cie(input_offset, output_size);
        } else {
            const initial_location_offset = input_offset + 8;
            if (query_cursor.at(initial_location_offset)) |relocation| {
                keep_record = !(try relocationTargetDiscarded(objects, object_index, relocation, globals));
            }
            if (keep_record) {
                const cie_field_offset = input_offset + 4;
                if (record_id > cie_field_offset) return error.InvalidObject;
                const cie_input_offset = cie_field_offset - record_id;
                cie_pointer = try consumer.resolve(cie_input_offset, output_size);
                patch_cie_pointer = true;
            }
        }

        if (keep_record) {
            emitRelocations(&window_cursor, input_offset, record_size, output_size, consumer);
            consumer.piece(.{
                .input_offset = input_offset,
                .size = record_size,
                .output_offset = output_size,
                .patch_cie_pointer = patch_cie_pointer,
                .cie_pointer = cie_pointer,
            });
            output_size += record_size;
        }
        input_offset = record_end;
    }
    return output_size;
}

pub fn assign(
    output_sections: *[output_section_count]OutputSection,
    contributions: []SectionContribution,
    section: SectionHeader,
    section_index: usize,
    output_size: u64,
    options: model.LinkOptions,
) model.Error!void {
    const output_index = @backingInt(output_section.OutputSectionKind.eh_frame);
    var output = &output_sections[output_index];
    try validateAlignment(section.alignment);
    output.alignment = @max(output.alignment, @max(section.alignment, 1));
    const alignment = @max(section.alignment, 1);
    const aligned_offset = if (section.section_type == std.elf.SHT_NOBITS)
        alignForwardU64(output.memory_size, alignment)
    else
        alignForwardU64(output.file_size, alignment);
    const reserved_size = contributionReserveSize(output_size, alignment, options);
    contributions[section_index] = SectionContribution.init(
        output_index,
        aligned_offset,
        output_size,
        reserved_size,
        alignment,
    );

    if (section.section_type == std.elf.SHT_NOBITS) {
        output.memory_size = aligned_offset + reserved_size;
    } else {
        output.file_size = aligned_offset + reserved_size;
        output.memory_size = output.file_size;
    }
}

pub fn cieOutputOffset(cies: []const EhFrameCieLayout, input_offset: u64) ?u64 {
    for (cies) |cie| {
        if (cie.input_offset == input_offset) return cie.output_offset;
    }
    return null;
}

fn emitRelocations(
    cursor: *record.Cursor,
    input_offset: u64,
    size: u64,
    output_offset: u64,
    consumer: anytype,
) void {
    const input_end = input_offset + size;
    if (cursor.window(input_offset, input_end)) |window_relocations| {
        for (window_relocations) |relocation| {
            var adjusted = relocation;
            adjusted.offset = output_offset + relocation.offset - input_offset;
            consumer.relocation(adjusted);
        }
        return;
    }
    for (cursor.relocations) |relocation| {
        if (relocation.offset < input_offset or relocation.offset >= input_end) continue;
        var adjusted = relocation;
        adjusted.offset = output_offset + relocation.offset - input_offset;
        consumer.relocation(adjusted);
    }
}

fn relocationTargetDiscarded(
    objects: []const ObjectFile,
    object_index: usize,
    relocation: Rela,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
) model.Error!bool {
    const object = objects[object_index];
    const symbol_index = relocation.symbolIndex();
    if (symbol_index >= object.symbols.len) return error.UndefinedSymbol;
    const symbol = object.symbols[symbol_index];
    if (symbol.isUndefined() or symbol.isCommon() or symbol.isAbsolute()) return false;
    if (symbol.section_index >= object.sections.len) return error.UnsupportedRelocation;
    if (foldedSection(object, symbol.section_index)) |canonical| {
        if (canonical.object_index >= objects.len) return error.MissingSection;
        return sectionDiscarded(objects[canonical.object_index], canonical.section_index);
    }
    if (!sectionDiscarded(object, symbol.section_index)) return false;
    if (symbol.name.len == 0) return true;
    const global = globals.get(symbol.name) orelse return true;
    const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
    return global.ref.eql(current_ref);
}
