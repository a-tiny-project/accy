const ir = @import("../../core/root.zig");

pub const Phase = enum(u1) {
    source,
    definition,
};

pub const Point = struct {
    position: u32,
    phase: Phase,

    pub fn source(position: u32) Point {
        return .{ .position = position, .phase = .source };
    }

    pub fn definition(position: u32) Point {
        return .{ .position = position, .phase = .definition };
    }

    pub fn rank(self: Point) u64 {
        return (@as(u64, self.position) << 1) | @backingInt(self.phase);
    }

    pub fn lessThan(self: Point, other: Point) bool {
        return self.rank() < other.rank();
    }

    pub fn greaterThan(self: Point, other: Point) bool {
        return self.rank() > other.rank();
    }
};

pub fn valueStartPhase(value: *const ir.Value) Phase {
    return switch (value.kind) {
        .block_argument => .source,
        .op_result => .definition,
    };
}

test "position points order source before definition" {
    const std = @import("std");
    const source = Point.source(4);
    const definition = Point.definition(4);
    try std.testing.expect(source.lessThan(definition));
    try std.testing.expect(definition.greaterThan(source));
}
