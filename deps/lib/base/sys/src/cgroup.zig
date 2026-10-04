//! Linux control groups on the unified (version two) hierarchy, reached through
//! directory descriptors so that no call builds a path under the mount by hand.
//!
//! A *group* is one directory of the hierarchy, held open read-only as a
//! `Group`. The caller creates and removes child groups, enables controllers
//! for a group's children, and reads what the kernel accounted: the peak of
//! charged memory, the user and system CPU time of every task that ever ran
//! there, and the count of out-of-memory kills. CPU time comes from `cpu.stat`,
//! which the kernel keeps in every group whether or not the cpu controller is
//! enabled, and the memory figures need the memory controller enabled in the
//! parent's `cgroup.subtree_control`.
//!
//! *Membership*, the group the calling process belongs to, comes from
//! `/proc/self/cgroup`. It is `unified` only when that file holds the single
//! `0::` line of a unified host, and `none` on a legacy or hybrid host.
//!
//! Every file is read into caller or fixed storage, and a file that fills it
//! fails with `BufferTooSmall`. The parsers are pure functions over bytes and
//! run on any host. Every call that touches the kernel returns
//! `UnsupportedPlatform` off Linux.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");

const linux = std.os.linux;
const native_os = builtin.os.tag;

pub const required_capabilities = capabilities.host(&.{
    .descriptors,
    .filesystem,
});

pub const Descriptor = std.posix.fd_t;

/// Where the unified hierarchy is mounted on a systemd host.
pub const mount_point = "/sys/fs/cgroup";
/// The longest single path component the kernel accepts for a group name.
pub const name_bytes_max: usize = 255;
/// The largest interface file the readers here accept. `cpu.stat` and
/// `memory.events` are a few hundred bytes on Linux 7.1.
pub const value_bytes_max: usize = 4096;
/// The largest `/proc/self/cgroup` the membership reader accepts.
pub const membership_bytes_max: usize = 4096;

pub const Error = error{
    UnsupportedPlatform,
    AccessDenied,
    NotFound,
    Exists,
    /// A removal found live tasks or child groups, or a write found a
    /// controller that cannot change in the group's state.
    Busy,
    /// A creation met `cgroup.max.descendants` or `cgroup.max.depth`.
    LimitReached,
    NoSpace,
    NameTooLong,
    BufferTooSmall,
    InvalidData,
    SystemResources,
    Unexpected,
};

pub const Controller = enum {
    cpu,
    cpuset,
    io,
    memory,
    pids,
    hugetlb,
    rdma,
    misc,
    perf_event,
    dmem,
};

pub const Controllers = std.EnumSet(Controller);

/// Reads a `cgroup.controllers` or `cgroup.subtree_control` line. Names this
/// enum does not know are skipped, since newer kernels add controllers.
pub fn parseControllers(text: []const u8) Controllers {
    var result: Controllers = .empty;
    var names = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (names.next()) |name| {
        if (std.meta.stringToEnum(Controller, name)) |controller| result.insert(controller);
    }
    return result;
}

pub const Membership = union(enum) {
    /// The group path relative to the mount, beginning with `/`.
    unified: []const u8,
    /// No single unified line: a legacy or hybrid host.
    none,
};

pub fn parseMembership(text: []const u8) Error!Membership {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return error.InvalidData;
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) return .none;
    const prefix = "0::";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return .none;
    const path = trimmed[prefix.len..];
    if (path.len == 0 or path[0] != '/') return error.InvalidData;
    return .{ .unified = path };
}

/// Reports the calling process's group. The returned path borrows `storage`.
pub fn membership(storage: []u8) Error!Membership {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    const descriptor = try openZ(linux.AT.FDCWD, "/proc/self/cgroup", .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    });
    defer _ = linux.close(descriptor);
    return parseMembership(try readAll(descriptor, storage));
}

/// Reports whether `path` is `root` itself or lies below it.
pub fn within(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/';
}

/// Returns the value of one `key value` line, as in `cpu.stat`,
/// `memory.events`, `cgroup.events` and `cgroup.stat`. A missing or repeated
/// key and a malformed value are `InvalidData`.
pub fn parseKeyed(text: []const u8, key: []const u8) Error!u64 {
    var found: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, key)) continue;
        if (found != null) return error.InvalidData;
        const value = fields.next() orelse return error.InvalidData;
        if (fields.next() != null) return error.InvalidData;
        found = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidData;
    }
    return found orelse error.InvalidData;
}

/// Reads a file holding one unsigned integer, such as `memory.peak`.
pub fn parseCount(text: []const u8) Error!u64 {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return error.InvalidData;
    return std.fmt.parseUnsigned(u64, value, 10) catch error.InvalidData;
}

/// What the kernel accounted to one group over its lifetime.
pub const Usage = struct {
    /// `memory.peak`: the highest memory charged at once, page cache and
    /// tmpfs included, so it is not a resident-set figure.
    memory_peak_bytes: u64,
    cpu_user_usec: u64,
    cpu_system_usec: u64,
    /// The `oom_kill` line of `memory.events`, which counts kills in the group
    /// and its descendants.
    oom_kills: u64,
};

pub fn parseUsage(peak: []const u8, cpu: []const u8, events: []const u8) Error!Usage {
    return .{
        .memory_peak_bytes = try parseCount(peak),
        .cpu_user_usec = try parseKeyed(cpu, "user_usec"),
        .cpu_system_usec = try parseKeyed(cpu, "system_usec"),
        .oom_kills = try parseKeyed(events, "oom_kill"),
    };
}

/// The `cgroup.stat` counts of live and dying descendants.
pub const Census = struct {
    descendants: u64,
    dying_descendants: u64,
};

pub fn parseCensus(text: []const u8) Error!Census {
    return .{
        .descendants = try parseKeyed(text, "nr_descendants"),
        .dying_descendants = try parseKeyed(text, "nr_dying_descendants"),
    };
}

/// One group held open read-only. The descriptor also serves as the target of
/// `clone3` with `CLONE_INTO_CGROUP`.
pub const Group = struct {
    descriptor: Descriptor,

    /// Opens the group at an absolute path.
    pub fn open(path: []const u8) Error!Group {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        var storage: [std.fs.max_path_bytes + 1]u8 = undefined;
        const text = try terminated(&storage, path);
        return .{ .descriptor = try openZ(linux.AT.FDCWD, text, directory_flags) };
    }

    pub fn openChild(self: Group, name: []const u8) Error!Group {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        var storage: [name_bytes_max + 1]u8 = undefined;
        const text = try component(&storage, name);
        return .{ .descriptor = try openZ(self.descriptor, text, directory_flags) };
    }

    pub fn close(self: Group) void {
        if (comptime native_os != .linux) return;
        _ = linux.close(self.descriptor);
    }

    pub fn createChild(self: Group, name: []const u8) Error!void {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        var storage: [name_bytes_max + 1]u8 = undefined;
        const text = try component(&storage, name);
        return switch (linux.errno(linux.mkdirat(self.descriptor, text, 0o755))) {
            .SUCCESS => {},
            .EXIST => error.Exists,
            .AGAIN => error.LimitReached,
            else => |code| mapErrno(code),
        };
    }

    /// Removes an empty child group. A child that still holds tasks or groups
    /// fails with `Busy` and stays.
    pub fn removeChild(self: Group, name: []const u8) Error!void {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        var storage: [name_bytes_max + 1]u8 = undefined;
        const text = try component(&storage, name);
        const rc = linux.unlinkat(self.descriptor, text, linux.AT.REMOVEDIR);
        return switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOTEMPTY => error.Busy,
            else => |code| mapErrno(code),
        };
    }

    /// Reads one interface file into `storage` and returns the filled prefix.
    pub fn read(self: Group, name: []const u8, storage: []u8) Error![]const u8 {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        var name_storage: [name_bytes_max + 1]u8 = undefined;
        const text = try component(&name_storage, name);
        const descriptor = try openZ(self.descriptor, text, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        defer _ = linux.close(descriptor);
        return readAll(descriptor, storage);
    }

    /// Writes one interface file in a single call, as the kernel requires.
    pub fn write(self: Group, name: []const u8, bytes: []const u8) Error!void {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        var name_storage: [name_bytes_max + 1]u8 = undefined;
        const text = try component(&name_storage, name);
        const descriptor = try openZ(self.descriptor, text, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
        defer _ = linux.close(descriptor);
        while (true) {
            const rc = linux.write(descriptor, bytes.ptr, bytes.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return if (rc == bytes.len) {} else error.Unexpected,
                .INTR => continue,
                else => |code| return mapErrno(code),
            }
        }
    }

    /// The controllers the parent makes available to this group.
    pub fn controllers(self: Group) Error!Controllers {
        var storage: [value_bytes_max]u8 = undefined;
        return parseControllers(try self.read("cgroup.controllers", &storage));
    }

    /// The controllers this group enables for its children.
    pub fn subtreeControl(self: Group) Error!Controllers {
        var storage: [value_bytes_max]u8 = undefined;
        return parseControllers(try self.read("cgroup.subtree_control", &storage));
    }

    /// Enables `set` for this group's children. Enabling what is already on
    /// changes nothing.
    pub fn enable(self: Group, set: Controllers) Error!void {
        var storage: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        var iterator = set.iterator();
        var first = true;
        while (iterator.next()) |controller| {
            if (!first) writer.writeByte(' ') catch return error.BufferTooSmall;
            first = false;
            writer.print("+{s}", .{@tagName(controller)}) catch return error.BufferTooSmall;
        }
        if (first) return;
        return self.write("cgroup.subtree_control", writer.buffered());
    }

    /// Sets `cgroup.max.descendants`, so a creation below this group past
    /// `count` live descendants fails with `LimitReached`.
    pub fn limitDescendants(self: Group, count: u32) Error!void {
        var storage: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&storage, "{d}", .{count}) catch unreachable;
        return self.write("cgroup.max.descendants", text);
    }

    /// Reports whether any task lives in this group or below it.
    pub fn populated(self: Group) Error!bool {
        var storage: [value_bytes_max]u8 = undefined;
        return switch (try parseKeyed(try self.read("cgroup.events", &storage), "populated")) {
            0 => false,
            1 => true,
            else => error.InvalidData,
        };
    }

    /// Reports whether this group is frozen, by its own `cgroup.freeze` or an
    /// ancestor's. A task started in a frozen group stops before it runs.
    pub fn frozen(self: Group) Error!bool {
        var storage: [value_bytes_max]u8 = undefined;
        return switch (try parseKeyed(try self.read("cgroup.events", &storage), "frozen")) {
            0 => false,
            1 => true,
            else => error.InvalidData,
        };
    }

    pub fn census(self: Group) Error!Census {
        var storage: [value_bytes_max]u8 = undefined;
        return parseCensus(try self.read("cgroup.stat", &storage));
    }

    /// Reads the group's lifetime usage. It is all or nothing: any unreadable
    /// file fails the whole reading.
    pub fn usage(self: Group) Error!Usage {
        var peak: [64]u8 = undefined;
        var cpu: [value_bytes_max]u8 = undefined;
        var events: [value_bytes_max]u8 = undefined;
        return parseUsage(
            try self.read("memory.peak", &peak),
            try self.read("cpu.stat", &cpu),
            try self.read("memory.events", &events),
        );
    }

    /// Iterates this group's child groups. The iterator holds its own
    /// descriptor, so iteration never moves this group's offset.
    pub fn children(self: Group, buffer: []align(8) u8) Error!Children {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        return .{
            .descriptor = try openZ(self.descriptor, ".", directory_flags),
            .buffer = buffer,
        };
    }
};

/// Yields the names of child directories, skipping `.` and `..`. Each name
/// borrows the iterator's buffer until the next call.
pub const Children = struct {
    descriptor: Descriptor,
    buffer: []align(8) u8,
    offset: usize = 0,
    filled: usize = 0,

    pub fn next(self: *Children) Error!?[]const u8 {
        if (comptime native_os != .linux) return error.UnsupportedPlatform;
        while (true) {
            if (self.offset >= self.filled) {
                const rc = linux.getdents64(
                    self.descriptor,
                    self.buffer.ptr,
                    @intCast(@min(self.buffer.len, std.math.maxInt(c_uint))),
                );
                switch (linux.errno(rc)) {
                    .SUCCESS => {},
                    .INVAL => return error.BufferTooSmall,
                    else => |code| return mapErrno(code),
                }
                if (rc == 0) return null;
                self.filled = rc;
                self.offset = 0;
            }
            const entry: *align(1) const linux.dirent64 = @ptrCast(&self.buffer[self.offset]);
            self.offset += entry.reclen;
            if (entry.type != linux.DT.DIR) continue;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return name;
        }
    }

    pub fn close(self: *Children) void {
        if (comptime native_os != .linux) return;
        _ = linux.close(self.descriptor);
        self.* = undefined;
    }
};

const directory_flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };

fn openZ(directory: Descriptor, path: [*:0]const u8, flags: linux.O) Error!Descriptor {
    while (true) {
        const rc = linux.openat(directory, path, flags, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |code| return mapErrno(code),
        }
    }
}

fn readAll(descriptor: Descriptor, storage: []u8) Error![]const u8 {
    var count: usize = 0;
    while (count < storage.len) {
        const rc = linux.read(descriptor, storage[count..].ptr, storage.len - count);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return storage[0..count];
                count += rc;
            },
            .INTR => continue,
            else => |code| return mapErrno(code),
        }
    }
    return error.BufferTooSmall;
}

fn terminated(storage: []u8, text: []const u8) Error![*:0]const u8 {
    if (text.len >= storage.len) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidData;
    @memcpy(storage[0..text.len], text);
    storage[text.len] = 0;
    return storage[0..text.len :0].ptr;
}

/// Accepts exactly one path component, so a name never reaches outside its
/// parent group.
fn component(storage: *[name_bytes_max + 1]u8, name: []const u8) Error![*:0]const u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
    {
        return error.InvalidData;
    }
    return terminated(storage, name);
}

fn mapErrno(code: linux.E) Error {
    return switch (code) {
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOENT, .NOTDIR, .NODEV => error.NotFound,
        .EXIST => error.Exists,
        .BUSY, .NOTEMPTY => error.Busy,
        .AGAIN => error.LimitReached,
        .NOSPC => error.NoSpace,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM, .MFILE, .NFILE => error.SystemResources,
        .INVAL, .OPNOTSUPP => error.InvalidData,
        else => error.Unexpected,
    };
}
