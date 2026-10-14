const std = @import("std");
const backend = @import("backend.zig");
const BuildLayout = @import("build_layout.zig").BuildLayout;
const child = @import("child.zig");
const check = @import("check.zig");
const catalog = @import("catalog/root.zig");
const directory = @import("directory/root.zig");
const filter = @import("filter.zig");
const format = @import("format.zig");
const incremental = @import("incremental.zig");
const invocation = @import("invocation/root.zig");
const module = @import("module.zig");
const manifest = @import("manifest/root.zig");
const resource = @import("resource.zig");
const target = @import("target.zig");
const validate = @import("validate.zig");
const test_cwd_option = "test-cwd";

pub const Scope = struct {
    build: *std.Build,
    format_step: ?*std.Build.Step,
    iteration_marker: ?*std.Build.Step.Compile,
    product_backend: ?backend.Product,
    facts_step: ?*std.Build.Step,

    pub fn deinit(scope: Scope) void {
        scope.finalize(false);
    }

    fn finalize(scope: Scope, check_twins: bool) void {
        scope.finalizeWithQualification(check_twins, null);
    }

    fn finalizeWithQualification(
        scope: Scope,
        check_twins: bool,
        qualification: ?PackageGraph,
    ) void {
        validate.graph(scope.build);
        catalog.finalize(scope.build, scope.facts_step);
        finalizeCompilers(scope.build, scope.product_backend);
        if (qualification) |register_qualification| register_qualification(scope.build);
        if (check_twins) check.registerTwins(scope.build);
        settleLinkers(scope.build);
        manifest.attachment.finalize(scope.build) catch |err| {
            std.debug.panic("compiler invocation qualification: {t}", .{err});
        };
        if (scope.iteration_marker) |marker| {
            incremental.finalize(scope.build, marker);
        }
    }
};

fn finalizeCompilers(b: *std.Build, requested: ?backend.Product) void {
    for (ownedCompiles(b, .declared)) |compile| {
        backend.apply(b, requested, compile);
        incremental.applyGeneratedInputPolicy(compile);
    }
}

/// Runs after qualification and check twins add their projections, so every compile this
/// package hands the compiler pairs its linker with its backend.
fn settleLinkers(b: *std.Build) void {
    for (ownedCompiles(b, .implied)) |compile| backend.settleLinker(compile);
}

const Edges = enum {
    /// The dependencies each step declares by the end of configuration.
    declared,
    /// The declared dependencies, and those each compile's module graph implies: linked compiles
    /// and the producers of generated inputs. The serializer adds these only after configuration
    /// returns, so a compile that only a module graph reaches is otherwise missed.
    implied,
};

fn ownedCompiles(b: *std.Build, edges: Edges) []const *std.Build.Step.Compile {
    const arena = b.graph.arena;
    var visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var pending: std.ArrayListUnmanaged(*std.Build.Step) = .empty;
    var modules: std.AutoArrayHashMapUnmanaged(*std.Build.Module, void) = .empty;
    var modules_walked: usize = 0;
    var compiles: std.ArrayListUnmanaged(*std.Build.Step.Compile) = .empty;
    for (b.top_level_steps.values()) |top_level| {
        pending.append(arena, &top_level.step) catch @panic("OOM");
    }
    pending.appendSlice(arena, &.{
        &b.install_tls.step,
        &b.uninstall_tls.step,
    }) catch @panic("OOM");
    while (true) {
        if (pending.pop()) |step| {
            const entry = visited.getOrPut(arena, step) catch @panic("OOM");
            if (entry.found_existing) continue;
            if (step.cast(std.Build.Step.Compile)) |compile| {
                if (compile.step.owner == b) {
                    compiles.append(arena, compile) catch @panic("OOM");
                }
                if (edges == .implied) {
                    modules.put(arena, compile.root_module, {}) catch @panic("OOM");
                }
            }
            pending.appendSlice(arena, step.dependencies.items) catch @panic("OOM");
        } else if (modules_walked < modules.count()) {
            const reached = modules.keys()[modules_walked];
            modules_walked += 1;
            for (reached.import_table.values()) |imported| {
                modules.put(arena, imported, {}) catch @panic("OOM");
            }
            appendModuleSteps(b, &pending, reached);
        } else break;
    }
    if (edges == .declared) std.debug.assert(modules.count() == 0);
    return compiles.items;
}

/// Appends the steps a reached module implies for every compile that reaches it, as std's
/// Serialize createModuleDependenciesForStep adds them. Callers walk imports themselves, since
/// `Module.getGraph` caches a graph that later finalization still rewrites.
fn appendModuleSteps(
    b: *std.Build,
    pending: *std.ArrayListUnmanaged(*std.Build.Step),
    reached: *std.Build.Module,
) void {
    const arena = b.graph.arena;
    if (reached.root_source_file) |path| appendProducer(b, pending, path);
    for (reached.include_dirs.items) |include| switch (include) {
        .path,
        .path_system,
        .path_after,
        .framework_path,
        .framework_path_system,
        .embed_path,
        => |path| appendProducer(b, pending, path),
        .other_step => |other| pending.append(arena, &other.step) catch @panic("OOM"),
        .config_header_step => |other| pending.append(arena, &other.step) catch @panic("OOM"),
    };
    for (reached.lib_paths.items) |path| appendProducer(b, pending, path);
    for (reached.rpaths.items) |rpath| switch (rpath) {
        .lazy_path => |path| appendProducer(b, pending, path),
        .special => {},
    };
    for (reached.link_objects.items) |object| switch (object) {
        .static_path, .assembly_file => |path| appendProducer(b, pending, path),
        .other_step => |other| pending.append(arena, &other.step) catch @panic("OOM"),
        .system_lib => {},
        .c_source_file => |source| appendProducer(b, pending, source.file),
        .c_source_files => |sources| appendProducer(b, pending, sources.root),
        .win32_resource_file => |resource_file| {
            appendProducer(b, pending, resource_file.file);
            for (resource_file.include_paths) |path| appendProducer(b, pending, path);
        },
    };
}

fn appendProducer(
    b: *std.Build,
    pending: *std.ArrayListUnmanaged(*std.Build.Step),
    path: std.Build.LazyPath,
) void {
    switch (path) {
        .generated => |generated| {
            const producer = b.graph.generated_files.items[@backingInt(generated.index)];
            pending.append(b.graph.arena, producer) catch @panic("OOM");
        },
        .src_path, .cwd_relative, .relative, .dependency => {},
    }
}

pub fn configure(b: *std.Build) Scope {
    var format_step: ?*std.Build.Step = null;
    var iteration_marker: ?*std.Build.Step.Compile = null;
    if (b.isRoot()) {
        invocation.configuration.declare(b);
        invocation.configuration.adopt(b);
        iteration_marker = incremental.configure(b);
        format_step = format.register(b);
    }
    return .{
        .build = b,
        .format_step = format_step,
        .iteration_marker = iteration_marker,
        .product_backend = backend.configured(b),
        .facts_step = catalog.configure(b),
    };
}

pub const PackageGraph = *const fn (*std.Build) void;
pub const RootInputs = struct {
    format_step: *std.Build.Step,
};
pub const RootGraph = *const fn (*std.Build, RootInputs) void;

const Operation = union(enum) {
    package: PackageGraph,
    root: RootGraph,
};

pub fn package(b: *std.Build, package_graph: PackageGraph) void {
    runPackageLifecycle(b, .{ .package = package_graph });
}

pub fn packageWithQualification(
    b: *std.Build,
    package_graph: PackageGraph,
    qualification: PackageGraph,
) void {
    const scope = configure(b);
    package_graph(b);
    scope.finalizeWithQualification(true, qualification);
}

pub fn rootPackage(b: *std.Build, root_graph: RootGraph) void {
    runPackageLifecycle(b, .{ .root = root_graph });
}

fn runPackageLifecycle(b: *std.Build, operation: Operation) void {
    const scope = configure(b);
    defer scope.finalize(std.meta.activeTag(operation) == .package);
    switch (operation) {
        .package => |package_graph| {
            package_graph(b);
        },
        .root => |root_graph| {
            std.debug.assert(b.isRoot());
            root_graph(b, .{ .format_step = scope.format_step.? });
        },
    }
}

fn addModules(b: *std.Build, options: module.ModuleOptions) void {
    const modules = [_][2][]const u8{
        .{ "capacity", "src/capacity.zig" },
        .{ "requirements", "src/requirements.zig" },
        .{ "invocation", "src/invocation/root.zig" },
        .{ "carried", "timing/carried.zig" },
        .{ "tools", "tools/root.zig" },
        .{ "validation", "validation/root.zig" },
        .{ "restriction_model", "src/restriction.zig" },
        .{ "build_facts", "src/catalog/model.zig" },
    };
    for (modules) |entry| {
        _ = b.addModule(entry[0], options.createOptions(b, entry[1], &.{}));
    }
}

pub fn build(b: *std.Build) void {
    buildWithValidation(b, null);
}

pub fn buildWithValidation(b: *std.Build, comptime validation_module: ?type) void {
    const product = target.standardTargets(b).product;
    const optimize = b.standardOptimizeOption(.{});
    const module_options = module.ModuleOptions{
        .target = product,
        .optimize = optimize,
    };
    addModules(b, module_options);
    const child_transport = child.addLocalTransport(b);
    b.installArtifact(child_transport);
    if (!b.isRoot()) return;
    const test_filters = filter.focused(b);
    const evidence = if (validation_module) |validation| blk: {
        if (!b.isRoot()) break :blk null;
        const metadata = validation.declaration.load(b, "../..", "build/api").?;
        break :blk validation.configure(b, metadata.recipes);
    } else null;
    const test_cwd: ?[]const u8 = if (validation_module) |_| blk: {
        if (evidence) |bound| break :blk bound.recipe.test_cwd;
        break :blk null;
    } else null;
    const invocation_tests = b.addTest(.{
        .name = "compiler-invocation",
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/invocation/test.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const validation_tests = b.addTest(.{
        .name = "validation-receipts",
        .root_module = b.createModule(module_options.createOptions(b, "validation/test.zig", &.{})),
        .filters = test_filters,
    });
    const validation_step = b.step("validation-test", "Verify declared validation evidence");
    validation_step.dependOn(&runTest(b, validation_tests, test_cwd).step);
    const definition = b.createModule(module_options.createOptions(b, "build.zig", &.{}));
    const validation_build_tests = b.addTest(.{
        .name = "validation-build",
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/validation/test.zig",
            &.{.{ .name = "build_definition", .module = definition }},
        )),
        .filters = test_filters,
    });
    const validation_build_step = b.step(
        "validation-build-test",
        "Verify owner discovery and declared validation bindings",
    );
    validation_build_step.dependOn(&runTest(b, validation_build_tests, test_cwd).step);
    const child_tests = child.addLocalTests(b, test_filters);
    const backend_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/backend.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    var check_options: std.Build.TestOptions = .{
        .name = "build-api-check",
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/suite.zig",
            &.{},
        )),
        .filters = test_filters,
    };
    if (validation_module) |validation| if (evidence) |configuration| {
        if (optimize != .debug or !target.eql(product, b.graph.host) or
            test_filters.len != 0) @panic("validation recipes require unfiltered Debug host tests");
        const protocol_module = b.createModule(module_options.createOptions(
            b,
            "validation/root.zig",
            &.{},
        ));
        check_options.root_module = validation.bind(
            b,
            check_options.root_module,
            configuration,
            configuration.recipe.suites[0],
            .{ .module = protocol_module },
        );
        check_options.use_llvm = false;
        check_options.test_runner = .{ .path = b.path("runner.zig"), .mode = .simple };
    };
    const check_tests = b.addTest(check_options);
    const validate_tests = b.addTest(.{
        .name = "build-api-validate",
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/validate.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const filter_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "src/filter.zig", &.{})),
        .filters = test_filters,
    });
    const incremental_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "src/incremental.zig", &.{})),
        .filters = test_filters,
    });
    const marker_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "src/marker.zig", &.{})),
        .filters = test_filters,
    });
    const parallel_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "src/parallel.zig", &.{})),
        .filters = test_filters,
    });
    const provenance_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/provenance/model/test.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const capacity_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/capacity.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const requirements_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/requirements.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const testroot_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "src/testroot.zig", &.{})),
        .filters = test_filters,
    });
    const resource_policy_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(
            b,
            "src/claims.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const timing_schedule_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "timing/schedule.zig", &.{})),
        .filters = test_filters,
    });
    const timing_selection_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "timing/selection.zig", &.{})),
        .filters = test_filters,
    });
    const timing_command_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(
            b,
            "timing/command.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const timing_tree_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "timing/tree.zig", &.{})),
        .filters = test_filters,
    });
    const timing_balance_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "timing/balance.zig", &.{})),
        .filters = test_filters,
    });
    const timing_rows_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "timing/rows.zig", &.{})),
        .filters = test_filters,
    });
    const timing_merge_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(b, "timing/merge.zig", &.{})),
        .filters = test_filters,
    });
    const timing_witness_tests = b.addTest(.{
        .root_module = b.createModule(module_options.createOptions(
            b,
            "timing/witness.zig",
            &.{},
        )),
        .filters = test_filters,
    });
    const run_filter_tests = runTest(b, filter_tests, test_cwd);
    const run_child_tests = runTest(b, child_tests, test_cwd);
    const run_backend_tests = runTest(b, backend_tests, test_cwd);
    const run_check_tests = if (validation_module) |validation|
        validation.run(b, check_tests, evidence)
    else
        runTest(b, check_tests, test_cwd);
    const run_validate_tests = runTest(b, validate_tests, test_cwd);
    const run_incremental_tests = runTest(b, incremental_tests, test_cwd);
    const run_marker_tests = runTest(b, marker_tests, test_cwd);
    const run_parallel_tests = runTest(b, parallel_tests, test_cwd);
    const run_provenance_tests = runTest(b, provenance_tests, test_cwd);
    const run_capacity_tests = runTest(b, capacity_tests, test_cwd);
    const run_requirements_tests = runTest(b, requirements_tests, test_cwd);
    const run_testroot_tests = runTest(b, testroot_tests, test_cwd);
    const run_resource_policy_tests = runTest(b, resource_policy_tests, test_cwd);
    const run_timing_schedule_tests = runTest(b, timing_schedule_tests, test_cwd);
    const run_timing_selection_tests = runTest(b, timing_selection_tests, test_cwd);
    const run_timing_command_tests = runTest(b, timing_command_tests, test_cwd);
    const run_timing_tree_tests = runTest(b, timing_tree_tests, test_cwd);
    const run_timing_balance_tests = runTest(b, timing_balance_tests, test_cwd);
    const run_timing_rows_tests = runTest(b, timing_rows_tests, test_cwd);
    const run_timing_merge_tests = runTest(b, timing_merge_tests, test_cwd);
    const run_timing_witness_tests = runTest(b, timing_witness_tests, test_cwd);
    const launcher = b.path("loom");
    const run_identity_tests = b.addSystemCommand(&.{"sh"});
    run_identity_tests.addFileArg(b.path("launcher/identity-test"));
    run_identity_tests.addFileArg(launcher);
    run_identity_tests.setName("run launcher source identity tests");
    run_identity_tests.expectStdOutEqual("launcher source identity test: 9 checks passed\n");
    const run_resource_tests = b.addSystemCommand(&.{ "sh", "resource/test" });
    run_resource_tests.addFileArg(launcher);
    run_resource_tests.addArg(b.graph.zig_exe);
    const run_nested_resource = resource.addLocalRun(b, .ordinary);
    run_nested_resource.addArg("true");
    run_nested_resource.setName("run nested ordinary build resource transport");
    const step = b.step("test", "Run shared build support tests");
    step.dependOn(validation_step);
    step.dependOn(validation_build_step);
    addValidationRunnerTest(b, module_options, step, test_cwd);
    const resource_step = b.step(
        "resource-test",
        "Exercise live shared build resource admission",
    );
    addChildTransportCliTests(b, step, child_transport);
    addDevFixtureBuild(b, step, test_filters, test_cwd);
    addDirectoryTests(b, module_options, step, test_filters, test_cwd);
    addManifestTests(b, module_options, step, test_filters, test_cwd);
    if (product.query.isNative() and product.result.os.tag == .linux) {
        addLinkTests(b, module_options, step, test_cwd);
    }
    step.dependOn(&run_identity_tests.step);
    step.dependOn(&run_filter_tests.step);
    step.dependOn(&run_child_tests.step);
    step.dependOn(&run_backend_tests.step);
    step.dependOn(&run_check_tests.step);
    step.dependOn(&run_validate_tests.step);
    step.dependOn(&run_incremental_tests.step);
    step.dependOn(&run_marker_tests.step);
    step.dependOn(&run_parallel_tests.step);
    step.dependOn(&run_provenance_tests.step);
    step.dependOn(&run_capacity_tests.step);
    step.dependOn(&run_requirements_tests.step);
    step.dependOn(&runTest(b, invocation_tests, test_cwd).step);
    step.dependOn(&run_testroot_tests.step);
    step.dependOn(&run_resource_policy_tests.step);
    step.dependOn(&run_timing_schedule_tests.step);
    step.dependOn(&run_timing_selection_tests.step);
    step.dependOn(&run_timing_command_tests.step);
    step.dependOn(&run_timing_tree_tests.step);
    step.dependOn(&run_timing_balance_tests.step);
    step.dependOn(&run_timing_rows_tests.step);
    step.dependOn(&run_timing_merge_tests.step);
    step.dependOn(&run_timing_witness_tests.step);
    resource_step.dependOn(&run_resource_tests.step);
    resource_step.dependOn(&run_nested_resource.step);
}

fn addDevFixtureBuild(
    b: *std.Build,
    step: *std.Build.Step,
    filters: []const []const u8,
    test_cwd: ?[]const u8,
) void {
    var build_options: std.ArrayList([]const u8) = .empty;
    for (filters) |selected| {
        build_options.append(b.graph.arena, b.fmt("-Dtest-filter={s}", .{selected})) catch @panic("OOM");
    }
    if (test_cwd) |cwd| {
        build_options.append(b.graph.arena, b.fmt("-D{s}={s}", .{ test_cwd_option, cwd })) catch @panic("OOM");
    }
    const run = child.add(b, .{
        .cwd = b.path("dev"),
        .layout = child.Layout.from(BuildLayout.init(b).scoped(b, "dev")),
        .steps = &.{"test"},
        .build_options = build_options.items,
        .jobs = 1,
        .name = "run build api development fixtures",
    });
    step.dependOn(&run.step);
}

pub fn buildDevFixtures(b: *std.Build) void {
    const options = module.ModuleOptions{
        .target = target.standardTargets(b).product,
        .optimize = b.standardOptimizeOption(.{}),
    };
    const filters = filter.focused(b);
    const test_cwd = b.option([]const u8, test_cwd_option, "Writable test working directory");
    const step = b.step("test", "Run build api development fixture tests");
    addBindingTests(b, options, step, filters, test_cwd);
    addTargetTransportTests(b, step);
}

fn addValidationRunnerTest(b: *std.Build, options: module.ModuleOptions, step: *std.Build.Step, test_cwd: ?[]const u8) void {
    const run = validationRunner(b, options, test_cwd, "validation-runner", "dev/fixture/validation/test.zig");
    run.expectExitCode(0);
    step.dependOn(&run.step);
    // A skip is missing coverage, so bound validation fails it, and says why.
    const skipped = validationRunner(b, options, test_cwd, "validation-runner-skip", "dev/fixture/validation/skip.zig");
    skipped.expectExitCode(1);
    skipped.expectStdErrMatch("[skip] skip.test.validation runner skips one test: a skipped test fails bound validation");
    step.dependOn(&skipped.step);
}

fn validationRunner(
    b: *std.Build,
    options: module.ModuleOptions,
    test_cwd: ?[]const u8,
    name: []const u8,
    fixture: []const u8,
) *std.Build.Step.Run {
    const binding = b.addOptions();
    binding.addOption([]const u8, "model_namespace", "");
    binding.addOption([]const u8, "recipe_id", "validation-runner.test");
    binding.addOption([]const u8, "recipe_sha256", "0000000000000000000000000000000000000000000000000000000000000000");
    binding.addOption([]const u8, "suite_id", "validation-runner");
    binding.addOption([]const u8, "class", "ordinary");
    binding.addOption([]const u8, "backend", "native");
    binding.addOption([]const u8, "token", "validation-runner-fixture");
    const marker = b.addWriteFiles().add("validation-runner", "");
    binding.addOptionPath("output_marker", marker);
    binding.contents.appendSlice(b.allocator, "pub const directory = output_marker ++ \".receipts\";\n") catch @panic("OOM");
    binding.addOption([]const u8, "selection_artifact", "selection.json");
    binding.addOption([]const u8, "result_artifact", "result.json");
    const source = b.createModule(options.createOptions(b, fixture, &.{.{
        .name = "validation",
        .module = b.createModule(options.createOptions(b, "validation/root.zig", &.{})),
    }}));
    source.addOptions("validation_binding", binding);
    const tests = b.addTest(.{
        .name = name,
        .root_module = source,
        .test_runner = .{ .path = b.path("runner.zig"), .mode = .simple },
    });
    return runTest(b, tests, test_cwd);
}

fn runTest(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    cwd: ?[]const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    if (cwd) |path| run.setCwd(b.graph.cwdRelativePath(path));
    return run;
}

/// The manifest fixtures enumerate a handful of small directories.
const fixture_walks = manifest.source.Limits{
    .roots = 16,
    .directories = 64,
    .remembered = 1024,
    .walk_bytes = 64 * 1024,
    .runs = 64,
};

fn addManifestTests(
    b: *std.Build,
    options: module.ModuleOptions,
    step: *std.Build.Step,
    filters: []const []const u8,
    test_cwd: ?[]const u8,
) void {
    if (b.isRoot()) addInvocationFixture(b, options, step);
    const generator = manifest.Generator.init(b);
    const generated_options = b.addOptions();
    generated_options.addOption(bool, "enabled", false);
    var inputs: std.ArrayList(manifest.File) = .empty;
    var walks = manifest.source.Walks.init(b.graph.arena, fixture_walks) catch @panic("OOM");
    manifest.source.collect(&walks, b, b.path("dev/fixture/directory"), "fixture/source", &inputs) catch |err| {
        std.debug.panic("compiler input discovery: {t}", .{err});
    };
    manifest.source.append(b, &inputs, .{
        .identity = .{ .path = "fixture/options.zig" },
        .path = generated_options.getOutput(),
    }) catch @panic("OOM");
    manifest.source.sort(inputs.items);
    const toolchain = generator.toolchain();
    const captured = generator.capture(inputs.items, toolchain);
    const compiled_graph = addManifestGraphFixture(b, options, step, generator, toolchain);
    if (b.isRoot()) addIsolationFixture(b, options, step, filters, test_cwd);
    const tests = b.addTest(.{
        .name = "compiled-input-manifest",
        .root_module = b.createModule(options.createOptions(
            b,
            "test.zig",
            &.{
                .{
                    .name = "compiled_inputs_fixture",
                    .module = b.createModule(options.createOptionsWithRoot(captured.source, &.{})),
                },
                .{ .name = "compiled_graph_fixture", .module = compiled_graph.manifest },
                .{ .name = "compiled_graph_record", .module = compiled_graph.record },
            },
        )),
        .filters = filters,
    });
    step.dependOn(&runTest(b, tests, test_cwd).step);
}

fn addBindingTests(
    b: *std.Build,
    options: module.ModuleOptions,
    parent: *std.Build.Step,
    filters: []const []const u8,
    test_cwd: ?[]const u8,
) void {
    const parent_package = b.dependency("build_api", .{});
    const step = b.step("binding-test", "Verify emitted compiler input bindings");
    parent.dependOn(step);
    var exposure_only = filters.len > 0;
    for (filters) |selected| {
        if (!std.mem.startsWith(u8, selected, "binding exposure")) exposure_only = false;
    }
    var include_exposure = filters.len == 0;
    for (filters) |selected| if (std.mem.startsWith(u8, selected, "binding exposure")) {
        include_exposure = true;
    };
    const fixture = addBindingFixture(b, options);
    if (include_exposure) addExposureTests(b, options, step, filters, test_cwd, fixture);
    if (exposure_only) return;
    const linked_tests = b.addTest(.{
        .name = "compiler-binding-linked-graph",
        .root_module = b.createModule(options.createOptionsWithRoot(parent_package.path("test.zig"), &.{})),
        .filters = &.{"compiler binding"},
    });
    step.dependOn(&runTest(b, linked_tests, test_cwd).step);
    const tests = b.addTest(.{
        .name = "compiled-binding",
        .root_module = b.createModule(options.createOptionsWithRoot(
            manifest.binding.registration.source(b, true),
            &.{
                .{ .name = "binding_fixture", .module = b.createModule(.{ .root_source_file = fixture.path(b, "prefix/binding.zig") }) },
                .{
                    .name = "build_definition",
                    .module = b.createModule(options.createOptionsWithRoot(
                        parent_package.path("build.zig"),
                        &.{},
                    )),
                },
            },
        )),
        .filters = filters,
    });
    step.dependOn(&runTest(b, tests, test_cwd).step);
}

/// Native Darwin fixture compiles grow without a completed peak.
/// Use LLVM for sampled fixtures there; Linux keeps its native backend.
fn fixtureUsesLlvm(options: module.ModuleOptions) bool {
    return options.target.result.os.tag == .macos;
}

/// The fixture package qualifies only under its own exact invocation record,
/// which the driver writes. The enclosing build's launcher never decides it,
/// and every path it installs is absolute.
fn addBindingFixture(b: *std.Build, options: module.ModuleOptions) std.Build.LazyPath {
    const parent_package = b.dependency("build_api", .{});
    const invocation_module = b.createModule(options.createOptionsWithRoot(
        parent_package.path("src/invocation/root.zig"),
        &.{},
    ));
    const driver = b.addExecutable(.{
        .name = "binding-fixture-driver",
        .root_module = b.createModule(options.createOptions(b, "fixture/binding/driver.zig", &.{.{
            .name = "invocation",
            .module = invocation_module,
        }})),
        // Darwin M4 Max native sample: 13,075,536 KiB RSS before guard refusal.
        .use_llvm = fixtureUsesLlvm(options),
    });
    const run = b.addRunArtifact(driver);
    run.setName("build compiler binding fixtures under their own invocation");
    run.addArg(b.graph.zig_exe);
    run.addDirectoryArg2(b.path("fixture/binding"), .{ .make_absolute = true });
    const output = run.addOutputDirectoryArg2("binding-fixture", .{ .make_absolute = true });
    // The nested graph reads build/api sources that this Run cannot hash, so it
    // always runs. The nested cache under its output keeps a rerun cheap.
    run.has_side_effects = true;
    return output;
}

fn addExposureTests(
    b: *std.Build,
    options: module.ModuleOptions,
    step: *std.Build.Step,
    filters: []const []const u8,
    test_cwd: ?[]const u8,
    nested: std.Build.LazyPath,
) void {
    const parent_package = b.dependency("build_api", .{});
    const fixture = b.addOptions();
    const framing = b.addExecutable(.{
        .name = "binding-framing-fixture",
        .root_module = b.createModule(options.createOptionsWithRoot(manifest.binding.selection.framingSource(b), &.{})),
        // Darwin M4 Max native sample: 11,887,664 KiB RSS before guard refusal.
        .use_llvm = fixtureUsesLlvm(options),
    });
    fixture.addOptionPath("framing_binary", framing.getEmittedBin());
    const names = [_][]const u8{
        "exposure_binary",
        "first_record",
        "second_record",
        "native_record",
        "first_locator",
        "second_locator",
        "native_locator",
        "first_installed_record",
        "second_installed_record",
        "native_installed_record",
        "mirror_locator",
    };
    for (names) |name| {
        fixture.contents.print(b.allocator, "pub const {s} = @import(\"nested_fixture\").{s};\n", .{ name, name }) catch @panic("OOM");
    }
    const fixture_module = fixture.createModule();
    fixture_module.addImport("nested_fixture", b.createModule(.{ .root_source_file = nested.path(b, "prefix/exposure.zig") }));
    const tests = b.addTest(.{
        .name = "compiled-binding-exposure",
        .root_module = b.createModule(options.createOptionsWithRoot(
            manifest.binding.selection.source(b, true),
            &.{
                .{ .name = "binding_fixture", .module = fixture_module },
                .{
                    .name = "build_definition",
                    .module = b.createModule(options.createOptionsWithRoot(
                        parent_package.path("build.zig"),
                        &.{},
                    )),
                },
            },
        )),
        .filters = filters,
    });
    step.dependOn(&runTest(b, tests, test_cwd).step);
}

const ManifestGraphFixture = struct {
    manifest: *std.Build.Module,
    record: *std.Build.Module,
};

fn addManifestGraphFixture(
    b: *std.Build,
    options: module.ModuleOptions,
    step: *std.Build.Step,
    generator: manifest.Generator,
    toolchain: manifest.Manifest,
) ManifestGraphFixture {
    const settings = b.addOptions();
    settings.addOption(bool, "enabled", false);
    const generated = b.addWriteFiles();
    const constants = generated.add("root.zig", "pub const value = @embedFile(\"value.txt\");\n");
    _ = generated.add("value.txt", "generated compiler input\n");
    const source = b.createModule(options.createOptions(b, "dev/fixture/compiler/main.zig", &.{
        .{ .name = "settings", .module = settings.createModule() },
        .{ .name = "constants", .module = b.createModule(.{ .root_source_file = constants }) },
    }));
    const executable = b.addExecutable(.{
        .name = "compiler-manifest-fixture",
        .root_module = source,
        .use_llvm = false,
    });
    step.dependOn(&b.addRunArtifact(executable).step);
    var workspace = manifest.graph.Workspace.init(b.graph.arena, fixture_walks) catch @panic("OOM");
    const snapshot = manifest.graph.capture(b, executable, &.{}, &workspace) catch |err| {
        std.debug.panic("compiler graph capture: {t}", .{err});
    };
    var inputs: std.ArrayList(manifest.File) = .empty;
    inputs.appendSlice(b.graph.arena, snapshot.files) catch @panic("OOM");
    inputs.append(b.graph.arena, .{
        .identity = .{ .path = "compilation.json" },
        .path = b.addWriteFiles().add("compilation.json", snapshot.bytes),
    }) catch @panic("OOM");
    const captured = generator.capture(inputs.items, toolchain);
    const metadata = b.addOptions();
    metadata.addOption([]const u8, "graph", snapshot.bytes);
    return .{
        .manifest = b.createModule(options.createOptionsWithRoot(captured.source, &.{})),
        .record = metadata.createModule(),
    };
}

fn addDirectoryTests(
    b: *std.Build,
    options: module.ModuleOptions,
    step: *std.Build.Step,
    filters: []const []const u8,
    test_cwd: ?[]const u8,
) void {
    const generated = b.addWriteFiles().add(
        "directory \"quoted\"/value.txt",
        "generated directory\n",
    );
    const path_source = directory.addOptions(b, &.{
        .{ .name = "source", .directory = b.path("dev/fixture/directory") },
        .{ .name = "generated directory", .directory = generated.dirname() },
    });
    const paths = b.createModule(options.createOptionsWithRoot(path_source, &.{}));
    const tests = b.addTest(.{
        .root_module = b.createModule(options.createOptions(
            b,
            "src/directory/test.zig",
            &.{.{ .name = "directory_options", .module = paths }},
        )),
        .filters = filters,
    });
    const run = runTest(b, tests, test_cwd);
    run.addFileInput(b.path("dev/fixture/directory/value.txt"));
    run.addFileInput(generated);
    step.dependOn(&run.step);
}

fn addChildTransportCliTests(
    b: *std.Build,
    step: *std.Build.Step,
    transport: *std.Build.Step.Compile,
) void {
    const unsupported = b.addRunArtifact(transport);
    unsupported.addArgs(&.{
        "promoted-test-filters",
        "unused-child-command",
        "--",
        "--unsupported",
    });
    unsupported.expectExitCode(2);
    unsupported.expectStdErrEqual(
        "delegated test filter: only '--test-filter VALUE' and " ++
            "'--test-filter=VALUE' are supported after '--'; " ++
            "the child build was not started\n",
    );
    const missing = b.addRunArtifact(transport);
    missing.addArgs(&.{
        "promoted-test-filters",
        "unused-child-command",
        "--",
        "--test-filter",
    });
    missing.expectExitCode(2);
    missing.expectStdErrEqual(
        "delegated test filter: --test-filter needs a non-empty value; " ++
            "the child build was not started\n",
    );
    step.dependOn(&unsupported.step);
    step.dependOn(&missing.step);
}

fn addTargetTransportTests(
    b: *std.Build,
    step: *std.Build.Step,
) void {
    const native_dependency = b.dependency("target_transport_fixture", .{
        .target = b.graph.host,
        .@"expected-native" = true,
    });
    step.dependOn(&native_dependency.builder.top_level_steps.get("check").?.step);

    const partial_query = std.Target.Query{
        .os_tag = .linux,
        .abi = .gnu,
    };
    const partial_dependency = b.dependency("target_transport_fixture", .{
        .target = b.resolveTargetQuery(partial_query),
        .@"expected-native-cpu" = true,
    });
    step.dependOn(&partial_dependency.builder.top_level_steps.get("check").?.step);

    const query_dynamic_linker = "/tiny/query/ld.so";
    const resolved_dynamic_linker = "/tiny/resolved/ld.so";
    const query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        .ofmt = .elf,
        .dynamic_linker = std.Target.DynamicLinker.init(query_dynamic_linker),
    };
    const query_dependency = b.dependency("target_transport_fixture", .{
        .target = query,
        .@"expected-dynamic-linker" = query_dynamic_linker,
        .@"expected-ofmt" = std.Target.ObjectFormat.elf,
    });
    step.dependOn(&query_dependency.builder.top_level_steps.get("check").?.step);

    var resolved_query = query;
    resolved_query.dynamic_linker = std.Target.DynamicLinker.init(
        resolved_dynamic_linker,
    );
    const resolved = b.resolveTargetQuery(resolved_query);
    const resolved_dependency = b.dependency("target_transport_fixture", .{
        .target = resolved,
        .@"expected-dynamic-linker" = resolved_dynamic_linker,
        .@"expected-ofmt" = std.Target.ObjectFormat.elf,
    });
    step.dependOn(&resolved_dependency.builder.top_level_steps.get("check").?.step);
}

fn addLinkTests(
    b: *std.Build,
    module_options: module.ModuleOptions,
    step: *std.Build.Step,
    test_cwd: ?[]const u8,
) void {
    var executable_options = module_options.createOptions(
        b,
        "link/main.zig",
        &.{},
    );
    executable_options.link_libc = true;
    const executable_module = b.createModule(executable_options);
    const executable = b.addExecutable(.{
        .name = "build-api-stage2-libc",
        .root_module = executable_module,
        .use_llvm = false,
    });
    step.dependOn(&b.addRunArtifact(executable).step);
    addLinkTest(b, module_options, step, "stage2-libc", true, false, test_cwd);
    addLinkTest(b, module_options, step, "stage2-no-libc", false, false, test_cwd);
    addLinkTest(b, module_options, step, "llvm-libc", true, true, test_cwd);
}

fn addLinkTest(
    b: *std.Build,
    module_options: module.ModuleOptions,
    step: *std.Build.Step,
    name: []const u8,
    link_libc: bool,
    use_llvm: bool,
    test_cwd: ?[]const u8,
) void {
    var test_options = module_options.createOptions(
        b,
        "link/test.zig",
        &.{},
    );
    test_options.link_libc = link_libc;
    const test_module = b.createModule(test_options);
    const tests = b.addTest(.{
        .name = b.fmt("build-api-{s}", .{name}),
        .root_module = test_module,
        .use_llvm = use_llvm,
    });
    step.dependOn(&runTest(b, tests, test_cwd).step);
}

fn addInvocationFixture(b: *std.Build, options: module.ModuleOptions, step: *std.Build.Step) void {
    const observed = invocation.configuration.observe(b) catch |err| {
        std.debug.panic("compiler invocation qualification: {t}", .{err});
    };
    const expected = b.addOptions();
    const required = b.option(bool, "invocation-qualified", "Assert build invocation qualification");
    expected.addOption(bool, "qualified", required orelse (observed != null));
    const source = b.createModule(options.createOptions(b, "dev/fixture/invocation/main.zig", &.{
        .{ .name = "expected", .module = expected.createModule() },
    }));
    manifest.attachment.attach(b, source);
    const executable = b.addExecutable(.{
        .name = "compiler-invocation-fixture",
        .root_module = source,
        .use_llvm = false,
    });
    step.dependOn(&b.addRunArtifact(executable).step);
}

fn addIsolationFixture(
    b: *std.Build,
    options: module.ModuleOptions,
    step: *std.Build.Step,
    filters: []const []const u8,
    test_cwd: ?[]const u8,
) void {
    const shared = b.createModule(options.createOptions(b, "dev/fixture/isolation/shared.zig", &.{}));
    manifest.attachment.attach(b, shared);
    const alias = b.createModule(options.createOptions(b, "dev/fixture/isolation/alias.zig", &.{
        .{ .name = "shared", .module = shared },
    }));
    const observed = invocation.configuration.observe(b) catch |err| {
        std.debug.panic("compiler invocation qualification: {t}", .{err});
    };
    const pure = isolationRoot(b, options, shared, alias, observed != null, false);
    const native = isolationRoot(b, options, shared, alias, false, true);
    _ = pure.getGraph();
    _ = native.getGraph();
    const files = b.addWriteFiles();
    const roots = [_]*std.Build.Module{ pure, pure, pure, native };
    const names = [_][]const u8{ "first", "repeat", "changed", "native" };
    for (roots, names, 0..) |root, name, index| {
        const executable = b.addExecutable(.{
            .name = "compiler-isolation-fixture",
            .root_module = root,
            .use_llvm = false,
        });
        executable.rdynamic = index == 2;
        const run = b.addRunArtifact(executable);
        _ = files.addCopyFile(run.addOutputFileArg("identity.bin"), b.fmt("{s}.bin", .{name}));
        step.dependOn(&run.step);
    }
    const results = files.add("root.zig", "pub const first = @embedFile(\"first.bin\");\n" ++
        "pub const repeated = @embedFile(\"repeat.bin\");\n" ++
        "pub const changed = @embedFile(\"changed.bin\");\n" ++
        "pub const native = @embedFile(\"native.bin\");\n");
    const tests = b.addTest(.{
        .name = "compiler-isolation",
        .root_module = b.createModule(options.createOptions(b, "dev/fixture/isolation/test.zig", &.{.{
            .name = "isolated_compilers",
            .module = b.createModule(options.createOptionsWithRoot(results, &.{})),
        }})),
        .filters = filters,
    });
    step.dependOn(&runTest(b, tests, test_cwd).step);
}

fn isolationRoot(
    b: *std.Build,
    options: module.ModuleOptions,
    shared: *std.Build.Module,
    alias: *std.Build.Module,
    qualified: bool,
    link_libc: bool,
) *std.Build.Module {
    const expected = b.addOptions();
    expected.addOption(bool, "qualified", qualified);
    var root = options.createOptions(b, "dev/fixture/isolation/main.zig", &.{
        .{ .name = "shared", .module = shared },
        .{ .name = "alias", .module = alias },
        .{ .name = "expected", .module = expected.createModule() },
    });
    root.link_libc = link_libc;
    return b.createModule(root);
}
