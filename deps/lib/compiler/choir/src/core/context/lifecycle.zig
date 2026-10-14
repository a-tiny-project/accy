const std = @import("std");
const alloc_phase = @import("alloc_phase");
const core = @import("../root.zig");
const diagnostics = @import("../../diagnostics/root.zig");
const interfaces = @import("../root.zig").interfaces;
const dialects = @import("../root.zig").dialects;
const types = @import("../root.zig").types;
const attrs = @import("../root.zig").attrs;
const attr_ctx = @import("attrs.zig");
const dialect_ctx = @import("dialects.zig");
const freeze_ctx = @import("freeze.zig");
const interface_ctx = @import("interface.zig");
const memory_ctx = @import("memory.zig");
const ops_ctx = @import("ops.zig");
const policy_ctx = @import("policy.zig");
const resources = @import("resources.zig");
const threading = @import("../root.zig").threading;
const transactions = @import("transactions.zig");
const type_ctx = @import("types.zig");

const PassRunAtomicInt = if (@bitSizeOf(usize) >= @bitSizeOf(u64)) u64 else u32;

pub const Context = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    storage: [*]u8,
    memory: *memory_ctx.Memory,
    operation_storage_allocator: [@sizeOf(core.Operation.StorageAllocator)]u8 align(@alignOf(core.Operation.StorageAllocator)),
    dialect_registry: dialects.DialectRegistry,
    trait_registry: interfaces.TraitRegistry,
    type_interner: types.TypeInterner,
    attr_interner: attrs.AttributeInterner,
    resources: resources.Tracker,
    type_param_cache: types.TypeParamCache,
    dialect_load_transactions: std.ArrayListUnmanaged(transactions.DialectLoadTransaction),
    freeze_policy: freeze_ctx.Policy,
    threading_execution: threading.ExecutionState,
    diagnostic_engine: diagnostics.Engine,
    pass_runs: std.atomic.Value(PassRunAtomicInt),
    arithmetic_policy: interfaces.effects.ArithmeticPolicy = .{},

    pub const Limits = memory_ctx.Limits;
    pub const minimum_alignment = memory_ctx.minimum_alignment;
    pub const maximum_storage_bytes = memory_ctx.maximum_storage_bytes;
    pub const Refusal = memory_ctx.Refusal;
    pub const refusal = memory_ctx.refusal;
    pub const Capacity = memory_ctx.Capacity;
    pub const Segment = memory_ctx.Segment;
    pub const Usage = memory_ctx.Usage;
    pub const Exhausted = memory_ctx.Exhausted;
    pub const InFlightDiagnostic = diagnostics.BoundInFlightDiagnostic(
        Context,
        diagnosticPayloadAllocator,
    );
    pub const Exhaustion = error{OutOfMemory};
    pub const InitError = error{ CapacityOverflow, OutOfMemory };

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.context",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "dialect_registry_trait_and_configuration_table_storage",
                        .lifetime = .steady,
                        .detail = "dialect, registry, trait, and configuration table storage",
                    },
                    .{
                        .id = "interned_dialect_names",
                        .lifetime = .steady,
                        .detail = "interned dialect names",
                    },
                    .{
                        .id = "operation_type_attribute_and_dialect_interface_definitions",
                        .lifetime = .steady,
                        .detail = "operation, type, attribute, and dialect interface definitions",
                    },
                    .{
                        .id = "dialect_registration_transaction_journals",
                        .lifetime = .initialization,
                        .detail = "dialect registration transaction journals",
                    },
                    .{
                        .id = "interned_type_tables",
                        .lifetime = .steady,
                        .detail = "interned type tables",
                    },
                    .{
                        .id = "type_names_and_parameter_keys",
                        .lifetime = .steady,
                        .detail = "type names and parameter keys",
                    },
                    .{
                        .id = "type_objects_and_parsed_parameter_payloads",
                        .lifetime = .steady,
                        .detail = "type objects and parsed parameter payloads",
                    },
                    .{
                        .id = "interned_attribute_tables",
                        .lifetime = .steady,
                        .detail = "interned attribute tables",
                    },
                    .{
                        .id = "attribute_objects_and_retained_payloads",
                        .lifetime = .steady,
                        .detail = "attribute objects and retained payloads",
                    },
                    .{
                        .id = "fixed_shape_operation_storage_pools",
                        .lifetime = .steady,
                        .detail = "fixed-shape operation storage pools",
                    },
                    .{
                        .id = "regions_blocks_properties_operands_successors_and_o_5b44c1ea68c9",
                        .lifetime = .steady,
                        .detail = "regions, blocks, properties, operands, successors, and operation spills",
                    },
                    .{
                        .id = "diagnostic_handler_registry",
                        .lifetime = .steady,
                        .detail = "diagnostic handler registry",
                    },
                    .{
                        .id = "in_flight_diagnostic_messages_notes_and_metadata",
                        .lifetime = .steady,
                        .detail = "in-flight diagnostic messages, notes, and metadata",
                    },
                    .{
                        .id = "bounded_transient_formatting_parsing_verification_a_52aa670b3999",
                        .lifetime = .initialization,
                        .detail = "bounded transient formatting, parsing, verification, and lowering work",
                    },
                },
                .excluded = &.{
                    "caller allocator implementation state and an optional stable Context handle",
                    "caller-owned diagnostic capture buffers and foreign interface vtable state",
                    "pass managers, backends, extension registries, and other owners constructed beside Context",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "attributes_payload_bytes", "attributes.payload_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "attributes_table_bytes", "attributes.table_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "configuration_interface_bytes", "configuration.interface_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "configuration_name_bytes", "configuration.name_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "configuration_table_bytes", "configuration.table_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "configuration_transaction_bytes", "configuration.transaction_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "diagnostics_handler_bytes", "diagnostics.handler_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "diagnostics_payload_bytes", "diagnostics.payload_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "operations_nested_bytes", "operations.nested_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "operations_storage_bytes", "operations.storage_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "transient_bytes", "transient_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "types_key_bytes", "types.key_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "types_payload_bytes", "types.payload_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "types_table_bytes", "types.table_bytes"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .input = 2 },
                    .{ .input = 3 },
                    .{ .input = 4 },
                    .{ .input = 5 },
                    .{ .input = 6 },
                    .{ .input = 7 },
                    .{ .input = 8 },
                    .{ .input = 9 },
                    .{ .input = 10 },
                    .{ .input = 11 },
                    .{ .input = 12 },
                    .{ .input = 13 },
                    .{ .add = .{ .left = 0, .right = 1 } },
                    .{ .add = .{ .left = 14, .right = 2 } },
                    .{ .add = .{ .left = 15, .right = 3 } },
                    .{ .add = .{ .left = 16, .right = 4 } },
                    .{ .add = .{ .left = 17, .right = 5 } },
                    .{ .add = .{ .left = 18, .right = 6 } },
                    .{ .add = .{ .left = 19, .right = 7 } },
                    .{ .add = .{ .left = 20, .right = 8 } },
                    .{ .add = .{ .left = 21, .right = 9 } },
                    .{ .add = .{ .left = 22, .right = 10 } },
                    .{ .add = .{ .left = 23, .right = 11 } },
                    .{ .add = .{ .left = 24, .right = 12 } },
                    .{ .add = .{ .left = 25, .right = 13 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .upper_bound,
                    .expression = 26,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "steady OutOfMemory denotes exhaustion of one named fixed segment; capacity arithmetic and allocation admissions fail before publishing partial state",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "all Context-retained nested owners draw from the named fixed segments acquired at construction",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "opaque interface state and caller-owned diagnostic capture storage remain owned by their supplying APIs",
                },
            },
            .dependencies = &.{"choir.operation_fixed_storage"},
            .obligations = &.{
                .{ .key = "choir_context_capacity", .role = .capacity_model },
                .{ .key = "choir_context_capacity_overflow", .role = .overload },
                .{ .key = "choir_context_single_acquisition", .role = .transitive_risk },
                .{ .key = "choir_context_initialization_retry", .role = .overload },
                .{ .key = "choir_context_operation_exhaustion_overload", .role = .overload },
                .{ .key = "choir_context_operation_exhaustion_transitive_risk", .role = .transitive_risk },
                .{ .key = "choir_context_spill_exhaustion", .role = .overload },
                .{ .key = "choir_context_foreign_ownership", .role = .foreign_risk },
                .{ .key = "choir_context_diagnostic_exhaustion", .role = .overload },
                .{ .key = "choir_context_lazy_param_exhaustion", .role = .overload },
                .{ .key = "choir_context_attribute_exhaustion", .role = .overload },
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

    pub const Error = error{
        ContextFrozen,
        ContextMutationDuringMultithreadedExecution,
        UnknownDialect,
        DialectLoadCycle,
        UnknownOperation,
        UnknownType,
        DuplicateDialectLoader,
        DuplicateInterface,
        BackendDialectRequired,
        InvalidTranslationDialect,
    } || std.mem.Allocator.Error;

    pub const RegisterTraitDefinitionError = Error || interfaces.TraitRegistry.RegisterError;

    pub const RegisterError = Error || interfaces.OperationRegistry.GetOrCreateError || interfaces.OperationRegistry.RegisterInterfaceError;
    pub const RegisterTraitError = Error || interfaces.OperationRegistry.RegisterTraitError;
    pub const RegisterInherentAttributeNameError = Error || interfaces.OperationRegistry.RegisterInherentAttributeNameError;
    pub const RegisterTypeConstraintError = Error || interfaces.OperationRegistry.RegisterTypeConstraintError;
    pub const RegisterSegmentSpecError = Error || interfaces.OperationRegistry.RegisterSegmentSpecError;
    pub const RegisterTypeError = Error || interfaces.TypeRegistry.GetOrCreateError || interfaces.TypeRegistry.RegisterInterfaceError;
    pub const RegisterAttributeError = Error || interfaces.AttributeRegistry.RegisterError;

    pub fn init(allocator: std.mem.Allocator, limits: Limits) InitError!Context {
        const capacity = try Capacity.derive(limits);
        const storage = allocator.rawAlloc(
            capacity.storage_bytes,
            capacity.storage_alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        const memory = memory_ctx.Memory.init(storage, capacity);
        var context = Context{
            .phase = .initialization,
            .capacity = capacity,
            .storage = storage,
            .memory = memory,
            .operation_storage_allocator = undefined,
            .dialect_registry = dialects.DialectRegistry.init(
                memory.configuration_tables.allocator(),
                memory.configuration_interfaces.allocator(),
            ),
            .trait_registry = interfaces.TraitRegistry.init(),
            .type_interner = types.TypeInterner.init(
                memory.type_tables.allocator(),
                memory.type_keys.allocator(),
            ),
            .attr_interner = attrs.AttributeInterner.init(
                memory.attribute_tables.allocator(),
                memory.configuration_interfaces.allocator(),
            ),
            .resources = resources.Tracker.init(),
            .type_param_cache = .{},
            .dialect_load_transactions = .empty,
            .freeze_policy = freeze_ctx.Policy.init(),
            .threading_execution = threading.ExecutionState.init(),
            .diagnostic_engine = diagnostics.Engine.init(),
            .pass_runs = std.atomic.Value(PassRunAtomicInt).init(0),
        };
        operationStorageAllocator(&context).* = core.Operation.StorageAllocator.init(
            memory_ctx.operationStorageAllocator(context.memory),
        );
        return context;
    }

    pub fn create(allocator: std.mem.Allocator, limits: Limits) InitError!*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, limits);
        return self;
    }

    pub fn activate(self: *Context) void {
        std.debug.assert(self.phase == .initialization);
        self.freeze();
        self.phase = .steady;
    }

    pub fn capacityUsage(self: *const Context) Usage {
        return memory_ctx.cast(self.memory).usage();
    }

    pub fn exhaustedSegment(self: *const Context) ?Segment {
        return memory_ctx.cast(self.memory).exhausted_segment;
    }

    /// The segment a request found full and the size of that request, or
    /// null when no request has failed since the last `clearExhaustion`.
    pub fn exhaustion(self: *const Context) ?Exhausted {
        return memory_ctx.cast(self.memory).exhaustion();
    }

    pub fn clearExhaustion(self: *Context) void {
        memory_ctx.cast(self.memory).exhausted_segment = null;
        memory_ctx.cast(self.memory).exhausted_request = 0;
    }

    pub fn requireCapacity(
        self: *Context,
        segment: Segment,
        bytes: usize,
        alignment: std.mem.Alignment,
    ) Exhaustion!void {
        const memory = memory_ctx.cast(self.memory);
        if (!memory.hasCapacity(segment, bytes, alignment)) {
            memory.exhausted_segment = segment;
            memory.exhausted_request = bytes;
            return error.OutOfMemory;
        }
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        self.resources.deinit();
        operationStorageAllocator(self).deinit();
        self.deinitTypeParamCache();
        transactions.deinitAll(self);
        self.trait_registry.deinit(memory_ctx.configurationTableAllocator(self.memory));
        self.dialect_registry.deinit(
            memory_ctx.configurationTableAllocator(self.memory),
            memory_ctx.configurationNameAllocator(self.memory),
            memory_ctx.configurationInterfaceAllocator(self.memory),
        );
        self.type_interner.deinit(
            memory_ctx.typeTableAllocator(self.memory),
            memory_ctx.typeKeyAllocator(self.memory),
            memory_ctx.typePayloadAllocator(self.memory),
        );
        self.attr_interner.deinit(memory_ctx.attributePayloadAllocator(self.memory));
        self.diagnostic_engine.deinit(memory_ctx.diagnosticHandlerAllocator(self.memory));
        const storage = self.storage;
        const capacity = self.capacity;
        self.phase = .teardown;
        self.* = undefined;
        allocator.rawFree(
            storage[0..capacity.storage_bytes],
            capacity.storage_alignment,
            @returnAddress(),
        );
    }

    pub fn registerTraitDefinition(self: *Context, entry: interfaces.TraitEntry) RegisterTraitDefinitionError!void {
        try freeze_ctx.requireMutable(self);
        try self.trait_registry.register(
            memory_ctx.configurationTableAllocator(self.memory),
            entry,
        );
    }

    pub fn lookupTrait(self: *const Context, trait_id: interfaces.TraitId) ?*const interfaces.TraitVTable {
        return self.trait_registry.lookup(trait_id);
    }

    pub fn getDiagnosticEngine(self: *Context) *diagnostics.Engine {
        return &self.diagnostic_engine;
    }

    pub fn registerDiagnosticHandler(
        self: *Context,
        handler: diagnostics.Handler,
    ) !diagnostics.Engine.HandlerId {
        return self.diagnostic_engine.registerHandler(
            memory_ctx.diagnosticHandlerAllocator(self.memory),
            handler,
        );
    }

    pub fn eraseDiagnosticHandler(self: *Context, id: diagnostics.Engine.HandlerId) void {
        self.diagnostic_engine.eraseHandler(id);
    }

    pub fn emitDiagnostic(
        self: *Context,
        diagnostic: diagnostics.Diagnostic,
    ) InFlightDiagnostic {
        return .{
            .context = self,
            .diagnostic = self.diagnostic_engine.emit(diagnostic),
        };
    }

    pub fn captureDiagnostics(
        self: *Context,
        buffer: *diagnostics.CaptureBuffer,
    ) diagnostics.CaptureScope {
        return self.diagnostic_engine.capture(buffer);
    }

    pub fn replayDiagnostics(
        self: *Context,
        buffer: *const diagnostics.CaptureBuffer,
    ) !diagnostics.HandlerResult {
        return self.diagnostic_engine.replay(buffer);
    }

    pub fn enterMultithreadedExecution(self: *Context) threading.ExecutionGuard {
        return self.threading_execution.enter();
    }

    pub fn isMultithreadedExecution(self: *const Context) bool {
        return self.threading_execution.isActive();
    }

    pub fn recordPassRuns(self: *Context, additional: u64) void {
        var current = self.pass_runs.load(.monotonic);
        while (true) {
            const next = saturatingPassRunAdd(PassRunAtomicInt, current, additional);
            if (self.pass_runs.cmpxchgWeak(
                current,
                next,
                .monotonic,
                .monotonic,
            )) |observed| {
                current = observed;
            } else {
                return;
            }
        }
    }

    pub fn passRunCount(self: *const Context) u64 {
        return @intCast(self.pass_runs.load(.monotonic));
    }

    fn deinitTypeParamCache(self: *Context) void {
        var iter = self.type_param_cache.valueIterator();
        while (iter.next()) |payload| {
            payload.deinit(memory_ctx.typePayloadAllocator(self.memory), payload.ptr);
        }
        self.type_param_cache.deinit(memory_ctx.typeTableAllocator(self.memory));
    }

    pub const appendDialectRegistry = dialect_ctx.appendDialectRegistry;
    pub const registerDialectLoader = dialect_ctx.registerDialectLoader;
    pub const registerBackendDialect = dialect_ctx.registerBackendDialect;
    pub const isBackendDialect = dialect_ctx.isBackendDialect;
    pub const addDialectExtension = dialect_ctx.addDialectExtension;
    pub const getOrLoadDialect = dialect_ctx.getOrLoadDialect;
    pub const isDialectLoaded = dialect_ctx.isDialectLoaded;
    pub const getDialect = dialect_ctx.getDialect;
    pub const ensureDialectForOperation = dialect_ctx.ensureDialectForOperation;
    pub const prepareDialectLoadRecordStorage = transactions.prepareRecordStorage;
    pub const registerDialectInterface = interface_ctx.registerDialectInterface;
    pub const getDialectInterface = interface_ctx.getDialectInterface;
    pub const registerDialectOpInterfaceFallback = interface_ctx.registerDialectOpInterfaceFallback;
    pub const getDialectOpInterfaceFallback = interface_ctx.getDialectOpInterfaceFallback;
    pub const registerDialectTypeInterfaceFallback = interface_ctx.registerDialectTypeInterfaceFallback;
    pub const getDialectTypeInterfaceFallback = interface_ctx.getDialectTypeInterfaceFallback;
    pub const requireRegistered = policy_ctx.requireRegistered;
    pub const allowUnregistered = policy_ctx.allowUnregistered;
    pub const getOperationRegistry = ops_ctx.getOperationRegistry;
    pub const lookupOperation = ops_ctx.lookupOperation;
    pub const lookupOperationName = ops_ctx.lookupOperationName;
    pub const resolveOperation = ops_ctx.resolveOperation;
    pub const registerOperation = ops_ctx.registerOperation;
    pub const registerOperationWithAttributeNameCapacity = ops_ctx.registerOperationWithAttributeNameCapacity;
    pub const registerOperationBatch = ops_ctx.registerOperationBatch;
    pub const registerOperationInterface = ops_ctx.registerOperationInterface;
    pub const registerOperationInterfaceExternal = ops_ctx.registerOperationInterfaceExternal;
    pub const registerOperationInherentAttributeName = ops_ctx.registerOperationInherentAttributeName;
    pub const registerOperationInherentAttributeNames = ops_ctx.registerOperationInherentAttributeNames;
    pub const registerOperationRequiredAttributeName = ops_ctx.registerOperationRequiredAttributeName;
    pub const registerOperationRequiredAttributeNames = ops_ctx.registerOperationRequiredAttributeNames;
    pub const registerOperationPropertiesModel = ops_ctx.registerOperationPropertiesModel;
    pub const registerOperationShape = ops_ctx.registerOperationShape;
    pub const registerOperationOperandSegments = ops_ctx.registerOperationOperandSegments;
    pub const registerOperationResultSegments = ops_ctx.registerOperationResultSegments;
    pub const registerOperationOperandTypeConstraint = ops_ctx.registerOperationOperandTypeConstraint;
    pub const registerOperationResultTypeConstraint = ops_ctx.registerOperationResultTypeConstraint;
    pub const registerOperationTraitId = ops_ctx.registerOperationTraitId;
    pub const registerOperationTrait = ops_ctx.registerOperationTrait;
    pub const allocateValueId = resources.allocateValueId;
    pub const operationCount = resources.operationCount;
    pub const operationCreationBoundary = resources.operationCreationBoundary;
    pub const eraseOperationsCreatedSince = resources.eraseOperationsCreatedSince;
    pub const containsOperation = resources.containsOperation;
    pub const listsOperation = resources.listsOperation;

    /// A count that moves whenever operation storage outside the fixed pools goes back to the
    /// segment. `containsOperation` states what a caller may read while it stands still.
    pub fn operationReleaseEpoch(self: *Context) u64 {
        return operationStorageAllocator(self).backing_releases;
    }
    pub const createOperation = ops_ctx.createOperation;
    pub const untrackOperation = resources.untrackOperation;
    pub const getTypeRegistry = type_ctx.getTypeRegistry;
    pub const lookupType = type_ctx.lookupType;
    pub const registerType = type_ctx.registerType;
    pub const registerTypeBatch = type_ctx.registerTypeBatch;
    pub const registerTypeInterface = type_ctx.registerTypeInterface;
    pub const registerTypeInterfaceExternal = type_ctx.registerTypeInterfaceExternal;
    pub fn TypeInterfaceHandle(comptime IFace: type) type {
        return type_ctx.TypeInterfaceHandle(Context, IFace);
    }
    pub const typeInterface = type_ctx.typeInterface;
    pub const getTypeInterface = type_ctx.getTypeInterface;
    pub const getTypeParamPayloadRaw = type_ctx.getTypeParamPayloadRaw;
    pub const getTypeParamPayload = type_ctx.getTypeParamPayload;
    pub const getDialectType = type_ctx.getDialectType;
    pub const getDialectTypeWithKey = type_ctx.getDialectTypeWithKey;
    pub const getDialectTypeFromName = type_ctx.getDialectTypeFromName;
    pub const getDialectTypeFromNameWithKey = type_ctx.getDialectTypeFromNameWithKey;
    pub const lookupAttributeType = attr_ctx.lookupAttributeType;
    pub const registerAttributeType = attr_ctx.registerAttributeType;
    pub const registerAttributeInterfaceExternal = attr_ctx.registerAttributeInterfaceExternal;
    pub const getDialectAttr = attr_ctx.getDialectAttr;
    pub const getIntegerAttr = attr_ctx.getIntegerAttr;
    pub const getI64Attr = attr_ctx.getI64Attr;
    pub const getI32Attr = attr_ctx.getI32Attr;
    pub const getFloatAttr = attr_ctx.getFloatAttr;
    pub const getF64Attr = attr_ctx.getF64Attr;
    pub const getF32Attr = attr_ctx.getF32Attr;
    pub const getBoolAttr = attr_ctx.getBoolAttr;
    pub const getStringAttr = attr_ctx.getStringAttr;
    pub const getSymbolRefAttr = attr_ctx.getSymbolRefAttr;
    pub const getFlatSymbolRefAttr = attr_ctx.getFlatSymbolRefAttr;
    pub const getStringListAttr = attr_ctx.getStringListAttr;
    pub const getTypeListAttr = attr_ctx.getTypeListAttr;
    pub const getArrayAttr = attr_ctx.getArrayAttr;
    pub const freeze = freeze_ctx.freeze;
    pub const isFrozen = freeze_ctx.isFrozen;
};

pub fn operationStorageAllocator(context: *Context) *core.Operation.StorageAllocator {
    return @ptrCast(@alignCast(&context.operation_storage_allocator));
}

fn diagnosticPayloadAllocator(context: *Context) std.mem.Allocator {
    return memory_ctx.diagnosticPayloadAllocator(context.memory);
}

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Context);
}

fn saturatingPassRunAdd(comptime Int: type, current: Int, additional: u64) Int {
    const maximum: u64 = std.math.maxInt(Int);
    const bounded: Int = @intCast(@min(additional, maximum));
    return current +| bounded;
}

const AfterLoadTestState = struct {
    var extension_called: bool = false;
    var vtable: u8 = 99;
};

const ImmediateExtensionTestState = struct {
    var extension_called: bool = false;
    var vtable: u8 = 77;
};

const MultipleExtensionsTestState = struct {
    var call_count: u32 = 0;
};

const DuplicateInterfaceTestState = struct {
    var original_vtable: u8 = 1;
    var replacement_vtable: u8 = 2;
};

fn test_type_verify_noop(_: *const anyopaque) anyerror!void {}

fn test_extension_noop(_: *Context) anyerror!void {}

fn test_loader_noop(_: *Context) anyerror!void {}

fn after_load_test_loader(c: *Context) anyerror!void {
    _ = try c.registerOperation("ext_test.op", .{ .is_idempotent = true });
}

fn after_load_test_extension(c: *Context) anyerror!void {
    AfterLoadTestState.extension_called = true;
    const effect_id = interfaces.interfaceId("ext_test.interface");
    try c.registerOperationInterface("ext_test.op", .{
        .id = effect_id,
        .vtable = &AfterLoadTestState.vtable,
    });
}

fn immediate_extension_test_loader(c: *Context) anyerror!void {
    _ = try c.registerOperation("imm_test.op", .{ .is_idempotent = true });
}

fn immediate_extension_test_extension(c: *Context) anyerror!void {
    ImmediateExtensionTestState.extension_called = true;
    const effect_id = interfaces.interfaceId("imm_test.interface");
    try c.registerOperationInterface("imm_test.op", .{
        .id = effect_id,
        .vtable = &ImmediateExtensionTestState.vtable,
    });
}

fn multiple_extensions_test_loader(c: *Context) anyerror!void {
    _ = try c.registerOperation("multi_ext.op", .{});
}

fn multiple_extensions_test_add_one(_: *Context) anyerror!void {
    MultipleExtensionsTestState.call_count += 1;
}

fn multiple_extensions_test_add_ten(_: *Context) anyerror!void {
    MultipleExtensionsTestState.call_count += 10;
}

fn duplicate_interface_test_loader(c: *Context) anyerror!void {
    _ = try c.registerOperation("dup_iface.op", .{ .is_idempotent = true });
    const effect_id = interfaces.interfaceId("dup_iface.interface1");
    try c.registerOperationInterface("dup_iface.op", .{
        .id = effect_id,
        .vtable = &DuplicateInterfaceTestState.original_vtable,
    });
}

fn duplicate_interface_test_extension(c: *Context) anyerror!void {
    const effect_id = interfaces.interfaceId("dup_iface.interface1");
    const result = c.registerOperationInterface("dup_iface.op", .{
        .id = effect_id,
        .vtable = &DuplicateInterfaceTestState.replacement_vtable,
    });
    try std.testing.expectError(error.DuplicateInterface, result);
}
