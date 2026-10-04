const std = @import("std");
const dialects = @import("../../dialects/root.zig");

pub const Status = enum { admitted, deferred };
pub const Unit = enum { scalar, floating, vectors, memory, atomics, calls, syscalls, control, conversions };
pub const Entry = struct { name: []const u8, status: Status, unit: Unit };

/// Control legality: scalar integer/index/bool/f64 results and carried values;
/// bool conditions; index for bounds/induction; one block per region and
/// type/arity-matched terminal yields or while-before condition. If without
/// else requires zero results. While input/before/after/result types agree.
/// Limits and shape validation are owned by control.zig.
/// Dispatch inventory from the parity review, qualified by scalar type legality.
pub const operations = [_]Entry{
    .{ .name = dialects.ArithDialect.AbsOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.AddOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.AddoOp.operation_name, .status = .deferred, .unit = .scalar },
    .{ .name = dialects.ArithDialect.AndOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.BitcastOp.operation_name, .status = .admitted, .unit = .conversions },
    .{ .name = dialects.ArithDialect.CastOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.CmpOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ConstantOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.CosOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.DivOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ExpOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.ExtractOp.operation_name, .status = .deferred, .unit = .vectors },
    .{ .name = dialects.ArithDialect.FloorOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.FmaOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.InsertOp.operation_name, .status = .deferred, .unit = .vectors },
    .{ .name = dialects.ArithDialect.LogOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.MaxOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.MinOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.MulOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.MuloOp.operation_name, .status = .deferred, .unit = .scalar },
    .{ .name = dialects.ArithDialect.NegOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.NotOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.OrOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.PopCountOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.PowOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.RemOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.SelectOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ShlOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ShrOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.SinOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.SplatOp.operation_name, .status = .deferred, .unit = .vectors },
    .{ .name = dialects.ArithDialect.SqrtOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.SubOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.SuboOp.operation_name, .status = .deferred, .unit = .scalar },
    .{ .name = dialects.ArithDialect.TanOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.TanhOp.operation_name, .status = .deferred, .unit = .floating },
    .{ .name = dialects.ArithDialect.UmulhiOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.UshrOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.VecCmpOp.operation_name, .status = .deferred, .unit = .vectors },
    .{ .name = dialects.ArithDialect.VecConstantOp.operation_name, .status = .deferred, .unit = .vectors },
    .{ .name = dialects.ArithDialect.VecShuffleOp.operation_name, .status = .deferred, .unit = .vectors },
    .{ .name = dialects.ArithDialect.XorOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.FuncDialect.CallOp.operation_name, .status = .admitted, .unit = .calls },
    .{ .name = dialects.FuncDialect.ReturnOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.FuncDialect.SyscallOp.operation_name, .status = .deferred, .unit = .syscalls },
    .{ .name = dialects.MemrefDialect.AllocOp.operation_name, .status = .deferred, .unit = .memory },
    .{ .name = dialects.MemrefDialect.AllocaOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.MemrefDialect.AtomicCasOp.operation_name, .status = .deferred, .unit = .atomics },
    .{ .name = dialects.MemrefDialect.AtomicLoadOp.operation_name, .status = .deferred, .unit = .atomics },
    .{ .name = dialects.MemrefDialect.AtomicStoreOp.operation_name, .status = .deferred, .unit = .atomics },
    .{ .name = dialects.MemrefDialect.DeallocOp.operation_name, .status = .deferred, .unit = .memory },
    .{ .name = dialects.MemrefDialect.FenceOp.operation_name, .status = .deferred, .unit = .atomics },
    .{ .name = dialects.MemrefDialect.GetGlobalOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.MemrefDialect.LoadOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.MemrefDialect.StoreOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.MemrefDialect.ViewOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.ScfDialect.ConditionOp.operation_name, .status = .admitted, .unit = .control },
    .{ .name = dialects.ScfDialect.ForOp.operation_name, .status = .admitted, .unit = .control },
    .{ .name = dialects.ScfDialect.IfOp.operation_name, .status = .admitted, .unit = .control },
    .{ .name = dialects.ScfDialect.WhileOp.operation_name, .status = .admitted, .unit = .control },
    .{ .name = dialects.ScfDialect.YieldOp.operation_name, .status = .admitted, .unit = .control },
};

pub fn lookup(name: []const u8) ?Entry {
    for (operations) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
    }
    return null;
}

test "aarch64 admission inventory has 61 unique dispatch names" {
    try std.testing.expectEqual(@as(usize, 61), operations.len);
    for (operations, 0..) |entry, index| {
        for (operations[0..index]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, entry.name, previous.name));
        }
    }
}
