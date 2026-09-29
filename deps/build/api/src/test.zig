const std = @import("std");
const api = @import("root.zig");

test {
    _ = @import("catalog/test.zig");
}

fn testBuild(allocator: std.mem.Allocator) !*std.Build {
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.Options.debug_io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    const b = try std.Build.create(graph, .cwd(), &.{});
    b.dep_prefix = "fixture.";
    return b;
}

fn packageGraph(b: *std.Build) void {
    makePackageGraph(b, false);
}

fn bitcodeGraph(b: *std.Build) void {
    makePackageGraph(b, true);
}

fn makePackageGraph(b: *std.Build, emit_bitcode: bool) void {
    const module_options = api.ModuleOptions{
        .target = b.graph.host,
        .optimize = .debug,
    };
    const compile = b.addTest(.{
        .name = "sample",
        .root_module = b.createModule(module_options.createOptions(b, "sample.zig", &.{})),
    });
    if (emit_bitcode) {
        _ = compile.getEmittedLlvmBc();
    } else {
        _ = compile.getEmittedLlvmIr();
    }
    b.step("compile", "Compile selected tests").dependOn(&compile.step);
    const run = b.addRunArtifact(compile);
    b.step("sample", "Run selected tests").dependOn(&run.step);
}

test "check projection inherits finalized backend and test-root validation" {
    const graphs = [_]api.PackageGraph{ packageGraph, bitcodeGraph };
    for (graphs) |graph| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const b = try testBuild(arena.allocator());
        api.package(b, graph);
        const original_step = &b.top_level_steps.get("compile").?.step;
        const check_step = &b.top_level_steps.get("sample-check").?.step;
        try std.testing.expectEqual(@as(usize, 1), original_step.dependencies.items.len);
        try std.testing.expectEqual(@as(usize, 1), check_step.dependencies.items.len);
        const original = original_step.dependencies.items[0].cast(std.Build.Step.Compile).?;
        const projected = check_step.dependencies.items[0].cast(std.Build.Step.Compile).?;
        try std.testing.expect(original != projected);
        try std.testing.expect(original.generated_llvm_ir != .none or
            original.generated_llvm_bc != .none);
        try std.testing.expect(original.generated_bin != .none);
        try std.testing.expect(projected.generated_llvm_ir == .none);
        try std.testing.expect(projected.generated_llvm_bc == .none);
        try std.testing.expect(projected.generated_bin == .none);
        try std.testing.expectEqual(true, original.use_llvm);
        try std.testing.expectEqual(original.use_llvm, projected.use_llvm);
        try std.testing.expect(original.root_module == projected.root_module);
        try std.testing.expectEqual(@as(usize, 1), original.step.dependencies.items.len);
        try std.testing.expectEqualSlices(
            *std.Build.Step,
            original.step.dependencies.items,
            projected.step.dependencies.items,
        );
        try std.testing.expect(
            original.step.dependencies.items[0].cast(std.Build.Step.Run) != null,
        );
    }
}

test "check projection exists before iteration observations bind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    b.dep_prefix = "";
    _ = try b.addUserInputOption(api.iterationSelectedStepOption, "sample-check");
    _ = try b.addUserInputOption(api.iterationReceiptDirectoryOption, "/tmp/tiny-check-lifecycle");
    _ = try b.addUserInputOption(api.iterationReceiptTokenOption, "check-lifecycle");
    api.package(b, packageGraph);
    const selected = &b.top_level_steps.get("sample-check").?.step;
    const observation = &b.top_level_steps.get("iteration-observe").?.step;
    try std.testing.expectEqual(@as(usize, 1), observation.dependencies.items.len);
    const marker = observation.dependencies.items[0].cast(std.Build.Step.Run).?;
    try std.testing.expect(std.mem.indexOfScalar(
        *std.Build.Step,
        marker.step.dependencies.items,
        selected,
    ) != null);
}

const NativeInput = enum {
    object,
    assembly,
    c_source,
    c_sources,
    include,
    system_include,
    library_path,
    rpath,
};

fn addNativeInput(
    imported: *std.Build.Module,
    kind: NativeInput,
    path: std.Build.LazyPath,
) void {
    switch (kind) {
        .object => imported.addObjectFile(path),
        .assembly => imported.addAssemblyFile(path),
        .c_source => imported.addCSourceFile(.{ .file = path }),
        .c_sources => imported.addCSourceFiles(.{ .root = path, .files = &.{"input.c"} }),
        .include => imported.addIncludePath(path),
        .system_include => imported.addSystemIncludePath(path),
        .library_path => imported.addLibraryPath(path),
        .rpath => imported.addRPath(path),
    }
}

fn nativeInputsGraph(b: *std.Build) void {
    const kinds = std.enums.values(NativeInput);
    const options = api.ModuleOptions{ .target = b.graph.host, .optimize = .debug };
    for ([_]bool{ false, true }) |generated| {
        for (kinds) |kind| {
            const name = b.fmt("{t}-{s}", .{ kind, if (generated) "generated" else "source" });
            const path = if (generated)
                b.addWriteFiles().add("input", "fixture")
            else
                b.path("input");
            const imported = b.createModule(options.createOptions(b, "imported.zig", &.{}));
            imported.addImport("cycle", imported);
            addNativeInput(imported, kind, path);
            const compile = b.addTest(.{
                .name = name,
                .root_module = b.createModule(options.createOptions(b, "sample.zig", &.{
                    .{ .name = "input", .module = imported },
                })),
            });
            compile.incremental = true;
            b.step(name, "Compile native input fixture").dependOn(&compile.step);
        }
    }
}

test "generated native paths select fresh consumers through imports and check projections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    api.package(b, nativeInputsGraph);
    for ([_]bool{ false, true }) |generated| {
        for (std.enums.values(NativeInput)) |kind| {
            for ([_][]const u8{ "", "-check" }) |suffix| {
                const name = b.fmt("{t}-{s}{s}", .{
                    kind, if (generated) "generated" else "source", suffix,
                });
                const step = &b.top_level_steps.get(name).?.step;
                const compile = step.dependencies.items[0].cast(std.Build.Step.Compile).?;
                try std.testing.expectEqual(!generated, compile.incremental.?);
            }
        }
    }
}

fn generatedLinkGraph(b: *std.Build) void {
    const options = api.ModuleOptions{ .target = b.graph.host, .optimize = .debug };
    const library = b.addLibrary(.{
        .name = "input",
        .linkage = .static,
        .root_module = b.createModule(options.createOptions(b, "library.zig", &.{})),
    });
    const plain = b.addTest(.{
        .name = "plain",
        .root_module = b.createModule(options.createOptions(b, "plain.zig", &.{})),
    });
    const linked = b.addTest(.{
        .name = "linked",
        .root_module = b.createModule(options.createOptions(b, "linked.zig", &.{})),
    });
    linked.root_module.linkLibrary(library);
    const script = b.addTest(.{
        .name = "script",
        .root_module = b.createModule(options.createOptions(b, "script.zig", &.{})),
    });
    script.setLinkerScript(b.addWriteFiles().add("script.ld", "fixture"));
    for ([_]*std.Build.Step.Compile{ library, plain, linked, script }) |compile| {
        b.step(compile.name, "Compile link fixture").dependOn(&compile.step);
    }
}

test "generated libraries and scripts restart their consumers while source producers inherit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    api.package(b, generatedLinkGraph);
    for ([_][]const u8{ "input", "plain", "linked", "script" }, 0..) |name, index| {
        const step = &b.top_level_steps.get(name).?.step;
        const compile = step.dependencies.items[0].cast(std.Build.Step.Compile).?;
        const expected: ?bool = if (index < 2) null else false;
        try std.testing.expectEqual(expected, compile.incremental);
    }
}

test "compiler manifest refuses undeclared native inputs and linked artifact cycles" {
    const manifest = @import("manifest/root.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const b = try testBuild(allocator);
    const module = b.createModule(.{ .target = b.graph.host, .optimize = .debug });
    const library = b.addLibrary(.{ .name = "cycle", .root_module = module });
    var source = std.Build.Module.CSourceFile{ .file = b.path("absent.c"), .flags = &.{
        "-include", "/unrecorded/header.h",
    } };
    var sources = std.Build.Module.CSourceFiles{
        .root = b.path("."),
        .files = &.{"absent.c"},
        .flags = &.{"@unrecorded.rsp"},
        .language = null,
    };
    const cases = [_]struct { object: std.Build.Module.LinkObject, refusal: anyerror }{
        .{ .object = .{ .c_source_file = &source }, .refusal = error.UnqualifiedCompilerCInputs },
        .{ .object = .{ .c_source_files = &sources }, .refusal = error.UnqualifiedCompilerCInputs },
        .{
            .object = .{ .assembly_file = b.path("absent.s") },
            .refusal = error.UnqualifiedCompilerAssemblyTarget,
        },
    };
    const plan = manifest.linked.Plan{ .build = b, .excluded = &.{} };
    var foreign = b.graph.host;
    foreign.result.os.tag = .macos;
    module.resolved_target = foreign;
    for (cases) |case| {
        module.link_objects.clearRetainingCapacity();
        try module.link_objects.append(allocator, case.object);
        var inputs = manifest.paths.Inputs{ .build = b };
        var output = std.Io.Writer.Allocating.init(allocator);
        var json = std.json.Stringify{ .writer = &output.writer };
        try json.beginObject();
        try std.testing.expectError(case.refusal, manifest.native.module(
            &json,
            &inputs,
            module,
            "module",
            &plan,
        ));
        try std.testing.expectEqual(0, inputs.files.items.len);
    }
    module.resolved_target = b.graph.host;
    module.link_objects.clearRetainingCapacity();
    try module.link_objects.append(allocator, .{ .other_step = library });
    try std.testing.expectError(
        error.CompilerLinkedCycle,
        manifest.linked.Plan.init(b, library, &.{}),
    );
}

test "compiler manifest captures a module rooted directly in the build directory" {
    const manifest = @import("manifest/root.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "main.zig",
        .data = "pub fn main() void {}\n",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    b.root = .{ .root_dir = .{
        .path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator()),
        .handle = temporary.dir,
    } };
    var inputs = manifest.paths.Inputs{ .build = b };
    const name = try inputs.module(b.path("main.zig"), "module/source");
    try std.testing.expectEqualStrings("module/source/main.zig", name);
    try std.testing.expectEqual(1, inputs.files.items.len);
    try std.testing.expectEqualStrings(name, inputs.files.items[0].identity.path);
    try std.testing.expectEqualStrings("main.zig", inputs.files.items[0].path.src_path.sub_path);
}
