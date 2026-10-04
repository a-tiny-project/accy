const std = @import("std");
const validation = @import("root.zig");

pub const owners_max = 1024;
pub const recipes_max = 1024;
pub const paths_max = 4096;
pub const declarations_max = 4;
pub const areas_max = 64;
pub const area_paths_max = 64;

/// Repository-relative path prefixes and the recipes that cover that area.
pub const Area = struct {
    paths: []const []const u8,
    recipes: []const []const u8,
};

/// Package-owned validation coverage. Dependencies name other declared owners.
/// Declarations name the files outside `path` that declare those dependencies,
/// so an owner owns every file whose edit can change its edges.
pub const Owner = struct {
    path: []const u8,
    dependencies: []const []const u8 = &.{},
    recipes: []const []const u8,
    declarations: []const []const u8 = &.{},
    /// Direct changes select matching areas. An unclassified path or a changed
    /// dependency selects `recipes`, the owner's complete fallback coverage.
    areas: []const Area = &.{},
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
        selectOwner(&result, owners, recipes, paths, index);
    }
    return result;
}

fn selectOwner(
    result: *Plan,
    owners: []const Owner,
    recipes: []const validation.Recipe,
    paths: []const []const u8,
    index: usize,
) void {
    const owner = owners[index];
    if (owner.areas.len == 0) {
        for (owner.recipes) |id| result.recipes.set(recipeIndex(recipes, id).?);
        return;
    }
    var selected: std.StaticBitSet(recipes_max) = .empty;
    var direct = false;
    for (paths) |path| {
        if (owning(owners, path) != index and !declares(owner, path)) continue;
        direct = true;
        var classified = false;
        for (owner.areas) |area| {
            for (area.paths) |prefix| {
                if (!within(prefix, path)) continue;
                classified = true;
                for (area.recipes) |id| selected.set(recipeIndex(recipes, id).?);
                break;
            }
        }
        if (!classified) {
            for (owner.recipes) |id| result.recipes.set(recipeIndex(recipes, id).?);
            return;
        }
    }
    // A directly changed consumer can also be affected through a dependency.
    // Areas describe source edits, not the impact of an upstream interface.
    for (owner.dependencies) |dependency| {
        if (result.owners.isSet(ownerIndex(owners, dependency).?)) direct = false;
    }
    if (direct) {
        result.recipes.setUnion(selected);
    } else {
        for (owner.recipes) |id| result.recipes.set(recipeIndex(recipes, id).?);
    }
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
            owner.declarations.len > declarations_max or owner.areas.len > areas_max)
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
        if (owner.areas.len != 0 and owner.recipes.len == 0) {
            return error.ValidationAreaFallbackMissing;
        }
        for (owner.areas) |area| {
            if (area.paths.len == 0 or area.recipes.len == 0) return error.InvalidValidationArea;
            if (area.paths.len > area_paths_max or area.recipes.len > recipes_max) {
                return error.ValidationPlanCapacityExceeded;
            }
            for (area.paths) |path| {
                if (!validPath(path) or !within(owner.path, path)) {
                    return error.InvalidValidationArea;
                }
            }
            for (area.recipes) |id| {
                const recipe =
                    recipes[recipeIndex(recipes, id) orelse return error.UnknownValidationRecipe];
                if (!std.mem.eql(u8, recipe.owner, owner.path)) {
                    return error.ValidationOwnerMismatch;
                }
            }
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
        (std.mem.startsWith(u8, path, parent) and path.len > parent.len and
            path[parent.len] == '/');
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
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return false;
        }
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

const area_recipes = [_]validation.Recipe{
    areaRecipe("full"), areaRecipe("slot"), areaRecipe("ledger"), fixtureRecipe("lib/core"),
};

fn areaRecipe(id: []const u8) validation.Recipe {
    var recipe = fixtureRecipe("tools/app");
    recipe.id = id;
    return recipe;
}

const area_owners = [_]Owner{
    .{
        .path = "tools/app",
        .recipes = &.{"full"},
        .dependencies = &.{"lib/core"},
        .areas = &.{
            .{
                .paths = &.{ "tools/app/src/slot", "tools/app/src/slots.zig" },
                .recipes = &.{"slot"},
            },
            .{ .paths = &.{"tools/app/src/ledger"}, .recipes = &.{"ledger"} },
            .{ .paths = &.{"tools/app/src/governor"}, .recipes = &.{"full"} },
        },
    },
    .{ .path = "lib/core", .recipes = &.{"lib/core"} },
};
