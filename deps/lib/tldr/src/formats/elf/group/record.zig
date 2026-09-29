const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const SectionHeader = elf.format.SectionHeader;
const group_word_size = elf.format.group_word_size;
const readU32 = elf.format.readU32;
const sectionBytes = elf.format.sectionBytes;

pub const Members = struct {
    group_bytes: []const u8,
    index: usize = 1,

    pub fn next(self: *Members) ?u32 {
        if (self.index >= count(self.group_bytes)) return null;
        defer self.index += 1;
        return word(self.group_bytes, self.index);
    }
};

pub fn bytes(object: ObjectFile, section: SectionHeader) model.Error![]const u8 {
    if (section.entry_size != group_word_size or section.size % group_word_size != 0) {
        return error.InvalidObject;
    }
    return sectionBytes(object.bytes, section);
}

pub fn count(group_bytes: []const u8) usize {
    return group_bytes.len / group_word_size;
}

pub fn members(group_bytes: []const u8) Members {
    return .{ .group_bytes = group_bytes };
}

pub fn word(group_bytes: []const u8, index: usize) u32 {
    return readU32(group_bytes, index * group_word_size);
}
