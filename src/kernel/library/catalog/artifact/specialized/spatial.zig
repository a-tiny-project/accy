const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const spatial_mod = @import("../../../root.zig").spatial;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse
        return error.UnknownKernelLibraryEntry) {
        .spatial => |spatial_operation| switch (spatial_operation) {
            .grid_cells => createGridCells(allocator, handle, metadata, options),
            .grid_count => createGridCount(allocator, handle, metadata, options),
            .grid_neighbor_count => createGridNeighborCount(allocator, handle, metadata, options),
        },
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createGridCells(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != spatial_mod.grid_cells_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = spatial_mod.gridCellsInstanceFromSpecialization(metadata.specialization) orelse
        {
            return error.UnknownKernelLibraryEntry;
        };
    const target = try spatial_mod.gridCellsFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try spatial_mod.createGridCellsFamilyArtifact(allocator, handle, instance, options);
}

fn createGridCount(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != spatial_mod.grid_count_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = spatial_mod.gridCountInstanceFromSpecialization(metadata.specialization) orelse
        {
            return error.UnknownKernelLibraryEntry;
        };
    const target = try spatial_mod.gridCountFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try spatial_mod.createGridCountFamilyArtifact(allocator, handle, instance, options);
}

fn createGridNeighborCount(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != spatial_mod.grid_neighbor_count_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = spatial_mod.gridNeighborCountInstanceFromSpecialization(
        metadata.specialization,
    ) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try spatial_mod.gridNeighborCountFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try spatial_mod.createGridNeighborCountFamilyArtifact(
        allocator,
        handle,
        instance,
        options,
    );
}
