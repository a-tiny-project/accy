const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.pure();

pub const stackSwitchSupported = switch (capabilities.current.arch) {
    .x86_64, .aarch64 => true,
    else => false,
};

pub const JmpBuf = switch (capabilities.current.arch) {
    .x86_64 => extern struct {
        reg_ip: ?*anyopaque,
        reg_rbx: i64,
        reg_sp: ?*anyopaque,
        reg_rbp: ?*anyopaque,
        reg_r12: i64,
        reg_r13: i64,
        reg_r14: i64,
        reg_r15: i64,
        reg_mxcrs: u32,
        reg_fpcr: u16,
        context_padding: u16,
    },
    .aarch64 => extern struct {
        reg_x18: i64,
        reg_x19: i64,
        reg_x20: i64,
        reg_x21: i64,
        reg_x22: i64,
        reg_x23: i64,
        reg_x24: i64,
        reg_x25: i64,
        reg_x26: i64,
        reg_x27: i64,
        reg_x28: i64,
        reg_fp: ?*anyopaque,
        reg_ip: ?*anyopaque,
        reg_sp: ?*anyopaque,
        reg_fpcr: i64,
        reg_fpsr: i64,
        reg_d8: i64,
        reg_d9: i64,
        reg_d10: i64,
        reg_d11: i64,
        reg_d12: i64,
        reg_d13: i64,
        reg_d14: i64,
        reg_d15: i64,
    },
    else => extern struct {
        unsupported: usize,
    },
};

pub const UnwindFrame = extern struct {
    ip: ?*anyopaque,
};

pub const StartFn = *const fn (?*anyopaque, ?*UnwindFrame) callconv(.c) void;

pub extern fn mp_setjmp(save: *JmpBuf) callconv(.c) usize;
pub extern fn mp_longjmp(jmp: *JmpBuf) callconv(.c) noreturn;
pub extern fn mp_stack_enter(
    stack_base: [*]u8,
    stack_commit_limit: [*]u8,
    stack_limit: [*]u8,
    return_jmp: **JmpBuf,
    fun: StartFn,
    arg: ?*anyopaque,
) callconv(.c) ?*anyopaque;
