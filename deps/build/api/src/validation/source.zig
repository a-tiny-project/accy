const std = @import("std");
const validation = @import("../../validation/root.zig");

/// The repository at `repository` from this build's root, as the loader reads
/// it. Every file and directory a load reads becomes a configure input.
pub fn tree(
    b: *std.Build,
    repository: []const u8,
    failure: *validation.source.Failure,
) validation.source.Tree {
    std.debug.assert(repository.len != 0);
    const cwd = std.process.currentPathAlloc(b.graph.io, b.allocator) catch @panic("OOM");
    const relative = b.root.joinString(b.allocator, repository) catch @panic("OOM");
    const root = std.fs.path.resolve(b.allocator, &.{ cwd, relative }) catch @panic("OOM");
    std.debug.assert(std.fs.path.isAbsolute(root));
    return .{
        .io = b.graph.io,
        .root = root,
        .observer = .{ .context = b, .file = dependOnFile, .directory = dependOnDirectory },
        .failure = failure,
    };
}

pub fn capture(
    b: *std.Build,
    repository: []const u8,
    paths: []const []const u8,
) []const validation.Source {
    var failure: validation.source.Failure = .{};
    const checkout = tree(b, repository, &failure);
    return validation.source.capture(b.allocator, checkout, paths) catch |err| {
        std.debug.panic("validation framework source {s}: {s}", .{
            failure.path(),
            @errorName(err),
        });
    };
}

fn dependOnFile(context: *anyopaque, path: []const u8) void {
    const b: *std.Build = @ptrCast(@alignCast(context));
    b.dependOnFileContents(b.graph.cwdRelativePath(path));
}

fn dependOnDirectory(context: *anyopaque, path: []const u8) void {
    const b: *std.Build = @ptrCast(@alignCast(context));
    b.dependOnDirectoryContents(b.graph.cwdRelativePath(path));
}
