const std = @import("std");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const spirv_target = @import("../root.zig");
const gpu_target = @import("../../../../dialects/gpu/root.zig");
const dialect_writer = @import("dialect.zig");
const gpu = @import("gpu.zig");
const memory = @import("memory.zig");
const scalar = @import("scalar.zig");
const stage = @import("stage.zig");
const SpirvOp = @import("ops.zig").SpirvOp;

const GpuDialect = gpu_target.GpuDialect;
const ArithDialect = dialects.arith.ArithDialect;
const MemrefDialect = dialects.memref.MemrefDialect;
const FuncDialect = dialects.func.FuncDialect;
const ScfDialect = dialects.scf.ScfDialect;
const SpirvDialect = spirv_target.SpirvDialect;
const BuiltinKind = gpu.BuiltinKind;
const builtinLoad = stage.emitBuiltinLoad;

fn direct(comptime function: anytype) type {
    return struct {
        fn emit(
            comptime ErrorSet: type,
            comptime _: anytype,
            self: anytype,
            op: *ir.Operation,
        ) ErrorSet!void {
            return function(self, op);
        }
    };
}

fn withArg(comptime function: anytype, comptime argument: anytype) type {
    return struct {
        fn emit(
            comptime ErrorSet: type,
            comptime _: anytype,
            self: anytype,
            op: *ir.Operation,
        ) ErrorSet!void {
            return function(self, op, argument);
        }
    };
}

fn withTwoArgs(
    comptime function: anytype,
    comptime first: anytype,
    comptime second: anytype,
) type {
    return struct {
        fn emit(
            comptime ErrorSet: type,
            comptime _: anytype,
            self: anytype,
            op: *ir.Operation,
        ) ErrorSet!void {
            return function(self, op, first, second);
        }
    };
}

fn spirvBinary(
    comptime opcode: u32,
    comptime expectation: dialect_writer.SpirvBinaryExpectation,
) type {
    return withTwoArgs(dialect_writer.emitBinary, opcode, expectation);
}

fn arithBinary(comptime kind: scalar.BinaryKind) type {
    return withArg(scalar.emitBinaryArith, kind);
}

fn arithMinMax(comptime kind: scalar.MinMaxKind) type {
    return withArg(scalar.emitMinMaxArith, kind);
}

fn glslUnary(comptime opcode: u32) type {
    return withTwoArgs(scalar.emitGlslExtUnary, opcode, scalar.FloatExtConstraint.float16_or_32);
}

fn arithBitwise(comptime kind: scalar.BitwiseBinaryKind) type {
    return withArg(scalar.emitBitwiseBinary, kind);
}

fn arithShift(comptime kind: scalar.ShiftKind) type {
    return withArg(scalar.emitShiftArith, kind);
}

fn gpuIndex(comptime builtin: gpu.BuiltinKind) type {
    return withArg(gpu.emitIndex, builtin);
}

fn gpuSubgroupIndex(comptime builtin: gpu.BuiltinKind) type {
    return withArg(gpu.emitSubgroupIndex, builtin);
}

fn method(comptime name: []const u8) type {
    return struct {
        fn emit(
            comptime ErrorSet: type,
            comptime Control: anytype,
            self: anytype,
            op: *ir.Operation,
        ) ErrorSet!void {
            return @call(.auto, @field(Control, name), .{ self, op });
        }
    };
}

fn unsupportedControlFlow() type {
    return struct {
        fn emit(
            comptime ErrorSet: type,
            comptime _: anytype,
            _: anytype,
            _: *ir.Operation,
        ) ErrorSet!void {
            return error.UnsupportedControlFlow;
        }
    };
}

fn operation(comptime Operation: type, comptime Emitter: type) type {
    if (!@hasDecl(Operation, "operation_name")) @compileError("SPIR-V catalog name is missing");
    if (!@hasDecl(Emitter, "emit")) @compileError("SPIR-V catalog emitter is missing");
    return struct {
        pub const name = Operation.operation_name;

        fn emit(
            comptime ErrorSet: type,
            comptime Control: anytype,
            self: anytype,
            op: *ir.Operation,
        ) ErrorSet!void {
            return Emitter.emit(ErrorSet, Control, self, op);
        }
    };
}

pub const entries = .{
    operation(SpirvDialect.ConstantOp, direct(dialect_writer.emitConstant)),
    operation(SpirvDialect.IAddOp, spirvBinary(SpirvOp.IAdd, .int_any)),
    operation(SpirvDialect.FAddOp, spirvBinary(SpirvOp.FAdd, .float)),
    operation(SpirvDialect.ISubOp, spirvBinary(SpirvOp.ISub, .int_any)),
    operation(SpirvDialect.FSubOp, spirvBinary(SpirvOp.FSub, .float)),
    operation(SpirvDialect.IMulOp, spirvBinary(SpirvOp.IMul, .int_any)),
    operation(SpirvDialect.FMulOp, spirvBinary(SpirvOp.FMul, .float)),
    operation(SpirvDialect.UDivOp, spirvBinary(SpirvOp.UDiv, .int_unsigned)),
    operation(SpirvDialect.SDivOp, spirvBinary(SpirvOp.SDiv, .int_signed)),
    operation(SpirvDialect.FDivOp, spirvBinary(SpirvOp.FDiv, .float)),
    operation(ArithDialect.ConstantOp, direct(scalar.emitConstant)),
    operation(ArithDialect.AddOp, arithBinary(.add)),
    operation(ArithDialect.SubOp, arithBinary(.sub)),
    operation(ArithDialect.MulOp, arithBinary(.mul)),
    operation(ArithDialect.DivOp, arithBinary(.div)),
    operation(ArithDialect.RemOp, arithBinary(.rem)),
    operation(ArithDialect.MaxOp, arithMinMax(.max)),
    operation(ArithDialect.MinOp, arithMinMax(.min)),
    operation(ArithDialect.NegOp, direct(scalar.emitNegArith)),
    operation(ArithDialect.ExpOp, glslUnary(scalar.GLSLstd450.Exp)),
    operation(ArithDialect.LogOp, glslUnary(scalar.GLSLstd450.Log)),
    operation(ArithDialect.TanhOp, glslUnary(scalar.GLSLstd450.Tanh)),
    operation(ArithDialect.SqrtOp, direct(scalar.emitSqrtArith)),
    operation(ArithDialect.AbsOp, direct(scalar.emitAbsArith)),
    operation(ArithDialect.SinOp, glslUnary(scalar.GLSLstd450.Sin)),
    operation(ArithDialect.CosOp, glslUnary(scalar.GLSLstd450.Cos)),
    operation(ArithDialect.TanOp, glslUnary(scalar.GLSLstd450.Tan)),
    operation(ArithDialect.FloorOp, glslUnary(scalar.GLSLstd450.Floor)),
    operation(ArithDialect.RoundOp, direct(scalar.emitRoundArith)),
    operation(ArithDialect.TruncOp, glslUnary(scalar.GLSLstd450.Trunc)),
    operation(ArithDialect.PowOp, direct(scalar.emitPowArith)),
    operation(ArithDialect.Atan2Op, direct(scalar.emitAtan2Arith)),
    operation(ArithDialect.FmaOp, direct(scalar.emitFmaArith)),
    operation(ArithDialect.AndOp, arithBitwise(.band)),
    operation(ArithDialect.OrOp, arithBitwise(.bor)),
    operation(ArithDialect.XorOp, arithBitwise(.bxor)),
    operation(ArithDialect.NotOp, direct(scalar.emitNotArith)),
    operation(ArithDialect.ShlOp, arithShift(.shl)),
    operation(ArithDialect.ShrOp, arithShift(.shr)),
    operation(ArithDialect.UshrOp, arithShift(.ushr)),
    operation(ArithDialect.UmulhiOp, direct(scalar.emitUmulhi)),
    operation(ArithDialect.CastOp, direct(scalar.emitCast)),
    operation(ArithDialect.BitcastOp, direct(scalar.emitBitcast)),
    operation(ArithDialect.CmpOp, direct(scalar.emitCmp)),
    operation(ArithDialect.SelectOp, direct(scalar.emitSelect)),
    operation(MemrefDialect.LoadOp, direct(memory.emitLoad)),
    operation(MemrefDialect.StoreOp, direct(memory.emitStore)),
    operation(MemrefDialect.AtomicRmwOp, direct(memory.emitAtomicRmw)),
    operation(MemrefDialect.AtomicCasOp, direct(memory.emitAtomicCas)),
    operation(MemrefDialect.AllocOp, direct(memory.emitAlloc)),
    operation(MemrefDialect.AllocaOp, direct(memory.emitDeclaredAlloca)),
    operation(FuncDialect.CallOp, method("emitCall")),
    operation(SpirvDialect.LocalInvocationIdOp, gpuIndex(.local_invocation_id)),
    operation(SpirvDialect.WorkgroupIdOp, gpuIndex(.workgroup_id)),
    operation(SpirvDialect.WorkgroupSizeOp, gpuIndex(.workgroup_size)),
    operation(SpirvDialect.NumWorkgroupsOp, gpuIndex(.num_workgroups)),
    operation(SpirvDialect.GlobalInvocationIdOp, gpuIndex(.global_invocation_id)),
    operation(SpirvDialect.BarrierOp, direct(gpu.emitBarrier)),
    operation(SpirvDialect.SyncWarpOp, direct(gpu.emitSyncWarp)),
    operation(SpirvDialect.ActiveMaskOp, direct(gpu.emitActiveMask)),
    operation(SpirvDialect.AllSyncOp, withArg(gpu.emitAllAny, gpu.AllAnyKind.all)),
    operation(SpirvDialect.AnySyncOp, withArg(gpu.emitAllAny, gpu.AllAnyKind.any)),
    operation(SpirvDialect.BallotSyncOp, direct(gpu.emitBallot)),
    operation(SpirvDialect.ShflSyncOp, direct(gpu.emitShuffle)),
    operation(SpirvDialect.WarpReduceOp, direct(gpu.emitWarpReduce)),
    operation(SpirvDialect.WarpScanOp, direct(gpu.emitWarpScan)),
    operation(GpuDialect.ThreadIdxOp, gpuIndex(.local_invocation_id)),
    operation(GpuDialect.BlockIdxOp, gpuIndex(.workgroup_id)),
    operation(GpuDialect.BlockDimOp, gpuIndex(.workgroup_size)),
    operation(GpuDialect.GridDimOp, gpuIndex(.num_workgroups)),
    operation(GpuDialect.GlobalIdxOp, gpuIndex(.global_invocation_id)),
    operation(GpuDialect.LaneIdOp, gpuSubgroupIndex(.subgroup_local_invocation_id)),
    operation(GpuDialect.WarpIdOp, gpuSubgroupIndex(.subgroup_id)),
    operation(GpuDialect.BarrierOp, direct(gpu.emitBarrier)),
    operation(GpuDialect.SyncWarpOp, direct(gpu.emitSyncWarp)),
    operation(GpuDialect.ActiveMaskOp, direct(gpu.emitActiveMask)),
    operation(GpuDialect.AllSyncOp, withArg(gpu.emitAllAny, gpu.AllAnyKind.all)),
    operation(GpuDialect.AnySyncOp, withArg(gpu.emitAllAny, gpu.AllAnyKind.any)),
    operation(GpuDialect.BallotSyncOp, direct(gpu.emitBallot)),
    operation(GpuDialect.ShflSyncOp, direct(gpu.emitShuffle)),
    operation(GpuDialect.WarpReduceOp, direct(gpu.emitWarpReduce)),
    operation(GpuDialect.WarpScanOp, direct(gpu.emitWarpScan)),
    operation(GpuDialect.StageInputOp, direct(stage.emitStageInput)),
    operation(GpuDialect.StageOutputOp, direct(stage.emitStageOutput)),
    operation(GpuDialect.PositionOp, direct(stage.emitPosition)),
    operation(GpuDialect.FragCoordOp, withArg(builtinLoad, BuiltinKind.frag_coord)),
    operation(GpuDialect.VertexIndexOp, withArg(builtinLoad, BuiltinKind.vertex_index)),
    operation(GpuDialect.InstanceIndexOp, withArg(builtinLoad, BuiltinKind.instance_index)),
    operation(GpuDialect.FrontFacingOp, withArg(builtinLoad, BuiltinKind.front_facing)),
    operation(GpuDialect.SampledTextureOp, direct(stage.emitSampledTexture)),
    operation(GpuDialect.SampleOp, withArg(stage.emitSample, stage.Lod.implicit)),
    operation(GpuDialect.SampleLodOp, withArg(stage.emitSample, stage.Lod.explicit)),
    operation(GpuDialect.DpdxOp, withArg(stage.emitDerivative, SpirvOp.DPdxFine)),
    operation(GpuDialect.DpdyOp, withArg(stage.emitDerivative, SpirvOp.DPdyFine)),
    operation(GpuDialect.FwidthOp, withArg(stage.emitDerivative, SpirvOp.FwidthFine)),
    operation(GpuDialect.PushConstantOp, direct(stage.emitPushConstant)),
    operation(GpuDialect.UniformOp, direct(stage.emitUniform)),
    operation(ScfDialect.IfOp, method("emitScfIf")),
    operation(ScfDialect.ForOp, method("emitScfFor")),
    operation(ScfDialect.WhileOp, method("emitScfWhile")),
    operation(ScfDialect.YieldOp, unsupportedControlFlow()),
    operation(ScfDialect.ConditionOp, unsupportedControlFlow()),
    operation(FuncDialect.ReturnOp, method("emitReturn")),
};

pub fn supports(name: []const u8) bool {
    inline for (entries) |Entry| {
        if (std.mem.eql(u8, name, Entry.name)) return true;
    }
    return false;
}

pub fn emit(
    comptime ErrorSet: type,
    comptime Control: anytype,
    self: anytype,
    op: *ir.Operation,
) ErrorSet!void {
    inline for (entries) |Entry| {
        if (std.mem.eql(u8, op.name.name, Entry.name)) {
            return Entry.emit(ErrorSet, Control, self, op);
        }
    }
    return error.UnsupportedOperation;
}

comptime {
    @setEvalBranchQuota(100_000);
    for (entries, 0..) |Candidate, index| {
        if (!@hasDecl(Candidate, "emit")) @compileError("SPIR-V catalog emitter is missing");
        for (entries, 0..) |Prior, prior_index| {
            if (prior_index >= index) continue;
            if (std.mem.eql(u8, Candidate.name, Prior.name)) {
                @compileError("SPIR-V catalog operation name is not unique");
            }
        }
    }
}

test "spirv catalog resolves every operation to one emitter" {
    try std.testing.expectEqual(@as(usize, 103), entries.len);
    inline for (entries) |Entry| try std.testing.expect(supports(Entry.name));
    try std.testing.expect(!supports("test.unsupported"));
}
