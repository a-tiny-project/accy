const elf = @import("../root.zig");

const Rela = elf.format.Rela;

pub const EhFramePieceLayout = struct {
    input_offset: u64 = 0,
    size: u64 = 0,
    output_offset: u64 = 0,
    patch_cie_pointer: bool = false,
    cie_pointer: u32 = 0,
};

pub const EhFrameCieLayout = struct {
    input_offset: u64 = 0,
    output_offset: u64 = 0,
};

pub const EhFrameSectionLayout = struct {
    present: bool = false,
    pieces: []EhFramePieceLayout = &.{},
    relocations: []Rela = &.{},

    pub fn deinit(self: *EhFrameSectionLayout, allocator: anytype) void {
        if (self.pieces.len != 0) allocator.free(self.pieces);
        if (self.relocations.len != 0) allocator.free(self.relocations);
    }

    pub fn isPresent(self: EhFrameSectionLayout) bool {
        return self.present;
    }
};

pub fn sectionAt(sections: []const EhFrameSectionLayout, section_index: usize) ?EhFrameSectionLayout {
    if (section_index >= sections.len) return null;
    const eh_frame_section = sections[section_index];
    if (!eh_frame_section.isPresent()) return null;
    return eh_frame_section;
}
