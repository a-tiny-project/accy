const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const compaction = @import("../../../root.zig").compaction;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != compaction.filter_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = compaction.filterInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try compaction.filterFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try compaction.createFilterFamilyArtifact(allocator, handle, instance, options);
}
