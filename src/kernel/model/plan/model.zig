const std = @import("std");
const testing = std.testing;

const core = @import("../core/root.zig");

const builder = core.builder;
const schedule_mod = core.schedule;

pub const Error = schedule_mod.ScheduleError ||
    builder.BackendError ||
    builder.FingerprintError ||
    std.mem.Allocator.Error ||
    error{
        ArgumentCountOverflow,
        MissingKernelName,
        ParameterSchemaMismatch,
    };

pub const Options = struct {
    diagnostic_id: ?[]const u8 = null,
    diagnostic: ?*builder.VerificationDiagnostic = null,
};

pub const plan_version: u32 = 1;

pub const Plan = struct {
    allocator: std.mem.Allocator,
    version: u32,
    schedule: schedule_mod.Snapshot,
    schedule_version: u32,
    launch: schedule_mod.Launch,
    body_fingerprint: u64,
    schedule_fingerprint: u64,
    entry_name: []const u8,
    diagnostic_id: []const u8,
    argument_count: u32,
    params: []builder.Param,

    pub fn deinit(self: *Plan) void {
        if (self.params.len != 0) self.allocator.free(self.params);
        self.allocator.free(self.diagnostic_id);
        self.allocator.free(self.entry_name);
        self.schedule.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    kernel: *builder.Kernel,
    schedule: *const schedule_mod.Schedule,
    snapshot_limits: schedule_mod.Snapshot.Limits,
    options: Options,
) Error!Plan {
    var local_diagnostic: builder.VerificationDiagnostic = .{};
    try kernel.verifyWithDiagnostic(options.diagnostic orelse &local_diagnostic);

    const launch = try schedule.launch();
    var snapshot = try schedule_mod.createSnapshot(allocator, snapshot_limits, schedule);
    errdefer snapshot.deinit(allocator);
    const body_fingerprint = try kernel.fingerprint(allocator);
    const schedule_fingerprint = snapshot.fingerprint();

    const entry_name = kernel.func().getName() orelse return error.MissingKernelName;
    const raw_argument_count = kernel.func().getNumArguments();
    if (raw_argument_count != kernel.params().len) return error.ParameterSchemaMismatch;
    const argument_count = std.math.cast(u32, raw_argument_count) orelse return error.ArgumentCountOverflow;

    const owned_entry_name = try allocator.dupe(u8, entry_name);
    errdefer allocator.free(owned_entry_name);
    const owned_diagnostic_id = try allocator.dupe(u8, options.diagnostic_id orelse entry_name);
    errdefer allocator.free(owned_diagnostic_id);
    const owned_params = try allocator.dupe(builder.Param, kernel.params());
    errdefer allocator.free(owned_params);

    return .{
        .allocator = allocator,
        .version = plan_version,
        .schedule = snapshot,
        .schedule_version = snapshot.version,
        .launch = launch,
        .body_fingerprint = body_fingerprint,
        .schedule_fingerprint = schedule_fingerprint,
        .entry_name = owned_entry_name,
        .diagnostic_id = owned_diagnostic_id,
        .argument_count = argument_count,
        .params = owned_params,
    };
}

test "Plan captures authored kernel schedule without backend artifact payload" {
    var schedule = try schedule_mod.Schedule.init(testing.allocator, schedule_mod.Schedule.Limits.testing);
    defer schedule.deinit(testing.allocator);

    const i = try schedule.addAxis("i", 4);
    try schedule.bind(i, .thread_x);

    var b = try builder.Builder.init(testing.allocator, builder.Builder.Limits.testing, "copy_i32_plan", &.{
        builder.dynamicBuffer(.i32),
        builder.dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const index = try b.globalId(.x);
    const value = try b.load(src, index);
    try b.store(value, dst, index);
    try b.return_();

    var kernel = try b.finish();
    defer kernel.deinit();

    var out = try create(
        testing.allocator,
        &kernel,
        &schedule,
        schedule_mod.Snapshot.Limits.testing,
        .{},
    );
    defer out.deinit();

    try testing.expectEqual(plan_version, out.version);
    try testing.expectEqual(schedule_mod.snapshot_version, out.schedule_version);
    try testing.expectEqualStrings("copy_i32_plan", out.entry_name);
    try testing.expectEqualStrings("copy_i32_plan", out.diagnostic_id);
    try testing.expectEqual(@as(u32, 2), out.argument_count);
    try testing.expectEqual(@as(usize, 2), out.params.len);
    try testing.expect((builder.Param{ .buffer = .{ .dtype = .i32 } }).eql(out.params[0]));
    try testing.expect((builder.Param{ .buffer = .{ .dtype = .i32 } }).eql(out.params[1]));

    try testing.expectEqual(@as(u32, 1), out.launch.grid[0]);
    try testing.expectEqual(@as(u32, 4), out.launch.block[0]);
    try testing.expectEqual(@as(usize, 1), out.schedule.allAxes().len);
    try testing.expectEqual(try kernel.fingerprint(testing.allocator), out.body_fingerprint);
    try testing.expectEqual(schedule.fingerprint(), out.schedule_fingerprint);
}
