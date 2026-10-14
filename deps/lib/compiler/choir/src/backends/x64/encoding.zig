const std = @import("std");
const registers = @import("registers/root.zig");

pub const GPR = registers.GPR;
pub const XMM = registers.XMM;

pub const max_instruction_len: usize = 15;

pub const Condition = enum(u4) {
    o = 0x0,
    no = 0x1,
    b = 0x2,
    ae = 0x3,
    e = 0x4,
    ne = 0x5,
    be = 0x6,
    a = 0x7,
    s = 0x8,
    ns = 0x9,
    p = 0xA,
    np = 0xB,
    l = 0xC,
    ge = 0xD,
    le = 0xE,
    g = 0xF,

    fn opcode(self: Condition) u8 {
        return @backingInt(self);
    }
};

pub const Encoding = struct {
    bytes: [max_instruction_len]u8 = undefined,
    len: u8 = 0,

    pub fn init() Encoding {
        return .{};
    }

    pub fn slice(self: *const Encoding) []const u8 {
        return self.bytes[0..self.len];
    }

    fn emitByte(self: *Encoding, byte: u8) void {
        self.bytes[self.len] = byte;
        self.len += 1;
    }

    fn emitU32(self: *Encoding, value: u32) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], value, .little);
        self.len += 4;
    }

    fn emitU64(self: *Encoding, value: u64) void {
        std.mem.writeInt(u64, self.bytes[self.len..][0..8], value, .little);
        self.len += 8;
    }
};

pub const Scale = enum(u2) {
    one = 0b00,
    two = 0b01,
    four = 0b10,
    eight = 0b11,
};

pub const Mem = struct {
    base: ?GPR = null,
    index: ?GPR = null,
    scale: Scale = .one,
    disp: i32 = 0,
    rip_relative: bool = false,

    pub fn baseDisp(base: GPR, disp: i32) Mem {
        return .{ .base = base, .disp = disp };
    }

    pub fn baseIndex(base: GPR, index: GPR, scale: Scale, disp: i32) Mem {
        return .{ .base = base, .index = index, .scale = scale, .disp = disp };
    }

    pub fn ripRel(disp: i32) Mem {
        return .{ .rip_relative = true, .disp = disp };
    }
};

const Rex = struct {
    required: bool = false,
    w: bool = false,
    r: bool = false,
    x: bool = false,
    b: bool = false,

    fn byte(self: Rex) ?u8 {
        if (!(self.required or self.w or self.r or self.x or self.b)) return null;
        return 0x40 |
            (if (self.w) @as(u8, 0x08) else 0) |
            (if (self.r) @as(u8, 0x04) else 0) |
            (if (self.x) @as(u8, 0x02) else 0) |
            (if (self.b) @as(u8, 0x01) else 0);
    }
};

const RegBits = struct {
    low3: u3,
    rex: bool,
    byte_rex: bool = false,
};

fn regBitsFromGpr(gpr: GPR) RegBits {
    const id: u4 = @backingInt(gpr);
    return .{ .low3 = @as(u3, @truncate(id)), .rex = (id & 0x8) != 0 };
}

fn regBitsFromByte(gpr: GPR) RegBits {
    var bits = regBitsFromGpr(gpr);
    bits.byte_rex = bits.low3 >= 4;
    return bits;
}

fn regBitsFromXmm(xmm: XMM) RegBits {
    const id: u4 = @backingInt(xmm);
    return .{ .low3 = @as(u3, @truncate(id)), .rex = (id & 0x8) != 0 };
}

const RmOp = union(enum) {
    reg: RegBits,
    mem: Mem,
};

const Disp = union(enum) {
    none,
    disp8: i8,
    disp32: i32,

    fn emit(self: Disp, enc: *Encoding) void {
        switch (self) {
            .none => {},
            .disp8 => |value| enc.emitByte(@as(u8, @bitCast(value))),
            .disp32 => |value| enc.emitU32(@as(u32, @bitCast(value))),
        }
    }
};

const ModRmEncoding = struct {
    modrm: u8,
    sib: ?u8,
    disp: Disp,
    rex: Rex,
};

fn modrmByte(mod: u2, reg: u3, rm: u3) u8 {
    return (@as(u8, @intCast(mod)) << 6) |
        (@as(u8, @intCast(reg)) << 3) |
        @as(u8, @intCast(rm));
}

fn sibByte(scale: u2, index: u3, base: u3) u8 {
    return (@as(u8, @intCast(scale)) << 6) |
        (@as(u8, @intCast(index)) << 3) |
        @as(u8, @intCast(base));
}

fn fitsInI8(value: i32) bool {
    return value >= std.math.minInt(i8) and value <= std.math.maxInt(i8);
}

fn buildModRm(reg_bits: RegBits, rm: RmOp) ModRmEncoding {
    var rex = Rex{ .r = reg_bits.rex, .required = reg_bits.byte_rex };

    switch (rm) {
        .reg => |rm_bits| {
            rex.b = rm_bits.rex;
            rex.required = rex.required or rm_bits.byte_rex;
            return .{
                .modrm = modrmByte(0b11, reg_bits.low3, rm_bits.low3),
                .sib = null,
                .disp = .none,
                .rex = rex,
            };
        },
        .mem => |mem| return buildMemoryModRm(reg_bits, mem, rex),
    }
}

fn buildMemoryModRm(reg_bits: RegBits, mem: Mem, initial: Rex) ModRmEncoding {
    var rex = initial;
    if (mem.rip_relative) {
        std.debug.assert(mem.base == null);
        std.debug.assert(mem.index == null);
        return .{
            .modrm = modrmByte(0b00, reg_bits.low3, 0b101),
            .sib = null,
            .disp = .{ .disp32 = mem.disp },
            .rex = rex,
        };
    }

    const base = mem.base;
    const index = mem.index;

    if (index) |idx| {
        std.debug.assert(idx != .rsp);
    }

    var mod: u2 = 0b00;
    var disp: Disp = .none;

    if (base) |b| {
        const base_is_rbp = (b == .rbp or b == .r13);
        if (mem.disp == 0 and !base_is_rbp) {
            mod = 0b00;
            disp = .none;
        } else if (fitsInI8(mem.disp)) {
            mod = 0b01;
            disp = .{ .disp8 = @intCast(mem.disp) };
        } else {
            mod = 0b10;
            disp = .{ .disp32 = mem.disp };
        }
    } else {
        mod = 0b00;
        disp = .{ .disp32 = mem.disp };
    }

    const needs_sib = (index != null) or (base == null) or
        (base != null and regBitsFromGpr(base.?).low3 == 0b100);

    if (needs_sib) {
        const base_bits = if (base) |b| regBitsFromGpr(b) else RegBits{ .low3 = 0b101, .rex = false };
        const index_bits = if (index) |i| regBitsFromGpr(i) else RegBits{ .low3 = 0b100, .rex = false };

        rex.b = base_bits.rex;
        rex.x = index_bits.rex;

        return .{
            .modrm = modrmByte(mod, reg_bits.low3, 0b100),
            .sib = sibByte(@backingInt(mem.scale), index_bits.low3, base_bits.low3),
            .disp = disp,
            .rex = rex,
        };
    }

    const base_bits = regBitsFromGpr(base.?);
    rex.b = base_bits.rex;
    return .{
        .modrm = modrmByte(mod, reg_bits.low3, base_bits.low3),
        .sib = null,
        .disp = disp,
        .rex = rex,
    };
}

fn encodeOp(prefixes: []const u8, opcode: []const u8, reg_bits: RegBits, rm: RmOp, w: bool) Encoding {
    var enc = Encoding.init();
    var modrm = buildModRm(reg_bits, rm);
    var rex = modrm.rex;
    rex.w = w;

    for (prefixes) |prefix| {
        enc.emitByte(prefix);
    }
    if (rex.byte()) |byte| {
        enc.emitByte(byte);
    }
    for (opcode) |byte| {
        enc.emitByte(byte);
    }
    enc.emitByte(modrm.modrm);
    if (modrm.sib) |sib| {
        enc.emitByte(sib);
    }
    modrm.disp.emit(&enc);
    return enc;
}

fn encodeRmImm(
    prefixes: []const u8,
    opcode: u8,
    reg_ext: u3,
    rm: RmOp,
    imm: anytype,
    w: bool,
) Encoding {
    const reg_bits = RegBits{ .low3 = reg_ext, .rex = false };
    var enc = Encoding.init();
    var modrm = buildModRm(reg_bits, rm);
    var rex = modrm.rex;
    rex.w = w;

    for (prefixes) |prefix| {
        enc.emitByte(prefix);
    }
    if (rex.byte()) |byte| {
        enc.emitByte(byte);
    }
    enc.emitByte(opcode);
    enc.emitByte(modrm.modrm);
    if (modrm.sib) |sib| {
        enc.emitByte(sib);
    }
    modrm.disp.emit(&enc);

    switch (@TypeOf(imm)) {
        i8 => enc.emitByte(@as(u8, @bitCast(imm))),
        u8 => enc.emitByte(imm),
        i32 => enc.emitU32(@as(u32, @bitCast(imm))),
        u32 => enc.emitU32(imm),
        else => @compileError("Unsupported immediate type"),
    }

    return enc;
}

fn rmFromGpr(reg: GPR) RmOp {
    return .{ .reg = regBitsFromGpr(reg) };
}

fn rmFromXmm(reg: XMM) RmOp {
    return .{ .reg = regBitsFromXmm(reg) };
}

fn rmFromMem(mem: Mem) RmOp {
    return .{ .mem = mem };
}

pub const XmmRm = union(enum) {
    reg: XMM,
    mem: Mem,
};

fn rmFromXmmRm(rm: XmmRm) RmOp {
    return switch (rm) {
        .reg => |r| rmFromXmm(r),
        .mem => |m| rmFromMem(m),
    };
}

pub fn addRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x01}, regBitsFromGpr(src), rmFromGpr(dst), true);
}

pub fn addRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x01}, regBitsFromGpr(src), rmFromGpr(dst), false);
}

pub fn subRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x29}, regBitsFromGpr(src), rmFromGpr(dst), true);
}

pub fn subRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x29}, regBitsFromGpr(src), rmFromGpr(dst), false);
}

pub fn movRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x89}, regBitsFromGpr(src), rmFromGpr(dst), true);
}

pub fn movRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x89}, regBitsFromGpr(src), rmFromGpr(dst), false);
}

pub fn movRegMem(dst: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{0x8B}, regBitsFromGpr(dst), rmFromMem(mem), true);
}

pub fn movRegMem32(dst: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{0x8B}, regBitsFromGpr(dst), rmFromMem(mem), false);
}

pub fn movMemReg(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x89}, regBitsFromGpr(src), rmFromMem(mem), true);
}

pub fn movMemReg32(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x89}, regBitsFromGpr(src), rmFromMem(mem), false);
}

pub fn movMemReg8(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x88}, regBitsFromByte(src), rmFromMem(mem), false);
}

pub fn movMemReg16(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{0x66}, &.{0x89}, regBitsFromGpr(src), rmFromMem(mem), false);
}

pub fn movzxRegMem8(dest: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0xB6 }, regBitsFromGpr(dest), rmFromMem(mem), true);
}

pub fn movzxRegMem16(dest: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0xB7 }, regBitsFromGpr(dest), rmFromMem(mem), true);
}

pub fn movsxRegMem8(dest: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0xBE }, regBitsFromGpr(dest), rmFromMem(mem), true);
}

pub fn movsxRegMem16(dest: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0xBF }, regBitsFromGpr(dest), rmFromMem(mem), true);
}

pub fn addRegImm8(dst: GPR, imm: i8) Encoding {
    return encodeRmImm(&.{}, 0x83, 0b000, rmFromGpr(dst), imm, true);
}

pub fn subRegImm32(dst: GPR, imm: i32) Encoding {
    return encodeRmImm(&.{}, 0x81, 0b101, rmFromGpr(dst), imm, true);
}

pub fn addRegImm(dst: GPR, imm: i32) Encoding {
    if (fitsInI8(imm)) {
        return encodeRmImm(&.{}, 0x83, 0b000, rmFromGpr(dst), @as(i8, @intCast(imm)), true);
    }
    return encodeRmImm(&.{}, 0x81, 0b000, rmFromGpr(dst), imm, true);
}

pub fn subRegImm(dst: GPR, imm: i32) Encoding {
    if (fitsInI8(imm)) {
        return encodeRmImm(&.{}, 0x83, 0b101, rmFromGpr(dst), @as(i8, @intCast(imm)), true);
    }
    return encodeRmImm(&.{}, 0x81, 0b101, rmFromGpr(dst), imm, true);
}

pub fn cmpRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x39}, regBitsFromGpr(src), rmFromGpr(dst), true);
}

pub fn cmpRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x39}, regBitsFromGpr(src), rmFromGpr(dst), false);
}

pub fn cmpRegMem(dst: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{0x3B}, regBitsFromGpr(dst), rmFromMem(mem), true);
}

pub fn cmpRegMem32(dst: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{0x3B}, regBitsFromGpr(dst), rmFromMem(mem), false);
}

pub fn cmpMemReg(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x39}, regBitsFromGpr(src), rmFromMem(mem), true);
}

pub fn cmpMemReg32(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x39}, regBitsFromGpr(src), rmFromMem(mem), false);
}

pub fn addRegMem(dst: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{0x03}, regBitsFromGpr(dst), rmFromMem(mem), true);
}

pub fn addRegMem32(dst: GPR, mem: Mem) Encoding {
    return encodeOp(&.{}, &.{0x03}, regBitsFromGpr(dst), rmFromMem(mem), false);
}

pub fn addMemReg(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x01}, regBitsFromGpr(src), rmFromMem(mem), true);
}

pub fn addMemReg32(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x01}, regBitsFromGpr(src), rmFromMem(mem), false);
}

pub fn cmpRegImm(dst: GPR, imm: i32) Encoding {
    if (fitsInI8(imm)) {
        return encodeRmImm(&.{}, 0x83, 0b111, rmFromGpr(dst), @as(i8, @intCast(imm)), true);
    }
    return encodeRmImm(&.{}, 0x81, 0b111, rmFromGpr(dst), imm, true);
}

pub fn cmpRegImm32(dst: GPR, imm: i32) Encoding {
    if (fitsInI8(imm)) {
        return encodeRmImm(&.{}, 0x83, 0b111, rmFromGpr(dst), @as(i8, @intCast(imm)), false);
    }
    return encodeRmImm(&.{}, 0x81, 0b111, rmFromGpr(dst), imm, false);
}

/// Compares the quadword at `mem` with a sign-extended byte, which sets the flags a branch on
/// the value reads without first loading it into a register.
pub fn cmpMemImm8(mem: Mem, imm: i8) Encoding {
    return encodeRmImm(&.{}, 0x83, 0b111, rmFromMem(mem), imm, true);
}

/// The doubleword form of `cmpMemImm8`.
pub fn cmpMemImm8_32(mem: Mem, imm: i8) Encoding {
    return encodeRmImm(&.{}, 0x83, 0b111, rmFromMem(mem), imm, false);
}

pub fn pushReg(reg: GPR) Encoding {
    var enc = Encoding.init();
    const id: u4 = @backingInt(reg);
    if ((id & 0x8) != 0) {
        enc.emitByte(0x41);
    }
    enc.emitByte(0x50 + @as(u8, @intCast(id & 0x7)));
    return enc;
}

pub fn popReg(reg: GPR) Encoding {
    var enc = Encoding.init();
    const id: u4 = @backingInt(reg);
    if ((id & 0x8) != 0) {
        enc.emitByte(0x41);
    }
    enc.emitByte(0x58 + @as(u8, @intCast(id & 0x7)));
    return enc;
}

pub fn movRegImm64(dst: GPR, imm: u64) Encoding {
    var enc = Encoding.init();
    const id: u4 = @backingInt(dst);
    const rex: u8 = 0x48 | (if ((id & 0x8) != 0) @as(u8, 0x01) else 0);
    enc.emitByte(rex);
    enc.emitByte(0xB8 + @as(u8, @intCast(id & 0x7)));
    enc.emitU64(imm);
    return enc;
}

/// `mov r64, simm32`: the immediate sign extends to 64 bits, so a value outside the signed 32
/// bit range needs `movRegImm64`, or `movRegImm32` when it fits unsigned 32 bits.
pub fn movRegSimm32(dst: GPR, imm: i32) Encoding {
    return encodeRmImm(&.{}, 0xC7, 0b000, rmFromGpr(dst), imm, true);
}

/// The ALU operations with an `r/m, imm` form, by their ModRM reg extension.
pub const AluImm = enum(u3) { add = 0, or_ = 1, and_ = 4, sub = 5, xor = 6, cmp = 7 };

/// `op r, imm`, with the immediate sign extended to the operation width. The imm8 form is
/// chosen when the value fits it.
pub fn aluRegImm(kind: AluImm, dst: GPR, imm: i32, wide: bool) Encoding {
    if (fitsInI8(imm)) {
        return encodeRmImm(&.{}, 0x83, @backingInt(kind), rmFromGpr(dst), @as(i8, @intCast(imm)), wide);
    }
    return encodeRmImm(&.{}, 0x81, @backingInt(kind), rmFromGpr(dst), imm, wide);
}

/// `imul dst, src, imm`, the immediate sign extended to the operation width.
pub fn imulRegRegImm(dst: GPR, src: GPR, imm: i32, wide: bool) Encoding {
    if (fitsInI8(imm)) {
        var enc = encodeOp(&.{}, &.{0x6B}, regBitsFromGpr(dst), rmFromGpr(src), wide);
        enc.emitByte(@bitCast(@as(i8, @intCast(imm))));
        return enc;
    }
    var enc = encodeOp(&.{}, &.{0x69}, regBitsFromGpr(dst), rmFromGpr(src), wide);
    enc.emitU32(@bitCast(imm));
    return enc;
}

/// A general register or a memory operand, as the `r/m` side of an instruction.
pub const GprRm = union(enum) { reg: GPR, mem: Mem };

/// The two-operand integer operations with an `r, r/m` form.
pub const Alu = enum { add, sub, and_, or_, xor, imul };

/// `op dst, src`, the `r, r/m` form, at 64 bits when `wide` and 32 otherwise.
pub fn aluRegRm(kind: Alu, dst: GPR, src: GprRm, wide: bool) Encoding {
    const opcode: []const u8 = switch (kind) {
        .add => &.{0x03},
        .or_ => &.{0x0B},
        .and_ => &.{0x23},
        .sub => &.{0x2B},
        .xor => &.{0x33},
        .imul => &.{ 0x0F, 0xAF },
    };
    const rm = switch (src) {
        .reg => |reg| rmFromGpr(reg),
        .mem => |mem| rmFromMem(mem),
    };
    return encodeOp(&.{}, opcode, regBitsFromGpr(dst), rm, wide);
}

/// The shifts with an `r/m, imm8` form, by their ModRM reg extension.
pub const ShiftImm = enum(u3) { shl = 4, shr = 5, sar = 7 };

/// `shift dst, count`, at 64 bits when `wide` and 32 otherwise.
pub fn shiftRegImm(kind: ShiftImm, dst: GPR, count: u6, wide: bool) Encoding {
    return encodeRmImm(&.{}, 0xC1, @backingInt(kind), rmFromGpr(dst), @as(u8, count), wide);
}

pub fn movRegImm32(dst: GPR, imm: u32) Encoding {
    var enc = Encoding.init();
    const id: u4 = @backingInt(dst);
    if ((id & 0x8) != 0) {
        enc.emitByte(0x41);
    }
    enc.emitByte(0xB8 + @as(u8, @intCast(id & 0x7)));
    enc.emitU32(imm);
    return enc;
}

pub fn imulRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0xAF }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn imulRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0xAF }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn mulReg(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b100, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), true);
}

pub fn mulReg32(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b100, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), false);
}

pub fn idivReg(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b111, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), true);
}

pub fn idivReg32(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b111, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), false);
}

pub fn divReg(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b110, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), true);
}

pub fn divReg32(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b110, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), false);
}

pub fn negReg(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b011, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), true);
}

pub fn negReg32(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b011, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), false);
}

pub fn cmovgRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x4F }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn cmovgRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x4F }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn cmovlRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x4C }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn cmovlRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x4C }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn cmovaRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x47 }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn cmovaRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x47 }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn cmovbRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x42 }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn cmovbRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x42 }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn cmovneRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x45 }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn cmovneRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x45 }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn movsxdRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x63}, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn cvtss2sd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x5A }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn cvtsd2ss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x5A }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn cvtsi2ssReg32(dst: XMM, src: GPR) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x2A }, regBitsFromXmm(dst), rmFromGpr(src), false);
}

pub fn cvtsi2ssReg64(dst: XMM, src: GPR) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x2A }, regBitsFromXmm(dst), rmFromGpr(src), true);
}

pub fn cvtsi2sdReg32(dst: XMM, src: GPR) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x2A }, regBitsFromXmm(dst), rmFromGpr(src), false);
}

pub fn cvtsi2sdReg64(dst: XMM, src: GPR) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x2A }, regBitsFromXmm(dst), rmFromGpr(src), true);
}

pub fn movdXmmFromReg32(dst: XMM, src: GPR) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x6E }, regBitsFromXmm(dst), rmFromGpr(src), false);
}

pub fn movdXmmFromMem32(dst: XMM, src: Mem) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x6E }, regBitsFromXmm(dst), rmFromMem(src), false);
}

pub fn movqXmmFromReg64(dst: XMM, src: GPR) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x6E }, regBitsFromXmm(dst), rmFromGpr(src), true);
}

pub fn movqXmmFromMem64(dst: XMM, src: Mem) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x6E }, regBitsFromXmm(dst), rmFromMem(src), true);
}

pub fn movdMemFromXmm32(dst: Mem, src: XMM) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x7E }, regBitsFromXmm(src), rmFromMem(dst), false);
}

pub fn movqMemFromXmm64(dst: Mem, src: XMM) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x7E }, regBitsFromXmm(src), rmFromMem(dst), true);
}

pub fn movdReg32FromXmm(dst: GPR, src: XMM) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x7E }, regBitsFromXmm(src), rmFromGpr(dst), false);
}

pub fn movqReg64FromXmm(dst: GPR, src: XMM) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x7E }, regBitsFromXmm(src), rmFromGpr(dst), true);
}

pub fn cvttss2siReg32(dst: GPR, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x2C }, regBitsFromGpr(dst), rmFromXmmRm(src), false);
}

pub fn cvttss2siReg64(dst: GPR, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x2C }, regBitsFromGpr(dst), rmFromXmmRm(src), true);
}

pub fn cvttsd2siReg32(dst: GPR, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x2C }, regBitsFromGpr(dst), rmFromXmmRm(src), false);
}

pub fn cvttsd2siReg64(dst: GPR, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x2C }, regBitsFromGpr(dst), rmFromXmmRm(src), true);
}

pub fn cmovnsRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x49 }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn cmovnsRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x49 }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn sqrtss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x51 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn sqrtsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x51 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn maxss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x5F }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn maxsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x5F }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn minss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x5D }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn minsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x5D }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn pcmpeqd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x76 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn paddd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xFE }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn psubd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xFA }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn paddq(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xD4 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn psubq(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xFB }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn pcmpgtd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x66 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn pmuludq(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xF4 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn pxor(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xEF }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn pand(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xDB }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn por(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0xEB }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn pshufd(dst: XMM, src: XmmRm, imm: u8) Encoding {
    var enc = encodeOp(&.{0x66}, &.{ 0x0F, 0x70 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
    enc.emitByte(imm);
    return enc;
}

fn xmmShiftImm(opcode_byte: u8, ext: u3, dst: XMM, imm: u8) Encoding {
    const reg_bits = RegBits{ .low3 = ext, .rex = false };
    var enc = encodeOp(&.{0x66}, &.{ 0x0F, opcode_byte }, reg_bits, rmFromXmm(dst), false);
    enc.emitByte(imm);
    return enc;
}

pub fn psrldImm(dst: XMM, imm: u8) Encoding {
    return xmmShiftImm(0x72, 0b010, dst, imm);
}

pub fn psradImm(dst: XMM, imm: u8) Encoding {
    return xmmShiftImm(0x72, 0b100, dst, imm);
}

pub fn psrlqImm(dst: XMM, imm: u8) Encoding {
    return xmmShiftImm(0x73, 0b010, dst, imm);
}

pub fn pslldImm(dst: XMM, imm: u8) Encoding {
    return xmmShiftImm(0x72, 0b110, dst, imm);
}

pub fn psllqImm(dst: XMM, imm: u8) Encoding {
    return xmmShiftImm(0x73, 0b110, dst, imm);
}

pub fn andps(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x54 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn andpd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x54 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn xorps(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x57 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn movaps(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x28 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn xorpd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x57 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn cqo() Encoding {
    var enc = Encoding.init();
    enc.emitByte(0x48);
    enc.emitByte(0x99);
    return enc;
}

pub fn cdq() Encoding {
    var enc = Encoding.init();
    enc.emitByte(0x99);
    return enc;
}

pub fn xorRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x31}, regBitsFromGpr(src), rmFromGpr(dst), true);
}

pub fn xorRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x31}, regBitsFromGpr(src), rmFromGpr(dst), false);
}

pub fn andRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x21}, regBitsFromGpr(src), rmFromGpr(dst), true);
}

pub fn andRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x21}, regBitsFromGpr(src), rmFromGpr(dst), false);
}

pub fn andRegImm(dst: GPR, imm: i32) Encoding {
    if (fitsInI8(imm)) {
        return encodeRmImm(&.{}, 0x83, 0b100, rmFromGpr(dst), @as(i8, @intCast(imm)), true);
    }
    return encodeRmImm(&.{}, 0x81, 0b100, rmFromGpr(dst), imm, true);
}

pub fn andRegImm32(dst: GPR, imm: i32) Encoding {
    if (fitsInI8(imm)) {
        return encodeRmImm(&.{}, 0x83, 0b100, rmFromGpr(dst), @as(i8, @intCast(imm)), false);
    }
    return encodeRmImm(&.{}, 0x81, 0b100, rmFromGpr(dst), imm, false);
}

pub fn orRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x09}, regBitsFromGpr(src), rmFromGpr(dst), true);
}

pub fn orRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x09}, regBitsFromGpr(src), rmFromGpr(dst), false);
}

pub fn notReg(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b010, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), true);
}

pub fn notReg32(src: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b010, .rex = false };
    return encodeOp(&.{}, &.{0xF7}, reg_bits, rmFromGpr(src), false);
}

pub fn shlRegCl(dst: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b100, .rex = false };
    return encodeOp(&.{}, &.{0xD3}, reg_bits, rmFromGpr(dst), true);
}

pub fn shlRegCl32(dst: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b100, .rex = false };
    return encodeOp(&.{}, &.{0xD3}, reg_bits, rmFromGpr(dst), false);
}

pub fn shrRegCl(dst: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b101, .rex = false };
    return encodeOp(&.{}, &.{0xD3}, reg_bits, rmFromGpr(dst), true);
}

pub fn shrRegCl32(dst: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b101, .rex = false };
    return encodeOp(&.{}, &.{0xD3}, reg_bits, rmFromGpr(dst), false);
}

pub fn shrRegImm(dst: GPR, imm: u8) Encoding {
    return encodeRmImm(&.{}, 0xC1, 0b101, rmFromGpr(dst), @as(i8, @bitCast(imm)), true);
}

pub fn shlRegImm(dst: GPR, imm: u8) Encoding {
    return encodeRmImm(&.{}, 0xC1, 0b100, rmFromGpr(dst), @as(i8, @bitCast(imm)), true);
}

pub fn shrRegImm32(dst: GPR, imm: u8) Encoding {
    return encodeRmImm(&.{}, 0xC1, 0b101, rmFromGpr(dst), @as(i8, @bitCast(imm)), false);
}

pub fn sarRegImm(dst: GPR, imm: u8) Encoding {
    return encodeRmImm(&.{}, 0xC1, 0b111, rmFromGpr(dst), @as(i8, @bitCast(imm)), true);
}

pub fn sarRegImm32(dst: GPR, imm: u8) Encoding {
    return encodeRmImm(&.{}, 0xC1, 0b111, rmFromGpr(dst), @as(i8, @bitCast(imm)), false);
}

pub fn sarRegCl(dst: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b111, .rex = false };
    return encodeOp(&.{}, &.{0xD3}, reg_bits, rmFromGpr(dst), true);
}

pub fn sarRegCl32(dst: GPR) Encoding {
    const reg_bits = RegBits{ .low3 = 0b111, .rex = false };
    return encodeOp(&.{}, &.{0xD3}, reg_bits, rmFromGpr(dst), false);
}

pub fn setcc(dst: GPR, cond: Condition) Encoding {
    const reg_bits = regBitsFromByte(dst);
    var enc = Encoding.init();
    var rex = Rex{ .b = reg_bits.rex, .required = reg_bits.byte_rex };
    if (rex.byte()) |byte| {
        enc.emitByte(byte);
    }
    enc.emitByte(0x0F);
    enc.emitByte(0x90 + cond.opcode());
    enc.emitByte(modrmByte(0b11, 0b000, reg_bits.low3));
    return enc;
}

/// The prefix that makes one read, modify, and write of memory a single indivisible access.
///
/// It sits before any REX byte, which `encodeOp` guarantees by emitting prefixes first.
const lock_prefix: u8 = 0xF0;

/// `lock cmpxchg [mem], src` on a machine word.
///
/// Compares rax with the word at `mem`. When they are equal it writes `src` there and sets ZF,
/// and otherwise it loads the word into rax and clears ZF. Either way rax ends holding the word
/// the instruction observed. The lock prefix orders the access against every other memory access
/// on the core, so a compare and swap needs no fence beside it at any ordering.
///
/// The bytes this, the exchange, and the fence below produce are pinned by a test against what
/// GNU as assembles from the same Intel syntax, read back with objdump, so that test checks the
/// encoder against an assembler rather than against itself.
pub fn lockCmpxchgMemReg(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{lock_prefix}, &.{ 0x0F, 0xB1 }, regBitsFromGpr(src), rmFromMem(mem), true);
}

/// `lock cmpxchg [mem], src` on 32 bits, comparing with eax.
pub fn lockCmpxchgMemReg32(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{lock_prefix}, &.{ 0x0F, 0xB1 }, regBitsFromGpr(src), rmFromMem(mem), false);
}

/// `xchg [mem], src` on a machine word.
///
/// An exchange with a memory operand is locked without being asked, so one instruction is both
/// the store and the full barrier a sequentially consistent store needs. `src` ends holding the
/// word that was there before.
pub fn xchgMemReg(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x87}, regBitsFromGpr(src), rmFromMem(mem), true);
}

/// `xchg [mem], src` on 32 bits.
pub fn xchgMemReg32(mem: Mem, src: GPR) Encoding {
    return encodeOp(&.{}, &.{0x87}, regBitsFromGpr(src), rmFromMem(mem), false);
}

/// `mfence`: no load or store after it becomes visible before every one before it has.
pub fn mfence() Encoding {
    var enc = Encoding.init();
    enc.emitByte(0x0F);
    enc.emitByte(0xAE);
    enc.emitByte(0xF0);
    return enc;
}

/// `ud2`: raises an invalid-opcode fault, which no debugger can continue past.
pub fn ud2() Encoding {
    var enc = Encoding.init();
    enc.emitByte(0x0F);
    enc.emitByte(0x0B);
    return enc;
}

pub fn movzxReg8(dest: GPR, src: GPR) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0xB6 }, regBitsFromGpr(dest), .{ .reg = regBitsFromByte(src) }, false);
}

pub fn popcntRegReg(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0xB8 }, regBitsFromGpr(dst), rmFromGpr(src), true);
}

pub fn popcntRegReg32(dst: GPR, src: GPR) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0xB8 }, regBitsFromGpr(dst), rmFromGpr(src), false);
}

pub fn jmpRel32(disp: i32) Encoding {
    var enc = Encoding.init();
    enc.emitByte(0xE9);
    enc.emitU32(@as(u32, @bitCast(disp)));
    return enc;
}

pub fn jccRel32(cond: Condition, disp: i32) Encoding {
    var enc = Encoding.init();
    enc.emitByte(0x0F);
    enc.emitByte(0x80 + cond.opcode());
    enc.emitU32(@as(u32, @bitCast(disp)));
    return enc;
}

pub fn callReg(reg: GPR) Encoding {
    const reg_bits = regBitsFromGpr(reg);
    var enc = Encoding.init();
    var rex = Rex{ .b = reg_bits.rex, .required = reg_bits.byte_rex };
    if (rex.byte()) |byte| {
        enc.emitByte(byte);
    }
    enc.emitByte(0xFF);
    enc.emitByte(modrmByte(0b11, 0b010, reg_bits.low3));
    return enc;
}

pub fn callRel32(disp: i32) Encoding {
    var enc = Encoding.init();
    enc.emitByte(0xE8);
    enc.emitU32(@as(u32, @bitCast(disp)));
    return enc;
}

pub fn ret() Encoding {
    var enc = Encoding.init();
    enc.emitByte(0xC3);
    return enc;
}

/// Enters the kernel. The instruction names no operand because the whole call sits in
/// registers the encoding does not mention: Linux x86-64 reads the number from rax and the
/// arguments from rdi, rsi, rdx, r10, r8, and r9, returns in rax, and destroys rcx and r11.
pub fn syscall() Encoding {
    var enc = Encoding.init();
    enc.emitByte(0x0F);
    enc.emitByte(0x05);
    return enc;
}

pub fn addss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x58 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn addsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x58 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn subss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x5C }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn subsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x5C }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn mulss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x59 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn mulsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x59 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn divss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x5E }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn divsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x5E }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn addps(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x58 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn subps(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x5C }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn mulps(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x59 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn divps(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x5E }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn addpd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x58 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn subpd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x5C }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn mulpd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x59 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn divpd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x5E }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn cmpps(dst: XMM, src: XmmRm, imm: u8) Encoding {
    var enc = encodeOp(&.{}, &.{ 0x0F, 0xC2 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
    enc.emitByte(imm);
    return enc;
}

pub fn cmppd(dst: XMM, src: XmmRm, imm: u8) Encoding {
    var enc = encodeOp(&.{0x66}, &.{ 0x0F, 0xC2 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
    enc.emitByte(imm);
    return enc;
}

pub fn shufpd(dst: XMM, src: XmmRm, imm: u8) Encoding {
    var enc = encodeOp(&.{0x66}, &.{ 0x0F, 0xC6 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
    enc.emitByte(imm);
    return enc;
}

pub fn shufps(dst: XMM, src: XmmRm, imm: u8) Encoding {
    var enc = encodeOp(&.{}, &.{ 0x0F, 0xC6 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
    enc.emitByte(imm);
    return enc;
}

pub fn movss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x10 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn movssStore(mem: Mem, src: XMM) Encoding {
    return encodeOp(&.{0xF3}, &.{ 0x0F, 0x11 }, regBitsFromXmm(src), rmFromMem(mem), false);
}

pub fn movsd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x10 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn movsdStore(mem: Mem, src: XMM) Encoding {
    return encodeOp(&.{0xF2}, &.{ 0x0F, 0x11 }, regBitsFromXmm(src), rmFromMem(mem), false);
}

pub fn movups(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x10 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn movupsStore(mem: Mem, src: XMM) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x11 }, regBitsFromXmm(src), rmFromMem(mem), false);
}

pub fn movupd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x10 }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn movupdStore(mem: Mem, src: XMM) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x11 }, regBitsFromXmm(src), rmFromMem(mem), false);
}

pub fn ucomiss(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{}, &.{ 0x0F, 0x2E }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

pub fn ucomisd(dst: XMM, src: XmmRm) Encoding {
    return encodeOp(&.{0x66}, &.{ 0x0F, 0x2E }, regBitsFromXmm(dst), rmFromXmmRm(src), false);
}

const VexFields = struct {
    r: bool,
    b: bool,
    mmmmm: u5,
    w: bool,
    vvvv: XMM,
    l: bool,
    pp: u2,
};

fn vex3Bytes(fields: VexFields) [3]u8 {
    const r_bar: u8 = if (fields.r) 0 else 1;
    const x_bar: u8 = 1;
    const b_bar: u8 = if (fields.b) 0 else 1;
    const byte1: u8 = (r_bar << 7) | (x_bar << 6) | (b_bar << 5) | @as(u8, fields.mmmmm);

    const w_bit: u8 = if (fields.w) 1 else 0;
    const vvvv_inv: u8 = (~@as(u8, @backingInt(fields.vvvv))) & 0xF;
    const l_bit: u8 = if (fields.l) 1 else 0;
    const byte2: u8 = (w_bit << 7) | (vvvv_inv << 3) | (l_bit << 2) | @as(u8, fields.pp);

    return .{ 0xC4, byte1, byte2 };
}

pub fn vfmadd231ss(dst: XMM, src1: XMM, src2: XMM) Encoding {
    var enc = Encoding.init();
    const dst_idx = @backingInt(dst);
    const src2_idx = @backingInt(src2);
    const prefix = vex3Bytes(.{
        .r = dst_idx >= 8,
        .b = src2_idx >= 8,
        .mmmmm = 0b00010,
        .w = false,
        .vvvv = src1,
        .l = false,
        .pp = 0b01,
    });
    for (prefix) |byte| enc.emitByte(byte);
    enc.emitByte(0xB9);
    enc.emitByte(0xC0 | (@as(u8, dst_idx & 0x7) << 3) | (src2_idx & 0x7));
    return enc;
}

pub fn vfmadd231sd(dst: XMM, src1: XMM, src2: XMM) Encoding {
    var enc = Encoding.init();
    const dst_idx = @backingInt(dst);
    const src2_idx = @backingInt(src2);
    const prefix = vex3Bytes(.{
        .r = dst_idx >= 8,
        .b = src2_idx >= 8,
        .mmmmm = 0b00010,
        .w = true,
        .vvvv = src1,
        .l = false,
        .pp = 0b01,
    });
    for (prefix) |byte| enc.emitByte(byte);
    enc.emitByte(0xB9);
    enc.emitByte(0xC0 | (@as(u8, dst_idx & 0x7) << 3) | (src2_idx & 0x7));
    return enc;
}

fn expectEncoding(actual: Encoding, expected: []const u8) !void {
    try std.testing.expectEqualSlices(u8, expected, actual.slice());
}
