const abi = @import("root.zig");

test {
    _ = @import("dtype.zig");
    _ = @import("errors.zig");
    _ = @import("features.zig");
    _ = @import("interface.zig");
    _ = @import("launch.zig");
    _ = @import("push.zig");
    @import("std").testing.refAllDecls(abi);
}
