const cuda = @import("root.zig");

test "gpu cuda runtime namespace" {
    _ = cuda.runtime;
    _ = cuda.support;
}
