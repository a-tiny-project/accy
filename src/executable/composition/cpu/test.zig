const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const sys = @import("sys");
const accy_root = @import("../../../root.zig");
const fixture = @import("../../../fixture/root.zig");
const executable = @import("../../root.zig");
const composition = @import("../root.zig");
const namespace = @import("root.zig");
const compilation = namespace.compilation;
const materialization = namespace.materialization;
const runtime = namespace.runtime;
const compileCpuObject = namespace.compileCpuObject;
const materializeCpuObject = namespace.materializeCpuObject;
const runtimeEvidence = namespace.runtimeEvidence;

const Allocator = std.mem.Allocator;
const accy = accy_root.choir;
const ChoirComposition = choir.composition;
const publication = fixture.publication;

fn addSemanticModule(allocator: Allocator, name: []const u8) !*accy.SemanticModule {
    var builder = try accy.SemanticBuilder.init(
        allocator,
        accy.SemanticBuilder.ContextLimits.standard,
    );
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var function = try builder.beginFunction(name, &.{ f32_8, f32_8 }, &.{f32_8});
    const sum = try function.add(function.parameter(0), function.parameter(1));
    try function.return_(&.{sum});
    try function.finish();
    return try builder.finish();
}

const InvocationWorker = struct {
    fragment: ChoirComposition.LoadedFragment,
    call_site: *const ChoirComposition.CallSite,
    context: *ChoirComposition.abi.Context,
    frame: *ChoirComposition.abi.Frame,
    status: ChoirComposition.abi.Status = .fragment_failure,

    fn run(self: *InvocationWorker) void {
        self.status = self.fragment.vtable.invoke.?(
            self.fragment.state,
            self.call_site,
            self.context,
            self.frame,
        );
    }
};

test "Accy composition CPU object compilation consumes semantic module on first allocation failure" {
    const module = try addSemanticModule(std.testing.allocator, "composition_cpu_object_oom");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    failing.fail_index = failing.alloc_index;
    var report = accy_root.preparation.publication.PreparationReport{};
    defer report.deinit();
    try std.testing.expectError(error.OutOfMemory, compileCpuObject(
        failing.allocator(),
        .{ .value = 23 },
        module,
        .{
            .request = publication.request("composition_cpu_object_oom", &.{}),
            .compiler = .{ .launch_tuning_artifact = &.{1} },
        },
        &report,
        publication.configuration,
    ));
}

test "Accy composition CPU object exhaustion consumes its draft without native success" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const module = try addSemanticModule(std.testing.allocator, "composition_cpu_exhausted");
    var report = accy_root.preparation.publication.PreparationReport{};
    defer report.deinit();
    var request = publication.request("composition_cpu_exhausted", &.{});
    request.work.allowance.structural_visits = 0;
    try std.testing.expectError(error.WorkExhausted, compileCpuObject(
        std.testing.allocator,
        .{ .value = 24 },
        module,
        .{ .request = request },
        &report,
        publication.configuration,
    ));
    try std.testing.expectEqual(@as(u8, 0), report.completed);
    const failure = report.failure orelse return error.TestExpectedResult;
    try std.testing.expectEqual(.exhausted, failure.work.outcome);
}

test "Accy composition CPU object metadata survives every allocation failure" {
    const allocator = std.testing.allocator;
    const semantic_module = try addSemanticModule(allocator, "composition_cpu_metadata_oom");
    var backend_state = gpu.cpu.State.init(allocator);
    defer backend_state.deinit();
    const compiled_fragment = executable.compileFragmentFromSemanticModule(
        allocator,
        backend_state.handle(),
        semantic_module,
        .{ .artifact_format = .cpu_object },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer compiled_fragment.deinit();

    const Harness = struct {
        fn run(
            failing_allocator: Allocator,
            fragment: *const executable.CompiledFragment,
        ) !void {
            var metadata = try composition.CpuObjectMetadata.init(failing_allocator, fragment);
            defer metadata.deinit();
        }
    };
    try fixture.checkAllAllocationFailures(Harness.run, .{compiled_fragment});
}

test "Accy composition CPU object retains artifacts and isolates concurrent invocations" {
    if (choir.product.compiler.unrecorded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const semantic_module = try addSemanticModule(allocator, "composition_cpu_object_add");
    const launch_tuning_artifact = try executable.encodeLaunchTuningArtifact(allocator, &.{});
    defer allocator.free(launch_tuning_artifact);
    const workspace = try allocator.alloc(u8, publication.artifact_workspace_bytes);
    defer allocator.free(workspace);
    var report = accy_root.preparation.publication.PreparationReport{};
    defer report.deinit();
    var compilation_value = compileCpuObject(allocator, .{ .value = 23 }, semantic_module, .{
        .request = publication.request("composition_cpu_object_add", workspace),
        .compiler = .{ .launch_tuning_artifact = launch_tuning_artifact },
    }, &report, publication.configuration) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer compilation_value.deinit();
    try std.testing.expectEqual(@as(u8, 7), report.completed);
    try std.testing.expect(compilation_value.input_product.record.eql(
        report.stages[0].record().metadata(),
    ));
    report.deinit();
    @memset(workspace, 0xa5);
    try compilation_value.input_product.validate();
    try std.testing.expect(
        compilation_value.launch_tuning_artifact.ptr != launch_tuning_artifact.ptr,
    );

    try std.testing.expectEqual(@as(usize, 1), compilation_value.metadata.artifacts.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        choir.backends.artifact.resource.count(compilation_value.metadata.artifacts[0]),
    );
    try std.testing.expectEqual(
        choir.backends.artifact.ArtifactKind.object_file,
        compilation_value.metadata.artifacts[0].metadata.kind,
    );
    try std.testing.expectEqual(@as(usize, 2), compilation_value.metadata.input_boundaries.len);
    try std.testing.expectEqual(@as(usize, 1), compilation_value.metadata.output_boundaries.len);
    for (compilation_value.metadata.input_boundaries) |boundary| {
        try std.testing.expectEqual(ChoirComposition.ElementType.f32, boundary.element_type);
        try std.testing.expectEqualSlices(u64, &.{8}, boundary.dimensions);
        try std.testing.expectEqual(@as(usize, 32), boundary.byte_size);
    }
    try std.testing.expectEqual(
        ChoirComposition.ElementType.f32,
        compilation_value.metadata.output_boundaries[0].element_type,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{8},
        compilation_value.metadata.output_boundaries[0].dimensions,
    );
    try std.testing.expectEqual(
        @as(usize, 32),
        compilation_value.metadata.output_boundaries[0].byte_size,
    );
    const entry_symbol = compilation_value.metadata.entrySymbol() orelse
        return error.TestExpectedResult;
    try std.testing.expect(entry_symbol.len != 0);
    try std.testing.expect(
        compilation_value.metadata.artifacts[0].linkage.hasProvided(entry_symbol),
    );

    var source_module = try ChoirComposition.PartitionedModule.init(
        allocator,
        "composition_cpu_object",
    );
    defer source_module.deinit();
    try source_module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "lhs",
        .element_type = .f32,
        .dimensions = &.{8},
        .byte_size = 32,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "composition", .symbol = "lhs" },
    });
    try source_module.addBoundary(.{
        .id = .{ .value = 2 },
        .name = "rhs",
        .element_type = .f32,
        .dimensions = &.{8},
        .byte_size = 32,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "composition", .symbol = "rhs" },
    });
    try source_module.addBoundary(.{
        .id = .{ .value = 3 },
        .name = "sum",
        .element_type = .f32,
        .dimensions = &.{8},
        .byte_size = 32,
        .access = .write,
        .ownership = .produced,
        .alias = .disjoint,
        .provenance = .{ .path = "composition", .symbol = "sum" },
    });
    try source_module.addPartition(.{
        .id = .{ .value = 13 },
        .name = "add",
        .pipeline = .accy,
        .inputs = &.{ .{ .value = 1 }, .{ .value = 2 } },
        .outputs = &.{.{ .value = 3 }},
        .product = compilation_value.input_product.ref,
        .effect = .none,
        .provenance = .{ .path = "composition", .symbol = "add" },
    });
    var durable_module = try ChoirComposition.CompositionModule.init(allocator, &source_module);
    defer durable_module.deinit();
    try durable_module.addFragment(.{
        .id = compilation_value.fragment_id,
        .partition = .{ .value = 13 },
        .pipeline = .accy,
        .pipeline_input = compilation_value.input_product,
        .artifacts = compilation_value.metadata.artifacts,
        .exports = &.{
            .{ .name = "add", .symbol = entry_symbol, .abi_version = ChoirComposition.abi.version },
        },
        .provenance = .{ .path = "composition", .symbol = "add" },
    });
    try durable_module.addVariant(.{
        .id = .{ .value = 1 },
        .choice = .{
            .target = choir.product.productRef("composition", "cpu", "target", "x86_64"),
            .policy = choir.product.productRef("composition", "cpu", "selection", "native"),
        },
        .fragments = &.{compilation_value.fragment_id},
        .call_sites = &.{},
    });
    const durable_fragment = durable_module.fragment(compilation_value.fragment_id) orelse
        return error.TestExpectedResult;
    const durable_lhs = &durable_module.source_module.boundaries.items[0];
    const original_element_type = durable_lhs.element_type;
    durable_lhs.element_type = .i32;
    const type_mismatch = materializeCpuObject(
        &compilation_value,
        allocator,
        &durable_module,
        durable_fragment,
    );
    durable_lhs.element_type = original_element_type;
    try std.testing.expectError(error.BoundaryMismatch, type_mismatch);

    const original_dimensions = durable_lhs.dimensions;
    const mismatched_dimensions = [_]u64{ 4, 2 };
    durable_lhs.dimensions = &mismatched_dimensions;
    const shape_mismatch = materializeCpuObject(
        &compilation_value,
        allocator,
        &durable_module,
        durable_fragment,
    );
    durable_lhs.dimensions = original_dimensions;
    try std.testing.expectError(error.BoundaryMismatch, shape_mismatch);

    const materialization_allocation_count = 3;
    for (0..materialization_allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(
            error.OutOfMemory,
            materializeCpuObject(
                &compilation_value,
                failing.allocator(),
                &durable_module,
                durable_fragment,
            ),
        );
        try std.testing.expect(compilation_value.compiled_fragment != null);
    }

    const materialized = try materializeCpuObject(
        &compilation_value,
        allocator,
        &durable_module,
        durable_fragment,
    );
    try std.testing.expect(compilation_value.compiled_fragment == null);
    const loaded_fragment = ChoirComposition.LoadedFragment{
        .id = compilation_value.fragment_id,
        .state = materialized.state,
        .vtable = materialized.vtable,
    };
    defer loaded_fragment.vtable.deinit(loaded_fragment.state, allocator);

    var provenance = try ChoirComposition.Provenance.init(
        allocator,
        .{ .path = "composition", .symbol = "add" },
    );
    defer provenance.deinit(allocator);
    const call_site = ChoirComposition.CallSite{
        .id = .{ .value = 41 },
        .name = "add",
        .caller = .{ .value = 11 },
        .caller_export = "host",
        .runtime_import = ChoirComposition.abi.invoke_symbol,
        .callee = loaded_fragment.id,
        .callee_export = "composition_cpu_object_add",
        .inputs = &.{ .{ .value = 1 }, .{ .value = 2 } },
        .outputs = &.{.{ .value = 3 }},
        .abi_version = ChoirComposition.abi.version,
        .provenance = provenance,
    };

    var context = ChoirComposition.abi.Context.init(0x1000, 0x2000);
    var first_lhs = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var first_rhs = [_]f32{ 8, 7, 6, 5, 4, 3, 2, 1 };
    var first_output = @as([8]f32, @splat(0));
    var first_resources = [_]ChoirComposition.abi.Resource{
        ChoirComposition.abi.Resource.init(
            context.owner_cookie,
            1,
            std.mem.sliceAsBytes(first_lhs[0..]),
            .read,
        ),
        ChoirComposition.abi.Resource.init(
            context.owner_cookie,
            1,
            std.mem.sliceAsBytes(first_rhs[0..]),
            .read,
        ),
        ChoirComposition.abi.Resource.init(
            context.owner_cookie,
            1,
            std.mem.sliceAsBytes(first_output[0..]),
            .write,
        ),
    };
    var first_frame = ChoirComposition.abi.Frame.init(context.owner_cookie, 1, &first_resources);
    first_resources[2].access = @backingInt(ChoirComposition.Access.read);
    try std.testing.expectEqual(
        ChoirComposition.abi.Status.invalid_resource,
        loaded_fragment.vtable.invoke.?(
            loaded_fragment.state,
            &call_site,
            &context,
            &first_frame,
        ),
    );
    first_resources[2].access = @backingInt(ChoirComposition.Access.write);

    var second_lhs = [_]f32{ -1, -2, -3, -4, 9, 10, 11, 12 };
    var second_rhs = [_]f32{ 2, 4, 6, 8, -1, -2, -3, -4 };
    var second_output = @as([8]f32, @splat(0));
    var second_resources = [_]ChoirComposition.abi.Resource{
        ChoirComposition.abi.Resource.init(
            context.owner_cookie,
            2,
            std.mem.sliceAsBytes(second_lhs[0..]),
            .read,
        ),
        ChoirComposition.abi.Resource.init(
            context.owner_cookie,
            2,
            std.mem.sliceAsBytes(second_rhs[0..]),
            .read,
        ),
        ChoirComposition.abi.Resource.init(
            context.owner_cookie,
            2,
            std.mem.sliceAsBytes(second_output[0..]),
            .write,
        ),
    };
    var second_frame = ChoirComposition.abi.Frame.init(context.owner_cookie, 2, &second_resources);

    var first_worker = InvocationWorker{
        .fragment = loaded_fragment,
        .call_site = &call_site,
        .context = &context,
        .frame = &first_frame,
    };
    var second_worker = InvocationWorker{
        .fragment = loaded_fragment,
        .call_site = &call_site,
        .context = &context,
        .frame = &second_frame,
    };
    const first_thread = try sys.thread.spawn(InvocationWorker.run, .{&first_worker});
    const second_thread = sys.thread.spawn(InvocationWorker.run, .{&second_worker}) catch |err| {
        first_thread.join();
        return err;
    };
    first_thread.join();
    second_thread.join();

    try std.testing.expectEqual(ChoirComposition.abi.Status.ok, first_worker.status);
    try std.testing.expectEqual(ChoirComposition.abi.Status.ok, second_worker.status);
    for (first_output, 0..) |value, index| {
        try std.testing.expectEqual(first_lhs[index] + first_rhs[index], value);
    }
    for (second_output, 0..) |value, index| {
        try std.testing.expectEqual(second_lhs[index] + second_rhs[index], value);
    }

    const evidence = try runtimeEvidence(loaded_fragment);
    try std.testing.expectEqual(@as(u64, 2), evidence.invocation_count);
    try std.testing.expectEqual(@as(u64, 2), evidence.completed_invocation_count);
    try std.testing.expectEqual(@as(u64, 0), evidence.failed_invocation_count);
    try std.testing.expectEqual(@as(usize, 1), evidence.loaded_artifact_count);
    try std.testing.expectEqual(@as(usize, 0), evidence.live_buffer_count);
}

test {
    @import("test_discovery").discover(namespace);
    _ = compilation;
    _ = materialization;
    _ = runtime;
}

test "accy executable composition cpu declaration coverage" {
    std.testing.refAllDecls(namespace);
}
