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

    if (std.mem.eql(u8, type_name, "arith.bool")) {
        const bool_attr = op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse return error.InvalidConstant;
        const bool_val = bool_attr.getValue();
        const imm: u64 = if (bool_val) 1 else 0;
        try self.emitEncoding(encoding.movRegImm64(.rax, imm));
        try self.storeFrom(result, .rax);
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
        if (slot.width <= 32) {
            try self.emitEncoding(encoding.movRegImm32(.rax, @intCast(masked)));
        } else {
            try self.emitEncoding(encoding.movRegImm64(.rax, masked));
        }
        try self.storeFrom(result, .rax);
        return;
    }

    if (const_op.getFloatValue()) |float_val| {
        if (slot.width == 32) {
            const bits: u32 = @bitCast(@as(f32, @floatCast(float_val)));
            try self.emitEncoding(encoding.movRegImm32(.rax, bits));
        } else if (slot.width == 64) {
            const bits: u64 = @bitCast(float_val);
            try self.emitEncoding(encoding.movRegImm64(.rax, bits));
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

pub fn shouldSkipArithConstant(op: *ir.Operation) bool {
    const result = op.getResult(0) orelse return false;
    if (constantIntI32(result) == null) return false;

    var use = result.first_use;
    while (use) |operand| {
        const user: *ir.Operation = @ptrCast(@alignCast(operand.owner));
        if (!immediateUseSupported(user, operand.operand_number)) return false;
        use = operand.next_use;
    }
    return true;
}

pub fn emitBinaryIntOp(self: anytype, op: *ir.Operation, kind: BinOp) !void {
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

    if (kind == .sub) {
        if (constantIntI32(rhs)) |imm| {
            try self.loadInto(lhs, .rax);
            if (op_width == 32) {
                try self.emitEncoding(encoding.subRegImm32(.rax, imm));
            } else {
                try self.emitEncoding(encoding.subRegImm(.rax, imm));
            }
            try self.storeFrom(result, .rax);
            return;
        }
    }

    try self.loadInto(lhs, .rax);
    try self.loadInto(rhs, .rcx);

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

pub const LibmUnaryKind = enum { sin, cos, tan, exp, log, tanh, floor };
pub const LibmBinaryKind = enum { pow };
const LibmTernaryKind = enum { fma };

fn libmUnaryCallee(kind: LibmUnaryKind, is_f32: bool) []const u8 {
    return switch (kind) {
        .sin => if (is_f32) "sinf" else "sin",
        .cos => if (is_f32) "cosf" else "cos",
        .tan => if (is_f32) "tanf" else "tan",
        .exp => if (is_f32) "expf" else "exp",
        .log => if (is_f32) "logf" else "log",
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
        try self.loadSlotXmm(true_slot, .xmm0);
        try self.loadSlotXmm(false_slot, .xmm1);
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
        try self.storeSlotXmm(result_slot, .xmm0);
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

    const result_slot = try self.slotFor(result);
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
                try self.storeSlot(result_slot, .rax);
            },
            .ne => {
                try self.emitEncoding(encoding.setcc(.rax, .ne));
                try self.emitEncoding(encoding.setcc(.rcx, .p));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.orRegReg(.rax, .rcx));
                try self.storeSlot(result_slot, .rax);
            },
            .lt, .slt, .ult => {
                try self.emitEncoding(encoding.setcc(.rax, .b));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeSlot(result_slot, .rax);
            },
            .le, .sle, .ule => {
                try self.emitEncoding(encoding.setcc(.rax, .be));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeSlot(result_slot, .rax);
            },
            .gt, .sgt, .ugt => {
                try self.emitEncoding(encoding.setcc(.rax, .a));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeSlot(result_slot, .rax);
            },
            .ge, .sge, .uge => {
                try self.emitEncoding(encoding.setcc(.rax, .ae));
                try self.emitEncoding(encoding.setcc(.rcx, .np));
                try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
                try self.emitEncoding(encoding.movzxReg8(.rcx, .rcx));
                try self.emitEncoding(encoding.andRegReg(.rax, .rcx));
                try self.storeSlot(result_slot, .rax);
            },
        }
        return;
    }

    const width = lhs_slot.width;
    if (width != 8 and width != 16 and width != 32 and width != 64) return error.UnsupportedType;

    const is_unsigned = switch (pred) {
        .ult, .ule, .ugt, .uge => true,
        else => false,
    };

    if (constantIntI32(rhs)) |imm| {
        if (is_unsigned) {
            try self.loadIntoUnsigned(lhs, .rax);
        } else {
            try self.loadInto(lhs, .rax);
        }
        if (width == 64) {
            try self.emitEncoding(encoding.cmpRegImm(.rax, imm));
        } else {
            try self.emitEncoding(encoding.cmpRegImm32(.rax, imm));
        }

        const cond = conditionForIntPredicate(pred);
        try self.emitEncoding(encoding.setcc(.rax, cond));
        try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
        try self.storeFrom(result, .rax);
        return;
    }

    if (is_unsigned) {
        try self.loadIntoUnsigned(lhs, .rax);
        try self.loadIntoUnsigned(rhs, .rcx);
    } else {
        try self.loadInto(lhs, .rax);
        try self.loadInto(rhs, .rcx);
    }

    if (width == 64) {
        try self.emitEncoding(encoding.cmpRegReg(.rax, .rcx));
    } else {
        try self.emitEncoding(encoding.cmpRegReg32(.rax, .rcx));
    }

    const cond = conditionForIntPredicate(pred);
    try self.emitEncoding(encoding.setcc(.rax, cond));
    try self.emitEncoding(encoding.movzxReg8(.rax, .rax));
    try self.storeFrom(result, .rax);
}

/// Sets the flags for one integer comparison, and DOES NOT DECIDE WHAT ITS
/// OPERANDS LOOK LIKE.
///
/// It used to. It read the extension off the PREDICATE, taking `.ult`, `.ule`,
/// `.ugt` and `.uge` as unsigned and everything else as signed, so a `u8`
/// equality took the signed reload while `constantIntI32` handed back the face
/// value, and `cmp $0xc8, %eax` met an `%eax` holding `0xFFFFFFC8`. That is
/// the comparison where the operand's form came from the instruction reading
/// it rather than from the value, so the two sides disagreed about what a byte
/// means.
///
/// Both operands now come back in the form their own slots carry, which is
/// the form the immediate is already in, so the three agree.
///
/// WHERE THE PREDICATE AND THE OPERAND TYPE DISAGREE, THE OPERAND WINS FOR
/// RELOADS. A signed predicate on unsigned operands exercises that boundary. At
/// widths 8 and 16 it costs nothing: a zero extended `u8` or
/// `u16` cannot reach the sign bit of the 32 bit comparison it is widened
/// into, so the signed comparison gives the unsigned answer anyway. At 32 and
/// 64 bits no extension happens at all and the predicate is the whole story.
/// Choosing the predicate for an unsigned comparison belongs to Yikes, not to
/// this backend.
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

    if (constantIntI32(rhs)) |imm| {
        try self.loadInto(lhs, .rax);
        if (width == 64) {
            try self.emitEncoding(encoding.cmpRegImm(.rax, imm));
        } else {
            try self.emitEncoding(encoding.cmpRegImm32(.rax, imm));
        }
        return true;
    }

    try self.loadInto(lhs, .rax);
    try self.loadInto(rhs, .rcx);

    if (width == 64) {
        try self.emitEncoding(encoding.cmpRegReg(.rax, .rcx));
    } else {
        try self.emitEncoding(encoding.cmpRegReg32(.rax, .rcx));
    }
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

fn immediateUseSupported(op: *ir.Operation, operand_number: u32) bool {
    const name = op.name.name;
    if (operand_number != 1) return false;
    if (std.mem.eql(u8, name, ArithDialect.SubOp.operation_name)) return true;
    if (std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name)) return true;
    return false;
}

pub fn constantIntI32(value: *ir.Value) ?i32 {
    const op = definingOp(value) orelse return null;
    if (!std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) return null;
    if (data.hasAttributes(op)) return null;
    const constant = ArithDialect.ConstantOp{ .op = op };
    const int_value = constant.getIntValue() orelse return null;
    return std.math.cast(i32, int_value);
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

    pub fn loadIntoUnsigned(self: *BinaryRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.loadSlotUnsigned(try self.slotFor(value), reg);
    }

    pub fn storeFrom(self: *BinaryRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.storeSlot(try self.slotFor(value), reg);
    }

    pub fn emitEncoding(self: *BinaryRecorder, enc: encoding.Encoding) !void {
        try std.testing.expect(enc.len > 0);
        self.encodings += 1;
    }
};
