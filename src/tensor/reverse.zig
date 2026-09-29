const std = @import("std");
const autodiff = @import("autodiff.zig");
const emit = @import("emit.zig");
const interpret = @import("interpret/root.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const transform = @import("transform.zig");
const types = @import("type/root.zig");

pub const Options = struct {
    keep_primal_outputs: bool = false,
};

pub const Pullback = struct {
    program: program_mod.Program,
    differentiated_parameters: []const usize,
    primal_parameter_count: usize,
    seed_parameter_count: usize,
    primal_output_count: usize,
    cotangent_output_count: usize,

    pub fn deinit(self: *Pullback) void {
        self.program.deinit();
    }
};

pub fn pullback(allocator: std.mem.Allocator, linearized: *const autodiff.Linearization, options: Options) !Pullback {
    var builder = try trace.Builder.init(allocator, linearized.program.name);
    errdefer builder.deinit();

    const graph = interpret.Graph{ .builder = &builder };
    return pullbackWith(allocator, linearized, options, graph);
}

pub const NoVjpRules = struct {};

fn RuleHandle(comptime Storage: type) type {
    const Child = @typeInfo(Storage).pointer.child;
    return switch (@typeInfo(Child)) {
        .pointer => Child,
        else => Storage,
    };
}

fn ruleHandle(storage: anytype) RuleHandle(@TypeOf(storage)) {
    const Child = @typeInfo(@TypeOf(storage)).pointer.child;
    return switch (@typeInfo(Child)) {
        .pointer => storage.*,
        else => storage,
    };
}

pub fn pullbackWith(allocator: std.mem.Allocator, linearized: *const autodiff.Linearization, options: Options, initial: anytype) !Pullback {
    return pullbackWithRules(allocator, linearized, options, initial, NoVjpRules{});
}

pub fn pullbackWithRules(
    allocator: std.mem.Allocator,
    linearized: *const autodiff.Linearization,
    options: Options,
    initial: anytype,
    rules: anytype,
) !Pullback {
    var layer = TransposeLayer(@TypeOf(initial)){ .next = initial };

    const active = try allocator.alloc(bool, linearized.program.valueCount());
    defer allocator.free(active);
    try markActive(linearized, active);

    const needed = try allocator.alloc(bool, linearized.program.valueCount());
    defer allocator.free(needed);
    for (needed) |*slot| slot.* = false;
    try markResiduals(&linearized.program, active, needed);
    for (linearized.program.parameters) |id| {
        const op = linearized.program.operation(id);
        if (op.kind.parameter.index < linearized.primal_parameter_count) needed[id.index] = true;
    }
    if (options.keep_primal_outputs) {
        for (linearized.primalOutputs()) |id| {
            try markResidual(&linearized.program, active, needed, id);
        }
    }

    const residuals = try allocator.alloc(?trace.Value, linearized.program.valueCount());
    defer allocator.free(residuals);
    for (residuals) |*slot| slot.* = null;
    try replayResiduals(allocator, &layer, &linearized.program, active, needed, residuals);

    const cotangents = try allocator.alloc(?trace.Value, linearized.program.valueCount());
    defer allocator.free(cotangents);
    for (cotangents) |*slot| slot.* = null;

    for (linearized.tangentOutputs()) |id| {
        const seed = try layer.builderHandle().inputTyped(linearized.program.typeOf(id));
        try addCotangent(&layer, cotangents, id, seed);
    }

    var mutable_rules = rules;
    try transposeActive(&layer, &linearized.program, active, residuals, cotangents, ruleHandle(&mutable_rules));

    const primal_output_count: usize = if (options.keep_primal_outputs) linearized.primal_output_count else 0;
    const outputs = try allocator.alloc(trace.Value, primal_output_count + linearized.tangent_parameter_count);
    defer allocator.free(outputs);
    var output_index: usize = 0;
    if (options.keep_primal_outputs) {
        for (linearized.primalOutputs()) |id| {
            outputs[output_index] = requireResidual(residuals, id);
            output_index += 1;
        }
    }
    for (linearized.program.parameters) |id| {
        const op = linearized.program.operation(id);
        const parameter = op.kind.parameter;
        if (parameter.index < linearized.primal_parameter_count) continue;
        outputs[output_index] = cotangents[id.index] orelse try emit.zeros(&layer, op.result);
        output_index += 1;
    }

    const differentiated_parameters = try layer.builderHandle().arena.allocator().dupe(usize, linearized.differentiated_parameters);

    return .{
        .program = try layer.next.finish(outputs),
        .differentiated_parameters = differentiated_parameters,
        .primal_parameter_count = linearized.primal_parameter_count,
        .seed_parameter_count = linearized.tangent_output_count,
        .primal_output_count = primal_output_count,
        .cotangent_output_count = linearized.tangent_parameter_count,
    };
}

fn TransposeLayer(comptime Next: type) type {
    return struct {
        next: Next,

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.next.builderHandle();
        }
    };
}

fn markActive(linearized: *const autodiff.Linearization, active: []bool) !void {
    for (linearized.program.operations) |op| {
        active[op.id.index] = switch (op.kind) {
            .parameter => |parameter| parameter.index >= linearized.primal_parameter_count,
            .constant, .iota => false,
            .unary => |unary| active[unary.input.index],
            .binary => |binary| active[binary.lhs.index] or active[binary.rhs.index],
            .broadcast => |broadcast| active[broadcast.input.index],
            .broadcast_in_dim => |broadcast| active[broadcast.input.index],
            .reshape => |reshape| active[reshape.input.index],
            .transpose => |transpose| active[transpose.input.index],
            .compare => false,
            .select => |select| active[select.on_true.index] or active[select.on_false.index],
            .custom_call => |custom| blk: {
                var any = false;
                for (custom.operands) |operand| {
                    if (active[operand.index]) any = true;
                }
                break :blk any;
            },
            .reduce => |reduce| active[reduce.input.index] or active[reduce.init.index],
            .gather => |gather| active[gather.input.index],
            .scatter_add => |scatter_add| active[scatter_add.input.index] or active[scatter_add.updates.index],
            .sparse_cross_entropy => |sparse_cross_entropy| active[sparse_cross_entropy.logits.index],
            .dot_general => |dot| active[dot.lhs.index] or active[dot.rhs.index],
            .scan => |scan| blk: {
                var any = false;
                for (scan.inits) |init_id| {
                    if (active[init_id.index]) any = true;
                }
                break :blk any;
            },
            .projection => |projection| active[projection.source.index],
        };
    }
}

fn replayResiduals(
    allocator: std.mem.Allocator,
    layer: anytype,
    program: *const program_mod.Program,
    active: []const bool,
    needed: []const bool,
    residuals: []?trace.Value,
) !void {
    try interpret.run(allocator, program, ResidualReplay(@TypeOf(layer)){
        .layer = layer,
        .active = active,
        .needed = needed,
        .residuals = residuals,
    });
}

fn ResidualReplay(comptime Layer: type) type {
    return struct {
        layer: Layer,
        active: []const bool,
        needed: []const bool,
        residuals: []?trace.Value,

        pub const Value = ?trace.Value;
        pub const Result = void;

        pub fn operation(self: *@This(), step: *interpret.Step(Value)) !Value {
            var buffer: [program_mod.max_operation_operands]Value = undefined;
            return self.bind(step.op, interpret.arguments(Value, step.op, step.values, &buffer));
        }

        pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const Value) !Value {
            if (self.active[op.id.index] or !self.needed[op.id.index]) return null;

            var buffer: [program_mod.max_operation_operands]trace.Value = undefined;
            const value = try self.layer.next.bind(op, requireArgs(args, &buffer));
            self.residuals[op.id.index] = value;
            return value;
        }

        pub fn finish(_: *@This(), outputs: []const Value) !Result {
            _ = outputs;
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.layer.builderHandle();
        }
    };
}

fn requireArgs(args: []const ?trace.Value, buffer: *[program_mod.max_operation_operands]trace.Value) []const trace.Value {
    for (args, 0..) |arg, index| {
        buffer[index] = arg orelse unreachable;
    }
    return buffer[0..args.len];
}

fn markResiduals(program: *const program_mod.Program, active: []const bool, needed: []bool) !void {
    for (program.operations) |op| {
        if (!active[op.id.index]) continue;
        switch (op.kind) {
            .parameter, .constant, .iota => {},
            .unary => {},
            .binary => |binary| try markBinaryResiduals(program, active, needed, binary),
            .dot_general => |dot| try markDotResiduals(program, active, needed, dot),
            .compare => {},
            .select => |select| try markResidual(program, active, needed, select.pred),
            .gather => |gather| {
                if (active[gather.input.index]) try markResidual(program, active, needed, gather.indices);
            },
            .scatter_add => |scatter_add| {
                if (active[scatter_add.updates.index]) try markResidual(program, active, needed, scatter_add.indices);
            },
            .sparse_cross_entropy => return error.SparseCrossEntropyTransposeUnsupported,
            .custom_call => |custom| try markCustomCallResiduals(program, active, needed, custom),
            .broadcast, .broadcast_in_dim, .reshape, .transpose, .reduce => {},
            .scan, .projection => return error.ScanTransposeUnsupported,
        }
    }
}

fn markBinaryResiduals(
    program: *const program_mod.Program,
    active: []const bool,
    needed: []bool,
    binary: program_mod.BinaryOp,
) !void {
    const lhs_active = active[binary.lhs.index];
    const rhs_active = active[binary.rhs.index];
    switch (binary.op) {
        .mul => {
            if (lhs_active and !rhs_active) try markResidual(program, active, needed, binary.rhs);
            if (rhs_active and !lhs_active) try markResidual(program, active, needed, binary.lhs);
        },
        .div => {
            if (lhs_active and !rhs_active) try markResidual(program, active, needed, binary.rhs);
        },
        .add, .sub, .max, .min, .pow => {},
    }
}

fn markDotResiduals(
    program: *const program_mod.Program,
    active: []const bool,
    needed: []bool,
    dot: program_mod.DotGeneral,
) !void {
    const lhs_active = active[dot.lhs.index];
    const rhs_active = active[dot.rhs.index];
    if (lhs_active and !rhs_active) try markResidual(program, active, needed, dot.rhs);
    if (rhs_active and !lhs_active) try markResidual(program, active, needed, dot.lhs);
}

fn markCustomCallResiduals(
    program: *const program_mod.Program,
    active: []const bool,
    needed: []bool,
    custom: program_mod.CustomCall,
) !void {
    for (custom.operands) |operand| {
        if (!active[operand.index]) try markResidual(program, active, needed, operand);
    }
}

fn markResidual(
    program: *const program_mod.Program,
    active: []const bool,
    needed: []bool,
    id: program_mod.Id,
) !void {
    if (active[id.index]) return error.NonlinearTranspose;
    if (needed[id.index]) return;
    needed[id.index] = true;
    const op = program.operation(id);
    switch (op.kind) {
        .parameter, .constant, .iota => {},
        .unary => |unary| try markResidual(program, active, needed, unary.input),
        .binary => |binary| {
            try markResidual(program, active, needed, binary.lhs);
            try markResidual(program, active, needed, binary.rhs);
        },
        .broadcast => |broadcast| try markResidual(program, active, needed, broadcast.input),
        .broadcast_in_dim => |broadcast| try markResidual(program, active, needed, broadcast.input),
        .reshape => |reshape| try markResidual(program, active, needed, reshape.input),
        .transpose => |transpose| try markResidual(program, active, needed, transpose.input),
        .compare => |compare| {
            try markResidual(program, active, needed, compare.lhs);
            try markResidual(program, active, needed, compare.rhs);
        },
        .select => |select| {
            try markResidual(program, active, needed, select.pred);
            try markResidual(program, active, needed, select.on_true);
            try markResidual(program, active, needed, select.on_false);
        },
        .custom_call => |custom| {
            for (custom.operands) |operand| try markResidual(program, active, needed, operand);
        },
        .reduce => |reduce| {
            try markResidual(program, active, needed, reduce.input);
            try markResidual(program, active, needed, reduce.init);
        },
        .gather => |gather| {
            try markResidual(program, active, needed, gather.input);
            try markResidual(program, active, needed, gather.indices);
        },
        .scatter_add => |scatter_add| {
            try markResidual(program, active, needed, scatter_add.input);
            try markResidual(program, active, needed, scatter_add.indices);
            try markResidual(program, active, needed, scatter_add.updates);
        },
        .sparse_cross_entropy => |sparse_cross_entropy| {
            try markResidual(program, active, needed, sparse_cross_entropy.logits);
            try markResidual(program, active, needed, sparse_cross_entropy.targets);
        },
        .dot_general => |dot| {
            try markResidual(program, active, needed, dot.lhs);
            try markResidual(program, active, needed, dot.rhs);
        },
        .scan => |scan| {
            for (scan.inits) |init_id| try markResidual(program, active, needed, init_id);
        },
        .projection => |projection| try markResidual(program, active, needed, projection.source),
    }
}

fn transposeActive(
    layer: anytype,
    program: *const program_mod.Program,
    active: []const bool,
    residuals: []const ?trace.Value,
    cotangents: []?trace.Value,
    rules: anytype,
) !void {
    var index = program.operations.len;
    while (index > 0) {
        index -= 1;
        const op = &program.operations[index];
        const cotangent = cotangents[op.id.index] orelse continue;
        if (!active[op.id.index]) continue;

        switch (op.kind) {
            .parameter, .constant, .iota => {},
            .unary => |unary| try transposeUnary(layer, unary, cotangent, cotangents),
            .binary => |binary| try transposeBinary(layer, binary, cotangent, active, residuals, cotangents),
            .broadcast => |broadcast| try transposeBroadcast(layer, program, op, broadcast, cotangent, active, cotangents),
            .broadcast_in_dim => |broadcast| try transposeBroadcastInDim(layer, program, op, broadcast, cotangent, active, cotangents),
            .reshape => |reshape| try transposeReshape(layer, program, reshape, cotangent, active, cotangents),
            .transpose => |transpose| try transposeTranspose(layer, program, transpose, cotangent, active, cotangents),
            .reduce => |reduce| try transposeReduce(layer, program, reduce, cotangent, active, cotangents),
            .gather => |gather| try transposeGather(layer, program, gather, cotangent, active, residuals, cotangents),
            .scatter_add => |scatter_add| try transposeScatterAdd(layer, scatter_add, cotangent, active, residuals, cotangents),
            .sparse_cross_entropy => return error.SparseCrossEntropyTransposeUnsupported,
            .dot_general => |dot| try transposeDot(layer, program, dot, cotangent, active, residuals, cotangents),
            .compare => {},
            .select => |select| try transposeSelect(layer, select, cotangent, active, residuals, cotangents),
            .custom_call => |custom| {
                const Rule = @typeInfo(@TypeOf(rules)).pointer.child;
                if (comptime @hasDecl(Rule, "customCall")) {
                    var rule_ctx = CustomVjpContext(@TypeOf(layer)){
                        .layer = layer,
                        .custom = custom,
                        .cotangent = cotangent,
                        .active = active,
                        .residuals = residuals,
                        .cotangents = cotangents,
                    };
                    try rules.customCall(&rule_ctx);
                } else {
                    return error.CustomCallRequiresVjpContract;
                }
            },
            .scan, .projection => return error.ScanTransposeUnsupported,
        }
    }
}

pub fn CustomVjpContext(comptime Layer: type) type {
    return struct {
        layer: Layer,
        custom: program_mod.CustomCall,
        cotangent: trace.Value,
        active: []const bool,
        residuals: []const ?trace.Value,
        cotangents: []?trace.Value,

        pub fn operandCount(self: *const @This()) usize {
            return self.custom.operands.len;
        }

        pub fn operandIsActive(self: *const @This(), index: usize) bool {
            return self.active[self.custom.operands[index].index];
        }

        pub fn operandResidual(self: *const @This(), index: usize) trace.Value {
            return requireResidual(self.residuals, self.custom.operands[index]);
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.layer.builderHandle();
        }

        pub fn contribute(self: *@This(), index: usize, value: trace.Value) !void {
            try addCotangent(self.layer, self.cotangents, self.custom.operands[index], value);
        }
    };
}

fn transposeUnary(
    layer: anytype,
    unary: program_mod.UnaryOp,
    cotangent: trace.Value,
    cotangents: []?trace.Value,
) !void {
    const contribution = switch (unary.op) {
        .neg => try emit.unary(layer, .neg, cotangent),
        else => return error.UnsupportedTranspose,
    };
    try addCotangent(layer, cotangents, unary.input, contribution);
}

fn transposeBinary(
    layer: anytype,
    binary: program_mod.BinaryOp,
    cotangent: trace.Value,
    active: []const bool,
    residuals: []const ?trace.Value,
    cotangents: []?trace.Value,
) !void {
    const lhs_active = active[binary.lhs.index];
    const rhs_active = active[binary.rhs.index];

    switch (binary.op) {
        .add => {
            if (lhs_active) try addCotangent(layer, cotangents, binary.lhs, cotangent);
            if (rhs_active) try addCotangent(layer, cotangents, binary.rhs, cotangent);
        },
        .sub => {
            if (lhs_active) try addCotangent(layer, cotangents, binary.lhs, cotangent);
            if (rhs_active) try addCotangent(layer, cotangents, binary.rhs, try emit.unary(layer, .neg, cotangent));
        },
        .mul => {
            if (lhs_active and rhs_active) return error.NonlinearTranspose;
            if (lhs_active) try addCotangent(
                layer,
                cotangents,
                binary.lhs,
                try emit.binary(layer, .mul, cotangent, requireResidual(residuals, binary.rhs)),
            );
            if (rhs_active) try addCotangent(
                layer,
                cotangents,
                binary.rhs,
                try emit.binary(layer, .mul, requireResidual(residuals, binary.lhs), cotangent),
            );
        },
        .div => {
            if (rhs_active) return error.UnsupportedTranspose;
            if (lhs_active) try addCotangent(
                layer,
                cotangents,
                binary.lhs,
                try emit.binary(layer, .div, cotangent, requireResidual(residuals, binary.rhs)),
            );
        },
        .max, .min, .pow => return error.UnsupportedTranspose,
    }
}

fn transposeSelect(
    layer: anytype,
    select: program_mod.Select,
    cotangent: trace.Value,
    active: []const bool,
    residuals: []const ?trace.Value,
    cotangents: []?trace.Value,
) !void {
    if (active[select.pred.index]) return error.UnsupportedTranspose;
    const pred = requireResidual(residuals, select.pred);
    const zeros = try emit.zeros(layer, cotangent.ty);
    if (active[select.on_true.index]) {
        try addCotangent(layer, cotangents, select.on_true, try emit.select(layer, pred, cotangent, zeros));
    }
    if (active[select.on_false.index]) {
        try addCotangent(layer, cotangents, select.on_false, try emit.select(layer, pred, zeros, cotangent));
    }
}

fn transposeBroadcast(
    layer: anytype,
    program: *const program_mod.Program,
    op: *const program_mod.Operation,
    broadcast: program_mod.Broadcast,
    cotangent: trace.Value,
    active: []const bool,
    cotangents: []?trace.Value,
) !void {
    if (!active[broadcast.input.index]) return;
    const input_ty = program.typeOf(broadcast.input);
    if (input_ty.rank() != 0) return error.UnsupportedTranspose;
    const axes = try allAxes(layer.builderHandle().arena.allocator(), op.result.rank());
    const reduced = try reduceSum(layer, cotangent, axes);
    try addCotangent(layer, cotangents, broadcast.input, reduced);
}

fn transposeBroadcastInDim(
    layer: anytype,
    program: *const program_mod.Program,
    op: *const program_mod.Operation,
    broadcast: program_mod.BroadcastInDim,
    cotangent: trace.Value,
    active: []const bool,
    cotangents: []?trace.Value,
) !void {
    if (!active[broadcast.input.index]) return;
    const input_ty = program.typeOf(broadcast.input);
    const axes = try broadcastReductionAxes(
        layer.builderHandle().arena.allocator(),
        input_ty.dims,
        op.result.dims,
        broadcast.broadcast_dims,
    );
    var contribution = cotangent;
    if (axes.len != 0) contribution = try reduceSum(layer, contribution, axes);
    if (!types.sameDims(contribution.ty.dims, input_ty.dims)) {
        contribution = try emit.reshape(layer, contribution, input_ty.dims);
    }
    try addCotangent(layer, cotangents, broadcast.input, contribution);
}

fn transposeReshape(
    layer: anytype,
    program: *const program_mod.Program,
    reshape: program_mod.Reshape,
    cotangent: trace.Value,
    active: []const bool,
    cotangents: []?trace.Value,
) !void {
    if (!active[reshape.input.index]) return;
    const input_ty = program.typeOf(reshape.input);
    try addCotangent(layer, cotangents, reshape.input, try emit.reshape(layer, cotangent, input_ty.dims));
}

fn transposeTranspose(
    layer: anytype,
    program: *const program_mod.Program,
    transpose: program_mod.Transpose,
    cotangent: trace.Value,
    active: []const bool,
    cotangents: []?trace.Value,
) !void {
    if (!active[transpose.input.index]) return;
    const inverse = try inversePermutation(layer.builderHandle().arena.allocator(), transpose.permutation);
    _ = program;
    try addCotangent(layer, cotangents, transpose.input, try emit.transpose(layer, cotangent, inverse));
}

fn transposeReduce(
    layer: anytype,
    program: *const program_mod.Program,
    reduce: program_mod.Reduce,
    cotangent: trace.Value,
    active: []const bool,
    cotangents: []?trace.Value,
) !void {
    if (reduce.reducer != .sum) return error.UnsupportedTranspose;
    if (active[reduce.init.index]) return error.UnsupportedTranspose;
    if (!active[reduce.input.index]) return;
    const input_ty = program.typeOf(reduce.input);
    const dims = try keptAxes(layer.builderHandle().arena.allocator(), input_ty.rank(), reduce.dimensions);
    const contribution = try emit.broadcastInDim(layer, cotangent, input_ty.dims, dims);
    try addCotangent(layer, cotangents, reduce.input, contribution);
}

fn transposeGather(
    layer: anytype,
    program: *const program_mod.Program,
    gather: program_mod.Gather,
    cotangent: trace.Value,
    active: []const bool,
    residuals: []const ?trace.Value,
    cotangents: []?trace.Value,
) !void {
    if (!active[gather.input.index]) return;
    if (active[gather.indices.index]) return error.UnsupportedTranspose;
    const input_ty = program.typeOf(gather.input);
    const zeros = try emit.zeros(layer, input_ty);
    const contribution = try emit.scatterAdd(layer, zeros, requireResidual(residuals, gather.indices), cotangent, gather.axis);
    try addCotangent(layer, cotangents, gather.input, contribution);
}

fn transposeScatterAdd(
    layer: anytype,
    scatter_add: program_mod.ScatterAdd,
    cotangent: trace.Value,
    active: []const bool,
    residuals: []const ?trace.Value,
    cotangents: []?trace.Value,
) !void {
    if (active[scatter_add.indices.index]) return error.UnsupportedTranspose;
    if (active[scatter_add.input.index]) {
        try addCotangent(layer, cotangents, scatter_add.input, cotangent);
    }
    if (active[scatter_add.updates.index]) {
        const contribution = try emit.gather(layer, cotangent, requireResidual(residuals, scatter_add.indices), scatter_add.axis);
        try addCotangent(layer, cotangents, scatter_add.updates, contribution);
    }
}

fn transposeDot(
    layer: anytype,
    program: *const program_mod.Program,
    dot: program_mod.DotGeneral,
    cotangent: trace.Value,
    active: []const bool,
    residuals: []const ?trace.Value,
    cotangents: []?trace.Value,
) !void {
    const lhs_active = active[dot.lhs.index];
    const rhs_active = active[dot.rhs.index];
    if (lhs_active and rhs_active) return error.NonlinearTranspose;

    const allocator = layer.builderHandle().arena.allocator();
    const lhs_ty = program.typeOf(dot.lhs);
    const rhs_ty = program.typeOf(dot.rhs);
    const batch_count = dot.lhs_batch.len;
    const lhs_free = try freeAxes(allocator, lhs_ty.rank(), dot.lhs_batch, dot.lhs_contract);
    const rhs_free = try freeAxes(allocator, rhs_ty.rank(), dot.rhs_batch, dot.rhs_contract);
    const cotangent_batch = try axisRange(allocator, 0, batch_count);
    const cotangent_rows = try axisRange(allocator, batch_count, lhs_free.len);
    const cotangent_columns = try axisRange(allocator, batch_count + lhs_free.len, rhs_free.len);

    if (lhs_active) {
        const rhs = requireResidual(residuals, dot.rhs);
        const flat_cotangent = try collapseBlocks(layer, cotangent, cotangent_batch, cotangent_rows, cotangent_columns);
        const flat_rhs = try collapseBlocks(layer, rhs, dot.rhs_batch, rhs_free, dot.rhs_contract);
        const flat = try canonicalDot(layer, flat_cotangent, flat_rhs, batch_count > 0);
        const restored = try expandBlocks(layer, flat, lhs_ty.dims, dot.lhs_batch, lhs_free, dot.lhs_contract);
        try addCotangent(layer, cotangents, dot.lhs, restored);
    }

    if (rhs_active) {
        const lhs = requireResidual(residuals, dot.lhs);
        const flat_lhs = try collapseBlocks(layer, lhs, dot.lhs_batch, dot.lhs_contract, lhs_free);
        const flat_cotangent = try collapseBlocks(layer, cotangent, cotangent_batch, cotangent_rows, cotangent_columns);
        const flat = try canonicalDot(layer, flat_lhs, flat_cotangent, batch_count > 0);
        const restored = try expandBlocks(layer, flat, rhs_ty.dims, dot.rhs_batch, dot.rhs_contract, rhs_free);
        try addCotangent(layer, cotangents, dot.rhs, restored);
    }
}

fn collapseBlocks(
    layer: anytype,
    value: trace.Value,
    batch: []const i64,
    rows: []const i64,
    columns: []const i64,
) !trace.Value {
    const allocator = layer.builderHandle().arena.allocator();
    const rank = value.ty.rank();
    const permutation = try allocator.alloc(i64, rank);
    var out: usize = 0;
    for ([_][]const i64{ batch, rows, columns }) |block| {
        for (block) |axis| {
            permutation[out] = axis;
            out += 1;
        }
    }
    const ordered = try restoreAxisOrder(layer, value, permutation);

    const collapsed_rank: usize = if (batch.len > 0) 3 else 2;
    const collapsed = try allocator.alloc(types.Dim, collapsed_rank);
    var dim_index: usize = 0;
    if (batch.len > 0) {
        collapsed[dim_index] = blockDim(ordered.ty.dims[0..batch.len], "flatbatch");
        dim_index += 1;
    }
    collapsed[dim_index] = blockDim(ordered.ty.dims[batch.len .. batch.len + rows.len], "flatrows");
    dim_index += 1;
    collapsed[dim_index] = blockDim(ordered.ty.dims[batch.len + rows.len ..], "flatcolumns");

    if (collapsed_rank == rank) {
        var unchanged = true;
        for (collapsed, ordered.ty.dims) |target, source| {
            if (target.extent != source.extent) unchanged = false;
        }
        if (unchanged) return ordered;
    }
    return emit.reshape(layer, ordered, collapsed);
}

fn blockDim(dims: []const types.Dim, fallback: []const u8) types.Dim {
    if (dims.len == 1) return dims[0];
    var extent: i64 = 1;
    for (dims) |dim| {
        extent *= dim.extent;
    }
    return .{ .name = fallback, .extent = extent };
}

fn canonicalDot(layer: anytype, lhs: trace.Value, rhs: trace.Value, batched: bool) !trace.Value {
    if (batched) {
        return emit.dotGeneral(layer, lhs, rhs, &.{2}, &.{1}, &.{0}, &.{0});
    }
    return emit.dotGeneral(layer, lhs, rhs, &.{1}, &.{0}, &.{}, &.{});
}

fn expandBlocks(
    layer: anytype,
    flat: trace.Value,
    target_dims: []const types.Dim,
    batch: []const i64,
    rows: []const i64,
    columns: []const i64,
) !trace.Value {
    const allocator = layer.builderHandle().arena.allocator();
    const rank = target_dims.len;
    const expanded = try allocator.alloc(types.Dim, rank);
    const permutation = try allocator.alloc(i64, rank);
    var out: usize = 0;
    for ([_][]const i64{ batch, rows, columns }) |block| {
        for (block) |axis| {
            expanded[out] = target_dims[@intCast(axis)];
            permutation[@intCast(axis)] = @intCast(out);
            out += 1;
        }
    }
    var reshaped = flat;
    if (rank != flat.ty.rank()) {
        reshaped = try emit.reshape(layer, flat, expanded);
    } else {
        var unchanged = true;
        for (expanded, flat.ty.dims) |target, source| {
            if (target.extent != source.extent) unchanged = false;
        }
        if (!unchanged) reshaped = try emit.reshape(layer, flat, expanded);
    }
    return restoreAxisOrder(layer, reshaped, permutation);
}

fn restoreAxisOrder(layer: anytype, value: trace.Value, permutation: []const i64) !trace.Value {
    for (permutation, 0..) |axis, index| {
        if (axis != @as(i64, @intCast(index))) return emit.transpose(layer, value, permutation);
    }
    return value;
}

fn freeAxes(allocator: std.mem.Allocator, rank: usize, batch: []const i64, contract: []const i64) ![]const i64 {
    const result = try allocator.alloc(i64, rank - batch.len - contract.len);
    var out: usize = 0;
    for (0..rank) |axis| {
        if (containsAxis(batch, axis) or containsAxis(contract, axis)) continue;
        result[out] = @intCast(axis);
        out += 1;
    }
    return result;
}

fn axisRange(allocator: std.mem.Allocator, start: usize, count: usize) ![]const i64 {
    const result = try allocator.alloc(i64, count);
    for (result, 0..) |*axis, index| {
        axis.* = @intCast(start + index);
    }
    return result;
}

fn addCotangent(
    layer: anytype,
    cotangents: []?trace.Value,
    id: program_mod.Id,
    contribution: trace.Value,
) !void {
    if (cotangents[id.index]) |existing| {
        cotangents[id.index] = try emit.binary(layer, .add, existing, contribution);
    } else {
        cotangents[id.index] = contribution;
    }
}

fn requireResidual(residuals: []const ?trace.Value, id: program_mod.Id) trace.Value {
    return residuals[id.index] orelse unreachable;
}

fn reduceSum(layer: anytype, value: trace.Value, axes: []const i64) !trace.Value {
    const init = try emit.fullFloat(layer, .{ .dtype = value.ty.dtype, .dims = &.{} }, 0.0);
    return emit.reduce(layer, value, init, .sum, axes);
}

fn allAxes(allocator: std.mem.Allocator, rank: usize) ![]const i64 {
    const result = try allocator.alloc(i64, rank);
    for (result, 0..) |*axis, index| {
        axis.* = @intCast(index);
    }
    return result;
}

fn keptAxes(allocator: std.mem.Allocator, rank: usize, removed: []const i64) ![]const i64 {
    const result = try allocator.alloc(i64, rank - removed.len);
    var out: usize = 0;
    for (0..rank) |axis| {
        if (!containsAxis(removed, axis)) {
            result[out] = @intCast(axis);
            out += 1;
        }
    }
    return result;
}

fn broadcastReductionAxes(
    allocator: std.mem.Allocator,
    input_dims: []const types.Dim,
    result_dims: []const types.Dim,
    broadcast_dims: []const i64,
) ![]const i64 {
    var count: usize = 0;
    for (0..result_dims.len) |axis| {
        if (broadcastInputAxis(broadcast_dims, axis)) |input_axis| {
            if (input_dims[input_axis].extent == 1 and result_dims[axis].extent != 1) count += 1;
        } else {
            count += 1;
        }
    }
    const result = try allocator.alloc(i64, count);
    var out: usize = 0;
    for (0..result_dims.len) |axis| {
        if (broadcastInputAxis(broadcast_dims, axis)) |input_axis| {
            if (input_dims[input_axis].extent == 1 and result_dims[axis].extent != 1) {
                result[out] = @intCast(axis);
                out += 1;
            }
        } else {
            result[out] = @intCast(axis);
            out += 1;
        }
    }
    return result;
}

fn broadcastInputAxis(broadcast_dims: []const i64, result_axis: usize) ?usize {
    for (broadcast_dims, 0..) |axis, input_axis| {
        if (axis == result_axis) return input_axis;
    }
    return null;
}

fn containsAxis(axes: []const i64, candidate: usize) bool {
    for (axes) |axis| {
        if (axis == candidate) return true;
    }
    return false;
}

fn inversePermutation(allocator: std.mem.Allocator, permutation: []const i64) ![]const i64 {
    const result = try allocator.alloc(i64, permutation.len);
    for (permutation, 0..) |axis, index| {
        result[@intCast(axis)] = @intCast(index);
    }
    return result;
}

fn pullbackBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try (try args[0].mul(args[1])).tanh();
}

test "tensor pullback transposes a linearized elementwise program" {
    var source = try trace.define(std.testing.allocator, "pullback", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, pullbackBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer linearized.deinit();

    var transposed = try pullback(std.testing.allocator, &linearized, .{});
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 3), transposed.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), transposed.program.outputs.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, transposed.differentiated_parameters);
    try types.expectExtents(&.{4}, transposed.program.typeOf(transposed.program.outputs[0]));
    try types.expectExtents(&.{4}, transposed.program.typeOf(transposed.program.outputs[1]));
}

fn sumBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].sum(.lane);
}

test "tensor pullback transposes reduce sum" {
    var source = try trace.define(std.testing.allocator, "pullback_sum", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, sumBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer linearized.deinit();

    var transposed = try pullback(std.testing.allocator, &linearized, .{});
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 2), transposed.program.parameters.len);
    try types.expectExtents(&.{4}, transposed.program.typeOf(transposed.program.parameters[0]));
    try types.expectExtents(&.{}, transposed.program.typeOf(transposed.program.parameters[1]));
    try std.testing.expectEqual(@as(usize, 1), transposed.program.outputs.len);
    try types.expectExtents(&.{4}, transposed.program.typeOf(transposed.program.outputs[0]));
}

fn productLossBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].mul(args[1]);
    return try product.sum(.lane);
}

const ReverseGeneratedCounts = struct {
    mul: usize = 0,
    broadcast_in_dim: usize = 0,
    metadata_checks: usize = 0,
};

const ReverseGeneratedRewrite = struct {
    counts: *ReverseGeneratedCounts,

    pub fn mul(self: *@This(), ctx: *transform.Context) !?trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) {
            self.counts.mul += 1;
            self.counts.metadata_checks += 1;
            _ = ctx.isZero(0);
            _ = ctx.constantPayload(1);
        }
        return null;
    }

    pub fn broadcastInDim(self: *@This(), ctx: *transform.Context) !?trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) self.counts.broadcast_in_dim += 1;
        return null;
    }
};

test "tensor pullback binds generated transpose ops through downstream semantics" {
    var source = try trace.define(std.testing.allocator, "pullback_generated", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, productLossBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer linearized.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    var counts = ReverseGeneratedCounts{};
    const graph = interpret.Graph{ .builder = &builder };
    const rewrite = transform.semantics(&linearized.program, graph, ReverseGeneratedRewrite{ .counts = &counts });
    var transposed = try pullbackWith(std.testing.allocator, &linearized, .{}, rewrite);
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 2), counts.mul);
    try std.testing.expectEqual(@as(usize, 1), counts.broadcast_in_dim);
    try std.testing.expectEqual(@as(usize, 2), counts.metadata_checks);
    try std.testing.expectEqual(@as(usize, 3), transposed.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), transposed.program.outputs.len);
}

fn residualExpressionBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const one = try builder.scalar(.f32, 1.0);
    const scale = try args[1].add(one);
    const product = try args[0].mul(scale);
    return try product.sum(.lane);
}

test "tensor pullback replays residual expressions through interpretation" {
    var source = try trace.define(std.testing.allocator, "pullback_residual_expression", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, residualExpressionBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer linearized.deinit();

    var transposed = try pullback(std.testing.allocator, &linearized, .{});
    defer transposed.deinit();

    var replayed_residual_expression = false;
    for (transposed.program.operations) |op| {
        switch (op.kind) {
            .binary => |binary| {
                if (binary.op == .add) replayed_residual_expression = true;
            },
            else => {},
        }
    }

    try std.testing.expect(replayed_residual_expression);
    try std.testing.expectEqual(@as(usize, 3), transposed.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), transposed.program.outputs.len);
    try types.expectExtents(&.{4}, transposed.program.typeOf(transposed.program.outputs[0]));
}

fn matmulBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].contract(args[1], .k);
    return try product.sum(.{ .m, .n });
}

test "tensor pullback transposes matmul through scalar loss" {
    var source = try trace.define(std.testing.allocator, "pullback_matmul", &.{
        types.spec(.f32, .{ .m = 2, .k = 4 }),
        types.spec(.f32, .{ .k = 4, .n = 3 }),
    }, matmulBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer linearized.deinit();

    var transposed = try pullback(std.testing.allocator, &linearized, .{});
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 3), transposed.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), transposed.program.outputs.len);
    try types.expectExtents(&.{ 2, 4 }, transposed.program.typeOf(transposed.program.outputs[0]));
    try types.expectExtents(&.{ 4, 3 }, transposed.program.typeOf(transposed.program.outputs[1]));
}

fn batchedMatmulBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].contract(args[1], .k);
    return try product.sum(.{ .b, .m, .n });
}

fn rawTransposedMatmulBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].builder.dotGeneralOp(args[0], args[1], &.{0}, &.{0}, &.{}, &.{});
    return try product.sum(.{ .m, .n });
}

fn rawTrailingBatchMatmulBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].builder.dotGeneralOp(args[0], args[1], &.{1}, &.{0}, &.{2}, &.{2});
    return try product.sum(.{ .b, .m, .n });
}

test "tensor pullback transposes batched matmul through scalar loss" {
    var source = try trace.define(std.testing.allocator, "pullback_batched_matmul", &.{
        types.spec(.f32, .{ .b = 5, .m = 2, .k = 4 }),
        types.spec(.f32, .{ .b = 5, .k = 4, .n = 3 }),
    }, batchedMatmulBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer linearized.deinit();

    var transposed = try pullback(std.testing.allocator, &linearized, .{});
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 3), transposed.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), transposed.program.outputs.len);
    try types.expectExtents(&.{ 5, 2, 4 }, transposed.program.typeOf(transposed.program.outputs[0]));
    try types.expectExtents(&.{ 5, 4, 3 }, transposed.program.typeOf(transposed.program.outputs[1]));
}

test "tensor pullback transposes raw noncanonical rank-2 dot_general" {
    var source = try trace.define(std.testing.allocator, "pullback_raw_transposed_matmul", &.{
        types.spec(.f32, .{ .k = 4, .m = 2 }),
        types.spec(.f32, .{ .k = 4, .n = 3 }),
    }, rawTransposedMatmulBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer linearized.deinit();

    var transposed = try pullback(std.testing.allocator, &linearized, .{});
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 2), transposed.program.outputs.len);
    try types.expectExtents(&.{ 4, 2 }, transposed.program.typeOf(transposed.program.outputs[0]));
    try types.expectExtents(&.{ 4, 3 }, transposed.program.typeOf(transposed.program.outputs[1]));
}

test "tensor pullback transposes raw noncanonical batched dot_general" {
    var source = try trace.define(std.testing.allocator, "pullback_raw_trailing_batch_matmul", &.{
        types.spec(.f32, .{ .m = 2, .k = 4, .b = 5 }),
        types.spec(.f32, .{ .k = 4, .n = 3, .b = 5 }),
    }, rawTrailingBatchMatmulBody);
    defer source.deinit();

    var linearized = try autodiff.linearize(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer linearized.deinit();

    var transposed = try pullback(std.testing.allocator, &linearized, .{});
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 2), transposed.program.outputs.len);
    try types.expectExtents(&.{ 2, 4, 5 }, transposed.program.typeOf(transposed.program.outputs[0]));
    try types.expectExtents(&.{ 4, 3, 5 }, transposed.program.typeOf(transposed.program.outputs[1]));
}

fn doublingVjpBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = builder;
    return args[0].builder.customCall("accy.custom.double", 1, &.{args[0]}, args[0].ty);
}

const DoublingJvpRule = struct {
    pub fn bind(self: *@This(), ctx: anytype) !autodiff.Dual {
        _ = self;
        switch (ctx.op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, "accy.custom.double")) {
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

const DoublingVjpRule = struct {
    applied: *usize,

    pub fn customCall(self: *@This(), ctx: anytype) !void {
        self.applied.* += 1;
        if (!ctx.operandIsActive(0)) return;
        const builder = ctx.builderHandle();
        const contribution = try builder.customCall(ctx.custom.target, ctx.custom.version, &.{ctx.cotangent}, ctx.cotangent.ty);
        try ctx.contribute(0, contribution);
    }
};

fn doublingLinearization(allocator: std.mem.Allocator, source: *const program_mod.Program) !autodiff.Linearization {
    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();
    const graph = interpret.Graph{ .builder = &builder };
    const linear = autodiff.semantics(source, graph, .{ .wrt = &.{0} });
    return interpret.run(allocator, source, interpret.layer(autodiff.Dual, linear, DoublingJvpRule{}));
}

test "tensor pullback rejects active custom calls without a vjp contract" {
    var source = try trace.define(std.testing.allocator, "vjp_opaque_custom", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doublingVjpBody);
    defer source.deinit();

    var linearized = try doublingLinearization(std.testing.allocator, &source);
    defer linearized.deinit();

    try std.testing.expectError(
        error.CustomCallRequiresVjpContract,
        pullback(std.testing.allocator, &linearized, .{}),
    );
}

test "tensor pullback accepts custom call vjp contracts through rules" {
    var source = try trace.define(std.testing.allocator, "vjp_custom_contract", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doublingVjpBody);
    defer source.deinit();

    var linearized = try doublingLinearization(std.testing.allocator, &source);
    defer linearized.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, linearized.program.name);
    errdefer builder.deinit();
    const graph = interpret.Graph{ .builder = &builder };

    var applied: usize = 0;
    var transposed = try pullbackWithRules(
        std.testing.allocator,
        &linearized,
        .{},
        graph,
        DoublingVjpRule{ .applied = &applied },
    );
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 1), applied);

    var custom_calls: usize = 0;
    for (transposed.program.operations) |op| {
        switch (op.kind) {
            .custom_call => custom_calls += 1,
            else => {},
        }
    }
    try std.testing.expect(custom_calls >= 1);
}

const residual_scale_target = "accy.custom.residual.scale";

fn residualScaleVjpBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const scaled = try builder.customCall(residual_scale_target, 1, &.{ args[0], args[1] }, args[0].ty);
    return try scaled.sum(.lane);
}

const ResidualScaleJvpRule = struct {
    pub fn bind(self: *@This(), ctx: anytype) !autodiff.Dual {
        _ = self;
        switch (ctx.op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, residual_scale_target)) {
                    const builder = ctx.builderHandle();
                    return .{
                        .primal = try builder.customCall(custom.target, custom.version, &.{ ctx.args[0].primal, ctx.args[1].primal }, ctx.op.result),
                        .tangent = try builder.customCall(custom.target, custom.version, &.{ ctx.args[0].tangent, ctx.args[1].primal }, ctx.op.result),
                    };
                }
            },
            else => {},
        }
        return ctx.default();
    }
};

const ResidualScaleVjpRule = struct {
    applied: *usize,
    residuals_used: *usize,

    pub fn customCall(self: *@This(), ctx: anytype) !void {
        if (!std.mem.eql(u8, ctx.custom.target, residual_scale_target)) return error.UnexpectedCustomCall;
        self.applied.* += 1;
        if (!ctx.operandIsActive(0)) return;

        const factor = ctx.operandResidual(1);
        self.residuals_used.* += 1;

        const builder = ctx.builderHandle();
        const contribution = try builder.customCall(
            ctx.custom.target,
            ctx.custom.version,
            &.{ ctx.cotangent, factor },
            ctx.cotangent.ty,
        );
        try ctx.contribute(0, contribution);
    }
};

fn residualScaleLinearization(allocator: std.mem.Allocator, source: *const program_mod.Program) !autodiff.Linearization {
    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();
    const graph = interpret.Graph{ .builder = &builder };
    const linear = autodiff.semantics(source, graph, .{ .wrt = &.{0} });
    return interpret.run(allocator, source, interpret.layer(autodiff.Dual, linear, ResidualScaleJvpRule{}));
}

test "tensor pullback exposes inactive custom call operands as vjp residuals" {
    var source = try trace.define(std.testing.allocator, "vjp_custom_operand_residual", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, residualScaleVjpBody);
    defer source.deinit();

    var linearized = try residualScaleLinearization(std.testing.allocator, &source);
    defer linearized.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, linearized.program.name);
    errdefer builder.deinit();
    const graph = interpret.Graph{ .builder = &builder };

    var applied: usize = 0;
    var residuals_used: usize = 0;
    var transposed = try pullbackWithRules(
        std.testing.allocator,
        &linearized,
        .{},
        graph,
        ResidualScaleVjpRule{
            .applied = &applied,
            .residuals_used = &residuals_used,
        },
    );
    defer transposed.deinit();

    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(usize, 1), residuals_used);
    try std.testing.expectEqual(@as(usize, 3), transposed.program.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), transposed.program.outputs.len);
    try types.expectExtents(&.{4}, transposed.program.typeOf(transposed.program.outputs[0]));

    var residual_scale_calls: usize = 0;
    for (transposed.program.operations) |op| {
        switch (op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, residual_scale_target)) {
                    residual_scale_calls += 1;
                    try std.testing.expectEqual(@as(usize, 2), custom.operands.len);
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), residual_scale_calls);
}

const stateful_inner_target = "accy.custom.stateful.inner";
const stateful_outer_target = "accy.custom.stateful.outer";

fn statefulVjpBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const inner = try builder.customCall(stateful_inner_target, 1, &.{args[0]}, args[0].ty);
    return try builder.customCall(stateful_outer_target, 1, &.{inner}, inner.ty);
}

const StatefulJvpRule = struct {
    pub fn bind(self: *@This(), ctx: anytype) !autodiff.Dual {
        _ = self;
        switch (ctx.op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, stateful_inner_target) or
                    std.mem.eql(u8, custom.target, stateful_outer_target))
                {
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

const StatefulVjpRule = struct {
    outer_seen: bool = false,

    pub fn customCall(self: *@This(), ctx: anytype) !void {
        if (std.mem.eql(u8, ctx.custom.target, stateful_outer_target)) {
            self.outer_seen = true;
        } else if (std.mem.eql(u8, ctx.custom.target, stateful_inner_target)) {
            if (!self.outer_seen) return error.VjpRuleStateWasCopied;
        } else {
            return error.UnexpectedCustomCall;
        }

        if (!ctx.operandIsActive(0)) return;
        const builder = ctx.builderHandle();
        const contribution = try builder.customCall(ctx.custom.target, ctx.custom.version, &.{ctx.cotangent}, ctx.cotangent.ty);
        try ctx.contribute(0, contribution);
    }
};

fn statefulLinearization(allocator: std.mem.Allocator, source: *const program_mod.Program) !autodiff.Linearization {
    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();
    const graph = interpret.Graph{ .builder = &builder };
    const linear = autodiff.semantics(source, graph, .{ .wrt = &.{0} });
    return interpret.run(allocator, source, interpret.layer(autodiff.Dual, linear, StatefulJvpRule{}));
}

test "tensor pullback preserves local vjp rule state between custom calls" {
    var source = try trace.define(std.testing.allocator, "vjp_stateful_custom_contract", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, statefulVjpBody);
    defer source.deinit();

    var linearized = try statefulLinearization(std.testing.allocator, &source);
    defer linearized.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, linearized.program.name);
    errdefer builder.deinit();
    const graph = interpret.Graph{ .builder = &builder };

    var transposed = try pullbackWithRules(
        std.testing.allocator,
        &linearized,
        .{},
        graph,
        StatefulVjpRule{},
    );
    defer transposed.deinit();

    var inner_calls: usize = 0;
    var outer_calls: usize = 0;
    for (transposed.program.operations) |op| {
        switch (op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, stateful_inner_target)) inner_calls += 1;
                if (std.mem.eql(u8, custom.target, stateful_outer_target)) outer_calls += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), inner_calls);
    try std.testing.expectEqual(@as(usize, 1), outer_calls);
}
