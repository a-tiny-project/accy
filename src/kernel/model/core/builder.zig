const std = @import("std");
const gpu_abi = @import("gpu_abi");
const testing = std.testing;

const alloc_phase = @import("alloc_phase");
const choir = @import("choir");
const gpu = choir.dialects.gpu;

const ir = choir.ir;
const dialects = choir.dialects;
const ArithDialect = dialects.ArithDialect;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const GpuDialect = gpu.GpuDialect;
const MemrefDialect = dialects.MemrefDialect;
const ScfDialect = dialects.ScfDialect;

pub const Dimension = gpu.Dimension;
pub const AddressSpace = dialects.AddressSpace;
pub const AtomicRmwKind = dialects.AtomicRmwKind;
pub const MemoryOrder = gpu.MemoryOrder;
pub const Scope = gpu.Scope;
pub const MmaShape = gpu.MmaShape;
pub const ShuffleMode = gpu.ShuffleMode;
pub const WarpOpKind = gpu.WarpOpKind;
pub const BackendError = choir.backends.interface.BackendError;
pub const FingerprintError = choir.OperationFingerprintError;

pub const WarpScanMode = enum {
    inclusive,
    exclusive,
};

const DType = gpu_abi.DType;

pub const Compare = dialects.arith.CmpPredicate;
pub const VerificationDiagnostic = choir.backends.contract.VerificationDiagnostic;

/// A caller passes this to a kernel builder to say which dialects, named groups of compiler
/// operations, are needed by the kernel's own compiler context, the object that owns the dialects,
/// types and operations of one compiler module. The builder reads the value once while setting up a
/// compiler context it owns and before that context is frozen. `registrations` lists dialects to
/// register and then load, and `preload` lists names of dialects already registered with the
/// compiler, which are loaded by name. The context copies each name it keeps, so the caller's
/// slices only need to live through setup.
pub const ContextRequirements = struct {
    registrations: []const choir.extensions.DialectRegistration = &.{},
    preload: []const []const u8 = &.{},

    pub fn prepare(self: ContextRequirements, ctx: *ir.Context) !void {
        const extension = choir.extensions.PackageExtension{
            .name = "accy-kernel-context",
            .dialects = self.registrations,
        };
        try extension.registerContext(ctx);
        for (self.registrations) |registration| {
            _ = try ctx.getOrLoadDialect(registration.name);
        }
        for (self.preload) |name| _ = try ctx.getOrLoadDialect(name);
    }
};

pub const Type = struct {
    value: ir.Type,

    fn raw(self: Type) ir.Type {
        return self.value;
    }

    pub fn eql(self: Type, other: Type) bool {
        return self.value.eql(other.value);
    }
};

pub const Value = struct {
    ptr: *ir.Value,

    fn raw(self: Value) *ir.Value {
        return self.ptr;
    }

    pub fn valueType(self: Value) Type {
        return .{ .value = self.ptr.type };
    }

    pub fn eql(self: Value, other: Value) bool {
        return self.ptr == other.ptr;
    }
};

pub const Block = struct {
    ptr: *ir.Block,

    fn raw(self: Block) *ir.Block {
        return self.ptr;
    }

    pub fn argument(self: Block, index: usize) ?Value {
        return wrapOptionalValue(self.ptr.getArgument(index));
    }
};

pub const If = struct {
    op: ScfDialect.IfOp,

    pub fn thenBlock(self: If) Block {
        return wrapBlock(self.op.getThenBlock());
    }

    pub fn elseBlock(self: If) ?Block {
        const block = self.op.getElseBlock() orelse return null;
        return wrapBlock(block);
    }

    pub fn result(self: *const If, index: usize) ?Value {
        return wrapOptionalValue(self.op.getResult(index));
    }

    pub fn resultCount(self: If) usize {
        return self.op.getNumResults();
    }

    fn raw(self: If) ScfDialect.IfOp {
        return self.op;
    }
};

pub const For = struct {
    op: ScfDialect.ForOp,

    pub fn bodyBlock(self: For) Block {
        return wrapBlock(self.op.getBodyBlock());
    }

    pub fn inductionVar(self: For) Value {
        return wrapValue(self.op.getInductionVar());
    }

    pub fn iterArg(self: For, index: usize) ?Value {
        const args = self.op.getIterArgs();
        if (index >= args.len) return null;
        return wrapValue(args[index]);
    }

    pub fn result(self: *const For, index: usize) ?Value {
        return wrapOptionalValue(self.op.getResult(index));
    }

    fn raw(self: For) ScfDialect.ForOp {
        return self.op;
    }
};

pub const ForScope = struct {
    builder: *Builder,
    loop: For,
    previous: Block,
    active: bool = true,

    pub fn inductionVar(self: ForScope) Value {
        return self.loop.inductionVar();
    }

    pub fn iterArg(self: ForScope, index: usize) ?Value {
        return self.loop.iterArg(index);
    }

    pub fn result(self: *const ForScope, index: usize) ?Value {
        return self.loop.result(index);
    }

    pub fn leave(self: *ForScope, values: []const Value) !void {
        if (!self.active) return;
        errdefer self.builder.setInsertionBlock(self.previous);
        try self.builder.yield_(values);
        self.builder.setInsertionBlock(self.previous);
        self.active = false;
    }

    pub fn abort(self: *ForScope) void {
        if (!self.active) return;
        self.builder.setInsertionBlock(self.previous);
        self.active = false;
    }
};

pub const While = struct {
    op: ScfDialect.WhileOp,

    pub fn beforeBlock(self: While) Block {
        return wrapBlock(self.op.getBeforeBlock());
    }

    pub fn afterBlock(self: While) Block {
        return wrapBlock(self.op.getAfterBlock());
    }

    pub fn result(self: *const While, index: usize) ?Value {
        return wrapOptionalValue(self.op.op.getResult(index));
    }

    fn raw(self: While) ScfDialect.WhileOp {
        return self.op;
    }
};

pub const WhileScope = struct {
    builder: *Builder,
    loop: While,
    previous: Block,
    phase: Phase = .before,

    const Phase = enum { before, after, done };

    pub fn beforeArg(self: WhileScope, index: usize) ?Value {
        return self.loop.beforeBlock().argument(index);
    }

    pub fn afterArg(self: WhileScope, index: usize) ?Value {
        return self.loop.afterBlock().argument(index);
    }

    pub fn result(self: *const WhileScope, index: usize) ?Value {
        return self.loop.result(index);
    }

    pub fn condition(self: *WhileScope, cond: Value, args: []const Value) !void {
        if (self.phase != .before) return error.WhileScopeMisused;
        try self.builder.condition_(cond, args);
        self.builder.setInsertionBlock(self.loop.afterBlock());
        self.phase = .after;
    }

    pub fn leave(self: *WhileScope, values: []const Value) !void {
        if (self.phase != .after) return error.WhileScopeMisused;
        errdefer self.builder.setInsertionBlock(self.previous);
        try self.builder.yield_(values);
        self.builder.setInsertionBlock(self.previous);
        self.phase = .done;
    }

    pub fn abort(self: *WhileScope) void {
        if (self.phase == .done) return;
        self.builder.setInsertionBlock(self.previous);
        self.phase = .done;
    }
};

const State = struct {
    ctx: *ir.Context,
    module: *ir.Operation,
    func: FuncDialect.FuncOp,
    params: []Param,
    decoded: ?choir.bytecode.DecodedModule = null,
};

pub const Buffer = struct {
    dtype: DType,
    size: ?u64 = null,
    space: AddressSpace = .device,

    pub fn eql(self: Buffer, other: Buffer) bool {
        return self.dtype == other.dtype and self.size == other.size and self.space == other.space;
    }
};

pub const Param = union(enum) {
    scalar: DType,
    buffer: Buffer,

    pub fn getType(self: Param, ctx: *ir.Context) !ir.Type {
        return switch (self) {
            .scalar => |dtype| scalarType(ctx, dtype),
            .buffer => |buf| bufferType(ctx, buf),
        };
    }

    pub fn eql(self: Param, other: Param) bool {
        return switch (self) {
            .scalar => |dtype| switch (other) {
                .scalar => |other_dtype| dtype == other_dtype,
                .buffer => false,
            },
            .buffer => |spec| switch (other) {
                .scalar => false,
                .buffer => |other_spec| spec.eql(other_spec),
            },
        };
    }
};

pub fn paramsEql(lhs: []const Param, rhs: []const Param) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!left.eql(right)) return false;
    }
    return true;
}

pub fn scalar(dtype: DType) Param {
    return .{ .scalar = dtype };
}

pub fn buffer(dtype: DType, size: u64) Param {
    return .{ .buffer = .{ .dtype = dtype, .size = size } };
}

pub fn dynamicBuffer(dtype: DType) Param {
    return .{ .buffer = .{ .dtype = dtype } };
}

pub const Storage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    storage: [*]u8,
    context: *ir.Context,
    state: *State,
    params: []Param,
    values: []*ir.Value,
    types: []ir.Type,
    owns_context: bool,
    parameters_high_water: usize,
    kernel_name_bytes_high_water: usize,
    temporary_values_high_water: usize,
    temporary_types_high_water: usize,

    pub const Limits = @import("limits.zig").RawLimits;

    pub const Capacity = struct {
        context: ir.Context.Capacity,
        parameters: usize,
        kernel_name_bytes: usize,
        temporary_values: usize,
        temporary_types: usize,
        context_offset: usize,
        state_offset: usize,
        parameters_offset: usize,
        values_offset: usize,
        types_offset: usize,
        storage_bytes: usize,
        storage_alignment: std.mem.Alignment,
        borrowed_acquired_bytes: usize,
        owned_acquired_bytes: usize,

        pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
            const context = try ir.Context.Capacity.derive(limits.context);
            var cursor: usize = 0;
            var alignment: usize = 1;
            const context_offset = try placeSlice(ir.Context, 1, &cursor, &alignment);
            const state_offset = try placeSlice(State, 1, &cursor, &alignment);
            const parameters_offset = try placeSlice(Param, limits.parameters, &cursor, &alignment);
            const values_offset = try placeSlice(
                *ir.Value,
                limits.temporary_values,
                &cursor,
                &alignment,
            );
            const types_offset = try placeSlice(
                ir.Type,
                limits.temporary_types,
                &cursor,
                &alignment,
            );
            if (cursor == 0) cursor = 1;
            const owned_acquired_bytes = std.math.add(
                usize,
                cursor,
                context.storage_bytes,
            ) catch return error.CapacityOverflow;
            return .{
                .context = context,
                .parameters = limits.parameters,
                .kernel_name_bytes = limits.kernel_name_bytes,
                .temporary_values = limits.temporary_values,
                .temporary_types = limits.temporary_types,
                .context_offset = context_offset,
                .state_offset = state_offset,
                .parameters_offset = parameters_offset,
                .values_offset = values_offset,
                .types_offset = types_offset,
                .storage_bytes = cursor,
                .storage_alignment = .fromByteUnits(alignment),
                .borrowed_acquired_bytes = cursor,
                .owned_acquired_bytes = owned_acquired_bytes,
            };
        }
    };

    pub const Exhaustion = error{
        ContextCapacityExceeded,
        ParameterCapacityExceeded,
        KernelNameCapacityExceeded,
        TemporaryValueCapacityExceeded,
        TemporaryTypeCapacityExceeded,
    };

    pub const Usage = struct {
        parameters: usize,
        kernel_name_bytes: usize,
        temporary_values: usize,
        temporary_types: usize,
    };

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "accy.kernel_raw_builder_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "stable_builder_state_and_optional_owned_choir_context_handle",
                        .lifetime = .steady,
                        .detail = "stable Builder state and optional owned Choir Context handle",
                    },
                    .{
                        .id = "retained_kernel_parameter_schema",
                        .lifetime = .transferred,
                        .detail = "retained kernel parameter schema",
                    },
                    .{
                        .id = "bounded_value_and_type_conversion_scratch",
                        .lifetime = .initialization,
                        .detail = "bounded value and type conversion scratch",
                    },
                    .{
                        .id = "caller_bounded_kernel_name_admitted_into_choir_context_storage",
                        .lifetime = .transferred,
                        .detail = "caller-bounded kernel name admitted into Choir Context storage",
                    },
                    .{
                        .id = "owned_choir_context_storage_and_all_retained_ir",
                        .lifetime = .transferred,
                        .detail = "owned Choir Context storage and all retained IR",
                    },
                },
                .excluded = &.{
                    "borrowed Choir Context storage supplied by initBorrowing",
                    "caller allocator implementation state and caller-owned diagnostic output",
                    "program Schedule, Snapshot, replay, backend, and oracle owners",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_attributes_payload_bytes",
                        "context.attributes.payload_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_attributes_table_bytes",
                        "context.attributes.table_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_configuration_interface_bytes",
                        "context.configuration.interface_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_configuration_name_bytes",
                        "context.configuration.name_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_configuration_table_bytes",
                        "context.configuration.table_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_configuration_transaction_bytes",
                        "context.configuration.transaction_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_diagnostics_handler_bytes",
                        "context.diagnostics.handler_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_diagnostics_payload_bytes",
                        "context.diagnostics.payload_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_operations_nested_bytes",
                        "context.operations.nested_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_operations_storage_bytes",
                        "context.operations.storage_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_transient_bytes",
                        "context.transient_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_types_key_bytes",
                        "context.types.key_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_types_payload_bytes",
                        "context.types.payload_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "context_types_table_bytes",
                        "context.types.table_bytes",
                    ),
                    alloc_phase.capacity.bindInput(
                        Limits,
                        "kernel_name_bytes",
                        "kernel_name_bytes",
                    ),
                    alloc_phase.capacity.bindInput(Limits, "parameters", "parameters"),
                    alloc_phase.capacity.bindInput(Limits, "temporary_types", "temporary_types"),
                    alloc_phase.capacity.bindInput(Limits, "temporary_values", "temporary_values"),
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
                    .{ .input = 14 },
                    .{ .input = 15 },
                    .{ .input = 16 },
                    .{ .input = 17 },
                    .{ .add = .{ .left = 0, .right = 1 } },
                    .{ .add = .{ .left = 18, .right = 2 } },
                    .{ .add = .{ .left = 19, .right = 3 } },
                    .{ .add = .{ .left = 20, .right = 4 } },
                    .{ .add = .{ .left = 21, .right = 5 } },
                    .{ .add = .{ .left = 22, .right = 6 } },
                    .{ .add = .{ .left = 23, .right = 7 } },
                    .{ .add = .{ .left = 24, .right = 8 } },
                    .{ .add = .{ .left = 25, .right = 9 } },
                    .{ .add = .{ .left = 26, .right = 10 } },
                    .{ .add = .{ .left = 27, .right = 11 } },
                    .{ .add = .{ .left = 28, .right = 12 } },
                    .{ .add = .{ .left = 29, .right = 13 } },
                    .{ .add = .{ .left = 30, .right = 14 } },
                    .{ .add = .{ .left = 31, .right = 15 } },
                    .{ .add = .{ .left = 32, .right = 16 } },
                    .{ .add = .{ .left = 33, .right = 17 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .upper_bound,
                    .expression = 34,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "name, parameter, scratch, Context budget, arithmetic, and fixed " ++
                    "Context exhaustion reject before publishing partial Builder state",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "Builder methods use only preacquired local scratch and the " ++
                        "independently bounded Choir Context",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "kernel construction crosses no foreign or operating-system boundary",
                },
            },
            .dependencies = &.{"choir.context"},
            .obligations = &.{
                .{ .key = "accy_kernel_raw_builder_capacity", .role = .capacity_model },
                .{ .key = "accy_kernel_raw_builder_boundary", .role = .overload },
                .{ .key = "accy_kernel_raw_builder_context_boundary", .role = .overload },
                .{ .key = "accy_kernel_raw_builder_sealed_construction", .role = .transitive_risk },
                .{ .key = "accy_kernel_raw_builder_transfer", .role = .foreign_risk },
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

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Storage {
        var storage = try acquire(allocator, limits);
        errdefer releaseStorage(&storage, allocator);
        storage.context.* = try ir.Context.init(allocator, limits.context);
        storage.owns_context = true;
        return storage;
    }

    pub fn initBorrowing(
        allocator: std.mem.Allocator,
        limits: Limits,
        context: *ir.Context,
    ) !Storage {
        var storage = try acquire(allocator, limits);
        storage.context = context;
        return storage;
    }

    fn acquire(allocator: std.mem.Allocator, limits: Limits) !Storage {
        const capacity = try Capacity.derive(limits);
        const storage = allocator.rawAlloc(
            capacity.storage_bytes,
            capacity.storage_alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .storage = storage,
            .context = &typedSlice(ir.Context, storage, capacity.context_offset, 1)[0],
            .state = &typedSlice(State, storage, capacity.state_offset, 1)[0],
            .params = typedSlice(Param, storage, capacity.parameters_offset, capacity.parameters),
            .values = typedSlice(
                *ir.Value,
                storage,
                capacity.values_offset,
                capacity.temporary_values,
            ),
            .types = typedSlice(ir.Type, storage, capacity.types_offset, capacity.temporary_types),
            .owns_context = false,
            .parameters_high_water = 0,
            .kernel_name_bytes_high_water = 0,
            .temporary_values_high_water = 0,
            .temporary_types_high_water = 0,
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        if (self.owns_context) self.context.activate();
        self.phase = .steady;
    }

    pub fn require(self: *Storage, usage: Usage) Exhaustion!void {
        if (usage.parameters > self.capacity.parameters) return error.ParameterCapacityExceeded;
        if (usage.kernel_name_bytes > self.capacity.kernel_name_bytes) {
            return error.KernelNameCapacityExceeded;
        }
        if (usage.temporary_values > self.capacity.temporary_values) {
            return error.TemporaryValueCapacityExceeded;
        }
        if (usage.temporary_types > self.capacity.temporary_types) {
            return error.TemporaryTypeCapacityExceeded;
        }
        self.parameters_high_water = @max(self.parameters_high_water, usage.parameters);
        self.kernel_name_bytes_high_water = @max(
            self.kernel_name_bytes_high_water,
            usage.kernel_name_bytes,
        );
        self.temporary_values_high_water = @max(
            self.temporary_values_high_water,
            usage.temporary_values,
        );
        self.temporary_types_high_water = @max(
            self.temporary_types_high_water,
            usage.temporary_types,
        );
    }

    pub fn capacityUsage(self: *const Storage) Usage {
        return .{
            .parameters = self.parameters_high_water,
            .kernel_name_bytes = self.kernel_name_bytes_high_water,
            .temporary_values = self.temporary_values_high_water,
            .temporary_types = self.temporary_types_high_water,
        };
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        if (self.owns_context) self.context.deinit(allocator);
        releaseStorage(self, allocator);
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
}

fn releaseStorage(storage_owner: *Storage, allocator: std.mem.Allocator) void {
    const storage = storage_owner.storage;
    const capacity = storage_owner.capacity;
    storage_owner.phase = .teardown;
    storage_owner.* = undefined;
    allocator.rawFree(
        storage[0..capacity.storage_bytes],
        capacity.storage_alignment,
        @returnAddress(),
    );
}

pub const Kernel = struct {
    allocator: std.mem.Allocator,
    capacity: Builder.Capacity,
    storage: Storage,
    state: *State,

    /// A caller uses this to wrap a kernel module decoded from bytes as a ready kernel, to avoid
    /// building it again. The kernel takes ownership of the decoded module, its tables, and the
    /// storage passed in on success, and the caller keeps all three on failure because
    /// `storage_value` is passed by value. The caller decodes the module through the operation
    /// allocator of the storage's compiler context before the call, and the call asserts this
    /// requirement. `function` must be a kernel with a body and a name inside the decoded module,
    /// and its arguments must match `parameters` in count and type, and otherwise the call returns
    /// `error.InvalidKernel`. The call also returns a storage capacity error when the name or
    /// parameters exceed the storage, or a verification error when the module fails to verify. The
    /// parameters are copied into the kernel's storage, so the caller's slice only needs to live
    /// through the call.
    pub fn fromDecoded(
        allocator: std.mem.Allocator,
        storage_value: Storage,
        decoded: choir.bytecode.DecodedModule,
        function: FuncDialect.FuncOp,
        parameters: []const Param,
    ) !Kernel {
        const module_op = decoded.module;
        const retained = ir.context.operationAllocator(storage_value.context);
        std.debug.assert(decoded.tables.allocator.ptr == retained.ptr);
        std.debug.assert(decoded.tables.allocator.vtable == retained.vtable);
        std.debug.assert(storage_value.phase == .initialization);
        std.debug.assert(module_op.context == storage_value.context);
        if (!module_op.isProperAncestor(function.op) or !function.isKernel() or
            !function.hasBody() or function.getNumArguments() != parameters.len)
        {
            return error.InvalidKernel;
        }
        const name = function.getName() orelse return error.InvalidKernel;
        var storage = storage_value;
        try storage.require(.{
            .parameters = parameters.len,
            .kernel_name_bytes = name.len,
            .temporary_values = 0,
            .temporary_types = 0,
        });
        for (parameters, function.getArguments()) |parameter, argument| {
            if (!argument.type.eql(try parameter.getType(storage.context))) {
                return error.InvalidKernel;
            }
        }
        try ir.verifyOperation(module_op, ir.verify.default_options);
        const params_copy = storage.params[0..parameters.len];
        @memcpy(params_copy, parameters);
        storage.state.* = .{
            .ctx = storage.context,
            .module = module_op,
            .func = function,
            .params = params_copy,
            .decoded = decoded,
        };
        storage.activate();
        return .{
            .allocator = allocator,
            .capacity = storage.capacity,
            .storage = storage,
            .state = storage.state,
        };
    }

    pub fn deinit(self: *Kernel) void {
        destroyState(self.state, self.allocator, &self.storage);
        self.* = undefined;
    }

    pub fn verify(self: *Kernel) !void {
        try ir.verifyOperation(self.state.module, ir.verify.default_options);
    }

    pub fn verifyWithDiagnostic(self: *Kernel, diagnostic: *VerificationDiagnostic) !void {
        try choir.backends.contract.verifyModuleWithDiagnostic(
            "accy/kernel/verify",
            self.state.module,
            diagnostic,
        );
    }

    pub fn fingerprint(self: *const Kernel, allocator: std.mem.Allocator) FingerprintError!u64 {
        return choir.operationFingerprint(allocator, self.state.module);
    }

    pub fn func(self: *const Kernel) FuncDialect.FuncOp {
        return self.state.func;
    }

    pub fn module(self: *const Kernel) *ir.Operation {
        return self.state.module;
    }

    pub fn params(self: *const Kernel) []const Param {
        return self.state.params;
    }

    pub fn capacityUsage(self: *const Kernel) Builder.Usage {
        return self.storage.capacityUsage();
    }

    pub fn acquiredBytes(self: *const Kernel) usize {
        return acquiredBytesForStorage(&self.storage);
    }

    pub fn contextCapacityUsage(self: *const Kernel) ir.Context.Usage {
        return self.state.ctx.capacityUsage();
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    capacity: Capacity,
    storage: Storage,
    state: *State,
    insertion_block: *ir.Block,
    loc: ir.Location,
    finished: bool = false,
    terminated: bool = false,

    pub const Limits = @import("limits.zig").RawLimits;
    pub const Capacity = Storage.Capacity;
    pub const Usage = Storage.Usage;

    pub fn init(
        backing: std.mem.Allocator,
        limits: Limits,
        kernel_name: []const u8,
        params: []const Param,
        requirements: ContextRequirements,
    ) !Builder {
        try validateInputs(limits, kernel_name, params);
        var storage = try Storage.init(backing, limits);
        errdefer storage.deinit(backing);
        try dialects.registerChoirDialect(storage.context);
        try requirements.prepare(storage.context);
        return initIn(backing, storage, storage.context, kernel_name, params);
    }

    pub fn initBorrowing(
        backing: std.mem.Allocator,
        limits: Limits,
        ctx: *ir.Context,
        kernel_name: []const u8,
        params: []const Param,
    ) !Builder {
        try validateInputs(limits, kernel_name, params);
        try requireContextBudget(ctx, limits.context);
        var storage = try Storage.initBorrowing(backing, limits, ctx);
        errdefer storage.deinit(backing);
        return initIn(backing, storage, ctx, kernel_name, params);
    }

    fn initIn(
        backing: std.mem.Allocator,
        storage_value: Storage,
        ctx: *ir.Context,
        kernel_name: []const u8,
        params: []const Param,
    ) !Builder {
        var storage = storage_value;
        try storage.require(.{
            .parameters = params.len,
            .kernel_name_bytes = kernel_name.len,
            .temporary_values = 0,
            .temporary_types = params.len,
        });
        const state = storage.state;
        const owned_params = storage.params[0..params.len];
        @memcpy(owned_params, params);

        const loc = ir.Location.getUnknown();
        const module = try BuiltinDialect.ModuleOp.create(ctx, loc);
        errdefer module.op.erase();

        const input_types = storage.types[0..params.len];
        for (params, 0..) |param, i| {
            input_types[i] = try param.getType(ctx);
        }

        var func = try FuncDialect.FuncOp.createKernel(ctx, loc, kernel_name, input_types);
        errdefer if (func.op.getBlock() == null) func.op.erase();
        try module.getBodyBlock().addOperation(func.op);
        state.* = .{
            .ctx = ctx,
            .module = module.op,
            .func = func,
            .params = owned_params,
        };

        return .{
            .allocator = backing,
            .capacity = storage.capacity,
            .storage = storage,
            .state = state,
            .insertion_block = func.getEntryBlock(),
            .loc = loc,
        };
    }

    pub fn deinit(self: *Builder) void {
        if (!self.finished) {
            destroyState(self.state, self.allocator, &self.storage);
        }
        self.* = undefined;
    }

    pub fn capacityUsage(self: *const Builder) Usage {
        return self.storage.capacityUsage();
    }

    pub fn acquiredBytes(self: *const Builder) usize {
        return acquiredBytesForStorage(&self.storage);
    }

    pub fn contextCapacityUsage(self: *const Builder) ir.Context.Usage {
        return self.state.ctx.capacityUsage();
    }

    pub fn argument(self: *Builder, index: usize) Value {
        return wrapValue(self.state.func.getArgument(index));
    }

    pub fn entryBlock(self: *Builder) Block {
        return wrapBlock(self.state.func.getEntryBlock());
    }

    pub fn insertionBlock(self: *Builder) Block {
        return wrapBlock(self.insertion_block);
    }

    pub fn setInsertionBlock(self: *Builder, block: Block) void {
        self.insertion_block = block.ptr;
    }

    pub fn enterBlock(self: *Builder, block: Block) !InsertionScope {
        try self.ensureOpen();
        const previous = self.insertionBlock();
        self.setInsertionBlock(block);
        return .{
            .builder = self,
            .previous = previous,
        };
    }

    pub fn globalId(self: *Builder, dim: Dimension) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.GlobalIdxOp.create(self.state.ctx, self.loc, dim);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn threadId(self: *Builder, dim: Dimension) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.ThreadIdxOp.create(self.state.ctx, self.loc, dim);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn blockId(self: *Builder, dim: Dimension) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.BlockIdxOp.create(self.state.ctx, self.loc, dim);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn blockDim(self: *Builder, dim: Dimension) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.BlockDimOp.create(self.state.ctx, self.loc, dim);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn gridDim(self: *Builder, dim: Dimension) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.GridDimOp.create(self.state.ctx, self.loc, dim);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn laneId(self: *Builder) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.LaneIdOp.create(self.state.ctx, self.loc);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn warpId(self: *Builder) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.WarpIdOp.create(self.state.ctx, self.loc);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn constantInt(self: *Builder, dtype: DType, value: i64) !Value {
        try self.ensureOpen();
        const ty = try scalarType(self.state.ctx, dtype);
        var op = try ArithDialect.ConstantOp.createInt(self.state.ctx, self.loc, ty, value);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn constantIndex(self: *Builder, value: i64) !Value {
        try self.ensureOpen();
        const ty = try ArithDialect.getIndexType(self.state.ctx);
        var op = try ArithDialect.ConstantOp.createInt(self.state.ctx, self.loc, ty, value);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn constantFloat(self: *Builder, dtype: DType, value: f64) !Value {
        try self.ensureOpen();
        const ty = try scalarType(self.state.ctx, dtype);
        var op = try ArithDialect.ConstantOp.createFloat(self.state.ctx, self.loc, ty, value);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn constantBool(self: *Builder, value: bool) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.ConstantOp.createBool(self.state.ctx, self.loc, value);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn add(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.AddOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn sub(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.SubOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn mul(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.MulOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn div(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.DivOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn min(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.MinOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn max(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.MaxOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn and_(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.AndOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn or_(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.OrOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn xor(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.XorOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn not(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.NotOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn popcount(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.PopCountOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn shl(self: *Builder, value: Value, shift: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.ShlOp.create(self.state.ctx, self.loc, value.ptr, shift.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn shr(self: *Builder, value: Value, shift: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.ShrOp.create(self.state.ctx, self.loc, value.ptr, shift.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn ushr(self: *Builder, value: Value, shift: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.UshrOp.create(self.state.ctx, self.loc, value.ptr, shift.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn umulhi(self: *Builder, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.UmulhiOp.create(self.state.ctx, self.loc, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn bitcast(self: *Builder, input: Value, dtype: DType) !Value {
        try self.ensureOpen();
        const ty = try scalarType(self.state.ctx, dtype);
        var op = try ArithDialect.BitcastOp.create(self.state.ctx, self.loc, input.ptr, ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn neg(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.NegOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn abs(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.AbsOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn sqrt(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.SqrtOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn exp(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.ExpOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn log(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.LogOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn tanh(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.TanhOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn sin(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.SinOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn cos(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.CosOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn tan(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.TanOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn floor(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.FloorOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn round(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.RoundOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn trunc(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.TruncOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn tf32Round(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.Tf32RoundOp.create(self.state.ctx, self.loc, input.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn pow(self: *Builder, base: Value, exponent: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.PowOp.create(self.state.ctx, self.loc, base.ptr, exponent.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn atan2(self: *Builder, y: Value, x: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.Atan2Op.create(self.state.ctx, self.loc, y.ptr, x.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn fma(self: *Builder, a: Value, b: Value, c: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.FmaOp.create(self.state.ctx, self.loc, a.ptr, b.ptr, c.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn splatVector(self: *Builder, input: Value, width: u32) !Value {
        try self.ensureOpen();
        const result_ty = try scalarVectorType(self.state.ctx, input.ptr.type, width);
        var op = try ArithDialect.SplatOp.create(self.state.ctx, self.loc, input.ptr, result_ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn shuffleVector(self: *Builder, input: Value, indices: []const i64) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.VecShuffleOp.create(
            self.state.ctx,
            self.loc,
            input.ptr,
            input.ptr.type,
            indices,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn compare(self: *Builder, predicate: Compare, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        const lhs_is_vector = try valueIsVector(lhs.ptr);
        const rhs_is_vector = try valueIsVector(rhs.ptr);
        if (lhs_is_vector != rhs_is_vector) return error.UnsupportedVectorType;
        if (lhs_is_vector) {
            var op = try ArithDialect.VecCmpOp.create(
                self.state.ctx,
                self.loc,
                predicate,
                lhs.ptr,
                rhs.ptr,
                lhs.ptr.type,
            );
            try self.addOperation(op.op);
            return wrapValue(op.getResult());
        }
        var op = try ArithDialect.CmpOp.create(
            self.state.ctx,
            self.loc,
            predicate,
            lhs.ptr,
            rhs.ptr,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn select(self: *Builder, condition: Value, true_value: Value, false_value: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.SelectOp.create(
            self.state.ctx,
            self.loc,
            condition.ptr,
            true_value.ptr,
            false_value.ptr,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn cast(self: *Builder, input: Value, dtype: DType) !Value {
        try self.ensureOpen();
        const ty = try scalarType(self.state.ctx, dtype);
        var op = try ArithDialect.CastOp.create(self.state.ctx, self.loc, input.ptr, ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn castIndex(self: *Builder, input: Value) !Value {
        try self.ensureOpen();
        const ty = try ArithDialect.getIndexType(self.state.ctx);
        var op = try ArithDialect.CastOp.create(self.state.ctx, self.loc, input.ptr, ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn load(self: *Builder, memref: Value, index: Value) !Value {
        try self.ensureOpen();
        const elem_ty = try memrefElementType(self.state.ctx, memref.ptr.type);
        var op = try MemrefDialect.LoadOp.create(
            self.state.ctx,
            self.loc,
            memref.ptr,
            index.ptr,
            elem_ty,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn loadVector(self: *Builder, memref: Value, index: Value, width: u32) !Value {
        try self.ensureOpen();
        const result_ty = try memrefVectorType(self.state.ctx, memref.ptr.type, width);
        var op = try MemrefDialect.LoadOp.create(
            self.state.ctx,
            self.loc,
            memref.ptr,
            index.ptr,
            result_ty,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn extractLane(self: *Builder, vector: Value, lane: u32, dtype: DType) !Value {
        try self.ensureOpen();
        const result_ty = try scalarType(self.state.ctx, dtype);
        var op = try ArithDialect.ExtractOp.create(
            self.state.ctx,
            self.loc,
            vector.ptr,
            @intCast(lane),
            result_ty,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn insertLane(self: *Builder, vector: Value, lane_value: Value, lane: u32) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.InsertOp.create(
            self.state.ctx,
            self.loc,
            vector.ptr,
            lane_value.ptr,
            @intCast(lane),
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn packVector(self: *Builder, lanes: [4]Value) !Value {
        var vector = try self.splatVector(lanes[0], 4);
        for (lanes[1..], 1..) |lane_value, lane| {
            vector = try self.insertLane(vector, lane_value, @intCast(lane));
        }
        return vector;
    }

    pub fn sharedBuffer(self: *Builder, dtype: DType, size: u64) !Value {
        try self.ensureOpen();
        if (size == 0) return error.InvalidSize;
        const elem_ty = try scalarType(self.state.ctx, dtype);
        const memref_ty = try MemrefDialect.getMemrefType1D(self.state.ctx, size, elem_ty, .shared);
        var op = try MemrefDialect.AllocOp.createStatic(self.state.ctx, self.loc, memref_ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn dynamicSharedBuffer(self: *Builder, dtype: DType, size: u64, byte_offset: u64) !Value {
        try self.ensureOpen();
        if (size == 0) return error.InvalidSize;
        const elem_ty = try scalarType(self.state.ctx, dtype);
        const memref_ty = try MemrefDialect.getMemrefType1D(self.state.ctx, size, elem_ty, .shared);
        const dynamic_size = try self.constantIndex(
            std.math.cast(i64, size) orelse return error.IntegerOutOfBounds,
        );
        var op = try MemrefDialect.AllocOp.createDynamic(
            self.state.ctx,
            self.loc,
            dynamic_size.ptr,
            memref_ty,
        );
        var op_owned = true;
        errdefer if (op_owned) op.op.erase();
        try op.op.setAttr(
            gpu.attr_names.dynamic_shared_byte_offset,
            try self.state.ctx.getI64Attr(
                std.math.cast(i64, byte_offset) orelse return error.IntegerOutOfBounds,
            ),
        );
        op_owned = false;
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn store(self: *Builder, value: Value, memref: Value, index: Value) !void {
        try self.ensureOpen();
        const op = try MemrefDialect.StoreOp.create(
            self.state.ctx,
            self.loc,
            value.ptr,
            memref.ptr,
            index.ptr,
        );
        try self.addOperation(op.op);
    }

    pub fn atomicRmw(
        self: *Builder,
        kind: dialects.AtomicRmwKind,
        value: Value,
        memref: Value,
        index: Value,
    ) !Value {
        try self.ensureOpen();
        const elem_ty = try memrefElementType(self.state.ctx, memref.ptr.type);
        var op = try MemrefDialect.AtomicRmwOp.create(
            self.state.ctx,
            self.loc,
            kind,
            value.ptr,
            memref.ptr,
            index.ptr,
            elem_ty,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn atomicCas(
        self: *Builder,
        expected: Value,
        desired: Value,
        memref: Value,
        index: Value,
    ) !Value {
        try self.ensureOpen();
        const elem_ty = try memrefElementType(self.state.ctx, memref.ptr.type);
        var op = try MemrefDialect.AtomicCasOp.create(
            self.state.ctx,
            self.loc,
            expected.ptr,
            desired.ptr,
            memref.ptr,
            index.ptr,
            elem_ty,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn barrier(self: *Builder, scope: Scope) !void {
        try self.ensureOpen();
        const op = try GpuDialect.BarrierOp.create(self.state.ctx, self.loc, scope);
        try self.addOperation(op.op);
    }

    pub fn activeMask(self: *Builder) !Value {
        try self.ensureOpen();
        var op = try GpuDialect.ActiveMaskOp.create(self.state.ctx, self.loc);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn syncWarp(self: *Builder) !void {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        const op = try GpuDialect.SyncWarpOp.create(self.state.ctx, self.loc, mask.ptr);
        try self.addOperation(op.op);
    }

    pub fn allSync(self: *Builder, predicate: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.AllSyncOp.create(self.state.ctx, self.loc, mask.ptr, predicate.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn anySync(self: *Builder, predicate: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.AnySyncOp.create(self.state.ctx, self.loc, mask.ptr, predicate.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn ballotSync(self: *Builder, predicate: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.BallotSyncOp.create(
            self.state.ctx,
            self.loc,
            mask.ptr,
            predicate.ptr,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn warpReduce(self: *Builder, op_kind: WarpOpKind, value: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.WarpReduceOp.create(
            self.state.ctx,
            self.loc,
            op_kind,
            mask.ptr,
            value.ptr,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn warpScan(self: *Builder, op_kind: WarpOpKind, mode: WarpScanMode, value: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.WarpScanOp.create(
            self.state.ctx,
            self.loc,
            op_kind,
            mode == .inclusive,
            mask.ptr,
            value.ptr,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn shuffleSync(
        self: *Builder,
        mode: ShuffleMode,
        value: Value,
        lane_or_delta: Value,
    ) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.ShflSyncOp.create(
            self.state.ctx,
            self.loc,
            mode,
            mask.ptr,
            value.ptr,
            lane_or_delta.ptr,
        );
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn mmaSync(
        self: *Builder,
        shape: MmaShape,
        a: [4]Value,
        b: [2]Value,
        c: [4]Value,
    ) ![4]Value {
        try self.ensureOpen();
        var op = try GpuDialect.MmaSyncOp.create(
            self.state.ctx,
            self.loc,
            .{ a[0].ptr, a[1].ptr, a[2].ptr, a[3].ptr },
            .{ b[0].ptr, b[1].ptr },
            .{ c[0].ptr, c[1].ptr, c[2].ptr, c[3].ptr },
            shape,
        );
        try self.addOperation(op.op);
        return .{
            wrapValue(op.getD(0)),
            wrapValue(op.getD(1)),
            wrapValue(op.getD(2)),
            wrapValue(op.getD(3)),
        };
    }

    pub fn fence(self: *Builder, scope: Scope) !void {
        try self.ensureOpen();
        const op = try GpuDialect.FenceOp.create(self.state.ctx, self.loc, scope, .seq_cst);
        try self.addOperation(op.op);
    }

    pub fn asyncCopyShared(
        self: *Builder,
        dst: Value,
        dst_index: Value,
        src: Value,
        src_index: Value,
        bytes: u32,
    ) !void {
        try self.ensureOpen();
        const op = try GpuDialect.CpAsyncSharedOp.create(
            self.state.ctx,
            self.loc,
            dst.ptr,
            dst_index.ptr,
            src.ptr,
            src_index.ptr,
            bytes,
        );
        try self.addOperation(op.op);
    }

    pub fn asyncCopyCommit(self: *Builder) !void {
        try self.ensureOpen();
        const op = try GpuDialect.CpAsyncCommitOp.create(self.state.ctx, self.loc);
        try self.addOperation(op.op);
    }

    pub fn asyncCopyWait(self: *Builder, groups: u32) !void {
        try self.ensureOpen();
        const op = try GpuDialect.CpAsyncWaitOp.create(self.state.ctx, self.loc, groups);
        try self.addOperation(op.op);
    }

    fn fullWarpMask(self: *Builder) !Value {
        return self.constantInt(.i32, -1);
    }

    pub fn if_(self: *Builder, condition: Value, result_types: []const Type) !If {
        try self.ensureOpen();
        const raw_types = try self.rawTypes(result_types);
        const op = try ScfDialect.IfOp.create(self.state.ctx, self.loc, condition.ptr, raw_types);
        try self.addOperation(op.op);
        return .{ .op = op };
    }

    pub fn for_(
        self: *Builder,
        lower: Value,
        upper: Value,
        step: Value,
        init_args: []const Value,
        result_types: []const Type,
    ) !For {
        try self.ensureOpen();
        const raw_init_args = try self.rawValues(init_args);
        const raw_result_types = try self.rawTypes(result_types);
        const op = try ScfDialect.ForOp.create(
            self.state.ctx,
            self.loc,
            lower.ptr,
            upper.ptr,
            step.ptr,
            raw_init_args,
            raw_result_types,
        );
        try self.addOperation(op.op);
        return .{ .op = op };
    }

    pub fn forScope(
        self: *Builder,
        lower: Value,
        upper: Value,
        step: Value,
        init_args: []const Value,
        result_types: []const Type,
    ) !ForScope {
        const loop = try self.for_(lower, upper, step, init_args, result_types);
        const previous = self.insertionBlock();
        self.setInsertionBlock(loop.bodyBlock());
        return .{
            .builder = self,
            .loop = loop,
            .previous = previous,
        };
    }

    pub fn while_(self: *Builder, init_args: []const Value, result_types: []const Type) !While {
        try self.ensureOpen();
        const raw_init_args = try self.rawValues(init_args);
        const raw_result_types = try self.rawTypes(result_types);
        const op = try ScfDialect.WhileOp.create(
            self.state.ctx,
            self.loc,
            raw_init_args,
            raw_result_types,
        );
        try self.addOperation(op.op);
        return .{ .op = op };
    }

    pub fn whileScope(
        self: *Builder,
        init_args: []const Value,
        result_types: []const Type,
    ) !WhileScope {
        const loop = try self.while_(init_args, result_types);
        const previous = self.insertionBlock();
        self.setInsertionBlock(loop.beforeBlock());
        return .{
            .builder = self,
            .loop = loop,
            .previous = previous,
        };
    }

    pub fn condition_(self: *Builder, cond: Value, args: []const Value) !void {
        try self.ensureOpen();
        const raw_args = try self.rawValues(args);
        const op = try ScfDialect.ConditionOp.create(self.state.ctx, self.loc, cond.ptr, raw_args);
        try self.addOperation(op.op);
    }

    pub fn forDo(
        self: *Builder,
        lower: Value,
        upper: Value,
        step: Value,
        context: anytype,
        comptime body: anytype,
    ) !For {
        var scope = try self.forScope(lower, upper, step, &.{}, &.{});
        errdefer scope.abort();
        try body(self, scope.inductionVar(), context);
        try scope.leave(&.{});
        return scope.loop;
    }

    pub fn fold(
        self: *Builder,
        lower: Value,
        upper: Value,
        step: Value,
        initial: Value,
        context: anytype,
        comptime body: anytype,
    ) !Value {
        var scope = try self.forScope(lower, upper, step, &.{initial}, &.{initial.valueType()});
        errdefer scope.abort();
        const next = try body(self, scope.inductionVar(), scope.iterArg(0).?, context);
        try scope.leave(&.{next});
        return scope.result(0).?;
    }

    pub fn yield_(self: *Builder, values: []const Value) !void {
        try self.ensureOpen();
        const raw_values = try self.rawValues(values);
        const op = try ScfDialect.YieldOp.create(self.state.ctx, self.loc, raw_values);
        try self.addOperation(op.op);
    }

    pub fn return_(self: *Builder) !void {
        try self.ensureOpen();
        const op = try FuncDialect.ReturnOp.create(self.state.ctx, self.loc, &.{});
        try self.addOperation(op.op);
        self.terminated = true;
    }

    pub fn finish(self: *Builder) !Kernel {
        return self.finishChecking(null);
    }

    pub fn finishWithDiagnostic(self: *Builder, diagnostic: *VerificationDiagnostic) !Kernel {
        return self.finishChecking(diagnostic);
    }

    fn finishChecking(self: *Builder, diagnostic: ?*VerificationDiagnostic) !Kernel {
        if (!self.terminated) return error.MissingTerminator;
        if (diagnostic) |captured| {
            try choir.backends.contract.verifyModuleWithDiagnostic(
                "accy/kernel/finish",
                self.state.module,
                captured,
            );
        } else {
            try ir.verifyOperation(self.state.module, ir.verify.default_options);
        }
        if (self.storage.owns_context) {
            try ir.dialects.loadDialectSpec(self.state.ctx, GpuDialect.spec);
        }
        self.storage.activate();
        self.finished = true;
        return .{
            .allocator = self.allocator,
            .capacity = self.capacity,
            .storage = self.storage,
            .state = self.state,
        };
    }

    fn addOperation(self: *Builder, op: *ir.Operation) !void {
        errdefer if (op.getBlock() == null) op.erase();
        try self.insertion_block.addOperation(op);
    }

    fn ensureOpen(self: *const Builder) !void {
        if (self.finished) return error.AlreadyFinished;
        if (self.terminated) return error.AlreadyTerminated;
    }

    fn rawValues(self: *Builder, values: []const Value) ![]*ir.Value {
        try self.storage.require(.{
            .parameters = 0,
            .kernel_name_bytes = 0,
            .temporary_values = values.len,
            .temporary_types = 0,
        });
        const out = self.storage.values[0..values.len];
        for (values, out) |value, *raw| raw.* = value.ptr;
        return out;
    }

    fn rawTypes(self: *Builder, types: []const Type) ![]ir.Type {
        try self.storage.require(.{
            .parameters = 0,
            .kernel_name_bytes = 0,
            .temporary_values = 0,
            .temporary_types = types.len,
        });
        const out = self.storage.types[0..types.len];
        for (types, out) |ty, *raw| raw.* = ty.value;
        return out;
    }
};

pub const InsertionScope = struct {
    builder: *Builder,
    previous: Block,
    active: bool = true,

    pub fn leave(self: *InsertionScope) void {
        if (!self.active) return;
        self.builder.setInsertionBlock(self.previous);
        self.active = false;
    }
};

fn wrapValue(value: *ir.Value) Value {
    return .{ .ptr = value };
}

fn wrapOptionalValue(value: ?*ir.Value) ?Value {
    return wrapValue(value orelse return null);
}

fn wrapBlock(block: *ir.Block) Block {
    return .{ .ptr = block };
}

fn validateInputs(limits: Builder.Limits, kernel_name: []const u8, params: []const Param) !void {
    if (params.len > limits.parameters) return error.ParameterCapacityExceeded;
    if (params.len > limits.temporary_types) return error.TemporaryTypeCapacityExceeded;
    if (kernel_name.len > limits.kernel_name_bytes) return error.KernelNameCapacityExceeded;
}

fn requireContextBudget(ctx: *const ir.Context, limits: ir.Context.Limits) !void {
    if (limits.maximum_alignment.toByteUnits() > ctx.capacity.storage_alignment.toByteUnits()) {
        return error.ContextCapacityExceeded;
    }
    const usage = ctx.capacityUsage();
    try requireSegmentBudget(usage.configuration_tables, limits.configuration.table_bytes);
    try requireSegmentBudget(usage.configuration_names, limits.configuration.name_bytes);
    try requireSegmentBudget(usage.configuration_interfaces, limits.configuration.interface_bytes);
    try requireSegmentBudget(
        usage.configuration_transactions,
        limits.configuration.transaction_bytes,
    );
    try requireSegmentBudget(usage.type_tables, limits.types.table_bytes);
    try requireSegmentBudget(usage.type_keys, limits.types.key_bytes);
    try requireSegmentBudget(usage.type_payloads, limits.types.payload_bytes);
    try requireSegmentBudget(usage.attribute_tables, limits.attributes.table_bytes);
    try requireSegmentBudget(usage.attribute_payloads, limits.attributes.payload_bytes);
    try requireSegmentBudget(usage.operation_storage, limits.operations.storage_bytes);
    try requireSegmentBudget(usage.operation_nested, limits.operations.nested_bytes);
    try requireSegmentBudget(usage.diagnostic_handlers, limits.diagnostics.handler_bytes);
    try requireSegmentBudget(usage.diagnostic_payloads, limits.diagnostics.payload_bytes);
    try requireSegmentBudget(usage.transient, limits.transient_bytes);
}

fn requireSegmentBudget(usage: anytype, bytes: usize) !void {
    if (usage.remainingBytes() < bytes) return error.ContextCapacityExceeded;
}

fn destroyState(state: *State, allocator: std.mem.Allocator, storage: *Storage) void {
    state.module.erase();
    if (state.decoded) |*decoded| decoded.deinit();
    storage.deinit(allocator);
}

fn acquiredBytesForStorage(storage: *const Storage) usize {
    return if (storage.owns_context)
        storage.capacity.owned_acquired_bytes
    else
        storage.capacity.borrowed_acquired_bytes;
}

fn placeSlice(
    comptime T: type,
    count: usize,
    cursor: *usize,
    allocation_alignment: *usize,
) error{CapacityOverflow}!usize {
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.CapacityOverflow;
    const alignment = @alignOf(T);
    const mask = std.math.sub(usize, alignment, 1) catch unreachable;
    const padded = std.math.add(usize, cursor.*, mask) catch return error.CapacityOverflow;
    const offset = padded & ~mask;
    cursor.* = std.math.add(usize, offset, bytes) catch return error.CapacityOverflow;
    allocation_alignment.* = @max(allocation_alignment.*, alignment);
    return offset;
}

fn typedSlice(
    comptime T: type,
    storage: [*]u8,
    offset: usize,
    count: usize,
) []T {
    const pointer: [*]T = @ptrCast(@alignCast(storage + offset));
    return pointer[0..count];
}

fn bufferType(ctx: *ir.Context, buf: Buffer) !ir.Type {
    const elem = try scalarType(ctx, buf.dtype);
    if (buf.size) |size| {
        return MemrefDialect.getMemrefType1D(ctx, size, elem, buf.space);
    }
    return MemrefDialect.getMemrefTypeDynamic(ctx, elem, buf.space);
}

fn scalarType(ctx: *ir.Context, dtype: DType) !ir.Type {
    return ArithDialect.getScalarType(ctx, switch (dtype) {
        .i1 => .bool,
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .u8 => .u8,
        .u16 => .u16,
        .u32 => .u32,
        .u64 => .u64,
        .f16 => .f16,
        .bf16 => .bf16,
        .f32 => .f32,
        .f64 => .f64,
        .key => .i32,
    });
}

fn memrefElementType(ctx: *ir.Context, ty: ir.Type) !ir.Type {
    const payload = try ctx.getTypeParamPayload(ty, MemrefDialect.MemrefTypePayload) orelse
        return error.ExpectedMemref;
    return payload.element_type orelse error.ExpectedMemref;
}

fn memrefVectorType(ctx: *ir.Context, ty: ir.Type, width: u32) !ir.Type {
    const elem_ty = try memrefElementType(ctx, ty);
    const elem_name = elem_ty.getDialectTypeName() orelse return error.ExpectedMemref;
    return (try ArithDialect.getVecType(ctx, width, elem_name)) orelse error.UnsupportedVectorType;
}

fn scalarVectorType(ctx: *ir.Context, ty: ir.Type, width: u32) !ir.Type {
    const elem_name = ty.getDialectTypeName() orelse return error.UnsupportedVectorType;
    return (try ArithDialect.getVecType(ctx, width, elem_name)) orelse error.UnsupportedVectorType;
}

fn valueIsVector(value: *ir.Value) !bool {
    const type_name = value.type.getDialectTypeName() orelse return error.UnsupportedType;
    return dialects.arith.parseVectorTypeName(type_name) != null;
}

const KernelResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) KernelResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: KernelResourceCounts, ctx: *const ir.Context) !void {
        try testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn emptyContextLimits() ir.Context.Limits {
    return .{
        .maximum_alignment = .@"64",
        .configuration = .{
            .table_bytes = 0,
            .name_bytes = 0,
            .interface_bytes = 0,
            .transaction_bytes = 0,
        },
        .types = .{
            .table_bytes = 0,
            .key_bytes = 0,
            .payload_bytes = 0,
        },
        .attributes = .{
            .table_bytes = 0,
            .payload_bytes = 0,
        },
        .operations = .{
            .storage_bytes = 0,
            .nested_bytes = 0,
        },
        .diagnostics = .{
            .handler_bytes = 0,
            .payload_bytes = 0,
        },
        .transient_bytes = 0,
    };
}

fn checkBorrowedBuilderAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerChoirDialect(&ctx);
    const baseline = KernelResourceCounts.capture(&ctx);
    defer baseline.expectEqual(&ctx) catch unreachable;

    var builder = try Builder.initBorrowing(
        allocator,
        Builder.Limits.borrowed_testing,
        &ctx,
        "borrowed_failure_f32",
        &.{
            dynamicBuffer(.f32),
            dynamicBuffer(.f32),
        },
    );
    defer builder.deinit();

    const src = builder.argument(0);
    const dst = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(src, index);
    const zero = try builder.constantFloat(.f32, 0);
    _ = try builder.dynamicSharedBuffer(.f32, 16, 32);
    _ = try builder.atomicRmw(.add, value, dst, index);
    try builder.barrier(.block);
    try builder.fence(.device);
    const predicate = try builder.compare(.gt, value, zero);
    var branch = try builder.if_(predicate, &.{value.valueType()});
    {
        var scope = try builder.enterBlock(branch.thenBlock());
        defer scope.leave();
        try builder.yield_(&.{value});
    }
    {
        var scope = try builder.enterBlock(branch.elseBlock().?);
        defer scope.leave();
        try builder.yield_(&.{zero});
    }
    try builder.store(branch.result(0).?, dst, index);
    try builder.return_();

    var kernel = try builder.finish();
    defer kernel.deinit();
    try kernel.verify();
}
