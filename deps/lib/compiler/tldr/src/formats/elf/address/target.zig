const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const cache = @import("cache.zig");
const size = @import("size.zig");
const symbol = @import("symbol.zig");

const model = root.model;
const format = elf.format;
const layout = elf.layout;
const merge = elf.merge;

const Access = cache.Access;
const Cache = cache.Cache;
const GlobalSymbol = layout.GlobalSymbol;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const Rela = format.Rela;

pub const Target = struct {
    address: i128,
    addend: i64,
    size: u64,
};

pub fn relocation(
    comptime cache_access: Access,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *Cache,
    object_index: usize,
    symbol_index: usize,
    relocation_record: Rela,
    needs_size: bool,
) model.Error!Target {
    const object = objects[object_index];
    if (symbol_index >= object.symbols.len) return error.UndefinedSymbol;

    if (needs_size) {
        return .{
            .address = 0,
            .addend = relocation_record.addend,
            .size = try size.symbol(objects, globals, object_index, symbol_index),
        };
    }

    const symbol_record = object.symbols[symbol_index];
    if (symbol_record.isSection()) {
        if (relocation_record.addend >= 0) {
            const offset: u64 = @intCast(relocation_record.addend);
            if (merge.address(layouts[object_index], object, output_sections, symbol_record.section_index, offset)) |resolved| {
                return .{ .address = resolved, .addend = 0, .size = 0 };
            }
        }
        return .{
            .address = @intCast(try symbol.sectionSymbolAddress(cache_access, objects, layouts, output_sections, symbol_addresses, object_index, symbol_index, symbol_record)),
            .addend = relocation_record.addend,
            .size = 0,
        };
    }

    return .{
        .address = try symbol.relocation(cache_access, objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index),
        .addend = relocation_record.addend,
        .size = 0,
    };
}
