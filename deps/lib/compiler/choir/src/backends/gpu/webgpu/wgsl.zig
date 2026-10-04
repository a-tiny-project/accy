const std = @import("std");
const abi = @import("gpu_abi");
const choir_pkg = @import("../../../root.zig");

const gpu = @import("../../../dialects/gpu/root.zig");

const ir = choir_pkg.ir;
const dialects = choir_pkg.dialects;

const Allocator = std.mem.Allocator;
const ArithDialect = dialects.ArithDialect;
const CmpPredicate = dialects.arith.CmpPredicate;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const GpuDialect = gpu.GpuDialect;
const MemrefDialect = dialects.MemrefDialect;
const ScfDialect = dialects.ScfDialect;

const EmitError = abi.Error || std.Io.Writer.Error;

const ScalarKind = dialects.arith.ScalarKind;
const scalar_kinds = dialects.arith.ScalarSet.init(&.{
    .bool,
    .index,
    .i8,
    .i16,
    .i32,
    .u32,
    .i64,
    .f16,
    .f32,
    .f64,
});

const YieldTarget = struct {
    names: []const []const u8,
};

pub fn emitWgsl(
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
    declarations: std.Io.Writer.Allocating,
    body: std.Io.Writer.Allocating,
    values: std.AutoHashMapUnmanaged(*const ir.Value, []const u8) = .{},
    names: std.ArrayListUnmanaged([]u8) = .empty,
    next_value: u32 = 0,
    next_loop: u32 = 0,
    next_shared: u32 = 0,
    indent: u32 = 1,
    while_depth: u32 = 0,
    uses_umulhi: bool = false,

    fn init(allocator: Allocator, entry_name: []const u8, module: *ir.Operation) Emitter {
        return .{
            .allocator = allocator,
            .entry_name = entry_name,
            .module = module,
            .declarations = std.Io.Writer.Allocating.init(allocator),
            .body = std.Io.Writer.Allocating.init(allocator),
        };
    }

    fn deinit(self: *Emitter) void {
        self.values.deinit(self.allocator);
        for (self.names.items) |name| self.allocator.free(name);
        self.names.deinit(self.allocator);
        self.declarations.deinit();
        self.body.deinit();
    }

    fn emit(self: *Emitter) EmitError![]u8 {
        const func = try self.findKernelFunction();
        try self.emitParameterBindings(func);
        try self.emitBlock(func.getEntryBlock(), null);

        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try writeHeader(&out.writer);
        if (self.uses_umulhi) try writeUmulhiHelper(&out.writer);
        try out.writer.writeAll(self.declarations.written());
        if (self.declarations.written().len != 0) try out.writer.writeByte('\n');
        try self.emitFunctionHeader(&out.writer);
        try out.writer.writeAll(self.body.written());
        try out.writer.writeAll("}\n");
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn collectBlockWrites(
        self: *Emitter,
        block: *ir.Block,
        written: *std.AutoHashMapUnmanaged(*const ir.Value, void),
    ) EmitError!void {
        var ops = block.getOperations();
        while (ops.next()) |op| {
            const name = op.name.name;
            if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
                const store = MemrefDialect.StoreOp{ .op = op };
                written.put(self.allocator, store.getMemref(), {}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, name, MemrefDialect.AtomicRmwOp.operation_name)) {
                const atomic = MemrefDialect.AtomicRmwOp{ .op = op };
                written.put(self.allocator, atomic.getMemref(), {}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, name, MemrefDialect.AtomicCasOp.operation_name)) {
                const atomic = MemrefDialect.AtomicCasOp{ .op = op };
                written.put(self.allocator, atomic.getMemref(), {}) catch return error.OutOfMemory;
            }
            for (op.regions.items) |*region| {
                var current = region.blocks.head;
                while (current) |inner| : (current = inner.next) {
                    try self.collectBlockWrites(inner, written);
                }
            }
        }
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

    fn emitParameterBindings(self: *Emitter, func: FuncDialect.FuncOp) EmitError!void {
        var written: std.AutoHashMapUnmanaged(*const ir.Value, void) = .empty;
        defer written.deinit(self.allocator);
        try self.collectBlockWrites(func.getEntryBlock(), &written);

        const args = func.getArguments();
        for (args, 0..) |arg, index| {
            if (memrefInfo(arg.type)) |info| {
                if (info.addr_space == .shared) return error.UnsupportedOperation;
                const name = std.fmt.allocPrint(self.allocator, "arg{d}", .{index}) catch return error.OutOfMemory;
                const bound = try self.rememberName(name);
                const access = if (written.contains(arg)) "read_write" else "read";
                try self.declarations.writer.print(
                    "@group(0) @binding({d}) var<storage, {s}> {s}: array<{s}>;\n",
                    .{ index, access, bound, try wgslStorageScalarType(info.element) },
                );
                try self.bind(arg, bound);
                continue;
            }
            const kind = try scalarKind(arg.type);
            const storage_type = try wgslStorageScalarType(kind);
            const storage_name = std.fmt.allocPrint(self.allocator, "arg{d}_scalar", .{index}) catch return error.OutOfMemory;
            defer self.allocator.free(storage_name);
            try self.declarations.writer.print(
                "@group(0) @binding({d}) var<storage, read> {s}: array<{s}>;\n",
                .{ index, storage_name, storage_type },
            );
            const expr = std.fmt.allocPrint(self.allocator, "{s}[0]", .{storage_name}) catch return error.OutOfMemory;
            try self.rememberAndBind(arg, expr);
        }
    }

    fn emitFunctionHeader(self: *Emitter, writer: *std.Io.Writer) EmitError!void {
        try writer.print("@compute @workgroup_size(choir_workgroup_size_x, choir_workgroup_size_y, choir_workgroup_size_z)\nfn {s}(\n", .{self.entry_name});
        try writer.writeAll("    @builtin(global_invocation_id) choir_global_id: vec3<u32>,\n");
        try writer.writeAll("    @builtin(local_invocation_id) choir_local_id: vec3<u32>,\n");
        try writer.writeAll("    @builtin(workgroup_id) choir_workgroup_id: vec3<u32>,\n");
        try writer.writeAll("    @builtin(num_workgroups) choir_num_workgroups: vec3<u32>,\n");
        try writer.writeAll("    @builtin(local_invocation_index) choir_local_index: u32\n");
        try writer.writeAll(") {\n");
    }

    fn emitBlock(self: *Emitter, block: *ir.Block, yield_target: ?YieldTarget) EmitError!void {
        var ops = block.getOperations();
        while (ops.next()) |op| {
            try self.emitOperation(op, yield_target);
        }
    }

    fn emitOperation(self: *Emitter, op: *ir.Operation, yield_target: ?YieldTarget) EmitError!void {
        const name = op.name.name;
        if (std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
            try self.line("return;", .{});
        } else if (std.mem.eql(u8, name, ScfDialect.YieldOp.operation_name)) {
            try self.emitYield(ScfDialect.YieldOp{ .op = op }, yield_target);
        } else if (std.mem.eql(u8, name, ScfDialect.IfOp.operation_name)) {
            try self.emitIf(ScfDialect.IfOp{ .op = op });
        } else if (std.mem.eql(u8, name, ScfDialect.ForOp.operation_name)) {
            try self.emitFor(ScfDialect.ForOp{ .op = op });
        } else if (std.mem.eql(u8, name, ScfDialect.WhileOp.operation_name)) {
            try self.emitWhile(ScfDialect.WhileOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.GlobalIdxOp.operation_name)) {
            const wrapped = GpuDialect.GlobalIdxOp{ .op = op };
            try self.emitGpuVectorRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_global_id");
        } else if (std.mem.eql(u8, name, GpuDialect.ThreadIdxOp.operation_name)) {
            const wrapped = GpuDialect.ThreadIdxOp{ .op = op };
            try self.emitGpuVectorRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_local_id");
        } else if (std.mem.eql(u8, name, GpuDialect.BlockIdxOp.operation_name)) {
            const wrapped = GpuDialect.BlockIdxOp{ .op = op };
            try self.emitGpuVectorRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_workgroup_id");
        } else if (std.mem.eql(u8, name, GpuDialect.BlockDimOp.operation_name)) {
            const wrapped = GpuDialect.BlockDimOp{ .op = op };
            try self.emitBlockDimRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact);
        } else if (std.mem.eql(u8, name, GpuDialect.GridDimOp.operation_name)) {
            const wrapped = GpuDialect.GridDimOp{ .op = op };
            try self.emitGpuVectorRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_num_workgroups");
        } else if (std.mem.eql(u8, name, GpuDialect.LaneIdOp.operation_name)) {
            return error.UnsupportedOperation;
        } else if (std.mem.eql(u8, name, GpuDialect.WarpIdOp.operation_name)) {
            return error.UnsupportedOperation;
        } else if (std.mem.eql(u8, name, GpuDialect.BarrierOp.operation_name)) {
            try self.emitBarrier(GpuDialect.BarrierOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.WarpReduceOp.operation_name)) {
            return error.UnsupportedOperation;
        } else if (std.mem.eql(u8, name, GpuDialect.WarpScanOp.operation_name)) {
            return error.UnsupportedOperation;
        } else if (std.mem.eql(u8, name, MemrefDialect.AllocOp.operation_name)) {
            try self.emitAlloc(MemrefDialect.AllocOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) {
            try self.emitLoad(MemrefDialect.LoadOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
            try self.emitStore(MemrefDialect.StoreOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.AtomicRmwOp.operation_name)) {
            return error.UnsupportedOperation;
        } else if (std.mem.eql(u8, name, MemrefDialect.AtomicCasOp.operation_name)) {
            return error.UnsupportedOperation;
        } else if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name)) {
            try self.emitConstant(ArithDialect.ConstantOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.AddOp.operation_name)) {
            try self.emitBinary(op, "+");
        } else if (std.mem.eql(u8, name, ArithDialect.SubOp.operation_name)) {
            try self.emitBinary(op, "-");
        } else if (std.mem.eql(u8, name, ArithDialect.MulOp.operation_name)) {
            try self.emitBinary(op, "*");
        } else if (std.mem.eql(u8, name, ArithDialect.UmulhiOp.operation_name)) {
            try self.emitUmulhi(op);
        } else if (std.mem.eql(u8, name, ArithDialect.DivOp.operation_name)) {
            try self.emitBinary(op, "/");
        } else if (std.mem.eql(u8, name, ArithDialect.MaxOp.operation_name)) {
            try self.emitCall2(op, "max");
        } else if (std.mem.eql(u8, name, ArithDialect.MinOp.operation_name)) {
            try self.emitCall2(op, "min");
        } else if (std.mem.eql(u8, name, ArithDialect.AndOp.operation_name)) {
            try self.emitBitwiseOrLogical(op, "&", "&&");
        } else if (std.mem.eql(u8, name, ArithDialect.OrOp.operation_name)) {
            try self.emitBitwiseOrLogical(op, "|", "||");
        } else if (std.mem.eql(u8, name, ArithDialect.XorOp.operation_name)) {
            try self.emitBitwiseOrLogical(op, "^", "!=");
        } else if (std.mem.eql(u8, name, ArithDialect.ShlOp.operation_name)) {
            try self.emitShift(op, "<<");
        } else if (std.mem.eql(u8, name, ArithDialect.ShrOp.operation_name)) {
            try self.emitShift(op, ">>");
        } else if (std.mem.eql(u8, name, ArithDialect.UshrOp.operation_name)) {
            try self.emitUnsignedShiftRight(op);
        } else if (std.mem.eql(u8, name, ArithDialect.NegOp.operation_name)) {
            try self.emitUnary(op, "-");
        } else if (std.mem.eql(u8, name, ArithDialect.NotOp.operation_name)) {
            try self.emitNot(op);
        } else if (std.mem.eql(u8, name, ArithDialect.AbsOp.operation_name)) {
            try self.emitCall1(op, "abs");
        } else if (std.mem.eql(u8, name, ArithDialect.SqrtOp.operation_name)) {
            try self.emitCall1(op, "sqrt");
        } else if (std.mem.eql(u8, name, ArithDialect.ExpOp.operation_name)) {
            try self.emitCall1(op, "exp");
        } else if (std.mem.eql(u8, name, ArithDialect.LogOp.operation_name)) {
            try self.emitCall1(op, "log");
        } else if (std.mem.eql(u8, name, ArithDialect.TanhOp.operation_name)) {
            try self.emitCall1(op, "tanh");
        } else if (std.mem.eql(u8, name, ArithDialect.SinOp.operation_name)) {
            try self.emitCall1(op, "sin");
        } else if (std.mem.eql(u8, name, ArithDialect.CosOp.operation_name)) {
            try self.emitCall1(op, "cos");
        } else if (std.mem.eql(u8, name, ArithDialect.TanOp.operation_name)) {
            try self.emitCall1(op, "tan");
        } else if (std.mem.eql(u8, name, ArithDialect.FloorOp.operation_name)) {
            try self.emitCall1(op, "floor");
        } else if (std.mem.eql(u8, name, ArithDialect.RoundOp.operation_name)) {
            try self.emitCall1(op, "round");
        } else if (std.mem.eql(u8, name, ArithDialect.TruncOp.operation_name)) {
            try self.emitCall1(op, "trunc");
        } else if (std.mem.eql(u8, name, ArithDialect.PowOp.operation_name)) {
            try self.emitCall2(op, "pow");
        } else if (std.mem.eql(u8, name, ArithDialect.Atan2Op.operation_name)) {
            try self.emitCall2(op, "atan2");
        } else if (std.mem.eql(u8, name, ArithDialect.FmaOp.operation_name)) {
            try self.emitFma(ArithDialect.FmaOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name)) {
            try self.emitCompare(ArithDialect.CmpOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.SelectOp.operation_name)) {
            try self.emitSelect(ArithDialect.SelectOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.CastOp.operation_name)) {
            try self.emitCast(ArithDialect.CastOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.BitcastOp.operation_name)) {
            try self.emitBitcast(ArithDialect.BitcastOp{ .op = op });
        } else {
            return error.UnsupportedOperation;
        }
    }

    fn emitGpuVectorRegister(self: *Emitter, op: *ir.Operation, dim: gpu.Dimension, builtin_name: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("let {s}: i32 = i32({s}.{s});", .{ out, builtin_name, dimName(dim) });
        try self.bind(result, out);
    }

    fn emitBlockDimRegister(self: *Emitter, op: *ir.Operation, dim: gpu.Dimension) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("let {s}: i32 = i32({s});", .{ out, workgroupSizeOverride(dim) });
        try self.bind(result, out);
    }

    fn emitBarrier(self: *Emitter, op: GpuDialect.BarrierOp) EmitError!void {
        if (self.while_depth != 0) return error.UnsupportedOperation;
        const scope = op.getScope() orelse return error.InvalidArtifact;
        switch (scope) {
            .block => try self.line("workgroupBarrier();", .{}),
            else => return error.UnsupportedOperation,
        }
    }

    fn emitAlloc(self: *Emitter, op: MemrefDialect.AllocOp) EmitError!void {
        if (op.getDynamicSize() != null) return error.UnsupportedOperation;
        const result = op.getResult();
        const info = memrefInfo(result.type) orelse return error.InvalidArtifact;
        if (info.addr_space != .shared) return error.UnsupportedOperation;
        const size = info.size orelse return error.InvalidArtifact;
        if (size == 0) return error.InvalidArtifact;
        const out = try self.freshSharedName();
        try self.declarations.writer.print("var<workgroup> {s}: array<{s}, {d}>;\n", .{ out, try wgslStorageScalarType(info.element), size });
        try self.bind(result, out);
    }

    fn emitLoad(self: *Emitter, op: MemrefDialect.LoadOp) EmitError!void {
        const result = op.getResult();
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s}[{s}];", .{
            out,
            try wgslScalarType(kind),
            try self.require(op.getMemref()),
            try self.require(op.getIndex()),
        });
        try self.bind(result, out);
    }

    fn emitStore(self: *Emitter, op: MemrefDialect.StoreOp) EmitError!void {
        try self.line("{s}[{s}] = {s};", .{
            try self.require(op.getMemref()),
            try self.require(op.getIndex()),
            try self.require(op.getValue()),
        });
    }

    fn emitConstant(self: *Emitter, op: ArithDialect.ConstantOp) EmitError!void {
        const result = op.getResult();
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        switch (kind) {
            .bool => {
                const bool_attr = op.op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse return error.InvalidArtifact;
                try self.line("let {s}: bool = {s};", .{ out, if (bool_attr.getValue()) "true" else "false" });
            },
            .index => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                if (value < 0) return error.UnsupportedOperation;
                try self.line("let {s}: i32 = i32({d});", .{ out, value });
            },
            .u32 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                if (value < 0) return error.UnsupportedOperation;
                try self.line("let {s}: u32 = {d}u;", .{ out, value });
            },
            .i32 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                try self.line("let {s}: i32 = i32({d});", .{ out, value });
            },
            .f32 => {
                const value = op.getFloatValue() orelse return error.InvalidArtifact;
                try self.line("let {s}: f32 = bitcast<f32>(0x{X:0>8}u);", .{ out, floatBits(value) });
            },
            .i8, .i16, .i64, .u8, .u16, .u64, .f16, .bf16, .f64 => return error.UnsupportedOperation,
        }
        try self.bind(result, out);
    }

    fn emitBinary(self: *Emitter, op: *ir.Operation, operator: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s} {s} {s};", .{
            out,
            try wgslScalarType(kind),
            try self.require(op.operands.items[0].value),
            operator,
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    fn emitUmulhi(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        self.uses_umulhi = true;
        switch (kind) {
            .u32 => try self.line("let {s}: u32 = choir_umulhi_u32({s}, {s});", .{
                out,
                try self.require(op.operands.items[0].value),
                try self.require(op.operands.items[1].value),
            }),
            .index, .i32 => try self.line("let {s}: {s} = bitcast<{s}>(choir_umulhi_u32(bitcast<u32>({s}), bitcast<u32>({s})));", .{
                out,
                try wgslScalarType(kind),
                try wgslScalarType(kind),
                try self.require(op.operands.items[0].value),
                try self.require(op.operands.items[1].value),
            }),
            else => return error.UnsupportedOperation,
        }
        try self.bind(result, out);
    }

    fn emitBitwiseOrLogical(self: *Emitter, op: *ir.Operation, bitwise_operator: []const u8, bool_operator: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const operator = if (kind == .bool) bool_operator else bitwise_operator;
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s} {s} {s};", .{
            out,
            try wgslScalarType(kind),
            try self.require(op.operands.items[0].value),
            operator,
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    fn emitShift(self: *Emitter, op: *ir.Operation, operator: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s} {s} u32({s});", .{
            out,
            try wgslScalarType(kind),
            try self.require(op.operands.items[0].value),
            operator,
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    fn emitUnsignedShiftRight(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const ty = try wgslScalarType(kind);
        const out = try self.freshValueName();
        if (kind == .u32) {
            try self.line("let {s}: u32 = {s} >> u32({s});", .{
                out,
                try self.require(op.operands.items[0].value),
                try self.require(op.operands.items[1].value),
            });
        } else {
            _ = try wgslUnsignedScalarType(kind);
            try self.line("let {s}: {s} = bitcast<{s}>(bitcast<u32>({s}) >> u32({s}));", .{
                out,
                ty,
                ty,
                try self.require(op.operands.items[0].value),
                try self.require(op.operands.items[1].value),
            });
        }
        try self.bind(result, out);
    }

    fn emitUnary(self: *Emitter, op: *ir.Operation, operator: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        if (kind == .u32) return error.UnsupportedOperation;
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s}{s};", .{
            out,
            try wgslScalarType(kind),
            operator,
            try self.require(op.operands.items[0].value),
        });
        try self.bind(result, out);
    }

    fn emitNot(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const operator = switch (kind) {
            .bool => "!",
            .index, .i32, .u32 => "~",
            else => return error.UnsupportedOperation,
        };
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s}{s};", .{
            out,
            try wgslScalarType(kind),
            operator,
            try self.require(op.operands.items[0].value),
        });
        try self.bind(result, out);
    }

    fn emitCall1(self: *Emitter, op: *ir.Operation, function_name: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s}({s});", .{
            out,
            try wgslScalarType(kind),
            function_name,
            try self.require(op.operands.items[0].value),
        });
        try self.bind(result, out);
    }

    fn emitCall2(self: *Emitter, op: *ir.Operation, function_name: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = {s}({s}, {s});", .{
            out,
            try wgslScalarType(kind),
            function_name,
            try self.require(op.operands.items[0].value),
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    fn emitFma(self: *Emitter, op: ArithDialect.FmaOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = fma({s}, {s}, {s});", .{
            out,
            try wgslScalarType(try scalarKind(result.type)),
            try self.require(op.getA()),
            try self.require(op.getB()),
            try self.require(op.getC()),
        });
        try self.bind(result, out);
    }

    fn emitCompare(self: *Emitter, op: ArithDialect.CmpOp) EmitError!void {
        const out = try self.freshValueName();
        try self.line("let {s}: bool = {s} {s} {s};", .{
            out,
            try self.require(op.op.operands.items[0].value),
            comparisonOperator(op.getPredicate() orelse return error.InvalidArtifact),
            try self.require(op.op.operands.items[1].value),
        });
        try self.bind(op.getResult(), out);
    }

    fn emitSelect(self: *Emitter, op: ArithDialect.SelectOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        try self.line("let {s}: {s} = select({s}, {s}, {s});", .{
            out,
            try wgslScalarType(try scalarKind(result.type)),
            try self.require(op.getFalseValue()),
            try self.require(op.getTrueValue()),
            try self.require(op.getCondition()),
        });
        try self.bind(result, out);
    }

    fn emitCast(self: *Emitter, op: ArithDialect.CastOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        const ty = try wgslScalarType(try scalarKind(result.type));
        try self.line("let {s}: {s} = {s}({s});", .{
            out,
            ty,
            ty,
            try self.require(op.getInput()),
        });
        try self.bind(result, out);
    }

    fn emitBitcast(self: *Emitter, op: ArithDialect.BitcastOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        const ty = try wgslScalarType(try scalarKind(result.type));
        try self.line("let {s}: {s} = bitcast<{s}>({s});", .{
            out,
            ty,
            ty,
            try self.require(op.getInput()),
        });
        try self.bind(result, out);
    }

    fn emitIf(self: *Emitter, op: ScfDialect.IfOp) EmitError!void {
        const result_count = op.getNumResults();
        if (result_count == 0) {
            try self.line("if ({s}) {{", .{try self.require(op.getCondition())});
            self.indent += 1;
            try self.emitBlock(op.getThenBlock(), null);
            self.indent -= 1;
            if (op.getElseBlock()) |else_block| {
                try self.line("}} else {{", .{});
                self.indent += 1;
                try self.emitBlock(else_block, null);
                self.indent -= 1;
            }
            try self.line("}}", .{});
            return;
        }

        const else_block = op.getElseBlock() orelse return error.InvalidArtifact;
        const result_names = self.allocator.alloc([]const u8, result_count) catch return error.OutOfMemory;
        defer self.allocator.free(result_names);
        for (result_names, 0..) |*name, index| {
            const result = op.op.getResult(index) orelse return error.InvalidArtifact;
            name.* = try self.freshLoopName();
            try self.line("var {s}: {s};", .{ name.*, try wgslScalarType(try scalarKind(result.type)) });
        }

        try self.line("if ({s}) {{", .{try self.require(op.getCondition())});
        self.indent += 1;
        try self.emitBlock(op.getThenBlock(), .{ .names = result_names });
        self.indent -= 1;
        try self.line("}} else {{", .{});
        self.indent += 1;
        try self.emitBlock(else_block, .{ .names = result_names });
        self.indent -= 1;
        try self.line("}}", .{});

        for (result_names, 0..) |name, index| {
            try self.bind(op.op.getResult(index).?, name);
        }
    }

    fn emitWhile(self: *Emitter, op: ScfDialect.WhileOp) EmitError!void {
        const before = op.getBeforeBlock();
        const after = op.getAfterBlock();
        const carry_count = op.op.operands.items.len;
        if (op.op.results.items.len != carry_count) return error.InvalidArtifact;
        if (before.arguments.items.len != carry_count) return error.InvalidArtifact;
        if (after.arguments.items.len != carry_count) return error.InvalidArtifact;

        const carry_names = self.allocator.alloc([]const u8, carry_count) catch return error.OutOfMemory;
        defer self.allocator.free(carry_names);
        const exit_names = self.allocator.alloc([]const u8, carry_count) catch return error.OutOfMemory;
        defer self.allocator.free(exit_names);

        for (0..carry_count) |index| {
            const operand = op.op.operands.items[index].value;
            const carry_type = try wgslScalarType(try scalarKind(operand.type));
            carry_names[index] = try self.freshLoopName();
            try self.line("var {s}: {s} = {s};", .{ carry_names[index], carry_type, try self.require(operand) });
            exit_names[index] = try self.freshLoopName();
            try self.line("var {s}: {s};", .{ exit_names[index], carry_type });
            try self.bind(before.arguments.items[index], carry_names[index]);
        }

        self.while_depth += 1;
        defer self.while_depth -= 1;
        try self.line("loop {{", .{});
        self.indent += 1;

        var before_ops = before.getOperations();
        var saw_condition = false;
        while (before_ops.next()) |before_op| {
            if (std.mem.eql(u8, before_op.name.name, ScfDialect.ConditionOp.operation_name)) {
                const condition = ScfDialect.ConditionOp{ .op = before_op };
                const args = condition.getArgs();
                if (args.len != carry_count) return error.InvalidArtifact;
                try self.line("if (!({s})) {{", .{try self.require(condition.getCondition())});
                self.indent += 1;
                for (args, exit_names) |arg, exit_name| {
                    try self.line("{s} = {s};", .{ exit_name, try self.require(arg) });
                }
                try self.line("break;", .{});
                self.indent -= 1;
                try self.line("}}", .{});
                for (args, 0..) |arg, index| {
                    try self.bind(after.arguments.items[index], try self.require(arg));
                }
                saw_condition = true;
                break;
            }
            try self.emitOperation(before_op, null);
        }
        if (!saw_condition) return error.InvalidArtifact;

        var after_ops = after.getOperations();
        var saw_yield = false;
        while (after_ops.next()) |after_op| {
            if (std.mem.eql(u8, after_op.name.name, ScfDialect.YieldOp.operation_name)) {
                const yield = ScfDialect.YieldOp{ .op = after_op };
                const yielded = yield.getOperands();
                if (yielded.len != carry_count) return error.InvalidArtifact;
                for (yielded, carry_names) |yield_value, carry_name| {
                    try self.line("{s} = {s};", .{ carry_name, try self.require(yield_value) });
                }
                saw_yield = true;
                break;
            }
            try self.emitOperation(after_op, null);
        }
        if (!saw_yield) return error.InvalidArtifact;

        self.indent -= 1;
        try self.line("}}", .{});

        for (op.op.results.items, exit_names) |*result, exit_name| {
            try self.bind(result, exit_name);
        }
    }

    fn emitFor(self: *Emitter, op: ScfDialect.ForOp) EmitError!void {
        const init_args = op.getInitArgs();
        if (op.op.results.items.len != init_args.len) return error.InvalidArtifact;

        const accumulator_names = self.allocator.alloc([]const u8, init_args.len) catch return error.OutOfMemory;
        defer self.allocator.free(accumulator_names);

        const iter_args = op.getIterArgs();
        for (init_args, 0..) |initial, index| {
            const name = try self.freshLoopName();
            accumulator_names[index] = name;
            try self.line("var {s}: {s} = {s};", .{
                name,
                try wgslScalarType(try scalarKind(initial.type)),
                try self.require(initial),
            });
            try self.bind(iter_args[index], name);
        }

        const iv_name = try self.freshLoopName();
        try self.bind(op.getInductionVar(), iv_name);
        const lower = try self.require(op.getLowerBound());
        const upper = try self.require(op.getUpperBound());
        const step = try self.require(op.getStep());
        try self.line("for (var {s}: i32 = {s}; {s} < {s}; {s} = {s} + {s}) {{", .{ iv_name, lower, iv_name, upper, iv_name, iv_name, step });
        self.indent += 1;
        try self.emitBlock(op.getBodyBlock(), .{ .names = accumulator_names });
        self.indent -= 1;
        try self.line("}}", .{});

        for (op.op.results.items, 0..) |*result, index| {
            try self.bind(result, accumulator_names[index]);
        }
    }

    fn emitYield(self: *Emitter, op: ScfDialect.YieldOp, yield_target: ?YieldTarget) EmitError!void {
        const operands = op.getOperands();
        const target_names = if (yield_target) |target_binding| target_binding.names else {
            if (operands.len != 0) return error.UnsupportedOperation;
            return;
        };
        if (operands.len != target_names.len) return error.InvalidArtifact;
        for (operands, target_names) |operand, target_name| {
            try self.line("{s} = {s};", .{ target_name, try self.require(operand) });
        }
    }

    fn freshValueName(self: *Emitter) abi.Error![]const u8 {
        const index = self.next_value;
        self.next_value += 1;
        const name = std.fmt.allocPrint(self.allocator, "v{d}", .{index}) catch return error.OutOfMemory;
        return try self.rememberName(name);
    }

    fn freshLoopName(self: *Emitter) abi.Error![]const u8 {
        const index = self.next_loop;
        self.next_loop += 1;
        const name = std.fmt.allocPrint(self.allocator, "l{d}", .{index}) catch return error.OutOfMemory;
        return try self.rememberName(name);
    }

    fn freshSharedName(self: *Emitter) abi.Error![]const u8 {
        const index = self.next_shared;
        self.next_shared += 1;
        const name = std.fmt.allocPrint(self.allocator, "shared{d}", .{index}) catch return error.OutOfMemory;
        return try self.rememberName(name);
    }

    fn rememberAndBind(self: *Emitter, value: *const ir.Value, name: []u8) abi.Error!void {
        const owned = try self.rememberName(name);
        try self.bind(value, owned);
    }

    fn rememberName(self: *Emitter, name: []u8) abi.Error![]const u8 {
        self.names.append(self.allocator, name) catch {
            self.allocator.free(name);
            return error.OutOfMemory;
        };
        return name;
    }

    fn bind(self: *Emitter, value: *const ir.Value, name: []const u8) abi.Error!void {
        self.values.put(self.allocator, value, name) catch return error.OutOfMemory;
    }

    fn require(self: *Emitter, value: *const ir.Value) abi.Error![]const u8 {
        return self.values.get(value) orelse error.InvalidArtifact;
    }

    fn line(self: *Emitter, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        for (0..self.indent) |_| try self.body.writer.writeAll("    ");
        try self.body.writer.print(fmt, args);
        try self.body.writer.writeByte('\n');
    }
};

fn writeHeader(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("override choir_workgroup_size_x: u32 = 1u;\n");
    try writer.writeAll("override choir_workgroup_size_y: u32 = 1u;\n");
    try writer.writeAll("override choir_workgroup_size_z: u32 = 1u;\n\n");
}

fn writeUmulhiHelper(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\fn choir_umulhi_u32(lhs: u32, rhs: u32) -> u32 {
        \\    let lhs_lo: u32 = lhs & 0xffffu;
        \\    let lhs_hi: u32 = lhs >> 16u;
        \\    let rhs_lo: u32 = rhs & 0xffffu;
        \\    let rhs_hi: u32 = rhs >> 16u;
        \\    let low: u32 = lhs_lo * rhs_lo;
        \\    let mid0: u32 = lhs_lo * rhs_hi;
        \\    let mid1: u32 = lhs_hi * rhs_lo;
        \\    let high: u32 = lhs_hi * rhs_hi;
        \\    let carry: u32 = ((low >> 16u) + (mid0 & 0xffffu) + (mid1 & 0xffffu)) >> 16u;
        \\    return high + (mid0 >> 16u) + (mid1 >> 16u) + carry;
        \\}
        \\
        \\
    );
}

fn scalarKind(typ: ir.Type) abi.Error!ScalarKind {
    return scalar_kinds.kindFromType(typ) orelse error.UnsupportedOperation;
}

const MemrefInfo = struct {
    size: ?u64,
    element: ScalarKind,
    addr_space: dialects.AddressSpace,
};

fn memrefInfo(typ: ir.Type) ?MemrefInfo {
    const name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, name, MemrefDialect.name)) return null;
    const params = MemrefDialect.parseMemrefParams(typ.getDialectParamKey() orelse return null) orelse return null;
    return .{
        .size = params.size,
        .element = scalar_kinds.kindFromTypeName(params.element_type_name) orelse return null,
        .addr_space = params.addr_space,
    };
}

fn wgslScalarType(kind: ScalarKind) abi.Error![]const u8 {
    return switch (kind) {
        .bool => "bool",
        .index => "i32",
        .i32 => "i32",
        .u32 => "u32",
        .f32 => "f32",
        .i8, .i16, .i64, .u8, .u16, .u64, .f16, .bf16, .f64 => error.UnsupportedOperation,
    };
}

fn wgslStorageScalarType(kind: ScalarKind) abi.Error![]const u8 {
    return switch (kind) {
        .index => "i32",
        .i32 => "i32",
        .u32 => "u32",
        .f32 => "f32",
        .bool, .i8, .i16, .i64, .u8, .u16, .u64, .f16, .bf16, .f64 => error.UnsupportedOperation,
    };
}

fn wgslUnsignedScalarType(kind: ScalarKind) abi.Error![]const u8 {
    return switch (kind) {
        .index, .i32, .u32 => "u32",
        else => error.UnsupportedOperation,
    };
}

fn dimName(dim: gpu.Dimension) []const u8 {
    return switch (dim) {
        .x => "x",
        .y => "y",
        .z => "z",
    };
}

fn workgroupSizeOverride(dim: gpu.Dimension) []const u8 {
    return switch (dim) {
        .x => "choir_workgroup_size_x",
        .y => "choir_workgroup_size_y",
        .z => "choir_workgroup_size_z",
    };
}

fn comparisonOperator(pred: CmpPredicate) []const u8 {
    return switch (pred) {
        .eq => "==",
        .ne => "!=",
        .lt, .slt, .ult => "<",
        .le, .sle, .ule => "<=",
        .gt, .sgt, .ugt => ">",
        .ge, .sge, .uge => ">=",
    };
}

fn floatBits(value: f64) u32 {
    const narrowed: f32 = @floatCast(value);
    return @bitCast(narrowed);
}

test "webgpu scalar support mask follows Choir scalar spellings" {
    inline for (std.meta.tags(ScalarKind)) |kind| {
        const expected: ?ScalarKind = if (scalar_kinds.contains(kind)) kind else null;
        try std.testing.expectEqual(
            expected,
            scalar_kinds.kindFromTypeName(dialects.arith.scalarTypeName(kind)),
        );
    }
    try std.testing.expectEqual(@as(?ScalarKind, null), scalar_kinds.kindFromTypeName("arith.unknown"));
}
