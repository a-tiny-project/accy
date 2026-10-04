const std = @import("std");
const alloc_arena = @import("alloc_arena");
const alloc_phase = @import("alloc_phase");
const ir = @import("../../core/root.zig");
const hashing = @import("root.zig");
const capacity_model = hashing.capacity;
const numbering = hashing.numbering;
const walk = hashing.walk;

const Allocator = std.mem.Allocator;

pub const StableHasher = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.stable_hasher",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "the_complete_stablevaluenumbering_claim_plus_inline_d8f50bb9374f",
                        .lifetime = .steady,
                        .detail = "the complete StableValueNumbering claim plus inline Wyhash and scalar state",
                    },
                },
                .excluded = &.{
                    "borrowed mutable IR and referenced type and attribute payloads",
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
                    alloc_phase.capacity.bindType(std.hash.Wyhash, "hasher"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .input = 2 },
                    .{ .scale = .{ .node = 4, .coefficient = .{ .size_of_concrete_type = 2 } } },
                    .{ .constant = 1 },
                    .{ .scale = .{ .node = 6, .coefficient = .{ .size_of_concrete_type = 3 } } },
                    .{ .add = .{ .left = 1, .right = 3 } },
                    .{ .add = .{ .left = 8, .right = 5 } },
                    .{ .add = .{ .left = 9, .right = 7 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 10,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "nesting, arithmetic, OOM, stale facts, or definition drift rejects before activation",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "fingerprint reaches the indirect OperationPropertiesModel.getInherentAttr hook",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "property hook implementations may reacquire allocator policy or cross foreign boundaries",
                },
            },
            .dependencies = &.{"choir.stable_value_numbering"},
            .obligations = &.{
                .{ .key = "hasher_capacity", .role = .capacity_model },
                .{ .key = "hasher_sealed_fingerprint_transitive_risk", .role = .transitive_risk },
                .{ .key = "hasher_sealed_fingerprint_foreign_risk", .role = .foreign_risk },
                .{ .key = "hasher_oom_retry", .role = .overload },
                .{ .key = "hasher_stale_limits", .role = .overload },
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
    numbering: numbering.StableValueNumbering,
    hasher: std.hash.Wyhash,
    definitions_seen: u64,

    pub const Limits = capacity_model.Limits;
    pub const Capacity = capacity_model.Capacity;

    const Self = @This();

    pub fn init(allocator: Allocator, limits: Limits) !Self {
        const value_numbering = try numbering.StableValueNumbering.init(allocator, limits);
        return .{
            .phase = .initialization,
            .capacity = value_numbering.capacity,
            .numbering = value_numbering,
            .hasher = std.hash.Wyhash.init(0),
            .definitions_seen = 0,
        };
    }

    pub fn activate(self: *Self) error{ AlreadyActive, InputChanged }!void {
        if (self.phase != .initialization) return error.AlreadyActive;
        try self.numbering.activate();
        self.phase = .steady;
    }

    pub fn fingerprint(self: *Self) u64 {
        self.requireSteady();
        self.hasher = std.hash.Wyhash.init(0);
        self.definitions_seen = 0;
        var iterator = walk.Iterator.init(
            self.numbering.operation_frames,
            self.numbering.root,
        );
        while (iterator.next()) |event| switch (event) {
            .operation => |operation| self.visitOperation(operation),
            .region => {},
            .block => |block| self.visitBlock(block),
        };
        if (self.definitions_seen != self.capacity.facts.value_count) {
            @panic("stable hashing definitions changed after activation");
        }
        return self.hasher.final();
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        if (self.phase == .teardown) @panic("stable hasher teardown is terminal");
        self.phase = .teardown;
        self.numbering.deinit(allocator);
        self.hasher = undefined;
        self.definitions_seen = undefined;
    }

    fn visitOperation(self: *Self, operation: *ir.Operation) void {
        self.update(operation.getName().name);

        var attrs = operation.getAttrs();
        while (attrs.next()) |attr| {
            self.update(attr.name);
            self.visitAttribute(attr.value);
        }

        self.updateU64(operation.getNumResults());
        for (operation.results.items) |*result| {
            self.visitType(result.type);
            self.registerValue(result);
        }

        self.updateU64(operation.getNumOperands());
        for (operation.operands.items) |operand| self.visitValueUse(operand.value);
        self.updateU64(operation.getNumRegions());
    }

    fn visitBlock(self: *Self, block: *ir.Block) void {
        self.updateU64(block.getNumArguments());
        for (block.arguments.items) |argument| {
            self.visitType(argument.type);
            self.registerValue(argument);
        }
    }

    fn registerValue(self: *Self, value: *const ir.Value) void {
        const id = self.numbering.valueId(value) orelse
            @panic("stable hashing definition was not indexed");
        if (id != self.definitions_seen) {
            @panic("stable hashing definition order changed after activation");
        }
        self.definitions_seen += 1;
    }

    fn visitValueUse(self: *Self, value: *const ir.Value) void {
        if (self.numbering.valueId(value)) |id| {
            if (id < self.definitions_seen) {
                self.updateU64(id);
                return;
            }
        }
        self.updateU64(std.math.maxInt(u64));
    }

    fn visitType(self: *Self, typ: ir.Type) void {
        if (typ.getDialectStorage()) |storage| {
            self.update(storage.name);
            if (storage.param_key.len > 0) self.update(storage.param_key);
            return;
        }
        self.updateU64(@intFromPtr(typ.impl));
    }

    fn visitAttribute(self: *Self, root: ir.Attribute) void {
        var current: ?ir.Attribute = root;
        var depth: usize = 0;
        const frames = self.numbering.attribute_frames;
        while (true) {
            if (current) |attr| {
                self.update(attr.abstract.name);

                if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.integer)) {
                    if (attr.cast(ir.Attribute.IntegerAttr)) |integer| {
                        self.updateU64(@bitCast(integer.value));
                        self.update(&[_]u8{integer.width});
                        self.update(&[_]u8{if (integer.is_signed) 1 else 0});
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.float_)) {
                    if (attr.cast(ir.Attribute.FloatAttr)) |float| {
                        self.updateU64(@bitCast(float.value));
                        self.update(&[_]u8{float.width});
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.bool_)) {
                    if (attr.cast(ir.Attribute.BoolAttr)) |boolean| {
                        self.update(&[_]u8{if (boolean.value) 1 else 0});
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.string)) {
                    if (attr.cast(ir.Attribute.StringAttr)) |string| {
                        self.update(string.value);
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.symbol_ref)) {
                    if (attr.cast(ir.Attribute.SymbolRefAttr)) |symbol| {
                        self.updateU64(@intCast(symbol.root_reference.len));
                        self.update(symbol.root_reference);
                        self.updateU64(@intCast(symbol.nested_references.len));
                        for (symbol.nested_references) |nested| {
                            self.updateU64(@intCast(nested.len));
                            self.update(nested);
                        }
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.string_list)) {
                    if (attr.cast(ir.Attribute.StringListAttr)) |list| {
                        self.updateU64(@intCast(list.values.len));
                        for (list.values) |value| {
                            self.updateU64(@intCast(value.len));
                            self.update(value);
                        }
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.type_list)) {
                    if (attr.cast(ir.Attribute.TypeListAttr)) |list| {
                        self.updateU64(@intCast(list.values.len));
                        for (list.values) |typ| self.visitType(typ);
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.array)) {
                    if (attr.cast(ir.Attribute.ArrayAttr)) |array| {
                        self.updateU64(@intCast(array.values.len));
                        if (array.values.len > 0) {
                            if (depth >= frames.len) {
                                @panic("attribute traversal exceeded inspected depth");
                            }
                            frames[depth] = .{ .values = array.values, .next_index = 1 };
                            depth += 1;
                            current = array.values[0];
                            continue;
                        }
                    } else {
                        self.updateU64(@intFromPtr(attr.impl));
                    }
                } else if (attr.cast(ir.Attribute.DialectAttr)) |dialect| {
                    self.update(dialect.payload);
                } else {
                    self.updateU64(@intFromPtr(attr.impl));
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

    fn update(self: *Self, bytes: []const u8) void {
        self.hasher.update(bytes);
    }

    fn updateU64(self: *Self, value: u64) void {
        self.hasher.update(std.mem.asBytes(&value));
    }

    fn requireSteady(self: *const Self) void {
        if (self.phase != .steady) @panic("stable hasher used outside its steady phase");
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(StableHasher);
}

fn testFingerprint(allocator: Allocator, operation: *ir.Operation) !u64 {
    const limits = try StableHasher.Limits.inspect(operation);
    var hasher = try StableHasher.init(allocator, limits);
    defer hasher.deinit(allocator);
    try hasher.activate();
    return hasher.fingerprint();
}

fn checkStableHasherInitFailures(allocator: Allocator, limits: StableHasher.Limits) !void {
    var hasher = try StableHasher.init(allocator, limits);
    defer hasher.deinit(allocator);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, hasher.phase);
}

fn makeForwardUseTree(
    context: *ir.Context,
    use_external: bool,
) !*ir.Operation {
    const location = ir.Location.getUnknown();
    const integer_type = try context.getDialectTypeFromName("arith.i64");
    var producer_state = ir.Operation.State.init("test.producer", location);
    producer_state.addTypes(&.{integer_type});
    const producer = try context.createOperation(producer_state);
    var external_state = ir.Operation.State.init("test.external", location);
    external_state.addTypes(&.{integer_type});
    const external = try context.createOperation(external_state);
    var consumer_state = ir.Operation.State.init("test.consumer", location);
    consumer_state.addOperands(&.{if (use_external)
        &external.results.items[0]
    else
        &producer.results.items[0]});
    const consumer = try context.createOperation(consumer_state);

    var region = ir.context.initRegion(context);
    defer region.deinit();
    const block = try region.addBlock();
    try block.addOperation(consumer);
    try block.addOperation(producer);
    var root_state = ir.Operation.State.init("test.root", location);
    root_state.addRegionBodies(&.{&region});
    return context.createOperation(root_state);
}

test "stable hasher preserves the established empty-module protocol" {
    const test_dialect = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();

    const module = try test_dialect.TestDialect.ModuleOp.create(
        &context,
        ir.Location.getUnknown(),
    );
    const limits = try StableHasher.Limits.inspect(module.op);
    var hasher = try StableHasher.init(allocator, limits);
    defer hasher.deinit(allocator);
    try hasher.activate();

    try std.testing.expectEqual(@as(u32, 0), hasher.capacity.facts.value_count);
    try std.testing.expectEqual(@as(u64, 13_570_492_803_627_155_438), hasher.fingerprint());
    try std.testing.expectEqual(@as(u64, 13_570_492_803_627_155_438), hasher.fingerprint());
}

test "stable hasher seals exact backing before its first fingerprint" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(StableHasher, "hasher_sealed_fingerprint_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(StableHasher, "hasher_sealed_fingerprint_foreign_risk"),
        );
    }

    const test_dialect = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();

    const location = ir.Location.getUnknown();
    const integer_type = try test_dialect.TestDialect.getI64Type(&context);
    var region = ir.context.initRegion(&context);
    defer region.deinit();
    const block = try region.addBlock();
    const first = try block.addArgument(integer_type, location);
    const second = try block.addArgument(integer_type, location);
    var state = ir.Operation.State.init("test.add", location);
    state.addOperands(&.{ first, second });
    const operation = try context.createOperation(state);
    try block.addOperation(operation);
    var wrapper_state = ir.Operation.State.init("wrapper", location);
    wrapper_state.addRegionBodies(&.{&region});
    const wrapper = try context.createOperation(wrapper_state);
    const leaf = try context.getStringAttr("sealed");
    const inner = try context.getArrayAttr(&.{leaf});
    try wrapper.setAttr("nested", try context.getArrayAttr(&.{inner}));

    const limits = try StableHasher.Limits.inspect(wrapper);
    try std.testing.expect(limits.facts.value_count > 0);
    try std.testing.expect(limits.facts.operation_depth > 1);
    try std.testing.expect(limits.facts.attribute_depth > 1);
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(allocator);
    var maybe_hasher: ?StableHasher = null;
    errdefer {
        if (phase_allocator.phase() == .initialization) phase_allocator.abortInitialization();
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_hasher) |*hasher| {
            if (hasher.phase != .teardown) {
                hasher.deinit(phase_allocator.teardownAllocator());
            }
        }
        if (phase_allocator.phase() == .teardown) phase_allocator.deinit();
    }

    maybe_hasher = try StableHasher.init(
        phase_allocator.initializationAllocator(),
        limits,
    );
    const hasher = &maybe_hasher.?;
    const entries_pointer = hasher.numbering.index.entries.ptr;
    const operations_pointer = hasher.numbering.operation_frames.ptr;
    const attributes_pointer = hasher.numbering.attribute_frames.ptr;
    const derived = hasher.capacity;

    phase_allocator.seal();
    try hasher.activate();
    const first_fingerprint = hasher.fingerprint();
    const second_fingerprint = hasher.fingerprint();

    try std.testing.expectEqual(first_fingerprint, second_fingerprint);
    try std.testing.expectEqual(derived, hasher.capacity);
    try std.testing.expectEqual(entries_pointer, hasher.numbering.index.entries.ptr);
    try std.testing.expectEqual(operations_pointer, hasher.numbering.operation_frames.ptr);
    try std.testing.expectEqual(attributes_pointer, hasher.numbering.attribute_frames.ptr);
    try std.testing.expectEqual(alloc_phase.PhaseViolations{}, phase_allocator.violations());

    phase_allocator.beginTeardown();
    hasher.deinit(phase_allocator.teardownAllocator());
    try std.testing.expectEqual(alloc_phase.capacity.Phase.teardown, hasher.phase);
    try std.testing.expectEqual(alloc_phase.PhaseViolations{}, phase_allocator.violations());
    phase_allocator.deinit();
}

test "stable hasher preserves established nested-operation protocol" {
    const test_dialect = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();

    _ = try test_dialect.TestDialect.ModuleOp.create(&context, location);
    const module = try test_dialect.TestDialect.ModuleOp.create(&context, location);
    const function = try test_dialect.TestDialect.FuncOp.create(
        &context,
        location,
        "foo",
        &.{},
    );
    try module.getBodyBlock().addOperation(function.op);
    try std.testing.expectEqual(
        @as(u64, 13_201_224_996_460_106_173),
        try testFingerprint(allocator, module.op),
    );
}

test "stable hasher preserves established operand protocol" {
    const test_dialect = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();
    const integer_type = try test_dialect.TestDialect.getI64Type(&context);

    var first_region = ir.context.initRegion(&context);
    defer first_region.deinit();
    const first_block = try first_region.addBlock();
    const first_argument = try first_block.addArgument(integer_type, location);
    const second_argument = try first_block.addArgument(integer_type, location);
    var first_state = ir.Operation.State.init("test.add", location);
    first_state.addOperands(&.{ first_argument, second_argument });
    const first_operation = try context.createOperation(first_state);
    try first_block.addOperation(first_operation);
    var first_wrapper_state = ir.Operation.State.init("wrapper", location);
    first_wrapper_state.addRegionBodies(&.{&first_region});
    const first_wrapper = try context.createOperation(first_wrapper_state);

    var second_region = ir.context.initRegion(&context);
    defer second_region.deinit();
    const second_block = try second_region.addBlock();
    const third_argument = try second_block.addArgument(integer_type, location);
    const fourth_argument = try second_block.addArgument(integer_type, location);
    var second_state = ir.Operation.State.init("test.add", location);
    second_state.addOperands(&.{ fourth_argument, third_argument });
    const second_operation = try context.createOperation(second_state);
    try second_block.addOperation(second_operation);
    var second_wrapper_state = ir.Operation.State.init("wrapper", location);
    second_wrapper_state.addRegionBodies(&.{&second_region});
    const second_wrapper = try context.createOperation(second_wrapper_state);

    try std.testing.expectEqual(
        @as(u64, 6_847_343_841_190_853_235),
        try testFingerprint(allocator, first_wrapper),
    );
    try std.testing.expectEqual(
        @as(u64, 17_940_735_187_720_636_147),
        try testFingerprint(allocator, second_wrapper),
    );
}

test "stable hasher initialization cleans every allocation failure and retries" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(StableHasher, "hasher_oom_retry"));
    }

    const test_dialect = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();
    const integer_type = try test_dialect.TestDialect.getI64Type(&context);
    var region = ir.context.initRegion(&context);
    defer region.deinit();
    const block = try region.addBlock();
    _ = try block.addArgument(integer_type, location);
    const child = try context.createOperation(ir.Operation.State.init("child", location));
    try block.addOperation(child);
    var root_state = ir.Operation.State.init("root", location);
    root_state.addRegionBodies(&.{&region});
    const root = try context.createOperation(root_state);
    const leaf = try context.getStringAttr("leaf");
    const inner = try context.getArrayAttr(&.{leaf});
    try root.setAttr("nested", try context.getArrayAttr(&.{inner}));
    const limits = try StableHasher.Limits.inspect(root);
    try std.testing.expect(limits.facts.value_count > 0);
    try std.testing.expect(limits.facts.operation_depth > 1);
    try std.testing.expect(limits.facts.attribute_depth > 1);

    try std.testing.checkAllAllocationFailures(
        allocator,
        checkStableHasherInitFailures,
        .{limits},
    );

    var hasher = try StableHasher.init(allocator, limits);
    defer hasher.deinit(allocator);
    try hasher.activate();
    _ = hasher.fingerprint();
}

test "stable hasher rejects definition drift before activation" {
    const test_dialect = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();
    const module = try test_dialect.TestDialect.ModuleOp.create(&context, location);
    const limits = try StableHasher.Limits.inspect(module.op);
    var hasher = try StableHasher.init(allocator, limits);
    defer hasher.deinit(allocator);

    const child = try context.createOperation(ir.Operation.State.init("new.child", location));
    try module.getBodyBlock().addOperation(child);
    try std.testing.expectError(error.InputChanged, hasher.activate());
}

test "stable hasher rejects stale limits before allocation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(StableHasher, "hasher_stale_limits"),
        );
    }

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
    const limits = try StableHasher.Limits.inspect(root);
    const block = try root.getRegion(0).?.addBlock();
    try block.addOperation(try context.createOperation(ir.Operation.State.init("child", location)));
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.InputChanged,
        StableHasher.init(failing.allocator(), limits),
    );
}

test "stable hasher fingerprints structural attributes by contents" {
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const location = ir.Location.getUnknown();
    const i32_type = try context.getDialectTypeFromName("arith.i32");
    const i64_type = try context.getDialectTypeFromName("arith.i64");

    const first = try context.createOperation(ir.Operation.State.init("test.attrs", location));
    try first.setAttr("names", try context.getStringListAttr(&.{ "ctx", "result" }));
    try first.setAttr("types", try context.getTypeListAttr(&.{ i32_type, i64_type }));
    try first.setAttr("array", try context.getArrayAttr(&.{
        try context.getStringAttr("ctx"),
        try context.getTypeListAttr(&.{ i32_type, i64_type }),
    }));

    const second = try context.createOperation(ir.Operation.State.init("test.attrs", location));
    try second.setAttr("array", try context.getArrayAttr(&.{
        try context.getStringAttr("ctx"),
        try context.getTypeListAttr(&.{ i32_type, i64_type }),
    }));
    try second.setAttr("types", try context.getTypeListAttr(&.{ i32_type, i64_type }));
    try second.setAttr("names", try context.getStringListAttr(&.{ "ctx", "result" }));

    const different = try context.createOperation(ir.Operation.State.init("test.attrs", location));
    try different.setAttr("names", try context.getStringListAttr(&.{ "ctx", "value" }));
    try different.setAttr("types", try context.getTypeListAttr(&.{i32_type}));
    try different.setAttr("array", try context.getArrayAttr(&.{
        try context.getStringAttr("ctx"),
        try context.getTypeListAttr(&.{i32_type}),
    }));

    const first_fingerprint = try testFingerprint(allocator, first);
    try std.testing.expectEqual(first_fingerprint, try testFingerprint(allocator, second));
    try std.testing.expect(first_fingerprint != try testFingerprint(allocator, different));
}

test "stable hasher consumes the maximum inspected attribute depth" {
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const operation = try context.createOperation(ir.Operation.State.init(
        "test.deep_attrs",
        ir.Location.getUnknown(),
    ));
    var attribute = try context.getStringAttr("leaf");
    for (0..capacity_model.maximum_attribute_depth) |_| {
        attribute = try context.getArrayAttr(&.{attribute});
    }
    try operation.setAttr("nested", attribute);
    const limits = try StableHasher.Limits.inspect(operation);
    try std.testing.expectEqual(
        capacity_model.maximum_attribute_depth,
        limits.facts.attribute_depth,
    );
    var hasher = try StableHasher.init(allocator, limits);
    defer hasher.deinit(allocator);
    try hasher.activate();
    _ = hasher.fingerprint();
}

test "stable hasher preserves forward and external use sentinels" {
    const allocator = std.testing.allocator;
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    try context.allowUnregistered();
    const forward = try makeForwardUseTree(&context, false);
    const external = try makeForwardUseTree(&context, true);
    try std.testing.expectEqual(
        try testFingerprint(allocator, forward),
        try testFingerprint(allocator, external),
    );
}
