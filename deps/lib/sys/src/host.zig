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

test "Linux available memory parser uses binary kibibytes" {
    const text =
        "MemTotal:       32768000 kB\n" ++
        "MemFree:         1048576 kB\n" ++
        "MemAvailable:   12582912 kB\n";
    try std.testing.expectEqual(
        @as(u64, 12 * 1024 * 1024 * 1024),
        try parseLinuxAvailableMemory(text),
    );
}

test "Linux available memory parser rejects missing duplicate and malformed values" {
    try std.testing.expectError(
        error.InvalidData,
        parseLinuxAvailableMemory("MemFree: 1 kB\n"),
    );
    try std.testing.expectError(
        error.InvalidData,
        parseLinuxAvailableMemory("MemAvailable: 1 kB\nMemAvailable: 2 kB\n"),
    );
    try std.testing.expectError(
        error.InvalidCharacter,
        parseLinuxAvailableMemory("MemAvailable: unknown kB\n"),
    );
    try std.testing.expectError(
        error.InvalidData,
        parseLinuxAvailableMemory("MemAvailable: 1 MB\n"),
    );
}

test "Linux cgroup membership distinguishes unified and memory controllers" {
    const unified = try parseCgroupMembership("0::/executor/slot\n");
    try std.testing.expectEqualStrings("/executor/slot", unified.v2.?);
    const legacy = try parseCgroupMembership("4:cpu,memory:/executor/slot\n");
    try std.testing.expectEqualStrings("/executor/slot", legacy.v1_memory.?);
    try std.testing.expectError(
        error.InvalidData,
        parseCgroupMembership("0::/safe/../escape\n"),
    );
}

test "Linux cgroup mount discovery accepts custom controller roots" {
    const mounts = try parseCgroupMounts(
        "36 25 0:32 /tenant /custom/unified rw,nosuid - cgroup2 cgroup rw\n" ++
            "37 25 0:33 /legacy /custom/memory rw,nosuid - cgroup cgroup rw,memory\n",
    );
    try std.testing.expectEqualStrings("/tenant", mounts.v2.?.root);
    try std.testing.expectEqualStrings("/custom/unified", mounts.v2.?.point);
    try std.testing.expectEqualStrings("/legacy", mounts.v1_memory.?.root);
    try std.testing.expectEqualStrings("/custom/memory", mounts.v1_memory.?.point);
}

test "Linux declared cgroup membership requires an observed mount" {
    try std.testing.expectError(
        error.CgroupTelemetryUnavailable,
        cgroupHeadroom(
            std.testing.io,
            .{ .v2 = "/executor" },
            .{},
        ),
    );
}

test "Linux cgroup headroom uses the tightest enclosing limit" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "parent/leaf");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "memory.max",
        .data = "max\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "parent/memory.max",
        .data = "800\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "parent/memory.current",
        .data = "300\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "parent/leaf/memory.max",
        .data = "1000\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "parent/leaf/memory.current",
        .data = "400\n",
    });
    const base = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(base);
    const observed = (try cgroupHierarchyHeadroom(
        std.testing.io,
        base,
        "/parent/leaf",
        "memory.max",
        "memory.current",
    )).?;
    try std.testing.expectEqual(@as(?u64, 500), observed.bytes);
}

test "Linux cgroup subtree mounts map membership relative to mount root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "job");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "memory.max",
        .data = "max\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "job/memory.max",
        .data = "1000\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "job/memory.current",
        .data = "400\n",
    });
    const base = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(base);
    const observed = try cgroupMountHeadroom(
        std.testing.io,
        "/tenant/job",
        .{ .root = "/tenant", .point = base },
        "memory.max",
        "memory.current",
        true,
    );
    try std.testing.expectEqual(@as(?u64, 600), observed);
}

test "Linux cgroup discovered mount without memory files fails closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "executor");
    const base = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(base);
    try std.testing.expectError(
        error.CgroupTelemetryUnavailable,
        cgroupMountHeadroom(
            std.testing.io,
            "/executor",
            .{ .root = "/", .point = base },
            "memory.max",
            "memory.current",
            true,
        ),
    );
}

test "Linux cgroup root without a v2 memory controller is unlimited" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "executor");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "cgroup.controllers",
        .data = "cpuset\n",
    });
    const base = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(base);
    const observed = try cgroupMountHeadroom(
        std.testing.io,
        "/executor",
        .{ .root = "/", .point = base },
        "memory.max",
        "memory.current",
        true,
    );
    try std.testing.expectEqual(@as(?u64, null), observed);
}

test "Linux cgroup active v2 edge missing memory files fails closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "executor");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "cgroup.controllers",
        .data = "memory\n",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "cgroup.subtree_control",
        .data = "memory\n",
    });
    const base = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(base);
    try std.testing.expectError(
        error.CgroupTelemetryUnavailable,
        cgroupMountHeadroom(
            std.testing.io,
            "/executor",
            .{ .root = "/", .point = base },
            "memory.max",
            "memory.current",
            true,
        ),
    );
}

test "Linux cgroup subtree mount without memory files fails closed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "job");
    const base = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(base);
    try std.testing.expectError(
        error.CgroupTelemetryUnavailable,
        cgroupMountHeadroom(
            std.testing.io,
            "/tenant/job",
            .{ .root = "/tenant", .point = base },
            "memory.max",
            "memory.current",
            true,
        ),
    );
}

test "Linux cgroup values reject malformed data and saturate exhausted limits" {
    try std.testing.expectError(error.InvalidData, parseMemoryLimit(""));
    try std.testing.expectError(error.InvalidCharacter, parseMemoryLimit("unknown"));
    try std.testing.expectError(error.InvalidData, parseMemoryCurrent(""));
    try std.testing.expectError(error.InvalidCharacter, parseMemoryCurrent("unknown"));
    try std.testing.expectEqual(@as(u64, 0), remainingMemory(100, 101));
    try std.testing.expectEqual(@as(u64, 1), remainingMemory(100, 99));
}

test "Darwin pressure sysctl decodes dispatch note flags" {
    try std.testing.expectEqual(Pressure.normal, try decodeDarwinPressure(1));
    try std.testing.expectEqual(Pressure.pressured, try decodeDarwinPressure(2));
    try std.testing.expectEqual(Pressure.pressured, try decodeDarwinPressure(4));
    try std.testing.expectError(error.InvalidData, decodeDarwinPressure(0));
    try std.testing.expectError(error.InvalidData, decodeDarwinPressure(3));
}

test "Darwin percent-free memory conversion is bounded and conservative" {
    try std.testing.expectEqual(
        @as(u64, 16 * 1024 * 1024 * 1024),
        try availableFromPercent(64 * 1024 * 1024 * 1024, 25),
    );
    try std.testing.expectEqual(@as(u64, 1), try availableFromPercent(101, 1));
    try std.testing.expectError(error.InvalidData, availableFromPercent(1, 101));
}

test "host memory is a bounded observation" {
    if (comptime builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) {
        return error.SkipZigTest;
    }
    const observed = try memory(std.testing.io);
    try std.testing.expect(observed.available_bytes > 0);
    if (comptime builtin.os.tag == .linux) {
        try std.testing.expectEqual(Pressure.normal, observed.pressure);
    }
}
