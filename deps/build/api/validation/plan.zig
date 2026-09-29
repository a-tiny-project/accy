const std = @import("std");
const validation = @import("root.zig");

pub const owners_max = 1024;
pub const recipes_max = 1024;
pub const paths_max = 4096;
pub const declarations_max = 4;

/// Package-owned validation coverage. Dependencies name other declared owners.
/// Declarations name the files outside `path` that declare those dependencies,
/// so an owner owns every file whose edit can change its edges.
pub const Owner = struct {
    path: []const u8,
    dependencies: []const []const u8 = &.{},
    recipes: []const []const u8,
    declarations: []const []const u8 = &.{},
};

pub const Plan = struct {
    owners: std.StaticBitSet(owners_max) = .empty,
    recipes: std.StaticBitSet(recipes_max) = .empty,
    uncovered_path: ?[]const u8 = null,
    uncovered_owner: ?[]const u8 = null,
};

/// Select changed owners and their transitive consumers without guessing checks.
pub fn select(
    owners: []const Owner,
    recipes: []const validation.Recipe,
    paths: []const []const u8,
) !Plan {
    if (owners.len > owners_max or recipes.len > recipes_max or paths.len > paths_max) {
        return error.ValidationPlanCapacityExceeded;
    }
    try validate(owners, recipes);
    var result = Plan{};
    var pending: [owners_max]usize = undefined;
    var count: usize = 0;
    for (paths) |path| {
        if (!validPath(path)) return error.InvalidValidationPath;
        var owned = false;
        if (owning(owners, path)) |index| {
            enqueue(&result, &pending, &count, index);
            owned = true;
        }
        for (owners, 0..) |owner, index| {
            if (!declares(owner, path)) continue;
            enqueue(&result, &pending, &count, index);
            owned = true;
        }
        if (!owned and result.uncovered_path == null) result.uncovered_path = path;
    }
    var cursor: usize = 0;
    while (cursor < count) : (cursor += 1) {
        const changed = owners[pending[cursor]].path;
        for (owners, 0..) |owner, index| {
            if (result.owners.isSet(index)) continue;
            for (owner.dependencies) |dependency| {
                if (std.mem.eql(u8, changed, dependency)) {
                    enqueue(&result, &pending, &count, index);
                    break;
                }
            }
        }
    }
    for (owners, 0..) |owner, index| {
        if (!result.owners.isSet(index)) continue;
        if (owner.recipes.len == 0 and result.uncovered_owner == null) {
            result.uncovered_owner = owner.path;
        }
        for (owner.recipes) |id| result.recipes.set(recipeIndex(recipes, id).?);
    }
    return result;
}

fn enqueue(result: *Plan, pending: *[owners_max]usize, count: *usize, index: usize) void {
    if (result.owners.isSet(index)) return;
    std.debug.assert(count.* < owners_max);
    result.owners.set(index);
    pending[count.*] = index;
    count.* += 1;
}

fn validate(owners: []const Owner, recipes: []const validation.Recipe) !void {
    for (recipes, 0..) |recipe, index| {
        if (recipe.id.len == 0) return error.InvalidValidationRecipe;
        for (recipes[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, recipe.id)) return error.DuplicateValidationRecipe;
        }
    }
    for (owners, 0..) |owner, index| {
        if (!validPath(owner.path)) return error.InvalidValidationOwner;
        if (owner.dependencies.len > owners_max or owner.recipes.len > recipes_max or
            owner.declarations.len > declarations_max)
        {
            return error.ValidationPlanCapacityExceeded;
        }
        for (owner.declarations) |declaration| {
            if (!validPath(declaration) or within(owner.path, declaration)) {
                return error.InvalidValidationOwner;
            }
        }
        for (owners[0..index]) |prior| {
            if (std.mem.eql(u8, prior.path, owner.path)) return error.DuplicateValidationOwner;
        }
        for (owner.dependencies) |dependency| {
            if (ownerIndex(owners, dependency) == null) return error.UnknownValidationDependency;
        }
        for (owner.recipes) |id| {
            const recipe = recipes[
                recipeIndex(recipes, id) orelse
                    return error.UnknownValidationRecipe
            ];
            if (!std.mem.eql(u8, recipe.owner, owner.path)) return error.ValidationOwnerMismatch;
        }
    }
}

fn owning(owners: []const Owner, path: []const u8) ?usize {
    var selected: ?usize = null;
    for (owners, 0..) |owner, index| {
        if (!within(owner.path, path)) continue;
        if (selected == null or owner.path.len > owners[selected.?].path.len) selected = index;
    }
    return selected;
}

pub fn within(parent: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, parent, path) or
        (std.mem.startsWith(u8, path, parent) and path.len > parent.len and path[parent.len] == '/');
}

fn declares(owner: Owner, path: []const u8) bool {
    for (owner.declarations) |declaration| {
        if (std.mem.eql(u8, declaration, path)) return true;
    }
    return false;
}

fn ownerIndex(owners: []const Owner, path: []const u8) ?usize {
    for (owners, 0..) |owner, index| {
        if (std.mem.eql(u8, path, owner.path)) return index;
    }
    return null;
}

fn recipeIndex(recipes: []const validation.Recipe, id: []const u8) ?usize {
    for (recipes, 0..) |recipe, index| {
        if (std.mem.eql(u8, id, recipe.id)) return index;
    }
    return null;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

const fixture_recipes = [_]validation.Recipe{
    fixtureRecipe("lib/core"), fixtureRecipe("lib/client"), fixtureRecipe("tools/app"),
};
const fixture_owners = [_]Owner{
    .{ .path = "lib/core", .recipes = &.{"lib/core"} },
    .{ .path = "lib/client", .dependencies = &.{"lib/core"}, .recipes = &.{"lib/client"} },
    .{ .path = "tools/app", .dependencies = &.{"lib/client"}, .recipes = &.{"tools/app"} },
};

fn fixtureRecipe(owner: []const u8) validation.Recipe {
    return .{
        .id = owner,
        .owner = owner,
        .directory = owner,
        .step = "test",
        .class = "ordinary",
        .test_cwd = "/tmp",
        .declaration = "build/recipes.zig",
        .declaration_sha256 = "",
        .framework_sha256 = "",
        .argv = &.{},
        .runtime = &.{},
        .environment = &.{},
        .suites = &.{},
    };
}

test "validation plan follows consumers but not unrelated dependencies" {
    const leaf = try select(&fixture_owners, &fixture_recipes, &.{"tools/app/src/main.zig"});
    try std.testing.expectEqual(@as(usize, 1), leaf.owners.count());
    try std.testing.expect(leaf.recipes.isSet(2));
    const middle = try select(&fixture_owners, &fixture_recipes, &.{"lib/client/src/root.zig"});
    try std.testing.expectEqual(@as(usize, 2), middle.recipes.count());
    try std.testing.expect(!middle.recipes.isSet(0));
    const core = try select(&fixture_owners, &fixture_recipes, &.{"lib/core/src/root.zig"});
    try std.testing.expectEqual(@as(usize, 3), core.recipes.count());
}

test "validation plan retains missing coverage and respects path components" {
    const absent = try select(&fixture_owners, &fixture_recipes, &.{"lib/corex/src/root.zig"});
    try std.testing.expectEqualStrings("lib/corex/src/root.zig", absent.uncovered_path.?);
    try std.testing.expectEqual(@as(usize, 0), absent.recipes.count());
    var owners = fixture_owners;
    owners[1].recipes = &.{};
    const consumer = try select(&owners, &fixture_recipes, &.{"lib/core/src/root.zig"});
    try std.testing.expectEqualStrings("lib/client", consumer.uncovered_owner.?);
}

test "validation plan uses the deepest declared owner" {
    const owners = fixture_owners ++ [_]Owner{.{ .path = "tools/app/plugin", .recipes = &.{} }};
    const nested = try select(&owners, &fixture_recipes, &.{"tools/app/plugin/src/main.zig"});
    try std.testing.expectEqualStrings("tools/app/plugin", nested.uncovered_owner.?);
    try std.testing.expectEqual(@as(usize, 0), nested.recipes.count());
}

test "validation plan terminates cycles and deduplicates changed paths" {
    var owners = fixture_owners;
    owners[0].dependencies = &.{"tools/app"};
    const result = try select(&owners, &fixture_recipes, &.{ "lib/core/a.zig", "lib/core/a.zig" });
    try std.testing.expectEqual(@as(usize, 3), result.recipes.count());
}

test "validation plan refuses incomplete or conflicting declarations" {
    var owners = fixture_owners;
    owners[0].dependencies = &.{"missing"};
    try std.testing.expectError(error.UnknownValidationDependency, select(&owners, &fixture_recipes, &.{}));
    owners = fixture_owners;
    owners[0].recipes = &.{"missing"};
    try std.testing.expectError(error.UnknownValidationRecipe, select(&owners, &fixture_recipes, &.{}));
    owners[0].recipes = &.{"tools/app"};
    try std.testing.expectError(error.ValidationOwnerMismatch, select(&owners, &fixture_recipes, &.{}));
    owners = fixture_owners;
    owners[1] = owners[0];
    try std.testing.expectError(error.DuplicateValidationOwner, select(&owners, &fixture_recipes, &.{}));
}

test "validation plan does not turn empty changes into required checks" {
    const result = try select(&fixture_owners, &fixture_recipes, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.recipes.count());
    try std.testing.expectEqual(null, result.uncovered_path);
}

test "validation plan bounds changed paths and rejects malformed input" {
    const paths: [paths_max + 1][]const u8 = @splat("lib/core/src/root.zig");
    const result = try select(&fixture_owners, &fixture_recipes, paths[0..paths_max]);
    try std.testing.expectEqual(@as(usize, 3), result.recipes.count());
    try std.testing.expectError(error.ValidationPlanCapacityExceeded, select(&fixture_owners, &fixture_recipes, &paths));
    for ([_][]const u8{ "", "/lib/core", "lib/../core", "lib//core", "lib/./core" }) |path| {
        try std.testing.expectError(error.InvalidValidationPath, select(&fixture_owners, &fixture_recipes, &.{path}));
    }
    const duplicates: [2]validation.Recipe = @splat(fixture_recipes[0]);
    try std.testing.expectError(error.DuplicateValidationRecipe, select(&fixture_owners, &duplicates, &.{}));
}

const registry_recipes = [_]validation.Recipe{
    fixtureRecipe("lib/core"), fixtureRecipe("lib/foo"), registryRecipe(),
};

fn registryRecipe() validation.Recipe {
    var recipe = fixtureRecipe("build/packages");
    recipe.id = "build-packages.test";
    return recipe;
}

fn registry(dependencies: []const []const u8) Owner {
    return .{
        .path = "build/packages",
        .dependencies = dependencies,
        .recipes = &.{"build-packages.test"},
        .declarations = &.{"build.zig.zon"},
    };
}

test "validation plan selects the registry for a root-manifest-only edit" {
    const owners = [_]Owner{
        .{ .path = "lib/core", .recipes = &.{"lib/core"} },
        .{ .path = "lib/foo", .recipes = &.{"lib/foo"} },
        registry(&.{ "lib/core", "lib/foo" }),
    };
    const manifest = try select(&owners, &registry_recipes, &.{"build.zig.zon"});
    try std.testing.expectEqual(@as(usize, 1), manifest.recipes.count());
    try std.testing.expect(manifest.recipes.isSet(2));
    try std.testing.expectEqual(null, manifest.uncovered_path);
    const unowned = try select(&owners, &registry_recipes, &.{"README.md"});
    try std.testing.expectEqualStrings("README.md", unowned.uncovered_path.?);
    try std.testing.expectEqual(@as(usize, 0), unowned.recipes.count());
}

test "validation plan runs the registry when a lane drops a root dependency and edits it" {
    const owners = [_]Owner{
        .{ .path = "lib/core", .recipes = &.{"lib/core"} },
        registry(&.{"lib/core"}),
    };
    const recipes = [_]validation.Recipe{ registry_recipes[0], registry_recipes[2] };
    const result = try select(&owners, &recipes, &.{ "build.zig.zon", "lib/foo/src/root.zig" });
    try std.testing.expect(result.recipes.isSet(1));
    try std.testing.expectEqualStrings("lib/foo/src/root.zig", result.uncovered_path.?);
}

test "validation plan runs a consumer whose own manifest drops an edge" {
    var owners = fixture_owners;
    owners[1].dependencies = &.{};
    const result = try select(&owners, &fixture_recipes, &.{
        "lib/client/build.zig.zon",
        "lib/core/src/root.zig",
    });
    try std.testing.expect(result.recipes.isSet(1));
    try std.testing.expectEqual(@as(usize, 3), result.recipes.count());
}

test "validation plan refuses declarations its owner already owns or cannot bound" {
    var owners = fixture_owners;
    const recipes = &fixture_recipes;
    owners[0].declarations = &.{"lib/core/build.zig.zon"};
    try std.testing.expectError(error.InvalidValidationOwner, select(&owners, recipes, &.{}));
    owners[0].declarations = &.{"../build.zig.zon"};
    try std.testing.expectError(error.InvalidValidationOwner, select(&owners, recipes, &.{}));
    const many: [declarations_max + 1][]const u8 = @splat("build.zig.zon");
    owners[0].declarations = &many;
    try std.testing.expectError(
        error.ValidationPlanCapacityExceeded,
        select(&owners, recipes, &.{}),
    );
}
