const std = @import("std");
const simd = @import("simd");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const entity = @import("root.zig").entity;
const revision = @import("root.zig").revision;
const recipe = @import("root.zig").recipe;
const compiler = @import("root.zig").compiler;
const bytecode = @import("../bytecode/root.zig");
const alloc_fixed = @import("alloc_fixed");

const Bytes = simd.ScalableTag(u8);

pub const image_version: u32 = 1;
pub const schema_identity = revision.record.Version{
    .name = "choir-operation-schema",
    .version = 1,
};

pub const Configuration = struct {
    context: ir.Context.Limits,
    register: *const fn (*ir.Context) anyerror!void,
    registration: revision.record.Version,
    codec: bytecode.qualification.Limits,
    image: bytecode.image.Limits,
    roots: u32,
    gate_scratch: u32,
    verify: ir.VerifyOptions,
};

pub const Source = struct {
    operation: *ir.Operation,
    resources: []const bytecode.Resource = &.{},
};

/// The trusted composition entry fixes the complete IR gate before freezing its store.
pub fn registerKind(
    allocator: std.mem.Allocator,
    store: *revision.Store,
    comptime configuration: Configuration,
    identity: revision.record.Version,
    gates: []const revision.store.Gate,
) !*const revision.Kind {
    comptime classifyConfiguration();
    _ = try compiler.manifest();
    try requireGenericVerification(configuration.verify);
    var writer = revision.record.Writer.init(allocator);
    defer writer.deinit();
    try revision.record.writeValue(&writer, .{
        .image_version = image_version,
        .bytecode_version = bytecode.format_version,
        .context = configuration.context,
        .registration = configuration.registration,
        .codec = configuration.codec,
        .image = configuration.image,
        .roots = configuration.roots,
        .gate_scratch = configuration.gate_scratch,
        .verify = configuration.verify,
    });
    return store.register(.{
        .identity = identity,
        .schema = .{
            .identity = schema_identity,
            .definition = writer.bytes.items,
            .scratch_bytes = configuration.gate_scratch,
            .run = struct {
                fn run(
                    input: revision.store.GateInput,
                    scratch: []u8,
                ) !revision.record.EntityCounts {
                    var fixed = alloc_fixed.FixedBuffer.init(scratch);
                    const inputs = try revision.record.decodeInputs(input.exact.inputs);
                    try requireCompilerManifest(input.compiler_manifest);
                    return verifyImage(
                        fixed.allocator(),
                        input.exact.image,
                        try recipe.decode(inputs.policy),
                        configuration,
                    ) catch |err| return if (err == error.OutOfMemory)
                        error.WorkExhausted
                    else
                        err;
                }
            }.run,
        },
        .gates = gates,
    });
}

fn boundedFailure(work: *revision.AccountingV1, err: anyerror) anyerror {
    if (err == error.OutOfMemory) {
        work.fail(.exhausted);
        return error.WorkExhausted;
    }
    return err;
}

fn requireCompilerManifest(bytes: []const u8) !void {
    if (!simd.equal(Bytes, bytes, try compiler.manifest())) {
        return error.UnrecordedCompilerBuild;
    }
}

fn classifyConfiguration() void {
    const fields = revision.record.requireFields;
    fields(Configuration, &.{
        "context", "register", "registration", "codec", "image", "roots", "gate_scratch", "verify",
    });
    fields(ir.Context.Limits, &.{
        "maximum_alignment", "configuration", "types", "attributes", "operations", "diagnostics",
        "transient_bytes",
    });
    fields(ir.Context.Limits.Configuration, &.{
        "table_bytes", "name_bytes", "interface_bytes", "transaction_bytes",
    });
    fields(ir.Context.Limits.Types, &.{ "table_bytes", "key_bytes", "payload_bytes" });
    fields(ir.Context.Limits.Attributes, &.{ "table_bytes", "payload_bytes" });
    fields(ir.Context.Limits.Operations, &.{ "storage_bytes", "nested_bytes" });
    fields(ir.Context.Limits.Diagnostics, &.{ "handler_bytes", "payload_bytes" });
    fields(bytecode.qualification.Limits, &.{ "operations", "entities", "fields", "depth" });
    fields(bytecode.image.Limits, &.{ "bytes", "entities", "depth" });
    fields(ir.VerifyOptions, &.{
        "check_terminators",     "require_terminators", "recursive", "check_use_def",
        "check_local_dominance", "check_cfg",           "max_depth",
    });
}

fn requireGenericVerification(options: ir.VerifyOptions) !void {
    if (!options.recursive or options.max_depth != 0 or !options.check_use_def or
        !options.check_local_dominance or !options.check_cfg or !options.check_terminators)
    {
        return error.WeakenedOperationSchema;
    }
}

/// Exclusive job capture copies only qualified bytecode; no source pointer is retained.
pub fn capture(
    builder: *revision.Builder,
    sources: []const Source,
    stage_record: []const u8,
    observations: []const revision.record.Fact,
    comptime configuration: Configuration,
) !void {
    const work = builder.accounting();
    errdefer work.fail(.rejected);
    if (sources.len == 0 or sources.len > configuration.roots) return error.EmptyOperationProduct;
    try requireCompilerManifest(builder.compilerManifest());
    const recorded = try recipe.decode(builder.inputs().policy);
    for (sources) |source| try recorded.requireContext(source.operation.getContext());
    try verifySources(sources, work, configuration);
    const token = try work.begin(.decode, .{
        .identity = .{ .name = "choir-qualified-bytecode", .version = 1 },
        .work = .{
            .input_bytes = configuration.image.bytes,
            .output_bytes = configuration.image.bytes,
            .structural_visits = configuration.image.entities,
            .allocation_capacity = configuration.gate_scratch,
        },
        .workspace = configuration.gate_scratch,
    });
    var open = true;
    errdefer if (open) {
        work.finish(token, .rejected, .{}) catch {};
    };
    const scratch = try builder.acquireWorkspace(.scratch);
    defer scratch.release();
    var fixed = alloc_fixed.FixedBuffer.init(scratch.bytes());
    const bytes = captureSources(
        fixed.allocator(),
        sources,
        stage_record,
        configuration,
    ) catch |err|
        return boundedFailure(work, err);
    defer fixed.allocator().free(bytes);
    try work.finish(token, .success, .{ .work = .{ .output_bytes = bytes.len } });
    open = false;
    try builder.capture(bytes, observations);
}

fn verifySources(
    sources: []const Source,
    work: *revision.AccountingV1,
    comptime configuration: Configuration,
) !void {
    const token = try work.begin(.verification, .{
        .identity = .{ .name = "choir-source-structure", .version = 1 },
        .work = .{ .structural_visits = configuration.image.entities },
        .workspace = configuration.gate_scratch,
    });
    errdefer work.finish(token, .rejected, .{}) catch {};
    for (sources, 0..) |source, index| {
        for (sources[0..index]) |other| {
            if (source.operation == other.operation or
                source.operation.isAncestor(other.operation) or
                other.operation.isAncestor(source.operation))
            {
                return error.OverlappingOperationRoots;
            }
        }
        try ir.verifyOperation(source.operation, configuration.verify);
    }
    try work.finish(token, .success, .{});
}

fn captureSources(
    allocator: std.mem.Allocator,
    sources: []const Source,
    stage_record: []const u8,
    comptime configuration: Configuration,
) ![]u8 {
    var writer = revision.record.Writer.init(allocator);
    defer writer.deinit();
    try writer.writeInt(u32, image_version);
    try writer.writeCount(sources.len);
    for (sources) |source| {
        var context = try ir.Context.init(allocator, configuration.context);
        defer context.deinit(allocator);
        context.arithmetic_policy = source.operation.getContext().arithmetic_policy;
        try configuration.register(&context);
        const bytes = try bytecode.qualification.encode(
            allocator,
            source.operation,
            source.resources,
            &context,
            configuration.codec,
        );
        defer allocator.free(bytes);
        if (bytes.len > configuration.image.bytes) return error.RecordLimit;
        try writer.writeBlob(bytes);
    }
    try writer.writeBlob(stage_record);
    if (writer.bytes.items.len > configuration.image.bytes) return error.RecordLimit;
    return writer.finish();
}

fn verifyImage(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    recorded: recipe.Recipe,
    comptime configuration: Configuration,
) !revision.record.EntityCounts {
    var reader = try revision.record.Reader.init(bytes);
    if (try reader.readInt(u32) != image_version) return error.UnknownSchema;
    const roots = try reader.readCount();
    if (roots == 0 or roots > configuration.roots) return error.EmptyOperationProduct;
    var counts: revision.record.EntityCounts = @splat(0);
    counts[@backingInt(revision.record.Namespace.root)] = @intCast(roots);
    for (0..roots) |_| {
        const encoded = try reader.readBlob();
        const index = try bytecode.image.Index.create(allocator, encoded, configuration.image);
        defer index.destroy();
        try addCounts(&counts, index.view());
        var context = try ir.Context.init(allocator, configuration.context);
        defer context.deinit(allocator);
        recorded.restore(&context);
        try configuration.register(&context);
        var decoded = try bytecode.decodeModule(allocator, &context, encoded);
        defer decoded.deinit();
        try ir.verifyOperation(decoded.module, configuration.verify);
    }
    _ = try reader.readBlob();
    if (!reader.atEnd()) return error.InvalidRecord;
    return counts;
}

fn addCounts(counts: *revision.record.EntityCounts, view: bytecode.image.View) !void {
    inline for (.{ "operation", "region", "block", "value", "attribute" }, .{
        view.operations.len,
        view.regions.len,
        view.blocks.len,
        view.values.len,
        view.attributes.len,
    }) |name, count| {
        const namespace = @field(revision.record.Namespace, name);
        const destination = &counts[@backingInt(namespace)];
        destination.* = std.math.add(u32, destination.*, @intCast(count)) catch {
            return error.EntityOverflow;
        };
    }
}

pub const Product = struct {
    revision: *const revision.Revision,

    pub fn seal(builder: *revision.Builder, kind: *const revision.Kind) !Product {
        const published = try builder.seal(kind);
        return .{ .revision = published };
    }

    pub fn retain(self: Product) !Product {
        return .{ .revision = try self.revision.retain() };
    }

    pub fn release(self: Product) void {
        self.revision.release();
    }

    pub fn eql(self: Product, other: Product) bool {
        return self.revision.eql(other.revision);
    }

    pub fn open(
        self: Product,
        allocator: std.mem.Allocator,
        limits: bytecode.image.Limits,
    ) !*entity.Image {
        try self.revision.requireGates(&.{schema_identity});
        return entity.Image.create(allocator, self.revision, limits, image_version);
    }

    pub fn successor(
        self: Product,
        builder: *revision.Builder,
        comptime configuration: Configuration,
    ) !*Job {
        const work = builder.accounting();
        errdefer work.fail(.rejected);
        try builder.requireDependency("source", self.revision);
        try self.revision.requireGates(&.{schema_identity});
        const token = try work.begin(.decode, .{
            .identity = .{ .name = "choir-successor-decode", .version = 1 },
            .work = .{
                .input_bytes = self.revision.view().exact.image.len,
                .structural_visits = configuration.image.entities,
                .allocation_capacity = configuration.gate_scratch,
            },
            .workspace = configuration.gate_scratch,
        });
        errdefer work.finish(token, .rejected, .{}) catch {};
        const lease = try builder.acquireWorkspace(.producer);
        const job = JobData.create(lease, self.revision, configuration) catch |err| {
            lease.release();
            return boundedFailure(work, err);
        };
        errdefer jobData(job).destroy();
        try work.finish(token, .success, .{ .work = .{
            .input_bytes = self.revision.view().exact.image.len,
        } });
        return job;
    }
};

/// A single mutable writer decoded from a retained image into an independent Context.
/// Analyses belong to the new job; no predecessor cache or live IR crosses this boundary.
pub const Job = opaque {
    pub fn destroy(self: *Job) void {
        jobData(self).destroy();
    }

    /// All mutable job allocations consume its pre-reserved producer region.
    pub fn allocator(self: *Job) std.mem.Allocator {
        std.debug.assert(!jobData(self).capturing);
        return jobData(self).allocator;
    }

    /// Borrowed until job destruction; any refused producer allocation is terminal.
    pub fn storageExhaustion(self: *Job) *const bool {
        return &jobData(self).fixed.exhausted;
    }

    /// Physical producer capacity reserved before decoding or executing the successor.
    pub fn storageCapacity(self: *Job) usize {
        return jobData(self).lease.bytes().len;
    }

    /// Refusal in either the outer region or a Context segment exhausts this job.
    pub fn exhausted(self: *Job) bool {
        const state = jobData(self);
        return state.fixed.exhausted or state.context.exhaustedSegment() != null;
    }

    pub fn context(self: *Job) *ir.Context {
        std.debug.assert(!jobData(self).capturing);
        return &jobData(self).context;
    }

    pub fn root(self: *Job, ordinal: u32) ?*ir.Operation {
        const state = jobData(self);
        std.debug.assert(!state.capturing);
        if (ordinal >= state.roots.len) return null;
        return state.roots[ordinal].module;
    }

    pub fn parent(self: *const Job) *const revision.Revision {
        const state: *const JobData = @ptrCast(@alignCast(self));
        return state.parent;
    }

    pub fn capture(
        self: *Job,
        builder: *revision.Builder,
        stage_record: []const u8,
        observations: []const revision.record.Fact,
        comptime configuration: Configuration,
    ) !void {
        const state = jobData(self);
        const work = builder.accounting();
        errdefer work.fail(.rejected);
        if (!builder.ownsWorkspace(state.lease)) return error.ForeignJob;
        if (self.exhausted()) {
            work.fail(.exhausted);
            return error.WorkExhausted;
        }
        std.debug.assert(!state.capturing);
        state.capturing = true;
        defer state.capturing = false;
        const sources = try state.sourceDescriptors(work);
        defer state.allocator.free(sources);
        try @import("root.zig").operation.capture(
            builder,
            sources,
            stage_record,
            observations,
            configuration,
        );
    }
};

const JobData = struct {
    allocator: std.mem.Allocator,
    fixed: alloc_fixed.Tracked,
    lease: revision.store.WorkspaceLease,
    parent: *const revision.Revision,
    context: ir.Context,
    roots: []bytecode.DecodedModule,
    capturing: bool = false,

    fn sourceDescriptors(self: *JobData, work: *revision.AccountingV1) ![]Source {
        const bytes = std.math.mul(usize, self.roots.len, @sizeOf(Source)) catch {
            return error.RecordOverflow;
        };
        const token = try work.begin(.input, .{
            .identity = .{ .name = "choir-root-bindings", .version = 1 },
            .work = .{ .allocation_capacity = bytes },
            .workspace = bytes,
        });
        errdefer work.finish(token, .rejected, .{}) catch {};
        const sources = try self.allocator.alloc(Source, self.roots.len);
        errdefer self.allocator.free(sources);
        for (sources, self.roots) |*source, decoded| source.* = .{
            .operation = decoded.module,
            .resources = decoded.resources,
        };
        try work.finish(token, .success, .{ .work = .{ .allocation_capacity = bytes } });
        return sources;
    }

    fn create(
        lease: revision.store.WorkspaceLease,
        parent: *const revision.Revision,
        comptime configuration: Configuration,
    ) !*Job {
        const retained = try parent.retain();
        errdefer retained.release();
        var initial = alloc_fixed.Tracked.init(lease.bytes());
        const self = try initial.allocator().create(JobData);
        self.* = .{
            .allocator = undefined,
            .fixed = initial,
            .lease = lease,
            .parent = retained,
            .roots = &.{},
            .context = undefined,
        };
        self.allocator = self.fixed.allocator();
        const allocator = self.allocator;
        self.context = try ir.Context.init(allocator, configuration.context);
        errdefer self.context.deinit(allocator);
        (try recipe.decode(parent.inputs().policy)).restore(&self.context);
        try configuration.register(&self.context);
        var reader = try revision.record.Reader.init(parent.view().exact.image);
        if (try reader.readInt(u32) != image_version) return error.UnknownSchema;
        const count = try reader.readCount();
        if (count == 0 or count > configuration.roots) return error.ImageLimit;
        self.roots = try allocator.alloc(bytecode.DecodedModule, count);
        errdefer allocator.free(self.roots);
        var initialized: usize = 0;
        errdefer for (self.roots[0..initialized]) |*decoded| decoded.deinit();
        for (self.roots) |*decoded| {
            decoded.* = try bytecode.decodeModule(allocator, &self.context, try reader.readBlob());
            initialized += 1;
        }
        _ = try reader.readBlob();
        if (!reader.atEnd()) return error.InvalidRecord;
        return @ptrCast(self);
    }

    fn destroy(self: *JobData) void {
        std.debug.assert(!self.capturing);
        for (self.roots) |*decoded| decoded.deinit();
        self.context.deinit(self.allocator);
        self.allocator.free(self.roots);
        self.parent.release();
        const lease = self.lease;
        lease.release();
    }
};

fn jobData(job: *Job) *JobData {
    return @ptrCast(@alignCast(job));
}

fn registerPublicationTest(context: *ir.Context) !void {
    try context.allowUnregistered();
}

const publication_test_configuration = Configuration{
    .context = ir.Context.Limits.testing,
    .register = registerPublicationTest,
    .registration = .{ .name = "unregistered-test-context", .version = 1 },
    .codec = .{ .operations = 100, .entities = 1000, .fields = 1000, .depth = 32 },
    .image = .{ .bytes = 65536, .entities = 1024, .depth = 32 },
    .roots = 4,
    .gate_scratch = 64 * 1024 * 1024,
    .verify = ir.verify.default_options,
};

const publication_test_limits = revision.store.Limits{
    .revisions = 8,
    .kinds = 4,
    .builders = 4,
    .compiler_manifests = 2,
    .record_bytes = 32 * 1024 * 1024,
    .gate_scratch_bytes = publication_test_configuration.gate_scratch,
    .candidate_count = 8,
    .screening_bytes = 32 * 1024 * 1024,
};

fn publishTestTree(
    allocator: std.mem.Allocator,
    store: *revision.Store,
    kind: *const revision.Kind,
    threshold: u8,
    arithmetic: recipe.ArithmeticPolicy,
) !Product {
    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());
    context.arithmetic_policy = arithmetic;
    try registerPublicationTest(&context);
    const tree = try makeTestTree(&context, "product.child");
    try tree.child.setAttr("threshold", try context.getI64Attr(threshold));
    const options = [_]u8{threshold};
    const policy = try recipe.encode(allocator, .{ .arithmetic = arithmetic, .policy = "strict" });
    defer allocator.free(policy);
    const builder = try store.begin(.{
        .kind = kind,
        .address = .{ .producer = "choir", .source = "test", .stage = "operation", .variant = "" },
        .inputs = .{
            .compiler_manifest = try compiler.manifest(),
            .versions = &.{schema_identity},
            .pipeline = &.{},
            .options = &options,
            .policy = policy,
        },
    }, .{
        .allowance = revision.WorkVector.uniform(1024 * 1024 * 1024),
        .workspace = 128 * 1024 * 1024,
        .events = 32,
    });
    var builder_open = true;
    errdefer if (builder_open) {
        if (builder.abort(.rejected)) |failure| {
            var owned = failure;
            owned.deinit();
        }
    };
    try capture(
        builder,
        &.{.{ .operation = tree.root }},
        "stage",
        &.{},
        publication_test_configuration,
    );
    const published = try Product.seal(builder, kind);
    builder_open = false;
    errdefer published.release();
    try tree.child.setAttr("threshold", try context.getI64Attr(255));
    return published;
}

fn beginTestSuccessor(
    store: *revision.Store,
    kind: *const revision.Kind,
    parent: Product,
    workspace: u64,
) !*revision.Builder {
    return store.begin(.{
        .kind = kind,
        .address = .{ .producer = "choir", .source = "test", .stage = "operation", .variant = "" },
        .inputs = .{
            .compiler_manifest = try compiler.manifest(),
            .versions = &.{schema_identity},
            .pipeline = &.{},
            .options = "successor",
            .policy = parent.revision.inputs().policy,
        },
        .parent = parent.revision,
        .dependencies = &.{.{ .role = "source", .revision = parent.revision }},
    }, .{
        .allowance = revision.WorkVector.uniform(1024 * 1024 * 1024),
        .workspace = workspace,
        .events = 32,
    });
}

fn firstChild(root: *ir.Operation) *ir.Operation {
    var operations = root.getRegion(0).?.getEntryBlock().?.getOperations();
    return operations.next().?;
}

fn allocationPublication(allocator: std.mem.Allocator) !void {
    const store = try revision.Store.create(allocator, publication_test_limits);
    defer store.release();
    const kind = try registerKind(allocator, store, publication_test_configuration, .{
        .name = "choir.operation",
        .version = 1,
    }, &.{});
    store.freeze();
    const published = try publishTestTree(allocator, store, kind, 11, .{});
    defer published.release();
    const view = try published.open(allocator, publication_test_configuration.image);
    defer view.destroy();
    try std.testing.expectEqualStrings("product.root", view.root(0).?.operations[0].name);
}

const TestTree = struct {
    root: *ir.Operation,
    region: *ir.Region,
    block: *ir.Block,
    child: *ir.Operation,
    argument: *ir.Value,
    result: *ir.Value,
    attribute: ir.Attribute,
};

fn makeTestTree(context: *ir.Context, name: []const u8) !TestTree {
    const test_dialect = @import("../dialects/fixture/root.zig");
    const location = ir.Location.getUnknown();
    const integer_type = try test_dialect.TestDialect.getI64Type(context);
    var region = ir.context.initRegion(context);
    defer region.deinit();
    const block = try region.addBlock();
    const argument = try block.addArgument(integer_type, location);
    var child_state = ir.Operation.State.init(name, location);
    child_state.addOperands(&.{argument});
    child_state.addTypes(&.{integer_type});
    const child = try context.createOperation(child_state);
    try block.addOperation(child);
    var root_state = ir.Operation.State.init("product.root", location);
    root_state.addRegionBodies(&.{&region});
    const root = try context.createOperation(root_state);
    const leaf = try context.getStringAttr("entity");
    const attribute = try context.getArrayAttr(&.{leaf});
    try child.setAttr("payload", attribute);
    return .{
        .root = root,
        .region = &root.regions.items[0],
        .block = root.getRegion(0).?.getEntryBlock().?,
        .child = child,
        .argument = argument,
        .result = child.getResult(0).?,
        .attribute = leaf,
    };
}

fn checkJobStorageExhaustion(exhaust_context: bool) !void {
    if (compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const store = try revision.Store.create(allocator, publication_test_limits);
    defer store.release();
    const kind = try registerKind(allocator, store, publication_test_configuration, .{
        .name = "choir.operation",
        .version = 1,
    }, &.{});
    store.freeze();
    const ancestor = try publishTestTree(allocator, store, kind, 11, .{});
    defer ancestor.release();
    const capacity = 128 * 1024 * 1024;
    const builder = try beginTestSuccessor(store, kind, ancestor, capacity);
    var open = true;
    defer if (open) {
        if (builder.abort(.rejected)) |failure| {
            var owned = failure;
            owned.deinit();
        }
    };
    const job = try ancestor.successor(builder, publication_test_configuration);
    defer job.destroy();
    if (exhaust_context) {
        const bytes = publication_test_configuration.context.attributes.payload_bytes + 1;
        const payload = try allocator.alloc(u8, bytes);
        defer allocator.free(payload);
        @memset(payload, 'x');
        try std.testing.expectError(error.OutOfMemory, job.context().getStringAttr(payload));
        try std.testing.expect(!job.storageExhaustion().*);
        try std.testing.expectEqual(.attribute_payloads, job.context().exhaustedSegment().?);
    } else {
        try std.testing.expectError(error.OutOfMemory, job.allocator().alloc(u8, capacity + 1));
    }
    try std.testing.expect(job.exhausted());
    const captured = job.capture(builder, "stage", &.{}, publication_test_configuration);
    var failure = builder.abort(.rejected).?;
    open = false;
    defer failure.deinit();
    try std.testing.expectError(error.WorkExhausted, captured);
    try std.testing.expectEqual(.exhausted, failure.work.outcome);
    try std.testing.expectEqual(1, store.publicationCount());
}
