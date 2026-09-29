const std = @import("std");
const gpu = @import("root.zig");

test {
    _ = @import("bindings.zig");
    _ = @import("push.zig");
    _ = @import("readback.zig");
    _ = @import("runtime/test.zig");
    _ = @import("runtime/cpu/raster.zig");
    _ = @import("runtime/cuda/test.zig");
    _ = @import("runtime/metal/test.zig");
    _ = @import("runtime/vulkan/test.zig");
}

test "gpu declaration coverage" {
    std.testing.refAllDecls(gpu);
    std.testing.refAllDecls(gpu.contract);
}

test "backends without a render path refuse passes with typed errors" {
    const refusal = @import("refusal.zig");
    var wasm_state = gpu.wasm.State.init(std.testing.allocator);
    defer wasm_state.deinit();
    try refusal.expectRenderRefused(wasm_state.handle());
    var webgpu_state = gpu.webgpu.State.init(std.testing.allocator);
    defer webgpu_state.deinit();
    try refusal.expectRenderRefused(webgpu_state.handle());
}
