const std = @import("std");
const abi = @import("abi.zig");

pub const DecodeError = error{
    InvalidDirection,
    InvalidPayload,
    MappingTooSmall,
};

pub const Direction = enum(u8) {
    input = 0,
    output = 1,
};

pub const Reason = enum(u32) {
    unknown = 0,
    exception = 1,
    io = 2,
    hypercall = 3,
    debug = 4,
    halted = 5,
    mmio = 6,
    interrupt_window_open = 7,
    shutdown = 8,
    fail_entry = 9,
    interrupted = 10,
    set_task_priority = 11,
    task_priority_access = 12,
    s390_intercept = 13,
    s390_reset = 14,
    dcr = 15,
    non_maskable_interrupt = 16,
    internal_error = 17,
    osi = 18,
    papr_hypercall = 19,
    s390_ucontrol = 20,
    watchdog = 21,
    s390_tsch = 22,
    epr = 23,
    system_event = 24,
    s390_stsi = 25,
    ioapic_eoi = 26,
    hyperv = 27,
    arm_nisv = 28,
    msr_read = 29,
    msr_write = 30,
    dirty_ring_full = 31,
    application_processor_reset_hold = 32,
    bus_lock = 33,
    xen = 34,
    riscv_sbi = 35,
    riscv_csr = 36,
    notify = 37,
    loongarch_iocsr = 38,
    memory_fault = 39,
    tdx = 40,
    arm_sea = 41,
    arm_ldst64b = 42,
    snp_request_certificates = 43,
    _,
};

pub const SystemEventKind = enum(u32) {
    shutdown = 1,
    reset = 2,
    crash = 3,
    wakeup = 4,
    @"suspend" = 5,
    encrypted_guest_termination = 6,
    confidential_guest_fatal = 7,
    _,
};

pub const Unknown = struct {
    hardware_reason: u64,
};

pub const Exception = struct {
    number: u32,
    error_code: u32,
};

pub const Io = struct {
    direction: Direction,
    size: u8,
    port: u16,
    count: u32,
    data: []u8,
};

pub const Debug = struct {
    exception: u32,
    program_counter: u64,
    dr6: u64,
    dr7: u64,
};

pub const Mmio = struct {
    physical_address: u64,
    data: []u8,
    write: bool,
};

pub const Hypercall = struct {
    number: u64,
    arguments: [6]u64,
    result: *u64,
    flags: *u64,
};

pub const FailEntry = struct {
    hardware_reason: u64,
    cpu: u32,
};

pub const TaskPriorityAccess = struct {
    instruction_pointer: u64,
    write: bool,
};

pub const InternalError = struct {
    kind: u32,
    data: []const u64,
};

pub const SystemEvent = struct {
    kind: SystemEventKind,
    data: []u64,
};

pub const Msr = struct {
    error_value: *u8,
    reason: u32,
    index: u32,
    data: *u64,
};

pub const Notify = struct {
    flags: u32,
};

pub const MemoryFault = struct {
    flags: u64,
    guest_physical_address: u64,
    size: u64,
};

pub const Exit = union(enum) {
    unknown: Unknown,
    exception: Exception,
    io: Io,
    hypercall: Hypercall,
    debug: Debug,
    halted,
    mmio: Mmio,
    interrupt_window_open,
    shutdown,
    fail_entry: FailEntry,
    interrupted,
    set_task_priority,
    task_priority_access: TaskPriorityAccess,
    non_maskable_interrupt,
    internal_error: InternalError,
    watchdog,
    system_event: SystemEvent,
    ioapic_eoi: u8,
    msr_read: Msr,
    msr_write: Msr,
    dirty_ring_full,
    application_processor_reset_hold,
    bus_lock,
    notify: Notify,
    memory_fault: MemoryFault,
    unhandled: Reason,
};

const UnknownRaw = extern struct {
    hardware_reason: u64,
};

const ExceptionRaw = extern struct {
    number: u32,
    error_code: u32,
};

const IoRaw = extern struct {
    direction: u8,
    size: u8,
    port: u16,
    count: u32,
    data_offset: u64,
};

const DebugRaw = extern struct {
    exception: u32,
    padding: u32,
    program_counter: u64,
    dr6: u64,
    dr7: u64,
};

const MmioRaw = extern struct {
    physical_address: u64,
    data: [8]u8,
    length: u32,
    write: u8,
};

const HypercallRaw = extern struct {
    number: u64,
    arguments: [6]u64,
    result: u64,
    flags: u64,
};

const FailEntryRaw = extern struct {
    hardware_reason: u64,
    cpu: u32,
};

const TaskPriorityAccessRaw = extern struct {
    instruction_pointer: u64,
    write: u32,
    padding: u32,
};

const InternalErrorRaw = extern struct {
    kind: u32,
    count: u32,
    data: [abi.maximum_exit_data]u64,
};

const SystemEventRaw = extern struct {
    kind: u32,
    count: u32,
    data: [abi.maximum_exit_data]u64,
};

const MsrRaw = extern struct {
    error_value: u8,
    padding: [7]u8,
    reason: u32,
    index: u32,
    data: u64,
};

const NotifyRaw = extern struct {
    flags: u32,
};

const MemoryFaultRaw = extern struct {
    flags: u64,
    guest_physical_address: u64,
    size: u64,
};

pub fn decode(mapping: []align(std.heap.page_size_min) u8) DecodeError!Exit {
    if (mapping.len < abi.minimum_run_bytes) return error.MappingTooSmall;
    const header = view(abi.RunHeader, mapping);
    const reason: Reason = @fromBackingInt(@intCast(header.exit_reason));
    return switch (reason) {
        .unknown => decodeUnknown(mapping),
        .exception => decodeException(mapping),
        .io => decodeIo(mapping),
        .hypercall => decodeHypercall(mapping),
        .debug => decodeDebug(mapping),
        .halted => .halted,
        .mmio => decodeMmio(mapping),
        .interrupt_window_open => .interrupt_window_open,
        .shutdown => .shutdown,
        .fail_entry => decodeFailEntry(mapping),
        .interrupted => .interrupted,
        .set_task_priority => .set_task_priority,
        .task_priority_access => decodeTaskPriorityAccess(mapping),
        .non_maskable_interrupt => .non_maskable_interrupt,
        .internal_error => decodeInternalError(mapping),
        .watchdog => .watchdog,
        .system_event => decodeSystemEvent(mapping),
        .ioapic_eoi => decodeIoapicEoi(mapping),
        .msr_read => .{ .msr_read = decodeMsr(mapping) },
        .msr_write => .{ .msr_write = decodeMsr(mapping) },
        .dirty_ring_full => .dirty_ring_full,
        .application_processor_reset_hold => .application_processor_reset_hold,
        .bus_lock => .bus_lock,
        .notify => decodeNotify(mapping),
        .memory_fault => decodeMemoryFault(mapping),
        else => .{ .unhandled = reason },
    };
}

fn decodeUnknown(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(UnknownRaw, mapping);
    return .{ .unknown = .{ .hardware_reason = raw.hardware_reason } };
}

fn decodeException(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(ExceptionRaw, mapping);
    return .{ .exception = .{ .number = raw.number, .error_code = raw.error_code } };
}

fn decodeIo(mapping: []align(std.heap.page_size_min) u8) DecodeError!Exit {
    const raw = payload(IoRaw, mapping);
    const direction: Direction = switch (raw.direction) {
        0 => .input,
        1 => .output,
        else => return error.InvalidDirection,
    };
    if (raw.size == 0 or raw.size > 8 or !std.math.isPowerOfTwo(raw.size)) {
        return error.InvalidPayload;
    }
    const byte_count = std.math.mul(usize, raw.size, raw.count) catch
        return error.InvalidPayload;
    const offset = std.math.cast(usize, raw.data_offset) orelse
        return error.InvalidPayload;
    const end = std.math.add(usize, offset, byte_count) catch
        return error.InvalidPayload;
    if (end > mapping.len) return error.InvalidPayload;
    return .{ .io = .{
        .direction = direction,
        .size = raw.size,
        .port = raw.port,
        .count = raw.count,
        .data = mapping[offset..end],
    } };
}

fn decodeDebug(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(DebugRaw, mapping);
    return .{ .debug = .{
        .exception = raw.exception,
        .program_counter = raw.program_counter,
        .dr6 = raw.dr6,
        .dr7 = raw.dr7,
    } };
}

fn decodeMmio(mapping: []align(std.heap.page_size_min) u8) DecodeError!Exit {
    const raw = payload(MmioRaw, mapping);
    if (raw.length > raw.data.len) return error.InvalidPayload;
    return .{ .mmio = .{
        .physical_address = raw.physical_address,
        .data = raw.data[0..raw.length],
        .write = raw.write != 0,
    } };
}

fn decodeHypercall(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(HypercallRaw, mapping);
    return .{ .hypercall = .{
        .number = raw.number,
        .arguments = raw.arguments,
        .result = &raw.result,
        .flags = &raw.flags,
    } };
}

fn decodeFailEntry(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(FailEntryRaw, mapping);
    return .{ .fail_entry = .{
        .hardware_reason = raw.hardware_reason,
        .cpu = raw.cpu,
    } };
}

fn decodeTaskPriorityAccess(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(TaskPriorityAccessRaw, mapping);
    return .{ .task_priority_access = .{
        .instruction_pointer = raw.instruction_pointer,
        .write = raw.write != 0,
    } };
}

fn decodeIoapicEoi(mapping: []align(std.heap.page_size_min) u8) Exit {
    return .{ .ioapic_eoi = payload(u8, mapping).* };
}

fn decodeInternalError(mapping: []align(std.heap.page_size_min) u8) DecodeError!Exit {
    const raw = payload(InternalErrorRaw, mapping);
    if (raw.count > raw.data.len) return error.InvalidPayload;
    return .{ .internal_error = .{
        .kind = raw.kind,
        .data = raw.data[0..raw.count],
    } };
}

fn decodeSystemEvent(mapping: []align(std.heap.page_size_min) u8) DecodeError!Exit {
    const raw = payload(SystemEventRaw, mapping);
    if (raw.count > raw.data.len) return error.InvalidPayload;
    return .{ .system_event = .{
        .kind = @fromBackingInt(@intCast(raw.kind)),
        .data = raw.data[0..raw.count],
    } };
}

fn decodeMsr(mapping: []align(std.heap.page_size_min) u8) Msr {
    const raw = payload(MsrRaw, mapping);
    return .{
        .error_value = &raw.error_value,
        .reason = raw.reason,
        .index = raw.index,
        .data = &raw.data,
    };
}

fn decodeNotify(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(NotifyRaw, mapping);
    return .{ .notify = .{ .flags = raw.flags } };
}

fn decodeMemoryFault(mapping: []align(std.heap.page_size_min) u8) Exit {
    const raw = payload(MemoryFaultRaw, mapping);
    return .{ .memory_fault = .{
        .flags = raw.flags,
        .guest_physical_address = raw.guest_physical_address,
        .size = raw.size,
    } };
}

fn view(comptime T: type, mapping: []align(std.heap.page_size_min) u8) *T {
    std.debug.assert(mapping.len >= @sizeOf(T));
    return @ptrCast(@alignCast(mapping.ptr));
}

fn payload(comptime T: type, mapping: []align(std.heap.page_size_min) u8) *T {
    std.debug.assert(abi.run_union_offset + @sizeOf(T) <= mapping.len);
    return @ptrCast(@alignCast(mapping.ptr + abi.run_union_offset));
}

test "run exit decoder exposes bounded port data" {
    var storage: [4096]u8 align(std.heap.page_size_min) = @splat(0);
    const mapping = storage[0..];
    view(abi.RunHeader, mapping).exit_reason = @backingInt(Reason.io);
    const raw = payload(IoRaw, mapping);
    raw.* = .{ .direction = 1, .size = 2, .port = 0x34, .count = 2, .data_offset = 256 };
    @memcpy(mapping[256..260], &[_]u8{ 1, 2, 3, 4 });

    const decoded = try decode(mapping);
    try std.testing.expectEqual(Direction.output, decoded.io.direction);
    try std.testing.expectEqual(@as(u16, 0x34), decoded.io.port);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, decoded.io.data);
}

test "run exit decoder rejects data beyond the run mapping" {
    var storage: [4096]u8 align(std.heap.page_size_min) = @splat(0);
    const mapping = storage[0..];
    view(abi.RunHeader, mapping).exit_reason = @backingInt(Reason.io);
    payload(IoRaw, mapping).* = .{
        .direction = 0,
        .size = 8,
        .port = 0,
        .count = 2,
        .data_offset = mapping.len - 8,
    };
    try std.testing.expectError(error.InvalidPayload, decode(mapping));
}

test "run exit decoder exposes bounded MMIO data for completion" {
    var storage: [4096]u8 align(std.heap.page_size_min) = @splat(0);
    const mapping = storage[0..];
    view(abi.RunHeader, mapping).exit_reason = @backingInt(Reason.mmio);
    const raw = payload(MmioRaw, mapping);
    raw.* = .{
        .physical_address = 0x4000,
        .data = .{ 1, 2, 3, 4, 0, 0, 0, 0 },
        .length = 4,
        .write = 0,
    };

    const decoded = try decode(mapping);
    try std.testing.expectEqual(@as(u64, 0x4000), decoded.mmio.physical_address);
    try std.testing.expect(!decoded.mmio.write);
    decoded.mmio.data[0] = 9;
    try std.testing.expectEqual(@as(u8, 9), raw.data[0]);
}

test "run exit decoder bounds internal and system event arrays" {
    var storage: [4096]u8 align(std.heap.page_size_min) = @splat(0);
    const mapping = storage[0..];
    view(abi.RunHeader, mapping).exit_reason = @backingInt(Reason.internal_error);
    payload(InternalErrorRaw, mapping).count = abi.maximum_exit_data + 1;
    try std.testing.expectError(error.InvalidPayload, decode(mapping));

    view(abi.RunHeader, mapping).exit_reason = @backingInt(Reason.system_event);
    const event = payload(SystemEventRaw, mapping);
    event.kind = @backingInt(SystemEventKind.reset);
    event.count = 2;
    event.data[0] = 7;
    event.data[1] = 8;
    const decoded = try decode(mapping);
    try std.testing.expectEqual(SystemEventKind.reset, decoded.system_event.kind);
    try std.testing.expectEqualSlices(u64, &.{ 7, 8 }, decoded.system_event.data);
}
