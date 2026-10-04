const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const fd = @import("fd.zig");
const random = @import("random.zig");

const linux = std.os.linux;
const posix = std.posix;
const system = posix.system;
const native_os = builtin.os.tag;

pub const required_capabilities = switch (native_os) {
    .linux => capabilities.noLibc(&.{ .networking, .descriptors, .process, .random, .time }),
    else => capabilities.host(&.{ .networking, .descriptors, .process, .random, .time }),
};

pub const Socket = posix.socket_t;
pub const Ip4Address = posix.sockaddr.in;
pub const Ip6Address = posix.sockaddr.in6;
pub const IpAddress = union(enum) {
    ip4: Ip4Address,
    ip6: Ip6Address,
};
pub const SocketAddress = posix.sockaddr;
pub const SocketAddressLength = posix.socklen_t;
pub const unix_path_capacity = @sizeOf(@FieldType(posix.sockaddr.un, "path"));
pub const readiness_max: usize = 64;

const readable_mask = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;
const writable_mask = posix.POLL.OUT | posix.POLL.HUP | posix.POLL.ERR;

pub const PollInterest = enum {
    read,
    write,
};

const AddressStorage = extern union {
    storage: posix.sockaddr.storage,
    any: SocketAddress,
    ip4: Ip4Address,
    ip6: Ip6Address,
    unix: posix.sockaddr.un,
};

pub const SocketOptions = struct {
    nonblocking: bool = false,
    close_on_exec: bool = false,
};

pub const SocketPolicy = enum {
    unsupported,
    linux_syscall,
    posix_host,
};

pub const PeerCredentialsPolicy = enum {
    unsupported,
    linux_so_peercred,
};

pub const PeerCredentials = extern struct {
    process_id: linux.pid_t,
    user_id: linux.uid_t,
    group_id: linux.gid_t,
};

pub const SocketError = error{
    UnsupportedPlatform,
    AddressFamilyUnsupported,
    ProtocolUnsupportedBySystem,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    SocketFailed,
};

pub const AddressError = error{InvalidAddress};
pub const UnixAddressError = error{InvalidPath};

pub const Address = struct {
    storage: AddressStorage,
    len: SocketAddressLength,

    pub const ListenOptions = struct {
        backlog: u32 = 128,
        reuse_address: bool = false,
        nonblocking: bool = false,
        close_on_exec: bool = true,
    };

    pub const ListenAddressError = SocketError || SetOptionError || BindError || ListenError || SocketNameError;

    pub fn empty() Address {
        return .{
            .storage = undefined,
            .len = @intCast(@sizeOf(posix.sockaddr.storage)),
        };
    }

    pub fn parseIp(host: []const u8, port: u16) AddressError!Address {
        return fromIpAddress(try ipAddressForHost(host, port));
    }

    pub fn parseIp4(host: []const u8, port: u16) AddressError!Address {
        return fromIp4Address(try ip4AddressForHost(host, port));
    }

    pub fn fromIpAddress(address: IpAddress) Address {
        return switch (address) {
            .ip4 => |ip4| fromIp4Address(ip4),
            .ip6 => |ip6| fromIp6Address(ip6),
        };
    }

    pub fn fromIp4Address(address: Ip4Address) Address {
        var result = Address{
            .storage = undefined,
            .len = @intCast(@sizeOf(Ip4Address)),
        };
        result.storage.ip4 = address;
        return result;
    }

    pub fn fromIp6Address(address: Ip6Address) Address {
        var result = Address{
            .storage = undefined,
            .len = @intCast(@sizeOf(Ip6Address)),
        };
        result.storage.ip6 = address;
        return result;
    }

    pub fn initUnix(path: []const u8) UnixAddressError!Address {
        var result = Address{
            .storage = undefined,
            .len = undefined,
        };
        if (path.len > result.storage.unix.path.len) return error.InvalidPath;
        result.storage.unix.family = posix.AF.UNIX;
        @memset(&result.storage.unix.path, 0);
        @memcpy(result.storage.unix.path[0..path.len], path);
        const path_len = if (path.len < result.storage.unix.path.len) path.len + 1 else path.len;
        result.len = @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len);
        return result;
    }

    pub fn initUnixAbstract(name: []const u8) UnixAddressError!Address {
        var result = Address{
            .storage = undefined,
            .len = undefined,
        };
        if (name.len + 1 > result.storage.unix.path.len) return error.InvalidPath;
        result.storage.unix.family = posix.AF.UNIX;
        @memset(&result.storage.unix.path, 0);
        @memcpy(result.storage.unix.path[1 .. 1 + name.len], name);
        result.len = @intCast(@offsetOf(posix.sockaddr.un, "path") + 1 + name.len);
        return result;
    }

    pub fn family(self: *const Address) u32 {
        return @intCast(self.storage.any.family);
    }

    pub fn socketAddress(self: *const Address) *const SocketAddress {
        return &self.storage.any;
    }

    pub fn mutableSocketAddress(self: *Address) *SocketAddress {
        return &self.storage.any;
    }

    pub fn socketAddressLen(self: *const Address) SocketAddressLength {
        return self.len;
    }

    pub fn ipAddress(self: *const Address) ?IpAddress {
        return socketAddressToIpAddress(&self.storage.storage, self.len);
    }

    pub fn ip4Bytes(self: *const Address) ?[4]u8 {
        return switch (self.ipAddress() orelse return null) {
            .ip4 => |ip4| @bitCast(ip4.addr),
            .ip6 => null,
        };
    }

    pub fn getPort(self: *const Address) u16 {
        return ipAddressPort(self.ipAddress() orelse return 0);
    }

    pub fn listen(address: Address, options: ListenOptions) ListenAddressError!Server {
        const socket_fd = try streamSocket(address.family(), .{
            .close_on_exec = options.close_on_exec,
            .nonblocking = options.nonblocking,
        });
        errdefer close(socket_fd);

        if (options.reuse_address and isInetFamily(address.family())) {
            try setReuseAddress(socket_fd);
        }

        try bind(socket_fd, address.socketAddress(), address.socketAddressLen());
        try startListening(socket_fd, options.backlog);

        var listen_address = Address.empty();
        try readSocketAddress(socket_fd, &listen_address);

        return .{
            .socket = socket_fd,
            .listen_address = listen_address,
        };
    }
};

pub const Stream = struct {
    handle: Socket,

    pub fn initFd(socket_fd: Socket) Stream {
        return .{ .handle = socket_fd };
    }

    pub fn read(self: Stream, buffer: []u8) RecvError!usize {
        return recv(self.handle, buffer, 0);
    }

    pub fn write(self: Stream, bytes: []const u8) SendError!usize {
        const written = try sendNoSignal(self.handle, bytes);
        if (bytes.len != 0 and written == 0) return error.BrokenPipe;
        return written;
    }

    pub fn writeAll(self: Stream, bytes: []const u8) SendError!void {
        var written: usize = 0;
        while (written < bytes.len) {
            written += try self.write(bytes[written..]);
        }
    }

    pub fn close(self: Stream) void {
        fd.close(self.handle);
    }
};

pub const AcceptedStream = struct {
    stream: Stream,
    address: Address,
};

pub const Server = struct {
    socket: Socket,
    listen_address: Address,

    pub fn accept(self: *Server) AcceptError!AcceptedStream {
        var address = Address.empty();
        const accepted = try acceptSocket(
            self.socket,
            address.mutableSocketAddress(),
            &address.len,
            posix.SOCK.CLOEXEC,
        );
        return .{
            .stream = Stream.initFd(accepted),
            .address = address,
        };
    }

    pub fn deinit(self: *Server) void {
        fd.close(self.socket);
        self.* = undefined;
    }
};

pub const StreamConnectError = SocketError || ConnectError;

pub const BindError = error{
    UnsupportedPlatform,
    AddressInUse,
    BindFailed,
};

pub const ListenError = error{
    UnsupportedPlatform,
    ListenFailed,
};

pub const AcceptError = error{
    UnsupportedPlatform,
    WouldBlock,
    ConnectionAborted,
    ConnectionResetByPeer,
    FileDescriptorNotASocket,
    SocketNotListening,
    AcceptFailed,
};

pub const ConnectError = error{
    UnsupportedPlatform,
    WouldBlock,
    ConnectionRefused,
    ConnectionTimedOut,
    HostUnreachable,
    NetworkUnreachable,
    ConnectFailed,
};

pub const SendError = error{
    UnsupportedPlatform,
    WouldBlock,
    BrokenPipe,
    BadFileDescriptor,
    ConnectionResetByPeer,
    MessageTooLarge,
    SendFailed,
};

pub const RecvError = error{
    UnsupportedPlatform,
    WouldBlock,
    BadFileDescriptor,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    ReceiveFailed,
};

pub const SetOptionError = error{
    UnsupportedPlatform,
    InvalidArgument,
    SetOptionFailed,
};

pub const PeerCredentialsError = error{
    UnsupportedPlatform,
    BadFileDescriptor,
    FileDescriptorNotASocket,
    SocketNotConnected,
    PeerCredentialsUnavailable,
};

pub const SocketNameError = error{
    UnsupportedPlatform,
    SocketNameFailed,
};

pub const PollError = error{
    UnsupportedPlatform,
    PollFailed,
};

pub const ReceivedDatagram = struct {
    address: IpAddress,
    bytes: usize,
    truncated: bool,
};

/// Runs one worker's socket operations for one request under a deadline, a
/// cancellation flag, and a byte budget, so another thread can stop the work
/// and the work ends at a time the caller picked. The caller keeps the control
/// pinned and its deadline unchanged until the worker returns, and `cancel` may
/// be called from another thread. Because one worker owns every descriptor the
/// control touches, cancellation ends the wait and leaves the descriptor open,
/// so a descriptor another thread has since reused is never closed under it.
/// `check` fails with `Canceled` after a cancel and with `DeadlineExceeded`
/// past the deadline, and keeps the first failure in `failure`, while a send or
/// a receive past the byte budget fails with `TransferCapacityExceeded`.
pub const Control = struct {
    deadline_ns: u64,
    cancelled: std.atomic.Value(bool) = .init(false),
    bytes_remaining: u64,
    failure: ?Failure = null,

    pub const Failure = error{ Canceled, DeadlineExceeded, TransferCapacityExceeded };
    pub const poll_quantum_ms = 10;
    pub const DnsFamily = enum { ip4, ip6 };

    pub fn cancel(self: *Control) void {
        self.cancelled.store(true, .release);
    }

    pub fn check(self: *Control) !void {
        if (self.cancelled.load(.acquire)) return self.fail(error.Canceled);
        if (try clock() >= self.deadline_ns) return self.fail(error.DeadlineExceeded);
    }

    pub fn clock() !u64 {
        return (try @import("root.zig").time.awakeNow()).asNanoseconds();
    }

    fn fail(self: *Control, failure: Failure) Failure {
        self.failure = failure;
        return failure;
    }

    fn window(self: *Control, length: usize) !usize {
        try self.check();
        if (self.bytes_remaining == 0) return self.fail(error.TransferCapacityExceeded);
        return @intCast(@min(length, self.bytes_remaining));
    }

    /// Keeps cancellation and the deadline responsive during every blocking
    /// step of a controlled operation by polling the socket for one quantum at
    /// a time, and returns to the cancellation and deadline checks after each
    /// slice and after an interruption. A quantum runs ten milliseconds,
    /// shortened when less time than that remains before the deadline.
    fn wait(self: *Control, socket_fd: Socket, writable: bool) !void {
        if (comptime !supported()) return error.UnsupportedPlatform;
        while (true) {
            try self.check();
            const remaining = self.deadline_ns -| try clock();
            const millis: i32 = @intCast(@min(poll_quantum_ms, remaining / 1000000 + @intFromBool(remaining % 1000000 != 0)));
            var descriptor = posix.pollfd{
                .fd = socket_fd,
                .events = if (writable) posix.POLL.OUT else posix.POLL.IN,
                .revents = 0,
            };
            const rc = linux.poll(@ptrCast(&descriptor), 1, millis);
            const ready = switch (linux.errno(rc)) {
                .SUCCESS => rc != 0,
                .INTR => false,
                else => return error.PollFailed,
            };
            try self.check();
            if (ready) return;
        }
    }

    /// Reports whether this host carries the controlled descriptor and bounded
    /// entropy implementation, which is the native Linux one. Where this is
    /// false, every operation on a control returns `UnsupportedPlatform`.
    pub fn supported() bool {
        return native_os == .linux;
    }

    /// Draws random bytes for the resolver's query identifier under the same
    /// deadline as the rest of the request, filling `output` with kernel random
    /// bytes and rechecking cancellation and the deadline between reads. The
    /// read asks with `GRND_NONBLOCK`, so boot entropy that the kernel has yet
    /// to gather fails with `EntropyUnavailable` and the call returns inside
    /// the deadline.
    pub fn entropy(self: *Control, output: []u8) !void {
        if (comptime !supported()) return error.UnsupportedPlatform;
        var offset: usize = 0;
        while (offset < output.len) {
            try self.check();
            const rc = linux.getrandom(output[offset..].ptr, output.len - offset, 1);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.EntropyUnavailable;
                    offset += rc;
                },
                .INTR => {},
                else => return error.EntropyUnavailable,
            }
        }
        try self.check();
    }

    /// Opens the request's socket so that the open itself sits under the
    /// deadline, creating a TCP socket for the address family of `address`,
    /// close-on-exec and nonblocking. The descriptor belongs to the operation
    /// that asked for it, and the caller closes it.
    pub fn open(self: *Control, address: IpAddress) !Socket {
        if (comptime !supported()) return error.UnsupportedPlatform;
        while (true) {
            try self.check();
            const family: u32 = if (address == .ip4) linux.AF.INET else linux.AF.INET6;
            const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    const result: Socket = @intCast(rc);
                    errdefer close(result);
                    try self.check();
                    return result;
                },
                .INTR => {},
                else => return error.SocketFailed,
            }
        }
    }

    fn nonblocking(self: *Control, socket_fd: Socket) !void {
        const flags = while (true) {
            try self.check();
            const rc = linux.fcntl(socket_fd, linux.F.GETFL, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => {},
                else => return error.FlagUpdateFailed,
            }
        };
        while (true) {
            try self.check();
            const rc = linux.fcntl(socket_fd, linux.F.SETFL, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
            switch (linux.errno(rc)) {
                .SUCCESS => return,
                .INTR => {},
                else => return error.FlagUpdateFailed,
            }
        }
    }

    pub fn connectTo(self: *Control, socket_fd: Socket, address: IpAddress) !void {
        if (comptime !supported()) return error.UnsupportedPlatform;
        try self.check();
        try self.nonblocking(socket_fd);
        const rc = switch (address) {
            .ip4 => |ip| linux.connect(socket_fd, @ptrCast(&ip), @sizeOf(Ip4Address)),
            .ip6 => |ip| linux.connect(socket_fd, @ptrCast(&ip), @sizeOf(Ip6Address)),
        };
        switch (linux.errno(rc)) {
            .SUCCESS, .ISCONN => {},
            .INTR, .AGAIN, .INPROGRESS, .ALREADY => {
                try self.wait(socket_fd, true);
                try connectionStatus(socket_fd);
            },
            else => return error.ConnectFailed,
        }
        try self.check();
    }

    pub fn receive(self: *Control, socket_fd: Socket, output: []u8) !usize {
        if (comptime !supported()) return error.UnsupportedPlatform;
        std.debug.assert(output.len > 0);
        while (true) {
            const length = try self.window(output.len);
            const rc = linux.recvfrom(socket_fd, output.ptr, length, linux.MSG.DONTWAIT, null, null);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    self.bytes_remaining -= rc;
                    try self.check();
                    return rc;
                },
                .INTR => {},
                .AGAIN => try self.wait(socket_fd, false),
                else => return error.ReceiveFailed,
            }
        }
    }

    pub fn transmit(self: *Control, socket_fd: Socket, input: []const u8) !usize {
        if (comptime !supported()) return error.UnsupportedPlatform;
        std.debug.assert(input.len > 0);
        while (true) {
            const length = try self.window(input.len);
            const rc = linux.sendto(socket_fd, input.ptr, length, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.BrokenPipe;
                    self.bytes_remaining -= rc;
                    try self.check();
                    return rc;
                },
                .INTR => {},
                .AGAIN => try self.wait(socket_fd, true),
                else => return error.SendFailed,
            }
        }
    }

    fn transmitAll(self: *Control, socket_fd: Socket, input: []const u8) !void {
        var offset: usize = 0;
        while (offset < input.len) offset += try self.transmit(socket_fd, input[offset..]);
    }

    fn receiveExact(self: *Control, socket_fd: Socket, output: []u8) !void {
        var offset: usize = 0;
        while (offset < output.len) {
            const count = try self.receive(socket_fd, output[offset..]);
            if (count == 0) return error.MalformedResponse;
            offset += count;
        }
    }

    /// Puts one DNS question to `nameserver` over TCP and returns the answer
    /// address with `port` set, and `family` picks an A question or an AAAA
    /// question. The question carries a random sixteen-bit identifier drawn
    /// through `entropy`, and the response is matched against the question
    /// before any address is taken. One question goes out and one answer comes
    /// back: no search domain is appended, no second nameserver is tried, and
    /// no retry follows a failure, all of which `resolveIpAddressForHost` does.
    /// A response longer than 4096 bytes, and one the server marks truncated,
    /// both fail with `QueryTooLarge`, while the request and response buffers
    /// are wiped before the call returns.
    pub fn resolve(
        self: *Control,
        host: []const u8,
        port: u16,
        nameserver: IpAddress,
        family: DnsFamily,
    ) !IpAddress {
        try self.check();
        var request: [514]u8 = undefined;
        defer std.crypto.secureZero(u8, &request);
        var entropy_bytes: [2]u8 = undefined;
        try self.entropy(&entropy_bytes);
        const id = std.mem.readInt(u16, &entropy_bytes, .big);
        const encoded = try dnsQuery(request[2..], host, if (family == .ip4) .a else .aaaa, id);
        std.mem.writeInt(u16, request[0..2], @intCast(encoded.len), .big);
        const socket_fd = try self.open(nameserver);
        defer close(socket_fd);
        try self.connectTo(socket_fd, nameserver);
        try self.transmitAll(socket_fd, request[0 .. encoded.len + 2]);
        var size: [2]u8 = undefined;
        try self.receiveExact(socket_fd, &size);
        const length = std.mem.readInt(u16, &size, .big);
        var response: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &response);
        if (length == 0 or length > response.len) return error.QueryTooLarge;
        try self.receiveExact(socket_fd, response[0..length]);
        if (try dnsResponseTruncated(response[0..length], encoded.question)) return error.QueryTooLarge;
        return dnsAddressFromResponse(response[0..length], encoded.question, port);
    }
};

fn connectionStatus(socket_fd: Socket) !void {
    if (comptime !Control.supported()) return error.UnsupportedPlatform;
    var value: c_int = 0;
    var length: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(socket_fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&value), &length);
    if (linux.errno(rc) != .SUCCESS or length != @sizeOf(c_int) or value != 0)
        return error.ConnectFailed;
}

pub const ResolveOptions = struct {
    hosts_path: ?[]const u8 = "/etc/hosts",
    nameservers: []const IpAddress = &.{},
    timeout_ms: u32 = 1500,
};

const ResolveLocalError = error{
    InvalidHostName,
    MalformedResponse,
    NoAddress,
    NoNameserver,
    QueryTooLarge,
};

pub const ResolveError =
    AddressError ||
    random.SecureError ||
    SocketError ||
    ConnectError ||
    SendError ||
    RecvError ||
    SetOptionError ||
    ResolveLocalError;

const dns_max_name_len = 253;
const default_ndots = 1;
const DnsRecordType = enum(u16) {
    a = 1,
    aaaa = 28,
};
const socket_flags_unsupported = switch (native_os) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .haiku => true,
    else => false,
};
const accept4_unsupported = socket_flags_unsupported;

pub fn socketPolicy() SocketPolicy {
    return switch (native_os) {
        .windows, .wasi, .freestanding => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
}

pub fn close(socket_fd: Socket) void {
    fd.close(socket_fd);
}

pub fn shutdownReadWrite(socket_fd: Socket) void {
    switch (socketPolicy()) {
        .unsupported => {},
        .linux_syscall => shutdownReadWriteLinux(socket_fd),
        .posix_host => shutdownReadWritePosix(socket_fd),
    }
}

pub fn tcpStreamSocket(options: SocketOptions) SocketError!Socket {
    return streamSocket(posix.AF.INET, options);
}

pub fn tcpStreamSocketForAddress(address: IpAddress, options: SocketOptions) SocketError!Socket {
    return streamSocket(addressFamily(address), options);
}

pub fn unixStreamSocket(options: SocketOptions) SocketError!Socket {
    return streamSocket(posix.AF.UNIX, options);
}

pub fn udpDatagramSocket(options: SocketOptions) SocketError!Socket {
    return udpDatagramSocketForFamily(posix.AF.INET, options);
}

pub fn udpDatagramSocketForAddress(address: IpAddress, options: SocketOptions) SocketError!Socket {
    return udpDatagramSocketForFamily(addressFamily(address), options);
}

fn udpDatagramSocketForFamily(family: u32, options: SocketOptions) SocketError!Socket {
    var socket_type: u32 = posix.SOCK.DGRAM;
    if (options.nonblocking and !socket_flags_unsupported) socket_type |= posix.SOCK.NONBLOCK;
    if (options.close_on_exec and !socket_flags_unsupported) socket_type |= posix.SOCK.CLOEXEC;

    const socket_fd = try socket(family, socket_type, posix.IPPROTO.UDP);
    errdefer close(socket_fd);

    if (options.nonblocking and socket_flags_unsupported) {
        fd.setNonBlocking(socket_fd) catch return error.SocketFailed;
    }
    if (options.close_on_exec and socket_flags_unsupported) {
        fd.setCloseOnExec(socket_fd) catch return error.SocketFailed;
    }

    return socket_fd;
}

fn addressFamily(address: IpAddress) u32 {
    return switch (address) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
}

pub fn streamSocket(domain: u32, options: SocketOptions) SocketError!Socket {
    var socket_type: u32 = posix.SOCK.STREAM;
    if (options.nonblocking and !socket_flags_unsupported) socket_type |= posix.SOCK.NONBLOCK;
    if (options.close_on_exec and !socket_flags_unsupported) socket_type |= posix.SOCK.CLOEXEC;

    const socket_fd = try socket(domain, socket_type, 0);
    errdefer close(socket_fd);

    if (options.nonblocking and socket_flags_unsupported) {
        fd.setNonBlocking(socket_fd) catch return error.SocketFailed;
    }
    if (options.close_on_exec and socket_flags_unsupported) {
        fd.setCloseOnExec(socket_fd) catch return error.SocketFailed;
    }

    return socket_fd;
}

pub fn isInetFamily(family: u32) bool {
    return family == posix.AF.INET or family == posix.AF.INET6;
}

pub fn isIp4Family(family: u32) bool {
    return family == posix.AF.INET;
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!Socket {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => socketLinux(domain, socket_type, protocol),
        .posix_host => socketPosix(domain, socket_type, protocol),
    };
}

fn socketLinux(domain: u32, socket_type: u32, protocol: u32) SocketError!Socket {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const rc = linux.socket(domain, socket_type, protocol);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => return error.SocketFailed,
        }
    }
}

fn socketPosix(domain: u32, socket_type: u32, protocol: u32) SocketError!Socket {
    if (!@hasDecl(system, "socket") or @TypeOf(system.socket) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.socket(domain, socket_type, protocol);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => return error.SocketFailed,
        }
    }
}

pub fn socketPairUnixStream() fd.SocketPairError![2]Socket {
    return fd.socketPairUnixStream(.{ .close_on_exec = true });
}

pub fn send(socket_fd: Socket, bytes: []const u8, flags: u32) SendError!usize {
    return sendTo(socket_fd, bytes, flags, null, 0);
}

pub fn sendTo(
    socket_fd: Socket,
    bytes: []const u8,
    flags: u32,
    address: ?*const SocketAddress,
    len: SocketAddressLength,
) SendError!usize {
    if (bytes.len == 0) return 0;
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => sendToLinux(socket_fd, bytes, flags, address, len),
        .posix_host => sendToPosix(socket_fd, bytes, flags, address, len),
    };
}

fn sendToLinux(
    socket_fd: Socket,
    bytes: []const u8,
    flags: u32,
    address: ?*const SocketAddress,
    len: SocketAddressLength,
) SendError!usize {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const linux_address: ?*const linux.sockaddr = if (address) |ptr| @ptrCast(ptr) else null;
        const rc = linux.sendto(socket_fd, bytes.ptr, bytes.len, flags, linux_address, len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .BADF => return error.BadFileDescriptor,
            .CONNRESET => return error.ConnectionResetByPeer,
            .MSGSIZE => return error.MessageTooLarge,
            else => return error.SendFailed,
        }
    }
}

fn sendToPosix(
    socket_fd: Socket,
    bytes: []const u8,
    flags: u32,
    address: ?*const SocketAddress,
    len: SocketAddressLength,
) SendError!usize {
    if (!@hasDecl(system, "sendto") or @TypeOf(system.sendto) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.sendto(socket_fd, bytes.ptr, bytes.len, flags, address, len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .BADF => return error.BadFileDescriptor,
            .CONNRESET => return error.ConnectionResetByPeer,
            .MSGSIZE => return error.MessageTooLarge,
            else => return error.SendFailed,
        }
    }
}

pub fn sendNoSignal(socket_fd: Socket, bytes: []const u8) SendError!usize {
    return send(socket_fd, bytes, noSignalFlag());
}

pub fn sendToIpAddress(socket_fd: Socket, bytes: []const u8, flags: u32, address: IpAddress) SendError!usize {
    return switch (address) {
        .ip4 => |ip4| sendTo(socket_fd, bytes, flags, @ptrCast(&ip4), @sizeOf(Ip4Address)),
        .ip6 => |ip6| sendTo(socket_fd, bytes, flags, @ptrCast(&ip6), @sizeOf(Ip6Address)),
    };
}

pub fn recv(socket_fd: Socket, buffer: []u8, flags: u32) RecvError!usize {
    return recvFrom(socket_fd, buffer, flags, null, null);
}

pub fn recvFrom(
    socket_fd: Socket,
    buffer: []u8,
    flags: u32,
    address: ?*SocketAddress,
    len: ?*SocketAddressLength,
) RecvError!usize {
    if (buffer.len == 0) return 0;
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => recvFromLinux(socket_fd, buffer, flags, address, len),
        .posix_host => recvFromPosix(socket_fd, buffer, flags, address, len),
    };
}

fn recvFromLinux(
    socket_fd: Socket,
    buffer: []u8,
    flags: u32,
    address: ?*SocketAddress,
    len: ?*SocketAddressLength,
) RecvError!usize {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const linux_address: ?*linux.sockaddr = if (address) |ptr| @ptrCast(ptr) else null;
        const rc = linux.recvfrom(socket_fd, buffer.ptr, buffer.len, flags, linux_address, len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.BadFileDescriptor,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => return error.ReceiveFailed,
        }
    }
}

fn recvFromPosix(
    socket_fd: Socket,
    buffer: []u8,
    flags: u32,
    address: ?*SocketAddress,
    len: ?*SocketAddressLength,
) RecvError!usize {
    if (!@hasDecl(system, "recvfrom") or @TypeOf(system.recvfrom) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.recvfrom(socket_fd, buffer.ptr, buffer.len, flags, address, len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.BadFileDescriptor,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => return error.ReceiveFailed,
        }
    }
}

pub fn recvFromIpAddress(socket_fd: Socket, buffer: []u8, flags: u32) RecvError!ReceivedDatagram {
    var address: posix.sockaddr.storage = undefined;
    var len: SocketAddressLength = @sizeOf(posix.sockaddr.storage);
    const reported = try recvFrom(
        socket_fd,
        buffer,
        flags | receiveTruncationFlag(),
        @ptrCast(&address),
        &len,
    );
    return .{
        .address = socketAddressToIpAddress(&address, len) orelse return error.ReceiveFailed,
        .bytes = @min(reported, buffer.len),
        .truncated = if (comptime native_os == .linux)
            reported > buffer.len
        else
            reported == buffer.len,
    };
}

pub fn bindIp4(socket_fd: Socket, address: Ip4Address) BindError!void {
    return bind(socket_fd, @ptrCast(&address), @sizeOf(Ip4Address));
}

pub fn bindIp6(socket_fd: Socket, address: Ip6Address) BindError!void {
    return bind(socket_fd, @ptrCast(&address), @sizeOf(Ip6Address));
}

pub fn bindIpAddress(socket_fd: Socket, address: IpAddress) BindError!void {
    return switch (address) {
        .ip4 => |ip4| bindIp4(socket_fd, ip4),
        .ip6 => |ip6| bindIp6(socket_fd, ip6),
    };
}

pub fn bind(socket_fd: Socket, address: *const SocketAddress, len: SocketAddressLength) BindError!void {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => bindLinux(socket_fd, address, len),
        .posix_host => bindPosix(socket_fd, address, len),
    };
}

fn bindLinux(socket_fd: Socket, address: *const SocketAddress, len: SocketAddressLength) BindError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    const linux_address: *const linux.sockaddr = @ptrCast(address);
    while (true) {
        const rc = linux.bind(socket_fd, linux_address, len);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ADDRINUSE => return error.AddressInUse,
            else => return error.BindFailed,
        }
    }
}

fn bindPosix(socket_fd: Socket, address: *const SocketAddress, len: SocketAddressLength) BindError!void {
    if (!@hasDecl(system, "bind") or @TypeOf(system.bind) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.bind(socket_fd, address, len);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ADDRINUSE => return error.AddressInUse,
            else => return error.BindFailed,
        }
    }
}

pub fn listen(socket_fd: Socket, backlog: u32) ListenError!void {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => listenLinux(socket_fd, backlog),
        .posix_host => listenPosix(socket_fd, backlog),
    };
}

fn listenLinux(socket_fd: Socket, backlog: u32) ListenError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const rc = linux.listen(socket_fd, backlog);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.ListenFailed,
        }
    }
}

fn listenPosix(socket_fd: Socket, backlog: u32) ListenError!void {
    if (!@hasDecl(system, "listen") or @TypeOf(system.listen) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.listen(socket_fd, backlog);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.ListenFailed,
        }
    }
}

fn startListening(socket_fd: Socket, backlog: u32) ListenError!void {
    return listen(socket_fd, backlog);
}

pub fn accept(
    socket_fd: Socket,
    address: ?*SocketAddress,
    len: ?*SocketAddressLength,
    flags: u32,
) AcceptError!Socket {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => acceptLinux(socket_fd, address, len, flags),
        .posix_host => acceptPosix(socket_fd, address, len, flags),
    };
}

fn acceptLinux(
    socket_fd: Socket,
    address: ?*SocketAddress,
    len: ?*SocketAddressLength,
    flags: u32,
) AcceptError!Socket {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const linux_address: ?*linux.sockaddr = if (address) |ptr| @ptrCast(ptr) else null;
        const rc = linux.accept4(socket_fd, linux_address, len, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF => return error.FileDescriptorNotASocket,
            .INVAL => return error.SocketNotListening,
            else => return error.AcceptFailed,
        }
    }
}

fn acceptPosix(
    socket_fd: Socket,
    address: ?*SocketAddress,
    len: ?*SocketAddressLength,
    flags: u32,
) AcceptError!Socket {
    const can_accept4 = !accept4_unsupported and @hasDecl(system, "accept4") and @TypeOf(system.accept4) != void;
    if (comptime can_accept4) {
        while (true) {
            const rc = system.accept4(socket_fd, address, len, flags);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .CONNABORTED => return error.ConnectionAborted,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BADF => return error.FileDescriptorNotASocket,
                .INVAL => return error.SocketNotListening,
                else => return error.AcceptFailed,
            }
        }
    }

    if (!@hasDecl(system, "accept") or @TypeOf(system.accept) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.accept(socket_fd, address, len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const accepted: Socket = @intCast(rc);
                errdefer close(accepted);
                if ((flags & posix.SOCK.NONBLOCK) != 0) {
                    fd.setNonBlocking(accepted) catch return error.AcceptFailed;
                }
                if ((flags & posix.SOCK.CLOEXEC) != 0) {
                    fd.setCloseOnExec(accepted) catch return error.AcceptFailed;
                }
                return accepted;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF => return error.FileDescriptorNotASocket,
            .INVAL => return error.SocketNotListening,
            else => return error.AcceptFailed,
        }
    }
}

fn acceptSocket(
    socket_fd: Socket,
    address: ?*SocketAddress,
    len: ?*SocketAddressLength,
    flags: u32,
) AcceptError!Socket {
    return accept(socket_fd, address, len, flags);
}

pub fn acceptNonBlocking(socket_fd: Socket) AcceptError!Socket {
    return accept(socket_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
}

pub fn acceptStreamSocket(socket_fd: Socket) AcceptError!Socket {
    return accept(socket_fd, null, null, posix.SOCK.CLOEXEC);
}

pub fn connectIp4(socket_fd: Socket, address: Ip4Address) ConnectError!void {
    return connect(socket_fd, @ptrCast(&address), @sizeOf(Ip4Address));
}

pub fn connectIp6(socket_fd: Socket, address: Ip6Address) ConnectError!void {
    return connect(socket_fd, @ptrCast(&address), @sizeOf(Ip6Address));
}

pub fn connectIpAddress(socket_fd: Socket, address: IpAddress) ConnectError!void {
    return switch (address) {
        .ip4 => |ip4| connectIp4(socket_fd, ip4),
        .ip6 => |ip6| connectIp6(socket_fd, ip6),
    };
}

pub fn connectStream(address: Address) StreamConnectError!Stream {
    const socket_fd = try streamSocket(address.family(), .{ .close_on_exec = true });
    errdefer close(socket_fd);
    try connect(socket_fd, address.socketAddress(), address.socketAddressLen());
    return Stream.initFd(socket_fd);
}

pub fn connect(socket_fd: Socket, address: *const SocketAddress, len: SocketAddressLength) ConnectError!void {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => connectLinux(socket_fd, address, len),
        .posix_host => connectPosix(socket_fd, address, len),
    };
}

pub fn peerCredentialsPolicy() PeerCredentialsPolicy {
    return switch (native_os) {
        .linux => .linux_so_peercred,
        else => .unsupported,
    };
}

pub fn peerCredentials(
    socket_fd: Socket,
) PeerCredentialsError!PeerCredentials {
    return switch (comptime peerCredentialsPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_so_peercred => peerCredentialsLinux(socket_fd),
    };
}

fn peerCredentialsLinux(
    socket_fd: Socket,
) PeerCredentialsError!PeerCredentials {
    if (comptime native_os != .linux) {
        return error.UnsupportedPlatform;
    }
    var credentials: PeerCredentials = undefined;
    var length: linux.socklen_t = @sizeOf(PeerCredentials);
    const rc = linux.getsockopt(
        socket_fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        std.mem.asBytes(&credentials).ptr,
        &length,
    );
    try peerCredentialsErrorFromLinuxErrno(linux.errno(rc));
    if (length != @sizeOf(PeerCredentials)) {
        return error.PeerCredentialsUnavailable;
    }
    return credentials;
}

fn peerCredentialsErrorFromLinuxErrno(
    err: linux.E,
) PeerCredentialsError!void {
    return switch (err) {
        .SUCCESS => {},
        .BADF => error.BadFileDescriptor,
        .NOTSOCK => error.FileDescriptorNotASocket,
        .NOTCONN => error.SocketNotConnected,
        else => error.PeerCredentialsUnavailable,
    };
}

fn connectLinux(socket_fd: Socket, address: *const SocketAddress, len: SocketAddressLength) ConnectError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    while (true) {
        const rc = linux.connect(socket_fd, address, len);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNREFUSED => return error.ConnectionRefused,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            else => return error.ConnectFailed,
        }
    }
}

fn connectPosix(socket_fd: Socket, address: *const SocketAddress, len: SocketAddressLength) ConnectError!void {
    if (!@hasDecl(system, "connect") or @TypeOf(system.connect) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.connect(socket_fd, address, len);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNREFUSED => return error.ConnectionRefused,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            else => return error.ConnectFailed,
        }
    }
}

pub fn socketPort(socket_fd: Socket) SocketNameError!u16 {
    var address: posix.sockaddr.storage = undefined;
    var len: SocketAddressLength = @sizeOf(posix.sockaddr.storage);
    try socketAddress(socket_fd, @ptrCast(&address), &len);
    return ipAddressPort(socketAddressToIpAddress(&address, len) orelse return error.SocketNameFailed);
}

pub fn socketAddress(socket_fd: Socket, address: *SocketAddress, len: *SocketAddressLength) SocketNameError!void {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => socketAddressLinux(socket_fd, address, len),
        .posix_host => socketAddressPosix(socket_fd, address, len),
    };
}

fn socketAddressLinux(socket_fd: Socket, address: *SocketAddress, len: *SocketAddressLength) SocketNameError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    const linux_address: *linux.sockaddr = @ptrCast(address);
    while (true) {
        const rc = linux.getsockname(socket_fd, linux_address, len);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SocketNameFailed,
        }
    }
}

fn socketAddressPosix(socket_fd: Socket, address: *SocketAddress, len: *SocketAddressLength) SocketNameError!void {
    if (!@hasDecl(system, "getsockname") or @TypeOf(system.getsockname) == void) {
        return error.UnsupportedPlatform;
    }

    while (true) {
        const rc = system.getsockname(socket_fd, address, len);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SocketNameFailed,
        }
    }
}

pub fn socketAddressValue(socket_fd: Socket) SocketNameError!Address {
    var address = Address.empty();
    try readSocketAddress(socket_fd, &address);
    return address;
}

fn readSocketAddress(socket_fd: Socket, address: *Address) SocketNameError!void {
    try socketAddress(socket_fd, address.mutableSocketAddress(), &address.len);
}

pub fn pollReadable(socket_fd: Socket, timeout_ms: i32) PollError!bool {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => pollReadableLinux(socket_fd, timeout_ms),
        .posix_host => pollReadablePosix(socket_fd, timeout_ms),
    };
}

pub fn pollWritable(socket_fd: Socket, timeout_ms: i32) PollError!bool {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => pollWritableLinux(socket_fd, timeout_ms),
        .posix_host => pollWritablePosix(socket_fd, timeout_ms),
    };
}

pub fn pollReadableSet(sockets: []const Socket, ready: []bool, timeout_ms: i32) PollError!u8 {
    var interests: [readiness_max]PollInterest = undefined;
    @memset(interests[0..sockets.len], .read);
    return pollSet(sockets, interests[0..sockets.len], ready, timeout_ms);
}

pub fn pollSet(
    sockets: []const Socket,
    interests: []const PollInterest,
    ready: []bool,
    timeout_ms: i32,
) PollError!u8 {
    std.debug.assert(sockets.len == ready.len);
    std.debug.assert(sockets.len == interests.len);
    std.debug.assert(sockets.len <= readiness_max);
    @memset(ready, false);
    if (sockets.len == 0) return 0;
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => pollSetLinux(sockets, interests, ready, timeout_ms),
        .posix_host => pollSetPosix(sockets, interests, ready, timeout_ms),
    };
}

fn readinessRequest(
    sockets: []const Socket,
    interests: []const PollInterest,
    buffer: *[readiness_max]posix.pollfd,
) []posix.pollfd {
    std.debug.assert(sockets.len <= buffer.len);
    std.debug.assert(sockets.len == interests.len);
    for (sockets, interests, buffer[0..sockets.len]) |socket_fd, interest, *slot| {
        slot.* = .{
            .fd = socket_fd,
            .events = switch (interest) {
                .read => posix.POLL.IN,
                .write => posix.POLL.OUT,
            },
            .revents = 0,
        };
    }
    return buffer[0..sockets.len];
}

fn readinessOutcome(
    fds: []const posix.pollfd,
    interests: []const PollInterest,
    ready: []bool,
) u8 {
    std.debug.assert(fds.len == ready.len);
    std.debug.assert(fds.len == interests.len);
    var count: u8 = 0;
    for (fds, interests, ready) |slot, interest, *flag| {
        const mask: @TypeOf(slot.revents) = switch (interest) {
            .read => readable_mask,
            .write => writable_mask,
        };
        flag.* = (slot.revents & mask) != 0;
        count += @intFromBool(flag.*);
    }
    return count;
}

fn pollSetLinux(
    sockets: []const Socket,
    interests: []const PollInterest,
    ready: []bool,
    timeout_ms: i32,
) PollError!u8 {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    var buffer: [readiness_max]posix.pollfd = undefined;
    const fds = readinessRequest(sockets, interests, &buffer);
    while (true) {
        const rc = linux.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == 0) 0 else readinessOutcome(fds, interests, ready),
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn pollSetPosix(
    sockets: []const Socket,
    interests: []const PollInterest,
    ready: []bool,
    timeout_ms: i32,
) PollError!u8 {
    if (!@hasDecl(posix, "poll")) return error.UnsupportedPlatform;

    var buffer: [readiness_max]posix.pollfd = undefined;
    const fds = readinessRequest(sockets, interests, &buffer);
    const signalled = posix.poll(fds, timeout_ms) catch return error.PollFailed;
    return if (signalled == 0) 0 else readinessOutcome(fds, interests, ready);
}

fn pollReadableLinux(socket_fd: Socket, timeout_ms: i32) PollError!bool {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    var fds = [_]posix.pollfd{.{
        .fd = socket_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const rc = linux.poll(&fds, fds.len, timeout_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                return rc > 0 and (fds[0].revents & readable_mask) != 0;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn pollReadablePosix(socket_fd: Socket, timeout_ms: i32) PollError!bool {
    if (!@hasDecl(posix, "poll")) return error.UnsupportedPlatform;

    var fds = [_]posix.pollfd{.{
        .fd = socket_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const n = posix.poll(&fds, timeout_ms) catch return error.PollFailed;
    return n > 0 and (fds[0].revents & readable_mask) != 0;
}

fn pollWritableLinux(socket_fd: Socket, timeout_ms: i32) PollError!bool {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    var fds = [_]posix.pollfd{.{
        .fd = socket_fd,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};
    while (true) {
        const rc = linux.poll(&fds, fds.len, timeout_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                return rc > 0 and (fds[0].revents & writable_mask) != 0;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn pollWritablePosix(socket_fd: Socket, timeout_ms: i32) PollError!bool {
    if (!@hasDecl(posix, "poll")) return error.UnsupportedPlatform;

    var fds = [_]posix.pollfd{.{
        .fd = socket_fd,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};
    const n = posix.poll(&fds, timeout_ms) catch return error.PollFailed;
    return n > 0 and (fds[0].revents & writable_mask) != 0;
}

pub fn setReuseAddress(socket_fd: Socket) SetOptionError!void {
    var enabled: c_int = 1;
    return setSocketOption(socket_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enabled));
}

pub fn setTcpNoDelay(socket_fd: Socket) SetOptionError!void {
    if (comptime @TypeOf(posix.TCP) == void) return error.UnsupportedPlatform;
    if (comptime !@hasDecl(posix.TCP, "NODELAY")) return error.UnsupportedPlatform;
    var enabled: c_int = 1;
    return setSocketOption(socket_fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&enabled));
}

pub fn setReadTimeout(socket_fd: Socket, timeout_ms: u32) SetOptionError!void {
    const timeout = timeoutFromMillis(timeout_ms);
    return setSocketOption(socket_fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
}

pub fn setWriteTimeout(socket_fd: Socket, timeout_ms: u32) SetOptionError!void {
    const timeout = timeoutFromMillis(timeout_ms);
    return setSocketOption(socket_fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
}

pub fn setReceiveBuffer(
    socket_fd: Socket,
    bytes: u32,
) SetOptionError!void {
    if (bytes == 0 or bytes > std.math.maxInt(c_int)) {
        return error.InvalidArgument;
    }
    var capacity: c_int = @intCast(bytes);
    return setSocketOption(
        socket_fd,
        posix.SOL.SOCKET,
        posix.SO.RCVBUF,
        std.mem.asBytes(&capacity),
    );
}

pub fn setNonBlocking(socket_fd: Socket) SetOptionError!void {
    fd.setNonBlocking(socket_fd) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.UnsupportedPlatform,
        error.InvalidFlags => return error.InvalidArgument,
        error.FlagUpdateFailed => return error.SetOptionFailed,
    };
}

pub fn ip4AddressForHost(host: []const u8, port: u16) AddressError!Ip4Address {
    if (host.len == 0 or std.mem.eql(u8, host, "0.0.0.0")) return ip4Address(.{ 0, 0, 0, 0 }, port);
    if (std.mem.eql(u8, host, "localhost")) return ip4Address(.{ 127, 0, 0, 1 }, port);

    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, host, '.');
    var index: usize = 0;
    while (iter.next()) |part| : (index += 1) {
        if (index >= parts.len) return error.InvalidAddress;
        parts[index] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }
    if (index != parts.len) return error.InvalidAddress;
    return ip4Address(parts, port);
}

pub fn ip6AddressForHost(host: []const u8, port: u16) AddressError!Ip6Address {
    if (host.len == 0 or std.mem.eql(u8, host, "::")) return ip6Address(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, port);
    if (std.mem.eql(u8, host, "localhost")) return ip6Address(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, port);
    const parsed = std.Io.net.Ip6Address.parse(host, port) catch return error.InvalidAddress;
    return ip6Address(parsed.bytes, port);
}

pub fn ipAddressForHost(host: []const u8, port: u16) AddressError!IpAddress {
    if (ip4AddressForHost(host, port)) |address| return .{ .ip4 = address } else |_| {}
    return .{ .ip6 = try ip6AddressForHost(host, port) };
}

pub fn ipAddressPort(address: IpAddress) u16 {
    return switch (address) {
        .ip4 => |ip4| std.mem.bigToNative(u16, ip4.port),
        .ip6 => |ip6| std.mem.bigToNative(u16, ip6.port),
    };
}

pub fn ipAddressEql(lhs: IpAddress, rhs: IpAddress) bool {
    return switch (lhs) {
        .ip4 => |left| switch (rhs) {
            .ip4 => |right| left.addr == right.addr and left.port == right.port,
            .ip6 => false,
        },
        .ip6 => |left| switch (rhs) {
            .ip4 => false,
            .ip6 => |right| left.port == right.port and
                left.flowinfo == right.flowinfo and
                left.scope_id == right.scope_id and
                std.mem.eql(u8, &left.addr, &right.addr),
        },
    };
}

pub fn resolveIp4AddressForHost(host: []const u8, port: u16, options: ResolveOptions) ResolveError!Ip4Address {
    return ip4AddressForHost(host, port) catch {
        if (options.hosts_path) |hosts_path| {
            if (hostsAddressForHost(host, port, hosts_path, .a)) |address| return address.ip4;
        }
        const address = if (options.nameservers.len != 0)
            try resolveAddressWithNameservers(host, port, options.nameservers, options.timeout_ms, .a)
        else address: {
            const config = try resolvConfConfig();
            break :address try resolveAddressWithConfig(host, port, &config, options.timeout_ms, .a);
        };
        return switch (address) {
            .ip4 => |ip4| ip4,
            .ip6 => error.NoAddress,
        };
    };
}

pub fn resolveIp6AddressForHost(host: []const u8, port: u16, options: ResolveOptions) ResolveError!Ip6Address {
    return ip6AddressForHost(host, port) catch {
        if (options.hosts_path) |hosts_path| {
            if (hostsAddressForHost(host, port, hosts_path, .aaaa)) |address| return address.ip6;
        }
        const address = if (options.nameservers.len != 0)
            try resolveAddressWithNameservers(host, port, options.nameservers, options.timeout_ms, .aaaa)
        else address: {
            const config = try resolvConfConfig();
            break :address try resolveAddressWithConfig(host, port, &config, options.timeout_ms, .aaaa);
        };
        return switch (address) {
            .ip4 => error.NoAddress,
            .ip6 => |ip6| ip6,
        };
    };
}

pub fn resolveIpAddressForHost(host: []const u8, port: u16, options: ResolveOptions) ResolveError!IpAddress {
    if (ipAddressForHost(host, port)) |address| return address else |_| {}
    if (options.hosts_path) |hosts_path| {
        if (hostsAddressForHost(host, port, hosts_path, .a)) |address| return address;
        if (hostsAddressForHost(host, port, hosts_path, .aaaa)) |address| return address;
    }
    const dns_options = ResolveOptions{
        .hosts_path = null,
        .nameservers = options.nameservers,
        .timeout_ms = options.timeout_ms,
    };
    return .{ .ip4 = resolveIp4AddressForHost(host, port, dns_options) catch |err| switch (err) {
        error.NoAddress => return .{ .ip6 = try resolveIp6AddressForHost(host, port, dns_options) },
        else => return err,
    } };
}

pub fn ip4Address(bytes: [4]u8, port: u16) Ip4Address {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(bytes),
    };
}

pub fn ip6Address(bytes: [16]u8, port: u16) Ip6Address {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .addr = bytes,
        .scope_id = 0,
    };
}

fn resolveAddressWithNameserver(
    host: []const u8,
    port: u16,
    nameserver: IpAddress,
    timeout_ms: u32,
    record_type: DnsRecordType,
) ResolveError!IpAddress {
    var query: [512]u8 = undefined;
    const query_id = try secureDnsQueryId();
    const encoded = try dnsQuery(&query, host, record_type, query_id);

    const socket_fd = try udpDatagramSocketForAddress(nameserver, .{ .close_on_exec = true });
    defer close(socket_fd);
    if (timeout_ms != 0) {
        try setReadTimeout(socket_fd, timeout_ms);
        try setWriteTimeout(socket_fd, timeout_ms);
    }
    try connectIpAddress(socket_fd, nameserver);
    try sendAllSocket(socket_fd, query[0..encoded.len]);

    var response: [512]u8 = undefined;
    const response_len = try recv(socket_fd, &response, 0);
    if (try dnsResponseTruncated(response[0..response_len], encoded.question)) {
        return resolveAddressWithNameserverTcp(
            query[0..encoded.len],
            encoded.question,
            port,
            nameserver,
            timeout_ms,
        );
    }
    return dnsAddressFromResponse(response[0..response_len], encoded.question, port);
}

fn resolveAddressWithNameserverTcp(
    query: []const u8,
    question: DnsExpectedQuestion,
    port: u16,
    nameserver: IpAddress,
    timeout_ms: u32,
) ResolveError!IpAddress {
    var request: [514]u8 = undefined;
    std.mem.writeInt(u16, request[0..2], @intCast(query.len), .big);
    @memcpy(request[2..][0..query.len], query);

    const socket_fd = try tcpStreamSocketForAddress(nameserver, .{ .close_on_exec = true });
    defer close(socket_fd);
    if (timeout_ms != 0) {
        try setReadTimeout(socket_fd, timeout_ms);
        try setWriteTimeout(socket_fd, timeout_ms);
    }
    try connectIpAddress(socket_fd, nameserver);
    try sendAllSocket(socket_fd, request[0 .. query.len + 2]);

    var response_len_bytes: [2]u8 = undefined;
    try recvExactSocket(socket_fd, &response_len_bytes);
    const response_len = std.mem.readInt(u16, &response_len_bytes, .big);
    if (response_len == 0) return error.MalformedResponse;
    var response: [4096]u8 = undefined;
    if (response_len > response.len) return error.QueryTooLarge;
    try recvExactSocket(socket_fd, response[0..response_len]);
    return dnsAddressFromResponse(response[0..response_len], question, port);
}

fn resolveAddressWithNameservers(
    host: []const u8,
    port: u16,
    nameservers: []const IpAddress,
    timeout_ms: u32,
    record_type: DnsRecordType,
) ResolveError!IpAddress {
    if (nameservers.len == 0) return error.NoNameserver;
    var last_error: ResolveError = error.NoNameserver;
    for (nameservers) |nameserver| {
        return resolveAddressWithNameserver(host, port, nameserver, timeout_ms, record_type) catch |err| {
            last_error = err;
            continue;
        };
    }
    return last_error;
}

fn resolveAddressWithConfig(
    host: []const u8,
    port: u16,
    config: *const ResolverConfig,
    timeout_ms: u32,
    record_type: DnsRecordType,
) ResolveError!IpAddress {
    if (config.search_domains.count() == 0 or hostIsAbsolute(host)) {
        return resolveAddressWithNameservers(canonicalHostName(host), port, config.nameservers.slice(), timeout_ms, record_type);
    }

    var last_error: ResolveError = error.NoAddress;
    const name = canonicalHostName(host);
    const name_first = hostDotCount(name) >= config.ndots;
    if (name_first) {
        if (tryResolveAddressWithNameservers(name, port, config.nameservers.slice(), timeout_ms, record_type, &last_error)) |address| return address;
    }
    var index: usize = 0;
    while (index < config.search_domains.count()) : (index += 1) {
        if (tryResolveSearchDomainName(name, config.search_domains.get(index), port, config.nameservers.slice(), timeout_ms, record_type, &last_error)) |address| return address;
    }
    if (!name_first) {
        if (tryResolveAddressWithNameservers(name, port, config.nameservers.slice(), timeout_ms, record_type, &last_error)) |address| return address;
    }
    return last_error;
}

fn tryResolveAddressWithNameservers(
    host: []const u8,
    port: u16,
    nameservers: []const IpAddress,
    timeout_ms: u32,
    record_type: DnsRecordType,
    last_error: *ResolveError,
) ?IpAddress {
    return resolveAddressWithNameservers(host, port, nameservers, timeout_ms, record_type) catch |err| {
        last_error.* = err;
        return null;
    };
}

fn tryResolveSearchDomainName(
    host: []const u8,
    domain: []const u8,
    port: u16,
    nameservers: []const IpAddress,
    timeout_ms: u32,
    record_type: DnsRecordType,
    last_error: *ResolveError,
) ?IpAddress {
    var candidate: [dns_max_name_len]u8 = undefined;
    const candidate_len = searchDomainName(&candidate, host, domain) catch |err| {
        last_error.* = err;
        return null;
    };
    return tryResolveAddressWithNameservers(candidate[0..candidate_len], port, nameservers, timeout_ms, record_type, last_error);
}

fn sendAllSocket(socket_fd: Socket, bytes: []const u8) ResolveError!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = try send(socket_fd, bytes[sent..], 0);
        if (n == 0) return error.NoAddress;
        sent += n;
    }
}

fn recvExactSocket(socket_fd: Socket, buffer: []u8) ResolveError!void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = try recv(socket_fd, buffer[filled..], 0);
        if (n == 0) return error.NoAddress;
        filled += n;
    }
}

fn searchDomainName(buffer: []u8, host: []const u8, domain: []const u8) ResolveError!usize {
    const name = canonicalHostName(host);
    const suffix = canonicalHostName(domain);
    if (name.len == 0 or suffix.len == 0) return error.InvalidHostName;
    if (name.len + 1 + suffix.len > dns_max_name_len or name.len + 1 + suffix.len > buffer.len) return error.InvalidHostName;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = '.';
    @memcpy(buffer[name.len + 1 ..][0..suffix.len], suffix);
    return name.len + 1 + suffix.len;
}

fn hostIsAbsolute(host: []const u8) bool {
    return host.len > 1 and host[host.len - 1] == '.';
}

fn hostDotCount(host: []const u8) usize {
    var count: usize = 0;
    for (host) |byte| {
        if (byte == '.') count += 1;
    }
    return count;
}

fn hostsAddressForHost(host: []const u8, port: u16, path: []const u8, record_type: DnsRecordType) ?IpAddress {
    const file = posix.openat(posix.AT.FDCWD, path, .{ .CLOEXEC = true }, 0) catch
        return null;
    defer fd.close(file);

    var read_buffer: [4096]u8 = undefined;
    var line_buffer: [4096]u8 = undefined;
    var line_len: usize = 0;
    var skipping_line = false;
    while (true) {
        const n = fd.read(file, read_buffer[0..]) catch return null;
        if (n == 0) break;
        for (read_buffer[0..n]) |byte| {
            if (byte == '\n') {
                if (!skipping_line) {
                    if (hostsAddressFromLine(line_buffer[0..line_len], host, port, record_type)) |address| return address;
                }
                line_len = 0;
                skipping_line = false;
            } else if (!skipping_line) {
                if (line_len == line_buffer.len) {
                    line_len = 0;
                    skipping_line = true;
                } else {
                    line_buffer[line_len] = byte;
                    line_len += 1;
                }
            }
        }
    }
    if (!skipping_line) {
        if (hostsAddressFromLine(line_buffer[0..line_len], host, port, record_type)) |address| return address;
    }
    return null;
}

fn hostsAddressFromContents(contents: []const u8, host: []const u8, port: u16, record_type: DnsRecordType) ?IpAddress {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (hostsAddressFromLine(line, host, port, record_type)) |address| return address;
    }
    return null;
}

fn hostsAddressFromLine(line: []const u8, host: []const u8, port: u16, record_type: DnsRecordType) ?IpAddress {
    const stripped = stripDnsLine(line);
    var fields = std.mem.tokenizeAny(u8, stripped, " \t\r");
    const address_text = fields.next() orelse return null;
    const address = addressFromText(address_text, port, record_type) catch return null;
    while (fields.next()) |name| {
        if (hostNamesEqual(name, host)) return address;
    }
    return null;
}

fn addressFromText(text: []const u8, port: u16, record_type: DnsRecordType) AddressError!IpAddress {
    return switch (record_type) {
        .a => .{ .ip4 = try ip4AddressForHost(text, port) },
        .aaaa => .{ .ip6 = try ip6AddressForHost(text, port) },
    };
}

fn hostNamesEqual(lhs: []const u8, rhs: []const u8) bool {
    const left = canonicalHostName(lhs);
    const right = canonicalHostName(rhs);
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (std.ascii.toLower(left_byte) != std.ascii.toLower(right_byte)) return false;
    }
    return true;
}

fn canonicalHostName(host: []const u8) []const u8 {
    if (host.len > 1 and host[host.len - 1] == '.') return host[0 .. host.len - 1];
    return host;
}

const resolv_conf_nameserver_limit = 3;
const resolv_conf_search_limit = 6;
const resolv_conf_search_storage_len = 256;

const ResolverConfig = struct {
    nameservers: Nameservers = .{},
    search_domains: SearchDomains = .{},
    ndots: u8 = default_ndots,
};

const Nameservers = struct {
    buffer: [resolv_conf_nameserver_limit]IpAddress = undefined,
    len: usize = 0,

    fn append(self: *Nameservers, address: IpAddress) void {
        if (self.len == self.buffer.len) return;
        self.buffer[self.len] = address;
        self.len += 1;
    }

    fn slice(self: *const Nameservers) []const IpAddress {
        return self.buffer[0..self.len];
    }
};

const SearchDomain = struct {
    offset: usize,
    len: usize,
};

const SearchDomains = struct {
    entries: [resolv_conf_search_limit]SearchDomain = undefined,
    len: usize = 0,
    storage: [resolv_conf_search_storage_len]u8 = undefined,
    storage_len: usize = 0,

    fn clear(self: *SearchDomains) void {
        self.len = 0;
        self.storage_len = 0;
    }

    fn append(self: *SearchDomains, domain: []const u8) void {
        const name = canonicalHostName(domain);
        if (name.len == 0 or name.len > dns_max_name_len) return;
        if (self.len == self.entries.len) return;
        if (self.storage_len + name.len > self.storage.len) return;
        const offset = self.storage_len;
        @memcpy(self.storage[offset..][0..name.len], name);
        self.entries[self.len] = .{ .offset = offset, .len = name.len };
        self.len += 1;
        self.storage_len += name.len;
    }

    fn count(self: *const SearchDomains) usize {
        return self.len;
    }

    fn get(self: *const SearchDomains, index: usize) []const u8 {
        const entry = self.entries[index];
        return self.storage[entry.offset..][0..entry.len];
    }
};

fn resolvConfConfig() ResolveError!ResolverConfig {
    const resolv_conf = "/etc/resolv.conf";
    const file = posix.openat(posix.AT.FDCWD, resolv_conf, .{ .CLOEXEC = true }, 0) catch
        return error.NoNameserver;
    defer fd.close(file);

    var buffer: [4096]u8 = undefined;
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = fd.read(file, buffer[filled..]) catch return error.NoNameserver;
        if (n == 0) break;
        filled += n;
    }
    const config = configFromResolvConf(buffer[0..filled]);
    if (config.nameservers.len == 0) return error.NoNameserver;
    return config;
}

fn configFromResolvConf(contents: []const u8) ResolverConfig {
    var config = ResolverConfig{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const stripped = stripDnsLine(line);
        var fields = std.mem.tokenizeAny(u8, stripped, " \t\r");
        const key = fields.next() orelse continue;
        if (std.mem.eql(u8, key, "nameserver")) {
            const value = fields.next() orelse continue;
            config.nameservers.append(ipAddressForHost(value, 53) catch continue);
        } else if (std.mem.eql(u8, key, "search")) {
            config.search_domains.clear();
            while (fields.next()) |domain| config.search_domains.append(domain);
        } else if (std.mem.eql(u8, key, "domain")) {
            config.search_domains.clear();
            const domain = fields.next() orelse continue;
            config.search_domains.append(domain);
        } else if (std.mem.eql(u8, key, "options")) {
            while (fields.next()) |option| {
                if (ndotsFromOption(option)) |ndots| config.ndots = ndots;
            }
        }
    }
    return config;
}

fn ndotsFromOption(option: []const u8) ?u8 {
    const prefix = "ndots:";
    if (!std.mem.startsWith(u8, option, prefix)) return null;
    const parsed = std.fmt.parseInt(u8, option[prefix.len..], 10) catch return null;
    return @min(parsed, 15);
}

fn stripDnsLine(line: []const u8) []const u8 {
    var end = line.len;
    if (std.mem.indexOfScalar(u8, line, '#')) |index| end = @min(end, index);
    if (std.mem.indexOfScalar(u8, line, ';')) |index| end = @min(end, index);
    return std.mem.trim(u8, line[0..end], " \t\r");
}

const dns_header_len = 12;
const dns_name_wire_capacity = dns_max_name_len + 2;
const dns_name_step_limit = dns_name_wire_capacity;
const dns_cname_hop_limit = 16;
const dns_record_min_len = 11;
const dns_class_in = 1;
const dns_cname_type = 5;

const DnsName = struct {
    bytes: [dns_name_wire_capacity]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const DnsName) []const u8 {
        return self.bytes[0..self.len];
    }

    fn eql(self: *const DnsName, other: *const DnsName) bool {
        return self.eqlSlice(other.slice());
    }

    fn eqlSlice(self: *const DnsName, other: []const u8) bool {
        if (self.len != other.len) return false;
        for (self.slice(), other) |left, right| {
            if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
        }
        return true;
    }
};

const DecodedDnsName = struct {
    name: DnsName,
    end: usize,
};

const DnsQuestion = struct {
    id: u16,
    name: DnsName,
    record_type: u16,
    class: u16,
    end: usize,
};

const DnsExpectedQuestion = struct {
    id: u16,
    name: []const u8,
    record_type: u16,
    class: u16,
};

const DnsQuery = struct {
    len: usize,
    question: DnsExpectedQuestion,
};

const DnsResponseView = struct {
    flags: u16,
    question: DnsQuestion,
    answer_count: u16,
    authority_count: u16,
    additional_count: u16,
};

const DnsRecord = struct {
    owner: DnsName,
    record_type: u16,
    class: u16,
    data_start: usize,
    data_end: usize,
};

const DnsAnswerScan = struct {
    address: ?IpAddress = null,
    cname: ?DnsName = null,
};

fn dnsQuery(
    buffer: []u8,
    host: []const u8,
    record_type: DnsRecordType,
    query_id: u16,
) ResolveError!DnsQuery {
    if (buffer.len < 17) return error.QueryTooLarge;
    const name = canonicalHostName(host);
    if (name.len == 0 or name.len > dns_max_name_len) return error.InvalidHostName;

    std.mem.writeInt(u16, buffer[0..2], query_id, .big);
    std.mem.writeInt(u16, buffer[2..4], 0x0100, .big);
    std.mem.writeInt(u16, buffer[4..6], 1, .big);
    std.mem.writeInt(u16, buffer[6..8], 0, .big);
    std.mem.writeInt(u16, buffer[8..10], 0, .big);
    std.mem.writeInt(u16, buffer[10..12], 0, .big);

    var index: usize = dns_header_len;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidHostName;
        if (index + 1 + label.len >= buffer.len) return error.QueryTooLarge;
        buffer[index] = @intCast(label.len);
        index += 1;
        for (label) |byte| {
            if (!dnsLabelByte(byte)) return error.InvalidHostName;
            buffer[index] = std.ascii.toLower(byte);
            index += 1;
        }
    }
    if (index + 5 > buffer.len) return error.QueryTooLarge;
    buffer[index] = 0;
    index += 1;
    const wire_name = buffer[dns_header_len..index];
    std.mem.writeInt(u16, buffer[index..][0..2], @backingInt(record_type), .big);
    index += 2;
    std.mem.writeInt(u16, buffer[index..][0..2], 1, .big);
    index += 2;
    return .{
        .len = index,
        .question = .{
            .id = query_id,
            .name = wire_name,
            .record_type = @backingInt(record_type),
            .class = dns_class_in,
        },
    };
}

fn dnsLabelByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-';
}

fn secureDnsQueryId() random.SecureError!u16 {
    return random.csprngU16();
}

fn decodeDnsName(packet: []const u8, start: usize) ResolveError!DecodedDnsName {
    var decoded = DecodedDnsName{ .name = .{}, .end = undefined };
    var cursor = start;
    var compressed_end: ?usize = null;
    for (0..dns_name_step_limit) |_| {
        if (cursor >= packet.len) return error.MalformedResponse;
        const label_len = packet[cursor];
        if ((label_len & 0xc0) == 0xc0) {
            if (packet.len - cursor < 2) return error.MalformedResponse;
            const target = (@as(usize, label_len & 0x3f) << 8) | packet[cursor + 1];
            if (target < dns_header_len or target >= cursor or target >= packet.len) {
                return error.MalformedResponse;
            }
            if (compressed_end == null) compressed_end = cursor + 2;
            cursor = target;
            continue;
        }
        if ((label_len & 0xc0) != 0) return error.MalformedResponse;
        cursor += 1;
        if (label_len == 0) {
            decoded.name.bytes[decoded.name.len] = 0;
            decoded.name.len += 1;
            decoded.end = compressed_end orelse cursor;
            return decoded;
        }
        if (label_len > packet.len - cursor) return error.MalformedResponse;
        const next_len = decoded.name.len + 1 + label_len;
        if (next_len >= decoded.name.bytes.len) return error.MalformedResponse;
        decoded.name.bytes[decoded.name.len] = label_len;
        decoded.name.len += 1;
        @memcpy(
            decoded.name.bytes[decoded.name.len..][0..label_len],
            packet[cursor..][0..label_len],
        );
        decoded.name.len += label_len;
        cursor += label_len;
    }
    return error.MalformedResponse;
}

fn parseDnsQuestion(packet: []const u8) ResolveError!DnsQuestion {
    if (packet.len < dns_header_len) return error.MalformedResponse;
    if (std.mem.readInt(u16, packet[4..6], .big) != 1) return error.MalformedResponse;
    const decoded = try decodeDnsName(packet, dns_header_len);
    if (decoded.end > packet.len or packet.len - decoded.end < 4) return error.MalformedResponse;
    return .{
        .id = std.mem.readInt(u16, packet[0..2], .big),
        .name = decoded.name,
        .record_type = std.mem.readInt(u16, packet[decoded.end..][0..2], .big),
        .class = std.mem.readInt(u16, packet[decoded.end + 2 ..][0..2], .big),
        .end = decoded.end + 4,
    };
}

fn dnsResponseView(
    response: []const u8,
    expected: DnsExpectedQuestion,
) ResolveError!DnsResponseView {
    const actual = try parseDnsQuestion(response);
    const flags = std.mem.readInt(u16, response[2..4], .big);
    if ((flags & 0x8000) == 0 or (flags & 0x7800) != 0) return error.MalformedResponse;
    if ((flags & 0x0040) != 0) return error.MalformedResponse;
    if (actual.id != expected.id) return error.MalformedResponse;
    if (!actual.name.eqlSlice(expected.name)) return error.MalformedResponse;
    if (actual.record_type != expected.record_type) return error.MalformedResponse;
    if (actual.class != expected.class) return error.MalformedResponse;
    return .{
        .flags = flags,
        .question = actual,
        .answer_count = std.mem.readInt(u16, response[6..8], .big),
        .authority_count = std.mem.readInt(u16, response[8..10], .big),
        .additional_count = std.mem.readInt(u16, response[10..12], .big),
    };
}

fn parseDnsRecord(response: []const u8, index: *usize) ResolveError!DnsRecord {
    const owner = try decodeDnsName(response, index.*);
    if (owner.end > response.len or response.len - owner.end < 10) return error.MalformedResponse;
    const data_len = std.mem.readInt(u16, response[owner.end + 8 ..][0..2], .big);
    const data_start = owner.end + 10;
    if (data_len > response.len - data_start) return error.MalformedResponse;
    const data_end = data_start + data_len;
    index.* = data_end;
    return .{
        .owner = owner.name,
        .record_type = std.mem.readInt(u16, response[owner.end..][0..2], .big),
        .class = std.mem.readInt(u16, response[owner.end + 2 ..][0..2], .big),
        .data_start = data_start,
        .data_end = data_end,
    };
}

fn validateDnsRecordSections(response: []const u8, view: DnsResponseView) ResolveError!void {
    const record_count = @as(usize, view.answer_count) +
        @as(usize, view.authority_count) +
        @as(usize, view.additional_count);
    if (view.question.end > response.len) return error.MalformedResponse;
    if (record_count > (response.len - view.question.end) / dns_record_min_len) {
        return error.MalformedResponse;
    }
    var index = view.question.end;
    for (0..record_count) |_| _ = try parseDnsRecord(response, &index);
    if (index != response.len) return error.MalformedResponse;
}

fn addressFromDnsRecord(
    response: []const u8,
    record: DnsRecord,
    record_type: DnsRecordType,
    port: u16,
) ResolveError!IpAddress {
    const data = response[record.data_start..record.data_end];
    return switch (record_type) {
        .a => if (data.len == 4)
            .{ .ip4 = ip4Address(data[0..4].*, port) }
        else
            error.MalformedResponse,
        .aaaa => if (data.len == 16)
            .{ .ip6 = ip6Address(data[0..16].*, port) }
        else
            error.MalformedResponse,
    };
}

fn cnameFromDnsRecord(response: []const u8, record: DnsRecord) ResolveError!DnsName {
    const decoded = try decodeDnsName(response, record.data_start);
    if (decoded.end != record.data_end) return error.MalformedResponse;
    return decoded.name;
}

fn scanDnsAnswers(
    response: []const u8,
    view: DnsResponseView,
    target: *const DnsName,
    record_type: DnsRecordType,
    port: u16,
    validate_sections: bool,
) ResolveError!DnsAnswerScan {
    const record_count = @as(usize, view.answer_count) +
        @as(usize, view.authority_count) +
        @as(usize, view.additional_count);
    if (validate_sections and
        record_count > (response.len - view.question.end) / dns_record_min_len)
    {
        return error.MalformedResponse;
    }
    var scan = DnsAnswerScan{};
    var index = view.question.end;
    for (0..view.answer_count) |_| {
        const record = try parseDnsRecord(response, &index);
        if (record.class != dns_class_in or !record.owner.eql(target)) continue;
        if (record.record_type == @backingInt(record_type)) {
            if (scan.cname != null) return error.MalformedResponse;
            const address = try addressFromDnsRecord(response, record, record_type, port);
            if (scan.address == null) scan.address = address;
        } else if (record.record_type == dns_cname_type) {
            if (scan.address != null) return error.MalformedResponse;
            const cname = try cnameFromDnsRecord(response, record);
            if (scan.cname) |existing| {
                if (!existing.eql(&cname)) return error.MalformedResponse;
            } else {
                scan.cname = cname;
            }
        }
    }
    if (validate_sections) {
        const remaining_count = @as(usize, view.authority_count) +
            @as(usize, view.additional_count);
        for (0..remaining_count) |_| _ = try parseDnsRecord(response, &index);
        if (index != response.len) return error.MalformedResponse;
    }
    return scan;
}

fn dnsAddressFromResponse(
    response: []const u8,
    expected: DnsExpectedQuestion,
    port: u16,
) ResolveError!IpAddress {
    const view = try dnsResponseView(response, expected);
    if ((view.flags & 0x0200) != 0) return error.MalformedResponse;
    if ((view.flags & 0x000f) != 0) {
        try validateDnsRecordSections(response, view);
        return error.NoAddress;
    }
    if (view.question.class != dns_class_in) return error.MalformedResponse;
    const record_type = std.enums.fromInt(DnsRecordType, view.question.record_type) orelse
        return error.MalformedResponse;
    var target = view.question.name;
    for (0..dns_cname_hop_limit + 1) |hop| {
        const scan = try scanDnsAnswers(response, view, &target, record_type, port, hop == 0);
        if (scan.address) |address| return address;
        const cname = scan.cname orelse return error.NoAddress;
        if (cname.eql(&target) or hop == dns_cname_hop_limit) {
            return error.MalformedResponse;
        }
        target = cname;
    }
    unreachable;
}

fn dnsResponseTruncated(response: []const u8, expected: DnsExpectedQuestion) ResolveError!bool {
    const view = try dnsResponseView(response, expected);
    return (view.flags & 0x0200) != 0;
}

fn skipDnsName(packet: []const u8, index: *usize) ResolveError!void {
    index.* = (try decodeDnsName(packet, index.*)).end;
}

fn setSocketOption(socket_fd: Socket, level: i32, option: u32, value: []const u8) SetOptionError!void {
    return switch (socketPolicy()) {
        .unsupported => error.UnsupportedPlatform,
        .linux_syscall => setSocketOptionLinux(socket_fd, level, option, value),
        .posix_host => setSocketOptionPosix(socket_fd, level, option, value),
    };
}

fn setSocketOptionLinux(socket_fd: Socket, level: i32, option: u32, value: []const u8) SetOptionError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;

    switch (linux.errno(linux.setsockopt(socket_fd, level, option, value.ptr, @intCast(value.len)))) {
        .SUCCESS => {},
        .INVAL => return error.InvalidArgument,
        else => return error.SetOptionFailed,
    }
}

fn setSocketOptionPosix(socket_fd: Socket, level: i32, option: u32, value: []const u8) SetOptionError!void {
    posix.setsockopt(socket_fd, level, option, value) catch return error.SetOptionFailed;
}

fn shutdownReadWriteLinux(socket_fd: Socket) void {
    if (comptime native_os != .linux) return;
    _ = linux.shutdown(socket_fd, posix.SHUT.RDWR);
}

fn shutdownReadWritePosix(socket_fd: Socket) void {
    if (@hasDecl(system, "shutdown")) {
        _ = system.shutdown(socket_fd, posix.SHUT.RDWR);
    }
}

fn timeoutFromMillis(timeout_ms: u32) posix.timeval {
    if (timeout_ms == 0) return .{ .sec = 0, .usec = 0 };
    return .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
}

fn noSignalFlag() u32 {
    if (@hasField(posix.MSG, "NOSIGNAL")) return posix.MSG.NOSIGNAL;
    return 0;
}

fn receiveTruncationFlag() u32 {
    if (comptime native_os == .linux) return linux.MSG.TRUNC;
    return 0;
}

fn socketAddressToIpAddress(address: *const posix.sockaddr.storage, len: SocketAddressLength) ?IpAddress {
    const any: *const SocketAddress = @ptrCast(address);
    return switch (any.family) {
        posix.AF.INET => {
            if (len < @sizeOf(Ip4Address)) return null;
            const ip4: *const Ip4Address = @ptrCast(@alignCast(address));
            return .{ .ip4 = ip4.* };
        },
        posix.AF.INET6 => {
            if (len < @sizeOf(Ip6Address)) return null;
            const ip6: *const Ip6Address = @ptrCast(@alignCast(address));
            return .{ .ip6 = ip6.* };
        },
        else => null,
    };
}

fn expectIp4Address(address: Ip4Address, bytes: [4]u8, port: u16) !void {
    try std.testing.expectEqual(std.mem.nativeToBig(u16, port), address.port);
    try std.testing.expectEqual(@as(u32, @bitCast(bytes)), address.addr);
}

fn expectIp6Address(address: Ip6Address, bytes: [16]u8, port: u16) !void {
    try std.testing.expectEqual(std.mem.nativeToBig(u16, port), address.port);
    try std.testing.expectEqual(bytes, address.addr);
}

fn expectIpAddress4(address: IpAddress, bytes: [4]u8, port: u16) !void {
    return switch (address) {
        .ip4 => |ip4| expectIp4Address(ip4, bytes, port),
        .ip6 => error.InvalidAddress,
    };
}

fn expectIpAddress6(address: IpAddress, bytes: [16]u8, port: u16) !void {
    return switch (address) {
        .ip4 => error.InvalidAddress,
        .ip6 => |ip6| expectIp6Address(ip6, bytes, port),
    };
}

test "abstract unix address leads with a NUL and excludes a trailing one" {
    const name = "/tmp/.X11-unix/X1";
    const address = try Address.initUnixAbstract(name);
    try std.testing.expectEqual(@as(u32, posix.AF.UNIX), address.family());
    try std.testing.expectEqual(@as(u8, 0), address.storage.unix.path[0]);
    try std.testing.expectEqualSlices(u8, name, address.storage.unix.path[1 .. 1 + name.len]);
    try std.testing.expectEqual(
        @as(usize, @offsetOf(posix.sockaddr.un, "path") + 1 + name.len),
        @as(usize, address.socketAddressLen()),
    );
}

test "pathname unix address copies the path verbatim with no leading NUL" {
    const path = "/tmp/.X11-unix/X1";
    const address = try Address.initUnix(path);
    try std.testing.expectEqualSlices(u8, path, address.storage.unix.path[0..path.len]);
    try std.testing.expect(address.storage.unix.path[0] != 0);
}

test "IPv4 host parsing recognizes localhost and any address" {
    const loopback = try ip4AddressForHost("localhost", 1234);
    try expectIp4Address(loopback, .{ 127, 0, 0, 1 }, 1234);

    const any = try ip4AddressForHost("", 8080);
    try expectIp4Address(any, .{ 0, 0, 0, 0 }, 8080);
}

test "IPv6 host parsing recognizes localhost and any address" {
    const loopback = try ip6AddressForHost("localhost", 1234);
    try expectIp6Address(loopback, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 1234);

    const any = try ip6AddressForHost("", 8080);
    try expectIp6Address(any, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 8080);

    const documentation = try ip6AddressForHost("2001:db8::42", 443);
    try expectIp6Address(documentation, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x42 }, 443);
}

test "resolv.conf parser returns resolver config" {
    const config = configFromResolvConf(
        \\# generated
        \\domain stale.test
        \\search example.test
        \\options attempts:2 ndots:2
        \\nameserver 127.0.0.53
        \\nameserver 10.0.0.1
        \\nameserver 2001:db8::53
        \\nameserver 10.0.0.3
    );
    try std.testing.expectEqual(@as(usize, 3), config.nameservers.len);
    try expectIpAddress4(config.nameservers.buffer[0], .{ 127, 0, 0, 53 }, 53);
    try expectIpAddress4(config.nameservers.buffer[1], .{ 10, 0, 0, 1 }, 53);
    try expectIpAddress6(config.nameservers.buffer[2], .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x53 }, 53);
    try std.testing.expectEqual(@as(u8, 2), config.ndots);
    try std.testing.expectEqual(@as(usize, 1), config.search_domains.count());
    try std.testing.expectEqualStrings("example.test", config.search_domains.get(0));
}

test "resolv.conf parser lets later domain replace search list" {
    const config = configFromResolvConf(
        \\search first.test second.test
        \\domain final.test.
        \\options ndots:99
    );
    try std.testing.expectEqual(@as(u8, 15), config.ndots);
    try std.testing.expectEqual(@as(usize, 1), config.search_domains.count());
    try std.testing.expectEqualStrings("final.test", config.search_domains.get(0));
}

test "hosts parser returns matching IPv4 alias" {
    const contents =
        \\# generated
        \\::1 ip6-localhost
        \\192.0.2.44 alpha.example alpha
        \\198.51.100.8 beta.example BETA.
    ;
    const address = hostsAddressFromContents(contents, "beta", 9000, .a) orelse return error.NoAddress;
    try expectIpAddress4(address, .{ 198, 51, 100, 8 }, 9000);
}

test "hosts parser returns matching IPv6 alias" {
    const contents =
        \\# generated
        \\127.0.0.1 localhost
        \\2001:db8::88 gamma.example GAMMA.
    ;
    const address = hostsAddressFromContents(contents, "gamma", 9443, .aaaa) orelse return error.NoAddress;
    try expectIpAddress6(address, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x88 }, 9443);
}

test "resolver uses hosts file before DNS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "hosts",
        .data =
        \\203.0.113.9 local-only.test
        ,
    });

    const hosts_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "hosts", std.testing.allocator);
    defer std.testing.allocator.free(hosts_path);
    const address = try resolveIp4AddressForHost("local-only.test", 443, .{
        .hosts_path = hosts_path,
        .nameservers = &.{.{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, 9) }},
        .timeout_ms = 1,
    });
    try expectIp4Address(address, .{ 203, 0, 113, 9 }, 443);
}

test "generic resolver uses IPv6 hosts file entry before DNS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "hosts",
        .data =
        \\2001:db8::99 ip6-local-only.test
        ,
    });

    const hosts_path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "hosts", std.testing.allocator);
    defer std.testing.allocator.free(hosts_path);
    const address = try resolveIpAddressForHost("ip6-local-only.test", 443, .{
        .hosts_path = hosts_path,
        .nameservers = &.{.{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, 9) }},
        .timeout_ms = 1,
    });
    try expectIpAddress6(address, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x99 }, 443);
}

test "DNS response parser returns IPv4 answer" {
    var query: [512]u8 = undefined;
    const encoded = try dnsQuery(&query, "example.test", .a, 0x1234);

    var response: [512]u8 = undefined;
    const response_len = try dnsTestResponse(
        &response,
        query[0..encoded.len],
        .{ .ip4 = ip4Address(.{ 127, 0, 0, 42 }, 0) },
        false,
    );
    const address = try dnsAddressFromResponse(response[0..response_len], encoded.question, 8080);

    try expectIpAddress4(address, .{ 127, 0, 0, 42 }, 8080);
}

test "DNS response parser returns IPv6 answer" {
    const answer_bytes = [16]u8{
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
        0,    0,    0,    0,    0, 0, 0, 0x42,
    };
    var query: [512]u8 = undefined;
    const encoded = try dnsQuery(&query, "example.test", .aaaa, 0x5678);

    var response: [512]u8 = undefined;
    const response_len = try dnsTestResponse(
        &response,
        query[0..encoded.len],
        .{ .ip6 = ip6Address(answer_bytes, 0) },
        false,
    );
    const address = try dnsAddressFromResponse(response[0..response_len], encoded.question, 8080);

    try expectIpAddress6(address, answer_bytes, 8080);
}

test "DNS response parser rejects a mismatched question" {
    var query: [512]u8 = undefined;
    const encoded = try dnsQuery(&query, "example.test", .a, 0x9abc);
    var response: [512]u8 = undefined;
    const response_len = try dnsTestResponse(
        &response,
        query[0..encoded.len],
        .{ .ip4 = ip4Address(.{ 127, 0, 0, 42 }, 0) },
        false,
    );
    var question_end: usize = 12;
    try skipDnsName(response[0..response_len], &question_end);

    response[13] = 'f';
    try std.testing.expectError(
        error.MalformedResponse,
        dnsAddressFromResponse(response[0..response_len], encoded.question, 8080),
    );
}

test "DNS resolver uses configured UDP nameserver" {
    const server_socket = udpDatagramSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(server_socket);
    try bindIp4(server_socket, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try setReadTimeout(server_socket, 1000);
    const server_port = try socketPort(server_socket);

    var server = TestDnsServer{ .socket = server_socket };
    const thread = try std.Thread.spawn(.{}, TestDnsServer.run, .{&server});
    const resolved = resolveIp4AddressForHost("example.test", 8080, .{
        .hosts_path = null,
        .nameservers = &.{.{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, server_port) }},
        .timeout_ms = 1000,
    });
    thread.join();
    if (server.err) |err| return err;

    const address = try resolved;
    try expectIp4Address(address, .{ 127, 0, 0, 42 }, 8080);
}

test "DNS resolver uses configured UDP nameserver for IPv6" {
    const server_socket = udpDatagramSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(server_socket);
    try bindIp4(server_socket, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try setReadTimeout(server_socket, 1000);
    const server_port = try socketPort(server_socket);

    var server = TestDnsServer{ .socket = server_socket, .answer = .{ .ip6 = ip6Address(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x77 }, 0) } };
    const thread = try std.Thread.spawn(.{}, TestDnsServer.run, .{&server});
    const resolved = resolveIp6AddressForHost("example.test", 9443, .{
        .hosts_path = null,
        .nameservers = &.{.{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, server_port) }},
        .timeout_ms = 1000,
    });
    thread.join();
    if (server.err) |err| return err;

    const address = try resolved;
    try expectIp6Address(address, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x77 }, 9443);
}

test "generic DNS resolver falls back to IPv6 answer" {
    const server_socket = udpDatagramSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(server_socket);
    try bindIp4(server_socket, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try setReadTimeout(server_socket, 1000);
    const server_port = try socketPort(server_socket);

    var server = TestDnsSequenceServer{
        .socket = server_socket,
        .answers = .{
            null,
            .{ .ip6 = ip6Address(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x66 }, 0) },
        },
    };
    const thread = try std.Thread.spawn(.{}, TestDnsSequenceServer.run, .{&server});
    const resolved = resolveIpAddressForHost("example.test", 9443, .{
        .hosts_path = null,
        .nameservers = &.{.{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, server_port) }},
        .timeout_ms = 1000,
    });
    thread.join();
    if (server.err) |err| return err;

    const address = try resolved;
    try expectIpAddress6(address, .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x66 }, 9443);
}

test "DNS resolver tries configured nameservers in order" {
    const first_socket = udpDatagramSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(first_socket);
    try bindIp4(first_socket, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try setReadTimeout(first_socket, 1000);
    const first_port = try socketPort(first_socket);

    const second_socket = udpDatagramSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(second_socket);
    try bindIp4(second_socket, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try setReadTimeout(second_socket, 1000);
    const second_port = try socketPort(second_socket);

    var first = TestDnsServer{ .socket = first_socket, .answer = null };
    var second = TestDnsServer{ .socket = second_socket, .answer = .{ .ip4 = ip4Address(.{ 127, 0, 0, 99 }, 0) } };
    const first_thread = try std.Thread.spawn(.{}, TestDnsServer.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, TestDnsServer.run, .{&second});
    const nameservers = [_]IpAddress{
        .{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, first_port) },
        .{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, second_port) },
    };
    const resolved = resolveIp4AddressForHost("example.test", 8080, .{
        .hosts_path = null,
        .nameservers = &nameservers,
        .timeout_ms = 1000,
    });
    first_thread.join();
    second_thread.join();
    if (first.err) |err| return err;
    if (second.err) |err| return err;

    const address = try resolved;
    try expectIp4Address(address, .{ 127, 0, 0, 99 }, 8080);
}

test "DNS resolver applies search domains before bare single label" {
    const server_socket = udpDatagramSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(server_socket);
    try bindIp4(server_socket, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try setReadTimeout(server_socket, 1000);
    const server_port = try socketPort(server_socket);

    var config = ResolverConfig{};
    config.nameservers.append(.{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, server_port) });
    config.search_domains.append("example.test");
    config.ndots = 1;

    var server = TestDnsServer{
        .socket = server_socket,
        .expected = "service.example.test",
        .answer = .{ .ip4 = ip4Address(.{ 127, 0, 0, 77 }, 0) },
    };
    const thread = try std.Thread.spawn(.{}, TestDnsServer.run, .{&server});
    const resolved = resolveAddressWithConfig("service", 8080, &config, 1000, .a);
    thread.join();
    if (server.err) |err| return err;

    const address = try resolved;
    try expectIpAddress4(address, .{ 127, 0, 0, 77 }, 8080);
}

test "DNS resolver uses TCP fallback for truncated UDP response" {
    const tcp_socket = tcpStreamSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(tcp_socket);
    try bindIp4(tcp_socket, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try listen(tcp_socket, 1);
    const server_port = try socketPort(tcp_socket);

    const udp_socket = udpDatagramSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(udp_socket);
    try bindIp4(udp_socket, ip4Address(.{ 127, 0, 0, 1 }, server_port));
    try setReadTimeout(udp_socket, 1000);

    var udp_server = TestDnsServer{ .socket = udp_socket, .answer = null, .truncated = true };
    var tcp_server = TestTcpDnsServer{ .socket = tcp_socket, .answer = .{ .ip4 = ip4Address(.{ 127, 0, 0, 88 }, 0) } };
    const udp_thread = try std.Thread.spawn(.{}, TestDnsServer.run, .{&udp_server});
    const tcp_thread = try std.Thread.spawn(.{}, TestTcpDnsServer.run, .{&tcp_server});
    const resolved = resolveIp4AddressForHost("example.test", 8080, .{
        .hosts_path = null,
        .nameservers = &.{.{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, server_port) }},
        .timeout_ms = 1000,
    });
    udp_thread.join();
    tcp_thread.join();
    if (udp_server.err) |err| return err;
    if (tcp_server.err) |err| return err;

    const address = try resolved;
    try expectIp4Address(address, .{ 127, 0, 0, 88 }, 8080);
}

const TestDnsServer = struct {
    socket: Socket,
    expected: ?[]const u8 = null,
    answer: ?IpAddress = .{ .ip4 = ip4Address(.{ 127, 0, 0, 42 }, 0) },
    truncated: bool = false,
    err: ?anyerror = null,

    fn run(self: *TestDnsServer) void {
        self.serve() catch |err| {
            self.err = err;
        };
    }

    fn serve(self: *TestDnsServer) !void {
        var query: [512]u8 = undefined;
        var peer: SocketAddress = undefined;
        var peer_len: SocketAddressLength = @sizeOf(SocketAddress);
        const query_len = try recvFrom(self.socket, &query, 0, &peer, &peer_len);

        var response: [512]u8 = undefined;
        const answer = if (self.expected) |expected|
            if (dnsQuestionNameEquals(query[0..query_len], expected)) self.answer else null
        else
            self.answer;
        const response_len = try dnsTestResponse(&response, query[0..query_len], answer, self.truncated);
        _ = try sendTo(self.socket, response[0..response_len], 0, &peer, peer_len);
    }
};

const TestTcpDnsServer = struct {
    socket: Socket,
    answer: ?IpAddress = .{ .ip4 = ip4Address(.{ 127, 0, 0, 42 }, 0) },
    err: ?anyerror = null,

    fn run(self: *TestTcpDnsServer) void {
        self.serve() catch |err| {
            self.err = err;
        };
    }

    fn serve(self: *TestTcpDnsServer) !void {
        if (!(try pollReadable(self.socket, 1000))) return error.ConnectionTimedOut;
        const client = try accept(self.socket, null, null, posix.SOCK.CLOEXEC);
        defer close(client);
        try setReadTimeout(client, 1000);
        try setWriteTimeout(client, 1000);

        var query_len_bytes: [2]u8 = undefined;
        try recvExactSocket(client, &query_len_bytes);
        const query_len = std.mem.readInt(u16, &query_len_bytes, .big);
        if (query_len == 0) return error.MalformedResponse;
        var query: [512]u8 = undefined;
        if (query_len > query.len) return error.QueryTooLarge;
        try recvExactSocket(client, query[0..query_len]);

        var response: [512]u8 = undefined;
        const response_len = try dnsTestResponse(&response, query[0..query_len], self.answer, false);
        var frame: [514]u8 = undefined;
        std.mem.writeInt(u16, frame[0..2], @intCast(response_len), .big);
        @memcpy(frame[2..][0..response_len], response[0..response_len]);
        try sendAllSocket(client, frame[0 .. response_len + 2]);
    }
};

const TestDnsSequenceServer = struct {
    socket: Socket,
    answers: [2]?IpAddress,
    err: ?anyerror = null,

    fn run(self: *TestDnsSequenceServer) void {
        self.serve() catch |err| {
            self.err = err;
        };
    }

    fn serve(self: *TestDnsSequenceServer) !void {
        var request_index: usize = 0;
        while (request_index < self.answers.len) : (request_index += 1) {
            var query: [512]u8 = undefined;
            var peer: SocketAddress = undefined;
            var peer_len: SocketAddressLength = @sizeOf(SocketAddress);
            const query_len = try recvFrom(self.socket, &query, 0, &peer, &peer_len);

            var response: [512]u8 = undefined;
            const response_len = try dnsTestResponse(&response, query[0..query_len], self.answers[request_index], false);
            _ = try sendTo(self.socket, response[0..response_len], 0, &peer, peer_len);
        }
    }
};

fn dnsQuestionNameEquals(query: []const u8, expected: []const u8) bool {
    var expected_query: [512]u8 = undefined;
    const encoded = dnsQuery(&expected_query, expected, .a, 0) catch return false;
    var query_name_end: usize = 12;
    skipDnsName(query, &query_name_end) catch return false;
    if (query_name_end > query.len) return false;
    return std.mem.eql(u8, query[12..query_name_end], encoded.question.name);
}

fn dnsTestResponse(buffer: []u8, query: []const u8, address: ?IpAddress, truncated: bool) !usize {
    if (query.len < 17 or buffer.len < query.len + 28) return error.QueryTooLarge;
    var question_end: usize = 12;
    try skipDnsName(query, &question_end);
    question_end += 4;
    if (question_end > query.len) return error.MalformedResponse;

    std.mem.writeInt(u16, buffer[0..2], std.mem.readInt(u16, query[0..2], .big), .big);
    std.mem.writeInt(u16, buffer[2..4], if (truncated) 0x8380 else 0x8180, .big);
    std.mem.writeInt(u16, buffer[4..6], 1, .big);
    std.mem.writeInt(u16, buffer[6..8], if (address == null) 0 else 1, .big);
    std.mem.writeInt(u16, buffer[8..10], 0, .big);
    std.mem.writeInt(u16, buffer[10..12], 0, .big);

    var index: usize = 12;
    @memcpy(buffer[index..][0 .. question_end - 12], query[12..question_end]);
    index += question_end - 12;
    const answer = address orelse return index;
    buffer[index] = 0xc0;
    buffer[index + 1] = 0x0c;
    index += 2;
    switch (answer) {
        .ip4 => |ip4| {
            std.mem.writeInt(u16, buffer[index..][0..2], @backingInt(DnsRecordType.a), .big);
            index += 2;
            std.mem.writeInt(u16, buffer[index..][0..2], 1, .big);
            index += 2;
            std.mem.writeInt(u32, buffer[index..][0..4], 0, .big);
            index += 4;
            std.mem.writeInt(u16, buffer[index..][0..2], 4, .big);
            index += 2;
            const bytes: [4]u8 = @bitCast(ip4.addr);
            @memcpy(buffer[index..][0..4], &bytes);
            index += 4;
        },
        .ip6 => |ip6| {
            std.mem.writeInt(u16, buffer[index..][0..2], @backingInt(DnsRecordType.aaaa), .big);
            index += 2;
            std.mem.writeInt(u16, buffer[index..][0..2], 1, .big);
            index += 2;
            std.mem.writeInt(u32, buffer[index..][0..4], 0, .big);
            index += 4;
            std.mem.writeInt(u16, buffer[index..][0..2], 16, .big);
            index += 2;
            @memcpy(buffer[index..][0..16], &ip6.addr);
            index += 16;
        },
    }
    return index;
}

test "stream socket can be created for IPv4" {
    const socket_fd = tcpStreamSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(socket_fd);
}

test "socket policy is explicit" {
    const expected: SocketPolicy = switch (native_os) {
        .windows, .wasi, .freestanding => .unsupported,
        .linux => .linux_syscall,
        else => .posix_host,
    };
    try std.testing.expectEqual(expected, socketPolicy());
}

test "peer credentials policy is explicit" {
    const expected: PeerCredentialsPolicy = switch (native_os) {
        .linux => .linux_so_peercred,
        else => .unsupported,
    };
    try std.testing.expectEqual(
        expected,
        peerCredentialsPolicy(),
    );
}

test "Unix stream socket pair exposes kernel peer identity" {
    if (comptime native_os != .linux) {
        return error.SkipZigTest;
    }
    const sockets = try socketPairUnixStream();
    defer close(sockets[0]);
    defer close(sockets[1]);

    const left = try peerCredentials(sockets[0]);
    const right = try peerCredentials(sockets[1]);
    const process_id = linux.getpid();
    const user_id = linux.geteuid();
    const group_id = linux.getegid();
    try std.testing.expectEqual(process_id, left.process_id);
    try std.testing.expectEqual(user_id, left.user_id);
    try std.testing.expectEqual(group_id, left.group_id);
    try std.testing.expectEqual(process_id, right.process_id);
    try std.testing.expectEqual(user_id, right.user_id);
    try std.testing.expectEqual(group_id, right.group_id);
}

test "TCP stream socket can disable Nagle" {
    const socket_fd = tcpStreamSocket(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(socket_fd);
    setTcpNoDelay(socket_fd) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
}

test "Unix stream socket pair send recv round trip" {
    const sockets = socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(sockets[0]);
    defer close(sockets[1]);

    try std.testing.expectEqual(@as(usize, 4), try sendNoSignal(sockets[0], "pong"));

    var buffer: [8]u8 = undefined;
    const count = try recv(sockets[1], &buffer, 0);
    try std.testing.expectEqualStrings("pong", buffer[0..count]);
}

test "Unix stream socket pair poll detects readable data" {
    const sockets = socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(sockets[0]);
    defer close(sockets[1]);

    try std.testing.expect(!try pollReadable(sockets[1], 0));
    try std.testing.expectEqual(@as(usize, 4), try sendNoSignal(sockets[0], "pong"));
    try std.testing.expect(try pollReadable(sockets[1], 0));
}

test "readiness set reports each ready socket without blocking on silent peers" {
    const testing = std.testing;
    const quiet = socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(quiet[0]);
    defer close(quiet[1]);
    const busy = try socketPairUnixStream();
    defer close(busy[0]);
    defer close(busy[1]);

    const watched = [_]Socket{ quiet[1], busy[1] };
    var ready: [watched.len]bool = undefined;
    try testing.expectEqual(
        @as(u8, 0),
        try pollReadableSet(&watched, &ready, 0),
    );
    try testing.expectEqual([_]bool{ false, false }, ready);

    try testing.expectEqual(@as(usize, 4), try sendNoSignal(busy[0], "ping"));
    try testing.expectEqual(
        @as(u8, 1),
        try pollReadableSet(&watched, &ready, 0),
    );
    try testing.expectEqual([_]bool{ false, true }, ready);

    try testing.expectEqual(@as(usize, 4), try sendNoSignal(quiet[0], "ping"));
    try testing.expectEqual(
        @as(u8, 2),
        try pollReadableSet(&watched, &ready, 0),
    );
    try testing.expectEqual([_]bool{ true, true }, ready);
}

test "readiness set reports a hung up peer and admits an empty watch list" {
    const testing = std.testing;
    const sockets = socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(sockets[1]);
    close(sockets[0]);

    const watched = [_]Socket{sockets[1]};
    var ready: [watched.len]bool = undefined;
    try testing.expectEqual(
        @as(u8, 1),
        try pollReadableSet(&watched, &ready, 0),
    );
    try testing.expect(ready[0]);

    var none: [0]bool = undefined;
    try testing.expectEqual(
        @as(u8, 0),
        try pollReadableSet(&.{}, &none, 0),
    );
}

test "readiness set joins readable and writable interests" {
    const readable = socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(readable[0]);
    defer close(readable[1]);
    const writable = try socketPairUnixStream();
    defer close(writable[0]);
    defer close(writable[1]);
    try setNonBlocking(readable[1]);
    try setNonBlocking(writable[0]);
    try std.testing.expectEqual(@as(usize, 4), try sendNoSignal(readable[0], "ping"));

    const watched = [_]Socket{ readable[1], writable[0] };
    const interests = [_]PollInterest{ .read, .write };
    var ready: [watched.len]bool = undefined;
    try std.testing.expectEqual(
        @as(u8, 2),
        try pollSet(&watched, &interests, &ready, 0),
    );
    try std.testing.expectEqual([_]bool{ true, true }, ready);
}

test "Unix stream socket pair poll detects writable backpressure" {
    const sockets = socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer close(sockets[0]);
    defer close(sockets[1]);

    try setNonBlocking(sockets[0]);
    try std.testing.expect(try pollWritable(sockets[0], 0));
    try fillSocketForBackpressure(sockets[0]);
    try std.testing.expect(!try pollWritable(sockets[0], 0));
}

fn fillSocketForBackpressure(socket_fd: Socket) !void {
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 0xAA);

    while (true) {
        _ = sendNoSignal(socket_fd, &chunk) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }
}

test "controlled sockets: stalled read and full write honor an absolute deadline" {
    if (!Control.supported()) return error.SkipZigTest;
    const sockets = try socketPairUnixStream();
    defer close(sockets[0]);
    defer close(sockets[1]);
    var control = Control{ .deadline_ns = try Control.clock() + 30 * std.time.ns_per_ms, .bytes_remaining = 16 * 1024 * 1024 };
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.DeadlineExceeded, control.receive(sockets[0], &byte));
    try std.testing.expect(try Control.clock() < control.deadline_ns + 100 * std.time.ns_per_ms);
    try setNonBlocking(sockets[0]);
    const fill: [8192]u8 = @splat(1);
    var filled: usize = 0;
    while (filled < 16 * 1024 * 1024) {
        filled += sendNoSignal(sockets[0], &fill) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
    }
    try std.testing.expect(filled < 16 * 1024 * 1024);
    control = .{ .deadline_ns = try Control.clock() + 30 * std.time.ns_per_ms, .bytes_remaining = 65536 };
    try std.testing.expectError(error.DeadlineExceeded, control.transmit(sockets[0], "x"));
    try std.testing.expect(try Control.clock() < control.deadline_ns + 100 * std.time.ns_per_ms);
}

const ControlledSocketWorker = struct {
    socket: Socket,
    address: ?IpAddress = null,
    control: *Control,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ControlledSocketWorker) void {
        self.perform() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn perform(self: *ControlledSocketWorker) !void {
        if (self.address) |address| try self.control.connectTo(self.socket, address) else _ = try self.control.transmit(self.socket, "x");
    }

    fn cancelAndJoin(self: *ControlledSocketWorker) !void {
        const thread = try @import("root.zig").thread.spawn(ControlledSocketWorker.run, .{self});
        defer thread.join();
        defer self.control.cancel();
        @import("root.zig").time.sleepMilliseconds(20);
        try std.testing.expect(!self.done.load(.acquire));
        const canceled_at = try Control.clock();
        self.control.cancel();
        while (!self.done.load(.acquire) and try Control.clock() < canceled_at + 200 * std.time.ns_per_ms)
            @import("root.zig").time.sleepMilliseconds(1);
        try std.testing.expect(self.done.load(.acquire));
        try std.testing.expectEqual(error.Canceled, self.failure.?);
    }
};

test "controlled sockets: cancellation interrupts backpressure without closing a descriptor" {
    if (!Control.supported()) return error.SkipZigTest;
    const sockets = try socketPairUnixStream();
    defer close(sockets[0]);
    defer close(sockets[1]);
    try setNonBlocking(sockets[0]);
    const fill: [8192]u8 = @splat(1);
    var filled: usize = 0;
    while (filled < 16 * 1024 * 1024) {
        filled += sendNoSignal(sockets[0], &fill) catch |err| {
            if (err == error.WouldBlock) break;
            return err;
        };
    }
    try std.testing.expect(filled < 16 * 1024 * 1024);
    var control = Control{ .deadline_ns = try Control.clock() + std.time.ns_per_s, .bytes_remaining = 65536 };
    var worker = ControlledSocketWorker{ .socket = sockets[0], .control = &control };
    try worker.cancelAndJoin();
    var read_back: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try recv(sockets[1], &read_back, 0));
}

test "controlled sockets: full local accept queue bounds connect deadline and cancellation" {
    if (!Control.supported()) return error.SkipZigTest;
    const listener = try tcpStreamSocket(.{ .nonblocking = true, .close_on_exec = true });
    defer close(listener);
    try bindIp4(listener, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try listen(listener, 1);
    const address: IpAddress = .{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, try socketPort(listener)) };
    const first = try tcpStreamSocket(.{});
    defer close(first);
    const second = try tcpStreamSocket(.{});
    defer close(second);
    var control = Control{ .deadline_ns = try Control.clock() + std.time.ns_per_s, .bytes_remaining = 1024 };
    try control.connectTo(first, address);
    try control.connectTo(second, address);
    const pending = try tcpStreamSocket(.{});
    defer close(pending);
    control = .{ .deadline_ns = try Control.clock() + 30 * std.time.ns_per_ms, .bytes_remaining = 1024 };
    try std.testing.expectError(error.DeadlineExceeded, control.connectTo(pending, address));
    try std.testing.expect(try Control.clock() < control.deadline_ns + 100 * std.time.ns_per_ms);
    const canceled = try tcpStreamSocket(.{});
    defer close(canceled);
    control = .{ .deadline_ns = try Control.clock() + std.time.ns_per_s, .bytes_remaining = 1024 };
    var worker = ControlledSocketWorker{ .socket = canceled, .address = address, .control = &control };
    try worker.cancelAndJoin();
}

test "controlled sockets: explicit DNS over TCP and exact wire budget" {
    if (!Control.supported()) return error.SkipZigTest;
    const listener = try tcpStreamSocket(.{});
    defer close(listener);
    try bindIp4(listener, ip4Address(.{ 127, 0, 0, 1 }, 0));
    try listen(listener, 1);
    const nameserver: IpAddress = .{ .ip4 = ip4Address(.{ 127, 0, 0, 1 }, try socketPort(listener)) };
    var server = TestTcpDnsServer{ .socket = listener };
    const thread = try @import("root.zig").thread.spawn(TestTcpDnsServer.run, .{&server});
    var control = Control{ .deadline_ns = try Control.clock() + std.time.ns_per_s, .bytes_remaining = 4096 };
    const resolved = control.resolve("example.test", 443, nameserver, .ip4);
    thread.join();
    if (server.err) |err| return err;
    try expectIp4Address((try resolved).ip4, .{ 127, 0, 0, 42 }, 443);
    const sockets = try socketPairUnixStream();
    defer close(sockets[0]);
    defer close(sockets[1]);
    control = .{ .deadline_ns = try Control.clock() + std.time.ns_per_s, .bytes_remaining = 1 };
    try std.testing.expectEqual(@as(usize, 1), try control.transmit(sockets[0], "xy"));
    try std.testing.expectError(error.TransferCapacityExceeded, control.transmit(sockets[0], "y"));
}
