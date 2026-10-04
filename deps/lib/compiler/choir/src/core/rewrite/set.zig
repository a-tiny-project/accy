const std = @import("std");
const ir = @import("../root.zig");
const alloc_phase = @import("alloc_phase");
const PatternBenefit = ir.rewrite.PatternBenefit;
const RewritePatternSpec = ir.rewrite.RewritePatternSpec;
const RewritePattern = ir.rewrite.RewritePattern;
const PatternResult = ir.rewrite.PatternResult;
const tryApplyRewritePattern = ir.rewrite.tryApplyRewritePattern;
const PatternRewriter = ir.rewrite.PatternRewriter;
const PatternIndex = ir.rewrite.PatternIndex;

pub const RewritePatternSet = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayListUnmanaged(RewritePattern),
    index: ?PatternIndex,

    pub fn init(allocator: std.mem.Allocator) RewritePatternSet {
        return .{
            .allocator = allocator,
            .patterns = .empty,
            .index = null,
        };
    }

    pub fn deinit(self: *RewritePatternSet) void {
        if (self.index) |*index| index.deinit(self.allocator);
        self.patterns.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *RewritePatternSet, pattern: RewritePattern) !void {
        if (self.index != null) return error.PatternSetSealed;
        var ordered = pattern;
        ordered.order = self.patterns.items.len;
        try self.patterns.append(self.allocator, ordered);
    }

    pub fn ensureUnusedCapacity(self: *RewritePatternSet, additional_count: usize) !void {
        if (self.index != null) return error.PatternSetSealed;
        const required_count = std.math.add(
            usize,
            self.patterns.items.len,
            additional_count,
        ) catch return error.CapacityOverflow;
        try self.patterns.ensureTotalCapacity(self.allocator, required_count);
    }

    pub fn addPattern(
        self: *RewritePatternSet,
        op_name: []const u8,
        rewrite_fn: *const fn (*ir.Operation, *PatternRewriter) PatternResult,
    ) !void {
        try self.add(RewritePattern.init(.{
            .name = op_name,
            .root_op_name = op_name,
        }, rewrite_fn));
    }

    pub fn count(self: *const RewritePatternSet) usize {
        if (self.index) |index| return index.capacity.facts.pattern_count;
        return self.patterns.items.len;
    }

    pub fn seal(self: *RewritePatternSet) !void {
        if (self.index != null) return;
        std.mem.sort(RewritePattern, self.patterns.items, {}, RewritePattern.lessThan);
        const limits = try PatternIndex.Limits.inspect(self.patterns.items);
        var index = try PatternIndex.init(self.allocator, limits);
        errdefer index.deinit(self.allocator);
        try index.activate();
        self.patterns.deinit(self.allocator);
        self.patterns = .empty;
        self.index = index;
    }

    pub fn getMatchingPatterns(self: *const RewritePatternSet, op: *ir.Operation) []const RewritePattern {
        if (self.index) |*index| {
            return index.matching(op.name.name);
        }
        @panic("rewrite pattern set is not sealed");
    }

    pub fn applyFirstMatchingPattern(
        self: *const RewritePatternSet,
        op: *ir.Operation,
        rewriter: *PatternRewriter,
    ) bool {
        for (self.getMatchingPatterns(op)) |*pattern| {
            if (tryApplyRewritePattern(pattern, op, rewriter)) return true;
        }
        return false;
    }
};

test "rewrite pattern builder reuses reserved capacity" {
    const testing = std.testing;

    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(testing.allocator);
    var maybe_patterns: ?RewritePatternSet = RewritePatternSet.init(
        phase_allocator.initializationAllocator(),
    );
    errdefer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_patterns) |*patterns| patterns.deinit();
        if (phase_allocator.phase() == .teardown) phase_allocator.deinit();
    }
    const patterns = &maybe_patterns.?;

    try patterns.ensureUnusedCapacity(3);
    const base_pointer = patterns.patterns.items.ptr;
    phase_allocator.seal();

    try patterns.add(RewritePattern.init(
        testRewriteSpec("test.pattern_a", 1),
        rewriteNoopForPatternOrder,
    ));
    try patterns.add(RewritePattern.init(
        testRewriteSpec("test.pattern_b", 2),
        rewriteNoopForPatternOrder,
    ));
    try patterns.add(RewritePattern.init(
        testRewriteSpec("test.pattern_c", 3),
        rewriteNoopForPatternOrder,
    ));
    try testing.expectEqual(base_pointer, patterns.patterns.items.ptr);
    try testing.expectError(
        error.CapacityOverflow,
        patterns.ensureUnusedCapacity(std.math.maxInt(usize)),
    );
    try testing.expectEqual(
        alloc_phase.PhaseViolations{},
        phase_allocator.violations(),
    );

    phase_allocator.beginTeardown();
    patterns.deinit();
    maybe_patterns = null;
    try testing.expectEqual(
        alloc_phase.PhaseViolations{},
        phase_allocator.violations(),
    );
    phase_allocator.deinit();
}

test "RewritePatternSet seal preserves equal-benefit insertion order per root" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var patterns = RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try patterns.add(RewritePattern.init(testRewriteSpec("test.a", 1), rewriteNoopForPatternOrder));
    try patterns.add(RewritePattern.init(testRewriteSpec("test.b", 1), rewriteNoopForPatternOrder));
    try patterns.add(RewritePattern.init(testRewriteSpec("test.a", 1), rewriteNoopForPatternOrder));

    try patterns.seal();

    try testing.expectEqual(@as(usize, 0), patterns.patterns.items.len);
    try testing.expectEqual(@as(usize, 3), patterns.count());
    const matching_a = patterns.index.?.matching("test.a");
    try testing.expectEqual(@as(usize, 2), matching_a.len);
    try testing.expectEqual(@as(usize, 0), matching_a[0].order);
    try testing.expectEqual(@as(usize, 2), matching_a[1].order);
    const matching_b = patterns.index.?.matching("test.b");
    try testing.expectEqual(@as(usize, 1), matching_b.len);
    try testing.expectEqual(@as(usize, 1), matching_b[0].order);
}

test "RewritePatternSet indexes matching patterns by root operation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const a = try ctx.createOperation(ir.Operation.State.init("test.a", .unknown));
    const b = try ctx.createOperation(ir.Operation.State.init("test.b", .unknown));
    const c = try ctx.createOperation(ir.Operation.State.init("test.c", .unknown));

    var patterns = RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try patterns.add(RewritePattern.init(testRewriteSpec("test.b", 1), rewriteNoopForPatternOrder));
    try patterns.add(RewritePattern.init(testRewriteSpec("test.a", 1), rewriteNoopForPatternOrder));
    try patterns.add(RewritePattern.init(testRewriteSpec("test.a", 2), rewriteNoopForPatternOrder));
    try patterns.seal();

    const a_patterns = patterns.getMatchingPatterns(a);
    try testing.expectEqual(@as(usize, 2), a_patterns.len);
    const first_a = a_patterns[0];
    const second_a = a_patterns[1];
    try testing.expectEqual(@as(PatternBenefit, 2), first_a.spec.benefit);
    try testing.expectEqual(@as(PatternBenefit, 1), second_a.spec.benefit);
    try testing.expectEqualStrings("test.a", first_a.spec.root_op_name);

    const b_patterns = patterns.getMatchingPatterns(b);
    try testing.expectEqual(@as(usize, 1), b_patterns.len);
    try testing.expectEqualStrings("test.b", b_patterns[0].spec.root_op_name);

    try testing.expectEqual(@as(usize, 0), patterns.getMatchingPatterns(c).len);
}

test "rewrite pattern set" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var patterns = RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try patterns.add(RewritePattern.init(testRewriteSpec("arith.addi", 1), dummyRewrite));
    try patterns.add(RewritePattern.init(testRewriteSpec("arith.muli", 2), dummyRewrite));
    try patterns.add(RewritePattern.init(testRewriteSpec("arith.subi", 3), dummyRewrite));

    try testing.expectEqual(@as(usize, 3), patterns.patterns.items.len);

    try patterns.seal();

    try testing.expectEqual(alloc_phase.capacity.Phase.steady, patterns.index.?.phase);
}

fn dummyRewrite(op: *ir.Operation, rewriter: *PatternRewriter) PatternResult {
    rewriter.eraseOp(op) catch return .failure;
    return .success;
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
