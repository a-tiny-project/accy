const build_options = @import("build_options");

pub const cuda = if (build_options.native_backend_modules)
    @import("cuda/root.zig")
else
    @compileError("The gpu CUDA runtime is only available in native builds");

pub const vulkan = if (build_options.native_backend_modules)
    @import("vulkan/root.zig")
else
    @compileError("The gpu Vulkan runtime is only available in native builds");

pub const metal = if (build_options.native_backend_modules)
    @import("metal/root.zig")
else
    @compileError("The gpu Metal runtime is only available in native builds");
