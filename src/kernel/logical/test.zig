const std = @import("std");
const logical = @import("root.zig");

const kernel = @import("../root.zig");
const Program = logical.Program;
const axis = logical.axis;
const schedule = logical.schedule;

test {
    _ = @import("family.zig");
    _ = @import("selection/test.zig");
    @import("test_discovery").discover(logical);
}

fn scaleEach(inner: anytype, index: kernel.Index1D, each_args: anytype) !void {
    const value = try each_args.param(.src).load(inner, index);
    const scaled = try value.mul(inner, each_args.param(.scale));
    try each_args.param(.dst).store(inner, scaled, index);
}

fn scaleBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 5, args, scaleEach);
}

const Scale = Program(.{
    .name = "kernel_logical_scale_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
        .scale = kernel.scalar(.f32),
    },
    .body = scaleBody,
});

const OneThreadScale = Scale.withSchedule(schedule.threadBlocks(.{ .x = 1 }));

const AxisThreads = struct {
    name: []const u8,
    x: u32,

    pub fn index1D(self: *@This(), ctx: anytype) !kernel.Index1D {
        if (std.mem.eql(u8, ctx.axis.name, self.name)) {
            return ctx.useThreads(self.x);
        }
        return ctx.default();
    }
};

const DelegatedStackScale = Scale.withSchedule(schedule.stack(.{
    schedule.with(AxisThreads{ .name = "j", .x = 2 }),
    schedule.useThreads(.{ .x = 1 }),
}));

const OverrideStackScale = Scale.withSchedule(schedule.stack(.{
    schedule.with(AxisThreads{ .name = "i", .x = 2 }),
    schedule.useThreads(.{ .x = 1 }),
}));

fn windowSumStep(
    fold_inner: anytype,
    offset: kernel.Value,
    acc: kernel.Value,
    fold_ctx: anytype,
) !kernel.Value {
    const input_index = try fold_inner.add(fold_ctx.base, offset);
    const value = try fold_ctx.src.load(fold_inner, input_index);
    return fold_inner.add(acc, value.raw());
}

fn windowSumEach(inner: anytype, index: kernel.Index1D, each_args: anytype) !void {
    const zero = try inner.constantFloat(.f32, 0.0);
    const width = try inner.constantIndex(3);
    const base = try inner.mul(index.index, width);

    const sum = try inner.foldRange(0, 3, 1, zero, .{
        .src = each_args.param(.src),
        .base = base,
    }, windowSumStep);

    try each_args.param(.dst).store(inner, sum, index);
}

fn windowSumBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("window", 4, args, windowSumEach);
}

const WindowSum = Program(.{
    .name = "kernel_logical_window_sum_f32",
    .parameters = .{
        .src = kernel.dynamicBuffer(.f32),
        .dst = kernel.dynamicBuffer(.f32),
    },
    .body = windowSumBody,
});

const DropMul = struct {
    pub fn mul(_: *@This(), ctx: anytype) !kernel.Value {
        return ctx.lhs;
    }
};

const MulPresence = struct {
    has_mul: bool = false,

    pub const Result = struct {
        graph: kernel.Graph,
        has_mul: bool,

        pub fn deinit(self: *@This()) void {
            self.graph.deinit();
            self.* = undefined;
        }
    };

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        self.has_mul = true;
        return ctx.default();
    }

    pub fn finish(self: *@This(), ctx: anytype) !Result {
        return .{
            .graph = try ctx.default(),
            .has_mul = self.has_mul,
        };
    }
};

const DropMulWhenPresent = struct {
    enabled: bool,

    pub fn mul(self: *@This(), ctx: anytype) !kernel.Value {
        if (self.enabled) return ctx.lhs;
        return ctx.default();
    }
};

fn dropMulFromPresence(analysis: *const MulPresence.Result) DropMulWhenPresent {
    return .{ .enabled = analysis.has_mul };
}

const DropFold = struct {
    pub fn fold(_: *@This(), ctx: anytype) !kernel.Value {
        return ctx.initial;
    }
};

const Unscaled = Scale.transform(DropMul{});
const OneThreadUnscaled = OneThreadScale.transform(DropMul{});
const OverrideStackUnscaled = OverrideStackScale.transform(DropMul{});
const LateScheduledUnscaled = Unscaled.withSchedule(schedule.stack(.{
    schedule.with(AxisThreads{ .name = "i", .x = 2 }),
    schedule.useThreads(.{ .x = 1 }),
}));
const RescheduledOneThreadUnscaled = OneThreadUnscaled.withSchedule(
    schedule.threadBlocks(.{ .x = 5 }),
);
const AnalyzedUnscaled = Scale.analyze(MulPresence{}).transform(dropMulFromPresence);
const LateScheduledAnalyzedUnscaled = AnalyzedUnscaled.withSchedule(schedule.stack(.{
    schedule.with(AxisThreads{ .name = "i", .x = 2 }),
    schedule.useThreads(.{ .x = 1 }),
}));
const RescheduledAnalyzedUnscaled = OneThreadScale.analyze(
    MulPresence{},
).transform(dropMulFromPresence).withSchedule(schedule.threadBlocks(.{ .x = 5 }));
const EmptyWindowSum = WindowSum.transform(DropFold{});

test "logical Program compiles to a checked scheduled kernel graph" {
    try std.testing.expectEqual(@as(usize, 0), Scale.arg(.src));
    try std.testing.expectEqual(@as(usize, 1), Scale.arg(.dst));
    try std.testing.expectEqual(@as(usize, 2), Scale.arg(.scale));

    try std.testing.expectEqual(@as(usize, 0), OneThreadScale.arg(.src));

    var graph = try Scale.build(std.testing.allocator, Scale.Limits.testing);
    defer graph.deinit();
    try graph.verify();

    const launch_value = try graph.launch();
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 5), launch_value.block[0]);

    var plan = try Scale.createCheckedPlan(std.testing.allocator, Scale.Limits.testing, .{});
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 3), plan.argument_count);
    try std.testing.expectEqualStrings("kernel_logical_scale_f32", plan.entry_name);

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try Scale.runCpu(std.testing.allocator, Scale.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 2.0, -4.0, 7.0, 8.0, -0.5 }, output[0..]);
}

test "logical Program schedules through a first-class policy" {
    const default_launch = try Scale.launch(std.testing.allocator, Scale.Limits.testing);
    const one_thread_launch = try OneThreadScale.launch(
        std.testing.allocator,
        OneThreadScale.Limits.testing,
    );
    const delegated_launch = try DelegatedStackScale.launch(
        std.testing.allocator,
        DelegatedStackScale.Limits.testing,
    );
    const override_launch = try OverrideStackScale.launch(
        std.testing.allocator,
        OverrideStackScale.Limits.testing,
    );
    var override_snapshot = try OverrideStackScale.scheduleSnapshot(
        std.testing.allocator,
        OverrideStackScale.Limits.testing,
    );
    defer override_snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), default_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 5), default_launch.block[0]);
    try std.testing.expectEqual(@as(u32, 5), one_thread_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), one_thread_launch.block[0]);
    try std.testing.expectEqual(@as(u32, 5), delegated_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), delegated_launch.block[0]);
    try std.testing.expectEqual(@as(u32, 3), override_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), override_launch.block[0]);
    try std.testing.expectEqual(@as(usize, 2), override_snapshot.allAxes().len);
    try std.testing.expectEqual(@as(usize, 4), override_snapshot.allSteps().len);
    try std.testing.expectEqualStrings("i_tile", override_snapshot.allAxes()[0].name);
    try std.testing.expectEqualStrings("i_lane", override_snapshot.allAxes()[1].name);
    try std.testing.expectEqual(kernel.BindTarget.block_x, override_snapshot.allAxes()[0].bind.?);
    try std.testing.expectEqual(kernel.BindTarget.thread_x, override_snapshot.allAxes()[1].bind.?);

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try OverrideStackScale.runCpu(std.testing.allocator, OverrideStackScale.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(3.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 3.0, -6.0, 10.5, 12.0, -0.75 }, output[0..]);
}

test "logical Program folds scalar ranges inside scheduled bodies" {
    const launch_value = try WindowSum.launch(std.testing.allocator, WindowSum.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);

    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0 };
    var output = [_]f32{ 0, 0, 0, 0 };
    try WindowSum.runCpu(std.testing.allocator, WindowSum.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 6.0, 15.0, 24.0, 33.0 }, output[0..]);

    var empty_output = [_]f32{ -1.0, -1.0, -1.0, -1.0 };
    try EmptyWindowSum.runCpu(std.testing.allocator, EmptyWindowSum.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, empty_output[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 0.0, 0.0 }, empty_output[0..]);
}

test "logical Program composes with kernel interpreter transforms" {
    const late_scheduled_launch = try LateScheduledUnscaled.launch(
        std.testing.allocator,
        LateScheduledUnscaled.Limits.testing,
    );
    const rescheduled_launch = try RescheduledOneThreadUnscaled.launch(
        std.testing.allocator,
        RescheduledOneThreadUnscaled.Limits.testing,
    );
    const analyzed_late_scheduled_launch = try LateScheduledAnalyzedUnscaled.launch(
        std.testing.allocator,
        LateScheduledAnalyzedUnscaled.Limits.testing,
    );
    const analyzed_rescheduled_launch = try RescheduledAnalyzedUnscaled.launch(
        std.testing.allocator,
        RescheduledAnalyzedUnscaled.Limits.testing,
    );
    var late_scheduled_snapshot = try LateScheduledUnscaled.scheduleSnapshot(
        std.testing.allocator,
        LateScheduledUnscaled.Limits.testing,
    );
    defer late_scheduled_snapshot.deinit(std.testing.allocator);
    var analyzed_late_scheduled_snapshot = try LateScheduledAnalyzedUnscaled.scheduleSnapshot(
        std.testing.allocator,
        LateScheduledAnalyzedUnscaled.Limits.testing,
    );
    defer analyzed_late_scheduled_snapshot.deinit(std.testing.allocator);
    var analyzed_late_scheduled_plan = try LateScheduledAnalyzedUnscaled.createCheckedPlan(
        std.testing.allocator,
        LateScheduledAnalyzedUnscaled.Limits.testing,
        .{},
    );
    defer analyzed_late_scheduled_plan.deinit();
    try std.testing.expectEqual(@as(u32, 3), late_scheduled_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), late_scheduled_launch.block[0]);
    try std.testing.expectEqual(@as(u32, 1), rescheduled_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 5), rescheduled_launch.block[0]);
    try std.testing.expectEqual(@as(u32, 3), analyzed_late_scheduled_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), analyzed_late_scheduled_launch.block[0]);
    try std.testing.expectEqual(@as(u32, 1), analyzed_rescheduled_launch.grid[0]);
    try std.testing.expectEqual(@as(u32, 5), analyzed_rescheduled_launch.block[0]);
    try std.testing.expectEqual(
        late_scheduled_snapshot.fingerprint(),
        analyzed_late_scheduled_snapshot.fingerprint(),
    );
    try std.testing.expectEqual(
        analyzed_late_scheduled_plan.schedule_fingerprint,
        analyzed_late_scheduled_snapshot.fingerprint(),
    );
    try std.testing.expectEqual(@as(usize, 4), analyzed_late_scheduled_snapshot.allSteps().len);
    try std.testing.expectEqualStrings(
        "i",
        analyzed_late_scheduled_snapshot.allSteps()[0].axis.name,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        analyzed_late_scheduled_snapshot.allSteps()[1].tile.factor,
    );

    var input = [_]f32{ 1.0, -2.0, 3.5, 4.0, -0.25 };
    var output = [_]f32{ 0, 0, 0, 0, 0 };
    try Unscaled.runCpu(std.testing.allocator, Unscaled.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, output[0..]),
        kernel.argumentF32(2.0),
    });
    try std.testing.expectEqualSlices(f32, input[0..], output[0..]);

    var one_thread_output = [_]f32{ 0, 0, 0, 0, 0 };
    try OneThreadUnscaled.runCpu(std.testing.allocator, OneThreadUnscaled.Limits.testing, &.{
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, one_thread_output[0..]),
        kernel.argumentF32(2.0),
    });
    try std.testing.expectEqualSlices(f32, input[0..], one_thread_output[0..]);

    var late_scheduled_output = [_]f32{ 0, 0, 0, 0, 0 };
    try LateScheduledUnscaled.runCpu(
        std.testing.allocator,
        LateScheduledUnscaled.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, input[0..]),
            kernel.argumentBuffer(f32, late_scheduled_output[0..]),
            kernel.argumentF32(2.0),
        },
    );
    try std.testing.expectEqualSlices(f32, input[0..], late_scheduled_output[0..]);

    var rescheduled_output = [_]f32{ 0, 0, 0, 0, 0 };
    try RescheduledOneThreadUnscaled.runCpu(
        std.testing.allocator,
        RescheduledOneThreadUnscaled.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, input[0..]),
            kernel.argumentBuffer(f32, rescheduled_output[0..]),
            kernel.argumentF32(2.0),
        },
    );
    try std.testing.expectEqualSlices(f32, input[0..], rescheduled_output[0..]);

    var analyzed_late_scheduled_output = [_]f32{ 0, 0, 0, 0, 0 };
    try LateScheduledAnalyzedUnscaled.runCpu(
        std.testing.allocator,
        LateScheduledAnalyzedUnscaled.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, input[0..]),
            kernel.argumentBuffer(f32, analyzed_late_scheduled_output[0..]),
            kernel.argumentF32(2.0),
        },
    );
    try std.testing.expectEqualSlices(f32, input[0..], analyzed_late_scheduled_output[0..]);

    var analyzed_rescheduled_output = [_]f32{ 0, 0, 0, 0, 0 };
    try RescheduledAnalyzedUnscaled.runCpu(
        std.testing.allocator,
        RescheduledAnalyzedUnscaled.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, input[0..]),
            kernel.argumentBuffer(f32, analyzed_rescheduled_output[0..]),
            kernel.argumentF32(2.0),
        },
    );
    try std.testing.expectEqualSlices(f32, input[0..], analyzed_rescheduled_output[0..]);

    var stacked_output = [_]f32{ 0, 0, 0, 0, 0 };
    try OverrideStackUnscaled.runCpu(
        std.testing.allocator,
        OverrideStackUnscaled.Limits.testing,
        &.{
            kernel.argumentBuffer(f32, input[0..]),
            kernel.argumentBuffer(f32, stacked_output[0..]),
            kernel.argumentF32(2.0),
        },
    );
    try std.testing.expectEqualSlices(f32, input[0..], stacked_output[0..]);
}

test "accy kernel logical declaration coverage" {
    std.testing.refAllDecls(logical);
}
