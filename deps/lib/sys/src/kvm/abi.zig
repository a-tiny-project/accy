const std = @import("std");

pub const api_version: u32 = 12;
pub const device_path = "/dev/kvm";
pub const minimum_run_bytes: usize = 2352;
pub const run_union_offset: usize = 32;
pub const maximum_exit_data: usize = 16;
pub const maximum_xcrs: usize = 16;

const ioctl_type: u32 = 0xae;
const direction_none: u32 = 0;
const direction_write: u32 = 1;
const direction_read: u32 = 2;

fn ioctl(direction: u32, number: u8, size: usize) u32 {
    std.debug.assert(direction <= direction_read | direction_write);
    std.debug.assert(size < 1 << 14);
    return (direction << 30) |
        (@as(u32, @intCast(size)) << 16) |
        (ioctl_type << 8) |
        number;
}

fn io(number: u8) u32 {
    return ioctl(direction_none, number, 0);
}

fn ior(number: u8, comptime T: type) u32 {
    return ioctl(direction_read, number, @sizeOf(T));
}

fn iow(number: u8, comptime T: type) u32 {
    return ioctl(direction_write, number, @sizeOf(T));
}

fn iowr(number: u8, comptime T: type) u32 {
    return ioctl(direction_read | direction_write, number, @sizeOf(T));
}

pub const UserMemoryRegion = extern struct {
    slot: u32,
    flags: u32,
    guest_physical_address: u64,
    memory_size: u64,
    userspace_address: u64,
};

pub const RunHeader = extern struct {
    request_interrupt_window: u8,
    immediate_exit: u8,
    padding: [6]u8,
    exit_reason: u32,
    ready_for_interrupt_injection: u8,
    interrupts_enabled: u8,
    flags: u16,
    cr8: u64,
    apic_base: u64,
};

pub const Registers = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rsp: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
};

pub const Segment = extern struct {
    base: u64,
    limit: u32,
    selector: u16,
    kind: u8,
    present: u8,
    privilege: u8,
    default_operand_size: u8,
    system: u8,
    long_mode: u8,
    granularity: u8,
    available: u8,
    unusable: u8,
    padding: u8,
};

pub const DescriptorTable = extern struct {
    base: u64,
    limit: u16,
    padding: [3]u16,
};

pub const SpecialRegisters = extern struct {
    cs: Segment,
    ds: Segment,
    es: Segment,
    fs: Segment,
    gs: Segment,
    ss: Segment,
    tr: Segment,
    ldt: Segment,
    gdt: DescriptorTable,
    idt: DescriptorTable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,
};

pub const Fpu = extern struct {
    floating_point_registers: [8][16]u8,
    control_word: u16,
    status_word: u16,
    tag_word: u8,
    padding_1: u8,
    last_opcode: u16,
    last_instruction_pointer: u64,
    last_data_pointer: u64,
    xmm: [16][16]u8,
    mxcsr: u32,
    padding_2: u32,
};

pub const MsrEntry = extern struct {
    index: u32,
    reserved: u32,
    data: u64,
};

pub const MsrHeader = extern struct {
    count: u32,
    padding: u32,
};

pub fn MsrBuffer(comptime capacity: usize) type {
    if (capacity > std.math.maxInt(u32)) @compileError("MSR capacity exceeds KVM ABI");
    return extern struct {
        pub const entry_capacity = capacity;

        count: u32,
        padding: u32,
        entries: [capacity]MsrEntry,

        pub fn init(indices: []const u32) error{TooManyEntries}!@This() {
            if (indices.len > capacity) return error.TooManyEntries;
            var result = std.mem.zeroes(@This());
            result.count = @intCast(indices.len);
            for (indices, 0..) |index, entry_index| {
                result.entries[entry_index].index = index;
            }
            return result;
        }

        pub fn values(self: *@This()) []MsrEntry {
            std.debug.assert(self.count <= capacity);
            const len: usize = @intCast(self.count);
            return self.entries[0..len];
        }

        pub fn valuesConst(self: *const @This()) []const MsrEntry {
            std.debug.assert(self.count <= capacity);
            const len: usize = @intCast(self.count);
            return self.entries[0..len];
        }
    };
}

pub const CpuidEntry = extern struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    padding: [3]u32,
};

pub const CpuidHeader = extern struct {
    count: u32,
    padding: u32,
};

pub fn CpuidBuffer(comptime capacity: usize) type {
    if (capacity > std.math.maxInt(u32)) @compileError("CPUID capacity exceeds KVM ABI");
    return extern struct {
        pub const entry_capacity = capacity;

        count: u32,
        padding: u32,
        entries: [capacity]CpuidEntry,

        pub fn init() @This() {
            var result = std.mem.zeroes(@This());
            result.count = @intCast(capacity);
            return result;
        }

        pub fn values(self: *@This()) []CpuidEntry {
            std.debug.assert(self.count <= capacity);
            const len: usize = @intCast(self.count);
            return self.entries[0..len];
        }

        pub fn valuesConst(self: *const @This()) []const CpuidEntry {
            std.debug.assert(self.count <= capacity);
            const len: usize = @intCast(self.count);
            return self.entries[0..len];
        }
    };
}

pub const MpState = extern struct {
    state: u32,
};

pub const ExceptionEvent = extern struct {
    injected: u8,
    number: u8,
    has_error_code: u8,
    pending: u8,
    error_code: u32,
};

pub const InterruptEvent = extern struct {
    injected: u8,
    number: u8,
    software: u8,
    shadow: u8,
};

pub const NmiEvent = extern struct {
    injected: u8,
    pending: u8,
    masked: u8,
    padding: u8,
};

pub const SmiEvent = extern struct {
    system_management_mode: u8,
    pending: u8,
    inside_nmi: u8,
    latched_init: u8,
};

pub const TripleFaultEvent = extern struct {
    pending: u8,
};

pub const VcpuEvents = extern struct {
    exception: ExceptionEvent,
    interrupt: InterruptEvent,
    nmi: NmiEvent,
    sipi_vector: u32,
    flags: u32,
    smi: SmiEvent,
    triple_fault: TripleFaultEvent,
    reserved: [26]u8,
    exception_has_payload: u8,
    exception_payload: u64,
};

pub const DebugRegisters = extern struct {
    breakpoint_address: [4]u64,
    status: u64,
    control: u64,
    flags: u64,
    reserved: [9]u64,
};

pub const Xsave = extern struct {
    region: [1024]u32,
};

pub const Xcr = extern struct {
    index: u32,
    reserved: u32,
    value: u64,
};

pub const Xcrs = extern struct {
    count: u32,
    flags: u32,
    entries: [maximum_xcrs]Xcr,
    padding: [16]u64,
};

pub const Clock = extern struct {
    clock: u64,
    flags: u32,
    padding_0: u32,
    realtime: u64,
    host_tsc: u64,
    padding: [4]u32,
};

pub const request = struct {
    pub const get_api_version = io(0x00);
    pub const create_vm = io(0x01);
    pub const check_extension = io(0x03);
    pub const get_vcpu_mmap_size = io(0x04);
    pub const get_supported_cpuid = iowr(0x05, CpuidHeader);
    pub const create_vcpu = io(0x41);
    pub const set_user_memory_region = iow(0x46, UserMemoryRegion);
    pub const set_clock = iow(0x7b, Clock);
    pub const get_clock = ior(0x7c, Clock);
    pub const run = io(0x80);
    pub const get_registers = ior(0x81, Registers);
    pub const set_registers = iow(0x82, Registers);
    pub const get_special_registers = ior(0x83, SpecialRegisters);
    pub const set_special_registers = iow(0x84, SpecialRegisters);
    pub const get_msrs = iowr(0x88, MsrHeader);
    pub const set_msrs = iow(0x89, MsrHeader);
    pub const get_fpu = ior(0x8c, Fpu);
    pub const set_fpu = iow(0x8d, Fpu);
    pub const set_cpuid = iow(0x90, CpuidHeader);
    pub const get_cpuid = iowr(0x91, CpuidHeader);
    pub const get_mp_state = ior(0x98, MpState);
    pub const set_mp_state = iow(0x99, MpState);
    pub const get_vcpu_events = ior(0x9f, VcpuEvents);
    pub const set_vcpu_events = iow(0xa0, VcpuEvents);
    pub const get_debug_registers = ior(0xa1, DebugRegisters);
    pub const set_debug_registers = iow(0xa2, DebugRegisters);
    pub const get_xsave = ior(0xa4, Xsave);
    pub const set_xsave = iow(0xa5, Xsave);
    pub const get_xcrs = ior(0xa6, Xcrs);
    pub const set_xcrs = iow(0xa7, Xcrs);
};

pub const Extension = enum(u32) {
    user_memory = 3,
    extended_cpuid = 7,
    recommended_vcpus = 9,
    memory_slots = 10,
    mp_state = 14,
    vcpu_events = 41,
    debug_registers = 50,
    xsave = 55,
    xcrs = 56,
    maximum_vcpus = 66,
    read_only_memory = 81,
    maximum_vcpu_id = 128,
    immediate_exit = 136,
    special_registers_2 = 200,
    xsave_2 = 208,
};

pub const MemoryFlags = struct {
    log_dirty_pages: bool = false,
    read_only: bool = false,

    pub fn bits(self: MemoryFlags) u32 {
        return @as(u32, @intFromBool(self.log_dirty_pages)) |
            (@as(u32, @intFromBool(self.read_only)) << 1);
    }
};

test "Linux x86 KVM ABI layouts match the UAPI" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(UserMemoryRegion));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RunHeader));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(Registers));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Segment));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DescriptorTable));
    try std.testing.expectEqual(@as(usize, 312), @sizeOf(SpecialRegisters));
    try std.testing.expectEqual(@as(usize, 416), @sizeOf(Fpu));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(VcpuEvents));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(DebugRegisters));
    try std.testing.expectEqual(@as(usize, 4096), @sizeOf(Xsave));
    try std.testing.expectEqual(@as(usize, 392), @sizeOf(Xcrs));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Clock));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(MsrEntry));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(CpuidEntry));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(MpState));
}

test "Linux x86 KVM ABI alignments and run offsets match the UAPI" {
    try std.testing.expectEqual(@as(usize, 8), @alignOf(UserMemoryRegion));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(RunHeader));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(SpecialRegisters));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(VcpuEvents));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(RunHeader, "exit_reason"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(RunHeader, "cr8"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RunHeader, "apic_base"));
    try std.testing.expectEqual(@as(usize, 32), run_union_offset);
}

test "Linux x86 KVM ioctl numbers match the UAPI" {
    try std.testing.expectEqual(@as(u32, 0x0000ae00), request.get_api_version);
    try std.testing.expectEqual(@as(u32, 0x0000ae01), request.create_vm);
    try std.testing.expectEqual(@as(u32, 0x0000ae03), request.check_extension);
    try std.testing.expectEqual(@as(u32, 0x0000ae04), request.get_vcpu_mmap_size);
    try std.testing.expectEqual(@as(u32, 0xc008ae05), request.get_supported_cpuid);
    try std.testing.expectEqual(@as(u32, 0x0000ae41), request.create_vcpu);
    try std.testing.expectEqual(@as(u32, 0x4020ae46), request.set_user_memory_region);
    try std.testing.expectEqual(@as(u32, 0x4030ae7b), request.set_clock);
    try std.testing.expectEqual(@as(u32, 0x8030ae7c), request.get_clock);
    try std.testing.expectEqual(@as(u32, 0x0000ae80), request.run);
    try std.testing.expectEqual(@as(u32, 0x8090ae81), request.get_registers);
    try std.testing.expectEqual(@as(u32, 0x4090ae82), request.set_registers);
    try std.testing.expectEqual(@as(u32, 0x8138ae83), request.get_special_registers);
    try std.testing.expectEqual(@as(u32, 0x4138ae84), request.set_special_registers);
    try std.testing.expectEqual(@as(u32, 0xc008ae88), request.get_msrs);
    try std.testing.expectEqual(@as(u32, 0x4008ae89), request.set_msrs);
    try std.testing.expectEqual(@as(u32, 0x81a0ae8c), request.get_fpu);
    try std.testing.expectEqual(@as(u32, 0x41a0ae8d), request.set_fpu);
    try std.testing.expectEqual(@as(u32, 0x4008ae90), request.set_cpuid);
    try std.testing.expectEqual(@as(u32, 0xc008ae91), request.get_cpuid);
    try std.testing.expectEqual(@as(u32, 0x8004ae98), request.get_mp_state);
    try std.testing.expectEqual(@as(u32, 0x4004ae99), request.set_mp_state);
    try std.testing.expectEqual(@as(u32, 0x8040ae9f), request.get_vcpu_events);
    try std.testing.expectEqual(@as(u32, 0x4040aea0), request.set_vcpu_events);
    try std.testing.expectEqual(@as(u32, 0x8080aea1), request.get_debug_registers);
    try std.testing.expectEqual(@as(u32, 0x4080aea2), request.set_debug_registers);
    try std.testing.expectEqual(@as(u32, 0x9000aea4), request.get_xsave);
    try std.testing.expectEqual(@as(u32, 0x5000aea5), request.set_xsave);
    try std.testing.expectEqual(@as(u32, 0x8188aea6), request.get_xcrs);
    try std.testing.expectEqual(@as(u32, 0x4188aea7), request.set_xcrs);
}

test "static variable-state buffers reject capacity plus one" {
    const Buffer = MsrBuffer(2);
    _ = try Buffer.init(&.{ 0x10, 0x1b });
    try std.testing.expectError(error.TooManyEntries, Buffer.init(&.{ 1, 2, 3 }));

    const Cpuids = CpuidBuffer(3);
    const cpuids = Cpuids.init();
    try std.testing.expectEqual(@as(u32, 3), cpuids.count);
}
