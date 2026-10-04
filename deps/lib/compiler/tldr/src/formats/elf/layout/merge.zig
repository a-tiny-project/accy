const section = @import("section.zig");

const SectionContribution = section.SectionContribution;

pub const MergePieceLayout = struct {
    input_offset: u64 = 0,
    size: u64 = 0,
    contribution: SectionContribution = .{},
    output_intra_offset: u64 = 0,
};

pub const MergeSectionLayout = struct {
    pieces: []MergePieceLayout = &.{},
    fixed_piece_size: u64 = 0,

    pub fn deinit(self: *MergeSectionLayout, allocator: anytype) void {
        if (self.pieces.len != 0) allocator.free(self.pieces);
    }

    pub fn isPresent(self: MergeSectionLayout) bool {
        return self.pieces.len != 0;
    }
};

pub fn sectionAt(sections: []const MergeSectionLayout, section_index: usize) ?MergeSectionLayout {
    if (section_index >= sections.len) return null;
    const merge_section = sections[section_index];
    if (!merge_section.isPresent()) return null;
    return merge_section;
}
