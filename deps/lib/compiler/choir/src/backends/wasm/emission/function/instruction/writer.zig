const std = @import("std");
const wasm = @import("../../../root.zig");
const ir = @import("../../../../../core/root.zig");
const dialects = @import("../../../../../dialects/root.zig");
const emission = @import("../../root.zig");
const instruction = @import("root.zig");

const ArithDialect = dialects.ArithDialect;
const FuncDialect = dialects.FuncDialect;
const MemrefDialect = dialects.MemrefDialect;

pub fn Writer(comptime Out: type) type {
    return struct {
        out: Out,
        plan: *const emission.Plan,
        function_ordinal: usize,

        const Self = @This();

        pub fn writeOperation(self: *Self, operation: *ir.Operation) emission.Error!void {
            const name = operation.name.name;
            if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name)) {
                return instruction.arithmetic.lowering.writeConstant(Out, self, operation);
            }
            if (std.mem.eql(u8, name, ArithDialect.AddOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .add);
            }
            if (std.mem.eql(u8, name, ArithDialect.SubOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .sub);
            }
            if (std.mem.eql(u8, name, ArithDialect.MulOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .mul);
            }
            if (std.mem.eql(u8, name, ArithDialect.DivOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .div);
            }
            if (std.mem.eql(u8, name, ArithDialect.RemOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .rem);
            }
            if (std.mem.eql(u8, name, ArithDialect.AndOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .band);
            }
            if (std.mem.eql(u8, name, ArithDialect.OrOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .bor);
            }
            if (std.mem.eql(u8, name, ArithDialect.XorOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .bxor);
            }
            if (std.mem.eql(u8, name, ArithDialect.ShlOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .shl);
            }
            if (std.mem.eql(u8, name, ArithDialect.ShrOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .shr);
            }
            if (std.mem.eql(u8, name, ArithDialect.UshrOp.operation_name)) {
                return instruction.arithmetic.lowering.writeBinary(Out, self, operation, .ushr);
            }
            if (std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name)) {
                return instruction.arithmetic.lowering.writeCmp(Out, self, operation);
            }
            if (std.mem.eql(u8, name, ArithDialect.SelectOp.operation_name)) {
                return instruction.arithmetic.lowering.writeSelect(Out, self, operation);
            }
            if (std.mem.eql(u8, name, ArithDialect.NegOp.operation_name)) {
                return instruction.arithmetic.lowering.writeNeg(Out, self, operation);
            }
            if (std.mem.eql(u8, name, ArithDialect.AbsOp.operation_name)) {
                return instruction.arithmetic.lowering.writeAbs(Out, self, operation);
            }
            if (std.mem.eql(u8, name, ArithDialect.SqrtOp.operation_name)) {
                return instruction.arithmetic.lowering.writeSqrt(Out, self, operation);
            }
            if (std.mem.eql(u8, name, ArithDialect.BitcastOp.operation_name)) {
                return instruction.cast.write(Out, self, operation, true);
            }
            if (std.mem.eql(u8, name, ArithDialect.CastOp.operation_name)) {
                return instruction.cast.write(Out, self, operation, false);
            }
            if (std.mem.eql(u8, name, FuncDialect.CallOp.operation_name)) {
                return instruction.call.write(Out, self, operation);
            }
            if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) {
                return instruction.memory.writeLoad(Out, self, operation);
            }
            if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
                return instruction.memory.writeStore(Out, self, operation);
            }
            inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
                if (std.mem.eql(u8, name, Op.operation_name)) return error.UnsupportedOperation;
            }
            return error.CodeGenFailed;
        }

        pub fn writeValue(self: *Self, value: *ir.Value) emission.Error!void {
            try self.writeLocalGet(try self.localFor(value));
        }

        pub fn writeLocalGet(self: *Self, local: u32) emission.Error!void {
            try self.out.writeByte(0x20);
            try wasm.binary.writeUleb(self.out, local);
        }

        pub fn writeLocalSet(self: *Self, local: u32) emission.Error!void {
            try self.out.writeByte(0x21);
            try wasm.binary.writeUleb(self.out, local);
        }

        pub fn localFor(self: *const Self, value: *ir.Value) emission.Error!u32 {
            return self.plan.localFor(self.function_ordinal, value) orelse
                error.CodeGenFailed;
        }
    };
}
