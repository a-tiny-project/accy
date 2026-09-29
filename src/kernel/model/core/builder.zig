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
            const values_offset = try placeSlice(*ir.Value, limits.temporary_values, &cursor, &alignment);
            const types_offset = try placeSlice(ir.Type, limits.temporary_types, &cursor, &alignment);
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
                    alloc_phase.capacity.bindInput(Limits, "context_attributes_payload_bytes", "context.attributes.payload_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_attributes_table_bytes", "context.attributes.table_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_configuration_interface_bytes", "context.configuration.interface_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_configuration_name_bytes", "context.configuration.name_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_configuration_table_bytes", "context.configuration.table_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_configuration_transaction_bytes", "context.configuration.transaction_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_diagnostics_handler_bytes", "context.diagnostics.handler_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_diagnostics_payload_bytes", "context.diagnostics.payload_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_operations_nested_bytes", "context.operations.nested_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_operations_storage_bytes", "context.operations.storage_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_transient_bytes", "context.transient_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_types_key_bytes", "context.types.key_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_types_payload_bytes", "context.types.payload_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "context_types_table_bytes", "context.types.table_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "kernel_name_bytes", "kernel_name_bytes"),
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
                .detail = "name, parameter, scratch, Context budget, arithmetic, and fixed Context exhaustion reject before publishing partial Builder state",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "Builder methods use only preacquired local scratch and the independently bounded Choir Context",
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
            .values = typedSlice(*ir.Value, storage, capacity.values_offset, capacity.temporary_values),
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
        if (usage.kernel_name_bytes > self.capacity.kernel_name_bytes) return error.KernelNameCapacityExceeded;
        if (usage.temporary_values > self.capacity.temporary_values) return error.TemporaryValueCapacityExceeded;
        if (usage.temporary_types > self.capacity.temporary_types) return error.TemporaryTypeCapacityExceeded;
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
        try choir.backends.contract.verifyModuleWithDiagnostic("accy/kernel/verify", self.state.module, diagnostic);
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
        var op = try ArithDialect.VecShuffleOp.create(self.state.ctx, self.loc, input.ptr, input.ptr.type, indices);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn compare(self: *Builder, predicate: Compare, lhs: Value, rhs: Value) !Value {
        try self.ensureOpen();
        const lhs_is_vector = try valueIsVector(lhs.ptr);
        const rhs_is_vector = try valueIsVector(rhs.ptr);
        if (lhs_is_vector != rhs_is_vector) return error.UnsupportedVectorType;
        if (lhs_is_vector) {
            var op = try ArithDialect.VecCmpOp.create(self.state.ctx, self.loc, predicate, lhs.ptr, rhs.ptr, lhs.ptr.type);
            try self.addOperation(op.op);
            return wrapValue(op.getResult());
        }
        var op = try ArithDialect.CmpOp.create(self.state.ctx, self.loc, predicate, lhs.ptr, rhs.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn select(self: *Builder, condition: Value, true_value: Value, false_value: Value) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.SelectOp.create(self.state.ctx, self.loc, condition.ptr, true_value.ptr, false_value.ptr);
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
        var op = try MemrefDialect.LoadOp.create(self.state.ctx, self.loc, memref.ptr, index.ptr, elem_ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn loadVector(self: *Builder, memref: Value, index: Value, width: u32) !Value {
        try self.ensureOpen();
        const result_ty = try memrefVectorType(self.state.ctx, memref.ptr.type, width);
        var op = try MemrefDialect.LoadOp.create(self.state.ctx, self.loc, memref.ptr, index.ptr, result_ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn extractLane(self: *Builder, vector: Value, lane: u32, dtype: DType) !Value {
        try self.ensureOpen();
        const result_ty = try scalarType(self.state.ctx, dtype);
        var op = try ArithDialect.ExtractOp.create(self.state.ctx, self.loc, vector.ptr, @intCast(lane), result_ty);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn insertLane(self: *Builder, vector: Value, lane_value: Value, lane: u32) !Value {
        try self.ensureOpen();
        var op = try ArithDialect.InsertOp.create(self.state.ctx, self.loc, vector.ptr, lane_value.ptr, @intCast(lane));
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
        const dynamic_size = try self.constantIndex(std.math.cast(i64, size) orelse return error.IntegerOutOfBounds);
        var op = try MemrefDialect.AllocOp.createDynamic(self.state.ctx, self.loc, dynamic_size.ptr, memref_ty);
        var op_owned = true;
        errdefer if (op_owned) op.op.erase();
        try op.op.setAttr(
            gpu.attr_names.dynamic_shared_byte_offset,
            try self.state.ctx.getI64Attr(std.math.cast(i64, byte_offset) orelse return error.IntegerOutOfBounds),
        );
        op_owned = false;
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn store(self: *Builder, value: Value, memref: Value, index: Value) !void {
        try self.ensureOpen();
        const op = try MemrefDialect.StoreOp.create(self.state.ctx, self.loc, value.ptr, memref.ptr, index.ptr);
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
        var op = try GpuDialect.BallotSyncOp.create(self.state.ctx, self.loc, mask.ptr, predicate.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn warpReduce(self: *Builder, op_kind: WarpOpKind, value: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.WarpReduceOp.create(self.state.ctx, self.loc, op_kind, mask.ptr, value.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn warpScan(self: *Builder, op_kind: WarpOpKind, mode: WarpScanMode, value: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.WarpScanOp.create(self.state.ctx, self.loc, op_kind, mode == .inclusive, mask.ptr, value.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn shuffleSync(self: *Builder, mode: ShuffleMode, value: Value, lane_or_delta: Value) !Value {
        try self.ensureOpen();
        const mask = try self.fullWarpMask();
        var op = try GpuDialect.ShflSyncOp.create(self.state.ctx, self.loc, mode, mask.ptr, value.ptr, lane_or_delta.ptr);
        try self.addOperation(op.op);
        return wrapValue(op.getResult());
    }

    pub fn mmaSync(self: *Builder, shape: MmaShape, a: [4]Value, b: [2]Value, c: [4]Value) ![4]Value {
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

    pub fn asyncCopyShared(self: *Builder, dst: Value, dst_index: Value, src: Value, src_index: Value, bytes: u32) !void {
        try self.ensureOpen();
        const op = try GpuDialect.CpAsyncSharedOp.create(self.state.ctx, self.loc, dst.ptr, dst_index.ptr, src.ptr, src_index.ptr, bytes);
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

    pub fn for_(self: *Builder, lower: Value, upper: Value, step: Value, init_args: []const Value, result_types: []const Type) !For {
        try self.ensureOpen();
        const raw_init_args = try self.rawValues(init_args);
        const raw_result_types = try self.rawTypes(result_types);
        const op = try ScfDialect.ForOp.create(self.state.ctx, self.loc, lower.ptr, upper.ptr, step.ptr, raw_init_args, raw_result_types);
        try self.addOperation(op.op);
        return .{ .op = op };
    }

    pub fn forScope(self: *Builder, lower: Value, upper: Value, step: Value, init_args: []const Value, result_types: []const Type) !ForScope {
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
        const op = try ScfDialect.WhileOp.create(self.state.ctx, self.loc, raw_init_args, raw_result_types);
        try self.addOperation(op.op);
        return .{ .op = op };
    }

    pub fn whileScope(self: *Builder, init_args: []const Value, result_types: []const Type) !WhileScope {
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

    pub fn forDo(self: *Builder, lower: Value, upper: Value, step: Value, context: anytype, comptime body: anytype) !For {
        var scope = try self.forScope(lower, upper, step, &.{}, &.{});
        errdefer scope.abort();
        try body(self, scope.inductionVar(), context);
        try scope.leave(&.{});
        return scope.loop;
    }

    pub fn fold(self: *Builder, lower: Value, upper: Value, step: Value, initial: Value, context: anytype, comptime body: anytype) !Value {
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
            try choir.backends.contract.verifyModuleWithDiagnostic("accy/kernel/finish", self.state.module, captured);
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
    try requireSegmentBudget(usage.configuration_transactions, limits.configuration.transaction_bytes);
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
    const payload = try ctx.getTypeParamPayload(ty, MemrefDialect.MemrefTypePayload) orelse return error.ExpectedMemref;
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

test "Raw Builder capacity follows an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "accy_kernel_raw_builder_capacity"),
        );
    }

    const limits = Builder.Limits{
        .context = ir.Context.Limits.standard,
        .parameters = 3,
        .kernel_name_bytes = 5,
        .temporary_values = 7,
        .temporary_types = 11,
    };
    const capacity = try Builder.Capacity.derive(limits);
    const context_capacity = try ir.Context.Capacity.derive(limits.context);
    var expected: usize = 0;
    expected = std.mem.alignForward(usize, expected, @alignOf(ir.Context)) + @sizeOf(ir.Context);
    expected = std.mem.alignForward(usize, expected, @alignOf(State)) + @sizeOf(State);
    expected = std.mem.alignForward(usize, expected, @alignOf(Param)) + limits.parameters * @sizeOf(Param);
    expected = std.mem.alignForward(usize, expected, @alignOf(*ir.Value)) + limits.temporary_values * @sizeOf(*ir.Value);
    expected = std.mem.alignForward(usize, expected, @alignOf(ir.Type)) + limits.temporary_types * @sizeOf(ir.Type);
    try testing.expectEqual(expected, capacity.storage_bytes);
    try testing.expectEqual(expected, capacity.borrowed_acquired_bytes);
    try testing.expectEqual(expected + context_capacity.storage_bytes, capacity.owned_acquired_bytes);

    var overflow = limits;
    overflow.parameters = std.math.maxInt(usize);
    try testing.expectError(error.CapacityOverflow, Builder.Capacity.derive(overflow));
}

test "Raw Builder admits parameter and scratch maxima and rejects max plus one before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "accy_kernel_raw_builder_boundary"),
        );
    }

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try dialects.registerChoirDialect(&ctx);

    var limits = Builder.Limits.borrowed_testing;
    limits.parameters = 2;
    limits.kernel_name_bytes = 4;
    limits.temporary_values = 2;
    limits.temporary_types = 2;
    const params = [_]Param{ dynamicBuffer(.f32), dynamicBuffer(.f32) };
    const before_rejections = KernelResourceCounts.capture(&ctx);
    try testing.expectError(
        error.KernelNameCapacityExceeded,
        Builder.initBorrowing(testing.allocator, limits, &ctx, "names", &params),
    );
    try testing.expectError(
        error.ParameterCapacityExceeded,
        Builder.initBorrowing(testing.allocator, limits, &ctx, "name", &.{ params[0], params[1], params[0] }),
    );
    try before_rejections.expectEqual(&ctx);

    var builder = try Builder.initBorrowing(testing.allocator, limits, &ctx, "name", &params);
    defer builder.deinit();
    const values = [_]Value{ builder.argument(0), builder.argument(1) };
    const types = [_]Type{ values[0].valueType(), values[1].valueType() };
    _ = try builder.rawValues(&values);
    _ = try builder.rawTypes(&types);
    const exact_usage = builder.capacityUsage();
    try testing.expectEqual(@as(usize, 2), exact_usage.temporary_values);
    try testing.expectEqual(@as(usize, 2), exact_usage.temporary_types);

    const before = try choir.operationFingerprint(testing.allocator, builder.state.module);
    try testing.expectError(
        error.TemporaryValueCapacityExceeded,
        builder.rawValues(&.{ values[0], values[1], values[0] }),
    );
    try testing.expectError(
        error.TemporaryTypeCapacityExceeded,
        builder.rawTypes(&.{ types[0], types[1], types[0] }),
    );
    try testing.expectEqual(before, try choir.operationFingerprint(testing.allocator, builder.state.module));
    try testing.expectEqualDeep(exact_usage, builder.capacityUsage());
}

test "borrowed Raw Builder verifies explicit remaining Context capacity" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "accy_kernel_raw_builder_context_boundary"),
        );
    }

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.standard);
    defer ctx.deinit(testing.allocator);
    try dialects.registerChoirDialect(&ctx);
    const usage = ctx.capacityUsage();
    var context_limits = emptyContextLimits();
    context_limits.configuration.table_bytes = usage.configuration_tables.remainingBytes();
    try requireContextBudget(&ctx, context_limits);
    context_limits.configuration.table_bytes += 1;
    try testing.expectError(
        error.ContextCapacityExceeded,
        requireContextBudget(&ctx, context_limits),
    );

    var limits = Builder.Limits.borrowed_standard;
    limits.context = context_limits;
    limits.parameters = 0;
    limits.temporary_values = 0;
    limits.temporary_types = 0;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const before = KernelResourceCounts.capture(&ctx);
    try testing.expectError(
        error.ContextCapacityExceeded,
        Builder.initBorrowing(failing.allocator(), limits, &ctx, "", &.{}),
    );
    try before.expectEqual(&ctx);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "Raw Builder construction after initialization makes no backing allocator calls" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "accy_kernel_raw_builder_sealed_construction"),
        );
    }

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var builder = try Builder.init(
        failing.allocator(),
        Builder.Limits.standard,
        "sealed_raw_builder",
        &.{dynamicBuffer(.f32)},
        .{},
    );
    defer builder.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const index = try builder.globalId(.x);
    const value = try builder.load(builder.argument(0), index);
    const zero = try builder.constantFloat(.f32, 0);
    _ = try builder.compare(.gt, value, zero);
    try builder.return_();

    try testing.expect(!failing.has_induced_failure);
}

test "Raw Builder finish transfers owned state without acquisition" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "accy_kernel_raw_builder_transfer"),
        );
    }

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var kernel_name = [_]u8{ 't', 'r', 'a', 'n', 's', 'f', 'e', 'r' };
    var params = [_]Param{dynamicBuffer(.f32)};
    var builder = try Builder.init(
        failing.allocator(),
        Builder.Limits.standard,
        &kernel_name,
        &params,
        .{},
    );
    errdefer builder.deinit();
    const storage_pointer = builder.storage.storage;
    const state_pointer = builder.state;
    kernel_name[0] = 'x';
    params[0] = scalar(.i32);
    try builder.return_();

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var kernel = try builder.finish();
    builder.deinit();
    defer kernel.deinit();

    try testing.expectEqual(storage_pointer, kernel.storage.storage);
    try testing.expectEqual(state_pointer, kernel.state);
    try testing.expectEqual(kernel.capacity.owned_acquired_bytes, kernel.acquiredBytes());
    try testing.expectEqualStrings("transfer", kernel.func().getName().?);
    try testing.expect(paramsEql(kernel.params(), &.{dynamicBuffer(.f32)}));
    try testing.expect(!failing.has_induced_failure);
}

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

test "Builder borrows a reusable Choir context" {
    const allocator = testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerChoirDialect(&ctx);
    const baseline = KernelResourceCounts.capture(&ctx);

    var abandoned = try Builder.initBorrowing(allocator, Builder.Limits.borrowed_testing, &ctx, "borrowed_abandoned", &.{});
    try testing.expectEqual(&ctx, abandoned.state.ctx);
    try testing.expect(!abandoned.storage.owns_context);
    abandoned.deinit();
    try baseline.expectEqual(&ctx);

    var rejected = try Builder.initBorrowing(allocator, Builder.Limits.borrowed_testing, &ctx, "borrowed_rejected", &.{});
    var rejected_live = true;
    errdefer if (rejected_live) rejected.deinit();
    const zero = try rejected.constantFloat(.f32, 0);
    const predicate = try rejected.compare(.gt, zero, zero);
    _ = try rejected.if_(predicate, &.{zero.valueType()});
    try rejected.return_();
    try testing.expectError(error.ScfIfYieldMissing, rejected.finish());
    rejected.deinit();
    rejected_live = false;
    try baseline.expectEqual(&ctx);

    var builder = try Builder.initBorrowing(allocator, Builder.Limits.borrowed_testing, &ctx, "borrowed_copy_f32", &.{
        dynamicBuffer(.f32),
        dynamicBuffer(.f32),
    });
    errdefer builder.deinit();
    const src = builder.argument(0);
    const dst = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(src, index);
    try builder.store(value, dst, index);
    try builder.return_();

    var kernel = try builder.finish();
    var kernel_live = true;
    errdefer if (kernel_live) kernel.deinit();
    try testing.expectEqual(&ctx, kernel.module().context);
    try kernel.verify();
    kernel.deinit();
    kernel_live = false;
    try baseline.expectEqual(&ctx);
}

fn checkBorrowedBuilderAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerChoirDialect(&ctx);
    const baseline = KernelResourceCounts.capture(&ctx);
    defer baseline.expectEqual(&ctx) catch unreachable;

    var builder = try Builder.initBorrowing(allocator, Builder.Limits.borrowed_testing, &ctx, "borrowed_failure_f32", &.{
        dynamicBuffer(.f32),
        dynamicBuffer(.f32),
    });
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

test "borrowed Builder restores context resources on allocation failure" {
    try @import("../../../fixture/root.zig").checkAllAllocationFailures(
        checkBorrowedBuilderAllocationFailures,
        .{},
    );
}

test "Builder creates a Choir-backed copy kernel" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "copy_f32", &.{
        dynamicBuffer(.f32),
        dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const x = try b.load(src, i);
    try b.store(x, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    try testing.expectEqualStrings(FuncDialect.FuncOp.operation_name, kernel.func().op.name.name);
    try testing.expect(kernel.func().isKernel());
    try kernel.verify();
    try testing.expectEqual(@as(usize, 2), kernel.params().len);
    try testing.expect((Param{ .buffer = .{ .dtype = .f32 } }).eql(kernel.params()[0]));
    try testing.expect((Param{ .buffer = .{ .dtype = .f32 } }).eql(kernel.params()[1]));
}

test "Builder creates while loops with carried state" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "while_countdown_i32", &.{
        dynamicBuffer(.i32),
        dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const start = try b.load(src, i);
    const zero = try b.constantInt(.i32, 0);
    const one = try b.constantInt(.i32, 1);

    var scope = try b.whileScope(&.{ start, zero }, &.{ start.valueType(), zero.valueType() });
    errdefer scope.abort();
    const remaining = scope.beforeArg(0).?;
    const total = scope.beforeArg(1).?;
    const proceed = try b.compare(.gt, remaining, zero);
    try scope.condition(proceed, &.{ remaining, total });
    const after_remaining = scope.afterArg(0).?;
    const after_total = scope.afterArg(1).?;
    const next_total = try b.add(after_total, after_remaining);
    const next_remaining = try b.sub(after_remaining, one);
    try scope.leave(&.{ next_remaining, next_total });

    try b.store(scope.result(1).?, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();
    try kernel.verify();
}

test "Builder creates vector memref arithmetic" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "vec4_add_f32", &.{
        dynamicBuffer(.f32),
        dynamicBuffer(.f32),
        dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const dst = b.argument(0);
    const lhs_mem = b.argument(1);
    const rhs_mem = b.argument(2);
    const zero = try b.constantIndex(0);
    const lhs = try b.loadVector(lhs_mem, zero, 4);
    const rhs = try b.loadVector(rhs_mem, zero, 4);
    const sum = try b.add(lhs, rhs);
    try b.store(sum, dst, zero);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    try testing.expectEqualStrings("arith.vec4xf32", sum.ptr.type.getDialectTypeName().?);
    try testing.expectEqualStrings(FuncDialect.FuncOp.operation_name, kernel.func().op.name.name);
    try testing.expectEqual(@as(usize, 3), kernel.params().len);
}

test "Builder compare selects scalar or vector compare operation" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "cmp_surface", &.{
        dynamicBuffer(.u32),
        dynamicBuffer(.u32),
    }, .{});
    defer b.deinit();

    const zero = try b.constantIndex(0);
    const one = try b.constantIndex(1);
    const scalar_cmp = try b.compare(.lt, zero, one);
    const scalar_def: *ir.Operation = @ptrCast(@alignCast(scalar_cmp.ptr.getDefiningOp() orelse return error.ExpectedDefiningOp));
    try testing.expectEqualStrings(ArithDialect.CmpOp.operation_name, scalar_def.name.name);
    try testing.expectEqualStrings("arith.bool", scalar_cmp.ptr.type.getDialectTypeName().?);

    const lhs = try b.loadVector(b.argument(0), zero, 4);
    const rhs = try b.loadVector(b.argument(1), zero, 4);
    const vector = try b.compare(.ult, lhs, rhs);
    const vector_def: *ir.Operation = @ptrCast(@alignCast(vector.ptr.getDefiningOp() orelse return error.ExpectedDefiningOp));
    try testing.expectEqualStrings(ArithDialect.VecCmpOp.operation_name, vector_def.name.name);
    try testing.expectEqualStrings("arith.vec4xu32", vector.ptr.type.getDialectTypeName().?);
    try testing.expectError(error.UnsupportedVectorType, b.compare(.eq, zero, lhs));
}

test "Builder creates vector splat arithmetic" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "vec4_splat_u32", &.{
        dynamicBuffer(.u32),
        scalar(.u32),
    }, .{});
    errdefer b.deinit();

    const dst = b.argument(0);
    const bias = b.argument(1);
    const zero = try b.constantIndex(0);
    const splat = try b.splatVector(bias, 4);
    try b.store(splat, dst, zero);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    try testing.expectEqualStrings("arith.vec4xu32", splat.ptr.type.getDialectTypeName().?);
    try testing.expectEqualStrings(FuncDialect.FuncOp.operation_name, kernel.func().op.name.name);
    try testing.expectEqual(@as(usize, 2), kernel.params().len);
}

test "Builder creates vector shuffle arithmetic" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "vec4_shuffle_u32", &.{
        dynamicBuffer(.u32),
        dynamicBuffer(.u32),
    }, .{});
    errdefer b.deinit();

    const dst = b.argument(0);
    const src_mem = b.argument(1);
    const zero = try b.constantIndex(0);
    const src = try b.loadVector(src_mem, zero, 4);
    const indices = [_]i64{ 3, 2, 1, 0 };
    const shuffled = try b.shuffleVector(src, indices[0..]);
    try b.store(shuffled, dst, zero);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    try testing.expectEqualStrings("arith.vec4xu32", shuffled.ptr.type.getDialectTypeName().?);
    try testing.expectEqualStrings(FuncDialect.FuncOp.operation_name, kernel.func().op.name.name);
    try testing.expectEqual(@as(usize, 2), kernel.params().len);
}

test "Builder loads core dialects lazily" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "lazy_context", &.{
        dynamicBuffer(.f32),
    }, .{});
    defer b.deinit();

    try testing.expect(b.state.ctx.isDialectLoaded("builtin"));
    try testing.expect(b.state.ctx.isDialectLoaded("arith"));
    try testing.expect(b.state.ctx.isDialectLoaded("memref"));
    try testing.expect(b.state.ctx.isDialectLoaded("func"));
    try testing.expect(!b.state.ctx.isDialectLoaded("tile"));
    try testing.expect(!b.state.ctx.isDialectLoaded("aarch64"));
    try testing.expect(!b.state.ctx.isDialectLoaded("x86_64"));
    try testing.expect(!b.state.ctx.isDialectLoaded("rc"));
    try testing.expect(!b.state.ctx.isDialectLoaded("scf"));
    try testing.expect(!b.state.ctx.isDialectLoaded("gpu"));
    try testing.expect(!b.state.ctx.isBackendDialect("spirv"));
    try testing.expect(!b.state.ctx.isBackendDialect("nvptx"));
    try testing.expectError(error.UnknownDialect, b.state.ctx.getOrLoadDialect("nvptx"));
}

test "kernel context requirements preload only the selected dialects" {
    var names = [_][]const u8{"scf"};
    var builder = try Builder.init(testing.allocator, Builder.Limits.testing, "host", &.{}, .{
        .preload = &names,
    });
    errdefer builder.deinit();
    names[0] = "nvptx";
    try builder.return_();
    var kernel = try builder.finish();
    defer kernel.deinit();

    const ctx = kernel.module().getContext();
    try testing.expect(ctx.isFrozen());
    try testing.expect(ctx.isDialectLoaded("gpu"));
    try testing.expect(ctx.isDialectLoaded("scf"));
    try testing.expect(!ctx.isDialectLoaded("nvptx"));
    try testing.expect(!ctx.isDialectLoaded("spirv"));
    try testing.expect(!ctx.isBackendDialect("nvptx"));
    try testing.expect(!ctx.isBackendDialect("spirv"));
    try testing.expectError(error.ContextFrozen, ctx.getOrLoadDialect("nvptx"));
    try kernel.verify();
}

test "kernel context requirements release owned storage when preparation fails" {
    try testing.expectError(error.UnknownDialect, Builder.init(
        testing.allocator,
        Builder.Limits.testing,
        "missing_dialect",
        &.{},
        .{ .preload = &.{"unavailable"} },
    ));
}

test "Builder supports structured control flow through Choir scf ops" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "clamp_positive", &.{
        dynamicBuffer(.f32),
        dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const x = try b.load(src, i);
    const zero = try b.constantFloat(.f32, 0.0);
    const pred = try b.compare(.gt, x, zero);
    var if_op = try b.if_(pred, &.{x.valueType()});

    {
        var then_scope = try b.enterBlock(if_op.thenBlock());
        defer then_scope.leave();
        try b.yield_(&.{x});
    }

    {
        var else_scope = try b.enterBlock(if_op.elseBlock().?);
        defer else_scope.leave();
        try b.yield_(&.{zero});
    }

    const clamped = if_op.result(0).?;
    try b.store(clamped, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    try kernel.verify();
}

test "Builder scopes loop callbacks over Choir scf.for" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "fill_loop", &.{
        dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const dst = b.argument(0);
    const lower = try b.constantIndex(0);
    const upper = try b.constantIndex(4);
    const step = try b.constantIndex(1);
    _ = try b.forDo(lower, upper, step, dst, struct {
        fn body(k: *Builder, index: Value, target: Value) !void {
            const one = try k.constantInt(.i32, 1);
            try k.store(one, target, index);
        }
    }.body);

    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    try kernel.verify();
}

test "Builder finishWithDiagnostic localizes Choir verifier failures" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "bad_if", &.{}, .{});
    defer b.deinit();

    const zero = try b.constantFloat(.f32, 0.0);
    const pred = try b.compare(.gt, zero, zero);
    _ = try b.if_(pred, &.{zero.valueType()});
    try b.return_();

    var diagnostic: VerificationDiagnostic = .{};
    try testing.expectError(error.VerificationFailed, b.finishWithDiagnostic(&diagnostic));
    try testing.expect(diagnostic.hasText());
    try testing.expect(std.mem.indexOf(u8, diagnostic.text(), "accy/kernel/finish") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.text(), "scf.if") != null);
}

test "Kernel fingerprint reuses Choir stable hashing" {
    var first_builder = try Builder.init(testing.allocator, Builder.Limits.testing, "fingerprint_copy_i32", &.{
        dynamicBuffer(.i32),
        dynamicBuffer(.i32),
    }, .{});
    errdefer first_builder.deinit();
    const first_src = first_builder.argument(0);
    const first_dst = first_builder.argument(1);
    const first_index = try first_builder.globalId(.x);
    const first_value = try first_builder.load(first_src, first_index);
    try first_builder.store(first_value, first_dst, first_index);
    try first_builder.return_();
    var first = try first_builder.finish();
    defer first.deinit();

    var second_builder = try Builder.init(testing.allocator, Builder.Limits.testing, "fingerprint_copy_i32", &.{
        dynamicBuffer(.i32),
        dynamicBuffer(.i32),
    }, .{});
    errdefer second_builder.deinit();
    const second_src = second_builder.argument(0);
    const second_dst = second_builder.argument(1);
    const second_index = try second_builder.globalId(.x);
    const second_value = try second_builder.load(second_src, second_index);
    try second_builder.store(second_value, second_dst, second_index);
    try second_builder.return_();
    var second = try second_builder.finish();
    defer second.deinit();

    var renamed_builder = try Builder.init(testing.allocator, Builder.Limits.testing, "fingerprint_copy_renamed_i32", &.{
        dynamicBuffer(.i32),
        dynamicBuffer(.i32),
    }, .{});
    errdefer renamed_builder.deinit();
    const renamed_src = renamed_builder.argument(0);
    const renamed_dst = renamed_builder.argument(1);
    const renamed_index = try renamed_builder.globalId(.x);
    const renamed_value = try renamed_builder.load(renamed_src, renamed_index);
    try renamed_builder.store(renamed_value, renamed_dst, renamed_index);
    try renamed_builder.return_();
    var renamed = try renamed_builder.finish();
    defer renamed.deinit();

    try testing.expectEqual(try first.fingerprint(testing.allocator), try second.fingerprint(testing.allocator));
    try testing.expect(try first.fingerprint(testing.allocator) != try renamed.fingerprint(testing.allocator));
}

test "Builder supports u32 dynamic buffers" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "copy_u32", &.{
        dynamicBuffer(.u32),
        dynamicBuffer(.u32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const x = try b.load(src, i);
    try b.store(x, dst, i);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    try testing.expect(paramsEql(kernel.params(), &.{
        dynamicBuffer(.u32),
        dynamicBuffer(.u32),
    }));
    try kernel.verify();
}

test "Builder packs scalar lanes into a vector store" {
    var b = try Builder.init(testing.allocator, Builder.Limits.testing, "pack_v4", &.{
        dynamicBuffer(.f32),
        dynamicBuffer(.f32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const four = try b.constantIndex(4);
    const base = try b.mul(i, four);
    const loaded = try b.loadVector(src, base, 4);
    var lanes: [4]Value = undefined;
    for (&lanes, 0..) |*lane, lane_index| {
        lane.* = try b.extractLane(loaded, @intCast(lane_index), .f32);
    }
    const packed_value = try b.packVector(lanes);
    try b.store(packed_value, dst, base);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();
    try kernel.verify();
}
