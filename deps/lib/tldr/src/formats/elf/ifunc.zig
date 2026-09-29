const std = @import("std");
const root = @import("../../root.zig");
const elf = @import("root.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const parallel = root.parallel;
const addressing = elf.addressing;
const format = elf.format;
const layout = elf.layout;
const output_section = elf.output_section;
const section_state = elf.section_state;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const GlobalSymbol = layout.GlobalSymbol;
const SymbolRef = layout.SymbolRef;
const SymbolAddressCache = addressing.Cache;
const OutputSectionKind = output_section.OutputSectionKind;
const output_section_count = output_section.output_section_count;
const writeU32 = format.writeU32;
const writeU64 = format.writeU64;

pub const stub_size = 16;
pub const slot_size = 8;
pub const rela_size = 24;

const irelative_type: u32 = 37;
pub const parallel_mark_symbol_threshold = 32 * 1024;
const mark_symbols_per_worker = 16 * 1024;
const no_ifunc_definition = SymbolRef{
    .object_index = std.math.maxInt(usize),
    .symbol_index = std.math.maxInt(usize),
};

pub const Entry = struct {
    definition: SymbolRef,
    resolver_address: u64 = 0,
};

pub const IfuncLayout = struct {
    entries: []Entry = &.{},

    pub fn deinit(self: *IfuncLayout, allocator: Allocator) void {
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = .{};
    }
};

pub const Collector = struct {
    active: bool,
    marks: [][]SymbolRef = &.{},
    seen: std.AutoHashMapUnmanaged(SymbolRef, void) = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(
        allocator: Allocator,
        objects: []const ObjectFile,
        globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
        max_link_jobs: usize,
    ) model.Error!Collector {
        if (!hasIfuncDefinitions(objects)) return .{ .active = false };
        const marks = try allocator.alloc([]SymbolRef, objects.len);
        for (marks) |*object_marks| object_marks.* = &.{};
        errdefer {
            for (marks) |object_marks| {
                if (object_marks.len != 0) allocator.free(object_marks);
            }
            allocator.free(marks);
        }
        for (objects, 0..) |object, object_index| {
            const object_marks = try allocator.alloc(SymbolRef, object.symbols.len);
            marks[object_index] = object_marks;
        }
        const total_symbol_count = try countSymbols(objects);
        var context = MarkContext{
            .objects = objects,
            .globals = globals,
            .marks = marks,
        };
        const requested_workers = if (max_link_jobs != 0)
            max_link_jobs
        else
            @max(2, total_symbol_count / mark_symbols_per_worker);
        const workers = if (total_symbol_count >= parallel_mark_symbol_threshold)
            parallel.chooseWorkers(objects.len, requested_workers)
        else
            1;
        if (workers > 1) {
            parallel.forItems(objects.len, workers, &context, fillMarkObject);
        } else {
            for (objects, 0..) |_, object_index| fillMarkObject(&context, 0, object_index);
        }
        return .{ .active = true, .marks = marks };
    }

    pub fn deinit(self: *Collector, allocator: Allocator) void {
        for (self.marks) |object_marks| allocator.free(object_marks);
        if (self.marks.len != 0) allocator.free(self.marks);
        self.seen.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn enabled(self: *const Collector) bool {
        return self.active;
    }

    pub fn observe(
        self: *Collector,
        allocator: Allocator,
        object_index: usize,
        relocation_record: format.Rela,
    ) model.Error!void {
        if (!self.active) return;
        if (elf.relocation.isNone(relocation_record)) return;
        const symbol_index: usize = @intCast(relocation_record.symbolIndex());
        if (object_index >= self.marks.len) return;
        const object_marks = self.marks[object_index];
        if (symbol_index >= object_marks.len) return;
        const definition = object_marks[symbol_index];
        if (definition.object_index == no_ifunc_definition.object_index) return;
        const gop = try self.seen.getOrPut(allocator, definition);
        if (gop.found_existing) return;
        try self.entries.append(allocator, .{ .definition = definition });
    }

    pub fn finish(
        self: *Collector,
        allocator: Allocator,
        output_sections: *[output_section_count]OutputSection,
    ) model.Error!IfuncLayout {
        const entry_slice = try self.entries.toOwnedSlice(allocator);
        self.entries = .empty;
        const ifunc_layout = IfuncLayout{ .entries = entry_slice };
        reserve(output_sections, ifunc_layout);
        return ifunc_layout;
    }
};

const MarkContext = struct {
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    marks: [][]SymbolRef,
};

fn fillMarkObject(context: *MarkContext, worker: usize, object_index: usize) void {
    _ = worker;
    for (context.marks[object_index], 0..) |*mark, symbol_index| {
        mark.* = ifuncDefinition(context.objects, context.globals, object_index, symbol_index) orelse no_ifunc_definition;
    }
}

pub fn collectEntries(
    allocator: Allocator,
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    output_sections: *[output_section_count]OutputSection,
) model.Error!IfuncLayout {
    var collector = try Collector.init(allocator, objects, globals, 0);
    defer collector.deinit(allocator);
    if (!collector.enabled()) return .{};

    for (objects, 0..) |object, object_index| {
        if (object.relocations.len == 0) continue;
        for (object.sections, 0..) |_, section_index| {
            if (section_state.sectionDiscarded(object, section_index)) continue;
            if (section_state.foldedSection(object, section_index) != null) continue;
            for (object.relocationsForSection(section_index)) |entry| {
                try collector.observe(allocator, object_index, entry);
            }
        }
    }

    return try collector.finish(allocator, output_sections);
}

fn hasIfuncDefinitions(objects: []const ObjectFile) bool {
    for (objects) |object| {
        if (object.has_ifunc_definitions) return true;
    }
    return false;
}

fn countSymbols(objects: []const ObjectFile) model.Error!usize {
    var total: usize = 0;
    for (objects) |object| {
        total = std.math.add(usize, total, object.symbols.len) catch return error.InvalidObject;
    }
    return total;
}

fn ifuncDefinition(
    objects: []const ObjectFile,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    object_index: usize,
    symbol_index: usize,
) ?SymbolRef {
    const symbol = objects[object_index].symbols[symbol_index];
    var ref = SymbolRef{ .object_index = object_index, .symbol_index = symbol_index };
    if (symbol.isUndefined() or section_state.symbolSectionDiscarded(objects[object_index], symbol)) {
        if (symbol.name.len == 0) return null;
        const global = globals.get(symbol.name) orelse return null;
        ref = global.ref;
    }
    if (ref.object_index >= objects.len) return null;
    const target_object = objects[ref.object_index];
    if (ref.symbol_index >= target_object.symbols.len) return null;
    const target = target_object.symbols[ref.symbol_index];
    if (target.kind() != std.elf.STT_GNU_IFUNC) return null;
    if (target.isUndefined()) return null;
    return ref;
}

fn reserve(output_sections: *[output_section_count]OutputSection, ifunc_layout: IfuncLayout) void {
    if (ifunc_layout.entries.len == 0) return;
    const count: u64 = @intCast(ifunc_layout.entries.len);

    var iplt = &output_sections[@backingInt(OutputSectionKind.iplt)];
    iplt.file_size = count * stub_size;
    iplt.memory_size = iplt.file_size;
    iplt.alignment = @max(iplt.alignment, stub_size);

    var igot = &output_sections[@backingInt(OutputSectionKind.igot)];
    igot.file_size = count * slot_size;
    igot.memory_size = igot.file_size;
    igot.alignment = @max(igot.alignment, slot_size);

    var rela = &output_sections[@backingInt(OutputSectionKind.rela_iplt)];
    rela.file_size = count * rela_size;
    rela.memory_size = rela.file_size;
    rela.alignment = @max(rela.alignment, 8);
}

pub fn finalize(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    globals: *const std.StringHashMapUnmanaged(GlobalSymbol),
    symbol_addresses: *SymbolAddressCache,
    ifunc_layout: IfuncLayout,
) model.Error!void {
    if (ifunc_layout.entries.len == 0) return;
    const iplt = output_sections[@backingInt(OutputSectionKind.iplt)];

    for (ifunc_layout.entries) |*entry| {
        entry.resolver_address = try addressing.symbolAddress(
            .serial,
            objects,
            layouts,
            output_sections,
            globals,
            symbol_addresses,
            entry.definition.object_index,
            entry.definition.symbol_index,
        );
    }
    for (ifunc_layout.entries, 0..) |entry, index| {
        const stub_address = iplt.address + @as(u64, @intCast(index)) * stub_size;
        _ = try addressing.store(.serial, symbol_addresses.slot(entry.definition.object_index, entry.definition.symbol_index), stub_address);
    }
}

pub fn write(
    image: []u8,
    output_sections: []const OutputSection,
    ifunc_layout: IfuncLayout,
) model.Error!void {
    if (ifunc_layout.entries.len == 0) return;
    const iplt = output_sections[@backingInt(OutputSectionKind.iplt)];
    const igot = output_sections[@backingInt(OutputSectionKind.igot)];
    const rela = output_sections[@backingInt(OutputSectionKind.rela_iplt)];

    for (ifunc_layout.entries, 0..) |entry, index| {
        const offset: u64 = @intCast(index);
        const stub_address = iplt.address + offset * stub_size;
        const stub_offset: usize = @intCast(iplt.file_offset + offset * stub_size);
        const slot_address = igot.address + offset * slot_size;
        const slot_offset: usize = @intCast(igot.file_offset + offset * slot_size);
        const rela_offset: usize = @intCast(rela.file_offset + offset * rela_size);

        try format.requireRange(image, stub_offset, stub_size);
        try format.requireRange(image, slot_offset, slot_size);
        try format.requireRange(image, rela_offset, rela_size);

        const displacement = @as(i128, @intCast(slot_address)) - @as(i128, @intCast(stub_address + 6));
        image[stub_offset + 0] = 0xff;
        image[stub_offset + 1] = 0x25;
        writeU32(image, stub_offset + 2, @bitCast(try elf.relocation.checkedI32(displacement)));
        @memset(image[stub_offset + 6 ..][0 .. stub_size - 6], 0xcc);

        writeU64(image, slot_offset, entry.resolver_address);

        writeU64(image, rela_offset + 0, slot_address);
        writeU64(image, rela_offset + 8, irelative_type);
        writeU64(image, rela_offset + 16, entry.resolver_address);
    }
}

test "ifunc layout reserves stub slot and relocation space" {
    var output_sections = @as([output_section_count]OutputSection, @splat(.{ .kind = .build_id_note }));
    for (&output_sections, 0..) |*section, index| section.kind = @fromBackingInt(@intCast(index));

    var entries = [_]Entry{
        .{ .definition = .{ .object_index = 0, .symbol_index = 1 } },
        .{ .definition = .{ .object_index = 0, .symbol_index = 2 } },
    };
    const ifunc_layout = IfuncLayout{ .entries = &entries };
    reserve(&output_sections, ifunc_layout);
    try std.testing.expectEqual(@as(u64, 32), output_sections[@backingInt(OutputSectionKind.iplt)].file_size);
    try std.testing.expectEqual(@as(u64, 16), output_sections[@backingInt(OutputSectionKind.igot)].file_size);
    try std.testing.expectEqual(@as(u64, 48), output_sections[@backingInt(OutputSectionKind.rela_iplt)].file_size);
}
