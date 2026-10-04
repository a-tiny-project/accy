const std = @import("std");
const ir = @import("../../core/root.zig");
const position = @import("position.zig");

pub fn Requirement(comptime Register: type) type {
    return union(enum) {
        any,
        fixed: Register,
    };
}

pub const Range = struct {
    start: u32,
    end: u32,
    end_phase: position.Phase,
};

pub fn UsePosition(comptime Register: type, comptime Mask: type) type {
    const RequirementType = Requirement(Register);

    return struct {
        point: position.Point,
        requirement: RequirementType,
        source_blockers: Mask,
    };
}

pub fn DefinitionPosition(comptime Register: type) type {
    const RequirementType = Requirement(Register);

    return struct {
        point: position.Point,
        requirement: RequirementType,
        source: RequirementType,
    };
}

pub const FixedPositionKind = enum {
    source,
    use,
    scratch_use,
    def,
    clobber,
};

pub fn FixedPosition(comptime Register: type) type {
    return struct {
        point: position.Point,
        reg: Register,
        kind: FixedPositionKind,
    };
}

pub fn FixedPositionIndex(comptime Register: type) type {
    const FixedPositionType = FixedPosition(Register);
    const register_count = switch (@typeInfo(Register)) {
        .@"enum" => |info| info.field_names.len,
        .int => 0,
        else => @compileError("register type must be an integer or enum"),
    };

    return struct {
        positions: []const FixedPositionType,
        register_spans: *const Storage,

        const Self = @This();
        pub const RegisterSpan = struct {
            start: usize = 0,
            end: usize = 0,
        };
        pub const Storage = [register_count]RegisterSpan;
        const empty_register_spans = @as([register_count]RegisterSpan, @splat(.{}));

        pub fn init(positions: []FixedPositionType, register_spans: *Storage) Self {
            std.mem.sort(FixedPositionType, positions, {}, lessThan);
            register_spans.* = @as([register_count]RegisterSpan, @splat(.{}));
            if (comptime register_count != 0) {
                for (positions, 0..) |fixed, index| {
                    const span = &register_spans[registerIndex(fixed.reg)];
                    if (span.end == 0) span.start = index;
                    span.end = index + 1;
                }
            }
            return .{ .positions = positions, .register_spans = register_spans };
        }

        pub fn empty() Self {
            return .{ .positions = &.{}, .register_spans = &empty_register_spans };
        }

        pub fn between(self: Self, reg: Register, start: position.Point, end: position.Point) []const FixedPositionType {
            if (comptime register_count != 0) {
                const span = self.register_spans[registerIndex(reg)];
                const register_positions = self.positions[span.start..span.end];
                const first = pointLowerBound(register_positions, start.rank());
                const last = pointLowerBound(register_positions, end.rank() + 1);
                return register_positions[first..last];
            }
            const first = self.lowerBound(reg, start.rank());
            const last = self.lowerBound(reg, end.rank() + 1);
            return self.positions[first..last];
        }

        fn pointLowerBound(positions: []const FixedPositionType, rank: u64) usize {
            var low: usize = 0;
            var high = positions.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (positions[middle].point.rank() < rank) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            return low;
        }

        fn lowerBound(self: Self, reg: Register, rank: u64) usize {
            var low: usize = 0;
            var high = self.positions.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const fixed = self.positions[middle];
                const order = registerOrder(fixed.reg, reg);
                if (order == .lt or (order == .eq and fixed.point.rank() < rank)) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            return low;
        }

        fn lessThan(_: void, lhs: FixedPositionType, rhs: FixedPositionType) bool {
            const order = registerOrder(lhs.reg, rhs.reg);
            if (order != .eq) return order == .lt;
            if (lhs.point.rank() != rhs.point.rank()) return lhs.point.lessThan(rhs.point);
            return @backingInt(lhs.kind) < @backingInt(rhs.kind);
        }

        fn registerIndex(reg: Register) usize {
            const info = switch (@typeInfo(Register)) {
                .@"enum" => |info| info,
                else => unreachable,
            };
            inline for (info.field_values, 0..) |field_value, index| {
                if (@backingInt(reg) == field_value) return index;
            }
            unreachable;
        }

        fn registerOrder(lhs: Register, rhs: Register) std.math.Order {
            return switch (@typeInfo(Register)) {
                .@"enum" => std.math.order(@backingInt(lhs), @backingInt(rhs)),
                .int => std.math.order(lhs, rhs),
                else => @compileError("register type must be an integer or enum"),
            };
        }
    };
}

pub fn fixedPositionPoint(raw_position: u32, kind: FixedPositionKind) position.Point {
    return switch (kind) {
        .source, .use, .scratch_use => position.Point.source(raw_position),
        .def, .clobber => position.Point.definition(raw_position),
    };
}

pub fn Candidate(comptime Register: type, comptime Mask: type) type {
    const RequirementType = Requirement(Register);
    const UsePositionType = UsePosition(Register, Mask);
    const DefinitionPositionType = DefinitionPosition(Register);
    const FixedPositionType = FixedPosition(Register);

    return struct {
        value: *ir.Value,
        range: Range,
        use_positions: std.ArrayListUnmanaged(UsePositionType),
        definition: DefinitionPositionType,
        order: u32,
        is_constant: bool,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.use_positions.deinit(allocator);
        }

        pub fn start(self: Self) u32 {
            return self.range.start;
        }

        pub fn startPoint(self: Self) position.Point {
            return .{ .position = self.range.start, .phase = position.valueStartPhase(self.value) };
        }

        pub fn end(self: Self) u32 {
            return self.range.end;
        }

        pub fn endPhase(self: Self) position.Phase {
            return self.range.end_phase;
        }

        pub fn endPoint(self: Self) position.Point {
            return .{ .position = self.end(), .phase = self.endPhase() };
        }

        pub fn locationRangeEnd(self: Self) u32 {
            return self.end() + 1;
        }

        pub fn containsPoint(self: Self, point: position.Point) bool {
            if (point.position < self.start() or point.position > self.end()) return false;
            if (point.position == self.start() and @backingInt(point.phase) < @backingInt(position.valueStartPhase(self.value))) return false;
            if (point.position == self.end() and @backingInt(point.phase) > @backingInt(self.endPhase())) return false;
            return true;
        }

        pub fn requirementMatchesReg(requirement: RequirementType, reg: Register) bool {
            return switch (requirement) {
                .any => false,
                .fixed => |fixed| fixed == reg,
            };
        }

        pub fn ownsFixedPosition(self: Self, fixed: FixedPositionType) bool {
            return switch (fixed.kind) {
                .use => {
                    if (self.definition.point.rank() == fixed.point.rank() and
                        requirementMatchesReg(self.definition.requirement, fixed.reg)) return true;
                    return self.ownsUsePosition(fixed.point, fixed.reg);
                },
                .scratch_use => self.ownsUsePosition(fixed.point, fixed.reg),
                .source => self.definition.point.rank() == fixed.point.rank() and requirementMatchesReg(self.definition.source, fixed.reg),
                .def => self.definition.point.rank() == fixed.point.rank() and requirementMatchesReg(self.definition.requirement, fixed.reg),
                .clobber => self.definition.point.rank() == fixed.point.rank() and
                    self.startPoint().rank() == fixed.point.rank() and
                    requirementMatchesReg(self.definition.requirement, fixed.reg),
            };
        }

        pub fn fixedPositionConflicts(self: Self, fixed: FixedPositionType, reg: Register) bool {
            if (fixed.kind == .source or fixed.kind == .use) return false;
            if (fixed.reg != reg) return false;
            if (!self.containsPoint(fixed.point)) return false;
            return !self.ownsFixedPosition(fixed);
        }

        pub fn conflictsWithFixedPositions(self: Self, fixed_positions: FixedPositionIndex(Register), reg: Register) bool {
            for (fixed_positions.between(reg, self.startPoint(), self.endPoint())) |fixed| {
                if (self.fixedPositionConflicts(fixed, reg)) return true;
            }
            return false;
        }

        pub fn useCount(self: Self) usize {
            return self.use_positions.items.len;
        }

        pub fn usesAt(self: Self, point: position.Point) []const UsePositionType {
            const first = self.useLowerBound(point.rank());
            const last = self.useUpperBound(point.rank());
            return self.use_positions.items[first..last];
        }

        pub fn usesBetween(self: Self, start_point: position.Point, end_point: position.Point) []const UsePositionType {
            if (end_point.lessThan(start_point)) return self.use_positions.items[0..0];
            const first = self.useLowerBound(start_point.rank());
            const last = self.useUpperBound(end_point.rank());
            return self.use_positions.items[first..last];
        }

        pub fn firstUse(self: Self) ?UsePositionType {
            return if (self.use_positions.items.len == 0) null else self.use_positions.items[0];
        }

        pub fn firstUseAtOrAfter(self: Self, point: position.Point) ?UsePositionType {
            const first = self.useLowerBound(point.rank());
            return if (first == self.use_positions.items.len) null else self.use_positions.items[first];
        }

        pub fn recordUse(
            self: *Self,
            allocator: std.mem.Allocator,
            point: position.Point,
            requirement: RequirementType,
            source_blockers: Mask,
        ) !void {
            const use = UsePositionType{
                .point = point,
                .requirement = requirement,
                .source_blockers = source_blockers,
            };
            const len = self.use_positions.items.len;
            if (len == 0 or self.use_positions.items[len - 1].point.rank() <= point.rank()) {
                try self.use_positions.append(allocator, use);
            } else {
                try self.use_positions.insert(allocator, self.useUpperBound(point.rank()), use);
            }
            if (point.greaterThan(self.endPoint())) {
                self.range.end = point.position;
                self.range.end_phase = point.phase;
            }
        }

        fn useLowerBound(self: Self, rank: u64) usize {
            var low: usize = 0;
            var high = self.use_positions.items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (self.use_positions.items[middle].point.rank() < rank) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            return low;
        }

        fn useUpperBound(self: Self, rank: u64) usize {
            var low: usize = 0;
            var high = self.use_positions.items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (self.use_positions.items[middle].point.rank() <= rank) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            return low;
        }

        fn ownsUsePosition(self: Self, point: position.Point, reg: Register) bool {
            const rank = point.rank();
            var index = self.useLowerBound(rank);
            while (index < self.use_positions.items.len) : (index += 1) {
                const use = self.use_positions.items[index];
                if (use.point.rank() != rank) return false;
                if (requirementMatchesReg(use.requirement, reg)) return true;
            }
            return false;
        }

        pub fn before(_: void, a: Self, b: Self) bool {
            if (a.startPoint().rank() != b.startPoint().rank()) return a.startPoint().lessThan(b.startPoint());
            if (a.endPoint().rank() != b.endPoint().rank()) return a.endPoint().lessThan(b.endPoint());
            if (a.is_constant != b.is_constant) return !a.is_constant;
            return a.order < b.order;
        }
    };
}

pub fn Candidates(comptime Register: type, comptime Mask: type) type {
    const CandidateType = Candidate(Register, Mask);

    return struct {
        items: std.ArrayListUnmanaged(CandidateType) = .empty,
        by_value: std.AutoHashMapUnmanaged(*ir.Value, usize) = .empty,

        const Self = @This();

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.items.items) |*candidate| candidate.deinit(allocator);
            self.items.deinit(allocator);
            self.by_value.deinit(allocator);
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, candidate: CandidateType) !void {
            const candidate_index = self.items.items.len;
            try self.items.append(allocator, candidate);
            errdefer _ = self.items.pop();
            try self.by_value.putNoClobber(allocator, candidate.value, candidate_index);
        }

        pub fn getPtr(self: *Self, value: *ir.Value) ?*CandidateType {
            const candidate_index = self.by_value.get(value) orelse return null;
            return &self.items.items[candidate_index];
        }

        pub fn sort(self: *Self) void {
            std.mem.sort(CandidateType, self.items.items, {}, CandidateType.before);
            for (self.items.items, 0..) |candidate, candidate_index| {
                self.by_value.getPtr(candidate.value).?.* = candidate_index;
            }
        }

        pub fn slice(self: *Self) []CandidateType {
            return self.items.items;
        }
    };
}

pub fn Active(comptime Register: type) type {
    return struct {
        start: u32,
        end: u32,
        end_phase: position.Phase,
        reg: Register,
        candidate_index: usize,

        const Self = @This();

        pub fn endPoint(self: Self) position.Point {
            return .{ .position = self.end, .phase = self.end_phase };
        }
    };
}

pub fn ActiveSet(comptime Register: type) type {
    const ActiveType = Active(Register);

    return struct {
        items: std.ArrayListUnmanaged(ActiveType) = .empty,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, active: ActiveType) !void {
            try self.items.append(allocator, active);
        }

        pub fn containsRegister(self: Self, reg: Register) bool {
            for (self.items.items) |entry| {
                if (entry.reg == reg) return true;
            }
            return false;
        }

        pub fn slice(self: Self) []const ActiveType {
            return self.items.items;
        }

        pub fn swapRemove(self: *Self, index: usize) ActiveType {
            return self.items.swapRemove(index);
        }

        pub fn pop(self: *Self) ?ActiveType {
            return self.items.pop();
        }

        pub fn takeExpiredBefore(self: *Self, point: position.Point) ?ActiveType {
            var i: usize = 0;
            while (i < self.items.items.len) {
                if (self.items.items[i].endPoint().lessThan(point)) return self.items.swapRemove(i);
                i += 1;
            }
            return null;
        }
    };
}

pub fn firstAvailableRegister(comptime Register: type, active: ActiveSet(Register), homes: []const Register, policy: anytype) ?Register {
    for (homes) |reg| {
        if (active.containsRegister(reg)) continue;
        if (policy.blocksRegister(reg)) continue;
        return reg;
    }
    return null;
}

pub fn AvailableRegister(comptime Register: type) type {
    return struct {
        reg: Register,
        until: position.Point,
    };
}

pub fn bestAvailableRegister(comptime Register: type, active: ActiveSet(Register), homes: []const Register, policy: anytype) ?AvailableRegister(Register) {
    var best: ?AvailableRegister(Register) = null;
    for (homes) |reg| {
        if (active.containsRegister(reg)) continue;
        const until = policy.availableUntil(reg) orelse continue;
        if (best) |current| {
            if (current.until.lessThan(until)) best = .{ .reg = reg, .until = until };
        } else {
            best = .{ .reg = reg, .until = until };
        }
    }
    return best;
}

pub fn evictionCandidateIndex(
    comptime Register: type,
    comptime CandidateType: type,
    active: []const Active(Register),
    candidates: []const CandidateType,
    policy: anytype,
) ?usize {
    var victim_index: ?usize = null;
    for (active, 0..) |entry, index| {
        if (policy.blocksRegister(entry.reg)) continue;
        const victim = candidates[entry.candidate_index];
        if (!policy.canEvict(victim)) continue;
        if (victim_index) |current_index| {
            const current = candidates[active[current_index].candidate_index];
            if (policy.prefersVictim(victim, current)) victim_index = index;
        } else {
            victim_index = index;
        }
    }
    return victim_index;
}
