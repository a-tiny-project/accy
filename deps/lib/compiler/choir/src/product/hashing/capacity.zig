const std = @import("std");
const alloc_phase = @import("alloc_phase");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");

pub const maximum_operation_depth: usize = 256;
pub const maximum_attribute_depth: usize = 256;

pub const InspectError = error{
    ValueCountOverflow,
    CountOverflow,
    NestingLimitExceeded,
};

pub const Facts = struct {
    value_count: u32 = 0,
    operation_count: usize = 0,
    region_count: usize = 0,
    block_count: usize = 0,
    operation_depth: usize = 0,
    attribute_depth: usize = 0,

    pub fn eql(self: Facts, other: Facts) bool {
        return std.meta.eql(self, other);
    }
};

pub const Limits = struct {
    root: *ir.Operation,
    facts: Facts,

    pub fn inspect(root: *ir.Operation) InspectError!Limits {
        var facts = Facts{};
        try inspectOperation(root, 1, &facts);
        return .{ .root = root, .facts = facts };
    }
};

pub const ValueEntry = struct {
    value: *const ir.Value,
    id: u64,
};

pub const OperationFrame = struct {
    operation: *ir.Operation,
    state: State = .operation,
    region_index: usize = 0,
    block: ?*ir.Block = null,
    child: ?*ir.Operation = null,

    pub const State = enum {
        operation,
        region,
        block,
        child,
    };
};

pub const AttributeFrame = struct {
    values: []const ir.Attribute,
    next_index: usize,
};

pub const Capacity = struct {
    facts: Facts,
    value_bytes: usize,
    operation_bytes: usize,
    attribute_bytes: usize,
    working_bytes: usize,

    pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
        const value_bytes = try checkedMul(limits.facts.value_count, @sizeOf(ValueEntry));
        const operation_bytes = try checkedMul(
            limits.facts.operation_depth,
            @sizeOf(OperationFrame),
        );
        const attribute_bytes = try checkedMul(
            limits.facts.attribute_depth,
            @sizeOf(AttributeFrame),
        );
        const partial = try checkedAdd(value_bytes, operation_bytes);
        const working_bytes = try checkedAdd(partial, attribute_bytes);
        return .{
            .facts = limits.facts,
            .value_bytes = value_bytes,
            .operation_bytes = operation_bytes,
            .attribute_bytes = attribute_bytes,
            .working_bytes = working_bytes,
        };
    }
};

fn inspectOperation(
    operation: *ir.Operation,
    depth: usize,
    facts: *Facts,
) InspectError!void {
    if (depth > maximum_operation_depth) return error.NestingLimitExceeded;
    facts.operation_depth = @max(facts.operation_depth, depth);
    facts.operation_count = try addCount(facts.operation_count, 1);
    facts.value_count = try addValues(facts.value_count, operation.results.items.len);

    var attrs = operation.getAttrs();
    while (attrs.next()) |attr| try inspectAttribute(attr.value, 0, facts);

    for (operation.regions.items) |*region| {
        facts.region_count = try addCount(facts.region_count, 1);
        var block_opaque = region.blocks.head;
        while (block_opaque) |block_ptr| {
            const block: *ir.Block = @ptrCast(@alignCast(block_ptr));
            facts.block_count = try addCount(facts.block_count, 1);
            facts.value_count = try addValues(facts.value_count, block.arguments.items.len);

            var child_opaque = block.operations.head;
            while (child_opaque) |child_ptr| {
                const child: *ir.Operation = @ptrCast(@alignCast(child_ptr));
                try inspectOperation(child, depth + 1, facts);
                child_opaque = child.next_op;
            }
            block_opaque = block.next;
        }
    }
}

fn inspectAttribute(attr: ir.Attribute, depth: usize, facts: *Facts) InspectError!void {
    const array = attr.cast(ir.Attribute.ArrayAttr) orelse return;
    if (array.values.len == 0) return;
    const array_depth = depth + 1;
    if (array_depth > maximum_attribute_depth) return error.NestingLimitExceeded;
    facts.attribute_depth = @max(facts.attribute_depth, array_depth);
    for (array.values) |value| try inspectAttribute(value, array_depth, facts);
}

fn addValues(current: u32, amount: usize) InspectError!u32 {
    const narrowed = std.math.cast(u32, amount) orelse return error.ValueCountOverflow;
    return std.math.add(u32, current, narrowed) catch return error.ValueCountOverflow;
}

fn addCount(current: usize, amount: usize) InspectError!usize {
    return std.math.add(usize, current, amount) catch return error.CountOverflow;
}

fn checkedMul(count: anytype, size: usize) error{CapacityOverflow}!usize {
    const narrowed = std.math.cast(usize, count) orelse return error.CapacityOverflow;
    return std.math.mul(usize, narrowed, size) catch return error.CapacityOverflow;
}

fn checkedAdd(lhs: usize, rhs: usize) error{CapacityOverflow}!usize {
    return std.math.add(usize, lhs, rhs) catch return error.CapacityOverflow;
}
