const build_options = @import("build_options");
const namespace = @import("root.zig");
const cuda = namespace.cuda;
const vulkan = namespace.vulkan;
const metal = namespace.metal;

test {
    if (build_options.native_backend_modules) {
        _ = @This().cuda;
        _ = @This().vulkan;
        _ = @This().metal;
    }
}
