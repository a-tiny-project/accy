const std = @import("std");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const ObjectFile = elf.parser.ObjectFile;
const SectionHeader = elf.format.SectionHeader;

pub fn count(bytes: []const u8) usize {
    var piece_count: usize = 0;
    for (bytes) |byte| {
        if (byte == 0) piece_count += 1;
    }
    return piece_count;
}

pub const Index = struct {
    built: bool = false,
    sections: []SectionStarts = &.{},

    pub fn deinit(self: *Index, allocator: Allocator) void {
        for (self.sections) |section| allocator.free(section.starts);
        allocator.free(self.sections);
        self.* = .{};
    }

    pub fn forSection(
        self: *Index,
        allocator: Allocator,
        object: ObjectFile,
        section_index: usize,
    ) Allocator.Error![]const u64 {
        if (!self.built) try self.build(allocator, object);
        for (self.sections) |section| {
            if (section.section_index == section_index) return section.starts;
        }
        return &.{};
    }

    fn build(self: *Index, allocator: Allocator, object: ObjectFile) Allocator.Error!void {
        var builders = std.ArrayListUnmanaged(SectionBuilder).empty;
        defer builders.deinit(allocator);
        errdefer deinitBuilders(allocator, builders.items);

        for (object.symbols) |symbol| {
            if (symbol.section_index >= object.sections.len) continue;
            const section_index: usize = symbol.section_index;
            const section = object.sections[section_index];
            if (!mergeStringSectionWithoutRelocations(object, section, section_index)) continue;
            if (!symbol.isGlobalDefinition()) continue;
            const starts = try builderForSection(allocator, &builders, section_index);
            try starts.append(allocator, symbol.value);
        }

        const sections = try allocator.alloc(SectionStarts, builders.items.len);
        var initialized_sections: usize = 0;
        errdefer {
            for (sections[0..initialized_sections]) |section| allocator.free(section.starts);
            allocator.free(sections);
        }
        for (builders.items, sections) |*builder, *section| {
            std.mem.sort(u64, builder.starts.items, {}, std.sort.asc(u64));
            section.* = .{
                .section_index = builder.section_index,
                .starts = try builder.starts.toOwnedSlice(allocator),
            };
            initialized_sections += 1;
        }
        self.sections = sections;
        self.built = true;
    }
};

pub fn shouldIndex(object: ObjectFile) bool {
    var section_count: usize = 0;
    for (object.sections, 0..) |section, section_index| {
        if (!mergeStringSectionWithoutRelocations(object, section, section_index)) continue;
        section_count += 1;
        if (section_count > 1) return true;
    }
    return false;
}

pub fn collect(
    allocator: Allocator,
    object: ObjectFile,
    section_index: usize,
) Allocator.Error![]u64 {
    var starts = std.ArrayListUnmanaged(u64).empty;
    errdefer starts.deinit(allocator);
    for (object.symbols) |symbol| {
        if (symbol.section_index != section_index) continue;
        if (!symbol.isGlobalDefinition()) continue;
        try starts.append(allocator, symbol.value);
    }
    if (starts.items.len == 0) return &.{};
    std.mem.sort(u64, starts.items, {}, std.sort.asc(u64));
    return try starts.toOwnedSlice(allocator);
}

const SectionStarts = struct {
    section_index: usize,
    starts: []const u64,
};

const SectionBuilder = struct {
    section_index: usize,
    starts: std.ArrayListUnmanaged(u64) = .empty,
};

fn deinitBuilders(allocator: Allocator, builders: []SectionBuilder) void {
    for (builders) |*builder| builder.starts.deinit(allocator);
}

fn builderForSection(
    allocator: Allocator,
    builders: *std.ArrayListUnmanaged(SectionBuilder),
    section_index: usize,
) Allocator.Error!*std.ArrayListUnmanaged(u64) {
    for (builders.items) |*builder| {
        if (builder.section_index == section_index) return &builder.starts;
    }
    try builders.append(allocator, .{ .section_index = section_index });
    return &builders.items[builders.items.len - 1].starts;
}

fn mergeStringSectionWithoutRelocations(object: ObjectFile, section: SectionHeader, section_index: usize) bool {
    if ((section.flags & std.elf.SHF_ALLOC) == 0) return false;
    if ((section.flags & std.elf.SHF_MERGE) == 0) return false;
    if ((section.flags & std.elf.SHF_STRINGS) == 0) return false;
    if (section.section_type != std.elf.SHT_PROGBITS) return false;
    if (section.entry_size > 1) return false;
    if (section.alignment > 1) return false;
    return object.relocationsForSection(section_index).len == 0;
}

pub fn has(external_starts: []const u64, cursor: *usize, input_offset: usize) bool {
    const offset: u64 = @intCast(input_offset);
    while (cursor.* < external_starts.len and external_starts[cursor.*] < offset) cursor.* += 1;
    return cursor.* < external_starts.len and external_starts[cursor.*] == offset;
}
