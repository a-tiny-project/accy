const std = @import("std");
const sys = @import("sys");
const wayland = @import("root.zig");
const wayland_options = @import("wayland_options");

pub const Environment = struct {
    wayland_socket: ?[]const u8 = null,
    wayland_display: ?[]const u8 = null,
    xdg_runtime_dir: ?[]const u8 = null,

    pub fn current() Environment {
        return .{
            .wayland_socket = sys.env.getConstant("WAYLAND_SOCKET"),
            .wayland_display = sys.env.getConstant("WAYLAND_DISPLAY"),
            .xdg_runtime_dir = sys.env.getConstant("XDG_RUNTIME_DIR"),
        };
    }
};

pub const ProcessEnvironmentLimits = struct {
    retained_entry_count: usize = wayland_options.process_environment_retained_entry_count,
};

pub const ProcessEnvironmentCapacityError = error{
    CapacityOverflow,
};

pub const ProcessEnvironmentCapacity = struct {
    retained_entry_count: usize,
    source_entry_count: usize,
    generation_entry_count: usize,
    generation_bytes: usize,
    generation_owner_bytes: usize,
    total_static_bytes: usize,

    pub fn derive(limits: ProcessEnvironmentLimits) ProcessEnvironmentCapacityError!ProcessEnvironmentCapacity {
        const source_entry_count = std.math.add(
            usize,
            limits.retained_entry_count,
            1,
        ) catch return error.CapacityOverflow;
        const generation_bytes = std.math.mul(
            usize,
            source_entry_count,
            @sizeOf(?[*:0]const u8),
        ) catch return error.CapacityOverflow;
        const generation_owner_bytes = @sizeOf(sys.env.GenerationStorage);
        const total_static_bytes = std.math.add(
            usize,
            generation_bytes,
            generation_owner_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .retained_entry_count = limits.retained_entry_count,
            .source_entry_count = source_entry_count,
            .generation_entry_count = source_entry_count,
            .generation_bytes = generation_bytes,
            .generation_owner_bytes = generation_owner_bytes,
            .total_static_bytes = total_static_bytes,
        };
    }
};

pub const process_environment_capacity = ProcessEnvironmentCapacity.derive(.{}) catch |err| {
    @compileError("invalid Wayland process environment capacity: " ++ @errorName(err));
};

var process_environment_generation_entries: [process_environment_capacity.generation_entry_count]?[*:0]const u8 = undefined;
var process_environment_generation =
    sys.env.GenerationStorage.init(&process_environment_generation_entries);

pub const Error = std.mem.Allocator.Error || sys.net.StreamConnectError || sys.fd.FlagError || error{
    InvalidInheritedDescriptor,
    MissingRuntimeDirectory,
    InvalidRuntimeDirectory,
    ProcessEnvironmentCapacityExceeded,
    ProcessEnvironmentGenerationConsumed,
    InvalidDisplayName,
    SocketPathTooLong,
};

const test_capacity = wayland.TransportCapacity.derive(.{}) catch unreachable;

const Endpoint = union(enum) {
    inherited: sys.fd.Descriptor,
    path: []const u8,
};

const InheritedSocketClaim = struct {
    descriptor: ?sys.fd.Descriptor = null,

    fn validate(self: *@This(), descriptor_text: []const u8) bool {
        const descriptor = std.fmt.parseInt(sys.fd.Descriptor, descriptor_text, 10) catch return false;
        if (descriptor < 0) return false;
        sys.fd.setCloseOnExec(descriptor) catch return false;
        self.descriptor = descriptor;
        return true;
    }
};

pub fn connect(
    session_allocator: std.mem.Allocator,
    capacity: wayland.transport.Capacity,
) Error!wayland.Transport {
    return connectProcessEnvironmentStorage(
        session_allocator,
        null,
        capacity,
        &process_environment_generation,
    );
}

pub fn connectNamed(
    session_allocator: std.mem.Allocator,
    display_name: []const u8,
    capacity: wayland.transport.Capacity,
) Error!wayland.Transport {
    return connectProcessEnvironmentStorage(
        session_allocator,
        display_name,
        capacity,
        &process_environment_generation,
    );
}

fn connectProcessEnvironmentStorage(
    session_allocator: std.mem.Allocator,
    display_name: ?[]const u8,
    capacity: wayland.transport.Capacity,
    generation: *sys.env.GenerationStorage,
) Error!wayland.Transport {
    var storage = try wayland.transport.Storage.init(session_allocator, capacity);
    errdefer storage.deinit();
    var claim: InheritedSocketClaim = .{};
    const inherited = sys.env.claimIf(
        generation,
        "WAYLAND_SOCKET",
        &claim,
        InheritedSocketClaim.validate,
    ) catch |err| switch (err) {
        error.ConditionRejected => return error.InvalidInheritedDescriptor,
        error.GenerationStorageAlreadyUsed => return error.ProcessEnvironmentGenerationConsumed,
        error.GenerationStorageTooSmall => return error.ProcessEnvironmentCapacityExceeded,
    };
    if (inherited) return storage.attach(claim.descriptor.?);
    var environment = Environment.current();
    environment.wayland_socket = null;
    return connectNamedWithEnvironmentStorage(&storage, display_name, environment);
}

pub fn connectNamedWithEnvironment(
    session_allocator: std.mem.Allocator,
    display_name: ?[]const u8,
    environment: Environment,
    capacity: wayland.transport.Capacity,
) Error!wayland.Transport {
    var storage = try wayland.transport.Storage.init(session_allocator, capacity);
    errdefer storage.deinit();
    return connectNamedWithEnvironmentStorage(&storage, display_name, environment);
}

fn connectNamedWithEnvironmentStorage(
    storage: *wayland.transport.Storage,
    display_name: ?[]const u8,
    environment: Environment,
) Error!wayland.Transport {
    var path_buffer: [sys.net.unix_path_capacity - 1]u8 = undefined;
    return switch (try resolve(display_name, environment, &path_buffer)) {
        .inherited => |descriptor| storage.attach(descriptor),
        .path => |path| connectPath(storage, path),
    };
}

fn connectPath(
    storage: *wayland.transport.Storage,
    path: []const u8,
) Error!wayland.Transport {
    const address = sys.net.Address.initUnix(path) catch return error.SocketPathTooLong;
    const stream = try sys.net.connectStream(address);
    return storage.attach(stream.handle);
}

fn resolve(
    display_name: ?[]const u8,
    environment: Environment,
    path_buffer: *[sys.net.unix_path_capacity - 1]u8,
) Error!Endpoint {
    if (environment.wayland_socket) |descriptor_text| {
        const descriptor = std.fmt.parseInt(sys.fd.Descriptor, descriptor_text, 10) catch {
            return error.InvalidInheritedDescriptor;
        };
        if (descriptor < 0) return error.InvalidInheritedDescriptor;
        return .{ .inherited = descriptor };
    }

    const name = display_name orelse environment.wayland_display orelse "wayland-0";
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidDisplayName;
    if (name.len != 0 and name[0] == '/') {
        if (name.len >= sys.net.unix_path_capacity) return error.SocketPathTooLong;
        return .{ .path = name };
    }

    const runtime_dir = environment.xdg_runtime_dir orelse return error.MissingRuntimeDirectory;
    if (runtime_dir.len == 0 or runtime_dir[0] != '/' or std.mem.indexOfScalar(u8, runtime_dir, 0) != null) {
        return error.InvalidRuntimeDirectory;
    }
    const separator_and_name_len = std.math.add(usize, name.len, 1) catch {
        return error.SocketPathTooLong;
    };
    const path_len = std.math.add(usize, runtime_dir.len, separator_and_name_len) catch {
        return error.SocketPathTooLong;
    };
    if (path_len >= sys.net.unix_path_capacity) return error.SocketPathTooLong;
    @memcpy(path_buffer[0..runtime_dir.len], runtime_dir);
    path_buffer[runtime_dir.len] = '/';
    @memcpy(path_buffer[runtime_dir.len + 1 .. path_len], name);
    return .{ .path = path_buffer[0..path_len] };
}

test "display endpoint resolution follows the Wayland environment contract" {
    var buffer: [sys.net.unix_path_capacity - 1]u8 = undefined;

    const fallback = try resolve(null, .{ .xdg_runtime_dir = "/run/user/1000" }, &buffer);
    try std.testing.expectEqualStrings("/run/user/1000/wayland-0", fallback.path);

    const selected = try resolve(null, .{
        .wayland_display = "wayland-7",
        .xdg_runtime_dir = "/runtime",
    }, &buffer);
    try std.testing.expectEqualStrings("/runtime/wayland-7", selected.path);

    const absolute = try resolve("/tmp/custom-wayland", .{}, &buffer);
    try std.testing.expectEqualStrings("/tmp/custom-wayland", absolute.path);

    const inherited = try resolve("ignored", .{
        .wayland_socket = "42",
        .wayland_display = "also-ignored",
    }, &buffer);
    try std.testing.expectEqual(@as(sys.fd.Descriptor, 42), inherited.inherited);
}

test "invalid display endpoints fail before opening a socket" {
    var buffer: [sys.net.unix_path_capacity - 1]u8 = undefined;
    try std.testing.expectError(error.MissingRuntimeDirectory, resolve(null, .{}, &buffer));
    try std.testing.expectError(
        error.InvalidRuntimeDirectory,
        resolve(null, .{ .xdg_runtime_dir = "relative" }, &buffer),
    );
    try std.testing.expectError(
        error.InvalidInheritedDescriptor,
        resolve(null, .{ .wayland_socket = "4x" }, &buffer),
    );
    try std.testing.expectError(
        error.InvalidInheritedDescriptor,
        resolve(null, .{ .wayland_socket = "-1" }, &buffer),
    );

    var long_name: [sys.net.unix_path_capacity]u8 = @splat('w');
    long_name[0] = '/';
    try std.testing.expectError(error.SocketPathTooLong, resolve(&long_name, .{}, &buffer));
}

test "connection acquires transport storage before endpoint effects" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        connectNamedWithEnvironment(failing.allocator(), null, .{}, test_capacity),
    );
}

test "process environment capacity derives exact literal-static generation storage" {
    const capacity = try ProcessEnvironmentCapacity.derive(.{
        .retained_entry_count = 3,
    });
    try std.testing.expectEqual(@as(usize, 3), capacity.retained_entry_count);
    try std.testing.expectEqual(@as(usize, 4), capacity.source_entry_count);
    try std.testing.expectEqual(@as(usize, 4), capacity.generation_entry_count);
    try std.testing.expectEqual(
        4 * @sizeOf(?[*:0]const u8),
        capacity.generation_bytes,
    );
    try std.testing.expectEqual(
        @sizeOf(sys.env.GenerationStorage),
        capacity.generation_owner_bytes,
    );
    try std.testing.expectEqual(
        capacity.generation_bytes + capacity.generation_owner_bytes,
        capacity.total_static_bytes,
    );
    try std.testing.expectEqual(
        process_environment_capacity.generation_entry_count,
        process_environment_generation_entries.len,
    );
    try std.testing.expectEqual(
        process_environment_capacity.total_static_bytes,
        @sizeOf(@TypeOf(process_environment_generation_entries)) +
            @sizeOf(@TypeOf(process_environment_generation)),
    );
}

test "process environment capacity rejects arithmetic overflow" {
    try std.testing.expectError(
        error.CapacityOverflow,
        ProcessEnvironmentCapacity.derive(.{
            .retained_entry_count = std.math.maxInt(usize),
        }),
    );
}

test "inherited Wayland socket ownership transfers to the transport" {
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    var inherited_owned = true;
    defer if (inherited_owned) sys.fd.close(sockets[0]);
    defer sys.fd.close(sockets[1]);

    var descriptor_text: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&descriptor_text, "{d}", .{sockets[0]});
    var transport = try connectNamedWithEnvironment(std.testing.allocator, "ignored", .{
        .wayland_socket = value,
    }, test_capacity);
    inherited_owned = false;
    defer transport.deinit();

    try transport.queueOwned(2, 3, &.{}, &.{});
    try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try transport.flush());
    var message: [wayland.wire.header_size]u8 = undefined;
    try std.testing.expectEqual(message.len, try sys.fd.read(sockets[1], &message));
    try std.testing.expectEqual(@as(u32, 2), (try wayland.wire.decode(&message)).object_id);
}

test "process inherited socket claim allocates only transport storage" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const sockets = try sys.fd.socketPairUnixStream(.{ .close_on_exec = false });
    var inherited_owned = true;
    defer if (inherited_owned) sys.fd.close(sockets[0]);
    defer sys.fd.close(sockets[1]);

    var descriptor_text: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&descriptor_text, "{d}", .{sockets[0]});
    var map = sys.env.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("WAYLAND_SOCKET", value);
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var generation_entries: [1]?[*:0]const u8 = undefined;
    var generation = sys.env.GenerationStorage.init(&generation_entries);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var transport = try connectProcessEnvironmentStorage(
        failing.allocator(),
        null,
        test_capacity,
        &generation,
    );
    inherited_owned = false;
    defer transport.deinit();
    try std.testing.expectEqual(@as(usize, 4), failing.allocations);
    try std.testing.expect(generation.used);
    try std.testing.expect(sys.env.getConstant("WAYLAND_SOCKET") == null);

    try std.testing.expect(try sys.fd.closeOnExec(transport.descriptor));
    try std.testing.expect(try sys.fd.nonBlocking(transport.descriptor));
}

test "process environment max plus one rejects before descriptor effects" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const sockets = try sys.fd.socketPairUnixStream(.{ .close_on_exec = false });
    defer sys.fd.close(sockets[0]);
    defer sys.fd.close(sockets[1]);

    var descriptor_text: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&descriptor_text, "{d}", .{sockets[0]});
    var map = sys.env.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("WAYLAND_SOCKET", value);
    try map.put("TINY_WAYLAND_RETAIN", "visible");
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var generation_entries: [1]?[*:0]const u8 = undefined;
    var generation = sys.env.GenerationStorage.init(&generation_entries);
    try std.testing.expectError(
        error.ProcessEnvironmentCapacityExceeded,
        connectProcessEnvironmentStorage(
            std.testing.allocator,
            null,
            test_capacity,
            &generation,
        ),
    );
    try std.testing.expect(!generation.used);
    try std.testing.expectEqualStrings(value, sys.env.getConstant("WAYLAND_SOCKET").?);
    try std.testing.expectEqualStrings(
        "visible",
        sys.env.getConstant("TINY_WAYLAND_RETAIN").?,
    );

    try std.testing.expect(!try sys.fd.closeOnExec(sockets[0]));
}

test "invalid process inherited socket text remains installed" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    var map = sys.env.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("WAYLAND_SOCKET", "4x");
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var generation_entries: [1]?[*:0]const u8 = undefined;
    var generation = sys.env.GenerationStorage.init(&generation_entries);
    try std.testing.expectError(
        error.InvalidInheritedDescriptor,
        connectProcessEnvironmentStorage(
            std.testing.allocator,
            null,
            test_capacity,
            &generation,
        ),
    );
    try std.testing.expectEqualStrings("4x", sys.env.getConstant("WAYLAND_SOCKET").?);

    var inherited = try sys.env.createMap(std.testing.allocator);
    defer inherited.deinit();
    try std.testing.expectEqualStrings("4x", inherited.get("WAYLAND_SOCKET").?);
}

test "closed process inherited socket remains installed" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const sockets = try sys.fd.socketPairUnixStream(.{ .close_on_exec = false });
    sys.fd.close(sockets[0]);
    defer sys.fd.close(sockets[1]);

    var descriptor_text: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&descriptor_text, "{d}", .{sockets[0]});
    var map = sys.env.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("WAYLAND_SOCKET", value);
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var generation_entries: [1]?[*:0]const u8 = undefined;
    var generation = sys.env.GenerationStorage.init(&generation_entries);
    try std.testing.expectError(
        error.InvalidInheritedDescriptor,
        connectProcessEnvironmentStorage(
            std.testing.allocator,
            null,
            test_capacity,
            &generation,
        ),
    );
    try std.testing.expectEqualStrings(value, sys.env.getConstant("WAYLAND_SOCKET").?);

    var inherited = try sys.env.createMap(std.testing.allocator);
    defer inherited.deinit();
    try std.testing.expectEqualStrings(value, inherited.get("WAYLAND_SOCKET").?);
}

const InheritedSocketClaimWorkerFixture = struct {
    generation: *sys.env.GenerationStorage,
    connected: bool = false,
    failed: bool = false,

    fn run(self: *@This()) void {
        var transport = connectProcessEnvironmentStorage(
            std.testing.allocator,
            null,
            test_capacity,
            self.generation,
        ) catch |err| switch (err) {
            error.MissingRuntimeDirectory => return,
            else => {
                self.failed = true;
                return;
            },
        };
        self.connected = true;
        transport.deinit();
    }
};

test "concurrent inherited socket claims transfer exactly once" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const sockets = try sys.fd.socketPairUnixStream(.{ .close_on_exec = false });
    var inherited_owned = true;
    defer if (inherited_owned) sys.fd.close(sockets[0]);
    defer sys.fd.close(sockets[1]);

    var descriptor_text: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&descriptor_text, "{d}", .{sockets[0]});
    var map = sys.env.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("WAYLAND_SOCKET", value);
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const previous = sys.env.current();
    sys.env.installProcessEnvironment(.{ .block = block });
    defer sys.env.installProcessEnvironment(previous);

    var generation_entries: [1]?[*:0]const u8 = undefined;
    var generation = sys.env.GenerationStorage.init(&generation_entries);
    var workers: [8]InheritedSocketClaimWorkerFixture = undefined;
    for (&workers) |*worker| worker.* = .{ .generation = &generation };
    var threads: [workers.len]std.Thread = undefined;
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, InheritedSocketClaimWorkerFixture.run, .{worker});
    }
    for (&threads) |*thread| thread.join();

    var connected: usize = 0;
    for (workers) |worker| {
        try std.testing.expect(!worker.failed);
        if (worker.connected) connected += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), connected);
    inherited_owned = false;
    try std.testing.expect(sys.env.getConstant("WAYLAND_SOCKET") == null);
}

test "display name connects through the runtime directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var runtime_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const runtime_len = try tmp.dir.realPath(std.Options.debug_io, &runtime_buffer);
    const runtime_dir = runtime_buffer[0..runtime_len];
    var socket_path_buffer: [sys.net.unix_path_capacity - 1]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_path_buffer, "{s}/wayland-test", .{runtime_dir});

    var server = try sys.net.Address.listen(try sys.net.Address.initUnix(socket_path), .{});
    defer server.deinit();

    var transport = try connectNamedWithEnvironment(std.testing.allocator, "wayland-test", .{
        .xdg_runtime_dir = runtime_dir,
    }, test_capacity);
    defer transport.deinit();
    const accepted = try server.accept();
    defer accepted.stream.close();

    try transport.queueOwned(8, 5, &.{}, &.{});
    try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try transport.flush());
    var message: [wayland.wire.header_size]u8 = undefined;
    try std.testing.expectEqual(message.len, try accepted.stream.read(&message));
    const header = try wayland.wire.decode(&message);
    try std.testing.expectEqual(@as(u32, 8), header.object_id);
    try std.testing.expectEqual(@as(u16, 5), header.opcode);
}
