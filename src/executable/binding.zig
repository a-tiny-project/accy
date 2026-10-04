const std = @import("std");
const gpu = @import("gpu");
const artifact_product = @import("../artifact/root.zig");
const plan_mod = @import("plan.zig");

const BackendArtifactPlan = artifact_product.BackendArtifactPlan;
const BackendMemoryPlan = artifact_product.plan.BackendMemoryPlan;
const PlannedSlot = artifact_product.PlannedSlot;

pub const SlotBinding = struct {
    slot_id: usize,
    binding: gpu.BufferBinding,
};

pub const ElementCountBufferBinding = struct {
    kernel_id: usize,
    binding: gpu.BufferBinding,
};

const BackendPlanBuffer = struct {
    allocation_id: usize,
    handle: gpu.BufferHandle,
};

const OutputCopy = struct {
    output_index: usize,
    slot_id: usize,
};

const PreparedLaunchBindingsState = struct {
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    live_buffers: std.ArrayList(gpu.BufferHandle) = .empty,
    slot_bindings: std.ArrayList(SlotBinding) = .empty,
    plan_buffers: std.ArrayList(BackendPlanBuffer) = .empty,
    count_bindings: std.ArrayList(ElementCountBufferBinding) = .empty,
    output_copies: std.ArrayList(OutputCopy) = .empty,
    borrowed_count: usize = 0,

    fn create(
        allocator: std.mem.Allocator,
        handle: gpu.BackendHandle,
    ) !*PreparedLaunchBindingsState {
        const state = try allocator.create(PreparedLaunchBindingsState);
        state.* = .{ .allocator = allocator, .handle = handle };
        return state;
    }

    fn destroy(self: *PreparedLaunchBindingsState) void {
        const allocator = self.allocator;
        std.debug.assert(self.borrowed_count <= self.live_buffers.items.len);
        for (self.live_buffers.items) |buffer| self.handle.destroyObject(buffer.id);
        self.output_copies.deinit(allocator);
        self.count_bindings.deinit(allocator);
        self.plan_buffers.deinit(allocator);
        self.slot_bindings.deinit(allocator);
        self.live_buffers.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }
};

pub const PreparedLaunchBindings = opaque {
    fn stateConst(self: *const PreparedLaunchBindings) *const PreparedLaunchBindingsState {
        return @ptrCast(@alignCast(self));
    }

    fn stateMut(self: *PreparedLaunchBindings) *PreparedLaunchBindingsState {
        return @ptrCast(@alignCast(self));
    }

    pub fn deinit(self: *PreparedLaunchBindings) void {
        self.stateMut().destroy();
    }
};

pub fn liveBufferCount(bindings: *const PreparedLaunchBindings) usize {
    const state = bindings.stateConst();
    return state.live_buffers.items.len;
}

pub fn slotBindings(bindings: *const PreparedLaunchBindings) []const SlotBinding {
    const state = bindings.stateConst();
    return state.slot_bindings.items;
}

pub fn elementCountBindings(
    bindings: *const PreparedLaunchBindings,
) []const ElementCountBufferBinding {
    const state = bindings.stateConst();
    return state.count_bindings.items;
}

pub fn elementCountBindingForKernel(
    bindings: *const PreparedLaunchBindings,
    kernel_id: usize,
) ?gpu.BufferBinding {
    const state = bindings.stateConst();
    for (state.count_bindings.items) |binding| {
        if (binding.kernel_id == kernel_id) return binding.binding;
    }
    return null;
}

/// Returns how many buffers `prepareBorrowed` imported from caller memory, so a
/// caller or a test can see how many buffers of one run use that memory in
/// place.
pub fn borrowedBufferCount(bindings: *const PreparedLaunchBindings) usize {
    const state = bindings.stateConst();
    std.debug.assert(state.borrowed_count <= state.live_buffers.items.len);
    return state.borrowed_count;
}

pub fn prepare(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    artifact_plan: *const BackendArtifactPlan,
    inputs: []const []const u8,
) !*PreparedLaunchBindings {
    if (artifact_plan.input_slot_ids.len != inputs.len) return error.InvalidArtifact;
    const bindings = try PreparedLaunchBindingsState.create(allocator, handle);
    errdefer bindings.destroy();
    const min_buffer_alignment = try backendMinBufferAlignment(handle);

    for (artifact_plan.input_slot_ids, inputs) |slot_id, input| {
        const slot = artifact_plan.slotById(slot_id) orelse return error.InvalidArtifact;
        if (slot.byte_size == null or input.len != slot.byte_size.?) return error.InvalidArtifact;
        try bindCopiedInput(bindings, slot.*, input, min_buffer_alignment);
    }

    var memory_plan = try artifact_product.createBackendMemoryPlan(allocator, artifact_plan);
    defer memory_plan.deinit();
    try bindPlannedSlots(bindings, artifact_plan, &memory_plan, min_buffer_alignment);
    try bindElementCounts(bindings, artifact_plan, min_buffer_alignment);
    return @ptrCast(bindings);
}

/// Binds the caller's `inputs` and `outputs` to planned buffers of one run, and
/// imports each slice in place when the plans show that no kernel will write
/// through it by surprise, so the caller runs a compiled program directly on
/// its own input and output slices, avoiding a copy when the plans allow it. An
/// input is imported read-only when no kernel output and no loop carry writes
/// its slot, and the call copies the input into a new buffer otherwise. An
/// output is copied back later by `completeBorrowed` when its slot appears
/// earlier in the output list, has no planned allocation, is an input, is a
/// constant, or is a loop carry. Every other output is imported as the buffer
/// of its planned allocation, and two outputs that share one allocation give
/// `error.InvalidArtifact`. Input and output counts that differ from the plan
/// give `error.InvalidArtifact`, and an output that overlaps an input or an
/// earlier output gives `error.InvalidBuffer`. Each slice must be exactly its
/// slot's size, and each imported slice must meet the slot's alignment, else
/// the call returns `error.InvalidBuffer`. Imported slices are used in place by
/// the backend, so the caller keeps every slice alive and unmoved until the
/// returned bindings are released with `deinit`.
pub fn prepareBorrowed(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    artifact_plan: *const BackendArtifactPlan,
    launch_plan: plan_mod.LaunchGraphPlan,
    inputs: []const []const u8,
    outputs: []const []u8,
) !*PreparedLaunchBindings {
    if (artifact_plan.input_slot_ids.len != inputs.len) return error.InvalidArtifact;
    if (artifact_plan.output_slot_ids.len != outputs.len) return error.InvalidArtifact;
    try expectDisjointOutputs(inputs, outputs);
    const bindings = try PreparedLaunchBindingsState.create(allocator, handle);
    errdefer bindings.destroy();
    const min_buffer_alignment = try backendMinBufferAlignment(handle);

    for (artifact_plan.input_slot_ids, inputs) |slot_id, input| {
        const slot = artifact_plan.slotById(slot_id) orelse return error.InvalidArtifact;
        if (try slotByteSize(slot.*) != input.len) return error.InvalidBuffer;
        if (slotIsWritten(artifact_plan, launch_plan, slot_id)) {
            try bindCopiedInput(bindings, slot.*, input, min_buffer_alignment);
            continue;
        }
        const buffer = try importSlotBuffer(
            bindings,
            slot.*,
            @constCast(input),
            min_buffer_alignment,
        );
        try appendSlotBindingWithAccess(
            allocator,
            &bindings.slot_bindings,
            slot_id,
            buffer,
            .read_only,
        );
    }

    var memory_plan = try artifact_product.createBackendMemoryPlan(allocator, artifact_plan);
    defer memory_plan.deinit();
    for (outputs, 0..) |output, index| {
        try bindBorrowedOutput(
            bindings,
            artifact_plan,
            launch_plan,
            &memory_plan,
            index,
            output,
            min_buffer_alignment,
        );
    }
    try bindPlannedSlots(bindings, artifact_plan, &memory_plan, min_buffer_alignment);
    try bindElementCounts(bindings, artifact_plan, min_buffer_alignment);
    return @ptrCast(bindings);
}

/// Reads each output that `prepareBorrowed` set aside for copying from its
/// device buffer into the caller's slice, so the caller fills outputs that
/// could not be written in place. The caller calls this function only after the
/// launch has completed, as the session does. An output index beyond `outputs`
/// gives `error.InvalidBuffer`.
pub fn completeBorrowed(
    bindings: *const PreparedLaunchBindings,
    outputs: []const []u8,
) gpu.BackendError!void {
    const state = bindings.stateConst();
    for (state.output_copies.items) |copy| {
        if (copy.output_index >= outputs.len) return error.InvalidBuffer;
        const binding = try bindingForSlot(state.slot_bindings.items, copy.slot_id, .read_only);
        try state.handle.readBuffer(.{
            .handle = binding.handle,
            .bytes = outputs[copy.output_index],
        });
    }
}

fn bindCopiedInput(
    state: *PreparedLaunchBindingsState,
    slot: PlannedSlot,
    input: []const u8,
    min_buffer_alignment: u32,
) !void {
    const buffer = try allocateBackendSlotBuffer(
        state.allocator,
        state.handle,
        &state.live_buffers,
        slot,
        min_buffer_alignment,
    );
    try state.handle.writeBuffer(.{ .handle = buffer, .bytes = input });
    try appendSlotBinding(state.allocator, &state.slot_bindings, slot.slot_id, buffer);
}

fn bindBorrowedOutput(
    state: *PreparedLaunchBindingsState,
    artifact_plan: *const BackendArtifactPlan,
    launch_plan: plan_mod.LaunchGraphPlan,
    memory_plan: *const BackendMemoryPlan,
    index: usize,
    output: []u8,
    min_buffer_alignment: u32,
) !void {
    const slot_id = artifact_plan.output_slot_ids[index];
    const slot = artifact_plan.slotById(slot_id) orelse return error.InvalidArtifact;
    if (try slotByteSize(slot.*) != output.len) return error.InvalidBuffer;
    const earlier_outputs = artifact_plan.output_slot_ids[0..index];
    const repeated = std.mem.indexOfScalar(usize, earlier_outputs, slot_id) != null;
    const assignment = memory_plan.assignmentForSlot(slot_id);
    if (repeated or assignment == null or slot.role.input or slot.role.constant or
        slotIsCarried(launch_plan, slot_id))
    {
        try state.output_copies.append(state.allocator, .{
            .output_index = index,
            .slot_id = slot_id,
        });
        return;
    }
    const allocation_id = assignment.?.allocation_id;
    const existing = planBufferHandleFor(state.plan_buffers.items, allocation_id);
    if (existing != null) return error.InvalidArtifact;
    const buffer = try importSlotBuffer(state, slot.*, output, min_buffer_alignment);
    try state.plan_buffers.append(state.allocator, .{
        .allocation_id = allocation_id,
        .handle = buffer,
    });
}

fn importSlotBuffer(
    state: *PreparedLaunchBindingsState,
    slot: PlannedSlot,
    bytes: []u8,
    min_buffer_alignment: u32,
) !gpu.BufferHandle {
    const buffer = try state.handle.importBuffer(.{
        .bytes = bytes,
        .alignment = try backendAllocationAlignment(slot.alignment, min_buffer_alignment),
        .dtype = slot.dtype,
        .element_count = slot.element_count,
    });
    errdefer state.handle.destroyObject(buffer.id);
    try state.live_buffers.append(state.allocator, buffer);
    state.borrowed_count += 1;
    return buffer;
}

fn slotByteSize(slot: PlannedSlot) !usize {
    const byte_size = slot.byte_size orelse return error.UnsupportedOperation;
    return std.math.cast(usize, byte_size) orelse error.InvalidArtifact;
}

fn slotIsWritten(
    artifact_plan: *const BackendArtifactPlan,
    launch_plan: plan_mod.LaunchGraphPlan,
    slot_id: usize,
) bool {
    for (artifact_plan.kernels.items) |kernel| {
        if (kernel.output_slot_id == slot_id) return true;
    }
    return slotIsCarried(launch_plan, slot_id);
}

fn slotIsCarried(launch_plan: plan_mod.LaunchGraphPlan, slot_id: usize) bool {
    for (launch_plan.loops) |loop| {
        for (loop.carries) |carry| {
            if (carry.initial_slot_id == slot_id or carry.input_slot_id == slot_id) return true;
            if (carry.output_slot_id == slot_id or carry.final_slot_id == slot_id) return true;
        }
    }
    return false;
}

fn expectDisjointOutputs(
    inputs: []const []const u8,
    outputs: []const []u8,
) gpu.BackendError!void {
    for (outputs, 0..) |output, index| {
        for (inputs) |input| {
            if (bytesOverlap(output, input)) return error.InvalidBuffer;
        }
        for (outputs[0..index]) |earlier| {
            if (bytesOverlap(output, earlier)) return error.InvalidBuffer;
        }
    }
}

fn bytesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start < b_start + b.len and b_start < a_start + a.len;
}

fn bindPlannedSlots(
    state: *PreparedLaunchBindingsState,
    artifact_plan: *const BackendArtifactPlan,
    memory_plan: *const BackendMemoryPlan,
    min_buffer_alignment: u32,
) !void {
    const allocator = state.allocator;
    for (artifact_plan.slots) |slot| {
        if (slot.role.input) continue;
        if (slot.role.constant) {
            const used = slot.role.output or plannedSlotHasKernelUse(artifact_plan, slot.slot_id);
            if (!used) continue;
            try bindConstantSlot(state, slot, min_buffer_alignment);
            continue;
        }
        if (!slot.hasStaticSize()) return error.UnsupportedOperation;
        const assignment = memory_plan.assignmentForSlot(slot.slot_id) orelse continue;
        const planned = planBufferHandleFor(state.plan_buffers.items, assignment.allocation_id);
        const slot_handle = planned orelse blk: {
            const allocated = try allocateBackendSlotBuffer(
                allocator,
                state.handle,
                &state.live_buffers,
                slot,
                min_buffer_alignment,
            );
            try state.plan_buffers.append(allocator, .{
                .allocation_id = assignment.allocation_id,
                .handle = allocated,
            });
            break :blk allocated;
        };
        try appendSlotBinding(allocator, &state.slot_bindings, slot.slot_id, slot_handle);
    }
}

fn bindConstantSlot(
    state: *PreparedLaunchBindingsState,
    slot: PlannedSlot,
    min_buffer_alignment: u32,
) !void {
    const bytes = slot.constantBytes() orelse return error.InvalidArtifact;
    if (bytes.len != try slotByteSize(slot)) return error.InvalidArtifact;
    const buffer = try allocateBackendSlotBuffer(
        state.allocator,
        state.handle,
        &state.live_buffers,
        slot,
        min_buffer_alignment,
    );
    try state.handle.writeBuffer(.{ .handle = buffer, .bytes = bytes });
    try appendSlotBindingWithAccess(
        state.allocator,
        &state.slot_bindings,
        slot.slot_id,
        buffer,
        .read_only,
    );
}

fn bindElementCounts(
    state: *PreparedLaunchBindingsState,
    artifact_plan: *const BackendArtifactPlan,
    min_buffer_alignment: u32,
) !void {
    for (artifact_plan.kernels.items) |kernel| {
        if (kernel.element_count_argument != .device_buffer_u32) continue;
        const count_handle = try allocateBackendElementCountBuffer(
            state.allocator,
            state.handle,
            &state.live_buffers,
            min_buffer_alignment,
        );
        if (kernel.element_count > std.math.maxInt(u32)) return error.LaunchArgumentMismatch;
        var count_value: u32 = @intCast(kernel.element_count);
        try state.handle.writeBuffer(.{
            .handle = count_handle,
            .bytes = std.mem.asBytes(&count_value),
        });
        try state.count_bindings.append(state.allocator, .{
            .kernel_id = kernel.kernel_id,
            .binding = executableBackendBinding(count_handle, .read_write),
        });
    }
}

fn allocateBackendSlotBuffer(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    list: *std.ArrayList(gpu.BufferHandle),
    slot: artifact_product.PlannedSlot,
    min_buffer_alignment: u32,
) !gpu.BufferHandle {
    const byte_size_u64 = slot.byte_size orelse return error.UnsupportedOperation;
    const byte_size = std.math.cast(usize, byte_size_u64) orelse return error.InvalidArtifact;
    const buffer = try handle.allocateBuffer(.{
        .byte_size = byte_size,
        .alignment = try backendAllocationAlignment(slot.alignment, min_buffer_alignment),
        .dtype = slot.dtype,
        .element_count = slot.element_count,
    });
    errdefer handle.destroyObject(buffer.id);
    try list.append(allocator, buffer);
    return buffer;
}

fn allocateBackendElementCountBuffer(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    list: *std.ArrayList(gpu.BufferHandle),
    min_buffer_alignment: u32,
) !gpu.BufferHandle {
    const buffer = try handle.allocateBuffer(.{
        .byte_size = @sizeOf(u32),
        .alignment = try backendAllocationAlignment(64, min_buffer_alignment),
        .dtype = .i32,
        .element_count = 1,
    });
    errdefer handle.destroyObject(buffer.id);
    try list.append(allocator, buffer);
    return buffer;
}

fn backendMinBufferAlignment(handle: gpu.BackendHandle) !u32 {
    const caps = try handle.queryCapabilities();
    return caps.memory.min_buffer_alignment;
}

fn backendAllocationAlignment(preferred: u64, min_buffer_alignment: u32) !u32 {
    const aligned = @max(preferred, @as(u64, min_buffer_alignment));
    return std.math.cast(u32, aligned) orelse return error.InvalidArtifact;
}

fn appendSlotBinding(
    allocator: std.mem.Allocator,
    slot_bindings: *std.ArrayList(SlotBinding),
    slot_id: usize,
    handle: gpu.BufferHandle,
) !void {
    try appendSlotBindingWithAccess(allocator, slot_bindings, slot_id, handle, .read_write);
}

fn appendSlotBindingWithAccess(
    allocator: std.mem.Allocator,
    slot_bindings: *std.ArrayList(SlotBinding),
    slot_id: usize,
    handle: gpu.BufferHandle,
    access: gpu.BufferAccess,
) !void {
    try slot_bindings.append(allocator, .{
        .slot_id = slot_id,
        .binding = executableBackendBinding(handle, access),
    });
}

fn executableBackendBinding(handle: gpu.BufferHandle, access: gpu.BufferAccess) gpu.BufferBinding {
    return .{
        .handle = handle,
        .access = access,
        .ownership = handle.ownership,
        .byte_size = handle.byte_size,
    };
}

fn planBufferHandleFor(
    plan_buffers: []const BackendPlanBuffer,
    allocation_id: usize,
) ?gpu.BufferHandle {
    for (plan_buffers) |plan_buffer| {
        if (plan_buffer.allocation_id == allocation_id) return plan_buffer.handle;
    }
    return null;
}

fn plannedSlotHasKernelUse(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    slot_id: usize,
) bool {
    for (artifact_plan.kernels.items) |kernel| {
        if (kernel.output_slot_id == slot_id) return true;
        for (kernel.input_slot_ids) |input_slot_id| {
            if (input_slot_id == slot_id) return true;
        }
    }
    return false;
}

pub fn bindingForSlot(
    bindings: []const SlotBinding,
    slot_id: usize,
    access: gpu.BufferAccess,
) gpu.BackendError!gpu.BufferBinding {
    for (bindings) |slot_binding| {
        if (slot_binding.slot_id != slot_id) continue;
        return .{
            .handle = slot_binding.binding.handle,
            .access = access,
            .ownership = slot_binding.binding.ownership,
            .byte_size = slot_binding.binding.byte_size,
        };
    }
    return error.InvalidBuffer;
}

pub fn countBinding(binding: gpu.BufferBinding) gpu.BufferBinding {
    return .{
        .handle = binding.handle,
        .access = .read_only,
        .ownership = binding.ownership,
        .byte_size = binding.byte_size,
    };
}

pub fn elementCountBufferForKernel(
    bindings: []const ElementCountBufferBinding,
    kernel_id: usize,
) ?gpu.BufferBinding {
    for (bindings) |binding| {
        if (binding.kernel_id == kernel_id) return binding.binding;
    }
    return null;
}

test "borrowed bindings run a cpu fragment on caller memory without copies" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const fixture = @import("fixture.zig");
    const fragment_mod = @import("fragment.zig");
    const invocation_mod = @import("invocation.zig");
    const allocator = std.testing.allocator;

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();
    const module = try fixture.addSemanticModule(allocator, "borrowed_bindings_add");
    const compiled = try fragment_mod.compileFragmentFromSemanticModule(
        allocator,
        handle,
        module,
        .{ .artifact_format = .cpu_object },
    );
    var fragment = try fragment_mod.loadFragment(allocator, handle, compiled, .{
        .artifact_format = .cpu_object,
    });
    defer fragment.deinit();
    const artifact_plan = compiled.artifactPlan();
    const launch_plan = compiled.launchPlan();

    const lhs = try allocator.alignedAlloc(f32, .@"64", 8);
    defer allocator.free(lhs);
    const rhs = try allocator.alignedAlloc(f32, .@"64", 8);
    defer allocator.free(rhs);
    const sum = try allocator.alignedAlloc(f32, .@"64", 8);
    defer allocator.free(sum);
    for (lhs, rhs, 0..) |*left, *right, index| {
        left.* = @floatFromInt(index);
        right.* = 0.25 * @as(f32, @floatFromInt(index));
    }
    const inputs = [_][]const u8{ std.mem.sliceAsBytes(lhs), std.mem.sliceAsBytes(rhs) };
    const outputs = [_][]u8{std.mem.sliceAsBytes(sum)};

    const bindings = try prepareBorrowed(
        allocator,
        handle,
        artifact_plan,
        launch_plan,
        &inputs,
        &outputs,
    );
    defer bindings.deinit();
    try std.testing.expectEqual(@as(usize, 3), borrowedBufferCount(bindings));
    try fragment.submitInvocationWithOptions(allocator, bindings, .{});
    try fragment.completeInvocationWithOptions(.{});
    try completeBorrowed(bindings, &outputs);

    var copied: [8]f32 = undefined;
    const copied_outputs = [_][]u8{std.mem.sliceAsBytes(&copied)};
    try invocation_mod.run(fragment, allocator, allocator, &inputs, &copied_outputs);
    try std.testing.expectEqualSlices(u8, copied_outputs[0], outputs[0]);

    const overlapping = [_][]u8{std.mem.sliceAsBytes(lhs)};
    try std.testing.expectError(
        error.InvalidBuffer,
        prepareBorrowed(allocator, handle, artifact_plan, launch_plan, &inputs, &overlapping),
    );
    const short = [_][]u8{std.mem.sliceAsBytes(sum)[0..4]};
    try std.testing.expectError(
        error.InvalidBuffer,
        prepareBorrowed(allocator, handle, artifact_plan, launch_plan, &inputs, &short),
    );
}
