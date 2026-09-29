const std = @import("std");
const root = @import("../../root.zig");
const format = @import("format.zig");
const layout = @import("layout/root.zig");
const parser = @import("parser.zig");
const sections = @import("sections.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const ObjectFile = parser.ObjectFile;
const Symbol = format.Symbol;
const SymbolRef = layout.SymbolRef;
const GlobalSymbol = layout.GlobalSymbol;
const symbolSectionDiscarded = sections.symbolSectionDiscarded;

pub const parallel_global_symbol_threshold = 32768;
const global_symbols_per_worker = 8192;

pub fn collectGlobalSymbols(
    allocator: Allocator,
    objects: []const ObjectFile,
    globals: *std.StringHashMapUnmanaged(GlobalSymbol),
    global_symbol_refs: ?*std.ArrayListUnmanaged(SymbolRef),
    max_link_jobs: usize,
) model.Error!void {
    if (global_symbol_refs) |refs| {
        const total_symbols = objectSymbolTotal(objects);
        const requested_workers = if (max_link_jobs != 0)
            max_link_jobs
        else
            total_symbols / global_symbols_per_worker;
        const workers = if (total_symbols >= parallel_global_symbol_threshold)
            parallel.chooseWorkers(total_symbols, requested_workers)
        else
            1;
        if (workers <= 1) {
            try collectGlobalSymbolRefsSerial(allocator, objects, refs);
        } else {
            try collectGlobalSymbolRefsParallel(allocator, objects, refs, workers);
        }
        const capacity = std.math.cast(u32, refs.items.len) orelse return error.InvalidObject;
        try globals.ensureTotalCapacity(allocator, capacity);
        const active_refs = try allocator.alloc(bool, refs.items.len);
        defer allocator.free(active_refs);
        @memset(active_refs, false);
        for (refs.items, 0..) |ref, ref_index| {
            const ref_index_u32 = std.math.cast(u32, ref_index) orelse return error.InvalidObject;
            try addGlobalSymbolDefinitionTracked(allocator, objects, globals, ref.object_index, ref.symbol_index, ref_index_u32, active_refs);
        }
        compactGlobalSymbolRefs(refs, active_refs);
        return;
    }

    var definition_count: usize = 0;
    for (objects) |object| {
        for (object.symbols) |symbol| {
            if (!globalSymbolCanBeAdded(object, symbol)) continue;
            definition_count += 1;
        }
    }
    const capacity = std.math.cast(u32, definition_count) orelse return error.InvalidObject;
    try globals.ensureTotalCapacity(allocator, capacity);

    for (objects, 0..) |object, object_index| {
        for (object.symbols, 0..) |symbol, symbol_index| {
            if (!globalSymbolCanBeAdded(object, symbol)) continue;
            try addGlobalSymbolDefinition(allocator, objects, globals, object_index, symbol_index);
        }
    }
}

fn collectGlobalSymbolRefsSerial(
    allocator: Allocator,
    objects: []const ObjectFile,
    refs: *std.ArrayListUnmanaged(SymbolRef),
) model.Error!void {
    refs.clearRetainingCapacity();
    try refs.ensureTotalCapacity(allocator, objects.len);
    for (objects, 0..) |object, object_index| {
        for (object.symbols, 0..) |symbol, symbol_index| {
            if (!globalSymbolCanBeAdded(object, symbol)) continue;
            try refs.append(allocator, .{
                .object_index = object_index,
                .symbol_index = symbol_index,
            });
        }
    }
}

const GlobalSymbolRefCountContext = struct {
    objects: []const ObjectFile,
    offsets: []usize,
};

const GlobalSymbolRefFillContext = struct {
    objects: []const ObjectFile,
    offsets: []const usize,
    refs: []SymbolRef,
};

fn collectGlobalSymbolRefsParallel(
    allocator: Allocator,
    objects: []const ObjectFile,
    refs: *std.ArrayListUnmanaged(SymbolRef),
    workers: usize,
) model.Error!void {
    refs.clearRetainingCapacity();
    const offsets = try allocator.alloc(usize, objects.len + 1);
    defer allocator.free(offsets);

    var count_context = GlobalSymbolRefCountContext{
        .objects = objects,
        .offsets = offsets,
    };
    parallel.forItems(objects.len, workers, &count_context, countGlobalSymbolRefsForObject);

    var total: usize = 0;
    for (offsets[0..objects.len]) |*slot| {
        const count = slot.*;
        slot.* = total;
        total += count;
    }
    offsets[objects.len] = total;

    _ = std.math.cast(u32, total) orelse return error.InvalidObject;
    try refs.resize(allocator, total);

    var fill_context = GlobalSymbolRefFillContext{
        .objects = objects,
        .offsets = offsets,
        .refs = refs.items,
    };
    parallel.forItems(objects.len, workers, &fill_context, fillGlobalSymbolRefsForObject);
}

fn countGlobalSymbolRefsForObject(context: *GlobalSymbolRefCountContext, worker: usize, object_index: usize) void {
    _ = worker;
    const object = context.objects[object_index];
    var count: usize = 0;
    for (object.symbols) |symbol| {
        if (!globalSymbolCanBeAdded(object, symbol)) continue;
        count += 1;
    }
    context.offsets[object_index] = count;
}

fn fillGlobalSymbolRefsForObject(context: *GlobalSymbolRefFillContext, worker: usize, object_index: usize) void {
    _ = worker;
    const object = context.objects[object_index];
    var write_index = context.offsets[object_index];
    for (object.symbols, 0..) |symbol, symbol_index| {
        if (!globalSymbolCanBeAdded(object, symbol)) continue;
        context.refs[write_index] = .{
            .object_index = object_index,
            .symbol_index = symbol_index,
        };
        write_index += 1;
    }
    std.debug.assert(write_index == context.offsets[object_index + 1]);
}

fn objectSymbolTotal(objects: []const ObjectFile) usize {
    var total: usize = 0;
    for (objects) |object| total += object.symbols.len;
    return total;
}

pub fn globalSymbolCanBeAdded(object: ObjectFile, symbol: Symbol) bool {
    if (!symbol.isGlobalDefinition()) return false;
    if (symbolSectionDiscarded(object, symbol)) return false;
    return true;
}

pub fn addGlobalSymbol(
    allocator: Allocator,
    objects: []const ObjectFile,
    globals: *std.StringHashMapUnmanaged(GlobalSymbol),
    object_index: usize,
    symbol_index: usize,
) model.Error!bool {
    const elf_symbol = objects[object_index].symbols[symbol_index];
    if (!globalSymbolCanBeAdded(objects[object_index], elf_symbol)) return false;
    try addGlobalSymbolDefinition(allocator, objects, globals, object_index, symbol_index);
    return true;
}

pub fn addGlobalSymbolDefinition(
    allocator: Allocator,
    objects: []const ObjectFile,
    globals: *std.StringHashMapUnmanaged(GlobalSymbol),
    object_index: usize,
    symbol_index: usize,
) model.Error!void {
    try addGlobalSymbolDefinitionTracked(allocator, objects, globals, object_index, symbol_index, 0, null);
}

fn addGlobalSymbolDefinitionTracked(
    allocator: Allocator,
    objects: []const ObjectFile,
    globals: *std.StringHashMapUnmanaged(GlobalSymbol),
    object_index: usize,
    symbol_index: usize,
    ref_index: u32,
    active_refs: ?[]bool,
) model.Error!void {
    const ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
    const elf_symbol = objects[ref.object_index].symbols[ref.symbol_index];
    const gop = try globals.getOrPut(allocator, elf_symbol.name);
    const candidate = globalSymbolFromRef(objects, ref, ref_index);
    if (!gop.found_existing) {
        gop.value_ptr.* = candidate;
        if (active_refs) |active| active[ref_index] = true;
        return;
    }
    switch (try mergeGlobalSymbols(objects, gop.value_ptr.*, candidate)) {
        .keep => {},
        .replace => |replacement| {
            if (active_refs) |active| {
                active[gop.value_ptr.ref_index] = false;
                active[replacement.ref_index] = true;
            }
            gop.value_ptr.* = replacement;
        },
    }
}

fn compactGlobalSymbolRefs(refs: *std.ArrayListUnmanaged(SymbolRef), active_refs: []const bool) void {
    var write_index: usize = 0;
    for (refs.items, active_refs) |ref, active| {
        if (!active) continue;
        refs.items[write_index] = ref;
        write_index += 1;
    }
    refs.shrinkRetainingCapacity(write_index);
}

const GlobalSymbolMerge = union(enum) {
    keep,
    replace: GlobalSymbol,
};

fn mergeGlobalSymbols(
    objects: []const ObjectFile,
    existing: GlobalSymbol,
    candidate: GlobalSymbol,
) model.Error!GlobalSymbolMerge {
    if (existing.ref.eql(candidate.ref)) return .keep;

    const existing_symbol = objects[existing.ref.object_index].symbols[existing.ref.symbol_index];
    const candidate_symbol = objects[candidate.ref.object_index].symbols[candidate.ref.symbol_index];
    const existing_rank = globalSymbolRank(existing);
    const candidate_rank = globalSymbolRank(candidate);

    if (existing_rank != candidate_rank) {
        if (candidate_rank > existing_rank) return .{ .replace = candidate };
        return .keep;
    }
    if (existing.common and candidate.common) {
        if (prefersCommonSymbol(candidate_symbol, existing_symbol, candidate.ref, existing.ref)) return .{ .replace = candidate };
        return .keep;
    }
    if (existing_rank == strong_definition_rank) {
        if (existing_symbol.isGnuUnique() and candidate_symbol.isGnuUnique()) {
            if (symbolRefBefore(candidate.ref, existing.ref)) return .{ .replace = candidate };
            return .keep;
        }
        return error.DuplicateSymbol;
    }
    if (symbolRefBefore(candidate.ref, existing.ref)) return .{ .replace = candidate };
    return .keep;
}

const weak_definition_rank: u8 = 0;
const common_definition_rank: u8 = 1;
const strong_definition_rank: u8 = 2;

fn globalSymbolRank(global: GlobalSymbol) u8 {
    if (!global.weak and !global.common) return strong_definition_rank;
    if (!global.weak and global.common) return common_definition_rank;
    return weak_definition_rank;
}

fn globalSymbolFromRef(objects: []const ObjectFile, ref: SymbolRef, ref_index: u32) GlobalSymbol {
    const symbol = objects[ref.object_index].symbols[ref.symbol_index];
    return .{
        .ref = ref,
        .ref_index = ref_index,
        .weak = symbol.binding() == std.elf.STB_WEAK,
        .common = symbol.isCommon(),
    };
}

fn prefersCommonSymbol(candidate: Symbol, existing: Symbol, candidate_ref: SymbolRef, existing_ref: SymbolRef) bool {
    if (candidate.size != existing.size) return candidate.size > existing.size;
    if (candidate.value != existing.value) return candidate.value > existing.value;
    return symbolRefBefore(candidate_ref, existing_ref);
}

fn symbolRefBefore(left: SymbolRef, right: SymbolRef) bool {
    if (left.object_index != right.object_index) return left.object_index < right.object_index;
    return left.symbol_index < right.symbol_index;
}

test "ELF global symbol merge keeps earliest weak definition" {
    var first_symbols = [_]Symbol{testSymbol("shared", std.elf.STB_WEAK, 1, 0, 1)};
    var second_symbols = [_]Symbol{testSymbol("shared", std.elf.STB_WEAK, 1, 0, 1)};
    var objects = [_]ObjectFile{
        testObject(first_symbols[0..]),
        testObject(second_symbols[0..]),
    };
    const first_ref = SymbolRef{ .object_index = 0, .symbol_index = 0 };
    const second_ref = SymbolRef{ .object_index = 1, .symbol_index = 0 };

    try expectReplacedRef(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], second_ref, 1),
        globalSymbolFromRef(objects[0..], first_ref, 0),
    ), first_ref);
    try expectKept(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], first_ref, 0),
        globalSymbolFromRef(objects[0..], second_ref, 1),
    ));
}

test "ELF global symbol merge ranks common symbols by size value then reference" {
    var small_symbols = [_]Symbol{testSymbol("slot", std.elf.STB_GLOBAL, std.elf.SHN_COMMON, 8, 8)};
    var large_symbols = [_]Symbol{testSymbol("slot", std.elf.STB_GLOBAL, std.elf.SHN_COMMON, 4, 16)};
    var tie_symbols = [_]Symbol{testSymbol("slot", std.elf.STB_GLOBAL, std.elf.SHN_COMMON, 8, 8)};
    var objects = [_]ObjectFile{
        testObject(small_symbols[0..]),
        testObject(large_symbols[0..]),
        testObject(tie_symbols[0..]),
    };
    const small_ref = SymbolRef{ .object_index = 0, .symbol_index = 0 };
    const large_ref = SymbolRef{ .object_index = 1, .symbol_index = 0 };
    const tie_ref = SymbolRef{ .object_index = 2, .symbol_index = 0 };

    try expectReplacedRef(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], small_ref, 0),
        globalSymbolFromRef(objects[0..], large_ref, 1),
    ), large_ref);
    try expectKept(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], small_ref, 0),
        globalSymbolFromRef(objects[0..], tie_ref, 2),
    ));
    try expectReplacedRef(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], tie_ref, 2),
        globalSymbolFromRef(objects[0..], small_ref, 0),
    ), small_ref);
}

test "ELF global symbol merge ranks strong common above weak definitions" {
    var weak_symbols = [_]Symbol{testSymbol("slot", std.elf.STB_WEAK, 1, 0, 1)};
    var common_symbols = [_]Symbol{testSymbol("slot", std.elf.STB_GLOBAL, std.elf.SHN_COMMON, 16, 32)};
    var objects = [_]ObjectFile{
        testObject(weak_symbols[0..]),
        testObject(common_symbols[0..]),
    };
    const weak_ref = SymbolRef{ .object_index = 0, .symbol_index = 0 };
    const common_ref = SymbolRef{ .object_index = 1, .symbol_index = 0 };

    try expectReplacedRef(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], weak_ref, 0),
        globalSymbolFromRef(objects[0..], common_ref, 1),
    ), common_ref);
    try expectKept(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], common_ref, 1),
        globalSymbolFromRef(objects[0..], weak_ref, 0),
    ));
}

test "ELF global symbol merge rejects ordinary strong duplicates" {
    var first_symbols = [_]Symbol{testSymbol("call", std.elf.STB_GLOBAL, 1, 0, 1)};
    var second_symbols = [_]Symbol{testSymbol("call", std.elf.STB_GLOBAL, 1, 0, 1)};
    var objects = [_]ObjectFile{
        testObject(first_symbols[0..]),
        testObject(second_symbols[0..]),
    };
    const first_ref = SymbolRef{ .object_index = 0, .symbol_index = 0 };
    const second_ref = SymbolRef{ .object_index = 1, .symbol_index = 0 };

    try std.testing.expectError(error.DuplicateSymbol, mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], first_ref, 0),
        globalSymbolFromRef(objects[0..], second_ref, 1),
    ));
}

test "ELF global symbol merge coalesces GNU unique definitions by earliest reference" {
    var first_symbols = [_]Symbol{testSymbol("slot", std.elf.STB_GNU_UNIQUE, 1, 0, 1)};
    var second_symbols = [_]Symbol{testSymbol("slot", std.elf.STB_GNU_UNIQUE, 1, 0, 1)};
    var objects = [_]ObjectFile{
        testObject(first_symbols[0..]),
        testObject(second_symbols[0..]),
    };
    const first_ref = SymbolRef{ .object_index = 0, .symbol_index = 0 };
    const second_ref = SymbolRef{ .object_index = 1, .symbol_index = 0 };

    try expectReplacedRef(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], second_ref, 1),
        globalSymbolFromRef(objects[0..], first_ref, 0),
    ), first_ref);
    try expectKept(try mergeGlobalSymbols(
        objects[0..],
        globalSymbolFromRef(objects[0..], first_ref, 0),
        globalSymbolFromRef(objects[0..], second_ref, 1),
    ));
}

fn expectKept(merge: GlobalSymbolMerge) !void {
    switch (merge) {
        .keep => {},
        .replace => return error.ExpectedKeep,
    }
}

fn expectReplacedRef(merge: GlobalSymbolMerge, ref: SymbolRef) !void {
    switch (merge) {
        .keep => return error.ExpectedReplace,
        .replace => |replacement| try std.testing.expect(replacement.ref.eql(ref)),
    }
}

fn testSymbol(name: []const u8, binding: u8, section_index: u16, value: u64, size: u64) Symbol {
    return .{
        .name_offset = 0,
        .info = format.elfSymbolInfo(binding, std.elf.STT_OBJECT),
        .other = 0,
        .section_index = section_index,
        .value = value,
        .size = size,
        .name = name,
    };
}

fn testObject(symbols: []Symbol) ObjectFile {
    return .{
        .name = "symbols.o",
        .bytes = &.{},
        .sections = &.{},
        .section_names = &.{},
        .section_name_ends = &.{},
        .symbols = symbols,
        .relocations = &.{},
        .relocations_owned = false,
        .has_common_symbols = false,
        .has_named_strong_undefined_symbols = false,
        .has_ifunc_definitions = false,
        .has_group_sections = false,
        .relocation_ranges = &.{},
    };
}
