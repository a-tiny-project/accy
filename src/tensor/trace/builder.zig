const std = @import("std");
const tensor = @import("../root.zig");
const trace = @import("root.zig");

const Binary = trace.Binary;
const CompareDirection = trace.CompareDirection;
const DType = trace.DType;
const Dim = trace.Dim;
const Id = trace.Id;
const Program = trace.Program;
const Reducer = trace.Reducer;
const Spec = trace.Spec;
const Type = trace.Type;
const Unary = trace.Unary;
const Value = trace.Value;
const program_mod = tensor.program;
const type_mod = tensor.types;

pub const ScanScope = struct {
    parent: *Builder,
    child: Builder,
    length: i64,
    init_ids: []const Id,
    phase: Phase = .open,

    const Phase = enum { open, done };

    pub fn body(self: *ScanScope) *Builder {
        return &self.child;
    }

    pub fn carry(self: *ScanScope, index: usize) Value {
        return self.child.makeValue(self.child.parameters_list.items[index]);
    }

    pub fn finish(self: *ScanScope, next: []const Value) !Value {
        if (self.phase != .open) return error.ScanScopeMisused;
        if (next.len != self.init_ids.len) return error.ScanArityMismatch;
        const output_ids = try self.child.arena.allocator().alloc(Id, next.len);
        for (next, output_ids) |value, *slot| {
            try self.child.ensureValue(value);
            slot.* = value.id;
        }
        const body_view = program_mod.Subgraph{
            .values = self.child.values.items,
            .operations = self.child.operations.items,
            .parameters = self.child.parameters_list.items,
            .outputs = output_ids,
        };
        const result = try self.parent.emitScanIds(self.length, self.init_ids, &body_view);
        self.abort();
        return result;
    }

    pub fn abort(self: *ScanScope) void {
        if (self.phase == .done) return;
        self.child.deinit();
        self.phase = .done;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    values: std.ArrayListUnmanaged(Type) = .empty,
    operations: std.ArrayListUnmanaged(program_mod.Operation) = .empty,
    parameters_list: std.ArrayListUnmanaged(Id) = .empty,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Builder {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var builder = Builder{
            .allocator = allocator,
            .arena = arena,
            .name = &.{},
        };
        builder.name = try builder.arena.allocator().dupe(u8, name);
        return builder;
    }

    pub fn deinit(self: *Builder) void {
        if (!self.finished) {
            self.arena.deinit();
            self.finished = true;
        }
    }

    pub fn input(self: *Builder, dtype: DType, dims_struct: anytype) !Value {
        var buffer: [type_mod.dimCount(@TypeOf(dims_struct))]Dim = undefined;
        type_mod.fillDims(dims_struct, &buffer);
        return self.inputDims(dtype, &buffer);
    }

    pub fn inputDims(self: *Builder, dtype: DType, dims: []const Dim) !Value {
        try type_mod.validateAuthoredDims(dims);
        return self.inputTyped(.{ .dtype = dtype, .dims = dims });
    }

    pub fn inputSpec(self: *Builder, input_spec: Spec) !Value {
        return self.inputDims(input_spec.dtype, input_spec.dims);
    }

    pub fn inputs(self: *Builder, specs: []const Spec) ![]Value {
        const result = try self.arena.allocator().alloc(Value, specs.len);
        for (specs, 0..) |input_spec, index| {
            result[index] = try self.inputSpec(input_spec);
        }
        return result;
    }

    pub fn inputTyped(self: *Builder, ty: Type) !Value {
        const owned = try self.copyType(ty);
        const id = try self.append(
            owned,
            .{ .parameter = .{ .index = self.parameters_list.items.len } },
        );
        try self.parameters_list.append(self.arena.allocator(), id);
        return self.makeValue(id);
    }

    pub fn operation(self: *Builder, op: *const program_mod.Operation, args: []const Value) !Value {
        return switch (op.kind) {
            .parameter => self.inputTyped(op.result),
            .constant => |constant| self.constantBytes(op.result, constant.payload),
            .iota => |iota_op| self.iotaTyped(op.result, iota_op.axis),
            .unary => |unary_op| self.unary(unary_op.op, args[0]),
            .binary => |binary_op| self.binary(binary_op.op, args[0], args[1]),
            .broadcast => self.broadcastOp(args[0], op.result.dims),
            .broadcast_in_dim => |broadcast_op| self.broadcastTo(
                args[0],
                op.result.dims,
                broadcast_op.broadcast_dims,
            ),
            .reshape => self.reshapeTo(args[0], op.result.dims),
            .transpose => |transpose_op| self.transposeBy(args[0], transpose_op.permutation),
            .reduce => |reduce_op| self.reduce(
                args[0],
                args[1],
                reduce_op.reducer,
                reduce_op.dimensions,
            ),
            .gather => |gather_op| self.gatherOp(args[0], args[1], gather_op.axis),
            .scatter_add => |scatter_add| self.scatterAddOp(
                args[0],
                args[1],
                args[2],
                scatter_add.axis,
            ),
            .sparse_cross_entropy => |sparse_cross_entropy_op| self.sparseCrossEntropyOp(
                args[0],
                args[1],
                sparse_cross_entropy_op.axis,
            ),
            .compare => |compare_op| self.compare(compare_op.direction, args[0], args[1]),
            .select => self.select(args[0], args[1], args[2]),
            .custom_call => |custom_call| self.customCall(
                custom_call.target,
                custom_call.version,
                args,
                op.result,
            ),
            .dot_general => |dot| self.dotGeneralOp(
                args[0],
                args[1],
                dot.lhs_contract,
                dot.rhs_contract,
                dot.lhs_batch,
                dot.rhs_batch,
            ),
            .scan => |scan_op| self.emitScan(
                scan_op.length,
                args[0..scan_op.inits.len],
                scan_op.body,
            ),
            .projection => |projection_op| self.projection(args[0], projection_op.index),
        };
    }

    pub fn scalar(self: *Builder, comptime dtype: DType, scalar_value: dtype.ZigType()) !Value {
        const ty = Type.scalar(dtype);
        return self.constantBytes(ty, std.mem.asBytes(&scalar_value));
    }

    pub fn full(
        self: *Builder,
        comptime dtype: DType,
        dims_struct: anytype,
        fill_value: dtype.ZigType(),
    ) !Value {
        var buffer: [type_mod.dimCount(@TypeOf(dims_struct))]Dim = undefined;
        type_mod.fillDims(dims_struct, &buffer);
        return self.fullDims(dtype, &buffer, fill_value);
    }

    pub fn fullDims(
        self: *Builder,
        comptime dtype: DType,
        dims: []const Dim,
        fill_value: dtype.ZigType(),
    ) !Value {
        try type_mod.validateAuthoredDims(dims);
        const ty = try Type.init(self.arena.allocator(), dtype, dims);
        const count = try ty.elementCount();
        const payload = try self.arena.allocator().alloc(dtype.ZigType(), count);
        for (payload) |*slot| {
            slot.* = fill_value;
        }
        return self.constantOwned(ty, std.mem.sliceAsBytes(payload));
    }

    pub fn fullFloat(self: *Builder, ty: Type, fill_value: f64) !Value {
        const owned = try self.copyType(ty);
        const count = try owned.elementCount();
        return switch (owned.dtype) {
            .f16 => blk: {
                const payload = try self.arena.allocator().alloc(f16, count);
                const value: f16 = @floatCast(fill_value);
                for (payload) |*slot| slot.* = value;
                break :blk self.constantOwned(owned, std.mem.sliceAsBytes(payload));
            },
            .bf16 => blk: {
                const Bf16 = DType.bf16.ZigType();
                const payload = try self.arena.allocator().alloc(Bf16, count);
                const value = Bf16.fromF32(@floatCast(fill_value));
                for (payload) |*slot| slot.* = value;
                break :blk self.constantOwned(owned, std.mem.sliceAsBytes(payload));
            },
            .f32 => blk: {
                const payload = try self.arena.allocator().alloc(f32, count);
                const value: f32 = @floatCast(fill_value);
                for (payload) |*slot| slot.* = value;
                break :blk self.constantOwned(owned, std.mem.sliceAsBytes(payload));
            },
            .f64 => blk: {
                const payload = try self.arena.allocator().alloc(f64, count);
                for (payload) |*slot| slot.* = fill_value;
                break :blk self.constantOwned(owned, std.mem.sliceAsBytes(payload));
            },
            else => error.NonFloatDType,
        };
    }

    pub fn constantBytes(self: *Builder, ty: Type, payload: []const u8) !Value {
        if (payload.len != try ty.byteCount()) return error.PayloadLengthMismatch;
        return self.constantOwned(
            try self.copyType(ty),
            try self.arena.allocator().dupe(u8, payload),
        );
    }

    pub fn zeros(self: *Builder, ty: Type) !Value {
        const owned = try self.copyType(ty);
        const payload = try self.arena.allocator().alloc(u8, try owned.byteCount());
        @memset(payload, 0);
        return self.constantOwned(owned, payload);
    }

    pub fn isStructuralZero(self: *Builder, id: Id) bool {
        const index: usize = @intCast(id.index);
        if (index >= self.operations.items.len) return false;
        return switch (self.operations.items[index].kind) {
            .constant => |constant| program_mod.isZeroPayload(constant.payload),
            .unary => |unary_op| switch (unary_op.op) {
                .neg => self.isStructuralZero(unary_op.input),
                else => false,
            },
            .binary => |binary_op| switch (binary_op.op) {
                .add, .sub => self.isStructuralZero(binary_op.lhs) and
                    self.isStructuralZero(binary_op.rhs),
                .mul => self.isStructuralZero(binary_op.lhs) or
                    self.isStructuralZero(binary_op.rhs),
                else => false,
            },
            .broadcast => |broadcast_op| self.isStructuralZero(broadcast_op.input),
            .broadcast_in_dim => |broadcast_op| self.isStructuralZero(broadcast_op.input),
            .reshape => |reshape_op| self.isStructuralZero(reshape_op.input),
            .transpose => |transpose_op| self.isStructuralZero(transpose_op.input),
            .gather => |gather_op| self.isStructuralZero(gather_op.input),
            .scatter_add => |scatter_add| self.isStructuralZero(scatter_add.input) and
                self.isStructuralZero(scatter_add.updates),
            .select => |select_op| self.isStructuralZero(select_op.on_true) and
                self.isStructuralZero(select_op.on_false),
            else => false,
        };
    }

    pub fn iota(self: *Builder, dtype: DType, dims_struct: anytype, comptime axis: anytype) !Value {
        var buffer: [type_mod.dimCount(@TypeOf(dims_struct))]Dim = undefined;
        type_mod.fillDims(dims_struct, &buffer);
        return self.iotaDims(dtype, &buffer, comptime nameOf(axis));
    }

    pub fn iotaDims(self: *Builder, dtype: DType, dims: []const Dim, axis_name: []const u8) !Value {
        try type_mod.validateAuthoredDims(dims);
        const index = type_mod.findDim(dims, axis_name) orelse return error.AxisNotFound;
        return self.iotaTyped(.{ .dtype = dtype, .dims = dims }, @intCast(index));
    }

    fn iotaTyped(self: *Builder, ty: Type, axis: i64) !Value {
        try type_mod.validateAxes(ty.dims.len, &.{axis});
        return self.emit(try self.copyType(ty), .{ .iota = .{ .axis = axis } });
    }

    pub fn unary(self: *Builder, op: Unary, operand_value: Value) !Value {
        try self.ensureValue(operand_value);
        return self.emit(try self.copyType(operand_value.ty), .{
            .unary = .{ .op = op, .input = operand_value.id },
        });
    }

    pub fn binary(self: *Builder, op: Binary, lhs: Value, rhs: Value) !Value {
        try self.ensureValue(lhs);
        try self.ensureValue(rhs);
        try type_mod.sameType(lhs.ty, rhs.ty);
        return self.emit(try self.copyType(lhs.ty), .{
            .binary = .{ .op = op, .lhs = lhs.id, .rhs = rhs.id },
        });
    }

    pub fn alignedBinary(self: *Builder, op: Binary, lhs: Value, rhs: Value) !Value {
        try self.ensureValue(lhs);
        try self.ensureValue(rhs);
        if (lhs.ty.dtype != rhs.ty.dtype) return error.DTypeMismatch;
        const target = try type_mod.unionDims(self.arena.allocator(), lhs.ty.dims, rhs.ty.dims);
        const left = try self.alignTo(lhs, target);
        const right = try self.alignTo(rhs, target);
        return self.binary(op, left, right);
    }

    pub fn customCall(
        self: *Builder,
        target: []const u8,
        version: u32,
        operands: []const Value,
        result_ty: Type,
    ) !Value {
        if (target.len == 0) return error.InvalidCustomCallContract;
        if (version == 0) return error.InvalidCustomCallContract;
        if (operands.len > program_mod.max_custom_call_operands) {
            return error.UnsupportedCustomCallArity;
        }
        const arena = self.arena.allocator();
        const ids = try arena.alloc(program_mod.Id, operands.len);
        for (operands, ids) |operand, *id| {
            try self.ensureValue(operand);
            id.* = operand.id;
        }
        return self.emit(try self.copyType(result_ty), .{
            .custom_call = .{
                .target = try arena.dupe(u8, target),
                .version = version,
                .operands = ids,
            },
        });
    }

    pub fn compare(self: *Builder, direction: CompareDirection, lhs: Value, rhs: Value) !Value {
        try self.ensureValue(lhs);
        try self.ensureValue(rhs);
        try type_mod.sameType(lhs.ty, rhs.ty);
        const pred_ty = try self.copyType(.{ .dtype = .i1, .dims = lhs.ty.dims });
        return self.emit(pred_ty, .{
            .compare = .{ .lhs = lhs.id, .rhs = rhs.id, .direction = direction },
        });
    }

    pub fn alignedCompare(
        self: *Builder,
        direction: CompareDirection,
        lhs: Value,
        rhs: Value,
    ) !Value {
        try self.ensureValue(lhs);
        try self.ensureValue(rhs);
        if (lhs.ty.dtype != rhs.ty.dtype) return error.DTypeMismatch;
        const target = try type_mod.unionDims(self.arena.allocator(), lhs.ty.dims, rhs.ty.dims);
        const left = try self.alignTo(lhs, target);
        const right = try self.alignTo(rhs, target);
        return self.compare(direction, left, right);
    }

    pub fn select(self: *Builder, pred: Value, on_true: Value, on_false: Value) !Value {
        try self.ensureValue(pred);
        try self.ensureValue(on_true);
        try self.ensureValue(on_false);
        const ty = try type_mod.select(self.arena.allocator(), pred.ty, on_true.ty, on_false.ty);
        return self.emit(ty, .{
            .select = .{ .pred = pred.id, .on_true = on_true.id, .on_false = on_false.id },
        });
    }

    pub fn alignedSelect(self: *Builder, pred: Value, on_true: Value, on_false: Value) !Value {
        try self.ensureValue(pred);
        try self.ensureValue(on_true);
        try self.ensureValue(on_false);
        if (on_true.ty.dtype != on_false.ty.dtype) return error.DTypeMismatch;
        const arena = self.arena.allocator();
        var target = try type_mod.unionDims(arena, on_true.ty.dims, on_false.ty.dims);
        if (pred.ty.rank() != 0) {
            target = try type_mod.unionDims(arena, target, pred.ty.dims);
        }
        const chosen_true = try self.alignTo(on_true, target);
        const chosen_false = try self.alignTo(on_false, target);
        const chosen_pred = if (pred.ty.rank() == 0) pred else try self.alignTo(pred, target);
        return self.select(chosen_pred, chosen_true, chosen_false);
    }

    pub fn broadcastAxes(self: *Builder, operand_value: Value, added: []const Dim) !Value {
        try self.ensureValue(operand_value);
        try type_mod.validateAuthoredDims(added);
        const target = try type_mod.appendDims(
            self.arena.allocator(),
            operand_value.ty.dims,
            added,
        );
        return self.alignTo(operand_value, target);
    }

    pub fn renameAxis(
        self: *Builder,
        operand_value: Value,
        old_name: []const u8,
        new_name: []const u8,
    ) !Value {
        try self.ensureValue(operand_value);
        try type_mod.validateAuthoredName(new_name);
        const new_dims = try type_mod.renamed(
            self.arena.allocator(),
            operand_value.ty.dims,
            old_name,
            new_name,
        );
        return self.reshapeTo(operand_value, new_dims);
    }

    pub fn splitAxis(
        self: *Builder,
        operand_value: Value,
        axis_name: []const u8,
        parts: []const Dim,
    ) !Value {
        try self.ensureValue(operand_value);
        try type_mod.validateAuthoredDims(parts);
        const new_dims = try type_mod.splitDims(
            self.arena.allocator(),
            operand_value.ty.dims,
            axis_name,
            parts,
        );
        return self.reshapeTo(operand_value, new_dims);
    }

    pub fn mergeAxes(
        self: *Builder,
        operand_value: Value,
        names: []const []const u8,
        merged_name: []const u8,
    ) !Value {
        try self.ensureValue(operand_value);
        try type_mod.validateAuthoredName(merged_name);
        const plan = try type_mod.mergeDims(
            self.arena.allocator(),
            operand_value.ty.dims,
            names,
            merged_name,
        );
        var current = operand_value;
        if (plan.permutation) |permutation| {
            current = try self.transposeBy(current, permutation);
        }
        return self.reshapeTo(current, plan.result);
    }

    pub fn alignTo(self: *Builder, operand_value: Value, target: []const Dim) !Value {
        if (type_mod.sameDims(operand_value.ty.dims, target)) return operand_value;
        const plan = try type_mod.alignment(self.arena.allocator(), operand_value.ty.dims, target);
        var current = operand_value;
        if (plan.permutation) |permutation| {
            current = try self.transposeBy(current, permutation);
        }
        if (type_mod.sameDims(current.ty.dims, target)) return current;
        return self.broadcastTo(current, target, plan.mapping.?);
    }

    pub fn broadcastOp(self: *Builder, operand_value: Value, result_dims: []const Dim) !Value {
        try self.ensureValue(operand_value);
        const ty = try Type.init(self.arena.allocator(), operand_value.ty.dtype, result_dims);
        return self.emit(ty, .{
            .broadcast = .{
                .input = operand_value.id,
                .sizes = try type_mod.extents(self.arena.allocator(), ty.dims),
            },
        });
    }

    pub fn broadcastTo(
        self: *Builder,
        operand_value: Value,
        result_dims: []const Dim,
        broadcast_dims: []const i64,
    ) !Value {
        try self.ensureValue(operand_value);
        const ty = try type_mod.broadcastInDim(
            self.arena.allocator(),
            operand_value.ty,
            result_dims,
            broadcast_dims,
        );
        return self.emit(ty, .{
            .broadcast_in_dim = .{
                .input = operand_value.id,
                .broadcast_dims = try self.arena.allocator().dupe(i64, broadcast_dims),
            },
        });
    }

    pub fn reshapeTo(self: *Builder, operand_value: Value, new_dims: []const Dim) !Value {
        try self.ensureValue(operand_value);
        const ty = try type_mod.reshaped(self.arena.allocator(), operand_value.ty, new_dims);
        return self.emit(ty, .{
            .reshape = .{
                .input = operand_value.id,
                .new_shape = try type_mod.extents(self.arena.allocator(), ty.dims),
            },
        });
    }

    pub fn transposeBy(self: *Builder, operand_value: Value, permutation: []const i64) !Value {
        try self.ensureValue(operand_value);
        const result_dims = try type_mod.permuted(
            self.arena.allocator(),
            operand_value.ty.dims,
            permutation,
        );
        const ty = try Type.init(self.arena.allocator(), operand_value.ty.dtype, result_dims);
        return self.emit(ty, .{
            .transpose = .{
                .input = operand_value.id,
                .permutation = try self.arena.allocator().dupe(i64, permutation),
            },
        });
    }

    pub fn reduce(
        self: *Builder,
        operand_value: Value,
        init_value: Value,
        reducer: Reducer,
        dimensions: []const i64,
    ) !Value {
        try self.ensureValue(operand_value);
        try self.ensureValue(init_value);
        if (operand_value.ty.dtype != init_value.ty.dtype) return error.DTypeMismatch;
        if (init_value.ty.rank() != 0) return error.ReduceInitNotScalar;
        const result_dims = try type_mod.removeAxes(
            self.arena.allocator(),
            operand_value.ty.dims,
            dimensions,
        );
        const ty = try Type.init(self.arena.allocator(), operand_value.ty.dtype, result_dims);
        return self.emit(ty, .{
            .reduce = .{
                .input = operand_value.id,
                .init = init_value.id,
                .reducer = reducer,
                .dimensions = try self.arena.allocator().dupe(i64, dimensions),
            },
        });
    }

    pub fn reduceNamed(
        self: *Builder,
        operand_value: Value,
        reducer: Reducer,
        names: []const []const u8,
    ) !Value {
        try self.ensureValue(operand_value);
        const indices = try type_mod.axisIndices(
            self.arena.allocator(),
            operand_value.ty.dims,
            names,
        );
        const init_value = try self.reducerInit(operand_value.ty.dtype, reducer);
        return self.reduce(operand_value, init_value, reducer, indices);
    }

    pub fn reduceWith(
        self: *Builder,
        operand_value: Value,
        init_value: Value,
        reducer: Reducer,
        names: []const []const u8,
    ) !Value {
        try self.ensureValue(operand_value);
        const indices = try type_mod.axisIndices(
            self.arena.allocator(),
            operand_value.ty.dims,
            names,
        );
        return self.reduce(operand_value, init_value, reducer, indices);
    }

    pub fn gather(
        self: *Builder,
        operand_value: Value,
        indices_value: Value,
        comptime axis: anytype,
    ) !Value {
        return self.gatherNamed(operand_value, indices_value, comptime nameOf(axis));
    }

    pub fn gatherNamed(
        self: *Builder,
        operand_value: Value,
        indices_value: Value,
        axis_name: []const u8,
    ) !Value {
        try self.ensureValue(operand_value);
        const axis = type_mod.findDim(operand_value.ty.dims, axis_name) orelse
            return error.AxisNotFound;
        return self.gatherOp(operand_value, indices_value, @intCast(axis));
    }

    pub fn gatherOp(self: *Builder, operand_value: Value, indices_value: Value, axis: i64) !Value {
        try self.ensureValue(operand_value);
        try self.ensureValue(indices_value);
        const ty = try type_mod.gather(
            self.arena.allocator(),
            operand_value.ty,
            indices_value.ty,
            axis,
        );
        return self.emit(ty, .{
            .gather = .{
                .input = operand_value.id,
                .indices = indices_value.id,
                .axis = axis,
            },
        });
    }

    pub fn scatterAdd(
        self: *Builder,
        input_value: Value,
        indices_value: Value,
        updates_value: Value,
        comptime axis: anytype,
    ) !Value {
        return self.scatterAddNamed(
            input_value,
            indices_value,
            updates_value,
            comptime nameOf(axis),
        );
    }

    pub fn scatterAddNamed(
        self: *Builder,
        input_value: Value,
        indices_value: Value,
        updates_value: Value,
        axis_name: []const u8,
    ) !Value {
        try self.ensureValue(input_value);
        const axis = type_mod.findDim(input_value.ty.dims, axis_name) orelse
            return error.AxisNotFound;
        return self.scatterAddOp(input_value, indices_value, updates_value, @intCast(axis));
    }

    pub fn scatterAddOp(
        self: *Builder,
        input_value: Value,
        indices_value: Value,
        updates_value: Value,
        axis: i64,
    ) !Value {
        try self.ensureValue(input_value);
        try self.ensureValue(indices_value);
        try self.ensureValue(updates_value);
        const ty = try type_mod.scatterAdd(
            self.arena.allocator(),
            input_value.ty,
            indices_value.ty,
            updates_value.ty,
            axis,
        );
        return self.emit(ty, .{
            .scatter_add = .{
                .input = input_value.id,
                .indices = indices_value.id,
                .updates = updates_value.id,
                .axis = axis,
            },
        });
    }

    pub fn sparseCrossEntropyLoss(
        self: *Builder,
        logits_value: Value,
        targets_value: Value,
        comptime axis: anytype,
    ) !Value {
        return self.sparseCrossEntropyLossNamed(logits_value, targets_value, comptime nameOf(axis));
    }

    pub fn sparseCrossEntropyLossNamed(
        self: *Builder,
        logits_value: Value,
        targets_value: Value,
        axis_name: []const u8,
    ) !Value {
        try self.ensureValue(logits_value);
        const axis = type_mod.findDim(logits_value.ty.dims, axis_name) orelse
            return error.AxisNotFound;
        return self.sparseCrossEntropyOp(logits_value, targets_value, @intCast(axis));
    }

    pub fn sparseCrossEntropyOp(
        self: *Builder,
        logits_value: Value,
        targets_value: Value,
        axis: i64,
    ) !Value {
        try self.ensureValue(logits_value);
        try self.ensureValue(targets_value);
        const ty = try type_mod.sparseCrossEntropy(
            self.arena.allocator(),
            logits_value.ty,
            targets_value.ty,
            axis,
        );
        return self.emit(ty, .{
            .sparse_cross_entropy = .{
                .logits = logits_value.id,
                .targets = targets_value.id,
                .axis = axis,
            },
        });
    }

    pub fn meanNamed(self: *Builder, operand_value: Value, names: []const []const u8) !Value {
        try self.ensureValue(operand_value);
        const indices = try type_mod.axisIndices(
            self.arena.allocator(),
            operand_value.ty.dims,
            names,
        );
        const count = try type_mod.reducedExtentProduct(operand_value.ty.dims, indices);
        const init_value = try self.reducerInit(operand_value.ty.dtype, .sum);
        const summed = try self.reduce(operand_value, init_value, .sum, indices);
        const divisor = try self.fullFloat(
            Type.scalar(operand_value.ty.dtype),
            @floatFromInt(count),
        );
        return self.alignedBinary(.div, summed, divisor);
    }

    fn reducerInit(self: *Builder, dtype: DType, reducer: Reducer) !Value {
        const ty = Type.scalar(dtype);
        return switch (reducer) {
            .sum => self.zeros(ty),
            .max => self.extremum(ty, .lowest),
            .min => self.extremum(ty, .highest),
        };
    }

    fn extremum(self: *Builder, ty: Type, comptime bound: enum { lowest, highest }) !Value {
        return switch (ty.dtype) {
            inline .f16, .f32, .f64 => |tag| blk: {
                const Element = tag.ZigType();
                const value: Element = if (bound == .lowest)
                    -std.math.inf(Element)
                else
                    std.math.inf(Element);
                break :blk self.constantBytes(ty, std.mem.asBytes(&value));
            },
            .bf16 => blk: {
                const Bf16 = DType.bf16.ZigType();
                const value = Bf16.fromF32(if (bound == .lowest)
                    -std.math.inf(f32)
                else
                    std.math.inf(f32));
                break :blk self.constantBytes(ty, std.mem.asBytes(&value));
            },
            inline .i32, .i64 => |tag| blk: {
                const Element = tag.ZigType();
                const value: Element = if (bound == .lowest)
                    std.math.minInt(Element)
                else
                    std.math.maxInt(Element);
                break :blk self.constantBytes(ty, std.mem.asBytes(&value));
            },
            else => error.DTypeMismatch,
        };
    }

    pub fn contract(self: *Builder, lhs: Value, rhs: Value, names: []const []const u8) !Value {
        try self.ensureValue(lhs);
        try self.ensureValue(rhs);
        if (lhs.ty.dtype != rhs.ty.dtype) return error.ContractDTypeMismatch;
        const arena = self.arena.allocator();
        const plan = try type_mod.contraction(arena, lhs.ty.dims, rhs.ty.dims, names);

        const batch_count = plan.lhs_batch.len;
        const contract_count = plan.lhs_contract.len;
        const lhs_free = lhs.ty.dims.len - batch_count - contract_count;

        const lhs_order = try arena.alloc(Dim, lhs.ty.dims.len);
        for (plan.lhs_batch, 0..) |axis, index| {
            lhs_order[index] = lhs.ty.dims[@intCast(axis)];
        }
        fillFreeDims(
            lhs.ty.dims,
            plan.lhs_batch,
            plan.lhs_contract,
            lhs_order[batch_count .. batch_count + lhs_free],
        );
        for (plan.lhs_contract, 0..) |axis, index| {
            lhs_order[batch_count + lhs_free + index] = lhs.ty.dims[@intCast(axis)];
        }

        const rhs_order = try arena.alloc(Dim, rhs.ty.dims.len);
        for (plan.rhs_batch, 0..) |axis, index| {
            rhs_order[index] = rhs.ty.dims[@intCast(axis)];
        }
        for (plan.rhs_contract, 0..) |axis, index| {
            rhs_order[batch_count + index] = rhs.ty.dims[@intCast(axis)];
        }
        fillFreeDims(
            rhs.ty.dims,
            plan.rhs_batch,
            plan.rhs_contract,
            rhs_order[batch_count + contract_count ..],
        );

        const lhs_canonical = try self.alignTo(lhs, lhs_order);
        const rhs_canonical = try self.alignTo(rhs, rhs_order);

        const lhs_batch = try arena.alloc(i64, batch_count);
        const rhs_batch = try arena.alloc(i64, batch_count);
        for (0..batch_count) |index| {
            lhs_batch[index] = @intCast(index);
            rhs_batch[index] = @intCast(index);
        }
        const lhs_contract = try arena.alloc(i64, contract_count);
        const rhs_contract = try arena.alloc(i64, contract_count);
        for (0..contract_count) |index| {
            lhs_contract[index] = @intCast(batch_count + lhs_free + index);
            rhs_contract[index] = @intCast(batch_count + index);
        }

        const ty = try Type.init(arena, lhs.ty.dtype, plan.result);
        return self.emit(ty, .{
            .dot_general = .{
                .lhs = lhs_canonical.id,
                .rhs = rhs_canonical.id,
                .lhs_contract = lhs_contract,
                .rhs_contract = rhs_contract,
                .lhs_batch = lhs_batch,
                .rhs_batch = rhs_batch,
            },
        });
    }

    pub fn dotGeneralOp(
        self: *Builder,
        lhs: Value,
        rhs: Value,
        lhs_contract: []const i64,
        rhs_contract: []const i64,
        lhs_batch: []const i64,
        rhs_batch: []const i64,
    ) !Value {
        try self.ensureValue(lhs);
        try self.ensureValue(rhs);
        if (lhs.ty.dtype != rhs.ty.dtype) return error.ContractDTypeMismatch;
        const arena = self.arena.allocator();
        const result_dims = try type_mod.dotGeneralDims(
            arena,
            lhs.ty.dims,
            rhs.ty.dims,
            lhs_contract,
            rhs_contract,
            lhs_batch,
            rhs_batch,
        );
        const ty = try Type.init(arena, lhs.ty.dtype, result_dims);
        return self.emit(ty, .{
            .dot_general = .{
                .lhs = lhs.id,
                .rhs = rhs.id,
                .lhs_contract = try arena.dupe(i64, lhs_contract),
                .rhs_contract = try arena.dupe(i64, rhs_contract),
                .lhs_batch = try arena.dupe(i64, lhs_batch),
                .rhs_batch = try arena.dupe(i64, rhs_batch),
            },
        });
    }

    pub fn scan(self: *Builder, spec: anytype) !ScanResult(@TypeOf(spec.init)) {
        const init_count = comptime scanValueCount(@TypeOf(spec.init));
        var inits: [init_count]Value = undefined;
        scanValues(spec.init, &inits);

        var scope = try self.scanScope(spec.length, &inits);
        errdefer scope.abort();

        const carry = scanCarry(@TypeOf(spec.init), &scope);
        const next = try callScanBody(spec.body, scope.body(), carry);
        var next_values: [init_count]Value = undefined;
        scanValues(next, &next_values);

        const walked = try scope.finish(&next_values);
        return scanResult(self, @TypeOf(spec.init), walked);
    }

    pub fn scanScope(self: *Builder, length: i64, inits: []const Value) !ScanScope {
        if (length < 0) return error.ScanLengthNegative;
        if (inits.len == 0) return error.ScanWithoutCarries;
        if (inits.len > program_mod.max_scan_carries) return error.ScanArityUnsupported;
        const init_ids = try self.arena.allocator().alloc(Id, inits.len);
        for (inits, init_ids) |value, *slot| {
            try self.ensureValue(value);
            slot.* = value.id;
        }
        var child = try Builder.init(self.allocator, "scan_body");
        errdefer child.deinit();
        for (inits) |value| {
            _ = try child.inputTyped(value.ty);
        }
        return .{
            .parent = self,
            .child = child,
            .length = length,
            .init_ids = init_ids,
        };
    }

    pub fn projection(self: *Builder, source: Value, index: usize) !Value {
        try self.ensureValue(source);
        const source_op = self.operations.items[source.id.index];
        const scan_op = switch (source_op.kind) {
            .scan => |scan_op| scan_op,
            else => return error.ProjectionSourceNotScan,
        };
        if (index == 0 or index >= scan_op.inits.len) return error.ProjectionIndexInvalid;
        const ty = try self.copyType(scan_op.body.typeOf(scan_op.body.outputs[index]));
        return self.emit(ty, .{ .projection = .{ .source = source.id, .index = index } });
    }

    pub fn emitScan(
        self: *Builder,
        length: i64,
        inits: []const Value,
        body: *const program_mod.Subgraph,
    ) !Value {
        const init_ids = try self.arena.allocator().alloc(Id, inits.len);
        for (inits, init_ids) |value, *slot| {
            try self.ensureValue(value);
            slot.* = value.id;
        }
        return self.emitScanIds(length, init_ids, body);
    }

    fn emitScanIds(
        self: *Builder,
        length: i64,
        inits: []const Id,
        body: *const program_mod.Subgraph,
    ) !Value {
        if (length < 0) return error.ScanLengthNegative;
        if (inits.len == 0) return error.ScanWithoutCarries;
        if (inits.len > program_mod.max_scan_carries) return error.ScanArityUnsupported;
        if (body.parameters.len != inits.len) return error.ScanArityMismatch;
        if (body.outputs.len != inits.len) return error.ScanArityMismatch;
        for (inits, 0..) |init_id, index| {
            const init_ty = self.values.items[init_id.index];
            try type_mod.sameType(init_ty, body.typeOf(body.parameters[index]));
            try type_mod.sameType(init_ty, body.typeOf(body.outputs[index]));
        }
        const owned_body = try program_mod.cloneSubgraph(self.arena.allocator(), body);
        const result_ty = try self.copyType(self.values.items[inits[0].index]);
        return self.emit(result_ty, .{ .scan = .{
            .length = length,
            .inits = inits,
            .body = owned_body,
        } });
    }

    pub fn finish(self: *Builder, outputs: []const Value) !Program {
        if (self.finished) return error.BuilderFinished;
        const owned_outputs = try self.arena.allocator().alloc(Id, outputs.len);
        for (outputs, 0..) |output, index| {
            try self.ensureValue(output);
            owned_outputs[index] = output.id;
        }
        self.finished = true;
        return .{
            .arena = self.arena,
            .name = self.name,
            .values = self.values.items,
            .operations = self.operations.items,
            .parameters = self.parameters_list.items,
            .outputs = owned_outputs,
        };
    }

    fn constantOwned(self: *Builder, ty: Type, payload: []const u8) !Value {
        return self.emit(ty, .{ .constant = .{ .payload = payload } });
    }

    fn emit(self: *Builder, ty: Type, kind: program_mod.Kind) !Value {
        const id = try self.append(ty, kind);
        return self.makeValue(id);
    }

    fn append(self: *Builder, result: Type, kind: program_mod.Kind) !Id {
        if (self.finished) return error.BuilderFinished;
        const id = Id{ .index = @intCast(self.values.items.len) };
        try self.values.append(self.arena.allocator(), result);
        try self.operations.append(self.arena.allocator(), .{
            .id = id,
            .result = result,
            .kind = kind,
        });
        return id;
    }

    fn makeValue(self: *Builder, id: Id) Value {
        return .{
            .builder = self,
            .id = id,
            .ty = self.values.items[id.index],
        };
    }

    fn ensureValue(self: *Builder, candidate: Value) !void {
        if (self.finished) return error.BuilderFinished;
        if (candidate.builder != self) return error.CrossBuilderValue;
    }

    fn copyType(self: *Builder, ty: Type) !Type {
        return Type.init(self.arena.allocator(), ty.dtype, ty.dims);
    }
};

fn fillFreeDims(dims: []const Dim, batch: []const i64, contracted: []const i64, out: []Dim) void {
    var index: usize = 0;
    for (dims, 0..) |dim, position| {
        if (containsIndex(batch, position) or containsIndex(contracted, position)) continue;
        out[index] = dim;
        index += 1;
    }
}

fn containsIndex(axes: []const i64, position: usize) bool {
    for (axes) |axis| {
        if (axis == @as(i64, @intCast(position))) return true;
    }
    return false;
}

pub fn nameOf(comptime name_value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(name_value))) {
        .enum_literal => @tagName(name_value),
        .pointer, .array => name_value[0..],
        else => @compileError("tensor axis names must be enum literals or string literals"),
    };
}

fn ScanResult(comptime Init: type) type {
    if (comptime Init == Value) return Value;
    return switch (@typeInfo(Init)) {
        .array => |array| blk: {
            if (array.child != Value) {
                @compileError("tensor scan array init values must be tensor Values");
            }
            break :blk [array.len]Value;
        },
        .@"struct" => |info| blk: {
            if (info.field_names.len == 0) {
                @compileError("tensor scan init struct must contain at least one carry");
            }
            inline for (info.field_types) |field_type| {
                if (field_type != Value) {
                    @compileError("tensor scan struct init fields must be tensor Values");
                }
            }
            break :blk Init;
        },
        else => @compileError("tensor scan init must be a Value, array of Values, tuple of " ++
            "Values, or struct of Values"),
    };
}

fn scanValueCount(comptime Init: type) usize {
    if (comptime Init == Value) return 1;
    return switch (@typeInfo(Init)) {
        .array => |array| blk: {
            if (array.child != Value) {
                @compileError("tensor scan array init values must be tensor Values");
            }
            break :blk array.len;
        },
        .@"struct" => |info| blk: {
            if (info.field_names.len == 0) {
                @compileError("tensor scan init struct must contain at least one carry");
            }
            inline for (info.field_types) |field_type| {
                if (field_type != Value) {
                    @compileError("tensor scan struct init fields must be tensor Values");
                }
            }
            break :blk info.field_names.len;
        },
        else => @compileError("tensor scan init must be a Value, array of Values, tuple of " ++
            "Values, or struct of Values"),
    };
}

fn scanValues(source: anytype, values: *[scanValueCount(@TypeOf(source))]Value) void {
    const Source = @TypeOf(source);
    if (comptime Source == Value) {
        values[0] = source;
        return;
    }
    switch (@typeInfo(Source)) {
        .array => for (source, 0..) |value, index| {
            values[index] = value;
        },
        .@"struct" => |info| inline for (info.field_names, 0..) |field_name, index| {
            values[index] = @field(source, field_name);
        },
        else => unreachable,
    }
}

fn scanCarry(comptime Init: type, scope: *ScanScope) ScanResult(Init) {
    if (comptime Init == Value) return scope.carry(0);
    return switch (@typeInfo(Init)) {
        .array => |array| blk: {
            var result: [array.len]Value = undefined;
            inline for (0..array.len) |index| {
                result[index] = scope.carry(index);
            }
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: Init = undefined;
            inline for (info.field_names, 0..) |field_name, index| {
                @field(result, field_name) = scope.carry(index);
            }
            break :blk result;
        },
        else => unreachable,
    };
}

fn scanResult(builder: *Builder, comptime Init: type, walked: Value) !ScanResult(Init) {
    if (comptime Init == Value) return walked;
    return switch (@typeInfo(Init)) {
        .array => |array| blk: {
            var result: [array.len]Value = undefined;
            inline for (0..array.len) |index| {
                result[index] = if (index == 0) walked else try builder.projection(walked, index);
            }
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: Init = undefined;
            inline for (info.field_names, 0..) |field_name, index| {
                @field(result, field_name) = if (index == 0)
                    walked
                else
                    try builder.projection(walked, index);
            }
            break :blk result;
        },
        else => unreachable,
    };
}

fn callScanBody(
    comptime body: anytype,
    builder: *Builder,
    carry: anytype,
) !ScanResult(@TypeOf(carry)) {
    if (comptime @typeInfo(@TypeOf(body)) != .@"fn") {
        @compileError("tensor scan body must be a function value");
    }
    return body(builder, carry);
}

fn namedScanStep(scan_builder: *Builder, carry: anytype) !@TypeOf(carry) {
    const half = try scan_builder.scalar(.f32, 0.5);
    const next_x = try (try carry.x.mul(carry.x)).mul(half);
    return .{
        .x = next_x,
        .acc = try carry.acc.add(next_x),
    };
}

fn singleScanStep(_: *Builder, carry: Value) !Value {
    return carry.add(carry);
}

fn arrayScanStep(_: *Builder, carry: [2]Value) ![2]Value {
    const next = try carry[0].add(carry[0]);
    return .{ next, try carry[1].add(next) };
}

fn tupleScanStep(_: *Builder, carry: anytype) !@TypeOf(carry) {
    const next = try carry[0].add(carry[0]);
    return .{ next, try carry[1].add(next) };
}
