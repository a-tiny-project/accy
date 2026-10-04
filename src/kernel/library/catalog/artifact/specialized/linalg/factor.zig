const std = @import("std");

const kernel = @import("../../../../../root.zig");
const entry = @import("../../../../root.zig").entry;
const factor_mod = @import("../../../../root.zig").factor;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    operation: entry.LinalgOperator,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (operation) {
        .batched_cholesky => createBatchedCholesky(allocator, handle, metadata, options),
        .batched_cholesky_solve => createBatchedCholeskySolve(allocator, handle, metadata, options),
        .batched_inverse => createBatchedInverse(allocator, handle, metadata, options),
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createBatchedCholesky(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != factor_mod.batched_cholesky_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = factor_mod.batchedCholeskyInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try factor_mod.batchedCholeskyFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try factor_mod.createBatchedCholeskyFamilyArtifact(allocator, handle, instance, options);
}

fn createBatchedCholeskySolve(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != factor_mod.batched_cholesky_solve_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = factor_mod.batchedCholeskySolveInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try factor_mod.batchedCholeskySolveFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try factor_mod.createBatchedCholeskySolveFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
}

fn createBatchedInverse(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != factor_mod.batched_inverse_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = factor_mod.batchedInverseInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try factor_mod.batchedInverseFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try factor_mod.createBatchedInverseFamilyArtifact(allocator, handle, instance, options);
}
