const std = @import("std");
const gpu = @import("gpu");
const accy = @import("../root.zig");
const autodiff = @import("autodiff.zig");
const emit = @import("emit.zig");
const execute = @import("execute.zig");
const gating = @import("accy_validation_gating");
const hook = @import("hook.zig");
const interpret_mod = @import("interpret/root.zig");
const lower = @import("lower.zig");
const program_mod = @import("program.zig");
const reverse = @import("reverse.zig");
const trace = @import("trace/root.zig");
const unroll = @import("unroll.zig");
const types = @import("type/root.zig");

pub const Options = autodiff.LinearizeOptions;

pub fn grad(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
) !program_mod.Program {
    try validate(source, options);

    var linearized = try autodiff.linearize(allocator, source, options);
    defer linearized.deinit();

    var transposed = try reverse.pullback(allocator, &linearized, .{});
    defer transposed.deinit();

    return seedGradient(allocator, &transposed);
}

pub fn valueAndGrad(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
) !program_mod.Program {
    try validate(source, options);

    var linearized = try autodiff.linearize(allocator, source, options);
    defer linearized.deinit();

    var transposed = try reverse.pullback(allocator, &linearized, .{ .keep_primal_outputs = true });
    defer transposed.deinit();

    return seedGradient(allocator, &transposed);
}

pub fn gradWith(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
    hooks: anytype,
) !program_mod.Program {
    try validate(source, options);

    var linearized = try autodiff.linearizeWith(allocator, source, options, hooks);
    defer linearized.deinit();

    var builder = try trace.Builder.init(allocator, linearized.program.name);
    errdefer builder.deinit();

    const graph = interpret_mod.Graph{ .builder = &builder };
    const pullback_initial = hook.attach("pullback", hooks, graph);
    var transposed = if (comptime hook.has(@TypeOf(hooks), "vjp"))
        try reverse.pullbackWithRules(allocator, &linearized, .{}, pullback_initial, hooks.vjp)
    else
        try reverse.pullbackWith(allocator, &linearized, .{}, pullback_initial);
    defer transposed.deinit();

    return seedGradientWith(allocator, &transposed, hooks);
}

pub fn gradWithRules(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
    jvp_rules: anytype,
    vjp_rules: anytype,
) !program_mod.Program {
    if (source.containsScan()) {
        var expanded = try unroll.apply(allocator, source);
        defer expanded.deinit();
        return gradWithRules(allocator, &expanded, options, jvp_rules, vjp_rules);
    }

    try validate(source, options);

    var linearize_builder = try trace.Builder.init(allocator, source.name);
    errdefer linearize_builder.deinit();
    const linearize_graph = interpret_mod.Graph{ .builder = &linearize_builder };
    const linear = autodiff.semantics(source, linearize_graph, options);
    var linearized = try interpret_mod.run(
        allocator,
        source,
        interpret_mod.layer(autodiff.Dual, linear, jvp_rules),
    );
    defer linearized.deinit();

    var pullback_builder = try trace.Builder.init(allocator, linearized.program.name);
    errdefer pullback_builder.deinit();
    const pullback_graph = interpret_mod.Graph{ .builder = &pullback_builder };
    var transposed = try reverse.pullbackWithRules(allocator, &linearized, .{}, pullback_graph, vjp_rules);
    defer transposed.deinit();

    return seedGradient(allocator, &transposed);
}

pub fn interpret(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    return interpretWith(allocator, source, options, .{}, initial);
}

pub fn interpretWith(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    options: Options,
    hooks: anytype,
    initial: anytype,
) !interpret_mod.result(@TypeOf(initial)) {
    if (comptime @hasDecl(@TypeOf(initial), "attach")) {
        try validate(source, options);

        var linearized = try autodiff.linearizeWith(allocator, source, options, hooks);
        defer linearized.deinit();

        var pullback_builder = try trace.Builder.init(allocator, linearized.program.name);
        errdefer pullback_builder.deinit();

        const pullback_graph = interpret_mod.Graph{ .builder = &pullback_builder };
        var transposed = try reverse.pullbackWith(allocator, &linearized, .{}, hook.attach("pullback", hooks, pullback_graph));
        defer transposed.deinit();

        var builder = try trace.Builder.init(allocator, transposed.program.name);
        errdefer builder.deinit();

        const graph = interpret_mod.Graph{ .builder = &builder };
        return seedGradientInto(allocator, &transposed, hook.attach("seed", hooks, initial.attach(graph)));
    }

    var differentiated = try gradWith(allocator, source, options, hooks);
    defer differentiated.deinit();

    return interpret_mod.run(allocator, &differentiated, initial);
}

pub fn validate(source: *const program_mod.Program, options: Options) !void {
    try validateScalarOutput(source);
    try autodiff.validate(source, options);
}

fn seedGradient(allocator: std.mem.Allocator, transposed: *const reverse.Pullback) !program_mod.Program {
    var builder = try trace.Builder.init(allocator, transposed.program.name);
    errdefer builder.deinit();

    const graph = interpret_mod.Graph{ .builder = &builder };
    return seedGradientInto(allocator, transposed, graph);
}

fn seedGradientWith(allocator: std.mem.Allocator, transposed: *const reverse.Pullback, hooks: anytype) !program_mod.Program {
    var builder = try trace.Builder.init(allocator, transposed.program.name);
    errdefer builder.deinit();

    const graph = interpret_mod.Graph{ .builder = &builder };
    return seedGradientInto(allocator, transposed, hook.attach("seed", hooks, graph));
}

fn seedGradientInto(allocator: std.mem.Allocator, transposed: *const reverse.Pullback, initial: anytype) !SeedSemantics(@TypeOf(initial)).Result {
    if (transposed.seed_parameter_count != 1) return error.GradientRequiresScalarOutput;

    return interpret_mod.run(allocator, &transposed.program, SeedSemantics(@TypeOf(initial)){
        .next = initial,
        .seed_parameter = transposed.primal_parameter_count,
    });
}

fn SeedSemantics(comptime Next: type) type {
    return struct {
        next: Next,
        seed_parameter: usize,

        pub const Value: type = trace.Value;
        pub const Result: type = Next.Result;

        pub fn operation(self: *@This(), step: *interpret_mod.Step(Value)) !Value {
            var buffer: [program_mod.max_operation_operands]Value = undefined;
            return self.bind(step.op, interpret_mod.arguments(Value, step.op, step.values, &buffer));
        }

        pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const Value) !Value {
            switch (op.kind) {
                .parameter => |parameter| {
                    if (parameter.index == self.seed_parameter) return emit.fullFloat(self, op.result, 1.0);
                },
                else => {},
            }
            return self.next.bind(op, args);
        }

        pub fn finish(self: *@This(), outputs: []const Value) !Result {
            return self.next.finish(outputs);
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.next.builderHandle();
        }
    };
}

fn validateScalarOutput(source: *const program_mod.Program) !void {
    if (source.outputs.len != 1) return error.GradientRequiresScalarOutput;
    if (source.typeOf(source.outputs[0]).rank() != 0) return error.GradientRequiresScalarOutput;
}

fn elementwiseLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].mul(args[1]);
    return try product.sum(.lane);
}

fn embeddingLookupLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const gathered = try args[0].gather(args[1], .vocab);
    return try gathered.sum(.{ .token, .channel });
}

test "tensor grad derives scalar-output gradients through pullback" {
    var source = try trace.define(std.testing.allocator, "grad_elementwise", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, elementwiseLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[1]));
}

test "tensor grad transposes gather with scatter add" {
    var source = try trace.define(std.testing.allocator, "grad_embedding_lookup", &.{
        types.spec(.f32, .{ .vocab = 16, .channel = 4 }),
        types.spec(.i32, .{ .token = 3 }),
    }, embeddingLookupLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.parameters.len);
    try types.expectExtents(&.{ 16, 4 }, differentiated.typeOf(differentiated.parameters[0]));
    try types.expectExtents(&.{3}, differentiated.typeOf(differentiated.parameters[1]));
    try std.testing.expectEqual(@as(usize, 1), differentiated.outputs.len);
    try types.expectExtents(&.{ 16, 4 }, differentiated.typeOf(differentiated.outputs[0]));

    var scatter_adds: usize = 0;
    for (differentiated.operations) |op| {
        switch (op.kind) {
            .scatter_add => scatter_adds += 1,
            else => {},
        }
    }
    try std.testing.expect(scatter_adds >= 1);
}

const GeneratedGradCounts = struct {
    constant: usize = 0,
    mul: usize = 0,
    broadcast_in_dim: usize = 0,
};

const GeneratedGradCounter = struct {
    counts: *GeneratedGradCounts,

    pub fn constant(self: *@This(), ctx: anytype) !trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) self.counts.constant += 1;
        return ctx.default();
    }

    pub fn mul(self: *@This(), ctx: anytype) !trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) self.counts.mul += 1;
        return ctx.default();
    }

    pub fn broadcastInDim(self: *@This(), ctx: anytype) !trace.Value {
        if (ctx.op.id.index == program_mod.synthetic_id.index) self.counts.broadcast_in_dim += 1;
        return ctx.default();
    }
};

test "tensor gradWith routes generated ops through user semantics" {
    var source = try trace.define(std.testing.allocator, "grad_with_elementwise", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, elementwiseLoss);
    defer source.deinit();

    var counts = GeneratedGradCounts{};
    var seed_counts = GeneratedGradCounts{};
    var differentiated = try gradWith(
        std.testing.allocator,
        &source,
        .{ .wrt = &.{ 0, 1 } },
        .{
            .linearize = interpret_mod.bind(GeneratedGradCounter{ .counts = &counts }),
            .pullback = interpret_mod.bind(GeneratedGradCounter{ .counts = &counts }),
            .seed = interpret_mod.bind(GeneratedGradCounter{ .counts = &seed_counts }),
        },
    );
    defer differentiated.deinit();

    try std.testing.expect(counts.mul >= 4);
    try std.testing.expect(counts.broadcast_in_dim >= 1);
    try std.testing.expectEqual(@as(usize, 1), seed_counts.constant);
    try std.testing.expectEqual(@as(usize, 2), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[1]));
}

fn reluLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const zero = try builder.scalar(.f32, 0.0);
    const rectified = try args[0].max(zero);
    return try rectified.sum(.lane);
}

test "tensor grad differentiates relu through select" {
    var source = try trace.define(std.testing.allocator, "grad_relu", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, reluLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
}

fn cubeLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const three = try builder.scalar(.f32, 3.0);
    const cubed = try args[0].pow(three);
    return try cubed.sum(.lane);
}

test "tensor grad differentiates pow with inactive exponent" {
    var source = try trace.define(std.testing.allocator, "grad_cube", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, cubeLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));

    var logs: usize = 0;
    for (differentiated.operations) |op| {
        switch (op.kind) {
            .unary => |unary_op| {
                if (unary_op.op == .log) logs += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), logs);
}

fn plainSumLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].sum(.lane);
}

test "tensor grad preserves source parameters when no residuals are needed" {
    var source = try trace.define(std.testing.allocator, "grad_plain_sum", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, plainSumLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), differentiated.parameters.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.parameters[0]));
    try std.testing.expectEqual(@as(usize, 1), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));

    const x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var gradient_out = @as([4]f32, @splat(0));
    const outputs = [_][]u8{std.mem.sliceAsBytes(gradient_out[0..])};
    try execute.runCpu(std.testing.allocator, &differentiated, &.{std.mem.sliceAsBytes(x[0..])}, outputs[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 1.0, 1.0, 1.0 }, gradient_out[0..]);
}

test "tensor grad executes with an unused parameter on native CPU" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    var source = try trace.define(std.testing.allocator, "grad_unused_parameter_cpu", &.{
        types.spec(.f32, .{ .vocab = 4, .channel = 2 }),
        types.spec(.i32, .{ .token = 3 }),
    }, embeddingLookupLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.parameters.len);
    try types.expectExtents(&.{ 4, 2 }, differentiated.typeOf(differentiated.parameters[0]));
    try types.expectExtents(&.{3}, differentiated.typeOf(differentiated.parameters[1]));

    const table = [_]f32{ 0.5, -1.0, 2.0, 0.25, 3.0, -2.0, 1.5, 0.75 };
    const indices = [_]i32{ 2, 0, 2 };
    var table_grad = @as([8]f32, @splat(-1.0));
    const outputs = [_][]u8{std.mem.sliceAsBytes(table_grad[0..])};
    try execute.runCpu(std.testing.allocator, &differentiated, &.{
        std.mem.sliceAsBytes(table[0..]),
        std.mem.sliceAsBytes(indices[0..]),
    }, outputs[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 1.0, 0.0, 0.0, 2.0, 2.0, 0.0, 0.0 }, table_grad[0..]);
}

test "tensor valueAndGrad emits the loss ahead of the gradients" {
    var source = try trace.define(std.testing.allocator, "value_and_grad_elementwise", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, elementwiseLoss);
    defer source.deinit();

    var combined = try valueAndGrad(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer combined.deinit();

    try std.testing.expectEqual(@as(usize, 2), combined.parameters.len);
    try types.expectExtents(&.{4}, combined.typeOf(combined.parameters[0]));
    try types.expectExtents(&.{4}, combined.typeOf(combined.parameters[1]));
    try std.testing.expectEqual(@as(usize, 3), combined.outputs.len);
    try types.expectExtents(&.{}, combined.typeOf(combined.outputs[0]));
    try types.expectExtents(&.{4}, combined.typeOf(combined.outputs[1]));
    try types.expectExtents(&.{4}, combined.typeOf(combined.outputs[2]));
}

test "tensor valueAndGrad computes the loss and gradients in one launch" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    var source = try trace.define(std.testing.allocator, "value_and_grad_numeric", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, elementwiseLoss);
    defer source.deinit();

    var combined = try valueAndGrad(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer combined.deinit();

    const x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const y = [_]f32{ 0.5, -1.0, 2.0, 0.25 };
    var loss_value: f32 = 0;
    var x_grad = @as([4]f32, @splat(0));
    var y_grad = @as([4]f32, @splat(0));
    const outputs = [_][]u8{
        std.mem.asBytes(&loss_value),
        std.mem.sliceAsBytes(x_grad[0..]),
        std.mem.sliceAsBytes(y_grad[0..]),
    };
    try execute.runCpu(std.testing.allocator, &combined, &.{
        std.mem.sliceAsBytes(x[0..]),
        std.mem.sliceAsBytes(y[0..]),
    }, outputs[0..]);

    try std.testing.expectApproxEqAbs(@as(f32, 5.5), loss_value, 0.000001);
    try std.testing.expectEqualSlices(f32, y[0..], x_grad[0..]);
    try std.testing.expectEqualSlices(f32, x[0..], y_grad[0..]);
}

fn maxLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const init = try builder.scalar(.f32, -3.4e38);
    return try args[0].reduce(init, .max, .lane);
}

fn maxLossWithInitParam(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].reduce(args[1], .max, .lane);
}

test "tensor grad differentiates reduce max" {
    var source = try trace.define(std.testing.allocator, "grad_reduce_max", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, maxLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
}

test "tensor grad differentiates reduce max init parameter" {
    var source = try trace.define(std.testing.allocator, "grad_reduce_max_init", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{}),
    }, maxLossWithInitParam);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
    try types.expectExtents(&.{}, differentiated.typeOf(differentiated.outputs[1]));
}

fn absLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = builder;
    const magnitude = try args[0].abs();
    return try magnitude.sum(.lane);
}

test "tensor grad differentiates abs through the sign mask" {
    var source = try trace.define(std.testing.allocator, "grad_abs", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, absLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
}

fn tanLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = builder;
    const slope = try args[0].tan();
    return try slope.sum(.lane);
}

test "tensor grad differentiates tan" {
    var source = try trace.define(std.testing.allocator, "grad_tan", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, tanLoss);
    defer source.deinit();

    var differentiated = try grad(std.testing.allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
}

test "tensor grad requires scalar output" {
    var source = try trace.define(std.testing.allocator, "grad_vector", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, struct {
        fn body(_: *trace.Builder, args: []const trace.Value) !trace.Value {
            return try args[0].mul(args[1]);
        }
    }.body);
    defer source.deinit();

    try std.testing.expectError(error.GradientRequiresScalarOutput, grad(std.testing.allocator, &source, .{ .wrt = &.{0} }));
}

fn batchedDotGeneralLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].contract(args[1], .k);
    const weighted = try product.mul(args[2]);
    return try weighted.sum(.{ .b, .m, .n });
}

test "tensor grad executes batched dot_general gradients on native CPU" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const batch = 2;
    const m = 2;
    const k = 3;
    const n = 2;

    var source = try trace.define(allocator, "grad_batched_dot_general_cpu", &.{
        types.spec(.f32, .{ .b = batch, .m = m, .k = k }),
        types.spec(.f32, .{ .b = batch, .k = k, .n = n }),
        types.spec(.f32, .{ .b = batch, .m = m, .n = n }),
    }, batchedDotGeneralLoss);
    defer source.deinit();

    var differentiated = try grad(allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const options = lower.FragmentCompilerOptions{
        .artifact_format = .cpu_object,
    };
    const compiled = try lower.compileFragment(allocator, state.handle(), &differentiated, options);
    var fragment = try accy.executable.loadFragment(allocator, state.handle(), compiled, options);
    defer fragment.deinit();

    var lhs = [_]f32{
        1.0,  2.0,  3.0,
        4.0,  5.0,  6.0,
        -1.0, 0.5,  2.0,
        3.0,  -2.0, 1.0,
    };
    var rhs = [_]f32{
        7.0,  8.0,
        9.0,  10.0,
        11.0, 12.0,
        0.25, -1.0,
        2.0,  -3.0,
        4.0,  0.5,
    };
    var weights = [_]f32{
        1.0,  -0.5,
        0.25, 2.0,
        -1.5, 0.75,
        3.0,  -2.0,
    };
    var lhs_grad = @as([(batch * m * k)]f32, @splat(0.0));
    var rhs_grad = @as([(batch * k * n)]f32, @splat(0.0));
    var outputs = [_][]u8{
        std.mem.sliceAsBytes(lhs_grad[0..]),
        std.mem.sliceAsBytes(rhs_grad[0..]),
    };
    try accy.executable.invoke(fragment, allocator, allocator, &.{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
        std.mem.sliceAsBytes(weights[0..]),
    }, &outputs);

    var expected_lhs_grad = @as([(batch * m * k)]f32, @splat(0.0));
    var expected_rhs_grad = @as([(batch * k * n)]f32, @splat(0.0));
    for (0..batch) |b| {
        for (0..m) |row| {
            for (0..k) |inner| {
                var sum: f32 = 0.0;
                for (0..n) |col| {
                    sum += weights[(b * m + row) * n + col] * rhs[(b * k + inner) * n + col];
                }
                expected_lhs_grad[(b * m + row) * k + inner] = sum;
            }
        }
        for (0..k) |inner| {
            for (0..n) |col| {
                var sum: f32 = 0.0;
                for (0..m) |row| {
                    sum += lhs[(b * m + row) * k + inner] * weights[(b * m + row) * n + col];
                }
                expected_rhs_grad[(b * k + inner) * n + col] = sum;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 2), fragment.outputCount());
    for (expected_lhs_grad, lhs_grad) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.000001);
    }
    for (expected_rhs_grad, rhs_grad) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.000001);
    }
}

fn transposedProjectionLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].builder.dotGeneralOp(args[0], args[1], &.{0}, &.{0}, &.{}, &.{});
    return try product.sum(.{ .m, .n });
}

test "tensor grad executes noncanonical dot_general gradients on native CPU" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;

    var source = try trace.define(allocator, "grad_noncanonical_dot_cpu", &.{
        types.spec(.f32, .{ .k = 3, .m = 2 }),
        types.spec(.f32, .{ .k = 3, .n = 2 }),
    }, transposedProjectionLoss);
    defer source.deinit();

    var differentiated = try grad(allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    const lhs = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    const rhs = [_]f32{ 0.5, -1.0, 2.0, 0.25, -0.75, 1.5 };
    var lhs_grad = @as([6]f32, @splat(0.0));
    var rhs_grad = @as([6]f32, @splat(0.0));
    var outputs = [_][]u8{
        std.mem.sliceAsBytes(lhs_grad[0..]),
        std.mem.sliceAsBytes(rhs_grad[0..]),
    };
    try execute.runCpu(allocator, &differentiated, &.{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
    }, outputs[0..]);

    for (0..3) |k| {
        const rhs_row_sum = rhs[k * 2] + rhs[k * 2 + 1];
        try std.testing.expectApproxEqAbs(rhs_row_sum, lhs_grad[k * 2], 0.000001);
        try std.testing.expectApproxEqAbs(rhs_row_sum, lhs_grad[k * 2 + 1], 0.000001);
        const lhs_row_sum = lhs[k * 2] + lhs[k * 2 + 1];
        try std.testing.expectApproxEqAbs(lhs_row_sum, rhs_grad[k * 2], 0.000001);
        try std.testing.expectApproxEqAbs(lhs_row_sum, rhs_grad[k * 2 + 1], 0.000001);
    }
}

const attention_tokens = 4;
const attention_channels = 3;
const attention_mask_penalty: f32 = -30.0;

fn causalAttentionLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const queries = args[0];
    const keys = args[1];
    const values = args[2];
    const mask = args[3];

    const scores = try queries.contract(try keys.rename(.token, .key), .channel);
    const masked = try scores.add(mask);
    const centered = try masked.sub(try masked.max(.key));
    const weights = try centered.exp();
    const probs = try weights.div(try weights.sum(.key));
    const mixed = try probs.contract(try values.rename(.token, .key), .key);
    const squared = try mixed.mul(mixed);
    return try squared.sum(.{ .token, .channel });
}

fn attentionNoise(seed: usize) f32 {
    var state: u64 = @as(u64, @intCast(seed)) +% 0x9e3779b97f4a7c15;
    state = (state ^ (state >> 30)) *% 0xbf58476d1ce4e5b9;
    state = (state ^ (state >> 27)) *% 0x94d049bb133111eb;
    state ^= state >> 31;
    const unit = @as(f32, @floatFromInt(state & 0xffff)) / 65535.0;
    return 2.0 * unit - 1.0;
}

test "tensor valueAndGrad matches finite differences through causal attention" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const element_count = attention_tokens * attention_channels;

    var source = try trace.define(allocator, "grad_causal_attention_fd", &.{
        types.spec(.f32, .{ .token = attention_tokens, .channel = attention_channels }),
        types.spec(.f32, .{ .token = attention_tokens, .channel = attention_channels }),
        types.spec(.f32, .{ .token = attention_tokens, .channel = attention_channels }),
        types.spec(.f32, .{ .token = attention_tokens, .key = attention_tokens }),
    }, causalAttentionLoss);
    defer source.deinit();

    var combined = try valueAndGrad(allocator, &source, .{ .wrt = &.{ 0, 1, 2 } });
    defer combined.deinit();

    var inputs: [3][element_count]f32 = undefined;
    for (&inputs, 0..) |*tensor_input, tensor_index| {
        for (tensor_input, 0..) |*slot, element_index| {
            slot.* = attentionNoise(tensor_index * 1000 + element_index);
        }
    }
    var mask: [attention_tokens * attention_tokens]f32 = undefined;
    for (0..attention_tokens) |row| {
        for (0..attention_tokens) |col| {
            mask[row * attention_tokens + col] = if (col <= row) 0.0 else attention_mask_penalty;
        }
    }

    var loss_value: f32 = 0.0;
    var gradients: [3][element_count]f32 = @splat(@splat(0.0));
    var grad_outputs = [_][]u8{
        std.mem.asBytes(&loss_value),
        std.mem.sliceAsBytes(gradients[0][0..]),
        std.mem.sliceAsBytes(gradients[1][0..]),
        std.mem.sliceAsBytes(gradients[2][0..]),
    };
    try execute.runCpu(allocator, &combined, &.{
        std.mem.sliceAsBytes(inputs[0][0..]),
        std.mem.sliceAsBytes(inputs[1][0..]),
        std.mem.sliceAsBytes(inputs[2][0..]),
        std.mem.sliceAsBytes(mask[0..]),
    }, grad_outputs[0..]);

    var loss_executor = try execute.Cpu.init(allocator, &source);
    defer loss_executor.deinit();

    const step: f32 = 0.01;
    for (0..3) |tensor_index| {
        for (0..element_count) |element_index| {
            var probes: [2]f32 = undefined;
            for (&probes, [_]f32{ step, -step }) |*probe, offset| {
                var perturbed = inputs;
                perturbed[tensor_index][element_index] += offset;
                var probe_loss: f32 = 0.0;
                var probe_outputs = [_][]u8{std.mem.asBytes(&probe_loss)};
                try loss_executor.launch(allocator, &.{
                    std.mem.sliceAsBytes(perturbed[0][0..]),
                    std.mem.sliceAsBytes(perturbed[1][0..]),
                    std.mem.sliceAsBytes(perturbed[2][0..]),
                    std.mem.sliceAsBytes(mask[0..]),
                }, probe_outputs[0..]);
                probe.* = probe_loss;
            }
            const finite_difference = (probes[0] - probes[1]) / (2.0 * step);
            const analytic = gradients[tensor_index][element_index];
            const tolerance = 0.002 + 0.02 * @abs(finite_difference);
            try std.testing.expectApproxEqAbs(finite_difference, analytic, tolerance);
        }
    }
}

const custom_double_target = "accy.custom.double";

fn doubleSumLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const doubled = try builder.customCall(custom_double_target, 1, &.{args[0]}, args[0].ty);
    return try doubled.sum(.lane);
}

const DoubleJvpRule = struct {
    applied: *usize,

    pub fn bind(self: *@This(), ctx: anytype) !autodiff.Dual {
        switch (ctx.op.kind) {
            .custom_call => |custom| {
                if (std.mem.eql(u8, custom.target, custom_double_target)) {
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

const DoubleVjpRule = struct {
    applied: *usize,

    pub fn customCall(self: *@This(), ctx: anytype) !void {
        self.applied.* += 1;
        if (!ctx.operandIsActive(0)) return;
        const builder = ctx.builderHandle();
        const contribution = try builder.customCall(
            ctx.custom.target,
            ctx.custom.version,
            &.{ctx.cotangent},
            ctx.cotangent.ty,
        );
        try ctx.contribute(0, contribution);
    }
};

test "tensor gradWithRules differentiates custom calls through both contracts" {
    var source = try trace.define(std.testing.allocator, "grad_custom_double", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doubleSumLoss);
    defer source.deinit();

    var jvp_applied: usize = 0;
    var vjp_applied: usize = 0;
    var differentiated = try gradWithRules(
        std.testing.allocator,
        &source,
        .{ .wrt = &.{0} },
        DoubleJvpRule{ .applied = &jvp_applied },
        DoubleVjpRule{ .applied = &vjp_applied },
    );
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), jvp_applied);
    try std.testing.expectEqual(@as(usize, 1), vjp_applied);
    try std.testing.expectEqual(@as(usize, 1), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));

    var custom_calls: usize = 0;
    for (differentiated.operations) |op| {
        switch (op.kind) {
            .custom_call => |custom| {
                try std.testing.expectEqualStrings(custom_double_target, custom.target);
                custom_calls += 1;
            },
            else => {},
        }
    }
    try std.testing.expect(custom_calls >= 1);
}

test "tensor gradWith accepts custom-call contracts through public hooks" {
    var source = try trace.define(std.testing.allocator, "grad_public_custom_double", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doubleSumLoss);
    defer source.deinit();

    var jvp_applied: usize = 0;
    var vjp_applied: usize = 0;
    var differentiated = try gradWith(
        std.testing.allocator,
        &source,
        .{ .wrt = &.{0} },
        .{
            .jvp = interpret_mod.bind(DoubleJvpRule{ .applied = &jvp_applied }),
            .vjp = DoubleVjpRule{ .applied = &vjp_applied },
        },
    );
    defer differentiated.deinit();

    try std.testing.expectEqual(@as(usize, 1), jvp_applied);
    try std.testing.expectEqual(@as(usize, 1), vjp_applied);
    try std.testing.expectEqual(@as(usize, 1), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), differentiated.outputs.len);
    try types.expectExtents(&.{4}, differentiated.typeOf(differentiated.outputs[0]));
}

test "tensor gradWithRules still rejects missing contracts by name" {
    var source = try trace.define(std.testing.allocator, "grad_custom_opaque", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doubleSumLoss);
    defer source.deinit();

    var vjp_applied: usize = 0;
    try std.testing.expectError(error.CustomCallRequiresJvpContract, gradWithRules(
        std.testing.allocator,
        &source,
        .{ .wrt = &.{0} },
        .{},
        DoubleVjpRule{ .applied = &vjp_applied },
    ));

    var jvp_applied: usize = 0;
    try std.testing.expectError(error.CustomCallRequiresVjpContract, gradWithRules(
        std.testing.allocator,
        &source,
        .{ .wrt = &.{0} },
        DoubleJvpRule{ .applied = &jvp_applied },
        .{},
    ));
}

fn customDoubleKernel() type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D("e", 4, args, struct {
                fn each(inner: anytype, index: accy.kernel.Index1D, each_args: anytype) !void {
                    const x = try each_args.param(.x).load(inner, index);
                    const doubled = try x.add(inner, x);
                    try each_args.param(.dst).store(inner, doubled, index);
                }
            }.each);
        }
    };
    return accy.kernel.logical.Program(.{
        .name = "accy_custom_double_4_f32",
        .parameters = .{
            .dst = accy.kernel.dynamicBuffer(.f32),
            .x = accy.kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(accy.kernel.logical.schedule.threadBlocks(.{ .x = 4 }));
}

test "tensor valueAndGrad executes loss and gradients in one launch on live CUDA" {
    const allocator = std.testing.allocator;

    try gating.skipIfBuildFlagDisabled(.cuda);
    if (!gpu.cuda.platformSupported()) return gating.skip(.cuda, .unsupported_platform);
    var state = gpu.cuda.State.initDevice(allocator, 0) catch |err| switch (err) {
        error.RuntimeUnavailable => return gating.skip(.cuda, .cuda_device_missing),
        else => return err,
    };
    defer state.deinit();
    const handle = state.handle();

    var source = try trace.define(allocator, "live_value_and_grad", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, elementwiseLoss);
    defer source.deinit();

    var combined = try valueAndGrad(allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer combined.deinit();

    const compiled = try lower.compileFragment(allocator, handle, &combined, .{});
    var fragment = try accy.executable.loadFragment(allocator, handle, compiled, .{});
    defer fragment.deinit();

    var x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var y = [_]f32{ 0.5, -1.0, 2.0, 0.25 };
    var loss_value: f32 = -1.0;
    var x_grad = @as([4]f32, @splat(-1.0));
    var y_grad = @as([4]f32, @splat(-1.0));
    var outputs = [_][]u8{
        std.mem.asBytes(&loss_value),
        std.mem.sliceAsBytes(x_grad[0..]),
        std.mem.sliceAsBytes(y_grad[0..]),
    };
    try accy.executable.invoke(fragment, allocator, allocator, &.{
        std.mem.sliceAsBytes(x[0..]),
        std.mem.sliceAsBytes(y[0..]),
    }, &outputs);

    try std.testing.expectApproxEqAbs(@as(f32, 5.5), loss_value, 0.000001);
    try std.testing.expectEqualSlices(f32, y[0..], x_grad[0..]);
    try std.testing.expectEqualSlices(f32, x[0..], y_grad[0..]);
}

test "tensor gradWith custom-call gradient executes on live CUDA" {
    const allocator = std.testing.allocator;

    try gating.skipIfBuildFlagDisabled(.cuda);
    if (!gpu.cuda.platformSupported()) return gating.skip(.cuda, .unsupported_platform);
    var state = gpu.cuda.State.initDevice(allocator, 0) catch |err| switch (err) {
        error.RuntimeUnavailable => return gating.skip(.cuda, .cuda_device_missing),
        else => return err,
    };
    defer state.deinit();
    const handle = state.handle();

    var call_artifact = try customDoubleKernel().createKernelCallArtifact(
        allocator,
        accy.kernel.Limits.testing,
        handle,
        .{
            .target = custom_double_target,
            .version = 1,
            .format = .cuda_ptx,
        },
    );
    defer call_artifact.deinit();
    const registry = call_artifact.registry();

    var source = try trace.define(allocator, "live_grad_custom_double", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, doubleSumLoss);
    defer source.deinit();

    var jvp_applied: usize = 0;
    var vjp_applied: usize = 0;
    var differentiated = try gradWith(
        allocator,
        &source,
        .{ .wrt = &.{0} },
        .{
            .jvp = interpret_mod.bind(DoubleJvpRule{ .applied = &jvp_applied }),
            .vjp = DoubleVjpRule{ .applied = &vjp_applied },
        },
    );
    defer differentiated.deinit();

    const options = lower.FragmentCompilerOptions{
        .kernel_call_registry = &registry,
    };
    const compiled = try lower.compileFragment(allocator, handle, &differentiated, options);
    var fragment = try accy.executable.loadFragment(allocator, handle, compiled, options);
    defer fragment.deinit();

    var x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const input_bytes = [_][]const u8{std.mem.sliceAsBytes(x[0..])};
    const bindings = try accy.executable.prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();
    try bindings.launchWithOptions(allocator, .{});

    var gradient = @as([4]f32, @splat(-1.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(gradient[0..]));

    for (gradient) |value| {
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), value, 0.000001);
    }
}
