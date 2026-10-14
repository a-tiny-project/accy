const std = @import("std");
const x86 = @import("root.zig");

pub const RegisterBank = enum(u1) {
    gpr = 0,
    vector = 1,
};

pub const RegisterLane = enum(u3) {
    low8 = 0,
    high8 = 1,
    word = 2,
    dword = 3,
    qword = 4,
    vector128 = 5,

    pub fn bytes(self: RegisterLane) u8 {
        return switch (self) {
            .low8, .high8 => 1,
            .word => 2,
            .dword => 4,
            .qword => 8,
            .vector128 => 16,
        };
    }
};

pub const Register = struct {
    bank: RegisterBank = .gpr,
    number: u4 = 0,
    lane: RegisterLane = .qword,

    pub fn role(self: Register) x86.Role {
        if (self.bank == .vector or self.lane == .high8) return .ordinary;
        return switch (self.number) {
            4 => .rsp,
            5 => .rbp,
            else => .ordinary,
        };
    }
};

pub const RegisterAccess = struct {
    register: Register = .{},
    access: x86.Access = .none,
};

pub const Segment = enum(u3) {
    none = 0,
    es = 1,
    cs = 2,
    ss = 3,
    ds = 4,
    fs = 5,
    gs = 6,

    pub fn prefixByte(self: Segment) u8 {
        return switch (self) {
            .none => 0,
            .es => 0x26,
            .cs => 0x2e,
            .ss => 0x36,
            .ds => 0x3e,
            .fs => 0x64,
            .gs => 0x65,
        };
    }
};

pub const Scale = enum(u2) {
    one = 0,
    two = 1,
    four = 2,
    eight = 3,

    pub fn factor(self: Scale) u4 {
        return @as(u4, 1) << @backingInt(self);
    }
};

pub const Memory = struct {
    kind: x86.AddressKind,
    width: x86.Width = .none,
    base: ?Register = null,
    index: ?Register = null,
    scale: Scale = .one,
    displacement: i32 = 0,
    segment: Segment = .none,
};

pub const Operand = union(enum) {
    none,
    register: Register,
    memory: Memory,
};

pub const ImmediateExtension = enum(u1) {
    none = 0,
    sign = 1,
};

pub const Immediate = struct {
    value: u64,
    encoded_bytes: u4,
    extension: ImmediateExtension,

    pub fn signed(self: Immediate) i64 {
        std.debug.assert(std.math.isPowerOfTwo(self.encoded_bytes));
        std.debug.assert(self.encoded_bytes <= 8);
        return switch (self.encoded_bytes) {
            1 => @as(i8, @bitCast(@as(u8, @truncate(self.value)))),
            2 => @as(i16, @bitCast(@as(u16, @truncate(self.value)))),
            4 => @as(i32, @bitCast(@as(u32, @truncate(self.value)))),
            8 => @bitCast(self.value),
            else => unreachable,
        };
    }
};
