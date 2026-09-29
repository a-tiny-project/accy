const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const OutputSection = elf.layout.OutputSection;
const SectionContribution = elf.layout.SectionContribution;
const MergePieceLayout = elf.layout.MergePieceLayout;
const MergeSectionLayout = elf.layout.MergeSectionLayout;
const SectionHeader = elf.format.SectionHeader;
const output_section_count = elf.output_section.output_section_count;
const hashU64 = elf.format.hashU64;
const sectionBytes = elf.format.sectionBytes;
const validateAlignment = elf.format.validateAlignment;
const alignForwardU64 = elf.format.alignForwardU64;
const outputIndexForAlloc = elf.output_section.indexForAllocated;
const contributionReserveSize = elf.layout.contributionReserveSize;

const Key = struct {
    section_type: u32,
    output_index: u8,
    entry_size: u64,
    alignment: u64,
    bytes: []const u8,

    const Context = struct {
        pub fn hash(_: Context, key: Key) u64 {
            var value = hashU64(0x4d6f3a27c994f64b, key.section_type);
            value = hashU64(value, key.output_index);
            value = hashU64(value, key.entry_size);
            value = hashU64(value, key.alignment);
            return std.hash.Wyhash.hash(value, key.bytes);
        }

        pub fn eql(_: Context, left: Key, right: Key) bool {
            return left.section_type == right.section_type and
                left.output_index == right.output_index and
                left.entry_size == right.entry_size and
                left.alignment == right.alignment and
                std.mem.eql(u8, left.bytes, right.bytes);
        }
    };
};

const Target = struct {
    contribution: SectionContribution,
    intra_offset: u64 = 0,
};

const context = Key.Context{};
const Map = std.HashMapUnmanaged(
    Key,
    Target,
    Key.Context,
    80,
);

pub const Fixed = struct {
    pieces: Map = .empty,

    pub fn deinit(self: *Fixed, allocator: Allocator) void {
        self.pieces.deinit(allocator);
    }

    pub fn collect(
        self: *Fixed,
        allocator: Allocator,
        object: ObjectFile,
        section: SectionHeader,
        section_index: usize,
        output_sections: *[output_section_count]OutputSection,
        merge_sections: []MergeSectionLayout,
        options: model.LinkOptions,
    ) model.Error!void {
        if (section.size % section.entry_size != 0) return error.InvalidObject;
        if (object.relocationsForSection(section_index).len != 0) return error.UnsupportedRelocation;

        try validateAlignment(section.alignment);
        const entry_size: usize = @intCast(section.entry_size);
        const entry_count: usize = @intCast(section.size / section.entry_size);
        const layouts = try allocator.alloc(MergePieceLayout, entry_count);
        errdefer allocator.free(layouts);

        const output_index = outputIndexForAlloc(section);
        const output_index_u8: u8 = @intCast(output_index);
        var output = &output_sections[output_index];
        const alignment = @max(section.alignment, 1);
        output.alignment = @max(output.alignment, alignment);

        const bytes = try sectionBytes(object.bytes, section);
        for (layouts, 0..) |*piece_layout, index| {
            const start = index * entry_size;
            const piece_bytes = bytes[start..][0..entry_size];
            piece_layout.* = .{
                .input_offset = @intCast(start),
                .size = section.entry_size,
            };
            const key: Key = .{
                .section_type = section.section_type,
                .output_index = output_index_u8,
                .entry_size = section.entry_size,
                .alignment = alignment,
                .bytes = piece_bytes,
            };
            if (self.pieces.getContext(key, context)) |existing| {
                piece_layout.contribution = existing.contribution;
                piece_layout.output_intra_offset = existing.intra_offset;
                continue;
            }

            const aligned_offset = alignForwardU64(output.file_size, alignment);
            const reserved_size = contributionReserveSize(section.entry_size, alignment, options);
            const contribution = SectionContribution.init(
                output_index,
                aligned_offset,
                section.entry_size,
                reserved_size,
                alignment,
            );
            try self.pieces.putContext(allocator, key, .{ .contribution = contribution }, context);
            piece_layout.contribution = contribution;
            output.file_size = aligned_offset + reserved_size;
            output.memory_size = output.file_size;
        }

        merge_sections[section_index] = .{
            .pieces = layouts,
            .fixed_piece_size = section.entry_size,
        };
    }
};
