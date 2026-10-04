const std = @import("std");
const module_support = @import("module.zig");
const target_support = @import("target.zig");

pub fn graph(b: *std.Build) void {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var test_compiles: std.ArrayListUnmanaged(*std.Build.Step.Compile) = .empty;
    for (b.top_level_steps.values()) |top_level| {
        step(b, &visited, &test_compiles, &top_level.step);
    }
    step(b, &visited, &test_compiles, &b.install_tls.step);
    step(b, &visited, &test_compiles, &b.uninstall_tls.step);
    addTestRootGuards(b, test_compiles.items);
}

fn step(
    b: *std.Build,
    visited: *std.AutoHashMapUnmanaged(*std.Build.Step, void),
    test_compiles: *std.ArrayListUnmanaged(*std.Build.Step.Compile),
    current: *std.Build.Step,
) void {
    const entry = visited.getOrPut(b.graph.arena, current) catch @panic("OOM");
    if (entry.found_existing) return;
    if (current.cast(std.Build.Step.Compile)) |compile| {
        compileClosure(b, compile);
        if (compile.step.owner == b and compile.kind.isTest()) {
            test_compiles.append(b.graph.arena, compile) catch @panic("OOM");
        }
    }
    for (current.dependencies.items) |dependency| {
        step(b, visited, test_compiles, dependency);
    }
}

fn addTestRootGuards(
    b: *std.Build,
    test_compiles: []const *std.Build.Step.Compile,
) void {
    if (test_compiles.len == 0) return;
    const source = b.addWriteFiles().add(
        "tiny-test-root.zig",
        @embedFile("testroot.zig"),
    );
    const options = module_support.ModuleOptions.host(b, .debug, "");
    const guard_module = b.createModule(options.createOptionsWithRoot(
        source,
        &.{},
    ));
    const executable = b.addExecutable(.{
        .name = "tiny-test-root-guard",
        .root_module = guard_module,
    });
    var runs: std.AutoHashMapUnmanaged(
        *std.Build.Module,
        *std.Build.Step.Run,
    ) = .empty;
    for (test_compiles) |compile| {
        const entry = runs.getOrPut(
            b.graph.arena,
            compile.root_module,
        ) catch @panic("OOM");
        if (!entry.found_existing) {
            const root_source = compile.root_module.root_source_file orelse
                std.debug.panic(
                    "test compile step '{s}' has no root source",
                    .{compile.step.name},
                );
            const run = b.addRunArtifact(executable);
            run.setName(b.fmt(
                "validate test root for {s}",
                .{compile.step.name},
            ));
            run.addFileArg(root_source);
            _ = run.addOutputFileArg("validated");
            entry.value_ptr.* = run;
        }
        compile.step.dependOn(&entry.value_ptr.*.step);
    }
}

fn compileClosure(b: *std.Build, compile: *std.Build.Step.Compile) void {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    var modules: std.ArrayListUnmanaged(*std.Build.Module) = .empty;
    collectModules(b.graph.arena, &visited, &modules, compile.root_module);
    validateTargetRoles(b, compile, modules.items);
    var expected_optimize: ?std.builtin.OptimizeMode = null;
    var expected_optimize_module: ?*std.Build.Module = null;
    for (modules.items) |module| {
        const actual = module.optimize orelse continue;
        if (expected_optimize == null) {
            expected_optimize = actual;
            expected_optimize_module = module;
            continue;
        }
        if (actual != expected_optimize.?) {
            std.debug.panic(
                "compile step '{s}' mixes optimization roles: expected={s} through={s}, actual={s} through={s}",
                .{
                    compile.step.name,
                    @tagName(expected_optimize.?),
                    importPath(
                        b,
                        compile.root_module,
                        expected_optimize_module.?,
                    ),
                    @tagName(actual),
                    importPath(b, compile.root_module, module),
                },
            );
        }
    }
    for (modules.items, 0..) |left, left_index| {
        for (modules.items[left_index + 1 ..]) |right| {
            if (left == right) continue;
            if (sameRootSource(left, right)) {
                std.debug.panic(
                    "compile step '{s}' contains duplicate modules: source={f}, left={s} ({s}) through {s}, right={s} ({s}) through {s}",
                    .{
                        compile.step.name,
                        left.root_source_file.?,
                        left.owner.dep_prefix,
                        optionSummary(b, left.owner),
                        importPath(b, compile.root_module, left),
                        right.owner.dep_prefix,
                        optionSummary(b, right.owner),
                        importPath(b, compile.root_module, right),
                    },
                );
            }
        }
    }
}

const TargetMismatch = struct {
    expected: *std.Build.Module,
    actual: *std.Build.Module,
};

fn validateTargetRoles(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    modules: []const *std.Build.Module,
) void {
    const mismatch = targetMismatch(modules) orelse return;
    std.debug.panic(
        "compile step '{s}' mixes target roles: expected={s} ({s}) through={s}, actual={s} ({s}) through={s}",
        .{
            compile.step.name,
            mismatch.expected.owner.dep_prefix,
            targetSummary(b, mismatch.expected.resolved_target.?),
            importPath(b, compile.root_module, mismatch.expected),
            mismatch.actual.owner.dep_prefix,
            targetSummary(b, mismatch.actual.resolved_target.?),
            importPath(b, compile.root_module, mismatch.actual),
        },
    );
}

fn targetMismatch(
    modules: []const *std.Build.Module,
) ?TargetMismatch {
    std.debug.assert(modules.len > 0);
    var expected: ?*std.Build.Module = null;
    for (modules) |module| {
        const actual = module.resolved_target orelse continue;
        const expected_module = expected orelse {
            expected = module;
            continue;
        };
        if (!sameTarget(expected_module.resolved_target.?, actual)) {
            return .{ .expected = expected_module, .actual = module };
        }
    }
    return null;
}

fn targetSummary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) []const u8 {
    const resolved = target_support.query(target);
    const triple = resolved.zigTriple(b.graph.arena) catch @panic("OOM");
    const cpu = resolved.serializeCpuAlloc(b.graph.arena) catch @panic("OOM");
    const linker = if (resolved.dynamic_linker) |dynamic_linker|
        dynamic_linker.get() orelse "<none>"
    else
        "<none>";
    return b.fmt(
        "{s} cpu={s} ofmt={s} dynamic-linker={s}",
        .{
            triple,
            cpu,
            if (resolved.ofmt) |ofmt| @tagName(ofmt) else "<none>",
            linker,
        },
    );
}

fn collectModules(
    allocator: std.mem.Allocator,
    visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
    modules: *std.ArrayListUnmanaged(*std.Build.Module),
    module: *std.Build.Module,
) void {
    const entry = visited.getOrPut(allocator, module) catch @panic("OOM");
    if (entry.found_existing) return;
    modules.append(allocator, module) catch @panic("OOM");
    for (module.import_table.values()) |imported| {
        collectModules(allocator, visited, modules, imported);
    }
}

fn optionSummary(b: *std.Build, owner: *std.Build) []const u8 {
    var result: []const u8 = "";
    var iterator = owner.user_input_options.iterator();
    while (iterator.next()) |entry| {
        const value = switch (entry.value_ptr.*) {
            .flag => "true",
            .scalar => |scalar| scalar,
            .list => "<list>",
            .map => "<map>",
            .lazy_path => "<path>",
            .lazy_path_list => "<paths>",
        };
        result = b.fmt(
            "{s}{s}{s}={s}",
            .{
                result,
                if (result.len == 0) "" else ",",
                entry.key_ptr.*,
                value,
            },
        );
    }
    return result;
}

fn importPath(
    b: *std.Build,
    root: *std.Build.Module,
    target: *std.Build.Module,
) []const u8 {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    return findImportPath(b, &visited, root, target) orelse "<unreachable>";
}

fn findImportPath(
    b: *std.Build,
    visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
    current: *std.Build.Module,
    target: *std.Build.Module,
) ?[]const u8 {
    if (current == target) return "";
    const entry = visited.getOrPut(b.graph.arena, current) catch @panic("OOM");
    if (entry.found_existing) return null;
    for (current.import_table.keys(), current.import_table.values()) |name, imported| {
        const suffix = findImportPath(b, visited, imported, target) orelse continue;
        return if (suffix.len == 0)
            name
        else
            b.fmt("{s}.{s}", .{ name, suffix });
    }
    return null;
}

fn sameTarget(
    left: std.Build.ResolvedTarget,
    right: std.Build.ResolvedTarget,
) bool {
    return target_support.eql(left, right);
}

fn sameRootSource(
    left: *std.Build.Module,
    right: *std.Build.Module,
) bool {
    const left_path = left.root_source_file orelse return false;
    const right_path = right.root_source_file orelse return false;
    if (std.meta.activeTag(left_path) != right_path) return false;
    return switch (left_path) {
        .src_path => |left_source| blk: {
            const right_source = right_path.src_path;
            break :blk packageEqual(left_source.owner, right_source.owner) and
                std.mem.eql(u8, left_source.sub_path, right_source.sub_path);
        },
        .generated => |left_generated| blk: {
            const right_generated = right_path.generated;
            break :blk left_generated.index == right_generated.index and
                left_generated.up == right_generated.up and
                std.mem.eql(
                    u8,
                    left_generated.sub_path,
                    right_generated.sub_path,
                );
        },
        .cwd_relative => |left_relative| std.mem.eql(
            u8,
            left_relative,
            right_path.cwd_relative,
        ),
        .relative => |left_relative| left_relative.eql(right_path.relative),
        .dependency => |left_dependency| blk: {
            const right_dependency = right_path.dependency;
            break :blk packageEqual(
                left_dependency.dependency.builder,
                right_dependency.dependency.builder,
            ) and std.mem.eql(
                u8,
                left_dependency.sub_path,
                right_dependency.sub_path,
            );
        },
    };
}

fn packageEqual(left: *std.Build, right: *std.Build) bool {
    return std.mem.eql(u8, left.pkg_hash, right.pkg_hash);
}

fn resolvedTestTarget(query: std.Target.Query) !std.Build.ResolvedTarget {
    return .{
        .query = query,
        .result = try std.zig.system.resolveTargetQuery(std.testing.io, query),
    };
}

fn importedTargetMismatch(
    allocator: std.mem.Allocator,
    product_target: std.Build.ResolvedTarget,
    imported_target: ?std.Build.ResolvedTarget,
) !bool {
    var imported: std.Build.Module = undefined;
    imported.import_table = .empty;
    imported.resolved_target = imported_target;
    var product: std.Build.Module = undefined;
    product.import_table = .empty;
    product.resolved_target = product_target;
    defer product.import_table.deinit(allocator);
    try product.import_table.put(allocator, "imported", &imported);

    var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    defer visited.deinit(allocator);
    var modules: std.ArrayListUnmanaged(*std.Build.Module) = .empty;
    defer modules.deinit(allocator);
    collectModules(allocator, &visited, &modules, &product);
    return targetMismatch(modules.items) != null;
}

test "product compile rejects an imported host-role module" {
    const product = try resolvedTestTarget(try std.Target.Query.parse(.{
        .arch_os_abi = "wasm32-freestanding",
    }));
    const host = try resolvedTestTarget(.{});
    try std.testing.expect(try importedTargetMismatch(
        std.testing.allocator,
        product,
        host,
    ));
}

test "product compile accepts an imported target-neutral module" {
    const product = try resolvedTestTarget(try std.Target.Query.parse(.{
        .arch_os_abi = "wasm32-freestanding",
    }));
    try std.testing.expect(!try importedTargetMismatch(
        std.testing.allocator,
        product,
        null,
    ));
}
