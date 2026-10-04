const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const boundary = @import("boundary.zig");

const Allocator = std.mem.Allocator;
const model = root.model;
const Boundary = boundary.Boundary;
const BoundaryMap = std.HashMapUnmanaged(
    Boundary,
    u64,
    Boundary.Context,
    80,
);
const Range = struct {
    start: u64,
    stop: u64,
};
const ObjectFile = elf.parser.ObjectFile;
const ObjectLayout = elf.layout.ObjectLayout;
const OutputSection = elf.layout.OutputSection;
const contributionAt = elf.layout.contributionAt;
const foldedSection = elf.section_state.foldedSection;
const firstLoadSection = elf.program.firstLoadSection;
const mergeSectionLayout = elf.layout.mergeSection;
const sectionDiscarded = elf.section_state.sectionDiscarded;
const sectionIsAllocated = elf.format.sectionIsAllocated;
const sectionNameOrEmpty = elf.parser.sectionNameOrEmpty;

pub const Cache = struct {
    pub const missing = std.math.maxInt(u64);

    entries: []u64,
    object_offsets: []usize,
    synthetic_boundaries: BoundaryMap,

    pub fn init(
        allocator: Allocator,
        objects: []const ObjectFile,
        layouts: []const ObjectLayout,
        output_sections: []const OutputSection,
    ) model.Error!Cache {
        const object_offsets = try allocator.alloc(usize, objects.len + 1);
        errdefer allocator.free(object_offsets);

        var total_symbol_count: usize = 0;
        for (objects, 0..) |object, object_index| {
            object_offsets[object_index] = total_symbol_count;
            if (object.symbols.len > std.math.maxInt(usize) - total_symbol_count) {
                return error.InvalidObject;
            }
            total_symbol_count += object.symbols.len;
        }
        object_offsets[objects.len] = total_symbol_count;

        const entries = try allocator.alloc(u64, total_symbol_count);
        errdefer allocator.free(entries);
        @memset(entries, missing);

        var synthetic_boundaries: BoundaryMap = .{};
        errdefer synthetic_boundaries.deinit(allocator);
        try collectSyntheticBoundaryAddresses(allocator, objects, layouts, output_sections, &synthetic_boundaries);

        return .{
            .entries = entries,
            .object_offsets = object_offsets,
            .synthetic_boundaries = synthetic_boundaries,
        };
    }

    pub fn deinit(self: *Cache, allocator: Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.object_offsets);
        self.synthetic_boundaries.deinit(allocator);
        self.* = undefined;
    }

    pub fn slot(self: *Cache, object_index: usize, symbol_index: usize) *u64 {
        return &self.entries[self.object_offsets[object_index] + symbol_index];
    }

    pub fn syntheticBoundaryAddress(self: *const Cache, search_boundary: Boundary) ?u64 {
        return self.synthetic_boundaries.get(search_boundary);
    }
};

pub const Access = enum {
    serial,
    concurrent,
};

pub fn load(access: Access, slot: *const u64) u64 {
    return switch (access) {
        .serial => slot.*,
        .concurrent => @atomicLoad(u64, slot, .monotonic),
    };
}

pub fn store(access: Access, slot: *u64, address: u64) model.Error!u64 {
    if (address == Cache.missing) return error.InvalidRange;
    switch (access) {
        .serial => slot.* = address,
        .concurrent => @atomicStore(u64, slot, address, .monotonic),
    }
    return address;
}

fn collectSyntheticBoundaryAddresses(
    allocator: Allocator,
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    addresses: *BoundaryMap,
) model.Error!void {
    for (objects) |object| {
        for (object.symbols) |symbol| {
            if (!symbol.isUndefined()) continue;
            if (symbol.name.len == 0) continue;
            const symbol_boundary = boundary.forSymbol(symbol.name) orelse continue;
            if (addresses.contains(symbol_boundary)) continue;
            const resolved = (try syntheticBoundaryAddress(objects, layouts, output_sections, symbol_boundary)) orelse continue;
            if (resolved == Cache.missing) return error.InvalidRange;
            try addresses.put(allocator, symbol_boundary, resolved);
        }
    }
}

fn syntheticBoundaryAddress(
    objects: []const ObjectFile,
    layouts: []const ObjectLayout,
    output_sections: []const OutputSection,
    search_boundary: Boundary,
) model.Error!?u64 {
    if (search_boundary.output_section) {
        for (output_sections) |output| {
            if (output.logicalSize() == 0) continue;
            if (!std.mem.eql(u8, output.kind.name(), search_boundary.section_name)) continue;
            return if (search_boundary.stop) output.address + output.logicalSize() else output.address;
        }
        if (search_boundary.optional) return syntheticBoundaryFallbackAddress(output_sections) orelse null;
        return null;
    }
    var range: ?Range = null;
    for (objects, 0..) |object, object_index| {
        if (object_index >= layouts.len) return error.MissingSection;
        const object_layout = layouts[object_index];
        for (object.sections, 0..) |section, section_index| {
            if (!sectionIsAllocated(section)) continue;
            if (section.size == 0) continue;
            if (sectionDiscarded(object, section_index)) continue;
            if (foldedSection(object, section_index) != null) continue;
            if (!boundary.sectionNameMatches(search_boundary, sectionNameOrEmpty(object, section_index))) continue;
            const section_range = (try syntheticBoundaryRangeForSection(object_layout, output_sections, section_index)) orelse continue;
            range = mergeSyntheticBoundaryRange(range, section_range);
        }
    }
    const final_range = range orelse {
        if (search_boundary.optional) {
            const fallback = syntheticBoundaryFallbackAddress(output_sections) orelse return null;
            return fallback;
        }
        return null;
    };
    return if (search_boundary.stop) final_range.stop else final_range.start;
}

fn syntheticBoundaryFallbackAddress(output_sections: []const OutputSection) ?u64 {
    const first_load = firstLoadSection(output_sections) orelse return null;
    return first_load.address - first_load.file_offset;
}

fn syntheticBoundaryRangeForSection(
    object_layout: ObjectLayout,
    output_sections: []const OutputSection,
    section_index: usize,
) model.Error!?Range {
    if (mergeSectionLayout(object_layout, section_index)) |merge_section| {
        return try syntheticBoundaryRangeForMergeSection(merge_section, output_sections);
    }
    const contribution = contributionAt(object_layout.sections, section_index) orelse return null;
    const output = output_sections[contribution.outputIndex()];
    const start = output.address + contribution.offset;
    const stop = std.math.add(u64, start, contribution.size) catch return error.InvalidRange;
    return .{ .start = start, .stop = stop };
}

fn syntheticBoundaryRangeForMergeSection(
    merge_section: elf.layout.MergeSectionLayout,
    output_sections: []const OutputSection,
) model.Error!?Range {
    var range: ?Range = null;
    for (merge_section.pieces) |piece| {
        if (!piece.contribution.isPresent()) continue;
        const output = output_sections[piece.contribution.outputIndex()];
        const start = output.address + piece.contribution.offset + piece.output_intra_offset;
        const stop = std.math.add(u64, start, piece.size) catch return error.InvalidRange;
        range = mergeSyntheticBoundaryRange(range, .{ .start = start, .stop = stop });
    }
    return range;
}

fn mergeSyntheticBoundaryRange(
    current: ?Range,
    update: Range,
) Range {
    const existing = current orelse return update;
    return .{
        .start = @min(existing.start, update.start),
        .stop = @max(existing.stop, update.stop),
    };
}
