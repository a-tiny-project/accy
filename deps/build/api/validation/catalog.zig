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
/// The registry's withheld packages, by directory. The root build composes
/// them through the registry, not a manifest edge, so this list joins the root
/// manifest's dependencies. The public projection empties it.
pub const withheld_path = "build/packages/registry/withheld.zon";
pub const runtime_extra_max = 14;
pub const jobs_max = 16;
/// The most CPUs a recipe may claim. Admission clamps a claim to the sealed
/// host's CPU tokens; this bound refuses a declaration no host could mean.
pub const claim_cpu_max = 64;
/// A product tree keys at most this many input paths, stages at most this many
/// copies, adds at most this many producer variables and carries at most this
/// many policy words.
pub const product_inputs_max = 8;
pub const product_staging_max = 8;
pub const product_environment_max = 8;
pub const product_policy_max = 32;
pub const product_path_bytes_max = 256;
/// The counts above admit records past this serialized bound; it is the
/// one that holds.
pub const product_tree_bytes_max = validation.product_tree_bytes_max;
pub const recipe_bytes_max = validation.recipe_bytes_max;
/// The check executor sets variables with this prefix for a product tree's
/// mount and mode.
pub const product_reserved_prefix = "TINY_PRODUCT_";
/// The check executor keeps the declared commands here inside the check's
/// private /tmp, so no product mount may name it or lie under it. It names
/// the same directory as `sandbox.confined.command_directory`, which this
/// module does not import.
const command_directory = "sandbox-bin";

comptime {
    std.debug.assert(product_tree_bytes_max < recipe_bytes_max);
}
/// A declared claim covers its measured peak by at least a quarter.
pub const claim_headroom_numerator = 5;
pub const claim_headroom_denominator = 4;

pub const Spec = struct {
    owner: []const u8,
    required: []const []const u8,
    /// Recipes that run whenever the owner is selected and stop a landing
    /// when they fail, without covering the owner.
    advisory: []const []const u8 = &.{},
    recipes: []const RecipeSpec,
    areas: []const validation.plan.Area = &.{},
    inputs: []const []const u8 = &.{},
};

pub const RecipeSpec = struct {
    id: []const u8,
    step: []const u8,
    class: []const u8 = "ordinary",
    placement: validation.Placement = .local,
    runner: validation.Runner = .normalized,
    runtime: []const []const u8 = &.{},
    child_zig_cache: ?[]const u8 = null,
    jobs: ?u8 = null,
    claim: ?validation.Claim = null,
    product_tree: ?validation.ProductTree = null,
    suites: []const validation.Suite,
};

/// Recipes, the owners that select them, and the hashed sources their
/// identities cover. Every slice lives in the arena that loaded it.
pub const Catalog = struct {
    recipes: []const validation.Recipe,
    sources: []const validation.Source,
    source_roots: []const []const u8,
    owners: []const validation.plan.Owner,
    runtime_inputs: []const validation.runtime.Input,

    pub fn model(self: Catalog) validation.plan.Model {
        std.debug.assert(self.runtime_inputs.len <= validation.runtime.inputs_max);
        return .{
            .owners = self.owners,
            .recipes = self.recipes,
            .runtime_inputs = self.runtime_inputs,
        };
    }
};

const framework_roots = [_][]const u8{
    "build/api/build.zig",
    "build/api/build.zig.zon",
    "build/api/runner.zig",
    "build/api/src",
    "build/api/validation",
    "build/api/timing",
};

/// Loads the catalog of the whole tree. Root dependencies, the registry's
/// withheld list and the canonical tool catalog enumerate package identities.
/// Each owner owns every file that declares its edges: a package its own
/// manifest, and an infrastructure owner the root manifest or tool catalog it
/// reads. The withheld list lies inside build/packages, which owns it by path.
/// Inert fixture fronts never become owners.
pub fn load(arena: std.mem.Allocator, checkout: Tree, tool_catalog: []const u8) !Catalog {
    return loadSelected(arena, checkout, tool_catalog, null);
}

/// Selects only the tool roots present on this build surface. Null keeps the
/// whole-tree inventory; an empty slice selects no tool roots. Manifest edges
/// still require every reached owner, including a tool omitted from these seeds.
/// Selection never turns a missing selected manifest into an absent owner.
pub fn loadSelected(
    arena: std.mem.Allocator,
    checkout: Tree,
    tool_catalog: []const u8,
    selected_tool_roots: ?[]const []const u8,
) !Catalog {
    var snapshot: source.Snapshot = .{ .arena = arena };
    var tree = checkout;
    tree.snapshot = &snapshot;
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
    try roots.add(arena, &source_roots, withheld_path);
    const catalog_bytes = try tree.read(arena, tool_catalog, manifest.bytes_max);
    var tool_roots = try manifest.toolRoots(arena, catalog_bytes);
    const withheld_roots = try withheld(arena, tree);
    if (selected_tool_roots) |selected| {
        if (selected.len > validation.plan.owners_max) return error.ValidationPlanCapacityExceeded;
        for (selected) |owner| {
            if (!listed(tool_roots, owner)) return error.InvalidValidationToolCatalog;
        }
        var selected_count: usize = 0;
        for (tool_roots) |owner| {
            if (!listed(selected, owner)) continue;
            tool_roots[selected_count] = owner;
            selected_count += 1;
        }
        tool_roots = tool_roots[0..selected_count];
    }
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
            for (withheld_roots) |root| {
                if (!listed(pending[0..count], root)) {
                    if (count == pending.len) return error.ValidationPlanCapacityExceeded;
                    pending[count] = root;
                    count += 1;
                }
                if (!listed(dependencies.items, root)) try dependencies.append(arena, root);
            }
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
            .advisory = if (declared) |metadata| metadata.owners[0].advisory else &.{},
            .areas = if (declared) |metadata| metadata.owners[0].areas else &.{},
            .inputs = if (declared) |metadata| metadata.owners[0].inputs else &.{},
        });
    }
    if (try infrastructure.load(arena, tree, owners.items)) |metadata| {
        for (metadata.recipes) |recipe| {
            if (recipe.claim) |claim| try validateClaim(claim);
        }
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
                .none => &.{},
            };
            const declaration: ?[]const u8 = switch (dependency_source) {
                .root_manifest => "build.zig.zon",
                .tool_catalog => tool_catalog,
                .none => null,
            };
            if (declaration) |file| {
                if (!validation.plan.within(owner.path, file)) {
                    owner.declarations = try std.mem.concat(arena, []const u8, &.{
                        declared.declarations,
                        &.{file},
                    });
                }
            }
            try owners.append(arena, owner);
        }
    }
    const runtime_inputs = try validation.runtime.load(arena, tree);
    _ = try validation.plan.select(
        .{ .owners = owners.items, .recipes = recipes.items, .runtime_inputs = runtime_inputs },
        &.{},
    );
    return .{
        .recipes = try recipes.toOwnedSlice(arena),
        .owners = try owners.toOwnedSlice(arena),
        .runtime_inputs = runtime_inputs,
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
    owners[0] = .{
        .path = spec.owner,
        .recipes = spec.required,
        .advisory = spec.advisory,
        .areas = spec.areas,
        .inputs = spec.inputs,
    };
    _ = try validation.plan.select(
        .{ .owners = owners, .recipes = recipes, .runtime_inputs = &.{} },
        &.{},
    );
    return .{
        .recipes = recipes,
        .sources = sources,
        .source_roots = source_roots,
        .owners = owners,
        .runtime_inputs = &.{},
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
    if ((entry.runner == .normalized and
        (entry.suites.len == 0 or entry.suites.len > validation.max_suites)) or
        (entry.runner == .standard and entry.suites.len != 0))
    {
        return error.InvalidValidationSuiteCount;
    }
    // A standard route runs in the checkout, where no child cache is redirected.
    if (entry.runner == .standard and entry.child_zig_cache != null)
        return error.UnsupportedStandardValidationRuntime;
    if (entry.runtime.len > runtime_extra_max) return error.TooManyValidationExecutables;
    // A standard route builds a step whose lanes carry its claim.
    if (entry.runner == .standard and entry.claim != null)
        return error.UnsupportedStandardValidationClaim;
    if (entry.claim) |claim| try validateClaim(claim);
    if (entry.product_tree) |tree| {
        if (entry.runner == .standard) return error.UnsupportedStandardValidationProductTree;
        try validateProductTree(arena, tree);
    }
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
    const producer: []const validation.Environment =
        if (entry.product_tree) |tree| tree.environment else &.{};
    const environment = try arena.alloc(
        validation.Environment,
        base_environment.len + @intFromBool(entry.child_zig_cache != null) + producer.len,
    );
    @memcpy(environment[0..base_environment.len], &base_environment);
    var count: usize = base_environment.len;
    if (entry.child_zig_cache) |path| {
        if (!std.mem.startsWith(u8, path, "/tmp/") or
            path.len <= "/tmp/".len or
            std.mem.indexOf(u8, path, "..") != null)
            return error.InvalidChildZigCache;
        environment[count] = .{ .name = "ZIG_LOCAL_CACHE_DIR", .value = path };
        count += 1;
    }
    for (producer) |variable| {
        for (environment[0..count]) |prior| {
            if (std.mem.eql(u8, prior.name, variable.name)) return error.InvalidProductTree;
        }
        environment[count] = variable;
        count += 1;
    }
    std.debug.assert(count == environment.len);
    const arguments = try recipeArguments(arena, owner, entry);
    const recipe: validation.Recipe = .{
        .id = entry.id,
        .owner = owner,
        .directory = owner,
        .step = entry.step,
        .class = entry.class,
        .placement = entry.placement,
        .runner = entry.runner,
        .claim = entry.claim,
        .test_cwd = if (entry.runner == .normalized) "/tmp" else ".",
        .declaration = declaration,
        .declaration_sha256 = declaration_hash,
        .framework_sha256 = framework_hash,
        .argv = arguments,
        .runtime = runtime,
        .environment = if (entry.runner == .normalized) environment else &.{},
        .suites = entry.suites,
        .product_tree = entry.product_tree,
    };
    if (try serializedBytes(arena, recipe) > recipe_bytes_max) {
        return error.ValidationRecipeTooLarge;
    }
    return recipe;
}

fn serializedBytes(allocator: std.mem.Allocator, value: anytype) !usize {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    return bytes.len;
}

/// Refuses a product tree whose paths are not canonical or overlap, whose
/// counts or serialized size exceed their bounds, whose text the sandbox
/// would refuse, or whose producer variables could shadow the ones the
/// check executor or the check sets. The mount follows the sandbox's cache mount rule.
fn validateProductTree(allocator: std.mem.Allocator, tree: validation.ProductTree) !void {
    if (tree.policy_version == 0) return error.InvalidProductTree;
    if (!cacheMount(tree.mount)) return error.InvalidProductTree;
    if (tree.inputs.len == 0 or tree.inputs.len > product_inputs_max) {
        return error.InvalidProductTree;
    }
    for (tree.inputs, 0..) |input, index| {
        if (!canonical(input, "")) return error.InvalidProductTree;
        for (tree.inputs[0..index]) |prior| {
            if (contains(prior, input) or contains(input, prior)) return error.InvalidProductTree;
        }
    }
    if (tree.staging.len == 0 or tree.staging.len > product_staging_max) {
        return error.InvalidProductTree;
    }
    for (tree.staging) |mapping| {
        if (!canonical(mapping.from, "/workspace/") or !canonical(mapping.to, "/output/")) {
            return error.InvalidProductTree;
        }
    }
    if (tree.environment.len > product_environment_max) return error.InvalidProductTree;
    for (tree.environment) |variable| {
        if (!word(variable.name) or !text(variable.value) or
            std.mem.indexOfScalar(u8, variable.name, '=') != null or
            std.mem.eql(u8, variable.name, "PATH") or
            std.mem.startsWith(u8, variable.name, product_reserved_prefix))
            return error.InvalidProductTree;
    }
    if (tree.policy.len > product_policy_max) return error.InvalidProductTree;
    for (tree.policy) |value| if (!word(value)) return error.InvalidProductTree;
    if (try serializedBytes(allocator, tree) > product_tree_bytes_max) {
        return error.InvalidProductTree;
    }
}

/// Reports whether `mount` is a cache mount the sandbox accepts: strictly
/// inside the private /tmp, outside the command directory, and canonical.
fn cacheMount(mount: []const u8) bool {
    if (!canonical(mount, "/tmp/")) return false;
    const first = std.mem.sliceTo(mount["/tmp/".len..], '/');
    return !std.mem.eql(u8, first, command_directory);
}

/// Reports whether `path` starts with `prefix` and continues in nonempty
/// components other than `.` and `..`, as sandbox text within
/// `product_path_bytes_max`.
fn canonical(path: []const u8, prefix: []const u8) bool {
    if (!text(path) or !std.mem.startsWith(u8, path, prefix)) return false;
    const rest = path[prefix.len..];
    if (rest.len == 0) return false;
    var parts = std.mem.splitScalar(u8, rest, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return false;
        }
    }
    return true;
}

/// Nonempty sandbox text.
fn word(value: []const u8) bool {
    return value.len != 0 and text(value);
}

/// Text the sandbox accepts: valid UTF-8 without NUL, within
/// `product_path_bytes_max`.
fn text(value: []const u8) bool {
    return value.len <= product_path_bytes_max and
        std.mem.indexOfScalar(u8, value, 0) == null and
        std.unicode.utf8ValidateSlice(value);
}

/// Reports whether repository path `inner` is `outer` or lies under it.
fn contains(outer: []const u8, inner: []const u8) bool {
    return std.mem.startsWith(u8, inner, outer) and
        (inner.len == outer.len or inner[outer.len] == '/');
}

/// Refuses a claim that does not cover its own measured peak with headroom,
/// so a declaration cannot reserve less than its evidence says it uses.
fn validateClaim(claim: validation.Claim) !void {
    if (claim.memory_mib == 0 or claim.cpu == 0 or claim.peak_mib == 0 or
        claim.evidence.len == 0 or claim.cpu > claim_cpu_max)
        return error.InvalidValidationClaim;
    if (claim.memory_mib < claimFloor(claim.peak_mib)) return error.ValidationClaimBelowPeak;
}

/// The least memory a claim may declare for a measured peak.
pub fn claimFloor(peak_mib: u32) u64 {
    return std.math.divCeil(
        u64,
        @as(u64, peak_mib) * claim_headroom_numerator,
        claim_headroom_denominator,
    ) catch unreachable;
}

/// Reads the withheld list. A tree without one, such as a tree older than the
/// list, withholds nothing.
fn withheld(arena: std.mem.Allocator, tree: Tree) ![]const []const u8 {
    const absolute = try tree.absolute(arena, withheld_path);
    tree.observeDirectory(std.fs.path.dirname(absolute).?);
    const bytes = (try tree.readOptional(arena, withheld_path, manifest.bytes_max)) orelse
        return &.{};
    return manifest.withheldRoots(arena, bytes);
}

fn recipeArguments(
    arena: std.mem.Allocator,
    owner: []const u8,
    entry: RecipeSpec,
) ![]const []const u8 {
    const jobs_count: usize = @intFromBool(entry.jobs != null);
    const base_count: usize = if (entry.runner == .normalized) 10 else 5;
    const arguments = try arena.alloc([]const u8, base_count + jobs_count);
    const build_file = try std.fmt.allocPrint(arena, "{s}{s}/build.zig", .{
        if (entry.runner == .normalized) "/workspace/" else "", owner,
    });
    if (entry.runner == .normalized) @memcpy(arguments[0..10], &[_][]const u8{
        "build",                    "--build-file",     build_file,
        cache_directory_argument,   "/tmp/zig-local",   "--prefix",
        "/tmp/zig-out",             "-Doptimize=Debug", "-Dproduct-backend=native",
        "-Dvalidation-dir=/output",
    }) else @memcpy(arguments[0..5], &[_][]const u8{
        "build", "--build-file", build_file, "-Doptimize=Debug", "-Dproduct-backend=native",
    });
    if (entry.jobs) |jobs| {
        if (jobs == 0 or jobs > jobs_max) return error.InvalidValidationJobCount;
        arguments[base_count] = try std.fmt.allocPrint(arena, "-j{d}", .{jobs});
    }
    return arguments;
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

const infrastructure_files = [_][2][]const u8{
    .{ "build.zig", "// root\n" },
    .{ "build.zig.zon", ".{ .dependencies = .{ .api = .{ .path = \"build/api\" } } }" },
    .{ "toolcatalogtest.zig", "// catalog test\n" },
    .{ "build/root.zig", "// root build\n" },
    .{ "build/packages/audit/register/root.zig", "// audit\n" },
    .{ "build/packages/register.zig", "// registry\n" },
    .{ "build/packages/root.zig", "// registry\n" },
    .{ "build/tools/package/catalog.zon", empty_tool_catalog },
    .{ "build/tools/package/register.zig", "// tools\n" },
    .{ "build/tools/package/root.zig", "// tools\n" },
    .{ infrastructure.declaration_path, registry_declaration },
};

const withheld_declaration =
    \\.{ .owner = "lib/fun/x", .required = .{"x.test"}, .recipes = .{.{
    \\    .id = "x.test",
    \\    .step = "test",
    \\    .suites = .{.{
    \\        .id = "x",
    \\        .backend = "native",
    \\        .selection_artifact = "x.selection.json",
    \\        .result_artifact = "x.result.json",
    \\    }},
    \\}} }
    \\
;

const withheld_files = [_][2][]const u8{
    .{ withheld_path, ".{ \"lib/fun/x\", \"lib/fun/x/dev\" }\n" },
    .{ "lib/fun/x/build.zig", "// x\n" },
    .{
        "lib/fun/x/build.zig.zon",
        ".{ .dependencies = .{ .api = .{ .path = \"../../../build/api\" } } }",
    },
    .{ "lib/fun/x/build/validation.zon", withheld_declaration },
    .{ "lib/fun/x/dev/build.zig.zon", ".{ .dependencies = .{ .x = .{ .path = \"..\" } } }" },
};

fn selects(catalog: Catalog, plan: validation.plan.Plan, id: []const u8) !bool {
    for (catalog.recipes, 0..) |recipe, index| {
        if (std.mem.eql(u8, recipe.id, id)) return plan.recipes.isSet(index);
    }
    return error.UnknownValidationRecipe;
}

/// A tree whose serialized form is exactly the bound passes, and one byte
/// more refuses, with the maximum producer environment declared.
fn expectProductBoundary(arena: std.mem.Allocator, base: validation.ProductTree) !void {
    var tree = base;
    var variables: [product_environment_max]validation.Environment = undefined;
    for (&variables, 0..) |*variable, index| variable.* = .{
        .name = try std.fmt.allocPrint(arena, "CORE_{d}", .{index}),
        .value = "1",
    };
    tree.environment = &variables;
    tree.policy = &.{};
    const empty = try serializedBytes(arena, tree);
    const full: [product_path_bytes_max]u8 = @splat('a');
    var words: [product_policy_max][]const u8 = undefined;
    var count: usize = 0;
    var size = empty;
    // Each word adds its bytes, its two quotation marks and, after the first,
    // a comma. Fill with full words, then size the last to land on the bound.
    while (product_tree_bytes_max - size > product_path_bytes_max + 3) : (count += 1) {
        words[count] = &full;
        size += @as(usize, product_path_bytes_max + 2) + @intFromBool(count > 0);
    }
    const last = product_tree_bytes_max - size - 2 - @as(usize, @intFromBool(count > 0));
    words[count] = try arena.alloc(u8, last);
    @memset(@constCast(words[count]), 'a');
    count += 1;
    tree.policy = words[0..count];
    try std.testing.expectEqual(product_tree_bytes_max, try serializedBytes(arena, tree));
    try validateProductTree(arena, tree);
    words[count - 1] = try std.mem.concat(arena, u8, &.{ words[count - 1], "a" });
    try std.testing.expectError(error.InvalidProductTree, validateProductTree(arena, tree));
}
