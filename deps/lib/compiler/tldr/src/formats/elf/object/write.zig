const std = @import("std");
const elf = @import("../root.zig");
const model = @import("model.zig");
const layout_plan = @import("layout.zig");

const Allocator = std.mem.Allocator;
const format = elf.format;
const shdr_size = format.shdr_size;
const sym_size = format.sym_size;
const rela_size = format.rela_size;
const copyInto = format.copyInto;
const Description = model.Description;
const Error = model.Error;
const Layout = layout_plan.Layout;

/// Writes one described object into `out`, which is exactly `layout.size`
/// bytes, using the layout (the planned file offsets for every record). A
/// caller that owns its output buffer calls this function after `plan` to write
/// the description (a value listing its header fields, sections, symbols and
/// relocations), and `build` calls it for everyone else. The call allocates
/// nothing and does no arithmetic that can fail, because `plan` already proved
/// every offset. The function zeroes `out` first, so the padding between
/// records is zero. Each described record is written in one bounded pass.
pub fn write(description: Description, layout: Layout, out: []u8) void {
    std.debug.assert(out.len == layout.size);
    @memset(out, 0);

    (format.Header{
        .type = description.header.type,
        .machine = description.header.machine,
        .entry = description.header.entry,
        .flags = description.header.flags,
        .shoff = layout.shoff,
        .shnum = layout.shnum,
        .shstrndx = layout.shstrtab_index,
    }).write(out);

    for (description.sections, 0..) |section, index| {
        copyInto(out, @intCast(layout.section_offsets[index]), section.bytes);
    }
    writeRelocations(description, layout, out);
    writeSymbols(description, layout, out);
    writeSectionHeaders(description, layout, out);
}

/// Plans the layout (the planned file offsets for every record), allocates the
/// output once at the planned size, writes it, and frees the layout, for tests
/// and tools that want the object's bytes in one call. The returned bytes
/// belong to the caller, who frees them with the same allocator.
pub fn build(allocator: Allocator, description: Description) Error![]u8 {
    var layout = try Layout.plan(allocator, description);
    defer layout.deinit(allocator);
    const out = try allocator.alloc(u8, layout.size);
    write(description, layout, out);
    return out;
}

/// Writes the relocation section of each described section that has
/// relocations, for `write` to emit every relocation section. The function
/// walks `layout.order` once, because that order already groups relocations by
/// ascending target and keeps input order within a target.
fn writeRelocations(description: Description, layout: Layout, out: []u8) void {
    var placed: usize = 0;
    for (description.sections, 0..) |_, index| {
        const count: usize = @intCast(layout.rela_counts[index]);
        if (count == 0) continue;
        const start: usize = @intCast(layout.rela_starts[index]);
        var slot: usize = 0;
        while (slot < count) : (slot += 1) {
            const relocation = description.relocations[@intCast(layout.order[placed + slot])];
            (format.Rela{
                .offset = relocation.offset,
                .info = relocation.info(),
                .addend = relocation.addend,
            }).write(out, start + slot * rela_size);
        }
        placed += count;
    }
    std.debug.assert(placed == layout.order.len);
}

/// Writes `.symtab` and `.strtab` in one pass, for `write` to emit the symbol
/// table. One cursor gives both each name's position in the name table and the
/// offset stored in its symbol entry, so the two always agree.
fn writeSymbols(description: Description, layout: Layout, out: []u8) void {
    const table = out[@intCast(layout.symtab_offset)..];
    const names = out[@intCast(layout.strtab_offset)..];
    (format.SymbolRecord{}).write(table, 0);

    var cursor: usize = 1;
    for (description.symbols, 0..) |symbol, index| {
        var name_offset: u32 = 0;
        if (symbol.name.len != 0) {
            name_offset = @intCast(cursor);
            copyInto(names, cursor, symbol.name);
            cursor += symbol.name.len + 1;
        }
        (format.SymbolRecord{
            .name_offset = name_offset,
            .info = symbol.info(),
            .other = symbol.other,
            .section_index = symbol.section_index,
            .value = symbol.value,
            .size = symbol.size,
        }).write(table, (index + 1) * sym_size);
    }
    std.debug.assert(cursor == layout.strtab_size);
}

/// Writes the section headers and `.shstrtab` in one pass, with one cursor for
/// both, the same way `writeSymbols` pairs its two tables, for `write` to emit
/// the section header table.
fn writeSectionHeaders(description: Description, layout: Layout, out: []u8) void {
    const table = out[@intCast(layout.shoff)..];
    const names = out[@intCast(layout.shstrtab_offset)..];
    (format.SectionHeader{}).write(table, 0);

    var cursor: usize = 1;
    for (description.sections, 0..) |section, index| {
        copyInto(names, cursor, section.name);
        (format.SectionHeader{
            .name_offset = @intCast(cursor),
            .section_type = section.section_type,
            .flags = section.flags,
            .address = section.address,
            .offset = layout.section_offsets[index],
            .size = section.wireSize(),
            .link = sectionLink(section, layout),
            .info = section.info,
            .alignment = section.alignment,
            .entry_size = section.entry_size,
        }).write(table, (index + 1) * shdr_size);
        cursor += section.name.len + 1;
    }

    var rela_index: usize = description.sections.len + 1;
    for (description.sections, 0..) |section, index| {
        const count = layout.rela_counts[index];
        if (count == 0) continue;
        copyInto(names, cursor, layout_plan.rela_name_prefix);
        copyInto(names, cursor + layout_plan.rela_name_prefix.len, section.name);
        (format.SectionHeader{
            .name_offset = @intCast(cursor),
            .section_type = std.elf.SHT_RELA,
            .offset = layout.rela_starts[index],
            .size = count * rela_size,
            .link = layout.symtab_index,
            .info = @intCast(index + 1),
            .alignment = 8,
            .entry_size = rela_size,
        }).write(table, rela_index * shdr_size);
        cursor += layout_plan.rela_name_prefix.len + section.name.len + 1;
        rela_index += 1;
    }
    std.debug.assert(rela_index == layout.symtab_index);

    writeTrailingHeaders(layout, table, names, cursor);
}

/// Writes the three headers every object ends with, for `writeSectionHeaders`
/// to finish the table, in this fixed order: those of `.symtab`, `.strtab` and
/// `.shstrtab`.
fn writeTrailingHeaders(layout: Layout, table: []u8, names: []u8, start: usize) void {
    var cursor = start;
    copyInto(names, cursor, layout_plan.symtab_name);
    (format.SectionHeader{
        .name_offset = @intCast(cursor),
        .section_type = std.elf.SHT_SYMTAB,
        .offset = layout.symtab_offset,
        .size = layout.symtab_size,
        .link = layout.strtab_index,
        .info = layout.first_global,
        .alignment = 8,
        .entry_size = sym_size,
    }).write(table, @as(usize, layout.symtab_index) * shdr_size);
    cursor += layout_plan.symtab_name.len + 1;

    copyInto(names, cursor, layout_plan.strtab_name);
    (format.SectionHeader{
        .name_offset = @intCast(cursor),
        .section_type = std.elf.SHT_STRTAB,
        .offset = layout.strtab_offset,
        .size = layout.strtab_size,
        .alignment = 1,
    }).write(table, @as(usize, layout.strtab_index) * shdr_size);
    cursor += layout_plan.strtab_name.len + 1;

    copyInto(names, cursor, layout_plan.shstrtab_name);
    (format.SectionHeader{
        .name_offset = @intCast(cursor),
        .section_type = std.elf.SHT_STRTAB,
        .offset = layout.shstrtab_offset,
        .size = layout.shstrtab_size,
        .alignment = 1,
    }).write(table, @as(usize, layout.shstrtab_index) * shdr_size);
    cursor += layout_plan.shstrtab_name.len + 1;
    std.debug.assert(cursor == layout.shstrtab_size);
}

/// Returns the symbol table's index for a group section, because the group's
/// `sh_info` names its signature symbol by an index into that table.
/// `writeSectionHeaders` calls this function for each described section's
/// `sh_link` field. Every other section keeps the link stated in its
/// description (a value listing the object's header fields, sections, symbols
/// and relocations).
fn sectionLink(section: Section, layout: Layout) u32 {
    if (section.section_type == std.elf.SHT_GROUP) return layout.symtab_index;
    return section.link;
}

const Section = model.Section;
const Symbol = model.Symbol;
const Relocation = model.Relocation;
