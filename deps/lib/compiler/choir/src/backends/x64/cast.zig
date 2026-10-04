const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const encoding = @import("encoding.zig");
const labels = @import("labels.zig");
const registers = @import("registers/root.zig");
const slot_layout = @import("slots.zig");

const ArithDialect = dialects.arith.ArithDialect;

pub const Kind = enum {
    bool_,
    i8_,
    u8_,
    i16_,
    i32_,
    u32_,
    i64_,
    u64_,
    index_,
    f32_,
    f64_,

    pub fn fromTypeName(name: []const u8) ?Kind {
        const scalar_kind = dialects.arith.scalarKindFromTypeName(name) orelse return null;
        return switch (scalar_kind) {
            .bool => .bool_,
            .i8 => .i8_,
            .u8 => .u8_,
            .i16 => .i16_,
            .i32 => .i32_,
            .u32 => .u32_,
            .i64 => .i64_,
            .u64 => .u64_,
            .index => .index_,
            .f32 => .f32_,
            .f64 => .f64_,
            .u16, .f16, .bf16 => null,
        };
    }

    pub fn isFloat(self: Kind) bool {
        return self == .f32_ or self == .f64_;
    }

    pub fn isSignedInt(self: Kind) bool {
        return switch (self) {
            .i8_, .i16_, .i32_, .i64_ => true,
            else => false,
        };
    }

    pub fn isUnsigned64Int(self: Kind) bool {
        return self == .u64_ or self == .index_;
    }

    pub fn isUnsigned32Int(self: Kind) bool {
        return self == .u32_;
    }

    pub fn intBits(self: Kind) u8 {
        return switch (self) {
            .i8_, .u8_ => 8,
            .i16_ => 16,
            .i32_ => 32,
            .u32_ => 32,
            .i64_ => 64,
            .u64_ => 64,
            .index_ => 64,
            else => 0,
        };
    }
};

pub fn emitCast(emitter: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const operand = op.getOperand(0) orelse return error.MissingOperand;

    const result_slot = try emitter.slotFor(result);
    const operand_slot = try emitter.slotFor(operand);

    const result_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const operand_name = operand.type.getDialectTypeName() orelse return error.UnsupportedType;

    const result_kind = Kind.fromTypeName(result_name) orelse return error.UnsupportedType;
    const operand_kind = Kind.fromTypeName(operand_name) orelse return error.UnsupportedType;

    if (result_kind == operand_kind) {
        if (result_kind.isFloat()) {
            try emitter.loadSlotXmm(operand_slot, .xmm0);
            try emitter.storeSlotXmm(result_slot, .xmm0);
        } else {
            try emitter.loadInto(operand, .rax);
            try emitter.storeFrom(result, .rax);
        }
        return;
    }

    if (operand_kind == .bool_ and result_kind != .bool_) {
        if (result_kind.isFloat()) {
            try emitter.loadInto(operand, .rax);
            switch (result_kind) {
                .f32_ => try emitter.emitEncoding(encoding.cvtsi2ssReg64(.xmm0, .rax)),
                .f64_ => try emitter.emitEncoding(encoding.cvtsi2sdReg64(.xmm0, .rax)),
                else => unreachable,
            }
            try emitter.storeSlotXmm(result_slot, .xmm0);
        } else {
            try emitter.loadIntoUnsigned(operand, .rax);
            try emitter.storeFrom(result, .rax);
        }
        return;
    }

    if (result_kind == .bool_ and operand_kind != .bool_) {
        if (operand_kind.isFloat()) {
            try emitter.loadSlotXmm(operand_slot, .xmm0);
            try emitter.emitEncoding(encoding.xorps(.xmm1, .{ .reg = .xmm1 }));
            if (operand_kind == .f32_) {
                try emitter.emitEncoding(encoding.ucomiss(.xmm0, .{ .reg = .xmm1 }));
            } else {
                try emitter.emitEncoding(encoding.ucomisd(.xmm0, .{ .reg = .xmm1 }));
            }
            try emitter.emitEncoding(encoding.setcc(.rax, .np));
            try emitter.emitEncoding(encoding.setcc(.rcx, .ne));
            try emitter.emitEncoding(encoding.andRegReg(.rax, .rcx));
            try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
        } else {
            try emitter.loadIntoUnsigned(operand, .rax);
            try emitter.emitEncoding(encoding.cmpRegImm(.rax, 0));
            try emitter.emitEncoding(encoding.setcc(.rax, .ne));
            try emitter.emitEncoding(encoding.movzxReg8(.rax, .rax));
        }
        try emitter.storeFrom(result, .rax);
        return;
    }

    if (!result_kind.isFloat() and !operand_kind.isFloat()) {
        const operand_signed = operand_kind.isSignedInt();
        const result_bits = result_kind.intBits();
        const operand_bits = operand_kind.intBits();

        if (operand_kind == .i32_ and (result_kind == .i64_ or result_kind.isUnsigned64Int())) {
            try emitter.loadInto(operand, .rax);
            try emitter.emitEncoding(encoding.movsxdRegReg(.rax, .rax));
            try emitter.storeFrom(result, .rax);
            return;
        }

        if (operand_signed) {
            try emitter.loadInto(operand, .rax);
        } else {
            try emitter.loadIntoUnsigned(operand, .rax);
        }

        _ = result_bits;
        _ = operand_bits;
        try emitter.storeFrom(result, .rax);
        return;
    }

    if (result_kind.isFloat() and operand_kind.isFloat()) {
        try emitter.loadSlotXmm(operand_slot, .xmm0);
        if (operand_kind == .f32_ and result_kind == .f64_) {
            try emitter.emitEncoding(encoding.cvtss2sd(.xmm0, .{ .reg = .xmm0 }));
        } else if (operand_kind == .f64_ and result_kind == .f32_) {
            try emitter.emitEncoding(encoding.cvtsd2ss(.xmm0, .{ .reg = .xmm0 }));
        } else {
            return error.UnsupportedType;
        }
        try emitter.storeSlotXmm(result_slot, .xmm0);
        return;
    }

    if (result_kind.isFloat() and !operand_kind.isFloat()) {
        const operand_bits = operand_kind.intBits();
        if (operand_kind.isSignedInt()) {
            try emitter.loadSlot(operand_slot, .rax);
        } else {
            try emitter.loadSlotUnsigned(operand_slot, .rax);
        }

        if (operand_kind.isUnsigned64Int()) {
            var high_label = labels.Label{};
            defer high_label.deinit(emitter.allocator);
            var done_label = labels.Label{};
            defer done_label.deinit(emitter.allocator);

            try emitter.emitEncoding(encoding.cmpRegImm(.rax, 0));
            try emitter.emitJccLabel(.s, &high_label);

            switch (result_kind) {
                .f32_ => try emitter.emitEncoding(encoding.cvtsi2ssReg64(.xmm0, .rax)),
                .f64_ => try emitter.emitEncoding(encoding.cvtsi2sdReg64(.xmm0, .rax)),
                else => unreachable,
            }
            try emitter.emitJmpLabel(&done_label);

            try emitter.bindLabel(&high_label);
            try emitter.emitEncoding(encoding.movRegReg(.rcx, .rax));
            try emitter.emitEncoding(encoding.shrRegImm(.rcx, 1));
            try emitter.emitEncoding(encoding.andRegImm(.rax, 1));
            try emitter.emitEncoding(encoding.orRegReg(.rcx, .rax));
            switch (result_kind) {
                .f32_ => {
                    try emitter.emitEncoding(encoding.cvtsi2ssReg64(.xmm0, .rcx));
                    try emitter.emitEncoding(encoding.addss(.xmm0, .{ .reg = .xmm0 }));
                },
                .f64_ => {
                    try emitter.emitEncoding(encoding.cvtsi2sdReg64(.xmm0, .rcx));
                    try emitter.emitEncoding(encoding.addsd(.xmm0, .{ .reg = .xmm0 }));
                },
                else => unreachable,
            }

            try emitter.bindLabel(&done_label);
            try emitter.storeSlotXmm(result_slot, .xmm0);
            return;
        }

        switch (result_kind) {
            .f32_ => {
                if (operand_bits <= 32 and operand_kind.isSignedInt()) {
                    try emitter.emitEncoding(encoding.cvtsi2ssReg32(.xmm0, .rax));
                } else {
                    try emitter.emitEncoding(encoding.cvtsi2ssReg64(.xmm0, .rax));
                }
            },
            .f64_ => {
                if (operand_bits <= 32 and operand_kind.isSignedInt()) {
                    try emitter.emitEncoding(encoding.cvtsi2sdReg32(.xmm0, .rax));
                } else {
                    try emitter.emitEncoding(encoding.cvtsi2sdReg64(.xmm0, .rax));
                }
            },
            else => unreachable,
        }
        try emitter.storeSlotXmm(result_slot, .xmm0);
        return;
    }

    if (operand_kind.isFloat() and !result_kind.isFloat()) {
        try emitter.loadSlotXmm(operand_slot, .xmm0);

        if (result_kind.isUnsigned32Int()) {
            var low_label = labels.Label{};
            defer low_label.deinit(emitter.allocator);
            var done_label = labels.Label{};
            defer done_label.deinit(emitter.allocator);

            switch (operand_kind) {
                .f32_ => {
                    try emitter.emitEncoding(encoding.movRegImm64(.rcx, 0x4F000000));
                    try emitter.emitEncoding(encoding.movdXmmFromReg32(.xmm1, .rcx));
                    try emitter.emitEncoding(encoding.ucomiss(.xmm0, .{ .reg = .xmm1 }));
                },
                .f64_ => {
                    try emitter.emitEncoding(encoding.movRegImm64(.rcx, 0x41E0000000000000));
                    try emitter.emitEncoding(encoding.movqXmmFromReg64(.xmm1, .rcx));
                    try emitter.emitEncoding(encoding.ucomisd(.xmm0, .{ .reg = .xmm1 }));
                },
                else => unreachable,
            }

            try emitter.emitJccLabel(.b, &low_label);

            switch (operand_kind) {
                .f32_ => {
                    try emitter.emitEncoding(encoding.subss(.xmm0, .{ .reg = .xmm1 }));
                    try emitter.emitEncoding(encoding.cvttss2siReg32(.rax, .{ .reg = .xmm0 }));
                },
                .f64_ => {
                    try emitter.emitEncoding(encoding.subsd(.xmm0, .{ .reg = .xmm1 }));
                    try emitter.emitEncoding(encoding.cvttsd2siReg32(.rax, .{ .reg = .xmm0 }));
                },
                else => unreachable,
            }
            try emitter.emitEncoding(encoding.addRegImm(.rax, std.math.minInt(i32)));
            try emitter.emitJmpLabel(&done_label);

            try emitter.bindLabel(&low_label);
            switch (operand_kind) {
                .f32_ => try emitter.emitEncoding(encoding.cvttss2siReg32(.rax, .{ .reg = .xmm0 })),
                .f64_ => try emitter.emitEncoding(encoding.cvttsd2siReg32(.rax, .{ .reg = .xmm0 })),
                else => unreachable,
            }

            try emitter.bindLabel(&done_label);
            try emitter.storeSlot(result_slot, .rax);
            return;
        }

        if (result_kind.isUnsigned64Int()) {
            var low_label = labels.Label{};
            defer low_label.deinit(emitter.allocator);
            var done_label = labels.Label{};
            defer done_label.deinit(emitter.allocator);

            switch (operand_kind) {
                .f32_ => {
                    try emitter.emitEncoding(encoding.movRegImm64(.rcx, 0x5F000000));
                    try emitter.emitEncoding(encoding.movdXmmFromReg32(.xmm1, .rcx));
                    try emitter.emitEncoding(encoding.ucomiss(.xmm0, .{ .reg = .xmm1 }));
                },
                .f64_ => {
                    try emitter.emitEncoding(encoding.movRegImm64(.rcx, 0x43E0000000000000));
                    try emitter.emitEncoding(encoding.movqXmmFromReg64(.xmm1, .rcx));
                    try emitter.emitEncoding(encoding.ucomisd(.xmm0, .{ .reg = .xmm1 }));
                },
                else => unreachable,
            }

            try emitter.emitJccLabel(.b, &low_label);

            switch (operand_kind) {
                .f32_ => {
                    try emitter.emitEncoding(encoding.subss(.xmm0, .{ .reg = .xmm1 }));
                    try emitter.emitEncoding(encoding.cvttss2siReg64(.rax, .{ .reg = .xmm0 }));
                },
                .f64_ => {
                    try emitter.emitEncoding(encoding.subsd(.xmm0, .{ .reg = .xmm1 }));
                    try emitter.emitEncoding(encoding.cvttsd2siReg64(.rax, .{ .reg = .xmm0 }));
                },
                else => unreachable,
            }
            try emitter.emitEncoding(encoding.movRegImm64(.rcx, 0x8000000000000000));
            try emitter.emitEncoding(encoding.addRegReg(.rax, .rcx));
            try emitter.emitJmpLabel(&done_label);

            try emitter.bindLabel(&low_label);
            switch (operand_kind) {
                .f32_ => try emitter.emitEncoding(encoding.cvttss2siReg64(.rax, .{ .reg = .xmm0 })),
                .f64_ => try emitter.emitEncoding(encoding.cvttsd2siReg64(.rax, .{ .reg = .xmm0 })),
                else => unreachable,
            }

            try emitter.bindLabel(&done_label);
            try emitter.storeSlot(result_slot, .rax);
            return;
        }

        const result_bits = result_kind.intBits();
        switch (operand_kind) {
            .f32_ => {
                if (result_bits <= 32) {
                    try emitter.emitEncoding(encoding.cvttss2siReg32(.rax, .{ .reg = .xmm0 }));
                } else {
                    try emitter.emitEncoding(encoding.cvttss2siReg64(.rax, .{ .reg = .xmm0 }));
                }
            },
            .f64_ => {
                if (result_bits <= 32) {
                    try emitter.emitEncoding(encoding.cvttsd2siReg32(.rax, .{ .reg = .xmm0 }));
                } else {
                    try emitter.emitEncoding(encoding.cvttsd2siReg64(.rax, .{ .reg = .xmm0 }));
                }
            },
            else => unreachable,
        }
        try emitter.storeSlot(result_slot, .rax);
        return;
    }

    return error.UnsupportedType;
}

pub fn emitBitcast(emitter: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.MissingResult;
    const operand = op.getOperand(0) orelse return error.MissingOperand;

    const result_slot = try emitter.slotFor(result);
    const operand_slot = try emitter.slotFor(operand);

    const result_name = result.type.getDialectTypeName() orelse return error.UnsupportedType;
    const operand_name = operand.type.getDialectTypeName() orelse return error.UnsupportedType;

    const result_kind = Kind.fromTypeName(result_name) orelse return error.UnsupportedType;
    const operand_kind = Kind.fromTypeName(operand_name) orelse return error.UnsupportedType;
    if (result_kind == .bool_ or operand_kind == .bool_) return error.UnsupportedType;
    if (result_kind == .index_ or operand_kind == .index_) return error.UnsupportedType;

    if (std.mem.eql(u8, result_name, "arith.f16") or
        std.mem.eql(u8, result_name, "arith.bf16") or
        std.mem.eql(u8, operand_name, "arith.f16") or
        std.mem.eql(u8, operand_name, "arith.bf16")) return error.UnsupportedType;

    if (result_slot.width != operand_slot.width) return error.UnsupportedType;

    if (operand_kind.isFloat()) {
        if (emitter.xmmHome(operand)) |home| {
            if (operand_slot.width == 32) {
                try emitter.emitEncoding(encoding.movdReg32FromXmm(.rax, home));
            } else {
                try emitter.emitEncoding(encoding.movqReg64FromXmm(.rax, home));
            }
        } else {
            try emitter.loadSlotUnsigned(operand_slot, .rax);
        }
    } else {
        try emitter.loadIntoUnsigned(operand, .rax);
    }

    if (result_kind.isFloat()) {
        if (emitter.xmmHomeForPhase(result, .definition)) |home| {
            if (result_slot.width == 32) {
                try emitter.emitEncoding(encoding.movdXmmFromReg32(home, .rax));
            } else {
                try emitter.emitEncoding(encoding.movqXmmFromReg64(home, .rax));
            }
        } else {
            try emitter.storeSlot(result_slot, .rax);
        }
    } else {
        try emitter.storeFrom(result, .rax);
    }
}

const CopyRecorder = struct {
    allocator: std.mem.Allocator,
    input: *ir.Value,
    result: *ir.Value,
    input_slot: slot_layout.Slot,
    result_slot: slot_layout.Slot,
    loads: usize = 0,
    stores: usize = 0,

    pub fn slotFor(self: *CopyRecorder, value: *ir.Value) !slot_layout.Slot {
        if (value == self.input) return self.input_slot;
        if (value == self.result) return self.result_slot;
        return error.MissingSlot;
    }

    pub fn loadSlot(self: *CopyRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.loads += 1;
    }

    pub fn loadSlotUnsigned(self: *CopyRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        try self.loadSlot(slot, reg);
    }

    pub fn loadInto(self: *CopyRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.loadSlot(try self.slotFor(value), reg);
    }

    pub fn loadIntoUnsigned(self: *CopyRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.loadSlot(try self.slotFor(value), reg);
    }

    pub fn storeFrom(self: *CopyRecorder, value: *ir.Value, reg: registers.GPR) !void {
        try self.storeSlot(try self.slotFor(value), reg);
    }

    pub fn loadSlotXmm(self: *CopyRecorder, slot: slot_layout.Slot, reg: registers.XMM) !void {
        _ = slot;
        _ = reg;
        self.loads += 1;
    }

    pub fn storeSlot(self: *CopyRecorder, slot: slot_layout.Slot, reg: registers.GPR) !void {
        _ = slot;
        _ = reg;
        self.stores += 1;
    }

    pub fn storeSlotXmm(self: *CopyRecorder, slot: slot_layout.Slot, reg: registers.XMM) !void {
        _ = slot;
        _ = reg;
        self.stores += 1;
    }

    pub fn emitEncoding(_: *CopyRecorder, _: encoding.Encoding) !void {}

    pub fn emitJccLabel(_: *CopyRecorder, _: encoding.Condition, _: *labels.Label) !void {}

    pub fn emitJmpLabel(_: *CopyRecorder, _: *labels.Label) !void {}

    pub fn bindLabel(_: *CopyRecorder, _: *labels.Label) !void {}
};

test "x86_64 cast owner emits integer identity copy" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try @import("../../dialects/root.zig").registerAllDialects(&ctx);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    var constant = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 7);
    var cast = try ArithDialect.CastOp.create(&ctx, loc, constant.getResult(), i32_type);

    var recorder = CopyRecorder{
        .allocator = std.testing.allocator,
        .input = constant.getResult(),
        .result = cast.getResult(),
        .input_slot = .{ .offset = -8, .width = 32, .ext = .signed },
        .result_slot = .{ .offset = -16, .width = 32, .ext = .signed },
    };

    try emitCast(&recorder, cast.op);

    try std.testing.expectEqual(@as(usize, 1), recorder.loads);
    try std.testing.expectEqual(@as(usize, 1), recorder.stores);
}

test "x86_64 cast owner classifies scalar types" {
    try std.testing.expectEqual(Kind.i64_, Kind.fromTypeName("arith.i64").?);
    try std.testing.expectEqual(Kind.u32_, Kind.fromTypeName("arith.u32").?);
    try std.testing.expectEqual(Kind.u64_, Kind.fromTypeName("arith.u64").?);
    try std.testing.expectEqual(Kind.f32_, Kind.fromTypeName("arith.f32").?);
    try std.testing.expect(Kind.fromTypeName("arith.vec4xf32") == null);
}
