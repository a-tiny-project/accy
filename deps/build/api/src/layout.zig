const std = @import("std");

const StructInner = struct {
    a: [32]u8 = @splat(0),
    b: u64 align(1) = 0,
};

const StructOuter = struct {
    x: u8 = 0,
    inner: StructInner = .{},
    tail: [16]u8 = @splat(1),
};

const UnionInner = union(enum) {
    value: u64 align(1),
};

const UnionOuter = struct {
    x: u8 = 0,
    inner: UnionInner = .{ .value = 0 },
    tail: [16]u8 = @splat(1),
};

fn expectTrailingOnes(tail: *const [16]u8) !void {
    const ones: [16]u8 = @splat(1);
    try std.testing.expectEqualSlices(u8, &ones, tail);
}

test "under-aligned struct field keeps trailing constant bytes" {
    var literal = StructOuter{};
    _ = &literal;
    try expectTrailingOnes(&literal.tail);

    const template: StructOuter = .{};
    _ = &template;
    var copied = template;
    _ = &copied;
    try expectTrailingOnes(&copied.tail);
}

test "under-aligned union field keeps trailing constant bytes" {
    var literal = UnionOuter{};
    _ = &literal;
    try expectTrailingOnes(&literal.tail);

    const template: UnionOuter = .{};
    _ = &template;
    var copied = template;
    _ = &copied;
    try expectTrailingOnes(&copied.tail);
}
