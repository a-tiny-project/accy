const std = @import("std");

pub const Encoded = enum(u5) {
    _,

    pub fn fromInt(val: u5) Encoded {
        return @fromBackingInt(@intCast(val));
    }

    pub fn toInt(self: Encoded) u5 {
        return @backingInt(self);
    }
};

pub const GPR = enum(u5) {
    x0 = 0,
    x1 = 1,
    x2 = 2,
    x3 = 3,
    x4 = 4,
    x5 = 5,
    x6 = 6,
    x7 = 7,
    x8 = 8,
    x9 = 9,
    x10 = 10,
    x11 = 11,
    x12 = 12,
    x13 = 13,
    x14 = 14,
    x15 = 15,
    x16 = 16,
    x17 = 17,
    x18 = 18,
    x19 = 19,
    x20 = 20,
    x21 = 21,
    x22 = 22,
    x23 = 23,
    x24 = 24,
    x25 = 25,
    x26 = 26,
    x27 = 27,
    x28 = 28,
    x29 = 29,
    x30 = 30,

    pub const fp = GPR.x29;
    pub const lr = GPR.x30;

    pub const arg0 = GPR.x0;
    pub const arg1 = GPR.x1;
    pub const arg2 = GPR.x2;
    pub const arg3 = GPR.x3;
    pub const arg4 = GPR.x4;
    pub const arg5 = GPR.x5;
    pub const arg6 = GPR.x6;
    pub const arg7 = GPR.x7;

    pub const ret = GPR.x0;

    pub fn encode(self: GPR) Encoded {
        return @fromBackingInt(@intCast(@backingInt(self)));
    }

    pub fn isCallerSaved(self: GPR) bool {
        const n = @backingInt(self);
        return n <= 17;
    }

    pub fn isCalleeSaved(self: GPR) bool {
        const n = @backingInt(self);
        return n >= 19 and n <= 28;
    }

    pub fn isArgument(self: GPR) bool {
        const n = @backingInt(self);
        return n <= 7;
    }

    pub fn toW(self: GPR) []const u8 {
        const names = [_][]const u8{
            "w0",  "w1",  "w2",  "w3",  "w4",  "w5",  "w6",  "w7",
            "w8",  "w9",  "w10", "w11", "w12", "w13", "w14", "w15",
            "w16", "w17", "w18", "w19", "w20", "w21", "w22", "w23",
            "w24", "w25", "w26", "w27", "w28", "w29", "w30",
        };
        return names[@backingInt(self)];
    }

    pub fn toX(self: GPR) []const u8 {
        const names = [_][]const u8{
            "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
            "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
            "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
            "x24", "x25", "x26", "x27", "x28", "x29", "x30",
        };
        return names[@backingInt(self)];
    }
};

pub const SP = struct {
    pub const encoded: Encoded = @fromBackingInt(@intCast(31));
};

pub const ZR = struct {
    pub const encoded: Encoded = @fromBackingInt(@intCast(31));
};

pub const FPR = enum(u5) {
    v0 = 0,
    v1 = 1,
    v2 = 2,
    v3 = 3,
    v4 = 4,
    v5 = 5,
    v6 = 6,
    v7 = 7,
    v8 = 8,
    v9 = 9,
    v10 = 10,
    v11 = 11,
    v12 = 12,
    v13 = 13,
    v14 = 14,
    v15 = 15,
    v16 = 16,
    v17 = 17,
    v18 = 18,
    v19 = 19,
    v20 = 20,
    v21 = 21,
    v22 = 22,
    v23 = 23,
    v24 = 24,
    v25 = 25,
    v26 = 26,
    v27 = 27,
    v28 = 28,
    v29 = 29,
    v30 = 30,
    v31 = 31,

    pub const arg0 = FPR.v0;
    pub const arg1 = FPR.v1;
    pub const arg2 = FPR.v2;
    pub const arg3 = FPR.v3;
    pub const arg4 = FPR.v4;
    pub const arg5 = FPR.v5;
    pub const arg6 = FPR.v6;
    pub const arg7 = FPR.v7;

    pub const ret = FPR.v0;

    pub fn encode(self: FPR) Encoded {
        return @fromBackingInt(@intCast(@backingInt(self)));
    }

    pub fn isCallerSaved(self: FPR) bool {
        const n = @backingInt(self);
        return n <= 7 or n >= 16;
    }

    pub fn isCalleeSaved(self: FPR) bool {
        const n = @backingInt(self);
        return n >= 8 and n <= 15;
    }

    pub fn isArgument(self: FPR) bool {
        const n = @backingInt(self);
        return n <= 7;
    }

    pub fn toS(self: FPR) []const u8 {
        const names = [_][]const u8{
            "s0",  "s1",  "s2",  "s3",  "s4",  "s5",  "s6",  "s7",
            "s8",  "s9",  "s10", "s11", "s12", "s13", "s14", "s15",
            "s16", "s17", "s18", "s19", "s20", "s21", "s22", "s23",
            "s24", "s25", "s26", "s27", "s28", "s29", "s30", "s31",
        };
        return names[@backingInt(self)];
    }

    pub fn toD(self: FPR) []const u8 {
        const names = [_][]const u8{
            "d0",  "d1",  "d2",  "d3",  "d4",  "d5",  "d6",  "d7",
            "d8",  "d9",  "d10", "d11", "d12", "d13", "d14", "d15",
            "d16", "d17", "d18", "d19", "d20", "d21", "d22", "d23",
            "d24", "d25", "d26", "d27", "d28", "d29", "d30", "d31",
        };
        return names[@backingInt(self)];
    }
};

pub const GPRSize = enum(u1) {
    w = 0,
    x = 1,

    pub fn bits(self: GPRSize) u8 {
        return switch (self) {
            .w => 32,
            .x => 64,
        };
    }
};

pub const FPRSize = enum(u2) {
    s = 0b00,
    d = 0b01,
    h = 0b11,

    pub fn bits(self: FPRSize) u8 {
        return switch (self) {
            .h => 16,
            .s => 32,
            .d => 64,
        };
    }
};

pub const Register = union(enum) {
    gpr: GPR,
    fpr: FPR,
    sp,
    zr,

    pub fn encode(self: Register) Encoded {
        return switch (self) {
            .gpr => |r| r.encode(),
            .fpr => |r| r.encode(),
            .sp => SP.encoded,
            .zr => ZR.encoded,
        };
    }
};

pub const allocatable_gprs = [_]GPR{
    .x0,  .x1,  .x2,  .x3,  .x4,  .x5,  .x6,  .x7,
    .x8,  .x9,  .x10, .x11, .x12, .x13, .x14, .x15,
    .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26,
    .x27, .x28,
};

pub const callee_saved_gprs = [_]GPR{
    .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28,
};

pub const allocatable_fprs = [_]FPR{
    .v0,  .v1,  .v2,  .v3,  .v4,  .v5,  .v6,  .v7,
    .v8,  .v9,  .v10, .v11, .v12, .v13, .v14, .v15,
    .v16, .v17, .v18, .v19, .v20, .v21, .v22, .v23,
    .v24, .v25, .v26, .v27, .v28, .v29, .v30, .v31,
};

pub const callee_saved_fprs = [_]FPR{
    .v8, .v9, .v10, .v11, .v12, .v13, .v14, .v15,
};
