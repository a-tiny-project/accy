const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const plan = @import("registry.zig");

const DType = gpu_abi.DType;

pub const product_name = "accy.kernel_call_pipeline";

pub const PipelineValueRef = union(enum) {
    operand: u32,
    result: u32,
    intermediate: u32,
};

pub const PipelineScalarDerivation = union(enum) {
    forward: u32,
    ceil_div: plan.KernelCallDerivedLaunchAxis.RuntimeU32CeilDiv,
    ceil_div_scaled: CeilDivScaled,
    ceil_div_scaled_by_arg: CeilDivScaledByArg,

    pub const CeilDivScaled = struct {
        argument_index: u32,
        divisor: u32 = 1,
        scale: u32 = 1,
    };

    pub const CeilDivScaledByArg = struct {
        argument_index: u32,
        divisor: u32 = 1,
        scale_argument_index: u32,
    };

    pub fn resolveScalar(
        self: PipelineScalarDerivation,
        runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    ) gpu.BackendError!gpu_abi.ScalarArgument {
        return switch (self) {
            .forward => |index| if (index < runtime_scalar_arguments.len)
                runtime_scalar_arguments[index]
            else
                error.LaunchArgumentMismatch,
            .ceil_div => |axis| .{
                .u32 = try (plan.KernelCallDerivedLaunchAxis{
                    .runtime_u32_ceil_div = axis,
                }).extent(runtime_scalar_arguments),
            },
            .ceil_div_scaled => |scaled| blk: {
                const base = try (plan.KernelCallDerivedLaunchAxis{ .runtime_u32_ceil_div = .{
                    .argument_index = scaled.argument_index,
                    .divisor = scaled.divisor,
                } }).extent(runtime_scalar_arguments);
                const value = std.math.mul(
                    u32,
                    base,
                    scaled.scale,
                ) catch return error.LaunchArgumentMismatch;
                break :blk .{ .u32 = value };
            },
            .ceil_div_scaled_by_arg => |scaled| blk: {
                const base = try (plan.KernelCallDerivedLaunchAxis{ .runtime_u32_ceil_div = .{
                    .argument_index = scaled.argument_index,
                    .divisor = scaled.divisor,
                } }).extent(runtime_scalar_arguments);
                if (scaled.scale_argument_index >= runtime_scalar_arguments.len) {
                    return error.LaunchArgumentMismatch;
                }
                const scale = switch (runtime_scalar_arguments[scaled.scale_argument_index]) {
                    .u32 => |value| value,
                    else => return error.LaunchArgumentMismatch,
                };
                const value = std.math.mul(
                    u32,
                    base,
                    scale,
                ) catch return error.LaunchArgumentMismatch;
                break :blk .{ .u32 = value };
            },
        };
    }

    pub fn resolveExtent(
        self: PipelineScalarDerivation,
        runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    ) gpu.BackendError!u32 {
        return switch (try self.resolveScalar(runtime_scalar_arguments)) {
            .u32 => |value| value,
            else => error.LaunchArgumentMismatch,
        };
    }
};

pub const PipelineIntermediate = struct {
    dtype: DType,
    extent: PipelineScalarDerivation,
};

pub const PipelineRuntimeScalarBound = struct {
    argument_index: u32,
    max_u32: u32,
};

pub const PipelineStage = struct {
    target: []const u8,
    version: u32,
    buffers: []const PipelineValueRef = &.{},
    scalars: []const PipelineScalarDerivation = &.{},
};

/// An ordered list of stages under one target name and version, so a caller
/// describes a multi-kernel computation and hands it to the loader and
/// launcher. Each stage names a registry entry, a prebuilt kernel, by target
/// and version and so holds no copy of its code. Each stage lists its buffers
/// as caller operands, caller results or scratch buffers allocated between
/// stages, and derives its integer arguments from the runtime scalar arguments
/// by passing one through, dividing and rounding up, or scaling first. The same
/// runtime scalar arguments size the intermediates and the launch grids, and
/// each runtime scalar argument may carry an upper bound. `validate` checks a
/// nonempty target, a nonzero version and at least one stage, then finds every
/// stage's entry for the format and checks each stage's buffer count, argument
/// count, references and divisors before anything is launched, and every
/// failure is `error.InvalidArtifact`. `validateRuntimeScalarArguments` checks
/// the count and the declared bounds of the runtime scalar arguments and
/// returns `error.LaunchArgumentMismatch` on a mismatch.
pub const KernelCallPipeline = struct {
    target: []const u8,
    version: u32,
    operand_count: u32 = 0,
    result_count: u32 = 0,
    runtime_scalar_argument_count: u32 = 0,
    runtime_scalar_bounds: []const PipelineRuntimeScalarBound = &.{},
    intermediates: []const PipelineIntermediate = &.{},
    stages: []const PipelineStage = &.{},

    pub fn validate(
        self: KernelCallPipeline,
        registry: plan.KernelCallRegistry,
        format: gpu.ArtifactFormat,
    ) gpu.BackendError!void {
        if (self.target.len == 0) return error.InvalidArtifact;
        if (self.version == 0) return error.InvalidArtifact;
        if (self.stages.len == 0) return error.InvalidArtifact;
        for (self.runtime_scalar_bounds) |bound| {
            if (bound.argument_index >= self.runtime_scalar_argument_count) {
                return error.InvalidArtifact;
            }
        }
        for (self.intermediates) |intermediate| {
            try self.validateDerivation(intermediate.extent);
        }
        for (self.stages) |stage| {
            const entry = registry.find(stage.target, stage.version, format) orelse
                return error.InvalidArtifact;
            if (entry.argument_count < entry.runtime_scalar_argument_count) {
                return error.InvalidArtifact;
            }
            const buffer_count = entry.argument_count - entry.runtime_scalar_argument_count;
            if (stage.buffers.len != buffer_count) return error.InvalidArtifact;
            if (stage.scalars.len != entry.runtime_scalar_argument_count) {
                return error.InvalidArtifact;
            }
            for (stage.buffers) |ref| try self.validateValueRef(ref);
            for (stage.scalars) |derivation| try self.validateDerivation(derivation);
        }
    }

    pub fn validateRuntimeScalarArguments(
        self: KernelCallPipeline,
        runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    ) gpu.BackendError!void {
        if (runtime_scalar_arguments.len != self.runtime_scalar_argument_count) {
            return error.LaunchArgumentMismatch;
        }
        for (self.runtime_scalar_bounds) |bound| {
            if (bound.argument_index >= runtime_scalar_arguments.len) {
                return error.LaunchArgumentMismatch;
            }
            const value = switch (runtime_scalar_arguments[bound.argument_index]) {
                .u32 => |value| value,
                else => return error.LaunchArgumentMismatch,
            };
            if (value > bound.max_u32) return error.LaunchArgumentMismatch;
        }
    }

    fn validateValueRef(self: KernelCallPipeline, ref: PipelineValueRef) gpu.BackendError!void {
        switch (ref) {
            .operand => |index| if (index >= self.operand_count) return error.InvalidArtifact,
            .result => |index| if (index >= self.result_count) return error.InvalidArtifact,
            .intermediate => |index| if (index >=
                self.intermediates.len) return error.InvalidArtifact,
        }
    }

    fn validateDerivation(
        self: KernelCallPipeline,
        derivation: PipelineScalarDerivation,
    ) gpu.BackendError!void {
        switch (derivation) {
            .forward => |index| if (index >=
                self.runtime_scalar_argument_count) return error.InvalidArtifact,
            .ceil_div => |axis| {
                if (axis.divisor == 0) return error.InvalidArtifact;
                if (axis.argument_index >= self.runtime_scalar_argument_count) {
                    return error.InvalidArtifact;
                }
            },
            .ceil_div_scaled => |scaled| {
                if (scaled.divisor == 0 or scaled.scale == 0) return error.InvalidArtifact;
                if (scaled.argument_index >= self.runtime_scalar_argument_count) {
                    return error.InvalidArtifact;
                }
            },
            .ceil_div_scaled_by_arg => |scaled| {
                if (scaled.divisor == 0) return error.InvalidArtifact;
                if (scaled.argument_index >= self.runtime_scalar_argument_count) {
                    return error.InvalidArtifact;
                }
                if (scaled.scale_argument_index >= self.runtime_scalar_argument_count) {
                    return error.InvalidArtifact;
                }
            },
        }
    }
};

pub fn findPipeline(
    pipelines: []const KernelCallPipeline,
    target: []const u8,
    version: u32,
) ?KernelCallPipeline {
    for (pipelines) |entry| {
        if (entry.version != version) continue;
        if (!std.mem.eql(u8, entry.target, target)) continue;
        return entry;
    }
    return null;
}

pub const OwnedKernelCallPipeline = struct {
    arena: std.heap.ArenaAllocator,
    value: KernelCallPipeline = .{ .target = &.{}, .version = 0 },

    pub fn init(backing_allocator: std.mem.Allocator) OwnedKernelCallPipeline {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    pub fn allocator(self: *OwnedKernelCallPipeline) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *OwnedKernelCallPipeline) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const testing = std.testing;

fn testEntry(
    comptime target: []const u8,
    argument_count: u32,
    runtime_scalars: u32,
) plan.KernelCallArtifact {
    return .{
        .target = target,
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = target,
        .argument_count = argument_count,
        .payload = .{ .text = "// " ++ target },
        .runtime_scalar_argument_count = runtime_scalars,
    };
}

const device_scan_entries = [_]plan.KernelCallArtifact{
    testEntry("accy.kernel.scan.device_prefix_sum_block_scan_family_64_f32", 4, 1),
    testEntry("accy.kernel.scan.prefix_sum_exclusive_family_32_f32", 3, 1),
    testEntry("accy.kernel.scan.device_add_base_family_64_f32", 3, 1),
};

const device_scan_pipeline = KernelCallPipeline{
    .target = "accy.kernel.scan.device_prefix_sum_family_64_f32",
    .version = 1,
    .operand_count = 1,
    .result_count = 1,
    .runtime_scalar_argument_count = 1,
    .intermediates = &.{
        .{ .dtype = .f32, .extent = .{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } } },
        .{ .dtype = .f32, .extent = .{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } } },
    },
    .stages = &.{
        .{
            .target = "accy.kernel.scan.device_prefix_sum_block_scan_family_64_f32",
            .version = 1,
            .buffers = &.{ .{ .result = 0 }, .{ .operand = 0 }, .{ .intermediate = 0 } },
            .scalars = &.{.{ .forward = 0 }},
        },
        .{
            .target = "accy.kernel.scan.prefix_sum_exclusive_family_32_f32",
            .version = 1,
            .buffers = &.{ .{ .intermediate = 1 }, .{ .intermediate = 0 } },
            .scalars = &.{.{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } }},
        },
        .{
            .target = "accy.kernel.scan.device_add_base_family_64_f32",
            .version = 1,
            .buffers = &.{ .{ .result = 0 }, .{ .intermediate = 1 } },
            .scalars = &.{.{ .forward = 0 }},
        },
    },
};
