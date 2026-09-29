const std = @import("std");
const pretty = @import("pretty");

const model = @import("provenance_model");

const fs_io = std.Options.debug_io;
const git_output_bytes_max: usize = 64 * 1024;
const writer_buffer_bytes: usize = 4096;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        pretty.diagnostic.writeStderrText(
            "repository provenance: {s}\n",
            .{@errorName(err)},
        );
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 10) return error.InvalidArguments;
    const minimum_source_prefix_bytes = try std.fmt.parseInt(usize, args[2], 10);
    const tiny_commit = init.environ_map.get("TINY_COMMIT");
    const github_sha = init.environ_map.get("GITHUB_SHA");
    const git_revision = if (tiny_commit == null and github_sha == null)
        gitRevision(init)
    else
        "";
    var source_base_storage: [model.source_base_bytes_max]u8 = undefined;
    const resolution = model.resolve(.{
        .fallback_version = args[1],
        .minimum_source_prefix_bytes = minimum_source_prefix_bytes,
        .source_base_storage = &source_base_storage,
        .tiny_commit = tiny_commit,
        .github_sha = github_sha,
        .git_revision = git_revision,
        .tiny_source_base = init.environ_map.get("TINY_SOURCE_BASE"),
        .tiny_version = init.environ_map.get("TINY_VERSION"),
    });
    const values = switch (resolution) {
        .available => |values| values,
        .unavailable => |failure| {
            writeUnavailable(
                failure,
                args[3],
                minimum_source_prefix_bytes,
            );
            return 1;
        },
    };
    try writeModule(args[4], values.revision);
    try writeRevision(args[5], values.revision);
    try writeModule(args[6], values.source_base);
    try writeModule(args[7], values.source_prefix);
    try writeModule(args[8], values.version);
    try writeVersion(args[9], values.version);
    return 0;
}

fn writeUnavailable(
    failure: model.Failure,
    identity_message: []const u8,
    minimum_source_prefix_bytes: usize,
) void {
    switch (failure) {
        .identity_unavailable => pretty.diagnostic.writeStderrText(
            "{s}\n",
            .{identity_message},
        ),
        .version_capacity_exceeded => pretty.diagnostic.writeStderrText(
            "documentation version exceeds the {d}-byte capacity; " ++
                "shorten TINY_VERSION or the root package version\n",
            .{model.version_bytes_max},
        ),
        .source_base_capacity_exceeded => pretty.diagnostic.writeStderrText(
            "TINY_SOURCE_BASE exceeds the {d}-byte documentation " ++
                "source URL capacity\n",
            .{model.source_base_bytes_max},
        ),
        .source_prefix_too_short => pretty.diagnostic.writeStderrText(
            "documentation source URL needs at least {d} bytes before its " ++
                "exact commit; set a longer TINY_SOURCE_BASE\n",
            .{minimum_source_prefix_bytes},
        ),
    }
}

fn gitRevision(init: std.process.Init) []const u8 {
    const result = std.process.run(init.arena.allocator(), init.io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .stdout_limit = .limited(git_output_bytes_max),
        .stderr_limit = .limited(git_output_bytes_max),
    }) catch return "unknown";
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

fn writeModule(path: []const u8, value: []const u8) !void {
    std.debug.assert(path.len > 0);
    const file = try std.Io.Dir.cwd().createFile(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    var buffer: [writer_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(fs_io, &buffer);
    const writer = &file_writer.interface;
    try model.writeStringModule(writer, value);
    try writer.flush();
}

fn writeRevision(path: []const u8, revision: []const u8) !void {
    std.debug.assert(path.len > 0);
    if (!model.validRevision(revision)) return error.InvalidRevision;
    const file = try std.Io.Dir.cwd().createFile(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    var buffer: [writer_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(fs_io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(revision);
    try writer.writeByte('\n');
    try writer.flush();
}

fn writeVersion(path: []const u8, version: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(version.len <= model.version_bytes_max);
    const file = try std.Io.Dir.cwd().createFile(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    var buffer: [writer_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(fs_io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(version);
    try writer.flush();
}
