const std = @import("std");

pub const FormKey = u64;

pub const Prefix = enum(u5) {
    none = 0,
    rex = 1,
    rex_b = 2,
    rex_r = 3,
    rex_rb = 4,
    rex_rxb = 5,
    rex_w = 6,
    rex_wb = 7,
    rex_wr = 8,
    rex_wrb = 9,
    operand16 = 10,
    operand16_cs = 11,
    operand16_rex_b = 12,
    operand16_rex_r = 13,
    operand16_rex_rb = 14,
    lock_rex = 15,
    lock_rex_b = 16,
    lock_rex_w = 17,
    repeat = 18,
    repeat_rex_b = 19,
    rex_x = 20,
    rex_xb = 21,
    rex_rx = 22,
    rex_wx = 23,
    rex_wxb = 24,
    rex_wrx = 25,
    rex_wrxb = 26,
    repeat_rex_w = 27,
    operand16_2_cs = 28,
    operand16_4_cs = 29,
    operand16_5_cs = 30,
    operand16_3_cs = 31,

    pub fn bytes(self: Prefix) []const u8 {
        return switch (self) {
            .none => &.{},
            .rex => &.{0x40},
            .rex_b => &.{0x41},
            .rex_r => &.{0x44},
            .rex_rb => &.{0x45},
            .rex_rxb => &.{0x47},
            .rex_w => &.{0x48},
            .rex_wb => &.{0x49},
            .rex_wr => &.{0x4c},
            .rex_wrb => &.{0x4d},
            .operand16 => &.{0x66},
            .operand16_cs => &.{ 0x66, 0x2e },
            .operand16_rex_b => &.{ 0x66, 0x41 },
            .operand16_rex_r => &.{ 0x66, 0x44 },
            .operand16_rex_rb => &.{ 0x66, 0x45 },
            .lock_rex => &.{ 0xf0, 0x40 },
            .lock_rex_b => &.{ 0xf0, 0x41 },
            .lock_rex_w => &.{ 0xf0, 0x48 },
            .repeat => &.{0xf3},
            .repeat_rex_b => &.{ 0xf3, 0x41 },
            .rex_x => &.{0x42},
            .rex_xb => &.{0x43},
            .rex_rx => &.{0x46},
            .rex_wx => &.{0x4a},
            .rex_wxb => &.{0x4b},
            .rex_wrx => &.{0x4e},
            .rex_wrxb => &.{0x4f},
            .repeat_rex_w => &.{ 0xf3, 0x48 },
            .operand16_2_cs => &.{ 0x66, 0x66, 0x2e },
            .operand16_4_cs => &.{ 0x66, 0x66, 0x66, 0x66, 0x2e },
            .operand16_5_cs => &.{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x2e },
            .operand16_3_cs => &.{ 0x66, 0x66, 0x66, 0x2e },
        };
    }

    pub fn fromBytes(value: []const u8) ?Prefix {
        inline for (@typeInfo(Prefix).@"enum".field_names) |name| {
            const candidate: Prefix = @fromBackingInt(@intCast(@backingInt(@field(Prefix, name))));
            if (std.mem.eql(u8, value, candidate.bytes())) return candidate;
        }
        return null;
    }

    pub fn rexByte(self: Prefix) u8 {
        return switch (self) {
            .rex, .lock_rex => 0x40,
            .rex_b, .operand16_rex_b, .lock_rex_b, .repeat_rex_b => 0x41,
            .rex_x => 0x42,
            .rex_xb => 0x43,
            .rex_r, .operand16_rex_r => 0x44,
            .rex_rb, .operand16_rex_rb => 0x45,
            .rex_rx => 0x46,
            .rex_rxb => 0x47,
            .rex_w, .lock_rex_w => 0x48,
            .rex_wb => 0x49,
            .rex_wx => 0x4a,
            .rex_wxb => 0x4b,
            .rex_wr => 0x4c,
            .rex_wrb => 0x4d,
            .rex_wrx => 0x4e,
            .rex_wrxb => 0x4f,
            .repeat_rex_w => 0x48,
            else => 0,
        };
    }

    pub fn wide(self: Prefix) bool {
        return self.rexByte() & 0x08 != 0;
    }

    pub fn hasOperand16(self: Prefix) bool {
        return switch (self) {
            .operand16,
            .operand16_cs,
            .operand16_rex_b,
            .operand16_rex_r,
            .operand16_rex_rb,
            .operand16_2_cs,
            .operand16_4_cs,
            .operand16_5_cs,
            .operand16_3_cs,
            => true,
            else => false,
        };
    }

    pub fn repeatedOperand16(self: Prefix) bool {
        return self == .operand16_2_cs or
            self == .operand16_4_cs or
            self == .operand16_5_cs or
            self == .operand16_3_cs;
    }

    pub fn locked(self: Prefix) bool {
        return switch (self) {
            .lock_rex, .lock_rex_b, .lock_rex_w => true,
            else => false,
        };
    }

    pub fn repeated(self: Prefix) bool {
        return switch (self) {
            .repeat, .repeat_rex_b, .repeat_rex_w => true,
            else => false,
        };
    }
};

pub const Map = enum(u1) {
    one = 0,
    two = 1,
};

pub const Width = enum(u3) {
    none = 0,
    byte = 1,
    word = 2,
    dword = 3,
    qword = 4,
    vector128 = 5,

    pub fn bytes(self: Width) u8 {
        return switch (self) {
            .none => 0,
            .byte => 1,
            .word => 2,
            .dword => 4,
            .qword => 8,
            .vector128 => 16,
        };
    }
};

pub const Extension = enum(u4) {
    zero = 0,
    one = 1,
    two = 2,
    three = 3,
    four = 4,
    five = 5,
    six = 6,
    seven = 7,
    none = 8,

    pub fn fromRaw(value: u3) Extension {
        return @fromBackingInt(@intCast(value));
    }
};

pub const Mode = enum(u3) {
    none = 0,
    memory = 1,
    displacement8 = 2,
    displacement32 = 3,
    register = 4,
};

pub const Role = enum(u2) {
    none = 0,
    ordinary = 1,
    rsp = 2,
    rbp = 3,
};

pub const AddressKind = enum(u3) {
    none = 0,
    base = 1,
    base_indexed = 2,
    rip_relative = 3,
    absolute = 4,
    absolute_indexed = 5,
};

pub const Access = enum(u2) {
    none = 0,
    read = 1,
    write = 2,
    read_write = 3,
};

pub const Form = packed struct(u64) {
    prefix: Prefix = .none,
    map: Map = .one,
    opcode: u8 = 0,
    width: Width = .none,
    extension: Extension = .none,
    mode: Mode = .none,
    register_role: Role = .none,
    register_access: Access = .none,
    operand_role: Role = .none,
    operand_access: Access = .none,
    address: AddressKind = .none,
    base_role: Role = .none,
    index_role: Role = .none,
    embedded_role: Role = .none,
    embedded_access: Access = .none,
    immediate: u8 = 0,
    reserved: u13 = 0,

    pub fn key(self: Form) FormKey {
        return @bitCast(self);
    }

    pub fn encodedKey(self: Form) [8]u8 {
        var result: [8]u8 = undefined;
        std.mem.writeInt(u64, &result, self.key(), .little);
        return result;
    }
};

pub const Diagnostic = struct {
    candidate: Form = .{},
    prefix: [15]u8 = @splat(0),
    prefix_count: u4 = 0,
    active: bool = false,
    normalized: bool = false,

    pub fn captureForm(self: *Diagnostic, value: Form) void {
        self.* = .{
            .candidate = value,
            .active = true,
            .normalized = true,
        };
    }

    pub fn capturePrefix(self: *Diagnostic, value: []const u8) void {
        std.debug.assert(value.len <= self.prefix.len);
        self.* = .{
            .prefix_count = @intCast(value.len),
            .active = true,
        };
        @memcpy(self.prefix[0..value.len], value);
    }

    pub fn normalizedForm(self: Diagnostic) ?Form {
        if (!self.active or !self.normalized) return null;
        return self.candidate;
    }

    pub fn prefixBytes(self: *const Diagnostic) []const u8 {
        return self.prefix[0..self.prefix_count];
    }
};

pub fn modeled(value: Form) bool {
    if (value.reserved != 0) return false;
    return switch (value.map) {
        .one => modeledOne(value.opcode),
        .two => modeledTwo(value.opcode),
    };
}

fn modeledOne(opcode: u8) bool {
    if (opcode <= 0x05) return true;
    if (opcode >= 0x08 and opcode <= 0x0b) return true;
    if (opcode == 0x0d) return true;
    if (opcode >= 0x18 and opcode <= 0x1d) return true;
    if (opcode >= 0x20 and opcode <= 0x25) return true;
    if (opcode >= 0x28 and opcode <= 0x2d) return true;
    if (opcode >= 0x30 and opcode <= 0x35) return true;
    if (opcode == 0x38 or opcode == 0x39 or
        (opcode >= 0x3b and opcode <= 0x3d)) return true;
    if (opcode >= 0x50 and opcode <= 0x5f) return true;
    if ((opcode >= 0x72 and opcode <= 0x77) or
        (opcode >= 0x7c and opcode <= 0x7f)) return true;
    if (opcode >= 0xb0 and opcode <= 0xbf) return true;
    return switch (opcode) {
        0x69,
        0x6a,
        0x6b,
        0x80,
        0x81,
        0x83,
        0x84,
        0x85,
        0x88,
        0x89,
        0x8a,
        0x8b,
        0x8d,
        0x90,
        0x9c,
        0xa4,
        0xa5,
        0xa8,
        0xa9,
        0xaa,
        0xab,
        0xc0,
        0xc1,
        0xc3,
        0xc6,
        0xc7,
        0xcd,
        0xd0,
        0xd1,
        0xd2,
        0xd3,
        0xe8,
        0xe9,
        0xeb,
        0xee,
        0xf4,
        0xf5,
        0xf6,
        0xf7,
        0xfa,
        0xfb,
        0xfe,
        0xff,
        => true,
        else => false,
    };
}

fn modeledTwo(opcode: u8) bool {
    if ((opcode >= 0x82 and opcode <= 0x87) or
        (opcode >= 0x8c and opcode <= 0x8f)) return true;
    if ((opcode >= 0x92 and opcode <= 0x97) or
        (opcode >= 0x9c and opcode <= 0x9f)) return true;
    if (opcode >= 0xc8 and opcode <= 0xcf) return true;
    return switch (opcode) {
        0x0b,
        0x10,
        0x11,
        0x1f,
        0x30,
        0x32,
        0x42,
        0x43,
        0x44,
        0x45,
        0x47,
        0x6f,
        0x70,
        0x7f,
        0x90,
        0xa2,
        0xaf,
        0xb0,
        0xb6,
        0xb7,
        0xbe,
        0xbf,
        => true,
        else => false,
    };
}

comptime {
    std.debug.assert(@sizeOf(Form) == @sizeOf(FormKey));
    std.debug.assert(@bitSizeOf(Form) == 64);
}
