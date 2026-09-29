const std = @import("std");

const artifact_product = @import("../../../../artifact/model/root.zig");
const kernel = @import("../../../root.zig");
const descriptor_mod = @import("../root.zig");
const entry = @import("../../root.zig").entry;
const query_mod = descriptor_mod;
const scan = @import("../../root.zig").scan;
const sort_mod = @import("../../root.zig").sort;

const model = @import("model.zig");

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const OwnedKernelCallPipelinePackage = model.OwnedKernelCallPipelinePackage;

pub fn createOwnedKernelCallPipelinePackage(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    descriptor: OwnedDescriptor,
    options: entry.ArtifactOptions,
) !?OwnedKernelCallPipelinePackage {
    const metadata = descriptor.descriptor.metadata;
    return switch (metadata.category) {
        .scan => try createDeviceScanPipelinePackage(allocator, handle, metadata, options),
        .sort => try createRadixSortPipelinePackage(allocator, handle, metadata, options),
        else => null,
    };
}

fn createDeviceScanPipelinePackage(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !?OwnedKernelCallPipelinePackage {
    if (metadata.version != scan.device_scan_family_version) return null;
    const instance = scan.deviceScanInstanceFromSpecialization(metadata.specialization) orelse return null;
    const target = try scan.deviceScanFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return null;

    var stage_artifacts = try scan.createDeviceScanPipelineArtifacts(allocator, handle, instance, options);
    var stage_artifacts_owned = true;
    errdefer if (stage_artifacts_owned) stage_artifacts.deinit();

    var pipeline = try scan.deviceScanPipeline(allocator, instance);
    errdefer pipeline.deinit();

    const artifacts = allocator.alloc(kernel.OwnedKernelCallArtifact, 3) catch return error.OutOfMemory;
    errdefer allocator.free(artifacts);
    artifacts[0] = stage_artifacts.block_scan;
    artifacts[1] = stage_artifacts.sums_scan;
    artifacts[2] = stage_artifacts.add_base;
    stage_artifacts_owned = false;

    return try finishPipelinePackage(allocator, artifacts, &pipeline);
}

fn createRadixSortPipelinePackage(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !?OwnedKernelCallPipelinePackage {
    if (metadata.specialization.structureIs(sort_mod.bitonic_block_structure_name)) return null;
    if (metadata.version != sort_mod.radix_split_family_version) return null;
    const instance = sort_mod.radixSplitInstanceFromSpecialization(metadata.specialization) orelse return null;
    if (metadata.specialization.structureIs(@tagName(query_mod.SortStructure.radix_digit))) {
        return try createRadixDigitPackage(allocator, handle, metadata, instance, options);
    }
    return try createRadixSplitPackage(allocator, handle, metadata, instance, options);
}

fn createRadixSplitPackage(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    instance: sort_mod.RadixSplit,
    options: entry.ArtifactOptions,
) !?OwnedKernelCallPipelinePackage {
    const target = try sort_mod.radixSplitPipelineTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return null;

    var stage_artifacts = try sort_mod.createRadixSplitPipelineArtifacts(allocator, handle, instance, options);
    var stage_artifacts_owned = true;
    errdefer if (stage_artifacts_owned) stage_artifacts.deinit();

    var pipeline = try sort_mod.radixSplitPipeline(allocator, instance);
    errdefer pipeline.deinit();

    const artifacts = allocator.alloc(kernel.OwnedKernelCallArtifact, 5) catch return error.OutOfMemory;
    errdefer allocator.free(artifacts);
    artifacts[0] = stage_artifacts.flags;
    artifacts[1] = stage_artifacts.block_scan;
    artifacts[2] = stage_artifacts.sums_scan;
    artifacts[3] = stage_artifacts.add_base;
    artifacts[4] = stage_artifacts.scatter;
    stage_artifacts_owned = false;

    return try finishPipelinePackage(allocator, artifacts, &pipeline);
}

fn createRadixDigitPackage(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    instance: sort_mod.RadixSplit,
    options: entry.ArtifactOptions,
) !?OwnedKernelCallPipelinePackage {
    const target = try sort_mod.radixDigitPipelineTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return null;

    var stage_artifacts = try sort_mod.createRadixDigitPipelineArtifacts(allocator, handle, instance, options);
    var stage_artifacts_owned = true;
    errdefer if (stage_artifacts_owned) stage_artifacts.deinit();

    var pipeline = try sort_mod.radixDigitPipeline(allocator, instance);
    errdefer pipeline.deinit();

    const artifacts = allocator.alloc(kernel.OwnedKernelCallArtifact, 5) catch return error.OutOfMemory;
    errdefer allocator.free(artifacts);
    artifacts[0] = stage_artifacts.histogram;
    artifacts[1] = stage_artifacts.block_scan;
    artifacts[2] = stage_artifacts.sums_scan;
    artifacts[3] = stage_artifacts.add_base;
    artifacts[4] = stage_artifacts.rank_scatter;
    stage_artifacts_owned = false;

    return try finishPipelinePackage(allocator, artifacts, &pipeline);
}

fn finishPipelinePackage(
    allocator: std.mem.Allocator,
    artifacts: []kernel.OwnedKernelCallArtifact,
    pipeline: *artifact_product.OwnedKernelCallPipeline,
) !?OwnedKernelCallPipelinePackage {
    errdefer for (artifacts) |*artifact| artifact.deinit();

    const entries = allocator.alloc(artifact_product.KernelCallArtifact, artifacts.len) catch return error.OutOfMemory;
    errdefer allocator.free(entries);
    for (artifacts, entries) |*owned_artifact, *registry_entry| registry_entry.* = owned_artifact.entry();

    const index = try artifact_product.buildKernelCallRegistryIndex(allocator, entries);
    errdefer artifact_product.deinitKernelCallRegistryIndex(allocator, index);

    const registry_view = artifact_product.KernelCallRegistry{ .entries = entries, .index = index };
    try pipeline.value.validate(registry_view, entries[0].format);

    return .{
        .allocator = allocator,
        .artifacts = artifacts,
        .entries = entries,
        .index = index,
        .pipeline = pipeline.*,
    };
}
