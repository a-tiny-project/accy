const std = @import("std");
const manifest = @import("root.zig");

/// Enumerate source names during configuration; hashing remains a make-phase job.
/// Directory dependencies invalidate additions, removals and renames. Individual
/// LazyPath file inputs invalidate content edits without rerunning configuration.
pub fn collect(
    b: *std.Build,
    path: std.Build.LazyPath,
    name: []const u8,
    files: *std.ArrayList(manifest.File),
) !void {
    try manifest.model.validatePath(name);
    switch (path) {
        .src_path => |source| try directory(b, source.owner, source.sub_path, name, files),
        .dependency => |source| try directory(
            b,
            source.dependency.builder,
            source.sub_path,
            name,
            files,
        ),
        .cwd_relative => |absolute| {
            if (!std.fs.path.isAbsolute(absolute)) return error.UnqualifiedCompilerSourceDirectory;
            b.dependOnDirectoryContents(path);
            var source = try std.Io.Dir.cwd().openDir(b.graph.io, absolute, .{ .iterate = true });
            defer source.close(b.graph.io);
            try walk(b, source, path, name, files);
        },
        else => return error.UnqualifiedCompilerSourceDirectory,
    }
}

fn directory(
    b: *std.Build,
    owner: *std.Build,
    path: []const u8,
    name: []const u8,
    files: *std.ArrayList(manifest.File),
) !void {
    b.dependOnDirectoryContents(owner.path(path));
    const directory_path = if (path.len == 0) "." else path;
    var source = try owner.root.openDir(b.graph.io, directory_path, .{ .iterate = true });
    defer source.close(b.graph.io);
    try walk(b, source, owner.path(path), name, files);
}

fn walk(
    b: *std.Build,
    source: std.Io.Dir,
    base: std.Build.LazyPath,
    name: []const u8,
    files: *std.ArrayList(manifest.File),
) !void {
    var walker = try source.walk(b.graph.arena);
    defer walker.deinit();
    var visited: u32 = 0;
    while (try walker.next(b.graph.io)) |entry| {
        if (visited == manifest.model.maximum_entries) return error.CompilerInputCountExceeded;
        visited += 1;
        const path = base.path(b, entry.path);
        if (entry.kind == .directory) {
            b.dependOnDirectoryContents(path);
            continue;
        }
        if (entry.kind != .file) return error.UnsupportedCompilerSource;
        try append(b, files, .{
            .identity = .{ .path = b.pathJoin(&.{ name, entry.path }) },
            .path = path,
        });
    }
}

pub fn append(b: *std.Build, files: *std.ArrayList(manifest.File), input: manifest.File) !void {
    if (files.items.len == manifest.model.maximum_entries) return error.CompilerInputCountExceeded;
    try files.append(b.graph.arena, input);
}

pub fn sort(files: []manifest.File) void {
    std.mem.sort(manifest.File, files, {}, less);
}

fn less(_: void, a: manifest.File, b: manifest.File) bool {
    return std.mem.lessThan(u8, a.identity.path, b.identity.path);
}
