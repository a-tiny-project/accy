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

test "recording symbols resolves required names through definitions" {
    const allocator = std.testing.allocator;
    var definitions: definition.Index = .{};
    defer definition.deinit(allocator, &definitions);
    var counts = [_]usize{0};
    var pending = definition.Queue.initContext({});
    defer pending.deinit(allocator);
    var unresolved_names: usize = 0;

    try definition.add(allocator, &definitions, "puts", 0, &counts, &pending);

    const undefined_global = testSymbol("puts", std.elf.SHN_UNDEF, std.elf.STB_GLOBAL);
    const undefined_weak = testSymbol("vfork", std.elf.SHN_UNDEF, std.elf.STB_WEAK);
    const undefined_local = testSymbol("tls", std.elf.SHN_UNDEF, std.elf.STB_LOCAL);
    try recordSymbols(
        allocator,
        &.{ undefined_global, undefined_weak, undefined_local },
        &definitions,
        &unresolved_names,
        &counts,
        &pending,
    );
    try std.testing.expectEqual(@as(usize, 1), unresolved_names);
    try std.testing.expectEqual(@as(usize, 1), counts[0]);
    try std.testing.expectEqual(@as(?usize, 0), pending.peek());

    const defining_global = testSymbol("puts", 1, std.elf.STB_GLOBAL);
    try recordSymbols(allocator, &.{defining_global}, &definitions, &unresolved_names, &counts, &pending);
    try std.testing.expectEqual(@as(usize, 0), unresolved_names);
    try std.testing.expectEqual(@as(usize, 0), counts[0]);

    try recordSymbols(allocator, &.{undefined_global}, &definitions, &unresolved_names, &counts, &pending);
    try std.testing.expectEqual(@as(usize, 0), unresolved_names);
    try std.testing.expectEqual(@as(usize, 0), counts[0]);
}
