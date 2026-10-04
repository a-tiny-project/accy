const std = @import("std");
const ir = @import("../core/root.zig");
const graph_mod = @import("graph.zig");
const pattern_mod = @import("pattern.zig");
const extract_mod = @import("extract.zig");

const ClassId = graph_mod.ClassId;
const Node = graph_mod.Node;
const Graph = graph_mod.Graph;

pub const RewriteContext = struct {
    graph: *Graph,

    pub fn merge(self: *RewriteContext, lhs: ClassId, rhs: ClassId) !bool {
        return self.graph.merge(lhs, rhs);
    }

    pub fn nodes(self: *RewriteContext, id: ClassId) []const Node {
        return self.graph.nodes(id);
    }
};

pub const RewriteFn = *const fn (*RewriteContext, ClassId, *const Node) anyerror!bool;

pub const RewriteRule = struct {
    name: []const u8,
    benefit: u32 = 1,
    apply: RewriteFn,
};

fn rewrite_rule_benefit_greater_than(_: void, lhs: RewriteRule, rhs: RewriteRule) bool {
    return lhs.benefit > rhs.benefit;
}

fn pattern_rule_benefit_greater_than(
    _: void,
    lhs: pattern_mod.Rule,
    rhs: pattern_mod.Rule,
) bool {
    return lhs.benefit > rhs.benefit;
}

pub const RewriteSet = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayListUnmanaged(RewriteRule) = .empty,
    patterns: std.ArrayListUnmanaged(pattern_mod.Rule) = .empty,
    constant_model: ?pattern_mod.ConstantModel = null,
    cost_model: ?extract_mod.CostModel = null,

    pub fn init(allocator: std.mem.Allocator) RewriteSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RewriteSet) void {
        self.rules.deinit(self.allocator);
        self.patterns.deinit(self.allocator);
    }

    pub fn add(self: *RewriteSet, rule: RewriteRule) !void {
        try self.rules.append(self.allocator, rule);
    }

    pub fn addPattern(self: *RewriteSet, rule: pattern_mod.Rule) !void {
        try self.patterns.append(self.allocator, rule);
    }

    pub fn addPatterns(self: *RewriteSet, pattern_rules: []const pattern_mod.Rule) !void {
        try self.patterns.appendSlice(self.allocator, pattern_rules);
    }

    pub fn setConstantModel(self: *RewriteSet, model: pattern_mod.ConstantModel) void {
        self.constant_model = model;
    }

    pub fn setCostModel(self: *RewriteSet, model: extract_mod.CostModel) void {
        self.cost_model = model;
    }

    pub fn resolvedCostModel(self: *const RewriteSet) extract_mod.CostModel {
        var model = self.cost_model orelse extract_mod.CostModel{};
        if (model.constant_op_name == null) {
            if (self.constant_model) |constant_model| {
                model.constant_op_name = constant_model.op_name;
            }
        }
        return model;
    }

    pub fn sortByBenefit(self: *RewriteSet) void {
        std.mem.sort(RewriteRule, self.rules.items, {}, rewrite_rule_benefit_greater_than);
        std.mem.sort(pattern_mod.Rule, self.patterns.items, {}, pattern_rule_benefit_greater_than);
    }
};

pub const CandidateFn = *const fn (?*anyopaque, *ir.Operation) anyerror!bool;
pub const PopulateRulesFn = *const fn (*RewriteSet) anyerror!void;
