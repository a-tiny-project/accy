const abi = @import("abi.zig");

pub const Parts = struct {
    registers: bool = true,
    special_registers: bool = true,
    fpu: bool = false,
    events: bool = false,
    debug_registers: bool = false,
    xsave: bool = false,
    xcrs: bool = false,
    multiprocessor: bool = false,

    pub const basic: Parts = .{};
    pub const all: Parts = .{
        .fpu = true,
        .events = true,
        .debug_registers = true,
        .xsave = true,
        .xcrs = true,
        .multiprocessor = true,
    };
};

pub const Fixed = struct {
    valid: Parts,
    registers: abi.Registers,
    special_registers: abi.SpecialRegisters,
    fpu: abi.Fpu,
    events: abi.VcpuEvents,
    debug_registers: abi.DebugRegisters,
    xsave: abi.Xsave,
    xcrs: abi.Xcrs,
    multiprocessor: abi.MpState,
};
