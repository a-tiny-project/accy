const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("validation");
const model = if (options.model_namespace.len == 0)
    protocol
else
    @field(protocol, options.model_namespace);
const io = std.Options.debug_io;
const options = @import("validation_binding");

const binding: model.Binding = .{
    .recipe_id = options.recipe_id,
    .recipe_sha256 = options.recipe_sha256,
    .suite_id = options.suite_id,
    .class = options.class,
    .token = options.token,
    .backend = options.backend,
    .compiler_backend = @tagName(builtin.zig_backend),
    .zig_version = builtin.zig_version_string,
    .target = model.host_target,
    .optimize = switch (builtin.mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    },
};

pub fn prepare(init: std.process.Init.Minimal) !void {
    var arguments = std.process.Args.Iterator.init(init.args);
    _ = arguments.next();
    if (arguments.next() != null) return error.ValidationRunnerArgumentsUnsupported;
    for ([_][]const u8{
        "FILTER",           "ALLOW_EMPTY_FILTER", "REPEAT",         "SHARD_COUNT", "SHARD_INDEX",
        "SHARD_SOCKET",     "SHARD_CHILD",        "EXTERNAL_SHARD", "SHARD_PORT",  "SUPERVISED",
        "SUPERVISOR_CHILD", "SUPERVISOR_ORDER",
    }) |suffix| {
        var name: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&name, "TINY_TIMING_RUNNER_{s}", .{suffix});
        if (std.process.Environ.getPosix(init.environ, key) != null) {
            return error.ValidationRunnerEnvironmentUnsupported;
        }
    }
}

pub fn selected(names: []const []const u8) !void {
    std.debug.assert(names.len <= model.max_tests);
    var behavioral: u32 = 0;
    for (names) |name| if (model.behavioral(name)) {
        behavioral += 1;
    };
    const hash = model.selectionDigest(binding, names);
    try writeArtifact(options.selection_artifact, model.Selection{
        .binding = binding,
        .selected_test_count = @intCast(names.len),
        .selected_behavioral_test_count = behavioral,
        .selection_sha256 = &hash,
        .tests = names,
    });
}

pub fn completed(rows: anytype) !void {
    std.debug.assert(rows.len <= model.max_tests);
    var names: [model.max_tests][]const u8 = undefined;
    var results: [model.max_tests]model.Row = undefined;
    var value = resultCounts(rows);
    for (rows, 0..) |row, index| {
        names[index] = row.name;
        results[index] = .{
            .name = row.name,
            .status = switch (row.status) {
                inline else => |status| @field(model.Status, @tagName(status)),
            },
            .leaked = row.leaked,
        };
    }
    const selected_hash = model.selectionDigest(binding, names[0..rows.len]);
    const result_hash = model.resultDigest(binding, &selected_hash, results[0..rows.len]);
    value.selection_sha256 = &selected_hash;
    value.result_sha256 = &result_hash;
    value.tests = results[0..rows.len];
    try writeArtifact(options.result_artifact, value);
    if (value.completed_behavioral_test_count == 0 or value.passed_behavioral_test_count == 0) {
        return error.NoCompletedBehavioralTests;
    }
}

fn resultCounts(rows: anytype) model.Result {
    var value: model.Result = .{
        .binding = binding,
        .selection_sha256 = "",
        .result_sha256 = "",
        .completed_test_count = @intCast(rows.len),
        .completed_behavioral_test_count = 0,
        .passed_behavioral_test_count = 0,
        .skipped_test_count = 0,
        .failed_test_count = 0,
        .leaked_test_count = 0,
        .tests = &.{},
    };
    for (rows) |row| {
        const behavioral = model.behavioral(row.name);
        if (behavioral and row.status != .skip) value.completed_behavioral_test_count += 1;
        if (behavioral and row.status == .ok and !row.leaked) {
            value.passed_behavioral_test_count += 1;
        }
        if (row.status == .skip) value.skipped_test_count += 1;
        if (row.status == .fail or row.status == .fail_leak) {
            value.failed_test_count += 1;
        }
        if (row.leaked) value.leaked_test_count += 1;
    }
    return value;
}

fn writeArtifact(name: []const u8, value: anytype) !void {
    try std.Io.Dir.cwd().createDirPath(io, options.directory);
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "{s}/{s}", .{ options.directory, name });
    var pending_storage: [std.fs.max_path_bytes]u8 = undefined;
    const pending = try std.fmt.bufPrint(&pending_storage, "{s}.pending", .{path});
    defer std.Io.Dir.cwd().deleteFile(io, pending) catch {};
    var file = try std.Io.Dir.cwd().createFile(io, pending, .{ .truncate = true });
    var open = true;
    defer if (open) file.close(io);
    var buffer: [32 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try std.json.Stringify.value(value, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    file.close(io);
    open = false;
    // The directory may be relative to the working directory of a local build.
    try std.Io.Dir.cwd().rename(pending, std.Io.Dir.cwd(), path, io);
}
