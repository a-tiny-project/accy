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
    /// Borrowed sorted NUL membership records from this configure graph only.
    inventory: ?[]const u8 = null,
    failure: ?*Failure = null,
    /// Borrowed for one catalog load. Standalone captures have no snapshot.
    snapshot: ?*Snapshot = null,

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
        if (tree.observer) |observer| {
            if (tree.snapshot) |snapshot| {
                if (!snapshot.first(&snapshot.files_observed, file)) return;
            }
            observer.file(observer.context, file);
        }
    }

    pub fn observeDirectory(tree: Tree, directory: []const u8) void {
        std.debug.assert(std.fs.path.isAbsolute(directory));
        if (tree.observer) |observer| {
            if (tree.snapshot) |snapshot| {
                if (!snapshot.first(&snapshot.directories_observed, directory)) return;
            }
            observer.directory(observer.context, directory);
        }
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

/// Configure-local captures, file hashes and observer membership. All keys and
/// slices live in the caller's arena. The tree must stay fixed for this lifetime.
pub const Snapshot = struct {
    arena: std.mem.Allocator,
    roots: std.StringHashMapUnmanaged([]const model.Source) = .empty,
    files: std.StringHashMapUnmanaged(model.Source) = .empty,
    files_observed: std.StringHashMapUnmanaged(void) = .empty,
    inventory_loaded: bool = false,
    inventory: ?[]const u8 = null,
    directories_observed: std.StringHashMapUnmanaged(void) = .empty,

    fn first(snapshot: *Snapshot, set: *std.StringHashMapUnmanaged(void), path: []const u8) bool {
        const entry = set.getOrPut(snapshot.arena, path) catch @panic("OOM");
        return !entry.found_existing;
    }

    fn root(snapshot: *Snapshot, tree: Tree, path: []const u8) ![]const model.Source {
        if (snapshot.roots.get(path)) |values| return values;
        var values: std.ArrayList(model.Source) = .empty;
        if (!snapshot.inventory_loaded) {
            snapshot.inventory = try inventory(snapshot.arena, tree);
            snapshot.inventory_loaded = true;
        }
        if (snapshot.inventory) |paths| {
            try collectInventory(snapshot.arena, tree, path, paths, &values);
        } else {
            try collect(snapshot.arena, tree, path, &values);
        }
        std.mem.sort(model.Source, values.items, {}, less);
        const captured = try values.toOwnedSlice(snapshot.arena);
        try snapshot.roots.put(snapshot.arena, path, captured);
        return captured;
    }
};

/// Hashes each file below `paths`, sorted by path. A directory contributes
/// the tracked and unignored regular files under it; other kinds refuse.
/// An absent path contributes nothing, so a reader with an older root list
/// hashes the same sources as the tree's own list once a root leaves both the
/// tree and that list. `require` refuses an absent root where the list and the
/// tree come from the same commit.
pub fn capture(
    arena: std.mem.Allocator,
    checkout: Tree,
    paths: []const []const u8,
) ![]const model.Source {
    var local_snapshot: Snapshot = .{ .arena = arena };
    var tree = checkout;
    if (tree.snapshot == null) {
        local_snapshot.inventory = try inventory(arena, tree);
        local_snapshot.inventory_loaded = true;
        tree.snapshot = &local_snapshot;
    }
    var values: std.ArrayList(model.Source) = .empty;
    for (paths) |path| {
        if (tree.snapshot) |snapshot| {
            const captured = try snapshot.root(tree, path);
            if (captured.len > sources_max - values.items.len)
                return error.ValidationFrameworkSourceLimit;
            try values.appendSlice(arena, captured);
        } else {
            try collect(arena, tree, path, &values);
        }
    }
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

const inventory_command_arguments = 9;

/// The canonical snapshot membership query: tracked files, and untracked files
/// no ignore rule matches. Tracked paths remain members when ignore rules match.
/// Each `excluded` entry names a top-level directory the listing leaves out,
/// tracked or not.
pub fn inventoryArguments(
    arena: std.mem.Allocator,
    root: []const u8,
    paths: []const []const u8,
    excluded: []const []const u8,
) ![]const []const u8 {
    std.debug.assert(std.fs.path.isAbsolute(root));
    std.debug.assert(paths.len != 0);
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(arena, &.{
        "git",                "-C", root, "ls-files", "-z", "--cached", "--others",
        "--exclude-standard", "--",
    });
    for (paths) |path| {
        const spec = if (std.mem.eql(u8, path, "."))
            try arena.dupe(u8, ".")
        else
            try std.fmt.allocPrint(arena, ":(top,literal){s}", .{path});
        try arguments.append(arena, spec);
    }
    for (excluded) |directory| {
        std.debug.assert(directory.len != 0);
        std.debug.assert(!std.fs.path.isAbsolute(directory));
        const spec = try std.fmt.allocPrint(arena, ":(top,exclude){s}", .{directory});
        try arguments.append(arena, spec);
    }
    std.debug.assert(arguments.items.len == inventory_command_arguments + paths.len + excluded.len);
    return arguments.toOwnedSlice(arena);
}

/// Frees what `inventoryArguments` allocated. The root stays the caller's.
pub fn freeInventoryArguments(arena: std.mem.Allocator, arguments: []const []const u8) void {
    std.debug.assert(arguments.len > inventory_command_arguments);
    for (arguments[inventory_command_arguments..]) |spec| arena.free(spec);
    arena.free(arguments);
}

pub const inventory_bytes_max = 32 * 1024 * 1024;
pub const inventory_entries_max = 32 * 1024;

/// One bounded listing for a Git checkout, or null for retained-file trees.
pub fn inventoryBytes(arena: std.mem.Allocator, tree: Tree) !?[]const u8 {
    const git = try tree.absolute(arena, ".git");
    _ = std.Io.Dir.cwd().statFile(tree.io, git, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const argv = try inventoryArguments(arena, tree.root, &.{"."}, &.{});
    defer freeInventoryArguments(arena, argv);
    const output = try std.process.run(arena, tree.io, .{
        .argv = argv,
        .stdout_limit = .limited(inventory_bytes_max),
        .stderr_limit = .limited(64 * 1024),
    });
    defer arena.free(output.stderr);
    switch (output.term) {
        .exited => |status| if (status != 0) return error.ValidationInventoryFailed,
        else => return error.ValidationInventoryFailed,
    }
    const paths = try inventoryPaths(arena, output.stdout);
    std.mem.sortUnstable([]const u8, paths, {}, pathLess);
    var sorted: std.ArrayList(u8) = .empty;
    for (paths) |path| {
        try sorted.appendSlice(arena, path);
        try sorted.append(arena, 0);
    }
    arena.free(output.stdout);
    arena.free(paths);
    return try sorted.toOwnedSlice(arena);
}

fn pathLess(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn inventory(arena: std.mem.Allocator, tree: Tree) !?[]const u8 {
    return tree.inventory orelse try inventoryBytes(arena, tree);
}

fn inventoryPaths(arena: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var entries = std.mem.splitScalar(u8, bytes, 0);
    while (entries.next()) |path| {
        if (path.len == 0) continue;
        if (paths.items.len == inventory_entries_max) return error.ValidationInventoryLimit;
        try paths.append(arena, path);
    }
    return paths.toOwnedSlice(arena);
}

/// Searches sorted NUL records without materializing a per-capture index.
fn lowerBound(paths: []const u8, key: []const u8) usize {
    var begin: usize = 0;
    var end = paths.len;
    while (begin < end) {
        var middle = begin + (end - begin) / 2;
        while (middle > begin and paths[middle - 1] != 0) middle -= 1;
        const len = std.mem.indexOfScalar(u8, paths[middle..end], 0).?;
        if (std.mem.lessThan(u8, paths[middle..][0..len], key)) {
            begin = middle + len + 1;
        } else {
            end = middle;
        }
    }
    return begin;
}

fn collectInventory(
    arena: std.mem.Allocator,
    tree: Tree,
    root: []const u8,
    paths: []const u8,
    values: *std.ArrayList(model.Source),
) !void {
    const absolute_root = try tree.absolute(arena, root);
    const root_stat = std.Io.Dir.cwd().statFile(
        tree.io,
        absolute_root,
        .{ .follow_symlinks = false },
    ) catch |err|
        switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    if (root_stat.kind == .directory) tree.observeDirectory(absolute_root);
    const key = if (root_stat.kind == .directory)
        if (std.mem.eql(u8, root, ".")) "" else try std.fmt.allocPrint(arena, "{s}/", .{root})
    else
        root;
    const begin = lowerBound(paths, key);
    var selected = std.mem.splitScalar(u8, paths[begin..], 0);
    while (selected.next()) |path| {
        if (path.len == 0) continue;
        if (root_stat.kind == .directory) {
            if (!std.mem.startsWith(u8, path, key)) break;
        } else if (!std.mem.eql(u8, path, root)) break;
        const source_path = if (key.len == 0)
            try std.fs.path.join(arena, &.{ root, path })
        else
            try arena.dupe(u8, path);
        tree.fail(source_path);
        const absolute = try tree.absolute(arena, source_path);
        const stat = std.Io.Dir.cwd().statFile(
            tree.io,
            absolute,
            .{ .follow_symlinks = false },
        ) catch |err|
            switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
        if (stat.kind != .file) return error.UnsupportedValidationFrameworkSource;
        var parent = std.fs.path.dirname(absolute);
        while (parent) |directory| {
            if (directory.len < absolute_root.len) break;
            tree.observeDirectory(directory);
            parent = std.fs.path.dirname(directory);
        }
        try add(arena, tree, absolute, source_path, values);
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
    const stat = std.Io.Dir.cwd().statFile(
        tree.io,
        absolute,
        .{ .follow_symlinks = false },
    ) catch |err|
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
    if (tree.snapshot) |snapshot| {
        if (snapshot.files.get(path)) |entry| {
            try values.append(arena, entry);
            return;
        }
    }
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
    const entry: model.Source = .{
        .path = path,
        .sha256 = try arena.dupe(u8, &std.fmt.bytesToHex(hash, .lower)),
    };
    if (tree.snapshot) |snapshot| try snapshot.files.put(snapshot.arena, path, entry);
    try values.append(arena, entry);
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

const Observations = struct {
    arena: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(void) = .empty,
    directories: std.StringHashMapUnmanaged(void) = .empty,
    calls: usize = 0,

    fn observer(value: *Observations) Observer {
        return .{ .context = value, .file = file, .directory = directory };
    }

    fn file(context: *anyopaque, path: []const u8) void {
        const value: *Observations = @ptrCast(@alignCast(context));
        value.calls += 1;
        value.files.put(value.arena, path, {}) catch @panic("OOM");
    }

    fn directory(context: *anyopaque, path: []const u8) void {
        const value: *Observations = @ptrCast(@alignCast(context));
        value.calls += 1;
        value.directories.put(value.arena, path, {}) catch @panic("OOM");
    }
};

fn fixtureGit(fixture: *Fixture, arguments: []const []const u8) !void {
    const arena = fixture.arena.allocator();
    const tree = try fixture.tree();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "-C", tree.root });
    try argv.appendSlice(arena, arguments);
    const output = try std.process.run(arena, tree.io, .{ .argv = argv.items });
    switch (output.term) {
        .exited => |status| try std.testing.expectEqual(@as(u8, 0), status),
        else => return error.TestUnexpectedResult,
    }
}
