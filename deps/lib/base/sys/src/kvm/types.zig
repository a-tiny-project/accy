const std = @import("std");
const abi = @import("abi.zig");

pub const Descriptor = std.posix.fd_t;
pub const Errno = std.posix.E;
pub const page_size = std.heap.page_size_min;
pub const maximum_interrupt_retries: usize = 128;

pub const Availability = enum {
    available,
    unsupported,
    unavailable,
    denied,
    failed,
};

pub const CapabilityStage = enum {
    platform,
    device,
    api_version,
    run_mapping,
    extensions,
    complete,
};

pub const Extensions = struct {
    user_memory: u32 = 0,
    extended_cpuid: u32 = 0,
    recommended_vcpus: u32 = 0,
    memory_slots: u32 = 0,
    multiprocessor_state: u32 = 0,
    vcpu_events: u32 = 0,
    debug_registers: u32 = 0,
    xsave: u32 = 0,
    xcrs: u32 = 0,
    maximum_vcpus: u32 = 0,
    read_only_memory: u32 = 0,
    maximum_vcpu_id: u32 = 0,
    immediate_exit: u32 = 0,
    special_registers_2: u32 = 0,
    xsave_2: u32 = 0,
};

pub const CapabilityReceipt = struct {
    availability: Availability = .failed,
    stage: CapabilityStage = .platform,
    errno_code: u16 = 0,
    api_version: u32 = 0,
    run_mapping_bytes: u32 = 0,
    extensions: Extensions = .{},
};

pub const MemoryRegion = struct {
    slot: u32,
    guest_physical_address: u64,
    memory: []align(page_size) u8,
    flags: abi.MemoryFlags = .{},
};

pub const CreateError = error{
    AccessDenied,
    Closed,
    CreateFailed,
    ResourceLimit,
    UnsupportedOperation,
};

pub const MemoryError = error{
    AccessDenied,
    Closed,
    GuestRangeOverflow,
    InvalidAlignment,
    InvalidSlot,
    MemoryRegionFailed,
    UnsupportedFlags,
};

pub const RunError = error{
    AccessDenied,
    Closed,
    Interrupted,
    InvalidRunState,
    RunFailed,
    UnsupportedOperation,
    WouldBlock,
};

pub const StateError = error{
    AccessDenied,
    CapacityExceeded,
    Closed,
    PartialTransfer,
    StateFailed,
    UnsupportedState,
};

pub const RawResult = union(enum) {
    value: usize,
    failure: Errno,
};

pub const MapResult = union(enum) {
    mapping: []align(page_size) u8,
    failure: Errno,
};

pub const Operations = struct {
    context: *anyopaque,
    platform_supported: *const fn (*anyopaque) bool,
    open_device: *const fn (*anyopaque) RawResult,
    control_descriptor: *const fn (*anyopaque, Descriptor, u32, usize) RawResult,
    map_run: *const fn (*anyopaque, Descriptor, usize) MapResult,
    unmap_run: *const fn (*anyopaque, []align(page_size) u8) void,
    close_descriptor: *const fn (*anyopaque, Descriptor) void,

    pub fn platformSupported(self: @This()) bool {
        return self.platform_supported(self.context);
    }

    pub fn openDevice(self: @This()) RawResult {
        return self.open_device(self.context);
    }

    pub fn control(
        self: @This(),
        descriptor: Descriptor,
        request: u32,
        argument: usize,
    ) RawResult {
        return self.control_descriptor(self.context, descriptor, request, argument);
    }

    pub fn mapRun(self: @This(), descriptor: Descriptor, len: usize) MapResult {
        return self.map_run(self.context, descriptor, len);
    }

    pub fn unmap(self: @This(), mapping: []align(page_size) u8) void {
        self.unmap_run(self.context, mapping);
    }

    pub fn close(self: @This(), descriptor: Descriptor) void {
        self.close_descriptor(self.context, descriptor);
    }
};

fn Adapter(comptime Implementation: type) type {
    return struct {
        fn target(context: *anyopaque) *Implementation {
            return @ptrCast(@alignCast(context));
        }

        fn platformSupported(context: *anyopaque) bool {
            return target(context).platformSupported();
        }

        fn openDevice(context: *anyopaque) RawResult {
            return target(context).openDevice();
        }

        fn control(
            context: *anyopaque,
            descriptor: Descriptor,
            request: u32,
            argument: usize,
        ) RawResult {
            return target(context).control(descriptor, request, argument);
        }

        fn mapRun(context: *anyopaque, descriptor: Descriptor, len: usize) MapResult {
            return target(context).mapRun(descriptor, len);
        }

        fn unmap(context: *anyopaque, mapping: []align(page_size) u8) void {
            target(context).unmap(mapping);
        }

        fn close(context: *anyopaque, descriptor: Descriptor) void {
            target(context).close(descriptor);
        }
    };
}

pub fn operationsFor(implementation: anytype) Operations {
    const pointer = @typeInfo(@TypeOf(implementation)).pointer;
    const ImplementationAdapter = Adapter(pointer.child);
    return .{
        .context = implementation,
        .platform_supported = ImplementationAdapter.platformSupported,
        .open_device = ImplementationAdapter.openDevice,
        .control_descriptor = ImplementationAdapter.control,
        .map_run = ImplementationAdapter.mapRun,
        .unmap_run = ImplementationAdapter.unmap,
        .close_descriptor = ImplementationAdapter.close,
    };
}

pub fn controlRetry(
    operations: Operations,
    descriptor: Descriptor,
    request: u32,
    argument: usize,
) RawResult {
    for (0..maximum_interrupt_retries) |_| switch (operations.control(
        descriptor,
        request,
        argument,
    )) {
        .value => |value| return .{ .value = value },
        .failure => |code| {
            if (code == .INTR) continue;
            return .{ .failure = code };
        },
    };
    return .{ .failure = .INTR };
}

pub fn createDescriptor(result: RawResult) CreateError!Descriptor {
    return switch (result) {
        .value => |value| std.math.cast(Descriptor, value) orelse error.CreateFailed,
        .failure => |code| createError(code),
    };
}

pub fn createError(code: Errno) CreateError {
    return switch (code) {
        .ACCES, .PERM => error.AccessDenied,
        .MFILE, .NFILE, .NOMEM => error.ResourceLimit,
        .INVAL, .NODEV, .NOSYS, .OPNOTSUPP => error.UnsupportedOperation,
        else => error.CreateFailed,
    };
}

pub fn stateControl(
    operations: Operations,
    descriptor: Descriptor,
    request: u32,
    argument: usize,
) StateError!void {
    switch (controlRetry(operations, descriptor, request, argument)) {
        .value => return,
        .failure => |code| return switch (code) {
            .ACCES, .PERM => error.AccessDenied,
            .BADF, .NODEV => error.Closed,
            .@"2BIG" => error.CapacityExceeded,
            .INVAL, .NOSYS, .NOTTY, .OPNOTSUPP => error.UnsupportedState,
            else => error.StateFailed,
        },
    }
}
