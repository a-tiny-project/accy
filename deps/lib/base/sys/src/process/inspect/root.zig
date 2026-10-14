const builtin = @import("builtin");
const sys = @import("../../root.zig");
const types = @import("types.zig");

const backend = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("darwin.zig"),
    else => @import("unsupported.zig"),
};

pub const required_capabilities = sys.capabilities.host(
    &.{ .filesystem, .libc_interop, .process },
);

pub const Error = types.Error;
pub const ProcessId = types.ProcessId;
pub const Descriptor = types.Descriptor;
pub const DarwinTime = types.DarwinTime;
pub const Start = types.Start;
pub const Info = types.Info;
pub const parseStartToken = types.parseStartToken;

pub const list = backend.list;
pub const children = backend.children;
pub const info = backend.info;
pub const group = backend.group;
pub const exists = backend.exists;
pub const exitDescriptor = backend.exitDescriptor;
pub const name = backend.name;
pub const fds = backend.fds;
pub const fdPath = backend.fdPath;
pub const fdFlock = backend.fdFlock;
pub const cwd = backend.cwd;
pub const command = backend.command;
pub const environment = backend.environment;
pub const hostname = backend.hostname;
pub const pidNamespace = backend.pidNamespace;
pub const cgroup = backend.cgroup;
pub const namespaceInit = backend.namespaceInit;
pub const groupRunning = @import("census.zig").groupRunning;
