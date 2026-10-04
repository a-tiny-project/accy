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
