const std = @import("std");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const spirv_target = @import("../root.zig");
const gpu_target = @import("../../../../dialects/gpu/root.zig");
const binary = @import("module.zig");
const scalar = @import("scalar.zig");
const spec = @import("spec.zig");
const spirv_ops = @import("ops.zig");

const ArithDialect = dialects.arith.ArithDialect;
const GpuDialect = gpu_target.GpuDialect;
const SpirvDialect = spirv_target.SpirvDialect;
const GpuDimension = gpu_target.Dimension;
const GpuScope = gpu_target.Scope;
const WarpOpKind = gpu_target.WarpOpKind;
const SpirvOp = spirv_ops.SpirvOp;
const SpvCapability = spec.Capability;
const SpvDecoration = spec.Decoration;
const SpvStorageClass = spec.StorageClass;
const SpirvVersion = binary.Version;
const SpvScope = spec.Scope;
const SpvMemorySemanticsMask = spec.MemorySemanticsMask;

const SpvGroupOperation = struct {
    const Reduce: u32 = 0;
    const InclusiveScan: u32 = 1;
    const ExclusiveScan: u32 = 2;
    const ClusteredReduce: u32 = 3;
};

pub const SpvBuiltIn = struct {
    pub const Position: u32 = 0;
    pub const FragCoord: u32 = 15;
    pub const FrontFacing: u32 = 17;
    pub const NumWorkgroups: u32 = 24;
    pub const WorkgroupSize: u32 = 25;
    pub const WorkgroupId: u32 = 26;
    pub const LocalInvocationId: u32 = 27;
    pub const GlobalInvocationId: u32 = 28;
    pub const SubgroupId: u32 = 40;
    pub const SubgroupLocalInvocationId: u32 = 41;
    pub const VertexIndex: u32 = 42;
    pub const InstanceIndex: u32 = 43;
};

pub const BuiltinKind = enum {
    num_workgroups,
    workgroup_size,
    workgroup_id,
    local_invocation_id,
    global_invocation_id,
    subgroup_id,
    subgroup_local_invocation_id,
    position,
    frag_coord,
    vertex_index,
    instance_index,
    front_facing,
};

pub const AllAnyKind = enum { all, any };

const GroupCapability = enum { vote, ballot, shuffle, shuffle_relative, arithmetic };

pub fn emitIndex(self: anytype, op: *ir.Operation, builtin: BuiltinKind) !void {
    const dim = getGpuDimension(op) orelse return error.MissingAttribute;
    const u32_type = try self.getScalarType(.u32);

    if (builtin == .workgroup_size) {
        if (self.kernel_shape) |shape| {
            const component_index: usize = switch (dim) {
                .x => 0,
                .y => 1,
                .z => 2,
            };
            const extent = shape[component_index];
            const result_id = try self.getIntConstant(u32_type, .u32, extent);
            const result = op.getResult(0) orelse return error.UnsupportedOperation;
            try self.bindValue(result, result_id);
            return;
        }
    }

    const composite_id = if (builtin == .workgroup_size)
        try self.getWorkgroupSizeConstant()
    else blk: {
        const builtin_id = try getBuiltinVar(self, builtin);
        const vec_type = try self.getVectorType(.u32, 3);
        const load_id = self.builder.newId();
        try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{
            vec_type,
            load_id,
            builtin_id,
        });
        break :blk load_id;
    };

    const result_id = self.builder.newId();
    const component_index: u32 = switch (dim) {
        .x => 0,
        .y => 1,
        .z => 2,
    };

    try self.builder.emit(&self.builder.functions, SpirvOp.CompositeExtract, &.{
        u32_type,
        result_id,
        composite_id,
        component_index,
    });

    const result = op.getResult(0) orelse return error.UnsupportedOperation;
    try self.bindValue(result, result_id);
}

/// Vulkan runs a control barrier only at Workgroup or Subgroup scope, so the
/// thread, cluster, device and system scopes are refused.
pub fn emitBarrier(self: anytype, op: *ir.Operation) !void {
    const barrier = GpuDialect.BarrierOp{ .op = op };
    const scope = barrier.getScope() orelse return error.MissingAttribute;
    const execution = spvScopeForBarrier(scope) orelse return error.UnsupportedOperation;
    try emitControlBarrier(self, execution);
}

/// Every storage class a kernel can write and read back across a barrier.
/// UniformMemory covers StorageBuffer, and ImageMemory covers storage images.
const barrier_semantics: u32 = SpvMemorySemanticsMask.AcquireRelease |
    SpvMemorySemanticsMask.UniformMemory |
    SpvMemorySemanticsMask.WorkgroupMemory |
    SpvMemorySemanticsMask.ImageMemory;

/// The execution scopes Vulkan allows for OpControlBarrier (VUID-04636).
const BarrierScope = enum(u32) {
    workgroup = SpvScope.Workgroup,
    subgroup = SpvScope.Subgroup,
};

/// Emits OpControlBarrier at `execution` scope with Workgroup memory scope.
/// Workgroup covers a subgroup's memory too, and a Subgroup memory scope
/// would need GroupNonUniform and SPIR-V 1.3 (VUID-07951).
fn emitControlBarrier(self: anytype, execution: BarrierScope) !void {
    const u32_type = try self.getScalarType(.u32);
    const exec_id = try self.getIntConstant(u32_type, .u32, @backingInt(execution));
    const mem_id = try self.getIntConstant(u32_type, .u32, SpvScope.Workgroup);
    const sem_id = try self.getIntConstant(u32_type, .u32, barrier_semantics);

    try self.builder.emit(&self.builder.functions, SpirvOp.ControlBarrier, &.{
        exec_id,
        mem_id,
        sem_id,
    });
}

pub fn emitSubgroupIndex(self: anytype, op: *ir.Operation, builtin: BuiltinKind) !void {
    const result = op.getResult(0) orelse return error.UnsupportedOperation;
    const builtin_id = try getBuiltinVar(self, builtin);
    const u32_type = try self.getScalarType(.u32);

    const load_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{
        u32_type,
        load_id,
        builtin_id,
    });

    try self.bindValue(result, load_id);
}

pub fn emitSyncWarp(self: anytype, op: *ir.Operation) !void {
    const sync = GpuDialect.SyncWarpOp{ .op = op };
    try requireFullMask(self, sync.getMask());
    try emitControlBarrier(self, .subgroup);
}

pub fn emitActiveMask(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.UnsupportedOperation;
    const true_id = try self.getBoolConstant(true);
    const mask_id = try emitGroupBallotMask(self, true_id);
    try bindMaskValue(self, result, mask_id);
}

pub fn emitAllAny(self: anytype, op: *ir.Operation, kind: AllAnyKind) !void {
    try requireFullMask(self, op.operands.items[0].value);
    try requireGroupNonUniform(self, .vote);
    const result = op.getResult(0) orelse return error.UnsupportedOperation;
    const predicate = op.operands.items[1].value;
    const pred_id = try self.getValue(predicate);
    const result_type_id = try self.getTypeForValue(result);

    const u32_type = try self.getScalarType(.u32);
    const scope_id = try self.getIntConstant(u32_type, .u32, SpvScope.Subgroup);
    const opcode = switch (kind) {
        .all => SpirvOp.GroupNonUniformAll,
        .any => SpirvOp.GroupNonUniformAny,
    };

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        scope_id,
        pred_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitBallot(self: anytype, op: *ir.Operation) !void {
    const ballot = GpuDialect.BallotSyncOp{ .op = op };
    try requireFullMask(self, ballot.getMask());
    const pred_id = try self.getValue(ballot.getPredicate());
    const result = ballot.getResult();
    const mask_id = try emitGroupBallotMask(self, pred_id);
    try bindMaskValue(self, result, mask_id);
}

pub fn emitShuffle(self: anytype, op: *ir.Operation) !void {
    const shfl = GpuDialect.ShflSyncOp{ .op = op };
    const mode = shfl.getMode() orelse return error.MissingAttribute;
    try requireFullMask(self, shfl.getMask());
    try requireGroupNonUniform(self, switch (mode) {
        .sync, .xor => .shuffle,
        .down, .up => .shuffle_relative,
    });
    const src_id = try self.getValue(shfl.getSrc());
    const lane_id = try self.getValue(shfl.getLaneOrDelta());
    const result = shfl.getResult();
    const result_type_id = try self.getTypeForValue(result);

    const u32_type = try self.getScalarType(.u32);
    const scope_id = try self.getIntConstant(u32_type, .u32, SpvScope.Subgroup);
    const opcode = switch (mode) {
        .sync => SpirvOp.GroupNonUniformShuffle,
        .down => SpirvOp.GroupNonUniformShuffleDown,
        .up => SpirvOp.GroupNonUniformShuffleUp,
        .xor => SpirvOp.GroupNonUniformShuffleXor,
    };

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        scope_id,
        src_id,
        lane_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitWarpReduce(self: anytype, op: *ir.Operation) !void {
    const reduce = GpuDialect.WarpReduceOp{ .op = op };
    try requireFullMask(self, reduce.getMask());
    try requireGroupNonUniform(self, .arithmetic);
    const op_kind = reduce.getOpKind() orelse return error.MissingAttribute;
    const value = reduce.getValue();
    const value_id = try self.getValue(value);
    const result = reduce.getResult();
    const kind = scalar.kindFromType(value.type) orelse return error.UnsupportedType;
    const opcode = groupNonUniformOpcode(op_kind, kind) orelse return error.UnsupportedType;

    const u32_type = try self.getScalarType(.u32);
    const scope_id = try self.getIntConstant(u32_type, .u32, SpvScope.Subgroup);
    const result_type_id = try self.getTypeForValue(result);
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        scope_id,
        SpvGroupOperation.Reduce,
        value_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitWarpScan(self: anytype, op: *ir.Operation) !void {
    const scan = GpuDialect.WarpScanOp{ .op = op };
    try requireFullMask(self, scan.getMask());
    try requireGroupNonUniform(self, .arithmetic);
    const op_kind = scan.getOpKind() orelse return error.MissingAttribute;
    const value = scan.getValue();
    const value_id = try self.getValue(value);
    const result = scan.getResult();
    const kind = scalar.kindFromType(value.type) orelse return error.UnsupportedType;
    const opcode = groupNonUniformOpcode(op_kind, kind) orelse return error.UnsupportedType;

    const u32_type = try self.getScalarType(.u32);
    const scope_id = try self.getIntConstant(u32_type, .u32, SpvScope.Subgroup);
    const group_op = if (scan.isInclusive())
        SpvGroupOperation.InclusiveScan
    else
        SpvGroupOperation.ExclusiveScan;
    const result_type_id = try self.getTypeForValue(result);
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        scope_id,
        group_op,
        value_id,
    });
    try self.bindValue(result, result_id);
}

fn requireGroupNonUniform(self: anytype, capability: GroupCapability) !void {
    self.builder.requireVersion(SpirvVersion.v13);
    try self.requireCapability(SpvCapability.GroupNonUniform);
    switch (capability) {
        .vote => try self.requireCapability(SpvCapability.GroupNonUniformVote),
        .ballot => try self.requireCapability(SpvCapability.GroupNonUniformBallot),
        .shuffle => try self.requireCapability(SpvCapability.GroupNonUniformShuffle),
        .shuffle_relative => try self.requireCapability(SpvCapability.GroupNonUniformShuffleRelative),
        .arithmetic => try self.requireCapability(SpvCapability.GroupNonUniformArithmetic),
    }
}

fn requireFullMask(self: anytype, mask: *ir.Value) !void {
    if (isFullMaskValue(self, mask)) return;
    return error.UnsupportedMask;
}

fn isFullMaskValue(self: anytype, mask: *ir.Value) bool {
    _ = self;
    const kind = scalar.kindFromType(mask.type) orelse return false;
    if (!scalar.isInt(kind)) return false;

    const defining = mask.getDefiningOp() orelse return false;
    const def_op: *ir.Operation = @ptrCast(@alignCast(defining));
    if (std.mem.eql(u8, def_op.name.name, ArithDialect.ConstantOp.operation_name)) {
        const constant = ArithDialect.ConstantOp{ .op = def_op };
        if (constant.getIntValue()) |int_value| {
            return scalar.isFullMaskConstant(kind, int_value);
        }
    }
    if (std.mem.eql(u8, def_op.name.name, SpirvDialect.ConstantOp.operation_name)) {
        const constant = SpirvDialect.ConstantOp{ .op = def_op };
        if (constant.getIntValue()) |int_value| {
            return scalar.isFullMaskConstant(kind, int_value);
        }
    }
    return false;
}

fn emitGroupBallotMask(self: anytype, pred_id: u32) !u32 {
    try requireGroupNonUniform(self, .ballot);
    const vec_type = try self.getVectorType(.u32, 4);
    const u32_type = try self.getScalarType(.u32);
    const scope_id = try self.getIntConstant(u32_type, .u32, SpvScope.Subgroup);

    const ballot_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.GroupNonUniformBallot, &.{
        vec_type,
        ballot_id,
        scope_id,
        pred_id,
    });

    const mask_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.CompositeExtract, &.{
        u32_type,
        mask_id,
        ballot_id,
        0,
    });
    return mask_id;
}

fn bindMaskValue(self: anytype, result: *ir.Value, mask_id: u32) !void {
    const result_kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
    if (result_kind == .u32) {
        try self.bindValue(result, mask_id);
        return;
    }
    if (result_kind == .i32) {
        const result_type_id = try self.getScalarType(.i32);
        const cast_id = self.builder.newId();
        try self.builder.emit(&self.builder.functions, SpirvOp.Bitcast, &.{
            result_type_id,
            cast_id,
            mask_id,
        });
        try self.bindValue(result, cast_id);
        return;
    }
    return error.UnsupportedType;
}

pub fn getBuiltinVar(self: anytype, builtin: BuiltinKind) !u32 {
    if (self.builtin_vars.get(builtin)) |id| {
        try self.addInterfaceVar(id);
        return id;
    }

    const value_type = try builtinType(self, builtin);
    const storage_class: u32 = if (builtin == .position)
        SpvStorageClass.Output
    else
        SpvStorageClass.Input;
    const ptr_type = try self.getPointerType(storage_class, value_type);

    const var_id = self.builder.newId();
    try self.builder.emit(&self.builder.globals, SpirvOp.Variable, &.{
        ptr_type,
        var_id,
        storage_class,
    });

    const builtin_value: u32 = switch (builtin) {
        .num_workgroups => SpvBuiltIn.NumWorkgroups,
        .workgroup_size => return error.UnsupportedOperation,
        .workgroup_id => SpvBuiltIn.WorkgroupId,
        .local_invocation_id => SpvBuiltIn.LocalInvocationId,
        .global_invocation_id => SpvBuiltIn.GlobalInvocationId,
        .subgroup_id => SpvBuiltIn.SubgroupId,
        .subgroup_local_invocation_id => SpvBuiltIn.SubgroupLocalInvocationId,
        .position => SpvBuiltIn.Position,
        .frag_coord => SpvBuiltIn.FragCoord,
        .vertex_index => SpvBuiltIn.VertexIndex,
        .instance_index => SpvBuiltIn.InstanceIndex,
        .front_facing => SpvBuiltIn.FrontFacing,
    };

    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        var_id,
        SpvDecoration.BuiltIn,
        builtin_value,
    });

    try self.builtin_vars.put(self.allocator, builtin, var_id);
    try self.addInterfaceVar(var_id);
    return var_id;
}

/// The type a builtin variable holds.
pub fn builtinType(self: anytype, builtin: BuiltinKind) !u32 {
    return switch (builtin) {
        .num_workgroups,
        .workgroup_size,
        .workgroup_id,
        .local_invocation_id,
        .global_invocation_id,
        => self.getVectorType(.u32, 3),
        .subgroup_id,
        .subgroup_local_invocation_id,
        .vertex_index,
        .instance_index,
        => self.getScalarType(.u32),
        .position, .frag_coord => self.getVectorType(.f32, 4),
        .front_facing => self.getScalarType(.bool),
    };
}

fn spvScopeForBarrier(scope: GpuScope) ?BarrierScope {
    return switch (scope) {
        .warp => .subgroup,
        .block => .workgroup,
        .thread, .cluster, .device, .system => null,
    };
}

fn groupNonUniformOpcode(op_kind: WarpOpKind, scalar_kind: scalar.Kind) ?u16 {
    return switch (op_kind) {
        .add => if (scalar.isFloat(scalar_kind))
            SpirvOp.GroupNonUniformFAdd
        else if (scalar.isInt(scalar_kind))
            SpirvOp.GroupNonUniformIAdd
        else
            null,
        .min => if (scalar.isFloat(scalar_kind))
            SpirvOp.GroupNonUniformFMin
        else if (scalar.isSignedInt(scalar_kind))
            SpirvOp.GroupNonUniformSMin
        else if (scalar.isUnsignedInt(scalar_kind))
            SpirvOp.GroupNonUniformUMin
        else
            null,
        .max => if (scalar.isFloat(scalar_kind))
            SpirvOp.GroupNonUniformFMax
        else if (scalar.isSignedInt(scalar_kind))
            SpirvOp.GroupNonUniformSMax
        else if (scalar.isUnsignedInt(scalar_kind))
            SpirvOp.GroupNonUniformUMax
        else
            null,
        .and_ => if (scalar_kind == .bool)
            SpirvOp.GroupNonUniformLogicalAnd
        else if (scalar.isInt(scalar_kind))
            SpirvOp.GroupNonUniformBitwiseAnd
        else
            null,
        .or_ => if (scalar_kind == .bool)
            SpirvOp.GroupNonUniformLogicalOr
        else if (scalar.isInt(scalar_kind))
            SpirvOp.GroupNonUniformBitwiseOr
        else
            null,
        .xor => if (scalar_kind == .bool)
            SpirvOp.GroupNonUniformLogicalXor
        else if (scalar.isInt(scalar_kind))
            SpirvOp.GroupNonUniformBitwiseXor
        else
            null,
    };
}

fn getGpuDimension(op: *ir.Operation) ?GpuDimension {
    if (std.mem.eql(u8, op.name.name, GpuDialect.ThreadIdxOp.operation_name)) {
        const thread = GpuDialect.ThreadIdxOp{ .op = op };
        return thread.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, GpuDialect.BlockIdxOp.operation_name)) {
        const block = GpuDialect.BlockIdxOp{ .op = op };
        return block.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, GpuDialect.BlockDimOp.operation_name)) {
        const dim = GpuDialect.BlockDimOp{ .op = op };
        return dim.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, GpuDialect.GridDimOp.operation_name)) {
        const dim = GpuDialect.GridDimOp{ .op = op };
        return dim.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, GpuDialect.GlobalIdxOp.operation_name)) {
        const global = GpuDialect.GlobalIdxOp{ .op = op };
        return global.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, SpirvDialect.LocalInvocationIdOp.operation_name)) {
        const local = SpirvDialect.LocalInvocationIdOp{ .op = op };
        return local.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, SpirvDialect.WorkgroupIdOp.operation_name)) {
        const wg = SpirvDialect.WorkgroupIdOp{ .op = op };
        return wg.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, SpirvDialect.WorkgroupSizeOp.operation_name)) {
        const wg_size = SpirvDialect.WorkgroupSizeOp{ .op = op };
        return wg_size.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, SpirvDialect.NumWorkgroupsOp.operation_name)) {
        const num = SpirvDialect.NumWorkgroupsOp{ .op = op };
        return num.getDimension();
    }
    if (std.mem.eql(u8, op.name.name, SpirvDialect.GlobalInvocationIdOp.operation_name)) {
        const global = SpirvDialect.GlobalInvocationIdOp{ .op = op };
        return global.getDimension();
    }
    const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "dim") orelse return null;
    return GpuDimension.fromString(dialect_attr.payload);
}

test "spirv gpu maps barrier scopes Vulkan runs and refuses the rest" {
    try std.testing.expectEqual(@as(?BarrierScope, .subgroup), spvScopeForBarrier(.warp));
    try std.testing.expectEqual(@as(?BarrierScope, .workgroup), spvScopeForBarrier(.block));
    try std.testing.expectEqual(@as(?BarrierScope, null), spvScopeForBarrier(.thread));
    try std.testing.expectEqual(@as(?BarrierScope, null), spvScopeForBarrier(.cluster));
    try std.testing.expectEqual(@as(?BarrierScope, null), spvScopeForBarrier(.device));
    try std.testing.expectEqual(@as(?BarrierScope, null), spvScopeForBarrier(.system));
}

/// A kernel that stores to a storage buffer, then runs `barrier`.
fn barrierKernel(comptime barrier: []const u8) []const u8 {
    return
    \\builtin.module() {
    \\  ^bb0:
    \\    func.func() {input_count = 1:i64, input_types = [!memref<?,arith.i32,device>], input_types_text = "!memref<?,arith.i32,device>", kernel = #attr<func.kernel>, sym_name = #attr<func.sym_name>("test_barrier")} {
    \\      ^bb0(%0: !memref<?,arith.i32,device>):
    \\        %1 = gpu.global_idx() {dim = #attr<gpu.dim>("x")} : !arith.index
    \\        %2 = arith.cast(%1) : !arith.i32
    \\        memref.store(%2, %0, %1)
    \\
    ++ barrier ++
        \\
        \\        func.return()
        \\    }
        \\}
        \\
    ;
}

const BarrierCensus = struct {
    count: u32 = 0,
    execution: u32 = 0,
    memory: u32 = 0,
    semantics: u32 = 0,
    group_non_uniform: bool = false,
};

/// Emits `source` and reads back every OpControlBarrier's constant operands.
fn censusBarriers(source: []const u8) !BarrierCensus {
    const fixture = @import("../../fixture/root.zig");
    const registration = @import("../../registration.zig");
    const plan = @import("plan.zig");
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try fixture.lower(&ctx, source, .spirv);
    defer module.erase();
    const emission = try plan.emitPlanWords(allocator, module, "test_barrier", .{}, .{});
    defer allocator.free(emission.words);
    const words = emission.words;

    var census: BarrierCensus = .{};
    var index: usize = 5;
    while (index < words.len) {
        const word_count = words[index] >> 16;
        try std.testing.expect(word_count > 0);
        const opcode: u16 = @truncate(words[index]);
        if (opcode == SpirvOp.Capability and words[index + 1] == SpvCapability.GroupNonUniform) {
            census.group_non_uniform = true;
        }
        if (opcode == SpirvOp.ControlBarrier) {
            census.count += 1;
            census.execution = try constantValue(words, words[index + 1]);
            census.memory = try constantValue(words, words[index + 2]);
            census.semantics = try constantValue(words, words[index + 3]);
        }
        index += word_count;
    }
    try std.testing.expectEqual(words.len, index);
    return census;
}

fn constantValue(words: []const u32, id: u32) !u32 {
    var index: usize = 5;
    while (index < words.len) {
        const word_count = words[index] >> 16;
        const opcode: u16 = @truncate(words[index]);
        if (opcode == SpirvOp.Constant and word_count == 4 and words[index + 2] == id) return words[index + 3];
        index += word_count;
    }
    return error.TestUnexpectedResult;
}

test "spirv gpu barriers order storage buffer and workgroup memory at a Vulkan scope" {
    const Case = struct { source: []const u8, execution: u32 };
    const cases = [_]Case{
        .{
            .source = comptime barrierKernel("        gpu.barrier() {scope = #attr<gpu.scope>(\"block\")}"),
            .execution = SpvScope.Workgroup,
        },
        .{
            .source = comptime barrierKernel("        gpu.barrier() {scope = #attr<gpu.scope>(\"warp\")}"),
            .execution = SpvScope.Subgroup,
        },
        .{
            .source = comptime barrierKernel(
                \\        %3 = arith.constant() properties(-1:i64) : !arith.i32
                \\        gpu.sync_warp(%3)
            ),
            .execution = SpvScope.Subgroup,
        },
    };
    for (cases) |case| {
        const census = try censusBarriers(case.source);
        try std.testing.expectEqual(@as(u32, 1), census.count);
        try std.testing.expectEqual(case.execution, census.execution);
        try std.testing.expectEqual(SpvScope.Workgroup, census.memory);
        try std.testing.expectEqual(barrier_semantics, census.semantics);
        try std.testing.expect(!census.group_non_uniform);
    }
    try std.testing.expect(barrier_semantics & SpvMemorySemanticsMask.UniformMemory != 0);
}

test "spirv gpu refuses barrier scopes Vulkan cannot run" {
    const sources = [_][]const u8{
        comptime barrierKernel("        gpu.barrier() {scope = #attr<gpu.scope>(\"thread\")}"),
        comptime barrierKernel("        gpu.barrier() {scope = #attr<gpu.scope>(\"cluster\")}"),
        comptime barrierKernel("        gpu.barrier() {scope = #attr<gpu.scope>(\"device\")}"),
        comptime barrierKernel("        gpu.barrier() {scope = #attr<gpu.scope>(\"system\")}"),
    };
    for (sources) |source| {
        try std.testing.expectError(error.UnsupportedOperation, censusBarriers(source));
    }
}

test "spirv gpu maps warp reductions by scalar kind" {
    try std.testing.expectEqual(SpirvOp.GroupNonUniformFAdd, groupNonUniformOpcode(.add, .f32).?);
    try std.testing.expectEqual(SpirvOp.GroupNonUniformIAdd, groupNonUniformOpcode(.add, .i32).?);
    try std.testing.expectEqual(SpirvOp.GroupNonUniformSMin, groupNonUniformOpcode(.min, .i32).?);
    try std.testing.expectEqual(SpirvOp.GroupNonUniformUMax, groupNonUniformOpcode(.max, .u32).?);
    try std.testing.expectEqual(SpirvOp.GroupNonUniformLogicalAnd, groupNonUniformOpcode(.and_, .bool).?);
    try std.testing.expectEqual(@as(?u16, null), groupNonUniformOpcode(.and_, .f32));
}
