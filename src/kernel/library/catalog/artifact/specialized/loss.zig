const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const loss = @import("../../../root.zig").loss;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse
        return error.UnknownKernelLibraryEntry) {
        .loss => |loss_operation| switch (loss_operation) {
            .row_sparse_cross_entropy => createRowSparseCrossEntropy(
                allocator,
                handle,
                metadata,
                options,
            ),
        },
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createRowSparseCrossEntropy(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != loss.row_sparse_cross_entropy_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = loss.rowSparseCrossEntropyInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try loss.rowSparseCrossEntropyFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try loss.createRowSparseCrossEntropyFamilyArtifact(allocator, handle, instance, options);
}
