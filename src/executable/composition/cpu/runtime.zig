const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const sys = @import("sys");
const executable = @import("../../root.zig");

const Allocator = std.mem.Allocator;
const ChoirComposition = choir.composition;

pub const RuntimeEvidence = struct {
    invocation_count: u64,
    completed_invocation_count: u64,
    failed_invocation_count: u64,
    loaded_artifact_count: usize,
    live_buffer_count: usize,
};

pub const RuntimeEvidenceError = error{ForeignLoadedFragment};

pub const State = struct {
    allocator: Allocator,
    fragment_id: ChoirComposition.FragmentId,
    mutex: sys.thread.Mutex = .{},
    cpu: gpu.cpu.State,
    fragment: *executable.LoadedFragment,
    input_byte_sizes: []usize,
    output_byte_sizes: []usize,
    invocation_count: u64 = 0,
    completed_invocation_count: u64 = 0,
    failed_invocation_count: u64 = 0,

    pub fn init(allocator: Allocator, fragment_id: ChoirComposition.FragmentId) State {
        return .{
            .allocator = allocator,
            .fragment_id = fragment_id,
            .cpu = gpu.cpu.State.init(allocator),
            .fragment = undefined,
            .input_byte_sizes = &.{},
            .output_byte_sizes = &.{},
        };
    }

    pub fn handle(self: *State) gpu.BackendHandle {
        return self.cpu.handle();
    }

    pub fn install(
        self: *State,
        fragment: *executable.LoadedFragment,
        input_byte_sizes: []usize,
        output_byte_sizes: []usize,
    ) void {
        self.fragment = fragment;
        self.input_byte_sizes = input_byte_sizes;
        self.output_byte_sizes = output_byte_sizes;
    }

    pub fn deinitUnloaded(self: *State) void {
        std.debug.assert(self.cpu.buffers.count() == 0);
        std.debug.assert(self.cpu.loaded.count() == 0);
        self.cpu.deinit();
        self.* = undefined;
    }
};

pub const vtable = ChoirComposition.FragmentVTable{
    .invoke = invoke,
    .deinit = deinit,
};

pub fn runtimeEvidence(fragment: ChoirComposition.LoadedFragment) RuntimeEvidenceError!RuntimeEvidence {
    if (fragment.vtable != &vtable) return error.ForeignLoadedFragment;
    const state: *State = @ptrCast(@alignCast(fragment.state));
    state.mutex.lock();
    defer state.mutex.unlock();
    return .{
        .invocation_count = state.invocation_count,
        .completed_invocation_count = state.completed_invocation_count,
        .failed_invocation_count = state.failed_invocation_count,
        .loaded_artifact_count = state.cpu.loaded.count(),
        .live_buffer_count = state.cpu.buffers.count(),
    };
}

fn invoke(
    ptr: *anyopaque,
    call_site: *const ChoirComposition.CallSite,
    context: *ChoirComposition.abi.Context,
    frame: *ChoirComposition.abi.Frame,
) ChoirComposition.abi.Status {
    const state: *State = @ptrCast(@alignCast(ptr));
    const context_status = context.validate();
    if (context_status != .ok) return context_status;
    if (call_site.callee.value != state.fragment_id.value) return .missing_fragment;
    if (call_site.abi_version != ChoirComposition.abi.version) return .incompatible_frame;
    if (call_site.inputs.len != state.input_byte_sizes.len or call_site.outputs.len != state.output_byte_sizes.len) return .invalid_resource;
    const expected_resource_count = std.math.add(usize, call_site.inputs.len, call_site.outputs.len) catch return .invalid_resource;

    const resolved = frame.resources(context);
    const resources = switch (resolved) {
        .status => |status| return status,
        .value => |values| values,
    };
    if (resources.len != expected_resource_count) return .invalid_resource;

    var input_values: [ChoirComposition.abi.max_resources][]const u8 = undefined;
    var output_values: [ChoirComposition.abi.max_resources][]u8 = undefined;
    for (resources[0..call_site.inputs.len], 0..) |resource, index| {
        const access = resource.accessValue() orelse return .invalid_resource;
        if (access != .read and access != .read_write) return .invalid_resource;
        const bytes = switch (resource.bytes()) {
            .status => |status| return status,
            .value => |value| value,
        };
        if (bytes.len != state.input_byte_sizes[index]) return .invalid_resource;
        input_values[index] = bytes;
    }
    for (resources[call_site.inputs.len..], 0..) |resource, index| {
        const access = resource.accessValue() orelse return .invalid_resource;
        if (access != .write and access != .read_write) return .invalid_resource;
        const bytes = switch (resource.bytes()) {
            .status => |status| return status,
            .value => |value| value,
        };
        if (bytes.len != state.output_byte_sizes[index]) return .invalid_resource;
        output_values[index] = bytes;
    }

    state.mutex.lock();
    defer state.mutex.unlock();
    state.invocation_count +|= 1;
    const invocation = executable.prepareInvocation(
        state.fragment,
        state.allocator,
        input_values[0..call_site.inputs.len],
    ) catch {
        state.failed_invocation_count +|= 1;
        return .fragment_failure;
    };
    defer invocation.deinit();
    invocation.launch(state.allocator) catch {
        state.failed_invocation_count +|= 1;
        return .fragment_failure;
    };
    invocation.readOutputs(output_values[0..call_site.outputs.len]) catch {
        state.failed_invocation_count +|= 1;
        return .fragment_failure;
    };
    state.completed_invocation_count +|= 1;
    return .ok;
}

fn deinit(ptr: *anyopaque, _: Allocator) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const allocator = state.allocator;
    state.mutex.lock();
    std.debug.assert(state.cpu.buffers.count() == 0);
    std.debug.assert(state.cpu.loaded.count() == state.fragment.kernelCount());
    state.fragment.deinit();
    std.debug.assert(state.cpu.buffers.count() == 0);
    std.debug.assert(state.cpu.loaded.count() == 0);
    state.cpu.deinit();
    allocator.free(state.output_byte_sizes);
    allocator.free(state.input_byte_sizes);
    state.mutex.unlock();
    allocator.destroy(state);
}
