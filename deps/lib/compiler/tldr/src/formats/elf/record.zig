const builtin = @import("builtin");
const std = @import("std");
const byte = @import("byte.zig");

const readU16 = byte.readU16;
const readU32 = byte.readU32;
const readU64 = byte.readU64;
const writeU16 = byte.writeU16;
const writeU32 = byte.writeU32;
const writeU64 = byte.writeU64;

pub const ehdr_size = 64;
pub const phdr_size = 56;
pub const shdr_size = 64;
pub const sym_size = 24;
pub const rela_size = 24;
pub const group_word_size = 4;
pub const native_endian = builtin.cpu.arch.endian();
pub const build_id_note_desc_offset = 16;
pub const build_id_fast_desc_size = 8;
pub const build_id_sha1_desc_size = 20;
pub const eh_frame_hdr_fixed_size = 12;
pub const eh_frame_hdr_entry_size = 8;
pub const dwarf_eh_pe_udata4: u8 = 0x03;
pub const dwarf_eh_pe_sdata4: u8 = 0x0b;
pub const dwarf_eh_pe_pcrel: u8 = 0x10;
pub const dwarf_eh_pe_datarel: u8 = 0x30;

pub const parallel_relocation_threshold = 50_000;
pub const relocations_per_worker = 25_000;

pub const HeaderError = error{
    InvalidElfHeader,
    UnsupportedFormat,
};

/// The ELF64 file header fields a producer picks: object type, machine, entry
/// address, flags, and the offsets, counts and name table index of the program
/// and section header tables. `write` supplies the fields the format fixes: the
/// magic bytes, the 64-bit class, the little-endian encoding, version 1, and
/// the sizes of the file header, a program header and a section header, so the
/// struct has no fields for them.
pub const Header = struct {
    type: std.elf.ET = .REL,
    machine: std.elf.EM = .X86_64,
    entry: u64 = 0,
    flags: u32 = 0,
    phoff: u64 = 0,
    phnum: u16 = 0,
    shoff: u64 = 0,
    shnum: u16 = 0,
    shstrndx: u16 = 0,

    /// Fills the first 64 bytes of `buffer` with the header, zeroing the bytes
    /// it does not set. A program header entry size is written only when
    /// `phnum` is nonzero, so a relocatable object records no entry size for a
    /// table it lacks.
    pub fn write(self: Header, buffer: []u8) void {
        const out = buffer[0..ehdr_size];
        @memset(out, 0);
        std.mem.copyForwards(u8, out[0..4], std.elf.MAGIC);
        out[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
        out[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
        out[std.elf.EI_VERSION] = 1;
        writeU16(out, 16, @backingInt(self.type));
        writeU16(out, 18, @backingInt(self.machine));
        writeU32(out, 20, 1);
        writeU64(out, 24, self.entry);
        writeU64(out, 32, self.phoff);
        writeU64(out, 40, self.shoff);
        writeU32(out, 48, self.flags);
        writeU16(out, 52, ehdr_size);
        writeU16(out, 54, if (self.phnum == 0) 0 else phdr_size);
        writeU16(out, 56, self.phnum);
        writeU16(out, 58, shdr_size);
        writeU16(out, 60, self.shnum);
        writeU16(out, 62, self.shstrndx);
    }
};

/// Decodes the file header at the start of `bytes`. The call returns
/// `error.InvalidElfHeader` for fewer than 64 bytes, wrong magic bytes, or
/// header or section entry sizes other than ELF64's, and
/// `error.UnsupportedFormat` for a 32-bit or big-endian file. Object type and
/// machine pass through unchecked, because accepting or refusing them is the
/// linker's decision and the record has no rule about them.
pub fn readHeader(bytes: []const u8) HeaderError!Header {
    if (bytes.len < ehdr_size) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return error.InvalidElfHeader;
    if (bytes[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return error.UnsupportedFormat;
    if (bytes[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return error.UnsupportedFormat;
    if (readU16(bytes, 52) != ehdr_size) return error.InvalidElfHeader;
    if (readU16(bytes, 58) != shdr_size) return error.InvalidElfHeader;
    return .{
        .type = @fromBackingInt(@intCast(readU16(bytes, 16))),
        .machine = @fromBackingInt(@intCast(readU16(bytes, 18))),
        .entry = readU64(bytes, 24),
        .flags = readU32(bytes, 48),
        .phoff = readU64(bytes, 32),
        .phnum = readU16(bytes, 56),
        .shoff = readU64(bytes, 40),
        .shnum = readU16(bytes, 60),
        .shstrndx = readU16(bytes, 62),
    };
}

pub const SectionHeader = extern struct {
    name_offset: u32 = 0,
    section_type: u32 = std.elf.SHT_NULL,
    flags: u64 = 0,
    address: u64 = 0,
    offset: u64 = 0,
    size: u64 = 0,
    link: u32 = 0,
    info: u32 = 0,
    alignment: u64 = 0,
    entry_size: u64 = 0,

    pub fn write(self: SectionHeader, buffer: []u8, at: usize) void {
        const out = buffer[at..][0..shdr_size];
        if (native_endian == .little) {
            @memcpy(out, std.mem.asBytes(&self));
            return;
        }
        writeU32(out, 0, self.name_offset);
        writeU32(out, 4, self.section_type);
        writeU64(out, 8, self.flags);
        writeU64(out, 16, self.address);
        writeU64(out, 24, self.offset);
        writeU64(out, 32, self.size);
        writeU32(out, 40, self.link);
        writeU32(out, 44, self.info);
        writeU64(out, 48, self.alignment);
        writeU64(out, 56, self.entry_size);
    }
};

pub fn sectionIsAllocated(section: SectionHeader) bool {
    return (section.flags & std.elf.SHF_ALLOC) != 0;
}

test "ELF parsed section header fits raw SHDR size" {
    try std.testing.expectEqual(@as(usize, shdr_size), @sizeOf(SectionHeader));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SectionHeader, "name_offset"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(SectionHeader, "section_type"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(SectionHeader, "flags"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SectionHeader, "address"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(SectionHeader, "offset"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(SectionHeader, "size"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(SectionHeader, "link"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(SectionHeader, "info"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(SectionHeader, "alignment"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(SectionHeader, "entry_size"));
}

/// The 24-byte on-disk form of an ELF64 symbol table entry, with each field at
/// its file offset. The record stores a symbol's name as an offset into the
/// symbol string table, and the parsed `Symbol` adds the name itself as a
/// slice.
pub const SymbolRecord = extern struct {
    name_offset: u32 = 0,
    info: u8 = 0,
    other: u8 = 0,
    section_index: u16 = std.elf.SHN_UNDEF,
    value: u64 = 0,
    size: u64 = 0,

    pub fn write(self: SymbolRecord, buffer: []u8, at: usize) void {
        const out = buffer[at..][0..sym_size];
        if (native_endian == .little) {
            @memcpy(out, std.mem.asBytes(&self));
            return;
        }
        writeU32(out, 0, self.name_offset);
        out[4] = self.info;
        out[5] = self.other;
        writeU16(out, 6, self.section_index);
        writeU64(out, 8, self.value);
        writeU64(out, 16, self.size);
    }
};

test "ELF symbol record fits raw SYM size" {
    try std.testing.expectEqual(@as(usize, sym_size), @sizeOf(SymbolRecord));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SymbolRecord, "name_offset"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(SymbolRecord, "info"));
    try std.testing.expectEqual(@as(usize, 5), @offsetOf(SymbolRecord, "other"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(SymbolRecord, "section_index"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(SymbolRecord, "value"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SymbolRecord, "size"));
}

pub const Symbol = struct {
    name_offset: u32,
    info: u8,
    other: u8,
    section_index: u16,
    value: u64,
    size: u64,
    name: []const u8 = "",

    pub fn binding(self: Symbol) u8 {
        return self.info >> 4;
    }

    pub fn kind(self: Symbol) u8 {
        return self.info & 0xf;
    }

    pub fn isUndefined(self: Symbol) bool {
        return self.section_index == std.elf.SHN_UNDEF;
    }

    pub fn isWeakUndefined(self: Symbol) bool {
        return self.isUndefined() and self.binding() == std.elf.STB_WEAK;
    }

    pub fn isCommon(self: Symbol) bool {
        return self.section_index == std.elf.SHN_COMMON;
    }

    pub fn isAbsolute(self: Symbol) bool {
        return self.section_index == std.elf.SHN_ABS;
    }

    pub fn isSection(self: Symbol) bool {
        return self.kind() == std.elf.STT_SECTION;
    }

    pub fn isGlobalDefinition(self: Symbol) bool {
        if (self.isUndefined() or self.isSection() or self.name.len == 0) return false;
        return symbolBindingIsExternalDefinition(self.binding());
    }

    pub fn isGnuUnique(self: Symbol) bool {
        return self.binding() == std.elf.STB_GNU_UNIQUE;
    }
};

pub fn symbolBindingIsExternalDefinition(binding: u8) bool {
    return binding == std.elf.STB_GLOBAL or
        binding == std.elf.STB_WEAK or
        binding == std.elf.STB_GNU_UNIQUE;
}

pub const Rela = extern struct {
    offset: u64 = 0,
    info: u64 = 0,
    addend: i64 = 0,

    pub fn symbolIndex(self: Rela) u32 {
        return @intCast(self.info >> 32);
    }

    pub fn relocationType(self: Rela) u32 {
        return @truncate(self.info);
    }

    pub fn write(self: Rela, buffer: []u8, at: usize) void {
        const out = buffer[at..][0..rela_size];
        if (native_endian == .little) {
            @memcpy(out, std.mem.asBytes(&self));
            return;
        }
        writeU64(out, 0, self.offset);
        writeU64(out, 8, self.info);
        writeU64(out, 16, @bitCast(self.addend));
    }
};

test "ELF parsed relocation record fits raw RELA size" {
    try std.testing.expectEqual(@as(usize, rela_size), @sizeOf(Rela));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Rela, "offset"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Rela, "info"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Rela, "addend"));
}

test "ELF file header pins its fixed fields and round trips" {
    var buffer = @as([ehdr_size]u8, @splat(0xaa));
    const written = Header{
        .type = .EXEC,
        .machine = .X86_64,
        .entry = 0x401000,
        .flags = 0,
        .phoff = ehdr_size,
        .phnum = 3,
        .shoff = 0x2000,
        .shnum = 7,
        .shstrndx = 6,
    };
    written.write(&buffer);

    try std.testing.expectEqualSlices(u8, std.elf.MAGIC, buffer[0..4]);
    try std.testing.expectEqual(@as(u8, std.elf.ELFCLASS64), buffer[std.elf.EI_CLASS]);
    try std.testing.expectEqual(@as(u8, std.elf.ELFDATA2LSB), buffer[std.elf.EI_DATA]);
    try std.testing.expectEqual(@as(u8, 1), buffer[std.elf.EI_VERSION]);
    try std.testing.expectEqual(@as(u32, 1), readU32(&buffer, 20));
    try std.testing.expectEqual(@as(u16, ehdr_size), readU16(&buffer, 52));
    try std.testing.expectEqual(@as(u16, phdr_size), readU16(&buffer, 54));
    try std.testing.expectEqual(@as(u16, shdr_size), readU16(&buffer, 58));
    for (buffer[8..16]) |pad| try std.testing.expectEqual(@as(u8, 0), pad);

    try std.testing.expectEqual(written, try readHeader(&buffer));
}

test "ELF file header omits a program header size without program headers" {
    var buffer = @as([ehdr_size]u8, @splat(0xaa));
    const written = Header{ .shoff = 0x40, .shnum = 5, .shstrndx = 4 };
    written.write(&buffer);

    try std.testing.expectEqual(@as(u16, 0), readU16(&buffer, 54));
    try std.testing.expectEqual(@as(u16, 0), readU16(&buffer, 56));
    try std.testing.expectEqual(@as(u16, @backingInt(std.elf.ET.REL)), readU16(&buffer, 16));
    try std.testing.expectEqual(written, try readHeader(&buffer));
}

test "ELF file header decode rejects a foreign record" {
    var buffer = @as([ehdr_size]u8, @splat(0));
    (Header{ .shnum = 1 }).write(&buffer);
    try std.testing.expectError(error.InvalidElfHeader, readHeader(buffer[0 .. ehdr_size - 1]));

    buffer[std.elf.EI_CLASS] = std.elf.ELFCLASS32;
    try std.testing.expectError(error.UnsupportedFormat, readHeader(&buffer));
    buffer[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    buffer[std.elf.EI_DATA] = std.elf.ELFDATA2MSB;
    try std.testing.expectError(error.UnsupportedFormat, readHeader(&buffer));

    buffer[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    buffer[0] = 'x';
    try std.testing.expectError(error.InvalidElfHeader, readHeader(&buffer));

    (Header{ .shnum = 1 }).write(&buffer);
    writeU16(&buffer, 58, shdr_size + 1);
    try std.testing.expectError(error.InvalidElfHeader, readHeader(&buffer));
}

test "ELF records write their wire bytes" {
    var buffer = @as([shdr_size + sym_size + rela_size]u8, @splat(0xee));
    const section = SectionHeader{
        .name_offset = 0x11,
        .section_type = std.elf.SHT_PROGBITS,
        .flags = std.elf.SHF_ALLOC,
        .address = 0x400000,
        .offset = 0x1000,
        .size = 0x20,
        .link = 3,
        .info = 4,
        .alignment = 16,
        .entry_size = 0,
    };
    section.write(&buffer, 0);
    const symbol = SymbolRecord{
        .name_offset = 0x22,
        .info = 0x12,
        .other = 2,
        .section_index = 5,
        .value = 0x30,
        .size = 0x40,
    };
    symbol.write(&buffer, shdr_size);
    const rela = Rela{ .offset = 0x50, .info = 0x0000000200000001, .addend = -8 };
    rela.write(&buffer, shdr_size + sym_size);

    try std.testing.expectEqual(@as(u32, 0x11), readU32(&buffer, 0));
    try std.testing.expectEqual(@as(u32, std.elf.SHT_PROGBITS), readU32(&buffer, 4));
    try std.testing.expectEqual(@as(u64, std.elf.SHF_ALLOC), readU64(&buffer, 8));
    try std.testing.expectEqual(@as(u64, 0x400000), readU64(&buffer, 16));
    try std.testing.expectEqual(@as(u64, 0x1000), readU64(&buffer, 24));
    try std.testing.expectEqual(@as(u64, 0x20), readU64(&buffer, 32));
    try std.testing.expectEqual(@as(u32, 3), readU32(&buffer, 40));
    try std.testing.expectEqual(@as(u32, 4), readU32(&buffer, 44));
    try std.testing.expectEqual(@as(u64, 16), readU64(&buffer, 48));
    try std.testing.expectEqual(@as(u64, 0), readU64(&buffer, 56));
    try std.testing.expectEqual(@as(u32, 0x22), readU32(&buffer, shdr_size + 0));
    try std.testing.expectEqual(@as(u8, 0x12), buffer[shdr_size + 4]);
    try std.testing.expectEqual(@as(u8, 2), buffer[shdr_size + 5]);
    try std.testing.expectEqual(@as(u16, 5), readU16(&buffer, shdr_size + 6));
    try std.testing.expectEqual(@as(u64, 0x30), readU64(&buffer, shdr_size + 8));
    try std.testing.expectEqual(@as(u64, 0x40), readU64(&buffer, shdr_size + 16));
    const rela_at = shdr_size + sym_size;
    try std.testing.expectEqual(@as(u64, 0x50), readU64(&buffer, rela_at + 0));
    try std.testing.expectEqual(@as(u64, 0x0000000200000001), readU64(&buffer, rela_at + 8));
    try std.testing.expectEqual(@as(i64, -8), @as(i64, @bitCast(readU64(&buffer, rela_at + 16))));
    try std.testing.expectEqual(@as(u32, 2), rela.symbolIndex());
    try std.testing.expectEqual(@as(u32, 1), rela.relocationType());
}
