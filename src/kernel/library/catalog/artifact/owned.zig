const std = @import("std");

const artifact_product = @import("../../../../artifact/model/root.zig");
const kernel = @import("../../../root.zig");
const descriptor_mod = @import("../root.zig");
const entry = @import("../../root.zig").entry;

const model = @import("model.zig");
const request_mod = @import("request.zig");
const specialized = @import("specialized/root.zig");

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const OwnedKernelCallArtifactRegistry = model.OwnedKernelCallArtifactRegistry;

pub fn createOwnedKernelCallArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    descriptor: OwnedDescriptor,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return request_mod.createKernelCallArtifact(allocator, handle, .{
        .target = descriptor.descriptor.metadata.target,
        .version = descriptor.descriptor.metadata.version,
        .options = options,
    }) catch |err| switch (err) {
        error.UnknownKernelLibraryEntry => try specialized.createSpecializedKernelCallArtifact(allocator, handle, descriptor, options),
        else => err,
    };
}

pub fn createOwnedKernelCallArtifactRegistry(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    descriptors: []const OwnedDescriptor,
    options: entry.ArtifactOptions,
) !OwnedKernelCallArtifactRegistry {
    if (descriptors.len == 0) return .{ .allocator = allocator };

    const artifacts = try allocator.alloc(kernel.OwnedKernelCallArtifact, descriptors.len);
    var artifact_count: usize = 0;
    errdefer {
        for (artifacts[0..artifact_count]) |*artifact| artifact.deinit();
        allocator.free(artifacts);
    }

    const entries = try allocator.alloc(artifact_product.KernelCallArtifact, descriptors.len);
    errdefer allocator.free(entries);

    for (descriptors, 0..) |descriptor, index| {
        artifacts[index] = try createOwnedKernelCallArtifact(allocator, handle, descriptor, options);
        artifact_count += 1;
        entries[index] = artifacts[index].entry();
    }

    const index = try artifact_product.buildKernelCallRegistryIndex(allocator, entries);
    errdefer artifact_product.deinitKernelCallRegistryIndex(allocator, index);

    return .{
        .allocator = allocator,
        .artifacts = artifacts,
        .entries = entries,
        .index = index,
    };
}
