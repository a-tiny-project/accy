const std = @import("std");
const elf = @import("../root.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const format = elf.format;
const ehdr_size = format.ehdr_size;
const shdr_size = format.shdr_size;
const sym_size = format.sym_size;
const rela_size = format.rela_size;
const Description = model.Description;
const Error = model.Error;
const Section = model.Section;
const Symbol = model.Symbol;

/// The section names the writer supplies itself, leaving them out of every
/// description: the `.rela` prefix put before a section's name to name its
/// relocation section, and `.symtab`, `.strtab` and `.shstrtab`. The layout
/// sizes the section name table from these names, and the writer copies them
/// into it, so both agree on its bytes.
pub const rela_name_prefix = ".rela";
pub const symtab_name = ".symtab";
pub const strtab_name = ".strtab";
pub const shstrtab_name = ".shstrtab";

/// The number of section headers every object has besides one per described
/// section and one per relocation section: the empty header at index 0 plus the
/// headers of `.symtab`, `.strtab` and `.shstrtab`. The layout adds this
/// constant when counting section headers, and tests use it to predict the
/// header count.
pub const fixed_section_count = 4;

/// The number of 64-bit slots `plan` sets aside for each described section: the
/// section's file offset, its relocation count, and the file offset of its
/// relocation section. The `plan` function multiplies the section count by it
/// to size its scratch allocation.
const words_per_section = 3;

/// Records where each part of one described object goes in the file: each
/// section's bytes, each relocation section, `.symtab`, `.strtab`, `.shstrtab`
/// and the section header table, along with the total file size. The `plan`
/// function computes the layout once from the description and checks every
/// addition and multiplication, so `write` has no arithmetic left that can
/// fail. One allocation, `scratch`, holds four slices in this order: each
/// section's file offset, each section's relocation count, each relocation
/// section's file offset, and the order in which the writer emits relocations.
/// The `build` function plans a layout and passes it to `write`, and a caller
/// that writes into its own buffer does the same and calls `deinit` to free
/// `scratch` with the allocator that was given to `plan`.
pub const Layout = struct {
    size: usize,
    shoff: u64,
    shnum: u16,
    symtab_index: u16,
    strtab_index: u16,
    shstrtab_index: u16,
    first_global: u32,
    symtab_offset: u64,
    symtab_size: u64,
    strtab_offset: u64,
    strtab_size: u64,
    shstrtab_offset: u64,
    shstrtab_size: u64,
    scratch: []u64,
    section_offsets: []u64,
    rela_counts: []u64,
    rela_starts: []u64,
    order: []u64,

    /// Checks `description` and computes the file offset of every record, so
    /// callers run it before `write`, directly or through `build`, to learn the
    /// file size to allocate. The call returns `error.TooManySymbols` for 2^32 -
    /// 1 symbols or more, `error.InvalidAlignment` for an alignment that is
    /// neither 0 nor a power of two, and `error.InvalidSize` for a NOBITS
    /// section that carries bytes or for any other section whose nonzero `size`
    /// differs from the length of its bytes. The function returns
    /// `error.SymbolOrder` for a local symbol after a global one,
    /// `error.InvalidSectionIndex` for a relocation whose target is 0 or past
    /// the last section, `error.TooManySections` for more headers than an index
    /// below `SHN_LORESERVE` can name, and `error.SizeOverflow` for an offset
    /// or a string table size too large to represent. The function makes one
    /// allocation whose size follows from the section and relocation counts
    /// alone, so it is fixed up front and no later step enlarges it. The caller
    /// frees the result with `Layout.deinit`.
    pub fn plan(allocator: Allocator, description: Description) Error!Layout {
        if (description.symbols.len >= std.math.maxInt(u32)) return error.TooManySymbols;
        for (description.sections) |section| try validateSection(section);
        const first_global = try firstGlobalIndex(description.symbols);

        const section_count = description.sections.len;
        const words = words_per_section * section_count + description.relocations.len;
        const scratch = try allocator.alloc(u64, words);
        errdefer allocator.free(scratch);
        const section_offsets = scratch[0..section_count];
        const rela_counts = scratch[section_count..][0..section_count];
        const rela_starts = scratch[2 * section_count ..][0..section_count];
        const order = scratch[words_per_section * section_count ..];
        const carved = section_offsets.len + rela_counts.len + rela_starts.len;
        std.debug.assert(carved + order.len == scratch.len);

        const relocated_sections =
            try countRelocations(description, rela_counts, rela_starts, order);

        const shnum_count = section_count + relocated_sections + fixed_section_count;
        if (shnum_count >= std.elf.SHN_LORESERVE) return error.TooManySections;
        const symtab_index: u16 = @intCast(1 + section_count + relocated_sections);

        var offset = try placePayloads(description, section_offsets, rela_counts, rela_starts);
        offset = try alignForward(offset, 8);
        const symtab_offset = offset;
        const symtab_size = try mul(description.symbols.len + 1, sym_size);
        offset = try add(offset, symtab_size);

        const strtab_offset = offset;
        const strtab_size = try symbolNameTableSize(description.symbols);
        offset = try add(offset, strtab_size);

        const shstrtab_offset = offset;
        const shstrtab_size = try sectionNameTableSize(description.sections, rela_counts);
        offset = try add(offset, shstrtab_size);

        const shoff = try alignForward(offset, 8);
        const total = try add(shoff, try mul(shnum_count, shdr_size));

        return .{
            .size = std.math.cast(usize, total) orelse return error.SizeOverflow,
            .shoff = shoff,
            .shnum = @intCast(shnum_count),
            .symtab_index = symtab_index,
            .strtab_index = symtab_index + 1,
            .shstrtab_index = symtab_index + 2,
            .first_global = first_global,
            .symtab_offset = symtab_offset,
            .symtab_size = symtab_size,
            .strtab_offset = strtab_offset,
            .strtab_size = strtab_size,
            .shstrtab_offset = shstrtab_offset,
            .shstrtab_size = shstrtab_size,
            .scratch = scratch,
            .section_offsets = section_offsets,
            .rela_counts = rela_counts,
            .rela_starts = rela_starts,
            .order = order,
        };
    }

    pub fn deinit(self: *Layout, allocator: Allocator) void {
        allocator.free(self.scratch);
        self.* = undefined;
    }
};

/// Places each described section's bytes at the next offset its alignment
/// allows, starting after the 64-byte file header, then places each relocation
/// section at an 8-byte boundary, and returns the first offset past all of
/// them. The `plan` function calls it to place the section bytes and the
/// relocation sections before it places the tables that follow them. The
/// described sections go first so that each keeps the alignment its description
/// asked for. The function writes each relocation section's file offset into
/// `rela_starts`, or 0 for a section with no relocations, replacing the sort
/// positions `countRelocations` left there.
fn placePayloads(
    description: Description,
    section_offsets: []u64,
    rela_counts: []const u64,
    rela_starts: []u64,
) Error!u64 {
    var offset: u64 = ehdr_size;
    for (description.sections, 0..) |section, index| {
        offset = try alignForward(offset, section.alignment);
        section_offsets[index] = offset;
        offset = try add(offset, section.fileSize());
    }
    for (rela_counts, 0..) |count, index| {
        if (count == 0) {
            rela_starts[index] = 0;
            continue;
        }
        offset = try alignForward(offset, 8);
        rela_starts[index] = offset;
        offset = try add(offset, try mul(count, rela_size));
    }
    return offset;
}

/// Counts the relocations aimed at each described section and returns how many
/// sections receive any. The `plan` function calls it once so that the writer
/// can emit every relocation section in a single walk. The function fills
/// `order` with relocation indices sorted by target section, keeping the input
/// order among relocations with the same target. `rela_starts` holds each
/// target's running position during this counting sort, and `placePayloads`
/// later overwrites it with file offsets. The function returns
/// `error.InvalidSectionIndex` for a target of 0 or one past the last described
/// section.
fn countRelocations(
    description: Description,
    rela_counts: []u64,
    rela_starts: []u64,
    order: []u64,
) Error!usize {
    @memset(rela_counts, 0);
    for (description.relocations) |relocation| {
        if (relocation.section == 0) return error.InvalidSectionIndex;
        const target = @as(usize, relocation.section);
        if (target > description.sections.len) return error.InvalidSectionIndex;
        rela_counts[relocation.section - 1] += 1;
    }

    var running: u64 = 0;
    var relocated_sections: usize = 0;
    for (rela_counts, 0..) |count, index| {
        rela_starts[index] = running;
        running += count;
        if (count != 0) relocated_sections += 1;
    }
    std.debug.assert(running == description.relocations.len);
    for (description.relocations, 0..) |relocation, index| {
        const target = relocation.section - 1;
        order[@intCast(rela_starts[target])] = index;
        rela_starts[target] += 1;
    }
    return relocated_sections;
}

fn validateSection(section: Section) Error!void {
    const aligned = section.alignment == 0 or std.math.isPowerOfTwo(section.alignment);
    if (!aligned) return error.InvalidAlignment;
    if (section.isNoBits()) {
        if (section.bytes.len != 0) return error.InvalidSize;
        return;
    }
    if (section.size != 0 and section.size != section.bytes.len) return error.InvalidSize;
}

/// Computes the value of the symbol table header's `sh_info` field: the table
/// index one past the last local symbol. The `plan` function stores this result
/// so the writer can put it in the symbol table's header. Counting starts at
/// one because the writer places an empty entry at index 0. The function
/// returns `error.SymbolOrder` when a local symbol follows a global one.
fn firstGlobalIndex(symbols: []const Symbol) Error!u32 {
    var locals: usize = 0;
    var seen_global = false;
    for (symbols) |symbol| {
        if (!symbol.isLocal()) {
            seen_global = true;
            continue;
        }
        if (seen_global) return error.SymbolOrder;
        locals += 1;
    }
    return @intCast(1 + locals);
}

fn symbolNameTableSize(symbols: []const Symbol) Error!u64 {
    var size: u64 = 1;
    for (symbols) |symbol| {
        if (symbol.name.len == 0) continue;
        size = try add(size, try add(symbol.name.len, 1));
    }
    if (size > std.math.maxInt(u32)) return error.SizeOverflow;
    return size;
}

fn sectionNameTableSize(sections: []const Section, rela_counts: []const u64) Error!u64 {
    var size: u64 = 1;
    for (sections) |section| size = try add(size, try add(section.name.len, 1));
    for (sections, 0..) |section, index| {
        if (rela_counts[index] == 0) continue;
        size = try add(size, try add(rela_name_prefix.len + section.name.len, 1));
    }
    size = try add(size, symtab_name.len + 1);
    size = try add(size, strtab_name.len + 1);
    size = try add(size, shstrtab_name.len + 1);
    if (size > std.math.maxInt(u32)) return error.SizeOverflow;
    return size;
}

fn add(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch error.SizeOverflow;
}

fn mul(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch error.SizeOverflow;
}

/// Rounds `value` up to a multiple of `alignment`, and an alignment of 0 or 1
/// leaves it unchanged. `plan` and `placePayloads` use it for every aligned
/// offset. The function returns `error.SizeOverflow` when rounding up would
/// pass the largest 64-bit value.
fn alignForward(value: u64, alignment: u64) Error!u64 {
    if (alignment <= 1) return value;
    const mask = alignment - 1;
    return (try add(value, mask)) & ~mask;
}

test "ELF object layout places every generated table after the described sections" {
    const allocator = std.testing.allocator;
    const description = Description{
        .sections = &.{
            Section.progbits(".text", "\x90\x90\x90\x90", std.elf.SHF_EXECINSTR, 16),
            Section.progbits(".data", "\x00\x00\x00\x00\x00\x00\x00\x00", std.elf.SHF_WRITE, 8),
            Section.nobits(".bss", 64, std.elf.SHF_WRITE, 8),
        },
        .symbols = &.{
            Symbol.section(1),
            Symbol.function("main", 1, 0, 4),
        },
        .relocations = &.{
            model.Relocation.x86_64(2, 0, 2, .@"64", 0),
        },
    };

    var layout = try Layout.plan(allocator, description);
    defer layout.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 3 + 1 + fixed_section_count), layout.shnum);
    try std.testing.expectEqual(@as(u16, 5), layout.symtab_index);
    try std.testing.expectEqual(@as(u16, 6), layout.strtab_index);
    try std.testing.expectEqual(@as(u16, 7), layout.shstrtab_index);
    try std.testing.expectEqual(@as(u32, 2), layout.first_global);

    try std.testing.expectEqual(@as(u64, 64), layout.section_offsets[0]);
    try std.testing.expectEqual(@as(u64, 72), layout.section_offsets[1]);
    try std.testing.expectEqual(@as(u64, 80), layout.section_offsets[2]);

    try std.testing.expectEqual(@as(u64, 0), layout.rela_counts[0]);
    try std.testing.expectEqual(@as(u64, 1), layout.rela_counts[1]);
    try std.testing.expectEqual(@as(u64, 80), layout.rela_starts[1]);

    try std.testing.expectEqual(@as(u64, 104), layout.symtab_offset);
    try std.testing.expectEqual(@as(u64, 3 * sym_size), layout.symtab_size);
    try std.testing.expectEqual(@as(u64, 176), layout.strtab_offset);
    try std.testing.expectEqual(@as(u64, 6), layout.strtab_size);
    try std.testing.expectEqual(@as(u64, 182), layout.shstrtab_offset);
    try std.testing.expectEqual(@as(u64, 1 + 6 + 6 + 5 + 11 + 8 + 8 + 10), layout.shstrtab_size);
    try std.testing.expectEqual(@as(u64, 240), layout.shoff);
    try std.testing.expectEqual(@as(usize, 240 + 8 * shdr_size), layout.size);
}

test "ELF object layout orders relocations by target then by input" {
    const allocator = std.testing.allocator;
    const description = Description{
        .sections = &.{
            Section.progbits(".text", "\x90\x90\x90\x90\x90\x90\x90\x90", std.elf.SHF_EXECINSTR, 1),
            Section.progbits(".data", "\x00\x00\x00\x00\x00\x00\x00\x00", std.elf.SHF_WRITE, 1),
        },
        .symbols = &.{Symbol.undefinedFunction("target")},
        .relocations = &.{
            model.Relocation.x86_64(2, 0, 1, .@"64", 0),
            model.Relocation.x86_64(1, 1, 1, .PLT32, -4),
            model.Relocation.x86_64(2, 8, 1, .@"64", 8),
            model.Relocation.x86_64(1, 2, 1, .PC32, -4),
        },
    };

    var layout = try Layout.plan(allocator, description);
    defer layout.deinit(allocator);

    try std.testing.expectEqualSlices(u64, &.{ 2, 2 }, layout.rela_counts);
    try std.testing.expectEqualSlices(u64, &.{ 1, 3, 0, 2 }, layout.order);
    try std.testing.expect(layout.rela_starts[0] < layout.rela_starts[1]);
}

test "ELF object layout refuses an alignment that is not a power of two" {
    const description = Description{ .sections = &.{Section.progbits(".text", "\x90", 0, 3)} };
    const planned = Layout.plan(std.testing.allocator, description);
    try std.testing.expectError(error.InvalidAlignment, planned);
}

test "ELF object layout refuses a size that contradicts the section bytes" {
    const stated = Description{
        .sections = &.{.{ .name = ".text", .bytes = "\x90\x90", .size = 9 }},
    };
    try std.testing.expectError(error.InvalidSize, Layout.plan(std.testing.allocator, stated));

    const occupied = Description{
        .sections = &.{.{
            .name = ".bss",
            .section_type = std.elf.SHT_NOBITS,
            .bytes = "\x00",
            .size = 8,
        }},
    };
    try std.testing.expectError(error.InvalidSize, Layout.plan(std.testing.allocator, occupied));
}

test "ELF object layout refuses a relocation against no described section" {
    const sections = [_]Section{Section.progbits(".text", "\x90", 0, 1)};
    const absent = Description{
        .sections = &sections,
        .relocations = &.{model.Relocation.x86_64(0, 0, 1, .@"64", 0)},
    };
    const missing = Layout.plan(std.testing.allocator, absent);
    try std.testing.expectError(error.InvalidSectionIndex, missing);

    const past_end = Description{
        .sections = &sections,
        .relocations = &.{model.Relocation.x86_64(2, 0, 1, .@"64", 0)},
    };
    const beyond = Layout.plan(std.testing.allocator, past_end);
    try std.testing.expectError(error.InvalidSectionIndex, beyond);
}

test "ELF object layout refuses a local symbol after a global one" {
    const description = Description{
        .sections = &.{Section.progbits(".text", "\x90", 0, 1)},
        .symbols = &.{ Symbol.function("main", 1, 0, 1), Symbol.section(1) },
    };
    try std.testing.expectError(error.SymbolOrder, Layout.plan(std.testing.allocator, description));
}

test "ELF object layout refuses more sections than a section index can name" {
    const allocator = std.testing.allocator;
    const sections = try allocator.alloc(Section, std.elf.SHN_LORESERVE);
    defer allocator.free(sections);
    for (sections) |*section| section.* = Section.progbits(".t", "\x90", 0, 1);

    const planned = Layout.plan(allocator, .{ .sections = sections });
    try std.testing.expectError(error.TooManySections, planned);
}

/// Returns a slice that claims 2^32 - 1 symbols over storage that holds one, so
/// the symbol limit test can pass `plan` a symbol count too large to store. The
/// `plan` function checks the count before it reads any entry, so the test
/// reads none of the missing elements and they need no memory.
fn overlongSymbols(storage: *const [1]Symbol) []const Symbol {
    return @as([*]const Symbol, storage)[0..std.math.maxInt(u32)];
}

test "ELF object layout refuses more symbols than a table index can name" {
    const storage = [_]Symbol{.{}};
    const description = Description{ .sections = &.{}, .symbols = overlongSymbols(&storage) };

    const planned = Layout.plan(std.testing.allocator, description);
    try std.testing.expectError(error.TooManySymbols, planned);
}

test "ELF object layout refuses an alignment that leaves the address space" {
    const huge = @as(u64, 1) << 63;
    const description = Description{
        .sections = &.{
            .{ .name = ".a", .bytes = "\x90", .alignment = huge },
            .{ .name = ".b", .bytes = "\x90", .alignment = huge },
        },
    };
    const planned = Layout.plan(std.testing.allocator, description);
    try std.testing.expectError(error.SizeOverflow, planned);
}

test "ELF object layout reports an allocator that cannot hold its scratch" {
    const description = Description{ .sections = &.{Section.progbits(".text", "\x90", 0, 1)} };
    const planned = Layout.plan(std.testing.failing_allocator, description);
    try std.testing.expectError(error.OutOfMemory, planned);
}
