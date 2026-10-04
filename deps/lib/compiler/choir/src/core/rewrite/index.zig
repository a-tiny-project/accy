const std = @import("std");
const ir = @import("../root.zig");
const alloc_phase = @import("alloc_phase");
const PatternBenefit = ir.rewrite.PatternBenefit;
const RewritePatternSpec = ir.rewrite.RewritePatternSpec;
const RewritePattern = ir.rewrite.RewritePattern;
const PatternResult = ir.rewrite.PatternResult;
const PatternRewriter = ir.rewrite.PatternRewriter;
const RewritePatternSet = ir.rewrite.RewritePatternSet;

const PatternOrdinal = u32;

const PatternRootSlot = struct {
    name: ?[]const u8 = null,
    start: PatternOrdinal = 0,
    len: PatternOrdinal = 0,
};

const pattern_index_alignment = @max(
    @alignOf(PatternRootSlot),
    @alignOf(RewritePattern),
);

const PatternIndexFacts = struct {
    pattern_count: usize,
};

const PatternIndexLimits = struct {
    patterns: []const RewritePattern,
    facts: PatternIndexFacts,

    pub fn inspect(patterns: []const RewritePattern) error{CountOverflow}!PatternIndexLimits {
        if (patterns.len > std.math.maxInt(PatternOrdinal)) return error.CountOverflow;
        return .{
            .patterns = patterns,
            .facts = .{ .pattern_count = patterns.len },
        };
    }
};

const PatternIndexCapacity = struct {
    facts: PatternIndexFacts,
    slot_count: usize,
    slots_offset: usize,
    slots_bytes: usize,
    patterns_offset: usize,
    patterns_bytes: usize,
    working_bytes: usize,

    pub fn derive(limits: PatternIndexLimits) error{CapacityOverflow}!PatternIndexCapacity {
        if (limits.facts.pattern_count > std.math.maxInt(PatternOrdinal)) {
            return error.CapacityOverflow;
        }
        const slot_count = try patternRootSlotCount(limits.facts.pattern_count);
        const slots_bytes = std.math.mul(
            usize,
            slot_count,
            @sizeOf(PatternRootSlot),
        ) catch return error.CapacityOverflow;
        const patterns_bytes = std.math.mul(
            usize,
            limits.facts.pattern_count,
            @sizeOf(RewritePattern),
        ) catch return error.CapacityOverflow;
        var cursor: usize = 0;
        const slots_offset = try placePatternIndexBytes(
            slots_bytes,
            @alignOf(PatternRootSlot),
            &cursor,
        );
        const patterns_offset = try placePatternIndexBytes(
            patterns_bytes,
            @alignOf(RewritePattern),
            &cursor,
        );
        return .{
            .facts = limits.facts,
            .slot_count = slot_count,
            .slots_offset = slots_offset,
            .slots_bytes = slots_bytes,
            .patterns_offset = patterns_offset,
            .patterns_bytes = patterns_bytes,
            .working_bytes = cursor,
        };
    }
};

pub const PatternIndex = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.rewrite_pattern_index",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "load_bounded_rewrite_root_slots_and_exact_sealed_pattern_groups",
                        .lifetime = .steady,
                        .detail = "load-bounded rewrite-root slots and exact sealed pattern groups",
                    },
                },
                .excluded = &.{
                    "geometrically grown rewrite-pattern builder storage",
                    "borrowed root names, rewrite callbacks, IR, and pattern-rewriter state",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "patterns", "patterns"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(PatternRootSlot, "rootslot"),
                    alloc_phase.capacity.bindType(RewritePattern, "rewritepattern"),
                },
                .nodes = &.{
                    .{ .collection = .{ .length = 0 } },
                    .{ .constant = 2 },
                    .{ .scale = .{ .node = 1, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .add = .{ .left = 2, .right = 3 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 4,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "pattern-count, unique-root count, placement arithmetic, or OOM failure leaves the pattern set unsealed and retryable",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "benefit sorting and root-name hashing use standard-library helpers without a transitive allocation-closure certificate",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "pattern indexing is process-local and invokes no callback or operating-system boundary",
                },
            },
            .obligations = &.{
                .{ .key = "pattern_index_capacity", .role = .capacity_model },
                .{ .key = "pattern_index_sealed_reuse_overload", .role = .overload },
                .{ .key = "pattern_index_sealed_reuse_transitive_risk", .role = .transitive_risk },
                .{ .key = "pattern_index_sealed_reuse_foreign_risk", .role = .foreign_risk },
                .{ .key = "pattern_index_oom_retry", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: alloc_phase.capacity.Phase,
    capacity: PatternIndexCapacity,
    source_patterns: ?[]const RewritePattern,
    bytes: []align(pattern_index_alignment) u8,
    slots: []PatternRootSlot,
    grouped_patterns: []RewritePattern,
    root_count: usize,

    pub const Limits = PatternIndexLimits;
    pub const Capacity = PatternIndexCapacity;

    pub fn init(allocator: std.mem.Allocator, limits: PatternIndexLimits) !PatternIndex {
        const capacity = try PatternIndexCapacity.derive(limits);
        const bytes = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(pattern_index_alignment),
            capacity.working_bytes,
        );
        errdefer allocator.free(bytes);
        const slots = patternIndexSlice(
            PatternRootSlot,
            bytes,
            capacity.slots_offset,
            capacity.slot_count,
        );
        @memset(slots, .{});
        const grouped_patterns = patternIndexSlice(
            RewritePattern,
            bytes,
            capacity.patterns_offset,
            capacity.facts.pattern_count,
        );

        var root_count: usize = 0;
        for (limits.patterns) |pattern| {
            const insertion = getOrInsertPatternRoot(slots, pattern.spec.root_op_name);
            root_count += @intFromBool(insertion.inserted);
            slots[insertion.index].len = std.math.add(
                PatternOrdinal,
                slots[insertion.index].len,
                1,
            ) catch unreachable;
        }
        setPatternRootStarts(slots, grouped_patterns.len);
        var source_index = limits.patterns.len;
        while (source_index > 0) {
            source_index -= 1;
            const pattern = limits.patterns[source_index];
            const slot_index = findPatternRootSlotIndex(
                slots,
                pattern.spec.root_op_name,
            ).?;
            std.debug.assert(slots[slot_index].len > 0);
            slots[slot_index].len -= 1;
            const grouped_index = @as(usize, slots[slot_index].start) +
                @as(usize, slots[slot_index].len);
            std.debug.assert(grouped_index < grouped_patterns.len);
            grouped_patterns[grouped_index] = pattern;
        }
        restorePatternRootLengths(slots, grouped_patterns.len);

        const index = PatternIndex{
            .phase = .initialization,
            .capacity = capacity,
            .source_patterns = limits.patterns,
            .bytes = bytes,
            .slots = slots,
            .grouped_patterns = grouped_patterns,
            .root_count = root_count,
        };
        index.assertInvariant();
        return index;
    }

    pub fn activate(self: *PatternIndex) error{ AlreadyActive, InputChanged }!void {
        if (self.phase != .initialization) return error.AlreadyActive;
        if (self.source_patterns == null) return error.InputChanged;
        self.source_patterns = null;
        self.phase = .steady;
        self.assertInvariant();
    }

    pub fn deinit(self: *PatternIndex, allocator: std.mem.Allocator) void {
        if (self.phase == .teardown) @panic("rewrite pattern index teardown is terminal");
        self.assertInvariant();
        self.phase = .teardown;
        allocator.free(self.bytes);
        self.source_patterns = undefined;
        self.bytes = undefined;
        self.slots = undefined;
        self.grouped_patterns = undefined;
        self.root_count = undefined;
    }

    pub fn matching(self: *const PatternIndex, root_name: []const u8) []const RewritePattern {
        self.requireSteady();
        std.debug.assert(self.grouped_patterns.len == self.capacity.facts.pattern_count);
        std.debug.assert(self.slots.len == self.capacity.slot_count);
        const range = self.findRoot(root_name) orelse return &.{};
        const start: usize = @intCast(range.start);
        const len: usize = @intCast(range.len);
        std.debug.assert(start <= self.grouped_patterns.len);
        std.debug.assert(len <= self.grouped_patterns.len - start);
        return self.grouped_patterns[start..][0..len];
    }

    fn findRoot(self: *const PatternIndex, root_name: []const u8) ?PatternRootSlot {
        const slot_index = findPatternRootSlotIndex(self.slots, root_name) orelse
            return null;
        return self.slots[slot_index];
    }

    fn requireSteady(self: *const PatternIndex) void {
        if (self.phase != .steady) @panic("rewrite pattern index is not active");
    }

    fn assertInvariant(self: *const PatternIndex) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(self.bytes.len == self.capacity.working_bytes);
        if (self.phase == .initialization) {
            std.debug.assert(self.source_patterns != null);
            std.debug.assert(self.source_patterns.?.len == self.capacity.facts.pattern_count);
        } else {
            std.debug.assert(self.source_patterns == null);
        }
        std.debug.assert(self.slots.len == self.capacity.slot_count);
        std.debug.assert(self.grouped_patterns.len == self.capacity.facts.pattern_count);
        var root_count: usize = 0;
        var pattern_count: usize = 0;
        for (self.slots) |slot| {
            const name = slot.name orelse continue;
            root_count += 1;
            std.debug.assert(slot.len > 0);
            const start: usize = @intCast(slot.start);
            const len: usize = @intCast(slot.len);
            std.debug.assert(start <= self.grouped_patterns.len);
            std.debug.assert(len <= self.grouped_patterns.len - start);
            pattern_count = std.math.add(usize, pattern_count, len) catch unreachable;
            std.debug.assert(pattern_count <= self.grouped_patterns.len);
            const found = self.findRoot(name).?;
            std.debug.assert(found.start == slot.start);
            std.debug.assert(found.len == slot.len);
        }
        std.debug.assert(root_count == self.root_count);
        std.debug.assert(pattern_count == self.grouped_patterns.len);
        for (self.grouped_patterns, 0..) |_, pattern_index| {
            var containing_ranges: usize = 0;
            for (self.slots) |slot| {
                if (slot.name == null) continue;
                const start: usize = @intCast(slot.start);
                const len: usize = @intCast(slot.len);
                if (pattern_index >= start and pattern_index - start < len) {
                    containing_ranges += 1;
                }
            }
            std.debug.assert(containing_ranges == 1);
        }
    }

    fn matchesPatterns(self: *const PatternIndex) bool {
        if (self.grouped_patterns.len != self.capacity.facts.pattern_count) return false;
        for (self.slots) |slot| {
            const root_name = slot.name orelse continue;
            const start: usize = @intCast(slot.start);
            const len: usize = @intCast(slot.len);
            for (self.grouped_patterns[start..][0..len], 0..) |pattern, group_index| {
                if (!std.mem.eql(
                    u8,
                    root_name,
                    pattern.spec.root_op_name,
                )) return false;
                if (group_index > 0 and RewritePattern.lessThan(
                    {},
                    pattern,
                    self.grouped_patterns[start + group_index - 1],
                )) return false;
            }
        }
        return true;
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(PatternIndex);
}

fn patternRootSlotCount(pattern_count: usize) error{CapacityOverflow}!usize {
    return std.math.mul(usize, pattern_count, 2) catch
        return error.CapacityOverflow;
}

fn patternRootSlotIndex(root_name: []const u8, slot_count: usize) usize {
    std.debug.assert(slot_count > 0);
    const hash = std.hash_map.hashString(root_name);
    const reduced = @as(u128, hash) * @as(u128, slot_count);
    const index: usize = @intCast(reduced >> 64);
    std.debug.assert(index < slot_count);
    return index;
}

const PatternRootInsertion = struct {
    index: usize,
    inserted: bool,
};

fn getOrInsertPatternRoot(slots: []PatternRootSlot, root_name: []const u8) PatternRootInsertion {
    std.debug.assert(slots.len > 0);
    var index = patternRootSlotIndex(root_name, slots.len);
    var remaining = slots.len;
    while (remaining > 0) : (remaining -= 1) {
        std.debug.assert(index < slots.len);
        if (slots[index].name == null) {
            slots[index].name = root_name;
            return .{ .index = index, .inserted = true };
        }
        if (std.mem.eql(u8, slots[index].name.?, root_name)) {
            return .{ .index = index, .inserted = false };
        }
        index += 1;
        if (index == slots.len) index = 0;
    }
    unreachable;
}

fn findPatternRootSlotIndex(slots: []const PatternRootSlot, root_name: []const u8) ?usize {
    if (slots.len == 0) return null;
    var index = patternRootSlotIndex(root_name, slots.len);
    var remaining = slots.len;
    while (remaining > 0) : (remaining -= 1) {
        std.debug.assert(index < slots.len);
        const candidate = slots[index].name orelse return null;
        if (std.mem.eql(u8, candidate, root_name)) return index;
        index += 1;
        if (index == slots.len) index = 0;
    }
    return null;
}

fn setPatternRootStarts(slots: []PatternRootSlot, pattern_count: usize) void {
    var pattern_cursor: usize = 0;
    for (slots) |*slot| {
        if (slot.name == null) continue;
        slot.start = @intCast(pattern_cursor);
        pattern_cursor = std.math.add(
            usize,
            pattern_cursor,
            @as(usize, slot.len),
        ) catch unreachable;
        std.debug.assert(pattern_cursor <= pattern_count);
    }
    std.debug.assert(pattern_cursor == pattern_count);
}

fn restorePatternRootLengths(slots: []PatternRootSlot, pattern_count: usize) void {
    var previous_index: ?usize = null;
    for (slots, 0..) |slot, slot_index| {
        if (slot.name == null) continue;
        std.debug.assert(slot.len == 0);
        if (previous_index) |index| {
            std.debug.assert(slots[index].start < slot.start);
            slots[index].len = slot.start - slots[index].start;
        }
        previous_index = slot_index;
    }
    if (previous_index) |index| {
        std.debug.assert(@as(usize, slots[index].start) < pattern_count);
        slots[index].len = @intCast(pattern_count - @as(usize, slots[index].start));
    } else {
        std.debug.assert(pattern_count == 0);
    }
}

fn placePatternIndexBytes(byte_count: usize, alignment: usize, cursor: *usize) error{CapacityOverflow}!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    const padded = std.math.add(usize, cursor.*, mask) catch return error.CapacityOverflow;
    const offset = padded & ~mask;
    cursor.* = std.math.add(usize, offset, byte_count) catch return error.CapacityOverflow;
    return offset;
}

fn patternIndexSlice(
    comptime T: type,
    bytes: []align(pattern_index_alignment) u8,
    offset: usize,
    count: usize,
) []T {
    if (count == 0) return &.{};
    const byte_count = std.math.mul(usize, count, @sizeOf(T)) catch unreachable;
    std.debug.assert(offset <= bytes.len);
    std.debug.assert(byte_count <= bytes.len - offset);
    const region: []align(@alignOf(T)) u8 = @alignCast(bytes[offset..][0..byte_count]);
    return std.mem.bytesAsSlice(T, region);
}

fn checkRewritePatternIndexInitFailures(allocator: std.mem.Allocator) !void {
    var patterns = RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try patterns.add(RewritePattern.init(
        testRewriteSpec("test.pattern_b", 1),
        rewriteNoopForPatternOrder,
    ));
    try patterns.add(RewritePattern.init(
        testRewriteSpec("test.pattern_a", 2),
        rewriteNoopForPatternOrder,
    ));
    try patterns.add(RewritePattern.init(
        testRewriteSpec("test.pattern_a", 1),
        rewriteNoopForPatternOrder,
    ));
    try patterns.seal();
    try std.testing.expectEqual(
        alloc_phase.capacity.Phase.steady,
        patterns.index.?.phase,
    );
}

fn rewriteNoopForPatternOrder(_: *ir.Operation, _: *PatternRewriter) PatternResult {
    return .failure;
}

fn testRewriteSpec(root_op_name: []const u8, benefit: PatternBenefit) RewritePatternSpec {
    return .{
        .name = root_op_name,
        .root_op_name = root_op_name,
        .benefit = benefit,
    };
}
