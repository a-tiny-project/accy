const std = @import("std");
const sys = @import("sys");
const tldr = @import("tldr");

const max_object_bytes = 1024 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = sys.allocator.processAllocator();
    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.next() orelse return error.ExpectedProgramName;
    const object_path = args.next() orelse return error.ExpectedObjectPath;
    if (args.next() != null) return error.UnexpectedArgument;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        object_path,
        allocator,
        .limited(max_object_bytes),
    );
    defer allocator.free(bytes);

    var object = try tldr.formats.macho.parseObject(allocator, bytes);
    defer object.deinit(allocator);
    try validateObject(object);
}

fn validateObject(object: tldr.formats.macho.Object) !void {
    if (object.target.object_format != .macho or
        object.target.architecture != .aarch64 or
        object.target.endianness != .little or
        object.target.pointer_width_bits != 64)
    {
        return error.UnexpectedTarget;
    }

    const text_section = findSection(object, "__TEXT", "__text") orelse return error.MissingTextSection;
    const data_section = findSection(object, "__DATA", "__data") orelse return error.MissingDataSection;
    const call_symbol = findSymbol(object, "_tldr_macho_probe_call") orelse return error.MissingCallSymbol;
    const data_symbol = findSymbol(object, "_tldr_macho_probe_data") orelse return error.MissingDataSymbol;
    const external_symbol = findSymbol(object, "_tldr_macho_probe_external") orelse return error.MissingExternalSymbol;

    try validateDefinedSymbol(object, call_symbol, text_section);
    try validateDefinedSymbol(object, data_symbol, data_section);
    try validateUndefinedSymbol(object, external_symbol);
    try requireRelocation(object, text_section, external_symbol, .ARM64_RELOC_BRANCH26);
    try requireSectionRelocation(object, text_section, data_section, .ARM64_RELOC_PAGE21);
    try requireSectionRelocation(object, text_section, data_section, .ARM64_RELOC_PAGEOFF12);
}

fn findSection(object: tldr.formats.macho.Object, segment_name: []const u8, name: []const u8) ?usize {
    for (object.sections, 0..) |section, index| {
        if (std.mem.eql(u8, section.segment_name, segment_name) and
            std.mem.eql(u8, section.name, name))
        {
            return index;
        }
    }
    return null;
}

fn findSymbol(object: tldr.formats.macho.Object, name: []const u8) ?u32 {
    for (object.symbols, 0..) |symbol, index| {
        if (std.mem.eql(u8, symbol.name, name)) return @intCast(index);
    }
    return null;
}

fn validateDefinedSymbol(object: tldr.formats.macho.Object, symbol_index: u32, section_index: usize) !void {
    const symbol = object.symbols[symbol_index];
    if (!symbol.external or
        (symbol.kind & std.macho.N_TYPE) != std.macho.N_SECT or
        symbol.section_index != section_index + 1)
    {
        return error.UnexpectedDefinedSymbol;
    }
}

fn validateUndefinedSymbol(object: tldr.formats.macho.Object, symbol_index: u32) !void {
    const symbol = object.symbols[symbol_index];
    if (!symbol.external or
        (symbol.kind & std.macho.N_TYPE) != std.macho.N_UNDF or
        symbol.section_index != 0)
    {
        return error.UnexpectedUndefinedSymbol;
    }
}

fn requireRelocation(
    object: tldr.formats.macho.Object,
    section_index: usize,
    symbol_index: u32,
    kind: std.macho.reloc_type_arm64,
) !void {
    for (object.relocations) |relocation| {
        if (relocation.section_index == section_index and
            relocation.external and
            relocation.symbol_number == symbol_index and
            relocation.kind == @backingInt(kind))
        {
            return;
        }
    }
    return error.MissingRelocation;
}

fn requireSectionRelocation(
    object: tldr.formats.macho.Object,
    source_section_index: usize,
    target_section_index: usize,
    kind: std.macho.reloc_type_arm64,
) !void {
    for (object.relocations) |relocation| {
        if (relocation.section_index != source_section_index or
            !relocation.external or
            relocation.kind != @backingInt(kind))
        {
            continue;
        }
        const symbol = object.symbols[relocation.symbol_number];
        if (symbol.section_index == target_section_index + 1) return;
    }
    return error.MissingSectionRelocation;
}
