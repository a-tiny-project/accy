const std = @import("std");
const epilogue = @import("epilogue.zig");
const matrix = @import("root.zig");
const product = @import("product.zig");
const vector = @import("vector.zig");

test {
    @import("test_discovery").discover(matrix);
    @import("test_discovery").discover(epilogue);
    @import("test_discovery").discover(product);
    @import("test_discovery").discover(vector);
}

test "accy kernel library catalog match fused matrix declaration coverage" {
    std.testing.refAllDecls(matrix);
    std.testing.refAllDecls(epilogue);
    std.testing.refAllDecls(product);
    std.testing.refAllDecls(vector);
}
