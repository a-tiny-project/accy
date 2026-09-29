const std = @import("std");
const alloc_phase = @import("alloc_phase");
const sys = @import("sys");
const artifact = @import("root.zig").artifact;
const machine = @import("machine.zig");

const Allocator = std.mem.Allocator;

const ehdr_size = 64;
const shdr_size = 64;
const sym_size = 24;
const rela_size = 24;

pub const ObjectError = Allocator.Error || ValidationError;

const ValidationError = error{
    DuplicateSymbol,
    InvalidAlignment,
    InvalidDataSymbol,
    InvalidTextSymbol,
    InvalidRelocationOffset,
    MissingRelocationSymbol,
    UnsupportedArchitecture,
    UnsupportedRelocation,
    ObjectSizeOverflow,
};

/// One slot to patch. `section` names the section holding the slot, and only a section the
/// file carries bytes for may hold one: `.text`, `.rodata`, or `.data`. A `.bss` slot is
/// refused because there are no bytes in the file to write an address into.
pub const Relocation = struct {
    section: []const u8 = ".text",
    offset: u64,
    symbol: []const u8,
    kind: artifact.RelocationKind,
    addend: i64 = 0,
    width_bits: u16 = 64,
};

pub const TextSymbol = struct {
    name: []const u8,
    offset: u64,
    size: u64,
};

pub const RelocatableObject = struct {
    architecture: artifact.Architecture = .x86_64,
    entry_symbol: []const u8,
    text: []const u8,
    text_alignment: usize = 16,
    text_symbols: []const TextSymbol = &.{},
    data_symbols: []const machine.DataSymbol = &.{},
    relocations: []const Relocation = &.{},
    executable_stack: bool = false,
};

pub const X86_64MachineCodeObject = struct {
    entry_symbol: []const u8,
    code: []const u8,
    text_symbols: []const TextSymbol = &.{},
    relocations: []const machine.CallRelocation = &.{},
    data_relocations: []const machine.DataRelocation = &.{},
    data_symbols: []const machine.DataSymbol = &.{},
    executable_stack: bool = false,
};

pub fn buildX86_64MachineCodeObject(
    allocator: Allocator,
    input: X86_64MachineCodeObject,
) ObjectError![]u8 {
    const object_relocations = try allocator.alloc(Relocation, input.relocations.len + input.data_relocations.len);
    defer allocator.free(object_relocations);

    for (input.relocations, 0..) |relocation, index| {
        object_relocations[index] = .{
            .offset = relocation.offset,
            .symbol = relocation.target,
            .kind = .call,
            .width_bits = 64,
        };
    }
    for (input.data_relocations, 0..) |relocation, index| {
        object_relocations[input.relocations.len + index] = .{
            .offset = relocation.offset,
            .symbol = relocation.target,
            .kind = .absolute,
            .addend = relocation.addend,
            .width_bits = relocation.width_bits,
        };
    }

    return buildRelocatableObject(allocator, .{
        .architecture = .x86_64,
        .entry_symbol = input.entry_symbol,
        .text = input.code,
        .text_symbols = input.text_symbols,
        .data_symbols = input.data_symbols,
        .relocations = object_relocations,
        .executable_stack = input.executable_stack,
    });
}

pub fn buildRelocatableObject(
    allocator: Allocator,
    input: RelocatableObject,
) ObjectError![]u8 {
    if (input.architecture != .x86_64) return error.UnsupportedArchitecture;
    try validateAlignment(input.text_alignment);
    const default_symbols = [_]TextSymbol{.{
        .name = input.entry_symbol,
        .offset = 0,
        .size = input.text.len,
    }};
    const text_symbols = if (input.text_symbols.len == 0) &default_symbols else input.text_symbols;
    for (text_symbols) |symbol| try validateTextSymbol(input.text.len, symbol);

    var rodata = try DataSectionLayout.build(allocator, input.data_symbols, .rodata);
    defer rodata.deinit(allocator);
    var data = try DataSectionLayout.build(allocator, input.data_symbols, .data);
    defer data.deinit(allocator);
    var bss = try DataSectionLayout.build(allocator, input.data_symbols, .bss);
    defer bss.deinit(allocator);

    var sections = Sections.init(input, rodata, data, bss);
    var symbols = try Symbols.init(allocator);
    defer symbols.deinit(allocator);
    try symbols.collect(allocator, sections, .{
        .rodata = rodata.symbols,
        .data = data.symbols,
        .bss = bss.symbols,
    }, text_symbols, input.relocations);

    const sizes: TargetSizes = .{ input.text.len, rodata.size, data.size };
    var groups = try collectRelocations(allocator, input, sizes, &symbols.indices);
    defer groups.deinit(allocator);

    const layout = try sections.place(&symbols, groups);
    const buffer = try allocator.alloc(u8, layout.size);
    errdefer allocator.free(buffer);
    @memset(buffer, 0);

    const placed = [_]PlacedBytes{
        .{ .section = sections.text, .target = .text, .bytes = input.text },
        .{ .section = sections.rodata, .target = .rodata, .bytes = rodata.bytes },
        .{ .section = sections.data, .target = .data, .bytes = data.bytes },
    };
    for (placed) |entry| {
        if (entry.section == 0) continue;
        const offset = sections.headers[entry.section].offset;
        copyInto(buffer, offset, entry.bytes);
        scrubRelocationSlots(buffer[offset..][0..entry.bytes.len], input.relocations, entry.target);
    }
    for (relocation_targets) |target| {
        const section = sections.rela[@backingInt(target)];
        if (section == 0) continue;
        writeRelaRecords(buffer, sections.headers[section].offset, groups.slice(target));
    }
    writeSymbolRecords(buffer, sections.headers[sections.symbols].offset, symbols.records.items);
    copyInto(buffer, sections.headers[sections.strings].offset, symbols.strings.bytes());
    copyInto(buffer, sections.headers[sections.names].offset, Sections.names_text);
    writeElfHeader(buffer, .{
        .section_header_offset = layout.headers,
        .section_count = sections.count,
        .section_string_table_index = sections.names,
    });
    sections.write(buffer, layout.headers);
    std.debug.assert(buffer.len >= input.text.len);
    return buffer;
}

const Sections = struct {
    headers: [12]SectionHeader = @splat(.null_header),
    count: u16 = 1,
    text: u16 = 0,
    rodata: u16 = 0,
    data: u16 = 0,
    bss: u16 = 0,
    /// One relocation section per target that has relocations, indexed by `RelocationTarget`.
    rela: [relocation_target_count]u16 = @splat(0),
    symbols: u16 = 0,
    strings: u16 = 0,
    names: u16 = 0,

    /// A name is found by its first occurrence, so each plain name is spelled before the
    /// `.rela.` section that quotes it.
    const names_text = "\x00.text\x00.rodata\x00.data\x00.bss\x00.rela.text\x00" ++
        ".rela.rodata\x00.rela.data\x00.symtab\x00.strtab\x00.shstrtab\x00" ++
        ".note.GNU-stack\x00";
    const Layout = struct { headers: usize, size: usize };

    fn init(
        input: RelocatableObject,
        rodata: DataSectionLayout,
        data: DataSectionLayout,
        bss: DataSectionLayout,
    ) Sections {
        var self: Sections = .{};
        self.text = self.add(".text", .{
            .section_type = std.elf.SHT_PROGBITS,
            .flags = std.elf.SHF_ALLOC | std.elf.SHF_EXECINSTR,
            .size = input.text.len,
            .alignment = input.text_alignment,
        });
        if (rodata.size != 0) self.rodata = self.add(".rodata", .{
            .section_type = std.elf.SHT_PROGBITS,
            .flags = std.elf.SHF_ALLOC,
            .size = rodata.size,
            .alignment = rodata.alignment,
        });
        if (data.size != 0) self.data = self.add(".data", .{
            .section_type = std.elf.SHT_PROGBITS,
            .flags = std.elf.SHF_ALLOC | std.elf.SHF_WRITE,
            .size = data.size,
            .alignment = data.alignment,
        });
        if (bss.size != 0) self.bss = self.add(".bss", .{
            .section_type = std.elf.SHT_NOBITS,
            .flags = std.elf.SHF_ALLOC | std.elf.SHF_WRITE,
            .size = bss.size,
            .alignment = bss.alignment,
        });
        self.addRelocationSections(input.relocations);
        self.symbols = self.add(".symtab", .{
            .section_type = std.elf.SHT_SYMTAB,
            .alignment = 8,
            .entry_size = sym_size,
        });
        self.strings = self.add(".strtab", .{ .section_type = std.elf.SHT_STRTAB, .alignment = 1 });
        self.names = self.add(".shstrtab", .{
            .section_type = std.elf.SHT_STRTAB,
            .size = names_text.len,
            .alignment = 1,
        });
        _ = self.add(".note.GNU-stack", .{
            .section_type = std.elf.SHT_PROGBITS,
            .flags = if (input.executable_stack) std.elf.SHF_EXECINSTR else 0,
            .alignment = 1,
        });
        self.headers[self.symbols].link = self.strings;
        for (self.rela) |section| {
            if (section != 0) self.headers[section].link = self.symbols;
        }
        std.debug.assert(self.count <= self.headers.len);
        return self;
    }

    /// Adds one `SHT_RELA` section per target that has relocations. A target with none gets no
    /// section, which is what keeps an object holding only `.text` slots identical to what this
    /// writer produced before data sections existed.
    fn addRelocationSections(self: *Sections, relocations: []const Relocation) void {
        if (relocationCount(relocations, .text) != 0) {
            self.rela[@backingInt(RelocationTarget.text)] =
                self.add(".rela.text", relaHeader(self.text));
        }
        if (self.rodata != 0 and relocationCount(relocations, .rodata) != 0) {
            self.rela[@backingInt(RelocationTarget.rodata)] =
                self.add(".rela.rodata", relaHeader(self.rodata));
        }
        if (self.data != 0 and relocationCount(relocations, .data) != 0) {
            self.rela[@backingInt(RelocationTarget.data)] =
                self.add(".rela.data", relaHeader(self.data));
        }
    }

    fn relaHeader(target_section: u16) SectionHeader {
        return .{
            .section_type = std.elf.SHT_RELA,
            .info = target_section,
            .alignment = 8,
            .entry_size = rela_size,
        };
    }

    fn add(self: *Sections, comptime name: []const u8, header: SectionHeader) u16 {
        std.debug.assert(self.count < self.headers.len);
        const index = self.count;
        self.headers[index] = header;
        self.headers[index].name = comptime std.mem.indexOf(u8, names_text, name).?;
        self.count += 1;
        return index;
    }

    /// Assigns every section its file offset. A `SHT_NOBITS` section takes an offset and no
    /// bytes, because its size is what the loader zeroes rather than what the file carries.
    fn place(
        self: *Sections,
        symbols: *const Symbols,
        groups: RelocationGroups,
    ) ObjectError!Layout {
        self.headers[self.symbols].size = std.math.mul(usize, symbols.records.items.len, sym_size) catch {
            return error.ObjectSizeOverflow;
        };
        self.headers[self.symbols].info = symbols.first_global;
        self.headers[self.strings].size = symbols.strings.bytes().len;
        for (self.rela, groups.counts) |section, count| {
            if (section == 0) {
                std.debug.assert(count == 0);
                continue;
            }
            self.headers[section].size = std.math.mul(usize, count, rela_size) catch {
                return error.ObjectSizeOverflow;
            };
        }
        var offset: usize = ehdr_size;
        for (self.headers[1..self.count]) |*header| {
            const mask = header.alignment - 1;
            const aligned = std.math.add(usize, offset, mask) catch return error.ObjectSizeOverflow;
            offset = aligned & ~mask;
            header.offset = offset;
            if (header.section_type == std.elf.SHT_NOBITS) continue;
            offset = std.math.add(usize, offset, header.size) catch return error.ObjectSizeOverflow;
        }
        const padded = std.math.add(usize, offset, 7) catch return error.ObjectSizeOverflow;
        const headers = padded & ~@as(usize, 7);
        const size = std.math.add(usize, headers, @as(usize, self.count) * shdr_size) catch {
            return error.ObjectSizeOverflow;
        };
        std.debug.assert(size >= headers);
        return .{ .headers = headers, .size = size };
    }

    fn write(self: *const Sections, buffer: []u8, table_offset: usize) void {
        std.debug.assert(self.count <= self.headers.len);
        for (self.headers[0..self.count], 0..) |header, index| {
            writeSectionHeader(buffer, table_offset, @intCast(index), header);
        }
    }
};

const Symbols = struct {
    records: std.ArrayListUnmanaged(SymbolRecord) = .empty,
    indices: std.StringHashMapUnmanaged(u32) = .{},
    strings: StringTable,
    first_global: u32 = 0,

    fn init(allocator: Allocator) Allocator.Error!Symbols {
        return .{ .strings = try StringTable.init(allocator) };
    }

    fn deinit(self: *Symbols, allocator: Allocator) void {
        self.records.deinit(allocator);
        self.indices.deinit(allocator);
        self.strings.deinit(allocator);
        self.* = undefined;
    }

    /// Writes the table in the one order ELF permits: every local symbol first, then
    /// `first_global` and the rest. A section symbol is local, so the data sections announce
    /// themselves before any datum does.
    fn collect(
        self: *Symbols,
        allocator: Allocator,
        sections: Sections,
        layouts: SymbolLayouts,
        text: []const TextSymbol,
        relocations: []const Relocation,
    ) ObjectError!void {
        std.debug.assert(self.records.items.len == 0);
        const data_sections = [_]DataSectionSymbols{
            .{ .section = sections.rodata, .symbols = layouts.rodata },
            .{ .section = sections.data, .symbols = layouts.data },
            .{ .section = sections.bss, .symbols = layouts.bss },
        };
        try self.add(allocator, .{});
        try self.add(allocator, .{ .kind = .section, .section = sections.text });
        for (data_sections) |entry| {
            if (entry.section == 0) continue;
            try self.add(allocator, .{ .kind = .section, .section = entry.section });
        }
        for (data_sections) |entry| {
            if (entry.section == 0) continue;
            try self.data(allocator, entry.section, entry.symbols, .local);
        }
        self.first_global = @intCast(self.records.items.len);
        for (data_sections) |entry| {
            if (entry.section == 0) continue;
            try self.data(allocator, entry.section, entry.symbols, .global);
        }
        for (text) |symbol| try self.add(allocator, .{
            .name = symbol.name,
            .binding = .global,
            .kind = .function,
            .section = sections.text,
            .value = symbol.offset,
            .size = symbol.size,
        });
        for (relocations) |relocation| {
            if (self.indices.contains(relocation.symbol)) continue;
            try self.add(allocator, .{
                .name = relocation.symbol,
                .binding = .global,
                .kind = symbolKindForRelocation(relocation.kind),
                .section = std.elf.SHN_UNDEF,
            });
        }
        std.debug.assert(self.first_global <= self.records.items.len);
    }

    fn data(
        self: *Symbols,
        allocator: Allocator,
        section: u16,
        symbols: []const DataSymbolLayout,
        binding: machine.DataSymbolBinding,
    ) ObjectError!void {
        for (symbols) |symbol| {
            if (symbol.binding != binding) continue;
            try self.add(allocator, .{
                .name = symbol.name,
                .binding = if (binding == .local) .local else .global,
                .kind = .object,
                .section = section,
                .value = symbol.offset,
                .size = symbol.size,
            });
        }
    }

    fn add(self: *Symbols, allocator: Allocator, fields: SymbolFields) ObjectError!void {
        try appendSymbol(allocator, &self.strings, &self.records, &self.indices, fields);
    }
};

/// The sections a relocation may name. `.bss` is absent on purpose: a `SHT_NOBITS` section
/// occupies no file bytes, so there is no slot in the object to write an address into. A
/// relocation naming `.bss` is refused rather than silently dropped.
const RelocationTarget = enum(u2) { text = 0, rodata = 1, data = 2 };

const relocation_targets = [_]RelocationTarget{ .text, .rodata, .data };
const relocation_target_count = relocation_targets.len;

/// The byte length of each target section, indexed by `RelocationTarget`.
const TargetSizes = [relocation_target_count]usize;

const PlacedBytes = struct { section: u16, target: RelocationTarget, bytes: []const u8 };

const SymbolLayouts = struct {
    rodata: []const DataSymbolLayout,
    data: []const DataSymbolLayout,
    bss: []const DataSymbolLayout,
};

const DataSectionSymbols = struct { section: u16, symbols: []const DataSymbolLayout };

fn relocationTarget(section: []const u8) ObjectError!RelocationTarget {
    if (std.mem.eql(u8, section, ".text")) return .text;
    if (std.mem.eql(u8, section, ".rodata")) return .rodata;
    if (std.mem.eql(u8, section, ".data")) return .data;
    return error.UnsupportedRelocation;
}

/// Counts the relocations landing in one target. A section header is only written for a
/// target that has some, so this runs before any of them are built.
fn relocationCount(relocations: []const Relocation, target: RelocationTarget) usize {
    var count: usize = 0;
    for (relocations) |relocation| {
        const found = relocationTarget(relocation.section) catch continue;
        if (found == target) count += 1;
    }
    return count;
}

/// Every relocation record, ordered so that one target's records are contiguous. A
/// `SHT_RELA` section is a run of records, so grouping is what lets three sections share one
/// allocation.
const RelocationGroups = struct {
    records: []RelaRecord = &.{},
    starts: [relocation_target_count]usize = @splat(0),
    counts: [relocation_target_count]usize = @splat(0),

    fn slice(self: RelocationGroups, target: RelocationTarget) []const RelaRecord {
        const index = @backingInt(target);
        return self.records[self.starts[index]..][0..self.counts[index]];
    }

    fn deinit(self: *RelocationGroups, allocator: Allocator) void {
        if (self.records.len != 0) allocator.free(self.records);
        self.* = .{};
    }
};

fn collectRelocations(
    allocator: Allocator,
    input: RelocatableObject,
    sizes: TargetSizes,
    symbols: *const std.StringHashMapUnmanaged(u32),
) ObjectError!RelocationGroups {
    if (input.relocations.len == 0) return .{};
    const records = try allocator.alloc(RelaRecord, input.relocations.len);
    errdefer allocator.free(records);
    var groups: RelocationGroups = .{ .records = records };
    var written: usize = 0;
    for (relocation_targets) |target| {
        groups.starts[@backingInt(target)] = written;
        for (input.relocations) |relocation| {
            if ((try relocationTarget(relocation.section)) != target) continue;
            const symbol_index = symbols.get(relocation.symbol) orelse
                return error.MissingRelocationSymbol;
            const relocation_type = try x86_64RelocationType(relocation);
            try validateRelocationSlot(sizes[@backingInt(target)], relocation);
            records[written] = .{
                .offset = relocation.offset,
                .info = (@as(u64, symbol_index) << 32) | relocation_type,
                .addend = x86_64RelocationAddend(relocation),
            };
            written += 1;
        }
        groups.counts[@backingInt(target)] = written - groups.starts[@backingInt(target)];
    }
    std.debug.assert(written == input.relocations.len);
    return groups;
}

/// The bytes of one `SHT_PROGBITS` data section and where each of its symbols sits in them.
/// One data section's placed contents: the bytes the file carries, the extent those bytes
/// occupy once loaded, and where each symbol sits inside it.
///
/// `.bss` uses this type too. There `bytes` is empty and `size` is the extent, which is the one
/// difference between a section the file carries and a section the loader supplies.
const DataSectionLayout = struct {
    bytes: []u8 = &.{},
    size: usize = 0,
    symbols: []DataSymbolLayout = &.{},
    alignment: usize = 1,

    /// Packs the symbols belonging to `section` by the same rule as JIT data mappings. The
    /// packing itself stays with `machine.DataLayout`, so no section can drift from another.
    fn build(
        allocator: Allocator,
        symbols: []const machine.DataSymbol,
        section: machine.DataSection,
    ) ObjectError!DataSectionLayout {
        var count: usize = 0;
        for (symbols) |symbol| {
            if (symbol.section == section) count += 1;
        }
        if (count == 0) return .{};

        const selected = try allocator.alloc(machine.DataSymbol, count);
        defer allocator.free(selected);
        var filled: usize = 0;
        for (symbols) |symbol| {
            if (symbol.section != section) continue;
            selected[filled] = symbol;
            filled += 1;
        }
        std.debug.assert(filled == count);

        var layout = machine.DataLayout.init(allocator, selected) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidDataSymbol => error.InvalidDataSymbol,
            error.DataTooLarge => error.ObjectSizeOverflow,
        };
        defer layout.deinit(allocator);

        const placed = try allocator.alloc(DataSymbolLayout, count);
        errdefer allocator.free(placed);
        for (selected, layout.offsets, placed) |symbol, offset, *entry| {
            entry.* = .{
                .name = symbol.name,
                .binding = symbol.binding,
                .offset = offset,
                .size = symbol.size(),
            };
        }
        if (!section.carriesBytes()) {
            return .{ .size = layout.size, .symbols = placed, .alignment = layout.alignment };
        }

        const bytes = try allocator.alloc(u8, layout.size);
        layout.write(selected, bytes);
        return .{
            .bytes = bytes,
            .size = layout.size,
            .symbols = placed,
            .alignment = layout.alignment,
        };
    }

    fn deinit(self: *DataSectionLayout, allocator: Allocator) void {
        if (self.bytes.len != 0) allocator.free(self.bytes);
        if (self.symbols.len != 0) allocator.free(self.symbols);
        self.* = .{};
    }
};

const DataSymbolLayout = struct {
    name: []const u8,
    binding: machine.DataSymbolBinding,
    offset: u64,
    size: u64,
};

const StringTable = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn init(allocator: Allocator) Allocator.Error!StringTable {
        var table = StringTable{};
        try table.data.append(allocator, 0);
        return table;
    }

    fn deinit(self: *StringTable, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    fn add(self: *StringTable, allocator: Allocator, name: []const u8) Allocator.Error!u32 {
        const offset: u32 = @intCast(self.data.items.len);
        try self.data.appendSlice(allocator, name);
        try self.data.append(allocator, 0);
        return offset;
    }

    fn bytes(self: *const StringTable) []const u8 {
        return self.data.items;
    }
};

const SymbolBinding = enum {
    local,
    global,
};

const SymbolKind = enum {
    none,
    section,
    function,
    object,
};

const SymbolFields = struct {
    name: []const u8 = "",
    binding: SymbolBinding = .local,
    kind: SymbolKind = .none,
    section: u16 = std.elf.SHN_UNDEF,
    value: u64 = 0,
    size: u64 = 0,
};

const SymbolRecord = struct {
    name: u32 = 0,
    info: u8 = 0,
    other: u8 = 0,
    section: u16 = std.elf.SHN_UNDEF,
    value: u64 = 0,
    size: u64 = 0,
};

fn appendSymbol(
    allocator: Allocator,
    strtab: *StringTable,
    symbols: *std.ArrayListUnmanaged(SymbolRecord),
    symbol_indices: *std.StringHashMapUnmanaged(u32),
    fields: SymbolFields,
) ObjectError!void {
    if (fields.name.len != 0 and symbol_indices.contains(fields.name)) return error.DuplicateSymbol;

    const index: u32 = @intCast(symbols.items.len);
    const name_offset = if (fields.name.len == 0) 0 else try strtab.add(allocator, fields.name);
    try symbols.append(allocator, .{
        .name = name_offset,
        .info = (@as(u8, elfBinding(fields.binding)) << 4) | elfSymbolKind(fields.kind),
        .section = fields.section,
        .value = fields.value,
        .size = fields.size,
    });
    if (fields.name.len != 0) {
        try symbol_indices.putNoClobber(allocator, fields.name, index);
    }
}

const RelaRecord = struct {
    offset: u64,
    info: u64,
    addend: i64,
};

const ElfHeaderSpec = struct {
    section_header_offset: usize,
    section_count: u16,
    section_string_table_index: u16,
};

fn writeElfHeader(buffer: []u8, spec: ElfHeaderSpec) void {
    std.mem.copyForwards(u8, buffer[0..4], std.elf.MAGIC);
    buffer[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    buffer[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    buffer[std.elf.EI_VERSION] = 1;
    buffer[std.elf.EI_OSABI] = 0;

    writeU16(buffer, 16, @backingInt(std.elf.ET.REL));
    writeU16(buffer, 18, @backingInt(std.elf.EM.X86_64));
    writeU32(buffer, 20, 1);
    writeU64(buffer, 24, 0);
    writeU64(buffer, 32, 0);
    writeU64(buffer, 40, @intCast(spec.section_header_offset));
    writeU32(buffer, 48, 0);
    writeU16(buffer, 52, ehdr_size);
    writeU16(buffer, 54, 0);
    writeU16(buffer, 56, 0);
    writeU16(buffer, 58, shdr_size);
    writeU16(buffer, 60, spec.section_count);
    writeU16(buffer, 62, spec.section_string_table_index);
}

const SectionHeader = struct {
    name: u32 = 0,
    section_type: u32 = std.elf.SHT_NULL,
    flags: u64 = 0,
    address: u64 = 0,
    offset: usize = 0,
    size: usize = 0,
    link: u32 = 0,
    info: u32 = 0,
    alignment: usize = 0,
    entry_size: usize = 0,

    const null_header: SectionHeader = .{};
};

fn writeSectionHeader(buffer: []u8, table_offset: usize, section_index: u16, header: SectionHeader) void {
    const offset = table_offset + @as(usize, section_index) * shdr_size;
    writeU32(buffer, offset + 0, header.name);
    writeU32(buffer, offset + 4, header.section_type);
    writeU64(buffer, offset + 8, header.flags);
    writeU64(buffer, offset + 16, header.address);
    writeU64(buffer, offset + 24, @intCast(header.offset));
    writeU64(buffer, offset + 32, @intCast(header.size));
    writeU32(buffer, offset + 40, header.link);
    writeU32(buffer, offset + 44, header.info);
    writeU64(buffer, offset + 48, @intCast(header.alignment));
    writeU64(buffer, offset + 56, @intCast(header.entry_size));
}

fn writeSymbolRecords(buffer: []u8, offset: usize, symbols: []const SymbolRecord) void {
    for (symbols, 0..) |symbol, index| {
        const start = offset + index * sym_size;
        writeU32(buffer, start + 0, symbol.name);
        buffer[start + 4] = symbol.info;
        buffer[start + 5] = symbol.other;
        writeU16(buffer, start + 6, symbol.section);
        writeU64(buffer, start + 8, symbol.value);
        writeU64(buffer, start + 16, symbol.size);
    }
}

fn writeRelaRecords(buffer: []u8, offset: usize, records: []const RelaRecord) void {
    for (records, 0..) |record, index| {
        const start = offset + index * rela_size;
        writeU64(buffer, start + 0, record.offset);
        writeU64(buffer, start + 8, record.info);
        writeU64(buffer, start + 16, @bitCast(record.addend));
    }
}

fn copyInto(buffer: []u8, offset: usize, bytes: []const u8) void {
    if (bytes.len == 0) return;
    std.mem.copyForwards(u8, buffer[offset .. offset + bytes.len], bytes);
}

fn validateAlignment(alignment: usize) ObjectError!void {
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidAlignment;
}

fn validateTextSymbol(text_len: usize, symbol: TextSymbol) ObjectError!void {
    if (symbol.name.len == 0) return error.InvalidTextSymbol;
    if (symbol.offset > std.math.maxInt(usize) or symbol.size > std.math.maxInt(usize)) {
        return error.InvalidTextSymbol;
    }
    const offset: usize = @intCast(symbol.offset);
    const size: usize = @intCast(symbol.size);
    if (offset > text_len or size > text_len - offset) return error.InvalidTextSymbol;
}

fn validateRelocationSlot(section_len: usize, relocation: Relocation) ObjectError!void {
    const width_bytes = relocation.width_bits / 8;
    if (width_bytes == 0 or relocation.width_bits % 8 != 0) return error.UnsupportedRelocation;
    if (relocation.offset > std.math.maxInt(usize)) return error.InvalidRelocationOffset;
    const offset: usize = @intCast(relocation.offset);
    if (offset > section_len or width_bytes > section_len - offset) {
        return error.InvalidRelocationOffset;
    }
}

/// Zeroes every slot the linker will write in one section, so a stale value cannot be read
/// as an address if the relocation is never applied.
fn scrubRelocationSlots(
    bytes: []u8,
    relocations: []const Relocation,
    target: RelocationTarget,
) void {
    for (relocations) |relocation| {
        const found = relocationTarget(relocation.section) catch continue;
        if (found != target) continue;
        const width_bytes = relocation.width_bits / 8;
        const offset: usize = @intCast(relocation.offset);
        @memset(bytes[offset .. offset + width_bytes], 0);
    }
}

fn symbolKindForRelocation(kind: artifact.RelocationKind) SymbolKind {
    return switch (kind) {
        .call, .plt => .function,
        else => .none,
    };
}

fn elfBinding(binding: SymbolBinding) u8 {
    return switch (binding) {
        .local => std.elf.STB_LOCAL,
        .global => std.elf.STB_GLOBAL,
    };
}

fn elfSymbolKind(kind: SymbolKind) u8 {
    return switch (kind) {
        .none => std.elf.STT_NOTYPE,
        .section => std.elf.STT_SECTION,
        .function => std.elf.STT_FUNC,
        .object => std.elf.STT_OBJECT,
    };
}

fn x86_64RelocationType(relocation: Relocation) ObjectError!u64 {
    return switch (relocation.kind) {
        .call => switch (relocation.width_bits) {
            64 => @as(u64, @backingInt(std.elf.R_X86_64.@"64")),
            32 => @as(u64, @backingInt(std.elf.R_X86_64.PLT32)),
            else => error.UnsupportedRelocation,
        },
        .absolute => switch (relocation.width_bits) {
            64 => @as(u64, @backingInt(std.elf.R_X86_64.@"64")),
            32 => @as(u64, @backingInt(std.elf.R_X86_64.@"32")),
            else => error.UnsupportedRelocation,
        },
        .relative => switch (relocation.width_bits) {
            32 => @as(u64, @backingInt(std.elf.R_X86_64.PC32)),
            else => error.UnsupportedRelocation,
        },
        .plt => switch (relocation.width_bits) {
            32 => @as(u64, @backingInt(std.elf.R_X86_64.PLT32)),
            else => error.UnsupportedRelocation,
        },
        .got => switch (relocation.width_bits) {
            32 => @as(u64, @backingInt(std.elf.R_X86_64.GOTPCREL)),
            else => error.UnsupportedRelocation,
        },
        else => error.UnsupportedRelocation,
    };
}

fn x86_64RelocationAddend(relocation: Relocation) i64 {
    if (relocation.addend != 0) return relocation.addend;
    return switch (relocation.kind) {
        .call, .plt => if (relocation.width_bits == 32) -4 else 0,
        else => 0,
    };
}

fn writeU16(buffer: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, buffer[offset..][0..2], value, .little);
}

fn writeU32(buffer: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buffer[offset..][0..4], value, .little);
}

fn writeU64(buffer: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, buffer[offset..][0..8], value, .little);
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

const TestSection = struct {
    index: u16,
    name: []const u8,
    header_offset: usize,
    offset: usize,
    size: usize,
    section_type: u32,
    link: u32,
    info: u32,
    entry_size: usize,
};

fn findTestSection(object: []const u8, name: []const u8) ?TestSection {
    const shoff: usize = @intCast(readU64(object, 40));
    const shnum = readU16(object, 60);
    const shstrndx = readU16(object, 62);
    const shstr_header = shoff + @as(usize, shstrndx) * shdr_size;
    const shstr_offset: usize = @intCast(readU64(object, shstr_header + 24));
    const shstr_size: usize = @intCast(readU64(object, shstr_header + 32));
    const shstrtab = object[shstr_offset .. shstr_offset + shstr_size];

    for (0..shnum) |index| {
        const header_offset = shoff + index * shdr_size;
        const name_offset = readU32(object, header_offset);
        const actual_name = stringFromTable(shstrtab, name_offset);
        if (!std.mem.eql(u8, actual_name, name)) continue;
        return .{
            .index = @intCast(index),
            .name = actual_name,
            .header_offset = header_offset,
            .offset = @intCast(readU64(object, header_offset + 24)),
            .size = @intCast(readU64(object, header_offset + 32)),
            .section_type = readU32(object, header_offset + 4),
            .link = readU32(object, header_offset + 40),
            .info = readU32(object, header_offset + 44),
            .entry_size = @intCast(readU64(object, header_offset + 56)),
        };
    }
    return null;
}

fn testSymbolName(object: []const u8, symtab: TestSection, symbol_index: usize) []const u8 {
    const shoff: usize = @intCast(readU64(object, 40));
    const strtab_header = shoff + @as(usize, symtab.link) * shdr_size;
    const strtab_offset: usize = @intCast(readU64(object, strtab_header + 24));
    const strtab_size: usize = @intCast(readU64(object, strtab_header + 32));
    const strtab = object[strtab_offset .. strtab_offset + strtab_size];
    const symbol_offset = symtab.offset + symbol_index * sym_size;
    return stringFromTable(strtab, readU32(object, symbol_offset));
}

fn stringFromTable(table: []const u8, offset: u32) []const u8 {
    if (offset >= table.len) return "";
    const start: usize = @intCast(offset);
    const end = std.mem.indexOfScalarPos(u8, table, start, 0) orelse table.len;
    return table[start..end];
}

test "ELF64 objects declare their stack execution requirement" {
    for ([_]bool{ false, true }) |executable| {
        const bytes = try buildX86_64MachineCodeObject(std.testing.allocator, .{
            .entry_symbol = "value",
            .code = &.{0xc3},
            .executable_stack = executable,
        });
        defer std.testing.allocator.free(bytes);
        const section = findTestSection(bytes, ".note.GNU-stack").?;
        try std.testing.expectEqual(std.elf.SHT_PROGBITS, section.section_type);
        try std.testing.expectEqual(@as(usize, 0), section.size);
        const flags = readU64(bytes, section.header_offset + 8);
        try std.testing.expectEqual(
            @as(u64, if (executable) std.elf.SHF_EXECINSTR else 0),
            flags,
        );
    }
}

test "ELF64 object layout rejects unrepresentable section offsets before allocation" {
    var sections = Sections.init(
        .{ .entry_symbol = "value", .text = &.{0xc3} },
        .{},
        .{},
        .{},
    );
    sections.headers[sections.text].size = std.math.maxInt(usize);
    var symbols = try Symbols.init(std.testing.allocator);
    defer symbols.deinit(std.testing.allocator);
    try std.testing.expectError(error.ObjectSizeOverflow, sections.place(&symbols, .{}));
}

test "ELF64 relocatable object records x86_64 call slots" {
    const code = [_]u8{
        0x48, 0xb8,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0xff, 0xd0,
        0xc3,
    };
    const relocations = [_]machine.CallRelocation{
        .{ .offset = 2, .target = "__tiny_runtime_call" },
    };
    const object = try buildX86_64MachineCodeObject(std.testing.allocator, .{
        .entry_symbol = "tiny_entry",
        .code = &code,
        .relocations = &relocations,
    });
    defer std.testing.allocator.free(object);

    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, object[0..4]);
    try std.testing.expectEqual(@backingInt(std.elf.ET.REL), readU16(object, 16));
    try std.testing.expectEqual(@backingInt(std.elf.EM.X86_64), readU16(object, 18));

    const text = findTestSection(object, ".text").?;
    try std.testing.expectEqual(std.elf.SHT_PROGBITS, text.section_type);
    try std.testing.expectEqualSlices(u8, &code, object[text.offset .. text.offset + text.size]);

    const rela_text = findTestSection(object, ".rela.text").?;
    try std.testing.expectEqual(std.elf.SHT_RELA, rela_text.section_type);
    try std.testing.expectEqual(@as(u32, text.index), rela_text.info);
    try std.testing.expectEqual(@as(usize, rela_size), rela_text.entry_size);
    try std.testing.expectEqual(@as(u64, 2), readU64(object, rela_text.offset));

    const info = readU64(object, rela_text.offset + 8);
    const symbol_index: usize = @intCast(info >> 32);
    try std.testing.expectEqual(@as(u32, @backingInt(std.elf.R_X86_64.@"64")), @as(u32, @truncate(info)));
    try std.testing.expectEqual(@as(u64, 0), readU64(object, rela_text.offset + 16));

    const symtab = findTestSection(object, ".symtab").?;
    try std.testing.expectEqualStrings("__tiny_runtime_call", testSymbolName(object, symtab, symbol_index));
}

test "ELF64 relocatable object supports direct PLT32 call relocations" {
    const object = try buildRelocatableObject(std.testing.allocator, .{
        .entry_symbol = "tiny_entry",
        .text = &.{ 0xe8, 0, 0, 0, 0, 0xc3 },
        .relocations = &.{.{
            .offset = 1,
            .symbol = "__tiny_runtime_call",
            .kind = .call,
            .width_bits = 32,
        }},
    });
    defer std.testing.allocator.free(object);

    const rela_text = findTestSection(object, ".rela.text").?;
    const info = readU64(object, rela_text.offset + 8);
    try std.testing.expectEqual(@as(u32, @backingInt(std.elf.R_X86_64.PLT32)), @as(u32, @truncate(info)));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -4))), readU64(object, rela_text.offset + 16));
}

test "ELF64 relocatable object defines multiple text symbols" {
    const text_symbols = [_]TextSymbol{
        .{ .name = "tiny_entry", .offset = 0, .size = 4 },
        .{ .name = "tiny_helper", .offset = 16, .size = 3 },
    };
    const object = try buildRelocatableObject(std.testing.allocator, .{
        .entry_symbol = "tiny_entry",
        .text = &.{
            0x90, 0x90, 0x90, 0xc3,
            0,    0,    0,    0,
            0,    0,    0,    0,
            0,    0,    0,    0,
            0x90, 0x90, 0xc3,
        },
        .text_symbols = &text_symbols,
        .relocations = &.{.{
            .offset = 1,
            .symbol = "tiny_helper",
            .kind = .call,
            .width_bits = 32,
        }},
    });
    defer std.testing.allocator.free(object);

    const text = findTestSection(object, ".text").?;
    const symtab = findTestSection(object, ".symtab").?;
    var found_entry = false;
    var found_helper = false;
    const symbol_count = symtab.size / sym_size;
    for (0..symbol_count) |index| {
        const symbol_offset = symtab.offset + index * sym_size;
        const symbol_name = testSymbolName(object, symtab, index);
        if (std.mem.eql(u8, symbol_name, "tiny_entry")) {
            found_entry = true;
            try std.testing.expectEqual(text.index, readU16(object, symbol_offset + 6));
            try std.testing.expectEqual(@as(u64, 0), readU64(object, symbol_offset + 8));
            try std.testing.expectEqual(@as(u64, 4), readU64(object, symbol_offset + 16));
        }
        if (std.mem.eql(u8, symbol_name, "tiny_helper")) {
            found_helper = true;
            try std.testing.expectEqual(text.index, readU16(object, symbol_offset + 6));
            try std.testing.expectEqual(@as(u64, 16), readU64(object, symbol_offset + 8));
            try std.testing.expectEqual(@as(u64, 3), readU64(object, symbol_offset + 16));
        }
    }
    try std.testing.expect(found_entry);
    try std.testing.expect(found_helper);
}

test "ELF64 relocatable object lays out rodata symbols" {
    const data_symbols = [_]machine.DataSymbol{
        .{ .name = ".Lstring0", .bytes = "abc", .alignment = 8 },
        .{ .name = ".Lsymbol0", .bytes = "xy", .alignment = 4 },
    };
    const object = try buildRelocatableObject(std.testing.allocator, .{
        .entry_symbol = "tiny_entry",
        .text = &.{0xc3},
        .data_symbols = &data_symbols,
    });
    defer std.testing.allocator.free(object);

    const rodata = findTestSection(object, ".rodata").?;
    try std.testing.expectEqual(std.elf.SHT_PROGBITS, rodata.section_type);
    try std.testing.expectEqual(@as(usize, 8), readU64(object, rodata.header_offset + 48));
    try std.testing.expectEqualSlices(u8, "abc\x00xy", object[rodata.offset .. rodata.offset + rodata.size]);

    const symtab = findTestSection(object, ".symtab").?;
    var found_string = false;
    var found_symbol = false;
    const symbol_count = symtab.size / sym_size;
    for (0..symbol_count) |index| {
        const symbol_offset = symtab.offset + index * sym_size;
        const symbol_name = testSymbolName(object, symtab, index);
        if (std.mem.eql(u8, symbol_name, ".Lstring0")) {
            found_string = true;
            try std.testing.expectEqual(rodata.index, readU16(object, symbol_offset + 6));
            try std.testing.expectEqual(@as(u64, 0), readU64(object, symbol_offset + 8));
            try std.testing.expectEqual(@as(u64, 3), readU64(object, symbol_offset + 16));
        }
        if (std.mem.eql(u8, symbol_name, ".Lsymbol0")) {
            found_symbol = true;
            try std.testing.expectEqual(rodata.index, readU16(object, symbol_offset + 6));
            try std.testing.expectEqual(@as(u64, 4), readU64(object, symbol_offset + 8));
            try std.testing.expectEqual(@as(u64, 2), readU64(object, symbol_offset + 16));
        }
    }
    try std.testing.expect(found_string);
    try std.testing.expect(found_symbol);
}

test "ELF64 relocatable object can export rodata symbols" {
    const data_symbols = [_]machine.DataSymbol{
        .{
            .name = "__tiny_aot_runtime_import_count",
            .bytes = "\x01\x00\x00\x00\x00\x00\x00\x00",
            .alignment = 8,
            .binding = .global,
        },
    };
    const object = try buildRelocatableObject(std.testing.allocator, .{
        .entry_symbol = "tiny_entry",
        .text = &.{0xc3},
        .data_symbols = &data_symbols,
    });
    defer std.testing.allocator.free(object);

    const rodata = findTestSection(object, ".rodata").?;
    const symtab = findTestSection(object, ".symtab").?;

    var found_symbol = false;
    const symbol_count = symtab.size / sym_size;
    for (0..symbol_count) |index| {
        const symbol_offset = symtab.offset + index * sym_size;
        const symbol_name = testSymbolName(object, symtab, index);
        if (std.mem.eql(u8, symbol_name, "__tiny_aot_runtime_import_count")) {
            found_symbol = true;
            try std.testing.expectEqual(rodata.index, readU16(object, symbol_offset + 6));
            try std.testing.expectEqual(std.elf.STB_GLOBAL, object[symbol_offset + 4] >> 4);
            try std.testing.expectEqual(std.elf.STT_OBJECT, object[symbol_offset + 4] & 0xf);
        }
    }
    try std.testing.expect(found_symbol);
}

test "ELF64 relocatable object relocates text slots to rodata symbols" {
    const data_symbols = [_]machine.DataSymbol{
        .{ .name = ".Lstring0", .bytes = "abc", .alignment = 1 },
    };
    const object = try buildRelocatableObject(std.testing.allocator, .{
        .entry_symbol = "tiny_entry",
        .text = &.{ 0x48, 0xb8, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xc3 },
        .data_symbols = &data_symbols,
        .relocations = &.{.{
            .offset = 2,
            .symbol = ".Lstring0",
            .kind = .absolute,
            .width_bits = 64,
        }},
    });
    defer std.testing.allocator.free(object);

    const text = findTestSection(object, ".text").?;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
        object[text.offset + 2 .. text.offset + 10],
    );

    const rela_text = findTestSection(object, ".rela.text").?;
    const info = readU64(object, rela_text.offset + 8);
    const symbol_index: usize = @intCast(info >> 32);
    try std.testing.expectEqual(
        @as(u32, @backingInt(std.elf.R_X86_64.@"64")),
        @as(u32, @truncate(info)),
    );
    try std.testing.expectEqual(@as(u64, 0), readU64(object, rela_text.offset + 16));

    const symtab = findTestSection(object, ".symtab").?;
    try std.testing.expectEqualStrings(".Lstring0", testSymbolName(object, symtab, symbol_index));
}

/// One object the data-section tests agree on. A `.rodata` word holds the address of a `.data`
/// word, that word holds the address of a second `.data` word, a `.bss` reservation sits beside
/// them, and `_start` walks the chain and exits with what it finds. Every section and every
/// relocation direction the writer gained appears once, so the structural check and the run
/// check read the same artifact rather than two artifacts that might drift.
const DataSectionProbe = struct {
    const counter_initial: u8 = 40;
    const counter_increment: u8 = 2;
    const expected_status: u8 = counter_initial + counter_increment;
    const exit_syscall: u8 = 60;
    const reservation_size: usize = 16;
    const word_alignment: usize = 8;

    /// `.text` byte offsets of the two slots the linker fills with an absolute address.
    const counter_ptr_slot: u64 = 2;
    const scratch_slot: u64 = 25;
    /// `.data` byte offset of `counter_alias`, which is the second word of the section.
    const alias_slot: u64 = 8;

    const text = [_]u8{
        0x48, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x48, 0x8b, 0x00, 0x48, 0x8b, 0x00, 0x48, 0x83, 0x00, counter_increment,
        0x48, 0x8b, 0x38, 0x48, 0xbb, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x48, 0x03, 0x3b, 0x48, 0xc7, 0xc0, exit_syscall,
        0x00, 0x00, 0x00, 0x0f, 0x05,
    };

    const zero_word: [8]u8 = @splat(0);
    const counter_word = [_]u8{ counter_initial, 0, 0, 0, 0, 0, 0, 0 };

    const data_symbols = [_]machine.DataSymbol{
        .{
            .name = "counter_ptr",
            .bytes = &zero_word,
            .alignment = word_alignment,
            .binding = .global,
            .section = .rodata,
        },
        .{
            .name = "counter",
            .bytes = &counter_word,
            .alignment = word_alignment,
            .binding = .global,
            .section = .data,
        },
        .{
            .name = "counter_alias",
            .bytes = &zero_word,
            .alignment = word_alignment,
            .binding = .global,
            .section = .data,
        },
        .{
            .name = "scratch",
            .reserved_size = reservation_size,
            .alignment = word_alignment,
            .binding = .global,
            .section = .bss,
        },
    };

    const relocations = [_]Relocation{
        .{ .offset = counter_ptr_slot, .symbol = "counter_ptr", .kind = .absolute },
        .{ .offset = scratch_slot, .symbol = "scratch", .kind = .absolute },
        .{ .section = ".rodata", .offset = 0, .symbol = "counter_alias", .kind = .absolute },
        .{ .section = ".data", .offset = alias_slot, .symbol = "counter", .kind = .absolute },
    };

    fn build(allocator: Allocator) ObjectError![]u8 {
        return buildRelocatableObject(allocator, .{
            .entry_symbol = "_start",
            .text = &text,
            .data_symbols = &data_symbols,
            .relocations = &relocations,
        });
    }
};

fn expectSectionFlags(object: []const u8, section: TestSection, flags: u64) !void {
    try std.testing.expectEqual(flags, readU64(object, section.header_offset + 8));
}

test "ELF64 relocatable object carries writable data beside a zero reservation" {
    const object = try DataSectionProbe.build(std.testing.allocator);
    defer std.testing.allocator.free(object);

    const data = findTestSection(object, ".data").?;
    try std.testing.expectEqual(std.elf.SHT_PROGBITS, data.section_type);
    try expectSectionFlags(object, data, std.elf.SHF_ALLOC | std.elf.SHF_WRITE);
    try std.testing.expectEqual(@as(usize, 16), data.size);
    try std.testing.expectEqual(
        @as(u64, DataSectionProbe.counter_initial),
        readU64(object, data.offset),
    );

    const bss = findTestSection(object, ".bss").?;
    try std.testing.expectEqual(std.elf.SHT_NOBITS, bss.section_type);
    try expectSectionFlags(object, bss, std.elf.SHF_ALLOC | std.elf.SHF_WRITE);
    try std.testing.expectEqual(DataSectionProbe.reservation_size, bss.size);

    const rodata = findTestSection(object, ".rodata").?;
    try expectSectionFlags(object, rodata, std.elf.SHF_ALLOC);

    const symtab = findTestSection(object, ".symtab").?;
    var counter_section: u16 = 0;
    var scratch_section: u16 = 0;
    var scratch_value: u64 = 0;
    for (0..symtab.size / sym_size) |index| {
        const record = symtab.offset + index * sym_size;
        const name = testSymbolName(object, symtab, index);
        if (std.mem.eql(u8, name, "counter")) {
            counter_section = readU16(object, record + 6);
            const info = (@as(u8, std.elf.STB_GLOBAL) << 4) | @as(u8, std.elf.STT_OBJECT);
            try std.testing.expectEqual(info, object[record + 4]);
        }
        if (std.mem.eql(u8, name, "scratch")) {
            scratch_section = readU16(object, record + 6);
            scratch_value = readU64(object, record + 8);
            const size = readU64(object, record + 16);
            try std.testing.expectEqual(@as(u64, DataSectionProbe.reservation_size), size);
        }
    }
    try std.testing.expectEqual(data.index, counter_section);
    try std.testing.expectEqual(bss.index, scratch_section);
    try std.testing.expectEqual(@as(u64, 0), scratch_value);
}

test "ELF64 bss reservations cost no file bytes" {
    const text = [_]u8{0xc3};
    const small = try buildRelocatableObject(std.testing.allocator, .{
        .entry_symbol = "_start",
        .text = &text,
        .data_symbols = &.{
            .{ .name = "scratch", .reserved_size = 16, .alignment = 8, .section = .bss },
        },
    });
    defer std.testing.allocator.free(small);
    const huge_size = 1 << 20;
    const huge = try buildRelocatableObject(std.testing.allocator, .{
        .entry_symbol = "_start",
        .text = &text,
        .data_symbols = &.{
            .{ .name = "scratch", .reserved_size = huge_size, .alignment = 8, .section = .bss },
        },
    });
    defer std.testing.allocator.free(huge);

    try std.testing.expectEqual(small.len, huge.len);
    try std.testing.expectEqual(@as(usize, huge_size), findTestSection(huge, ".bss").?.size);
}

test "ELF64 relocatable object relocates from rodata and from data" {
    const object = try DataSectionProbe.build(std.testing.allocator);
    defer std.testing.allocator.free(object);

    const symtab = findTestSection(object, ".symtab").?;
    const absolute_64: u32 = @backingInt(std.elf.R_X86_64.@"64");

    const rela_text = findTestSection(object, ".rela.text").?;
    try std.testing.expectEqual(@as(u32, findTestSection(object, ".text").?.index), rela_text.info);
    try std.testing.expectEqual(@as(usize, 2 * rela_size), rela_text.size);

    const rela_rodata = findTestSection(object, ".rela.rodata").?;
    const rodata_index = findTestSection(object, ".rodata").?.index;
    try std.testing.expectEqual(@as(u32, rodata_index), rela_rodata.info);
    try std.testing.expectEqual(@as(usize, rela_size), rela_rodata.size);
    try std.testing.expectEqual(@as(u64, 0), readU64(object, rela_rodata.offset));
    const rodata_info = readU64(object, rela_rodata.offset + 8);
    try std.testing.expectEqual(absolute_64, @as(u32, @truncate(rodata_info)));
    try std.testing.expectEqualStrings(
        "counter_alias",
        testSymbolName(object, symtab, @intCast(rodata_info >> 32)),
    );

    const rela_data = findTestSection(object, ".rela.data").?;
    try std.testing.expectEqual(@as(u32, findTestSection(object, ".data").?.index), rela_data.info);
    try std.testing.expectEqual(@as(usize, rela_size), rela_data.size);
    try std.testing.expectEqual(DataSectionProbe.alias_slot, readU64(object, rela_data.offset));
    const data_info = readU64(object, rela_data.offset + 8);
    try std.testing.expectEqual(absolute_64, @as(u32, @truncate(data_info)));
    try std.testing.expectEqualStrings(
        "counter",
        testSymbolName(object, symtab, @intCast(data_info >> 32)),
    );

    try std.testing.expectEqual(@as(u32, symtab.index), rela_rodata.link);
    try std.testing.expectEqual(@as(u32, symtab.index), rela_data.link);
}

test "ELF64 writer refuses a relocation into a section with no file bytes" {
    try std.testing.expectError(error.UnsupportedRelocation, buildRelocatableObject(
        std.testing.allocator,
        .{
            .entry_symbol = "_start",
            .text = &.{0xc3},
            .data_symbols = &.{
                .{ .name = "scratch", .reserved_size = 8, .alignment = 8, .section = .bss },
            },
            .relocations = &.{.{
                .section = ".bss",
                .offset = 0,
                .symbol = "scratch",
                .kind = .absolute,
            }},
        },
    ));
}

/// Where a caller names the `tldr-link` binary. The linker is another package's artifact and
/// nothing in this package's build graph produces it, so the gate reads a path rather than
/// guessing one, and reports absence as a skip rather than a pass.
const tldr_link_env = "CHOIR_TLDR_LINK";

fn expectExitCode(process_io: anytype, argv: []const []const u8, expected: i64) !void {
    var child = try sys.process.spawn(process_io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer sys.process.killAndReap(&child, process_io);
    const termination = try sys.process.wait(&child, process_io);
    try std.testing.expectEqual(expected, sys.process.exitCode(termination));
}

test "ELF64 data sections link and run through tldr" {
    if (!sys.capabilities.current.isLinux()) return error.SkipZigTest;
    if (!sys.capabilities.current.supportsX86_64Execution()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const linker = (try sys.env.getOwned(allocator, tldr_link_env)) orelse return error.SkipZigTest;
    defer allocator.free(linker);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.parent_dir.realPathFileAlloc(
        std.Options.debug_io,
        tmp.sub_path[0..],
        allocator,
    );
    defer allocator.free(root);
    const object_path = try std.fs.path.join(allocator, &.{ root, "probe.o" });
    defer allocator.free(object_path);
    const program_path = try std.fs.path.join(allocator, &.{ root, "probe" });
    defer allocator.free(program_path);

    const object = try DataSectionProbe.build(allocator);
    defer allocator.free(object);
    try sys.fs.writeFile(object_path, object);

    var io_state = sys.thread.initThreadedIo(allocator, .{});
    defer io_state.deinit();
    const process_io = io_state.io();

    const link_argv = [_][]const u8{ linker, "-o", program_path, "-e", "_start", object_path };
    try expectExitCode(process_io, &link_argv, 0);
    try expectExitCode(process_io, &.{program_path}, DataSectionProbe.expected_status);
}

comptime {
    alloc_phase.capacity.declareDynamicUnbounded("choir.elf_symbols", Symbols);
}
