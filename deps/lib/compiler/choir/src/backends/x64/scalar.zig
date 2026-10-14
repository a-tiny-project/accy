const std = @import("std");
const zig_builtin = @import("builtin");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const machine = @import("../root.zig").machine_code;
const call_plan = @import("calls.zig");
const cast = @import("cast.zig");
const data = @import("data.zig");
const encoding = @import("encoding.zig");
const labels = @import("labels.zig");
const registers = @import("registers/root.zig");
const slot_layout = @import("slots.zig");

const cpu_has_fma3 = blk: {
    const features = zig_builtin.cpu.features;
    const FeatureType = std.Target.x86.Feature;
    break :blk std.Target.x86.featureSetHas(features, FeatureType.fma);
};

const cpu_has_popcnt = blk: {
    const features = zig_builtin.cpu.features;
    const FeatureType = std.Target.x86.Feature;
    break :blk std.Target.x86.featureSetHas(features, FeatureType.popcnt);
};

const arith = dialects.arith;
const ArithDialect = arith.ArithDialect;
const arith_scalar = arith.scalar;
const CmpPredicate = arith.CmpPredicate;
const Condition = encoding.Condition;
const Label = labels.Label;
const Slot = slot_layout.Slot;
const ExternArg = call_plan.ExternArg;
const ExternResult = call_plan.ExternResult;

pub fn isUnsignedIntegerTypeName(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "arith.u8") or
        std.mem.eql(u8, type_name, "arith.u16") or
        std.mem.eql(u8, type_name, "arith.u32") or
        std.mem.eql(u8, type_name, "arith.u64") or
        std.mem.eql(u8, type_name, "arith.index");
}

fn isUnsignedScalarTypeName(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "arith.u8") or
        std.mem.eql(u8, type_name, "arith.u16") or
        std.mem.eql(u8, type_name, "arith.u32") or
        std.mem.eql(u8, type_name, "arith.u64");
}

pub fn isIntegerScalarTypeName(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "arith.i8") or
        std.mem.eql(u8, type_name, "arith.i16") or
        std.mem.eql(u8, type_name, "arith.i32") or
        std.mem.eql(u8, type_name, "arith.i64") or
        isUnsignedScalarTypeName(type_name);
}

fn isFloatScalarTypeName(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.f32") or
        std.mem.eql(u8, type_name, "arith.f64");
}

pub fn emitArithConstant(self: anytype, op: *ir.Operation) !void {
    if (try data.symbolOf(op)) |symbol| return emitDataAddress(self, op, symbol);
    const const_op = ArithDialect.ConstantOp{ .op = op };
    const result = const_op.getResult();
    const slot = try self.slotFor(result);
    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;

    // An integer lands in its register home directly, or in rax on its way to its slot.
    const target: registers.GPR = self.registerHomeForPhase(result, .definition) orelse .rax;

    if (std.mem.eql(u8, type_name, "arith.bool")) {
        const bool_attr = op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse return error.InvalidConstant;
        const bool_val = bool_attr.getValue();
        try self.emitEncoding(encoding.movRegImm32(target, if (bool_val) 1 else 0));
        try self.storeFrom(result, target);
        return;
    }

    if (const_op.getIntValue()) |int_val| {
        const bits: u64 = @bitCast(int_val);
        const masked: u64 = switch (slot.width) {
            8 => bits & 0xFF,
            16 => bits & 0xFFFF,
            32 => bits & 0xFFFF_FFFF,
            64 => bits,
            else => return error.UnsupportedType,
        };
        try self.emitEncoding(immediateMove(target, masked));
        try self.storeFrom(result, target);
        return;
    }

    if (const_op.getFloatValue()) |float_val| {
        if (slot.width == 32) {
            const bits: u32 = @bitCast(@as(f32, @floatCast(float_val)));
            try self.emitEncoding(encoding.movRegImm32(.rax, bits));
        } else if (slot.width == 64) {
            const bits: u64 = @bitCast(float_val);
            try self.emitEncoding(immediateMove(.rax, bits));
        } else {
            return error.UnsupportedType;
        }
        if (self.xmmHomeForPhase(result, .definition)) |home| {
            try self.emitEncoding(encoding.movqXmmFromReg64(home, .rax));
        } else {
            try self.storeSlot(slot, .rax);
        }
        return;
    }

    return error.UnsupportedType;
}

/// The shortest move of the 64 bits `bits` into `dst`: `mov r32, imm32` zero extends what fits
/// 32 unsigned bits, `mov r64, simm32` sign extends what fits 32 signed bits, and only the rest
/// takes `movabs`.
fn immediateMove(dst: registers.GPR, bits: u64) encoding.Encoding {
    if (bits <= std.math.maxInt(u32)) return encoding.movRegImm32(dst, @intCast(bits));
    if (std.math.cast(i32, @as(i64, @bitCast(bits)))) |imm| return encoding.movRegSimm32(dst, imm);
    return encoding.movRegImm64(dst, bits);
}

/// Loads the address of `symbol` through a 64-bit immediate that a data relocation fills.
fn emitDataAddress(self: anytype, op: *ir.Operation, symbol: machine.DataSymbol) !void {
    const result = (ArithDialect.ConstantOp{ .op = op }).getResult();
    try data.emitAddress(self, result, symbol);
}

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
};

pub fn emitIntegerDiv(self: anytype, op_width: u8, is_unsigned: bool) !void {
    if (is_unsigned) {
        if (op_width == 32) {
            try self.emitEncoding(encoding.xorRegReg32(.rdx, .rdx));
            try self.emitEncoding(encoding.divReg32(.rcx));
        } else {
            try self.emitEncoding(encoding.xorRegReg(.rdx, .rdx));
            try self.emitEncoding(encoding.divReg(.rcx));
        }
        return;
    }

    if (op_width == 32) {
        try self.emitEncoding(encoding.cdq());
        try self.emitEncoding(encoding.idivReg32(.rcx));
    } else {
        try self.emitEncoding(encoding.cqo());
        try self.emitEncoding(encoding.idivReg(.rcx));
    }
}

/// Traps when the shift count in `rcx` falls outside `[0, width)`.
///
/// The count arrives extended from its own width, so one unsigned compare
/// against `width` refuses both a negative count and one at or past `width`.
pub fn emitShiftCountGuard(self: anytype, width: u8) !void {
    std.debug.assert(width == 8 or width == 16 or width == 32 or width == 64);
    if (width <= 32) {
        try self.emitEncoding(encoding.cmpRegImm32(.rcx, width));
    } else {
        try self.emitEncoding(encoding.cmpRegImm(.rcx, width));
    }
    try self.emitEncoding(encoding.jccRel32(.b, encoding.ud2().len));
    try self.emitEncoding(encoding.ud2());
}

/// Traps a signed 8 or 16 bit division of the width's minimum by -1.
///
/// Narrow division runs at 32 bits on operands sign extended into `eax` and
/// `ecx`, where the quotient fits and the hardware raises nothing. A zero
/// divisor still faults in the hardware divide.
pub fn emitNarrowQuotientGuard(self: anytype, width: u8) !void {
    std.debug.assert(width == 8 or width == 16);
    const min: i32 = -(@as(i32, 1) << @intCast(width - 1));
    const trap = encoding.ud2();
    const is_min = encoding.cmpRegImm32(.rax, min);
    const past_min = encoding.jccRel32(.ne, trap.len);
    try self.emitEncoding(encoding.cmpRegImm32(.rcx, -1));
    try self.emitEncoding(encoding.jccRel32(.ne, is_min.len + past_min.len + trap.len));
    try self.emitEncoding(is_min);
    try self.emitEncoding(past_min);
    try self.emitEncoding(trap);
}

/// Returns k when `rhs` is the literal 2^k with 1 <= k <= width - 2, a positive power of two a
/// signed division by can take as a shift. -2^k, 1 and MIN stay on the divide.
pub fn powerOfTwoShift(rhs: *ir.Value, width: u8) ?u6 {
    const literal = literalWord(rhs) orelse return null;
    const divisor = arith_scalar.truncate(literal, width);
    if (divisor < 2 or !std.math.isPowerOfTwo(divisor)) return null;
    const shift = std.math.log2_int(u64, @intCast(divisor));
    std.debug.assert(shift <= width - 2);
    return @intCast(shift);
}

/// Divides or takes the remainder of `lhs` by 2^`shift`, rounding toward zero as `idiv` does.
///
/// A negative dividend takes a bias of 2^shift - 1 before the arithmetic shift, so the shift's
/// floor rounds toward zero; the bias is the sign smeared across the low `shift` bits. The
/// remainder subtracts the biased dividend with its low `shift` bits cleared. Operands of 8 and
/// 16 bits are sign extended at 32 bits, where neither the bias nor the quotient can overflow.
fn emitSignedPowerOfTwoDivision(
    self: anytype,
    lhs: *ir.Value,
    result: *ir.Value,
    kind: BinOp,
    op_width: u8,
    shift: u6,
) !void {
    std.debug.assert(op_width == 32 or op_width == 64);
    std.debug.assert(shift >= 1 and shift <= op_width - 2);
    const wide = op_width == 64;
    try self.loadInto(lhs, .rax);
    try self.emitEncoding(if (wide) encoding.movRegReg(.rcx, .rax) else encoding.movRegReg32(.rcx, .rax));
    // For a shift of one the sign bit alone is the bias, so the logical shift finds it.
    if (shift > 1) {
        try self.emitEncoding(if (wide) encoding.sarRegImm(.rcx, op_width - 1) else encoding.sarRegImm32(.rcx, op_width - 1));
    }
    try self.emitEncoding(if (wide) encoding.shrRegImm(.rcx, op_width - shift) else encoding.shrRegImm32(.rcx, op_width - shift));
    switch (kind) {
        .div => {
            try self.emitEncoding(if (wide) encoding.addRegReg(.rax, .rcx) else encoding.addRegReg32(.rax, .rcx));
            try self.emitEncoding(if (wide) encoding.sarRegImm(.rax, shift) else encoding.sarRegImm32(.rax, shift));
        },
        .rem => {
            try self.emitEncoding(if (wide) encoding.addRegReg(.rcx, .rax) else encoding.addRegReg32(.rcx, .rax));
            if (shift < 32) {
                const mask: i32 = @intCast(-(@as(i64, 1) << shift));
                try self.emitEncoding(if (wide) encoding.andRegImm(.rcx, mask) else encoding.andRegImm32(.rcx, mask));
            } else {
                try self.emitEncoding(encoding.sarRegImm(.rcx, shift));
                try self.emitEncoding(encoding.shlRegImm(.rcx, shift));
            }
            try self.emitEncoding(if (wide) encoding.subRegReg(.rax, .rcx) else encoding.subRegReg32(.rax, .rcx));
        },
        .add, .sub, .mul => unreachable,
    }
    try self.storeFrom(result, .rax);
}

/// Answers whether the literals of a signed division prove its quotient fits,
/// by the rule the arith declaration states.
pub fn quotientRepresentable(lhs: *ir.Value, rhs: *ir.Value, width: u8) bool {
    const right = literalWord(rhs) orelse return false;
    if (arith_scalar.truncate(right, width) != -1) return true;
    const left = literalWord(lhs) orelse return false;
    return @as(i128, arith_scalar.truncate(left, width)) != arith_scalar.intLimits(width).min;
}

/// Answers whether the count's definition proves the shift in bounds: a
/// literal below `width`, or a mask by one, which bounds the count by the mask.
pub fn shiftCountInBounds(count: *ir.Value, width: u8) bool {
    if (literalWord(count)) |value| return arith_scalar.shiftCount(value, width) != null;
    const op = definingOp(count) orelse return false;
    if (!std.mem.eql(u8, op.name.name, ArithDialect.AndOp.operation_name)) return false;
    for (op.operands.items) |operand| {
        const mask = literalWord(operand.value) orelse continue;
        if (arith_scalar.shiftCount(mask, width) != null) return true;
    }
    return false;
}

pub fn shouldSkipArithConstant(op: *ir.Operation) bool {
    const result = op.getResult(0) orelse return false;
    const fits = constantIntI32(result) != null;
    if (result.first_use == null) return fits;

    var use = result.first_use;
    while (use) |operand| {
        const user: *ir.Operation = @ptrCast(@alignCast(operand.owner));
        const immediate = fits and immediateUseSupported(user, operand.operand_number);
        if (!immediate and !inPlaceLiteralUse(user, operand.operand_number)) return false;
        use = operand.next_use;
    }
    return true;
}

pub fn emitBinaryIntOp(self: anytype, op: *ir.Operation, kind: BinOp) !void {
    if (placesOperands(op)) return emitInPlace(self, op);
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const is_float = std.mem.eql(u8, type_name, "arith.f32") or std.mem.eql(u8, type_name, "arith.f64");
    const is_unsigned = isUnsignedIntegerTypeName(type_name);
    if ((kind == .div or kind == .rem) and std.mem.eql(u8, type_name, "arith.bool")) return error.UnsupportedType;

    if (is_float) {
        try self.loadIntoXmm(lhs, .xmm0);
        try self.loadIntoXmm(rhs, .xmm1);
        if (result_slot.width == 32) {
            switch (kind) {
                .add => try self.emitEncoding(encoding.addss(.xmm0, .{ .reg = .xmm1 })),
                .sub => try self.emitEncoding(encoding.subss(.xmm0, .{ .reg = .xmm1 })),
                .mul => try self.emitEncoding(encoding.mulss(.xmm0, .{ .reg = .xmm1 })),
                .div => try self.emitEncoding(encoding.divss(.xmm0, .{ .reg = .xmm1 })),
                .rem => return error.UnsupportedType,
            }
        } else if (result_slot.width == 64) {
            switch (kind) {
                .add => try self.emitEncoding(encoding.addsd(.xmm0, .{ .reg = .xmm1 })),
                .sub => try self.emitEncoding(encoding.subsd(.xmm0, .{ .reg = .xmm1 })),
                .mul => try self.emitEncoding(encoding.mulsd(.xmm0, .{ .reg = .xmm1 })),
                .div => try self.emitEncoding(encoding.divsd(.xmm0, .{ .reg = .xmm1 })),
                .rem => return error.UnsupportedType,
            }
        } else {
            return error.UnsupportedType;
        }
        try self.storeFromXmm(result, .xmm0);
        return;
    }

    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
    const op_width: u8 = if (width <= 32) 32 else 64;

    if (immediateRhs(op)) |imm| {
        const wide = op_width == 64;
        try self.loadInto(lhs, .rax);
        switch (kind) {
            .add => try self.emitEncoding(encoding.aluRegImm(.add, .rax, imm, wide)),
            .sub => if (wide) {
                try self.emitEncoding(encoding.subRegImm(.rax, imm));
            } else {
                try self.emitEncoding(encoding.subRegImm32(.rax, imm));
            },
            .mul => try self.emitEncoding(encoding.imulRegRegImm(.rax, .rax, imm, wide)),
            .div, .rem => unreachable,
        }
        try self.storeFrom(result, .rax);
        return;
    }

    if ((kind == .div or kind == .rem) and !is_unsigned) {
        if (powerOfTwoShift(rhs, width)) |shift| {
            try emitSignedPowerOfTwoDivision(self, lhs, result, kind, op_width, shift);
            return;
        }
    }

    try self.loadInto(lhs, .rax);
    try self.loadInto(rhs, .rcx);

    if ((kind == .div or kind == .rem) and !is_unsigned and width < 32 and
        !quotientRepresentable(lhs, rhs, width))
    {
        try emitNarrowQuotientGuard(self, width);
    }

    switch (kind) {
        .add => {
            if (op_width == 32) {
                try self.emitEncoding(encoding.addRegReg32(.rax, .rcx));
            } else {
                try self.emitEncoding(encoding.addRegReg(.rax, .rcx));
            }
            try self.storeFrom(result, .rax);
        },
        .sub => {
            if (op_width == 32) {
                try self.emitEncoding(encoding.subRegReg32(.rax, .rcx));
            } else {
                try self.emitEncoding(encoding.subRegReg(.rax, .rcx));
            }
            try self.storeFrom(result, .rax);
        },
        .mul => {
            if (op_width == 32) {
                try self.emitEncoding(encoding.imulRegReg32(.rax, .rcx));
            } else {
                try self.emitEncoding(encoding.imulRegReg(.rax, .rcx));
            }
            try self.storeFrom(result, .rax);
        },
        .div => {
            try emitIntegerDiv(self, op_width, is_unsigned);
            try self.storeFrom(result, .rax);
        },
        .rem => {
            try emitIntegerDiv(self, op_width, is_unsigned);
            try self.storeFrom(result, .rdx);
        },
    }
}

/// The arithmetic instruction must write OF even for constant operands. In particular, this
/// path never calls the ordinary binary emitter, whose lea/shift forms do not answer overflow.
/// The allocator fixes the two definitions to rax and rcx, so settling the value cannot
/// overwrite the flag. A materialized bool captures OF before either result settles.
/// A flags-only bool leaves OF live through storeFrom's mov (or no instruction), then
/// the adjacent branch's allocator transitions, which emit only flag-preserving moves.
pub fn emitOverflow(self: anytype, op: *ir.Operation, kind: enum { add, sub, mul }) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const overflow = op.getResult(1) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;
    if (op.getNumResults() != 2 or op.getNumOperands() != 2) return error.UnsupportedOperation;
    if (arith.scalarKindFromType(lhs.type) != .i64 or
        arith.scalarKindFromType(rhs.type) != .i64 or
        arith.scalarKindFromType(result.type) != .i64 or
        arith.scalarKindFromType(overflow.type) != .bool) return error.UnsupportedType;

    try self.loadInto(lhs, .rax);
    try self.loadInto(rhs, .rcx);
    try self.emitEncoding(switch (kind) {
        .add => encoding.addRegReg(.rax, .rcx),
        .sub => encoding.subRegReg(.rax, .rcx),
        .mul => encoding.imulRegReg(.rax, .rcx),
    });
    const flags_only = self.flagsOnly(overflow);
    if (!flags_only) {
        try self.emitEncoding(encoding.setcc(.rcx, .o));
        try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
    }
    try self.storeFrom(result, .rax);
    if (!flags_only) try self.storeFrom(overflow, .rcx);
}

pub fn emitArithUmulhi(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const lhs_type_name = lhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    const rhs_type_name = rhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, lhs_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, rhs_type_name)) return error.UnsupportedType;
    if (arith.parseVectorTypeName(type_name) != null) return error.UnsupportedType;
    if (!isIntegerScalarTypeName(type_name)) return error.UnsupportedType;

    const result_slot = try self.slotFor(result);
    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    try self.loadIntoUnsigned(lhs, .rax);
    try self.loadIntoUnsigned(rhs, .rcx);
    try emitUnsignedHighProductFromRaxRcx(self, width);
    try self.storeFrom(result, .rax);
}

pub fn emitUnsignedHighProductFromRaxRcx(self: anytype, width: u8) !void {
    switch (width) {
        8, 16 => {
            try self.emitEncoding(encoding.imulRegReg32(.rax, .rcx));
            try self.emitEncoding(encoding.shrRegImm(.rax, width));
        },
        32 => {
            try self.emitEncoding(encoding.mulReg32(.rcx));
            try self.emitEncoding(encoding.movRegReg32(.rax, .rdx));
        },
        64 => {
            try self.emitEncoding(encoding.mulReg(.rcx));
            try self.emitEncoding(encoding.movRegReg(.rax, .rdx));
        },
        else => return error.UnsupportedType,
    }
}

pub fn emitArithPopCount(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const input = op.getOperand(0) orelse return error.MissingOperand;

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const input_type_name = input.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, input_type_name)) return error.UnsupportedType;
    if (arith.parseVectorTypeName(type_name) != null) return error.UnsupportedType;
    if (std.mem.eql(u8, type_name, "arith.bool") or isFloatScalarTypeName(type_name)) return error.UnsupportedType;
    if (!isIntegerScalarTypeName(type_name) and !std.mem.eql(u8, type_name, "arith.index")) return error.UnsupportedType;

    const result_slot = try self.slotFor(result);
    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    try self.loadIntoUnsigned(input, .rax);
    try emitPopCountFromRax(self, width);
    try self.storeFrom(result, .rax);
}

pub fn emitPopCountFromRax(self: anytype, width: u8) !void {
    if (cpu_has_popcnt) {
        if (width == 64) {
            try self.emitEncoding(encoding.popcntRegReg(.rax, .rax));
        } else {
            try self.emitEncoding(encoding.popcntRegReg32(.rax, .rax));
        }
    } else {
        try emitPopCountSoftware(self);
    }
}

fn emitPopCountSoftware(self: anytype) !void {
    try self.emitEncoding(encoding.movRegReg(.rdx, .rax));
    try self.emitEncoding(encoding.shrRegImm(.rdx, 1));
    try self.emitEncoding(encoding.movRegImm64(.rcx, 0x5555_5555_5555_5555));
    try self.emitEncoding(encoding.andRegReg(.rdx, .rcx));
    try self.emitEncoding(encoding.subRegReg(.rax, .rdx));

    try self.emitEncoding(encoding.movRegImm64(.rcx, 0x3333_3333_3333_3333));
    try self.emitEncoding(encoding.movRegReg(.rdx, .rax));
    try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
    try self.emitEncoding(encoding.shrRegImm(.rdx, 2));
    try self.emitEncoding(encoding.andRegReg(.rdx, .rcx));
    try self.emitEncoding(encoding.addRegReg(.rax, .rdx));

    try self.emitEncoding(encoding.movRegReg(.rdx, .rax));
    try self.emitEncoding(encoding.shrRegImm(.rdx, 4));
    try self.emitEncoding(encoding.addRegReg(.rax, .rdx));
    try self.emitEncoding(encoding.movRegImm64(.rcx, 0x0f0f_0f0f_0f0f_0f0f));
    try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
    try self.emitEncoding(encoding.movRegImm64(.rcx, 0x0101_0101_0101_0101));
    try self.emitEncoding(encoding.imulRegReg(.rax, .rcx));
    try self.emitEncoding(encoding.shrRegImm(.rax, 56));
}

pub fn emitArithNeg(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const operand = op.getOperand(0) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (std.mem.eql(u8, type_name, "arith.index")) return error.UnsupportedType;
    if (std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.bool")) return error.UnsupportedType;

    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (is_f32 or is_f64) {
        return emitArithNegFloat(self, result, operand, is_f32);
    }

    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
    const op_width: u8 = if (width <= 32) 32 else 64;

    try self.loadInto(operand, .rax);
    if (op_width == 32) {
        try self.emitEncoding(encoding.negReg32(.rax));
    } else {
        try self.emitEncoding(encoding.negReg(.rax));
    }
    try self.storeFrom(result, .rax);
}

fn emitArithNegFloat(
    self: anytype,
    result: *ir.Value,
    operand: *ir.Value,
    is_f32: bool,
) !void {
    try self.loadIntoXmm(operand, .xmm0);
    try self.emitEncoding(encoding.pcmpeqd(.xmm1, .{ .reg = .xmm1 }));
    if (is_f32) {
        try self.emitEncoding(encoding.pslldImm(.xmm1, 31));
        try self.emitEncoding(encoding.xorps(.xmm0, .{ .reg = .xmm1 }));
    } else {
        try self.emitEncoding(encoding.psllqImm(.xmm1, 63));
        try self.emitEncoding(encoding.xorpd(.xmm0, .{ .reg = .xmm1 }));
    }
    try self.storeFromXmm(result, .xmm0);
}

pub const MinMaxKind = enum { max, min };

pub fn emitArithMax(self: anytype, op: *ir.Operation) !void {
    return emitArithMinMax(self, op, .max);
}

pub fn emitArithMin(self: anytype, op: *ir.Operation) !void {
    return emitArithMinMax(self, op, .min);
}

fn emitArithMinMax(self: anytype, op: *ir.Operation, kind: MinMaxKind) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const lhs_type_name = lhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    const rhs_type_name = rhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, lhs_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, rhs_type_name)) return error.UnsupportedType;

    if (std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.bool")) return error.UnsupportedType;

    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (is_f32 or is_f64) {
        return emitArithMinMaxFloat(self, result, lhs, rhs, is_f32, kind);
    }

    const is_unsigned = isUnsignedIntegerTypeName(type_name);

    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
    const op_width: u8 = if (width <= 32) 32 else 64;

    if (is_unsigned) {
        try self.loadIntoUnsigned(lhs, .rax);
        try self.loadIntoUnsigned(rhs, .rcx);
    } else {
        try self.loadInto(lhs, .rax);
        try self.loadInto(rhs, .rcx);
    }

    try emitIntegerMinMax(self, op_width, is_unsigned, kind);
    try self.storeFrom(result, .rax);
}

pub fn emitIntegerMinMax(self: anytype, op_width: u8, is_unsigned: bool, kind: MinMaxKind) !void {
    if (op_width == 32) {
        try self.emitEncoding(encoding.cmpRegReg32(.rax, .rcx));
        if (is_unsigned) {
            switch (kind) {
                .max => try self.emitEncoding(encoding.cmovbRegReg32(.rax, .rcx)),
                .min => try self.emitEncoding(encoding.cmovaRegReg32(.rax, .rcx)),
            }
        } else {
            switch (kind) {
                .max => try self.emitEncoding(encoding.cmovlRegReg32(.rax, .rcx)),
                .min => try self.emitEncoding(encoding.cmovgRegReg32(.rax, .rcx)),
            }
        }
    } else {
        try self.emitEncoding(encoding.cmpRegReg(.rax, .rcx));
        if (is_unsigned) {
            switch (kind) {
                .max => try self.emitEncoding(encoding.cmovbRegReg(.rax, .rcx)),
                .min => try self.emitEncoding(encoding.cmovaRegReg(.rax, .rcx)),
            }
        } else {
            switch (kind) {
                .max => try self.emitEncoding(encoding.cmovlRegReg(.rax, .rcx)),
                .min => try self.emitEncoding(encoding.cmovgRegReg(.rax, .rcx)),
            }
        }
    }
}

fn emitArithMinMaxFloat(
    self: anytype,
    result: *ir.Value,
    lhs: *ir.Value,
    rhs: *ir.Value,
    is_f32: bool,
    kind: MinMaxKind,
) !void {
    try self.loadIntoXmm(lhs, .xmm0);
    try self.loadIntoXmm(rhs, .xmm1);
    try emitFloatMinMax(self, is_f32, kind);
    try self.storeFromXmm(result, .xmm0);
}

pub fn emitFloatMinMax(
    self: anytype,
    is_f32: bool,
    kind: MinMaxKind,
) !void {
    if (is_f32) {
        try self.emitEncoding(encoding.movss(.xmm2, .{ .reg = .xmm0 }));
    } else {
        try self.emitEncoding(encoding.movsd(.xmm2, .{ .reg = .xmm0 }));
    }

    switch (kind) {
        .max => {
            if (is_f32) {
                try self.emitEncoding(encoding.maxss(.xmm0, .{ .reg = .xmm1 }));
            } else {
                try self.emitEncoding(encoding.maxsd(.xmm0, .{ .reg = .xmm1 }));
            }
        },
        .min => {
            if (is_f32) {
                try self.emitEncoding(encoding.minss(.xmm0, .{ .reg = .xmm1 }));
            } else {
                try self.emitEncoding(encoding.minsd(.xmm0, .{ .reg = .xmm1 }));
            }
        },
    }

    if (is_f32) {
        try self.emitEncoding(encoding.ucomiss(.xmm0, .{ .reg = .xmm0 }));
    } else {
        try self.emitEncoding(encoding.ucomisd(.xmm0, .{ .reg = .xmm0 }));
    }

    var done_label = Label{};
    defer done_label.deinit(self.allocator);
    try self.emitJccLabel(.np, &done_label);

    if (is_f32) {
        try self.emitEncoding(encoding.movss(.xmm0, .{ .reg = .xmm2 }));
    } else {
        try self.emitEncoding(encoding.movsd(.xmm0, .{ .reg = .xmm2 }));
    }

    try self.bindLabel(&done_label);
}

pub fn emitArithSqrt(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const operand = op.getOperand(0) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);
    const operand_slot = try self.slotFor(operand);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (!is_f32 and !is_f64) return error.UnsupportedType;

    try self.loadSlotXmm(operand_slot, .xmm0);
    if (is_f32) {
        try self.emitEncoding(encoding.sqrtss(.xmm0, .{ .reg = .xmm0 }));
    } else {
        try self.emitEncoding(encoding.sqrtsd(.xmm0, .{ .reg = .xmm0 }));
    }
    try self.storeSlotXmm(result_slot, .xmm0);
}

pub fn emitArithAbs(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const operand = op.getOperand(0) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (std.mem.eql(u8, type_name, "arith.index")) return error.UnsupportedType;
    if (std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.bool")) return error.UnsupportedType;

    if (isUnsignedScalarTypeName(type_name)) {
        try self.loadIntoUnsigned(operand, .rax);
        try self.storeFrom(result, .rax);
        return;
    }

    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (is_f32 or is_f64) {
        return emitArithAbsFloat(self, result_slot, try self.slotFor(operand), is_f32);
    }

    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
    const op_width: u8 = if (width <= 32) 32 else 64;

    try self.loadInto(operand, .rax);
    if (op_width == 32) {
        try self.emitEncoding(encoding.movRegReg32(.rcx, .rax));
        try self.emitEncoding(encoding.negReg32(.rcx));
        try self.emitEncoding(encoding.cmovnsRegReg32(.rax, .rcx));
    } else {
        try self.emitEncoding(encoding.movRegReg(.rcx, .rax));
        try self.emitEncoding(encoding.negReg(.rcx));
        try self.emitEncoding(encoding.cmovnsRegReg(.rax, .rcx));
    }
    try self.storeFrom(result, .rax);
}

fn emitArithAbsFloat(
    self: anytype,
    result_slot: anytype,
    operand_slot: anytype,
    is_f32: bool,
) !void {
    try self.loadSlotXmm(operand_slot, .xmm0);
    try self.emitEncoding(encoding.pcmpeqd(.xmm1, .{ .reg = .xmm1 }));
    if (is_f32) {
        try self.emitEncoding(encoding.psrldImm(.xmm1, 1));
        try self.emitEncoding(encoding.andps(.xmm0, .{ .reg = .xmm1 }));
    } else {
        try self.emitEncoding(encoding.psrlqImm(.xmm1, 1));
        try self.emitEncoding(encoding.andpd(.xmm0, .{ .reg = .xmm1 }));
    }
    try self.storeSlotXmm(result_slot, .xmm0);
}

pub const LibmUnaryKind = enum { sin, cos, tan, exp, log, log1p, expm1, tanh, floor };
pub const LibmBinaryKind = enum { pow };
const LibmTernaryKind = enum { fma };

fn libmUnaryCallee(kind: LibmUnaryKind, is_f32: bool) []const u8 {
    return switch (kind) {
        .sin => if (is_f32) "sinf" else "sin",
        .cos => if (is_f32) "cosf" else "cos",
        .tan => if (is_f32) "tanf" else "tan",
        .exp => if (is_f32) "expf" else "exp",
        .log => if (is_f32) "logf" else "log",
        .log1p => "log1p",
        .expm1 => "expm1",
        .tanh => if (is_f32) "tanhf" else "tanh",
        .floor => if (is_f32) "floorf" else "floor",
    };
}

fn libmBinaryCallee(kind: LibmBinaryKind, is_f32: bool) []const u8 {
    return switch (kind) {
        .pow => if (is_f32) "powf" else "pow",
    };
}

fn libmTernaryCallee(kind: LibmTernaryKind, is_f32: bool) []const u8 {
    return switch (kind) {
        .fma => if (is_f32) "fmaf" else "fma",
    };
}

pub fn emitArithLibmUnary(self: anytype, op: *ir.Operation, kind: LibmUnaryKind) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const operand = op.getOperand(0) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);
    const operand_slot = try self.slotFor(operand);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const operand_type_name = operand.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, operand_type_name)) return error.UnsupportedType;

    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (!is_f32 and !is_f64) return error.UnsupportedType;
    // `sys.math` binds log1p and expm1 at f64 only.
    if (is_f32 and (kind == .log1p or kind == .expm1)) return error.UnsupportedType;

    const callee = libmUnaryCallee(kind, is_f32);
    const args = [_]ExternArg{
        .{ .type_name = type_name, .source = .{ .slot = operand_slot } },
    };
    const call_result: ExternResult = .{ .type_name = type_name, .slot = result_slot };
    try call_plan.emitExtern(self, callee, &args, &.{call_result});
}

pub fn emitArithLibmBinary(self: anytype, op: *ir.Operation, kind: LibmBinaryKind) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const base = op.getOperand(0) orelse return error.MissingOperand;
    const exponent = op.getOperand(1) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);
    const base_slot = try self.slotFor(base);
    const exponent_slot = try self.slotFor(exponent);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const base_type_name = base.type.getDialectTypeName() orelse return error.UnsupportedType;
    const exponent_type_name = exponent.type.getDialectTypeName() orelse return error.UnsupportedType;

    if (!std.mem.eql(u8, type_name, base_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, exponent_type_name)) return error.UnsupportedType;

    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (!is_f32 and !is_f64) return error.UnsupportedType;

    const callee = libmBinaryCallee(kind, is_f32);
    const args = [_]ExternArg{
        .{ .type_name = type_name, .source = .{ .slot = base_slot } },
        .{ .type_name = type_name, .source = .{ .slot = exponent_slot } },
    };
    const call_result: ExternResult = .{ .type_name = type_name, .slot = result_slot };
    try call_plan.emitExtern(self, callee, &args, &.{call_result});
}

fn emitArithLibmTernary(
    self: anytype,
    op: *ir.Operation,
    kind: LibmTernaryKind,
) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const a = op.getOperand(0) orelse return error.MissingOperand;
    const b = op.getOperand(1) orelse return error.MissingOperand;
    const c = op.getOperand(2) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);
    const a_slot = try self.slotFor(a);
    const b_slot = try self.slotFor(b);
    const c_slot = try self.slotFor(c);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const a_type_name = a.type.getDialectTypeName() orelse return error.UnsupportedType;
    const b_type_name = b.type.getDialectTypeName() orelse return error.UnsupportedType;
    const c_type_name = c.type.getDialectTypeName() orelse return error.UnsupportedType;

    if (!std.mem.eql(u8, type_name, a_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, b_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, c_type_name)) return error.UnsupportedType;

    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (!is_f32 and !is_f64) return error.UnsupportedType;

    const callee = libmTernaryCallee(kind, is_f32);
    const args = [_]ExternArg{
        .{ .type_name = type_name, .source = .{ .slot = a_slot } },
        .{ .type_name = type_name, .source = .{ .slot = b_slot } },
        .{ .type_name = type_name, .source = .{ .slot = c_slot } },
    };
    const call_result: ExternResult = .{ .type_name = type_name, .slot = result_slot };
    try call_plan.emitExtern(self, callee, &args, &.{call_result});
}

pub fn emitArithFma(self: anytype, op: *ir.Operation) !void {
    if (comptime cpu_has_fma3) {
        return emitArithFmaNative(self, op);
    }
    return emitArithLibmTernary(self, op, .fma);
}

fn emitArithFmaNative(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const a = op.getOperand(0) orelse return error.MissingOperand;
    const b = op.getOperand(1) orelse return error.MissingOperand;
    const c = op.getOperand(2) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);
    const a_slot = try self.slotFor(a);
    const b_slot = try self.slotFor(b);
    const c_slot = try self.slotFor(c);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const a_type_name = a.type.getDialectTypeName() orelse return error.UnsupportedType;
    const b_type_name = b.type.getDialectTypeName() orelse return error.UnsupportedType;
    const c_type_name = c.type.getDialectTypeName() orelse return error.UnsupportedType;

    if (!std.mem.eql(u8, type_name, a_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, b_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, c_type_name)) return error.UnsupportedType;

    const is_f32 = std.mem.eql(u8, type_name, "arith.f32");
    const is_f64 = std.mem.eql(u8, type_name, "arith.f64");
    if (!is_f32 and !is_f64) return error.UnsupportedType;

    try self.loadSlotXmm(a_slot, .xmm0);
    try self.loadSlotXmm(b_slot, .xmm1);
    try self.loadSlotXmm(c_slot, .xmm2);

    if (is_f32) {
        try self.emitEncoding(encoding.vfmadd231ss(.xmm2, .xmm0, .xmm1));
    } else {
        try self.emitEncoding(encoding.vfmadd231sd(.xmm2, .xmm0, .xmm1));
    }

    try self.storeSlotXmm(result_slot, .xmm2);
}

pub const BitwiseBinaryKind = enum { band, bor, bxor };
pub const ShiftKind = enum { shl, shr, ushr };

pub fn emitArithBitwiseBinary(
    self: anytype,
    op: *ir.Operation,
    kind: BitwiseBinaryKind,
) !void {
    if (placesOperands(op)) return emitInPlace(self, op);
    const result = op.getResult(0) orelse return error.MissingResult;
    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const lhs_type_name = lhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    const rhs_type_name = rhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, lhs_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, rhs_type_name)) return error.UnsupportedType;

    if (std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.f32") or
        std.mem.eql(u8, type_name, "arith.f64")) return error.UnsupportedType;

    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
    const op_width: u8 = if (width <= 32) 32 else 64;

    if (immediateRhs(op)) |imm| {
        try self.loadInto(lhs, .rax);
        const alu: encoding.AluImm = switch (kind) {
            .band => .and_,
            .bor => .or_,
            .bxor => .xor,
        };
        try self.emitEncoding(encoding.aluRegImm(alu, .rax, imm, op_width == 64));
        try self.storeFrom(result, .rax);
        return;
    }

    try self.loadInto(lhs, .rax);
    try self.loadInto(rhs, .rcx);
    if (op_width == 32) {
        switch (kind) {
            .band => try self.emitEncoding(encoding.andRegReg32(.rax, .rcx)),
            .bor => try self.emitEncoding(encoding.orRegReg32(.rax, .rcx)),
            .bxor => try self.emitEncoding(encoding.xorRegReg32(.rax, .rcx)),
        }
    } else {
        switch (kind) {
            .band => try self.emitEncoding(encoding.andRegReg(.rax, .rcx)),
            .bor => try self.emitEncoding(encoding.orRegReg(.rax, .rcx)),
            .bxor => try self.emitEncoding(encoding.xorRegReg(.rax, .rcx)),
        }
    }
    try self.storeFrom(result, .rax);
}

pub fn emitArithNot(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const operand = op.getOperand(0) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const operand_type_name = operand.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, operand_type_name)) return error.UnsupportedType;

    if (std.mem.eql(u8, type_name, "arith.bool")) {
        try self.loadInto(operand, .rax);
        try self.emitEncoding(encoding.cmpRegImm(.rax, 0));
        try self.emitEncoding(encoding.setcc(.rax, .e));
        try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
        try self.storeFrom(result, .rax);
        return;
    }

    if (std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.f32") or
        std.mem.eql(u8, type_name, "arith.f64")) return error.UnsupportedType;

    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
    const op_width: u8 = if (width <= 32) 32 else 64;

    try self.loadInto(operand, .rax);
    if (op_width == 32) {
        try self.emitEncoding(encoding.notReg32(.rax));
    } else {
        try self.emitEncoding(encoding.notReg(.rax));
    }
    try self.storeFrom(result, .rax);
}

pub fn emitArithShift(self: anytype, op: *ir.Operation, kind: ShiftKind) !void {
    if (placesOperands(op)) return emitInPlace(self, op);
    const result = op.getResult(0) orelse return error.MissingResult;
    const value = op.getOperand(0) orelse return error.MissingOperand;
    const count = op.getOperand(1) orelse return error.MissingOperand;

    const result_slot = try self.slotFor(result);

    const type_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const value_type_name = value.type.getDialectTypeName() orelse return error.UnsupportedType;
    const count_type_name = count.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, value_type_name)) return error.UnsupportedType;
    if (!std.mem.eql(u8, type_name, count_type_name)) return error.UnsupportedType;

    if (std.mem.eql(u8, type_name, "arith.f16") or
        std.mem.eql(u8, type_name, "arith.bf16") or
        std.mem.eql(u8, type_name, "arith.f32") or
        std.mem.eql(u8, type_name, "arith.f64") or
        std.mem.eql(u8, type_name, "arith.bool")) return error.UnsupportedType;

    if (isUnsignedIntegerTypeName(type_name) and kind == .shr) return error.UnsupportedType;

    const width = result_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;
    const op_width: u8 = if (width <= 32) 32 else 64;

    if (kind == .ushr) {
        try self.loadIntoUnsigned(value, .rax);
    } else {
        try self.loadInto(value, .rax);
    }
    try self.loadInto(count, .rcx);
    if (!shiftCountInBounds(count, width)) try emitShiftCountGuard(self, width);

    if (op_width == 32) {
        switch (kind) {
            .shl => try self.emitEncoding(encoding.shlRegCl32(.rax)),
            .shr => try self.emitEncoding(encoding.sarRegCl32(.rax)),
            .ushr => try self.emitEncoding(encoding.shrRegCl32(.rax)),
        }
    } else {
        switch (kind) {
            .shl => try self.emitEncoding(encoding.shlRegCl(.rax)),
            .shr => try self.emitEncoding(encoding.sarRegCl(.rax)),
            .ushr => try self.emitEncoding(encoding.shrRegCl(.rax)),
        }
    }
    try self.storeFrom(result, .rax);
}

pub fn emitArithSelect(self: anytype, op: *ir.Operation) !void {
    if (op.operands.items.len != 3) return error.UnsupportedOperation;
    const cond = op.getOperand(0) orelse return error.MissingOperand;
    const true_val = op.getOperand(1) orelse return error.MissingOperand;
    const false_val = op.getOperand(2) orelse return error.MissingOperand;
    const result = op.getResult(0) orelse return error.MissingResult;

    const cond_slot = try self.slotFor(cond);
    const true_slot = try self.slotFor(true_val);
    const false_slot = try self.slotFor(false_val);
    const result_slot = try self.slotFor(result);

    const cond_name = cond.type.getDialectTypeName() orelse return error.UnsupportedType;
    if (!std.mem.eql(u8, cond_name, "arith.bool")) return error.UnsupportedType;

    const result_kind = cast.Kind.fromTypeName(result.type.getDialectTypeName() orelse return error.UnsupportedType) orelse return error.UnsupportedType;
    const true_kind = cast.Kind.fromTypeName(true_val.type.getDialectTypeName() orelse return error.UnsupportedType) orelse return error.UnsupportedType;
    const false_kind = cast.Kind.fromTypeName(false_val.type.getDialectTypeName() orelse return error.UnsupportedType) orelse return error.UnsupportedType;
    if (result_kind != true_kind or result_kind != false_kind) return error.UnsupportedType;
    if (!result.type.eql(true_val.type)) return error.UnsupportedType;
    if (!result.type.eql(false_val.type)) return error.UnsupportedType;

    const is_f32 = result_kind == .f32_;
    const is_f64 = result_kind == .f64_;

    if (is_f32 or is_f64) {
        try self.loadInto(cond, .rax);
        try self.loadIntoXmm(true_val, .xmm0);
        try self.loadIntoXmm(false_val, .xmm1);
        try self.emitEncoding(encoding.cmpRegImm(.rax, 0));

        var done_label = Label{};
        defer done_label.deinit(self.allocator);
        try self.emitJccLabel(.ne, &done_label);

        if (is_f32) {
            try self.emitEncoding(encoding.movss(.xmm0, .{ .reg = .xmm1 }));
        } else {
            try self.emitEncoding(encoding.movsd(.xmm0, .{ .reg = .xmm1 }));
        }

        try self.bindLabel(&done_label);
        try self.storeFromXmm(result, .xmm0);
        return;
    }

    if (cond_slot.width == 64 and true_slot.width == 64 and false_slot.width == 64 and result_slot.width == 64) {
        try self.loadInto(cond, .rax);
        try self.loadInto(true_val, .rcx);
        try self.loadInto(false_val, .rdx);
    } else {
        try self.loadIntoUnsigned(cond, .rax);
        try self.loadIntoUnsigned(true_val, .rcx);
        try self.loadIntoUnsigned(false_val, .rdx);
    }
    try self.emitEncoding(encoding.cmpRegImm(.rax, 0));
    try self.emitEncoding(encoding.cmovneRegReg(.rdx, .rcx));
    try self.storeFrom(result, .rdx);
}

pub fn emitArithCmp(self: anytype, op: *ir.Operation) !void {
    const wrapped = ArithDialect.CmpOp{ .op = op };
    const result = wrapped.getResult();
    const pred = wrapped.getPredicate() orelse return error.MissingPredicate;

    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;

    const lhs_slot = try self.slotFor(lhs);
    const type_name = lhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    const is_float = std.mem.eql(u8, type_name, "arith.f32") or std.mem.eql(u8, type_name, "arith.f64");

    if (is_float) {
        try self.loadIntoXmm(lhs, .xmm0);
        try self.loadIntoXmm(rhs, .xmm1);
        if (lhs_slot.width == 32) {
            try self.emitEncoding(encoding.ucomiss(.xmm0, .{ .reg = .xmm1 }));
        } else if (lhs_slot.width == 64) {
            try self.emitEncoding(encoding.ucomisd(.xmm0, .{ .reg = .xmm1 }));
        } else {
            return error.UnsupportedType;
        }

        switch (pred) {
            .eq => {
                try self.emitEncoding(encoding.setcc(.rax, .e));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeFrom(result, .rax);
            },
            .ne => {
                try self.emitEncoding(encoding.setcc(.rax, .ne));
                try self.emitEncoding(encoding.setcc(.rcx, .p));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.orRegReg(.rax, .rcx));
                try self.storeFrom(result, .rax);
            },
            .lt, .slt, .ult => {
                try self.emitEncoding(encoding.setcc(.rax, .b));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeFrom(result, .rax);
            },
            .le, .sle, .ule => {
                try self.emitEncoding(encoding.setcc(.rax, .be));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeFrom(result, .rax);
            },
            .gt, .sgt, .ugt => {
                try self.emitEncoding(encoding.setcc(.rax, .a));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeFrom(result, .rax);
            },
            .ge, .sge, .uge => {
                try self.emitEncoding(encoding.setcc(.rax, .ae));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeFrom(result, .rax);
            },
        }
        return;
    }

    const width = lhs_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    try emitIntCompare(self, pred, lhs, rhs, width);

    const cond = conditionForIntPredicate(pred);
    try self.emitEncoding(encoding.setcc(.rax, cond));
    try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
    try self.storeFrom(result, .rax);
}

/// Sets the flags for `cmp pred lhs, rhs` on integers of `width` bits, lhs in rax. Both
/// comparison emitters read their operands here, so a returned comparison and a branched one
/// cannot disagree.
///
/// THE PREDICATE DECIDES HOW BOTH OPERANDS ARE READ, AND THE KIND DOES NOT. An unsigned ordering
/// reads both zero extended from the width and a signed ordering reads both sign extended, the
/// literal included. The left side was once zero extended against a literal taken as written,
/// so an i8 of -1 arrived as 255 and met the immediate -1, which is 0xFFFFFFFF at 32 bits, and
/// `ult` answered true. A signed ordering once read each operand in its slot's own form, so a
/// u8 of 200 ordered above 100 where the predicate asks whether -56 does. Equality reads each
/// operand in its slot's form, which is the form `literalWord` gives a literal, and either
/// extension answers it alike.
fn emitIntCompare(self: anytype, pred: CmpPredicate, lhs: *ir.Value, rhs: *ir.Value, width: u8) !void {
    const Reading = enum { own, signed, unsigned };
    const reading: Reading = switch (pred) {
        .ult, .ule, .ugt, .uge => .unsigned,
        .lt, .le, .gt, .ge, .slt, .sle, .sgt, .sge => .signed,
        .eq, .ne => .own,
    };
    switch (reading) {
        .own => try self.loadInto(lhs, .rax),
        .signed => try self.loadIntoSigned(lhs, .rax),
        .unsigned => try self.loadIntoUnsigned(lhs, .rax),
    }

    if (constantIntI32(rhs)) |literal| {
        if (width == 64) {
            try self.emitEncoding(encoding.cmpRegImm(.rax, literal));
            return;
        }
        const imm: i32 = switch (reading) {
            .own => literal,
            .signed => @intCast(arith_scalar.truncate(literal, width)),
            .unsigned => if (width < 32) @intCast(arith_scalar.maskToBits(literal, width)) else literal,
        };
        try self.emitEncoding(encoding.cmpRegImm32(.rax, imm));
        return;
    }

    switch (reading) {
        .own => try self.loadInto(rhs, .rcx),
        .signed => try self.loadIntoSigned(rhs, .rcx),
        .unsigned => try self.loadIntoUnsigned(rhs, .rcx),
    }
    if (width == 64) {
        try self.emitEncoding(encoding.cmpRegReg(.rax, .rcx));
    } else {
        try self.emitEncoding(encoding.cmpRegReg32(.rax, .rcx));
    }
}

/// Sets the flags for one integer comparison and stores nothing, for a consumer that reads the
/// flags directly. Answers false for a floating comparison, which it leaves alone.
pub fn emitArithCmpFlags(self: anytype, op: *ir.Operation) !bool {
    const wrapped = ArithDialect.CmpOp{ .op = op };
    if (wrapped.getPredicate() == null) return error.MissingPredicate;

    const lhs = op.getOperand(0) orelse return error.MissingOperand;
    const rhs = op.getOperand(1) orelse return error.MissingOperand;
    const lhs_slot = try self.slotFor(lhs);
    const type_name = lhs.type.getDialectTypeName() orelse return error.UnsupportedType;
    const is_float = std.mem.eql(u8, type_name, "arith.f32") or std.mem.eql(u8, type_name, "arith.f64");
    if (is_float) return false;

    const width = lhs_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    try emitIntCompare(self, wrapped.getPredicate().?, lhs, rhs, width);
    return true;
}

pub fn conditionForIntPredicate(pred: CmpPredicate) Condition {
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

/// Answers whether `op` reads its operand `operand_number` as an immediate when that operand is
/// a literal that fits a sign-extended 32 bits, so the literal needs no register.
fn immediateUseSupported(op: *ir.Operation, operand_number: u32) bool {
    if (operand_number != 1) return false;
    if (takesImmediateRhs(op)) return true;
    return divisionIgnoresRhs(op);
}

/// The integer operations whose emitters take a literal right operand as an imm32.
fn takesImmediateRhs(op: *const ir.Operation) bool {
    const name = op.name.name;
    for ([_][]const u8{
        ArithDialect.AddOp.operation_name,
        ArithDialect.SubOp.operation_name,
        ArithDialect.MulOp.operation_name,
        ArithDialect.AndOp.operation_name,
        ArithDialect.OrOp.operation_name,
        ArithDialect.XorOp.operation_name,
        ArithDialect.CmpOp.operation_name,
    }) |taker| {
        if (std.mem.eql(u8, name, taker)) return true;
    }
    return false;
}

/// The literal right operand `op` takes as an imm32, when it takes one. The emitter, the
/// register allocator, and the constant that `shouldSkipArithConstant` skips all ask this.
pub fn immediateRhs(op: *ir.Operation) ?i32 {
    if (!takesImmediateRhs(op)) return null;
    const rhs = op.getOperand(1) orelse return null;
    return constantIntI32(rhs);
}

/// Answers whether `op` is a scalar signed division or remainder by a power of two, which
/// shifts and never reads its divisor.
pub fn divisionIgnoresRhs(op: *ir.Operation) bool {
    const name = op.name.name;
    if (!std.mem.eql(u8, name, ArithDialect.DivOp.operation_name) and
        !std.mem.eql(u8, name, ArithDialect.RemOp.operation_name)) return false;
    const result = op.getResult(0) orelse return false;
    const rhs = op.getOperand(1) orelse return false;
    const type_name = result.type.getDialectTypeName() orelse return false;
    if (!isIntegerScalarTypeName(type_name) or isUnsignedIntegerTypeName(type_name)) return false;
    const kind = arith.scalarKindFromTypeName(type_name) orelse return false;
    const width = arith.scalarBitWidth(kind);
    if (width != 8 and width != 16 and width != 32 and width != 64) return false;
    return powerOfTwoShift(rhs, width) != null;
}

/// The integer operations that read their operands where the allocator left them and define their
/// result in any register, rather than staging through rax and rcx.
const InPlace = enum { add, sub, mul, band, bor, bxor, shl, shr, ushr };

/// How an in-place operation reads a literal right operand: as an imm32, as a shift count, or,
/// for `and` with the low 32 bits of a 64-bit word, as a zero-extending 32-bit move.
const Literal = union(enum) { imm32: i32, count: u6, low_word };

fn inPlaceKind(op: *const ir.Operation) ?InPlace {
    const name = op.name.name;
    inline for (.{
        .{ ArithDialect.AddOp, .add },  .{ ArithDialect.SubOp, .sub }, .{ ArithDialect.MulOp, .mul },
        .{ ArithDialect.AndOp, .band }, .{ ArithDialect.OrOp, .bor },  .{ ArithDialect.XorOp, .bxor },
        .{ ArithDialect.ShlOp, .shl },  .{ ArithDialect.ShrOp, .shr }, .{ ArithDialect.UshrOp, .ushr },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0].operation_name)) return entry[1];
    }
    return null;
}

/// The width of a 32 or 64 bit integer word, the only kinds an in-place operation reads.
fn wordWidth(value: *ir.Value) ?u8 {
    const name = value.type.getDialectTypeName() orelse return null;
    for ([_][]const u8{ "arith.i32", "arith.u32" }) |word| if (std.mem.eql(u8, name, word)) return 32;
    for ([_][]const u8{ "arith.i64", "arith.u64", "arith.index" }) |word| if (std.mem.eql(u8, name, word)) return 64;
    return null;
}

/// The literal an in-place `op` reads as its right operand, or null when it reads a value.
fn rhsLiteral(op: *ir.Operation, kind: InPlace, width: u8) ?Literal {
    const rhs = op.getOperand(1) orelse return null;
    switch (kind) {
        .shl, .shr, .ushr => {
            const count = literalWord(rhs) orelse return null;
            if (count < 0 or count >= width) return null;
            return .{ .count = @intCast(count) };
        },
        .band => if (width == 64 and (literalWord(rhs) orelse 0) == 0xFFFF_FFFF) return .low_word,
        else => {},
    }
    return .{ .imm32 = immediateRhs(op) orelse return null };
}

/// Whether `op` reads its operands in place. The allocator asks this to free the operation's
/// operands and result from rax and rcx, and the emitter asks it to emit the matching code, so
/// the two never disagree. A shift places its operands only when its count is a literal below
/// the width, since a counted shift reads cl.
pub fn placesOperands(op: *ir.Operation) bool {
    const kind = inPlaceKind(op) orelse return false;
    if (op.operands.items.len != 2 or op.results.items.len != 1) return false;
    const result = op.getResult(0) orelse return false;
    const width = wordWidth(result) orelse return false;
    const type_name = result.type.getDialectTypeName().?;
    for (op.operands.items) |operand| {
        const name = operand.value.type.getDialectTypeName() orelse return false;
        if (!std.mem.eql(u8, name, type_name)) return false;
    }
    const unsigned = isUnsignedIntegerTypeName(type_name);
    return switch (kind) {
        .shl, .ushr => rhsLiteral(op, kind, width) != null,
        .shr => !unsigned and rhsLiteral(op, kind, width) != null,
        else => true,
    };
}

/// Whether the right operand of `op` is a literal an in-place emitter reads without a register.
pub fn inPlaceLiteralUse(op: *ir.Operation, operand_number: u32) bool {
    if (operand_number != 1 or !placesOperands(op)) return false;
    return rhsLiteral(op, inPlaceKind(op).?, wordWidth(op.getResult(0).?).?) != null;
}

/// Where an in-place operand lives as its operation executes.
const Source = union(enum) { reg: registers.GPR, slot: Slot };

fn sourceOf(self: anytype, value: *ir.Value) !Source {
    if (self.registerHome(value)) |home| return .{ .reg = home };
    return .{ .slot = try self.slotFor(value) };
}

fn operandOf(source: Source) encoding.GprRm {
    return switch (source) {
        .reg => |reg| .{ .reg = reg },
        .slot => |slot| .{ .mem = encoding.Mem.baseDisp(.rbp, slot.offset) },
    };
}

fn copyInto(self: anytype, dst: registers.GPR, src: Source, wide: bool) !void {
    switch (src) {
        .reg => |reg| if (reg != dst) {
            try self.emitEncoding(if (wide) encoding.movRegReg(dst, reg) else encoding.movRegReg32(dst, reg));
        },
        .slot => |slot| try self.loadSlot(slot, dst),
    }
}

/// Emits an operation `placesOperands` admits: copy the left operand into the result's home,
/// unless it is there already, and apply the right operand from its register, its slot or its
/// literal. When the home holds the right operand, a commutative operation swaps its operands,
/// and `sub` computes in rax, which the allocator keeps free of its right operand. A result
/// with no home computes in rax and settles to its slot.
fn emitInPlace(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0).?;
    const kind = inPlaceKind(op).?;
    const width = wordWidth(result).?;
    const wide = width == 64;
    const home = self.registerHomeForPhase(result, .definition);
    var dst: registers.GPR = home orelse .rax;
    var lhs = try sourceOf(self, op.getOperand(0).?);
    if (rhsLiteral(op, kind, width)) |literal| switch (literal) {
        .low_word => switch (operandOf(lhs)) {
            .reg => |reg| try self.emitEncoding(encoding.movRegReg32(dst, reg)),
            .mem => |mem| try self.emitEncoding(encoding.movRegMem32(dst, mem)),
        },
        .count => |count| {
            try copyInto(self, dst, lhs, wide);
            const shift: encoding.ShiftImm = switch (kind) {
                .shl => .shl,
                .shr => .sar,
                else => .shr,
            };
            try self.emitEncoding(encoding.shiftRegImm(shift, dst, count, wide));
        },
        .imm32 => |imm| if (kind == .mul and lhs == .reg) {
            try self.emitEncoding(encoding.imulRegRegImm(dst, lhs.reg, imm, wide));
        } else {
            try copyInto(self, dst, lhs, wide);
            try self.emitEncoding(switch (kind) {
                .add => encoding.aluRegImm(.add, dst, imm, wide),
                .sub => encoding.aluRegImm(.sub, dst, imm, wide),
                .band => encoding.aluRegImm(.and_, dst, imm, wide),
                .bor => encoding.aluRegImm(.or_, dst, imm, wide),
                .bxor => encoding.aluRegImm(.xor, dst, imm, wide),
                .mul => encoding.imulRegRegImm(dst, dst, imm, wide),
                .shl, .shr, .ushr => unreachable,
            });
        },
    } else {
        var rhs = try sourceOf(self, op.getOperand(1).?);
        const holds_rhs = rhs == .reg and rhs.reg == dst and !(lhs == .reg and lhs.reg == dst);
        if (holds_rhs and kind == .sub) {
            std.debug.assert(dst != .rax);
            dst = .rax;
        } else if (holds_rhs) {
            std.mem.swap(Source, &lhs, &rhs);
        }
        try copyInto(self, dst, lhs, wide);
        const alu: encoding.Alu = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .imul,
            .band => .and_,
            .bor => .or_,
            .bxor => .xor,
            .shl, .shr, .ushr => unreachable,
        };
        try self.emitEncoding(encoding.aluRegRm(alu, dst, operandOf(rhs), wide));
    }
    if (home != dst) try self.storeFrom(result, dst);
}

/// The literal `value` when its value by kind fits a sign-extended 32 bits.
pub fn constantIntI32(value: *ir.Value) ?i32 {
    return std.math.cast(i32, literalWord(value) orelse return null);
}

/// The value of an integer literal, read by its kind: sign extended from the kind's width for a
/// signed kind and zero extended for an unsigned one. A producer may have written the
/// attribute's raw word with bits above the width or with the other extension. The readers that
/// ask here are the immediate operands, the comparison's immediate, the power-of-two divisor,
/// the proof that a divisor is not -1, the scalar shift count proof and `memory`'s constant
/// alloca count. Scalar constants and vector splats do not ask: they mask the raw word to the
/// width where they materialize it, which leaves the same low bits.
pub fn literalWord(value: *ir.Value) ?i64 {
    const op = definingOp(value) orelse return null;
    if (!std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) return null;
    if (data.hasAttributes(op)) return null;
    const word = (ArithDialect.ConstantOp{ .op = op }).getIntValue() orelse return null;
    const type_name = value.type.getDialectTypeName() orelse return null;
    const kind = arith.scalarKindFromTypeName(type_name) orelse return null;
    const width = arith.scalarBitWidth(kind);
    if (width != 8 and width != 16 and width != 32) return word;
    if (isUnsignedIntegerTypeName(type_name)) return @intCast(arith_scalar.maskToBits(word, width));
    return arith_scalar.truncate(word, width);
}

fn definingOp(value: *ir.Value) ?*ir.Operation {
    return switch (value.kind) {
        .op_result => |info| @ptrCast(@alignCast(info.owner)),
        .block_argument => null,
    };
}

const BinaryRecorder = struct {
    lhs: *ir.Value,
    rhs: *ir.Value,
    result: *ir.Value,
    lhs_slot: Slot,
    rhs_slot: Slot,
    result_slot: Slot,
    gpr_loads: usize = 0,
    xmm_loads: usize = 0,
    gpr_stores: usize = 0,
    xmm_stores: usize = 0,
    encodings: usize = 0,
    bytes: [64]u8 = undefined,
    byte_count: usize = 0,

    pub fn slotFor(self: *BinaryRecorder, value: *ir.Value) !Slot {
        if (value == self.lhs) return self.lhs_slot;
        if (value == self.rhs) return self.rhs_slot;
        if (value == self.result) return self.result_slot;
        return error.MissingSlot;
    }

    pub fn loadSlot(self: *BinaryRecorder, slot: Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.gpr_loads += 1;
    }

    pub fn loadSlotUnsigned(self: *BinaryRecorder, slot: Slot, reg: registers.GPR) !void {
        try self.loadSlot(slot, reg);
    }

    pub fn loadSlotXmm(self: *BinaryRecorder, slot: Slot, reg: registers.XMM) !void {
        _ = slot;
        _ = reg;
        self.xmm_loads += 1;
    }

    pub fn storeSlot(self: *BinaryRecorder, slot: Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.gpr_stores += 1;
    }

    pub fn storeSlotXmm(self: *BinaryRecorder, slot: Slot, reg: registers.XMM) !void {
        _ = slot;
        _ = reg;
        self.xmm_stores += 1;
    }

    pub fn loadInto(self: *BinaryRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.loadSlot(try self.slotFor(value), reg);
    }

    pub fn loadIntoXmm(self: *BinaryRecorder, value: *ir.Value, reg: registers.XMM) !void {
        try self.loadSlotXmm(try self.slotFor(value), reg);
    }

    pub fn storeFromXmm(self: *BinaryRecorder, value: *ir.Value, reg: registers.XMM) !void {
        try self.storeSlotXmm(try self.slotFor(value), reg);
    }

    pub fn xmmHomeForPhase(self: *BinaryRecorder, value: *ir.Value, phase: anytype) ?registers.XMM {
        _ = self;
        _ = value;
        _ = phase;
        return null;
    }

    pub fn loadIntoSigned(self: *BinaryRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.loadSlot(try self.slotFor(value), reg);
    }

    pub fn loadIntoUnsigned(self: *BinaryRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.loadSlotUnsigned(try self.slotFor(value), reg);
    }

    pub fn storeFrom(self: *BinaryRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.storeSlot(try self.slotFor(value), reg);
    }

    pub fn registerHome(_: *BinaryRecorder, _: *ir.Value) ?registers.GPR {
        return null;
    }

    pub fn registerHomeForPhase(_: *BinaryRecorder, _: *ir.Value, _: anytype) ?registers.GPR {
        return null;
    }

    pub fn emitEncoding(self: *BinaryRecorder, enc: encoding.Encoding) !void {
        try std.testing.expect(enc.len > 0);
        try std.testing.expect(self.byte_count + enc.len <= self.bytes.len);
        @memcpy(self.bytes[self.byte_count..][0..enc.len], enc.slice());
        self.byte_count += enc.len;
        self.encodings += 1;
    }

    fn emitted(self: *const BinaryRecorder) []const u8 {
        return self.bytes[0..self.byte_count];
    }
};

/// The bytes a guard against a shift count at or past `width` emits: `cmp ecx, width` (or
/// `cmp rcx, 64`), `jb` past the trap, and `ud2`.
pub fn shiftGuardBytes(comptime width: u8) []const u8 {
    const compare: []const u8 = if (width == 64)
        &.{ 0x48, 0x83, 0xF9, width }
    else
        &.{ 0x83, 0xF9, width };
    return compare ++ &[_]u8{ 0x0F, 0x82, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x0B };
}

/// The bytes a guard against `MIN / -1` at 8 or 16 bits emits: `cmp ecx, -1`, `jne` past the
/// rest, `cmp eax, MIN`, `jne` past the trap, and `ud2`.
pub fn quotientGuardBytes(comptime width: u8) []const u8 {
    const is_min: []const u8 = if (width == 8)
        &.{ 0x83, 0xF8, 0x80 }
    else
        &.{ 0x81, 0xF8, 0x00, 0x80, 0xFF, 0xFF };
    return &[_]u8{ 0x83, 0xF9, 0xFF, 0x0F, 0x85, @intCast(is_min.len + 8), 0x00, 0x00, 0x00 } ++
        is_min ++ &[_]u8{ 0x0F, 0x85, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x0B };
}

/// How a test's operand is defined: a literal, a mask of a non-literal by a literal, or
/// neither, which a sum of two literals stands in for.
const Operand = union(enum) { literal: i64, mask: i64, opaque_ };

fn testOperand(ctx: *ir.Context, typ: ir.Type, operand: Operand) !*ir.Value {
    const loc = ir.Location.getUnknown();
    if (operand == .literal) {
        return (try ArithDialect.ConstantOp.createInt(ctx, loc, typ, operand.literal)).getResult();
    }
    const one = try ArithDialect.ConstantOp.createInt(ctx, loc, typ, 1);
    const sum = try ArithDialect.AddOp.create(ctx, loc, one.getResult(), one.getResult());
    if (operand == .opaque_) return sum.getResult();
    const mask = try ArithDialect.ConstantOp.createInt(ctx, loc, typ, operand.mask);
    return (try ArithDialect.AndOp.create(ctx, loc, sum.getResult(), mask.getResult())).getResult();
}

/// Emits `kind` on operands of `scalar` defined as `lhs` and `rhs`, and returns its recorder.
fn recordIntOp(
    ctx: *ir.Context,
    scalar: ArithDialect.ScalarTypeKind,
    comptime Op: type,
    lhs_operand: Operand,
    rhs_operand: Operand,
) !BinaryRecorder {
    const loc = ir.Location.getUnknown();
    const typ = try ArithDialect.getScalarType(ctx, scalar);
    const lhs = try testOperand(ctx, typ, lhs_operand);
    const rhs = try testOperand(ctx, typ, rhs_operand);
    const op = try Op.create(ctx, loc, lhs, rhs);
    const width: u8 = @intCast(arith.types.scalarBitWidth(scalar));
    const unsigned = arith.scalarKindIsUnsignedInteger(scalar);
    const ext: slot_layout.IntExtension = if (unsigned) .unsigned else .signed;
    var recorder = BinaryRecorder{
        .lhs = lhs,
        .rhs = rhs,
        .result = op.getResult(),
        .lhs_slot = .{ .offset = -8, .width = width, .ext = ext },
        .rhs_slot = .{ .offset = -16, .width = width, .ext = ext },
        .result_slot = .{ .offset = -24, .width = width, .ext = ext },
    };
    if (Op == ArithDialect.DivOp) {
        try emitBinaryIntOp(&recorder, op.op, .div);
    } else if (Op == ArithDialect.RemOp) {
        try emitBinaryIntOp(&recorder, op.op, .rem);
    } else if (Op == ArithDialect.ShlOp) {
        try emitArithShift(&recorder, op.op, .shl);
    } else if (Op == ArithDialect.ShrOp) {
        try emitArithShift(&recorder, op.op, .shr);
    } else {
        comptime std.debug.assert(Op == ArithDialect.UshrOp);
        try emitArithShift(&recorder, op.op, .ushr);
    }
    return recorder;
}
