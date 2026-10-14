const std = @import("std");

const kernel = @import("../../../../../root.zig");
const entry = @import("../../../../root.zig").entry;

const factor = @import("factor.zig");
const product = @import("product.zig");

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse
        return error.UnknownKernelLibraryEntry) {
        .linalg => |linalg_operation| switch (linalg_operation) {
            .batched_cholesky, .batched_cholesky_solve, .batched_inverse => factor.create(
                allocator,
                handle,
                metadata,
                linalg_operation,
                options,
            ),
            .batched_matrix_product, .matrix_product, .matrix_vector_product, .outer_product => product.create(
                allocator,
                handle,
                metadata,
                linalg_operation,
                options,
            ),
        },
        else => error.UnknownKernelLibraryEntry,
    };
}
