const metal = @import("root.zig");

test "gpu metal runtime namespace" {
    _ = @import("runtime/test.zig");
    _ = metal.runtime;
}
