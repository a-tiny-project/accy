pub const module = @import("module.zig");
pub const abi = @import("abi.zig");
pub const payload = @import("payload.zig");

pub const product_name = module.product_name;
pub const TargetJob = module.TargetJob;
pub const TargetModule = module.TargetModule;

pub const Compilation = payload.Compilation;
pub const compileKernelForArtifactFormat = payload.compileKernelForArtifactFormat;
pub const compileOptionsForArtifactFormat = payload.compileOptionsForArtifactFormat;
pub const CompileOptions = payload.CompileOptions;
pub const native_cpu_artifacts_supported = payload.native_cpu_artifacts_supported;
