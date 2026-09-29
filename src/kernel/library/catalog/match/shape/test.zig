const std = @import("std");
const attention = @import("attention.zig");
const dimension = @import("dimension.zig");
const fused = @import("fused.zig");
const layout = @import("layout.zig");
const matrix = @import("matrix.zig");
const model = @import("model.zig");
const outer = @import("outer.zig");
const product = @import("product.zig");
const reduction = @import("reduction.zig");
const shape = @import("root.zig");
const vector = @import("vector.zig");

test {
    @import("test_discovery").discover(shape);
    @import("test_discovery").discover(attention);
    @import("test_discovery").discover(dimension);
    @import("test_discovery").discover(fused);
    @import("test_discovery").discover(layout);
    @import("test_discovery").discover(matrix);
    @import("test_discovery").discover(model);
    @import("test_discovery").discover(reduction);
    @import("test_discovery").discover(outer);
    @import("test_discovery").discover(product);
    @import("test_discovery").discover(vector);
}

test "accy kernel library catalog match shape declaration coverage" {
    std.testing.refAllDecls(shape);
    std.testing.refAllDecls(attention);
    std.testing.refAllDecls(dimension);
    std.testing.refAllDecls(fused);
    std.testing.refAllDecls(layout);
    std.testing.refAllDecls(matrix);
    std.testing.refAllDecls(model);
    std.testing.refAllDecls(reduction);
    std.testing.refAllDecls(outer);
    std.testing.refAllDecls(product);
    std.testing.refAllDecls(vector);
}
