const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const definition = @import("definition.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const Symbol = elf.format.Symbol;
const globalSymbolCanBeAdded = elf.symbol_table.globalSymbolCanBeAdded;

pub fn record(
    allocator: Allocator,
    objects: []const ObjectFile,
    object_index: usize,
    definitions: *definition.Index,
    unresolved_names: *usize,
    active_candidate_counts: []usize,
    pending: *definition.Queue,
) model.Error!void {
    const parsed_object = objects[object_index];
    for (parsed_object.symbols) |symbol| {
        try recordSymbol(
            allocator,
            symbol,
            globalSymbolCanBeAdded(parsed_object, symbol),
            definitions,
            unresolved_names,
            active_candidate_counts,
            pending,
        );
    }
}

pub fn recordSymbols(
    allocator: Allocator,
    symbols: []const Symbol,
    definitions: *definition.Index,
    unresolved_names: *usize,
    active_candidate_counts: []usize,
    pending: *definition.Queue,
) model.Error!void {
    for (symbols) |symbol| {
        try recordSymbol(
            allocator,
            symbol,
            symbol.isGlobalDefinition(),
            definitions,
            unresolved_names,
            active_candidate_counts,
            pending,
        );
    }
}

fn recordSymbol(
    allocator: Allocator,
    symbol: Symbol,
    records_definition: bool,
    definitions: *definition.Index,
    unresolved_names: *usize,
    active_candidate_counts: []usize,
    pending: *definition.Queue,
) model.Error!void {
    if (records_definition) {
        return definition.define(allocator, definitions, unresolved_names, active_candidate_counts, symbol.name);
    }
    if (!symbol.isUndefined()) return;
    if (symbol.name.len == 0) return;
    if (symbol.binding() != std.elf.STB_GLOBAL) return;
    try definition.require(allocator, definitions, unresolved_names, active_candidate_counts, pending, symbol.name);
}

fn testSymbol(name: []const u8, section_index: u16, symbol_binding: u8) Symbol {
    return .{
        .name_offset = 0,
        .info = symbol_binding << 4,
        .other = 0,
        .section_index = section_index,
        .value = 0,
        .size = 0,
        .name = name,
    };
}
