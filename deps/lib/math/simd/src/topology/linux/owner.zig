const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");
const topology = @import("../root.zig");
const parse = @import("../parse/root.zig");

const sysfs_buffer_bytes: usize = 200;
const max_cache_indices: usize = 64;

const package_path = "/sys/devices/system/cpu/cpu{d}/topology/physical_package_id";
const cluster_path = "/sys/devices/system/cpu/cpu{d}/cache/index3/id";
const core_path = "/sys/devices/system/cpu/cpu{d}/topology/core_id";
const l2_path = "/sys/devices/system/cpu/cpu{d}/cache/index2/size";
const l3_path = "/sys/devices/system/cpu/cpu{d}/cache/index3/size";
const node_path = "/sys/devices/system/node/node{d}/cpulist";
const cache_path = "/sys/devices/system/cpu/cpu0/cache/index{d}/{s}";
const cpu_list_options: parse.CpuListOptions = .{
    .clamp = switch (builtin.target.cpu.arch) {
        .riscv32, .riscv32be, .riscv64, .riscv64be => true,
        else => false,
    },
};

const CpuSetAdder = struct {
    set: *sys.thread.CpuSet,

    pub fn call(self: *@This(), lp: usize) void {
        const word = lp / @bitSizeOf(usize);
        const bit: std.math.Log2Int(usize) =
            @intCast(lp % @bitSizeOf(usize));
        self.set[word] |= @as(usize, 1) << bit;
    }
};

const NodeAssigner = struct {
    records: []topology.ProcessorRecord,
    node: u8,

    pub fn call(self: *@This(), lp: usize) void {
        self.records[lp].node = self.node;
    }
};

pub fn totalLogicalProcessors() usize {
    var buffer: [sysfs_buffer_bytes]u8 = undefined;
    const text = readPath("/sys/devices/system/cpu/online", &buffer) orelse
        return fallbackTotal();
    var set = topology.LogicalProcessorSet{};
    if (!parse.cpuList(
        text,
        topology.max_logical_processors - 1,
        cpu_list_options,
        &set,
    )) {
        return fallbackTotal();
    }
    return @max(1, set.count());
}

pub fn fillRecords(
    records: *[topology.max_logical_processors]topology.ProcessorRecord,
) usize {
    const count = totalLogicalProcessors();
    for (records[0..count], 0..) |*record, lp| {
        const package = readNumber(package_path, lp) orelse return 0;
        const core = readNumber(core_path, lp) orelse return 0;
        const cluster = readNumber(cluster_path, lp) orelse 0;
        record.* = .{
            .package_id = package,
            .cluster_id = cluster,
            .core_id = core,
        };
    }
    setNodes(records[0..count]);
    return count;
}

pub fn fillClusterCacheSizes(detected: *topology.Topology) void {
    for (detected.packages) |package| {
        for (package.clusters) |*const_cluster| {
            const cluster = @constCast(const_cluster);
            if (!cluster.lps.any()) continue;
            const lp = cluster.lps.first();
            if (readNumber(l2_path, lp)) |bytes| cluster.private_kib = bytes >> 10;
            if (readNumber(l3_path, lp)) |bytes| cluster.shared_kib = bytes >> 10;
        }
    }
}

pub fn getThreadAffinity(out: *topology.LogicalProcessorSet) bool {
    const set = sys.thread.currentAffinity() catch return false;
    out.* = .{};
    for (set, 0..) |word, word_index| {
        var remaining = word;
        while (remaining != 0) {
            const bit: usize = @ctz(remaining);
            const lp = word_index * @bitSizeOf(usize) + bit;
            if (lp < topology.max_logical_processors) out.set(lp);
            remaining &= remaining - 1;
        }
    }
    return true;
}

pub fn setThreadAffinity(lps: *const topology.LogicalProcessorSet) bool {
    var set: sys.thread.CpuSet = @splat(0);
    var add = CpuSetAdder{ .set = &set };
    lps.foreach(&add);
    sys.thread.setCurrentAffinity(&set) catch return false;
    return true;
}

pub fn dataCaches() ?[4]topology.Cache {
    var records: [topology.max_logical_processors]topology.ProcessorRecord = undefined;
    const record_count = fillRecords(&records);
    if (record_count == 0) return null;
    var caches: [4]topology.Cache = @splat(.{});
    var index: usize = 0;
    while (index < max_cache_indices) : (index += 1) {
        var type_buffer: [sysfs_buffer_bytes]u8 = undefined;
        const type_text = readCache(index, "type", &type_buffer) orelse break;
        if (!std.mem.eql(u8, type_text, "Data") and
            !std.mem.eql(u8, type_text, "Unified")) continue;
        var level_buffer: [sysfs_buffer_bytes]u8 = undefined;
        const level = parse.unsignedPrefix(
            readCache(index, "level", &level_buffer) orelse continue,
        ) orelse continue;
        if (level < 1 or level > 3 or caches[level].size_kib != 0) continue;

        var size_buffer: [sysfs_buffer_bytes]u8 = undefined;
        var ways_buffer: [sysfs_buffer_bytes]u8 = undefined;
        var sets_buffer: [sysfs_buffer_bytes]u8 = undefined;
        const size_kib = parse.unsignedPrefix(
            readCache(index, "size", &size_buffer) orelse continue,
        ) orelse continue;
        const associativity = parse.unsignedPrefix(
            readCache(index, "ways_of_associativity", &ways_buffer) orelse continue,
        ) orelse continue;
        const sets = parse.unsignedPrefix(
            readCache(index, "number_of_sets", &sets_buffer) orelse continue,
        ) orelse continue;
        if (size_kib > std.math.maxInt(u32) or
            associativity == 0 or associativity > std.math.maxInt(u16) or
            sets == 0 or sets > std.math.maxInt(u32)) continue;
        const lines = std.math.mul(usize, associativity, sets) catch continue;
        const bytes = std.math.mul(usize, size_kib, 1024) catch continue;
        if (bytes % lines != 0 or bytes / lines > std.math.maxInt(u16)) continue;

        var shared_buffer: [sysfs_buffer_bytes]u8 = undefined;
        const shared_text = readCache(index, "shared_cpu_list", &shared_buffer);
        const cores_sharing = if (shared_text) |text|
            countSharedCores(text, records[0..record_count])
        else
            1;
        const sharing = @max(1, cores_sharing);
        if (sharing > std.math.maxInt(u16)) continue;
        caches[level] = .{
            .size_kib = @intCast(size_kib / sharing),
            .sets = @intCast(sets / sharing),
            .bytes_per_line = @intCast(bytes / lines),
            .associativity = @intCast(associativity),
            .cores_sharing = @intCast(sharing),
        };
    }
    if (caches[1].size_kib == 0 or caches[2].size_kib == 0) return null;
    for (caches[1..4]) |*cache| if (!topology.computeCacheSets(cache)) return null;
    if (caches[3].cores_sharing >= 16 and caches[3].size_kib <= 512) {
        caches[3] = .{};
    }
    return caches;
}

fn fallbackTotal() usize {
    const count = std.Thread.getCpuCount() catch 1;
    return std.math.clamp(count, 1, topology.max_logical_processors);
}

fn setNodes(records: []topology.ProcessorRecord) void {
    var node: usize = 0;
    while (node <= std.math.maxInt(u8)) : (node += 1) {
        var buffer: [sysfs_buffer_bytes]u8 = undefined;
        const text = readFormatted(node_path, node, &buffer) orelse break;
        var set = topology.LogicalProcessorSet{};
        if (!parse.cpuList(
            text,
            records.len - 1,
            cpu_list_options,
            &set,
        )) continue;
        var assign = NodeAssigner{
            .records = records,
            .node = @intCast(node),
        };
        set.foreach(&assign);
    }
}

fn countSharedCores(
    text: []const u8,
    records: []const topology.ProcessorRecord,
) usize {
    var set = topology.LogicalProcessorSet{};
    if (!parse.cpuList(
        text,
        records.len - 1,
        cpu_list_options,
        &set,
    )) return 1;
    var count: usize = 0;
    for (records, 0..) |record, lp| {
        if (!set.get(lp)) continue;
        var seen = false;
        for (records[0..lp], 0..) |prior, prior_lp| {
            if (set.get(prior_lp) and prior.package_id == record.package_id and
                prior.core_id == record.core_id)
            {
                seen = true;
                break;
            }
        }
        count += @intFromBool(!seen);
    }
    return @max(1, count);
}

fn readNumber(comptime format: []const u8, index: usize) ?usize {
    var buffer: [sysfs_buffer_bytes]u8 = undefined;
    const text = readFormatted(format, index, &buffer) orelse return null;
    return parse.numberWithOptionalSuffix(text);
}

fn readCache(index: usize, name: []const u8, buffer: *[sysfs_buffer_bytes]u8) ?[]const u8 {
    var path_buffer: [sysfs_buffer_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, cache_path, .{ index, name }, 0) catch return null;
    return readPath(path, buffer);
}

fn readFormatted(
    comptime format: []const u8,
    index: usize,
    buffer: *[sysfs_buffer_bytes]u8,
) ?[]const u8 {
    var path_buffer: [sysfs_buffer_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, format, .{index}, 0) catch return null;
    return readPath(path, buffer);
}

fn readPath(path: [:0]const u8, buffer: *[sysfs_buffer_bytes]u8) ?[]const u8 {
    const descriptor = sys.fd.openAtZ(
        sys.fd.cwd_descriptor,
        path,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    ) catch return null;
    defer sys.fd.close(descriptor);
    var used: usize = 0;
    while (used < buffer.len - 1) {
        const read = sys.fd.read(descriptor, buffer[used .. buffer.len - 1]) catch return null;
        if (read == 0) break;
        used += read;
    }
    if (used == buffer.len - 1) return null;
    buffer[used] = 0;
    while (used != 0 and (buffer[used - 1] == '\n' or buffer[used - 1] == 0)) used -= 1;
    return buffer[0..used];
}
