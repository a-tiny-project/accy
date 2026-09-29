const std = @import("std");
const abi = @import("abi.zig");
const types = @import("types.zig");
const vcpu = @import("vcpu.zig");

pub const Vm = struct {
    pub const descriptor_capacity: usize = 1;

    operations: types.Operations,
    descriptor: types.Descriptor,
    run_mapping_bytes: u32,
    extensions: types.Extensions,
    active: bool = true,

    pub fn deinit(self: *@This()) void {
        if (!self.active) return;
        std.debug.assert(self.descriptor >= 0);
        self.operations.close(self.descriptor);
        self.active = false;
    }

    pub fn registerMemory(
        self: *@This(),
        region: types.MemoryRegion,
    ) types.MemoryError!void {
        if (!self.active) return error.Closed;
        try validateMemory(region, self.extensions);
        const raw: abi.UserMemoryRegion = .{
            .slot = region.slot,
            .flags = region.flags.bits(),
            .guest_physical_address = region.guest_physical_address,
            .memory_size = @intCast(region.memory.len),
            .userspace_address = @intFromPtr(region.memory.ptr),
        };
        try memoryControl(self.operations, self.descriptor, &raw);
    }

    pub fn unregisterMemory(self: *@This(), slot: u32) types.MemoryError!void {
        if (!self.active) return error.Closed;
        if (self.extensions.memory_slots != 0 and slot >= self.extensions.memory_slots) {
            return error.InvalidSlot;
        }
        const raw: abi.UserMemoryRegion = .{
            .slot = slot,
            .flags = 0,
            .guest_physical_address = 0,
            .memory_size = 0,
            .userspace_address = 0,
        };
        try memoryControl(self.operations, self.descriptor, &raw);
    }

    pub fn createVcpu(self: *@This(), identifier: u32) types.CreateError!vcpu.Vcpu {
        if (!self.active) return error.Closed;
        if (self.extensions.maximum_vcpu_id != 0 and
            identifier >= self.extensions.maximum_vcpu_id)
        {
            return error.UnsupportedOperation;
        }
        const result = types.controlRetry(
            self.operations,
            self.descriptor,
            abi.request.create_vcpu,
            identifier,
        );
        const descriptor = try types.createDescriptor(result);
        return createVcpuMapping(self, descriptor);
    }

    pub fn getClock(self: *@This()) types.StateError!abi.Clock {
        if (!self.active) return error.Closed;
        var clock = std.mem.zeroes(abi.Clock);
        try types.stateControl(
            self.operations,
            self.descriptor,
            abi.request.get_clock,
            @intFromPtr(&clock),
        );
        return clock;
    }

    pub fn setClock(self: *@This(), clock: *const abi.Clock) types.StateError!void {
        if (!self.active) return error.Closed;
        try types.stateControl(
            self.operations,
            self.descriptor,
            abi.request.set_clock,
            @intFromPtr(clock),
        );
    }

    fn createVcpuMapping(
        self: *@This(),
        descriptor: types.Descriptor,
    ) types.CreateError!vcpu.Vcpu {
        std.debug.assert(self.run_mapping_bytes >= abi.minimum_run_bytes);
        const mapping = switch (self.operations.mapRun(
            descriptor,
            self.run_mapping_bytes,
        )) {
            .mapping => |value| value,
            .failure => |code| {
                self.operations.close(descriptor);
                return types.createError(code);
            },
        };
        std.debug.assert(mapping.len >= self.run_mapping_bytes);
        return .{
            .operations = self.operations,
            .descriptor = descriptor,
            .mapping = mapping,
            .extensions = self.extensions,
        };
    }
};

fn validateMemory(
    region: types.MemoryRegion,
    extensions: types.Extensions,
) types.MemoryError!void {
    if (extensions.memory_slots != 0 and region.slot >= extensions.memory_slots) {
        return error.InvalidSlot;
    }
    if (region.flags.read_only and extensions.read_only_memory == 0) {
        return error.UnsupportedFlags;
    }
    if (region.memory.len == 0) return error.InvalidAlignment;
    if (region.memory.len % types.page_size != 0) return error.InvalidAlignment;
    if (region.guest_physical_address % types.page_size != 0) {
        return error.InvalidAlignment;
    }
    _ = std.math.add(
        u64,
        region.guest_physical_address,
        region.memory.len,
    ) catch return error.GuestRangeOverflow;
}

fn memoryControl(
    operations: types.Operations,
    descriptor: types.Descriptor,
    region: *const abi.UserMemoryRegion,
) types.MemoryError!void {
    const result = types.controlRetry(
        operations,
        descriptor,
        abi.request.set_user_memory_region,
        @intFromPtr(region),
    );
    switch (result) {
        .value => return,
        .failure => |code| return switch (code) {
            .ACCES, .PERM => error.AccessDenied,
            else => error.MemoryRegionFailed,
        },
    }
}
