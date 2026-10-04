const std = @import("std");
const spec = @import("spec.zig");
const tensor = @import("../root.zig");
const namespace = @import("root.zig");
const program_mod = tensor.program;
const trace = tensor.trace;
const types = tensor.types;
const Graph = namespace.Graph;
const semantics = namespace.semantics;
const bind = namespace.bind;
const stack = namespace.stack;
const layer = namespace.layer;
const run = namespace.run;
const result = namespace.result;

fn rankBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].tanh();
}

const RankBinding = struct {
    pub const Value = usize;
    pub const Result = usize;

    pub fn bind(_: *@This(), op: *const program_mod.Operation, args: []const usize) !usize {
        _ = args;
        return op.result.rank();
    }

    pub fn finish(_: *@This(), outputs: []const usize) !Result {
        return outputs[0];
    }
};

test "tensor interpreter walks operations and collects outputs" {
    var source = try trace.define(std.testing.allocator, "interpret_rank", &.{
        types.spec(.f32, .{ .lane = 4 }),
    }, rankBody);
    defer source.deinit();

    const rank = try run(std.testing.allocator, &source, RankBinding{});

    try std.testing.expectEqual(@as(usize, 1), rank);
}

const MethodLeafAddCounter = struct {
    count: usize = 0,

    pub const Value = usize;
    pub const Result = usize;

    pub fn default(self: *@This(), ctx: anytype) !usize {
        _ = ctx;
        return self.count;
    }

    pub fn add(self: *@This(), ctx: anytype) !usize {
        _ = ctx.arg(0);
        self.count += 1;
        return self.count;
    }

    pub fn finish(self: *@This(), outputs: []const usize) !Result {
        _ = outputs;
        return self.count;
    }
};

test "tensor leaf semantics dispatch primitive methods" {
    var source = try trace.define(std.testing.allocator, "interpret_leaf_methods", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, addBody);
    defer source.deinit();

    const count = try run(std.testing.allocator, &source, MethodLeafAddCounter{});
    const explicit_count = try run(
        std.testing.allocator,
        &source,
        semantics(usize, MethodLeafAddCounter{}),
    );

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), explicit_count);
}

fn addBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    return try args[0].add(args[1]);
}

const CountAddLayer = struct {
    count: *usize,

    pub fn bind(self: *@This(), ctx: anytype) !trace.Value {
        switch (ctx.op.kind) {
            .binary => |binary| {
                if (binary.op == .add) self.count.* += 1;
            },
            else => {},
        }
        return ctx.default();
    }
};

test "tensor interpreter layers let users observe and delegate primitive binds" {
    var source = try trace.define(std.testing.allocator, "interpret_layer", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, addBody);
    defer source.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    var count: usize = 0;
    const graph = Graph{ .builder = &builder };
    var counted = try run(
        std.testing.allocator,
        &source,
        layer(trace.Value, graph, CountAddLayer{ .count = &count }),
    );
    defer counted.deinit();

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(source.operationCount(), counted.operationCount());
    try types.expectExtents(&.{4}, counted.typeOf(counted.outputs[0]));
}

const MethodAddCounter = struct {
    count: *usize,

    pub fn add(self: *@This(), ctx: anytype) !trace.Value {
        _ = ctx.arg(0);
        self.count.* += 1;
        return ctx.default();
    }
};

const CountedGraph = struct {
    graph: program_mod.Program,
    finish_count: usize,

    pub fn deinit(self: *@This()) void {
        self.graph.deinit();
    }
};

const FinishSummary = struct {
    count: *usize,

    pub const Result: type = CountedGraph;

    pub fn finish(self: *@This(), ctx: anytype, outputs: []const trace.Value) !Result {
        self.count.* += 1;
        return .{
            .graph = try ctx.default(outputs),
            .finish_count = self.count.*,
        };
    }
};

test "tensor interpreter bind specs stack primitive handlers and finish wrappers" {
    var source = try trace.define(std.testing.allocator, "interpret_stack", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, addBody);
    defer source.deinit();

    var builder = try trace.Builder.init(std.testing.allocator, source.name);
    errdefer builder.deinit();

    var add_count: usize = 0;
    var finish_count: usize = 0;
    const graph = Graph{ .builder = &builder };
    var counted = try run(
        std.testing.allocator,
        &source,
        stack(.{
            bind(FinishSummary{ .count = &finish_count }),
            bind(MethodAddCounter{ .count = &add_count }),
        }).attach(graph),
    );
    defer counted.deinit();

    try std.testing.expectEqual(@as(usize, 1), add_count);
    try std.testing.expectEqual(@as(usize, 1), counted.finish_count);
    try std.testing.expectEqual(@as(usize, 1), finish_count);
    try std.testing.expectEqual(source.operationCount(), counted.graph.operationCount());
    try types.expectExtents(&.{4}, counted.graph.typeOf(counted.graph.outputs[0]));
}
