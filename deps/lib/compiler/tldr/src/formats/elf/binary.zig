const std = @import("std");
const root = @import("../../root.zig");
const record = @import("record.zig");

const model = root.model;
const native_endian = record.native_endian;
const shdr_size = record.shdr_size;
const SectionHeader = record.SectionHeader;
const Symbol = record.Symbol;
const SymbolRecord = record.SymbolRecord;
const byte = @import("byte.zig");

const readU16 = byte.readU16;
const readU32 = byte.readU32;
const readU64 = byte.readU64;

pub fn sectionBytes(bytes: []const u8, section: SectionHeader) model.Error![]const u8 {
    if (section.section_type == std.elf.SHT_NOBITS) return &.{};
    try requireRange(bytes, section.offset, section.size);
    const start: usize = @intCast(section.offset);
    const size: usize = @intCast(section.size);
    return bytes[start .. start + size];
}

pub fn isElf(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], std.elf.MAGIC);
}

pub fn requireRange(bytes: []const u8, offset: u64, size: u64) model.Error!void {
    if (offset > bytes.len) return error.InvalidRange;
    if (size > bytes.len - offset) return error.InvalidRange;
}

pub fn stringFromTable(table: []const u8, offset: u32) model.Error![]const u8 {
    if (offset >= table.len) return error.InvalidStringTable;
    const start: usize = @intCast(offset);
    const end = std.mem.indexOfScalarPos(u8, table, start, 0) orelse return error.InvalidStringTable;
    return table[start..end];
}

pub fn decodeSectionHeaders(bytes: []const u8, shoff: u64, sections: []SectionHeader) void {
    if (native_endian == .little) {
        const start: usize = @intCast(shoff);
        const byte_count = sections.len * shdr_size;
        @memcpy(std.mem.sliceAsBytes(sections), bytes[start..][0..byte_count]);
        return;
    }

    for (sections, 0..) |*section, index| {
        const offset: u64 = shoff + @as(u64, @intCast(index)) * shdr_size;
        section.* = readSectionHeader(bytes, offset);
    }
}

pub fn readSectionHeader(bytes: []const u8, offset: u64) SectionHeader {
    const start: usize = @intCast(offset);
    return .{
        .name_offset = readU32(bytes[start..], 0),
        .section_type = readU32(bytes[start..], 4),
        .flags = readU64(bytes[start..], 8),
        .address = readU64(bytes[start..], 16),
        .offset = readU64(bytes[start..], 24),
        .size = readU64(bytes[start..], 32),
        .link = readU32(bytes[start..], 40),
        .info = readU32(bytes[start..], 44),
        .alignment = readU64(bytes[start..], 48),
        .entry_size = readU64(bytes[start..], 56),
    };
}

/// Decodes one 24-byte ELF64 symbol table entry, stored little-endian, into its
/// on-disk record so the entry's byte layout is read in one place. The function
/// is the only decoder of that entry: `readSymbol` and `View.symbol` both call
/// it.
pub fn readSymbolRecord(bytes: []const u8) SymbolRecord {
    return .{
        .name_offset = readU32(bytes, 0),
        .info = bytes[4],
        .other = bytes[5],
        .section_index = readU16(bytes, 6),
        .value = readU64(bytes, 8),
        .size = readU64(bytes, 16),
    };
}

/// Decodes one symbol table entry into the parsed symbol shape, by way of
/// `readSymbolRecord`. The object parser calls this function for each entry of
/// a symbol table before it resolves the names. The result's `name` is empty,
/// because the name lives in the symbol string table, which the caller holds
/// and looks up afterwards.
pub fn readSymbol(bytes: []const u8) Symbol {
    const wire = readSymbolRecord(bytes);
    return .{
        .name_offset = wire.name_offset,
        .info = wire.info,
        .other = wire.other,
        .section_index = wire.section_index,
        .value = wire.value,
        .size = wire.size,
    };
}

pub fn validateAlignment(alignment: u64) model.Error!void {
    if (alignment == 0) return;
    if ((alignment & (alignment - 1)) != 0) return error.InvalidAlignment;
}

pub fn alignForward(value: usize, alignment: usize) usize {
    if (alignment == 0) return value;
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}

pub fn alignForwardU64(value: u64, alignment: u64) u64 {
    if (alignment == 0) return value;
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}
