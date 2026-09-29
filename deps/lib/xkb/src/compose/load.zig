const std = @import("std");
const alloc_phase = @import("alloc_phase");
const compose = @import("root.zig");

pub const Error = compose.ParseError || compose.Storage.AcquireError ||
    compose.ScratchStorage.AcquireError || error{ComposeFileNotFound};

pub const Options = struct {
    locale: []const u8,
    home: ?[]const u8 = null,
    xcompose_file: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    system_directory: []const u8 = compose.default_system_directory,
    io: std.Io = std.Options.debug_io,
    diagnostic_context: ?*anyopaque = null,
    diagnostic: ?compose.DiagnosticFn = null,

    pub fn pathOptions(self: Options) compose.PathOptions {
        return .{
            .locale = self.locale,
            .home = self.home,
            .xcompose_file = self.xcompose_file,
            .xdg_config_home = self.xdg_config_home,
            .system_directory = self.system_directory,
            .io = self.io,
        };
    }

    pub fn parserOptions(self: Options) compose.ParserOptions {
        return .{
            .paths = self.pathOptions(),
            .diagnostic_context = self.diagnostic_context,
            .diagnostic = self.diagnostic,
        };
    }
};

pub fn compile(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    input: []const u8,
    options: Options,
) Error!compose.Table {
    try scratch_storage.acquire();
    defer scratch_storage.reset();
    return compileSource(storage, scratch_storage, input, "(buffer)", options);
}

pub fn load(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    options: Options,
) Error!compose.Table {
    try scratch_storage.acquire();
    defer scratch_storage.reset();
    if (options.xcompose_file) |file_path| {
        if (file_path.len != 0) {
            if (try loadCandidate(storage, scratch_storage, file_path, options)) |table| {
                return table;
            }
        }
    }

    if (try compose.xdgPath(
        scratch_storage.filePath(0),
        options.pathOptions(),
    )) |file_path| {
        if (try loadCandidate(storage, scratch_storage, file_path, options)) |table| {
            return table;
        }
    }
    if (try compose.homePath(
        scratch_storage.filePath(0),
        options.pathOptions(),
    )) |file_path| {
        if (try loadCandidate(storage, scratch_storage, file_path, options)) |table| {
            return table;
        }
    }

    const locale_path = try compose.localePath(
        scratch_storage,
        scratch_storage.filePath(0),
        options.pathOptions(),
    );
    return (try loadCandidate(storage, scratch_storage, locale_path, options)) orelse
        error.ComposeFileNotFound;
}

fn loadCandidate(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    file_path: []const u8,
    options: Options,
) Error!?compose.Table {
    var file = std.Io.Dir.cwd().openFile(options.io, file_path, .{}) catch return null;
    defer file.close(options.io);
    const stat = file.stat(options.io) catch return null;
    if (stat.kind != .file) return null;
    try storage.acquire();
    errdefer storage.reset();
    try compose.parseOpenedFile(
        storage,
        scratch_storage,
        file,
        stat.size,
        file_path,
        options.parserOptions(),
        0,
    );
    return storage.publish();
}

fn compileSource(
    storage: *compose.Storage,
    scratch_storage: *compose.ScratchStorage,
    input: []const u8,
    source: []const u8,
    options: Options,
) Error!compose.Table {
    try storage.acquire();
    errdefer storage.reset();
    try compose.parse(
        storage,
        scratch_storage,
        input,
        source,
        options.parserOptions(),
        0,
    );
    return storage.publish();
}

test "loader observes XCompose precedence and recursively parses includes" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);
    const included_path = try std.fs.path.join(allocator, &.{ root, "included" });
    defer allocator.free(included_path);
    const selected_path = try std.fs.path.join(allocator, &.{ root, "selected" });
    defer allocator.free(selected_path);

    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "included",
        .data = "<Multi_key> <a> : \"included\"\n",
    });
    const selected = try std.fmt.allocPrint(
        allocator,
        "include \"{s}\"\n<Multi_key> <b> : \"selected\"\n",
        .{included_path},
    );
    defer allocator.free(selected);
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "selected",
        .data = selected,
    });

    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 8,
        .text_bytes = 32,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    const table = try load(&storage, &scratch_storage, .{
        .locale = "C",
        .home = root,
        .xcompose_file = selected_path,
        .system_directory = root,
    });
    defer storage.reset();
    var iterator_value = table.iterator();
    try std.testing.expectEqualStrings("included", iterator_value.next().?.text.?);
    try std.testing.expectEqualStrings("selected", iterator_value.next().?.text.?);
    try std.testing.expect(iterator_value.next() == null);
}

test "loader skips a non-regular XCOMPOSEFILE candidate" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);
    try temporary.dir.createDirPath(std.Options.debug_io, ".config");
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = ".config/XCompose",
        .data = "<A> : \"fallback\" A\n",
    });

    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 4,
        .text_bytes = 16,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    const table = try load(&storage, &scratch_storage, .{
        .locale = "blabla",
        .home = root,
        .xcompose_file = root,
        .system_directory = root,
    });
    defer storage.reset();
    var iterator_value = table.iterator();
    try std.testing.expectEqualStrings("fallback", iterator_value.next().?.text.?);
    try std.testing.expect(iterator_value.next() == null);
}

test "Compose compiler accepts exact capacities and rejects max plus one" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "xkb_compose_boundaries"),
        );
    }

    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 2,
        .text_bytes = 2,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();

    const exact = try compile(&storage, &scratch_storage, "<A> <B> : \"ok\"\n", .{ .locale = "C" });
    var exact_iterator = exact.iterator();
    try std.testing.expectEqualStrings("ok", exact_iterator.next().?.text.?);
    storage.reset();
    try std.testing.expectError(
        error.SequenceSymbolCapacityExceeded,
        compile(&storage, &scratch_storage, "<A> <B> <C> : \"ok\"\n", .{ .locale = "C" }),
    );
    try std.testing.expectError(
        error.TextByteCapacityExceeded,
        compile(&storage, &scratch_storage, "<A> : \"long\"\n", .{ .locale = "C" }),
    );
}

test "Compose storage rejects concurrent use and resets after exhaustion" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "xkb_compose_reuse"),
        );
    }

    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 1,
        .text_bytes = 1,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    _ = try compile(&storage, &scratch_storage, "<A> : \"x\"\n", .{ .locale = "C" });
    try std.testing.expectError(
        error.ComposeStorageInUse,
        compile(&storage, &scratch_storage, "<A> : A\n", .{ .locale = "C" }),
    );
    storage.reset();
    try std.testing.expectError(
        error.SequenceSymbolCapacityExceeded,
        compile(&storage, &scratch_storage, "<A> <B> : B\n", .{ .locale = "C" }),
    );
    const reused = try compile(&storage, &scratch_storage, "<B> : B\n", .{ .locale = "C" });
    defer storage.reset();
    var reused_iterator = reused.iterator();
    try std.testing.expect(reused_iterator.next() != null);
}

test "Activated Compose storage performs no backing allocation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "xkb_compose_sealed"),
        );
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var storage = try compose.Storage.init(counting.allocator(), .{
        .sequence_symbols = 4,
        .text_bytes = 8,
    });
    defer storage.deinit(counting.allocator());
    var scratch_storage = try compose.ScratchStorage.init(
        counting.allocator(),
        compose.default_scratch_limits,
    );
    defer scratch_storage.deinit(counting.allocator());
    storage.activate();
    scratch_storage.activate();
    const allocations = counting.alloc_index;
    const resizes = counting.resize_index;
    _ = try compile(&storage, &scratch_storage, "<A> <B> : \"ok\"\n", .{
        .locale = "C",
    });
    defer storage.reset();
    try std.testing.expectEqual(allocations, counting.alloc_index);
    try std.testing.expectEqual(resizes, counting.resize_index);
}

test "Compose scratch accepts exact line and path bounds and rejects max plus one" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("./workspace/root.zig").Storage,
                "xkb_compose_scratch_boundaries",
            ),
        );
    }

    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);
    const included_path = try std.fs.path.join(allocator, &.{ root, "included" });
    defer allocator.free(included_path);
    const over_line_path = try std.fs.path.join(allocator, &.{ root, "over-line" });
    defer allocator.free(over_line_path);
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "included",
        .data = "<A> : A\n",
    });
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "over-line",
        .data = "<A> : A \n",
    });
    const exact_source = try std.fmt.allocPrint(allocator, "include \"{s}\"", .{included_path});
    defer allocator.free(exact_source);
    const over_source = try std.fmt.allocPrint(allocator, "include \"{s}x\"", .{included_path});
    defer allocator.free(over_source);

    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 1,
        .text_bytes = 0,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, .{
        .line_bytes = over_source.len,
        .path_bytes = included_path.len,
    });
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();

    _ = try compile(&storage, &scratch_storage, exact_source, .{ .locale = "C" });
    storage.reset();
    try std.testing.expectError(
        error.PathByteCapacityExceeded,
        compile(&storage, &scratch_storage, over_source, .{ .locale = "C" }),
    );

    var line_scratch = try compose.ScratchStorage.init(allocator, .{
        .line_bytes = "<A> : A".len,
        .path_bytes = 1,
    });
    defer line_scratch.deinit(allocator);
    line_scratch.activate();
    _ = try compile(&storage, &line_scratch, "<A> : A", .{ .locale = "C" });
    storage.reset();
    try std.testing.expectError(
        error.LineByteCapacityExceeded,
        compile(&storage, &line_scratch, "<A> : A ", .{ .locale = "C" }),
    );
    _ = try load(&storage, &line_scratch, .{
        .locale = "C",
        .xcompose_file = included_path,
    });
    storage.reset();
    try std.testing.expectError(
        error.LineByteCapacityExceeded,
        load(&storage, &line_scratch, .{
            .locale = "C",
            .xcompose_file = over_line_path,
        }),
    );
}

test "Compose scratch rejects concurrent use and resets after exhaustion" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("./workspace/root.zig").Storage,
                "xkb_compose_scratch_reuse",
            ),
        );
    }

    const allocator = std.testing.allocator;
    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 1,
        .text_bytes = 0,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, .{
        .line_bytes = "<A> : A".len,
        .path_bytes = 1,
    });
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    try scratch_storage.acquire();
    try std.testing.expectError(
        error.ComposeScratchInUse,
        compile(&storage, &scratch_storage, "<A> : A", .{ .locale = "C" }),
    );
    scratch_storage.reset();
    try std.testing.expectError(
        error.LineByteCapacityExceeded,
        compile(&storage, &scratch_storage, "<A> : A ", .{ .locale = "C" }),
    );
    _ = try compile(&storage, &scratch_storage, "<A> : A", .{ .locale = "C" });
    defer storage.reset();
}

test "Compose streaming scratch spans the maximum include depth" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("./workspace/root.zig").Storage,
                "xkb_compose_scratch_depth",
            ),
        );
    }

    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);
    var paths: [compose.max_include_depth + 2][]u8 = undefined;
    var path_count: usize = 0;
    defer for (paths[0..path_count]) |file_path| allocator.free(file_path);
    for (&paths, 0..) |*file_path, index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "source-{d}", .{index});
        file_path.* = try std.fs.path.join(allocator, &.{ root, name });
        path_count += 1;
    }
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "source-5",
        .data = "<A> : A\n",
    });
    var depth: usize = compose.max_include_depth;
    while (depth > 0) {
        depth -= 1;
        const source = try std.fmt.allocPrint(allocator, "include \"{s}\"\n", .{paths[depth + 1]});
        defer allocator.free(source);
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "source-{d}", .{depth});
        try temporary.dir.writeFile(std.Options.debug_io, .{
            .sub_path = name,
            .data = source,
        });
    }

    var storage = try compose.Storage.init(allocator, .{
        .sequence_symbols = 1,
        .text_bytes = 0,
    });
    defer storage.deinit(allocator);
    var scratch_storage = try compose.ScratchStorage.init(allocator, compose.default_scratch_limits);
    defer scratch_storage.deinit(allocator);
    storage.activate();
    scratch_storage.activate();
    _ = try load(&storage, &scratch_storage, .{
        .locale = "C",
        .xcompose_file = paths[0],
    });
    storage.reset();

    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "source-6",
        .data = "<A> : A\n",
    });
    const excessive = try std.fmt.allocPrint(allocator, "include \"{s}\"\n", .{paths[6]});
    defer allocator.free(excessive);
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "source-5",
        .data = excessive,
    });
    try std.testing.expectError(
        error.IncludeDepthExceeded,
        load(&storage, &scratch_storage, .{
            .locale = "C",
            .xcompose_file = paths[0],
        }),
    );
}

test "Activated Compose compiler and loader perform no backing allocation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("./workspace/root.zig").Storage,
                "xkb_compose_scratch_sealed",
            ),
        );
    }

    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(root);
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "locale.alias",
        .data = "friendly en_US.UTF-8\n",
    });
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "compose.dir",
        .data = "XCompose en_US.UTF-8\n",
    });
    try temporary.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "XCompose",
        .data = "<A> : A\n",
    });

    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var storage = try compose.Storage.init(counting.allocator(), .{
        .sequence_symbols = 1,
        .text_bytes = 0,
    });
    defer storage.deinit(counting.allocator());
    var scratch_storage = try compose.ScratchStorage.init(
        counting.allocator(),
        compose.default_scratch_limits,
    );
    defer scratch_storage.deinit(counting.allocator());
    storage.activate();
    scratch_storage.activate();
    const allocations = counting.alloc_index;
    const resizes = counting.resize_index;
    _ = try load(&storage, &scratch_storage, .{
        .locale = "friendly",
        .system_directory = root,
    });
    defer storage.reset();
    try std.testing.expectEqual(allocations, counting.alloc_index);
    try std.testing.expectEqual(resizes, counting.resize_index);
}
