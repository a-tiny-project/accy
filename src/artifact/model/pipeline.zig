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

test "pipeline validates the device scan shape against its stage registry" {
    const registry = plan.KernelCallRegistry{ .entries = device_scan_entries[0..] };
    try device_scan_pipeline.validate(registry, .cuda_ptx);
}

test "pipeline validation names every violated contract" {
    const registry = plan.KernelCallRegistry{ .entries = device_scan_entries[0..] };

    var missing_stage = device_scan_pipeline;
    missing_stage.stages = &.{.{
        .target = "accy.kernel.scan.absent",
        .version = 1,
        .buffers = &.{ .{ .result = 0 }, .{ .operand = 0 }, .{ .intermediate = 0 } },
        .scalars = &.{.{ .forward = 0 }},
    }};
    try testing.expectError(error.InvalidArtifact, missing_stage.validate(registry, .cuda_ptx));

    var wrong_format = device_scan_pipeline;
    try testing.expectError(error.InvalidArtifact, wrong_format.validate(registry, .vulkan_spirv));

    var bad_version = device_scan_pipeline;
    bad_version.version = 0;
    try testing.expectError(error.InvalidArtifact, bad_version.validate(registry, .cuda_ptx));

    var no_stages = device_scan_pipeline;
    no_stages.stages = &.{};
    try testing.expectError(error.InvalidArtifact, no_stages.validate(registry, .cuda_ptx));

    var bad_operand = device_scan_pipeline;
    bad_operand.operand_count = 0;
    try testing.expectError(error.InvalidArtifact, bad_operand.validate(registry, .cuda_ptx));

    var bad_intermediate = device_scan_pipeline;
    bad_intermediate.intermediates = device_scan_pipeline.intermediates[0..1];
    try testing.expectError(error.InvalidArtifact, bad_intermediate.validate(registry, .cuda_ptx));

    var bad_scalar = device_scan_pipeline;
    bad_scalar.runtime_scalar_argument_count = 0;
    try testing.expectError(error.InvalidArtifact, bad_scalar.validate(registry, .cuda_ptx));

    var bad_runtime_bound = device_scan_pipeline;
    bad_runtime_bound.runtime_scalar_bounds = &.{.{ .argument_index = 1, .max_u32 = 5000 }};
    try testing.expectError(error.InvalidArtifact, bad_runtime_bound.validate(registry, .cuda_ptx));

    const short_buffers = [_]PipelineStage{.{
        .target = "accy.kernel.scan.device_add_base_family_64_f32",
        .version = 1,
        .buffers = &.{.{ .result = 0 }},
        .scalars = &.{.{ .forward = 0 }},
    }};
    var wrong_arity = device_scan_pipeline;
    wrong_arity.stages = short_buffers[0..];
    try testing.expectError(error.InvalidArtifact, wrong_arity.validate(registry, .cuda_ptx));
}

test "pipeline runtime scalar bounds reject out-of-capacity launches" {
    const registry = plan.KernelCallRegistry{ .entries = device_scan_entries[0..] };
    var bounded = device_scan_pipeline;
    bounded.runtime_scalar_bounds = &.{.{ .argument_index = 0, .max_u32 = 5000 }};
    try bounded.validate(registry, .cuda_ptx);

    const in_range = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    try bounded.validateRuntimeScalarArguments(in_range[0..]);

    const too_large = [_]gpu_abi.ScalarArgument{.{ .u32 = 5001 }};
    try testing.expectError(
        error.LaunchArgumentMismatch,
        bounded.validateRuntimeScalarArguments(too_large[0..]),
    );

    const wrong_type = [_]gpu_abi.ScalarArgument{.{ .f32 = 5000.0 }};
    try testing.expectError(
        error.LaunchArgumentMismatch,
        bounded.validateRuntimeScalarArguments(wrong_type[0..]),
    );

    try testing.expectError(
        error.LaunchArgumentMismatch,
        bounded.validateRuntimeScalarArguments(&.{}),
    );
}

test "pipeline scalar derivations resolve forward and ceil-div values" {
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};

    const forward = PipelineScalarDerivation{ .forward = 0 };
    try testing.expectEqual(@as(u32, 5000), try forward.resolveExtent(args[0..]));

    const blocks = PipelineScalarDerivation{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } };
    try testing.expectEqual(@as(u32, 79), try blocks.resolveExtent(args[0..]));

    const scalar = try blocks.resolveScalar(args[0..]);
    try testing.expectEqual(@as(u32, 79), scalar.u32);

    const float_args = [_]gpu_abi.ScalarArgument{.{ .f32 = 1.0 }};
    try testing.expectError(error.LaunchArgumentMismatch, forward.resolveExtent(float_args[0..]));
    try testing.expectError(error.LaunchArgumentMismatch, blocks.resolveExtent(float_args[0..]));

    const out_of_range = PipelineScalarDerivation{ .forward = 3 };
    try testing.expectError(error.LaunchArgumentMismatch, out_of_range.resolveScalar(args[0..]));
}

test "pipeline lookup finds by target and version" {
    const pipelines = [_]KernelCallPipeline{device_scan_pipeline};
    try testing.expect(findPipeline(pipelines[0..], device_scan_pipeline.target, 1) != null);
    try testing.expect(findPipeline(pipelines[0..], device_scan_pipeline.target, 2) == null);
    try testing.expect(findPipeline(pipelines[0..], "missing", 1) == null);
}

test "pipeline scaled ceil-div derivations resolve and validate" {
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const counts_extent = PipelineScalarDerivation{
        .ceil_div_scaled = .{ .argument_index = 0, .divisor = 64, .scale = 16 },
    };
    try testing.expectEqual(@as(u32, 79 * 16), try counts_extent.resolveExtent(args[0..]));

    const identity_scale = PipelineScalarDerivation{
        .ceil_div_scaled = .{ .argument_index = 0, .divisor = 64, .scale = 1 },
    };
    try testing.expectEqual(@as(u32, 79), try identity_scale.resolveExtent(args[0..]));

    const overflow = PipelineScalarDerivation{
        .ceil_div_scaled = .{ .argument_index = 0, .divisor = 1, .scale = std.math.maxInt(u32) },
    };
    try testing.expectError(error.LaunchArgumentMismatch, overflow.resolveExtent(args[0..]));

    var scaled_pipeline = device_scan_pipeline;
    const scaled_intermediates = [_]PipelineIntermediate{
        .{ .dtype = .f32, .extent = .{
            .ceil_div_scaled = .{ .argument_index = 0, .divisor = 64, .scale = 0 },
        } },
    };
    scaled_pipeline.intermediates = scaled_intermediates[0..];
    const registry = plan.KernelCallRegistry{ .entries = device_scan_entries[0..] };
    try testing.expectError(error.InvalidArtifact, scaled_pipeline.validate(registry, .cuda_ptx));

    var bad_index = device_scan_pipeline;
    const bad_intermediates = [_]PipelineIntermediate{
        .{ .dtype = .f32, .extent = .{
            .ceil_div_scaled = .{ .argument_index = 7, .divisor = 64, .scale = 16 },
        } },
    };
    bad_index.intermediates = bad_intermediates[0..];
    try testing.expectError(error.InvalidArtifact, bad_index.validate(registry, .cuda_ptx));
}

test "pipeline runtime-scaled derivations resolve and validate" {
    const args = [_]gpu_abi.ScalarArgument{ .{ .u32 = 5000 }, .{ .u32 = 64 } };
    const cells_buffer = PipelineScalarDerivation{
        .ceil_div_scaled_by_arg = .{
            .argument_index = 0,
            .divisor = 64,
            .scale_argument_index = 1,
        },
    };
    try testing.expectEqual(@as(u32, 79 * 64), try cells_buffer.resolveExtent(args[0..]));

    const bad_index = PipelineScalarDerivation{
        .ceil_div_scaled_by_arg = .{
            .argument_index = 0,
            .divisor = 64,
            .scale_argument_index = 7,
        },
    };
    try testing.expectError(error.LaunchArgumentMismatch, bad_index.resolveExtent(args[0..]));

    const float_scale_args = [_]gpu_abi.ScalarArgument{ .{ .u32 = 5000 }, .{ .f32 = 2.0 } };
    try testing.expectError(
        error.LaunchArgumentMismatch,
        cells_buffer.resolveExtent(float_scale_args[0..]),
    );

    var scaled_pipeline = device_scan_pipeline;
    const bad_intermediates = [_]PipelineIntermediate{
        .{ .dtype = .f32, .extent = .{ .ceil_div_scaled_by_arg = .{
            .argument_index = 0,
            .divisor = 0,
            .scale_argument_index = 0,
        } } },
    };
    scaled_pipeline.intermediates = bad_intermediates[0..];
    const registry = plan.KernelCallRegistry{ .entries = device_scan_entries[0..] };
    try testing.expectError(error.InvalidArtifact, scaled_pipeline.validate(registry, .cuda_ptx));
}
