const std = @import("std");
const registers = @import("../registers/root.zig");

const Encoded = registers.Encoded;

const GprSize = enum { w, x };
const GprRole = enum { base, other };

const ConditionName = [_][]const u8{
    "eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc",
    "hi", "ls", "ge", "lt", "gt", "le", "al", "nv",
};

pub fn formatInstructionRaw(raw: u32, buf: []u8) []const u8 {
    return formatInstructionRawWithDetail(raw, buf, false);
}

pub fn formatInstructionRawWithDetail(raw: u32, buf: []u8, show_offsets_in_bytes: bool) []const u8 {
    var writer = std.Io.Writer.fixed(buf);

    disassembleToWriter(raw, &writer, show_offsets_in_bytes) catch {
        return fallbackUnknown(raw, buf);
    };

    return writer.buffered();
}

pub fn disassembleToWriter(raw: u32, writer: anytype, show_offsets_in_bytes: bool) !void {
    if (try decodeBranchReg(raw, writer)) return;
    if (try decodeBranchCond(raw, writer, show_offsets_in_bytes)) return;
    if (try decodeBranchImm(raw, writer, show_offsets_in_bytes)) return;

    if (try decodeLoadStorePair(raw, writer)) return;
    if (try decodeLoadStoreRegImm(raw, writer)) return;

    if (try decodeDataProcessingImmediate(raw, writer)) return;
    if (try decodeConditionalSelect(raw, writer)) return;
    if (try decodeDataProcessingRegister(raw, writer)) return;

    if (try decodeFPImmediate(raw, writer)) return;
    if (try decodeFP(raw, writer)) return;

    try writer.print("unknown 0x{x:0>8}", .{raw});
}

fn fallbackUnknown(raw: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "unknown 0x{x:0>8}", .{raw}) catch "unknown";
}

fn bits(raw: u32, lo: u5, width: u5) u32 {
    const mask: u32 = if (width == 32) std.math.maxInt(u32) else (@as(u32, 1) << width) - 1;
    return (raw >> lo) & mask;
}

fn signExtend(value: u32, width: u6) i64 {
    const shift: u7 = @as(u7, 64) - @as(u7, width);
    return (@as(i64, @intCast(value)) << @intCast(shift)) >> @intCast(shift);
}

fn gprSizeFromBit(sf: u1) GprSize {
    return if (sf == 0) .w else .x;
}

fn gprScaleBytes(size: GprSize) u32 {
    return switch (size) {
        .w => 4,
        .x => 8,
    };
}

fn condName(cond: u4) []const u8 {
    return ConditionName[cond];
}

fn invertCond(cond: u4) u4 {
    return cond ^ 1;
}

fn formatGpr(buf: []u8, reg: Encoded, size: GprSize, role: GprRole) []const u8 {
    const n: u5 = reg.toInt();
    if (n == 31) {
        return switch (role) {
            .base => "sp",
            .other => switch (size) {
                .w => "wzr",
                .x => "xzr",
            },
        };
    }

    const prefix: u8 = switch (size) {
        .w => 'w',
        .x => 'x',
    };
    return std.fmt.bufPrint(buf, "{c}{d}", .{ prefix, n }) catch "x?";
}

fn formatFpr(buf: []u8, reg: Encoded, fp_prefix: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{c}{d}", .{ fp_prefix, reg.toInt() }) catch "v?";
}

fn formatUnsignedHex(buf: []u8, value: u64) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x}", .{value}) catch "0x?";
}

fn formatSignedHex(buf: []u8, value: i64) []const u8 {
    if (value < 0) {
        const mag: u64 = @intCast(-value);
        return std.fmt.bufPrint(buf, "-0x{x}", .{mag}) catch "-0x?";
    }
    return std.fmt.bufPrint(buf, "0x{x}", .{@as(u64, @intCast(value))}) catch "0x?";
}

fn decodeDataProcessingImmediate(raw: u32, writer: anytype) !bool {
    const fixed_23_28 = bits(raw, 23, 6);

    if (fixed_23_28 == 0b100010) {
        return decodeAddSubImmediate(raw, writer);
    }
    if (fixed_23_28 == 0b100101) {
        return decodeMoveWide(raw, writer);
    }

    return false;
}

fn decodeAddSubImmediate(raw: u32, writer: anytype) !bool {
    const sf: u1 = @intCast(bits(raw, 31, 1));
    const op: u1 = @intCast(bits(raw, 30, 1));
    const s: u1 = @intCast(bits(raw, 29, 1));
    const sh: u1 = @intCast(bits(raw, 22, 1));
    const imm12: u12 = @intCast(bits(raw, 10, 12));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const size = gprSizeFromBit(sf);
    const imm_value: u32 = if (sh == 1) (@as(u32, imm12) << 12) else imm12;

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var imm_buf: [32]u8 = undefined;

    const rn_name = formatGpr(&reg_buf0, rn, size, .other);
    const imm_name = formatUnsignedHex(&imm_buf, imm_value);

    if (s == 1 and rd.toInt() == 31) {
        try writer.print("cmp {s}, #{s}", .{ rn_name, imm_name });
        return true;
    }

    const rd_name = formatGpr(&reg_buf1, rd, size, .other);

    const base = if (op == 0) "add" else "sub";
    const suffix = if (s == 1) "s" else "";
    try writer.print("{s}{s} {s}, {s}, #{s}", .{ base, suffix, rd_name, rn_name, imm_name });
    return true;
}

fn decodeMoveWide(raw: u32, writer: anytype) !bool {
    const sf: u1 = @intCast(bits(raw, 31, 1));
    const opc: u2 = @intCast(bits(raw, 29, 2));
    const hw: u2 = @intCast(bits(raw, 21, 2));
    const imm16: u16 = @intCast(bits(raw, 5, 16));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const mnemonic = switch (opc) {
        0b00 => "movn",
        0b10 => "movz",
        0b11 => "movk",
        else => return false,
    };

    const size = gprSizeFromBit(sf);
    const shift_amount: u32 = @as(u32, hw) * 16;

    var reg_buf: [8]u8 = undefined;
    var imm_buf: [32]u8 = undefined;

    const rd_name = formatGpr(&reg_buf, rd, size, .other);
    const imm_name = formatUnsignedHex(&imm_buf, imm16);

    if (shift_amount == 0) {
        try writer.print("{s} {s}, #{s}", .{ mnemonic, rd_name, imm_name });
        return true;
    }

    try writer.print("{s} {s}, #{s}, lsl #{d}", .{ mnemonic, rd_name, imm_name, shift_amount });
    return true;
}

fn decodeDataProcessingRegister(raw: u32, writer: anytype) !bool {
    const fixed_24_28 = bits(raw, 24, 5);

    if (fixed_24_28 == 0b01011 and bits(raw, 21, 1) == 0) {
        return decodeAddSubShiftedRegister(raw, writer);
    }
    if (fixed_24_28 == 0b01010) {
        return decodeLogicalShiftedRegister(raw, writer);
    }
    if (bits(raw, 21, 8) == 0b11010110 and bits(raw, 30, 1) == 0) {
        return decodeDataProcessing2Source(raw, writer);
    }
    if (fixed_24_28 == 0b11011) {
        return decodeDataProcessing3Source(raw, writer);
    }

    return false;
}

fn decodeAddSubShiftedRegister(raw: u32, writer: anytype) !bool {
    const sf: u1 = @intCast(bits(raw, 31, 1));
    const op: u1 = @intCast(bits(raw, 30, 1));
    const s: u1 = @intCast(bits(raw, 29, 1));
    const shift: u2 = @intCast(bits(raw, 22, 2));
    const imm6: u6 = @intCast(bits(raw, 10, 6));
    const rm: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 16, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const size = gprSizeFromBit(sf);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var reg_buf2: [8]u8 = undefined;

    const rn_name = formatGpr(&reg_buf0, rn, size, .other);
    const rm_name = formatGpr(&reg_buf1, rm, size, .other);

    if (s == 1 and rd.toInt() == 31) {
        try writer.print("cmp {s}, {s}", .{ rn_name, rm_name });
        if (imm6 != 0 or shift != 0) {
            try writeShiftSuffix(writer, shift, imm6);
        }
        return true;
    }

    const rd_name = formatGpr(&reg_buf2, rd, size, .other);

    const base = if (op == 0) "add" else "sub";
    const suffix = if (s == 1) "s" else "";

    try writer.print("{s}{s} {s}, {s}, {s}", .{ base, suffix, rd_name, rn_name, rm_name });
    if (imm6 != 0 or shift != 0) {
        try writeShiftSuffix(writer, shift, imm6);
    }
    return true;
}

fn writeShiftSuffix(writer: anytype, shift: u2, amount: u6) !void {
    const shift_name = switch (shift) {
        0b00 => "lsl",
        0b01 => "lsr",
        0b10 => "asr",
        else => "ror",
    };
    try writer.print(", {s} #{d}", .{ shift_name, amount });
}

fn decodeLogicalShiftedRegister(raw: u32, writer: anytype) !bool {
    const sf: u1 = @intCast(bits(raw, 31, 1));
    const opc: u2 = @intCast(bits(raw, 29, 2));
    const shift: u2 = @intCast(bits(raw, 22, 2));
    const imm6: u6 = @intCast(bits(raw, 10, 6));
    const n: u1 = @intCast(bits(raw, 21, 1));
    const rm: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 16, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const size = gprSizeFromBit(sf);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var reg_buf2: [8]u8 = undefined;

    const rn_name = formatGpr(&reg_buf0, rn, size, .other);
    const rm_name = formatGpr(&reg_buf1, rm, size, .other);
    const rd_name = formatGpr(&reg_buf2, rd, size, .other);

    if (opc == 0b01 and n == 0 and rn.toInt() == 31 and shift == 0 and imm6 == 0) {
        try writer.print("mov {s}, {s}", .{ rd_name, rm_name });
        return true;
    }

    const mnemonic = switch (opc) {
        0b00 => "and",
        0b01 => "orr",
        0b10 => "eor",
        0b11 => "ands",
    };

    try writer.print("{s} {s}, {s}, {s}", .{ mnemonic, rd_name, rn_name, rm_name });
    if (shift != 0 or imm6 != 0) {
        try writeShiftSuffix(writer, shift, imm6);
    }
    return true;
}

fn decodeDataProcessing2Source(raw: u32, writer: anytype) !bool {
    const sf: u1 = @intCast(bits(raw, 31, 1));
    const opcode: u6 = @intCast(bits(raw, 10, 6));
    const rm: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 16, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const mnemonic = switch (opcode) {
        0b000010 => "udiv",
        0b000011 => "sdiv",
        else => return false,
    };

    const size = gprSizeFromBit(sf);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var reg_buf2: [8]u8 = undefined;

    const rd_name = formatGpr(&reg_buf0, rd, size, .other);
    const rn_name = formatGpr(&reg_buf1, rn, size, .other);
    const rm_name = formatGpr(&reg_buf2, rm, size, .other);

    try writer.print("{s} {s}, {s}, {s}", .{ mnemonic, rd_name, rn_name, rm_name });
    return true;
}

fn decodeDataProcessing3Source(raw: u32, writer: anytype) !bool {
    const sf: u1 = @intCast(bits(raw, 31, 1));
    const op54: u2 = @intCast(bits(raw, 29, 2));
    const op31: u3 = @intCast(bits(raw, 21, 3));
    const o0: u1 = @intCast(bits(raw, 15, 1));
    const rm: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 16, 5)))));
    const ra: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 10, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    if (op54 != 0 or op31 != 0) return false;

    const size = gprSizeFromBit(sf);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var reg_buf2: [8]u8 = undefined;
    var reg_buf3: [8]u8 = undefined;

    const rd_name = formatGpr(&reg_buf0, rd, size, .other);
    const rn_name = formatGpr(&reg_buf1, rn, size, .other);
    const rm_name = formatGpr(&reg_buf2, rm, size, .other);
    const ra_name = formatGpr(&reg_buf3, ra, size, .other);

    if (o0 == 0 and ra.toInt() == 31) {
        try writer.print("mul {s}, {s}, {s}", .{ rd_name, rn_name, rm_name });
        return true;
    }

    const mnemonic = if (o0 == 0) "madd" else "msub";
    try writer.print("{s} {s}, {s}, {s}, {s}", .{ mnemonic, rd_name, rn_name, rm_name, ra_name });
    return true;
}

fn decodeConditionalSelect(raw: u32, writer: anytype) !bool {
    if (bits(raw, 24, 5) != 0b11010) return false;
    if (bits(raw, 22, 2) != 0b10) return false;
    if (bits(raw, 21, 1) != 0) return false;

    const sf: u1 = @intCast(bits(raw, 31, 1));
    const op: u1 = @intCast(bits(raw, 30, 1));
    const cond: u4 = @intCast(bits(raw, 12, 4));
    const op2: u2 = @intCast(bits(raw, 10, 2));
    const rm: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 16, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    if (op != 0) return false;

    const size = gprSizeFromBit(sf);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var reg_buf2: [8]u8 = undefined;

    const rd_name = formatGpr(&reg_buf0, rd, size, .other);

    if (op2 == 0b01 and rn.toInt() == 31 and rm.toInt() == 31) {
        const original_cond = invertCond(cond);
        try writer.print("cset {s}, {s}", .{ rd_name, condName(original_cond) });
        return true;
    }

    const rn_name = formatGpr(&reg_buf1, rn, size, .other);
    const rm_name = formatGpr(&reg_buf2, rm, size, .other);

    if (op2 != 0b00) return false;

    try writer.print("csel {s}, {s}, {s}, {s}", .{ rd_name, rn_name, rm_name, condName(cond) });
    return true;
}

fn decodeLoadStoreRegImm(raw: u32, writer: anytype) !bool {
    if (bits(raw, 24, 2) != 0b01) return false;
    if (bits(raw, 27, 3) != 0b111) return false;

    const v: u1 = @intCast(bits(raw, 26, 1));
    const size_bits: u2 = @intCast(bits(raw, 30, 2));
    const opc: u2 = @intCast(bits(raw, 22, 2));
    const imm12: u12 = @intCast(bits(raw, 10, 12));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rt: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const is_load = opc == 0b01;
    if (!is_load and opc != 0b00) return false;

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var off_buf: [32]u8 = undefined;

    const mnemonic = if (is_load) "ldr" else "str";

    if (v == 0) {
        const size: GprSize = switch (size_bits) {
            0b10 => .w,
            0b11 => .x,
            else => return false,
        };
        const scale = gprScaleBytes(size);
        const byte_offset: u32 = @as(u32, imm12) * scale;

        const rt_name = formatGpr(&reg_buf0, rt, size, .other);
        const rn_name = formatGpr(&reg_buf1, rn, size, .base);

        try writer.print("{s} {s}, [", .{ mnemonic, rt_name });
        try writer.writeAll(rn_name);
        if (byte_offset != 0) {
            const off_name = formatUnsignedHex(&off_buf, byte_offset);
            try writer.print(", #{s}", .{off_name});
        }
        try writer.writeAll("]");
        return true;
    }

    const fp_prefix: u8 = switch (size_bits) {
        0b10 => 's',
        0b11 => 'd',
        else => return false,
    };
    const scale: u32 = if (fp_prefix == 's') 4 else 8;
    const byte_offset: u32 = @as(u32, imm12) * scale;

    const rt_name = formatFpr(&reg_buf0, rt, fp_prefix);
    const rn_name = formatGpr(&reg_buf1, rn, .x, .base);

    try writer.print("{s} {s}, [", .{ mnemonic, rt_name });
    try writer.writeAll(rn_name);
    if (byte_offset != 0) {
        const off_name = formatUnsignedHex(&off_buf, byte_offset);
        try writer.print(", #{s}", .{off_name});
    }
    try writer.writeAll("]");
    return true;
}

fn decodeLoadStorePair(raw: u32, writer: anytype) !bool {
    if (bits(raw, 27, 3) != 0b101) return false;

    const v: u1 = @intCast(bits(raw, 26, 1));
    const op2: u3 = @intCast(bits(raw, 23, 3));
    const l: u1 = @intCast(bits(raw, 22, 1));
    const imm7_bits: u7 = @intCast(bits(raw, 15, 7));
    const rt2: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 10, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rt: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));
    const opc: u2 = @intCast(bits(raw, 30, 2));

    const valid_op2 = op2 == 0b001 or op2 == 0b010 or op2 == 0b011;
    if (!valid_op2) return false;

    const signed_imm7: i64 = signExtend(imm7_bits, 7);

    const mnemonic = if (l == 1) "ldp" else "stp";

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var reg_buf2: [8]u8 = undefined;
    var off_buf: [32]u8 = undefined;

    const base_name = formatGpr(&reg_buf2, rn, .x, .base);

    if (v == 0) {
        const size: GprSize = switch (opc) {
            0b00 => .w,
            0b10 => .x,
            else => return false,
        };
        const scale = gprScaleBytes(size);
        const byte_offset: i64 = signed_imm7 * scale;

        const rt_name = formatGpr(&reg_buf0, rt, size, .other);
        const rt2_name = formatGpr(&reg_buf1, rt2, size, .other);

        try writer.print("{s} {s}, {s}, ", .{ mnemonic, rt_name, rt2_name });
        try writeAddressingMode(writer, base_name, op2, byte_offset, &off_buf);
        return true;
    }

    const fp_prefix: u8 = switch (opc) {
        0b00 => 's',
        0b01 => 'd',
        0b10 => 'q',
        else => return false,
    };
    const scale: i64 = switch (fp_prefix) {
        's' => 4,
        'd' => 8,
        'q' => 16,
        else => 8,
    };
    const byte_offset: i64 = signed_imm7 * scale;

    const rt_name = formatFpr(&reg_buf0, rt, fp_prefix);
    const rt2_name = formatFpr(&reg_buf1, rt2, fp_prefix);

    try writer.print("{s} {s}, {s}, ", .{ mnemonic, rt_name, rt2_name });
    try writeAddressingMode(writer, base_name, op2, byte_offset, &off_buf);
    return true;
}

fn writeAddressingMode(writer: anytype, base_name: []const u8, op2: u3, byte_offset: i64, off_buf: []u8) !void {
    const offset_text = if (byte_offset == 0) "" else formatSignedHex(off_buf, byte_offset);

    switch (op2) {
        0b010 => {
            try writer.writeAll("[");
            try writer.writeAll(base_name);
            if (byte_offset != 0) {
                try writer.print(", #{s}", .{offset_text});
            }
            try writer.writeAll("]");
        },
        0b011 => {
            try writer.writeAll("[");
            try writer.writeAll(base_name);
            if (byte_offset != 0) {
                try writer.print(", #{s}", .{offset_text});
            }
            try writer.writeAll("]!");
        },
        0b001 => {
            try writer.writeAll("[");
            try writer.writeAll(base_name);
            try writer.writeAll("]");
            if (byte_offset != 0) {
                try writer.print(", #{s}", .{offset_text});
            }
        },
        else => {
            try writer.print("[{s}]", .{base_name});
        },
    }
}

fn decodeBranchImm(raw: u32, writer: anytype, show_offsets_in_bytes: bool) !bool {
    if (bits(raw, 26, 5) != 0b00101) return false;

    const op: u1 = @intCast(bits(raw, 31, 1));
    const imm26_bits: u26 = @intCast(bits(raw, 0, 26));
    const signed_imm26: i64 = signExtend(imm26_bits, 26);
    const offset: i64 = if (show_offsets_in_bytes) signed_imm26 * 4 else signed_imm26;

    var off_buf: [32]u8 = undefined;
    const off_name = formatSignedHex(&off_buf, offset);

    const mnemonic = if (op == 1) "bl" else "b";
    try writer.print("{s} #{s}", .{ mnemonic, off_name });
    return true;
}

fn decodeBranchCond(raw: u32, writer: anytype, show_offsets_in_bytes: bool) !bool {
    if (bits(raw, 25, 7) != 0b0101010) return false;
    if (bits(raw, 24, 1) != 0) return false;
    if (bits(raw, 4, 1) != 0) return false;

    const cond: u4 = @intCast(bits(raw, 0, 4));
    const imm19_bits: u19 = @intCast(bits(raw, 5, 19));
    const signed_imm19: i64 = signExtend(imm19_bits, 19);
    const offset: i64 = if (show_offsets_in_bytes) signed_imm19 * 4 else signed_imm19;

    var off_buf: [32]u8 = undefined;
    const off_name = formatSignedHex(&off_buf, offset);

    try writer.print("b.{s} #{s}", .{ condName(cond), off_name });
    return true;
}

fn decodeBranchReg(raw: u32, writer: anytype) !bool {
    if (bits(raw, 25, 7) != 0b1101011) return false;

    const op2: u5 = @intCast(bits(raw, 16, 5));
    if (op2 != 0b11111) return false;

    const opc: u4 = @intCast(bits(raw, 21, 4));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));

    var reg_buf: [8]u8 = undefined;
    const rn_name = formatGpr(&reg_buf, rn, .x, .other);

    switch (opc) {
        0b0010 => {
            if (rn.toInt() == 30) {
                try writer.writeAll("ret");
            } else {
                try writer.print("ret {s}", .{rn_name});
            }
            return true;
        },
        0b0000 => {
            try writer.print("br {s}", .{rn_name});
            return true;
        },
        0b0001 => {
            try writer.print("blr {s}", .{rn_name});
            return true;
        },
        else => return false,
    }
}

fn decodeFPImmediate(raw: u32, writer: anytype) !bool {
    if (bits(raw, 23, 9) != 0b000111100) return false;
    if (bits(raw, 10, 3) != 0b100) return false;
    if (bits(raw, 5, 5) != 0) return false;

    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));
    const imm8: u8 = @intCast(bits(raw, 13, 8));
    const ptype: u2 = @intCast(bits(raw, 21, 2));

    const fp_prefix: u8 = switch (ptype) {
        0b00 => 'h',
        0b01 => 's',
        0b11 => 'd',
        else => 'v',
    };

    var reg_buf: [8]u8 = undefined;
    const rd_name = formatFpr(&reg_buf, rd, fp_prefix);

    try writer.print("fmov {s}, #0x{x}", .{ rd_name, imm8 });
    return true;
}

fn decodeFP(raw: u32, writer: anytype) !bool {
    if (bits(raw, 24, 5) != 0b11110) return false;
    if (bits(raw, 21, 1) != 1) return false;
    if (bits(raw, 29, 3) != 0) return false;

    if (bits(raw, 10, 5) == 0b10000) {
        return decodeFP1Source(raw, writer);
    }
    if (bits(raw, 10, 2) == 0b10) {
        return decodeFP2Source(raw, writer);
    }
    if (bits(raw, 10, 4) == 0b1000) {
        return decodeFPCompare(raw, writer);
    }
    if (bits(raw, 10, 6) == 0 and (bits(raw, 16, 3) == 0b110 or bits(raw, 16, 3) == 0b111)) {
        return decodeFMovGeneral(raw, writer);
    }

    return false;
}

fn fpPrefixFromType(ptype: u2) u8 {
    return switch (ptype) {
        0b00 => 's',
        0b01 => 'd',
        else => 'v',
    };
}

fn decodeFP1Source(raw: u32, writer: anytype) !bool {
    const opcode: u6 = @intCast(bits(raw, 15, 6));
    const ptype: u2 = @intCast(bits(raw, 22, 2));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const mnemonic = switch (opcode) {
        0b000000 => "fmov",
        0b000001 => "fabs",
        0b000010 => "fneg",
        0b000011 => "fsqrt",
        else => return false,
    };

    const fp_prefix = fpPrefixFromType(ptype);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;

    const rd_name = formatFpr(&reg_buf0, rd, fp_prefix);
    const rn_name = formatFpr(&reg_buf1, rn, fp_prefix);

    try writer.print("{s} {s}, {s}", .{ mnemonic, rd_name, rn_name });
    return true;
}

fn decodeFP2Source(raw: u32, writer: anytype) !bool {
    const opcode: u4 = @intCast(bits(raw, 12, 4));
    const ptype: u2 = @intCast(bits(raw, 22, 2));
    const rm: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 16, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    const mnemonic = switch (opcode) {
        0b0000 => "fmul",
        0b0001 => "fdiv",
        0b0010 => "fadd",
        0b0011 => "fsub",
        else => return false,
    };

    const fp_prefix = fpPrefixFromType(ptype);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;
    var reg_buf2: [8]u8 = undefined;

    const rd_name = formatFpr(&reg_buf0, rd, fp_prefix);
    const rn_name = formatFpr(&reg_buf1, rn, fp_prefix);
    const rm_name = formatFpr(&reg_buf2, rm, fp_prefix);

    try writer.print("{s} {s}, {s}, {s}", .{ mnemonic, rd_name, rn_name, rm_name });
    return true;
}

fn decodeFPCompare(raw: u32, writer: anytype) !bool {
    const opcode2: u5 = @intCast(bits(raw, 0, 5));
    const op: u2 = @intCast(bits(raw, 14, 2));
    if (op != 0) return false;

    const ptype: u2 = @intCast(bits(raw, 22, 2));
    const rm: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 16, 5)))));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));

    const fp_prefix = fpPrefixFromType(ptype);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;

    const rn_name = formatFpr(&reg_buf0, rn, fp_prefix);

    if (opcode2 == 0b01000 and rm.toInt() == 0) {
        try writer.print("fcmp {s}, #0.0", .{rn_name});
        return true;
    }

    const rm_name = formatFpr(&reg_buf1, rm, fp_prefix);
    try writer.print("fcmp {s}, {s}", .{ rn_name, rm_name });
    return true;
}

fn decodeFMovGeneral(raw: u32, writer: anytype) !bool {
    const opcode: u3 = @intCast(bits(raw, 16, 3));
    const ptype: u2 = @intCast(bits(raw, 22, 2));
    const sf: u1 = @intCast(bits(raw, 31, 1));
    const rn: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 5, 5)))));
    const rd: Encoded = @fromBackingInt(@intCast(@as(u5, @intCast(bits(raw, 0, 5)))));

    if (opcode != 0b110 and opcode != 0b111) return false;

    const fp_prefix = fpPrefixFromType(ptype);
    const gpr_size = gprSizeFromBit(sf);

    var reg_buf0: [8]u8 = undefined;
    var reg_buf1: [8]u8 = undefined;

    if (opcode == 0b111) {
        const rd_name = formatFpr(&reg_buf0, rd, fp_prefix);
        const rn_name = formatGpr(&reg_buf1, rn, gpr_size, .other);
        try writer.print("fmov {s}, {s}", .{ rd_name, rn_name });
        return true;
    }

    const rd_name = formatGpr(&reg_buf0, rd, gpr_size, .other);
    const rn_name = formatFpr(&reg_buf1, rn, fp_prefix);
    try writer.print("fmov {s}, {s}", .{ rd_name, rn_name });
    return true;
}
