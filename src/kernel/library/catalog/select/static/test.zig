const std = @import("std");
const activation = @import("activation.zig");
const attention = @import("attention.zig");
const filter = @import("filter.zig");
const fused = @import("fused.zig");
const gather = @import("gather.zig");
const layout = @import("layout.zig");
const linalg = @import("linalg.zig");
const normalization = @import("normalization.zig");
const random = @import("random.zig");
const reduction = @import("reduction.zig");
const scan = @import("scan.zig");
const scatter = @import("scatter.zig");
const segmented = @import("segmented.zig");
const stencil = @import("stencil.zig");

test {
    @import("test_discovery").discover(activation);
    @import("test_discovery").discover(attention);
    @import("test_discovery").discover(filter);
    @import("test_discovery").discover(fused);
    @import("test_discovery").discover(gather);
    @import("test_discovery").discover(layout);
    @import("test_discovery").discover(linalg);
    @import("test_discovery").discover(normalization);
    @import("test_discovery").discover(random);
    @import("test_discovery").discover(reduction);
    @import("test_discovery").discover(scan);
    @import("test_discovery").discover(scatter);
    @import("test_discovery").discover(segmented);
    @import("test_discovery").discover(stencil);
}

test "accy kernel library catalog select static declaration coverage" {
    std.testing.refAllDecls(activation);
    std.testing.refAllDecls(attention);
    std.testing.refAllDecls(filter);
    std.testing.refAllDecls(fused);
    std.testing.refAllDecls(gather);
    std.testing.refAllDecls(layout);
    std.testing.refAllDecls(linalg);
    std.testing.refAllDecls(normalization);
    std.testing.refAllDecls(random);
    std.testing.refAllDecls(reduction);
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(scatter);
    std.testing.refAllDecls(segmented);
    std.testing.refAllDecls(stencil);
}
