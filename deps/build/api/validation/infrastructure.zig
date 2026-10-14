const std = @import("std");
const validation = @import("root.zig");
const source = @import("source.zig");
const runtime_extra_max = @import("catalog.zig").runtime_extra_max;

pub const declaration_path = "build/api/validation/infrastructure.zon";
pub const declaration_bytes_max = 1024 * 1024;

/// An owner declares a required recipe (`id`, `step` and `suite` together), or
/// advisory recipes, or both. Only the required recipe covers the owner.
pub const OwnerSpec = struct {
    path: []const u8,
    id: ?[]const u8 = null,
    step: ?[]const u8 = null,
    suite: ?[]const u8 = null,
    /// Recipes that run whenever the owner is selected and stop a landing
    /// when they fail, without covering the owner.
    advisory: []const AdvisorySpec = &.{},
    dependencies: DependencySource,
    /// The owner's measured claim, which the catalog checks as it checks a
    /// package recipe's.
    claim: ?validation.Claim = null,
    /// Exact files this owner claims, taking them from their directory owner.
    declarations: []const []const u8 = &.{},
    /// Additional read dependencies, without changing file ownership.
    inputs: []const []const u8 = &.{},
};

/// One advisory recipe: a root step run by the standard runner, which checks a
/// sealed exit of zero and binds no suite.
pub const AdvisorySpec = struct {
    id: []const u8,
    step: []const u8,
    class: []const u8 = "ordinary",
    /// Commands the step runs beyond zig and git, by their gates bundle names.
    runtime: []const []const u8 = &.{},
};

/// Where an owner's edges come from. `.root_manifest` and `.tool_catalog` take
/// the edges that file declares and claim the file. `.none` takes no edges: the
/// owner selects on its own path, its `.declarations` and its `.inputs` only.
pub const DependencySource = enum { root_manifest, tool_catalog, none };

pub const Catalog = struct {
    recipes: []const validation.Recipe,
    sources: []const validation.Source,
    source_roots: []const []const u8,
    owners: []const validation.plan.Owner,
    dependency_sources: []const DependencySource,
};

const Manifest = struct {
    root_options: []const []const u8,
    owners: []const OwnerSpec,
};

const source_roots = [_][]const u8{
    "build.zig",
    "build.zig.zon",
    "toolcatalogtest.zig",
    "build/root.zig",
    "build/api/build.zig",
    "build/api/build.zig.zon",
    "build/api/runner.zig",
    "build/api/src",
    "build/api/validation",
    "build/packages/audit/register",
    "build/packages/register.zig",
    "build/packages/root.zig",
    "build/tools/package/catalog.zon",
    "build/tools/package/register.zig",
    "build/tools/package/root.zig",
};

/// Loads the infrastructure owners, or null when the tree declares none.
/// Their roots may not overlap each other or any package owner.
pub fn load(
    arena: std.mem.Allocator,
    tree: source.Tree,
    package_roots: []const validation.plan.Owner,
) !?Catalog {
    const absolute = try tree.absolute(arena, declaration_path);
    tree.observeDirectory(std.fs.path.dirname(absolute).?);
    const bytes = (try tree.readOptional(arena, declaration_path, declaration_bytes_max)) orelse
        return null;
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = try std.zon.parse.fromSlice(Manifest, .{
        .gpa = arena,
        .arena = arena,
        .source = bytes,
        .diagnostics = &diagnostics,
    });
    const package_paths = try arena.alloc([]const u8, package_roots.len);
    for (package_roots, package_paths) |package, *path| path.* = package.path;
    try validateRoots(manifest.owners, package_paths);
    const sources = try source.capture(arena, tree, &source_roots);
    const declaration_hash = for (sources) |entry| {
        if (std.mem.eql(u8, entry.path, declaration_path)) break entry.sha256;
    } else return error.MissingInfrastructureDeclaration;
    const framework_hash = try arena.dupe(u8, &validation.sourceDigest(sources));
    var recipe_count: usize = 0;
    for (manifest.owners) |spec| recipe_count += @intFromBool(spec.id != null) + spec.advisory.len;
    const recipes = try arena.alloc(validation.Recipe, recipe_count);
    const owners = try arena.alloc(validation.plan.Owner, manifest.owners.len);
    const dependency_sources = try arena.alloc(DependencySource, manifest.owners.len);
    const normalized_base: []const []const u8 = &.{
        "build",
        "--build-file",
        "/workspace/build.zig",
        "--cache-dir",
        "/tmp/zig-local",
        "--prefix",
        "/tmp/zig-out",
        "-Doptimize=Debug",
        "-Dproduct-backend=native",
        "-Dvalidation-dir=/output",
        "-j1",
    };
    const standard_base: []const []const u8 = &.{
        "build", "--build-file", "build.zig", "-Doptimize=Debug", "-Dproduct-backend=native",
    };
    const normalized_argv = try std.mem.concat(
        arena,
        []const u8,
        &.{ normalized_base, manifest.root_options },
    );
    const standard_argv = try std.mem.concat(
        arena,
        []const u8,
        &.{ standard_base, manifest.root_options },
    );
    var cursor: usize = 0;
    for (manifest.owners, owners, dependency_sources) |spec, *owner, *dependency_source| {
        dependency_source.* = spec.dependencies;
        var identity: validation.Recipe = .{
            .id = "",
            .owner = spec.path,
            .directory = ".",
            .step = "",
            .class = "ordinary",
            .test_cwd = "",
            .declaration = declaration_path,
            .declaration_sha256 = declaration_hash,
            .framework_sha256 = framework_hash,
            .argv = &.{},
            .runtime = &.{ "zig", "git" },
            .environment = &.{},
            .suites = &.{},
        };
        var required: []const []const u8 = &.{};
        if (spec.id) |id| {
            identity.argv = normalized_argv;
            recipes[cursor] = try requiredRecipe(arena, identity, spec);
            cursor += 1;
            required = try arena.dupe([]const u8, &.{id});
        }
        identity.argv = standard_argv;
        const advisory = try arena.alloc([]const u8, spec.advisory.len);
        for (spec.advisory, advisory) |entry, *id| {
            recipes[cursor] = try advisoryRecipe(arena, identity, entry);
            cursor += 1;
            id.* = entry.id;
        }
        owner.* = .{
            .path = spec.path,
            .recipes = required,
            .advisory = advisory,
            .declarations = spec.declarations,
            .inputs = spec.inputs,
        };
    }
    std.debug.assert(cursor == recipes.len);
    _ = try validation.plan.select(
        .{ .owners = owners, .recipes = recipes, .runtime_inputs = &.{} },
        &.{},
    );
    return .{
        .recipes = recipes,
        .owners = owners,
        .sources = sources,
        .source_roots = &source_roots,
        .dependency_sources = dependency_sources,
    };
}

/// The owner's required recipe: its bound suite under the normalized runner.
fn requiredRecipe(
    arena: std.mem.Allocator,
    identity: validation.Recipe,
    spec: OwnerSpec,
) !validation.Recipe {
    const name = spec.suite.?;
    const suite = try arena.alloc(validation.Suite, 1);
    suite[0] = .{
        .id = name,
        .backend = "native",
        .selection_artifact = try std.fmt.allocPrint(arena, "{s}.selection.json", .{name}),
        .result_artifact = try std.fmt.allocPrint(arena, "{s}.result.json", .{name}),
    };
    var recipe = identity;
    recipe.id = spec.id.?;
    recipe.step = spec.step.?;
    recipe.test_cwd = "/tmp";
    recipe.environment = &.{
        .{ .name = "HOME", .value = "/tmp" },
        .{ .name = "TMPDIR", .value = "/tmp" },
        .{ .name = "ZIG_GLOBAL_CACHE_DIR", .value = "/tmp/zig-global" },
        .{ .name = "ZIG_LOCAL_CACHE_DIR", .value = "/tmp/zig-child" },
        .{ .name = "ZIG_DEBUG_CMD", .value = "1" },
        .{ .name = "LANG", .value = "C" },
        .{ .name = "TZ", .value = "UTC" },
        .{ .name = "NO_COLOR", .value = "1" },
    };
    recipe.suites = suite;
    recipe.claim = spec.claim;
    return recipe;
}

/// One advisory recipe: a root step on the standard route.
fn advisoryRecipe(
    arena: std.mem.Allocator,
    identity: validation.Recipe,
    entry: AdvisorySpec,
) !validation.Recipe {
    var recipe = identity;
    recipe.id = entry.id;
    recipe.step = entry.step;
    recipe.class = entry.class;
    recipe.runner = .standard;
    recipe.test_cwd = ".";
    recipe.runtime = try std.mem.concat(arena, []const u8, &.{ identity.runtime, entry.runtime });
    return recipe;
}

pub fn validateRoots(specs: []const OwnerSpec, package_roots: []const []const u8) !void {
    for (specs, 0..) |spec, index| {
        const required = spec.id != null;
        if (required != (spec.step != null) or required != (spec.suite != null) or
            (!required and (spec.advisory.len == 0 or spec.claim != null)))
        {
            return error.InvalidInfrastructureOwner;
        }
        if (required and
            (spec.id.?.len == 0 or spec.step.?.len == 0 or spec.suite.?.len == 0))
        {
            return error.InvalidInfrastructureOwner;
        }
        for (spec.advisory) |entry| {
            if (entry.id.len == 0 or entry.step.len == 0 or entry.class.len == 0 or
                entry.runtime.len > runtime_extra_max)
            {
                return error.InvalidInfrastructureOwner;
            }
        }
        if (std.mem.eql(u8, spec.path, ".") or std.mem.eql(u8, spec.path, "build") or
            std.mem.eql(u8, spec.path, "build/") or
            !validPath(spec.path)) return error.InvalidInfrastructureOwner;
        for (specs[0..index]) |prior| {
            if (overlaps(spec.path, prior.path)) return error.OverlappingInfrastructureOwner;
        }
        for (package_roots) |package_root| {
            if (overlaps(spec.path, package_root)) return error.InfrastructureOverlapsPackage;
        }
    }
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or
            std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    return std.mem.startsWith(u8, a, b) and a.len > b.len and a[b.len] == '/' or
        std.mem.startsWith(u8, b, a) and b.len > a.len and b[a.len] == '/';
}
