const std = @import("std");
const alloc_phase = @import("alloc_phase");
const Operation = @import("../root.zig").Operation;
const interfaces = @import("../root.zig").interfaces;
const dialect_ctx = @import("dialects.zig");
const freeze_ctx = @import("freeze.zig");
const memory_ctx = @import("memory.zig");
const resources = @import("resources.zig");
const transactions = @import("transactions.zig");

pub fn getOperationRegistry(ctx: anytype) *interfaces.OperationRegistry {
    return &ctx.dialect_registry.operation_registry;
}

pub fn lookupOperation(
    ctx: anytype,
    op_name: []const u8,
) ?*interfaces.OperationInfo {
    return ctx.dialect_registry.operation_registry.lookup(op_name);
}

pub fn registerOperation(
    ctx: anytype,
    op_name: []const u8,
    traits: interfaces.OperationTraits,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.GetOrCreateError || interfaces.OperationRegistry.RegisterInterfaceError)!*interfaces.OperationInfo {
    return registerOperationWithAttributeNameCapacity(ctx, op_name, traits, .{});
}

pub fn registerOperationWithAttributeNameCapacity(
    ctx: anytype,
    op_name: []const u8,
    traits: interfaces.OperationTraits,
    capacity: interfaces.OperationInfo.AttributeNameCapacity,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.GetOrCreateError || interfaces.OperationRegistry.RegisterInterfaceError)!*interfaces.OperationInfo {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTrackedWithAttributeNameCapacity(
        op_name,
        capacity,
    );
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    op_result.info.traits = op_result.info.traits.merge(traits);
    return op_result.info;
}

pub fn registerOperationBatch(
    ctx: anytype,
    operation_specs: anytype,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.GetOrCreateError)!void {
    try freeze_ctx.requireMutable(ctx);
    for (operation_specs) |op| {
        try transactions.recordCreatedOperation(
            ctx,
            op.name,
            ctx.dialect_registry.operation_registry.lookup(op.name) == null,
        );
    }
    try ctx.dialect_registry.operation_registry.getOrCreateOperationBatch(
        operation_specs,
    );
    for (operation_specs) |op| {
        const info = ctx.dialect_registry.operation_registry.lookup(op.name) orelse unreachable;
        info.traits = info.traits.merge(op.traits);
    }
}

pub fn registerOperationInterface(
    ctx: anytype,
    op_name: []const u8,
    entry: interfaces.InterfaceEntry,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.GetOrCreateError || interfaces.OperationRegistry.RegisterInterfaceError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.addInterface(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), entry);
}

pub fn registerOperationInterfaceExternal(
    ctx: anytype,
    op_name: []const u8,
    entry: interfaces.InterfaceEntry,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.GetOrCreateError || interfaces.OperationRegistry.RegisterInterfaceError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.addOrReplaceInterface(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), entry);
}

pub fn registerOperationInherentAttributeName(
    ctx: anytype,
    op_name: []const u8,
    attr_name: []const u8,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterInherentAttributeNameError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.addInherentAttributeName(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), attr_name);
}

pub fn registerOperationInherentAttributeNames(
    ctx: anytype,
    op_name: []const u8,
    attr_names: []const []const u8,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterInherentAttributeNameError)!void {
    for (attr_names) |attr_name| {
        try registerOperationInherentAttributeName(ctx, op_name, attr_name);
    }
}

pub fn registerOperationRequiredAttributeName(
    ctx: anytype,
    op_name: []const u8,
    attr_name: []const u8,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterRequiredAttributeNameError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.addRequiredAttributeName(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), attr_name);
}

pub fn registerOperationRequiredAttributeNames(
    ctx: anytype,
    op_name: []const u8,
    attr_names: []const []const u8,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterRequiredAttributeNameError)!void {
    for (attr_names) |attr_name| {
        try registerOperationRequiredAttributeName(ctx, op_name, attr_name);
    }
}

pub fn registerOperationPropertiesModel(
    ctx: anytype,
    op_name: []const u8,
    model: interfaces.OperationPropertiesModel,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterPropertiesModelError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.setPropertiesModel(model);
}

pub fn registerOperationShape(
    ctx: anytype,
    op_name: []const u8,
    shape: interfaces.OperationShape,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterShapeError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.setShape(shape);
}

pub fn registerOperationOperandSegments(
    ctx: anytype,
    op_name: []const u8,
    spec: interfaces.OperationSegmentSpec,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterSegmentSpecError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.setOperandSegments(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), spec);
}

pub fn registerOperationResultSegments(
    ctx: anytype,
    op_name: []const u8,
    spec: interfaces.OperationSegmentSpec,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterSegmentSpecError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.setResultSegments(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), spec);
}

pub fn registerOperationOperandTypeConstraint(
    ctx: anytype,
    op_name: []const u8,
    constraint: interfaces.OperationTypeConstraint,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterTypeConstraintError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.addOperandTypeConstraint(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), constraint);
}

pub fn registerOperationResultTypeConstraint(
    ctx: anytype,
    op_name: []const u8,
    constraint: interfaces.OperationTypeConstraint,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterTypeConstraintError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.addResultTypeConstraint(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), constraint);
}

pub fn registerOperationTraitId(
    ctx: anytype,
    op_name: []const u8,
    trait_id: interfaces.TraitId,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterTraitError)!void {
    try freeze_ctx.requireMutable(ctx);
    const op_result = try ctx.dialect_registry.operation_registry.getOrCreateTracked(op_name);
    try transactions.recordCreatedOperation(ctx, op_name, op_result.created);
    try op_result.info.addTrait(memory_ctx.segmentAllocator(ctx, .configuration_interfaces), trait_id);
}

pub fn registerOperationTrait(
    ctx: anytype,
    op_name: []const u8,
    trait_name: []const u8,
) (@TypeOf(ctx.*).Error || interfaces.OperationRegistry.RegisterTraitError)!void {
    return registerOperationTraitId(ctx, op_name, interfaces.traitIdRuntime(trait_name));
}

pub fn createOperation(ctx: anytype, state: Operation.State) anyerror!*Operation {
    try freeze_ctx.requireSingleThreadedMutation(ctx);
    try dialect_ctx.ensureDialectForOperation(ctx, state.name.name);

    var resolved_state = state;
    const op_info = ctx.dialect_registry.operation_registry.lookup(state.name.name);

    if (!ctx.dialect_registry.operation_registry.allow_unregistered_operations and op_info == null) {
        return error.UnknownOperation;
    }

    if (op_info) |info| {
        resolved_state.name = Operation.OperationName.registered(info);
    }

    const op = try Operation.create(ctx, resolved_state);

    for (op.results.items) |*result| {
        result.id = resources.allocateValueId(ctx);
    }

    resources.trackOperation(ctx, op);

    return op;
}

test "Context operation registry integration" {
    const testing = @import("std").testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    try testing.expectEqual(@as(?*interfaces.OperationInfo, null), ctx.lookupOperation("arith.addi"));

    const info = try ctx.registerOperation(
        "arith.addi",
        .{ .is_idempotent = true, .is_commutative = true },
    );
    try testing.expectEqualStrings("arith.addi", info.name);
    try testing.expect(info.traits.is_idempotent);
    try testing.expect(info.traits.is_commutative);

    const found = ctx.lookupOperation("arith.addi");
    try testing.expectEqual(info, found.?);

    const iface_id = interfaces.interfaceId("ir.interface.symbol_op");
    const vtable: u8 = 42;
    try ctx.registerOperationInterface("arith.addi", .{ .id = iface_id, .vtable = &vtable });
    try ctx.registerOperationInherentAttributeName("arith.addi", "value");
    try ctx.registerOperationRequiredAttributeName("arith.addi", "value");

    try testing.expect(info.hasInterface(iface_id));
    try testing.expect(info.hasInherentAttributeName("value"));
    try testing.expect(info.hasRequiredAttributeName("value"));

    const registry = ctx.getOperationRegistry();
    try testing.expectEqual(@as(usize, 1), registry.count());
}

test "Context operation tracking adds no allocation and retries after storage OOM" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Context, "choir_context_operation_exhaustion_overload"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Context, "choir_context_operation_exhaustion_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("../operation/root.zig").OperationFixedStorage, "choir_operation_tracking_static"),
        );
    }

    const testing = std.testing;
    const Context = @import("root.zig").Context;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const storage_capacity = try Operation.StoragePlan.Capacity.derive(.{
        .operands = 0,
        .results = 0,
        .regions = 0,
        .successors = 0,
        .properties = 0,
        .properties_alignment = .@"1",
    });
    var limits = Context.Limits.testing;
    limits.operations.storage_bytes = storage_capacity.total_bytes;
    var ctx = try Context.init(failing.allocator(), limits);
    defer ctx.deinit(failing.allocator());
    try ctx.allowUnregistered();

    const state = Operation.State.init("tracking_static", .unknown);
    const before = failing.alloc_index;
    const first = try ctx.createOperation(state);
    try testing.expectEqual(before, failing.alloc_index);
    try testing.expectEqual(@as(usize, 1), ctx.operationCount());
    try testing.expect(ctx.containsOperation(first));

    try testing.expectError(error.OutOfMemory, ctx.createOperation(state));
    try testing.expectEqual(@as(usize, 1), ctx.operationCount());
    try testing.expect(ctx.containsOperation(first));

    first.erase();
    try testing.expectEqual(@as(usize, 0), ctx.operationCount());
    try testing.expect(!ctx.containsOperation(first));

    const second = try ctx.createOperation(state);
    try testing.expectEqual(before, failing.alloc_index);
    try testing.expectEqual(@as(usize, 1), ctx.operationCount());
    try testing.expect(ctx.containsOperation(second));

    second.erase();
    try testing.expectEqual(@as(usize, 0), ctx.operationCount());
}

test "Context creation boundaries erase only later operations" {
    const testing = @import("std").testing;
    const Context = @import("root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const first = try ctx.createOperation(Operation.State.init("first", .unknown));
    const boundary = ctx.operationCreationBoundary();
    const second = try ctx.createOperation(Operation.State.init("second", .unknown));
    const third = try ctx.createOperation(Operation.State.init("third", .unknown));

    ctx.eraseOperationsCreatedSince(boundary);

    try testing.expectEqual(@as(usize, 1), ctx.operationCount());
    try testing.expect(ctx.containsOperation(first));
    try testing.expect(!ctx.containsOperation(second));
    try testing.expect(!ctx.containsOperation(third));
    first.erase();
}

test "Context common operation storage retries and reuses erased storage" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var limits = Context.Limits.testing;
    limits.operations.storage_bytes = Operation.StorageAllocator.first_chunk_bytes;
    var ctx = try Context.init(failing.allocator(), limits);
    defer ctx.deinit(failing.allocator());
    try ctx.allowUnregistered();
    _ = try ctx.registerOperation("test.common_storage", .{});
    try ctx.registerOperationPropertiesModel(
        "test.common_storage",
        interfaces.singleAttributePropertiesModel("test.common_storage.properties", "value"),
    );
    const ty = try ctx.getDialectTypeFromName("test.common_storage_type");

    var state = Operation.State.init("test.common_storage", .unknown);
    state.addTypes(&.{ty});

    var operations: [Operation.StorageAllocator.items_per_chunk]*Operation = undefined;
    for (&operations) |*operation| operation.* = try ctx.createOperation(state);
    const first = operations[0];
    const first_address = @intFromPtr(first);
    const allocations = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, ctx.createOperation(state));
    first.erase();

    const reused = try ctx.createOperation(state);
    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expectEqual(first_address, @intFromPtr(reused));
    reused.erase();
}

test "Context registerOperationTrait adds dynamic trait" {
    const testing = @import("std").testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const trait_id = interfaces.traitId("ir.trait.test_dynamic");
    try ctx.registerOperationTraitId("trait_test.op", trait_id);

    const state = Operation.State.init("trait_test.op", .unknown);
    const op = try ctx.createOperation(state);

    try testing.expect(op.hasTraitId(trait_id));
    try testing.expect(op.hasTraitName("ir.trait.test_dynamic"));
}

test "Operation caches op info after interface lookup" {
    const testing = @import("std").testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const state = Operation.State.init("cache_iface.op", .unknown);
    const op = try ctx.createOperation(state);
    try testing.expectEqual(@as(?*const interfaces.OperationInfo, null), op.name.getRegisteredInfo());

    const CacheInterface = struct {
        pub const id = interfaces.interfaceId("cache_iface.interface");
        pub const VTable = struct {};
    };
    const vtable: CacheInterface.VTable = .{};
    try ctx.registerOperationInterface("cache_iface.op", .{ .id = CacheInterface.id, .vtable = &vtable });

    const iface = op.getInterface(CacheInterface);
    try testing.expect(iface != null);
    const cached = op.name.getRegisteredInfo().?;
    for (0..5) |_| {
        try testing.expectEqual(cached, op.getRegisteredInfo().?);
        try testing.expectEqual(cached, op.name.getRegisteredInfo().?);
        try testing.expect(op.getInterface(CacheInterface) != null);
    }
}

test "OperationName carries registered operation info from creation" {
    const testing = @import("std").testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const info = try ctx.registerOperation("registered_name.op", .{ .is_idempotent = true });

    const state = Operation.State.init("registered_name.op", .unknown);
    const op = try ctx.createOperation(state);

    try testing.expect(op.isRegistered());
    try testing.expectEqual(info, op.name.getRegisteredInfo().?);
    try testing.expect(op.name.getTraits().is_idempotent);
}

test "Context operation registry cleanup" {
    const testing = @import("std").testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    _ = try ctx.registerOperation("arith.addi", .{ .is_idempotent = true });
    _ = try ctx.registerOperation("arith.subi", .{ .is_idempotent = true });
    _ = try ctx.registerOperation("memref.store", .{ .is_terminator = true });

    const effect_id = interfaces.interfaceId("test.interface");
    const vtable: u8 = 1;
    try ctx.registerOperationInterface("arith.addi", .{ .id = effect_id, .vtable = &vtable });
    try ctx.registerOperationInterface("arith.subi", .{ .id = effect_id, .vtable = &vtable });
}

test "Context createOperation validates against registry" {
    const testing = @import("std").testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const state1 = Operation.State.init("test.unregistered", .unknown);
    const op1 = try ctx.createOperation(state1);
    try testing.expectEqualStrings("test.unregistered", op1.name.name);

    _ = try ctx.registerOperation("test.registered", .{ .is_idempotent = true });

    const state2 = Operation.State.init("test.registered", .unknown);
    const op2 = try ctx.createOperation(state2);
    try testing.expectEqualStrings("test.registered", op2.name.name);

    try ctx.requireRegistered();

    const state3 = Operation.State.init("test.another_unregistered", .unknown);
    const result = ctx.createOperation(state3);
    try testing.expectError(error.UnknownOperation, result);

    const state4 = Operation.State.init("test.registered", .unknown);
    const op4 = try ctx.createOperation(state4);
    try testing.expectEqualStrings("test.registered", op4.name.name);
}
