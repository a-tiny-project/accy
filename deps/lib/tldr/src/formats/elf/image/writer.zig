const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const symbols = @import("symbols.zig");
const zero = @import("zero.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const trace = root.trace;
const StringTable = elf.string.Table;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = elf.layout.ObjectLayout;
const OutputSection = elf.layout.OutputSection;
const GlobalSymbol = elf.layout.GlobalSymbol;
const SymbolRef = elf.layout.SymbolRef;
const GotLayout = elf.layout.GotLayout;
const SymbolAddressCache = elf.addressing.Cache;
const OutputSectionKind = elf.output_section.OutputSectionKind;
const output_section_count = elf.output_section.output_section_count;
const SectionHeader = elf.format.SectionHeader;
const SymbolRecord = elf.format.SymbolRecord;
const shdr_size = elf.format.shdr_size;
const sym_size = elf.format.sym_size;
const alignForwardU64 = elf.format.alignForwardU64;
const copyInto = elf.format.copyInto;
const elfSymbolInfo = elf.format.elfSymbolInfo;

pub fn write(
    scratch: Allocator,
    image_allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: *[output_section_count]OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    global_symbol_refs: []const SymbolRef,
    symbol_addresses: *SymbolAddressCache,
    got_layout: GotLayout,
    options: model.LinkOptions,
    entry_address: u64,
    live_output_count: usize,
    program_header_count: usize,
) model.Error!root.LinkedImage.Storage.Allocation {
    var shstrtab = try StringTable.init(scratch);
    defer shstrtab.deinit(scratch);
    var strtab = try StringTable.init(scratch);
    defer strtab.deinit(scratch);

    var sh_names: [output_section_count]u32 = @splat(0);
    for (output_sections, 0..) |section, index| {
        if (section.logicalSize() != 0) sh_names[index] = try shstrtab.add(scratch, section.kind.name());
    }
    const sh_name_symtab = try shstrtab.add(scratch, ".symtab");
    const sh_name_strtab = try shstrtab.add(scratch, ".strtab");
    const sh_name_shstrtab = try shstrtab.add(scratch, ".shstrtab");

    var executable_symbols = std.ArrayListUnmanaged(SymbolRecord).empty;
    defer executable_symbols.deinit(scratch);
    const local_symbol_capacity = std.math.add(usize, 1, live_output_count) catch return error.InvalidObject;
    const executable_symbol_capacity = std.math.add(usize, local_symbol_capacity, global_symbol_refs.len) catch return error.InvalidObject;
    try executable_symbols.ensureTotalCapacity(scratch, executable_symbol_capacity);
    try executable_symbols.append(scratch, .{});
    for (output_sections) |section| {
        if (section.logicalSize() == 0) continue;
        try executable_symbols.append(scratch, .{
            .info = elfSymbolInfo(std.elf.STB_LOCAL, std.elf.STT_SECTION),
            .section_index = section.section_index,
        });
    }
    const first_global_symbol: u32 = @intCast(executable_symbols.items.len);
    {
        const symbol_phase = trace.product(.write_symbol_table);
        defer symbol_phase.end();
        try symbols.appendExecutable(scratch, &executable_symbols, &strtab, objects, layouts, output_sections, globals, global_symbol_refs, symbol_addresses, options.max_link_jobs);
    }

    const symtab_size = executable_symbols.items.len * sym_size;

    var last_load_end: u64 = 0;
    for (output_sections) |section| {
        if (section.logicalSize() == 0) continue;
        const file_end = if (section.kind.isNoBits())
            section.file_offset
        else
            section.file_offset + section.fileLoadSize();
        last_load_end = @max(last_load_end, file_end);
    }

    var metadata_offset = alignForwardU64(last_load_end, 8);
    const symtab_offset = metadata_offset;
    metadata_offset += symtab_size;
    const strtab_offset = metadata_offset;
    metadata_offset += strtab.bytes().len;
    const shstrtab_offset = metadata_offset;
    metadata_offset += shstrtab.bytes().len;
    const shoff = alignForwardU64(metadata_offset, 8);

    const shnum = 1 + live_output_count + 3;
    if (shnum > std.math.maxInt(u16)) return error.TooManySections;
    const symtab_section_index: u16 = @intCast(1 + live_output_count);
    const strtab_section_index: u16 = symtab_section_index + 1;
    const shstrtab_section_index: u16 = strtab_section_index + 1;
    const total_size = shoff + shnum * shdr_size;

    var allocation = try root.LinkedImage.Storage.allocate(image_allocator, @intCast(total_size), options);
    errdefer allocation.deinit(image_allocator);
    const image = allocation.bytes;
    if (allocation.needsZeroFill()) {
        const zero_phase = trace.product(.write_zero_fill);
        defer zero_phase.end();
        try zero.unwrittenFileRanges(image, objects, layouts, output_sections, symtab_offset, metadata_offset, shoff);
    }
    try writeGeneratedPayloads(scratch, image, objects, layouts, output_sections, globals, symbol_addresses, options);
    try elf.got_table.writePayload(image, objects, layouts, output_sections, globals, symbol_addresses, got_layout);

    elf.program.writeElfHeader(image, .{
        .entry_address = entry_address,
        .program_header_count = @intCast(program_header_count),
        .section_header_offset = shoff,
        .section_count = @intCast(shnum),
        .section_string_table_index = shstrtab_section_index,
    });
    elf.program.writeProgramHeaders(image, output_sections, options, program_header_count);
    const metadata_phase = trace.product(.write_metadata);
    const symbol_table = image[@as(usize, @intCast(symtab_offset))..];
    for (executable_symbols.items, 0..) |entry, index| {
        entry.write(symbol_table, index * sym_size);
    }
    copyInto(image, @intCast(strtab_offset), strtab.bytes());
    copyInto(image, @intCast(shstrtab_offset), shstrtab.bytes());
    metadata_phase.end();

    const section_table = image[@as(usize, @intCast(shoff))..];
    var next_section_index: u16 = 1;
    (SectionHeader{}).write(section_table, 0);
    for (output_sections, 0..) |section, output_index| {
        if (section.logicalSize() == 0) continue;
        (SectionHeader{
            .name_offset = sh_names[output_index],
            .section_type = section.kind.sectionType(),
            .flags = section.kind.flags(),
            .address = section.address,
            .offset = section.file_offset,
            .size = section.logicalSize(),
            .alignment = section.alignment,
            .entry_size = section.kind.entrySize(),
        }).write(section_table, @as(usize, next_section_index) * shdr_size);
        next_section_index += 1;
    }
    (SectionHeader{
        .name_offset = sh_name_symtab,
        .section_type = std.elf.SHT_SYMTAB,
        .offset = symtab_offset,
        .size = symtab_size,
        .link = strtab_section_index,
        .info = first_global_symbol,
        .alignment = 8,
        .entry_size = sym_size,
    }).write(section_table, @as(usize, symtab_section_index) * shdr_size);
    (SectionHeader{
        .name_offset = sh_name_strtab,
        .section_type = std.elf.SHT_STRTAB,
        .offset = strtab_offset,
        .size = strtab.bytes().len,
        .alignment = 1,
    }).write(section_table, @as(usize, strtab_section_index) * shdr_size);
    (SectionHeader{
        .name_offset = sh_name_shstrtab,
        .section_type = std.elf.SHT_STRTAB,
        .offset = shstrtab_offset,
        .size = shstrtab.bytes().len,
        .alignment = 1,
    }).write(section_table, @as(usize, shstrtab_section_index) * shdr_size);

    return allocation;
}

fn writeGeneratedPayloads(
    scratch: Allocator,
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    options: model.LinkOptions,
) model.Error!void {
    if (options.build_id != .none) {
        const section = output_sections[@backingInt(OutputSectionKind.build_id_note)];
        try elf.note.writeBuildIdHeader(image, section.file_offset);
    }
    try elf.ehframe.writeHeader(scratch, image, objects, layouts, output_sections, globals, symbol_addresses, options);
}
