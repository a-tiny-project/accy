const std = @import("std");
const alloc_arena = @import("alloc_arena");
const alloc_phase = @import("alloc_phase");
const ir = @import("../../core/root.zig");
const hashing = @import("root.zig");
const capacity_model = hashing.capacity;
const index_model = hashing.index;
const walk = hashing.walk;

const Allocator = std.mem.Allocator;

pub const StableValueNumbering = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.stable_value_numbering",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "valueentry_array_operationframe_array_and_attributeframe_array",
                        .lifetime = .steady,
                        .detail = "ValueEntry array, OperationFrame array, and AttributeFrame array",
                    },
                },
                .excluded = &.{
                    "borrowed mutable IR and every referenced Value, type, and attribute payload",
                    "generic fingerprint builder storage and side effects",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "facts_value_count", "facts.value_count"),
                    alloc_phase.capacity.bindInput(Limits, "facts_operation_depth", "facts.operation_depth"),
                    alloc_phase.capacity.bindInput(Limits, "facts_attribute_depth", "facts.attribute_depth"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(capacity_model.ValueEntry, "valueentry"),
                    alloc_phase.capacity.bindType(capacity_model.OperationFrame, "operationframe"),
                    alloc_phase.capacity.bindType(capacity_model.AttributeFrame, "attributeframe"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .input = 2 },
                    .{ .scale = .{ .node = 4, .coefficient = .{ .size_of_concrete_type = 2 } } },
                    .{ .add = .{ .left = 1, .right = 3 } },
                    .{ .add = .{ .left = 6, .right = 5 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 7,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "nesting, arithmetic, OOM, or definition drift rejects before activation; there is no steady exhaustion",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "updateSubtreeFingerprint invokes unconstrained anytype builder methods and an indirect inherent-property hook",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "generic builder and property hook implementations may reacquire allocator policy or cross foreign boundaries",
                },
            },
            .obligations = &.{
                .{ .key = "numbering_capacity", .role = .capacity_model },
                .{ .key = "numbering_sealed_repeat_overload", .role = .overload },
                .{ .key = "numbering_sealed_repeat_transitive_risk", .role = .transitive_risk },
                .{ .key = "numbering_sealed_repeat_foreign_risk", .role = .foreign_risk },
                .{ .key = "numbering_oom_retry", .role = .overload },
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
    capacity: Capacity,
    root: *ir.Operation,
    index: index_model.ValueIndex,
    operation_frames: []capacity_model.OperationFrame,
    attribute_frames: []capacity_model.AttributeFrame,

    pub const Limits = capacity_model.Limits;
    pub const Capacity = capacity_model.Capacity;

    const Self = @This();

    pub fn init(allocator: Allocator, limits: Limits) !Self {
        const current = Limits.inspect(limits.root) catch return error.InputChanged;
        if (!limits.facts.eql(current.facts)) return error.InputChanged;
        const derived = try Capacity.derive(limits);
        var index = try index_model.ValueIndex.init(allocator, derived);
        errdefer index.deinit(allocator);
        const operation_frames = try allocator.alloc(
            capacity_model.OperationFrame,
            derived.facts.operation_depth,
        );
        errdefer allocator.free(operation_frames);
        const attribute_frames = try allocator.alloc(
            capacity_model.AttributeFrame,
            derived.facts.attribute_depth,
        );
        errdefer allocator.free(attribute_frames);
        try index.fill(limits.root, operation_frames);
        return .{
            .phase = .initialization,
            .capacity = derived,
            .root = limits.root,
            .index = index,
            .operation_frames = operation_frames,
            .attribute_frames = attribute_frames,
        };
    }

    pub fn activate(self: *Self) error{ AlreadyActive, InputChanged }!void {
        if (self.phase != .initialization) return error.AlreadyActive;
        const current = Limits.inspect(self.root) catch return error.InputChanged;
        if (!self.capacity.facts.eql(current.facts)) return error.InputChanged;
        if (!self.index.matchesDefinitions(self.root, self.operation_frames)) {
            return error.InputChanged;
        }
        self.phase = .steady;
    }

    pub fn valueId(self: *const Self, value: *const ir.Value) ?u64 {
        self.requireSteady();
        return self.index.lookup(value);
    }

    pub fn updateSubtreeFingerprint(
        self: *Self,
        builder: anytype,
        operation: *ir.Operation,
    ) void {
        self.requireSteady();
        if (!self.root.isAncestor(operation)) {
            @panic("stable value numbering subtree is outside its indexed root");
        }
        var iterator = walk.Iterator.init(self.operation_frames, operation);
        while (iterator.next()) |event| switch (event) {
            .operation => |op| self.updateOperation(builder, op),
            .region => |region| updateRegion(builder, region),
            .block => |block| self.updateBlock(builder, block),
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        if (self.phase == .teardown) @panic("stable value numbering teardown is terminal");
        self.phase = .teardown;
        allocator.free(self.attribute_frames);
        allocator.free(self.operation_frames);
        self.index.deinit(allocator);
        self.root = undefined;
        self.operation_frames = undefined;
        self.attribute_frames = undefined;
    }

    fn updateOperation(
        self: *Self,
        builder: anytype,
        operation: *ir.Operation,
    ) void {
        builder.updateBytes(operation.getName().name);

        builder.updateUsize(operation.getNumAttrs());
        var attrs = operation.getAttrs();
        while (attrs.next()) |attr| {
            builder.updateBytes(attr.name);
            updateAttributeFingerprint(builder, attr.value, self.attribute_frames);
        }

        builder.updateU64(operation.getNumResults());
        for (operation.results.items) |*result| {
            updateTypeFingerprint(builder, result.type);
            self.updateNumberedValue(builder, result);
        }

        builder.updateU64(operation.getNumOperands());
        for (operation.operands.items) |operand| {
            self.updateNumberedValue(builder, operand.value);
        }
        builder.updateU64(operation.getNumRegions());
    }

    fn updateBlock(
        self: *Self,
        builder: anytype,
        block: *ir.Block,
    ) void {
        builder.updateU64(block.getNumArguments());
        for (block.arguments.items) |argument| {
            updateTypeFingerprint(builder, argument.type);
            self.updateNumberedValue(builder, argument);
        }

        var operation_count: usize = 0;
        var operation_opaque = block.operations.head;
        while (operation_opaque) |operation_ptr| {
            operation_count += 1;
            const operation: *ir.Operation = @ptrCast(@alignCast(operation_ptr));
            operation_opaque = operation.next_op;
        }
        builder.updateUsize(operation_count);
    }

    fn updateNumberedValue(
        self: *const Self,
        builder: anytype,
        value: *const ir.Value,
    ) void {
        if (self.valueId(value)) |id| {
            builder.updateBool(true);
            builder.updateU64(id);
        } else {
            builder.updateBool(false);
            builder.updateU64(std.math.maxInt(u64));
        }
    }

    fn requireSteady(self: *const Self) void {
        if (self.phase != .steady) {
            @panic("stable value numbering used outside its steady phase");
        }
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(StableValueNumbering);
}

fn updateRegion(builder: anytype, region: *ir.Region) void {
    var block_count: usize = 0;
    var block_opaque = region.blocks.head;
    while (block_opaque) |block_ptr| {
        block_count += 1;
        const block: *ir.Block = @ptrCast(@alignCast(block_ptr));
        block_opaque = block.next;
    }
    builder.updateUsize(block_count);
}

fn updateTypeFingerprint(builder: anytype, typ: ir.Type) void {
    if (typ.getDialectStorage()) |storage| {
        builder.updateBool(true);
        builder.updateBytes(storage.name);
        builder.updateBytes(storage.param_key);
        return;
    }
    builder.updateBool(false);
    builder.updateU64(@intFromPtr(typ.impl));
}

fn updateAttributeFingerprint(
    builder: anytype,
    root: ir.Attribute,
    frames: []capacity_model.AttributeFrame,
) void {
    var current: ?ir.Attribute = root;
    var depth: usize = 0;
    while (true) {
        if (current) |attr| {
            builder.updateU64(@backingInt(attr.attr_id));
            builder.updateBytes(attr.abstract.name);

            if (attr.cast(ir.Attribute.IntegerAttr)) |integer| {
                builder.updateU64(@bitCast(integer.value));
                builder.updateU64(integer.width);
                builder.updateBool(integer.is_signed);
            } else if (attr.cast(ir.Attribute.FloatAttr)) |float| {
                builder.updateU64(@bitCast(float.value));
                builder.updateU64(float.width);
            } else if (attr.cast(ir.Attribute.BoolAttr)) |boolean| {
                builder.updateBool(boolean.value);
            } else if (attr.cast(ir.Attribute.StringAttr)) |string| {
                builder.updateBytes(string.value);
            } else if (attr.cast(ir.Attribute.SymbolRefAttr)) |symbol| {
                builder.updateBytes(symbol.root_reference);
                builder.updateUsize(symbol.nested_references.len);
                for (symbol.nested_references) |nested| builder.updateBytes(nested);
            } else if (attr.cast(ir.Attribute.StringListAttr)) |list| {
                builder.updateUsize(list.values.len);
                for (list.values) |value| builder.updateBytes(value);
            } else if (attr.cast(ir.Attribute.TypeListAttr)) |list| {
                builder.updateUsize(list.values.len);
                for (list.values) |typ| updateTypeFingerprint(builder, typ);
            } else if (attr.cast(ir.Attribute.ArrayAttr)) |array| {
                builder.updateUsize(array.values.len);
                if (array.values.len > 0) {
                    if (depth >= frames.len) {
                        @panic("attribute traversal exceeded inspected depth");
                    }
                    frames[depth] = .{ .values = array.values, .next_index = 1 };
                    depth += 1;
                    current = array.values[0];
                    continue;
                }
            } else if (attr.cast(ir.Attribute.DialectAttr)) |dialect| {
                builder.updateBytes(dialect.payload);
            } else {
                builder.updateU64(@intFromPtr(attr.impl));
            }
        }

        current = null;
        while (depth > 0) {
            const frame = &frames[depth - 1];
            if (frame.next_index < frame.values.len) {
                current = frame.values[frame.next_index];
                frame.next_index += 1;
                break;
            }
            depth -= 1;
        }
        if (current == null) return;
    }
}

const TestFingerprintBuilder = struct {
    value: u64 = 14_695_981_039_346_656_037,

    fn updateBytes(self: *@This(), bytes: []const u8) void {
        self.updateU64(bytes.len);
        self.updateRawBytes(bytes);
    }

    fn updateRawBytes(self: *@This(), bytes: []const u8) void {
        for (bytes) |byte| {
            self.value ^= byte;
            self.value *%= 1_099_511_628_211;
        }
    }

    fn updateBool(self: *@This(), value: bool) void {
        self.updateU64(@intFromBool(value));
    }

    fn updateU64(self: *@This(), value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.updateRawBytes(&bytes);
    }

    fn updateUsize(self: *@This(), value: usize) void {
        self.updateU64(@intCast(value));
    }

    fn finish(self: @This()) u64 {
        return self.value;
    }
};

fn makeNumberingTree(
    context: *ir.Context,
    operation_name: []const u8,
    reverse_operands: bool,
) !*ir.Operation {
    const test_dialect = @import("../../dialects/fixture/root.zig");
    const location = ir.Location.getUnknown();
    const integer_type = try test_dialect.TestDialect.getI64Type(context);
    var region = ir.context.initRegion(context);
    defer region.deinit();
    const block = try region.addBlock();
    const first = try block.addArgument(integer_type, location);
    const second = try block.addArgument(integer_type, location);
    var state = ir.Operation.State.init(operation_name, location);
    state.addOperands(if (reverse_operands) &.{ second, first } else &.{ first, second });
    state.addTypes(&.{integer_type});
    const operation = try context.createOperation(state);
    try block.addOperation(operation);
    var wrapper_state = ir.Operation.State.init("wrapper", location);
    wrapper_state.addRegionBodies(&.{&region});
    return context.createOperation(wrapper_state);
}

fn numberedFingerprint(allocator: Allocator, operation: *ir.Operation) !u64 {
    const limits = try StableValueNumbering.Limits.inspect(operation);
    var numbering = try StableValueNumbering.init(allocator, limits);
    defer numbering.deinit(allocator);
    try numbering.activate();
    var builder = TestFingerprintBuilder{};
    numbering.updateSubtreeFingerprint(&builder, operation);
    return builder.finish();
}

fn checkStableValueNumberingInitFailures(
    allocator: Allocator,
    limits: StableValueNumbering.Limits,
) !void {
    var numbering = try StableValueNumbering.init(allocator, limits);
    defer numbering.deinit(allocator);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, numbering.phase);
}
