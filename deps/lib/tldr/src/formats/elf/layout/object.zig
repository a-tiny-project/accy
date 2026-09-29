const frame = @import("frame.zig");
const merge = @import("merge.zig");
const section = @import("section.zig");

pub const ObjectLayout = struct {
    sections: []section.SectionContribution,
    common_symbols: []section.SectionContribution,
    merge_sections: []merge.MergeSectionLayout,
    eh_frame_sections: []frame.EhFrameSectionLayout,

    pub fn deinit(self: *ObjectLayout, allocator: anytype) void {
        if (self.common_symbols.len != 0) allocator.free(self.common_symbols);
        for (self.merge_sections) |*merge_section| merge_section.deinit(allocator);
        if (self.merge_sections.len != 0) allocator.free(self.merge_sections);
        for (self.eh_frame_sections) |*eh_frame_section| eh_frame_section.deinit(allocator);
        if (self.eh_frame_sections.len != 0) allocator.free(self.eh_frame_sections);
    }
};

pub fn mergeSection(object_layout: ObjectLayout, section_index: usize) ?merge.MergeSectionLayout {
    return merge.sectionAt(object_layout.merge_sections, section_index);
}

pub fn ehFrameSection(object_layout: ObjectLayout, section_index: usize) ?frame.EhFrameSectionLayout {
    return frame.sectionAt(object_layout.eh_frame_sections, section_index);
}
