const std = @import("std");
const root = @import("../../../../root.zig");
const elf = @import("../../root.zig");
const ehframe = @import("../root.zig");
const reservation = @import("reservation.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const addressing = elf.addressing;
const format = elf.format;
const layout = elf.layout;
const output_section = elf.output_section;
const parser = elf.parser;
const ObjectFile = parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const GlobalSymbol = layout.GlobalSymbol;
const SymbolAddressCache = addressing.Cache;
const Rela = format.Rela;
const OutputSectionKind = output_section.OutputSectionKind;
const eh_frame_hdr_fixed_size = format.eh_frame_hdr_fixed_size;
const eh_frame_hdr_entry_size = format.eh_frame_hdr_entry_size;
const dwarf_eh_pe_udata4 = format.dwarf_eh_pe_udata4;
const dwarf_eh_pe_sdata4 = format.dwarf_eh_pe_sdata4;
const dwarf_eh_pe_pcrel = format.dwarf_eh_pe_pcrel;
const dwarf_eh_pe_datarel = format.dwarf_eh_pe_datarel;
const contributionAt = layout.contributionAt;
const ehFrameSectionLayout = layout.ehFrameSection;
const sectionBytes = format.sectionBytes;
const readU32 = format.readU32;
const writeU32 = format.writeU32;
const requireRange = format.requireRange;
const relocationTargetAddress = addressing.relocationTarget;
const record = ehframe.record;
const section = ehframe.section;

const Entry = struct {
    start_ip: u64,
    fde_address: u64,
};

pub fn write(
    scratch: Allocator,
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    options: model.LinkOptions,
) model.Error!void {
    if (!options.eh_frame_header) return;
    const header = output_sections[@backingInt(OutputSectionKind.eh_frame_hdr)];
    if (header.logicalSize() == 0) return;
    const eh_frame_start = startAddress(objects, layouts, output_sections) orelse return error.MissingSection;

    var entries = std.ArrayListUnmanaged(Entry).empty;
    defer entries.deinit(scratch);
    try collectEntries(scratch, &entries, objects, layouts, output_sections, globals, symbol_addresses);
    if (try reservation.size(entries.items.len) != header.logicalSize()) return error.InvalidRange;

    std.mem.sort(Entry, entries.items, {}, compareEntries);
    try requireRange(image, header.file_offset, header.logicalSize());
    const start: usize = @intCast(header.file_offset);
    image[start + 0] = 1;
    image[start + 1] = dwarf_eh_pe_pcrel | dwarf_eh_pe_sdata4;
    image[start + 2] = dwarf_eh_pe_udata4;
    image[start + 3] = dwarf_eh_pe_datarel | dwarf_eh_pe_sdata4;
    writeU32(image, start + 4, @bitCast(try elf.relocation.checkedI32(@as(i128, @intCast(eh_frame_start)) - @as(i128, @intCast(header.address + 4)))));
    writeU32(image, start + 8, try elf.relocation.checkedU32(@intCast(entries.items.len)));

    var cursor = start + eh_frame_hdr_fixed_size;
    for (entries.items) |entry| {
        writeU32(image, cursor + 0, @bitCast(try elf.relocation.checkedI32(@as(i128, @intCast(entry.start_ip)) - @as(i128, @intCast(header.address)))));
        writeU32(image, cursor + 4, @bitCast(try elf.relocation.checkedI32(@as(i128, @intCast(entry.fde_address)) - @as(i128, @intCast(header.address)))));
        cursor += eh_frame_hdr_entry_size;
    }
}

fn collectEntries(
    allocator: Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        const object_layout = layouts[object_index];
        for (object.sections, 0..) |input_section, section_index| {
            const contribution = contributionAt(object_layout.sections, section_index) orelse continue;
            if (!section.is(object, section_index, input_section)) continue;
            const output = output_sections[contribution.outputIndex()];
            const section_address = output.address + contribution.offset;
            const bytes = try sectionBytes(object.bytes, input_section);
            if (ehFrameSectionLayout(object_layout, section_index)) |eh_frame_section| {
                var cursor = record.Cursor.init(eh_frame_section.relocations);
                for (eh_frame_section.pieces) |piece| {
                    try appendEntry(
                        allocator,
                        entries,
                        objects,
                        layouts,
                        output_sections,
                        globals,
                        symbol_addresses,
                        object_index,
                        bytes,
                        piece.input_offset,
                        piece.size,
                        piece.output_offset,
                        &cursor,
                        section_address,
                    );
                }
                continue;
            }
            try collectRawEntries(
                allocator,
                entries,
                objects,
                layouts,
                output_sections,
                globals,
                symbol_addresses,
                object_index,
                bytes,
                object.relocationsForSection(section_index),
                section_address,
            );
        }
    }
}

fn collectRawEntries(
    allocator: Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    object_index: usize,
    bytes: []const u8,
    relocations: []const Rela,
    section_address: u64,
) model.Error!void {
    var cursor = record.Cursor.init(relocations);
    var input_offset: u64 = 0;
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
        try appendEntry(
            allocator,
            entries,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            object_index,
            bytes,
            input_offset,
            record_size,
            input_offset,
            &cursor,
            section_address,
        );
        if (record_length == 0) break;
        input_offset = record_end;
    }
}

fn appendEntry(
    allocator: Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    object_index: usize,
    bytes: []const u8,
    input_offset: u64,
    entry_size: u64,
    output_offset: u64,
    cursor: *record.Cursor,
    section_address: u64,
) model.Error!void {
    if (!try record.hasHeaderEntry(bytes, input_offset, entry_size, output_offset, cursor)) return;
    const relocation = cursor.at(output_offset + 8) orelse return;
    const symbol_index: usize = @intCast(relocation.symbolIndex());
    const target = try relocationTargetAddress(.serial, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index, relocation, false);
    try entries.append(allocator, .{
        .start_ip = try elf.relocation.checkedU64(target.address + target.addend),
        .fde_address = section_address + output_offset,
    });
}

fn startAddress(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
) ?u64 {
    var start: ?u64 = null;
    for (objects, 0..) |object, object_index| {
        const object_layout = layouts[object_index];
        for (object.sections, 0..) |input_section, section_index| {
            const contribution = contributionAt(object_layout.sections, section_index) orelse continue;
            if (!section.is(object, section_index, input_section)) continue;
            const output = output_sections[contribution.outputIndex()];
            const address = output.address + contribution.offset;
            if (start == null or address < start.?) start = address;
        }
    }
    return start;
}

fn compareEntries(_: void, left: Entry, right: Entry) bool {
    if (left.start_ip != right.start_ip) return left.start_ip < right.start_ip;
    return left.fde_address < right.fde_address;
}
