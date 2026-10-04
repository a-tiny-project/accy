const std = @import("std");
const gpu = @import("gpu");
const accy = @import("../root.zig");
const lower = @import("lower.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const types = @import("type/root.zig");

pub const Cpu = struct {
    allocator: std.mem.Allocator,
    state: *gpu.cpu.State,
    fragment: *lower.LoadedFragment,

    pub fn init(allocator: std.mem.Allocator, program: *const program_mod.Program) !Cpu {
        return initWith(allocator, program, .{ .artifact_format = .cpu_object });
    }

    pub fn initWith(
        allocator: std.mem.Allocator,
        program: *const program_mod.Program,
        options: lower.FragmentCompilerOptions,
    ) !Cpu {
        const state = try allocator.create(gpu.cpu.State);
        errdefer allocator.destroy(state);
        state.* = gpu.cpu.State.init(allocator);
        errdefer state.deinit();
        const compiled = try lower.compileFragment(allocator, state.handle(), program, options);
        const fragment = try accy.executable.loadFragment(
            allocator,
            state.handle(),
            compiled,
            options,
        );
        return .{ .allocator = allocator, .state = state, .fragment = fragment };
    }

    pub fn deinit(self: *Cpu) void {
        self.fragment.deinit();
        self.state.deinit();
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn launch(
        self: *const Cpu,
        scratch: std.mem.Allocator,
        inputs: []const []const u8,
        outputs: []const []u8,
    ) !void {
        try accy.executable.invoke(self.fragment, scratch, scratch, inputs, outputs);
    }
};

pub fn runCpu(
    allocator: std.mem.Allocator,
    program: *const program_mod.Program,
    inputs: []const []const u8,
    outputs: []const []u8,
) !void {
    var executor = try Cpu.init(allocator, program);
    defer executor.deinit();
    try executor.launch(allocator, inputs, outputs);
}

fn scaleShiftBody(_: *trace.Builder, args: []const trace.Value) !trace.Value {
    const doubled = try args[0].add(args[0]);
    return doubled.add(args[1]);
}

test "tensor cpu executor launches one program repeatedly" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var graph = try trace.define(allocator, "execute_scale_shift", &.{
        types.spec(.f32, .{ .lane = 4 }),
        types.spec(.f32, .{ .lane = 4 }),
    }, scaleShiftBody);
    defer graph.deinit();

    var executor = try Cpu.init(allocator, &graph);
    defer executor.deinit();

    const base = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var shift = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    var out = @as([4]f32, @splat(0));
    const outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};

    try executor.launch(allocator, &.{
        std.mem.sliceAsBytes(base[0..]),
        std.mem.sliceAsBytes(shift[0..]),
    }, outputs[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 2.5, 4.5, 6.5, 8.5 }, out[0..]);

    shift = .{ -1.0, -1.0, -1.0, -1.0 };
    try executor.launch(allocator, &.{
        std.mem.sliceAsBytes(base[0..]),
        std.mem.sliceAsBytes(shift[0..]),
    }, outputs[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 3.0, 5.0, 7.0 }, out[0..]);
}

test "tensor runCpu runs a program once" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var graph = try trace.define(allocator, "execute_run_once", &.{
        types.spec(.f32, .{ .lane = 3 }),
        types.spec(.f32, .{ .lane = 3 }),
    }, scaleShiftBody);
    defer graph.deinit();

    const base = [_]f32{ 1.0, -2.0, 0.25 };
    const shift = [_]f32{ 0.0, 1.0, -0.25 };
    var out = @as([3]f32, @splat(0));
    const outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try runCpu(allocator, &graph, &.{
        std.mem.sliceAsBytes(base[0..]),
        std.mem.sliceAsBytes(shift[0..]),
    }, outputs[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 2.0, -3.0, 0.25 }, out[0..]);
}

fn constantBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = args;
    return builder.full(.f32, .{ .lane = 4 }, 3.0);
}

test "tensor runCpu serves constant-only outputs" {
    const allocator = std.testing.allocator;
    var graph = try trace.define(allocator, "execute_constant_output", &.{
        types.spec(.f32, .{ .lane = 3 }),
    }, constantBody);
    defer graph.deinit();

    const ignored = [_]f32{ 1.0, 2.0, 3.0 };
    var out = @as([4]f32, @splat(0));
    const outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try runCpu(allocator, &graph, &.{std.mem.sliceAsBytes(ignored[0..])}, outputs[0..]);
    try std.testing.expectEqualSlices(f32, &.{ 3.0, 3.0, 3.0, 3.0 }, out[0..]);
}
