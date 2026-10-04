const std = @import("std");
const root = @import("../../../../root.zig");
const elf = @import("../../root.zig");
const ehframe = @import("../root.zig");

const model = root.model;
const format = elf.format;
const layout = elf.layout;
const output_section = elf.output_section;
const parser = elf.parser;
const ObjectFile = parser.ObjectFile;
const ObjectLayout = layout.ObjectLayout;
const OutputSection = layout.OutputSection;
const Rela = format.Rela;
const OutputSectionKind = output_section.OutputSectionKind;
const output_section_count = output_section.output_section_count;
const eh_frame_hdr_fixed_size = format.eh_frame_hdr_fixed_size;
const eh_frame_hdr_entry_size = format.eh_frame_hdr_entry_size;
const contributionAt = layout.contributionAt;
const ehFrameSectionLayout = layout.ehFrameSection;
const sectionBytes = format.sectionBytes;
const readU32 = format.readU32;
const record = ehframe.record;
const section = ehframe.section;

pub fn reserve(
    output_sections: *[output_section_count]OutputSection,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    options: model.LinkOptions,
) model.Error!void {
    if (!options.eh_frame_header) return;
    const count = try countEntries(objects, layouts);
    if (count == 0) return;
    const header_size = try size(count);
    var output = &output_sections[@backingInt(OutputSectionKind.eh_frame_hdr)];
    output.file_size = header_size;
    output.memory_size = header_size;
    output.alignment = @max(output.alignment, 4);
}

pub fn size(entry_count: usize) model.Error!u64 {
    const count = std.math.cast(u64, entry_count) orelse return error.InvalidRange;
    if (count > (std.math.maxInt(u64) - eh_frame_hdr_fixed_size) / eh_frame_hdr_entry_size) return error.InvalidRange;
    return eh_frame_hdr_fixed_size + count * eh_frame_hdr_entry_size;
}

fn countEntries(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
) model.Error!usize {
    var count: usize = 0;
    for (objects, 0..) |object, object_index| {
        const object_layout = layouts[object_index];
        for (object.sections, 0..) |input_section, section_index| {
            if (contributionAt(object_layout.sections, section_index) == null) continue;
            if (!section.is(object, section_index, input_section)) continue;
            const bytes = try sectionBytes(object.bytes, input_section);
            if (ehFrameSectionLayout(object_layout, section_index)) |eh_frame_section| {
                var cursor = record.Cursor.init(eh_frame_section.relocations);
                for (eh_frame_section.pieces) |piece| {
                    if (try record.hasHeaderEntry(bytes, piece.input_offset, piece.size, piece.output_offset, &cursor)) count += 1;
                }
                continue;
            }
            try countRawEntries(bytes, object.relocationsForSection(section_index), &count);
        }
    }
    return count;
}

fn countRawEntries(
    bytes: []const u8,
    relocations: []const Rela,
    count: *usize,
) model.Error!void {
    var cursor = record.Cursor.init(relocations);
    var input_offset: u64 = 0;
    while (input_offset < bytes.len) {
        const record_start: usize = @intCast(input_offset);
        if (bytes.len - record_start < 4) return error.InvalidObject;
        const record_length = readU32(bytes, record_start);
        if (record_length == 0xffffffff) return error.UnsupportedFormat;
        const record_size = @as(u64, record_length) + 4;
        if (record_size < 4) return error.InvalidObject;
        if (input_offset > std.math.maxInt(u64) - record_size) return error.InvalidObject;
        const record_end = input_offset + record_size;
        if (record_end > bytes.len) return error.InvalidObject;
        if (try record.hasHeaderEntry(bytes, input_offset, record_size, input_offset, &cursor)) count.* += 1;
        if (record_length == 0) break;
        input_offset = record_end;
    }
}
