const std = @import("std");
const batched = @import("batched.zig");
const linalg = @import("root.zig");
const matrix = @import("matrix.zig");
const outer = @import("outer.zig");
const vector = @import("vector.zig");

test {
    @import("test_discovery").discover(linalg);
    @import("test_discovery").discover(batched);
    @import("test_discovery").discover(matrix);
    @import("test_discovery").discover(outer);
    @import("test_discovery").discover(vector);
}

test "accy kernel library catalog match linalg declaration coverage" {
    std.testing.refAllDecls(linalg);
    std.testing.refAllDecls(batched);
    std.testing.refAllDecls(matrix);
    std.testing.refAllDecls(outer);
    std.testing.refAllDecls(vector);
}
