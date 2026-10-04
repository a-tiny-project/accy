const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const record = @import("record.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const ObjectFile = elf.parser.ObjectFile;
const SectionRef = elf.parser.SectionRef;

const Range = struct {
    start: usize = 0,
    count: usize = 0,
};

const Memberships = struct {
    ranges: []Range = &.{},
    group_sections: []usize = &.{},

    fn init(allocator: Allocator, object: ObjectFile) model.Error!Memberships {
        const ranges = try allocator.alloc(Range, object.sections.len);
        errdefer allocator.free(ranges);
        for (ranges) |*range| range.* = .{};

        for (object.sections) |section| {
            if (section.section_type != std.elf.SHT_GROUP) continue;
            const group_bytes = try record.bytes(object, section);
            var member_iterator = record.members(group_bytes);
            while (member_iterator.next()) |member_index| {
                if (member_index >= object.sections.len) continue;
                if (ranges[member_index].count == std.math.maxInt(usize)) return error.InvalidObject;
                ranges[member_index].count += 1;
            }
        }

        var total_group_references: usize = 0;
        for (ranges) |*range| {
            const group_count = range.count;
            range.start = total_group_references;
            range.count = 0;
            if (group_count > std.math.maxInt(usize) - total_group_references) return error.InvalidObject;
            total_group_references += group_count;
        }

        const group_sections = try allocator.alloc(usize, total_group_references);
        errdefer allocator.free(group_sections);

        for (object.sections, 0..) |section, group_section_index| {
            if (section.section_type != std.elf.SHT_GROUP) continue;
            const group_bytes = try record.bytes(object, section);
            var member_iterator = record.members(group_bytes);
            while (member_iterator.next()) |member_index| {
                if (member_index >= object.sections.len) continue;
                const range = &ranges[member_index];
                group_sections[range.start + range.count] = group_section_index;
                range.count += 1;
            }
        }

        return .{
            .ranges = ranges,
            .group_sections = group_sections,
        };
    }

    fn deinit(self: *Memberships, allocator: Allocator) void {
        if (self.ranges.len != 0) allocator.free(self.ranges);
        if (self.group_sections.len != 0) allocator.free(self.group_sections);
    }

    fn groupsForSection(self: Memberships, section_index: usize) []const usize {
        if (section_index >= self.ranges.len) return &.{};
        const range = self.ranges[section_index];
        return self.group_sections[range.start..][0..range.count];
    }
};

pub const Index = struct {
    objects: []Memberships = &.{},

    pub fn init(allocator: Allocator, objects: []const ObjectFile) model.Error!Index {
        const object_memberships = try allocator.alloc(Memberships, objects.len);
        var initialized_count: usize = 0;
        errdefer {
            for (object_memberships[0..initialized_count]) |*memberships| memberships.deinit(allocator);
            allocator.free(object_memberships);
        }

        for (objects, 0..) |object, object_index| {
            object_memberships[object_index] = try Memberships.init(allocator, object);
            initialized_count += 1;
        }

        return .{ .objects = object_memberships };
    }

    pub fn deinit(self: *Index, allocator: Allocator) void {
        for (self.objects) |*memberships| memberships.deinit(allocator);
        if (self.objects.len != 0) allocator.free(self.objects);
    }

    pub fn groupsForSection(self: Index, section_ref: SectionRef) []const usize {
        if (section_ref.object_index >= self.objects.len) return &.{};
        return self.objects[section_ref.object_index].groupsForSection(section_ref.section_index);
    }
};
