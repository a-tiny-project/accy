const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const image = @import("../../../root.zig").image;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse
        return error.UnknownKernelLibraryEntry) {
        .image => |image_operation| switch (image_operation) {
            .blur_pass => createBlurPass(allocator, handle, metadata, options),
            .resize_bilinear => createResize(allocator, handle, metadata, options),
        },
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createBlurPass(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != image.blur_family_version) return error.UnknownKernelLibraryEntry;
    const instance = image.blurPassInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try image.blurPassFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try image.createBlurPassFamilyArtifact(allocator, handle, instance, options);
}

fn createResize(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != image.resize_family_version) return error.UnknownKernelLibraryEntry;
    const instance = image.resizeInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try image.resizeFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try image.createResizeFamilyArtifact(allocator, handle, instance, options);
}
