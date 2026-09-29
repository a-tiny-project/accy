const std = @import("std");
const kernel = @import("../root.zig");
const logical_builder = @import("../model/logical/root.zig");
const parameter = @import("../program/root.zig").parameter;
const schedule_mod = logical_builder.schedule;

pub fn Family(comptime definition: anytype) type {
    return struct {
        const FamilySource: type = kernel.Family(FamilyDefinition(definition));

        pub const name = definition.name;
        pub const parameters = definition.parameters;
        pub const Layout: type = FamilySource.Layout;
        pub const Instance: type = definition.Instance;
        pub const Limits: type = FamilySource.Limits;

        pub const arg = FamilySource.arg;
        pub const schema = FamilySource.schema;
        pub const build = FamilySource.build;
        pub const buildNamed = FamilySource.buildNamed;
        pub const interpret = FamilySource.interpret;
        pub const launch = FamilySource.launch;
        pub const scheduleSnapshot = FamilySource.scheduleSnapshot;
        pub const createPlan = FamilySource.createPlan;
        pub const createCheckedPlan = FamilySource.createCheckedPlan;
        pub const compileFragment = FamilySource.compileFragment;
        pub const createKernelArtifact = FamilySource.createKernelArtifact;
        pub const createKernelCallArtifact = FamilySource.createKernelCallArtifact;
        pub const runCpu = FamilySource.runCpu;
        pub const runCpuWithDiagnostic = FamilySource.runCpuWithDiagnostic;
        pub const verify = FamilySource.verify;
    };
}

fn FamilyDefinition(comptime definition: anytype) type {
    return struct {
        pub const name = definition.name;
        pub const parameters = definition.parameters;
        pub const Instance: type = definition.Instance;

        pub fn body(raw_builder: anytype, instance: definition.Instance, _: anytype) !void {
            var logical = logical_builder.wrap(raw_builder, scheduleValue(definition, instance));
            try call(definition, instance, &logical);
        }
    };
}

fn ScheduleValue(comptime definition: anytype) type {
    if (@hasField(@TypeOf(definition), "schedule")) {
        return @TypeOf(definition.schedule(@as(definition.Instance, undefined)));
    }
    return schedule_mod.ThreadBlocks;
}

fn scheduleValue(comptime definition: anytype, instance: definition.Instance) ScheduleValue(definition) {
    if (comptime @hasField(@TypeOf(definition), "schedule")) {
        return definition.schedule(instance);
    }
    return schedule_mod.default();
}

fn call(comptime definition: anytype, instance: definition.Instance, k: anytype) !void {
    if (comptime parameter.named(definition.parameters)) {
        try definition.body(k, instance, parameter.Args(definition.parameters, PointerChild(@TypeOf(k))){ .builder = k });
    } else {
        const count = comptime parameter.arity(definition.parameters);
        var args: [count]kernel.Value = undefined;
        inline for (0..count) |index_value| {
            args[index_value] = k.argument(index_value);
        }
        try definition.body(k, instance, args[0..]);
    }
}

fn PointerChild(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info.child,
        else => @compileError("logical kernel Family bodies receive builder pointers"),
    };
}

const ScaleInstance = struct {
    extent: u64,
    threads: u32,
};

fn scaleFamilySchedule(instance: ScaleInstance) schedule_mod.ThreadBlocks {
    return schedule_mod.threadBlocks(.{ .x = instance.threads });
}

fn scaleFamilyBody(k: anytype, instance: ScaleInstance, args: anytype) !void {
    _ = try k.forEach1D("i", instance.extent, args, struct {
        fn each(inner: anytype, index: kernel.Index1D, each_args: anytype) !void {
            const value = try each_args.param(.src).load(inner, index);
            const scaled = try value.mul(inner, each_args.param(.scale));
            try each_args.param(.dst).store(inner, scaled, index);
        }
    }.each);
}

const ScaleFamily = Family(.{
    .name = "kernel_logical_scale_family_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .Instance = ScaleInstance,
    .schedule = scaleFamilySchedule,
    .body = scaleFamilyBody,
});

test "logical Family schedules runtime instances through thread block policies" {
    const compact_launch = try ScaleFamily.launch(std.testing.allocator, ScaleFamily.Limits.testing, .{ .extent = 5, .threads = 5 });
    try std.testing.expectEqual(@as(u32, 1), compact_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 5), compact_launch.block[0]);

    const tiled_launch = try ScaleFamily.launch(std.testing.allocator, ScaleFamily.Limits.testing, .{ .extent = 6, .threads = 2 });
    try std.testing.expectEqual(@as(u32, 3), tiled_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), tiled_launch.block[0]);

    var tiled_snapshot = try ScaleFamily.scheduleSnapshot(std.testing.allocator, ScaleFamily.Limits.testing, .{ .extent = 6, .threads = 2 });
    defer tiled_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), tiled_snapshot.allAxes().len);
    try std.testing.expectEqualStrings("i_tile", tiled_snapshot.allAxes()[0].name);
    try std.testing.expectEqualStrings("i_lane", tiled_snapshot.allAxes()[1].name);
    try std.testing.expectEqual(kernel.BindTarget.block_x, tiled_snapshot.allAxes()[0].bind.?);
    try std.testing.expectEqual(kernel.BindTarget.thread_x, tiled_snapshot.allAxes()[1].bind.?);
}

test "logical Family executes runtime instances on the CPU oracle" {
    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25, 6.0 };
    var output = [_]f32{ 0, 0, 0, 0, 0, 0 };
    try ScaleFamily.runCpu(std.testing.allocator, ScaleFamily.Limits.testing, .{ .extent = 6, .threads = 2 }, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 2.0, -4.0, 7.0, 8.0, -0.5, 12.0 }, output[0..]);

    var head_output = [_]f32{ 0, 0, 0, 0, 0, 0 };
    try ScaleFamily.runCpu(std.testing.allocator, ScaleFamily.Limits.testing, .{ .extent = 3, .threads = 4 }, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, head_output[0..]),
        kernel.argumentF32(3.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 3.0, -6.0, 10.5, 0.0, 0.0, 0.0 }, head_output[0..]);
}

const LoopCarryInstance = struct {
    steps: u32,
};

fn loopCarryFamilyBody(k: anytype, instance: LoopCarryInstance, args: anytype) !void {
    const zero_index = try k.constantIndex(0);
    const one_index = try k.constantIndex(1);
    const upper = try k.constantIndex(instance.steps);
    const zero_i32 = try k.constantInt(.i32, 0);
    const one_i32 = try k.constantInt(.i32, 1);

    var init_values = [_]kernel.Value{ zero_i32, zero_i32 };
    var result_types = [_]kernel.Type{ zero_i32.valueType(), zero_i32.valueType() };
    var scope = try k.forScope(zero_index, upper, one_index, init_values[0..], result_types[0..]);
    errdefer scope.abort();

    const sum = scope.iterArg(0).?;
    const count = scope.iterArg(1).?;
    const step_i32 = try k.cast(scope.inductionVar(), .i32);
    const next_sum = try k.add(sum, step_i32);
    const next_count = try k.add(count, one_i32);
    try scope.leave(&.{ next_sum, next_count });

    const total = try k.add(scope.result(0).?, scope.result(1).?);
    try args.param(.dst).store(k, total, zero_index);
}

const LoopCarryFamily = Family(.{
    .name = "kernel_logical_loop_carry_i32",
    .parameters = .{
        .dst = kernel.dynamicBuffer(.i32),
    },
    .Instance = LoopCarryInstance,
    .body = loopCarryFamilyBody,
});

const ForScopeCounter = struct {
    for_scope_count: usize = 0,
    iter_arg_count: usize = 0,
    leave_count: usize = 0,
    result_count: usize = 0,

    pub const Result = struct {
        graph: kernel.Graph,
        for_scope_count: usize,
        iter_arg_count: usize,
        leave_count: usize,
        result_count: usize,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn forScope(self: *@This(), ctx: anytype) !@TypeOf(ctx.*).ScopeType {
        self.for_scope_count += 1;
        return ctx.default();
    }

    pub fn forScopeIterArg(self: *@This(), ctx: anytype) ?kernel.Value {
        self.iter_arg_count += 1;
        return ctx.default();
    }

    pub fn forScopeLeave(self: *@This(), ctx: anytype) !void {
        self.leave_count += 1;
        try ctx.default();
    }

    pub fn forScopeResult(self: *@This(), ctx: anytype) ?kernel.Value {
        self.result_count += 1;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .for_scope_count = self.for_scope_count,
            .iter_arg_count = self.iter_arg_count,
            .leave_count = self.leave_count,
            .result_count = self.result_count,
        };
    }
};

test "logical Family forwards forScope through interpret layers" {
    var result = try LoopCarryFamily.interpret(std.testing.allocator, LoopCarryFamily.Limits.testing, .{ .steps = 4 }, ForScopeCounter{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.for_scope_count);
    try std.testing.expectEqual(@as(usize, 2), result.iter_arg_count);
    try std.testing.expectEqual(@as(usize, 1), result.leave_count);
    try std.testing.expectEqual(@as(usize, 2), result.result_count);
    try result.graph.verify();

    var output = [_]i32{0};
    try result.graph.runCpu(std.testing.allocator, &.{
        kernel.argumentBuffer(i32, output[0..]),
    });
    try std.testing.expectEqual(@as(i32, 10), output[0]);
}
