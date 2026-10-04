const std = @import("std");
const alloc_arena = @import("alloc_arena");
const pretty = @import("pretty");
const registers = @import("../registers/root.zig");
const disassemble = @import("../disassemble/root.zig");

const Encoded = registers.Encoded;
const GPR = registers.GPR;
const FPR = registers.FPR;
const GPRSize = registers.GPRSize;

pub const MoveWideOpcode = enum(u2) {
    movn = 0b00,
    movz = 0b10,
    movk = 0b11,
};

pub const LogicalOpcode = enum(u2) {
    @"and" = 0b00,
    orr = 0b01,
    eor = 0b10,
    ands = 0b11,
};

pub const AddSubShift = enum(u2) {
    lsl = 0b00,
    lsr = 0b01,
    asr = 0b10,
    reserved = 0b11,
};

pub const AddSubExtend = enum(u3) {
    uxtb = 0b000,
    uxth = 0b001,
    uxtw = 0b010,
    uxtx = 0b011,
    sxtb = 0b100,
    sxth = 0b101,
    sxtw = 0b110,
    sxtx = 0b111,
};

pub const LogicalShift = enum(u2) {
    lsl = 0b00,
    lsr = 0b01,
    asr = 0b10,
    ror = 0b11,
};

pub const DataProcessing2SourceOpcode = enum(u6) {
    udiv = 0b000010,
    sdiv = 0b000011,
    lslv = 0b001000,
    lsrv = 0b001001,
    asrv = 0b001010,
    rorv = 0b001011,
};

pub const LoadStoreFPSize = enum(u2) {
    single = 0b10,
    double = 0b11,
};

pub const LoadStorePairMode = enum(u3) {
    post_index = 0b001,
    signed_offset = 0b010,
    pre_index = 0b011,
};

pub const LoadStorePairFPSize = enum(u2) {
    single = 0b00,
    double = 0b01,
    quad = 0b10,
};

pub const FP1SourceOpcode = enum(u6) {
    fmov = 0b000000,
    fabs = 0b000001,
    fneg = 0b000010,
    fsqrt = 0b000011,
};

pub const FP2SourceOpcode = enum(u4) {
    fmul = 0b0000,
    fdiv = 0b0001,
    fadd = 0b0010,
    fsub = 0b0011,
    fmax = 0b0100,
    fmin = 0b0101,
};

pub const FPImmediateType = enum(u2) {
    half = 0b00,
    single = 0b01,
    double = 0b11,
};

pub const Instruction = packed union {
    data_processing_imm: DataProcessingImmediate,
    data_processing_reg: DataProcessingRegister,
    load_store: LoadStore,
    branch: Branch,
    fp_data_processing: FPDataProcessing,
    raw: u32,

    pub const size = 4;

    pub fn toBytes(self: Instruction) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], self.raw, .little);
        return buf;
    }

    pub fn fromBytes(bytes: [4]u8) Instruction {
        return .{ .raw = std.mem.readInt(u32, bytes[0..4], .little) };
    }

    pub fn write(self: Instruction, buf: []u8) void {
        std.mem.writeInt(u32, buf[0..4], self.raw, .little);
    }
};

pub const DataProcessingImmediate = packed union {
    add_sub_imm: AddSubImmediate,
    move_wide: MoveWide,
    logical_imm: LogicalImmediate,
    raw: u32,
};

pub const AddSubImmediate = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    imm12: u12,
    sh: u1,
    fixed: u6 = 0b100010,
    s: u1,
    op: AddSubOp,
    sf: u1,

    pub const AddSubOp = enum(u1) { add = 0, sub = 1 };

    pub fn add(rd: Encoded, rn: Encoded, imm: u12, size: GPRSize) Instruction {
        return .{
            .data_processing_imm = .{
                .add_sub_imm = .{
                    .rd = rd,
                    .rn = rn,
                    .imm12 = imm,
                    .sh = 0,
                    .s = 0,
                    .op = .add,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn adds(rd: Encoded, rn: Encoded, imm: u12, size: GPRSize) Instruction {
        return .{
            .data_processing_imm = .{
                .add_sub_imm = .{
                    .rd = rd,
                    .rn = rn,
                    .imm12 = imm,
                    .sh = 0,
                    .s = 1,
                    .op = .add,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn sub(rd: Encoded, rn: Encoded, imm: u12, size: GPRSize) Instruction {
        return .{
            .data_processing_imm = .{
                .add_sub_imm = .{
                    .rd = rd,
                    .rn = rn,
                    .imm12 = imm,
                    .sh = 0,
                    .s = 0,
                    .op = .sub,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn subs(rd: Encoded, rn: Encoded, imm: u12, size: GPRSize) Instruction {
        return .{
            .data_processing_imm = .{
                .add_sub_imm = .{
                    .rd = rd,
                    .rn = rn,
                    .imm12 = imm,
                    .sh = 0,
                    .s = 1,
                    .op = .sub,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn cmpImm(rn: Encoded, imm: u12, size: GPRSize) Instruction {
        return subs(registers.ZR.encoded, rn, imm, size);
    }
};

pub const MoveWide = packed struct(u32) {
    rd: Encoded,
    imm16: u16,
    hw: u2,
    fixed: u6 = 0b100101,
    opc: MoveWideOpcode,
    sf: u1,

    pub fn movz(rd: Encoded, imm: u16, shift: u2, size: GPRSize) Instruction {
        return .{
            .data_processing_imm = .{
                .move_wide = .{
                    .rd = rd,
                    .imm16 = imm,
                    .hw = shift,
                    .opc = .movz,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn movk(rd: Encoded, imm: u16, shift: u2, size: GPRSize) Instruction {
        return .{
            .data_processing_imm = .{
                .move_wide = .{
                    .rd = rd,
                    .imm16 = imm,
                    .hw = shift,
                    .opc = .movk,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn movn(rd: Encoded, imm: u16, shift: u2, size: GPRSize) Instruction {
        return .{
            .data_processing_imm = .{
                .move_wide = .{
                    .rd = rd,
                    .imm16 = imm,
                    .hw = shift,
                    .opc = .movn,
                    .sf = @backingInt(size),
                },
            },
        };
    }
};

pub const LogicalImmediate = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    imms: u6,
    immr: u6,
    n: u1,
    fixed: u6 = 0b100100,
    opc: LogicalOpcode,
    sf: u1,
};

pub const DataProcessingRegister = packed union {
    add_sub_shifted: AddSubShiftedRegister,
    add_sub_extended: AddSubExtendedRegister,
    logical_shifted: LogicalShiftedRegister,
    data_proc_2src: DataProcessing2Source,
    data_proc_3src: DataProcessing3Source,
    conditional_select: ConditionalSelect,
    raw: u32,
};

pub const AddSubShiftedRegister = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    imm6: u6,
    rm: Encoded,
    fixed0: u1 = 0,
    shift: AddSubShift,
    fixed1: u5 = 0b01011,
    s: u1,
    op: u1,
    sf: u1,

    pub fn addReg(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .add_sub_shifted = .{
                    .rd = rd,
                    .rn = rn,
                    .imm6 = 0,
                    .rm = rm,
                    .shift = .lsl,
                    .s = 0,
                    .op = 0,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn addsReg(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .add_sub_shifted = .{
                    .rd = rd,
                    .rn = rn,
                    .imm6 = 0,
                    .rm = rm,
                    .shift = .lsl,
                    .s = 1,
                    .op = 0,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn subReg(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .add_sub_shifted = .{
                    .rd = rd,
                    .rn = rn,
                    .imm6 = 0,
                    .rm = rm,
                    .shift = .lsl,
                    .s = 0,
                    .op = 1,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn subsReg(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .add_sub_shifted = .{
                    .rd = rd,
                    .rn = rn,
                    .imm6 = 0,
                    .rm = rm,
                    .shift = .lsl,
                    .s = 1,
                    .op = 1,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn cmpReg(rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return subsReg(registers.ZR.encoded, rn, rm, size);
    }
};

pub const AddSubExtendedRegister = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    imm3: u3,
    option: AddSubExtend,
    rm: Encoded,
    fixed0: u1 = 1,
    fixed1: u2 = 0b01,
    fixed2: u5 = 0b01011,
    s: u1,
    op: u1,
    sf: u1,
};

pub const LogicalShiftedRegister = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    imm6: u6,
    rm: Encoded,
    n: u1,
    shift: LogicalShift,
    fixed: u5 = 0b01010,
    opc: LogicalOpcode,
    sf: u1,

    pub fn andReg(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .logical_shifted = .{
                    .rd = rd,
                    .rn = rn,
                    .imm6 = 0,
                    .rm = rm,
                    .n = 0,
                    .shift = .lsl,
                    .opc = .@"and",
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn orrReg(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .logical_shifted = .{
                    .rd = rd,
                    .rn = rn,
                    .imm6 = 0,
                    .rm = rm,
                    .n = 0,
                    .shift = .lsl,
                    .opc = .orr,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn eorReg(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .logical_shifted = .{
                    .rd = rd,
                    .rn = rn,
                    .imm6 = 0,
                    .rm = rm,
                    .n = 0,
                    .shift = .lsl,
                    .opc = .eor,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn movReg(rd: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return orrReg(rd, registers.ZR.encoded, rm, size);
    }
};

pub const DataProcessing2Source = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    opcode: DataProcessing2SourceOpcode,
    rm: Encoded,
    fixed: u8 = 0b11010110,
    s: u1 = 0,
    fixed2: u1 = 0,
    sf: u1,

    pub fn udiv(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .data_proc_2src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .udiv,
                    .rm = rm,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn sdiv(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .data_proc_2src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .sdiv,
                    .rm = rm,
                    .sf = @backingInt(size),
                },
            },
        };
    }
};

pub const DataProcessing3Source = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    ra: Encoded,
    o0: u1,
    rm: Encoded,
    op31: u3,
    fixed: u5 = 0b11011,
    op54: u2,
    sf: u1,

    pub fn mul(rd: Encoded, rn: Encoded, rm: Encoded, size: GPRSize) Instruction {
        return madd(rd, rn, rm, registers.ZR.encoded, size);
    }

    pub fn madd(rd: Encoded, rn: Encoded, rm: Encoded, ra: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .data_proc_3src = .{
                    .rd = rd,
                    .rn = rn,
                    .ra = ra,
                    .o0 = 0,
                    .rm = rm,
                    .op31 = 0b000,
                    .op54 = 0b00,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn msub(rd: Encoded, rn: Encoded, rm: Encoded, ra: Encoded, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .data_proc_3src = .{
                    .rd = rd,
                    .rn = rn,
                    .ra = ra,
                    .o0 = 1,
                    .rm = rm,
                    .op31 = 0b000,
                    .op54 = 0b00,
                    .sf = @backingInt(size),
                },
            },
        };
    }
};

pub const ConditionalSelect = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    op2: u2,
    cond: Condition,
    rm: Encoded,
    fixed0: u1 = 0,
    fixed1: u2 = 0b10,
    fixed2: u5 = 0b11010,
    s: u1 = 0,
    op: u1,
    sf: u1,

    pub fn csel(rd: Encoded, rn: Encoded, rm: Encoded, cond: Condition, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .conditional_select = .{
                    .rd = rd,
                    .rn = rn,
                    .op2 = 0b00,
                    .cond = cond,
                    .rm = rm,
                    .op = 0,
                    .sf = @backingInt(size),
                },
            },
        };
    }

    pub fn cset(rd: Encoded, cond: Condition, size: GPRSize) Instruction {
        return .{
            .data_processing_reg = .{
                .conditional_select = .{
                    .rd = rd,
                    .rn = registers.ZR.encoded,
                    .op2 = 0b01,
                    .cond = cond.invert(),
                    .rm = registers.ZR.encoded,
                    .op = 0,
                    .sf = @backingInt(size),
                },
            },
        };
    }
};

pub const LoadStore = packed union {
    load_store_reg_imm: LoadStoreRegImm,
    load_store_reg_imm_fp: LoadStoreRegImmFP,
    load_store_pair: LoadStorePair,
    load_store_pair_fp: LoadStorePairFP,
    raw: u32,
};

/// LDR Xt, [PC, #imm19*4]. The caller bounds the signed displacement.
pub const LoadLiteral = struct {
    pub fn ldrX(rt: Encoded, offset: i19) Instruction {
        const immediate: u19 = @bitCast(offset);
        return .{ .raw = 0x58000000 | (@as(u32, immediate) << 5) | @as(u32, @backingInt(rt)) };
    }
};

pub const LoadStoreRegImm = packed struct(u32) {
    rt: Encoded,
    rn: Encoded,
    imm12: u12,
    opc: u2,
    fixed_01: u2 = 0b01,
    v: u1 = 0,
    fixed_111: u3 = 0b111,
    size: u2,

    pub fn ldr(rt: Encoded, rn: Encoded, offset: u12, gpr_size: GPRSize) Instruction {
        return .{
            .load_store = .{
                .load_store_reg_imm = .{
                    .rt = rt,
                    .rn = rn,
                    .imm12 = offset,
                    .opc = 0b01,
                    .size = switch (gpr_size) {
                        .w => 0b10,
                        .x => 0b11,
                    },
                },
            },
        };
    }

    pub fn str(rt: Encoded, rn: Encoded, offset: u12, gpr_size: GPRSize) Instruction {
        return .{
            .load_store = .{
                .load_store_reg_imm = .{
                    .rt = rt,
                    .rn = rn,
                    .imm12 = offset,
                    .opc = 0b00,
                    .size = switch (gpr_size) {
                        .w => 0b10,
                        .x => 0b11,
                    },
                },
            },
        };
    }
};

pub const LoadStoreRegImmFP = packed struct(u32) {
    rt: Encoded,
    rn: Encoded,
    imm12: u12,
    opc: u2,
    fixed_01: u2 = 0b01,
    v: u1 = 1,
    fixed_111: u3 = 0b111,
    size: u2,

    pub fn ldr(rt: Encoded, rn: Encoded, offset: u12, fp_size: LoadStoreFPSize) Instruction {
        return .{
            .load_store = .{
                .load_store_reg_imm_fp = .{
                    .rt = rt,
                    .rn = rn,
                    .imm12 = offset,
                    .opc = 0b01,
                    .size = @backingInt(fp_size),
                },
            },
        };
    }

    pub fn str(rt: Encoded, rn: Encoded, offset: u12, fp_size: LoadStoreFPSize) Instruction {
        return .{
            .load_store = .{
                .load_store_reg_imm_fp = .{
                    .rt = rt,
                    .rn = rn,
                    .imm12 = offset,
                    .opc = 0b00,
                    .size = @backingInt(fp_size),
                },
            },
        };
    }
};

fn scalePairOffsetBytes(byte_offset: i32, scale: i32) i7 {
    std.debug.assert(scale > 0);
    std.debug.assert(@mod(byte_offset, scale) == 0);
    return @intCast(@divTrunc(byte_offset, scale));
}

pub const LoadStorePair = packed struct(u32) {
    rt: Encoded,
    rn: Encoded,
    rt2: Encoded,
    imm7: i7,
    l: u1,
    op2: LoadStorePairMode,
    v: u1 = 0,
    fixed: u3 = 0b101,
    opc: u2,

    pub fn stp(rt: Encoded, rt2: Encoded, rn: Encoded, offset: i7, gpr_size: GPRSize) Instruction {
        return .{
            .load_store = .{
                .load_store_pair = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 0,
                    .op2 = .signed_offset,
                    .opc = @as(u2, @backingInt(gpr_size)) << 1,
                },
            },
        };
    }

    pub fn stpBytes(rt: Encoded, rt2: Encoded, rn: Encoded, byte_offset: i32, gpr_size: GPRSize) Instruction {
        const scale: i32 = switch (gpr_size) {
            .w => 4,
            .x => 8,
        };
        return stp(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), gpr_size);
    }

    pub fn stpPre(rt: Encoded, rt2: Encoded, rn: Encoded, offset: i7, gpr_size: GPRSize) Instruction {
        return .{
            .load_store = .{
                .load_store_pair = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 0,
                    .op2 = .pre_index,
                    .opc = @as(u2, @backingInt(gpr_size)) << 1,
                },
            },
        };
    }

    pub fn stpPreBytes(rt: Encoded, rt2: Encoded, rn: Encoded, byte_offset: i32, gpr_size: GPRSize) Instruction {
        const scale: i32 = switch (gpr_size) {
            .w => 4,
            .x => 8,
        };
        return stpPre(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), gpr_size);
    }

    pub fn ldp(rt: Encoded, rt2: Encoded, rn: Encoded, offset: i7, gpr_size: GPRSize) Instruction {
        return .{
            .load_store = .{
                .load_store_pair = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 1,
                    .op2 = .signed_offset,
                    .opc = @as(u2, @backingInt(gpr_size)) << 1,
                },
            },
        };
    }

    pub fn ldpBytes(rt: Encoded, rt2: Encoded, rn: Encoded, byte_offset: i32, gpr_size: GPRSize) Instruction {
        const scale: i32 = switch (gpr_size) {
            .w => 4,
            .x => 8,
        };
        return ldp(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), gpr_size);
    }

    pub fn ldpPost(rt: Encoded, rt2: Encoded, rn: Encoded, offset: i7, gpr_size: GPRSize) Instruction {
        return .{
            .load_store = .{
                .load_store_pair = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 1,
                    .op2 = .post_index,
                    .opc = @as(u2, @backingInt(gpr_size)) << 1,
                },
            },
        };
    }

    pub fn ldpPostBytes(rt: Encoded, rt2: Encoded, rn: Encoded, byte_offset: i32, gpr_size: GPRSize) Instruction {
        const scale: i32 = switch (gpr_size) {
            .w => 4,
            .x => 8,
        };
        return ldpPost(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), gpr_size);
    }
};

pub const LoadStorePairFP = packed struct(u32) {
    rt: Encoded,
    rn: Encoded,
    rt2: Encoded,
    imm7: i7,
    l: u1,
    op2: LoadStorePairMode,
    v: u1 = 1,
    fixed: u3 = 0b101,
    opc: LoadStorePairFPSize,

    pub fn stp(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        offset: i7,
        size: LoadStorePairFPSize,
    ) Instruction {
        return .{
            .load_store = .{
                .load_store_pair_fp = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 0,
                    .op2 = .signed_offset,
                    .opc = size,
                },
            },
        };
    }

    pub fn stpBytes(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        byte_offset: i32,
        size: LoadStorePairFPSize,
    ) Instruction {
        const scale: i32 = switch (size) {
            .single => 4,
            .double => 8,
            .quad => 16,
        };
        return stp(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), size);
    }

    pub fn stpPre(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        offset: i7,
        size: LoadStorePairFPSize,
    ) Instruction {
        return .{
            .load_store = .{
                .load_store_pair_fp = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 0,
                    .op2 = .pre_index,
                    .opc = size,
                },
            },
        };
    }

    pub fn stpPreBytes(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        byte_offset: i32,
        size: LoadStorePairFPSize,
    ) Instruction {
        const scale: i32 = switch (size) {
            .single => 4,
            .double => 8,
            .quad => 16,
        };
        return stpPre(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), size);
    }

    pub fn ldp(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        offset: i7,
        size: LoadStorePairFPSize,
    ) Instruction {
        return .{
            .load_store = .{
                .load_store_pair_fp = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 1,
                    .op2 = .signed_offset,
                    .opc = size,
                },
            },
        };
    }

    pub fn ldpBytes(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        byte_offset: i32,
        size: LoadStorePairFPSize,
    ) Instruction {
        const scale: i32 = switch (size) {
            .single => 4,
            .double => 8,
            .quad => 16,
        };
        return ldp(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), size);
    }

    pub fn ldpPost(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        offset: i7,
        size: LoadStorePairFPSize,
    ) Instruction {
        return .{
            .load_store = .{
                .load_store_pair_fp = .{
                    .rt = rt,
                    .rn = rn,
                    .rt2 = rt2,
                    .imm7 = offset,
                    .l = 1,
                    .op2 = .post_index,
                    .opc = size,
                },
            },
        };
    }

    pub fn ldpPostBytes(
        rt: Encoded,
        rt2: Encoded,
        rn: Encoded,
        byte_offset: i32,
        size: LoadStorePairFPSize,
    ) Instruction {
        const scale: i32 = switch (size) {
            .single => 4,
            .double => 8,
            .quad => 16,
        };
        return ldpPost(rt, rt2, rn, scalePairOffsetBytes(byte_offset, scale), size);
    }
};

pub const Branch = packed union {
    unconditional_imm: UnconditionalBranchImm,
    conditional: ConditionalBranch,
    unconditional_reg: UnconditionalBranchReg,
    raw: u32,
};

pub const UnconditionalBranchImm = packed struct(u32) {
    imm26: i26,
    fixed: u5 = 0b00101,
    op: u1,

    pub fn b(offset: i26) Instruction {
        return .{
            .branch = .{
                .unconditional_imm = .{
                    .imm26 = offset,
                    .op = 0,
                },
            },
        };
    }

    pub fn bl(offset: i26) Instruction {
        return .{
            .branch = .{
                .unconditional_imm = .{
                    .imm26 = offset,
                    .op = 1,
                },
            },
        };
    }
};

pub const ConditionalBranch = packed struct(u32) {
    cond: Condition,
    fixed0: u1 = 0,
    imm19: i19,
    fixed1: u1 = 0,
    fixed2: u7 = 0b0101010,

    pub fn bCond(cond: Condition, offset: i19) Instruction {
        return .{
            .branch = .{
                .conditional = .{
                    .cond = cond,
                    .imm19 = offset,
                },
            },
        };
    }
};

pub const UnconditionalBranchReg = packed struct(u32) {
    fixed0: u5 = 0b00000,
    rn: Encoded,
    fixed1: u6 = 0b000000,
    op2: u5,
    opc: u4,
    fixed2: u7 = 0b1101011,

    pub fn ret(rn: Encoded) Instruction {
        return .{
            .branch = .{
                .unconditional_reg = .{
                    .rn = rn,
                    .op2 = 0b11111,
                    .opc = 0b0010,
                },
            },
        };
    }

    pub fn retLr() Instruction {
        return ret(GPR.lr.encode());
    }

    pub fn br(rn: Encoded) Instruction {
        return .{
            .branch = .{
                .unconditional_reg = .{
                    .rn = rn,
                    .op2 = 0b11111,
                    .opc = 0b0000,
                },
            },
        };
    }

    pub fn blr(rn: Encoded) Instruction {
        return .{
            .branch = .{
                .unconditional_reg = .{
                    .rn = rn,
                    .op2 = 0b11111,
                    .opc = 0b0001,
                },
            },
        };
    }
};

pub const FPDataProcessing = packed union {
    fp_1src: FP1Source,
    fp_2src: FP2Source,
    fp_compare: FPCompare,
    fp_conversion: FPConversion,
    fp_imm: FPImmediate,
    fmov_general: FMovGeneral,
    raw: u32,
};

pub const FP1Source = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    fixed0: u5 = 0b10000,
    opcode: FP1SourceOpcode,
    fixed1: u1 = 1,
    ptype: FP2Source.FPType,
    fixed2: u5 = 0b11110,
    s: u1 = 0,
    fixed3: u1 = 0,
    m: u1 = 0,

    pub fn fabs(rd: Encoded, rn: Encoded, ftype: FP2Source.FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_1src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fabs,
                    .ptype = ftype,
                },
            },
        };
    }

    pub fn fneg(rd: Encoded, rn: Encoded, ftype: FP2Source.FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_1src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fneg,
                    .ptype = ftype,
                },
            },
        };
    }

    pub fn fsqrt(rd: Encoded, rn: Encoded, ftype: FP2Source.FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_1src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fsqrt,
                    .ptype = ftype,
                },
            },
        };
    }

    pub fn fmov(rd: Encoded, rn: Encoded, ftype: FP2Source.FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_1src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fmov,
                    .ptype = ftype,
                },
            },
        };
    }
};

pub const FP2Source = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    fixed0: u2 = 0b10,
    opcode: FP2SourceOpcode,
    rm: Encoded,
    fixed1: u1 = 1,
    ptype: FPType,
    fixed2: u5 = 0b11110,
    m: u1 = 0,
    fixed3: u1 = 0,
    s: u1 = 0,

    pub const FPType = enum(u2) {
        single = 0b00,
        double = 0b01,
        half = 0b11,
    };

    pub fn fadd(rd: Encoded, rn: Encoded, rm: Encoded, ftype: FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_2src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fadd,
                    .rm = rm,
                    .ptype = ftype,
                },
            },
        };
    }

    pub fn fsub(rd: Encoded, rn: Encoded, rm: Encoded, ftype: FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_2src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fsub,
                    .rm = rm,
                    .ptype = ftype,
                },
            },
        };
    }

    pub fn fmul(rd: Encoded, rn: Encoded, rm: Encoded, ftype: FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_2src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fmul,
                    .rm = rm,
                    .ptype = ftype,
                },
            },
        };
    }

    pub fn fdiv(rd: Encoded, rn: Encoded, rm: Encoded, ftype: FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_2src = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = .fdiv,
                    .rm = rm,
                    .ptype = ftype,
                },
            },
        };
    }
};

pub const FPCompare = packed struct(u32) {
    opcode2: u5,
    rn: Encoded,
    fixed0: u4 = 0b1000,
    op: u2,
    rm: Encoded,
    fixed1: u1 = 1,
    ptype: FP2Source.FPType,
    fixed2: u5 = 0b11110,
    m: u1 = 0,
    fixed3: u1 = 0,
    s: u1 = 0,

    pub fn fcmp(rn: Encoded, rm: Encoded, ftype: FP2Source.FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_compare = .{
                    .opcode2 = 0b00000,
                    .rn = rn,
                    .op = 0b00,
                    .rm = rm,
                    .ptype = ftype,
                },
            },
        };
    }

    pub fn fcmpZero(rn: Encoded, ftype: FP2Source.FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_compare = .{
                    .opcode2 = 0b01000,
                    .rn = rn,
                    .op = 0b00,
                    .rm = @fromBackingInt(@intCast(0)),
                    .ptype = ftype,
                },
            },
        };
    }
};

pub const FPConversion = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    fixed0: u6 = 0b000000,
    opcode: u3,
    rmode: u2,
    fixed1: u1 = 0,
    ptype: u2,
    fixed2: u5 = 0b11110,
    s: u1 = 0,
    fixed3: u1 = 0,
    sf: u1,

    /// SCVTF Dd, Xn converts the full signed word under the current FPCR.
    pub fn scvtfDoubleFromX(rd: Encoded, rn: Encoded) Instruction {
        return .{ .fp_data_processing = .{ .fp_conversion = .{
            .rd = rd,
            .rn = rn,
            .opcode = 0b010,
            .rmode = 0,
            .fixed1 = 1,
            .ptype = 0b01,
            .sf = 1,
        } } };
    }

    /// UCVTF Dd, Xn converts the full unsigned word under the current FPCR.
    pub fn ucvtfDoubleFromX(rd: Encoded, rn: Encoded) Instruction {
        return .{ .fp_data_processing = .{ .fp_conversion = .{
            .rd = rd,
            .rn = rn,
            .opcode = 0b011,
            .rmode = 0,
            .fixed1 = 1,
            .ptype = 0b01,
            .sf = 1,
        } } };
    }

    /// FCVTZS Xd, Dn truncates a finite double toward signed 64-bit zero.
    /// Callers must guard their narrower declared result interval first.
    pub fn fcvtzsXFromDouble(rd: Encoded, rn: Encoded) Instruction {
        return .{ .fp_data_processing = .{ .fp_conversion = .{
            .rd = rd,
            .rn = rn,
            .opcode = 0b000,
            .rmode = 0b11,
            .fixed1 = 1,
            .ptype = 0b01,
            .sf = 1,
        } } };
    }

    /// FCVTZU Xd, Dn truncates a finite double toward unsigned 64-bit zero.
    pub fn fcvtzuXFromDouble(rd: Encoded, rn: Encoded) Instruction {
        return .{ .fp_data_processing = .{ .fp_conversion = .{
            .rd = rd,
            .rn = rn,
            .opcode = 0b001,
            .rmode = 0b11,
            .fixed1 = 1,
            .ptype = 0b01,
            .sf = 1,
        } } };
    }
};

pub const FPImmediate = packed struct(u32) {
    rd: Encoded,
    fixed0: u5 = 0b00000,
    fixed1: u3 = 0b100,
    imm8: u8,
    ptype: FPImmediateType,
    fixed2: u5 = 0b11100,
    fixed3: u4 = 0b0001,

    fn immTypeFromFP(ftype: FP2Source.FPType) FPImmediateType {
        return switch (ftype) {
            .half => .half,
            .single => .single,
            .double => .double,
        };
    }

    pub fn fmovImm(rd: Encoded, imm8: u8, ftype: FP2Source.FPType) Instruction {
        return .{
            .fp_data_processing = .{
                .fp_imm = .{
                    .rd = rd,
                    .imm8 = imm8,
                    .ptype = immTypeFromFP(ftype),
                },
            },
        };
    }

    pub fn encodeF32(value: f32) ?u8 {
        const bits: u32 = @bitCast(value);
        const sign: u8 = @intCast(bits >> 31);
        const exp: u8 = @intCast((bits >> 23) & 0xFF);
        const frac: u32 = bits & 0x7FFFFF;

        const exp_high: u8 = exp >> 3;
        if (exp_high != 0x0F and exp_high != 0x10) return null;
        if ((frac & 0x7FFFF) != 0) return null;

        const exp_low: u8 = exp & 0x7;
        const frac_top: u8 = @intCast(frac >> 19);
        return (sign << 7) | (exp_low << 4) | frac_top;
    }

    pub fn encodeF64(value: f64) ?u8 {
        const bits: u64 = @bitCast(value);
        const sign: u8 = @intCast(bits >> 63);
        const exp: u16 = @intCast((bits >> 52) & 0x7FF);
        const frac: u64 = bits & 0xFFFFFFFFFFFFF;

        const exp_high: u16 = exp >> 3;
        if (exp_high != 0x7F and exp_high != 0x80) return null;
        if ((frac & 0xFFFFFFFFFFFF) != 0) return null;

        const exp_low: u8 = @intCast(exp & 0x7);
        const frac_top: u8 = @intCast(frac >> 48);
        return (sign << 7) | (exp_low << 4) | frac_top;
    }
};

pub const FMovGeneral = packed struct(u32) {
    rd: Encoded,
    rn: Encoded,
    fixed0: u6 = 0b000000,
    opcode: u3,
    rmode: u2,
    fixed1: u1 = 1,
    ptype: u2,
    fixed2: u5 = 0b11110,
    s: u1 = 0,
    fixed3: u1 = 0,
    sf: u1,

    pub fn fmovToFprSingle(rd: Encoded, rn: Encoded) Instruction {
        return .{
            .fp_data_processing = .{
                .fmov_general = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = 0b111,
                    .rmode = 0b00,
                    .ptype = 0b00,
                    .sf = 0,
                },
            },
        };
    }

    pub fn fmovToFprDouble(rd: Encoded, rn: Encoded) Instruction {
        return .{
            .fp_data_processing = .{
                .fmov_general = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = 0b111,
                    .rmode = 0b00,
                    .ptype = 0b01,
                    .sf = 1,
                },
            },
        };
    }

    pub fn fmovFromFprSingle(rd: Encoded, rn: Encoded) Instruction {
        return .{
            .fp_data_processing = .{
                .fmov_general = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = 0b110,
                    .rmode = 0b00,
                    .ptype = 0b00,
                    .sf = 0,
                },
            },
        };
    }

    pub fn fmovFromFprDouble(rd: Encoded, rn: Encoded) Instruction {
        return .{
            .fp_data_processing = .{
                .fmov_general = .{
                    .rd = rd,
                    .rn = rn,
                    .opcode = 0b110,
                    .rmode = 0b00,
                    .ptype = 0b01,
                    .sf = 1,
                },
            },
        };
    }
};

pub const Condition = enum(u4) {
    eq = 0b0000,
    ne = 0b0001,
    cs = 0b0010,
    cc = 0b0011,
    mi = 0b0100,
    pl = 0b0101,
    vs = 0b0110,
    vc = 0b0111,
    hi = 0b1000,
    ls = 0b1001,
    ge = 0b1010,
    lt = 0b1011,
    gt = 0b1100,
    le = 0b1101,
    al = 0b1110,
    nv = 0b1111,

    pub const hs = Condition.cs;
    pub const lo = Condition.cc;

    pub fn invert(self: Condition) Condition {
        return @fromBackingInt(@intCast(@backingInt(self) ^ 1));
    }
};

fn expectEncoded(inst: Instruction, expected_hex: u32) !void {
    if (inst.raw == expected_hex) return;

    const testing = std.testing;
    const diff = inst.raw ^ expected_hex;
    var expected_asm_buf: [160]u8 = undefined;
    var actual_asm_buf: [160]u8 = undefined;
    const expected_asm = disassemble.formatInstructionRawWithDetail(expected_hex, &expected_asm_buf, true);
    const actual_asm = disassemble.formatInstructionRawWithDetail(inst.raw, &actual_asm_buf, true);

    writeEncodingMismatch(expected_hex, expected_asm, inst.raw, actual_asm, diff) catch {};

    return testing.expectEqual(expected_hex, inst.raw);
}

fn writeEncodingMismatch(
    expected_hex: u32,
    expected_asm: []const u8,
    actual_hex: u32,
    actual_asm: []const u8,
    diff: u32,
) !void {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    var report = try pretty.diagnostic.Report.init(
        arena.allocator(),
        "AArch64 encoding mismatch",
    );
    defer report.deinit();
    try report.field("Expected", "0x{x:0>8} → {s}", .{ expected_hex, expected_asm });
    try report.field("Actual", "0x{x:0>8} → {s}", .{ actual_hex, actual_asm });
    try report.field("XOR diff", "0x{x:0>8}", .{diff});
    try report.section("Bit positions that differ");
    var bit_buffer: [128]u8 = undefined;
    var bits = std.Io.Writer.fixed(&bit_buffer);
    var count: u32 = 0;
    for (0..32) |i| {
        const bit: u5 = @intCast(31 - i);
        if ((diff >> bit) & 1 != 0) {
            if (count != 0) try bits.writeByte(' ');
            try bits.print("{d}", .{bit});
            count += 1;
        }
    }
    if (count == 0) try bits.writeAll("none");
    try report.line("{s}", .{bits.buffered()});
    pretty.diagnostic.writeStderr(&report, .{ .width = 100 });
}
