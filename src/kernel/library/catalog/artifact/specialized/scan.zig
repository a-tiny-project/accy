const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const scan = @import("../../../root.zig").scan;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != scan.prefix_sum_family_version) return error.UnknownKernelLibraryEntry;
    const instance = scan.prefixSumInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try scan.prefixSumFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try scan.createPrefixSumFamilyArtifact(allocator, handle, instance, options);
}
