const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const boundary = @import("boundary.zig");
const cache = @import("cache.zig");

const model = root.model;
const format = elf.format;
const layout = elf.layout;
const merge = elf.merge;
const section_state = elf.section_state;

const Access = cache.Access;
const Cache = cache.Cache;
const GlobalSymbol = layout.GlobalSymbol;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const Symbol = format.Symbol;
const SymbolRef = layout.SymbolRef;
const contributionAt = layout.contributionAt;
const foldedSection = section_state.foldedSection;
const symbolSectionDiscarded = section_state.symbolSectionDiscarded;

pub fn address(
    comptime cache_access: Access,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *Cache,
    object_index: usize,
    symbol_index: usize,
) model.Error!u64 {
    if (symbol_index >= objects[object_index].symbols.len) return error.UndefinedSymbol;
    const cached = symbol_addresses.slot(object_index, symbol_index);
    const cached_value = cache.load(cache_access, cached);
    if (cached_value != Cache.missing) return cached_value;

    const symbol_record = objects[object_index].symbols[symbol_index];
    if (symbol_record.isUndefined()) {
        const global = globals.get(symbol_record.name) orelse {
            if (boundary.forSymbol(symbol_record.name)) |symbol_boundary| {
                if (symbol_addresses.syntheticBoundaryAddress(symbol_boundary)) |boundary_address| {
                    return cache.store(cache_access, cached, boundary_address);
                }
            }
            if (symbol_record.isWeakUndefined()) {
                return cache.store(cache_access, cached, 0);
            }
            return error.UndefinedSymbol;
        };
        const resolved = try address(
            cache_access,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            global.ref.object_index,
            global.ref.symbol_index,
        );
        return cache.store(cache_access, cached, resolved);
    }
    if (symbolSectionDiscarded(objects[object_index], symbol_record) and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.MissingSection;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (global.ref.eql(current_ref)) return error.MissingSection;
        const resolved = try address(
            cache_access,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            global.ref.object_index,
            global.ref.symbol_index,
        );
        return cache.store(cache_access, cached, resolved);
    }
    if (symbol_record.isCommon() and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.UndefinedSymbol;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (!global.ref.eql(current_ref)) {
            const resolved = try address(cache_access, objects, layouts, output_sections, globals, symbol_addresses, global.ref.object_index, global.ref.symbol_index);
            return cache.store(cache_access, cached, resolved);
        }
    }
    if (symbol_record.isAbsolute()) return cache.store(cache_access, cached, symbol_record.value);
    if (symbol_record.isCommon()) {
        const object_layout = layouts[object_index];
        if (symbol_index >= object_layout.common_symbols.len) return error.UnsupportedRelocation;
        const common_contribution = contributionAt(object_layout.common_symbols, symbol_index) orelse return error.MissingSection;
        const output = output_sections[common_contribution.outputIndex()];
        return cache.store(cache_access, cached, output.address + common_contribution.offset);
    }
    return sectionAddress(cache_access, objects, layouts, output_sections, cached, object_index, symbol_record);
}

pub fn relocation(
    comptime cache_access: Access,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *Cache,
    object_index: usize,
    symbol_index: usize,
) model.Error!i128 {
    if (symbol_index >= objects[object_index].symbols.len) return error.UndefinedSymbol;

    const symbol_record = objects[object_index].symbols[symbol_index];
    if (symbol_record.isUndefined()) {
        const global = globals.get(symbol_record.name) orelse {
            if (boundary.forSymbol(symbol_record.name)) |symbol_boundary| {
                if (symbol_addresses.syntheticBoundaryAddress(symbol_boundary)) |boundary_address| {
                    return @intCast(boundary_address);
                }
            }
            if (symbol_record.isWeakUndefined()) return 0;
            return error.UndefinedSymbol;
        };
        return relocation(
            cache_access,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            global.ref.object_index,
            global.ref.symbol_index,
        );
    }
    if (symbolSectionDiscarded(objects[object_index], symbol_record) and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.MissingSection;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (global.ref.eql(current_ref)) return error.MissingSection;
        return relocation(
            cache_access,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            global.ref.object_index,
            global.ref.symbol_index,
        );
    }
    if (symbol_record.isCommon() and symbol_record.name.len != 0) {
        const global = globals.get(symbol_record.name) orelse return error.UndefinedSymbol;
        const current_ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
        if (!global.ref.eql(current_ref)) {
            return relocation(cache_access, objects, layouts, output_sections, globals, symbol_addresses, global.ref.object_index, global.ref.symbol_index);
        }
    }
    if (symbol_record.isAbsolute()) return signedAbsoluteValue(symbol_record.value);
    if (symbol_record.isCommon()) return @intCast(try address(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index));
    return @intCast(try sectionSymbolAddress(cache_access, objects, layouts, output_sections, symbol_addresses, object_index, symbol_index, symbol_record));
}

pub fn isUnresolvedWeak(
    object: ObjectFile,
    symbol_index: usize,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
) bool {
    if (symbol_index >= object.symbols.len) return false;
    const symbol_record = object.symbols[symbol_index];
    return symbol_record.isWeakUndefined() and !globals.contains(symbol_record.name);
}

pub fn sectionSymbolAddress(
    comptime cache_access: Access,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    symbol_addresses: *Cache,
    object_index: usize,
    symbol_index: usize,
    symbol_record: Symbol,
) model.Error!u64 {
    const cached = symbol_addresses.slot(object_index, symbol_index);
    const cached_value = cache.load(cache_access, cached);
    if (cached_value != Cache.missing) return cached_value;
    return sectionAddress(cache_access, objects, layouts, output_sections, cached, object_index, symbol_record);
}

fn sectionAddress(
    comptime cache_access: Access,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    cached: *u64,
    object_index: usize,
    symbol_record: Symbol,
) model.Error!u64 {
    const object = objects[object_index];
    const object_layout = layouts[object_index];
    if (symbol_record.section_index >= object.sections.len) return error.UnsupportedRelocation;
    if (merge.piece(object_layout, object, symbol_record.section_index, symbol_record.value)) |entry| {
        const output = output_sections[entry.contribution.outputIndex()];
        const resolved = output.address + entry.contribution.offset + entry.intra_offset;
        return cache.store(cache_access, cached, resolved);
    }
    const symbol_contribution = if (foldedSection(object, symbol_record.section_index)) |canonical|
        (contributionAt(layouts[canonical.object_index].sections, canonical.section_index) orelse return error.MissingSection).*
    else
        (contributionAt(object_layout.sections, symbol_record.section_index) orelse return error.MissingSection).*;
    const output = output_sections[symbol_contribution.outputIndex()];
    const resolved = output.address + symbol_contribution.offset + symbol_record.value;
    return cache.store(cache_access, cached, resolved);
}

fn signedAbsoluteValue(value: u64) i128 {
    return @as(i64, @bitCast(value));
}
