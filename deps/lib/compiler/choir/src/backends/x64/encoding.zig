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

test "golden: atomic compare and swap, exchange, and fence match GNU as" {
    const low = Mem.baseIndex(.rax, .rcx, .eight, 0);
    const low32 = Mem.baseIndex(.rax, .rcx, .four, 0);
    const high = Mem.baseIndex(.r8, .r9, .eight, 0);
    const high32 = Mem.baseIndex(.r8, .r9, .four, 0);
    const frame = Mem.baseDisp(.rbp, -16);

    try expectEncoding(lockCmpxchgMemReg(low, .rdx), &.{ 0xF0, 0x48, 0x0F, 0xB1, 0x14, 0xC8 });
    try expectEncoding(lockCmpxchgMemReg32(low32, .rdx), &.{ 0xF0, 0x0F, 0xB1, 0x14, 0x88 });
    try expectEncoding(lockCmpxchgMemReg(high, .r10), &.{ 0xF0, 0x4F, 0x0F, 0xB1, 0x14, 0xC8 });
    try expectEncoding(lockCmpxchgMemReg32(high32, .r10), &.{ 0xF0, 0x47, 0x0F, 0xB1, 0x14, 0x88 });
    try expectEncoding(lockCmpxchgMemReg(frame, .rdx), &.{ 0xF0, 0x48, 0x0F, 0xB1, 0x55, 0xF0 });

    try expectEncoding(xchgMemReg(low, .rdx), &.{ 0x48, 0x87, 0x14, 0xC8 });
    try expectEncoding(xchgMemReg32(low32, .rdx), &.{ 0x87, 0x14, 0x88 });
    try expectEncoding(xchgMemReg(high, .r10), &.{ 0x4F, 0x87, 0x14, 0xC8 });
    try expectEncoding(xchgMemReg32(high32, .r10), &.{ 0x47, 0x87, 0x14, 0x88 });
    try expectEncoding(xchgMemReg(frame, .rdx), &.{ 0x48, 0x87, 0x55, 0xF0 });

    try expectEncoding(mfence(), &.{ 0x0F, 0xAE, 0xF0 });
}

test "golden: compare memory with a byte immediate matches GNU as" {
    try expectEncoding(cmpMemImm8(Mem.baseDisp(.rbp, -16), 0), &.{ 0x48, 0x83, 0x7D, 0xF0, 0x00 });
    try expectEncoding(cmpMemImm8_32(Mem.baseDisp(.rbp, -16), 0), &.{ 0x83, 0x7D, 0xF0, 0x00 });
    try expectEncoding(
        cmpMemImm8(Mem.baseDisp(.rbp, -200), 0),
        &.{ 0x48, 0x83, 0xBD, 0x38, 0xFF, 0xFF, 0xFF, 0x00 },
    );
    try expectEncoding(cmpMemImm8(Mem.baseDisp(.r13, 8), 0), &.{ 0x49, 0x83, 0x7D, 0x08, 0x00 });
}

test "golden: reg/reg and immediates" {
    try expectEncoding(addRegReg(.rax, .rbx), &.{ 0x48, 0x01, 0xD8 });
    try expectEncoding(subRegReg(.r12, .r13), &.{ 0x4D, 0x29, 0xEC });
    try expectEncoding(movRegReg(.r8, .r9), &.{ 0x4D, 0x89, 0xC8 });
    try expectEncoding(addRegImm8(.r10, 5), &.{ 0x49, 0x83, 0xC2, 0x05 });
    try expectEncoding(subRegImm32(.r11, 0x12345678), &.{ 0x49, 0x81, 0xEB, 0x78, 0x56, 0x34, 0x12 });
}

test "golden: xmm register copies" {
    try expectEncoding(movaps(.xmm1, .{ .reg = .xmm2 }), &.{ 0x0F, 0x28, 0xCA });
    try expectEncoding(movaps(.xmm9, .{ .reg = .xmm12 }), &.{ 0x45, 0x0F, 0x28, 0xCC });
    try expectEncoding(movdReg32FromXmm(.rax, .xmm1), &.{ 0x66, 0x0F, 0x7E, 0xC8 });
    try expectEncoding(movqReg64FromXmm(.rax, .xmm1), &.{ 0x66, 0x48, 0x0F, 0x7E, 0xC8 });
    try expectEncoding(movdReg32FromXmm(.r9, .xmm12), &.{ 0x66, 0x45, 0x0F, 0x7E, 0xE1 });
}

test "golden: reg/mem compare and add forms" {
    const local = Mem.baseDisp(.rbp, -8);
    try expectEncoding(cmpRegMem(.rax, local), &.{ 0x48, 0x3B, 0x45, 0xF8 });
    try expectEncoding(cmpMemReg(local, .rcx), &.{ 0x48, 0x39, 0x4D, 0xF8 });
    try expectEncoding(addRegMem(.r8, Mem.baseDisp(.rbp, 0x10)), &.{ 0x4C, 0x03, 0x45, 0x10 });
    try expectEncoding(addMemReg(Mem.baseDisp(.rbp, -0x18), .rdi), &.{ 0x48, 0x01, 0x7D, 0xE8 });
}

test "golden: SIB addressing and RIP-relative" {
    const sib_load = Mem.baseIndex(.r12, .rsi, .four, 0x10);
    try expectEncoding(movRegMem(.rax, sib_load), &.{ 0x49, 0x8B, 0x44, 0xB4, 0x10 });

    const sib_store = Mem.baseIndex(.r8, .rdx, .two, 0x20);
    try expectEncoding(movMemReg(sib_store, .r9), &.{ 0x4D, 0x89, 0x4C, 0x50, 0x20 });

    const rip = Mem.ripRel(0x1234);
    try expectEncoding(movRegMem(.rax, rip), &.{ 0x48, 0x8B, 0x05, 0x34, 0x12, 0x00, 0x00 });
}

test "golden: XMM scalar ops" {
    try expectEncoding(addss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x58, 0xC1 });
    try expectEncoding(addsd(.xmm2, .{ .reg = .xmm3 }), &.{ 0xF2, 0x0F, 0x58, 0xD3 });
    try expectEncoding(subss(.xmm4, .{ .reg = .xmm5 }), &.{ 0xF3, 0x0F, 0x5C, 0xE5 });
    try expectEncoding(subsd(.xmm6, .{ .reg = .xmm7 }), &.{ 0xF2, 0x0F, 0x5C, 0xF7 });
    try expectEncoding(mulss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x59, 0xC1 });
    try expectEncoding(mulsd(.xmm2, .{ .reg = .xmm3 }), &.{ 0xF2, 0x0F, 0x59, 0xD3 });
    try expectEncoding(divss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x5E, 0xC1 });
    try expectEncoding(divsd(.xmm2, .{ .reg = .xmm3 }), &.{ 0xF2, 0x0F, 0x5E, 0xD3 });
    try expectEncoding(movss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x10, 0xC1 });
    try expectEncoding(movsd(.xmm2, .{ .reg = .xmm3 }), &.{ 0xF2, 0x0F, 0x10, 0xD3 });
    try expectEncoding(ucomiss(.xmm0, .{ .reg = .xmm1 }), &.{ 0x0F, 0x2E, 0xC1 });
    try expectEncoding(ucomisd(.xmm2, .{ .reg = .xmm3 }), &.{ 0x66, 0x0F, 0x2E, 0xD3 });
}

test "golden: XMM packed f32 ops" {
    try expectEncoding(addps(.xmm0, .{ .reg = .xmm1 }), &.{ 0x0F, 0x58, 0xC1 });
    try expectEncoding(subps(.xmm2, .{ .reg = .xmm3 }), &.{ 0x0F, 0x5C, 0xD3 });
    try expectEncoding(mulps(.xmm4, .{ .reg = .xmm5 }), &.{ 0x0F, 0x59, 0xE5 });
    try expectEncoding(divps(.xmm6, .{ .reg = .xmm7 }), &.{ 0x0F, 0x5E, 0xF7 });
    try expectEncoding(cmpps(.xmm0, .{ .reg = .xmm1 }, 1), &.{ 0x0F, 0xC2, 0xC1, 0x01 });
    try expectEncoding(shufps(.xmm0, .{ .reg = .xmm0 }, 0x1B), &.{ 0x0F, 0xC6, 0xC0, 0x1B });
    try expectEncoding(movups(.xmm0, .{ .mem = Mem.baseDisp(.rbp, -16) }), &.{ 0x0F, 0x10, 0x45, 0xF0 });
    try expectEncoding(movupsStore(Mem.baseDisp(.rbp, -24), .xmm1), &.{ 0x0F, 0x11, 0x4D, 0xE8 });
}

test "golden: XMM packed f64 ops" {
    try expectEncoding(addpd(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0x58, 0xC1 });
    try expectEncoding(subpd(.xmm2, .{ .reg = .xmm3 }), &.{ 0x66, 0x0F, 0x5C, 0xD3 });
    try expectEncoding(mulpd(.xmm4, .{ .reg = .xmm5 }), &.{ 0x66, 0x0F, 0x59, 0xE5 });
    try expectEncoding(divpd(.xmm6, .{ .reg = .xmm7 }), &.{ 0x66, 0x0F, 0x5E, 0xF7 });
    try expectEncoding(cmppd(.xmm2, .{ .reg = .xmm3 }, 2), &.{ 0x66, 0x0F, 0xC2, 0xD3, 0x02 });
    try expectEncoding(shufpd(.xmm0, .{ .reg = .xmm0 }, 0x01), &.{ 0x66, 0x0F, 0xC6, 0xC0, 0x01 });
    try expectEncoding(movupd(.xmm0, .{ .mem = Mem.baseDisp(.rbp, -16) }), &.{ 0x66, 0x0F, 0x10, 0x45, 0xF0 });
    try expectEncoding(movupdStore(Mem.baseDisp(.rbp, -24), .xmm1), &.{ 0x66, 0x0F, 0x11, 0x4D, 0xE8 });
}

test "golden: XMM packed integer ops" {
    try expectEncoding(paddd(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0xFE, 0xC1 });
    try expectEncoding(psubd(.xmm2, .{ .reg = .xmm3 }), &.{ 0x66, 0x0F, 0xFA, 0xD3 });
    try expectEncoding(paddq(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0xD4, 0xC1 });
    try expectEncoding(psubq(.xmm2, .{ .reg = .xmm3 }), &.{ 0x66, 0x0F, 0xFB, 0xD3 });
    try expectEncoding(pcmpgtd(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0x66, 0xC1 });
    try expectEncoding(pmuludq(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0xF4, 0xC1 });
    try expectEncoding(pand(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0xDB, 0xC1 });
    try expectEncoding(por(.xmm2, .{ .reg = .xmm0 }), &.{ 0x66, 0x0F, 0xEB, 0xD0 });
    try expectEncoding(pxor(.xmm0, .{ .reg = .xmm0 }), &.{ 0x66, 0x0F, 0xEF, 0xC0 });
    try expectEncoding(pshufd(.xmm0, .{ .reg = .xmm1 }, 0), &.{ 0x66, 0x0F, 0x70, 0xC1, 0x00 });
}

test "golden: push/pop and immediates" {
    try expectEncoding(pushReg(.rbp), &.{0x55});
    try expectEncoding(pushReg(.r12), &.{ 0x41, 0x54 });
    try expectEncoding(popReg(.rbp), &.{0x5D});
    try expectEncoding(popReg(.r12), &.{ 0x41, 0x5C });
    try expectEncoding(subRegImm(.rsp, 8), &.{ 0x48, 0x83, 0xEC, 0x08 });
    try expectEncoding(addRegImm(.rsp, 8), &.{ 0x48, 0x83, 0xC4, 0x08 });
}

test "golden: mov imm64, call, ret" {
    try expectEncoding(movRegImm64(.rax, 0x1122334455667788), &.{
        0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
    });
    try expectEncoding(callRel32(0), &.{ 0xE8, 0x00, 0x00, 0x00, 0x00 });
    try expectEncoding(ret(), &.{0xC3});
    try expectEncoding(syscall(), &.{ 0x0F, 0x05 });
}

test "golden: compare, setcc, movzx, jcc" {
    try expectEncoding(cmpRegReg(.rax, .rcx), &.{ 0x48, 0x39, 0xC8 });
    try expectEncoding(setcc(.rax, .e), &.{ 0x0F, 0x94, 0xC0 });
    try expectEncoding(movzxReg8(.rax, .rax), &.{ 0x0F, 0xB6, 0xC0 });
    try expectEncoding(jccRel32(.ne, 0), &.{ 0x0F, 0x85, 0x00, 0x00, 0x00, 0x00 });
}

test "golden: movsx/movzx and byte/word stores" {
    const mem = Mem.baseDisp(.rbp, -8);
    try expectEncoding(movzxRegMem8(.rax, mem), &.{ 0x48, 0x0F, 0xB6, 0x45, 0xF8 });
    try expectEncoding(movzxRegMem16(.rax, mem), &.{ 0x48, 0x0F, 0xB7, 0x45, 0xF8 });
    try expectEncoding(movsxRegMem8(.rax, mem), &.{ 0x48, 0x0F, 0xBE, 0x45, 0xF8 });
    try expectEncoding(movsxRegMem16(.rax, mem), &.{ 0x48, 0x0F, 0xBF, 0x45, 0xF8 });
    try expectEncoding(movMemReg8(mem, .rax), &.{ 0x88, 0x45, 0xF8 });
    try expectEncoding(movMemReg16(mem, .rax), &.{ 0x66, 0x89, 0x45, 0xF8 });
}

test "golden: logical and/or" {
    try expectEncoding(andRegReg(.rax, .rcx), &.{ 0x48, 0x21, 0xC8 });
    try expectEncoding(orRegReg(.rax, .rcx), &.{ 0x48, 0x09, 0xC8 });
}

test "golden: vfmadd231ss + vfmadd231sd (FMA3 native lowering)" {
    try expectEncoding(vfmadd231ss(.xmm2, .xmm0, .xmm1), &.{ 0xC4, 0xE2, 0x79, 0xB9, 0xD1 });

    try expectEncoding(vfmadd231sd(.xmm2, .xmm0, .xmm1), &.{ 0xC4, 0xE2, 0xF9, 0xB9, 0xD1 });

    try expectEncoding(vfmadd231sd(.xmm8, .xmm0, .xmm1), &.{ 0xC4, 0x62, 0xF9, 0xB9, 0xC1 });
}

test "golden: movdXmmFromReg32 + movqXmmFromReg64 (2^63-split cast support)" {
    try expectEncoding(movdXmmFromReg32(.xmm0, .rcx), &.{ 0x66, 0x0F, 0x6E, 0xC1 });
    try expectEncoding(movdXmmFromMem32(.xmm0, Mem.baseDisp(.rbp, -8)), &.{ 0x66, 0x0F, 0x6E, 0x45, 0xF8 });
    try expectEncoding(movqXmmFromReg64(.xmm1, .rdx), &.{ 0x66, 0x48, 0x0F, 0x6E, 0xCA });
    try expectEncoding(movqXmmFromReg64(.xmm0, .r12), &.{ 0x66, 0x49, 0x0F, 0x6E, 0xC4 });
    try expectEncoding(movqXmmFromMem64(.xmm0, Mem.baseDisp(.rbp, -8)), &.{ 0x66, 0x48, 0x0F, 0x6E, 0x45, 0xF8 });
    try expectEncoding(movdMemFromXmm32(Mem.baseDisp(.rbp, -8), .xmm0), &.{ 0x66, 0x0F, 0x7E, 0x45, 0xF8 });
    try expectEncoding(
        movqMemFromXmm64(Mem.baseDisp(.rbp, -16), .xmm1),
        &.{ 0x66, 0x48, 0x0F, 0x7E, 0x4D, 0xF0 },
    );
}

test "golden: shrRegImm + andRegImm (Hacker's Delight cast support)" {
    try expectEncoding(shrRegImm(.rax, 1), &.{ 0x48, 0xC1, 0xE8, 0x01 });
    try expectEncoding(shrRegImm(.r12, 5), &.{ 0x49, 0xC1, 0xEC, 0x05 });

    try expectEncoding(andRegImm(.rax, 1), &.{ 0x48, 0x83, 0xE0, 0x01 });
    try expectEncoding(andRegImm(.rax, 0x12345678), &.{ 0x48, 0x81, 0xE0, 0x78, 0x56, 0x34, 0x12 });
}

test "golden: movss/movsd stores" {
    const mem = Mem.baseDisp(.rbp, -8);
    try expectEncoding(movssStore(mem, .xmm0), &.{ 0xF3, 0x0F, 0x11, 0x45, 0xF8 });
    try expectEncoding(movsdStore(mem, .xmm1), &.{ 0xF2, 0x0F, 0x11, 0x4D, 0xF8 });
}

test "golden: neg and cmov" {
    try expectEncoding(negReg(.rax), &.{ 0x48, 0xF7, 0xD8 });
    try expectEncoding(negReg32(.rax), &.{ 0xF7, 0xD8 });
    try expectEncoding(negReg(.r12), &.{ 0x49, 0xF7, 0xDC });
    try expectEncoding(divReg(.rcx), &.{ 0x48, 0xF7, 0xF1 });
    try expectEncoding(divReg32(.rcx), &.{ 0xF7, 0xF1 });
    try expectEncoding(idivReg(.rcx), &.{ 0x48, 0xF7, 0xF9 });
    try expectEncoding(idivReg32(.rcx), &.{ 0xF7, 0xF9 });
    try expectEncoding(mulReg(.rcx), &.{ 0x48, 0xF7, 0xE1 });
    try expectEncoding(mulReg32(.rcx), &.{ 0xF7, 0xE1 });

    try expectEncoding(cmovgRegReg(.rax, .rcx), &.{ 0x48, 0x0F, 0x4F, 0xC1 });
    try expectEncoding(cmovgRegReg32(.rax, .rcx), &.{ 0x0F, 0x4F, 0xC1 });
    try expectEncoding(cmovlRegReg(.rax, .rcx), &.{ 0x48, 0x0F, 0x4C, 0xC1 });
    try expectEncoding(cmovlRegReg32(.rax, .rcx), &.{ 0x0F, 0x4C, 0xC1 });

    try expectEncoding(cmovaRegReg(.rax, .rcx), &.{ 0x48, 0x0F, 0x47, 0xC1 });
    try expectEncoding(cmovaRegReg32(.rax, .rcx), &.{ 0x0F, 0x47, 0xC1 });
    try expectEncoding(cmovbRegReg(.rax, .rcx), &.{ 0x48, 0x0F, 0x42, 0xC1 });
    try expectEncoding(cmovbRegReg32(.rax, .rcx), &.{ 0x0F, 0x42, 0xC1 });

    try expectEncoding(movsxdRegReg(.rax, .rcx), &.{ 0x48, 0x63, 0xC1 });

    try expectEncoding(cmovnsRegReg(.rax, .rcx), &.{ 0x48, 0x0F, 0x49, 0xC1 });
    try expectEncoding(cmovnsRegReg32(.rax, .rcx), &.{ 0x0F, 0x49, 0xC1 });

    try expectEncoding(cmovneRegReg(.rax, .rcx), &.{ 0x48, 0x0F, 0x45, 0xC1 });
    try expectEncoding(cmovneRegReg32(.rax, .rcx), &.{ 0x0F, 0x45, 0xC1 });
}

test "golden: SSE sqrt" {
    try expectEncoding(sqrtss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x51, 0xC1 });
    try expectEncoding(sqrtsd(.xmm2, .{ .reg = .xmm3 }), &.{ 0xF2, 0x0F, 0x51, 0xD3 });
}

test "golden: bitwise + shift integer ops" {
    try expectEncoding(andRegReg(.rax, .rcx), &.{ 0x48, 0x21, 0xC8 });
    try expectEncoding(andRegReg32(.rax, .rcx), &.{ 0x21, 0xC8 });
    try expectEncoding(orRegReg(.rax, .rcx), &.{ 0x48, 0x09, 0xC8 });
    try expectEncoding(orRegReg32(.rax, .rcx), &.{ 0x09, 0xC8 });
    try expectEncoding(notReg(.rax), &.{ 0x48, 0xF7, 0xD0 });
    try expectEncoding(notReg32(.rax), &.{ 0xF7, 0xD0 });
    try expectEncoding(shlRegCl(.rax), &.{ 0x48, 0xD3, 0xE0 });
    try expectEncoding(shlRegCl32(.rax), &.{ 0xD3, 0xE0 });
    try expectEncoding(shrRegCl(.rax), &.{ 0x48, 0xD3, 0xE8 });
    try expectEncoding(shrRegCl32(.rax), &.{ 0xD3, 0xE8 });
    try expectEncoding(sarRegCl(.rax), &.{ 0x48, 0xD3, 0xF8 });
    try expectEncoding(sarRegCl32(.rax), &.{ 0xD3, 0xF8 });
    try expectEncoding(popcntRegReg(.rax, .rcx), &.{ 0xF3, 0x48, 0x0F, 0xB8, 0xC1 });
    try expectEncoding(popcntRegReg32(.rax, .rcx), &.{ 0xF3, 0x0F, 0xB8, 0xC1 });
}

test "golden: SSE conversion family" {
    try expectEncoding(cvtss2sd(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x5A, 0xC1 });
    try expectEncoding(cvtsd2ss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF2, 0x0F, 0x5A, 0xC1 });
    try expectEncoding(cvtsi2ssReg32(.xmm0, .rax), &.{ 0xF3, 0x0F, 0x2A, 0xC0 });
    try expectEncoding(cvtsi2ssReg64(.xmm0, .rax), &.{ 0xF3, 0x48, 0x0F, 0x2A, 0xC0 });
    try expectEncoding(cvtsi2sdReg32(.xmm0, .rax), &.{ 0xF2, 0x0F, 0x2A, 0xC0 });
    try expectEncoding(cvtsi2sdReg64(.xmm0, .rax), &.{ 0xF2, 0x48, 0x0F, 0x2A, 0xC0 });
    try expectEncoding(cvttss2siReg32(.rax, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x2C, 0xC1 });
    try expectEncoding(cvttss2siReg64(.rax, .{ .reg = .xmm1 }), &.{ 0xF3, 0x48, 0x0F, 0x2C, 0xC1 });
    try expectEncoding(cvttsd2siReg32(.rax, .{ .reg = .xmm1 }), &.{ 0xF2, 0x0F, 0x2C, 0xC1 });
    try expectEncoding(cvttsd2siReg64(.rax, .{ .reg = .xmm1 }), &.{ 0xF2, 0x48, 0x0F, 0x2C, 0xC1 });
}

test "golden: SSE max/min scalar" {
    try expectEncoding(maxss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x5F, 0xC1 });
    try expectEncoding(maxsd(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF2, 0x0F, 0x5F, 0xC1 });
    try expectEncoding(minss(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF3, 0x0F, 0x5D, 0xC1 });
    try expectEncoding(minsd(.xmm0, .{ .reg = .xmm1 }), &.{ 0xF2, 0x0F, 0x5D, 0xC1 });
}

test "golden: SSE sign-mask helpers" {
    try expectEncoding(pcmpeqd(.xmm1, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0x76, 0xC9 });
    try expectEncoding(psrldImm(.xmm1, 1), &.{ 0x66, 0x0F, 0x72, 0xD1, 0x01 });
    try expectEncoding(psradImm(.xmm1, 1), &.{ 0x66, 0x0F, 0x72, 0xE1, 0x01 });
    try expectEncoding(psrlqImm(.xmm1, 1), &.{ 0x66, 0x0F, 0x73, 0xD1, 0x01 });
    try expectEncoding(pslldImm(.xmm1, 31), &.{ 0x66, 0x0F, 0x72, 0xF1, 0x1F });
    try expectEncoding(psllqImm(.xmm1, 63), &.{ 0x66, 0x0F, 0x73, 0xF1, 0x3F });
    try expectEncoding(andps(.xmm0, .{ .reg = .xmm1 }), &.{ 0x0F, 0x54, 0xC1 });
    try expectEncoding(andpd(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0x54, 0xC1 });
    try expectEncoding(xorps(.xmm0, .{ .reg = .xmm1 }), &.{ 0x0F, 0x57, 0xC1 });
    try expectEncoding(xorpd(.xmm0, .{ .reg = .xmm1 }), &.{ 0x66, 0x0F, 0x57, 0xC1 });
}

test "golden: byte GPR operands select low bytes through REX" {
    const mem = Mem.baseDisp(.rbp, -8);
    try expectEncoding(movMemReg8(mem, .rsp), &.{ 0x40, 0x88, 0x65, 0xf8 });
    try expectEncoding(movMemReg8(mem, .rbp), &.{ 0x40, 0x88, 0x6d, 0xf8 });
    try expectEncoding(movMemReg8(mem, .rsi), &.{ 0x40, 0x88, 0x75, 0xf8 });
    try expectEncoding(movMemReg8(mem, .rdi), &.{ 0x40, 0x88, 0x7d, 0xf8 });
    try expectEncoding(movMemReg8(mem, .r8), &.{ 0x44, 0x88, 0x45, 0xf8 });
    try expectEncoding(movMemReg8(Mem.baseDisp(.r12, 0), .rdi), &.{ 0x41, 0x88, 0x3c, 0x24 });
    try expectEncoding(setcc(.rdi, .e), &.{ 0x40, 0x0f, 0x94, 0xc7 });
    try expectEncoding(movzxReg8(.rax, .rsi), &.{ 0x40, 0x0f, 0xb6, 0xc6 });
    try expectEncoding(movzxReg8(.r9, .rdi), &.{ 0x44, 0x0f, 0xb6, 0xcf });
}
