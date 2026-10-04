const std = @import("std");
const choir = @import("choir");
const namespace = @import("root.zig");

const Allocator = std.mem.Allocator;
const composition = choir.composition;
const Backend = choir.backends.x86_64.backend.Backend;
const execution = choir.backends.execution;
const source = namespace.source;
const publication = namespace.fixture;

pub const Job = struct {
    artifact: choir.backends.artifact.Artifact,
    input: choir.product.operation.Product,

    pub fn deinit(self: *Job) void {
        self.artifact.deinit();
        self.input.release();
    }

    pub fn inputProduct(self: *const Job) choir.product.ProductKey {
        return choir.product.productKey(self.input.revision.metadata());
    }
};

const State = struct {
    runtime: execution.native.Runtime,
    module: execution.Handle,

    fn deinit(ptr: *anyopaque, allocator: Allocator) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.runtime.deinit();
        allocator.destroy(self);
    }

    fn lookupExport(ptr: *anyopaque, name: []const u8) ?usize {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.runtime.functionAddress(self.module, name) catch null;
    }
};

const vtable = composition.FragmentVTable{
    .deinit = State.deinit,
    .lookup_export = State.lookupExport,
};

pub fn compile(allocator: Allocator, program: *const source.Program) !Job {
    try program.verify();
    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.standard);
    defer ctx.deinit(allocator);
    try choir.dialects.registerAllDialects(&ctx);
    const module = try buildModule(&ctx, program);
    const input = try publication.capture(allocator, module, source.hostProductRef());
    errdefer input.release();
    var backend = try Backend.init(allocator, &ctx);
    defer backend.deinit();
    var artifact = try backend.compileFunctionToArtifact(module, source.host_symbol);
    errdefer artifact.deinit();
    try artifact.verification.replace(
        artifact.allocator,
        .{ .state = .passed, .stage = "choir.x86_64.machine_code" },
    );
    return .{
        .artifact = artifact,
        .input = input,
    };
}

pub fn materializeProduct(
    product: *const Job,
    allocator: Allocator,
    _: *const composition.CompositionModule,
    fragment: *const composition.Fragment,
) !composition.MaterializedFragment {
    if (fragment.id.value != source.host_fragment.value or fragment.pipeline != .choir) {
        return error.FragmentMismatch;
    }
    if (!fragment.pipeline_input.eql(product.inputProduct())) return error.ProductMismatch;
    if (fragment.artifacts.len != 1 or !fragment.artifacts[0].eql(product.artifact)) {
        return error.ArtifactMismatch;
    }
    const export_value = fragment.exportByName("entry") orelse return error.MissingEntry;
    if (!std.mem.eql(
        u8,
        export_value.symbol,
        source.host_symbol,
    ) or export_value.abi_version != composition.abi.version) return error.MissingEntry;
    const runtime_import = fragment.importByName("invoke") orelse return error.MissingRuntime;
    if (!std.mem.eql(u8, runtime_import.symbol, composition.abi.invoke_symbol) or
        runtime_import.kind != .runtime or
        runtime_import.abi_version != composition.abi.version)
    {
        return error.MissingRuntime;
    }

    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.runtime = try execution.native.Runtime.init(allocator, .standard);
    errdefer state.runtime.deinit();
    try state.runtime.registerExternalSymbol(
        composition.abi.invoke_symbol,
        @intFromPtr(&composition.loaded.invoke),
    );
    state.module = try state.runtime.loadArtifact(&fragment.artifacts[0]);
    return .{
        .state = state,
        .vtable = &vtable,
    };
}

pub fn materializer(product: *Job) composition.FragmentMaterializer {
    return .{
        .id = source.host_fragment,
        .context = product,
        .materialize = materialize,
    };
}

fn materialize(
    ptr: *anyopaque,
    allocator: Allocator,
    module: *const composition.CompositionModule,
    fragment: *const composition.Fragment,
) anyerror!composition.MaterializedFragment {
    const product: *Job = @ptrCast(@alignCast(ptr));
    return try materializeProduct(product, allocator, module, fragment);
}

fn buildModule(ctx: *choir.ir.Context, program: *const source.Program) !*choir.ir.Operation {
    const ArithDialect = choir.dialects.ArithDialect;
    const BuiltinDialect = choir.dialects.BuiltinDialect;
    const FuncDialect = choir.dialects.FuncDialect;
    const location = choir.ir.Location.getUnknown();
    const i64_type = try ArithDialect.getScalarType(ctx, .i64);

    const module = try BuiltinDialect.ModuleOp.create(ctx, location);
    const body = module.getBodyBlock();
    const invoke_declaration = try FuncDialect.FuncOp.createDeclaration(
        ctx,
        location,
        composition.abi.invoke_symbol,
        &.{ i64_type, i64_type, i64_type },
        &.{i64_type},
    );
    try body.addOperation(invoke_declaration.op);

    var entry = try FuncDialect.FuncOp.create(
        ctx,
        location,
        source.host_symbol,
        &.{ i64_type, i64_type },
        &.{i64_type},
    );
    try body.addOperation(entry.op);

    const entry_block = entry.getEntryBlock();
    var call_site = try ArithDialect.ConstantOp.createInt(
        ctx,
        location,
        i64_type,
        @intCast(program.add.call_site.value),
    );
    try entry_block.addOperation(call_site.op);
    var call = try FuncDialect.CallOp.create(
        ctx,
        location,
        composition.abi.invoke_symbol,
        &.{ entry.getArgument(0), call_site.getResult(), entry.getArgument(1) },
        &.{i64_type},
    );
    try entry_block.addOperation(call.op);
    const return_op = try FuncDialect.ReturnOp.create(ctx, location, &.{call.getResult(0).?});
    try entry_block.addOperation(return_op.op);
    return module.op;
}
