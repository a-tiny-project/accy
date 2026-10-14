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
