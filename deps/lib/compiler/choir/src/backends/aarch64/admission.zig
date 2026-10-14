const std = @import("std");
const dialects = @import("../../dialects/root.zig");
const VectorArrangement = @import("encoding/root.zig").VectorArrangement;

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
    .{ .name = dialects.ArithDialect.AddoOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.AndOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.BitcastOp.operation_name, .status = .admitted, .unit = .conversions },
    .{ .name = dialects.ArithDialect.CastOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.CmpOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ConstantOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.CosOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.DivOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ExpOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.Expm1Op.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.ExtractOp.operation_name, .status = .admitted, .unit = .vectors },
    .{ .name = dialects.ArithDialect.FloorOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.FmaOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.InsertOp.operation_name, .status = .admitted, .unit = .vectors },
    .{ .name = dialects.ArithDialect.LogOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.Log1pOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.MaxOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.MinOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.MulOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.MuloOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.NegOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.NotOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.OrOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.PopCountOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.PowOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.RemOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.SelectOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ShlOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.ShrOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.SinOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.SplatOp.operation_name, .status = .admitted, .unit = .vectors },
    .{ .name = dialects.ArithDialect.SqrtOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.SubOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.SuboOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.TanOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.TanhOp.operation_name, .status = .admitted, .unit = .floating },
    .{ .name = dialects.ArithDialect.UmulhiOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.UshrOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.ArithDialect.VecCmpOp.operation_name, .status = .admitted, .unit = .vectors },
    .{ .name = dialects.ArithDialect.VecConstantOp.operation_name, .status = .admitted, .unit = .vectors },
    .{ .name = dialects.ArithDialect.VecShuffleOp.operation_name, .status = .admitted, .unit = .vectors },
    .{ .name = dialects.ArithDialect.XorOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.FuncDialect.CallOp.operation_name, .status = .admitted, .unit = .calls },
    .{ .name = dialects.FuncDialect.ReturnOp.operation_name, .status = .admitted, .unit = .scalar },
    .{ .name = dialects.FuncDialect.SyscallOp.operation_name, .status = .deferred, .unit = .syscalls },
    .{ .name = dialects.MemrefDialect.AllocOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.MemrefDialect.AllocaOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.MemrefDialect.AtomicCasOp.operation_name, .status = .admitted, .unit = .atomics },
    .{ .name = dialects.MemrefDialect.AtomicLoadOp.operation_name, .status = .admitted, .unit = .atomics },
    .{ .name = dialects.MemrefDialect.AtomicStoreOp.operation_name, .status = .admitted, .unit = .atomics },
    .{ .name = dialects.MemrefDialect.DeallocOp.operation_name, .status = .admitted, .unit = .memory },
    .{ .name = dialects.MemrefDialect.FenceOp.operation_name, .status = .admitted, .unit = .atomics },
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

/// One vector type aarch64 admits: its lane type and count, and the register arrangement
/// that holds it whole.
pub const VectorShape = struct {
    name: []const u8,
    lane: dialects.arith.ScalarKind,
    arrangement: VectorArrangement,

    fn of(lanes: u32, lane: dialects.arith.ScalarKind, arrangement: VectorArrangement) VectorShape {
        std.debug.assert(arrangement.lanes() == lanes);
        std.debug.assert(arrangement.laneBits() == dialects.arith.scalarBitWidth(lane));
        return .{ .name = dialects.arith.vectorTypeName(lanes, lane).?, .lane = lane, .arrangement = arrangement };
    }
};

/// The vector types aarch64 admits, named one by one: the packed lanes Yikes's aarch64 target
/// claims. Each fits one vector register. f16, bf16 and byte lanes, wider vectors, and index
/// lanes are refused by name.
pub const vector_shapes = [_]VectorShape{
    .of(2, .f32, .@"2s"),
    .of(2, .i32, .@"2s"),
    .of(2, .u32, .@"2s"),
    .of(2, .f64, .@"2d"),
    .of(2, .i64, .@"2d"),
    .of(2, .u64, .@"2d"),
    .of(4, .f32, .@"4s"),
    .of(4, .i32, .@"4s"),
    .of(4, .u32, .@"4s"),
    .of(4, .i16, .@"4h"),
    .of(4, .u16, .@"4h"),
};

pub fn vectorShape(type_name: []const u8) ?VectorShape {
    for (vector_shapes) |shape| {
        if (std.mem.eql(u8, type_name, shape.name)) return shape;
    }
    return null;
}

pub fn lookup(name: []const u8) ?Entry {
    for (operations) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
    }
    return null;
}
