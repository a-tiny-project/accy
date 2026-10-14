const std = @import("std");
const root = @import("../../root.zig");
const addressing = @import("address/root.zig");
const format = @import("format.zig");
const layout = @import("layout/root.zig");
const output_section = @import("section.zig");
const parser = @import("parser.zig");
const relocation = @import("relocation/root.zig");
const sections = @import("sections.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const ObjectFile = parser.ObjectFile;
const GlobalSymbol = layout.GlobalSymbol;
const GotEntry = layout.GotEntry;
const GotLayout = layout.GotLayout;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const OutputSectionKind = output_section.OutputSectionKind;
const SymbolRef = layout.SymbolRef;
const output_section_count = output_section.output_section_count;
const foldedSection = sections.foldedSection;
const sectionDiscarded = sections.sectionDiscarded;
const sectionRelocationsAffectOutput = relocation.sectionRelocationsAffectOutput;
const symbolAddress = addressing.symbolAddress;
const symbolSectionDiscarded = sections.symbolSectionDiscarded;
const writeU64 = format.writeU64;

pub fn collectEntries(
    allocator: Allocator,
    objects: []const ObjectFile,
    output_sections: *[output_section_count]OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
) model.Error!GotLayout {
    var entries: std.ArrayListUnmanaged(GotEntry) = .empty;
    errdefer entries.deinit(allocator);

    for (objects, 0..) |object, object_index| {
        if (object.relocations.len == 0) continue;
        for (object.sections, 0..) |_, section_index| {
            if (!sectionRelocationsAffectOutput(object, section_index)) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;
            for (object.relocationsForSection(section_index)) |relocation_record| {
                if (relocation_record.relocationType() != @backingInt(std.elf.R_X86_64.GOTPCREL)) continue;
                const ref = try canonicalSymbolRef(objects, globals, object_index, @intCast(relocation_record.symbolIndex()));
                if ((GotLayout{ .entries = entries.items }).entryOffset(ref) != null) continue;
                const offset = try checkedOffset(entries.items.len);
                try entries.append(allocator, .{ .ref = ref, .offset = offset });
            }
        }
    }

    if (entries.items.len != 0) {
        const size = try checkedSize(entries.items.len);
        var output = &output_sections[@backingInt(OutputSectionKind.got)];
        output.file_size = size;
        output.memory_size = size;
        output.alignment = @max(output.alignment, 8);
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn collectEntriesWithIfunc(
    allocator: Allocator,
    objects: []const ObjectFile,
    output_sections: *[output_section_count]OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    ifunc_collector: anytype,
) model.Error!GotLayout {
    var entries: std.ArrayListUnmanaged(GotEntry) = .empty;
    errdefer entries.deinit(allocator);

    for (objects, 0..) |object, object_index| {
        if (object.relocations.len == 0) continue;
        for (object.sections, 0..) |_, section_index| {
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;
            const affects_output = sectionRelocationsAffectOutput(object, section_index);
            if (!affects_output) continue;
            for (object.relocationsForSection(section_index)) |relocation_record| {
                try ifunc_collector.observe(allocator, object_index, relocation_record);
                if (relocation_record.relocationType() != @backingInt(std.elf.R_X86_64.GOTPCREL)) continue;
                const ref = try canonicalSymbolRef(objects, globals, object_index, @intCast(relocation_record.symbolIndex()));
                if ((GotLayout{ .entries = entries.items }).entryOffset(ref) != null) continue;
                const offset = try checkedOffset(entries.items.len);
                try entries.append(allocator, .{ .ref = ref, .offset = offset });
            }
        }
    }

    if (entries.items.len != 0) {
        const size = try checkedSize(entries.items.len);
        var output = &output_sections[@backingInt(OutputSectionKind.got)];
        output.file_size = size;
        output.memory_size = size;
        output.alignment = @max(output.alignment, 8);
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn canonicalSymbolRef(
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    object_index: usize,
    symbol_index: usize,
) model.Error!SymbolRef {
    if (object_index >= objects.len) return error.UndefinedSymbol;
    const object = objects[object_index];
    if (symbol_index >= object.symbols.len) return error.UndefinedSymbol;
    const symbol = object.symbols[symbol_index];
    const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
    if (symbol.isUndefined()) {
        const global = globals.get(symbol.name) orelse return current_ref;
        return global.ref;
    }
    if ((symbolSectionDiscarded(object, symbol) or symbol.isCommon()) and symbol.name.len != 0) {
        const global = globals.get(symbol.name) orelse return current_ref;
        return global.ref;
    }
    return current_ref;
}

pub fn writePayload(
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *addressing.Cache,
    got_layout: GotLayout,
) model.Error!void {
    if (got_layout.entries.len == 0) return;
    const got = output_sections[@backingInt(OutputSectionKind.got)];
    for (got_layout.entries) |entry| {
        const address = try symbolAddress(.serial, objects, layouts, output_sections, globals, symbol_addresses, entry.ref.object_index, entry.ref.symbol_index);
        writeU64(image, @intCast(got.file_offset + entry.offset), address);
    }
}

fn checkedOffset(entry_count: usize) model.Error!u64 {
    if (entry_count > std.math.maxInt(u64) / 8) return error.InvalidRange;
    return @as(u64, @intCast(entry_count)) * 8;
}

fn checkedSize(entry_count: usize) model.Error!u64 {
    return checkedOffset(entry_count);
}
