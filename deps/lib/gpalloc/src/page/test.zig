const std = @import("std");
const subject = @import("root.zig");
const lifecycle = @import("lifecycle.zig");
const mapping = @import("mapping.zig");
const model = @import("model.zig");

comptime {
    _ = subject;
}

test {
    std.testing.refAllDecls(lifecycle);
    std.testing.refAllDecls(mapping);
    std.testing.refAllDecls(model);
}
