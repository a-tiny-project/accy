const std = @import("std");
const batched_matrix_product = @import("batch.zig");
const linalg = @import("root.zig");
const matrix_product = @import("matrix.zig");
const matrix_vector = @import("vector.zig");
const outer_product = @import("outer.zig");

test {
    @import("test_discovery").discover(linalg);
    @import("test_discovery").discover(batched_matrix_product);
    @import("test_discovery").discover(matrix_product);
    @import("test_discovery").discover(matrix_vector);
    @import("test_discovery").discover(outer_product);
}

test "accy kernel library catalog family linalg declaration coverage" {
    std.testing.refAllDecls(linalg);
    std.testing.refAllDecls(batched_matrix_product);
    std.testing.refAllDecls(matrix_product);
    std.testing.refAllDecls(matrix_vector);
    std.testing.refAllDecls(outer_product);
}
