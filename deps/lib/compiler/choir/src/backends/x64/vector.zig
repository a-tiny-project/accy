const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const data = @import("data.zig");
const encoding = @import("encoding.zig");
const labels = @import("labels.zig");
const registers = @import("registers/root.zig");
const scalar_backend = @import("scalar.zig");
const slot_layout = @import("slots.zig");

const ArithDialect = dialects.arith.ArithDialect;
const CmpPredicate = dialects.arith.CmpPredicate;

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
};

pub const BitwiseBinaryOp = enum {
    band,
    bor,
    bxor,
};

pub const PackedFloat = enum {
    f32x4,
    f64x2,
};

pub const PackedInt = enum {
    dwordx4,
    qwordx2,
};

pub const PackedKind = union(enum) {
    float: PackedFloat,
    int: PackedInt,
};

pub fn packedFloatKind(slot: slot_layout.VectorSlot) ?PackedFloat {
    if (!slot.is_float) return null;
    if (slot.lanes == 4 and
        slot.base.width == 32 and
        std.mem.eql(u8, slot.elem_type_name, dialects.arith.type_names.float32))
    {
        return .f32x4;
    }
    if (slot.lanes == 2 and
        slot.base.width == 64 and
        std.mem.eql(u8, slot.elem_type_name, dialects.arith.type_names.float64))
    {
        return .f64x2;
    }
    return null;
}

pub fn packedIntKind(slot: slot_layout.VectorSlot) ?PackedInt {
    if (slot.is_float) return null;
    if (slot.lanes == 4 and
        slot.base.width == 32 and
        (std.mem.eql(u8, slot.elem_type_name, dialects.arith.type_names.int32) or
            std.mem.eql(u8, slot.elem_type_name, dialects.arith.type_names.uint32)))
    {
        return .dwordx4;
    }
    if (slot.lanes == 2 and
        slot.base.width == 64 and
        (std.mem.eql(u8, slot.elem_type_name, dialects.arith.type_names.int64) or
            std.mem.eql(u8, slot.elem_type_name, dialects.arith.type_names.uint64)))
    {
        return .qwordx2;
    }
    return null;
}

pub fn packedKind(slot: slot_layout.VectorSlot) ?PackedKind {
    if (packedFloatKind(slot)) |kind| return .{ .float = kind };
    if (packedIntKind(slot)) |kind| return .{ .int = kind };
    return null;
}

fn samePackedFloatKind(lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot) ?PackedFloat {
    const lhs_kind = packedFloatKind(lhs) orelse return null;
    const rhs_kind = packedFloatKind(rhs) orelse return null;
    const result_kind = packedFloatKind(result) orelse return null;
    if (lhs_kind != rhs_kind or lhs_kind != result_kind) return null;
    return lhs_kind;
}

fn samePackedIntKind(lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot) ?PackedInt {
    if (!std.mem.eql(u8, lhs.elem_type_name, rhs.elem_type_name) or
        !std.mem.eql(u8, lhs.elem_type_name, result.elem_type_name)) return null;
    const lhs_kind = packedIntKind(lhs) orelse return null;
    const rhs_kind = packedIntKind(rhs) orelse return null;
    const result_kind = packedIntKind(result) orelse return null;
    if (lhs_kind != rhs_kind or lhs_kind != result_kind) return null;
    return lhs_kind;
}

fn samePackedResultShape(input: slot_layout.VectorSlot, result: slot_layout.VectorSlot) bool {
    return input.lanes == result.lanes and
        input.base.width == result.base.width and
        packedKind(result) != null;
}

fn sameVectorStorageShape(lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot) bool {
    return lhs.lanes == rhs.lanes and
        lhs.base.width == rhs.base.width and
        lhs.is_float == rhs.is_float and
        std.mem.eql(u8, lhs.elem_type_name, rhs.elem_type_name);
}

fn samePackedFloatCmpKind(lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot) ?PackedFloat {
    const lhs_kind = packedFloatKind(lhs) orelse return null;
    const rhs_kind = packedFloatKind(rhs) orelse return null;
    if (lhs_kind != rhs_kind) return null;
    if (!samePackedResultShape(lhs, result)) return null;
    return lhs_kind;
}

fn samePackedIntCmpKind(lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot) ?PackedInt {
    if (!std.mem.eql(u8, lhs.elem_type_name, rhs.elem_type_name)) return null;
    const lhs_kind = packedIntKind(lhs) orelse return null;
    const rhs_kind = packedIntKind(rhs) orelse return null;
    if (lhs_kind != rhs_kind) return null;
    if (!samePackedResultShape(lhs, result)) return null;
    return lhs_kind;
}

fn packedMem(slot: slot_layout.VectorSlot) encoding.Mem {
    const low_lane = slot_layout.laneSlot(slot.base, slot.lanes - 1);
    return encoding.Mem.baseDisp(.rbp, low_lane.offset);
}

pub fn emitPackedLoadFromMem(emitter: anytype, kind: PackedKind, mem: encoding.Mem, reg: registers.XMM) !void {
    switch (kind) {
        .float => |float_kind| switch (float_kind) {
            .f32x4 => try emitter.emitEncoding(encoding.movups(reg, .{ .mem = mem })),
            .f64x2 => try emitter.emitEncoding(encoding.movupd(reg, .{ .mem = mem })),
        },
        .int => |int_kind| switch (int_kind) {
            .dwordx4 => try emitter.emitEncoding(encoding.movups(reg, .{ .mem = mem })),
            .qwordx2 => try emitter.emitEncoding(encoding.movupd(reg, .{ .mem = mem })),
        },
    }
}

pub fn emitPackedStoreToMem(emitter: anytype, kind: PackedKind, mem: encoding.Mem, reg: registers.XMM) !void {
    switch (kind) {
        .float => |float_kind| switch (float_kind) {
            .f32x4 => try emitter.emitEncoding(encoding.movupsStore(mem, reg)),
            .f64x2 => try emitter.emitEncoding(encoding.movupdStore(mem, reg)),
        },
        .int => |int_kind| switch (int_kind) {
            .dwordx4 => try emitter.emitEncoding(encoding.movupsStore(mem, reg)),
            .qwordx2 => try emitter.emitEncoding(encoding.movupdStore(mem, reg)),
        },
    }
}

pub fn emitPackedLoad(emitter: anytype, slot: slot_layout.VectorSlot, reg: registers.XMM) !void {
    const kind = packedKind(slot) orelse return error.UnsupportedType;
    try emitPackedLoadFromMem(emitter, kind, packedMem(slot), reg);
}

pub fn emitPackedStore(emitter: anytype, slot: slot_layout.VectorSlot, reg: registers.XMM) !void {
    const kind = packedKind(slot) orelse return error.UnsupportedType;
    try emitPackedStoreToMem(emitter, kind, packedMem(slot), reg);
}

fn emitPackedFloatBinary(emitter: anytype, lhs: *ir.Value, rhs: *ir.Value, result: *ir.Value, op_kind: BinOp, float_kind: PackedFloat) !void {
    try emitter.loadIntoXmmPacked(lhs, .xmm0);
    try emitter.loadIntoXmmPacked(rhs, .xmm1);
    switch (float_kind) {
        .f32x4 => switch (op_kind) {
            .add => try emitter.emitEncoding(encoding.addps(.xmm0, .{ .reg = .xmm1 })),
            .sub => try emitter.emitEncoding(encoding.subps(.xmm0, .{ .reg = .xmm1 })),
            .mul => try emitter.emitEncoding(encoding.mulps(.xmm0, .{ .reg = .xmm1 })),
            .div => try emitter.emitEncoding(encoding.divps(.xmm0, .{ .reg = .xmm1 })),
        },
        .f64x2 => switch (op_kind) {
            .add => try emitter.emitEncoding(encoding.addpd(.xmm0, .{ .reg = .xmm1 })),
            .sub => try emitter.emitEncoding(encoding.subpd(.xmm0, .{ .reg = .xmm1 })),
            .mul => try emitter.emitEncoding(encoding.mulpd(.xmm0, .{ .reg = .xmm1 })),
            .div => try emitter.emitEncoding(encoding.divpd(.xmm0, .{ .reg = .xmm1 })),
        },
    }
    try emitter.storeFromXmmPacked(result, .xmm0);
}

fn emitPackedDwordMul(emitter: anytype) !void {
    try emitter.emitEncoding(encoding.movups(.xmm2, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.pmuludq(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm2, 32));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm1, 32));
    try emitter.emitEncoding(encoding.pmuludq(.xmm2, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.pcmpeqd(.xmm3, .{ .reg = .xmm3 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm3, 32));
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm3 }));
    try emitter.emitEncoding(encoding.pand(.xmm2, .{ .reg = .xmm3 }));
    try emitter.emitEncoding(encoding.psllqImm(.xmm2, 32));
    try emitter.emitEncoding(encoding.por(.xmm0, .{ .reg = .xmm2 }));
}

fn emitPackedQwordMul(emitter: anytype) !void {
    try emitter.emitEncoding(encoding.movupd(.xmm2, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm2, 32));
    try emitter.emitEncoding(encoding.movupd(.xmm3, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm3, 32));
    try emitter.emitEncoding(encoding.movupd(.xmm4, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.pmuludq(.xmm2, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.pmuludq(.xmm4, .{ .reg = .xmm3 }));
    try emitter.emitEncoding(encoding.paddq(.xmm2, .{ .reg = .xmm4 }));
    try emitter.emitEncoding(encoding.psllqImm(.xmm2, 32));
    try emitter.emitEncoding(encoding.pmuludq(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.paddq(.xmm0, .{ .reg = .xmm2 }));
}

fn emitPackedIntBinary(emitter: anytype, lhs: *ir.Value, rhs: *ir.Value, result: *ir.Value, op_kind: BinOp, int_kind: PackedInt) !void {
    try emitter.loadIntoXmmPacked(lhs, .xmm0);
    try emitter.loadIntoXmmPacked(rhs, .xmm1);
    switch (int_kind) {
        .dwordx4 => switch (op_kind) {
            .add => try emitter.emitEncoding(encoding.paddd(.xmm0, .{ .reg = .xmm1 })),
            .sub => try emitter.emitEncoding(encoding.psubd(.xmm0, .{ .reg = .xmm1 })),
            .mul => try emitPackedDwordMul(emitter),
            .div => return error.UnsupportedOperation,
        },
        .qwordx2 => switch (op_kind) {
            .add => try emitter.emitEncoding(encoding.paddq(.xmm0, .{ .reg = .xmm1 })),
            .sub => try emitter.emitEncoding(encoding.psubq(.xmm0, .{ .reg = .xmm1 })),
            .mul => try emitPackedQwordMul(emitter),
            .div => return error.UnsupportedOperation,
        },
    }
    try emitter.storeFromXmmPacked(result, .xmm0);
}

fn emitPackedIntBitwiseBinary(emitter: anytype, lhs: *ir.Value, rhs: *ir.Value, result: *ir.Value, op_kind: BitwiseBinaryOp) !void {
    try emitter.loadIntoXmmPacked(lhs, .xmm0);
    try emitter.loadIntoXmmPacked(rhs, .xmm1);
    switch (op_kind) {
        .band => try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm1 })),
        .bor => try emitter.emitEncoding(encoding.por(.xmm0, .{ .reg = .xmm1 })),
        .bxor => try emitter.emitEncoding(encoding.pxor(.xmm0, .{ .reg = .xmm1 })),
    }
    try emitter.storeFromXmmPacked(result, .xmm0);
}

fn emitPackedDwordConstantReg(emitter: anytype, reg: registers.XMM, value: u32) !void {
    try emitter.emitEncoding(encoding.movRegImm32(.rax, value));
    try emitter.emitEncoding(encoding.movdXmmFromReg32(reg, .rax));
    try emitter.emitEncoding(encoding.pshufd(reg, .{ .reg = reg }, 0));
}

fn emitPackedQwordConstantReg(emitter: anytype, reg: registers.XMM, value: u64) !void {
    try emitter.emitEncoding(encoding.movRegImm64(.rax, value));
    try emitter.emitEncoding(encoding.movqXmmFromReg64(reg, .rax));
    try emitter.emitEncoding(encoding.shufpd(reg, .{ .reg = reg }, 0));
}

fn emitPackedDwordPopCount(emitter: anytype) !void {
    try emitter.emitEncoding(encoding.movups(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrldImm(.xmm1, 1));
    try emitPackedDwordConstantReg(emitter, .xmm2, 0x5555_5555);
    try emitter.emitEncoding(encoding.pand(.xmm1, .{ .reg = .xmm2 }));
    try emitter.emitEncoding(encoding.psubd(.xmm0, .{ .reg = .xmm1 }));

    try emitPackedDwordConstantReg(emitter, .xmm2, 0x3333_3333);
    try emitter.emitEncoding(encoding.movups(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm2 }));
    try emitter.emitEncoding(encoding.psrldImm(.xmm1, 2));
    try emitter.emitEncoding(encoding.pand(.xmm1, .{ .reg = .xmm2 }));
    try emitter.emitEncoding(encoding.paddd(.xmm0, .{ .reg = .xmm1 }));

    try emitter.emitEncoding(encoding.movups(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrldImm(.xmm1, 4));
    try emitter.emitEncoding(encoding.paddd(.xmm0, .{ .reg = .xmm1 }));
    try emitPackedDwordConstantReg(emitter, .xmm2, 0x0f0f_0f0f);
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm2 }));

    try emitter.emitEncoding(encoding.movups(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrldImm(.xmm1, 8));
    try emitter.emitEncoding(encoding.paddd(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.movups(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrldImm(.xmm1, 16));
    try emitter.emitEncoding(encoding.paddd(.xmm0, .{ .reg = .xmm1 }));
    try emitPackedDwordConstantReg(emitter, .xmm2, 0x0000_003f);
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm2 }));
}

fn emitPackedQwordPopCount(emitter: anytype) !void {
    try emitter.emitEncoding(encoding.movupd(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm1, 1));
    try emitPackedQwordConstantReg(emitter, .xmm2, 0x5555_5555_5555_5555);
    try emitter.emitEncoding(encoding.pand(.xmm1, .{ .reg = .xmm2 }));
    try emitter.emitEncoding(encoding.psubq(.xmm0, .{ .reg = .xmm1 }));

    try emitPackedQwordConstantReg(emitter, .xmm2, 0x3333_3333_3333_3333);
    try emitter.emitEncoding(encoding.movupd(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm2 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm1, 2));
    try emitter.emitEncoding(encoding.pand(.xmm1, .{ .reg = .xmm2 }));
    try emitter.emitEncoding(encoding.paddq(.xmm0, .{ .reg = .xmm1 }));

    try emitter.emitEncoding(encoding.movupd(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm1, 4));
    try emitter.emitEncoding(encoding.paddq(.xmm0, .{ .reg = .xmm1 }));
    try emitPackedQwordConstantReg(emitter, .xmm2, 0x0f0f_0f0f_0f0f_0f0f);
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm2 }));

    try emitter.emitEncoding(encoding.movupd(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm1, 8));
    try emitter.emitEncoding(encoding.paddq(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.movupd(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm1, 16));
    try emitter.emitEncoding(encoding.paddq(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.movupd(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm1, 32));
    try emitter.emitEncoding(encoding.paddq(.xmm0, .{ .reg = .xmm1 }));
    try emitPackedQwordConstantReg(emitter, .xmm2, 0x0000_0000_0000_007f);
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm2 }));
}

fn emitPackedIntPopCount(emitter: anytype, input: slot_layout.VectorSlot, result: slot_layout.VectorSlot, int_kind: PackedInt) !void {
    try emitPackedLoad(emitter, input, .xmm0);
    switch (int_kind) {
        .dwordx4 => try emitPackedDwordPopCount(emitter),
        .qwordx2 => try emitPackedQwordPopCount(emitter),
    }
    try emitPackedStore(emitter, result, .xmm0);
}

fn emitPackedDwordUmulhi(emitter: anytype) !void {
    try emitter.emitEncoding(encoding.movups(.xmm2, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.movups(.xmm3, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.pmuludq(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm2, 32));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm3, 32));
    try emitter.emitEncoding(encoding.pmuludq(.xmm2, .{ .reg = .xmm3 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm0, 32));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm2, 32));
    try emitter.emitEncoding(encoding.psllqImm(.xmm2, 32));
    try emitter.emitEncoding(encoding.por(.xmm0, .{ .reg = .xmm2 }));
}

fn emitPackedIntUmulhi(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot, int_kind: PackedInt) !bool {
    if (int_kind != .dwordx4) return false;
    try emitPackedLoad(emitter, lhs, .xmm0);
    try emitPackedLoad(emitter, rhs, .xmm1);
    try emitPackedDwordUmulhi(emitter);
    try emitPackedStore(emitter, result, .xmm0);
    return true;
}

fn emitCopyVectorSlot(emitter: anytype, src: slot_layout.VectorSlot, dst: slot_layout.VectorSlot) !void {
    if (!sameVectorStorageShape(src, dst)) return error.UnsupportedType;

    if (packedKind(src) != null) {
        if (packedKind(dst) != null) {
            try emitPackedLoad(emitter, src, .xmm0);
            try emitPackedStore(emitter, dst, .xmm0);
            return;
        }
    }

    for (0..src.lanes) |lane| {
        const src_lane = slot_layout.laneSlot(src.base, lane);
        const dst_lane = slot_layout.laneSlot(dst.base, lane);
        if (src.is_float) {
            try emitter.loadSlotXmm(src_lane, .xmm0);
            try emitter.storeSlotXmm(dst_lane, .xmm0);
        } else {
            try emitter.loadSlot(src_lane, .rax);
            try emitter.storeSlot(dst_lane, .rax);
        }
    }
}

fn definingOp(value: *ir.Value) ?*ir.Operation {
    return switch (value.kind) {
        .op_result => |info| @ptrCast(@alignCast(info.owner)),
        .block_argument => null,
    };
}

fn constantIntValue(value: *ir.Value) ?i64 {
    const op = definingOp(value) orelse return null;
    const name = op.name.name;
    if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name)) {
        if (data.hasAttributes(op)) return null;
        return (ArithDialect.ConstantOp{ .op = op }).getIntValue();
    }
    if (std.mem.eql(u8, name, ArithDialect.VecConstantOp.operation_name)) {
        return (ArithDialect.VecConstantOp{ .op = op }).getIntValue();
    }
    return null;
}

/// Answers whether a literal divisor proves no lane divides by -1.
fn uniformDivisorNotNegativeOne(rhs: *ir.Value, lane_width: u8) bool {
    const divisor = uniformIntValue(rhs) orelse return false;
    return dialects.arith.scalar.truncate(divisor, lane_width) != -1;
}

/// The shift count a literal word gives lanes of `lane_width` bits, or null past the lane. The
/// word is read at the lane's width, as materialization reads it, so bits a producer left above
/// the width do not decide whether the shift is in bounds.
fn boundedShiftCount(word: i64, lane_width: u8) ?u8 {
    const value = dialects.arith.scalar.truncate(word, lane_width);
    if (value < 0) return null;
    const count: u64 = @intCast(value);
    if (count >= lane_width) return null;
    return @intCast(count);
}

fn uniformShiftCount(value: *ir.Value, lane_width: u8) ?u8 {
    const count = uniformIntValue(value) orelse return null;
    return boundedShiftCount(count, lane_width);
}

/// Answers whether the count's definition proves every lane's shift in
/// bounds: a uniform literal below `lane_width`, or a mask by one.
fn laneShiftCountInBounds(count: *ir.Value, lane_width: u8) bool {
    if (uniformIntValue(count)) |value| return boundedShiftCount(value, lane_width) != null;
    const op = definingOp(count) orelse return false;
    if (!std.mem.eql(u8, op.name.name, ArithDialect.AndOp.operation_name)) return false;
    for (op.operands.items) |operand| {
        const mask = uniformIntValue(operand.value) orelse continue;
        if (boundedShiftCount(mask, lane_width) != null) return true;
    }
    return false;
}

/// Returns the literal every lane of `value` holds, when one does.
fn uniformIntValue(value: *ir.Value) ?i64 {
    if (constantIntValue(value)) |literal| return literal;
    const op = definingOp(value) orelse return null;
    if (!std.mem.eql(u8, op.name.name, ArithDialect.SplatOp.operation_name)) return null;
    const scalar = op.getOperand(0) orelse return null;
    return constantIntValue(scalar);
}

fn emitPackedIntShiftUniform(
    emitter: anytype,
    value: slot_layout.VectorSlot,
    result: slot_layout.VectorSlot,
    kind: scalar_backend.ShiftKind,
    int_kind: PackedInt,
    count: u8,
) !bool {
    if (int_kind == .qwordx2 and kind == .shr) return false;

    try emitPackedLoad(emitter, value, .xmm0);
    switch (int_kind) {
        .dwordx4 => switch (kind) {
            .shl => try emitter.emitEncoding(encoding.pslldImm(.xmm0, count)),
            .shr => try emitter.emitEncoding(encoding.psradImm(.xmm0, count)),
            .ushr => try emitter.emitEncoding(encoding.psrldImm(.xmm0, count)),
        },
        .qwordx2 => switch (kind) {
            .shl => try emitter.emitEncoding(encoding.psllqImm(.xmm0, count)),
            .shr => unreachable,
            .ushr => try emitter.emitEncoding(encoding.psrlqImm(.xmm0, count)),
        },
    }
    try emitPackedStore(emitter, result, .xmm0);
    return true;
}

const FloatCmpPlan = struct {
    imm: u8,
    swap: bool = false,
};

fn floatCmpPlan(pred: CmpPredicate) FloatCmpPlan {
    return switch (pred) {
        .eq => .{ .imm = 0 },
        .ne => .{ .imm = 4 },
        .lt, .slt, .ult => .{ .imm = 1 },
        .le, .sle, .ule => .{ .imm = 2 },
        .gt, .sgt, .ugt => .{ .imm = 1, .swap = true },
        .ge, .sge, .uge => .{ .imm = 2, .swap = true },
    };
}

fn emitPackedFloatCmp(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot, pred: CmpPredicate, float_kind: PackedFloat) !void {
    const plan = floatCmpPlan(pred);
    if (plan.swap) {
        try emitPackedLoad(emitter, rhs, .xmm0);
        try emitPackedLoad(emitter, lhs, .xmm1);
    } else {
        try emitPackedLoad(emitter, lhs, .xmm0);
        try emitPackedLoad(emitter, rhs, .xmm1);
    }
    switch (float_kind) {
        .f32x4 => {
            try emitter.emitEncoding(encoding.cmpps(.xmm0, .{ .reg = .xmm1 }, plan.imm));
            try emitter.emitEncoding(encoding.psrldImm(.xmm0, 31));
        },
        .f64x2 => {
            try emitter.emitEncoding(encoding.cmppd(.xmm0, .{ .reg = .xmm1 }, plan.imm));
            try emitter.emitEncoding(encoding.psrlqImm(.xmm0, 63));
        },
    }
    try emitPackedStore(emitter, result, .xmm0);
}

const IntCmpRelation = enum {
    eq,
    gt,
};

const IntCmpPlan = struct {
    relation: IntCmpRelation,
    swap: bool = false,
    invert: bool = false,
    unsigned: bool = false,
};

fn intCmpPlan(pred: CmpPredicate) IntCmpPlan {
    return switch (pred) {
        .eq => .{ .relation = .eq },
        .ne => .{ .relation = .eq, .invert = true },
        .gt, .sgt => .{ .relation = .gt },
        .lt, .slt => .{ .relation = .gt, .swap = true },
        .ge, .sge => .{ .relation = .gt, .swap = true, .invert = true },
        .le, .sle => .{ .relation = .gt, .invert = true },
        .ugt => .{ .relation = .gt, .unsigned = true },
        .ult => .{ .relation = .gt, .swap = true, .unsigned = true },
        .uge => .{ .relation = .gt, .swap = true, .invert = true, .unsigned = true },
        .ule => .{ .relation = .gt, .invert = true, .unsigned = true },
    };
}

fn emitPackedAllOnes(emitter: anytype, reg: registers.XMM) !void {
    try emitter.emitEncoding(encoding.pcmpeqd(reg, .{ .reg = reg }));
}

fn emitPackedOneBits(emitter: anytype, kind: PackedInt, reg: registers.XMM) !void {
    try emitPackedAllOnes(emitter, reg);
    switch (kind) {
        .dwordx4 => try emitter.emitEncoding(encoding.psrldImm(reg, 31)),
        .qwordx2 => try emitter.emitEncoding(encoding.psrlqImm(reg, 63)),
    }
}

fn emitPackedDwordSignMask(emitter: anytype, reg: registers.XMM) !void {
    try emitPackedAllOnes(emitter, reg);
    try emitter.emitEncoding(encoding.pslldImm(reg, 31));
}

fn emitPackedIntCmpInvert(emitter: anytype, kind: PackedInt) !void {
    try emitPackedOneBits(emitter, kind, .xmm1);
    try emitter.emitEncoding(encoding.pxor(.xmm0, .{ .reg = .xmm1 }));
}

fn emitPackedDwordCmpMask(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, plan: IntCmpPlan) !void {
    if (plan.swap) {
        try emitPackedLoad(emitter, rhs, .xmm0);
        try emitPackedLoad(emitter, lhs, .xmm1);
    } else {
        try emitPackedLoad(emitter, lhs, .xmm0);
        try emitPackedLoad(emitter, rhs, .xmm1);
    }
    switch (plan.relation) {
        .eq => try emitter.emitEncoding(encoding.pcmpeqd(.xmm0, .{ .reg = .xmm1 })),
        .gt => {
            if (plan.unsigned) {
                try emitPackedDwordSignMask(emitter, .xmm2);
                try emitter.emitEncoding(encoding.pxor(.xmm0, .{ .reg = .xmm2 }));
                try emitter.emitEncoding(encoding.pxor(.xmm1, .{ .reg = .xmm2 }));
            }
            try emitter.emitEncoding(encoding.pcmpgtd(.xmm0, .{ .reg = .xmm1 }));
        },
    }
}

fn emitPackedDwordCmpBits(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, plan: IntCmpPlan) !void {
    try emitPackedDwordCmpMask(emitter, lhs, rhs, plan);
    try emitter.emitEncoding(encoding.psrldImm(.xmm0, 31));
}

fn emitPackedQwordEqCmpBits(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot) !void {
    try emitPackedLoad(emitter, lhs, .xmm0);
    try emitPackedLoad(emitter, rhs, .xmm1);
    try emitter.emitEncoding(encoding.pcmpeqd(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.pshufd(.xmm1, .{ .reg = .xmm0 }, 0xB1));
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm0, 63));
}

fn emitPackedQwordGtCmpBits(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, unsigned: bool) !void {
    try emitPackedLoad(emitter, lhs, .xmm0);
    try emitPackedLoad(emitter, rhs, .xmm1);

    try emitter.emitEncoding(encoding.movupd(.xmm2, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.movupd(.xmm3, .{ .reg = .xmm1 }));
    if (unsigned) {
        try emitPackedDwordSignMask(emitter, .xmm4);
        try emitter.emitEncoding(encoding.pxor(.xmm2, .{ .reg = .xmm4 }));
        try emitter.emitEncoding(encoding.pxor(.xmm3, .{ .reg = .xmm4 }));
    }
    try emitter.emitEncoding(encoding.pcmpgtd(.xmm2, .{ .reg = .xmm3 }));

    try emitter.emitEncoding(encoding.movupd(.xmm3, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.pcmpeqd(.xmm3, .{ .reg = .xmm1 }));

    try emitPackedDwordSignMask(emitter, .xmm4);
    try emitter.emitEncoding(encoding.pxor(.xmm0, .{ .reg = .xmm4 }));
    try emitter.emitEncoding(encoding.pxor(.xmm1, .{ .reg = .xmm4 }));
    try emitter.emitEncoding(encoding.pcmpgtd(.xmm0, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.psllqImm(.xmm0, 32));
    try emitter.emitEncoding(encoding.pand(.xmm0, .{ .reg = .xmm3 }));
    try emitter.emitEncoding(encoding.por(.xmm2, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.movupd(.xmm0, .{ .reg = .xmm2 }));
    try emitter.emitEncoding(encoding.psrlqImm(.xmm0, 63));
}

fn emitPackedQwordCmpBits(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, plan: IntCmpPlan) !void {
    switch (plan.relation) {
        .eq => try emitPackedQwordEqCmpBits(emitter, lhs, rhs),
        .gt => {
            const gt_lhs = if (plan.swap) rhs else lhs;
            const gt_rhs = if (plan.swap) lhs else rhs;
            try emitPackedQwordGtCmpBits(emitter, gt_lhs, gt_rhs, plan.unsigned);
        },
    }
}

fn emitPackedQwordBitsToMask(emitter: anytype) !void {
    try emitter.emitEncoding(encoding.pxor(.xmm1, .{ .reg = .xmm1 }));
    try emitter.emitEncoding(encoding.psubq(.xmm1, .{ .reg = .xmm0 }));
    try emitter.emitEncoding(encoding.movupd(.xmm0, .{ .reg = .xmm1 }));
}

fn emitPackedIntCmp(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot, pred: CmpPredicate, int_kind: PackedInt) !void {
    const plan = intCmpPlan(pred);
    switch (int_kind) {
        .dwordx4 => try emitPackedDwordCmpBits(emitter, lhs, rhs, plan),
        .qwordx2 => try emitPackedQwordCmpBits(emitter, lhs, rhs, plan),
    }
    if (plan.invert) try emitPackedIntCmpInvert(emitter, int_kind);
    try emitPackedStore(emitter, result, .xmm0);
}

fn emitPackedIntBlendMask(emitter: anytype, true_slot: slot_layout.VectorSlot, false_slot: slot_layout.VectorSlot, result: slot_layout.VectorSlot, int_kind: PackedInt) !void {
    try emitPackedLoad(emitter, true_slot, .xmm1);
    try emitPackedLoad(emitter, false_slot, .xmm2);
    switch (int_kind) {
        .dwordx4 => try emitter.emitEncoding(encoding.movups(.xmm3, .{ .reg = .xmm0 })),
        .qwordx2 => try emitter.emitEncoding(encoding.movupd(.xmm3, .{ .reg = .xmm0 })),
    }
    try emitter.emitEncoding(encoding.pand(.xmm1, .{ .reg = .xmm0 }));
    try emitPackedAllOnes(emitter, .xmm4);
    try emitter.emitEncoding(encoding.pxor(.xmm3, .{ .reg = .xmm4 }));
    try emitter.emitEncoding(encoding.pand(.xmm2, .{ .reg = .xmm3 }));
    try emitter.emitEncoding(encoding.por(.xmm1, .{ .reg = .xmm2 }));
    try emitPackedStore(emitter, result, .xmm1);
}

fn emitPackedIntMinMax(emitter: anytype, lhs: slot_layout.VectorSlot, rhs: slot_layout.VectorSlot, result: slot_layout.VectorSlot, kind: scalar_backend.MinMaxKind, int_kind: PackedInt) !void {
    const plan: IntCmpPlan = .{
        .relation = .gt,
        .unsigned = scalar_backend.isUnsignedIntegerTypeName(result.elem_type_name),
    };
    switch (int_kind) {
        .dwordx4 => try emitPackedDwordCmpMask(emitter, lhs, rhs, plan),
        .qwordx2 => {
            try emitPackedQwordCmpBits(emitter, lhs, rhs, plan);
            try emitPackedQwordBitsToMask(emitter);
        },
    }
    const true_slot = switch (kind) {
        .max => lhs,
        .min => rhs,
    };
    const false_slot = switch (kind) {
        .max => rhs,
        .min => lhs,
    };
    try emitPackedIntBlendMask(emitter, true_slot, false_slot, result, int_kind);
}

fn packedIntCmpSupported(pred: CmpPredicate, int_kind: PackedInt) bool {
    _ = pred;
    return switch (int_kind) {
        .dwordx4 => true,
        .qwordx2 => true,
    };
}

fn emitPackedFloatNeg(emitter: anytype, input: slot_layout.VectorSlot, result: slot_layout.VectorSlot, float_kind: PackedFloat) !void {
    try emitPackedLoad(emitter, input, .xmm0);
    try emitter.emitEncoding(encoding.pcmpeqd(.xmm1, .{ .reg = .xmm1 }));
    switch (float_kind) {
        .f32x4 => {
            try emitter.emitEncoding(encoding.pslldImm(.xmm1, 31));
            try emitter.emitEncoding(encoding.xorps(.xmm0, .{ .reg = .xmm1 }));
        },
        .f64x2 => {
            try emitter.emitEncoding(encoding.psllqImm(.xmm1, 63));
            try emitter.emitEncoding(encoding.xorpd(.xmm0, .{ .reg = .xmm1 }));
        },
    }
    try emitPackedStore(emitter, result, .xmm0);
}

fn emitPackedIntNeg(emitter: anytype, input: slot_layout.VectorSlot, result: slot_layout.VectorSlot, int_kind: PackedInt) !void {
    switch (int_kind) {
        .dwordx4 => {
            try emitter.emitEncoding(encoding.pxor(.xmm0, .{ .reg = .xmm0 }));
            try emitPackedLoad(emitter, input, .xmm1);
            try emitter.emitEncoding(encoding.psubd(.xmm0, .{ .reg = .xmm1 }));
        },
        .qwordx2 => {
            try emitter.emitEncoding(encoding.pxor(.xmm0, .{ .reg = .xmm0 }));
            try emitPackedLoad(emitter, input, .xmm1);
            try emitter.emitEncoding(encoding.psubq(.xmm0, .{ .reg = .xmm1 }));
        },
    }
    try emitPackedStore(emitter, result, .xmm0);
}

fn emitPackedIntNot(emitter: anytype, input: slot_layout.VectorSlot, result: slot_layout.VectorSlot) !void {
    try emitPackedLoad(emitter, input, .xmm0);
    try emitPackedAllOnes(emitter, .xmm1);
    try emitter.emitEncoding(encoding.pxor(.xmm0, .{ .reg = .xmm1 }));
    try emitPackedStore(emitter, result, .xmm0);
}

fn emitPackedFloatSplat(emitter: anytype, scalar: *ir.Value, result: *ir.Value, float_kind: PackedFloat) !void {
    try emitter.loadIntoXmm(scalar, .xmm0);
    try emitPackedFloatBroadcastStore(emitter, result, float_kind);
}

fn emitPackedFloatBroadcastStore(emitter: anytype, result: *ir.Value, float_kind: PackedFloat) !void {
    switch (float_kind) {
        .f32x4 => try emitter.emitEncoding(encoding.shufps(.xmm0, .{ .reg = .xmm0 }, 0)),
        .f64x2 => try emitter.emitEncoding(encoding.shufpd(.xmm0, .{ .reg = .xmm0 }, 0)),
    }
    try emitter.storeFromXmmPacked(result, .xmm0);
}

fn emitPackedFloatConstant(emitter: anytype, result: *ir.Value, value: f64, float_kind: PackedFloat) !void {
    switch (float_kind) {
        .f32x4 => {
            const bits: u32 = @bitCast(@as(f32, @floatCast(value)));
            try emitter.emitEncoding(encoding.movRegImm32(.rax, bits));
            try emitter.emitEncoding(encoding.movdXmmFromReg32(.xmm0, .rax));
        },
        .f64x2 => {
            const bits: u64 = @bitCast(value);
            try emitter.emitEncoding(encoding.movRegImm64(.rax, bits));
            try emitter.emitEncoding(encoding.movqXmmFromReg64(.xmm0, .rax));
        },
    }
    try emitPackedFloatBroadcastStore(emitter, result, float_kind);
}

fn emitPackedDwordBroadcastStore(emitter: anytype, result: *ir.Value) !void {
    try emitter.emitEncoding(encoding.pshufd(.xmm0, .{ .reg = .xmm0 }, 0));
    try emitter.storeFromXmmPacked(result, .xmm0);
}

fn emitPackedQwordBroadcastStore(emitter: anytype, result: *ir.Value) !void {
    try emitter.emitEncoding(encoding.shufpd(.xmm0, .{ .reg = .xmm0 }, 0));
    try emitter.storeFromXmmPacked(result, .xmm0);
}

fn emitPackedIntSplat(emitter: anytype, scalar: *ir.Value, result: *ir.Value, int_kind: PackedInt) !void {
    const scalar_home = emitter.registerHome(scalar);
    switch (int_kind) {
        .dwordx4 => {
            if (scalar_home) |home| {
                try emitter.emitEncoding(encoding.movRegReg32(.rax, home));
                try emitter.emitEncoding(encoding.movdXmmFromReg32(.xmm0, .rax));
            } else {
                const mem = encoding.Mem.baseDisp(.rbp, (try emitter.slotFor(scalar)).offset);
                try emitter.emitEncoding(encoding.movdXmmFromMem32(.xmm0, mem));
            }
            try emitPackedDwordBroadcastStore(emitter, result);
        },
        .qwordx2 => {
            if (scalar_home) |home| {
                try emitter.emitEncoding(encoding.movqXmmFromReg64(.xmm0, home));
            } else {
                const mem = encoding.Mem.baseDisp(.rbp, (try emitter.slotFor(scalar)).offset);
                try emitter.emitEncoding(encoding.movqXmmFromMem64(.xmm0, mem));
            }
            try emitPackedQwordBroadcastStore(emitter, result);
        },
    }
}

fn emitPackedIntConstant(emitter: anytype, result: *ir.Value, value: i64, int_kind: PackedInt) !void {
    switch (int_kind) {
        .dwordx4 => {
            const bits: u64 = @bitCast(value);
            const masked: u32 = @intCast(bits & 0xFFFF_FFFF);
            try emitter.emitEncoding(encoding.movRegImm32(.rax, masked));
            try emitter.emitEncoding(encoding.movdXmmFromReg32(.xmm0, .rax));
            try emitPackedDwordBroadcastStore(emitter, result);
        },
        .qwordx2 => {
            const bits: u64 = @bitCast(value);
            try emitter.emitEncoding(encoding.movRegImm64(.rax, bits));
            try emitter.emitEncoding(encoding.movqXmmFromReg64(.xmm0, .rax));
            try emitPackedQwordBroadcastStore(emitter, result);
        },
    }
}

fn packedSourceElement(index: i64, lanes: usize) !u8 {
    if (index < 0) return error.IndexOutOfBounds;
    const lane: usize = @intCast(index);
    if (lane >= lanes) return error.IndexOutOfBounds;
    return @intCast(lanes - 1 - lane);
}

fn packedShuffleImm(indices: []const i64, lanes: usize, selector_bits: usize) !u8 {
    if (indices.len != lanes) return error.VectorArityMismatch;
    var imm: u8 = 0;
    for (0..lanes) |physical_dest| {
        const logical_dest = lanes - 1 - physical_dest;
        const physical_source = try packedSourceElement(indices[logical_dest], lanes);
        const shift: u3 = @intCast(physical_dest * selector_bits);
        imm |= physical_source << shift;
    }
    return imm;
}

fn packedFloatShuffleImm(indices: []const i64, float_kind: PackedFloat) !u8 {
    const lanes: usize = switch (float_kind) {
        .f32x4 => 4,
        .f64x2 => 2,
    };
    const selector_bits: usize = switch (float_kind) {
        .f32x4 => 2,
        .f64x2 => 1,
    };
    return packedShuffleImm(indices, lanes, selector_bits);
}

fn emitPackedFloatShuffle(emitter: anytype, input: slot_layout.VectorSlot, result: slot_layout.VectorSlot, indices: []const i64, float_kind: PackedFloat) !void {
    const imm = try packedFloatShuffleImm(indices, float_kind);
    try emitPackedLoad(emitter, input, .xmm0);
    switch (float_kind) {
        .f32x4 => try emitter.emitEncoding(encoding.shufps(.xmm0, .{ .reg = .xmm0 }, imm)),
        .f64x2 => try emitter.emitEncoding(encoding.shufpd(.xmm0, .{ .reg = .xmm0 }, imm)),
    }
    try emitPackedStore(emitter, result, .xmm0);
}

fn emitPackedIntShuffle(emitter: anytype, input: slot_layout.VectorSlot, result: slot_layout.VectorSlot, indices: []const i64, int_kind: PackedInt) !void {
    switch (int_kind) {
        .dwordx4 => {
            const imm = try packedShuffleImm(indices, 4, 2);
            try emitPackedLoad(emitter, input, .xmm0);
            try emitter.emitEncoding(encoding.pshufd(.xmm0, .{ .reg = .xmm0 }, imm));
            try emitPackedStore(emitter, result, .xmm0);
        },
        .qwordx2 => {
            const imm = try packedShuffleImm(indices, 2, 1);
            try emitPackedLoad(emitter, input, .xmm0);
            try emitter.emitEncoding(encoding.shufpd(.xmm0, .{ .reg = .xmm0 }, imm));
            try emitPackedStore(emitter, result, .xmm0);
        },
    }
}

fn samePackedInsertShape(input: slot_layout.VectorSlot, result: slot_layout.VectorSlot) ?PackedKind {
    if (input.lanes != result.lanes or input.base.width != result.base.width) return null;
    if (input.is_float != result.is_float) return null;
    if (!std.mem.eql(u8, input.elem_type_name, result.elem_type_name)) return null;
    const input_kind = packedKind(input) orelse return null;
    const result_kind = packedKind(result) orelse return null;
    if (!std.meta.eql(input_kind, result_kind)) return null;
    return input_kind;
}

fn emitPackedExtractLowStore(emitter: anytype, result: slot_layout.Slot, is_float: bool) !void {
    const mem = encoding.Mem.baseDisp(.rbp, result.offset);
    if (is_float) {
        switch (result.width) {
            32 => try emitter.emitEncoding(encoding.movssStore(mem, .xmm0)),
            64 => try emitter.emitEncoding(encoding.movsdStore(mem, .xmm0)),
            else => return error.UnsupportedType,
        }
    } else {
        switch (result.width) {
            32 => try emitter.emitEncoding(encoding.movdMemFromXmm32(mem, .xmm0)),
            64 => try emitter.emitEncoding(encoding.movqMemFromXmm64(mem, .xmm0)),
            else => return error.UnsupportedType,
        }
    }
}

fn emitPackedExtract(emitter: anytype, vector: slot_layout.VectorSlot, result: slot_layout.Slot, index: i64, kind: PackedKind) !void {
    if (result.width != vector.base.width) return error.UnsupportedType;
    const source = try packedSourceElement(index, vector.lanes);

    try emitPackedLoad(emitter, vector, .xmm0);
    switch (kind) {
        .float => |float_kind| switch (float_kind) {
            .f32x4 => try emitter.emitEncoding(encoding.shufps(.xmm0, .{ .reg = .xmm0 }, source)),
            .f64x2 => try emitter.emitEncoding(encoding.shufpd(.xmm0, .{ .reg = .xmm0 }, source)),
        },
        .int => |int_kind| switch (int_kind) {
            .dwordx4 => try emitter.emitEncoding(encoding.pshufd(.xmm0, .{ .reg = .xmm0 }, source)),
            .qwordx2 => try emitter.emitEncoding(encoding.shufpd(.xmm0, .{ .reg = .xmm0 }, source)),
        },
    }
    try emitPackedExtractLowStore(emitter, result, vector.is_float);
}

fn emitPackedInsert(emitter: anytype, vector: slot_layout.VectorSlot, scalar: slot_layout.Slot, result: slot_layout.VectorSlot, index: usize, kind: PackedKind) !void {
    if (scalar.width != vector.base.width) return error.UnsupportedType;
    try emitPackedLoad(emitter, vector, .xmm0);
    try emitPackedStoreToMem(emitter, kind, packedMem(result), .xmm0);

    const dst_lane = slot_layout.laneSlot(result.base, index);
    try emitter.loadSlot(scalar, .rax);
    try emitter.storeSlot(dst_lane, .rax);
}

pub fn emitConstant(emitter: anytype, op: *ir.Operation) !void {
    const vec_op = ArithDialect.VecConstantOp{ .op = op };
    const result = vec_op.getResult();
    const vector = try emitter.vectorSlotFor(result);

    const int_val = vec_op.getIntValue();
    const float_val = vec_op.getFloatValue();
    if (int_val == null and float_val == null) return error.InvalidConstant;

    if (int_val) |ival| {
        if (packedIntKind(vector)) |int_kind| {
            try emitPackedIntConstant(emitter, result, ival, int_kind);
            return;
        }
    }

    if (float_val) |fval| {
        if (packedFloatKind(vector)) |float_kind| {
            try emitPackedFloatConstant(emitter, result, fval, float_kind);
            return;
        }
    }

    for (0..vector.lanes) |lane| {
        const lane_slot = slot_layout.laneSlot(vector.base, lane);
        if (int_val) |ival| {
            const bits: u64 = @bitCast(ival);
            const masked: u64 = switch (lane_slot.width) {
                8 => bits & 0xFF,
                16 => bits & 0xFFFF,
                32 => bits & 0xFFFF_FFFF,
                64 => bits,
                else => return error.UnsupportedType,
            };
            if (lane_slot.width <= 32) {
                try emitter.emitEncoding(encoding.movRegImm32(.rax, @intCast(masked)));
            } else {
                try emitter.emitEncoding(encoding.movRegImm64(.rax, masked));
            }
            try emitter.storeSlot(lane_slot, .rax);
        } else if (float_val) |fval| {
            if (lane_slot.width == 32) {
                const bits: u32 = @bitCast(@as(f32, @floatCast(fval)));
                try emitter.emitEncoding(encoding.movRegImm32(.rax, bits));
                try emitter.storeSlot(lane_slot, .rax);
            } else if (lane_slot.width == 64) {
                const bits: u64 = @bitCast(fval);
                try emitter.emitEncoding(encoding.movRegImm64(.rax, bits));
                try emitter.storeSlot(lane_slot, .rax);
            } else {
                return error.UnsupportedType;
            }
        }
    }
}

pub fn emitSplat(emitter: anytype, op: *ir.Operation) !void {
    const splat_op = ArithDialect.SplatOp{ .op = op };
    const result = splat_op.getResult();
    const scalar = splat_op.getInput();
    const scalar_slot = try emitter.slotFor(scalar);
    const vector = try emitter.vectorSlotFor(result);

    if (packedFloatKind(vector)) |float_kind| {
        if (scalar_slot.width == vector.base.width) {
            try emitPackedFloatSplat(emitter, scalar, result, float_kind);
            return;
        }
    }

    if (packedIntKind(vector)) |int_kind| {
        if (scalar_slot.width == vector.base.width) {
            try emitPackedIntSplat(emitter, scalar, result, int_kind);
            return;
        }
    }

    if (scalar_slot.width != vector.base.width) {
        return error.UnsupportedType;
    }

    if (vector.base.width <= 32 and !vector.is_float) {
        try emitter.loadSlot(scalar_slot, .rax);
        for (0..vector.lanes) |lane| {
            const lane_slot = slot_layout.laneSlot(vector.base, lane);
            try emitter.storeSlot(lane_slot, .rax);
        }
        return;
    }

    try emitter.loadSlot(scalar_slot, .rax);
    for (0..vector.lanes) |lane| {
        const lane_slot = slot_layout.laneSlot(vector.base, lane);
        try emitter.storeSlot(lane_slot, .rax);
    }
}

pub fn emitExtract(emitter: anytype, op: *ir.Operation) !void {
    const extract_op = ArithDialect.ExtractOp{ .op = op };
    const result = extract_op.getResult();
    const vector = extract_op.getVector();
    const index = extract_op.getIndex() orelse return error.MissingIndex;

    if (index < 0) return error.IndexOutOfBounds;
    const vector_slot = try emitter.vectorSlotFor(vector);
    const lane_index: usize = @intCast(index);
    if (lane_index >= vector_slot.lanes) return error.IndexOutOfBounds;

    const lane_slot = slot_layout.laneSlot(vector_slot.base, lane_index);
    const result_slot = try emitter.slotFor(result);
    if (packedKind(vector_slot)) |kind| {
        try emitPackedExtract(emitter, vector_slot, result_slot, index, kind);
        return;
    }
    try emitter.loadSlot(lane_slot, .rax);
    try emitter.storeSlot(result_slot, .rax);
}

pub fn emitInsert(emitter: anytype, op: *ir.Operation) !void {
    const insert_op = ArithDialect.InsertOp{ .op = op };
    const result = insert_op.getResult();
    const vector = insert_op.getVector();
    const scalar = insert_op.getScalar();
    const index = insert_op.getIndex() orelse return error.MissingIndex;

    if (index < 0) return error.IndexOutOfBounds;
    const vector_slot = try emitter.vectorSlotFor(vector);
    const lane_index: usize = @intCast(index);
    if (lane_index >= vector_slot.lanes) return error.IndexOutOfBounds;

    const result_slot = try emitter.vectorSlotFor(result);
    const scalar_slot = try emitter.slotFor(scalar);

    if (samePackedInsertShape(vector_slot, result_slot)) |kind| {
        try emitPackedInsert(emitter, vector_slot, scalar_slot, result_slot, lane_index, kind);
        return;
    }

    for (0..vector_slot.lanes) |lane| {
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);
        if (lane == lane_index) {
            try emitter.loadSlot(scalar_slot, .rax);
            try emitter.storeSlot(dst_lane, .rax);
        } else {
            const src_lane = slot_layout.laneSlot(vector_slot.base, lane);
            try emitter.loadSlot(src_lane, .rax);
            try emitter.storeSlot(dst_lane, .rax);
        }
    }
}

pub fn emitShuffle(emitter: anytype, op: *ir.Operation) !void {
    const shuffle_op = ArithDialect.VecShuffleOp{ .op = op };
    const result = shuffle_op.getResult();
    const vector = shuffle_op.getVector();

    const result_slot = try emitter.vectorSlotFor(result);
    const vector_slot = try emitter.vectorSlotFor(vector);
    if (!std.mem.eql(u8, result_slot.elem_type_name, vector_slot.elem_type_name)) return error.UnsupportedType;

    var buf: [16]i64 = undefined;
    const indices = shuffle_op.getIndices(&buf) catch |err| switch (err) {
        error.MissingIndices => return error.MissingIndex,
        error.InvalidIndices => return error.UnsupportedOperation,
        error.TooManyIndices => return error.VectorArityMismatch,
    };

    if (indices.len != result_slot.lanes) return error.VectorArityMismatch;

    if (packedFloatKind(vector_slot)) |float_kind| {
        if (packedFloatKind(result_slot)) |result_kind| {
            if (result_kind == float_kind) {
                try emitPackedFloatShuffle(emitter, vector_slot, result_slot, indices, float_kind);
                return;
            }
        }
    }

    if (packedIntKind(vector_slot)) |int_kind| {
        if (packedIntKind(result_slot)) |result_kind| {
            if (result_kind == int_kind) {
                try emitPackedIntShuffle(emitter, vector_slot, result_slot, indices, int_kind);
                return;
            }
        }
    }

    if (vector_slot.base.width != result_slot.base.width) {
        return error.UnsupportedType;
    }

    if (vector_slot.is_float != result_slot.is_float) {
        return error.UnsupportedType;
    }

    if (result_slot.lanes != vector_slot.lanes and indices.len != result_slot.lanes) {
        return error.VectorArityMismatch;
    }

    if (indices.len != result_slot.lanes) {
        return error.VectorArityMismatch;
    }

    if (!std.mem.eql(u8, result_slot.elem_type_name, vector_slot.elem_type_name)) {
        return error.UnsupportedType;
    }

    if (indices.len == 0) {
        return;
    }

    for (indices, 0..) |idx, lane| {
        if (idx < 0) return error.IndexOutOfBounds;
        const src_index: usize = @intCast(idx);
        if (src_index >= vector_slot.lanes) return error.IndexOutOfBounds;

        const src_lane = slot_layout.laneSlot(vector_slot.base, src_index);
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);

        if (vector_slot.is_float) {
            try emitter.loadSlotXmm(src_lane, .xmm0);
            try emitter.storeSlotXmm(dst_lane, .xmm0);
        } else {
            try emitter.loadSlot(src_lane, .rax);
            try emitter.storeSlot(dst_lane, .rax);
        }
    }
}

pub fn emitBinaryOp(emitter: anytype, op: *ir.Operation, kind: BinOp) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const lhs_slot = try emitter.vectorSlotFor(lhs);
    const rhs_slot = try emitter.vectorSlotFor(rhs);
    const result_slot = try emitter.vectorSlotFor(result);

    if (lhs_slot.lanes != rhs_slot.lanes or lhs_slot.lanes != result_slot.lanes) return error.VectorArityMismatch;
    if (lhs_slot.is_float != rhs_slot.is_float) return error.UnsupportedType;
    if (lhs_slot.is_float != rhs_slot.is_float or lhs_slot.is_float != result_slot.is_float) return error.UnsupportedType;

    if (samePackedFloatKind(lhs_slot, rhs_slot, result_slot)) |float_kind| {
        try emitPackedFloatBinary(emitter, lhs, rhs, result, kind, float_kind);
        return;
    }

    if (samePackedIntKind(lhs_slot, rhs_slot, result_slot)) |int_kind| {
        switch (kind) {
            .add, .sub, .mul => {
                try emitPackedIntBinary(emitter, lhs, rhs, result, kind, int_kind);
                return;
            },
            .div => {},
        }
    }

    for (0..lhs_slot.lanes) |lane| {
        const lhs_lane = slot_layout.laneSlot(lhs_slot.base, lane);
        const rhs_lane = slot_layout.laneSlot(rhs_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);

        if (lhs_slot.is_float) {
            try emitter.loadSlotXmm(lhs_lane, .xmm0);
            try emitter.loadSlotXmm(rhs_lane, .xmm1);
            if (lhs_lane.width == 32) {
                switch (kind) {
                    .add => try emitter.emitEncoding(encoding.addss(.xmm0, .{ .reg = .xmm1 })),
                    .sub => try emitter.emitEncoding(encoding.subss(.xmm0, .{ .reg = .xmm1 })),
                    .mul => try emitter.emitEncoding(encoding.mulss(.xmm0, .{ .reg = .xmm1 })),
                    .div => try emitter.emitEncoding(encoding.divss(.xmm0, .{ .reg = .xmm1 })),
                }
            } else if (lhs_lane.width == 64) {
                switch (kind) {
                    .add => try emitter.emitEncoding(encoding.addsd(.xmm0, .{ .reg = .xmm1 })),
                    .sub => try emitter.emitEncoding(encoding.subsd(.xmm0, .{ .reg = .xmm1 })),
                    .mul => try emitter.emitEncoding(encoding.mulsd(.xmm0, .{ .reg = .xmm1 })),
                    .div => try emitter.emitEncoding(encoding.divsd(.xmm0, .{ .reg = .xmm1 })),
                }
            } else {
                return error.UnsupportedType;
            }
            try emitter.storeSlotXmm(dst_lane, .xmm0);
        } else {
            const width = lhs_lane.width;
            if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
            const op_width: u8 = if (width <= 32) 32 else 64;

            const is_unsigned = scalar_backend.isUnsignedIntegerTypeName(result_slot.elem_type_name);
            if (kind == .div and is_unsigned) {
                try emitter.loadSlotUnsigned(lhs_lane, .rax);
                try emitter.loadSlotUnsigned(rhs_lane, .rcx);
            } else {
                try emitter.loadSlot(lhs_lane, .rax);
                try emitter.loadSlot(rhs_lane, .rcx);
            }
            const narrow_signed = !is_unsigned and width < 32;
            if (kind == .div and narrow_signed and !uniformDivisorNotNegativeOne(rhs, width)) {
                try scalar_backend.emitNarrowQuotientGuard(emitter, width);
            }

            switch (kind) {
                .add => {
                    if (op_width == 32) {
                        try emitter.emitEncoding(encoding.addRegReg32(.rax, .rcx));
                    } else {
                        try emitter.emitEncoding(encoding.addRegReg(.rax, .rcx));
                    }
                    try emitter.storeSlot(dst_lane, .rax);
                },
                .sub => {
                    if (op_width == 32) {
                        try emitter.emitEncoding(encoding.subRegReg32(.rax, .rcx));
                    } else {
                        try emitter.emitEncoding(encoding.subRegReg(.rax, .rcx));
                    }
                    try emitter.storeSlot(dst_lane, .rax);
                },
                .mul => {
                    if (op_width == 32) {
                        try emitter.emitEncoding(encoding.imulRegReg32(.rax, .rcx));
                    } else {
                        try emitter.emitEncoding(encoding.imulRegReg(.rax, .rcx));
                    }
                    try emitter.storeSlot(dst_lane, .rax);
                },
                .div => {
                    try scalar_backend.emitIntegerDiv(emitter, op_width, is_unsigned);
                    try emitter.storeSlot(dst_lane, .rax);
                },
            }
        }
    }
}

pub fn emitBitwiseBinary(emitter: anytype, op: *ir.Operation, kind: BitwiseBinaryOp) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const lhs_slot = try emitter.vectorSlotFor(lhs);
    const rhs_slot = try emitter.vectorSlotFor(rhs);
    const result_slot = try emitter.vectorSlotFor(result);

    if (lhs_slot.lanes != rhs_slot.lanes or lhs_slot.lanes != result_slot.lanes) return error.VectorArityMismatch;
    if (lhs_slot.is_float or rhs_slot.is_float or result_slot.is_float) return error.UnsupportedType;
    if (!std.mem.eql(u8, lhs_slot.elem_type_name, rhs_slot.elem_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, lhs_slot.elem_type_name, result_slot.elem_type_name)) return error.UnsupportedType;
    if (lhs_slot.base.width != rhs_slot.base.width or lhs_slot.base.width != result_slot.base.width) return error.UnsupportedType;

    if (samePackedIntKind(lhs_slot, rhs_slot, result_slot)) |_| {
        try emitPackedIntBitwiseBinary(emitter, lhs, rhs, result, kind);
        return;
    }

    for (0..lhs_slot.lanes) |lane| {
        const lhs_lane = slot_layout.laneSlot(lhs_slot.base, lane);
        const rhs_lane = slot_layout.laneSlot(rhs_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);

        const width = lhs_lane.width;
        if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
        const op_width: u8 = if (width <= 32) 32 else 64;

        try emitter.loadSlot(lhs_lane, .rax);
        try emitter.loadSlot(rhs_lane, .rcx);
        if (op_width == 32) {
            switch (kind) {
                .band => try emitter.emitEncoding(encoding.andRegReg32(.rax, .rcx)),
                .bor => try emitter.emitEncoding(encoding.orRegReg32(.rax, .rcx)),
                .bxor => try emitter.emitEncoding(encoding.xorRegReg32(.rax, .rcx)),
            }
        } else {
            switch (kind) {
                .band => try emitter.emitEncoding(encoding.andRegReg(.rax, .rcx)),
                .bor => try emitter.emitEncoding(encoding.orRegReg(.rax, .rcx)),
                .bxor => try emitter.emitEncoding(encoding.xorRegReg(.rax, .rcx)),
            }
        }
        try emitter.storeSlot(dst_lane, .rax);
    }
}

pub fn emitUmulhi(emitter: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const lhs_slot = try emitter.vectorSlotFor(lhs);
    const rhs_slot = try emitter.vectorSlotFor(rhs);
    const result_slot = try emitter.vectorSlotFor(result);

    if (lhs_slot.lanes != rhs_slot.lanes or lhs_slot.lanes != result_slot.lanes) return error.VectorArityMismatch;
    if (lhs_slot.is_float or rhs_slot.is_float or result_slot.is_float) return error.UnsupportedType;
    if (!std.mem.eql(u8, lhs_slot.elem_type_name, rhs_slot.elem_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, lhs_slot.elem_type_name, result_slot.elem_type_name)) return error.UnsupportedType;
    if (lhs_slot.base.width != rhs_slot.base.width or lhs_slot.base.width != result_slot.base.width) return error.UnsupportedType;
    if (!scalar_backend.isIntegerScalarTypeName(result_slot.elem_type_name)) return error.UnsupportedType;

    const width = result_slot.base.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    if (samePackedIntKind(lhs_slot, rhs_slot, result_slot)) |int_kind| {
        if (try emitPackedIntUmulhi(emitter, lhs_slot, rhs_slot, result_slot, int_kind)) return;
    }

    for (0..lhs_slot.lanes) |lane| {
        const lhs_lane = slot_layout.laneSlot(lhs_slot.base, lane);
        const rhs_lane = slot_layout.laneSlot(rhs_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);

        try emitter.loadSlotUnsigned(lhs_lane, .rax);
        try emitter.loadSlotUnsigned(rhs_lane, .rcx);
        try scalar_backend.emitUnsignedHighProductFromRaxRcx(emitter, width);
        try emitter.storeSlot(dst_lane, .rax);
    }
}

pub fn emitPopCount(emitter: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const input = op.getOperand(0) orelse return error.MissingOperand;

    const in_slot = try emitter.vectorSlotFor(input);
    const out_slot = try emitter.vectorSlotFor(result);

    if (in_slot.lanes != out_slot.lanes) return error.VectorArityMismatch;
    if (in_slot.is_float or out_slot.is_float) return error.UnsupportedType;
    if (!std.mem.eql(u8, in_slot.elem_type_name, out_slot.elem_type_name)) return error.UnsupportedType;
    if (in_slot.base.width != out_slot.base.width) return error.UnsupportedType;
    if (std.mem.eql(u8, out_slot.elem_type_name, dialects.arith.type_names.boolean)) return error.UnsupportedType;
    if (!scalar_backend.isIntegerScalarTypeName(out_slot.elem_type_name) and
        !std.mem.eql(u8, out_slot.elem_type_name, dialects.arith.type_names.index)) return error.UnsupportedType;

    const width = out_slot.base.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    if (packedIntKind(in_slot)) |in_kind| {
        if (packedIntKind(out_slot)) |out_kind| {
            if (in_kind == out_kind) {
                try emitPackedIntPopCount(emitter, in_slot, out_slot, in_kind);
                return;
            }
        }
    }

    for (0..in_slot.lanes) |lane| {
        const src_lane = slot_layout.laneSlot(in_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(out_slot.base, lane);

        try emitter.loadSlotUnsigned(src_lane, .rax);
        try scalar_backend.emitPopCountFromRax(emitter, width);
        try emitter.storeSlot(dst_lane, .rax);
    }
}

pub fn emitShift(emitter: anytype, op: *ir.Operation, kind: scalar_backend.ShiftKind) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const value = op.getOperand(0) orelse return error.MissingOperand;
    const count = op.getOperand(1) orelse return error.MissingOperand;

    const value_slot = try emitter.vectorSlotFor(value);
    const count_slot = try emitter.vectorSlotFor(count);
    const result_slot = try emitter.vectorSlotFor(result);

    if (value_slot.lanes != count_slot.lanes or value_slot.lanes != result_slot.lanes) return error.VectorArityMismatch;
    if (value_slot.is_float or count_slot.is_float or result_slot.is_float) return error.UnsupportedType;
    if (!std.mem.eql(u8, value_slot.elem_type_name, count_slot.elem_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, value_slot.elem_type_name, result_slot.elem_type_name)) return error.UnsupportedType;
    if (value_slot.base.width != count_slot.base.width or value_slot.base.width != result_slot.base.width) return error.UnsupportedType;

    const elem_type_name = result_slot.elem_type_name;
    if (std.mem.eql(u8, elem_type_name, dialects.arith.type_names.float16) or
        std.mem.eql(u8, elem_type_name, dialects.arith.type_names.bfloat16) or
        std.mem.eql(u8, elem_type_name, dialects.arith.type_names.boolean)) return error.UnsupportedType;
    if (scalar_backend.isUnsignedIntegerTypeName(elem_type_name) and kind == .shr) return error.UnsupportedType;

    const width = result_slot.base.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    if (samePackedIntKind(value_slot, count_slot, result_slot)) |int_kind| {
        if (uniformShiftCount(count, width)) |shift_count| {
            if (try emitPackedIntShiftUniform(emitter, value_slot, result_slot, kind, int_kind, shift_count)) return;
        }
    }

    const op_width: u8 = if (width <= 32) 32 else 64;
    for (0..value_slot.lanes) |lane| {
        const value_lane = slot_layout.laneSlot(value_slot.base, lane);
        const count_lane = slot_layout.laneSlot(count_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);

        if (kind == .ushr) {
            try emitter.loadSlotUnsigned(value_lane, .rax);
        } else {
            try emitter.loadSlot(value_lane, .rax);
        }
        try emitter.loadSlot(count_lane, .rcx);
        if (!laneShiftCountInBounds(count, width)) try scalar_backend.emitShiftCountGuard(emitter, width);

        if (op_width == 32) {
            switch (kind) {
                .shl => try emitter.emitEncoding(encoding.shlRegCl32(.rax)),
                .shr => try emitter.emitEncoding(encoding.sarRegCl32(.rax)),
                .ushr => try emitter.emitEncoding(encoding.shrRegCl32(.rax)),
            }
        } else {
            switch (kind) {
                .shl => try emitter.emitEncoding(encoding.shlRegCl(.rax)),
                .shr => try emitter.emitEncoding(encoding.sarRegCl(.rax)),
                .ushr => try emitter.emitEncoding(encoding.shrRegCl(.rax)),
            }
        }
        try emitter.storeSlot(dst_lane, .rax);
    }
}

pub fn emitMinMax(emitter: anytype, op: *ir.Operation, kind: scalar_backend.MinMaxKind) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const lhs_slot = try emitter.vectorSlotFor(lhs);
    const rhs_slot = try emitter.vectorSlotFor(rhs);
    const result_slot = try emitter.vectorSlotFor(result);

    if (lhs_slot.lanes != rhs_slot.lanes or lhs_slot.lanes != result_slot.lanes) return error.VectorArityMismatch;
    if (lhs_slot.is_float != rhs_slot.is_float or lhs_slot.is_float != result_slot.is_float) return error.UnsupportedType;
    if (!std.mem.eql(u8, lhs_slot.elem_type_name, rhs_slot.elem_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, lhs_slot.elem_type_name, result_slot.elem_type_name)) return error.UnsupportedType;

    const elem_type_name = result_slot.elem_type_name;
    if (std.mem.eql(u8, elem_type_name, dialects.arith.type_names.float16) or
        std.mem.eql(u8, elem_type_name, dialects.arith.type_names.bfloat16) or
        std.mem.eql(u8, elem_type_name, dialects.arith.type_names.boolean)) return error.UnsupportedType;

    if (!result_slot.is_float) {
        if (samePackedIntKind(lhs_slot, rhs_slot, result_slot)) |int_kind| {
            try emitPackedIntMinMax(emitter, lhs_slot, rhs_slot, result_slot, kind, int_kind);
            return;
        }
    }

    for (0..lhs_slot.lanes) |lane| {
        const lhs_lane = slot_layout.laneSlot(lhs_slot.base, lane);
        const rhs_lane = slot_layout.laneSlot(rhs_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);

        if (result_slot.is_float) {
            try emitter.loadSlotXmm(lhs_lane, .xmm0);
            try emitter.loadSlotXmm(rhs_lane, .xmm1);
            if (lhs_lane.width == 32) {
                try scalar_backend.emitFloatMinMax(emitter, true, kind);
            } else if (lhs_lane.width == 64) {
                try scalar_backend.emitFloatMinMax(emitter, false, kind);
            } else {
                return error.UnsupportedType;
            }
            try emitter.storeSlotXmm(dst_lane, .xmm0);
        } else {
            const width = lhs_lane.width;
            if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
            const op_width: u8 = if (width <= 32) 32 else 64;
            const is_unsigned = scalar_backend.isUnsignedIntegerTypeName(elem_type_name);
            if (is_unsigned) {
                try emitter.loadSlotUnsigned(lhs_lane, .rax);
                try emitter.loadSlotUnsigned(rhs_lane, .rcx);
            } else {
                try emitter.loadSlot(lhs_lane, .rax);
                try emitter.loadSlot(rhs_lane, .rcx);
            }
            try scalar_backend.emitIntegerMinMax(emitter, op_width, is_unsigned, kind);
            try emitter.storeSlot(dst_lane, .rax);
        }
    }
}

pub fn emitSelect(emitter: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 3) return error.UnsupportedOperation;
    const cond = op.getOperand(0) orelse return error.MissingOperand;
    const true_val = op.getOperand(1) orelse return error.MissingOperand;
    const false_val = op.getOperand(2) orelse return error.MissingOperand;
    const result = op.getResult(0) orelse return error.MissingResult;

    const cond_name = cond.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, cond_name, dialects.arith.type_names.boolean)) return error.UnsupportedType;
    if (!result.type.eql(true_val.type)) return error.UnsupportedType;
    if (!result.type.eql(false_val.type)) return error.UnsupportedType;

    const cond_slot = try emitter.slotFor(cond);
    const true_slot = try emitter.vectorSlotFor(true_val);
    const false_slot = try emitter.vectorSlotFor(false_val);
    const result_slot = try emitter.vectorSlotFor(result);
    if (!sameVectorStorageShape(true_slot, false_slot)) return error.UnsupportedType;
    if (!sameVectorStorageShape(true_slot, result_slot)) return error.UnsupportedType;

    try emitCopyVectorSlot(emitter, true_slot, result_slot);
    try emitter.loadSlotUnsigned(cond_slot, .rax);
    try emitter.emitEncoding(encoding.cmpRegImm(.rax, 0));

    var done_label = labels.Label{};
    defer done_label.deinit(emitter.allocator);
    try emitter.emitJccLabel(.ne, &done_label);
    try emitCopyVectorSlot(emitter, false_slot, result_slot);
    try emitter.bindLabel(&done_label);
}

pub fn emitNeg(emitter: anytype, op: *ir.Operation) !void {
    const vec_op = ArithDialect.NegOp{ .op = op };
    const result = vec_op.getResult();
    const input = vec_op.getInput();

    const in_slot = try emitter.vectorSlotFor(input);
    const out_slot = try emitter.vectorSlotFor(result);
    if (in_slot.lanes != out_slot.lanes) return error.VectorArityMismatch;
    if (in_slot.is_float != out_slot.is_float) return error.UnsupportedType;

    if (packedFloatKind(in_slot)) |in_kind| {
        if (packedFloatKind(out_slot)) |out_kind| {
            if (in_kind == out_kind) {
                try emitPackedFloatNeg(emitter, in_slot, out_slot, in_kind);
                return;
            }
        }
    }

    if (packedIntKind(in_slot)) |in_kind| {
        if (packedIntKind(out_slot)) |out_kind| {
            if (in_kind == out_kind and std.mem.eql(u8, in_slot.elem_type_name, out_slot.elem_type_name)) {
                try emitPackedIntNeg(emitter, in_slot, out_slot, in_kind);
                return;
            }
        }
    }

    // Negation flips the sign bit, as the scalar and packed paths do. Subtracting from zero
    // would answer +0 for +0 and quiet a NaN.
    if (in_slot.is_float) {
        const width = in_slot.base.width;
        if (width != 32 and width != 64) return error.UnsupportedType;
        try emitter.emitEncoding(encoding.pcmpeqd(.xmm1, .{ .reg = .xmm1 }));
        if (width == 32) {
            try emitter.emitEncoding(encoding.pslldImm(.xmm1, 31));
        } else {
            try emitter.emitEncoding(encoding.psllqImm(.xmm1, 63));
        }
    }

    for (0..in_slot.lanes) |lane| {
        const src_lane = slot_layout.laneSlot(in_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(out_slot.base, lane);

        if (in_slot.is_float) {
            try emitter.loadSlotXmm(src_lane, .xmm0);
            if (src_lane.width == 32) {
                try emitter.emitEncoding(encoding.xorps(.xmm0, .{ .reg = .xmm1 }));
            } else {
                try emitter.emitEncoding(encoding.xorpd(.xmm0, .{ .reg = .xmm1 }));
            }
            try emitter.storeSlotXmm(dst_lane, .xmm0);
        } else {
            const width = src_lane.width;
            const op_width: u8 = if (width <= 32) 32 else 64;
            try emitter.emitEncoding(encoding.movRegImm64(.rax, 0));
            try emitter.loadSlot(src_lane, .rcx);
            if (op_width == 32) {
                try emitter.emitEncoding(encoding.subRegReg32(.rax, .rcx));
            } else {
                try emitter.emitEncoding(encoding.subRegReg(.rax, .rcx));
            }
            try emitter.storeSlot(dst_lane, .rax);
        }
    }
}

pub fn emitNot(emitter: anytype, op: *ir.Operation) !void {
    const vec_op = ArithDialect.NotOp{ .op = op };
    const result = vec_op.getResult();
    const input = vec_op.getInput();

    const in_slot = try emitter.vectorSlotFor(input);
    const out_slot = try emitter.vectorSlotFor(result);
    if (in_slot.lanes != out_slot.lanes) return error.VectorArityMismatch;
    if (in_slot.is_float or out_slot.is_float) return error.UnsupportedType;
    if (!std.mem.eql(u8, in_slot.elem_type_name, out_slot.elem_type_name)) return error.UnsupportedType;
    if (in_slot.base.width != out_slot.base.width) return error.UnsupportedType;
    if (std.mem.eql(u8, out_slot.elem_type_name, dialects.arith.type_names.boolean)) return error.UnsupportedType;

    if (packedIntKind(in_slot)) |in_kind| {
        if (packedIntKind(out_slot)) |out_kind| {
            if (in_kind == out_kind) {
                try emitPackedIntNot(emitter, in_slot, out_slot);
                return;
            }
        }
    }

    for (0..in_slot.lanes) |lane| {
        const src_lane = slot_layout.laneSlot(in_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(out_slot.base, lane);

        const width = src_lane.width;
        if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
        const op_width: u8 = if (width <= 32) 32 else 64;

        try emitter.loadSlot(src_lane, .rax);
        if (op_width == 32) {
            try emitter.emitEncoding(encoding.notReg32(.rax));
        } else {
            try emitter.emitEncoding(encoding.notReg(.rax));
        }
        try emitter.storeSlot(dst_lane, .rax);
    }
}

pub fn emitCmp(emitter: anytype, op: *ir.Operation) !void {
    const vec_cmp = ArithDialect.VecCmpOp{ .op = op };
    const result = vec_cmp.getResult();
    const pred = vec_cmp.getPredicate() orelse return error.MissingPredicate;

    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const lhs_slot = try emitter.vectorSlotFor(lhs);
    const rhs_slot = try emitter.vectorSlotFor(rhs);
    const result_slot = try emitter.vectorSlotFor(result);

    if (lhs_slot.lanes != rhs_slot.lanes or lhs_slot.lanes != result_slot.lanes) return error.VectorArityMismatch;

    if (samePackedFloatCmpKind(lhs_slot, rhs_slot, result_slot)) |float_kind| {
        try emitPackedFloatCmp(emitter, lhs_slot, rhs_slot, result_slot, pred, float_kind);
        return;
    }

    if (samePackedIntCmpKind(lhs_slot, rhs_slot, result_slot)) |int_kind| {
        if (packedIntCmpSupported(pred, int_kind)) {
            try emitPackedIntCmp(emitter, lhs_slot, rhs_slot, result_slot, pred, int_kind);
            return;
        }
    }

    for (0..lhs_slot.lanes) |lane| {
        const lhs_lane = slot_layout.laneSlot(lhs_slot.base, lane);
        const rhs_lane = slot_layout.laneSlot(rhs_slot.base, lane);
        const dst_lane = slot_layout.laneSlot(result_slot.base, lane);

        if (lhs_slot.is_float) {
            try emitter.loadSlotXmm(lhs_lane, .xmm0);
            try emitter.loadSlotXmm(rhs_lane, .xmm1);
            if (lhs_lane.width == 32) {
                try emitter.emitEncoding(encoding.ucomiss(.xmm0, .{ .reg = .xmm1 }));
            } else if (lhs_lane.width == 64) {
                try emitter.emitEncoding(encoding.ucomisd(.xmm0, .{ .reg = .xmm1 }));
            } else {
                return error.UnsupportedType;
            }

            switch (pred) {
                .eq => {
                    try emitter.emitEncoding(encoding.setcc(.rax, .e));
                    try emitter.emitEncoding(encoding.setcc(.rcx, .np));
                    try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
                    try emitter.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                    try emitter.emitEncoding(encoding.andRegReg(.rax, .rcx));
                },
                .ne => {
                    try emitter.emitEncoding(encoding.setcc(.rax, .ne));
                    try emitter.emitEncoding(encoding.setcc(.rcx, .p));
                    try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
                    try emitter.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                    try emitter.emitEncoding(encoding.orRegReg(.rax, .rcx));
                },
                .lt, .slt, .ult => {
                    try emitter.emitEncoding(encoding.setcc(.rax, .b));
                    try emitter.emitEncoding(encoding.setcc(.rcx, .np));
                    try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
                    try emitter.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                    try emitter.emitEncoding(encoding.andRegReg(.rax, .rcx));
                },
                .le, .sle, .ule => {
                    try emitter.emitEncoding(encoding.setcc(.rax, .be));
                    try emitter.emitEncoding(encoding.setcc(.rcx, .np));
                    try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
                    try emitter.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                    try emitter.emitEncoding(encoding.andRegReg(.rax, .rcx));
                },
                .gt, .sgt, .ugt => {
                    try emitter.emitEncoding(encoding.setcc(.rax, .a));
                    try emitter.emitEncoding(encoding.setcc(.rcx, .np));
                    try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
                    try emitter.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                    try emitter.emitEncoding(encoding.andRegReg(.rax, .rcx));
                },
                .ge, .sge, .uge => {
                    try emitter.emitEncoding(encoding.setcc(.rax, .ae));
                    try emitter.emitEncoding(encoding.setcc(.rcx, .np));
                    try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
                    try emitter.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                    try emitter.emitEncoding(encoding.andRegReg(.rax, .rcx));
                },
            }
            try emitter.storeSlot(dst_lane, .rax);
        } else {
            const width = lhs_lane.width;
            if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

            // The predicate decides how both lanes are read, as in the scalar comparison.
            switch (pred) {
                .ult, .ule, .ugt, .uge => {
                    try emitter.loadSlotUnsigned(lhs_lane, .rax);
                    try emitter.loadSlotUnsigned(rhs_lane, .rcx);
                },
                .lt, .le, .gt, .ge, .slt, .sle, .sgt, .sge => {
                    try emitter.loadSlotSigned(lhs_lane, .rax);
                    try emitter.loadSlotSigned(rhs_lane, .rcx);
                },
                .eq, .ne => {
                    try emitter.loadSlot(lhs_lane, .rax);
                    try emitter.loadSlot(rhs_lane, .rcx);
                },
            }

            if (width == 64) {
                try emitter.emitEncoding(encoding.cmpRegReg(.rax, .rcx));
            } else {
                try emitter.emitEncoding(encoding.cmpRegReg32(.rax, .rcx));
            }

            const cond = predicateToConditionInt(pred);
            try emitter.emitEncoding(encoding.setcc(.rax, cond));
            try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
            try emitter.storeSlot(dst_lane, .rax);
        }
    }
}

fn predicateToConditionInt(pred: CmpPredicate) encoding.Condition {
    return switch (pred) {
        .eq => .e,
        .ne => .ne,
        .lt, .slt => .l,
        .le, .sle => .le,
        .gt, .sgt => .g,
        .ge, .sge => .ge,
        .ult => .b,
        .ule => .be,
        .ugt => .a,
        .uge => .ae,
    };
}

const ConstantRecorder = struct {
    allocator: ?std.mem.Allocator = null,
    vector_value: *ir.Value,
    vector_slot: slot_layout.VectorSlot,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    encodings: usize = 0,
    stores: usize = 0,

    pub fn vectorSlotFor(self: *ConstantRecorder, value: *ir.Value) !slot_layout.VectorSlot {
        if (value != self.vector_value) return error.MissingSlot;
        return self.vector_slot;
    }

    pub fn emitEncoding(self: *ConstantRecorder, enc: encoding.Encoding) !void {
        if (self.allocator) |allocator| {
            try self.bytes.appendSlice(allocator, enc.slice());
        }
        self.encodings += 1;
    }

    pub fn storeSlot(self: *ConstantRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.stores += 1;
    }

    pub fn storeFromXmmPacked(self: *ConstantRecorder, value: *ir.Value, reg: registers.XMM) !void {
        try emitPackedStore(self, try self.vectorSlotFor(value), reg);
    }
};

const SplatRecorder = struct {
    allocator: std.mem.Allocator,
    scalar_value: *ir.Value,
    scalar_slot: slot_layout.Slot,
    result_value: *ir.Value,
    result_slot: slot_layout.VectorSlot,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    xmm_loads: usize = 0,
    scalar_loads: usize = 0,
    scalar_stores: usize = 0,

    pub fn slotFor(self: *SplatRecorder, value: *ir.Value) !slot_layout.Slot {
        if (value == self.scalar_value) return self.scalar_slot;
        return error.MissingSlot;
    }

    pub fn vectorSlotFor(self: *SplatRecorder, value: *ir.Value) !slot_layout.VectorSlot {
        if (value == self.result_value) return self.result_slot;
        return error.MissingSlot;
    }

    pub fn emitEncoding(self: *SplatRecorder, enc: encoding.Encoding) !void {
        try self.bytes.appendSlice(self.allocator, enc.slice());
    }

    pub fn loadSlotXmm(self: *SplatRecorder, slot: slot_layout.Slot, reg: registers.XMM) !void {
        self.xmm_loads += 1;
        const mem = encoding.Mem.baseDisp(.rbp, slot.offset);
        if (slot.width == 32) {
            try self.emitEncoding(encoding.movss(reg, .{ .mem = mem }));
        } else if (slot.width == 64) {
            try self.emitEncoding(encoding.movsd(reg, .{ .mem = mem }));
        } else {
            return error.UnsupportedType;
        }
    }

    pub fn loadSlot(self: *SplatRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_loads += 1;
    }

    pub fn storeSlot(self: *SplatRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_stores += 1;
    }

    pub fn loadIntoXmm(self: *SplatRecorder, value: *ir.Value, reg: registers.XMM) !void {
        try self.loadSlotXmm(try self.slotFor(value), reg);
    }

    pub fn registerHome(self: *SplatRecorder, value: *ir.Value) ?registers.GPR {
        _ = self;
        _ = value;
        return null;
    }

    pub fn storeFromXmmPacked(self: *SplatRecorder, value: *ir.Value, reg: registers.XMM) !void {
        try emitPackedStore(self, try self.vectorSlotFor(value), reg);
    }
};

const BinaryRecorder = struct {
    allocator: std.mem.Allocator,
    lhs_value: *ir.Value,
    lhs_slot: slot_layout.VectorSlot,
    rhs_value: *ir.Value,
    rhs_slot: slot_layout.VectorSlot,
    result_value: *ir.Value,
    result_slot: slot_layout.VectorSlot,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    scalar_loads: usize = 0,
    scalar_stores: usize = 0,

    pub fn vectorSlotFor(self: *BinaryRecorder, value: *ir.Value) !slot_layout.VectorSlot {
        if (value == self.lhs_value) return self.lhs_slot;
        if (value == self.rhs_value) return self.rhs_slot;
        if (value == self.result_value) return self.result_slot;
        return error.MissingSlot;
    }

    pub fn emitEncoding(self: *BinaryRecorder, enc: encoding.Encoding) !void {
        try self.bytes.appendSlice(self.allocator, enc.slice());
    }

    pub fn loadSlotXmm(self: *BinaryRecorder, slot: slot_layout.Slot, reg: registers.XMM) !void {
        _ = slot;
        _ = reg;
        self.scalar_loads += 1;
    }

    pub fn storeSlotXmm(self: *BinaryRecorder, slot: slot_layout.Slot, reg: registers.XMM) !void {
        _ = slot;
        _ = reg;
        self.scalar_stores += 1;
    }

    pub fn loadSlot(self: *BinaryRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_loads += 1;
    }

    pub fn loadSlotSigned(self: *BinaryRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_loads += 1;
    }

    pub fn loadSlotUnsigned(self: *BinaryRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_loads += 1;
    }

    pub fn storeSlot(self: *BinaryRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_stores += 1;
    }

    pub fn emitJccLabel(_: *BinaryRecorder, _: encoding.Condition, _: *labels.Label) !void {}

    pub fn bindLabel(_: *BinaryRecorder, _: *labels.Label) !void {}

    pub fn loadIntoXmmPacked(self: *BinaryRecorder, value: *ir.Value, reg: registers.XMM) !void {
        try emitPackedLoad(self, try self.vectorSlotFor(value), reg);
    }

    pub fn storeFromXmmPacked(self: *BinaryRecorder, value: *ir.Value, reg: registers.XMM) !void {
        try emitPackedStore(self, try self.vectorSlotFor(value), reg);
    }
};

const LaneRecorder = struct {
    allocator: std.mem.Allocator,
    vector_value: *ir.Value,
    vector_slot: slot_layout.VectorSlot,
    slot_value: *ir.Value,
    slot: slot_layout.Slot,
    result_vector_value: ?*ir.Value = null,
    result_vector_slot: slot_layout.VectorSlot = undefined,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    scalar_loads: usize = 0,
    scalar_stores: usize = 0,

    pub fn vectorSlotFor(self: *LaneRecorder, value: *ir.Value) !slot_layout.VectorSlot {
        if (value == self.vector_value) return self.vector_slot;
        if (self.result_vector_value) |result_value| {
            if (value == result_value) return self.result_vector_slot;
        }
        return error.MissingSlot;
    }

    pub fn slotFor(self: *LaneRecorder, value: *ir.Value) !slot_layout.Slot {
        if (value == self.slot_value) return self.slot;
        return error.MissingSlot;
    }

    pub fn emitEncoding(self: *LaneRecorder, enc: encoding.Encoding) !void {
        try self.bytes.appendSlice(self.allocator, enc.slice());
    }

    pub fn loadSlot(self: *LaneRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_loads += 1;
    }

    pub fn storeSlot(self: *LaneRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.scalar_stores += 1;
    }
};

fn f64x2Slot(offset: i32) slot_layout.VectorSlot {
    return .{
        .base = .{ .offset = offset, .width = 64, .ext = .unsigned },
        .lanes = 2,
        .elem_type_name = dialects.arith.type_names.float64,
        .is_float = true,
    };
}

fn f32x4Slot(offset: i32) slot_layout.VectorSlot {
    return .{
        .base = .{ .offset = offset, .width = 32, .ext = .unsigned },
        .lanes = 4,
        .elem_type_name = dialects.arith.type_names.float32,
        .is_float = true,
    };
}

fn i32x4Slot(offset: i32) slot_layout.VectorSlot {
    return .{
        .base = .{ .offset = offset, .width = 32, .ext = .signed },
        .lanes = 4,
        .elem_type_name = dialects.arith.type_names.int32,
        .is_float = false,
    };
}

fn u32x4Slot(offset: i32) slot_layout.VectorSlot {
    return .{
        .base = .{ .offset = offset, .width = 32, .ext = .unsigned },
        .lanes = 4,
        .elem_type_name = dialects.arith.type_names.uint32,
        .is_float = false,
    };
}

fn i64x2Slot(offset: i32) slot_layout.VectorSlot {
    return .{
        .base = .{ .offset = offset, .width = 64, .ext = .signed },
        .lanes = 2,
        .elem_type_name = dialects.arith.type_names.int64,
        .is_float = false,
    };
}

fn u64x2Slot(offset: i32) slot_layout.VectorSlot {
    return .{
        .base = .{ .offset = offset, .width = 64, .ext = .unsigned },
        .lanes = 2,
        .elem_type_name = dialects.arith.type_names.uint64,
        .is_float = false,
    };
}

/// `bytes`, once per lane.
fn repeated(comptime bytes: []const u8, comptime lanes: usize) [bytes.len * lanes]u8 {
    var out: [bytes.len * lanes]u8 = undefined;
    for (0..lanes) |lane| @memcpy(out[lane * bytes.len ..][0..bytes.len], bytes);
    return out;
}

fn laneSlot(
    offset: i32,
    width: u8,
    lanes: usize,
    elem_type_name: []const u8,
) slot_layout.VectorSlot {
    return .{
        .base = .{ .offset = offset, .width = width, .ext = .signed },
        .lanes = lanes,
        .elem_type_name = elem_type_name,
        .is_float = false,
    };
}

/// How a lane test's right operand is defined: a uniform literal, a mask of a non-literal by
/// one, or neither, which a sum of two literals stands in for.
const LaneOperand = union(enum) { literal: i64, mask: i64, opaque_ };

/// Emits `Op` on a non-literal left operand and a right operand defined as `rhs`, over `lanes`
/// signed lanes of `width` bits, and returns its recorder.
fn recordLaneOp(
    ctx: *ir.Context,
    comptime Op: type,
    width: u8,
    lanes: u32,
    elem_type_name: []const u8,
    rhs_operand: LaneOperand,
) !BinaryRecorder {
    const loc = ir.Location.getUnknown();
    const vec_type = (try ArithDialect.getVecType(ctx, lanes, elem_type_name)).?;
    const one = try ArithDialect.VecConstantOp.createInt(ctx, loc, vec_type, 1);
    const lhs = try ArithDialect.AddOp.create(ctx, loc, one.getResult(), one.getResult());
    const rhs = switch (rhs_operand) {
        .literal => |value| (try ArithDialect.VecConstantOp.createInt(
            ctx,
            loc,
            vec_type,
            value,
        )).getResult(),
        .mask => |value| (try ArithDialect.AndOp.create(
            ctx,
            loc,
            lhs.getResult(),
            (try ArithDialect.VecConstantOp.createInt(ctx, loc, vec_type, value)).getResult(),
        )).getResult(),
        .opaque_ => (try ArithDialect.AddOp.create(
            ctx,
            loc,
            one.getResult(),
            one.getResult(),
        )).getResult(),
    };
    const op = try Op.create(ctx, loc, lhs.getResult(), rhs);
    const span: i32 = @intCast(@as(u32, width / 8) * lanes);
    var recorder = BinaryRecorder{
        .allocator = std.testing.allocator,
        .lhs_value = lhs.getResult(),
        .lhs_slot = laneSlot(-span, width, lanes, elem_type_name),
        .rhs_value = rhs,
        .rhs_slot = laneSlot(-2 * span, width, lanes, elem_type_name),
        .result_value = op.getResult(),
        .result_slot = laneSlot(-3 * span, width, lanes, elem_type_name),
    };
    errdefer recorder.bytes.deinit(std.testing.allocator);
    if (Op == ArithDialect.DivOp) {
        try emitBinaryOp(&recorder, op.op, .div);
    } else {
        comptime std.debug.assert(Op == ArithDialect.ShlOp);
        try emitShift(&recorder, op.op, .shl);
    }
    return recorder;
}
