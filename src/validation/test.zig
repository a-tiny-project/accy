const validation = @import("root.zig");

test "accy integration package namespace" {
    _ = validation.gating;
    _ = validation.ptx;
    _ = @import("contract/test.zig");
    _ = @import("conformance/test.zig");
    _ = @import("composition/test.zig");
}
