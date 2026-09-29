const std = @import("std");
const activation = @import("activation.zig");
const attention = @import("attention.zig");
const common = @import("common.zig");
const compaction = @import("compaction.zig");
const factor = @import("factor.zig");
const fused = @import("fused/root.zig");
const image = @import("image.zig");
const indexing = @import("indexing/root.zig");
const layout = @import("layout.zig");
const linalg = @import("linalg/root.zig");
const loss = @import("loss.zig");
const match = @import("root.zig");
const normalization = @import("normalization.zig");
const random = @import("random.zig");
const reduction = @import("reduction.zig");
const scan = @import("scan.zig");
const segmented = @import("segmented.zig");
const shape = @import("shape/root.zig");
const sort = @import("sort.zig");
const sparse = @import("sparse/root.zig");
const spatial = @import("spatial.zig");
const stencil = @import("stencil.zig");

test {
    _ = @import("fused/test.zig");
    _ = @import("indexing/test.zig");
    _ = @import("linalg/test.zig");
    _ = @import("shape/test.zig");
    _ = @import("sparse/test.zig");
    @import("test_discovery").discover(match);
    @import("test_discovery").discover(activation);
    @import("test_discovery").discover(attention);
    @import("test_discovery").discover(common);
    @import("test_discovery").discover(compaction);
    @import("test_discovery").discover(factor);
    @import("test_discovery").discover(fused);
    @import("test_discovery").discover(image);
    @import("test_discovery").discover(indexing);
    @import("test_discovery").discover(layout);
    @import("test_discovery").discover(linalg);
    @import("test_discovery").discover(loss);
    @import("test_discovery").discover(normalization);
    @import("test_discovery").discover(random);
    @import("test_discovery").discover(reduction);
    @import("test_discovery").discover(scan);
    @import("test_discovery").discover(segmented);
    @import("test_discovery").discover(shape);
    @import("test_discovery").discover(sort);
    @import("test_discovery").discover(sparse);
    @import("test_discovery").discover(spatial);
    @import("test_discovery").discover(stencil);
}

fn dependencyDeclarationCount(source: []const u8) ?usize {
    const body_start = std.mem.indexOf(u8, source, "pub fn ") orelse return null;
    const preamble = source[0..body_start];
    return std.mem.count(u8, preamble, "\nconst ") +
        @intFromBool(std.mem.startsWith(u8, preamble, "const "));
}

test "kernel library catalog matchers keep narrow dependency preambles" {
    try std.testing.expectEqual(5, dependencyDeclarationCount(@embedFile("activation.zig")));
    try std.testing.expectEqual(12, dependencyDeclarationCount(@embedFile("attention.zig")));
    try std.testing.expectEqual(3, dependencyDeclarationCount(@embedFile("common.zig")));
    try std.testing.expectEqual(9, dependencyDeclarationCount(@embedFile("compaction.zig")));
    try std.testing.expectEqual(10, dependencyDeclarationCount(@embedFile("factor.zig")));
    try std.testing.expectEqual(8, dependencyDeclarationCount(@embedFile("layout.zig")));
    try std.testing.expectEqual(9, dependencyDeclarationCount(@embedFile("normalization.zig")));
    try std.testing.expectEqual(9, dependencyDeclarationCount(@embedFile("random.zig")));
    try std.testing.expectEqual(9, dependencyDeclarationCount(@embedFile("reduction.zig")));
    try std.testing.expectEqual(8, dependencyDeclarationCount(@embedFile("scan.zig")));
    try std.testing.expectEqual(8, dependencyDeclarationCount(@embedFile("segmented.zig")));
    try std.testing.expectEqual(10, dependencyDeclarationCount(@embedFile("sort.zig")));
    try std.testing.expectEqual(9, dependencyDeclarationCount(@embedFile("spatial.zig")));
    try std.testing.expectEqual(10, dependencyDeclarationCount(@embedFile("stencil.zig")));
}

test "accy kernel library catalog match declaration coverage" {
    std.testing.refAllDecls(match);
    std.testing.refAllDecls(activation);
    std.testing.refAllDecls(attention);
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(compaction);
    std.testing.refAllDecls(factor);
    std.testing.refAllDecls(fused);
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(indexing);
    std.testing.refAllDecls(layout);
    std.testing.refAllDecls(linalg);
    std.testing.refAllDecls(loss);
    std.testing.refAllDecls(normalization);
    std.testing.refAllDecls(random);
    std.testing.refAllDecls(reduction);
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(segmented);
    std.testing.refAllDecls(shape);
    std.testing.refAllDecls(sort);
    std.testing.refAllDecls(sparse);
    std.testing.refAllDecls(spatial);
    std.testing.refAllDecls(stencil);
}
