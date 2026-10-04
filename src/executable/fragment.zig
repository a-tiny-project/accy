const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const sys = @import("sys");
const accy_choir = @import("../choir/root.zig");
const artifact_product = @import("../artifact/root.zig");
const kernel_library = @import("../kernel/library/root.zig");
const exec_product = @import("plan.zig");
const preparation = @import("../preparation/root.zig");
const tuning_mod = @import("tuning.zig");
const schedule_tuning = @import("schedule.zig");
const binding_mod = @import("binding.zig");
const loaded_mod = @import("loaded.zig");
const fixture = @import("fixture.zig");

const ir = choir.ir;
const passes = choir.passes;
const semantic = accy_choir.semantic;
const candidate_mod = @import("candidate.zig");
const phase_mod = @import("phase.zig");

pub const LaunchCandidateMeasurement = tuning_mod.LaunchCandidateMeasurement;
pub const LaunchTuningSelection = tuning_mod.LaunchTuningSelection;
pub const launch_tuning_cache_record_version = tuning_mod.launch_tuning_cache_record_version;
pub const launch_tuning_artifact_magic = tuning_mod.launch_tuning_artifact_magic;
pub const launch_tuning_artifact_version = tuning_mod.launch_tuning_artifact_version;
pub const LaunchTuningCacheRecord = tuning_mod.LaunchTuningCacheRecord;
pub const LaunchTuning = tuning_mod.LaunchTuning;
pub const encodeLaunchTuningArtifact = tuning_mod.encodeLaunchTuningArtifact;
pub const decodeLaunchTuningArtifact = tuning_mod.decodeLaunchTuningArtifact;

const LaunchTuningCacheKey = tuning_mod.LaunchTuningCacheKey;
const LaunchTuningCache = tuning_mod.LaunchTuningCache;
const LaunchGraphPlan = exec_product.LaunchGraphPlan;
const OwnedLaunchGraphPlan = exec_product.OwnedLaunchGraphPlan;
pub const LaunchCandidateSynchronization = candidate_mod.LaunchCandidateSynchronization;
pub const LaunchCandidateBenchmarkOptions = candidate_mod.LaunchCandidateBenchmarkOptions;
pub const LaunchCandidateRecord = candidate_mod.LaunchCandidateRecord;
pub const FragmentPhase = phase_mod.FragmentPhase;
pub const FragmentPhaseObserver = phase_mod.FragmentPhaseObserver;
pub const FragmentInstrumentation = phase_mod.FragmentInstrumentation;

const launchCandidateRecord = candidate_mod.launchCandidateRecord;
const plannedKernelForLaunchCandidateRecord = candidate_mod.plannedKernelForLaunchCandidateRecord;
const launchResourceClassName = artifact_product.launchResourceClassName;
const copyKernelArtifactToAllocator = candidate_mod.copyKernelArtifactToAllocator;

const SlotBinding = binding_mod.SlotBinding;
const ElementCountBufferBinding = binding_mod.ElementCountBufferBinding;
const PreparedLaunchBindings = binding_mod.PreparedLaunchBindings;
const LoadedKernels = loaded_mod.LoadedKernels;
const loadKernels = loaded_mod.loadKernels;
const loadKernelsWithInstrumentation = loaded_mod.loadKernelsWithInstrumentation;
const RecordingBackendState = gpu.recording.BackendState;
const addChoirModule = fixture.addChoirModule;
const addU32ChoirModule = fixture.addU32ChoirModule;
const addSemanticModule = fixture.addSemanticModule;
const fusedAddMulChoirModule = fixture.fusedAddMulChoirModule;
const constantAddChoirModule = fixture.constantAddChoirModule;
const dotGeneralChoirModule = fixture.dotGeneralChoirModule;
const dotGeneralF16ChoirModule = fixture.dotGeneralF16ChoirModule;
const reduceChoirModule = fixture.reduceChoirModule;
const reduceI32ChoirModule = fixture.reduceI32ChoirModule;
const escapedTwoKernelChoirModule = fixture.escapedTwoKernelChoirModule;
const kernelCallChoirModule = fixture.kernelCallChoirModule;
const aliasedKernelCallChoirModule = fixture.aliasedKernelCallChoirModule;
const createTestBackendArtifactPlan = fixture.createTestBackendArtifactPlan;
const bufferBinding = fixture.bufferBinding;
const slotBindingsForKernel = fixture.slotBindingsForKernel;
const slotBindingsForPlan = fixture.slotBindingsForPlan;
const elementCountBindingsForPlan = fixture.elementCountBindingsForPlan;
const firstElementCountBinding = fixture.firstElementCountBinding;

pub const FragmentCompilerOptions = struct {
    /// Limits on the compiler context that tensor lowering builds its semantic
    /// module in, for sizing the memory used when a tensor program is lowered
    /// into the compiler's semantic form. Only tensor lowering reads this
    /// limit, so compiling from a semantic module the caller already built
    /// ignores it. A limit too small for the program makes the refresh fail
    /// with `error.OutOfMemory`.
    semantic_context_limits: semantic.Builder.ContextLimits = .standard,
    artifact_format: ?gpu.ArtifactFormat = null,
    math_tier: gpu.BackendMathTier = .exact,
    kernel_call_registry: ?*const artifact_product.KernelCallRegistry = null,
    matrix_product_schedule: ?kernel_library.MatrixProductSchedule = null,
    gather_schedule: ?kernel_library.GatherSchedule = null,
    scatter_schedule: ?kernel_library.ScatterSchedule = null,
    scatter_add_schedule: ?kernel_library.ScatterAddSchedule = null,
    row_sparse_cross_entropy_schedule: ?kernel_library.RowSparseCrossEntropySchedule = null,
    generated_scan_schedule: ?preparation.target.GeneratedScanSchedule = null,
    generated_scan_schedule_tuning_artifact: []const u8 = &.{},
    generated_row_pipeline_schedule: ?preparation.target.GeneratedRowPipelineSchedule = null,
    generated_row_pipeline_schedule_tuning_artifact: []const u8 = &.{},
    family_tuning: ?*const kernel_library.tuning.FamilyTuningReader = null,
    family_tuning_artifact: []const u8 = &.{},
    matrix_product_schedule_tuning_artifact: []const u8 = &.{},
    authored_kernel_diagnostic_id: ?[]const u8 = null,
    launch_tuning_artifact: []const u8 = &.{},
    preparation_failure: ?*preparation.BackendPreparationFailure = null,
    instrumentation: FragmentInstrumentation = .{},
};

pub const KernelCompilerOptions = struct {
    artifact_format: ?gpu.ArtifactFormat = null,
    authored_kernel_diagnostic_id: ?[]const u8 = null,
    instrumentation: FragmentInstrumentation = .{},
};

pub const LaunchOptions = exec_product.LaunchOptions;

const LoadedFragmentState = struct {
    allocator: std.mem.Allocator,
    compiled_fragment: *exec_product.CompiledFragment,
    loaded_kernels: LoadedKernels,
    tuning_cache: LaunchTuningCache,
    prepared_plan: ?OwnedLaunchGraphPlan = null,

    fn deinit(self: *LoadedFragmentState) void {
        if (self.prepared_plan) |*prepared| prepared.deinit();
        self.tuning_cache.deinit();
        self.loaded_kernels.deinit();
        self.compiled_fragment.deinit();
        self.* = undefined;
    }
};

pub const LoadedFragment = opaque {
    fn stateConst(self: *const LoadedFragment) *const LoadedFragmentState {
        return @ptrCast(@alignCast(self));
    }

    fn stateMut(self: *LoadedFragment) *LoadedFragmentState {
        return @ptrCast(@alignCast(self));
    }

    fn artifactPlan(self: *const LoadedFragment) *const artifact_product.BackendArtifactPlan {
        const state = self.stateConst();
        return state.compiled_fragment.artifactPlan();
    }

    fn loadedKernelCount(self: *const LoadedFragment) usize {
        const state = self.stateConst();
        return state.loaded_kernels.kernelCount();
    }

    pub fn deinit(self: *LoadedFragment) void {
        const state = self.stateMut();
        const allocator = state.allocator;
        state.deinit();
        allocator.destroy(state);
    }

    pub fn tuningRecordCount(self: *const LoadedFragment) usize {
        return self.stateConst().tuning_cache.count();
    }

    pub fn compiledFingerprint(self: *const LoadedFragment) u64 {
        return self.stateConst().compiled_fragment.fingerprint();
    }

    pub fn kernelCount(self: *const LoadedFragment) usize {
        return self.artifactPlan().kernelCount();
    }

    pub fn kernelSummary(
        self: *const LoadedFragment,
        kernel_index: usize,
    ) gpu.BackendError!artifact_product.KernelSummary {
        return try artifact_product.summarizePlannedKernel(try self.plannedKernel(kernel_index));
    }

    pub fn kernelSummaryForWork(
        self: *const LoadedFragment,
        work_item_id: usize,
    ) gpu.BackendError!artifact_product.KernelSummary {
        for (self.artifactPlan().kernels.items) |kernel| {
            if (kernel.work_item_id == work_item_id) {
                return try artifact_product.summarizePlannedKernel(kernel);
            }
        }
        return error.InvalidArtifact;
    }

    pub fn copyKernelSummaries(
        self: *const LoadedFragment,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError!artifact_product.KernelSummaries {
        const kernels = self.artifactPlan().kernels.items;
        const items = result_allocator.alloc(
            artifact_product.KernelSummary,
            kernels.len,
        ) catch return error.OutOfMemory;
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |summary| {
                result_allocator.free(summary.entry_name);
            }
            result_allocator.free(items);
        }

        for (items, kernels) |*item, kernel| {
            item.* = try artifact_product.copyKernelSummary(
                result_allocator,
                try artifact_product.summarizePlannedKernel(kernel),
            );
            copied += 1;
        }

        return .{
            .allocator = result_allocator,
            .items = items,
        };
    }

    pub fn copyKernelArtifact(
        self: *const LoadedFragment,
        allocator: std.mem.Allocator,
        kernel_index: usize,
    ) gpu.BackendError!gpu.KernelArtifact {
        const planned = try self.plannedKernel(kernel_index);
        return try copyKernelArtifactToAllocator(allocator, planned.artifact);
    }

    fn plannedKernel(
        self: *const LoadedFragment,
        kernel_index: usize,
    ) gpu.BackendError!artifact_product.PlannedKernel {
        const artifact_plan = self.artifactPlan();
        if (kernel_index >= artifact_plan.kernels.items.len) return error.InvalidArtifact;
        return artifact_plan.kernels.items[kernel_index];
    }

    fn launchResourceCandidate(
        self: *const LoadedFragment,
        kernel_index: usize,
        candidate_index: usize,
    ) gpu.BackendError!artifact_product.LaunchResourceCandidate {
        const kernel = try self.plannedKernel(kernel_index);
        if (candidate_index >= kernel.launch_resources.candidate_count) {
            return error.LaunchArgumentMismatch;
        }
        return kernel.launch_resources.candidates[candidate_index];
    }

    pub fn importLaunchTuningArtifact(
        self: *LoadedFragment,
        scratch: std.mem.Allocator,
        bytes: []const u8,
    ) gpu.BackendError!void {
        const state = self.stateMut();
        const records = try decodeLaunchTuningArtifact(scratch, bytes);
        defer scratch.free(records);
        try state.tuning_cache.importRecords(records);
        try self.refreshPreparedLaunchGraphPlan();
    }

    pub fn replaceLaunchTuningArtifact(
        self: *LoadedFragment,
        scratch: std.mem.Allocator,
        bytes: []const u8,
    ) gpu.BackendError!void {
        const state = self.stateMut();
        var tuning_cache = LaunchTuningCache.init(state.allocator);
        errdefer tuning_cache.deinit();
        if (bytes.len != 0) {
            const records = try decodeLaunchTuningArtifact(scratch, bytes);
            defer scratch.free(records);
            try tuning_cache.importRecords(records);
        }
        state.tuning_cache.deinit();
        state.tuning_cache = tuning_cache;
        try self.refreshPreparedLaunchGraphPlan();
    }

    pub fn exportLaunchTuningArtifact(
        self: *const LoadedFragment,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError![]u8 {
        const state = self.stateConst();
        const records = try state.tuning_cache.exportRecords(result_allocator);
        defer result_allocator.free(records);
        return try encodeLaunchTuningArtifact(result_allocator, records);
    }

    pub fn recordLaunchCandidateRecords(
        self: *LoadedFragment,
        records: []const LaunchCandidateRecord,
    ) gpu.BackendError!void {
        const state = self.stateMut();
        const artifact_plan = state.compiled_fragment.artifactPlan();
        const caps = try state.loaded_kernels.handle.queryCapabilities();
        for (records) |record| _ = try plannedKernelForLaunchCandidateRecord(artifact_plan, record);
        for (records) |record| {
            const planned = try plannedKernelForLaunchCandidateRecord(artifact_plan, record);
            try state.tuning_cache.recordMeasuredSelection(caps, planned, .{
                .kernel_id = record.kernel.kernel_id,
                .candidate_index = record.candidate_index,
                .median_ns = record.median_ns,
                .sample_count = record.sample_count,
            });
        }
        try self.refreshPreparedLaunchGraphPlan();
    }

    pub fn createLaunchGraphPlan(
        self: *const LoadedFragment,
        allocator: std.mem.Allocator,
        launch_options: LaunchOptions,
    ) gpu.BackendError!OwnedLaunchGraphPlan {
        const state = self.stateConst();
        var graph = try state.compiled_fragment.createLaunchGraphPlan(allocator, launch_options);
        errdefer graph.deinit();
        if (state.tuning_cache.count() != 0 and
            tuning_mod.launchTuningIsEmpty(launch_options.tuning))
        {
            try graph.applyCachedLaunchTuning(
                try state.loaded_kernels.handle.queryCapabilities(),
                state.compiled_fragment.artifactPlan(),
                &state.tuning_cache,
            );
            graph.validated = false;
            const view = graph.plan();
            try exec_product.validateLaunchGraph(
                allocator,
                state.compiled_fragment.artifactPlan(),
                view,
                exec_product.launchGraphNeedsDependencyEvents(view),
            );
            graph.validated = true;
        }
        return graph;
    }

    fn refreshPreparedLaunchGraphPlan(self: *LoadedFragment) gpu.BackendError!void {
        const state = self.stateMut();
        var next = try self.createLaunchGraphPlan(state.allocator, .{});
        errdefer next.deinit();
        if (state.prepared_plan) |*existing| existing.deinit();
        state.prepared_plan = next;
    }

    pub fn prepareInvocationBindings(
        self: *const LoadedFragment,
        allocator: std.mem.Allocator,
        inputs: []const []const u8,
    ) !*PreparedLaunchBindings {
        const state = self.stateConst();
        return try binding_mod.prepare(
            allocator,
            state.loaded_kernels.handle,
            state.compiled_fragment.artifactPlan(),
            inputs,
        );
    }

    fn submitPreparedForTest(
        self: *const LoadedFragment,
        scratch: std.mem.Allocator,
        bindings: *const PreparedLaunchBindings,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        if (state.prepared_plan) |*prepared| {
            try self.launchGraph(
                scratch,
                binding_mod.slotBindings(bindings),
                binding_mod.elementCountBindings(bindings),
                prepared.plan(),
            );
            return;
        }
        try self.submitInvocationWithOptions(scratch, bindings, .{});
    }

    pub fn submitInvocationWithOptions(
        self: *const LoadedFragment,
        scratch: std.mem.Allocator,
        bindings: *const PreparedLaunchBindings,
        launch_options: LaunchOptions,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        if (launchOptionsUsePreparedPlan(launch_options)) {
            const prepared = if (state.prepared_plan) |*plan|
                plan
            else
                return error.InvalidArtifact;
            try self.launchGraph(
                scratch,
                binding_mod.slotBindings(bindings),
                binding_mod.elementCountBindings(bindings),
                prepared.plan(),
            );
            return;
        }
        try self.launchAllWithOptions(
            scratch,
            binding_mod.slotBindings(bindings),
            binding_mod.elementCountBindings(bindings),
            launch_options,
        );
    }

    pub fn submitInvocationWithGraph(
        self: *const LoadedFragment,
        scratch: std.mem.Allocator,
        bindings: *const PreparedLaunchBindings,
        graph: LaunchGraphPlan,
    ) gpu.BackendError!void {
        try self.launchGraph(
            scratch,
            binding_mod.slotBindings(bindings),
            binding_mod.elementCountBindings(bindings),
            graph,
        );
    }

    pub fn completeInvocationWithOptions(
        self: *const LoadedFragment,
        options: LaunchOptions,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        if (options.signal_event) |event| {
            try state.loaded_kernels.handle.synchronize(.{ .scope = .event, .event = event });
        } else if (options.stream) |stream| {
            try state.loaded_kernels.handle.synchronize(.{ .scope = .stream, .stream = stream });
        } else {
            try state.loaded_kernels.handle.synchronize(.{ .scope = .default_stream });
        }
    }

    pub fn completeInvocationGraph(
        self: *const LoadedFragment,
        graph: LaunchGraphPlan,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        if (graph.nodes.len == 0) return error.InvalidArtifact;
        var reverse_index = graph.nodes.len;
        while (reverse_index != 0) {
            reverse_index -= 1;
            const node = graph.nodes[reverse_index];
            var later_same_stream = false;
            for (graph.nodes[reverse_index + 1 ..]) |later| {
                if (sameOptionalStream(node.stream, later.stream)) {
                    later_same_stream = true;
                    break;
                }
            }
            if (later_same_stream) continue;
            if (node.signal_event) |event| {
                try state.loaded_kernels.handle.synchronize(.{ .scope = .event, .event = event });
            } else if (node.stream) |stream| {
                try state.loaded_kernels.handle.synchronize(
                    .{ .scope = .stream, .stream = stream },
                );
            } else {
                try state.loaded_kernels.handle.synchronize(.{ .scope = .default_stream });
            }
        }
    }

    pub fn outputCount(self: *const LoadedFragment) usize {
        return self.artifactPlan().output_slot_ids.len;
    }

    pub fn outputSlot(
        self: *const LoadedFragment,
        index: usize,
    ) ?*const artifact_product.PlannedSlot {
        const plan = self.artifactPlan();
        if (index >= plan.output_slot_ids.len) return null;
        return plan.slotById(plan.output_slot_ids[index]);
    }

    pub fn readInvocationOutput(
        self: *const LoadedFragment,
        bindings: *const PreparedLaunchBindings,
        index: usize,
        host_bytes: []u8,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        const plan = state.compiled_fragment.artifactPlan();
        if (index >= plan.output_slot_ids.len) return error.InvalidArtifact;
        const slot_id = plan.output_slot_ids[index];
        const slot = plan.slotById(slot_id) orelse return error.InvalidArtifact;
        const byte_size_u64 = slot.byte_size orelse return error.UnsupportedOperation;
        const byte_size = std.math.cast(usize, byte_size_u64) orelse return error.InvalidArtifact;
        if (host_bytes.len < byte_size) return error.ReadBufferDestinationTooSmall;
        if (host_bytes.len > byte_size) return error.InvalidBuffer;
        const binding = try binding_mod.bindingForSlot(
            binding_mod.slotBindings(bindings),
            slot_id,
            .read_only,
        );
        try state.loaded_kernels.handle.readBuffer(.{
            .handle = binding.handle,
            .bytes = host_bytes,
        });
    }

    fn invokeAndReadForTest(
        self: *const LoadedFragment,
        allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        inputs: []const []const u8,
        outputs: []const []u8,
    ) gpu.BackendError!void {
        if (outputs.len != self.outputCount()) return error.InvalidArtifact;
        const bindings = try self.prepareInvocationBindings(allocator, inputs);
        defer bindings.deinit();
        try self.submitPreparedForTest(scratch, bindings);
        try self.completeInvocationWithOptions(.{});
        for (outputs, 0..) |host_bytes, index| {
            try self.readInvocationOutput(bindings, index, host_bytes);
        }
    }

    pub fn measureInvocationLaunchCandidates(
        self: *const LoadedFragment,
        result_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        kernel_index: usize,
        bindings: *const PreparedLaunchBindings,
        options: LaunchCandidateBenchmarkOptions,
    ) gpu.BackendError![]LaunchCandidateRecord {
        const state = self.stateConst();
        const kernel = try self.plannedKernel(kernel_index);
        const artifact_plan = state.compiled_fragment.artifactPlan();
        const measurements = try state.loaded_kernels.measureLaunchCandidates(
            scratch,
            scratch,
            artifact_plan,
            kernel_index,
            binding_mod.slotBindings(bindings),
            binding_mod.elementCountBindingForKernel(bindings, kernel.kernel_id),
            options,
        );
        defer scratch.free(measurements);

        const records = result_allocator.alloc(
            LaunchCandidateRecord,
            measurements.len,
        ) catch return error.OutOfMemory;
        errdefer result_allocator.free(records);
        for (measurements, 0..) |measurement, index| {
            const candidate = try self.launchResourceCandidate(
                kernel_index,
                measurement.candidate_index,
            );
            records[index] = try launchCandidateRecord(kernel, candidate, measurement);
        }
        return records;
    }

    pub fn measureAndRecordInvocationLaunchCandidates(
        self: *LoadedFragment,
        result_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        bindings: *const PreparedLaunchBindings,
        options: LaunchCandidateBenchmarkOptions,
    ) gpu.BackendError![]LaunchCandidateRecord {
        var records = std.ArrayListUnmanaged(LaunchCandidateRecord).empty;
        errdefer records.deinit(result_allocator);

        var kernel_index: usize = 0;
        while (kernel_index < self.kernelCount()) : (kernel_index += 1) {
            const kernel = try self.plannedKernel(kernel_index);
            if (kernel.launch_resources.candidate_count <= 1) continue;

            const measured = try self.measureInvocationLaunchCandidates(
                scratch,
                scratch,
                kernel_index,
                bindings,
                options,
            );
            defer scratch.free(measured);
            records.appendSlice(result_allocator, measured) catch return error.OutOfMemory;
        }

        const owned_records = records.toOwnedSlice(result_allocator) catch return error.OutOfMemory;
        errdefer result_allocator.free(owned_records);
        try self.recordLaunchCandidateRecords(owned_records);
        return owned_records;
    }

    fn launchAll(
        self: *const LoadedFragment,
        scratch: std.mem.Allocator,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
    ) gpu.BackendError!void {
        try self.launchAllWithOptions(
            scratch,
            slot_bindings,
            element_count_buffers,
            .{},
        );
    }

    fn launchAllWithOptions(
        self: *const LoadedFragment,
        scratch: std.mem.Allocator,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        launch_options: LaunchOptions,
    ) gpu.BackendError!void {
        var graph = try self.createLaunchGraphPlan(scratch, launch_options);
        defer graph.deinit();
        try self.launchGraph(scratch, slot_bindings, element_count_buffers, graph.plan());
    }

    fn launchGraph(
        self: *const LoadedFragment,
        scratch: std.mem.Allocator,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        graph: LaunchGraphPlan,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        const artifact_plan = state.compiled_fragment.artifactPlan();
        try state.loaded_kernels.launchGraph(
            scratch,
            artifact_plan,
            slot_bindings,
            element_count_buffers,
            graph,
        );
    }

    fn launchGraphWithDependencyEvents(
        self: *const LoadedFragment,
        scratch: std.mem.Allocator,
        slot_bindings: []const SlotBinding,
        element_count_buffers: []const ElementCountBufferBinding,
        graph: LaunchGraphPlan,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        const artifact_plan = state.compiled_fragment.artifactPlan();
        try state.loaded_kernels.launchGraphWithDependencyEvents(
            scratch,
            artifact_plan,
            slot_bindings,
            element_count_buffers,
            graph,
        );
    }

    pub fn launchKernelWithArguments(
        self: *const LoadedFragment,
        kernel_index: usize,
        buffers: []const gpu.BufferBinding,
        scalar_arguments: []const gpu_abi.ScalarArgument,
        launch_options: LaunchOptions,
    ) gpu.BackendError!void {
        const state = self.stateConst();
        const artifact_plan = state.compiled_fragment.artifactPlan();
        try state.loaded_kernels.launchKernelWithArguments(
            artifact_plan,
            kernel_index,
            buffers,
            scalar_arguments,
            launch_options,
        );
    }
};

fn launchOptionsUsePreparedPlan(options: LaunchOptions) bool {
    return options.stream == null and
        options.wait_events.len == 0 and
        options.signal_event == null and
        tuning_mod.launchTuningIsEmpty(options.tuning) and
        options.runtime_scalar_arguments.len == 0;
}

fn sameOptionalStream(a: ?gpu.StreamHandle, b: ?gpu.StreamHandle) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.id == b.?.id and a.?.backend == b.?.backend;
}

fn artifactPlanOptions(options: FragmentCompilerOptions) artifact_product.ArtifactPlanOptions {
    return .{
        .format = options.artifact_format,
        .kernel_call_registry = options.kernel_call_registry,
    };
}

pub fn backendTargetProfile(
    handle: gpu.BackendHandle,
    requested_format: ?gpu.ArtifactFormat,
    math_tier: gpu.BackendMathTier,
) gpu.BackendError!preparation.BackendTargetProfile {
    const caps = try handle.queryCapabilities();
    const kind = handle.backendKind() orelse caps.identity.backend;
    const format = requested_format orelse
        artifact_product.defaultArtifactFormat(kind) orelse return error.UnsupportedOperation;
    return try preparation.BackendTargetProfile.initWithMathTier(caps, kind, format, math_tier);
}

pub fn recordBackendPreparationRun(
    instrumentation: FragmentInstrumentation,
    run: preparation.BackendPreparationRun,
) !void {
    try instrumentation.recordElapsed(.run_contract_pipeline, run.contract_ns);
    try instrumentation.recordElapsed(.run_tensor_pipeline, run.tensor_ns);
    try instrumentation.recordElapsed(.run_dispatch_pipeline, run.dispatch_ns);
    try instrumentation.recordElapsed(.run_memory_pipeline, run.memory_ns);
    try instrumentation.recordElapsed(.run_kernel_pipeline, run.kernel_ns);
    try instrumentation.recordElapsed(.run_target_pipeline, run.target_ns);
}

pub fn loadFragment(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    compiled_fragment: *exec_product.CompiledFragment,
    options: FragmentCompilerOptions,
) !*LoadedFragment {
    var compiled_owned = true;
    defer if (compiled_owned) compiled_fragment.deinit();

    var tuning_cache = LaunchTuningCache.init(allocator);
    var tuning_owned = true;
    errdefer if (tuning_owned) tuning_cache.deinit();
    const tuning_start = nowNs();
    if (options.launch_tuning_artifact.len != 0) {
        const records = try decodeLaunchTuningArtifact(allocator, options.launch_tuning_artifact);
        defer allocator.free(records);
        try tuning_cache.importRecords(records);
        try options.instrumentation.record(.import_launch_tuning, tuning_start);
    }

    var loaded_kernels = try loadKernelsWithInstrumentation(
        allocator,
        handle,
        compiled_fragment.artifactPlan(),
        options.instrumentation,
    );
    var kernels_owned = true;
    errdefer if (kernels_owned) loaded_kernels.deinit();

    const state = allocator.create(LoadedFragmentState) catch return error.OutOfMemory;
    var state_owned = true;
    errdefer if (state_owned) allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .compiled_fragment = compiled_fragment,
        .loaded_kernels = loaded_kernels,
        .tuning_cache = tuning_cache,
    };
    compiled_owned = false;
    tuning_owned = false;
    kernels_owned = false;
    state_owned = false;
    const fragment: *LoadedFragment = @ptrCast(state);
    errdefer fragment.deinit();
    try fragment.refreshPreparedLaunchGraphPlan();
    return fragment;
}

/// Compiles the stored stage results of `prepared`, rebuilding their plans
/// inside the caller's `workspace`, into a compiled fragment so the caller can
/// turn a finished preparation into device code it can later load. The returned
/// fragment copies the kernel list and its plan, so it stays valid after the
/// caller releases `workspace` and `prepared`. The step records its time as
/// `compile_fragment` in the instrumentation.
pub fn compileFragmentFromPreparedModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    prepared: *const preparation.pipeline.BackendPreparedModule,
    options: FragmentCompilerOptions,
    workspace: []u8,
    comptime configuration: choir.product.operation.Configuration,
) !*exec_product.CompiledFragment {
    const job = try createArtifactJobFromPreparedModule(
        allocator,
        handle,
        prepared,
        options,
        workspace,
        configuration,
    );
    defer job.deinit();
    const start = nowNs();
    const fragment = try exec_product.compileFragmentFromArtifactJob(allocator, job);
    errdefer fragment.deinit();
    try options.instrumentation.record(.compile_fragment, start);
    return fragment;
}

/// Compiles the stored stage results of `prepared`, using `workspace` for the
/// rebuilt plans, into a new artifact job that the caller frees with `deinit`,
/// so the caller can obtain the compiled kernels by themselves before building
/// a runnable fragment. The job is built from the stored records of `prepared`
/// alone and holds no live compile job of any stage. The step records its time
/// as `plan_create_backend_artifacts`.
pub fn createArtifactJobFromPreparedModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    prepared: *const preparation.pipeline.BackendPreparedModule,
    options: FragmentCompilerOptions,
    workspace: []u8,
    comptime configuration: choir.product.operation.Configuration,
) !*artifact_product.ArtifactJob {
    const start = nowNs();
    var plan = try artifact_product.createBackendArtifactPlanFromPreparedModule(
        allocator,
        handle,
        prepared,
        artifactPlanOptions(options),
        workspace,
        configuration,
    );
    var plan_owned = true;
    errdefer if (plan_owned) plan.deinit();
    const job = try artifact_product.ArtifactJob.init(allocator, plan);
    plan_owned = false;
    errdefer job.deinit();
    try options.instrumentation.record(.plan_create_backend_artifacts, start);
    return job;
}

pub fn compileFragmentFromPreparedJob(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    prepared: *preparation.BackendPreparedJob,
    options: FragmentCompilerOptions,
) !*exec_product.CompiledFragment {
    const artifact_module = try createArtifactJobFromPreparedJob(
        allocator,
        handle,
        prepared,
        options,
    );
    defer artifact_module.deinit();
    const exec_start = nowNs();
    const fragment = try exec_product.compileFragmentFromArtifactJob(allocator, artifact_module);
    errdefer fragment.deinit();
    try options.instrumentation.record(.compile_fragment, exec_start);
    return fragment;
}

pub fn createArtifactJobFromPreparedJob(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    prepared: *preparation.BackendPreparedJob,
    options: FragmentCompilerOptions,
) !*artifact_product.ArtifactJob {
    const target_module = try prepared.targetModule();
    const artifact_start = nowNs();
    const artifact_module = try artifact_product.createArtifactJobFromTargetJob(
        allocator,
        handle,
        target_module,
        artifactPlanOptions(options),
    );
    errdefer artifact_module.deinit();
    try options.instrumentation.record(.plan_create_backend_artifacts, artifact_start);
    return artifact_module;
}

pub const FragmentPreparationPlan = struct {
    allocator: std.mem.Allocator,
    decoded_family_tuning: ?kernel_library.tuning.OwnedFamilyTuningRecords,
    decoded_family_tuning_reader: kernel_library.tuning.FamilyTuningReader,
    matrix_product_tuning_records: []kernel_library.tuning.MatrixProductFamilyScheduleTuningRecord,
    generated_scan_schedule_decisions: []preparation.target.GeneratedScanScheduleDecision,
    generated_row_pipeline_schedule_decisions: []preparation.target.GeneratedRowPipelineScheduleDecision,
    run_options: preparation.BackendPreparationRunOptions,

    pub fn init(
        self: *FragmentPreparationPlan,
        allocator: std.mem.Allocator,
        handle: gpu.BackendHandle,
        options: FragmentCompilerOptions,
    ) !void {
        const target_profile = try backendTargetProfile(
            handle,
            options.artifact_format,
            options.math_tier,
        );
        self.allocator = allocator;
        self.decoded_family_tuning = null;
        self.matrix_product_tuning_records = &.{};
        self.generated_scan_schedule_decisions = &.{};
        self.generated_row_pipeline_schedule_decisions = &.{};
        errdefer self.deinit();

        var family_tuning = options.family_tuning;
        if (family_tuning == null and options.family_tuning_artifact.len != 0) {
            self.decoded_family_tuning = try kernel_library.tuning.decodeFamilyTuningArtifact(
                allocator,
                options.family_tuning_artifact,
            );
            self.decoded_family_tuning_reader = kernel_library.tuning.FamilyTuningReader.init(
                try handle.queryCapabilities(),
                self.decoded_family_tuning.?.table(),
            );
            family_tuning = &self.decoded_family_tuning_reader;
        }

        var matrix_product_tuning: ?kernel_library.linalg.MatrixProductScheduleReader = null;
        if (options.matrix_product_schedule == null and
            options.matrix_product_schedule_tuning_artifact.len != 0)
        {
            const decoded = try schedule_tuning.decodeMatrixProductFamilyScheduleTuningArtifact(
                allocator,
                options.matrix_product_schedule_tuning_artifact,
            );
            defer allocator.free(decoded);
            var cache = schedule_tuning.MatrixProductFamilyScheduleTuningCache.init(allocator);
            defer cache.deinit();
            try cache.importRecords(decoded);
            self.matrix_product_tuning_records = try cache.exportRecords(allocator);
            matrix_product_tuning = .{
                .device = (try handle.queryCapabilities()).identity,
                .format = target_profile.artifact_format,
                .records = self.matrix_product_tuning_records,
            };
        }

        if (options.generated_scan_schedule) |schedule| {
            const decisions = allocator.alloc(
                preparation.target.GeneratedScanScheduleDecision,
                1,
            ) catch return error.OutOfMemory;
            decisions[0] = .{ .schedule = schedule };
            self.generated_scan_schedule_decisions = decisions;
        } else if (options.generated_scan_schedule_tuning_artifact.len != 0) {
            const records = try schedule_tuning.decodeGeneratedScanScheduleTuningArtifact(
                allocator,
                options.generated_scan_schedule_tuning_artifact,
            );
            defer allocator.free(records);
            const caps = try handle.queryCapabilities();
            var decisions = std.ArrayListUnmanaged(
                preparation.target.GeneratedScanScheduleDecision,
            ).empty;
            errdefer decisions.deinit(allocator);
            for (records) |record| {
                if (record.key.format != target_profile.artifact_format) continue;
                if (record.key.dtype != .f32) continue;
                var candidate_buffer: [preparation.kernelization.max_scan_schedule_candidates]preparation.target.GeneratedScanSchedule = undefined;
                const candidates = preparation.kernelization.scanScheduleCandidates(
                    record.key.total,
                    target_profile.artifact_format,
                    &candidate_buffer,
                );
                if (candidates.len < 2) continue;
                const key = try schedule_tuning.GeneratedScanScheduleTuningKey.init(caps, .{
                    .format = target_profile.artifact_format,
                    .total = record.key.total,
                    .dtype = record.key.dtype,
                    .schedule_version = preparation.kernelization.generated_scan_schedule_version,
                    .candidates = candidates,
                });
                if (!key.eql(record.key)) continue;
                decisions.append(allocator, .{
                    .total = record.key.total,
                    .schedule = record.selection.schedule,
                }) catch return error.OutOfMemory;
            }
            self.generated_scan_schedule_decisions = decisions.toOwnedSlice(
                allocator,
            ) catch return error.OutOfMemory;
        }

        if (options.generated_row_pipeline_schedule) |schedule| {
            const decisions = allocator.alloc(
                preparation.target.GeneratedRowPipelineScheduleDecision,
                1,
            ) catch return error.OutOfMemory;
            decisions[0] = .{ .schedule = schedule };
            self.generated_row_pipeline_schedule_decisions = decisions;
        } else if (options.generated_row_pipeline_schedule_tuning_artifact.len != 0) {
            const records = try schedule_tuning.decodeGeneratedRowPipelineScheduleTuningArtifact(
                allocator,
                options.generated_row_pipeline_schedule_tuning_artifact,
            );
            defer allocator.free(records);
            const caps = try handle.queryCapabilities();
            var decisions = std.ArrayListUnmanaged(
                preparation.target.GeneratedRowPipelineScheduleDecision,
            ).empty;
            errdefer decisions.deinit(allocator);
            for (records) |record| {
                if (record.key.format != target_profile.artifact_format) continue;
                if (record.key.dtype != .f32) continue;
                var candidate_buffer: [preparation.kernelization.max_row_pipeline_schedule_candidates]preparation.target.GeneratedRowPipelineSchedule = undefined;
                const candidates = preparation.kernelization.rowPipelineScheduleCandidates(
                    record.key.cols,
                    target_profile.artifact_format,
                    &candidate_buffer,
                );
                if (candidates.len < 2) continue;
                const key = try schedule_tuning.GeneratedRowPipelineScheduleTuningKey.init(caps, .{
                    .format = target_profile.artifact_format,
                    .rows = record.key.rows,
                    .cols = record.key.cols,
                    .dtype = record.key.dtype,
                    .schedule_version = preparation.kernelization.generated_row_pipeline_schedule_version,
                    .candidates = candidates,
                });
                if (!key.eql(record.key)) continue;
                decisions.append(allocator, .{
                    .shape = .{ .rows = record.key.rows, .cols = record.key.cols },
                    .schedule = record.selection.schedule,
                }) catch return error.OutOfMemory;
            }
            self.generated_row_pipeline_schedule_decisions = decisions.toOwnedSlice(
                allocator,
            ) catch return error.OutOfMemory;
        }

        const kernel_library_lowering: preparation.KernelLibraryLowering = if (options.kernel_call_registry != null)
            .enabled
        else
            .disabled;
        self.run_options = .{
            .failure = options.preparation_failure,
            .target_profile = target_profile,
            .generated_scan_schedules = self.generated_scan_schedule_decisions,
            .generated_row_pipeline_schedules = self.generated_row_pipeline_schedule_decisions,
            .tensor = .{
                .activation = .{ .kernel_library = kernel_library_lowering },
                .einsum = .{
                    .kernel_library = kernel_library_lowering,
                    .matrix_product_schedule = options.matrix_product_schedule,
                    .matrix_product_tuning = matrix_product_tuning,
                    .family_tuning = family_tuning,
                },
                .indexing = .{
                    .kernel_library = kernel_library_lowering,
                    .gather_schedule = options.gather_schedule,
                    .scatter_schedule = options.scatter_schedule,
                    .scatter_add_schedule = options.scatter_add_schedule,
                    .family_tuning = family_tuning,
                },
                .loss = .{
                    .kernel_library = kernel_library_lowering,
                    .row_sparse_cross_entropy_schedule = options.row_sparse_cross_entropy_schedule,
                },
            },
        };
    }

    pub fn deinit(self: *FragmentPreparationPlan) void {
        if (self.generated_row_pipeline_schedule_decisions.len != 0) {
            self.allocator.free(self.generated_row_pipeline_schedule_decisions);
        }
        if (self.generated_scan_schedule_decisions.len != 0) {
            self.allocator.free(self.generated_scan_schedule_decisions);
        }
        self.allocator.free(self.matrix_product_tuning_records);
        if (self.decoded_family_tuning) |*owned| owned.deinit();
        self.* = undefined;
    }
};

pub fn prepareFragmentFromSemanticModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    module: *semantic.SemanticModule,
    options: FragmentCompilerOptions,
) !preparation.BackendPreparedJob {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    var plan: FragmentPreparationPlan = undefined;
    try plan.init(allocator, handle, options);
    defer plan.deinit();

    module_owned = false;
    return try preparation.prepareBackendJobFromSemanticModule(allocator, module, plan.run_options);
}

pub fn compileFragmentFromSemanticModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    module: *semantic.SemanticModule,
    options: FragmentCompilerOptions,
) !*exec_product.CompiledFragment {
    var prepared = try prepareFragmentFromSemanticModule(allocator, handle, module, options);
    defer prepared.deinit();

    try recordBackendPreparationRun(options.instrumentation, prepared.run);
    return try compileFragmentFromPreparedJob(allocator, handle, &prepared, options);
}

fn nowNs() i128 {
    return sys.time.nanoTimestamp();
}

const testing = std.testing;

fn createTestLoadedFragment(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    pass_ctx: *passes.PassContext,
    choir_module: *ir.Operation,
    options: FragmentCompilerOptions,
) !*LoadedFragment {
    const artifact_start = nowNs();
    var artifact_plan = try createTestBackendArtifactPlan(
        allocator,
        handle,
        pass_ctx,
        choir_module,
        artifactPlanOptions(options),
    );
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();

    const artifact_module = try artifact_product.ArtifactJob.init(
        allocator,
        artifact_plan,
    );
    plan_owned = false;
    defer artifact_module.deinit();
    try options.instrumentation.record(.plan_create_backend_artifacts, artifact_start);
    const exec_start = nowNs();
    const compiled = try exec_product.compileFragmentFromArtifactJob(allocator, artifact_module);
    try options.instrumentation.record(.compile_fragment, exec_start);
    return try loadFragment(allocator, handle, compiled, options);
}

fn compileAndLoadTestSemanticModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    module: *semantic.SemanticModule,
    options: FragmentCompilerOptions,
) !*LoadedFragment {
    const compiled = try compileFragmentFromSemanticModule(allocator, handle, module, options);
    return try loadFragment(allocator, handle, compiled, options);
}

fn compileAndLoadTestPreparedJob(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    prepared: *preparation.BackendPreparedJob,
    options: FragmentCompilerOptions,
) !*LoadedFragment {
    const compiled = try compileFragmentFromPreparedJob(allocator, handle, prepared, options);
    return try loadFragment(allocator, handle, compiled, options);
}

fn runDotGeneralNativeCpuFragment(format: gpu.ArtifactFormat) !void {
    const allocator = testing.allocator;

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 2, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 2 });
    const out_ty = try builder.tensor(.f32, &.{ 2, 2 });
    const module_name = switch (format) {
        .cpu_machine_code => "choir_cpu_dot_general_machine_code",
        .cpu_object => "choir_cpu_dot_general_object",
        else => return error.UnsupportedArtifactFormat,
    };
    var fb = try builder.beginFunction(module_name, &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const product = try fb.dotGeneral(
        fb.parameter(0),
        fb.parameter(1),
        out_ty,
        &.{1},
        &.{0},
        &.{},
        &.{},
    );
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();

    var fragment = compileAndLoadTestSemanticModule(allocator, handle, module, .{
        .artifact_format = format,
    }) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer fragment.deinit();

    const summary = try fragment.kernelSummary(0);
    try testing.expectEqual(format, summary.artifact_format);
    try testing.expectEqual(artifact_product.KernelSource.tensor, summary.source);
    try testing.expectEqual(
        artifact_product.PlannedKernelCompileLaunch.dot_general,
        summary.compile_launch,
    );
    try testing.expectEqual(@as(usize, 1), fragment.outputCount());

    const lhs = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    const rhs = [_]f32{ 7.0, 8.0, 9.0, 10.0, 11.0, 12.0 };
    var output = @as([4]f32, @splat(0.0));
    const output_bytes = std.mem.sliceAsBytes(output[0..]);
    var outputs = [_][]u8{output_bytes};
    try fragment.invokeAndReadForTest(
        allocator,
        allocator,
        &.{ std.mem.sliceAsBytes(lhs[0..]), std.mem.sliceAsBytes(rhs[0..]) },
        &outputs,
    );

    try testing.expectEqualSlices(f32, &.{ 58.0, 64.0, 139.0, 154.0 }, output[0..]);
}

fn runKernelCallNativeCpuRuntimeScalarFragment(format: gpu.ArtifactFormat) !void {
    const allocator = testing.allocator;

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    const Axpy8F32 = kernel_library.elementwise.Axpy8F32;
    var call_artifact = Axpy8F32.createKernelCallArtifact(allocator, handle, .{
        .limits = .standard,
        .format = format,
        .runtime_scalar_argument_count = 1,
    }) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer call_artifact.deinit();

    const entry = call_artifact.entry();
    try testing.expectEqual(format, entry.format);
    try testing.expectEqual(@as(u32, 12), entry.argument_count);
    try testing.expectEqual(@as(u32, 1), entry.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        entry.static_arguments.len,
    );

    const registry = call_artifact.registry();
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    const module_name = switch (format) {
        .cpu_machine_code => "choir_cpu_machine_code_kernel_call_runtime_scalar_axpy",
        .cpu_object => "choir_cpu_object_kernel_call_runtime_scalar_axpy",
        else => return error.UnsupportedArtifactFormat,
    };
    var fb = try builder.beginFunction(module_name, &.{ f32_8, f32_8 }, &.{f32_8});
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1) },
        &.{f32_8},
        .{
            .target = Axpy8F32.target,
            .operand_effects = &.{ .read, .read },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();

    var fragment = compileAndLoadTestSemanticModule(allocator, handle, module, .{
        .artifact_format = format,
        .kernel_call_registry = &registry,
    }) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer fragment.deinit();

    const summary = try fragment.kernelSummary(0);
    try testing.expectEqual(format, summary.artifact_format);
    try testing.expectEqual(artifact_product.KernelSource.kernel_call, summary.source);
    try testing.expectEqual(@as(u32, 12), summary.compile_argument_count);
    try testing.expectEqual(@as(u32, 1), summary.runtime_scalar_argument_count);
    try testing.expectEqual(@as(usize, 1), fragment.outputCount());

    const x = [_]f32{ 1.0, 2.0, -3.0, 4.0, 0.5, -1.5, 8.0, 16.0 };
    const y = [_]f32{ 10.0, -4.0, 1.0, 2.0, 3.0, 6.0, -8.0, 0.0 };
    const inputs = [_][]const u8{
        std.mem.sliceAsBytes(x[0..]),
        std.mem.sliceAsBytes(y[0..]),
    };
    const bindings = try fragment.prepareInvocationBindings(allocator, inputs[0..]);
    defer bindings.deinit();

    var graph = try fragment.createLaunchGraphPlan(allocator, .{});
    defer graph.deinit();
    const runtime_args = [_]gpu_abi.ScalarArgument{.{ .f32 = 2.0 }};
    graph.nodes[0].runtime_scalar_arguments = runtime_args[0..];

    try fragment.submitInvocationWithGraph(allocator, bindings, graph.plan());
    try fragment.completeInvocationGraph(graph.plan());

    var output = @as([8]f32, @splat(0.0));
    try fragment.readInvocationOutput(bindings, 0, std.mem.sliceAsBytes(output[0..]));
    try testing.expectEqualSlices(
        f32,
        &.{ 12.0, 0.0, -5.0, 10.0, 4.0, 3.0, 8.0, 32.0 },
        output[0..],
    );
}

fn familyTuningBlobTestModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 7 });
    var fb = try builder.beginFunction(name, &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,kn->mn");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn findKernelCallTarget(op: *ir.Operation) ?[]const u8 {
    if (std.mem.eql(u8, op.name.name, accy_choir.dialect.AccyDialect.KernelCallOp.operation_name)) {
        const target_attr = op.getAttr("target") orelse return null;
        const target = target_attr.cast(ir.Attribute.DialectAttr) orelse return null;
        return target.payload;
    }
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                if (findKernelCallTarget(current_op)) |found| return found;
                current = current_op.next_op;
            }
        }
    }
    return null;
}

fn matrixProductScheduleTuningArtifactForThreads(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    probe: kernel_library.linalg.MatrixProduct,
    selected_threads: kernel_library.Threads2D,
) ![]u8 {
    const thread_candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(
        probe.m,
        probe.n,
    );
    const candidate_slice = thread_candidates.slice();
    try std.testing.expect(candidate_slice.len >= 2);
    const capacity = kernel_library.tuning.matrix_product_family_schedule_tuning_max_candidates;
    var schedule_candidates: [capacity]kernel_library.tuning.MatrixProductFamilyScheduleThreads =
        undefined;
    try std.testing.expect(candidate_slice.len <= schedule_candidates.len);
    for (candidate_slice, 0..) |candidate, index| {
        schedule_candidates[index] = .{ .x = candidate.x, .y = candidate.y };
    }
    const problem = kernel_library.tuning.MatrixProductFamilyScheduleTuningProblem{
        .format = .cuda_ptx,
        .m = probe.m,
        .n = probe.n,
        .k = probe.k,
        .dtype = probe.dtype,
        .accumulation_dtype = probe.accumulation_dtype,
        .family_version = kernel_library.linalg.matrix_product_family_version,
        .candidates = schedule_candidates[0..candidate_slice.len],
    };
    const record = kernel_library.tuning.MatrixProductFamilyScheduleTuningRecord{
        .key = try kernel_library.tuning.MatrixProductFamilyScheduleTuningKey.init(
            (try handle.queryCapabilities()).identity,
            problem,
        ),
        .selection = .{
            .threads = .{ .x = selected_threads.x, .y = selected_threads.y },
            .winner_median_ns = 800,
            .runner_up_median_ns = 1200,
            .sample_count = 30,
        },
    };
    return try schedule_tuning.encodeMatrixProductFamilyScheduleTuningArtifact(allocator, &.{
        record,
    });
}

fn nonHeuristicMatrixProductThreads(
    probe: kernel_library.linalg.MatrixProduct,
) !kernel_library.Threads2D {
    const heuristic = kernel_library.linalg.matrixProductThreadsForExtents(probe.m, probe.n);
    const thread_candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(
        probe.m,
        probe.n,
    );
    for (thread_candidates.slice()) |candidate| {
        if (candidate.x != heuristic.x or candidate.y != heuristic.y) return candidate;
    }
    return error.TestExpectedMatrixProductThreadCandidate;
}

fn matrixProductTuningTestDescriptor(
    allocator: std.mem.Allocator,
    threads: kernel_library.Threads2D,
) !kernel_library.OwnedCatalogDescriptor {
    const lhs_dims = [_]i64{ 5, 3 };
    const rhs_dims = [_]i64{ 3, 7 };
    const out_dims = [_]i64{ 5, 7 };
    return (try kernel_library.selectOwned(allocator, .{ .matrix_product = .{
        .dtype = .f32,
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .output_indices = "mn",
        .lhs_dims = lhs_dims[0..],
        .rhs_dims = rhs_dims[0..],
        .output_dims = out_dims[0..],
        .schedule = .{ .thread_blocks = threads },
    } })) orelse return error.TestExpectedMatrixProductThreadCandidate;
}

fn matrixProductTuningTestRegistry(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
) !kernel_library.OwnedKernelCallArtifactRegistry {
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const heuristic_threads = kernel_library.linalg.matrixProductThreadsForExtents(
        probe.m,
        probe.n,
    );
    const alternate_threads = try nonHeuristicMatrixProductThreads(probe);
    var descriptors: [2]kernel_library.OwnedCatalogDescriptor = undefined;
    var descriptor_count: usize = 0;
    defer for (descriptors[0..descriptor_count]) |*descriptor| descriptor.deinit();
    descriptors[0] = try matrixProductTuningTestDescriptor(allocator, heuristic_threads);
    descriptor_count = 1;
    descriptors[1] = try matrixProductTuningTestDescriptor(allocator, alternate_threads);
    descriptor_count = 2;
    return try kernel_library.createOwnedKernelCallArtifactRegistry(
        allocator,
        handle,
        descriptors[0..],
        .{ .limits = .testing },
    );
}

fn matrixProductScheduleRecipe(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    artifact: []const u8,
    root: *ir.Operation,
) ![]u8 {
    var plan: FragmentPreparationPlan = undefined;
    try plan.init(allocator, handle, .{ .matrix_product_schedule_tuning_artifact = artifact });
    defer plan.deinit();
    return preparation.recipe.encode(allocator, .tensor, root, plan.run_options);
}

fn matrixProductSchedulePlanFailure(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    artifact: []const u8,
) !void {
    var plan: FragmentPreparationPlan = undefined;
    try plan.init(allocator, handle, .{ .matrix_product_schedule_tuning_artifact = artifact });
    defer plan.deinit();
    const reader = plan.run_options.tensor.einsum.matrix_product_tuning.?;
    try std.testing.expectEqual(@as(usize, 1), reader.records.len);
}
