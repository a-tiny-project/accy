const std = @import("std");
const root = @import("../../root.zig");
const format = @import("format.zig");

const model = root.model;
const ehdr_size = format.ehdr_size;
const shdr_size = format.shdr_size;
const sym_size = format.sym_size;
const Header = format.Header;
const SectionHeader = format.SectionHeader;
const SymbolRecord = format.SymbolRecord;

/// A section header found by name, with the file index of that header, returned
/// by `find` so the caller gets the header and the index that names it.
pub const Found = struct {
    index: u16,
    header: SectionHeader,
};

/// A view (a checked read of one ELF64 little-endian file) held in borrowed
/// bytes, so tests read back objects and executables through it by section name
/// or index. `parse` validates the file header, where the section table lies,
/// and the section name table up front. Each read after that returns a slice of
/// `bytes` checked against its bounds and allocates nothing. The caller keeps
/// `bytes` alive and unchanged while it uses the view.
pub const View = struct {
    bytes: []const u8,
    header: Header,
    names: []const u8,

    /// Validates the file header and section table of `bytes` and returns a
    /// view (a checked read of one ELF64 little-endian file) that borrows them.
    /// Because every read goes through that table, a file with no section table
    /// returns `error.MissingSection` here, so no later read checks for it
    /// again. The call returns `error.InvalidElfHeader` when the section name
    /// table index is past the table, and `error.InvalidRange` when the table
    /// or the name table lies outside `bytes`.
    pub fn parse(bytes: []const u8) model.Error!View {
        const header = try format.readHeader(bytes);
        if (header.shnum == 0) return error.MissingSection;
        if (header.shstrndx >= header.shnum) return error.InvalidElfHeader;
        try format.requireRange(bytes, header.shoff, @as(u64, header.shnum) * shdr_size);

        const name_table_offset = header.shoff + @as(u64, header.shstrndx) * shdr_size;
        const name_table = format.readSectionHeader(bytes, name_table_offset);
        return .{
            .bytes = bytes,
            .header = header,
            .names = try format.sectionBytes(bytes, name_table),
        };
    }

    pub fn sectionCount(self: View) u16 {
        return self.header.shnum;
    }

    /// Reads the section header at `index`, for example the string table a
    /// symbol table links to. `parse` already proved the whole table lies
    /// within the file, so the one requirement left is `index` below the
    /// section count, which a debug assertion checks.
    pub fn section(self: View, index: u16) SectionHeader {
        std.debug.assert(index < self.header.shnum);
        const offset = self.header.shoff + @as(u64, index) * shdr_size;
        return format.readSectionHeader(self.bytes, offset);
    }

    pub fn sectionName(self: View, header: SectionHeader) model.Error![]const u8 {
        return format.stringFromTable(self.names, header.name_offset);
    }

    /// Returns the first section named `name` with its index, or null, so tests
    /// can look sections up by name. The scan runs in file order, so when two
    /// sections share a name the lower index wins. The call returns
    /// `error.InvalidStringTable` when a section's name starts outside the
    /// section name table or runs to its end with no terminating zero byte.
    pub fn find(self: View, name: []const u8) model.Error!?Found {
        var index: u16 = 0;
        while (index < self.header.shnum) : (index += 1) {
            const header = self.section(index);
            if (std.mem.eql(u8, try self.sectionName(header), name)) {
                return .{ .index = index, .header = header };
            }
        }
        return null;
    }

    /// Returns the file bytes of a section as a slice of `bytes`, so tests can
    /// compare a section's contents with what they wrote. The call returns an
    /// empty slice for a NOBITS section, because it has no bytes in the file.
    /// The call returns `error.InvalidRange` when the section extends past the
    /// file.
    pub fn sectionBytes(self: View, header: SectionHeader) model.Error![]const u8 {
        return format.sectionBytes(self.bytes, header);
    }

    pub fn symbolCount(self: View, symtab: SectionHeader) model.Error!usize {
        return (try self.sectionBytes(symtab)).len / sym_size;
    }

    pub fn symbol(self: View, symtab: SectionHeader, index: usize) model.Error!SymbolRecord {
        const table = try self.sectionBytes(symtab);
        if (index >= table.len / sym_size) return error.InvalidRange;
        return format.readSymbolRecord(table[index * sym_size ..][0..sym_size]);
    }

    pub fn string(self: View, strtab: SectionHeader, offset: u32) model.Error![]const u8 {
        return format.stringFromTable(try self.sectionBytes(strtab), offset);
    }
};

const witness_text = "\x55\x48\x89\xe5";
const witness_strtab = "\x00main\x00";
const witness_shstrtab = "\x00.text\x00.symtab\x00.strtab\x00.shstrtab\x00";
const witness_text_offset = ehdr_size;
const witness_symtab_offset = witness_text_offset + 8;
const witness_symbol_count = 2;
const witness_symtab_size = witness_symbol_count * sym_size;
const witness_strtab_offset = witness_symtab_offset + witness_symtab_size;
const witness_shstrtab_offset = witness_strtab_offset + witness_strtab.len;
const witness_shoff = 160;
const witness_shnum = 5;
const witness_size = witness_shoff + witness_shnum * shdr_size;

/// Writes a minimal relocatable object using the package's own header, section
/// and symbol record writers, so each test of a view (a borrowed, checked read
/// of an ELF64 file) starts from the object it writes. The object comes from
/// the same writers whose output the view reads, so a failing view test means
/// the writers and the view disagree about the format.
fn writeWitness(buffer: *[witness_size]u8) void {
    @memset(buffer, 0);
    (Header{
        .shoff = witness_shoff,
        .shnum = witness_shnum,
        .shstrndx = 4,
    }).write(buffer);
    @memcpy(buffer[witness_text_offset..][0..witness_text.len], witness_text);
    (SymbolRecord{}).write(buffer, witness_symtab_offset);
    (SymbolRecord{
        .name_offset = 1,
        .info = format.elfSymbolInfo(std.elf.STB_GLOBAL, std.elf.STT_FUNC),
        .section_index = 1,
        .size = witness_text.len,
    }).write(buffer, witness_symtab_offset + sym_size);
    @memcpy(buffer[witness_strtab_offset..][0..witness_strtab.len], witness_strtab);
    @memcpy(buffer[witness_shstrtab_offset..][0..witness_shstrtab.len], witness_shstrtab);

    (SectionHeader{}).write(buffer, witness_shoff);
    (SectionHeader{
        .name_offset = 1,
        .section_type = std.elf.SHT_PROGBITS,
        .flags = std.elf.SHF_ALLOC | std.elf.SHF_EXECINSTR,
        .offset = witness_text_offset,
        .size = witness_text.len,
        .alignment = 1,
    }).write(buffer, witness_shoff + shdr_size);
    (SectionHeader{
        .name_offset = 7,
        .section_type = std.elf.SHT_SYMTAB,
        .offset = witness_symtab_offset,
        .size = witness_symtab_size,
        .link = 3,
        .info = 1,
        .alignment = 8,
        .entry_size = sym_size,
    }).write(buffer, witness_shoff + 2 * shdr_size);
    (SectionHeader{
        .name_offset = 15,
        .section_type = std.elf.SHT_STRTAB,
        .offset = witness_strtab_offset,
        .size = witness_strtab.len,
        .alignment = 1,
    }).write(buffer, witness_shoff + 3 * shdr_size);
    (SectionHeader{
        .name_offset = 23,
        .section_type = std.elf.SHT_STRTAB,
        .offset = witness_shstrtab_offset,
        .size = witness_shstrtab.len,
        .alignment = 1,
    }).write(buffer, witness_shoff + 4 * shdr_size);
}

test "ELF view reads back the records written into an object" {
    var buffer: [witness_size]u8 = undefined;
    writeWitness(&buffer);
    const view = try View.parse(&buffer);

    try std.testing.expectEqual(@as(u16, witness_shnum), view.sectionCount());
    try std.testing.expectEqual(std.elf.ET.REL, view.header.type);
    try std.testing.expectEqualStrings("", try view.sectionName(view.section(0)));

    const text = (try view.find(".text")).?;
    try std.testing.expectEqual(@as(u16, 1), text.index);
    try std.testing.expectEqual(@as(u32, std.elf.SHT_PROGBITS), text.header.section_type);
    try std.testing.expectEqualStrings(witness_text, try view.sectionBytes(text.header));
    try std.testing.expectEqualStrings(".text", try view.sectionName(text.header));

    const symtab = (try view.find(".symtab")).?;
    const strtab = view.section(@intCast(symtab.header.link));
    const counted = try view.symbolCount(symtab.header);
    try std.testing.expectEqual(@as(usize, witness_symbol_count), counted);

    const null_symbol = try view.symbol(symtab.header, 0);
    try std.testing.expectEqual(SymbolRecord{}, null_symbol);
    try std.testing.expectEqualStrings("", try view.string(strtab, null_symbol.name_offset));

    const main_symbol = try view.symbol(symtab.header, 1);
    try std.testing.expectEqual(@as(u16, 1), main_symbol.section_index);
    try std.testing.expectEqual(@as(u64, witness_text.len), main_symbol.size);
    try std.testing.expectEqualStrings("main", try view.string(strtab, main_symbol.name_offset));

    try std.testing.expect((try view.find(".rodata")) == null);
}

test "ELF view borrows nothing from a NOBITS section" {
    var buffer: [witness_size]u8 = undefined;
    writeWitness(&buffer);
    const view = try View.parse(&buffer);

    const reserved = SectionHeader{
        .section_type = std.elf.SHT_NOBITS,
        .offset = witness_size * 4,
        .size = 4096,
    };
    try std.testing.expectEqual(@as(usize, 0), (try view.sectionBytes(reserved)).len);
}

test "ELF view refuses reads the file cannot satisfy" {
    var buffer: [witness_size]u8 = undefined;
    writeWitness(&buffer);

    try std.testing.expectError(error.InvalidRange, View.parse(buffer[0 .. witness_size - 1]));

    const view = try View.parse(&buffer);
    const symtab = (try view.find(".symtab")).?.header;
    const strtab = view.section(3);
    try std.testing.expectError(error.InvalidRange, view.symbol(symtab, witness_symbol_count));
    try std.testing.expectError(error.InvalidStringTable, view.string(strtab, witness_strtab.len));

    writeWitness(&buffer);
    (Header{
        .shoff = witness_shoff,
        .shnum = witness_shnum,
        .shstrndx = witness_shnum,
    }).write(&buffer);
    try std.testing.expectError(error.InvalidElfHeader, View.parse(&buffer));

    writeWitness(&buffer);
    (Header{ .shoff = witness_shoff }).write(&buffer);
    try std.testing.expectError(error.MissingSection, View.parse(&buffer));
}
