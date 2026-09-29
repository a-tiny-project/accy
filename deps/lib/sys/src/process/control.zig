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
        .hardware_capabilities => std.elf.AT_HWCAP,
        .hardware_capabilities_2 => std.elf.AT_HWCAP2,
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

test "process waitid Darwin status preserves termination across extended exit bits" {
    try std.testing.expectEqual(
        Termination{ .exited = 143 },
        darwinTermination(1, 0xff00008f),
    );
    try std.testing.expectEqual(
        Termination{ .signal = .KILL },
        darwinTermination(2, 0xff000009),
    );
    try std.testing.expectEqual(
        Termination{ .signal = .TERM },
        darwinTermination(3, 0xff00000f),
    );
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

test "descriptor isolation scans a bounded range and retries interruptions" {
    const results = [_]DescriptorIsolationStatus{
        .absent,
        .interrupted,
        .success,
        .success,
    };
    var operation: DescriptorIsolationFixture = .{ .results = &results };
    try isolateChildDescriptorsWith(&operation, 3, 6);
    const expected = [_]posix.fd_t{ 3, 4, 4, 5 };
    try std.testing.expectEqualSlices(
        posix.fd_t,
        &expected,
        operation.descriptors[0..operation.attempts],
    );
}

test "descriptor isolation maps operation failure" {
    const results = [_]DescriptorIsolationStatus{.failed};
    var operation: DescriptorIsolationFixture = .{ .results = &results };
    try std.testing.expectError(
        error.DescriptorIsolationFailed,
        isolateChildDescriptorsWith(&operation, 3, 4),
    );
}

test "exec under stack sets the limit and the persona before it execs" {
    if (comptime native_os != .linux) return error.SkipZigTest;
    const fork_result = linux.fork();
    if (linux.errno(fork_result) != .SUCCESS) return error.StackLimitForkFailed;
    if (fork_result == 0) stackLimitChild();

    var status: i32 = undefined;
    while (true) {
        const wait_result = linux.wait4(@intCast(fork_result), &status, 0, null);
        switch (linux.errno(wait_result)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.StackLimitWaitFailed,
        }
    }
    const decoded: u32 = @bitCast(status);
    try std.testing.expect(linux.W.IFEXITED(decoded));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(decoded));
}

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

test "process note walk finds the GNU build-id past other notes at either alignment" {
    for ([_]usize{ 4, 8 }) |alignment| {
        var segment: [96]u8 = @splat(0);
        var writer = std.Io.Writer.fixed(&segment);
        const Entry = struct { name: []const u8, kind: u32, descriptor: []const u8 };
        const build_id = std.elf.NT_GNU_BUILD_ID;
        const entries = [_]Entry{
            .{ .name = "GNU\x00", .kind = 5, .descriptor = "property" },
            .{ .name = "Go\x00\x00", .kind = build_id, .descriptor = "other" },
            .{ .name = "GNU\x00", .kind = build_id, .descriptor = "0123456789abcdefghij" },
        };
        for (entries) |entry| {
            try writer.writeInt(u32, @intCast(entry.name.len), .little);
            try writer.writeInt(u32, @intCast(entry.descriptor.len), .little);
            try writer.writeInt(u32, entry.kind, .little);
            try writer.writeAll(entry.name);
            try writer.splatByteAll(0, padding(writer.end, alignment));
            try writer.writeAll(entry.descriptor);
            try writer.splatByteAll(0, padding(writer.end, alignment));
        }
        const used = segment[0..writer.end];
        try std.testing.expectEqualStrings(
            "0123456789abcdefghij",
            noteDescriptor(used, alignment, build_id).?,
        );
        const past_padding = used[0 .. used.len - 5];
        try std.testing.expectEqual(null, noteDescriptor(past_padding, alignment, build_id));
        try std.testing.expectEqual(null, noteDescriptor(used, alignment, 99));
    }
}

fn padding(offset: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, offset, alignment) - offset;
}

test "process build-id reads the running image without failing" {
    if (native_os != .linux) return error.SkipZigTest;
    if (try buildId()) |id| try std.testing.expect(id.len != 0);
}

test "process policy exports child type" {
    try std.testing.expect(Child == std.process.Child);
}

test "process exitCode maps termination records" {
    try std.testing.expectEqual(@as(i64, 7), exitCode(.{ .exited = 7 }));
    try std.testing.expectEqual(@as(i64, -1), exitCode(.{ .unknown = 42 }));
}

test "process resource counts are explicit Linux wait accounting" {
    const expected: ?u64 = if (native_os == .linux) 7 else null;
    try std.testing.expectEqual(expected, linuxResourceCount(@as(isize, 7)));
    try std.testing.expectEqual(@as(?u64, null), linuxResourceCount(@as(isize, -1)));
}

test "process current resource usage names its accounting source" {
    const usage = currentResourceUsage();
    const expected: ?ResourceUsageSource = switch (native_os) {
        .windows, .wasi, .freestanding => null,
        else => .getrusage_self,
    };
    try std.testing.expectEqual(expected, usage.source);
    if (usage.source != null) {
        try std.testing.expect(usage.maxrss_kib.? > 0);
        try std.testing.expect(usage.user_s.? >= 0);
        try std.testing.expect(usage.system_s.? >= 0);
    }
}

test "process peak rss normalizes Darwin bytes to kibibytes" {
    try std.testing.expectEqual(@as(?i64, 714_208), normalizeMaxRss(731_348_992, true));
    try std.testing.expectEqual(@as(?i64, 731_348_992), normalizeMaxRss(731_348_992, false));
    try std.testing.expectEqual(@as(?i64, null), normalizeMaxRss(-1, true));
}

test "process child signal policy is explicit" {
    const expected: ChildSignalPolicy = switch (native_os) {
        .windows, .wasi => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
    try std.testing.expectEqual(expected, childSignalPolicy());
}

test "process child signals cover supervisor lifecycle actions" {
    if (comptime native_os == .linux) {
        try std.testing.expectEqual(linux.SIG.STOP, linuxChildSignal(.pause_child));
        try std.testing.expectEqual(linux.SIG.CONT, linuxChildSignal(.resume_child));
    }
    if (comptime native_os != .windows and native_os != .wasi) {
        try std.testing.expectEqual(posix.SIG.STOP, posixChildSignal(.pause_child));
        try std.testing.expectEqual(posix.SIG.CONT, posixChildSignal(.resume_child));
    }
}

test "process identity policy is explicit" {
    const expected: ProcessIdentityPolicy = switch (native_os) {
        .windows, .wasi, .freestanding => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
    try std.testing.expectEqual(expected, processIdentityPolicy());
}

test "process child signal errno mapping is explicit" {
    if (comptime native_os != .linux) return;
    try childSignalErrorFromLinuxErrno(.SUCCESS);
    try std.testing.expectError(error.InvalidSignal, childSignalErrorFromLinuxErrno(.INVAL));
    try std.testing.expectError(error.PermissionDenied, childSignalErrorFromLinuxErrno(.PERM));
    try std.testing.expectError(error.ProcessNotFound, childSignalErrorFromLinuxErrno(.SRCH));
    try std.testing.expectError(error.SignalFailed, childSignalErrorFromLinuxErrno(.IO));
}

test "process identity values are queryable" {
    if (processIdentityPolicy() == .unsupported) return error.SkipZigTest;

    try std.testing.expect(try currentProcessId() > 0);
    _ = try parentProcessId();
    _ = try currentUserId();
    _ = try currentGroupId();
    _ = try effectiveUserId();
    _ = try effectiveGroupId();
    if (comptime native_os == .linux) try std.testing.expect(try currentThreadId() > 0);
}

test "process executableDirPathAlloc returns a non-empty path" {
    const path = try executableDirPathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(path.len > 0);
}

test "process detach policy is explicit" {
    const expected: DetachPolicy = switch (comptime native_os) {
        .linux => .linux_cloexec_process_group,
        else => .unsupported,
    };
    try std.testing.expectEqual(expected, detachPolicy());
}

test "detached spawn leads its own process group and leaves no stdio pipe" {
    const testing = std.testing;
    if (comptime detachPolicy() == .unsupported) return error.SkipZigTest;
    var io_state = std.Io.Threaded.init(testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    var child = try spawnDetached(io, .{
        .argv = &.{ "sh", "-c", "read line; exit 0" },
    });
    var reaped = false;
    defer if (!reaped) killAndReap(&child, io);
    const child_id = child.id orelse return error.MissingChildId;

    try testing.expect(child.stdin == null);
    try testing.expect(child.stdout == null);
    try testing.expect(child.stderr == null);
    try testing.expectEqual(child_id, try processGroupId(child_id));
    try testing.expect(try processGroupId(child_id) !=
        try processGroupId(try currentProcessId()));
    try testing.expect(try processAlive(child_id));

    forceKillChildId(child_id);
    _ = try wait(&child, io);
    reaped = true;
}

test "detached spawn excludes an exact inherited descriptor" {
    const testing = std.testing;
    if (comptime native_os != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var identity_buffer: [64]u8 = undefined;
    const identity = try std.fmt.bufPrint(
        &identity_buffer,
        "tiny-detach-{s}",
        .{tmp.sub_path},
    );
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "probe",
        .data = identity,
    });
    const probe = try posix.openat(
        tmp.dir.handle,
        "probe",
        .{},
        0,
    );
    defer _ = linux.close(probe);
    const before = linux.fcntl(probe, linux.F.GETFD, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(before));
    try testing.expect(before & linux.FD_CLOEXEC == 0);

    var script_buffer: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "test \"$(cat /proc/self/fd/{d} 2>/dev/null)\" != '{s}'",
        .{ probe, identity },
    );
    var io_state = std.Io.Threaded.init(testing.allocator, .{});
    defer io_state.deinit();
    var child = try spawnDetached(io_state.io(), .{
        .argv = &.{ "/bin/sh", "-c", script },
    });
    var reaped = false;
    defer if (!reaped) killAndReap(&child, io_state.io());
    const term = try wait(&child, io_state.io());
    reaped = true;
    try testing.expectEqual(@as(i64, 0), exitCode(term));
    const after = linux.fcntl(probe, linux.F.GETFD, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(after));
    try testing.expect(after & linux.FD_CLOEXEC != 0);
    const seek = linux.lseek(probe, 0, linux.SEEK.SET);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(seek));
    var read_buffer: [identity_buffer.len]u8 = undefined;
    const read = linux.read(probe, &read_buffer, read_buffer.len);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(read));
    try testing.expectEqualStrings(
        identity,
        read_buffer[0..read],
    );
}

test "detached child transfers exact reaping ownership" {
    const testing = std.testing;
    if (comptime detachPolicy() == .unsupported) {
        return error.SkipZigTest;
    }
    var io_state = std.Io.Threaded.init(
        testing.allocator,
        .{},
    );
    defer io_state.deinit();
    var child = try spawnDetached(io_state.io(), .{
        .argv = &.{ "sh", "-c", "exit 0" },
    });
    var child_owned = true;
    defer if (child_owned) killAndReap(
        &child,
        io_state.io(),
    );
    const child_id = child.id orelse
        return error.MissingChildId;
    try handoffReap(&child);
    child_owned = false;
    try testing.expect(child.id == null);
    const deadline = (try sys.time.awakeNow()).deadlineAfter(.fromMilliseconds(1_000));
    while (try processAlive(child_id)) {
        if ((try sys.time.awakeNow()).reached(deadline)) {
            return error.DetachedChildNotReaped;
        }
        sys.time.sleepMilliseconds(1);
    }
}

test "process wait deadline ignores wall jumps and suspend gaps" {
    var clock = sys.time.FakeClock.zero();
    const deadline = clock.awake.deadlineAfter(.fromMilliseconds(10));
    clock.setWall(.fromNanoseconds(std.math.maxInt(u64)));
    clock.suspendGap(.fromMilliseconds(20));
    try std.testing.expect(!clock.awake.reached(deadline));
    clock.advance(.fromMilliseconds(10));
    try std.testing.expect(clock.awake.reached(deadline));
}

test "process group lookup rejects absent and invalid identities" {
    const testing = std.testing;
    if (comptime processIdentityPolicy() == .unsupported) return error.SkipZigTest;
    try testing.expectError(error.ProcessNotFound, processGroupId(0));
    try testing.expectError(error.ProcessNotFound, processGroupId(-1));
    try testing.expect(!try processAlive(0));
    try testing.expect(try processAlive(try currentProcessId()));
}

test "bound spawn ends the child when the parent that started it dies" {
    if (comptime native_os != .linux) return error.SkipZigTest;
    const inspect = sys.process.inspect;
    var hold: [2]posix.fd_t = undefined;
    if (linux.errno(linux.pipe2(&hold, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    defer closeBoundPipe(hold);
    var report: [2]posix.fd_t = undefined;
    const piped = linux.pipe2(&report, .{ .CLOEXEC = true });
    if (linux.errno(piped) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(report[0]);
    const host = linux.fork();
    if (linux.errno(host) != .SUCCESS) {
        _ = linux.close(report[1]);
        return error.HostForkFailed;
    }
    if (host == 0) boundHost(hold[0], report[1]);
    _ = linux.close(report[1]);
    var bytes: [@sizeOf(ProcessId)]u8 = undefined;
    const length = linux.read(report[0], &bytes, bytes.len);
    const host_exit = sys.process.exitCode(try waitDirect(@intCast(host)));
    try std.testing.expectEqual(@as(i64, 0), host_exit);
    try std.testing.expectEqual(bytes.len, length);
    const child = std.mem.readInt(ProcessId, &bytes, .little);
    // The orphan is killed and then reaped by whichever process adopts it.
    for (0..5_000) |_| {
        const observed = inspect.info(child) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        if (!observed.alive) break;
        sys.time.sleepMilliseconds(1);
    } else {
        _ = linux.kill(child, .KILL);
        return error.ChildSurvivedParent;
    }
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

test "bound spawn refuses scratch that cannot hold its arguments" {
    if (comptime native_os != .linux) return error.SkipZigTest;
    var scratch: [4]u8 = undefined;
    var pointers: [4]?[*:0]const u8 = undefined;
    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 0" };
    try std.testing.expectError(error.ScratchTooSmall, spawnBound(.{
        .argv = &argv,
        .directory = "/",
        .stdin = 0,
        .scratch = &scratch,
        .pointers = &pointers,
    }));
    var wide: [64]u8 = undefined;
    try std.testing.expectError(error.ScratchTooSmall, spawnBound(.{
        .argv = &argv,
        .directory = "/",
        .stdin = 0,
        .scratch = &wide,
        .pointers = pointers[0..3],
    }));
    const nul = [_][]const u8{"/bin/\x00sh"};
    try std.testing.expectError(error.InvalidArgument, spawnBound(.{
        .argv = &nul,
        .directory = "/",
        .stdin = 0,
        .scratch = &wide,
        .pointers = &pointers,
    }));
}
