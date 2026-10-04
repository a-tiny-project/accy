const std = @import("std");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");
const schedule_data = @import("schedule.zig");

const max_count = 32;
const report_width = 120;
const child_env = "TINY_TIMING_RUNNER_SHARD_CHILD";
const count_env = "TINY_TIMING_RUNNER_SHARD_COUNT";
const external_env = "TINY_TIMING_RUNNER_EXTERNAL_SHARD";
const index_env = "TINY_TIMING_RUNNER_SHARD_INDEX";
const port_env = "TINY_TIMING_RUNNER_SHARD_PORT";
const request_value: u8 = 0xa5;
const done_index = std.math.maxInt(u32);

pub const CoordinatorResult = struct {
    success: bool,
    worker_count: usize,
};

pub fn coordinatorRequested(environ: sys.process.Environ) bool {
    if (childRequested(environ) or externalRequested(environ)) return false;
    return requestedCount(environ) > 1;
}

pub fn childRequested(environ: sys.process.Environ) bool {
    return sys.process.Environ.getPosix(environ, child_env) != null;
}

pub fn externalRequested(environ: sys.process.Environ) bool {
    return sys.process.Environ.getPosix(environ, external_env) != null;
}

pub fn runCoordinator(init: sys.process.Init, order: []const u32) !CoordinatorResult {
    if (order.len == 0) return .{ .success = true, .worker_count = 0 };
    if (schedulerSupported()) return try runDynamicCoordinator(init, order);
    return try runStaticCoordinator(init, order.len);
}

pub const Worker = struct {
    mode: Mode,
    total: usize,

    const Mode = union(enum) {
        indexed: struct {
            count: usize,
            index: usize,
            cursor: usize = 0,
        },
        dynamic: sys.net.Stream,
    };

    pub fn init(environ: sys.process.Environ, total: usize) !Worker {
        if (sys.process.Environ.getPosix(environ, port_env)) |port_text| {
            const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return error.InvalidSchedulerPort;
            const address = sys.net.Address.fromIp4Address(sys.net.ip4Address(.{ 127, 0, 0, 1 }, port));
            return .{ .mode = .{ .dynamic = try sys.net.connectStream(address) }, .total = total };
        }
        const count = requestedCount(environ);
        const index_text = sys.process.Environ.getPosix(environ, index_env) orelse "0";
        const index = std.fmt.parseUnsigned(usize, index_text, 10) catch return error.InvalidTestShard;
        if (index >= count) return error.InvalidTestShard;
        return .{ .mode = .{ .indexed = .{ .count = count, .index = index } }, .total = total };
    }

    /// Walks a shard's own precomputed order, every position once.
    pub fn single(total: usize) Worker {
        return .{ .mode = .{ .indexed = .{ .count = 1, .index = 0 } }, .total = total };
    }

    pub fn deinit(self: *Worker) void {
        switch (self.mode) {
            .indexed => {},
            .dynamic => |stream| stream.close(),
        }
        self.* = undefined;
    }

    pub fn next(self: *Worker) !?usize {
        return switch (self.mode) {
            .indexed => |*indexed| indexedNext(indexed, self.total),
            .dynamic => |stream| try dynamicNext(stream, self.total),
        };
    }
};

const Indexed = @FieldType(Worker.Mode, "indexed");

pub const Position = struct {
    count: usize,
    index: usize,
};

/// The shard count and index an externally sharded run was given. A run without them is
/// the only shard.
pub fn externalPosition(environ: sys.process.Environ) !Position {
    const count = requestedCount(environ);
    const index_text = sys.process.Environ.getPosix(environ, index_env) orelse "0";
    const index = std.fmt.parseUnsigned(usize, index_text, 10) catch return error.InvalidTestShard;
    if (index >= count) return error.InvalidTestShard;
    if (count > 1 and !externalRequested(environ)) return error.ExternalShardRequired;
    return .{ .count = count, .index = index };
}

fn indexedNext(indexed: *Indexed, total: usize) ?usize {
    const position = schedule_data.indexedPosition(
        total,
        indexed.count,
        indexed.index,
        indexed.cursor,
    );
    indexed.cursor += 1;
    return position;
}

fn dynamicNext(stream: sys.net.Stream, total: usize) !?usize {
    try stream.writeAll(&.{request_value});
    var encoded: [@sizeOf(u32)]u8 = undefined;
    try readExact(stream, &encoded);
    const ordinal = std.mem.readInt(u32, &encoded, .little);
    if (ordinal == done_index) return null;
    if (ordinal >= total) return error.InvalidTestSchedule;
    return ordinal;
}

fn readExact(stream: sys.net.Stream, output: []u8) !void {
    var received: usize = 0;
    for (0..output.len) |_| {
        const count = try stream.read(output[received..]);
        if (count == 0) return error.SchedulerClosed;
        received += count;
        if (received == output.len) return;
    }
    return error.IncompleteSchedulerResponse;
}

const Handler = struct {
    stream: sys.net.Stream,
    schedule: *schedule_data.Schedule,
    err: ?anyerror = null,

    fn run(self: *Handler) void {
        defer self.stream.close();
        self.serve() catch |err| {
            self.err = err;
        };
    }

    fn serve(self: *Handler) !void {
        for (0..self.schedule.order.len + 1) |_| {
            var request: [1]u8 = undefined;
            const count = try self.stream.read(&request);
            if (count == 0) return;
            if (request[0] != request_value) return error.InvalidSchedulerRequest;
            const ordinal = self.schedule.take() orelse done_index;
            var encoded: [@sizeOf(u32)]u8 = undefined;
            std.mem.writeInt(u32, &encoded, ordinal, .little);
            try self.stream.writeAll(&encoded);
            if (ordinal == done_index) return;
        }
        return error.SchedulerRequestOverflow;
    }
};

const SpawnMode = union(enum) {
    dynamic: u16,
    indexed,
};

fn runDynamicCoordinator(init: sys.process.Init, order: []const u32) !CoordinatorResult {
    var arena = std.heap.ArenaAllocator.init(sys.allocator.processAllocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    const worker_count = schedule_data.activeCount(requestedCount(init.minimal.environ), order.len);
    const args = try argvAlloc(allocator, init.minimal.args);
    const address = sys.net.Address.fromIp4Address(sys.net.ip4Address(.{ 127, 0, 0, 1 }, 0));
    var server = address.listen(.{ .backlog = @intCast(worker_count) }) catch
        return try runStaticCoordinator(init, order.len);
    defer server.deinit();

    var children: [max_count]sys.process.Child = undefined;
    try spawnChildren(init, allocator, args, children[0..worker_count], .{
        .dynamic = server.listen_address.getPort(),
    });
    var cleaned = false;
    var streams: [max_count]sys.net.Stream = undefined;
    var accepted: usize = 0;
    var schedule = schedule_data.Schedule{ .order = order };
    var handlers: [max_count]Handler = undefined;
    var threads: [max_count]sys.thread.JoinHandle = undefined;
    var started: usize = 0;
    errdefer if (!cleaned) cleanupHandlers(
        init.io,
        children[0..worker_count],
        threads[0..started],
        streams[started..accepted],
    );
    while (accepted < worker_count) : (accepted += 1) {
        if (!try sys.net.pollReadable(server.socket, 30_000)) return error.TestWorkerConnectTimeout;
        streams[accepted] = (try server.accept()).stream;
    }
    while (started < accepted) : (started += 1) {
        handlers[started] = .{ .stream = streams[started], .schedule = &schedule };
        threads[started] = try sys.thread.spawn(Handler.run, .{&handlers[started]});
    }

    const success = try waitChildren(init.io, children[0..worker_count]);
    for (threads[0..started]) |thread| thread.join();
    cleaned = true;
    for (handlers[0..started]) |handler| if (handler.err) |err| return err;
    return .{ .success = success, .worker_count = worker_count };
}

fn runStaticCoordinator(init: sys.process.Init, test_count: usize) !CoordinatorResult {
    var arena = std.heap.ArenaAllocator.init(sys.allocator.processAllocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    const worker_count = schedule_data.activeCount(requestedCount(init.minimal.environ), test_count);
    const args = try argvAlloc(allocator, init.minimal.args);
    var children: [max_count]sys.process.Child = undefined;
    try spawnChildren(init, allocator, args, children[0..worker_count], .indexed);
    errdefer killChildren(init.io, children[0..worker_count]);
    return .{
        .success = try waitChildren(init.io, children[0..worker_count]),
        .worker_count = worker_count,
    };
}

fn argvAlloc(allocator: std.mem.Allocator, args: sys.process.Args) ![]const []const u8 {
    const args_z = try args.toSlice(allocator);
    const argv = try allocator.alloc([]const u8, args_z.len);
    for (args_z, argv) |arg, *value| value.* = arg[0..arg.len];
    return argv;
}

fn spawnChildren(
    init: sys.process.Init,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    children: []sys.process.Child,
    mode: SpawnMode,
) !void {
    var started: usize = 0;
    errdefer killChildren(init.io, children[0..started]);
    while (started < children.len) : (started += 1) {
        var environment = try init.environ_map.clone(allocator);
        defer environment.deinit();
        try environment.put(child_env, "1");
        var count_buffer: [32]u8 = undefined;
        try environment.put(count_env, try std.fmt.bufPrint(&count_buffer, "{d}", .{children.len}));
        var value_buffer: [32]u8 = undefined;
        switch (mode) {
            .dynamic => |port| try environment.put(port_env, try std.fmt.bufPrint(&value_buffer, "{d}", .{port})),
            .indexed => try environment.put(index_env, try std.fmt.bufPrint(&value_buffer, "{d}", .{started})),
        }
        children[started] = try sys.process.spawn(init.io, .{
            .argv = argv,
            .environ_map = &environment,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
    }
}

fn waitChildren(io: anytype, children: []sys.process.Child) !bool {
    var success = true;
    for (children, 0..) |*child, worker_index| {
        const term = try child.wait(io);
        if (sys.process.exitCode(term) == 0) continue;
        success = false;
        writeFailure(worker_index, children.len, term);
    }
    return success;
}

fn killChildren(io: anytype, children: []sys.process.Child) void {
    for (children) |*child| sys.process.killAndReap(child, io);
}

fn cleanupHandlers(
    io: anytype,
    children: []sys.process.Child,
    threads: []sys.thread.JoinHandle,
    unowned_streams: []sys.net.Stream,
) void {
    killChildren(io, children);
    for (unowned_streams) |stream| stream.close();
    for (threads) |thread| thread.join();
}

fn schedulerSupported() bool {
    return sys.thread.threadsSupported() and sys.net.socketPolicy() != .unsupported;
}

fn requestedCount(environ: sys.process.Environ) usize {
    const count_text = sys.process.Environ.getPosix(environ, count_env) orelse return 1;
    const count = std.fmt.parseUnsigned(usize, count_text, 10) catch @panic("invalid test shard count");
    if (count == 0 or count > max_count) @panic("invalid test shard count");
    return count;
}

pub fn writeCoordinatorError(err: anyerror) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(std.Options.debug_io, &buffer);
    defer writer.interface.flush() catch {};
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = builder.concat(&.{
        tagDoc(builder, "FAIL", .danger) catch return,
        builder.text(" test shard coordinator failed"),
        builder.punct(":") catch return,
        builder.text(" "),
        builder.styledText(.danger, @errorName(err)) catch return,
        pretty.hardline,
    }) catch return;
    pretty.write(&writer.interface, doc, renderOptions()) catch {};
}

pub fn writeSuccess(test_count: usize, worker_count: usize) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(std.Options.debug_io, &buffer);
    defer writer.interface.flush() catch {};
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = builder.concat(&.{
        tagDoc(
            builder,
            if (test_count == 0) "SKIP" else "PASS",
            if (test_count == 0) .muted else .value,
        ) catch return,
        builder.text(" "),
        builder.styledFmt(.number, "{d}", .{test_count}) catch return,
        builder.text(" selected"),
        builder.punct(",") catch return,
        builder.text(" "),
        builder.styledFmt(.number, "{d}", .{test_count}) catch return,
        builder.text(" executed across "),
        builder.styledFmt(.number, "{d}", .{worker_count}) catch return,
        builder.text(" shards"),
        pretty.hardline,
    }) catch return;
    pretty.write(&writer.interface, doc, renderOptions()) catch {};
}

fn writeFailure(worker_index: usize, worker_count: usize, term: sys.process.Termination) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(std.Options.debug_io, &buffer);
    defer writer.interface.flush() catch {};
    var scratch: [4096]u8 = undefined;
    var scratch_state = std.heap.FixedBufferAllocator.init(&scratch);
    const builder = pretty.Builder.init(scratch_state.allocator());
    const doc = builder.concat(&.{
        tagDoc(builder, "FAIL", .danger) catch return,
        builder.text(" test shard "),
        builder.styledFmt(.number, "{d}", .{worker_index + 1}) catch return,
        builder.punct("/") catch return,
        builder.styledFmt(.number, "{d}", .{worker_count}) catch return,
        builder.text(" exited with status "),
        builder.styledFmt(.danger, "{d}", .{sys.process.exitCode(term)}) catch return,
        pretty.hardline,
    }) catch return;
    pretty.write(&writer.interface, doc, renderOptions()) catch {};
}

fn renderOptions() pretty.LayoutOptions {
    return .{ .width = report_width, .color = .none };
}

fn tagDoc(builder: pretty.Builder, value: []const u8, style: pretty.Style) !pretty.Doc {
    return try builder.concat(&.{
        try builder.punct("["),
        try builder.styledText(style, value),
        try builder.punct("]"),
    });
}
