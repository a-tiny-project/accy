const std = @import("std");

pub const OutputSectionKind = enum {
    build_id_note,
    init,
    text,
    fini,
    iplt,
    eh_frame_hdr,
    eh_frame,
    rodata,
    rela_iplt,
    preinit_array,
    init_array,
    fini_array,
    data,
    got,
    igot,
    tdata,
    tbss,
    bss,
    debug_abbrev,
    debug_addr,
    debug_aranges,
    debug_cu_index,
    debug_frame,
    debug_info,
    debug_line,
    debug_line_str,
    debug_loc,
    debug_loclists,
    debug_macinfo,
    debug_macro,
    debug_names,
    debug_pubnames,
    debug_pubtypes,
    debug_ranges,
    debug_rnglists,
    debug_str,
    debug_str_offsets,
    debug_tu_index,
    debug_types,

    pub fn name(self: OutputSectionKind) []const u8 {
        return switch (self) {
            .build_id_note => ".note.gnu.build-id",
            .init => ".init",
            .text => ".text",
            .fini => ".fini",
            .iplt => ".iplt",
            .eh_frame_hdr => ".eh_frame_hdr",
            .eh_frame => ".eh_frame",
            .rodata => ".rodata",
            .rela_iplt => ".rela.iplt",
            .preinit_array => ".preinit_array",
            .init_array => ".init_array",
            .fini_array => ".fini_array",
            .data => ".data",
            .got => ".got",
            .igot => ".igot",
            .tdata => ".tdata",
            .tbss => ".tbss",
            .bss => ".bss",
            .debug_abbrev => ".debug_abbrev",
            .debug_addr => ".debug_addr",
            .debug_aranges => ".debug_aranges",
            .debug_cu_index => ".debug_cu_index",
            .debug_frame => ".debug_frame",
            .debug_info => ".debug_info",
            .debug_line => ".debug_line",
            .debug_line_str => ".debug_line_str",
            .debug_loc => ".debug_loc",
            .debug_loclists => ".debug_loclists",
            .debug_macinfo => ".debug_macinfo",
            .debug_macro => ".debug_macro",
            .debug_names => ".debug_names",
            .debug_pubnames => ".debug_pubnames",
            .debug_pubtypes => ".debug_pubtypes",
            .debug_ranges => ".debug_ranges",
            .debug_rnglists => ".debug_rnglists",
            .debug_str => ".debug_str",
            .debug_str_offsets => ".debug_str_offsets",
            .debug_tu_index => ".debug_tu_index",
            .debug_types => ".debug_types",
        };
    }

    pub fn flags(self: OutputSectionKind) u64 {
        return switch (self) {
            .build_id_note => std.elf.SHF_ALLOC,
            .init, .text, .fini, .iplt => std.elf.SHF_ALLOC | std.elf.SHF_EXECINSTR,
            .eh_frame_hdr, .eh_frame, .rodata, .rela_iplt => std.elf.SHF_ALLOC,
            .preinit_array, .init_array, .fini_array, .data, .got, .igot => std.elf.SHF_ALLOC | std.elf.SHF_WRITE,
            .tdata, .tbss => std.elf.SHF_ALLOC | std.elf.SHF_WRITE | std.elf.SHF_TLS,
            .bss => std.elf.SHF_ALLOC | std.elf.SHF_WRITE,
            .debug_abbrev,
            .debug_addr,
            .debug_aranges,
            .debug_cu_index,
            .debug_frame,
            .debug_info,
            .debug_line,
            .debug_line_str,
            .debug_loc,
            .debug_loclists,
            .debug_macinfo,
            .debug_macro,
            .debug_names,
            .debug_pubnames,
            .debug_pubtypes,
            .debug_ranges,
            .debug_rnglists,
            .debug_str,
            .debug_str_offsets,
            .debug_tu_index,
            .debug_types,
            => 0,
        };
    }

    pub fn sectionType(self: OutputSectionKind) u32 {
        return switch (self) {
            .build_id_note => std.elf.SHT_NOTE,
            .rela_iplt => std.elf.SHT_RELA,
            .preinit_array => std.elf.SHT_PREINIT_ARRAY,
            .init_array => std.elf.SHT_INIT_ARRAY,
            .fini_array => std.elf.SHT_FINI_ARRAY,
            .init,
            .text,
            .fini,
            .iplt,
            .eh_frame_hdr,
            .eh_frame,
            .rodata,
            .data,
            .got,
            .igot,
            .tdata,
            .debug_abbrev,
            .debug_addr,
            .debug_aranges,
            .debug_cu_index,
            .debug_frame,
            .debug_info,
            .debug_line,
            .debug_line_str,
            .debug_loc,
            .debug_loclists,
            .debug_macinfo,
            .debug_macro,
            .debug_names,
            .debug_pubnames,
            .debug_pubtypes,
            .debug_ranges,
            .debug_rnglists,
            .debug_str,
            .debug_str_offsets,
            .debug_tu_index,
            .debug_types,
            => std.elf.SHT_PROGBITS,
            .tbss, .bss => std.elf.SHT_NOBITS,
        };
    }

    pub fn programFlags(self: OutputSectionKind) u32 {
        return switch (self) {
            .build_id_note => std.elf.PF_R,
            .init, .text, .fini, .iplt => std.elf.PF_R | std.elf.PF_X,
            .eh_frame_hdr, .eh_frame, .rodata, .rela_iplt => std.elf.PF_R,
            .preinit_array, .init_array, .fini_array, .data, .got, .igot, .tdata, .tbss, .bss => std.elf.PF_R | std.elf.PF_W,
            .debug_abbrev,
            .debug_addr,
            .debug_aranges,
            .debug_cu_index,
            .debug_frame,
            .debug_info,
            .debug_line,
            .debug_line_str,
            .debug_loc,
            .debug_loclists,
            .debug_macinfo,
            .debug_macro,
            .debug_names,
            .debug_pubnames,
            .debug_pubtypes,
            .debug_ranges,
            .debug_rnglists,
            .debug_str,
            .debug_str_offsets,
            .debug_tu_index,
            .debug_types,
            => 0,
        };
    }

    pub fn isAllocated(self: OutputSectionKind) bool {
        return (self.flags() & std.elf.SHF_ALLOC) != 0;
    }

    pub fn isNoBits(self: OutputSectionKind) bool {
        return self.sectionType() == std.elf.SHT_NOBITS;
    }

    pub fn isTls(self: OutputSectionKind) bool {
        return self == .tdata or self == .tbss;
    }

    pub fn entrySize(self: OutputSectionKind) u64 {
        return switch (self) {
            .rela_iplt => 24,
            else => 0,
        };
    }
};

pub const output_section_count = @typeInfo(OutputSectionKind).@"enum".field_names.len;

pub fn indexForAllocatedNamed(section: anytype, name: []const u8) usize {
    const named_alloc = (section.flags & std.elf.SHF_TLS) == 0 and section.section_type != std.elf.SHT_NOBITS;
    if (named_alloc) {
        if (name.len > 1 and name[0] == '.') {
            switch (name[1]) {
                'e' => if (std.mem.eql(u8, name, ".eh_frame")) return @backingInt(OutputSectionKind.eh_frame),
                'f' => {
                    if ((section.flags & std.elf.SHF_EXECINSTR) != 0 and std.mem.eql(u8, name, ".fini")) return @backingInt(OutputSectionKind.fini);
                    if (std.mem.eql(u8, name, ".fini_array") or std.mem.startsWith(u8, name, ".fini_array.")) return @backingInt(OutputSectionKind.fini_array);
                },
                'i' => {
                    if ((section.flags & std.elf.SHF_EXECINSTR) != 0 and std.mem.eql(u8, name, ".init")) return @backingInt(OutputSectionKind.init);
                    if (std.mem.eql(u8, name, ".init_array") or std.mem.startsWith(u8, name, ".init_array.")) return @backingInt(OutputSectionKind.init_array);
                },
                'p' => if (std.mem.eql(u8, name, ".preinit_array")) return @backingInt(OutputSectionKind.preinit_array),
                else => {},
            }
        }
        if (section.section_type == std.elf.SHT_X86_64_UNWIND) return @backingInt(OutputSectionKind.eh_frame);
    }
    return indexForAllocated(section);
}

pub fn indexForAllocated(section: anytype) usize {
    if ((section.flags & std.elf.SHF_TLS) != 0) {
        if (section.section_type == std.elf.SHT_NOBITS) return @backingInt(OutputSectionKind.tbss);
        return @backingInt(OutputSectionKind.tdata);
    }
    if (section.section_type == std.elf.SHT_NOBITS) return @backingInt(OutputSectionKind.bss);
    if ((section.flags & std.elf.SHF_EXECINSTR) != 0) return @backingInt(OutputSectionKind.text);
    if ((section.flags & std.elf.SHF_WRITE) != 0) return @backingInt(OutputSectionKind.data);
    return @backingInt(OutputSectionKind.rodata);
}

pub fn isAllocatedPayloadType(section_type: u32) bool {
    return switch (section_type) {
        std.elf.SHT_PROGBITS,
        std.elf.SHT_NOBITS,
        std.elf.SHT_NOTE,
        std.elf.SHT_PREINIT_ARRAY,
        std.elf.SHT_INIT_ARRAY,
        std.elf.SHT_FINI_ARRAY,
        std.elf.SHT_X86_64_UNWIND,
        => true,
        else => false,
    };
}

pub fn debugOutputIndexForName(name: []const u8) ?usize {
    const debug_prefix = ".debug_";
    if (name.len <= debug_prefix.len) return null;
    if (name[0] != '.' or name[1] != 'd') return null;
    if (!std.mem.startsWith(u8, name, debug_prefix)) return null;
    const suffix = name[debug_prefix.len..];
    switch (suffix[0]) {
        'a' => {
            if (std.mem.eql(u8, suffix, "abbrev")) return @backingInt(OutputSectionKind.debug_abbrev);
            if (std.mem.eql(u8, suffix, "addr")) return @backingInt(OutputSectionKind.debug_addr);
            if (std.mem.eql(u8, suffix, "aranges")) return @backingInt(OutputSectionKind.debug_aranges);
        },
        'c' => if (std.mem.eql(u8, suffix, "cu_index")) return @backingInt(OutputSectionKind.debug_cu_index),
        'f' => if (std.mem.eql(u8, suffix, "frame")) return @backingInt(OutputSectionKind.debug_frame),
        'i' => if (std.mem.eql(u8, suffix, "info")) return @backingInt(OutputSectionKind.debug_info),
        'l' => {
            if (std.mem.eql(u8, suffix, "line")) return @backingInt(OutputSectionKind.debug_line);
            if (std.mem.eql(u8, suffix, "line_str")) return @backingInt(OutputSectionKind.debug_line_str);
            if (std.mem.eql(u8, suffix, "loc")) return @backingInt(OutputSectionKind.debug_loc);
            if (std.mem.eql(u8, suffix, "loclists")) return @backingInt(OutputSectionKind.debug_loclists);
        },
        'm' => {
            if (std.mem.eql(u8, suffix, "macinfo")) return @backingInt(OutputSectionKind.debug_macinfo);
            if (std.mem.eql(u8, suffix, "macro")) return @backingInt(OutputSectionKind.debug_macro);
        },
        'n' => if (std.mem.eql(u8, suffix, "names")) return @backingInt(OutputSectionKind.debug_names),
        'p' => {
            if (std.mem.eql(u8, suffix, "pubnames")) return @backingInt(OutputSectionKind.debug_pubnames);
            if (std.mem.eql(u8, suffix, "pubtypes")) return @backingInt(OutputSectionKind.debug_pubtypes);
        },
        'r' => {
            if (std.mem.eql(u8, suffix, "ranges")) return @backingInt(OutputSectionKind.debug_ranges);
            if (std.mem.eql(u8, suffix, "rnglists")) return @backingInt(OutputSectionKind.debug_rnglists);
        },
        's' => {
            if (std.mem.eql(u8, suffix, "str")) return @backingInt(OutputSectionKind.debug_str);
            if (std.mem.eql(u8, suffix, "str_offsets")) return @backingInt(OutputSectionKind.debug_str_offsets);
        },
        't' => {
            if (std.mem.eql(u8, suffix, "tu_index")) return @backingInt(OutputSectionKind.debug_tu_index);
            if (std.mem.eql(u8, suffix, "types")) return @backingInt(OutputSectionKind.debug_types);
        },
        else => {},
    }
    return null;
}

const AllocatedSectionFixture = struct {
    flags: u64,
    section_type: u32,
};

test "ELF output section classifies allocated special names" {
    const alloc = std.elf.SHF_ALLOC;
    const exec = std.elf.SHF_ALLOC | std.elf.SHF_EXECINSTR;
    const writable = std.elf.SHF_ALLOC | std.elf.SHF_WRITE;
    const tls = std.elf.SHF_ALLOC | std.elf.SHF_TLS;
    try std.testing.expectEqual(@backingInt(OutputSectionKind.init), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = exec, .section_type = std.elf.SHT_PROGBITS }, ".init"));
    try std.testing.expectEqual(@backingInt(OutputSectionKind.fini), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = exec, .section_type = std.elf.SHT_PROGBITS }, ".fini"));
    try std.testing.expectEqual(@backingInt(OutputSectionKind.preinit_array), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = writable, .section_type = std.elf.SHT_PREINIT_ARRAY }, ".preinit_array"));
    try std.testing.expectEqual(@backingInt(OutputSectionKind.init_array), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = writable, .section_type = std.elf.SHT_INIT_ARRAY }, ".init_array.100"));
    try std.testing.expectEqual(@backingInt(OutputSectionKind.fini_array), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = writable, .section_type = std.elf.SHT_FINI_ARRAY }, ".fini_array"));
    try std.testing.expectEqual(@backingInt(OutputSectionKind.eh_frame), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = alloc, .section_type = std.elf.SHT_PROGBITS }, ".eh_frame"));
    try std.testing.expectEqual(@backingInt(OutputSectionKind.eh_frame), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = alloc, .section_type = std.elf.SHT_X86_64_UNWIND }, ".gcc_except_table"));
    try std.testing.expectEqual(@backingInt(OutputSectionKind.tdata), indexForAllocatedNamed(AllocatedSectionFixture{ .flags = tls, .section_type = std.elf.SHT_PROGBITS }, ".init_array"));
}
