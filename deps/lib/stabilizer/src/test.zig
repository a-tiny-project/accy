const std = @import("std");
const stabilizer = @import("root.zig");

const code_mod = @import("code.zig");
const config_mod = @import("config.zig");
const heap_mod = @import("heap.zig");
const intrinsics_mod = @import("intrinsics.zig");
const rng_mod = @import("rng.zig");
const runtime_mod = @import("runtime.zig");
const stack_mod = @import("stack.zig");

test "stabilizer package namespace" {
    _ = stabilizer;
    std.testing.refAllDecls(code_mod);
    std.testing.refAllDecls(config_mod);
    std.testing.refAllDecls(heap_mod);
    std.testing.refAllDecls(intrinsics_mod);
    std.testing.refAllDecls(rng_mod);
    std.testing.refAllDecls(runtime_mod);
    std.testing.refAllDecls(stack_mod);
}
