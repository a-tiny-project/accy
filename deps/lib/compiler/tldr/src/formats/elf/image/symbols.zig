const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const StringTable = elf.string.Table;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = elf.layout.ObjectLayout;
const OutputSection = elf.layout.OutputSection;
const GlobalSymbol = elf.layout.GlobalSymbol;
const SymbolRef = elf.layout.SymbolRef;
const Access = elf.addressing.Access;
const SymbolAddressCache = elf.addressing.Cache;
const SymbolRecord = elf.format.SymbolRecord;

const ResolvedEntry = struct {
    found: bool = false,
    name: []const u8 = "",
    entry: SymbolRecord = .{},
};

const EntryFailure = struct {
    found: bool = false,
    ref_index: usize = 0,
    err: model.Error = error.InvalidObject,

    fn isFound(failure: EntryFailure) bool {
        return failure.found;
    }

    fn before(left: EntryFailure, right: EntryFailure) bool {
        return left.ref_index < right.ref_index;
    }
};

const EntryFailures = parallel.FailureSlots(EntryFailure);

const ParallelEntryContext = struct {
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    global_symbol_refs: []const SymbolRef,
    symbol_addresses: *SymbolAddressCache,
    resolved_entries: []ResolvedEntry,
    failures: *EntryFailures,
};

pub const parallel_entry_threshold = 32768;
const entries_per_worker = 8192;

pub fn appendExecutable(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SymbolRecord),
    strtab: *StringTable,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    global_symbol_refs: []const SymbolRef,
    symbol_addresses: *SymbolAddressCache,
    worker_budget: usize,
) model.Error!void {
    const workers = if (global_symbol_refs.len >= parallel_entry_threshold)
        parallel.chooseWorkers(
            global_symbol_refs.len,
            parallel.grainWorkers(worker_budget, global_symbol_refs.len, entries_per_worker),
        )
    else
        1;
    if (workers > 1) {
        return appendExecutableParallel(allocator, out, strtab, objects, layouts, output_sections, globals, global_symbol_refs, symbol_addresses, workers);
    }
    try appendExecutableSerial(allocator, out, strtab, objects, layouts, output_sections, globals, global_symbol_refs, symbol_addresses);
}

fn appendExecutableSerial(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SymbolRecord),
    strtab: *StringTable,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    global_symbol_refs: []const SymbolRef,
    symbol_addresses: *SymbolAddressCache,
) model.Error!void {
    for (global_symbol_refs) |current_ref| {
        if (try resolveExecutableEntry(.serial, objects, layouts, output_sections, globals, symbol_addresses, current_ref)) |resolved| {
            try appendResolvedEntry(allocator, out, strtab, resolved);
        }
    }
}

fn appendExecutableParallel(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SymbolRecord),
    strtab: *StringTable,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    global_symbol_refs: []const SymbolRef,
    symbol_addresses: *SymbolAddressCache,
    workers: usize,
) model.Error!void {
    const resolved_entries = try allocator.alloc(ResolvedEntry, global_symbol_refs.len);
    defer allocator.free(resolved_entries);
    for (resolved_entries) |*entry| entry.* = .{};

    var failures = try EntryFailures.init(allocator, workers, .{});
    defer failures.deinit(allocator);

    var context = ParallelEntryContext{
        .objects = objects,
        .layouts = layouts,
        .output_sections = output_sections,
        .globals = globals,
        .global_symbol_refs = global_symbol_refs,
        .symbol_addresses = symbol_addresses,
        .resolved_entries = resolved_entries,
        .failures = &failures,
    };
    parallel.forChunks(global_symbol_refs.len, workers, &context, resolveEntryChunk);
    if (failures.earliest(EntryFailure.isFound, EntryFailure.before)) |failure| return failure.err;

    for (resolved_entries) |resolved| {
        if (!resolved.found) continue;
        try appendResolvedEntry(allocator, out, strtab, resolved);
    }
}

fn resolveEntryChunk(context: *ParallelEntryContext, worker: usize, start: usize, end: usize) void {
    var index = start;
    while (index < end) : (index += 1) {
        const resolved = resolveExecutableEntry(.concurrent, context.objects, context.layouts, context.output_sections, context.globals, context.symbol_addresses, context.global_symbol_refs[index]) catch |err| {
            const current = context.failures.items[worker];
            const failure = EntryFailure{
                .found = true,
                .ref_index = index,
                .err = err,
            };
            if (!current.found or EntryFailure.before(failure, current)) {
                context.failures.record(worker, failure);
            }
            continue;
        };
        context.resolved_entries[index] = resolved orelse .{};
    }
}

fn resolveExecutableEntry(
    comptime access: Access,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    current_ref: SymbolRef,
) model.Error!?ResolvedEntry {
    const object = objects[current_ref.object_index];
    const symbol = object.symbols[current_ref.symbol_index];
    if (elf.section_state.symbolSectionDiscarded(object, symbol)) return null;
    if (elf.addressing.symbolIsTls(object, symbol)) {
        const value = try elf.addressing.tlsOffset(objects, layouts, output_sections, globals, symbol_addresses, current_ref.object_index, current_ref.symbol_index);
        const contribution = try elf.addressing.contribution(objects, layouts, current_ref.object_index, current_ref.symbol_index);
        const output = output_sections[contribution.outputIndex()];
        return .{
            .found = true,
            .name = symbol.name,
            .entry = .{
                .info = symbol.info,
                .other = symbol.other,
                .section_index = output.section_index,
                .value = value,
                .size = symbol.size,
            },
        };
    }
    if (symbol.isAbsolute()) {
        return .{
            .found = true,
            .name = symbol.name,
            .entry = .{
                .info = symbol.info,
                .other = symbol.other,
                .section_index = std.elf.SHN_ABS,
                .value = symbol.value,
                .size = symbol.size,
            },
        };
    }
    const value = try elf.addressing.symbolAddress(access, objects, layouts, output_sections, globals, symbol_addresses, current_ref.object_index, current_ref.symbol_index);
    const contribution = try elf.addressing.contribution(objects, layouts, current_ref.object_index, current_ref.symbol_index);
    const output = output_sections[contribution.outputIndex()];
    return .{
        .found = true,
        .name = symbol.name,
        .entry = .{
            .info = symbol.info,
            .other = symbol.other,
            .section_index = output.section_index,
            .value = value,
            .size = symbol.size,
        },
    };
}

fn appendResolvedEntry(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(SymbolRecord),
    strtab: *StringTable,
    resolved: ResolvedEntry,
) model.Error!void {
    var entry = resolved.entry;
    entry.name_offset = try strtab.add(allocator, resolved.name);
    try out.append(allocator, entry);
}
