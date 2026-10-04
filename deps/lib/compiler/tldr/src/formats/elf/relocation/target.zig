const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const addressing = elf.addressing;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = elf.layout.ObjectLayout;
const OutputSection = elf.layout.OutputSection;
const GlobalSymbol = elf.layout.GlobalSymbol;
const Rela = elf.format.Rela;
const SymbolAddressCache = addressing.Cache;
const SymbolCacheAccess = addressing.Access;
const RelocationTarget = addressing.Target;
const relocationTargetAddress = addressing.relocationTarget;
const symbolTlsOffset = addressing.tlsOffset;

pub fn cached(
    comptime cache_access: SymbolCacheAccess,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    object_index: usize,
    symbol_index: usize,
    relocation: Rela,
    needs_size: bool,
    tls_offset: bool,
    target_cache: *Cache,
) model.Error!RelocationTarget {
    const target = target_cache.get(object_index, symbol_index, relocation.addend, needs_size, tls_offset) orelse blk: {
        const resolved = if (tls_offset)
            RelocationTarget{
                .address = @intCast(try symbolTlsOffset(objects, layouts, output_sections, globals, symbol_addresses, object_index, symbol_index)),
                .addend = relocation.addend,
                .size = 0,
            }
        else
            try relocationTargetAddress(
                cache_access,
                objects,
                layouts,
                output_sections,
                globals,
                symbol_addresses,
                object_index,
                symbol_index,
                relocation,
                needs_size,
            );
        target_cache.put(object_index, symbol_index, relocation.addend, needs_size, tls_offset, resolved);
        break :blk resolved;
    };
    return target;
}

pub fn cachedOrSkip(
    comptime cache_access: SymbolCacheAccess,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    object_index: usize,
    symbol_index: usize,
    relocation: Rela,
    needs_size: bool,
    tls_offset: bool,
    ignore_missing_target: bool,
    target_cache: *Cache,
) model.Error!?RelocationTarget {
    return cached(
        cache_access,
        objects,
        layouts,
        output_sections,
        globals,
        symbol_addresses,
        object_index,
        symbol_index,
        relocation,
        needs_size,
        tls_offset,
        target_cache,
    ) catch |err| switch (err) {
        error.MissingSection => if (ignore_missing_target) return null else return err,
        else => return err,
    };
}

pub const Cache = struct {
    const entry_count = 64;
    const invalid_object_index = std.math.maxInt(usize);

    entries: [entry_count]Entry = @splat(Entry{}),

    const Entry = struct {
        object_index: usize = invalid_object_index,
        symbol_index: usize = 0,
        addend: i64 = 0,
        needs_size: bool = false,
        tls_offset: bool = false,
        target: RelocationTarget = .{ .address = 0, .addend = 0, .size = 0 },
    };

    pub fn get(
        self: *const Cache,
        object_index: usize,
        symbol_index: usize,
        addend: i64,
        needs_size: bool,
        tls_offset: bool,
    ) ?RelocationTarget {
        const entry = self.entries[indexFor(object_index, symbol_index, addend, needs_size, tls_offset)];
        if (entry.object_index != object_index) return null;
        if (entry.symbol_index != symbol_index) return null;
        if (entry.addend != addend) return null;
        if (entry.needs_size != needs_size) return null;
        if (entry.tls_offset != tls_offset) return null;
        return entry.target;
    }

    pub fn put(
        self: *Cache,
        object_index: usize,
        symbol_index: usize,
        addend: i64,
        needs_size: bool,
        tls_offset: bool,
        target: RelocationTarget,
    ) void {
        self.entries[indexFor(object_index, symbol_index, addend, needs_size, tls_offset)] = .{
            .object_index = object_index,
            .symbol_index = symbol_index,
            .addend = addend,
            .needs_size = needs_size,
            .tls_offset = tls_offset,
            .target = target,
        };
    }

    fn indexFor(object_index: usize, symbol_index: usize, addend: i64, needs_size: bool, tls_offset: bool) usize {
        const addend_bits: u64 = @bitCast(addend);
        var hash = object_index *% 0x9e3779b1;
        hash ^= symbol_index *% 0x85ebca6b;
        hash ^= @as(usize, @truncate(addend_bits));
        if (needs_size) hash ^= 0xc2b2ae35;
        if (tls_offset) hash ^= 0x27d4eb2f;
        return hash & (entry_count - 1);
    }
};
