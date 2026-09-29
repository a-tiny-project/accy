const std = @import("std");
const accy = @import("accy");
const choir = @import("choir");
const sys = @import("sys");
const namespace = @import("root.zig");
const host = namespace.host;
const model = namespace.model;
const source = namespace.source;
const publication = namespace.fixture;
const supports_hybrid_host = sys.capabilities.current.supportsX86_64Execution();

test {
    @import("test_discovery").discover(namespace);
}

const composition = choir.composition;
const accy_composition = accy.executable.composition;

const LifecycleRecorder = struct {
    events: [8]composition.LifecycleEvent = undefined,
    count: usize = 0,

    fn observer(self: *LifecycleRecorder) composition.LifecycleObserver {
        return .{
            .ptr = self,
            .record_fn = record,
        };
    }

    fn record(ptr: *anyopaque, event: composition.LifecycleEvent) void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.count < self.events.len);
        self.events[self.count] = event;
        self.count += 1;
    }
};

const InvocationWorker = struct {
    ready: *sys.thread.Semaphore,
    start: *sys.thread.Semaphore,
    entry: composition.Entry,
    invocation: *composition.Invocation,
    status: composition.abi.Status = .fragment_failure,

    fn run(self: *InvocationWorker) void {
        self.ready.post();
        self.start.wait();
        self.status = self.entry.invoke(self.invocation);
    }
};

fn expectInvocationDestroyed(event: composition.LifecycleEvent, id: u64) !void {
    switch (event) {
        .invocation_destroyed => |actual| try std.testing.expectEqual(id, actual),
        else => try std.testing.expect(false),
    }
}

fn expectFragmentDestroyed(event: composition.LifecycleEvent, id: composition.FragmentId) !void {
    switch (event) {
        .fragment_destroyed => |actual| try std.testing.expectEqual(id.value, actual.value),
        else => try std.testing.expect(false),
    }
}

fn expectCompositionDestroyed(event: composition.LifecycleEvent) !void {
    switch (event) {
        .composition_destroyed => {},
        else => try std.testing.expect(false),
    }
}

fn expectOrderedText(text: []const u8, parts: []const []const u8) !void {
    var offset: usize = 0;
    for (parts) |part| {
        const position = std.mem.indexOfPos(u8, text, offset, part);
        try std.testing.expect(position != null);
        offset = position.? + part.len;
    }
}

test "hybrid composition compiles and invokes isolated Choir and Accy fragments" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    if (comptime !supports_hybrid_host) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const fixture_model = model;
    const fixture_source = source;

    var program = try fixture_source.Program.init(allocator);
    var program_owned = true;
    defer if (program_owned) program.deinit();
    try std.testing.expectEqual(@as(usize, 3), program.partitioned.boundaries.items.len);
    try std.testing.expectEqual(@as(usize, 2), program.partitioned.partitions.items.len);
    try std.testing.expectEqual(@as(usize, 1), program.partitioned.call_sites.items.len);

    const lowered_accy = try program.lowerAccy(allocator);
    var semantic_owned = true;
    defer if (semantic_owned) lowered_accy.module.deinit();
    const workspace = try allocator.alloc(u8, publication.artifact_workspace_bytes);
    defer allocator.free(workspace);
    var report = accy.preparation.publication.PreparationReport{};
    defer report.deinit();
    semantic_owned = false;
    var accy_product = try accy_composition.compileCpuObject(
        allocator,
        fixture_source.accy_fragment,
        lowered_accy.module,
        .{ .request = publication.request(fixture_source.source_path, workspace) },
        &report,
        publication.configuration,
    );
    defer accy_product.deinit();
    const accy_input = try program.accyInput(accy_product.input_product);

    try std.testing.expectEqual(@as(usize, 2), accy_product.metadata.input_boundaries.len);
    try std.testing.expectEqual(@as(usize, 1), accy_product.metadata.output_boundaries.len);
    for (accy_product.metadata.input_boundaries) |boundary| {
        try std.testing.expectEqual(composition.ElementType.f32, boundary.element_type);
        try std.testing.expectEqualSlices(u64, &.{8}, boundary.dimensions);
        try std.testing.expectEqual(@as(usize, 32), boundary.byte_size);
    }
    try std.testing.expectEqual(composition.ElementType.f32, accy_product.metadata.output_boundaries[0].element_type);
    try std.testing.expectEqualSlices(u64, &.{8}, accy_product.metadata.output_boundaries[0].dimensions);
    try std.testing.expectEqual(@as(usize, 32), accy_product.metadata.output_boundaries[0].byte_size);
    try std.testing.expectEqual(@as(usize, 1), accy_product.metadata.artifacts.len);
    const accy_export_symbol = accy_product.metadata.entrySymbol() orelse return error.TestExpectedResult;

    var host_product = try host.compile(allocator, &program);
    defer host_product.deinit();

    try std.testing.expectEqual(
        choir.backends.artifact.ArtifactKind.machine_code,
        host_product.artifact.metadata.kind,
    );
    try std.testing.expect(host_product.artifact.linkage.hasProvided(fixture_source.host_symbol));
    try std.testing.expect(host_product.artifact.linkage.hasRequired(composition.abi.invoke_symbol));
    try std.testing.expectEqual(
        choir.backends.artifact.ArtifactKind.object_file,
        accy_product.metadata.artifacts[0].metadata.kind,
    );
    try std.testing.expect(accy_product.metadata.artifacts[0].linkage.hasProvided(accy_export_symbol));

    const host_input = try program.hostInput(host_product.inputProduct());
    var host_plan = try composition.FragmentPlan.init(
        allocator,
        fixture_source.host_fragment,
        host_input,
        fixture_source.host_symbol,
        composition.abi.version,
    );
    var host_plan_owned = true;
    defer if (host_plan_owned) host_plan.deinit();
    var accy_plan = try composition.FragmentPlan.init(
        allocator,
        fixture_source.accy_fragment,
        accy_input,
        accy_export_symbol,
        composition.abi.version,
    );
    var accy_plan_owned = true;
    defer if (accy_plan_owned) accy_plan.deinit();

    try std.testing.expect(host_plan.input.product.eql(host_product.inputProduct()));
    try std.testing.expect(accy_plan.input.product.eql(accy_product.input_product));

    const target_choice = program.cpuTargetChoice();
    var composition_module = try fixture_model.buildComposition(allocator, &program, .{
        .choice = target_choice,
        .host_artifact = &host_product.artifact,
        .host_plan = &host_plan,
        .accy_artifacts = accy_product.metadata.artifacts,
        .accy_plan = &accy_plan,
    });
    var module_owned = true;
    defer if (module_owned) composition_module.deinit();

    const serialized = try composition.serialization.serialize(allocator, &composition_module);
    var serialized_owned = true;
    defer if (serialized_owned) allocator.free(serialized);
    const decoded_module = try composition.serialization.deserialize(allocator, serialized);
    composition_module.deinit();
    composition_module = decoded_module;
    allocator.free(serialized);
    serialized_owned = false;

    const diagnostic = try composition_module.diagnosticPath(fixture_source.composition_variant, program.add.call_site);
    try std.testing.expectEqualStrings(fixture_source.source_path, diagnostic.source.path);
    try std.testing.expectEqualStrings(program.add.symbol, diagnostic.source.symbol);
    try std.testing.expectEqual(fixture_source.accy_partition.value, diagnostic.partition.id.value);
    try std.testing.expectEqualStrings("hybrid/add", diagnostic.partition.name);
    try std.testing.expectEqual(composition.Pipeline.accy, diagnostic.partition.pipeline);
    try std.testing.expect(diagnostic.pipeline_input.eql(accy_plan.input.product));
    try std.testing.expectEqual(fixture_source.accy_fragment.value, diagnostic.fragment.id.value);
    try std.testing.expectEqualStrings(accy_export_symbol, diagnostic.fragment_export.symbol);
    try std.testing.expectEqual(program.add.call_site.value, diagnostic.call_site.id.value);
    try std.testing.expectEqualStrings("hybrid/add", diagnostic.call_site.name);
    try std.testing.expectEqual(
        choir.backends.artifact.ArtifactKind.object_file,
        diagnostic.artifact.metadata.kind,
    );
    try std.testing.expect(choir.backends.artifact.resource.count(diagnostic.artifact.*) != 0);
    const rendered_diagnostic = try composition.diagnostic.renderPathAlloc(
        allocator,
        &composition_module,
        fixture_source.composition_variant,
        program.add.call_site,
    );
    defer allocator.free(rendered_diagnostic);
    const repeated_diagnostic = try composition.diagnostic.renderPathAlloc(
        allocator,
        &composition_module,
        fixture_source.composition_variant,
        program.add.call_site,
    );
    defer allocator.free(repeated_diagnostic);
    try std.testing.expectEqualStrings(rendered_diagnostic, repeated_diagnostic);
    const expected_diagnostic_path = [_][]const u8{
        "composition path: hybrid/add",
        "source",
        "validation/hybrid_composition.tiny:2:5",
        "operation hybrid_accy_add",
        "module hybrid_composition",
        "variant",
        "target validation/validation/hybrid_composition.tiny/cpu-target [x86_64]",
        "policy validation/validation/hybrid_composition.tiny/selection [native]",
        "partition",
        "[11] hybrid/add",
        "input [1] lhs: f32[8], 32 bytes, read, borrowed",
        "input [2] rhs: f32[8], 32 bytes, read, borrowed",
        "output [3] sum: f32[8], 32 bytes, write, produced",
        "pipeline",
        "pipeline input ",
        "pipeline accy",
        "fragment",
        "[21] accy",
        "export add -> ",
        accy_export_symbol,
        "call site",
        "[30] hybrid/add",
        "route [20].entry -> invoke -> [21].add (ABI v1)",
        "caller export entry -> hybrid_composition_host_entry",
        "runtime import invoke -> choir_compose_invoke_v1 (ABI v1)",
        "artifact",
        "object_file",
        "target x86_64",
        "triple x86_64-unknown-linux-gnu",
        "ABI sysv",
        "object format elf",
    };
    try expectOrderedText(rendered_diagnostic, &expected_diagnostic_path);
    for (composition_module.fragments.items) |fragment| {
        try std.testing.expect(fragment.artifacts.len != 0);
        for (fragment.artifacts) |artifact| {
            try std.testing.expect(choir.backends.artifact.resource.count(artifact) != 0);
        }
    }
    const bytecode_resource_count = composition_module.bytecodeResourceCount();
    const bytecode_resources = try allocator.alloc(choir.bytecode.Resource, bytecode_resource_count);
    defer allocator.free(bytecode_resources);
    const written_resources = try composition_module.writeBytecodeResources(bytecode_resources);
    try std.testing.expectEqual(bytecode_resource_count, written_resources.len);
    for (written_resources) |resource| try std.testing.expect(resource.data.len != 0);

    accy_plan.deinit();
    accy_plan_owned = false;
    host_plan.deinit();
    host_plan_owned = false;
    program.deinit();
    program_owned = false;

    var recorder = LifecycleRecorder{};
    const materializers = [_]composition.FragmentMaterializer{
        accy_product.materializer(),
        host.materializer(&host_product),
    };
    module_owned = false;
    const loaded = try composition.LoadedComposition.initOwned(
        allocator,
        composition_module,
        target_choice,
        &materializers,
        recorder.observer(),
    );
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit();
    const entry = try composition.Entry.init(loaded, fixture_source.host_fragment, "entry");

    var first_lhs = [_]f32{ 1, 2, 3, 4, -1.5, 8, 0.25, 16 };
    var first_rhs = [_]f32{ 5, -2, 0.5, 6, 2.5, -3, 0.75, 4 };
    var first_output = @as([8]f32, @splat(-999));
    var second_lhs = [_]f32{ -8, -7, -6, -5, -4, -3, -2, -1 };
    var second_rhs = [_]f32{ 1, 3, 5, 7, 9, 11, 13, 15 };
    var second_output = @as([8]f32, @splat(-999));
    const first_specs = [_]composition.ResourceSpec{
        .{ .bytes = std.mem.sliceAsBytes(first_lhs[0..]), .access = .read },
        .{ .bytes = std.mem.sliceAsBytes(first_rhs[0..]), .access = .read },
        .{ .bytes = std.mem.sliceAsBytes(first_output[0..]), .access = .write },
    };
    const second_specs = [_]composition.ResourceSpec{
        .{ .bytes = std.mem.sliceAsBytes(second_lhs[0..]), .access = .read },
        .{ .bytes = std.mem.sliceAsBytes(second_rhs[0..]), .access = .read },
        .{ .bytes = std.mem.sliceAsBytes(second_output[0..]), .access = .write },
    };

    const first_invocation = try composition.Invocation.init(allocator, loaded, &first_specs);
    var first_invocation_owned = true;
    defer if (first_invocation_owned) first_invocation.deinit();
    const second_invocation = try composition.Invocation.init(allocator, loaded, &second_specs);
    var second_invocation_owned = true;
    defer if (second_invocation_owned) second_invocation.deinit();

    try std.testing.expect(first_invocation.id() != second_invocation.id());
    try std.testing.expect(first_invocation.framePointer() != second_invocation.framePointer());
    const first_resolved = first_invocation.framePointer().resources(loaded.contextPointer());
    const second_resolved = second_invocation.framePointer().resources(loaded.contextPointer());
    try std.testing.expect(first_resolved == .value);
    try std.testing.expect(second_resolved == .value);
    try std.testing.expect(first_resolved.value.ptr != second_resolved.value.ptr);
    for (first_resolved.value, second_resolved.value) |first_resource, second_resource| {
        try std.testing.expect(first_resource.handle != second_resource.handle);
        try std.testing.expect(first_resource.invocation_id != second_resource.invocation_id);
    }
    try std.testing.expectEqual(@as(u64, 2), loaded.activeInvocationCount());

    var ready: sys.thread.Semaphore = .{};
    var start: sys.thread.Semaphore = .{};
    var first_worker = InvocationWorker{
        .ready = &ready,
        .start = &start,
        .entry = entry,
        .invocation = first_invocation,
    };
    var second_worker = InvocationWorker{
        .ready = &ready,
        .start = &start,
        .entry = entry,
        .invocation = second_invocation,
    };
    const first_thread = try sys.thread.spawn(InvocationWorker.run, .{&first_worker});
    var first_thread_joined = false;
    errdefer if (!first_thread_joined) {
        start.post();
        first_thread.join();
    };
    const second_thread = try sys.thread.spawn(InvocationWorker.run, .{&second_worker});
    var second_thread_joined = false;
    errdefer if (!second_thread_joined) {
        start.post();
        second_thread.join();
    };
    ready.wait();
    ready.wait();
    start.post();
    start.post();
    first_thread.join();
    first_thread_joined = true;
    second_thread.join();
    second_thread_joined = true;

    try std.testing.expectEqual(composition.abi.Status.ok, first_worker.status);
    try std.testing.expectEqual(composition.abi.Status.ok, second_worker.status);
    try std.testing.expectEqual(composition.abi.Status.ok, first_invocation.status());
    try std.testing.expectEqual(composition.abi.Status.ok, second_invocation.status());
    try std.testing.expectEqualSlices(
        f32,
        &.{ 6, 0, 3.5, 10, 1, 5, 1, 20 },
        &first_output,
    );
    try std.testing.expectEqualSlices(
        f32,
        &.{ -7, -4, -1, 2, 5, 8, 11, 14 },
        &second_output,
    );

    const loaded_accy = loaded.loadedFragment(fixture_source.accy_fragment) orelse return error.TestExpectedResult;
    const runtime_evidence = try accy_composition.runtimeEvidence(loaded_accy);
    try std.testing.expectEqual(@as(u64, 2), runtime_evidence.invocation_count);
    try std.testing.expectEqual(@as(u64, 2), runtime_evidence.completed_invocation_count);
    try std.testing.expectEqual(@as(u64, 0), runtime_evidence.failed_invocation_count);
    try std.testing.expectEqual(@as(usize, 1), runtime_evidence.loaded_artifact_count);
    try std.testing.expectEqual(@as(usize, 0), runtime_evidence.live_buffer_count);

    const first_id = first_invocation.id();
    const second_id = second_invocation.id();
    second_invocation.deinit();
    second_invocation_owned = false;
    try std.testing.expectEqual(@as(u64, 1), loaded.activeInvocationCount());
    first_invocation.deinit();
    first_invocation_owned = false;
    try std.testing.expectEqual(@as(u64, 0), loaded.activeInvocationCount());
    loaded.deinit();
    loaded_owned = false;

    try std.testing.expectEqual(@as(usize, 5), recorder.count);
    try expectInvocationDestroyed(recorder.events[0], second_id);
    try expectInvocationDestroyed(recorder.events[1], first_id);
    try expectFragmentDestroyed(recorder.events[2], fixture_source.host_fragment);
    try expectFragmentDestroyed(recorder.events[3], fixture_source.accy_fragment);
    try expectCompositionDestroyed(recorder.events[4]);
}

test "accy validation composition declaration coverage" {
    std.testing.refAllDecls(namespace);
}
