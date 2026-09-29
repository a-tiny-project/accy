//! Process-group membership census over the host process table.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const backend = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("darwin.zig"),
    else => @import("unsupported.zig"),
};

/// Reports whether any member of `group_id`, its leader included, still runs.
/// A member that exited counts as gone while its parent or an adopting
/// subreaper still owns the zombie entry, because an exited process holds no
/// descriptor. Members that vanish during the scan count as gone. A process
/// whose group or state cannot be read returns that error, so membership that
/// cannot be established never reads as drained. The scan visits at most
/// `storage.len` processes and refuses a larger table with `BufferTooSmall`.
/// On Linux a procfs that shows another pid namespace refuses with
/// `QueryFailed`. Callers treat every error as possibly running.
pub fn groupRunning(
    group_id: types.ProcessId,
    storage: []types.ProcessId,
) types.Error!bool {
    if (group_id <= 1) return error.ProcessNotFound;
    if (comptime builtin.os.tag == .linux) {
        if (!try procfsSharesPidView()) return error.QueryFailed;
    }
    const processes = try backend.list(storage);
    for (processes) |pid| {
        const member_group = backend.group(pid) catch |err| switch (err) {
            error.ProcessNotFound => continue,
            else => return err,
        };
        if (member_group != group_id) continue;
        const member = backend.info(pid) catch |err| switch (err) {
            error.ProcessNotFound => continue,
            else => return err,
        };
        if (member.alive) return true;
    }
    return false;
}

fn procfsSharesPidView() types.Error!bool {
    var storage: [16]u8 = undefined;
    const count = std.Io.Dir.cwd().readLink(std.Options.debug_io, "/proc/self", &storage) catch
        return error.QueryFailed;
    if (count >= storage.len) return error.InvalidData;
    const viewed = std.fmt.parseUnsigned(types.ProcessId, storage[0..count], 10) catch
        return error.InvalidData;
    return viewed == std.os.linux.getpid();
}
