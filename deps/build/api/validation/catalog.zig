const std = @import("std");
const validation = @import("root.zig");
const infrastructure = @import("infrastructure.zig");
const manifest = @import("manifest.zig");
const roots = @import("roots.zig");
const source = @import("source.zig");

const Tree = source.Tree;

/// The child build's cache flag. build/api's child runner owns it, and its
/// configure side checks at compile time that the two agree.
pub const cache_directory_argument = "--cache-dir";
pub const declaration_bytes_max = 1024 * 1024;
pub const runtime_extra_max = 14;
pub const jobs_max = 16;

pub const Spec = struct {
    owner: []const u8,
    required: []const []const u8,
    recipes: []const RecipeSpec,
    areas: []const validation.plan.Area = &.{},
};

pub const RecipeSpec = struct {
    id: []const u8,
    step: []const u8,
    class: []const u8 = "ordinary",
    placement: validation.Placement = .local,
    runtime: []const []const u8 = &.{},
    child_zig_cache: ?[]const u8 = null,
    jobs: ?u8 = null,
    suites: []const validation.Suite,
};

/// Recipes, the owners that select them, and the hashed sources their
/// identities cover. Every slice lives in the arena that loaded it.
pub const Catalog = struct {
    recipes: []const validation.Recipe,
    sources: []const validation.Source,
    source_roots: []const []const u8,
    owners: []const validation.plan.Owner,
};

const framework_roots = [_][]const u8{
    "build/api/build.zig",
    "build/api/build.zig.zon",
    "build/api/runner.zig",
    "build/api/src",
    "build/api/validation",
    "build/api/timing",
};

/// Loads the catalog of the whole tree. Root dependencies and the canonical
/// tool catalog enumerate package identities. Each owner owns every file that
/// declares its edges: a package its own manifest, and an infrastructure owner
/// the root manifest or tool catalog it reads. Inert fixture fronts never
/// become owners.
pub fn load(arena: std.mem.Allocator, tree: Tree, tool_catalog: []const u8) !Catalog {
    std.debug.assert(std.fs.path.isAbsolute(tree.root));
    std.debug.assert(tool_catalog.len != 0);
    const cwd = try std.process.currentPathAlloc(tree.io, arena);
    var pending: [validation.plan.owners_max][]const u8 = undefined;
    pending[0] = ".";
    var count: usize = 1;
    var cursor: usize = 0;
    var owners: std.ArrayList(validation.plan.Owner) = .empty;
    var recipes: std.ArrayList(validation.Recipe) = .empty;
    var source_roots: std.ArrayList([]const u8) = .empty;
    var root_dependencies: []const []const u8 = &.{};
    var root_fixture_parents: std.ArrayList([]const u8) = .empty;
    try roots.add(arena, &source_roots, tool_catalog);
    const catalog_bytes = try tree.read(arena, tool_catalog, manifest.bytes_max);
    const tool_roots = try manifest.toolRoots(arena, catalog_bytes);
    for (tool_roots) |owner| {
        if (listed(pending[0..count], owner)) continue;
        if (count == pending.len) return error.ValidationPlanCapacityExceeded;
        pending[count] = owner;
        count += 1;
    }
    while (cursor < count) : (cursor += 1) {
        const owner = pending[cursor];
        const manifest_path = if (cursor == 0)
            "build.zig.zon"
        else
            try std.fs.path.join(arena, &.{ owner, "build.zig.zon" });
        try roots.add(arena, &source_roots, manifest_path);
        const bytes = try tree.read(arena, manifest_path, manifest.bytes_max);
        const paths = try manifest.dependencies(arena, bytes);
        var dependencies: std.ArrayList([]const u8) = .empty;
        for (paths) |path| {
            const resolved = try std.fs.path.resolve(arena, &.{ tree.root, owner, path });
            const relative = try std.fs.path.relative(arena, cwd, null, tree.root, resolved);
            if (std.fs.path.isAbsolute(relative) or std.mem.eql(u8, relative, "..") or
                std.mem.startsWith(u8, relative, "../"))
            {
                return error.ValidationDependencyOutsideRepository;
            }
            if (std.mem.eql(u8, relative, ".") or relative.len == 0) continue;
            if (fixtureParent(relative)) |parent| {
                if (cursor == 0) try root_fixture_parents.append(arena, parent);
                continue;
            }
            if (!listed(pending[0..count], relative)) {
                if (count == pending.len) return error.ValidationPlanCapacityExceeded;
                pending[count] = relative;
                count += 1;
            }
            try dependencies.append(arena, relative);
        }
        if (cursor == 0) {
            root_dependencies = try dependencies.toOwnedSlice(arena);
            continue;
        }
        std.debug.assert(validation.plan.within(owner, manifest_path));
        const declared = try package(arena, tree, owner);
        if (declared) |metadata| {
            if (recipes.items.len + metadata.recipes.len > validation.plan.recipes_max) {
                return error.ValidationPlanCapacityExceeded;
            }
            try recipes.appendSlice(arena, metadata.recipes);
            for (metadata.source_roots) |path| try roots.add(arena, &source_roots, path);
        }
        try owners.append(arena, .{
            .path = owner,
            .dependencies = try dependencies.toOwnedSlice(arena),
            .recipes = if (declared) |metadata| metadata.owners[0].recipes else &.{},
            .areas = if (declared) |metadata| metadata.owners[0].areas else &.{},
        });
    }
    if (try infrastructure.load(arena, tree, owners.items)) |metadata| {
        var infrastructure_dependencies: std.ArrayList([]const u8) = .empty;
        try infrastructure_dependencies.appendSlice(arena, root_dependencies);
        for (root_fixture_parents.items) |parent| {
            for (metadata.owners) |declared| {
                if (std.mem.eql(u8, parent, declared.path)) {
                    try infrastructure_dependencies.append(arena, parent);
                    break;
                }
            }
        }
        const framework_root = for (root_dependencies) |dependency| {
            if (std.mem.eql(u8, dependency, "build/api")) break dependency;
        } else return error.ValidationFrameworkDependencyMissing;
        const tool_dependencies = try arena.alloc([]const u8, tool_roots.len + 1);
        @memcpy(tool_dependencies[0..tool_roots.len], tool_roots);
        tool_dependencies[tool_roots.len] = framework_root;
        if (recipes.items.len + metadata.recipes.len > validation.plan.recipes_max or
            owners.items.len + metadata.owners.len > validation.plan.owners_max)
            return error.ValidationPlanCapacityExceeded;
        try recipes.appendSlice(arena, metadata.recipes);
        for (metadata.source_roots) |path| try roots.add(arena, &source_roots, path);
        for (metadata.owners, metadata.dependency_sources) |declared, dependency_source| {
            var owner = declared;
            owner.dependencies = switch (dependency_source) {
                .root_manifest => infrastructure_dependencies.items,
                .tool_catalog => tool_dependencies,
            };
            const declaration = switch (dependency_source) {
                .root_manifest => "build.zig.zon",
                .tool_catalog => tool_catalog,
            };
            if (!validation.plan.within(owner.path, declaration)) {
                owner.declarations = try arena.dupe([]const u8, &.{declaration});
            }
            try owners.append(arena, owner);
        }
    }
    _ = try validation.plan.select(owners.items, recipes.items, &.{});
    return .{
        .recipes = try recipes.toOwnedSlice(arena),
        .owners = try owners.toOwnedSlice(arena),
        .sources = try source.capture(arena, tree, source_roots.items),
        .source_roots = try source_roots.toOwnedSlice(arena),
    };
}

/// Loads one package's declaration, or null when the package declares no
/// recipes.
pub fn package(arena: std.mem.Allocator, tree: Tree, owner: []const u8) !?Catalog {
    std.debug.assert(owner.len != 0);
    const path = try std.fs.path.join(arena, &.{ owner, "build/validation.zon" });
    const absolute = try tree.absolute(arena, path);
    const parent = std.fs.path.dirname(absolute).?;
    tree.fail(path);
    const directory = if (std.Io.Dir.cwd().statFile(tree.io, parent, .{})) |_|
        parent
    else |err| switch (err) {
        error.FileNotFound => std.fs.path.dirname(parent).?,
        else => return err,
    };
    tree.observeDirectory(directory);
    const bytes = (try tree.readOptional(arena, path, declaration_bytes_max)) orelse return null;
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const spec = try std.zon.parse.fromSlice(Spec, .{
        .gpa = arena,
        .arena = arena,
        .source = bytes,
        .diagnostics = &diagnostics,
    });
    if (!std.mem.eql(u8, spec.owner, owner)) return error.ValidationDeclarationOwnerMismatch;
    return try configure(arena, tree, spec);
}

/// Derives a package's recipe identities. Package execution and catalog
/// export both come through here, so they cannot disagree.
pub fn configure(arena: std.mem.Allocator, tree: Tree, spec: Spec) !Catalog {
    std.debug.assert(spec.owner.len != 0);
    if (spec.recipes.len == 0 or spec.recipes.len > validation.plan.recipes_max) {
        return error.InvalidValidationRecipeCount;
    }
    const source_roots = try arena.alloc([]const u8, framework_roots.len + 3);
    @memcpy(source_roots[0..framework_roots.len], &framework_roots);
    source_roots[framework_roots.len] = try std.fs.path.join(arena, &.{ spec.owner, "build.zig" });
    source_roots[framework_roots.len + 1] =
        try std.fs.path.join(arena, &.{ spec.owner, "build.zig.zon" });
    source_roots[framework_roots.len + 2] = try std.fs.path.join(arena, &.{ spec.owner, "build" });
    const sources = try source.capture(arena, tree, source_roots);
    const declaration = try std.fs.path.join(arena, &.{ spec.owner, "build/validation.zon" });
    const declaration_hash = for (sources) |entry| {
        if (std.mem.eql(u8, entry.path, declaration)) break entry.sha256;
    } else return error.MissingValidationDeclaration;
    const framework_hash = try arena.dupe(u8, &validation.sourceDigest(sources));
    const recipes = try arena.alloc(validation.Recipe, spec.recipes.len);
    for (spec.recipes, recipes) |entry, *recipe| {
        recipe.* = try packageRecipe(
            arena,
            spec.owner,
            entry,
            declaration,
            declaration_hash,
            framework_hash,
        );
    }
    const owners = try arena.alloc(validation.plan.Owner, 1);
    owners[0] = .{ .path = spec.owner, .recipes = spec.required, .areas = spec.areas };
    _ = try validation.plan.select(owners, recipes, &.{});
    return .{
        .recipes = recipes,
        .sources = sources,
        .source_roots = source_roots,
        .owners = owners,
    };
}

fn packageRecipe(
    arena: std.mem.Allocator,
    owner: []const u8,
    entry: RecipeSpec,
    declaration: []const u8,
    declaration_hash: []const u8,
    framework_hash: []const u8,
) !validation.Recipe {
    if (entry.suites.len == 0 or entry.suites.len > validation.max_suites) {
        return error.InvalidValidationSuiteCount;
    }
    if (entry.runtime.len > runtime_extra_max) return error.TooManyValidationExecutables;
    const runtime = try arena.alloc([]const u8, 2 + entry.runtime.len);
    runtime[0] = "zig";
    runtime[1] = "git";
    @memcpy(runtime[2..], entry.runtime);
    const base_environment = [_]validation.Environment{
        .{ .name = "HOME", .value = "/tmp" },
        .{ .name = "TMPDIR", .value = "/tmp" },
        .{ .name = "ZIG_GLOBAL_CACHE_DIR", .value = "/tmp/zig-global" },
        .{ .name = "ZIG_DEBUG_CMD", .value = "1" },
        .{ .name = "LANG", .value = "C" },
        .{ .name = "TZ", .value = "UTC" },
        .{ .name = "NO_COLOR", .value = "1" },
    };
    const environment = try arena.alloc(
        validation.Environment,
        base_environment.len + @intFromBool(entry.child_zig_cache != null),
    );
    @memcpy(environment[0..base_environment.len], &base_environment);
    if (entry.child_zig_cache) |path| {
        if (!std.mem.startsWith(u8, path, "/tmp/") or
            path.len <= "/tmp/".len or
            std.mem.indexOf(u8, path, "..") != null)
            return error.InvalidChildZigCache;
        environment[base_environment.len] = .{ .name = "ZIG_LOCAL_CACHE_DIR", .value = path };
    }
    const jobs_count: usize = @intFromBool(entry.jobs != null);
    const arguments = try arena.alloc([]const u8, 10 + jobs_count);
    const build_file = try std.fmt.allocPrint(arena, "/workspace/{s}/build.zig", .{owner});
    @memcpy(arguments[0..10], &[_][]const u8{
        "build",                    "--build-file",     build_file,
        cache_directory_argument,   "/tmp/zig-local",   "--prefix",
        "/tmp/zig-out",             "-Doptimize=Debug", "-Dproduct-backend=native",
        "-Dvalidation-dir=/output",
    });
    if (entry.jobs) |jobs| {
        if (jobs == 0 or jobs > jobs_max) return error.InvalidValidationJobCount;
        arguments[10] = try std.fmt.allocPrint(arena, "-j{d}", .{jobs});
    }
    return .{
        .id = entry.id,
        .owner = owner,
        .directory = owner,
        .step = entry.step,
        .class = entry.class,
        .placement = entry.placement,
        .test_cwd = "/tmp",
        .declaration = declaration,
        .declaration_sha256 = declaration_hash,
        .framework_sha256 = framework_hash,
        .argv = arguments,
        .runtime = runtime,
        .environment = environment,
        .suites = entry.suites,
    };
}

fn listed(paths: []const []const u8, path: []const u8) bool {
    for (paths) |existing| if (std.mem.eql(u8, existing, path)) return true;
    return false;
}

fn fixtureParent(path: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, path, "/fixture") orelse return null;
    const suffix = path[marker + "/fixture".len ..];
    if (suffix.len != 0 and suffix[0] != '/') return null;
    return path[0..marker];
}

const Fixture = struct {
    temporary: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    failure: source.Failure = .{},

    const framework = [_][2][]const u8{
        .{ "build/api/build.zig", "// build\n" },
        .{ "build/api/build.zig.zon", ".{}\n" },
        .{ "build/api/runner.zig", "// runner\n" },
        .{ "build/api/src/root.zig", "// src\n" },
        .{ "build/api/timing/root.zig", "// timing\n" },
        .{ "build/api/validation/root.zig", "// validation\n" },
    };

    fn init() !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
        return .{ .temporary = temporary, .arena = arena, .root = root };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena.deinit();
        fixture.temporary.cleanup();
        fixture.* = undefined;
    }

    fn write(fixture: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            try fixture.temporary.dir.createDirPath(std.testing.io, parent);
        }
        try fixture.temporary.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn tree(fixture: *Fixture) Tree {
        return .{ .io = std.testing.io, .root = fixture.root, .failure = &fixture.failure };
    }
};

fn hex(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return arena.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

const core_declaration =
    \\.{ .owner = "lib/core", .required = .{"lib-core.test"}, .recipes = .{.{
    \\    .id = "lib-core.test",
    \\    .step = "test",
    \\    .suites = .{.{
    \\        .id = "lib-core",
    \\        .backend = "native",
    \\        .selection_artifact = "lib-core.selection.json",
    \\        .result_artifact = "lib-core.result.json",
    \\    }},
    \\}} }
    \\
;

const empty_tool_catalog = ".{ .schema = \"tiny.build.tool-catalog/v1\", .tools = .{} }";

const registry_declaration =
    \\.{ .root_options = .{}, .owners = .{
    \\    .{
    \\        .path = "build/packages",
    \\        .id = "build-packages.test",
    \\        .step = "package-registry-test",
    \\        .suite = "build-packages-check",
    \\        .dependencies = .root_manifest,
    \\    },
    \\    .{
    \\        .path = "build/tools/package",
    \\        .id = "build-tools-package.test",
    \\        .step = "tool-catalog-test",
    \\        .suite = "build-tools-package-check",
    \\        .dependencies = .tool_catalog,
    \\    },
    \\} }
;
