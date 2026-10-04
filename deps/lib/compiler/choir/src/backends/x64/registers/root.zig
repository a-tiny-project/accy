pub const Encoded = enum(u4) {
    _,

    pub fn fromInt(val: u4) Encoded {
        return @fromBackingInt(@intCast(val));
    }

    pub fn toInt(self: Encoded) u4 {
        return @backingInt(self);
    }
};

pub const GPR = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    pub const sp = GPR.rsp;
    pub const fp = GPR.rbp;

    pub const arg0 = GPR.rdi;
    pub const arg1 = GPR.rsi;
    pub const arg2 = GPR.rdx;
    pub const arg3 = GPR.rcx;
    pub const arg4 = GPR.r8;
    pub const arg5 = GPR.r9;

    pub const ret = GPR.rax;

    pub fn id(self: GPR) u4 {
        return @backingInt(self);
    }

    pub fn low3(self: GPR) u3 {
        return @as(u3, @truncate(self.id()));
    }

    pub fn rexBit(self: GPR) bool {
        return (self.id() & 0x8) != 0;
    }

    pub fn encode(self: GPR) Encoded {
        return @fromBackingInt(@intCast(self.id()));
    }

    pub fn isCallerSaved(self: GPR) bool {
        return switch (self) {
            .rbx, .rbp, .r12, .r13, .r14, .r15 => false,
            else => true,
        };
    }

    pub fn isCalleeSaved(self: GPR) bool {
        return switch (self) {
            .rbx, .rbp, .r12, .r13, .r14, .r15 => true,
            else => false,
        };
    }

    pub fn isArgument(self: GPR) bool {
        return switch (self) {
            .rdi, .rsi, .rdx, .rcx, .r8, .r9 => true,
            else => false,
        };
    }
};

pub const XMM = enum(u4) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,
    xmm4 = 4,
    xmm5 = 5,
    xmm6 = 6,
    xmm7 = 7,
    xmm8 = 8,
    xmm9 = 9,
    xmm10 = 10,
    xmm11 = 11,
    xmm12 = 12,
    xmm13 = 13,
    xmm14 = 14,
    xmm15 = 15,

    pub const arg0 = XMM.xmm0;
    pub const arg1 = XMM.xmm1;
    pub const arg2 = XMM.xmm2;
    pub const arg3 = XMM.xmm3;
    pub const arg4 = XMM.xmm4;
    pub const arg5 = XMM.xmm5;
    pub const arg6 = XMM.xmm6;
    pub const arg7 = XMM.xmm7;

    pub const ret = XMM.xmm0;

    pub fn id(self: XMM) u4 {
        return @backingInt(self);
    }

    pub fn low3(self: XMM) u3 {
        return @as(u3, @truncate(self.id()));
    }

    pub fn rexBit(self: XMM) bool {
        return (self.id() & 0x8) != 0;
    }

    pub fn encode(self: XMM) Encoded {
        return @fromBackingInt(@intCast(self.id()));
    }

    pub fn isCallerSaved(self: XMM) bool {
        _ = self;
        return true;
    }

    pub fn isCalleeSaved(self: XMM) bool {
        _ = self;
        return false;
    }

    pub fn isArgument(self: XMM) bool {
        return self.id() <= 7;
    }
};

pub const Register = union(enum) {
    gpr: GPR,
    xmm: XMM,
};

pub const allocatable_gprs = [_]GPR{
    .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11,
};

pub const callee_saved_gprs = [_]GPR{
    .rbx, .rbp, .r12, .r13, .r14, .r15,
};

pub const allocatable_xmms = [_]XMM{
    .xmm0, .xmm1, .xmm2,  .xmm3,  .xmm4,  .xmm5,  .xmm6,  .xmm7,
    .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13, .xmm14, .xmm15,
};

pub const callee_saved_xmms = [_]XMM{};
