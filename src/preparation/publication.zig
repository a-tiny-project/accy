const std = @import("std");
const fixed = @import("alloc_fixed");
const choir = @import("choir");
const publication = @import("../choir/root.zig").publication;
const records = @import("../choir/root.zig").record;
const preparation = @import("root.zig");
const recipe = @import("recipe.zig");
const execution = @import("execution.zig");
const Stage = publication.Stage;
const operation = choir.product.operation;
const revision = choir.product.revision;
const Options = preparation.BackendPreparationRunOptions;
const bounds = choir.passes.pass.work;
const Prepared = @import("product.zig").BackendPreparedModule;
const Semantic = @import("../choir/root.zig").semantic.SemanticModule;

/// An immutable handle keeps the first stage record, the sealed result of one compile stage. That
/// record is captured from a draft, the caller's mutable semantic module. A caller holds this
/// handle to compile the same program again with no draft as long as that stage record still
/// matches. Only this file creates one, and it copies the target settings it reads from the draft
/// before the draft is freed. `retain` returns another independent handle to the same record, and
/// `deinit` releases this handle.
pub const SemanticSource = opaque {
    const Data = struct {
        allocator: std.mem.Allocator,
        revision: *const revision.Revision,
        target_recipe: []u8,
    };

    fn data(self: *const SemanticSource) *const Data {
        return @ptrCast(@alignCast(self));
    }

    fn create(
        allocator: std.mem.Allocator,
        published: *const revision.Revision,
        target_recipe: []const u8,
    ) !*SemanticSource {
        const retained = try published.retain();
        errdefer retained.release();
        const bytes = try allocator.dupe(u8, target_recipe);
        errdefer allocator.free(bytes);
        const owned = try allocator.create(Data);
        owned.* = .{ .allocator = allocator, .revision = retained, .target_recipe = bytes };
        return @ptrCast(owned);
    }

    fn capture(
        allocator: std.mem.Allocator,
        draft: *Semantic,
        published: *const revision.Revision,
    ) !*SemanticSource {
        try published.requireGates(&.{ operation.schema_identity, Stage.semantic.schema() });
        std.debug.assert(std.mem.eql(u8, published.address().stage, Stage.semantic.name()));
        const bytes = try recipe.encode(allocator, .kernel, draft.choir_module, .{});
        defer allocator.free(bytes);
        return create(allocator, published, bytes);
    }

    /// Returns the first stage record this source was built from. The record is borrowed until this
    /// source is destroyed, and a caller that needs it longer retains it.
    pub fn record(self: *const SemanticSource) *const revision.Revision {
        return self.data().revision;
    }

    pub fn retain(self: *const SemanticSource, allocator: std.mem.Allocator) !*SemanticSource {
        return create(allocator, self.record(), self.data().target_recipe);
    }

    pub fn deinit(self: *SemanticSource) void {
        const owned = self.data();
        owned.revision.release();
        owned.allocator.free(owned.target_recipe);
        owned.allocator.destroy(@constCast(owned));
    }

    fn options(
        self: *const SemanticSource,
        allocator: std.mem.Allocator,
        comptime stage: Stage,
        run: Options,
    ) ![]u8 {
        var inherited = try records.codec.decode(
            allocator,
            recipe.Record(.kernel),
            .kernel,
            self.data().target_recipe,
        );
        defer inherited.deinit();
        return recipe.encodeWithTarget(allocator, stage, inherited.value.options, run);
    }
};

pub const SemanticInput = union(enum) {
    draft: *Semantic,
    retained: *const SemanticSource,

    fn arithmetic(self: SemanticInput) !choir.product.recipe.ArithmeticPolicy {
        return switch (self) {
            .draft => |source| source.context().arithmetic_policy,
            .retained => |source| (try choir.product.recipe.decode(
                source.record().inputs().policy,
            )).arithmetic,
        };
    }

    fn options(
        self: SemanticInput,
        allocator: std.mem.Allocator,
        comptime stage: Stage,
        run: Options,
    ) ![]u8 {
        return switch (self) {
            .draft => |source| recipe.encode(allocator, stage, source.choir_module, run),
            .retained => |source| source.options(allocator, stage, run),
        };
    }

    fn retainSource(
        self: SemanticInput,
        allocator: std.mem.Allocator,
        published: *const revision.Revision,
    ) !*SemanticSource {
        return switch (self) {
            .draft => |source| SemanticSource.capture(allocator, source, published),
            .retained => |source| retained: {
                std.debug.assert(source.record().eql(published));
                break :retained source.retain(allocator);
            },
        };
    }
};

pub const PreparationRequest = struct {
    source: []const u8,
    variant: []const u8 = "",
    options: Options = .{},
    /// Work limits a caller sets on each compile request, bounding how much work the whole compile
    /// may do: the allowance in these limits is shared by the whole chain of seven stages, and each
    /// stage's charge is taken off before the next stage starts. The workspace and trace limits
    /// apply to each stage separately.
    work: revision.receipt.Limits,
    record_bytes: u32,
    candidate: ?*const Prepared = null,
};

pub const StageExecution = union(enum) {
    cold: *const revision.Revision,
    warm: revision.store.Reuse,

    pub fn record(self: *const StageExecution) *const revision.Revision {
        return switch (self.*) {
            .cold => |item| item,
            .warm => |item| item.revision,
        };
    }

    pub fn work(self: *const StageExecution) revision.WorkReceiptV1 {
        return switch (self.*) {
            .cold => |item| item.view().work,
            .warm => |item| item.work,
        };
    }

    pub fn deinit(self: *StageExecution) void {
        switch (self.*) {
            .cold => |item| item.release(),
            .warm => |*item| item.deinit(),
        }
        self.* = undefined;
    }
};

/// Report passed empty to each compile and read afterwards to see what ran, what was reused and
/// what failed: the report holds, for each finished stage, whether its stage record was reused or
/// built new, with the work it charged, and also the time per stage, the count of finished stages,
/// the failure receipt and the retained source. The entries for finished stages stay valid whether
/// the compile succeeds or a later stage fails. The caller owns the report, separately from the
/// compiled result.
pub const PreparationReport = struct {
    stages: [7]StageExecution = undefined,
    /// Holds the wall-clock time of each of the seven stages, in nanoseconds, read from the
    /// request's clock, so a caller can see how long each stage took in this request. These times
    /// are left out of stage records, out of the charged work and out of the reuse check, so they
    /// never change a result.
    elapsed_ns: [7]u64 = @splat(0),
    completed: u8 = 0,
    failure: ?revision.store.Failure = null,
    source: ?*SemanticSource = null,

    pub fn deinit(self: *PreparationReport) void {
        if (self.source) |source| source.deinit();
        for (self.stages[0..self.completed]) |*item| item.deinit();
        if (self.failure) |*failure| failure.deinit();
        self.* = .{};
    }

    pub fn charged(self: *const PreparationReport) !revision.WorkVector {
        var result: revision.WorkVector = .{};
        for (self.stages[0..self.completed]) |*item| result = try result.add(item.work().charged);
        if (self.failure) |failure| result = try result.add(failure.work.charged);
        return result;
    }
};

/// Compiles a program through all seven stages in order, starting from a fresh draft or from a
/// retained source: for each stage after the first, the call reuses the record of the candidate, an
/// earlier compile result, when the reuse check accepts it, and builds a new record otherwise. A
/// retained source must pass the reuse check for the first stage, and when it does not, the call
/// returns `error.SemanticModuleRequired` because only a draft can be captured again. `report` must
/// be empty when passed in, and on success its source is set and the caller owns the returned
/// result. On failure the call records the failing stage's receipt and the stages already finished
/// in `report`, returns the error, and leaves the candidate unchanged.
pub fn prepare(
    allocator: std.mem.Allocator,
    source: SemanticInput,
    request: PreparationRequest,
    report: *PreparationReport,
    comptime configuration: operation.Configuration,
) !*Prepared {
    std.debug.assert(report.completed == 0);
    std.debug.assert(report.failure == null);
    std.debug.assert(report.source == null);
    const store = try revision.Store.create(allocator, .{
        .revisions = 7,
        .kinds = 7,
        .builders = 1,
        .compiler_manifests = 2,
        .record_bytes = request.record_bytes,
        .gate_scratch_bytes = configuration.gate_scratch,
        .candidate_count = 7,
        .screening_bytes = request.record_bytes,
    });
    defer store.release();
    const stages = comptime std.enums.values(Stage);
    var kinds: [7]*const revision.Kind = undefined;
    inline for (stages, 0..) |stage, index| {
        kinds[index] = try registerKind(allocator, store, stage, configuration);
    }
    store.freeze();
    var remaining = request.work;
    var revisions: [7]*const revision.Revision = undefined;
    inline for (stages, 0..) |stage, index| {
        const start = request.options.now();
        defer report.elapsed_ns[index] = @intCast(@max(0, request.options.now() - start));
        const parent = if (index == 0) null else revisions[index - 1];
        const builder = try beginPreparationStage(
            allocator,
            store,
            kinds[index],
            source,
            parent,
            stage,
            request,
            remaining,
        );
        report.stages[index] = prepareStage(
            allocator,
            builder,
            kinds[index],
            source,
            parent,
            stage,
            request,
            configuration,
        ) catch |err| {
            report.failure = builder.abort(.rejected);
            return err;
        };
        report.completed += 1;
        revisions[index] = report.stages[index].record();
        const charged = report.stages[index].work().charged;
        inline for (@typeInfo(revision.WorkVector).@"struct".field_names) |field| {
            std.debug.assert(@field(charged, field) <= @field(remaining.allowance, field));
            @field(remaining.allowance, field) -= @field(charged, field);
        }
    }
    report.source = try source.retainSource(allocator, revisions[0]);
    return Prepared.create(allocator, revisions);
}

fn beginPreparationStage(
    allocator: std.mem.Allocator,
    store: *revision.Store,
    kind: *const revision.Kind,
    source: SemanticInput,
    parent: ?*const revision.Revision,
    comptime stage: Stage,
    request: PreparationRequest,
    work: revision.receipt.Limits,
) !*revision.Builder {
    const bytes = try source.options(allocator, stage, request.options);
    defer allocator.free(bytes);
    const policy = try choir.product.recipe.encode(allocator, .{
        .arithmetic = try source.arithmetic(),
        .policy = "accy-preparation",
    });
    defer allocator.free(policy);
    const dependencies: []const revision.store.Dependency = if (parent) |item|
        &.{.{ .role = "source", .revision = item }}
    else
        &.{};
    return store.begin(.{
        .kind = kind,
        .address = .{
            .producer = "accy",
            .source = request.source,
            .stage = stage.name(),
            .variant = request.variant,
        },
        .inputs = .{
            .compiler_manifest = try choir.product.compiler.manifest(),
            .versions = &.{ stage.schema(), operation.schema_identity, recipe.identity },
            .pipeline = recipe.pipeline(stage),
            .options = bytes,
            .policy = policy,
        },
        .dependencies = dependencies,
        .parent = parent,
    }, work);
}

fn prepareStage(
    allocator: std.mem.Allocator,
    builder: *revision.Builder,
    kind: *const revision.Kind,
    source: SemanticInput,
    parent: ?*const revision.Revision,
    comptime stage: Stage,
    request: PreparationRequest,
    comptime configuration: operation.Configuration,
) !StageExecution {
    if (stage == .semantic) {
        switch (source) {
            .draft => |draft| try draft.capture(builder, configuration),
            .retained => |input| {
                if (try builder.admitReuse(input.record())) |reuse| return .{ .warm = reuse };
                return error.SemanticModuleRequired;
            },
        }
    } else {
        if (request.candidate) |candidate| {
            if (try builder.admitReuse(candidate.stage(stage))) |reuse| return .{ .warm = reuse };
        }
        try capture(
            allocator,
            builder,
            .{ .revision = parent.? },
            stage,
            request.options,
            configuration,
        );
    }
    return .{ .cold = try builder.seal(kind) };
}

/// Builds one stage anew from the previous stage's record for the compile chain: the call runs the
/// stage's pass pipeline in a fresh compiler job bounded by the builder's limits, and copies the
/// result into the record builder, the object that collects one stage's result and is then sealed
/// into a stage record or aborted. The caller then seals or aborts the record builder, and owns any
/// diagnostics allocated with `diagnostic_allocator`. The call returns `error.WorkExhausted` when
/// the stage ran out of its limits, `error.MissingWorkContract` when a pass declared no bound, and
/// `error.PassFailed` for any other pipeline failure.
pub fn capture(
    diagnostic_allocator: std.mem.Allocator,
    builder: *revision.Builder,
    parent: operation.Product,
    comptime stage: Stage,
    options: Options,
    comptime configuration: operation.Configuration,
) !void {
    const work = builder.accounting();
    captureJob(diagnostic_allocator, builder, parent, stage, options, configuration) catch |err| {
        work.fail(if (err == error.WorkOverflow or err == error.WorkExhausted)
            .exhausted
        else
            .rejected);
        if (work.view().outcome == .exhausted) return error.WorkExhausted;
        return err;
    };
}

fn captureJob(
    diagnostic_allocator: std.mem.Allocator,
    builder: *revision.Builder,
    parent: operation.Product,
    comptime stage: Stage,
    options: Options,
    comptime configuration: operation.Configuration,
) !void {
    if (stage == .semantic) @compileError("Semantic input has no predecessor pipeline");
    const work = builder.accounting();
    const job = try parent.successor(builder, configuration);
    defer job.destroy();
    errdefer if (job.exhausted()) work.fail(.exhausted);
    var manager = choir.passes.PassManager.init(job.allocator());
    defer manager.deinit();
    try configure(&manager, builder, job, stage, &options);
    var cache = try choir.passes.AnalysisCache.initAccounted(
        job.allocator(),
        &manager.stats,
        work,
        .{ .workspace = job.storageExhaustion(), .context = job.context() },
        configuration.image.entities,
    );
    defer cache.deinit();
    if (manager.runWithAnalysisCache(
        job.root(0).?,
        job.context(),
        &cache,
        recipe.runOptions(),
    ) == .failure) {
        execution.capturePipelineFailure(
            diagnostic_allocator,
            options.failure,
            recipe.pipelineName(stage),
            &manager,
        );
        if (work.view().outcome == .exhausted or job.exhausted()) {
            return error.WorkExhausted;
        }
        if (work.view().missing_work_contract) return error.MissingWorkContract;
        return error.PassFailed;
    }
    try work.producersComplete();
    var context = choir.passes.PassContext.init(
        job.root(0).?,
        job.context(),
        job.allocator(),
        &cache,
    );
    defer context.deinit();
    context.run_options = recipe.runOptions();
    const bytes = try captureRecord(job, parent, &context, work, stage, configuration);
    defer job.allocator().free(bytes);
    try work.producersComplete();
    try job.capture(builder, bytes, &.{}, configuration);
}

fn configure(
    manager: *choir.passes.PassManager,
    builder: *revision.Builder,
    job: *operation.Job,
    comptime stage: Stage,
    options: *const Options,
) !void {
    const work = builder.accounting();
    const inputs = builder.inputs();
    const token = try work.begin(.input, .{
        .identity = .{ .name = "accy-stage-setup", .version = 1 },
        .work = .{
            .input_bytes = try bounds.add(
                try bounds.add(inputs.options.len, inputs.policy.len),
                try bounds.add(inputs.versions.bytes.len, inputs.pipeline.bytes.len),
            ),
            .output_bytes = job.storageCapacity(),
            .structural_visits = try bounds.add(
                job.storageCapacity(),
                try bounds.add(inputs.versions.count, inputs.pipeline.count),
            ),
            .allocation_capacity = job.storageCapacity(),
        },
        .workspace = job.storageCapacity(),
    });
    errdefer {
        if (job.exhausted()) work.fail(.exhausted);
        work.finish(token, .rejected, .{}) catch {};
    }
    const root = job.root(0) orelse return error.InvalidStageRoots;
    (try choir.product.recipe.decode(inputs.policy)).requireContext(job.context()) catch {
        return error.RecipeMismatch;
    };
    if (stage == .kernel or stage == .target) {
        try recipe.applyTargetOptions(job.allocator(), root, options.*);
    }
    const bytes = try recipe.encode(manager.allocator, stage, root, options.*);
    defer manager.allocator.free(bytes);
    if (!std.mem.eql(u8, inputs.options, bytes)) return error.RecipeMismatch;
    try requirePipeline(inputs, stage);
    try recipe.configure(manager, stage, options);
    try work.finish(token, .success, .{ .work = .{ .output_bytes = bytes.len } });
}

fn requirePipeline(inputs: revision.record.InputView, comptime stage: Stage) !void {
    const expected = recipe.pipeline(stage);
    if (inputs.pipeline.count != expected.len) return error.RecipeMismatch;
    var pipeline = inputs.pipeline.iterator();
    for (expected) |identity| {
        if (!(try pipeline.next()).?.eql(identity)) return error.RecipeMismatch;
    }
    var versions = inputs.versions.iterator();
    for (0..inputs.versions.count) |_| {
        if ((try versions.next()).?.eql(recipe.identity)) return;
    }
    return error.RecipeMismatch;
}

fn captureRecord(
    job: *operation.Job,
    parent: operation.Product,
    context: *choir.passes.PassContext,
    work: *revision.AccountingV1,
    comptime stage: Stage,
    comptime configuration: operation.Configuration,
) ![]u8 {
    const parent_bytes = if (stage == .target) parent.revision.view().exact.image.len else 0;
    const visits = try bounds.multiply(
        configuration.codec.fields,
        try bounds.add(configuration.image.entities, parent_bytes),
    );
    const token = try work.begin(.capture, .{
        .identity = .{ .name = "accy-stage-record", .version = 1 },
        .work = .{
            .input_bytes = try bounds.add(job.storageCapacity(), parent_bytes),
            .output_bytes = job.storageCapacity(),
            .structural_visits = visits,
            .allocation_capacity = job.storageCapacity(),
        },
        .workspace = job.storageCapacity(),
    });
    errdefer {
        if (job.exhausted()) work.fail(.exhausted);
        work.finish(token, .rejected, .{}) catch {};
    }
    const bytes = try encodeRecord(job, parent, context, stage, configuration);
    try work.finish(token, .success, .{ .work = .{ .output_bytes = bytes.len } });
    return bytes;
}

fn encodeRecord(
    job: *operation.Job,
    parent: operation.Product,
    context: *choir.passes.PassContext,
    comptime stage: Stage,
    comptime configuration: operation.Configuration,
) ![]u8 {
    const allocator = job.allocator();
    const root = job.root(0).?;
    return switch (stage) {
        .semantic, .contract, .tensor => allocator.dupe(u8, &publication.irRecord(stage)),
        .dispatch => preparation.capture.dispatch(
            allocator,
            root,
            try preparation.fusion.getFusionPlanAnalysis(context, root),
            try preparation.schedule.getSchedulePlanAnalysis(context, root),
            configuration.image.entities,
        ),
        .memory => preparation.capture.memory(
            allocator,
            root,
            try preparation.bufferization.getBufferPlanAnalysis(context, root),
            try preparation.memory.getMemorySpacePlanAnalysis(context, root),
            try preparation.layout.getLayoutPlanAnalysis(context, root),
            configuration.image.entities,
        ),
        .kernel => preparation.capture.kernel(
            allocator,
            root,
            try preparation.outlining.getKernelOutlinePlanAnalysis(context, root),
            try preparation.kernelization.getKernelizationAnalysis(context, root),
            configuration,
        ),
        .target => captureTarget(job, parent, context, configuration),
    };
}

fn captureTarget(
    job: *operation.Job,
    parent: operation.Product,
    context: *choir.passes.PassContext,
    comptime configuration: operation.Configuration,
) ![]u8 {
    if (!std.mem.eql(u8, parent.revision.address().stage, Stage.kernel.name())) {
        return error.WrongStage;
    }
    try parent.revision.requireGates(&.{Stage.kernel.schema()});
    const allocator = job.allocator();
    const image = try parent.open(allocator, configuration.image);
    defer image.destroy();
    var source = try records.codec.decode(allocator, records.kernel.Record, .kernel, image.stage());
    defer source.deinit();
    const Lowered = preparation.kernelization.LoweredKernel;
    const kernels = try allocator.alloc(Lowered, source.value.generated.kernels.len);
    defer allocator.free(kernels);
    var initialized: usize = 0;
    defer for (kernels[0..initialized]) |*kernel| kernel.deinit(allocator);
    for (source.value.generated.kernels, kernels) |record, *kernel| {
        kernel.* = try restoreKernel(allocator, record, configuration);
        initialized += 1;
    }
    return preparation.capture.target(
        allocator,
        job.root(0).?,
        try preparation.schedule.getSchedulePlanAnalysis(context, job.root(0).?),
        kernels,
        configuration,
    );
}

/// Restores a kernel from a sealed record back as a mutable kernel a caller can compile further:
/// the call rebuilds the captured kernel with its own copies of the entry name and the program,
/// allocated with `allocator`. The result owns those copies and is independent of the sealed
/// record.
pub fn restoreKernel(
    allocator: std.mem.Allocator,
    source: records.kernel.Lowered,
    comptime configuration: operation.Configuration,
) !preparation.kernelization.LoweredKernel {
    const name = try allocator.dupe(u8, source.entry_name);
    errdefer allocator.free(name);
    const program = try records.program.restore(allocator, source.program, name, configuration);
    var result: preparation.kernelization.LoweredKernel = undefined;
    inline for (@typeInfo(@TypeOf(result)).@"struct".field_names) |field| {
        @field(result, field) = if (comptime std.mem.eql(u8, field, "program"))
            program
        else if (comptime std.mem.eql(u8, field, "entry_name"))
            name
        else
            @field(source, field);
    }
    return result;
}

pub fn registerKind(
    allocator: std.mem.Allocator,
    store: *revision.Store,
    comptime stage: Stage,
    comptime configuration: operation.Configuration,
) !*const revision.Kind {
    return operation.registerKind(allocator, store, configuration, .{
        .name = stage.name(),
        .version = 1,
    }, &.{.{
        .identity = stage.schema(),
        .definition = &.{ 1, 0, 0, 0, @backingInt(stage) },
        .scratch_bytes = configuration.gate_scratch,
        .run = struct {
            fn run(input: revision.store.GateInput, scratch: []u8) !revision.record.EntityCounts {
                return verifyStage(input, scratch, stage, configuration);
            }
        }.run,
    }});
}

fn verifyStage(
    input: revision.store.GateInput,
    scratch: []u8,
    comptime stage: Stage,
    comptime configuration: operation.Configuration,
) !revision.record.EntityCounts {
    const address = try revision.record.decodeAddress(input.exact.address);
    if (!std.mem.eql(u8, address.stage, stage.name())) return error.WrongStage;
    try verifyPredecessor(input.dependencies, stage);
    var reader = try revision.record.Reader.init(input.exact.image);
    if (try reader.readInt(u32) != operation.image_version) return error.UnknownSchema;
    if (try reader.readCount() != 1) return error.InvalidStageRoots;
    const bytes = try reader.readBlob();
    const stage_bytes = try reader.readBlob();
    if (!reader.atEnd()) return error.InvalidStageRecord;
    switch (stage) {
        .semantic, .contract, .tensor => {
            if (!std.mem.eql(u8, stage_bytes, &publication.irRecord(stage))) {
                return error.InvalidStageRecord;
            }
        },
        else => {},
    }
    var memory = fixed.FixedBuffer.init(scratch);
    const allocator = memory.allocator();
    if (stage == .contract or stage == .tensor) {
        try verifyDialects(allocator, input, bytes, configuration);
    }
    if (stage == .dispatch or stage == .memory or stage == .kernel or stage == .target) {
        try verifyPlan(&memory, scratch, input, stage, stage_bytes, bytes, configuration);
    }
    return @splat(0);
}

fn verifyDialects(
    allocator: std.mem.Allocator,
    input: revision.store.GateInput,
    bytes: []const u8,
    comptime configuration: operation.Configuration,
) !void {
    var context = try choir.ir.Context.init(allocator, configuration.context);
    defer context.deinit(allocator);
    const inputs = try revision.record.decodeInputs(input.exact.inputs);
    (try choir.product.recipe.decode(inputs.policy)).restore(&context);
    try configuration.register(&context);
    var decoded = try choir.bytecode.decodeModule(allocator, &context, bytes);
    defer decoded.deinit();
    try @import("../choir/root.zig").contract.verifyAllowedDialects(decoded.module);
}

fn verifyPredecessor(
    dependencies: []const revision.record.Dependency,
    comptime stage: Stage,
) !void {
    if (stage == .semantic) {
        if (dependencies.len != 0) return error.InvalidStageDependency;
        return;
    }
    const parent: Stage = switch (stage) {
        .contract => .semantic,
        .tensor => .contract,
        .dispatch => .tensor,
        .memory => .dispatch,
        .kernel => .memory,
        .target => .kernel,
        else => unreachable,
    };
    if (dependencies.len != 1 or !std.mem.eql(u8, dependencies[0].role, "source")) {
        return error.InvalidStageDependency;
    }
    const exact = try revision.record.decodeExact(dependencies[0].exact);
    const address = try revision.record.decodeAddress(exact.address);
    if (!std.mem.eql(u8, address.stage, parent.name())) return error.InvalidStageDependency;
    const inputs = try revision.record.decodeInputs(exact.inputs);
    try inputs.requireGateDeclarations(&.{ operation.schema_identity, parent.schema() });
}

fn verifyPlan(
    memory: *fixed.FixedBuffer,
    scratch: []u8,
    input: revision.store.GateInput,
    comptime stage: Stage,
    bytes: []const u8,
    ir_bytes: []const u8,
    comptime configuration: operation.Configuration,
) !void {
    const allocator = memory.allocator();
    var plan = try records.codec.decode(allocator, publication.Plan(stage), stage, bytes);
    defer plan.deinit();
    const index = try choir.bytecode.image.Index.create(allocator, ir_bytes, configuration.image);
    defer index.destroy();
    try records.codec.validateReferences(plan.value, index.view());
    switch (stage) {
        .dispatch => try records.dispatch.validate(allocator, plan.value),
        .memory => {
            var dispatch = try predecessorPlan(allocator, input, .dispatch);
            defer dispatch.deinit();
            try records.memory.validate(allocator, plan.value, dispatch.value);
        },
        .kernel => {
            var parent = try predecessorPlan(allocator, input, .memory);
            defer parent.deinit();
            try records.kernel.validate(allocator, plan.value, parent.value);
            for (plan.value.generated.kernels) |kernel| {
                try verifyProgram(scratch[fixed.used(memory)..], kernel, configuration);
            }
        },
        .target => {
            var parent = try predecessorPlan(allocator, input, .kernel);
            defer parent.deinit();
            try records.target.validate(allocator, plan.value, parent.value);
            for (plan.value.kernels) |kernel| {
                try verifyProgram(scratch[fixed.used(memory)..], kernel.lowered, configuration);
            }
        },
        else => unreachable,
    }
}

fn verifyProgram(
    scratch: []u8,
    kernel: records.kernel.Lowered,
    comptime configuration: operation.Configuration,
) !void {
    var memory = fixed.FixedBuffer.init(scratch);
    try records.program.validate(
        memory.allocator(),
        kernel.program,
        kernel.entry_name,
        configuration,
    );
}

fn predecessorPlan(
    allocator: std.mem.Allocator,
    input: revision.store.GateInput,
    comptime stage: Stage,
) !records.codec.Decoded(publication.Plan(stage)) {
    const parent = try revision.record.decodeExact(input.dependencies[0].exact);
    var reader = try revision.record.Reader.init(parent.image);
    if (try reader.readInt(u32) != operation.image_version) return error.UnknownSchema;
    if (try reader.readCount() != 1) return error.InvalidStageRoots;
    _ = try reader.readBlob();
    const bytes = try reader.readBlob();
    if (!reader.atEnd()) return error.InvalidStageRecord;
    return records.codec.decode(allocator, publication.Plan(stage), stage, bytes);
}
