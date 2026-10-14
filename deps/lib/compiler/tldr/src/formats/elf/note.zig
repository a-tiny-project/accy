const std = @import("std");
const root = @import("../../root.zig");
const format = @import("format.zig");
const layout = @import("layout/root.zig");
const output_section = @import("section.zig");

const model = root.model;
const OutputSection = layout.OutputSection;
const OutputSectionKind = output_section.OutputSectionKind;
const SectionHeader = format.SectionHeader;
const output_section_count = output_section.output_section_count;
const requireRange = format.requireRange;
const writeU32 = format.writeU32;
const writeU64 = format.writeU64;

pub const section_name = ".note.gnu.build-id";
pub const desc_offset = format.build_id_note_desc_offset;
pub const fast_desc_size = format.build_id_fast_desc_size;
pub const sha1_desc_size = format.build_id_sha1_desc_size;

pub fn reserveBuildId(
    output_sections: *[output_section_count]OutputSection,
    options: model.LinkOptions,
) void {
    if (options.build_id == .none) return;
    var output = &output_sections[@backingInt(OutputSectionKind.build_id_note)];
    const note_size = size(options.build_id);
    output.file_size = note_size;
    output.memory_size = note_size;
    output.alignment = @max(output.alignment, 4);
}

pub fn writeBuildIdHeader(image: []u8, offset: u64) model.Error!void {
    try requireRange(image, offset, desc_offset);
    const start: usize = @intCast(offset);
    writeU32(image, start + 0, 4);
    writeU32(image, start + 8, std.elf.NT_GNU_BUILD_ID);
    image[start + 12] = 'G';
    image[start + 13] = 'N';
    image[start + 14] = 'U';
    image[start + 15] = 0;
}

pub fn finishBuildId(
    image: []u8,
    output_sections: []const OutputSection,
    options: model.LinkOptions,
) model.Error!void {
    if (options.build_id == .none) return;
    const section = output_sections[@backingInt(OutputSectionKind.build_id_note)];
    const note_size = size(options.build_id);
    try requireRange(image, section.file_offset, note_size);
    try finishBuildIdAt(image, section.file_offset, options.build_id);
}

pub fn finishBuildIdSection(
    image: []u8,
    section: SectionHeader,
    mode: model.BuildIdMode,
) model.Error!void {
    if (mode == .none) return;
    if (section.section_type != std.elf.SHT_NOTE) return error.InvalidElfHeader;
    if (section.size != size(mode)) return error.InvalidElfHeader;
    try requireRange(image, section.offset, section.size);
    try finishBuildIdAt(image, section.offset, mode);
}

fn finishBuildIdAt(
    image: []u8,
    file_offset: u64,
    mode: model.BuildIdMode,
) model.Error!void {
    const desc_size = descSize(mode);
    const start: usize = @intCast(file_offset);
    const desc_start = start + desc_offset;
    writeU32(image, start + 4, @intCast(desc_size));
    @memset(image[desc_start..][0..desc_size], 0);
    switch (mode) {
        .none => unreachable,
        .fast => {
            var hasher = std.hash.XxHash64.init(0);
            hasher.update(image);
            writeU64(image, desc_start, hasher.final());
        },
        .sha1 => {
            var digest: [sha1_desc_size]u8 = undefined;
            std.crypto.hash.Sha1.hash(image, &digest, .{});
            @memcpy(image[desc_start..][0..sha1_desc_size], &digest);
        },
    }
}

pub fn patchGenerated(
    image: []u8,
    candidate_image: []const u8,
    section: SectionHeader,
    candidate_section: SectionHeader,
) model.Error!void {
    if (section.offset != candidate_section.offset) return error.InvalidElfHeader;
    if (section.size != candidate_section.size) return error.InvalidElfHeader;
    if (section.section_type != std.elf.SHT_NOTE or candidate_section.section_type != std.elf.SHT_NOTE) return error.InvalidElfHeader;
    try requireRange(image, section.offset, section.size);
    try requireRange(candidate_image, candidate_section.offset, candidate_section.size);
    const start: usize = @intCast(section.offset);
    const note_size: usize = @intCast(section.size);
    @memcpy(image[start..][0..note_size], candidate_image[start..][0..note_size]);
}

pub fn size(mode: model.BuildIdMode) u64 {
    return desc_offset + descSize(mode);
}

fn descSize(mode: model.BuildIdMode) u64 {
    return switch (mode) {
        .none => 0,
        .fast => fast_desc_size,
        .sha1 => sha1_desc_size,
    };
}
