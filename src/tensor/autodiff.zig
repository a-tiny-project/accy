const std = @import("std");
const emit = @import("emit.zig");
const hook = @import("hook.zig");
const interpret = @import("interpret/root.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const transform = @import("transform.zig");
const unroll = @import("unroll.zig");
const types = @import("type/root.zig");

pub const LinearizeOptions = struct {
    wrt: []const usize,
};

pub const JvpOptions = LinearizeOptions;

pub const Dual = struct {
    primal: trace.Value,
    tangent: trace.Value,
};

const ResultMode = enum {
    linearization,
    downstream,
};

pub const Linearization = struct {
    program: program_mod.Program,
    differentiated_parameters: []const usize,
    primal_parameter_count: usize,
    tangent_parameter_count: usize,
    primal_output_count: usize,
    tangent_output_count: usize,

    pub fn deinit(self: *Linearization) void {
        self.program.deinit();
    }

    pub fn primalOutputs(self: *const Linearization) []const program_mod.Id {
        return self.program.outputs[0..self.primal_output_count];
    }

    pub fn tangentOutputs(self: *const Linearization) []const program_mod.Id {
        return self.program.outputs[self.primal_output_count .. self.primal_output_count + self.tangent_output_count];
    }
};

pub fn semantics(
    source: *const program_mod.Program,
    next: anytype,
    options: LinearizeOptions,
) Semantics(@TypeOf(next), .linearization) {
    return .{
        .source = source,
        .next = next,
        .options = options,
    };
}

pub fn jvpSemantics(
    source: *const program_mod.Program,
    next: anytype,
    options: JvpOptions,
) Semantics(@TypeOf(next), .downstream) {
    return .{
        .source = source,
        .next = next,
        .options = options,
    };
}

pub fn jvpSemanticsWith(
    source: *const program_mod.Program,
    next: anytype,
    options: JvpOptions,
    hooks: anytype,
) @TypeOf(hook.attach("jvp", hooks, jvpSemantics(source, hook.attach("linearize", hooks, next), options))) {
    const generated = hook.attach("linearize", hooks, next);
    const linear = jvpSemantics(source, generated, options);
    return hook.attach("jvp", hooks, linear);
}

pub fn Semantics(comptime Next: type, comptime result_mode: ResultMode) type {
    return struct {
        source: *const program_mod.Program,
        next: Next,
        options: LinearizeOptions,
        parameter_values: ?[]Value = null,

        pub const Value: type = Dual;
        pub const Result: type = if (result_mode == .linearization) Linearization else Next.Result;

        pub fn operation(self: *@This(), step: *interpret.Step(Value)) !Value {
            var buffer: [program_mod.max_operation_operands]Value = undefined;
            return self.bind(step.op, interpret.arguments(Value, step.op, step.values, &buffer));
        }

        pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const Value) !Value {
            return switch (op.kind) {
                .parameter => |parameter_info| self.parameterValue(parameter_info),
                .constant => self.constantValue(op),
                .iota => self.iotaValue(op),
                .unary => |unary_info| self.unaryValue(op, unary_info, args[0]),
                .binary => |binary_info| self.binaryValue(op, binary_info, args[0], args[1]),
                .broadcast => self.broadcastValue(op, args[0]),
                .broadcast_in_dim => |broadcast_info| self.broadcastInDimValue(op, broadcast_info, args[0]),
                .reshape => self.reshapeValue(op, args[0]),
                .transpose => |transpose_info| self.transposeValue(op, transpose_info, args[0]),
                .reduce => |reduce_info| self.reduceValue(op, reduce_info, args[0], args[1]),
                .gather => |gather_info| self.gatherValue(op, gather_info, args[0], args[1]),
                .scatter_add => |scatter_add| self.scatterAddValue(op, scatter_add, args[0], args[1], args[2]),
                .sparse_cross_entropy => |sparse_cross_entropy| self.sparseCrossEntropyValue(op, sparse_cross_entropy, args[0], args[1]),
                .dot_general => |dot_info| self.dotGeneralValue(op, dot_info, args[0], args[1]),
                .compare => self.compareValue(op, args[0], args[1]),
                .select => self.selectValue(op, args[0], args[1], args[2]),
                .custom_call => error.CustomCallRequiresJvpContract,
                .scan, .projection => error.ScanLinearizationUnsupported,
            };
        }

        pub fn finish(self: *@This(), outputs: []const Value) !Result {
            const values = try self.builderHandle().arena.allocator().alloc(trace.Value, outputs.len * 2);
            for (outputs, 0..) |output, index| {
                values[index] = output.primal;
                values[index + outputs.len] = output.tangent;
            }

            if (comptime result_mode == .downstream) return self.next.finish(values);

            var program = try self.next.finish(values);
            errdefer program.deinit();

            const differentiated_parameters = try differentiatedParameters(&program, self.source, self.options);
            const tangent_parameter_count = differentiated_parameters.len;

            return .{
                .program = program,
                .differentiated_parameters = differentiated_parameters,
                .primal_parameter_count = self.source.parameters.len,
                .tangent_parameter_count = tangent_parameter_count,
                .primal_output_count = outputs.len,
                .tangent_output_count = outputs.len,
            };
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.next.builderHandle();
        }

        fn parameterValue(self: *@This(), parameter_info: program_mod.Parameter) !Value {
            if (self.parameter_values == null) try self.prepareParameters();
            return self.parameter_values.?[parameter_info.index];
        }

        fn prepareParameters(self: *@This()) !void {
            const values = try self.builderHandle().arena.allocator().alloc(Value, self.source.parameters.len);
            for (self.source.parameters) |id| {
                const op = &self.source.operations[id.index];
                const parameter_info = op.kind.parameter;
                values[parameter_info.index].primal = try self.next.bind(op, &.{});
            }
            for (self.source.parameters) |id| {
                const op = &self.source.operations[id.index];
                const parameter_info = op.kind.parameter;
                values[parameter_info.index].tangent = if (isWrt(self.options.wrt, parameter_info.index)) tangent: {
                    if (!op.result.dtype.isFloat()) return error.NonDifferentiableParameter;
                    break :tangent try self.builderHandle().inputTyped(op.result);
                } else try self.emitZeros(op.result);
            }
            self.parameter_values = values;
        }

        fn compareValue(self: *@This(), op: *const program_mod.Operation, lhs: Value, rhs: Value) !Value {
            return .{
                .primal = try self.next.bind(op, &.{ lhs.primal, rhs.primal }),
                .tangent = try self.emitZeros(op.result),
            };
        }

        fn selectValue(self: *@This(), op: *const program_mod.Operation, pred: Value, on_true: Value, on_false: Value) !Value {
            return .{
                .primal = try self.next.bind(op, &.{ pred.primal, on_true.primal, on_false.primal }),
                .tangent = try emit.select(self, pred.primal, on_true.tangent, on_false.tangent),
            };
        }

        fn constantValue(self: *@This(), op: *const program_mod.Operation) !Value {
            return .{
                .primal = try self.next.bind(op, &.{}),
                .tangent = try self.emitZeros(op.result),
            };
        }

        fn iotaValue(self: *@This(), op: *const program_mod.Operation) !Value {
            return .{
                .primal = try self.next.bind(op, &.{}),
                .tangent = try self.emitZeros(op.result),
            };
        }

        fn unaryValue(self: *@This(), op: *const program_mod.Operation, unary_info: program_mod.UnaryOp, input: Value) !Value {
            const primal = try self.next.bind(op, &.{input.primal});
            return .{
                .primal = primal,
                .tangent = try unaryJvp(self, unary_info.op, input.primal, primal, input.tangent),
            };
        }

        fn binaryValue(self: *@This(), op: *const program_mod.Operation, binary_info: program_mod.BinaryOp, lhs: Value, rhs: Value) !Value {
            const primal = try self.next.bind(op, &.{ lhs.primal, rhs.primal });
            return .{
                .primal = primal,
                .tangent = try binaryJvp(self, binary_info.op, lhs.primal, rhs.primal, lhs.tangent, rhs.tangent),
            };
        }

        fn broadcastValue(self: *@This(), op: *const program_mod.Operation, input: Value) !Value {
            return .{
                .primal = try self.next.bind(op, &.{input.primal}),
                .tangent = try self.emitBroadcast(input.tangent, op.result.dims),
            };
        }

        fn broadcastInDimValue(self: *@This(), op: *const program_mod.Operation, broadcast_info: program_mod.BroadcastInDim, input: Value) !Value {
            return .{
                .primal = try self.next.bind(op, &.{input.primal}),
                .tangent = try self.emitBroadcastInDim(input.tangent, op.result.dims, broadcast_info.broadcast_dims),
            };
        }

        fn reshapeValue(self: *@This(), op: *const program_mod.Operation, input: Value) !Value {
            return .{
                .primal = try self.next.bind(op, &.{input.primal}),
                .tangent = try self.emitReshape(input.tangent, op.result.dims),
            };
        }

        fn transposeValue(self: *@This(), op: *const program_mod.Operation, transpose_info: program_mod.Transpose, input: Value) !Value {
            return .{
                .primal = try self.next.bind(op, &.{input.primal}),
                .tangent = try self.emitTranspose(input.tangent, transpose_info.permutation),
            };
        }

        fn reduceValue(self: *@This(), op: *const program_mod.Operation, reduce_info: program_mod.Reduce, input: Value, init: Value) !Value {
            const primal = try self.next.bind(op, &.{ input.primal, init.primal });
            const tangent = switch (reduce_info.reducer) {
                .sum => try self.emitReduce(input.tangent, init.tangent, .sum, reduce_info.dimensions),
                .max, .min => blk: {
                    const input_active = !input.tangent.isStructuralZero();
                    const init_active = !init.tangent.isStructuralZero();
                    if (!input_active and !init_active) break :blk try self.emitZeros(primal.ty);

                    var input_term: ?trace.Value = null;
                    if (input_active) {
                        const allocator = self.builderHandle().arena.allocator();
                        const input_dims = input.primal.ty.dims;
                        const kept = try allocator.alloc(i64, input_dims.len - reduce_info.dimensions.len);
                        var kept_index: usize = 0;
                        for (0..input_dims.len) |axis| {
                            var reduced = false;
                            for (reduce_info.dimensions) |dimension| {
                                if (dimension == @as(i64, @intCast(axis))) reduced = true;
                            }
                            if (reduced) continue;
                            kept[kept_index] = @intCast(axis);
                            kept_index += 1;
                        }
                        const expanded = try self.emitBroadcastInDim(primal, input_dims, kept);
                        const mask = try self.emitCompare(.eq, input.primal, expanded);
                        const zeros = try self.emitZeros(input.primal.ty);
                        const masked = try self.emitSelect(mask, input.tangent, zeros);
                        const zero_init = try self.emitZeros(init.tangent.ty);
                        input_term = try self.emitReduce(masked, zero_init, .sum, reduce_info.dimensions);
                    }

                    var init_term: ?trace.Value = null;
                    if (init_active) {
                        const init_primal = try self.emitToShape(init.primal, primal.ty);
                        const init_tangent = try self.emitToShape(init.tangent, primal.ty);
                        const init_mask = try self.emitCompare(.eq, primal, init_primal);
                        const zeros = try self.emitZeros(primal.ty);
                        init_term = try self.emitSelect(init_mask, init_tangent, zeros);
                    }

                    break :blk if (input_term) |input_value|
                        if (init_term) |init_value|
                            try self.emitBinary(.add, input_value, init_value)
                        else
                            input_value
                    else
                        init_term.?;
                },
            };
            return .{
                .primal = primal,
                .tangent = tangent,
            };
        }

        fn gatherValue(self: *@This(), op: *const program_mod.Operation, gather_info: program_mod.Gather, input: Value, indices: Value) !Value {
            return .{
                .primal = try self.next.bind(op, &.{ input.primal, indices.primal }),
                .tangent = try self.emitGather(input.tangent, indices.primal, gather_info.axis),
            };
        }

        fn scatterAddValue(
            self: *@This(),
            op: *const program_mod.Operation,
            scatter_add: program_mod.ScatterAdd,
            input: Value,
            indices: Value,
            updates: Value,
        ) !Value {
            return .{
                .primal = try self.next.bind(op, &.{ input.primal, indices.primal, updates.primal }),
                .tangent = try self.emitScatterAdd(input.tangent, indices.primal, updates.tangent, scatter_add.axis),
            };
        }

        fn sparseCrossEntropyValue(
            self: *@This(),
            op: *const program_mod.Operation,
            sparse_cross_entropy: program_mod.SparseCrossEntropy,
            logits: Value,
            targets: Value,
        ) !Value {
            const primal = try self.next.bind(op, &.{ logits.primal, targets.primal });

            const logits_ty = logits.primal.ty;
            const axis = sparse_cross_entropy.axis;
            const class_axes = [_]i64{axis};
            const scalar_ty = trace.Type.scalar(logits_ty.dtype);

            const max_init = try self.emitFloatLowest(logits_ty.dtype);
            const row_max = try emit.reduce(self, logits.primal, max_init, .max, class_axes[0..]);
            const row_max_full = try self.emitExpandAxis(row_max, logits_ty.dims, axis);
            const shifted = try emit.binary(self, .sub, logits.primal, row_max_full);
            const exponentials = try emit.unary(self, .exp, shifted);
            const sum_init = try self.emitZeros(scalar_ty);
            const denominator = try emit.reduce(self, exponentials, sum_init, .sum, class_axes[0..]);
            const denominator_full = try self.emitExpandAxis(denominator, logits_ty.dims, axis);
            const softmax = try emit.binary(self, .div, exponentials, denominator_full);

            const weighted = try emit.binary(self, .mul, softmax, logits.tangent);
            const weighted_sum = try emit.reduce(self, weighted, sum_init, .sum, class_axes[0..]);

            const positions = try emit.iota(self, .i32, logits_ty.dims, axis);
            const target_positions = try self.emitExpandAxis(targets.primal, logits_ty.dims, axis);
            const mask = try emit.compare(self, .eq, positions, target_positions);
            const tangent_zeros = try self.emitZeros(logits_ty);
            const masked_tangent = try emit.select(self, mask, logits.tangent, tangent_zeros);
            const target_tangent = try emit.reduce(self, masked_tangent, sum_init, .sum, class_axes[0..]);

            return .{
                .primal = primal,
                .tangent = try emit.binary(self, .sub, weighted_sum, target_tangent),
            };
        }

        fn emitExpandAxis(self: *@This(), value: trace.Value, result_dims: []const trace.Dim, axis: i64) !trace.Value {
            const allocator = self.builderHandle().arena.allocator();
            const mapping = try allocator.alloc(i64, value.ty.rank());
            var out: usize = 0;
            for (0..result_dims.len) |position| {
                if (position == @as(usize, @intCast(axis))) continue;
                mapping[out] = @intCast(position);
                out += 1;
            }
            const expanded_dims = try allocator.alloc(trace.Dim, result_dims.len);
            for (result_dims, expanded_dims) |dim, *slot| slot.* = dim;
            return emit.broadcastInDim(self, value, expanded_dims, mapping);
        }

        fn emitFloatLowest(self: *@This(), dtype: trace.DType) !trace.Value {
            const scalar_ty = trace.Type.scalar(dtype);
            return switch (dtype) {
                .f16 => emit.fullFloat(self, scalar_ty, -std.math.floatMax(f16)),
                .bf16, .f32 => emit.fullFloat(self, scalar_ty, -std.math.floatMax(f32)),
                .f64 => emit.fullFloat(self, scalar_ty, -std.math.floatMax(f64)),
                else => error.NonFloatDType,
            };
        }

        fn dotGeneralValue(self: *@This(), op: *const program_mod.Operation, dot: program_mod.DotGeneral, lhs: Value, rhs: Value) !Value {
            const primal = try self.next.bind(op, &.{ lhs.primal, rhs.primal });
            const left = try self.emitDotGeneral(
                lhs.tangent,
                rhs.primal,
                dot.lhs_contract,
                dot.rhs_contract,
                dot.lhs_batch,
                dot.rhs_batch,
            );
            const right = try self.emitDotGeneral(
                lhs.primal,
                rhs.tangent,
                dot.lhs_contract,
                dot.rhs_contract,
                dot.lhs_batch,
                dot.rhs_batch,
            );
            return .{
                .primal = primal,
                .tangent = try self.emitBinary(.add, left, right),
            };
        }

        fn emitZeros(self: *@This(), ty: trace.Type) !trace.Value {
            return emit.zeros(self, ty);
        }

        fn emitToShape(self: *@This(), value: trace.Value, ty: trace.Type) !trace.Value {
            if (value.ty.dtype != ty.dtype) return error.DTypeMismatch;
            if (types.sameDims(value.ty.dims, ty.dims)) return value;
            if (value.ty.rank() == 0) return self.emitBroadcastInDim(value, ty.dims, &.{});
            return error.ShapeMismatch;
        }

        fn emitCompare(self: *@This(), direction: program_mod.CompareDirection, lhs: trace.Value, rhs: trace.Value) !trace.Value {
            return emit.compare(self, direction, lhs, rhs);
        }

        fn emitSelect(self: *@This(), pred: trace.Value, on_true: trace.Value, on_false: trace.Value) !trace.Value {
            return emit.select(self, pred, on_true, on_false);
        }

        fn emitFullFloat(self: *@This(), ty: trace.Type, fill_value: f64) !trace.Value {
            return emit.fullFloat(self, ty, fill_value);
        }

        fn emitUnary(self: *@This(), op_kind: program_mod.Unary, input: trace.Value) !trace.Value {
            return emit.unary(self, op_kind, input);
        }

        fn emitBinary(self: *@This(), op_kind: program_mod.Binary, lhs: trace.Value, rhs: trace.Value) !trace.Value {
            return emit.binary(self, op_kind, lhs, rhs);
        }

        fn emitBroadcast(self: *@This(), input: trace.Value, result_dims: []const trace.Dim) !trace.Value {
            return emit.broadcast(self, input, result_dims);
        }

        fn emitBroadcastInDim(self: *@This(), input: trace.Value, result_dims: []const trace.Dim, broadcast_dims: []const i64) !trace.Value {
            return emit.broadcastInDim(self, input, result_dims, broadcast_dims);
        }

        fn emitReshape(self: *@This(), input: trace.Value, new_dims: []const trace.Dim) !trace.Value {
            return emit.reshape(self, input, new_dims);
        }

        fn emitTranspose(self: *@This(), input: trace.Value, permutation: []const i64) !trace.Value {
            return emit.transpose(self, input, permutation);
        }

        fn emitReduce(self: *@This(), input: trace.Value, init: trace.Value, reducer: program_mod.Reducer, dimensions: []const i64) !trace.Value {
            return emit.reduce(self, input, init, reducer, dimensions);
        }

        fn emitGather(self: *@This(), input: trace.Value, indices: trace.Value, axis: i64) !trace.Value {
            return emit.gather(self, input, indices, axis);
        }

        fn emitScatterAdd(self: *@This(), input: trace.Value, indices: trace.Value, updates: trace.Value, axis: i64) !trace.Value {
            return emit.scatterAdd(self, input, indices, updates, axis);
        }

        fn emitDotGeneral(
            self: *@This(),
            lhs: trace.Value,
            rhs: trace.Value,
            lhs_contract: []const i64,
            rhs_contract: []const i64,
            lhs_batch: []const i64,
            rhs_batch: []const i64,
        ) !trace.Value {
            return emit.dotGeneral(self, lhs, rhs, lhs_contract, rhs_contract, lhs_batch, rhs_batch);
        }
    };
}

pub fn linearize(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: LinearizeOptions,
) !Linearization {
    if (source.containsScan()) {
        var expanded = try unroll.apply(allocator, source);
        defer expanded.deinit();
        return linearize(allocator, &expanded, options);
    }

    try validate(source, options);

    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();

    const graph = interpret.Graph{ .builder = &builder };
    return linearizeInto(allocator, source, options, graph);
}

pub fn linearizeWith(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: LinearizeOptions,
    hooks: anytype,
) !Linearization {
    if (source.containsScan()) {
        var expanded = try unroll.apply(allocator, source);
        defer expanded.deinit();
        return linearizeWith(allocator, &expanded, options, hooks);
    }

    try validate(source, options);

    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();

    const graph = interpret.Graph{ .builder = &builder };
    const generated = hook.attach("linearize", hooks, graph);
    const linear = semantics(source, generated, options);
    return interpret.run(allocator, source, hook.attach("jvp", hooks, linear));
}

fn linearizeInto(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: LinearizeOptions,
    initial: anytype,
) !Linearization {
    return interpret.run(allocator, source, semantics(source, initial, options));
}

pub fn jvp(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: JvpOptions,
) !program_mod.Program {
    const linearized = try linearize(allocator, source, options);
    return linearized.program;
}

pub fn jvpWith(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: JvpOptions,
    hooks: anytype,
) !program_mod.Program {
    const linearized = try linearizeWith(allocator, source, options, hooks);
    return linearized.program;
}

fn unaryJvp(layer: anytype, op: program_mod.Unary, input: trace.Value, primal: trace.Value, tangent: trace.Value) !trace.Value {
    if (!input.ty.dtype.isFloat()) return error.UnsupportedDerivative;
    return switch (op) {
        .neg => layer.emitUnary(.neg, tangent),
        .exp => layer.emitBinary(.mul, primal, tangent),
        .log => layer.emitBinary(.div, tangent, input),
        .sqrt => blk: {
            const two = try layer.emitFullFloat(input.ty, 2.0);
            break :blk layer.emitBinary(.div, tangent, try layer.emitBinary(.mul, two, primal));
        },
        .tanh => blk: {
            const one = try layer.emitFullFloat(input.ty, 1.0);
            const square = try layer.emitBinary(.mul, primal, primal);
            break :blk layer.emitBinary(.mul, tangent, try layer.emitBinary(.sub, one, square));
        },
        .sin => layer.emitBinary(.mul, tangent, try layer.emitUnary(.cos, input)),
        .cos => layer.emitUnary(.neg, try layer.emitBinary(.mul, tangent, try layer.emitUnary(.sin, input))),
        .abs => blk: {
            const zeros = try layer.emitZeros(input.ty);
            const non_negative = try layer.emitCompare(.ge, input, zeros);
            break :blk layer.emitSelect(non_negative, tangent, try layer.emitUnary(.neg, tangent));
        },
        .tan => blk: {
            const cosine = try layer.emitUnary(.cos, input);
            break :blk layer.emitBinary(.div, tangent, try layer.emitBinary(.mul, cosine, cosine));
        },
    };
}

fn binaryJvp(
    layer: anytype,
    op: program_mod.Binary,
    lhs: trace.Value,
    rhs: trace.Value,
    lhs_tangent: trace.Value,
    rhs_tangent: trace.Value,
) !trace.Value {
    if (!lhs.ty.dtype.isFloat()) return error.UnsupportedDerivative;
    return switch (op) {
        .add => layer.emitBinary(.add, lhs_tangent, rhs_tangent),
        .sub => layer.emitBinary(.sub, lhs_tangent, rhs_tangent),
        .mul => layer.emitBinary(.add, try layer.emitBinary(.mul, lhs_tangent, rhs), try layer.emitBinary(.mul, lhs, rhs_tangent)),
        .div => blk: {
            const numerator = try layer.emitBinary(.sub, try layer.emitBinary(.mul, lhs_tangent, rhs), try layer.emitBinary(.mul, lhs, rhs_tangent));
            const denominator = try layer.emitBinary(.mul, rhs, rhs);
            break :blk layer.emitBinary(.div, numerator, denominator);
        },
        .max => blk: {
            const mask = try layer.emitCompare(.ge, lhs, rhs);
            break :blk layer.emitSelect(mask, lhs_tangent, rhs_tangent);
        },
        .min => blk: {
            const mask = try layer.emitCompare(.le, lhs, rhs);
            break :blk layer.emitSelect(mask, lhs_tangent, rhs_tangent);
        },
        .pow => blk: {
            const lhs_active = !lhs_tangent.isStructuralZero();
            const rhs_active = !rhs_tangent.isStructuralZero();
            if (!lhs_active and !rhs_active) break :blk layer.emitZeros(lhs.ty);

            var base_term: ?trace.Value = null;
            if (lhs_active) {
                const one = try layer.emitFullFloat(lhs.ty, 1.0);
                const exponent_minus_one = try layer.emitBinary(.sub, rhs, one);
                const power_step_down = try layer.emitBinary(.pow, lhs, exponent_minus_one);
                base_term = try layer.emitBinary(
                    .mul,
                    try layer.emitBinary(.mul, rhs, power_step_down),
                    lhs_tangent,
                );
            }

            var exponent_term: ?trace.Value = null;
            if (rhs_active) {
                exponent_term = try layer.emitBinary(
                    .mul,
                    try layer.emitBinary(.mul, try layer.emitBinary(.pow, lhs, rhs), try layer.emitUnary(.log, lhs)),
                    rhs_tangent,
                );
            }

            break :blk if (base_term) |base|
                if (exponent_term) |exponent|
                    try layer.emitBinary(.add, base, exponent)
                else
                    base
            else
                exponent_term.?;
        },
    };
}

fn differentiatedParameters(
    program: *program_mod.Program,
    source: *const program_mod.Program,
    options: LinearizeOptions,
) ![]const usize {
    const result = try program.arena.allocator().alloc(usize, differentiatedParameterCount(source, options.wrt));
    var out: usize = 0;
    for (source.parameters) |id| {
        const parameter = source.operation(id).kind.parameter;
        if (isWrt(options.wrt, parameter.index)) {
            result[out] = parameter.index;
            out += 1;
        }
    }
    return result;
}

fn differentiatedParameterCount(source: *const program_mod.Program, wrt: []const usize) usize {
    var count: usize = 0;
    for (source.parameters) |id| {
        const parameter = source.operation(id).kind.parameter;
        if (isWrt(wrt, parameter.index)) count += 1;
    }
    return count;
}

pub fn validate(source: *const program_mod.Program, options: LinearizeOptions) !void {
    for (options.wrt, 0..) |index, offset| {
        if (index >= source.parameters.len) return error.ParameterOutOfRange;
        for (options.wrt[0..offset]) |seen| {
            if (seen == index) return error.DuplicateParameter;
        }
    }
}

fn isWrt(wrt: []const usize, index: usize) bool {
    for (wrt) |item| {
        if (item == index) return true;
    }
    return false;
}

fn jvpBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try (try args[0].mul(args[1])).tanh();
}

fn addZeroBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const zero = try builder.full(.f32, .{ .lane = 4 }, 0.0);
    return try args[0].add(zero);
}

fn powInactiveExponentBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const three = try builder.scalar(.f32, 3.0);
    const exponent = three;
    return try args[0].pow(exponent);
}

fn reduceMaxWithInitBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].reduce(args[1], .max, .lane);
}

fn reduceMinWithInitBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].reduce(args[1], .min, .lane);
}

fn expectExtremaInitTangentMasked(source: *const program_mod.Program) !void {
    var differentiated = try linearize(std.testing.allocator, source, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 4), differentiated.program.parameters.len);
    const init_tangent = differentiated.program.parameters[3];
    var reduce_seeded_by_init_tangent = false;
    var masked_init_tangent = false;
    for (differentiated.program.operations) |op| {
        switch (op.kind) {
            .reduce => |reduce| {
                if (reduce.reducer == .sum and reduce.init.index == init_tangent.index) {
                    reduce_seeded_by_init_tangent = true;
                }
            },
            .select => |select| {
                if (select.on_true.index == init_tangent.index) masked_init_tangent = true;
            },
            else => {},
        }
    }

    try std.testing.expect(!reduce_seeded_by_init_tangent);
    try std.testing.expect(masked_init_tangent);
}

const CountDualBinary = struct {
    count: *usize,

    pub fn bind(self: *@This(), ctx: anytype) !Dual {
        switch (ctx.op.kind) {
            .binary => self.count.* += 1,
            else => {},
        }
        return ctx.default();
    }
};

const TraceBinaryCounts = struct {
    add: usize = 0,
    mul: usize = 0,
};

const TraceBinaryCounter = struct {
    counts: *TraceBinaryCounts,

    pub fn add(self: *@This(), ctx: anytype) !trace.Value {
        self.counts.add += 1;
        return ctx.default();
    }

    pub fn mul(self: *@This(), ctx: anytype) !trace.Value {
        self.counts.mul += 1;
        return ctx.default();
    }
};

test "tensor linearize semantics accepts user layers over dual values" {
    var source = try trace.define(std.testing.allocator, "jvp_layer", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, addZeroBody);
    defer source.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    var count: usize = 0;
    const graph = interpret.Graph{ .builder = &builder };
    const linear = semantics(&source, graph, .{ .wrt = &.{0} });
    var differentiated = try interpret.run(std.testing.allocator, &source, interpret.layer(Dual, linear, CountDualBinary{ .count = &count }));
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 2), differentiated.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.program.outputs.len);
}

test "tensor linearize binds generated tangent arithmetic through downstream semantics" {
    var source = try trace.define(std.testing.allocator, "jvp_generated_arithmetic", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, struct {
        fn body(_: *trace.Builder, args: []const trace.Value) !trace.Value {
            return try args[0].mul(args[1]);
        }
    }.body);
    defer source.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    var counts: TraceBinaryCounts = .{};
    const graph = interpret.Graph{ .builder = &builder };
    const counted = interpret.bind(TraceBinaryCounter{ .counts = &counts }).attach(graph);
    var differentiated = try interpret.run(std.testing.allocator, &source, semantics(&source, counted, .{ .wrt = &.{ 0, 1 } }));
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), counts.add);
    try std.testing.expectEqual(@as(usize, 3), counts.mul);
    try std.testing.expectEqual(@as(usize, 4), differentiated.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.program.outputs.len);
}

const GeneratedAddMetadata = struct {
    seen: *usize,

    pub fn add(self: *@This(), ctx: *transform.Context) !?trace.Value {
        self.seen.* += 1;
        try std.testing.expect(!ctx.isZero(0));
        try std.testing.expect(!ctx.isZero(1));
        try std.testing.expect(ctx.constantPayload(0) == null);
        try std.testing.expect(ctx.constantPayload(1) == null);
        return null;
    }
};

test "tensor linearize generated arithmetic is safe for downstream rewrite metadata queries" {
    var source = try trace.define(std.testing.allocator, "jvp_generated_metadata", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, struct {
        fn body(_: *trace.Builder, args: []const trace.Value) !trace.Value {
            return try args[0].mul(args[1]);
        }
    }.body);
    defer source.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    var seen: usize = 0;
    const graph = interpret.Graph{ .builder = &builder };
    const rewrite = transform.semantics(&source, graph, GeneratedAddMetadata{ .seen = &seen });
    var differentiated = try interpret.run(std.testing.allocator, &source, semantics(&source, rewrite, .{ .wrt = &.{ 0, 1 } }));
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), seen);
    try std.testing.expectEqual(@as(usize, 4), differentiated.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.program.outputs.len);
}

const DropAddZero = struct {
    pub fn add(_: *@This(), ctx: *transform.Context) !?trace.Value {
        if (ctx.isZero(1)) return ctx.arg(0);
        if (ctx.isZero(0)) return ctx.arg(1);
        return null;
    }
};

test "tensor linearize semantics delegates primal binds through rewrite layers" {
    var source = try trace.define(std.testing.allocator, "jvp_rewrite_stack", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, addZeroBody);
    defer source.deinit();

    var plain = try linearize(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer plain.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    const graph = interpret.Graph{ .builder = &builder };
    const rewrite = transform.semantics(&source, graph, DropAddZero{});
    var rewritten = try interpret.run(std.testing.allocator, &source, semantics(&source, rewrite, .{ .wrt = &.{0} }));
    defer rewritten.deinit();

    try std.testing.expect(rewritten.program.operationCount() < plain.program.operationCount());
    try std.testing.expectEqual(@as(u32, 0), rewritten.primalOutputs()[0].index);
    try types.expectExtents(&.{4}, rewritten.program.typeOf(rewritten.tangentOutputs()[0]));
}

test "tensor linearize exposes primal and tangent structure" {
    var source = try trace.define(std.testing.allocator, "jvp", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, jvpBody);
    defer source.deinit();

    var differentiated = try linearize(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.primal_parameter_count);
    try std.testing.expectEqual(@as(usize, 2), differentiated.tangent_parameter_count);
    try std.testing.expectEqual(@as(usize, 1), differentiated.primal_output_count);
    try std.testing.expectEqual(@as(usize, 1), differentiated.tangent_output_count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, differentiated.differentiated_parameters);
    try std.testing.expectEqual(@as(usize, 4), differentiated.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.program.outputs.len);
    try types.expectExtents(&.{4}, differentiated.program.typeOf(differentiated.primalOutputs()[0]));
    try types.expectExtents(&.{4}, differentiated.program.typeOf(differentiated.tangentOutputs()[0]));
}

test "tensor linearize omits inactive pow exponent branch" {
    var source = try trace.define(std.testing.allocator, "jvp_pow_inactive_exponent", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, powInactiveExponentBody);
    defer source.deinit();

    var differentiated = try linearize(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    var logs: usize = 0;
    for (differentiated.program.operations) |op| {
        switch (op.kind) {
            .unary => |unary_op| {
                if (unary_op.op == .log) logs += 1;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 0), logs);
    try types.expectExtents(&.{4}, differentiated.program.typeOf(differentiated.tangentOutputs()[0]));
}

test "tensor linearize masks reduce max init tangents" {
    var source = try trace.define(std.testing.allocator, "jvp_reduce_max_init", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{}),
    }, reduceMaxWithInitBody);
    defer source.deinit();

    try expectExtremaInitTangentMasked(&source);
}

test "tensor linearize masks reduce min init tangents" {
    var source = try trace.define(std.testing.allocator, "jvp_reduce_min_init", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{}),
    }, reduceMinWithInitBody);
    defer source.deinit();

    try expectExtremaInitTangentMasked(&source);
}

test "tensor jvp is a linearize convenience wrapper" {
    var source = try trace.define(std.testing.allocator, "jvp_wrapper", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, jvpBody);
    defer source.deinit();

    var differentiated = try jvp(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 4), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[1]));
}

test "tensor jvpWith routes linearize generated ops through user semantics" {
    var source = try trace.define(std.testing.allocator, "jvp_with_generated_arithmetic", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, struct {
        fn body(_: *trace.Builder, args: []const trace.Value) !trace.Value {
            return try args[0].mul(args[1]);
        }
    }.body);
    defer source.deinit();

    var counts: TraceBinaryCounts = .{};
    var differentiated = try jvpWith(
        std.testing.allocator,
        &source,
        .{ .wrt = &.{ 0, 1 } },
        .{ .linearize = interpret.bind(TraceBinaryCounter{ .counts = &counts }) },
    );
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), counts.add);
    try std.testing.expectEqual(@as(usize, 3), counts.mul);
    try std.testing.expectEqual(@as(usize, 4), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[1]));
}

fn doublingCallBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = builder;
    return args[0].builder.customCall("accy.custom.double", 1, &.{args[0]}, args[0].ty);
}

test "tensor linearize rejects opaque custom calls naming the contract" {
    var source = try trace.define(std.testing.allocator, "jvp_opaque_custom", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doublingCallBody);
    defer source.deinit();

    try std.testing.expectError(
        error.CustomCallRequiresJvpContract,
        linearize(std.testing.allocator, &source, .{ .wrt = &.{0} }),
    );
}

const DoubleJvpRule = struct {
    applied: *usize,

    pub fn bind(self: *@This(), ctx: anytype) !Dual {
        switch (ctx.op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, "accy.custom.double")) {
                    self.applied.* += 1;
                    const builder = ctx.builderHandle();
                    return .{
                        .primal = try builder.customCall(custom.target, custom.version, &.{ctx.args[0].primal}, ctx.op.result),
                        .tangent = try builder.customCall(custom.target, custom.version, &.{ctx.args[0].tangent}, ctx.op.result),
                    };
                }
            },
            else => {},
        }
        return ctx.default();
    }
};

test "tensor linearize accepts custom call jvp contracts through user layers" {
    var source = try trace.define(std.testing.allocator, "jvp_custom_contract", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doublingCallBody);
    defer source.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    var applied: usize = 0;
    const graph = interpret.Graph{ .builder = &builder };
    const linear = semantics(&source, graph, .{ .wrt = &.{0} });
    var differentiated = try interpret.run(
        std.testing.allocator,
        &source,
        interpret.layer(Dual, linear, DoubleJvpRule{ .applied = &applied }),
    );
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(usize, 2), differentiated.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.program.outputs.len);

    var custom_calls: usize = 0;
    for (differentiated.program.operations) |op| {
        switch (op.kind) {
            .custom_call => custom_calls += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), custom_calls);
}

test "tensor jvpWith accepts custom call jvp contracts through public hooks" {
    var source = try trace.define(std.testing.allocator, "jvp_public_custom_contract", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doublingCallBody);
    defer source.deinit();

    var applied: usize = 0;
    var differentiated = try jvpWith(
        std.testing.allocator,
        &source,
        .{ .wrt = &.{0} },
        .{ .jvp = interpret.bind(DoubleJvpRule{ .applied = &applied }) },
    );
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(usize, 2), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);

    var custom_calls: usize = 0;
    for (differentiated.operations) |op| {
        switch (op.kind) {
            .custom_call => custom_calls += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), custom_calls);
}
