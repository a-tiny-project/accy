//! Code above `lib/base/sys` reaches the platform through this surface, and the
//! platform-sensitive parts of `std`, libc, `@cImport`, and the platform
//! libraries stay below it. One namespace per area of the operating system
//! spans descriptors, virtual memory, processes and threads, and what a running
//! program does to its host: files, sockets, clocks, standard streams, and the
//! environment. Whatever descriptor, virtual memory mapping, process, or thread
//! the operating system hands back is a *host resource* that stays the caller's
//! to release, which means the caller closes the descriptors it received and
//! unmaps the memory it mapped. A call that fails turns the platform's status
//! code or errno into a Zig error value before it returns, producing a *typed
//! error* that keeps raw numbers out of the code above.

pub const allocator = @import("allocator.zig");
pub const ancillary = @import("ancillary.zig");
pub const apple = @import("apple/root.zig");
pub const atomic = @import("atomic/root.zig");
pub const audio = @import("audio.zig");
pub const backtrace = @import("backtrace.zig");
pub const capabilities = @import("capabilities.zig");
pub const cgroup = @import("cgroup.zig");
pub const context = @import("context.zig");
pub const coreaudio = @import("coreaudio.zig");
pub const cuda = @import("cuda.zig");
pub const drm = @import("drm.zig");
pub const dynamic = @import("dynamic.zig");
pub const env = @import("env.zig");
pub const errno = @import("errno.zig");
pub const evdev = @import("evdev.zig");
pub const event = @import("event/root.zig");
pub const fd = @import("fd.zig");
pub const font = @import("font/root.zig");
pub const fs = @import("fs.zig");
pub const heap = @import("heap.zig");
pub const host = @import("host.zig");
pub const kvm = @import("kvm/root.zig");
pub const math = @import("math.zig");
pub const memory = @import("memory.zig");
pub const net = @import("net.zig");
pub const path = @import("path.zig");
pub const panic = @import("panic.zig");
pub const perf = @import("perf.zig");
pub const poll = @import("poll.zig");
pub const process = @import("process/root.zig");
pub const pty = @import("pty.zig");
pub const pulse = @import("pulse.zig");
pub const random = @import("random.zig");
pub const rseq = @import("rseq/root.zig");
pub const signal = @import("signal.zig");
pub const stdio = @import("stdio.zig");
pub const std_options = @import("options.zig");
pub const terminal = @import("terminal.zig");
pub const thread = @import("thread.zig");
pub const time = @import("time.zig");
pub const timer = @import("timer.zig");
pub const tinyrt = @import("tinyrt.zig");
pub const tls = @import("tls.zig");
pub const vulkan = @import("vulkan.zig");

pub const CoreaudioPlaybackStorage = @import("coreaudio.zig").Storage;
pub const PulseControlStorage = @import("pulse.zig").ControlStorage;
