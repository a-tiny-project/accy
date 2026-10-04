const std = @import("std");
const macho = @import("root.zig");
const f = macho.format;
const machine = @import("../root.zig").machine_code;
const Allocator = std.mem.Allocator;
const ObjectError = f.ObjectError;
const alloc_phase = @import("alloc_phase");

pub const WriteResult = union(enum) {
    written: usize,
    short_buffer: struct { required: usize, available: usize },
};

pub const ByteCounts = struct {
    header_commands: u64 = f.header_bytes,
    initialized_payload: u64,
    padding: u64,
    relocations: u64,
    symbols: u64,
    strings: u64,
    file: u64,
    virtual_sections: [4]u64,
    bss_reservation: u64,
};

pub const SectionLayout = struct {
    address: u64 = 0,
    size: u64 = 0,
    alignment: usize = 1,
    file_offset: u32 = 0,
    relocation_offset: u32 = 0,
    relocation_count: u32 = 0,
};

const Symbol = struct {
    name: []const u8,
    string_offset: u32,
    section: ?f.Section,
    offset: u64,
    binding: machine.DataSymbolBinding,
};
const DataPlacement = struct { section: f.Section, offset: u64 };
const Fixup = struct { source: f.Relocation, symbol_index: u32 };

/// Construction owns structural scratch, and borrows input names and payloads.
/// BSS reservation never sizes an allocation or a file write.
pub const Layout = struct {
    input: f.RelocatableObject,
    sections: [4]SectionLayout = @splat(.{}),
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    indices: std.StringHashMapUnmanaged(u32) = .{},
    strings: std.ArrayListUnmanaged(u8) = .empty,
    placements: []DataPlacement = &.{},
    fixups: []Fixup = &.{},
    symbol_offset: u32 = 0,
    string_offset: u32 = 0,
    counts: ByteCounts = undefined,

    pub fn init(allocator: Allocator, input: f.RelocatableObject) ObjectError!Layout {
        var self: Layout = .{ .input = input };
        errdefer self.deinit(allocator);
        if (input.text.len > std.math.maxInt(u32) or input.text_symbols.len > 0x1000000 or
            input.data_symbols.len > 0x1000000 or
            input.relocations.len > std.math.maxInt(u32) / f.relocation_bytes)
            return error.ObjectSizeOverflow;
        try f.validateAlignment(input.text_alignment);
        self.sections[0].alignment = input.text_alignment;
        self.sections[0].size = input.text.len;
        try validateText(allocator, input);
        self.placements = try allocator.alloc(DataPlacement, input.data_symbols.len);
        var payload: u64 = input.text.len;
        for (input.data_symbols, self.placements) |symbol, *placement| {
            try f.validateName(symbol.name);
            if (!symbol.isValid()) return error.InvalidDataSymbol;
            const section = f.Section.ofData(symbol.section);
            const layout = &self.sections[@backingInt(section)];
            layout.alignment = @max(layout.alignment, symbol.alignment);
            const offset = try f.alignForward(layout.size, symbol.alignment);
            layout.size = try f.add(offset, symbol.size());
            placement.* = .{ .section = section, .offset = offset };
            payload = try f.add(payload, symbol.bytes.len);
        }
        try self.strings.append(allocator, 0);
        for (input.text_symbols) |symbol| try self.addSymbol(allocator, .{
            .name = symbol.name,
            .section = .text,
            .offset = symbol.offset,
            .binding = symbol.binding,
            .string_offset = 0,
        });
        for (input.data_symbols, self.placements) |symbol, placement| try self.addSymbol(
            allocator,
            .{
                .name = symbol.name,
                .section = placement.section,
                .offset = placement.offset,
                .binding = symbol.binding,
                .string_offset = 0,
            },
        );
        self.fixups = try allocator.alloc(Fixup, input.relocations.len);
        for (input.relocations, self.fixups) |relocation, *fixup| {
            try self.validateRelocation(relocation);
            if (!self.indices.contains(relocation.symbol)) try self.addSymbol(allocator, .{
                .name = relocation.symbol,
                .section = null,
                .offset = 0,
                .binding = .global,
                .string_offset = 0,
            });
            fixup.* = .{
                .source = relocation,
                .symbol_index = self.indices.get(relocation.symbol).?,
            };
        }
        std.mem.sort(Fixup, self.fixups, {}, fixupLess);
        for (self.fixups, 0..) |fixup, index| {
            if (index != 0) {
                const previous = self.fixups[index - 1].source;
                if (previous.section == fixup.source.section and
                    previous.offset - fixup.source.offset < 8)
                    return error.OverlappingRelocations;
            }
            const section = &self.sections[@backingInt(fixup.source.section)];
            if (section.relocation_count == std.math.maxInt(u32)) return error.ObjectSizeOverflow;
            section.relocation_count += 1;
        }
        try self.place(payload);
        return self;
    }

    pub fn deinit(self: *Layout, allocator: Allocator) void {
        self.symbols.deinit(allocator);
        self.indices.deinit(allocator);
        self.strings.deinit(allocator);
        allocator.free(self.placements);
        allocator.free(self.fixups);
        self.* = undefined;
    }

    pub fn byteCounts(self: *const Layout) ByteCounts {
        return self.counts;
    }

    pub fn requiredBytes(self: *const Layout) usize {
        return @intCast(self.counts.file);
    }

    /// Writes exactly requiredBytes, allocates nothing, and leaves a short buffer untouched.
    /// The caller supplies output disjoint from this Layout, construction scratch, and all
    /// borrowed input storage (including descriptors, names, and payloads). Those borrows
    /// remain valid through write and deinit.
    pub fn write(self: *const Layout, buffer: []u8) WriteResult {
        const required = self.requiredBytes();
        if (buffer.len < required) return .{ .short_buffer = .{
            .required = required,
            .available = buffer.len,
        } };
        const out = buffer[0..required];
        std.debug.assert(
            self.counts.file == self.counts.header_commands + self.counts.initialized_payload +
                self.counts.padding +
                self.counts.relocations + self.counts.symbols + self.counts.strings,
        );
        std.debug.assert(
            self.sections[3].file_offset == 0 and self.sections[3].relocation_count == 0,
        );
        @memset(out, 0);
        @memcpy(out[self.sections[0].file_offset..][0..self.input.text.len], self.input.text);
        for (self.input.data_symbols, self.placements) |symbol, placement| {
            if (placement.section == .bss) continue;
            const section = self.sections[@backingInt(placement.section)];
            const offset: usize = @intCast(section.file_offset + placement.offset);
            @memcpy(out[offset..][0..symbol.bytes.len], symbol.bytes);
        }
        self.writeHeaders(out);
        var indices: [4]usize = @splat(0);
        for (self.fixups) |fixup| {
            const source = fixup.source;
            const section_index = @backingInt(source.section);
            const section = self.sections[section_index];
            const record = section.relocation_offset + indices[section_index] * f.relocation_bytes;
            f.put(u32, out, record, @intCast(source.offset));
            f.put(u32, out, record + 4, fixup.symbol_index | (3 << 25) | (1 << 27));
            const slot: usize = @intCast(section.file_offset + source.offset);
            f.put(u64, out, slot, @bitCast(source.addend));
            indices[section_index] += 1;
        }
        for (self.symbols.items, 0..) |symbol, index| {
            const record = self.symbol_offset + index * f.symbol_bytes;
            f.put(u32, out, record, symbol.string_offset);
            out[record + 4] = (if (symbol.section != null) @as(u8, 0x0e) else 0) |
                (if (symbol.binding == .global) @as(u8, 1) else 0);
            if (symbol.section) |section| {
                out[record + 5] = section.ordinal();
                f.put(
                    u64,
                    out,
                    record + 8,
                    self.sections[@backingInt(section)].address + symbol.offset,
                );
            }
        }
        @memcpy(out[self.string_offset..][0..self.strings.items.len], self.strings.items);
        return .{ .written = required };
    }

    fn addSymbol(self: *Layout, allocator: Allocator, symbol: Symbol) ObjectError!void {
        try f.validateName(symbol.name);
        if (self.symbols.items.len > 0xffffff) return error.ObjectSizeOverflow;
        if (self.indices.contains(symbol.name)) return error.DuplicateSymbol;
        const string_end = try f.add(self.strings.items.len, try f.add(symbol.name.len, 1));
        if (string_end > std.math.maxInt(u32)) return error.ObjectSizeOverflow;
        var record = symbol;
        record.string_offset = @intCast(self.strings.items.len);
        try self.indices.put(allocator, symbol.name, @intCast(self.symbols.items.len));
        try self.symbols.append(allocator, record);
        try self.strings.appendSlice(allocator, symbol.name);
        try self.strings.append(allocator, 0);
    }

    fn validateRelocation(self: *const Layout, relocation: f.Relocation) ObjectError!void {
        try f.validateName(relocation.symbol);
        if (relocation.section == .bss or relocation.width_bits != 64 or
            (relocation.kind != .absolute and relocation.kind != .call) or
            (relocation.kind ==
                .call and relocation.addend != 0)) return error.UnsupportedRelocation;
        const end = try f.add(relocation.offset, 8);
        if (end > self.sections[@backingInt(relocation.section)].size or
            relocation.offset > std.math.maxInt(i32)) return error.InvalidRelocationOffset;
    }

    fn place(self: *Layout, payload: u64) ObjectError!void {
        var file: u64 = f.header_bytes;
        var virtual: u64 = 0;
        for (&self.sections, 0..) |*section, index| {
            section.address = try f.alignForward(virtual, section.alignment);
            virtual = try f.add(section.address, section.size);
            if (index == 3) continue;
            file = try f.alignForward(file, section.alignment);
            section.file_offset = try fileOffset(file);
            file = try f.add(file, section.size);
        }
        file = try f.alignForward(file, 4);
        for (&self.sections) |*section| {
            if (section.relocation_count == 0) continue;
            section.relocation_offset = try fileOffset(file);
            file = try f.add(file, try f.multiply(section.relocation_count, f.relocation_bytes));
        }
        file = try f.alignForward(file, 8);
        self.symbol_offset = try fileOffset(file);
        const symbols = try f.multiply(self.symbols.items.len, f.symbol_bytes);
        file = try f.add(file, symbols);
        self.string_offset = try fileOffset(file);
        file = try f.add(file, self.strings.items.len);
        _ = try fileOffset(file);
        if (file > std.math.maxInt(usize)) return error.ObjectSizeOverflow;
        const relocations = try f.multiply(self.fixups.len, f.relocation_bytes);
        self.counts = .{
            .initialized_payload = payload,
            .padding = file - f.header_bytes -
                payload - relocations - symbols - self.strings.items.len,
            .relocations = relocations,
            .symbols = symbols,
            .strings = self.strings.items.len,
            .file = file,
            .virtual_sections = .{
                self.sections[0].size,
                self.sections[1].size,
                self.sections[2].size,
                self.sections[3].size,
            },
            .bss_reservation = self.sections[3].size,
        };
    }

    fn writeHeaders(self: *const Layout, out: []u8) void {
        f.put(u32, out, 0, 0xfeedfacf);
        f.put(u32, out, 4, 0x0100000c);
        f.put(u32, out, 12, 1);
        f.put(u32, out, 16, 2);
        f.put(u32, out, 20, f.header_bytes - 32);
        f.put(u32, out, 32, 0x19);
        f.put(u32, out, 36, 72 + 4 * 80);
        const bss = self.sections[3];
        f.put(u64, out, 64, bss.address + bss.size);
        f.put(u64, out, 72, self.sections[0].file_offset);
        const data = self.sections[2];
        f.put(u64, out, 80, data.file_offset + data.size - self.sections[0].file_offset);
        f.put(u32, out, 88, 7);
        f.put(u32, out, 92, 7);
        f.put(u32, out, 96, 4);
        const names = [_][]const u8{ "__text", "__const", "__data", "__bss" };
        for (self.sections, 0..) |section, index| {
            const record = 104 + index * 80;
            f.name(out, record, names[index]);
            f.name(out, record + 16, if (index < 2) "__TEXT" else "__DATA");
            f.put(u64, out, record + 32, section.address);
            f.put(u64, out, record + 40, section.size);
            f.put(u32, out, record + 48, section.file_offset);
            f.put(u32, out, record + 52, @intCast(@ctz(section.alignment)));
            f.put(u32, out, record + 56, section.relocation_offset);
            f.put(u32, out, record + 60, section.relocation_count);
            f.put(u32, out, record + 64, if (index == 0) 0x400 else if (index == 3) 1 else 0);
        }
        f.put(u32, out, 424, 2);
        f.put(u32, out, 428, 24);
        f.put(u32, out, 432, self.symbol_offset);
        f.put(u32, out, 436, @intCast(self.symbols.items.len));
        f.put(u32, out, 440, self.string_offset);
        f.put(u32, out, 444, @intCast(self.strings.items.len));
    }
};

fn fileOffset(offset: u64) ObjectError!u32 {
    return std.math.cast(u32, offset) orelse error.ObjectSizeOverflow;
}

fn fixupLess(_: void, left: Fixup, right: Fixup) bool {
    if (left.source.section != right.source.section) {
        return @backingInt(left.source.section) < @backingInt(right.source.section);
    }
    return left.source.offset > right.source.offset;
}

fn textLess(_: void, left: f.TextSymbol, right: f.TextSymbol) bool {
    return left.offset < right.offset;
}

fn validateText(allocator: Allocator, input: f.RelocatableObject) ObjectError!void {
    const sorted = try allocator.dupe(f.TextSymbol, input.text_symbols);
    defer allocator.free(sorted);
    std.mem.sort(f.TextSymbol, sorted, {}, textLess);
    var end: u64 = 0;
    for (sorted) |symbol| {
        try f.validateName(symbol.name);
        if (symbol.size == 0 or symbol.offset < end) return error.InvalidTextSymbol;
        end = try f.add(symbol.offset, symbol.size);
        if (end > input.text.len) return error.InvalidTextSymbol;
    }
}

comptime {
    alloc_phase.capacity.declareDynamicUnbounded("choir.macho_layout", Layout);
}
