const std = @import("std");
const root = @import("../../root.zig");
const format = @import("format.zig");
const layout = @import("layout/root.zig");
const output_section = @import("section.zig");

const model = root.model;
const ehdr_size = format.ehdr_size;
const phdr_size = format.phdr_size;
const Header = format.Header;
const OutputSection = layout.OutputSection;
const OutputSectionKind = output_section.OutputSectionKind;
const writeU32 = format.writeU32;
const writeU64 = format.writeU64;

pub const HeaderFields = struct {
    entry_address: u64,
    program_header_count: u16,
    section_header_offset: u64,
    section_count: u16,
    section_string_table_index: u16,
};

pub const TlsSegment = struct {
    offset: u64,
    address: u64,
    file_size: u64,
    memory_size: u64,
    alignment: u64,
};

pub fn countHeaders(output_sections: []const OutputSection) model.Error!usize {
    const count = 1 +
        @as(usize, @intFromBool(noteSegment(output_sections) != null)) +
        @as(usize, @intFromBool(ehFrameHeaderSegment(output_sections) != null)) +
        countLoadSegments(output_sections) +
        @as(usize, @intFromBool(tlsSegment(output_sections) != null));
    if (count > std.math.maxInt(u16)) return error.TooManyProgramHeaders;
    return count;
}

/// Writes the executable's ELF file header at the start of `image`: type
/// `EXEC`, the entry address, a program header table right after the file
/// header, and the section table fields from `fields`. The image writer calls
/// it once per link with the program header count returned by `countHeaders`.
/// `countHeaders` always counts an entry for the program header table itself,
/// so `program_header_count` is at least one and the header records a program
/// header entry size.
pub fn writeElfHeader(image: []u8, fields: HeaderFields) void {
    const header = Header{
        .type = .EXEC,
        .entry = fields.entry_address,
        .phoff = ehdr_size,
        .phnum = fields.program_header_count,
        .shoff = fields.section_header_offset,
        .shnum = fields.section_count,
        .shstrndx = fields.section_string_table_index,
    };
    header.write(image);
}

pub fn writeProgramHeaders(image: []u8, output_sections: []const OutputSection, options: model.LinkOptions, program_header_count: usize) void {
    const first_load = firstLoadSection(output_sections) orelse return;
    const first_load_base = first_load.address - first_load.file_offset;

    writeU32(image, ehdr_size + 0, std.elf.PT_PHDR);
    writeU32(image, ehdr_size + 4, std.elf.PF_R);
    writeU64(image, ehdr_size + 8, ehdr_size);
    writeU64(image, ehdr_size + 16, first_load_base + ehdr_size);
    writeU64(image, ehdr_size + 24, first_load_base + ehdr_size);
    writeU64(image, ehdr_size + 32, program_header_count * phdr_size);
    writeU64(image, ehdr_size + 40, program_header_count * phdr_size);
    writeU64(image, ehdr_size + 48, 8);

    var index: usize = 1;
    if (noteSegment(output_sections)) |note| {
        const offset = ehdr_size + index * phdr_size;
        writeU32(image, offset + 0, std.elf.PT_NOTE);
        writeU32(image, offset + 4, std.elf.PF_R);
        writeU64(image, offset + 8, note.file_offset);
        writeU64(image, offset + 16, note.address);
        writeU64(image, offset + 24, note.address);
        writeU64(image, offset + 32, note.logicalSize());
        writeU64(image, offset + 40, note.logicalSize());
        writeU64(image, offset + 48, note.alignment);
        index += 1;
    }
    if (ehFrameHeaderSegment(output_sections)) |header| {
        const offset = ehdr_size + index * phdr_size;
        writeU32(image, offset + 0, std.elf.PT_GNU_EH_FRAME);
        writeU32(image, offset + 4, std.elf.PF_R);
        writeU64(image, offset + 8, header.file_offset);
        writeU64(image, offset + 16, header.address);
        writeU64(image, offset + 24, header.address);
        writeU64(image, offset + 32, header.logicalSize());
        writeU64(image, offset + 40, header.logicalSize());
        writeU64(image, offset + 48, header.alignment);
        index += 1;
    }
    var first_load_written = false;
    var run: ?LoadRun = null;
    for (output_sections) |section| {
        if (section.logicalSize() == 0) continue;
        if (!section.kind.isAllocated()) continue;
        if (run) |*current| {
            if (sectionContinuesLoad(current.last_kind, section.kind)) {
                if (!section.kind.isNoBits()) {
                    current.file_end = @max(current.file_end, section.file_offset + section.fileLoadSize());
                }
                current.memory_end = section.address + section.reserved_size;
                current.last_kind = section.kind;
                continue;
            }
            writeLoadHeader(image, ehdr_size + index * phdr_size, current.*, options.page_size);
            index += 1;
            run = null;
        }
        const load_file_offset = if (!first_load_written) 0 else section.file_offset;
        const load_address = if (!first_load_written) first_load_base else section.address;
        run = .{
            .file_offset = load_file_offset,
            .address = load_address,
            .file_end = if (section.kind.isNoBits()) load_file_offset else section.file_offset + section.fileLoadSize(),
            .memory_end = section.address + section.reserved_size,
            .flags = section.kind.programFlags(),
            .last_kind = section.kind,
        };
        first_load_written = true;
    }
    if (run) |current| {
        writeLoadHeader(image, ehdr_size + index * phdr_size, current, options.page_size);
        index += 1;
    }
    if (tlsSegment(output_sections)) |segment| {
        const offset = ehdr_size + index * phdr_size;
        writeU32(image, offset + 0, std.elf.PT_TLS);
        writeU32(image, offset + 4, std.elf.PF_R);
        writeU64(image, offset + 8, segment.offset);
        writeU64(image, offset + 16, segment.address);
        writeU64(image, offset + 24, segment.address);
        writeU64(image, offset + 32, segment.file_size);
        writeU64(image, offset + 40, segment.memory_size);
        writeU64(image, offset + 48, segment.alignment);
    }
}

pub fn firstLoadSection(output_sections: []const OutputSection) ?OutputSection {
    for (output_sections) |section| {
        if (section.logicalSize() == 0) continue;
        if (section.kind.isAllocated()) return section;
    }
    return null;
}

pub fn tlsSegment(output_sections: []const OutputSection) ?TlsSegment {
    var found = false;
    var start_offset: u64 = 0;
    var start_address: u64 = 0;
    var file_end: u64 = 0;
    var memory_end: u64 = 0;
    var alignment: u64 = 1;

    for (output_sections) |section| {
        if (!section.kind.isTls()) continue;
        if (section.logicalSize() == 0) continue;
        if (!found) {
            start_offset = section.file_offset;
            start_address = section.address;
            file_end = section.file_offset;
            memory_end = section.address;
            found = true;
        }
        alignment = @max(alignment, @max(section.alignment, 1));
        if (!section.kind.isNoBits()) file_end = @max(file_end, section.file_offset + section.fileLoadSize());
        memory_end = @max(memory_end, section.address + section.reserved_size);
    }

    if (!found) return null;
    return .{
        .offset = start_offset,
        .address = start_address,
        .file_size = file_end - start_offset,
        .memory_size = memory_end - start_address,
        .alignment = alignment,
    };
}

pub fn tlsMemorySize(output_sections: []const OutputSection) u64 {
    const segment = tlsSegment(output_sections) orelse return 0;
    return segment.memory_size;
}

const LoadRun = struct {
    file_offset: u64,
    address: u64,
    file_end: u64,
    memory_end: u64,
    flags: u32,
    last_kind: OutputSectionKind,
};

pub fn sectionContinuesLoad(previous: OutputSectionKind, current: OutputSectionKind) bool {
    return current.isTls() and previous.isTls();
}

fn writeLoadHeader(image: []u8, offset: usize, run: LoadRun, page_size: u64) void {
    writeU32(image, offset + 0, std.elf.PT_LOAD);
    writeU32(image, offset + 4, run.flags);
    writeU64(image, offset + 8, run.file_offset);
    writeU64(image, offset + 16, run.address);
    writeU64(image, offset + 24, run.address);
    writeU64(image, offset + 32, run.file_end - run.file_offset);
    writeU64(image, offset + 40, run.memory_end - run.address);
    writeU64(image, offset + 48, page_size);
}

fn countLoadSegments(output_sections: []const OutputSection) usize {
    var count: usize = 0;
    var previous_kind: ?OutputSectionKind = null;
    for (output_sections) |section| {
        if (section.logicalSize() == 0 or !section.kind.isAllocated()) continue;
        if (previous_kind == null or !sectionContinuesLoad(previous_kind.?, section.kind)) count += 1;
        previous_kind = section.kind;
    }
    return count;
}

fn noteSegment(output_sections: []const OutputSection) ?OutputSection {
    const section = output_sections[@backingInt(OutputSectionKind.build_id_note)];
    if (section.logicalSize() == 0) return null;
    return section;
}

fn ehFrameHeaderSegment(output_sections: []const OutputSection) ?OutputSection {
    const section = output_sections[@backingInt(OutputSectionKind.eh_frame_hdr)];
    if (section.logicalSize() == 0) return null;
    return section;
}
