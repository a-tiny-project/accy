const std = @import("std");

const artifact_product = @import("../../../../artifact/model/root.zig");
const kernel = @import("../../../root.zig");

pub const OwnedKernelCallArtifactRegistry = struct {
    allocator: std.mem.Allocator,
    artifacts: []kernel.OwnedKernelCallArtifact = &.{},
    entries: []artifact_product.KernelCallArtifact = &.{},
    index: artifact_product.KernelCallRegistryIndex = .{},

    pub fn registry(
        self: *const OwnedKernelCallArtifactRegistry,
    ) artifact_product.KernelCallRegistry {
        return .{
            .entries = self.entries,
            .index = self.index,
        };
    }

    pub fn deinit(self: *OwnedKernelCallArtifactRegistry) void {
        artifact_product.deinitKernelCallRegistryIndex(self.allocator, self.index);
        for (self.artifacts) |*artifact| artifact.deinit();
        if (self.artifacts.len != 0) self.allocator.free(self.artifacts);
        if (self.entries.len != 0) self.allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const OwnedKernelCallPipelinePackage = struct {
    allocator: std.mem.Allocator,
    artifacts: []kernel.OwnedKernelCallArtifact = &.{},
    entries: []artifact_product.KernelCallArtifact = &.{},
    index: artifact_product.KernelCallRegistryIndex = .{},
    pipeline: artifact_product.OwnedKernelCallPipeline,

    pub fn registry(
        self: *const OwnedKernelCallPipelinePackage,
    ) artifact_product.KernelCallRegistry {
        return .{
            .entries = self.entries,
            .index = self.index,
        };
    }

    pub fn deinit(self: *OwnedKernelCallPipelinePackage) void {
        artifact_product.deinitKernelCallRegistryIndex(self.allocator, self.index);
        for (self.artifacts) |*artifact| artifact.deinit();
        if (self.artifacts.len != 0) self.allocator.free(self.artifacts);
        if (self.entries.len != 0) self.allocator.free(self.entries);
        self.pipeline.deinit();
        self.* = undefined;
    }
};
