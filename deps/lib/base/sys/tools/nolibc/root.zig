//! Inspects one ELF file for the C runtime that an artifact built without
//! libc must not reach: the libraries its dynamic segment names as needed,
//! read as the loader reads them, and the undefined names in its symbol
//! tables, `.dynsym` and `.symtab` both. The `.dynsym` read must be the
//! table the loader resolves through `DT_SYMTAB`. Every target the checks
//! serve emits 64-bit little-endian files, and any other class or byte order
//! is refused by name. A part of the file that cannot be read refuses the
//! file rather than letting it pass. The file is read through two fixed
//! buffers and never loaded whole, so memory stays the same however large
//! the artifact is.

const std = @import("std");
const elf = std.elf;
pub const policy = @import("policy.zig");

/// The bytes of a name that matching keeps. Every exact name in the policy
/// is shorter, so a longer name can only match a prefix, which these bytes
/// hold.
pub const name_window_bytes: usize = 64;
/// Names are read through this buffer. A linker lays out a string table in
/// roughly the order of the symbols that use it, so most reads land inside
/// the bytes already buffered.
const string_buffer_bytes: usize = 64 * 1024;
const record_buffer_bytes: usize = 4096;
/// A symbol's section index that lives in the extended index table.
const shn_xindex: u16 = 0xffff;

comptime {
    const names = policy.libraries ++ policy.runtime_symbols ++ policy.runtime_prefixes;
    for (names) |name| std.debug.assert(name.len > 0 and name.len < name_window_bytes);
}

pub const Checks = struct {
    /// Undefined symbols that name the C runtime. Needed libraries are
    /// always checked.
    undefined_symbols: bool = false,
};

pub const Kind = enum {
    needed_library,
    undefined_symbol,

    pub fn finding(kind: Kind) Finding {
        return switch (kind) {
            .needed_library => error.LinksRuntimeLibrary,
            .undefined_symbol => error.ExposesRuntimeSymbol,
        };
    }
};

pub const Finding = error{ LinksRuntimeLibrary, ExposesRuntimeSymbol };

pub const Refusal = error{
    NotElf,
    UnsupportedClass,
    UnsupportedEndian,
    /// A header, table or name lies outside the file or disagrees with the
    /// layout it declares.
    InvalidElf,
    /// A symbol's section index lives in the extended index table, which is
    /// not read, so whether the symbol is defined is unknown.
    ExtendedSectionIndex,
    ReadFailed,
};

pub const Error = Finding || Refusal;

/// Receives each offending name, cut to `name_window_bytes` when longer.
pub const Report = struct {
    context: *anyopaque,
    found: *const fn (context: *anyopaque, kind: Kind, name: []const u8) void,
};

/// Reads the needed entries, and the undefined symbols when `checks` asks,
/// and reports each one the policy forbids. A file that cannot be read whole
/// is refused; otherwise the finding of the first kind seen, in `Kind`
/// order, is returned.
pub fn inspect(io: std.Io, file: std.Io.File, checks: Checks, report: ?Report) Error!void {
    var record_buffer: [record_buffer_bytes]u8 = undefined;
    var records = file.reader(io, &record_buffer);
    var string_buffer: [string_buffer_bytes]u8 = undefined;
    var strings = file.reader(io, &string_buffer);
    const file_bytes = records.getSize() catch return error.ReadFailed;
    var scan: Scan = .{
        .header = try readHeader(&records.interface),
        .file_bytes = file_bytes,
        .records = &records,
        .strings = &strings,
        .report = report,
    };
    const dynamic = try scan.needed();
    if (checks.undefined_symbols) {
        scan.section_count = try scan.sectionCount();
        var dynamic_tables: u64 = 0;
        for (0..scan.section_count) |index| {
            const section = try scan.section(index);
            switch (section.sh_type) {
                elf.SHT_DYNSYM => {
                    dynamic_tables += 1;
                    try scan.reconcile(section, dynamic);
                    try scan.symbols(section);
                },
                elf.SHT_SYMTAB => try scan.symbols(section),
                else => {},
            }
        }
        if (dynamic.symbols != null and dynamic_tables != 1) return error.InvalidElf;
    }
    for (std.enums.values(Kind)) |kind| {
        if (scan.seen.contains(kind)) return kind.finding();
    }
}

fn readHeader(reader: *std.Io.Reader) Refusal!elf.Header {
    const ident = reader.peek(elf.EI.NIDENT) catch |err| return switch (err) {
        error.EndOfStream => error.NotElf,
        error.ReadFailed => error.ReadFailed,
    };
    if (!std.mem.eql(u8, ident[0..4], elf.MAGIC)) return error.NotElf;
    switch (ident[elf.EI.CLASS]) {
        elf.ELFCLASS64 => {},
        elf.ELFCLASS32 => return error.UnsupportedClass,
        else => return error.InvalidElf,
    }
    switch (ident[elf.EI.DATA]) {
        elf.ELFDATA2LSB => {},
        elf.ELFDATA2MSB => return error.UnsupportedEndian,
        else => return error.InvalidElf,
    }
    const header = elf.Header.read(reader) catch |err| return switch (err) {
        error.ReadFailed => error.ReadFailed,
        else => error.InvalidElf,
    };
    std.debug.assert(header.is_64 and header.endian == .little);
    return header;
}

const Scan = struct {
    header: elf.Header,
    file_bytes: u64,
    records: *std.Io.File.Reader,
    strings: *std.Io.File.Reader,
    report: ?Report,
    section_count: u64 = 0,
    seen: std.EnumSet(Kind) = .empty,
    name_storage: [name_window_bytes]u8 = undefined,

    /// A file with more sections than its header can count stores the count
    /// in the first section header's size.
    fn sectionCount(scan: *Scan) Error!u64 {
        if (scan.header.shoff == 0) {
            if (scan.header.shnum != 0) return error.InvalidElf;
            return 0;
        }
        if (scan.header.shentsize != @sizeOf(elf.Elf64_Shdr)) return error.InvalidElf;
        try scan.within(scan.header.shoff, @sizeOf(elf.Elf64_Shdr));
        scan.section_count = 1;
        const count = if (scan.header.shnum != 0)
            scan.header.shnum
        else
            (try scan.section(0)).sh_size;
        const table_bytes = std.math.mul(u64, count, @sizeOf(elf.Elf64_Shdr)) catch
            return error.InvalidElf;
        try scan.within(scan.header.shoff, table_bytes);
        return count;
    }

    fn section(scan: *Scan, index: u64) Error!elf.Elf64_Shdr {
        if (index >= scan.section_count) return error.InvalidElf;
        try seek(scan.records, scan.header.shoff + index * @sizeOf(elf.Elf64_Shdr));
        return scan.records.interface.takeStruct(elf.Elf64_Shdr, .little) catch |err|
            return readFailure(err);
    }

    /// Checks that `table` lies inside the file and holds whole entries of
    /// `entry_bytes` each.
    fn table(scan: *Scan, header: elf.Elf64_Shdr, entry_bytes: u64) Error!u64 {
        if (header.sh_entsize != entry_bytes) return error.InvalidElf;
        if (header.sh_size % entry_bytes != 0) return error.InvalidElf;
        try scan.within(header.sh_offset, header.sh_size);
        return header.sh_size / entry_bytes;
    }

    /// The string table a section links to.
    fn linkedStrings(scan: *Scan, header: elf.Elf64_Shdr) Error!Strings {
        const linked = try scan.section(header.sh_link);
        if (linked.sh_type != elf.SHT_STRTAB) return error.InvalidElf;
        try scan.within(linked.sh_offset, linked.sh_size);
        return .{ .offset = linked.sh_offset, .bytes = linked.sh_size };
    }

    /// Reads the needed entries as the loader does: from the one dynamic
    /// segment, up to the `DT_NULL` that must end it inside the segment, at
    /// the bytes a loaded segment places at its address, naming
    /// them through the string table that `DT_STRTAB` places in a loaded
    /// segment and `DT_STRSZ` sizes. Sections are never read here, since the
    /// loader never reads them. A segment whose bytes run past the file
    /// cannot be loaded, and refuses the file. Returns where the loader finds
    /// the dynamic symbols and their names.
    fn needed(scan: *Scan) Error!Dynamic {
        const programs = try scan.programCount();
        var dynamic: ?elf.Elf64.Phdr = null;
        for (0..programs) |index| {
            const program = try scan.programHeader(index);
            try scan.within(program.offset, program.filesz);
            if (program.type != .DYNAMIC) continue;
            if (dynamic != null) return error.InvalidElf;
            dynamic = program;
        }
        const segment = dynamic orelse return .{};
        if (segment.filesz % @sizeOf(elf.Elf64_Dyn) != 0) return error.InvalidElf;
        // The loader reads the table at its address, so the bytes read here
        // must be the ones a loaded segment places there.
        const placed = try scan.loaded(segment.vaddr, segment.filesz);
        if (placed.offset != segment.offset) return error.InvalidElf;
        const count = segment.filesz / @sizeOf(elf.Elf64_Dyn);

        var names_address: ?u64 = null;
        var names_bytes: ?u64 = null;
        var symbols_address: ?u64 = null;
        var needs = false;
        for (0..count) |index| {
            const entry = try scan.dynamicEntry(segment, index);
            switch (entry.d_tag) {
                elf.DT_NULL => break,
                elf.DT_NEEDED => needs = true,
                elf.DT_STRTAB => {
                    if (names_address != null) return error.InvalidElf;
                    names_address = entry.d_val;
                },
                elf.DT_STRSZ => {
                    if (names_bytes != null) return error.InvalidElf;
                    names_bytes = entry.d_val;
                },
                elf.DT_SYMTAB => {
                    if (symbols_address != null) return error.InvalidElf;
                    symbols_address = entry.d_val;
                },
                else => {},
            }
        } else {
            // The loader reads on to a `DT_NULL`, so entries past the segment's
            // bytes would be read here unseen.
            return error.InvalidElf;
        }
        if (!needs and symbols_address == null) return .{};
        const names = try scan.loaded(
            names_address orelse return error.InvalidElf,
            names_bytes orelse return error.InvalidElf,
        );
        const symbols_offset = if (symbols_address) |address|
            (try scan.loaded(address, @sizeOf(elf.Elf64_Sym))).offset
        else
            null;
        for (0..count) |index| {
            const entry = try scan.dynamicEntry(segment, index);
            if (entry.d_tag == elf.DT_NULL) break;
            if (entry.d_tag != elf.DT_NEEDED) continue;
            const name = try scan.readName(names, entry.d_val);
            if (startsWithAny(name.bytes, &policy.libraries)) {
                scan.found(.needed_library, name.bytes);
            }
        }
        return .{ .names = names, .symbols = symbols_offset };
    }

    /// Checks that a dynamic symbol table is the one the loader resolves
    /// through: at `DT_SYMTAB`, with its names at `DT_STRTAB`. The loader
    /// counts the symbols through the hash tables, which are not read, so
    /// the section's count is trusted, as `readelf -Ws` trusts it.
    fn reconcile(scan: *Scan, symbol_table: elf.Elf64_Shdr, dynamic: Dynamic) Error!void {
        const offset = dynamic.symbols orelse return;
        if (symbol_table.sh_offset != offset) return error.InvalidElf;
        const names = try scan.section(symbol_table.sh_link);
        if (names.sh_offset != dynamic.names.?.offset) return error.InvalidElf;
    }

    fn dynamicEntry(scan: *Scan, segment: elf.Elf64.Phdr, index: u64) Error!elf.Elf64_Dyn {
        std.debug.assert(index < segment.filesz / @sizeOf(elf.Elf64_Dyn));
        try seek(scan.records, segment.offset + index * @sizeOf(elf.Elf64_Dyn));
        return scan.records.interface.takeStruct(elf.Elf64_Dyn, .little) catch |err|
            return readFailure(err);
    }

    /// The bytes of the file that the loader places at `address` for
    /// `bytes` bytes: those of the first loaded segment whose file image
    /// holds them all.
    fn loaded(scan: *Scan, address: u64, bytes: u64) Error!Strings {
        const end = std.math.add(u64, address, bytes) catch return error.InvalidElf;
        for (0..scan.header.phnum) |index| {
            const program = try scan.programHeader(index);
            if (program.type != .LOAD or address < program.vaddr) continue;
            const image_end = std.math.add(u64, program.vaddr, program.filesz) catch
                return error.InvalidElf;
            if (end > image_end) continue;
            return .{ .offset = program.offset + (address - program.vaddr), .bytes = bytes };
        }
        return error.InvalidElf;
    }

    /// The number of program headers, once their table is known to lie
    /// inside the file.
    fn programCount(scan: *Scan) Error!u64 {
        if (scan.header.phnum == 0) return 0;
        if (scan.header.phnum == std.math.maxInt(u16)) return error.InvalidElf;
        if (scan.header.phentsize != @sizeOf(elf.Elf64.Phdr)) return error.InvalidElf;
        try scan.within(scan.header.phoff, @as(u64, scan.header.phnum) * @sizeOf(elf.Elf64.Phdr));
        return scan.header.phnum;
    }

    fn programHeader(scan: *Scan, index: u64) Error!elf.Elf64.Phdr {
        std.debug.assert(index < scan.header.phnum);
        try seek(scan.records, scan.header.phoff + index * @sizeOf(elf.Elf64.Phdr));
        return scan.records.interface.takeStruct(elf.Elf64.Phdr, .little) catch |err|
            return readFailure(err);
    }

    fn symbols(scan: *Scan, symbol_table: elf.Elf64_Shdr) Error!void {
        const count = try scan.table(symbol_table, @sizeOf(elf.Elf64_Sym));
        const names = try scan.linkedStrings(symbol_table);
        for (0..count) |index| {
            try seek(scan.records, symbol_table.sh_offset + index * @sizeOf(elf.Elf64_Sym));
            const symbol = scan.records.interface.takeStruct(elf.Elf64_Sym, .little) catch |err|
                return readFailure(err);
            if (symbol.st_shndx == shn_xindex) return error.ExtendedSectionIndex;
            if (symbol.st_shndx != elf.SHN_UNDEF or symbol.st_name == 0) continue;
            const name = try scan.readName(names, symbol.st_name);
            if (runtime(name)) scan.found(.undefined_symbol, name.bytes);
        }
    }

    /// Reads the name at `offset` in string table `names`, which must end
    /// inside the table. Keeps its first `name_window_bytes`, cut at the
    /// version's `@`.
    fn readName(scan: *Scan, names: Strings, offset: u64) Error!Name {
        if (offset >= names.bytes) return error.InvalidElf;
        try seek(scan.strings, names.offset + offset);
        var remaining = names.bytes - offset;
        var length: u64 = 0;
        while (true) {
            if (remaining == 0) return error.InvalidElf;
            const buffered = scan.strings.interface.peekGreedy(1) catch |err|
                return readFailure(err);
            const chunk = buffered[0..@intCast(@min(buffered.len, remaining))];
            const end = std.mem.indexOfScalar(u8, chunk, 0);
            const used = end orelse chunk.len;
            if (length < name_window_bytes) {
                const kept = @min(used, name_window_bytes - length);
                @memcpy(scan.name_storage[@intCast(length)..][0..kept], chunk[0..kept]);
            }
            length += used;
            if (end != null) break;
            scan.strings.interface.toss(chunk.len);
            remaining -= chunk.len;
        }
        const kept = scan.name_storage[0..@intCast(@min(length, name_window_bytes))];
        if (std.mem.indexOfScalar(u8, kept, '@')) |version| {
            return .{ .bytes = kept[0..version], .complete = true };
        }
        return .{ .bytes = kept, .complete = length <= name_window_bytes };
    }

    fn within(scan: *Scan, offset: u64, bytes: u64) Error!void {
        const end = std.math.add(u64, offset, bytes) catch return error.InvalidElf;
        if (end > scan.file_bytes) return error.InvalidElf;
    }

    fn found(scan: *Scan, kind: Kind, bytes: []const u8) void {
        scan.seen.insert(kind);
        if (scan.report) |report| report.found(report.context, kind, bytes);
    }
};

/// Where the loader finds the dynamic symbols and their names in the file.
const Dynamic = struct {
    names: ?Strings = null,
    symbols: ?u64 = null,
};

/// Where a string table's bytes lie in the file.
const Strings = struct {
    offset: u64,
    bytes: u64,
};

const Name = struct {
    bytes: []const u8,
    /// False when the name runs past the window, so only a prefix can match.
    complete: bool,
};

fn runtime(name: Name) bool {
    if (startsWithAny(name.bytes, &policy.runtime_prefixes)) return true;
    if (!name.complete) return false;
    for (policy.runtime_symbols) |symbol| {
        if (std.mem.eql(u8, name.bytes, symbol)) return true;
    }
    return false;
}

fn startsWithAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

fn seek(reader: *std.Io.File.Reader, offset: u64) Error!void {
    reader.seekTo(offset) catch return error.ReadFailed;
}

/// A read past the end of the file finds a malformed file; any other read
/// failure is the file system's.
fn readFailure(err: std.Io.Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.InvalidElf,
        error.ReadFailed => error.ReadFailed,
    };
}
