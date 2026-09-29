const std = @import("std");
const root = @import("../root.zig");
const model = root.model;
const trace = root.trace;

const Allocator = std.mem.Allocator;

const header_size = @sizeOf(std.macho.mach_header_64);
const load_command_size = @sizeOf(std.macho.load_command);
const segment_command_64_size = @sizeOf(std.macho.segment_command_64);
const section_64_size = @sizeOf(std.macho.section_64);
const symtab_command_size = @sizeOf(std.macho.symtab_command);
const entry_point_command_size = @sizeOf(std.macho.entry_point_command);
const nlist_64_size = @sizeOf(std.macho.nlist_64);
const relocation_info_size = @sizeOf(std.macho.relocation_info);
const macho_text_protection = 0x5;

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
    segment_name: []const u8,
    name: []const u8,
    address: u64,
    size: u64,
    offset: u32,
    alignment_shift: u32,
    relocation_offset: u32,
    relocation_count: u32,
    flags: u32,
};

pub const Relocation = struct {
    section_index: usize,
    address: i32,
    symbol_number: u32,
    pc_relative: bool,
    length: u8,
    external: bool,
    kind: u8,
};

pub const Symbol = struct {
    name: []const u8,
    section_index: u8,
    value: u64,
    kind: u8,
    external: bool,
};

const SymtabCommand = struct {
    symbol_offset: u32,
    symbol_count: u32,
    string_offset: u32,
    string_size: u32,
};

const TextContribution = struct {
    input_name: []const u8,
    input_index: usize,
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
    value: u64,
};

pub fn linkExecutable(
    allocator: Allocator,
    inputs: []const model.Input,
    options: model.LinkOptions,
) model.Error!root.LinkedImage {
    const link_phase = trace.scope("link.macho");
    defer link_phase.end();
    if (options.diagnostics) |diagnostics| diagnostics.clear();
    if (options.output_kind != .executable) return error.UnsupportedOutputKind;
    if (options.target.architecture != .x86_64 or options.target.endianness != .little) {
        return error.UnsupportedArchitecture;
    }
    if (options.gc_sections or options.icf != .off) return error.UnsupportedFormat;
    if (inputs.len == 0) return error.NoAllocSections;

    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var manifest_builder = build_manifest: {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        var builder = try root.incremental.Builder.init(allocator, options);
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
        if (object.target.object_format != .macho) return error.UnsupportedFormat;
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

    const load_size = segment_command_64_size + section_64_size + entry_point_command_size;
    const text_file_offset = try alignForward(header_size + load_size, 16);
    const entry_file_offset = try checkedAddU64(text_file_offset, try checkedAddU64(entry.contribution.output_offset, entry.definition.value));
    const total_size = try checkedAddU64(text_file_offset, text_size);
    const text_vmaddr = try checkedAddU64(options.image_base, text_file_offset);
    const text_vmsize = try alignForward(total_size, options.page_size);

    const image = try allocator.alloc(u8, try checkedUsize(total_size));
    errdefer allocator.free(image);
    {
        const write_phase = trace.product(.output_writing);
        defer write_phase.end();
        @memset(image, 0);

        try writeExecutableHeaders(
            image,
            options,
            load_size,
            text_file_offset,
            entry_file_offset,
            total_size,
            text_vmsize,
            text_size,
        );

        for (contributions.items) |contribution| {
            const start = try checkedUsize(try checkedAddU64(text_file_offset, contribution.output_offset));
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
                "__TEXT,__text",
                try checkedAddU64(text_vmaddr, contribution.output_offset),
                try checkedAddU64(text_file_offset, contribution.output_offset),
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
        text_file_offset,
        text_vmaddr,
    );

    {
        const manifest_phase = trace.product(.manifest_recording);
        defer manifest_phase.end();
        try manifest_builder.addSection(
            "__TEXT,__text",
            text_vmaddr,
            text_file_offset,
            text_size,
            text_size,
            16,
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
    const magic = try readU32(bytes, 0);
    if (magic != std.macho.MH_MAGIC_64) return error.UnsupportedFormat;

    const filetype = try readU32(bytes, 12);
    if (filetype != std.macho.MH_OBJECT) return error.UnsupportedFormat;

    const target = try targetFromCpuType(try readU32(bytes, 4));
    const command_count = try readU32(bytes, 16);
    const command_bytes_len = try readU32(bytes, 20);
    const command_start: usize = header_size;
    const command_end = command_start + try checkedUsize(command_bytes_len);
    _ = try range(bytes, command_start, try checkedUsize(command_bytes_len));

    var section_count: usize = 0;
    var symtab: ?SymtabCommand = null;
    var command_offset = command_start;
    var command_index: u32 = 0;
    while (command_index < command_count) : (command_index += 1) {
        const command = try readU32(bytes, command_offset);
        const command_size = try readU32(bytes, command_offset + 4);
        const command_len = try checkedUsize(command_size);
        if (command_len < load_command_size) return error.InvalidObject;
        _ = try range(bytes, command_offset, command_len);
        if (command_offset + command_len > command_end) return error.InvalidRange;

        if (command == @backingInt(std.macho.LC.SEGMENT_64)) {
            if (command_len < segment_command_64_size) return error.InvalidObject;
            const sections_in_segment = try readU32(bytes, command_offset + 64);
            const required_size = segment_command_64_size + try checkedMul(try checkedUsize(sections_in_segment), section_64_size);
            if (command_len < required_size) return error.InvalidObject;
            section_count += try checkedUsize(sections_in_segment);
        } else if (command == @backingInt(std.macho.LC.SYMTAB)) {
            if (command_len < symtab_command_size) return error.InvalidObject;
            if (symtab != null) return error.InvalidObject;
            symtab = .{
                .symbol_offset = try readU32(bytes, command_offset + 8),
                .symbol_count = try readU32(bytes, command_offset + 12),
                .string_offset = try readU32(bytes, command_offset + 16),
                .string_size = try readU32(bytes, command_offset + 20),
            };
        }

        command_offset += command_len;
    }
    if (command_offset != command_end) return error.InvalidRange;

    const sections = try allocator.alloc(Section, section_count);
    errdefer allocator.free(sections);
    var section_cursor: usize = 0;

    command_offset = command_start;
    command_index = 0;
    while (command_index < command_count) : (command_index += 1) {
        const command = try readU32(bytes, command_offset);
        const command_len = try checkedUsize(try readU32(bytes, command_offset + 4));
        if (command == @backingInt(std.macho.LC.SEGMENT_64)) {
            const sections_in_segment = try checkedUsize(try readU32(bytes, command_offset + 64));
            var section_offset = command_offset + segment_command_64_size;
            var index: usize = 0;
            while (index < sections_in_segment) : (index += 1) {
                const size = try readU64(bytes, section_offset + 40);
                const data_offset = try readU32(bytes, section_offset + 48);
                const relocation_offset = try readU32(bytes, section_offset + 56);
                const relocation_count = try readU32(bytes, section_offset + 60);
                if (size != 0 and data_offset != 0) {
                    _ = try range(bytes, try checkedUsize(data_offset), try checkedUsize(size));
                }
                if (relocation_count != 0) {
                    _ = try range(
                        bytes,
                        try checkedUsize(relocation_offset),
                        try checkedMul(try checkedUsize(relocation_count), relocation_info_size),
                    );
                }
                sections[section_cursor] = .{
                    .segment_name = paddedName((try range(bytes, section_offset + 16, 16))[0..16]),
                    .name = paddedName((try range(bytes, section_offset, 16))[0..16]),
                    .address = try readU64(bytes, section_offset + 32),
                    .size = size,
                    .offset = data_offset,
                    .alignment_shift = try readU32(bytes, section_offset + 52),
                    .relocation_offset = relocation_offset,
                    .relocation_count = relocation_count,
                    .flags = try readU32(bytes, section_offset + 64),
                };
                section_cursor += 1;
                section_offset += section_64_size;
            }
        }
        command_offset += command_len;
    }

    const relocations = try parseRelocations(
        allocator,
        bytes,
        sections,
        if (symtab) |table| table.symbol_count else 0,
    );
    errdefer if (relocations.len != 0) allocator.free(relocations);

    const symbols: []Symbol = if (symtab) |table| blk: {
        const string_table = try range(bytes, try checkedUsize(table.string_offset), try checkedUsize(table.string_size));
        const symbol_bytes_len = try checkedMul(try checkedUsize(table.symbol_count), nlist_64_size);
        _ = try range(bytes, try checkedUsize(table.symbol_offset), symbol_bytes_len);

        const parsed_symbols = try allocator.alloc(Symbol, try checkedUsize(table.symbol_count));
        errdefer allocator.free(parsed_symbols);
        var index: usize = 0;
        while (index < parsed_symbols.len) : (index += 1) {
            const symbol_offset = try checkedUsize(table.symbol_offset) + index * nlist_64_size;
            const symbol_kind = (try range(bytes, symbol_offset + 4, 1))[0];
            const section_index = (try range(bytes, symbol_offset + 5, 1))[0];
            try validateSymbolSectionIndex(symbol_kind, section_index, sections.len);
            parsed_symbols[index] = .{
                .name = try stringFromTable(string_table, try readU32(bytes, symbol_offset)),
                .section_index = section_index,
                .value = try readU64(bytes, symbol_offset + 8),
                .kind = symbol_kind,
                .external = symbol_kind & 0x1 != 0,
            };
        }
        break :blk parsed_symbols;
    } else try allocator.alloc(Symbol, 0);
    errdefer if (symbols.len != 0) allocator.free(symbols);

    return .{
        .target = target,
        .sections = sections,
        .relocations = relocations,
        .symbols = symbols,
        .string_table = if (symtab) |table| try range(bytes, try checkedUsize(table.string_offset), try checkedUsize(table.string_size)) else &.{},
    };
}

pub fn parseObjectMetadata(allocator: Allocator, bytes: []const u8) model.Error!root.Object {
    var object = try parseObject(allocator, bytes);
    defer object.deinit(allocator);

    const sections = try allocator.alloc(root.ObjectSection, object.sections.len);
    errdefer allocator.free(sections);
    for (sections, object.sections) |*section, source| {
        section.* = .{
            .segment_name = source.segment_name,
            .name = source.name,
            .address = source.address,
            .size = source.size,
            .offset = source.offset,
            .alignment = try alignmentFromShift(source.alignment_shift),
            .flags = source.flags,
            .relocation_count = source.relocation_count,
        };
    }

    const symbols = try allocator.alloc(root.ObjectSymbol, object.symbols.len);
    errdefer allocator.free(symbols);
    for (symbols, object.symbols) |*symbol, source| {
        symbol.* = .{
            .name = source.name,
            .section_index = source.section_index,
            .value = source.value,
            .kind = source.kind,
            .binding = @intFromBool(source.external),
            .external = source.external,
            .undefined = source.section_index == 0,
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
            .input_name = input.name,
            .input_index = input_index,
            .section_index = section_index,
            .section_name = section.name,
            .bytes = try sectionData(input.bytes, section),
            .alignment = try alignmentFromShift(section.alignment_shift),
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
    text_vmaddr: u64,
) model.Error!void {
    const phase = trace.product(.relocation_application);
    defer phase.end();
    const branch_kind: u8 = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH));
    const unsigned_kind: u8 = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_UNSIGNED));
    for (objects) |link_object| {
        for (link_object.object.relocations) |relocation| {
            if (relocation.section_index >= link_object.object.sections.len) return error.InvalidObject;
            const section = link_object.object.sections[relocation.section_index];
            if (!sectionHasImageData(section)) continue;
            const pcrel_offset = signedRelocationOffset(relocation.kind);
            const supported_branch_pcrel32 = relocation.kind == branch_kind and relocation.pc_relative and relocation.length == 2;
            const supported_signed_pcrel32 = pcrel_offset != null and relocation.pc_relative and relocation.length == 2;
            const supported_unsigned = relocation.kind == unsigned_kind and !relocation.pc_relative and (relocation.length == 2 or relocation.length == 3);
            const supported_external = relocation.external and (supported_branch_pcrel32 or supported_signed_pcrel32 or supported_unsigned);
            const supported_local = !relocation.external and (supported_signed_pcrel32 or supported_unsigned);
            if (!supported_external and !supported_local) {
                if (options.diagnostics) |diagnostics| {
                    diagnostics.recordUnsupportedRelocation(
                        link_object.input_name,
                        section.name,
                        relocationSymbolName(link_object.object, relocation),
                        relocation.kind,
                    );
                }
                return error.UnsupportedRelocation;
            }

            const source = contributionForSection(
                contributions,
                link_object.input_index,
                relocation.section_index,
            ) orelse return error.InvalidObject;
            if (supported_local) {
                const target_section_index = try relocationTargetSectionIndex(relocation, link_object.object.sections.len);
                const target_section = link_object.object.sections[target_section_index];
                if (!sectionHasImageData(target_section)) {
                    if (options.diagnostics) |diagnostics| {
                        diagnostics.recordUnsupportedRelocation(
                            link_object.input_name,
                            section.name,
                            relocationSymbolName(link_object.object, relocation),
                            relocation.kind,
                        );
                    }
                    return error.UnsupportedRelocation;
                }
                const target_contribution = contributionForSection(
                    contributions,
                    link_object.input_index,
                    target_section_index,
                ) orelse return error.InvalidObject;
                const target_vmaddr = try checkedAddU64(text_vmaddr, target_contribution.output_offset);
                if (supported_unsigned) {
                    try applyUnsignedRelocation(image, text_file_offset, source, relocation, target_vmaddr, target_section.address);
                } else {
                    try applyLocalPcrel32Relocation(
                        image,
                        text_file_offset,
                        text_vmaddr,
                        source,
                        section,
                        relocation,
                        target_contribution,
                        target_section,
                        pcrel_offset orelse 0,
                    );
                }
                continue;
            }
            const symbol = symbolByIndex(link_object.object.symbols, relocation.symbol_number) orelse return error.InvalidObject;
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
            const target_vmaddr = try checkedAddU64(
                text_vmaddr,
                try checkedAddU64(target_contribution.output_offset, target.value),
            );
            if (supported_unsigned) {
                try applyUnsignedRelocation(image, text_file_offset, source, relocation, target_vmaddr, 0);
            } else {
                try applyPcrel32Relocation(
                    image,
                    text_file_offset,
                    text_vmaddr,
                    source,
                    relocation,
                    target_vmaddr,
                    pcrel_offset orelse 0,
                );
            }
        }
    }
}

fn signedRelocationOffset(kind: u8) ?u64 {
    if (kind == @backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_SIGNED)) return 0;
    if (kind == @backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_SIGNED_1)) return 1;
    if (kind == @backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_SIGNED_2)) return 2;
    if (kind == @backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_SIGNED_4)) return 4;
    return null;
}

fn applyPcrel32Relocation(
    image: []u8,
    text_file_offset: u64,
    text_vmaddr: u64,
    source: TextContribution,
    relocation: Relocation,
    target_vmaddr: u64,
    pcrel_offset: u64,
) model.Error!void {
    const patch_index = try relocationPatchIndex(image, text_file_offset, source, relocation, 4);
    const relocation_offset: u64 = @intCast(relocation.address);
    const place_vmaddr = try checkedAddU64(
        text_vmaddr,
        try checkedAddU64(source.output_offset, relocation_offset),
    );
    const addend = try checkedAddI64(
        std.mem.readInt(i32, image[patch_index..][0..4], .little),
        try checkedI64FromU64(pcrel_offset),
    );
    const pc = try checkedAddU64(try checkedAddU64(place_vmaddr, 4), pcrel_offset);
    const value = try checkedSubI64(
        try checkedAddI64(try checkedI64FromU64(target_vmaddr), addend),
        try checkedI64FromU64(pc),
    );
    std.mem.writeInt(i32, image[patch_index..][0..4], try checkedI32FromI64(value), .little);
}

fn applyLocalPcrel32Relocation(
    image: []u8,
    text_file_offset: u64,
    text_vmaddr: u64,
    source: TextContribution,
    source_section: Section,
    relocation: Relocation,
    target: TextContribution,
    target_section: Section,
    pcrel_offset: u64,
) model.Error!void {
    const patch_index = try relocationPatchIndex(image, text_file_offset, source, relocation, 4);
    const relocation_offset: u64 = @intCast(relocation.address);
    const embedded_addend = try checkedAddI64(
        std.mem.readInt(i32, image[patch_index..][0..4], .little),
        try checkedI64FromU64(pcrel_offset),
    );
    const input_reloc_base = try checkedAddU64(
        source_section.address,
        try checkedAddU64(relocation_offset, 4),
    );
    const input_referent = try checkedAddI64(try checkedI64FromU64(input_reloc_base), embedded_addend);
    const target_offset_i64 = try checkedSubI64(input_referent, try checkedI64FromU64(target_section.address));
    if (target_offset_i64 < 0) return error.InvalidRange;
    const target_offset: u64 = @intCast(target_offset_i64);
    if (target_offset > target.bytes.len) return error.InvalidRange;

    const target_vmaddr = try checkedAddU64(
        text_vmaddr,
        try checkedAddU64(target.output_offset, target_offset),
    );
    const place_vmaddr = try checkedAddU64(
        text_vmaddr,
        try checkedAddU64(source.output_offset, relocation_offset),
    );
    const pc = try checkedAddU64(try checkedAddU64(place_vmaddr, 4), pcrel_offset);
    const value = try checkedSubI64(try checkedI64FromU64(target_vmaddr), try checkedI64FromU64(pc));
    std.mem.writeInt(i32, image[patch_index..][0..4], try checkedI32FromI64(value), .little);
}

fn applyUnsignedRelocation(
    image: []u8,
    text_file_offset: u64,
    source: TextContribution,
    relocation: Relocation,
    target_vmaddr: u64,
    target_section_address: u64,
) model.Error!void {
    if (relocation.length == 2) {
        const patch_index = try relocationPatchIndex(image, text_file_offset, source, relocation, 4);
        const addend = offsetFromSectionAddress(std.mem.readInt(u32, image[patch_index..][0..4], .little), target_section_address);
        const value = try checkedRelocationAddU64(target_vmaddr, addend);
        std.mem.writeInt(u32, image[patch_index..][0..4], try checkedU32FromRelocation(value), .little);
    } else if (relocation.length == 3) {
        const patch_index = try relocationPatchIndex(image, text_file_offset, source, relocation, 8);
        const addend = offsetFromSectionAddress(std.mem.readInt(u64, image[patch_index..][0..8], .little), target_section_address);
        std.mem.writeInt(u64, image[patch_index..][0..8], try checkedRelocationAddU64(target_vmaddr, addend), .little);
    } else {
        return error.UnsupportedRelocation;
    }
}

fn relocationPatchIndex(
    image: []const u8,
    text_file_offset: u64,
    source: TextContribution,
    relocation: Relocation,
    width: usize,
) model.Error!usize {
    if (relocation.address < 0) return error.InvalidObject;
    const relocation_offset: u64 = @intCast(relocation.address);
    const patch_file_offset = try checkedAddU64(
        text_file_offset,
        try checkedAddU64(source.output_offset, relocation_offset),
    );
    const patch_index = try checkedUsize(patch_file_offset);
    if (patch_index > image.len or width > image.len - patch_index) return error.InvalidRange;
    return patch_index;
}

fn symbolByIndex(symbols: []const Symbol, raw_index: u32) ?Symbol {
    const index = std.math.cast(usize, raw_index) orelse return null;
    if (index >= symbols.len) return null;
    return symbols[index];
}

fn relocationTargetSectionIndex(relocation: Relocation, section_count: usize) model.Error!usize {
    if (relocation.symbol_number == 0) return error.InvalidObject;
    const index = try checkedUsize(relocation.symbol_number - 1);
    if (index >= section_count) return error.InvalidObject;
    return index;
}

fn definitionForRelocationSymbol(
    definitions: *const std.StringHashMapUnmanaged(SymbolDefinition),
    input_name: []const u8,
    input_index: usize,
    sections: []const Section,
    symbol: Symbol,
    options: model.LinkOptions,
) model.Error!SymbolDefinition {
    if ((symbol.kind & std.macho.N_TYPE) == std.macho.N_SECT) {
        const section_index: usize = @intCast(symbol.section_index - 1);
        if (section_index >= sections.len) return error.InvalidObject;
        return .{
            .input_index = input_index,
            .section_index = section_index,
            .value = try symbolOffsetInSection(sections[section_index], symbol),
        };
    }
    if (definitions.get(symbol.name)) |definition| return definition;
    if (options.diagnostics) |diagnostics| diagnostics.recordUndefinedSymbol(input_name, symbol.name);
    return error.UndefinedSymbol;
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

fn relocationSymbolName(object: Object, relocation: Relocation) []const u8 {
    if (relocation.external) {
        const index = std.math.cast(usize, relocation.symbol_number) orelse return "";
        if (index < object.symbols.len) return object.symbols[index].name;
        return "";
    }
    if (relocation.symbol_number == 0) return "";
    const section_index: usize = @intCast(relocation.symbol_number - 1);
    if (section_index < object.sections.len) return object.sections[section_index].name;
    return "";
}

fn indexExternalDefinitions(
    allocator: Allocator,
    definitions: *std.StringHashMapUnmanaged(SymbolDefinition),
    input_index: usize,
    object: Object,
) model.Error!void {
    for (object.symbols) |symbol| {
        if (!symbol.external) continue;
        if ((symbol.kind & std.macho.N_TYPE) != std.macho.N_SECT) continue;
        if (symbol.section_index == 0) continue;
        const section_index: usize = @intCast(symbol.section_index - 1);
        if (section_index >= object.sections.len) return error.InvalidObject;
        const section = object.sections[section_index];
        if (!sectionHasImageData(section)) continue;
        const gop = try definitions.getOrPut(allocator, symbol.name);
        if (gop.found_existing) return error.DuplicateSymbol;
        gop.value_ptr.* = .{
            .input_index = input_index,
            .section_index = section_index,
            .value = try symbolOffsetInSection(section, symbol),
        };
    }
}

fn symbolOffsetInSection(section: Section, symbol: Symbol) model.Error!u64 {
    return offsetFromSectionAddress(symbol.value, section.address);
}

fn offsetFromSectionAddress(value: u64, section_address: u64) u64 {
    if (value >= section_address) return value - section_address;
    return value;
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
    if (!std.mem.eql(u8, section.segment_name, "__TEXT")) return false;
    if (std.mem.eql(u8, section.name, "__text")) return true;
    return section.flags & (std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS) != 0;
}

fn sectionData(bytes: []const u8, section: Section) model.Error![]const u8 {
    return try range(bytes, try checkedUsize(section.offset), try checkedUsize(section.size));
}

fn writeExecutableHeaders(
    image: []u8,
    options: model.LinkOptions,
    load_size: usize,
    text_file_offset: u64,
    entry_file_offset: u64,
    total_size: u64,
    text_vmsize: u64,
    text_size: u64,
) model.Error!void {
    writeU32(image, 0, std.macho.MH_MAGIC_64);
    writeU32(image, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(image, 8, @bitCast(std.macho.CPU_SUBTYPE_X86_64_ALL));
    writeU32(image, 12, std.macho.MH_EXECUTE);
    writeU32(image, 16, 2);
    writeU32(image, 20, @intCast(load_size));
    writeU32(image, 24, std.macho.MH_NOUNDEFS);

    const segment_offset = header_size;
    writeU32(image, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(image, segment_offset + 4, segment_command_64_size + section_64_size);
    writeName(image, segment_offset + 8, 16, "__TEXT");
    writeU64(image, segment_offset + 24, options.image_base);
    writeU64(image, segment_offset + 32, text_vmsize);
    writeU64(image, segment_offset + 40, 0);
    writeU64(image, segment_offset + 48, total_size);
    writeU32(image, segment_offset + 56, macho_text_protection);
    writeU32(image, segment_offset + 60, macho_text_protection);
    writeU32(image, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(image, section_offset, 16, "__text");
    writeName(image, section_offset + 16, 16, "__TEXT");
    writeU64(image, section_offset + 32, try checkedAddU64(options.image_base, text_file_offset));
    writeU64(image, section_offset + 40, text_size);
    writeU32(image, section_offset + 48, try checkedU32FromU64(text_file_offset));
    writeU32(image, section_offset + 52, 4);
    writeU32(image, section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);

    const entry_offset = section_offset + section_64_size;
    writeU32(image, entry_offset, @backingInt(std.macho.LC.MAIN));
    writeU32(image, entry_offset + 4, entry_point_command_size);
    writeU64(image, entry_offset + 8, entry_file_offset);
}

fn targetFromCpuType(cpu_type: u32) model.Error!model.Target {
    return switch (@as(std.macho.cpu_type_t, @bitCast(cpu_type))) {
        std.macho.CPU_TYPE_X86_64 => .{
            .object_format = .macho,
            .architecture = .x86_64,
            .endianness = .little,
            .pointer_width_bits = 64,
        },
        std.macho.CPU_TYPE_ARM64 => .{
            .object_format = .macho,
            .architecture = .aarch64,
            .endianness = .little,
            .pointer_width_bits = 64,
        },
        else => error.UnsupportedArchitecture,
    };
}

fn alignmentFromShift(shift: u32) model.Error!u64 {
    if (shift >= 63) return error.InvalidAlignment;
    return @as(u64, 1) << @intCast(shift);
}

fn paddedName(bytes: *const [16]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

fn stringFromTable(table: []const u8, offset: u32) model.Error![]const u8 {
    if (offset == 0) return "";
    const start = try checkedUsize(offset);
    if (start >= table.len) return error.InvalidStringTable;
    const end = std.mem.indexOfScalarPos(u8, table, start, 0) orelse return error.InvalidStringTable;
    return table[start..end];
}

fn validateSymbolSectionIndex(kind: u8, section_index: u8, section_count: usize) model.Error!void {
    if ((kind & std.macho.N_TYPE) == std.macho.N_SECT) {
        if (section_index == 0 or section_index > section_count) return error.InvalidObject;
    } else if (section_index != 0) {
        return error.InvalidObject;
    }
}

fn parseRelocations(
    allocator: Allocator,
    bytes: []const u8,
    sections: []const Section,
    symbol_count: u32,
) model.Error![]Relocation {
    var relocation_count: usize = 0;
    for (sections) |section| {
        relocation_count = try checkedAdd(relocation_count, try checkedUsize(section.relocation_count));
    }

    const relocations = try allocator.alloc(Relocation, relocation_count);
    errdefer if (relocations.len != 0) allocator.free(relocations);

    var cursor: usize = 0;
    for (sections, 0..) |section, section_index| {
        const count = try checkedUsize(section.relocation_count);
        if (count == 0) continue;
        const relocation_range = try range(
            bytes,
            try checkedUsize(section.relocation_offset),
            try checkedMul(count, relocation_info_size),
        );
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const offset = index * relocation_info_size;
            const encoded = std.mem.readInt(u32, relocation_range[offset + 4 ..][0..4], .little);
            const symbol_number = encoded & 0x00ff_ffff;
            const external = ((encoded >> 27) & 0x1) != 0;
            const address = std.mem.readInt(i32, relocation_range[offset..][0..4], .little);
            const length: u8 = @intCast((encoded >> 25) & 0x3);
            try validateRelocationAddress(address, length, section.size);
            if (external) {
                if (symbol_number >= symbol_count) return error.InvalidObject;
            } else if (symbol_number == 0 or symbol_number > sections.len) {
                return error.InvalidObject;
            }
            relocations[cursor] = .{
                .section_index = section_index,
                .address = address,
                .symbol_number = symbol_number,
                .pc_relative = ((encoded >> 24) & 0x1) != 0,
                .length = length,
                .external = external,
                .kind = @intCast((encoded >> 28) & 0xf),
            };
            cursor += 1;
        }
    }

    return relocations;
}

fn validateRelocationAddress(address: i32, length: u8, section_size: u64) model.Error!void {
    if (address < 0) return error.InvalidObject;
    const offset: u64 = @intCast(address);
    const width = relocationWidth(length);
    if (offset > section_size) return error.InvalidObject;
    if (width > section_size - offset) return error.InvalidObject;
}

fn relocationWidth(length: u8) u64 {
    return @as(u64, 1) << @intCast(length);
}

fn range(bytes: []const u8, offset: usize, len: usize) model.Error![]const u8 {
    if (offset > bytes.len) return error.InvalidRange;
    if (len > bytes.len - offset) return error.InvalidRange;
    return bytes[offset..][0..len];
}

fn readU32(bytes: []const u8, offset: usize) model.Error!u32 {
    return std.mem.readInt(u32, (try range(bytes, offset, 4))[0..4], .little);
}

fn readU64(bytes: []const u8, offset: usize) model.Error!u64 {
    return std.mem.readInt(u64, (try range(bytes, offset, 8))[0..8], .little);
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

fn alignForward(value: u64, alignment: u64) model.Error!u64 {
    if (alignment == 0) return error.InvalidAlignment;
    if (!std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
    const mask = alignment - 1;
    return (try checkedAddU64(value, mask)) & ~mask;
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn writeI32(bytes: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, .little);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

fn writeName(bytes: []u8, offset: usize, comptime size: usize, value: []const u8) void {
    @memset(bytes[offset..][0..size], 0);
    @memcpy(bytes[offset..][0..value.len], value);
}

const FixtureRelocation = struct {
    section_index: usize,
    address: i32,
    symbol_number: u32,
    pc_relative: bool,
    length: u8,
    external: bool,
    kind: u8,
};

fn writeRelocation(bytes: []u8, offset: usize, relocation: FixtureRelocation) void {
    writeI32(bytes, offset, relocation.address);
    const encoded = (relocation.symbol_number & 0x00ff_ffff) |
        (@as(u32, @intFromBool(relocation.pc_relative)) << 24) |
        (@as(u32, relocation.length) << 25) |
        (@as(u32, @intFromBool(relocation.external)) << 27) |
        (@as(u32, relocation.kind) << 28);
    writeU32(bytes, offset + 4, encoded);
}

fn fixtureObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const text_offset = header_size + load_size;
    const text = "\xe8\x00\x00\x00\x00\x90\x90\xc3";
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_info_size;
    const symbol_count = 2;
    const string_table = "\x00_start\x00local\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 32, text.len);
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 52, 4);
    writeU32(bytes, section_offset + 56, @intCast(relocation_offset));
    writeU32(bytes, section_offset + 60, 1);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    @memcpy(bytes[text_offset..][0..text.len], text);
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 1,
        .symbol_number = 0,
        .pc_relative = true,
        .length = 2,
        .external = true,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH)),
    });

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;
    writeU64(bytes, symbol_offset + 8, 0);
    const local_symbol_offset = symbol_offset + nlist_64_size;
    writeU32(bytes, local_symbol_offset, 8);
    bytes[local_symbol_offset + 4] = 0x0e;
    bytes[local_symbol_offset + 5] = 1;
    writeU64(bytes, local_symbol_offset + 8, 1);

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

fn fixtureBranchCallerObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const text_offset = header_size + load_size;
    const text = "\xe8\x00\x00\x00\x00\xc3";
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_info_size;
    const symbol_count = 2;
    const string_table = "\x00_start\x00callee\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 32, text.len);
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 52, 4);
    writeU32(bytes, section_offset + 56, @intCast(relocation_offset));
    writeU32(bytes, section_offset + 60, 1);
    writeU32(bytes, section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    @memcpy(bytes[text_offset..][0..text.len], text);
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 1,
        .symbol_number = 1,
        .pc_relative = true,
        .length = 2,
        .external = true,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH)),
    });

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;
    writeU64(bytes, symbol_offset + 8, 0);
    const callee_symbol_offset = symbol_offset + nlist_64_size;
    writeU32(bytes, callee_symbol_offset, 8);
    bytes[callee_symbol_offset + 4] = 0x01;

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

fn fixtureSignedCallerObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const text_offset = header_size + load_size;
    const text = "\x48\x8d\x05\x00\x00\x00\x00\xc3";
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_info_size;
    const symbol_count = 2;
    const string_table = "\x00_start\x00callee\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 32, text.len);
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 52, 4);
    writeU32(bytes, section_offset + 56, @intCast(relocation_offset));
    writeU32(bytes, section_offset + 60, 1);
    writeU32(bytes, section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    @memcpy(bytes[text_offset..][0..text.len], text);
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 3,
        .symbol_number = 1,
        .pc_relative = true,
        .length = 2,
        .external = true,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_SIGNED)),
    });

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;
    writeU64(bytes, symbol_offset + 8, 0);
    const callee_symbol_offset = symbol_offset + nlist_64_size;
    writeU32(bytes, callee_symbol_offset, 8);
    bytes[callee_symbol_offset + 4] = 0x01;

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

fn fixtureUnsignedCallerObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const text_offset = header_size + load_size;
    const text = "\x48\xb8\x00\x00\x00\x00\x00\x00\x00\x00\xc3";
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_info_size;
    const symbol_count = 2;
    const string_table = "\x00_start\x00callee\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 32, text.len);
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 52, 4);
    writeU32(bytes, section_offset + 56, @intCast(relocation_offset));
    writeU32(bytes, section_offset + 60, 1);
    writeU32(bytes, section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    @memcpy(bytes[text_offset..][0..text.len], text);
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 2,
        .symbol_number = 1,
        .pc_relative = false,
        .length = 3,
        .external = true,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_UNSIGNED)),
    });

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;
    writeU64(bytes, symbol_offset + 8, 0);
    const callee_symbol_offset = symbol_offset + nlist_64_size;
    writeU32(bytes, callee_symbol_offset, 8);
    bytes[callee_symbol_offset + 4] = 0x01;

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

fn fixtureLocalUnsignedCallerObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const text_offset = header_size + load_size;
    const text_address = 0x1000;
    const target_address = text_address + 16;
    const text = "\x48\xb8\x10\x10\x00\x00\x00\x00\x00\x00\xc3\x90\x90\x90\x90\x90\xc3";
    const relocation_offset = text_offset + text.len;
    const symbol_offset = relocation_offset + relocation_info_size;
    const symbol_count = 1;
    const string_table = "\x00_start\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 24, text_address);
    writeU64(bytes, segment_offset + 32, text.len);
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 32, text_address);
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 52, 4);
    writeU32(bytes, section_offset + 56, @intCast(relocation_offset));
    writeU32(bytes, section_offset + 60, 1);
    writeU32(bytes, section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    @memcpy(bytes[text_offset..][0..text.len], text);
    writeU64(bytes, text_offset + 2, target_address);
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 2,
        .symbol_number = 1,
        .pc_relative = false,
        .length = 3,
        .external = false,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_UNSIGNED)),
    });

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;
    writeU64(bytes, symbol_offset + 8, text_address);

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

fn fixtureLocalSignedCallerObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + 2 * section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const caller_text = "\x48\x8d\x05\x00\x00\x00\x00\xc3";
    const target_text = "\xc3";
    const caller_address = 0x1000;
    const target_address = 0x2000;
    const text_offset = header_size + load_size;
    const target_offset = text_offset + caller_text.len;
    const relocation_offset = target_offset + target_text.len;
    const symbol_offset = relocation_offset + relocation_info_size;
    const symbol_count = 1;
    const string_table = "\x00_start\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 24, caller_address);
    writeU64(bytes, segment_offset + 32, target_address + target_text.len - caller_address);
    writeU32(bytes, segment_offset + 64, 2);

    const caller_section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, caller_section_offset, 16, "__text");
    writeName(bytes, caller_section_offset + 16, 16, "__TEXT");
    writeU64(bytes, caller_section_offset + 32, caller_address);
    writeU64(bytes, caller_section_offset + 40, caller_text.len);
    writeU32(bytes, caller_section_offset + 48, @intCast(text_offset));
    writeU32(bytes, caller_section_offset + 52, 4);
    writeU32(bytes, caller_section_offset + 56, @intCast(relocation_offset));
    writeU32(bytes, caller_section_offset + 60, 1);
    writeU32(bytes, caller_section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);

    const target_section_offset = caller_section_offset + section_64_size;
    writeName(bytes, target_section_offset, 16, "__text2");
    writeName(bytes, target_section_offset + 16, 16, "__TEXT");
    writeU64(bytes, target_section_offset + 32, target_address);
    writeU64(bytes, target_section_offset + 40, target_text.len);
    writeU32(bytes, target_section_offset + 48, @intCast(target_offset));
    writeU32(bytes, target_section_offset + 52, 4);
    writeU32(bytes, target_section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    @memcpy(bytes[text_offset..][0..caller_text.len], caller_text);
    @memcpy(bytes[target_offset..][0..target_text.len], target_text);
    writeI32(bytes, text_offset + 3, target_address - caller_address - 7);
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 3,
        .symbol_number = 2,
        .pc_relative = true,
        .length = 2,
        .external = false,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_SIGNED)),
    });

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;
    writeU64(bytes, symbol_offset + 8, caller_address);

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

fn fixtureBranchCalleeObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const text_offset = header_size + load_size;
    const text = "\xc3";
    const symbol_offset = text_offset + text.len;
    const symbol_count = 1;
    const string_table = "\x00callee\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 32, text.len);
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 52, 4);
    writeU32(bytes, section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);
    @memcpy(bytes[text_offset..][0..text.len], text);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

fn fixtureRelocationOnlyObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size;
    const text_offset = header_size + load_size;
    const text = "\x00\x00\x00\x00\x00\x00\x00\x00";
    const relocation_offset = text_offset + text.len;
    const total_size = relocation_offset + relocation_info_size;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 1);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 56, @intCast(relocation_offset));
    writeU32(bytes, section_offset + 60, 1);
    @memcpy(bytes[text_offset..][0..text.len], text);

    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 0,
        .symbol_number = 1,
        .pc_relative = false,
        .length = 3,
        .external = false,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_UNSIGNED)),
    });

    return bytes;
}

fn fixtureExecutableObject(allocator: Allocator) ![]u8 {
    const segment_load_size = segment_command_64_size + section_64_size;
    const load_size = segment_load_size + symtab_command_size;
    const text_offset = header_size + load_size;
    const text = "\xc3";
    const symbol_offset = text_offset + text.len;
    const symbol_count = 1;
    const string_table = "\x00_start\x00";
    const string_offset = symbol_offset + symbol_count * nlist_64_size;
    const total_size = string_offset + string_table.len;

    const bytes = try allocator.alloc(u8, total_size);
    @memset(bytes, 0);

    writeU32(bytes, 0, std.macho.MH_MAGIC_64);
    writeU32(bytes, 4, @bitCast(std.macho.CPU_TYPE_X86_64));
    writeU32(bytes, 12, std.macho.MH_OBJECT);
    writeU32(bytes, 16, 2);
    writeU32(bytes, 20, @intCast(load_size));

    const segment_offset = header_size;
    writeU32(bytes, segment_offset, @backingInt(std.macho.LC.SEGMENT_64));
    writeU32(bytes, segment_offset + 4, @intCast(segment_load_size));
    writeName(bytes, segment_offset + 8, 16, "__TEXT");
    writeU64(bytes, segment_offset + 32, text.len);
    writeU32(bytes, segment_offset + 64, 1);

    const section_offset = segment_offset + segment_command_64_size;
    writeName(bytes, section_offset, 16, "__text");
    writeName(bytes, section_offset + 16, 16, "__TEXT");
    writeU64(bytes, section_offset + 40, text.len);
    writeU32(bytes, section_offset + 48, @intCast(text_offset));
    writeU32(bytes, section_offset + 52, 4);
    writeU32(bytes, section_offset + 64, std.macho.S_REGULAR | std.macho.S_ATTR_PURE_INSTRUCTIONS | std.macho.S_ATTR_SOME_INSTRUCTIONS);
    @memcpy(bytes[text_offset..][0..text.len], text);

    const symtab_offset = segment_offset + segment_load_size;
    writeU32(bytes, symtab_offset, @backingInt(std.macho.LC.SYMTAB));
    writeU32(bytes, symtab_offset + 4, symtab_command_size);
    writeU32(bytes, symtab_offset + 8, @intCast(symbol_offset));
    writeU32(bytes, symtab_offset + 12, symbol_count);
    writeU32(bytes, symtab_offset + 16, @intCast(string_offset));
    writeU32(bytes, symtab_offset + 20, string_table.len);

    writeU32(bytes, symbol_offset, 1);
    bytes[symbol_offset + 4] = 0x0f;
    bytes[symbol_offset + 5] = 1;

    @memcpy(bytes[string_offset..][0..string_table.len], string_table);
    return bytes;
}

test "Mach-O parser reads 64-bit object sections and symbols" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    var object = try parseObject(allocator, bytes);
    defer object.deinit(allocator);

    try std.testing.expectEqual(model.ObjectFormat.macho, object.target.object_format);
    try std.testing.expectEqual(model.Architecture.x86_64, object.target.architecture);
    try std.testing.expectEqual(@as(usize, 1), object.sections.len);
    try std.testing.expectEqualStrings("__TEXT", object.sections[0].segment_name);
    try std.testing.expectEqualStrings("__text", object.sections[0].name);
    try std.testing.expectEqual(@as(u64, 8), object.sections[0].size);
    try std.testing.expectEqual(@as(u32, 4), object.sections[0].alignment_shift);
    try std.testing.expectEqual(@as(usize, 1), object.relocations.len);
    try std.testing.expectEqual(@as(usize, 0), object.relocations[0].section_index);
    try std.testing.expectEqual(@as(i32, 1), object.relocations[0].address);
    try std.testing.expectEqual(@as(u32, 0), object.relocations[0].symbol_number);
    try std.testing.expect(object.relocations[0].pc_relative);
    try std.testing.expectEqual(@as(u8, 2), object.relocations[0].length);
    try std.testing.expect(object.relocations[0].external);
    try std.testing.expectEqual(@as(u8, @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH))), object.relocations[0].kind);
    try std.testing.expectEqual(@as(usize, 2), object.symbols.len);
    try std.testing.expectEqualStrings("_start", object.symbols[0].name);
    try std.testing.expect(object.symbols[0].external);
    try std.testing.expectEqualStrings("local", object.symbols[1].name);
    try std.testing.expect(!object.symbols[1].external);
}

test "Mach-O metadata parser projects sections and symbols" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    var object = try parseObjectMetadata(allocator, bytes);
    defer object.deinit(allocator);

    try std.testing.expectEqual(model.ObjectFormat.macho, object.target.object_format);
    try std.testing.expectEqual(@as(usize, 1), object.sections.len);
    try std.testing.expectEqualStrings("__TEXT", object.sections[0].segment_name);
    try std.testing.expectEqualStrings("__text", object.sections[0].name);
    try std.testing.expectEqual(@as(u64, 16), object.sections[0].alignment);
    try std.testing.expectEqual(@as(usize, 2), object.symbols.len);
    try std.testing.expectEqualStrings("_start", object.symbols[0].name);
    try std.testing.expect(object.symbols[0].external);
}

test "Mach-O linker emits a minimal x86_64 executable" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureExecutableObject(allocator);
    defer allocator.free(bytes);

    var linked = try root.link(
        allocator,
        &.{.{ .name = "start.o", .bytes = bytes }},
        .{
            .target = .macos_x86_64_macho,
            .image_base = 0x100000000,
        },
    );
    defer linked.deinit(allocator);

    const load_size = segment_command_64_size + section_64_size + entry_point_command_size;
    const text_file_offset = try alignForward(header_size + load_size, 16);
    try std.testing.expectEqual(@as(usize, try checkedUsize(text_file_offset + 1)), linked.bytes.len);
    try std.testing.expectEqual(std.macho.MH_MAGIC_64, try readU32(linked.bytes, 0));
    try std.testing.expectEqual(@as(u32, @bitCast(std.macho.CPU_TYPE_X86_64)), try readU32(linked.bytes, 4));
    try std.testing.expectEqual(std.macho.MH_EXECUTE, try readU32(linked.bytes, 12));
    try std.testing.expectEqual(@as(u32, 2), try readU32(linked.bytes, 16));
    try std.testing.expectEqual(@as(u32, @intCast(load_size)), try readU32(linked.bytes, 20));
    try std.testing.expectEqual(std.macho.MH_NOUNDEFS, try readU32(linked.bytes, 24));

    const segment_offset = header_size;
    try std.testing.expectEqual(@as(u32, @backingInt(std.macho.LC.SEGMENT_64)), try readU32(linked.bytes, segment_offset));
    try std.testing.expectEqual(@as(u32, segment_command_64_size + section_64_size), try readU32(linked.bytes, segment_offset + 4));
    try std.testing.expectEqualSlices(u8, "__TEXT", linked.bytes[segment_offset + 8 ..][0..6]);
    try std.testing.expectEqual(@as(u64, 0x100000000), try readU64(linked.bytes, segment_offset + 24));
    try std.testing.expectEqual(@as(u64, 0), try readU64(linked.bytes, segment_offset + 40));
    try std.testing.expectEqual(@as(u64, linked.bytes.len), try readU64(linked.bytes, segment_offset + 48));
    try std.testing.expectEqual(@as(u32, macho_text_protection), try readU32(linked.bytes, segment_offset + 56));
    try std.testing.expectEqual(@as(u32, 1), try readU32(linked.bytes, segment_offset + 64));

    const section_offset = segment_offset + segment_command_64_size;
    try std.testing.expectEqualSlices(u8, "__text", linked.bytes[section_offset..][0..6]);
    try std.testing.expectEqualSlices(u8, "__TEXT", linked.bytes[section_offset + 16 ..][0..6]);
    try std.testing.expectEqual(@as(u64, 0x100000000 + text_file_offset), try readU64(linked.bytes, section_offset + 32));
    try std.testing.expectEqual(@as(u64, 1), try readU64(linked.bytes, section_offset + 40));
    try std.testing.expectEqual(@as(u32, @intCast(text_file_offset)), try readU32(linked.bytes, section_offset + 48));
    try std.testing.expectEqual(@as(u32, 4), try readU32(linked.bytes, section_offset + 52));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset)]);

    const entry_offset = section_offset + section_64_size;
    try std.testing.expectEqual(@as(u32, @backingInt(std.macho.LC.MAIN)), try readU32(linked.bytes, entry_offset));
    try std.testing.expectEqual(@as(u32, entry_point_command_size), try readU32(linked.bytes, entry_offset + 4));
    try std.testing.expectEqual(text_file_offset, try readU64(linked.bytes, entry_offset + 8));

    try std.testing.expectEqual(model.ObjectFormat.macho, linked.manifest.target.object_format);
    try std.testing.expectEqual(@as(usize, 1), linked.manifest.sections.len);
    try std.testing.expectEqualStrings("__TEXT,__text", linked.manifest.string(linked.manifest.sections[0].name_id));
    try std.testing.expectEqual(@as(u64, 0x100000000 + text_file_offset), linked.manifest.sections[0].address);
    try std.testing.expectEqual(@as(usize, 1), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings("start.o", linked.manifest.string(linked.manifest.contributions[0].input_name_id));
}

test "Mach-O linker applies x86_64 branch relocations" {
    const allocator = std.testing.allocator;
    const caller = try fixtureBranchCallerObject(allocator);
    defer allocator.free(caller);
    const callee = try fixtureBranchCalleeObject(allocator);
    defer allocator.free(callee);

    var linked = try root.link(
        allocator,
        &.{
            .{ .name = "caller.o", .bytes = caller },
            .{ .name = "callee.o", .bytes = callee },
        },
        .{
            .target = .macos_x86_64_macho,
            .image_base = 0x100000000,
        },
    );
    defer linked.deinit(allocator);

    const load_size = segment_command_64_size + section_64_size + entry_point_command_size;
    const text_file_offset = try alignForward(header_size + load_size, 16);
    try std.testing.expectEqual(@as(usize, try checkedUsize(text_file_offset + 17)), linked.bytes.len);
    try std.testing.expectEqual(@as(u64, 17), linked.manifest.sections[0].size);

    const displacement_offset = try checkedUsize(text_file_offset + 1);
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, linked.bytes[displacement_offset..][0..4], .little));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 5)]);
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 16)]);
    try std.testing.expectEqual(@as(usize, 2), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings("caller.o", linked.manifest.string(linked.manifest.contributions[0].input_name_id));
    try std.testing.expectEqualStrings("callee.o", linked.manifest.string(linked.manifest.contributions[1].input_name_id));
}

test "Mach-O linker applies x86_64 signed PC-relative relocations" {
    const allocator = std.testing.allocator;
    const caller = try fixtureSignedCallerObject(allocator);
    defer allocator.free(caller);
    const callee = try fixtureBranchCalleeObject(allocator);
    defer allocator.free(callee);

    var linked = try root.link(
        allocator,
        &.{
            .{ .name = "signed.o", .bytes = caller },
            .{ .name = "callee.o", .bytes = callee },
        },
        .{
            .target = .macos_x86_64_macho,
            .image_base = 0x100000000,
        },
    );
    defer linked.deinit(allocator);

    const load_size = segment_command_64_size + section_64_size + entry_point_command_size;
    const text_file_offset = try alignForward(header_size + load_size, 16);
    try std.testing.expectEqual(@as(usize, try checkedUsize(text_file_offset + 17)), linked.bytes.len);
    try std.testing.expectEqual(@as(u64, 17), linked.manifest.sections[0].size);

    const displacement_offset = try checkedUsize(text_file_offset + 3);
    try std.testing.expectEqual(@as(i32, 9), std.mem.readInt(i32, linked.bytes[displacement_offset..][0..4], .little));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 7)]);
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 16)]);
    try std.testing.expectEqual(@as(usize, 2), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings("signed.o", linked.manifest.string(linked.manifest.contributions[0].input_name_id));
    try std.testing.expectEqualStrings("callee.o", linked.manifest.string(linked.manifest.contributions[1].input_name_id));
}

test "Mach-O linker applies x86_64 unsigned absolute relocations" {
    const allocator = std.testing.allocator;
    const caller = try fixtureUnsignedCallerObject(allocator);
    defer allocator.free(caller);
    const callee = try fixtureBranchCalleeObject(allocator);
    defer allocator.free(callee);

    var linked = try root.link(
        allocator,
        &.{
            .{ .name = "absolute.o", .bytes = caller },
            .{ .name = "callee.o", .bytes = callee },
        },
        .{
            .target = .macos_x86_64_macho,
            .image_base = 0x100000000,
        },
    );
    defer linked.deinit(allocator);

    const load_size = segment_command_64_size + section_64_size + entry_point_command_size;
    const text_file_offset = try alignForward(header_size + load_size, 16);
    try std.testing.expectEqual(@as(usize, try checkedUsize(text_file_offset + 17)), linked.bytes.len);
    try std.testing.expectEqual(@as(u64, 17), linked.manifest.sections[0].size);

    const immediate_offset = try checkedUsize(text_file_offset + 2);
    try std.testing.expectEqual(@as(u64, 0x100000000 + text_file_offset + 16), std.mem.readInt(u64, linked.bytes[immediate_offset..][0..8], .little));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 10)]);
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 16)]);
    try std.testing.expectEqual(@as(usize, 2), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings("absolute.o", linked.manifest.string(linked.manifest.contributions[0].input_name_id));
    try std.testing.expectEqualStrings("callee.o", linked.manifest.string(linked.manifest.contributions[1].input_name_id));
}

test "Mach-O linker applies x86_64 local unsigned absolute relocations" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureLocalUnsignedCallerObject(allocator);
    defer allocator.free(bytes);

    var linked = try root.link(
        allocator,
        &.{.{ .name = "local-absolute.o", .bytes = bytes }},
        .{
            .target = .macos_x86_64_macho,
            .image_base = 0x100000000,
        },
    );
    defer linked.deinit(allocator);

    const load_size = segment_command_64_size + section_64_size + entry_point_command_size;
    const text_file_offset = try alignForward(header_size + load_size, 16);
    try std.testing.expectEqual(@as(usize, try checkedUsize(text_file_offset + 17)), linked.bytes.len);
    try std.testing.expectEqual(@as(u64, 17), linked.manifest.sections[0].size);

    const immediate_offset = try checkedUsize(text_file_offset + 2);
    try std.testing.expectEqual(@as(u64, 0x100000000 + text_file_offset + 16), std.mem.readInt(u64, linked.bytes[immediate_offset..][0..8], .little));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 10)]);
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 16)]);
    try std.testing.expectEqual(@as(usize, 1), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings("local-absolute.o", linked.manifest.string(linked.manifest.contributions[0].input_name_id));
}

test "Mach-O linker applies x86_64 local signed PC-relative relocations" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureLocalSignedCallerObject(allocator);
    defer allocator.free(bytes);

    var linked = try root.link(
        allocator,
        &.{.{ .name = "local-signed.o", .bytes = bytes }},
        .{
            .target = .macos_x86_64_macho,
            .image_base = 0x100000000,
        },
    );
    defer linked.deinit(allocator);

    const load_size = segment_command_64_size + section_64_size + entry_point_command_size;
    const text_file_offset = try alignForward(header_size + load_size, 16);
    try std.testing.expectEqual(@as(usize, try checkedUsize(text_file_offset + 17)), linked.bytes.len);
    try std.testing.expectEqual(@as(u64, 17), linked.manifest.sections[0].size);

    const displacement_offset = try checkedUsize(text_file_offset + 3);
    try std.testing.expectEqual(@as(i32, 9), std.mem.readInt(i32, linked.bytes[displacement_offset..][0..4], .little));
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 7)]);
    try std.testing.expectEqual(@as(u8, 0xc3), linked.bytes[try checkedUsize(text_file_offset + 16)]);
    try std.testing.expectEqual(@as(usize, 2), linked.manifest.contributions.len);
    try std.testing.expectEqualStrings("local-signed.o", linked.manifest.string(linked.manifest.contributions[0].input_name_id));
    try std.testing.expectEqualStrings("local-signed.o", linked.manifest.string(linked.manifest.contributions[1].input_name_id));
}

test "Mach-O linker records unsupported relocation diagnostics" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + segment_command_64_size + section_64_size + symtab_command_size + 8;
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 1,
        .symbol_number = 0,
        .pc_relative = true,
        .length = 2,
        .external = true,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_GOT_LOAD)),
    });

    var diagnostics: model.Diagnostics = .{};
    try std.testing.expectError(
        error.UnsupportedRelocation,
        root.link(
            allocator,
            &.{.{ .name = "call.o", .bytes = bytes }},
            .{
                .target = .macos_x86_64_macho,
                .image_base = 0x100000000,
                .diagnostics = &diagnostics,
            },
        ),
    );

    const failure = diagnostics.linkFailure(error.UnsupportedRelocation);
    const relocation = switch (failure) {
        .unsupported_relocation => |relocation| relocation,
        else => return error.ExpectedUnsupportedRelocationDiagnostic,
    };
    try std.testing.expectEqual(@as(u32, 3), relocation.relocation_type);
    try std.testing.expectEqualStrings("call.o", relocation.input_name);
    try std.testing.expectEqualStrings("__text", relocation.section_name);
    try std.testing.expectEqualStrings("_start", relocation.symbol_name);
}

test "Mach-O parser rejects truncated load commands" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    try std.testing.expectError(error.InvalidRange, parseObject(allocator, bytes[0 .. header_size + 8]));
}

test "Mach-O parser rejects truncated relocation tables" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const section_offset = header_size + segment_command_64_size;
    writeU32(bytes, section_offset + 56, @intCast(bytes.len - relocation_info_size + 1));
    writeU32(bytes, section_offset + 60, 1);

    try std.testing.expectError(error.InvalidRange, parseObject(allocator, bytes));
}

test "Mach-O parser reads relocation entries without a symbol table" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureRelocationOnlyObject(allocator);
    defer allocator.free(bytes);

    var object = try parseObject(allocator, bytes);
    defer object.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), object.relocations.len);
    try std.testing.expectEqual(@as(i32, 0), object.relocations[0].address);
    try std.testing.expectEqual(@as(u32, 1), object.relocations[0].symbol_number);
    try std.testing.expect(!object.relocations[0].external);
    try std.testing.expectEqual(@as(u8, 3), object.relocations[0].length);
}

test "Mach-O parser rejects invalid external relocation symbol references" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + segment_command_64_size + section_64_size + symtab_command_size + 8;
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 1,
        .symbol_number = 2,
        .pc_relative = true,
        .length = 2,
        .external = true,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH)),
    });

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "Mach-O parser rejects invalid local relocation section references" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureRelocationOnlyObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + segment_command_64_size + section_64_size + 8;
    writeRelocation(bytes, relocation_offset, .{
        .section_index = 0,
        .address = 0,
        .symbol_number = 2,
        .pc_relative = false,
        .length = 3,
        .external = false,
        .kind = @intCast(@backingInt(std.macho.reloc_type_x86_64.X86_64_RELOC_UNSIGNED)),
    });

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "Mach-O parser rejects scattered relocation entries" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + segment_command_64_size + section_64_size + symtab_command_size + 8;
    writeU32(bytes, relocation_offset, 0x8000_0000);

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "Mach-O parser rejects relocations outside section data" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const relocation_offset = header_size + segment_command_64_size + section_64_size + symtab_command_size + 8;
    writeI32(bytes, relocation_offset, 5);

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}

test "Mach-O parser rejects invalid symbol section references" {
    const allocator = std.testing.allocator;
    const bytes = try fixtureObject(allocator);
    defer allocator.free(bytes);

    const symbol_offset = header_size + segment_command_64_size + section_64_size + symtab_command_size + 8 + relocation_info_size;
    bytes[symbol_offset + 5] = 2;

    try std.testing.expectError(error.InvalidObject, parseObject(allocator, bytes));
}
