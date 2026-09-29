//! Capture-only exit barrier. The caller invokes this after its exact announcement
//! write, routes every error through publication invalidation, and supplies the
//! unchanged initial environment value. The collector independently retains the
//! live process; protocol fields never substitute for kernel process identity.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const environment_name = "TINY_BINDING_CAPTURE";
pub const maximum_environment_bytes = 256;
pub const maximum_socket_path_bytes = 96;
pub const maximum_peers = 64;
pub const packet_bytes = 128;
pub const maximum_announcement_bytes = 17216;
pub const maximum_snapshot_bytes = 256 * 1024;
pub const maximum_ancestors = 4096;
pub const maximum_proc_bytes = 8192;
pub const maximum_control_bytes = 64;
pub const maximum_operations = 262144;
pub const socket_buffer_request_bytes: i32 = 8192;
pub const maximum_effective_socket_buffer_bytes: i32 = 2 * socket_buffer_request_bytes;
pub const timeout_ns: u64 = 120 * std.time.ns_per_s;
pub const magic = "TC7LIF01";

pub const Error = error{
    CompilerBindingLifetimePlatform,
    CompilerBindingLifetimeEnvironment,
    CompilerBindingLifetimeAnnouncement,
    CompilerBindingLifetimeProtocol,
    CompilerBindingLifetimeCredentials,
    CompilerBindingLifetimeObserver,
    CompilerBindingLifetimePeerChanged,
    CompilerBindingLifetimeAncestry,
    CompilerBindingLifetimeAncestorsExceeded,
    CompilerBindingLifetimeProcExceeded,
    CompilerBindingLifetimeDescriptorsExceeded,
    CompilerBindingLifetimeWorkExceeded,
    CompilerBindingLifetimeTimeout,
    CompilerBindingLifetimeClock,
    CompilerBindingLifetimeIo,
};

pub const Kind = enum(u32) { hello = 1, challenge = 2, ready = 3, ack = 4 };

/// Layout: magic[0..8], kind u32[8..12], zero flags[12..16], capture[16..48],
/// challenge[48..80], digest[80..112], value u64[112..120], zero[120..128].
/// All integers are little endian; hashes and nonces are raw 32-byte values.
pub const Packet = struct {
    kind: Kind,
    capture: [32]u8,
    challenge: [32]u8,
    digest: [32]u8,
    value: u64,

    pub fn encode(self: Packet) [packet_bytes]u8 {
        var bytes: [packet_bytes]u8 = @splat(0);
        @memcpy(bytes[0..8], magic);
        std.mem.writeInt(u32, bytes[8..12], @backingInt(self.kind), .little);
        @memcpy(bytes[16..48], &self.capture);
        @memcpy(bytes[48..80], &self.challenge);
        @memcpy(bytes[80..112], &self.digest);
        std.mem.writeInt(u64, bytes[112..120], self.value, .little);
        return bytes;
    }

    pub fn decode(bytes: []const u8) Error!Packet {
        if (bytes.len != packet_bytes or !std.mem.eql(u8, bytes[0..8], magic) or
            !zero(bytes[12..16]) or !zero(bytes[120..128]))
            return error.CompilerBindingLifetimeProtocol;
        return .{
            .kind = switch (std.mem.readInt(u32, bytes[8..12], .little)) {
                1 => .hello,
                2 => .challenge,
                3 => .ready,
                4 => .ack,
                else => return error.CompilerBindingLifetimeProtocol,
            },
            .capture = bytes[16..48].*,
            .challenge = bytes[48..80].*,
            .digest = bytes[80..112].*,
            .value = std.mem.readInt(u64, bytes[112..120], .little),
        };
    }
};

pub const Config = struct {
    path: []const u8,
    session: [32]u8,

    pub fn parse(value: []const u8) Error!Config {
        if (value.len > maximum_environment_bytes or !std.mem.startsWith(u8, value, "unix1:"))
            return error.CompilerBindingLifetimeEnvironment;
        const tail = value[6..];
        const separator = std.mem.indexOfScalar(u8, tail, ':') orelse return error.CompilerBindingLifetimeEnvironment;
        const path = tail[0..separator];
        const hex = tail[separator + 1 ..];
        if (path.len < 2 or path.len > maximum_socket_path_bytes or path[0] != '/' or
            path[path.len - 1] == '/' or hex.len != 64)
            return error.CompilerBindingLifetimeEnvironment;
        for (path) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '.' or byte == '_' or byte == '-'))
                return error.CompilerBindingLifetimeEnvironment;
        }
        var parts = std.mem.splitScalar(u8, path[1..], '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
                return error.CompilerBindingLifetimeEnvironment;
        }
        var session: [32]u8 = undefined;
        for (&session, 0..) |*byte, i| byte.* = (try nibble(hex[2 * i])) * 16 + try nibble(hex[2 * i + 1]);
        if (zero(&session)) return error.CompilerBindingLifetimeEnvironment;
        return .{ .path = path, .session = session };
    }
};

const Identity = struct {
    pid: i32,
    parent: i32,
    start: u64,

    fn same(self: Identity, other: Identity) bool {
        return self.pid == other.pid and self.parent == other.parent and self.start == other.start;
    }
};

const Ancestor = struct { identity: Identity, fd: i32 };

/// Caller owns one workspace for the entire call; no heap allocation occurs.
/// Only the populated ancestry prefix is initialized, visited and closed.
pub const Workspace = struct {
    ancestors: [maximum_ancestors]Ancestor,
    proc_bytes: [maximum_proc_bytes + 1]u8,
    count: usize,
};

pub fn workspaceBytes() usize {
    return @sizeOf(Workspace);
}

/// Ancestry pidfds + one socket + one temporary proc descriptor. Ancillary
/// rights are always refused and closed; up to control_bytes / sizeof(fd)
/// additional received descriptors may transiently exist before refusal.
pub fn descriptorsMax() usize {
    return maximum_ancestors + 2 + maximum_control_bytes / @sizeOf(i32);
}

pub fn transportBytesMax() usize {
    return maximum_peers * 4 * packet_bytes;
}

/// Absent environment returns before inspecting arguments/workspace or making a
/// syscall. Present configuration never degrades to the ordinary path on error.
pub fn barrier(value: ?[]const u8, announcement: []const u8, workspace: *Workspace) Error!void {
    const configured = value orelse return;
    if (comptime builtin.os.tag != .linux) return error.CompilerBindingLifetimePlatform;
    const config = try Config.parse(configured);
    var exchange = try Exchange.init(config.session, announcement);
    var kernel: Kernel = .{ .budget = try Budget.init(try now()), .workspace = workspace };
    workspace.count = 0;
    defer {
        for (workspace.ancestors[0..workspace.count]) |ancestor| _ = linux.close(ancestor.fd);
    }
    const socket = try kernel.connect(config.path);
    defer _ = linux.close(socket);
    try kernel.send(socket, exchange.hello(), null);
    const challenge = try kernel.receive(socket, null);
    const ready = try exchange.acceptChallenge(challenge.packet);
    const peer = try kernel.authenticate(challenge.credentials);
    const executable = try kernel.executable(challenge.credentials.pid);
    try kernel.verifyAncestry();
    try kernel.send(socket, ready, peer);
    const ack = try kernel.receive(socket, peer);
    if (!challenge.credentials.same(ack.credentials)) return error.CompilerBindingLifetimePeerChanged;
    try exchange.acceptAck(ack.packet);
    try kernel.verifyAncestry();
    try kernel.privileges(challenge.credentials.pid);
    if (!executable.same(try kernel.executable(challenge.credentials.pid))) return error.CompilerBindingLifetimePeerChanged;
    try kernel.noPending(socket);
    try kernel.budget.tick();
}

const Exchange = struct {
    session: [32]u8,
    digest: [32]u8,
    bytes: u64,
    epoch: [32]u8 = @splat(0),
    nonce: [32]u8 = @splat(0),
    state: enum { challenge, ack, done } = .challenge,

    fn init(session: [32]u8, announcement: []const u8) Error!Exchange {
        if (announcement.len == 0 or announcement.len > maximum_announcement_bytes or
            announcement[announcement.len - 1] != '\n')
            return error.CompilerBindingLifetimeAnnouncement;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(announcement, &digest, .{});
        return .{ .session = session, .digest = digest, .bytes = announcement.len };
    }

    fn hello(self: Exchange) Packet {
        return .{ .kind = .hello, .capture = self.session, .challenge = @splat(0), .digest = self.digest, .value = self.bytes };
    }

    fn acceptChallenge(self: *Exchange, packet: Packet) Error!Packet {
        if (self.state != .challenge or packet.kind != .challenge or zero(&packet.capture) or
            zero(&packet.challenge) or std.mem.eql(u8, &packet.capture, &self.session) or
            !std.mem.eql(u8, &packet.digest, &self.digest) or packet.value != self.bytes)
            return error.CompilerBindingLifetimeProtocol;
        self.epoch = packet.capture;
        self.nonce = packet.challenge;
        self.state = .ack;
        var ready = packet;
        ready.kind = .ready;
        return ready;
    }

    fn acceptAck(self: *Exchange, packet: Packet) Error!void {
        if (self.state != .ack or packet.kind != .ack or
            !std.mem.eql(u8, &packet.capture, &self.epoch) or !std.mem.eql(u8, &packet.challenge, &self.nonce) or
            packet.value == 0 or packet.value > maximum_snapshot_bytes)
            return error.CompilerBindingLifetimeProtocol;
        self.state = .done;
    }
};

const Budget = struct {
    deadline: u64,
    operations: usize = 0,

    fn init(start: u64) Error!Budget {
        return .{ .deadline = std.math.add(u64, start, timeout_ns) catch return error.CompilerBindingLifetimeClock };
    }

    fn check(self: *Budget, instant: u64) Error!u64 {
        if (instant >= self.deadline) return error.CompilerBindingLifetimeTimeout;
        if (self.operations == maximum_operations) return error.CompilerBindingLifetimeWorkExceeded;
        self.operations += 1;
        return self.deadline - instant;
    }

    fn tick(self: *Budget) Error!void {
        _ = try self.check(try now());
    }
};

const Credentials = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,

    fn same(self: Credentials, other: Credentials) bool {
        return self.pid == other.pid and self.uid == other.uid and self.gid == other.gid;
    }
};

const Received = struct { packet: Packet, credentials: Credentials };

/// The parser remembers all delivered SCM_RIGHTS even when credentials fail, so
/// the syscall boundary can close every injected descriptor on every exit path.
const Control = struct {
    credentials: ?Credentials = null,
    rights: [maximum_control_bytes / @sizeOf(i32)]i32 = undefined,
    count: usize = 0,
    invalid: bool = false,

    fn close(self: *Control) void {
        for (self.rights[0..self.count]) |fd| _ = linux.close(fd);
        self.count = 0;
    }

    fn parse(self: *Control, bytes: []const u8) Error!Credentials {
        if (bytes.len > maximum_control_bytes) return error.CompilerBindingLifetimeCredentials;
        var offset: usize = 0;
        const header_bytes = @sizeOf(linux.cmsghdr);
        while (offset < bytes.len) {
            if (bytes.len - offset < header_bytes) return error.CompilerBindingLifetimeCredentials;
            const header = std.mem.bytesToValue(linux.cmsghdr, bytes[offset..][0..header_bytes]);
            if (header.len < header_bytes or header.len > bytes.len - offset)
                return error.CompilerBindingLifetimeCredentials;
            const payload = bytes[offset + header_bytes .. offset + header.len];
            if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
                self.invalid = true;
                if (payload.len % @sizeOf(i32) != 0) return error.CompilerBindingLifetimeCredentials;
                var at: usize = 0;
                while (at < payload.len) : (at += @sizeOf(i32)) {
                    if (self.count == self.rights.len) return error.CompilerBindingLifetimeCredentials;
                    self.rights[self.count] = std.mem.bytesToValue(i32, payload[at..][0..@sizeOf(i32)]);
                    self.count += 1;
                }
            } else if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.CREDENTIALS) {
                if (self.credentials != null or payload.len != @sizeOf(Credentials)) {
                    self.invalid = true;
                } else self.credentials = std.mem.bytesToValue(Credentials, payload[0..@sizeOf(Credentials)]);
            } else self.invalid = true;
            const next = std.mem.alignForward(usize, header.len, @sizeOf(usize));
            if (next > bytes.len - offset) {
                if (header.len != bytes.len - offset) return error.CompilerBindingLifetimeCredentials;
                offset = bytes.len;
            } else offset += next;
        }
        if (self.invalid) return error.CompilerBindingLifetimeCredentials;
        const credentials = self.credentials orelse return error.CompilerBindingLifetimeCredentials;
        if (credentials.pid <= 0) return error.CompilerBindingLifetimeCredentials;
        return credentials;
    }
};

const Executable = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    bytes: u64,
    mtime: i64,
    mtime_ns: u32,
    ctime: i64,
    ctime_ns: u32,

    fn same(self: Executable, other: Executable) bool {
        return std.meta.eql(self, other);
    }
};

const Kernel = struct {
    budget: Budget,
    workspace: *Workspace,

    fn connect(self: *Kernel, path: []const u8) Error!i32 {
        try self.budget.tick();
        const socket = try descriptor(linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0));
        errdefer _ = linux.close(socket);
        const enabled: i32 = 1;
        try self.budget.tick();
        if (linux.errno(linux.setsockopt(socket, linux.SOL.SOCKET, linux.SO.PASSCRED, std.mem.asBytes(&enabled), @sizeOf(i32))) != .SUCCESS)
            return error.CompilerBindingLifetimeIo;
        for ([_]u32{ linux.SO.SNDBUF, linux.SO.RCVBUF }) |option| {
            try self.budget.tick();
            if (linux.errno(linux.setsockopt(socket, linux.SOL.SOCKET, option, std.mem.asBytes(&socket_buffer_request_bytes), @sizeOf(i32))) != .SUCCESS)
                return error.CompilerBindingLifetimeIo;
            var effective: i32 = 0;
            var length: linux.socklen_t = @sizeOf(i32);
            try self.budget.tick();
            if (linux.errno(linux.getsockopt(socket, linux.SOL.SOCKET, option, std.mem.asBytes(&effective), &length)) != .SUCCESS or
                length != @sizeOf(i32) or effective <= 0 or effective > maximum_effective_socket_buffer_bytes)
                return error.CompilerBindingLifetimeIo;
        }
        var address: linux.sockaddr.un = .{ .path = @splat(0) };
        @memcpy(address.path[0..path.len], path);
        try self.budget.tick();
        const result = linux.connect(socket, &address, @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1));
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INPROGRESS => {
                try self.wait(socket, linux.POLL.OUT, null);
                var failure: i32 = 0;
                var length: linux.socklen_t = @sizeOf(i32);
                try self.budget.tick();
                if (linux.errno(linux.getsockopt(socket, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&failure), &length)) != .SUCCESS or
                    length != @sizeOf(i32) or failure != 0) return error.CompilerBindingLifetimeObserver;
            },
            else => return error.CompilerBindingLifetimeObserver,
        }
        return socket;
    }

    fn wait(self: *Kernel, socket: i32, events: i16, peer: ?i32) Error!void {
        while (true) {
            const remaining = try self.budget.check(try now());
            const millis: i32 = @intCast((remaining + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
            var fds = [_]linux.pollfd{
                .{ .fd = socket, .events = events, .revents = 0 },
                .{ .fd = peer orelse -1, .events = linux.POLL.IN, .revents = 0 },
            };
            const result = linux.poll(&fds, fds.len, millis);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    try self.budget.tick();
                    if (fds[1].revents != 0) return error.CompilerBindingLifetimePeerChanged;
                    if (fds[0].revents & (linux.POLL.ERR | linux.POLL.NVAL) != 0)
                        return error.CompilerBindingLifetimeObserver;
                    if (events == linux.POLL.IN and fds[0].revents & linux.POLL.IN != 0) return;
                    if (fds[0].revents & linux.POLL.HUP != 0) return error.CompilerBindingLifetimeObserver;
                    if (fds[0].revents & events != 0) return;
                },
                .INTR => {},
                else => return error.CompilerBindingLifetimeIo,
            }
        }
    }

    fn send(self: *Kernel, socket: i32, packet: Packet, peer: ?i32) Error!void {
        const bytes = packet.encode();
        var vector: std.posix.iovec_const = .{ .base = &bytes, .len = bytes.len };
        const message: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = (&vector)[0..1],
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        while (true) {
            try self.budget.tick();
            const result = linux.sendmsg(socket, &message, linux.MSG.NOSIGNAL);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result != packet_bytes) return error.CompilerBindingLifetimeProtocol;
                    return;
                },
                .INTR => {},
                .AGAIN => try self.wait(socket, linux.POLL.OUT, peer),
                else => return error.CompilerBindingLifetimeObserver,
            }
        }
    }

    fn receive(self: *Kernel, socket: i32, peer: ?i32) Error!Received {
        while (true) {
            try self.wait(socket, linux.POLL.IN, peer);
            var bytes: [packet_bytes]u8 = undefined;
            var control_bytes: [maximum_control_bytes]u8 align(@alignOf(linux.cmsghdr)) = undefined;
            var vector: std.posix.iovec = .{ .base = &bytes, .len = bytes.len };
            var message: linux.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = (&vector)[0..1],
                .iovlen = 1,
                .control = &control_bytes,
                .controllen = control_bytes.len,
                .flags = 0,
            };
            try self.budget.tick();
            const result = linux.recvmsg(socket, &message, linux.MSG.CMSG_CLOEXEC);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    const flags = message.flags | (if (result > bytes.len) @as(u32, linux.MSG.TRUNC) else 0);
                    return received(bytes[0..@min(result, bytes.len)], control_bytes[0..message.controllen], flags);
                },
                .INTR, .AGAIN => {},
                else => return error.CompilerBindingLifetimeObserver,
            }
        }
    }

    /// Drain an already queued extra packet solely to close any attached rights.
    /// A normal server socket close after ACK is allowed while its pidfd is live.
    fn noPending(self: *Kernel, socket: i32) Error!void {
        var bytes: [packet_bytes]u8 = undefined;
        var control_bytes: [maximum_control_bytes]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var vector: std.posix.iovec = .{ .base = &bytes, .len = bytes.len };
        while (true) {
            var message: linux.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = (&vector)[0..1],
                .iovlen = 1,
                .control = &control_bytes,
                .controllen = control_bytes.len,
                .flags = 0,
            };
            try self.budget.tick();
            const result = linux.recvmsg(socket, &message, linux.MSG.CMSG_CLOEXEC);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    var control: Control = .{};
                    defer control.close();
                    _ = control.parse(control_bytes[0..message.controllen]) catch {};
                    if (result == 0 and message.controllen == 0) return;
                    return error.CompilerBindingLifetimeProtocol;
                },
                .AGAIN => return,
                .INTR => {},
                else => return error.CompilerBindingLifetimeObserver,
            }
        }
    }

    fn authenticate(self: *Kernel, credentials: Credentials) Error!i32 {
        try self.budget.tick();
        const own = linux.getpid();
        if (credentials.pid == own or credentials.uid != linux.getuid() or credentials.gid != linux.getgid())
            return error.CompilerBindingLifetimeCredentials;
        try self.privileges(own);
        try self.privileges(credentials.pid);
        const own_namespace = try self.namespace(own);
        if (!std.mem.eql(u8, &own_namespace, &(try self.namespace(credentials.pid))))
            return error.CompilerBindingLifetimeCredentials;
        var pid = own;
        for (0..maximum_ancestors) |_| {
            const before = try self.identity(pid);
            try self.budget.tick();
            const fd = blk: {
                const pinned = try descriptor(linux.pidfd_open(pid, 0));
                errdefer _ = linux.close(pinned);
                const after = try self.identity(pid);
                if (!before.same(after)) return error.CompilerBindingLifetimePeerChanged;
                break :blk pinned;
            };
            self.workspace.ancestors[self.workspace.count] = .{ .identity = before, .fd = fd };
            self.workspace.count += 1;
            if (pid == credentials.pid) return fd;
            if (before.parent <= 0 or before.parent == pid) return error.CompilerBindingLifetimeAncestry;
            pid = before.parent;
        }
        return error.CompilerBindingLifetimeAncestorsExceeded;
    }

    fn verifyAncestry(self: *Kernel) Error!void {
        for (self.workspace.ancestors[0..self.workspace.count]) |ancestor| {
            try self.budget.tick();
            var entry = [_]linux.pollfd{.{ .fd = ancestor.fd, .events = linux.POLL.IN, .revents = 0 }};
            if (linux.errno(linux.poll(&entry, 1, 0)) != .SUCCESS or entry[0].revents != 0)
                return error.CompilerBindingLifetimePeerChanged;
            if (!ancestor.identity.same(try self.identity(ancestor.identity.pid)))
                return error.CompilerBindingLifetimePeerChanged;
        }
    }

    fn identity(self: *Kernel, pid: i32) Error!Identity {
        return parseStat(pid, try self.proc(pid, "stat"));
    }

    fn privileges(self: *Kernel, pid: i32) Error!void {
        const bytes = try self.proc(pid, "status");
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var found = false;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "CapEff:\t")) {
                if (found or line.len != 24 or !std.mem.eql(u8, line[8..], "0000000000000000"))
                    return error.CompilerBindingLifetimeCredentials;
                found = true;
            }
        }
        if (!found) return error.CompilerBindingLifetimeCredentials;
    }

    fn namespace(self: *Kernel, pid: i32) Error![64]u8 {
        var path: [64]u8 = undefined;
        const name = std.mem.printSentinel(&path, "/proc/{d}/ns/pid", .{pid}, 0) catch return error.CompilerBindingLifetimeIo;
        var bytes: [64]u8 = @splat(0);
        try self.budget.tick();
        const count = linux.readlinkat(linux.AT.FDCWD, name.ptr, &bytes, bytes.len);
        if (linux.errno(count) != .SUCCESS or count == 0 or count >= bytes.len)
            return error.CompilerBindingLifetimeCredentials;
        return bytes;
    }

    fn executable(self: *Kernel, pid: i32) Error!Executable {
        var path: [64]u8 = undefined;
        const name = std.mem.printSentinel(&path, "/proc/{d}/exe", .{pid}, 0) catch return error.CompilerBindingLifetimeIo;
        var stat: linux.Statx = undefined;
        try self.budget.tick();
        if (linux.errno(linux.statx(linux.AT.FDCWD, name.ptr, 0, linux.STATX.BASIC_STATS, &stat)) != .SUCCESS)
            return error.CompilerBindingLifetimePeerChanged;
        if (!stat.mask.TYPE or !stat.mask.INO or !stat.mask.SIZE or !stat.mask.CTIME or !stat.mask.MTIME or
            stat.mode & linux.S.IFMT != linux.S.IFREG) return error.CompilerBindingLifetimePeerChanged;
        return .{
            .device_major = stat.dev_major,
            .device_minor = stat.dev_minor,
            .inode = stat.ino,
            .bytes = stat.size,
            .mtime = stat.mtime.sec,
            .mtime_ns = stat.mtime.nsec,
            .ctime = stat.ctime.sec,
            .ctime_ns = stat.ctime.nsec,
        };
    }

    fn proc(self: *Kernel, pid: i32, leaf: []const u8) Error![]const u8 {
        var path: [64]u8 = undefined;
        const name = std.mem.printSentinel(&path, "/proc/{d}/{s}", .{ pid, leaf }, 0) catch return error.CompilerBindingLifetimeIo;
        try self.budget.tick();
        const fd = try descriptor(linux.openat(linux.AT.FDCWD, name.ptr, .{ .CLOEXEC = true, .NOFOLLOW = true }, 0));
        defer _ = linux.close(fd);
        var length: usize = 0;
        while (length < self.workspace.proc_bytes.len) {
            try self.budget.tick();
            const count = linux.read(fd, self.workspace.proc_bytes[length..].ptr, self.workspace.proc_bytes.len - length);
            switch (linux.errno(count)) {
                .SUCCESS => {
                    if (count == 0) return self.workspace.proc_bytes[0..length];
                    length += count;
                    if (length > maximum_proc_bytes) return error.CompilerBindingLifetimeProcExceeded;
                },
                .INTR => {},
                else => return error.CompilerBindingLifetimePeerChanged,
            }
        }
        return error.CompilerBindingLifetimeProcExceeded;
    }
};

fn received(bytes: []const u8, ancillary: []const u8, flags: u32) Error!Received {
    var control: Control = .{};
    defer control.close();
    const credentials = try control.parse(ancillary);
    if (flags & (linux.MSG.TRUNC | linux.MSG.CTRUNC) != 0 or bytes.len != packet_bytes)
        return error.CompilerBindingLifetimeProtocol;
    return .{ .packet = try Packet.decode(bytes), .credentials = credentials };
}

/// The collector end of one barrier, for local integration tests only. It binds
/// one SEQPACKET listener and exchanges bounded packets. It never authenticates
/// its peer and is not the C7 admission collector.
pub const TestCollector = struct {
    listener: i32,
    connection: i32 = -1,

    const wait_ms = 15_000;

    pub fn listen(path: []const u8) Error!TestCollector {
        if (comptime builtin.os.tag != .linux) return error.CompilerBindingLifetimePlatform;
        var address: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len == 0 or path.len >= address.path.len) return error.CompilerBindingLifetimeEnvironment;
        @memcpy(address.path[0..path.len], path);
        const listener = try descriptor(linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0));
        errdefer _ = linux.close(listener);
        if (linux.errno(linux.bind(listener, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS or
            linux.errno(linux.listen(listener, 1)) != .SUCCESS) return error.CompilerBindingLifetimeIo;
        return .{ .listener = listener };
    }

    pub fn deinit(self: *TestCollector) void {
        if (self.connection >= 0) _ = linux.close(self.connection);
        _ = linux.close(self.listener);
        self.* = undefined;
    }

    pub fn accept(self: *TestCollector) Error!void {
        std.debug.assert(self.connection < 0);
        try readable(self.listener);
        self.connection = try descriptor(linux.accept4(self.listener, null, null, linux.SOCK.CLOEXEC));
    }

    pub fn receive(self: *TestCollector) Error!Packet {
        std.debug.assert(self.connection >= 0);
        try readable(self.connection);
        var bytes: [packet_bytes + 1]u8 = undefined;
        const length = linux.recvfrom(self.connection, &bytes, bytes.len, 0, null, null);
        if (linux.errno(length) != .SUCCESS) return error.CompilerBindingLifetimeIo;
        return Packet.decode(bytes[0..length]);
    }

    pub fn send(self: *TestCollector, packet: Packet) Error!void {
        std.debug.assert(self.connection >= 0);
        const bytes = packet.encode();
        const sent = linux.sendto(self.connection, &bytes, bytes.len, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(sent) != .SUCCESS or sent != bytes.len) return error.CompilerBindingLifetimeIo;
    }

    fn readable(socket: i32) Error!void {
        var fds = [_]linux.pollfd{.{ .fd = socket, .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const result = linux.poll(&fds, fds.len, wait_ms);
            switch (linux.errno(result)) {
                .SUCCESS => return if (result == 0) error.CompilerBindingLifetimeTimeout else {},
                .INTR => {},
                else => return error.CompilerBindingLifetimeIo,
            }
        }
    }
};

fn now() Error!u64 {
    var timestamp: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &timestamp)) != .SUCCESS or
        timestamp.sec < 0 or timestamp.nsec < 0 or timestamp.nsec >= std.time.ns_per_s)
        return error.CompilerBindingLifetimeClock;
    const seconds = std.math.mul(u64, @intCast(timestamp.sec), std.time.ns_per_s) catch return error.CompilerBindingLifetimeClock;
    return std.math.add(u64, seconds, @intCast(timestamp.nsec)) catch return error.CompilerBindingLifetimeClock;
}

fn descriptor(result: usize) Error!i32 {
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .MFILE, .NFILE => error.CompilerBindingLifetimeDescriptorsExceeded,
        else => error.CompilerBindingLifetimeIo,
    };
}

fn parseStat(expected: i32, bytes: []const u8) Error!Identity {
    const open = std.mem.indexOfScalar(u8, bytes, '(') orelse return error.CompilerBindingLifetimePeerChanged;
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.CompilerBindingLifetimePeerChanged;
    if (open < 2 or close <= open or close + 2 >= bytes.len or bytes[open - 1] != ' ' or bytes[close + 1] != ' ')
        return error.CompilerBindingLifetimePeerChanged;
    const pid = std.fmt.parseInt(i32, bytes[0 .. open - 1], 10) catch return error.CompilerBindingLifetimePeerChanged;
    if (pid != expected or pid <= 0) return error.CompilerBindingLifetimePeerChanged;
    var fields = std.mem.tokenizeScalar(u8, bytes[close + 2 ..], ' ');
    const state = fields.next() orelse return error.CompilerBindingLifetimePeerChanged;
    if (state.len != 1 or state[0] == 'Z' or state[0] == 'X') return error.CompilerBindingLifetimePeerChanged;
    const parent = std.fmt.parseInt(i32, fields.next() orelse return error.CompilerBindingLifetimePeerChanged, 10) catch
        return error.CompilerBindingLifetimePeerChanged;
    for (0..17) |_| _ = fields.next() orelse return error.CompilerBindingLifetimePeerChanged;
    const start = std.fmt.parseInt(u64, fields.next() orelse return error.CompilerBindingLifetimePeerChanged, 10) catch
        return error.CompilerBindingLifetimePeerChanged;
    if (start == 0 or parent < 0) return error.CompilerBindingLifetimePeerChanged;
    return .{ .pid = pid, .parent = parent, .start = start };
}

fn nibble(byte: u8) Error!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => error.CompilerBindingLifetimeEnvironment,
    };
}

fn zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test "binding exposure lifetime: absent configuration performs no work" {
    var workspace: Workspace = undefined;
    try barrier(null, &.{}, &workspace);
}

test "binding exposure lifetime: canonical environment and exact path bound" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const config = try Config.parse("unix1:/tmp/c7/socket:" ++ key);
    try std.testing.expectEqualStrings("/tmp/c7/socket", config.path);
    try std.testing.expectEqual(@as(u8, 0x01), config.session[0]);
    _ = try Config.parse("unix1:/" ++ @as([maximum_socket_path_bytes - 1]u8, @splat('a')) ++ ":" ++ key);
    try std.testing.expectError(error.CompilerBindingLifetimeEnvironment, Config.parse("unix1:/" ++ @as([maximum_socket_path_bytes]u8, @splat('a')) ++ ":" ++ key));
    for ([_][]const u8{
        "unix1:relative:" ++ key, "unix1:/a//b:" ++ key,                   "unix1:/a/../b:" ++ key,
        "unix1:/a/./b:" ++ key,   "unix1:/a/:" ++ key,                     "unix1:/:" ++ key,
        "unix1:/a b:" ++ key,     "unix1:/a\x00b:" ++ key,                 "unix1:/a\\b:" ++ key,
        "unix1:/a:b:" ++ key,     "unix1:/a:" ++ @as([64]u8, @splat('A')), "unix1:/a:" ++ @as([64]u8, @splat('0')),
        "unix2:/a:" ++ key,       "unix1:/a:" ++ key ++ "0",               &@as([maximum_environment_bytes + 1]u8, @splat('x')),
    }) |text| try std.testing.expectError(error.CompilerBindingLifetimeEnvironment, Config.parse(text));
}

test "binding exposure lifetime: packet has exact independent wire layout" {
    const packet: Packet = .{ .kind = .ready, .capture = @splat(0x11), .challenge = @splat(0x22), .digest = @splat(0x33), .value = 0x0102030405060708 };
    const bytes = packet.encode();
    try std.testing.expectEqualStrings("TC7LIF01\x03\x00\x00\x00\x00\x00\x00\x00", bytes[0..16]);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0x11))), bytes[16..48]);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0x22))), bytes[48..80]);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0x33))), bytes[80..112]);
    try std.testing.expectEqualSlices(u8, &.{ 8, 7, 6, 5, 4, 3, 2, 1 }, bytes[112..120]);
    try std.testing.expect(zero(bytes[120..]));
    try std.testing.expect(std.meta.eql(packet, try Packet.decode(&bytes)));
    for ([_]usize{ 0, 8, 12, 15, 120, 127 }) |index| {
        var bad = bytes;
        bad[index] = 255;
        try std.testing.expectError(error.CompilerBindingLifetimeProtocol, Packet.decode(&bad));
    }
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, Packet.decode(bytes[0..127]));
    var oversized: [packet_bytes + 1]u8 = @splat(0);
    @memcpy(oversized[0..packet_bytes], &bytes);
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, Packet.decode(&oversized));
}

test "binding exposure lifetime: state binds digest epoch nonce and receipt extent" {
    var exchange = try Exchange.init(@splat(1), "{}\n");
    const hello = exchange.hello();
    try std.testing.expect(hello.kind == .hello and zero(&hello.challenge) and hello.value == 3);
    var challenge = hello;
    challenge.kind = .challenge;
    challenge.capture = @splat(2);
    challenge.challenge = @splat(3);
    var wrong = challenge;
    wrong.digest[0] ^= 1;
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptChallenge(wrong));
    wrong = challenge;
    wrong.capture = hello.capture;
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptChallenge(wrong));
    const ready = try exchange.acceptChallenge(challenge);
    try std.testing.expect(ready.kind == .ready);
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptChallenge(challenge));
    var ack = ready;
    ack.kind = .ack;
    ack.digest = @splat(4);
    ack.value = maximum_snapshot_bytes;
    wrong = ack;
    wrong.challenge[0] ^= 1;
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptAck(wrong));
    wrong = ack;
    wrong.value += 1;
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptAck(wrong));
    try exchange.acceptAck(ack);
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptAck(ack));
}

test "binding exposure lifetime: deadline never extends across work or interruption" {
    var budget = try Budget.init(7);
    try std.testing.expectEqual(timeout_ns, try budget.check(7));
    try std.testing.expectEqual(@as(u64, 1), try budget.check(7 + timeout_ns - 1));
    try std.testing.expectError(error.CompilerBindingLifetimeTimeout, budget.check(7 + timeout_ns));
    budget = try Budget.init(7);
    budget.operations = maximum_operations;
    try std.testing.expectError(error.CompilerBindingLifetimeWorkExceeded, budget.check(7));
    try std.testing.expectError(error.CompilerBindingLifetimeClock, Budget.init(std.math.maxInt(u64)));
}

test "binding exposure lifetime: announcement and snapshot bounds reject the next byte" {
    var bytes: [maximum_announcement_bytes + 1]u8 = @splat(' ');
    bytes[maximum_announcement_bytes - 1] = '\n';
    _ = try Exchange.init(@splat(1), bytes[0..maximum_announcement_bytes]);
    bytes[maximum_announcement_bytes] = '\n';
    try std.testing.expectError(error.CompilerBindingLifetimeAnnouncement, Exchange.init(@splat(1), &bytes));
    try std.testing.expectError(error.CompilerBindingLifetimeAnnouncement, Exchange.init(@splat(1), "{}"));
    var exchange = try Exchange.init(@splat(1), "{}\n");
    var challenge = exchange.hello();
    challenge.kind = .challenge;
    challenge.capture = @splat(2);
    challenge.challenge = @splat(3);
    var ack = try exchange.acceptChallenge(challenge);
    ack.kind = .ack;
    ack.value = 0;
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptAck(ack));
    ack.value = maximum_snapshot_bytes + 1;
    try std.testing.expectError(error.CompilerBindingLifetimeProtocol, exchange.acceptAck(ack));
    ack.value = maximum_snapshot_bytes;
    try exchange.acceptAck(ack);
}

test "binding exposure lifetime: proc stat handles parentheses and refuses changed identity" {
    const stat = "42 (name with ) inside) S 41 " ++ "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 " ++ "123 0\n";
    const parsed = try parseStat(42, stat);
    try std.testing.expectEqual(@as(i32, 41), parsed.parent);
    try std.testing.expectEqual(@as(u64, 123), parsed.start);
    try std.testing.expectError(error.CompilerBindingLifetimePeerChanged, parseStat(43, stat));
    try std.testing.expectError(error.CompilerBindingLifetimePeerChanged, parseStat(42, "42 (dead) Z 41 " ++ "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 " ++ "123 0\n"));
    try std.testing.expectError(error.CompilerBindingLifetimePeerChanged, parseStat(42, "42 (short) S 41"));
    try std.testing.expect(!parsed.same(.{ .pid = 42, .parent = 1, .start = 123 }));
    try std.testing.expect(!parsed.same(.{ .pid = 42, .parent = 41, .start = 124 }));
}

test "binding exposure lifetime: kernel ancillary credentials are exact and rights are retained for close" {
    var bytes: [maximum_control_bytes]u8 = @splat(0);
    const size = @sizeOf(linux.cmsghdr);
    const header: linux.cmsghdr = .{ .len = size + @sizeOf(Credentials), .level = linux.SOL.SOCKET, .type = linux.SCM.CREDENTIALS };
    const credentials: Credentials = .{ .pid = 42, .uid = 1000, .gid = 1000 };
    @memcpy(bytes[0..size], std.mem.asBytes(&header));
    @memcpy(bytes[size..][0..@sizeOf(Credentials)], std.mem.asBytes(&credentials));
    const aligned = std.mem.alignForward(usize, header.len, @sizeOf(usize));
    var control: Control = .{};
    try std.testing.expect(credentials.same(try control.parse(bytes[0..aligned])));
    @memcpy(bytes[aligned..][0..aligned], bytes[0..aligned]);
    control = .{};
    try std.testing.expectError(error.CompilerBindingLifetimeCredentials, control.parse(bytes[0 .. 2 * aligned]));
    const rights: linux.cmsghdr = .{ .len = size + @sizeOf(i32), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
    const fd: i32 = 99;
    @memcpy(bytes[0..size], std.mem.asBytes(&rights));
    @memcpy(bytes[size..][0..@sizeOf(i32)], std.mem.asBytes(&fd));
    control = .{};
    try std.testing.expectError(error.CompilerBindingLifetimeCredentials, control.parse(bytes[0..std.mem.alignForward(usize, rights.len, @sizeOf(usize))]));
    try std.testing.expectEqual(@as(usize, 1), control.count);
    try std.testing.expectEqual(fd, control.rights[0]);
}

test "binding exposure lifetime: refused real rights and truncated rights close every delivered fd" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var sockets: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &sockets,
    )));
    defer for (sockets) |fd| {
        _ = linux.close(fd);
    };
    var pipe: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer for (pipe) |fd| {
        _ = linux.close(fd);
    };
    const enabled: i32 = 1;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.setsockopt(
        sockets[1],
        linux.SOL.SOCKET,
        linux.SO.PASSCRED,
        std.mem.asBytes(&enabled),
        @sizeOf(i32),
    )));
    const packet: Packet = .{ .kind = .ack, .capture = @splat(2), .challenge = @splat(3), .digest = @splat(4), .value = 1 };
    const bytes = packet.encode();
    const header_size = @sizeOf(linux.cmsghdr);
    for ([_]usize{ 1, 16 }) |count| {
        var send_control: [128]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
        const header: linux.cmsghdr = .{ .len = header_size + count * @sizeOf(i32), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        @memcpy(send_control[0..header_size], std.mem.asBytes(&header));
        for (0..count) |i| @memcpy(send_control[header_size + i * @sizeOf(i32) ..][0..@sizeOf(i32)], std.mem.asBytes(&pipe[0]));
        var send_vector: std.posix.iovec_const = .{ .base = &bytes, .len = bytes.len };
        const outgoing: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = (&send_vector)[0..1],
            .iovlen = 1,
            .control = &send_control,
            .controllen = std.mem.alignForward(usize, header.len, @sizeOf(usize)),
            .flags = 0,
        };
        try std.testing.expectEqual(@as(usize, packet_bytes), linux.sendmsg(sockets[0], &outgoing, linux.MSG.NOSIGNAL));
        var raw: [packet_bytes]u8 = undefined;
        var control_bytes: [maximum_control_bytes]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var vector: std.posix.iovec = .{ .base = &raw, .len = raw.len };
        var incoming: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = (&vector)[0..1],
            .iovlen = 1,
            .control = &control_bytes,
            .controllen = control_bytes.len,
            .flags = 0,
        };
        try std.testing.expectEqual(@as(usize, packet_bytes), linux.recvmsg(sockets[1], &incoming, linux.MSG.CMSG_CLOEXEC));
        var preview: Control = .{};
        var transferred = false;
        defer if (!transferred) preview.close();
        try std.testing.expectError(error.CompilerBindingLifetimeCredentials, preview.parse(control_bytes[0..incoming.controllen]));
        try std.testing.expect(preview.count > 0 and preview.count <= count);
        try std.testing.expectEqual(count == 16, incoming.flags & linux.MSG.CTRUNC != 0);
        for (preview.rights[0..preview.count]) |fd| {
            const flags = linux.fcntl(fd, linux.F.GETFD, 0);
            try std.testing.expect(linux.errno(flags) == .SUCCESS and flags & linux.FD_CLOEXEC != 0);
        }
        transferred = true;
        try std.testing.expectError(error.CompilerBindingLifetimeCredentials, received(&raw, control_bytes[0..incoming.controllen], incoming.flags));
        for (preview.rights[0..preview.count]) |fd| {
            try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
        }
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(pipe[0], linux.F.GETFD, 0)));
    }
}
