const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const random = @import("../../../root.zig").random;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse
        return error.UnknownKernelLibraryEntry) {
        .random => |random_operation| switch (random_operation) {
            .philox => createPhilox(allocator, handle, metadata, options),
            .threefry => createThreefry(allocator, handle, metadata, options),
            .squares => createSquares(allocator, handle, metadata, options),
            .philox_key_split => createPhiloxKeySplit(allocator, handle, metadata, options),
            .philox_key_uniform => createPhiloxKeyUniform(allocator, handle, metadata, options),
            .philox_key_counter_uniform => createPhiloxKeyCounterUniform(
                allocator,
                handle,
                metadata,
                options,
            ),
            .philox_fold, .threefry_fold, .squares_fold => error.UnknownKernelLibraryEntry,
        },
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createSquares(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != random.squares_family_version) return error.UnknownKernelLibraryEntry;
    const instance = random.squaresInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try random.squaresFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try random.createSquaresFamilyArtifact(allocator, handle, instance, options);
}

fn createPhilox(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != random.philox_family_version) return error.UnknownKernelLibraryEntry;
    const instance = random.philoxInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try random.philoxFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try random.createPhiloxFamilyArtifact(allocator, handle, instance, options);
}

fn createPhiloxKeySplit(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != random.philox_key_split_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = random.philoxKeySplitInstanceFromSpecialization(metadata.specialization) orelse
        {
            return error.UnknownKernelLibraryEntry;
        };
    const target = try random.philoxKeySplitFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try random.createPhiloxKeySplitFamilyArtifact(allocator, handle, instance, options);
}

fn createPhiloxKeyUniform(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != random.philox_key_uniform_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = random.philoxKeyUniformInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try random.philoxKeyUniformFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try random.createPhiloxKeyUniformFamilyArtifact(allocator, handle, instance, options);
}

fn createPhiloxKeyCounterUniform(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != random.philox_key_counter_uniform_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = random.philoxKeyCounterUniformInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try random.philoxKeyCounterUniformFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try random.createPhiloxKeyCounterUniformFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
}

fn createThreefry(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != random.threefry_family_version) return error.UnknownKernelLibraryEntry;
    const instance = random.threefryInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try random.threefryFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try random.createThreefryFamilyArtifact(allocator, handle, instance, options);
}
