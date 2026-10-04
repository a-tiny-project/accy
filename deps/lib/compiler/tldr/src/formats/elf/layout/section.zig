const std = @import("std");
const elf = @import("../root.zig");

const OutputSectionKind = elf.output_section.OutputSectionKind;
const output_section_count = elf.output_section.output_section_count;

pub const OutputSection = struct {
    kind: OutputSectionKind,
    file_size: u64 = 0,
    memory_size: u64 = 0,
    alignment: u64 = 1,
    file_offset: u64 = 0,
    address: u64 = 0,
    reserved_size: u64 = 0,
    section_index: u16 = 0,

    pub fn logicalSize(self: OutputSection) u64 {
        if (self.kind.isAllocated()) return self.memory_size;
        return self.file_size;
    }

    pub fn fileLoadSize(self: OutputSection) u64 {
        if (self.kind.isNoBits()) return 0;
        return self.reserved_size;
    }
};

pub const SectionContribution = struct {
    output_index_plus_one: u8 = 0,
    offset: u64 = 0,
    size: u64 = 0,
    reserved_size: u64 = 0,
    alignment: u64 = 0,

    pub fn init(output_index: usize, offset: u64, size: u64, reserved_size: u64, alignment: u64) SectionContribution {
        std.debug.assert(output_index < output_section_count);
        return .{
            .output_index_plus_one = @intCast(output_index + 1),
            .offset = offset,
            .size = size,
            .reserved_size = reserved_size,
            .alignment = alignment,
        };
    }

    pub inline fn isPresent(self: SectionContribution) bool {
        return self.output_index_plus_one != 0;
    }

    pub inline fn outputIndex(self: SectionContribution) usize {
        std.debug.assert(self.isPresent());
        return @as(usize, self.output_index_plus_one) - 1;
    }
};

pub inline fn contributionAt(contributions: []const SectionContribution, index: usize) ?*const SectionContribution {
    if (index >= contributions.len) return null;
    const contribution = &contributions[index];
    if (!contribution.isPresent()) return null;
    return contribution;
}
