const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const accy_choir = @import("../../choir/root.zig");

const testing = std.testing;

pub const ArtifactPlanOptions = struct {
    format: ?gpu.ArtifactFormat = null,
    kernel_call_registry: ?*const KernelCallRegistry = null,
};

pub const ElementCountArgument = enum {
    none,
    scalar_u32,
    device_buffer_u32,
};
pub const KernelCallLaunch = union(enum) {
    derived: KernelCallDerivedLaunch,
    fixed: gpu_abi.LaunchGeometry,
};

pub const KernelCallDerivedLaunchAxis = union(enum) {
    fixed: u32,
    runtime_u32_ceil_div: RuntimeU32CeilDiv,

    pub const RuntimeU32CeilDiv = struct {
        argument_index: u32,
        divisor: u32 = 1,
    };

    pub fn extent(
        self: KernelCallDerivedLaunchAxis,
        runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    ) gpu.BackendError!u32 {
        return switch (self) {
            .fixed => |value| if (value == 0) error.InvalidArtifact else value,
            .runtime_u32_ceil_div => |axis| runtimeU32CeilDiv(runtime_scalar_arguments, axis),
        };
    }
};

pub const KernelCallDerivedLaunch = struct {
    grid: [3]KernelCallDerivedLaunchAxis = .{
        .{ .fixed = 1 },
        .{ .fixed = 1 },
        .{ .fixed = 1 },
    },
    threadgroup: [3]u32 = .{ 1, 1, 1 },
    dynamic_shared_memory_bytes: u32 = 0,

    pub fn geometry(
        self: KernelCallDerivedLaunch,
        runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    ) gpu.BackendError!gpu_abi.LaunchGeometry {
        return .{
            .grid = .{
                try self.grid[0].extent(runtime_scalar_arguments),
                try self.grid[1].extent(runtime_scalar_arguments),
                try self.grid[2].extent(runtime_scalar_arguments),
            },
            .threadgroup = try validateThreadgroup(self.threadgroup),
            .dynamic_shared_memory_bytes = self.dynamic_shared_memory_bytes,
        };
    }
};

pub const KernelCallShapeProfileBounds = accy_choir.shape.Bounds;

pub const KernelCallShapeProfileDimension = struct {
    name: []const u8,
    runtime_scalar_argument_index: u32,
    bounds: KernelCallShapeProfileBounds,
};

pub const KernelCallShapeProfile = struct {
    name: []const u8,
    fingerprint: u64,
    dimensions: []const KernelCallShapeProfileDimension = &.{},

    pub fn validate(
        self: KernelCallShapeProfile,
        runtime_scalar_argument_count: u32,
    ) gpu.BackendError!void {
        if (self.name.len == 0) return error.InvalidArtifact;
        if (self.dimensions.len == 0) return error.InvalidArtifact;
        for (self.dimensions, 0..) |item, index| {
            if (item.name.len == 0) return error.InvalidArtifact;
            if (item.runtime_scalar_argument_index >= runtime_scalar_argument_count) {
                return error.InvalidArtifact;
            }
            if (!item.bounds.valid()) return error.InvalidArtifact;
            for (self.dimensions[0..index]) |previous| {
                if (previous.runtime_scalar_argument_index == item.runtime_scalar_argument_index) {
                    return error.InvalidArtifact;
                }
                if (std.mem.eql(u8, previous.name, item.name)) return error.InvalidArtifact;
            }
        }
    }

    pub fn dimension(
        self: KernelCallShapeProfile,
        name: []const u8,
    ) ?KernelCallShapeProfileDimension {
        for (self.dimensions) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }
        return null;
    }

    pub fn runtimeScalarDimension(
        self: KernelCallShapeProfile,
        index: u32,
    ) ?KernelCallShapeProfileDimension {
        for (self.dimensions) |item| {
            if (item.runtime_scalar_argument_index == index) return item;
        }
        return null;
    }
};

/// Records one prebuilt kernel in a registry, found by the triple of target
/// name, for example "accy.kernel.linalg.matmul5x7x3_4x2_f32", its `version`,
/// and its artifact format, so compiled programs can call it by name. The entry
/// also records its entry point name, argument count, required element types,
/// device features, code payload, launch rule, static arguments, and optional
/// named dimensions. The `version` field stands for what the kernel computes
/// and is separate from the byte-layout version of the registry file. A
/// maintainer raises `version` before an existing entry changes its math, the
/// meaning of its element types or memory layout, its argument list, its static
/// arguments, how its launch is derived, what its shape profile means, or its
/// schedule. A change that touches only the registry file's byte layout, or
/// that keeps behavior unchanged, leaves `version` as it is, because the
/// registry file carries its own layout version. A family target names one
/// reusable schedule, and sizes that leave that schedule unchanged arrive at
/// launch as bounded runtime scalar arguments.
pub const KernelCallArtifact = struct {
    target: []const u8,
    version: u32,
    format: gpu.ArtifactFormat,
    entry_name: []const u8,
    argument_count: u32,
    shape_family_fingerprint: ?u64 = null,
    shape_profile: ?KernelCallShapeProfile = null,
    required_dtypes: gpu.DTypeSet = .{},
    required_features: gpu_abi.Features = .{},
    required_subgroup: gpu_abi.SubgroupRequirements = .{},
    /// Layout the emitter gave the entry's push-constant block, if any.
    push_constants: gpu_abi.PushConstants = .{},
    payload: gpu.CompilePayload,
    launch: KernelCallLaunch = .{ .derived = .{} },
    element_count_argument: ElementCountArgument = .none,
    runtime_scalar_argument_count: u32 = 0,
    static_arguments: []const gpu_abi.ScalarArgument = &.{},

    /// Scalar arguments the entry's kernel takes, runtime and static
    /// together. The rest of `argument_count` are buffers.
    pub fn scalarArgumentCount(self: KernelCallArtifact) gpu.BackendError!u32 {
        const static_count = std.math.cast(u32, self.static_arguments.len) orelse
            return error.InvalidArtifact;
        const count = std.math.add(u32, self.runtime_scalar_argument_count, static_count) catch
            return error.InvalidArtifact;
        if (count > self.argument_count) return error.InvalidArtifact;
        return count;
    }
};

pub const StandaloneKernelOptions = struct {
    runtime_scalar_argument_count: u32 = 0,
    static_arguments: []const gpu_abi.ScalarArgument = &.{},
};

pub const KernelCallRegistryIndexSlot = struct {
    occupied: bool = false,
    target: []const u8 = &.{},
    version: u32 = 0,
    format: gpu.ArtifactFormat = .cuda_ptx,
    entry_index: usize = 0,
};

pub const KernelCallRegistryIndex = struct {
    slots: []const KernelCallRegistryIndexSlot = &.{},

    pub fn findEntryIndex(
        self: KernelCallRegistryIndex,
        target: []const u8,
        version: u32,
        format: gpu.ArtifactFormat,
    ) ?usize {
        if (self.slots.len == 0) return null;
        var slot_index = kernelCallRegistrySlotIndex(self.slots.len, target, version, format);
        var probe_count: usize = 0;
        while (probe_count < self.slots.len) : (probe_count += 1) {
            const slot = self.slots[slot_index];
            if (!slot.occupied) return null;
            if (kernelCallRegistryKeyMatches(slot, target, version, format)) {
                return slot.entry_index;
            }
            slot_index = (slot_index + 1) & (self.slots.len - 1);
        }
        return null;
    }
};

pub const KernelCallRegistry = struct {
    entries: []const KernelCallArtifact = &.{},
    index: ?KernelCallRegistryIndex = null,

    pub fn find(
        self: KernelCallRegistry,
        target: []const u8,
        version: u32,
        format: gpu.ArtifactFormat,
    ) ?KernelCallArtifact {
        if (self.index) |index| {
            const entry_index = index.findEntryIndex(target, version, format) orelse return null;
            if (entry_index >= self.entries.len) return null;
            return self.entries[entry_index];
        }
        for (self.entries) |entry| {
            if (entry.version != version) continue;
            if (entry.format != format) continue;
            if (!std.mem.eql(u8, entry.target, target)) continue;
            return entry;
        }
        return null;
    }
};

pub const KernelCallRegistryIndexError = error{
    DuplicateKernelCallArtifact,
} || std.mem.Allocator.Error;

pub fn buildKernelCallRegistryIndex(
    allocator: std.mem.Allocator,
    entries: []const KernelCallArtifact,
) KernelCallRegistryIndexError!KernelCallRegistryIndex {
    if (entries.len == 0) return .{};
    const slots = try allocator.alloc(
        KernelCallRegistryIndexSlot,
        try kernelCallRegistryIndexCapacity(entries.len),
    );
    @memset(slots, .{});
    const index = KernelCallRegistryIndex{ .slots = slots };
    errdefer deinitKernelCallRegistryIndex(allocator, index);
    for (entries, 0..) |entry, entry_index| {
        try insertKernelCallRegistryIndexEntry(slots, entry, entry_index);
    }
    return index;
}

pub fn deinitKernelCallRegistryIndex(
    allocator: std.mem.Allocator,
    index: KernelCallRegistryIndex,
) void {
    if (index.slots.len != 0) allocator.free(@constCast(index.slots));
}

fn insertKernelCallRegistryIndexEntry(
    slots: []KernelCallRegistryIndexSlot,
    entry: KernelCallArtifact,
    entry_index: usize,
) KernelCallRegistryIndexError!void {
    var slot_index = kernelCallRegistrySlotIndex(
        slots.len,
        entry.target,
        entry.version,
        entry.format,
    );
    while (true) {
        const slot = &slots[slot_index];
        if (!slot.occupied) {
            slot.* = .{
                .occupied = true,
                .target = entry.target,
                .version = entry.version,
                .format = entry.format,
                .entry_index = entry_index,
            };
            return;
        }
        if (kernelCallRegistryKeyMatches(slot.*, entry.target, entry.version, entry.format)) {
            return error.DuplicateKernelCallArtifact;
        }
        slot_index = (slot_index + 1) & (slots.len - 1);
    }
}

fn kernelCallRegistryIndexCapacity(entry_count: usize) KernelCallRegistryIndexError!usize {
    const wanted = std.math.mul(usize, entry_count, 2) catch return error.OutOfMemory;
    var capacity: usize = 1;
    while (capacity < wanted) {
        capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
    }
    return capacity;
}

fn kernelCallRegistrySlotIndex(
    slot_count: usize,
    target: []const u8,
    version: u32,
    format: gpu.ArtifactFormat,
) usize {
    return @intCast(
        kernelCallRegistryKeyHash(target, version, format) & @as(u64, @intCast(slot_count - 1)),
    );
}

fn kernelCallRegistryKeyHash(target: []const u8, version: u32, format: gpu.ArtifactFormat) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(target);
    hasher.update(std.mem.asBytes(&version));
    const format_tag: u8 = @backingInt(format);
    hasher.update(std.mem.asBytes(&format_tag));
    return hasher.final();
}

fn kernelCallRegistryKeyMatches(
    slot: KernelCallRegistryIndexSlot,
    target: []const u8,
    version: u32,
    format: gpu.ArtifactFormat,
) bool {
    return slot.version == version and
        slot.format == format and
        std.mem.eql(u8, slot.target, target);
}

pub fn duplicateKernelCallShapeProfile(
    allocator: std.mem.Allocator,
    profile: KernelCallShapeProfile,
) !KernelCallShapeProfile {
    const name = try allocator.dupe(u8, profile.name);
    errdefer allocator.free(name);
    const dimensions = try allocator.alloc(KernelCallShapeProfileDimension, profile.dimensions.len);
    var copied_count: usize = 0;
    errdefer {
        for (dimensions[0..copied_count]) |dimension| allocator.free(dimension.name);
        allocator.free(dimensions);
    }
    for (profile.dimensions, dimensions) |source, *destination| {
        destination.* = source;
        destination.name = try allocator.dupe(u8, source.name);
        copied_count += 1;
    }
    return .{
        .name = name,
        .fingerprint = profile.fingerprint,
        .dimensions = dimensions,
    };
}

pub fn deinitKernelCallShapeProfile(
    allocator: std.mem.Allocator,
    profile: KernelCallShapeProfile,
) void {
    allocator.free(profile.name);
    for (profile.dimensions) |dimension| allocator.free(dimension.name);
    allocator.free(profile.dimensions);
}

pub fn kernelCallShapeProfileEql(lhs: ?KernelCallShapeProfile, rhs: ?KernelCallShapeProfile) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return kernelCallShapeProfileValueEql(lhs.?, rhs.?);
}

fn kernelCallShapeProfileValueEql(lhs: KernelCallShapeProfile, rhs: KernelCallShapeProfile) bool {
    if (!std.mem.eql(u8, lhs.name, rhs.name)) return false;
    if (lhs.fingerprint != rhs.fingerprint) return false;
    if (lhs.dimensions.len != rhs.dimensions.len) return false;
    for (lhs.dimensions, rhs.dimensions) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (left.runtime_scalar_argument_index != right.runtime_scalar_argument_index) return false;
        if (!std.meta.eql(left.bounds, right.bounds)) return false;
    }
    return true;
}

fn runtimeU32CeilDiv(
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    axis: KernelCallDerivedLaunchAxis.RuntimeU32CeilDiv,
) gpu.BackendError!u32 {
    if (axis.divisor == 0) return error.InvalidArtifact;
    const argument_index: usize = @intCast(axis.argument_index);
    if (argument_index >= runtime_scalar_arguments.len) return error.LaunchArgumentMismatch;
    const value = switch (runtime_scalar_arguments[argument_index]) {
        .u32 => |payload| payload,
        else => return error.LaunchArgumentMismatch,
    };
    const biased = std.math.add(u32, value, axis.divisor -
        1) catch return error.LaunchArgumentMismatch;
    const extent = biased / axis.divisor;
    if (extent == 0) return error.LaunchArgumentMismatch;
    return extent;
}

pub fn validateThreadgroup(threadgroup: [3]u32) gpu.BackendError![3]u32 {
    for (threadgroup) |extent| {
        if (extent == 0) return error.InvalidArtifact;
    }
    return threadgroup;
}

pub fn defaultArtifactFormat(kind: gpu.BackendKind) ?gpu.ArtifactFormat {
    return switch (kind) {
        .cuda => .cuda_ptx,
        .vulkan => .vulkan_spirv,
        .metal => .metal_msl,
        .webgpu => .webgpu_wgsl,
        .cpu => .cpu_object,
        .wasm => .webassembly_module,
        else => null,
    };
}
