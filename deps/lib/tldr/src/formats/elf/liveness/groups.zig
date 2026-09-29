const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const state = @import("state.zig");

const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const SectionRef = elf.parser.SectionRef;
const State = state.State;

pub fn mark(
    objects: []const ObjectFile,
    group_memberships: *const elf.group.Index,
    live: *State,
    section_ref: SectionRef,
) model.Error!void {
    const object = objects[section_ref.object_index];
    for (group_memberships.groupsForSection(section_ref)) |group_section_index| {
        if (group_section_index >= object.sections.len) return error.MissingSection;
        const group_bytes = try elf.group.bytes(object, object.sections[group_section_index]);
        var member_iterator = elf.group.members(group_bytes);
        while (member_iterator.next()) |member_index| {
            try state.markSection(
                live,
                objects,
                .{
                    .object_index = section_ref.object_index,
                    .section_index = member_index,
                },
            );
        }
    }
}
