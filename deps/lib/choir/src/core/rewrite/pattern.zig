const std = @import("std");
const ir = @import("../root.zig");
const PatternRewriter = ir.rewrite.PatternRewriter;

pub const PatternBenefit = u16;

pub const RewritePatternKind = enum {
    rewrite,
    fold,
};

pub const RewritePatternProducts = union(enum) {
    unknown,
    none,
    operations: []const []const u8,
};

pub const RewritePatternSpec = struct {
    name: []const u8,
    root_op_name: []const u8,
    benefit: PatternBenefit = 1,
    kind: RewritePatternKind = .rewrite,
    products: RewritePatternProducts = .unknown,
};

pub const RewritePattern = struct {
    spec: RewritePatternSpec,

    rewrite_fn: *const fn (
        op: *ir.Operation,
        rewriter: *PatternRewriter,
    ) PatternResult,

    match_fn: ?*const fn (op: *ir.Operation) bool,

    order: usize,

    pub fn init(
        spec: RewritePatternSpec,
        rewrite_fn: *const fn (*ir.Operation, *PatternRewriter) PatternResult,
    ) RewritePattern {
        return .{
            .spec = spec,
            .rewrite_fn = rewrite_fn,
            .match_fn = null,
            .order = 0,
        };
    }

    pub fn initWithMatch(
        spec: RewritePatternSpec,
        match_fn: *const fn (*ir.Operation) bool,
        rewrite_fn: *const fn (*ir.Operation, *PatternRewriter) PatternResult,
    ) RewritePattern {
        return .{
            .spec = spec,
            .rewrite_fn = rewrite_fn,
            .match_fn = match_fn,
            .order = 0,
        };
    }

    pub fn matches(self: *const RewritePattern, op: *ir.Operation) bool {
        if (!std.mem.eql(u8, op.name.name, self.spec.root_op_name)) {
            return false;
        }
        return self.matchesAfterRoot(op);
    }

    pub fn matchesAfterRoot(self: *const RewritePattern, op: *ir.Operation) bool {
        if (self.match_fn) |match| {
            return match(op);
        }
        return true;
    }

    pub fn apply(self: *const RewritePattern, op: *ir.Operation, rewriter: *PatternRewriter) PatternResult {
        return self.rewrite_fn(op, rewriter);
    }

    pub fn matchAndRewrite(self: *const RewritePattern, op: *ir.Operation, rewriter: *PatternRewriter) PatternResult {
        if (!self.matches(op)) return .failure;
        return self.apply(op, rewriter);
    }

    pub fn lessThan(_: void, a: RewritePattern, b: RewritePattern) bool {
        if (a.spec.benefit != b.spec.benefit) return a.spec.benefit > b.spec.benefit;
        return a.order < b.order;
    }
};

pub const PatternResult = enum {
    success,
    failure,
};

test "RewritePattern stores inspectable declaration" {
    const pattern = RewritePattern.init(.{
        .name = "test-forward",
        .root_op_name = "test.source",
        .benefit = 9,
        .products = .none,
    }, rewriteNoopForPatternOrder);

    try std.testing.expectEqualStrings("test-forward", pattern.spec.name);
    try std.testing.expectEqualStrings("test.source", pattern.spec.root_op_name);
    try std.testing.expectEqual(@as(PatternBenefit, 9), pattern.spec.benefit);
    try std.testing.expectEqual(.rewrite, pattern.spec.kind);
    switch (pattern.spec.products) {
        .none => {},
        else => return error.TestExpectedNoProducts,
    }
}

fn rewriteNoopForPatternOrder(_: *ir.Operation, _: *PatternRewriter) PatternResult {
    return .failure;
}
