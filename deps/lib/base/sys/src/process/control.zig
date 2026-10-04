const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../root.zig");

const linux = std.os.linux;
const posix = std.posix;
const system = posix.system;
const native_os = builtin.os.tag;
const is_darwin = switch (native_os) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
    else => false,
};

pub const required_capabilities = sys.capabilities.host(
    &.{ .process, .environment, .threads },
);

pub const Child = std.process.Child;
pub const Init = std.process.Init;
pub const MinimalInit = std.process.Init.Minimal;
pub const Args = std.process.Args;
pub const Environ = std.process.Environ;
pub const SpawnOptions = std.process.SpawnOptions;
pub const SpawnError = std.process.SpawnError;
pub const Termination = Child.Term;
pub const WaitError = Child.WaitError;
pub const RunOptions = std.process.RunOptions;
pub const RunResult = std.process.RunResult;
pub const RunError = std.process.RunError;
pub const ExecutablePathAllocError = std.process.ExecutablePathAllocError;
pub const ProcessId = linux.pid_t;
pub const ThreadId = linux.pid_t;
pub const UserId = linux.uid_t;
pub const GroupId = linux.gid_t;

pub const AuxiliaryKey = enum {
    hardware_capabilities,
    hardware_capabilities_2,
};

pub const AuxiliaryValueError = error{UnsupportedPlatform};
pub const SystemControlError = error{
    UnsupportedPlatform,
    NotFound,
    PermissionDenied,
    BufferTooSmall,
    QueryFailed,
};
pub const KernelReleaseError = error{ UnsupportedPlatform, BufferTooSmall };

pub const ResourceUsageSource = enum {
    getrusage_self,
    wait4_rusage,
};

pub const ResourceUsage = struct {
    source: ?ResourceUsageSource = null,
    maxrss_kib: ?i64 = null,
    user_s: ?f64 = null,
    system_s: ?f64 = null,
    minor_page_faults: ?u64 = null,
    major_page_faults: ?u64 = null,
    voluntary_context_switches: ?u64 = null,
    involuntary_context_switches: ?u64 = null,
};

pub const WaitNoHangOutcome = struct {
    term: Termination,
    usage: ResourceUsage,
};

pub const WaitAnyNoHangOutcome = struct {
    pid: ProcessId,
    outcome: WaitNoHangOutcome,
};

pub const ChildSignal = enum {
    terminate,
    kill,
    pause_child,
    resume_child,
};

pub const ChildSignalPolicy = enum {
    unsupported,
    linux_syscall,
    posix_host,
};

pub const ProcessIdentityPolicy = enum {
    unsupported,
    linux_syscall,
    posix_host,
};

pub const ChildPeekPolicy = enum {
    unsupported,
    linux_waitid,
    darwin_waitid,
};

pub const ChildSignalError = error{
    UnsupportedPlatform,
    ProcessNotFound,
    PermissionDenied,
    InvalidSignal,
    SignalFailed,
};

pub const ProcessIdentityError = error{
    UnsupportedPlatform,
};

pub const ProcessGroupError = error{
    UnsupportedPlatform,
    ProcessNotFound,
    PermissionDenied,
};

pub const SubreaperError = error{
    UnsupportedPlatform,
    SubreaperFailed,
};

pub const ForkError = error{
    UnsupportedPlatform,
    SystemResources,
    ForkFailed,
};

pub const ForkResult = union(enum) {
    child,
    parent: ProcessId,
};

pub const ExecDescriptorError = error{
    UnsupportedPlatform,
    InvalidDescriptor,
    AccessDenied,
    InvalidExecutable,
    ExecFailed,
};
pub const ExecUnderStackError = error{
    UnsupportedPlatform,
    InvalidLimit,
    PermissionDenied,
    PersonaFailed,
    AccessDenied,
    InvalidExecutable,
    ExecFailed,
};

pub const WaitDirectError = error{
    UnsupportedPlatform,
    ChildAlreadyReaped,
    ChildWaitFailed,
};

pub const DetachPolicy = enum {
    unsupported,
    linux_cloexec_process_group,
};

pub const DetachOptions = struct {
    argv: []const []const u8,
    cwd: Child.Cwd = .inherit,
    environ_map: ?*const Environ.Map = null,
};

pub const DetachError = SpawnError || error{
    UnsupportedPlatform,
    DescriptorIsolationFailed,
};
pub const DescriptorIsolationError = error{
    UnsupportedPlatform,
    DescriptorIsolationFailed,
};
pub const ReapHandoffError = sys.thread.SpawnError || error{
    MissingChildId,
};

pub fn spawn(io: anytype, options: SpawnOptions) SpawnError!Child {
    return std.process.spawn(io, options);
}

pub const SpawnIntoError = SpawnError || error{
    /// No child started the program: the kernel refused the group, setup
    /// failed before any child existed, or the child was killed before its
    /// exec by the handshake deadline. The caller may spawn it elsewhere.
    CgroupJoinRefused,
};

pub const SpawnWithinError = SpawnError || error{
    /// The child neither exec'd nor reported a failure by the deadline. It
    /// was killed before its exec, so the program never ran.
    StartTimedOut,
};

/// How long a killed child that has not exec'd gets to be reaped. A child
/// still unreaped then stays a zombie of the caller, whose next reap of its
/// own descendants collects it.
pub const start_reap_ns: i128 = 100 * std.time.ns_per_ms;

/// Starts a child the way `spawn` does on a `std.Io.Threaded`, except that the
/// child is born in the control group `group` holds open, so its first
/// instruction and every process it starts run there. `clone3` with
/// `CLONE_INTO_CGROUP` takes the place of `fork`, and the kernel checks the
/// group before any child exists, so any clone failure returns
/// `CgroupJoinRefused` and leaves nothing to reap. Between the clone and the
/// exec the child repeats std's setup in std's order: standard streams,
/// working directory, process group, and an exec over the parent's `PATH`.
/// It shares std's cached `/dev/null` descriptor and reports an exec failure
/// through the same error pipe as the same error. The signal mask and ignored
/// signals pass to the program unchanged, as they do through `spawn`. `io` must be a
/// `std.Io.Threaded`, the implementation whose spawn this repeats. A progress
/// node, a user or group change, a suspended start and argument expansion are
/// outside this call. Linux only; every other host returns
/// `CgroupJoinRefused`.
///
/// The child claims its exec, through a page it shares with the parent, just
/// before its first `execve`; the `PATH` search after the claim is only
/// `execve` attempts. A claimed launch is a started child. `deadline_ns`
/// bounds only the unclaimed part: at the deadline the parent cancels an
/// unclaimed start, kills and reaps the child within `start_reap_ns`, and
/// returns `CgroupJoinRefused`, so the program never ran. A claimed child is
/// returned like any spawned one, even if its group is frozen afterwards;
/// pausing it then is the group owner's choice, as it is for a child that
/// exec'd a moment earlier. A claimed child that stalls past the deadline in
/// `execve` and whose exec then fails reports exit status 1 instead of the
/// exec error, since the parent has stopped reading the error pipe.
pub fn spawnInto(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: SpawnOptions,
    group: posix.fd_t,
    deadline_ns: i128,
) SpawnIntoError!Child {
    if (comptime native_os != .linux) return error.CgroupJoinRefused;
    // Every failure here comes before any child exists.
    const started = startInto(io, allocator, options, group) catch return error.CgroupJoinRefused;
    return finishStart(started, options, deadline_ns) catch |err| switch (err) {
        error.StartTimedOut => error.CgroupJoinRefused,
        else => |other| other,
    };
}

/// Starts a child as `spawn` does, except that the exec handshake ends at
/// `deadline_ns` on the `sys.time.nanoTimestamp` clock. A child that has not
/// reached its exec by then is killed, and the call returns `StartTimedOut`.
/// Linux only; every other host calls `spawn`.
pub fn spawnWithin(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: SpawnOptions,
    deadline_ns: i128,
) SpawnWithinError!Child {
    if (comptime native_os != .linux) return spawn(io, options);
    const started = startInto(io, allocator, options, null) catch |err| switch (err) {
        // Only a group refuses a join.
        error.CgroupJoinRefused => unreachable,
        else => |other| return other,
    };
    return finishStart(started, options, deadline_ns);
}

/// Waits for the child's exec or its reported failure until `deadline_ns`.
/// At the deadline the parent tries to cancel the child's claim on its exec.
/// A child that has not claimed it is killed, so the program never ran. A
/// child that has claimed it is starting the program and is returned as
/// started. An exec failure it reports later reaches its caller as exit 1.
fn finishStart(started: IntoStarted, options: SpawnOptions, deadline_ns: i128) SpawnWithinError!Child {
    defer _ = linux.close(started.failure);
    defer releaseClaim(started.claim);
    const outcome = awaitStart(started, deadline_ns);
    if (outcome != .started) {
        inline for (.{ started.stdin, started.stdout, started.stderr }) |stream| {
            if (stream) |file| _ = linux.close(file.handle);
        }
        // The child has exited or is killed; std leaves a failed child for
        // the caller's wait, and this reaps it within a bound instead.
        _ = reapWithin(started.pid, sys.time.nanoTimestamp() + start_reap_ns);
    }
    return switch (outcome) {
        .started => .{
            .id = started.pid,
            .thread_handle = {},
            .stdin = started.stdin,
            .stdout = started.stdout,
            .stderr = started.stderr,
            .request_resource_usage_statistics = options.request_resource_usage_statistics,
        },
        .failed => |code| @errorCast(@errorFromInt(code)),
        .cancelled => error.StartTimedOut,
    };
}

const StartOutcome = union(enum) {
    started,
    failed: IntoFailure,
    cancelled,
};

fn awaitStart(started: IntoStarted, deadline_ns: i128) StartOutcome {
    while (true) {
        const left = deadline_ns - sys.time.nanoTimestamp();
        if (left <= 0) break;
        var descriptors = [_]linux.pollfd{.{ .fd = started.failure, .events = linux.POLL.IN, .revents = 0 }};
        const wait_ms: i32 = @intCast(@min(@divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms), 1000));
        const rc = linux.poll(&descriptors, 1, wait_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 1) return readStart(started.failure),
            .INTR => {},
            // As in std, an unpollable pipe leaves the child treated as started.
            else => return .started,
        }
    }
    // The pipe may have become ready as the deadline passed.
    var descriptors = [_]linux.pollfd{.{ .fd = started.failure, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.poll(&descriptors, 1, 0) == 1) return readStart(started.failure);
    if (@cmpxchgStrong(u32, started.claim, claim_open, claim_cancelled, .seq_cst, .seq_cst) != null) {
        return .started;
    }
    _ = linux.kill(started.pid, linux.SIG.KILL);
    return .cancelled;
}

fn readStart(descriptor: posix.fd_t) StartOutcome {
    return if (readIntoFailure(descriptor)) |code| .{ .failed = code } else .started;
}

/// Reaps `pid` if it exits by `deadline_ns`, and reports whether it did.
fn reapWithin(pid: ProcessId, deadline_ns: i128) bool {
    while (true) {
        if (waitNoHang(pid) catch return false) |_| return true;
        if (sys.time.nanoTimestamp() >= deadline_ns) return false;
        sys.time.sleepNanoseconds(std.time.ns_per_ms);
    }
}

/// Unmaps the page `startInto` mapped for a claim: one page, as
/// `mapSharedAnonymous` rounds a `u32` up to one.
fn releaseClaim(claim: *u32) void {
    const page: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(claim));
    sys.memory.unmap(page[0..sys.memory.pageSize()]);
}

const claim_open: u32 = 0;
const claim_exec: u32 = 1;
const claim_cancelled: u32 = 2;

const IntoStarted = struct {
    pid: ProcessId,
    failure: posix.fd_t,
    /// A word shared with the child, which it moves from `claim_open` to
    /// `claim_exec` before its first exec. The parent moves it to
    /// `claim_cancelled` to stop an exec that has not begun.
    claim: *u32,
    stdin: ?std.Io.File,
    stdout: ?std.Io.File,
    stderr: ?std.Io.File,
};

fn startInto(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: SpawnOptions,
    group: ?posix.fd_t,
) SpawnIntoError!IntoStarted {
    std.debug.assert(options.progress_node.index == .none);
    std.debug.assert(options.uid == null and options.gid == null);
    std.debug.assert(!options.start_suspended and options.expand_arg0 == .no_expand);
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata));

    const stdin_pipe = if (options.stdin == .pipe) try intoPipe() else undefined;
    errdefer if (options.stdin == .pipe) closeIntoPipe(stdin_pipe);
    const stdout_pipe = if (options.stdout == .pipe) try intoPipe() else undefined;
    errdefer if (options.stdout == .pipe) closeIntoPipe(stdout_pipe);
    const stderr_pipe = if (options.stderr == .pipe) try intoPipe() else undefined;
    errdefer if (options.stderr == .pipe) closeIntoPipe(stderr_pipe);
    const any_ignore = options.stdin == .ignore or options.stdout == .ignore or
        options.stderr == .ignore;
    const dev_null = if (any_ignore) try threadedNull(threaded) else undefined;

    // As in std, nothing is allocated between the clone and the exec.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (options.argv, 0..) |argument, index| argv[index] = (try arena.dupeSentinel(u8, argument, 0)).ptr;
    const environment = if (options.environ_map) |map|
        try map.createPosixBlock(arena, .{ .zig_progress_fd = -1 })
    else
        try threaded.environ.process_environ.createPosixBlock(arena, .{ .zig_progress_fd = -1 });
    const cwd_path: ?[*:0]const u8 = switch (options.cwd) {
        .path => |path| (try arena.dupeSentinel(u8, path, 0)).ptr,
        else => null,
    };
    const search = threadedPath(threaded) orelse std.Io.Threaded.default_PATH;

    const failure_pipe = try intoPipe();
    errdefer closeIntoPipe(failure_pipe);
    const claim_page = sys.memory.mapSharedAnonymous(@sizeOf(u32), .{ .read = true, .write = true }) catch
        return error.SystemResources;
    const claim: *u32 = @ptrCast(claim_page.ptr);
    errdefer releaseClaim(claim);
    claim.* = claim_open;
    var arguments = std.mem.zeroes(CloneArguments);
    arguments.exit_signal = @backingInt(linux.SIG.CHLD);
    if (group) |descriptor| {
        arguments.flags = linux.CLONE.INTO_CGROUP;
        arguments.cgroup = @intCast(descriptor);
    }
    const cloned = linux.syscall2(.clone3, @intFromPtr(&arguments), @sizeOf(CloneArguments));
    // Every failure, EAGAIN from a full pids.max included, leaves no child, so
    // the caller can still start the program outside the group.
    switch (linux.errno(cloned)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return if (group == null) error.SystemResources else error.CgroupJoinRefused,
        else => return if (group == null) error.Unexpected else error.CgroupJoinRefused,
    }
    if (cloned == 0) intoChild(.{
        .options = &options,
        .stdin = if (options.stdin == .pipe) stdin_pipe[0] else -1,
        .stdout = if (options.stdout == .pipe) stdout_pipe[1] else -1,
        .stderr = if (options.stderr == .pipe) stderr_pipe[1] else -1,
        .dev_null = if (any_ignore) dev_null else -1,
        .cwd_path = cwd_path,
        .argv = argv.ptr,
        .environment = environment.slice.ptr,
        .search = search,
        .failure = failure_pipe[1],
        .claim = claim,
    });
    errdefer comptime unreachable;

    const pid: ProcessId = @intCast(cloned);
    _ = linux.close(failure_pipe[1]);
    if (options.stdin == .pipe) _ = linux.close(stdin_pipe[0]);
    if (options.stdout == .pipe) _ = linux.close(stdout_pipe[1]);
    if (options.stderr == .pipe) _ = linux.close(stderr_pipe[1]);
    return .{
        .pid = pid,
        .failure = failure_pipe[0],
        .claim = claim,
        .stdin = if (options.stdin == .pipe) .{ .handle = stdin_pipe[1], .flags = .{ .nonblocking = false } } else null,
        .stdout = if (options.stdout == .pipe) .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } } else null,
        .stderr = if (options.stderr == .pipe) .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = false } } else null,
    };
}

/// The kernel's `struct clone_args` through `cgroup`, its version-two size.
const CloneArguments = extern struct {
    flags: u64,
    pidfd: u64,
    child_tid: u64,
    parent_tid: u64,
    exit_signal: u64,
    stack: u64,
    stack_size: u64,
    tls: u64,
    set_tid: u64,
    set_tid_size: u64,
    cgroup: u64,
};

const IntoFailure = @Int(.unsigned, @sizeOf(anyerror) * 8);

const IntoChild = struct {
    options: *const SpawnOptions,
    stdin: posix.fd_t,
    stdout: posix.fd_t,
    stderr: posix.fd_t,
    dev_null: posix.fd_t,
    cwd_path: ?[*:0]const u8,
    argv: [*:null]?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    search: []const u8,
    failure: posix.fd_t,
    claim: *u32,
};

/// Runs in the cloned child and never returns. It makes raw system calls
/// only, in the order of std's `spawnPosix`.
fn intoChild(child: IntoChild) noreturn {
    const options = child.options;
    intoStdio(options.stdin, child.stdin, posix.STDIN_FILENO, child.dev_null) catch |err|
        intoFail(child.failure, err);
    intoStdio(options.stdout, child.stdout, posix.STDOUT_FILENO, child.dev_null) catch |err|
        intoFail(child.failure, err);
    intoStdio(options.stderr, child.stderr, posix.STDERR_FILENO, child.dev_null) catch |err|
        intoFail(child.failure, err);
    switch (options.cwd) {
        .inherit => {},
        .dir => |directory| if (directory.handle != posix.AT.FDCWD) {
            switch (linux.errno(linux.fchdir(directory.handle))) {
                .SUCCESS => {},
                .ACCES => intoFail(child.failure, error.AccessDenied),
                .NOTDIR => intoFail(child.failure, error.NotDir),
                .IO => intoFail(child.failure, error.FileSystem),
                else => intoFail(child.failure, error.Unexpected),
            }
        },
        .path => switch (linux.errno(linux.chdir(child.cwd_path.?))) {
            .SUCCESS => {},
            .ACCES => intoFail(child.failure, error.AccessDenied),
            .IO => intoFail(child.failure, error.FileSystem),
            .LOOP => intoFail(child.failure, error.SymLinkLoop),
            .NAMETOOLONG => intoFail(child.failure, error.NameTooLong),
            .NOENT => intoFail(child.failure, error.FileNotFound),
            .NOMEM => intoFail(child.failure, error.SystemResources),
            .NOTDIR => intoFail(child.failure, error.NotDir),
            .ILSEQ => intoFail(child.failure, error.BadPathName),
            else => intoFail(child.failure, error.Unexpected),
        },
    }
    if (options.pgid) |group_id| switch (linux.errno(linux.setpgid(0, group_id))) {
        .SUCCESS => {},
        .ACCES => intoFail(child.failure, error.ProcessAlreadyExec),
        .INVAL => intoFail(child.failure, error.InvalidProcessGroupId),
        .PERM => intoFail(child.failure, error.PermissionDenied),
        else => intoFail(child.failure, error.Unexpected),
    };
    // A parent that gave up before this point has killed or will kill this
    // child, and must be able to tell that the program never ran.
    if (@cmpxchgStrong(u32, child.claim, claim_open, claim_exec, .seq_cst, .seq_cst) != null) {
        linux.exit_group(1);
    }
    intoFail(child.failure, intoExec(child.argv, child.environment, child.search));
}

fn intoStdio(
    stdio: SpawnOptions.StdIo,
    pipe_descriptor: posix.fd_t,
    standard: posix.fd_t,
    dev_null: posix.fd_t,
) error{ ProcessFdQuotaExceeded, SystemResources, Unexpected }!void {
    const source = switch (stdio) {
        .pipe => pipe_descriptor,
        .close => {
            _ = linux.close(standard);
            return;
        },
        .inherit => return,
        .ignore => dev_null,
        .file => |file| file.handle,
    };
    while (true) switch (linux.errno(linux.dup2(source, standard))) {
        .SUCCESS => return,
        .BUSY, .INTR => continue,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    };
}

/// std's `posixExecv` over `PATH` without argument expansion.
fn intoExec(
    argv: [*:null]?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    search: []const u8,
) std.process.ReplaceError {
    const file = std.mem.sliceTo(argv[0].?, 0);
    if (std.mem.indexOfScalar(u8, file, '/') != null) return intoExecPath(argv[0].?, argv, environment);
    var path_storage: [posix.PATH_MAX]u8 = undefined;
    var directories = std.mem.tokenizeScalar(u8, search, ':');
    var seen_access = false;
    var result: std.process.ReplaceError = error.FileNotFound;
    while (directories.next()) |directory| {
        const length = directory.len + file.len + 1;
        if (path_storage.len < length + 1) return error.NameTooLong;
        @memcpy(path_storage[0..directory.len], directory);
        path_storage[directory.len] = '/';
        @memcpy(path_storage[directory.len + 1 ..][0..file.len], file);
        path_storage[length] = 0;
        result = intoExecPath(path_storage[0..length :0].ptr, argv, environment);
        switch (result) {
            error.AccessDenied => seen_access = true,
            error.FileNotFound, error.NotDir => {},
            else => |err| return err,
        }
    }
    if (seen_access) return error.AccessDenied;
    return result;
}

/// std's `posixExecveat` error mapping, without its cancellation check.
fn intoExecPath(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
) std.process.ReplaceError {
    return switch (linux.errno(linux.execve(path, argv, environment))) {
        .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .INVAL, .NOEXEC, .LIBBAD => error.InvalidExe,
        .IO, .LOOP => error.FileSystem,
        .ISDIR => error.IsDir,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .TXTBSY => error.FileBusy,
        else => error.Unexpected,
    };
}

fn intoFail(failure: posix.fd_t, err: anyerror) noreturn {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @as(IntoFailure, @intFromError(err)), .little);
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(failure, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => written += rc,
            .INTR => continue,
            else => break,
        }
    }
    linux.exit_group(1);
}

/// Returns the error the child reported, or null once the exec closed the pipe.
fn readIntoFailure(descriptor: posix.fd_t) ?IntoFailure {
    var bytes: [8]u8 = undefined;
    var count: usize = 0;
    while (count < bytes.len) {
        const rc = linux.read(descriptor, bytes[count..].ptr, bytes.len - count);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                count += rc;
            },
            .INTR => continue,
            // As in std, an unreadable pipe leaves the child treated as started.
            else => return null,
        }
    }
    if (count != bytes.len) return null;
    return @intCast(std.mem.readInt(u64, &bytes, .little));
}

fn intoPipe() SpawnError![2]posix.fd_t {
    var descriptors: [2]posix.fd_t = undefined;
    return switch (linux.errno(linux.pipe2(&descriptors, .{ .CLOEXEC = true }))) {
        .SUCCESS => descriptors,
        .NFILE => error.SystemFdQuotaExceeded,
        .MFILE => error.ProcessFdQuotaExceeded,
        else => error.Unexpected,
    };
}

fn closeIntoPipe(descriptors: [2]posix.fd_t) void {
    _ = linux.close(descriptors[0]);
    _ = linux.close(descriptors[1]);
}

/// The `/dev/null` descriptor std's spawn caches on `threaded`, opened the same
/// way when this call is the first to need it.
fn threadedNull(threaded: *std.Io.Threaded) SpawnError!posix.fd_t {
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    if (threaded.null_file.fd != -1) return threaded.null_file.fd;
    while (true) {
        const rc = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                threaded.null_file.fd = @intCast(rc);
                return threaded.null_file.fd;
            },
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            else => return error.Unexpected,
        }
    }
}

/// The parent's `PATH` as std's environment scan records it: the last entry of
/// the process environment wins.
fn threadedPath(threaded: *std.Io.Threaded) ?[]const u8 {
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    var found: ?[]const u8 = null;
    for (threaded.environ.process_environ.block.slice) |entry_or_null| {
        const entry = std.mem.sliceTo(entry_or_null orelse continue, 0);
        if (std.mem.startsWith(u8, entry, "PATH=")) found = entry["PATH=".len..];
    }
    return found;
}

pub fn fork() ForkError!ForkResult {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const result = linux.fork();
    return switch (linux.errno(result)) {
        .SUCCESS => if (result == 0) .child else .{ .parent = @intCast(result) },
        .AGAIN, .NOMEM => error.SystemResources,
        else => error.ForkFailed,
    };
}

pub fn execDescriptor(
    descriptor: posix.fd_t,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
) ExecDescriptorError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const result = linux.execveat(
        descriptor,
        "",
        argv,
        environment,
        .{ .SYMLINK_NOFOLLOW = true, .EMPTY_PATH = true },
    );
    return switch (linux.errno(result)) {
        .BADF => error.InvalidDescriptor,
        .ACCES => error.AccessDenied,
        .NOEXEC => error.InvalidExecutable,
        else => error.ExecFailed,
    };
}

/// The Linux persona value `ADDR_NO_RANDOMIZE`, set by exec under a stack
/// limit, gives a process carrying it its initial stack at one address on every
/// run.
const persona_no_randomize: usize = 0x0040000;

/// Caps this process at `stack_bytes` of stack and then hands it over to the
/// program at `path`. The initial stack lands at the address the kernel picks
/// when no randomization applies, so a harness that has to show a program stays
/// inside a stack budget gets the same answer on every run. Linux otherwise
/// shifts the initial stack pointer down by a random amount of up to eight
/// kilobytes before the program executes an instruction, in `arch_align_stack`,
/// which leaves a program at a fixed limit surviving one run and overflowing
/// the next. The order runs persona, then the soft and hard limit in one call,
/// and then the exec. A return means the exec failed, and both settings remain
/// in force on the calling process, so a caller with work left to do makes this
/// call inside a forked child. A zero limit fails with `InvalidLimit`, and a
/// host other than Linux with `UnsupportedPlatform`.
pub fn execUnderStack(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    stack_bytes: u64,
) ExecUnderStackError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    if (stack_bytes == 0) return error.InvalidLimit;
    if (linux.errno(linux.syscall1(.personality, persona_no_randomize)) != .SUCCESS) {
        return error.PersonaFailed;
    }
    const limit = linux.rlimit{ .cur = stack_bytes, .max = stack_bytes };
    switch (linux.errno(linux.setrlimit(.STACK, &limit))) {
        .SUCCESS => {},
        .INVAL => return error.InvalidLimit,
        .PERM => return error.PermissionDenied,
        else => return error.InvalidLimit,
    }
    const result = linux.execve(path, argv, environment);
    return switch (linux.errno(result)) {
        .ACCES => error.AccessDenied,
        .NOEXEC => error.InvalidExecutable,
        else => error.ExecFailed,
    };
}

/// A child `spawnBound` starts: an absolute executable with its arguments, an absolute starting
/// directory, an empty environment, and the caller's descriptor as standard input. Standard output
/// and standard error come back as pipes. The null-terminated copies of the arguments and the
/// directory are built in `scratch` and `pointers` before the fork, so the child allocates nothing.
pub const BoundOptions = struct {
    argv: []const []const u8,
    directory: []const u8,
    stdin: posix.fd_t,
    scratch: []u8,
    pointers: []?[*:0]const u8,
};

pub const BoundError = error{
    UnsupportedPlatform,
    ScratchTooSmall,
    InvalidArgument,
    SystemResources,
    ForkFailed,
    ChildSetupFailed,
    BindingFailed,
    DirectoryFailed,
    FileNotFound,
    AccessDenied,
    ExecFailed,
};

/// Codes the child writes on its error pipe before it exits. The exec closes the pipe on success.
const BoundFailure = enum(u8) {
    setup = 1,
    binding = 2,
    directory = 3,
    not_found = 4,
    access = 5,
    exec = 6,
};

/// Starts a child in its own process group that the kernel kills when its parent dies. Between the
/// fork and the exec the child asks for `SIGKILL` on parent death, then reads its parent again and
/// exits if the parent is already gone, which closes the race between the fork and the request.
/// Linux delivers the signal when the *thread* that forked exits, so a caller spawns from a thread
/// that lives as long as the process. The binding covers the direct child only: a descendant that
/// the child starts is not bound. Linux only; every other host refuses with `UnsupportedPlatform`.
pub fn spawnBound(options: BoundOptions) BoundError!Child {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    if (options.argv.len == 0 or options.pointers.len < options.argv.len + 1)
        return error.ScratchTooSmall;
    var used: usize = 0;
    for (options.argv, 0..) |argument, index| {
        options.pointers[index] = try boundString(options.scratch, &used, argument);
    }
    options.pointers[options.argv.len] = null;
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(options.pointers.ptr);
    const directory = try boundString(options.scratch, &used, options.directory);
    const environment = [_:null]?[*:0]const u8{};

    // The parent closes each pipe by hand once the fork has happened.
    var forked_once = false;
    const stdout_pipe = try boundPipe();
    errdefer if (!forked_once) closeBoundPipe(stdout_pipe);
    const stderr_pipe = try boundPipe();
    errdefer if (!forked_once) closeBoundPipe(stderr_pipe);
    const failure_pipe = try boundPipe();
    defer _ = linux.close(failure_pipe[0]);

    const parent = linux.getpid();
    const forked = linux.fork();
    switch (linux.errno(forked)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => {
            _ = linux.close(failure_pipe[1]);
            return error.SystemResources;
        },
        else => {
            _ = linux.close(failure_pipe[1]);
            return error.ForkFailed;
        },
    }
    if (forked == 0) boundChild(.{
        .parent = parent,
        .argv = argv,
        .directory = directory,
        .environment = &environment,
        .stdin = options.stdin,
        .stdout = stdout_pipe[1],
        .stderr = stderr_pipe[1],
        .failure = failure_pipe[1],
    });

    forked_once = true;
    const pid: ProcessId = @intCast(forked);
    _ = linux.close(failure_pipe[1]);
    _ = linux.close(stdout_pipe[1]);
    _ = linux.close(stderr_pipe[1]);
    var code: [1]u8 = undefined;
    const reported = while (true) {
        const rc = linux.read(failure_pipe[0], &code, 1);
        switch (linux.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            // The child's state is unknown, so it is treated as started and left to the caller.
            else => break 0,
        }
    };
    if (reported != 0) {
        _ = linux.close(stdout_pipe[0]);
        _ = linux.close(stderr_pipe[0]);
        _ = waitDirect(pid) catch {};
        return switch (std.enums.fromInt(BoundFailure, code[0]) orelse .exec) {
            .setup => error.ChildSetupFailed,
            .binding => error.BindingFailed,
            .directory => error.DirectoryFailed,
            .not_found => error.FileNotFound,
            .access => error.AccessDenied,
            .exec => error.ExecFailed,
        };
    }
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } },
        .stderr = .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = false } },
        .request_resource_usage_statistics = false,
    };
}

const BoundChild = struct {
    parent: linux.pid_t,
    argv: [*:null]const ?[*:0]const u8,
    directory: [*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    stdin: posix.fd_t,
    stdout: posix.fd_t,
    stderr: posix.fd_t,
    failure: posix.fd_t,
};

/// Runs in the forked child and never returns. It uses only raw system calls.
fn boundChild(child: BoundChild) noreturn {
    if (linux.errno(linux.setpgid(0, 0)) != .SUCCESS) boundFail(child.failure, .setup);
    const death: usize = @backingInt(linux.SIG.KILL);
    if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), death, 0, 0, 0)) != .SUCCESS)
        boundFail(child.failure, .binding);
    if (linux.getppid() != child.parent) linux.exit_group(127);
    for ([_][2]posix.fd_t{
        .{ child.stdin, 0 },
        .{ child.stdout, 1 },
        .{ child.stderr, 2 },
    }) |pair| {
        if (linux.errno(linux.dup2(pair[0], pair[1])) != .SUCCESS)
            boundFail(child.failure, .setup);
    }
    if (linux.errno(linux.chdir(child.directory)) != .SUCCESS)
        boundFail(child.failure, .directory);
    const rc = linux.execve(child.argv[0].?, child.argv, child.environment);
    boundFail(child.failure, switch (linux.errno(rc)) {
        .NOENT, .NOTDIR => .not_found,
        .ACCES, .PERM => .access,
        else => .exec,
    });
}

fn boundFail(failure: posix.fd_t, why: BoundFailure) noreturn {
    const code = [1]u8{@backingInt(why)};
    _ = linux.write(failure, &code, 1);
    linux.exit_group(127);
}

fn boundString(scratch: []u8, used: *usize, bytes: []const u8) BoundError![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidArgument;
    if (scratch.len - used.* < bytes.len + 1) return error.ScratchTooSmall;
    const start = used.*;
    @memcpy(scratch[start..][0..bytes.len], bytes);
    scratch[start + bytes.len] = 0;
    used.* += bytes.len + 1;
    return scratch[start .. start + bytes.len :0].ptr;
}

fn boundPipe() BoundError![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    return switch (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => fds,
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        else => error.ChildSetupFailed,
    };
}

fn closeBoundPipe(fds: [2]posix.fd_t) void {
    _ = linux.close(fds[0]);
    _ = linux.close(fds[1]);
}

pub fn auxiliaryValue(key: AuxiliaryKey) AuxiliaryValueError!usize {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return linux.getauxval(switch (key) {
        .hardware_capabilities => std.elf.AT.HWCAP,
        .hardware_capabilities_2 => std.elf.AT.HWCAP2,
    });
}

/// Returns the GNU build-id descriptor of the running executable, or null when its link wrote
/// none. The kernel passes the program headers in auxv, so no file is read and no syscall runs.
/// The slice borrows the mapped image for the life of the process.
pub fn buildId() BuildIdError!?[]const u8 {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const headers = posix.getSelfPhdrs();
    const bias = for (headers) |header| {
        if (header.type == .PHDR) break @intFromPtr(headers.ptr) -% header.vaddr;
    } else return error.ProgramHeaderMissing;
    for (headers) |header| {
        if (header.type != .NOTE) continue;
        const start: [*]const u8 = @ptrFromInt(bias +% header.vaddr);
        const alignment: usize = if (header.@"align" == 8) 8 else 4;
        const segment = start[0..header.filesz];
        if (noteDescriptor(segment, alignment, std.elf.NT_GNU_BUILD_ID)) |id| return id;
    }
    return null;
}

pub const BuildIdError = error{ UnsupportedPlatform, ProgramHeaderMissing };

/// Returns the descriptor of the first `GNU` note of `kind` in one note segment. Entries pad
/// their name and descriptor to the segment's `alignment`. A truncated entry ends the walk.
pub fn noteDescriptor(segment: []const u8, alignment: usize, kind: u32) ?[]const u8 {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    std.debug.assert(alignment <= 8);
    const header_bytes = @sizeOf(std.elf.Elf64_Nhdr);
    var offset: usize = 0;
    while (segment.len - offset >= header_bytes) {
        const header = std.mem.bytesAsValue(
            std.elf.Elf64_Nhdr,
            segment[offset..][0..header_bytes],
        ).*;
        const name_start = offset + header_bytes;
        if (header.n_namesz > segment.len - name_start) return null;
        const name_end = name_start + header.n_namesz;
        const descriptor_start = std.mem.alignForward(usize, name_end, alignment);
        if (descriptor_start > segment.len or
            header.n_descsz > segment.len - descriptor_start) return null;
        const name = segment[name_start..][0..header.n_namesz];
        if (header.n_type == kind and std.mem.eql(u8, name, "GNU\x00"))
            return segment[descriptor_start..][0..header.n_descsz];
        const next = std.mem.alignForward(usize, descriptor_start + header.n_descsz, alignment);
        if (next > segment.len) return null;
        offset = next;
    }
    return null;
}

pub fn systemControl(
    comptime name: [:0]const u8,
    output: anytype,
) SystemControlError!usize {
    if (comptime !is_darwin) return error.UnsupportedPlatform;
    const pointer = @typeInfo(@TypeOf(output)).pointer;
    var byte_len: usize = @sizeOf(pointer.child);
    const rc = system.sysctlbyname(name, output, &byte_len, null, 0);
    return switch (posix.errno(rc)) {
        .SUCCESS => byte_len,
        .NOENT => error.NotFound,
        .ACCES, .PERM => error.PermissionDenied,
        .NOMEM => error.BufferTooSmall,
        else => error.QueryFailed,
    };
}

pub fn kernelRelease(storage: []u8) KernelReleaseError![]const u8 {
    if (comptime native_os == .windows or native_os == .wasi or native_os == .freestanding) {
        return error.UnsupportedPlatform;
    }
    const identity = posix.uname();
    const release = std.mem.sliceTo(&identity.release, 0);
    if (release.len > storage.len) return error.BufferTooSmall;
    @memcpy(storage[0..release.len], release);
    return storage[0..release.len];
}

pub fn detachPolicy() DetachPolicy {
    return switch (comptime native_os) {
        .linux => .linux_cloexec_process_group,
        else => .unsupported,
    };
}

pub fn spawnDetached(io: anytype, options: DetachOptions) DetachError!Child {
    if (comptime detachPolicy() == .unsupported) return error.UnsupportedPlatform;
    std.debug.assert(options.argv.len != 0);
    try isolateChildDescriptors();
    return try spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

pub fn handoffReap(
    child: *Child,
) ReapHandoffError!void {
    const child_id = child.id orelse
        return error.MissingChildId;
    const reaper = try sys.thread.spawn(
        reapChildId,
        .{child_id},
    );
    child.id = null;
    reaper.detach();
}

fn reapChildId(child_id: Child.Id) void {
    if (comptime native_os == .windows or
        native_os == .wasi)
    {
        return;
    }
    var status: i32 = undefined;
    var child_usage: posix.rusage = undefined;
    while (true) {
        const rc = system.wait4(
            child_id,
            &status,
            0,
            &child_usage,
        );
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn isolateChildDescriptors() DescriptorIsolationError!void {
    return switch (comptime native_os) {
        .linux => isolateChildDescriptorsLinux(),
        .macos => isolateChildDescriptorsDarwin(),
        else => error.UnsupportedPlatform,
    };
}

fn isolateChildDescriptorsLinux() DescriptorIsolationError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const last: linux.fd_t = @bitCast(
        @as(u32, std.math.maxInt(u32)),
    );
    const close_on_exec: linux.CLOSE_RANGE =
        @bitCast(@as(u32, 1 << 2));
    const rc = linux.close_range(3, last, close_on_exec);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOSYS => error.UnsupportedPlatform,
        else => error.DescriptorIsolationFailed,
    };
}

const DescriptorIsolationStatus = enum {
    success,
    absent,
    interrupted,
    failed,
};

const DarwinDescriptorIsolationOperation = struct {
    fn mark(
        _: *@This(),
        descriptor: posix.fd_t,
    ) DescriptorIsolationStatus {
        const flags = system.fcntl(descriptor, posix.F.GETFD, @as(usize, 0));
        const current: usize = switch (posix.errno(flags)) {
            .SUCCESS => @intCast(flags),
            .INTR => return .interrupted,
            .BADF => return .absent,
            else => return .failed,
        };
        const rc = system.fcntl(descriptor, posix.F.SETFD, current | posix.FD_CLOEXEC);
        return switch (posix.errno(rc)) {
            .SUCCESS => .success,
            .INTR => .interrupted,
            .BADF => .absent,
            else => .failed,
        };
    }
};

fn isolateChildDescriptorsDarwin() DescriptorIsolationError!void {
    if (comptime native_os != .macos) return error.UnsupportedPlatform;
    const limit = darwin.getdtablesize();
    if (limit < 3) return error.DescriptorIsolationFailed;
    var operation: DarwinDescriptorIsolationOperation = .{};
    return isolateChildDescriptorsWith(&operation, 3, limit);
}

fn isolateChildDescriptorsWith(
    operation: anytype,
    first: posix.fd_t,
    limit: posix.fd_t,
) DescriptorIsolationError!void {
    std.debug.assert(first >= 0);
    std.debug.assert(limit >= first);
    var descriptor = first;
    while (descriptor < limit) : (descriptor += 1) {
        while (true) switch (operation.mark(descriptor)) {
            .success, .absent => break,
            .interrupted => continue,
            .failed => return error.DescriptorIsolationFailed,
        };
    }
}

const darwin = struct {
    extern "c" fn getdtablesize() c_int;
    extern "c" fn getpgid(process_id: c_int) c_int;
    extern "c" fn waitid(kind: c_uint, id: c_uint, info: *std.c.siginfo_t, flags: c_int) c_int;

    const pid: c_uint = 1;
    const exited: c_int = 0x4;
    const nowait: c_int = 0x20;
};

pub fn processGroupId(process_id: ProcessId) ProcessGroupError!ProcessId {
    if (process_id <= 0) return error.ProcessNotFound;
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => processGroupIdInspected(process_id),
        .posix_host => processGroupIdPosix(process_id),
    };
}

pub fn processAlive(process_id: ProcessId) ProcessGroupError!bool {
    _ = processGroupId(process_id) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn createOwnProcessGroup() ProcessGroupError!void {
    const outcome = if (comptime native_os == .linux)
        linux.errno(linux.setpgid(0, 0))
    else if (comptime native_os == .macos)
        std.c.errno(std.c.setpgid(0, 0))
    else
        return error.UnsupportedPlatform;
    return switch (outcome) {
        .SUCCESS => {},
        .ACCES, .PERM => error.PermissionDenied,
        else => error.UnsupportedPlatform,
    };
}

/// Ensures a descendant whose parent died still reports its exit to the
/// supervisor by making the calling process the Linux child subreaper, so
/// descendants orphaned below it reparent to it and stay reapable. Other
/// targets refuse with `UnsupportedPlatform`.
pub fn becomeChildSubreaper() SubreaperError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return switch (linux.errno(linux.prctl(
        @backingInt(linux.PR.SET_CHILD_SUBREAPER),
        1,
        0,
        0,
        0,
    ))) {
        .SUCCESS => {},
        else => error.SubreaperFailed,
    };
}

pub fn processGroupAlive(group_id: ProcessId) ProcessGroupError!bool {
    if (group_id <= 1) return error.ProcessNotFound;
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => switch (linux.errno(linux.kill(
            -group_id,
            @fromBackingInt(@intCast(0)),
        ))) {
            .SUCCESS => true,
            .SRCH => false,
            .PERM => true,
            else => error.UnsupportedPlatform,
        },
        .posix_host => switch (posix.errno(system.kill(
            -group_id,
            @as(system.SIG, @fromBackingInt(@intCast(0))),
        ))) {
            .SUCCESS, .PERM => true,
            .SRCH => false,
            else => error.UnsupportedPlatform,
        },
    };
}

fn processGroupIdInspected(process_id: ProcessId) ProcessGroupError!ProcessId {
    return sys.process.inspect.group(process_id) catch |err| switch (err) {
        error.ProcessNotFound => error.ProcessNotFound,
        error.PermissionDenied => error.PermissionDenied,
        else => error.UnsupportedPlatform,
    };
}

fn processGroupIdPosix(process_id: ProcessId) ProcessGroupError!ProcessId {
    if (comptime native_os == .windows or native_os == .wasi) return error.UnsupportedPlatform;
    if (comptime native_os == .macos) return processGroupIdInspected(process_id);
    const rc = if (comptime is_darwin)
        darwin.getpgid(process_id)
    else
        system.getpgid(process_id);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .SRCH => error.ProcessNotFound,
        else => error.UnsupportedPlatform,
    };
}

pub fn wait(child: *Child, io: anytype) WaitError!Termination {
    return child.wait(io);
}

pub fn waitDirect(child_id: ProcessId) WaitDirectError!Termination {
    if (comptime native_os == .windows or
        native_os == .wasi or
        native_os == .freestanding)
    {
        return error.UnsupportedPlatform;
    }
    var status: i32 = undefined;
    var child_usage: posix.rusage = undefined;
    while (true) {
        const result = system.wait4(child_id, &status, 0, &child_usage);
        switch (posix.errno(result)) {
            .SUCCESS => return statusToTerm(@bitCast(status)),
            .INTR => continue,
            .CHILD => return error.ChildAlreadyReaped,
            else => return error.ChildWaitFailed,
        }
    }
}

pub fn waitNoHang(child_id: Child.Id) !?WaitNoHangOutcome {
    if (comptime native_os == .windows or native_os == .wasi) return error.UnsupportedPlatform;
    var status: i32 = undefined;
    var child_usage: posix.rusage = undefined;
    const rc = system.wait4(child_id, &status, posix.W.NOHANG, &child_usage);
    return switch (posix.errno(rc)) {
        .SUCCESS => if (rc == 0) null else .{
            .term = statusToTerm(@bitCast(status)),
            .usage = resourceUsage(.wait4_rusage, child_usage),
        },
        .INTR => null,
        else => |err| return posix.unexpectedErrno(err),
    };
}

/// Reaps one exited child of the caller, including a descendant adopted by a
/// child subreaper. The caller must own every child wait in this process and
/// route a returned direct child's outcome to its owner. No ready child, no
/// children, and an interrupted wait all return null.
pub fn waitAnyNoHang() !?WaitAnyNoHangOutcome {
    if (comptime native_os == .windows or
        native_os == .wasi or
        native_os == .freestanding)
    {
        return error.UnsupportedPlatform;
    }
    var status: i32 = undefined;
    var child_usage: posix.rusage = undefined;
    const rc = system.wait4(-1, &status, posix.W.NOHANG, &child_usage);
    return switch (posix.errno(rc)) {
        .SUCCESS => if (rc == 0) null else .{
            .pid = @intCast(rc),
            .outcome = .{
                .term = statusToTerm(@bitCast(status)),
                .usage = resourceUsage(.wait4_rusage, child_usage),
            },
        },
        .INTR, .CHILD => null,
        else => |err| return posix.unexpectedErrno(err),
    };
}

pub fn currentResourceUsage() ResourceUsage {
    if (comptime native_os == .windows or
        native_os == .wasi or
        native_os == .freestanding)
    {
        return .{};
    }
    return resourceUsage(
        .getrusage_self,
        posix.getrusage(posix.rusage.SELF),
    );
}

fn resourceUsage(source: ResourceUsageSource, usage: posix.rusage) ResourceUsage {
    return .{
        .source = source,
        .maxrss_kib = normalizeMaxRss(usage.maxrss, is_darwin),
        .user_s = timevalSeconds(usage.utime),
        .system_s = timevalSeconds(usage.stime),
        .minor_page_faults = linuxResourceCount(usage.minflt),
        .major_page_faults = linuxResourceCount(usage.majflt),
        .voluntary_context_switches = linuxResourceCount(usage.nvcsw),
        .involuntary_context_switches = linuxResourceCount(usage.nivcsw),
    };
}

fn normalizeMaxRss(value: anytype, darwin_units: bool) ?i64 {
    if (value < 0) return null;
    const nonnegative: i64 = @intCast(value);
    return if (darwin_units) @divFloor(nonnegative, 1024) else nonnegative;
}

pub fn peekNoHang(child_id: Child.Id) !?Termination {
    return switch (comptime childPeekPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_waitid => peekLinux(child_id),
        .darwin_waitid => peekDarwin(child_id),
    };
}

fn peekLinux(child_id: Child.Id) !?Termination {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    while (true) {
        const flags = linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT;
        switch (linux.errno(linux.waitid(.PID, child_id, &info, flags, null))) {
            .SUCCESS => {
                if (info.fields.common.first.piduid.pid == 0) return null;
                const status: u32 = @bitCast(
                    info.fields.common.second.sigchld.status,
                );
                const code: linux.CLD = @fromBackingInt(@intCast(info.code));
                return switch (code) {
                    .EXITED => .{ .exited = @truncate(status) },
                    .KILLED, .DUMPED => .{
                        .signal = @fromBackingInt(@intCast(status)),
                    },
                    .TRAPPED, .STOPPED => .{
                        .stopped = @fromBackingInt(@intCast(status)),
                    },
                    _, .CONTINUED => .{ .unknown = status },
                };
            },
            .INTR => return null,
            .CHILD => return error.ProcessNotFound,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn childPeekPolicy() ChildPeekPolicy {
    return switch (native_os) {
        .linux => .linux_waitid,
        .macos => .darwin_waitid,
        else => .unsupported,
    };
}

fn peekDarwin(child_id: Child.Id) !?Termination {
    if (comptime !is_darwin) return error.UnsupportedPlatform;
    var info: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
    const flags = darwin.exited | std.c.W.NOHANG | darwin.nowait;
    switch (posix.errno(darwin.waitid(darwin.pid, @intCast(child_id), &info, flags))) {
        .SUCCESS => {
            if (info.pid == 0) return null;
            const status: u32 = @bitCast(info.status);
            return darwinTermination(info.code, status);
        },
        .INTR => return null,
        .CHILD => return error.ProcessNotFound,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn darwinTermination(code: c_int, status: u32) Termination {
    return switch (code) {
        1 => .{ .exited = @truncate(status) },
        2, 3 => .{ .signal = @fromBackingInt(@intCast(status & 0x7f)) },
        else => .{ .unknown = status },
    };
}

pub fn run(allocator: std.mem.Allocator, io: anytype, options: RunOptions) RunError!RunResult {
    return std.process.run(allocator, io, options);
}

pub fn executableDirPathAlloc(allocator: std.mem.Allocator) ExecutablePathAllocError![]u8 {
    return std.process.executableDirPathAlloc(std.Options.debug_io, allocator);
}

pub fn executablePathAlloc(allocator: std.mem.Allocator) ExecutablePathAllocError![:0]u8 {
    return std.process.executablePathAlloc(std.Options.debug_io, allocator);
}

pub fn exit(code: u8) noreturn {
    std.process.exit(code);
}

pub fn abort() noreturn {
    std.process.abort();
}

pub fn exitCode(term: Termination) i64 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| -@as(i64, @intCast(@backingInt(sig))),
        .stopped => |sig| -@as(i64, @intCast(@backingInt(sig))),
        .unknown => -1,
    };
}

pub fn childSignalPolicy() ChildSignalPolicy {
    return switch (native_os) {
        .windows, .wasi => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
}

pub fn processIdentityPolicy() ProcessIdentityPolicy {
    return switch (native_os) {
        .windows, .wasi, .freestanding => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
}

pub fn signalChildId(child_id: Child.Id, signal: ChildSignal) ChildSignalError!void {
    return switch (comptime childSignalPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => signalChildIdLinux(child_id, signal),
        .posix_host => signalChildIdPosix(child_id, signal),
    };
}

pub fn signalChildGroup(child_id: Child.Id, signal: ChildSignal) ChildSignalError!void {
    return switch (comptime childSignalPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall, .posix_host => signalChildId(-child_id, signal),
    };
}

pub fn currentProcessId() ProcessIdentityError!ProcessId {
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => linux.getpid(),
        .posix_host => currentProcessIdPosix(),
    };
}

pub fn parentProcessId() ProcessIdentityError!ProcessId {
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => linux.getppid(),
        .posix_host => parentProcessIdPosix(),
    };
}

pub fn currentThreadId() ProcessIdentityError!ThreadId {
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => linux.gettid(),
        .posix_host => currentThreadIdPosix(),
    };
}

pub fn currentUserId() ProcessIdentityError!UserId {
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => linux.getuid(),
        .posix_host => currentUserIdPosix(),
    };
}

pub fn currentGroupId() ProcessIdentityError!GroupId {
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => linux.getgid(),
        .posix_host => currentGroupIdPosix(),
    };
}

pub fn effectiveUserId() ProcessIdentityError!UserId {
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => linux.geteuid(),
        .posix_host => effectiveUserIdPosix(),
    };
}

pub fn effectiveGroupId() ProcessIdentityError!GroupId {
    return switch (comptime processIdentityPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => linux.getegid(),
        .posix_host => effectiveGroupIdPosix(),
    };
}

pub fn requestTermination(child: *Child, io: anytype) void {
    if (native_os == .windows or native_os == .wasi) {
        killAndReap(child, io);
        return;
    }

    const child_id = child.id orelse return;
    signalChildId(child_id, .terminate) catch {};
}

pub fn forceKillChildId(child_id: Child.Id) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    signalChildId(child_id, .kill) catch {};
}

pub fn killAndReap(child: *Child, io: anytype) void {
    if (child.id != null) child.kill(io);
}

fn signalChildIdLinux(child_id: Child.Id, signal: ChildSignal) ChildSignalError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return childSignalErrorFromLinuxErrno(linux.errno(linux.kill(child_id, linuxChildSignal(signal))));
}

fn signalChildIdPosix(child_id: Child.Id, signal: ChildSignal) ChildSignalError!void {
    if (comptime native_os == .windows or native_os == .wasi) return error.UnsupportedPlatform;
    posix.kill(child_id, posixChildSignal(signal)) catch |err| switch (err) {
        error.ProcessNotFound => return error.ProcessNotFound,
        error.PermissionDenied => return error.PermissionDenied,
        else => return error.SignalFailed,
    };
}

fn currentProcessIdPosix() ProcessIdentityError!ProcessId {
    if (!@hasDecl(system, "getpid") or @TypeOf(system.getpid) == void) return error.UnsupportedPlatform;
    return @intCast(system.getpid());
}

fn parentProcessIdPosix() ProcessIdentityError!ProcessId {
    if (!@hasDecl(system, "getppid") or @TypeOf(system.getppid) == void) return error.UnsupportedPlatform;
    return @intCast(system.getppid());
}

fn currentThreadIdPosix() ProcessIdentityError!ThreadId {
    if (!@hasDecl(system, "gettid") or @TypeOf(system.gettid) == void) return error.UnsupportedPlatform;
    return @intCast(system.gettid());
}

fn currentUserIdPosix() ProcessIdentityError!UserId {
    if (!@hasDecl(system, "getuid") or @TypeOf(system.getuid) == void) return error.UnsupportedPlatform;
    return @intCast(system.getuid());
}

fn currentGroupIdPosix() ProcessIdentityError!GroupId {
    if (!@hasDecl(system, "getgid") or @TypeOf(system.getgid) == void) return error.UnsupportedPlatform;
    return @intCast(system.getgid());
}

fn effectiveUserIdPosix() ProcessIdentityError!UserId {
    if (!@hasDecl(system, "geteuid") or @TypeOf(system.geteuid) == void) return error.UnsupportedPlatform;
    return @intCast(system.geteuid());
}

fn effectiveGroupIdPosix() ProcessIdentityError!GroupId {
    if (!@hasDecl(system, "getegid") or @TypeOf(system.getegid) == void) return error.UnsupportedPlatform;
    return @intCast(system.getegid());
}

fn statusToTerm(status: u32) Termination {
    return if (posix.W.IFEXITED(status))
        .{ .exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .stopped = posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

fn timevalSeconds(value: @TypeOf(@as(posix.rusage, undefined).utime)) f64 {
    return @as(f64, @floatFromInt(value.sec)) + @as(f64, @floatFromInt(value.usec)) / 1_000_000.0;
}

fn linuxResourceCount(value: anytype) ?u64 {
    if (comptime native_os != .linux) return null;
    return if (value >= 0) @intCast(value) else null;
}

fn linuxChildSignal(signal: ChildSignal) linux.SIG {
    return switch (signal) {
        .terminate => .TERM,
        .kill => .KILL,
        .pause_child => .STOP,
        .resume_child => .CONT,
    };
}

fn posixChildSignal(signal: ChildSignal) posix.SIG {
    return switch (signal) {
        .terminate => .TERM,
        .kill => .KILL,
        .pause_child => .STOP,
        .resume_child => .CONT,
    };
}

fn childSignalErrorFromLinuxErrno(err: linux.E) ChildSignalError!void {
    return switch (err) {
        .SUCCESS => {},
        .INVAL => error.InvalidSignal,
        .PERM => error.PermissionDenied,
        .SRCH => error.ProcessNotFound,
        else => error.SignalFailed,
    };
}

const DescriptorIsolationFixture = struct {
    results: []const DescriptorIsolationStatus,
    descriptors: [8]posix.fd_t = undefined,
    attempts: usize = 0,

    fn mark(self: *@This(), descriptor: posix.fd_t) DescriptorIsolationStatus {
        std.debug.assert(self.attempts < self.results.len);
        std.debug.assert(self.attempts < self.descriptors.len);
        const index = self.attempts;
        self.descriptors[index] = descriptor;
        self.attempts += 1;
        return self.results[index];
    }
};

/// Runs as the child the test forks to prove both settings survive to the exec.
/// The child hands the call a path no file occupies, which fails the exec at
/// the last step and leaves the process alive with both settings applied, then
/// reads both back from the kernel and exits zero when both hold, with a
/// distinct code for each check that fails.
fn stackLimitChild() noreturn {
    const bytes: u64 = 16 * 1024;
    const argv = [_:null]?[*:0]const u8{"/nonexistent/stack-limit-probe"};
    const environment = [_:null]?[*:0]const u8{};
    const failed = execUnderStack(argv[0].?, &argv, &environment, bytes);
    if (failed != error.ExecFailed) linux.exit_group(201);
    var read: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.STACK, &read)) != .SUCCESS) linux.exit_group(202);
    if (read.cur != bytes or read.max != bytes) linux.exit_group(203);
    const persona = linux.syscall1(.personality, 0xffffffff);
    if (persona & persona_no_randomize == 0) linux.exit_group(204);
    linux.exit_group(0);
}

fn padding(offset: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, offset, alignment) - offset;
}

/// Runs as the forked parent: it binds a child that blocks reading the held pipe, reports the
/// child's pid, and exits without waiting for it.
fn boundHost(stdin: posix.fd_t, report: posix.fd_t) noreturn {
    var scratch: [64]u8 = undefined;
    var pointers: [4]?[*:0]const u8 = undefined;
    const argv = [_][]const u8{ "/bin/sh", "-c", "read line" };
    const child = spawnBound(.{
        .argv = &argv,
        .directory = "/",
        .stdin = stdin,
        .scratch = &scratch,
        .pointers = &pointers,
    }) catch linux.exit_group(201);
    var bytes: [@sizeOf(ProcessId)]u8 = undefined;
    std.mem.writeInt(ProcessId, &bytes, child.id.?, .little);
    if (linux.write(report, &bytes, bytes.len) != bytes.len) linux.exit_group(202);
    linux.exit_group(0);
}

fn testDeadline() i128 {
    return sys.time.nanoTimestamp() + 5 * std.time.ns_per_s;
}

/// Forks a child that stands in for one between its clone and its exec: it
/// claims the exec when `claims` is set, then waits to be killed.
fn stalledStart(claims: bool) !IntoStarted {
    const pipe = try intoPipe();
    const claim_page = try sys.memory.mapSharedAnonymous(@sizeOf(u32), .{ .read = true, .write = true });
    const claim: *u32 = @ptrCast(claim_page.ptr);
    claim.* = claim_open;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        if (claims) _ = @cmpxchgStrong(u32, claim, claim_open, claim_exec, .seq_cst, .seq_cst);
        while (true) _ = linux.pause();
    }
    _ = linux.close(pipe[1]);
    // The parent waits for the claim, as a real exec would follow it.
    if (claims) while (@atomicLoad(u32, claim, .seq_cst) != claim_exec) sys.time.sleepNanoseconds(std.time.ns_per_ms);
    return .{ .pid = @intCast(pid), .failure = pipe[0], .claim = claim, .stdin = null, .stdout = null, .stderr = null };
}

/// Opens the test process's own control group, which accepts a child when the
/// host runs the unified hierarchy and the group is a leaf. Null elsewhere.
fn ownGroupForTest() ?sys.cgroup.Group {
    var storage: [sys.cgroup.membership_bytes_max]u8 = undefined;
    const path = switch (sys.cgroup.membership(&storage) catch return null) {
        .unified => |value| value,
        .none => return null,
    };
    var joined: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = std.fmt.bufPrint(&joined, "{s}{s}", .{ sys.cgroup.mount_point, path }) catch
        return null;
    return sys.cgroup.Group.open(absolute) catch null;
}

// dash clears its signal mask at startup and blocks every signal around each
// vfork, so the mask is read by a direct exec of grep instead (see
// `mask_probe`).
const into_probe =
    \\echo "cwd $(pwd -P)"
    \\echo "pgid $(/usr/bin/cut -d' ' -f5 /proc/$$/stat) self $$"
    \\for f in /proc/$$/fd/*; do printf 'fd %s %s\n' "${f##*/}" "$(/usr/bin/readlink "$f" | /usr/bin/sed 's/:\[.*//')"; done
    \\/usr/bin/env | LC_ALL=C /usr/bin/sort
;

/// grep leaves its signal mask and dispositions as exec left them.
const mask_probe = [_][]const u8{ "/usr/bin/grep", "-E", "^(SigBlk|SigIgn|SigCgt):", "/proc/self/status" };

const IntoOutcome = union(enum) {
    output: []const u8,
    failure: anyerror,
};

/// Runs one spawn and returns its output. For the shell probe it first checks
/// that the child leads its own process group, then blanks the child's pid,
/// the one line two children cannot share.
fn runIntoCase(
    io: std.Io,
    group: ?posix.fd_t,
    options: SpawnOptions,
    storage: []u8,
) !IntoOutcome {
    var child = (if (group) |descriptor|
        spawnInto(io, std.testing.allocator, options, descriptor, testDeadline())
    else
        spawn(io, options)) catch |err| return .{ .failure = err };
    defer killAndReap(&child, io);
    var count: usize = 0;
    while (true) {
        if (count == storage.len) return error.ProbeOutputTooLarge;
        const rc = linux.read(child.stdout.?.handle, storage[count..].ptr, storage.len - count);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) break else {
                count += rc;
            },
            .INTR => continue,
            else => return error.ProbeReadFailed,
        }
    }
    const term = try child.wait(io);
    child.id = null;
    try std.testing.expectEqual(Termination{ .exited = 0 }, term);
    const output = storage[0..count];
    if (options.argv.ptr == &mask_probe) return .{ .output = output };
    const self_at = std.mem.indexOf(u8, output, " self ") orelse return error.ProbeShape;
    const line_end = std.mem.indexOfScalarPos(u8, output, self_at, '\n') orelse return error.ProbeShape;
    const pgid_at = std.mem.lastIndexOf(u8, output[0..self_at], "pgid ") orelse return error.ProbeShape;
    try std.testing.expectEqualStrings(
        output[self_at + " self ".len .. line_end],
        output[pgid_at + "pgid ".len .. self_at],
    );
    @memset(output[pgid_at..line_end], '_');
    return .{ .output = output };
}

const IntoCase = struct {
    name: []const u8,
    argv: []const []const u8,
    /// The parent's PATH, which resolves `argv[0]`.
    parent_path: [:0]const u8,
    /// The child map's PATH, or no map at all: the child then gets the
    /// parent's environment.
    child_path: ?[]const u8 = "/nonexistent-child-path",
    stdin: SpawnOptions.StdIo = .ignore,
    /// The probe must fail with this error through both spawns.
    expected: ?anyerror = null,
};
