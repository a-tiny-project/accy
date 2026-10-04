//! GPU code generation. Lowers gpu-dialect kernels to SPIR-V, PTX, MSL, WGSL
//! and CPU host loops, and derives the interface a compiled kernel requires.

pub const spirv = @import("spirv/root.zig");
pub const nvptx = @import("nvptx/root.zig");
pub const metal = @import("metal/root.zig");
pub const webgpu = @import("webgpu/root.zig");
pub const cpu = @import("cpu/root.zig");
pub const lowering = @import("lowering.zig");
pub const registration = @import("registration.zig");

const features = @import("features.zig");
const subgroup = @import("subgroup.zig");

pub const TargetLowering = lowering.TargetLowering;
pub const addTargetLoweringPipeline = lowering.addTargetLoweringPipeline;

pub const dialect_registrations = registration.dialect_registrations;
pub const package_extension = registration.package_extension;
pub const registerTargetDialects = registration.registerTargetDialects;
pub const prepareCompilationDialects = registration.prepareCompilationDialects;

pub const featureRequirementsForModule = features.requirementsForModule;
pub const subgroupRequirementsForModule = subgroup.requirementsForModule;
