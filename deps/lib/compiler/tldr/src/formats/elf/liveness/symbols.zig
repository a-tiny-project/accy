const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const state = @import("state.zig");

const model = root.model;
const GlobalSymbol = elf.layout.GlobalSymbol;
const ObjectFile = elf.parser.ObjectFile;
const SectionRef = elf.parser.SectionRef;
const State = state.State;
const SymbolRef = elf.layout.SymbolRef;
const SyntheticBoundary = elf.addressing.Boundary;
const boundarySectionNameMatches = elf.addressing.boundarySectionNameMatches;
const foldedSection = elf.section_state.foldedSection;
const sectionDiscarded = elf.section_state.sectionDiscarded;
const sectionIsAllocated = elf.format.sectionIsAllocated;
const sectionNameOrEmpty = elf.parser.sectionNameOrEmpty;
const symbolSectionDiscarded = elf.section_state.symbolSectionDiscarded;
const syntheticBoundaryForSymbol = elf.addressing.boundaryForSymbol;

pub fn mark(
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    live: *State,
    symbol_ref: SymbolRef,
    options: model.LinkOptions,
) model.Error!void {
    if (symbol_ref.object_index >= objects.len) return error.InvalidObject;
    const object = objects[symbol_ref.object_index];
    if (symbol_ref.symbol_index >= object.symbols.len) return error.UndefinedSymbol;

    const symbol = object.symbols[symbol_ref.symbol_index];
    if (symbol.isUndefined()) {
        const global = globals.get(symbol.name) orelse {
            if (symbol.isWeakUndefined()) return;
            const boundary = syntheticBoundaryForSymbol(symbol.name) orelse {
                elf.diagnostic.recordUndefinedSymbol(options, object, symbol);
                return error.UndefinedSymbol;
            };
            if (try markSyntheticBoundarySections(objects, live, boundary)) return;
            if (boundary.optional) return;
            elf.diagnostic.recordUndefinedSymbol(options, object, symbol);
            return error.UndefinedSymbol;
        };
        return mark(objects, globals, live, global.ref, options);
    }
    if (symbolSectionDiscarded(object, symbol) and symbol.name.len != 0) {
        const global = globals.get(symbol.name) orelse return error.MissingSection;
        return mark(objects, globals, live, global.ref, options);
    }
    if (symbol.isCommon()) return;
    if (symbol.isAbsolute()) return;
    if (symbol.section_index >= object.sections.len) return error.UnsupportedRelocation;

    try state.markSection(
        live,
        objects,
        .{
            .object_index = symbol_ref.object_index,
            .section_index = symbol.section_index,
        },
    );
}

fn markSyntheticBoundarySections(
    objects: []const ObjectFile,
    live: *State,
    boundary: SyntheticBoundary,
) model.Error!bool {
    var found = false;
    for (objects, 0..) |object, object_index| {
        for (object.sections, 0..) |section, section_index| {
            if (!sectionIsAllocated(section)) continue;
            if (section.size == 0) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;
            if (!boundarySectionNameMatches(boundary, sectionNameOrEmpty(object, section_index))) continue;
            try state.markSection(
                live,
                objects,
                .{
                    .object_index = object_index,
                    .section_index = section_index,
                },
            );
            found = true;
        }
    }
    return found;
}

pub fn markRelocationTargets(
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    live: *State,
    section_ref: SectionRef,
    options: model.LinkOptions,
) model.Error!void {
    const object = objects[section_ref.object_index];
    for (object.relocationsForSection(section_ref.section_index)) |entry| {
        if (elf.relocation.isNone(entry)) continue;
        if (entry.symbolIndex() >= object.symbols.len) return error.UndefinedSymbol;
        try mark(
            objects,
            globals,
            live,
            .{
                .object_index = section_ref.object_index,
                .symbol_index = @intCast(entry.symbolIndex()),
            },
            options,
        );
    }
}
