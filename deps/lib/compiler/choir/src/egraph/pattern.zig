const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const graph_mod = @import("graph.zig");

const ClassId = graph_mod.ClassId;
const Node = graph_mod.Node;
const Graph = graph_mod.Graph;

pub const max_variables = 4;

pub const Scalar = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,

    pub fn eql(self: Scalar, other: Scalar) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .int => |value| value == other.int,
            .float => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(other.float)),
            .boolean => |value| value == other.boolean,
        };
    }
};

pub const TypeClass = enum {
    integer,
    float,
    boolean,
    other,
};

pub const ClassifyFn = *const fn (ty: ir.Type) TypeClass;
pub const ReadFn = *const fn (attr: ir.Attribute) ?Scalar;
pub const BuildFn = *const fn (ir_ctx: *ir.Context, value: Scalar) anyerror!ir.Attribute;

pub const ConstantStorage = enum {
    attribute,
    properties,
};

pub const ConstantModel = struct {
    op_name: []const u8,
    attr_name: []const u8 = "value",
    classify: ClassifyFn,
    read: ReadFn = readScalar,
    build: BuildFn = buildScalar,
    storage: ConstantStorage = .attribute,
};

pub fn readScalar(attr: ir.Attribute) ?Scalar {
    if (attr.cast(ir.Attribute.IntegerAttr)) |int_attr| return .{ .int = int_attr.getValue() };
    if (attr.cast(ir.Attribute.FloatAttr)) |float_attr| return .{ .float = float_attr.getValue() };
    if (attr.cast(ir.Attribute.BoolAttr)) |bool_attr| return .{ .boolean = bool_attr.getValue() };
    return null;
}

pub fn buildScalar(ir_ctx: *ir.Context, value: Scalar) anyerror!ir.Attribute {
    return switch (value) {
        .int => |int_value| try ir_ctx.getI64Attr(int_value),
        .float => |float_value| try ir_ctx.getF64Attr(float_value),
        .boolean => |bool_value| try ir_ctx.getBoolAttr(bool_value),
    };
}

pub const OpShape = struct {
    name: []const u8,
    operands: []const Pattern,
};

pub const Pattern = union(enum) {
    variable: u8,
    constant: ?Scalar,
    operation: OpShape,
};

pub const TemplateShape = struct {
    name: []const u8,
    operands: []const Template,
};

pub const Template = union(enum) {
    variable: u8,
    constant: Scalar,
    operation: TemplateShape,
};

pub const Rule = struct {
    name: []const u8,
    benefit: u32 = 1,
    classes: ?[]const TypeClass = null,
    lhs: OpShape,
    rhs: Template,
};

pub const Bindings = struct {
    slots: [max_variables]?ClassId = @as([max_variables]?ClassId, @splat(null)),

    pub fn get(self: *const Bindings, variable: u8) ?ClassId {
        return self.slots[variable];
    }

    pub fn set(self: *Bindings, variable: u8, class: ClassId) void {
        self.slots[variable] = class;
    }
};

pub fn classConstant(graph: *Graph, model: *const ConstantModel, class: ClassId) ?Scalar {
    for (graph.nodes(class)) |*node| {
        if (node.kind != .operation) continue;
        if (!std.mem.eql(u8, node.op_name, model.op_name)) continue;
        const attr = node.getAttr(model.attr_name) orelse continue;
        if (model.read(attr)) |value| return value;
    }
    return null;
}

pub fn matchNode(
    graph: *Graph,
    model: *const ConstantModel,
    rule: *const Rule,
    node: *const Node,
    bindings: *Bindings,
) bool {
    if (node.kind != .operation) return false;
    if (!std.mem.eql(u8, node.op_name, rule.lhs.name)) return false;
    if (rule.classes) |classes| {
        if (node.result_types.len == 0) return false;
        const type_class = model.classify(node.result_types[0]);
        if (std.mem.indexOfScalar(TypeClass, classes, type_class) == null) return false;
    }
    return matchOperands(graph, model, rule.lhs.operands, node, bindings);
}

fn matchOperands(
    graph: *Graph,
    model: *const ConstantModel,
    patterns: []const Pattern,
    node: *const Node,
    bindings: *Bindings,
) bool {
    if (patterns.len != node.operands.len) return false;

    const saved = bindings.*;
    var swapped: [2]ClassId = undefined;
    const attempt_count: usize = if (node.commutative and node.operands.len == 2) 2 else 1;

    attempts: for (0..attempt_count) |attempt| {
        bindings.* = saved;
        const operands = if (attempt == 0) node.operands else operands: {
            swapped = .{ node.operands[1], node.operands[0] };
            break :operands swapped[0..];
        };

        for (patterns, operands) |pattern, operand| {
            switch (pattern) {
                .variable => |variable| {
                    if (bindings.get(variable)) |bound| {
                        if (!graph.find(bound).eql(graph.find(operand))) continue :attempts;
                    } else {
                        bindings.set(variable, graph.find(operand));
                    }
                },
                .constant => |expected| {
                    const actual = classConstant(graph, model, operand) orelse continue :attempts;
                    if (expected) |value| {
                        if (!value.eql(actual)) continue :attempts;
                    }
                },
                .operation => |shape| {
                    var matched = false;
                    const class_nodes = graph.nodes(operand);
                    for (class_nodes) |*candidate| {
                        if (candidate.kind != .operation) continue;
                        if (!std.mem.eql(u8, candidate.op_name, shape.name)) continue;
                        if (matchOperands(graph, model, shape.operands, candidate, bindings)) {
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) continue :attempts;
                },
            }
        }
        return true;
    }

    bindings.* = saved;
    return false;
}

pub fn instantiate(
    graph: *Graph,
    ir_ctx: *ir.Context,
    model: *const ConstantModel,
    template: Template,
    bindings: *const Bindings,
    result_types: []ir.Type,
) anyerror!ClassId {
    switch (template) {
        .variable => |variable| {
            const bound = bindings.get(variable) orelse return error.UnboundPatternVariable;
            return graph.find(bound);
        },
        .constant => |value| {
            const attr = try model.build(ir_ctx, value);
            var attributes = [_]ir.NamedAttribute{.{ .name = model.attr_name, .value = attr }};
            var node = Node{
                .kind = .operation,
                .op_name = model.op_name,
                .operands = &.{},
                .result_types = result_types,
                .attributes = attributes[0..],
                .raw_attributes = if (model.storage == .attribute) attributes[0..] else &.{},
                .properties = if (model.storage == .properties) attr else null,
                .commutative = false,
            };
            return graph.addNode(&node);
        },
        .operation => |shape| {
            var operand_classes: [max_variables]ClassId = undefined;
            if (shape.operands.len > operand_classes.len) return error.PatternTooWide;
            for (shape.operands, 0..) |operand_template, index| {
                operand_classes[index] = try instantiate(graph, ir_ctx, model, operand_template, bindings, result_types);
            }

            const commutative = if (ir_ctx.lookupOperation(shape.name)) |info| info.traits.is_commutative else false;
            var node = Node{
                .kind = .operation,
                .op_name = shape.name,
                .operands = operand_classes[0..shape.operands.len],
                .result_types = result_types,
                .attributes = &.{},
                .raw_attributes = &.{},
                .properties = null,
                .commutative = commutative,
            };
            node.normalizeOperands();
            return graph.addNode(&node);
        },
    }
}

pub fn applyRule(
    graph: *Graph,
    ir_ctx: *ir.Context,
    model: *const ConstantModel,
    rule: *const Rule,
    class: ClassId,
    node: *const Node,
) anyerror!bool {
    var bindings = Bindings{};
    if (!matchNode(graph, model, rule, node, &bindings)) return false;
    const rhs_class = try instantiate(graph, ir_ctx, model, rule.rhs, &bindings, node.result_types);
    return graph.merge(class, rhs_class);
}

const test_dialect_mod = @import("../dialects/fixture/root.zig");

fn testClassify(ty: ir.Type) TypeClass {
    const name = ty.getDialectTypeName() orelse return .other;
    if (std.mem.eql(u8, name, "test.i64")) return .integer;
    return .other;
}

const test_model = ConstantModel{
    .op_name = "test.constant",
    .classify = testClassify,
};

fn testGraphContext(allocator: std.mem.Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try test_dialect_mod.registerTestDialect(&ctx);
    _ = try ctx.registerOperation("test.constant", .{});
    _ = try ctx.registerOperation("test.binary", .{ .is_commutative = true });
    return ctx;
}

fn addTestConstant(graph: *Graph, ir_ctx: *ir.Context, i64_type: ir.Type, value: i64) !ClassId {
    const attr = try ir_ctx.getI64Attr(value);
    var attributes = [_]ir.NamedAttribute{.{ .name = "value", .value = attr }};
    var result_types = [_]ir.Type{i64_type};
    var node = Node{
        .kind = .operation,
        .op_name = "test.constant",
        .operands = &.{},
        .result_types = result_types[0..],
        .attributes = attributes[0..],
        .raw_attributes = attributes[0..],
        .properties = null,
        .commutative = false,
    };
    return graph.addNode(&node);
}

fn addTestBinary(graph: *Graph, i64_type: ir.Type, lhs: ClassId, rhs: ClassId) !ClassId {
    var operands = [_]ClassId{ lhs, rhs };
    var result_types = [_]ir.Type{i64_type};
    var node = Node{
        .kind = .operation,
        .op_name = "test.binary",
        .operands = operands[0..],
        .result_types = result_types[0..],
        .attributes = &.{},
        .raw_attributes = &.{},
        .properties = null,
        .commutative = true,
    };
    node.normalizeOperands();
    return graph.addNode(&node);
}

test "scalar float equality distinguishes signed zero" {
    const positive = Scalar{ .float = 0.0 };
    const negative = Scalar{ .float = -0.0 };
    try std.testing.expect(!positive.eql(negative));
    try std.testing.expect(positive.eql(.{ .float = 0.0 }));
    try std.testing.expect(!positive.eql(.{ .int = 0 }));
}

const add_zero_rule = Rule{
    .name = "test-binary-zero",
    .classes = &.{.integer},
    .lhs = .{ .name = "test.binary", .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } },
    .rhs = .{ .variable = 0 },
};

const self_to_zero_rule = Rule{
    .name = "test-binary-self-zero",
    .classes = &.{.integer},
    .lhs = .{ .name = "test.binary", .operands = &.{ .{ .variable = 0 }, .{ .variable = 0 } } },
    .rhs = .{ .constant = .{ .int = 0 } },
};

test "pattern rule merges class with bound variable" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try testGraphContext(allocator);
    defer ctx.deinit(allocator);
    const i64_type = try test_dialect_mod.TestDialect.getI64Type(&ctx);

    var graph = Graph.init(allocator);
    defer graph.deinit();

    const seven = try addTestConstant(&graph, &ctx, i64_type, 7);
    const zero = try addTestConstant(&graph, &ctx, i64_type, 0);
    const sum = try addTestBinary(&graph, i64_type, seven, zero);

    try testing.expect(!graph.find(sum).eql(graph.find(seven)));

    const sum_nodes = graph.nodes(sum);
    var fired = false;
    for (sum_nodes) |*node| {
        if (node.kind != .operation) continue;
        if (!std.mem.eql(u8, node.op_name, "test.binary")) continue;
        fired = try applyRule(&graph, &ctx, &test_model, &add_zero_rule, sum, node);
        break;
    }

    try testing.expect(fired);
    try testing.expect(graph.find(sum).eql(graph.find(seven)));
}

test "pattern rule with commutative swap matches constant on the left" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try testGraphContext(allocator);
    defer ctx.deinit(allocator);
    const i64_type = try test_dialect_mod.TestDialect.getI64Type(&ctx);

    var graph = Graph.init(allocator);
    defer graph.deinit();

    const zero = try addTestConstant(&graph, &ctx, i64_type, 0);
    const seven = try addTestConstant(&graph, &ctx, i64_type, 7);
    const sum = try addTestBinary(&graph, i64_type, zero, seven);

    const sum_nodes = graph.nodes(sum);
    var fired = false;
    for (sum_nodes) |*node| {
        if (node.kind != .operation) continue;
        if (!std.mem.eql(u8, node.op_name, "test.binary")) continue;
        fired = try applyRule(&graph, &ctx, &test_model, &add_zero_rule, sum, node);
        break;
    }

    try testing.expect(fired);
    try testing.expect(graph.find(sum).eql(graph.find(seven)));
}

test "pattern rule instantiates a fresh constant node" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try testGraphContext(allocator);
    defer ctx.deinit(allocator);
    const i64_type = try test_dialect_mod.TestDialect.getI64Type(&ctx);

    var graph = Graph.init(allocator);
    defer graph.deinit();

    const seven = try addTestConstant(&graph, &ctx, i64_type, 7);
    const sum = try addTestBinary(&graph, i64_type, seven, seven);

    const sum_nodes = graph.nodes(sum);
    var fired = false;
    for (sum_nodes) |*node| {
        if (node.kind != .operation) continue;
        if (!std.mem.eql(u8, node.op_name, "test.binary")) continue;
        fired = try applyRule(&graph, &ctx, &test_model, &self_to_zero_rule, sum, node);
        break;
    }

    try testing.expect(fired);
    const merged = classConstant(&graph, &test_model, sum) orelse return error.TestExpectedResult;
    try testing.expect(merged.eql(.{ .int = 0 }));
}

test "pattern rule respects type class guard" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try testGraphContext(allocator);
    defer ctx.deinit(allocator);
    const i64_type = try test_dialect_mod.TestDialect.getI64Type(&ctx);

    var graph = Graph.init(allocator);
    defer graph.deinit();

    const seven = try addTestConstant(&graph, &ctx, i64_type, 7);
    const zero = try addTestConstant(&graph, &ctx, i64_type, 0);
    const sum = try addTestBinary(&graph, i64_type, seven, zero);

    const float_guarded = Rule{
        .name = "float-only",
        .classes = &.{.float},
        .lhs = add_zero_rule.lhs,
        .rhs = add_zero_rule.rhs,
    };

    const sum_nodes = graph.nodes(sum);
    var fired = false;
    for (sum_nodes) |*node| {
        if (node.kind != .operation) continue;
        if (!std.mem.eql(u8, node.op_name, "test.binary")) continue;
        fired = try applyRule(&graph, &ctx, &test_model, &float_guarded, sum, node);
        break;
    }

    try testing.expect(!fired);
    try testing.expect(!graph.find(sum).eql(graph.find(seven)));
}

test "nested pattern matches through operand classes" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try testGraphContext(allocator);
    defer ctx.deinit(allocator);
    const i64_type = try test_dialect_mod.TestDialect.getI64Type(&ctx);

    var graph = Graph.init(allocator);
    defer graph.deinit();

    const seven = try addTestConstant(&graph, &ctx, i64_type, 7);
    const zero = try addTestConstant(&graph, &ctx, i64_type, 0);
    const inner = try addTestBinary(&graph, i64_type, seven, zero);
    const outer = try addTestBinary(&graph, i64_type, inner, zero);

    const nested_rule = Rule{
        .name = "nested-binary-zero",
        .lhs = .{ .name = "test.binary", .operands = &.{
            .{ .operation = .{ .name = "test.binary", .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } } } },
            .{ .constant = .{ .int = 0 } },
        } },
        .rhs = .{ .variable = 0 },
    };

    const outer_nodes = graph.nodes(outer);
    var fired = false;
    for (outer_nodes) |*node| {
        if (node.kind != .operation) continue;
        if (!std.mem.eql(u8, node.op_name, "test.binary")) continue;
        fired = try applyRule(&graph, &ctx, &test_model, &nested_rule, outer, node);
        break;
    }

    try testing.expect(fired);
    try testing.expect(graph.find(outer).eql(graph.find(seven)));
}
