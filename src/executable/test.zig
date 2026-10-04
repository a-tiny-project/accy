const namespace = @import("root.zig");
const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const exec_product = @import("plan.zig");
const tuning_mod = @import("tuning.zig");
const binding_mod = @import("binding.zig");
const loaded_mod = @import("loaded.zig");
const fixture = @import("fixture.zig");
const passes = choir.passes;
const LaunchCandidateMeasurement = tuning_mod.LaunchCandidateMeasurement;
const LaunchTuningSelection = tuning_mod.LaunchTuningSelection;
const launch_tuning_cache_record_version = tuning_mod.launch_tuning_cache_record_version;
const LaunchTuningCacheRecord = tuning_mod.LaunchTuningCacheRecord;
const encodeLaunchTuningArtifact = tuning_mod.encodeLaunchTuningArtifact;
const decodeLaunchTuningArtifact = tuning_mod.decodeLaunchTuningArtifact;
const LaunchTuningCacheKey = tuning_mod.LaunchTuningCacheKey;
const LaunchTuningCache = tuning_mod.LaunchTuningCache;
const LaunchGraphNode = exec_product.LaunchGraphNode;
const LaunchGraphDependency = exec_product.LaunchGraphDependency;
const LaunchGraphLoopCarry = exec_product.LaunchGraphLoopCarry;
const LaunchGraphLoop = exec_product.LaunchGraphLoop;
const createDataflowLaunchGraphPlan = exec_product.createDataflowLaunchGraphPlan;
const loadKernels = loaded_mod.loadKernels;
const RecordingBackendState = gpu.recording.BackendState;
const addChoirModule = fixture.addChoirModule;
const escapedTwoKernelChoirModule = fixture.escapedTwoKernelChoirModule;
const createTestBackendArtifactPlan = fixture.createTestBackendArtifactPlan;
const slotBindingsForKernel = fixture.slotBindingsForKernel;
const slotBindingsForPlan = fixture.slotBindingsForPlan;
const elementCountBindingsForPlan = fixture.elementCountBindingsForPlan;
const firstElementCountBinding = fixture.firstElementCountBinding;
const testing = std.testing;

test {
    _ = @import("composition/test.zig");
    @import("test_discovery").discover(namespace);
    @import("test_discovery").discover(namespace.fragment);
    @import("test_discovery").discover(namespace.composition);
    @import("test_discovery").discover(namespace.compiler);
    @import("test_discovery").discover(namespace.invocation);
    @import("test_discovery").discover(namespace.schedule);
}

test "accy executable declaration coverage" {
    std.testing.refAllDecls(namespace);
    std.testing.refAllDecls(namespace.fragment);
    std.testing.refAllDecls(namespace.composition);
    std.testing.refAllDecls(namespace.compiler);
    std.testing.refAllDecls(namespace.invocation);
    std.testing.refAllDecls(namespace.schedule);
}

test "Choir executable launch graph forwards per-kernel stream event dependencies" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(allocator, "choir_cuda_executable_launch_graph");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();
    try testing.expectEqual(@as(usize, 2), artifact_plan.kernelCount());

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    const stream_a = gpu.StreamHandle{ .id = 71, .backend = .cuda };
    const stream_b = gpu.StreamHandle{ .id = 72, .backend = .cuda };
    const dependency = gpu.EventHandle{ .id = 91, .backend = .cuda };
    const done = gpu.EventHandle{ .id = 92, .backend = .cuda };
    const second_waits = [_]gpu.EventHandle{dependency};
    const nodes = [_]LaunchGraphNode{
        .{
            .kernel_index = 0,
            .stream = stream_a,
            .signal_event = dependency,
        },
        .{
            .kernel_index = 1,
            .stream = stream_b,
            .wait_events = &second_waits,
            .signal_event = done,
        },
    };
    const dependencies = [_]LaunchGraphDependency{.{
        .producer_node_index = 0,
        .consumer_node_index = 1,
        .slot_id = artifact_plan.kernels.items[0].output_slot_id,
    }};

    try executable.launchGraph(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        .{
            .nodes = &nodes,
            .dependencies = &dependencies,
        },
    );

    const lowered_dependency = state.created_events[0];
    try testing.expectEqual(@as(usize, 2), state.launch_count);
    try testing.expectEqual(@as(usize, 1), state.created_event_count);
    try testing.expectEqual(@as(gpu.BackendObjectId, 71), state.launch_streams[0].?);
    try testing.expectEqual(@as(gpu.BackendObjectId, 91), state.launch_signal_events[0].?);
    try testing.expectEqual(@as(gpu.BackendObjectId, 72), state.launch_streams[1].?);
    try testing.expectEqual(@as(usize, 2), state.launch_wait_counts[1]);
    try testing.expectEqual(@as(gpu.BackendObjectId, 91), state.launch_wait_events[1][0]);
    try testing.expectEqual(lowered_dependency, state.launch_wait_events[1][1]);
    try testing.expectEqual(@as(gpu.BackendObjectId, 92), state.launch_signal_events[1].?);
}

test "Choir executable launch graph host loops remap carry slots" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(
        allocator,
        "choir_cuda_executable_launch_graph_host_loop",
    );
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();
    try testing.expectEqual(@as(usize, 2), artifact_plan.kernelCount());

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    const initial_slot_id = artifact_plan.kernels.items[0].input_slot_ids[0];
    const output_slot_id = artifact_plan.kernels.items[1].output_slot_id;
    const carry = [_]LaunchGraphLoopCarry{.{
        .initial_slot_id = initial_slot_id,
        .input_slot_id = initial_slot_id,
        .output_slot_id = output_slot_id,
        .final_slot_id = output_slot_id,
    }};
    const loops = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = graph.nodes.len,
        .trip_count = 3,
        .carries = &carry,
    }};

    try executable.launchGraph(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        .{
            .nodes = graph.nodes,
            .dependencies = graph.dependencies,
            .loops = &loops,
        },
    );

    const initial_binding = try binding_mod.bindingForSlot(
        slot_bindings,
        initial_slot_id,
        .read_only,
    );
    const output_binding = try binding_mod.bindingForSlot(
        slot_bindings,
        output_slot_id,
        .read_only,
    );

    try testing.expectEqual(@as(usize, 6), state.launch_count);
    try testing.expect(state.launch_buffer_counts[0] >= 2);
    try testing.expect(state.launch_buffer_counts[1] >= 1);
    try testing.expectEqual(initial_binding.handle.id, state.launch_buffer_ids[0][1]);
    try testing.expectEqual(output_binding.handle.id, state.launch_buffer_ids[1][0]);
    try testing.expectEqual(output_binding.handle.id, state.launch_buffer_ids[2][1]);
    try testing.expectEqual(initial_binding.handle.id, state.launch_buffer_ids[3][0]);
    try testing.expectEqual(initial_binding.handle.id, state.launch_buffer_ids[4][1]);
    try testing.expectEqual(output_binding.handle.id, state.launch_buffer_ids[5][0]);
}

test "Choir executable launch graph lowers dependencies to backend events" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(
        allocator,
        "choir_cuda_executable_launch_graph_event_lowering",
    );
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();
    try testing.expectEqual(@as(usize, 2), artifact_plan.kernelCount());

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();
    graph.nodes[0].stream = .{ .id = 71, .backend = .cuda };
    graph.nodes[1].stream = .{ .id = 72, .backend = .cuda };

    try executable.launchGraphWithDependencyEvents(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        graph.plan(),
    );

    try testing.expectEqual(@as(usize, 1), state.created_event_count);
    const dependency_event = state.created_events[0];
    try testing.expectEqual(@as(usize, 2), state.launch_count);
    try testing.expectEqual(@as(gpu.BackendObjectId, 71), state.launch_streams[0].?);
    try testing.expectEqual(@as(gpu.BackendObjectId, 72), state.launch_streams[1].?);
    try testing.expectEqual(@as(usize, 1), state.launch_wait_counts[1]);
    try testing.expectEqual(dependency_event, state.launch_wait_events[1][0]);
    try testing.expectEqual(@as(usize, 1), state.record_event_count);
    try testing.expectEqual(@as(gpu.BackendObjectId, 71), state.record_streams[0].?);
    try testing.expectEqual(dependency_event, state.record_events[0].?);
}

test "Choir executable launch graph automatically lowers cross-stream dependencies" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(
        allocator,
        "choir_cuda_executable_launch_graph_auto_events",
    );
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();
    try testing.expectEqual(@as(usize, 2), artifact_plan.kernelCount());

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();
    graph.nodes[0].stream = .{ .id = 71, .backend = .cuda };
    graph.nodes[1].stream = .{ .id = 72, .backend = .cuda };

    try executable.launchGraph(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        graph.plan(),
    );

    try testing.expectEqual(@as(usize, 1), state.created_event_count);
    const dependency_event = state.created_events[0];
    try testing.expectEqual(@as(usize, 2), state.launch_count);
    try testing.expectEqual(@as(gpu.BackendObjectId, 71), state.launch_streams[0].?);
    try testing.expectEqual(@as(gpu.BackendObjectId, 72), state.launch_streams[1].?);
    try testing.expectEqual(@as(usize, 1), state.launch_wait_counts[1]);
    try testing.expectEqual(dependency_event, state.launch_wait_events[1][0]);
    try testing.expectEqual(@as(usize, 1), state.record_event_count);
    try testing.expectEqual(@as(gpu.BackendObjectId, 71), state.record_streams[0].?);
    try testing.expectEqual(dependency_event, state.record_events[0].?);
}

test "Choir executable dependency event lowering requires producer streams" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(
        allocator,
        "choir_cuda_executable_launch_graph_event_stream",
    );
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();
    graph.nodes[1].stream = .{ .id = 72, .backend = .cuda };

    try testing.expectError(
        error.LaunchArgumentMismatch,
        executable.launchGraphWithDependencyEvents(
            allocator,
            &artifact_plan,
            slot_bindings,
            &.{},
            graph.plan(),
        ),
    );
    try testing.expectEqual(@as(usize, 0), state.created_event_count);
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "Choir executable launch graph validates complete unique kernel nodes before launch" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(
        allocator,
        "choir_cuda_executable_launch_graph_invalid",
    );
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();
    try testing.expectEqual(@as(usize, 2), artifact_plan.kernelCount());

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);

    const duplicate_nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 0 },
        .{ .kernel_index = 0 },
    };
    try testing.expectError(
        error.InvalidArtifact,
        executable.launchGraph(
            allocator,
            &artifact_plan,
            slot_bindings,
            &.{},
            .{ .nodes = &duplicate_nodes },
        ),
    );

    const missing_nodes = [_]LaunchGraphNode{.{ .kernel_index = 0 }};
    try testing.expectError(
        error.InvalidArtifact,
        executable.launchGraph(
            allocator,
            &artifact_plan,
            slot_bindings,
            &.{},
            .{ .nodes = &missing_nodes },
        ),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "Choir executable launch graph validates dependency indices before launch" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(
        allocator,
        "choir_cuda_executable_launch_graph_bad_dependency",
    );
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();
    try testing.expectEqual(@as(usize, 2), artifact_plan.kernelCount());

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);

    const nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 0 },
        .{ .kernel_index = 1 },
    };
    const dependencies = [_]LaunchGraphDependency{.{
        .producer_node_index = 0,
        .consumer_node_index = 2,
        .slot_id = artifact_plan.kernels.items[0].output_slot_id,
    }};

    try testing.expectError(
        error.InvalidArtifact,
        executable.launchGraph(
            allocator,
            &artifact_plan,
            slot_bindings,
            &.{},
            .{
                .nodes = &nodes,
                .dependencies = &dependencies,
            },
        ),
    );

    const mismatched_dependencies = [_]LaunchGraphDependency{.{
        .producer_node_index = 0,
        .consumer_node_index = 1,
        .slot_id = artifact_plan.kernels.items[1].output_slot_id,
    }};
    try testing.expectError(
        error.InvalidArtifact,
        executable.launchGraph(
            allocator,
            &artifact_plan,
            slot_bindings,
            &.{},
            .{
                .nodes = &nodes,
                .dependencies = &mismatched_dependencies,
            },
        ),
    );

    const reversed_nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 1 },
        .{ .kernel_index = 0 },
    };
    const reversed_dependencies = [_]LaunchGraphDependency{.{
        .producer_node_index = 1,
        .consumer_node_index = 0,
        .slot_id = artifact_plan.kernels.items[0].output_slot_id,
    }};
    try testing.expectError(
        error.InvalidArtifact,
        executable.launchGraph(
            allocator,
            &artifact_plan,
            slot_bindings,
            &.{},
            .{
                .nodes = &reversed_nodes,
                .dependencies = &reversed_dependencies,
            },
        ),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "Choir executable plan launches fastest measured candidate" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_measured_candidate");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    const measurements = [_]LaunchCandidateMeasurement{
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    };

    try executable.launchAllWithOptions(allocator, &artifact_plan, slot_bindings, count_bindings, .{
        .tuning = .{ .measurements = &measurements },
    });

    const selected = kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable launch tuning selections override measurements" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_selected_candidate");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    const measurements = [_]LaunchCandidateMeasurement{.{
        .kernel_id = kernel.kernel_id,
        .candidate_index = 0,
        .median_ns = 1,
        .sample_count = 8,
    }};
    const selections = [_]LaunchTuningSelection{.{
        .kernel_id = kernel.kernel_id,
        .candidate_index = 1,
        .median_ns = 200,
        .sample_count = 4,
    }};

    try executable.launchAllWithOptions(allocator, &artifact_plan, slot_bindings, count_bindings, .{
        .tuning = .{
            .selections = &selections,
            .measurements = &measurements,
        },
    });

    const selected = kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);

    const duplicate_selections = [_]LaunchTuningSelection{ selections[0], selections[0] };
    try testing.expectError(
        error.LaunchArgumentMismatch,
        executable.launchAllWithOptions(allocator, &artifact_plan, slot_bindings, count_bindings, .{
            .tuning = .{ .selections = &duplicate_selections },
        }),
    );
    try testing.expectEqual(@as(usize, 1), state.launch_count);
}

test "Choir executable launch graph persists measured tuning selections" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_graph_tuning");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    const measurements = [_]LaunchCandidateMeasurement{
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    };

    try graph.applyMeasuredLaunchTuning(&artifact_plan, &measurements);

    try testing.expectEqual(@as(usize, 1), graph.tuning_selections.len);
    try testing.expectEqual(kernel.kernel_id, graph.tuning_selections[0].kernel_id);
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections[0].candidate_index);
    try testing.expectEqual(@as(u64, 200), graph.tuning_selections[0].median_ns);
    try testing.expectEqual(@as(u32, 4), graph.tuning_selections[0].sample_count);
    try testing.expectEqual(@as(usize, 1), graph.nodes[0].tuning.selections.len);
    try testing.expectEqual(@as(usize, 0), graph.nodes[0].tuning.measurements.len);
    try testing.expectEqual(
        @intFromPtr(graph.tuning_selections.ptr),
        @intFromPtr(graph.nodes[0].tuning.selections.ptr),
    );

    try executable.launchGraph(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        graph.plan(),
    );

    const selected = kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable launch tuning cache applies measured graph selections" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_graph_tuning_cache");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const caps = try handle.queryCapabilities();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    var tuning_cache = LaunchTuningCache.init(allocator);
    defer tuning_cache.deinit();

    const measurements = [_]LaunchCandidateMeasurement{
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    };
    try tuning_cache.recordMeasurements(caps, &artifact_plan, &measurements);
    try testing.expectEqual(@as(usize, 1), tuning_cache.count());

    const slower_measurements = [_]LaunchCandidateMeasurement{.{
        .kernel_id = kernel.kernel_id,
        .candidate_index = 0,
        .median_ns = 600,
        .sample_count = 16,
    }};
    try tuning_cache.recordMeasurements(caps, &artifact_plan, &slower_measurements);
    try testing.expectEqual(@as(usize, 1), tuning_cache.count());

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();
    try graph.applyCachedLaunchTuning(caps, &artifact_plan, &tuning_cache);

    try testing.expectEqual(@as(usize, 1), graph.tuning_selections.len);
    try testing.expectEqual(kernel.kernel_id, graph.tuning_selections[0].kernel_id);
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections[0].candidate_index);
    try testing.expectEqual(@as(u64, 200), graph.tuning_selections[0].median_ns);
    try testing.expectEqual(@as(u32, 4), graph.tuning_selections[0].sample_count);
    try testing.expectEqual(@as(usize, 1), graph.nodes[0].tuning.selections.len);
    try testing.expectEqual(@as(usize, 0), graph.nodes[0].tuning.measurements.len);

    try executable.launchGraph(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        graph.plan(),
    );

    const selected = kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable launch tuning cache exports and imports records" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_graph_tuning_records");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const caps = try handle.queryCapabilities();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    var tuning_cache = LaunchTuningCache.init(allocator);
    defer tuning_cache.deinit();

    const measurements = [_]LaunchCandidateMeasurement{
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    };
    try tuning_cache.recordMeasurements(caps, &artifact_plan, &measurements);

    const records = try tuning_cache.exportRecords(allocator);
    defer allocator.free(records);
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqual(launch_tuning_cache_record_version, records[0].version);
    try testing.expectEqual(
        @as(u32, @intCast(kernel.launch_resources.candidate_count)),
        records[0].key.candidate_count,
    );
    try testing.expect(records[0].key.launch_resource_fingerprint != 0);
    try testing.expectEqual(
        kernel.output_layout_fingerprint,
        records[0].key.output_layout_fingerprint,
    );
    try testing.expectEqual(
        kernel.input_layout_fingerprint,
        records[0].key.input_layout_fingerprint,
    );
    try testing.expectEqual(kernel.kernel_id, records[0].selection.kernel_id);
    try testing.expectEqual(@as(usize, 1), records[0].selection.candidate_index);

    var imported = LaunchTuningCache.init(allocator);
    defer imported.deinit();
    try imported.importRecords(records);
    try testing.expectEqual(@as(usize, 1), imported.count());

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();
    try graph.applyCachedLaunchTuning(caps, &artifact_plan, &imported);

    try testing.expectEqual(@as(usize, 1), graph.tuning_selections.len);
    try testing.expectEqual(kernel.kernel_id, graph.tuning_selections[0].kernel_id);
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections[0].candidate_index);
    try testing.expectEqual(@as(u64, 200), graph.tuning_selections[0].median_ns);

    try executable.launchGraph(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        graph.plan(),
    );

    const selected = kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable launch tuning artifact round-trips records" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_graph_tuning_artifact");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const caps = try handle.queryCapabilities();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    var tuning_cache = LaunchTuningCache.init(allocator);
    defer tuning_cache.deinit();

    const measurements = [_]LaunchCandidateMeasurement{
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    };
    try tuning_cache.recordMeasurements(caps, &artifact_plan, &measurements);

    const records = try tuning_cache.exportRecords(allocator);
    defer allocator.free(records);
    const artifact_bytes = try encodeLaunchTuningArtifact(allocator, records);
    defer allocator.free(artifact_bytes);
    const decoded = try decodeLaunchTuningArtifact(allocator, artifact_bytes);
    defer allocator.free(decoded);
    const encoded_again = try encodeLaunchTuningArtifact(allocator, decoded);
    defer allocator.free(encoded_again);

    try testing.expectEqualSlices(u8, artifact_bytes, encoded_again);
    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expectEqual(launch_tuning_cache_record_version, decoded[0].version);
    try testing.expectEqual(records[0].key, decoded[0].key);
    try testing.expectEqual(
        kernel.output_layout_fingerprint,
        decoded[0].key.output_layout_fingerprint,
    );
    try testing.expectEqual(
        kernel.input_layout_fingerprint,
        decoded[0].key.input_layout_fingerprint,
    );
    try testing.expectEqual(records[0].selection, decoded[0].selection);

    var imported = LaunchTuningCache.init(allocator);
    defer imported.deinit();
    try imported.importRecords(decoded);

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();
    try graph.applyCachedLaunchTuning(caps, &artifact_plan, &imported);

    try testing.expectEqual(@as(usize, 1), graph.tuning_selections.len);
    try testing.expectEqual(kernel.kernel_id, graph.tuning_selections[0].kernel_id);
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections[0].candidate_index);
    try testing.expectEqual(@as(u64, 200), graph.tuning_selections[0].median_ns);

    try executable.launchGraph(
        allocator,
        &artifact_plan,
        slot_bindings,
        count_bindings,
        graph.plan(),
    );

    const selected = kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable launch tuning artifact rejects invalid bytes" {
    const allocator = testing.allocator;
    const record = LaunchTuningCacheRecord{
        .key = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .format = .cuda_ptx,
            .candidate_count = 2,
        },
        .selection = .{
            .kernel_id = 0,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    };
    const artifact_bytes = try encodeLaunchTuningArtifact(allocator, &.{record});
    defer allocator.free(artifact_bytes);

    var bad_magic = try allocator.dupe(u8, artifact_bytes);
    defer allocator.free(bad_magic);
    bad_magic[0] ^= 0xff;
    try testing.expectError(
        error.InvalidArtifact,
        decodeLaunchTuningArtifact(allocator, bad_magic),
    );

    var bad_version = try allocator.dupe(u8, artifact_bytes);
    defer allocator.free(bad_version);
    bad_version[4] ^= 0xff;
    try testing.expectError(
        error.InvalidArtifact,
        decodeLaunchTuningArtifact(allocator, bad_version),
    );

    try testing.expectError(
        error.InvalidArtifact,
        decodeLaunchTuningArtifact(allocator, artifact_bytes[0 .. artifact_bytes.len - 1]),
    );

    var extra = std.ArrayListUnmanaged(u8).empty;
    defer extra.deinit(allocator);
    try extra.appendSlice(allocator, artifact_bytes);
    try extra.append(allocator, 0);
    try testing.expectError(
        error.InvalidArtifact,
        decodeLaunchTuningArtifact(allocator, extra.items),
    );
}

test "Choir executable launch tuning cache rejects invalid records before import" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_graph_tuning_bad_records");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const caps = try handle.queryCapabilities();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const key = LaunchTuningCacheKey.init(caps, kernel);
    const valid = LaunchTuningCacheRecord{
        .key = key,
        .selection = .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
    };
    const invalid = LaunchTuningCacheRecord{
        .key = key,
        .selection = .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = @intCast(key.candidate_count),
            .median_ns = 1,
            .sample_count = 1,
        },
    };
    const records = [_]LaunchTuningCacheRecord{ valid, invalid };

    var tuning_cache = LaunchTuningCache.init(allocator);
    defer tuning_cache.deinit();
    try testing.expectError(error.LaunchArgumentMismatch, tuning_cache.importRecords(&records));
    try testing.expectEqual(@as(usize, 0), tuning_cache.count());

    try tuning_cache.importRecords(&.{valid});
    try testing.expectEqual(@as(usize, 1), tuning_cache.count());

    var stale = valid;
    stale.version = launch_tuning_cache_record_version + 1;
    try testing.expectError(error.InvalidArtifact, tuning_cache.importRecords(&.{stale}));
    try testing.expectEqual(@as(usize, 1), tuning_cache.count());
}

test "Choir executable launch tuning cache keys reuse by launch resource identity" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_graph_tuning_cache_key");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const caps = try handle.queryCapabilities();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);

    var tuning_cache = LaunchTuningCache.init(allocator);
    defer tuning_cache.deinit();
    try tuning_cache.recordMeasuredSelection(caps, kernel, .{
        .kernel_id = kernel.kernel_id,
        .candidate_index = 1,
        .median_ns = 200,
        .sample_count = 4,
    });

    var equivalent_kernel = kernel;
    equivalent_kernel.kernel_id += 1000;
    const cached = (try tuning_cache.selectionForKernel(caps, equivalent_kernel)).?;
    try testing.expectEqual(equivalent_kernel.kernel_id, cached.kernel_id);
    try testing.expectEqual(@as(usize, 1), cached.candidate_index);

    var different_caps = caps;
    different_caps.threadgroup.max_threads = 512;
    try testing.expectEqual(
        @as(?LaunchTuningSelection, null),
        try tuning_cache.selectionForKernel(different_caps, kernel),
    );
}

test "Choir executable launch graph rejects invalid measured tuning selection" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_graph_bad_tuning");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    const kernel = artifact_plan.kernels.items[0];
    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    const measurements = [_]LaunchCandidateMeasurement{.{
        .kernel_id = kernel.kernel_id,
        .candidate_index = kernel.launch_resources.candidate_count,
        .median_ns = 1,
    }};

    try testing.expectError(
        error.LaunchArgumentMismatch,
        graph.applyMeasuredLaunchTuning(&artifact_plan, &measurements),
    );
    try testing.expectEqual(@as(usize, 0), graph.tuning_selections.len);
    try testing.expectEqual(@as(usize, 0), graph.nodes[0].tuning.selections.len);
    try testing.expectEqual(@as(usize, 0), graph.nodes[0].tuning.measurements.len);
}

test "Choir executable plan rejects invalid measured candidate" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_invalid_candidate");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);

    const measurements = [_]LaunchCandidateMeasurement{.{
        .kernel_id = kernel.kernel_id,
        .candidate_index = kernel.launch_resources.candidate_count,
        .median_ns = 1,
    }};

    try testing.expectError(
        error.LaunchArgumentMismatch,
        executable.launchAllWithOptions(allocator, &artifact_plan, slot_bindings, &.{}, .{
            .tuning = .{ .measurements = &measurements },
        }),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "Choir executable plan measures launch candidates" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_measure_candidates");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    const measurements = try executable.measureLaunchCandidates(
        allocator,
        allocator,
        &artifact_plan,
        0,
        slot_bindings,
        firstElementCountBinding(count_bindings),
        .{ .warmup = 1, .samples = 2 },
    );
    defer allocator.free(measurements);

    try testing.expectEqual(kernel.launch_resources.candidate_count, measurements.len);
    try testing.expectEqual(kernel.launch_resources.candidate_count * 3, state.launch_count);
    for (measurements, 0..) |measurement, index| {
        try testing.expectEqual(kernel.kernel_id, measurement.kernel_id);
        try testing.expectEqual(index, measurement.candidate_index);
        try testing.expectEqual(@as(u32, 2), measurement.sample_count);
    }
}

test "Choir executable launch candidate measurement requires samples" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_measure_no_samples");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    try testing.expectError(
        error.LaunchArgumentMismatch,
        executable.measureLaunchCandidates(
            allocator,
            allocator,
            &artifact_plan,
            0,
            slot_bindings,
            firstElementCountBinding(count_bindings),
            .{ .samples = 0 },
        ),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}
