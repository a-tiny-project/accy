const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const histogram_mod = @import("../../../root.zig").histogram;
const indexing = @import("../../../root.zig").indexing;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse
        return error.UnknownKernelLibraryEntry) {
        .indexing => |indexing_operation| switch (indexing_operation) {
            .gather => createGather(allocator, handle, metadata, options),
            .scatter => createScatter(allocator, handle, metadata, options),
            .scatter_add => createScatterAdd(allocator, handle, metadata, options),
            .histogram => createHistogram(allocator, handle, metadata, options),
        },
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createHistogram(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != histogram_mod.histogram_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = histogram_mod.histogramInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try histogram_mod.histogramFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try histogram_mod.createHistogramFamilyArtifact(allocator, handle, instance, options);
}

fn createGather(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != indexing.gather_family_version) return error.UnknownKernelLibraryEntry;
    const instance = indexing.gatherInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try indexing.gatherFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try indexing.createGatherFamilyArtifact(allocator, handle, instance, options);
}

fn createScatter(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != indexing.scatter_family_version) return error.UnknownKernelLibraryEntry;
    const instance = indexing.scatterInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try indexing.scatterFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try indexing.createScatterFamilyArtifact(allocator, handle, instance, options);
}

fn createScatterAdd(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != indexing.scatter_add_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = indexing.scatterAddInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try indexing.scatterAddFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try indexing.createScatterAddFamilyArtifact(allocator, handle, instance, options);
}
