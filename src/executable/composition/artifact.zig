const std = @import("std");
const choir = @import("choir");
const accy_root = @import("../../root.zig");
const executable = @import("../root.zig");
const composition = @import("root.zig");

const Allocator = std.mem.Allocator;
const Artifact = choir.backends.artifact.Artifact;

pub const BoundaryMetadata = struct {
    element_type: choir.composition.ElementType,
    dimensions: []const u64,
    byte_size: usize,

    fn deinit(self: *BoundaryMetadata, allocator: Allocator) void {
        if (self.dimensions.len != 0) allocator.free(@constCast(self.dimensions));
        self.* = undefined;
    }
};

pub const CpuObjectMetadata = struct {
    allocator: Allocator,
    fingerprint: u64,
    artifact_fingerprint: u64,
    artifacts: []Artifact,
    input_boundaries: []BoundaryMetadata,
    output_boundaries: []BoundaryMetadata,

    pub fn init(
        allocator: Allocator,
        fragment: *const executable.CompiledFragment,
    ) !CpuObjectMetadata {
        const plan = fragment.artifactPlan();
        if (plan.kernels.items.len == 0) return error.InvalidArtifact;
        const artifacts = try allocator.alloc(Artifact, plan.kernels.items.len);
        var artifact_count: usize = 0;
        errdefer {
            var index = artifact_count;
            while (index != 0) {
                index -= 1;
                artifacts[index].deinit();
            }
            allocator.free(artifacts);
        }

        for (plan.kernels.items, 0..) |kernel, index| {
            if (kernel.artifact.backend != .cpu or kernel.artifact.format != .cpu_object) return error.InvalidArtifact;
            const object = switch (kernel.artifact.payload) {
                .bytes => |bytes| bytes,
                else => return error.InvalidArtifact,
            };
            var artifact = try choir.backends.artifact.objectFileArtifact(
                allocator,
                .{
                    .architecture = .x86_64,
                    .triple = "x86_64-unknown-linux-gnu",
                    .cpu = "x86-64",
                },
                .{
                    .name = "sysv",
                    .calling_convention = "c",
                    .object_format = "elf",
                    .pointer_width_bits = 64,
                    .endianness = .little,
                },
                kernel.artifact.entry_name,
                object,
                &.{},
            );
            errdefer artifact.deinit();
            try artifact.options.add(.{ .key = "accy.kernel_id", .value = .{ .unsigned = kernel.kernel_id } });
            try artifact.options.add(.{ .key = "accy.work_item_id", .value = .{ .unsigned = kernel.work_item_id } });
            try artifact.options.add(.{ .key = "accy.argument_count", .value = .{ .unsigned = kernel.artifact.argument_count } });
            try artifact.options.add(.{ .key = "accy.scalar_argument_count", .value = .{ .unsigned = kernel.artifact.scalar_argument_count } });
            try artifact.verification.replace(artifact.allocator, .{ .state = .passed, .stage = "accy.cpu_object" });
            artifacts[index] = artifact;
            artifact_count += 1;
        }

        const input_boundaries = try retainBoundaries(allocator, plan, plan.input_slot_ids);
        errdefer deinitBoundaries(allocator, input_boundaries);
        const output_boundaries = try retainBoundaries(allocator, plan, plan.output_slot_ids);
        errdefer deinitBoundaries(allocator, output_boundaries);

        return .{
            .allocator = allocator,
            .fingerprint = fragment.fingerprint(),
            .artifact_fingerprint = fragment.artifactFingerprint(),
            .artifacts = artifacts,
            .input_boundaries = input_boundaries,
            .output_boundaries = output_boundaries,
        };
    }

    pub fn entrySymbol(self: *const CpuObjectMetadata) ?[]const u8 {
        for (self.artifacts) |artifact| {
            if (artifact.linkage.provided_symbols.items.len != 0) return artifact.linkage.provided_symbols.items[0].name;
        }
        return null;
    }

    pub fn deinit(self: *CpuObjectMetadata) void {
        var artifact_index = self.artifacts.len;
        while (artifact_index != 0) {
            artifact_index -= 1;
            self.artifacts[artifact_index].deinit();
        }
        deinitBoundaries(self.allocator, self.output_boundaries);
        deinitBoundaries(self.allocator, self.input_boundaries);
        self.allocator.free(self.artifacts);
        self.* = undefined;
    }
};

fn retainBoundaries(
    allocator: Allocator,
    plan: *const accy_root.artifact.BackendArtifactPlan,
    slot_ids: []const usize,
) ![]BoundaryMetadata {
    const boundaries = try allocator.alloc(BoundaryMetadata, slot_ids.len);
    var initialized: usize = 0;
    errdefer {
        var index = initialized;
        while (index != 0) {
            index -= 1;
            boundaries[index].deinit(allocator);
        }
        allocator.free(boundaries);
    }
    for (slot_ids, 0..) |slot_id, index| {
        const slot = plan.slotById(slot_id) orelse return error.InvalidArtifact;
        const byte_size = std.math.cast(usize, slot.byte_size orelse return error.UnsupportedOperation) orelse return error.InvalidArtifact;
        if (byte_size == 0) return error.UnsupportedOperation;
        const dimensions: []u64 = if (slot.dims.len == 0) &.{} else try allocator.alloc(u64, slot.dims.len);
        errdefer if (dimensions.len != 0) allocator.free(dimensions);
        for (slot.dims, dimensions) |dimension, *retained| {
            retained.* = std.math.cast(u64, dimension) orelse return error.UnsupportedOperation;
            if (retained.* == 0) return error.UnsupportedOperation;
        }
        const element_type = composition.elementType(slot.dtype);
        const static_byte_size = choir.composition.source.boundary.staticByteSize(element_type, dimensions) orelse return error.InvalidArtifact;
        if (static_byte_size != byte_size) return error.InvalidArtifact;
        boundaries[index] = .{
            .element_type = element_type,
            .dimensions = dimensions,
            .byte_size = byte_size,
        };
        initialized += 1;
    }
    return boundaries;
}

fn deinitBoundaries(allocator: Allocator, boundaries: []BoundaryMetadata) void {
    var index = boundaries.len;
    while (index != 0) {
        index -= 1;
        boundaries[index].deinit(allocator);
    }
    allocator.free(boundaries);
}
