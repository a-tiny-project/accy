const std = @import("std");
const descriptor_mod = @import("../../root.zig");
const query_mod = descriptor_mod;
const radix = @import("radix.zig");
const top = @import("top.zig");

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SortQuery = query_mod.SortQuery;

pub const selectRadixSortWithTuning = radix.selectRadixSortWithTuning;
pub const selectRadixSort = radix.selectRadixSort;

pub fn selectSort(backing_allocator: std.mem.Allocator, query: SortQuery) !?OwnedDescriptor {
    return switch (query.kind) {
        .radix_ascending => radix.selectRadixSort(backing_allocator, query),
        .top_k_smallest => top.selectTopKBlock(backing_allocator, query),
    };
}
