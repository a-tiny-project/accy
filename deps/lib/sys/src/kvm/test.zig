const std = @import("std");
const sys = @import("../root.zig");
const kvm = @import("root.zig");
const system_backend = @import("system.zig");
const types = @import("types.zig");

const abi = kvm.abi;
const Availability = kvm.Availability;
const CapabilityStage = kvm.CapabilityStage;
const Descriptor = types.Descriptor;
const Errno = types.Errno;
const MapResult = types.MapResult;
const RawResult = types.RawResult;
const maximum_interrupt_retries = types.maximum_interrupt_retries;
const page_size = types.page_size;

test "KVM namespace exposes a no-libc virtualization boundary" {
    std.testing.refAllDecls(kvm);
    try std.testing.expectEqual(
        sys.capabilities.CapabilityTier.no_libc,
        kvm.required_capabilities.tier,
    );
    try std.testing.expect(kvm.required_capabilities.requires(.descriptors));
    try std.testing.expect(kvm.required_capabilities.requires(.memory_mapping));
    try std.testing.expect(kvm.required_capabilities.requires(.virtualization));
    try std.testing.expectEqual(@as(usize, 1), kvm.System.descriptor_capacity);
    try std.testing.expectEqual(@as(usize, 1), kvm.Vm.descriptor_capacity);
    try std.testing.expectEqual(@as(usize, 1), kvm.Vcpu.descriptor_capacity);
    try std.testing.expectEqual(@as(usize, 1), kvm.Vcpu.mapping_capacity);
}

test "KVM host probe never substitutes an unavailable backend" {
    const receipt = kvm.probe();
    if (!kvm.supported) {
        try std.testing.expectEqual(kvm.Availability.unsupported, receipt.availability);
        try std.testing.expectEqual(kvm.CapabilityStage.platform, receipt.stage);
        return;
    }
    if (receipt.availability == .available) {
        try std.testing.expectEqual(kvm.CapabilityStage.complete, receipt.stage);
        try std.testing.expectEqual(kvm.abi.api_version, receipt.api_version);
        try std.testing.expect(receipt.extensions.user_memory != 0);
    } else {
        try std.testing.expect(receipt.stage != .complete);
    }
}

const TestAction = enum {
    open,
    control,
    map,
    unmap,
    close,
};

const TestRecord = struct {
    action: TestAction,
    descriptor: Descriptor = -1,
    request: u32 = 0,
    argument: usize = 0,
};

const FakeOperations = struct {
    platform_available: bool = true,
    open_failure: ?Errno = null,
    control_failure_request: ?u32 = null,
    control_failure: Errno = .IO,
    map_failure: ?Errno = null,
    api: u32 = abi.api_version,
    run_bytes: u32 = 4096,
    user_memory: u32 = 1,
    records: [192]TestRecord = undefined,
    record_count: usize = 0,
    registered_region: ?abi.UserMemoryRegion = null,
    run_storage: [4096]u8 align(page_size) = @splat(0),

    pub fn platformSupported(self: *@This()) bool {
        return self.platform_available;
    }

    pub fn openDevice(self: *@This()) RawResult {
        self.record(.{ .action = .open });
        if (self.open_failure) |code| return .{ .failure = code };
        return .{ .value = 10 };
    }

    pub fn control(
        self: *@This(),
        descriptor: Descriptor,
        request: u32,
        argument: usize,
    ) RawResult {
        self.record(.{
            .action = .control,
            .descriptor = descriptor,
            .request = request,
            .argument = argument,
        });
        if (self.control_failure_request == request) {
            return .{ .failure = self.control_failure };
        }
        return self.controlResult(request, argument);
    }

    pub fn mapRun(self: *@This(), descriptor: Descriptor, len: usize) MapResult {
        self.record(.{ .action = .map, .descriptor = descriptor, .argument = len });
        if (self.map_failure) |code| return .{ .failure = code };
        if (len > self.run_storage.len) return .{ .failure = .NOMEM };
        return .{ .mapping = self.run_storage[0..len] };
    }

    pub fn unmap(self: *@This(), mapping: []align(page_size) u8) void {
        std.debug.assert(mapping.ptr == self.run_storage[0..].ptr);
        self.record(.{ .action = .unmap, .argument = mapping.len });
    }

    pub fn close(self: *@This(), descriptor: Descriptor) void {
        self.record(.{ .action = .close, .descriptor = descriptor });
    }

    fn controlResult(self: *@This(), request: u32, argument: usize) RawResult {
        if (request == abi.request.get_api_version) return .{ .value = self.api };
        if (request == abi.request.get_vcpu_mmap_size) return .{ .value = self.run_bytes };
        if (request == abi.request.check_extension) {
            return .{ .value = self.extensionValue(argument) };
        }
        if (request == abi.request.create_vm) return .{ .value = 20 };
        if (request == abi.request.create_vcpu) return .{ .value = 30 };
        if (request == abi.request.set_user_memory_region) {
            const region: *const abi.UserMemoryRegion = @ptrFromInt(argument);
            self.registered_region = region.*;
            return .{ .value = 0 };
        }
        if (request == abi.request.run) {
            const header: *abi.RunHeader = @ptrCast(&self.run_storage);
            header.exit_reason = @backingInt(kvm.ExitReason.halted);
            return .{ .value = 0 };
        }
        return self.stateResult(request, argument);
    }

    fn extensionValue(self: *@This(), raw_extension: usize) usize {
        const extension_value: u32 = @intCast(raw_extension);
        const extension: abi.Extension = @fromBackingInt(extension_value);
        return switch (extension) {
            .user_memory => self.user_memory,
            .recommended_vcpus => 2,
            .memory_slots => 32,
            .maximum_vcpus => 4,
            .maximum_vcpu_id => 16,
            .xsave_2 => @sizeOf(abi.Xsave),
            else => 1,
        };
    }

    fn stateResult(self: *@This(), request: u32, argument: usize) RawResult {
        if (request == abi.request.get_registers) {
            clear(abi.Registers, argument).rip = 0x1234;
        } else if (request == abi.request.get_special_registers) {
            _ = clear(abi.SpecialRegisters, argument);
        } else if (request == abi.request.get_fpu) {
            _ = clear(abi.Fpu, argument);
        } else if (request == abi.request.get_vcpu_events) {
            _ = clear(abi.VcpuEvents, argument);
        } else if (request == abi.request.get_debug_registers) {
            _ = clear(abi.DebugRegisters, argument);
        } else if (request == abi.request.get_xsave) {
            _ = clear(abi.Xsave, argument);
        } else if (request == abi.request.get_xcrs) {
            _ = clear(abi.Xcrs, argument);
        } else if (request == abi.request.get_mp_state) {
            _ = clear(abi.MpState, argument);
        } else if (request == abi.request.get_clock) {
            clear(abi.Clock, argument).clock = 99;
        } else if (request == abi.request.get_msrs) {
            return getMsrs(argument);
        } else if (request == abi.request.set_msrs) {
            return msrCount(argument);
        } else if (request == abi.request.get_supported_cpuid) {
            return self.supportedCpuid(argument);
        } else if (isStateWrite(request) or isCpuid(request)) {
            return .{ .value = 0 };
        } else {
            return .{ .failure = .NOTTY };
        }
        return .{ .value = 0 };
    }

    fn supportedCpuid(_: *const @This(), address: usize) RawResult {
        const header: *abi.CpuidHeader = @ptrFromInt(address);
        if (header.count == 0) return .{ .failure = .@"2BIG" };
        const entries: [*]abi.CpuidEntry = @ptrFromInt(address + @sizeOf(abi.CpuidHeader));
        header.count = 1;
        entries[0] = std.mem.zeroes(abi.CpuidEntry);
        entries[0].function = 0x8000_0001;
        entries[0].edx = @as(u32, 1) << 20;
        return .{ .value = 0 };
    }

    fn record(self: *@This(), value: TestRecord) void {
        std.debug.assert(self.record_count < self.records.len);
        self.records[self.record_count] = value;
        self.record_count += 1;
    }

    fn actionCount(self: *const @This(), action: TestAction) usize {
        var count: usize = 0;
        for (self.records[0..self.record_count]) |entry| {
            if (entry.action == action) count += 1;
        }
        return count;
    }

    fn descriptorCloseCount(self: *const @This(), descriptor: Descriptor) usize {
        var count: usize = 0;
        for (self.records[0..self.record_count]) |entry| {
            if (entry.action == .close and entry.descriptor == descriptor) count += 1;
        }
        return count;
    }

    fn clear(comptime T: type, address: usize) *T {
        const destination: *T = @ptrFromInt(address);
        destination.* = std.mem.zeroes(T);
        return destination;
    }

    fn getMsrs(address: usize) RawResult {
        const header: *abi.MsrHeader = @ptrFromInt(address);
        std.debug.assert(header.count <= 16);
        const entries: [*]abi.MsrEntry = @ptrFromInt(address + @sizeOf(abi.MsrHeader));
        for (entries[0..header.count], 0..) |*entry, index| {
            entry.data = 0x1000 + index;
        }
        return .{ .value = header.count };
    }

    fn msrCount(address: usize) RawResult {
        const header: *const abi.MsrHeader = @ptrFromInt(address);
        return .{ .value = header.count };
    }

    fn isStateWrite(request: u32) bool {
        return request == abi.request.set_registers or
            request == abi.request.set_special_registers or
            request == abi.request.set_fpu or
            request == abi.request.set_vcpu_events or
            request == abi.request.set_debug_registers or
            request == abi.request.set_xsave or
            request == abi.request.set_xcrs or
            request == abi.request.set_mp_state or
            request == abi.request.set_clock;
    }

    fn isCpuid(request: u32) bool {
        return request == abi.request.get_supported_cpuid or
            request == abi.request.get_cpuid or
            request == abi.request.set_cpuid;
    }
};

fn readySystem(operations: *FakeOperations) !system_backend.System {
    return switch (system_backend.acquire(types.operationsFor(operations))) {
        .ready => |system| system,
        .rejected => error.UnexpectedRejection,
    };
}

fn expectDeviceRejection(code: Errno, availability: Availability) !void {
    var operations: FakeOperations = .{ .open_failure = code };
    const attempt = system_backend.acquire(types.operationsFor(&operations));
    switch (attempt) {
        .ready => return error.UnexpectedAvailability,
        .rejected => |receipt| {
            try std.testing.expectEqual(availability, receipt.availability);
            try std.testing.expectEqual(CapabilityStage.device, receipt.stage);
            try std.testing.expectEqual(
                @as(u16, @intCast(@backingInt(code))),
                receipt.errno_code,
            );
        },
    }
    try std.testing.expectEqual(@as(usize, 0), operations.actionCount(.close));
    const expected_opens: usize = if (code == .INTR) maximum_interrupt_retries else 1;
    try std.testing.expectEqual(expected_opens, operations.actionCount(.open));
}

test "KVM capability receipt classifies device rejection" {
    try expectDeviceRejection(.NOENT, .unavailable);
    try expectDeviceRejection(.NODEV, .unavailable);
    try expectDeviceRejection(.ACCES, .denied);
    try expectDeviceRejection(.NOSYS, .unsupported);
    try expectDeviceRejection(.IO, .failed);
    try expectDeviceRejection(.INTR, .failed);

    var operations: FakeOperations = .{ .platform_available = false };
    const attempt = system_backend.acquire(types.operationsFor(&operations));
    try std.testing.expectEqual(
        Availability.unsupported,
        attempt.rejected.availability,
    );
    try std.testing.expectEqual(CapabilityStage.platform, attempt.rejected.stage);
    try std.testing.expectEqual(@as(usize, 0), operations.actionCount(.open));
}

test "KVM capability receipt closes rejected system descriptor" {
    var incompatible: FakeOperations = .{ .api = abi.api_version + 1 };
    const version_attempt = system_backend.acquire(types.operationsFor(&incompatible));
    try std.testing.expectEqual(
        Availability.unsupported,
        version_attempt.rejected.availability,
    );
    try std.testing.expectEqual(CapabilityStage.api_version, version_attempt.rejected.stage);
    try std.testing.expectEqual(@as(usize, 1), incompatible.descriptorCloseCount(10));

    var missing_memory: FakeOperations = .{ .user_memory = 0 };
    const memory_attempt = system_backend.acquire(types.operationsFor(&missing_memory));
    try std.testing.expectEqual(
        Availability.unsupported,
        memory_attempt.rejected.availability,
    );
    try std.testing.expectEqual(CapabilityStage.extensions, memory_attempt.rejected.stage);
    try std.testing.expectEqual(@as(usize, 1), missing_memory.descriptorCloseCount(10));

    var invalid_mapping: FakeOperations = .{ .run_bytes = 3000 };
    const mapping_attempt = system_backend.acquire(types.operationsFor(&invalid_mapping));
    try std.testing.expectEqual(
        Availability.unsupported,
        mapping_attempt.rejected.availability,
    );
    try std.testing.expectEqual(CapabilityStage.run_mapping, mapping_attempt.rejected.stage);
    try std.testing.expectEqual(@as(usize, 1), invalid_mapping.descriptorCloseCount(10));

    var denied_extension: FakeOperations = .{
        .control_failure_request = abi.request.check_extension,
        .control_failure = .ACCES,
    };
    const extension_attempt = system_backend.acquire(types.operationsFor(&denied_extension));
    try std.testing.expectEqual(Availability.denied, extension_attempt.rejected.availability);
    try std.testing.expectEqual(CapabilityStage.extensions, extension_attempt.rejected.stage);
    try std.testing.expectEqual(@as(usize, 1), denied_extension.descriptorCloseCount(10));
}

test "KVM system acquisition returns measured capabilities and closes once" {
    var operations: FakeOperations = .{};
    var system = try readySystem(&operations);
    try std.testing.expectEqual(Availability.available, system.receipt.availability);
    try std.testing.expectEqual(CapabilityStage.complete, system.receipt.stage);
    try std.testing.expectEqual(abi.api_version, system.receipt.api_version);
    try std.testing.expectEqual(@as(u32, 4096), system.receipt.run_mapping_bytes);
    try std.testing.expectEqual(@as(u32, 32), system.receipt.extensions.memory_slots);
    try std.testing.expectEqual(@as(u32, 4), system.receipt.extensions.maximum_vcpus);
    try std.testing.expectEqual(@as(u32, 32), system.memorySlotCapacity());
    try std.testing.expect(system.supportsReadOnlyMemory());

    system.deinit();
    system.deinit();
    try std.testing.expectEqual(@as(usize, 1), operations.descriptorCloseCount(10));
}

test "KVM owners route memory run and state through typed controls" {
    var operations: FakeOperations = .{};
    var system = try readySystem(&operations);
    defer system.deinit();
    var vm = try system.createVm(0);
    defer vm.deinit();

    var guest: [page_size]u8 align(page_size) = @splat(0);
    try vm.registerMemory(.{
        .slot = 3,
        .guest_physical_address = 0x4000,
        .memory = guest[0..],
        .flags = .{ .read_only = true },
    });
    try std.testing.expectEqual(@as(u32, 3), operations.registered_region.?.slot);
    const registered = operations.registered_region.?;
    try std.testing.expectEqual(@as(u64, 0x4000), registered.guest_physical_address);
    try std.testing.expectEqual(@as(u64, page_size), registered.memory_size);
    try std.testing.expectEqual(@intFromPtr(&guest), registered.userspace_address);
    try vm.unregisterMemory(3);
    try std.testing.expectEqual(@as(u64, 0), operations.registered_region.?.memory_size);

    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();
    try vcpu.setRunControls(.{
        .request_interrupt_window = true,
        .cr8 = 3,
        .apic_base = 0xfee00000,
    });
    try vcpu.setImmediateExit(false);
    const before_run = try vcpu.runStatus();
    try std.testing.expectEqual(@as(u64, 3), before_run.cr8);
    try std.testing.expectEqual(@as(u64, 0xfee00000), before_run.apic_base);
    const run_exit = try vcpu.run();
    try std.testing.expectEqual(.halted, std.meta.activeTag(run_exit));

    var snapshot = try vcpu.capture(.all);
    try std.testing.expectEqual(@as(u64, 0x1234), snapshot.registers.rip);
    try vcpu.restore(&snapshot);

    const Msrs = abi.MsrBuffer(2);
    var msrs = try Msrs.init(&.{ 0x10, 0x1b });
    try vcpu.readMsrs(&msrs);
    try std.testing.expectEqual(@as(u64, 0x1000), msrs.entries[0].data);
    try vcpu.writeMsrs(&msrs);

    const Cpuids = abi.CpuidBuffer(4);
    var cpuids = Cpuids.init();
    try system.supportedCpuid(&cpuids);
    try vcpu.readCpuid(&cpuids);
    try vcpu.writeCpuid(&cpuids);

    const clock = try vm.getClock();
    try std.testing.expectEqual(@as(u64, 99), clock.clock);
    try vm.setClock(&clock);

    vcpu.deinit();
    vm.deinit();
    system.deinit();
    const tail = operations.records[operations.record_count - 4 .. operations.record_count];
    try std.testing.expectEqual(TestAction.unmap, tail[0].action);
    try std.testing.expectEqual(TestAction.close, tail[1].action);
    try std.testing.expectEqual(@as(Descriptor, 30), tail[1].descriptor);
    try std.testing.expectEqual(@as(Descriptor, 20), tail[2].descriptor);
    try std.testing.expectEqual(@as(Descriptor, 10), tail[3].descriptor);
}

test "KVM vcpu map failure closes only the new descriptor" {
    var operations: FakeOperations = .{ .map_failure = .NOMEM };
    var system = try readySystem(&operations);
    defer system.deinit();
    var vm = try system.createVm(0);
    defer vm.deinit();

    try std.testing.expectError(error.ResourceLimit, vm.createVcpu(0));
    try std.testing.expectEqual(@as(usize, 1), operations.descriptorCloseCount(30));
    try std.testing.expectEqual(@as(usize, 0), operations.actionCount(.unmap));
    try std.testing.expectEqual(@as(usize, 0), operations.descriptorCloseCount(20));
    try std.testing.expectEqual(@as(usize, 0), operations.descriptorCloseCount(10));
}

test "KVM owners reject capacity violations before kernel control" {
    var operations: FakeOperations = .{};
    var system = try readySystem(&operations);
    defer system.deinit();
    var vm = try system.createVm(0);
    defer vm.deinit();
    const controls_before = operations.actionCount(.control);

    var guest: [page_size]u8 align(page_size) = @splat(0);
    try std.testing.expectError(error.InvalidSlot, vm.registerMemory(.{
        .slot = vm.extensions.memory_slots,
        .guest_physical_address = 0,
        .memory = guest[0..],
    }));
    vm.extensions.read_only_memory = 0;
    try std.testing.expectError(error.UnsupportedFlags, vm.registerMemory(.{
        .slot = 0,
        .guest_physical_address = 0,
        .memory = guest[0..],
        .flags = .{ .read_only = true },
    }));
    try std.testing.expectError(error.InvalidAlignment, vm.registerMemory(.{
        .slot = 0,
        .guest_physical_address = 1,
        .memory = guest[0..],
    }));
    try std.testing.expectError(
        error.UnsupportedOperation,
        vm.createVcpu(vm.extensions.maximum_vcpu_id),
    );
    try std.testing.expectEqual(controls_before, operations.actionCount(.control));
}

test "KVM state buffers and run interruption fail before unsafe reuse" {
    var operations: FakeOperations = .{};
    var system = try readySystem(&operations);
    defer system.deinit();
    var vm = try system.createVm(0);
    defer vm.deinit();
    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();

    const Msrs = abi.MsrBuffer(1);
    var msrs = try Msrs.init(&.{0x10});
    msrs.count = 2;
    try std.testing.expectError(error.CapacityExceeded, vcpu.readMsrs(&msrs));
    vcpu.extensions.xsave = 0;
    try std.testing.expectError(error.UnsupportedState, vcpu.capture(.{ .xsave = true }));
    vcpu.extensions.immediate_exit = 0;
    try std.testing.expectError(error.UnsupportedOperation, vcpu.setImmediateExit(true));

    operations.control_failure_request = abi.request.run;
    operations.control_failure = .INTR;
    try std.testing.expectError(error.Interrupted, vcpu.run());
}
