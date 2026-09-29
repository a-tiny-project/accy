const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const state = @import("state.zig");

const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const SectionHeader = elf.format.SectionHeader;
const State = state.State;
const foldedSection = elf.section_state.foldedSection;
const sectionDiscarded = elf.section_state.sectionDiscarded;
const sectionIsAllocated = elf.format.sectionIsAllocated;
const sectionNameOrEmpty = elf.parser.sectionNameOrEmpty;

pub fn markReserved(
    objects: []const ObjectFile,
    live: *State,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        for (object.sections, 0..) |section, section_index| {
            if (!sectionIsReservedRoot(object, section_index, section)) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;
            try state.markSection(
                live,
                objects,
                .{
                    .object_index = object_index,
                    .section_index = @intCast(section_index),
                },
            );
        }
    }
}

pub fn markRetained(
    objects: []const ObjectFile,
    live: *State,
) model.Error!void {
    for (objects, 0..) |object, object_index| {
        for (object.sections, 0..) |section, section_index| {
            if (!sectionIsAllocated(section)) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;
            if ((section.flags & std.elf.SHF_GNU_RETAIN) == 0) continue;
            try state.markSection(
                live,
                objects,
                .{
                    .object_index = object_index,
                    .section_index = @intCast(section_index),
                },
            );
        }
    }
}

fn sectionIsReservedRoot(object: ObjectFile, section_index: usize, section: SectionHeader) bool {
    if (!sectionIsAllocated(section)) return false;
    switch (section.section_type) {
        std.elf.SHT_PREINIT_ARRAY,
        std.elf.SHT_INIT_ARRAY,
        std.elf.SHT_FINI_ARRAY,
        => return true,
        std.elf.SHT_NOTE => return (section.flags & std.elf.SHF_GROUP) == 0,
        else => {},
    }

    const name = sectionNameOrEmpty(object, section_index);
    return std.mem.eql(u8, name, ".init") or
        std.mem.eql(u8, name, ".fini") or
        std.mem.eql(u8, name, ".jcr") or
        std.mem.startsWith(u8, name, ".init_array") or
        std.mem.startsWith(u8, name, ".ctors") or
        std.mem.startsWith(u8, name, ".dtors");
}
