const std = @import("std");
const root = @import("../../root.zig");
const format = @import("format.zig");
const build_id_note = @import("note.zig");

const incremental = root.incremental;
const model = root.model;
const ehdr_size = format.ehdr_size;
const phdr_size = format.phdr_size;
const shdr_size = format.shdr_size;
const SectionHeader = format.SectionHeader;
const requireRange = format.requireRange;
const sectionBytes = format.sectionBytes;
const stringFromTable = format.stringFromTable;
const readSectionHeader = format.readSectionHeader;
const readU16 = format.readU16;
const readU32 = format.readU32;
const readU64 = format.readU64;

pub const ProgramHeader = struct {
    flags: u32,
    file_offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
};

const Layout = struct {
    start: u64,
    section_header_offset: u64,
    section_count: u16,
    string_section_index: u16,
};

pub fn patchIncrementalMetadata(image: []u8, candidate_image: []const u8) model.Error!void {
    if (image.len != candidate_image.len) return error.InvalidRange;
    const image_metadata = try metadataLayout(image);
    const candidate_metadata = try metadataLayout(candidate_image);
    if (image_metadata.start != candidate_metadata.start) return error.InvalidElfHeader;
    if (image_metadata.section_header_offset != candidate_metadata.section_header_offset) return error.InvalidElfHeader;
    if (image_metadata.section_count != candidate_metadata.section_count) return error.InvalidElfHeader;
    if (image_metadata.string_section_index != candidate_metadata.string_section_index) return error.InvalidElfHeader;
    const start: usize = @intCast(image_metadata.start);
    @memcpy(image[start..], candidate_image[start..]);
    try patchGeneratedBuildIdNote(image, candidate_image);
}

pub fn finishIncrementalMetadata(image: []u8, options: model.LinkOptions) model.Error!void {
    try finishGeneratedBuildIdNote(image, options.build_id);
}

pub const MetadataRange = struct {
    offset: usize,
    len: usize,
};

pub fn buildIdNoteRange(image: []const u8) model.Error!?MetadataRange {
    const note = linkedSectionByName(image, build_id_note.section_name) catch |err| switch (err) {
        error.MissingSection => return null,
        else => return err,
    };
    return .{
        .offset = std.math.cast(usize, note.offset) orelse return error.InvalidRange,
        .len = std.math.cast(usize, note.size) orelse return error.InvalidRange,
    };
}

pub fn patchIncrementalMetadataRange(image: []const u8) model.Error!MetadataRange {
    const image_metadata = try metadataLayout(image);
    const start = std.math.cast(usize, image_metadata.start) orelse return error.InvalidRange;
    return .{ .offset = start, .len = image.len - start };
}

fn patchGeneratedBuildIdNote(image: []u8, candidate_image: []const u8) model.Error!void {
    const note = linkedSectionByName(image, build_id_note.section_name) catch |err| switch (err) {
        error.MissingSection => return,
        else => return err,
    };
    const candidate_note = try linkedSectionByName(candidate_image, build_id_note.section_name);
    try build_id_note.patchGenerated(image, candidate_image, note, candidate_note);
}

fn finishGeneratedBuildIdNote(image: []u8, mode: model.BuildIdMode) model.Error!void {
    if (mode == .none) return;
    const note = try linkedSectionByName(image, build_id_note.section_name);
    try build_id_note.finishBuildIdSection(image, note, mode);
}

pub fn manifestSection(manifest: incremental.Manifest, name: []const u8) ?incremental.SectionRecord {
    for (manifest.sections) |section| {
        if (std.mem.eql(u8, manifest.string(section.name_id), name)) return section;
    }
    return null;
}

pub fn manifestContribution(
    manifest: incremental.Manifest,
    input_name: []const u8,
    kind: incremental.ContributionKind,
    name: []const u8,
    ordinal: u32,
) ?incremental.ContributionRecord {
    for (manifest.contributions) |contribution| {
        if (!std.mem.eql(u8, manifest.string(contribution.input_name_id), input_name)) continue;
        if (contribution.kind != kind) continue;
        if (contribution.ordinal != ordinal) continue;
        if (std.mem.eql(u8, manifest.string(contribution.name_id), name)) return contribution;
    }
    return null;
}

pub fn manifestDiscardedContribution(
    manifest: incremental.Manifest,
    input_name: []const u8,
    name: []const u8,
    ordinal: u32,
) ?incremental.DiscardedContributionRecord {
    for (manifest.discarded_contributions) |contribution| {
        if (!std.mem.eql(u8, manifest.string(contribution.input_name_id), input_name)) continue;
        if (contribution.ordinal != ordinal) continue;
        if (std.mem.eql(u8, manifest.string(contribution.name_id), name)) return contribution;
    }
    return null;
}

fn metadataLayout(image: []const u8) model.Error!Layout {
    if (image.len < ehdr_size) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, image[0..4], std.elf.MAGIC)) return error.InvalidElfHeader;
    const shoff = readU64(image, 40);
    const shentsize = readU16(image, 58);
    const shnum = readU16(image, 60);
    const shstrndx = readU16(image, 62);
    if (shentsize != shdr_size or shnum == 0 or shstrndx >= shnum) return error.InvalidElfHeader;
    try requireRange(image, shoff, @as(u64, shnum) * shdr_size);

    const shstrtab_header = readSectionHeader(image, shoff + @as(u64, shstrndx) * shdr_size);
    const shstrtab = try sectionBytes(image, shstrtab_header);
    var start = shoff;
    var found = false;
    for (0..shnum) |index| {
        const section = readSectionHeader(image, shoff + @as(u64, @intCast(index)) * shdr_size);
        const section_name = try stringFromTable(shstrtab, section.name_offset);
        if (!std.mem.eql(u8, section_name, ".symtab") and
            !std.mem.eql(u8, section_name, ".strtab") and
            !std.mem.eql(u8, section_name, ".shstrtab"))
        {
            continue;
        }
        start = @min(start, section.offset);
        found = true;
    }
    if (!found) return error.MissingSection;
    return .{
        .start = start,
        .section_header_offset = shoff,
        .section_count = shnum,
        .string_section_index = shstrndx,
    };
}

pub fn linkedSectionByName(image: []const u8, name: []const u8) model.Error!SectionHeader {
    const shoff = readU64(image, 40);
    const shnum = readU16(image, 60);
    const shstrndx = readU16(image, 62);
    if (shstrndx >= shnum) return error.InvalidElfHeader;
    try requireRange(image, shoff, @as(u64, shnum) * shdr_size);

    const shstrtab_header = readSectionHeader(image, shoff + @as(u64, shstrndx) * shdr_size);
    const shstrtab = try sectionBytes(image, shstrtab_header);
    for (0..shnum) |index| {
        const section = readSectionHeader(image, shoff + @as(u64, @intCast(index)) * shdr_size);
        const section_name = try stringFromTable(shstrtab, section.name_offset);
        if (std.mem.eql(u8, section_name, name)) return section;
    }
    return error.MissingSection;
}

pub fn loadProgramHeaderByAddress(image: []const u8, virtual_address: u64) model.Error!ProgramHeader {
    return loadProgramHeaderByAddressAndType(image, virtual_address, @backingInt(std.elf.PT.LOAD));
}

pub fn programHeaderByType(image: []const u8, program_type: u32) model.Error!ProgramHeader {
    return loadProgramHeaderByAddressAndType(image, null, program_type);
}

fn loadProgramHeaderByAddressAndType(image: []const u8, virtual_address: ?u64, program_type: u32) model.Error!ProgramHeader {
    const phoff = readU64(image, 32);
    const phentsize = readU16(image, 54);
    const phnum = readU16(image, 56);
    if (phentsize != phdr_size) return error.InvalidElfHeader;
    try requireRange(image, phoff, @as(u64, phnum) * phdr_size);

    for (0..phnum) |index| {
        const offset = phoff + @as(u64, @intCast(index)) * phdr_size;
        if (readU32(image, @intCast(offset)) != program_type) continue;
        const header_virtual_address = readU64(image, @intCast(offset + 16));
        const memory_size = readU64(image, @intCast(offset + 40));
        if (virtual_address) |address| {
            if (address < header_virtual_address) continue;
            if (address - header_virtual_address >= memory_size) continue;
        }
        return .{
            .flags = readU32(image, @intCast(offset + 4)),
            .file_offset = readU64(image, @intCast(offset + 8)),
            .virtual_address = header_virtual_address,
            .file_size = readU64(image, @intCast(offset + 32)),
            .memory_size = memory_size,
        };
    }
    return error.MissingSection;
}
