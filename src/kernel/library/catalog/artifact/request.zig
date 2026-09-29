const std = @import("std");

const kernel = @import("../../../root.zig");
const query_mod = @import("../root.zig");
const registry = query_mod;

const ArtifactRequest = query_mod.ArtifactRequest;

pub fn createKernelCallArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    request: ArtifactRequest,
) !kernel.OwnedKernelCallArtifact {
    inline for (registry.entries) |EntryType| {
        if (EntryType.version == request.version and std.mem.eql(u8, EntryType.target, request.target)) {
            return try EntryType.createKernelCallArtifact(allocator, handle, request.options);
        }
    }
    return error.UnknownKernelLibraryEntry;
}
