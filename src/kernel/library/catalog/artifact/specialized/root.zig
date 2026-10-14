const std = @import("std");

const kernel = @import("../../../../root.zig");
const descriptor_mod = @import("../../root.zig");
const entry = @import("../../../root.zig").entry;

const compaction = @import("compaction.zig");
const indexing = @import("indexing.zig");
const image = @import("image.zig");
const linalg = @import("linalg/root.zig");
const loss = @import("loss.zig");
const random = @import("random.zig");
const scan = @import("scan.zig");
const segmented = @import("segmented.zig");
const sort = @import("sort.zig");
const sparse = @import("sparse.zig");
const spatial = @import("spatial.zig");
const stencil = @import("stencil.zig");

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;

pub fn createSpecializedKernelCallArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    descriptor: OwnedDescriptor,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (descriptor.specialization == null) return error.UnknownKernelLibraryEntry;
    const metadata = descriptor.descriptor.metadata;
    return switch (metadata.category) {
        .linalg => linalg.create(allocator, handle, metadata, options),
        .stencil => stencil.create(allocator, handle, metadata, options),
        .indexing => indexing.create(allocator, handle, metadata, options),
        .loss => loss.create(allocator, handle, metadata, options),
        .segmented => segmented.create(allocator, handle, metadata, options),
        .sparse => sparse.create(allocator, handle, metadata, options),
        .sort => sort.create(allocator, handle, metadata, options),
        .spatial => spatial.create(allocator, handle, metadata, options),
        .image => image.create(allocator, handle, metadata, options),
        .scan => scan.create(allocator, handle, metadata, options),
        .compaction => compaction.create(allocator, handle, metadata, options),
        .random => random.create(allocator, handle, metadata, options),
        else => error.UnknownKernelLibraryEntry,
    };
}
