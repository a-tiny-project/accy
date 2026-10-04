const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const gpu_codegen = choir.backends.gpu;
const GpuDialect = choir.dialects.gpu.GpuDialect;
const kernel_program = @import("../kernel/model/root.zig").program;
const accy_choir = @import("../choir/root.zig");
const artifact_model = @import("model/root.zig");
const preparation = @import("../preparation/root.zig");
const kernelization_model = @import("../preparation/kernelization/model/root.zig");
const backend_legalization = preparation.backend;
const bufferization = preparation.bufferization;
const dialect_mod = accy_choir.dialect;
const kernelization = preparation.kernelization;
const kernel_outlining = preparation.outlining;
const layout_planning = preparation.layout;
const memory_space = preparation.memory;
const schedule_planning = preparation.schedule;
const semantic = accy_choir.semantic;
const target_profile = preparation.target;
const target_product = @import("../target/root.zig");

const ir = choir.ir;
const passes = choir.passes;

const ArtifactPlanOptions = artifact_model.ArtifactPlanOptions;
const ElementCountArgument = artifact_model.ElementCountArgument;
const KernelCallArtifact = artifact_model.KernelCallArtifact;
const KernelCallDerivedLaunch = artifact_model.KernelCallDerivedLaunch;
const KernelCallLaunch = artifact_model.KernelCallLaunch;
const KernelCallRegistry = artifact_model.KernelCallRegistry;
const StandaloneKernelOptions = artifact_model.StandaloneKernelOptions;
const defaultArtifactFormat = artifact_model.defaultArtifactFormat;
const validateThreadgroup = artifact_model.validateThreadgroup;

pub const BackendArtifactPlanSource = struct {
    pass_ctx: *passes.PassContext,
    choir_module: *ir.Operation,
    lowered_kernels: *const kernelization.KernelizationAnalysis,
};

const CompilePlan = struct {
    entry_name: []const u8,
    entry_name_owned: ?[]u8 = null,
    argument_count: u32 = 0,
    payload: gpu.CompilePayload = .none,
    launch: CompileLaunchPlan = .generic,
    lowered_kernel: ?*const kernelization.LoweredKernel = null,
    required_dtypes: gpu.DTypeSet = .{},
    required_features: gpu_abi.Features = .{},
    required_subgroup: gpu_abi.SubgroupRequirements = .{},
    push_constants: gpu_abi.PushConstants = .{},
    shape_family_fingerprint: ?u64 = null,
    element_count_argument: ?ElementCountArgument = null,
    runtime_scalar_argument_count: u32 = 0,
    runtime_scalar_defaults: []gpu_abi.ScalarArgument = &.{},
    static_arguments: []gpu_abi.ScalarArgument = &.{},

    fn deinit(self: *CompilePlan, allocator: std.mem.Allocator) void {
        if (self.entry_name_owned) |entry_name| allocator.free(entry_name);
        if (self.runtime_scalar_defaults.len != 0) allocator.free(self.runtime_scalar_defaults);
        if (self.static_arguments.len != 0) allocator.free(self.static_arguments);
        deinitCompilePayload(allocator, self.payload);
        self.* = undefined;
    }
};

const CompileLaunchPlan = union(enum) {
    generic,
    dot_general: DotGeneralLaunchPlan,
    reduction: ReductionLaunchPlan,
    kernel_call: KernelCallLaunch,
};

pub const PlannedKernelCompilePayload = enum {
    none,
    bytes,
    words_u32,
    text,
};

pub const PlannedKernelCompileLaunch = enum {
    authored,
    generic,
    dot_general,
    reduction,
    kernel_call,
};

pub const PlannedKernelCompileContract = struct {
    source: PlannedKernelSource,
    launch: PlannedKernelCompileLaunch,
    format: gpu.ArtifactFormat,
    entry_name: []u8,
    argument_count: u32,
    required_dtypes: gpu.DTypeSet,
    required_features: gpu_abi.Features = .{},
    required_subgroup: gpu_abi.SubgroupRequirements = .{},
    shape_family_fingerprint: ?u64 = null,
    payload: PlannedKernelCompilePayload,
    payload_byte_count: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        source: PlannedKernelSource,
        launch: PlannedKernelCompileLaunch,
        format: gpu.ArtifactFormat,
        entry_name: []const u8,
        argument_count: u32,
        required_dtypes: gpu.DTypeSet,
        required_features: gpu_abi.Features,
        required_subgroup: gpu_abi.SubgroupRequirements,
        shape_family_fingerprint: ?u64,
        payload: gpu.CompilePayload,
    ) !PlannedKernelCompileContract {
        return .{
            .source = source,
            .launch = launch,
            .format = format,
            .entry_name = try allocator.dupe(u8, entry_name),
            .argument_count = argument_count,
            .required_dtypes = required_dtypes,
            .required_features = required_features,
            .required_subgroup = required_subgroup,
            .shape_family_fingerprint = shape_family_fingerprint,
            .payload = compilePayloadKind(payload),
            .payload_byte_count = try compilePayloadByteCount(payload),
        };
    }

    pub fn deinit(self: *PlannedKernelCompileContract, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_name);
        self.* = undefined;
    }

    fn copy(
        self: PlannedKernelCompileContract,
        allocator: std.mem.Allocator,
    ) gpu.BackendError!PlannedKernelCompileContract {
        return .{
            .source = self.source,
            .launch = self.launch,
            .format = self.format,
            .entry_name = allocator.dupe(u8, self.entry_name) catch return error.OutOfMemory,
            .argument_count = self.argument_count,
            .required_dtypes = self.required_dtypes,
            .required_features = self.required_features,
            .required_subgroup = self.required_subgroup,
            .shape_family_fingerprint = self.shape_family_fingerprint,
            .payload = self.payload,
            .payload_byte_count = self.payload_byte_count,
        };
    }
};

const DotGeneralLaunchPlan = struct {
    input_dtype: gpu_abi.DType,
    output_dtype: gpu_abi.DType,
    m: u32,
    n: u32,
    k: u32,
    batch: u32 = 1,
};

const ReductionLaunchPlan = struct {
    kind: LaunchReductionKind,
    input_dtype: gpu_abi.DType,
    output_dtype: gpu_abi.DType,
    input_rank: u8,
    axis: u8,
    input_element_count: u32,
    output_element_count: u32,
    reduction_extent: u32,
};

pub const PlannedKernel = struct {
    compile: PlannedKernelCompileContract,
    kernel_id: usize,
    work_item_id: usize,
    output_slot_id: usize,
    input_slot_ids: []usize,
    output_layout_fingerprint: u64,
    input_layout_fingerprint: u64,
    element_count: u64,
    op_count: usize,
    resources: schedule_planning.ScheduleResourceEstimate,
    artifact: gpu.KernelArtifact,
    launch_resources: LaunchResourcePlan,
    kernel_call_launch: ?KernelCallLaunch = null,
    element_count_argument: ElementCountArgument,
    element_count_argument_value: u64,
    runtime_scalar_argument_count: u32,
    runtime_scalar_defaults: []gpu_abi.ScalarArgument,
    static_arguments: []gpu_abi.ScalarArgument,
    output_fill_pattern: ?u32 = null,
    scratch_fill_pattern: ?u32 = null,

    fn deinit(self: *PlannedKernel, allocator: std.mem.Allocator) void {
        self.artifact.deinit();
        self.compile.deinit(allocator);
        allocator.free(self.input_slot_ids);
        if (self.runtime_scalar_defaults.len != 0) allocator.free(self.runtime_scalar_defaults);
        if (self.static_arguments.len != 0) allocator.free(self.static_arguments);
        self.* = undefined;
    }

    fn copy(self: PlannedKernel, allocator: std.mem.Allocator) gpu.BackendError!PlannedKernel {
        var compile = try self.compile.copy(allocator);
        errdefer compile.deinit(allocator);

        const input_slot_ids = allocator.dupe(
            usize,
            self.input_slot_ids,
        ) catch return error.OutOfMemory;
        errdefer allocator.free(input_slot_ids);

        var artifact = try copyKernelArtifact(allocator, self.artifact);
        errdefer artifact.deinit();

        const runtime_scalar_defaults = allocator.dupe(
            gpu_abi.ScalarArgument,
            self.runtime_scalar_defaults,
        ) catch return error.OutOfMemory;
        errdefer if (runtime_scalar_defaults.len != 0) allocator.free(runtime_scalar_defaults);

        const static_arguments = allocator.dupe(
            gpu_abi.ScalarArgument,
            self.static_arguments,
        ) catch return error.OutOfMemory;
        errdefer if (static_arguments.len != 0) allocator.free(static_arguments);

        return .{
            .compile = compile,
            .kernel_id = self.kernel_id,
            .work_item_id = self.work_item_id,
            .output_slot_id = self.output_slot_id,
            .input_slot_ids = input_slot_ids,
            .output_layout_fingerprint = self.output_layout_fingerprint,
            .input_layout_fingerprint = self.input_layout_fingerprint,
            .element_count = self.element_count,
            .op_count = self.op_count,
            .resources = self.resources,
            .artifact = artifact,
            .launch_resources = self.launch_resources,
            .kernel_call_launch = self.kernel_call_launch,
            .element_count_argument = self.element_count_argument,
            .element_count_argument_value = self.element_count_argument_value,
            .runtime_scalar_argument_count = self.runtime_scalar_argument_count,
            .runtime_scalar_defaults = runtime_scalar_defaults,
            .static_arguments = static_arguments,
            .output_fill_pattern = self.output_fill_pattern,
            .scratch_fill_pattern = self.scratch_fill_pattern,
        };
    }
};

pub const PlannedKernelSource = enum {
    tensor,
    kernel_call,
    choir_kernel,
};

pub const PlannedSlot = struct {
    slot_id: usize,
    role: bufferization.BufferRole,
    dtype: gpu_abi.DType,
    memory_space: memory_space.MemorySpace,
    memory_access: memory_space.MemoryAccess,
    boundary_transfer: memory_space.BoundaryTransfer,
    layout_kind: layout_planning.LayoutKind,
    dims: []i64,
    element_strides: ?[]u64,
    minor_to_major: []usize,
    element_count: ?u64,
    byte_size: ?u64,
    alignment: u64,
    contiguous: bool,
    static_layout: bool,
    layout_fingerprint: u64,
    constant_payload: []u8,

    fn init(
        allocator: std.mem.Allocator,
        slot: bufferization.BufferSlot,
        memory_assignment: memory_space.MemorySpaceAssignment,
        layout_assignment: layout_planning.LayoutAssignment,
    ) !PlannedSlot {
        if (slot.id != memory_assignment.slot_id or slot.id != layout_assignment.slot_id) {
            return error.InvalidArtifact;
        }
        const dims = try allocator.dupe(i64, slot.dims);
        errdefer allocator.free(dims);

        var element_strides: ?[]u64 = null;
        if (layout_assignment.element_strides) |strides| {
            element_strides = try allocator.dupe(u64, strides);
            errdefer if (element_strides) |owned| allocator.free(owned);
        }

        const minor_to_major = try allocator.dupe(usize, layout_assignment.minor_to_major);
        errdefer allocator.free(minor_to_major);

        const constant_payload = try constantPayloadForSlot(allocator, slot);
        errdefer if (constant_payload.len != 0) allocator.free(constant_payload);

        const layout_fingerprint = layoutFingerprint(
            memory_assignment.space,
            layout_assignment.kind,
            dims,
            element_strides,
            minor_to_major,
            layout_assignment.alignment,
            layout_assignment.contiguous,
            layout_assignment.static_layout,
        );

        return .{
            .slot_id = slot.id,
            .role = slot.role,
            .dtype = slot.dtype,
            .memory_space = memory_assignment.space,
            .memory_access = memory_assignment.access,
            .boundary_transfer = memory_assignment.transfer,
            .layout_kind = layout_assignment.kind,
            .dims = dims,
            .element_strides = element_strides,
            .minor_to_major = minor_to_major,
            .element_count = slot.element_count,
            .byte_size = slot.byte_size,
            .alignment = layout_assignment.alignment,
            .contiguous = layout_assignment.contiguous,
            .static_layout = layout_assignment.static_layout,
            .layout_fingerprint = layout_fingerprint,
            .constant_payload = constant_payload,
        };
    }

    fn deinit(self: *PlannedSlot, allocator: std.mem.Allocator) void {
        allocator.free(self.dims);
        if (self.element_strides) |strides| allocator.free(strides);
        allocator.free(self.minor_to_major);
        if (self.constant_payload.len != 0) allocator.free(self.constant_payload);
        self.* = undefined;
    }

    fn copy(self: PlannedSlot, allocator: std.mem.Allocator) gpu.BackendError!PlannedSlot {
        const dims = allocator.dupe(i64, self.dims) catch return error.OutOfMemory;
        errdefer allocator.free(dims);

        var element_strides: ?[]u64 = null;
        if (self.element_strides) |strides| {
            element_strides = allocator.dupe(u64, strides) catch return error.OutOfMemory;
            errdefer if (element_strides) |owned| allocator.free(owned);
        }

        const minor_to_major = allocator.dupe(
            usize,
            self.minor_to_major,
        ) catch return error.OutOfMemory;
        errdefer allocator.free(minor_to_major);

        const constant_payload = allocator.dupe(
            u8,
            self.constant_payload,
        ) catch return error.OutOfMemory;
        errdefer if (constant_payload.len != 0) allocator.free(constant_payload);

        return .{
            .slot_id = self.slot_id,
            .role = self.role,
            .dtype = self.dtype,
            .memory_space = self.memory_space,
            .memory_access = self.memory_access,
            .boundary_transfer = self.boundary_transfer,
            .layout_kind = self.layout_kind,
            .dims = dims,
            .element_strides = element_strides,
            .minor_to_major = minor_to_major,
            .element_count = self.element_count,
            .byte_size = self.byte_size,
            .alignment = self.alignment,
            .contiguous = self.contiguous,
            .static_layout = self.static_layout,
            .layout_fingerprint = self.layout_fingerprint,
            .constant_payload = constant_payload,
        };
    }

    pub fn hasStaticSize(self: PlannedSlot) bool {
        return self.byte_size != null;
    }

    pub fn constantBytes(self: PlannedSlot) ?[]const u8 {
        if (!self.role.constant) return null;
        return self.constant_payload;
    }
};

pub const BackendArtifactPlan = struct {
    allocator: std.mem.Allocator,
    backend_kind: gpu.BackendKind,
    format: gpu.ArtifactFormat,
    target_profile: target_profile.BackendTargetProfile,
    slots: []PlannedSlot,
    input_slot_ids: []usize,
    output_slot_ids: []usize,
    kernels: std.ArrayListUnmanaged(PlannedKernel),
    total_kernel_ops: usize = 0,
    total_static_bytes: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        profile: target_profile.BackendTargetProfile,
    ) BackendArtifactPlan {
        return .{
            .allocator = allocator,
            .backend_kind = profile.backend_kind,
            .format = profile.artifact_format,
            .target_profile = profile,
            .slots = &.{},
            .input_slot_ids = &.{},
            .output_slot_ids = &.{},
            .kernels = .empty,
        };
    }

    pub fn deinit(self: *BackendArtifactPlan) void {
        for (self.kernels.items) |*kernel| {
            kernel.deinit(self.allocator);
        }
        self.kernels.deinit(self.allocator);
        for (self.slots) |*slot| {
            slot.deinit(self.allocator);
        }
        if (self.slots.len != 0) self.allocator.free(self.slots);
        if (self.input_slot_ids.len != 0) self.allocator.free(self.input_slot_ids);
        if (self.output_slot_ids.len != 0) self.allocator.free(self.output_slot_ids);
        self.* = undefined;
    }

    pub fn copy(
        self: *const BackendArtifactPlan,
        allocator: std.mem.Allocator,
    ) gpu.BackendError!BackendArtifactPlan {
        var copied = BackendArtifactPlan.init(allocator, self.target_profile);
        errdefer copied.deinit();

        const slots = allocator.alloc(PlannedSlot, self.slots.len) catch return error.OutOfMemory;
        var slots_owned = true;
        var initialized_slots: usize = 0;
        errdefer {
            if (slots_owned) {
                for (slots[0..initialized_slots]) |*slot| slot.deinit(allocator);
                if (slots.len != 0) allocator.free(slots);
            }
        }
        for (self.slots, 0..) |slot, index| {
            slots[index] = try slot.copy(allocator);
            initialized_slots += 1;
        }
        copied.slots = slots;
        slots_owned = false;

        copied.input_slot_ids = allocator.dupe(
            usize,
            self.input_slot_ids,
        ) catch return error.OutOfMemory;

        copied.output_slot_ids = allocator.dupe(
            usize,
            self.output_slot_ids,
        ) catch return error.OutOfMemory;

        try copied.kernels.ensureTotalCapacity(allocator, self.kernels.items.len);
        for (self.kernels.items) |kernel| {
            var kernel_copy = try kernel.copy(allocator);
            var kernel_owned = true;
            errdefer if (kernel_owned) kernel_copy.deinit(allocator);
            copied.kernels.appendAssumeCapacity(kernel_copy);
            kernel_owned = false;
        }

        copied.total_kernel_ops = self.total_kernel_ops;
        copied.total_static_bytes = self.total_static_bytes;
        return copied;
    }

    pub fn slotCount(self: BackendArtifactPlan) usize {
        return self.slots.len;
    }

    pub fn kernelCount(self: BackendArtifactPlan) usize {
        return self.kernels.items.len;
    }

    pub fn slotById(self: *const BackendArtifactPlan, slot_id: usize) ?*const PlannedSlot {
        if (slot_id < self.slots.len and self.slots[slot_id].slot_id == slot_id) {
            return &self.slots[slot_id];
        }
        for (self.slots) |*slot| {
            if (slot.slot_id == slot_id) return slot;
        }
        return null;
    }

    fn setSlots(
        self: *BackendArtifactPlan,
        buffer_plan: *const bufferization.BufferPlanAnalysis,
        memory_plan: *const memory_space.MemorySpacePlanAnalysis,
        layout_plan: *const layout_planning.LayoutPlanAnalysis,
        choir_module: *ir.Operation,
    ) !void {
        std.debug.assert(self.slots.len == 0);
        std.debug.assert(self.input_slot_ids.len == 0);
        std.debug.assert(self.output_slot_ids.len == 0);

        const slots = try self.allocator.alloc(PlannedSlot, buffer_plan.slots.items.len);
        var initialized: usize = 0;
        errdefer {
            for (slots[0..initialized]) |*slot| {
                slot.deinit(self.allocator);
            }
            if (slots.len != 0) self.allocator.free(slots);
        }
        for (buffer_plan.slots.items, 0..) |slot, index| {
            const memory_assignment = memory_plan.getAssignmentForSlot(slot.id) orelse {
                return error.MissingMemorySpaceAssignment;
            };
            const layout_assignment = layout_plan.getAssignmentForSlot(slot.id) orelse {
                return error.MissingLayoutAssignment;
            };
            slots[index] = try PlannedSlot.init(
                self.allocator,
                slot,
                memory_assignment.*,
                layout_assignment.*,
            );
            initialized += 1;
        }

        const input_slot_ids = try collectInputSlotIds(self.allocator, buffer_plan);
        errdefer if (input_slot_ids.len != 0) self.allocator.free(input_slot_ids);

        const output_slot_ids = try collectOutputSlotIds(self.allocator, choir_module, buffer_plan);
        errdefer if (output_slot_ids.len != 0) self.allocator.free(output_slot_ids);

        self.slots = slots;
        self.input_slot_ids = input_slot_ids;
        self.output_slot_ids = output_slot_ids;
    }

    fn addKernel(
        self: *BackendArtifactPlan,
        outline: kernelization_model.KernelOutline,
        resources: schedule_planning.ScheduleResourceEstimate,
        legal: backend_legalization.BackendKernelLegalization,
        artifact: gpu.KernelArtifact,
        launch_resources: LaunchResourcePlan,
        kernel_call_launch: ?KernelCallLaunch,
        element_count_argument: ElementCountArgument,
        element_count_argument_value: u64,
        runtime_scalar_argument_count: u32,
        runtime_scalar_defaults: []const gpu_abi.ScalarArgument,
        static_arguments: []const gpu_abi.ScalarArgument,
        compile: PlannedKernelCompileContract,
        output_fill_pattern: ?u32,
        scratch_fill_pattern: ?u32,
    ) !void {
        var owned_artifact = artifact;
        errdefer owned_artifact.deinit();
        var owned_compile = compile;
        errdefer owned_compile.deinit(self.allocator);

        const input_slot_ids = try self.allocator.dupe(usize, outline.input_slot_ids);
        errdefer self.allocator.free(input_slot_ids);
        const owned_runtime_scalar_defaults = try self.allocator.dupe(
            gpu_abi.ScalarArgument,
            runtime_scalar_defaults,
        );
        errdefer if (owned_runtime_scalar_defaults.len !=
            0) self.allocator.free(owned_runtime_scalar_defaults);
        const owned_static_arguments = try self.allocator.dupe(
            gpu_abi.ScalarArgument,
            static_arguments,
        );
        errdefer if (owned_static_arguments.len != 0) self.allocator.free(owned_static_arguments);
        const output_layout_fingerprint = try self.layoutFingerprintForSlot(outline.output_slot_id);
        const input_layout_fingerprint = try self.layoutFingerprintForInputs(input_slot_ids);

        try self.kernels.append(self.allocator, .{
            .compile = owned_compile,
            .kernel_id = outline.id,
            .work_item_id = outline.work_item_id,
            .output_slot_id = outline.output_slot_id,
            .input_slot_ids = input_slot_ids,
            .output_layout_fingerprint = output_layout_fingerprint,
            .input_layout_fingerprint = input_layout_fingerprint,
            .element_count = outline.element_count,
            .op_count = outline.op_count,
            .resources = resources,
            .artifact = owned_artifact,
            .launch_resources = launch_resources,
            .kernel_call_launch = kernel_call_launch,
            .element_count_argument = element_count_argument,
            .element_count_argument_value = element_count_argument_value,
            .runtime_scalar_argument_count = runtime_scalar_argument_count,
            .runtime_scalar_defaults = owned_runtime_scalar_defaults,
            .static_arguments = owned_static_arguments,
            .output_fill_pattern = output_fill_pattern,
            .scratch_fill_pattern = scratch_fill_pattern,
        });
        self.total_kernel_ops += outline.op_count;
        self.total_static_bytes += legal.static_bytes;
    }

    pub fn addStandaloneKernel(
        self: *BackendArtifactPlan,
        artifact: gpu.KernelArtifact,
        launch_resources: LaunchResourcePlan,
        compile: PlannedKernelCompileContract,
        options: StandaloneKernelOptions,
    ) !void {
        var owned_artifact = artifact;
        errdefer owned_artifact.deinit();
        var owned_compile = compile;
        errdefer owned_compile.deinit(self.allocator);

        const input_slot_ids = try self.allocator.alloc(usize, 0);
        errdefer self.allocator.free(input_slot_ids);
        const owned_static_arguments = try self.allocator.dupe(
            gpu_abi.ScalarArgument,
            options.static_arguments,
        );
        errdefer if (owned_static_arguments.len != 0) self.allocator.free(owned_static_arguments);

        try self.kernels.append(self.allocator, .{
            .compile = owned_compile,
            .kernel_id = 0,
            .work_item_id = 0,
            .output_slot_id = 0,
            .input_slot_ids = input_slot_ids,
            .output_layout_fingerprint = 0,
            .input_layout_fingerprint = 0,
            .element_count = launch_resources.element_count,
            .op_count = 0,
            .resources = .{
                .element_count = launch_resources.element_count,
                .element_size = 1,
                .op_count = 0,
            },
            .artifact = owned_artifact,
            .launch_resources = launch_resources,
            .kernel_call_launch = null,
            .element_count_argument = .none,
            .element_count_argument_value = 0,
            .runtime_scalar_argument_count = options.runtime_scalar_argument_count,
            .runtime_scalar_defaults = &.{},
            .static_arguments = owned_static_arguments,
        });
    }

    fn layoutFingerprintForSlot(
        self: *const BackendArtifactPlan,
        slot_id: usize,
    ) !u64 {
        const slot = self.slotById(slot_id) orelse return error.InvalidArtifact;
        return slot.layout_fingerprint;
    }

    fn layoutFingerprintForInputs(
        self: *const BackendArtifactPlan,
        input_slot_ids: []const usize,
    ) !u64 {
        var builder = choir.product.incremental.FingerprintBuilder{};
        builder.updateBytes("accy.artifact.input_layouts");
        builder.updateUsize(input_slot_ids.len);
        for (input_slot_ids) |slot_id| {
            const slot = self.slotById(slot_id) orelse return error.InvalidArtifact;
            builder.updateU64(slot.layout_fingerprint);
        }
        return builder.finish();
    }
};

test "artifact plan copy owns standalone kernel data" {
    const allocator = std.testing.allocator;

    var artifact_plan = BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var plan_owned = true;
    defer if (plan_owned) artifact_plan.deinit();

    var artifact = try gpu.KernelArtifact.init(allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "kernel0",
        .argument_count = 0,
    });
    var artifact_owned = true;
    errdefer if (artifact_owned) artifact.deinit();
    try artifact.setOwnedText("payload");

    var compile = try PlannedKernelCompileContract.init(
        allocator,
        .choir_kernel,
        .authored,
        .cuda_ptx,
        "kernel0",
        0,
        gpu.DTypeSet.init(&.{.f32}),
        .{},
        .{},
        null,
        .{ .text = "payload" },
    );
    var compile_owned = true;
    errdefer if (compile_owned) compile.deinit(allocator);

    try artifact_plan.addStandaloneKernel(
        artifact,
        .{
            .format = .cuda_ptx,
            .element_count = 1,
            .geometry = .{
                .grid = .{ 1, 1, 1 },
                .threadgroup = .{ 1, 1, 1 },
            },
        },
        compile,
        .{},
    );
    artifact_owned = false;
    compile_owned = false;

    var copied = try artifact_plan.copy(allocator);
    defer copied.deinit();

    artifact_plan.deinit();
    plan_owned = false;

    try std.testing.expectEqual(@as(usize, 1), copied.kernelCount());
    const kernel = copied.kernels.items[0];
    try std.testing.expectEqualStrings("kernel0", kernel.artifact.entry_name);
    try std.testing.expectEqual(gpu.PayloadOwnership.owned, kernel.artifact.payload_ownership);
    switch (kernel.artifact.payload) {
        .text => |text| try std.testing.expectEqualStrings("payload", text),
        else => return error.InvalidArtifact,
    }
    try std.testing.expectEqualStrings("kernel0", kernel.compile.entry_name);
    try std.testing.expectEqual(PlannedKernelCompilePayload.text, kernel.compile.payload);
}

pub const BackendSlotLifetime = struct {
    slot_id: usize,
    role: bufferization.BufferRole,
    dtype: gpu_abi.DType,
    memory_space: memory_space.MemorySpace,
    layout_kind: layout_planning.LayoutKind,
    element_count: ?u64,
    byte_size: ?u64,
    alignment: u64,
    layout_fingerprint: u64,
    first_kernel_index: usize = std.math.maxInt(usize),
    last_kernel_index: usize = 0,

    pub fn hasKernelUse(self: BackendSlotLifetime) bool {
        return self.first_kernel_index != std.math.maxInt(usize);
    }

    pub fn isBackendAllocatable(self: BackendSlotLifetime) bool {
        return self.hasKernelUse() and
            !self.role.input and !self.role.constant and self.byte_size != null;
    }
};

pub const BackendBufferAllocationPlan = struct {
    allocation_id: usize,
    byte_size: u64,
    dtype: gpu_abi.DType,
    memory_space: memory_space.MemorySpace,
    layout_kind: layout_planning.LayoutKind,
    element_count: ?u64,
    alignment: u64,
    layout_fingerprint: u64,
    last_kernel_index: usize,
};

pub const BackendBufferReuseAssignment = struct {
    slot_id: usize,
    allocation_id: usize,
};

pub const BackendMemoryPlan = struct {
    allocator: std.mem.Allocator,
    lifetimes: []BackendSlotLifetime,
    allocations: []BackendBufferAllocationPlan,
    assignments: []BackendBufferReuseAssignment,
    total_static_slot_bytes: u64 = 0,
    allocated_static_bytes: u64 = 0,
    peak_static_live_bytes: u64 = 0,

    pub fn deinit(self: *BackendMemoryPlan) void {
        if (self.lifetimes.len != 0) self.allocator.free(self.lifetimes);
        if (self.allocations.len != 0) self.allocator.free(self.allocations);
        if (self.assignments.len != 0) self.allocator.free(self.assignments);
        self.* = undefined;
    }

    pub fn assignmentForSlot(
        self: BackendMemoryPlan,
        slot_id: usize,
    ) ?BackendBufferReuseAssignment {
        for (self.assignments) |assignment| {
            if (assignment.slot_id == slot_id) return assignment;
        }
        return null;
    }

    pub fn allocationForId(
        self: BackendMemoryPlan,
        allocation_id: usize,
    ) ?BackendBufferAllocationPlan {
        for (self.allocations) |allocation| {
            if (allocation.allocation_id == allocation_id) return allocation;
        }
        return null;
    }
};

pub const LaunchResourceClass = enum {
    unknown,
    memory_bound,
    balanced,
    compute_weighted,
};

pub const LaunchTileKind = enum {
    none,
    dot_general,
    reduction,
    elementwise_rank2,
};

pub const LaunchReductionKind = enum {
    none,
    sum,
    max,
    min,
};

pub const LaunchTilePlan = struct {
    kind: LaunchTileKind = .none,
    m: u32 = 0,
    n: u32 = 0,
    k: u32 = 0,
    batch: u32 = 1,
    input_dtype: ?gpu_abi.DType = null,
    output_dtype: ?gpu_abi.DType = null,
    input_tile_bytes: u32 = 0,
    output_tile_bytes: u32 = 0,
    scratch_memory_bytes: u32 = 0,
    reduction_kind: LaunchReductionKind = .none,
    reduction_rank: u32 = 0,
    reduction_axis: u32 = 0,
    reduction_extent: u32 = 0,

    pub fn active(self: LaunchTilePlan) bool {
        return self.kind != .none;
    }
};

pub const max_launch_resource_candidates = 8;

pub const LaunchResourceCandidate = struct {
    geometry: gpu_abi.LaunchGeometry = .{},
    score: u32 = std.math.maxInt(u32),
    estimated_static_bytes_per_threadgroup: u64 = 0,
    estimated_element_ops_per_threadgroup: u64 = 0,
    tile: LaunchTilePlan = .{},
};

pub const LaunchResourcePlan = struct {
    format: gpu.ArtifactFormat,
    element_count: u64,
    geometry: gpu_abi.LaunchGeometry,
    subgroup_size: ?u32 = null,
    subgroup_aligned: bool = false,
    fixed_threadgroup: bool = false,
    resource_class: LaunchResourceClass = .unknown,
    element_ops_per_kib: u64 = 0,
    estimated_static_bytes_per_threadgroup: u64 = 0,
    estimated_element_ops_per_threadgroup: u64 = 0,
    static_bytes_complete: bool = false,
    tile: LaunchTilePlan = .{},
    candidate_count: usize = 0,
    candidates: [max_launch_resource_candidates]LaunchResourceCandidate = @as(
        [max_launch_resource_candidates]LaunchResourceCandidate,
        @splat(.{}),
    ),

    pub fn selectedCandidate(self: LaunchResourcePlan) ?LaunchResourceCandidate {
        if (self.candidate_count == 0) return null;
        return self.candidates[0];
    }
};

pub fn createLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
) gpu.BackendError!LaunchResourcePlan {
    const subgroup_size = subgroupSizeFor(caps);
    const fixed_threadgroup = fixedThreadgroupSizeFor(format);
    const resource_class = classifyLaunchResources(resources);
    const candidates = if (fixed_threadgroup) |fixed|
        try fixedLaunchResourceCandidates(caps, format, resources, resource_class, fixed)
    else
        try dynamicLaunchResourceCandidates(caps, format, resources, resource_class, subgroup_size);
    if (candidates.count == 0) return error.CapabilityMismatch;
    const selected = candidates.items[0];
    const plan = LaunchResourcePlan{
        .format = format,
        .element_count = resources.element_count,
        .geometry = selected.geometry,
        .subgroup_size = subgroup_size,
        .subgroup_aligned = if (subgroup_size) |size| blk: {
            const thread_count = try threadgroupThreadCount(selected.geometry);
            break :blk thread_count >= size and thread_count % size == 0;
        } else false,
        .fixed_threadgroup = fixed_threadgroup != null,
        .resource_class = resource_class,
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = selected.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = selected.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .candidate_count = candidates.count,
        .candidates = candidates.items,
    };
    try caps.validateLaunchGeometry(plan.geometry);
    return plan;
}

fn createLaunchResourcePlanForWork(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    work: schedule_planning.ScheduleWorkItem,
    compile_plan: CompilePlan,
) gpu.BackendError!LaunchResourcePlan {
    const plan = switch (compile_plan.launch) {
        .dot_general => |dot| try createDotGeneralLaunchResourcePlan(
            caps,
            format,
            work.resources,
            dot,
            loweredKernelBody(compile_plan),
        ),
        .reduction => |reduction| blk: {
            var resources = work.resources;
            resources.element_count = work.element_count;
            break :blk try createReductionLaunchResourcePlan(
                caps,
                format,
                resources,
                reduction,
                loweredKernelBody(compile_plan),
            );
        },
        .kernel_call => |kernel_call| return createKernelCallLaunchResourcePlan(
            caps,
            format,
            work.resources,
            kernel_call,
        ),
        .generic => blk: {
            switch (loweredKernelBody(compile_plan)) {
                .row_pipeline => |pipeline| break :blk try createFixedLaunchResourcePlan(
                    caps,
                    format,
                    work.resources,
                    .{
                        .grid = .{ pipeline.rows, 1, 1 },
                        .threadgroup = .{ pipeline.threads, 1, 1 },
                    },
                ),
                .flash_attention => |flash| break :blk try createFixedLaunchResourcePlan(
                    caps,
                    format,
                    work.resources,
                    .{
                        .grid = .{ flash.seq / flash.br, 1, 1 },
                        .threadgroup = .{ flash.threads_x, flash.threads_y, 1 },
                    },
                ),
                .scan => |scan_plan| break :blk try createFixedLaunchResourcePlan(
                    caps,
                    format,
                    work.resources,
                    .{
                        .grid = .{ scan_plan.blocks, 1, 1 },
                        .threadgroup = .{ scan_plan.threads, 1, 1 },
                    },
                ),
                .elementwise_rank2 => |rank2| break :blk try createElementwiseRank2LaunchResourcePlan(
                    caps,
                    format,
                    work.resources,
                    rank2,
                ),
                .elementwise_vector => |vector_plan| {
                    var resources = work.resources;
                    resources.element_count = vector_plan.quads;
                    break :blk try createLaunchResourcePlan(caps, format, resources);
                },
                else => {},
            }
            if (fixedThreadgroupSizeFor(format) != null) {
                if (compile_plan.lowered_kernel) |lowered| {
                    if (lowered.launchGeometry()) |geometry| {
                        break :blk try createFixedLaunchResourcePlan(
                            caps,
                            format,
                            work.resources,
                            geometry,
                        );
                    }
                }
            }
            break :blk try createLaunchResourcePlan(caps, format, work.resources);
        },
    };
    return attachGeneratedDynamicSharedMemory(caps, plan, compile_plan);
}

fn createKernelCallLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    launch: KernelCallLaunch,
) gpu.BackendError!LaunchResourcePlan {
    return switch (launch) {
        .derived => |derived| blk: {
            try validateKernelCallDerivedLaunch(derived);
            break :blk createFixedLaunchResourcePlan(caps, format, resources, .{
                .threadgroup = derived.threadgroup,
                .dynamic_shared_memory_bytes = derived.dynamic_shared_memory_bytes,
            });
        },
        .fixed => |geometry| createFixedLaunchResourcePlan(caps, format, resources, geometry),
    };
}

fn createFixedLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    geometry: gpu_abi.LaunchGeometry,
) gpu.BackendError!LaunchResourcePlan {
    try caps.validateLaunchGeometry(geometry);
    const thread_count = try threadgroupThreadCount(geometry);
    const subgroup_size = subgroupSizeFor(caps);
    const resource_class = classifyLaunchResources(resources);
    const candidate = LaunchResourceCandidate{
        .geometry = geometry,
        .score = 0,
        .estimated_static_bytes_per_threadgroup = scaleResourceToThreadgroup(
            resources.static_total_bytes,
            resources.element_count,
            thread_count,
        ),
        .estimated_element_ops_per_threadgroup = scaleResourceToThreadgroup(
            resources.estimated_element_ops,
            resources.element_count,
            thread_count,
        ),
    };
    var candidates = @as([max_launch_resource_candidates]LaunchResourceCandidate, @splat(.{}));
    candidates[0] = candidate;
    return .{
        .format = format,
        .element_count = resources.element_count,
        .geometry = geometry,
        .subgroup_size = subgroup_size,
        .subgroup_aligned = if (subgroup_size) |size|
            thread_count >= size and thread_count % size == 0
        else
            false,
        .fixed_threadgroup = true,
        .resource_class = resource_class,
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = candidate.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = candidate.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .candidate_count = 1,
        .candidates = candidates,
    };
}

fn loweredKernelBody(compile_plan: CompilePlan) kernelization.LoweredKernelBody {
    const lowered = compile_plan.lowered_kernel orelse return .generic;
    return lowered.body;
}

fn attachGeneratedDynamicSharedMemory(
    caps: gpu.BackendCapabilities,
    plan_value: LaunchResourcePlan,
    compile_plan: CompilePlan,
) gpu.BackendError!LaunchResourcePlan {
    const bytes = generatedDynamicSharedMemoryBytes(compile_plan);
    if (bytes == 0) return plan_value;

    var plan = plan_value;
    plan.geometry.dynamic_shared_memory_bytes = bytes;
    try caps.validateLaunchGeometry(plan.geometry);
    var candidate_index: usize = 0;
    while (candidate_index < plan.candidate_count) : (candidate_index += 1) {
        plan.candidates[candidate_index].geometry.dynamic_shared_memory_bytes = bytes;
        try caps.validateLaunchGeometry(plan.candidates[candidate_index].geometry);
    }
    return plan;
}

fn generatedDynamicSharedMemoryBytes(compile_plan: CompilePlan) u32 {
    const lowered = compile_plan.lowered_kernel orelse return 0;
    return lowered.dynamic_shared_memory_bytes;
}

fn createElementwiseRank2LaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    rank2: kernelization.product.ElementwiseRank2Plan,
) gpu.BackendError!LaunchResourcePlan {
    const default_geometry = gpu_abi.LaunchGeometry{
        .grid = .{
            try gridSizeFor(rank2.cols, rank2.threads_x),
            try gridSizeFor(rank2.rows, rank2.threads_y),
            1,
        },
        .threadgroup = .{ rank2.threads_x, rank2.threads_y, 1 },
    };
    if (fixedThreadgroupSizeFor(format) != null) {
        var plan = try createFixedLaunchResourcePlan(caps, format, resources, default_geometry);
        plan.tile = elementwiseRank2TilePlan(rank2);
        plan.candidates[0].tile = plan.tile;
        return plan;
    }

    const resource_class = classifyLaunchResources(resources);
    const subgroup_size = subgroupSizeFor(caps);
    const target_thread_count = try threadgroupThreadCount(default_geometry);
    var candidates = LaunchCandidateBuffer{};
    try appendElementwiseRank2LaunchCandidate(
        &candidates,
        caps,
        resources,
        rank2,
        rank2.threads_x,
        rank2.threads_y,
        target_thread_count,
    );
    for (elementwise_rank2_launch_shapes) |shape| {
        try appendElementwiseRank2LaunchCandidate(
            &candidates,
            caps,
            resources,
            rank2,
            shape.x,
            shape.y,
            target_thread_count,
        );
    }
    if (candidates.count == 0) return error.CapabilityMismatch;

    const selected = candidates.items[0];
    return .{
        .format = format,
        .element_count = resources.element_count,
        .geometry = selected.geometry,
        .subgroup_size = subgroup_size,
        .subgroup_aligned = if (subgroup_size) |size| blk: {
            const thread_count = try threadgroupThreadCount(selected.geometry);
            break :blk thread_count >= size and thread_count % size == 0;
        } else false,
        .fixed_threadgroup = false,
        .resource_class = resource_class,
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = selected.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = selected.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .tile = selected.tile,
        .candidate_count = candidates.count,
        .candidates = candidates.items,
    };
}

const ElementwiseRank2LaunchShape = struct {
    x: u32,
    y: u32,
};

const elementwise_rank2_launch_shapes = [_]ElementwiseRank2LaunchShape{
    .{ .x = 16, .y = 16 },
    .{ .x = 8, .y = 32 },
    .{ .x = 64, .y = 4 },
    .{ .x = 128, .y = 2 },
    .{ .x = 256, .y = 1 },
    .{ .x = 32, .y = 4 },
    .{ .x = 16, .y = 8 },
};

fn appendElementwiseRank2LaunchCandidate(
    candidates: *LaunchCandidateBuffer,
    caps: gpu.BackendCapabilities,
    resources: schedule_planning.ScheduleResourceEstimate,
    rank2: kernelization.product.ElementwiseRank2Plan,
    threads_x: u32,
    threads_y: u32,
    target_thread_count: u32,
) gpu.BackendError!void {
    if (candidates.count >= max_launch_resource_candidates) return;
    if (threads_x == 0 or threads_y == 0) return;
    const geometry = gpu_abi.LaunchGeometry{
        .grid = .{
            try gridSizeFor(rank2.cols, threads_x),
            try gridSizeFor(rank2.rows, threads_y),
            1,
        },
        .threadgroup = .{ threads_x, threads_y, 1 },
    };
    caps.validateLaunchGeometry(geometry) catch |err| switch (err) {
        error.CapabilityMismatch => return,
        else => return err,
    };
    for (candidates.items[0..candidates.count]) |existing| {
        if (sameLaunchGeometry(existing.geometry, geometry)) return;
    }
    const thread_count = try threadgroupThreadCount(geometry);
    candidates.items[candidates.count] = .{
        .geometry = geometry,
        .score = candidateScore(thread_count, target_thread_count),
        .estimated_static_bytes_per_threadgroup = scaleResourceToThreadgroup(
            resources.static_total_bytes,
            resources.element_count,
            thread_count,
        ),
        .estimated_element_ops_per_threadgroup = scaleResourceToThreadgroup(
            resources.estimated_element_ops,
            resources.element_count,
            thread_count,
        ),
        .tile = elementwiseRank2TilePlan(rank2),
    };
    candidates.count += 1;
}

fn elementwiseRank2TilePlan(rank2: kernelization.product.ElementwiseRank2Plan) LaunchTilePlan {
    return .{
        .kind = .elementwise_rank2,
        .m = rank2.rows,
        .n = rank2.cols,
    };
}

fn createDotGeneralLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    dot: DotGeneralLaunchPlan,
    body: kernelization.LoweredKernelBody,
) gpu.BackendError!LaunchResourcePlan {
    if (gpu.artifactFormatUsesHostLoopLaunch(format)) {
        return createDotGeneralHostLoopLaunchResourcePlan(caps, format, resources, dot);
    }
    switch (body) {
        .dot_block_tile => |block_tile| return createDotGeneralBlockTileLaunchResourcePlan(
            caps,
            format,
            resources,
            dot,
            block_tile,
        ),
        .dot_mma_tile => |mma_tile| return createDotGeneralMmaTileLaunchResourcePlan(
            caps,
            format,
            resources,
            dot,
            mma_tile,
        ),
        else => {},
    }
    var candidates = LaunchCandidateBuffer{};
    for (try dotGeneralTileShapes(format), 0..) |shape, index| {
        try appendDotGeneralLaunchCandidate(
            &candidates,
            caps,
            resources,
            dot,
            shape,
            @intCast(index),
        );
    }
    if (candidates.count == 0) return error.CapabilityMismatch;
    const candidate = candidates.items[0];
    return .{
        .format = format,
        .element_count = resources.element_count,
        .geometry = candidate.geometry,
        .fixed_threadgroup = true,
        .resource_class = classifyLaunchResources(resources),
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = candidate.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = candidate.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .tile = candidate.tile,
        .candidate_count = candidates.count,
        .candidates = candidates.items,
    };
}

fn createDotGeneralHostLoopLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    dot: DotGeneralLaunchPlan,
) gpu.BackendError!LaunchResourcePlan {
    const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ try gridSizeFor(resources.element_count, 1), 1, 1 },
        .threadgroup = .{ 1, 1, 1 },
    };
    try caps.validateLaunchGeometry(geometry);
    var candidates = LaunchCandidateBuffer{};
    candidates.items[0] = .{
        .geometry = geometry,
        .score = 0,
        .estimated_static_bytes_per_threadgroup = scaleResourceToThreadgroup(
            resources.static_total_bytes,
            resources.element_count,
            1,
        ),
        .estimated_element_ops_per_threadgroup = scaleResourceToThreadgroup(
            resources.estimated_element_ops,
            resources.element_count,
            1,
        ),
        .tile = try dotGeneralTilePlan(dot, .{ .m = 1, .n = 1 }),
    };
    candidates.count = 1;
    const candidate = candidates.items[0];
    return .{
        .format = format,
        .element_count = resources.element_count,
        .geometry = candidate.geometry,
        .fixed_threadgroup = true,
        .resource_class = classifyLaunchResources(resources),
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = candidate.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = candidate.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .tile = candidate.tile,
        .candidate_count = candidates.count,
        .candidates = candidates.items,
    };
}

fn createDotGeneralBlockTileLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    dot: DotGeneralLaunchPlan,
    block_tile: kernelization.DotGeneralBlockTile,
) gpu.BackendError!LaunchResourcePlan {
    const geometry = gpu_abi.LaunchGeometry{
        .grid = .{
            try gridSizeFor(dot.n, block_tile.bn),
            try gridSizeFor(dot.m, block_tile.bm),
            dot.batch * block_tile.splits,
        },
        .threadgroup = .{ block_tile.threadsX(), block_tile.threadsY(), 1 },
    };
    try caps.validateLaunchGeometry(geometry);
    const thread_count = try threadgroupThreadCount(geometry);
    var candidates = LaunchCandidateBuffer{};
    candidates.items[0] = .{
        .geometry = geometry,
        .score = 0,
        .estimated_static_bytes_per_threadgroup = scaleResourceToThreadgroup(
            resources.static_total_bytes,
            resources.element_count,
            thread_count,
        ),
        .estimated_element_ops_per_threadgroup = scaleResourceToThreadgroup(
            resources.estimated_element_ops,
            resources.element_count,
            thread_count,
        ),
        .tile = try dotGeneralTilePlan(dot, .{ .m = block_tile.bm, .n = block_tile.bn }),
    };
    candidates.count = 1;
    const candidate = candidates.items[0];
    return .{
        .format = format,
        .element_count = resources.element_count,
        .geometry = candidate.geometry,
        .fixed_threadgroup = true,
        .resource_class = classifyLaunchResources(resources),
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = candidate.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = candidate.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .tile = candidate.tile,
        .candidate_count = candidates.count,
        .candidates = candidates.items,
    };
}

fn createDotGeneralMmaTileLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    dot: DotGeneralLaunchPlan,
    mma_tile: kernelization.DotGeneralMmaTile,
) gpu.BackendError!LaunchResourcePlan {
    const geometry = gpu_abi.LaunchGeometry{
        .grid = .{
            try gridSizeFor(dot.n, mma_tile.bn),
            try gridSizeFor(dot.m, mma_tile.bm),
            dot.batch * mma_tile.splits,
        },
        .threadgroup = .{ 32, mma_tile.warps(), 1 },
    };
    try caps.validateLaunchGeometry(geometry);
    const thread_count = try threadgroupThreadCount(geometry);
    var candidates = LaunchCandidateBuffer{};
    candidates.items[0] = .{
        .geometry = geometry,
        .score = 0,
        .estimated_static_bytes_per_threadgroup = scaleResourceToThreadgroup(
            resources.static_total_bytes,
            resources.element_count,
            thread_count,
        ),
        .estimated_element_ops_per_threadgroup = scaleResourceToThreadgroup(
            resources.estimated_element_ops,
            resources.element_count,
            thread_count,
        ),
        .tile = try dotGeneralTilePlan(dot, .{ .m = mma_tile.bm, .n = mma_tile.bn }),
    };
    candidates.count = 1;
    const candidate = candidates.items[0];
    return .{
        .format = format,
        .element_count = resources.element_count,
        .geometry = candidate.geometry,
        .fixed_threadgroup = true,
        .resource_class = classifyLaunchResources(resources),
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = candidate.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = candidate.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .tile = candidate.tile,
        .candidate_count = candidates.count,
        .candidates = candidates.items,
    };
}

fn dotGeneralTilePlan(
    dot: DotGeneralLaunchPlan,
    shape: DotGeneralTileShape,
) gpu.BackendError!LaunchTilePlan {
    return .{
        .kind = .dot_general,
        .m = shape.m,
        .n = shape.n,
        .k = dot.k,
        .batch = dot.batch,
        .input_dtype = dot.input_dtype,
        .output_dtype = dot.output_dtype,
        .input_tile_bytes = try dotGeneralInputTileBytes(shape.m, shape.n, dot.k, dot.input_dtype),
        .output_tile_bytes = try dotGeneralOutputTileBytes(shape.m, shape.n, dot.output_dtype),
    };
}

const DotGeneralTileShape = struct {
    m: u32,
    n: u32,
};

const cuda_dot_general_tile_shapes = [_]DotGeneralTileShape{
    .{ .m = 16, .n = 16 },
    .{ .m = 8, .n = 32 },
    .{ .m = 32, .n = 8 },
    .{ .m = 8, .n = 8 },
};

const vulkan_dot_general_tile_shapes = [_]DotGeneralTileShape{
    .{ .m = 8, .n = 8 },
    .{ .m = 8, .n = 16 },
    .{ .m = 16, .n = 8 },
    .{ .m = 16, .n = 16 },
};

const metal_dot_general_tile_shapes = [_]DotGeneralTileShape{
    .{ .m = 8, .n = 8 },
    .{ .m = 8, .n = 16 },
    .{ .m = 16, .n = 8 },
    .{ .m = 16, .n = 16 },
};

fn dotGeneralTileShapes(format: gpu.ArtifactFormat) gpu.BackendError![]const DotGeneralTileShape {
    return switch (format) {
        .cuda_ptx => &cuda_dot_general_tile_shapes,
        .vulkan_spirv => &vulkan_dot_general_tile_shapes,
        .metal_msl => &metal_dot_general_tile_shapes,
        else => error.UnsupportedArtifactFormat,
    };
}

fn appendDotGeneralLaunchCandidate(
    candidates: *LaunchCandidateBuffer,
    caps: gpu.BackendCapabilities,
    resources: schedule_planning.ScheduleResourceEstimate,
    dot: DotGeneralLaunchPlan,
    shape: DotGeneralTileShape,
    score: u32,
) gpu.BackendError!void {
    if (candidates.count >= max_launch_resource_candidates) return;
    const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ try gridSizeFor(dot.n, shape.n), try gridSizeFor(dot.m, shape.m), dot.batch },
        .threadgroup = .{ shape.n, shape.m, 1 },
    };
    caps.validateLaunchGeometry(geometry) catch |err| switch (err) {
        error.CapabilityMismatch => return,
        else => return err,
    };
    for (candidates.items[0..candidates.count]) |existing| {
        if (sameLaunchGeometry(existing.geometry, geometry)) return;
    }
    const thread_count = try threadgroupThreadCount(geometry);
    candidates.items[candidates.count] = .{
        .geometry = geometry,
        .score = score,
        .estimated_static_bytes_per_threadgroup = scaleResourceToThreadgroup(
            resources.static_total_bytes,
            resources.element_count,
            thread_count,
        ),
        .estimated_element_ops_per_threadgroup = scaleResourceToThreadgroup(
            resources.estimated_element_ops,
            resources.element_count,
            thread_count,
        ),
        .tile = try dotGeneralTilePlan(dot, shape),
    };
    candidates.count += 1;
}

fn dotGeneralInputTileBytes(
    m: u32,
    n: u32,
    k: u32,
    dtype: gpu_abi.DType,
) gpu.BackendError!u32 {
    const lhs_elements = std.math.mul(u32, m, k) catch return error.CapabilityMismatch;
    const rhs_elements = std.math.mul(u32, k, n) catch return error.CapabilityMismatch;
    const elements = std.math.add(
        u32,
        lhs_elements,
        rhs_elements,
    ) catch return error.CapabilityMismatch;
    return std.math.mul(u32, elements, @as(
        u32,
        dtype.sizeOf(),
    )) catch return error.CapabilityMismatch;
}

fn dotGeneralOutputTileBytes(
    m: u32,
    n: u32,
    dtype: gpu_abi.DType,
) gpu.BackendError!u32 {
    const elements = std.math.mul(u32, m, n) catch return error.CapabilityMismatch;
    return std.math.mul(u32, elements, @as(
        u32,
        dtype.sizeOf(),
    )) catch return error.CapabilityMismatch;
}

fn createReductionLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    reduction: ReductionLaunchPlan,
    body: kernelization.LoweredKernelBody,
) gpu.BackendError!LaunchResourcePlan {
    try validateReductionLaunchPlan(resources, reduction);
    switch (body) {
        .reduction_atomic => |atomic_plan| return createFixedGeometryReductionLaunchResourcePlan(
            caps,
            format,
            resources,
            reduction,
            .{
                .grid = .{ atomic_plan.blocks, 1, 1 },
                .threadgroup = .{ atomic_plan.threads, 1, 1 },
            },
        ),
        .reduction_single_block => |threads| return createFixedGeometryReductionLaunchResourcePlan(
            caps,
            format,
            resources,
            reduction,
            .{
                .grid = .{ 1, 1, 1 },
                .threadgroup = .{ threads, 1, 1 },
            },
        ),
        .reduction_warp_rows => |warp_plan| {
            const lanes = std.math.mul(
                u32,
                warp_plan.rows,
                32,
            ) catch return error.CapabilityMismatch;
            return createFixedGeometryReductionLaunchResourcePlan(
                caps,
                format,
                resources,
                reduction,
                .{
                    .grid = .{ (lanes + warp_plan.threads - 1) / warp_plan.threads, 1, 1 },
                    .threadgroup = .{ warp_plan.threads, 1, 1 },
                },
            );
        },
        else => {},
    }
    var plan = try createLaunchResourcePlan(caps, format, resources);
    var kept: usize = 0;
    var candidate_index: usize = 0;
    while (candidate_index < plan.candidate_count) : (candidate_index += 1) {
        const tile = reductionTilePlan(
            reduction,
            plan.candidates[candidate_index].geometry.threadgroup[0],
        ) catch |err| switch (err) {
            error.CapabilityMismatch => continue,
            else => return err,
        };
        plan.candidates[kept] = plan.candidates[candidate_index];
        plan.candidates[kept].tile = tile;
        kept += 1;
    }
    if (kept == 0) return error.CapabilityMismatch;
    plan.candidate_count = kept;
    plan.geometry = plan.candidates[0].geometry;
    plan.tile = plan.candidates[0].tile;
    return plan;
}

fn createFixedGeometryReductionLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    reduction: ReductionLaunchPlan,
    geometry: gpu_abi.LaunchGeometry,
) gpu.BackendError!LaunchResourcePlan {
    try caps.validateLaunchGeometry(geometry);
    var candidates = LaunchCandidateBuffer{};
    candidates.items[0] = .{
        .geometry = geometry,
        .score = 0,
        .estimated_static_bytes_per_threadgroup = resources.static_total_bytes,
        .estimated_element_ops_per_threadgroup = resources.estimated_element_ops,
        .tile = try reductionTilePlan(reduction, 1),
    };
    candidates.count = 1;
    const candidate = candidates.items[0];
    return .{
        .format = format,
        .element_count = resources.element_count,
        .geometry = candidate.geometry,
        .fixed_threadgroup = true,
        .resource_class = classifyLaunchResources(resources),
        .element_ops_per_kib = resources.elementOpsPerKiB(),
        .estimated_static_bytes_per_threadgroup = candidate.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = candidate.estimated_element_ops_per_threadgroup,
        .static_bytes_complete = resources.static_bytes_complete,
        .tile = candidate.tile,
        .candidate_count = candidates.count,
        .candidates = candidates.items,
    };
}

fn validateReductionLaunchPlan(
    resources: schedule_planning.ScheduleResourceEstimate,
    reduction: ReductionLaunchPlan,
) gpu.BackendError!void {
    if (resources.element_count != @as(u64, reduction.output_element_count)) {
        return error.InvalidArtifact;
    }
    const covered_elements = std.math.mul(
        u32,
        reduction.output_element_count,
        reduction.reduction_extent,
    ) catch return error.CapabilityMismatch;
    if (covered_elements != reduction.input_element_count) return error.InvalidArtifact;
}

fn reductionTilePlan(
    reduction: ReductionLaunchPlan,
    output_tile_elements: u32,
) gpu.BackendError!LaunchTilePlan {
    return .{
        .kind = .reduction,
        .m = output_tile_elements,
        .n = reduction.reduction_extent,
        .k = @intCast(reduction.axis),
        .batch = 1,
        .input_dtype = reduction.input_dtype,
        .output_dtype = reduction.output_dtype,
        .input_tile_bytes = try reductionInputTileBytes(
            output_tile_elements,
            reduction.reduction_extent,
            reduction.input_dtype,
        ),
        .output_tile_bytes = try reductionOutputTileBytes(
            output_tile_elements,
            reduction.output_dtype,
        ),
        .reduction_kind = reduction.kind,
        .reduction_rank = @intCast(reduction.input_rank),
        .reduction_axis = @intCast(reduction.axis),
        .reduction_extent = reduction.reduction_extent,
    };
}

fn reductionInputTileBytes(
    output_tile_elements: u32,
    reduction_extent: u32,
    dtype: gpu_abi.DType,
) gpu.BackendError!u32 {
    const elements = std.math.mul(
        u32,
        output_tile_elements,
        reduction_extent,
    ) catch return error.CapabilityMismatch;
    return std.math.mul(u32, elements, @as(
        u32,
        dtype.sizeOf(),
    )) catch return error.CapabilityMismatch;
}

fn reductionOutputTileBytes(
    output_tile_elements: u32,
    dtype: gpu_abi.DType,
) gpu.BackendError!u32 {
    return std.math.mul(
        u32,
        output_tile_elements,
        @as(u32, dtype.sizeOf()),
    ) catch return error.CapabilityMismatch;
}

fn threadgroupThreadCount(geometry: gpu_abi.LaunchGeometry) gpu.BackendError!u32 {
    const xy = std.math.mul(
        u32,
        geometry.threadgroup[0],
        geometry.threadgroup[1],
    ) catch return error.CapabilityMismatch;
    return std.math.mul(u32, xy, geometry.threadgroup[2]) catch return error.CapabilityMismatch;
}

pub fn createBackendMemoryPlan(
    allocator: std.mem.Allocator,
    artifact_plan: *const BackendArtifactPlan,
) !BackendMemoryPlan {
    const lifetimes = try allocator.alloc(BackendSlotLifetime, artifact_plan.slots.len);
    errdefer allocator.free(lifetimes);
    for (artifact_plan.slots, 0..) |slot, index| {
        lifetimes[index] = .{
            .slot_id = slot.slot_id,
            .role = slot.role,
            .dtype = slot.dtype,
            .memory_space = slot.memory_space,
            .layout_kind = slot.layout_kind,
            .element_count = slot.element_count,
            .byte_size = slot.byte_size,
            .alignment = slot.alignment,
            .layout_fingerprint = slot.layout_fingerprint,
        };
    }

    for (artifact_plan.kernels.items, 0..) |kernel, kernel_index| {
        try recordSlotLifetimeUse(lifetimes, kernel.output_slot_id, kernel_index);
        for (kernel.input_slot_ids) |slot_id| {
            try recordSlotLifetimeUse(lifetimes, slot_id, kernel_index);
        }
    }

    const end_index = artifact_plan.kernels.items.len;
    for (artifact_plan.output_slot_ids) |slot_id| {
        const lifetime = lifetimeForSlot(lifetimes, slot_id) orelse return error.InvalidArtifact;
        if (lifetime.hasKernelUse()) {
            lifetime.last_kernel_index = @max(lifetime.last_kernel_index, end_index);
        }
    }

    var allocation_list: std.ArrayListUnmanaged(BackendBufferAllocationPlan) = .empty;
    errdefer allocation_list.deinit(allocator);
    var assignment_list: std.ArrayListUnmanaged(BackendBufferReuseAssignment) = .empty;
    errdefer assignment_list.deinit(allocator);
    var candidate_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer candidate_indices.deinit(allocator);

    var total_static_slot_bytes: u64 = 0;
    for (lifetimes, 0..) |lifetime, index| {
        if (!lifetime.isBackendAllocatable()) continue;
        total_static_slot_bytes += lifetime.byte_size.?;
        try candidate_indices.append(allocator, index);
    }
    std.mem.sort(usize, candidate_indices.items, lifetimes, lessLifetimeIndex);

    var allocated_static_bytes: u64 = 0;
    for (candidate_indices.items) |lifetime_index| {
        const lifetime = lifetimes[lifetime_index];
        const allocation_index = reusableAllocationIndex(allocation_list.items, lifetime) orelse
            blk: {
                const allocation_id = allocation_list.items.len;
                const allocation = BackendBufferAllocationPlan{
                    .allocation_id = allocation_id,
                    .byte_size = lifetime.byte_size.?,
                    .dtype = lifetime.dtype,
                    .memory_space = lifetime.memory_space,
                    .layout_kind = lifetime.layout_kind,
                    .element_count = lifetime.element_count,
                    .alignment = lifetime.alignment,
                    .layout_fingerprint = lifetime.layout_fingerprint,
                    .last_kernel_index = lifetime.last_kernel_index,
                };
                try allocation_list.append(allocator, allocation);
                allocated_static_bytes += allocation.byte_size;
                break :blk allocation_id;
            };
        allocation_list.items[allocation_index].last_kernel_index = lifetime.last_kernel_index;
        try assignment_list.append(allocator, .{
            .slot_id = lifetime.slot_id,
            .allocation_id = allocation_list.items[allocation_index].allocation_id,
        });
    }

    const allocations = try allocation_list.toOwnedSlice(allocator);
    errdefer if (allocations.len != 0) allocator.free(allocations);
    const assignments = try assignment_list.toOwnedSlice(allocator);
    errdefer if (assignments.len != 0) allocator.free(assignments);

    return .{
        .allocator = allocator,
        .lifetimes = lifetimes,
        .allocations = allocations,
        .assignments = assignments,
        .total_static_slot_bytes = total_static_slot_bytes,
        .allocated_static_bytes = allocated_static_bytes,
        .peak_static_live_bytes = peakStaticLiveBytes(lifetimes, end_index),
    };
}

fn recordSlotLifetimeUse(
    lifetimes: []BackendSlotLifetime,
    slot_id: usize,
    kernel_index: usize,
) !void {
    const lifetime = lifetimeForSlot(lifetimes, slot_id) orelse return error.InvalidArtifact;
    if (!lifetime.hasKernelUse()) {
        lifetime.first_kernel_index = kernel_index;
        lifetime.last_kernel_index = kernel_index;
        return;
    }
    lifetime.first_kernel_index = @min(lifetime.first_kernel_index, kernel_index);
    lifetime.last_kernel_index = @max(lifetime.last_kernel_index, kernel_index);
}

fn lifetimeForSlot(
    lifetimes: []BackendSlotLifetime,
    slot_id: usize,
) ?*BackendSlotLifetime {
    if (slot_id < lifetimes.len and lifetimes[slot_id].slot_id == slot_id) {
        return &lifetimes[slot_id];
    }
    for (lifetimes) |*lifetime| {
        if (lifetime.slot_id == slot_id) return lifetime;
    }
    return null;
}

fn lessLifetimeIndex(
    lifetimes: []BackendSlotLifetime,
    lhs_index: usize,
    rhs_index: usize,
) bool {
    const lhs = lifetimes[lhs_index];
    const rhs = lifetimes[rhs_index];
    if (lhs.first_kernel_index != rhs.first_kernel_index) {
        return lhs.first_kernel_index < rhs.first_kernel_index;
    }
    return lhs.slot_id < rhs.slot_id;
}

fn reusableAllocationIndex(
    allocations: []const BackendBufferAllocationPlan,
    lifetime: BackendSlotLifetime,
) ?usize {
    for (allocations, 0..) |allocation, index| {
        if (allocation.last_kernel_index >= lifetime.first_kernel_index) continue;
        if (allocation.byte_size != lifetime.byte_size.?) continue;
        if (allocation.dtype != lifetime.dtype) continue;
        if (allocation.memory_space != lifetime.memory_space) continue;
        if (allocation.layout_kind != lifetime.layout_kind) continue;
        if (allocation.element_count != lifetime.element_count) continue;
        if (allocation.alignment != lifetime.alignment) continue;
        if (allocation.layout_fingerprint != lifetime.layout_fingerprint) continue;
        return index;
    }
    return null;
}

fn peakStaticLiveBytes(lifetimes: []const BackendSlotLifetime, end_index: usize) u64 {
    var peak: u64 = 0;
    for (0..end_index + 1) |kernel_index| {
        var live: u64 = 0;
        for (lifetimes) |lifetime| {
            if (!lifetime.isBackendAllocatable()) continue;
            if (lifetime.first_kernel_index > kernel_index) continue;
            if (lifetime.last_kernel_index < kernel_index) continue;
            live += lifetime.byte_size.?;
        }
        peak = @max(peak, live);
    }
    return peak;
}

pub fn createBackendArtifactPlan(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    source: BackendArtifactPlanSource,
    options: ArtifactPlanOptions,
) !BackendArtifactPlan {
    const pass_ctx = source.pass_ctx;
    const choir_module = source.choir_module;
    const schedule_plan = try schedule_planning.getSchedulePlanAnalysis(pass_ctx, choir_module);
    const buffer_plan = try bufferization.getBufferPlanAnalysis(pass_ctx, choir_module);
    const memory_plan = try memory_space.getMemorySpacePlanAnalysis(pass_ctx, choir_module);
    const layout_plan = try layout_planning.getLayoutPlanAnalysis(pass_ctx, choir_module);
    const outline_plan = try kernel_outlining.getKernelOutlinePlanAnalysis(pass_ctx, choir_module);
    const legal_plan = try backend_legalization.getBackendLegalizationAnalysis(
        pass_ctx,
        choir_module,
    );

    return createFromPlans(allocator, handle, .{
        .root = choir_module,
        .profile = target_profile.readBackendTargetProfile(choir_module),
        .schedule = schedule_plan,
        .buffers = buffer_plan,
        .spaces = memory_plan,
        .layouts = layout_plan,
        .outlines = outline_plan,
        .generated = source.lowered_kernels,
        .legal = legal_plan,
    }, options);
}

pub const PlanInputs = struct {
    root: *ir.Operation,
    profile: ?preparation.BackendTargetProfile,
    schedule: *const schedule_planning.SchedulePlanAnalysis,
    buffers: *const bufferization.BufferPlanAnalysis,
    spaces: *const memory_space.MemorySpacePlanAnalysis,
    layouts: *const layout_planning.LayoutPlanAnalysis,
    outlines: *const kernelization_model.KernelOutlinePlanAnalysis,
    generated: *const kernelization.KernelizationAnalysis,
    legal: *const backend_legalization.BackendLegalizationAnalysis,
    target: ?*const accy_choir.record.target.Record = null,
};

fn createFromPlans(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    source: PlanInputs,
    options: ArtifactPlanOptions,
) !BackendArtifactPlan {
    const caps = try handle.queryCapabilities();
    const existing_profile = source.profile;
    const backend_kind = handle.backendKind() orelse caps.identity.backend;
    const format = options.format orelse
        if (existing_profile) |profile| profile.artifact_format else defaultArtifactFormat(
            backend_kind,
        ) orelse {
            return error.UnsupportedOperation;
        };
    if (!caps.supportsArtifactFormat(format)) return error.UnsupportedArtifactFormat;
    const profile = try selectedBackendTargetProfile(caps, backend_kind, format, existing_profile);

    const choir_module = source.root;
    const schedule_plan = source.schedule;
    const buffer_plan = source.buffers;
    const memory_plan = source.spaces;
    const layout_plan = source.layouts;
    const outline_plan = source.outlines;
    const legal_plan = source.legal;
    if (source.target != null and (existing_profile == null or
        existing_profile.?.artifact_format != format)) return error.TargetRecipeMismatch;

    var plan = BackendArtifactPlan.init(allocator, profile);
    errdefer plan.deinit();
    try plan.setSlots(buffer_plan, memory_plan, layout_plan, choir_module);

    for (outline_plan.kernels.items) |outline| {
        const legal = legalizationForKernel(legal_plan, outline.id) orelse {
            return error.MissingKernelLegalization;
        };
        if (!legal.isLegal()) return backend_legalization.backendKernelStatusError(legal.status);

        const work = workItemById(schedule_plan, outline.work_item_id) orelse {
            return error.MissingScheduleWorkItem;
        };
        var compile_plan = try compilePlanForWork(
            allocator,
            format,
            outline,
            work.*,
            buffer_plan,
            source.generated,
            options.kernel_call_registry,
            source.target,
        );
        defer compile_plan.deinit(allocator);

        const element_count_argument = try elementCountArgumentForWork(
            format,
            work.*,
            compile_plan,
        );
        const element_count_argument_value = elementCountArgumentValueForWork(work.*, compile_plan);
        const launch_resources = try createLaunchResourcePlanForWork(
            caps,
            format,
            work.*,
            compile_plan,
        );

        const required_dtypes = requiredDTypesForCompilePlan(work.dtype, &compile_plan);
        var compile = try PlannedKernelCompileContract.init(
            allocator,
            plannedCompileSource(compile_plan),
            plannedCompileLaunch(compile_plan),
            format,
            compile_plan.entry_name,
            compile_plan.argument_count,
            required_dtypes,
            compile_plan.required_features,
            compile_plan.required_subgroup,
            compile_plan.shape_family_fingerprint,
            compile_plan.payload,
        );
        var compile_owned = true;
        errdefer if (compile_owned) compile.deinit(allocator);

        const artifact = try createKernelArtifactFromCompilePlan(
            handle,
            format,
            &compile_plan,
            outline.name,
            required_dtypes,
            compile_plan.required_features,
            compile_plan.required_subgroup,
        );

        compile_owned = false;
        try plan.addKernel(
            outline,
            work.resources,
            legal,
            artifact,
            launch_resources,
            kernelCallLaunchForCompilePlan(compile_plan),
            element_count_argument,
            element_count_argument_value,
            compile_plan.runtime_scalar_argument_count,
            compile_plan.runtime_scalar_defaults,
            compile_plan.static_arguments,
            compile,
            outputFillPatternForCompilePlan(compile_plan),
            scratchFillPatternForCompilePlan(compile_plan),
        );
    }

    return plan;
}

fn scratchFillPatternForCompilePlan(compile_plan: CompilePlan) ?u32 {
    const lowered = compile_plan.lowered_kernel orelse return null;
    return lowered.scratch_fill_pattern;
}

fn outputFillPatternForCompilePlan(compile_plan: CompilePlan) ?u32 {
    const lowered = compile_plan.lowered_kernel orelse return null;
    return lowered.output_fill_pattern;
}

pub fn createBackendArtifactPlanFromTargetJob(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    target_module: *target_product.TargetJob,
    options: ArtifactPlanOptions,
) !BackendArtifactPlan {
    var pass_ctx = target_module.passContext();
    defer pass_ctx.deinit();
    return try createBackendArtifactPlan(
        allocator,
        handle,
        .{
            .pass_ctx = &pass_ctx,
            .choir_module = target_module.choir_module,
            .lowered_kernels = target_module.kernelizationProduct(),
        },
        options,
    );
}

fn requiredDTypesForCompilePlan(
    work_dtype: gpu_abi.DType,
    compile_plan: *const CompilePlan,
) gpu.DTypeSet {
    var dtypes = gpu.DTypeSet.init(&.{work_dtype});
    dtypes.bits |= compile_plan.required_dtypes.bits;
    if (compile_plan.lowered_kernel) |lowered| {
        const lowered_dtypes = lowered.requiredDTypes();
        dtypes.bits |= lowered_dtypes.bits;
    }
    return dtypes;
}

fn requiredDTypesForKernelCallArtifact(
    artifact: KernelCallArtifact,
    work: schedule_planning.ScheduleWorkItem,
    outline: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError!gpu.DTypeSet {
    var dtypes = artifact.required_dtypes;
    dtypes.insert(work.dtype);
    for (outline.input_slot_ids) |slot_id| {
        const slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        dtypes.insert(slot.dtype);
    }
    return dtypes;
}

fn bufferSlotById(
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    slot_id: usize,
) ?*const bufferization.BufferSlot {
    if (slot_id < buffer_plan.slots.items.len and buffer_plan.slots.items[slot_id].id == slot_id) {
        return &buffer_plan.slots.items[slot_id];
    }
    for (buffer_plan.slots.items) |*slot| {
        if (slot.id == slot_id) return slot;
    }
    return null;
}

fn plannedCompileLaunch(compile_plan: CompilePlan) PlannedKernelCompileLaunch {
    return switch (compile_plan.launch) {
        .generic => .generic,
        .dot_general => .dot_general,
        .reduction => .reduction,
        .kernel_call => .kernel_call,
    };
}

fn plannedCompileSource(compile_plan: CompilePlan) PlannedKernelSource {
    return switch (compile_plan.launch) {
        .kernel_call => .kernel_call,
        else => .tensor,
    };
}

fn kernelCallLaunchForCompilePlan(compile_plan: CompilePlan) ?KernelCallLaunch {
    return switch (compile_plan.launch) {
        .kernel_call => |launch| launch,
        else => null,
    };
}

fn compilePayloadKind(payload: gpu.CompilePayload) PlannedKernelCompilePayload {
    return switch (payload) {
        .none => .none,
        .bytes => .bytes,
        .words_u32 => .words_u32,
        .text => .text,
    };
}

fn compilePayloadByteCount(payload: gpu.CompilePayload) gpu.BackendError!usize {
    return switch (payload) {
        .none => 0,
        .bytes => |bytes| bytes.len,
        .words_u32 => |words| std.math.mul(usize, words.len, @sizeOf(
            u32,
        )) catch return error.CapabilityMismatch,
        .text => |text| text.len,
    };
}

fn collectInputSlotIds(
    allocator: std.mem.Allocator,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) ![]usize {
    var slot_ids: std.ArrayListUnmanaged(usize) = .empty;
    errdefer slot_ids.deinit(allocator);
    for (buffer_plan.slots.items) |slot| {
        if (!slot.role.input) continue;
        try slot_ids.append(allocator, slot.id);
    }
    return try slot_ids.toOwnedSlice(allocator);
}

fn collectOutputSlotIds(
    allocator: std.mem.Allocator,
    choir_module: *ir.Operation,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) ![]usize {
    var slot_ids: std.ArrayListUnmanaged(usize) = .empty;
    errdefer slot_ids.deinit(allocator);
    try appendReturnSlotIds(allocator, choir_module, buffer_plan, &slot_ids);
    return try slot_ids.toOwnedSlice(allocator);
}

fn appendReturnSlotIds(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    slot_ids: *std.ArrayListUnmanaged(usize),
) !void {
    if (isReturnOp(op)) {
        for (op.getOperandValues()) |value| {
            const slot = buffer_plan.getSlot(value) orelse return error.UnsupportedOperation;
            try slot_ids.append(allocator, slot.id);
        }
    }

    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                try appendReturnSlotIds(allocator, current_op, buffer_plan, slot_ids);
                current = current_op.next_op;
            }
        }
    }
}

fn isReturnOp(op: *ir.Operation) bool {
    return isName(op.name.name, "func.return") or
        isName(op.name.name, dialect_mod.AccyDialect.ReturnOp.operation_name);
}

fn isKernelCallOp(op: *ir.Operation) bool {
    return isName(op.name.name, dialect_mod.AccyDialect.KernelCallOp.operation_name);
}

fn isName(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

fn constantPayloadForSlot(
    allocator: std.mem.Allocator,
    slot: bufferization.BufferSlot,
) ![]u8 {
    if (!slot.role.constant) return &.{};
    const producer = slot.producer orelse return error.InvalidArtifact;
    if (!isName(producer.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        return error.InvalidArtifact;
    }
    const attr = producer.getAttr("payload") orelse return error.InvalidArtifact;
    if (!std.mem.eql(
        u8,
        attr.abstract.name,
        dialect_mod.AccyDialect.ConstantOp.payload_attr_name,
    )) {
        return error.InvalidArtifact;
    }
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return error.InvalidArtifact;
    if (slot.byte_size) |byte_size| {
        const expected = std.math.cast(usize, byte_size) orelse return error.InvalidArtifact;
        if (dialect_attr.payload.len != expected) return error.InvalidArtifact;
    }
    return try allocator.dupe(u8, dialect_attr.payload);
}

fn layoutFingerprint(
    space: memory_space.MemorySpace,
    kind: layout_planning.LayoutKind,
    dims: []const i64,
    element_strides: ?[]const u64,
    minor_to_major: []const usize,
    alignment: u64,
    contiguous: bool,
    static_layout: bool,
) u64 {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes("accy.artifact.layout");
    builder.updateEnumTag(space);
    builder.updateEnumTag(kind);
    builder.updateI64Slice(dims);
    builder.updateOptionalU64Slice(element_strides);
    builder.updateUsizeSlice(minor_to_major);
    builder.updateU64(alignment);
    builder.updateBool(contiguous);
    builder.updateBool(static_layout);
    return builder.finish();
}

fn selectedBackendTargetProfile(
    caps: gpu.BackendCapabilities,
    backend_kind: gpu.BackendKind,
    format: gpu.ArtifactFormat,
    existing: ?target_profile.BackendTargetProfile,
) gpu.BackendError!target_profile.BackendTargetProfile {
    const profile = existing orelse
        try target_profile.BackendTargetProfile.init(caps, backend_kind, format);
    if (profile.backend_kind != backend_kind) return error.CapabilityMismatch;
    if (profile.artifact_format != format) return error.UnsupportedArtifactFormat;
    if (!caps.supportsArtifactFormat(profile.artifact_format)) {
        return error.UnsupportedArtifactFormat;
    }
    if (!profile.isSupportedBy(caps)) return error.CapabilityMismatch;
    return profile;
}

fn legalizationForKernel(
    legal_plan: *const backend_legalization.BackendLegalizationAnalysis,
    kernel_id: usize,
) ?backend_legalization.BackendKernelLegalization {
    for (legal_plan.kernels.items) |legal| {
        if (legal.kernel_id == kernel_id) return legal;
    }
    return null;
}

fn workItemById(
    schedule_plan: *const schedule_planning.SchedulePlanAnalysis,
    work_item_id: usize,
) ?*const schedule_planning.ScheduleWorkItem {
    if (work_item_id < schedule_plan.work_items.items.len) {
        const work = &schedule_plan.work_items.items[work_item_id];
        if (work.id == work_item_id) return work;
    }
    for (schedule_plan.work_items.items) |*work| {
        if (work.id == work_item_id) return work;
    }
    return null;
}

fn compilePlanForWork(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    kernelization_plan: *const kernelization.KernelizationAnalysis,
    kernel_call_registry: ?*const KernelCallRegistry,
    captured: ?*const accy_choir.record.target.Record,
) gpu.BackendError!CompilePlan {
    if (outline.kind == .kernel_call) {
        return try compilePlanFromKernelCall(
            allocator,
            format,
            outline,
            work,
            buffer_plan,
            kernel_call_registry,
        );
    }

    if (format == .cuda_ptx or format == .vulkan_spirv or format == .metal_msl or
        format == .webgpu_wgsl or gpu.artifactFormatUsesHostLoopLaunch(format))
    {
        if (kernelization_plan.getForWork(work.id)) |lowered| {
            var compile_plan = if (captured) |record|
                try compilePlanFromCapturedKernel(allocator, format, lowered, work, record)
            else
                try compilePlanFromLoweredKernel(allocator, format, lowered, work);
            errdefer compile_plan.deinit(allocator);
            compile_plan.launch = try compileLaunchPlanForWork(outline, work, buffer_plan);
            return compile_plan;
        }
        return kernelizationMissError(outline, work, buffer_plan);
    }

    return error.UnsupportedOperation;
}

fn compilePlanFromKernelCall(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    kernel_call_registry: ?*const KernelCallRegistry,
) gpu.BackendError!CompilePlan {
    const registry = kernel_call_registry orelse return error.UnsupportedOperation;
    if (work.ops.len != 1 or work.ops[0] != work.root) return error.InvalidArtifact;
    if (!isKernelCallOp(work.root)) return error.InvalidArtifact;

    const target = try kernelCallTarget(work.root);
    const version = try kernelCallVersion(work.root);
    const artifact = registry.find(target, version, format) orelse
        return error.UnsupportedOperation;
    try validateKernelCallArtifact(format, artifact);

    const payload = try duplicateCompilePayload(allocator, artifact.payload);
    errdefer deinitCompilePayload(allocator, payload);

    const explicit_scalars = dialect_mod.AccyDialect.kernelCallRuntimeScalars(work.root) catch {
        return error.InvalidArtifact;
    };
    var runtime_scalar_defaults = try kernelCallRuntimeScalarDefaults(
        allocator,
        artifact,
        explicit_scalars,
    );
    errdefer if (runtime_scalar_defaults.len != 0) allocator.free(runtime_scalar_defaults);

    const static_arguments = allocator.dupe(
        gpu_abi.ScalarArgument,
        artifact.static_arguments,
    ) catch return error.OutOfMemory;
    errdefer if (static_arguments.len != 0) allocator.free(static_arguments);

    const expected_argument_count = try expectedKernelCallArgumentCount(
        outline,
        artifact.element_count_argument,
        artifact.runtime_scalar_argument_count,
        artifact.static_arguments.len,
    );
    if (artifact.argument_count != expected_argument_count) return error.InvalidArtifact;

    var element_count_argument = artifact.element_count_argument;
    var runtime_scalar_argument_count = artifact.runtime_scalar_argument_count;
    var launch = artifact.launch;
    if (explicit_scalars == null and kernelCallCountScalarIsElementCount(artifact)) {
        if (gpu.artifactFormatUsesHostLoopLaunch(format)) {
            element_count_argument = .scalar_u32;
            runtime_scalar_argument_count = 0;
            launch = try resolveKernelCallLaunchForElementCount(
                artifact.launch,
                work.element_count,
            );
            const geometry = switch (launch) {
                .fixed => |fixed| fixed,
                .derived => return error.InvalidArtifact,
            };
            const shape_count = gpu_abi.launch_shape_argument_count;
            if (static_arguments.len < shape_count) return error.InvalidArtifact;
            const shape_arguments = try gpu_abi.launchShapeArguments(
                allocator,
                work.element_count,
                geometry,
            );
            defer allocator.free(shape_arguments);
            @memcpy(static_arguments[static_arguments.len - shape_count ..], shape_arguments);
        } else {
            if (work.element_count > std.math.maxInt(u32)) return error.LaunchArgumentMismatch;
            const count_default = allocator.alloc(
                gpu_abi.ScalarArgument,
                1,
            ) catch return error.OutOfMemory;
            count_default[0] = .{ .u32 = @intCast(work.element_count) };
            runtime_scalar_defaults = count_default;
        }
    }

    return .{
        .entry_name = artifact.entry_name,
        .argument_count = artifact.argument_count,
        .payload = payload,
        .launch = .{ .kernel_call = launch },
        .required_dtypes = try requiredDTypesForKernelCallArtifact(
            artifact,
            work,
            outline,
            buffer_plan,
        ),
        .required_features = artifact.required_features,
        .required_subgroup = artifact.required_subgroup,
        .push_constants = artifact.push_constants,
        .shape_family_fingerprint = artifact.shape_family_fingerprint,
        .element_count_argument = element_count_argument,
        .runtime_scalar_argument_count = runtime_scalar_argument_count,
        .runtime_scalar_defaults = runtime_scalar_defaults,
        .static_arguments = static_arguments,
    };
}

fn kernelCallRuntimeScalarDefaults(
    allocator: std.mem.Allocator,
    artifact: KernelCallArtifact,
    explicit_scalars: ?dialect_mod.AccyDialect.KernelCallRuntimeScalars,
) gpu.BackendError![]gpu_abi.ScalarArgument {
    const scalars = explicit_scalars orelse return &.{};
    if (scalars.count != artifact.runtime_scalar_argument_count) return error.InvalidArtifact;
    const defaults = allocator.alloc(
        gpu_abi.ScalarArgument,
        scalars.count,
    ) catch return error.OutOfMemory;
    for (scalars.slice(), 0..) |scalar, index| {
        defaults[index] = backendScalarFromKernelCallScalar(scalar);
    }
    return defaults;
}

fn backendScalarFromKernelCallScalar(
    scalar: dialect_mod.AccyDialect.KernelCallScalar,
) gpu_abi.ScalarArgument {
    return switch (scalar.kind) {
        .i32 => .{ .i32 = @bitCast(@as(u32, @truncate(scalar.bits))) },
        .u32 => .{ .u32 = @truncate(scalar.bits) },
        .i64 => .{ .i64 = @bitCast(scalar.bits) },
        .u64 => .{ .u64 = scalar.bits },
        .f32 => .{ .f32 = @bitCast(@as(u32, @truncate(scalar.bits))) },
        .f64 => .{ .f64 = @bitCast(scalar.bits) },
    };
}

fn kernelCallCountScalarIsElementCount(artifact: KernelCallArtifact) bool {
    if (artifact.runtime_scalar_argument_count != 1) return false;
    if (artifact.element_count_argument != .none) return false;
    const shape_profile = artifact.shape_profile orelse return false;
    if (shape_profile.dimensions.len != 1) return false;
    return shape_profile.dimensions[0].runtime_scalar_argument_index == 0;
}

fn resolveKernelCallLaunchForElementCount(
    launch: KernelCallLaunch,
    element_count: u64,
) gpu.BackendError!KernelCallLaunch {
    const derived = switch (launch) {
        .fixed => return launch,
        .derived => |derived| derived,
    };
    const count = std.math.cast(u32, element_count) orelse return error.LaunchArgumentMismatch;
    const count_argument = [_]gpu_abi.ScalarArgument{.{ .u32 = count }};
    return .{ .fixed = try derived.geometry(count_argument[0..]) };
}

fn validateKernelCallArtifact(
    format: gpu.ArtifactFormat,
    artifact: KernelCallArtifact,
) gpu.BackendError!void {
    if (artifact.target.len == 0) return error.InvalidArtifact;
    if (artifact.version == 0) return error.InvalidArtifact;
    if (artifact.format != format) return error.UnsupportedArtifactFormat;
    if (artifact.entry_name.len == 0) return error.InvalidArtifact;
    switch (artifact.payload) {
        .none => return error.InvalidArtifact,
        .bytes => |bytes| if (bytes.len == 0) return error.InvalidArtifact,
        .words_u32 => |words| if (words.len == 0) return error.InvalidArtifact,
        .text => |text| if (text.len == 0) return error.InvalidArtifact,
    }
    const static_argument_count: u32 = std.math.cast(u32, artifact.static_arguments.len) orelse
        return error.InvalidArtifact;
    const scalar_min = std.math.add(
        u32,
        artifact.runtime_scalar_argument_count,
        static_argument_count,
    ) catch return error.InvalidArtifact;
    if (scalar_min > artifact.argument_count) return error.InvalidArtifact;
    if (artifact.shape_profile) |profile| {
        const fingerprint = artifact.shape_family_fingerprint orelse return error.InvalidArtifact;
        if (profile.fingerprint != fingerprint) return error.InvalidArtifact;
        try profile.validate(artifact.runtime_scalar_argument_count);
    }
    switch (artifact.launch) {
        .derived => |derived| try validateKernelCallDerivedLaunch(derived),
        .fixed => {},
    }
}

fn validateKernelCallDerivedLaunch(launch: KernelCallDerivedLaunch) gpu.BackendError!void {
    _ = try validateThreadgroup(launch.threadgroup);
    for (launch.grid) |axis| {
        switch (axis) {
            .fixed => |value| if (value == 0) return error.InvalidArtifact,
            .runtime_u32_ceil_div => |runtime| if (runtime.divisor ==
                0) return error.InvalidArtifact,
        }
    }
}

fn kernelCallTarget(op: *ir.Operation) gpu.BackendError![]const u8 {
    const attr = op.getAttr("target") orelse return error.InvalidArtifact;
    if (!std.mem.eql(
        u8,
        attr.abstract.name,
        dialect_mod.AccyDialect.KernelCallOp.target_attr_name,
    )) {
        return error.InvalidArtifact;
    }
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return error.InvalidArtifact;
    if (dialect_attr.payload.len == 0) return error.InvalidArtifact;
    return dialect_attr.payload;
}

fn kernelCallVersion(op: *ir.Operation) gpu.BackendError!u32 {
    const attr = op.getAttrAs(ir.Attribute.IntegerAttr, "version") orelse
        return error.InvalidArtifact;
    const value = attr.getValue();
    if (value < 1 or value > @as(i64, std.math.maxInt(u32))) return error.InvalidArtifact;
    return @intCast(value);
}

fn expectedKernelCallArgumentCount(
    outline: kernelization_model.KernelOutline,
    element_count_argument: ElementCountArgument,
    runtime_scalar_argument_count: u32,
    static_argument_count: usize,
) gpu.BackendError!u32 {
    var count: usize = 1 + outline.inputCount() + static_argument_count;
    count += runtime_scalar_argument_count;
    switch (element_count_argument) {
        .none => {},
        .scalar_u32, .device_buffer_u32 => count += 1,
    }
    if (count > std.math.maxInt(u32)) return error.InvalidArtifact;
    return @intCast(count);
}

fn duplicateCompilePayload(
    allocator: std.mem.Allocator,
    payload: gpu.CompilePayload,
) gpu.BackendError!gpu.CompilePayload {
    return switch (payload) {
        .none => .none,
        .bytes => |bytes| .{ .bytes = allocator.dupe(u8, bytes) catch return error.OutOfMemory },
        .words_u32 => |words| .{
            .words_u32 = allocator.dupe(u32, words) catch return error.OutOfMemory,
        },
        .text => |text| .{ .text = allocator.dupe(u8, text) catch return error.OutOfMemory },
    };
}

fn compileLaunchPlanForWork(
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError!CompileLaunchPlan {
    return switch (outline.kind) {
        .dot_general => .{
            .dot_general = try dotGeneralLaunchPlanForWork(outline, work, buffer_plan),
        },
        .reduction => .{ .reduction = try reductionLaunchPlanForWork(outline, work, buffer_plan) },
        .elementwise, .shape, .kernel_call, .row_pipeline, .iterate, .flash_attention, .scan => .generic,
    };
}

fn dotGeneralLaunchPlanForWork(
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError!DotGeneralLaunchPlan {
    const desc = try kernelization.dotGeneralDescriptionForWork(outline, work, buffer_plan);
    return .{
        .input_dtype = desc.input_dtype,
        .output_dtype = desc.output_dtype,
        .m = desc.dims.m,
        .n = desc.dims.n,
        .k = desc.dims.k,
        .batch = desc.dims.batch,
    };
}

fn reductionLaunchPlanForWork(
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError!ReductionLaunchPlan {
    const desc = try kernelization.reductionDescriptionForWork(outline, work, buffer_plan);
    return .{
        .kind = launchReductionKind(desc.kind),
        .input_dtype = desc.input_dtype,
        .output_dtype = desc.output_dtype,
        .input_rank = desc.dims.input_rank,
        .axis = desc.dims.axis,
        .input_element_count = desc.dims.input_element_count,
        .output_element_count = desc.dims.output_element_count,
        .reduction_extent = try reductionExtent(desc.dims),
    };
}

fn launchReductionKind(kind: kernelization.ReductionKind) LaunchReductionKind {
    return switch (kind) {
        .sum => .sum,
        .max => .max,
        .min => .min,
    };
}

fn reductionExtent(dims: kernelization.ReductionStaticDims) gpu.BackendError!u32 {
    return switch (dims.input_rank) {
        1 => dims.input_element_count,
        2 => if (dims.axis == 0) dims.rows else dims.cols,
        3 => dims.cols,
        else => error.InvalidArtifact,
    };
}

fn compilePlanFromLoweredKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    lowered: *const kernelization.LoweredKernel,
    work: schedule_planning.ScheduleWorkItem,
) gpu.BackendError!CompilePlan {
    const required_features = gpu_codegen.featureRequirementsForModule(
        lowered.program.kernelModule(),
    );
    const required_subgroup = gpu_codegen.subgroupRequirementsForModule(
        lowered.program.kernelModule(),
    );
    const argument_count = try target_product.abi.argumentCount(format, lowered.argument_count);
    const static_arguments = try target_product.abi.staticArguments(
        allocator,
        format,
        work.element_count,
        lowered.launchGeometry(),
    );
    errdefer if (static_arguments.len != 0) allocator.free(static_arguments);
    const compilation = try target_product.compileKernelForArtifactFormat(
        allocator,
        format,
        lowered.entry_name,
        lowered.program.kernelModule(),
        target_product.compileOptionsForArtifactFormat(format, work.element_count),
    );
    return .{
        .entry_name = lowered.entry_name,
        .argument_count = argument_count,
        .payload = compilation.payload,
        .lowered_kernel = lowered,
        .required_features = required_features,
        .required_subgroup = required_subgroup,
        .push_constants = compilation.push_constants,
        .runtime_scalar_argument_count = lowered.runtimeScalarArgumentCount(),
        .static_arguments = static_arguments,
    };
}

fn compilePlanFromCapturedKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    lowered: *const kernelization.LoweredKernel,
    work: schedule_planning.ScheduleWorkItem,
    target_record: *const accy_choir.record.target.Record,
) gpu.BackendError!CompilePlan {
    for (target_record.kernels) |item| {
        if (item.lowered.work_item_id != work.id) continue;
        if (item.work_dtype != work.dtype or item.element_count != work.element_count) {
            return error.InvalidArtifact;
        }
        const abi = item.abi orelse return error.InvalidArtifact;
        const arguments = try allocator.dupe(gpu_abi.ScalarArgument, abi.static_arguments);
        errdefer allocator.free(arguments);
        const compilation = try target_product.compileKernelForArtifactFormat(
            allocator,
            format,
            lowered.entry_name,
            lowered.program.kernelModule(),
            abi.compile_options,
        );
        return .{
            .entry_name = lowered.entry_name,
            .argument_count = abi.argument_count,
            .payload = compilation.payload,
            .lowered_kernel = lowered,
            .required_dtypes = .{ .bits = item.required_dtype_bits },
            .required_features = item.required_features,
            .required_subgroup = item.required_subgroup,
            .push_constants = compilation.push_constants,
            .runtime_scalar_argument_count = item.runtime_scalar_argument_count,
            .static_arguments = arguments,
        };
    }
    return error.InvalidArtifact;
}

/// Rebuilds the plans inside the caller's `workspace` from the prepared
/// module's stage records. The call compiles each kernel through `handle` and
/// returns an artifact plan the caller owns. A caller uses this to turn a
/// finished compile into device code for one backend. A `workspace` too small
/// for the rebuilt plans gives `error.WorkExhausted`. The rebuilt plans are
/// freed before the call returns, so the returned plan holds copies of the
/// slots and ids and the compiled code, and nothing that points into
/// `workspace`.
pub fn createBackendArtifactPlanFromPreparedModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    prepared: *const preparation.pipeline.BackendPreparedModule,
    options: ArtifactPlanOptions,
    workspace: []u8,
    comptime configuration: choir.product.operation.Configuration,
) !BackendArtifactPlan {
    const input = try @import("input.zig").InputJob.create(workspace, prepared, configuration);
    defer input.destroy();
    return createFromPlans(allocator, handle, input.plans(), options);
}

fn createKernelArtifactFromCompilePlan(
    handle: gpu.BackendHandle,
    format: gpu.ArtifactFormat,
    compile_plan: *const CompilePlan,
    diagnostic_id: []const u8,
    required_dtypes: gpu.DTypeSet,
    required_features: gpu_abi.Features,
    required_subgroup: gpu_abi.SubgroupRequirements,
) gpu.BackendError!gpu.KernelArtifact {
    return try handle.createArtifact(.{
        .kernel_name = compile_plan.entry_name,
        .requested_format = format,
        .argument_count = compile_plan.argument_count,
        .scalar_argument_count = compile_plan.runtime_scalar_argument_count + @as(
            u32,
            @intCast(compile_plan.static_arguments.len),
        ),
        .required_dtypes = required_dtypes,
        .required_features = required_features,
        .required_subgroup = required_subgroup,
        .push_constants = compile_plan.push_constants,
        .diagnostic_id = diagnostic_id,
        .payload = compile_plan.payload,
    });
}

fn deinitCompilePayload(allocator: std.mem.Allocator, payload: gpu.CompilePayload) void {
    switch (payload) {
        .bytes => |bytes| allocator.free(@constCast(bytes)),
        .words_u32 => |words| allocator.free(@constCast(words)),
        .text => |text| allocator.free(@constCast(text)),
        .none => {},
    }
}

fn copyKernelArtifact(
    allocator: std.mem.Allocator,
    source: gpu.KernelArtifact,
) gpu.BackendError!gpu.KernelArtifact {
    var artifact = gpu.KernelArtifact.init(allocator, .{
        .backend = source.backend,
        .format = source.format,
        .entry_name = source.entry_name,
        .argument_count = source.argument_count,
        .scalar_argument_count = source.scalar_argument_count,
        .diagnostic_id = source.diagnostic_id,
        .interface = source.interface,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();

    switch (source.payload) {
        .none => {},
        .bytes => |bytes| try artifact.setOwnedBytes(bytes),
        .words_u32 => |words| try artifact.setOwnedWords(words),
        .text => |text| try artifact.setOwnedText(text),
        .external => return error.InvalidArtifact,
    }

    return artifact;
}

fn kernelizationMissError(
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) gpu.BackendError {
    return switch (outline.kind) {
        .elementwise, .shape, .kernel_call, .row_pipeline, .iterate, .flash_attention, .scan => if (work.dtype == .f32)
            error.UnsupportedOperation
        else
            error.CapabilityMismatch,
        .dot_general => {
            const dot = kernelization.dotGeneralDescriptionForWork(
                outline,
                work,
                buffer_plan,
            ) catch |err| return err;
            if (dot.input_dtype != .f32 or dot.output_dtype != .f32) {
                return error.CapabilityMismatch;
            }
            return error.UnsupportedOperation;
        },
        .reduction => {
            const desc = kernelization.reductionDescriptionForWork(
                outline,
                work,
                buffer_plan,
            ) catch |err| return err;
            if (desc.input_dtype != .f32 or desc.output_dtype != .f32) {
                return error.CapabilityMismatch;
            }
            return error.UnsupportedOperation;
        },
    };
}

fn elementCountArgumentForWork(
    format: gpu.ArtifactFormat,
    work: schedule_planning.ScheduleWorkItem,
    compile_plan: CompilePlan,
) gpu.BackendError!ElementCountArgument {
    if (compile_plan.element_count_argument) |argument| return argument;
    if (compile_plan.lowered_kernel != null) {
        return switch (compile_plan.launch) {
            .dot_general => .none,
            else => .device_buffer_u32,
        };
    }
    _ = format;
    _ = work;
    return error.UnsupportedOperation;
}

fn elementCountArgumentValueForWork(
    work: schedule_planning.ScheduleWorkItem,
    compile_plan: CompilePlan,
) u64 {
    _ = compile_plan;
    return work.element_count;
}

fn fixedThreadgroupSizeFor(format: gpu.ArtifactFormat) ?u32 {
    return switch (format) {
        .vulkan_spirv => 64,
        .cpu_machine_code, .cpu_object, .webassembly_module => 1,
        else => null,
    };
}

fn fixedThreadgroupSize(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    requested: u32,
) gpu.BackendError!u32 {
    switch (format) {
        .vulkan_spirv, .cpu_machine_code, .cpu_object, .webassembly_module => {},
        else => return error.UnsupportedArtifactFormat,
    }
    const max_threads = if (caps.threadgroup.max_threads == 0) 1 else caps.threadgroup.max_threads;
    const max_x = if (caps.threadgroup.max_threads_per_dim[0] == 0)
        1
    else
        caps.threadgroup.max_threads_per_dim[0];
    if (requested > max_threads or requested > max_x) return error.CapabilityMismatch;
    return requested;
}

const LaunchCandidateBuffer = struct {
    items: [max_launch_resource_candidates]LaunchResourceCandidate = @as(
        [max_launch_resource_candidates]LaunchResourceCandidate,
        @splat(.{}),
    ),
    count: usize = 0,
};

fn fixedLaunchResourceCandidates(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    resource_class: LaunchResourceClass,
    fixed_threadgroup: u32,
) gpu.BackendError!LaunchCandidateBuffer {
    const threadgroup_size = try fixedThreadgroupSize(caps, format, fixed_threadgroup);
    var candidates = LaunchCandidateBuffer{};
    try appendLaunchCandidate(
        &candidates,
        caps,
        resources,
        resource_class,
        threadgroup_size,
        threadgroup_size,
    );
    return candidates;
}

fn dynamicLaunchResourceCandidates(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resources: schedule_planning.ScheduleResourceEstimate,
    resource_class: LaunchResourceClass,
    subgroup_size: ?u32,
) gpu.BackendError!LaunchCandidateBuffer {
    const limit = try dynamicThreadgroupLimit(caps, format, resource_class);
    const target = dynamicThreadgroupTarget(resources, subgroup_size, limit);
    var candidates = LaunchCandidateBuffer{};
    try appendLaunchCandidate(&candidates, caps, resources, resource_class, target, target);

    const canonical = [_]u32{ 32, 64, 128, 256, 512, 1024, 16, 8, 4, 2, 1 };
    for (canonical) |candidate| {
        if (!candidateThreadgroupAllowed(candidate, subgroup_size, target)) continue;
        try appendLaunchCandidate(&candidates, caps, resources, resource_class, candidate, target);
    }
    try appendLaunchCandidate(&candidates, caps, resources, resource_class, limit, target);

    if (subgroup_size) |size| {
        if (size != 0 and limit >= size) {
            try appendLaunchCandidate(&candidates, caps, resources, resource_class, size, target);
            try appendLaunchCandidate(
                &candidates,
                caps,
                resources,
                resource_class,
                largestMultipleAtMost(limit, size),
                target,
            );
        }
    }

    return candidates;
}

fn dynamicThreadgroupLimit(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    resource_class: LaunchResourceClass,
) gpu.BackendError!u32 {
    const preferred = try preferredDynamicThreadgroupSize(format, resource_class);
    const max_threads = if (caps.threadgroup.max_threads == 0) 1 else caps.threadgroup.max_threads;
    const max_x = if (caps.threadgroup.max_threads_per_dim[0] == 0)
        1
    else
        caps.threadgroup.max_threads_per_dim[0];
    const limit = @min(@min(preferred, max_threads), max_x);
    if (limit == 0) return error.CapabilityMismatch;

    return limit;
}

fn dynamicThreadgroupTarget(
    resources: schedule_planning.ScheduleResourceEstimate,
    subgroup_size: ?u32,
    limit: u32,
) u32 {
    var target = elementThreadTarget(resources.element_count, limit);
    if (subgroup_size) |size| {
        target = alignThreadgroupToSubgroup(target, size, limit);
    }
    return @max(target, 1);
}

fn appendLaunchCandidate(
    candidates: *LaunchCandidateBuffer,
    caps: gpu.BackendCapabilities,
    resources: schedule_planning.ScheduleResourceEstimate,
    resource_class: LaunchResourceClass,
    threadgroup_size: u32,
    target_threadgroup_size: u32,
) gpu.BackendError!void {
    if (threadgroup_size == 0) return;
    const geometry = gpu_abi.LaunchGeometry{
        .grid = .{ try gridSizeFor(resources.element_count, threadgroup_size), 1, 1 },
        .threadgroup = .{ threadgroup_size, 1, 1 },
    };
    const candidate = LaunchResourceCandidate{
        .geometry = geometry,
        .score = candidateScore(threadgroup_size, target_threadgroup_size),
        .estimated_static_bytes_per_threadgroup = scaleResourceToThreadgroup(
            resources.static_total_bytes,
            resources.element_count,
            threadgroup_size,
        ),
        .estimated_element_ops_per_threadgroup = scaleResourceToThreadgroup(
            resources.estimated_element_ops,
            resources.element_count,
            threadgroup_size,
        ),
    };
    caps.validateLaunchGeometry(candidate.geometry) catch return;
    for (candidates.items[0..candidates.count]) |existing| {
        if (sameLaunchGeometry(existing.geometry, candidate.geometry)) return;
    }

    var insert_index: usize = 0;
    while (insert_index < candidates.count and !candidateSortsBefore(
        candidate,
        candidates.items[insert_index],
        resource_class,
    )) {
        insert_index += 1;
    }
    if (insert_index >= max_launch_resource_candidates) return;

    if (candidates.count < max_launch_resource_candidates) candidates.count += 1;
    var index = candidates.count - 1;
    while (index > insert_index) : (index -= 1) {
        candidates.items[index] = candidates.items[index - 1];
    }
    candidates.items[insert_index] = candidate;
}

fn sameLaunchGeometry(lhs: gpu_abi.LaunchGeometry, rhs: gpu_abi.LaunchGeometry) bool {
    return lhs.grid[0] == rhs.grid[0] and
        lhs.grid[1] == rhs.grid[1] and
        lhs.grid[2] == rhs.grid[2] and
        lhs.threadgroup[0] == rhs.threadgroup[0] and
        lhs.threadgroup[1] == rhs.threadgroup[1] and
        lhs.threadgroup[2] == rhs.threadgroup[2] and
        lhs.dynamic_shared_memory_bytes == rhs.dynamic_shared_memory_bytes;
}

fn candidateThreadgroupAllowed(
    candidate: u32,
    subgroup_size: ?u32,
    target: u32,
) bool {
    if (candidate == 0) return false;
    if (subgroup_size) |size| {
        if (size <= 1) return true;
        if (target < size) return true;
        return candidate >= size and candidate % size == 0;
    }
    return true;
}

fn candidateSortsBefore(
    lhs: LaunchResourceCandidate,
    rhs: LaunchResourceCandidate,
    resource_class: LaunchResourceClass,
) bool {
    const lhs_threadgroup = lhs.geometry.threadgroup[0];
    const rhs_threadgroup = rhs.geometry.threadgroup[0];
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    return switch (resource_class) {
        .memory_bound => lhs_threadgroup > rhs_threadgroup,
        .compute_weighted => lhs_threadgroup < rhs_threadgroup,
        else => lhs_threadgroup < rhs_threadgroup,
    };
}

fn candidateScore(candidate: u32, target: u32) u32 {
    return if (candidate >= target) candidate - target else target - candidate;
}

fn preferredDynamicThreadgroupSize(
    format: gpu.ArtifactFormat,
    resource_class: LaunchResourceClass,
) gpu.BackendError!u32 {
    return switch (format) {
        .cuda_ptx, .metal_msl, .webgpu_wgsl => switch (resource_class) {
            .compute_weighted => 128,
            else => 256,
        },
        else => error.UnsupportedArtifactFormat,
    };
}

fn classifyLaunchResources(
    resources: schedule_planning.ScheduleResourceEstimate,
) LaunchResourceClass {
    if (!resources.static_bytes_complete) return .unknown;
    if (resources.static_total_bytes == 0) return .unknown;
    if (resources.estimated_element_ops == 0) return .unknown;
    const ops_per_kib = resources.elementOpsPerKiB();
    if (ops_per_kib <= 256) return .memory_bound;
    if (ops_per_kib <= 1024) return .balanced;
    return .compute_weighted;
}

fn subgroupSizeFor(caps: gpu.BackendCapabilities) ?u32 {
    if (!caps.subgroup.supported) return null;
    if (caps.subgroup.size_max != 0) return caps.subgroup.size_max;
    if (caps.subgroup.size_min != 0) return caps.subgroup.size_min;
    return null;
}

fn elementThreadTarget(element_count: u64, limit: u32) u32 {
    if (element_count == 0) return 1;
    if (element_count >= limit) return limit;
    const count: u32 = @intCast(element_count);
    return std.math.ceilPowerOfTwo(u32, count) catch limit;
}

fn alignThreadgroupToSubgroup(target: u32, subgroup_size: u32, limit: u32) u32 {
    if (subgroup_size <= 1 or limit < subgroup_size) return target;
    const rounded = roundUpToMultiple(target, subgroup_size);
    if (rounded <= limit) return rounded;
    return largestMultipleAtMost(limit, subgroup_size);
}

fn roundUpToMultiple(value: u32, multiple: u32) u32 {
    const remainder = value % multiple;
    if (remainder == 0) return value;
    return value + (multiple - remainder);
}

fn largestMultipleAtMost(value: u32, multiple: u32) u32 {
    return value - (value % multiple);
}

fn gridSizeFor(element_count: u64, threads: u32) gpu.BackendError!u32 {
    if (threads == 0) return error.CapabilityMismatch;
    const grid = if (element_count == 0)
        1
    else
        ((element_count - 1) / @as(u64, threads)) + 1;
    if (grid > std.math.maxInt(u32)) return error.LaunchArgumentMismatch;
    return @intCast(grid);
}

fn scaleResourceToThreadgroup(total: u64, element_count: u64, threads: u32) u64 {
    if (total == 0 or element_count == 0 or threads == 0) return 0;
    return ceilDivSaturated(saturatedMul(total, threads), element_count);
}

fn ceilDivSaturated(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return 0;
    return (numerator / denominator) + @intFromBool(numerator % denominator != 0);
}

fn saturatedMul(lhs: u64, rhs: u64) u64 {
    return std.math.mul(u64, lhs, rhs) catch std.math.maxInt(u64);
}

const testing = std.testing;

const OwnedSemanticChoirModule = struct {
    module: *semantic.SemanticModule,
    choir_module: *ir.Operation,
};

const OwnedSemanticChoirModuleWithPayload = struct {
    module: *semantic.SemanticModule,
    choir_module: *ir.Operation,
    payload: [32]u8,
};

fn operationTreeContainsName(op: *ir.Operation, name: []const u8) bool {
    if (std.mem.eql(u8, op.name.name, name)) return true;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_node = block.operations.head;
            while (op_node) |node| {
                const child: *ir.Operation = @ptrCast(@alignCast(node));
                if (operationTreeContainsName(child, name)) return true;
                op_node = child.next_op;
            }
        }
    }
    return false;
}

fn addChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{ f32_8, f32_8 }, &.{f32_8});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn kernelCallChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{ f32_8, f32_8 }, &.{f32_8});
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1) },
        &.{f32_8},
        .{
            .target = "accy.custom.scale",
            .operand_effects = &.{ .read, .write },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn reshapeChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_2x4 = try builder.tensor(.f32, &.{ 2, 4 });
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{f32_2x4}, &.{f32_8});
    const reshaped = try fb.reshape(fb.parameter(0), f32_8, &.{8});
    try fb.return_(&.{reshaped});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn fusedAddMulChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{ f32_8, f32_8, f32_8 }, &.{f32_8});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn dotGeneralChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_16x16 = try builder.tensor(.f32, &.{ 16, 16 });
    var fb = try builder.beginFunction(name, &.{ f32_16x16, f32_16x16 }, &.{f32_16x16});
    const product = try fb.dotGeneral(
        fb.parameter(0),
        fb.parameter(1),
        f32_16x16,
        &.{1},
        &.{0},
        &.{},
        &.{},
    );
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn dotGeneralF16ChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f16_16x16 = try builder.tensor(.f16, &.{ 16, 16 });
    const f32_16x16 = try builder.tensor(.f32, &.{ 16, 16 });
    var fb = try builder.beginFunction(name, &.{ f16_16x16, f16_16x16 }, &.{f32_16x16});
    const product = try fb.dotGeneral(
        fb.parameter(0),
        fb.parameter(1),
        f32_16x16,
        &.{1},
        &.{0},
        &.{},
        &.{},
    );
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn reduceChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_256 = try builder.tensor(.f32, &.{256});
    const f32_scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction(name, &.{f32_256}, &.{f32_scalar});
    const zero_value: f32 = 0.0;
    const zero = try fb.constant(f32_scalar, std.mem.asBytes(&zero_value));
    const reduced = try fb.reduce(fb.parameter(0), zero, f32_scalar, "sum", &.{0});
    try fb.return_(&.{reduced});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn reduceI32ChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const i32_256 = try builder.tensor(.i32, &.{256});
    const i32_scalar = try builder.tensor(.i32, &.{});
    var fb = try builder.beginFunction(name, &.{i32_256}, &.{i32_scalar});
    const zero_value: i32 = 0;
    const zero = try fb.constant(i32_scalar, std.mem.asBytes(&zero_value));
    const reduced = try fb.reduce(fb.parameter(0), zero, i32_scalar, "sum", &.{0});
    try fb.return_(&.{reduced});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn reduceRank2Axis1ChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_16x16 = try builder.tensor(.f32, &.{ 16, 16 });
    const f32_16 = try builder.tensor(.f32, &.{16});
    const f32_scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction(name, &.{f32_16x16}, &.{f32_16});
    const zero_value: f32 = 0.0;
    const zero = try fb.constant(f32_scalar, std.mem.asBytes(&zero_value));
    const reduced = try fb.reduce(fb.parameter(0), zero, f32_16, "sum", &.{1});
    try fb.return_(&.{reduced});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn addConstantChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModuleWithPayload {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{f32_8}, &.{f32_8});
    const values = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var payload: [32]u8 = undefined;
    @memcpy(payload[0..], std.mem.sliceAsBytes(values[0..]));
    const c = try fb.constant(f32_8, &payload);
    const sum = try fb.add(fb.parameter(0), c);
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
        .payload = payload,
    };
}

fn expectScalarU32(actual: gpu_abi.ScalarArgument, expected: u32) !void {
    switch (actual) {
        .u32 => |value| try testing.expectEqual(expected, value),
        else => return error.TestExpectedScalarU32,
    }
}

fn expectKernelLayoutFingerprints(plan: *const BackendArtifactPlan, kernel: PlannedKernel) !void {
    const output_slot = plan.slotById(kernel.output_slot_id) orelse return error.MissingSlot;
    try testing.expectEqual(output_slot.layout_fingerprint, kernel.output_layout_fingerprint);
    try testing.expect(kernel.output_layout_fingerprint != 0);
    try testing.expectEqual(
        try plan.layoutFingerprintForInputs(kernel.input_slot_ids),
        kernel.input_layout_fingerprint,
    );
    try testing.expect(kernel.input_layout_fingerprint != 0);
}

fn expectReductionTile(
    tile: LaunchTilePlan,
    output_tile_elements: u32,
    reduction_extent_value: u32,
    rank: u32,
    axis: u32,
    input_tile_bytes: u32,
    output_tile_bytes: u32,
) !void {
    try testing.expect(tile.active());
    try testing.expectEqual(LaunchTileKind.reduction, tile.kind);
    try testing.expectEqual(output_tile_elements, tile.m);
    try testing.expectEqual(reduction_extent_value, tile.n);
    try testing.expectEqual(axis, tile.k);
    try testing.expectEqual(@as(u32, 1), tile.batch);
    try testing.expectEqual(gpu_abi.DType.f32, tile.input_dtype.?);
    try testing.expectEqual(gpu_abi.DType.f32, tile.output_dtype.?);
    try testing.expectEqual(input_tile_bytes, tile.input_tile_bytes);
    try testing.expectEqual(output_tile_bytes, tile.output_tile_bytes);
    try testing.expectEqual(@as(u32, 0), tile.scratch_memory_bytes);
    try testing.expectEqual(LaunchReductionKind.sum, tile.reduction_kind);
    try testing.expectEqual(rank, tile.reduction_rank);
    try testing.expectEqual(axis, tile.reduction_axis);
    try testing.expectEqual(reduction_extent_value, tile.reduction_extent);
}

fn expectDotGeneralTile(
    tile: LaunchTilePlan,
    m: u32,
    n: u32,
    k: u32,
    input_tile_bytes: u32,
    output_tile_bytes: u32,
) !void {
    try testing.expect(tile.active());
    try testing.expectEqual(LaunchTileKind.dot_general, tile.kind);
    try testing.expectEqual(m, tile.m);
    try testing.expectEqual(n, tile.n);
    try testing.expectEqual(k, tile.k);
    try testing.expectEqual(@as(u32, 1), tile.batch);
    try testing.expectEqual(gpu_abi.DType.f32, tile.input_dtype.?);
    try testing.expectEqual(gpu_abi.DType.f32, tile.output_dtype.?);
    try testing.expectEqual(input_tile_bytes, tile.input_tile_bytes);
    try testing.expectEqual(output_tile_bytes, tile.output_tile_bytes);
    try testing.expectEqual(@as(u32, 0), tile.scratch_memory_bytes);
}

fn expectDotGeneralCandidate(
    candidate: LaunchResourceCandidate,
    grid_xy: [2]u32,
    threadgroup_xy: [2]u32,
    score: u32,
    estimated_static_bytes: u64,
    estimated_element_ops: u64,
    m: u32,
    n: u32,
    k: u32,
    input_tile_bytes: u32,
    output_tile_bytes: u32,
) !void {
    try testing.expectEqual(grid_xy[0], candidate.geometry.grid[0]);
    try testing.expectEqual(grid_xy[1], candidate.geometry.grid[1]);
    try testing.expectEqual(@as(u32, 1), candidate.geometry.grid[2]);
    try testing.expectEqual(threadgroup_xy[0], candidate.geometry.threadgroup[0]);
    try testing.expectEqual(threadgroup_xy[1], candidate.geometry.threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), candidate.geometry.threadgroup[2]);
    try testing.expectEqual(score, candidate.score);
    try testing.expectEqual(
        estimated_static_bytes,
        candidate.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(estimated_element_ops, candidate.estimated_element_ops_per_threadgroup);
    try expectDotGeneralTile(candidate.tile, m, n, k, input_tile_bytes, output_tile_bytes);
}

fn deadTemporaryChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    const f32_16 = try builder.tensor(.f32, &.{16});
    var fb = try builder.beginFunction(
        name,
        &.{ f32_8, f32_8, f32_8, f32_8, f32_8, f32_8 },
        &.{ f32_8, f32_8 },
    );
    const shared = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(shared, fb.parameter(2));
    _ = try fb.concatenate(&.{ shared, fb.parameter(3) }, f32_16, 0);
    const sum = try fb.add(fb.parameter(4), fb.parameter(5));
    try fb.return_(&.{ product, sum });
    try fb.finish();
    const module = try builder.finish();

    return .{
        .module = module,
        .choir_module = module.choir_module,
    };
}

fn launchResourceCaps(
    kind: gpu.BackendKind,
    format: gpu.ArtifactFormat,
    max_threads: u32,
    max_x: u32,
    subgroup_size: ?u32,
) gpu.BackendCapabilities {
    return .{
        .identity = .{
            .backend = kind,
            .family = gpu.familyForBackendKind(kind),
            .name = "resource-test",
        },
        .subgroup = if (subgroup_size) |size| .{
            .supported = true,
            .size_min = size,
            .size_max = size,
            .shuffle = true,
            .ballot = true,
            .vote = true,
            .arithmetic = true,
        } else .{},
        .threadgroup = .{
            .max_threads = max_threads,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ max_x, 1, 1 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
        },
        .dtypes = gpu.DTypeSet.init(&.{.f32}),
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{format}),
    };
}

fn launchResources(
    element_count: u64,
    op_count: usize,
    static_total_bytes: u64,
) schedule_planning.ScheduleResourceEstimate {
    return .{
        .element_count = element_count,
        .element_size = 4,
        .op_count = op_count,
        .static_read_bytes = static_total_bytes,
        .static_total_bytes = static_total_bytes,
        .estimated_element_ops = element_count * @as(u64, @intCast(op_count)),
    };
}

const ArtifactPlanningBackendState = struct {
    allocator: std.mem.Allocator,
    kind: gpu.BackendKind,
    format: gpu.ArtifactFormat,

    fn init(allocator: std.mem.Allocator, kind: gpu.BackendKind) ArtifactPlanningBackendState {
        return .{
            .allocator = allocator,
            .kind = kind,
            .format = defaultArtifactFormat(kind).?,
        };
    }

    fn deinit(self: *ArtifactPlanningBackendState) void {
        self.* = undefined;
    }

    fn handle(self: *ArtifactPlanningBackendState) gpu.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &artifact_planning_backend_vtable,
            .kind = self.kind,
        };
    }
};

fn artifactPlanningQueryCapabilities(ptr: *anyopaque) gpu.BackendError!gpu.BackendCapabilities {
    const state: *ArtifactPlanningBackendState = @ptrCast(@alignCast(ptr));
    const dtypes = switch (state.kind) {
        .webgpu => gpu.DTypeSet.init(&.{ .i1, .i32, .u32, .f32 }),
        .wasm => gpu.DTypeSet.init(&.{ .i1, .i32, .u32, .i64, .u64, .f32, .f64 }),
        .cpu => gpu.DTypeSet.init(&.{ .i1, .i32, .u32, .i64, .u64, .f32, .f64 }),
        else => gpu.DTypeSet.init(&.{ .i1, .i32, .u32, .f16, .f32 }),
    };
    const subgroup_size: u32 = switch (state.kind) {
        .vulkan, .webgpu, .cpu, .wasm => 0,
        else => 32,
    };
    return .{
        .identity = .{
            .backend = state.kind,
            .family = gpu.familyForBackendKind(state.kind),
            .name = "artifact-planning",
        },
        .memory = switch (state.kind) {
            .cuda => .{
                .shared_memory_per_threadgroup_bytes = 48 * 1024,
                .constant_memory_bytes = 64 * 1024,
                .min_buffer_alignment = 256,
            },
            .metal => .{
                .min_buffer_alignment = 256,
                .unified_memory = true,
                .host_visible_device_memory = true,
            },
            .webgpu => .{
                .shared_memory_per_threadgroup_bytes = 16 * 1024,
                .min_buffer_alignment = 4,
            },
            .wasm => .{
                .min_buffer_alignment = 1,
                .host_visible_device_memory = true,
            },
            else => .{
                .min_buffer_alignment = 16,
                .host_visible_device_memory = true,
            },
        },
        .subgroup = if (subgroup_size == 0) .{} else .{
            .supported = true,
            .size_min = subgroup_size,
            .size_max = subgroup_size,
            .shuffle = true,
            .ballot = true,
            .vote = true,
            .arithmetic = true,
            .scan = state.kind == .cuda or state.kind == .metal,
        },
        .threadgroup = .{
            .max_threads = if (state.kind == .webgpu) 256 else 1024,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = if (state.kind == .webgpu)
                .{ 256, 256, 64 }
            else
                .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
            .shared_memory_bytes = if (state.kind == .cuda)
                48 * 1024
            else if (state.kind == .webgpu) 16 * 1024 else 0,
        },
        .dtypes = dtypes,
        .layouts = .{
            .row_major = true,
            .compact_strides = true,
            .broadcast_strides = true,
            .tiled = true,
            .vectorized = state.kind == .cuda,
            .opaque_backend_layouts = true,
        },
        .runtime = .{
            .driver_loaded = false,
            .device_context = false,
            .streams = true,
            .events = true,
            .timeline_events = state.kind == .vulkan,
        },
        .features = .{
            .atomic_i32 = state.kind != .webgpu and state.kind != .wasm,
            .atomic_u32 = state.kind != .webgpu and state.kind != .wasm,
            .atomic_index = state.kind != .webgpu and state.kind != .wasm,
            .atomic_f32_add_device = state.kind == .cuda or state.kind == .metal,
            .atomic_f32_add_shared = state.kind == .cuda,
            .async_copy = state.kind == .metal,
            .dynamic_shared_memory = state.kind == .cuda,
        },
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{state.format}),
    };
}

fn artifactPlanningCreateArtifact(
    ptr: *anyopaque,
    request: gpu.CompileRequest,
) gpu.BackendError!gpu.KernelArtifact {
    const state: *ArtifactPlanningBackendState = @ptrCast(@alignCast(ptr));
    if (request.requested_format != state.format) return error.UnsupportedOperation;
    var artifact = gpu.KernelArtifact.init(state.allocator, .{
        .backend = state.kind,
        .format = state.format,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    switch (state.format) {
        .cuda_ptx, .metal_msl, .webgpu_wgsl => switch (request.payload) {
            .text => |text| try artifact.setOwnedText(text),
            .bytes => |bytes| try artifact.setOwnedText(bytes),
            else => return error.InvalidArtifact,
        },
        .vulkan_spirv => switch (request.payload) {
            .words_u32 => |words| try artifact.setOwnedWords(words),
            else => return error.InvalidArtifact,
        },
        .cpu_machine_code, .cpu_object, .webassembly_module => switch (request.payload) {
            .bytes => |bytes| try artifact.setOwnedBytes(bytes),
            else => return error.InvalidArtifact,
        },
        else => return error.UnsupportedArtifactFormat,
    }
    return artifact;
}

const artifact_planning_backend_vtable = gpu.BackendVTable{
    .query_capabilities = artifactPlanningQueryCapabilities,
    .create_artifact = artifactPlanningCreateArtifact,
};

fn createTestBackendArtifactPlan(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    pass_ctx: *passes.PassContext,
    choir_module: *ir.Operation,
    options: ArtifactPlanOptions,
) !BackendArtifactPlan {
    const lowered_kernels = try kernelization.getKernelizationAnalysis(pass_ctx, choir_module);
    return try createBackendArtifactPlan(
        allocator,
        handle,
        .{
            .pass_ctx = pass_ctx,
            .choir_module = choir_module,
            .lowered_kernels = lowered_kernels,
        },
        options,
    );
}

test "Choir launch resource plan uses subgroup-aligned dynamic threadgroups" {
    const caps = launchResourceCaps(.cuda, .cuda_ptx, 96, 96, 32);

    const small = try createLaunchResourcePlan(caps, .cuda_ptx, launchResources(17, 1, 204));
    try testing.expectEqual(@as(u32, 32), small.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 1), small.geometry.grid[0]);
    try testing.expectEqual(@as(?u32, 32), small.subgroup_size);
    try testing.expect(small.subgroup_aligned);
    try testing.expect(!small.fixed_threadgroup);
    try testing.expectEqual(LaunchResourceClass.memory_bound, small.resource_class);
    try testing.expectEqual(@as(u64, 384), small.estimated_static_bytes_per_threadgroup);
    try testing.expectEqual(@as(u64, 32), small.estimated_element_ops_per_threadgroup);
    try testing.expectEqual(LaunchTileKind.none, small.tile.kind);
    try testing.expect(!small.tile.active());
    try testing.expectEqual(@as(usize, 3), small.candidate_count);
    try testing.expectEqual(@as(u32, 32), small.selectedCandidate().?.geometry.threadgroup[0]);
    try testing.expectEqual(LaunchTileKind.none, small.selectedCandidate().?.tile.kind);
    try testing.expectEqual(@as(u32, 64), small.candidates[1].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 96), small.candidates[2].geometry.threadgroup[0]);

    const capped = try createLaunchResourcePlan(caps, .cuda_ptx, launchResources(1000, 1, 12000));
    try testing.expectEqual(@as(u32, 96), capped.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 11), capped.geometry.grid[0]);
    try testing.expect(capped.subgroup_aligned);
    try testing.expectEqual(@as(usize, 3), capped.candidate_count);
    try testing.expectEqual(@as(u32, 96), capped.candidates[0].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 64), capped.candidates[1].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 32), capped.candidates[2].geometry.threadgroup[0]);
}

test "Choir launch resource plan lowers dynamic threadgroups for compute weighted work" {
    const caps = launchResourceCaps(.cuda, .cuda_ptx, 256, 256, 32);

    const plan = try createLaunchResourcePlan(caps, .cuda_ptx, launchResources(4096, 64, 65536));
    try testing.expectEqual(LaunchResourceClass.compute_weighted, plan.resource_class);
    try testing.expectEqual(@as(u32, 128), plan.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 32), plan.geometry.grid[0]);
    try testing.expectEqual(@as(u64, 4096), plan.element_ops_per_kib);
    try testing.expectEqual(@as(u64, 2048), plan.estimated_static_bytes_per_threadgroup);
    try testing.expectEqual(@as(u64, 8192), plan.estimated_element_ops_per_threadgroup);
    try testing.expectEqual(@as(usize, 4), plan.candidate_count);
    try testing.expectEqual(@as(u32, 128), plan.candidates[0].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 64), plan.candidates[1].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 32), plan.candidates[2].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 256), plan.candidates[3].geometry.threadgroup[0]);
}

test "Choir launch resource plan preserves fixed Vulkan local size" {
    const caps = launchResourceCaps(.vulkan, .vulkan_spirv, 128, 128, 32);

    const plan = try createLaunchResourcePlan(caps, .vulkan_spirv, launchResources(65, 1, 780));
    try testing.expectEqual(@as(u32, 64), plan.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 2), plan.geometry.grid[0]);
    try testing.expect(plan.fixed_threadgroup);
    try testing.expectEqual(@as(usize, 1), plan.candidate_count);
    try testing.expectEqual(@as(u32, 64), plan.candidates[0].geometry.threadgroup[0]);

    const too_small = launchResourceCaps(.vulkan, .vulkan_spirv, 63, 63, 32);
    try testing.expectError(
        error.CapabilityMismatch,
        createLaunchResourcePlan(too_small, .vulkan_spirv, launchResources(65, 1, 780)),
    );
}

test "Choir launch resource plan exposes rank-2 elementwise 2D candidates" {
    var caps = launchResourceCaps(.cuda, .cuda_ptx, 256, 256, 32);
    caps.threadgroup.max_threads_per_dim = .{ 256, 256, 64 };
    const rank2 = kernelization.product.ElementwiseRank2Plan{
        .rows = 2048,
        .cols = 2048,
        .threads_x = 32,
        .threads_y = 8,
    };

    const plan = try createElementwiseRank2LaunchResourcePlan(
        caps,
        .cuda_ptx,
        launchResources(2048 * 2048, 1, 2048 * 2048 * 12),
        rank2,
    );
    try testing.expect(!plan.fixed_threadgroup);
    try testing.expectEqual(@as(usize, 8), plan.candidate_count);
    try testing.expectEqual(LaunchTileKind.elementwise_rank2, plan.tile.kind);
    try testing.expectEqual(@as(u32, 2048), plan.tile.m);
    try testing.expectEqual(@as(u32, 2048), plan.tile.n);
    try testing.expectEqual(@as(u32, 32), plan.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 8), plan.geometry.threadgroup[1]);
    try testing.expectEqual(@as(u32, 16), plan.candidates[1].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 16), plan.candidates[1].geometry.threadgroup[1]);
    try testing.expectEqual(@as(u32, 8), plan.candidates[2].geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 32), plan.candidates[2].geometry.threadgroup[1]);
}

test "Choir generated launch resource plan carries dynamic shared memory to candidates" {
    const allocator = testing.allocator;

    var caps = launchResourceCaps(.cuda, .cuda_ptx, 256, 256, 32);
    caps.features.dynamic_shared_memory = true;
    caps.threadgroup.shared_memory_bytes = 4096;

    const plan = try createLaunchResourcePlan(caps, .cuda_ptx, launchResources(4096, 64, 65536));
    try testing.expect(plan.candidate_count > 1);

    var builder = try kernel_program.Builder.init(
        allocator,
        kernel_program.Builder.Limits.testing,
        "x",
        &.{},
    );
    errdefer builder.deinit();
    try builder.return_();
    var program = try builder.finish();
    defer program.deinit();

    const entry_name = try allocator.dupe(u8, "x");
    defer allocator.free(entry_name);

    const lowered = kernelization.LoweredKernel{
        .work_item_id = 0,
        .entry_name = entry_name,
        .program = program,
        .argument_count = 0,
        .body_fingerprint = 0,
        .dynamic_shared_memory_bytes = 2048,
        .schedule = .{
            .kind = .flat,
            .threads = .{ .x = 64 },
        },
    };
    const compile_plan = CompilePlan{
        .entry_name = "x",
        .lowered_kernel = &lowered,
    };

    const updated = try attachGeneratedDynamicSharedMemory(caps, plan, compile_plan);

    try testing.expectEqual(@as(u32, 2048), updated.geometry.dynamic_shared_memory_bytes);
    var candidate_index: usize = 0;
    while (candidate_index < updated.candidate_count) : (candidate_index += 1) {
        try testing.expectEqual(
            @as(u32, 2048),
            updated.candidates[candidate_index].geometry.dynamic_shared_memory_bytes,
        );
    }

    var unsupported = caps;
    unsupported.features.dynamic_shared_memory = false;
    try testing.expectError(
        error.CapabilityMismatch,
        attachGeneratedDynamicSharedMemory(unsupported, plan, compile_plan),
    );
}

test "Choir artifact plan creates CUDA artifacts from legal single-op kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_add_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.cuda, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.tensor, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.generic, kernel.compile.launch);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, kernel.compile.format);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.compile.entry_name);
    try testing.expectEqual(@as(u32, 4), kernel.compile.argument_count);
    try testing.expect(kernel.compile.required_dtypes.contains(.f32));
    try testing.expectEqual(PlannedKernelCompilePayload.text, kernel.compile.payload);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 4), kernel.artifact.argument_count);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(@as(usize, 1), kernel.resources.op_count);
    try testing.expectEqual(@as(usize, 2), kernel.resources.external_input_value_count);
    try testing.expectEqual(@as(u64, 64), kernel.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 32), kernel.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 96), kernel.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 8), kernel.resources.estimated_element_ops);
    try testing.expectEqual(
        LaunchResourceClass.memory_bound,
        kernel.launch_resources.resource_class,
    );
    try testing.expectEqual(
        @as(u64, 384),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 32),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 32), kernel.launch_resources.geometry.threadgroup[0]);
    try expectKernelLayoutFingerprints(&plan, kernel);
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        ".visible .entry accy_choir_elementwise_add_0",
    ) != null);
    try testing.expectEqual(kernel.artifact.payload.text.len, kernel.compile.payload_byte_count);
}

test "Choir artifact plan creates native CPU object artifacts from legal single-op kernels" {
    if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cpu_add_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cpu);
    state.format = .cpu_object;
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{ .format = .cpu_object },
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.cpu, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cpu_object, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.tensor, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.generic, kernel.compile.launch);
    try testing.expectEqual(gpu.ArtifactFormat.cpu_object, kernel.compile.format);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.compile.entry_name);
    try testing.expectEqual(@as(u32, 12), kernel.compile.argument_count);
    try testing.expectEqual(PlannedKernelCompilePayload.bytes, kernel.compile.payload);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 12), kernel.artifact.argument_count);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        kernel.static_arguments.len,
    );
    try expectScalarU32(kernel.static_arguments[0], 0);
    try expectScalarU32(kernel.static_arguments[1], 8);
    try expectScalarU32(kernel.static_arguments[2], 1);
    try expectScalarU32(kernel.static_arguments[3], 1);
    try expectScalarU32(kernel.static_arguments[4], 1);
    try expectScalarU32(kernel.static_arguments[5], 8);
    try expectScalarU32(kernel.static_arguments[6], 1);
    try expectScalarU32(kernel.static_arguments[7], 1);
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(usize, 1), kernel.launch_resources.candidate_count);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 8), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expect(kernel.artifact.payload.bytes.len >= 4);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x7f, 'E', 'L', 'F' },
        kernel.artifact.payload.bytes[0..4],
    );
    try testing.expectEqual(kernel.artifact.payload.bytes.len, kernel.compile.payload_byte_count);
}

test "Choir artifact plan creates webassembly module artifacts from legal single-op kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_wasm_add_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .wasm);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.wasm, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.webassembly_module, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.tensor, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.generic, kernel.compile.launch);
    try testing.expectEqual(gpu.ArtifactFormat.webassembly_module, kernel.compile.format);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.compile.entry_name);
    try testing.expectEqual(@as(u32, 12), kernel.compile.argument_count);
    try testing.expectEqual(PlannedKernelCompilePayload.bytes, kernel.compile.payload);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 12), kernel.artifact.argument_count);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        kernel.static_arguments.len,
    );
    try expectScalarU32(kernel.static_arguments[0], 0);
    try expectScalarU32(kernel.static_arguments[1], 8);
    try expectScalarU32(kernel.static_arguments[2], 1);
    try expectScalarU32(kernel.static_arguments[3], 1);
    try expectScalarU32(kernel.static_arguments[4], 1);
    try expectScalarU32(kernel.static_arguments[5], 8);
    try expectScalarU32(kernel.static_arguments[6], 1);
    try expectScalarU32(kernel.static_arguments[7], 1);
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(usize, 1), kernel.launch_resources.candidate_count);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 8), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expect(kernel.artifact.payload.bytes.len >= 8);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 },
        kernel.artifact.payload.bytes[0..8],
    );
    try testing.expectEqual(kernel.artifact.payload.bytes.len, kernel.compile.payload_byte_count);
}

test "Choir artifact plan uses prepared target module lowered kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_target_artifact_source");
    var module_owned = true;
    errdefer if (module_owned) owned.module.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    const handle = state.handle();
    const caps = try handle.queryCapabilities();
    const profile = try target_profile.BackendTargetProfile.init(caps, .cuda, .cuda_ptx);
    var prepared = try preparation.prepareBackendJobFromSemanticModule(
        allocator,
        owned.module,
        .{ .target_profile = profile },
    );
    module_owned = false;
    defer prepared.deinit();

    const target_module = try prepared.targetModule();
    const product = target_module.kernelizationProduct();
    try testing.expectEqual(@as(usize, 1), product.kernelCount());
    const generated_summary = try product.kernelSummary(0);
    const generated_program = try product.kernelProgram(0);
    try testing.expectEqual(
        generated_summary.body_fingerprint,
        try generated_program.bodyFingerprint(allocator),
    );

    var plan = try createBackendArtifactPlanFromTargetJob(allocator, handle, target_module, .{});
    defer plan.deinit();

    const generated_after_plan = try product.kernelProgramForWork(generated_summary.work_item_id);
    try testing.expectEqual(
        generated_summary.body_fingerprint,
        try generated_after_plan.bodyFingerprint(allocator),
    );
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    try testing.expectEqualStrings(
        "accy_choir_elementwise_add_0_v4",
        plan.kernels.items[0].compile.entry_name,
    );
    try testing.expectEqual(PlannedKernelSource.tensor, plan.kernels.items[0].compile.source);
    try testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
}

test "Choir artifact plan rejects semantic kernel_call until external payload lowering exists" {
    const allocator = testing.allocator;

    var owned = try kernelCallChoirModule(allocator, "choir_cuda_kernel_call_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    try testing.expectError(
        error.UnsupportedOperation,
        createTestBackendArtifactPlan(
            allocator,
            state.handle(),
            &pass_ctx,
            owned.choir_module,
            .{},
        ),
    );
}

test "Choir artifact plan resolves semantic kernel_call through registry" {
    const allocator = testing.allocator;

    var owned = try kernelCallChoirModule(allocator, "choir_cuda_registered_kernel_call_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    const source = ".visible .entry accy_custom_scale() { ret; }";
    const registry = KernelCallRegistry{ .entries = &.{.{
        .target = "accy.custom.scale",
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = "accy_custom_scale",
        .argument_count = 5,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .payload = .{ .text = source },
        .launch = .{ .fixed = .{
            .grid = .{ 1, 1, 1 },
            .threadgroup = .{ 8, 1, 1 },
            .dynamic_shared_memory_bytes = 2048,
        } },
        .element_count_argument = .scalar_u32,
        .static_arguments = &.{.{ .u32 = 7 }},
    }} };

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{ .kernel_call_registry = &registry },
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.kernel_call, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.kernel_call, kernel.compile.launch);
    try testing.expectEqualStrings("accy_custom_scale", kernel.compile.entry_name);
    try testing.expectEqual(@as(u32, 5), kernel.compile.argument_count);
    try testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, kernel.compile.required_dtypes.bits);
    try testing.expectEqual(PlannedKernelCompilePayload.text, kernel.compile.payload);
    try testing.expectEqual(source.len, kernel.compile.payload_byte_count);
    try testing.expectEqualStrings("accy_custom_scale", kernel.artifact.entry_name);
    try testing.expectEqualStrings(source, kernel.artifact.payload.text);
    try testing.expectEqual(@as(usize, 2), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 8), kernel.element_count);
    try testing.expectEqual(ElementCountArgument.scalar_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(@as(usize, 1), kernel.static_arguments.len);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 7 }, kernel.static_arguments[0]);
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(usize, 1), kernel.launch_resources.candidate_count);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 8), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(
        @as(u32, 2048),
        kernel.launch_resources.geometry.dynamic_shared_memory_bytes,
    );
    try testing.expectEqual(
        @as(u32, 8),
        kernel.launch_resources.candidates[0].geometry.threadgroup[0],
    );
    try testing.expectEqual(
        @as(u32, 2048),
        kernel.launch_resources.candidates[0].geometry.dynamic_shared_memory_bytes,
    );
}

test "Choir artifact plan carries prepared backend target profile" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_target_profile_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    const profile = target_profile.BackendTargetProfile{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    };
    try target_profile.setBackendTargetProfile(owned.module.context(), owned.choir_module, profile);

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expect(plan.target_profile.eql(profile));
    try testing.expectEqual(gpu.BackendKind.cuda, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, plan.format);
}

test "Choir CUDA artifact planning preserves generated kernel source modules" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_cuda_target_lowering_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    const planned = plan.kernels.items[0];
    const kernelization_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        owned.choir_module,
    );
    const lowered = kernelization_plan.getForWork(planned.work_item_id) orelse
        return error.MissingKernelization;
    const module = lowered.program.kernelModule();

    try testing.expect(operationTreeContainsName(module, GpuDialect.GlobalIdxOp.operation_name));
    try testing.expect(
        operationTreeContainsName(module, choir.dialects.MemrefDialect.LoadOp.operation_name),
    );
    try testing.expect(
        operationTreeContainsName(module, choir.dialects.MemrefDialect.StoreOp.operation_name),
    );
    try testing.expect(!operationTreeContainsName(
        module,
        gpu_codegen.nvptx.NvptxDialect.ThreadIdxOp.operation_name,
    ));
    try testing.expect(!operationTreeContainsName(
        module,
        gpu_codegen.nvptx.NvptxDialect.BlockIdxOp.operation_name,
    ));
    try testing.expect(!operationTreeContainsName(
        module,
        gpu_codegen.nvptx.NvptxDialect.LoadGlobalOp.operation_name,
    ));
    try testing.expect(!operationTreeContainsName(
        module,
        gpu_codegen.nvptx.NvptxDialect.StoreGlobalOp.operation_name,
    ));
    try testing.expect(
        std.mem.indexOf(u8, planned.artifact.payload.text, planned.compile.entry_name) != null,
    );
}

test "Choir artifact plan creates Vulkan artifacts from legal single-op kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_vulkan_add_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.vulkan, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.tensor, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.generic, kernel.compile.launch);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, kernel.compile.format);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.compile.entry_name);
    try testing.expectEqual(@as(u32, 4), kernel.compile.argument_count);
    try testing.expectEqual(PlannedKernelCompilePayload.words_u32, kernel.compile.payload);
    const kernelization_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        owned.choir_module,
    );
    const lowered = kernelization_plan.getForWork(kernel.work_item_id) orelse
        return error.MissingKernelization;
    const generated_launch = try lowered.program.launch();
    try testing.expectEqual(@as(u32, 1), generated_launch.grid[0]);
    try testing.expectEqual(@as(u32, 8), generated_launch.block[0]);
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 4), kernel.artifact.argument_count);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 8), kernel.launch_resources.geometry.threadgroup[0]);
    try expectKernelLayoutFingerprints(&plan, kernel);
    try testing.expectEqual(@as(u32, 0x07230203), kernel.artifact.payload.words_u32[0]);
    try testing.expectEqual(
        kernel.artifact.payload.words_u32.len * @sizeOf(u32),
        kernel.compile.payload_byte_count,
    );
}

test "Choir artifact planning capabilities reflect implemented backend features" {
    var cuda_state = ArtifactPlanningBackendState.init(testing.allocator, .cuda);
    defer cuda_state.deinit();
    const cuda_caps = try cuda_state.handle().queryCapabilities();
    try testing.expect(cuda_caps.features.atomic_i32);
    try testing.expect(cuda_caps.features.atomic_u32);
    try testing.expect(cuda_caps.features.atomic_index);
    try testing.expect(cuda_caps.features.atomic_f32_add_device);
    try testing.expect(cuda_caps.features.atomic_f32_add_shared);
    try testing.expect(cuda_caps.features.dynamic_shared_memory);

    var metal_state = ArtifactPlanningBackendState.init(testing.allocator, .metal);
    defer metal_state.deinit();
    const metal_caps = try metal_state.handle().queryCapabilities();
    try testing.expect(metal_caps.features.atomic_i32);
    try testing.expect(metal_caps.features.atomic_u32);
    try testing.expect(metal_caps.features.atomic_index);
    try testing.expect(metal_caps.features.atomic_f32_add_device);
    try testing.expect(!metal_caps.features.atomic_f32_add_shared);
    try testing.expect(!metal_caps.features.dynamic_shared_memory);

    var vulkan_state = ArtifactPlanningBackendState.init(testing.allocator, .vulkan);
    defer vulkan_state.deinit();
    const vulkan_caps = try vulkan_state.handle().queryCapabilities();
    try testing.expect(vulkan_caps.features.atomic_i32);
    try testing.expect(vulkan_caps.features.atomic_u32);
    try testing.expect(vulkan_caps.features.atomic_index);
    try testing.expect(!vulkan_caps.features.atomic_f32_add_device);
    try testing.expect(!vulkan_caps.features.atomic_f32_add_shared);
    try testing.expect(!vulkan_caps.features.dynamic_shared_memory);
}

test "Choir Vulkan artifact planning preserves generated kernel source modules" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_vulkan_target_lowering_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    const planned = plan.kernels.items[0];
    const kernelization_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        owned.choir_module,
    );
    const lowered = kernelization_plan.getForWork(planned.work_item_id) orelse
        return error.MissingKernelization;
    const module = lowered.program.kernelModule();

    try testing.expect(operationTreeContainsName(module, GpuDialect.GlobalIdxOp.operation_name));
    try testing.expect(
        operationTreeContainsName(module, choir.dialects.ArithDialect.AddOp.operation_name),
    );
    try testing.expect(!operationTreeContainsName(
        module,
        gpu_codegen.spirv.SpirvDialect.GlobalInvocationIdOp.operation_name,
    ));
    try testing.expect(
        !operationTreeContainsName(module, gpu_codegen.spirv.SpirvDialect.FAddOp.operation_name),
    );
    try testing.expectEqual(@as(u32, 0x07230203), planned.artifact.payload.words_u32[0]);
}

test "Choir artifact plan creates Vulkan artifacts from kernel-language reshape kernels" {
    const allocator = testing.allocator;

    var owned = try reshapeChoirModule(allocator, "choir_vulkan_reshape_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.vulkan, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    const kernelization_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        owned.choir_module,
    );
    const lowered = kernelization_plan.getForWork(kernel.work_item_id) orelse
        return error.MissingKernelization;
    const generated_launch = try lowered.program.launch();
    try testing.expectEqual(@as(u32, 1), generated_launch.grid[0]);
    try testing.expectEqual(@as(u32, 8), generated_launch.block[0]);
    try testing.expectEqualStrings("accy_choir_shape_reshape_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 3), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 8), kernel.element_count);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u64, 32), kernel.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 32), kernel.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 64), kernel.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 8), kernel.resources.estimated_element_ops);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(
        LaunchResourceClass.memory_bound,
        kernel.launch_resources.resource_class,
    );
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 8), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(
        @as(u64, 64),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 8),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    try expectKernelLayoutFingerprints(&plan, kernel);
    try testing.expectEqual(@as(u32, 0x07230203), kernel.artifact.payload.words_u32[0]);
}

test "Choir artifact plan creates native CPU dot_general artifacts" {
    if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;
    const allocator = testing.allocator;

    var owned = try dotGeneralChoirModule(allocator, "choir_cpu_dot_general_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cpu);
    state.format = .cpu_object;
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{ .format = .cpu_object },
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.cpu, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cpu_object, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.tensor, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.dot_general, kernel.compile.launch);
    try testing.expectEqual(gpu.ArtifactFormat.cpu_object, kernel.compile.format);
    try testing.expectEqualStrings(
        "accy_choir_dot_general_f32_16x16x16_0",
        kernel.compile.entry_name,
    );
    try testing.expectEqual(@as(u32, 11), kernel.compile.argument_count);
    try testing.expect(kernel.compile.required_dtypes.contains(.f32));
    try testing.expectEqual(PlannedKernelCompilePayload.bytes, kernel.compile.payload);
    try testing.expectEqualStrings(
        "accy_choir_dot_general_f32_16x16x16_0",
        kernel.artifact.entry_name,
    );
    try testing.expectEqual(@as(u32, 11), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 2), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 256), kernel.element_count);
    try testing.expectEqual(ElementCountArgument.none, kernel.element_count_argument);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        kernel.static_arguments.len,
    );
    try expectScalarU32(kernel.static_arguments[0], 0);
    try expectScalarU32(kernel.static_arguments[1], 256);
    try expectScalarU32(kernel.static_arguments[2], 256);
    try expectScalarU32(kernel.static_arguments[3], 1);
    try expectScalarU32(kernel.static_arguments[4], 1);
    try expectScalarU32(kernel.static_arguments[5], 1);
    try expectScalarU32(kernel.static_arguments[6], 1);
    try expectScalarU32(kernel.static_arguments[7], 1);
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(usize, 1), kernel.launch_resources.candidate_count);
    try testing.expectEqual(@as(u32, 256), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[1]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[2]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.threadgroup[2]);
    try expectDotGeneralTile(kernel.launch_resources.tile, 1, 1, 16, 128, 4);
    try testing.expect(kernel.artifact.payload.bytes.len >= 4);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x7f, 'E', 'L', 'F' },
        kernel.artifact.payload.bytes[0..4],
    );
}

test "Choir artifact plan creates CUDA artifacts from choir dot_general kernels" {
    const allocator = testing.allocator;

    var owned = try dotGeneralChoirModule(allocator, "choir_cuda_dot_general_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.cuda, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.tensor, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.dot_general, kernel.compile.launch);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, kernel.compile.format);
    try testing.expectEqualStrings(
        "accy_choir_dot_general_f32_16x16x16_0",
        kernel.compile.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.compile.argument_count);
    try testing.expect(kernel.compile.required_dtypes.contains(.f32));
    try testing.expectEqual(PlannedKernelCompilePayload.text, kernel.compile.payload);
    try testing.expectEqualStrings(
        "accy_choir_dot_general_f32_16x16x16_0",
        kernel.artifact.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 2), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 256), kernel.element_count);
    try testing.expectEqual(@as(u64, 256), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u64, 2048), kernel.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 1024), kernel.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 3072), kernel.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 8192), kernel.resources.estimated_element_ops);
    try testing.expectEqual(ElementCountArgument.none, kernel.element_count_argument);
    try testing.expectEqual(@as(usize, 0), kernel.static_arguments.len);
    try testing.expectEqual(
        LaunchResourceClass.compute_weighted,
        kernel.launch_resources.resource_class,
    );
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[1]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[2]);
    try testing.expectEqual(@as(u32, 16), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 16), kernel.launch_resources.geometry.threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.threadgroup[2]);
    try testing.expectEqual(
        @as(u64, 3072),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 8192),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    try testing.expectEqual(@as(usize, 4), kernel.launch_resources.candidate_count);
    const tile = kernel.launch_resources.tile;
    try expectDotGeneralTile(tile, 16, 16, 16, 2048, 1024);
    try testing.expectEqual(tile, kernel.launch_resources.candidates[0].tile);
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[0],
        .{ 1, 1 },
        .{ 16, 16 },
        0,
        3072,
        8192,
        16,
        16,
        16,
        2048,
        1024,
    );
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[1],
        .{ 1, 2 },
        .{ 32, 8 },
        1,
        3072,
        8192,
        8,
        32,
        16,
        2560,
        1024,
    );
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[2],
        .{ 2, 1 },
        .{ 8, 32 },
        2,
        3072,
        8192,
        32,
        8,
        16,
        2560,
        1024,
    );
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[3],
        .{ 2, 2 },
        .{ 8, 8 },
        3,
        768,
        2048,
        8,
        8,
        16,
        1024,
        256,
    );
    try expectKernelLayoutFingerprints(&plan, kernel);
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        ".visible .entry accy_choir_dot_general_f32_16x16x16_0",
    ) != null);
    try testing.expectEqual(kernel.artifact.payload.text.len, kernel.compile.payload_byte_count);
}

test "Choir artifact plan requires CUDA f16 choir lowering for f16 dot_general kernels" {
    const allocator = testing.allocator;

    var owned = try dotGeneralF16ChoirModule(allocator, "choir_cuda_dot_general_f16_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    try testing.expectError(
        error.CapabilityMismatch,
        createTestBackendArtifactPlan(
            allocator,
            state.handle(),
            &pass_ctx,
            owned.choir_module,
            .{},
        ),
    );
}

test "Choir artifact plan creates Vulkan artifacts from kernel-language dot_general kernels" {
    const allocator = testing.allocator;

    var owned = try dotGeneralChoirModule(allocator, "choir_vulkan_dot_general_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.vulkan, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqual(PlannedKernelSource.tensor, kernel.compile.source);
    try testing.expectEqual(PlannedKernelCompileLaunch.dot_general, kernel.compile.launch);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, kernel.compile.format);
    try testing.expectEqualStrings(
        "accy_choir_dot_general_f32_16x16x16_0",
        kernel.compile.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.compile.argument_count);
    try testing.expect(kernel.compile.required_dtypes.contains(.f32));
    try testing.expectEqual(PlannedKernelCompilePayload.words_u32, kernel.compile.payload);
    try testing.expectEqualStrings(
        "accy_choir_dot_general_f32_16x16x16_0",
        kernel.artifact.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 2), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 256), kernel.element_count);
    try testing.expectEqual(@as(u64, 256), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u64, 8192), kernel.resources.estimated_element_ops);
    try testing.expectEqual(ElementCountArgument.none, kernel.element_count_argument);
    try testing.expectEqual(@as(usize, 0), kernel.static_arguments.len);
    try testing.expectEqual(
        LaunchResourceClass.compute_weighted,
        kernel.launch_resources.resource_class,
    );
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 2), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 2), kernel.launch_resources.geometry.grid[1]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[2]);
    try testing.expectEqual(@as(u32, 8), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(@as(u32, 8), kernel.launch_resources.geometry.threadgroup[1]);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.threadgroup[2]);
    try testing.expectEqual(
        @as(u64, 768),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 2048),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    try testing.expectEqual(@as(usize, 4), kernel.launch_resources.candidate_count);
    const tile = kernel.launch_resources.tile;
    try expectDotGeneralTile(tile, 8, 8, 16, 1024, 256);
    try testing.expectEqual(tile, kernel.launch_resources.candidates[0].tile);
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[0],
        .{ 2, 2 },
        .{ 8, 8 },
        0,
        768,
        2048,
        8,
        8,
        16,
        1024,
        256,
    );
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[1],
        .{ 1, 2 },
        .{ 16, 8 },
        1,
        1536,
        4096,
        8,
        16,
        16,
        1536,
        512,
    );
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[2],
        .{ 2, 1 },
        .{ 8, 16 },
        2,
        1536,
        4096,
        16,
        8,
        16,
        1536,
        512,
    );
    try expectDotGeneralCandidate(
        kernel.launch_resources.candidates[3],
        .{ 1, 1 },
        .{ 16, 16 },
        3,
        3072,
        8192,
        16,
        16,
        16,
        2048,
        1024,
    );
    try expectKernelLayoutFingerprints(&plan, kernel);
    try testing.expectEqual(@as(u32, 0x07230203), kernel.artifact.payload.words_u32[0]);
    try testing.expectEqual(
        kernel.artifact.payload.words_u32.len * @sizeOf(u32),
        kernel.compile.payload_byte_count,
    );
}

test "Choir artifact plan requires Vulkan f16 capability for f16 dot_general kernels" {
    const allocator = testing.allocator;

    var owned = try dotGeneralF16ChoirModule(allocator, "choir_vulkan_dot_general_f16_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    try testing.expectError(
        error.CapabilityMismatch,
        createTestBackendArtifactPlan(
            allocator,
            state.handle(),
            &pass_ctx,
            owned.choir_module,
            .{},
        ),
    );
}

test "Choir artifact plan creates CUDA artifacts from structured reduction kernels" {
    const allocator = testing.allocator;

    var owned = try reduceChoirModule(allocator, "choir_cuda_reduce_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.cuda, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings(
        "accy_choir_reduction_sum_rank1_axis0_f32_0",
        kernel.artifact.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 1), kernel.element_count);
    try testing.expectEqual(@as(u64, 1), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u64, 1024), kernel.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 4), kernel.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 1028), kernel.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 256), kernel.resources.estimated_element_ops);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(usize, 0), kernel.static_arguments.len);
    try testing.expectEqual(
        LaunchResourceClass.memory_bound,
        kernel.launch_resources.resource_class,
    );
    try testing.expect(!kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 32), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(
        @as(u64, 32896),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 8192),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    const tile = kernel.launch_resources.tile;
    try expectReductionTile(tile, 32, 256, 1, 0, 32768, 128);
    try testing.expectEqual(tile, kernel.launch_resources.candidates[0].tile);
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        ".visible .entry accy_choir_reduction_sum_rank1_axis0_f32_0",
    ) != null);
}

test "Choir artifact plan creates CUDA artifacts from i32 structured reductions" {
    const allocator = testing.allocator;

    var owned = try reduceI32ChoirModule(allocator, "choir_cuda_reduce_i32_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings(
        "accy_choir_reduction_sum_rank1_axis0_i32_0",
        kernel.artifact.entry_name,
    );
    try testing.expect(kernel.compile.required_dtypes.contains(.i32));
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        ".visible .entry accy_choir_reduction_sum_rank1_axis0_i32_0",
    ) != null);
}

test "Choir artifact plan creates Vulkan artifacts from i32 structured reductions" {
    const allocator = testing.allocator;

    var owned = try reduceI32ChoirModule(allocator, "choir_vulkan_reduce_i32_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expect(kernel.compile.required_dtypes.contains(.i32));
}

test "Choir artifact plan creates CUDA artifacts from structured rank-2 reduction kernels" {
    const allocator = testing.allocator;

    var owned = try reduceRank2Axis1ChoirModule(allocator, "choir_cuda_reduce_rank2_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.cuda, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings(
        "accy_choir_reduction_sum_rank2_axis1_f32_0",
        kernel.artifact.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 16), kernel.element_count);
    try testing.expectEqual(@as(u64, 16), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u64, 1024), kernel.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 64), kernel.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 1088), kernel.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 256), kernel.resources.estimated_element_ops);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(usize, 0), kernel.static_arguments.len);
    try testing.expectEqual(
        LaunchResourceClass.memory_bound,
        kernel.launch_resources.resource_class,
    );
    try testing.expect(!kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 32), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(
        @as(u64, 2176),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 512),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    const tile = kernel.launch_resources.tile;
    try expectReductionTile(tile, 32, 16, 2, 1, 2048, 128);
    try testing.expectEqual(tile, kernel.launch_resources.candidates[0].tile);
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        ".visible .entry accy_choir_reduction_sum_rank2_axis1_f32_0",
    ) != null);
}

test "Choir artifact plan creates Vulkan artifacts from kernel-language reduction kernels" {
    const allocator = testing.allocator;

    var owned = try reduceChoirModule(allocator, "choir_vulkan_reduce_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.vulkan, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings(
        "accy_choir_reduction_sum_rank1_axis0_f32_0",
        kernel.artifact.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 1), kernel.element_count);
    try testing.expectEqual(@as(u64, 1), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u64, 256), kernel.resources.estimated_element_ops);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(usize, 0), kernel.static_arguments.len);
    try testing.expectEqual(
        LaunchResourceClass.memory_bound,
        kernel.launch_resources.resource_class,
    );
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 64), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(
        @as(u64, 65792),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 16384),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    const tile = kernel.launch_resources.tile;
    try expectReductionTile(tile, 64, 256, 1, 0, 65536, 256);
    try testing.expectEqual(tile, kernel.launch_resources.candidates[0].tile);
    try testing.expectEqual(@as(u32, 0x07230203), kernel.artifact.payload.words_u32[0]);
}

test "Choir artifact plan creates Vulkan artifacts from rank-2 kernel-language reductions" {
    const allocator = testing.allocator;

    var owned = try reduceRank2Axis1ChoirModule(allocator, "choir_vulkan_reduce_rank2_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.vulkan, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings(
        "accy_choir_reduction_sum_rank2_axis1_f32_0",
        kernel.artifact.entry_name,
    );
    try testing.expectEqual(@as(u32, 3), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 1), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(u64, 16), kernel.element_count);
    try testing.expectEqual(@as(u64, 16), kernel.element_count_argument_value);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(usize, 0), kernel.static_arguments.len);
    try testing.expect(kernel.launch_resources.fixed_threadgroup);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 64), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expectEqual(
        @as(u64, 4352),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 1024),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    const tile = kernel.launch_resources.tile;
    try expectReductionTile(tile, 64, 16, 2, 1, 4096, 256);
    try testing.expectEqual(tile, kernel.launch_resources.candidates[0].tile);
    try testing.expectEqual(@as(u32, 0x07230203), kernel.artifact.payload.words_u32[0]);
}

test "Choir artifact plan creates Metal artifacts from legal single-op kernels" {
    const allocator = testing.allocator;

    var owned = try addChoirModule(allocator, "choir_metal_add_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .metal);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.metal, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.metal_msl, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings("accy_choir_elementwise_add_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 4), kernel.artifact.argument_count);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u32, 1), kernel.launch_resources.geometry.grid[0]);
    try testing.expectEqual(@as(u32, 32), kernel.launch_resources.geometry.threadgroup[0]);
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        "kernel void accy_choir_elementwise_add_0",
    ) != null);
    try testing.expect(
        std.mem.indexOf(u8, kernel.artifact.payload.text, "thread_position_in_grid") != null,
    );
}

test "Choir artifact plan creates CUDA artifacts from legal fused kernels" {
    const allocator = testing.allocator;

    var owned = try fusedAddMulChoirModule(allocator, "choir_cuda_fused_add_mul_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.cuda, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings("accy_choir_elementwise_add_mul_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 5), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 3), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(usize, 2), kernel.op_count);
    try testing.expectEqual(@as(usize, 3), kernel.resources.external_input_value_count);
    try testing.expectEqual(@as(usize, 3), kernel.resources.external_operand_count);
    try testing.expectEqual(@as(usize, 1), kernel.resources.chain_operand_count);
    try testing.expectEqual(@as(u64, 96), kernel.resources.static_read_bytes);
    try testing.expectEqual(@as(u64, 32), kernel.resources.static_write_bytes);
    try testing.expectEqual(@as(u64, 128), kernel.resources.static_total_bytes);
    try testing.expectEqual(@as(u64, 16), kernel.resources.estimated_element_ops);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u64, 128), kernel.resources.elementOpsPerKiB());
    try testing.expectEqual(
        LaunchResourceClass.memory_bound,
        kernel.launch_resources.resource_class,
    );
    try testing.expectEqual(
        @as(u64, 512),
        kernel.launch_resources.estimated_static_bytes_per_threadgroup,
    );
    try testing.expectEqual(
        @as(u64, 64),
        kernel.launch_resources.estimated_element_ops_per_threadgroup,
    );
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        ".visible .entry accy_choir_elementwise_add_mul_0",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, kernel.artifact.payload.text, "mul.f32") != null);
}

test "Choir artifact plan carries memory spaces and layouts into planned slots" {
    const allocator = testing.allocator;

    var owned = try addConstantChoirModule(allocator, "choir_cuda_layout_metadata_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 3), plan.slotCount());
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());

    var constant_slot: ?PlannedSlot = null;
    var output_slot: ?PlannedSlot = null;
    for (plan.slots) |slot| {
        if (slot.role.constant) constant_slot = slot;
        if (slot.role.output) output_slot = slot;
        try testing.expect(slot.layout_fingerprint != 0);
        try testing.expectEqual(layout_planning.LayoutKind.row_major, slot.layout_kind);
        try testing.expectEqualSlices(i64, &.{8}, slot.dims);
        try testing.expectEqualSlices(u64, &.{1}, slot.element_strides.?);
        try testing.expectEqualSlices(usize, &.{0}, slot.minor_to_major);
        try testing.expectEqual(@as(u64, 4), slot.alignment);
        try testing.expect(slot.contiguous);
        try testing.expect(slot.static_layout);
    }

    const constant = constant_slot orelse return error.TestExpectedConstant;
    try testing.expectEqual(memory_space.MemorySpace.device_constant, constant.memory_space);
    try testing.expectEqual(memory_space.MemoryAccess.read_only, constant.memory_access);
    try testing.expectEqual(memory_space.BoundaryTransfer.none, constant.boundary_transfer);
    try testing.expectEqualSlices(u8, owned.payload[0..], constant.constantBytes().?);

    const output = output_slot orelse return error.TestExpectedSlot;
    try testing.expectEqual(memory_space.MemorySpace.device_global, output.memory_space);
    try testing.expectEqual(memory_space.MemoryAccess.write_only, output.memory_access);
    try testing.expectEqual(memory_space.BoundaryTransfer.device_to_host, output.boundary_transfer);
}

test "Choir backend memory plan keeps layout-incompatible allocations separate" {
    const allocation = [_]BackendBufferAllocationPlan{.{
        .allocation_id = 0,
        .byte_size = 32,
        .dtype = .f32,
        .memory_space = .device_global,
        .layout_kind = .row_major,
        .element_count = 8,
        .alignment = 4,
        .layout_fingerprint = 0x1111,
        .last_kernel_index = 0,
    }};
    const matching = BackendSlotLifetime{
        .slot_id = 1,
        .role = .{ .temporary = true },
        .dtype = .f32,
        .memory_space = .device_global,
        .layout_kind = .row_major,
        .element_count = 8,
        .byte_size = 32,
        .alignment = 4,
        .layout_fingerprint = 0x1111,
        .first_kernel_index = 1,
        .last_kernel_index = 1,
    };
    const mismatched = BackendSlotLifetime{
        .slot_id = 2,
        .role = .{ .temporary = true },
        .dtype = .f32,
        .memory_space = .device_global,
        .layout_kind = .row_major,
        .element_count = 8,
        .byte_size = 32,
        .alignment = 4,
        .layout_fingerprint = 0x2222,
        .first_kernel_index = 1,
        .last_kernel_index = 1,
    };

    try testing.expectEqual(@as(?usize, 0), reusableAllocationIndex(allocation[0..], matching));
    try testing.expectEqual(
        @as(?usize, null),
        reusableAllocationIndex(allocation[0..], mismatched),
    );
}

test "Choir backend memory plan reuses dead static tensor slots" {
    const allocator = testing.allocator;

    var owned = try deadTemporaryChoirModule(allocator, "choir_cuda_memory_reuse_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .cuda);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 10), plan.slotCount());
    try testing.expectEqual(@as(usize, 4), plan.kernelCount());

    var memory = try createBackendMemoryPlan(allocator, &plan);
    defer memory.deinit();

    try testing.expectEqual(@as(usize, 4), memory.assignments.len);
    try testing.expectEqual(@as(usize, 3), memory.allocations.len);
    try testing.expectEqual(@as(u64, 160), memory.total_static_slot_bytes);
    try testing.expectEqual(@as(u64, 128), memory.allocated_static_bytes);
    try testing.expectEqual(@as(u64, 128), memory.peak_static_live_bytes);
    try testing.expect(memory.assignmentForSlot(plan.output_slot_ids[0]) != null);
    try testing.expect(memory.assignmentForSlot(plan.output_slot_ids[1]) != null);
}

test "Choir artifact plan creates Vulkan artifacts from legal fused kernels" {
    const allocator = testing.allocator;

    var owned = try fusedAddMulChoirModule(allocator, "choir_vulkan_fused_add_mul_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .vulkan);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.vulkan, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings("accy_choir_elementwise_add_mul_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 5), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 3), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(usize, 2), kernel.op_count);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expectEqual(@as(u32, 0x07230203), kernel.artifact.payload.words_u32[0]);
}

test "Choir artifact plan creates Metal artifacts from legal fused kernels" {
    const allocator = testing.allocator;

    var owned = try fusedAddMulChoirModule(allocator, "choir_metal_fused_add_mul_artifact");
    defer owned.module.deinit();

    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        owned.choir_module,
        owned.module.context(),
        allocator,
        &cache,
    );
    defer pass_ctx.deinit();

    var state = ArtifactPlanningBackendState.init(allocator, .metal);
    defer state.deinit();

    var plan = try createTestBackendArtifactPlan(
        allocator,
        state.handle(),
        &pass_ctx,
        owned.choir_module,
        .{},
    );
    defer plan.deinit();

    try testing.expectEqual(gpu.BackendKind.metal, plan.backend_kind);
    try testing.expectEqual(gpu.ArtifactFormat.metal_msl, plan.format);
    try testing.expectEqual(@as(usize, 1), plan.kernelCount());
    const kernel = plan.kernels.items[0];
    try testing.expectEqualStrings("accy_choir_elementwise_add_mul_0", kernel.artifact.entry_name);
    try testing.expectEqual(@as(u32, 5), kernel.artifact.argument_count);
    try testing.expectEqual(@as(usize, 3), kernel.input_slot_ids.len);
    try testing.expectEqual(@as(usize, 2), kernel.op_count);
    try testing.expectEqual(ElementCountArgument.device_buffer_u32, kernel.element_count_argument);
    try testing.expectEqual(@as(u64, 8), kernel.element_count_argument_value);
    try testing.expect(std.mem.indexOf(
        u8,
        kernel.artifact.payload.text,
        "kernel void accy_choir_elementwise_add_mul_0",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, kernel.artifact.payload.text, " * ") != null);
}
