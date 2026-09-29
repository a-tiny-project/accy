const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const sys = @import("sys");
const artifact_product = @import("../artifact/root.zig");
const binding_mod = @import("binding.zig");
const candidate_mod = @import("candidate.zig");
const exec_product = @import("plan.zig");
const phase_mod = @import("phase.zig");
const tuning_mod = @import("tuning.zig");

const ElementCountBufferBinding = binding_mod.ElementCountBufferBinding;
const LaunchCandidateBenchmarkOptions = candidate_mod.LaunchCandidateBenchmarkOptions;
const LaunchCandidateSynchronization = candidate_mod.LaunchCandidateSynchronization;
const LaunchGraphPlan = exec_product.LaunchGraphPlan;
const LaunchGraphLoop = exec_product.LaunchGraphLoop;
const LaunchOptions = exec_product.LaunchOptions;
const LaunchTuning = tuning_mod.LaunchTuning;
const LaunchCandidateMeasurement = tuning_mod.LaunchCandidateMeasurement;
const SlotBinding = binding_mod.SlotBinding;
const FragmentInstrumentation = phase_mod.FragmentInstrumentation;
const createDataflowLaunchGraphPlan = exec_product.createDataflowLaunchGraphPlan;
const incomingDependencyCount = exec_product.incomingDependencyCount;
const launchGraphNeedsDependencyEvents = exec_product.launchGraphNeedsDependencyEvents;

pub const LoadedKernel = struct {
    kernel_id: usize,
    work_item_id: usize,
    loaded_artifact: gpu.LoadedArtifact,

    fn deinit(self: *LoadedKernel, handle: gpu.BackendHandle) void {
        handle.destroyObject(self.loaded_artifact.id);
        self.* = undefined;
    }
};

const max_launch_arguments = 32;

pub const LoadedKernels = struct {
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    kernels: []LoadedKernel,

    pub fn deinit(self: *LoadedKernels) void {
        for (self.kernels) |*kernel| kernel.deinit(self.handle);
        self.allocator.free(self.kernels);
        self.* = undefined;
    }

    pub fn kernelCount(self: LoadedKernels) usize {
        return self.kernels.len;
    }

    pub fn launchKernel(
        self: *const LoadedKernels,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        kernel_index: usize,
        slot_bindings: []const SlotBinding,
        element_count_buffer: ?gpu.BufferBinding,
        launch_options: LaunchOptions,
    ) gpu.BackendError!void {
        if (kernel_index >= self.kernels.len or kernel_index >= artifact_plan.kernels.items.len) {
            return error.InvalidArtifact;
        }
        const loaded = self.kernels[kernel_index];
        const planned = artifact_plan.kernels.items[kernel_index];
        if (loaded.kernel_id != planned.kernel_id or loaded.work_item_id != planned.work_item_id) {
            return error.InvalidArtifact;
        }

        const has_count_buffer = planned.element_count_argument == .device_buffer_u32;
        const buffer_count = 1 + planned.input_slot_ids.len + @intFromBool(has_count_buffer);
        if (buffer_count > max_launch_arguments) return error.LaunchArgumentMismatch;
        var binding_storage: [max_launch_arguments]gpu.BufferBinding = undefined;
        const bindings = binding_storage[0..buffer_count];

        var binding_index: usize = 0;
        bindings[binding_index] = try binding_mod.bindingForSlot(slot_bindings, planned.output_slot_id, outputAccessForKernel(planned));
        if (planned.output_fill_pattern) |pattern| {
            try self.fillOutputBinding(artifact_plan, planned, bindings[binding_index], pattern);
        }
        binding_index += 1;
        for (planned.input_slot_ids, 0..) |slot_id, input_index| {
            const writable = planned.scratch_fill_pattern != null and input_index + 1 == planned.input_slot_ids.len;
            bindings[binding_index] = try binding_mod.bindingForSlot(slot_bindings, slot_id, if (writable) .read_write else .read_only);
            if (planned.scratch_fill_pattern) |pattern| {
                if (input_index + 1 == planned.input_slot_ids.len) {
                    try self.fillSlotBinding(artifact_plan, slot_id, bindings[binding_index], pattern);
                }
            }
            binding_index += 1;
        }
        if (has_count_buffer) {
            bindings[binding_index] = binding_mod.countBinding(element_count_buffer orelse return error.LaunchArgumentMismatch);
            binding_index += 1;
        }

        const runtime_scalar_count: usize = @intCast(planned.runtime_scalar_argument_count);
        const runtime_scalar_arguments: []const gpu_abi.ScalarArgument = if (runtime_scalar_count == 0)
            &.{}
        else if (launch_options.runtime_scalar_arguments.len != 0)
            launch_options.runtime_scalar_arguments
        else
            planned.runtime_scalar_defaults;
        if (runtime_scalar_arguments.len != runtime_scalar_count) return error.LaunchArgumentMismatch;
        const count_scalar_count: usize = @intFromBool(planned.element_count_argument == .scalar_u32);
        const scalar_count = count_scalar_count + runtime_scalar_count + planned.static_arguments.len;
        if (scalar_count > max_launch_arguments) return error.LaunchArgumentMismatch;
        var scalar_argument_storage: [max_launch_arguments]gpu_abi.ScalarArgument = undefined;
        const scalar_storage = scalar_argument_storage[0..scalar_count];

        var scalar_index: usize = 0;
        switch (planned.element_count_argument) {
            .none, .device_buffer_u32 => {},
            .scalar_u32 => {
                if (planned.element_count_argument_value > std.math.maxInt(u32)) return error.LaunchArgumentMismatch;
                scalar_storage[scalar_index] = .{ .u32 = @intCast(planned.element_count_argument_value) };
                scalar_index += 1;
            },
        }
        if (runtime_scalar_count != 0) {
            @memcpy(scalar_storage[scalar_index..][0..runtime_scalar_count], runtime_scalar_arguments);
            scalar_index += runtime_scalar_count;
        }
        if (planned.static_arguments.len != 0) {
            @memcpy(scalar_storage[scalar_index..][0..planned.static_arguments.len], planned.static_arguments);
            scalar_index += planned.static_arguments.len;
        }

        try self.handle.launch(.{
            .artifact = &planned.artifact,
            .loaded_artifact = loaded.loaded_artifact,
            .buffers = bindings[0..binding_index],
            .scalar_arguments = scalar_storage[0..scalar_index],
            .geometry = try launchGeometryForPlanned(planned, runtime_scalar_arguments, launch_options.tuning),
            .diagnostic_id = planned.artifact.diagnostic_id,
            .stream = launch_options.stream,
            .wait_events = launch_options.wait_events,
            .signal_event = launch_options.signal_event,
        });
    }

    pub fn launchKernelWithArguments(
        self: *const LoadedKernels,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        kernel_index: usize,
        buffers: []const gpu.BufferBinding,
        scalar_arguments: []const gpu_abi.ScalarArgument,
        launch_options: LaunchOptions,
    ) gpu.BackendError!void {
        if (kernel_index >= self.kernels.len or kernel_index >= artifact_plan.kernels.items.len) {
            return error.InvalidArtifact;
        }
        const loaded = self.kernels[kernel_index];
        const planned = artifact_plan.kernels.items[kernel_index];
        if (loaded.kernel_id != planned.kernel_id or loaded.work_item_id != planned.work_item_id) {
            return error.InvalidArtifact;
        }
        if (planned.compile.source != .choir_kernel) return error.UnsupportedOperation;
        const candidate_index = try launch_options.tuning.selectedCandidateIndex(planned);
        const geometry = if (planned.launch_resources.candidate_count == 0)
            planned.launch_resources.geometry
        else if (candidate_index < planned.launch_resources.candidate_count)
            planned.launch_resources.candidates[candidate_index].geometry
        else
            return error.LaunchArgumentMismatch;

        try self.handle.launch(.{
            .artifact = &planned.artifact,
            .loaded_artifact = loaded.loaded_artifact,
            .buffers = buffers,
            .scalar_arguments = scalar_arguments,
            .geometry = geometry,
            .stream = launch_options.stream,
            .wait_events = launch_options.wait_events,
            .signal_event = launch_options.signal_event,
            .diagnostic_id = planned.artifact.diagnostic_id,
        });
    }

    pub fn measureLaunchCandidates(
        self: *const LoadedKernels,
        result_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        kernel_index: usize,
        slot_bindings: []const SlotBinding,
        element_count_buffer: ?gpu.BufferBinding,
        options: LaunchCandidateBenchmarkOptions,
    ) gpu.BackendError![]LaunchCandidateMeasurement {
        if (options.samples == 0) return error.LaunchArgumentMismatch;
        if (kernel_index >= artifact_plan.kernels.items.len) return error.InvalidArtifact;
        const planned = artifact_plan.kernels.items[kernel_index];
        if (planned.launch_resources.candidate_count == 0) return error.LaunchArgumentMismatch;

        const measurements = result_allocator.alloc(LaunchCandidateMeasurement, planned.launch_resources.candidate_count) catch return error.OutOfMemory;
        errdefer result_allocator.free(measurements);

        const sample_times = scratch.alloc(u64, options.samples) catch return error.OutOfMemory;
        defer scratch.free(sample_times);

        for (measurements, 0..) |*measurement, candidate_index| {
            var warmup_index: u32 = 0;
            while (warmup_index < options.warmup) : (warmup_index += 1) {
                try self.launchKernelCandidate(
                    artifact_plan,
                    kernel_index,
                    slot_bindings,
                    element_count_buffer,
                    options.base_options,
                    planned.kernel_id,
                    candidate_index,
                );
                try self.synchronizeMeasuredLaunch(options.base_options, options.synchronize);
            }

            for (sample_times) |*sample| {
                const start = nowNs();
                try self.launchKernelCandidate(
                    artifact_plan,
                    kernel_index,
                    slot_bindings,
                    element_count_buffer,
                    options.base_options,
                    planned.kernel_id,
                    candidate_index,
                );
                try self.synchronizeMeasuredLaunch(options.base_options, options.synchronize);
                sample.* = elapsedNs(start);
            }

            std.mem.sort(u64, sample_times, {}, std.sort.asc(u64));
            measurement.* = .{
                .kernel_id = planned.kernel_id,
                .candidate_index = candidate_index,
                .median_ns = sample_times[sample_times.len / 2],
                .sample_count = options.samples,
            };
        }

        return measurements;
    }

    fn launchKernelCandidate(
        self: *const LoadedKernels,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        kernel_index: usize,
        slot_bindings: []const SlotBinding,
        element_count_buffer: ?gpu.BufferBinding,
        base_options: LaunchOptions,
        kernel_id: usize,
        candidate_index: usize,
    ) gpu.BackendError!void {
        const forced_measurement = [_]LaunchCandidateMeasurement{.{
            .kernel_id = kernel_id,
            .candidate_index = candidate_index,
            .median_ns = 0,
        }};
        var launch_options = base_options;
        launch_options.tuning = .{ .measurements = &forced_measurement };
        try self.launchKernel(
            artifact_plan,
            kernel_index,
            slot_bindings,
            element_count_buffer,
            launch_options,
        );
    }

    const max_output_fill_bytes = 4096;

    fn fillOutputBinding(
        self: *const LoadedKernels,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        planned: artifact_product.PlannedKernel,
        binding: gpu.BufferBinding,
        pattern: u32,
    ) gpu.BackendError!void {
        return self.fillSlotBinding(artifact_plan, planned.output_slot_id, binding, pattern);
    }

    fn fillSlotBinding(
        self: *const LoadedKernels,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_id: usize,
        binding: gpu.BufferBinding,
        pattern: u32,
    ) gpu.BackendError!void {
        const slot = artifact_plan.slotById(slot_id) orelse return error.InvalidArtifact;
        const byte_size_u64 = slot.byte_size orelse return error.UnsupportedOperation;
        if (byte_size_u64 == 0 or byte_size_u64 % @sizeOf(u32) != 0) return error.InvalidArtifact;
        if (self.handle.fillBuffer(.{ .handle = binding.handle, .pattern = pattern })) |_| {
            return;
        } else |err| switch (err) {
            error.UnsupportedOperation => {},
            else => return err,
        }
        if (byte_size_u64 > max_output_fill_bytes) return error.UnsupportedOperation;
        const byte_size: usize = @intCast(byte_size_u64);

        var storage: [max_output_fill_bytes]u8 = undefined;
        const pattern_bytes = std.mem.asBytes(&pattern);
        var offset: usize = 0;
        while (offset < byte_size) : (offset += @sizeOf(u32)) {
            @memcpy(storage[offset..][0..@sizeOf(u32)], pattern_bytes);
        }
        try self.handle.writeBuffer(.{
            .handle = binding.handle,
            .bytes = storage[0..byte_size],
        });
    }

    fn synchronizeMeasuredLaunch(
        self: *const LoadedKernels,
        launch_options: LaunchOptions,
        synchronization: LaunchCandidateSynchronization,
    ) gpu.BackendError!void {
        switch (synchronization) {
            .none => {},
            .device => try self.handle.synchronize(.{ .scope = .device }),
            .stream => try self.handle.synchronize(.{
                .scope = .stream,
                .stream = launch_options.stream orelse return error.LaunchArgumentMismatch,
            }),
            .event => try self.handle.synchronize(.{
                .scope = .event,
                .event = launch_options.signal_event orelse return error.LaunchArgumentMismatch,
            }),
        }
    }

    pub fn launchAll(
        self: *const LoadedKernels,
        scratch: std.mem.Allocator,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
    ) gpu.BackendError!void {
        try self.launchAllWithOptions(
            scratch,
            artifact_plan,
            slot_bindings,
            element_count_buffers,
            .{},
        );
    }

    pub fn launchAllWithOptions(
        self: *const LoadedKernels,
        scratch: std.mem.Allocator,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        launch_options: LaunchOptions,
    ) gpu.BackendError!void {
        if (self.kernels.len != artifact_plan.kernels.items.len) return error.InvalidArtifact;
        var graph = try createDataflowLaunchGraphPlan(scratch, artifact_plan, launch_options);
        defer graph.deinit();
        try self.launchGraph(
            scratch,
            artifact_plan,
            slot_bindings,
            element_count_buffers,
            graph.plan(),
        );
    }

    pub fn launchGraph(
        self: *const LoadedKernels,
        scratch: std.mem.Allocator,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        graph: LaunchGraphPlan,
    ) gpu.BackendError!void {
        if (self.kernels.len != artifact_plan.kernels.items.len) return error.InvalidArtifact;
        if (launchGraphNeedsDependencyEvents(graph)) {
            if (graph.loops.len != 0) return error.UnsupportedOperation;
            try self.launchGraphWithDependencyEvents(
                scratch,
                artifact_plan,
                slot_bindings,
                element_count_buffers,
                graph,
            );
            return;
        }
        try self.launchGraphHostOrder(
            scratch,
            artifact_plan,
            slot_bindings,
            element_count_buffers,
            graph,
        );
    }

    fn launchGraphHostOrder(
        self: *const LoadedKernels,
        scratch: std.mem.Allocator,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        graph: LaunchGraphPlan,
    ) gpu.BackendError!void {
        if (!graph.validated) try exec_product.validateLaunchGraph(scratch, artifact_plan, graph, false);

        var node_index: usize = 0;
        while (node_index < graph.nodes.len) {
            if (loopAtNode(graph.loops, node_index)) |loop_desc| {
                try self.launchGraphLoopHostOrder(
                    scratch,
                    artifact_plan,
                    slot_bindings,
                    element_count_buffers,
                    graph,
                    loop_desc,
                );
                node_index += loop_desc.node_count;
                continue;
            }
            try self.launchGraphNodeHostOrder(
                artifact_plan,
                slot_bindings,
                element_count_buffers,
                graph.nodes[node_index],
            );
            node_index += 1;
        }
    }

    fn launchGraphLoopHostOrder(
        self: *const LoadedKernels,
        scratch: std.mem.Allocator,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        graph: LaunchGraphPlan,
        loop_desc: LaunchGraphLoop,
    ) gpu.BackendError!void {
        if (loop_desc.trip_count == 0) return;
        const loop_end = loop_desc.first_node_index + loop_desc.node_count;
        if (loop_desc.carries.len == 0) {
            var iteration: u64 = 0;
            while (iteration < loop_desc.trip_count) : (iteration += 1) {
                for (graph.nodes[loop_desc.first_node_index..loop_end]) |node| {
                    try self.launchGraphNodeHostOrder(
                        artifact_plan,
                        slot_bindings,
                        element_count_buffers,
                        node,
                    );
                }
            }
            return;
        }

        const remapped_slot_bindings = scratch.alloc(SlotBinding, slot_bindings.len) catch return error.OutOfMemory;
        defer scratch.free(remapped_slot_bindings);

        var iteration: u64 = 0;
        while (iteration < loop_desc.trip_count) : (iteration += 1) {
            @memcpy(remapped_slot_bindings, slot_bindings);
            for (loop_desc.carries) |carry| {
                const input_physical_slot = if (iteration % 2 == 0) carry.initial_slot_id else carry.output_slot_id;
                const output_physical_slot = if (iteration % 2 == 0) carry.output_slot_id else carry.initial_slot_id;
                const input_binding = try binding_mod.bindingForSlot(slot_bindings, input_physical_slot, .read_write);
                const output_binding = try binding_mod.bindingForSlot(slot_bindings, output_physical_slot, .read_write);
                try remapSlotBinding(remapped_slot_bindings, carry.input_slot_id, input_binding);
                try remapSlotBinding(remapped_slot_bindings, carry.output_slot_id, output_binding);
            }
            for (graph.nodes[loop_desc.first_node_index..loop_end]) |node| {
                try self.launchGraphNodeHostOrder(
                    artifact_plan,
                    remapped_slot_bindings,
                    element_count_buffers,
                    node,
                );
            }
        }
    }

    fn launchGraphNodeHostOrder(
        self: *const LoadedKernels,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        node: exec_product.LaunchGraphNode,
    ) gpu.BackendError!void {
        const kernel = self.kernels[node.kernel_index];
        try self.launchKernel(
            artifact_plan,
            node.kernel_index,
            slot_bindings,
            binding_mod.elementCountBufferForKernel(element_count_buffers, kernel.kernel_id),
            .{
                .stream = node.stream,
                .wait_events = node.wait_events,
                .signal_event = node.signal_event,
                .tuning = node.tuning,
                .runtime_scalar_arguments = node.runtime_scalar_arguments,
            },
        );
    }

    pub fn launchGraphWithDependencyEvents(
        self: *const LoadedKernels,
        scratch: std.mem.Allocator,
        artifact_plan: *const artifact_product.BackendArtifactPlan,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        graph: LaunchGraphPlan,
    ) gpu.BackendError!void {
        if (graph.loops.len != 0) return error.UnsupportedOperation;
        if (!graph.validated) try exec_product.validateLaunchGraph(scratch, artifact_plan, graph, true);

        const dependency_events = scratch.alloc(gpu.EventHandle, graph.dependencies.len) catch return error.OutOfMemory;
        defer scratch.free(dependency_events);
        var created_event_count: usize = 0;
        errdefer {
            for (dependency_events[0..created_event_count]) |event| self.handle.destroyObject(event.id);
        }
        for (graph.dependencies, 0..) |_, index| {
            dependency_events[index] = try self.handle.createEvent(.{});
            created_event_count += 1;
        }
        defer {
            for (dependency_events[0..created_event_count]) |event| self.handle.destroyObject(event.id);
        }

        for (graph.nodes, 0..) |node, node_index| {
            const incoming_count = incomingDependencyCount(graph, node_index);
            const wait_events = scratch.alloc(gpu.EventHandle, node.wait_events.len + incoming_count) catch return error.OutOfMemory;
            defer scratch.free(wait_events);
            @memcpy(wait_events[0..node.wait_events.len], node.wait_events);
            var wait_index = node.wait_events.len;
            for (graph.dependencies, 0..) |dependency, dependency_index| {
                if (dependency.consumer_node_index != node_index) continue;
                wait_events[wait_index] = dependency_events[dependency_index];
                wait_index += 1;
            }

            const kernel = self.kernels[node.kernel_index];
            try self.launchKernel(
                artifact_plan,
                node.kernel_index,
                slot_bindings,
                binding_mod.elementCountBufferForKernel(element_count_buffers, kernel.kernel_id),
                .{
                    .stream = node.stream,
                    .wait_events = wait_events,
                    .signal_event = node.signal_event,
                    .tuning = node.tuning,
                    .runtime_scalar_arguments = node.runtime_scalar_arguments,
                },
            );

            for (graph.dependencies, 0..) |dependency, dependency_index| {
                if (dependency.producer_node_index != node_index) continue;
                try self.handle.recordEvent(.{
                    .stream = node.stream.?,
                    .event = dependency_events[dependency_index],
                });
            }
        }
    }
};

fn loopAtNode(loops: []const LaunchGraphLoop, node_index: usize) ?LaunchGraphLoop {
    for (loops) |loop_desc| {
        if (loop_desc.first_node_index == node_index) return loop_desc;
    }
    return null;
}

fn remapSlotBinding(
    slot_bindings: []SlotBinding,
    slot_id: usize,
    binding: gpu.BufferBinding,
) gpu.BackendError!void {
    for (slot_bindings) |*slot_binding| {
        if (slot_binding.slot_id != slot_id) continue;
        slot_binding.binding = binding;
        return;
    }
    return error.InvalidBuffer;
}

pub fn loadKernels(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    artifact_plan: *const artifact_product.BackendArtifactPlan,
) !LoadedKernels {
    return try loadKernelsWithInstrumentation(allocator, handle, artifact_plan, .{});
}

pub fn loadKernelsWithInstrumentation(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    instrumentation: FragmentInstrumentation,
) !LoadedKernels {
    const load_start = nowNs();
    const kernels = allocator.alloc(LoadedKernel, artifact_plan.kernels.items.len) catch return error.OutOfMemory;
    var loaded_count: usize = 0;
    errdefer {
        for (kernels[0..loaded_count]) |*kernel| kernel.deinit(handle);
        allocator.free(kernels);
    }

    for (artifact_plan.kernels.items, 0..) |planned, index| {
        const loaded = try handle.loadArtifact(&planned.artifact);
        kernels[index] = .{
            .kernel_id = planned.kernel_id,
            .work_item_id = planned.work_item_id,
            .loaded_artifact = loaded,
        };
        loaded_count += 1;
    }

    try instrumentation.record(.load_backend_artifacts, load_start);
    return .{
        .allocator = allocator,
        .handle = handle,
        .kernels = kernels,
    };
}

fn outputAccessForKernel(planned: artifact_product.PlannedKernel) gpu.BufferAccess {
    for (planned.input_slot_ids) |slot_id| {
        if (slot_id == planned.output_slot_id) return .read_write;
    }
    return .write_only;
}

fn launchGeometryForPlanned(
    planned: artifact_product.PlannedKernel,
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    tuning: LaunchTuning,
) gpu.BackendError!gpu_abi.LaunchGeometry {
    if (planned.kernel_call_launch) |launch| {
        switch (launch) {
            .derived => |derived| return derived.geometry(runtime_scalar_arguments),
            .fixed => {},
        }
    }
    const candidate_index = try tuning.selectedCandidateIndex(planned);
    if (candidate_index >= planned.launch_resources.candidate_count) return error.LaunchArgumentMismatch;
    return planned.launch_resources.candidates[candidate_index].geometry;
}

fn nowNs() i128 {
    return sys.time.nanoTimestamp();
}

fn elapsedNs(start: i128) u64 {
    const end = nowNs();
    if (end <= start) return 0;
    const elapsed = end - start;
    if (elapsed > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(elapsed);
}
