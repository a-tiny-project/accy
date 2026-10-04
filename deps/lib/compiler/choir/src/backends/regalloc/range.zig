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
