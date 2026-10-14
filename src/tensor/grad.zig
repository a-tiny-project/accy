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
    var transposed = try reverse.pullbackWithRules(
        allocator,
        &linearized,
        .{},
        pullback_graph,
        vjp_rules,
    );
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
        var transposed = try reverse.pullbackWith(
            allocator,
            &linearized,
            .{},
            hook.attach("pullback", hooks, pullback_graph),
        );
        defer transposed.deinit();

        var builder = try trace.Builder.init(allocator, transposed.program.name);
        errdefer builder.deinit();

        const graph = interpret_mod.Graph{ .builder = &builder };
        return seedGradientInto(
            allocator,
            &transposed,
            hook.attach("seed", hooks, initial.attach(graph)),
        );
    }

    var differentiated = try gradWith(allocator, source, options, hooks);
    defer differentiated.deinit();

    return interpret_mod.run(allocator, &differentiated, initial);
}

pub fn validate(source: *const program_mod.Program, options: Options) !void {
    try validateScalarOutput(source);
    try autodiff.validate(source, options);
}

fn seedGradient(
    allocator: std.mem.Allocator,
    transposed: *const reverse.Pullback,
) !program_mod.Program {
    var builder = try trace.Builder.init(allocator, transposed.program.name);
    errdefer builder.deinit();

    const graph = interpret_mod.Graph{ .builder = &builder };
    return seedGradientInto(allocator, transposed, graph);
}

fn seedGradientWith(
    allocator: std.mem.Allocator,
    transposed: *const reverse.Pullback,
    hooks: anytype,
) !program_mod.Program {
    var builder = try trace.Builder.init(allocator, transposed.program.name);
    errdefer builder.deinit();

    const graph = interpret_mod.Graph{ .builder = &builder };
    return seedGradientInto(allocator, transposed, hook.attach("seed", hooks, graph));
}

fn seedGradientInto(
    allocator: std.mem.Allocator,
    transposed: *const reverse.Pullback,
    initial: anytype,
) !SeedSemantics(@TypeOf(initial)).Result {
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
            return self.bind(
                step.op,
                interpret_mod.arguments(Value, step.op, step.values, &buffer),
            );
        }

        pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const Value) !Value {
            switch (op.kind) {
                .parameter => |parameter| {
                    if (parameter.index == self.seed_parameter) {
                        return emit.fullFloat(self, op.result, 1.0);
                    }
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

fn reluLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const zero = try builder.scalar(.f32, 0.0);
    const rectified = try args[0].max(zero);
    return try rectified.sum(.lane);
}

fn cubeLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const three = try builder.scalar(.f32, 3.0);
    const cubed = try args[0].pow(three);
    return try cubed.sum(.lane);
}

fn plainSumLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].sum(.lane);
}

fn maxLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    const init = try builder.scalar(.f32, -3.4e38);
    return try args[0].reduce(init, .max, .lane);
}

fn maxLossWithInitParam(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].reduce(args[1], .max, .lane);
}

fn absLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = builder;
    const magnitude = try args[0].abs();
    return try magnitude.sum(.lane);
}

fn tanLoss(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = builder;
    const slope = try args[0].tan();
    return try slope.sum(.lane);
}

fn batchedDotGeneralLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].contract(args[1], .k);
    const weighted = try product.mul(args[2]);
    return try weighted.sum(.{ .b, .m, .n });
}

fn transposedProjectionLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].builder.dotGeneralOp(args[0], args[1], &.{0}, &.{0}, &.{}, &.{});
    return try product.sum(.{ .m, .n });
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
                        .primal = try builder.customCall(
                            custom.target,
                            custom.version,
                            &.{ctx.args[0].primal},
                            ctx.op.result,
                        ),
                        .tangent = try builder.customCall(
                            custom.target,
                            custom.version,
                            &.{ctx.args[0].tangent},
                            ctx.op.result,
                        ),
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
