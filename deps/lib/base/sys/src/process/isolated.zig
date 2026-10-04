const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const native_os = builtin.os.tag;
const child_source_min = 4;
const default_path = std.Io.Threaded.default_PATH;
const syscall_interruptions_max = 8;

/// Specifies what to run and in what environment through the inputs for a
/// captured launch: the argument vector and the environment map.
pub const CapturedOptions = struct {
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
};

/// Starts one Linux child whose standard output and standard error are pipes
/// the caller reads, with standard input on `/dev/null`, for a caller that
/// needs to know the child holds none of its descriptors.
///
/// Before it execs, the child arms the parent-death signal to `SIGKILL` and
/// starts its own process group. One `close_range` call in the child closes any
/// open descriptor above standard error, so that every inherited non-standard
/// descriptor is closed before the program runs, while the pre-exec launcher
/// keeps one private close-on-exec status descriptor at descriptor 3, whose
/// end-of-file after a successful exec tells the parent the launch reached the
/// program. Where a command name has no slash, the launcher finds it by
/// searching a fixed `PATH` list compiled into the launcher, which the
/// environment map does not change.
///
/// A launch that fails anywhere before the program starts is killed and reaped,
/// and reports `DescriptorIsolationFailed`, while an empty argument vector
/// returns `EmptyArgv` and a host other than Linux returns
/// `UnsupportedPlatform`.
pub fn spawnCaptured(
    allocator: Allocator,
    options: CapturedOptions,
) !std.process.Child {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    if (options.argv.len == 0) return error.EmptyArgv;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try prepareArgv(arena, options.argv);
    const environment = try options.environment.createPosixBlock(arena, .{
        .zig_progress_fd = -1,
    });
    var executable_storage: [std.posix.PATH_MAX]u8 = undefined;
    const executable = try executablePath(
        argv[0].?,
        options.argv[0],
        &executable_storage,
    );

    var descriptors = try Descriptors.init();
    defer descriptors.deinit();
    const parent_id = linux.getpid();
    const fork_result = linux.fork();
    switch (linux.errno(fork_result)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.DescriptorIsolationFailed,
    }
    if (fork_result == 0) {
        launchChild(
            parent_id,
            descriptors,
            executable,
            argv,
            environment,
        );
    }

    const child_id: linux.pid_t = @intCast(fork_result);
    descriptors.closeSources();
    if (!launchSucceeded(descriptors.status_read)) {
        terminateAndReap(child_id);
        return error.DescriptorIsolationFailed;
    }
    descriptors.closeStatus();

    const stdout_descriptor = descriptors.takeStdout();
    const stderr_descriptor = descriptors.takeStderr();
    return .{
        .id = child_id,
        .thread_handle = {},
        .stdin = null,
        .stdout = .{
            .handle = stdout_descriptor,
            .flags = .{ .nonblocking = false },
        },
        .stderr = .{
            .handle = stderr_descriptor,
            .flags = .{ .nonblocking = false },
        },
        .request_resource_usage_statistics = false,
    };
}

fn prepareArgv(
    allocator: Allocator,
    arguments: []const []const u8,
) ![:null]?[*:0]const u8 {
    const pointers = try allocator.allocSentinel(
        ?[*:0]const u8,
        arguments.len,
        null,
    );
    for (arguments, pointers[0..arguments.len]) |argument, *pointer| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) {
            return error.InvalidArgument;
        }
        pointer.* = (try allocator.dupeSentinel(u8, argument, 0)).ptr;
    }
    return pointers;
}

fn executablePath(
    prepared_name: [*:0]const u8,
    name: []const u8,
    candidate_storage: *[std.posix.PATH_MAX]u8,
) ![:0]const u8 {
    if (name.len == 0) return error.FileNotFound;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return prepared_name[0..name.len :0];
    }

    var directories = std.mem.splitScalar(u8, default_path, ':');
    var access_denied = false;
    while (directories.next()) |raw_directory| {
        const directory = if (raw_directory.len == 0) "." else raw_directory;
        const candidate_len = directory.len + 1 + name.len;
        if (candidate_len >= candidate_storage.len) return error.NameTooLong;
        @memcpy(candidate_storage[0..directory.len], directory);
        candidate_storage[directory.len] = '/';
        @memcpy(candidate_storage[directory.len + 1 .. candidate_len], name);
        candidate_storage[candidate_len] = 0;
        const candidate = candidate_storage[0..candidate_len :0];
        switch (linux.errno(linux.access(candidate.ptr, linux.X_OK))) {
            .SUCCESS => return candidate,
            .ACCES => access_denied = true,
            .NOENT, .NOTDIR => {},
            else => return error.DescriptorIsolationFailed,
        }
    }
    if (access_denied) return error.AccessDenied;
    return error.FileNotFound;
}

const Descriptors = struct {
    stdout_read: linux.fd_t = -1,
    stdout_source: linux.fd_t = -1,
    stderr_read: linux.fd_t = -1,
    stderr_source: linux.fd_t = -1,
    status_read: linux.fd_t = -1,
    status_source: linux.fd_t = -1,
    null_source: linux.fd_t = -1,

    fn init() !Descriptors {
        var self = Descriptors{};
        errdefer self.deinit();
        const stdout = try capturedPipe();
        self.stdout_read = stdout.read;
        self.stdout_source = stdout.source;
        const stderr = try capturedPipe();
        self.stderr_read = stderr.read;
        self.stderr_source = stderr.source;
        const status = try capturedPipe();
        self.status_read = status.read;
        self.status_source = status.source;
        self.null_source = try nullSource();
        return self;
    }

    fn closeSources(self: *Descriptors) void {
        closeDescriptor(&self.null_source);
        closeDescriptor(&self.status_source);
        closeDescriptor(&self.stderr_source);
        closeDescriptor(&self.stdout_source);
    }

    fn closeStatus(self: *Descriptors) void {
        closeDescriptor(&self.status_read);
    }

    fn takeStdout(self: *Descriptors) linux.fd_t {
        const descriptor = self.stdout_read;
        self.stdout_read = -1;
        return descriptor;
    }

    fn takeStderr(self: *Descriptors) linux.fd_t {
        const descriptor = self.stderr_read;
        self.stderr_read = -1;
        return descriptor;
    }

    fn deinit(self: *Descriptors) void {
        self.closeSources();
        self.closeStatus();
        closeDescriptor(&self.stderr_read);
        closeDescriptor(&self.stdout_read);
        self.* = undefined;
    }
};

const CapturedPipe = struct {
    read: linux.fd_t,
    source: linux.fd_t,
};

fn capturedPipe() !CapturedPipe {
    var descriptors: [2]linux.fd_t = undefined;
    var interruptions: u8 = 0;
    while (interruptions < syscall_interruptions_max) {
        const result = linux.pipe2(&descriptors, .{ .CLOEXEC = true });
        switch (linux.errno(result)) {
            .SUCCESS => break,
            .INTR => interruptions += 1,
            else => return error.DescriptorIsolationFailed,
        }
    } else return error.DescriptorIsolationFailed;
    errdefer {
        _ = linux.close(descriptors[1]);
        _ = linux.close(descriptors[0]);
    }

    const source = try promoteSource(descriptors[1]);
    if (source != descriptors[1]) _ = linux.close(descriptors[1]);
    return .{ .read = descriptors[0], .source = source };
}

fn nullSource() !linux.fd_t {
    const descriptor_result = linux.open(
        "/dev/null",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    if (linux.errno(descriptor_result) != .SUCCESS) {
        return error.DescriptorIsolationFailed;
    }
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    errdefer _ = linux.close(descriptor);
    const source = try promoteSource(descriptor);
    if (source != descriptor) _ = linux.close(descriptor);
    return source;
}

fn promoteSource(descriptor: linux.fd_t) !linux.fd_t {
    if (descriptor >= child_source_min) return descriptor;
    var interruptions: u8 = 0;
    while (interruptions < syscall_interruptions_max) {
        const result = linux.fcntl(
            descriptor,
            linux.F.DUPFD_CLOEXEC,
            child_source_min,
        );
        switch (linux.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => interruptions += 1,
            else => return error.DescriptorIsolationFailed,
        }
    }
    return error.DescriptorIsolationFailed;
}

fn launchChild(
    parent_id: linux.pid_t,
    descriptors: Descriptors,
    executable: [:0]const u8,
    argv: [:null]?[*:0]const u8,
    environment: std.process.Environ.PosixBlock,
) noreturn {
    if (!armParentDeath() or linux.getppid() != parent_id) {
        launchFailure(descriptors.status_source);
    }
    if (!duplicateTo(descriptors.null_source, linux.STDIN_FILENO, false)) {
        launchFailure(descriptors.status_source);
    }
    if (!duplicateTo(descriptors.stdout_source, linux.STDOUT_FILENO, false)) {
        launchFailure(descriptors.status_source);
    }
    if (!duplicateTo(descriptors.stderr_source, linux.STDERR_FILENO, false)) {
        launchFailure(descriptors.status_source);
    }
    if (!duplicateTo(descriptors.status_source, 3, true)) {
        launchFailure(descriptors.status_source);
    }
    if (linux.errno(linux.setpgid(0, 0)) != .SUCCESS) launchFailure(3);

    const last: linux.fd_t = @bitCast(@as(u32, std.math.maxInt(u32)));
    const close_flags: linux.CLOSE_RANGE = @bitCast(@as(u32, 0));
    if (linux.errno(linux.close_range(4, last, close_flags)) != .SUCCESS) {
        launchFailure(3);
    }
    _ = linux.execve(executable.ptr, argv.ptr, environment.slice.ptr);
    launchFailure(3);
}

fn armParentDeath() bool {
    const result = linux.prctl(
        @backingInt(linux.PR.SET_PDEATHSIG),
        @backingInt(linux.SIG.KILL),
        0,
        0,
        0,
    );
    return linux.errno(result) == .SUCCESS;
}

fn duplicateTo(
    source: linux.fd_t,
    target: linux.fd_t,
    close_on_exec: bool,
) bool {
    const flags: u32 = if (close_on_exec)
        @bitCast(linux.O{ .CLOEXEC = true })
    else
        0;
    var interruptions: u8 = 0;
    while (interruptions < syscall_interruptions_max) {
        const result = linux.dup3(source, target, flags);
        switch (linux.errno(result)) {
            .SUCCESS => return true,
            .INTR => interruptions += 1,
            else => return false,
        }
    }
    return false;
}

fn launchFailure(descriptor: linux.fd_t) noreturn {
    const marker = [1]u8{1};
    var interruptions: u8 = 0;
    while (interruptions < syscall_interruptions_max) {
        const result = linux.write(descriptor, &marker, marker.len);
        switch (linux.errno(result)) {
            .SUCCESS => break,
            .INTR => interruptions += 1,
            else => break,
        }
    }
    linux.exit_group(127);
}

fn launchSucceeded(descriptor: linux.fd_t) bool {
    var marker: [1]u8 = undefined;
    var interruptions: u8 = 0;
    while (interruptions < syscall_interruptions_max) {
        const result = linux.read(descriptor, &marker, marker.len);
        switch (linux.errno(result)) {
            .SUCCESS => return result == 0,
            .INTR => interruptions += 1,
            else => return false,
        }
    }
    return false;
}

fn terminateAndReap(child_id: linux.pid_t) void {
    _ = linux.kill(-child_id, .KILL);
    _ = linux.kill(child_id, .KILL);
    var status: i32 = undefined;
    while (true) {
        const result = linux.wait4(child_id, &status, 0, null);
        switch (linux.errno(result)) {
            .SUCCESS, .CHILD => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn closeDescriptor(descriptor: *linux.fd_t) void {
    if (descriptor.* >= 0) _ = linux.close(descriptor.*);
    descriptor.* = -1;
}

test "captured descriptors fit the standard launch capacity" {
    if (comptime native_os != .linux) return error.SkipZigTest;
    const limits = try std.posix.getrlimit(.NOFILE);
    if (limits.max < 10) return error.SkipZigTest;

    const fork_result = linux.fork();
    if (linux.errno(fork_result) != .SUCCESS) {
        return error.DescriptorCapacityForkFailed;
    }
    if (fork_result == 0) capacityChild(limits.max);

    var status: i32 = undefined;
    while (true) {
        const wait_result = linux.wait4(
            @intCast(fork_result),
            &status,
            0,
            null,
        );
        switch (linux.errno(wait_result)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.DescriptorCapacityWaitFailed,
        }
    }
    const decoded: u32 = @bitCast(status);
    try std.testing.expect(linux.W.IFEXITED(decoded));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(decoded));
}

fn capacityChild(maximum: u64) noreturn {
    const last: linux.fd_t = @bitCast(@as(u32, std.math.maxInt(u32)));
    const close_flags: linux.CLOSE_RANGE = @bitCast(@as(u32, 0));
    if (linux.errno(linux.close_range(3, last, close_flags)) != .SUCCESS) {
        linux.exit_group(201);
    }
    const limited = linux.rlimit{ .cur = 10, .max = maximum };
    if (linux.errno(linux.setrlimit(.NOFILE, &limited)) != .SUCCESS) {
        linux.exit_group(202);
    }
    var descriptors = Descriptors.init() catch linux.exit_group(203);
    descriptors.deinit();
    linux.exit_group(0);
}
