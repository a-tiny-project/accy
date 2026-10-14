const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const fd = @import("fd.zig");

const debug_io = std.Options.debug_io;
const linux = std.os.linux;
const native_os = builtin.os.tag;
const posix = std.posix;

pub const required_capabilities = capabilities.host(&.{.filesystem});

pub const Dir = std.Io.Dir;
pub const CwdError = std.process.CurrentPathAllocError;
pub const ReadFileError = std.Io.Dir.ReadFileAllocError;
pub const WriteFileError = std.Io.Dir.WriteFileError;
pub const AppendFileError = std.Io.File.OpenError || std.Io.File.StatError || std.Io.File.Writer.SeekError || std.Io.Writer.Error;
pub const AppendFileSyncError = AppendFileError || std.Io.File.SyncError;
pub const SyncFilesystemError = std.Io.File.SyncError;
pub const ExistsError = std.Io.Dir.StatFileError;
pub const AccessOptions = std.Io.Dir.AccessOptions;
pub const AccessError = std.Io.Dir.AccessError;
pub const OpenFileError = std.Io.File.OpenError;
pub const OpenFileOptions = std.Io.Dir.OpenFileOptions;
pub const OpenRegularFileError = std.posix.OpenError ||
    std.Io.File.StatError ||
    error{ UnsupportedPlatform, NotRegularFile };
pub const OpenDirError = std.Io.Dir.OpenError;
pub const OpenDirOptions = std.Io.Dir.OpenOptions;
pub const ReadHandleError = std.posix.ReadError;
pub const CreateFileOptions = std.Io.Dir.CreateFileOptions;
pub const CreateDirPathError = std.Io.Dir.CreateDirPathError;
pub const DeleteFileError = std.Io.Dir.DeleteFileError;
pub const DeleteTreeError = std.Io.Dir.DeleteTreeError;
pub const FilePermissions = std.Io.File.Permissions;
pub const SetFilePermissionsOptions = std.Io.Dir.SetFilePermissionsOptions;
pub const SetFilePermissionsError = std.Io.Dir.SetFilePermissionsError;
pub const RenameError = std.Io.Dir.RenameError;
pub const ExchangeError = error{
    FileNotFound,
    AccessDenied,
    ExchangeUnsupported,
} || posix.UnexpectedError;
pub const RealPathError = std.Io.Dir.RealPathFileAllocError;
pub const ListDirError = std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error || std.mem.Allocator.Error;
pub const FileOwnerUserId = linux.uid_t;
pub const FileMode = posix.mode_t;
pub const WatchEvent = linux.inotify_event;

pub const NamedPipeError = error{
    UnsupportedPlatform,
    AccessDenied,
    CreateFailed,
};
pub const AnonymousFileError = error{
    UnsupportedPlatform,
    OutOfMemory,
    CreateFailed,
};
pub const TruncateError = error{
    UnsupportedPlatform,
    OutOfMemory,
    TruncateFailed,
};
pub const WatchError = error{
    UnsupportedPlatform,
    WatchFailed,
};

pub const WatchMask = struct {
    pub const close_write = linux.IN.CLOSE_WRITE;
    pub const create = linux.IN.CREATE;
    pub const delete = linux.IN.DELETE;
    pub const delete_self = linux.IN.DELETE_SELF;
    pub const ignored = linux.IN.IGNORED;
    pub const moved_from = linux.IN.MOVED_FROM;
    pub const moved_to = linux.IN.MOVED_TO;
    pub const move_self = linux.IN.MOVE_SELF;
    pub const queue_overflow = linux.IN.Q_OVERFLOW;
    pub const unmount = linux.IN.UNMOUNT;
};

pub const FileOwnerPolicy = enum {
    unsupported,
    linux_statx,
};

pub const AllocatedBlocksUnsupported = enum {
    platform,
    statx_unavailable,
};

pub const AllocatedBlocks = union(enum) {
    supported: u64,
    unsupported: AllocatedBlocksUnsupported,
};

pub const FileOwnerError = error{
    UnsupportedPlatform,
    BadPathName,
    NameTooLong,
    AccessDenied,
    FileNotFound,
    NotDir,
    SymLinkLoop,
    SystemResources,
    OwnerUnavailable,
};

pub const EntryKind = enum {
    file,
    directory,
    sym_link,
    other,
};

pub const Entry = struct {
    name: []u8,
    kind: EntryKind,
    path: []u8,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const OpenedRegularFile = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
};

pub fn debugIo() std.Io {
    return debug_io;
}

pub fn cwd() Dir {
    return Dir.cwd();
}

pub fn cwdAlloc(allocator: std.mem.Allocator) CwdError![]u8 {
    const path_z = try std.process.currentPathAlloc(debug_io, allocator);
    defer allocator.free(path_z);
    return try allocator.dupe(u8, path_z);
}

pub fn setCreationMask(mask: FileMode) error{UnsupportedPlatform}!FileMode {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return @intCast(linux.syscall1(.umask, mask));
}

pub fn createNamedPipe(
    directory: Dir,
    name: [:0]const u8,
    mode: FileMode,
) NamedPipeError!void {
    const result = switch (native_os) {
        .linux => linux.mknodat(directory.handle, name.ptr, linux.S.IFIFO | mode, 0),
        .macos => darwin.mkfifoat(directory.handle, name.ptr, mode),
        else => return error.UnsupportedPlatform,
    };
    return switch (posix.errno(result)) {
        .SUCCESS => {},
        .ACCES, .PERM => error.AccessDenied,
        else => error.CreateFailed,
    };
}

pub fn createAnonymousFile(name: []const u8) AnonymousFileError!fd.Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return posix.memfd_create(name, posix.MFD.CLOEXEC) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CreateFailed,
    };
}

/// Creates a Linux memory file that allows seals and carries none yet, for a
/// caller that will later seal the file because sealing has to be allowed at
/// creation. Bytes go in before the seals, because the immutable check requires
/// the seals to be present. The descriptor is close-on-exec, and the caller
/// closes it, while a host other than Linux returns `UnsupportedPlatform`.
pub fn createSealableFile(name: []const u8) AnonymousFileError!fd.Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return posix.memfd_create(name, posix.MFD.CLOEXEC | posix.MFD.ALLOW_SEALING) catch |err|
        switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CreateFailed,
        };
}

/// Seals a populated file so that every later mapping of it sees the same
/// bytes, adding the write, shrink, and grow seals, which stop mutation of the
/// file through any descriptor. The seals are read back before the call
/// returns, so a return means they are in place, while every failure, including
/// a host other than Linux, reports `UnsupportedImageBacking`.
pub fn sealFile(descriptor: fd.Descriptor) error{UnsupportedImageBacking}!void {
    if (comptime native_os != .linux) return error.UnsupportedImageBacking;
    const seals = linux.F.SEAL_WRITE | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW;
    if (posix.errno(linux.fcntl(descriptor, linux.F.ADD_SEALS, seals)) != .SUCCESS) {
        return error.UnsupportedImageBacking;
    }
    try requireImmutableFile(descriptor);
}

/// Admits a descriptor for an immutable mapping only when the Linux write,
/// shrink, and grow seals are all present, so a mutable ordinary file returns
/// `UnsupportedImageBacking`. Read-only permissions, a matching digest, and a
/// private mapping do not qualify a file on their own.
pub fn requireImmutableFile(descriptor: fd.Descriptor) error{UnsupportedImageBacking}!void {
    if (comptime native_os != .linux) return error.UnsupportedImageBacking;
    const required = linux.F.SEAL_WRITE | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW;
    const actual = linux.fcntl(descriptor, linux.F.GET_SEALS, 0);
    if (posix.errno(actual) != .SUCCESS or actual & required != required) {
        return error.UnsupportedImageBacking;
    }
}

pub fn truncateDescriptor(
    descriptor: fd.Descriptor,
    byte_len: usize,
) TruncateError!void {
    switch (comptime native_os) {
        .linux => {
            var operation: LinuxTruncateOperation = .{};
            return truncateDescriptorWith(&operation, descriptor, byte_len);
        },
        .macos => {
            var operation: DarwinTruncateOperation = .{};
            return truncateDescriptorWith(&operation, descriptor, byte_len);
        },
        else => return error.UnsupportedPlatform,
    }
}

pub fn createWatch() WatchError!fd.Descriptor {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const result = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.WatchFailed,
    };
}

pub fn addWatch(
    descriptor: fd.Descriptor,
    path: [:0]const u8,
    mask: u32,
) WatchError!i32 {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const result = linux.inotify_add_watch(descriptor, path.ptr, mask);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.WatchFailed,
    };
}

pub fn removeWatch(descriptor: fd.Descriptor, watch: i32) WatchError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return switch (linux.errno(linux.inotify_rm_watch(descriptor, watch))) {
        .SUCCESS => {},
        else => error.WatchFailed,
    };
}

pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) ReadFileError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(debug_io, path, allocator, .limited(limit));
}

pub fn writeFile(path: []const u8, contents: []const u8) WriteFileError!void {
    try std.Io.Dir.cwd().writeFile(debug_io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

pub fn createFile(path: []const u8, options: CreateFileOptions) OpenFileError!std.Io.File {
    return try std.Io.Dir.cwd().createFile(debug_io, path, options);
}

pub fn openAbsoluteFile(path: []const u8, options: OpenFileOptions) OpenFileError!std.Io.File {
    return try std.Io.Dir.openFileAbsolute(debug_io, path, options);
}

pub fn openAbsoluteDir(path: []const u8, options: OpenDirOptions) OpenDirError!Dir {
    return try std.Io.Dir.openDirAbsolute(debug_io, path, options);
}

pub fn openRegularFile(
    io: std.Io,
    directory: Dir,
    path: []const u8,
) OpenRegularFileError!OpenedRegularFile {
    if (comptime native_os != .linux and native_os != .macos) {
        return error.UnsupportedPlatform;
    }
    const descriptor = std.posix.openat(directory.handle, path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0) catch |err| switch (err) {
        error.SymLinkLoop => return error.NotRegularFile,
        else => |other| return other,
    };
    var file = std.Io.File{
        .handle = descriptor,
        .flags = .{ .nonblocking = true },
    };
    errdefer file.close(io);
    const stat = file.stat(io) catch |err| switch (err) {
        error.Streaming => return error.NotRegularFile,
        else => |other| return other,
    };
    if (stat.kind != .file) return error.NotRegularFile;
    return .{ .file = file, .stat = stat };
}

pub fn readHandle(file: std.Io.File, buffer: []u8) ReadHandleError!usize {
    return try std.posix.read(file.handle, buffer);
}

pub fn readHandleAt(file: std.Io.File, buffer: []u8, offset: u64) !usize {
    return file.readPositionalAll(debug_io, buffer, offset);
}

pub fn readHandleToEndAlloc(allocator: std.mem.Allocator, file: std.Io.File, limit: usize) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(debug_io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

pub fn writeHandleAll(file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(debug_io, bytes);
}

pub fn writeHandleAt(file: std.Io.File, bytes: []const u8, offset: u64) !void {
    try file.writePositionalAll(debug_io, bytes, offset);
}

pub fn closeHandle(file: std.Io.File) void {
    file.close(debug_io);
}

/// Flushes the open file's dirty data pages to the storage device before a
/// caller reports written records durable, so that the records can be found
/// again after a crash. Surviving a power loss still depends on the device's
/// own caches and on its support for the flush command, so a return carries no
/// unconditional hardware guarantee. Linux uses `fdatasync`, which leaves
/// unchanged metadata alone. Darwin uses `F_FULLFSYNC` to flush the file and
/// request the device-cache flush that plain `fsync` does not provide.
/// Unsupported hosts refuse with `error.Unexpected`.
pub fn syncData(file: std.Io.File) std.posix.SyncError!void {
    if (comptime builtin.os.tag == .linux) return std.posix.fdatasync(file.handle);
    if (comptime builtin.os.tag.isDarwin()) return syncDarwinData(file);
    return error.Unexpected;
}

fn syncDarwinData(file: std.Io.File) std.posix.SyncError!void {
    // Signals can interrupt the flush repeatedly. Each retry preserves the
    // same descriptor and barrier, with constant storage and no weaker fallback.
    while (true) switch (std.posix.errno(std.c.fcntl(
        file.handle,
        std.c.F.FULLFSYNC,
        @as(c_int, 0),
    ))) {
        .SUCCESS => return,
        .INTR => {},
        .BADF => unreachable,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .DQUOT => return error.DiskQuota,
        .ACCES, .PERM => return error.AccessDenied,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

pub fn syncFilesystem(file: std.Io.File) SyncFilesystemError!void {
    if (comptime builtin.os.tag == .linux) return std.posix.syncfs(file.handle);
    if (comptime builtin.os.tag.isDarwin()) return syncDarwinFilesystem(file);
    if (comptime builtin.os.tag == .windows) return;
    return file.sync(debug_io);
}

fn syncDarwinFilesystem(file: std.Io.File) SyncFilesystemError!void {
    while (true) switch (@as(std.posix.E, @fromBackingInt(@intCast(darwin.fsync_volume_np(
        file.handle,
        darwin.sync_volume_wait,
    ))))) {
        .SUCCESS => return,
        .INTR => {},
        .BADF, .INVAL, .ROFS => unreachable,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .DQUOT => return error.DiskQuota,
        .ACCES, .PERM => return error.AccessDenied,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

const darwin = struct {
    const sync_volume_wait = 0x02;

    extern "c" fn fsync_volume_np(fd: std.posix.fd_t, flags: c_int) c_int;
    extern "c" fn ftruncate(fd: std.posix.fd_t, length: std.posix.off_t) c_int;
    extern "c" fn mkfifoat(
        fd: std.posix.fd_t,
        path: [*:0]const u8,
        mode: std.posix.mode_t,
    ) c_int;
};

pub fn appendFile(path: []const u8, chunks: []const []const u8) AppendFileError!void {
    var file = try std.Io.Dir.cwd().createFile(debug_io, path, .{
        .truncate = false,
        .read = false,
    });
    defer file.close(debug_io);

    const stat = try file.stat(debug_io);
    var write_buffer: [1024]u8 = undefined;
    var writer = file.writer(debug_io, &write_buffer);
    try writer.seekTo(stat.size);
    for (chunks) |chunk| try writer.interface.writeAll(chunk);
    try writer.interface.flush();
}

pub fn appendFileSync(path: []const u8, chunks: []const []const u8) AppendFileSyncError!void {
    var file = try std.Io.Dir.cwd().createFile(debug_io, path, .{
        .truncate = false,
        .read = false,
    });
    defer file.close(debug_io);

    const stat = try file.stat(debug_io);
    var write_buffer: [1024]u8 = undefined;
    var writer = file.writer(debug_io, &write_buffer);
    try writer.seekTo(stat.size);
    for (chunks) |chunk| try writer.interface.writeAll(chunk);
    try writer.interface.flush();
    try file.sync(debug_io);
}

pub fn exists(path: []const u8) bool {
    _ = statFile(path) catch return false;
    return true;
}

pub fn accessAbsolute(path: []const u8, options: AccessOptions) AccessError!void {
    try std.Io.Dir.accessAbsolute(debug_io, path, options);
}

pub fn absolutePathExists(path: []const u8) bool {
    accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn statFile(path: []const u8) ExistsError!std.Io.Dir.Stat {
    return std.Io.Dir.cwd().statFile(debug_io, path, .{});
}

pub fn allocatedBlocks(file: std.Io.File) AllocatedBlocks {
    return switch (comptime native_os) {
        .linux => allocatedBlocksLinux(file),
        else => .{ .unsupported = .platform },
    };
}

fn allocatedBlocksLinux(file: std.Io.File) AllocatedBlocks {
    while (true) {
        var statx = std.mem.zeroes(linux.Statx);
        const rc = linux.statx(
            file.handle,
            "",
            linux.AT.EMPTY_PATH,
            .{ .BLOCKS = true },
            &statx,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => return if (statx.mask.BLOCKS)
                .{ .supported = statx.blocks }
            else
                .{ .unsupported = .statx_unavailable },
            .INTR => {},
            .BADF => unreachable,
            else => return .{ .unsupported = .statx_unavailable },
        }
    }
}

pub fn fileOwnerPolicy() FileOwnerPolicy {
    return switch (native_os) {
        .linux => .linux_statx,
        else => .unsupported,
    };
}

pub fn fileOwnerUserId(
    path: []const u8,
) FileOwnerError!FileOwnerUserId {
    return switch (comptime fileOwnerPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_statx => fileOwnerUserIdLinux(path),
    };
}

fn fileOwnerUserIdLinux(
    path: []const u8,
) FileOwnerError!FileOwnerUserId {
    if (comptime native_os != .linux) {
        return error.UnsupportedPlatform;
    }
    if (std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.BadPathName;
    }
    var path_buffer: [std.posix.PATH_MAX]u8 =
        undefined;
    if (path.len >= path_buffer.len) {
        return error.NameTooLong;
    }
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const path_z = path_buffer[0..path.len :0];
    while (true) {
        var statx = std.mem.zeroes(linux.Statx);
        const rc = linux.statx(
            linux.AT.FDCWD,
            path_z,
            linux.AT.NO_AUTOMOUNT,
            .{ .UID = true },
            &statx,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (!statx.mask.UID) {
                    return error.OwnerUnavailable;
                }
                return statx.uid;
            },
            .INTR => {},
            .ACCES => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            else => return error.OwnerUnavailable,
        }
    }
}

pub fn absoluteFileExists(path: []const u8) OpenFileError!bool {
    var file = std.Io.Dir.openFileAbsolute(debug_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(debug_io);
    return true;
}

pub fn createDirPath(path: []const u8) CreateDirPathError!void {
    try std.Io.Dir.cwd().createDirPath(debug_io, path);
}

pub fn createAbsoluteDirPath(path: []const u8) CreateDirPathError!void {
    std.debug.assert(std.fs.path.isAbsolute(path));
    try createDirPath(path);
}

pub fn deleteFile(path: []const u8) DeleteFileError!void {
    try std.Io.Dir.cwd().deleteFile(debug_io, path);
}

pub fn deleteAbsoluteFile(path: []const u8) DeleteFileError!void {
    try std.Io.Dir.deleteFileAbsolute(debug_io, path);
}

pub fn deleteTree(path: []const u8) DeleteTreeError!void {
    try std.Io.Dir.cwd().deleteTree(debug_io, path);
}

pub fn setFilePermissions(
    path: []const u8,
    permissions: FilePermissions,
    options: SetFilePermissionsOptions,
) SetFilePermissionsError!void {
    try std.Io.Dir.cwd().setFilePermissions(debug_io, path, permissions, options);
}

pub fn rename(old_path: []const u8, new_path: []const u8) RenameError!void {
    try std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), new_path, debug_io);
}

/// Swaps two entries of one directory in a single atomic rename, so every
/// observer sees either both old names or both new names. Linux provides it
/// through renameat2 RENAME_EXCHANGE. A kernel or filesystem without it
/// refuses with ExchangeUnsupported.
pub fn exchange(directory: Dir, first: [:0]const u8, second: [:0]const u8) ExchangeError!void {
    if (comptime native_os != .linux) return error.ExchangeUnsupported;
    const result = linux.renameat2(directory.handle, first, directory.handle, second, .{ .EXCHANGE = true });
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .INVAL, .NOSYS, .OPNOTSUPP => return error.ExchangeUnsupported,
        else => |code| return posix.unexpectedErrno(code),
    }
}

pub fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) RealPathError![]u8 {
    const path_z = try std.Io.Dir.cwd().realPathFileAlloc(debug_io, path, allocator);
    defer allocator.free(path_z);
    return try allocator.dupe(u8, path_z);
}

pub fn listDirAlloc(allocator: std.mem.Allocator, path: []const u8) ListDirError![]Entry {
    var handle = try std.Io.Dir.cwd().openDir(debug_io, path, .{ .iterate = true });
    defer handle.close(debug_io);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var iterator = handle.iterate();
    while (try iterator.next(debug_io)) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        const entry_name = try allocator.dupe(u8, entry.name);
        var appended = false;
        errdefer if (!appended) {
            allocator.free(entry_path);
            allocator.free(entry_name);
        };
        try entries.append(allocator, .{
            .name = entry_name,
            .kind = entryKind(entry.kind),
            .path = entry_path,
        });
        appended = true;
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

const TruncateStatus = enum {
    success,
    interrupted,
    out_of_memory,
    failed,
};

const LinuxTruncateOperation = struct {
    fn run(
        _: *@This(),
        descriptor: fd.Descriptor,
        byte_len: usize,
    ) TruncateStatus {
        return switch (linux.errno(linux.ftruncate(descriptor, @intCast(byte_len)))) {
            .SUCCESS => .success,
            .INTR => .interrupted,
            .NOMEM => .out_of_memory,
            else => .failed,
        };
    }
};

const DarwinTruncateOperation = struct {
    fn run(
        _: *@This(),
        descriptor: fd.Descriptor,
        byte_len: usize,
    ) TruncateStatus {
        return switch (posix.errno(darwin.ftruncate(descriptor, @intCast(byte_len)))) {
            .SUCCESS => .success,
            .INTR => .interrupted,
            .NOMEM => .out_of_memory,
            else => .failed,
        };
    }
};

fn truncateDescriptorWith(
    operation: anytype,
    descriptor: fd.Descriptor,
    byte_len: usize,
) TruncateError!void {
    while (true) {
        switch (operation.run(descriptor, byte_len)) {
            .success => return,
            .interrupted => continue,
            .out_of_memory => return error.OutOfMemory,
            .failed => return error.TruncateFailed,
        }
    }
}

fn entryKind(kind: std.Io.File.Kind) EntryKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .sym_link,
        else => .other,
    };
}

const regular_open_input: [:0]const u8 = ".tiny-regular-open-input";
const regular_open_ready: [:0]const u8 = ".tiny-regular-open-ready";
const regular_open_go: [:0]const u8 = ".tiny-regular-open-go";
const handshake_attempts_max: usize = 500;
const handshake_wait_ms: u64 = 10;

fn supportsRegularFileOpen() bool {
    return native_os == .linux or native_os == .macos;
}

fn createNamedPipeForTest(
    directory: Dir,
    name: [:0]const u8,
) !void {
    createNamedPipe(directory, name, 0o600) catch |err| switch (err) {
        error.UnsupportedPlatform, error.AccessDenied => return error.SkipZigTest,
        error.CreateFailed => return error.CreateNamedPipeFailed,
    };
}

const InterruptingTruncateOperation = struct {
    attempts: usize = 0,

    fn run(self: *@This(), _: fd.Descriptor, _: usize) TruncateStatus {
        self.attempts += 1;
        return if (self.attempts == 1) .interrupted else .success;
    }
};

const FixedTruncateOperation = struct {
    status: TruncateStatus,
    attempts: usize = 0,

    fn run(self: *@This(), _: fd.Descriptor, _: usize) TruncateStatus {
        self.attempts += 1;
        return self.status;
    }
};

fn openNamedPipeGuardForTest(
    directory: Dir,
    name: [:0]const u8,
) !std.Io.File {
    const descriptor = try std.posix.openat(directory.handle, name, .{
        .ACCMODE = .RDWR,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0);
    return .{
        .handle = descriptor,
        .flags = .{ .nonblocking = true },
    };
}

fn expectRegularOpenRejected(directory: Dir, name: []const u8) !void {
    var opened = openRegularFile(debug_io, directory, name) catch |err| {
        if (err != error.NotRegularFile) return err;
        return;
    };
    defer opened.file.close(debug_io);
    return error.ExpectedRegularFileRejection;
}

fn expectRegularOpenFlags(file: std.Io.File) !void {
    const descriptor_flags = std.posix.system.fcntl(
        file.handle,
        std.posix.F.GETFD,
        @as(usize, 0),
    );
    try std.testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(descriptor_flags),
    );
    const descriptor_bits: usize = @intCast(descriptor_flags);
    try std.testing.expect(
        descriptor_bits & @as(usize, std.posix.FD_CLOEXEC) != 0,
    );
    const status_flags = std.posix.system.fcntl(
        file.handle,
        std.posix.F.GETFL,
        @as(usize, 0),
    );
    try std.testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(status_flags),
    );
    const status_bits: usize = @intCast(status_flags);
    const nonblocking: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    try std.testing.expect(status_bits & nonblocking != 0);
}

fn waitForTestEntry(directory: Dir, name: []const u8) !void {
    const time = @import("time.zig");
    for (0..handshake_attempts_max) |_| {
        if (directory.statFile(
            debug_io,
            name,
            .{ .follow_symlinks = false },
        )) |_| {
            return;
        } else |err| switch (err) {
            error.FileNotFound => time.sleepMilliseconds(handshake_wait_ms),
            else => return err,
        }
    }
    return error.TestHandshakeTimedOut;
}

fn waitForReplacementChild(child: *@import("process/root.zig").Child) !void {
    const process = @import("process/root.zig");
    const time = @import("time.zig");
    const child_id = child.id orelse return error.ExpectedChildProcess;
    for (0..handshake_attempts_max) |_| {
        if (try process.waitNoHang(child_id)) |outcome| {
            child.id = null;
            if (process.exitCode(outcome.term) != 0) {
                return error.ReplacementChildFailed;
            }
            return;
        }
        time.sleepMilliseconds(handshake_wait_ms);
    }
    return error.ReplacementChildTimedOut;
}
