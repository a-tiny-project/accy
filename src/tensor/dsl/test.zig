const std = @import("std");
const gpu = @import("gpu");
const accy = @import("../../root.zig");
const tensor = @import("../root.zig");
const namespace = @import("root.zig");
const batch = tensor.batch;
const interpret_mod = tensor.interpret;
const program_mod = tensor.program;
const trace = tensor.trace;
const transform = tensor.transform;
const types = tensor.types;
const body = namespace.body;
const Program = namespace.Program;

fn elementwiseLoss(_: *trace.Builder, args: anytype) !trace.Value {
    const product = try args.param(.x).mul(args.param(.y));
    return try product.sum(.lane);
}

fn positionalLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].mul(args[1]);
    return try product.sum(.lane);
}

fn arrayForward(_: *trace.Builder, args: anytype) ![2]trace.Value {
    const sum = try args.param(.x).add(args.param(.y));
    return .{ sum, try sum.sum(.lane) };
}

fn addBeforeMulLoss(_: *trace.Builder, args: anytype) !trace.Value {
    const sum = try args.param(.x).add(args.param(.y));
    const product = try sum.mul(args.param(.z));
    return try product.sum(.lane);
}

fn selectUnmapped(_: *trace.Builder, args: anytype) !trace.Value {
    return args.param(.y);
}

fn selectAfterMul(_: *trace.Builder, args: anytype) !trace.Value {
    _ = try args.param(.x).mul(args.param(.y));
    return args.param(.z);
}

const ElementwiseOutputs = struct {
    product: trace.Value,
    total: trace.Value,
};

fn elementwiseForward(_: *trace.Builder, args: anytype) !ElementwiseOutputs {
    const product = try args.param(.x).mul(args.param(.y));
    return .{
        .product = product,
        .total = try product.sum(.lane),
    };
}

const ElementwiseLoss = Program(.{
    .name = "dsl_elementwise_loss",
    .parameters = .{
        .x = types.spec(.f32, .{ .lane = 4 }),
        .y = types.spec(.f32, .{ .lane = 4 }),
    },
    .body = elementwiseLoss,
});

const ElementwiseGradient = ElementwiseLoss.grad(.{ .wrt = ElementwiseLoss.wrt(.{ .x, .y }) });

const GeneratedMulAsAdd = struct {
    pub fn mul(_: *@This(), ctx: anytype) !trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) {
            var op = ctx.op.*;
            op.kind = .{ .binary = .{
                .op = .add,
                .lhs = program_mod.synthetic_id,
                .rhs = program_mod.synthetic_id,
            } };
            return ctx.next.bind(&op, ctx.args);
        }
        return ctx.default();
    }
};

const GeneratedSeedAsZero = struct {
    pub fn constant(_: *@This(), ctx: anytype) !trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) {
            const payload = try ctx.builderHandle().arena.allocator().alloc(u8, try ctx.op.result.byteCount());
            @memset(payload, 0);
            var op = ctx.op.*;
            op.kind = .{ .constant = .{ .payload = payload } };
            return ctx.next.bind(&op, &.{});
        }
        return ctx.default();
    }
};

const GeneratedBroadcastAsZero = struct {
    pub fn broadcastInDim(_: *@This(), ctx: anytype) !trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) {
            const payload = try ctx.builderHandle().arena.allocator().alloc(u8, try ctx.op.result.byteCount());
            @memset(payload, 0);
            var op = ctx.op.*;
            op.kind = .{ .constant = .{ .payload = payload } };
            return ctx.next.bind(&op, &.{});
        }
        return ctx.default();
    }
};

const GeneratedMulAsAddFromAnalysis = struct {
    analysis: *const MulPresence.Result,

    pub fn mul(self: *@This(), ctx: anytype) !trace.Value {
        if (self.analysis.has_mul and ctx.op.id.index == program_mod.synthetic_id.index) {
            var op = ctx.op.*;
            op.kind = .{ .binary = .{
                .op = .add,
                .lhs = program_mod.synthetic_id,
                .rhs = program_mod.synthetic_id,
            } };
            return ctx.next.bind(&op, ctx.args);
        }
        return ctx.default();
    }
};

const GeneratedBroadcastAsZeroFromAnalysis = struct {
    analysis: *const MulPresence.Result,

    pub fn broadcastInDim(self: *@This(), ctx: anytype) !trace.Value {
        if (self.analysis.has_mul and ctx.op.id.index == program_mod.synthetic_id.index) {
            const payload = try ctx.builderHandle().arena.allocator().alloc(u8, try ctx.op.result.byteCount());
            @memset(payload, 0);
            var op = ctx.op.*;
            op.kind = .{ .constant = .{ .payload = payload } };
            return ctx.next.bind(&op, &.{});
        }
        return ctx.default();
    }
};

const LinearizeAnalysisHooks = struct {
    linearize: interpret_mod.With(GeneratedMulAsAddFromAnalysis),
};

const PullbackAnalysisHooks = struct {
    pullback: interpret_mod.With(GeneratedMulAsAddFromAnalysis),
};

const BatchAnalysisHooks = struct {
    batch: interpret_mod.With(GeneratedBroadcastAsZeroFromAnalysis),
};

fn linearizeHooksFromMulPresence(analysis: *const MulPresence.Result) LinearizeAnalysisHooks {
    return .{ .linearize = interpret_mod.bind(GeneratedMulAsAddFromAnalysis{ .analysis = analysis }) };
}

fn pullbackHooksFromMulPresence(analysis: *const MulPresence.Result) PullbackAnalysisHooks {
    return .{ .pullback = interpret_mod.bind(GeneratedMulAsAddFromAnalysis{ .analysis = analysis }) };
}

fn batchHooksFromMulPresence(analysis: *const MulPresence.Result) BatchAnalysisHooks {
    return .{ .batch = interpret_mod.bind(GeneratedBroadcastAsZeroFromAnalysis{ .analysis = analysis }) };
}

const ElementwiseGradientWithGeneratedRewrite = ElementwiseLoss.gradWith(
    .{ .wrt = ElementwiseLoss.wrt(.{ .x, .y }) },
    .{
        .pullback = interpret_mod.bind(GeneratedMulAsAdd{}),
        .seed = interpret_mod.bind(GeneratedSeedAsZero{}),
    },
);

const ElementwiseMulAnalysis = ElementwiseLoss.analyze(MulPresence{});

const ElementwiseGradientWithAnalysisRewrite = ElementwiseMulAnalysis.gradWith(
    .{ .wrt = ElementwiseLoss.wrt(.{ .x, .y }) },
    pullbackHooksFromMulPresence,
);

const BatchedElementwiseGradient = ElementwiseGradient.vmap(.{
    .axis_size = 8,
    .in_axes = ElementwiseGradient.inAxes(.{ .x = batch.mapped(0), .y = batch.mapped(0) }),
});

const BatchedElementwiseGradientWithGeneratedRewrite = ElementwiseGradientWithGeneratedRewrite.vmap(.{
    .axis_size = 8,
    .in_axes = ElementwiseGradientWithGeneratedRewrite.inAxes(.{ .x = batch.mapped(0), .y = batch.mapped(0) }),
});

const BatchedElementwiseGradientWithAnalysisRewrite = ElementwiseGradientWithAnalysisRewrite.vmap(.{
    .axis_size = 8,
    .in_axes = ElementwiseGradientWithAnalysisRewrite.inAxes(.{ .x = batch.mapped(0), .y = batch.mapped(0) }),
});

const ElementwiseJvp = ElementwiseLoss.jvp(.{ .wrt = ElementwiseLoss.wrt(.{ .x, .y }) });

const ElementwiseJvpWithGeneratedRewrite = ElementwiseLoss.jvpWith(
    .{ .wrt = ElementwiseLoss.wrt(.{ .x, .y }) },
    .{ .linearize = interpret_mod.bind(GeneratedMulAsAdd{}) },
);

const ElementwiseJvpWithAnalysisRewrite = ElementwiseMulAnalysis.jvpWith(
    .{ .wrt = ElementwiseLoss.wrt(.{ .x, .y }) },
    linearizeHooksFromMulPresence,
);

const dsl_custom_double_target = "accy.dsl.custom.double";

fn customDoubleLoss(builder: *trace.Builder, args: anytype) !trace.Value {
    const input = args.param(.x);
    const doubled = try builder.customCall(dsl_custom_double_target, 1, &.{input}, input.ty);
    return try doubled.sum(.lane);
}

const DslDoubleJvpRule = struct {
    pub fn bind(_: *@This(), ctx: anytype) !tensor.Dual {
        switch (ctx.op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, dsl_custom_double_target)) {
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

const CustomDoubleLoss = Program(.{
    .name = "dsl_custom_double_loss",
    .parameters = .{
        .x = types.spec(.f32, .{ .lane = 4 }),
    },
    .body = customDoubleLoss,
});

const CustomDoubleJvp = CustomDoubleLoss.jvpWith(
    .{ .wrt = CustomDoubleLoss.wrt(.x) },
    .{ .jvp = interpret_mod.bind(DslDoubleJvpRule{}) },
);

const BatchedElementwiseJvp = ElementwiseJvp.vmap(.{
    .axis_size = 8,
    .in_axes = ElementwiseJvp.inAxes(.{
        .primals = .{ .x = batch.mapped(0), .y = batch.mapped(0) },
        .tangents = .{ .x = batch.mapped(0), .y = batch.mapped(0) },
    }),
});

const BatchedElementwiseJvpWithGeneratedRewrite = ElementwiseJvpWithGeneratedRewrite.vmap(.{
    .axis_size = 8,
    .in_axes = ElementwiseJvpWithGeneratedRewrite.inAxes(.{
        .primals = .{ .x = batch.mapped(0), .y = batch.mapped(0) },
        .tangents = .{ .x = batch.mapped(0), .y = batch.mapped(0) },
    }),
});

const BatchedElementwiseJvpWithAnalysisRewrite = ElementwiseJvpWithAnalysisRewrite.vmap(.{
    .axis_size = 8,
    .in_axes = ElementwiseJvpWithAnalysisRewrite.inAxes(.{
        .primals = .{ .x = batch.mapped(0), .y = batch.mapped(0) },
        .tangents = .{ .x = batch.mapped(0), .y = batch.mapped(0) },
    }),
});

const ArrayForward = Program(.{
    .name = "dsl_array_forward",
    .parameters = .{
        .x = types.spec(.f32, .{ .lane = 4 }),
        .y = types.spec(.f32, .{ .lane = 4 }),
    },
    .body = arrayForward,
});

const ArrayForwardCopy = ArrayForward.rewrite(struct {}{});

const ElementwiseForward = Program(.{
    .name = "dsl_elementwise_forward",
    .parameters = .{
        .x = types.spec(.f32, .{ .lane = 4 }),
        .y = types.spec(.f32, .{ .lane = 4 }),
    },
    .body = elementwiseForward,
});

const ElementwiseForwardJvp = ElementwiseForward.jvp(.{ .wrt = ElementwiseForward.wrt(.{ .x, .y }) });

const SelectUnmapped = Program(.{
    .name = "dsl_select_unmapped",
    .parameters = .{
        .x = types.spec(.f32, .{ .lane = 4 }),
        .y = types.spec(.f32, .{ .lane = 4 }),
    },
    .body = selectUnmapped,
});

const BatchedSelectUnmapped = SelectUnmapped.vmap(.{
    .axis_size = 8,
    .in_axes = SelectUnmapped.inAxes(.{ .x = batch.mapped(0) }),
});

const SelectAfterMul = Program(.{
    .name = "dsl_select_after_mul",
    .parameters = .{
        .x = types.spec(.f32, .{ .lane = 4 }),
        .y = types.spec(.f32, .{ .lane = 4 }),
        .z = types.spec(.f32, .{ .lane = 4 }),
    },
    .body = selectAfterMul,
});

const BatchedSelectUnmappedWithGeneratedRewrite = SelectUnmapped.vmapWith(
    .{
        .axis_size = 8,
        .in_axes = SelectUnmapped.inAxes(.{ .x = batch.mapped(0) }),
    },
    .{ .batch = interpret_mod.bind(GeneratedBroadcastAsZero{}) },
);

const SelectAfterMulAnalysis = SelectAfterMul.analyze(MulPresence{});

const BatchedSelectAfterMulWithAnalysisRewrite = SelectAfterMulAnalysis.vmapWith(
    .{
        .axis_size = 8,
        .in_axes = SelectAfterMul.inAxes(.{ .x = batch.mapped(0), .y = batch.mapped(0) }),
    },
    batchHooksFromMulPresence,
);

const BatchedElementwiseForward = ElementwiseForward.vmap(.{
    .axis_size = 8,
    .in_axes = ElementwiseForward.inAxes(.{ .x = batch.mapped(0), .y = batch.mapped(0) }),
});

const AddBeforeMulLoss = Program(.{
    .name = "dsl_add_before_mul_loss",
    .parameters = .{
        .x = types.spec(.f32, .{ .lane = 4 }),
        .y = types.spec(.f32, .{ .lane = 4 }),
        .z = types.spec(.f32, .{ .lane = 4 }),
    },
    .body = addBeforeMulLoss,
});

const AddCounter = struct {
    count: *usize,

    pub const Value = usize;
    pub const Result = usize;

    pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const usize) !usize {
        _ = args;
        switch (op.kind) {
            .binary => |binary| {
                if (binary.op == .add) self.count.* += 1;
            },
            else => {},
        }
        return self.count.*;
    }

    pub fn finish(self: *@This(), outputs: []const usize) !Result {
        _ = outputs;
        return self.count.*;
    }
};

const BinaryCounts = struct {
    add_count: usize = 0,
    mul_count: usize = 0,
};

const BinaryCounter = struct {
    counts: BinaryCounts = .{},

    pub const Value: type = BinaryCounts;
    pub const Result: type = BinaryCounts;

    pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const BinaryCounts) !BinaryCounts {
        _ = args;
        switch (op.kind) {
            .binary => |binary| switch (binary.op) {
                .add => self.counts.add_count += 1,
                .mul => self.counts.mul_count += 1,
                else => {},
            },
            else => {},
        }
        return self.counts;
    }

    pub fn finish(self: *@This(), outputs: []const BinaryCounts) !Result {
        _ = outputs;
        return self.counts;
    }
};

const CountedGraph = struct {
    graph: program_mod.Program,
    add_count: usize,
    broadcast_in_dim_count: usize,
    finish_count: usize,
    mul_count: usize,

    pub fn deinit(self: *@This()) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

const GraphLayerCounter = struct {
    add_count: usize = 0,
    broadcast_in_dim_count: usize = 0,
    finish_count: usize = 0,
    mul_count: usize = 0,

    pub const Result: type = CountedGraph;

    pub fn add(self: *@This(), ctx: anytype) !trace.Value {
        self.add_count += 1;
        return ctx.default();
    }

    pub fn broadcastInDim(self: *@This(), ctx: anytype) !trace.Value {
        self.broadcast_in_dim_count += 1;
        return ctx.default();
    }

    pub fn mul(self: *@This(), ctx: anytype) !trace.Value {
        self.mul_count += 1;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype, outputs: []const trace.Value) !CountedGraph {
        self.finish_count += 1;
        return .{
            .graph = try ctx.default(outputs),
            .add_count = self.add_count,
            .broadcast_in_dim_count = self.broadcast_in_dim_count,
            .finish_count = self.finish_count,
            .mul_count = self.mul_count,
        };
    }
};

const MulPresence = struct {
    has_mul: bool = false,

    pub const Value = bool;
    pub const Result = struct {
        has_mul: bool,
    };

    pub fn default(self: *@This(), ctx: anytype) !bool {
        _ = ctx;
        return self.has_mul;
    }

    pub fn mul(self: *@This(), ctx: anytype) !bool {
        _ = ctx;
        self.has_mul = true;
        return self.has_mul;
    }

    pub fn finish(self: *@This(), outputs: []const bool) !Result {
        _ = outputs;
        return .{ .has_mul = self.has_mul };
    }
};

const DropAddWhenMulPresent = struct {
    enabled: bool,

    pub fn add(self: *@This(), ctx: *transform.Context) !?trace.Value {
        if (self.enabled) return ctx.arg(0);
        return null;
    }
};

fn dropAddFromMulPresence(analysis: *const MulPresence.Result) DropAddWhenMulPresent {
    return .{ .enabled = analysis.has_mul };
}

const AddBeforeMulAnalysis = AddBeforeMulLoss.analyze(MulPresence{});

const AddDroppedAfterMulAnalysis = AddBeforeMulAnalysis.rewrite(dropAddFromMulPresence);

const BatchedAddDroppedAfterMulAnalysis = AddDroppedAfterMulAnalysis.vmap(.{
    .axis_size = 8,
    .in_axes = AddDroppedAfterMulAnalysis.inAxes(.{
        .x = batch.mapped(0),
        .y = batch.mapped(0),
        .z = batch.mapped(0),
    }),
});

test "tensor Program keeps positional parameters available" {
    const PositionalLoss = Program(.{
        .name = "dsl_positional_loss",
        .parameters = &.{ types.spec(.f32, .{ .lane = 4 }), types.spec(.f32, .{ .lane = 4 }) },
        .body = positionalLoss,
    });

    var built = try PositionalLoss.build(std.testing.allocator);
    defer built.deinit();

    try std.testing.expectEqual(@as(usize, 2), built.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), built.outputs.len);
    try types.expectExtents(&.{}, built.typeOf(built.outputs[0]));
    try PositionalLoss.verify(std.testing.allocator);
}

test "tensor Program supports array output bodies" {
    var built = try ArrayForward.build(std.testing.allocator);
    defer built.deinit();

    try std.testing.expectEqual(@as(usize, 2), built.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), built.outputs.len);
    try types.expectExtents(&.{4}, built.typeOf(built.outputs[0]));
    try types.expectExtents(&.{}, built.typeOf(built.outputs[1]));
    try ArrayForward.verify(std.testing.allocator);
}

test "tensor Program interprets source and derived programs through user semantics" {
    var add_count: usize = 0;
    const counted = try ArrayForward.interpret(std.testing.allocator, AddCounter{ .count = &add_count });

    try std.testing.expectEqual(@as(usize, 1), counted);

    var copied_add_count: usize = 0;
    const counted_copy = try ArrayForwardCopy.interpret(std.testing.allocator, AddCounter{ .count = &copied_add_count });

    try std.testing.expectEqual(@as(usize, 1), counted_copy);
}

test "tensor Program attaches graph semantics specs" {
    var copied = try ArrayForward.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied.deinit();

    try std.testing.expectEqual(@as(usize, 1), copied.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied.finish_count);
    try std.testing.expectEqual(@as(usize, 2), copied.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied.graph.outputs.len);
    try types.expectExtents(&.{4}, copied.graph.typeOf(copied.graph.outputs[0]));
    try types.expectExtents(&.{}, copied.graph.typeOf(copied.graph.outputs[1]));

    var copied_rewrite = try ArrayForwardCopy.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_rewrite.deinit();

    try std.testing.expectEqual(@as(usize, 1), copied_rewrite.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_rewrite.finish_count);
    try std.testing.expectEqual(@as(usize, 2), copied_rewrite.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied_rewrite.graph.outputs.len);
    try types.expectExtents(&.{4}, copied_rewrite.graph.typeOf(copied_rewrite.graph.outputs[0]));
    try types.expectExtents(&.{}, copied_rewrite.graph.typeOf(copied_rewrite.graph.outputs[1]));

    var copied_jvp = try ElementwiseJvp.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_jvp.deinit();

    try std.testing.expectEqual(@as(usize, 1), copied_jvp.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_jvp.finish_count);
    try std.testing.expectEqual(@as(usize, 3), copied_jvp.mul_count);
    try std.testing.expectEqual(@as(usize, 4), copied_jvp.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied_jvp.graph.outputs.len);
    try types.expectExtents(&.{}, copied_jvp.graph.typeOf(copied_jvp.graph.outputs[0]));
    try types.expectExtents(&.{}, copied_jvp.graph.typeOf(copied_jvp.graph.outputs[1]));

    var copied_jvp_with = try ElementwiseJvpWithGeneratedRewrite.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_jvp_with.deinit();

    try std.testing.expectEqual(@as(usize, 3), copied_jvp_with.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_jvp_with.finish_count);
    try std.testing.expectEqual(@as(usize, 1), copied_jvp_with.mul_count);
    try std.testing.expectEqual(@as(usize, 4), copied_jvp_with.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied_jvp_with.graph.outputs.len);
    try types.expectExtents(&.{}, copied_jvp_with.graph.typeOf(copied_jvp_with.graph.outputs[0]));
    try types.expectExtents(&.{}, copied_jvp_with.graph.typeOf(copied_jvp_with.graph.outputs[1]));

    var copied_analysis_jvp = try ElementwiseJvpWithAnalysisRewrite.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_analysis_jvp.deinit();

    try std.testing.expectEqual(@as(usize, 3), copied_analysis_jvp.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_jvp.finish_count);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_jvp.mul_count);
    try std.testing.expectEqual(@as(usize, 4), copied_analysis_jvp.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied_analysis_jvp.graph.outputs.len);
    try types.expectExtents(&.{}, copied_analysis_jvp.graph.typeOf(copied_analysis_jvp.graph.outputs[0]));
    try types.expectExtents(&.{}, copied_analysis_jvp.graph.typeOf(copied_analysis_jvp.graph.outputs[1]));

    var copied_grad = try ElementwiseGradient.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_grad.deinit();

    try std.testing.expectEqual(@as(usize, 0), copied_grad.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_grad.broadcast_in_dim_count);
    try std.testing.expectEqual(@as(usize, 1), copied_grad.finish_count);
    try std.testing.expectEqual(@as(usize, 2), copied_grad.mul_count);
    try std.testing.expectEqual(@as(usize, 2), copied_grad.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied_grad.graph.outputs.len);
    try types.expectExtents(&.{4}, copied_grad.graph.typeOf(copied_grad.graph.outputs[ElementwiseGradient.out(.x)]));
    try types.expectExtents(&.{4}, copied_grad.graph.typeOf(copied_grad.graph.outputs[ElementwiseGradient.out(.y)]));

    var copied_grad_with = try ElementwiseGradientWithGeneratedRewrite.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_grad_with.deinit();

    try std.testing.expectEqual(@as(usize, 2), copied_grad_with.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_grad_with.broadcast_in_dim_count);
    try std.testing.expectEqual(@as(usize, 1), copied_grad_with.finish_count);
    try std.testing.expectEqual(@as(usize, 0), copied_grad_with.mul_count);
    try std.testing.expectEqual(@as(usize, 2), copied_grad_with.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied_grad_with.graph.outputs.len);
    try types.expectExtents(&.{4}, copied_grad_with.graph.typeOf(copied_grad_with.graph.outputs[ElementwiseGradientWithGeneratedRewrite.out(.x)]));
    try types.expectExtents(&.{4}, copied_grad_with.graph.typeOf(copied_grad_with.graph.outputs[ElementwiseGradientWithGeneratedRewrite.out(.y)]));

    var copied_analysis_grad = try ElementwiseGradientWithAnalysisRewrite.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_analysis_grad.deinit();

    try std.testing.expectEqual(@as(usize, 2), copied_analysis_grad.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_grad.broadcast_in_dim_count);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_grad.finish_count);
    try std.testing.expectEqual(@as(usize, 0), copied_analysis_grad.mul_count);
    try std.testing.expectEqual(@as(usize, 2), copied_analysis_grad.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), copied_analysis_grad.graph.outputs.len);
    try types.expectExtents(&.{4}, copied_analysis_grad.graph.typeOf(copied_analysis_grad.graph.outputs[ElementwiseGradientWithAnalysisRewrite.out(.x)]));
    try types.expectExtents(&.{4}, copied_analysis_grad.graph.typeOf(copied_analysis_grad.graph.outputs[ElementwiseGradientWithAnalysisRewrite.out(.y)]));

    var copied_vmap = try BatchedSelectUnmapped.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_vmap.deinit();

    try std.testing.expectEqual(@as(usize, 0), copied_vmap.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_vmap.broadcast_in_dim_count);
    try std.testing.expectEqual(@as(usize, 1), copied_vmap.finish_count);
    try std.testing.expectEqual(@as(usize, 2), copied_vmap.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), copied_vmap.graph.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, copied_vmap.graph.typeOf(copied_vmap.graph.parameters[0]));
    try types.expectExtents(&.{4}, copied_vmap.graph.typeOf(copied_vmap.graph.parameters[1]));
    try types.expectExtents(&.{ 8, 4 }, copied_vmap.graph.typeOf(copied_vmap.graph.outputs[0]));

    var copied_vmap_with = try BatchedSelectUnmappedWithGeneratedRewrite.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_vmap_with.deinit();

    try std.testing.expectEqual(@as(usize, 0), copied_vmap_with.add_count);
    try std.testing.expectEqual(@as(usize, 0), copied_vmap_with.broadcast_in_dim_count);
    try std.testing.expectEqual(@as(usize, 1), copied_vmap_with.finish_count);
    try std.testing.expectEqual(@as(usize, 2), copied_vmap_with.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), copied_vmap_with.graph.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, copied_vmap_with.graph.typeOf(copied_vmap_with.graph.outputs[0]));

    var copied_analysis_vmap = try BatchedSelectAfterMulWithAnalysisRewrite.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_analysis_vmap.deinit();

    try std.testing.expectEqual(@as(usize, 0), copied_analysis_vmap.add_count);
    try std.testing.expectEqual(@as(usize, 0), copied_analysis_vmap.broadcast_in_dim_count);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_vmap.finish_count);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_vmap.mul_count);
    try std.testing.expectEqual(@as(usize, 3), copied_analysis_vmap.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_vmap.graph.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, copied_analysis_vmap.graph.typeOf(copied_analysis_vmap.graph.outputs[0]));
}

test "tensor Program derives transforms from user analysis semantics" {
    const analysis = try AddBeforeMulAnalysis.interpret(std.testing.allocator);
    try std.testing.expect(analysis.has_mul);

    var source = try AddBeforeMulLoss.build(std.testing.allocator);
    defer source.deinit();
    var analyzed = try AddDroppedAfterMulAnalysis.build(std.testing.allocator);
    defer analyzed.deinit();

    try std.testing.expect(analyzed.operationCount() < source.operationCount());
    try std.testing.expectEqual(@as(usize, 3), analyzed.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), analyzed.outputs.len);
    try types.expectExtents(&.{}, analyzed.typeOf(analyzed.outputs[0]));

    const counts = try AddDroppedAfterMulAnalysis.interpret(std.testing.allocator, BinaryCounter{});
    try std.testing.expectEqual(@as(usize, 0), counts.add_count);
    try std.testing.expectEqual(@as(usize, 1), counts.mul_count);
    try AddDroppedAfterMulAnalysis.verify(std.testing.allocator);

    var copied_analysis_rewrite = try AddDroppedAfterMulAnalysis.interpret(std.testing.allocator, interpret_mod.bind(GraphLayerCounter{}));
    defer copied_analysis_rewrite.deinit();
    try std.testing.expectEqual(@as(usize, 0), copied_analysis_rewrite.add_count);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_rewrite.finish_count);
    try std.testing.expectEqual(@as(usize, 3), copied_analysis_rewrite.graph.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), copied_analysis_rewrite.graph.outputs.len);
    try types.expectExtents(&.{}, copied_analysis_rewrite.graph.typeOf(copied_analysis_rewrite.graph.outputs[0]));

    var batched = try BatchedAddDroppedAfterMulAnalysis.build(std.testing.allocator);
    defer batched.deinit();
    try std.testing.expectEqual(@as(usize, 3), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), batched.outputs.len);
    try types.expectExtents(&.{8}, batched.typeOf(batched.outputs[0]));
    try BatchedAddDroppedAfterMulAnalysis.verify(std.testing.allocator);
}

test "tensor Program lowers source and derived programs directly" {
    const source_module = try ArrayForward.lower(std.testing.allocator);
    defer source_module.deinit();
    try source_module.verify();

    const derived_module = try BatchedElementwiseGradient.lower(std.testing.allocator);
    defer derived_module.deinit();
    try derived_module.verify();

    const explicit_source_module = try ArrayForward.interpret(std.testing.allocator, tensor.lower.module(std.testing.allocator));
    defer explicit_source_module.deinit();
    try explicit_source_module.verify();

    const explicit_jvp_module = try ElementwiseJvpWithGeneratedRewrite.interpret(std.testing.allocator, tensor.lower.module(std.testing.allocator));
    defer explicit_jvp_module.deinit();
    try explicit_jvp_module.verify();

    const explicit_grad_module = try ElementwiseGradientWithAnalysisRewrite.interpret(std.testing.allocator, tensor.lower.module(std.testing.allocator));
    defer explicit_grad_module.deinit();
    try explicit_grad_module.verify();
}

fn expectPreparedGeneratedKernels(prepared: *const tensor.BackendPreparedJob) !void {
    const kernel_count = try prepared.generatedKernelCount();
    try std.testing.expect(kernel_count > 0);
    var launch_count: usize = 0;
    for (0..kernel_count) |kernel_index| {
        const summary = try prepared.generatedKernelSummary(kernel_index);
        const program = try prepared.generatedKernelProgram(kernel_index);
        try std.testing.expect(summary.entry_name.len > 0);
        if (summary.launch_geometry != null) launch_count += 1;
        const launch = try program.launch();
        switch (summary.schedule.kind) {
            .flat => {
                try std.testing.expectEqual(@as(u32, 64), summary.schedule.threads.x);
                try std.testing.expect(launch.block[0] > 0);
                try std.testing.expect(launch.block[0] <= summary.schedule.threads.x);
            },
            .matrix => {
                try std.testing.expectEqual(@as(u32, 16), summary.schedule.threads.x);
                try std.testing.expectEqual(@as(u32, 16), summary.schedule.threads.y);
                try std.testing.expect(launch.block[0] > 0);
                try std.testing.expect(launch.block[0] <= summary.schedule.threads.x);
                try std.testing.expect(launch.block[1] > 0);
                try std.testing.expect(launch.block[1] <= summary.schedule.threads.y);
            },
        }
    }
    try std.testing.expect(launch_count > 0);
    try std.testing.expectError(error.InvalidIndex, prepared.generatedKernelSummary(kernel_count));
}

fn expectLoadedFragmentMatchesPrepared(
    allocator: std.mem.Allocator,
    prepared: *const tensor.BackendPreparedJob,
    generated_summaries: *const tensor.GeneratedKernelSummaries,
    artifact_summaries: *const tensor.ArtifactKernelSummaries,
    fragment: *tensor.LoadedFragment,
    artifact_format: gpu.ArtifactFormat,
) !void {
    const prepared_kernel_count = try prepared.generatedKernelCount();
    try std.testing.expectEqual(prepared_kernel_count, fragment.kernelCount());
    var executable_summaries = try fragment.copyKernelSummaries(allocator);
    defer executable_summaries.deinit();
    try std.testing.expectEqual(prepared_kernel_count, executable_summaries.len());
    for (generated_summaries.items) |generated_snapshot| {
        const summary = try executable_summaries.summaryForWork(generated_snapshot.work_item_id);
        const executable_summary = try fragment.kernelSummaryForWork(generated_snapshot.work_item_id);
        const generated = try prepared.generatedKernelSummaryForWork(summary.work_item_id);
        const copied_generated = try generated_summaries.summaryForWork(summary.work_item_id);
        const artifact_summary = try artifact_summaries.summaryForWork(summary.work_item_id);
        const generated_program = try prepared.generatedKernelProgramForWork(summary.work_item_id);
        try std.testing.expectEqual(tensor.ArtifactKernelSource.tensor, summary.source);
        try std.testing.expectEqualStrings(executable_summary.entry_name, summary.entry_name);
        try std.testing.expect(summary.entry_name.len > 0);
        try std.testing.expectEqualStrings(generated.entry_name, summary.entry_name);
        try std.testing.expectEqualStrings(copied_generated.entry_name, generated.entry_name);
        try std.testing.expectEqualStrings(artifact_summary.entry_name, summary.entry_name);
        try std.testing.expectEqual(artifact_summary.compile_argument_count, summary.compile_argument_count);
        try std.testing.expectEqual(generated.argument_count, summary.compile_argument_count);
        try std.testing.expectEqual(generated.body_fingerprint, try generated_program.bodyFingerprint(allocator));
        try std.testing.expectEqual(artifact_format, summary.artifact_format);
    }
}

test "tensor Program prepares generated kernel programs directly" {
    var source_prepared = try ElementwiseForward.prepare(std.testing.allocator);
    defer source_prepared.deinit();
    try expectPreparedGeneratedKernels(&source_prepared);

    var derived_prepared = try BatchedElementwiseGradient.prepareWith(std.testing.allocator, .{});
    defer derived_prepared.deinit();
    try expectPreparedGeneratedKernels(&derived_prepared);
}

test "tensor Program creates executable fragment through BackendHandle" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };

    const program_options = tensor.FragmentCompilerOptions{ .authored_kernel_diagnostic_id = "tensor/program-executable" };
    const program_compiled = try BatchedElementwiseGradient.compileFragment(
        allocator,
        state.handle(),
        program_options,
    );
    var fragment = try accy.executable.loadFragment(allocator, state.handle(), program_compiled, program_options);
    defer fragment.deinit();

    try std.testing.expect(state.create_count > 0);
    try std.testing.expect(state.load_count > 0);
    var fragment_summaries = try fragment.copyKernelSummaries(allocator);
    defer fragment_summaries.deinit();
    try std.testing.expect(fragment_summaries.len() > 0);
    try std.testing.expectEqual(fragment.kernelCount(), fragment_summaries.len());
    for (fragment_summaries.items, 0..) |summary, index| {
        const indexed_summary = try fragment_summaries.summary(index);
        const executable_summary = try fragment.kernelSummaryForWork(summary.work_item_id);
        try std.testing.expectEqualStrings(indexed_summary.entry_name, summary.entry_name);
        try std.testing.expectEqualStrings(executable_summary.entry_name, summary.entry_name);
        try std.testing.expectEqual(tensor.ArtifactKernelSource.tensor, summary.source);
        try std.testing.expect(summary.entry_name.len > 0);
        try std.testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, summary.artifact_format);
    }

    var direct_artifact = try BatchedElementwiseGradient.createArtifactJob(
        allocator,
        state.handle(),
        .{ .authored_kernel_diagnostic_id = "tensor/program-direct-artifact" },
    );
    defer direct_artifact.deinit();
    var direct_artifact_summaries = try direct_artifact.copyKernelSummaries(allocator);
    defer direct_artifact_summaries.deinit();
    try std.testing.expect(direct_artifact_summaries.len() > 0);
    try std.testing.expectEqual(direct_artifact.kernelCount(), direct_artifact_summaries.len());
    for (direct_artifact_summaries.items, 0..) |summary, index| {
        const indexed_summary = try direct_artifact_summaries.summary(index);
        try std.testing.expectEqualStrings(indexed_summary.entry_name, summary.entry_name);
        try std.testing.expectEqual(tensor.ArtifactKernelSource.tensor, summary.source);
        try std.testing.expect(summary.entry_name.len > 0);
        try std.testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, summary.artifact_format);
    }

    const direct_options = tensor.FragmentCompilerOptions{ .authored_kernel_diagnostic_id = "tensor/program-direct-artifact" };
    const direct_compiled = try tensor.compileFragmentFromArtifactJob(allocator, direct_artifact);
    var direct_artifact_fragment = try accy.executable.loadFragment(allocator, state.handle(), direct_compiled, direct_options);
    defer direct_artifact_fragment.deinit();
    try std.testing.expectEqual(direct_artifact.kernelCount(), direct_artifact_fragment.kernelCount());
    var direct_fragment_summaries = try direct_artifact_fragment.copyKernelSummaries(allocator);
    defer direct_fragment_summaries.deinit();
    try std.testing.expectEqual(direct_artifact_summaries.len(), direct_fragment_summaries.len());
    for (direct_artifact_summaries.items) |artifact_summary| {
        const executable_summary = try direct_fragment_summaries.summaryForWork(artifact_summary.work_item_id);
        try std.testing.expectEqualStrings(artifact_summary.entry_name, executable_summary.entry_name);
        try std.testing.expectEqual(artifact_summary.compile_argument_count, executable_summary.compile_argument_count);
    }

    var staged_state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    var prepared = try BatchedElementwiseGradient.prepareFragment(
        allocator,
        staged_state.handle(),
        .{ .authored_kernel_diagnostic_id = "tensor/program-staged-executable" },
    );
    defer prepared.deinit();
    try expectPreparedGeneratedKernels(&prepared);
    const prepared_kernel_count = try prepared.generatedKernelCount();
    var generated_summaries = try prepared.copyGeneratedKernelSummaries(allocator);
    defer generated_summaries.deinit();
    try std.testing.expectEqual(prepared_kernel_count, generated_summaries.len());
    for (generated_summaries.items, 0..) |summary, index| {
        const indexed_summary = try prepared.generatedKernelSummary(index);
        try std.testing.expectEqualStrings(indexed_summary.entry_name, summary.entry_name);
        const work_summary = try prepared.generatedKernelSummaryForWork(summary.work_item_id);
        try std.testing.expectEqualStrings(summary.entry_name, work_summary.entry_name);
    }

    var artifact_module = try tensor.createArtifactJobFromPreparedJob(
        allocator,
        staged_state.handle(),
        &prepared,
        .{ .authored_kernel_diagnostic_id = "tensor/program-staged-executable" },
    );
    defer artifact_module.deinit();
    const artifact_fingerprint = artifact_module.fingerprint();
    try std.testing.expectEqual(prepared_kernel_count, artifact_module.kernelCount());
    var artifact_summaries = try artifact_module.copyKernelSummaries(allocator);
    defer artifact_summaries.deinit();
    try std.testing.expectEqual(prepared_kernel_count, artifact_summaries.len());
    for (generated_summaries.items) |generated| {
        const summary = try artifact_summaries.summaryForWork(generated.work_item_id);
        try std.testing.expectEqual(tensor.ArtifactKernelSource.tensor, summary.source);
        try std.testing.expectEqualStrings(generated.entry_name, summary.entry_name);
    }
    try std.testing.expectError(error.InvalidArtifact, artifact_summaries.summaryForWork(std.math.maxInt(usize)));

    const staged_options = tensor.FragmentCompilerOptions{ .authored_kernel_diagnostic_id = "tensor/program-staged-executable" };
    const staged_compiled = try tensor.compileFragmentFromArtifactJob(allocator, artifact_module);
    var staged_fragment = try accy.executable.loadFragment(allocator, staged_state.handle(), staged_compiled, staged_options);
    defer staged_fragment.deinit();

    try std.testing.expect(staged_state.create_count > 0);
    try std.testing.expect(staged_state.load_count > 0);
    try std.testing.expectEqual(prepared_kernel_count, try prepared.generatedKernelCount());
    try std.testing.expectEqual(artifact_fingerprint, artifact_module.fingerprint());
    try expectLoadedFragmentMatchesPrepared(allocator, &prepared, &generated_summaries, &artifact_summaries, staged_fragment, .vulkan_spirv);

    const repeat_options = tensor.FragmentCompilerOptions{ .authored_kernel_diagnostic_id = "tensor/program-staged-executable-repeat" };
    const repeat_compiled = try tensor.compileFragmentFromArtifactJob(allocator, artifact_module);
    var second_staged_fragment = try accy.executable.loadFragment(allocator, staged_state.handle(), repeat_compiled, repeat_options);
    defer second_staged_fragment.deinit();

    try std.testing.expectEqual(prepared_kernel_count, try prepared.generatedKernelCount());
    try std.testing.expectEqual(artifact_fingerprint, artifact_module.fingerprint());
    try expectLoadedFragmentMatchesPrepared(allocator, &prepared, &generated_summaries, &artifact_summaries, second_staged_fragment, .vulkan_spirv);
}

test "tensor Program supports named multi-output bodies" {
    var built = try ElementwiseForward.build(std.testing.allocator);
    defer built.deinit();

    try std.testing.expectEqual(@as(usize, 2), built.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), built.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), ElementwiseForward.out(.product));
    try std.testing.expectEqual(@as(usize, 1), ElementwiseForward.out(.total));
    try types.expectExtents(&.{4}, built.typeOf(built.outputs[ElementwiseForward.out(.product)]));
    try types.expectExtents(&.{}, built.typeOf(built.outputs[ElementwiseForward.out(.total)]));
    try ElementwiseForward.verify(std.testing.allocator);
}

test "tensor Program vmaps named multi-output bodies" {
    var built = try BatchedElementwiseForward.build(std.testing.allocator);
    defer built.deinit();

    try std.testing.expectEqual(@as(usize, 2), built.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), built.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, built.typeOf(built.outputs[BatchedElementwiseForward.out(.product)]));
    try types.expectExtents(&.{8}, built.typeOf(built.outputs[BatchedElementwiseForward.out(.total)]));
    try BatchedElementwiseForward.verify(std.testing.allocator);
}

test "tensor Program names jvp outputs by primal and tangent source output" {
    var built = try ElementwiseForwardJvp.build(std.testing.allocator);
    defer built.deinit();

    try std.testing.expectEqual(@as(usize, 4), built.parameters.len);
    try std.testing.expectEqual(@as(usize, 4), built.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), ElementwiseForwardJvp.out(.{ .primals = .product }));
    try std.testing.expectEqual(@as(usize, 1), ElementwiseForwardJvp.out(.{ .primals = .total }));
    try std.testing.expectEqual(@as(usize, 2), ElementwiseForwardJvp.out(.{ .tangents = .product }));
    try std.testing.expectEqual(@as(usize, 3), ElementwiseForwardJvp.out(.{ .tangents = .total }));
    try types.expectExtents(&.{4}, built.typeOf(built.outputs[ElementwiseForwardJvp.out(.{ .primals = .product })]));
    try types.expectExtents(&.{}, built.typeOf(built.outputs[ElementwiseForwardJvp.out(.{ .primals = .total })]));
    try types.expectExtents(&.{4}, built.typeOf(built.outputs[ElementwiseForwardJvp.out(.{ .tangents = .product })]));
    try types.expectExtents(&.{}, built.typeOf(built.outputs[ElementwiseForwardJvp.out(.{ .tangents = .total })]));
    try ElementwiseForwardJvp.verify(std.testing.allocator);
}

test "tensor Program composes tracing jvp vmap and lowering" {
    var batched = try BatchedElementwiseJvp.build(std.testing.allocator);
    defer batched.deinit();

    try std.testing.expectEqual(@as(usize, 4), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), BatchedElementwiseJvp.out(.primal));
    try std.testing.expectEqual(@as(usize, 1), BatchedElementwiseJvp.out(.tangent));
    try types.expectExtents(&.{8}, batched.typeOf(batched.outputs[BatchedElementwiseJvp.out(.primal)]));
    try types.expectExtents(&.{8}, batched.typeOf(batched.outputs[BatchedElementwiseJvp.out(.tangent)]));
    try BatchedElementwiseJvp.verify(std.testing.allocator);
}

test "tensor Program jvpWith composes user semantics inside jvp" {
    const ordinary_counts = try ElementwiseJvp.interpret(std.testing.allocator, BinaryCounter{});
    const rewritten_counts = try ElementwiseJvpWithGeneratedRewrite.interpret(std.testing.allocator, BinaryCounter{});

    var rewritten = try ElementwiseJvpWithGeneratedRewrite.build(std.testing.allocator);
    defer rewritten.deinit();

    try std.testing.expect(rewritten_counts.mul_count < ordinary_counts.mul_count);
    try std.testing.expect(rewritten_counts.add_count > ordinary_counts.add_count);
    try std.testing.expectEqual(@as(usize, 4), rewritten.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), rewritten.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), ElementwiseJvpWithGeneratedRewrite.out(.primal));
    try std.testing.expectEqual(@as(usize, 1), ElementwiseJvpWithGeneratedRewrite.out(.tangent));
    try types.expectExtents(&.{}, rewritten.typeOf(rewritten.outputs[ElementwiseJvpWithGeneratedRewrite.out(.primal)]));
    try types.expectExtents(&.{}, rewritten.typeOf(rewritten.outputs[ElementwiseJvpWithGeneratedRewrite.out(.tangent)]));
    try ElementwiseJvpWithGeneratedRewrite.verify(std.testing.allocator);

    var batched = try BatchedElementwiseJvpWithGeneratedRewrite.build(std.testing.allocator);
    defer batched.deinit();

    try std.testing.expectEqual(@as(usize, 4), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try types.expectExtents(&.{8}, batched.typeOf(batched.outputs[BatchedElementwiseJvpWithGeneratedRewrite.out(.primal)]));
    try types.expectExtents(&.{8}, batched.typeOf(batched.outputs[BatchedElementwiseJvpWithGeneratedRewrite.out(.tangent)]));
    try BatchedElementwiseJvpWithGeneratedRewrite.verify(std.testing.allocator);
}

test "tensor Program jvpWith accepts custom-call jvp hooks" {
    var built = try CustomDoubleJvp.build(std.testing.allocator);
    defer built.deinit();

    try std.testing.expectEqual(@as(usize, 2), built.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), built.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), CustomDoubleJvp.out(.primal));
    try std.testing.expectEqual(@as(usize, 1), CustomDoubleJvp.out(.tangent));

    var custom_calls: usize = 0;
    for (built.operations) |op| {
        switch (op.kind) {
            .custom_call => |custom| {
                try std.testing.expectEqualStrings(dsl_custom_double_target, custom.target);
                custom_calls += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), custom_calls);
}

test "tensor Program vmapWith composes user semantics inside batch" {
    var rewritten = try BatchedSelectUnmappedWithGeneratedRewrite.build(std.testing.allocator);
    defer rewritten.deinit();

    try std.testing.expectEqual(@as(usize, 2), rewritten.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), rewritten.outputs.len);
    try std.testing.expect(rewritten.isZeroConstant(rewritten.outputs[0]));
    try types.expectExtents(&.{ 8, 4 }, rewritten.typeOf(rewritten.outputs[0]));
    try BatchedSelectUnmappedWithGeneratedRewrite.verify(std.testing.allocator);
}

test "tensor Program derives jvp grad and vmap phase hooks from analysis semantics" {
    const ordinary_jvp_counts = try ElementwiseJvp.interpret(std.testing.allocator, BinaryCounter{});
    const analyzed_jvp_counts = try ElementwiseJvpWithAnalysisRewrite.interpret(std.testing.allocator, BinaryCounter{});

    var analyzed_jvp = try ElementwiseJvpWithAnalysisRewrite.build(std.testing.allocator);
    defer analyzed_jvp.deinit();

    try std.testing.expect(analyzed_jvp_counts.mul_count < ordinary_jvp_counts.mul_count);
    try std.testing.expect(analyzed_jvp_counts.add_count > ordinary_jvp_counts.add_count);
    try std.testing.expectEqual(@as(usize, 4), analyzed_jvp.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), analyzed_jvp.outputs.len);
    try ElementwiseJvpWithAnalysisRewrite.verify(std.testing.allocator);

    var batched_jvp = try BatchedElementwiseJvpWithAnalysisRewrite.build(std.testing.allocator);
    defer batched_jvp.deinit();

    try std.testing.expectEqual(@as(usize, 4), batched_jvp.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched_jvp.outputs.len);
    try types.expectExtents(&.{8}, batched_jvp.typeOf(batched_jvp.outputs[BatchedElementwiseJvpWithAnalysisRewrite.out(.primal)]));
    try types.expectExtents(&.{8}, batched_jvp.typeOf(batched_jvp.outputs[BatchedElementwiseJvpWithAnalysisRewrite.out(.tangent)]));
    try BatchedElementwiseJvpWithAnalysisRewrite.verify(std.testing.allocator);

    const ordinary_gradient_counts = try ElementwiseGradient.interpret(std.testing.allocator, BinaryCounter{});
    const analyzed_gradient_counts = try ElementwiseGradientWithAnalysisRewrite.interpret(std.testing.allocator, BinaryCounter{});

    var analyzed_gradient = try ElementwiseGradientWithAnalysisRewrite.build(std.testing.allocator);
    defer analyzed_gradient.deinit();

    try std.testing.expect(analyzed_gradient_counts.mul_count < ordinary_gradient_counts.mul_count);
    try std.testing.expectEqual(@as(usize, 2), analyzed_gradient.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), analyzed_gradient.outputs.len);
    try ElementwiseGradientWithAnalysisRewrite.verify(std.testing.allocator);

    var batched_gradient = try BatchedElementwiseGradientWithAnalysisRewrite.build(std.testing.allocator);
    defer batched_gradient.deinit();

    try std.testing.expectEqual(@as(usize, 2), batched_gradient.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched_gradient.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, batched_gradient.typeOf(batched_gradient.outputs[BatchedElementwiseGradientWithAnalysisRewrite.out(.x)]));
    try types.expectExtents(&.{ 8, 4 }, batched_gradient.typeOf(batched_gradient.outputs[BatchedElementwiseGradientWithAnalysisRewrite.out(.y)]));
    try BatchedElementwiseGradientWithAnalysisRewrite.verify(std.testing.allocator);

    var analyzed_batch = try BatchedSelectAfterMulWithAnalysisRewrite.build(std.testing.allocator);
    defer analyzed_batch.deinit();

    try std.testing.expectEqual(@as(usize, 3), analyzed_batch.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), analyzed_batch.outputs.len);
    try std.testing.expect(analyzed_batch.isZeroConstant(analyzed_batch.outputs[0]));
    try types.expectExtents(&.{ 8, 4 }, analyzed_batch.typeOf(analyzed_batch.outputs[0]));
    try BatchedSelectAfterMulWithAnalysisRewrite.verify(std.testing.allocator);
}

test "tensor Program composes tracing grad vmap and lowering" {
    var batched = try BatchedElementwiseGradient.build(std.testing.allocator);
    defer batched.deinit();

    try std.testing.expectEqual(@as(usize, 2), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), BatchedElementwiseGradient.out(.x));
    try std.testing.expectEqual(@as(usize, 1), BatchedElementwiseGradient.out(.y));
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[BatchedElementwiseGradient.out(.x)]));
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[BatchedElementwiseGradient.out(.y)]));
    try BatchedElementwiseGradient.verify(std.testing.allocator);
}

test "tensor Program gradWith composes user semantics inside grad" {
    const ordinary_counts = try ElementwiseGradient.interpret(std.testing.allocator, BinaryCounter{});
    const rewritten_counts = try ElementwiseGradientWithGeneratedRewrite.interpret(std.testing.allocator, BinaryCounter{});

    var rewritten = try ElementwiseGradientWithGeneratedRewrite.build(std.testing.allocator);
    defer rewritten.deinit();

    try std.testing.expect(rewritten_counts.mul_count < ordinary_counts.mul_count);
    try std.testing.expectEqual(@as(usize, 2), rewritten.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), rewritten.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), ElementwiseGradientWithGeneratedRewrite.out(.x));
    try std.testing.expectEqual(@as(usize, 1), ElementwiseGradientWithGeneratedRewrite.out(.y));
    try types.expectExtents(&.{4}, rewritten.typeOf(rewritten.outputs[ElementwiseGradientWithGeneratedRewrite.out(.x)]));
    try types.expectExtents(&.{4}, rewritten.typeOf(rewritten.outputs[ElementwiseGradientWithGeneratedRewrite.out(.y)]));
    try ElementwiseGradientWithGeneratedRewrite.verify(std.testing.allocator);

    var batched = try BatchedElementwiseGradientWithGeneratedRewrite.build(std.testing.allocator);
    defer batched.deinit();

    try std.testing.expectEqual(@as(usize, 2), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[BatchedElementwiseGradientWithGeneratedRewrite.out(.x)]));
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[BatchedElementwiseGradientWithGeneratedRewrite.out(.y)]));
    try BatchedElementwiseGradientWithGeneratedRewrite.verify(std.testing.allocator);
}
