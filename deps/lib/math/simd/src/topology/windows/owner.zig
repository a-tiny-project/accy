const std = @import("std");
const topology = @import("../root.zig");

const windows = std.os.windows;
const all_processor_groups: u16 = 0xffff;
const static_query_bytes: usize = 512 * 1024;
const invalid_id = std.math.maxInt(u64);

const Relationship = enum(u32) {
    processor_core = 0,
    numa_node = 1,
    cache = 2,
    processor_package = 3,
    group = 4,
    processor_die = 5,
    numa_node_ex = 6,
    processor_module = 7,
    all = 0xffff,
    _,
};

const CacheType = enum(u32) {
    unified = 0,
    instruction = 1,
    data = 2,
    trace = 3,
    unknown = 4,
    _,
};

const GroupAffinity = extern struct {
    mask: usize,
    group: u16,
    reserved: [3]u16,
};

const ProcessorRelationship = extern struct {
    flags: u8,
    efficiency_class: u8,
    reserved: [20]u8,
    group_count: u16,
    group_mask: [1]GroupAffinity,
};

const NumaNodeRelationship = extern struct {
    node_number: u32,
    reserved: [18]u8,
    group_count: u16,
    group_masks: [1]GroupAffinity,
};

const CacheRelationship = extern struct {
    level: u8,
    associativity: u8,
    line_size: u16,
    cache_size: u32,
    kind: CacheType,
    reserved: [18]u8,
    group_count: u16,
    group_masks: [1]GroupAffinity,
};

const Entry = extern struct {
    relationship: Relationship,
    size: u32,
};

var static_query: [static_query_bytes]u8 align(8) = @splat(0);
var static_query_guard: std.atomic.Mutex = .unlocked;

extern "kernel32" fn GetLogicalProcessorInformationEx(
    relationship: Relationship,
    buffer: ?*anyopaque,
    returned_length: *u32,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetActiveProcessorCount(
    group_number: u16,
) callconv(.winapi) u32;

extern "kernel32" fn SetThreadAffinityMask(
    thread: windows.HANDLE,
    affinity_mask: usize,
) callconv(.winapi) usize;

pub fn totalLogicalProcessors() usize {
    const count = GetActiveProcessorCount(all_processor_groups);
    if (count == 0) return 1;
    return std.math.clamp(@as(usize, count), 1, topology.max_logical_processors);
}

pub fn fillRecords(
    allocator: std.mem.Allocator,
    records: *[topology.max_logical_processors]topology.ProcessorRecord,
) std.mem.Allocator.Error!usize {
    const count = totalLogicalProcessors();
    for (records[0..count]) |*record| record.* = .{
        .package_id = invalid_id,
        .cluster_id = 0,
        .core_id = invalid_id,
    };
    const all_buffer = (try queryAlloc(allocator, .all)) orelse return 0;
    defer allocator.free(all_buffer);
    var state = RecordState{ .records = records[0..count] };
    if (!walk(all_buffer, &state, RecordState.visitAll)) return 0;

    if (try queryAlloc(allocator, .processor_die)) |die_buffer| {
        defer allocator.free(die_buffer);
        var die_state = DieState{ .records = records[0..count] };
        if (walk(die_buffer, &die_state, DieState.visit) and die_state.count != 0) {
            state.cluster_count = die_state.count;
        }
    }
    if (state.package_count == 0 or state.core_count == 0) return 0;
    for (records[0..count]) |record| {
        if (record.package_id == invalid_id or record.core_id == invalid_id) return 0;
    }
    if (dataCaches()) |caches| {
        for (records[0..count]) |*record| {
            record.private_kib = caches[2].size_kib;
            record.shared_kib = caches[3].size_kib;
        }
    }
    return count;
}

pub fn getThreadAffinity(out: *topology.LogicalProcessorSet) bool {
    const thread = windows.GetCurrentThread();
    const previous = SetThreadAffinityMask(thread, std.math.maxInt(usize));
    if (previous == 0) return false;
    _ = SetThreadAffinityMask(thread, previous);
    out.* = .{};
    out.setNonzeroBitsFrom64(previous);
    return true;
}

pub fn setThreadAffinity(lps: *const topology.LogicalProcessorSet) bool {
    const mask: usize = @truncate(lps.get64());
    if (mask == 0) return false;
    return SetThreadAffinityMask(windows.GetCurrentThread(), mask) != 0;
}

pub fn dataCaches() ?[4]topology.Cache {
    while (!static_query_guard.tryLock()) std.atomic.spinLoopHint();
    defer static_query_guard.unlock();
    const buffer = queryStatic(.all) orelse return null;
    var state = CacheState{};
    if (!walk(buffer, &state, CacheState.visitCore)) return null;
    if (state.max_lps_per_core == 0) return null;
    if (!walk(buffer, &state, CacheState.visitCache)) return null;
    if (state.caches[1].size_kib == 0 or state.caches[2].size_kib == 0) return null;
    for (state.caches[1..4]) |*cache| if (!topology.computeCacheSets(cache)) return null;
    if (state.caches[3].cores_sharing >= 16 and state.caches[3].size_kib <= 512) {
        state.caches[3] = .{};
    }
    return state.caches;
}

const RecordState = struct {
    records: []topology.ProcessorRecord,
    package_count: usize = 0,
    core_count: usize = 0,
    cluster_count: usize = 0,

    fn visitAll(self: *@This(), entry: *const Entry) void {
        switch (entry.relationship) {
            .processor_package => {
                const processor = processorPayload(entry);
                assignId(
                    self.records,
                    groupMasks(processor),
                    self.package_count,
                    .package,
                );
                self.package_count += 1;
            },
            .processor_core => {
                const processor = processorPayload(entry);
                assignId(
                    self.records,
                    groupMasks(processor),
                    self.core_count,
                    .core,
                );
                self.core_count += 1;
            },
            .cache => {
                const cache = cachePayload(entry);
                if (cache.level != 3 or
                    (cache.kind != .unified and cache.kind != .data)) return;
                assignId(
                    self.records,
                    cacheGroupMasks(cache),
                    self.cluster_count,
                    .cluster,
                );
                self.cluster_count += 1;
            },
            .numa_node => {
                const numa = numaPayload(entry);
                assignNode(
                    self.records,
                    numaGroupMasks(numa),
                    @truncate(numa.node_number),
                );
            },
            else => {},
        }
    }
};

const DieState = struct {
    records: []topology.ProcessorRecord,
    count: usize = 0,

    fn visit(self: *@This(), entry: *const Entry) void {
        if (entry.relationship != .processor_die) return;
        const processor = processorPayload(entry);
        assignId(self.records, groupMasks(processor), self.count, .cluster);
        self.count += 1;
    }
};

const CacheState = struct {
    caches: [4]topology.Cache = @splat(.{}),
    max_lps_per_core: usize = 0,

    fn visitCore(self: *@This(), entry: *const Entry) void {
        if (entry.relationship != .processor_core) return;
        const processor = processorPayload(entry);
        self.max_lps_per_core = @max(
            self.max_lps_per_core,
            countGroupBits(groupMasks(processor)),
        );
    }

    fn visitCache(self: *@This(), entry: *const Entry) void {
        if (entry.relationship != .cache) return;
        const source = cachePayload(entry);
        if ((source.kind != .unified and source.kind != .data) or
            source.level < 1 or source.level > 3) return;
        const cache = &self.caches[source.level];
        if (cache.size_kib != 0 or source.cache_size % 1024 != 0) return;
        var shared = countGroupBits(cacheGroupMasks(source));
        shared = std.math.divCeil(usize, shared, self.max_lps_per_core) catch return;
        shared = @max(1, shared);
        if (shared > std.math.maxInt(u16)) return;
        const size_kib = source.cache_size / 1024 / shared;
        cache.* = .{
            .size_kib = @intCast(size_kib),
            .bytes_per_line = source.line_size,
            .associativity = if (source.associativity == 0xff)
                topology.Cache.max_associativity
            else
                source.associativity,
            .cores_sharing = @intCast(shared),
        };
    }
};

const IdField = enum {
    package,
    cluster,
    core,
};

const IdAssigner = struct {
    records: []topology.ProcessorRecord,
    id: u64,
    field: IdField,

    fn call(self: *@This(), lp: usize) void {
        const bounded = @min(lp, self.records.len - 1);
        switch (self.field) {
            .package => self.records[bounded].package_id = self.id,
            .cluster => self.records[bounded].cluster_id = self.id,
            .core => self.records[bounded].core_id = self.id,
        }
    }
};

const NodeAssigner = struct {
    records: []topology.ProcessorRecord,
    node: u8,

    fn call(self: *@This(), lp: usize) void {
        self.records[@min(lp, self.records.len - 1)].node = self.node;
    }
};

fn assignId(
    records: []topology.ProcessorRecord,
    groups: []const GroupAffinity,
    id: usize,
    field: IdField,
) void {
    var set = IdAssigner{ .records = records, .id = id, .field = field };
    forEachGroupBit(groups, &set);
}

fn assignNode(
    records: []topology.ProcessorRecord,
    groups: []const GroupAffinity,
    node: u8,
) void {
    var set = NodeAssigner{ .records = records, .node = node };
    forEachGroupBit(groups, &set);
}

fn forEachGroupBit(groups: []const GroupAffinity, visitor: anytype) void {
    for (groups, 0..) |group, group_index| {
        var remaining = group.mask;
        while (remaining != 0) {
            const bit: usize = @ctz(remaining);
            visitor.call(group_index * 64 + bit);
            remaining &= remaining - 1;
        }
    }
}

fn countGroupBits(groups: []const GroupAffinity) usize {
    var count: usize = 0;
    for (groups) |group| count += @popCount(group.mask);
    return count;
}

fn processorPayload(entry: *const Entry) *const ProcessorRelationship {
    return @ptrCast(@alignCast(@as([*]const u8, @ptrCast(entry)) + @sizeOf(Entry)));
}

fn cachePayload(entry: *const Entry) *const CacheRelationship {
    return @ptrCast(@alignCast(@as([*]const u8, @ptrCast(entry)) + @sizeOf(Entry)));
}

fn numaPayload(entry: *const Entry) *const NumaNodeRelationship {
    return @ptrCast(@alignCast(@as([*]const u8, @ptrCast(entry)) + @sizeOf(Entry)));
}

fn groupMasks(processor: *const ProcessorRelationship) []const GroupAffinity {
    return processor.group_mask[0..processor.group_count];
}

fn cacheGroupMasks(cache: *const CacheRelationship) []const GroupAffinity {
    return cache.group_masks[0..@max(1, cache.group_count)];
}

fn numaGroupMasks(numa: *const NumaNodeRelationship) []const GroupAffinity {
    return numa.group_masks[0..@max(1, numa.group_count)];
}

fn walk(buffer: []align(8) const u8, context: anytype, visit: anytype) bool {
    var offset: usize = 0;
    while (offset < buffer.len) {
        if (buffer.len - offset < @sizeOf(Entry)) return false;
        const entry: *const Entry = @ptrCast(@alignCast(buffer.ptr + offset));
        if (entry.size < @sizeOf(Entry) or entry.size > buffer.len - offset) return false;
        visit(context, entry);
        offset += entry.size;
    }
    return offset == buffer.len;
}

fn queryAlloc(
    allocator: std.mem.Allocator,
    relationship: Relationship,
) std.mem.Allocator.Error!?[]align(8) u8 {
    var required: u32 = 0;
    _ = GetLogicalProcessorInformationEx(relationship, null, &required);
    if (required == 0) return null;
    const allocation = try allocator.alignedAlloc(u8, .@"8", required);
    errdefer allocator.free(allocation);
    @memset(allocation, 0);
    var returned = required;
    if (!GetLogicalProcessorInformationEx(relationship, allocation.ptr, &returned).toBool() or
        returned > allocation.len)
    {
        allocator.free(allocation);
        return null;
    }
    return allocation[0..returned];
}

fn queryStatic(relationship: Relationship) ?[]align(8) const u8 {
    var required: u32 = 0;
    _ = GetLogicalProcessorInformationEx(relationship, null, &required);
    if (required == 0 or required > static_query.len) return null;
    @memset(static_query[0..required], 0);
    var returned = required;
    if (!GetLogicalProcessorInformationEx(
        relationship,
        static_query[0..required].ptr,
        &returned,
    ).toBool() or returned > required) return null;
    return static_query[0..returned];
}

comptime {
    std.debug.assert(@offsetOf(ProcessorRelationship, "group_mask") == 24);
    std.debug.assert(@offsetOf(NumaNodeRelationship, "group_masks") == 24);
    std.debug.assert(@offsetOf(CacheRelationship, "group_masks") == 32);
}
