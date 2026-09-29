const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");
const incremental = @import("incremental.zig");
const module = @import("module.zig");
const resource = @import("resource.zig");

const fs_io = std.Options.debug_io;
const transport_artifact_name = "tiny-build-child";
const transport_mode = "promoted-test-filters";
const launcher_transport_mode = "launcher-capability";
const launcher_filter_transport_mode = "launcher-capability-promoted-test-filters";
const launcher_cache_marker = "--tiny-child-cache-dir";
pub const cache_directory_argument = "--cache-dir";
const layout_path_options: std.Build.Step.Run.PathArgOptions = .{
    .make_absolute = true,
};
const cache_lease_protocol = "tiny-cache-lease-v1";
const cache_mode_build_root = "build-root";
const max_child_arguments = 256;
const max_test_filters = 32;
const max_transport_arguments = 4 + max_child_arguments + 1 + 2 * max_test_filters;

pub const Layout = struct {
    local_cache_dir: std.Build.LazyPath,
    install_prefix: std.Build.LazyPath,

    pub fn from(build_layout: anytype) Layout {
        return .{
            .local_cache_dir = build_layout.local_cache_dir,
            .install_prefix = build_layout.install_prefix,
        };
    }
};

pub const Arguments = union(enum) {
    fixed: []const []const u8,
    structured: []const Argument,
    passthru,
    promoted_test_filters,
    none,
};

pub const Argument = union(enum) {
    bytes: []const u8,
    file: std.Build.LazyPath,
    path: std.Build.LazyPath,
};

pub const BuildFileOption = union(enum) {
    prefixed: struct {
        prefix: []const u8,
        artifact: std.Build.LazyPath,
    },
    separate: struct {
        name: []const u8,
        artifact: std.Build.LazyPath,
    },
};

pub const Launcher = struct {
    fallback_zig_exe: []const u8,
    package_cache_dir: std.Build.LazyPath,
    scoped_cache_dir: std.Build.LazyPath,
};

pub const Options = struct {
    zig_exe: ?[]const u8 = null,
    launcher: ?Launcher = null,
    cwd: std.Build.LazyPath,
    layout: Layout,
    steps: []const []const u8 = &.{},
    build_options: []const []const u8 = &.{},
    build_file_option: ?BuildFileOption = null,
    arguments: Arguments = .none,
    jobs: ?u32 = null,
    resource_class: ?resource.Class = null,
    name: ?[]const u8 = null,
    iteration: ?incremental.Observation = null,
};

pub fn main(init: std.process.Init) u8 {
    return transport(init) catch |err| {
        transportDiagnostic(err);
        return switch (err) {
            error.MissingTransportMode,
            error.UnsupportedTransportMode,
            error.MissingChildCommand,
            error.MissingArgumentSeparator,
            error.MissingTestFilterValue,
            error.EmptyTestFilterValue,
            error.UnsupportedArgument,
            error.TooManyTestFilters,
            error.TooManyChildArguments,
            error.TooManyTransportArguments,
            error.MissingLauncherArguments,
            error.InvalidCacheMarker,
            => 2,
            else => 1,
        };
    };
}

pub fn add(b: *std.Build, options: Options) *std.Build.Step.Run {
    return addCommand(b, options, .one_shot);
}

pub fn watch(b: *std.Build, options: Options) *std.Build.Step.Run {
    return addCommand(b, options, .persistent);
}

pub fn append(
    b: *std.Build,
    run: *std.Build.Step.Run,
    options: Options,
) *std.Build.Step.Run {
    std.debug.assert(options.resource_class == null);
    std.debug.assert(options.launcher == null);
    switch (options.arguments) {
        .promoted_test_filters => unreachable,
        else => {},
    }
    run.addArg(options.zig_exe orelse b.graph.zig_exe);
    return configureCommand(b, run, options, .one_shot);
}

fn addCommand(
    b: *std.Build,
    options: Options,
    lifetime: incremental.Lifetime,
) *std.Build.Step.Run {
    if (options.launcher != null) {
        std.debug.assert(options.zig_exe == null);
    }
    const zig_exe = options.zig_exe orelse b.graph.zig_exe;
    const promoted_filters = switch (options.arguments) {
        .promoted_test_filters => true,
        else => false,
    };
    const uses_transport = options.launcher != null or promoted_filters;
    const run = if (options.resource_class) |class|
        resource.addDependencyRun(b, class)
    else if (uses_transport)
        b.addRunArtifact(
            b.dependency("build_api", .{}).artifact(
                transport_artifact_name,
            ),
        )
    else
        b.addSystemCommand(&.{zig_exe});
    if (uses_transport and options.resource_class != null) {
        run.addArtifactArg(b.dependency("build_api", .{}).artifact(
            transport_artifact_name,
        ));
    }
    if (options.launcher) |launcher| {
        run.addArg(if (promoted_filters)
            launcher_filter_transport_mode
        else
            launcher_transport_mode);
        run.addArg(launcher.fallback_zig_exe);
        run.addDirectoryArg2(launcher.package_cache_dir, layout_path_options);
        run.addDirectoryArg2(launcher.scoped_cache_dir, layout_path_options);
    } else if (promoted_filters) {
        run.addArg(transport_mode);
        run.addArg(zig_exe);
    } else if (options.resource_class != null) {
        run.addArg(zig_exe);
    }
    return configureCommand(b, run, options, lifetime);
}

fn configureCommand(
    b: *std.Build,
    run: *std.Build.Step.Run,
    options: Options,
    lifetime: incremental.Lifetime,
) *std.Build.Step.Run {
    run.addArgs(incremental.buildArguments(lifetime));
    if (options.jobs) |jobs| run.addArg(b.fmt("-j{d}", .{jobs}));
    if (options.iteration) |observation| {
        run.addArg("iteration-observe");
        incremental.appendObservation(b, run, observation);
    } else {
        run.addArgs(options.steps);
    }
    run.addArgs(options.build_options);
    if (options.build_file_option) |option| {
        appendBuildFileOption(run, option);
    } else if (options.launcher != null) {
        run.addArg("--build-file");
        run.addFileArg2(options.cwd.path(b, "build.zig"), layout_path_options);
    }
    if (options.launcher != null) {
        run.addArg(launcher_cache_marker);
    } else {
        run.addArg(cache_directory_argument);
        run.addDirectoryArg2(options.layout.local_cache_dir, layout_path_options);
    }
    run.addArg("--prefix");
    run.addDirectoryArg2(options.layout.install_prefix, layout_path_options);
    switch (options.arguments) {
        .fixed => |args| if (args.len != 0) {
            run.addArg("--");
            run.addArgs(args);
        },
        .structured => |args| if (args.len != 0) {
            run.addArg("--");
            for (args) |arg| switch (arg) {
                .bytes => |bytes| run.addArg(bytes),
                .file => |path| run.addFileArg(path),
                .path => |path| run.addDirectoryArg2(path, .{}),
            };
        },
        .passthru => {
            run.addArg("--");
            run.addPassthruArgs();
        },
        .promoted_test_filters => {
            run.addArg("--");
            run.addPassthruArgs();
        },
        .none => {},
    }
    run.setCwd(options.cwd);
    run.has_side_effects = true;
    if (options.name) |name| run.setName(name);
    return run;
}

fn appendBuildFileOption(
    run: *std.Build.Step.Run,
    option: BuildFileOption,
) void {
    switch (option) {
        .prefixed => |prefixed| {
            std.debug.assert(prefixed.prefix.len != 0);
            std.debug.assert(std.mem.endsWith(u8, prefixed.prefix, "="));
            run.addPrefixedFileArg(prefixed.prefix, prefixed.artifact);
        },
        .separate => |separate| {
            std.debug.assert(separate.name.len != 0);
            std.debug.assert(!std.mem.endsWith(u8, separate.name, "="));
            run.addArg(separate.name);
            run.addFileArg2(separate.artifact, .{ .make_absolute = true });
        },
    }
}

test "launcher child builds identify their package and preserve explicit build files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const graph = try allocator.create(std.Build.Graph);
    graph.* = .{
        .io = std.testing.io,
        .arena = allocator,
        .zig_exe = "zig",
        .environ_map = .init(allocator),
        .host = .{ .query = .{}, .result = builtin.target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };
    const b = try std.Build.create(graph, .cwd(), &.{});
    for ([_]struct { launcher: bool, explicit: bool }{
        .{ .launcher = true, .explicit = false },
        .{ .launcher = true, .explicit = true },
        .{ .launcher = false, .explicit = false },
    }) |case| {
        const run = b.addSystemCommand(&.{"child"});
        const cwd = b.path("package");
        const expected = if (case.explicit) b.path("custom.zig") else cwd.path(b, "build.zig");
        _ = configureCommand(b, run, .{
            .cwd = cwd,
            .layout = .{ .local_cache_dir = b.path("cache"), .install_prefix = b.path("out") },
            .steps = &.{"test"},
            .launcher = if (case.launcher) .{
                .fallback_zig_exe = "zig",
                .package_cache_dir = b.path("cache"),
                .scoped_cache_dir = b.path("scoped"),
            } else null,
            .build_file_option = if (case.explicit) .{ .separate = .{
                .name = "--build-file",
                .artifact = expected,
            } } else null,
        }, .one_shot);
        var found: usize = 0;
        for (run.argv.items, 0..) |argument, index| {
            if (argument != .bytes or !std.mem.eql(u8, argument.bytes, "--build-file")) continue;
            try std.testing.expect(index + 1 < run.argv.items.len);
            const file = run.argv.items[index + 1].lazy_path;
            try std.testing.expect(file.make_absolute);
            try std.testing.expectEqual(expected.src_path.owner, file.lazy_path.src_path.owner);
            try std.testing.expectEqualStrings(
                expected.src_path.sub_path,
                file.lazy_path.src_path.sub_path,
            );
            found += 1;
        }
        try std.testing.expectEqual(
            @as(usize, @intFromBool(case.launcher or case.explicit)),
            found,
        );
    }
}

test "file build options precede the runtime argument separator" {
    const source = @embedFile("child.zig");
    const file_option = std.mem.indexOf(
        u8,
        source,
        "appendBuildFileOption(run, option);",
    ).?;
    const runtime_separator = std.mem.indexOf(
        u8,
        source,
        "run.addArg(\"--\");",
    ).?;
    try std.testing.expect(file_option < runtime_separator);
}

test "separate file build options preserve two argument spelling" {
    const source = @embedFile("child.zig");
    const branch = std.mem.indexOf(
        u8,
        source,
        ".separate => |separate| {",
    ).?;
    const name = std.mem.indexOfPos(
        u8,
        source,
        branch,
        "run.addArg(separate.name);",
    ).?;
    const artifact = std.mem.indexOfPos(
        u8,
        source,
        name,
        "run.addFileArg2(separate.artifact, .{ .make_absolute = true });",
    ).?;
    try std.testing.expect(branch < name);
    try std.testing.expect(name < artifact);
}

test "child build layout paths are absolute command arguments" {
    try std.testing.expect(layout_path_options.make_absolute);
    const source = @embedFile("child.zig");
    const uses = [_][]const u8{
        "run.addDirectoryArg2(launcher.package_cache_dir, layout_path_options);",
        "run.addDirectoryArg2(launcher.scoped_cache_dir, layout_path_options);",
        "run.addDirectoryArg2(options.layout.local_cache_dir, layout_path_options);",
        "run.addDirectoryArg2(options.layout.install_prefix, layout_path_options);",
    };
    for (uses) |use| try std.testing.expect(std.mem.indexOf(u8, source, use) != null);
}

pub fn addLocalTransport(b: *std.Build) *std.Build.Step.Compile {
    const module_options = module.ModuleOptions.host(b, .small, "");
    return b.addExecutable(.{
        .name = transport_artifact_name,
        .root_module = b.createModule(module_options.createOptionsWithRoot(
            b.path("src/child.zig"),
            &.{},
        )),
        .use_llvm = backend.hostTool(b),
    });
}

pub fn addLocalTests(
    b: *std.Build,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    const module_options = module.ModuleOptions{
        .target = b.graph.host,
        .optimize = .debug,
    };
    return b.addTest(.{
        .name = "tiny-build-child-test",
        .root_module = b.createModule(module_options.createOptionsWithRoot(
            b.path("src/child.zig"),
            &.{},
        )),
        .filters = filters,
        .use_llvm = backend.hostTool(b),
    });
}

fn transport(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);
    if (process_args.len == 0) return error.MissingTransportMode;
    if (process_args.len -| 1 > max_transport_arguments) {
        return error.TooManyTransportArguments;
    }
    var argument_storage: [max_transport_arguments][]const u8 = undefined;
    const arguments = argument_storage[0..process_args.len -| 1];
    for (process_args[1..], arguments) |source, *destination| {
        destination.* = source[0..source.len];
    }
    var executable_storage: [std.fs.max_path_bytes]u8 = undefined;
    const command = transportCommand(
        allocator,
        init.environ_map,
        arguments,
        &executable_storage,
    ) catch |err| switch (err) {
        error.MissingRepositoryRoot => @panic("worktree cache protocol requires TINY_REPO_ROOT"),
        error.RelativeRepositoryRoot => @panic("TINY_REPO_ROOT must be absolute"),
        else => return err,
    };
    @import("invocation/root.zig").forget(init.environ_map);
    var child = try std.process.spawn(init.io, .{
        .argv = command,
        .environ_map = init.environ_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(init.io);
    return relayTermination(try child.wait(init.io));
}

fn transportCommand(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    arguments: []const []const u8,
    executable_storage: []u8,
) ![]const []const u8 {
    if (arguments.len == 0) return error.MissingTransportMode;
    if (std.mem.eql(u8, arguments[0], transport_mode)) {
        return promotedCommand(allocator, arguments);
    }
    if (std.mem.eql(u8, arguments[0], launcher_transport_mode)) {
        return launcherCommand(
            allocator,
            environment,
            arguments,
            executable_storage,
            false,
        );
    }
    if (std.mem.eql(u8, arguments[0], launcher_filter_transport_mode)) {
        return launcherCommand(
            allocator,
            environment,
            arguments,
            executable_storage,
            true,
        );
    }
    return error.UnsupportedTransportMode;
}

const LauncherSelection = struct {
    zig_exe: []const u8,
    cache_dir: []const u8,
};

fn selectLauncher(
    environment: *const std.process.Environ.Map,
    fallback_zig_exe: []const u8,
    package_cache_dir: []const u8,
    scoped_cache_dir: []const u8,
    executable_storage: []u8,
) !LauncherSelection {
    const protocol = environment.get("TINY_ZIG_CACHE_LEASE_PROTOCOL") orelse
        return .{ .zig_exe = fallback_zig_exe, .cache_dir = scoped_cache_dir };
    if (!std.mem.eql(u8, protocol, cache_lease_protocol)) {
        return .{ .zig_exe = fallback_zig_exe, .cache_dir = scoped_cache_dir };
    }
    const root = environment.get("TINY_REPO_ROOT") orelse
        return error.MissingRepositoryRoot;
    if (!std.fs.path.isAbsolute(root)) return error.RelativeRepositoryRoot;
    const zig_exe = std.fmt.bufPrint(
        executable_storage,
        "{s}" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++
            "worktree" ++ std.fs.path.sep_str ++ "bin" ++ std.fs.path.sep_str ++ "zig",
        .{std.mem.trimEnd(u8, root, std.fs.path.sep_str)},
    ) catch return error.RepositoryRootTooLong;
    const mode = environment.get("TINY_ZIG_CACHE_MODE");
    return .{
        .zig_exe = zig_exe,
        .cache_dir = if (std.mem.eql(u8, mode orelse "", cache_mode_build_root))
            package_cache_dir
        else
            scoped_cache_dir,
    };
}

fn launcherCommand(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    arguments: []const []const u8,
    executable_storage: []u8,
    promote_filters: bool,
) ![]const []const u8 {
    if (arguments.len < 5) return error.MissingLauncherArguments;
    const transported = arguments[4..];
    const separator = if (promote_filters)
        findSeparator(transported) orelse return error.MissingArgumentSeparator
    else
        transported.len;
    const child_arguments = transported[0..separator];
    if (child_arguments.len == 0) return error.MissingChildCommand;
    if (child_arguments.len > max_child_arguments) return error.TooManyChildArguments;
    if (countCacheMarkers(child_arguments) != 1) return error.InvalidCacheMarker;
    const runtime_arguments = if (promote_filters)
        transported[separator + 1 ..]
    else
        &.{};
    const filter_count = try countTestFilters(runtime_arguments);
    const inherited_count = countInheritedTestFilters(child_arguments);
    if (inherited_count > max_test_filters - filter_count) return error.TooManyTestFilters;
    const selected = try selectLauncher(
        environment,
        arguments[1],
        arguments[2],
        arguments[3],
        executable_storage,
    );
    const command = try allocator.alloc(
        []const u8,
        1 + child_arguments.len + 1 + filter_count,
    );
    command[0] = selected.zig_exe;
    var command_index: usize = 1;
    for (child_arguments) |argument| {
        if (std.mem.eql(u8, argument, launcher_cache_marker)) {
            command[command_index] = cache_directory_argument;
            command[command_index + 1] = selected.cache_dir;
            command_index += 2;
        } else {
            command[command_index] = argument;
            command_index += 1;
        }
    }
    var runtime_index: usize = 0;
    while (try nextTestFilter(runtime_arguments, &runtime_index)) |value| {
        command[command_index] = try std.fmt.allocPrint(
            allocator,
            "-Dtest-filter={s}",
            .{value},
        );
        command_index += 1;
    }
    std.debug.assert(command_index == command.len);
    return command;
}

fn findSeparator(arguments: []const []const u8) ?usize {
    for (arguments, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--")) return index;
    }
    return null;
}

fn countCacheMarkers(arguments: []const []const u8) u32 {
    var count: u32 = 0;
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, launcher_cache_marker)) count += 1;
    }
    return count;
}

fn promotedCommand(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) ![]const []const u8 {
    if (arguments.len == 0) return error.MissingTransportMode;
    if (!std.mem.eql(u8, arguments[0], transport_mode)) {
        return error.UnsupportedTransportMode;
    }
    const separator = for (arguments[1..], 1..) |argument, index| {
        if (std.mem.eql(u8, argument, "--")) break index;
    } else return error.MissingArgumentSeparator;
    const child_arguments = arguments[1..separator];
    if (child_arguments.len == 0) return error.MissingChildCommand;
    if (child_arguments.len > max_child_arguments) {
        return error.TooManyChildArguments;
    }
    const runtime_arguments = arguments[separator + 1 ..];
    const filter_count = try countTestFilters(runtime_arguments);
    const inherited_filter_count = countInheritedTestFilters(child_arguments);
    if (inherited_filter_count > max_test_filters - filter_count) {
        return error.TooManyTestFilters;
    }
    const command = try allocator.alloc(
        []const u8,
        child_arguments.len + filter_count,
    );
    @memcpy(command[0..child_arguments.len], child_arguments);
    var command_index = child_arguments.len;
    var runtime_index: usize = 0;
    while (try nextTestFilter(runtime_arguments, &runtime_index)) |value| {
        command[command_index] = try std.fmt.allocPrint(
            allocator,
            "-Dtest-filter={s}",
            .{value},
        );
        command_index += 1;
    }
    std.debug.assert(command_index == command.len);
    return command;
}

fn countInheritedTestFilters(arguments: []const []const u8) usize {
    var count: usize = 0;
    for (arguments) |argument| {
        if (std.mem.startsWith(u8, argument, "-Dtest-filter=")) count += 1;
    }
    return count;
}

fn countTestFilters(arguments: []const []const u8) !usize {
    var count: usize = 0;
    var index: usize = 0;
    while (try nextTestFilter(arguments, &index)) |_| {
        count += 1;
        if (count > max_test_filters) return error.TooManyTestFilters;
    }
    return count;
}

fn nextTestFilter(
    arguments: []const []const u8,
    index: *usize,
) !?[]const u8 {
    if (index.* == arguments.len) return null;
    const argument = arguments[index.*];
    index.* += 1;
    const value = if (std.mem.eql(u8, argument, "--test-filter")) blk: {
        if (index.* == arguments.len) return error.MissingTestFilterValue;
        defer index.* += 1;
        break :blk arguments[index.*];
    } else if (std.mem.cutPrefix(u8, argument, "--test-filter=")) |joined| joined else {
        return error.UnsupportedArgument;
    };
    if (value.len == 0) return error.EmptyTestFilterValue;
    return value;
}

fn relayTermination(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| blk: {
            if (comptime builtin.os.tag != .windows) {
                std.posix.raise(signal) catch {};
            }
            const code = 128 + @backingInt(signal);
            break :blk @intCast(@min(code, std.math.maxInt(u8)));
        },
        .stopped, .unknown => 1,
    };
}

fn transportDiagnostic(err: anyerror) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(fs_io, &buffer);
    switch (err) {
        error.MissingTestFilterValue, error.EmptyTestFilterValue => writer.interface.writeAll(
            "delegated test filter: --test-filter needs a non-empty value; " ++
                "the child build was not started\n",
        ) catch {},
        error.UnsupportedArgument => writer.interface.writeAll(
            "delegated test filter: only '--test-filter VALUE' and " ++
                "'--test-filter=VALUE' are supported after '--'; " ++
                "the child build was not started\n",
        ) catch {},
        error.TooManyTestFilters => writer.interface.print(
            "delegated test filter: at most {d} filters are supported; " ++
                "the child build was not started\n",
            .{max_test_filters},
        ) catch {},
        else => writer.interface.print(
            "delegated test filter: the child build could not start ({s})\n",
            .{@errorName(err)},
        ) catch {},
    }
    writer.interface.flush() catch {};
}

test "delegated test filters promote split and joined values in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const command = try promotedCommand(arena_state.allocator(), &.{
        transport_mode,
        "zig",
        "build",
        "language-test",
        "--",
        "--test-filter",
        "first",
        "--test-filter=second",
    });
    try expectCommand(&.{
        "zig",
        "build",
        "language-test",
        "-Dtest-filter=first",
        "-Dtest-filter=second",
    }, command);
}

test "delegated test filter transport leaves unfiltered commands unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const command = try promotedCommand(arena_state.allocator(), &.{
        transport_mode,
        "zig",
        "build",
        "language-test",
        "--",
    });
    try expectCommand(
        &.{ "zig", "build", "language-test" },
        command,
    );
}

fn expectCommand(
    expected: []const []const u8,
    actual: []const []const u8,
) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_argument, actual_argument| {
        try std.testing.expectEqualStrings(expected_argument, actual_argument);
    }
}

test "launcher transport selects current executable and cache route" {
    const Case = struct {
        protocol: ?[]const u8,
        mode: ?[]const u8,
        root: ?[]const u8,
        expected: []const []const u8,
    };
    const cases = [_]Case{
        .{
            .protocol = cache_lease_protocol,
            .mode = cache_mode_build_root,
            .root = "/repo",
            .expected = &.{
                "/repo/skills/worktree/bin/zig", "build",         "test",
                "--cache-dir",                   "package-cache",
            },
        },
        .{
            .protocol = cache_lease_protocol,
            .mode = "explicit",
            .root = "/repo",
            .expected = &.{
                "/repo/skills/worktree/bin/zig", "build",        "test",
                "--cache-dir",                   "scoped-cache",
            },
        },
        .{
            .protocol = null,
            .mode = null,
            .root = null,
            .expected = &.{
                "raw-zig", "build", "test", "--cache-dir", "scoped-cache",
            },
        },
    };
    for (cases) |case| {
        var environment = std.process.Environ.Map.init(std.testing.allocator);
        defer environment.deinit();
        if (case.protocol) |value| try environment.put("TINY_ZIG_CACHE_LEASE_PROTOCOL", value);
        if (case.mode) |value| try environment.put("TINY_ZIG_CACHE_MODE", value);
        if (case.root) |value| try environment.put("TINY_REPO_ROOT", value);
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var executable_storage: [std.fs.max_path_bytes]u8 = undefined;
        const command = try launcherCommand(
            arena_state.allocator(),
            &environment,
            &.{
                launcher_transport_mode, "raw-zig", "package-cache",       "scoped-cache",
                "build",                 "test",    launcher_cache_marker,
            },
            &executable_storage,
            false,
        );
        try expectCommand(case.expected, command);
    }
}

test "launcher transport promotes runtime filters after cache selection" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TINY_ZIG_CACHE_LEASE_PROTOCOL", cache_lease_protocol);
    try environment.put("TINY_ZIG_CACHE_MODE", cache_mode_build_root);
    try environment.put("TINY_REPO_ROOT", "/repo");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var executable_storage: [std.fs.max_path_bytes]u8 = undefined;
    const command = try launcherCommand(
        arena_state.allocator(),
        &environment,
        &.{
            launcher_filter_transport_mode, "raw-zig",             "package-cache", "scoped-cache",
            "build",                        launcher_cache_marker, "--",            "--test-filter",
            "selected",
        },
        &executable_storage,
        true,
    );
    try expectCommand(&.{
        "/repo/skills/worktree/bin/zig", "build", "--cache-dir", "package-cache",
        "-Dtest-filter=selected",
    }, command);
}

test "launcher transport preserves repository root requirements" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TINY_ZIG_CACHE_LEASE_PROTOCOL", cache_lease_protocol);
    var executable_storage: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(
        error.MissingRepositoryRoot,
        selectLauncher(&environment, "zig", "package", "scoped", &executable_storage),
    );
    try environment.put("TINY_REPO_ROOT", "relative");
    try std.testing.expectError(
        error.RelativeRepositoryRoot,
        selectLauncher(&environment, "zig", "package", "scoped", &executable_storage),
    );
}

test "delegated test filter transport rejects unsupported and missing values" {
    try std.testing.expectError(
        error.UnsupportedArgument,
        promotedCommand(std.testing.allocator, &.{
            transport_mode,
            "zig",
            "--",
            "--unsupported",
        }),
    );
    try std.testing.expectError(
        error.MissingTestFilterValue,
        promotedCommand(std.testing.allocator, &.{
            transport_mode,
            "zig",
            "--",
            "--test-filter",
        }),
    );
    try std.testing.expectError(
        error.EmptyTestFilterValue,
        promotedCommand(std.testing.allocator, &.{
            transport_mode,
            "zig",
            "--",
            "--test-filter=",
        }),
    );
}

test "delegated test filter transport rejects runtime max plus one" {
    var arguments: [3 + max_test_filters + 1][]const u8 = undefined;
    arguments[0] = transport_mode;
    arguments[1] = "zig";
    arguments[2] = "--";
    for (arguments[3..]) |*argument| argument.* = "--test-filter=value";
    try std.testing.expectError(
        error.TooManyTestFilters,
        promotedCommand(std.testing.allocator, &arguments),
    );
}

test "delegated test filter transport accepts the combined exact max" {
    var arguments: [3 + max_test_filters][]const u8 = undefined;
    arguments[0] = transport_mode;
    arguments[1] = "zig";
    for (arguments[2 .. 1 + max_test_filters]) |*argument| {
        argument.* = "-Dtest-filter=inherited";
    }
    arguments[1 + max_test_filters] = "--";
    arguments[2 + max_test_filters] = "--test-filter=runtime";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const command = try promotedCommand(
        arena_state.allocator(),
        &arguments,
    );
    try std.testing.expectEqual(
        @as(usize, 1 + max_test_filters),
        command.len,
    );
    try std.testing.expectEqualStrings(
        "-Dtest-filter=runtime",
        command[command.len - 1],
    );
}

test "delegated test filter transport rejects combined max plus one" {
    var arguments: [4 + max_test_filters][]const u8 = undefined;
    arguments[0] = transport_mode;
    arguments[1] = "zig";
    for (arguments[2 .. 2 + max_test_filters]) |*argument| {
        argument.* = "-Dtest-filter=inherited";
    }
    arguments[2 + max_test_filters] = "--";
    arguments[3 + max_test_filters] = "--test-filter=runtime";
    try std.testing.expectError(
        error.TooManyTestFilters,
        promotedCommand(std.testing.allocator, &arguments),
    );
}
