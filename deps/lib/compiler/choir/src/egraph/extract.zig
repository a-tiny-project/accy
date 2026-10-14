const std = @import("std");
const ir = @import("../core/root.zig");
const rewrite = ir.rewrite;
const graph_mod = @import("graph.zig");

const ClassId = graph_mod.ClassId;
const Node = graph_mod.Node;
const Graph = graph_mod.Graph;
const ValueEntry = graph_mod.ValueEntry;

pub const infinite_cost = std.math.maxInt(u64);

pub const OpCost = struct {
    name: []const u8,
    cost: u32,
};

pub const CostModel = struct {
    operation: u32 = 4,
    constant: u32 = 1,
    constant_op_name: ?[]const u8 = null,
    overrides: []const OpCost = &.{},

    pub fn operationCost(self: *const CostModel, op_name: []const u8) u32 {
        for (self.overrides) |entry| {
            if (std.mem.eql(u8, entry.name, op_name)) return entry.cost;
        }
        if (self.constant_op_name) |constant_name| {
            if (std.mem.eql(u8, constant_name, op_name)) return self.constant;
        }
        return self.operation;
    }
};

const Choice = struct {
    cost: u64 = infinite_cost,
    node_cost: u64 = infinite_cost,
    node_index: ?usize = null,
};

pub const Extraction = struct {
    allocator: std.mem.Allocator,
    graph: *Graph,
    model: CostModel,
    choices: []Choice,

    /// Choice-table storage. Temporary materialization paths are charged separately.
    pub fn choiceStorageBound(classes: u64, blocks: u64) !u64 {
        const bytes = try std.math.mul(u64, classes, @sizeOf(Choice));
        return std.math.add(u64, bytes, try std.math.mul(u64, blocks, @alignOf(Choice)));
    }

    pub fn init(allocator: std.mem.Allocator, graph: *Graph, model: CostModel) !Extraction {
        const choices = try allocator.alloc(Choice, graph.classCount());
        @memset(choices, .{});
        return .{
            .allocator = allocator,
            .graph = graph,
            .model = model,
            .choices = choices,
        };
    }

    pub fn deinit(self: *Extraction) void {
        self.allocator.free(self.choices);
    }

    pub fn analyze(self: *Extraction) void {
        for (0..self.graph.classCount()) |index| {
            const id = ClassId{ .index = @intCast(index) };
            const root = self.graph.find(id);
            if (!root.eql(id)) continue;
            if (self.graph.classValues(root).len > 0) {
                self.choices[index].cost = 0;
            }
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (0..self.graph.classCount()) |index| {
                const id = ClassId{ .index = @intCast(index) };
                const root = self.graph.find(id);
                if (!root.eql(id)) continue;

                const slot = &self.choices[index];
                for (self.graph.nodes(root), 0..) |*node, node_index| {
                    if (node.kind != .operation) continue;
                    const cost = self.termCostOfNode(node);
                    if (cost < slot.node_cost) {
                        slot.node_cost = cost;
                        slot.node_index = node_index;
                        changed = true;
                    }
                }
                if (slot.node_cost < slot.cost) {
                    slot.cost = slot.node_cost;
                    changed = true;
                }
            }
        }
    }

    pub fn classCost(self: *Extraction, class: ClassId) u64 {
        const root = self.graph.find(class);
        return self.choices[@intCast(root.index)].cost;
    }

    pub fn nodeCost(self: *Extraction, class: ClassId) u64 {
        const root = self.graph.find(class);
        return self.choices[@intCast(root.index)].node_cost;
    }

    pub fn termCost(self: *Extraction, op_name: []const u8, operand_classes: []const ClassId) u64 {
        var total: u64 = self.model.operationCost(op_name);
        for (operand_classes) |operand| {
            total +|= self.classCost(operand);
        }
        return @min(total, infinite_cost);
    }

    fn termCostOfNode(self: *Extraction, node: *const Node) u64 {
        var total: u64 = self.model.operationCost(node.op_name);
        for (node.operands) |operand| {
            total +|= self.classCost(operand);
        }
        return total;
    }

    pub fn usableValue(
        self: *Extraction,
        class: ClassId,
        order_limit: usize,
        exclude: ?*ir.Value,
    ) ?*ir.Value {
        const root = self.graph.find(class);
        var best: ?ValueEntry = null;
        for (self.graph.classValues(root)) |entry| {
            if (entry.order > order_limit) continue;
            if (exclude != null and entry.value == exclude.?) continue;
            if (best == null or entry.order < best.?.order) best = entry;
        }
        if (best) |entry| return entry.value;
        return null;
    }

    pub fn materialize(
        self: *Extraction,
        rewriter: *rewrite.PatternRewriter,
        class: ClassId,
        before_op: *ir.Operation,
        order_limit: usize,
        exclude: ?*ir.Value,
    ) anyerror!?*ir.Value {
        var visiting = std.AutoHashMapUnmanaged(u32, void).empty;
        defer visiting.deinit(self.allocator);
        return self.materializeClass(rewriter, class, before_op, order_limit, exclude, &visiting);
    }

    fn materializeClass(
        self: *Extraction,
        rewriter: *rewrite.PatternRewriter,
        class: ClassId,
        before_op: *ir.Operation,
        order_limit: usize,
        exclude: ?*ir.Value,
        visiting: *std.AutoHashMapUnmanaged(u32, void),
    ) anyerror!?*ir.Value {
        const root = self.graph.find(class);

        if (self.usableValue(root, order_limit, exclude)) |value| return value;

        if (visiting.contains(root.index)) return null;
        try visiting.put(self.allocator, root.index, {});
        defer _ = visiting.remove(root.index);

        const slot = self.choices[@intCast(root.index)];
        if (slot.node_cost == infinite_cost) return null;
        const node_index = slot.node_index orelse return null;

        const node = self.graph.nodes(root)[node_index];
        if (node.kind != .operation) return null;
        if (node.result_types.len != 1) return null;

        var operand_values: std.ArrayListUnmanaged(*ir.Value) = .empty;
        defer operand_values.deinit(self.allocator);
        try operand_values.ensureTotalCapacity(self.allocator, node.operands.len);
        for (node.operands) |operand| {
            const operand_value = try self.materializeClass(
                rewriter,
                operand,
                before_op,
                order_limit,
                exclude,
                visiting,
            ) orelse return null;
            operand_values.appendAssumeCapacity(operand_value);
        }

        var state = ir.Operation.State.init(node.op_name, before_op.location);
        state.addOperands(operand_values.items);
        state.addTypes(node.result_types);

        if (node.raw_attributes.len > 0) state.addRawAttributes(node.raw_attributes);
        if (node.properties) |properties| try state.setPropertiesAttr(properties);

        rewriter.setInsertionPointBefore(before_op);
        const new_op = try rewriter.ir_ctx.createOperation(state);
        var attached = false;
        defer if (!attached) new_op.erase();
        var declaration = try ir.interfaces.effects.inspect(self.allocator, new_op);
        defer declaration.deinit(self.allocator);
        if (new_op.hasTrait("is_terminator")) return null;
        if (new_op.hasInterface(ir.interfaces.SymbolOpInterface)) return null;
        if (!ir.interfaces.effects.duplicate(declaration.facts, .{})) return null;
        _ = try rewriter.insert(new_op);
        attached = true;
        const result = new_op.getResult(0) orelse return null;
        try self.graph.attachValue(root, result, 0, order_limit);
        return result;
    }
};
