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

fn constantBody(builder: *trace.Builder, args: []const trace.Value) !trace.Value {
    _ = args;
    return builder.full(.f32, .{ .lane = 4 }, 3.0);
}
