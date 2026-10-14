const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const dialect_mod = @import("dialect.zig");
const semantics_mod = @import("semantics.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const AccyDialect = dialect_mod.AccyDialect;

pub const product_name = "accy.semantic";
pub const ActivationKind = semantics_mod.ActivationKind;
pub const CompareDirection = semantics_mod.CompareDirection;
pub const KernelOperandEffect = semantics_mod.KernelOperandEffect;

pub const KernelCallOptions = struct {
    target: []const u8,
    version: u32 = 1,
    has_side_effects: bool = false,
    operand_effects: []const KernelOperandEffect,
    result_aliases: []const ?usize,
};

pub const SemanticModule = struct {
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    owns_ctx: bool,
    choir_module: *ir.Operation,
    live: bool = true,

    pub fn context(self: *SemanticModule) *ir.Context {
        return self.ctx;
    }

    pub fn deinit(self: *SemanticModule) void {
        if (self.live) {
            self.choir_module.erase();
            if (self.owns_ctx) {
                self.ctx.deinit(self.allocator);
                self.allocator.destroy(self.ctx);
            }
            self.live = false;
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn verify(self: *SemanticModule) !void {
        try ir.verifyOperation(self.choir_module, ir.verify.default_options);
    }

    pub fn fingerprint(
        self: *SemanticModule,
        allocator: std.mem.Allocator,
    ) !choir.product.incremental.Fingerprint {
        return try choir.operationFingerprint(allocator, self.choir_module);
    }

    pub fn capture(
        self: *SemanticModule,
        builder: *choir.product.revision.Builder,
        comptime configuration: choir.product.operation.Configuration,
    ) !void {
        try choir.product.operation.capture(
            builder,
            &.{.{ .operation = self.choir_module }},
            &@import("root.zig").publication.irRecord(.semantic),
            &.{},
            configuration,
        );
    }
};

pub const Builder = struct {
    module: ?*SemanticModule,
    location: ir.Location,

    pub const ContextLimits = ir.Context.Limits;

    pub fn init(
        allocator: std.mem.Allocator,
        context_limits: ContextLimits,
    ) !Builder {
        return try initAt(allocator, context_limits, ir.Location.getUnknown());
    }

    pub fn initAt(
        allocator: std.mem.Allocator,
        context_limits: ContextLimits,
        location: ir.Location,
    ) !Builder {
        const ctx = try allocator.create(ir.Context);
        errdefer allocator.destroy(ctx);
        ctx.* = try buildSemanticContext(allocator, context_limits);
        errdefer ctx.deinit(allocator);
        return try initIn(allocator, ctx, true, location);
    }

    pub fn initBorrowing(allocator: std.mem.Allocator, ctx: *ir.Context) !Builder {
        return try initBorrowingAt(allocator, ctx, ir.Location.getUnknown());
    }

    pub fn initBorrowingAt(
        allocator: std.mem.Allocator,
        ctx: *ir.Context,
        location: ir.Location,
    ) !Builder {
        return try initIn(allocator, ctx, false, location);
    }

    fn initIn(
        allocator: std.mem.Allocator,
        ctx: *ir.Context,
        owns_ctx: bool,
        location: ir.Location,
    ) !Builder {
        const module = try allocator.create(SemanticModule);
        errdefer allocator.destroy(module);

        module.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .owns_ctx = owns_ctx,
            .choir_module = undefined,
        };

        const choir_module = try dialects.BuiltinDialect.ModuleOp.create(module.ctx, location);
        module.choir_module = choir_module.op;
        return .{ .module = module, .location = location };
    }

    pub fn deinit(self: *Builder) void {
        if (self.module) |module| {
            module.deinit();
            self.module = null;
        }
    }

    pub fn tensor(self: *Builder, dtype: gpu_abi.DType, dims: []const i64) !ir.Type {
        return try dialect_mod.accyTensorType(self.context(), dtype, dims);
    }

    pub fn beginFunction(
        self: *Builder,
        name: []const u8,
        param_types: []const ir.Type,
        result_types: []const ir.Type,
    ) !FunctionBuilder {
        return try self.beginFunctionAt(name, param_types, result_types, self.location);
    }

    pub fn beginFunctionAt(
        self: *Builder,
        name: []const u8,
        param_types: []const ir.Type,
        result_types: []const ir.Type,
        location: ir.Location,
    ) !FunctionBuilder {
        const module = self.module orelse return error.BuilderFinished;
        const func = try dialects.FuncDialect.FuncOp.create(
            module.ctx,
            location,
            name,
            param_types,
            result_types,
        );
        errdefer if (func.op.getBlock() == null) func.op.erase();
        try bodyBlock(module.choir_module).addOperation(func.op);
        return .{
            .ctx = module.ctx,
            .entry = func.getEntryBlock(),
            .result_types = result_types,
            .location = location,
        };
    }

    pub fn finish(self: *Builder) !*SemanticModule {
        const module = self.module orelse return error.BuilderFinished;
        try module.verify();
        self.module = null;
        return module;
    }

    fn context(self: *Builder) *ir.Context {
        return (self.module orelse unreachable).ctx;
    }
};

pub const IterateBuilder = struct {
    op: AccyDialect.IterateOp,
    body: FunctionBuilder,

    pub fn carry(self: *IterateBuilder, idx: usize) *ir.Value {
        return self.body.parameter(idx);
    }

    pub fn inner(self: *IterateBuilder) *FunctionBuilder {
        return &self.body;
    }

    pub fn yield_(self: *IterateBuilder, predicate: *ir.Value, carries: []const *ir.Value) !void {
        if (self.body.terminated) return error.AlreadyTerminated;
        errdefer self.op.op.erase();
        const yield_op = try AccyDialect.IterateYieldOp.create(
            self.body.ctx,
            self.body.location,
            predicate,
            carries,
        );
        try self.body.insert(yield_op.op);
        self.body.terminated = true;
        try verifyInsertedAccyOp(self.op.op);
    }

    pub fn result(self: *IterateBuilder, idx: usize) *ir.Value {
        return self.op.getResult(idx).?;
    }
};

pub const FunctionBuilder = struct {
    ctx: *ir.Context,
    entry: *ir.Block,
    result_types: []const ir.Type,
    location: ir.Location,
    terminated: bool = false,

    pub fn setLocation(self: *FunctionBuilder, location: ir.Location) void {
        self.location = location;
    }

    pub fn parameter(self: *FunctionBuilder, idx: usize) *ir.Value {
        return self.entry.arguments.items[idx];
    }

    pub fn constant(self: *FunctionBuilder, result_type: ir.Type, bytes: []const u8) !*ir.Value {
        const op = try AccyDialect.ConstantOp.create(self.ctx, self.location, bytes, result_type);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn iota(self: *FunctionBuilder, result_type: ir.Type, axis: u32) !*ir.Value {
        const op = try AccyDialect.IotaOp.create(
            self.ctx,
            self.location,
            result_type,
            @intCast(axis),
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn add(self: *FunctionBuilder, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.AddOp.create(self.ctx, self.location, lhs, rhs);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn sub(self: *FunctionBuilder, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.SubOp.create(self.ctx, self.location, lhs, rhs);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn mul(self: *FunctionBuilder, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.MulOp.create(self.ctx, self.location, lhs, rhs);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn div(self: *FunctionBuilder, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.DivOp.create(self.ctx, self.location, lhs, rhs);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn max(self: *FunctionBuilder, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.MaxOp.create(self.ctx, self.location, lhs, rhs);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn min(self: *FunctionBuilder, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.MinOp.create(self.ctx, self.location, lhs, rhs);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn neg(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.NegOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn abs(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.AbsOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn exp(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.ExpOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn log(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.LogOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn sqrt(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.SqrtOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn tanh(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.TanhOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn activation(self: *FunctionBuilder, input: *ir.Value, kind: ActivationKind) !*ir.Value {
        const op = try AccyDialect.ActivationOp.create(
            self.ctx,
            self.location,
            input,
            input.type,
            kind,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn compare(
        self: *FunctionBuilder,
        lhs: *ir.Value,
        rhs: *ir.Value,
        result_type: ir.Type,
        direction: CompareDirection,
    ) !*ir.Value {
        const op = try AccyDialect.CompareOp.create(
            self.ctx,
            self.location,
            lhs,
            rhs,
            result_type,
            @tagName(direction),
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn convert(
        self: *FunctionBuilder,
        input: *ir.Value,
        result_type: ir.Type,
        target_dtype: gpu_abi.DType,
    ) !*ir.Value {
        const op = try AccyDialect.ConvertOp.create(
            self.ctx,
            self.location,
            input,
            result_type,
            @tagName(target_dtype),
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn select(
        self: *FunctionBuilder,
        condition: *ir.Value,
        on_true: *ir.Value,
        on_false: *ir.Value,
    ) !*ir.Value {
        const op = try AccyDialect.SelectOp.create(
            self.ctx,
            self.location,
            condition,
            on_true,
            on_false,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn sin(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.SinOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn cos(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.CosOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn tan(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.TanOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn floor(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.FloorOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn round(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.RoundOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn trunc(self: *FunctionBuilder, input: *ir.Value) !*ir.Value {
        const op = try AccyDialect.TruncOp.create(self.ctx, self.location, input);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn pow(self: *FunctionBuilder, lhs: *ir.Value, rhs: *ir.Value) !*ir.Value {
        const op = try AccyDialect.PowOp.create(self.ctx, self.location, lhs, rhs);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn atan2(self: *FunctionBuilder, y: *ir.Value, x: *ir.Value) !*ir.Value {
        const op = try AccyDialect.Atan2Op.create(self.ctx, self.location, y, x);
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn broadcast(
        self: *FunctionBuilder,
        input: *ir.Value,
        result_type: ir.Type,
        sizes: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.BroadcastOp.create(
            self.ctx,
            self.location,
            input,
            result_type,
            sizes,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn broadcastInDim(
        self: *FunctionBuilder,
        input: *ir.Value,
        result_type: ir.Type,
        result_shape: []const i64,
        broadcast_dims: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.BroadcastInDimOp.create(
            self.ctx,
            self.location,
            input,
            result_type,
            broadcast_dims,
            result_shape,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn reshape(
        self: *FunctionBuilder,
        input: *ir.Value,
        result_type: ir.Type,
        new_shape: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.ReshapeOp.create(
            self.ctx,
            self.location,
            input,
            result_type,
            new_shape,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn transpose(
        self: *FunctionBuilder,
        input: *ir.Value,
        result_type: ir.Type,
        permutation: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.TransposeOp.create(
            self.ctx,
            self.location,
            input,
            result_type,
            permutation,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn slice(
        self: *FunctionBuilder,
        input: *ir.Value,
        result_type: ir.Type,
        starts: []const i64,
        limits: []const i64,
        strides: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.SliceOp.create(
            self.ctx,
            self.location,
            input,
            result_type,
            starts,
            limits,
            strides,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn concatenate(
        self: *FunctionBuilder,
        operands: []const *ir.Value,
        result_type: ir.Type,
        dimension: i64,
    ) !*ir.Value {
        const op = try AccyDialect.ConcatenateOp.create(
            self.ctx,
            self.location,
            operands,
            result_type,
            dimension,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn kernelCall(
        self: *FunctionBuilder,
        operands: []const *ir.Value,
        result_types: []const ir.Type,
        options: KernelCallOptions,
    ) !AccyDialect.KernelCallOp {
        const op = try AccyDialect.KernelCallOp.create(
            self.ctx,
            self.location,
            operands,
            result_types,
            options.target,
            options.version,
            options.has_side_effects,
            options.operand_effects,
            options.result_aliases,
        );
        try self.insert(op.op);
        return op;
    }

    pub fn dotGeneral(
        self: *FunctionBuilder,
        lhs: *ir.Value,
        rhs: *ir.Value,
        result_type: ir.Type,
        contracting_lhs: []const i64,
        contracting_rhs: []const i64,
        batching_lhs: []const i64,
        batching_rhs: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.DotGeneralOp.create(
            self.ctx,
            self.location,
            lhs,
            rhs,
            result_type,
            batching_lhs,
            batching_rhs,
            contracting_lhs,
            contracting_rhs,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn einsum(
        self: *FunctionBuilder,
        operands: []const *ir.Value,
        result_type: ir.Type,
        equation: []const u8,
    ) !*ir.Value {
        const op = try AccyDialect.EinsumOp.create(
            self.ctx,
            self.location,
            operands,
            result_type,
            equation,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn reduce(
        self: *FunctionBuilder,
        input: *ir.Value,
        init: *ir.Value,
        result_type: ir.Type,
        reducer_kind: []const u8,
        dimensions: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.ReduceOp.create(
            self.ctx,
            self.location,
            input,
            init,
            result_type,
            reducer_kind,
            dimensions,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn gather(
        self: *FunctionBuilder,
        input: *ir.Value,
        indices: *ir.Value,
        result_type: ir.Type,
        axis: i64,
    ) !*ir.Value {
        const op = try AccyDialect.GatherOp.create(
            self.ctx,
            self.location,
            input,
            indices,
            result_type,
            axis,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn scatter(
        self: *FunctionBuilder,
        input: *ir.Value,
        indices: *ir.Value,
        updates: *ir.Value,
        result_type: ir.Type,
        axis: i64,
    ) !*ir.Value {
        const op = try AccyDialect.ScatterOp.create(
            self.ctx,
            self.location,
            input,
            indices,
            updates,
            result_type,
            axis,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn scatterAdd(
        self: *FunctionBuilder,
        input: *ir.Value,
        indices: *ir.Value,
        updates: *ir.Value,
        result_type: ir.Type,
        axis: i64,
    ) !*ir.Value {
        const op = try AccyDialect.ScatterAddOp.create(
            self.ctx,
            self.location,
            input,
            indices,
            updates,
            result_type,
            axis,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn sparseCrossEntropy(
        self: *FunctionBuilder,
        logits: *ir.Value,
        targets: *ir.Value,
        result_type: ir.Type,
    ) !*ir.Value {
        const op = try AccyDialect.SparseCrossEntropyOp.create(
            self.ctx,
            self.location,
            logits,
            targets,
            result_type,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn pad(
        self: *FunctionBuilder,
        input: *ir.Value,
        padding_value: *ir.Value,
        result_type: ir.Type,
        edge_low: []const i64,
        edge_high: []const i64,
        interior: []const i64,
    ) !*ir.Value {
        const op = try AccyDialect.PadOp.create(
            self.ctx,
            self.location,
            input,
            padding_value,
            result_type,
            edge_low,
            edge_high,
            interior,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn cumsum(
        self: *FunctionBuilder,
        input: *ir.Value,
        result_type: ir.Type,
        axis: i64,
    ) !*ir.Value {
        const op = try AccyDialect.CumsumOp.create(
            self.ctx,
            self.location,
            input,
            result_type,
            axis,
        );
        try self.insert(op.op);
        return op.getResult();
    }

    pub fn beginIterate(
        self: *FunctionBuilder,
        carries: []const *ir.Value,
        max_iters: i64,
    ) !IterateBuilder {
        if (self.terminated) return error.AlreadyTerminated;
        const op = try AccyDialect.IterateOp.create(self.ctx, self.location, carries, max_iters);
        errdefer if (op.op.getBlock() == null) op.op.erase();
        const block = op.bodyBlock() orelse return error.BuilderFinished;
        try self.entry.addOperation(op.op);
        return .{
            .op = op,
            .body = .{
                .ctx = self.ctx,
                .entry = block,
                .result_types = &.{},
                .location = self.location,
            },
        };
    }

    pub fn return_(self: *FunctionBuilder, values: []const *ir.Value) !void {
        if (self.terminated) return error.AlreadyTerminated;
        if (values.len != self.result_types.len) return error.ResultCountMismatch;
        for (values, self.result_types) |value, expected| {
            if (!value.type.eql(expected)) return error.ResultTypeMismatch;
        }
        const op = try dialects.FuncDialect.ReturnOp.create(self.ctx, self.location, values);
        try self.insert(op.op);
        self.terminated = true;
    }

    pub fn finish(self: *FunctionBuilder) !void {
        if (!self.terminated) return error.MissingTerminator;
    }

    fn insert(self: *FunctionBuilder, op: *ir.Operation) !void {
        std.debug.assert(op.getBlock() == null);
        errdefer if (op.getBlock() == null) op.erase();
        if (self.terminated) return error.AlreadyTerminated;
        try verifyInsertedAccyOp(op);
        try self.entry.addOperation(op);
    }
};

fn verifyInsertedAccyOp(op: *ir.Operation) !void {
    if (std.mem.startsWith(u8, op.name.name, "accy.")) {
        try ir.verifyOperation(op, .{ .recursive = false });
    }
}

pub fn buildSemanticContext(
    allocator: std.mem.Allocator,
    context_limits: ir.Context.Limits,
) !ir.Context {
    return try choir.compiler.initContext(allocator, .{
        .context_limits = context_limits,
        .packages = &.{dialect_mod.accy_package_extension},
        .preload_dialects = &.{
            "builtin",
            "arith",
            "memref",
            "scf",
            "func",
            "accy",
        },
    });
}

fn bodyBlock(module: *ir.Operation) *ir.Block {
    return module.getRegion(0).?.getEntryBlock().?;
}

const SemanticResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) SemanticResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: SemanticResourceCounts, ctx: *const ir.Context) !void {
        try std.testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn checkBorrowedBuilderAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try buildSemanticContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const baseline = SemanticResourceCounts.capture(&ctx);
    defer baseline.expectEqual(&ctx) catch unreachable;

    var builder = try Builder.initBorrowing(allocator, &ctx);
    defer builder.deinit();
    const ty = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("borrowed_allocation_failure", &.{ ty, ty }, &.{ty});
    const sum = try function.add(function.parameter(0), function.parameter(1));
    try function.return_(&.{sum});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    try module.verify();
}
