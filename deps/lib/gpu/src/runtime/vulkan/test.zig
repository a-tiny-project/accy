const vulkan = @import("root.zig");

test "gpu vulkan runtime namespace" {
    _ = vulkan.memory;
    _ = vulkan.runtime;
    _ = vulkan.launch;
    _ = vulkan.raster;
    _ = vulkan.dmabuf;
}
