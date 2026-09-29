const std = @import("std");
const pretty_json = @import("pretty").json;
const coz = @import("coz");
const metadata = @import("metadata.zig");
const stabilizer = @import("stabilizer");
const sys = @import("sys");
const tracy = @import("tracy");

const Allocator = std.mem.Allocator;
const SourceLocation = std.builtin.SourceLocation;

pub const CozSession = struct {
    runtime: coz.Runtime = .{},
    profile_file: coz.ProfileFile = .{},
    enabled: bool = false,

    pub fn start(self: *CozSession, alloc: Allocator) !void {
        try self.startWithOptions(alloc, .{});
    }

    pub fn startWithOptions(self: *CozSession, alloc: Allocator, options: coz.RuntimeOptions) !void {
        self.enabled = try self.runtime.startIfAvailable(alloc, options);
    }

    pub fn startWithOutputPath(self: *CozSession, alloc: Allocator, path: []const u8) !void {
        try self.startWithOutputPathAndOptions(alloc, path, .{});
    }

    pub fn startWithOutputPathAndOptions(
        self: *CozSession,
        alloc: Allocator,
        path: []const u8,
        options: coz.RuntimeOptions,
    ) !void {
        try self.profile_file.open(path);
        errdefer self.profile_file.close();

        var runtime_options = options;
        runtime_options.profile_writer = self.profile_file.interface().?;
        self.enabled = try self.runtime.startIfAvailable(alloc, runtime_options);
        if (!self.enabled) self.profile_file.close();
    }

    pub fn deinit(self: *CozSession) void {
        self.runtime.shutdown();
        self.profile_file.close();
        self.enabled = false;
    }

    pub fn finish(self: *CozSession) !void {
        var first_error: ?anyerror = null;
        self.runtime.stop() catch |err| rememberSessionError(&first_error, err);
        self.profile_file.finish() catch |err| rememberSessionError(&first_error, err);
        self.enabled = false;
        if (first_error) |err| return err;
    }
};

pub const CapabilityName = enum {
    coz,
    tracy,
    stabilizer,
    memtrace,
    perf,

    pub fn text(self: CapabilityName) []const u8 {
        return switch (self) {
            .coz => "coz",
            .tracy => "tracy",
            .stabilizer => "stabilizer",
            .memtrace => "memtrace",
            .perf => "perf",
        };
    }
};

pub const CapabilityState = enum {
    enabled,
    disabled,
    unavailable,

    pub fn text(self: CapabilityState) []const u8 {
        return switch (self) {
            .enabled => "enabled",
            .disabled => "disabled",
            .unavailable => "unavailable",
        };
    }
};

pub const Capability = struct {
    name: CapabilityName,
    state: CapabilityState,
    requested: bool = false,
    artifact: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    stabilizer_config: ?stabilizer.Config = null,
};

pub const Artifact = struct {
    name: []const u8,
    path: []const u8,
};

pub const ProfilingSessionOptions = struct {
    name: []const u8,
    coz_output: ?[]const u8 = null,
    coz_summary: ?[]const u8 = null,
    tracy_output: ?[]const u8 = null,
    tracy_summary: ?[]const u8 = null,
    tracy_summary_options: tracy.summary.Options = .{},
    stabilizer_config: ?stabilizer.Config = null,
    memtrace_summary: ?[]const u8 = null,
    memtrace_events: ?[]const u8 = null,
    perf_artifact: ?[]const u8 = null,
    perf_counter: ?sys.perf.CounterSelector = null,
    perf_counter_options: sys.perf.CounterOptions = .{
        .read_format = sys.perf.ReadFormat.total_time_enabled |
            sys.perf.ReadFormat.total_time_running,
    },
    require_tracy: bool = false,
};

pub const ProfilingReport = struct {
    capabilities: []const Capability,
    artifacts: []const Artifact,
};

pub const ProfilingSession = struct {
    coz_session: CozSession = .{},
    tracy_file: tracy.File = .{},
    tracy_started: bool = false,
    tracy_output: ?[]const u8 = null,
    tracy_summary: ?[]const u8 = null,
    tracy_summary_options: tracy.summary.Options = .{},
    perf_region: ?sys.perf.CounterRegion = null,
    perf_artifact: ?[]const u8 = null,
    perf_result: ?sys.perf.CountResult = null,
    allocator: ?Allocator = null,
    capabilities: [5]Capability = undefined,
    capability_count: usize = 0,
    artifacts: [8]Artifact = undefined,
    artifact_count: usize = 0,

    pub fn start(self: *ProfilingSession, allocator: Allocator, options: ProfilingSessionOptions) !void {
        self.deinit();
        self.reset();
        self.allocator = allocator;
        errdefer self.deinit();

        if (options.coz_output) |path| {
            try ensureParent(path);
            try self.coz_session.startWithOutputPath(allocator, path);
            self.addCapability(.{
                .name = .coz,
                .state = if (self.coz_session.enabled) .enabled else .unavailable,
                .requested = true,
                .artifact = path,
                .reason = if (self.coz_session.enabled) null else "coz runtime unavailable",
            });
            self.addArtifact("coz_output", path);
        } else {
            self.addCapability(.{
                .name = .coz,
                .state = .disabled,
                .reason = "no coz output path configured",
            });
        }
        if (options.coz_summary) |path| self.addArtifact("coz_summary", path);

        if (options.tracy_output) |path| {
            self.tracy_output = path;
            self.tracy_summary = options.tracy_summary;
            self.tracy_summary_options = options.tracy_summary_options;
            if (!tracy.enabled) {
                self.addCapability(.{
                    .name = .tracy,
                    .state = .unavailable,
                    .requested = true,
                    .artifact = path,
                    .reason = "tracy build option disabled",
                });
                if (options.require_tracy) return error.TracyUnavailable;
            } else {
                try ensureParent(path);
                try self.tracy_file.open(path);
                self.tracy_started = try tracy.start(self.tracy_file.interface().?, .{ .name = options.name });
                self.addCapability(.{
                    .name = .tracy,
                    .state = if (self.tracy_started) .enabled else .unavailable,
                    .requested = true,
                    .artifact = path,
                    .reason = if (self.tracy_started) null else "tracy runtime unavailable",
                });
            }
            self.addArtifact("tracy_output", path);
            if (options.tracy_summary) |summary_path| self.addArtifact("tracy_summary", summary_path);
        } else {
            self.addCapability(.{
                .name = .tracy,
                .state = if (tracy.enabled) .disabled else .unavailable,
                .reason = if (tracy.enabled) "no tracy output path configured" else "tracy build option disabled",
            });
        }

        self.addCapability(.{
            .name = .stabilizer,
            .state = if (options.stabilizer_config != null) .enabled else .disabled,
            .requested = options.stabilizer_config != null,
            .reason = if (options.stabilizer_config != null) null else "layout randomization disabled",
            .stabilizer_config = options.stabilizer_config,
        });

        if (options.memtrace_summary) |path| self.addArtifact("memtrace_summary", path);
        if (options.memtrace_events) |path| self.addArtifact("memtrace_events", path);
        self.addCapability(.{
            .name = .memtrace,
            .state = if (options.memtrace_summary != null or options.memtrace_events != null) .enabled else .disabled,
            .requested = options.memtrace_summary != null or options.memtrace_events != null,
            .artifact = options.memtrace_summary orelse options.memtrace_events,
            .reason = if (options.memtrace_summary != null or options.memtrace_events != null) null else "no memtrace artifact configured",
        });

        if (options.perf_artifact) |path| self.addArtifact("perf_counter", path);
        self.perf_artifact = options.perf_artifact;
        if (options.perf_counter) |counter| {
            self.perf_region = sys.perf.CounterRegion.start(counter, options.perf_counter_options) catch |err| {
                self.addCapability(.{
                    .name = .perf,
                    .state = .unavailable,
                    .requested = true,
                    .artifact = options.perf_artifact,
                    .reason = @errorName(err),
                });
                return;
            };
            self.addCapability(.{
                .name = .perf,
                .state = .enabled,
                .requested = true,
                .artifact = options.perf_artifact,
            });
        } else {
            self.addCapability(.{
                .name = .perf,
                .state = .disabled,
                .requested = options.perf_artifact != null,
                .artifact = options.perf_artifact,
                .reason = if (options.perf_artifact != null) "no perf counter configured" else "no perf counter artifact configured",
            });
        }
    }

    pub fn finish(self: *ProfilingSession) !void {
        var first_error: ?anyerror = null;
        self.finishPerfCounter() catch |err| rememberSessionError(&first_error, err);
        const write_tracy_summary = self.tracy_started;
        if (self.tracy_started) {
            tracy.stop();
            self.tracy_started = false;
        }
        self.tracy_file.finish() catch |err| rememberSessionError(&first_error, err);
        if (write_tracy_summary) self.writeTracySummary() catch |err| rememberSessionError(&first_error, err);
        self.coz_session.finish() catch |err| rememberSessionError(&first_error, err);
        if (first_error) |err| return err;
    }

    pub fn deinit(self: *ProfilingSession) void {
        if (self.perf_region) |*region| {
            if (region.active) _ = region.stop() catch {};
            region.deinit();
            self.perf_region = null;
        }
        if (self.tracy_started) {
            tracy.stop();
            self.tracy_started = false;
        }
        self.tracy_file.close();
        self.coz_session.deinit();
    }

    pub fn report(self: *const ProfilingSession) ProfilingReport {
        return .{
            .capabilities = self.capabilities[0..self.capability_count],
            .artifacts = self.artifacts[0..self.artifact_count],
        };
    }

    fn reset(self: *ProfilingSession) void {
        self.capability_count = 0;
        self.artifact_count = 0;
        self.tracy_started = false;
        self.tracy_output = null;
        self.tracy_summary = null;
        self.tracy_summary_options = .{};
        self.perf_region = null;
        self.perf_artifact = null;
        self.perf_result = null;
        self.allocator = null;
    }

    fn addCapability(self: *ProfilingSession, capability: Capability) void {
        self.capabilities[self.capability_count] = capability;
        self.capability_count += 1;
    }

    fn addArtifact(self: *ProfilingSession, name: []const u8, path: []const u8) void {
        self.artifacts[self.artifact_count] = .{ .name = name, .path = path };
        self.artifact_count += 1;
    }

    fn setCapability(self: *ProfilingSession, capability: Capability) void {
        for (self.capabilities[0..self.capability_count]) |*existing| {
            if (existing.name == capability.name) {
                existing.* = capability;
                return;
            }
        }
        self.addCapability(capability);
    }

    fn finishPerfCounter(self: *ProfilingSession) !void {
        var region = self.perf_region orelse return;
        self.perf_region = null;
        defer region.deinit();
        if (!region.active) return;
        const result = region.stop() catch |err| {
            self.setCapability(.{
                .name = .perf,
                .state = .unavailable,
                .requested = true,
                .artifact = self.perf_artifact,
                .reason = @errorName(err),
            });
            return err;
        };
        self.perf_result = result;
        if (self.perf_artifact) |path| try writePerfCounterResultFile(path, result);
    }

    fn writeTracySummary(self: *ProfilingSession) !void {
        const trace_path = self.tracy_output orelse return;
        const summary_path = self.tracy_summary orelse return;
        const allocator = self.allocator orelse return error.ProfilingSessionNotStarted;
        try writeTracySummaryJsonlFile(allocator, summary_path, trace_path, self.tracy_summary_options);
    }
};

pub fn writeProfilingReport(object: pretty_json.Object, report: ProfilingReport) !void {
    const capabilities = try object.array("capabilities");
    for (report.capabilities) |capability| {
        const entry = try capabilities.object();
        try entry.field("name", capability.name.text());
        try entry.field("state", capability.state.text());
        try entry.field("requested", capability.requested);
        try entry.field("artifact", capability.artifact);
        try entry.field("reason", capability.reason);
        if (capability.stabilizer_config) |layout_config| {
            try metadata.writeStabilizerConfig(
                try entry.object("stabilizer_config"),
                layout_config,
            );
        }
        try entry.end();
    }
    try capabilities.end();
    const artifacts = try object.object("artifacts");
    for (report.artifacts) |artifact| {
        try artifacts.field(artifact.name, artifact.path);
    }
    try artifacts.end();
    try object.end();
}

pub fn writePerfCounterResult(object: pretty_json.Object, result: sys.perf.CountResult) !void {
    try object.field("protocol", "bench.perf-counter/v1");
    try object.field("value", result.value);
    try object.field("scaled_value", result.scaledValue());
    try object.field("time_enabled", result.time_enabled);
    try object.field("time_running", result.time_running);
    try object.field("running_coverage", result.runningCoverage().text());
    try object.field("running_ratio", result.runningRatio());
    try object.field("id", result.id);
    try object.field("lost", result.lost);
    try object.end();
}

fn writePerfCounterResultFile(path: []const u8, result: sys.perf.CountResult) !void {
    try ensureParent(path);
    var file = try sys.fs.createFile(path, .{ .truncate = true });
    defer file.close(sys.fs.debugIo());

    var buffer: [8192]u8 = undefined;
    var writer = file.writer(sys.fs.debugIo(), &buffer);
    var stream = pretty_json.Writer.init(&writer.interface, .minified);
    try writePerfCounterResult(try stream.object(), result);
    try stream.newline();
    try writer.interface.flush();
}

fn writeTracySummaryJsonlFile(
    allocator: Allocator,
    path: []const u8,
    trace_path: []const u8,
    options: tracy.summary.Options,
) !void {
    try ensureParent(path);
    var file = try sys.fs.createFile(path, .{ .truncate = true });
    defer file.close(sys.fs.debugIo());

    var buffer: [8192]u8 = undefined;
    var writer = file.writer(sys.fs.debugIo(), &buffer);
    try tracy.summary.writeSummaryJsonlFromJsonlPath(allocator, trace_path, &writer.interface, options);
    try writer.interface.flush();
}

fn rememberSessionError(first_error: *?anyerror, err: anyerror) void {
    if (first_error.* == null) first_error.* = err;
}

fn ensureParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try sys.fs.createDirPath(dir);
    }
}

fn tracyName(comptime name: []const u8) [:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, 0) != null) {
        @compileError("bench phase names must not contain NUL bytes");
    }
    const terminated = name ++ "\x00";
    return terminated[0..name.len :0];
}

pub fn Phase(comptime name: []const u8) type {
    return struct {
        coz_scope: coz.Scope(name),
        tracy_zone: tracy.Zone,

        const Self = @This();

        pub inline fn init(comptime src: SourceLocation) Self {
            return .{
                .coz_scope = coz.scope(name),
                .tracy_zone = tracy.zoneAt(tracyName(name), src),
            };
        }

        pub inline fn setName(self: Self, dynamic_name: []const u8) void {
            self.tracy_zone.setName(dynamic_name);
        }

        pub inline fn setValue(self: Self, value: u64) void {
            self.tracy_zone.setValue(value);
        }

        pub inline fn setText(self: Self, text: []const u8) void {
            self.tracy_zone.setText(text);
        }

        pub inline fn end(self: Self) void {
            self.coz_scope.end();
            self.tracy_zone.end();
        }
    };
}

pub inline fn phaseAt(comptime name: []const u8, comptime src: SourceLocation) Phase(name) {
    return Phase(name).init(src);
}

pub fn rerandomizeLayout(runtime: *?stabilizer.Runtime, comptime progress_name: []const u8) void {
    if (runtime.*) |*active| {
        active.rerandomize();
        coz.progressNamed(progress_name);
    }
}

pub fn callWithStackPad(unit: u8, callback: anytype, args: anytype) @TypeOf(@call(.auto, callback, args)) {
    switch (unit) {
        inline 0...stabilizer.max_stack_pad_unit => |pad_unit| {
            return callWithExactStackPad(@as(usize, pad_unit) * stabilizer.stack_alignment, callback, args);
        },
    }
}

fn callWithExactStackPad(comptime bytes: usize, callback: anytype, args: anytype) @TypeOf(@call(.auto, callback, args)) {
    var pad: [bytes]u8 align(stabilizer.stack_alignment) = undefined;
    touchStackPad(&pad);
    return @call(.auto, callback, args);
}

pub fn touchStackPad(pad: []u8) void {
    for (pad, 0..) |*byte, index| {
        const volatile_byte: *volatile u8 = @ptrCast(byte);
        volatile_byte.* = @truncate(index);
    }
}

test "coz session starts without sampling resources" {
    var session: CozSession = .{};

    try session.startWithOptions(std.testing.allocator, .{
        .install_signal_handler = false,
        .start_current_thread = false,
    });
    defer session.deinit();

    try std.testing.expect(session.enabled);
    try std.testing.expect(session.runtime.profiler_installed);
}

test "coz session writes owned profile output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(std.Options.debug_io, tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "bench.coz.jsonl" });
    defer allocator.free(path);

    var session: CozSession = .{};
    try session.startWithOutputPathAndOptions(allocator, path, .{
        .install_signal_handler = false,
        .start_current_thread = false,
    });
    try std.testing.expect(session.enabled);
    session.deinit();

    const contents = try sys.fs.readFileAlloc(allocator, path, 1024);
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"event\":\"startup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"event\":\"runtime\"") != null);
}

test "coz session rejects invalid sampler configuration" {
    var session: CozSession = .{};

    try std.testing.expectError(error.InvalidSamplePeriod, session.startWithOptions(std.testing.allocator, .{
        .install_signal_handler = false,
        .sampler_options = .{ .sample_period_ns = 0 },
    }));

    try std.testing.expect(!session.enabled);
    try std.testing.expect(!session.runtime.profiler_installed);
}

test "profiling session reports enabled and disabled capabilities" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(std.Options.debug_io, tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const coz_path = try std.fs.path.join(allocator, &.{ root, "bench.coz.jsonl" });
    defer allocator.free(coz_path);
    const coz_summary = try std.fs.path.join(allocator, &.{ root, "bench.coz.analysis.json" });
    defer allocator.free(coz_summary);

    var session: ProfilingSession = .{};
    try session.start(allocator, .{
        .name = "bench test",
        .coz_output = coz_path,
        .coz_summary = coz_summary,
        .stabilizer_config = .{ .seed = 5, .code = .{ .enabled = false } },
    });
    try session.finish();
    session.deinit();

    const report_value = session.report();
    try std.testing.expectEqual(@as(usize, 5), report_value.capabilities.len);
    const coz_capability = report_value.capabilities[0];
    try std.testing.expectEqual(CapabilityName.coz, coz_capability.name);
    switch (coz_capability.state) {
        .enabled => try std.testing.expect(coz_capability.reason == null),
        .unavailable => try std.testing.expect(coz_capability.reason != null),
        .disabled => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CapabilityState.enabled, report_value.capabilities[2].state);
    try std.testing.expectEqual(CapabilityName.stabilizer, report_value.capabilities[2].name);
    try std.testing.expectEqual(@as(u64, 5), report_value.capabilities[2].stabilizer_config.?.seed);
    try std.testing.expectEqual(CapabilityState.disabled, report_value.capabilities[3].state);
    try std.testing.expectEqual(CapabilityName.memtrace, report_value.capabilities[3].name);
    try std.testing.expectEqual(CapabilityState.disabled, report_value.capabilities[4].state);
    try std.testing.expectEqual(CapabilityName.perf, report_value.capabilities[4].name);
    try std.testing.expectEqual(@as(usize, 2), report_value.artifacts.len);
}

test "profiling session reports requested perf artifact without counter as disabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realPathFileAlloc(std.Options.debug_io, tmp.sub_path[0..], allocator);
    defer allocator.free(root);
    const perf_path = try std.fs.path.join(allocator, &.{ root, "bench.perf.json" });
    defer allocator.free(perf_path);

    var session: ProfilingSession = .{};
    try session.start(allocator, .{
        .name = "bench test",
        .perf_artifact = perf_path,
    });
    defer session.deinit();

    const report_value = session.report();
    try std.testing.expectEqual(@as(usize, 5), report_value.capabilities.len);
    const perf_capability = report_value.capabilities[4];
    try std.testing.expectEqual(CapabilityName.perf, perf_capability.name);
    try std.testing.expectEqual(CapabilityState.disabled, perf_capability.state);
    try std.testing.expect(perf_capability.requested);
    try std.testing.expectEqualStrings(perf_path, perf_capability.artifact.?);
    try std.testing.expectEqualStrings("no perf counter configured", perf_capability.reason.?);
    try std.testing.expectEqual(@as(usize, 1), report_value.artifacts.len);
    try std.testing.expectEqualStrings("perf_counter", report_value.artifacts[0].name);
    try session.finish();
}

test "profiling report writes capability rows and artifact paths" {
    const report_value = ProfilingReport{
        .capabilities = &.{
            .{ .name = .coz, .state = .enabled, .requested = true, .artifact = "bench.coz.jsonl" },
            .{ .name = .tracy, .state = .unavailable, .requested = true, .artifact = "bench.tracy.jsonl", .reason = "tracy build option disabled" },
            .{ .name = .stabilizer, .state = .enabled, .requested = true, .stabilizer_config = .{ .seed = 88, .heap = .{ .shuffle_slots = 7 }, .code = .{ .enabled = false } } },
            .{ .name = .memtrace, .state = .disabled, .reason = "no memtrace artifact configured" },
        },
        .artifacts = &.{
            .{ .name = "coz_output", .path = "bench.coz.jsonl" },
            .{ .name = "coz_summary", .path = "bench.coz.analysis.json" },
        },
    };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    try writeProfilingReport(try stream.object(), report_value);

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"coz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"enabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"tracy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"stabilizer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stabilizer_config\":{\"seed\":88") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shuffle_slots\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":{\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"memtrace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"coz_summary\":\"bench.coz.analysis.json\"") != null);
}

test "perf counter result writer records scaled counter fields" {
    const result = sys.perf.CountResult{
        .value = 10,
        .time_enabled = 100,
        .time_running = 50,
        .id = 7,
        .lost = 3,
    };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    try writePerfCounterResult(try stream.object(), result);

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"protocol\":\"bench.perf-counter/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scaled_value\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"time_enabled\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"time_running\":50") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"running_coverage\":\"multiplexed\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "\"running_ratio\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lost\":3") != null);
}

test "perf counter result writer withholds invalid evidence" {
    const result = sys.perf.CountResult{ .value = 10, .time_enabled = 50, .time_running = 100 };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var stream = pretty_json.Writer.init(&out.writer, .minified);
    try writePerfCounterResult(try stream.object(), result);

    const json = out.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scaled_value\":null") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"running_coverage\":\"invalid\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "\"running_ratio\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lost\":null") != null);
}

test "layout rerandomization emits Coz progress" {
    const allocator = std.testing.allocator;
    var profiler: coz.Profiler = .{};
    defer profiler.deinit(allocator);

    coz.installProfiler(allocator, &profiler);
    defer coz.uninstallProfiler(&profiler);

    var runtime: ?stabilizer.Runtime = try stabilizer.Runtime.init(allocator, .{
        .seed = 17,
        .code = .{ .enabled = false },
    });
    defer if (runtime) |*active| active.deinit();

    rerandomizeLayout(&runtime, "bench.test.stabilizer.rerandomize");

    const point = try profiler.registry.getThroughputPoint(allocator, "bench.test.stabilizer.rerandomize");
    try std.testing.expectEqual(@as(usize, 1), point.getCount());
}

test "phase pairs Coz latency with Tracy zone surface" {
    const allocator = std.testing.allocator;
    var profiler: coz.Profiler = .{};
    defer profiler.deinit(allocator);

    coz.installProfiler(allocator, &profiler);
    defer coz.uninstallProfiler(&profiler);

    {
        const phase = phaseAt("bench.test.phase", @src());
        phase.setName("dynamic bench phase");
        phase.setText("phase metadata");
        phase.setValue(123);
        defer phase.end();
    }

    const point = try profiler.registry.getLatencyPoint(allocator, "bench.test.phase");
    try std.testing.expectEqual(@as(usize, 1), point.getBeginCount());
    try std.testing.expectEqual(@as(usize, 1), point.getEndCount());
}

fn testPhaseName(comptime suffix: []const u8) []const u8 {
    return "bench.test." ++ suffix;
}

test "phase accepts comptime constructed names" {
    const allocator = std.testing.allocator;
    var profiler: coz.Profiler = .{};
    defer profiler.deinit(allocator);

    coz.installProfiler(allocator, &profiler);
    defer coz.uninstallProfiler(&profiler);

    {
        const phase = phaseAt(testPhaseName("constructed"), @src());
        defer phase.end();
    }

    const point = try profiler.registry.getLatencyPoint(allocator, "bench.test.constructed");
    try std.testing.expectEqual(@as(usize, 1), point.getBeginCount());
    try std.testing.expectEqual(@as(usize, 1), point.getEndCount());
}
