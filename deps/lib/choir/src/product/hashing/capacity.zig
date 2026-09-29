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

test "capacity derives exact typed working bytes" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").StableValueNumbering, "numbering_capacity"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").StableHasher, "hasher_capacity"),
        );
    }

    const facts = Facts{
        .value_count = 7,
        .operation_count = 4,
        .region_count = 2,
        .block_count = 3,
        .operation_depth = 3,
        .attribute_depth = 2,
    };
    const capacity = try Capacity.derive(.{ .root = undefined, .facts = facts });
    const value_bytes = 7 * @sizeOf(ValueEntry);
    const operation_bytes = 3 * @sizeOf(OperationFrame);
    const attribute_bytes = 2 * @sizeOf(AttributeFrame);
    try std.testing.expectEqual(value_bytes, capacity.value_bytes);
    try std.testing.expectEqual(operation_bytes, capacity.operation_bytes);
    try std.testing.expectEqual(attribute_bytes, capacity.attribute_bytes);
    try std.testing.expectEqual(
        value_bytes + operation_bytes + attribute_bytes,
        capacity.working_bytes,
    );
}

test "capacity rejects checked arithmetic overflow" {
    const overflowing = Facts{
        .operation_depth = std.math.maxInt(usize),
        .attribute_depth = std.math.maxInt(usize),
    };
    try std.testing.expectError(
        error.CapacityOverflow,
        Capacity.derive(.{ .root = undefined, .facts = overflowing }),
    );
    try std.testing.expectError(
        error.ValueCountOverflow,
        addValues(std.math.maxInt(u32), 1),
    );
    try std.testing.expectError(
        error.CountOverflow,
        addCount(std.math.maxInt(usize), 1),
    );
}

test "inspection enforces operation nesting boundary" {
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();
    var root_state = ir.Operation.State.init("root", location);
    root_state.addRegion();
    const root = try context.createOperation(root_state);
    var current = root;
    for (1..maximum_operation_depth) |_| {
        var child_state = ir.Operation.State.init("child", location);
        child_state.addRegion();
        const child = try context.createOperation(child_state);
        const block = try current.getRegion(0).?.addBlock();
        try block.addOperation(child);
        current = child;
    }
    const limits = try Limits.inspect(root);
    try std.testing.expectEqual(maximum_operation_depth, limits.facts.operation_depth);

    const one_past = try context.createOperation(ir.Operation.State.init("one.past", location));
    const block = try current.getRegion(0).?.addBlock();
    try block.addOperation(one_past);
    try std.testing.expectError(error.NestingLimitExceeded, Limits.inspect(root));
}

test "inspection enforces array attribute nesting boundary" {
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const operation = try context.createOperation(ir.Operation.State.init(
        "array.depth",
        ir.Location.getUnknown(),
    ));
    var attribute = try context.getStringAttr("leaf");
    for (0..maximum_attribute_depth) |_| {
        attribute = try context.getArrayAttr(&.{attribute});
    }
    try operation.setAttr("nested", attribute);
    const limits = try Limits.inspect(operation);
    try std.testing.expectEqual(maximum_attribute_depth, limits.facts.attribute_depth);

    try operation.setAttr("nested", try context.getArrayAttr(&.{attribute}));
    try std.testing.expectError(error.NestingLimitExceeded, Limits.inspect(operation));
}
