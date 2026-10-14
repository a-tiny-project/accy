const std = @import("std");
const gpu = @import("gpu");
const fragment_mod = @import("fragment.zig");
const binding_mod = @import("binding.zig");
const plan_mod = @import("plan.zig");

pub const InvocationState = enum {
    prepared,
    running,
    completed,
    cancelled,
    failed,
};

pub const InvocationError = gpu.BackendError || error{InvalidInvocationState};

const InvocationStorage = struct {
    allocator: std.mem.Allocator,
    fragment: *fragment_mod.LoadedFragment,
    bindings: *binding_mod.PreparedLaunchBindings,
    status: InvocationState = .prepared,
    failure: ?gpu.BackendError = null,

    fn deinit(self: *InvocationStorage) void {
        self.bindings.deinit();
        self.* = undefined;
    }
};

pub const Invocation = opaque {
    fn storageConst(self: *const Invocation) *const InvocationStorage {
        return @ptrCast(@alignCast(self));
    }

    fn storageMut(self: *Invocation) *InvocationStorage {
        return @ptrCast(@alignCast(self));
    }

    pub fn deinit(self: *Invocation) void {
        const storage = self.storageMut();
        const allocator = storage.allocator;
        storage.deinit();
        allocator.destroy(storage);
    }

    pub fn state(self: *const Invocation) InvocationState {
        return self.storageConst().status;
    }

    pub fn failure(self: *const Invocation) ?gpu.BackendError {
        return self.storageConst().failure;
    }

    pub fn cancel(self: *Invocation) InvocationError!void {
        const storage = self.storageMut();
        if (storage.status != .prepared) return error.InvalidInvocationState;
        storage.status = .cancelled;
    }

    pub fn launch(
        self: *Invocation,
        scratch: std.mem.Allocator,
    ) InvocationError!void {
        try self.launchWithOptions(scratch, .{});
    }

    pub fn launchWithOptions(
        self: *Invocation,
        scratch: std.mem.Allocator,
        options: fragment_mod.LaunchOptions,
    ) InvocationError!void {
        const storage = self.storageMut();
        if (storage.status != .prepared) return error.InvalidInvocationState;
        storage.status = .running;
        storage.fragment.submitInvocationWithOptions(
            scratch,
            storage.bindings,
            options,
        ) catch |err| {
            storage.failure = err;
            storage.status = .failed;
            return err;
        };
        storage.fragment.completeInvocationWithOptions(options) catch |err| {
            storage.failure = err;
            storage.status = .failed;
            return err;
        };
        storage.status = .completed;
    }

    pub fn launchWithGraph(
        self: *Invocation,
        scratch: std.mem.Allocator,
        graph: plan_mod.LaunchGraphPlan,
    ) InvocationError!void {
        const storage = self.storageMut();
        if (storage.status != .prepared) return error.InvalidInvocationState;
        storage.status = .running;
        storage.fragment.submitInvocationWithGraph(scratch, storage.bindings, graph) catch |err| {
            storage.failure = err;
            storage.status = .failed;
            return err;
        };
        storage.fragment.completeInvocationGraph(graph) catch |err| {
            storage.failure = err;
            storage.status = .failed;
            return err;
        };
        storage.status = .completed;
    }

    pub fn outputCount(self: *const Invocation) usize {
        return self.storageConst().fragment.outputCount();
    }

    pub fn readOutput(
        self: *const Invocation,
        index: usize,
        host_bytes: []u8,
    ) InvocationError!void {
        const storage = self.storageConst();
        if (storage.status != .completed) return error.InvalidInvocationState;
        try storage.fragment.readInvocationOutput(storage.bindings, index, host_bytes);
    }

    pub fn readOutputs(
        self: *const Invocation,
        outputs: []const []u8,
    ) InvocationError!void {
        if (outputs.len != self.outputCount()) return error.InvalidArtifact;
        for (outputs, 0..) |host_bytes, index| {
            try self.readOutput(index, host_bytes);
        }
    }

    pub fn measureLaunchCandidateRecords(
        self: *const Invocation,
        result_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        kernel_index: usize,
        options: fragment_mod.LaunchCandidateBenchmarkOptions,
    ) gpu.BackendError![]fragment_mod.LaunchCandidateRecord {
        const storage = self.storageConst();
        if (storage.status != .prepared) return error.LaunchArgumentMismatch;
        return try storage.fragment.measureInvocationLaunchCandidates(
            result_allocator,
            scratch,
            kernel_index,
            storage.bindings,
            options,
        );
    }

    pub fn measureAndRecordLaunchCandidateRecords(
        self: *Invocation,
        result_allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        options: fragment_mod.LaunchCandidateBenchmarkOptions,
    ) gpu.BackendError![]fragment_mod.LaunchCandidateRecord {
        const storage = self.storageMut();
        if (storage.status != .prepared) return error.LaunchArgumentMismatch;
        return try storage.fragment.measureAndRecordInvocationLaunchCandidates(
            result_allocator,
            scratch,
            storage.bindings,
            options,
        );
    }
};

pub fn prepare(
    fragment: *fragment_mod.LoadedFragment,
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
) !*Invocation {
    const bindings = try fragment.prepareInvocationBindings(allocator, inputs);
    errdefer bindings.deinit();

    const storage = allocator.create(InvocationStorage) catch return error.OutOfMemory;
    storage.* = .{
        .allocator = allocator,
        .fragment = fragment,
        .bindings = bindings,
    };
    return @ptrCast(storage);
}

pub fn run(
    fragment: *fragment_mod.LoadedFragment,
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    inputs: []const []const u8,
    outputs: []const []u8,
) InvocationError!void {
    var invocation = try prepare(fragment, allocator, inputs);
    defer invocation.deinit();
    try invocation.launch(scratch);
    try invocation.readOutputs(outputs);
}
