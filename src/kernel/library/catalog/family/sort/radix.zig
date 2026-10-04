const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const sort_mod = @import("../../../root.zig").sort;
const tuning_mod = @import("../../../root.zig").tuning;
const query_mod = descriptor_mod;

const bitonic = @import("bitonic.zig");

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SortQuery = query_mod.SortQuery;

pub fn selectRadixSortWithTuning(
    backing_allocator: std.mem.Allocator,
    query: SortQuery,
    reader: tuning_mod.FamilyTuningReader,
) !?OwnedDescriptor {
    if (query.structure != null) return selectRadixSort(backing_allocator, query);
    if (query.dtype != .i32 or query.kind != .radix_ascending) return null;
    const threads = sort_mod.radixSplitThreadsForExtent(query.extent) orelse return null;
    var instance = sort_mod.RadixSplit{ .extent = query.extent, .threads = threads };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |requested_threads| instance.threads = requested_threads,
        }
    }
    const resolved = try sort_mod.resolveRadixSplitStructure(backing_allocator, reader, instance);
    var tuned = query;
    tuned.structure = if (resolved) |structure| switch (structure) {
        .radix_split => .radix_split,
        .radix_digit => .radix_digit,
    } else null;
    return selectRadixSort(backing_allocator, tuned);
}

pub fn selectRadixSort(backing_allocator: std.mem.Allocator, query: SortQuery) !?OwnedDescriptor {
    if (query.dtype != .i32) return null;
    if (query.kind != .radix_ascending) return null;
    const structure = query.structure orelse .radix_digit;
    switch (structure) {
        .bitonic_block => return bitonic.selectBitonicBlockSort(backing_allocator, query),
        .radix_split, .radix_digit => {},
        .top_k_block, .top_k_block_pairs => return null,
    }
    var instance = sort_mod.RadixSplit{
        .extent = query.extent,
        .threads = sort_mod.radixSplitThreadsForExtent(query.extent) orelse return null,
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                instance.threads = threads;
            },
        }
    }
    if (!sort_mod.radixSplitInstanceValid(instance)) return null;
    var specialization = try sort_mod.radixSplitFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    specialization.value.structure = @tagName(structure);
    const lifetime_allocator = specialization.allocator();
    const target = switch (structure) {
        .radix_split => try sort_mod.radixSplitPipelineTarget(lifetime_allocator, instance),
        .radix_digit => try sort_mod.radixDigitPipelineTarget(lifetime_allocator, instance),
        .bitonic_block, .top_k_block, .top_k_block_pairs => unreachable,
    };
    const descriptor = Descriptor{
        .name = target,
        .metadata = .{
            .target = target,
            .version = sort_mod.radix_split_family_version,
            .layer = .logical,
            .category = .sort,
            .specialization = specialization.value,
        },
    };
    return .{ .descriptor = descriptor, .specialization = specialization };
}
