const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const artifact_product = @import("../artifact/root.zig");
const tuning_mod = @import("tuning.zig");

pub const product_name = "accy.exec";

pub const LaunchOptions = struct {
    stream: ?gpu.StreamHandle = null,
    wait_events: []const gpu.EventHandle = &.{},
    signal_event: ?gpu.EventHandle = null,
    tuning: LaunchTuning = .{},
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument = &.{},
};

pub const LaunchGraphNode = struct {
    kernel_index: usize,
    stream: ?gpu.StreamHandle = null,
    wait_events: []const gpu.EventHandle = &.{},
    signal_event: ?gpu.EventHandle = null,
    tuning: LaunchTuning = .{},
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument = &.{},
};

pub const LaunchGraphDependency = struct {
    producer_node_index: usize,
    consumer_node_index: usize,
    slot_id: usize,
};

pub const LaunchGraphLoopCarry = struct {
    initial_slot_id: usize,
    input_slot_id: usize,
    output_slot_id: usize,
    final_slot_id: usize,
};

pub const LaunchGraphLoop = struct {
    first_node_index: usize,
    node_count: usize,
    trip_count: u64,
    carries: []const LaunchGraphLoopCarry = &.{},
};

pub fn launchGraphLoopCarryFinalSlot(carry: LaunchGraphLoopCarry, trip_count: u64) usize {
    if (trip_count % 2 == 0) return carry.initial_slot_id;
    return carry.output_slot_id;
}

pub const LaunchGraphPlan = struct {
    nodes: []const LaunchGraphNode,
    dependencies: []const LaunchGraphDependency = &.{},
    loops: []const LaunchGraphLoop = &.{},
    validated: bool = false,
};

pub const OwnedLaunchGraphPlan = struct {
    allocator: std.mem.Allocator,
    nodes: []LaunchGraphNode,
    dependencies: []LaunchGraphDependency,
    loops: []LaunchGraphLoop = &.{},
    tuning_selections: []LaunchTuningSelection = &.{},
    validated: bool = false,

    pub fn deinit(self: *OwnedLaunchGraphPlan) void {
        if (self.nodes.len != 0) self.allocator.free(self.nodes);
        if (self.dependencies.len != 0) self.allocator.free(self.dependencies);
        for (self.loops) |loop| {
            if (loop.carries.len != 0) self.allocator.free(@constCast(loop.carries));
        }
        if (self.loops.len != 0) self.allocator.free(self.loops);
        if (self.tuning_selections.len != 0) self.allocator.free(self.tuning_selections);
        self.* = undefined;
    }

    pub fn plan(self: *const OwnedLaunchGraphPlan) LaunchGraphPlan {
        return .{
            .nodes = self.nodes,
            .dependencies = self.dependencies,
            .loops = self.loops,
            .validated = self.validated,
        };
    }

    pub fn copyWithLaunchOptions(
        self: *const OwnedLaunchGraphPlan,
        allocator: std.mem.Allocator,
        launch_options: LaunchOptions,
    ) gpu.BackendError!OwnedLaunchGraphPlan {
        const nodes = allocator.alloc(
            LaunchGraphNode,
            self.nodes.len,
        ) catch return error.OutOfMemory;
        errdefer allocator.free(nodes);

        for (nodes, 0..) |*node, index| {
            node.* = self.nodes[index];
            node.stream = launch_options.stream;
            node.wait_events = if (index == 0) launch_options.wait_events else &.{};
            node.signal_event = if (index + 1 == nodes.len) launch_options.signal_event else null;
            node.tuning = launch_options.tuning;
            node.runtime_scalar_arguments = launch_options.runtime_scalar_arguments;
        }

        var dependencies: []LaunchGraphDependency = &.{};
        if (self.dependencies.len != 0) {
            dependencies = allocator.dupe(
                LaunchGraphDependency,
                self.dependencies,
            ) catch return error.OutOfMemory;
        }
        errdefer if (dependencies.len != 0) allocator.free(dependencies);

        var loops: []LaunchGraphLoop = &.{};
        if (self.loops.len != 0) {
            loops = allocator.alloc(LaunchGraphLoop, self.loops.len) catch return error.OutOfMemory;
            var copied_loops: usize = 0;
            errdefer {
                for (loops[0..copied_loops]) |loop| {
                    if (loop.carries.len != 0) allocator.free(@constCast(loop.carries));
                }
                allocator.free(loops);
            }
            for (self.loops, 0..) |loop, index| {
                var carries: []LaunchGraphLoopCarry = &.{};
                if (loop.carries.len != 0) {
                    carries = allocator.dupe(
                        LaunchGraphLoopCarry,
                        loop.carries,
                    ) catch return error.OutOfMemory;
                }
                loops[index] = .{
                    .first_node_index = loop.first_node_index,
                    .node_count = loop.node_count,
                    .trip_count = loop.trip_count,
                    .carries = carries,
                };
                copied_loops += 1;
            }
        }

        return .{
            .allocator = allocator,
            .nodes = nodes,
            .dependencies = dependencies,
            .loops = loops,
        };
    }

    pub fn applyMeasuredLaunchTuning(
        self: *OwnedLaunchGraphPlan,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        measurements: []const LaunchCandidateMeasurement,
    ) gpu.BackendError!void {
        if (self.nodes.len != artifact_plan.kernels.items.len) return error.InvalidArtifact;

        var selection_count: usize = 0;
        for (self.nodes) |node| {
            if (node.kernel_index >= artifact_plan.kernels.items.len) return error.InvalidArtifact;
            const planned = artifact_plan.kernels.items[node.kernel_index];
            if (try selectedLaunchMeasurement(planned, measurements)) |_| selection_count += 1;
        }

        var new_selections: []LaunchTuningSelection = &.{};
        if (selection_count != 0) {
            new_selections = self.allocator.alloc(
                LaunchTuningSelection,
                selection_count,
            ) catch return error.OutOfMemory;
        }
        errdefer if (new_selections.len != 0) self.allocator.free(new_selections);

        var selection_index: usize = 0;
        for (self.nodes) |node| {
            const planned = artifact_plan.kernels.items[node.kernel_index];
            if (try selectedLaunchMeasurement(planned, measurements)) |measurement| {
                new_selections[selection_index] = .{
                    .kernel_id = measurement.kernel_id,
                    .candidate_index = measurement.candidate_index,
                    .median_ns = measurement.median_ns,
                    .sample_count = measurement.sample_count,
                };
                selection_index += 1;
            }
        }

        self.installLaunchTuningSelections(artifact_plan, new_selections);
    }

    pub fn applyCachedLaunchTuning(
        self: *OwnedLaunchGraphPlan,
        caps: gpu.BackendCapabilities,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        cache: *const LaunchTuningCache,
    ) gpu.BackendError!void {
        if (self.nodes.len != artifact_plan.kernels.items.len) return error.InvalidArtifact;

        var selection_count: usize = 0;
        for (self.nodes) |node| {
            if (node.kernel_index >= artifact_plan.kernels.items.len) return error.InvalidArtifact;
            const planned = artifact_plan.kernels.items[node.kernel_index];
            if (try cache.selectionForKernel(caps, planned)) |_| selection_count += 1;
        }

        var new_selections: []LaunchTuningSelection = &.{};
        if (selection_count != 0) {
            new_selections = self.allocator.alloc(
                LaunchTuningSelection,
                selection_count,
            ) catch return error.OutOfMemory;
        }
        errdefer if (new_selections.len != 0) self.allocator.free(new_selections);

        var selection_index: usize = 0;
        for (self.nodes) |node| {
            const planned = artifact_plan.kernels.items[node.kernel_index];
            if (try cache.selectionForKernel(caps, planned)) |selection| {
                new_selections[selection_index] = selection;
                selection_index += 1;
            }
        }

        self.installLaunchTuningSelections(artifact_plan, new_selections);
    }

    fn installLaunchTuningSelections(
        self: *OwnedLaunchGraphPlan,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        new_selections: []LaunchTuningSelection,
    ) void {
        if (self.tuning_selections.len != 0) self.allocator.free(self.tuning_selections);
        self.tuning_selections = new_selections;
        var selection_index: usize = 0;
        for (self.nodes) |*node| {
            node.tuning = .{};
            const planned = artifact_plan.kernels.items[node.kernel_index];
            if (selection_index < self.tuning_selections.len and
                self.tuning_selections[selection_index].kernel_id == planned.kernel_id)
            {
                node.tuning.selections = self.tuning_selections[selection_index .. selection_index +
                    1];
                selection_index += 1;
            }
        }
    }
};

const CompiledFragmentState = struct {
    allocator: std.mem.Allocator,
    artifact_plan: artifact_product.BackendArtifactPlan,
    artifact_fingerprint: u64,
    launch_plan: OwnedLaunchGraphPlan,
    fingerprint_value: u64,

    fn deinit(self: *CompiledFragmentState) void {
        self.launch_plan.deinit();
        self.artifact_plan.deinit();
        self.* = undefined;
    }
};

pub const CompiledFragment = opaque {
    fn stateConst(self: *const CompiledFragment) *const CompiledFragmentState {
        return @ptrCast(@alignCast(self));
    }

    fn stateMut(self: *CompiledFragment) *CompiledFragmentState {
        return @ptrCast(@alignCast(self));
    }

    pub fn init(
        allocator: std.mem.Allocator,
        artifact_module: *artifact_product.ArtifactJob,
    ) !*CompiledFragment {
        var artifact_plan = try artifact_module.copyArtifactPlan(allocator);
        errdefer artifact_plan.deinit();

        var launch_plan = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
        errdefer launch_plan.deinit();

        const artifact_fingerprint = artifact_module.fingerprint();
        const product_stamp = fragmentProductStamp(
            artifact_fingerprint,
            launchGraphFingerprint(launch_plan.plan()),
        );

        const state = allocator.create(CompiledFragmentState) catch return error.OutOfMemory;
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .artifact_plan = artifact_plan,
            .artifact_fingerprint = artifact_fingerprint,
            .launch_plan = launch_plan,
            .fingerprint_value = product_stamp.fingerprint,
        };
        const fragment: *CompiledFragment = @ptrCast(state);
        try fragment.verify();
        return fragment;
    }

    pub fn initWithLaunchPlan(
        allocator: std.mem.Allocator,
        artifact_module: *artifact_product.ArtifactJob,
        launch_plan: OwnedLaunchGraphPlan,
    ) !*CompiledFragment {
        var owned_launch_plan = launch_plan;
        errdefer owned_launch_plan.deinit();

        var artifact_plan = try artifact_module.copyArtifactPlan(allocator);
        errdefer artifact_plan.deinit();

        const artifact_fingerprint = artifact_module.fingerprint();
        const product_stamp = fragmentProductStamp(
            artifact_fingerprint,
            launchGraphFingerprint(owned_launch_plan.plan()),
        );

        const state = allocator.create(CompiledFragmentState) catch return error.OutOfMemory;
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .artifact_plan = artifact_plan,
            .artifact_fingerprint = artifact_fingerprint,
            .launch_plan = owned_launch_plan,
            .fingerprint_value = product_stamp.fingerprint,
        };
        const fragment: *CompiledFragment = @ptrCast(state);
        try fragment.verify();
        return fragment;
    }

    pub fn deinit(self: *CompiledFragment) void {
        const state = self.stateMut();
        const allocator = state.allocator;
        state.deinit();
        allocator.destroy(state);
    }

    pub fn verify(self: *const CompiledFragment) !void {
        const state = self.stateConst();
        try validateLaunchGraph(
            state.allocator,
            &state.artifact_plan,
            state.launch_plan.plan(),
            false,
        );
    }

    pub fn fingerprint(self: *const CompiledFragment) u64 {
        return self.stateConst().fingerprint_value;
    }

    pub fn artifactFingerprint(self: *const CompiledFragment) u64 {
        return self.stateConst().artifact_fingerprint;
    }

    pub fn productStamp(self: *const CompiledFragment) choir.product.incremental.ProductStamp {
        return choir.product.incremental.productStamp(product_name, self.fingerprint());
    }

    pub fn artifactPlan(self: *const CompiledFragment) *const artifact_product.BackendArtifactPlan {
        return &self.stateConst().artifact_plan;
    }

    pub fn launchPlan(self: *const CompiledFragment) LaunchGraphPlan {
        return self.stateConst().launch_plan.plan();
    }

    pub fn kernelCount(self: *const CompiledFragment) usize {
        return self.artifactPlan().kernelCount();
    }

    pub fn createLaunchGraphPlan(
        self: *const CompiledFragment,
        allocator: std.mem.Allocator,
        launch_options: LaunchOptions,
    ) gpu.BackendError!OwnedLaunchGraphPlan {
        const state = self.stateConst();
        var graph = try state.launch_plan.copyWithLaunchOptions(allocator, launch_options);
        errdefer graph.deinit();
        const view = graph.plan();
        try validateLaunchGraph(
            allocator,
            self.artifactPlan(),
            view,
            launchGraphNeedsDependencyEvents(view),
        );
        graph.validated = true;
        return graph;
    }
};

pub fn compileFragmentFromArtifactJob(
    allocator: std.mem.Allocator,
    artifact_module: *artifact_product.ArtifactJob,
) !*CompiledFragment {
    return try CompiledFragment.init(allocator, artifact_module);
}

pub fn compileFragmentFromArtifactJobWithLaunchPlan(
    allocator: std.mem.Allocator,
    artifact_module: *artifact_product.ArtifactJob,
    launch_plan: OwnedLaunchGraphPlan,
) !*CompiledFragment {
    return try CompiledFragment.initWithLaunchPlan(allocator, artifact_module, launch_plan);
}

pub fn createDataflowLaunchGraphPlan(
    allocator: std.mem.Allocator,
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    launch_options: LaunchOptions,
) gpu.BackendError!OwnedLaunchGraphPlan {
    const kernel_count = artifact_plan.kernels.items.len;
    const nodes = allocator.alloc(LaunchGraphNode, kernel_count) catch return error.OutOfMemory;
    errdefer allocator.free(nodes);

    const scheduled = allocator.alloc(bool, kernel_count) catch return error.OutOfMemory;
    defer allocator.free(scheduled);
    @memset(scheduled, false);

    const kernel_to_node = allocator.alloc(usize, kernel_count) catch return error.OutOfMemory;
    defer allocator.free(kernel_to_node);
    @memset(kernel_to_node, std.math.maxInt(usize));

    for (nodes, 0..) |*node, node_index| {
        const kernel_index = nextReadyKernelIndex(artifact_plan, scheduled) orelse
            return error.InvalidArtifact;
        scheduled[kernel_index] = true;
        kernel_to_node[kernel_index] = node_index;
        node.* = .{
            .kernel_index = kernel_index,
            .stream = launch_options.stream,
            .wait_events = if (node_index == 0) launch_options.wait_events else &.{},
            .signal_event = if (node_index + 1 == kernel_count)
                launch_options.signal_event
            else
                null,
            .tuning = launch_options.tuning,
            .runtime_scalar_arguments = launch_options.runtime_scalar_arguments,
        };
    }

    var dependencies: std.ArrayListUnmanaged(LaunchGraphDependency) = .empty;
    errdefer dependencies.deinit(allocator);

    for (nodes, 0..) |consumer_node, consumer_node_index| {
        const consumer = artifact_plan.kernels.items[consumer_node.kernel_index];
        for (consumer.input_slot_ids) |slot_id| {
            const producer_index = producerKernelIndexForConsumedSlot(
                artifact_plan,
                slot_id,
                consumer_node.kernel_index,
            ) orelse continue;
            if (producer_index == consumer_node.kernel_index) continue;
            const producer_node_index = kernel_to_node[producer_index];
            if (producer_node_index == std.math.maxInt(usize)) return error.InvalidArtifact;
            const dependency = LaunchGraphDependency{
                .producer_node_index = producer_node_index,
                .consumer_node_index = consumer_node_index,
                .slot_id = slot_id,
            };
            if (dependencyExists(
                dependencies.items,
                dependency.producer_node_index,
                dependency.consumer_node_index,
                dependency.slot_id,
            )) continue;
            dependencies.append(allocator, dependency) catch return error.OutOfMemory;
        }
    }

    return .{
        .allocator = allocator,
        .nodes = nodes,
        .dependencies = dependencies.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

pub fn launchGraphFingerprint(graph: LaunchGraphPlan) u64 {
    var hasher = choir.product.incremental.FingerprintBuilder{};
    hasher.updateBytes("accy.exec.launch_graph");
    hashU64(&hasher, graph.nodes.len);
    for (graph.nodes) |node| {
        hashU64(&hasher, node.kernel_index);
    }
    hashU64(&hasher, graph.dependencies.len);
    for (graph.dependencies) |dependency| {
        hashU64(&hasher, dependency.producer_node_index);
        hashU64(&hasher, dependency.consumer_node_index);
        hashU64(&hasher, dependency.slot_id);
    }
    hashU64(&hasher, graph.loops.len);
    for (graph.loops) |loop| {
        hashU64(&hasher, loop.first_node_index);
        hashU64(&hasher, loop.node_count);
        hashU64(&hasher, loop.trip_count);
        hashU64(&hasher, loop.carries.len);
        for (loop.carries) |carry| {
            hashU64(&hasher, carry.initial_slot_id);
            hashU64(&hasher, carry.input_slot_id);
            hashU64(&hasher, carry.output_slot_id);
            hashU64(&hasher, carry.final_slot_id);
        }
    }
    return hasher.finish();
}

pub fn validateLaunchGraph(
    scratch: std.mem.Allocator,
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    graph: LaunchGraphPlan,
    dependency_events: bool,
) gpu.BackendError!void {
    if (graph.nodes.len != artifact_plan.kernels.items.len) return error.InvalidArtifact;
    const seen = scratch.alloc(
        bool,
        artifact_plan.kernels.items.len,
    ) catch return error.OutOfMemory;
    defer scratch.free(seen);
    @memset(seen, false);
    for (graph.nodes) |node| {
        if (node.kernel_index >= artifact_plan.kernels.items.len) return error.InvalidArtifact;
        if (seen[node.kernel_index]) return error.InvalidArtifact;
        seen[node.kernel_index] = true;
    }
    for (graph.dependencies, 0..) |dependency, dependency_index| {
        if (dependency.producer_node_index >= graph.nodes.len) return error.InvalidArtifact;
        if (dependency.consumer_node_index >= graph.nodes.len) return error.InvalidArtifact;
        if (dependency.producer_node_index == dependency.consumer_node_index) {
            return error.InvalidArtifact;
        }
        if (dependency.producer_node_index >= dependency.consumer_node_index) {
            return error.InvalidArtifact;
        }
        if (dependencyExists(
            graph.dependencies[0..dependency_index],
            dependency.producer_node_index,
            dependency.consumer_node_index,
            dependency.slot_id,
        )) {
            return error.InvalidArtifact;
        }
        const producer = graph.nodes[dependency.producer_node_index];
        const consumer = graph.nodes[dependency.consumer_node_index];
        if (dependency_events and producer.stream == null) return error.LaunchArgumentMismatch;
        if (artifact_plan.kernels.items[producer.kernel_index].output_slot_id !=
            dependency.slot_id) return error.InvalidArtifact;
        if (!kernelConsumesSlot(
            artifact_plan.kernels.items[consumer.kernel_index],
            dependency.slot_id,
        )) return error.InvalidArtifact;
    }
    try validateLaunchGraphDependencyClosure(artifact_plan, graph);
    try validateLaunchGraphLoops(scratch, artifact_plan, graph);
}

pub fn launchGraphNeedsDependencyEvents(graph: LaunchGraphPlan) bool {
    for (graph.dependencies) |dependency| {
        if (dependency.producer_node_index >= graph.nodes.len) return false;
        if (dependency.consumer_node_index >= graph.nodes.len) return false;
        const producer = graph.nodes[dependency.producer_node_index];
        const consumer = graph.nodes[dependency.consumer_node_index];
        if (!sameLaunchStream(producer.stream, consumer.stream)) return true;
    }
    return false;
}

pub fn incomingDependencyCount(graph: LaunchGraphPlan, node_index: usize) usize {
    var count: usize = 0;
    for (graph.dependencies) |dependency| {
        if (dependency.consumer_node_index == node_index) count += 1;
    }
    return count;
}

fn sameLaunchStream(lhs: ?gpu.StreamHandle, rhs: ?gpu.StreamHandle) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return lhs.?.id == rhs.?.id and lhs.?.backend == rhs.?.backend;
}

fn producerKernelIndexForConsumedSlot(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    slot_id: usize,
    consumer_kernel_index: usize,
) ?usize {
    var preceding_producer: ?usize = null;
    for (artifact_plan.kernels.items[0..consumer_kernel_index], 0..) |kernel, index| {
        if (kernel.output_slot_id == slot_id) preceding_producer = index;
    }
    if (preceding_producer) |producer| return producer;

    var unique_producer: ?usize = null;
    for (artifact_plan.kernels.items, 0..) |kernel, index| {
        if (kernel.output_slot_id != slot_id) continue;
        if (unique_producer != null) return null;
        unique_producer = index;
    }
    if (unique_producer) |producer| {
        if (producer != consumer_kernel_index) return producer;
    }
    return null;
}

fn nextReadyKernelIndex(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    scheduled: []const bool,
) ?usize {
    for (artifact_plan.kernels.items, 0..) |_, kernel_index| {
        if (scheduled[kernel_index]) continue;
        if (kernelDependenciesScheduled(artifact_plan, scheduled, kernel_index)) {
            return kernel_index;
        }
    }
    return null;
}

fn kernelDependenciesScheduled(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    scheduled: []const bool,
    consumer_kernel_index: usize,
) bool {
    const consumer = artifact_plan.kernels.items[consumer_kernel_index];
    for (consumer.input_slot_ids) |slot_id| {
        const producer_index = producerKernelIndexForConsumedSlot(
            artifact_plan,
            slot_id,
            consumer_kernel_index,
        ) orelse continue;
        if (producer_index == consumer_kernel_index) continue;
        if (!scheduled[producer_index]) return false;
    }
    return true;
}

fn validateLaunchGraphDependencyClosure(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    graph: LaunchGraphPlan,
) gpu.BackendError!void {
    for (graph.nodes, 0..) |consumer_node, consumer_node_index| {
        const consumer = artifact_plan.kernels.items[consumer_node.kernel_index];
        for (consumer.input_slot_ids) |slot_id| {
            const producer_node_index = producerNodeIndexForConsumedSlot(
                artifact_plan,
                graph,
                slot_id,
                consumer_node.kernel_index,
            ) orelse continue;
            if (producer_node_index == consumer_node_index) continue;
            if (producer_node_index >= consumer_node_index) return error.InvalidArtifact;
            if (!dependencyExists(
                graph.dependencies,
                producer_node_index,
                consumer_node_index,
                slot_id,
            )) {
                return error.InvalidArtifact;
            }
        }
    }
}

fn validateLaunchGraphLoops(
    scratch: std.mem.Allocator,
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    graph: LaunchGraphPlan,
) gpu.BackendError!void {
    if (graph.loops.len == 0) return;
    const loop_node = scratch.alloc(bool, graph.nodes.len) catch return error.OutOfMemory;
    defer scratch.free(loop_node);
    @memset(loop_node, false);

    for (graph.loops) |loop| {
        if (loop.node_count == 0) return error.InvalidArtifact;
        const last_node_index = std.math.add(
            usize,
            loop.first_node_index,
            loop.node_count,
        ) catch return error.InvalidArtifact;
        if (last_node_index > graph.nodes.len) return error.InvalidArtifact;
        for (loop_node[loop.first_node_index..last_node_index]) |*seen| {
            if (seen.*) return error.InvalidArtifact;
            seen.* = true;
        }
        for (loop.carries) |carry| {
            if (carry.input_slot_id == carry.output_slot_id) return error.InvalidArtifact;
            if (loop.trip_count != 0 and carry.initial_slot_id == carry.output_slot_id) {
                return error.InvalidArtifact;
            }
            if (launchGraphLoopCarryFinalSlot(carry, loop.trip_count) != carry.final_slot_id) {
                return error.InvalidArtifact;
            }
            if (!loopConsumesSlot(artifact_plan, graph, loop, carry.input_slot_id)) {
                return error.InvalidArtifact;
            }
            if (!loopProducesSlot(artifact_plan, graph, loop, carry.output_slot_id)) {
                return error.InvalidArtifact;
            }
        }
    }
}

fn loopConsumesSlot(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    graph: LaunchGraphPlan,
    loop: LaunchGraphLoop,
    slot_id: usize,
) bool {
    const end = loop.first_node_index + loop.node_count;
    for (graph.nodes[loop.first_node_index..end]) |node| {
        if (kernelConsumesSlot(artifact_plan.kernels.items[node.kernel_index], slot_id)) {
            return true;
        }
    }
    return false;
}

fn loopProducesSlot(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    graph: LaunchGraphPlan,
    loop: LaunchGraphLoop,
    slot_id: usize,
) bool {
    const end = loop.first_node_index + loop.node_count;
    for (graph.nodes[loop.first_node_index..end]) |node| {
        if (artifact_plan.kernels.items[node.kernel_index].output_slot_id == slot_id) return true;
    }
    return false;
}

fn producerNodeIndexForConsumedSlot(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    graph: LaunchGraphPlan,
    slot_id: usize,
    consumer_kernel_index: usize,
) ?usize {
    const producer_kernel_index = producerKernelIndexForConsumedSlot(
        artifact_plan,
        slot_id,
        consumer_kernel_index,
    ) orelse return null;
    for (graph.nodes, 0..) |node, node_index| {
        if (node.kernel_index == producer_kernel_index) return node_index;
    }
    return null;
}

fn dependencyExists(
    dependencies: []const LaunchGraphDependency,
    producer_node_index: usize,
    consumer_node_index: usize,
    slot_id: usize,
) bool {
    for (dependencies) |dependency| {
        if (dependency.producer_node_index != producer_node_index) continue;
        if (dependency.consumer_node_index != consumer_node_index) continue;
        if (dependency.slot_id != slot_id) continue;
        return true;
    }
    return false;
}

fn kernelConsumesSlot(kernel: artifact_product.PlannedKernel, slot_id: usize) bool {
    for (kernel.input_slot_ids) |input_slot_id| {
        if (input_slot_id == slot_id) return true;
    }
    return false;
}

pub fn fragmentProductStamp(
    artifact_fingerprint: u64,
    launch_graph_fingerprint: u64,
) choir.product.incremental.ProductStamp {
    const artifact_stamp = choir.product.incremental.productStamp(
        artifact_product.product_name,
        artifact_fingerprint,
    );
    return choir.product.incremental.derivedProductStamp(
        product_name,
        &.{artifact_stamp},
        launch_graph_fingerprint,
    );
}

fn hashU64(hasher: *choir.product.incremental.FingerprintBuilder, value: u64) void {
    hasher.updateU64(value);
}

const LaunchCandidateMeasurement = tuning_mod.LaunchCandidateMeasurement;
const LaunchTuningSelection = tuning_mod.LaunchTuningSelection;
const LaunchTuningCache = tuning_mod.LaunchTuningCache;
const LaunchTuning = tuning_mod.LaunchTuning;
const selectedLaunchMeasurement = tuning_mod.selectedLaunchMeasurement;

fn appendTestKernel(
    allocator: std.mem.Allocator,
    artifact_plan: *artifact_product.BackendArtifactPlan,
    kernel_id: usize,
    output_slot_id: usize,
    input_slot_ids: []const usize,
) !void {
    const inputs = try allocator.dupe(usize, input_slot_ids);
    errdefer allocator.free(inputs);

    const entry_name = if (kernel_id == 0) "kernel0" else "kernel1";
    const compile_entry_name = try allocator.dupe(u8, entry_name);
    var compile_entry_owned = true;
    errdefer if (compile_entry_owned) allocator.free(compile_entry_name);

    var artifact = try gpu.KernelArtifact.init(allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = entry_name,
        .argument_count = 0,
    });
    errdefer artifact.deinit();

    try artifact_plan.kernels.append(allocator, .{
        .compile = .{
            .source = .tensor,
            .launch = .generic,
            .format = .cuda_ptx,
            .entry_name = compile_entry_name,
            .argument_count = 0,
            .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
            .payload = .none,
            .payload_byte_count = 0,
        },
        .kernel_id = kernel_id,
        .work_item_id = kernel_id,
        .output_slot_id = output_slot_id,
        .input_slot_ids = inputs,
        .output_layout_fingerprint = 0,
        .input_layout_fingerprint = 0,
        .element_count = 1,
        .op_count = 1,
        .resources = .{
            .element_count = 1,
            .element_size = 4,
            .op_count = 1,
        },
        .artifact = artifact,
        .launch_resources = .{
            .format = .cuda_ptx,
            .element_count = 1,
            .geometry = .{
                .grid = .{ 1, 1, 1 },
                .threadgroup = .{ 1, 1, 1 },
            },
        },
        .element_count_argument = .none,
        .element_count_argument_value = 0,
        .runtime_scalar_argument_count = 0,
        .runtime_scalar_defaults = &.{},
        .static_arguments = &.{},
    });
    compile_entry_owned = false;
}

test "compiled fragment copies artifact job plan" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();

    const artifact_module = try artifact_product.ArtifactJob.init(
        allocator,
        artifact_plan,
    );
    plan_owned = false;
    var artifact_owned = true;
    errdefer if (artifact_owned) artifact_module.deinit();

    const artifact_fingerprint = artifact_module.fingerprint();
    var first = try CompiledFragment.init(allocator, artifact_module);
    errdefer first.deinit();
    var second = try CompiledFragment.init(allocator, artifact_module);
    errdefer second.deinit();

    artifact_module.deinit();
    artifact_owned = false;
    defer second.deinit();
    defer first.deinit();

    try std.testing.expectEqualStrings(product_name, "accy.exec");
    try first.verify();
    try second.verify();
    const expected_stamp = choir.product.incremental.derivedProductStamp(
        product_name,
        &.{choir.product.incremental.productStamp(
            artifact_product.product_name,
            artifact_fingerprint,
        )},
        launchGraphFingerprint(first.launchPlan()),
    );
    try std.testing.expectEqualStrings(product_name, expected_stamp.name);
    try std.testing.expectEqual(expected_stamp.fingerprint, first.fingerprint());
    try std.testing.expectEqual(first.fingerprint(), second.fingerprint());
    try std.testing.expectEqualStrings(product_name, first.productStamp().name);
    try std.testing.expectEqual(first.fingerprint(), first.productStamp().fingerprint);
    try std.testing.expectEqual(artifact_fingerprint, first.artifactFingerprint());
    try std.testing.expectEqual(@as(usize, 0), first.kernelCount());
    try std.testing.expectEqual(@as(usize, 0), first.launchPlan().nodes.len);
}

test "failed compiled fragment init leaves artifact ownership with caller" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();

    try appendTestKernel(allocator, &artifact_plan, 0, 2, &.{3});
    try appendTestKernel(allocator, &artifact_plan, 1, 3, &.{2});

    const artifact_module = try artifact_product.ArtifactJob.init(
        allocator,
        artifact_plan,
    );
    plan_owned = false;
    defer artifact_module.deinit();

    try std.testing.expectError(
        error.InvalidArtifact,
        CompiledFragment.init(allocator, artifact_module),
    );
}

test "executable dataflow launch graph records slot dependencies" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer artifact_plan.deinit();
    try appendTestKernel(allocator, &artifact_plan, 0, 2, &.{0});
    try appendTestKernel(allocator, &artifact_plan, 1, 3, &.{2});

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), graph.nodes[0].kernel_index);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes[1].kernel_index);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies.len);
    try std.testing.expectEqual(@as(usize, 0), graph.dependencies[0].producer_node_index);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies[0].consumer_node_index);
    try std.testing.expectEqual(@as(usize, 2), graph.dependencies[0].slot_id);
    try validateLaunchGraph(allocator, &artifact_plan, graph.plan(), false);
}

test "executable dataflow launch graph links repeated in-place slot updates" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer artifact_plan.deinit();
    try appendTestKernel(allocator, &artifact_plan, 0, 0, &.{0});
    try appendTestKernel(allocator, &artifact_plan, 1, 0, &.{0});
    try appendTestKernel(allocator, &artifact_plan, 2, 1, &.{0});

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), graph.nodes[0].kernel_index);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes[1].kernel_index);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes[2].kernel_index);
    try std.testing.expectEqual(@as(usize, 2), graph.dependencies.len);
    try std.testing.expectEqual(@as(usize, 0), graph.dependencies[0].producer_node_index);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies[0].consumer_node_index);
    try std.testing.expectEqual(@as(usize, 0), graph.dependencies[0].slot_id);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies[1].producer_node_index);
    try std.testing.expectEqual(@as(usize, 2), graph.dependencies[1].consumer_node_index);
    try std.testing.expectEqual(@as(usize, 0), graph.dependencies[1].slot_id);
    try validateLaunchGraph(allocator, &artifact_plan, graph.plan(), false);
}

test "executable dataflow launch graph orders producers before consumers" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer artifact_plan.deinit();
    try appendTestKernel(allocator, &artifact_plan, 0, 3, &.{2});
    try appendTestKernel(allocator, &artifact_plan, 1, 2, &.{0});

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes[0].kernel_index);
    try std.testing.expectEqual(@as(usize, 0), graph.nodes[1].kernel_index);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies.len);
    try std.testing.expectEqual(@as(usize, 0), graph.dependencies[0].producer_node_index);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies[0].consumer_node_index);
    try std.testing.expectEqual(@as(usize, 2), graph.dependencies[0].slot_id);
    try validateLaunchGraph(allocator, &artifact_plan, graph.plan(), false);
}

test "executable launch graph fingerprint includes schedule order" {
    const first_nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 0 },
        .{ .kernel_index = 1 },
    };
    const second_nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 1 },
        .{ .kernel_index = 0 },
    };
    const dependencies = [_]LaunchGraphDependency{.{
        .producer_node_index = 0,
        .consumer_node_index = 1,
        .slot_id = 2,
    }};

    try std.testing.expect(launchGraphFingerprint(.{
        .nodes = &first_nodes,
        .dependencies = &dependencies,
    }) != launchGraphFingerprint(.{
        .nodes = &second_nodes,
        .dependencies = &dependencies,
    }));
}

test "executable launch graph fingerprint includes loop structure" {
    const nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 0 },
        .{ .kernel_index = 1 },
    };
    const carry = [_]LaunchGraphLoopCarry{.{
        .initial_slot_id = 0,
        .input_slot_id = 0,
        .output_slot_id = 2,
        .final_slot_id = 0,
    }};
    const first_loops = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = 2,
        .trip_count = 4,
        .carries = &carry,
    }};
    const second_loops = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = 2,
        .trip_count = 5,
        .carries = &carry,
    }};

    try std.testing.expect(launchGraphFingerprint(.{
        .nodes = &nodes,
        .loops = &first_loops,
    }) != launchGraphFingerprint(.{
        .nodes = &nodes,
        .loops = &second_loops,
    }));
}

test "executable launch graph validates loop carry body slots" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer artifact_plan.deinit();
    try appendTestKernel(allocator, &artifact_plan, 0, 1, &.{0});
    try appendTestKernel(allocator, &artifact_plan, 1, 2, &.{1});

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    const carry = [_]LaunchGraphLoopCarry{.{
        .initial_slot_id = 0,
        .input_slot_id = 0,
        .output_slot_id = 2,
        .final_slot_id = 0,
    }};
    const loops = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = 2,
        .trip_count = 4,
        .carries = &carry,
    }};

    try validateLaunchGraph(allocator, &artifact_plan, .{
        .nodes = graph.nodes,
        .dependencies = graph.dependencies,
        .loops = &loops,
    }, false);
}

test "executable launch graph rejects invalid loop ranges and carries" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer artifact_plan.deinit();
    try appendTestKernel(allocator, &artifact_plan, 0, 1, &.{0});
    try appendTestKernel(allocator, &artifact_plan, 1, 2, &.{1});

    var graph = try createDataflowLaunchGraphPlan(allocator, &artifact_plan, .{});
    defer graph.deinit();

    const valid_carry = [_]LaunchGraphLoopCarry{.{
        .initial_slot_id = 0,
        .input_slot_id = 0,
        .output_slot_id = 2,
        .final_slot_id = 0,
    }};
    const missing_input = [_]LaunchGraphLoopCarry{.{
        .initial_slot_id = 0,
        .input_slot_id = 99,
        .output_slot_id = 2,
        .final_slot_id = 0,
    }};
    const missing_output = [_]LaunchGraphLoopCarry{.{
        .initial_slot_id = 0,
        .input_slot_id = 0,
        .output_slot_id = 99,
        .final_slot_id = 0,
    }};
    const bad_final = [_]LaunchGraphLoopCarry{.{
        .initial_slot_id = 0,
        .input_slot_id = 0,
        .output_slot_id = 2,
        .final_slot_id = 3,
    }};

    const empty_loop = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = 0,
        .trip_count = 4,
        .carries = &valid_carry,
    }};
    try std.testing.expectError(
        error.InvalidArtifact,
        validateLaunchGraph(allocator, &artifact_plan, .{
            .nodes = graph.nodes,
            .dependencies = graph.dependencies,
            .loops = &empty_loop,
        }, false),
    );

    const out_of_range = [_]LaunchGraphLoop{.{
        .first_node_index = 1,
        .node_count = 2,
        .trip_count = 4,
        .carries = &valid_carry,
    }};
    try std.testing.expectError(
        error.InvalidArtifact,
        validateLaunchGraph(allocator, &artifact_plan, .{
            .nodes = graph.nodes,
            .dependencies = graph.dependencies,
            .loops = &out_of_range,
        }, false),
    );

    const bad_input = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = 2,
        .trip_count = 4,
        .carries = &missing_input,
    }};
    try std.testing.expectError(
        error.InvalidArtifact,
        validateLaunchGraph(allocator, &artifact_plan, .{
            .nodes = graph.nodes,
            .dependencies = graph.dependencies,
            .loops = &bad_input,
        }, false),
    );

    const bad_output = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = 2,
        .trip_count = 4,
        .carries = &missing_output,
    }};
    try std.testing.expectError(
        error.InvalidArtifact,
        validateLaunchGraph(allocator, &artifact_plan, .{
            .nodes = graph.nodes,
            .dependencies = graph.dependencies,
            .loops = &bad_output,
        }, false),
    );

    const invalid_final = [_]LaunchGraphLoop{.{
        .first_node_index = 0,
        .node_count = 2,
        .trip_count = 4,
        .carries = &bad_final,
    }};
    try std.testing.expectError(
        error.InvalidArtifact,
        validateLaunchGraph(allocator, &artifact_plan, .{
            .nodes = graph.nodes,
            .dependencies = graph.dependencies,
            .loops = &invalid_final,
        }, false),
    );
}

test "executable launch graph rejects missing slot dependencies" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer artifact_plan.deinit();
    try appendTestKernel(allocator, &artifact_plan, 0, 2, &.{0});
    try appendTestKernel(allocator, &artifact_plan, 1, 3, &.{2});

    const nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 0 },
        .{ .kernel_index = 1 },
    };

    try std.testing.expectError(
        error.InvalidArtifact,
        validateLaunchGraph(allocator, &artifact_plan, .{ .nodes = &nodes }, false),
    );
}

test "executable launch graph rejects duplicate slot dependencies" {
    const allocator = std.testing.allocator;

    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    defer artifact_plan.deinit();
    try appendTestKernel(allocator, &artifact_plan, 0, 2, &.{0});
    try appendTestKernel(allocator, &artifact_plan, 1, 3, &.{2});

    const nodes = [_]LaunchGraphNode{
        .{ .kernel_index = 0 },
        .{ .kernel_index = 1 },
    };
    const dependencies = [_]LaunchGraphDependency{
        .{
            .producer_node_index = 0,
            .consumer_node_index = 1,
            .slot_id = 2,
        },
        .{
            .producer_node_index = 0,
            .consumer_node_index = 1,
            .slot_id = 2,
        },
    };

    try std.testing.expectError(
        error.InvalidArtifact,
        validateLaunchGraph(
            allocator,
            &artifact_plan,
            .{
                .nodes = &nodes,
                .dependencies = &dependencies,
            },
            false,
        ),
    );
}
