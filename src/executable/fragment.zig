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
            if (kernel.work_item_id == work_item_id) return try artifact_product.summarizePlannedKernel(kernel);
        }
        return error.InvalidArtifact;
    }

    pub fn copyKernelSummaries(
        self: *const LoadedFragment,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError!artifact_product.KernelSummaries {
        const kernels = self.artifactPlan().kernels.items;
        const items = result_allocator.alloc(artifact_product.KernelSummary, kernels.len) catch return error.OutOfMemory;
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |summary| {
                result_allocator.free(summary.entry_name);
            }
            result_allocator.free(items);
        }

        for (items, kernels) |*item, kernel| {
            item.* = try artifact_product.copyKernelSummary(result_allocator, try artifact_product.summarizePlannedKernel(kernel));
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
        if (candidate_index >= kernel.launch_resources.candidate_count) return error.LaunchArgumentMismatch;
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
        if (state.tuning_cache.count() != 0 and tuning_mod.launchTuningIsEmpty(launch_options.tuning)) {
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
            const prepared = if (state.prepared_plan) |*plan| plan else return error.InvalidArtifact;
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
                try state.loaded_kernels.handle.synchronize(.{ .scope = .stream, .stream = stream });
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
        const binding = try binding_mod.bindingForSlot(binding_mod.slotBindings(bindings), slot_id, .read_only);
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

        const records = result_allocator.alloc(LaunchCandidateRecord, measurements.len) catch return error.OutOfMemory;
        errdefer result_allocator.free(records);
        for (measurements, 0..) |measurement, index| {
            const candidate = try self.launchResourceCandidate(kernel_index, measurement.candidate_index);
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
    const format = requested_format orelse artifact_product.defaultArtifactFormat(kind) orelse return error.UnsupportedOperation;
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
    const artifact_module = try createArtifactJobFromPreparedJob(allocator, handle, prepared, options);
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
        const target_profile = try backendTargetProfile(handle, options.artifact_format, options.math_tier);
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
        if (options.matrix_product_schedule == null and options.matrix_product_schedule_tuning_artifact.len != 0) {
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
            const decisions = allocator.alloc(preparation.target.GeneratedScanScheduleDecision, 1) catch return error.OutOfMemory;
            decisions[0] = .{ .schedule = schedule };
            self.generated_scan_schedule_decisions = decisions;
        } else if (options.generated_scan_schedule_tuning_artifact.len != 0) {
            const records = try schedule_tuning.decodeGeneratedScanScheduleTuningArtifact(
                allocator,
                options.generated_scan_schedule_tuning_artifact,
            );
            defer allocator.free(records);
            const caps = try handle.queryCapabilities();
            var decisions = std.ArrayListUnmanaged(preparation.target.GeneratedScanScheduleDecision).empty;
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
            self.generated_scan_schedule_decisions = decisions.toOwnedSlice(allocator) catch return error.OutOfMemory;
        }

        if (options.generated_row_pipeline_schedule) |schedule| {
            const decisions = allocator.alloc(preparation.target.GeneratedRowPipelineScheduleDecision, 1) catch return error.OutOfMemory;
            decisions[0] = .{ .schedule = schedule };
            self.generated_row_pipeline_schedule_decisions = decisions;
        } else if (options.generated_row_pipeline_schedule_tuning_artifact.len != 0) {
            const records = try schedule_tuning.decodeGeneratedRowPipelineScheduleTuningArtifact(
                allocator,
                options.generated_row_pipeline_schedule_tuning_artifact,
            );
            defer allocator.free(records);
            const caps = try handle.queryCapabilities();
            var decisions = std.ArrayListUnmanaged(preparation.target.GeneratedRowPipelineScheduleDecision).empty;
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
            self.generated_row_pipeline_schedule_decisions = decisions.toOwnedSlice(allocator) catch return error.OutOfMemory;
        }

        const kernel_library_lowering: preparation.KernelLibraryLowering = if (options.kernel_call_registry != null) .enabled else .disabled;
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
        if (self.generated_row_pipeline_schedule_decisions.len != 0) self.allocator.free(self.generated_row_pipeline_schedule_decisions);
        if (self.generated_scan_schedule_decisions.len != 0) self.allocator.free(self.generated_scan_schedule_decisions);
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

test "loaded fragment consumes compiled fragment and partial backend loads on failure" {
    const allocator = testing.allocator;

    var owned = try escapedTwoKernelChoirModule(allocator, "loaded_fragment_failed_load");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
        .fail_load_after_count = 1,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();
    const artifact_module = try artifact_product.ArtifactJob.init(
        allocator,
        artifact_plan,
    );
    plan_owned = false;
    defer artifact_module.deinit();

    const compiled = try exec_product.compileFragmentFromArtifactJob(allocator, artifact_module);
    try testing.expectError(
        error.RuntimeUnavailable,
        loadFragment(allocator, handle, compiled, .{ .artifact_format = .cuda_ptx }),
    );
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.destroy_count);
}

test "Choir executable plan loads artifacts and launches CUDA device-count kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_add");
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

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    try executable.launchAll(allocator, &artifact_plan, slot_bindings, count_bindings);

    try testing.expectEqual(@as(usize, 1), executable.kernelCount());
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(state.last_loaded_id.?, state.last_launch_loaded_id.?);
    try testing.expectEqual(@as(usize, 4), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try testing.expect(state.last_launch_scalar_u32 == null);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 32), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(gpu.BackendObjectId, 100), state.last_buffer_ids[0]);
    try testing.expectEqual(@as(gpu.BackendObjectId, 900), state.last_buffer_ids[3]);
    try testing.expectEqual(gpu.BufferAccess.write_only, state.last_buffer_access[0]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[1]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[2]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[3]);
}

test "Choir executable plan runs native CPU machine-code prepared kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cpu_executable_add");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{}) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const lhs = [_]f32{ 1.0, 2.0, 3.0, 4.0, -1.5, 8.0, 0.25, 16.0 };
    const rhs = [_]f32{ 5.0, -2.0, 0.5, 6.0, 2.5, -3.0, 0.75, 4.0 };
    var bindings = try binding_mod.prepare(allocator, handle, &artifact_plan, &.{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
    });
    defer bindings.deinit();

    try executable.launchAll(
        allocator,
        &artifact_plan,
        binding_mod.slotBindings(bindings),
        binding_mod.elementCountBindings(bindings),
    );

    const output_slot_id = artifact_plan.output_slot_ids[0];
    const output_binding = try binding_mod.bindingForSlot(binding_mod.slotBindings(bindings), output_slot_id, .read_only);
    var output = @as([8]f32, @splat(0.0));
    try handle.readBuffer(.{
        .handle = output_binding.handle,
        .bytes = std.mem.sliceAsBytes(output[0..]),
    });

    for (output, 0..) |value, index| {
        try testing.expectEqual(lhs[index] + rhs[index], value);
    }
}

test "Choir executable fragment runs native CPU object prepared kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cpu_loaded_fragment_object_add");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var fragment = createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .artifact_format = .cpu_object,
    }) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer fragment.deinit();

    const summary = try fragment.kernelSummary(0);
    try testing.expectEqual(gpu.ArtifactFormat.cpu_object, summary.artifact_format);
    try testing.expectEqual(artifact_product.KernelSource.tensor, summary.source);
    try testing.expectEqual(@as(usize, 1), fragment.outputCount());

    const lhs = [_]f32{ 1.0, 2.0, 3.0, 4.0, -1.5, 8.0, 0.25, 16.0 };
    const rhs = [_]f32{ 5.0, -2.0, 0.5, 6.0, 2.5, -3.0, 0.75, 4.0 };
    const inputs = [_][]const u8{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
    };
    const bindings = try fragment.prepareInvocationBindings(allocator, inputs[0..]);
    defer bindings.deinit();

    try fragment.submitPreparedForTest(allocator, bindings);
    try fragment.completeInvocationWithOptions(.{});

    var output = @as([8]f32, @splat(0.0));
    try fragment.readInvocationOutput(bindings, 0, std.mem.sliceAsBytes(output[0..]));

    for (output, 0..) |value, index| {
        try testing.expectEqual(lhs[index] + rhs[index], value);
    }
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
    try testing.expectEqual(artifact_product.PlannedKernelCompileLaunch.dot_general, summary.compile_launch);
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

test "Choir executable fragment runs dot_general native CPU machine-code" {
    try runDotGeneralNativeCpuFragment(.cpu_machine_code);
}

test "Choir executable fragment runs dot_general native CPU object" {
    try runDotGeneralNativeCpuFragment(.cpu_object);
}

test "Choir executable fragment materializes i1 outputs as single bytes on native CPU" {
    const allocator = testing.allocator;

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    const i1_8 = try builder.tensor(.i1, &.{8});
    var fb = try builder.beginFunction("choir_cpu_bool_byte_flags", &.{ f32_8, f32_8 }, &.{i1_8});
    const flags = try fb.compare(fb.parameter(0), fb.parameter(1), i1_8, .gt);
    try fb.return_(&.{flags});
    try fb.finish();
    const module = try builder.finish();

    var fragment = compileAndLoadTestSemanticModule(allocator, handle, module, .{
        .artifact_format = .cpu_object,
    }) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer fragment.deinit();

    const lhs = [_]f32{ 1.0, -1.0, 2.0, -2.0, 0.5, -0.5, 3.0, 0.0 };
    const rhs = [_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0 };
    var flags_out = @as([8]u8, @splat(0xaa));
    var outputs = [_][]u8{flags_out[0..]};
    try fragment.invokeAndReadForTest(
        allocator,
        allocator,
        &.{ std.mem.sliceAsBytes(lhs[0..]), std.mem.sliceAsBytes(rhs[0..]) },
        &outputs,
    );

    try testing.expectEqualSlices(u8, &.{ 1, 0, 1, 0, 1, 0, 1, 0 }, flags_out[0..]);
}

test "Choir executable fragment runs kernel library native CPU object" {
    const allocator = testing.allocator;

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    const VectorAdd8F32 = kernel_library.elementwise.VectorAdd8F32;
    const options = FragmentCompilerOptions{
        .artifact_format = .cpu_object,
        .authored_kernel_diagnostic_id = "accy/executable/kernel-library-native-cpu-object",
    };
    const compiled = VectorAdd8F32.compileFragment(
        allocator,
        VectorAdd8F32.Limits.testing,
        handle,
        options,
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    var fragment = loadFragment(allocator, handle, compiled, options) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer fragment.deinit();

    const plan = fragment.artifactPlan();
    const planned = plan.kernels.items[0];
    const summary = try fragment.kernelSummary(0);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    try testing.expectEqual(gpu.ArtifactFormat.cpu_object, summary.artifact_format);
    try testing.expectEqual(artifact_product.KernelSource.choir_kernel, summary.source);
    try testing.expectEqual(@as(u32, 11), summary.compile_argument_count);
    try testing.expectEqual(.authored, summary.compile_launch);
    try testing.expect(summary.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
    try testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[0]);
    try testing.expectEqual(@as(usize, gpu_abi.launch_shape_argument_count), planned.static_arguments.len);

    const lhs = [_]f32{ 1.0, 2.0, -3.0, 4.5, 8.0, -1.0, 0.25, 16.0 };
    const rhs = [_]f32{ 4.0, -2.0, 6.0, 0.5, -3.0, 5.0, 0.75, -8.0 };
    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = 8 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 8,
    });
    defer handle.destroyObject(dst_buffer.id);

    const lhs_buffer = try handle.allocateBuffer(.{
        .byte_size = 8 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 8,
    });
    defer handle.destroyObject(lhs_buffer.id);

    const rhs_buffer = try handle.allocateBuffer(.{
        .byte_size = 8 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 8,
    });
    defer handle.destroyObject(rhs_buffer.id);

    try handle.writeBuffer(.{
        .handle = lhs_buffer,
        .bytes = std.mem.sliceAsBytes(lhs[0..]),
    });
    try handle.writeBuffer(.{
        .handle = rhs_buffer,
        .bytes = std.mem.sliceAsBytes(rhs[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = lhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = lhs_buffer.byte_size,
        },
        .{
            .handle = rhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = rhs_buffer.byte_size,
        },
    };

    try fragment.launchKernelWithArguments(0, bindings[0..], planned.static_arguments, .{});

    var dst = @as([8]f32, @splat(0.0));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst[0..]),
    });
    try testing.expectEqualSlices(f32, &.{ 5.0, 0.0, 3.0, 5.0, 5.0, 4.0, 1.0, 8.0 }, dst[0..]);
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
    try testing.expectEqual(@as(usize, gpu_abi.launch_shape_argument_count), entry.static_arguments.len);

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
    try testing.expectEqualSlices(f32, &.{ 12.0, 0.0, -5.0, 10.0, 4.0, 3.0, 8.0, 32.0 }, output[0..]);
}

test "Choir executable fragment runs kernel_call native CPU machine-code with runtime scalar" {
    try runKernelCallNativeCpuRuntimeScalarFragment(.cpu_machine_code);
}

test "Choir executable fragment runs kernel_call native CPU object with runtime scalar" {
    try runKernelCallNativeCpuRuntimeScalarFragment(.cpu_object);
}

test "Choir executable artifact planning accepts CUDA u32 kernels" {
    const allocator = testing.allocator;

    var owned = try addU32ChoirModule(allocator, "choir_cuda_executable_add_u32");
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

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    try testing.expectEqual(@as(usize, 1), artifact_plan.kernelCount());
    const kernel = artifact_plan.kernels.items[0];
    try testing.expect(kernel.compile.required_dtypes.contains(.u32));
    try testing.expectEqual(@as(usize, 1), state.create_count);
    try testing.expectEqual(kernel.compile.required_dtypes.bits, state.last_create_required_dtype_bits);
}

test "Choir executable fragment launches registered kernel_call with full launch geometry" {
    const allocator = testing.allocator;

    var owned = try kernelCallChoirModule(allocator, "choir_cuda_executable_kernel_call_geometry");
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

    const source = ".visible .entry accy_custom_scale() { ret; }";
    const registry = artifact_product.KernelCallRegistry{ .entries = &.{.{
        .target = "accy.custom.scale",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_custom_scale",
        .argument_count = 5,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .payload = .{ .text = source },
        .launch = .{ .fixed = .{
            .grid = .{ 2, 3, 1 },
            .threadgroup = .{ 8, 2, 1 },
            .dynamic_shared_memory_bytes = 2048,
        } },
        .element_count_argument = .scalar_u32,
        .static_arguments = &.{.{ .u32 = 7 }},
    }} };

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .kernel_call_registry = &registry,
    });
    defer fragment.deinit();

    const plan = fragment.artifactPlan();
    const kernel = plan.kernels.items[0];
    const slot_bindings = try slotBindingsForPlan(allocator, plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, plan, .cuda);
    defer allocator.free(count_bindings);

    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    try testing.expectEqual(artifact_product.PlannedKernelSource.kernel_call, kernel.compile.source);
    try testing.expectEqual(@as(u32, 2048), kernel.launch_resources.geometry.dynamic_shared_memory_bytes);

    try fragment.launchAll(allocator, slot_bindings, count_bindings);

    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(u32, 2), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 3), state.last_launch_grid[1]);
    try testing.expectEqual(@as(u32, 8), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(u32, 2), state.last_launch_threadgroup[1]);
    try testing.expectEqual(@as(u32, 2048), state.last_launch_dynamic_shared_memory_bytes);
    try testing.expectEqual(@as(usize, 2), state.last_launch_scalar_count);
    try testing.expectEqual(@as(u32, 8), state.last_launch_scalar_u32_values[0]);
    try testing.expectEqual(@as(u32, 7), state.last_launch_scalar_u32_values[1]);
}

test "Choir executable fragment launches registered kernel_call with runtime derived geometry" {
    const allocator = testing.allocator;

    var owned = try kernelCallChoirModule(allocator, "choir_cuda_executable_kernel_call_derived_geometry");
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

    const source = ".visible .entry accy_custom_scale() { ret; }";
    const registry = artifact_product.KernelCallRegistry{ .entries = &.{.{
        .target = "accy.custom.scale",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_custom_scale",
        .argument_count = 6,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .payload = .{ .text = source },
        .launch = .{ .derived = .{
            .grid = .{
                .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = 8 } },
                .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = 4 } },
                .{ .fixed = 1 },
            },
            .threadgroup = .{ 8, 4, 1 },
            .dynamic_shared_memory_bytes = 1024,
        } },
        .runtime_scalar_argument_count = 2,
        .static_arguments = &.{.{ .u32 = 7 }},
    }} };

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .kernel_call_registry = &registry,
    });
    defer fragment.deinit();

    const plan = fragment.artifactPlan();
    const kernel = plan.kernels.items[0];
    const slot_bindings = try slotBindingsForPlan(allocator, plan, .cuda);
    defer allocator.free(slot_bindings);

    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    try testing.expectEqual(artifact_product.PlannedKernelSource.kernel_call, kernel.compile.source);
    try testing.expectEqual(@as(u32, 2), kernel.runtime_scalar_argument_count);

    try fragment.launchAllWithOptions(allocator, slot_bindings, &.{}, .{
        .runtime_scalar_arguments = &.{ .{ .u32 = 17 }, .{ .u32 = 9 } },
    });

    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(u32, 3), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 3), state.last_launch_grid[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[2]);
    try testing.expectEqual(@as(u32, 8), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(u32, 4), state.last_launch_threadgroup[1]);
    try testing.expectEqual(@as(u32, 1024), state.last_launch_dynamic_shared_memory_bytes);
    try testing.expectEqual(@as(usize, 3), state.last_launch_scalar_count);
    try testing.expectEqual(@as(u32, 17), state.last_launch_scalar_u32_values[0]);
    try testing.expectEqual(@as(u32, 9), state.last_launch_scalar_u32_values[1]);
    try testing.expectEqual(@as(u32, 7), state.last_launch_scalar_u32_values[2]);
}

test "Choir executable fragment lets launch scalars override the kernel_call count default" {
    const allocator = testing.allocator;

    var owned = try kernelCallChoirModule(allocator, "choir_cuda_executable_kernel_call_count_override");
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

    const source = ".visible .entry accy_custom_scale() { ret; }";
    const registry = artifact_product.KernelCallRegistry{ .entries = &.{.{
        .target = "accy.custom.scale",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_custom_scale",
        .argument_count = 4,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .payload = .{ .text = source },
        .launch = .{ .derived = .{
            .grid = .{
                .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = 4 } },
                .{ .fixed = 1 },
                .{ .fixed = 1 },
            },
            .threadgroup = .{ 4, 1, 1 },
            .dynamic_shared_memory_bytes = 0,
        } },
        .runtime_scalar_argument_count = 1,
        .shape_family_fingerprint = 0xfeed,
        .shape_profile = .{
            .name = "rows",
            .fingerprint = 0xfeed,
            .dimensions = &.{.{ .name = "n", .runtime_scalar_argument_index = 0, .bounds = .{ .max = 4096 } }},
        },
    }} };

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .kernel_call_registry = &registry,
    });
    defer fragment.deinit();

    const plan = fragment.artifactPlan();
    const kernel = plan.kernels.items[0];
    const slot_bindings = try slotBindingsForPlan(allocator, plan, .cuda);
    defer allocator.free(slot_bindings);

    try testing.expectEqual(@as(u32, 1), kernel.runtime_scalar_argument_count);
    try testing.expectEqual(@as(usize, 1), kernel.runtime_scalar_defaults.len);
    try testing.expectEqual(@as(u32, 8), kernel.runtime_scalar_defaults[0].u32);
    try testing.expectEqual(artifact_product.ElementCountArgument.none, kernel.element_count_argument);

    try fragment.launchAllWithOptions(allocator, slot_bindings, &.{}, .{
        .runtime_scalar_arguments = &.{.{ .u32 = 13 }},
    });
    try testing.expectEqual(@as(usize, 1), state.last_launch_scalar_count);
    try testing.expectEqual(@as(u32, 13), state.last_launch_scalar_u32_values[0]);
    try testing.expectEqual(@as(u32, 4), state.last_launch_grid[0]);

    try fragment.launchAllWithOptions(allocator, slot_bindings, &.{}, .{});
    try testing.expectEqual(@as(u32, 8), state.last_launch_scalar_u32_values[0]);
    try testing.expectEqual(@as(u32, 2), state.last_launch_grid[0]);
}

test "Choir executable fragment launches aliased kernel_call outputs read-write" {
    const allocator = testing.allocator;

    var owned = try aliasedKernelCallChoirModule(allocator, "choir_cuda_executable_kernel_call_alias_access");
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

    const source = ".visible .entry accy_custom_update() { ret; }";
    const registry = artifact_product.KernelCallRegistry{ .entries = &.{.{
        .target = "accy.custom.update",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_custom_update",
        .argument_count = 2,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .payload = .{ .text = source },
        .launch = .{ .fixed = .{
            .grid = .{ 1, 1, 1 },
            .threadgroup = .{ 8, 1, 1 },
        } },
    }} };

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .kernel_call_registry = &registry,
    });
    defer fragment.deinit();

    const plan = fragment.artifactPlan();
    const kernel = plan.kernels.items[0];
    const slot_bindings = try slotBindingsForPlan(allocator, plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, plan, .cuda);
    defer allocator.free(count_bindings);

    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    try testing.expectEqual(artifact_product.PlannedKernelSource.kernel_call, kernel.compile.source);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(kernel.output_slot_id, kernel.input_slot_ids[0]);

    try fragment.launchAll(allocator, slot_bindings, count_bindings);

    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 2), state.last_launch_buffer_count);
    try testing.expectEqual(state.last_buffer_ids[0], state.last_buffer_ids[1]);
    try testing.expectEqual(gpu.BufferAccess.read_write, state.last_buffer_access[0]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[1]);
}

test "Choir executable fragment launches prepared graph with runtime scalars" {
    const allocator = testing.allocator;

    var owned = try kernelCallChoirModule(allocator, "choir_cuda_executable_kernel_call_prepared_graph_runtime");
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

    const source = ".visible .entry accy_custom_scale() { ret; }";
    const registry = artifact_product.KernelCallRegistry{ .entries = &.{.{
        .target = "accy.custom.scale",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_custom_scale",
        .argument_count = 6,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .payload = .{ .text = source },
        .launch = .{ .derived = .{
            .grid = .{
                .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = 8 } },
                .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = 4 } },
                .{ .fixed = 1 },
            },
            .threadgroup = .{ 8, 4, 1 },
            .dynamic_shared_memory_bytes = 1024,
        } },
        .runtime_scalar_argument_count = 2,
        .static_arguments = &.{.{ .u32 = 7 }},
    }} };

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .kernel_call_registry = &registry,
    });
    defer fragment.deinit();

    var lhs = @as([8]f32, @splat(1.0));
    var rhs = @as([8]f32, @splat(2.0));
    const input_bytes = [_][]const u8{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
    };
    const bindings = try fragment.prepareInvocationBindings(allocator, input_bytes[0..]);
    defer bindings.deinit();

    var graph = try fragment.createLaunchGraphPlan(allocator, .{});
    defer graph.deinit();
    const runtime_args = [_]gpu_abi.ScalarArgument{ .{ .u32 = 17 }, .{ .u32 = 9 } };
    graph.nodes[0].runtime_scalar_arguments = runtime_args[0..];

    try fragment.submitInvocationWithGraph(allocator, bindings, graph.plan());

    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(u32, 3), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 3), state.last_launch_grid[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[2]);
    try testing.expectEqual(@as(u32, 8), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(u32, 4), state.last_launch_threadgroup[1]);
    try testing.expectEqual(@as(u32, 1024), state.last_launch_dynamic_shared_memory_bytes);
    try testing.expectEqual(@as(usize, 3), state.last_launch_scalar_count);
    try testing.expectEqual(@as(u32, 17), state.last_launch_scalar_u32_values[0]);
    try testing.expectEqual(@as(u32, 9), state.last_launch_scalar_u32_values[1]);
    try testing.expectEqual(@as(u32, 7), state.last_launch_scalar_u32_values[2]);
}

test "Choir executable plan launches CUDA choir dot_general without static shape scalars" {
    const allocator = testing.allocator;

    var owned = try dotGeneralChoirModule(allocator, "choir_cuda_executable_dot_general");
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

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const caps = try handle.queryCapabilities();
    const key = LaunchTuningCacheKey.init(caps, kernel);
    try testing.expectEqual(kernel.output_layout_fingerprint, key.output_layout_fingerprint);
    try testing.expectEqual(kernel.input_layout_fingerprint, key.input_layout_fingerprint);
    try testing.expect(key.output_layout_fingerprint != 0);
    try testing.expect(key.input_layout_fingerprint != 0);
    try testing.expectEqual(artifact_product.LaunchTileKind.dot_general, key.tile_kind);
    try testing.expectEqual(@as(u32, 16), key.tile_m);
    try testing.expectEqual(@as(u32, 16), key.tile_n);
    try testing.expectEqual(@as(u32, 16), key.tile_k);
    try testing.expectEqual(@as(u32, 1), key.tile_batch);
    try testing.expect(key.tile_has_input_dtype);
    try testing.expectEqual(gpu_abi.DType.f32, key.tile_input_dtype);
    try testing.expect(key.tile_has_output_dtype);
    try testing.expectEqual(gpu_abi.DType.f32, key.tile_output_dtype);
    try testing.expectEqual(@as(u32, 2048), key.tile_input_tile_bytes);
    try testing.expectEqual(@as(u32, 1024), key.tile_output_tile_bytes);
    try testing.expectEqual(@as(u32, 0), key.tile_scratch_memory_bytes);
    try testing.expectEqual(@as(u32, 4), key.candidate_count);
    try testing.expectEqual(artifact_product.launchResourcePlanFingerprint(kernel.launch_resources), key.launch_resource_fingerprint);
    try testing.expect(key.launch_resource_fingerprint != 0);
    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    try executable.launchAll(allocator, &artifact_plan, slot_bindings, count_bindings);

    try testing.expectEqual(@as(usize, 1), executable.kernelCount());
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 3), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try testing.expect(state.last_launch_scalar_u32 == null);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[2]);
    try testing.expectEqual(@as(u32, 16), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(u32, 16), state.last_launch_threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_threadgroup[2]);
    try testing.expectEqual(@as(usize, 2), kernel.input_slot_ids.len);
}

test "Choir executable plan rejects CUDA f16 dot_general until choir lowering supports it" {
    const allocator = testing.allocator;

    var owned = try dotGeneralF16ChoirModule(allocator, "choir_cuda_executable_dot_general_f16");
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

    try testing.expectError(
        error.CapabilityMismatch,
        createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{}),
    );
}

test "Choir executable plan launches Vulkan dot_general without element-count bindings" {
    const allocator = testing.allocator;

    var owned = try dotGeneralChoirModule(allocator, "choir_vulkan_executable_dot_general");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    try testing.expect(state.last_create_had_payload);
    try testing.expectEqual(@as(u32, 3), state.last_create_argument_count);

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .vulkan);
    defer allocator.free(slot_bindings);

    try executable.launchAll(allocator, &artifact_plan, slot_bindings, &.{});

    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 3), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try testing.expectEqual(@as(u32, 2), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 2), state.last_launch_grid[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[2]);
    try testing.expectEqual(@as(u32, 8), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(u32, 8), state.last_launch_threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_threadgroup[2]);
}

test "Choir executable plan launches CUDA reduction with static input count" {
    const allocator = testing.allocator;

    var owned = try reduceChoirModule(allocator, "choir_cuda_executable_reduce");
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

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const caps = try handle.queryCapabilities();
    const key = LaunchTuningCacheKey.init(caps, kernel);
    try testing.expectEqual(artifact_product.LaunchTileKind.reduction, key.tile_kind);
    try testing.expectEqual(@as(u32, 32), key.tile_m);
    try testing.expectEqual(@as(u32, 256), key.tile_n);
    try testing.expectEqual(@as(u32, 0), key.tile_k);
    try testing.expectEqual(@as(u32, 1), key.tile_batch);
    try testing.expect(key.tile_has_input_dtype);
    try testing.expectEqual(gpu_abi.DType.f32, key.tile_input_dtype);
    try testing.expect(key.tile_has_output_dtype);
    try testing.expectEqual(gpu_abi.DType.f32, key.tile_output_dtype);
    try testing.expectEqual(@as(u32, 32768), key.tile_input_tile_bytes);
    try testing.expectEqual(@as(u32, 128), key.tile_output_tile_bytes);
    try testing.expectEqual(@as(u32, 0), key.tile_scratch_memory_bytes);
    try testing.expectEqual(artifact_product.LaunchReductionKind.sum, key.tile_reduction_kind);
    try testing.expectEqual(@as(u32, 1), key.tile_reduction_rank);
    try testing.expectEqual(@as(u32, 0), key.tile_reduction_axis);
    try testing.expectEqual(@as(u32, 256), key.tile_reduction_extent);
    try testing.expect(key.launch_resource_fingerprint != 0);
    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, &artifact_plan, .cuda);
    defer allocator.free(count_bindings);

    try executable.launchAll(allocator, &artifact_plan, slot_bindings, count_bindings);

    try testing.expectEqual(@as(usize, 1), executable.kernelCount());
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 3), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try testing.expect(state.last_launch_scalar_u32 == null);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[2]);
    try testing.expectEqual(@as(u32, 32), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_threadgroup[2]);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(gpu.BackendObjectId, 900), state.last_buffer_ids[2]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[2]);
}

test "Choir executable plan creates CUDA plans from i32 reductions" {
    const allocator = testing.allocator;

    var owned = try reduceI32ChoirModule(allocator, "choir_cuda_executable_reduce_i32");
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

    var plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    try testing.expect(plan.kernels.items[0].compile.required_dtypes.contains(.i32));
}

test "Choir executable plan launches Vulkan reduction with device count binding" {
    const allocator = testing.allocator;

    var owned = try reduceChoirModule(allocator, "choir_vulkan_executable_reduce");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const caps = try handle.queryCapabilities();
    const key = LaunchTuningCacheKey.init(caps, kernel);
    try testing.expectEqual(artifact_product.LaunchTileKind.reduction, key.tile_kind);
    try testing.expectEqual(@as(u32, 64), key.tile_m);
    try testing.expectEqual(@as(u32, 256), key.tile_n);
    try testing.expectEqual(@as(u32, 0), key.tile_k);
    try testing.expectEqual(@as(u32, 1), key.tile_batch);
    try testing.expect(key.tile_has_input_dtype);
    try testing.expectEqual(gpu_abi.DType.f32, key.tile_input_dtype);
    try testing.expect(key.tile_has_output_dtype);
    try testing.expectEqual(gpu_abi.DType.f32, key.tile_output_dtype);
    try testing.expectEqual(@as(u32, 65536), key.tile_input_tile_bytes);
    try testing.expectEqual(@as(u32, 256), key.tile_output_tile_bytes);
    try testing.expectEqual(@as(u32, 0), key.tile_scratch_memory_bytes);
    try testing.expectEqual(artifact_product.LaunchReductionKind.sum, key.tile_reduction_kind);
    try testing.expectEqual(@as(u32, 1), key.tile_reduction_rank);
    try testing.expectEqual(@as(u32, 0), key.tile_reduction_axis);
    try testing.expectEqual(@as(u32, 256), key.tile_reduction_extent);
    try testing.expect(key.launch_resource_fingerprint != 0);
    try testing.expect(state.last_create_had_payload);
    try testing.expectEqual(@as(u32, 3), state.last_create_argument_count);

    const slot_bindings = try slotBindingsForPlan(allocator, &artifact_plan, .vulkan);
    defer allocator.free(slot_bindings);
    const count_binding = ElementCountBufferBinding{
        .kernel_id = kernel.kernel_id,
        .binding = bufferBinding(200, .vulkan, 4),
    };

    try executable.launchAll(allocator, &artifact_plan, slot_bindings, &.{count_binding});

    try testing.expectEqual(@as(usize, 1), executable.kernelCount());
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 3), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try testing.expect(state.last_launch_scalar_u32 == null);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[0]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_grid[2]);
    try testing.expectEqual(@as(u32, 64), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), state.last_launch_threadgroup[2]);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(gpu.BackendObjectId, 200), state.last_buffer_ids[2]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[2]);
}

test "Choir executable launch candidate measurement synchronizes stream" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_executable_measure_stream_sync");
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

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
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
        .{
            .warmup = 1,
            .samples = 2,
            .base_options = .{ .stream = .{ .id = 77, .backend = .cuda } },
            .synchronize = .stream,
        },
    );
    defer allocator.free(measurements);

    try testing.expectEqual(kernel.launch_resources.candidate_count * 3, state.launch_count);
    try testing.expectEqual(kernel.launch_resources.candidate_count * 3, state.sync_count);
    try testing.expectEqual(gpu.SyncScope.stream, state.last_sync_scope.?);
    try testing.expectEqual(@as(gpu.BackendObjectId, 77), state.last_sync_stream.?);
}

test "Choir executable fragment creates artifacts loads handles and launches" {
    const allocator = testing.allocator;
    const PhaseRecorder = struct {
        phases: [3]FragmentPhase = undefined,
        count: usize = 0,

        fn observe(context: ?*anyopaque, phase_name: []const u8, _: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.count >= self.phases.len) return error.TooManyPhases;
            self.phases[self.count] = if (std.mem.eql(u8, phase_name, FragmentPhase.run_contract_pipeline.name()))
                .run_contract_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.run_target_pipeline.name()))
                .run_target_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.plan_create_backend_artifacts.name()))
                .plan_create_backend_artifacts
            else if (std.mem.eql(u8, phase_name, FragmentPhase.compile_fragment.name()))
                .compile_fragment
            else if (std.mem.eql(u8, phase_name, FragmentPhase.load_backend_artifacts.name()))
                .load_backend_artifacts
            else if (std.mem.eql(u8, phase_name, FragmentPhase.import_launch_tuning.name()))
                .import_launch_tuning
            else
                return error.InvalidPhase;
            self.count += 1;
        }

        fn has(self: *const @This(), phase: FragmentPhase) bool {
            for (self.phases[0..self.count]) |recorded| {
                if (recorded == phase) return true;
            }
            return false;
        }
    };

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_add");
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

    var phase_recorder = PhaseRecorder{};
    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .instrumentation = .{
            .context = &phase_recorder,
            .observe = PhaseRecorder.observe,
        },
    });
    defer fragment.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, fragment.artifactPlan(), .cuda);
    defer allocator.free(count_bindings);

    try fragment.launchAll(allocator, slot_bindings, count_bindings);

    try testing.expectEqual(@as(usize, 1), fragment.artifactPlan().kernelCount());
    try testing.expectEqual(@as(usize, 1), fragment.loadedKernelCount());
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expect(state.last_launch_scalar_u32 == null);
    try testing.expectEqual(@as(usize, 3), phase_recorder.count);
    try testing.expectEqual(FragmentPhase.plan_create_backend_artifacts, phase_recorder.phases[0]);
    try testing.expectEqual(FragmentPhase.compile_fragment, phase_recorder.phases[1]);
    try testing.expectEqual(FragmentPhase.load_backend_artifacts, phase_recorder.phases[2]);
    try testing.expect(phase_recorder.has(.plan_create_backend_artifacts));
    try testing.expect(phase_recorder.has(.compile_fragment));
    try testing.expect(phase_recorder.has(.load_backend_artifacts));
}

test "Choir executable fragment from semantic module uses target product" {
    const allocator = testing.allocator;
    const PhaseRecorder = struct {
        phases: [9]FragmentPhase = undefined,
        count: usize = 0,

        fn observe(context: ?*anyopaque, phase_name: []const u8, _: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.count >= self.phases.len) return error.TooManyPhases;
            self.phases[self.count] = if (std.mem.eql(u8, phase_name, FragmentPhase.run_contract_pipeline.name()))
                .run_contract_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.run_tensor_pipeline.name()))
                .run_tensor_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.run_dispatch_pipeline.name()))
                .run_dispatch_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.run_memory_pipeline.name()))
                .run_memory_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.run_kernel_pipeline.name()))
                .run_kernel_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.run_target_pipeline.name()))
                .run_target_pipeline
            else if (std.mem.eql(u8, phase_name, FragmentPhase.plan_create_backend_artifacts.name()))
                .plan_create_backend_artifacts
            else if (std.mem.eql(u8, phase_name, FragmentPhase.compile_fragment.name()))
                .compile_fragment
            else if (std.mem.eql(u8, phase_name, FragmentPhase.load_backend_artifacts.name()))
                .load_backend_artifacts
            else if (std.mem.eql(u8, phase_name, FragmentPhase.import_launch_tuning.name()))
                .import_launch_tuning
            else
                return error.InvalidPhase;
            self.count += 1;
        }

        fn has(self: *const @This(), phase: FragmentPhase) bool {
            for (self.phases[0..self.count]) |recorded| {
                if (recorded == phase) return true;
            }
            return false;
        }
    };

    const module = try addSemanticModule(allocator, "choir_executable_from_semantic_add");

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    var phase_recorder = PhaseRecorder{};
    var fragment = try compileAndLoadTestSemanticModule(allocator, handle, module, .{
        .instrumentation = .{
            .context = &phase_recorder,
            .observe = PhaseRecorder.observe,
        },
    });
    defer fragment.deinit();

    try testing.expectEqual(@as(usize, 1), fragment.artifactPlan().kernelCount());
    try testing.expectEqual(@as(usize, 1), fragment.loadedKernelCount());
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 9), phase_recorder.count);
    try testing.expectEqual(FragmentPhase.run_contract_pipeline, phase_recorder.phases[0]);
    try testing.expectEqual(FragmentPhase.run_tensor_pipeline, phase_recorder.phases[1]);
    try testing.expectEqual(FragmentPhase.run_dispatch_pipeline, phase_recorder.phases[2]);
    try testing.expectEqual(FragmentPhase.run_memory_pipeline, phase_recorder.phases[3]);
    try testing.expectEqual(FragmentPhase.run_kernel_pipeline, phase_recorder.phases[4]);
    try testing.expectEqual(FragmentPhase.run_target_pipeline, phase_recorder.phases[5]);
    try testing.expectEqual(FragmentPhase.plan_create_backend_artifacts, phase_recorder.phases[6]);
    try testing.expectEqual(FragmentPhase.compile_fragment, phase_recorder.phases[7]);
    try testing.expectEqual(FragmentPhase.load_backend_artifacts, phase_recorder.phases[8]);
    try testing.expect(phase_recorder.has(.run_contract_pipeline));
    try testing.expect(phase_recorder.has(.run_tensor_pipeline));
    try testing.expect(phase_recorder.has(.run_dispatch_pipeline));
    try testing.expect(phase_recorder.has(.run_memory_pipeline));
    try testing.expect(phase_recorder.has(.run_kernel_pipeline));
    try testing.expect(phase_recorder.has(.run_target_pipeline));
    try testing.expect(phase_recorder.has(.plan_create_backend_artifacts));
    try testing.expect(phase_recorder.has(.compile_fragment));
    try testing.expect(phase_recorder.has(.load_backend_artifacts));
}

test "Choir executable fragment compiles a prepared job without rerunning preparation" {
    const allocator = testing.allocator;
    const PhaseRecorder = struct {
        phases: [3]FragmentPhase = undefined,
        count: usize = 0,

        fn observe(context: ?*anyopaque, phase_name: []const u8, _: u64) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.count >= self.phases.len) return error.TooManyPhases;
            self.phases[self.count] = if (std.mem.eql(u8, phase_name, FragmentPhase.plan_create_backend_artifacts.name()))
                .plan_create_backend_artifacts
            else if (std.mem.eql(u8, phase_name, FragmentPhase.compile_fragment.name()))
                .compile_fragment
            else if (std.mem.eql(u8, phase_name, FragmentPhase.load_backend_artifacts.name()))
                .load_backend_artifacts
            else if (std.mem.eql(u8, phase_name, FragmentPhase.import_launch_tuning.name()))
                .import_launch_tuning
            else
                return error.InvalidPhase;
            self.count += 1;
        }

        fn has(self: *const @This(), phase: FragmentPhase) bool {
            for (self.phases[0..self.count]) |recorded| {
                if (recorded == phase) return true;
            }
            return false;
        }
    };

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();

    const target_profile = try backendTargetProfile(handle, .cuda_ptx, .exact);
    const module = try addSemanticModule(allocator, "choir_executable_from_prepared_add");
    var prepared = try preparation.prepareBackendJobFromSemanticModule(allocator, module, .{
        .target_profile = target_profile,
    });
    defer prepared.deinit();

    var phase_recorder = PhaseRecorder{};
    var fragment = try compileAndLoadTestPreparedJob(allocator, handle, &prepared, .{
        .artifact_format = .cuda_ptx,
        .instrumentation = .{
            .context = &phase_recorder,
            .observe = PhaseRecorder.observe,
        },
    });
    defer fragment.deinit();

    try testing.expectEqual(@as(usize, 1), fragment.artifactPlan().kernelCount());
    try testing.expectEqual(@as(usize, 1), fragment.loadedKernelCount());
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(u64, preparation.target_pass_count), prepared.run.target_stats.pass_runs);
    try testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const generated_summary = try prepared.generatedKernelSummary(0);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0_v4", generated_summary.entry_name);
    try testing.expectEqualStrings("accy.artifact", artifact_product.product_name);
    try testing.expectEqual(@as(usize, 3), phase_recorder.count);
    try testing.expectEqual(FragmentPhase.plan_create_backend_artifacts, phase_recorder.phases[0]);
    try testing.expectEqual(FragmentPhase.compile_fragment, phase_recorder.phases[1]);
    try testing.expectEqual(FragmentPhase.load_backend_artifacts, phase_recorder.phases[2]);
    try testing.expect(phase_recorder.has(.plan_create_backend_artifacts));
    try testing.expect(phase_recorder.has(.compile_fragment));
    try testing.expect(phase_recorder.has(.load_backend_artifacts));
}

test "Choir executable fragment prepareInvocationBindings allocates buffers and count bindings" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_prepared_bindings");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const lhs = @as([8]f32, @splat(1.0));
    const rhs = @as([8]f32, @splat(2.0));
    const bindings = try fragment.prepareInvocationBindings(allocator, &.{
        std.mem.asBytes(&lhs),
        std.mem.asBytes(&rhs),
    });
    var bindings_live = true;
    defer if (bindings_live) bindings.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    const live_buffer_count = binding_mod.liveBufferCount(bindings);
    try testing.expectEqual(@as(usize, 4), live_buffer_count);
    try testing.expectEqual(@as(usize, 3), binding_mod.slotBindings(bindings).len);
    try testing.expectEqual(@as(usize, 1), binding_mod.elementCountBindings(bindings).len);
    try testing.expect(binding_mod.elementCountBindingForKernel(bindings, kernel.kernel_id) != null);
    const count_binding = binding_mod.elementCountBindingForKernel(bindings, kernel.kernel_id).?;
    try testing.expectEqual(@as(usize, @sizeOf(u32)), count_binding.byte_size);
    try testing.expectEqual(@as(usize, 4), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 3), state.write_count);
    try testing.expectEqual(@as(usize, @sizeOf(u32)), state.last_write_byte_count);
    try testing.expectEqual(@as(u32, 8), state.last_write_u32.?);

    try fragment.submitPreparedForTest(allocator, bindings);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 4), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.destroy_count);

    bindings.deinit();
    bindings_live = false;
    try testing.expectEqual(live_buffer_count, state.destroy_count);
}

test "Choir executable fragment prepareInvocationBindings skips reduction init constants" {
    const allocator = testing.allocator;

    var owned = try reduceChoirModule(allocator, "choir_loaded_fragment_prepared_reduction_bindings");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const input = @as([256]f32, @splat(1.0));
    const bindings = try fragment.prepareInvocationBindings(allocator, &.{std.mem.asBytes(&input)});
    defer bindings.deinit();

    const plan = fragment.artifactPlan();
    var constant_slot_count: usize = 0;
    for (plan.slots) |slot| {
        if (slot.role.constant) constant_slot_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), constant_slot_count);
    try testing.expectEqual(@as(usize, 3), binding_mod.liveBufferCount(bindings));
    try testing.expectEqual(@as(usize, 2), binding_mod.slotBindings(bindings).len);
    try testing.expectEqual(@as(usize, 1), binding_mod.elementCountBindings(bindings).len);
    for (binding_mod.slotBindings(bindings)) |slot_binding| {
        const slot = plan.slotById(slot_binding.slot_id) orelse return error.InvalidArtifact;
        try testing.expect(!slot.role.constant);
    }

    const kernel = plan.kernels.items[0];
    try testing.expect(binding_mod.elementCountBindingForKernel(bindings, kernel.kernel_id) != null);
    try testing.expectEqual(@as(usize, 3), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 2), state.write_count);
    try testing.expectEqual(@as(usize, @sizeOf(u32)), state.last_write_byte_count);
    try testing.expectEqual(@as(u32, 1), state.last_write_u32.?);

    try fragment.submitPreparedForTest(allocator, bindings);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 3), state.last_launch_buffer_count);
}

test "Choir executable fragment prepareInvocationBindings writes kernel constant buffers" {
    const allocator = testing.allocator;

    var owned = try constantAddChoirModule(allocator, "choir_loaded_fragment_constant_bindings");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const input = @as([8]f32, @splat(1.0));
    const bindings = try fragment.prepareInvocationBindings(allocator, &.{std.mem.asBytes(&input)});
    defer bindings.deinit();

    const plan = fragment.artifactPlan();
    var constant_slot: ?artifact_product.PlannedSlot = null;
    for (plan.slots) |slot| {
        if (slot.role.constant) constant_slot = slot;
    }
    const constant = constant_slot orelse return error.TestExpectedConstant;

    try testing.expectEqual(@as(usize, 4), binding_mod.liveBufferCount(bindings));
    try testing.expectEqual(@as(usize, 3), binding_mod.slotBindings(bindings).len);
    try testing.expectEqual(@as(usize, 1), binding_mod.elementCountBindings(bindings).len);
    try testing.expectEqual(@as(usize, 3), state.write_count);

    var found_constant_binding = false;
    for (binding_mod.slotBindings(bindings)) |slot_binding| {
        if (slot_binding.slot_id != constant.slot_id) continue;
        found_constant_binding = true;
        try testing.expectEqual(gpu.BufferAccess.read_only, slot_binding.binding.access);
        try testing.expectEqual(@as(usize, 8 * @sizeOf(f32)), slot_binding.binding.byte_size);
    }
    try testing.expect(found_constant_binding);

    try fragment.submitPreparedForTest(allocator, bindings);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 4), state.last_launch_buffer_count);
}

test "Choir executable fragment reads program outputs back to host" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_read_outputs");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    try testing.expectEqual(@as(usize, 1), fragment.outputCount());
    const slot = fragment.outputSlot(0).?;
    try testing.expectEqual(@as(?u64, 8 * @sizeOf(f32)), slot.byte_size);
    try testing.expect(fragment.outputSlot(1) == null);

    const lhs = @as([8]f32, @splat(1.0));
    const rhs = @as([8]f32, @splat(2.0));
    const bindings = try fragment.prepareInvocationBindings(allocator, &.{
        std.mem.asBytes(&lhs),
        std.mem.asBytes(&rhs),
    });
    defer bindings.deinit();

    try fragment.submitPreparedForTest(allocator, bindings);
    try fragment.completeInvocationWithOptions(.{});

    const output_slot_id = fragment.artifactPlan().output_slot_ids[0];
    const expected = try binding_mod.bindingForSlot(binding_mod.slotBindings(bindings), output_slot_id, .read_only);

    var host_out = @as([8]f32, @splat(7.0));
    try fragment.readInvocationOutput(bindings, 0, std.mem.sliceAsBytes(host_out[0..]));

    try testing.expectEqual(@as(usize, 1), state.read_count);
    try testing.expectEqual(@as(usize, 8 * @sizeOf(f32)), state.last_read_byte_count);
    try testing.expectEqual(expected.handle.id, state.last_read_buffer_id.?);
    try testing.expect(state.sync_count >= 1);
    try testing.expectEqual(gpu.SyncScope.default_stream, state.last_sync_scope.?);
    for (host_out) |value| try testing.expectEqual(@as(f32, 0.0), value);

    try testing.expectError(
        error.InvalidArtifact,
        fragment.readInvocationOutput(bindings, 1, std.mem.sliceAsBytes(host_out[0..])),
    );
    var small: [4]u8 = undefined;
    try testing.expectError(error.ReadBufferDestinationTooSmall, fragment.readInvocationOutput(bindings, 0, small[0..]));
}

test "Choir executable fragment launches inputs and reads outputs" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_launch_read");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const lhs = @as([8]f32, @splat(1.0));
    const rhs = @as([8]f32, @splat(2.0));
    var host_out = @as([8]f32, @splat(9.0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(host_out[0..])};

    try fragment.invokeAndReadForTest(allocator, allocator, &.{
        std.mem.asBytes(&lhs),
        std.mem.asBytes(&rhs),
    }, &outputs);

    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 1), state.read_count);
    try testing.expectEqual(@as(usize, 8 * @sizeOf(f32)), state.last_read_byte_count);
    try testing.expect(state.sync_count >= 1);
    for (host_out) |value| try testing.expectEqual(@as(f32, 0.0), value);

    try testing.expectError(error.InvalidArtifact, fragment.invokeAndReadForTest(allocator, allocator, &.{
        std.mem.asBytes(&lhs),
        std.mem.asBytes(&rhs),
    }, &.{}));
}

test "Choir executable fragment exposes kernel summaries by index and work item" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_kernel_summary_lookup");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    try testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const indexed = try fragment.kernelSummary(0);
    const by_work = try fragment.kernelSummaryForWork(indexed.work_item_id);
    try testing.expect(artifact_product.kernelSummariesEqual(indexed, by_work));
    try testing.expectError(error.InvalidArtifact, fragment.kernelSummary(1));
    try testing.expectError(error.InvalidArtifact, fragment.kernelSummaryForWork(std.math.maxInt(usize)));

    var summaries = try fragment.copyKernelSummaries(allocator);
    defer summaries.deinit();
    try testing.expectEqual(fragment.kernelCount(), summaries.len());
    const copied_indexed = try summaries.summary(0);
    const copied_by_work = try summaries.summaryForWork(indexed.work_item_id);
    try testing.expect(artifact_product.kernelSummariesEqual(indexed, copied_indexed));
    try testing.expect(artifact_product.kernelSummariesEqual(indexed, copied_by_work));
    try testing.expectEqualStrings(indexed.entry_name, copied_indexed.entry_name);
    try testing.expectError(error.InvalidArtifact, summaries.summary(fragment.kernelCount()));
    try testing.expectError(error.InvalidArtifact, summaries.summaryForWork(std.math.maxInt(usize)));
}

test "Choir executable fragment measures launch candidates through prepared bindings" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_measure_candidates");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const lhs = @as([8]f32, @splat(1.0));
    const rhs = @as([8]f32, @splat(2.0));
    const bindings = try fragment.prepareInvocationBindings(allocator, &.{
        std.mem.asBytes(&lhs),
        std.mem.asBytes(&rhs),
    });
    defer bindings.deinit();

    try testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const kernel = try fragment.plannedKernel(0);
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const summary = try fragment.kernelSummary(0);
    try testing.expectEqual(artifact_product.KernelSource.tensor, summary.source);
    try testing.expectEqual(kernel.kernel_id, summary.kernel_id);
    try testing.expectEqual(kernel.work_item_id, summary.work_item_id);
    try testing.expectEqual(kernel.element_count, summary.element_count);
    try testing.expectEqual(kernel.op_count, summary.op_count);
    try testing.expectEqual(kernel.output_layout_fingerprint, summary.output_layout_fingerprint);
    try testing.expectEqual(kernel.input_layout_fingerprint, summary.input_layout_fingerprint);
    try testing.expectEqual(kernel.launch_resources.candidate_count, summary.launch_candidate_count);
    try testing.expectEqualStrings(launchResourceClassName(kernel.launch_resources.resource_class), summary.launch_resource_class);
    var copied_artifact = try fragment.copyKernelArtifact(allocator, 0);
    defer copied_artifact.deinit();
    try testing.expectEqual(kernel.artifact.format, copied_artifact.format);
    try testing.expectEqualStrings(kernel.artifact.entry_name, copied_artifact.entry_name);

    const records = try fragment.measureInvocationLaunchCandidates(
        allocator,
        allocator,
        0,
        bindings,
        .{ .warmup = 1, .samples = 2 },
    );
    defer allocator.free(records);
    try testing.expectEqual(kernel.launch_resources.candidate_count, records.len);
    try testing.expectEqual(kernel.launch_resources.candidate_count * 3, state.launch_count);
    try testing.expectEqual(kernel.kernel_id, records[0].kernel.kernel_id);
    try testing.expectEqual(kernel.output_layout_fingerprint, records[0].kernel.output_layout_fingerprint);
    try testing.expectEqual(kernel.input_layout_fingerprint, records[0].kernel.input_layout_fingerprint);
    try testing.expectEqual(@as(usize, 0), records[0].candidate_index);
    try testing.expectEqual(kernel.launch_resources.candidates[0].geometry.threadgroup[0], records[0].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 2), records[0].sample_count);

    const candidate = try fragment.launchResourceCandidate(0, records[0].candidate_index);
    try testing.expectEqual(kernel.launch_resources.candidates[0].geometry.threadgroup[0], candidate.geometry.threadgroup[0]);
    try testing.expectError(error.InvalidArtifact, fragment.plannedKernel(fragment.kernelCount()));
    try testing.expectError(
        error.LaunchArgumentMismatch,
        fragment.launchResourceCandidate(0, kernel.launch_resources.candidate_count),
    );
}

test "Choir executable fragment measures and records launch candidates" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_measure_record_candidates");
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

    var measured = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer measured.deinit();

    const lhs = @as([8]f32, @splat(1.0));
    const rhs = @as([8]f32, @splat(2.0));
    const bindings = try measured.prepareInvocationBindings(allocator, &.{
        std.mem.asBytes(&lhs),
        std.mem.asBytes(&rhs),
    });
    defer bindings.deinit();

    const measured_kernel = measured.artifactPlan().kernels.items[0];
    try testing.expect(measured_kernel.launch_resources.candidate_count > 1);

    const records = try measured.measureAndRecordInvocationLaunchCandidates(
        allocator,
        allocator,
        bindings,
        .{ .warmup = 0, .samples = 1 },
    );
    defer allocator.free(records);

    try testing.expectEqual(measured_kernel.launch_resources.candidate_count, records.len);
    try testing.expectEqual(measured_kernel.launch_resources.candidate_count, state.launch_count);
    try testing.expectEqual(@as(usize, 1), measured.tuningRecordCount());
    for (records, 0..) |record, index| {
        try testing.expectEqual(measured_kernel.kernel_id, record.kernel.kernel_id);
        try testing.expectEqual(index, record.candidate_index);
        try testing.expectEqual(@as(u32, 1), record.sample_count);
    }

    const artifact_bytes = try measured.exportLaunchTuningArtifact(allocator);
    defer allocator.free(artifact_bytes);
    const decoded = try decodeLaunchTuningArtifact(allocator, artifact_bytes);
    defer allocator.free(decoded);
    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expectEqual(measured_kernel.kernel_id, decoded[0].selection.kernel_id);
    try testing.expect(decoded[0].selection.candidate_index < measured_kernel.launch_resources.candidate_count);

    var replay = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .launch_tuning_artifact = artifact_bytes,
    });
    defer replay.deinit();

    var graph = try replay.createLaunchGraphPlan(allocator, .{});
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections.len);
    try testing.expectEqual(decoded[0].selection.candidate_index, graph.tuning_selections[0].candidate_index);

    const replay_kernel = replay.artifactPlan().kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, replay_kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, replay.artifactPlan(), .cuda);
    defer allocator.free(count_bindings);

    try replay.launchAll(allocator, slot_bindings, count_bindings);

    const selected = replay_kernel.launch_resources.candidates[graph.tuning_selections[0].candidate_index];
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable fragment measured tuning skips fixed launch candidates" {
    const allocator = testing.allocator;

    var owned = try kernelCallChoirModule(allocator, "choir_loaded_fragment_measure_record_fixed_candidates");
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

    const source = ".visible .entry accy_custom_scale() { ret; }";
    const registry = artifact_product.KernelCallRegistry{ .entries = &.{.{
        .target = "accy.custom.scale",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_custom_scale",
        .argument_count = 5,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .payload = .{ .text = source },
        .launch = .{ .fixed = .{
            .grid = .{ 2, 3, 1 },
            .threadgroup = .{ 8, 2, 1 },
        } },
        .element_count_argument = .scalar_u32,
        .static_arguments = &.{.{ .u32 = 7 }},
    }} };

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .kernel_call_registry = &registry,
    });
    defer fragment.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    try testing.expectEqual(@as(usize, 1), kernel.launch_resources.candidate_count);

    const lhs = @as([8]f32, @splat(1.0));
    const rhs = @as([8]f32, @splat(2.0));
    const bindings = try fragment.prepareInvocationBindings(allocator, &.{
        std.mem.asBytes(&lhs),
        std.mem.asBytes(&rhs),
    });
    defer bindings.deinit();

    const records = try fragment.measureAndRecordInvocationLaunchCandidates(
        allocator,
        allocator,
        bindings,
        .{ .warmup = 0, .samples = 1 },
    );
    defer allocator.free(records);

    try testing.expectEqual(@as(usize, 0), records.len);
    try testing.expectEqual(@as(usize, 0), fragment.tuningRecordCount());
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "Choir executable fragment launches fused CUDA kernels" {
    const allocator = testing.allocator;

    var owned = try fusedAddMulChoirModule(allocator, "choir_loaded_fragment_fused_add_mul");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, fragment.artifactPlan(), .cuda);
    defer allocator.free(count_bindings);

    try fragment.launchAll(allocator, slot_bindings, count_bindings);

    try testing.expectEqual(@as(usize, 1), fragment.artifactPlan().kernelCount());
    try testing.expectEqual(@as(usize, 2), kernel.op_count);
    try testing.expectEqual(@as(usize, 5), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try testing.expect(state.last_launch_scalar_u32 == null);
    try testing.expectEqual(gpu.BufferAccess.write_only, state.last_buffer_access[0]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[1]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[2]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[3]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[4]);
}

test "Choir executable fragment records launch candidate records and applies artifact at creation" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_tuning_records");
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

    var measured = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer measured.deinit();

    const measured_kernel = measured.artifactPlan().kernels.items[0];
    try testing.expect(measured_kernel.launch_resources.candidate_count > 1);
    const records = [_]LaunchCandidateRecord{
        try launchCandidateRecord(
            measured_kernel,
            measured_kernel.launch_resources.candidates[0],
            .{
                .kernel_id = measured_kernel.kernel_id,
                .candidate_index = 0,
                .median_ns = 500,
                .sample_count = 8,
            },
        ),
        try launchCandidateRecord(
            measured_kernel,
            measured_kernel.launch_resources.candidates[1],
            .{
                .kernel_id = measured_kernel.kernel_id,
                .candidate_index = 1,
                .median_ns = 200,
                .sample_count = 4,
            },
        ),
    };
    try measured.recordLaunchCandidateRecords(&records);
    try testing.expectEqual(@as(usize, 1), measured.tuningRecordCount());

    const artifact_bytes = try measured.exportLaunchTuningArtifact(allocator);
    defer allocator.free(artifact_bytes);

    var replay = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .launch_tuning_artifact = artifact_bytes,
    });
    defer replay.deinit();
    try testing.expectEqual(@as(usize, 1), replay.tuningRecordCount());

    const replay_kernel = replay.artifactPlan().kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, replay_kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, replay.artifactPlan(), .cuda);
    defer allocator.free(count_bindings);

    var graph = try replay.createLaunchGraphPlan(allocator, .{});
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections.len);
    try testing.expectEqual(replay_kernel.kernel_id, graph.tuning_selections[0].kernel_id);
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections[0].candidate_index);

    try replay.launchAll(allocator, slot_bindings, count_bindings);

    const selected = replay_kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable fragment rejects mismatched launch candidate records" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_bad_candidate_records");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    var record = try launchCandidateRecord(
        kernel,
        kernel.launch_resources.candidates[0],
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
    );
    record.geometry.threadgroup[0] += 1;
    try testing.expectError(error.LaunchArgumentMismatch, fragment.recordLaunchCandidateRecords(&.{record}));
    try testing.expectEqual(@as(usize, 0), fragment.tuningRecordCount());

    record = try launchCandidateRecord(
        kernel,
        kernel.launch_resources.candidates[0],
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
    );
    record.geometry.dynamic_shared_memory_bytes += 1;
    try testing.expectError(error.LaunchArgumentMismatch, fragment.recordLaunchCandidateRecords(&.{record}));
    try testing.expectEqual(@as(usize, 0), fragment.tuningRecordCount());

    var layout_record = try launchCandidateRecord(
        kernel,
        kernel.launch_resources.candidates[0],
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
    );
    layout_record.kernel.output_layout_fingerprint ^= 1;
    try testing.expectError(error.LaunchArgumentMismatch, fragment.recordLaunchCandidateRecords(&.{layout_record}));
    try testing.expectEqual(@as(usize, 0), fragment.tuningRecordCount());

    var compile_record = try launchCandidateRecord(
        kernel,
        kernel.launch_resources.candidates[0],
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
    );
    compile_record.kernel.compile_required_features = .{ .tensor_cores = true };
    try testing.expectError(error.LaunchArgumentMismatch, fragment.recordLaunchCandidateRecords(&.{compile_record}));
    try testing.expectEqual(@as(usize, 0), fragment.tuningRecordCount());

    compile_record = try launchCandidateRecord(
        kernel,
        kernel.launch_resources.candidates[0],
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
    );
    compile_record.kernel.compile_required_subgroup = .{ .supported = true, .shuffle = true };
    try testing.expectError(error.LaunchArgumentMismatch, fragment.recordLaunchCandidateRecords(&.{compile_record}));
    try testing.expectEqual(@as(usize, 0), fragment.tuningRecordCount());
}

test "Choir executable fragment imports launch tuning artifact at creation" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_tuning_artifact");
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

    var measured = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer measured.deinit();

    const measured_kernel = measured.artifactPlan().kernels.items[0];
    try testing.expect(measured_kernel.launch_resources.candidate_count > 1);
    const records = [_]LaunchCandidateRecord{
        try launchCandidateRecord(
            measured_kernel,
            measured_kernel.launch_resources.candidates[0],
            .{
                .kernel_id = measured_kernel.kernel_id,
                .candidate_index = 0,
                .median_ns = 500,
                .sample_count = 8,
            },
        ),
        try launchCandidateRecord(
            measured_kernel,
            measured_kernel.launch_resources.candidates[1],
            .{
                .kernel_id = measured_kernel.kernel_id,
                .candidate_index = 1,
                .median_ns = 200,
                .sample_count = 4,
            },
        ),
    };
    try measured.recordLaunchCandidateRecords(&records);

    const artifact_bytes = try measured.exportLaunchTuningArtifact(allocator);
    defer allocator.free(artifact_bytes);

    var replay = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{
        .launch_tuning_artifact = artifact_bytes,
    });
    defer replay.deinit();
    try testing.expectEqual(@as(usize, 1), replay.tuningRecordCount());

    const replay_kernel = replay.artifactPlan().kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, replay_kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, replay.artifactPlan(), .cuda);
    defer allocator.free(count_bindings);

    var graph = try replay.createLaunchGraphPlan(allocator, .{});
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections.len);
    try testing.expectEqual(replay_kernel.kernel_id, graph.tuning_selections[0].kernel_id);
    try testing.expectEqual(@as(usize, 1), graph.tuning_selections[0].candidate_index);

    try replay.launchAll(allocator, slot_bindings, count_bindings);

    const selected = replay_kernel.launch_resources.candidates[1];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable fragment rejects invalid launch tuning artifacts without mutation" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_bad_tuning_artifact");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    const record = LaunchTuningCacheRecord{
        .key = LaunchTuningCacheKey.init(caps, kernel),
        .selection = .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 0,
            .median_ns = 500,
            .sample_count = 8,
        },
    };
    const artifact_bytes = try encodeLaunchTuningArtifact(allocator, &.{record});
    defer allocator.free(artifact_bytes);
    try fragment.importLaunchTuningArtifact(allocator, artifact_bytes);
    try testing.expectEqual(@as(usize, 1), fragment.tuningRecordCount());

    var bad_magic = try allocator.dupe(u8, artifact_bytes);
    defer allocator.free(bad_magic);
    bad_magic[0] ^= 0xff;
    try testing.expectError(error.InvalidArtifact, fragment.importLaunchTuningArtifact(allocator, bad_magic));
    try testing.expectEqual(@as(usize, 1), fragment.tuningRecordCount());
}

test "Choir executable fragment replaces launch tuning artifacts" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_replace_tuning_artifact");
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

    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const records = [_]LaunchCandidateRecord{try launchCandidateRecord(
        kernel,
        kernel.launch_resources.candidates[1],
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    )};
    try fragment.recordLaunchCandidateRecords(&records);
    try testing.expectEqual(@as(usize, 1), fragment.tuningRecordCount());

    const artifact_bytes = try fragment.exportLaunchTuningArtifact(allocator);
    defer allocator.free(artifact_bytes);

    try fragment.replaceLaunchTuningArtifact(allocator, &.{});
    try testing.expectEqual(@as(usize, 0), fragment.tuningRecordCount());

    try fragment.replaceLaunchTuningArtifact(allocator, artifact_bytes);
    try testing.expectEqual(@as(usize, 1), fragment.tuningRecordCount());
}

test "Choir executable fragment explicit launch tuning overrides cached records" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_loaded_fragment_tuning_override");
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
    var fragment = try createTestLoadedFragment(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer fragment.deinit();

    const kernel = fragment.artifactPlan().kernels.items[0];
    try testing.expect(kernel.launch_resources.candidate_count > 1);
    const records = [_]LaunchCandidateRecord{try launchCandidateRecord(
        kernel,
        kernel.launch_resources.candidates[1],
        .{
            .kernel_id = kernel.kernel_id,
            .candidate_index = 1,
            .median_ns = 200,
            .sample_count = 4,
        },
    )};
    try fragment.recordLaunchCandidateRecords(&records);
    try testing.expectEqual(@as(usize, 1), fragment.tuningRecordCount());

    const explicit = [_]LaunchCandidateMeasurement{.{
        .kernel_id = kernel.kernel_id,
        .candidate_index = 0,
        .median_ns = 1,
        .sample_count = 1,
    }};
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .cuda);
    defer allocator.free(slot_bindings);
    const count_bindings = try elementCountBindingsForPlan(allocator, fragment.artifactPlan(), .cuda);
    defer allocator.free(count_bindings);

    var graph = try fragment.createLaunchGraphPlan(allocator, .{
        .tuning = .{ .measurements = &explicit },
    });
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 0), graph.tuning_selections.len);
    try testing.expectEqual(@as(usize, 1), graph.nodes[0].tuning.measurements.len);

    try fragment.launchAllWithOptions(allocator, slot_bindings, count_bindings, .{
        .tuning = .{ .measurements = &explicit },
    });

    const selected = kernel.launch_resources.candidates[0];
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(selected.geometry.grid[0], state.last_launch_grid[0]);
    try testing.expectEqual(selected.geometry.threadgroup[0], state.last_launch_threadgroup[0]);
}

test "Choir executable plan launches Vulkan device-count kernels with count buffer" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_vulkan_executable_add");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .vulkan);
    defer allocator.free(slot_bindings);
    const count_binding = ElementCountBufferBinding{
        .kernel_id = kernel.kernel_id,
        .binding = bufferBinding(200, .vulkan, 4),
    };

    try executable.launchAll(allocator, &artifact_plan, slot_bindings, &.{count_binding});

    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 4), state.last_launch_buffer_count);
    try testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try testing.expect(state.last_launch_scalar_u32 == null);
    try testing.expectEqual(@as(u32, 8), state.last_launch_threadgroup[0]);
    try testing.expectEqual(@as(gpu.BackendObjectId, 200), state.last_buffer_ids[3]);
    try testing.expectEqual(gpu.BufferAccess.read_only, state.last_buffer_access[3]);
}

test "Choir executable plan requires a device-count buffer for Vulkan launches" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_vulkan_executable_missing_count");
    defer owned.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(owned.choir_module, owned.ctx, allocator, &cache);
    defer pass_ctx.deinit();

    var state = RecordingBackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    defer executable.deinit();

    const kernel = artifact_plan.kernels.items[0];
    const slot_bindings = try slotBindingsForKernel(allocator, kernel, .vulkan);
    defer allocator.free(slot_bindings);

    try testing.expectError(
        error.LaunchArgumentMismatch,
        executable.launchAll(allocator, &artifact_plan, slot_bindings, &.{}),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "Choir executable plan destroys loaded artifacts on deinit" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_executable_destroy_loaded");
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

    var artifact_plan = try createTestBackendArtifactPlan(allocator, handle, &pass_ctx, owned.choir_module, .{});
    defer artifact_plan.deinit();

    var executable = try loadKernels(allocator, handle, &artifact_plan);
    const loaded_id = state.last_loaded_id.?;
    executable.deinit();

    try testing.expectEqual(@as(usize, 1), state.destroy_count);
    try testing.expectEqual(loaded_id, state.last_destroyed_id.?);
}

fn familyTuningBlobTestModule(allocator: std.mem.Allocator, name: []const u8) !*semantic.SemanticModule {
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

test "Choir executable fragment consults an embedded family tuning artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const library = kernel_library;
    const tuning = library.tuning;

    var registry = try matrixProductTuningTestRegistry(allocator, handle);
    defer registry.deinit();
    const registry_value = registry.registry();

    const probe = library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const caps = try handle.queryCapabilities();
    const device = tuning.deviceFingerprint(caps);
    const thread_candidates = library.linalg.matrixProductThreadCandidatesForExtents(probe.m, probe.n);
    var winner = probe;
    winner.threads = thread_candidates.slice()[0];
    const winner_target = try library.linalg.matrixProductFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]tuning.FamilyTuningRecord{.{
        .key = try library.linalg.matrixProductFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1200,
        .sample_count = 30,
    }};
    const encoded = try tuning.encodeFamilyTuningArtifact(allocator, records[0..]);
    defer allocator.free(encoded);

    const module = try familyTuningBlobTestModule(allocator, "family_tuning_blob_prepare");
    var prepared = try prepareFragmentFromSemanticModule(
        allocator,
        handle,
        module,
        .{
            .kernel_call_registry = &registry_value,
            .family_tuning_artifact = encoded,
        },
    );
    defer prepared.deinit();

    const selected_target = findKernelCallTarget(prepared.choir_module) orelse
        return error.TestExpectedKernelCall;
    try std.testing.expectEqualStrings(winner_target, selected_target);
}

fn matrixProductScheduleTuningArtifactForThreads(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    probe: kernel_library.linalg.MatrixProduct,
    selected_threads: kernel_library.Threads2D,
) ![]u8 {
    const thread_candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(probe.m, probe.n);
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
    return try schedule_tuning.encodeMatrixProductFamilyScheduleTuningArtifact(allocator, &.{record});
}

fn nonHeuristicMatrixProductThreads(probe: kernel_library.linalg.MatrixProduct) !kernel_library.Threads2D {
    const heuristic = kernel_library.linalg.matrixProductThreadsForExtents(probe.m, probe.n);
    const thread_candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(probe.m, probe.n);
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
    const heuristic_threads = kernel_library.linalg.matrixProductThreadsForExtents(probe.m, probe.n);
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

test "Choir executable fragment consumes matrix product schedule tuning artifacts" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const selected_threads = try nonHeuristicMatrixProductThreads(probe);
    const encoded = try matrixProductScheduleTuningArtifactForThreads(allocator, handle, probe, selected_threads);
    defer allocator.free(encoded);

    var registry = try matrixProductTuningTestRegistry(allocator, handle);
    defer registry.deinit();
    const registry_value = registry.registry();

    var winner = probe;
    winner.threads = selected_threads;
    const winner_target = try kernel_library.linalg.matrixProductFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const module = try familyTuningBlobTestModule(allocator, "matrix_product_schedule_tuning_blob_prepare");
    var prepared = try prepareFragmentFromSemanticModule(
        allocator,
        handle,
        module,
        .{
            .kernel_call_registry = &registry_value,
            .matrix_product_schedule_tuning_artifact = encoded,
        },
    );
    defer prepared.deinit();

    const selected_target = findKernelCallTarget(prepared.choir_module) orelse
        return error.TestExpectedKernelCall;
    try std.testing.expectEqualStrings(winner_target, selected_target);
}

test "Choir executable fragment prefers explicit matrix product schedule over tuning artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const selected_threads = try nonHeuristicMatrixProductThreads(probe);
    const explicit_threads = kernel_library.linalg.matrixProductThreadsForExtents(probe.m, probe.n);
    try std.testing.expect(selected_threads.x != explicit_threads.x or selected_threads.y != explicit_threads.y);
    const encoded = try matrixProductScheduleTuningArtifactForThreads(allocator, handle, probe, selected_threads);
    defer allocator.free(encoded);

    var registry = try matrixProductTuningTestRegistry(allocator, handle);
    defer registry.deinit();
    const registry_value = registry.registry();

    var explicit = probe;
    explicit.threads = explicit_threads;
    const explicit_target = try kernel_library.linalg.matrixProductFamilyTarget(allocator, explicit);
    defer allocator.free(explicit_target);

    const module = try familyTuningBlobTestModule(allocator, "matrix_product_schedule_tuning_explicit_prepare");
    var prepared = try prepareFragmentFromSemanticModule(
        allocator,
        handle,
        module,
        .{
            .kernel_call_registry = &registry_value,
            .matrix_product_schedule = .{ .thread_blocks = explicit_threads },
            .matrix_product_schedule_tuning_artifact = encoded,
        },
    );
    defer prepared.deinit();

    const selected_target = findKernelCallTarget(prepared.choir_module) orelse
        return error.TestExpectedKernelCall;
    try std.testing.expectEqualStrings(explicit_target, selected_target);
}

test "Choir executable fragment rejects malformed matrix product schedule tuning artifacts" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const module = try familyTuningBlobTestModule(allocator, "matrix_product_schedule_tuning_blob_invalid");
    const bad_bytes = [_]u8{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidArtifact, prepareFragmentFromSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .matrix_product_schedule_tuning_artifact = bad_bytes[0..] },
    ));

    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const bad_selection = try matrixProductScheduleTuningArtifactForThreads(
        allocator,
        state.handle(),
        probe,
        .{ .x = 99, .y = 99 },
    );
    defer allocator.free(bad_selection);
    var registry = try matrixProductTuningTestRegistry(allocator, state.handle());
    defer registry.deinit();
    const registry_value = registry.registry();
    const selected_module = try familyTuningBlobTestModule(allocator, "matrix_product_schedule_tuning_blob_bad_selection");
    var failure: preparation.BackendPreparationFailure = .{};
    defer failure.deinit(allocator);
    try std.testing.expectError(error.PassFailed, prepareFragmentFromSemanticModule(
        allocator,
        state.handle(),
        selected_module,
        .{
            .kernel_call_registry = &registry_value,
            .matrix_product_schedule_tuning_artifact = bad_selection,
            .preparation_failure = &failure,
        },
    ));
    try std.testing.expectEqualStrings(preparation.tensor_pipeline_name, failure.pipeline_name.?);
    try std.testing.expectEqual(passes.PassFailureKind.pass, failure.failure_kind.?);
    try std.testing.expectEqualStrings(preparation.einsum_lowering_pass_name, failure.pass_name.?);
    try std.testing.expect(failure.target_op_name != null);
    try std.testing.expect(failure.worker_count > 0);
}

test "Choir executable fragment rejects malformed family tuning artifacts" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const module = try familyTuningBlobTestModule(allocator, "family_tuning_blob_invalid");
    const bad_bytes = [_]u8{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidArtifact, prepareFragmentFromSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .family_tuning_artifact = bad_bytes[0..] },
    ));
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

test "matrix product schedule recipe restores the artifact reader after plan destruction" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const winner = try nonHeuristicMatrixProductThreads(probe);
    const bytes = block: {
        const artifact = try matrixProductScheduleTuningArtifactForThreads(
            allocator,
            state.handle(),
            probe,
            winner,
        );
        defer allocator.free(artifact);
        const module = try familyTuningBlobTestModule(allocator, "matrix_recipe_input");
        defer module.deinit();
        break :block try matrixProductScheduleRecipe(
            allocator,
            state.handle(),
            artifact,
            module.choir_module,
        );
    };
    defer allocator.free(bytes);
    var decoded = try accy_choir.record.codec.decode(
        allocator,
        preparation.recipe.Record(.tensor),
        .tensor,
        bytes,
    );
    defer decoded.deinit();
    const reader = decoded.value.options.einsum.matrix_product_tuning.?;
    try std.testing.expectEqual(winner, (try reader.resolve(probe)).?);
    var missing = probe;
    missing.k += 1;
    try std.testing.expectEqual(null, try reader.resolve(missing));
}

test "matrix product schedule recipe normalizes artifact duplicates through the cache" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const winner = try nonHeuristicMatrixProductThreads(probe);
    const artifact = try matrixProductScheduleTuningArtifactForThreads(
        allocator,
        state.handle(),
        probe,
        winner,
    );
    defer allocator.free(artifact);
    const decoded = try schedule_tuning.decodeMatrixProductFamilyScheduleTuningArtifact(
        allocator,
        artifact,
    );
    defer allocator.free(decoded);
    var entries = [_]kernel_library.tuning.MatrixProductFamilyScheduleTuningRecord{
        decoded[0], decoded[0],
    };
    const slow = kernel_library.linalg.matrixProductThreadsForExtents(probe.m, probe.n);
    entries[0].selection.threads = .{ .x = slow.x, .y = slow.y };
    entries[0].selection.winner_median_ns += 1;
    const module = try familyTuningBlobTestModule(allocator, "matrix_recipe_duplicates");
    defer module.deinit();
    var recipes: [2][]u8 = undefined;
    var count: usize = 0;
    defer for (recipes[0..count]) |bytes| allocator.free(bytes);
    for (&recipes) |*bytes| {
        const encoded = try schedule_tuning.encodeMatrixProductFamilyScheduleTuningArtifact(
            allocator,
            &entries,
        );
        defer allocator.free(encoded);
        bytes.* = try matrixProductScheduleRecipe(
            allocator,
            state.handle(),
            encoded,
            module.choir_module,
        );
        count += 1;
        std.mem.swap(
            kernel_library.tuning.MatrixProductFamilyScheduleTuningRecord,
            &entries[0],
            &entries[1],
        );
    }
    try std.testing.expectEqualStrings(recipes[0], recipes[1]);
    var restored = try accy_choir.record.codec.decode(
        allocator,
        preparation.recipe.Record(.tensor),
        .tensor,
        recipes[0],
    );
    defer restored.deinit();
    const reader = restored.value.options.einsum.matrix_product_tuning.?;
    try std.testing.expectEqual(@as(usize, 1), reader.records.len);
    try std.testing.expectEqual(winner, (try reader.resolve(probe)).?);
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

test "matrix product schedule snapshot releases every failed acquisition" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const winner = try nonHeuristicMatrixProductThreads(probe);
    const artifact = try matrixProductScheduleTuningArtifactForThreads(
        allocator,
        state.handle(),
        probe,
        winner,
    );
    defer allocator.free(artifact);
    try std.testing.checkAllAllocationFailures(allocator, matrixProductSchedulePlanFailure, .{
        state.handle(), artifact,
    });
}
