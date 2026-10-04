const std = @import("std");
const root = @import("../root.zig");
const incremental = root.incremental;
const model = root.model;
const trace = root.trace;

const Allocator = std.mem.Allocator;

const header_size = @sizeOf(std.coff.Header);
const section_header_size = @sizeOf(std.coff.SectionHeader);
const symbol_size = std.coff.Symbol.sizeOf();
const relocation_size = 10;
const absolute_relocation_kind: u16 = 0;
const pe_offset = 0x80;
const pe_signature_size = 4;
const pe32_plus_optional_header_size = 240;
const pe_data_directory_count = 16;
const coff_file_alignment = 0x200;
const coff_text_section_flags = 0x60000020;
const coff_executable_flags = 0x22;
const coff_code_flags = 0x20;
const coff_uninitialized_data_flags = 0x80;
const coff_discardable_flags = 0x02000000;
const coff_execute_flags = 0x20000000;
const pe32_plus_magic = 0x20b;
const windows_cui_subsystem = 3;
const nx_compat_dll_characteristic = 0x0100;

pub const Object = struct {
    target: model.Target,
    sections: []Section,
    relocations: []Relocation,
    symbols: []Symbol,
    string_table: []const u8,

    pub fn deinit(self: *Object, allocator: Allocator) void {
        if (self.sections.len != 0) allocator.free(self.sections);
        if (self.relocations.len != 0) allocator.free(self.relocations);
        if (self.symbols.len != 0) allocator.free(self.symbols);
        self.* = undefined;
    }
};

pub const Section = struct {
    name: []const u8,
    size: u32,
    offset: u32,
    relocation_offset: u32,
    relocation_count: u16,
    flags: u32,
    alignment: u16,
};

pub const Relocation = struct {
    section_index: usize,
    virtual_address: u32,
    symbol_table_index: u32,
    kind: u16,
};

pub const Symbol = struct {
    raw_index: u32,
    name: []const u8,
    value: u32,
    section_number: i16,
    kind: u16,
    storage_class: u8,
    aux_count: u8,
};

const TextContribution = struct {
    input_index: usize,
    input_name: []const u8,
    section_index: usize,
    section_name: []const u8,
    bytes: []const u8,
    alignment: u64,
    output_offset: u64 = 0,
};

const LinkObject = struct {
    input_name: []const u8,
    input_index: usize,
    object: Object,
};

const SymbolDefinition = struct {
    input_index: usize,
    section_index: usize,
    value: u32,
};

pub fn isObject(bytes: []const u8) bool {
    if (bytes.len < header_size) return false;
    const machine = std.mem.readInt(u16, bytes[0..2], .little);
    switch (@as(std.coff.IMAGE.FILE.MACHINE, @fromBackingInt(@intCast(machine)))) {
        .AMD64, .ARM64 => {},
        else => return false,
    }
    return std.mem.readInt(u16, bytes[16..18], .little) == 0;
}

pub fn linkExecutable(
    allocator: Allocator,
    inputs: []const model.Input,
    options: model.LinkOptions,
) model.Error!root.LinkedImage {
    const link_phase = trace.scope("link.coff");
    defer link_phase.end();
    if (options.diagnostics) |diagnostics| diagnostics.clear();
    if (options.output_kind != .executable) return error.UnsupportedOutputKind;
    if (options.target.architecture != .x86_64 or options.target.endianness != .little) {
        return error.UnsupportedArchitecture;
    }
    if (options.page_size < coff_file_alignment) return error.InvalidAlignment;
    if (options.gc_sections or options.icf != .off) return error.UnsupportedFormat;
    if (inputs.len == 0) return error.NoAllocSections;

    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var manifest_builder = build_manifest: {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        var builder = try incremental.Builder.init(allocator, options);
        errdefer builder.deinit();
        for (inputs) |input| try builder.addInput(input);
        break :build_manifest builder;
    };
    errdefer manifest_builder.deinit();

    var contributions = std.ArrayListUnmanaged(TextContribution).empty;
    defer contributions.deinit(scratch);

    var definitions: std.StringHashMapUnmanaged(SymbolDefinition) = .{};
    defer definitions.deinit(scratch);

    var objects = std.ArrayListUnmanaged(LinkObject).empty;
    defer objects.deinit(scratch);

    for (inputs, 0..) |input, input_index| {
        if (root.archive.isArchive(input.bytes)) return error.UnsupportedFormat;
        const object = try parseObject(scratch, input.bytes);
        if (object.target.object_format != .coff) return error.UnsupportedFormat;
        if (object.target.architecture != options.target.architecture) return error.UnsupportedArchitecture;

        try objects.append(scratch, .{
            .input_name = input.name,
            .input_index = input_index,
            .object = object,
        });
    }

    {
        const layout_phase = trace.product(.section_contribution_graph);
        defer layout_phase.end();
        for (objects.items) |link_object| {
            const input = inputs[link_object.input_index];
            try collectTextContributions(scratch, &contributions, input, link_object.input_index, link_object.object.sections);
        }
    }
    {
        const symbol_phase = trace.product(.symbol_database);
        defer symbol_phase.end();
        for (objects.items) |link_object| {
            try indexExternalDefinitions(scratch, &definitions, link_object.input_index, link_object.object);
        }
    }

    const text_size = layout_text: {
        const layout_phase = trace.product(.address_assignment);
        defer layout_phase.end();
        break :layout_text try layoutTextContributions(contributions.items);
    };
    if (text_size == 0) return error.NoAllocSections;

    const entry = resolve_entry: {
        const symbol_phase = trace.product(.symbol_database);
        defer symbol_phase.end();
        const entry_definition = definitions.get(options.entry_symbol) orelse return error.MissingEntrySymbol;
        const entry_contribution = contributionForDefinition(contributions.items, entry_definition) orelse return error.MissingEntrySymbol;
        if (entry_definition.value > entry_contribution.bytes.len) return error.InvalidRange;
        break :resolve_entry .{
            .definition = entry_definition,
            .contribution = entry_contribution,
        };
    };

    const section_alignment = options.page_size;
    const text_rva = section_alignment;
    const entry_rva = try checkedU32FromU64(try checkedAddU64(text_rva, try checkedAddU64(entry.contribution.output_offset, entry.definition.value)));
    const text_raw_size = try alignForward(text_size, coff_file_alignment);
    const headers_size = try alignForward(pe_offset + pe_signature_size + header_size + pe32_plus_optional_header_size + section_header_size, coff_file_alignment);
    const size_of_image = try alignForward(try checkedAddU64(text_rva, text_size), section_alignment);
    const total_size = try checkedAddU64(headers_size, text_raw_size);

    const image = try allocator.alloc(u8, try checkedUsize(total_size));
    errdefer allocator.free(image);
    {
        const write_phase = trace.product(.output_writing);
        defer write_phase.end();
        @memset(image, 0);

        try writePeHeaders(
            image,
            options,
            text_size,
            text_raw_size,
            headers_size,
            entry_rva,
            size_of_image,
        );
        for (contributions.items) |contribution| {
            const start = try checkedUsize(try checkedAddU64(headers_size, contribution.output_offset));
            @memcpy(image[start..][0..contribution.bytes.len], contribution.bytes);
        }
    }
    {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        for (contributions.items) |contribution| {
            try manifest_builder.addContribution(
                contribution.input_name,
                contribution.input_index,
                .section,
                contribution.section_name,
                @intCast(contribution.section_index),
                ".text",
                try checkedAddU64(options.image_base, try checkedAddU64(text_rva, contribution.output_offset)),
                try checkedAddU64(headers_size, contribution.output_offset),
                contribution.bytes.len,
                contribution.bytes.len,
                contribution.alignment,
            );
        }
    }
    try applyRelocations(
        image,
        objects.items,
        contributions.items,
        &definitions,
        options,
        headers_size,
        text_rva,
    );

    {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        try manifest_builder.addSection(
            ".text",
            try checkedAddU64(options.image_base, text_rva),
            headers_size,
            text_size,
            text_raw_size,
            section_alignment,
        );
    }

    const manifest = finish_manifest: {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        break :finish_manifest try manifest_builder.finish();
    };

    return .{
        .bytes = image,
        .manifest = manifest,
    };
}

pub fn parseObject(allocator: Allocator, bytes: []const u8) model.Error!Object {
    const phase = trace.product(.input_discovery);
    defer phase.end();
    _ = try range(bytes, 0, header_size);

    const machine = try readU16(bytes, 0);
    const target = try targetFromMachine(machine);
    const section_count = try readU16(bytes, 2);
    const symbol_table_offset = try readU32(bytes, 8);
    const raw_symbol_count = try readU32(bytes, 12);
    const optional_header_size = try readU16(bytes, 16);
    if (optional_header_size != 0) return error.UnsupportedFormat;

    const section_table_offset = header_size + @as(usize, optional_header_size);
    const section_bytes_len = try checkedMul(@as(usize, section_count), section_header_size);
    _ = try range(bytes, section_table_offset, section_bytes_len);

    const string_table = try coffStringTable(bytes, symbol_table_offset, raw_symbol_count);

    const sections = try allocator.alloc(Section, section_count);
    errdefer allocator.free(sections);
    for (sections, 0..) |*section, index| {
        const section_offset = section_table_offset + index * section_header_size;
        const raw_data_size = try readU32(bytes, section_offset + 16);
        const raw_data_offset = try readU32(bytes, section_offset + 20);
        const relocation_offset = try readU32(bytes, section_offset + 24);
        const relocation_count = try readU16(bytes, section_offset + 32);
        if (raw_data_size != 0 and raw_data_offset != 0) {
            _ = try range(bytes, try checkedUsize(raw_data_offset), try checkedUsize(raw_data_size));
        }
        if (relocation_count != 0) {
            _ = try range(
                bytes,
                try checkedUsize(relocation_offset),
                try checkedMul(@as(usize, relocation_count), relocation_size),
            );
        }
        const flags = try readU32(bytes, section_offset + 36);
        section.* = .{
            .name = try sectionName((try range(bytes, section_offset, 8))[0..8], string_table),
            .size = raw_data_size,
            .offset = raw_data_offset,
            .relocation_offset = relocation_offset,
            .relocation_count = relocation_count,
            .flags = flags,
            .alignment = sectionAlignment(flags),
        };
    }

    const symbol_range = try coffSymbolRange(bytes, symbol_table_offset, raw_symbol_count);
    const primary_symbol_indices = try allocator.alloc(bool, try checkedUsize(raw_symbol_count));
    defer if (primary_symbol_indices.len != 0) allocator.free(primary_symbol_indices);
    @memset(primary_symbol_indices, false);

    var retained_symbol_count: usize = 0;
    var symbol_index: usize = 0;
    while (symbol_index < raw_symbol_count) {
        const symbol_offset = symbol_index * symbol_size;
        const aux_count = symbol_range[symbol_offset + 17];
        if (symbol_index + 1 + @as(usize, aux_count) > raw_symbol_count) return error.InvalidObject;
        primary_symbol_indices[symbol_index] = true;
        retained_symbol_count += 1;
        symbol_index += 1 + @as(usize, aux_count);
    }

    const relocations = try parseRelocations(allocator, bytes, target.architecture, sections, primary_symbol_indices);
    errdefer if (relocations.len != 0) allocator.free(relocations);

    const symbols = try allocator.alloc(Symbol, retained_symbol_count);
    errdefer allocator.free(symbols);
    var cursor: usize = 0;
    symbol_index = 0;
    while (symbol_index < raw_symbol_count) {
        const symbol_offset = symbol_index * symbol_size;
        const aux_count = symbol_range[symbol_offset + 17];
        const section_number = std.mem.readInt(i16, symbol_range[symbol_offset + 12 ..][0..2], .little);
        try validateSymbolSectionNumber(section_number, section_count);
        symbols[cursor] = .{
            .raw_index = @intCast(symbol_index),
            .name = try symbolName(symbol_range[symbol_offset..][0..8], string_table),
            .value = std.mem.readInt(u32, symbol_range[symbol_offset + 8 ..][0..4], .little),
            .section_number = section_number,
            .kind = std.mem.readInt(u16, symbol_range[symbol_offset + 14 ..][0..2], .little),
            .storage_class = symbol_range[symbol_offset + 16],
            .aux_count = aux_count,
        };
        cursor += 1;
        symbol_index += 1 + @as(usize, aux_count);
    }

    return .{
        .target = target,
        .sections = sections,
        .relocations = relocations,
        .symbols = symbols,
        .string_table = string_table,
    };
}

pub fn parseObjectMetadata(allocator: Allocator, bytes: []const u8) model.Error!root.Object {
    var object = try parseObject(allocator, bytes);
    defer object.deinit(allocator);

    const sections = try allocator.alloc(root.ObjectSection, object.sections.len);
    errdefer allocator.free(sections);
    for (sections, object.sections) |*section, source| {
        section.* = .{
            .name = source.name,
            .size = source.size,
            .offset = source.offset,
            .alignment = source.alignment,
            .flags = source.flags,
            .relocation_count = source.relocation_count,
        };
    }

    const symbols = try allocator.alloc(root.ObjectSymbol, object.symbols.len);
    errdefer allocator.free(symbols);
    for (symbols, object.symbols) |*symbol, source| {
        symbol.* = .{
            .name = source.name,
            .section_index = source.section_number,
            .value = source.value,
            .kind = source.kind,
            .binding = source.storage_class,
            .external = source.storage_class == @backingInt(std.coff.StorageClass.EXTERNAL),
            .undefined = source.section_number == 0,
        };
    }

    return .{
        .target = object.target,
        .sections = sections,
        .symbols = symbols,
    };
}

fn collectTextContributions(
    allocator: Allocator,
    contributions: *std.ArrayListUnmanaged(TextContribution),
    input: model.Input,
    input_index: usize,
    sections: []const Section,
) model.Error!void {
    for (sections, 0..) |section, section_index| {
        if (!sectionHasImageData(section)) continue;
        try contributions.append(allocator, .{
            .input_index = input_index,
            .input_name = input.name,
            .section_index = section_index,
            .section_name = section.name,
            .bytes = try sectionData(input.bytes, section),
            .alignment = @max(section.alignment, 1),
        });
    }
}

fn applyRelocations(
    image: []u8,
    objects: []const LinkObject,
    contributions: []const TextContribution,
    definitions: *const std.StringHashMapUnmanaged(SymbolDefinition),
    options: model.LinkOptions,
    text_file_offset: u64,
    text_rva: u64,
) model.Error!void {
    const phase = trace.product(.relocation_application);
    defer phase.end();
    for (objects) |link_object| {
        for (link_object.object.relocations) |relocation| {
            if (relocation.kind == absolute_relocation_kind) continue;
            if (relocation.section_index >= link_object.object.sections.len) return error.InvalidObject;
            const section = link_object.object.sections[relocation.section_index];
            if (!sectionHasImageData(section)) continue;
            const source = contributionForSection(
                contributions,
                link_object.input_index,
                relocation.section_index,
            ) orelse return error.InvalidObject;
            const symbol = symbolByRawIndex(link_object.object.symbols, relocation.symbol_table_index) orelse return error.InvalidObject;
            const target = try definitionForRelocationSymbol(
                definitions,
                link_object.input_name,
                link_object.input_index,
                link_object.object.sections,
                symbol,
                options,
            );
            const target_contribution = contributionForDefinition(contributions, target) orelse return error.InvalidObject;
            if (target.value > target_contribution.bytes.len) return error.InvalidRange;
            const target_rva = try symbolRva(text_rva, target_contribution, target.value);

            switch (@as(std.coff.IMAGE.REL.AMD64, @fromBackingInt(@intCast(relocation.kind)))) {
                .ADDR64 => try applyAddr64(
                    image,
                    text_file_offset,
                    source,
                    relocation,
                    try checkedRelocationAddU64(options.image_base, target_rva),
                ),
                .ADDR32 => try applyAddr32(
                    image,
                    text_file_offset,
                    source,
                    relocation,
                    try checkedRelocationAddU64(options.image_base, target_rva),
                ),
                .ADDR32NB => try applyAddr32(
                    image,
                    text_file_offset,
                    source,
                    relocation,
                    target_rva,
                ),
                .REL32 => try applyRel32(
                    image,
                    text_file_offset,
                    text_rva,
                    source,
                    relocation,
                    target_rva,
                    4,
                ),
                .REL32_1 => try applyRel32(
                    image,
                    text_file_offset,
                    text_rva,
                    source,
                    relocation,
                    target_rva,
                    5,
                ),
                .REL32_2 => try applyRel32(
                    image,
                    text_file_offset,
                    text_rva,
                    source,
                    relocation,
                    target_rva,
                    6,
                ),
                .REL32_3 => try applyRel32(
                    image,
                    text_file_offset,
                    text_rva,
                    source,
                    relocation,
                    target_rva,
                    7,
                ),
                .REL32_4 => try applyRel32(
                    image,
                    text_file_offset,
                    text_rva,
                    source,
                    relocation,
                    target_rva,
                    8,
                ),
                .REL32_5 => try applyRel32(
                    image,
                    text_file_offset,
                    text_rva,
                    source,
                    relocation,
                    target_rva,
                    9,
                ),
                else => {
                    if (options.diagnostics) |diagnostics| {
                        diagnostics.recordUnsupportedRelocation(
                            link_object.input_name,
                            section.name,
                            symbol.name,
                            relocation.kind,
                        );
                    }
                    return error.UnsupportedRelocation;
                },
            }
        }
    }
}

fn applyAddr64(
    image: []u8,
    text_file_offset: u64,
    source: TextContribution,
    relocation: Relocation,
    target_address: u64,
) model.Error!void {
    const patch_index = try relocationPatchIndex(image, text_file_offset, source, relocation, 8);
    const addend = std.mem.readInt(u64, image[patch_index..][0..8], .little);
    std.mem.writeInt(u64, image[patch_index..][0..8], try checkedRelocationAddU64(target_address, addend), .little);
}

fn applyAddr32(
    image: []u8,
    text_file_offset: u64,
    source: TextContribution,
    relocation: Relocation,
    target_address: u64,
) model.Error!void {
    const patch_index = try relocationPatchIndex(image, text_file_offset, source, relocation, 4);
    const addend: u64 = std.mem.readInt(u32, image[patch_index..][0..4], .little);
    const value = try checkedRelocationAddU64(target_address, addend);
    std.mem.writeInt(u32, image[patch_index..][0..4], try checkedU32FromRelocation(value), .little);
}

fn applyRel32(
    image: []u8,
    text_file_offset: u64,
    text_rva: u64,
    source: TextContribution,
    relocation: Relocation,
    target_rva: u64,
    base_distance: u64,
) model.Error!void {
    const patch_index = try relocationPatchIndex(image, text_file_offset, source, relocation, 4);

    const place_rva = try checkedAddU64(
        text_rva,
        try checkedAddU64(source.output_offset, relocation.virtual_address),
    );
    const addend: i64 = std.mem.readInt(i32, image[patch_index..][0..4], .little);
    const value = try checkedSubI64(
        try checkedAddI64(try checkedI64FromU64(target_rva), addend),
        try checkedI64FromU64(try checkedAddU64(place_rva, base_distance)),
    );
    std.mem.writeInt(i32, image[patch_index..][0..4], try checkedI32FromI64(value), .little);
}

fn relocationPatchIndex(
    image: []const u8,
    text_file_offset: u64,
    source: TextContribution,
    relocation: Relocation,
    width: usize,
) model.Error!usize {
    const patch_file_offset = try checkedAddU64(
        text_file_offset,
        try checkedAddU64(source.output_offset, relocation.virtual_address),
    );
    const patch_index = try checkedUsize(patch_file_offset);
    if (patch_index > image.len or width > image.len - patch_index) return error.InvalidRange;
    return patch_index;
}

fn symbolRva(text_rva: u64, target: TextContribution, target_value: u32) model.Error!u64 {
    return try checkedAddU64(
        text_rva,
        try checkedAddU64(target.output_offset, target_value),
    );
}

fn symbolByRawIndex(symbols: []const Symbol, raw_index: u32) ?Symbol {
    for (symbols) |symbol| {
        if (symbol.raw_index == raw_index) return symbol;
    }
    return null;
}

fn definitionForRelocationSymbol(
    definitions: *const std.StringHashMapUnmanaged(SymbolDefinition),
    input_name: []const u8,
    input_index: usize,
    sections: []const Section,
    symbol: Symbol,
    options: model.LinkOptions,
) model.Error!SymbolDefinition {
    if (symbol.section_number > 0) {
        const section_index: usize = @intCast(symbol.section_number - 1);
        if (section_index >= sections.len) return error.InvalidObject;
        return .{
            .input_index = input_index,
            .section_index = section_index,
            .value = symbol.value,
        };
    }
    if (symbol.section_number != 0) return error.InvalidObject;
    if (definitions.get(symbol.name)) |definition| return definition;
    if (options.diagnostics) |diagnostics| diagnostics.recordUndefinedSymbol(input_name, symbol.name);
    return error.UndefinedSymbol;
}

fn indexExternalDefinitions(
    allocator: Allocator,
    definitions: *std.StringHashMapUnmanaged(SymbolDefinition),
    input_index: usize,
    object: Object,
) model.Error!void {
    for (object.symbols) |symbol| {
        if (symbol.storage_class != @backingInt(std.coff.StorageClass.EXTERNAL)) continue;
        if (symbol.section_number <= 0) continue;
        const section_index: usize = @intCast(symbol.section_number - 1);
        if (section_index >= object.sections.len) return error.InvalidObject;
        if (!sectionHasImageData(object.sections[section_index])) continue;
        const gop = try definitions.getOrPut(allocator, symbol.name);
        if (gop.found_existing) return error.DuplicateSymbol;
        gop.value_ptr.* = .{
            .input_index = input_index,
            .section_index = section_index,
            .value = symbol.value,
        };
    }
}

fn contributionForSection(
    contributions: []const TextContribution,
    input_index: usize,
    section_index: usize,
) ?TextContribution {
    for (contributions) |contribution| {
        if (contribution.input_index != input_index) continue;
        if (contribution.section_index != section_index) continue;
        return contribution;
    }
    return null;
}

fn layoutTextContributions(contributions: []TextContribution) model.Error!u64 {
    var text_size: u64 = 0;
    for (contributions) |*contribution| {
        text_size = try alignForward(text_size, contribution.alignment);
        contribution.output_offset = text_size;
        text_size = try checkedAddU64(text_size, contribution.bytes.len);
    }
    return text_size;
}

fn contributionForDefinition(
    contributions: []const TextContribution,
    definition: SymbolDefinition,
) ?TextContribution {
    for (contributions) |contribution| {
        if (contribution.input_index != definition.input_index) continue;
        if (contribution.section_index != definition.section_index) continue;
        return contribution;
    }
    return null;
}

fn sectionHasImageData(section: Section) bool {
    if (section.size == 0) return false;
    if (section.flags & coff_discardable_flags != 0) return false;
    if (section.flags & coff_uninitialized_data_flags != 0) return false;
    const image_flags = coff_code_flags | coff_execute_flags;
    return section.flags & image_flags != 0;
}

fn sectionData(bytes: []const u8, section: Section) model.Error![]const u8 {
    return try range(bytes, try checkedUsize(section.offset), try checkedUsize(section.size));
}

fn writePeHeaders(
    image: []u8,
    options: model.LinkOptions,
    text_size: u64,
    text_raw_size: u64,
    headers_size: u64,
    entry_rva: u32,
    size_of_image: u64,
) model.Error!void {
    image[0] = 'M';
    image[1] = 'Z';
    writeU32(image, 0x3c, pe_offset);
    @memcpy(image[pe_offset..][0..pe_signature_size], "PE\x00\x00");

    const coff_offset = pe_offset + pe_signature_size;
    writeU16(image, coff_offset, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(image, coff_offset + 2, 1);
    writeU32(image, coff_offset + 16, pe32_plus_optional_header_size);
    writeU16(image, coff_offset + 18, coff_executable_flags);

    const optional_offset = coff_offset + header_size;
    writeU16(image, optional_offset, pe32_plus_magic);
    writeU32(image, optional_offset + 4, try checkedU32FromU64(text_raw_size));
    writeU32(image, optional_offset + 16, entry_rva);
    writeU32(image, optional_offset + 20, try checkedU32FromU64(options.page_size));
    writeU64(image, optional_offset + 24, options.image_base);
    writeU32(image, optional_offset + 32, try checkedU32FromU64(options.page_size));
    writeU32(image, optional_offset + 36, coff_file_alignment);
    writeU16(image, optional_offset + 40, 6);
    writeU16(image, optional_offset + 48, 6);
    writeU32(image, optional_offset + 56, try checkedU32FromU64(size_of_image));
    writeU32(image, optional_offset + 60, try checkedU32FromU64(headers_size));
    writeU16(image, optional_offset + 68, windows_cui_subsystem);
    writeU16(image, optional_offset + 70, nx_compat_dll_characteristic);
    writeU64(image, optional_offset + 72, 0x100000);
    writeU64(image, optional_offset + 80, 0x1000);
    writeU64(image, optional_offset + 88, 0x100000);
    writeU64(image, optional_offset + 96, 0x1000);
    writeU32(image, optional_offset + 108, pe_data_directory_count);

    const section_offset = optional_offset + pe32_plus_optional_header_size;
    writeName(image, section_offset, 8, ".text");
    writeU32(image, section_offset + 8, try checkedU32FromU64(text_size));
    writeU32(image, section_offset + 12, try checkedU32FromU64(options.page_size));
    writeU32(image, section_offset + 16, try checkedU32FromU64(text_raw_size));
    writeU32(image, section_offset + 20, try checkedU32FromU64(headers_size));
    writeU32(image, section_offset + 36, coff_text_section_flags);
}

fn alignForward(value: u64, alignment: u64) model.Error!u64 {
    if (alignment == 0) return error.InvalidAlignment;
    if (!std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
    const mask = alignment - 1;
    return (try checkedAddU64(value, mask)) & ~mask;
}

fn targetFromMachine(machine: u16) model.Error!model.Target {
    return switch (@as(std.coff.IMAGE.FILE.MACHINE, @fromBackingInt(@intCast(machine)))) {
        .AMD64 => .{
            .object_format = .coff,
            .architecture = .x86_64,
            .endianness = .little,
            .pointer_width_bits = 64,
        },
        .ARM64 => .{
            .object_format = .coff,
            .architecture = .aarch64,
            .endianness = .little,
            .pointer_width_bits = 64,
        },
        else => error.UnsupportedArchitecture,
    };
}

fn coffStringTable(bytes: []const u8, symbol_table_offset: u32, symbol_count: u32) model.Error![]const u8 {
    if (symbol_table_offset == 0) return &.{};
    const symbol_bytes_len = try checkedMul(try checkedUsize(symbol_count), symbol_size);
    const string_table_offset = try checkedUsize(symbol_table_offset) + symbol_bytes_len;
    _ = try range(bytes, string_table_offset, 4);
    const string_table_size = try readU32(bytes, string_table_offset);
    if (string_table_size < 4) return error.InvalidStringTable;
    return try range(bytes, string_table_offset, try checkedUsize(string_table_size));
}

fn coffSymbolRange(bytes: []const u8, symbol_table_offset: u32, symbol_count: u32) model.Error![]const u8 {
    if (symbol_count == 0) return &.{};
    if (symbol_table_offset == 0) return error.InvalidObject;
    return try range(
        bytes,
        try checkedUsize(symbol_table_offset),
        try checkedMul(try checkedUsize(symbol_count), symbol_size),
    );
}

fn parseRelocations(
    allocator: Allocator,
    bytes: []const u8,
    architecture: model.Architecture,
    sections: []const Section,
    primary_symbol_indices: []const bool,
) model.Error![]Relocation {
    var relocation_count: usize = 0;
    for (sections) |section| {
        relocation_count = try checkedAdd(relocation_count, section.relocation_count);
    }

    const relocations = try allocator.alloc(Relocation, relocation_count);
    errdefer allocator.free(relocations);

    var cursor: usize = 0;
    for (sections, 0..) |section, section_index| {
        const relocation_range = try range(
            bytes,
            try checkedUsize(section.relocation_offset),
            try checkedMul(section.relocation_count, relocation_size),
        );
        var index: usize = 0;
        while (index < section.relocation_count) : (index += 1) {
            const offset = index * relocation_size;
            const virtual_address = std.mem.readInt(u32, relocation_range[offset..][0..4], .little);
            const symbol_table_index = std.mem.readInt(u32, relocation_range[offset + 4 ..][0..4], .little);
            const kind = std.mem.readInt(u16, relocation_range[offset + 8 ..][0..2], .little);
            if (kind != absolute_relocation_kind) {
                try validateRelocationSpan(architecture, kind, virtual_address, section.size);
                if (!isPrimarySymbolIndex(primary_symbol_indices, symbol_table_index)) {
                    return error.InvalidObject;
                }
            }
            relocations[cursor] = .{
                .section_index = section_index,
                .virtual_address = virtual_address,
                .symbol_table_index = symbol_table_index,
                .kind = kind,
            };
            cursor += 1;
        }
    }

    return relocations;
}

fn validateRelocationSpan(
    architecture: model.Architecture,
    kind: u16,
    virtual_address: u32,
    section_size: u32,
) model.Error!void {
    if (virtual_address >= section_size) return error.InvalidObject;
    if (coffRelocationWidth(architecture, kind)) |width| {
        const offset: u64 = virtual_address;
        const size: u64 = section_size;
        if (width > size - offset) return error.InvalidObject;
    }
}

fn coffRelocationWidth(architecture: model.Architecture, kind: u16) ?u64 {
    return switch (architecture) {
        .x86_64 => coffAmd64RelocationWidth(kind),
        .aarch64 => coffArm64RelocationWidth(kind),
        else => null,
    };
}

fn coffAmd64RelocationWidth(kind: u16) ?u64 {
    return switch (@as(std.coff.IMAGE.REL.AMD64, @fromBackingInt(@intCast(kind)))) {
        .ADDR64 => 8,
        .SECTION => 2,
        .SECREL7 => 1,
        .ADDR32,
        .ADDR32NB,
        .REL32,
        .REL32_1,
        .REL32_2,
        .REL32_3,
        .REL32_4,
        .REL32_5,
        .SECREL,
        .TOKEN,
        .SREL32,
        .SSPAN32,
        => 4,
        else => null,
    };
}

fn coffArm64RelocationWidth(kind: u16) ?u64 {
    return switch (@as(std.coff.IMAGE.REL.ARM64, @fromBackingInt(@intCast(kind)))) {
        .SECTION => 2,
        .ADDR64 => 8,
        .ADDR32,
        .ADDR32NB,
        .BRANCH26,
        .PAGEBASE_REL21,
        .REL21,
        .PAGEOFFSET_12A,
        .PAGEOFFSET_12L,
        .SECREL,
        .SECREL_LOW12A,
        .SECREL_HIGH12A,
        .SECREL_LOW12L,
        .TOKEN,
        .BRANCH19,
        .BRANCH14,
        .REL32,
        => 4,
        else => null,
    };
}

fn isPrimarySymbolIndex(primary_symbol_indices: []const bool, symbol_table_index: u32) bool {
    const index = std.math.cast(usize, symbol_table_index) orelse return false;
    return index < primary_symbol_indices.len and primary_symbol_indices[index];
}

fn sectionName(raw_name: *const [8]u8, string_table: []const u8) model.Error![]const u8 {
    if (raw_name[0] == '/') {
        const end = std.mem.indexOfScalar(u8, raw_name, 0) orelse raw_name.len;
        const offset = std.fmt.parseInt(u32, raw_name[1..end], 10) catch return error.InvalidStringTable;
        return try stringFromTable(string_table, offset);
    }
    return paddedName(raw_name);
}

fn symbolName(raw_name: *const [8]u8, string_table: []const u8) model.Error![]const u8 {
    if (std.mem.eql(u8, raw_name[0..4], "\x00\x00\x00\x00")) {
        return try stringFromTable(string_table, std.mem.readInt(u32, raw_name[4..8], .little));
    }
    return paddedName(raw_name);
}

fn stringFromTable(table: []const u8, offset: u32) model.Error![]const u8 {
    const start = try checkedUsize(offset);
    if (start < 4 or start >= table.len) return error.InvalidStringTable;
    const end = std.mem.indexOfScalarPos(u8, table, start, 0) orelse return error.InvalidStringTable;
    return table[start..end];
}

fn paddedName(bytes: *const [8]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

fn sectionAlignment(flags: u32) u16 {
    const encoded = @as(u4, @truncate((flags >> 20) & 0xf));
    if (encoded == 0) return 1;
    return @as(u16, 1) << (encoded - 1);
}

fn validateSymbolSectionNumber(section_number: i16, section_count: u16) model.Error!void {
    if (section_number == 0 or section_number == -1 or section_number == -2) return;
    if (section_number < 0) return error.InvalidObject;
    if (@as(u16, @intCast(section_number)) > section_count) return error.InvalidObject;
}

fn range(bytes: []const u8, offset: usize, len: usize) model.Error![]const u8 {
    if (offset > bytes.len) return error.InvalidRange;
    if (len > bytes.len - offset) return error.InvalidRange;
    return bytes[offset..][0..len];
}

fn readU16(bytes: []const u8, offset: usize) model.Error!u16 {
    return std.mem.readInt(u16, (try range(bytes, offset, 2))[0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) model.Error!u32 {
    return std.mem.readInt(u32, (try range(bytes, offset, 4))[0..4], .little);
}

fn checkedUsize(value: anytype) model.Error!usize {
    return std.math.cast(usize, value) orelse error.InvalidRange;
}

fn checkedMul(a: usize, b: usize) model.Error!usize {
    return std.math.mul(usize, a, b) catch error.InvalidRange;
}

fn checkedAdd(a: usize, b: usize) model.Error!usize {
    return std.math.add(usize, a, b) catch error.InvalidRange;
}

fn checkedAddU64(a: u64, b: u64) model.Error!u64 {
    return std.math.add(u64, a, b) catch error.InvalidRange;
}

fn checkedAddI64(a: i64, b: i64) model.Error!i64 {
    return std.math.add(i64, a, b) catch error.InvalidRange;
}

fn checkedSubI64(a: i64, b: i64) model.Error!i64 {
    return std.math.sub(i64, a, b) catch error.InvalidRange;
}

fn checkedU32FromU64(value: u64) model.Error!u32 {
    return std.math.cast(u32, value) orelse error.InvalidRange;
}

fn checkedRelocationAddU64(a: u64, b: u64) model.Error!u64 {
    return std.math.add(u64, a, b) catch error.RelocationOverflow;
}

fn checkedU32FromRelocation(value: u64) model.Error!u32 {
    return std.math.cast(u32, value) orelse error.RelocationOverflow;
}

fn checkedI64FromU64(value: u64) model.Error!i64 {
    return std.math.cast(i64, value) orelse error.InvalidRange;
}

fn checkedI32FromI64(value: i64) model.Error!i32 {
    return std.math.cast(i32, value) orelse error.RelocationOverflow;
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeI16(bytes: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

fn writeName(bytes: []u8, offset: usize, comptime size: usize, value: []const u8) void {
    @memset(bytes[offset..][0..size], 0);
    @memcpy(bytes[offset..][0..value.len], value);
}

fn fixtureObject(allocator: Allocator) ![]u8 {
    const text = "\xe8\x00\x00\x00\x00\x90\x90\xc3";
    const section_offset = header_size;
    const text_offset = header_size + section_header_size;
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_size;
    const string_name = "long_external_symbol";
    const string_table_size = 4 + string_name.len + 1;
    const string_table_offset = symbol_offset + 2 * symbol_size;
    const total_size = string_table_offset + string_table_size;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU16(bytes, 0, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(bytes, 2, 1);
    writeU32(bytes, 8, @intCast(symbol_offset));
    writeU32(bytes, 12, 2);

    writeName(bytes, section_offset, 8, ".text");
    writeU32(bytes, section_offset + 16, text.len);
    writeU32(bytes, section_offset + 20, @intCast(text_offset));
    writeU32(bytes, section_offset + 24, @intCast(relocation_offset));
    writeU16(bytes, section_offset + 32, 1);
    writeU32(bytes, section_offset + 36, 0x60500020);
    @memcpy(bytes[text_offset..][0..text.len], text);
    writeU32(bytes, relocation_offset, 1);
    writeU32(bytes, relocation_offset + 4, 0);
    writeU16(bytes, relocation_offset + 8, @backingInt(std.coff.IMAGE.REL.AMD64.REL32));

    writeName(bytes, symbol_offset, 8, "_start");
    writeU32(bytes, symbol_offset + 8, 0);
    writeI16(bytes, symbol_offset + 12, 1);
    bytes[symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);

    const long_symbol_offset = symbol_offset + symbol_size;
    writeU32(bytes, long_symbol_offset + 4, 4);
    writeU32(bytes, long_symbol_offset + 8, 1);
    writeI16(bytes, long_symbol_offset + 12, 1);
    bytes[long_symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);

    writeU32(bytes, string_table_offset, string_table_size);
    @memcpy(bytes[string_table_offset + 4 ..][0..string_name.len], string_name);
    return bytes;
}

fn fixtureRelocationOnlyObject(allocator: Allocator) ![]u8 {
    const section_offset = header_size;
    const text = "\x00\x00\x00\x00";
    const text_offset = header_size + section_header_size;
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_size;
    const string_table_offset = symbol_offset + symbol_size;
    const total_size = string_table_offset + 4;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU16(bytes, 0, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(bytes, 2, 1);
    writeU32(bytes, 8, @intCast(symbol_offset));
    writeU32(bytes, 12, 1);

    writeName(bytes, section_offset, 8, ".text");
    writeU32(bytes, section_offset + 16, text.len);
    writeU32(bytes, section_offset + 20, @intCast(text_offset));
    writeU32(bytes, section_offset + 24, @intCast(relocation_offset));
    writeU16(bytes, section_offset + 32, 1);
    writeU32(bytes, section_offset + 36, 0x60500020);
    @memcpy(bytes[text_offset..][0..text.len], text);

    writeU32(bytes, relocation_offset, 0);
    writeU32(bytes, relocation_offset + 4, 0);
    writeU16(bytes, relocation_offset + 8, @backingInt(std.coff.IMAGE.REL.AMD64.ADDR32NB));

    writeName(bytes, symbol_offset, 8, "_target");
    writeI16(bytes, symbol_offset + 12, 1);
    bytes[symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);
    writeU32(bytes, string_table_offset, 4);

    return bytes;
}

fn fixtureExecutableObject(allocator: Allocator) ![]u8 {
    const section_offset = header_size;
    const text = "\x31\xc0\xc3";
    const text_offset = header_size + section_header_size;
    const symbol_offset = text_offset + text.len;
    const string_table_offset = symbol_offset + symbol_size;
    const total_size = string_table_offset + 4;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU16(bytes, 0, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(bytes, 2, 1);
    writeU32(bytes, 8, @intCast(symbol_offset));
    writeU32(bytes, 12, 1);

    writeName(bytes, section_offset, 8, ".text");
    writeU32(bytes, section_offset + 16, text.len);
    writeU32(bytes, section_offset + 20, @intCast(text_offset));
    writeU32(bytes, section_offset + 36, 0x60500020);
    @memcpy(bytes[text_offset..][0..text.len], text);

    writeName(bytes, symbol_offset, 8, "_start");
    writeI16(bytes, symbol_offset + 12, 1);
    bytes[symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);
    writeU32(bytes, string_table_offset, 4);

    return bytes;
}

fn fixtureRel32CallerObject(allocator: Allocator) ![]u8 {
    const section_offset = header_size;
    const text = "\xe8\x00\x00\x00\x00\xc3";
    const text_offset = header_size + section_header_size;
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_size;
    const string_table_offset = symbol_offset + 2 * symbol_size;
    const total_size = string_table_offset + 4;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU16(bytes, 0, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(bytes, 2, 1);
    writeU32(bytes, 8, @intCast(symbol_offset));
    writeU32(bytes, 12, 2);

    writeName(bytes, section_offset, 8, ".text");
    writeU32(bytes, section_offset + 16, text.len);
    writeU32(bytes, section_offset + 20, @intCast(text_offset));
    writeU32(bytes, section_offset + 24, @intCast(relocation_offset));
    writeU16(bytes, section_offset + 32, 1);
    writeU32(bytes, section_offset + 36, 0x60500020);
    @memcpy(bytes[text_offset..][0..text.len], text);

    writeU32(bytes, relocation_offset, 1);
    writeU32(bytes, relocation_offset + 4, 1);
    writeU16(bytes, relocation_offset + 8, @backingInt(std.coff.IMAGE.REL.AMD64.REL32));

    writeName(bytes, symbol_offset, 8, "_start");
    writeI16(bytes, symbol_offset + 12, 1);
    bytes[symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);

    const callee_symbol_offset = symbol_offset + symbol_size;
    writeName(bytes, callee_symbol_offset, 8, "callee");
    writeI16(bytes, callee_symbol_offset + 12, 0);
    bytes[callee_symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);

    writeU32(bytes, string_table_offset, 4);
    return bytes;
}

fn fixtureRel32CalleeObject(allocator: Allocator) ![]u8 {
    const section_offset = header_size;
    const text = "\xc3";
    const text_offset = header_size + section_header_size;
    const symbol_offset = text_offset + text.len;
    const string_table_offset = symbol_offset + symbol_size;
    const total_size = string_table_offset + 4;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU16(bytes, 0, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(bytes, 2, 1);
    writeU32(bytes, 8, @intCast(symbol_offset));
    writeU32(bytes, 12, 1);

    writeName(bytes, section_offset, 8, ".text");
    writeU32(bytes, section_offset + 16, text.len);
    writeU32(bytes, section_offset + 20, @intCast(text_offset));
    writeU32(bytes, section_offset + 36, 0x60500020);
    @memcpy(bytes[text_offset..][0..text.len], text);

    writeName(bytes, symbol_offset, 8, "callee");
    writeI16(bytes, symbol_offset + 12, 1);
    bytes[symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);
    writeU32(bytes, string_table_offset, 4);

    return bytes;
}

fn fixtureAmd64AddressRelocationObject(allocator: Allocator) ![]u8 {
    const section_offset = header_size;
    const text_len = 17;
    const text_offset = header_size + section_header_size;
    const relocation_count = 3;
    const relocation_offset = text_offset + text_len;
    const symbol_offset = relocation_offset + relocation_count * relocation_size;
    const string_table_offset = symbol_offset + 2 * symbol_size;
    const total_size = string_table_offset + 4;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU16(bytes, 0, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(bytes, 2, 1);
    writeU32(bytes, 8, @intCast(symbol_offset));
    writeU32(bytes, 12, 2);

    writeName(bytes, section_offset, 8, ".text");
    writeU32(bytes, section_offset + 16, text_len);
    writeU32(bytes, section_offset + 20, @intCast(text_offset));
    writeU32(bytes, section_offset + 24, @intCast(relocation_offset));
    writeU16(bytes, section_offset + 32, relocation_count);
    writeU32(bytes, section_offset + 36, 0x60500020);
    writeU64(bytes, text_offset, 5);
    writeU32(bytes, text_offset + 8, 7);
    writeU32(bytes, text_offset + 12, 11);
    bytes[text_offset + 16] = 0xc3;

    writeU32(bytes, relocation_offset, 0);
    writeU32(bytes, relocation_offset + 4, 1);
    writeU16(bytes, relocation_offset + 8, @backingInt(std.coff.IMAGE.REL.AMD64.ADDR64));

    const addr32_relocation_offset = relocation_offset + relocation_size;
    writeU32(bytes, addr32_relocation_offset, 8);
    writeU32(bytes, addr32_relocation_offset + 4, 1);
    writeU16(bytes, addr32_relocation_offset + 8, @backingInt(std.coff.IMAGE.REL.AMD64.ADDR32));

    const rva_relocation_offset = addr32_relocation_offset + relocation_size;
    writeU32(bytes, rva_relocation_offset, 12);
    writeU32(bytes, rva_relocation_offset + 4, 1);
    writeU16(bytes, rva_relocation_offset + 8, @backingInt(std.coff.IMAGE.REL.AMD64.ADDR32NB));

    writeName(bytes, symbol_offset, 8, "_start");
    writeI16(bytes, symbol_offset + 12, 1);
    bytes[symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);

    const target_symbol_offset = symbol_offset + symbol_size;
    writeName(bytes, target_symbol_offset, 8, "target");
    writeU32(bytes, target_symbol_offset + 8, 16);
    writeI16(bytes, target_symbol_offset + 12, 1);
    bytes[target_symbol_offset + 16] = @backingInt(std.coff.StorageClass.STATIC);
    writeU32(bytes, string_table_offset, 4);

    return bytes;
}

fn fixtureRel32VariantsObject(allocator: Allocator) ![]u8 {
    const section_offset = header_size;
    const text_len = 33;
    const target_offset = 32;
    const text_offset = header_size + section_header_size;
    const relocation_count = 6;
    const relocation_offset = text_offset + text_len;
    const symbol_offset = relocation_offset + relocation_count * relocation_size;
    const string_table_offset = symbol_offset + 2 * symbol_size;
    const total_size = string_table_offset + 4;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU16(bytes, 0, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64));
    writeU16(bytes, 2, 1);
    writeU32(bytes, 8, @intCast(symbol_offset));
    writeU32(bytes, 12, 2);

    writeName(bytes, section_offset, 8, ".text");
    writeU32(bytes, section_offset + 16, text_len);
    writeU32(bytes, section_offset + 20, @intCast(text_offset));
    writeU32(bytes, section_offset + 24, @intCast(relocation_offset));
    writeU16(bytes, section_offset + 32, relocation_count);
    writeU32(bytes, section_offset + 36, 0x60500020);
    bytes[text_offset + target_offset] = 0xc3;

    const kinds = [_]std.coff.IMAGE.REL.AMD64{
        .REL32,
        .REL32_1,
        .REL32_2,
        .REL32_3,
        .REL32_4,
        .REL32_5,
    };
    for (kinds, 0..) |kind, index| {
        const current_relocation_offset = relocation_offset + index * relocation_size;
        writeU32(bytes, current_relocation_offset, @intCast(index * 4));
        writeU32(bytes, current_relocation_offset + 4, 1);
        writeU16(bytes, current_relocation_offset + 8, @backingInt(kind));
    }

    writeName(bytes, symbol_offset, 8, "_start");
    writeI16(bytes, symbol_offset + 12, 1);
    bytes[symbol_offset + 16] = @backingInt(std.coff.StorageClass.EXTERNAL);

    const target_symbol_offset = symbol_offset + symbol_size;
    writeName(bytes, target_symbol_offset, 8, "target");
    writeU32(bytes, target_symbol_offset + 8, target_offset);
    writeI16(bytes, target_symbol_offset + 12, 1);
    bytes[target_symbol_offset + 16] = @backingInt(std.coff.StorageClass.STATIC);
    writeU32(bytes, string_table_offset, 4);

    return bytes;
}

test "COFF parser reads object sections and symbols" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    var object = try parseObject(allocator, bytes);
    defer object.deinit(allocator);

    try std.testing.expectEqual(model.ObjectFormat.coff, object.target.object_format);
    try std.testing.expectEqual(model.Architecture.x86_64, object.target.architecture);
    try std.testing.expectEqual(@as(usize, 1), object.sections.len);
    try std.testing.expectEqualStrings(".text", object.sections[0].name);
    try std.testing.expectEqual(@as(u32, 8), object.sections[0].size);
    try std.testing.expectEqual(@as(u16, 16), object.sections[0].alignment);
    try std.testing.expectEqual(@as(usize, 1), object.relocations.len);
    try std.testing.expectEqual(@as(usize, 0), object.relocations[0].section_index);
    try std.testing.expectEqual(@as(u32, 1), object.relocations[0].virtual_address);
    try std.testing.expectEqual(@as(u32, 0), object.relocations[0].symbol_table_index);
    try std.testing.expectEqual(@as(u16, @backingInt(std.coff.IMAGE.REL.AMD64.REL32)), object.relocations[0].kind);
    try std.testing.expectEqual(@as(usize, 2), object.symbols.len);
    try std.testing.expectEqualStrings("_start", object.symbols[0].name);
    try std.testing.expectEqual(@as(i16, 1), object.symbols[0].section_number);
    try std.testing.expectEqualStrings("long_external_symbol", object.symbols[1].name);
    try std.testing.expectEqual(@as(u32, 1), object.symbols[1].value);
}

test "COFF metadata parser projects sections and symbols" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    var object = try parseObjectMetadata(allocator, bytes);
    defer object.deinit(allocator);

    try std.testing.expectEqual(model.ObjectFormat.coff, object.target.object_format);
    try std.testing.expectEqual(@as(usize, 1), object.sections.len);
    try std.testing.expectEqualStrings(".text", object.sections[0].name);
    try std.testing.expectEqual(@as(u64, 8), object.sections[0].size);
    try std.testing.expectEqual(@as(usize, 2), object.symbols.len);
    try std.testing.expectEqualStrings("_start", object.symbols[0].name);
    try std.testing.expectEqual(@as(i32, 1), object.symbols[0].section_index);
    try std.testing.expect(object.symbols[0].external);
}

test "COFF linker emits a minimal PE executable" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureExecutableObject(allocator);
    defer allocator.free(bytes);

    var linked = try root.link(
        allocator,
        &.{.{ .name = "start.obj", .bytes = bytes }},
        .{ .target = .windows_x86_64_coff },
    );
    defer linked.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 'M'), linked.bytes[0]);
    try std.testing.expectEqual(@as(u8, 'Z'), linked.bytes[1]);
    const actual_pe_offset = try readU32(linked.bytes, 0x3c);
    try std.testing.expectEqual(@as(u32, pe_offset), actual_pe_offset);
    const pe_start: usize = @intCast(actual_pe_offset);
    try std.testing.expectEqualSlices(u8, "PE\x00\x00", linked.bytes[pe_start..][0..4]);

    const coff_offset = pe_start + pe_signature_size;
    try std.testing.expectEqual(@as(u16, @backingInt(std.coff.IMAGE.FILE.MACHINE.AMD64)), try readU16(linked.bytes, coff_offset));
    try std.testing.expectEqual(@as(u16, 1), try readU16(linked.bytes, coff_offset + 2));
    try std.testing.expectEqual(@as(u16, pe32_plus_optional_header_size), try readU16(linked.bytes, coff_offset + 16));

    const optional_offset = coff_offset + header_size;
    try std.testing.expectEqual(@as(u16, pe32_plus_magic), try readU16(linked.bytes, optional_offset));
    try std.testing.expectEqual(@as(u32, 0x1000), try readU32(linked.bytes, optional_offset + 16));
    try std.testing.expectEqual(@as(u64, 0x400000), std.mem.readInt(u64, linked.bytes[optional_offset + 24 ..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 0x1000), try readU32(linked.bytes, optional_offset + 32));
    try std.testing.expectEqual(@as(u32, coff_file_alignment), try readU32(linked.bytes, optional_offset + 36));

    const section_offset = optional_offset + pe32_plus_optional_header_size;
    try std.testing.expectEqualSlices(u8, ".text", linked.bytes[section_offset..][0..5]);
    try std.testing.expectEqual(@as(u32, 3), try readU32(linked.bytes, section_offset + 8));
    try std.testing.expectEqual(@as(u32, 0x1000), try readU32(linked.bytes, section_offset + 12));
    try std.testing.expectEqual(@as(u32, coff_file_alignment), try readU32(linked.bytes, section_offset + 16));
    const raw_offset = try readU32(linked.bytes, section_offset + 20);
    try std.testing.expectEqual(@as(u32, coff_file_alignment), raw_offset);
    try std.testing.expectEqualSlices(u8, "\x31\xc0\xc3", linked.bytes[@as(usize, @intCast(raw_offset))..][0..3]);

    try std.testing.expectEqual(model.ObjectFormat.coff, linked.manifest.target.object_format);
    try std.testing.expectEqual(@as(usize, 1), linked.manifest.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), linked.manifest.sections.len);
    try std.testing.expectEqual(@as(usize, 1), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings(".text", linked.manifest.string(linked.manifest.sections[0].name_id));
    try std.testing.expectEqual(@as(u64, 0x401000), linked.manifest.sections[0].address);
    try std.testing.expectEqual(@as(u64, coff_file_alignment), linked.manifest.sections[0].file_offset);
}

test "COFF linker applies x86_64 REL32 relocations" {
    const allocator = std.testing.allocator;
    const caller = try fixtureRel32CallerObject(allocator);
    defer allocator.free(caller);
    const callee = try fixtureRel32CalleeObject(allocator);
    defer allocator.free(callee);

    var linked = try root.link(
        allocator,
        &.{
            .{ .name = "caller.obj", .bytes = caller },
            .{ .name = "callee.obj", .bytes = callee },
        },
        .{ .target = .windows_x86_64_coff },
    );
    defer linked.deinit(allocator);

    const text = linked.manifest.sections[0];
    const text_offset: usize = @intCast(text.file_offset);
    try std.testing.expectEqual(@as(u64, 17), text.size);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[text_offset + 1 ..][0..4], .little));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[text_offset + 5]);
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[text_offset + 16]);
    try std.testing.expectEqual(@as(usize, 2), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings("caller.obj", linked.manifest.string(linked.manifest.contributions[0].input_name_id));
    try std.testing.expectEqualStrings("callee.obj", linked.manifest.string(linked.manifest.contributions[1].input_name_id));
}

test "COFF linker applies x86_64 absolute and RVA relocations" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureAmd64AddressRelocationObject(allocator);
    defer allocator.free(bytes);

    var linked = try root.link(
        allocator,
        &.{.{ .name = "addresses.obj", .bytes = bytes }},
        .{ .target = .windows_x86_64_coff },
    );
    defer linked.deinit(allocator);

    const text = linked.manifest.sections[0];
    const text_offset: usize = @intCast(text.file_offset);
    try std.testing.expectEqual(@as(u64, 17), text.size);
    try std.testing.expectEqual(@as(u64, 0x401015), std.mem.readInt(u64, linked.bytes[text_offset..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 0x401017), try readU32(linked.bytes, text_offset + 8));
    try std.testing.expectEqual(@as(u32, 0x101b), try readU32(linked.bytes, text_offset + 12));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[text_offset + 16]);
}

test "COFF linker applies x86_64 REL32 variant relocations" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureRel32VariantsObject(allocator);
    defer allocator.free(bytes);

    var linked = try root.link(
        allocator,
        &.{.{ .name = "rel32-variants.obj", .bytes = bytes }},
        .{ .target = .windows_x86_64_coff },
    );
    defer linked.deinit(allocator);

    const text = linked.manifest.sections[0];
    const text_offset: usize = @intCast(text.file_offset);
    const expected = [_]i32{ 28, 23, 18, 13, 8, 3 };
    try std.testing.expectEqual(@as(u64, 33), text.size);
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, std.mem.readInt(i32, linked.bytes[text_offset + index * 4 ..][0..4], .little));
    }
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[text_offset + 32]);
}

test "COFF linker records unsupported relocation diagnostics" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureRelocationOnlyObject(allocator);
    defer allocator.free(bytes);
    const relocation_offset = header_size + section_header_size + 4;
    writeU16(bytes, relocation_offset + 8, @backingInt(std.coff.IMAGE.REL.AMD64.TOKEN));

    var diagnostics: model.Diagnostics = .{};
    try std.testing.expectError(
        error.UnsupportedRelocation,
        root.link(
            allocator,
            &.{.{ .name = "reloc.obj", .bytes = bytes }},
            .{
                .target = .windows_x86_64_coff,
                .entry_symbol = "_target",
                .diagnostics = &diagnostics,
            },
        ),
    );

    const failure = diagnostics.linkFailure(error.UnsupportedRelocation);
    const relocation = switch (failure) {
        .unsupported_relocation => |relocation| relocation,
        else => return error.ExpectedUnsupportedRelocationDiagnostic,
    };
    try std.testing.expectEqual(@as(u32, 13), relocation.relocation_type);
    try std.testing.expectEqualStrings("reloc.obj", relocation.input_name);
    try std.testing.expectEqualStrings(".text", relocation.section_name);
    try std.testing.expectEqualStrings("_target", relocation.symbol_name);
}

test "COFF parser rejects truncated section data" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    try std.testing.expectError(error.InvalidRange, parseObject(allocator, bytes[0 .. header_size + section_header_size + 1]));
}

test "COFF parser accepts packed relocation entries" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureRelocationOnlyObject(allocator);
    defer allocator.free(bytes);

    var object = try parseObject(allocator, bytes);
    defer object.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), object.relocations.len);
    try std.testing.expectEqual(@as(u32, 0), object.relocations[0].virtual_address);
    try std.testing.expectEqual(@as(u16, @backingInt(std.coff.IMAGE.REL.AMD64.ADDR32NB)), object.relocations[0].kind);
}

test "COFF parser rejects invalid relocation symbol references" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureRelocationOnlyObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + section_header_size + 4;
    writeU32(bytes, relocation_offset + 4, 1);

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "COFF parser rejects relocations outside section data" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureRelocationOnlyObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + section_header_size + 4;
    writeU32(bytes, relocation_offset, 4);

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "COFF parser rejects relocations that extend past section data" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + section_header_size + 8;
    writeU32(bytes, relocation_offset, 5);

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "COFF parser rejects relocation targets inside auxiliary symbol records" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + section_header_size + 8;
    const symbol_offset = relocation_offset + relocation_size;
    writeU32(bytes, relocation_offset + 4, 1);
    bytes[symbol_offset + 17] = 1;

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "COFF parser rejects invalid symbol section references" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const symbol_offset = header_size + section_header_size + 8 + relocation_size;
    writeI16(bytes, symbol_offset + 12, 2);

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}
