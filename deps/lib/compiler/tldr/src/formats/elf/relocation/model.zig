const std = @import("std");
const elf = @import("../root.zig");

const Allocator = std.mem.Allocator;
const format = elf.format;
const Rela = format.Rela;

pub const RelocationRange = struct {
    start: usize,
    count: usize,
};

pub const ObjectParseOptions = struct {
    strip_debug: bool = false,
    /// Holds the worker budget for decoding a large relocation table, as
    /// `LinkOptions.max_link_jobs` defines it.
    worker_budget: usize = 1,
};

pub const ParsedRelocations = struct {
    relocations: []const Rela,
    owned: bool,
    ranges: []RelocationRange,

    pub fn deinit(self: ParsedRelocations, allocator: Allocator) void {
        if (self.owned and self.relocations.len != 0) allocator.free(@constCast(self.relocations));
        if (self.ranges.len != 0) allocator.free(self.ranges);
    }
};

pub const RelocationCounts = struct {
    counts: []usize = &.{},
    duplicate_targets: bool = false,

    pub fn deinit(self: *RelocationCounts, allocator: Allocator) void {
        if (self.counts.len != 0) allocator.free(self.counts);
    }
};

pub const SectionMetadata = struct {
    symtab_index: ?usize = null,
    has_relocation_sections: bool = false,
    has_group_sections: bool = false,
};
