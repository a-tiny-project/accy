const std = @import("std");
const builtin = @import("builtin");

const fs_io = std.Options.debug_io;
const gibibyte: u64 = 1024 * 1024 * 1024;
const max_cgroup_bytes = 16 * 1024;
const max_path_bytes = 4096;
const max_value_bytes = 256;
const capacity_policy = @embedFile("capacity.policy");
const max_capacity_policy_bytes = 1024;
const mebibyte: u64 = 1024 * 1024;

pub const max_waiters_per_lane: u32 = 64;
pub const max_queue_lanes: u32 = 2;
pub const max_ticket: u64 = std.math.maxInt(u64);
pub const max_u64: u64 = std.math.maxInt(u64);
pub const cpu_environment = "TINY_BUILD_RESOURCE_CPU_COUNT";
pub const memory_environment = "TINY_BUILD_RESOURCE_TOTAL_MIB";
pub const effective_cpu_environment = "TINY_BUILD_EFFECTIVE_CPU_COUNT";
pub const effective_memory_environment = "TINY_BUILD_EFFECTIVE_TOTAL_MIB";
pub const effective_tree_environment = "TINY_BUILD_EFFECTIVE_TREE_MIB";

const CapacityPolicy = struct {
    host_reserve_mib: u64,
    default_memory_claim_mib: u64,
    fallback_memory_claim_mib: u64,
    toolchain_memory_claim_mib: u64,
    tree_overhead_reserve_mib: u64,
    test_step_memory_claim_mib: u64,
    compile_step_memory_claim_mib: u64,
    ordinary_max_slots: u64,
    heavy_max_slots: u64,
    build_cpu_claim: u64,
    max_cpu_tokens: u64,
    max_resource_fds: u64,
};

const configured_policy = configured: {
    if (capacity_policy.len >= max_capacity_policy_bytes) {
        @compileError("capacity policy exceeds its byte bound");
    }
    const parsed = parsePolicy(capacity_policy) catch |err|
        @compileError("invalid capacity policy: " ++ @errorName(err));
    const cpu_fds: u64 = @intCast(@min(
        parsed.build_cpu_claim,
        parsed.max_cpu_tokens,
    ));
    const memory_fds: u64 = 1;
    const upgraded_fds = @as(u64, 2) + cpu_fds + memory_fds;
    if (parsed.compile_step_memory_claim_mib > parsed.test_step_memory_claim_mib) {
        @compileError("capacity policy compile claim exceeds the test step claim");
    }
    if (parsed.default_memory_claim_mib > parsed.fallback_memory_claim_mib) {
        @compileError("capacity policy default claim exceeds the fallback claim");
    }
    if (upgraded_fds > parsed.max_resource_fds) {
        @compileError("capacity policy exceeds the inherited descriptor bound");
    }
    break :configured parsed;
};
const build_cpu_claim: u32 = @intCast(configured_policy.build_cpu_claim);
const max_cpu_tokens: u32 = @intCast(configured_policy.max_cpu_tokens);
pub const max_resource_fds: u32 = @intCast(configured_policy.max_resource_fds);

pub fn buildCpuClaim() u32 {
    return build_cpu_claim;
}

pub const Capacity = struct {
    cpu_count: usize,
    memory_bytes: u64,
    cpu_limited: bool = false,
    memory_limited: bool = false,
    /// Holds the process-tree memory allowance granted by the executing lane.
    /// A direct invocation outside any lane leaves it absent.
    tree_bytes: ?u64 = null,

    pub fn init(cpu_count: usize, memory_bytes: u64) Capacity {
        return .{
            .cpu_count = @max(1, cpu_count),
            .memory_bytes = @max(1, memory_bytes),
        };
    }
};

pub const Policy = struct {
    memory_reserve: u64,
    process_memory_claim: u64,
    max_slots: u32,

    pub fn slots(policy: Policy, capacity: Capacity, requested: u32) u32 {
        std.debug.assert(requested > 0);
        const cpu_slots: u32 = @intCast(@min(
            capacity.cpu_count,
            std.math.maxInt(u32),
        ));
        return @min(
            requested,
            policy.max_slots,
            cpu_slots,
        );
    }
};

pub const ordinary = Policy{
    .memory_reserve = policyMib(configured_policy.host_reserve_mib),
    .process_memory_claim = policyMib(configured_policy.default_memory_claim_mib),
    .max_slots = @intCast(configured_policy.ordinary_max_slots),
};

pub const heavy = Policy{
    .memory_reserve = policyMib(configured_policy.host_reserve_mib),
    .process_memory_claim = policyMib(configured_policy.fallback_memory_claim_mib),
    .max_slots = @intCast(configured_policy.heavy_max_slots),
};

fn policyMib(value: u64) u64 {
    return std.math.mul(u64, value, mebibyte) catch
        @compileError("capacity policy MiB value overflows u64");
}

fn parsePolicy(text: []const u8) !CapacityPolicy {
    @setEvalBranchQuota(10_000);
    var host_reserve_mib: ?u64 = null;
    var default_memory_claim_mib: ?u64 = null;
    var fallback_memory_claim_mib: ?u64 = null;
    var toolchain_memory_claim_mib: ?u64 = null;
    var tree_overhead_reserve_mib: ?u64 = null;
    var test_step_memory_claim_mib: ?u64 = null;
    var compile_step_memory_claim_mib: ?u64 = null;
    var ordinary_max_slots: ?u64 = null;
    var heavy_max_slots: ?u64 = null;
    var parsed_build_cpu_claim: ?u64 = null;
    var parsed_max_cpu_tokens: ?u64 = null;
    var parsed_max_resource_fds: ?u64 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.MissingEquals;
        const name = line[0..separator];
        const value = line[separator + 1 ..];
        if (std.mem.eql(u8, name, "host_reserve_mib"))
            try setPolicyValue(&host_reserve_mib, value)
        else if (std.mem.eql(u8, name, "default_memory_claim_mib"))
            try setPolicyValue(&default_memory_claim_mib, value)
        else if (std.mem.eql(u8, name, "fallback_memory_claim_mib"))
            try setPolicyValue(&fallback_memory_claim_mib, value)
        else if (std.mem.eql(u8, name, "toolchain_memory_claim_mib"))
            try setPolicyValue(&toolchain_memory_claim_mib, value)
        else if (std.mem.eql(u8, name, "tree_overhead_reserve_mib"))
            try setPolicyValue(&tree_overhead_reserve_mib, value)
        else if (std.mem.eql(u8, name, "test_step_memory_claim_mib"))
            try setPolicyValue(&test_step_memory_claim_mib, value)
        else if (std.mem.eql(u8, name, "compile_step_memory_claim_mib"))
            try setPolicyValue(&compile_step_memory_claim_mib, value)
        else if (std.mem.eql(u8, name, "ordinary_max_slots"))
            try setPolicyValue(&ordinary_max_slots, value)
        else if (std.mem.eql(u8, name, "heavy_max_slots"))
            try setPolicyValue(&heavy_max_slots, value)
        else if (std.mem.eql(u8, name, "build_cpu_claim"))
            try setPolicyValue(&parsed_build_cpu_claim, value)
        else if (std.mem.eql(u8, name, "max_cpu_tokens"))
            try setPolicyValue(&parsed_max_cpu_tokens, value)
        else if (std.mem.eql(u8, name, "max_resource_fds"))
            try setPolicyValue(&parsed_max_resource_fds, value)
        else
            return error.UnknownSetting;
    }
    return .{
        .host_reserve_mib = host_reserve_mib orelse
            return error.MissingSetting,
        .default_memory_claim_mib = default_memory_claim_mib orelse
            return error.MissingSetting,
        .fallback_memory_claim_mib = fallback_memory_claim_mib orelse
            return error.MissingSetting,
        .toolchain_memory_claim_mib = toolchain_memory_claim_mib orelse
            return error.MissingSetting,
        .tree_overhead_reserve_mib = tree_overhead_reserve_mib orelse
            return error.MissingSetting,
        .test_step_memory_claim_mib = test_step_memory_claim_mib orelse
            return error.MissingSetting,
        .compile_step_memory_claim_mib = compile_step_memory_claim_mib orelse
            return error.MissingSetting,
        .ordinary_max_slots = ordinary_max_slots orelse return error.MissingSetting,
        .heavy_max_slots = heavy_max_slots orelse return error.MissingSetting,
        .build_cpu_claim = parsed_build_cpu_claim orelse return error.MissingSetting,
        .max_cpu_tokens = parsed_max_cpu_tokens orelse return error.MissingSetting,
        .max_resource_fds = parsed_max_resource_fds orelse return error.MissingSetting,
    };
}

fn setPolicyValue(slot: *?u64, text: []const u8) !void {
    if (slot.* != null) return error.DuplicateSetting;
    const value = std.fmt.parseUnsigned(u64, text, 10) catch
        return error.InvalidValue;
    if (value == 0) return error.InvalidValue;
    slot.* = value;
}

pub const Admission = struct {
    cpu_tokens: u32,
    memory_tokens: u32,
    ordinary_cpu_weight: u32,
    heavy_cpu_weight: u32,
    heavy_memory_weight: u32,
    build_slots: u32,
    build_heavy_slots: u32,
};

pub const host_reserve_bytes = policyMib(configured_policy.host_reserve_mib);
/// Bytes an ordinary lane claims when its manifest declares it with defaulted
/// evidence. Nothing else falls to it.
pub const default_memory_bytes = policyMib(configured_policy.default_memory_claim_mib);
/// Bytes claimed wherever evidence is missing, failed, or says the lane is
/// larger: lane-less commands, lanes the manifest does not hold, heavy lanes,
/// and lanes that declare the above-default claim.
pub const fallback_memory_bytes = policyMib(configured_policy.fallback_memory_claim_mib);
pub const toolchain_memory_bytes = policyMib(configured_policy.toolchain_memory_claim_mib);
pub const tree_overhead_reserve_bytes =
    policyMib(configured_policy.tree_overhead_reserve_mib);
pub const test_step_memory_bytes =
    policyMib(configured_policy.test_step_memory_claim_mib);
/// Bytes one otherwise unclaimed compile step reserves in a Maker budget. The
/// policy value is a sampled peak with margin, not a proven bound: the tools
/// aggregate sampled 1312460 KiB for a ReleaseFast tool compile.
pub const compile_step_memory_bytes =
    policyMib(configured_policy.compile_step_memory_claim_mib);

/// Returns the bytes a lane may hand to concurrent steps, keeping the overhead
/// reserve for the build runner, Maker, and the governor that share the tree.
pub fn treeBudgetBytes(tree_bytes: u64) u64 {
    std.debug.assert(tree_bytes > 0);
    const budget = tree_bytes -| tree_overhead_reserve_bytes;
    std.debug.assert(budget < tree_bytes);
    return @max(1, budget);
}

pub fn reservableBytes(effective_memory_bytes: u64) u64 {
    return effective_memory_bytes -| host_reserve_bytes;
}

pub fn admission(capacity: Capacity) Admission {
    const cpu_tokens: u32 = @intCast(@min(capacity.cpu_count, max_cpu_tokens));
    const cpu_weight = @min(build_cpu_claim, cpu_tokens);
    return .{
        .cpu_tokens = cpu_tokens,
        .memory_tokens = ordinary.max_slots,
        .ordinary_cpu_weight = cpu_weight,
        .heavy_cpu_weight = cpu_weight,
        .heavy_memory_weight = 1,
        .build_slots = @min(ordinary.max_slots, cpu_tokens),
        .build_heavy_slots = @min(heavy.max_slots, cpu_tokens),
    };
}

pub fn host(
    environment: *const std.process.Environ.Map,
    fallback_memory: u64,
) !Capacity {
    const host_cpu = std.Thread.getCpuCount() catch 1;
    const host_memory = std.process.totalSystemMemory() catch fallback_memory;
    return selectEffective(
        environment,
        try select(environment, Capacity.init(host_cpu, host_memory)),
    );
}

pub fn detect(
    host_cpu: usize,
    host_memory: u64,
    cgroups: ?[]const u8,
) Capacity {
    var result = Capacity.init(host_cpu, host_memory);
    if (comptime builtin.os.tag != .linux) return result;

    const membership = cgroups orelse {
        applyV2(&result, "/sys/fs/cgroup", "");
        applyV2(&result, "/sys/fs/cgroup/unified", "");
        finalize(&result, host_cpu, host_memory);
        return result;
    };
    if (membership.len > max_cgroup_bytes) return result;
    var lines = std.mem.splitScalar(u8, membership, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const hierarchy = fields.next() orelse continue;
        const controllers = fields.next() orelse continue;
        const group = fields.next() orelse continue;
        if (std.mem.eql(u8, hierarchy, "0") and controllers.len == 0) {
            applyV2(&result, "/sys/fs/cgroup", group);
            applyV2(&result, "/sys/fs/cgroup/unified", group);
            continue;
        }
        if (controllerListed(controllers, "memory")) {
            applyMemoryV1(&result, "/sys/fs/cgroup/memory", group);
        }
        if (controllerListed(controllers, "cpu")) {
            applyCpuV1(&result, "/sys/fs/cgroup/cpu", group);
            applyCpuV1(&result, "/sys/fs/cgroup/cpu,cpuacct", group);
            applyCpuV1(&result, "/sys/fs/cgroup/cpuacct,cpu", group);
        }
        if (controllerListed(controllers, "cpuset")) {
            applyCpuset(
                &result,
                "/sys/fs/cgroup/cpuset",
                group,
                "cpuset.cpus",
            );
        }
    }
    finalize(&result, host_cpu, host_memory);
    return result;
}

pub fn select(
    environment: *const std.process.Environ.Map,
    detected: Capacity,
) !Capacity {
    var result = detected;
    if (environment.get(cpu_environment)) |value| {
        result.cpu_count = try positive(usize, value);
        result.cpu_limited = false;
    }
    if (environment.get(memory_environment)) |value| {
        const memory_mib = try positive(u64, value);
        result.memory_bytes = std.math.mul(u64, memory_mib, mebibyte) catch
            return error.MemoryOverrideOverflow;
        result.memory_limited = false;
    }
    return result;
}

fn selectEffective(
    environment: *const std.process.Environ.Map,
    detected: Capacity,
) !Capacity {
    var result = detected;
    if (environment.get(effective_cpu_environment)) |value| {
        result.cpu_count = try positive(usize, value);
    }
    if (environment.get(effective_memory_environment)) |value| {
        const memory_mib = try positive(u64, value);
        result.memory_bytes = std.math.mul(u64, memory_mib, mebibyte) catch
            return error.MemoryOverrideOverflow;
    }
    if (environment.get(effective_tree_environment)) |value| {
        const tree_mib = try positive(u64, value);
        result.tree_bytes = std.math.mul(u64, tree_mib, mebibyte) catch
            return error.MemoryOverrideOverflow;
    }
    return result;
}

fn positive(comptime T: type, value: []const u8) !T {
    const parsed = std.fmt.parseUnsigned(T, value, 10) catch
        return error.InvalidPositiveInteger;
    return if (parsed == 0) error.InvalidPositiveInteger else parsed;
}

fn finalize(result: *Capacity, host_cpu: usize, host_memory: u64) void {
    result.cpu_limited = result.cpu_count < @max(1, host_cpu);
    result.memory_limited = result.memory_bytes < @max(1, host_memory);
}

fn applyV2(result: *Capacity, base: []const u8, group: []const u8) void {
    applyMemory(result, base, group, "memory.max");
    applyCpuV2(result, base, group);
    applyCpuset(result, base, group, "cpuset.cpus.effective");
}

fn applyMemoryV1(result: *Capacity, base: []const u8, group: []const u8) void {
    applyMemory(result, base, group, "memory.limit_in_bytes");
}

fn applyMemory(
    result: *Capacity,
    base: []const u8,
    group: []const u8,
    file_name: []const u8,
) void {
    var current = std.mem.trim(u8, group, "/");
    while (true) {
        var path_buffer: [max_path_bytes]u8 = undefined;
        const file_path = hierarchyPath(
            &path_buffer,
            base,
            current,
            file_name,
        ) orelse return;
        var value_buffer: [max_value_bytes]u8 = undefined;
        if (readAbsolute(file_path, &value_buffer)) |value| {
            if (parseMemoryLimit(value)) |limit| {
                result.memory_bytes = @min(result.memory_bytes, limit);
            }
        }
        current = parent(current) orelse break;
    }
}

fn applyCpuV2(result: *Capacity, base: []const u8, group: []const u8) void {
    var current = std.mem.trim(u8, group, "/");
    while (true) {
        var path_buffer: [max_path_bytes]u8 = undefined;
        const file_path = hierarchyPath(
            &path_buffer,
            base,
            current,
            "cpu.max",
        ) orelse return;
        var value_buffer: [max_value_bytes]u8 = undefined;
        if (readAbsolute(file_path, &value_buffer)) |value| {
            if (parseCpuMax(value)) |limit| {
                result.cpu_count = @min(result.cpu_count, limit);
            }
        }
        current = parent(current) orelse break;
    }
}

fn applyCpuV1(result: *Capacity, base: []const u8, group: []const u8) void {
    var current = std.mem.trim(u8, group, "/");
    while (true) {
        var quota_path_buffer: [max_path_bytes]u8 = undefined;
        const quota_path = hierarchyPath(
            &quota_path_buffer,
            base,
            current,
            "cpu.cfs_quota_us",
        ) orelse return;
        var quota_buffer: [max_value_bytes]u8 = undefined;
        const quota_text = readAbsolute(quota_path, &quota_buffer);

        var period_path_buffer: [max_path_bytes]u8 = undefined;
        const period_path = hierarchyPath(
            &period_path_buffer,
            base,
            current,
            "cpu.cfs_period_us",
        ) orelse return;
        var period_buffer: [max_value_bytes]u8 = undefined;
        const period_text = readAbsolute(period_path, &period_buffer);
        if (quota_text != null and period_text != null) {
            if (parseCpuV1(quota_text.?, period_text.?)) |limit| {
                result.cpu_count = @min(result.cpu_count, limit);
            }
        }
        current = parent(current) orelse break;
    }
}

fn applyCpuset(
    result: *Capacity,
    base: []const u8,
    group: []const u8,
    file_name: []const u8,
) void {
    var current = std.mem.trim(u8, group, "/");
    while (true) {
        var path_buffer: [max_path_bytes]u8 = undefined;
        const file_path = hierarchyPath(
            &path_buffer,
            base,
            current,
            file_name,
        ) orelse return;
        var value_buffer: [max_value_bytes]u8 = undefined;
        if (readAbsolute(file_path, &value_buffer)) |value| {
            if (parseCpuSet(value)) |limit| {
                result.cpu_count = @min(result.cpu_count, limit);
                return;
            }
        }
        current = parent(current) orelse break;
    }
}

fn hierarchyPath(
    buffer: []u8,
    base: []const u8,
    group: []const u8,
    file_name: []const u8,
) ?[]const u8 {
    return if (group.len == 0)
        std.fmt.bufPrint(buffer, "{s}/{s}", .{ base, file_name }) catch null
    else
        std.fmt.bufPrint(
            buffer,
            "{s}/{s}/{s}",
            .{ base, group, file_name },
        ) catch null;
}

fn parent(group: []const u8) ?[]const u8 {
    if (group.len == 0) return null;
    const separator = std.mem.lastIndexOfScalar(u8, group, '/') orelse
        return "";
    return group[0..separator];
}

fn readAbsolute(file_path: []const u8, buffer: []u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(fs_io, file_path, .{}) catch
        return null;
    defer file.close(fs_io);
    const count = file.readPositionalAll(fs_io, buffer, 0) catch return null;
    if (count == buffer.len) return null;
    return std.mem.trim(u8, buffer[0..count], " \t\r\n");
}

fn controllerListed(controllers: []const u8, expected: []const u8) bool {
    var values = std.mem.splitScalar(u8, controllers, ',');
    while (values.next()) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

pub fn parseMemoryLimit(text: []const u8) ?u64 {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0 or std.mem.eql(u8, value, "max")) return null;
    const parsed = std.fmt.parseUnsigned(u64, value, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

pub fn parseCpuMax(text: []const u8) ?usize {
    var values = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const quota = values.next() orelse return null;
    const period = values.next() orelse return null;
    if (values.next() != null or std.mem.eql(u8, quota, "max")) return null;
    const quota_value = std.fmt.parseUnsigned(u64, quota, 10) catch return null;
    const period_value = std.fmt.parseUnsigned(u64, period, 10) catch return null;
    return cpuRatio(quota_value, period_value);
}

pub fn parseCpuV1(quota: []const u8, period: []const u8) ?usize {
    const quota_value = std.fmt.parseInt(i64, quota, 10) catch return null;
    if (quota_value <= 0) return null;
    const period_value = std.fmt.parseUnsigned(u64, period, 10) catch return null;
    return cpuRatio(@intCast(quota_value), period_value);
}

fn cpuRatio(quota: u64, period: u64) ?usize {
    if (quota == 0 or period == 0) return null;
    const count = @max(1, quota / period);
    return @intCast(@min(count, std.math.maxInt(usize)));
}

pub fn parseCpuSet(text: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    var count: usize = 0;
    var ranges = std.mem.splitScalar(u8, trimmed, ',');
    while (ranges.next()) |range| {
        const item = std.mem.trim(u8, range, " \t");
        if (item.len == 0) return null;
        const separator = std.mem.indexOfScalar(u8, item, '-');
        const first_text = if (separator) |index| item[0..index] else item;
        const first = std.fmt.parseUnsigned(usize, first_text, 10) catch
            return null;
        const last = if (separator) |index|
            std.fmt.parseUnsigned(usize, item[index + 1 ..], 10) catch
                return null
        else
            first;
        if (last < first) return null;
        count = std.math.add(usize, count, last - first + 1) catch return null;
    }
    return if (count == 0) null else count;
}

test "memory reservation class bounds do not invent available bytes" {
    const small = Capacity.init(16, host_reserve_bytes);
    try std.testing.expectEqual(@as(u64, 0), reservableBytes(small.memory_bytes));
    try std.testing.expectEqual(@as(u32, 12), ordinary.slots(small, 12));
    try std.testing.expectEqual(@as(u32, 8), heavy.slots(small, 8));
    try std.testing.expectEqual(@as(u64, 1), reservableBytes(host_reserve_bytes + 1));
}

test "capacity policy parser rejects missing duplicate unknown and invalid settings" {
    const testing = std.testing;
    const parsed = try parsePolicy(capacity_policy);
    try testing.expectEqual(@as(u64, 4096), parsed.host_reserve_mib);
    try testing.expectEqual(@as(u64, 3584), parsed.default_memory_claim_mib);
    try testing.expectEqual(@as(u64, 5120), parsed.fallback_memory_claim_mib);
    try testing.expectEqual(default_memory_bytes, ordinary.process_memory_claim);
    try testing.expectEqual(fallback_memory_bytes, heavy.process_memory_claim);
    try testing.expectEqual(@as(u64, 6144), parsed.toolchain_memory_claim_mib);
    try testing.expectEqual(@as(u64, 256), parsed.tree_overhead_reserve_mib);
    try testing.expectEqual(@as(u64, 4096), parsed.test_step_memory_claim_mib);
    try testing.expectEqual(@as(u64, 1536), parsed.compile_step_memory_claim_mib);
    try testing.expectEqual(@as(u64, 2), parsed.build_cpu_claim);
    try testing.expectError(error.MissingEquals, parsePolicy("build_cpu_claim"));
    try testing.expectError(
        error.DuplicateSetting,
        parsePolicy("build_cpu_claim=4\nbuild_cpu_claim=4\n"),
    );
    try testing.expectError(
        error.UnknownSetting,
        parsePolicy("unknown=4\n"),
    );
    try testing.expectError(
        error.InvalidValue,
        parsePolicy("build_cpu_claim=0\n"),
    );
    try testing.expectError(
        error.InvalidValue,
        parsePolicy("build_cpu_claim=x\n"),
    );
    try testing.expectError(
        error.MissingSetting,
        parsePolicy("build_cpu_claim=4\n"),
    );
}

test "build admission derives slots for known local and remote hosts" {
    const testing = std.testing;
    const local = admission(Capacity.init(16, 31_228 * 1024 * 1024));
    try testing.expectEqual(@as(u32, 16), local.cpu_tokens);
    try testing.expectEqual(@as(u32, 12), local.memory_tokens);
    try testing.expectEqual(@as(u32, 2), local.ordinary_cpu_weight);
    try testing.expectEqual(@as(u32, 2), local.heavy_cpu_weight);
    try testing.expectEqual(@as(u32, 12), local.build_slots);
    try testing.expectEqual(@as(u32, 8), local.build_heavy_slots);

    const remote = admission(Capacity.init(16, 64_296 * 1024 * 1024));
    try testing.expectEqual(@as(u32, 12), remote.memory_tokens);
    try testing.expectEqual(@as(u32, 12), remote.build_slots);
    try testing.expectEqual(@as(u32, 8), remote.build_heavy_slots);

    const small = admission(Capacity.init(1, 8 * gibibyte));
    try testing.expectEqual(@as(u32, 1), small.ordinary_cpu_weight);
    try testing.expectEqual(@as(u32, 1), small.build_slots);
    try testing.expectEqual(@as(u32, 1), small.build_heavy_slots);
}

test "cgroup limits parse bounded memory cpu quota and cpuset" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u64, null), parseMemoryLimit("max\n"));
    try testing.expectEqual(
        @as(?u64, 1_073_741_824),
        parseMemoryLimit("1073741824"),
    );
    try testing.expectEqual(@as(?usize, null), parseCpuMax("max 100000"));
    try testing.expectEqual(@as(?usize, 2), parseCpuMax("250000 100000"));
    try testing.expectEqual(@as(?usize, 1), parseCpuMax("50000 100000"));
    try testing.expectEqual(@as(?usize, null), parseCpuV1("-1", "100000"));
    try testing.expectEqual(@as(?usize, 3), parseCpuV1("300000", "100000"));
    try testing.expectEqual(@as(?usize, 8), parseCpuSet("0-3,8,10-12"));
    try testing.expectEqual(@as(?usize, null), parseCpuSet("3-1"));
}

test "capacity selection separates user overrides from effective handoff" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put(cpu_environment, "8");
    try environment.put(memory_environment, "16384");
    var selected = try select(&environment, .{
        .cpu_count = 4,
        .memory_bytes = 8 * gibibyte,
        .cpu_limited = true,
        .memory_limited = true,
    });
    try std.testing.expectEqual(@as(usize, 8), selected.cpu_count);
    try std.testing.expectEqual(@as(u64, 16 * gibibyte), selected.memory_bytes);
    try std.testing.expect(!selected.cpu_limited);
    try std.testing.expect(!selected.memory_limited);
    try environment.put(effective_cpu_environment, "6");
    try environment.put(effective_memory_environment, "12288");
    selected = try selectEffective(&environment, selected);
    try std.testing.expectEqual(@as(usize, 6), selected.cpu_count);
    try std.testing.expectEqual(@as(u64, 12 * gibibyte), selected.memory_bytes);
    try std.testing.expectEqual(@as(?u64, null), selected.tree_bytes);
    try environment.put(effective_tree_environment, "5120");
    selected = try selectEffective(&environment, selected);
    try std.testing.expectEqual(@as(?u64, 5120 * mebibyte), selected.tree_bytes);
}

test "lane tree budget keeps the declared overhead reserve for the shared tree" {
    const lane = 5120 * mebibyte;
    try std.testing.expectEqual(@as(u64, 256 * mebibyte), tree_overhead_reserve_bytes);
    try std.testing.expectEqual(lane - 256 * mebibyte, treeBudgetBytes(lane));
    try std.testing.expectEqual(@as(u64, 1), treeBudgetBytes(tree_overhead_reserve_bytes));
    try std.testing.expectEqual(@as(u64, 1), treeBudgetBytes(1));
    try std.testing.expectEqual(@as(u64, 4096 * mebibyte), test_step_memory_bytes);
}
