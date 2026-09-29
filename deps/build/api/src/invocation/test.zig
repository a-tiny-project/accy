const std = @import("std");
const invocation = @import("root.zig");

const compiler = "/nix/store/0123456789abcdefghijklmnopqrstuv-zig/bin/zig";
const binding = invocation.Binding{
    .compiler = compiler,
    .directory = "/repo",
    .build_file = "/repo/build.zig",
};

test "compiler invocation refuses sealed publication without a record" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectError(error.UnrecordedCompilerBuild, invocation.receive(
        std.testing.allocator,
        &environment,
        binding,
    ));
    try invocation.refresh(std.testing.allocator, &environment, compiler, "/repo", &.{
        "build", "test", "--sysroot", "/sdk", "--error-limit", "31", "-fallow-so-scripts",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const recorded = try invocation.receive(arena.allocator(), &environment, binding);
    try std.testing.expectEqualStrings("/sdk", recorded.maker.sysroot.?);
    try std.testing.expectEqual(@as(?u32, 31), recorded.maker.error_limit);
    try std.testing.expectEqual(@as(?bool, true), recorded.maker.allow_so_scripts);
    try std.testing.expectEqual(@as(?[]const u8, null), recorded.maker.build_id);
    invocation.forget(&environment);
    try std.testing.expectError(error.UnrecordedCompilerBuild, invocation.receive(
        arena.allocator(),
        &environment,
        binding,
    ));
}

test "compiler invocation refresh replaces parent arguments and refuses stale binding" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try invocation.refresh(std.testing.allocator, &environment, compiler, "/repo", &.{
        "build", "test", "--error-limit", "9",
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const child = invocation.Binding{
        .compiler = compiler,
        .directory = "/repo/child",
        .build_file = "/repo/child/build.zig",
    };
    try std.testing.expectError(error.UnrecordedCompilerBuild, invocation.receive(
        arena.allocator(),
        &environment,
        child,
    ));
    try invocation.refresh(std.testing.allocator, &environment, compiler, child.directory, &.{
        "build", "check", "--search-prefix", "/first", "--search-prefix", "/second",
    });
    const recorded = try invocation.receive(arena.allocator(), &environment, child);
    try std.testing.expectEqual(@as(?u32, null), recorded.maker.error_limit);
    try std.testing.expectEqualStrings("check", recorded.arguments[1]);
    try std.testing.expectEqualStrings("/first", recorded.maker.search_prefixes[0]);
    try std.testing.expectEqualStrings("/second", recorded.maker.search_prefixes[1]);
    try environment.put("NIX_LDFLAGS", "-L/different");
    try std.testing.expectError(error.UnrecordedCompilerBuild, invocation.receive(
        arena.allocator(),
        &environment,
        child,
    ));
}

test "compiler invocation cannot qualify ignored dependencies or unknown maker options" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const []const u8{
        &.{ "build", "test", "--cache-poison=ignored" },
        &.{ "build", "test", "--cache-poison=disallowed" },
        &.{ "build", "test", "--unknown-maker-setting" },
        &.{ "build", "test", "--build-id=uuid" },
        &.{"version"},
    };
    for (cases) |args| {
        try invocation.refresh(std.testing.allocator, &environment, compiler, "/repo", args);
        try std.testing.expectError(error.UnrecordedCompilerBuild, invocation.receive(
            arena.allocator(),
            &environment,
            binding,
        ));
    }
}

test "compiler invocation size overflow revokes inherited publication authority" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try invocation.refresh(std.testing.allocator, &environment, compiler, "/repo", &.{"build"});
    try std.testing.expect(environment.contains(invocation.variable));
    const large = try std.testing.allocator.alloc(u8, invocation.maximum_bytes);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try environment.put("PATH", large);
    try invocation.refresh(std.testing.allocator, &environment, compiler, "/repo", &.{"build"});
    try std.testing.expect(!environment.contains(invocation.variable));
}

test "compiler invocation configuration observes qualified and unrecorded transitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.testing.io,
        .arena = allocator,
        .zig_exe = compiler,
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = @import("builtin").target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    const b = try std.Build.create(graph, .cwd(), &.{});
    const directory = try std.process.currentPathAlloc(std.testing.io, allocator);
    try invocation.refresh(allocator, &graph.environ_map, compiler, directory, &.{"build"});
    try std.testing.expect(try invocation.configuration.observe(b) != null);
    try std.testing.expectEqual(std.Build.Graph.CachePoison.poisoned, graph.cache_poison);
    invocation.forget(&graph.environ_map);
    graph.cache_poison = .pure;
    try std.testing.expectEqual(null, try invocation.configuration.observe(b));
    try std.testing.expectEqual(std.Build.Graph.CachePoison.poisoned, graph.cache_poison);
    graph.cache_poison = .ignored;
    try std.testing.expectEqual(null, try invocation.configuration.observe(b));
    graph.cache_poison = .disallowed;
    try std.testing.expectEqual(null, try invocation.configuration.observe(b));
}

test "compiler invocation records release modes passed to package children" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const modes = [_][]const u8{
        "--release",      "--release=off",  "--release=any",
        "--release=fast", "--release=safe", "--release=small",
    };
    for (modes) |mode| {
        const args = [_][]const u8{
            "build",       "-fno-incremental", "-j1",      "test",          mode,
            "--cache-dir", "/repo/.zig-cache", "--prefix", "/repo/zig-out",
        };
        try invocation.refresh(std.testing.allocator, &environment, compiler, "/repo", &args);
        const recorded = try invocation.receive(arena.allocator(), &environment, binding);
        try std.testing.expectEqualDeep(args[0..], recorded.arguments);
    }
    try invocation.refresh(std.testing.allocator, &environment, compiler, "/repo", &.{
        "build", "test", "--release=unknown",
    });
    try std.testing.expectError(error.UnrecordedCompilerBuild, invocation.receive(
        arena.allocator(),
        &environment,
        binding,
    ));
}
