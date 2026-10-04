const std = @import("std");
const factor = @import("factor.zig");
const family = @import("root.zig");
const filter = @import("filter.zig");
const gather = @import("gather.zig");
const histogram = @import("histogram.zig");
const image = @import("image.zig");
const linalg = @import("linalg/root.zig");
const random = @import("random/root.zig");
const scan = @import("scan/root.zig");
const scatter = @import("scatter/root.zig");
const segmented = @import("segmented.zig");
const sparse = @import("sparse/root.zig");
const sort = @import("sort/root.zig");
const spatial = @import("spatial.zig");
const stencil = @import("stencil.zig");

test {
    _ = @import("linalg/test.zig");
    _ = @import("random/test.zig");
    _ = @import("scan/test.zig");
    _ = @import("scatter/test.zig");
    _ = @import("sparse/test.zig");
    _ = @import("sort/test.zig");
    @import("test_discovery").discover(family);
    @import("test_discovery").discover(factor);
    @import("test_discovery").discover(filter);
    @import("test_discovery").discover(gather);
    @import("test_discovery").discover(histogram);
    @import("test_discovery").discover(image);
    @import("test_discovery").discover(linalg);
    @import("test_discovery").discover(random);
    @import("test_discovery").discover(scan);
    @import("test_discovery").discover(scatter);
    @import("test_discovery").discover(segmented);
    @import("test_discovery").discover(sparse);
    @import("test_discovery").discover(sort);
    @import("test_discovery").discover(spatial);
    @import("test_discovery").discover(stencil);
}

test "accy kernel library catalog family declaration coverage" {
    std.testing.refAllDecls(family);
    std.testing.refAllDecls(factor);
    std.testing.refAllDecls(filter);
    std.testing.refAllDecls(gather);
    std.testing.refAllDecls(histogram);
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(linalg);
    std.testing.refAllDecls(random);
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(scatter);
    std.testing.refAllDecls(segmented);
    std.testing.refAllDecls(sparse);
    std.testing.refAllDecls(sort);
    std.testing.refAllDecls(spatial);
    std.testing.refAllDecls(stencil);
}
