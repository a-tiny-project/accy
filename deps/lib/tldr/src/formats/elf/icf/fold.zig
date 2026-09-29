const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const hash = @import("hash.zig");
const match = @import("match.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const SectionRef = elf.parser.SectionRef;
const ensureFoldedSections = elf.section_state.ensureFoldedSections;
const foldedSection = elf.section_state.foldedSection;
const sectionDiscarded = elf.section_state.sectionDiscarded;

const ClassMap = std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(SectionRef));

pub fn fold(
    allocator: Allocator,
    objects: []ObjectFile,
) model.Error!void {
    var classes: ClassMap = .{};
    defer {
        var values = classes.valueIterator();
        while (values.next()) |sections| sections.deinit(allocator);
        classes.deinit(allocator);
    }

    for (objects, 0..) |*object, object_index| {
        const folded_sections = try ensureFoldedSections(allocator, object);
        for (object.sections, 0..) |_, section_index| {
            if (!sectionEligible(object.*, section_index)) continue;

            const section_hash = try hash.section(object.*, section_index);
            const gop = try classes.getOrPut(allocator, section_hash);
            if (!gop.found_existing) gop.value_ptr.* = .empty;

            var folded = false;
            for (gop.value_ptr.items) |candidate_ref| {
                const candidate = objects[candidate_ref.object_index];
                if (try match.sections(object.*, section_index, candidate, candidate_ref.section_index)) {
                    folded_sections[section_index] = candidate_ref;
                    folded = true;
                    break;
                }
            }
            if (!folded) {
                try gop.value_ptr.append(allocator, .{
                    .object_index = object_index,
                    .section_index = section_index,
                });
            }
        }
    }
}

fn sectionEligible(object: ObjectFile, section_index: usize) bool {
    if (sectionDiscarded(object, section_index)) return false;
    if (foldedSection(object, section_index) != null) return false;
    const input_section = object.sections[section_index];
    if (input_section.size == 0) return false;
    if (input_section.section_type != std.elf.SHT_PROGBITS) return false;
    if ((input_section.flags & std.elf.SHF_ALLOC) == 0) return false;
    if ((input_section.flags & std.elf.SHF_EXECINSTR) == 0) return false;
    if ((input_section.flags & std.elf.SHF_WRITE) != 0) return false;
    return true;
}
