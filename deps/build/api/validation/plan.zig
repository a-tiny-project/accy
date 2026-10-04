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
    try std.testing.expectError(
        error.UnknownValidationDependency,
        select(&owners, &fixture_recipes, &.{}),
    );
    owners = fixture_owners;
    owners[0].recipes = &.{"missing"};
    try std.testing.expectError(
        error.UnknownValidationRecipe,
        select(&owners, &fixture_recipes, &.{}),
    );
    owners[0].recipes = &.{"tools/app"};
    try std.testing.expectError(
        error.ValidationOwnerMismatch,
        select(&owners, &fixture_recipes, &.{}),
    );
    owners = fixture_owners;
    owners[1] = owners[0];
    try std.testing.expectError(
        error.DuplicateValidationOwner,
        select(&owners, &fixture_recipes, &.{}),
    );
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
    try std.testing.expectError(
        error.ValidationPlanCapacityExceeded,
        select(&fixture_owners, &fixture_recipes, &paths),
    );
    for ([_][]const u8{ "", "/lib/core", "lib/../core", "lib//core", "lib/./core" }) |path| {
        try std.testing.expectError(
            error.InvalidValidationPath,
            select(&fixture_owners, &fixture_recipes, &.{path}),
        );
    }
    const duplicates: [2]validation.Recipe = @splat(fixture_recipes[0]);
    try std.testing.expectError(
        error.DuplicateValidationRecipe,
        select(&fixture_owners, &duplicates, &.{}),
    );
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

test "validation areas select only touched suites and union multiple areas" {
    const slot = try select(&area_owners, &area_recipes, &.{"tools/app/src/slot/claim.zig"});
    try std.testing.expectEqual(@as(usize, 1), slot.recipes.count());
    try std.testing.expect(slot.recipes.isSet(1));
    const both = try select(&area_owners, &area_recipes, &.{
        "tools/app/src/slots.zig", "tools/app/src/ledger/record.zig", "tools/app/src/slots.zig",
    });
    try std.testing.expectEqual(@as(usize, 2), both.recipes.count());
    try std.testing.expect(both.recipes.isSet(1) and both.recipes.isSet(2));
}

test "validation areas fail closed for unknown paths shared areas and upstream changes" {
    const cases = [_][]const []const u8{
        &.{"tools/app/src/governor/run.zig"},
        &.{"tools/app/src/slotting.zig"},
        &.{ "tools/app/src/slot/claim.zig", "tools/app/build.zig" },
        &.{"lib/core/src/root.zig"},
        &.{ "lib/core/src/root.zig", "tools/app/src/slot/claim.zig" },
    };
    for (cases) |paths| {
        const selected = try select(&area_owners, &area_recipes, paths);
        try std.testing.expect(selected.recipes.isSet(0));
        try std.testing.expect(!selected.recipes.isSet(1) and !selected.recipes.isSet(2));
    }
}

test "validation areas union overlapping path declarations" {
    var owners = area_owners;
    owners[0].areas = &.{
        .{ .paths = &.{"tools/app/src"}, .recipes = &.{"ledger"} },
        .{ .paths = &.{"tools/app/src/slot"}, .recipes = &.{"slot"} },
    };
    const selected = try select(&owners, &area_recipes, &.{"tools/app/src/slot/claim.zig"});
    try std.testing.expectEqual(@as(usize, 2), selected.recipes.count());
    try std.testing.expect(selected.recipes.isSet(1) and selected.recipes.isSet(2));
}

test "validation areas reject missing fallback invalid paths and foreign recipes" {
    var owners = area_owners;
    owners[0].recipes = &.{};
    try std.testing.expectError(
        error.ValidationAreaFallbackMissing,
        select(&owners, &area_recipes, &.{}),
    );
    owners = area_owners;
    for ([_][]const u8{ "", "tools/app/../slot", "tools/appx/src", "lib/core" }) |path| {
        owners[0].areas = &.{.{ .paths = &.{path}, .recipes = &.{"slot"} }};
        try std.testing.expectError(
            error.InvalidValidationArea,
            select(&owners, &area_recipes, &.{}),
        );
    }
    owners[0].areas = &.{.{ .paths = &.{"tools/app/src"}, .recipes = &.{"missing"} }};
    try std.testing.expectError(
        error.UnknownValidationRecipe,
        select(&owners, &area_recipes, &.{}),
    );
    owners[0].areas = &.{.{ .paths = &.{"tools/app/src"}, .recipes = &.{"lib/core"} }};
    try std.testing.expectError(
        error.ValidationOwnerMismatch,
        select(&owners, &area_recipes, &.{}),
    );
}

test "validation areas accept 64 areas and 64 path prefixes and select their recipes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var owners = area_owners;
    var paths: [area_paths_max][]const u8 = undefined;
    for (&paths, 0..) |*path, index| {
        path.* = try std.fmt.allocPrint(arena, "tools/app/src/p{d}", .{index});
    }
    var areas: [areas_max]Area = undefined;
    for (&areas, 0..) |*area, index| area.* = .{
        .paths = paths[index .. index + 1],
        .recipes = &.{"slot"},
    };
    owners[0].areas = &areas;
    const touched = try std.fmt.allocPrint(arena, "{s}/claim.zig", .{paths[paths.len - 1]});
    const many_areas = try select(&owners, &area_recipes, &.{touched});
    try std.testing.expectEqual(@as(usize, 1), many_areas.recipes.count());
    try std.testing.expect(many_areas.recipes.isSet(1));

    owners[0].areas = &.{.{ .paths = &paths, .recipes = &.{"slot"} }};
    const many_paths = try select(&owners, &area_recipes, &.{touched});
    try std.testing.expectEqual(@as(usize, 1), many_paths.recipes.count());
    try std.testing.expect(many_paths.recipes.isSet(1));
}

test "validation areas enforce declaration capacities" {
    var owners = area_owners;
    const area = area_owners[0].areas[0];
    const many_areas: [areas_max + 1]Area = @splat(area);
    owners[0].areas = &many_areas;
    try std.testing.expectError(
        error.ValidationPlanCapacityExceeded,
        select(&owners, &area_recipes, &.{}),
    );
    const many_paths: [area_paths_max + 1][]const u8 = @splat("tools/app/src/slot");
    owners[0].areas = &.{.{ .paths = &many_paths, .recipes = &.{"slot"} }};
    try std.testing.expectError(
        error.ValidationPlanCapacityExceeded,
        select(&owners, &area_recipes, &.{}),
    );
}
