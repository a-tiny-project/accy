const std = @import("std");
const catalog = @import("root.zig");

fn testBuild(allocator: std.mem.Allocator) !*std.Build {
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.testing.io,
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

test "build facts preserve source roots imports and product edges without running effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const helper = b.createModule(.{ .root_source_file = b.path("src/helper.zig") });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "helper", .module = helper }},
    });
    helper.addImport("cycle", module);
    const executable = b.addExecutable(.{ .name = "example", .root_module = module });
    const run = b.addRunArtifact(executable);
    b.step("example", "Run example").dependOn(&run.step);
    const facts = try catalog.graph.capture(b, null);
    try std.testing.expectEqual(2, facts.modules.len);
    try std.testing.expectEqualStrings("src/main.zig", facts.modules[0].source.value);
    try std.testing.expectEqualStrings("src/helper.zig", facts.modules[1].source.value);
    try std.testing.expectEqual(1, facts.modules[0].imports[0].module);
    try std.testing.expectEqual(0, facts.modules[1].imports[0].module);
    var compiles: u32 = 0;
    for (facts.steps) |step| if (step.compile) |compile| {
        compiles += 1;
        try std.testing.expectEqualStrings("example", compile.name);
        try std.testing.expectEqual(0, compile.module);
    };
    try std.testing.expectEqual(1, compiles);
}

test "build facts distinguish generated inputs and decorated script arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const run = b.addSystemCommand(&.{ "python3", "bin/generate" });
    run.setCwd(b.path("assets"));
    run.addFileArg2(b.path("data/input.json"), .{ .prefix = "--input=", .suffix = ":json" });
    const generated = b.addWriteFiles().add("options.zig", "pub const enabled = true;\n");
    run.addFileArg(generated);
    b.step("generate", "Run generator").dependOn(&run.step);
    const facts = try catalog.graph.capture(b, null);
    var runs: u32 = 0;
    for (facts.steps) |step| if (step.run) |effect| {
        runs += 1;
        try std.testing.expectEqualStrings("assets", effect.cwd.value);
        try std.testing.expectEqualStrings("python3", effect.arguments[0].value);
        try std.testing.expectEqualStrings("bin/generate", effect.arguments[1].value);
        try std.testing.expectEqualStrings("data/input.json", effect.arguments[2].path.value);
        try std.testing.expectEqualStrings("--input=", effect.arguments[2].prefix);
        try std.testing.expectEqualStrings(":json", effect.arguments[2].suffix);
        try std.testing.expectEqual(.generated, effect.arguments[3].path.kind);
    };
    try std.testing.expectEqual(1, runs);
}

test "build facts export is opt in and cannot execute a product dependency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disabled = try testBuild(arena.allocator());
    try std.testing.expectEqual(null, catalog.configure(disabled));
    try std.testing.expect(!disabled.top_level_steps.contains("build-facts"));
    const dependency = try testBuild(arena.allocator());
    dependency.pkg_hash = "fixture";
    _ = try dependency.addUserInputOption("build-facts", "true");
    try std.testing.expectEqual(null, catalog.configure(dependency));
    const b = try testBuild(arena.allocator());
    _ = try b.addUserInputOption("build-facts", "true");
    const selected = catalog.configure(b).?;
    const effect = b.addSystemCommand(&.{ "must-not-run", "side-effect" });
    b.step("product", "Run product").dependOn(&effect.step);
    const bytes = try catalog.graph.encode(b, selected);
    const parsed = try std.json.parseFromSlice(
        catalog.model.Catalog,
        arena.allocator(),
        bytes,
        .{},
    );
    try std.testing.expectEqualStrings(catalog.model.schema, parsed.value.schema);
    for (parsed.value.roots) |root| {
        try std.testing.expect(!std.mem.eql(u8, root.name, "build-facts"));
    }
    catalog.finalize(b, selected);
    try std.testing.expectEqual(1, selected.dependencies.items.len);
    const install = selected.dependencies.items[0];
    try std.testing.expectEqual(.install_file, install.tag);
    try std.testing.expectEqual(1, install.dependencies.items.len);
    const write = install.dependencies.items[0];
    try std.testing.expectEqual(.write_file, write.tag);
    try std.testing.expectEqual(0, write.dependencies.items.len);
}

test "build facts normalize source paths and encode one deterministic graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try testBuild(arena.allocator());
    const first = b.step("z-last", "Last name");
    const second = b.step("a-first", "First name");
    second.dependOn(first);
    var context = try catalog.source.Context.init(b);
    defer context.deinit();
    const normalized = try context.path(b.path("src/../src/main.zig"));
    try std.testing.expectEqualStrings("src/main.zig", normalized.value);
    const outside = try context.path(b.path("../sibling/main.zig"));
    try std.testing.expectEqualStrings("../sibling/main.zig", outside.value);
    const bytes = try catalog.graph.encode(b, null);
    const repeat = try catalog.graph.encode(b, null);
    try std.testing.expectEqualStrings(bytes, repeat);
    const parsed = try std.json.parseFromSlice(
        catalog.model.Catalog,
        arena.allocator(),
        bytes,
        .{},
    );
    var found = false;
    for (parsed.value.roots, 0..) |root, index| {
        if (index > 0) try std.testing.expect(std.mem.lessThan(
            u8,
            parsed.value.roots[index - 1].name,
            root.name,
        ));
        if (!std.mem.eql(u8, root.name, "a-first")) continue;
        found = true;
        const dependencies = parsed.value.steps[root.step].dependencies;
        try std.testing.expectEqual(1, dependencies.len);
        try std.testing.expectEqualStrings("z-last", parsed.value.steps[dependencies[0]].name);
    }
    try std.testing.expect(found);
}
