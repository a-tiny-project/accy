const std = @import("std");
const abi = @import("gpu_abi");
const choir_pkg = @import("../../../root.zig");

const nvptx = @import("root.zig");
const gpu = @import("../../../dialects/gpu/root.zig");

const ir = choir_pkg.ir;
const dialects = choir_pkg.dialects;

const Allocator = std.mem.Allocator;
const ArithDialect = dialects.ArithDialect;
const CmpPredicate = dialects.arith.CmpPredicate;
const arith_names = dialects.arith.type_names;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const MemrefDialect = dialects.MemrefDialect;
const NvptxDialect = nvptx.NvptxDialect;
const ScfDialect = dialects.ScfDialect;

const EmitError = abi.Error || std.Io.Writer.Error;

const ScalarKind = dialects.arith.ScalarKind;
const scalar_kinds = dialects.arith.ScalarSet.init(&.{
    .i8,
    .i16,
    .i32,
    .i64,
    .u8,
    .u16,
    .u32,
    .u64,
    .f16,
    .bf16,
    .f32,
    .f64,
    .index,
    .bool,
});

const Value = union(enum) {
    pred: u32,
    u32: u32,
    s32: u32,
    u64: u32,
    f32: u32,
    f32x4: u32,
    f64: u32,
    ptr: u32,
    shared: u32,
};

const AddressBaseKey = struct {
    space: u32,
    base: usize,
    bytes: u32,
};

const AddressParts = struct {
    reg: u32,
    imm: i64,
};

const max_address_immediate: i64 = 1 << 30;

const PeeledIndex = struct {
    base: ?*ir.Value,
    offset: i64,
};

fn constantIndexValue(value: *ir.Value) ?i64 {
    const def = value.getDefiningOp() orelse return null;
    const op: *ir.Operation = @ptrCast(@alignCast(def));
    if (!std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) return null;
    const constant = ArithDialect.ConstantOp{ .op = op };
    return constant.getIntValue();
}

fn peelIndexOffset(index: *ir.Value) PeeledIndex {
    var current: *ir.Value = index;
    var offset: i64 = 0;
    var depth: u32 = 0;
    while (depth < 16) : (depth += 1) {
        if (constantIndexValue(current)) |value| return .{
            .base = null,
            .offset = std.math.add(i64, offset, value) catch return .{ .base = index, .offset = 0 },
        };
        const def = current.getDefiningOp() orelse break;
        const op: *ir.Operation = @ptrCast(@alignCast(def));
        if (std.mem.eql(u8, op.name.name, ArithDialect.AddOp.operation_name)) {
            const lhs = op.operands.items[0].value;
            const rhs = op.operands.items[1].value;
            if (constantIndexValue(rhs)) |value| {
                offset = std.math.add(i64, offset, value) catch
                    return .{ .base = index, .offset = 0 };
                current = lhs;
                continue;
            }
            if (constantIndexValue(lhs)) |value| {
                offset = std.math.add(i64, offset, value) catch
                    return .{ .base = index, .offset = 0 };
                current = rhs;
                continue;
            }
            break;
        }
        if (std.mem.eql(u8, op.name.name, ArithDialect.SubOp.operation_name)) {
            if (constantIndexValue(op.operands.items[1].value)) |value| {
                offset -= value;
                current = op.operands.items[0].value;
                continue;
            }
            break;
        }
        break;
    }
    return .{ .base = current, .offset = offset };
}

fn intValueForKind(kind: ScalarKind, reg: u32) Value {
    return switch (kind) {
        .i8, .i16, .i32 => .{ .s32 = reg },
        .index, .u8, .u16, .u32 => .{ .u32 = reg },
        .i64, .u64 => .{ .u64 = reg },
        else => unreachable,
    };
}

fn scalarKindIsSignedInteger(kind: ScalarKind) bool {
    return switch (kind) {
        .i8, .i16, .i32, .i64 => true,
        else => false,
    };
}

const LoopInteger = enum {
    u32,
    s32,
    u64,
    s64,

    fn fromType(typ: ir.Type) abi.Error!LoopInteger {
        return switch (try computeKind(typ)) {
            .index, .u32 => .u32,
            .i32 => .s32,
            .u64 => .u64,
            .i64 => .s64,
            else => error.UnsupportedOperation,
        };
    }

    fn registerFile(self: LoopInteger) []const u8 {
        return switch (self) {
            .u32, .s32 => "r",
            .u64, .s64 => "rd",
        };
    }

    fn register(self: LoopInteger, emitter: *Emitter, value: Value) abi.Error!u32 {
        return switch (self) {
            .u32, .s32 => emitter.asU32(value),
            .u64, .s64 => emitter.asU64(value),
        };
    }
};

fn atomicIntegerSuffix(kind: dialects.AtomicRmwKind, element: ScalarKind) abi.Error![]const u8 {
    return switch (kind) {
        .add => "add.u32",
        .min => if (element == .i32) "min.s32" else "min.u32",
        .max => if (element == .i32) "max.s32" else "max.u32",
        .bit_and => "and.b32",
        .bit_or => "or.b32",
        .bit_xor => "xor.b32",
        .exchange => "exch.b32",
    };
}

fn atomicKindSupportsRed(kind: dialects.AtomicRmwKind) bool {
    return switch (kind) {
        .add, .min, .max, .bit_and, .bit_or, .bit_xor => true,
        .exchange => false,
    };
}

pub fn emitPtx(
    result_allocator: Allocator,
    entry_name: []const u8,
    module: *ir.Operation,
) abi.Error![]u8 {
    var emitter = Emitter.init(result_allocator, entry_name, module);
    defer emitter.deinit();
    return emitter.emit() catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
}

const Emitter = struct {
    allocator: Allocator,
    entry_name: []const u8,
    module: *ir.Operation,
    body: std.Io.Writer.Allocating,
    memory_decls: std.Io.Writer.Allocating,
    values: std.AutoHashMapUnmanaged(*const ir.Value, Value) = .{},
    shared_bases: std.AutoHashMapUnmanaged(AddressBaseKey, u32) = .{},
    shared_byte_offsets: std.AutoHashMapUnmanaged(u32, u32) = .{},
    pointer_bases: std.AutoHashMapUnmanaged(AddressBaseKey, u32) = .{},
    next_r: u32 = 1,
    next_f: u32 = 1,
    next_fd: u32 = 1,
    next_h: u32 = 1,
    next_rd: u32 = 1,
    next_p: u32 = 1,
    next_shared: u32 = 0,
    next_label: u32 = 0,
    dynamic_shared_alignment: u32 = 0,
    requires_sm80: bool = false,

    const OperationHandler = *const fn (*Emitter, *ir.Operation) EmitError!void;

    fn init(allocator: Allocator, entry_name: []const u8, module: *ir.Operation) Emitter {
        return .{
            .allocator = allocator,
            .entry_name = entry_name,
            .module = module,
            .body = std.Io.Writer.Allocating.init(allocator),
            .memory_decls = std.Io.Writer.Allocating.init(allocator),
        };
    }

    fn deinit(self: *Emitter) void {
        self.pointer_bases.deinit(self.allocator);
        self.shared_byte_offsets.deinit(self.allocator);
        self.shared_bases.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.memory_decls.deinit();
        self.body.deinit();
    }

    fn resetAddressBases(self: *Emitter) void {
        self.shared_bases.clearRetainingCapacity();
        self.pointer_bases.clearRetainingCapacity();
    }

    fn emit(self: *Emitter) EmitError![]u8 {
        const func = try self.findKernelFunction();
        try self.emitParameterLoads(func);
        try self.emitBlock(func.getEntryBlock());

        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try writeHeader(&out.writer, self.requires_sm80);
        if (self.dynamic_shared_alignment != 0) {
            try out.writer.print("    .extern .shared .align {d} .b8 __choir_dynamic_shared[];\n", .{self.dynamic_shared_alignment});
            try out.writer.writeByte('\n');
        }
        try self.emitEntryHeader(&out.writer, func);
        try self.emitRegisterDecls(&out.writer);
        try out.writer.writeAll(self.memory_decls.written());
        if (self.memory_decls.written().len != 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(self.body.written());
        try out.writer.writeAll("}\n");
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn findKernelFunction(self: *Emitter) abi.Error!FuncDialect.FuncOp {
        if (!std.mem.eql(u8, self.module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
            return error.InvalidArtifact;
        }
        const block = self.module.getRegion(0).?.getEntryBlock() orelse return error.InvalidArtifact;
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
            const func = FuncDialect.FuncOp{ .op = op };
            if (!func.isKernel()) continue;
            const name = func.getName() orelse return error.InvalidArtifact;
            if (std.mem.eql(u8, name, self.entry_name)) return func;
        }
        return error.InvalidArtifact;
    }

    fn emitParameterLoads(self: *Emitter, func: FuncDialect.FuncOp) EmitError!void {
        const args = func.getArguments();
        for (args, 0..) |arg, index| {
            if (memrefInfo(arg.type)) |memref| {
                if (!isKernelParameterAddressSpace(memref.addr_space)) return error.UnsupportedOperation;
                const raw = self.allocPtr();
                const ptr = self.allocPtr();
                try self.line("    ld.param.u64       %rd{d}, [param{d}];", .{ raw, index });
                try self.line("    cvta.to.global.u64 %rd{d}, %rd{d};", .{ ptr, raw });
                try self.bind(arg, .{ .ptr = ptr });
                continue;
            }
            switch (try scalarKind(arg.type)) {
                .i64, .u64 => {
                    const reg = self.allocU64();
                    try self.line("    ld.param.u64       %rd{d}, [param{d}];", .{ reg, index });
                    try self.bind(arg, .{ .u64 = reg });
                },
                .index, .u8, .u16, .u32 => {
                    const reg = self.allocU32();
                    try self.line("    ld.param.u32       %r{d}, [param{d}];", .{ reg, index });
                    try self.bind(arg, .{ .u32 = reg });
                },
                .i8, .i16, .i32 => {
                    const reg = self.allocU32();
                    try self.line("    ld.param.u32       %r{d}, [param{d}];", .{ reg, index });
                    try self.bind(arg, .{ .s32 = reg });
                },
                .f32 => {
                    const reg = self.allocF32();
                    try self.line("    ld.param.f32       %f{d}, [param{d}];", .{ reg, index });
                    try self.bind(arg, .{ .f32 = reg });
                },
                .f64 => {
                    const reg = self.allocF64();
                    try self.line("    ld.param.f64       %fd{d}, [param{d}];", .{ reg, index });
                    try self.bind(arg, .{ .f64 = reg });
                },
                .bool, .f16, .bf16 => return error.UnsupportedOperation,
            }
        }
        if (args.len != 0) try self.body.writer.writeByte('\n');
    }

    fn emitEntryHeader(self: *Emitter, writer: *std.Io.Writer, func: FuncDialect.FuncOp) EmitError!void {
        try writer.print(".visible .entry {s}(\n", .{self.entry_name});
        const args = func.getArguments();
        for (args, 0..) |arg, index| {
            const suffix = if (index + 1 == args.len) "" else ",";
            if (memrefInfo(arg.type)) |memref| {
                if (!isKernelParameterAddressSpace(memref.addr_space)) return error.UnsupportedOperation;
                try writer.print("    .param .u64 param{d}{s}\n", .{ index, suffix });
                continue;
            }
            switch (try scalarKind(arg.type)) {
                .i64, .u64 => try writer.print("    .param .u64 param{d}{s}\n", .{ index, suffix }),
                .index, .i8, .i16, .i32, .u8, .u16, .u32 => try writer.print("    .param .u32 param{d}{s}\n", .{ index, suffix }),
                .f32 => try writer.print("    .param .f32 param{d}{s}\n", .{ index, suffix }),
                .f64 => try writer.print("    .param .f64 param{d}{s}\n", .{ index, suffix }),
                .bool, .f16, .bf16 => return error.UnsupportedOperation,
            }
        }
        try writer.writeAll(")\n{\n");
    }

    fn emitRegisterDecls(self: *Emitter, writer: *std.Io.Writer) EmitError!void {
        try writer.print("    .reg .b32   %r<{d}>;\n", .{@max(self.next_r, 1)});
        try writer.print("    .reg .f32   %f<{d}>;\n", .{@max(self.next_f, 1)});
        try writer.print("    .reg .f64   %fd<{d}>;\n", .{@max(self.next_fd, 1)});
        try writer.print("    .reg .b16   %h<{d}>;\n", .{@max(self.next_h, 1)});
        try writer.print("    .reg .b64   %rd<{d}>;\n", .{@max(self.next_rd, 1)});
        try writer.print("    .reg .pred  %p<{d}>;\n\n", .{@max(self.next_p, 1)});
    }

    fn emitBlock(self: *Emitter, block: *ir.Block) EmitError!void {
        self.resetAddressBases();
        var ops = block.getOperations();
        while (ops.next()) |op| {
            try self.emitOperation(op);
        }
        self.resetAddressBases();
    }

    fn emitOperation(self: *Emitter, op: *ir.Operation) EmitError!void {
        const handler = operation_emitters.get(op.name.name) orelse return error.UnsupportedOperation;
        try handler(self, op);
        for (op.results.items) |*result| try self.narrowResult(result);
    }

    fn narrowResult(self: *Emitter, result: *ir.Value) EmitError!void {
        const kind = scalar_kinds.kindFromType(result.type) orelse return;
        const bits: u5 = switch (kind) {
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            else => return,
        };
        const input = try self.asU32(try self.require(result));
        const out = self.allocU32();
        if (kind == .u8 or kind == .u16) {
            const mask = (@as(u32, 1) << bits) - 1;
            try self.line("    and.b32            %r{d}, %r{d}, {d};", .{ out, input, mask });
        } else {
            const shift: u6 = 32 - @as(u6, bits);
            try self.line("    shl.b32            %r{d}, %r{d}, {d};", .{ out, input, shift });
            try self.line("    shr.s32            %r{d}, %r{d}, {d};", .{ out, out, shift });
        }
        try self.bind(result, intValueForKind(kind, out));
    }

    const operation_emitters = std.StaticStringMap(OperationHandler).initComptime(.{
        .{ FuncDialect.ReturnOp.operation_name, lineHandler("    ret;") },
        .{ NvptxDialect.ThreadIdxOp.operation_name, dimHandler(NvptxDialect.ThreadIdxOp, "tid") },
        .{ NvptxDialect.BlockIdxOp.operation_name, dimHandler(NvptxDialect.BlockIdxOp, "ctaid") },
        .{ NvptxDialect.BlockDimOp.operation_name, dimHandler(NvptxDialect.BlockDimOp, "ntid") },
        .{ NvptxDialect.GridDimOp.operation_name, dimHandler(NvptxDialect.GridDimOp, "nctaid") },
        .{ NvptxDialect.Barrier0Op.operation_name, lineHandler("    bar.sync           0;") },
        .{ NvptxDialect.WarpBarrierAllOp.operation_name, lineHandler("    bar.warp.sync      0xffffffff;") },
        .{ NvptxDialect.LoadGlobalOp.operation_name, wrappedHandler(NvptxDialect.LoadGlobalOp, "emitNvptxGlobalLoad") },
        .{ NvptxDialect.LoadLocalOp.operation_name, wrappedHandler(NvptxDialect.LoadLocalOp, "emitNvptxLocalLoad") },
        .{ NvptxDialect.LoadSharedOp.operation_name, wrappedHandler(NvptxDialect.LoadSharedOp, "emitNvptxSharedLoad") },
        .{ NvptxDialect.StoreGlobalOp.operation_name, wrappedHandler(NvptxDialect.StoreGlobalOp, "emitNvptxGlobalStore") },
        .{ NvptxDialect.StoreLocalOp.operation_name, wrappedHandler(NvptxDialect.StoreLocalOp, "emitNvptxLocalStore") },
        .{ NvptxDialect.StoreSharedOp.operation_name, wrappedHandler(NvptxDialect.StoreSharedOp, "emitNvptxSharedStore") },
        .{ NvptxDialect.AtomicGlobalOp.operation_name, wrappedHandler(NvptxDialect.AtomicGlobalOp, "emitNvptxGlobalAtomic") },
        .{ NvptxDialect.AtomicSharedOp.operation_name, wrappedHandler(NvptxDialect.AtomicSharedOp, "emitNvptxSharedAtomic") },
        .{ NvptxDialect.AtomicCasGlobalOp.operation_name, wrappedHandler(NvptxDialect.AtomicCasGlobalOp, "emitNvptxGlobalAtomicCas") },
        .{ NvptxDialect.AtomicCasSharedOp.operation_name, wrappedHandler(NvptxDialect.AtomicCasSharedOp, "emitNvptxSharedAtomicCas") },
        .{ NvptxDialect.LaneIdOp.operation_name, specialHandler("laneid") },
        .{ NvptxDialect.WarpIdOp.operation_name, rawHandler("emitWarpIndex") },
        .{ NvptxDialect.SyncWarpOp.operation_name, wrappedHandler(NvptxDialect.SyncWarpOp, "emitSyncWarp") },
        .{ NvptxDialect.ActiveMaskOp.operation_name, wrappedHandler(NvptxDialect.ActiveMaskOp, "emitActiveMask") },
        .{ NvptxDialect.AllSyncOp.operation_name, voteHandler(NvptxDialect.AllSyncOp, "all") },
        .{ NvptxDialect.AnySyncOp.operation_name, voteHandler(NvptxDialect.AnySyncOp, "any") },
        .{ NvptxDialect.BallotSyncOp.operation_name, wrappedHandler(NvptxDialect.BallotSyncOp, "emitBallotSync") },
        .{ NvptxDialect.ShflSyncOp.operation_name, wrappedHandler(NvptxDialect.ShflSyncOp, "emitShflSync") },
        .{ NvptxDialect.WarpReduceOp.operation_name, wrappedHandler(NvptxDialect.WarpReduceOp, "emitWarpReduce") },
        .{ NvptxDialect.WarpScanOp.operation_name, wrappedHandler(NvptxDialect.WarpScanOp, "emitWarpScan") },
        .{ NvptxDialect.MmaSyncOp.operation_name, wrappedHandler(NvptxDialect.MmaSyncOp, "emitMmaSync") },
        .{ NvptxDialect.FenceDeviceOp.operation_name, lineHandler("    membar.gl;") },
        .{ NvptxDialect.CpAsyncSharedOp.operation_name, wrappedHandler(NvptxDialect.CpAsyncSharedOp, "emitCpAsyncShared") },
        .{ NvptxDialect.CpAsyncCommitOp.operation_name, wrappedHandler(NvptxDialect.CpAsyncCommitOp, "emitCpAsyncCommit") },
        .{ NvptxDialect.CpAsyncWaitOp.operation_name, wrappedHandler(NvptxDialect.CpAsyncWaitOp, "emitCpAsyncWait") },
        .{ MemrefDialect.AllocOp.operation_name, wrappedHandler(MemrefDialect.AllocOp, "emitAlloc") },
        .{ MemrefDialect.AllocaOp.operation_name, wrappedHandler(MemrefDialect.AllocaOp, "emitAlloca") },
        .{ ArithDialect.ConstantOp.operation_name, wrappedHandler(ArithDialect.ConstantOp, "emitConstant") },
        .{ ArithDialect.AddOp.operation_name, binaryHandler("add") },
        .{ ArithDialect.SubOp.operation_name, binaryHandler("sub") },
        .{ ArithDialect.MulOp.operation_name, binaryHandler("mul") },
        .{ ArithDialect.UmulhiOp.operation_name, rawHandler("emitUmulhi") },
        .{ ArithDialect.DivOp.operation_name, rawHandler("emitDiv") },
        .{ ArithDialect.NegOp.operation_name, rawHandler("emitNeg") },
        .{ ArithDialect.AbsOp.operation_name, rawHandler("emitAbs") },
        .{ ArithDialect.SqrtOp.operation_name, floatUnaryHandler("sqrt.approx") },
        .{ ArithDialect.MaxOp.operation_name, binaryHandler("max") },
        .{ ArithDialect.MinOp.operation_name, binaryHandler("min") },
        .{ ArithDialect.AndOp.operation_name, bitwiseHandler("and") },
        .{ ArithDialect.OrOp.operation_name, bitwiseHandler("or") },
        .{ ArithDialect.XorOp.operation_name, bitwiseHandler("xor") },
        .{ ArithDialect.NotOp.operation_name, rawHandler("emitNot") },
        .{ ArithDialect.PopCountOp.operation_name, rawHandler("emitPopCount") },
        .{ ArithDialect.ShlOp.operation_name, shiftHandler("shl.b32") },
        .{ ArithDialect.ShrOp.operation_name, shiftHandler("shr.s32") },
        .{ ArithDialect.UshrOp.operation_name, shiftHandler("shr.u32") },
        .{ ArithDialect.CmpOp.operation_name, wrappedHandler(ArithDialect.CmpOp, "emitCompare") },
        .{ ArithDialect.SelectOp.operation_name, rawHandler("emitSelect") },
        .{ ArithDialect.CastOp.operation_name, wrappedHandler(ArithDialect.CastOp, "emitCast") },
        .{ ArithDialect.BitcastOp.operation_name, rawHandler("emitBitcast") },
        .{ ArithDialect.ExpOp.operation_name, rawHandler("emitExp") },
        .{ ArithDialect.LogOp.operation_name, rawHandler("emitLog") },
        .{ ArithDialect.TanhOp.operation_name, rawHandler("emitTanh") },
        .{ ArithDialect.SinOp.operation_name, floatUnaryHandler("sin.approx") },
        .{ ArithDialect.CosOp.operation_name, floatUnaryHandler("cos.approx") },
        .{ ArithDialect.TanOp.operation_name, rawHandler("emitTan") },
        .{ ArithDialect.FloorOp.operation_name, floatIntegralUnaryHandler("cvt.rmi") },
        .{ ArithDialect.RoundOp.operation_name, rawHandler("emitRound") },
        .{ ArithDialect.TruncOp.operation_name, floatIntegralUnaryHandler("cvt.rzi") },
        .{ ArithDialect.Tf32RoundOp.operation_name, rawHandler("emitTf32Round") },
        .{ ArithDialect.PowOp.operation_name, rawHandler("emitPow") },
        .{ ArithDialect.Atan2Op.operation_name, rawHandler("emitAtan2") },
        .{ ArithDialect.FmaOp.operation_name, rawHandler("emitFma") },
        .{ ArithDialect.ExtractOp.operation_name, rawHandler("emitVecExtract") },
        .{ ArithDialect.SplatOp.operation_name, rawHandler("emitVecSplat") },
        .{ ArithDialect.InsertOp.operation_name, rawHandler("emitVecInsert") },
        .{ ScfDialect.IfOp.operation_name, wrappedHandler(ScfDialect.IfOp, "emitIf") },
        .{ ScfDialect.ForOp.operation_name, wrappedHandler(ScfDialect.ForOp, "emitFor") },
        .{ ScfDialect.WhileOp.operation_name, wrappedHandler(ScfDialect.WhileOp, "emitWhile") },
        .{ ScfDialect.YieldOp.operation_name, nopHandler() },
    });

    fn lineHandler(comptime text: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                _ = op;
                try self.line(text, .{});
            }
        }.emit;
    }

    fn nopHandler() OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                _ = self;
                _ = op;
            }
        }.emit;
    }

    fn dimHandler(comptime OpType: type, comptime register: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                const wrapped_op = OpType{ .op = op };
                try self.emitDimRegister(op, wrapped_op.getDimension() orelse return error.InvalidArtifact, register);
            }
        }.emit;
    }

    fn specialHandler(comptime register: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try self.emitSpecialRegister(op, register);
            }
        }.emit;
    }

    fn voteHandler(comptime OpType: type, comptime kind: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                const wrapped_op = OpType{ .op = op };
                try self.emitVoteSync(wrapped_op.getResult(), wrapped_op.getMask(), wrapped_op.getPredicate(), kind);
            }
        }.emit;
    }

    fn wrappedHandler(comptime OpType: type, comptime method: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try @field(Emitter, method)(self, OpType{ .op = op });
            }
        }.emit;
    }

    fn rawHandler(comptime method: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try @field(Emitter, method)(self, op);
            }
        }.emit;
    }

    fn binaryHandler(comptime mnemonic: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try self.emitBinary(op, mnemonic);
            }
        }.emit;
    }

    fn bitwiseHandler(comptime mnemonic: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try self.emitBitwise(op, mnemonic);
            }
        }.emit;
    }

    fn shiftHandler(comptime mnemonic: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try self.emitShift(op, mnemonic);
            }
        }.emit;
    }

    fn floatUnaryHandler(comptime mnemonic: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try self.emitFloatUnary(op, mnemonic);
            }
        }.emit;
    }

    fn floatIntegralUnaryHandler(comptime mnemonic: []const u8) OperationHandler {
        return struct {
            fn emit(self: *Emitter, op: *ir.Operation) EmitError!void {
                try self.emitFloatIntegralUnary(op, mnemonic);
            }
        }.emit;
    }
    fn emitDimRegister(self: *Emitter, op: *ir.Operation, dim: gpu.Dimension, comptime ptx_name: []const u8) EmitError!void {
        const out = self.allocU32();
        try self.line("    mov.u32            %r{d}, %{s}.{s};", .{ out, ptx_name, dimName(dim) });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .u32 = out });
    }

    fn emitSpecialRegister(self: *Emitter, op: *ir.Operation, comptime ptx_name: []const u8) EmitError!void {
        const out = self.allocU32();
        try self.line("    mov.u32            %r{d}, %{s};", .{ out, ptx_name });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .u32 = out });
    }

    fn emitWarpIndex(self: *Emitter, op: *ir.Operation) EmitError!void {
        const tid_z = self.allocU32();
        try self.line("    mov.u32            %r{d}, %tid.z;", .{tid_z});
        const ntid_y = self.allocU32();
        try self.line("    mov.u32            %r{d}, %ntid.y;", .{ntid_y});
        const tid_y = self.allocU32();
        try self.line("    mov.u32            %r{d}, %tid.y;", .{tid_y});
        const ntid_x = self.allocU32();
        try self.line("    mov.u32            %r{d}, %ntid.x;", .{ntid_x});
        const tid_x = self.allocU32();
        try self.line("    mov.u32            %r{d}, %tid.x;", .{tid_x});
        const plane = self.allocU32();
        try self.line("    mul.lo.u32         %r{d}, %r{d}, %r{d};", .{ plane, tid_z, ntid_y });
        const row = self.allocU32();
        try self.line("    add.u32            %r{d}, %r{d}, %r{d};", .{ row, plane, tid_y });
        const scaled = self.allocU32();
        try self.line("    mul.lo.u32         %r{d}, %r{d}, %r{d};", .{ scaled, row, ntid_x });
        const linear = self.allocU32();
        try self.line("    add.u32            %r{d}, %r{d}, %r{d};", .{ linear, scaled, tid_x });
        const out = self.allocU32();
        try self.line("    shr.u32            %r{d}, %r{d}, 5;", .{ out, linear });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .u32 = out });
    }

    fn emitSyncWarp(self: *Emitter, op: NvptxDialect.SyncWarpOp) EmitError!void {
        const mask = try self.asU32(try self.require(op.getMask()));
        try self.line("    bar.warp.sync      %r{d};", .{mask});
    }

    fn emitActiveMask(self: *Emitter, op: NvptxDialect.ActiveMaskOp) EmitError!void {
        const out = self.allocU32();
        try self.line("    activemask.b32     %r{d};", .{out});
        try self.bind(op.getResult(), .{ .u32 = out });
    }

    fn emitVoteSync(
        self: *Emitter,
        result: *ir.Value,
        mask_value: *ir.Value,
        predicate_value: *ir.Value,
        comptime mode: []const u8,
    ) EmitError!void {
        if ((try scalarKind(result.type)) != .bool) return error.UnsupportedOperation;
        const mask = try self.asU32(try self.require(mask_value));
        const predicate = try self.asPred(try self.require(predicate_value));
        const out = self.allocPred();
        try self.line("    vote.sync.{s}.pred %p{d}, %p{d}, %r{d};", .{ mode, out, predicate, mask });
        try self.bind(result, .{ .pred = out });
    }

    fn emitBallotSync(self: *Emitter, op: NvptxDialect.BallotSyncOp) EmitError!void {
        const mask = try self.asU32(try self.require(op.getMask()));
        const predicate = try self.asPred(try self.require(op.getPredicate()));
        const out = self.allocU32();
        try self.line("    vote.sync.ballot.b32 %r{d}, %p{d}, %r{d};", .{ out, predicate, mask });
        try self.bind(op.getResult(), .{ .u32 = out });
    }

    fn emitShflSync(self: *Emitter, op: NvptxDialect.ShflSyncOp) EmitError!void {
        const result = op.getResult();
        const mask = try self.asU32(try self.require(op.getMask()));
        const lane_or_delta = try self.asU32(try self.require(op.getLaneOrDelta()));
        const mode = ptxShuffleMode(op.getMode() orelse return error.InvalidArtifact);
        const src = try self.require(op.getSrc());
        switch (try scalarKind(result.type)) {
            .i64, .u64 => return error.UnsupportedOperation,
            .index, .i8, .i16, .i32, .u8, .u16, .u32 => {
                const out = self.allocU32();
                try self.line("    shfl.sync.{s}.b32  %r{d}, %r{d}, %r{d}, 0x1f, %r{d};", .{ mode, out, try self.asU32(src), lane_or_delta, mask });
                try self.bind(result, intValueForKind(try scalarKind(result.type), out));
            },
            .f32 => {
                const src_bits = self.allocU32();
                const out_bits = self.allocU32();
                const out = self.allocF32();
                try self.line("    mov.b32            %r{d}, %f{d};", .{ src_bits, try self.asF32(src) });
                try self.line("    shfl.sync.{s}.b32  %r{d}, %r{d}, %r{d}, 0x1f, %r{d};", .{ mode, out_bits, src_bits, lane_or_delta, mask });
                try self.line("    mov.b32            %f{d}, %r{d};", .{ out, out_bits });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const src_lo = self.allocU32();
                const src_hi = self.allocU32();
                const out_lo = self.allocU32();
                const out_hi = self.allocU32();
                const out = self.allocF64();
                try self.emitF64Unpack(src_lo, src_hi, try self.asF64(src));
                try self.line("    shfl.sync.{s}.b32  %r{d}, %r{d}, %r{d}, 0x1f, %r{d};", .{ mode, out_lo, src_lo, lane_or_delta, mask });
                try self.line("    shfl.sync.{s}.b32  %r{d}, %r{d}, %r{d}, 0x1f, %r{d};", .{ mode, out_hi, src_hi, lane_or_delta, mask });
                try self.emitF64Pack(out, out_lo, out_hi);
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => return error.UnsupportedOperation,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitWarpReduce(self: *Emitter, op: NvptxDialect.WarpReduceOp) EmitError!void {
        const result = op.getResult();
        try self.requireFullWarpMask(op.getMask());
        const mask = try self.asU32(try self.require(op.getMask()));
        const value = try self.require(op.getValue());
        const op_kind = op.getOpKind() orelse return error.InvalidArtifact;
        switch (try scalarKind(result.type)) {
            .i64, .u64 => return error.UnsupportedOperation,
            .index, .i8, .i16, .i32, .u8, .u16, .u32 => {
                const accumulator = self.allocU32();
                try self.emitMove(.{ .u32 = accumulator }, value);
                const unsigned = !scalarKindIsSignedInteger(try scalarKind(result.type));
                inline for (warp_reduce_deltas) |delta| {
                    const other = self.allocU32();
                    try self.line("    shfl.sync.bfly.b32 %r{d}, %r{d}, {d}, 0x1f, %r{d};", .{ other, accumulator, delta, mask });
                    try self.emitWarpIntegerCombine(null, accumulator, other, op_kind, unsigned);
                }
                try self.bind(result, intValueForKind(try scalarKind(result.type), accumulator));
            },
            .f32 => {
                const accumulator = self.allocF32();
                try self.emitMove(.{ .f32 = accumulator }, value);
                inline for (warp_reduce_deltas) |delta| {
                    const bits = self.allocU32();
                    const other_bits = self.allocU32();
                    const other = self.allocF32();
                    try self.line("    mov.b32            %r{d}, %f{d};", .{ bits, accumulator });
                    try self.line("    shfl.sync.bfly.b32 %r{d}, %r{d}, {d}, 0x1f, %r{d};", .{ other_bits, bits, delta, mask });
                    try self.line("    mov.b32            %f{d}, %r{d};", .{ other, other_bits });
                    try self.emitWarpFloatCombine(null, accumulator, other, op_kind);
                }
                try self.bind(result, .{ .f32 = accumulator });
            },
            .f64 => {
                const accumulator = self.allocF64();
                try self.emitMove(.{ .f64 = accumulator }, value);
                inline for (warp_reduce_deltas) |delta| {
                    const bits_lo = self.allocU32();
                    const bits_hi = self.allocU32();
                    const other_lo = self.allocU32();
                    const other_hi = self.allocU32();
                    const other = self.allocF64();
                    try self.emitF64Unpack(bits_lo, bits_hi, accumulator);
                    try self.line("    shfl.sync.bfly.b32 %r{d}, %r{d}, {d}, 0x1f, %r{d};", .{ other_lo, bits_lo, delta, mask });
                    try self.line("    shfl.sync.bfly.b32 %r{d}, %r{d}, {d}, 0x1f, %r{d};", .{ other_hi, bits_hi, delta, mask });
                    try self.emitF64Pack(other, other_lo, other_hi);
                    try self.emitWarpF64Combine(null, accumulator, other, op_kind);
                }
                try self.bind(result, .{ .f64 = accumulator });
            },
            .f16, .bf16 => return error.UnsupportedOperation,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitWarpScan(self: *Emitter, op: NvptxDialect.WarpScanOp) EmitError!void {
        const result = op.getResult();
        try self.requireFullWarpMask(op.getMask());
        const mask = try self.asU32(try self.require(op.getMask()));
        const value = try self.require(op.getValue());
        const op_kind = op.getOpKind() orelse return error.InvalidArtifact;
        switch (try scalarKind(result.type)) {
            .i64, .u64 => return error.UnsupportedOperation,
            .index, .i8, .i16, .i32, .u8, .u16, .u32 => try self.emitWarpIntegerScan(result, mask, value, op_kind, op.isInclusive()),
            .f32 => try self.emitWarpFloatScan(result, mask, value, op_kind, op.isInclusive()),
            .f16, .bf16 => return error.UnsupportedOperation,
            .f64 => return error.UnsupportedOperation,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitWarpIntegerScan(
        self: *Emitter,
        result: *ir.Value,
        mask: u32,
        value: Value,
        op_kind: gpu.WarpOpKind,
        inclusive: bool,
    ) EmitError!void {
        const accumulator = self.allocU32();
        try self.emitMove(.{ .u32 = accumulator }, value);
        const unsigned = !scalarKindIsSignedInteger(try scalarKind(result.type));
        inline for (warp_scan_offsets) |offset| {
            const other = self.allocU32();
            const valid = self.allocPred();
            try self.line("    shfl.sync.up.b32   %r{d}|%p{d}, %r{d}, {d}, 0x0, %r{d};", .{ other, valid, accumulator, offset, mask });
            try self.emitWarpIntegerCombine(valid, accumulator, other, op_kind, unsigned);
        }
        if (inclusive) {
            try self.bind(result, intValueForKind(try scalarKind(result.type), accumulator));
            return;
        }

        const previous = self.allocU32();
        const previous_valid = self.allocPred();
        const out = self.allocU32();
        try self.line("    shfl.sync.up.b32   %r{d}|%p{d}, %r{d}, 1, 0x0, %r{d};", .{ previous, previous_valid, accumulator, mask });
        try self.emitWarpIntegerIdentity(out, op_kind, unsigned);
        try self.line("    @%p{d} mov.u32     %r{d}, %r{d};", .{ previous_valid, out, previous });
        try self.bind(result, intValueForKind(try scalarKind(result.type), out));
    }

    fn emitWarpFloatScan(
        self: *Emitter,
        result: *ir.Value,
        mask: u32,
        value: Value,
        op_kind: gpu.WarpOpKind,
        inclusive: bool,
    ) EmitError!void {
        const accumulator = self.allocF32();
        try self.emitMove(.{ .f32 = accumulator }, value);
        inline for (warp_scan_offsets) |offset| {
            const bits = self.allocU32();
            const other_bits = self.allocU32();
            const other = self.allocF32();
            const valid = self.allocPred();
            try self.line("    mov.b32            %r{d}, %f{d};", .{ bits, accumulator });
            try self.line("    shfl.sync.up.b32   %r{d}|%p{d}, %r{d}, {d}, 0x0, %r{d};", .{ other_bits, valid, bits, offset, mask });
            try self.line("    mov.b32            %f{d}, %r{d};", .{ other, other_bits });
            try self.emitWarpFloatCombine(valid, accumulator, other, op_kind);
        }
        if (inclusive) {
            try self.bind(result, .{ .f32 = accumulator });
            return;
        }

        const bits = self.allocU32();
        const previous_bits = self.allocU32();
        const previous = self.allocF32();
        const previous_valid = self.allocPred();
        const out = self.allocF32();
        try self.line("    mov.b32            %r{d}, %f{d};", .{ bits, accumulator });
        try self.line("    shfl.sync.up.b32   %r{d}|%p{d}, %r{d}, 1, 0x0, %r{d};", .{ previous_bits, previous_valid, bits, mask });
        try self.line("    mov.b32            %f{d}, %r{d};", .{ previous, previous_bits });
        try self.emitWarpFloatIdentity(out, op_kind);
        try self.line("    @%p{d} mov.f32     %f{d}, %f{d};", .{ previous_valid, out, previous });
        try self.bind(result, .{ .f32 = out });
    }

    fn emitWarpIntegerCombine(self: *Emitter, predicate: ?u32, accumulator: u32, other: u32, op_kind: gpu.WarpOpKind, unsigned: bool) EmitError!void {
        if (predicate) |pred| {
            switch (op_kind) {
                .add => try self.line("    @%p{d} add.u32     %r{d}, %r{d}, %r{d};", .{ pred, accumulator, accumulator, other }),
                .max => try self.line("    @%p{d} max.{s}32   %r{d}, %r{d}, %r{d};", .{ pred, if (unsigned) "u" else "s", accumulator, accumulator, other }),
                .min => try self.line("    @%p{d} min.{s}32   %r{d}, %r{d}, %r{d};", .{ pred, if (unsigned) "u" else "s", accumulator, accumulator, other }),
                .and_ => try self.line("    @%p{d} and.b32     %r{d}, %r{d}, %r{d};", .{ pred, accumulator, accumulator, other }),
                .or_ => try self.line("    @%p{d} or.b32      %r{d}, %r{d}, %r{d};", .{ pred, accumulator, accumulator, other }),
                .xor => try self.line("    @%p{d} xor.b32     %r{d}, %r{d}, %r{d};", .{ pred, accumulator, accumulator, other }),
            }
            return;
        }
        switch (op_kind) {
            .add => try self.line("    add.u32            %r{d}, %r{d}, %r{d};", .{ accumulator, accumulator, other }),
            .max => try self.line("    max.{s}32          %r{d}, %r{d}, %r{d};", .{ if (unsigned) "u" else "s", accumulator, accumulator, other }),
            .min => try self.line("    min.{s}32          %r{d}, %r{d}, %r{d};", .{ if (unsigned) "u" else "s", accumulator, accumulator, other }),
            .and_ => try self.line("    and.b32            %r{d}, %r{d}, %r{d};", .{ accumulator, accumulator, other }),
            .or_ => try self.line("    or.b32             %r{d}, %r{d}, %r{d};", .{ accumulator, accumulator, other }),
            .xor => try self.line("    xor.b32            %r{d}, %r{d}, %r{d};", .{ accumulator, accumulator, other }),
        }
    }

    fn emitWarpFloatCombine(self: *Emitter, predicate: ?u32, accumulator: u32, other: u32, op_kind: gpu.WarpOpKind) EmitError!void {
        if (predicate) |pred| {
            switch (op_kind) {
                .add => try self.line("    @%p{d} add.f32     %f{d}, %f{d}, %f{d};", .{ pred, accumulator, accumulator, other }),
                .max => try self.line("    @%p{d} max.f32     %f{d}, %f{d}, %f{d};", .{ pred, accumulator, accumulator, other }),
                .min => try self.line("    @%p{d} min.f32     %f{d}, %f{d}, %f{d};", .{ pred, accumulator, accumulator, other }),
                .and_, .or_, .xor => return error.UnsupportedOperation,
            }
            return;
        }
        switch (op_kind) {
            .add => try self.line("    add.f32            %f{d}, %f{d}, %f{d};", .{ accumulator, accumulator, other }),
            .max => try self.line("    max.f32            %f{d}, %f{d}, %f{d};", .{ accumulator, accumulator, other }),
            .min => try self.line("    min.f32            %f{d}, %f{d}, %f{d};", .{ accumulator, accumulator, other }),
            .and_, .or_, .xor => return error.UnsupportedOperation,
        }
    }

    fn emitWarpF64Combine(self: *Emitter, predicate: ?u32, accumulator: u32, other: u32, op_kind: gpu.WarpOpKind) EmitError!void {
        if (predicate) |pred| {
            switch (op_kind) {
                .add => try self.line("    @%p{d} add.f64     %fd{d}, %fd{d}, %fd{d};", .{ pred, accumulator, accumulator, other }),
                .max => try self.line("    @%p{d} max.f64     %fd{d}, %fd{d}, %fd{d};", .{ pred, accumulator, accumulator, other }),
                .min => try self.line("    @%p{d} min.f64     %fd{d}, %fd{d}, %fd{d};", .{ pred, accumulator, accumulator, other }),
                .and_, .or_, .xor => return error.UnsupportedOperation,
            }
            return;
        }
        switch (op_kind) {
            .add => try self.line("    add.f64            %fd{d}, %fd{d}, %fd{d};", .{ accumulator, accumulator, other }),
            .max => try self.line("    max.f64            %fd{d}, %fd{d}, %fd{d};", .{ accumulator, accumulator, other }),
            .min => try self.line("    min.f64            %fd{d}, %fd{d}, %fd{d};", .{ accumulator, accumulator, other }),
            .and_, .or_, .xor => return error.UnsupportedOperation,
        }
    }

    fn emitF64Unpack(self: *Emitter, lo: u32, hi: u32, src: u32) EmitError!void {
        try self.line("    mov.b64            {{%r{d}, %r{d}}}, %fd{d};", .{ lo, hi, src });
    }

    fn emitF64Pack(self: *Emitter, dst: u32, lo: u32, hi: u32) EmitError!void {
        try self.line("    mov.b64            %fd{d}, {{%r{d}, %r{d}}};", .{ dst, lo, hi });
    }

    fn emitWarpIntegerIdentity(self: *Emitter, destination: u32, op_kind: gpu.WarpOpKind, unsigned: bool) EmitError!void {
        switch (op_kind) {
            .add, .or_, .xor => try self.line("    mov.u32            %r{d}, 0;", .{destination}),
            .and_ => try self.line("    mov.u32            %r{d}, 4294967295;", .{destination}),
            .max => try self.line("    mov.u32            %r{d}, {d};", .{ destination, if (unsigned) @as(u32, 0) else @as(u32, 2147483648) }),
            .min => try self.line("    mov.u32            %r{d}, {d};", .{ destination, if (unsigned) @as(u32, 4294967295) else @as(u32, 2147483647) }),
        }
    }

    fn emitWarpFloatIdentity(self: *Emitter, destination: u32, op_kind: gpu.WarpOpKind) EmitError!void {
        switch (op_kind) {
            .add => try self.line("    mov.f32            %f{d}, 0f00000000;", .{destination}),
            .max => try self.line("    mov.f32            %f{d}, 0fFF800000;", .{destination}),
            .min => try self.line("    mov.f32            %f{d}, 0f7F800000;", .{destination}),
            .and_, .or_, .xor => return error.UnsupportedOperation,
        }
    }

    fn requireFullWarpMask(_: *Emitter, mask: *ir.Value) abi.Error!void {
        const defining = mask.getDefiningOp() orelse return error.UnsupportedOperation;
        const op: *ir.Operation = @ptrCast(@alignCast(defining));
        if (!std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) return error.UnsupportedOperation;
        const constant = ArithDialect.ConstantOp{ .op = op };
        const int_value = constant.getIntValue() orelse return error.UnsupportedOperation;
        if (int_value != -1) return error.UnsupportedOperation;
    }

    fn emitAlloc(self: *Emitter, op: MemrefDialect.AllocOp) EmitError!void {
        const result = op.getResult();
        const memref = memrefInfo(result.type) orelse return error.InvalidArtifact;
        if (memref.addr_space != .shared) return error.UnsupportedOperation;
        const size = memref.size orelse return error.InvalidArtifact;
        const bytes64 = std.math.mul(u64, size, @as(u64, elementByteSize(memref.element))) catch return error.InvalidArtifact;
        const bytes = std.math.cast(u32, bytes64) orelse return error.InvalidArtifact;
        if (bytes == 0) return error.InvalidArtifact;
        const alignment64 = memref.alignment orelse elementByteSize(memref.element);
        var alignment = std.math.cast(u32, alignment64) orelse return error.InvalidArtifact;
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidArtifact;
        if (memref.element == .f32) alignment = @max(alignment, 16);
        const shared = self.allocShared();
        if (op.getDynamicSize() != null) {
            const byte_offset = try dynamicSharedByteOffset(op.op);
            if (byte_offset % alignment != 0) return error.InvalidArtifact;
            try self.shared_byte_offsets.put(self.allocator, shared, byte_offset);
            self.dynamic_shared_alignment = @max(self.dynamic_shared_alignment, alignment);
            try self.bind(result, .{ .shared = shared });
            return;
        }
        try self.memory_decls.writer.print("    .shared .align {d} .b8 __choir_shared{d}[{d}];\n", .{ alignment, shared, bytes });
        try self.bind(result, .{ .shared = shared });
    }

    fn emitAlloca(self: *Emitter, op: MemrefDialect.AllocaOp) EmitError!void {
        if (op.getDynamicSize() != null) return error.UnsupportedOperation;
        const result = op.getResult();
        const info = memrefInfo(result.type) orelse return error.InvalidArtifact;
        if (info.addr_space != .local) return error.UnsupportedOperation;
        const size = info.size orelse return error.InvalidArtifact;
        const bytes = std.math.mul(u64, size, elementByteSize(info.element)) catch
            return error.InvalidArtifact;
        if (bytes > std.math.maxInt(u32)) return error.UnsupportedOperation;
        const alignment = info.alignment orelse elementByteSize(info.element);
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidArtifact;
        const ptr = self.allocPtr();
        try self.memory_decls.writer.print("    .local .align {d} .b8 __choir_local{d}[{d}];\n", .{
            alignment, ptr, @max(bytes, 1),
        });
        try self.line("    mov.u64 %rd{d}, __choir_local{d};", .{ ptr, ptr });
        try self.bind(result, .{ .ptr = ptr });
    }

    fn emitNvptxLocalLoad(self: *Emitter, op: NvptxDialect.LoadLocalOp) EmitError!void {
        const value = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        if (info.addr_space != .local or value != .ptr) return error.InvalidArtifact;
        try self.emitPointerLoad("local", op.getResult(), value.ptr, op.getIndex(), info.element);
    }

    fn emitNvptxLocalStore(self: *Emitter, op: NvptxDialect.StoreLocalOp) EmitError!void {
        const value = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        if (info.addr_space != .local or value != .ptr) return error.InvalidArtifact;
        try self.emitPointerStore("local", op.getValue(), value.ptr, op.getIndex(), info.element);
    }

    fn emitPointerLoad(
        self: *Emitter,
        comptime space: []const u8,
        result: *ir.Value,
        ptr_reg: u32,
        index: *ir.Value,
        element: ScalarKind,
    ) EmitError!void {
        const addr = try self.emitPointerAddress(ptr_reg, index, element);
        switch (element) {
            .i8, .u8, .i16, .u16, .i32, .u32, .index => {
                const out = self.allocU32();
                const suffix = switch (element) {
                    .i8 => "s8",
                    .i16 => "s16",
                    .i32, .index => "u32",
                    else => @tagName(element),
                };
                try self.line("    ld." ++ space ++ ".{s} %r{d}, [%rd{d}+{d}];", .{
                    suffix, out, addr.reg, addr.imm,
                });
                try self.bind(result, intValueForKind(element, out));
            },
            .i64, .u64 => {
                const out = self.allocU64();
                try self.line("    ld." ++ space ++ ".u64      %rd{d}, [%rd{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .u64 = out });
            },
            .f32 => {
                const out = self.allocF32();
                try self.line("    ld." ++ space ++ ".f32      %f{d}, [%rd{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                try self.line("    ld." ++ space ++ ".f64      %fd{d}, [%rd{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .f64 = out });
            },
            .f16 => {
                const half = self.allocB16();
                const out = self.allocF32();
                try self.line("    ld." ++ space ++ ".b16      %h{d}, [%rd{d}+{d}];", .{ half, addr.reg, addr.imm });
                try self.line("    cvt.f32.f16        %f{d}, %h{d};", .{ out, half });
                try self.bind(result, .{ .f32 = out });
            },
            .bf16 => {
                const bits = self.allocU32();
                try self.line("    ld." ++ space ++ ".b16      %r{d}, [%rd{d}+{d}];", .{ bits, addr.reg, addr.imm });
                try self.bind(result, .{ .f32 = try self.emitBf16BitsToF32(bits) });
            },
            .bool => {
                const byte = self.allocU32();
                const out = self.allocPred();
                try self.line("    ld." ++ space ++ ".u8       %r{d}, [%rd{d}+{d}];", .{ byte, addr.reg, addr.imm });
                try self.line("    setp.ne.u32        %p{d}, %r{d}, 0;", .{ out, byte });
                try self.bind(result, .{ .pred = out });
            },
        }
    }

    fn emitSharedLoad(self: *Emitter, result: *ir.Value, shared: u32, index: *ir.Value, element: ScalarKind) EmitError!void {
        const addr = try self.emitSharedAddress(shared, index, element);
        switch (element) {
            .i8 => {
                const out = self.allocU32();
                try self.line("    ld.shared.s8       %r{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .s32 = out });
            },
            .u8 => {
                const out = self.allocU32();
                try self.line("    ld.shared.u8       %r{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .u32 = out });
            },
            .i16 => {
                const out = self.allocU32();
                try self.line("    ld.shared.s16      %r{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .s32 = out });
            },
            .u16 => {
                const out = self.allocU32();
                try self.line("    ld.shared.u16      %r{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .u32 = out });
            },
            .i64, .u64 => {
                const out = self.allocU64();
                try self.line("    ld.shared.u64      %rd{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .u64 = out });
            },
            .index, .u32 => {
                const out = self.allocU32();
                try self.line("    ld.shared.u32      %r{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .u32 = out });
            },
            .i32 => {
                const out = self.allocU32();
                try self.line("    ld.shared.u32      %r{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .s32 = out });
            },
            .f32 => {
                const out = self.allocF32();
                try self.line("    ld.shared.f32      %f{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                try self.line("    ld.shared.f64      %fd{d}, [%r{d}+{d}];", .{ out, addr.reg, addr.imm });
                try self.bind(result, .{ .f64 = out });
            },
            .f16 => {
                const half = self.allocB16();
                const out = self.allocF32();
                try self.line("    ld.shared.b16      %h{d}, [%r{d}+{d}];", .{ half, addr.reg, addr.imm });
                try self.line("    cvt.f32.f16        %f{d}, %h{d};", .{ out, half });
                try self.bind(result, .{ .f32 = out });
            },
            .bf16 => {
                const bits = self.allocU32();
                try self.line("    ld.shared.b16      %r{d}, [%r{d}+{d}];", .{ bits, addr.reg, addr.imm });
                try self.bind(result, .{ .f32 = try self.emitBf16BitsToF32(bits) });
            },
            .bool => {
                const byte = self.allocU32();
                const out = self.allocPred();
                try self.line("    ld.shared.u8       %r{d}, [%r{d}+{d}];", .{ byte, addr.reg, addr.imm });
                try self.line("    setp.ne.u32        %p{d}, %r{d}, 0;", .{ out, byte });
                try self.bind(result, .{ .pred = out });
            },
        }
    }

    fn emitNvptxGlobalLoad(self: *Emitter, op: NvptxDialect.LoadGlobalOp) EmitError!void {
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        switch (memref) {
            .ptr => |ptr_reg| {
                if (!isKernelParameterAddressSpace(info.addr_space)) return error.InvalidArtifact;
                if (isVec4F32Type(op.getResult().type)) {
                    if (info.element != .f32) return error.UnsupportedOperation;
                    const addr = try self.emitPointerAddress(ptr_reg, op.getIndex(), info.element);
                    const base = self.allocF32x4();
                    try self.line("    ld.global.v4.f32   {{%f{d}, %f{d}, %f{d}, %f{d}}}, [%rd{d}+{d}];", .{ base, base + 1, base + 2, base + 3, addr.reg, addr.imm });
                    try self.bind(op.getResult(), .{ .f32x4 = base });
                    return;
                }
                try self.emitPointerLoad("global", op.getResult(), ptr_reg, op.getIndex(), info.element);
            },
            else => return error.InvalidArtifact,
        }
    }

    fn emitNvptxSharedLoad(self: *Emitter, op: NvptxDialect.LoadSharedOp) EmitError!void {
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        switch (memref) {
            .shared => |shared| {
                if (info.addr_space != .shared) return error.InvalidArtifact;
                if (isVec4F32Type(op.getResult().type)) {
                    if (info.element != .f32) return error.UnsupportedOperation;
                    const addr = try self.emitSharedAddress(shared, op.getIndex(), info.element);
                    const base = self.allocF32x4();
                    try self.line("    ld.shared.v4.f32   {{%f{d}, %f{d}, %f{d}, %f{d}}}, [%r{d}+{d}];", .{ base, base + 1, base + 2, base + 3, addr.reg, addr.imm });
                    try self.bind(op.getResult(), .{ .f32x4 = base });
                    return;
                }
                try self.emitSharedLoad(op.getResult(), shared, op.getIndex(), info.element);
            },
            else => return error.InvalidArtifact,
        }
    }

    fn emitPointerStore(
        self: *Emitter,
        comptime space: []const u8,
        value: *ir.Value,
        ptr_reg: u32,
        index: *ir.Value,
        element: ScalarKind,
    ) EmitError!void {
        const addr = try self.emitPointerAddress(ptr_reg, index, element);
        switch (element) {
            .i8, .u8 => try self.line("    st." ++ space ++ ".u8       [%rd{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.asU32(try self.require(value)) }),
            .i16, .u16 => try self.line("    st." ++ space ++ ".u16      [%rd{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.asU32(try self.require(value)) }),
            .i64, .u64 => try self.line("    st." ++ space ++ ".u64      [%rd{d}+{d}], %rd{d};", .{ addr.reg, addr.imm, try self.asU64(try self.require(value)) }),
            .i32, .u32, .index => try self.line("    st." ++ space ++ ".u32      [%rd{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.asU32(try self.require(value)) }),
            .f32 => try self.line("    st." ++ space ++ ".f32      [%rd{d}+{d}], %f{d};", .{ addr.reg, addr.imm, try self.asF32(try self.require(value)) }),
            .f64 => try self.line("    st." ++ space ++ ".f64      [%rd{d}+{d}], %fd{d};", .{ addr.reg, addr.imm, try self.asF64(try self.require(value)) }),
            .f16 => {
                const half = self.allocB16();
                try self.line("    cvt.rn.f16.f32     %h{d}, %f{d};", .{ half, try self.asF32(try self.require(value)) });
                try self.line("    st." ++ space ++ ".b16      [%rd{d}+{d}], %h{d};", .{ addr.reg, addr.imm, half });
            },
            .bf16 => try self.line("    st." ++ space ++ ".b16      [%rd{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.emitF32ToBf16Bits(try self.require(value)) }),
            .bool => try self.line("    st." ++ space ++ ".u8       [%rd{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.emitBoolByte(try self.require(value)) }),
        }
    }

    fn emitSharedStore(self: *Emitter, value: *ir.Value, shared: u32, index: *ir.Value, element: ScalarKind) EmitError!void {
        const addr = try self.emitSharedAddress(shared, index, element);
        switch (element) {
            .i8, .u8 => try self.line("    st.shared.u8       [%r{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.asU32(try self.require(value)) }),
            .i16, .u16 => try self.line("    st.shared.u16      [%r{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.asU32(try self.require(value)) }),
            .i64, .u64 => try self.line("    st.shared.u64      [%r{d}+{d}], %rd{d};", .{ addr.reg, addr.imm, try self.asU64(try self.require(value)) }),
            .i32, .u32, .index => try self.line("    st.shared.u32      [%r{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.asU32(try self.require(value)) }),
            .f32 => try self.line("    st.shared.f32      [%r{d}+{d}], %f{d};", .{ addr.reg, addr.imm, try self.asF32(try self.require(value)) }),
            .f64 => try self.line("    st.shared.f64      [%r{d}+{d}], %fd{d};", .{ addr.reg, addr.imm, try self.asF64(try self.require(value)) }),
            .f16 => {
                const half = self.allocB16();
                try self.line("    cvt.rn.f16.f32     %h{d}, %f{d};", .{ half, try self.asF32(try self.require(value)) });
                try self.line("    st.shared.b16      [%r{d}+{d}], %h{d};", .{ addr.reg, addr.imm, half });
            },
            .bf16 => try self.line("    st.shared.b16      [%r{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.emitF32ToBf16Bits(try self.require(value)) }),
            .bool => try self.line("    st.shared.u8       [%r{d}+{d}], %r{d};", .{ addr.reg, addr.imm, try self.emitBoolByte(try self.require(value)) }),
        }
    }

    fn emitNvptxGlobalStore(self: *Emitter, op: NvptxDialect.StoreGlobalOp) EmitError!void {
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        switch (memref) {
            .ptr => |ptr_reg| {
                if (!isKernelParameterAddressSpace(info.addr_space)) return error.InvalidArtifact;
                const stored = try self.require(op.getValue());
                if (stored == .f32x4) {
                    if (info.element != .f32) return error.UnsupportedOperation;
                    const base = stored.f32x4;
                    const addr = try self.emitPointerAddress(ptr_reg, op.getIndex(), info.element);
                    try self.line("    st.global.v4.f32   [%rd{d}+{d}], {{%f{d}, %f{d}, %f{d}, %f{d}}};", .{ addr.reg, addr.imm, base, base + 1, base + 2, base + 3 });
                    return;
                }
                try self.emitPointerStore("global", op.getValue(), ptr_reg, op.getIndex(), info.element);
            },
            else => return error.InvalidArtifact,
        }
    }

    fn emitNvptxGlobalAtomic(self: *Emitter, op: NvptxDialect.AtomicGlobalOp) EmitError!void {
        const kind = op.getKind() orelse return error.InvalidArtifact;
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        const ptr_reg = switch (memref) {
            .ptr => |ptr_reg| ptr_reg,
            else => return error.InvalidArtifact,
        };
        if (!isKernelParameterAddressSpace(info.addr_space)) return error.InvalidArtifact;

        const addr = try self.emitPointerAddress(ptr_reg, op.getIndex(), info.element);

        switch (info.element) {
            .f32 => {
                if (kind != .add) return error.UnsupportedOperation;
                const operand = try self.asF32(try self.require(op.getValue()));
                if (op.getResult().hasNoUses()) {
                    try self.line("    red.global.add.f32  [%rd{d}+{d}], %f{d};", .{ addr.reg, addr.imm, operand });
                    return;
                }
                const out = self.allocF32();
                try self.line("    atom.global.add.f32 %f{d}, [%rd{d}+{d}], %f{d};", .{ out, addr.reg, addr.imm, operand });
                try self.bind(op.getResult(), .{ .f32 = out });
            },
            .i32, .u32, .index => {
                const suffix = try atomicIntegerSuffix(kind, info.element);
                const operand = try self.asU32(try self.require(op.getValue()));
                if (op.getResult().hasNoUses() and atomicKindSupportsRed(kind)) {
                    try self.line("    red.global.{s}  [%rd{d}+{d}], %r{d};", .{ suffix, addr.reg, addr.imm, operand });
                    return;
                }
                const out = self.allocU32();
                try self.line("    atom.global.{s} %r{d}, [%rd{d}+{d}], %r{d};", .{ suffix, out, addr.reg, addr.imm, operand });
                try self.bind(op.getResult(), intValueForKind(info.element, out));
            },
            .i8, .i16, .u8, .u16, .i64, .u64, .f16, .bf16, .f64, .bool => return error.UnsupportedOperation,
        }
    }

    fn emitNvptxSharedAtomic(self: *Emitter, op: NvptxDialect.AtomicSharedOp) EmitError!void {
        const kind = op.getKind() orelse return error.InvalidArtifact;
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        const shared = switch (memref) {
            .shared => |shared| shared,
            else => return error.InvalidArtifact,
        };
        if (info.addr_space != .shared) return error.InvalidArtifact;

        const addr = try self.emitSharedAddress(shared, op.getIndex(), info.element);

        switch (info.element) {
            .f32 => {
                if (kind != .add) return error.UnsupportedOperation;
                const operand = try self.asF32(try self.require(op.getValue()));
                if (op.getResult().hasNoUses()) {
                    try self.line("    red.shared.add.f32  [%r{d}+{d}], %f{d};", .{ addr.reg, addr.imm, operand });
                    return;
                }
                const out = self.allocF32();
                try self.line("    atom.shared.add.f32 %f{d}, [%r{d}+{d}], %f{d};", .{ out, addr.reg, addr.imm, operand });
                try self.bind(op.getResult(), .{ .f32 = out });
            },
            .i32, .u32, .index => {
                const suffix = try atomicIntegerSuffix(kind, info.element);
                const operand = try self.asU32(try self.require(op.getValue()));
                if (op.getResult().hasNoUses() and atomicKindSupportsRed(kind)) {
                    try self.line("    red.shared.{s}  [%r{d}+{d}], %r{d};", .{ suffix, addr.reg, addr.imm, operand });
                    return;
                }
                const out = self.allocU32();
                try self.line("    atom.shared.{s} %r{d}, [%r{d}+{d}], %r{d};", .{ suffix, out, addr.reg, addr.imm, operand });
                try self.bind(op.getResult(), intValueForKind(info.element, out));
            },
            .i8, .i16, .u8, .u16, .i64, .u64, .f16, .bf16, .f64, .bool => return error.UnsupportedOperation,
        }
    }

    fn emitNvptxGlobalAtomicCas(self: *Emitter, op: NvptxDialect.AtomicCasGlobalOp) EmitError!void {
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        const ptr_reg = switch (memref) {
            .ptr => |ptr_reg| ptr_reg,
            else => return error.InvalidArtifact,
        };
        if (!isKernelParameterAddressSpace(info.addr_space)) return error.InvalidArtifact;

        const addr = try self.emitPointerAddress(ptr_reg, op.getIndex(), info.element);

        switch (info.element) {
            .i32, .u32, .index => {
                const expected = try self.asU32(try self.require(op.getExpected()));
                const desired = try self.asU32(try self.require(op.getDesired()));
                const out = self.allocU32();
                try self.line("    atom.global.cas.b32 %r{d}, [%rd{d}+{d}], %r{d}, %r{d};", .{ out, addr.reg, addr.imm, expected, desired });
                try self.bind(op.getResult(), intValueForKind(info.element, out));
            },
            .i8, .i16, .u8, .u16, .i64, .u64, .f16, .bf16, .f32, .f64, .bool => return error.UnsupportedOperation,
        }
    }

    fn emitNvptxSharedAtomicCas(self: *Emitter, op: NvptxDialect.AtomicCasSharedOp) EmitError!void {
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        const shared = switch (memref) {
            .shared => |shared| shared,
            else => return error.InvalidArtifact,
        };
        if (info.addr_space != .shared) return error.InvalidArtifact;

        const addr = try self.emitSharedAddress(shared, op.getIndex(), info.element);

        switch (info.element) {
            .i32, .u32, .index => {
                const expected = try self.asU32(try self.require(op.getExpected()));
                const desired = try self.asU32(try self.require(op.getDesired()));
                const out = self.allocU32();
                try self.line("    atom.shared.cas.b32 %r{d}, [%r{d}+{d}], %r{d}, %r{d};", .{ out, addr.reg, addr.imm, expected, desired });
                try self.bind(op.getResult(), intValueForKind(info.element, out));
            },
            .i8, .i16, .u8, .u16, .i64, .u64, .f16, .bf16, .f32, .f64, .bool => return error.UnsupportedOperation,
        }
    }

    fn emitNvptxSharedStore(self: *Emitter, op: NvptxDialect.StoreSharedOp) EmitError!void {
        const memref = try self.require(op.getMemref());
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        switch (memref) {
            .shared => |shared| {
                if (info.addr_space != .shared) return error.InvalidArtifact;
                const stored = try self.require(op.getValue());
                if (stored == .f32x4) {
                    if (info.element != .f32) return error.UnsupportedOperation;
                    const base = stored.f32x4;
                    const addr = try self.emitSharedAddress(shared, op.getIndex(), info.element);
                    try self.line("    st.shared.v4.f32   [%r{d}+{d}], {{%f{d}, %f{d}, %f{d}, %f{d}}};", .{ addr.reg, addr.imm, base, base + 1, base + 2, base + 3 });
                    return;
                }
                try self.emitSharedStore(op.getValue(), shared, op.getIndex(), info.element);
            },
            else => return error.InvalidArtifact,
        }
    }

    fn emitBoolByte(self: *Emitter, value: Value) EmitError!u32 {
        const pred = try self.asPred(value);
        const one = self.allocU32();
        const zero = self.allocU32();
        const out = self.allocU32();
        try self.line("    mov.u32            %r{d}, 1;", .{one});
        try self.line("    mov.u32            %r{d}, 0;", .{zero});
        try self.line("    selp.u32           %r{d}, %r{d}, %r{d}, %p{d};", .{ out, one, zero, pred });
        return out;
    }

    fn emitSharedAddress(self: *Emitter, shared: u32, index: *ir.Value, element: ScalarKind) EmitError!AddressParts {
        const bytes: u32 = elementByteSize(element);
        const shared_byte_offset = self.shared_byte_offsets.get(shared) orelse 0;
        var peeled = peelIndexOffset(index);
        var imm = std.math.mul(i64, peeled.offset, @as(i64, bytes)) catch return error.InvalidArtifact;
        imm = std.math.add(i64, imm, @as(i64, shared_byte_offset)) catch return error.InvalidArtifact;
        if (imm > max_address_immediate or imm < -max_address_immediate) {
            peeled = .{ .base = index, .offset = 0 };
            imm = shared_byte_offset;
        }
        if (imm > max_address_immediate or imm < -max_address_immediate) return error.InvalidArtifact;
        const key = AddressBaseKey{
            .space = shared,
            .base = if (peeled.base) |base| @intFromPtr(base) else 0,
            .bytes = bytes,
        };
        if (self.shared_bases.get(key)) |reg| return .{ .reg = reg, .imm = imm };
        const addr = self.allocU32();
        if (peeled.base) |base_value| {
            const base_reg = try self.asU32(try self.require(base_value));
            const offset_reg = self.allocU32();
            try self.line("    mul.lo.u32         %r{d}, %r{d}, {d};", .{ offset_reg, base_reg, bytes });
            try self.emitSharedBaseMove(addr, shared);
            try self.line("    add.u32            %r{d}, %r{d}, %r{d};", .{ addr, addr, offset_reg });
        } else {
            try self.emitSharedBaseMove(addr, shared);
        }
        self.shared_bases.put(self.allocator, key, addr) catch return error.OutOfMemory;
        return .{ .reg = addr, .imm = imm };
    }

    fn emitSharedBaseMove(self: *Emitter, addr: u32, shared: u32) EmitError!void {
        if (self.shared_byte_offsets.contains(shared)) {
            try self.line("    mov.u32            %r{d}, __choir_dynamic_shared;", .{addr});
        } else {
            try self.line("    mov.u32            %r{d}, __choir_shared{d};", .{ addr, shared });
        }
    }

    fn emitPointerAddress(self: *Emitter, ptr_reg: u32, index: *ir.Value, element: ScalarKind) EmitError!AddressParts {
        const bytes: u32 = elementByteSize(element);
        var peeled = peelIndexOffset(index);
        var imm = std.math.mul(i64, peeled.offset, bytes) catch overflow: {
            peeled = .{ .base = index, .offset = 0 };
            break :overflow 0;
        };
        if (imm > max_address_immediate or imm < -max_address_immediate) {
            peeled = .{ .base = index, .offset = 0 };
            imm = 0;
        }
        const base_value = peeled.base orelse return .{ .reg = ptr_reg, .imm = imm };
        const key = AddressBaseKey{
            .space = ptr_reg,
            .base = @intFromPtr(base_value),
            .bytes = bytes,
        };
        if (self.pointer_bases.get(key)) |reg| return .{ .reg = reg, .imm = imm };
        const base = try self.require(base_value);
        const offset_reg = self.allocPtr();
        const addr = self.allocPtr();
        switch (base) {
            .u64 => |reg| try self.line("    mul.lo.u64 %rd{d}, %rd{d}, {d};", .{
                offset_reg, reg, bytes,
            }),
            .s32 => |reg| try self.line("    mul.wide.s32 %rd{d}, %r{d}, {d};", .{
                offset_reg, reg, bytes,
            }),
            .u32 => |reg| try self.line("    mul.wide.u32       %rd{d}, %r{d}, {d};", .{
                offset_reg, reg, bytes,
            }),
            else => return error.UnsupportedOperation,
        }
        try self.line("    add.s64            %rd{d}, %rd{d}, %rd{d};", .{ addr, ptr_reg, offset_reg });
        self.pointer_bases.put(self.allocator, key, addr) catch return error.OutOfMemory;
        return .{ .reg = addr, .imm = imm };
    }

    fn emitConstant(self: *Emitter, op: ArithDialect.ConstantOp) EmitError!void {
        const result = op.getResult();
        switch (try computeKind(result.type)) {
            .index => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                const out = self.allocU32();
                try self.line("    mov.u32            %r{d}, {d};", .{ out, @as(u32, @bitCast(@as(i32, @intCast(value)))) });
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                const out = self.allocU32();
                try self.line("    mov.u32            %r{d}, {d};", .{ out, @as(u32, @bitCast(@as(i32, @intCast(value)))) });
                try self.bind(result, .{ .s32 = out });
            },
            .u8, .u16, .u32 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                const out = self.allocU32();
                const narrowed = std.math.cast(u32, value) orelse return error.InvalidArtifact;
                try self.line("    mov.u32            %r{d}, {d};", .{ out, narrowed });
                try self.bind(result, .{ .u32 = out });
            },
            .i64 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                const out = self.allocU64();
                try self.line("    mov.u64            %rd{d}, {d};", .{ out, @as(u64, @bitCast(value)) });
                try self.bind(result, .{ .u64 = out });
            },
            .u64 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                const out = self.allocU64();
                const narrowed = std.math.cast(u64, value) orelse return error.InvalidArtifact;
                try self.line("    mov.u64            %rd{d}, {d};", .{ out, narrowed });
                try self.bind(result, .{ .u64 = out });
            },
            .f32 => {
                const value = op.getFloatValue() orelse return error.InvalidArtifact;
                const out = self.allocF32();
                try self.line("    mov.f32            %f{d}, 0f{X:0>8};", .{ out, f32Bits(value) });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const value = op.getFloatValue() orelse return error.InvalidArtifact;
                const out = self.allocF64();
                try self.line("    mov.f64            %fd{d}, 0d{X:0>16};", .{ out, f64Bits(value) });
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => unreachable,
            .bool => {
                const bool_attr = op.op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse return error.InvalidArtifact;
                const out = self.allocPred();
                const source: u32 = if (bool_attr.getValue()) 1 else 0;
                try self.line("    setp.ne.u32        %p{d}, {d}, 0;", .{ out, source });
                try self.bind(result, .{ .pred = out });
            },
        }
    }

    fn emitBinary(self: *Emitter, op: *ir.Operation, comptime instruction: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const lhs = try self.require(op.operands.items[0].value);
        const rhs = try self.require(op.operands.items[1].value);
        switch (try computeKind(result.type)) {
            .index, .u8, .u16, .u32 => {
                const out = self.allocU32();
                if (std.mem.eql(u8, instruction, "mul")) {
                    try self.line("    mul.lo.u32         %r{d}, %r{d}, %r{d};", .{ out, try self.asU32(lhs), try self.asU32(rhs) });
                } else if (std.mem.eql(u8, instruction, "max") or std.mem.eql(u8, instruction, "min")) {
                    try self.line("    {s}.u32            %r{d}, %r{d}, %r{d};", .{ instruction, out, try self.asU32(lhs), try self.asU32(rhs) });
                } else {
                    try self.line("    {s}.u32            %r{d}, %r{d}, %r{d};", .{ instruction, out, try self.asU32(lhs), try self.asU32(rhs) });
                }
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                if (std.mem.eql(u8, instruction, "mul")) {
                    try self.line("    mul.lo.u32         %r{d}, %r{d}, %r{d};", .{ out, try self.asU32(lhs), try self.asU32(rhs) });
                } else if (std.mem.eql(u8, instruction, "max") or std.mem.eql(u8, instruction, "min")) {
                    try self.line("    {s}.s32            %r{d}, %r{d}, %r{d};", .{ instruction, out, try self.asU32(lhs), try self.asU32(rhs) });
                } else {
                    try self.line("    {s}.u32            %r{d}, %r{d}, %r{d};", .{ instruction, out, try self.asU32(lhs), try self.asU32(rhs) });
                }
                try self.bind(result, .{ .s32 = out });
            },
            .i64 => {
                const out = self.allocU64();
                if (std.mem.eql(u8, instruction, "mul")) {
                    try self.line("    mul.lo.u64         %rd{d}, %rd{d}, %rd{d};", .{ out, try self.asU64(lhs), try self.asU64(rhs) });
                } else if (std.mem.eql(u8, instruction, "max") or std.mem.eql(u8, instruction, "min")) {
                    try self.line("    {s}.s64            %rd{d}, %rd{d}, %rd{d};", .{ instruction, out, try self.asU64(lhs), try self.asU64(rhs) });
                } else {
                    try self.line("    {s}.u64            %rd{d}, %rd{d}, %rd{d};", .{ instruction, out, try self.asU64(lhs), try self.asU64(rhs) });
                }
                try self.bind(result, .{ .u64 = out });
            },
            .u64 => {
                const out = self.allocU64();
                if (std.mem.eql(u8, instruction, "mul")) {
                    try self.line("    mul.lo.u64         %rd{d}, %rd{d}, %rd{d};", .{ out, try self.asU64(lhs), try self.asU64(rhs) });
                } else if (std.mem.eql(u8, instruction, "max") or std.mem.eql(u8, instruction, "min")) {
                    try self.line("    {s}.u64            %rd{d}, %rd{d}, %rd{d};", .{ instruction, out, try self.asU64(lhs), try self.asU64(rhs) });
                } else {
                    try self.line("    {s}.u64            %rd{d}, %rd{d}, %rd{d};", .{ instruction, out, try self.asU64(lhs), try self.asU64(rhs) });
                }
                try self.bind(result, .{ .u64 = out });
            },
            .f32 => {
                const out = self.allocF32();
                try self.line("    {s}.f32            %f{d}, %f{d}, %f{d};", .{ instruction, out, try self.asF32(lhs), try self.asF32(rhs) });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                try self.line("    {s}.f64            %fd{d}, %fd{d}, %fd{d};", .{ instruction, out, try self.asF64(lhs), try self.asF64(rhs) });
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => unreachable,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitUmulhi(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const lhs = try self.require(op.operands.items[0].value);
        const rhs = try self.require(op.operands.items[1].value);
        switch (try computeKind(result.type)) {
            .index, .i8, .i16, .i32, .u8, .u16, .u32 => {
                const out = self.allocU32();
                try self.line("    mul.hi.u32         %r{d}, %r{d}, %r{d};", .{ out, try self.asU32(lhs), try self.asU32(rhs) });
                try self.bind(result, intValueForKind(try computeKind(result.type), out));
            },
            .i64, .u64 => {
                const out = self.allocU64();
                try self.line("    mul.hi.u64         %rd{d}, %rd{d}, %rd{d};", .{ out, try self.asU64(lhs), try self.asU64(rhs) });
                try self.bind(result, .{ .u64 = out });
            },
            .f32, .f16, .bf16, .f64, .bool => return error.UnsupportedOperation,
        }
    }

    fn emitNeg(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const input = try self.require(op.operands.items[0].value);
        switch (try computeKind(result.type)) {
            .i64, .u64 => {
                const out = self.allocU64();
                try self.line("    neg.s64            %rd{d}, %rd{d};", .{ out, try self.asU64(input) });
                try self.bind(result, .{ .u64 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                try self.line("    neg.s32            %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .s32 = out });
            },
            .u8, .u16, .u32, .index => {
                const out = self.allocU32();
                try self.line("    neg.s32            %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .u32 = out });
            },
            .f32 => {
                const out = self.allocF32();
                try self.line("    neg.f32            %f{d}, %f{d};", .{ out, try self.asF32(input) });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                try self.line("    neg.f64            %fd{d}, %fd{d};", .{ out, try self.asF64(input) });
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => unreachable,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitDiv(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const lhs = try self.require(op.operands.items[0].value);
        const rhs = try self.require(op.operands.items[1].value);
        switch (try computeKind(result.type)) {
            .i64 => {
                const out = self.allocU64();
                try self.line("    div.s64            %rd{d}, %rd{d}, %rd{d};", .{ out, try self.asU64(lhs), try self.asU64(rhs) });
                try self.bind(result, .{ .u64 = out });
            },
            .u64 => {
                const out = self.allocU64();
                try self.line("    div.u64            %rd{d}, %rd{d}, %rd{d};", .{ out, try self.asU64(lhs), try self.asU64(rhs) });
                try self.bind(result, .{ .u64 = out });
            },
            .index, .u8, .u16, .u32 => {
                const out = self.allocU32();
                try self.line("    div.u32            %r{d}, %r{d}, %r{d};", .{ out, try self.asU32(lhs), try self.asU32(rhs) });
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                try self.line("    div.s32            %r{d}, %r{d}, %r{d};", .{ out, try self.asU32(lhs), try self.asU32(rhs) });
                try self.bind(result, .{ .s32 = out });
            },
            .f32 => {
                const out = self.allocF32();
                try self.line("    div.approx.f32     %f{d}, %f{d}, %f{d};", .{ out, try self.asF32(lhs), try self.asF32(rhs) });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                try self.line("    div.rn.f64         %fd{d}, %fd{d}, %fd{d};", .{ out, try self.asF64(lhs), try self.asF64(rhs) });
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => unreachable,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitAbs(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const input = try self.require(op.operands.items[0].value);
        switch (try computeKind(result.type)) {
            .i64 => {
                const out = self.allocU64();
                try self.line("    abs.s64            %rd{d}, %rd{d};", .{ out, try self.asU64(input) });
                try self.bind(result, .{ .u64 = out });
            },
            .u64 => {
                const out = self.allocU64();
                try self.line("    mov.u64            %rd{d}, %rd{d};", .{ out, try self.asU64(input) });
                try self.bind(result, .{ .u64 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                try self.line("    abs.s32            %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .s32 = out });
            },
            .u8, .u16, .u32, .index => {
                const out = self.allocU32();
                try self.line("    mov.u32            %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .u32 = out });
            },
            .f32 => {
                const out = self.allocF32();
                try self.line("    abs.f32            %f{d}, %f{d};", .{ out, try self.asF32(input) });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                try self.line("    abs.f64            %fd{d}, %fd{d};", .{ out, try self.asF64(input) });
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => unreachable,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitFloatUnary(self: *Emitter, op: *ir.Operation, comptime instruction: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        if ((try computeKind(result.type)) != .f32) return error.UnsupportedOperation;
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const out = self.allocF32();
        try self.line("    {s}.f32            %f{d}, %f{d};", .{ instruction, out, input });
        try self.bind(result, .{ .f32 = out });
    }

    fn emitFloatIntegralUnary(self: *Emitter, op: *ir.Operation, comptime instruction: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        if ((try computeKind(result.type)) != .f32) return error.UnsupportedOperation;
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const out = self.allocF32();
        try self.line("    {s}.f32.f32        %f{d}, %f{d};", .{ instruction, out, input });
        try self.bind(result, .{ .f32 = out });
    }

    fn emitRound(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        if ((try computeKind(result.type)) != .f32) return error.UnsupportedOperation;
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const abs_value = self.allocF32();
        const shifted = self.allocF32();
        const rounded_abs = self.allocF32();
        const input_bits = self.allocU32();
        const sign_mask = self.allocU32();
        const sign_bits = self.allocU32();
        const rounded_bits = self.allocU32();
        const magnitude_mask = self.allocU32();
        const magnitude_bits = self.allocU32();
        const result_bits = self.allocU32();
        const out = self.allocF32();
        try self.line("    abs.f32            %f{d}, %f{d};", .{ abs_value, input });
        try self.line("    add.f32            %f{d}, %f{d}, 0f3F000000;", .{ shifted, abs_value });
        try self.line("    cvt.rmi.f32.f32    %f{d}, %f{d};", .{ rounded_abs, shifted });
        try self.line("    mov.b32            %r{d}, %f{d};", .{ input_bits, input });
        try self.line("    mov.u32            %r{d}, 2147483648;", .{sign_mask});
        try self.line("    and.b32            %r{d}, %r{d}, %r{d};", .{ sign_bits, input_bits, sign_mask });
        try self.line("    mov.b32            %r{d}, %f{d};", .{ rounded_bits, rounded_abs });
        try self.line("    mov.u32            %r{d}, 2147483647;", .{magnitude_mask});
        try self.line("    and.b32            %r{d}, %r{d}, %r{d};", .{ magnitude_bits, rounded_bits, magnitude_mask });
        try self.line("    or.b32             %r{d}, %r{d}, %r{d};", .{ result_bits, magnitude_bits, sign_bits });
        try self.line("    mov.b32            %f{d}, %r{d};", .{ out, result_bits });
        try self.bind(result, .{ .f32 = out });
    }

    fn emitCompare(self: *Emitter, op: ArithDialect.CmpOp) EmitError!void {
        const result = op.getResult();
        const lhs = try self.require(op.op.operands.items[0].value);
        const rhs = try self.require(op.op.operands.items[1].value);
        const pred = op.getPredicate() orelse return error.InvalidArtifact;
        const out = self.allocPred();
        switch (try computeKind(op.op.operands.items[0].value.type)) {
            .index, .u8, .u16, .u32 => try self.line("    setp.{s}.u32        %p{d}, %r{d}, %r{d};", .{ ptxPredicate(pred), out, try self.asU32(lhs), try self.asU32(rhs) }),
            .i8, .i16, .i32 => try self.line("    setp.{s}.s32        %p{d}, %r{d}, %r{d};", .{ ptxPredicate(pred), out, try self.asU32(lhs), try self.asU32(rhs) }),
            .i64 => try self.line("    setp.{s}.s64        %p{d}, %rd{d}, %rd{d};", .{ ptxPredicate(pred), out, try self.asU64(lhs), try self.asU64(rhs) }),
            .u64 => try self.line("    setp.{s}.u64        %p{d}, %rd{d}, %rd{d};", .{ ptxPredicate(pred), out, try self.asU64(lhs), try self.asU64(rhs) }),
            .f32 => try self.line("    setp.{s}.f32        %p{d}, %f{d}, %f{d};", .{ ptxFloatPredicate(pred), out, try self.asF32(lhs), try self.asF32(rhs) }),
            .f64 => try self.line("    setp.{s}.f64        %p{d}, %fd{d}, %fd{d};", .{ ptxFloatPredicate(pred), out, try self.asF64(lhs), try self.asF64(rhs) }),
            .f16, .bf16 => unreachable,
            .bool => return error.UnsupportedOperation,
        }
        try self.bind(result, .{ .pred = out });
    }

    fn emitSelect(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const cond = try self.asPred(try self.require(op.operands.items[0].value));
        const true_value = try self.require(op.operands.items[1].value);
        const false_value = try self.require(op.operands.items[2].value);
        switch (try computeKind(result.type)) {
            .index, .u8, .u16, .u32 => {
                const out = self.allocU32();
                try self.line("    selp.u32           %r{d}, %r{d}, %r{d}, %p{d};", .{ out, try self.asU32(true_value), try self.asU32(false_value), cond });
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                try self.line("    selp.u32           %r{d}, %r{d}, %r{d}, %p{d};", .{ out, try self.asU32(true_value), try self.asU32(false_value), cond });
                try self.bind(result, .{ .s32 = out });
            },
            .i64, .u64 => {
                const out = self.allocU64();
                try self.line("    selp.b64           %rd{d}, %rd{d}, %rd{d}, %p{d};", .{ out, try self.asU64(true_value), try self.asU64(false_value), cond });
                try self.bind(result, .{ .u64 = out });
            },
            .f32 => {
                const out = self.allocF32();
                try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ out, try self.asF32(true_value), try self.asF32(false_value), cond });
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                try self.line("    selp.f64           %fd{d}, %fd{d}, %fd{d}, %p{d};", .{ out, try self.asF64(true_value), try self.asF64(false_value), cond });
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => unreachable,
            .bool => {
                const inverted = self.allocPred();
                const true_taken = self.allocPred();
                const false_taken = self.allocPred();
                const out = self.allocPred();
                try self.line("    not.pred           %p{d}, %p{d};", .{ inverted, cond });
                try self.line("    and.pred           %p{d}, %p{d}, %p{d};", .{ true_taken, try self.asPred(true_value), cond });
                try self.line("    and.pred           %p{d}, %p{d}, %p{d};", .{ false_taken, try self.asPred(false_value), inverted });
                try self.line("    or.pred            %p{d}, %p{d}, %p{d};", .{ out, true_taken, false_taken });
                try self.bind(result, .{ .pred = out });
            },
        }
    }

    fn emitCast(self: *Emitter, op: ArithDialect.CastOp) EmitError!void {
        const input = try self.require(op.getInput());
        const result = op.getResult();
        switch (try computeKind(result.type)) {
            .index, .u8, .u16, .u32 => {
                const out = self.allocU32();
                switch (input) {
                    .u32, .s32 => try self.line("    mov.u32            %r{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u64 => try self.line("    cvt.u32.u64        %r{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    .pred => |pred| {
                        const one = self.allocU32();
                        const zero = self.allocU32();
                        try self.line("    mov.u32            %r{d}, 1;", .{one});
                        try self.line("    mov.u32            %r{d}, 0;", .{zero});
                        try self.line("    selp.u32           %r{d}, %r{d}, %r{d}, %p{d};", .{ out, one, zero, pred });
                    },
                    .f32 => try self.line("    cvt.rzi.u32.f32    %r{d}, %f{d};", .{ out, try self.asF32(input) }),
                    .f64 => try self.line("    cvt.rzi.u32.f64    %r{d}, %fd{d};", .{ out, try self.asF64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                switch (input) {
                    .u32, .s32 => try self.line("    mov.u32            %r{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u64 => try self.line("    cvt.u32.u64        %r{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    .pred => |pred| {
                        const one = self.allocU32();
                        const zero = self.allocU32();
                        try self.line("    mov.u32            %r{d}, 1;", .{one});
                        try self.line("    mov.u32            %r{d}, 0;", .{zero});
                        try self.line("    selp.u32           %r{d}, %r{d}, %r{d}, %p{d};", .{ out, one, zero, pred });
                    },
                    .f32 => try self.line("    cvt.rzi.s32.f32    %r{d}, %f{d};", .{ out, try self.asF32(input) }),
                    .f64 => try self.line("    cvt.rzi.s32.f64    %r{d}, %fd{d};", .{ out, try self.asF64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .s32 = out });
            },
            .i64 => {
                const out = self.allocU64();
                switch (input) {
                    .s32 => try self.line("    cvt.s64.s32        %rd{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u32 => try self.line("    cvt.u64.u32        %rd{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u64 => try self.line("    mov.u64            %rd{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .u64 = out });
            },
            .u64 => {
                const out = self.allocU64();
                switch (input) {
                    .s32 => try self.line("    cvt.u64.s32        %rd{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u32 => try self.line("    cvt.u64.u32        %rd{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u64 => try self.line("    mov.u64            %rd{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    .pred => |pred| {
                        const one = self.allocU64();
                        const zero = self.allocU64();
                        try self.line("    mov.u64            %rd{d}, 1;", .{one});
                        try self.line("    mov.u64            %rd{d}, 0;", .{zero});
                        try self.line("    selp.b64           %rd{d}, %rd{d}, %rd{d}, %p{d};", .{ out, one, zero, pred });
                    },
                    .f32 => try self.line("    cvt.rzi.u64.f32    %rd{d}, %f{d};", .{ out, try self.asF32(input) }),
                    .f64 => try self.line("    cvt.rzi.u64.f64    %rd{d}, %fd{d};", .{ out, try self.asF64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .u64 = out });
            },
            .f32 => {
                const out = self.allocF32();
                switch (input) {
                    .u32 => try self.line("    cvt.rn.f32.u32     %f{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .s32 => try self.line("    cvt.rn.f32.s32     %f{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u64 => try self.line("    cvt.rn.f32.u64     %f{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    .f32 => try self.line("    mov.f32            %f{d}, %f{d};", .{ out, try self.asF32(input) }),
                    .f64 => try self.line("    cvt.rn.f32.f64     %f{d}, %fd{d};", .{ out, try self.asF64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                switch (input) {
                    .u32 => try self.line("    cvt.rn.f64.u32     %fd{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .s32 => try self.line("    cvt.rn.f64.s32     %fd{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .u64 => try self.line("    cvt.rn.f64.u64     %fd{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    .f32 => try self.line("    cvt.rn.f64.f32     %fd{d}, %f{d};", .{ out, try self.asF32(input) }),
                    .f64 => try self.line("    mov.f64            %fd{d}, %fd{d};", .{ out, try self.asF64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => unreachable,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitBitcast(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const input = try self.require(op.operands.items[0].value);
        switch (try scalarKind(result.type)) {
            .i8, .i16 => {
                const out = self.allocU32();
                switch (input) {
                    .u32, .s32 => try self.line("    mov.b32            %r{d}, %r{d};", .{ out, try self.asU32(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .s32 = out });
            },
            .u8, .u16 => {
                const out = self.allocU32();
                switch (input) {
                    .u32, .s32 => try self.line("    mov.b32            %r{d}, %r{d};", .{ out, try self.asU32(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .u32 = out });
            },
            .i64, .u64 => {
                const out = self.allocU64();
                switch (input) {
                    .u64 => try self.line("    mov.b64            %rd{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    .f64 => try self.line("    mov.b64            %rd{d}, %fd{d};", .{ out, try self.asF64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .u64 = out });
            },
            .index, .u32 => {
                const out = self.allocU32();
                switch (input) {
                    .u32, .s32 => try self.line("    mov.b32            %r{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .f32 => try self.line("    mov.b32            %r{d}, %f{d};", .{ out, try self.asF32(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .u32 = out });
            },
            .i32 => {
                const out = self.allocU32();
                switch (input) {
                    .u32, .s32 => try self.line("    mov.b32            %r{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .f32 => try self.line("    mov.b32            %r{d}, %f{d};", .{ out, try self.asF32(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .s32 = out });
            },
            .f32 => {
                const out = self.allocF32();
                switch (input) {
                    .u32, .s32 => try self.line("    mov.b32            %f{d}, %r{d};", .{ out, try self.asU32(input) }),
                    .f32 => try self.line("    mov.b32            %f{d}, %f{d};", .{ out, try self.asF32(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .f32 = out });
            },
            .f64 => {
                const out = self.allocF64();
                switch (input) {
                    .u64 => try self.line("    mov.b64            %fd{d}, %rd{d};", .{ out, try self.asU64(input) }),
                    .f64 => try self.line("    mov.b64            %fd{d}, %fd{d};", .{ out, try self.asF64(input) }),
                    else => return error.UnsupportedOperation,
                }
                try self.bind(result, .{ .f64 = out });
            },
            .f16, .bf16 => return error.UnsupportedOperation,
            .bool => return error.UnsupportedOperation,
        }
    }

    fn emitBitwise(self: *Emitter, op: *ir.Operation, comptime instruction: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const lhs = try self.require(op.operands.items[0].value);
        const rhs = try self.require(op.operands.items[1].value);
        switch (try scalarKind(result.type)) {
            .index, .u8, .u16, .u32 => {
                const out = self.allocU32();
                try self.line("    {s}.b32            %r{d}, %r{d}, %r{d};", .{ instruction, out, try self.asU32(lhs), try self.asU32(rhs) });
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                try self.line("    {s}.b32            %r{d}, %r{d}, %r{d};", .{ instruction, out, try self.asU32(lhs), try self.asU32(rhs) });
                try self.bind(result, .{ .s32 = out });
            },
            .i64, .u64 => {
                const out = self.allocU64();
                try self.line("    {s}.b64            %rd{d}, %rd{d}, %rd{d};", .{ instruction, out, try self.asU64(lhs), try self.asU64(rhs) });
                try self.bind(result, .{ .u64 = out });
            },
            .f16, .bf16 => return error.UnsupportedOperation,
            .bool => {
                const out = self.allocPred();
                try self.line("    {s}.pred           %p{d}, %p{d}, %p{d};", .{ instruction, out, try self.asPred(lhs), try self.asPred(rhs) });
                try self.bind(result, .{ .pred = out });
            },
            .f32, .f64 => return error.UnsupportedOperation,
        }
    }

    fn emitPopCount(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const input = try self.require(op.operands.items[0].value);
        switch (try scalarKind(result.type)) {
            .index, .u8, .u16, .u32 => {
                const out = self.allocU32();
                try self.line("    popc.b32           %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                try self.line("    popc.b32           %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .s32 = out });
            },
            .i64, .u64 => {
                const out = self.allocU32();
                try self.line("    popc.b64           %r{d}, %rd{d};", .{ out, try self.asU64(input) });
                const widened = self.allocU64();
                try self.line("    cvt.u64.u32        %rd{d}, %r{d};", .{ widened, out });
                try self.bind(result, .{ .u64 = widened });
            },
            else => return error.UnsupportedOperation,
        }
    }

    fn emitNot(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const input = try self.require(op.operands.items[0].value);
        switch (try scalarKind(result.type)) {
            .index, .u8, .u16, .u32 => {
                const out = self.allocU32();
                try self.line("    not.b32            %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const out = self.allocU32();
                try self.line("    not.b32            %r{d}, %r{d};", .{ out, try self.asU32(input) });
                try self.bind(result, .{ .s32 = out });
            },
            .i64, .u64 => {
                const out = self.allocU64();
                try self.line("    not.b64            %rd{d}, %rd{d};", .{ out, try self.asU64(input) });
                try self.bind(result, .{ .u64 = out });
            },
            .f16, .bf16 => return error.UnsupportedOperation,
            .bool => {
                const out = self.allocPred();
                try self.line("    not.pred           %p{d}, %p{d};", .{ out, try self.asPred(input) });
                try self.bind(result, .{ .pred = out });
            },
            .f32, .f64 => return error.UnsupportedOperation,
        }
    }

    fn emitShift(self: *Emitter, op: *ir.Operation, comptime instruction: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        switch (try scalarKind(result.type)) {
            .index, .u8, .u16, .u32 => {
                const value = try self.asU32(try self.require(op.operands.items[0].value));
                const shift = try self.asU32(try self.require(op.operands.items[1].value));
                const out = self.allocU32();
                try self.line("    {s}            %r{d}, %r{d}, %r{d};", .{ instruction, out, value, shift });
                try self.bind(result, .{ .u32 = out });
            },
            .i8, .i16, .i32 => {
                const value = try self.asU32(try self.require(op.operands.items[0].value));
                const shift = try self.asU32(try self.require(op.operands.items[1].value));
                const out = self.allocU32();
                try self.line("    {s}            %r{d}, %r{d}, %r{d};", .{ instruction, out, value, shift });
                try self.bind(result, .{ .s32 = out });
            },
            .i64 => {
                const value = try self.asU64(try self.require(op.operands.items[0].value));
                const shift = try self.asU64(try self.require(op.operands.items[1].value));
                const amount = self.allocU32();
                try self.line("    cvt.u32.u64        %r{d}, %rd{d};", .{ amount, shift });
                const mnemonic = comptime wideShiftMnemonic(instruction, true);
                const out = self.allocU64();
                try self.line("    {s}            %rd{d}, %rd{d}, %r{d};", .{ mnemonic, out, value, amount });
                try self.bind(result, .{ .u64 = out });
            },
            .u64 => {
                const value = try self.asU64(try self.require(op.operands.items[0].value));
                const shift = try self.asU64(try self.require(op.operands.items[1].value));
                const amount = self.allocU32();
                try self.line("    cvt.u32.u64        %r{d}, %rd{d};", .{ amount, shift });
                const mnemonic = comptime wideShiftMnemonic(instruction, false);
                const out = self.allocU64();
                try self.line("    {s}            %rd{d}, %rd{d}, %r{d};", .{ mnemonic, out, value, amount });
                try self.bind(result, .{ .u64 = out });
            },
            else => return error.UnsupportedOperation,
        }
    }

    fn wideShiftMnemonic(comptime narrow: []const u8, comptime signed: bool) []const u8 {
        if (std.mem.eql(u8, narrow, "shl.b32")) return "shl.b64";
        if (std.mem.eql(u8, narrow, "shr.s32")) return if (signed) "shr.s64" else "shr.u64";
        if (std.mem.eql(u8, narrow, "shr.u32")) return "shr.u64";
        @compileError("unsupported shift mnemonic " ++ narrow);
    }

    fn emitExp(self: *Emitter, op: *ir.Operation) EmitError!void {
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const tmp = self.allocF32();
        const out = self.allocF32();
        try self.line("    mul.f32            %f{d}, %f{d}, 0f3FB8AA3B;", .{ tmp, input });
        try self.line("    ex2.approx.f32     %f{d}, %f{d};", .{ out, tmp });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32 = out });
    }

    fn emitLog(self: *Emitter, op: *ir.Operation) EmitError!void {
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const tmp = self.allocF32();
        const out = self.allocF32();
        try self.line("    lg2.approx.f32     %f{d}, %f{d};", .{ tmp, input });
        try self.line("    mul.f32            %f{d}, %f{d}, 0f3F317218;", .{ out, tmp });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32 = out });
    }

    fn emitVecExtract(self: *Emitter, op: *ir.Operation) EmitError!void {
        const extract = ArithDialect.ExtractOp{ .op = op };
        const vector = try self.require(extract.getVector());
        if (vector != .f32x4) return error.UnsupportedOperation;
        const lane_index = extract.getIndex() orelse return error.InvalidArtifact;
        if (lane_index < 0 or lane_index > 3) return error.InvalidArtifact;
        const lane: u32 = @intCast(lane_index);
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32 = vector.f32x4 + lane });
    }

    fn emitVecSplat(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        if (!isVec4F32Type(result.type)) return error.UnsupportedOperation;
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const base = self.allocF32x4();
        var lane: u32 = 0;
        while (lane < 4) : (lane += 1) {
            try self.line("    mov.f32            %f{d}, %f{d};", .{ base + lane, input });
        }
        try self.bind(result, .{ .f32x4 = base });
    }

    fn emitVecInsert(self: *Emitter, op: *ir.Operation) EmitError!void {
        const insert = ArithDialect.InsertOp{ .op = op };
        const vector = try self.require(insert.getVector());
        if (vector != .f32x4) return error.UnsupportedOperation;
        const lane_value = try self.asF32(try self.require(insert.getScalar()));
        const lane_index = insert.getIndex() orelse return error.InvalidArtifact;
        if (lane_index < 0 or lane_index > 3) return error.InvalidArtifact;
        const target_lane: u32 = @intCast(lane_index);
        const base = self.allocF32x4();
        var lane: u32 = 0;
        while (lane < 4) : (lane += 1) {
            const source = if (lane == target_lane) lane_value else vector.f32x4 + lane;
            try self.line("    mov.f32            %f{d}, %f{d};", .{ base + lane, source });
        }
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32x4 = base });
    }

    fn emitTf32Round(self: *Emitter, op: *ir.Operation) EmitError!void {
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const bits = self.allocU32();
        const out = self.allocF32();
        self.requires_sm80 = true;
        try self.line("    cvt.rna.tf32.f32   %r{d}, %f{d};", .{ bits, input });
        try self.line("    mov.b32            %f{d}, %r{d};", .{ out, bits });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32 = out });
    }

    fn emitCpAsyncShared(self: *Emitter, op: NvptxDialect.CpAsyncSharedOp) EmitError!void {
        const bytes = op.getBytes() orelse return error.InvalidArtifact;
        if (bytes != 4 and bytes != 8 and bytes != 16) return error.UnsupportedOperation;
        self.requires_sm80 = true;

        const dst = try self.require(op.getDst());
        const dst_info = memrefInfo(op.getDst().type) orelse return error.InvalidArtifact;
        if (dst_info.addr_space != .shared) return error.InvalidArtifact;
        const shared = switch (dst) {
            .shared => |shared| shared,
            else => return error.InvalidArtifact,
        };
        const dst_addr = try self.emitSharedAddress(shared, op.getDstIndex(), dst_info.element);

        const src = try self.require(op.getSrc());
        const src_info = memrefInfo(op.getSrc().type) orelse return error.InvalidArtifact;
        if (!isKernelParameterAddressSpace(src_info.addr_space)) return error.InvalidArtifact;
        const src_ptr = switch (src) {
            .ptr => |ptr_reg| ptr_reg,
            else => return error.InvalidArtifact,
        };
        const src_addr = try self.emitPointerAddress(src_ptr, op.getSrcIndex(), src_info.element);

        const qualifier: []const u8 = if (bytes == 16) "cg" else "ca";
        try self.line("    cp.async.{s}.shared.global [%r{d}+{d}], [%rd{d}+{d}], {d};", .{ qualifier, dst_addr.reg, dst_addr.imm, src_addr.reg, src_addr.imm, bytes });
    }

    fn emitCpAsyncCommit(self: *Emitter, op: NvptxDialect.CpAsyncCommitOp) EmitError!void {
        _ = op;
        self.requires_sm80 = true;
        try self.line("    cp.async.commit_group ;", .{});
    }

    fn emitCpAsyncWait(self: *Emitter, op: NvptxDialect.CpAsyncWaitOp) EmitError!void {
        const groups = op.getGroups() orelse return error.InvalidArtifact;
        self.requires_sm80 = true;
        try self.line("    cp.async.wait_group {d};", .{groups});
    }

    fn emitMmaSync(self: *Emitter, op: NvptxDialect.MmaSyncOp) EmitError!void {
        const shape = op.getShape() orelse return error.InvalidArtifact;
        if (shape.m != 16 or shape.n != 8 or shape.k != 8) return error.UnsupportedOperation;
        self.requires_sm80 = true;
        var ab_regs: [6]u32 = undefined;
        for (0..ab_regs.len) |index| {
            const value = try self.require(op.getOperandValue(index));
            const bits = self.allocU32();
            try self.line("    mov.b32            %r{d}, %f{d};", .{ bits, try self.asF32(value) });
            ab_regs[index] = bits;
        }
        var c_regs: [4]u32 = undefined;
        for (0..c_regs.len) |index| {
            c_regs[index] = try self.asF32(try self.require(op.getOperandValue(6 + index)));
        }
        var d_regs: [4]u32 = undefined;
        for (&d_regs) |*reg| reg.* = self.allocF32();
        try self.line("    mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32 {{%f{d}, %f{d}, %f{d}, %f{d}}}, {{%r{d}, %r{d}, %r{d}, %r{d}}}, {{%r{d}, %r{d}}}, {{%f{d}, %f{d}, %f{d}, %f{d}}};", .{
            d_regs[0],  d_regs[1],  d_regs[2],  d_regs[3],
            ab_regs[0], ab_regs[1], ab_regs[2], ab_regs[3],
            ab_regs[4], ab_regs[5], c_regs[0],  c_regs[1],
            c_regs[2],  c_regs[3],
        });
        for (0..d_regs.len) |index| {
            try self.bind(op.op.getResult(index) orelse return error.InvalidArtifact, .{ .f32 = d_regs[index] });
        }
    }

    fn emitTanh(self: *Emitter, op: *ir.Operation) EmitError!void {
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const clamped_high = self.allocF32();
        const clamped = self.allocF32();
        const t0 = self.allocF32();
        const t1 = self.allocF32();
        const t2 = self.allocF32();
        const t3 = self.allocF32();
        const ratio = self.allocF32();
        const out = self.allocF32();
        const nan_pred = self.allocPred();
        try self.line("    min.f32            %f{d}, %f{d}, 0f41200000;", .{ clamped_high, input });
        try self.line("    max.f32            %f{d}, %f{d}, 0fC1200000;", .{ clamped, clamped_high });
        try self.line("    mul.f32            %f{d}, %f{d}, 0f4038AA3B;", .{ t0, clamped });
        try self.line("    ex2.approx.f32     %f{d}, %f{d};", .{ t1, t0 });
        try self.line("    add.f32            %f{d}, %f{d}, 0f3F800000;", .{ t2, t1 });
        try self.line("    sub.f32            %f{d}, %f{d}, 0f3F800000;", .{ t3, t1 });
        try self.line("    div.approx.f32     %f{d}, %f{d}, %f{d};", .{ ratio, t3, t2 });
        try self.line("    testp.notanumber.f32 %p{d}, %f{d};", .{ nan_pred, input });
        try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ out, input, ratio, nan_pred });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32 = out });
    }

    fn emitTan(self: *Emitter, op: *ir.Operation) EmitError!void {
        const input = try self.asF32(try self.require(op.operands.items[0].value));
        const s = self.allocF32();
        const c = self.allocF32();
        const out = self.allocF32();
        try self.line("    sin.approx.f32     %f{d}, %f{d};", .{ s, input });
        try self.line("    cos.approx.f32     %f{d}, %f{d};", .{ c, input });
        try self.line("    div.approx.f32     %f{d}, %f{d}, %f{d};", .{ out, s, c });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32 = out });
    }

    fn emitPow(self: *Emitter, op: *ir.Operation) EmitError!void {
        const base = try self.asF32(try self.require(op.operands.items[0].value));
        const exponent = try self.asF32(try self.require(op.operands.items[1].value));
        const log_base = self.allocF32();
        const scaled = self.allocF32();
        const out = self.allocF32();
        try self.line("    lg2.approx.f32     %f{d}, %f{d};", .{ log_base, base });
        try self.line("    mul.f32            %f{d}, %f{d}, %f{d};", .{ scaled, log_base, exponent });
        try self.line("    ex2.approx.f32     %f{d}, %f{d};", .{ out, scaled });
        try self.bind(op.getResult(0) orelse return error.InvalidArtifact, .{ .f32 = out });
    }

    fn emitAtan2(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        if ((try computeKind(result.type)) != .f32) return error.UnsupportedOperation;
        const y = try self.asF32(try self.require(op.operands.items[0].value));
        const x = try self.asF32(try self.require(op.operands.items[1].value));
        const abs_y = self.allocF32();
        const abs_x = self.allocF32();
        const y_over_x = self.allocF32();
        const x_over_y = self.allocF32();
        const ratio = self.allocF32();
        const complement = self.allocF32();
        const base = self.allocF32();
        const zero = self.allocF32();
        const half_pi = self.allocF32();
        const pi = self.allocF32();
        const x_axis = self.allocF32();
        const axis = self.allocF32();
        const pi_minus = self.allocF32();
        const quadrant = self.allocF32();
        const negated = self.allocF32();
        const out = self.allocF32();
        const use_y_over_x = self.allocPred();
        const x_zero = self.allocPred();
        const y_zero = self.allocPred();
        const x_negative = self.allocPred();
        const y_negative = self.allocPred();
        try self.line("    abs.f32            %f{d}, %f{d};", .{ abs_y, y });
        try self.line("    abs.f32            %f{d}, %f{d};", .{ abs_x, x });
        try self.line("    div.approx.f32     %f{d}, %f{d}, %f{d};", .{ y_over_x, abs_y, abs_x });
        try self.line("    div.approx.f32     %f{d}, %f{d}, %f{d};", .{ x_over_y, abs_x, abs_y });
        try self.line("    setp.gt.f32        %p{d}, %f{d}, %f{d};", .{ use_y_over_x, abs_x, abs_y });
        try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ ratio, y_over_x, x_over_y, use_y_over_x });
        const atan = try self.emitAtanApprox(ratio);
        try self.line("    mov.f32            %f{d}, 0f00000000;", .{zero});
        try self.line("    mov.f32            %f{d}, 0f3FC90FDB;", .{half_pi});
        try self.line("    mov.f32            %f{d}, 0f40490FDB;", .{pi});
        try self.line("    sub.f32            %f{d}, %f{d}, %f{d};", .{ complement, half_pi, atan });
        try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ base, atan, complement, use_y_over_x });
        try self.line("    setp.eq.f32        %p{d}, %f{d}, %f{d};", .{ x_zero, abs_x, zero });
        try self.line("    setp.eq.f32        %p{d}, %f{d}, %f{d};", .{ y_zero, abs_y, zero });
        try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ x_axis, half_pi, base, x_zero });
        try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ axis, zero, x_axis, y_zero });
        try self.line("    setp.lt.f32        %p{d}, %f{d}, %f{d};", .{ x_negative, x, zero });
        try self.line("    sub.f32            %f{d}, %f{d}, %f{d};", .{ pi_minus, pi, axis });
        try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ quadrant, pi_minus, axis, x_negative });
        try self.line("    setp.lt.f32        %p{d}, %f{d}, %f{d};", .{ y_negative, y, zero });
        try self.line("    neg.f32            %f{d}, %f{d};", .{ negated, quadrant });
        try self.line("    selp.f32           %f{d}, %f{d}, %f{d}, %p{d};", .{ out, negated, quadrant, y_negative });
        try self.bind(result, .{ .f32 = out });
    }

    fn emitAtanApprox(self: *Emitter, input: u32) EmitError!u32 {
        const abs_value = self.allocF32();
        const centered = self.allocF32();
        const b_term = self.allocF32();
        const coeff = self.allocF32();
        const term0 = self.allocF32();
        const term1 = self.allocF32();
        const linear = self.allocF32();
        const out = self.allocF32();
        try self.line("    abs.f32            %f{d}, %f{d};", .{ abs_value, input });
        try self.line("    sub.f32            %f{d}, %f{d}, 0f3F800000;", .{ centered, abs_value });
        try self.line("    mul.f32            %f{d}, %f{d}, 0f3D87C84B;", .{ b_term, abs_value });
        try self.line("    add.f32            %f{d}, %f{d}, 0f3E7A92A3;", .{ coeff, b_term });
        try self.line("    mul.f32            %f{d}, %f{d}, %f{d};", .{ term0, input, centered });
        try self.line("    mul.f32            %f{d}, %f{d}, %f{d};", .{ term1, term0, coeff });
        try self.line("    mul.f32            %f{d}, %f{d}, 0f3F490FDB;", .{ linear, input });
        try self.line("    sub.f32            %f{d}, %f{d}, %f{d};", .{ out, linear, term1 });
        return out;
    }

    fn emitFma(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        if ((try computeKind(result.type)) != .f32) return error.UnsupportedOperation;
        const a = try self.asF32(try self.require(op.operands.items[0].value));
        const b = try self.asF32(try self.require(op.operands.items[1].value));
        const c = try self.asF32(try self.require(op.operands.items[2].value));
        const out = self.allocF32();
        try self.line("    fma.rn.f32         %f{d}, %f{d}, %f{d}, %f{d};", .{ out, a, b, c });
        try self.bind(result, .{ .f32 = out });
    }

    fn emitIf(self: *Emitter, op: ScfDialect.IfOp) EmitError!void {
        const result_count = op.getNumResults();
        if (result_count == 0) {
            const cond = try self.asPred(try self.require(op.getCondition()));
            const id = self.freshLabel();
            try self.line("    @!%p{d} bra        LIF_ELSE_{d};", .{ cond, id });
            try self.emitBlock(op.getThenBlock());
            try self.line("    bra                LIF_DONE_{d};", .{id});
            try self.line("LIF_ELSE_{d}:", .{id});
            if (op.getElseBlock()) |else_block| {
                try self.emitBlock(else_block);
            }
            try self.line("LIF_DONE_{d}:", .{id});
            return;
        }

        const else_block = op.getElseBlock() orelse return error.InvalidArtifact;
        const cond = try self.asPred(try self.require(op.getCondition()));
        const id = self.freshLabel();

        var result_registers: std.ArrayListUnmanaged(Value) = .empty;
        defer result_registers.deinit(self.allocator);

        try self.line("    @!%p{d} bra        LIF_ELSE_{d};", .{ cond, id });
        try self.emitYieldingBlock(op.getThenBlock(), result_count, &result_registers);
        try self.line("    bra                LIF_DONE_{d};", .{id});
        try self.line("LIF_ELSE_{d}:", .{id});
        try self.emitYieldingBlock(else_block, result_count, &result_registers);
        try self.line("LIF_DONE_{d}:", .{id});
        self.resetAddressBases();

        for (0..result_count) |index| {
            const result = op.op.getResult(index) orelse return error.InvalidArtifact;
            try self.bind(result, result_registers.items[index]);
        }
    }

    fn emitYieldingBlock(
        self: *Emitter,
        block: *ir.Block,
        result_count: usize,
        result_registers: *std.ArrayListUnmanaged(Value),
    ) EmitError!void {
        self.resetAddressBases();
        var ops = block.getOperations();
        while (ops.next()) |block_op| {
            if (std.mem.eql(u8, block_op.name.name, ScfDialect.YieldOp.operation_name)) {
                const yield = ScfDialect.YieldOp{ .op = block_op };
                const yielded = yield.getOperands();
                if (yielded.len != result_count) return error.InvalidArtifact;
                for (yielded, 0..) |yield_value, index| {
                    const source = try self.require(yield_value);
                    if (result_registers.items.len <= index) {
                        const register = try self.allocLike(source);
                        result_registers.append(self.allocator, register) catch return error.OutOfMemory;
                    }
                    try self.emitMove(result_registers.items[index], source);
                }
                return;
            }
            try self.emitOperation(block_op);
        }
        return error.InvalidArtifact;
    }

    fn emitWhile(self: *Emitter, op: ScfDialect.WhileOp) EmitError!void {
        const before = op.getBeforeBlock();
        const after = op.getAfterBlock();
        const carry_count = op.op.operands.items.len;
        if (op.op.results.items.len != carry_count) return error.InvalidArtifact;
        if (before.arguments.items.len != carry_count) return error.InvalidArtifact;
        if (after.arguments.items.len != carry_count) return error.InvalidArtifact;

        var carries: std.ArrayListUnmanaged(Value) = .empty;
        defer carries.deinit(self.allocator);
        for (op.op.operands.items, before.arguments.items) |operand, before_arg| {
            const initial = try self.require(operand.value);
            const carry = try self.allocLike(initial);
            try self.emitMove(carry, initial);
            carries.append(self.allocator, carry) catch return error.OutOfMemory;
            try self.bind(before_arg, carry);
        }

        var exits: std.ArrayListUnmanaged(Value) = .empty;
        defer exits.deinit(self.allocator);

        const id = self.freshLabel();
        self.resetAddressBases();
        try self.line("LWHILE_HEAD_{d}:", .{id});

        var before_ops = before.getOperations();
        var saw_condition = false;
        while (before_ops.next()) |before_op| {
            if (std.mem.eql(u8, before_op.name.name, ScfDialect.ConditionOp.operation_name)) {
                const condition = ScfDialect.ConditionOp{ .op = before_op };
                const args = condition.getArgs();
                if (args.len != carry_count) return error.InvalidArtifact;
                for (args, 0..) |arg, index| {
                    const source = try self.require(arg);
                    if (exits.items.len <= index) {
                        const register = try self.allocLike(source);
                        exits.append(self.allocator, register) catch return error.OutOfMemory;
                    }
                    try self.emitMove(exits.items[index], source);
                }
                const cond = try self.asPred(try self.require(condition.getCondition()));
                try self.line("    @!%p{d} bra        LWHILE_DONE_{d};", .{ cond, id });
                saw_condition = true;
                break;
            }
            try self.emitOperation(before_op);
        }
        if (!saw_condition) return error.InvalidArtifact;

        for (after.arguments.items, 0..) |after_arg, index| {
            try self.bind(after_arg, exits.items[index]);
        }

        var after_ops = after.getOperations();
        var saw_yield = false;
        while (after_ops.next()) |after_op| {
            if (std.mem.eql(u8, after_op.name.name, ScfDialect.YieldOp.operation_name)) {
                const yield = ScfDialect.YieldOp{ .op = after_op };
                const yielded = yield.getOperands();
                if (yielded.len != carry_count) return error.InvalidArtifact;
                for (yielded, carries.items) |yield_value, carry| {
                    try self.emitMove(carry, try self.require(yield_value));
                }
                saw_yield = true;
                break;
            }
            try self.emitOperation(after_op);
        }
        if (!saw_yield) return error.InvalidArtifact;

        try self.line("    bra                LWHILE_HEAD_{d};", .{id});
        try self.line("LWHILE_DONE_{d}:", .{id});
        self.resetAddressBases();

        for (op.op.results.items, exits.items) |*result, exit| {
            try self.bind(result, exit);
        }
    }

    fn emitFor(self: *Emitter, op: ScfDialect.ForOp) EmitError!void {
        const integer = try LoopInteger.fromType(op.getLowerBound().type);
        const lower = try self.require(op.getLowerBound());
        const upper = try integer.register(self, try self.require(op.getUpperBound()));
        const step = try integer.register(self, try self.require(op.getStep()));
        const body_block = op.getBodyBlock();
        const iter_args = op.getInitArgs();
        if (iter_args.len != op.op.results.items.len) return error.InvalidArtifact;
        if (body_block.arguments.items.len != iter_args.len + 1) return error.InvalidArtifact;

        const induction = try self.allocLike(lower);
        const iv = try integer.register(self, induction);
        try self.emitMove(induction, lower);
        try self.bind(op.getInductionVar(), induction);

        const accumulators = try self.allocator.alloc(Value, iter_args.len);
        defer self.allocator.free(accumulators);
        for (iter_args, body_block.arguments.items[1..], accumulators) |init_arg, block_arg, *acc| {
            const initial = try self.require(init_arg);
            acc.* = try self.allocLike(initial);
            try self.emitMove(acc.*, initial);
            try self.bind(block_arg, acc.*);
        }

        const pred = self.allocPred();
        const id = self.freshLabel();
        const registers = integer.registerFile();
        self.resetAddressBases();
        try self.line("LFOR_HEAD_{d}:", .{id});
        try self.line("    setp.ge.{s}        %p{d}, %{s}{d}, %{s}{d};", .{
            @tagName(integer), pred, registers, iv, registers, upper,
        });
        try self.line("    @%p{d} bra         LFOR_DONE_{d};", .{ pred, id });

        try self.emitLoopBody(body_block, accumulators);
        self.resetAddressBases();
        try self.line("    add.{s}            %{s}{d}, %{s}{d}, %{s}{d};", .{
            @tagName(integer), registers, iv, registers, iv, registers, step,
        });
        try self.line("    bra                LFOR_HEAD_{d};", .{id});
        try self.line("LFOR_DONE_{d}:", .{id});

        for (op.op.results.items, accumulators) |*result, acc| {
            try self.bind(result, acc);
        }
    }

    fn emitLoopBody(self: *Emitter, body_block: *ir.Block, accumulators: []const Value) EmitError!void {
        var ops = body_block.getOperations();
        while (ops.next()) |body_op| {
            if (std.mem.eql(u8, body_op.name.name, ScfDialect.YieldOp.operation_name)) {
                const yield = ScfDialect.YieldOp{ .op = body_op };
                try self.emitParallelMoves(accumulators, yield.getOperands());
                return;
            }
            try self.emitOperation(body_op);
        }
        return error.InvalidArtifact;
    }

    fn emitParallelMoves(
        self: *Emitter,
        destinations: []const Value,
        sources: []const *ir.Value,
    ) EmitError!void {
        if (destinations.len != sources.len) return error.InvalidArtifact;
        const snapshots = try self.allocator.alloc(Value, sources.len);
        defer self.allocator.free(snapshots);
        for (sources, snapshots) |source, *snapshot| {
            const value = try self.require(source);
            snapshot.* = try self.allocLike(value);
            try self.emitMove(snapshot.*, value);
        }
        for (destinations, snapshots) |destination, snapshot| {
            try self.emitMove(destination, snapshot);
        }
    }

    fn allocLike(self: *Emitter, value: Value) abi.Error!Value {
        return switch (value) {
            .pred => .{ .pred = self.allocPred() },
            .u32 => .{ .u32 = self.allocU32() },
            .s32 => .{ .s32 = self.allocU32() },
            .u64 => .{ .u64 = self.allocU64() },
            .f32 => .{ .f32 = self.allocF32() },
            .f32x4 => .{ .f32x4 = self.allocF32x4() },
            .f64 => .{ .f64 = self.allocF64() },
            .ptr, .shared => error.UnsupportedOperation,
        };
    }

    fn emitMove(self: *Emitter, dst: Value, src: Value) EmitError!void {
        switch (dst) {
            .pred => |reg| try self.line("    mov.pred           %p{d}, %p{d};", .{ reg, try self.asPred(src) }),
            .u32, .s32 => |reg| try self.line("    mov.u32            %r{d}, %r{d};", .{ reg, try self.asU32(src) }),
            .u64 => |reg| try self.line("    mov.u64            %rd{d}, %rd{d};", .{ reg, try self.asU64(src) }),
            .f32 => |reg| try self.line("    mov.f32            %f{d}, %f{d};", .{ reg, try self.asF32(src) }),
            .f32x4 => |reg| {
                if (src != .f32x4) return error.UnsupportedOperation;
                var lane: u32 = 0;
                while (lane < 4) : (lane += 1) {
                    try self.line("    mov.f32            %f{d}, %f{d};", .{ reg + lane, src.f32x4 + lane });
                }
            },
            .f64 => |reg| try self.line("    mov.f64            %fd{d}, %fd{d};", .{ reg, try self.asF64(src) }),
            .ptr, .shared => return error.UnsupportedOperation,
        }
    }

    fn bind(self: *Emitter, value: *ir.Value, ptx_value: Value) abi.Error!void {
        self.values.put(self.allocator, value, ptx_value) catch return error.OutOfMemory;
    }

    fn require(self: *Emitter, value: *ir.Value) abi.Error!Value {
        return self.values.get(value) orelse error.InvalidArtifact;
    }

    fn asU32(_: *Emitter, value: Value) abi.Error!u32 {
        return switch (value) {
            .u32, .s32 => |reg| reg,
            else => error.InvalidArtifact,
        };
    }

    fn asF32(_: *Emitter, value: Value) abi.Error!u32 {
        return switch (value) {
            .f32 => |reg| reg,
            else => error.InvalidArtifact,
        };
    }

    fn asF64(_: *Emitter, value: Value) abi.Error!u32 {
        return switch (value) {
            .f64 => |reg| reg,
            else => error.InvalidArtifact,
        };
    }

    fn asU64(_: *Emitter, value: Value) abi.Error!u32 {
        return switch (value) {
            .u64 => |reg| reg,
            else => error.InvalidArtifact,
        };
    }

    fn asPred(_: *Emitter, value: Value) abi.Error!u32 {
        return switch (value) {
            .pred => |reg| reg,
            else => error.InvalidArtifact,
        };
    }

    fn allocU32(self: *Emitter) u32 {
        const reg = self.next_r;
        self.next_r += 1;
        return reg;
    }

    fn allocB16(self: *Emitter) u32 {
        const reg = self.next_h;
        self.next_h += 1;
        return reg;
    }

    fn allocF32(self: *Emitter) u32 {
        const reg = self.next_f;
        self.next_f += 1;
        return reg;
    }

    fn allocF32x4(self: *Emitter) u32 {
        const reg = self.next_f;
        self.next_f += 4;
        return reg;
    }

    fn allocF64(self: *Emitter) u32 {
        const reg = self.next_fd;
        self.next_fd += 1;
        return reg;
    }

    fn allocPtr(self: *Emitter) u32 {
        const reg = self.next_rd;
        self.next_rd += 1;
        return reg;
    }

    fn allocU64(self: *Emitter) u32 {
        const reg = self.next_rd;
        self.next_rd += 1;
        return reg;
    }

    fn allocPred(self: *Emitter) u32 {
        const reg = self.next_p;
        self.next_p += 1;
        return reg;
    }

    fn allocShared(self: *Emitter) u32 {
        const id = self.next_shared;
        self.next_shared += 1;
        return id;
    }

    fn emitBf16BitsToF32(self: *Emitter, bits: u32) EmitError!u32 {
        const widened = self.allocU32();
        const out = self.allocF32();
        try self.line("    shl.b32            %r{d}, %r{d}, 16;", .{ widened, bits });
        try self.line("    mov.b32            %f{d}, %r{d};", .{ out, widened });
        return out;
    }

    fn emitF32ToBf16Bits(self: *Emitter, value: Value) EmitError!u32 {
        const bits = self.allocU32();
        const out = self.allocU32();
        try self.line("    mov.b32            %r{d}, %f{d};", .{ bits, try self.asF32(value) });
        try self.line("    shr.u32            %r{d}, %r{d}, 16;", .{ out, bits });
        return out;
    }

    fn freshLabel(self: *Emitter) u32 {
        const label = self.next_label;
        self.next_label += 1;
        return label;
    }

    fn line(self: *Emitter, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        try self.body.writer.print(fmt, args);
        try self.body.writer.writeByte('\n');
    }
};

const MemrefInfo = struct {
    size: ?u64,
    element: ScalarKind,
    addr_space: dialects.AddressSpace,
    alignment: ?u64,
};

fn writeHeader(writer: *std.Io.Writer, requires_sm80: bool) std.Io.Writer.Error!void {
    if (requires_sm80) {
        try writer.writeAll(".version 7.0\n.target sm_80\n.address_size 64\n\n");
        return;
    }
    try writer.writeAll(".version 6.2\n.target sm_52\n.address_size 64\n\n");
}

fn scalarKind(typ: ir.Type) abi.Error!ScalarKind {
    return scalar_kinds.kindFromType(typ) orelse error.UnsupportedOperation;
}

fn isVec4F32Type(typ: ir.Type) bool {
    const name = typ.getDialectTypeName() orelse return false;
    return std.mem.eql(u8, name, arith_names.vec4xf32);
}

fn computeKind(typ: ir.Type) abi.Error!ScalarKind {
    const kind = try scalarKind(typ);
    return switch (kind) {
        .i8, .i16 => .i32,
        .u8, .u16 => .u32,
        .f16, .bf16 => .f32,
        else => kind,
    };
}

fn memrefInfo(typ: ir.Type) ?MemrefInfo {
    const name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, name, MemrefDialect.name)) return null;
    const params = MemrefDialect.parseMemrefParams(typ.getDialectParamKey() orelse return null) orelse return null;
    return .{
        .size = params.size,
        .element = scalar_kinds.kindFromTypeName(params.element_type_name) orelse return null,
        .addr_space = params.addr_space,
        .alignment = params.alignment,
    };
}

fn dynamicSharedByteOffset(op: *ir.Operation) abi.Error!u32 {
    const attr = op.getAttrAs(ir.Attribute.IntegerAttr, gpu.attr_names.dynamic_shared_byte_offset) orelse return 0;
    const value = attr.getValue();
    if (value < 0) return error.InvalidArtifact;
    return std.math.cast(u32, value) orelse return error.InvalidArtifact;
}

fn isKernelParameterAddressSpace(addr_space: dialects.AddressSpace) bool {
    return switch (addr_space) {
        .host, .device, .constant, .unified => true,
        .shared, .local => false,
    };
}

fn elementByteSize(kind: ScalarKind) u32 {
    return switch (kind) {
        .bool => 1,
        .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i64, .u64 => 8,
        .f64 => 8,
        .f16 => 2,
        .bf16 => 2,
        .index, .i32, .u32, .f32 => 4,
    };
}

fn dimName(dim: gpu.Dimension) []const u8 {
    return switch (dim) {
        .x => "x",
        .y => "y",
        .z => "z",
    };
}

fn ptxPredicate(pred: CmpPredicate) []const u8 {
    return switch (pred) {
        .eq => "eq",
        .ne => "ne",
        .lt, .slt, .ult => "lt",
        .le, .sle, .ule => "le",
        .gt, .sgt, .ugt => "gt",
        .ge, .sge, .uge => "ge",
    };
}

/// A float comparison's predicate. IEEE's `!=` is unordered, so it is `neu`,
/// true when either operand is a NaN; every other comparison is ordered.
fn ptxFloatPredicate(pred: CmpPredicate) []const u8 {
    return switch (pred) {
        .ne => "neu",
        else => ptxPredicate(pred),
    };
}

fn ptxShuffleMode(mode: gpu.ShuffleMode) []const u8 {
    return switch (mode) {
        .sync => "idx",
        .down => "down",
        .up => "up",
        .xor => "bfly",
    };
}

const warp_reduce_deltas = [_]u32{ 16, 8, 4, 2, 1 };
const warp_scan_offsets = [_]u32{ 1, 2, 4, 8, 16 };

fn f32Bits(value: f64) u32 {
    const narrowed: f32 = @floatCast(value);
    return @bitCast(narrowed);
}

fn f64Bits(value: f64) u64 {
    return @bitCast(value);
}

test "cuda scalar support mask follows Choir scalar spellings" {
    inline for (std.meta.tags(ScalarKind)) |kind| {
        try std.testing.expectEqual(
            @as(?ScalarKind, kind),
            scalar_kinds.kindFromTypeName(dialects.arith.scalarTypeName(kind)),
        );
    }
    try std.testing.expectEqual(@as(?ScalarKind, null), scalar_kinds.kindFromTypeName("arith.unknown"));
}
