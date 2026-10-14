//! Head-tree audit of explicit Lake dependencies. Catalog loading stays inert.
const std = @import("std");
const validation = @import("root.zig");
const parse = @import("lake/parse.zig");
const discovery = @import("lake/discovery.zig");

pub const manifest_bytes_max = 64 * 1024;
pub const projects_max = 128;
pub const path_bytes_max = std.fs.max_path_bytes;
pub const requires_max = parse.requires_max;

/// Successful Lake reads plus discovery entries (files and fallback directories).
pub const Work = struct {
    files: usize = 0,
    requires: usize = 0,
    projects: usize = 0,
    listed: usize = 0,
};
pub const Failure = struct {
    recipe: []const u8 = "",
    manifest: []const u8 = "",
    dependency: []const u8 = "",
    coverage: ?validation.plan.CoverageGap = null,
};

const Project = struct { path: []const u8, from: []const u8 };
const Closure = struct {
    projects: [projects_max]Project = undefined,
    count: usize = 0,

    fn add(self: *Closure, path: []const u8, from: []const u8) !void {
        for (self.projects[0..self.count]) |*project| {
            if (!std.mem.eql(u8, project.path, path)) continue;
            return;
        }
        if (self.count == projects_max) return error.LakeProjectsCapacityExceeded;
        self.projects[self.count] = .{ .path = path, .from = from };
        self.count += 1;
    }
};

/// This pass belongs to head planning, never configure or retained base loading.
/// All output slices and intermediate project identities live in `arena`.
pub fn audit(
    arena: std.mem.Allocator,
    tree: validation.source.Tree,
    model: validation.plan.Model,
    failure: *Failure,
) !Work {
    std.debug.assert(std.fs.path.isAbsolute(tree.root));
    std.debug.assert(model.owners.len <= validation.plan.owners_max);
    std.debug.assert(model.recipes.len <= validation.plan.recipes_max);
    var work: Work = .{};
    const any = for (model.recipes) |recipe| {
        if (usesLake(recipe)) break true;
    } else false;
    if (!any) return work;
    for (model.owners, 0..) |owner, owner_index| {
        const first = for (model.recipes) |recipe| {
            if (std.mem.eql(u8, recipe.owner, owner.path) and usesLake(recipe)) break recipe.id;
        } else continue;
        failure.* = .{ .recipe = first };
        var closure: Closure = .{};
        const inventory = tree.inventory orelse try discovery.inventory(arena, tree, owner.path);
        const roots = try discovery.find(arena, tree, model.owners, owner_index, inventory, &work);
        if (roots.len == 0) return error.LakeProjectMissing;
        for (roots) |root| try closure.add(root, "");
        var cursor: usize = 0;
        while (cursor < closure.count) : (cursor += 1) {
            try readProject(arena, tree, &closure, cursor, failure, &work);
        }
        for (model.recipes) |recipe| {
            if (!std.mem.eql(u8, recipe.owner, owner.path) or !usesLake(recipe)) continue;
            for (closure.projects[0..closure.count]) |project| {
                if (validation.plan.coverage(
                    model.owners,
                    owner_index,
                    recipe.id,
                    project.path,
                )) |gap| {
                    failure.* = .{
                        .recipe = recipe.id,
                        .manifest = project.from,
                        .dependency = project.path,
                        .coverage = gap,
                    };
                    return error.LakeDependencyUncovered;
                }
            }
        }
    }
    return work;
}

fn usesLake(recipe: validation.Recipe) bool {
    for (recipe.runtime) |command| if (std.mem.eql(u8, command, "lake")) return true;
    return false;
}

fn readProject(
    arena: std.mem.Allocator,
    tree: validation.source.Tree,
    closure: *Closure,
    index: usize,
    failure: *Failure,
    work: *Work,
) !void {
    std.debug.assert(index < closure.count);
    const project = closure.projects[index].path;
    failure.dependency = project;
    try discovery.safe(arena, tree, project, .directory);
    const toml = try std.fs.path.join(arena, &.{ project, "lakefile.toml" });
    const lean = try std.fs.path.join(arena, &.{ project, "lakefile.lean" });
    const has_toml = try discovery.exists(arena, tree, toml);
    const has_lean = try discovery.exists(arena, tree, lean);
    if (has_toml and has_lean) return error.AmbiguousLakeProject;
    if (!has_toml and !has_lean) return error.LakeProjectMissing;
    const file = if (has_toml) toml else lean;
    failure.manifest = file;
    if (closure.projects[index].from.len == 0) closure.projects[index].from = file;
    const bytes = (try read(arena, tree, file, work)) orelse return error.LakeProjectMissing;
    const requirements = if (has_toml) try parse.toml(bytes) else try parse.lean(bytes);
    work.requires += requirements.requires;
    try extend(arena, tree, closure, project, file, requirements, failure);
    const manifest = try std.fs.path.join(arena, &.{ project, "lake-manifest.json" });
    failure.manifest = manifest;
    if (try read(arena, tree, manifest, work)) |resolved| {
        const packages = try parse.manifest(arena, resolved);
        try extend(arena, tree, closure, project, manifest, packages, failure);
    }
    work.projects += 1;
}

fn read(
    arena: std.mem.Allocator,
    tree: validation.source.Tree,
    path: []const u8,
    work: *Work,
) !?[]const u8 {
    if (!try discovery.exists(arena, tree, path)) return null;
    try discovery.safe(arena, tree, path, .file);
    const bytes = tree.read(arena, path, manifest_bytes_max + 1) catch |err| switch (err) {
        error.StreamTooLong => return error.LakeManifestBytesExceeded,
        else => return err,
    };
    std.debug.assert(bytes.len <= manifest_bytes_max);
    work.files += 1;
    return bytes;
}

fn extend(
    arena: std.mem.Allocator,
    tree: validation.source.Tree,
    closure: *Closure,
    project: []const u8,
    file: []const u8,
    requirements: parse.Result,
    failure: *Failure,
) !void {
    std.debug.assert(requirements.count <= requires_max);
    for (requirements.paths[0..requirements.count]) |literal| {
        failure.dependency = literal;
        if (std.fs.path.isAbsolute(literal) or std.mem.indexOfScalar(u8, literal, 0) != null)
            return error.LakeDependencyOutsideRepository;
        const absolute = try std.fs.path.resolve(arena, &.{ tree.root, project, literal });
        if (!validation.plan.within(tree.root, absolute) or absolute.len <= tree.root.len)
            return error.LakeDependencyOutsideRepository;
        if (absolute.len >= path_bytes_max) return error.LakePathBytesExceeded;
        const relative = absolute[tree.root.len + 1 ..];
        failure.dependency = relative;
        if (!validation.plan.validPath(relative)) return error.InvalidLakeDependency;
        // Inspect the lexical path too: resolving x/../y must not hide x being a symlink.
        try discovery.literal(arena, tree, project, literal);
        try discovery.safe(arena, tree, relative, .directory);
        try closure.add(relative, file);
    }
}
