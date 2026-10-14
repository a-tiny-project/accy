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

/// The registration `name` has in this Context now, by one probe of the
/// operation registry. A static name carries its hash, so the probe compares
/// bytes and hashes nothing.
pub fn lookupOperationName(
    ctx: anytype,
    name: Operation.OperationName,
    static_name: ?*const Operation.OperationName.StaticDescriptor,
) ?*interfaces.OperationInfo {
    const registry = &ctx.dialect_registry.operation_registry;
    if (static_name) |descriptor| return registry.lookupHashed(descriptor.name.name, descriptor.hash);
    return registry.lookup(name.name);
}

/// Resolve `name` for one creation or one properties check: load its dialect
/// when that is still owed, and return its registration or null. The record
/// is borrowed for that call. Nothing is kept across calls, so a removal or a
/// later registration is seen by the next one.
pub fn resolveOperation(
    ctx: anytype,
    name: Operation.OperationName,
    static_name: ?*const Operation.OperationName.StaticDescriptor,
) !?*interfaces.OperationInfo {
    const settled = ctx.dialect_load_transactions.items.len == 0;
    if (static_name != null and settled) {
        if (lookupOperationName(ctx, name, static_name)) |info| {
            if (info.dialect_load_complete) return info;
        }
    }

    try dialect_ctx.ensureDialectForName(ctx, name, static_name);
    const info = lookupOperationName(ctx, name, static_name) orelse return null;
    // The record is shared by every lane, so only the single owner publishes
    // the proof, and only once. A lane preparing properties reads it.
    if (settled and !info.dialect_load_complete and !ctx.isMultithreadedExecution()) {
        info.dialect_load_complete = true;
    }
    return info;
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
    const op_info = try resolveOperation(ctx, state.name, state.static_name);

    if (!ctx.dialect_registry.operation_registry.allow_unregistered_operations and op_info == null) {
        return error.UnknownOperation;
    }

    const op = try Operation.createWithRegistration(ctx, state, op_info);

    for (op.results.items) |*result| {
        result.id = resources.allocateValueId(ctx);
    }

    resources.trackOperation(ctx, op);

    return op;
}
