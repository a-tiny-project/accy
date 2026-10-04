const std = @import("std");
const sys = @import("sys");
const topology = @import("../root.zig");

pub fn totalLogicalProcessors() usize {
    const count = sysctlNumber("hw.perflevel0.logicalcpu", 1) orelse
        (std.Thread.getCpuCount() catch 1);
    return std.math.clamp(count, 1, topology.max_logical_processors);
}

pub fn fillRecords(
    records: *[topology.max_logical_processors]topology.ProcessorRecord,
) usize {
    const count = totalLogicalProcessors();
    var total_cores = sysctlNumber("hw.perflevel0.physicalcpu", 1) orelse count;
    if (total_cores == 0) total_cores = count;
    const lps_per_core = std.math.divCeil(usize, count, total_cores) catch return 0;
    var cores_per_cluster = sysctlNumber("hw.perflevel0.cpusperl2", 1) orelse
        @min(4, total_cores);
    if (cores_per_cluster == 0) cores_per_cluster = 1;
    const caches = dataCaches();
    for (records[0..count], 0..) |*record, lp| {
        record.* = .{
            .package_id = 0,
            .cluster_id = lp / lps_per_core / cores_per_cluster,
            .core_id = lp / lps_per_core,
            .private_kib = if (caches) |value| value[2].size_kib else 0,
            .shared_kib = if (caches) |value| value[3].size_kib else 0,
        };
    }
    return count;
}

pub fn dataCaches() ?[4]topology.Cache {
    var caches: [4]topology.Cache = @splat(.{});
    const l1_size = sysctlNumber("hw.perflevel0.l1dcachesize", 1024) orelse
        sysctlNumber("hw.l1dcachesize", 1024) orelse return null;
    const l2_size = sysctlNumber("hw.perflevel0.l2cachesize", 1024) orelse
        sysctlNumber("hw.l2cachesize", 1024) orelse return null;
    if (l1_size > std.math.maxInt(u32) or l2_size > std.math.maxInt(u32)) return null;
    caches[1].size_kib = @intCast(l1_size);
    caches[1].cores_sharing = 1;
    var l2_sharing = sysctlNumber("hw.perflevel0.cpusperl2", 1) orelse 1;
    if (l2_sharing == 0 or l2_sharing > std.math.maxInt(u16)) l2_sharing = 1;
    caches[2].size_kib = @intCast(l2_size / l2_sharing);
    caches[2].cores_sharing = @intCast(l2_sharing);

    setKnownAppleGeometry(&caches);
    const line_size = sysctlNumber("hw.cachelinesize", 1) orelse 128;
    if (line_size == 0 or line_size > std.math.maxInt(u16)) return null;
    for (caches[1..4]) |*cache| {
        if (cache.bytes_per_line == 0) cache.bytes_per_line = @intCast(line_size);
    }
    if (caches[1].associativity == 0) {
        caches[1].associativity = @intCast(
            sysctlNumber("machdep.cpu.cache.L1_associativity", 1) orelse 8,
        );
    }
    if (caches[2].associativity == 0) {
        caches[2].associativity = @intCast(
            sysctlNumber("machdep.cpu.cache.L2_associativity", 1) orelse 12,
        );
    }
    caches[3].associativity = 12;

    const l3_size = sysctlNumber("hw.perflevel0.l3cachesize", 1024) orelse
        sysctlNumber("hw.l3cachesize", 1024);
    if (l3_size) |size| {
        var sharing = sysctlNumber("hw.perflevel0.cpusperl3", 1) orelse 1;
        if (sharing == 0 or sharing > std.math.maxInt(u16)) sharing = 1;
        const per_core = size / sharing;
        if (per_core <= std.math.maxInt(u32)) {
            caches[3].size_kib = @intCast(per_core);
            caches[3].cores_sharing = @intCast(sharing);
        }
    }
    if (caches[3].size_kib == 0) caches[3] = .{};
    for (caches[1..4]) |*cache| if (!topology.computeCacheSets(cache)) return null;
    if (caches[3].cores_sharing >= 16 and caches[3].size_kib <= 512) {
        caches[3] = .{};
    }
    return caches;
}

fn setKnownAppleGeometry(caches: *[4]topology.Cache) void {
    var brand: [128]u8 = @splat(0);
    const size = sys.process.systemControl("machdep.cpu.brand_string", &brand) catch return;
    if (size < 8) return;
    if (!std.mem.startsWith(u8, &brand, "Apple M")) return;
    caches[1].bytes_per_line = 64;
    caches[1].associativity = 8;
    caches[2].bytes_per_line = 128;
    caches[2].associativity = switch (brand[7]) {
        '1' => 12,
        '2', '3', '4' => 16,
        else => 0,
    };
}

fn sysctlNumber(comptime name: [:0]const u8, divisor: usize) ?usize {
    std.debug.assert(divisor != 0);
    var value: usize = 0;
    const size = sys.process.systemControl(name, &value) catch return null;
    if (size != @sizeOf(usize) or value % divisor != 0) return null;
    return value / divisor;
}
