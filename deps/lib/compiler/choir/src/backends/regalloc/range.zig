const std = @import("std");
const ir = @import("../../core/root.zig");
const interval = @import("interval.zig");
const position = @import("position.zig");

pub const Entry = enum {
    resident,
    reload,
};

pub const Exit = enum {
    retain,
    spill,
};

pub fn ValueLocationRange(comptime Register: type) type {
    return struct {
        value: *ir.Value,
        start: u32,
        end: u32,
        reg: Register,
        entry: Entry = .resident,
        end_phase: position.Phase = .definition,
        exit: Exit = .retain,

        const Self = @This();

        pub fn startPhase(self: Self) position.Phase {
            return switch (self.entry) {
                .reload => .source,
                .resident => position.valueStartPhase(self.value),
            };
        }

        pub fn containsPoint(self: Self, point: position.Point) bool {
            if (point.position < self.start or point.position >= self.end) return false;
            if (point.position == self.start and @backingInt(point.phase) < @backingInt(self.startPhase())) return false;
            if (point.position == self.end - 1 and @backingInt(point.phase) > @backingInt(self.end_phase)) return false;
            return true;
        }

        pub fn startPoint(self: Self) position.Point {
            return .{ .position = self.start, .phase = self.startPhase() };
        }

        pub fn endPoint(self: Self) position.Point {
            return .{ .position = self.end - 1, .phase = self.end_phase };
        }

        pub fn overlaps(self: Self, other: Self) bool {
            if (self.start >= self.end or other.start >= other.end) return false;
            const start = @max(self.startPoint().rank(), other.startPoint().rank());
            const end = @min(self.endPoint().rank(), other.endPoint().rank());
            return start <= end;
        }

        pub fn coversValueAt(self: Self, value: *ir.Value, point: position.Point) bool {
            return self.value == value and self.containsPoint(point);
        }

        pub fn blocksRegisterAt(self: Self, reg: Register, point: position.Point) bool {
            return self.reg == reg and self.containsPoint(point);
        }
    };
}

pub fn appendValueLocationRange(
    comptime Register: type,
    ranges: *std.ArrayListUnmanaged(ValueLocationRange(Register)),
    allocator: std.mem.Allocator,
    value: *ir.Value,
    start: u32,
    end: u32,
    reg: Register,
    entry: Entry,
    end_phase: position.Phase,
    exit: Exit,
) !void {
    if (start >= end) return;
    try ranges.append(allocator, .{
        .value = value,
        .start = start,
        .end = end,
        .reg = reg,
        .entry = entry,
        .end_phase = end_phase,
        .exit = exit,
    });
}

pub fn candidateRangeFixedConflictStart(
    comptime Register: type,
    comptime Mask: type,
    candidate: interval.Candidate(Register, Mask),
    fixed_positions: interval.FixedPositionIndex(Register),
    proposed: ValueLocationRange(Register),
) ?position.Point {
    for (fixed_positions.between(proposed.reg, proposed.startPoint(), proposed.endPoint())) |fixed| {
        if (fixed.kind == .source or fixed.kind == .use) continue;
        if (!candidate.ownsFixedPosition(fixed)) return fixed.point;
    }
    return null;
}

pub fn candidateRangeConflictsWithFixedPositions(
    comptime Register: type,
    comptime Mask: type,
    candidate: interval.Candidate(Register, Mask),
    fixed_positions: interval.FixedPositionIndex(Register),
    proposed: ValueLocationRange(Register),
) bool {
    return candidateRangeFixedConflictStart(Register, Mask, candidate, fixed_positions, proposed) != null;
}

test "value location ranges compare phase-aware overlap" {
    var owner: u8 = 0;
    var first_value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };
    var second_value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 1 } },
        .type = undefined,
        .id = 1,
    };

    const Range = ValueLocationRange(u8);
    const resident = Range{
        .value = &first_value,
        .start = 1,
        .end = 3,
        .reg = 1,
        .end_phase = .source,
    };
    const reload = Range{
        .value = &second_value,
        .start = 2,
        .end = 3,
        .reg = 1,
        .entry = .reload,
        .end_phase = .source,
    };
    const late = Range{
        .value = &second_value,
        .start = 2,
        .end = 3,
        .reg = 1,
    };

    try std.testing.expect(resident.overlaps(reload));
    try std.testing.expect(!resident.overlaps(late));
}

test "value location ranges cover values and block registers at points" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };
    var other_value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 1 } },
        .type = undefined,
        .id = 1,
    };

    const Range = ValueLocationRange(u8);
    const range = Range{
        .value = &value,
        .start = 4,
        .end = 5,
        .reg = 2,
    };
    const point = position.Point.definition(4);

    try std.testing.expect(range.coversValueAt(&value, point));
    try std.testing.expect(!range.coversValueAt(&other_value, point));
    try std.testing.expect(range.blocksRegisterAt(2, point));
    try std.testing.expect(!range.blocksRegisterAt(3, point));
}

test "candidate range fixed-position conflict query uses proposed range" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };

    const Candidate = interval.Candidate(u8, u8);
    const UsePosition = interval.UsePosition(u8, u8);
    const FixedPosition = interval.FixedPosition(u8);
    const Range = ValueLocationRange(u8);

    var uses: std.ArrayListUnmanaged(UsePosition) = .empty;
    defer uses.deinit(std.testing.allocator);
    try uses.append(std.testing.allocator, .{
        .point = position.Point.source(4),
        .requirement = .{ .fixed = 2 },
        .source_blockers = 0,
    });

    const candidate = Candidate{
        .value = &value,
        .range = .{ .start = 0, .end = 4, .end_phase = .source },
        .use_positions = uses,
        .definition = .{
            .point = position.Point.definition(0),
            .requirement = .{ .fixed = 1 },
            .source = .any,
        },
        .order = 0,
        .is_constant = false,
    };
    var fixed_positions = [_]FixedPosition{
        .{ .point = position.Point.definition(3), .reg = 1, .kind = .clobber },
        .{ .point = position.Point.source(4), .reg = 2, .kind = .scratch_use },
        .{ .point = position.Point.source(4), .reg = 1, .kind = .use },
    };
    var fixed_position_index_storage: interval.FixedPositionIndex(u8).Storage = undefined;
    const fixed_position_index = interval.FixedPositionIndex(u8).init(&fixed_positions, &fixed_position_index_storage);

    const crosses_clobber = Range{
        .value = &value,
        .start = 2,
        .end = 5,
        .reg = 1,
        .end_phase = .source,
    };
    const after_clobber = Range{
        .value = &value,
        .start = 4,
        .end = 5,
        .reg = 1,
        .end_phase = .source,
    };
    const owned_scratch = Range{
        .value = &value,
        .start = 4,
        .end = 5,
        .reg = 2,
        .end_phase = .source,
    };

    try std.testing.expect(candidateRangeConflictsWithFixedPositions(u8, u8, candidate, fixed_position_index, crosses_clobber));
    try std.testing.expect(!candidateRangeConflictsWithFixedPositions(u8, u8, candidate, fixed_position_index, after_clobber));
    try std.testing.expect(!candidateRangeConflictsWithFixedPositions(u8, u8, candidate, fixed_position_index, owned_scratch));

    const conflict = candidateRangeFixedConflictStart(u8, u8, candidate, fixed_position_index, crosses_clobber) orelse return error.TestFailure;
    try std.testing.expectEqual(position.Point.definition(3), conflict);
    try std.testing.expectEqual(@as(?position.Point, null), candidateRangeFixedConflictStart(u8, u8, candidate, fixed_position_index, after_clobber));
}

test "value location range append skips empty ranges" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };

    const Range = ValueLocationRange(u8);
    var ranges: std.ArrayListUnmanaged(Range) = .empty;
    defer ranges.deinit(std.testing.allocator);

    try appendValueLocationRange(u8, &ranges, std.testing.allocator, &value, 3, 3, 1, .resident, .source, .retain);
    try std.testing.expectEqual(@as(usize, 0), ranges.items.len);

    try appendValueLocationRange(u8, &ranges, std.testing.allocator, &value, 3, 4, 1, .resident, .definition, .retain);
    try std.testing.expectEqual(@as(usize, 1), ranges.items.len);
    try std.testing.expect(ranges.items[0].coversValueAt(&value, position.Point.definition(3)));
}
