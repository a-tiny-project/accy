const std = @import("std");
const digest = @import("digest.zig");
const model = @import("model.zig");

pub const sources_max = 1024;
pub const source_bytes_max = 4 * 1024 * 1024;

/// A repository checkout the catalog loader reads. A build passes an observer,
/// which sees each file and directory a load reads, so the build can declare
/// them as configure inputs. A run-time load passes none.
pub const Tree = struct {
    io: std.Io,
    /// Absolute and resolved, so owner paths come out repository-relative.
    root: []const u8,
    observer: ?Observer = null,
    failure: ?*Failure = null,

    pub fn absolute(tree: Tree, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        std.debug.assert(std.fs.path.isAbsolute(tree.root));
        std.debug.assert(path.len != 0);
        std.debug.assert(!std.fs.path.isAbsolute(path));
        return std.fs.path.join(arena, &.{ tree.root, path });
    }

    /// Reads a file below the root within `limit` bytes, then reports it.
    pub fn read(tree: Tree, arena: std.mem.Allocator, path: []const u8, limit: usize) ![:0]u8 {
        return (try tree.readOptional(arena, path, limit)) orelse {
            tree.fail(path);
            return error.FileNotFound;
        };
    }

    /// Like `read`, except that an absent file is null and is not reported.
    pub fn readOptional(
        tree: Tree,
        arena: std.mem.Allocator,
        path: []const u8,
        limit: usize,
    ) !?[:0]u8 {
        std.debug.assert(limit != 0);
        tree.fail(path);
        const file = try tree.absolute(arena, path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            tree.io,
            file,
            arena,
            .limited(limit),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        tree.observeFile(file);
        return try arena.dupeSentinel(u8, bytes, 0);
    }

    pub fn observeFile(tree: Tree, file: []const u8) void {
        std.debug.assert(std.fs.path.isAbsolute(file));
        if (tree.observer) |observer| observer.file(observer.context, file);
    }

    pub fn observeDirectory(tree: Tree, directory: []const u8) void {
        std.debug.assert(std.fs.path.isAbsolute(directory));
        if (tree.observer) |observer| observer.directory(observer.context, directory);
    }

    /// Notes the repository path a load is about to touch, so a refusal can
    /// name the file that caused it.
    pub fn fail(tree: Tree, path: []const u8) void {
        if (tree.failure) |failure| failure.note(path);
    }
};

pub const Observer = struct {
    context: *anyopaque,
    file: *const fn (context: *anyopaque, path: []const u8) void,
    directory: *const fn (context: *anyopaque, path: []const u8) void,
};

/// The repository path a failed load touched last.
pub const Failure = struct {
    bytes: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn note(failure: *Failure, touched: []const u8) void {
        const count = @min(touched.len, failure.bytes.len);
        @memcpy(failure.bytes[0..count], touched[0..count]);
        failure.len = count;
    }

    pub fn path(failure: *const Failure) []const u8 {
        std.debug.assert(failure.len <= failure.bytes.len);
        return failure.bytes[0..failure.len];
    }
};

/// Hashes each file below `paths`, sorted by path. A directory contributes
/// every regular file under it, and any other kind of entry refuses. An absent
/// path contributes nothing, so a reader compiled with an older root list
/// hashes the same sources as the tree's own list once a root leaves both the
/// tree and that list. `require` refuses an absent root where the list and the
/// tree come from the same commit.
pub fn capture(
    arena: std.mem.Allocator,
    tree: Tree,
    paths: []const []const u8,
) ![]const model.Source {
    var values: std.ArrayList(model.Source) = .empty;
    for (paths) |path| try collect(arena, tree, path, &values);
    std.mem.sort(model.Source, values.items, {}, less);
    std.debug.assert(values.items.len <= sources_max);
    return values.toOwnedSlice(arena);
}

/// Refuses the first of `paths` that is absent from the tree, and names it
/// through the tree's failure note.
pub fn require(arena: std.mem.Allocator, tree: Tree, paths: []const []const u8) !void {
    for (paths) |path| {
        tree.fail(path);
        const absolute = try tree.absolute(arena, path);
        _ = std.Io.Dir.cwd().statFile(tree.io, absolute, .{ .follow_symlinks = false }) catch |err|
            switch (err) {
                error.FileNotFound => return error.MissingValidationFrameworkSource,
                else => return err,
            };
    }
}

fn collect(
    arena: std.mem.Allocator,
    tree: Tree,
    path: []const u8,
    values: *std.ArrayList(model.Source),
) !void {
    tree.fail(path);
    const absolute = try tree.absolute(arena, path);
    const stat = std.Io.Dir.cwd().statFile(tree.io, absolute, .{ .follow_symlinks = false }) catch |err|
        switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    if (stat.kind == .file) return add(arena, tree, absolute, path, values);
    if (stat.kind != .directory) return error.UnsupportedValidationFrameworkSource;
    tree.observeDirectory(absolute);
    var directory = try std.Io.Dir.cwd().openDir(tree.io, absolute, .{ .iterate = true });
    defer directory.close(tree.io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    var visited: usize = 0;
    while (try walker.next(tree.io)) |entry| {
        if (visited == sources_max) return error.ValidationFrameworkSourceLimit;
        visited += 1;
        const child = try std.fs.path.join(arena, &.{ absolute, entry.path });
        if (entry.kind == .directory) {
            tree.observeDirectory(child);
            continue;
        }
        const child_path = try std.fs.path.join(arena, &.{ path, entry.path });
        tree.fail(child_path);
        if (entry.kind != .file) return error.UnsupportedValidationFrameworkSource;
        try add(arena, tree, child, child_path, values);
    }
}

fn add(
    arena: std.mem.Allocator,
    tree: Tree,
    absolute: []const u8,
    path: []const u8,
    values: *std.ArrayList(model.Source),
) !void {
    if (values.items.len == sources_max) return error.ValidationFrameworkSourceLimit;
    tree.observeFile(absolute);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        tree.io,
        absolute,
        arena,
        .limited(source_bytes_max),
    );
    defer arena.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    try values.append(arena, .{
        .path = path,
        .sha256 = try arena.dupe(u8, &std.fmt.bytesToHex(hash, .lower)),
    });
}

fn less(_: void, a: model.Source, b: model.Source) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

const Fixture = struct {
    temporary: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    failure: Failure = .{},

    fn init() Fixture {
        return .{
            .temporary = std.testing.tmpDir(.{}),
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena.deinit();
        fixture.temporary.cleanup();
        fixture.* = undefined;
    }

    fn write(fixture: *Fixture, path: []const u8, data: []const u8) !void {
        try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn tree(fixture: *Fixture) !Tree {
        const root = try fixture.temporary.dir.realPathFileAlloc(
            std.testing.io,
            ".",
            fixture.arena.allocator(),
        );
        return .{ .io = std.testing.io, .root = root, .failure = &fixture.failure };
    }
};

test "capture skips an absent root and a deleted root changes the digest" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const arena = fixture.arena.allocator();
    try fixture.write("kept.zig", "// kept\n");
    try fixture.write("leaving.tsv", "lane\n");
    const tree = try fixture.tree();
    const roots: []const []const u8 = &.{ "kept.zig", "leaving.tsv" };

    const kept = digest.sources(try capture(arena, tree, &.{"kept.zig"}));
    const present = digest.sources(try capture(arena, tree, roots));
    try std.testing.expect(!std.mem.eql(u8, &kept, &present));

    try fixture.temporary.dir.deleteFile(std.testing.io, "leaving.tsv");
    const absent = digest.sources(try capture(arena, tree, roots));
    try std.testing.expectEqualSlices(u8, &kept, &absent);
}

test "require names the first absent root" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    const arena = fixture.arena.allocator();
    try fixture.write("kept.zig", "// kept\n");
    const tree = try fixture.tree();

    try require(arena, tree, &.{"kept.zig"});
    try std.testing.expectError(
        error.MissingValidationFrameworkSource,
        require(arena, tree, &.{ "kept.zig", "leaving.tsv" }),
    );
    try std.testing.expectEqualStrings("leaving.tsv", fixture.failure.path());
}
