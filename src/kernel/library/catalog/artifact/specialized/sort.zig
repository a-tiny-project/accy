const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const sort_mod = @import("../../../root.zig").sort;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse return error.UnknownKernelLibraryEntry) {
        .sort => |sort_operation| switch (sort_operation) {
            .radix_ascending => createBitonicBlock(allocator, handle, metadata, options),
            .top_k_smallest => createTopK(allocator, handle, metadata, options),
        },
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createBitonicBlock(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sort_mod.bitonic_block_family_version) return error.UnknownKernelLibraryEntry;
    const instance = sort_mod.bitonicBlockInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sort_mod.bitonicBlockFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sort_mod.createBitonicBlockFamilyArtifact(allocator, handle, instance, options);
}

fn createTopK(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.specialization.structureIs(sort_mod.top_k_block_pairs_structure_name)) {
        return createTopKBlockPairs(allocator, handle, metadata, options);
    }
    return createTopKBlock(allocator, handle, metadata, options);
}

fn createTopKBlock(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sort_mod.top_k_block_family_version) return error.UnknownKernelLibraryEntry;
    const instance = sort_mod.topKBlockInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sort_mod.topKBlockFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sort_mod.createTopKBlockFamilyArtifact(allocator, handle, instance, options);
}

fn createTopKBlockPairs(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sort_mod.top_k_block_pairs_family_version) return error.UnknownKernelLibraryEntry;
    const instance = sort_mod.topKBlockPairsInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sort_mod.topKBlockPairsFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sort_mod.createTopKBlockPairsFamilyArtifact(allocator, handle, instance, options);
}
