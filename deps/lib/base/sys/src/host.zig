//! Host-wide resource observations, each read from the operating system at the
//! moment of the call.
//!
//! `memory` reports available memory together with a pressure level, while
//! `availableMemoryBytes` reports the byte count alone. On Linux *available
//! memory*, the byte count the host reports as allocatable without swapping,
//! comes from `MemAvailable` in `/proc/meminfo`, and pressure always reports
//! normal. When the process belongs to a control group with a memory limit, the
//! call reports the smaller of the host number and the group's *headroom*, the
//! limit minus current usage, taken across every enclosing group and across
//! both the unified and the version one hierarchies. On Darwin available memory
//! comes from the percent-free level and the total system memory, and
//! *pressure*, the Darwin memory pressure level reported as normal or
//! pressured, comes from a sysctl.
//!
//! A declared control group membership whose mount is missing, and a mount
//! whose memory files cannot be read, both fail with
//! `CgroupTelemetryUnavailable`, so a limit that cannot be read never passes as
//! unlimited headroom. Every file is read into fixed storage, and a file that
//! fills its storage fails with `BufferTooSmall`. Every other platform returns
//! `UnsupportedPlatform`.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.host(&.{
    .filesystem,
    .platform_frameworks,
});

const meminfo_path = "/proc/meminfo";
const cgroup_path = "/proc/self/cgroup";
const mountinfo_path = "/proc/self/mountinfo";
const meminfo_bytes_max: usize = 16 * 1024;
const cgroup_bytes_max: usize = 16 * 1024;
const mountinfo_bytes_max: usize = 128 * 1024;
const cgroup_value_bytes_max: usize = 256;

pub const Pressure = enum {
    normal,
    pressured,
};

pub const Memory = struct {
    available_bytes: u64,
    pressure: Pressure,
};

const CgroupMembership = struct {
    v2: ?[]const u8 = null,
    v1_memory: ?[]const u8 = null,
};

const CgroupMount = struct {
    root: []const u8,
    point: []const u8,
};

const CgroupMounts = struct {
    v2: ?CgroupMount = null,
    v1_memory: ?CgroupMount = null,
};

const HierarchyHeadroom = struct {
    bytes: ?u64 = null,
};

const MemoryLimit = union(enum) {
    unlimited,
    finite: u64,
};

extern "c" fn memorystatus_get_level(level_address: usize) c_int;

pub fn memory(io: std.Io) !Memory {
    return switch (comptime builtin.os.tag) {
        .linux => linuxMemory(io),
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => darwinMemory(),
        else => error.UnsupportedPlatform,
    };
}

pub fn availableMemoryBytes(io: std.Io) !u64 {
    return (try memory(io)).available_bytes;
}

fn linuxMemory(io: std.Io) !Memory {
    const host_available = try linuxHostAvailableMemoryBytes(io);
    const cgroup_available = try linuxCgroupHeadroom(io);
    return .{
        .available_bytes = if (cgroup_available) |available|
            @min(host_available, available)
        else
            host_available,
        .pressure = .normal,
    };
}

fn linuxHostAvailableMemoryBytes(io: std.Io) !u64 {
    var storage: [meminfo_bytes_max]u8 = undefined;
    return parseLinuxAvailableMemory(try readBounded(io, meminfo_path, &storage));
}

fn linuxCgroupHeadroom(io: std.Io) !?u64 {
    var membership_storage: [cgroup_bytes_max]u8 = undefined;
    const membership = try parseCgroupMembership(try readBounded(
        io,
        cgroup_path,
        &membership_storage,
    ));
    var mountinfo_storage: [mountinfo_bytes_max]u8 = undefined;
    const mounts = try parseCgroupMounts(try readBounded(
        io,
        mountinfo_path,
        &mountinfo_storage,
    ));
    return cgroupHeadroom(io, membership, mounts);
}

fn cgroupHeadroom(
    io: std.Io,
    membership: CgroupMembership,
    mounts: CgroupMounts,
) !?u64 {
    var result: ?u64 = null;
    if (membership.v2) |group| {
        const mount = mounts.v2 orelse return error.CgroupTelemetryUnavailable;
        if (try cgroupMountHeadroom(
            io,
            group,
            mount,
            "memory.max",
            "memory.current",
            true,
        )) |headroom| result = @min(result orelse headroom, headroom);
    }
    if (membership.v1_memory) |group| {
        const mount = mounts.v1_memory orelse return error.CgroupTelemetryUnavailable;
        if (try cgroupMountHeadroom(
            io,
            group,
            mount,
            "memory.limit_in_bytes",
            "memory.usage_in_bytes",
            false,
        )) |headroom| result = @min(result orelse headroom, headroom);
    }
    return result;
}

fn parseCgroupMounts(text: []const u8) !CgroupMounts {
    var result: CgroupMounts = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const separator = std.mem.indexOf(u8, line, " - ") orelse
            return error.InvalidData;
        var mounted = std.mem.tokenizeScalar(u8, line[0..separator], ' ');
        _ = mounted.next() orelse return error.InvalidData;
        _ = mounted.next() orelse return error.InvalidData;
        _ = mounted.next() orelse return error.InvalidData;
        const root = mounted.next() orelse return error.InvalidData;
        const mount_point = mounted.next() orelse return error.InvalidData;
        var filesystem = std.mem.tokenizeScalar(u8, line[separator + 3 ..], ' ');
        const kind = filesystem.next() orelse return error.InvalidData;
        _ = filesystem.next() orelse return error.InvalidData;
        const options = filesystem.next() orelse return error.InvalidData;
        if (std.mem.eql(u8, kind, "cgroup2")) {
            try validateCgroupMount(root, mount_point);
            if (result.v2 != null) return error.InvalidData;
            result.v2 = .{ .root = root, .point = mount_point };
        } else if (std.mem.eql(u8, kind, "cgroup") and
            controllerListed(options, "memory"))
        {
            try validateCgroupMount(root, mount_point);
            if (result.v1_memory != null) return error.InvalidData;
            result.v1_memory = .{ .root = root, .point = mount_point };
        }
    }
    return result;
}

fn validateCgroupMount(root: []const u8, point: []const u8) !void {
    if (!validCgroupGroup(root) or
        !std.fs.path.isAbsolute(point) or
        std.mem.indexOfScalar(u8, point, '\\') != null)
    {
        return error.InvalidData;
    }
}

fn cgroupMountHeadroom(
    io: std.Io,
    group: []const u8,
    mount: CgroupMount,
    limit_name: []const u8,
    current_name: []const u8,
    allow_inactive_v2: bool,
) !?u64 {
    const relative_group = try mountedCgroup(mount.root, group);
    const hierarchy = try cgroupHierarchyHeadroom(
        io,
        mount.point,
        relative_group,
        limit_name,
        current_name,
    );
    if (hierarchy) |observed| return observed.bytes;
    if (!allow_inactive_v2 or !std.mem.eql(u8, mount.root, "/")) {
        return error.CgroupTelemetryUnavailable;
    }
    const inactive = v2MemoryControllerInactive(
        io,
        mount.point,
        relative_group,
    ) catch return error.CgroupTelemetryUnavailable;
    if (!inactive) return error.CgroupTelemetryUnavailable;
    return null;
}

fn mountedCgroup(root: []const u8, group: []const u8) ![]const u8 {
    if (!validCgroupGroup(root) or !validCgroupGroup(group)) {
        return error.InvalidData;
    }
    if (std.mem.eql(u8, root, "/")) return group;
    if (!std.mem.startsWith(u8, group, root)) {
        return error.CgroupTelemetryUnavailable;
    }
    if (group.len == root.len) return "/";
    if (group[root.len] != '/') return error.CgroupTelemetryUnavailable;
    return group[root.len..];
}

fn v2MemoryControllerInactive(
    io: std.Io,
    base: []const u8,
    group: []const u8,
) !bool {
    if (!validCgroupGroup(group)) return error.InvalidData;
    var controllers_path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const controllers_path = try hierarchyPath(
        &controllers_path_storage,
        base,
        "",
        "cgroup.controllers",
    );
    var controllers_storage: [cgroup_value_bytes_max]u8 = undefined;
    if (!wordListed(
        try readBounded(io, controllers_path, &controllers_storage),
        "memory",
    )) return true;
    var child = std.mem.trim(u8, group, "/");
    while (cgroupParent(child)) |parent| {
        var path_storage: [std.fs.max_path_bytes]u8 = undefined;
        const path = try hierarchyPath(
            &path_storage,
            base,
            parent,
            "cgroup.subtree_control",
        );
        var value_storage: [cgroup_value_bytes_max]u8 = undefined;
        if (wordListed(try readBounded(io, path, &value_storage), "memory")) {
            return false;
        }
        child = parent;
    }
    return true;
}

fn cgroupHierarchyHeadroom(
    io: std.Io,
    base: []const u8,
    group: []const u8,
    limit_name: []const u8,
    current_name: []const u8,
) !?HierarchyHeadroom {
    if (!validCgroupGroup(group)) return error.InvalidData;
    var result: HierarchyHeadroom = .{};
    var observed = false;
    var current = std.mem.trim(u8, group, "/");
    while (true) {
        var limit_path_storage: [std.fs.max_path_bytes]u8 = undefined;
        const limit_path = try hierarchyPath(
            &limit_path_storage,
            base,
            current,
            limit_name,
        );
        var limit_storage: [cgroup_value_bytes_max]u8 = undefined;
        const limit_text = readBounded(io, limit_path, &limit_storage) catch |err| switch (err) {
            error.FileNotFound => {
                current = cgroupParent(current) orelse break;
                continue;
            },
            else => return err,
        };
        observed = true;
        switch (try parseMemoryLimit(limit_text)) {
            .unlimited => {},
            .finite => |limit| {
                var current_path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const current_path = try hierarchyPath(
                    &current_path_storage,
                    base,
                    current,
                    current_name,
                );
                var current_storage: [cgroup_value_bytes_max]u8 = undefined;
                const usage = try parseMemoryCurrent(try readBounded(
                    io,
                    current_path,
                    &current_storage,
                ));
                const headroom = remainingMemory(limit, usage);
                result.bytes = @min(result.bytes orelse headroom, headroom);
            },
        }
        current = cgroupParent(current) orelse break;
    }
    return if (observed) result else null;
}

fn parseCgroupMembership(text: []const u8) !CgroupMembership {
    var result: CgroupMembership = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ':');
        const hierarchy = fields.next() orelse return error.InvalidData;
        const controllers = fields.next() orelse return error.InvalidData;
        const group = fields.next() orelse return error.InvalidData;
        if (fields.next() != null or !validCgroupGroup(group)) return error.InvalidData;
        if (std.mem.eql(u8, hierarchy, "0") and controllers.len == 0) {
            if (result.v2 != null) return error.InvalidData;
            result.v2 = group;
        } else if (controllerListed(controllers, "memory")) {
            if (result.v1_memory != null) return error.InvalidData;
            result.v1_memory = group;
        }
    }
    return result;
}

fn controllerListed(controllers: []const u8, expected: []const u8) bool {
    var values = std.mem.splitScalar(u8, controllers, ',');
    while (values.next()) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn wordListed(words: []const u8, expected: []const u8) bool {
    var values = std.mem.tokenizeAny(u8, words, " \t\r\n");
    while (values.next()) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn validCgroupGroup(group: []const u8) bool {
    if (group.len == 0 or group[0] != '/') return false;
    var components = std.mem.splitScalar(u8, group[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0) return group.len == 1;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return false;
        }
    }
    return true;
}

fn hierarchyPath(
    storage: []u8,
    base: []const u8,
    group: []const u8,
    name: []const u8,
) ![]const u8 {
    return if (group.len == 0)
        std.fmt.bufPrint(storage, "{s}/{s}", .{ base, name })
    else
        std.fmt.bufPrint(storage, "{s}/{s}/{s}", .{ base, group, name });
}

fn cgroupParent(group: []const u8) ?[]const u8 {
    if (group.len == 0) return null;
    const separator = std.mem.lastIndexOfScalar(u8, group, '/') orelse return "";
    return group[0..separator];
}

fn parseMemoryLimit(text: []const u8) !MemoryLimit {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.eql(u8, value, "max")) return .unlimited;
    if (value.len == 0) return error.InvalidData;
    return .{ .finite = try std.fmt.parseUnsigned(u64, value, 10) };
}

fn parseMemoryCurrent(text: []const u8) !u64 {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return error.InvalidData;
    return std.fmt.parseUnsigned(u64, value, 10);
}

fn remainingMemory(limit: u64, current: u64) u64 {
    return limit -| current;
}

fn readBounded(io: std.Io, path: []const u8, storage: []u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const count = try file.readPositionalAll(io, storage, 0);
    if (count == storage.len) return error.BufferTooSmall;
    return storage[0..count];
}

fn parseLinuxAvailableMemory(text: []const u8) !u64 {
    var found: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r:");
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, "MemAvailable")) continue;
        if (found != null) return error.InvalidData;
        const kib = try std.fmt.parseUnsigned(u64, fields.next() orelse
            return error.InvalidData, 10);
        if (!std.mem.eql(u8, fields.next() orelse return error.InvalidData, "kB") or
            fields.next() != null)
        {
            return error.InvalidData;
        }
        found = try std.math.mul(u64, kib, 1024);
    }
    return found orelse error.InvalidData;
}

fn darwinMemory() !Memory {
    var percent_free: c_uint = 0;
    if (memorystatus_get_level(@intFromPtr(&percent_free)) != 0) {
        return error.QueryFailed;
    }
    const total = try std.process.totalSystemMemory();
    const available = try availableFromPercent(total, percent_free);
    var pressure_level: c_uint = 0;
    var pressure_size: usize = @sizeOf(c_uint);
    if (std.c.sysctlbyname(
        "kern.memorystatus_vm_pressure_level",
        &pressure_level,
        &pressure_size,
        null,
        0,
    ) != 0 or pressure_size != @sizeOf(c_uint)) return error.QueryFailed;
    return .{
        .available_bytes = available,
        .pressure = try decodeDarwinPressure(pressure_level),
    };
}

fn availableFromPercent(total: u64, percent: c_uint) !u64 {
    if (percent > 100) return error.InvalidData;
    return @intCast(@as(u128, total) * percent / 100);
}

fn decodeDarwinPressure(level: c_uint) !Pressure {
    return switch (level) {
        1 => .normal,
        2, 4 => .pressured,
        else => error.InvalidData,
    };
}
