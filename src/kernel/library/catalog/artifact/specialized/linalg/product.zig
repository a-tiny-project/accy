const std = @import("std");

const kernel = @import("../../../../../root.zig");
const entry = @import("../../../../root.zig").entry;
const linalg = @import("../../../../root.zig").linalg;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    operation: entry.LinalgOperator,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (operation) {
        .batched_matrix_product => createBatchedMatrixProduct(allocator, handle, metadata, options),
        .matrix_product => createMatrixProduct(allocator, handle, metadata, options),
        .matrix_vector_product => createMatrixVectorProduct(allocator, handle, metadata, options),
        .outer_product => createOuterProduct(allocator, handle, metadata, options),
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createMatrixProduct(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != linalg.matrix_product_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = linalg.matrixProductInstanceFromSpecialization(metadata.specialization) orelse
        {
            return error.UnknownKernelLibraryEntry;
        };
    const target = try linalg.matrixProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try linalg.createMatrixProductFamilyArtifact(allocator, handle, instance, options);
}

fn createBatchedMatrixProduct(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != linalg.batched_matrix_product_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = linalg.batchedMatrixProductInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try linalg.batchedMatrixProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try linalg.createBatchedMatrixProductFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
}

fn createMatrixVectorProduct(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != linalg.matrix_vector_product_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = linalg.matrixVectorProductInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try linalg.matrixVectorProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try linalg.createMatrixVectorProductFamilyArtifact(allocator, handle, instance, options);
}

fn createOuterProduct(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != linalg.outer_product_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = linalg.outerProductInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try linalg.outerProductFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try linalg.createOuterProductFamilyArtifact(allocator, handle, instance, options);
}
