const bootstrap = @import("root.zig");

test {
    _ = @import("interval.zig");
    _ = @import("resample.zig");
    @import("std").testing.refAllDecls(bootstrap);
}
