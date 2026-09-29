const std = @import("std");
const batch = @import("batch.zig");
const execute = @import("execute.zig");
const gradient = @import("grad.zig");
const lower = @import("lower.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const types = @import("type/root.zig");

pub const Function = struct {
    allocator: std.mem.Allocator,
    graph: program_mod.Program,
    root: ?*Function,
    derived: std.ArrayListUnmanaged(*Function),

    pub fn define(
        allocator: std.mem.Allocator,
        name: []const u8,
        specs: []const types.Spec,
        comptime body: anytype,
    ) !Function {
        return .{
            .allocator = allocator,
            .graph = try trace.define(allocator, name, specs, body),
            .root = null,
            .derived = .empty,
        };
    }

    pub fn deinit(self: *Function) void {
        std.debug.assert(self.root == null);
        for (self.derived.items) |child| {
            child.graph.deinit();
            self.allocator.destroy(child);
        }
        self.derived.deinit(self.allocator);
        self.graph.deinit();
        self.* = undefined;
    }

    pub fn grad(self: *Function, options: gradient.Options) !*Function {
        return self.adopt(try gradient.grad(self.allocator, &self.graph, options));
    }

    pub fn valueAndGrad(self: *Function, options: gradient.Options) !*Function {
        return self.adopt(try gradient.valueAndGrad(self.allocator, &self.graph, options));
    }

    pub fn vmap(self: *Function, options: batch.Options) !*Function {
        return self.adopt(try batch.vmap(self.allocator, &self.graph, options));
    }

    pub fn compileCpu(self: *const Function) !execute.Cpu {
        return execute.Cpu.init(self.allocator, &self.graph);
    }

    pub fn compileFragment(
        self: *const Function,
        handle: lower.BackendHandle,
        options: lower.FragmentCompilerOptions,
    ) !*lower.CompiledFragment {
        return lower.compileFragment(self.allocator, handle, &self.graph, options);
    }

    fn adopt(self: *Function, graph: program_mod.Program) !*Function {
        var owned = graph;
        errdefer owned.deinit();
        const root = self.root orelse self;
        const child = try root.allocator.create(Function);
        errdefer root.allocator.destroy(child);
        child.* = .{
            .allocator = root.allocator,
            .graph = owned,
            .root = root,
            .derived = .empty,
        };
        try root.derived.append(root.allocator, child);
        return child;
    }
};

fn productLoss(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const product = try args[0].mul(args[1]);
    return try product.sum(.lane);
}

test "tensor function owns every derived graph through one deinit" {
    var f = try Function.define(std.testing.allocator, "function_ownership", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, productLoss);
    defer f.deinit();

    const g = try f.grad(.{ .wrt = &.{ 0, 1 } });
    const bg = try g.vmap(.{
        .axis_size = 8,
        .in_axes = &.{ batch.mapped(0), batch.mapped(0) },
    });
    const step = try f.valueAndGrad(.{ .wrt = &.{ 0, 1 } });

    try std.testing.expectEqual(@as(usize, 2), g.graph.outputs.len);
    try types.expectExtents(&.{ 8, 4 }, bg.graph.typeOf(bg.graph.outputs[0]));
    try types.expectExtents(&.{ 8, 4 }, bg.graph.typeOf(bg.graph.outputs[1]));
    try std.testing.expectEqual(@as(usize, 3), step.graph.outputs.len);
    try types.expectExtents(&.{}, step.graph.typeOf(step.graph.outputs[0]));
}

test "tensor function value and grad matches the free-function path numerically" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var f = try Function.define(allocator, "function_parity", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, productLoss);
    defer f.deinit();

    const step = try f.valueAndGrad(.{ .wrt = &.{ 0, 1 } });
    var executor = try step.compileCpu();
    defer executor.deinit();

    const x = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const y = [_]f32{ 0.5, -1.0, 2.0, 0.25 };
    const inputs = [_][]const u8{
        std.mem.sliceAsBytes(x[0..]),
        std.mem.sliceAsBytes(y[0..]),
    };

    var loss_value: f32 = 0;
    var x_grad = @as([4]f32, @splat(0));
    var y_grad = @as([4]f32, @splat(0));
    const outputs = [_][]u8{
        std.mem.asBytes(&loss_value),
        std.mem.sliceAsBytes(x_grad[0..]),
        std.mem.sliceAsBytes(y_grad[0..]),
    };
    try executor.launch(allocator, inputs[0..], outputs[0..]);

    var source = try trace.define(allocator, "function_parity_reference", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, productLoss);
    defer source.deinit();
    var reference = try gradient.valueAndGrad(allocator, &source, .{ .wrt = &.{ 0, 1 } });
    defer reference.deinit();

    var reference_loss: f32 = 0;
    var reference_x_grad = @as([4]f32, @splat(0));
    var reference_y_grad = @as([4]f32, @splat(0));
    const reference_outputs = [_][]u8{
        std.mem.asBytes(&reference_loss),
        std.mem.sliceAsBytes(reference_x_grad[0..]),
        std.mem.sliceAsBytes(reference_y_grad[0..]),
    };
    try execute.runCpu(allocator, &reference, inputs[0..], reference_outputs[0..]);

    try std.testing.expectEqual(reference_loss, loss_value);
    try std.testing.expectEqualSlices(f32, reference_x_grad[0..], x_grad[0..]);
    try std.testing.expectEqualSlices(f32, reference_y_grad[0..], y_grad[0..]);
    try std.testing.expectApproxEqAbs(@as(f32, 5.5), loss_value, 0.000001);
}

test "tensor function composes per-example gradients through vmap of grad" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const rows = 3;
    const lanes = 4;

    var f = try Function.define(allocator, "function_vmap_grad", &.{
        types.spec(.f32, .{ .lane = lanes }),
        types.spec(.f32, .{ .lane = lanes }),
    }, productLoss);
    defer f.deinit();

    const per_example = try (try f.grad(.{ .wrt = &.{ 0, 1 } })).vmap(.{
        .axis_size = rows,
        .in_axes = &.{ batch.mapped(0), batch.mapped(0) },
    });
    var executor = try per_example.compileCpu();
    defer executor.deinit();

    var x: [rows * lanes]f32 = undefined;
    var y: [rows * lanes]f32 = undefined;
    for (0..rows * lanes) |index| {
        x[index] = @as(f32, @floatFromInt(index)) * 0.5 - 2.0;
        y[index] = 1.0 - @as(f32, @floatFromInt(index)) * 0.25;
    }

    var x_grad = @as([(rows * lanes)]f32, @splat(0));
    var y_grad = @as([(rows * lanes)]f32, @splat(0));
    const outputs = [_][]u8{
        std.mem.sliceAsBytes(x_grad[0..]),
        std.mem.sliceAsBytes(y_grad[0..]),
    };
    try executor.launch(allocator, &.{
        std.mem.sliceAsBytes(x[0..]),
        std.mem.sliceAsBytes(y[0..]),
    }, outputs[0..]);

    try std.testing.expectEqualSlices(f32, y[0..], x_grad[0..]);
    try std.testing.expectEqualSlices(f32, x[0..], y_grad[0..]);
}
