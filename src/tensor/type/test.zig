const std = @import("std");
const namespace = @import("root.zig");
const Dim = namespace.Dim;
const sameDims = namespace.sameDims;
const unionDims = namespace.unionDims;
const axisIndices = namespace.axisIndices;
const removeAxes = namespace.removeAxes;
const contraction = namespace.contraction;

test {
    @import("test_discovery").discover(namespace);
}

test "named type algebra supports the softmax attention derivation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const q = [_]Dim{
        .{ .name = "pos", .extent = 8 },
        .{ .name = "head", .extent = 16 },
    };
    const k = [_]Dim{
        .{ .name = "ctx", .extent = 6 },
        .{ .name = "head", .extent = 16 },
    };
    const v = [_]Dim{
        .{ .name = "ctx", .extent = 6 },
        .{ .name = "val", .extent = 32 },
    };

    const scores = try contraction(allocator, &q, &k, &.{"head"});
    try std.testing.expectEqualStrings("pos", scores.result[0].name);
    try std.testing.expectEqualStrings("ctx", scores.result[1].name);

    const ctx_axis = try axisIndices(allocator, scores.result, &.{"ctx"});
    const row = try removeAxes(allocator, scores.result, ctx_axis);
    try std.testing.expectEqual(@as(usize, 1), row.len);
    try std.testing.expectEqualStrings("pos", row[0].name);

    const back = try unionDims(allocator, scores.result, row);
    try std.testing.expect(sameDims(back, scores.result));

    const out = try contraction(allocator, scores.result, &v, &.{"ctx"});
    try std.testing.expectEqual(@as(usize, 2), out.result.len);
    try std.testing.expectEqualStrings("pos", out.result[0].name);
    try std.testing.expectEqualStrings("val", out.result[1].name);
}

test "accy tensor type declaration coverage" {
    std.testing.refAllDecls(namespace);
}
