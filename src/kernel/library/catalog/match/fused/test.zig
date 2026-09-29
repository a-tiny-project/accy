const std = @import("std");
const fused = @import("root.zig");
const matrix = @import("matrix/root.zig");
const row_normalization = @import("normalization.zig");
const vector = @import("vector.zig");

test {
    _ = @import("matrix/test.zig");
    @import("test_discovery").discover(fused);
    @import("test_discovery").discover(matrix);
    @import("test_discovery").discover(row_normalization);
    @import("test_discovery").discover(vector);
}

test "accy kernel library catalog match fused declaration coverage" {
    std.testing.refAllDecls(fused);
    std.testing.refAllDecls(matrix);
    std.testing.refAllDecls(row_normalization);
    std.testing.refAllDecls(vector);
}
