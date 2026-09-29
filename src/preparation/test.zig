const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const preparation = @import("root.zig");

test {
    _ = @import("coverage.zig");
    _ = @import("kernelization/test.zig");
    _ = @import("numerics.zig");
    @import("test_discovery").discover(preparation);
}

test "accy preparation declaration coverage" {
    std.testing.refAllDecls(preparation);
}

const choir = @import("choir");
const records = @import("../choir/record/root.zig");
const semantic = @import("../choir/root.zig").semantic;
const kernel_model = @import("../kernel/model/root.zig");

const StageRequest = struct {
    pipeline: ?[]const revision.record.Version = null,
    recipe_version: u32 = preparation.recipe.identity.version,
    allowance: revision.WorkVector = revision.WorkVector.uniform(1024 * 1024 * 1024),
    workspace: u64 = 128 * 1024 * 1024,
    gate_scratch_bytes: u32 = configuration.gate_scratch,
};

fn stageBuilder(
    chain: *Chain,
    root: *choir.ir.Operation,
    comptime stage: publication.Stage,
    options: preparation.BackendPreparationRunOptions,
    request: StageRequest,
) !*revision.Builder {
    const index = @backingInt(stage);
    const source: StageSource = .{
        .store = chain.store,
        .kind = chain.kinds[index],
        .parent = chain.products[index - 1],
    };
    return source.begin(root, stage, options, request);
}

const StageSource = struct {
    store: *revision.Store,
    kind: *const revision.Kind,
    parent: operation.Product,

    fn create(
        parent: operation.Product,
        comptime stage: publication.Stage,
        scratch_bytes: u32,
    ) !StageSource {
        const allocator = std.testing.allocator;
        const store = try revision.Store.create(allocator, .{
            .revisions = 1,
            .kinds = 1,
            .builders = 1,
            .compiler_manifests = 2,
            .record_bytes = 32 * 1024 * 1024,
            .gate_scratch_bytes = scratch_bytes,
            .candidate_count = 8,
            .screening_bytes = 32 * 1024 * 1024,
        });
        errdefer store.release();
        const kind = try preparation.publication.registerKind(
            allocator,
            store,
            stage,
            configuration,
        );
        store.freeze();
        return .{ .store = store, .kind = kind, .parent = parent };
    }

    fn begin(
        self: StageSource,
        root: *choir.ir.Operation,
        comptime stage: publication.Stage,
        options: preparation.BackendPreparationRunOptions,
        request: StageRequest,
    ) !*revision.Builder {
        const allocator = std.testing.allocator;
        const bytes = try preparation.recipe.encode(allocator, stage, root, options);
        defer allocator.free(bytes);
        const policy = try choir.product.recipe.encode(allocator, .{
            .arithmetic = root.context.arithmetic_policy,
            .policy = "accounted-stage-test",
        });
        defer allocator.free(policy);
        return self.store.begin(.{
            .kind = self.kind,
            .address = .{
                .producer = "accy",
                .source = "accounted-stage-test",
                .stage = stage.name(),
                .variant = "",
            },
            .inputs = .{
                .compiler_manifest = try choir.product.compiler.manifest(),
                .versions = &.{ stage.schema(), operation.schema_identity, .{
                    .name = preparation.recipe.identity.name,
                    .version = request.recipe_version,
                } },
                .pipeline = request.pipeline orelse preparation.recipe.pipeline(stage),
                .options = bytes,
                .policy = policy,
            },
            .dependencies = &.{.{ .role = "source", .revision = self.parent.revision }},
            .parent = self.parent.revision,
        }, .{
            .allowance = request.allowance,
            .workspace = request.workspace,
            .events = 256,
        });
    }
};

fn abortStage(builder: *revision.Builder) void {
    if (builder.abort(.rejected)) |failure| {
        var owned = failure;
        owned.deinit();
    }
}

fn expectStageWork(
    receipt: revision.WorkReceiptV1,
    comptime stage: publication.Stage,
    workspace: u64,
) !void {
    try std.testing.expectEqual(.success, receipt.outcome);
    try std.testing.expect(!receipt.missing_work_contract);
    try std.testing.expectEqual(
        preparation.recipe.pipeline(stage).len,
        receipt.executed.counters.pass_runs,
    );
    try std.testing.expect(receipt.executed.counters.analysis_misses > 0);
    var found = false;
    for (receipt.events) |*event| {
        if (!std.mem.eql(u8, event.identity().name, "accy-stage-setup")) continue;
        found = true;
        const capacity = workspace - configuration.gate_scratch;
        try std.testing.expectEqual(capacity, event.workspace);
        try std.testing.expectEqual(capacity, event.charged.allocation_capacity);
        try std.testing.expect(event.executed.work.exceeded(event.charged) == null);
    }
    try std.testing.expect(found);
}

test "Accy publication runs recorded Dispatch and Memory producers before sealing" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    inline for (.{ publication.Stage.dispatch, publication.Stage.memory }) |stage| {
        const index = @backingInt(stage);
        const builder = try stageBuilder(&chain, fixture.source.choir_module, stage, .{}, .{});
        var open = true;
        defer if (open) abortStage(builder);
        try preparation.publication.capture(
            allocator,
            builder,
            chain.products[index - 1],
            stage,
            .{},
            configuration,
        );
        const product = try operation.Product.seal(builder, chain.kinds[index]);
        open = false;
        defer product.release();
        chain.products[index].release();
        chain.products[index] = try product.retain();
        try expectStageWork(product.revision.view().work, stage, (StageRequest{}).workspace);
        const module = try publication.Module(stage).fromRevision(allocator, product.revision);
        defer module.deinit();
        const image = try module.open(allocator, configuration.image);
        defer image.destroy();
        const bytes = image.stage();
        var plan = try records.codec.decode(allocator, publication.Plan(stage), stage, bytes);
        defer plan.deinit();
        if (stage == .dispatch) {
            try std.testing.expectEqual(@as(usize, 1), plan.value.schedule.work_items.len);
        } else {
            try std.testing.expectEqual(@as(usize, 3), plan.value.buffers.slots.len);
        }
    }
}

fn markSavedProgram(fixture: *Fixture) !void {
    var context = fixture.context();
    defer context.deinit();
    const generated = try preparation.kernelization.getKernelizationAnalysis(
        &context,
        fixture.source.choir_module,
    );
    const source = &generated.kernels.items[0];
    const program_context = source.program.kernelModule().context;
    try source.program.storage.kernel.func().op.setAttr(
        "restoration_marker",
        try program_context.getStringAttr("retain this exact program"),
    );
    source.body_fingerprint = try source.program.bodyFingerprint(std.testing.allocator);
}

test "Accy publication restores exact Kernel programs into Target after source destruction" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    var live = true;
    defer if (live) fixture.deinit();
    try markSavedProgram(&fixture);
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    var expected = try records.codec.decode(
        allocator,
        records.kernel.Record,
        .kernel,
        captured.kernel,
    );
    defer expected.deinit();
    const options = preparation.BackendPreparationRunOptions{ .target_profile = .{
        .backend_kind = .cpu,
        .artifact_format = .cpu_object,
    } };
    try preparation.recipe.applyTargetOptions(allocator, fixture.source.choir_module, options);
    const request = StageRequest{
        .allowance = revision.WorkVector.uniform(64 * 1024 * 1024 * 1024),
        .workspace = 256 * 1024 * 1024,
    };
    const builder = try stageBuilder(
        &chain,
        fixture.source.choir_module,
        .target,
        options,
        request,
    );
    var open = true;
    defer if (open) abortStage(builder);
    fixture.deinit();
    live = false;
    @memset(captured.kernel, 0xa5);
    try preparation.publication.capture(
        allocator,
        builder,
        chain.products[5],
        .target,
        options,
        configuration,
    );
    const product = try operation.Product.seal(builder, chain.kinds[6]);
    open = false;
    defer product.release();
    try expectStageWork(product.revision.view().work, .target, request.workspace);
    const target = try publication.Module(.target).fromRevision(allocator, product.revision);
    defer target.deinit();
    var plan = try target.plan(allocator, configuration.image);
    defer plan.deinit();
    try std.testing.expectEqual(expected.value.generated.kernels.len, plan.value.kernels.len);
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    for (plan.value.kernels, expected.value.generated.kernels) |actual, wanted| {
        try records.codec.compare(actual.lowered, wanted, &references);
    }
}

const variant_options = [_]preparation.BackendPreparationRunOptions{
    .{ .target_profile = .{ .backend_kind = .cpu, .artifact_format = .cpu_object } },
    .{ .target_profile = .{ .backend_kind = .cuda, .artifact_format = .cuda_ptx } },
};

fn variantBuilders(fixture: *Fixture, chain: *Chain) ![variant_options.len]*revision.Builder {
    var builders: [variant_options.len]*revision.Builder = undefined;
    var initialized: usize = 0;
    errdefer for (builders[0..initialized]) |builder| abortStage(builder);
    for (variant_options, &builders) |options, *builder| {
        const root = fixture.source.choir_module;
        try preparation.recipe.applyTargetOptions(std.testing.allocator, root, options);
        builder.* = try stageBuilder(chain, root, .target, options, .{
            .allowance = revision.WorkVector.uniform(64 * 1024 * 1024 * 1024),
            .workspace = 256 * 1024 * 1024,
        });
        initialized += 1;
    }
    return builders;
}

fn expectTargetVariant(
    product: operation.Product,
    profile: preparation.BackendTargetProfile,
    parent: records.kernel.Record,
) !void {
    const allocator = std.testing.allocator;
    const module = try publication.Module(.target).fromRevision(allocator, product.revision);
    defer module.deinit();
    var plan = try module.plan(allocator, configuration.image);
    defer plan.deinit();
    try std.testing.expectEqualDeep(profile, plan.value.profile.?);
    try std.testing.expectEqual(parent.generated.kernels.len, plan.value.kernels.len);
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    const extra: u32 = if (profile.backend_kind == .cpu) gpu_abi.launch_shape_argument_count else 0;
    for (plan.value.kernels, parent.generated.kernels) |actual, expected| {
        try records.codec.compare(actual.lowered, expected, &references);
        try std.testing.expectEqual(expected.argument_count + extra, actual.abi.?.argument_count);
        try std.testing.expectEqual(extra, actual.abi.?.static_arguments.len);
    }
}

test "Accy publication keeps CPU and CUDA successors independent on one sealed Kernel" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    var live = true;
    defer if (live) fixture.deinit();
    try markSavedProgram(&fixture);
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    var expected = try records.codec.decode(
        allocator,
        records.kernel.Record,
        .kernel,
        captured.kernel,
    );
    defer expected.deinit();
    const parent = chain.products[5].revision;
    const parent_image = try allocator.dupe(u8, parent.view().exact.image);
    defer allocator.free(parent_image);
    const builders = try variantBuilders(&fixture, &chain);
    var sealed: usize = 0;
    defer for (builders[sealed..]) |builder| abortStage(builder);
    var first_image: ?[]u8 = null;
    defer if (first_image) |bytes| allocator.free(bytes);
    var products: [variant_options.len]operation.Product = undefined;
    defer for (products[0..sealed]) |product| product.release();
    fixture.deinit();
    live = false;
    @memset(captured.kernel, 0xa5);
    for (variant_options, builders, &products) |options, builder, *product| {
        try preparation.publication.capture(
            allocator,
            builder,
            chain.products[5],
            .target,
            options,
            configuration,
        );
        product.* = try operation.Product.seal(builder, chain.kinds[6]);
        sealed += 1;
        if (sealed == 1) {
            first_image = try allocator.dupe(u8, product.revision.view().exact.image);
        }
        try expectStageWork(product.revision.view().work, .target, 256 * 1024 * 1024);
    }
    try std.testing.expect(!products[0].revision.eql(products[1].revision));
    try std.testing.expectEqualSlices(u8, first_image.?, products[0].revision.view().exact.image);
    try std.testing.expectEqualSlices(u8, parent_image, parent.view().exact.image);
    for (products, variant_options) |product, options| {
        try expectTargetVariant(product, options.target_profile.?, expected.value);
    }
}

test "Accy publication reports exhausted Target restoration workspace after completing its passes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    const options = preparation.BackendPreparationRunOptions{ .target_profile = .{
        .backend_kind = .cpu,
        .artifact_format = .cpu_object,
    } };
    try preparation.recipe.applyTargetOptions(
        std.testing.allocator,
        fixture.source.choir_module,
        options,
    );
    const builder = try stageBuilder(&chain, fixture.source.choir_module, .target, options, .{
        .allowance = revision.WorkVector.uniform(64 * 1024 * 1024 * 1024),
    });
    defer abortStage(builder);
    try std.testing.expectError(error.WorkExhausted, preparation.publication.capture(
        std.testing.allocator,
        builder,
        chain.products[5],
        .target,
        options,
        configuration,
    ));
    const receipt = builder.accounting().view();
    try std.testing.expectEqual(.exhausted, receipt.outcome);
    try std.testing.expectEqual(
        preparation.recipe.pipeline(.target).len,
        receipt.executed.counters.pass_runs,
    );
    const last = receipt.events[receipt.events.len - 1];
    try std.testing.expectEqualStrings("accy-stage-record", last.identity().name);
}

test "Accy publication checks ordered pipeline identities and recipe versions before execution" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    const pipeline = preparation.recipe.pipeline(.dispatch);
    const requests = [_]StageRequest{
        .{ .pipeline = &.{ pipeline[1], pipeline[0] } },
        .{ .recipe_version = preparation.recipe.identity.version + 1 },
    };
    for (requests) |request| {
        const builder = try stageBuilder(
            &chain,
            fixture.source.choir_module,
            .dispatch,
            .{},
            request,
        );
        defer abortStage(builder);
        try std.testing.expectError(error.RecipeMismatch, preparation.publication.capture(
            std.testing.allocator,
            builder,
            chain.products[2],
            .dispatch,
            .{},
            configuration,
        ));
        const receipt = builder.accounting().view();
        try std.testing.expectEqual(.rejected, receipt.outcome);
        try std.testing.expectEqual(@as(u64, 0), receipt.executed.counters.pass_runs);
    }
}

test "Accy publication exhausts admission before executing a successor" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    var accounting_limit = StageRequest{};
    accounting_limit.allowance.structural_visits = 0;
    const requests = [_]StageRequest{
        accounting_limit,
        .{ .workspace = configuration.gate_scratch + 1024 },
    };
    for (requests) |request| {
        const builder = try stageBuilder(
            &chain,
            fixture.source.choir_module,
            .dispatch,
            .{},
            request,
        );
        defer abortStage(builder);
        try std.testing.expectError(error.WorkExhausted, preparation.publication.capture(
            std.testing.allocator,
            builder,
            chain.products[2],
            .dispatch,
            .{},
            configuration,
        ));
        const receipt = builder.accounting().view();
        try std.testing.expectEqual(.exhausted, receipt.outcome);
        try std.testing.expectEqual(@as(u64, 0), receipt.executed.counters.pass_runs);
        try std.testing.expectEqual(@as(u64, 0), receipt.executed.counters.analysis_misses);
    }
}

test "Accy publication rejects unrecorded options before running a producer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    const builder = try stageBuilder(&chain, fixture.source.choir_module, .tensor, .{}, .{});
    defer abortStage(builder);
    var options = preparation.BackendPreparationRunOptions{};
    options.tensor.einsum.beam_width += 1;
    try std.testing.expectError(error.RecipeMismatch, preparation.publication.capture(
        std.testing.allocator,
        builder,
        chain.products[1],
        .tensor,
        options,
        configuration,
    ));
    const receipt = builder.accounting().view();
    try std.testing.expectEqual(.rejected, receipt.outcome);
    try std.testing.expectEqual(@as(u64, 0), receipt.executed.counters.pass_runs);
}

test "Accy publication runs recorded Kernel producers before sealing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    const request: StageRequest = .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = 512 * 1024 * 1024,
    };
    const builder = try stageBuilder(&chain, fixture.source.choir_module, .kernel, .{}, request);
    var open = true;
    defer if (open) abortStage(builder);
    try preparation.publication.capture(
        std.testing.allocator,
        builder,
        chain.products[@backingInt(publication.Stage.memory)],
        .kernel,
        .{},
        configuration,
    );
    const product = try operation.Product.seal(builder, chain.kinds[@backingInt(publication.Stage.kernel)]);
    open = false;
    defer product.release();
    try expectStageWork(product.revision.view().work, .kernel, request.workspace);
    const module = try publication.Module(.kernel).fromRevision(std.testing.allocator, product.revision);
    defer module.deinit();
    var actual = try module.plan(std.testing.allocator, configuration.image);
    defer actual.deinit();
    var expected = try records.codec.decode(
        std.testing.allocator,
        records.kernel.Record,
        .kernel,
        captured.kernel,
    );
    defer expected.deinit();
    try std.testing.expectEqual(@as(usize, 1), actual.value.generated.kernels.len);
    var references = records.reference.Index{ .allocator = std.testing.allocator, .limit = 0 };
    defer references.deinit();
    try records.codec.compare(actual.value, expected.value, &references);
}

test "Accy publication Contract producers seal only after accounting" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    const product = try publishStage(&chain, fixture.source.choir_module, .contract);
    defer product.release();
    const receipt = product.revision.view().work;
    try std.testing.expectEqual(.success, receipt.outcome);
    try std.testing.expect(!receipt.missing_work_contract);
    try std.testing.expectEqual(preparation.recipe.pipeline(.contract).len, receipt.executed.counters.pass_runs);
    const module = try publication.Module(.contract).fromRevision(std.testing.allocator, product.revision);
    defer module.deinit();
    const image = try module.open(std.testing.allocator, configuration.image);
    defer image.destroy();
    try std.testing.expectEqualSlices(u8, &publication.irRecord(.contract), image.stage());
}

const Fixture = struct {
    source: *semantic.SemanticModule,
    cache: choir.passes.AnalysisCache,

    fn init() !Fixture {
        return initNames(&.{"plan_image"});
    }

    fn initNames(names: []const []const u8) !Fixture {
        const allocator = std.testing.allocator;
        var builder = try semantic.Builder.init(allocator, .standard);
        defer builder.deinit();
        const typ = try builder.tensor(.f32, &.{4});
        for (names) |name| {
            var function = try builder.beginFunction(name, &.{ typ, typ }, &.{typ});
            const first = try function.add(function.parameter(0), function.parameter(1));
            const second = try function.add(first, function.parameter(1));
            try function.return_(&.{second});
            try function.finish();
        }
        return .{
            .source = try builder.finish(),
            .cache = choir.passes.AnalysisCache.init(allocator, null),
        };
    }

    fn deinit(self: *Fixture) void {
        self.cache.deinit();
        self.source.deinit();
    }

    fn context(self: *Fixture) choir.passes.PassContext {
        return choir.passes.PassContext.init(
            self.source.choir_module,
            self.source.context(),
            std.testing.allocator,
            &self.cache,
        );
    }
};

const Snapshot = struct {
    dispatch: []u8,
    memory: []u8,
    kernel: []u8,
    target: []u8,
    image: []u8,

    fn deinit(self: *Snapshot) void {
        const allocator = std.testing.allocator;
        allocator.free(self.dispatch);
        allocator.free(self.memory);
        allocator.free(self.kernel);
        allocator.free(self.target);
        allocator.free(self.image);
    }
};

fn snapshot() !Snapshot {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    return captureFixture(&fixture);
}

fn captureFixture(fixture: *Fixture) !Snapshot {
    const allocator = std.testing.allocator;
    var context = fixture.context();
    defer context.deinit();
    const root = fixture.source.choir_module;
    const fusion = try preparation.fusion.getFusionPlanAnalysis(&context, root);
    const schedule = try preparation.schedule.getSchedulePlanAnalysis(&context, root);
    const buffers = try preparation.bufferization.getBufferPlanAnalysis(&context, root);
    const spaces = try preparation.memory.getMemorySpacePlanAnalysis(&context, root);
    const layouts = try preparation.layout.getLayoutPlanAnalysis(&context, root);
    const dispatch = try preparation.capture.dispatch(allocator, root, fusion, schedule, 1024);
    errdefer allocator.free(dispatch);
    const memory = try preparation.capture.memory(allocator, root, buffers, spaces, layouts, 1024);
    errdefer allocator.free(memory);
    const outlines = try preparation.outlining.getKernelOutlinePlanAnalysis(&context, root);
    const generated = try preparation.kernelization.getKernelizationAnalysis(&context, root);
    const kernel = try preparation.capture.kernel(
        allocator,
        root,
        outlines,
        generated,
        configuration,
    );
    errdefer allocator.free(kernel);
    const target = try preparation.capture.target(
        allocator,
        root,
        schedule,
        generated.kernels.items,
        configuration,
    );
    errdefer allocator.free(target);
    return .{
        .dispatch = dispatch,
        .memory = memory,
        .kernel = kernel,
        .target = target,
        .image = try choir.bytecode.encodeModule(allocator, root),
    };
}

test "Accy stage records own dispatch and memory plans after job destruction" {
    const allocator = std.testing.allocator;
    var captured = try snapshot();
    defer captured.deinit();
    const image = try choir.bytecode.image.Index.create(allocator, captured.image, .{
        .bytes = 65536,
        .entities = 1024,
        .depth = 32,
    });
    defer image.destroy();
    var dispatch = try records.codec.decode(
        allocator,
        records.dispatch.Record,
        .dispatch,
        captured.dispatch,
    );
    defer dispatch.deinit();
    var memory = try records.codec.decode(
        allocator,
        records.memory.Record,
        .memory,
        captured.memory,
    );
    defer memory.deinit();
    try records.codec.validateReferences(dispatch.value, image.view());
    try records.codec.validateReferences(memory.value, image.view());
    try std.testing.expect(dispatch.value.schedule.work_items.len > 0);
    try std.testing.expect(dispatch.value.fusion.clusters.len > 0);
    try std.testing.expect(memory.value.buffers.slots.len > 0);
    var functions: usize = 0;
    var outputs: usize = 0;
    for (memory.value.buffers.slots) |slot| {
        if (slot.function != null) functions += 1;
    }
    for (memory.value.spaces.assignments) |assignment| {
        if (assignment.output_source != null) outputs += 1;
    }
    try std.testing.expect(functions > 0);
    try std.testing.expect(outputs > 0);
    @memset(captured.dispatch, 0xa5);
    @memset(captured.memory, 0xa5);
    try records.codec.validateReferences(dispatch.value, image.view());
    try records.codec.validateReferences(memory.value, image.view());
}

test "Accy stage records include fusion kinds and memory output sources" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = fixture.context();
    defer context.deinit();
    const root = fixture.source.choir_module;
    const fusion = try preparation.fusion.getFusionPlanAnalysis(&context, root);
    const schedule = try preparation.schedule.getSchedulePlanAnalysis(&context, root);
    const before = try preparation.capture.dispatch(allocator, root, fusion, schedule, 1024);
    defer allocator.free(before);
    try std.testing.expect(fusion.clusters.items.len > 0);
    const clusters = @constCast(fusion).clusters.items;
    clusters[0].kind = .row_pipeline;
    var decoded_before = try records.codec.decode(
        allocator,
        records.dispatch.Record,
        .dispatch,
        before,
    );
    defer decoded_before.deinit();
    var references = try records.reference.Index.init(allocator, root, 1024);
    defer references.deinit();
    try std.testing.expectError(error.UnencodableProduct, records.codec.compare(
        decoded_before.value,
        .{ .fusion = fusion, .schedule = schedule },
        &references,
    ));
    const after = try preparation.capture.dispatch(allocator, root, fusion, schedule, 1024);
    defer allocator.free(after);
    try std.testing.expect(!std.mem.eql(u8, before, after));
    clusters[0].kind = .elementwise;
    const buffers = try preparation.bufferization.getBufferPlanAnalysis(&context, root);
    const spaces = try preparation.memory.getMemorySpacePlanAnalysis(&context, root);
    const layouts = try preparation.layout.getLayoutPlanAnalysis(&context, root);
    const initial = try preparation.capture.memory(allocator, root, buffers, spaces, layouts, 1024);
    defer allocator.free(initial);
    var changed = false;
    for (@constCast(spaces).assignments.items) |*assignment| {
        if (assignment.output_source == null) continue;
        assignment.output_source = .{ .aliased = 0 };
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    const updated = try preparation.capture.memory(allocator, root, buffers, spaces, layouts, 1024);
    defer allocator.free(updated);
    try std.testing.expect(!std.mem.eql(u8, initial, updated));
}

fn decodeFailure(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var decoded = try records.codec.decode(allocator, records.memory.Record, .memory, bytes);
    defer decoded.deinit();
    try std.testing.expect(decoded.value.buffers.slots.len > 0);
}

test "Accy stage records clean partial decoding and reject framing corruption" {
    const allocator = std.testing.allocator;
    var captured = try snapshot();
    defer captured.deinit();
    var moving = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(
        moving.allocator(),
        decodeFailure,
        .{captured.memory},
    );
    try std.testing.expectError(error.WrongStage, records.codec.decode(
        allocator,
        records.dispatch.Record,
        .dispatch,
        captured.memory,
    ));
    try std.testing.expectError(error.Truncated, records.codec.decode(
        allocator,
        records.memory.Record,
        .memory,
        captured.memory[0 .. captured.memory.len - 1],
    ));
}

const publication = @import("../choir/root.zig").publication;
const revision = choir.product.revision;
const operation = choir.product.operation;
const configuration = operation.Configuration{
    .context = choir.ir.Context.Limits.testing,
    .register = registerContext,
    .registration = .{ .name = "accy-plan-test-context", .version = 1 },
    .codec = .{ .operations = 100, .entities = 1000, .fields = 1000, .depth = 32 },
    .image = .{ .bytes = 65536, .entities = 1024, .depth = 32 },
    .roots = 1,
    .gate_scratch = 64 * 1024 * 1024,
    .verify = choir.ir.verify.default_options,
};

fn registerContext(context: *choir.ir.Context) !void {
    try choir.dialects.registerChoirDialect(context);
    try @import("../choir/root.zig").registerAccyDialect(context);
    try choir.backends.gpu.registerTargetDialects(context);
}

fn makeProgram(allocator: std.mem.Allocator) !kernel_model.Program {
    var builder = try kernel_model.Builder.init(allocator, .testing, "retained_program", &.{
        .{ .buffer = .{ .dtype = .f32, .size = 32 } }, .{ .scalar = .u32 },
    });
    errdefer builder.deinit();
    const axis = try builder.axis("items", 32);
    const split = try builder.split(axis, 8);
    try builder.bind(split.outer, .block_x);
    try builder.bind(split.inner, .thread_x);
    try builder.vectorize(split.inner, 4);
    try builder.unroll(split.outer, 2);
    try builder.return_();
    return builder.finish();
}

fn captureProgram(allocator: std.mem.Allocator) !records.codec.Decoded(records.program.Record) {
    var program = try makeProgram(allocator);
    defer program.deinit();
    return records.program.capture(allocator, &program, configuration);
}

test "Accy stage records retain complete generated programs after source destruction" {
    const allocator = std.testing.allocator;
    var captured = try captureProgram(allocator);
    defer captured.deinit();
    const record = captured.value;
    try std.testing.expectEqual(@as(usize, 2), record.params.len);
    try std.testing.expectEqual(@as(?u64, 32), record.params[0].buffer.size);
    try std.testing.expectEqual(.u32, record.params[1].scalar);
    var context = try choir.ir.Context.init(allocator, configuration.context);
    defer context.deinit(allocator);
    try registerContext(&context);
    var decoded = try choir.bytecode.decodeModule(allocator, &context, record.image);
    defer decoded.deinit();
    try choir.ir.verifyOperation(decoded.module, configuration.verify);
    var references = try records.reference.Index.init(allocator, decoded.module, 1024);
    defer references.deinit();
    var operations = decoded.module.getRegion(0).?.getEntryBlock().?.getOperations();
    const function = operations.next().?;
    try std.testing.expectEqual(record.function, (try references.operation(function)).ordinal);
    try std.testing.expectEqualStrings("retained_program", (choir.dialects.FuncDialect.FuncOp{
        .op = function,
    }).getName().?);
    var replayed = try kernel_model.core.schedule.Schedule.init(allocator, record.schedule.replay_limits);
    defer replayed.deinit(allocator);
    try replayed.replay(record.schedule);
    try std.testing.expectEqualDeep(record.launch, try replayed.launch());
    try std.testing.expectEqualStrings("items", record.schedule.steps[0].axis.name);
    try std.testing.expectEqual(@as(u32, 2), record.launch.block[0]);
    try std.testing.expectEqual(@as(u32, 4), record.launch.grid[0]);
}

fn restoreProgram(allocator: std.mem.Allocator, record: records.program.Record) !void {
    var restored = try records.program.restore(
        allocator,
        record,
        "retained_program",
        configuration,
    );
    defer restored.deinit();
}

test "Accy stage records restore independent arithmetic and complete schedules" {
    const allocator = std.testing.allocator;
    var captured = try captureProgram(allocator);
    var live = true;
    defer if (live) captured.deinit();
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    const expected = try records.codec.encode(
        allocator,
        records.program.Record,
        .kernel,
        captured.value,
        &references,
    );
    defer allocator.free(expected);
    var first = try records.program.restore(
        allocator,
        captured.value,
        "retained_program",
        configuration,
    );
    defer first.deinit();
    var changed = captured.value;
    changed.arithmetic.environment_observable = !changed.arithmetic.environment_observable;
    var second = try records.program.restore(allocator, changed, "retained_program", configuration);
    defer second.deinit();
    const second_policy = changed.arithmetic;
    captured.deinit();
    live = false;
    try std.testing.expect(first.kernelModule().context != second.kernelModule().context);
    try std.testing.expectEqualDeep(second_policy, second.kernelModule().context.arithmetic_policy);
    var actual = try records.program.capture(allocator, &first, configuration);
    defer actual.deinit();
    var wanted = try records.codec.decode(allocator, records.program.Record, .kernel, expected);
    defer wanted.deinit();
    try records.codec.compare(actual.value, wanted.value, &references);
    var alternate = try records.program.capture(allocator, &second, configuration);
    defer alternate.deinit();
    wanted.value.arithmetic = second_policy;
    try records.codec.compare(alternate.value, wanted.value, &references);
}

test "Accy stage records reject invalid restoration and release failed allocations before retry" {
    const allocator = std.testing.allocator;
    var captured = try captureProgram(allocator);
    defer captured.deinit();
    var changed = captured.value;
    changed.function = std.math.maxInt(u32);
    try std.testing.expectError(error.UnboundProductInput, restoreProgram(allocator, changed));
    changed = captured.value;
    changed.launch.grid[0] += 1;
    try std.testing.expectError(error.InvalidStageRecord, restoreProgram(allocator, changed));
    const constrained = comptime limited: {
        var result = configuration;
        result.context.operations.nested_bytes = 1;
        break :limited result;
    };
    try std.testing.expectError(error.WorkExhausted, records.program.restore(
        allocator,
        captured.value,
        "retained_program",
        constrained,
    ));
    try std.testing.checkAllAllocationFailures(allocator, restoreProgram, .{captured.value});
    try restoreProgram(allocator, captured.value);
}

test "Accy stage records preserve full width schedule axis identities and reject changed replay" {
    const allocator = std.testing.allocator;
    const schedule = kernel_model.core.schedule;
    const limits = schedule.Schedule.Limits{
        .axes = 300,
        .steps = 300,
        .name_bytes = 1024,
        .axis_ids = 300,
    };
    var source = try schedule.Schedule.init(allocator, limits);
    defer source.deinit(allocator);
    for (0..300) |_| _ = try source.addAxis("x", 1);
    var snapshot_value = try schedule.createSnapshot(allocator, .{
        .axes = 300,
        .steps = 300,
        .name_bytes = 1024,
    }, &source);
    defer snapshot_value.deinit(allocator);
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    const bytes = try records.codec.encode(
        allocator,
        schedule.Record,
        .kernel,
        try snapshot_value.record(),
        &references,
    );
    defer allocator.free(bytes);
    var decoded = try records.codec.decode(allocator, schedule.Record, .kernel, bytes);
    defer decoded.deinit();
    @memset(bytes, 0xa5);
    try std.testing.expectEqual(@as(u32, 299), decoded.value.axes[299].id.index());
    var replayed = try schedule.Schedule.init(allocator, limits);
    defer replayed.deinit(allocator);
    try replayed.replay(decoded.value);
    try records.codec.compare(decoded.value, try snapshot_value.record(), &references);
    var changed_axes = try allocator.dupe(schedule.Axis, decoded.value.axes);
    defer allocator.free(changed_axes);
    changed_axes[299].extent = 2;
    var changed = decoded.value;
    changed.axes = changed_axes;
    var rejected = try schedule.Schedule.init(allocator, limits);
    defer rejected.deinit(allocator);
    try std.testing.expectError(error.InvalidReplay, rejected.replay(changed));
    try std.testing.expectEqual(@as(usize, 0), rejected.allAxes().len);
    changed = decoded.value;
    changed.replay_limits.axes -= 1;
    try std.testing.expectError(error.InvalidReplay, rejected.replay(changed));
    try std.testing.expectEqual(@as(usize, 0), rejected.allAxes().len);
    try rejected.replay(decoded.value);
}

fn captureKernels() ![]u8 {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = fixture.context();
    defer context.deinit();
    const root = fixture.source.choir_module;
    const outlines = try preparation.outlining.getKernelOutlinePlanAnalysis(&context, root);
    const generated = try preparation.kernelization.getKernelizationAnalysis(&context, root);
    return preparation.capture.kernel(std.testing.allocator, root, outlines, generated, configuration);
}

test "Accy stage records capture actual kernel outlines and generated programs" {
    const allocator = std.testing.allocator;
    const bytes = try captureKernels();
    defer allocator.free(bytes);
    var captured = try records.codec.decode(allocator, records.kernel.Record, .kernel, bytes);
    defer captured.deinit();
    @memset(bytes, 0xa5);
    try std.testing.expect(captured.value.outlines.kernels.len > 0);
    try std.testing.expect(captured.value.generated.kernels.len > 0);
    for (captured.value.generated.kernels) |item| {
        try std.testing.expect(item.program.image.len > 0);
        try std.testing.expectEqual(item.argument_count, item.program.params.len);
        try std.testing.expectEqual(.generic, std.meta.activeTag(item.body));
        try std.testing.expect(item.entry_name.len > 0);
    }
}

fn failingProgramCapture(allocator: std.mem.Allocator, program: *const kernel_model.Program) !void {
    var captured = try records.program.capture(allocator, program, configuration);
    defer captured.deinit();
}

test "Accy stage records qualify program capture and release failed allocations" {
    const allocator = std.testing.allocator;
    var program = try makeProgram(allocator);
    defer program.deinit();
    try std.testing.checkAllAllocationFailures(allocator, failingProgramCapture, .{&program});
    const metadata: u32 = 7;
    program.kernelModule().location = .{ .fused = .{ .locations = &.{.unknown}, .metadata = &metadata } };
    try std.testing.expectError(error.UnencodableProduct, failingProgramCapture(allocator, &program));
}

fn seal(
    store: *revision.Store,
    kind: *const revision.Kind,
    root: *choir.ir.Operation,
    comptime stage: publication.Stage,
    bytes: []const u8,
    parent: ?operation.Product,
) !operation.Product {
    const allocator = std.testing.allocator;
    const policy = try choir.product.recipe.encode(allocator, .{
        .arithmetic = root.getContext().arithmetic_policy,
        .policy = "plan-capture-test",
    });
    defer allocator.free(policy);
    const builder = try store.begin(.{
        .kind = kind,
        .address = .{
            .producer = "accy",
            .source = "plan-test",
            .stage = stage.name(),
            .variant = "",
        },
        .inputs = .{
            .compiler_manifest = try choir.product.compiler.manifest(),
            .versions = &.{ stage.schema(), operation.schema_identity },
            .pipeline = &.{},
            .options = &.{},
            .policy = policy,
        },
        .dependencies = if (parent) |source|
            &.{.{ .role = "source", .revision = source.revision }}
        else
            &.{},
        .parent = if (parent) |source| source.revision else null,
    }, .{
        .allowance = revision.WorkVector.uniform(1024 * 1024 * 1024),
        .workspace = 128 * 1024 * 1024,
        .events = 64,
    });
    var open = true;
    errdefer if (open) {
        if (builder.abort(.rejected)) |failure| {
            var owned = failure;
            owned.deinit();
        }
    };
    try operation.capture(builder, &.{.{ .operation = root }}, bytes, &.{}, configuration);
    const product = try operation.Product.seal(builder, kind);
    open = false;
    return product;
}

const Chain = struct {
    store: *revision.Store,
    kinds: [7]*const revision.Kind,
    products: [7]operation.Product,

    fn init(root: *choir.ir.Operation, captured: Snapshot) !Chain {
        if (choir.product.compiler.unrecorded) return error.SkipZigTest;
        const allocator = std.testing.allocator;
        const store = try revision.Store.create(allocator, .{
            .revisions = 10,
            .kinds = 7,
            .builders = 4,
            .compiler_manifests = 2,
            .record_bytes = 32 * 1024 * 1024,
            .gate_scratch_bytes = configuration.gate_scratch,
            .candidate_count = 8,
            .screening_bytes = 32 * 1024 * 1024,
        });
        errdefer store.release();
        const stages = [_]publication.Stage{
            .semantic, .contract, .tensor, .dispatch, .memory, .kernel, .target,
        };
        var kinds: [7]*const revision.Kind = undefined;
        inline for (stages, 0..) |stage, index| {
            kinds[index] = try preparation.publication.registerKind(
                allocator,
                store,
                stage,
                configuration,
            );
        }
        store.freeze();
        const bytes = [_][]const u8{
            &publication.irRecord(.semantic), &publication.irRecord(.contract),
            &publication.irRecord(.tensor),   captured.dispatch,
            captured.memory,                  captured.kernel,
            captured.target,
        };
        var products: [7]operation.Product = undefined;
        var count: usize = 0;
        errdefer for (products[0..count]) |product| product.release();
        inline for (stages, 0..) |stage, index| {
            products[index] = try seal(
                store,
                kinds[index],
                root,
                stage,
                bytes[index],
                if (index == 0) null else products[index - 1],
            );
            count += 1;
        }
        return .{ .store = store, .kinds = kinds, .products = products };
    }

    fn deinit(self: *Chain) void {
        for (self.products) |product| product.release();
        self.store.release();
    }
};

test "sealed Accy stages own typed plans and reject invalid references" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    var live = true;
    defer if (live) fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    try rejectCorruption(&chain, fixture.source.choir_module, captured);
    try rejectKernelCorruption(&chain, fixture.source.choir_module, captured);
    try rejectTargetCorruption(&chain, fixture.source.choir_module, captured);
    const dispatch = try publication.Module(.dispatch).fromRevision(
        allocator,
        chain.products[3].revision,
    );
    defer dispatch.deinit();
    const memory = try publication.Module(.memory).fromRevision(
        allocator,
        chain.products[4].revision,
    );
    defer memory.deinit();
    const kernel = try publication.Module(.kernel).fromRevision(
        allocator,
        chain.products[5].revision,
    );
    defer kernel.deinit();
    const target = try publication.Module(.target).fromRevision(
        allocator,
        chain.products[6].revision,
    );
    defer target.deinit();
    fixture.deinit();
    live = false;
    @memset(captured.dispatch, 0xa5);
    @memset(captured.memory, 0xa5);
    @memset(captured.kernel, 0xa5);
    @memset(captured.target, 0xa5);
    var dispatch_plan = try dispatch.plan(allocator, configuration.image);
    defer dispatch_plan.deinit();
    var memory_plan = try memory.plan(allocator, configuration.image);
    defer memory_plan.deinit();
    var kernel_plan = try kernel.plan(allocator, configuration.image);
    defer kernel_plan.deinit();
    var target_plan = try target.plan(allocator, configuration.image);
    defer target_plan.deinit();
    try std.testing.expect(dispatch_plan.value.schedule.work_items.len > 0);
    try std.testing.expect(memory_plan.value.buffers.slots.len > 0);
    try std.testing.expect(kernel_plan.value.generated.kernels.len > 0);
    try records.kernel.validate(allocator, kernel_plan.value, memory_plan.value);
    try std.testing.expectEqual(null, target_plan.value.profile);
    try std.testing.expect(target_plan.value.kernels.len > 0);
    try std.testing.expectEqual(null, target_plan.value.kernels[0].abi);
}

const TargetCorruption = enum { work, count, profile, function, math, arguments, scalars };

fn corruptTarget(value: *records.target.Record, corruption: TargetCorruption) anyerror {
    const kernel = &@constCast(value.kernels)[0];
    switch (corruption) {
        .work => kernel.lowered.work_item_id = 99999,
        .count => value.kernels = value.kernels[0..0],
        .profile => value.profile = .{ .backend_kind = .cpu, .artifact_format = .cpu_object },
        .function => {
            kernel.lowered.program.function = 99999;
            return error.UnboundProductInput;
        },
        .math => value.math_tier = .tf32_tensor,
        .arguments => kernel.lowered.argument_count += 1,
        .scalars => kernel.runtime_scalar_argument_count = kernel.lowered.argument_count + 1,
    }
    return error.InvalidStageRecord;
}

fn rejectTargetCorruption(chain: *Chain, root: *choir.ir.Operation, captured: Snapshot) !void {
    const allocator = std.testing.allocator;
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    for (std.enums.values(TargetCorruption)) |corruption| {
        var decoded = try records.codec.decode(
            allocator,
            records.target.Record,
            .target,
            captured.target,
        );
        defer decoded.deinit();
        const expected = corruptTarget(&decoded.value, corruption);
        const bytes = try records.codec.encode(
            allocator,
            records.target.Record,
            .target,
            decoded.value,
            &references,
        );
        defer allocator.free(bytes);
        try expectRejected(expected, seal(
            chain.store,
            chain.kinds[6],
            root,
            .target,
            bytes,
            chain.products[5],
        ));
    }
    try expectRejected(error.InvalidStageDependency, seal(
        chain.store,
        chain.kinds[6],
        root,
        .target,
        captured.target,
        chain.products[4],
    ));
}

const KernelCorruption = enum {
    outline_slot,
    outline_root,
    program_function,
    program_nonfunction,
    program_parameter,
    program_entry,
    program_launch,
    schedule_axis,
    counters,
    argument_count,
    work,
};

fn corruptKernel(value: *records.kernel.Record, corruption: KernelCorruption) anyerror {
    const outline = &@constCast(value.outlines.kernels)[0];
    const kernel = &@constCast(value.generated.kernels)[0];
    switch (corruption) {
        .outline_slot => outline.output_slot_id = 99999,
        .outline_root => {
            outline.root.ordinal = 99999;
            return error.UnboundProductInput;
        },
        .program_function => {
            kernel.program.function = 99999;
            return error.UnboundProductInput;
        },
        .program_nonfunction => kernel.program.function = 0,
        .program_parameter => @constCast(kernel.program.params)[0] = .{ .scalar = .u32 },
        .program_entry => kernel.entry_name = "wrong_entry",
        .program_launch => kernel.program.launch.block[0] += 1,
        .schedule_axis => {
            @constCast(kernel.program.schedule.axes)[0].extent = 999;
            return error.InvalidReplay;
        },
        .counters => value.outlines.total_input_slots += 1,
        .argument_count => kernel.argument_count += 1,
        .work => kernel.work_item_id = 99999,
    }
    return error.InvalidStageRecord;
}

fn rejectKernelCorruption(chain: *Chain, root: *choir.ir.Operation, captured: Snapshot) !void {
    const allocator = std.testing.allocator;
    var references = try records.reference.Index.init(allocator, root, 1024);
    defer references.deinit();
    for (std.enums.values(KernelCorruption)) |corruption| {
        var decoded = try records.codec.decode(
            allocator,
            records.kernel.Record,
            .kernel,
            captured.kernel,
        );
        defer decoded.deinit();
        const expected = corruptKernel(&decoded.value, corruption);
        const bytes = try records.codec.encode(
            allocator,
            records.kernel.Record,
            .kernel,
            decoded.value,
            &references,
        );
        defer allocator.free(bytes);
        try expectRejected(expected, seal(
            chain.store,
            chain.kinds[5],
            root,
            .kernel,
            bytes,
            chain.products[4],
        ));
    }
    try expectRejected(error.InvalidStageDependency, seal(
        chain.store,
        chain.kinds[5],
        root,
        .kernel,
        captured.kernel,
        chain.products[3],
    ));
}

test "sealed Accy Kernel validates multiple program images within the same gate scratch" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.initNames(&.{ "first", "second" });
    var live = true;
    defer if (live) fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    fixture.deinit();
    live = false;
    @memset(captured.kernel, 0xa5);
    const kernel = try publication.Module(.kernel).fromRevision(
        allocator,
        chain.products[5].revision,
    );
    defer kernel.deinit();
    var plan = try kernel.plan(allocator, configuration.image);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.value.generated.kernels.len);
    try std.testing.expect(!std.mem.eql(
        u8,
        plan.value.generated.kernels[0].entry_name,
        plan.value.generated.kernels[1].entry_name,
    ));
}

fn targetVariant(
    chain: *Chain,
    fixture: *Fixture,
    profile: preparation.BackendTargetProfile,
) !operation.Product {
    const allocator = std.testing.allocator;
    const root = try fixture.source.choir_module.clone();
    defer root.erase();
    try preparation.setBackendTargetProfile(root.context, root, profile);
    try preparation.target.setGeneratedScanSchedules(allocator, root.context, root, &.{.{
        .total = 4,
        .schedule = .{ .threads = 32, .items = 1 },
    }});
    try preparation.target.setGeneratedRowPipelineSchedules(allocator, root.context, root, &.{.{
        .shape = .{ .rows = 1, .cols = 4 },
        .schedule = .{ .threads = 32 },
    }});
    var context = fixture.context();
    defer context.deinit();
    const source = fixture.source.choir_module;
    const schedule = try preparation.schedule.getSchedulePlanAnalysis(&context, source);
    const generated = try preparation.kernelization.getKernelizationAnalysis(&context, source);
    const bytes = try preparation.capture.target(
        allocator,
        root,
        schedule,
        generated.kernels.items,
        configuration,
    );
    defer allocator.free(bytes);
    return seal(chain.store, chain.kinds[6], root, .target, bytes, chain.products[5]);
}

test "sealed Accy Target owns sibling target contracts after source destruction" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    var live = true;
    defer if (live) fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    const cpu_product = try targetVariant(&chain, &fixture, .{
        .backend_kind = .cpu,
        .artifact_format = .cpu_object,
    });
    defer cpu_product.release();
    const gpu_product = try targetVariant(&chain, &fixture, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
    });
    defer gpu_product.release();
    fixture.deinit();
    live = false;
    @memset(captured.target, 0xa5);
    const cpu = try publication.Module(.target).fromRevision(allocator, cpu_product.revision);
    defer cpu.deinit();
    const accelerated = try publication.Module(.target).fromRevision(allocator, gpu_product.revision);
    defer accelerated.deinit();
    try std.testing.expect(!cpu.eql(accelerated));
    var cpu_plan = try cpu.plan(allocator, configuration.image);
    defer cpu_plan.deinit();
    var gpu_plan = try accelerated.plan(allocator, configuration.image);
    defer gpu_plan.deinit();
    const host = cpu_plan.value.kernels[0];
    const device = gpu_plan.value.kernels[0];
    try std.testing.expectEqual(host.lowered.argument_count + gpu_abi.launch_shape_argument_count, host.abi.?.argument_count);
    try std.testing.expectEqual(@as(usize, gpu_abi.launch_shape_argument_count), host.abi.?.static_arguments.len);
    try std.testing.expectEqual(@as(u32, 0), host.abi.?.static_arguments[0].u32);
    try std.testing.expectEqual(@as(u32, 4), host.abi.?.static_arguments[1].u32);
    try std.testing.expectEqual(@as(?u32, 4), host.abi.?.compile_options.cpu_vector_width);
    try std.testing.expectEqual(device.lowered.argument_count, device.abi.?.argument_count);
    try std.testing.expectEqual(@as(usize, 0), device.abi.?.static_arguments.len);
    try std.testing.expectEqual(@as(?u32, null), device.abi.?.compile_options.cpu_vector_width);
    try std.testing.expectEqualStrings("4=32x1", cpu_plan.value.generated_scan_schedules.?);
    try std.testing.expectEqualStrings(
        "1x4=32",
        cpu_plan.value.generated_row_pipeline_schedules.?,
    );
    const expected_dtypes = gpu.DTypeSet.init(&.{ .f32, .i32 });
    try std.testing.expectEqual(expected_dtypes.bits, host.required_dtype_bits);
    try std.testing.expectEqual(.exact, cpu_plan.value.math_tier);
    try std.testing.expectEqual(@as(u32, 0), host.runtime_scalar_argument_count);
}

test "Accy stage records capture nonempty target requirements from program operations" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = fixture.context();
    defer context.deinit();
    const root = fixture.source.choir_module;
    const schedule = try preparation.schedule.getSchedulePlanAnalysis(&context, root);
    const generated = try preparation.kernelization.getKernelizationAnalysis(&context, root);
    const kernel = &generated.kernels.items[0];
    const program_context = kernel.program.kernelModule().context;
    const block = kernel.program.storage.kernel.func().getEntryBlock();
    const terminator: *choir.ir.Operation = @ptrCast(@alignCast(block.operations.tail.?));
    const Gpu = choir.dialects.gpu.GpuDialect;
    const active = try Gpu.ActiveMaskOp.create(program_context, .unknown);
    try block.insertBefore(active.op, terminator);
    const commit = try Gpu.CpAsyncCommitOp.create(program_context, .unknown);
    try block.insertBefore(commit.op, terminator);
    kernel.body_fingerprint = try kernel.program.bodyFingerprint(allocator);
    const bytes = try preparation.capture.target(
        allocator,
        root,
        schedule,
        generated.kernels.items,
        configuration,
    );
    defer allocator.free(bytes);
    var decoded = try records.codec.decode(allocator, records.target.Record, .target, bytes);
    defer decoded.deinit();
    try std.testing.expect(decoded.value.kernels[0].required_features.tensor_cores);
    try std.testing.expect(decoded.value.kernels[0].required_subgroup.supported);
    try std.testing.expect(decoded.value.kernels[0].required_subgroup.ballot);
}

test "Accy stage records preserve floating ABI argument bits" {
    const allocator = std.testing.allocator;
    const T = struct { arguments: []const gpu_abi.ScalarArgument };
    const source = T{ .arguments = &.{
        .{ .f32 = @bitCast(@as(u32, 0x7fc00043)) },
        .{ .f64 = @bitCast(@as(u64, 0x7ff8000000000012)) },
        .{ .f64 = @bitCast(@as(u64, 0x8000000000000000)) },
    } };
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    const bytes = try records.codec.encode(allocator, T, .target, source, &references);
    defer allocator.free(bytes);
    var decoded = try records.codec.decode(allocator, T, .target, bytes);
    defer decoded.deinit();
    try records.codec.compare(decoded.value, source, &references);
    const first_bits: u32 = @bitCast(decoded.value.arguments[0].f32);
    try std.testing.expectEqual(@as(u32, 0x7fc00043), first_bits);
    try std.testing.expectEqual(
        @as(u64, 0x8000000000000000),
        @as(u64, @bitCast(decoded.value.arguments[2].f64)),
    );
    @constCast(decoded.value.arguments)[1].f64 = @bitCast(@as(u64, 0x7ff8000000000013));
    try std.testing.expectError(error.UnencodableProduct, records.codec.compare(
        decoded.value,
        source,
        &references,
    ));
}

fn rejectCorruption(chain: *Chain, root: *choir.ir.Operation, captured: Snapshot) !void {
    const allocator = std.testing.allocator;
    var dispatch = try records.codec.decode(
        allocator,
        records.dispatch.Record,
        .dispatch,
        captured.dispatch,
    );
    defer dispatch.deinit();
    @constCast(dispatch.value.schedule.work_items)[0].root.ordinal = 99999;
    var references = try records.reference.Index.init(allocator, root, 1024);
    defer references.deinit();
    const bad_dispatch = try records.codec.encode(
        allocator,
        records.dispatch.Record,
        .dispatch,
        dispatch.value,
        &references,
    );
    defer allocator.free(bad_dispatch);
    try expectRejected(error.UnboundProductInput, seal(
        chain.store,
        chain.kinds[3],
        root,
        .dispatch,
        bad_dispatch,
        chain.products[2],
    ));
    var memory = try records.codec.decode(
        allocator,
        records.memory.Record,
        .memory,
        captured.memory,
    );
    defer memory.deinit();
    @constCast(memory.value.spaces.assignments)[0].output_source = .{ .aliased = 99999 };
    const bad_memory = try records.codec.encode(
        allocator,
        records.memory.Record,
        .memory,
        memory.value,
        &references,
    );
    defer allocator.free(bad_memory);
    try expectRejected(error.InvalidStageRecord, seal(
        chain.store,
        chain.kinds[4],
        root,
        .memory,
        bad_memory,
        chain.products[3],
    ));
}

test "Accy stage records bound reference indexing and reject stale analysis maps" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var foreign = try Fixture.init();
    defer foreign.deinit();
    var index = try records.reference.Index.init(allocator, fixture.source.choir_module, 1024);
    defer index.deinit();
    try std.testing.expectError(
        error.UnboundProductInput,
        index.operation(foreign.source.choir_module),
    );
    const bound: u32 = @intCast(@max(index.operations.count(), index.values.count()));
    var exact = try records.reference.Index.init(allocator, fixture.source.choir_module, bound);
    defer exact.deinit();
    try std.testing.expectError(
        error.RecordLimit,
        records.reference.Index.init(allocator, fixture.source.choir_module, bound - 1),
    );
    var context = fixture.context();
    defer context.deinit();
    const root = fixture.source.choir_module;
    const fusion = try preparation.fusion.getFusionPlanAnalysis(&context, root);
    const schedule = try preparation.schedule.getSchedulePlanAnalysis(&context, root);
    @constCast(schedule).root_to_item.clearRetainingCapacity();
    try std.testing.expectError(error.UnencodableProduct, preparation.capture.dispatch(
        allocator,
        root,
        fusion,
        schedule,
        1024,
    ));
}

fn expectRejected(expected: anyerror, result: anyerror!operation.Product) !void {
    const product = result catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    product.release();
    return error.TestExpectedError;
}

fn captureFailure(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    buffers: *const preparation.bufferization.BufferPlanAnalysis,
    spaces: *const preparation.memory.MemorySpacePlanAnalysis,
    layouts: *const preparation.layout.LayoutPlanAnalysis,
) !void {
    const bytes = try preparation.capture.memory(allocator, root, buffers, spaces, layouts, 1024);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 5);
}

test "Accy stage records clean partial capture allocations" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = fixture.context();
    defer context.deinit();
    const root = fixture.source.choir_module;
    const buffers = try preparation.bufferization.getBufferPlanAnalysis(&context, root);
    const spaces = try preparation.memory.getMemorySpacePlanAnalysis(&context, root);
    const layouts = try preparation.layout.getLayoutPlanAnalysis(&context, root);
    try std.testing.checkAllAllocationFailures(
        allocator,
        captureFailure,
        .{ root, buffers, spaces, layouts },
    );
}

test "Accy publication recipes match the real ordered stage pipelines" {
    const recipe = preparation.recipe;
    const options = preparation.BackendPreparationRunOptions{};
    inline for (comptime std.meta.tags(publication.Stage)) |stage| {
        var manager = choir.passes.PassManager.init(std.testing.allocator);
        defer manager.deinit();
        try recipe.configure(&manager, stage, &options);
        try std.testing.expect(manager.verifier_enabled);
        try std.testing.expectEqualDeep(recipe.policy.verification, manager.verifier_options);
        try std.testing.expectEqual(@as(usize, 1), recipe.runOptions().max_threads);
        try std.testing.expectEqual(null, recipe.runOptions().worker_allocator);
        const identities = recipe.pipeline(stage);
        try std.testing.expectEqual(identities.len, manager.root.pipeline.items.len);
        for (identities, manager.root.pipeline.items) |identity, entry| {
            try std.testing.expectEqualStrings(identity.name, entry.pass.name);
            try std.testing.expectEqual(@as(u32, 1), identity.version);
        }
    }
}

fn recipeBytes(
    fixture: *Fixture,
    comptime stage: publication.Stage,
    options: preparation.BackendPreparationRunOptions,
) ![]u8 {
    return preparation.recipe.encode(
        std.testing.allocator,
        stage,
        fixture.source.choir_module,
        options,
    );
}

test "Accy publication recipes record every tensor choice and default" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const original = try recipeBytes(&fixture, .tensor, .{});
    defer allocator.free(original);
    var decoded = try records.codec.decode(
        allocator,
        preparation.recipe.Record(.tensor),
        .tensor,
        original,
    );
    defer decoded.deinit();
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    const defaults = preparation.TensorLoweringOptions{};
    try records.codec.compare(decoded.value.options, defaults, &references);
    try std.testing.expectEqualDeep(preparation.recipe.policy, decoded.value.execution);
    for (0..13) |choice| {
        var options = preparation.BackendPreparationRunOptions{};
        switch (choice) {
            0 => options.tensor.activation.kernel_library = .enabled,
            1 => options.tensor.einsum.strategy = .greedy,
            2 => options.tensor.einsum.exact_state_limit += 1,
            3 => options.tensor.einsum.beam_width += 1,
            4 => options.tensor.einsum.auto_beam_width += 1,
            5 => options.tensor.einsum.kernel_library = .enabled,
            6 => options.tensor.einsum.matrix_product_schedule = .{
                .thread_blocks = .{ .x = 8, .y = 4 },
            },
            7 => options.tensor.indexing.kernel_library = .enabled,
            8 => options.tensor.indexing.gather_schedule = .{ .thread_blocks = 32 },
            9 => options.tensor.indexing.scatter_schedule = .{ .thread_blocks = 64 },
            10 => options.tensor.indexing.scatter_add_schedule = .{ .shared_bins = 128 },
            11 => options.tensor.loss.kernel_library = .enabled,
            12 => options.tensor.loss.row_sparse_cross_entropy_schedule = .{
                .thread_blocks = 256,
            },
            else => unreachable,
        }
        const changed = try recipeBytes(&fixture, .tensor, options);
        defer allocator.free(changed);
        try std.testing.expect(!std.mem.eql(u8, original, changed));
    }
}

test "Accy publication recipes preserve inherited targets and explicit overrides" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const absent = try recipeBytes(&fixture, .kernel, .{});
    defer allocator.free(absent);
    const options = preparation.BackendPreparationRunOptions{
        .target_profile = .{ .backend_kind = .cpu, .artifact_format = .cpu_object },
        .generated_scan_schedules = &.{.{ .schedule = .{ .threads = 32, .items = 2 } }},
        .generated_row_pipeline_schedules = &.{.{ .schedule = .{ .threads = 64 } }},
    };
    const root = fixture.source.choir_module;
    const explicit = try recipeBytes(&fixture, .kernel, options);
    defer allocator.free(explicit);
    const unchanged = try recipeBytes(&fixture, .kernel, .{});
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(absent, unchanged);
    try preparation.recipe.applyTargetOptions(allocator, root, options);
    const applied = try recipeBytes(&fixture, .kernel, options);
    defer allocator.free(applied);
    try std.testing.expectEqualStrings(explicit, applied);
    try preparation.recipe.applyTargetOptions(allocator, root, .{});
    const inherited = try recipeBytes(&fixture, .kernel, .{});
    defer allocator.free(inherited);
    try std.testing.expectEqualStrings(explicit, inherited);
    try std.testing.expect(!std.mem.eql(u8, absent, inherited));
    var decoded = try records.codec.decode(
        allocator,
        preparation.recipe.Record(.kernel),
        .kernel,
        inherited,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(.cpu_object, decoded.value.options.profile.?.artifact_format);
    try std.testing.expectEqualStrings("32x2", decoded.value.options.generated_scan_schedules.?);
    try std.testing.expectEqualStrings(
        "64",
        decoded.value.options.generated_row_pipeline_schedules.?,
    );
    try preparation.recipe.applyTargetOptions(allocator, root, .{
        .target_profile = .{ .backend_kind = .cuda, .artifact_format = .cuda_ptx },
    });
    const overridden = try recipeBytes(&fixture, .kernel, .{});
    defer allocator.free(overridden);
    try std.testing.expect(!std.mem.eql(u8, inherited, overridden));
}

test "Accy publication recipes exclude diagnostics" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const original = try recipeBytes(&fixture, .tensor, .{});
    defer allocator.free(original);
    var failure = preparation.BackendPreparationFailure{};
    defer failure.deinit(allocator);
    var timing = preparation.BackendPreparationTiming.init(allocator);
    defer timing.deinit();
    const diagnostic = try recipeBytes(&fixture, .tensor, .{
        .failure = &failure,
        .timing = &timing,
        .now = struct {
            fn now() i128 {
                return 42;
            }
        }.now,
    });
    defer allocator.free(diagnostic);
    try std.testing.expectEqualStrings(original, diagnostic);
}

const TuningRecipeCase = struct {
    const library = @import("../kernel/library/root.zig");
    const tuning = library.tuning;
    const device: u64 = 912;

    arena: std.heap.ArenaAllocator,
    records: []tuning.FamilyTuningRecord,

    fn matrix() library.linalg.MatrixProduct {
        var instance: library.linalg.MatrixProduct = .{ .m = 64, .n = 32, .k = 16 };
        const candidates = library.linalg.matrixProductThreadCandidatesForExtents(64, 32);
        instance.threads = candidates.slice()[candidates.slice().len - 1];
        return instance;
    }

    fn gather() library.indexing.Gather {
        var instance: library.indexing.Gather = .{ .axis_size = 64, .gathered = 32 };
        const candidates = library.indexing.gatherThreadCandidatesForTotal(instance.total());
        instance.threads = candidates.slice()[candidates.slice().len - 1];
        return instance;
    }

    fn init() !TuningRecipeCase {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const items = try allocator.alloc(tuning.FamilyTuningRecord, 2);
        items[0] = .{
            .key = try library.linalg.matrixProductFamilyTuningKey(allocator, device, matrix()),
            .target = try library.linalg.matrixProductFamilyTarget(allocator, matrix()),
            .winner_median_ns = 7,
            .runner_up_median_ns = 11,
            .sample_count = 3,
        };
        items[1] = .{
            .key = try library.indexing.gatherFamilyTuningKey(allocator, device, gather()),
            .target = try library.indexing.gatherFamilyTarget(allocator, gather()),
            .winner_median_ns = 13,
            .runner_up_median_ns = 17,
            .sample_count = 5,
        };
        return .{ .arena = arena, .records = items };
    }

    fn reader(self: TuningRecipeCase) tuning.FamilyTuningReader {
        return .{ .device_fingerprint = device, .table = .{ .records = self.records } };
    }

    fn options(reader_: *const tuning.FamilyTuningReader) preparation.BackendPreparationRunOptions {
        return .{ .tensor = .{
            .einsum = .{ .kernel_library = .enabled, .family_tuning = reader_ },
            .indexing = .{ .kernel_library = .enabled, .family_tuning = reader_ },
        } };
    }

    fn deinit(self: *TuningRecipeCase) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn independentTuningRecipe() ![]u8 {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var source = try TuningRecipeCase.init();
    defer source.deinit();
    var reader = source.reader();
    const bytes = try recipeBytes(&fixture, .tensor, TuningRecipeCase.options(&reader));
    reader.device_fingerprint = 0;
    for (source.records) |*record| {
        @memset(@constCast(record.target), 'x');
        record.key.extents = @splat(0);
    }
    return bytes;
}

test "Accy publication recipes own tuning hits and misses after source destruction" {
    const allocator = std.testing.allocator;
    const library = TuningRecipeCase.library;
    const bytes = try independentTuningRecipe();
    defer allocator.free(bytes);
    var decoded = try records.codec.decode(
        allocator,
        preparation.recipe.Record(.tensor),
        .tensor,
        bytes,
    );
    defer decoded.deinit();
    try std.testing.expect(decoded.value.options.einsum.family_tuning != null);
    try std.testing.expect(decoded.value.options.indexing.family_tuning != null);
    const matrix_reader = decoded.value.options.einsum.family_tuning.?;
    const gather_reader = decoded.value.options.indexing.family_tuning.?;
    try std.testing.expectEqual(TuningRecipeCase.device, matrix_reader.device_fingerprint);
    try std.testing.expectEqual(@as(usize, 2), matrix_reader.table.records.len);
    try std.testing.expectEqual(@as(u64, 7), matrix_reader.table.records[0].winner_median_ns);
    try std.testing.expectEqualDeep(matrix_reader, gather_reader);
    const matrix = TuningRecipeCase.matrix();
    const gather = TuningRecipeCase.gather();
    try std.testing.expectEqual(matrix.threads, (try library.linalg.resolveMatrixProductSchedule(
        allocator,
        matrix_reader,
        matrix,
    )).?);
    try std.testing.expectEqual(gather.threads, (try library.indexing.resolveGatherSchedule(
        allocator,
        gather_reader,
        gather,
    )).?);
    var absent_matrix = matrix;
    absent_matrix.k += 1;
    var absent_gather = gather;
    absent_gather.axis_size += 1;
    try std.testing.expectEqual(null, try library.linalg.resolveMatrixProductSchedule(
        allocator,
        matrix_reader,
        absent_matrix,
    ));
    try std.testing.expectEqual(null, try library.indexing.resolveGatherSchedule(
        allocator,
        gather_reader,
        absent_gather,
    ));
}

fn tuningRecipeDiffers(fixture: *Fixture, baseline: []const u8, reader: anytype) !void {
    const changed = try recipeBytes(fixture, .tensor, TuningRecipeCase.options(reader));
    defer std.testing.allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, baseline, changed));
}

test "Accy publication recipes compare tuning values independent of pointer identity" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var source = try TuningRecipeCase.init();
    defer source.deinit();
    var reader = source.reader();
    const original = try recipeBytes(&fixture, .tensor, TuningRecipeCase.options(&reader));
    defer allocator.free(original);
    var relocated = try TuningRecipeCase.init();
    defer relocated.deinit();
    const other = relocated.reader();
    const same = try recipeBytes(&fixture, .tensor, TuningRecipeCase.options(&other));
    defer allocator.free(same);
    try std.testing.expectEqualSlices(u8, original, same);
    reader.device_fingerprint += 1;
    try tuningRecipeDiffers(&fixture, original, &reader);
    reader = source.reader();
    for (0..5) |field| {
        const saved = source.records[0];
        switch (field) {
            0 => source.records[0].key.extents[0] += 1,
            1 => source.records[0].key.dtype = .f16,
            2 => source.records[0].target = "absent-target",
            3 => source.records[0].sample_count += 1,
            4 => source.records[0].key.family_version += 1,
            else => unreachable,
        }
        try tuningRecipeDiffers(&fixture, original, &reader);
        source.records[0] = saved;
    }
    std.mem.swap(
        TuningRecipeCase.tuning.FamilyTuningRecord,
        &source.records[0],
        &source.records[1],
    );
    try tuningRecipeDiffers(&fixture, original, &reader);
}

test "Accy publication recipes distinguish absent and empty tuning providers" {
    const linalg = TuningRecipeCase.library.linalg;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const absent = try recipeBytes(&fixture, .tensor, .{});
    defer allocator.free(absent);
    var reader: TuningRecipeCase.tuning.FamilyTuningReader = .{
        .device_fingerprint = TuningRecipeCase.device,
        .table = .{},
    };
    var options = preparation.BackendPreparationRunOptions{};
    for (0..2) |kind| {
        switch (kind) {
            0 => options.tensor.einsum.family_tuning = &reader,
            else => options.tensor.indexing.family_tuning = &reader,
        }
        const bytes = try recipeBytes(&fixture, .tensor, options);
        defer allocator.free(bytes);
        try std.testing.expect(!std.mem.eql(u8, absent, bytes));
        var decoded = try records.codec.decode(
            allocator,
            preparation.recipe.Record(.tensor),
            .tensor,
            bytes,
        );
        defer decoded.deinit();
        const present = switch (kind) {
            0 => decoded.value.options.einsum.family_tuning,
            else => decoded.value.options.indexing.family_tuning,
        };
        try std.testing.expect(present != null);
        const captured = present.?;
        try std.testing.expectEqual(@as(usize, 0), captured.table.records.len);
        try std.testing.expectEqual(null, try linalg.resolveMatrixProductSchedule(
            allocator,
            captured,
            TuningRecipeCase.matrix(),
        ));
        options = .{};
    }
}

fn tuningRecipeFailure(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    reader: *const TuningRecipeCase.tuning.FamilyTuningReader,
) !void {
    const bytes = try preparation.recipe.encode(
        allocator,
        .tensor,
        root,
        TuningRecipeCase.options(reader),
    );
    defer allocator.free(bytes);
}

test "Accy publication recipes clean partial tuning capture allocations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var source = try TuningRecipeCase.init();
    defer source.deinit();
    const reader = source.reader();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, tuningRecipeFailure, .{
        fixture.source.choir_module, &reader,
    });
}

test "Accy publication recipes preserve first-match tuning record order" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var source = try TuningRecipeCase.init();
    defer source.deinit();
    source.records[1] = source.records[0];
    source.records[0].target = "stale-target";
    const reader = source.reader();
    var first: ?[]u8 = null;
    defer if (first) |bytes| allocator.free(bytes);
    for (0..2) |order| {
        const bytes = try recipeBytes(&fixture, .tensor, TuningRecipeCase.options(&reader));
        defer if (order != 0) allocator.free(bytes);
        if (order == 0) first = bytes else try std.testing.expect(!std.mem.eql(u8, first.?, bytes));
        var decoded = try records.codec.decode(
            allocator,
            preparation.recipe.Record(.tensor),
            .tensor,
            bytes,
        );
        defer decoded.deinit();
        try std.testing.expect(decoded.value.options.einsum.family_tuning != null);
        const found = try TuningRecipeCase.library.linalg.resolveMatrixProductSchedule(
            allocator,
            decoded.value.options.einsum.family_tuning.?,
            TuningRecipeCase.matrix(),
        );
        if (order == 0) {
            try std.testing.expectEqual(null, found);
        } else {
            try std.testing.expectEqual(TuningRecipeCase.matrix().threads, found.?);
        }
        std.mem.swap(
            TuningRecipeCase.tuning.FamilyTuningRecord,
            &source.records[0],
            &source.records[1],
        );
    }
}

const MatrixRecipeCase = struct {
    const library = TuningRecipeCase.library;
    const tuning = library.tuning;
    const Reader = library.linalg.MatrixProductScheduleReader;
    const Record = tuning.MatrixProductFamilyScheduleTuningRecord;
    const device: gpu.DeviceIdentity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "matrix recipe device",
        .vendor_id = 0x10de,
        .device_id = 42,
        .driver_version = "matrix recipe driver",
    };

    fn record() !Record {
        const instance = TuningRecipeCase.matrix();
        const threads = library.linalg.matrixProductThreadCandidatesForExtents(
            instance.m,
            instance.n,
        );
        const capacity = tuning.matrix_product_family_schedule_tuning_max_candidates;
        var candidates: [capacity]tuning.MatrixProductFamilyScheduleThreads = undefined;
        for (threads.slice(), 0..) |value, index| {
            candidates[index] = .{ .x = value.x, .y = value.y };
        }
        return .{
            .key = try tuning.MatrixProductFamilyScheduleTuningKey.init(device, .{
                .format = .cuda_ptx,
                .m = instance.m,
                .n = instance.n,
                .k = instance.k,
                .dtype = instance.dtype,
                .accumulation_dtype = instance.accumulation_dtype,
                .family_version = library.linalg.matrix_product_family_version,
                .candidates = candidates[0..threads.slice().len],
            }),
            .selection = .{
                .threads = .{ .x = instance.threads.x, .y = instance.threads.y },
                .winner_median_ns = 3,
                .runner_up_median_ns = 5,
                .sample_count = 7,
            },
        };
    }

    fn reader(items: []const Record) Reader {
        return .{ .device = device, .format = .cuda_ptx, .records = items };
    }

    fn options(value: ?Reader) preparation.BackendPreparationRunOptions {
        return .{ .tensor = .{ .einsum = .{
            .kernel_library = .enabled,
            .matrix_product_tuning = value,
        } } };
    }
};

fn independentMatrixRecipe() ![]u8 {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = arena.allocator();
    const items = try source.alloc(MatrixRecipeCase.Record, 1);
    items[0] = try MatrixRecipeCase.record();
    var reader = MatrixRecipeCase.reader(items);
    reader.device.name = try source.dupe(u8, reader.device.name);
    reader.device.driver_version = try source.dupe(u8, reader.device.driver_version.?);
    const bytes = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(reader));
    @memset(@constCast(reader.device.name), 'x');
    @memset(@constCast(reader.device.driver_version.?), 'y');
    items[0].key.k = 0;
    items[0].selection.threads = .{ .x = 99, .y = 99 };
    return bytes;
}

test "Accy publication matrix product schedule recipes own device facts hits and misses" {
    const allocator = std.testing.allocator;
    const bytes = try independentMatrixRecipe();
    defer allocator.free(bytes);
    var decoded = try records.codec.decode(
        allocator,
        preparation.recipe.Record(.tensor),
        .tensor,
        bytes,
    );
    defer decoded.deinit();
    const reader = decoded.value.options.einsum.matrix_product_tuning.?;
    try std.testing.expectEqualStrings(MatrixRecipeCase.device.name, reader.device.name);
    try std.testing.expectEqualStrings(
        MatrixRecipeCase.device.driver_version.?,
        reader.device.driver_version.?,
    );
    const instance = TuningRecipeCase.matrix();
    try std.testing.expectEqual(instance.threads, (try reader.resolve(instance)).?);
    for (0..5) |index| {
        var absent = instance;
        switch (index) {
            0 => absent.m += 1,
            1 => absent.n += 1,
            2 => absent.k += 1,
            3 => absent.dtype = .f16,
            else => absent.accumulation_dtype = .f16,
        }
        try std.testing.expectEqual(null, try reader.resolve(absent));
    }
    for (0..8) |index| {
        var absent = reader;
        switch (index) {
            0 => absent.device.backend = .vulkan,
            1 => absent.device.family = .external,
            2 => absent.device.name = "another device",
            3 => absent.device.vendor_id = null,
            4 => absent.device.device_id = null,
            5 => absent.device.driver_version = null,
            6 => absent.device.driver_version = "another driver",
            else => absent.format = .vulkan_spirv,
        }
        try std.testing.expectEqual(null, try absent.resolve(instance));
    }
}

test "Accy publication matrix product schedule recipes compare relocated reader values" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const items = [_]MatrixRecipeCase.Record{try MatrixRecipeCase.record()};
    const reader = MatrixRecipeCase.reader(&items);
    const original = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(reader));
    defer allocator.free(original);
    const relocated = try allocator.dupe(MatrixRecipeCase.Record, &items);
    defer allocator.free(relocated);
    var other = reader;
    other.records = relocated;
    other.device.name = try allocator.dupe(u8, reader.device.name);
    defer allocator.free(other.device.name);
    other.device.driver_version = try allocator.dupe(u8, reader.device.driver_version.?);
    defer allocator.free(other.device.driver_version.?);
    const copied = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(other));
    defer allocator.free(copied);
    try std.testing.expectEqualStrings(original, copied);
    try std.testing.expect(reader.eql(other));
    for (0..6) |index| {
        var changed = reader;
        var entry_ = items;
        changed.records = &entry_;
        switch (index) {
            0 => changed.device.driver_version = "another driver",
            1 => changed.device.name = "another device",
            2 => changed.format = .vulkan_spirv,
            3 => entry_[0].key.k += 1,
            4 => entry_[0].selection.threads.x += 1,
            else => entry_[0].selection.sample_count += 1,
        }
        const bytes = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(changed));
        defer allocator.free(bytes);
        try std.testing.expect(!std.mem.eql(u8, original, bytes));
        try std.testing.expect(!reader.eql(changed));
    }
}

test "Accy publication matrix product schedule recipes preserve presence and record order" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const empty = MatrixRecipeCase.reader(&.{});
    const absent = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(null));
    defer allocator.free(absent);
    const present = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(empty));
    defer allocator.free(present);
    try std.testing.expect(!std.mem.eql(u8, absent, present));
    const item = try MatrixRecipeCase.record();
    var items = [_]MatrixRecipeCase.Record{ item, item };
    items[1].selection.threads = .{ .x = 99, .y = 99 };
    const reader = MatrixRecipeCase.reader(&items);
    const first = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(reader));
    defer allocator.free(first);
    std.mem.swap(MatrixRecipeCase.Record, &items[0], &items[1]);
    const second = try recipeBytes(&fixture, .tensor, MatrixRecipeCase.options(reader));
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    for ([_][]const u8{ first, second }, 0..) |bytes, index| {
        var decoded = try records.codec.decode(
            allocator,
            preparation.recipe.Record(.tensor),
            .tensor,
            bytes,
        );
        defer decoded.deinit();
        const restored = decoded.value.options.einsum.matrix_product_tuning.?;
        if (index == 0) {
            try std.testing.expectEqual(
                TuningRecipeCase.matrix().threads,
                (try restored.resolve(TuningRecipeCase.matrix())).?,
            );
        } else {
            try std.testing.expectError(
                error.InvalidArtifact,
                restored.resolve(TuningRecipeCase.matrix()),
            );
        }
    }
}

fn matrixRecipeFailure(
    allocator: std.mem.Allocator,
    fixture: *Fixture,
    reader: MatrixRecipeCase.Reader,
) !void {
    const bytes = try preparation.recipe.encode(
        allocator,
        .tensor,
        fixture.source.choir_module,
        MatrixRecipeCase.options(reader),
    );
    defer allocator.free(bytes);
    var decoded = try records.codec.decode(
        allocator,
        preparation.recipe.Record(.tensor),
        .tensor,
        bytes,
    );
    defer decoded.deinit();
    const reader_ = decoded.value.options.einsum.matrix_product_tuning.?;
    try std.testing.expectEqual(
        TuningRecipeCase.matrix().threads,
        (try reader_.resolve(TuningRecipeCase.matrix())).?,
    );
}

test "Accy publication matrix product schedule recipes clean partial capture allocations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const items = [_]MatrixRecipeCase.Record{try MatrixRecipeCase.record()};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, matrixRecipeFailure, .{
        &fixture, MatrixRecipeCase.reader(&items),
    });
}

const StageObservation = struct {
    outcome: revision.receipt.Outcome,
    charged: revision.WorkVector,
    counters: revision.receipt.Counters,
    maximum_live_storage: u64,
    exceeded: ?revision.WorkVector.Component,

    fn from(receipt: revision.WorkReceiptV1) StageObservation {
        return .{
            .outcome = receipt.outcome,
            .charged = receipt.charged,
            .counters = receipt.executed.counters,
            .maximum_live_storage = receipt.maximum_live_storage,
            .exceeded = receipt.exceeded,
        };
    }
};

fn stageMatrixRequest(comptime stage: publication.Stage) StageRequest {
    if (stage == .kernel or stage == .contract) return .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = 512 * 1024 * 1024,
    };
    return if (stage == .target) .{
        .allowance = revision.WorkVector.uniform(64 * 1024 * 1024 * 1024),
        .workspace = 256 * 1024 * 1024,
    } else .{};
}

fn publishStage(
    chain: *Chain,
    root: *choir.ir.Operation,
    comptime stage: publication.Stage,
) !operation.Product {
    const builder = try stageBuilder(chain, root, stage, .{}, stageMatrixRequest(stage));
    errdefer abortStage(builder);
    try preparation.publication.capture(
        std.testing.allocator,
        builder,
        chain.products[@backingInt(stage) - 1],
        stage,
        .{},
        configuration,
    );
    return operation.Product.seal(builder, chain.kinds[@backingInt(stage)]);
}

fn failedStage(
    store: *revision.Store,
    builder: *revision.Builder,
    err: anyerror,
) !StageObservation {
    var failure = builder.abort(.rejected) orelse return error.MissingFailureReceipt;
    defer failure.deinit();
    if (err != error.WorkExhausted and err != error.UnexpectedImage) return err;
    try std.testing.expectEqual(@as(u32, 0), store.publicationCount());
    const expected: revision.receipt.Outcome = if (err == error.WorkExhausted)
        .exhausted
    else
        .rejected;
    try std.testing.expectEqual(expected, failure.work.outcome);
    return StageObservation.from(failure.work);
}

const StageRoute = enum { cold, warm, restored, restored_changed };

fn screenStage(
    builder: *revision.Builder,
    candidate: operation.Product,
    changed: bool,
) !void {
    const record = candidate.revision.view().semantic_record;
    if (!changed) return std.testing.expect(try builder.screenRestored(record, try choir.product.compiler.manifest()));
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, record);
    defer allocator.free(bytes);
    const exact = try revision.record.decodeExact(bytes);
    try std.testing.expect(exact.image.len > 0);
    @constCast(exact.image)[exact.image.len - 1] ^= 1;
    try std.testing.expect(try builder.screenRestored(bytes, try choir.product.compiler.manifest()));
    @memset(bytes, 0xa5);
}

fn stageAttempt(
    root: *choir.ir.Operation,
    parent: operation.Product,
    comptime stage: publication.Stage,
    request: StageRequest,
    route: StageRoute,
    candidate: operation.Product,
) !StageObservation {
    const source = try StageSource.create(parent, stage, request.gate_scratch_bytes);
    defer source.store.release();
    const builder = try source.begin(root, stage, .{}, request);
    var open = true;
    defer if (open) abortStage(builder);
    if (route == .warm) {
        const admitted = builder.admitReuse(candidate.revision) catch |err| {
            open = false;
            return failedStage(source.store, builder, err);
        };
        if (admitted) |value| {
            var reused = value;
            open = false;
            defer reused.deinit();
            try std.testing.expect(candidate.revision.eql(reused.revision));
            try std.testing.expectEqual(@as(u32, 0), source.store.publicationCount());
            return StageObservation.from(reused.work);
        }
    }
    if (route == .restored or route == .restored_changed) {
        try screenStage(builder, candidate, route == .restored_changed);
    }
    preparation.publication.capture(
        std.testing.allocator,
        builder,
        parent,
        stage,
        .{},
        configuration,
    ) catch |err| {
        open = false;
        return failedStage(source.store, builder, err);
    };
    const product = operation.Product.seal(builder, source.kind) catch |err| {
        open = false;
        return failedStage(source.store, builder, err);
    };
    open = false;
    defer product.release();
    try std.testing.expectEqualSlices(
        u8,
        candidate.revision.view().semantic_record,
        product.revision.view().semantic_record,
    );
    return StageObservation.from(product.revision.view().work);
}

fn checkChangedStage(
    root: *choir.ir.Operation,
    parent: operation.Product,
    comptime stage: publication.Stage,
    candidate: operation.Product,
) !void {
    const changed = try stageAttempt(
        root,
        parent,
        stage,
        stageMatrixRequest(stage),
        .restored_changed,
        candidate,
    );
    try std.testing.expectEqual(.rejected, changed.outcome);
    try std.testing.expectEqual(
        preparation.recipe.pipeline(stage).len,
        changed.counters.pass_runs,
    );
}

fn checkStageMatrix(comptime stage: publication.Stage) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    const root = fixture.source.choir_module;
    var chain = try Chain.init(root, captured);
    defer chain.deinit();
    const baseline = try publishStage(&chain, root, stage);
    defer baseline.release();
    const receipt = baseline.revision.view().work;
    const parent = chain.products[@backingInt(stage) - 1];
    try std.testing.expectEqual(.success, receipt.outcome);
    try std.testing.expect(!receipt.missing_work_contract);
    try std.testing.expectEqual(
        preparation.recipe.pipeline(stage).len,
        receipt.executed.counters.pass_runs,
    );
    try checkChangedStage(root, parent, stage, baseline);
    inline for (@typeInfo(revision.WorkVector).@"struct".field_names) |field| {
        const value = @field(receipt.charged, field);
        for ([_]i64{ -1, 0, 1 }) |offset| {
            if (value == 0 and offset < 0) continue;
            var request = stageMatrixRequest(stage);
            request.allowance = receipt.charged;
            @field(request.allowance, field) = @intCast(@as(i64, @intCast(value)) + offset);
            const cold = try stageAttempt(root, parent, stage, request, .cold, baseline);
            const warm = try stageAttempt(root, parent, stage, request, .warm, baseline);
            const restored = try stageAttempt(root, parent, stage, request, .restored, baseline);
            const expected: revision.receipt.Outcome = if (offset < 0) .exhausted else .success;
            try std.testing.expectEqual(expected, cold.outcome);
            try std.testing.expectEqual(cold.outcome, warm.outcome);
            try std.testing.expectEqualDeep(cold, restored);
            try std.testing.expectEqualDeep(cold.charged, warm.charged);
            try std.testing.expectEqual(cold.exceeded, warm.exceeded);
            try std.testing.expectEqual(cold.maximum_live_storage, warm.maximum_live_storage);
            try std.testing.expectEqual(@as(u64, 0), warm.counters.pass_runs);
        }
    }
}

test "Accy publication Tensor cold warm and restored share every work boundary" {
    try checkStageMatrix(.tensor);
}

test "Accy publication Dispatch cold warm and restored share every work boundary" {
    try checkStageMatrix(.dispatch);
}

test "Accy publication Memory cold warm and restored share every work boundary" {
    try checkStageMatrix(.memory);
}

test "Accy publication Target cold warm and restored share every work boundary" {
    try checkStageMatrix(.target);
}

test "Accy publication Kernel cold warm and restored share every work boundary" {
    try checkStageMatrix(.kernel);
}

fn checkWorkspaceRequest(
    root: *choir.ir.Operation,
    parent: operation.Product,
    comptime stage: publication.Stage,
    request: StageRequest,
    candidate: operation.Product,
) !void {
    const measured = try stageAttempt(root, parent, stage, request, .cold, candidate);
    try std.testing.expectEqual(.success, measured.outcome);
    for ([_]i64{ -1, 0, 1 }) |offset| {
        var exact = request;
        exact.allowance = measured.charged;
        const capacity: i64 = @intCast(measured.charged.allocation_capacity);
        exact.allowance.allocation_capacity = @intCast(capacity + offset);
        const cold = try stageAttempt(root, parent, stage, exact, .cold, candidate);
        const warm = try stageAttempt(root, parent, stage, exact, .warm, candidate);
        const restored = try stageAttempt(root, parent, stage, exact, .restored, candidate);
        const expected: revision.receipt.Outcome = if (offset < 0) .exhausted else .success;
        try std.testing.expectEqual(expected, cold.outcome);
        try std.testing.expectEqualDeep(cold, restored);
        try std.testing.expectEqual(cold.outcome, warm.outcome);
        try std.testing.expectEqualDeep(cold.charged, warm.charged);
        try std.testing.expectEqual(cold.exceeded, warm.exceeded);
        try std.testing.expectEqual(cold.maximum_live_storage, warm.maximum_live_storage);
    }
}

fn checkStageWorkspace(comptime stage: publication.Stage) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    const root = fixture.source.choir_module;
    var chain = try Chain.init(root, captured);
    defer chain.deinit();
    const baseline = try publishStage(&chain, root, stage);
    defer baseline.release();
    const parent = chain.products[@backingInt(stage) - 1];
    for ([_]i64{ -1, 1 }) |offset| {
        var request = stageMatrixRequest(stage);
        request.workspace = @intCast(@as(i64, @intCast(request.workspace)) + offset);
        try checkWorkspaceRequest(root, parent, stage, request, baseline);
    }
    var partition = stageMatrixRequest(stage);
    partition.gate_scratch_bytes += 1;
    try checkWorkspaceRequest(root, parent, stage, partition, baseline);
}

test "Accy publication workspace changes preserve Tensor budget outcomes" {
    try checkStageWorkspace(.tensor);
}

test "Accy publication workspace changes preserve Dispatch budget outcomes" {
    try checkStageWorkspace(.dispatch);
}

test "Accy publication workspace changes preserve Memory budget outcomes" {
    try checkStageWorkspace(.memory);
}

test "Accy publication workspace changes preserve Target budget outcomes" {
    try checkStageWorkspace(.target);
}

test "Accy publication workspace changes preserve Kernel budget outcomes" {
    try checkStageWorkspace(.kernel);
}

test "Accy publication Contract cold warm and restored share every work boundary" {
    try checkStageMatrix(.contract);
}

test "Accy publication Contract workspace changes preserve budget outcomes" {
    try checkStageWorkspace(.contract);
}

test "Accy publication Contract through Target consumes each newly sealed predecessor" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const root = fixture.source.choir_module;
    const store = try revision.Store.create(allocator, .{
        .revisions = 7,
        .kinds = 7,
        .builders = 1,
        .compiler_manifests = 2,
        .record_bytes = 32 * 1024 * 1024,
        .gate_scratch_bytes = configuration.gate_scratch,
        .candidate_count = 8,
        .screening_bytes = 32 * 1024 * 1024,
    });
    defer store.release();
    const stages = [_]publication.Stage{
        .semantic, .contract, .tensor, .dispatch, .memory, .kernel, .target,
    };
    var kinds: [stages.len]*const revision.Kind = undefined;
    inline for (stages, 0..) |stage, index| {
        kinds[index] = try preparation.publication.registerKind(allocator, store, stage, configuration);
    }
    store.freeze();
    var product = try seal(store, kinds[0], root, .semantic, &publication.irRecord(.semantic), null);
    defer product.release();
    var revisions: [7]*const revision.Revision = undefined;
    revisions[0] = product.revision;
    inline for (stages[1..], 1..) |stage, index| {
        const source = StageSource{ .store = store, .kind = kinds[index], .parent = product };
        const builder = try source.begin(root, stage, .{}, stageMatrixRequest(stage));
        errdefer abortStage(builder);
        try preparation.publication.capture(allocator, builder, product, stage, .{}, configuration);
        const next = try operation.Product.seal(builder, kinds[index]);
        product.release();
        product = next;
        revisions[index] = next.revision;
        const receipt = product.revision.view().work;
        try std.testing.expectEqual(.success, receipt.outcome);
        try std.testing.expect(!receipt.missing_work_contract);
        try std.testing.expectEqual(preparation.recipe.pipeline(stage).len, receipt.executed.counters.pass_runs);
    }
    try std.testing.expectEqual(7, store.publicationCount());
    const prepared = try preparation.pipeline.BackendPreparedModule.create(allocator, revisions);
    defer prepared.deinit();
    try std.testing.expect(prepared.stage(.target).eql(product.revision));
    var graph = try prepared.productGraph(allocator);
    defer graph.deinit(allocator);
    try std.testing.expectEqual(7, graph.products.len);
    const module = try publication.Module(.target).fromRevision(allocator, product.revision);
    defer module.deinit();
    var plan = try module.plan(allocator, configuration.image);
    defer plan.deinit();
    try std.testing.expectEqual(1, plan.value.kernels.len);
}

test "Accy retained preparation owns exact metadata after its source chain is released" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    var live = true;
    defer if (live) chain.deinit();
    var graph = try retainedPreparationGraph(&chain);
    defer graph.deinit(allocator);
    chain.deinit();
    live = false;
    try std.testing.expectEqual(7, graph.products.len);
    for (graph.products) |key| {
        const exact = try revision.record.decodeExact(key.record.bytes());
        try std.testing.expect(exact.image.len > 0);
        try std.testing.expect(key.ref.eql(try revision.record.decodeAddress(exact.address)));
    }
}

fn preparationRevisions(chain: *const Chain) [7]*const revision.Revision {
    var result: [7]*const revision.Revision = undefined;
    for (chain.products, &result) |product, *item| item.* = product.revision;
    return result;
}

fn retainedPreparationGraph(chain: *const Chain) !choir.product.incremental.ProductGraph {
    const allocator = std.testing.allocator;
    const Module = preparation.pipeline.BackendPreparedModule;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Module.create(failing.allocator(), preparationRevisions(chain)));
    const prepared = try Module.create(allocator, preparationRevisions(chain));
    defer prepared.deinit();
    const retained = try prepared.retain(allocator);
    defer retained.deinit();
    return retained.productGraph(allocator);
}

test "Accy retained preparation rejects a mixed exact predecessor and wrong stage" {
    const allocator = std.testing.allocator;
    const Module = preparation.pipeline.BackendPreparedModule;
    var first = try Fixture.init();
    defer first.deinit();
    var second = try Fixture.initNames(&.{"different_source"});
    defer second.deinit();
    var first_capture = try captureFixture(&first);
    defer first_capture.deinit();
    var second_capture = try captureFixture(&second);
    defer second_capture.deinit();
    var first_chain = try Chain.init(first.source.choir_module, first_capture);
    defer first_chain.deinit();
    var second_chain = try Chain.init(second.source.choir_module, second_capture);
    defer second_chain.deinit();
    var items = preparationRevisions(&first_chain);
    items[6] = second_chain.products[6].revision;
    try std.testing.expect(items[6].address().eql(first_chain.products[6].revision.address()));
    if (Module.create(allocator, items)) |unexpected| {
        unexpected.deinit();
        return error.TestExpectedError;
    } else |err| try std.testing.expect(err == error.UnboundProductInput);
    items[6] = first_chain.products[5].revision;
    try std.testing.expectError(error.WrongStage, Module.create(allocator, items));
}

fn preparationRequest() preparation.publication.PreparationRequest {
    return .{
        .source = "preparation-publication",
        .work = .{
            .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
            .workspace = 512 * 1024 * 1024,
            .events = 256,
        },
        .record_bytes = 32 * 1024 * 1024,
    };
}

fn prepareAndRelease(
    source: *semantic.SemanticModule,
    request: preparation.publication.PreparationRequest,
    report: *preparation.publication.PreparationReport,
) !void {
    const prepared = try preparation.publication.prepare(
        std.testing.allocator,
        .{ .draft = source },
        request,
        report,
        configuration,
    );
    prepared.deinit();
}

test "Accy preparation publication replays exact stages with current request receipts" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var cold = preparation.publication.PreparationReport{};
    defer cold.deinit();
    var request = preparationRequest();
    request.options = .{
        .target_profile = .{ .backend_kind = .cpu, .artifact_format = .cpu_object },
        .generated_scan_schedules = &.{.{ .schedule = .{ .threads = 32, .items = 2 } }},
        .generated_row_pipeline_schedules = &.{.{ .schedule = .{ .threads = 64 } }},
    };
    const first = try preparation.publication.prepare(
        allocator,
        .{ .draft = fixture.source },
        request,
        &cold,
        configuration,
    );
    defer first.deinit();
    try std.testing.expectEqual(7, cold.completed);
    request.candidate = first;
    request.work.allowance = try cold.charged();
    var warm = preparation.publication.PreparationReport{};
    defer warm.deinit();
    const second = try preparation.publication.prepare(
        allocator,
        .{ .draft = fixture.source },
        request,
        &warm,
        configuration,
    );
    defer second.deinit();
    try std.testing.expectEqualDeep(try cold.charged(), try warm.charged());
    inline for (std.enums.values(publication.Stage), 0..) |stage, index| {
        try std.testing.expect(first.stage(stage).eql(second.stage(stage)));
        const work = warm.stages[index].work();
        try std.testing.expectEqual(.success, work.outcome);
        try std.testing.expectEqualDeep(cold.stages[index].work().charged, work.charged);
        if (stage == .semantic) {
            try std.testing.expect(warm.stages[index] == .cold);
        } else {
            try std.testing.expect(warm.stages[index] == .warm);
            try std.testing.expectEqual(0, work.executed.counters.pass_runs);
        }
    }
    try std.testing.expectEqual(null, preparation.readBackendTargetProfile(
        fixture.source.choir_module,
    ));
}

test "Accy preparation publication carries one allowance through cold and warm stages" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var cold = preparation.publication.PreparationReport{};
    defer cold.deinit();
    var request = preparationRequest();
    const prepared = try preparation.publication.prepare(
        allocator,
        .{ .draft = fixture.source },
        request,
        &cold,
        configuration,
    );
    defer prepared.deinit();
    const charged = try cold.charged();
    inline for (@typeInfo(revision.WorkVector).@"struct".field_names) |field| {
        try std.testing.expect(@field(charged, field) > 0);
        for ([_]bool{ false, true }) |warm| {
            request.candidate = if (warm) prepared else null;
            request.work.allowance = charged;
            @field(request.work.allowance, field) -= 1;
            var failed = preparation.publication.PreparationReport{};
            defer failed.deinit();
            try std.testing.expectError(error.WorkExhausted, prepareAndRelease(
                fixture.source,
                request,
                &failed,
            ));
            try std.testing.expect(failed.completed < 7);
            if (failed.failure) |failure| {
                try std.testing.expectEqual(.exhausted, failure.work.outcome);
            }
            try std.testing.expectEqual(.success, prepared.stage(.target).view().work.outcome);
        }
    }
    inline for (@typeInfo(revision.WorkVector).@"struct".field_names) |field| {
        @field(request.work.allowance, field) = @field(charged, field) + 1;
    }
    for ([_]bool{ false, true }) |warm| {
        request.candidate = if (warm) prepared else null;
        var accepted = preparation.publication.PreparationReport{};
        defer accepted.deinit();
        try prepareAndRelease(fixture.source, request, &accepted);
        try std.testing.expectEqualDeep(charged, try accepted.charged());
    }
}

test "Accy preparation publication replaces a changed exact source without altering its candidate" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var cold = preparation.publication.PreparationReport{};
    defer cold.deinit();
    var request = preparationRequest();
    const first = try preparation.publication.prepare(
        allocator,
        .{ .draft = fixture.source },
        request,
        &cold,
        configuration,
    );
    defer first.deinit();
    const old_image = try allocator.dupe(u8, first.stage(.semantic).view().exact.image);
    defer allocator.free(old_image);
    try fixture.source.choir_module.setAttr(
        "source_revision",
        try fixture.source.ctx.getStringAttr("next"),
    );
    var next = preparation.publication.PreparationReport{};
    defer next.deinit();
    request.candidate = first;
    const second = try preparation.publication.prepare(
        allocator,
        .{ .draft = fixture.source },
        request,
        &next,
        configuration,
    );
    defer second.deinit();
    try std.testing.expect(!first.stage(.semantic).eql(second.stage(.semantic)));
    for (next.stages[0..next.completed]) |item| try std.testing.expect(item == .cold);
    try std.testing.expectEqualSlices(u8, old_image, first.stage(.semantic).view().exact.image);
}

test "Accy preparation publication cache owns updates across replacement and failure" {
    const allocator = std.testing.allocator;
    var cache = preparation.BackendPreparationCache.init(allocator);
    defer cache.deinit();
    var first_report = preparation.publication.PreparationReport{};
    defer first_report.deinit();
    var first = try cachePreparationFixture(&cache, &first_report, preparationRequest());
    defer first.deinit(allocator);
    try std.testing.expect(!first.reused);
    try std.testing.expect(first.request_changed);
    var warm_report = preparation.publication.PreparationReport{};
    defer warm_report.deinit();
    var warm = try cachePreparationFixture(&cache, &warm_report, preparationRequest());
    defer warm.deinit(allocator);
    try std.testing.expect(warm.reused);
    try std.testing.expect(!warm.request_changed);
    try std.testing.expectEqualDeep(try first_report.charged(), try warm_report.charged());
    var failed_report = preparation.publication.PreparationReport{};
    defer failed_report.deinit();
    var limited = preparationRequest();
    limited.work.allowance.rewrite_attempts = 0;
    try std.testing.expectError(error.WorkExhausted, cachePreparationFixture(
        &cache,
        &failed_report,
        limited,
    ));
    const current = cache.currentPrepared().?;
    try std.testing.expect(current.stage(.target).eql(warm.prepared.stage(.target)));
    var replacement_report = preparation.publication.PreparationReport{};
    defer replacement_report.deinit();
    var changed = preparationRequest();
    changed.variant = "another-target";
    var replacement = try cachePreparationFixture(&cache, &replacement_report, changed);
    defer replacement.deinit(allocator);
    try std.testing.expect(replacement.request_changed);
    try std.testing.expect(!replacement.reused);
    try std.testing.expect(first.prepared.stage(.target).eql(warm.prepared.stage(.target)));
    try std.testing.expect(!first.prepared.stage(.target).eql(replacement.prepared.stage(.target)));
    try std.testing.expectEqualStrings("", first.prepared.stage(.target).address().variant);
}

fn cachePreparationFixture(
    cache: *preparation.BackendPreparationCache,
    report: *preparation.publication.PreparationReport,
    request: preparation.publication.PreparationRequest,
) !preparation.BackendPreparationCacheUpdate {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    var fixture = try Fixture.init();
    fixture.cache.deinit();
    return cache.refreshFromSemanticModule(fixture.source, request, report, configuration);
}

fn captureTargetRecipe(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    const bytes = try preparation.recipe.encode(allocator, .target, fixture.source.choir_module, .{
        .target_profile = .{ .backend_kind = .cpu, .artifact_format = .cpu_object },
        .generated_scan_schedules = &.{.{ .schedule = .{ .threads = 32, .items = 2 } }},
        .generated_row_pipeline_schedules = &.{.{ .schedule = .{ .threads = 64 } }},
    });
    allocator.free(bytes);
}

test "Accy publication recipes release partial target override encoding allocations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        captureTargetRecipe,
        .{&fixture},
    );
    try std.testing.expectEqual(null, preparation.readBackendTargetProfile(
        fixture.source.choir_module,
    ));
}

test "Accy preparation publication cache rolls back its last replacement allocation and retries" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    var cache = preparation.BackendPreparationCache.init(failing.allocator());
    defer cache.deinit();
    var initial_report = preparation.publication.PreparationReport{};
    defer initial_report.deinit();
    var initial = try cachePreparationFixture(&cache, &initial_report, preparationRequest());
    defer initial.deinit(failing.allocator());
    var warm_report = preparation.publication.PreparationReport{};
    defer warm_report.deinit();
    const start = failing.alloc_index;
    var warm = try cachePreparationFixture(&cache, &warm_report, preparationRequest());
    defer warm.deinit(failing.allocator());
    const allocations = failing.alloc_index - start;
    try std.testing.expect(allocations > 0);
    const previous = cache.currentPrepared().?;
    var failed_report = preparation.publication.PreparationReport{};
    defer failed_report.deinit();
    failing.fail_index = failing.alloc_index + allocations - 1;
    if (cachePreparationFixture(
        &cache,
        &failed_report,
        preparationRequest(),
    )) |value| {
        var unexpected = value;
        unexpected.deinit(failing.allocator());
        return error.ExpectedAllocationFailure;
    } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(7, failed_report.completed);
    try std.testing.expectEqual(previous, cache.currentPrepared().?);
    failing.fail_index = std.math.maxInt(usize);
    var retry_report = preparation.publication.PreparationReport{};
    defer retry_report.deinit();
    var retry = try cachePreparationFixture(&cache, &retry_report, preparationRequest());
    defer retry.deinit(failing.allocator());
    try std.testing.expect(retry.reused);
    try std.testing.expect(retry.prepared.stage(.target).eql(warm.prepared.stage(.target)));
}

test "Accy preparation retained Semantic source replays every stage under the same allowance" {
    const allocator = std.testing.allocator;
    var cache = preparation.BackendPreparationCache.init(allocator);
    defer cache.deinit();
    var cold = preparation.publication.PreparationReport{};
    defer cold.deinit();
    var first = try cachePreparationFixture(&cache, &cold, preparationRequest());
    defer first.deinit(allocator);
    const source = first.prepared.stage(.semantic);
    var request = preparationRequest();
    request.work.allowance = try cold.charged();
    var warm = preparation.publication.PreparationReport{};
    defer warm.deinit();
    var second = try cache.refreshFromSemanticRevision(source, request, &warm, configuration);
    defer second.deinit(allocator);
    try std.testing.expect(second.reused);
    try std.testing.expect(!second.request_changed);
    try std.testing.expectEqualDeep(try cold.charged(), try warm.charged());
    for (warm.stages[0..warm.completed]) |stage| {
        try std.testing.expect(stage == .warm);
        try std.testing.expectEqual(0, stage.work().executed.counters.pass_runs);
    }
    var failed = preparation.publication.PreparationReport{};
    defer failed.deinit();
    request.work.allowance.rewrite_attempts -= 1;
    try std.testing.expectError(error.WorkExhausted, cache.refreshFromSemanticRevision(
        source,
        request,
        &failed,
        configuration,
    ));
    const current = cache.currentPrepared().?;
    try std.testing.expect(current.stage(.target).eql(first.prepared.stage(.target)));
}

test "Accy preparation retained source restores original target inheritance after an override" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    fixture.cache.deinit();
    var source_owned = true;
    defer if (source_owned) fixture.source.deinit();
    try preparation.recipe.applyTargetOptions(allocator, fixture.source.choir_module, .{
        .target_profile = .{ .backend_kind = .cpu, .artifact_format = .cpu_object },
        .generated_scan_schedules = &.{.{ .schedule = .{ .threads = 32, .items = 2 } }},
    });
    var cache = preparation.BackendPreparationCache.init(allocator);
    defer cache.deinit();
    var first_report = preparation.publication.PreparationReport{};
    defer first_report.deinit();
    var request = preparationRequest();
    request.options = .{
        .target_profile = .{ .backend_kind = .cuda, .artifact_format = .cuda_ptx },
        .generated_scan_schedules = &.{.{ .schedule = .{ .threads = 64, .items = 4 } }},
    };
    source_owned = false;
    var first = try cache.refreshFromSemanticModule(
        fixture.source,
        request,
        &first_report,
        configuration,
    );
    defer first.deinit(allocator);
    try expectPreparationTarget(first.prepared, .cuda, "64x4");
    var next_report = preparation.publication.PreparationReport{};
    defer next_report.deinit();
    request.options = .{};
    var next = try cache.refreshFromSemanticRevision(
        first.prepared.stage(.semantic),
        request,
        &next_report,
        configuration,
    );
    defer next.deinit(allocator);
    try std.testing.expect(!next.reused);
    try std.testing.expect(next.request_changed);
    for (next_report.stages[0..5]) |stage| try std.testing.expect(stage == .warm);
    for (next_report.stages[5..7]) |stage| try std.testing.expect(stage == .cold);
    try expectPreparationTarget(next.prepared, .cpu, "32x2");
    try expectPreparationTarget(first.prepared, .cuda, "64x4");
}

fn expectPreparationTarget(
    prepared: *const preparation.pipeline.BackendPreparedModule,
    kind: gpu.BackendKind,
    scans: []const u8,
) !void {
    const product = operation.Product{ .revision = prepared.stage(.target) };
    const image = try product.open(std.testing.allocator, configuration.image);
    defer image.destroy();
    var decoded = try records.codec.decode(
        std.testing.allocator,
        records.target.Record,
        .target,
        image.stage(),
    );
    defer decoded.deinit();
    try std.testing.expectEqual(kind, decoded.value.profile.?.backend_kind);
    try std.testing.expectEqualStrings(scans, decoded.value.generated_scan_schedules.?);
}

test "Accy preparation retained input outlives its cache and recomputes uncached stages" {
    const allocator = std.testing.allocator;
    var cache = preparation.BackendPreparationCache.init(allocator);
    var cache_live = true;
    defer if (cache_live) cache.deinit();
    var first_report = preparation.publication.PreparationReport{};
    defer first_report.deinit();
    var request = preparationRequest();
    request.options = .{
        .target_profile = .{ .backend_kind = .cpu, .artifact_format = .cpu_object },
        .generated_scan_schedules = &.{.{ .schedule = .{ .threads = 32, .items = 2 } }},
    };
    var first = try cachePreparationFixture(&cache, &first_report, request);
    var first_live = true;
    defer if (first_live) first.deinit(allocator);
    const source = try first_report.source.?.retain(allocator);
    defer source.deinit();
    request.work.allowance = try first_report.charged();
    first.deinit(allocator);
    first_live = false;
    first_report.deinit();
    cache.deinit();
    cache_live = false;
    var next_report = preparation.publication.PreparationReport{};
    defer next_report.deinit();
    const next = try preparation.publication.prepare(
        allocator,
        .{ .retained = source },
        request,
        &next_report,
        configuration,
    );
    defer next.deinit();
    try std.testing.expect(next_report.stages[0] == .warm);
    for (next_report.stages[1..7]) |stage| {
        try std.testing.expect(stage == .cold);
        try std.testing.expect(stage.work().executed.counters.pass_runs > 0);
    }
    try std.testing.expectEqualDeep(request.work.allowance, try next_report.charged());
    try expectPreparationTarget(next, .cpu, "32x2");
}

test "Accy preparation retained cache rejects a different exact Semantic at the same address" {
    const allocator = std.testing.allocator;
    var cache = preparation.BackendPreparationCache.init(allocator);
    defer cache.deinit();
    var first_report = preparation.publication.PreparationReport{};
    defer first_report.deinit();
    var first = try cachePreparationFixture(&cache, &first_report, preparationRequest());
    defer first.deinit(allocator);
    var fixture = try Fixture.initNames(&.{"another_semantic"});
    defer fixture.deinit();
    var other_report = preparation.publication.PreparationReport{};
    defer other_report.deinit();
    const other = try preparation.publication.prepare(
        allocator,
        .{ .draft = fixture.source },
        preparationRequest(),
        &other_report,
        configuration,
    );
    defer other.deinit();
    const source = other.stage(.semantic);
    try std.testing.expect(source.address().eql(first.prepared.stage(.semantic).address()));
    try std.testing.expect(!source.eql(first.prepared.stage(.semantic)));
    var rejected = preparation.publication.PreparationReport{};
    defer rejected.deinit();
    try std.testing.expectError(error.SemanticModuleRequired, retainedRefreshAndRelease(
        &cache,
        source,
        preparationRequest(),
        &rejected,
    ));
    try std.testing.expectEqual(0, rejected.completed);
    const current = cache.currentPrepared().?;
    try std.testing.expect(current.stage(.semantic).eql(first.prepared.stage(.semantic)));
}

fn retainedRefreshAndRelease(
    cache: *preparation.BackendPreparationCache,
    source: *const revision.Revision,
    request: preparation.publication.PreparationRequest,
    report: *preparation.publication.PreparationReport,
) !void {
    var update = try cache.refreshFromSemanticRevision(source, request, report, configuration);
    update.deinit(std.testing.allocator);
}

fn savedArtifactPreparation(profile: preparation.BackendTargetProfile) !*preparation.pipeline.BackendPreparedModule {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try preparation.setBackendTargetProfile(fixture.source.context(), fixture.source.choir_module, profile);
    try markSavedProgram(&fixture);
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    return preparation.pipeline.BackendPreparedModule.create(allocator, preparationRevisions(&chain));
}

test "Accy retained artifact job restores captured plans and marked programs without sources" {
    const allocator = std.testing.allocator;
    const artifact = @import("../artifact/root.zig");
    const prepared = try savedArtifactPreparation(.{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var retained = true;
    defer if (retained) prepared.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    try std.testing.expectError(error.WorkExhausted, artifact.InputJob.create(&.{}, prepared, configuration));
    const job = try artifact.InputJob.create(workspace, prepared, configuration);
    defer job.destroy();
    prepared.deinit();
    retained = false;
    const plans = job.plans();
    try std.testing.expectEqual(1, plans.outlines.kernelCount());
    try std.testing.expectEqual(1, plans.generated.kernels.items.len);
    const work = plans.schedule.work_items.items[0];
    try std.testing.expect(plans.schedule.getWorkForRoot(work.root).? == &plans.schedule.work_items.items[0]);
    try std.testing.expect(plans.buffers.getSlot(work.output_value) != null);
    for (plans.buffers.slots.items) |slot| {
        try std.testing.expect(plans.spaces.getAssignmentForSlot(slot.id) != null);
        try std.testing.expect(plans.layouts.getAssignmentForSlot(slot.id) != null);
    }
    const generated = &plans.generated.kernels.items[0];
    const marker = generated.program.storage.kernel.func().op.getAttrAs(choir.ir.Attribute.StringAttr, "restoration_marker") orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings("retain this exact program", marker.getValue());
    var actual = try records.program.capture(allocator, &generated.program, configuration);
    defer actual.deinit();
    var refs = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer refs.deinit();
    try records.codec.compare(actual.value, plans.target.?.kernels[0].lowered.program, &refs);
    try std.testing.expect(job.fixed.status().peak_bytes <= workspace.len);
    const context = generated.program.kernelModule().context;
    const handler = try context.registerDiagnosticHandler(.{ .handle = reportRetainedArtifactDiagnostic });
    defer context.eraseDiagnosticHandler(handler);
    const payload = (try @import("../target/root.zig").compileKernelForArtifactFormat(
        allocator,
        .cuda_ptx,
        generated.entry_name,
        generated.program.kernelModule(),
        .{},
    )).payload;
    defer allocator.free(payload.text);
    try std.testing.expect(payload.text.len != 0);
}

test "Accy retained artifact compilation owns its plan after workspace and preparation end" {
    const allocator = std.testing.allocator;
    const artifact = @import("../artifact/root.zig");
    const prepared = try savedArtifactPreparation(.{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var retained = true;
    defer if (retained) prepared.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    var workspace_live = true;
    defer if (workspace_live) allocator.free(workspace);
    var state = gpu.recording.BackendState{ .allocator = allocator };
    var plan = try artifact.createBackendArtifactPlanFromPreparedModule(allocator, state.handle(), prepared, .{}, workspace, configuration);
    defer plan.deinit();
    prepared.deinit();
    retained = false;
    @memset(workspace, 0xa5);
    allocator.free(workspace);
    workspace_live = false;
    try std.testing.expectEqual(1, state.create_count);
    try std.testing.expect(state.last_create_had_payload);
    try std.testing.expectEqual(1, plan.kernelCount());
    try std.testing.expectEqual(2, plan.input_slot_ids.len);
    try std.testing.expectEqual(1, plan.output_slot_ids.len);
    const kernel = plan.kernels.items[0];
    try std.testing.expectEqual(kernel.output_slot_id, plan.output_slot_ids[0]);
    try std.testing.expectEqualStrings(kernel.compile.entry_name, kernel.artifact.entry_name);
    try std.testing.expectEqual(kernel.compile.argument_count, state.last_create_argument_count);
}

test "Accy retained artifact reads the actual published chain and rejects before native effects" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const artifact = @import("../artifact/root.zig");
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var report = preparation.publication.PreparationReport{};
    defer report.deinit();
    var request = preparationRequest();
    request.options.target_profile = .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    };
    const prepared = try preparation.publication.prepare(allocator, .{ .draft = fixture.source }, request, &report, configuration);
    defer prepared.deinit();
    var state = gpu.recording.BackendState{ .allocator = allocator };
    try std.testing.expectError(error.WorkExhausted, artifact.createBackendArtifactPlanFromPreparedModule(allocator, state.handle(), prepared, .{}, &.{}, configuration));
    try std.testing.expectEqual(0, state.create_count);
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    var plan = try artifact.createBackendArtifactPlanFromPreparedModule(allocator, state.handle(), prepared, .{}, workspace, configuration);
    defer plan.deinit();
    try std.testing.expectEqual(7, report.completed);
    try std.testing.expectEqual(1, plan.kernelCount());
    try std.testing.expectEqual(1, state.create_count);
}

fn reportRetainedArtifactDiagnostic(
    _: ?*anyopaque,
    diagnostic: *const choir.diagnostics.Diagnostic,
) !choir.diagnostics.HandlerResult {
    const pretty = @import("pretty");
    var arena = @import("alloc_arena").Arena.init(std.testing.allocator);
    defer arena.deinit();
    var report = try pretty.diagnostic.Report.init(arena.allocator(), diagnostic.message);
    defer report.deinit();
    if (diagnostic.error_name) |name| try report.field("error", "{s}", .{name});
    for (diagnostic.metadata) |entry| try report.field(entry.name, "{s}", .{entry.value});
    pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
    return .consumed;
}

test "Accy retained artifact compilation preserves captured CPU ABI arguments" {
    if (comptime !@import("../target/root.zig").native_cpu_artifacts_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const artifact = @import("../artifact/root.zig");
    const prepared = try savedArtifactPreparation(.{
        .backend_kind = .cpu,
        .artifact_format = .cpu_object,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer prepared.deinit();
    const target = try publication.Module(.target).fromRevision(allocator, prepared.stage(.target));
    defer target.deinit();
    var captured = try target.plan(allocator, configuration.image);
    defer captured.deinit();
    const expected = captured.value.kernels[0].abi.?;
    try std.testing.expect(expected.static_arguments.len != 0);
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    var plan = try artifact.createBackendArtifactPlanFromPreparedModule(allocator, state.handle(), prepared, .{}, workspace, configuration);
    var plan_live = true;
    defer if (plan_live) plan.deinit();
    const actual = plan.kernels.items[0];
    try std.testing.expectEqual(expected.argument_count, actual.compile.argument_count);
    try std.testing.expectEqualDeep(expected.static_arguments, actual.static_arguments);
    try std.testing.expectEqual(expected.argument_count, actual.artifact.argument_count);
    const job = try artifact.ArtifactJob.init(allocator, plan);
    plan_live = false;
    defer job.deinit();
    const executable = @import("../executable/root.zig");
    const compiled = try executable.CompiledFragment.init(allocator, job);
    const loaded = try executable.loadFragment(allocator, state.handle(), compiled, .{ .artifact_format = .cpu_object });
    defer loaded.deinit();
    const left = [_]f32{ 1, 2, 3, 4 };
    const right = [_]f32{ 5, -2, 0.5, 6 };
    const bindings = try loaded.prepareInvocationBindings(allocator, &.{
        std.mem.sliceAsBytes(&left), std.mem.sliceAsBytes(&right),
    });
    defer bindings.deinit();
    try loaded.submitInvocationWithOptions(allocator, bindings, .{});
    try loaded.completeInvocationWithOptions(.{});
    var output: [4]f32 = undefined;
    try loaded.readInvocationOutput(bindings, 0, std.mem.sliceAsBytes(&output));
    for (output, left, right) |actual_value, lhs, rhs| {
        try std.testing.expectEqual(lhs + rhs + rhs, actual_value);
    }
}

test "Accy retained artifact rejects incompatible stage images before rebuilding pointer maps" {
    const allocator = std.testing.allocator;
    const artifact = @import("../artifact/root.zig");
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var chain = try Chain.init(fixture.source.choir_module, captured);
    defer chain.deinit();
    var other = try Fixture.initNames(&.{"different_stage_program"});
    defer other.deinit();
    const changed = try seal(chain.store, chain.kinds[6], other.source.choir_module, .target, captured.target, chain.products[5]);
    chain.products[6].release();
    chain.products[6] = changed;
    const prepared = try preparation.pipeline.BackendPreparedModule.create(allocator, preparationRevisions(&chain));
    defer prepared.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    if (artifact.InputJob.create(workspace, prepared, configuration)) |job| {
        job.destroy();
        return error.TestExpectedError;
    } else |err| try std.testing.expectEqual(error.IncompatibleStageImages, err);
}

test "Accy retained executable compiles without retaining preparation or restoration workspace" {
    const allocator = std.testing.allocator;
    const executable = @import("../executable/root.zig");
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const prepared = try savedArtifactPreparation(.{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var prepared_live = true;
    defer if (prepared_live) prepared.deinit();
    try std.testing.expectError(error.WorkExhausted, executable.compileFragmentFromPreparedModule(
        allocator,
        state.handle(),
        prepared,
        .{},
        &.{},
        configuration,
    ));
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    var workspace_live = true;
    defer if (workspace_live) allocator.free(workspace);
    const compiled = try executable.compileFragmentFromPreparedModule(
        allocator,
        state.handle(),
        prepared,
        .{},
        workspace,
        configuration,
    );
    var compiled_live = true;
    defer if (compiled_live) compiled.deinit();
    prepared.deinit();
    prepared_live = false;
    @memset(workspace, 0xa5);
    allocator.free(workspace);
    workspace_live = false;
    const plan = compiled.artifactPlan();
    try std.testing.expectEqual(@as(usize, 1), plan.kernelCount());
    try std.testing.expectEqual(@as(usize, 2), plan.input_slot_ids.len);
    try std.testing.expectEqual(@as(usize, 1), plan.output_slot_ids.len);
    compiled_live = false;
    const loaded = try executable.loadFragment(allocator, state.handle(), compiled, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.load_count);
}

const RejectCompilationPhase = struct {
    phase: []const u8,

    fn observe(raw: ?*anyopaque, phase: []const u8, _: u64) !void {
        const self: *const RejectCompilationPhase = @ptrCast(@alignCast(raw.?));
        if (std.mem.eql(u8, self.phase, phase)) return error.CompilationObserverRejected;
    }
};

test "Accy retained executable releases compiled ownership after observer failure" {
    const allocator = std.testing.allocator;
    const executable = @import("../executable/root.zig");
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const prepared = try savedArtifactPreparation(.{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer prepared.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    for ([_][]const u8{ "plan_create_backend_artifacts", "compile_fragment" }) |phase| {
        var observer = RejectCompilationPhase{ .phase = phase };
        try std.testing.expectError(error.CompilationObserverRejected, executable.compileFragmentFromPreparedModule(
            allocator,
            state.handle(),
            prepared,
            .{ .instrumentation = .{ .context = &observer, .observe = RejectCompilationPhase.observe } },
            workspace,
            configuration,
        ));
    }
    const retry = try executable.compileFragmentFromPreparedModule(
        allocator,
        state.handle(),
        prepared,
        .{},
        workspace,
        configuration,
    );
    defer retry.deinit();
    try std.testing.expectEqual(@as(usize, 1), retry.kernelCount());
    try std.testing.expectEqual(@as(usize, 0), state.load_count);
}

const exec_compiler = @import("../executable/root.zig");

fn compilationRequest(workspace: []u8) exec_compiler.FragmentCompilationRequest {
    const request = preparationRequest();
    return .{
        .source = request.source,
        .work = request.work,
        .record_bytes = request.record_bytes,
        .artifact_workspace = workspace,
    };
}

fn compileCacheFixture(
    cache: *exec_compiler.FragmentCompilerCache,
    name: []const u8,
    request: exec_compiler.FragmentCompilationRequest,
    report: *preparation.publication.PreparationReport,
) !exec_compiler.FragmentCompilerCacheUpdate {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    var fixture = try Fixture.initNames(&.{name});
    fixture.cache.deinit();
    return cache.refreshFromSemanticModule(fixture.source, .{}, request, report, configuration);
}

const PreparationPhases = struct {
    seen: u8 = 0,

    fn observe(raw: ?*anyopaque, phase: []const u8, _: u64) !void {
        if (!std.mem.startsWith(u8, phase, "run_")) return;
        const self: *PreparationPhases = @ptrCast(@alignCast(raw.?));
        const expected = [_][]const u8{
            "run_contract_pipeline", "run_tensor_pipeline", "run_dispatch_pipeline",
            "run_memory_pipeline",   "run_kernel_pipeline", "run_target_pipeline",
        };
        try std.testing.expect(self.seen < expected.len);
        try std.testing.expectEqualStrings(expected[self.seen], phase);
        self.seen += 1;
    }
};

test "Accy executable compiler admits warm stages and compiles a fresh native job" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var cache = exec_compiler.FragmentCompilerCache.init(allocator, state.handle());
    defer cache.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    var request = compilationRequest(workspace);
    var cold = preparation.publication.PreparationReport{};
    defer cold.deinit();
    var first = try compileCacheFixture(&cache, "compiler_transaction", request, &cold);
    defer first.deinit(allocator);
    try std.testing.expect(!first.preparation.reused);
    try std.testing.expectEqual(@as(usize, 1), state.load_count);
    request.work.allowance = try cold.charged();
    var warm = preparation.publication.PreparationReport{};
    defer warm.deinit();
    var phases = PreparationPhases{};
    var second = try cache.refreshFromSemanticRevision(
        first.preparation.prepared.stage(.semantic),
        .{ .instrumentation = .{ .context = &phases, .observe = PreparationPhases.observe } },
        request,
        &warm,
        configuration,
    );
    defer second.deinit(allocator);
    try std.testing.expect(second.preparation.reused);
    try std.testing.expectEqualDeep(try cold.charged(), try warm.charged());
    for (warm.stages[0..warm.completed]) |stage| try std.testing.expect(stage == .warm);
    try std.testing.expect(first.preparation.prepared.stage(.target).eql(second.preparation.prepared.stage(.target)));
    try std.testing.expectEqual(@as(usize, 7), second.preparation.refresh.productCount());
    try std.testing.expectEqual(@as(usize, 2), state.load_count);
    try std.testing.expectEqual(@as(usize, 1), state.destroy_count);
    try std.testing.expect(first.fragment != second.fragment);
    try std.testing.expectEqual(second.fragment, cache.currentFragment().?);
    try std.testing.expectEqual(@as(u8, 6), phases.seen);
}

test "Accy executable compiler preserves both prior owners after native load failure" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var cache = exec_compiler.FragmentCompilerCache.init(allocator, state.handle());
    defer cache.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    const request = compilationRequest(workspace);
    var cold = preparation.publication.PreparationReport{};
    defer cold.deinit();
    var first = try compileCacheFixture(&cache, "original_compiler_source", request, &cold);
    defer first.deinit(allocator);
    const previous = cache.currentPrepared().?;
    state.fail_load_after_count = 1;
    var failed = preparation.publication.PreparationReport{};
    defer failed.deinit();
    try std.testing.expectError(error.RuntimeUnavailable, compileCacheFixture(
        &cache,
        "changed_compiler_source",
        request,
        &failed,
    ));
    try std.testing.expectEqual(@as(usize, 7), failed.completed);
    try std.testing.expect(!failed.stages[0].record().eql(first.preparation.prepared.stage(.semantic)));
    try std.testing.expectEqual(previous, cache.currentPrepared().?);
    try std.testing.expectEqual(first.fragment, cache.currentFragment().?);
    try std.testing.expectEqual(@as(usize, 0), state.destroy_count);
    state.fail_load_after_count = null;
    var retried = preparation.publication.PreparationReport{};
    defer retried.deinit();
    var second = try compileCacheFixture(&cache, "changed_compiler_source", request, &retried);
    defer second.deinit(allocator);
    try std.testing.expect(!second.preparation.reused);
    try std.testing.expectEqual(@as(usize, 2), state.load_count);
    try std.testing.expectEqual(@as(usize, 1), state.destroy_count);
}

test "Accy executable compiler exhaustion stops before replacing or loading native state" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var cache = exec_compiler.FragmentCompilerCache.init(allocator, state.handle());
    defer cache.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    var request = compilationRequest(workspace);
    var cold = preparation.publication.PreparationReport{};
    defer cold.deinit();
    var first = try compileCacheFixture(&cache, "compiler_exhaustion", request, &cold);
    defer first.deinit(allocator);
    const previous = cache.currentPrepared().?;
    request.work.allowance = .{};
    var failed = preparation.publication.PreparationReport{};
    defer failed.deinit();
    try std.testing.expectError(error.WorkExhausted, cache.refreshFromSemanticRevision(
        previous.stage(.semantic),
        .{},
        request,
        &failed,
        configuration,
    ));
    try std.testing.expectEqual(previous, cache.currentPrepared().?);
    try std.testing.expectEqual(first.fragment, cache.currentFragment().?);
    try std.testing.expectEqual(@as(usize, 1), state.load_count);
    try std.testing.expectEqual(@as(usize, 0), state.destroy_count);
}

const tensor_compiler = @import("../tensor/root.zig");

fn tensorCompilerProgram(name: []const u8) !tensor_compiler.Graph {
    var builder = try tensor_compiler.Builder.init(std.testing.allocator, name);
    errdefer builder.deinit();
    const left = try builder.input(.f32, .{ .lane = 4 });
    const right = try builder.input(.f32, .{ .lane = 4 });
    return builder.finish(&.{try left.add(right)});
}

test "Accy tensor compiler admits exact stages from independent program drafts" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var cache = tensor_compiler.FragmentCompilerCache.init(allocator, state.handle());
    defer cache.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    const request = compilationRequest(workspace);
    var first_program = try tensorCompilerProgram("tensor_compiler");
    defer first_program.deinit();
    var first_report = preparation.publication.PreparationReport{};
    defer first_report.deinit();
    var first = try cache.refreshFromProgram(&first_program, .{}, request, &first_report, configuration);
    defer first.deinit(allocator);
    var second_program = try tensorCompilerProgram("tensor_compiler");
    defer second_program.deinit();
    var second_report = preparation.publication.PreparationReport{};
    defer second_report.deinit();
    var second = try cache.refreshFromProgram(&second_program, .{}, request, &second_report, configuration);
    defer second.deinit(allocator);
    try std.testing.expect(second.preparation.reused);
    try std.testing.expect(first.preparation.prepared.stage(.semantic).eql(second.preparation.prepared.stage(.semantic)));
    try std.testing.expectEqualDeep(try first_report.charged(), try second_report.charged());
    try std.testing.expectEqual(@as(usize, 7), second.preparation.refresh.productCount());
    try std.testing.expectEqual(@as(usize, 2), state.load_count);
    try std.testing.expectEqual(@as(usize, 1), state.destroy_count);
    try std.testing.expectEqual(second.fragment, cache.currentFragment().?);
}

test "Accy tensor compiler respects lowering capacity on repeated input and preserves prior state" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var cache = tensor_compiler.FragmentCompilerCache.init(allocator, state.handle());
    defer cache.deinit();
    const workspace = try allocator.alloc(u8, 256 * 1024 * 1024);
    defer allocator.free(workspace);
    const request = compilationRequest(workspace);
    var program = try tensorCompilerProgram("tensor_compiler_bounds");
    defer program.deinit();
    var first_report = preparation.publication.PreparationReport{};
    defer first_report.deinit();
    var first = try cache.refreshFromProgram(&program, .{}, request, &first_report, configuration);
    defer first.deinit(allocator);
    const previous = cache.currentPrepared().?;
    var options = exec_compiler.FragmentCompilerOptions{};
    options.semantic_context_limits.operations.storage_bytes = 1;
    var failed = preparation.publication.PreparationReport{};
    defer failed.deinit();
    try std.testing.expectError(error.OutOfMemory, cache.refreshFromProgram(
        &program,
        options,
        request,
        &failed,
        configuration,
    ));
    try std.testing.expectEqual(@as(u8, 0), failed.completed);
    try std.testing.expectEqual(previous, cache.currentPrepared().?);
    try std.testing.expectEqual(first.fragment, cache.currentFragment().?);
    try std.testing.expectEqual(@as(usize, 1), state.load_count);
    var retried = preparation.publication.PreparationReport{};
    defer retried.deinit();
    var retry = try cache.refreshFromProgram(&program, .{}, request, &retried, configuration);
    defer retry.deinit(allocator);
    try std.testing.expect(retry.preparation.reused);
    try std.testing.expectEqual(@as(usize, 2), state.load_count);
}

fn tensorScatterCompilerProgram() !tensor_compiler.Graph {
    var builder = try tensor_compiler.Builder.init(std.testing.allocator, "tensor_scatter_compiler");
    errdefer builder.deinit();
    const table = try builder.input(.f32, .{ .vocab = 16, .channel = 4 });
    const ids = try builder.input(.i32, .{ .token = 3 });
    const gathered = try table.gather(ids, .vocab);
    const zero = try builder.full(.f32, .{ .vocab = 16, .channel = 4 }, 0.0);
    return builder.finish(&.{try zero.scatterAdd(ids, gathered, .vocab)});
}

fn expectTensorKernelCall(
    prepared: *const preparation.pipeline.BackendPreparedModule,
    expected: ?[]const u8,
) !void {
    const allocator = std.testing.allocator;
    const module = try publication.Module(.tensor).fromRevision(allocator, prepared.stage(.tensor));
    defer module.deinit();
    const image = try module.open(allocator, configuration.image);
    defer image.destroy();
    var context = try choir.ir.Context.init(allocator, configuration.context);
    defer context.deinit(allocator);
    try registerContext(&context);
    var decoded = try choir.bytecode.decodeModule(allocator, &context, image.root(0).?.bytes);
    defer decoded.deinit();
    const operation_name = @import("../choir/root.zig").dialect.AccyDialect.KernelCallOp.operation_name;
    try std.testing.expectEqual(@as(usize, if (expected != null) 1 else 0), choir.ir.inspection.countOperationsNamed(decoded.module, operation_name));
    if (expected) |name| {
        const call = choir.ir.inspection.findOperationNamed(decoded.module, operation_name).?;
        const target = call.getAttr("target").?.cast(choir.ir.Attribute.DialectAttr).?;
        try std.testing.expectEqualStrings(name, target.payload);
    }
}

test "Accy tensor compiler captures scatter mode changes and current catalog targets" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const library = @import("../kernel/root.zig").library;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var cache = tensor_compiler.FragmentCompilerCache.init(allocator, state.handle());
    defer cache.deinit();
    const workspace = try allocator.alloc(u8, 1024 * 1024 * 1024);
    defer allocator.free(workspace);
    var request = compilationRequest(workspace);
    request.work.workspace = 2 * 1024 * 1024 * 1024;
    var program = try tensorScatterCompilerProgram();
    defer program.deinit();
    var family4 = try library.indexing.createScatterAddFamilyArtifact(allocator, state.handle(), .{
        .axis_size = 16,
        .updates = 3,
        .inner = 4,
        .dtype = .f32,
        .threads = 4,
    }, .{ .limits = .testing, .format = .cuda_ptx });
    defer family4.deinit();
    var family8 = try library.indexing.createScatterAddFamilyArtifact(allocator, state.handle(), .{
        .axis_size = 16,
        .updates = 3,
        .inner = 4,
        .dtype = .f32,
        .threads = 8,
    }, .{ .limits = .testing, .format = .cuda_ptx });
    defer family8.deinit();
    const registry4 = family4.registry();
    const registry8 = family8.registry();
    for ([_]?u32{ null, 4, 4, 8, null }, 0..) |threads, index| {
        var options = exec_compiler.FragmentCompilerOptions{};
        if (threads) |count| {
            options.kernel_call_registry = if (count == 4) &registry4 else &registry8;
            options.scatter_add_schedule = .{ .thread_blocks = count };
        }
        var report = preparation.publication.PreparationReport{};
        defer report.deinit();
        var update = cache.refreshFromProgram(&program, options, request, &report, configuration) catch |err| {
            try reportPreparationTestFailure(err, &report);
            return err;
        };
        defer update.deinit(allocator);
        try std.testing.expectEqual(index == 2, update.preparation.reused);
        const target: ?[]const u8 = if (threads) |count|
            (if (count == 4) "accy.kernel.indexing.scatter_add_family_4_f32" else "accy.kernel.indexing.scatter_add_family_8_f32")
        else
            null;
        try expectTensorKernelCall(update.preparation.prepared, target);
        if (index < 2) try expectRestoredTensorLookups(update.preparation.prepared, workspace, index == 1);
    }
}

fn expectRestoredTensorLookups(
    prepared: *const preparation.pipeline.BackendPreparedModule,
    workspace: []u8,
    aliases: bool,
) !void {
    const input = try @import("../artifact/root.zig").InputJob.create(workspace, prepared, configuration);
    defer input.destroy();
    const plans = input.plans();
    var reordered = false;
    for (plans.schedule.work_items.items, 0..) |work, index| {
        const found = plans.schedule.getWorkForRoot(work.root) orelse return error.MissingWorkLookup;
        try std.testing.expectEqual(work.id, found.id);
        reordered = reordered or work.id != index;
    }
    if (!aliases) try std.testing.expect(reordered);
    if (aliases) {
        const name = @import("../choir/root.zig").dialect.AccyDialect.KernelCallOp.operation_name;
        const call = choir.ir.inspection.findOperationNamed(plans.root, name).?;
        const value = call.getResult(0).?;
        const slot = plans.buffers.getSlot(value) orelse return error.MissingAliasLookup;
        try std.testing.expect(slot.value != value);
        try std.testing.expect(plans.buffers.value_to_slot.count() > plans.buffers.slots.items.len);
    }
}

fn reportPreparationTestFailure(err: anyerror, report: *const preparation.publication.PreparationReport) !void {
    const pretty = @import("pretty");
    var arena = @import("alloc_arena").Arena.init(std.testing.allocator);
    defer arena.deinit();
    var output = try pretty.diagnostic.Report.init(arena.allocator(), "retained preparation failed");
    defer output.deinit();
    try output.field("error", "{s}", .{@errorName(err)});
    try output.field("completed stages", "{d}", .{report.completed});
    if (report.failure) |failure| {
        try output.field("workspace limit", "{d}", .{failure.work.limits.workspace});
        try output.field("maximum live storage", "{d}", .{failure.work.maximum_live_storage});
        try output.field("exceeded", "{any}", .{failure.work.exceeded});
        for (failure.work.events) |event| {
            if (event.outcome == .success) continue;
            try output.field(event.identity().name, "outcome={s}, admitted={}, workspace={d}, charged={any}", .{
                @tagName(event.outcome), event.admitted, event.workspace, event.charged,
            });
        }
    }
    pretty.diagnostic.writeStderr(&output, .{ .width = 100 });
}

test "Accy tensor compiler Dispatch records preserve reordered IDs and reject counter drift" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.initNames(&.{ "first", "second" });
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var decoded = try records.codec.decode(allocator, records.dispatch.Record, .dispatch, captured.dispatch);
    defer decoded.deinit();
    const items = @constCast(decoded.value.schedule.work_items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    std.mem.swap(records.dispatch.WorkItem, &items[0], &items[1]);
    try records.dispatch.validate(allocator, decoded.value);
    const id = items[1].id;
    items[1].id = items[0].id;
    try std.testing.expectError(error.InvalidStageRecord, records.dispatch.validate(allocator, decoded.value));
    items[1].id = items.len;
    try std.testing.expectError(error.InvalidStageRecord, records.dispatch.validate(allocator, decoded.value));
    items[1].id = id;
    decoded.value.schedule.total_static_elements += 1;
    try std.testing.expectError(error.InvalidStageRecord, records.dispatch.validate(allocator, decoded.value));
    decoded.value.schedule.total_static_elements -= 1;
    decoded.value.fusion.fused_op_count += 1;
    try std.testing.expectError(error.InvalidStageRecord, records.dispatch.validate(allocator, decoded.value));
}

test "Accy tensor compiler Memory bindings require canonical order and complete primary values" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var memory = try records.codec.decode(allocator, records.memory.Record, .memory, captured.memory);
    defer memory.deinit();
    var dispatch = try records.codec.decode(allocator, records.dispatch.Record, .dispatch, captured.dispatch);
    defer dispatch.deinit();
    try records.memory.validate(allocator, memory.value, dispatch.value);
    const bindings = @constCast(memory.value.bindings);
    try std.testing.expect(bindings.len > 1);
    std.mem.swap(records.memory.Binding, &bindings[0], &bindings[1]);
    try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, memory.value, dispatch.value));
    std.mem.swap(records.memory.Binding, &bindings[0], &bindings[1]);
    const saved = bindings[1];
    bindings[1] = bindings[0];
    try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, memory.value, dispatch.value));
    bindings[1] = saved;
    bindings[1].slot_id = memory.value.buffers.slots.len;
    try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, memory.value, dispatch.value));
    bindings[1] = saved;
    memory.value.bindings = bindings[0 .. bindings.len - 1];
    try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, memory.value, dispatch.value));
}

test "Accy record counters reject every Memory aggregate independently" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var memory = try records.codec.decode(allocator, records.memory.Record, .memory, captured.memory);
    defer memory.deinit();
    var dispatch = try records.codec.decode(allocator, records.dispatch.Record, .dispatch, captured.dispatch);
    defer dispatch.deinit();
    try records.memory.validate(allocator, memory.value, dispatch.value);
    inline for (.{
        "input_slot_count",    "output_slot_count",  "temporary_slot_count",
        "constant_slot_count", "dynamic_slot_count", "total_static_bytes",
    }) |field| {
        var changed = memory.value;
        @field(changed.buffers, field) += 1;
        try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, changed, dispatch.value));
    }
    inline for (.{
        "host_slot_count",            "device_global_slot_count", "device_constant_slot_count",
        "device_shared_slot_count",   "unified_slot_count",       "host_input_transfer_count",
        "host_output_transfer_count", "dynamic_slot_count",       "elided_value_count",
        "total_static_bytes",
    }) |field| {
        var changed = memory.value;
        @field(changed.spaces, field) += 1;
        try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, changed, dispatch.value));
    }
    inline for (.{
        "scalar_layout_count",      "row_major_layout_count",   "dynamic_row_major_layout_count",
        "host_slot_count",          "device_global_slot_count", "device_constant_slot_count",
        "device_shared_slot_count", "unified_slot_count",       "dynamic_slot_count",
        "elided_value_count",       "total_static_bytes",
    }) |field| {
        var changed = memory.value;
        @field(changed.layouts, field) += 1;
        try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, changed, dispatch.value));
    }
}

test "Accy record counters reject Memory byte total overflow" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var memory = try records.codec.decode(allocator, records.memory.Record, .memory, captured.memory);
    defer memory.deinit();
    var dispatch = try records.codec.decode(allocator, records.dispatch.Record, .dispatch, captured.dispatch);
    defer dispatch.deinit();
    const slots = @constCast(memory.value.buffers.slots);
    try std.testing.expect(slots.len >= 2);
    slots[0].byte_size = std.math.maxInt(u64);
    slots[1].byte_size = 1;
    try std.testing.expectError(error.InvalidStageRecord, records.memory.validate(allocator, memory.value, dispatch.value));
}

test "Accy record counters recompute Target runtime scalars from the captured parameters" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var captured = try captureFixture(&fixture);
    defer captured.deinit();
    var target = try records.codec.decode(allocator, records.target.Record, .target, captured.target);
    defer target.deinit();
    var parent = try records.codec.decode(allocator, records.kernel.Record, .kernel, captured.kernel);
    defer parent.deinit();
    try records.target.validate(allocator, target.value, parent.value);
    const kernels = @constCast(target.value.kernels);
    try std.testing.expect(kernels.len != 0);
    kernels[0].runtime_scalar_argument_count += 1;
    try std.testing.expectError(error.InvalidStageRecord, records.target.validate(allocator, target.value, parent.value));
}

fn registerTestContext(context: *choir.ir.Context) !void {
    try choir.dialects.registerChoirDialect(context);
    try @import("../choir/root.zig").registerAccyDialect(context);
}

const test_configuration = operation.Configuration{
    .context = choir.ir.Context.Limits.testing,
    .register = registerTestContext,
    .registration = .{ .name = "accy-stage-test-context", .version = 1 },
    .codec = .{ .operations = 100, .entities = 1000, .fields = 1000, .depth = 32 },
    .image = .{ .bytes = 65536, .entities = 1024, .depth = 32 },
    .roots = 1,
    .gate_scratch = 64 * 1024 * 1024,
    .verify = choir.ir.verify.default_options,
};

const test_limits = revision.store.Limits{
    .revisions = 8,
    .kinds = 4,
    .builders = 4,
    .compiler_manifests = 2,
    .record_bytes = 32 * 1024 * 1024,
    .gate_scratch_bytes = test_configuration.gate_scratch,
    .candidate_count = 8,
    .screening_bytes = 32 * 1024 * 1024,
};

const TestKinds = struct {
    semantic: *const revision.Kind,
    contract: *const revision.Kind,
    tensor: *const revision.Kind,
    bare: *const revision.Kind,
};

fn testKinds(store: *revision.Store) !TestKinds {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const kinds = TestKinds{
        .semantic = try @import("root.zig").publication.registerKind(
            allocator,
            store,
            .semantic,
            test_configuration,
        ),
        .contract = try @import("root.zig").publication.registerKind(
            allocator,
            store,
            .contract,
            test_configuration,
        ),
        .tensor = try @import("root.zig").publication.registerKind(
            allocator,
            store,
            .tensor,
            test_configuration,
        ),
        .bare = try operation.registerKind(allocator, store, test_configuration, .{
            .name = "accy-bare-test",
            .version = 1,
        }, &.{}),
    };
    store.freeze();
    return kinds;
}

fn testBegin(
    store: *revision.Store,
    kind: *const revision.Kind,
    comptime stage: publication.Stage,
    parent: ?*const revision.Revision,
) !*revision.Builder {
    const allocator = std.testing.allocator;
    const policy = try choir.product.recipe.encode(allocator, .{
        .arithmetic = .{},
        .policy = "capture-test",
    });
    defer allocator.free(policy);
    const dependencies: []const revision.store.Dependency = if (parent) |source|
        &.{.{ .role = "source", .revision = source }}
    else
        &.{};
    return store.begin(.{
        .kind = kind,
        .address = .{
            .producer = "accy",
            .source = "sealed-stage-test",
            .stage = stage.name(),
            .variant = "",
        },
        .inputs = .{
            .compiler_manifest = try choir.product.compiler.manifest(),
            .versions = &.{ stage.schema(), operation.schema_identity },
            .pipeline = &.{},
            .options = &.{},
            .policy = policy,
        },
        .dependencies = dependencies,
        .parent = parent,
    }, .{
        .allowance = revision.WorkVector.uniform(1024 * 1024 * 1024),
        .workspace = 128 * 1024 * 1024,
        .events = 64,
    });
}

fn abortTest(builder: *revision.Builder) void {
    if (builder.abort(.rejected)) |failure| {
        var owned = failure;
        owned.deinit();
    }
}

fn testSource(
    store: *revision.Store,
    kind: *const revision.Kind,
    foreign: bool,
) !operation.Product {
    const allocator = std.testing.allocator;
    var source = try semantic.Builder.init(allocator, .standard);
    defer source.deinit();
    const typ = try source.tensor(.f32, &.{4});
    var function = try source.beginFunction("sealed_stage", &.{ typ, typ }, &.{typ});
    const sum = try function.add(function.parameter(0), function.parameter(1));
    try function.return_(&.{sum});
    try function.finish();
    const module = try source.finish();
    defer module.deinit();
    if (foreign) try addForeignOperation(module);
    const builder = try testBegin(store, kind, .semantic, null);
    var open = true;
    errdefer if (open) abortTest(builder);
    try module.capture(builder, test_configuration);
    try module.choir_module.setAttr("after_capture", try module.context().getStringAttr("changed"));
    const product = try operation.Product.seal(builder, kind);
    open = false;
    return product;
}

fn addForeignOperation(module: *@import("../choir/root.zig").semantic.SemanticModule) !void {
    const dialect = choir.dialects;
    const typ = try dialect.ArithDialect.getScalarType(module.context(), .f32);
    const memref = try dialect.MemrefDialect.getMemrefType1D(module.context(), 4, typ, .device);
    const alloc = try dialect.MemrefDialect.AllocOp.createStatic(
        module.context(),
        .unknown,
        memref,
    );
    try module.choir_module.getRegion(0).?.getEntryBlock().?.addOperation(alloc.op);
}

fn testSuccessor(
    store: *revision.Store,
    kind: *const revision.Kind,
    comptime stage: publication.Stage,
    parent: operation.Product,
    bytes: []const u8,
) !operation.Product {
    const builder = try testBegin(store, kind, stage, parent.revision);
    var open = true;
    errdefer if (open) abortTest(builder);
    const job = try parent.successor(builder, test_configuration);
    defer job.destroy();
    try job.capture(builder, bytes, &.{}, test_configuration);
    const product = try operation.Product.seal(builder, kind);
    open = false;
    return product;
}

test "sealed Accy IR stages retain immutable images after source destruction" {
    const allocator = std.testing.allocator;
    const store = try revision.Store.create(allocator, test_limits);
    defer store.release();
    const kinds = try testKinds(store);
    const source = try testSource(store, kinds.semantic, false);
    defer source.release();
    const contract = try testSuccessor(
        store,
        kinds.contract,
        .contract,
        source,
        &publication.irRecord(.contract),
    );
    defer contract.release();
    const tensor = try testSuccessor(store, kinds.tensor, .tensor, contract, &publication.irRecord(.tensor));
    defer tensor.release();
    const handle = try publication.Module(.tensor).fromRevision(allocator, tensor.revision);
    defer handle.deinit();
    const retained = try handle.retain(allocator);
    defer retained.deinit();
    try std.testing.expect(handle.eql(retained));
    const image = try retained.open(allocator, test_configuration.image);
    defer image.destroy();
    try std.testing.expectEqualStrings("builtin.module", image.root(0).?.operations[0].name);
    try std.testing.expectEqualSlices(u8, &publication.irRecord(.tensor), image.stage());
    try std.testing.expect(std.mem.indexOf(u8, image.root(0).?.bytes, "after_capture") == null);
    try std.testing.expectError(
        error.WrongStage,
        publication.Module(.contract).fromRevision(allocator, tensor.revision),
    );
}

test "sealed Accy stages reject missing gates and wrong predecessor records" {
    const allocator = std.testing.allocator;
    const store = try revision.Store.create(allocator, test_limits);
    defer store.release();
    const kinds = try testKinds(store);
    const source = try testSource(store, kinds.semantic, false);
    defer source.release();
    const bare = try testSuccessor(store, kinds.bare, .contract, source, &publication.irRecord(.contract));
    defer bare.release();
    try std.testing.expectError(
        error.MissingGateEvidence,
        publication.Module(.contract).fromRevision(allocator, bare.revision),
    );
    try std.testing.expectError(
        error.InvalidStageDependency,
        testSuccessor(store, kinds.tensor, .tensor, source, &publication.irRecord(.tensor)),
    );
    try std.testing.expectError(
        error.InvalidStageRecord,
        testSuccessor(store, kinds.contract, .contract, source, &publication.irRecord(.tensor)),
    );
}

test "sealed Accy Contract rejects unsupported dialects" {
    const allocator = std.testing.allocator;
    const store = try revision.Store.create(allocator, test_limits);
    defer store.release();
    const kinds = try testKinds(store);
    const source = try testSource(store, kinds.semantic, true);
    defer source.release();
    try std.testing.expectError(
        error.UnsupportedDialect,
        testSuccessor(store, kinds.contract, .contract, source, &publication.irRecord(.contract)),
    );
}

fn checkHandleFailure(allocator: std.mem.Allocator, published: *const revision.Revision) !void {
    const handle = try publication.Module(.semantic).fromRevision(allocator, published);
    defer handle.deinit();
    const image = try handle.open(allocator, test_configuration.image);
    defer image.destroy();
    try std.testing.expectEqualStrings("builtin.module", image.root(0).?.operations[0].name);
}

test "sealed Accy module handles clean allocation failures" {
    const allocator = std.testing.allocator;
    const store = try revision.Store.create(allocator, test_limits);
    defer store.release();
    const kinds = try testKinds(store);
    const source = try testSource(store, kinds.semantic, false);
    defer source.release();
    try std.testing.checkAllAllocationFailures(allocator, checkHandleFailure, .{source.revision});
}

test "sealed Accy stages require predecessor gate evidence beyond its address" {
    const allocator = std.testing.allocator;
    const store = try revision.Store.create(allocator, test_limits);
    defer store.release();
    const kinds = try testKinds(store);
    const bare_source = try testSource(store, kinds.bare, false);
    defer bare_source.release();
    try std.testing.expectError(
        error.MissingGateEvidence,
        testSuccessor(store, kinds.contract, .contract, bare_source, &publication.irRecord(.contract)),
    );
    const source = try testSource(store, kinds.semantic, false);
    defer source.release();
    const bare_contract = try testSuccessor(
        store,
        kinds.bare,
        .contract,
        source,
        &publication.irRecord(.contract),
    );
    defer bare_contract.release();
    try std.testing.expectError(
        error.MissingGateEvidence,
        testSuccessor(store, kinds.tensor, .tensor, bare_contract, &publication.irRecord(.tensor)),
    );
}
