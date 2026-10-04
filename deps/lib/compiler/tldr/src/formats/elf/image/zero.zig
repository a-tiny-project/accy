const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = elf.layout.ObjectLayout;
const OutputSection = elf.layout.OutputSection;
const output_section_count = elf.output_section.output_section_count;
const contributionAt = elf.layout.contributionAt;

pub fn unwrittenFileRanges(
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    metadata_start: u64,
    metadata_end: u64,
    section_header_offset: u64,
) model.Error!void {
    var section_cursors = @as([output_section_count]u64, @splat(0));
    var file_cursor: u64 = 0;
    for (output_sections, 0..) |section, output_index| {
        if (section.logicalSize() == 0) continue;
        try range(image, file_cursor, section.file_offset);
        if (section.kind.isNoBits()) {
            file_cursor = section.file_offset;
            continue;
        }

        const section_end = section.file_offset + section.fileLoadSize();
        section_cursors[output_index] = section.file_offset;
        file_cursor = section_end;
    }

    try contributionGaps(image, objects, layouts, output_sections, &section_cursors);

    for (output_sections, 0..) |section, output_index| {
        if (section.logicalSize() == 0) continue;
        if (section.kind.isNoBits()) continue;
        try range(image, section_cursors[output_index], section.file_offset + section.fileLoadSize());
    }

    try range(image, file_cursor, metadata_start);
    try range(image, metadata_end, section_header_offset);
}

fn contributionGaps(
    image: []u8,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    section_cursors: *[output_section_count]u64,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        const object_layout = layouts[object_index];
        for (object.sections, 0..) |section, section_index| {
            if (section.section_type == std.elf.SHT_NOBITS) continue;
            const contribution = contributionAt(object_layout.sections, section_index) orelse continue;
            const output_index = contribution.outputIndex();
            const output = output_sections[output_index];

            const payload_start = output.file_offset + contribution.offset;
            const payload_end = payload_start + contribution.size;
            const reserve_end = output.file_offset + contribution.offset + contribution.reserved_size;
            try range(image, section_cursors[output_index], payload_start);
            try range(image, payload_end, reserve_end);
            section_cursors[output_index] = reserve_end;
        }
    }
}

pub fn range(image: []u8, start: u64, end: u64) model.Error!void {
    if (end < start) return error.InvalidRange;
    if (start == end) return;
    const image_len: u64 = @intCast(image.len);
    if (end > image_len) return error.InvalidRange;
    const first: usize = @intCast(start);
    const last: usize = @intCast(end);
    @memset(image[first..last], 0);
}
