//! Compiled-kernel interface shared by Choir's GPU code generators and the
//! lib/compiler/gpu runtimes that load their artifacts. The package imports only `std`,
//! so each side links this vocabulary without linking the other.

const dtype = @import("dtype.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const interface = @import("interface.zig");
const launch = @import("launch.zig");
const push = @import("push.zig");

/// The host ABI of a vertex or fragment stage lowered to a CPU function.
pub const stage = @import("stage.zig");
/// The buffer, texture and sampler indices of an MSL render stage's resources.
pub const metal = @import("metal.zig");

pub const Error = errors.Error;

pub const DType = dtype.DType;
pub const Bf16 = dtype.Bf16;
pub const Key = dtype.Key;

pub const Features = features.Features;
pub const SubgroupRequirements = features.SubgroupRequirements;

pub const ScalarArgument = launch.ScalarArgument;
pub const LaunchGeometry = launch.LaunchGeometry;
pub const LaunchShape = launch.LaunchShape;
pub const launch_shape_argument_count = launch.launch_shape_argument_count;
pub const kernelArgumentCount = launch.kernelArgumentCount;
pub const launchShape = launch.launchShape;
pub const launchShapeArguments = launch.launchShapeArguments;

pub const max_push_constant_bytes = push.max_push_constant_bytes;
pub const max_push_constant_members = push.max_push_constant_members;
pub const pushConstantOffset = push.pushConstantOffset;
pub const Limits = push.Limits;
pub const PushConstants = push.PushConstants;
pub const PushConstantMember = push.PushConstantMember;

pub const Interface = interface.Interface;
