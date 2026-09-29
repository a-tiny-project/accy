const std = @import("std");
const elf = @import("../root.zig");

const format = elf.format;
const group_word_size = format.group_word_size;

/// Names each defect that stops a description (the values describing a
/// relocatable object) from becoming an object file, so callers of `plan` and
/// `build` switch on these to tell a malformed description apart from running
/// out of memory. Allocation failure is kept out of this set, and `Error` joins
/// the two for `plan` and `build`.
pub const DescriptionError = error{
    InvalidAlignment,
    InvalidSize,
    InvalidSectionIndex,
    SymbolOrder,
    TooManySections,
    TooManySymbols,
    SizeOverflow,
};

pub const Error = std.mem.Allocator.Error || DescriptionError;

/// The struct holds the file header fields a producer picks: object type
/// (relocatable by default), machine (x86-64 by default), entry address and
/// flags. A description (the values describing a relocatable object) carries
/// this struct to set the object's file header. The section table's offset,
/// count and name table index come from the layout (the file offsets `plan`
/// computes for each record), so a description has no fields for them.
pub const Header = struct {
    type: std.elf.ET = .REL,
    machine: std.elf.EM = .X86_64,
    entry: u64 = 0,
    flags: u32 = 0,
};

/// Describes one section of a description (the values describing a relocatable
/// object), so a caller lists one per section the object carries, in file
/// order. Each entry `sections[i]` gets file index `i + 1`, because the writer
/// places the empty section header at index 0 itself. A section of type
/// `SHT_NOBITS` has no bytes and reserves `size` bytes of memory. Any other
/// section is as long as its `bytes`, and `plan` refuses a nonzero `size` that
/// differs from that length.
pub const Section = struct {
    name: []const u8,
    section_type: u32 = std.elf.SHT_PROGBITS,
    flags: u64 = 0,
    alignment: u64 = 1,
    bytes: []const u8 = &.{},
    size: u64 = 0,
    address: u64 = 0,
    link: u32 = 0,
    info: u32 = 0,
    entry_size: u64 = 0,

    pub fn progbits(name: []const u8, bytes: []const u8, flags: u64, alignment: u64) Section {
        return .{
            .name = name,
            .section_type = std.elf.SHT_PROGBITS,
            .flags = flags | std.elf.SHF_ALLOC,
            .alignment = alignment,
            .bytes = bytes,
        };
    }

    pub fn nobits(name: []const u8, size: u64, flags: u64, alignment: u64) Section {
        return .{
            .name = name,
            .section_type = std.elf.SHT_NOBITS,
            .flags = flags | std.elf.SHF_ALLOC,
            .alignment = alignment,
            .size = size,
        };
    }

    pub fn mergeable(
        name: []const u8,
        bytes: []const u8,
        flags: u64,
        alignment: u64,
        entry_size: u64,
    ) Section {
        return .{
            .name = name,
            .section_type = std.elf.SHT_PROGBITS,
            .flags = flags | std.elf.SHF_ALLOC | std.elf.SHF_MERGE,
            .alignment = alignment,
            .bytes = bytes,
            .entry_size = entry_size,
        };
    }

    pub fn strings(name: []const u8, bytes: []const u8, alignment: u64) Section {
        return .{
            .name = name,
            .section_type = std.elf.SHT_PROGBITS,
            .flags = std.elf.SHF_ALLOC | std.elf.SHF_MERGE | std.elf.SHF_STRINGS,
            .alignment = alignment,
            .bytes = bytes,
            .entry_size = 1,
        };
    }

    pub fn nonAlloc(
        name: []const u8,
        bytes: []const u8,
        section_type: u32,
        alignment: u64,
    ) Section {
        return .{
            .name = name,
            .section_type = section_type,
            .alignment = alignment,
            .bytes = bytes,
        };
    }

    /// Builds a COMDAT group section whose payload is `bytes`, which the caller
    /// fills with `groupBytes` first, for a caller that needs sections kept or
    /// dropped together. The caller states only the signature symbol's index,
    /// and the writer points the section's link at the symbol table.
    pub fn group(name: []const u8, bytes: []const u8, signature_symbol: u32) Section {
        return .{
            .name = name,
            .section_type = std.elf.SHT_GROUP,
            .alignment = group_word_size,
            .bytes = bytes,
            .info = signature_symbol,
            .entry_size = group_word_size,
        };
    }

    pub fn isNoBits(self: Section) bool {
        return self.section_type == std.elf.SHT_NOBITS;
    }

    /// Returns the number of bytes the section takes in the file: zero for a
    /// reservation, else the length of `bytes`. The layout (the file offsets
    /// `plan` computes) uses it to advance the file offset past a section.
    pub fn fileSize(self: Section) u64 {
        if (self.isNoBits()) return 0;
        return self.bytes.len;
    }

    /// Returns the value written into the section header's `sh_size` field: the
    /// reserved size for a NOBITS section, else the length of `bytes`.
    pub fn wireSize(self: Section) u64 {
        if (self.isNoBits()) return self.size;
        return self.bytes.len;
    }
};

/// Writes a COMDAT group payload into `out`: the COMDAT flag word, then one
/// 32-bit word per member section index. The destination slice `out` holds at
/// least `(members.len + 1) * 4` bytes, which a debug assertion checks. The
/// function returns the filled prefix of `out`, ready to pass to
/// `Section.group`.
pub fn groupBytes(out: []u8, members: []const u16) []u8 {
    const needed = (members.len + 1) * group_word_size;
    std.debug.assert(out.len >= needed);
    const bytes = out[0..needed];
    format.writeU32(bytes, 0, std.elf.GRP_COMDAT);
    for (members, 0..) |member, index| {
        format.writeU32(bytes, (index + 1) * group_word_size, member);
    }
    return bytes;
}

/// Describes one symbol of a description (the values describing a relocatable
/// object), so a description lists one per symbol table entry, locals first.
/// Each entry `symbols[i]` gets table index `i + 1`, because the writer places
/// the empty entry at index 0 itself. The writer adds no symbols of its own, so
/// a description that needs section symbols lists them. The design this
/// namespace follows names the section field `section`, but because Zig rejects
/// a struct with a field and a declaration of the same name and the `section`
/// constructor kept that name, the field is `section_index`, the name
/// `record.SymbolRecord` also uses.
pub const Symbol = struct {
    name: []const u8 = "",
    binding: u8 = std.elf.STB_LOCAL,
    kind: u8 = std.elf.STT_NOTYPE,
    other: u8 = 0,
    section_index: u16 = std.elf.SHN_UNDEF,
    value: u64 = 0,
    size: u64 = 0,

    pub fn section(index: u16) Symbol {
        return .{ .kind = std.elf.STT_SECTION, .section_index = index };
    }

    pub fn function(name: []const u8, section_index: u16, value: u64, size: u64) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_FUNC, section_index, value, size);
    }

    pub fn weakFunction(name: []const u8, section_index: u16, value: u64, size: u64) Symbol {
        return defined(name, std.elf.STB_WEAK, std.elf.STT_FUNC, section_index, value, size);
    }

    pub fn ifunc(name: []const u8, section_index: u16, value: u64, size: u64) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_GNU_IFUNC, section_index, value, size);
    }

    pub fn object(name: []const u8, section_index: u16, value: u64, size: u64) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_OBJECT, section_index, value, size);
    }

    pub fn localObject(name: []const u8, section_index: u16, value: u64, size: u64) Symbol {
        return defined(name, std.elf.STB_LOCAL, std.elf.STT_OBJECT, section_index, value, size);
    }

    pub fn gnuUniqueObject(name: []const u8, section_index: u16, value: u64, size: u64) Symbol {
        const unique = std.elf.STB_GNU_UNIQUE;
        return defined(name, unique, std.elf.STT_OBJECT, section_index, value, size);
    }

    pub fn tlsObject(name: []const u8, section_index: u16, value: u64, size: u64) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_TLS, section_index, value, size);
    }

    pub fn absoluteObject(name: []const u8, value: u64, size: u64) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_OBJECT, std.elf.SHN_ABS, value, size);
    }

    /// Builds a global common symbol with section index `SHN_COMMON`, the
    /// required alignment in `value`, and the block's size in `size`, for a
    /// caller describing a C tentative definition or any common block. For a
    /// symbol in `SHN_COMMON`, ELF defines the value field as the alignment.
    pub fn commonObject(name: []const u8, alignment: u64, size: u64) Symbol {
        const block = std.elf.SHN_COMMON;
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_OBJECT, block, alignment, size);
    }

    pub fn undefinedObject(name: []const u8) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_OBJECT, std.elf.SHN_UNDEF, 0, 0);
    }

    pub fn undefinedFunction(name: []const u8) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_FUNC, std.elf.SHN_UNDEF, 0, 0);
    }

    pub fn weakUndefinedFunction(name: []const u8) Symbol {
        return defined(name, std.elf.STB_WEAK, std.elf.STT_FUNC, std.elf.SHN_UNDEF, 0, 0);
    }

    pub fn undefinedSymbol(name: []const u8) Symbol {
        return defined(name, std.elf.STB_GLOBAL, std.elf.STT_NOTYPE, std.elf.SHN_UNDEF, 0, 0);
    }

    pub fn isLocal(self: Symbol) bool {
        return self.binding == std.elf.STB_LOCAL;
    }

    pub fn info(self: Symbol) u8 {
        return format.elfSymbolInfo(self.binding, self.kind);
    }

    fn defined(
        name: []const u8,
        binding: u8,
        kind: u8,
        section_index: u16,
        value: u64,
        size: u64,
    ) Symbol {
        return .{
            .name = name,
            .binding = binding,
            .kind = kind,
            .section_index = section_index,
            .value = value,
            .size = size,
        };
    }
};

/// Describes one relocation against a described section: the target section's
/// index, the offset inside it, the symbol index, the relocation type and the
/// addend. A caller lists one per relocation in the object. The one field
/// `plan` checks is the target index, since placing the record depends on it.
/// The symbol index, offset, type and addend reach the file unchecked, so a
/// test can build the malformed objects that the linker's own checks must
/// reject.
pub const Relocation = struct {
    section: u16,
    offset: u64,
    symbol: u32,
    type: u32,
    addend: i64 = 0,

    pub fn x86_64(
        section: u16,
        offset: u64,
        symbol: u32,
        kind: std.elf.R_X86_64,
        addend: i64,
    ) Relocation {
        return .{
            .section = section,
            .offset = offset,
            .symbol = symbol,
            .type = @backingInt(kind),
            .addend = addend,
        };
    }

    pub fn info(self: Relocation) u64 {
        return (@as(u64, self.symbol) << 32) | self.type;
    }
};

pub const Description = struct {
    header: Header = .{},
    sections: []const Section,
    symbols: []const Symbol = &.{},
    relocations: []const Relocation = &.{},
};

test "ELF object sections separate their file size from their wire size" {
    const progbits = Section.progbits(".text", "\x90\x90\x90\x90", std.elf.SHF_EXECINSTR, 16);
    try std.testing.expectEqual(@as(u64, std.elf.SHT_PROGBITS), progbits.section_type);
    const code_flags = std.elf.SHF_ALLOC | std.elf.SHF_EXECINSTR;
    try std.testing.expectEqual(@as(u64, code_flags), progbits.flags);
    try std.testing.expectEqual(@as(u64, 4), progbits.fileSize());
    try std.testing.expectEqual(@as(u64, 4), progbits.wireSize());

    const reserved = Section.nobits(".bss", 4096, std.elf.SHF_WRITE, 8);
    try std.testing.expect(reserved.isNoBits());
    try std.testing.expectEqual(@as(u64, 0), reserved.fileSize());
    try std.testing.expectEqual(@as(u64, 4096), reserved.wireSize());
    try std.testing.expectEqual(@as(u64, std.elf.SHF_ALLOC | std.elf.SHF_WRITE), reserved.flags);
}

test "ELF object sections carry their merge and group shape" {
    const merged = Section.mergeable(".rodata.cst8", "01234567", 0, 8, 8);
    try std.testing.expectEqual(@as(u64, std.elf.SHF_ALLOC | std.elf.SHF_MERGE), merged.flags);
    try std.testing.expectEqual(@as(u64, 8), merged.entry_size);

    const text = Section.strings(".rodata.str1.1", "hi\x00", 1);
    try std.testing.expectEqual(
        @as(u64, std.elf.SHF_ALLOC | std.elf.SHF_MERGE | std.elf.SHF_STRINGS),
        text.flags,
    );
    try std.testing.expectEqual(@as(u64, 1), text.entry_size);

    const notes = Section.nonAlloc(".comment", "tldr\x00", std.elf.SHT_PROGBITS, 1);
    try std.testing.expectEqual(@as(u64, 0), notes.flags);

    var storage: [3 * 4]u8 = undefined;
    const payload = groupBytes(&storage, &.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 12), payload.len);
    try std.testing.expectEqual(@as(u32, std.elf.GRP_COMDAT), format.readU32(payload, 0));
    try std.testing.expectEqual(@as(u32, 1), format.readU32(payload, 4));
    try std.testing.expectEqual(@as(u32, 2), format.readU32(payload, 8));

    const comdat = Section.group(".group", payload, 7);
    try std.testing.expectEqual(@as(u32, std.elf.SHT_GROUP), comdat.section_type);
    try std.testing.expectEqual(@as(u32, 7), comdat.info);
    try std.testing.expectEqual(@as(u64, 4), comdat.alignment);
    try std.testing.expectEqual(@as(u64, 4), comdat.entry_size);
}

test "ELF object symbols fold their binding and kind into one info byte" {
    try std.testing.expectEqual(@as(u8, 0x03), Symbol.section(2).info());
    try std.testing.expectEqual(@as(u16, 2), Symbol.section(2).section_index);
    try std.testing.expect(Symbol.section(2).isLocal());

    try std.testing.expectEqual(@as(u8, 0x12), Symbol.function("main", 1, 0, 4).info());
    try std.testing.expectEqual(@as(u8, 0x22), Symbol.weakFunction("weak", 1, 0, 4).info());
    try std.testing.expectEqual(@as(u8, 0x1a), Symbol.ifunc("resolve", 1, 0, 4).info());
    try std.testing.expectEqual(@as(u8, 0x11), Symbol.object("data", 2, 0, 8).info());
    try std.testing.expectEqual(@as(u8, 0x01), Symbol.localObject("private", 2, 0, 8).info());
    try std.testing.expectEqual(@as(u8, 0xa1), Symbol.gnuUniqueObject("unique", 2, 0, 8).info());
    try std.testing.expectEqual(@as(u8, 0x16), Symbol.tlsObject("thread", 3, 0, 8).info());
    try std.testing.expectEqual(@as(u8, 0x10), Symbol.undefinedSymbol("plain").info() & 0xf0);

    const fixed = Symbol.absoluteObject("fixed", 9, 0);
    try std.testing.expectEqual(@as(u16, std.elf.SHN_ABS), fixed.section_index);
    const common = Symbol.commonObject("shared", 16, 32);
    try std.testing.expectEqual(@as(u16, std.elf.SHN_COMMON), common.section_index);
    try std.testing.expectEqual(@as(u64, 16), common.value);
    try std.testing.expectEqual(@as(u64, 32), common.size);
    const undefined_object = Symbol.undefinedObject("missing");
    const undefined_function = Symbol.undefinedFunction("missing");
    try std.testing.expectEqual(@as(u16, std.elf.SHN_UNDEF), undefined_object.section_index);
    try std.testing.expectEqual(@as(u16, std.elf.SHN_UNDEF), undefined_function.section_index);
    try std.testing.expect(!Symbol.weakUndefinedFunction("maybe").isLocal());
}

test "ELF object relocations pack their symbol and type into one info word" {
    const rela = Relocation.x86_64(1, 0x10, 3, .@"64", -8);
    try std.testing.expectEqual(@as(u16, 1), rela.section);
    try std.testing.expectEqual(@as(u64, 0x10), rela.offset);
    try std.testing.expectEqual(@as(i64, -8), rela.addend);
    try std.testing.expectEqual(@as(u64, (3 << 32) | 1), rela.info());
    try std.testing.expectEqual(@as(u32, 3), format.Rela.symbolIndex(.{ .info = rela.info() }));
    try std.testing.expectEqual(@as(u32, 1), format.Rela.relocationType(.{ .info = rela.info() }));
}
