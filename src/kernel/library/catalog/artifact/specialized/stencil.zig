const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const stencil = @import("../../../root.zig").stencil;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != stencil.window_family_version) return error.UnknownKernelLibraryEntry;
    const instance = stencil.windowInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try stencil.windowFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try stencil.createWindowFamilyArtifact(allocator, handle, instance, options);
}
