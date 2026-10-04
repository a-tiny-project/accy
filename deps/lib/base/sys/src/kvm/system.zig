const std = @import("std");
const abi = @import("abi.zig");
const linux = @import("linux.zig");
const types = @import("types.zig");
const vm = @import("vm.zig");

pub const supported_cpuid_entries_max: usize = 256;
pub const OpenAttempt = union(enum) {
    ready: System,
    rejected: types.CapabilityReceipt,
};

pub const System = struct {
    pub const descriptor_capacity: usize = 1;

    operations: types.Operations,
    descriptor: types.Descriptor,
    receipt: types.CapabilityReceipt,
    active: bool = true,

    pub fn deinit(self: *@This()) void {
        if (!self.active) return;
        std.debug.assert(self.descriptor >= 0);
        self.operations.close(self.descriptor);
        self.active = false;
    }

    pub fn createVm(self: *@This(), machine_type: u32) types.CreateError!vm.Vm {
        if (!self.active) return error.Closed;
        const result = types.controlRetry(
            self.operations,
            self.descriptor,
            abi.request.create_vm,
            machine_type,
        );
        const descriptor = try types.createDescriptor(result);
        return .{
            .operations = self.operations,
            .descriptor = descriptor,
            .run_mapping_bytes = self.receipt.run_mapping_bytes,
            .extensions = self.receipt.extensions,
        };
    }

    pub fn memorySlotCapacity(self: *const @This()) u32 {
        std.debug.assert(self.active);
        return self.receipt.extensions.memory_slots;
    }

    pub fn supportsReadOnlyMemory(self: *const @This()) bool {
        std.debug.assert(self.active);
        return self.receipt.extensions.read_only_memory != 0;
    }

    pub fn supportedCpuid(self: *@This(), buffer: anytype) types.StateError!void {
        if (!self.active) return error.Closed;
        if (self.receipt.extensions.extended_cpuid == 0) {
            return error.UnsupportedState;
        }
        validateCpuidBuffer(@TypeOf(buffer.*));
        if (buffer.count > buffer.entries.len) return error.CapacityExceeded;
        try types.stateControl(
            self.operations,
            self.descriptor,
            abi.request.get_supported_cpuid,
            @intFromPtr(buffer),
        );
    }
};

const ExtensionField = struct {
    extension: abi.Extension,
    name: []const u8,
};

const extension_fields = [_]ExtensionField{
    .{ .extension = .user_memory, .name = "user_memory" },
    .{ .extension = .extended_cpuid, .name = "extended_cpuid" },
    .{ .extension = .recommended_vcpus, .name = "recommended_vcpus" },
    .{ .extension = .memory_slots, .name = "memory_slots" },
    .{ .extension = .mp_state, .name = "multiprocessor_state" },
    .{ .extension = .vcpu_events, .name = "vcpu_events" },
    .{ .extension = .debug_registers, .name = "debug_registers" },
    .{ .extension = .xsave, .name = "xsave" },
    .{ .extension = .xcrs, .name = "xcrs" },
    .{ .extension = .maximum_vcpus, .name = "maximum_vcpus" },
    .{ .extension = .read_only_memory, .name = "read_only_memory" },
    .{ .extension = .maximum_vcpu_id, .name = "maximum_vcpu_id" },
    .{ .extension = .immediate_exit, .name = "immediate_exit" },
    .{ .extension = .special_registers_2, .name = "special_registers_2" },
    .{ .extension = .xsave_2, .name = "xsave_2" },
};

pub fn open() OpenAttempt {
    return acquire(linux.operations());
}

pub fn probe() types.CapabilityReceipt {
    return switch (open()) {
        .ready => |value| result: {
            var system = value;
            const receipt = system.receipt;
            system.deinit();
            break :result receipt;
        },
        .rejected => |receipt| receipt,
    };
}

pub fn acquire(operations: types.Operations) OpenAttempt {
    var receipt: types.CapabilityReceipt = .{};
    if (!operations.platformSupported()) {
        receipt.availability = .unsupported;
        return .{ .rejected = receipt };
    }
    receipt.stage = .device;
    const descriptor = openDescriptor(operations, &receipt) orelse {
        return .{ .rejected = receipt };
    };
    if (!readApiVersion(operations, descriptor, &receipt)) {
        operations.close(descriptor);
        return .{ .rejected = receipt };
    }
    if (!readRunMappingSize(operations, descriptor, &receipt)) {
        operations.close(descriptor);
        return .{ .rejected = receipt };
    }
    if (!readExtensions(operations, descriptor, &receipt)) {
        operations.close(descriptor);
        return .{ .rejected = receipt };
    }
    receipt.availability = .available;
    receipt.stage = .complete;
    return .{ .ready = .{
        .operations = operations,
        .descriptor = descriptor,
        .receipt = receipt,
    } };
}

fn openDescriptor(
    operations: types.Operations,
    receipt: *types.CapabilityReceipt,
) ?types.Descriptor {
    for (0..types.maximum_interrupt_retries) |_| switch (operations.openDevice()) {
        .value => |value| return std.math.cast(types.Descriptor, value) orelse {
            receipt.availability = .failed;
            return null;
        },
        .failure => |code| {
            if (code == .INTR) continue;
            reject(receipt, .device, code);
            return null;
        },
    };
    reject(receipt, .device, .INTR);
    return null;
}

fn readApiVersion(
    operations: types.Operations,
    descriptor: types.Descriptor,
    receipt: *types.CapabilityReceipt,
) bool {
    receipt.stage = .api_version;
    const result = types.controlRetry(
        operations,
        descriptor,
        abi.request.get_api_version,
        0,
    );
    const value = receiptValue(receipt, .api_version, result) orelse return false;
    receipt.api_version = std.math.cast(u32, value) orelse {
        receipt.availability = .failed;
        return false;
    };
    if (receipt.api_version != abi.api_version) {
        receipt.availability = .unsupported;
        return false;
    }
    return true;
}

fn readRunMappingSize(
    operations: types.Operations,
    descriptor: types.Descriptor,
    receipt: *types.CapabilityReceipt,
) bool {
    receipt.stage = .run_mapping;
    const result = types.controlRetry(
        operations,
        descriptor,
        abi.request.get_vcpu_mmap_size,
        0,
    );
    const value = receiptValue(receipt, .run_mapping, result) orelse return false;
    receipt.run_mapping_bytes = std.math.cast(u32, value) orelse {
        receipt.availability = .failed;
        return false;
    };
    if (receipt.run_mapping_bytes < abi.minimum_run_bytes or
        receipt.run_mapping_bytes % types.page_size != 0)
    {
        receipt.availability = .unsupported;
        return false;
    }
    return true;
}

fn readExtensions(
    operations: types.Operations,
    descriptor: types.Descriptor,
    receipt: *types.CapabilityReceipt,
) bool {
    receipt.stage = .extensions;
    inline for (extension_fields) |field| {
        const result = types.controlRetry(
            operations,
            descriptor,
            abi.request.check_extension,
            @backingInt(field.extension),
        );
        const value = receiptValue(receipt, .extensions, result) orelse return false;
        @field(receipt.extensions, field.name) = std.math.cast(u32, value) orelse {
            receipt.availability = .failed;
            return false;
        };
    }
    if (receipt.extensions.user_memory == 0) {
        receipt.availability = .unsupported;
        return false;
    }
    return true;
}

fn receiptValue(
    receipt: *types.CapabilityReceipt,
    stage: types.CapabilityStage,
    result: types.RawResult,
) ?usize {
    return switch (result) {
        .value => |value| value,
        .failure => |code| {
            reject(receipt, stage, code);
            return null;
        },
    };
}

fn reject(
    receipt: *types.CapabilityReceipt,
    stage: types.CapabilityStage,
    code: types.Errno,
) void {
    receipt.availability = classify(code);
    receipt.stage = stage;
    receipt.errno_code = @intCast(@backingInt(code));
}

fn classify(code: types.Errno) types.Availability {
    return switch (code) {
        .ACCES, .PERM => .denied,
        .NOENT, .NODEV, .NXIO => .unavailable,
        .NOSYS, .NOTTY, .OPNOTSUPP => .unsupported,
        else => .failed,
    };
}

fn validateCpuidBuffer(comptime Buffer: type) void {
    comptime {
        if (!@hasField(Buffer, "count") or !@hasField(Buffer, "entries")) {
            @compileError("expected abi.CpuidBuffer");
        }
        if (@FieldType(Buffer, "count") != u32) @compileError("invalid CPUID count type");
        if (@typeInfo(@FieldType(Buffer, "entries")).array.child != abi.CpuidEntry) {
            @compileError("invalid CPUID entry type");
        }
        if (@offsetOf(Buffer, "entries") != @sizeOf(abi.CpuidHeader)) {
            @compileError("invalid CPUID buffer layout");
        }
    }
}
