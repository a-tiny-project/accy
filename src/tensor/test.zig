const std = @import("std");
const gpu = @import("gpu");
const tensor = @import("root.zig");

const fixture = @import("../fixture/root.zig");
const types = tensor.types;
const program = tensor.program;
const batch = tensor.batch;
const nn = tensor.nn;
const lower = tensor.lower;
const execute = tensor.execute;
const Graph = tensor.Graph;
const Builder = tensor.Builder;
const Value = tensor.Value;
const TransformContext = tensor.TransformContext;
const spec = tensor.spec;
const define = tensor.define;
const rewrite = tensor.rewrite;
const linearize = tensor.linearize;
const pullback = tensor.pullback;
const grad = tensor.grad;
const embedding = tensor.embedding;
const sparseCrossEntropyMean = tensor.sparseCrossEntropyMean;
const vmap = tensor.vmap;
const mappedAxis = tensor.mappedAxis;
const runCpu = tensor.runCpu;
const toSemanticModule = tensor.toSemanticModule;
const compileFragment = tensor.compileFragment;
const FragmentCompilerOptions = tensor.FragmentCompilerOptions;

test {
    _ = @import("wire/test.zig");
    _ = @import("session/test.zig");
    _ = @import("dsl/test.zig");
    _ = @import("interpret/test.zig");
    _ = @import("random/test.zig");
    _ = @import("trace/test.zig");
    _ = @import("type/test.zig");
    @import("test_discovery").discover(tensor);
}

fn denseBody(_: *Builder, args: []const Value) !Value {
    const linear = try args[0].contract(args[1], .k);
    return try (try linear.add(args[2])).tanh();
}

test "accy tensor namespace traces rewrites and lowers a dense program" {
    var traced = try define(std.testing.allocator, "dense_root", &.{
        spec(.f32, .{ .m = 2, .k = 4 }),
        spec(.f32, .{ .k = 4, .n = 3 }),
        spec(.f32, .{ .n = 3 }),
    }, denseBody);
    defer traced.deinit();

    var rewritten = try rewrite(std.testing.allocator, &traced, struct {}{});
    defer rewritten.deinit();

    const module = try toSemanticModule(std.testing.allocator, &rewritten);
    defer module.deinit();

    try module.verify();
}

const DropAddZero = struct {
    pub fn add(_: *@This(), ctx: *TransformContext) !?Value {
        if (ctx.isZero(1)) return ctx.arg(0);
        if (ctx.isZero(0)) return ctx.arg(1);
        return null;
    }
};

fn compositionBody(builder: *Builder, args: []const Value) !Value {
    const zero = try builder.full(.f32, .{ .lane = 4 }, 0.0);
    return try (try args[0].mul(args[1])).add(zero);
}

test "accy tensor transforms compose through rewrite linearize rewrite and lower" {
    var traced = try define(std.testing.allocator, "composition", &.{
        spec(.f32, .{ .lane = 4 }),
        spec(.f32, .{ .lane = 4 }),
    }, compositionBody);
    defer traced.deinit();

    var simplified = try rewrite(std.testing.allocator, &traced, DropAddZero{});
    defer simplified.deinit();

    var differentiated = try linearize(std.testing.allocator, &simplified, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    var cleaned = try rewrite(std.testing.allocator, &differentiated.program, DropAddZero{});
    defer cleaned.deinit();

    const module = try toSemanticModule(std.testing.allocator, &cleaned);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.primal_parameter_count);
    try std.testing.expectEqual(@as(usize, 2), differentiated.tangent_parameter_count);
    try std.testing.expectEqual(@as(usize, 2), cleaned.outputs.len);
    try module.verify();
}

test "accy tensor vmap composes with linearize and lowering" {
    var traced = try define(std.testing.allocator, "vmap_linearize", &.{
        spec(.f32, .{ .lane = 4 }),
        spec(.f32, .{ .lane = 4 }),
    }, compositionBody);
    defer traced.deinit();

    var differentiated = try linearize(std.testing.allocator, &traced, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    var batched = try vmap(std.testing.allocator, &differentiated.program, .{
        .axis_size = 8,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0), mappedAxis(0), mappedAxis(0) },
    });
    defer batched.deinit();

    const module = try toSemanticModule(std.testing.allocator, &batched);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 4), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[0]));
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[1]));
    try module.verify();
}

test "accy tensor pullback composes with vmap and lowering" {
    var traced = try define(std.testing.allocator, "pullback_vmap", &.{
        spec(.f32, .{ .lane = 4 }),
        spec(.f32, .{ .lane = 4 }),
    }, compositionBody);
    defer traced.deinit();

    var differentiated = try linearize(std.testing.allocator, &traced, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    var transposed = try pullback(std.testing.allocator, &differentiated, .{});
    defer transposed.deinit();

    var batched = try vmap(std.testing.allocator, &transposed.program, .{
        .axis_size = 8,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0), mappedAxis(0) },
    });
    defer batched.deinit();

    const module = try toSemanticModule(std.testing.allocator, &batched);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 3), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[0]));
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[1]));
    try module.verify();
}

fn gradientBody(_: *Builder, args: []const Value) !Value {
    const product = try args[0].mul(args[1]);
    return try product.sum(.lane);
}

test "accy tensor grad composes with vmap and lowering" {
    var traced = try define(std.testing.allocator, "grad_vmap", &.{
        spec(.f32, .{ .lane = 4 }),
        spec(.f32, .{ .lane = 4 }),
    }, gradientBody);
    defer traced.deinit();

    var differentiated = try grad(std.testing.allocator, &traced, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    var batched = try vmap(std.testing.allocator, &differentiated, .{
        .axis_size = 8,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0) },
    });
    defer batched.deinit();

    const module = try toSemanticModule(std.testing.allocator, &batched);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[0]));
    try types.expectExtents(&.{ 8, 4 }, batched.typeOf(batched.outputs[1]));
    try module.verify();
}

const scan_differential_steps = 5;
const scan_differential_width = 4;

fn buildScanDifferentialScan(allocator: std.mem.Allocator) !Graph {
    var builder = try Builder.init(allocator, "scan_differential");
    errdefer builder.deinit();
    const x0 = try builder.input(.f32, .{ .lane = scan_differential_width });
    const c = try builder.input(.f32, .{ .lane = scan_differential_width });
    const acc0 = try builder.full(.f32, .{ .lane = scan_differential_width }, 0.0);
    const walked = try builder.scan(.{
        .length = scan_differential_steps,
        .init = .{ .x = x0, .acc = acc0, .c = c },
        .body = scanDifferentialStep,
    });
    return try builder.finish(&.{ walked.x, walked.acc });
}

fn scanDifferentialStep(builder: *Builder, carry: anytype) !@TypeOf(carry) {
    const half = try builder.scalar(.f32, 0.5);
    const next_x = try (try (try carry.x.mul(carry.x)).mul(half)).add(carry.c);
    return .{
        .x = next_x,
        .acc = try carry.acc.add(next_x),
        .c = carry.c,
    };
}

fn buildScanDifferentialUnrolled(allocator: std.mem.Allocator) !Graph {
    var builder = try Builder.init(allocator, "scan_differential");
    errdefer builder.deinit();
    const x0 = try builder.input(.f32, .{ .lane = scan_differential_width });
    const c = try builder.input(.f32, .{ .lane = scan_differential_width });
    const half = try builder.scalar(.f32, 0.5);
    var x = x0;
    var acc = try builder.full(.f32, .{ .lane = scan_differential_width }, 0.0);
    for (0..scan_differential_steps) |_| {
        x = try (try (try x.mul(x)).mul(half)).add(c);
        acc = try acc.add(x);
    }
    return try builder.finish(&.{ x, acc });
}

fn buildScatterAddDuplicateProgram(allocator: std.mem.Allocator) !Graph {
    var builder = try Builder.init(allocator, "scatter_add_duplicate");
    errdefer builder.deinit();
    const seed = try builder.input(.f32, .{ .vocab = 4, .channel = 2 });
    const ids = try builder.input(.i32, .{ .token = 4 });
    const updates = try builder.input(.f32, .{ .token = 4, .channel = 2 });
    const out = try seed.scatterAdd(ids, updates, .vocab);
    return try builder.finish(&.{out});
}

test "accy tensor scatter add accumulates duplicate indices on cpu" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var graph = try buildScatterAddDuplicateProgram(allocator);
    defer graph.deinit();

    const seed = [4][2]f32{
        .{ 0.5, 0.5 },
        .{ 1.0, 1.0 },
        .{ 2.0, 2.0 },
        .{ 3.0, 3.0 },
    };
    const ids = [_]i32{ 1, 2, 1, 3 };
    const updates = [4][2]f32{
        .{ 1.0, 10.0 },
        .{ 2.0, 20.0 },
        .{ 3.0, 30.0 },
        .{ 4.0, 40.0 },
    };
    const expected = [4][2]f32{
        .{ 0.5, 0.5 },
        .{ 5.0, 41.0 },
        .{ 4.0, 22.0 },
        .{ 7.0, 43.0 },
    };
    var out: [4][2]f32 = @splat(@splat(0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try execute.runCpu(allocator, &graph, &.{
        std.mem.sliceAsBytes(seed[0..]),
        std.mem.sliceAsBytes(ids[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    }, outputs[0..]);

    for (0..4) |row| {
        try std.testing.expectEqualSlices(f32, expected[row][0..], out[row][0..]);
    }
}

test "accy tensor scheduled scatter add matches the expanded lowering on live CUDA" {
    const accy = @import("../root.zig");
    const gating = @import("accy_validation_gating");
    const allocator = std.testing.allocator;

    try gating.skipIfBuildFlagDisabled(.cuda);
    if (!gpu.cuda.platformSupported()) return gating.skip(.cuda, .unsupported_platform);
    try fixture.requireNativeCpuArtifacts();
    var state = gpu.cuda.State.initDevice(allocator, 0) catch |err| switch (err) {
        error.RuntimeUnavailable => return gating.skip(.cuda, .cuda_device_missing),
        else => return err,
    };
    defer state.deinit();
    const handle = state.handle();

    var graph = try buildScatterAddDuplicateProgram(allocator);
    defer graph.deinit();

    const seed = [4][2]f32{
        .{ 0.5, 0.5 },
        .{ 1.0, 1.0 },
        .{ 2.0, 2.0 },
        .{ 3.0, 3.0 },
    };
    const ids = [_]i32{ 1, 2, 1, 3 };
    const updates = [4][2]f32{
        .{ 1.0, 10.0 },
        .{ 2.0, 20.0 },
        .{ 3.0, 30.0 },
        .{ 4.0, 40.0 },
    };
    const inputs = [_][]const u8{
        std.mem.sliceAsBytes(seed[0..]),
        std.mem.sliceAsBytes(ids[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    };

    var expanded: [4][2]f32 = @splat(@splat(0));
    var expanded_outputs = [_][]u8{std.mem.sliceAsBytes(expanded[0..])};
    try execute.runCpu(allocator, &graph, inputs[0..], expanded_outputs[0..]);

    var family_artifact = try accy.kernel.library.indexing.createScatterAddFamilyArtifact(
        allocator,
        handle,
        .{
            .axis_size = 4,
            .updates = 4,
            .inner = 2,
            .dtype = .f32,
            .threads = 4,
        },
        .{ .limits = .testing, .format = .cuda_ptx },
    );
    defer family_artifact.deinit();
    const registry = family_artifact.registry();

    const options = lower.FragmentCompilerOptions{
        .artifact_format = .cuda_ptx,
        .kernel_call_registry = &registry,
        .scatter_add_schedule = .{ .thread_blocks = 4 },
    };
    const compiled = try lower.compileFragment(allocator, handle, &graph, options);
    var scheduled_fragment = try accy.executable.loadFragment(allocator, handle, compiled, options);
    defer scheduled_fragment.deinit();

    var scheduled: [4][2]f32 = @splat(@splat(0));
    var scheduled_outputs = [_][]u8{std.mem.sliceAsBytes(scheduled[0..])};
    try accy.executable.invoke(
        scheduled_fragment,
        allocator,
        allocator,
        inputs[0..],
        scheduled_outputs[0..],
    );

    for (0..4) |row| {
        try std.testing.expectEqualSlices(f32, expanded[row][0..], scheduled[row][0..]);
    }
}

fn vmapGatherBody(_: *Builder, args: []const Value) !Value {
    return args[0].gather(args[1], .vocab);
}

fn vmapScatterAddBody(_: *Builder, args: []const Value) !Value {
    return args[0].scatterAdd(args[1], args[2], .vocab);
}

test "accy tensor vmap shared batch gather matches the host reference on cpu" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var source = try define(allocator, "vmap_gather_shared_cpu", &.{
        spec(.f32, .{ .vocab = 4, .channel = 2 }),
        spec(.i32, .{ .token = 3 }),
    }, vmapGatherBody);
    defer source.deinit();

    var batched = try vmap(allocator, &source, .{
        .axis_size = 2,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0) },
    });
    defer batched.deinit();

    var input: [2][4][2]f32 = undefined;
    for (0..2) |b| {
        for (0..4) |v| {
            for (0..2) |c| {
                input[b][v][c] = @floatFromInt(100 * b + 10 * v + c);
            }
        }
    }
    const ids = [2][3]i32{
        .{ 0, 2, 3 },
        .{ 3, 0, 3 },
    };

    var expected: [2][3][2]f32 = undefined;
    for (0..2) |b| {
        for (0..3) |t| {
            for (0..2) |c| {
                expected[b][t][c] = input[b][@intCast(ids[b][t])][c];
            }
        }
    }

    var out: [2][3][2]f32 = @splat(@splat(@splat(0)));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try execute.runCpu(allocator, &batched, &.{
        std.mem.sliceAsBytes(input[0..]),
        std.mem.sliceAsBytes(ids[0..]),
    }, outputs[0..]);

    for (0..2) |b| {
        for (0..3) |t| {
            try std.testing.expectEqualSlices(f32, expected[b][t][0..], out[b][t][0..]);
        }
    }
}

test "accy tensor vmap all batched scatter add accumulates duplicate indices on cpu" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var source = try define(allocator, "vmap_scatter_add_all_batched_cpu", &.{
        spec(.f32, .{ .vocab = 4, .channel = 2 }),
        spec(.i32, .{ .token = 3 }),
        spec(.f32, .{ .token = 3, .channel = 2 }),
    }, vmapScatterAddBody);
    defer source.deinit();

    var batched = try vmap(allocator, &source, .{
        .axis_size = 2,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0), mappedAxis(0) },
    });
    defer batched.deinit();

    var seed: [2][4][2]f32 = undefined;
    var updates: [2][3][2]f32 = undefined;
    for (0..2) |b| {
        for (0..4) |v| {
            for (0..2) |c| {
                seed[b][v][c] = @floatFromInt(100 * b + 10 * v + c);
            }
        }
        for (0..3) |t| {
            for (0..2) |c| {
                updates[b][t][c] = @floatFromInt(1000 + 100 * b + 10 * t + c);
            }
        }
    }
    const ids = [2][3]i32{
        .{ 1, 1, 3 },
        .{ 0, 2, 2 },
    };

    var expected = seed;
    for (0..2) |b| {
        for (0..3) |t| {
            for (0..2) |c| {
                expected[b][@intCast(ids[b][t])][c] += updates[b][t][c];
            }
        }
    }

    var out: [2][4][2]f32 = @splat(@splat(@splat(0)));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try execute.runCpu(allocator, &batched, &.{
        std.mem.sliceAsBytes(seed[0..]),
        std.mem.sliceAsBytes(ids[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    }, outputs[0..]);

    for (0..2) |b| {
        for (0..4) |v| {
            try std.testing.expectEqualSlices(f32, expected[b][v][0..], out[b][v][0..]);
        }
    }
}

test "accy tensor vmap batched index scatter add broadcasts the shared input on cpu" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var source = try define(allocator, "vmap_scatter_add_batched_indices_cpu", &.{
        spec(.f32, .{ .vocab = 4, .channel = 2 }),
        spec(.i32, .{ .token = 3 }),
        spec(.f32, .{ .token = 3, .channel = 2 }),
    }, vmapScatterAddBody);
    defer source.deinit();

    var batched = try vmap(allocator, &source, .{
        .axis_size = 2,
        .in_axes = &.{ .none, mappedAxis(0), mappedAxis(0) },
    });
    defer batched.deinit();

    var input: [4][2]f32 = undefined;
    for (0..4) |v| {
        for (0..2) |c| {
            input[v][c] = @floatFromInt(10 * v + c);
        }
    }
    var updates: [2][3][2]f32 = undefined;
    for (0..2) |b| {
        for (0..3) |t| {
            for (0..2) |c| {
                updates[b][t][c] = @floatFromInt(1000 + 100 * b + 10 * t + c);
            }
        }
    }
    const ids = [2][3]i32{
        .{ 0, 0, 2 },
        .{ 1, 3, 1 },
    };

    var expected: [2][4][2]f32 = undefined;
    for (0..2) |b| {
        for (0..4) |v| {
            expected[b][v] = input[v];
        }
        for (0..3) |t| {
            for (0..2) |c| {
                expected[b][@intCast(ids[b][t])][c] += updates[b][t][c];
            }
        }
    }

    var out: [2][4][2]f32 = @splat(@splat(@splat(0)));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try execute.runCpu(allocator, &batched, &.{
        std.mem.sliceAsBytes(input[0..]),
        std.mem.sliceAsBytes(ids[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    }, outputs[0..]);

    for (0..2) |b| {
        for (0..4) |v| {
            try std.testing.expectEqualSlices(f32, expected[b][v][0..], out[b][v][0..]);
        }
    }
}

fn sparseCrossEntropyLossBody(_: *Builder, args: []const Value) !Value {
    return args[0].sparseCrossEntropyLoss(args[1], .vocab);
}

test "accy tensor sparse cross entropy losses match the host reference on cpu" {
    try fixture.requireNativeCpuArtifacts();
    const accy = @import("../root.zig");
    const allocator = std.testing.allocator;
    var graph = try define(allocator, "sparse_cross_entropy_cpu", &.{
        spec(.f32, .{ .sample = 4, .vocab = 5 }),
        spec(.i32, .{ .sample = 4 }),
    }, sparseCrossEntropyLossBody);
    defer graph.deinit();

    var logits = [_]f32{
        0.5,   -1.0, 2.0,  0.0,  1.5,
        -0.25, 0.75, -2.0, 3.0,  0.125,
        1.0,   1.0,  1.0,  1.0,  1.0,
        -3.0,  4.0,  0.5,  -0.5, 2.5,
    };
    var targets = [4]i32{ 2, 0, 4, 1 };
    var expected: [4]f32 = undefined;
    accy.kernel.library.loss.hostRowSparseCrossEntropy(
        4,
        5,
        logits[0..],
        targets[0..],
        expected[0..],
    );

    var losses = @as([4]f32, @splat(0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(losses[0..])};
    try execute.runCpu(allocator, &graph, &.{
        std.mem.sliceAsBytes(logits[0..]),
        std.mem.sliceAsBytes(targets[0..]),
    }, outputs[0..]);

    for (expected, losses) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

fn sparseCrossEntropyMeanBody(_: *Builder, args: []const Value) !Value {
    return sparseCrossEntropyMean(args[0], args[1], .vocab);
}

test "accy tensor sparse cross entropy gradient matches softmax minus one hot on cpu" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var loss_graph = try define(allocator, "sparse_cross_entropy_grad_cpu", &.{
        spec(.f32, .{ .sample = 4, .vocab = 5 }),
        spec(.i32, .{ .sample = 4 }),
    }, sparseCrossEntropyMeanBody);
    defer loss_graph.deinit();

    var gradient_graph = try grad(allocator, &loss_graph, .{ .wrt = &.{0} });
    defer gradient_graph.deinit();

    var logits = [4][5]f32{
        .{ 0.5, -1.0, 2.0, 0.0, 1.5 },
        .{ -0.25, 0.75, -2.0, 3.0, 0.125 },
        .{ 1.0, 1.0, 1.0, 1.0, 1.0 },
        .{ -3.0, 4.0, 0.5, -0.5, 2.5 },
    };
    var targets = [4]i32{ 2, 0, 4, 1 };

    var expected: [4][5]f32 = undefined;
    for (0..4) |row| {
        var row_max = logits[row][0];
        for (logits[row]) |value| row_max = @max(row_max, value);
        var denom: f32 = 0;
        for (logits[row]) |value| denom += @exp(value - row_max);
        for (0..5) |class| {
            const softmax = @exp(logits[row][class] - row_max) / denom;
            const one_hot: f32 = if (targets[row] == class) 1.0 else 0.0;
            expected[row][class] = (softmax - one_hot) / 4.0;
        }
    }

    var logits_grad: [4][5]f32 = @splat(@splat(0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(logits_grad[0..])};
    try execute.runCpu(allocator, &gradient_graph, &.{
        std.mem.sliceAsBytes(logits[0..]),
        std.mem.sliceAsBytes(targets[0..]),
    }, outputs[0..]);

    for (0..4) |row| {
        for (0..5) |class| {
            try std.testing.expectApproxEqAbs(
                expected[row][class],
                logits_grad[row][class],
                0.0001,
            );
        }
    }
}

test "accy tensor vmap sparse cross entropy matches the host reference on cpu" {
    try fixture.requireNativeCpuArtifacts();
    const accy = @import("../root.zig");
    const allocator = std.testing.allocator;
    var source = try define(allocator, "vmap_sparse_cross_entropy_cpu", &.{
        spec(.f32, .{ .sample = 2, .vocab = 5 }),
        spec(.i32, .{ .sample = 2 }),
    }, sparseCrossEntropyLossBody);
    defer source.deinit();

    var batched = try vmap(allocator, &source, .{
        .axis_size = 2,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0) },
    });
    defer batched.deinit();

    var logits = [_]f32{
        0.5,   -1.0, 2.0,  0.0,  1.5,
        -0.25, 0.75, -2.0, 3.0,  0.125,
        1.0,   1.0,  1.0,  1.0,  1.0,
        -3.0,  4.0,  0.5,  -0.5, 2.5,
    };
    var targets = [4]i32{ 2, 0, 4, 1 };
    var expected: [4]f32 = undefined;
    accy.kernel.library.loss.hostRowSparseCrossEntropy(
        4,
        5,
        logits[0..],
        targets[0..],
        expected[0..],
    );

    var losses = @as([4]f32, @splat(0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(losses[0..])};
    try execute.runCpu(allocator, &batched, &.{
        std.mem.sliceAsBytes(logits[0..]),
        std.mem.sliceAsBytes(targets[0..]),
    }, outputs[0..]);

    for (expected, losses) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

test "accy tensor scheduled sparse cross entropy matches the expanded lowering on live CUDA" {
    const accy = @import("../root.zig");
    const gating = @import("accy_validation_gating");
    const allocator = std.testing.allocator;

    try gating.skipIfBuildFlagDisabled(.cuda);
    if (!gpu.cuda.platformSupported()) return gating.skip(.cuda, .unsupported_platform);
    try fixture.requireNativeCpuArtifacts();
    var state = gpu.cuda.State.initDevice(allocator, 0) catch |err| switch (err) {
        error.RuntimeUnavailable => return gating.skip(.cuda, .cuda_device_missing),
        else => return err,
    };
    defer state.deinit();
    const handle = state.handle();

    var graph = try define(allocator, "sparse_cross_entropy_cuda", &.{
        spec(.f32, .{ .sample = 4, .vocab = 5 }),
        spec(.i32, .{ .sample = 4 }),
    }, sparseCrossEntropyLossBody);
    defer graph.deinit();

    var logits = [_]f32{
        0.5,   -1.0, 2.0,  0.0,  1.5,
        -0.25, 0.75, -2.0, 3.0,  0.125,
        1.0,   1.0,  1.0,  1.0,  1.0,
        -3.0,  4.0,  0.5,  -0.5, 2.5,
    };
    var targets = [4]i32{ 2, 0, 4, 1 };
    const inputs = [_][]const u8{
        std.mem.sliceAsBytes(logits[0..]),
        std.mem.sliceAsBytes(targets[0..]),
    };

    var expanded = @as([4]f32, @splat(0));
    var expanded_outputs = [_][]u8{std.mem.sliceAsBytes(expanded[0..])};
    try execute.runCpu(allocator, &graph, inputs[0..], expanded_outputs[0..]);

    var family_artifact = try accy.kernel.library.loss.createRowSparseCrossEntropyFamilyArtifact(
        allocator,
        handle,
        .{
            .rows = 4,
            .classes = 5,
            .threads = 4,
        },
        .{ .limits = .testing, .format = .cuda_ptx },
    );
    defer family_artifact.deinit();
    const registry = family_artifact.registry();

    const options = lower.FragmentCompilerOptions{
        .artifact_format = .cuda_ptx,
        .kernel_call_registry = &registry,
        .row_sparse_cross_entropy_schedule = .{ .thread_blocks = 4 },
    };
    const compiled = try lower.compileFragment(allocator, handle, &graph, options);
    var scheduled_fragment = try accy.executable.loadFragment(allocator, handle, compiled, options);
    defer scheduled_fragment.deinit();

    var scheduled = @as([4]f32, @splat(0));
    var scheduled_outputs = [_][]u8{std.mem.sliceAsBytes(scheduled[0..])};
    try accy.executable.invoke(
        scheduled_fragment,
        allocator,
        allocator,
        inputs[0..],
        scheduled_outputs[0..],
    );

    for (expanded, scheduled) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

fn runScanDifferentialProgram(
    allocator: std.mem.Allocator,
    graph: *Graph,
    xs: []const f32,
    cs: []const f32,
    final_x: []f32,
    final_acc: []f32,
) !void {
    var outputs = [_][]u8{ std.mem.sliceAsBytes(final_x), std.mem.sliceAsBytes(final_acc) };
    try execute.runCpu(
        allocator,
        graph,
        &.{ std.mem.sliceAsBytes(xs), std.mem.sliceAsBytes(cs) },
        outputs[0..],
    );
}

test "accy tensor scan lowers to the same numbers as its hand unrolled twin" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const xs = [_]f32{ 0.25, -0.5, 1.0, 0.125 };
    const cs = [_]f32{ 0.1, 0.2, -0.3, 0.05 };

    var scan_graph = try buildScanDifferentialScan(allocator);
    defer scan_graph.deinit();
    var scan_x = @as([scan_differential_width]f32, @splat(0));
    var scan_acc = @as([scan_differential_width]f32, @splat(0));
    try runScanDifferentialProgram(
        allocator,
        &scan_graph,
        xs[0..],
        cs[0..],
        scan_x[0..],
        scan_acc[0..],
    );

    var unrolled_graph = try buildScanDifferentialUnrolled(allocator);
    defer unrolled_graph.deinit();
    var unrolled_x = @as([scan_differential_width]f32, @splat(0));
    var unrolled_acc = @as([scan_differential_width]f32, @splat(0));
    try runScanDifferentialProgram(
        allocator,
        &unrolled_graph,
        xs[0..],
        cs[0..],
        unrolled_x[0..],
        unrolled_acc[0..],
    );

    var host_x: [scan_differential_width]f32 = xs;
    var host_acc = @as([scan_differential_width]f32, @splat(0));
    for (0..scan_differential_steps) |_| {
        for (0..scan_differential_width) |lane| {
            host_x[lane] = host_x[lane] * host_x[lane] * 0.5 + cs[lane];
            host_acc[lane] += host_x[lane];
        }
    }

    try std.testing.expectEqualSlices(f32, unrolled_x[0..], scan_x[0..]);
    try std.testing.expectEqualSlices(f32, unrolled_acc[0..], scan_acc[0..]);
    for (0..scan_differential_width) |lane| {
        try std.testing.expectApproxEqAbs(host_x[lane], scan_x[lane], 1e-6);
        try std.testing.expectApproxEqAbs(host_acc[lane], scan_acc[lane], 1e-6);
    }
}

fn zeroLengthScanStep(_: *Builder, carry: Value) !Value {
    return carry.add(carry);
}

test "accy tensor scan with zero length yields its carry inits" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var builder = try Builder.init(allocator, "scan_zero_length");
    defer builder.deinit();
    const x0 = try builder.input(.f32, .{ .lane = scan_differential_width });
    const walked = try builder.scan(.{
        .length = 0,
        .init = x0,
        .body = zeroLengthScanStep,
    });
    const one = try builder.scalar(.f32, 1.0);
    const bumped = try walked.add(one);
    var graph = try builder.finish(&.{bumped});
    defer graph.deinit();

    const xs = [_]f32{ 0.25, -0.5, 1.0, 0.125 };
    var out = @as([scan_differential_width]f32, @splat(0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try execute.runCpu(allocator, &graph, &.{std.mem.sliceAsBytes(xs[0..])}, outputs[0..]);

    for (0..scan_differential_width) |lane| {
        try std.testing.expectApproxEqAbs(xs[lane] + 1.0, out[lane], 0.0);
    }
}

fn buildScanLossScan(allocator: std.mem.Allocator) !Graph {
    var builder = try Builder.init(allocator, "scan_loss");
    errdefer builder.deinit();
    const x0 = try builder.input(.f32, .{ .lane = scan_differential_width });
    const c = try builder.input(.f32, .{ .lane = scan_differential_width });
    const acc0 = try builder.full(.f32, .{ .lane = scan_differential_width }, 0.0);
    const walked = try builder.scan(.{
        .length = scan_differential_steps,
        .init = .{ .x = x0, .acc = acc0, .c = c },
        .body = scanDifferentialStep,
    });
    const loss = try walked.acc.sum(.lane);
    return try builder.finish(&.{loss});
}

fn buildScanLossUnrolled(allocator: std.mem.Allocator) !Graph {
    var builder = try Builder.init(allocator, "scan_loss");
    errdefer builder.deinit();
    const x0 = try builder.input(.f32, .{ .lane = scan_differential_width });
    const c = try builder.input(.f32, .{ .lane = scan_differential_width });
    const half = try builder.scalar(.f32, 0.5);
    var x = x0;
    var acc = try builder.full(.f32, .{ .lane = scan_differential_width }, 0.0);
    for (0..scan_differential_steps) |_| {
        x = try (try (try x.mul(x)).mul(half)).add(c);
        acc = try acc.add(x);
    }
    const loss = try acc.sum(.lane);
    return try builder.finish(&.{loss});
}

test "accy tensor grad differentiates scan like its hand unrolled twin" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const xs = [_]f32{ 0.25, -0.5, 1.0, 0.125 };
    const cs = [_]f32{ 0.1, 0.2, -0.3, 0.05 };

    var scan_loss = try buildScanLossScan(allocator);
    defer scan_loss.deinit();
    var scan_grad = try grad(allocator, &scan_loss, .{ .wrt = &.{ 0, 1 } });
    defer scan_grad.deinit();
    try std.testing.expect(!scan_grad.containsScan());
    var scan_dx = @as([scan_differential_width]f32, @splat(0));
    var scan_dc = @as([scan_differential_width]f32, @splat(0));
    var scan_outputs = [_][]u8{
        std.mem.sliceAsBytes(scan_dx[0..]),
        std.mem.sliceAsBytes(scan_dc[0..]),
    };
    try execute.runCpu(allocator, &scan_grad, &.{
        std.mem.sliceAsBytes(xs[0..]),
        std.mem.sliceAsBytes(cs[0..]),
    }, scan_outputs[0..]);

    var unrolled_loss = try buildScanLossUnrolled(allocator);
    defer unrolled_loss.deinit();
    var unrolled_grad = try grad(allocator, &unrolled_loss, .{ .wrt = &.{ 0, 1 } });
    defer unrolled_grad.deinit();
    var unrolled_dx = @as([scan_differential_width]f32, @splat(0));
    var unrolled_dc = @as([scan_differential_width]f32, @splat(0));
    var unrolled_outputs = [_][]u8{
        std.mem.sliceAsBytes(unrolled_dx[0..]),
        std.mem.sliceAsBytes(unrolled_dc[0..]),
    };
    try execute.runCpu(allocator, &unrolled_grad, &.{
        std.mem.sliceAsBytes(xs[0..]),
        std.mem.sliceAsBytes(cs[0..]),
    }, unrolled_outputs[0..]);

    try std.testing.expectEqualSlices(f32, unrolled_dx[0..], scan_dx[0..]);
    try std.testing.expectEqualSlices(f32, unrolled_dc[0..], scan_dc[0..]);
}

test "accy tensor jvp linearizes scan like its hand unrolled twin" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const xs = [_]f32{ 0.25, -0.5, 1.0, 0.125 };
    const cs = [_]f32{ 0.1, 0.2, -0.3, 0.05 };
    const dxs = [_]f32{ 1.0, 0.5, -0.25, 2.0 };
    const dcs = [_]f32{ 0.0, 1.0, 0.5, -1.0 };
    const inputs = [_][]const u8{
        std.mem.sliceAsBytes(xs[0..]),
        std.mem.sliceAsBytes(cs[0..]),
        std.mem.sliceAsBytes(dxs[0..]),
        std.mem.sliceAsBytes(dcs[0..]),
    };

    var scan_graph = try buildScanDifferentialScan(allocator);
    defer scan_graph.deinit();
    var scan_linear = try linearize(allocator, &scan_graph, .{ .wrt = &.{ 0, 1 } });
    defer scan_linear.deinit();
    try std.testing.expect(!scan_linear.program.containsScan());
    var scan_out: [4][scan_differential_width]f32 = @splat(@splat(0));
    var scan_outputs = [_][]u8{
        std.mem.sliceAsBytes(scan_out[0][0..]),
        std.mem.sliceAsBytes(scan_out[1][0..]),
        std.mem.sliceAsBytes(scan_out[2][0..]),
        std.mem.sliceAsBytes(scan_out[3][0..]),
    };
    try execute.runCpu(allocator, &scan_linear.program, inputs[0..], scan_outputs[0..]);

    var unrolled_graph = try buildScanDifferentialUnrolled(allocator);
    defer unrolled_graph.deinit();
    var unrolled_linear = try linearize(allocator, &unrolled_graph, .{ .wrt = &.{ 0, 1 } });
    defer unrolled_linear.deinit();
    var unrolled_out: [4][scan_differential_width]f32 = @splat(@splat(0));
    var unrolled_outputs = [_][]u8{
        std.mem.sliceAsBytes(unrolled_out[0][0..]),
        std.mem.sliceAsBytes(unrolled_out[1][0..]),
        std.mem.sliceAsBytes(unrolled_out[2][0..]),
        std.mem.sliceAsBytes(unrolled_out[3][0..]),
    };
    try execute.runCpu(allocator, &unrolled_linear.program, inputs[0..], unrolled_outputs[0..]);

    for (0..4) |output_index| {
        try std.testing.expectEqualSlices(
            f32,
            unrolled_out[output_index][0..],
            scan_out[output_index][0..],
        );
    }
}

test "accy tensor vmap batches scan structurally" {
    try fixture.requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const batch_size = 3;
    const lane_count = batch_size * scan_differential_width;
    var xs: [lane_count]f32 = undefined;
    var cs: [lane_count]f32 = undefined;
    for (0..lane_count) |index| {
        xs[index] = 0.05 * @as(f32, @floatFromInt(index + 1));
        cs[index] = 0.02 * @as(f32, @floatFromInt(index + 1)) - 0.1;
    }
    const inputs = [_][]const u8{ std.mem.sliceAsBytes(xs[0..]), std.mem.sliceAsBytes(cs[0..]) };

    var scan_graph = try buildScanDifferentialScan(allocator);
    defer scan_graph.deinit();
    var scan_batched = try vmap(allocator, &scan_graph, .{
        .axis_size = batch_size,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0) },
    });
    defer scan_batched.deinit();
    try std.testing.expect(scan_batched.containsScan());
    var scan_x = @as([lane_count]f32, @splat(0));
    var scan_acc = @as([lane_count]f32, @splat(0));
    var scan_outputs = [_][]u8{
        std.mem.sliceAsBytes(scan_x[0..]),
        std.mem.sliceAsBytes(scan_acc[0..]),
    };
    try execute.runCpu(allocator, &scan_batched, inputs[0..], scan_outputs[0..]);

    var unrolled_graph = try buildScanDifferentialUnrolled(allocator);
    defer unrolled_graph.deinit();
    var unrolled_batched = try vmap(allocator, &unrolled_graph, .{
        .axis_size = batch_size,
        .in_axes = &.{ mappedAxis(0), mappedAxis(0) },
    });
    defer unrolled_batched.deinit();
    var unrolled_x = @as([lane_count]f32, @splat(0));
    var unrolled_acc = @as([lane_count]f32, @splat(0));
    var unrolled_outputs = [_][]u8{
        std.mem.sliceAsBytes(unrolled_x[0..]),
        std.mem.sliceAsBytes(unrolled_acc[0..]),
    };
    try execute.runCpu(allocator, &unrolled_batched, inputs[0..], unrolled_outputs[0..]);

    try std.testing.expectEqualSlices(f32, unrolled_x[0..], scan_x[0..]);
    try std.testing.expectEqualSlices(f32, unrolled_acc[0..], scan_acc[0..]);
}

fn denseGradientBody(_: *Builder, args: []const Value) !Value {
    const product = try args[0].contract(args[1], .k);
    return try product.sum(.{ .m, .n });
}

test "accy tensor grad lowers dense scalar loss" {
    var traced = try define(std.testing.allocator, "grad_dense", &.{
        spec(.f32, .{ .m = 2, .k = 4 }),
        spec(.f32, .{ .k = 4, .n = 3 }),
    }, denseGradientBody);
    defer traced.deinit();

    var differentiated = try grad(std.testing.allocator, &traced, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    const module = try toSemanticModule(std.testing.allocator, &differentiated);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(&.{ 2, 4 }, differentiated.typeOf(differentiated.outputs[0]));
    try types.expectExtents(&.{ 4, 3 }, differentiated.typeOf(differentiated.outputs[1]));
    try module.verify();
}

fn batchedDenseGradientBody(_: *Builder, args: []const Value) !Value {
    const product = try args[0].contract(args[1], .k);
    return try product.sum(.{ .b, .m, .n });
}

test "accy tensor grad lowers batched dense scalar loss" {
    var traced = try define(std.testing.allocator, "grad_batched_dense", &.{
        spec(.f32, .{ .b = 5, .m = 2, .k = 4 }),
        spec(.f32, .{ .b = 5, .k = 4, .n = 3 }),
    }, batchedDenseGradientBody);
    defer traced.deinit();

    var differentiated = try grad(std.testing.allocator, &traced, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    const module = try toSemanticModule(std.testing.allocator, &differentiated);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(&.{ 5, 2, 4 }, differentiated.typeOf(differentiated.outputs[0]));
    try types.expectExtents(&.{ 5, 4, 3 }, differentiated.typeOf(differentiated.outputs[1]));
    try module.verify();
}

test "accy tensor vmap composes with dense grad and lowering" {
    var traced = try define(std.testing.allocator, "vmap_grad_dense", &.{
        spec(.f32, .{ .m = 2, .k = 4 }),
        spec(.f32, .{ .k = 4, .n = 3 }),
    }, denseGradientBody);
    defer traced.deinit();

    var differentiated = try grad(std.testing.allocator, &traced, .{ .wrt = &.{ 0, 1 } });
    defer differentiated.deinit();

    var batched = try vmap(std.testing.allocator, &differentiated, .{
        .axis_size = 8,
        .in_axes = &.{ mappedAxis(0), .none },
    });
    defer batched.deinit();

    const module = try toSemanticModule(std.testing.allocator, &batched);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), batched.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), batched.outputs.len);
    try types.expectExtents(&.{ 8, 2, 4 }, batched.typeOf(batched.outputs[0]));
    try types.expectExtents(&.{ 8, 4, 3 }, batched.typeOf(batched.outputs[1]));
    try module.verify();
}

const lm_batch = 2;
const lm_token = 3;
const lm_vocab = 11;
const lm_channel = 4;

fn tinyLanguageModelLoss(_: *Builder, args: []const Value) !Value {
    const token_ids = args[0];
    const target_ids = args[1];
    const embedding_table = args[2];
    const projection = args[3];
    const hidden = try nn.embedding(embedding_table, token_ids, .vocab);
    const flat_hidden = try hidden.merge(.{ .batch, .token }, .sample);
    const flat_targets = try target_ids.merge(.{ .batch, .token }, .sample);
    const logits = try flat_hidden.contract(projection, .channel);
    return nn.sparseCrossEntropyMean(logits, flat_targets, .vocab);
}

test "accy tensor builds and differentiates a tiny language model loss" {
    var traced = try define(std.testing.allocator, "tiny_lm_loss", &.{
        spec(.i32, .{ .batch = lm_batch, .token = lm_token }),
        spec(.i32, .{ .batch = lm_batch, .token = lm_token }),
        spec(.f32, .{ .vocab = lm_vocab, .channel = lm_channel }),
        spec(.f32, .{ .channel = lm_channel, .vocab = lm_vocab }),
    }, tinyLanguageModelLoss);
    defer traced.deinit();

    try types.expectExtents(&.{}, traced.typeOf(traced.outputs[0]));

    const lowered = try toSemanticModule(std.testing.allocator, &traced);
    defer lowered.deinit();
    try lowered.verify();

    var differentiated = try grad(std.testing.allocator, &traced, .{ .wrt = &.{ 2, 3 } });
    defer differentiated.deinit();

    const differentiated_lowered = try toSemanticModule(std.testing.allocator, &differentiated);
    defer differentiated_lowered.deinit();

    try std.testing.expectEqual(@as(usize, 4), differentiated.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), differentiated.outputs.len);
    try types.expectExtents(
        &.{ lm_vocab, lm_channel },
        differentiated.typeOf(differentiated.outputs[0]),
    );
    try types.expectExtents(
        &.{ lm_channel, lm_vocab },
        differentiated.typeOf(differentiated.outputs[1]),
    );
    try differentiated_lowered.verify();
}

const attention_pos = 3;
const attention_ctx = 4;
const attention_head = 2;
const attention_val = 2;

fn buildNamedAttention(allocator: std.mem.Allocator) !Graph {
    var builder = try Builder.init(allocator, "named_attention");
    errdefer builder.deinit();
    const q = try builder.input(.f32, .{ .pos = attention_pos, .head = attention_head });
    const k = try builder.input(.f32, .{ .ctx = attention_ctx, .head = attention_head });
    const v = try builder.input(.f32, .{ .ctx = attention_ctx, .val = attention_val });

    const scores = try q.contract(k, .head);
    const stable = try scores.sub(try scores.max(.ctx));
    const weights = try stable.exp();
    const probs = try weights.div(try weights.sum(.ctx));
    const out = try probs.contract(v, .ctx);
    return try builder.finish(&.{out});
}

fn hostNamedAttention(
    q: *const [attention_pos][attention_head]f32,
    k: *const [attention_ctx][attention_head]f32,
    v: *const [attention_ctx][attention_val]f32,
    out: *[attention_pos][attention_val]f32,
) void {
    for (0..attention_pos) |i| {
        var scores: [attention_ctx]f32 = undefined;
        var row_max: f32 = -std.math.inf(f32);
        for (0..attention_ctx) |j| {
            var dot: f32 = 0;
            for (0..attention_head) |h| dot += q[i][h] * k[j][h];
            scores[j] = dot;
            row_max = @max(row_max, dot);
        }
        var denom: f32 = 0;
        for (0..attention_ctx) |j| {
            scores[j] = @exp(scores[j] - row_max);
            denom += scores[j];
        }
        for (0..attention_val) |x| {
            var acc: f32 = 0;
            for (0..attention_ctx) |j| acc += (scores[j] / denom) * v[j][x];
            out[i][x] = acc;
        }
    }
}

fn runProgramCuda(
    allocator: std.mem.Allocator,
    graph: *Graph,
    inputs: []const []const u8,
    outputs: [][]u8,
) !void {
    const accy = @import("../root.zig");
    const gating = @import("accy_validation_gating");
    try gating.skipIfBuildFlagDisabled(.cuda);
    if (!gpu.cuda.platformSupported()) return gating.skip(.cuda, .unsupported_platform);
    var state = gpu.cuda.State.initDevice(allocator, 0) catch |err| switch (err) {
        error.RuntimeUnavailable => return gating.skip(.cuda, .cuda_device_missing),
        else => return err,
    };
    defer state.deinit();
    const module = try toSemanticModule(allocator, graph);
    const options = accy.executable.FragmentCompilerOptions{
        .artifact_format = .cuda_ptx,
    };
    const compiled = try accy.executable.compileFragmentFromSemanticModule(
        allocator,
        state.handle(),
        module,
        options,
    );
    var fragment = try accy.executable.loadFragment(allocator, state.handle(), compiled, options);
    defer fragment.deinit();
    try accy.executable.invoke(fragment, allocator, allocator, inputs, outputs);
}

test "accy tensor named attention verifies and matches the host softmax reference" {
    const allocator = std.testing.allocator;

    var graph = try buildNamedAttention(allocator);
    defer graph.deinit();
    try types.expectExtents(&.{ attention_pos, attention_val }, graph.typeOf(graph.outputs[0]));
    try std.testing.expectEqualStrings("pos", graph.typeOf(graph.outputs[0]).dims[0].name);
    try std.testing.expectEqualStrings("val", graph.typeOf(graph.outputs[0]).dims[1].name);

    const module = try toSemanticModule(allocator, &graph);
    defer module.deinit();
    try module.verify();

    const q = [attention_pos][attention_head]f32{
        .{ 0.2, -0.4 },
        .{ 1.1, 0.3 },
        .{ -0.7, 0.9 },
    };
    const k = [attention_ctx][attention_head]f32{
        .{ 0.5, 0.1 },
        .{ -0.3, 0.8 },
        .{ 0.9, -0.6 },
        .{ 0.0, 0.4 },
    };
    const v = [attention_ctx][attention_val]f32{
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 0.5, 0.5 },
        .{ -1.0, 2.0 },
    };

    var expected: [attention_pos][attention_val]f32 = undefined;
    hostNamedAttention(&q, &k, &v, &expected);

    var out: [attention_pos][attention_val]f32 = @splat(@splat(0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try runProgramCuda(allocator, &graph, &.{
        std.mem.sliceAsBytes(q[0..]),
        std.mem.sliceAsBytes(k[0..]),
        std.mem.sliceAsBytes(v[0..]),
    }, outputs[0..]);

    for (0..attention_pos) |i| {
        for (0..attention_val) |x| {
            try std.testing.expectApproxEqAbs(expected[i][x], out[i][x], 1e-5);
        }
    }
}

fn buildBatchedContract(allocator: std.mem.Allocator) !Graph {
    var builder = try Builder.init(allocator, "batched_contract");
    errdefer builder.deinit();
    const lhs = try builder.input(.f32, .{ .b = 2, .m = 2, .k = 3 });
    const rhs = try builder.input(.f32, .{ .b = 2, .k = 3, .n = 2 });
    const out = try lhs.contract(rhs, .k);
    return try builder.finish(&.{out});
}

test "accy tensor contract batches shared axes like a per-slice matmul" {
    const allocator = std.testing.allocator;

    var graph = try buildBatchedContract(allocator);
    defer graph.deinit();
    const out_ty = graph.typeOf(graph.outputs[0]);
    try types.expectExtents(&.{ 2, 2, 2 }, out_ty);
    try std.testing.expectEqualStrings("b", out_ty.dims[0].name);
    try std.testing.expectEqualStrings("m", out_ty.dims[1].name);
    try std.testing.expectEqualStrings("n", out_ty.dims[2].name);

    const module = try toSemanticModule(allocator, &graph);
    defer module.deinit();
    try module.verify();

    var lhs: [2][2][3]f32 = undefined;
    var rhs: [2][3][2]f32 = undefined;
    var seed: f32 = 0.1;
    for (0..2) |b| {
        for (0..2) |m| {
            for (0..3) |k| {
                lhs[b][m][k] = seed;
                seed += 0.07;
            }
        }
        for (0..3) |k| {
            for (0..2) |n| {
                rhs[b][k][n] = seed - 0.5;
                seed += 0.05;
            }
        }
    }

    var expected: [2][2][2]f32 = @splat(@splat(@splat(0)));
    for (0..2) |b| {
        for (0..2) |m| {
            for (0..2) |n| {
                for (0..3) |k| {
                    expected[b][m][n] += lhs[b][m][k] * rhs[b][k][n];
                }
            }
        }
    }

    var out: [2][2][2]f32 = @splat(@splat(@splat(0)));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try runProgramCuda(allocator, &graph, &.{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
    }, outputs[0..]);

    for (0..2) |b| {
        for (0..2) |m| {
            for (0..2) |n| {
                try std.testing.expectApproxEqAbs(expected[b][m][n], out[b][m][n], 1e-5);
            }
        }
    }
}

test "accy tensor declaration coverage" {
    std.testing.refAllDecls(tensor);
}
