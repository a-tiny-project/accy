const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const SectionRef = elf.parser.SectionRef;
const ensureDiscardedSections = elf.section_state.ensureDiscardedSections;
const sectionDiscarded = elf.section_state.sectionDiscarded;

pub const State = struct {
    live_sections: [][]bool,
    live_count: usize,
    pending: std.ArrayListUnmanaged(SectionRef),
};

pub fn init(allocator: Allocator, objects: []const ObjectFile) model.Error!State {
    var live_sections = try allocator.alloc([]bool, objects.len);
    var live_count: usize = 0;
    errdefer {
        for (live_sections[0..live_count]) |sections| allocator.free(sections);
        allocator.free(live_sections);
    }

    for (objects, 0..) |object, object_index| {
        live_sections[object_index] = try allocator.alloc(bool, object.sections.len);
        @memset(live_sections[object_index], false);
        live_count += 1;
    }

    var pending: std.ArrayListUnmanaged(SectionRef) = .empty;
    errdefer pending.deinit(allocator);
    try pending.ensureTotalCapacity(allocator, try countSections(objects));

    return .{
        .live_sections = live_sections,
        .live_count = live_count,
        .pending = pending,
    };
}

pub fn deinit(live: *State, allocator: Allocator) void {
    live.pending.deinit(allocator);
    for (live.live_sections[0..live.live_count]) |sections| allocator.free(sections);
    allocator.free(live.live_sections);
    live.* = .{
        .live_sections = &.{},
        .live_count = 0,
        .pending = .empty,
    };
}

pub fn markSection(
    live: *State,
    objects: []const ObjectFile,
    section_ref: SectionRef,
) model.Error!void {
    if (section_ref.object_index >= objects.len) return error.InvalidObject;
    const object = objects[section_ref.object_index];
    if (section_ref.section_index >= object.sections.len) return error.MissingSection;
    if (sectionDiscarded(object, section_ref.section_index)) return;
    if (live.live_sections[section_ref.object_index][section_ref.section_index]) return;

    live.live_sections[section_ref.object_index][section_ref.section_index] = true;
    live.pending.appendAssumeCapacity(section_ref);
}

pub fn discardUnmarked(
    live: *State,
    allocator: Allocator,
    objects: []ObjectFile,
) model.Error!void {
    for (objects, 0..) |*object, object_index| {
        const discarded_sections = try ensureDiscardedSections(allocator, object);
        for (object.sections, 0..) |section, section_index| {
            if (discarded_sections[section_index]) continue;
            if ((section.flags & std.elf.SHF_ALLOC) == 0) continue;
            if (!live.live_sections[object_index][section_index]) {
                discarded_sections[section_index] = true;
            }
        }
    }
}

fn countSections(objects: []const ObjectFile) model.Error!usize {
    var total: usize = 0;
    for (objects) |object| {
        if (object.sections.len > std.math.maxInt(usize) - total) return error.InvalidObject;
        total += object.sections.len;
    }
    return total;
}
