const std = @import("std");
const source = @import("../source.zig");
const plan = @import("../plan.zig");
const lake = @import("../lake.zig");

/// Ask Git only for the Lake owner's source membership. Retained trees use
/// their supplied inventory or the bounded owner-local directory walk.
pub fn inventory(arena: std.mem.Allocator, tree: source.Tree, owner: []const u8) !?[]const u8 {
    if (!try exists(arena, tree, ".git")) return null;
    const argv = try source.inventoryArguments(arena, tree.root, &.{owner}, &.{});
    defer source.freeInventoryArguments(arena, argv);
    const output = try std.process.run(arena, tree.io, .{
        .argv = argv,
        .stdout_limit = .limited(source.inventory_bytes_max),
        .stderr_limit = .limited(64 * 1024),
    });
    defer arena.free(output.stderr);
    switch (output.term) {
        .exited => |status| if (status != 0) return error.ValidationInventoryFailed,
        else => return error.ValidationInventoryFailed,
    }
    return output.stdout;
}

pub fn find(
    arena: std.mem.Allocator,
    tree: source.Tree,
    owners: []const plan.Owner,
    owner_index: usize,
    inventory_bytes: ?[]const u8,
    work: *lake.Work,
) ![]const []const u8 {
    std.debug.assert(owner_index < owners.len);
    const owner = owners[owner_index].path;
    var roots: [lake.projects_max][]const u8 = undefined;
    var count: usize = 0;
    var visited: usize = 0;
    if (inventory_bytes) |bytes| {
        if (bytes.len > source.inventory_bytes_max) return error.ValidationInventoryFailed;
        var records = std.mem.splitScalar(u8, bytes, 0);
        while (records.next()) |path| {
            if (path.len == 0) continue;
            visited += 1;
            if (visited > source.inventory_entries_max) return error.ValidationInventoryFailed;
            if (!plan.within(owner, path)) continue;
            work.listed += 1;
            try candidate(arena, owners, owner_index, path, &roots, &count);
        }
    } else {
        const absolute = try tree.absolute(arena, owner);
        try safe(arena, tree, owner, .directory);
        var dir = try std.Io.Dir.cwd().openDir(tree.io, absolute, .{ .iterate = true });
        defer dir.close(tree.io);
        var walker = try dir.walkSelectively(arena);
        defer walker.deinit();
        defer while (walker.stack.items.len != 0) walker.leave(tree.io);
        while (try walker.next(tree.io)) |entry| {
            visited += 1;
            work.listed += 1;
            if (visited > source.inventory_entries_max) return error.ValidationInventoryFailed;
            if (entry.kind == .directory) {
                if (!generated(entry.basename)) try walker.enter(tree.io, entry);
                continue;
            }
            const path = try std.fs.path.join(arena, &.{ owner, entry.path });
            try candidate(arena, owners, owner_index, path, &roots, &count);
        }
    }
    return arena.dupe([]const u8, roots[0..count]);
}

fn candidate(
    arena: std.mem.Allocator,
    owners: []const plan.Owner,
    owner_index: usize,
    path: []const u8,
    roots: *[lake.projects_max][]const u8,
    count: *usize,
) !void {
    if (!isLakefile(std.fs.path.basename(path))) return;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (generated(part)) return;
    for (owners, 0..) |owner, index| {
        if (index == owner_index) continue;
        if (owner.path.len > owners[owner_index].path.len and plan.within(owner.path, path)) return;
    }
    const parent = std.fs.path.dirname(path) orelse return error.InvalidLakeDependency;
    for (roots[0..count.*]) |root| if (std.mem.eql(u8, root, parent)) return;
    if (count.* == roots.len) return error.LakeProjectsCapacityExceeded;
    roots[count.*] = try arena.dupe(u8, parent);
    count.* += 1;
}

fn isLakefile(name: []const u8) bool {
    return std.mem.eql(u8, name, "lakefile.toml") or std.mem.eql(u8, name, "lakefile.lean");
}

fn generated(name: []const u8) bool {
    for ([_][]const u8{ ".lake", ".git", ".zig-cache", "zig-out" }) |value| {
        if (std.mem.eql(u8, name, value)) return true;
    }
    return false;
}

pub fn exists(arena: std.mem.Allocator, tree: source.Tree, path: []const u8) !bool {
    const absolute = try tree.absolute(arena, path);
    _ = std.Io.Dir.cwd().statFile(tree.io, absolute, .{ .follow_symlinks = false }) catch |err|
        switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    return true;
}

pub fn safe(
    arena: std.mem.Allocator,
    tree: source.Tree,
    path: []const u8,
    kind: std.Io.File.Kind,
) !void {
    std.debug.assert(path.len != 0);
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |_| {
        const end = components.index orelse path.len;
        const prefix = std.mem.trimEnd(u8, path[0..end], "/");
        const absolute = try tree.absolute(arena, prefix);
        const stat = try std.Io.Dir.cwd().statFile(
            tree.io,
            absolute,
            .{ .follow_symlinks = false },
        );
        if (stat.kind == .sym_link) return error.LakeDependencySymlink;
        const expected = if (prefix.len == path.len) kind else .directory;
        if (stat.kind != expected) return error.InvalidLakeDependency;
    }
}

/// Validate each lexical component before normalization can erase it.
pub fn literal(
    arena: std.mem.Allocator,
    tree: source.Tree,
    project: []const u8,
    path: []const u8,
) !void {
    var current = project;
    std.debug.assert(path.len != 0);
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (current.len == 0) return error.LakeDependencyOutsideRepository;
            current = std.fs.path.dirname(current) orelse "";
            continue;
        }
        current = if (current.len == 0) part else try std.fs.path.join(arena, &.{ current, part });
        try safe(arena, tree, current, .directory);
    }
}
