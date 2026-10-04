const std = @import("std");
const builtin = @import("builtin");

const fs_io = std.Options.debug_io;
const gibibyte: u64 = 1024 * 1024 * 1024;
const max_cgroup_bytes = 16 * 1024;
const max_path_bytes = 4096;
const max_value_bytes = 256;
const online_cpus_path = "/sys/devices/system/cpu/online";
const capacity_policy = @embedFile("capacity.policy");
const max_capacity_policy_bytes = 1024;
const workload_declarations = @embedFile("capacity.workloads");
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

/// The compile-time maxima that size admission state. A host capacity record
/// chooses the operating values under them, and a governor checks every
/// record against them before it admits with one.
pub const Limits = struct {
    /// Most ordinary slots, and so most memory tokens, a record may declare.
    ordinary_max_slots: u32,
    /// Most heavy slots a record may declare.
    heavy_max_slots: u32,
    /// Most CPU tokens a record may declare.
    max_cpu_tokens: u32,
    /// Most resource descriptors one lease holds or inherits.
    max_resource_fds: u32,
};

/// The limits `capacity.policy` holds. It holds nothing else.
pub const limits: Limits = parsed: {
    if (capacity_policy.len >= max_capacity_policy_bytes) {
        @compileError("capacity policy exceeds its byte bound");
    }
    const value = parseLimits(capacity_policy) catch |err|
        @compileError("invalid capacity policy: " ++ @errorName(err));
    if (upgradedLeaseDescriptors(value.max_cpu_tokens) > value.max_resource_fds) {
        @compileError("an upgraded lease at the CPU token limit exceeds the descriptor limit");
    }
    break :parsed value;
};
pub const max_resource_fds: u32 = limits.max_resource_fds;

/// Counts the descriptors an upgraded lease holds: its ordinary and heavy slot
/// tokens, one memory token, and one CPU token per unit of CPU weight. A valid
/// record's CPU weight never exceeds its CPU tokens, so the limit relationship
/// bounds every lease any valid record admits.
fn upgradedLeaseDescriptors(cpu_weight: u32) u32 {
    return 2 + cpu_weight + 1;
}

// Workload declarations. They size claims and reserves for kinds of work and
// change with the measurements behind them. The host capacity record holds
// the machine's operating point, so tuning it never needs a rebuild.

/// The evidence a defaulted claim cites: the file that declares the default
/// claims below.
pub const default_evidence_ref = "build/api/src/capacity.workloads";
/// Bytes the admission budget leaves to the host outside every lane. The
/// record's memory is the budget's tunable side.
pub const host_reserve_bytes: u64 = workloads.host_reserve_mib * mebibyte;
/// Bytes an ordinary lane claims when its manifest declares it with defaulted
/// evidence. Nothing else falls to it.
pub const default_memory_bytes: u64 = workloads.default_memory_claim_mib * mebibyte;
/// Bytes claimed wherever evidence is missing, failed, or says the lane is
/// larger: lane-less commands, lanes the manifest does not hold, heavy lanes,
/// and lanes that declare the above-default claim.
pub const fallback_memory_bytes: u64 = workloads.fallback_memory_claim_mib * mebibyte;
pub const toolchain_memory_bytes: u64 = workloads.toolchain_memory_claim_mib * mebibyte;
pub const tree_overhead_reserve_bytes: u64 = workloads.tree_overhead_reserve_mib * mebibyte;
pub const test_step_memory_bytes: u64 = workloads.test_step_memory_claim_mib * mebibyte;
/// Bytes one otherwise unclaimed compile step reserves in a Maker budget. The
/// value is a sampled peak with margin, not a proven bound: the tools
/// aggregate sampled 1312460 KiB for a ReleaseFast tool compile.
pub const compile_step_memory_bytes: u64 = workloads.compile_step_memory_claim_mib * mebibyte;
/// CPU jobs one lane claims unless its manifest declares otherwise.
const build_cpu_claim: u32 = workloads.build_cpu_claim;

comptime {
    if (compile_step_memory_bytes > test_step_memory_bytes) {
        @compileError("the compile step claim exceeds the test step claim");
    }
    if (default_memory_bytes > fallback_memory_bytes) {
        @compileError("the default claim exceeds the fallback claim");
    }
    if (build_cpu_claim > limits.max_cpu_tokens) {
        @compileError("the build CPU claim exceeds the CPU token limit");
    }
}

const Workloads = struct {
    host_reserve_mib: u32,
    default_memory_claim_mib: u32,
    fallback_memory_claim_mib: u32,
    toolchain_memory_claim_mib: u32,
    tree_overhead_reserve_mib: u32,
    test_step_memory_claim_mib: u32,
    compile_step_memory_claim_mib: u32,
    build_cpu_claim: u32,
};

const workloads = parseWorkloads(workload_declarations) catch |err|
    @compileError("invalid workload declarations: " ++ @errorName(err));

fn parseWorkloads(text: []const u8) !Workloads {
    @setEvalBranchQuota(10_000);
    if (text.len >= max_capacity_policy_bytes) return error.CapacityExceeded;
    var result = std.mem.zeroes(Workloads);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.MissingEquals;
        const name = line[0..separator];
        var found = false;
        inline for (comptime std.meta.fieldNames(Workloads)) |field| {
            if (std.mem.eql(u8, name, field)) {
                if (@field(result, field) != 0) return error.DuplicateSetting;
                @field(result, field) = try positive(u32, line[separator + 1 ..]);
                found = true;
            }
        }
        if (!found) return error.UnknownSetting;
    }
    inline for (comptime std.meta.fieldNames(Workloads)) |field| {
        if (@field(result, field) == 0) return error.MissingSetting;
    }
    return result;
}

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
    /// Holds the operating point sealed in the host capacity record. A
    /// capacity no record settled leaves it absent.
    operating: ?Admission = null,

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
    .memory_reserve = host_reserve_bytes,
    .process_memory_claim = default_memory_bytes,
    .max_slots = limits.ordinary_max_slots,
};

pub const heavy = Policy{
    .memory_reserve = host_reserve_bytes,
    .process_memory_claim = fallback_memory_bytes,
    .max_slots = limits.heavy_max_slots,
};

fn parseLimits(text: []const u8) !Limits {
    @setEvalBranchQuota(10_000);
    var ordinary_max_slots: ?u32 = null;
    var heavy_max_slots: ?u32 = null;
    var max_cpu_tokens: ?u32 = null;
    var resource_fds: ?u32 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.MissingEquals;
        const name = line[0..separator];
        const value = line[separator + 1 ..];
        if (std.mem.eql(u8, name, "ordinary_max_slots"))
            try setLimit(&ordinary_max_slots, value)
        else if (std.mem.eql(u8, name, "heavy_max_slots"))
            try setLimit(&heavy_max_slots, value)
        else if (std.mem.eql(u8, name, "max_cpu_tokens"))
            try setLimit(&max_cpu_tokens, value)
        else if (std.mem.eql(u8, name, "max_resource_fds"))
            try setLimit(&resource_fds, value)
        else
            return error.UnknownSetting;
    }
    return .{
        .ordinary_max_slots = ordinary_max_slots orelse return error.MissingSetting,
        .heavy_max_slots = heavy_max_slots orelse return error.MissingSetting,
        .max_cpu_tokens = max_cpu_tokens orelse return error.MissingSetting,
        .max_resource_fds = resource_fds orelse return error.MissingSetting,
    };
}

fn setLimit(slot: *?u32, text: []const u8) !void {
    if (slot.* != null) return error.DuplicateSetting;
    const value = std.fmt.parseUnsigned(u32, text, 10) catch
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

/// Derives the operating point a new host capacity record starts from. It is
/// the arithmetic admission used before records existed, so a record seeded
/// from the machine admits what the maxima admitted for every process on it.
pub fn seed(capacity: Capacity) Admission {
    std.debug.assert(capacity.cpu_count > 0);
    const cpu_tokens: u32 = @intCast(@min(capacity.cpu_count, limits.max_cpu_tokens));
    const cpu_weight = @min(build_cpu_claim, cpu_tokens);
    return .{
        .cpu_tokens = cpu_tokens,
        .memory_tokens = limits.ordinary_max_slots,
        .ordinary_cpu_weight = cpu_weight,
        .heavy_cpu_weight = cpu_weight,
        .heavy_memory_weight = 1,
        .build_slots = @min(limits.ordinary_max_slots, cpu_tokens),
        .build_heavy_slots = @min(limits.heavy_max_slots, cpu_tokens),
    };
}

/// Returns the operating point admission uses. A capacity sealed from the host
/// capacity record admits the record's values, clamped to the CPUs this
/// process may use. A capacity no record settled admits its seed.
pub fn admission(capacity: Capacity) Admission {
    std.debug.assert(capacity.cpu_count > 0);
    const operating = capacity.operating orelse return seed(capacity);
    std.debug.assert(operating.cpu_tokens > 0);
    const cpu_tokens: u32 = @intCast(@min(operating.cpu_tokens, capacity.cpu_count));
    return .{
        .cpu_tokens = cpu_tokens,
        .memory_tokens = operating.memory_tokens,
        .ordinary_cpu_weight = @min(operating.ordinary_cpu_weight, cpu_tokens),
        .heavy_cpu_weight = @min(operating.heavy_cpu_weight, cpu_tokens),
        .heavy_memory_weight = operating.heavy_memory_weight,
        .build_slots = @min(operating.build_slots, cpu_tokens),
        .build_heavy_slots = @min(operating.build_heavy_slots, cpu_tokens),
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

/// Returns the machine's online CPUs before this process's CPU affinity and
/// cgroups narrow them, so a record seeded from it holds for every process on
/// the machine. Linux reads the kernel's online list. Elsewhere the platform
/// count is already the machine's. The count is never below the platform
/// count, the CPUs this process may run on.
pub fn onlineCpuCount() usize {
    const platform = std.Thread.getCpuCount() catch 1;
    if (comptime builtin.os.tag != .linux) return platform;
    var buffer: [max_value_bytes]u8 = undefined;
    const text = readAbsolute(online_cpus_path, &buffer) orelse return platform;
    const online = parseCpuSet(text) orelse return platform;
    return @max(platform, online);
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

test "capacity policy holds only limits and refuses anything else" {
    const testing = std.testing;
    const parsed = try parseLimits(capacity_policy);
    try testing.expectEqual(Limits{
        .ordinary_max_slots = 12,
        .heavy_max_slots = 8,
        .max_cpu_tokens = 64,
        .max_resource_fds = 89,
    }, parsed);
    try testing.expectEqual(parsed, limits);
    const tuning = [_][]const u8{
        "host_reserve_mib=4096",
        "default_memory_claim_mib=3584",
        "fallback_memory_claim_mib=5120",
        "toolchain_memory_claim_mib=6144",
        "tree_overhead_reserve_mib=256",
        "test_step_memory_claim_mib=4096",
        "compile_step_memory_claim_mib=1536",
        "build_cpu_claim=2",
    };
    for (tuning) |line| {
        try testing.expectError(error.UnknownSetting, parseLimits(line));
    }
    try testing.expectError(error.MissingEquals, parseLimits("max_cpu_tokens"));
    try testing.expectError(
        error.DuplicateSetting,
        parseLimits("max_cpu_tokens=4\nmax_cpu_tokens=4\n"),
    );
    try testing.expectError(error.InvalidValue, parseLimits("max_cpu_tokens=0\n"));
    try testing.expectError(error.InvalidValue, parseLimits("max_cpu_tokens=x\n"));
    try testing.expectError(
        error.InvalidValue,
        parseLimits("max_cpu_tokens=4294967296\n"),
    );
    try testing.expectError(error.MissingSetting, parseLimits("max_cpu_tokens=4\n"));
    try testing.expect(upgradedLeaseDescriptors(limits.max_cpu_tokens) <= max_resource_fds);
}

test "workload declarations keep the claims the policy file used to hold" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 4096 * mebibyte), host_reserve_bytes);
    try testing.expectEqual(@as(u64, 3584 * mebibyte), default_memory_bytes);
    try testing.expectEqual(@as(u64, 5120 * mebibyte), fallback_memory_bytes);
    try testing.expectEqual(@as(u64, 6144 * mebibyte), toolchain_memory_bytes);
    try testing.expectEqual(@as(u64, 256 * mebibyte), tree_overhead_reserve_bytes);
    try testing.expectEqual(@as(u64, 4096 * mebibyte), test_step_memory_bytes);
    try testing.expectEqual(@as(u64, 1536 * mebibyte), compile_step_memory_bytes);
    try testing.expectEqual(@as(u32, 2), buildCpuClaim());
    try testing.expectEqual(default_memory_bytes, ordinary.process_memory_claim);
    try testing.expectEqual(fallback_memory_bytes, heavy.process_memory_claim);
    try testing.expectEqual(host_reserve_bytes, ordinary.memory_reserve);
    try testing.expectEqual(host_reserve_bytes, heavy.memory_reserve);
    try testing.expectEqual(limits.ordinary_max_slots, ordinary.max_slots);
    try testing.expectEqual(limits.heavy_max_slots, heavy.max_slots);
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

test "a sealed capacity admits the record operating point rather than the maxima" {
    const testing = std.testing;
    const operating = Admission{
        .cpu_tokens = 10,
        .memory_tokens = 5,
        .ordinary_cpu_weight = 3,
        .heavy_cpu_weight = 4,
        .heavy_memory_weight = 2,
        .build_slots = 6,
        .build_heavy_slots = 3,
    };
    var sealed = Capacity.init(16, 31_228 * mebibyte);
    sealed.operating = operating;
    try testing.expectEqual(operating, admission(sealed));
    try testing.expect(!std.meta.eql(seed(sealed), admission(sealed)));

    sealed.cpu_count = 4;
    try testing.expectEqual(Admission{
        .cpu_tokens = 4,
        .memory_tokens = 5,
        .ordinary_cpu_weight = 3,
        .heavy_cpu_weight = 4,
        .heavy_memory_weight = 2,
        .build_slots = 4,
        .build_heavy_slots = 3,
    }, admission(sealed));
}

test "a record seeded from the host admits what the maxima admitted for every process on it" {
    const memory_bytes: u64 = 31_228 * mebibyte;
    var host_cpus: usize = 1;
    while (host_cpus <= limits.max_cpu_tokens + 8) : (host_cpus += 1) {
        const machine = Capacity.init(host_cpus, memory_bytes);
        try std.testing.expectEqual(seed(machine), admission(machine));
        // A process narrower than the host, by its cgroups, its affinity or a
        // parent lane's handoff, admits the seed of what it may use.
        var process_cpus: usize = 1;
        while (process_cpus <= host_cpus) : (process_cpus += 1) {
            var sealed = Capacity.init(process_cpus, memory_bytes);
            sealed.operating = seed(machine);
            try std.testing.expectEqual(
                seed(Capacity.init(process_cpus, memory_bytes)),
                admission(sealed),
            );
        }
    }
}

test "the online CPU count covers every CPU this process may run on" {
    const platform = std.Thread.getCpuCount() catch 1;
    const online = onlineCpuCount();
    try std.testing.expect(online >= platform);
    try std.testing.expect(online >= 1);
}

test "workload declarations are complete unique positive values" {
    try std.testing.expectEqual(workloads, try parseWorkloads(workload_declarations));
    try std.testing.expectError(error.MissingSetting, parseWorkloads("host_reserve_mib=4096"));
    try std.testing.expectError(error.DuplicateSetting, parseWorkloads(
        workload_declarations ++ "host_reserve_mib=4096\n",
    ));
    try std.testing.expectError(error.UnknownSetting, parseWorkloads("ordinary_max_slots=12"));
    try std.testing.expectError(error.InvalidPositiveInteger, parseWorkloads("host_reserve_mib=0"));
    const oversized: [max_capacity_policy_bytes]u8 = @splat(' ');
    try std.testing.expectError(error.CapacityExceeded, parseWorkloads(&oversized));
}
