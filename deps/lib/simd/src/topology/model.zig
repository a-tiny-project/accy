const std = @import("std");
const alloc_phase = @import("alloc_phase");
const simd = @import("../root.zig");

pub const max_logical_processors: usize = 1024;
pub const max_smt: usize = 16;
pub const LogicalProcessorSet = simd.bitset.BitSet4096(max_logical_processors);

pub const LP = packed struct {
    cluster: u16 = 0,
    core: u16 = 0,
    package: u8 = 0,
    smt: u8 = 0,
    node: u8 = 0,
    reserved: u8 = 0,
};

pub const Cluster = struct {
    lps: LogicalProcessorSet = .{},
    private_kib: u64 = 0,
    shared_kib: u64 = 0,
    reserved1: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u64 = 0,
};

pub const Core = struct {
    lps: LogicalProcessorSet = .{},
    reserved: u64 = 0,
};

pub const Package = struct {
    clusters: []const Cluster,
    cores: []const Core,
};

pub const Cache = packed struct {
    size_kib: u32 = 0,
    sets: u32 = 0,
    bytes_per_line: u16 = 0,
    associativity: u16 = 0,
    cores_sharing: u16 = 0,
    reserved: u16 = 0,

    pub const max_associativity: u16 = 128;
};

pub const ProcessorRecord = struct {
    package_id: u64,
    cluster_id: u64,
    core_id: u64,
    node: u8 = 0,
    private_kib: u64 = 0,
    shared_kib: u64 = 0,
};

pub const CapacityError = error{
    EmptyTopology,
    TooManyLogicalProcessors,
    TooManyPackages,
    TooManySiblings,
    AllocationSizeOverflow,
};

pub const Error = std.mem.Allocator.Error || CapacityError;

pub fn computeCacheSets(cache: *Cache) bool {
    if (cache.size_kib == 0) {
        cache.sets = 0;
        return true;
    }
    if (cache.bytes_per_line == 0 or cache.associativity == 0) return false;
    const bytes = @as(u64, cache.size_kib) * 1024;
    const computed = bytes / cache.bytes_per_line / cache.associativity;
    if (computed > std.math.maxInt(u32)) return false;
    if (cache.sets == 0) {
        cache.sets = @intCast(computed);
        return true;
    }
    const actual: u64 = cache.sets;
    return actual >= computed and actual - computed <= 1;
}

const max_packages: usize = std.math.maxInt(u8) + 1;
const storage_alignment: std.mem.Alignment = std.mem.Alignment.of(Cluster)
    .max(std.mem.Alignment.of(Core))
    .max(std.mem.Alignment.of(Package))
    .max(std.mem.Alignment.of(LP));

const PackageSize = struct {
    clusters: usize = 0,
    cores: usize = 0,
};

pub const TopologyLimits = struct {
    records: []const ProcessorRecord,
};

pub const TopologyCapacity = struct {
    logical_processors: usize = 0,
    packages: usize = 0,
    clusters: usize = 0,
    cores: usize = 0,
    storage_bytes: usize = 0,

    pub fn derive(limits: TopologyLimits) CapacityError!TopologyCapacity {
        var mapped_lps: [max_logical_processors]LP = @splat(.{});
        var package_sizes: [max_packages]PackageSize = @splat(.{});
        return inspectRecords(limits.records, &mapped_lps, &package_sizes);
    }
};

pub const Topology = struct {
    phase: alloc_phase.capacity.Phase = .initialization,
    capacity: TopologyCapacity = .{},
    allocation: ?[]align(storage_alignment.toByteUnits()) u8 = null,
    packages: []const Package = &.{},
    lps: []const LP = &.{},

    pub const Limits: type = TopologyLimits;
    pub const Capacity: type = TopologyCapacity;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "simd.topology_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "one_exact_topology_array_region_and_borrowed_views",
                        .lifetime = .steady,
                        .detail = "one exact topology array region and borrowed views",
                    },
                },
                .excluded = &.{
                    "caller-owned processor discovery records",
                    "operating-system queries and temporary relationship buffers",
                },
            },
            .capacity = .{
                .inputs = &.{},
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .constant = 0 },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 0,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "empty oversize package and SMT bounds reject before allocation",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "remapping placement and allocation cleanup are checked together",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "native discovery completes before immutable topology storage is sealed",
                },
            },
            .obligations = &.{
                .{ .key = "simd_topology_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "simd_topology_capacity_overload", .role = .overload },
                .{ .key = "simd_topology_remap", .role = .transitive_risk },
                .{ .key = "simd_topology_oom", .role = .transitive_risk },
                .{ .key = "simd_topology_native", .role = .foreign_risk },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
    ) Error!Topology {
        const records = limits.records;
        var mapped_lps: [max_logical_processors]LP = @splat(.{});
        var package_sizes: [max_packages]PackageSize = @splat(.{});
        const capacity_value = try inspectRecords(records, &mapped_lps, &package_sizes);
        const allocation = try allocator.alignedAlloc(
            u8,
            storage_alignment,
            capacity_value.storage_bytes,
        );
        errdefer allocator.free(allocation);
        @memset(allocation, 0);

        var offset: usize = 0;
        const packages = take(Package, allocation, &offset, capacity_value.packages);
        const clusters = take(Cluster, allocation, &offset, capacity_value.clusters);
        const cores = take(Core, allocation, &offset, capacity_value.cores);
        const lps = take(LP, allocation, &offset, capacity_value.logical_processors);
        std.debug.assert(offset == capacity_value.storage_bytes);
        @memcpy(lps, mapped_lps[0..records.len]);
        placePackageSlices(packages, clusters, cores, &package_sizes);
        populateSets(packages, lps, records);
        return .{
            .phase = .initialization,
            .capacity = capacity_value,
            .allocation = allocation,
            .packages = packages,
            .lps = lps,
        };
    }

    pub fn initFromRecords(
        allocator: std.mem.Allocator,
        records: []const ProcessorRecord,
    ) Error!Topology {
        var topology = try init(allocator, .{ .records = records });
        topology.activate();
        return topology;
    }

    pub fn activate(self: *Topology) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.capacity.logical_processors == self.lps.len);
        self.phase = .steady;
    }

    pub fn deinit(self: *Topology, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        self.phase = .teardown;
        if (self.allocation) |allocation| allocator.free(allocation);
        self.allocation = null;
        self.packages = &.{};
        self.lps = &.{};
    }

    pub fn allocatedBytes(self: *const Topology) usize {
        std.debug.assert(self.phase != .teardown);
        return if (self.allocation) |allocation| allocation.len else 0;
    }
};

fn inspectRecords(
    records: []const ProcessorRecord,
    mapped_lps: *[max_logical_processors]LP,
    package_sizes: *[max_packages]PackageSize,
) CapacityError!TopologyCapacity {
    if (records.len == 0) return error.EmptyTopology;
    if (records.len > max_logical_processors) return error.TooManyLogicalProcessors;
    var package_count: usize = 0;
    for (records, 0..) |record, index| {
        const package = try mapPackage(records, mapped_lps, index, &package_count);
        const cluster = mapMember(
            records,
            mapped_lps,
            index,
            package,
            .cluster,
            package_sizes[package].clusters,
        );
        if (cluster.is_new) package_sizes[package].clusters += 1;
        const core = mapMember(
            records,
            mapped_lps,
            index,
            package,
            .core,
            package_sizes[package].cores,
        );
        if (core.is_new) package_sizes[package].cores += 1;
        const smt = countSiblings(mapped_lps, index, package, core.index);
        if (smt >= max_smt) return error.TooManySiblings;
        mapped_lps[index] = .{
            .cluster = @intCast(cluster.index),
            .core = @intCast(core.index),
            .package = @intCast(package),
            .smt = @intCast(smt),
            .node = record.node,
        };
    }
    var cluster_count: usize = 0;
    var core_count: usize = 0;
    for (package_sizes[0..package_count]) |size| {
        cluster_count = std.math.add(usize, cluster_count, size.clusters) catch
            return error.AllocationSizeOverflow;
        core_count = std.math.add(usize, core_count, size.cores) catch
            return error.AllocationSizeOverflow;
    }
    return .{
        .logical_processors = records.len,
        .packages = package_count,
        .clusters = cluster_count,
        .cores = core_count,
        .storage_bytes = try storageBytes(
            records.len,
            package_count,
            cluster_count,
            core_count,
        ),
    };
}

fn placePackageSlices(
    packages: []Package,
    clusters: []Cluster,
    cores: []Core,
    package_sizes: *const [max_packages]PackageSize,
) void {
    var cluster_offset: usize = 0;
    var core_offset: usize = 0;
    for (packages, package_sizes[0..packages.len]) |*package, size| {
        package.* = .{
            .clusters = clusters[cluster_offset..][0..size.clusters],
            .cores = cores[core_offset..][0..size.cores],
        };
        cluster_offset += size.clusters;
        core_offset += size.cores;
    }
    std.debug.assert(cluster_offset == clusters.len);
    std.debug.assert(core_offset == cores.len);
}

fn populateSets(
    packages: []Package,
    lps: []const LP,
    records: []const ProcessorRecord,
) void {
    for (lps, records, 0..) |lp, record, index| {
        const package = &packages[lp.package];
        const cluster = @constCast(&package.clusters[lp.cluster]);
        const core = @constCast(&package.cores[lp.core]);
        cluster.lps.set(index);
        core.lps.set(index);
        if (cluster.private_kib == 0) cluster.private_kib = record.private_kib;
        if (cluster.shared_kib == 0) cluster.shared_kib = record.shared_kib;
    }
}

const Member = enum {
    cluster,
    core,
};

const MappedMember = struct {
    index: usize,
    is_new: bool,
};

fn mapPackage(
    records: []const ProcessorRecord,
    lps: *const [max_logical_processors]LP,
    index: usize,
    package_count: *usize,
) CapacityError!usize {
    for (records[0..index], 0..) |prior, prior_index| {
        if (prior.package_id == records[index].package_id) return lps[prior_index].package;
    }
    if (package_count.* == max_packages) return error.TooManyPackages;
    const mapped = package_count.*;
    package_count.* += 1;
    return mapped;
}

fn mapMember(
    records: []const ProcessorRecord,
    lps: *const [max_logical_processors]LP,
    index: usize,
    package: usize,
    member: Member,
    next: usize,
) MappedMember {
    const wanted = memberId(records[index], member);
    for (records[0..index], 0..) |prior, prior_index| {
        const prior_lp = lps[prior_index];
        if (prior_lp.package == package and memberId(prior, member) == wanted) {
            return .{
                .index = switch (member) {
                    .cluster => prior_lp.cluster,
                    .core => prior_lp.core,
                },
                .is_new = false,
            };
        }
    }
    return .{ .index = next, .is_new = true };
}

fn memberId(record: ProcessorRecord, member: Member) u64 {
    return switch (member) {
        .cluster => record.cluster_id,
        .core => record.core_id,
    };
}

fn countSiblings(
    lps: *const [max_logical_processors]LP,
    end: usize,
    package: usize,
    core: usize,
) usize {
    var count: usize = 0;
    for (lps[0..end]) |lp| {
        if (lp.package == package and lp.core == core) count += 1;
    }
    return count;
}

fn storageBytes(
    lp_count: usize,
    package_count: usize,
    cluster_count: usize,
    core_count: usize,
) CapacityError!usize {
    var offset: usize = 0;
    try addTypeBytes(Package, &offset, package_count);
    try addTypeBytes(Cluster, &offset, cluster_count);
    try addTypeBytes(Core, &offset, core_count);
    try addTypeBytes(LP, &offset, lp_count);
    return offset;
}

fn addTypeBytes(comptime T: type, offset: *usize, count: usize) CapacityError!void {
    offset.* = std.mem.Alignment.of(T).forward(offset.*);
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch
        return error.AllocationSizeOverflow;
    offset.* = std.math.add(usize, offset.*, bytes) catch
        return error.AllocationSizeOverflow;
}

fn take(
    comptime T: type,
    allocation: []align(storage_alignment.toByteUnits()) u8,
    offset: *usize,
    count: usize,
) []T {
    offset.* = std.mem.Alignment.of(T).forward(offset.*);
    const pointer: [*]T = @ptrCast(@alignCast(allocation.ptr + offset.*));
    const values = pointer[0..count];
    offset.* += @sizeOf(T) * count;
    return values;
}

const SetAdder = struct {
    set: *LogicalProcessorSet,

    pub fn call(self: *@This(), index: usize) void {
        self.set.set(index);
    }
};

fn expectCoverage(topology: *const Topology) !void {
    var cluster_union = LogicalProcessorSet{};
    var core_union = LogicalProcessorSet{};
    var cluster_total: usize = 0;
    var core_total: usize = 0;
    for (topology.packages) |package| {
        try std.testing.expect(package.clusters.len != 0);
        try std.testing.expect(package.cores.len != 0);
        try std.testing.expect(package.clusters.len <= package.cores.len);
        for (package.clusters) |cluster| {
            cluster_total += cluster.lps.count();
            var add = SetAdder{ .set = &cluster_union };
            cluster.lps.foreach(&add);
        }
        for (package.cores) |core| {
            core_total += core.lps.count();
            var add = SetAdder{ .set = &core_union };
            core.lps.foreach(&add);
        }
    }
    try std.testing.expectEqual(topology.lps.len, cluster_total);
    try std.testing.expectEqual(topology.lps.len, core_total);
    try std.testing.expectEqual(topology.lps.len, cluster_union.count());
    try std.testing.expectEqual(topology.lps.len, core_union.count());
}

fn checkInitFailures(allocator: std.mem.Allocator) !void {
    const records = [_]ProcessorRecord{
        .{ .package_id = 9, .cluster_id = 42, .core_id = 100 },
        .{ .package_id = 9, .cluster_id = 42, .core_id = 100 },
        .{ .package_id = 9, .cluster_id = 42, .core_id = 101 },
        .{ .package_id = 4, .cluster_id = 7, .core_id = 5 },
    };
    var topology = try Topology.initFromRecords(allocator, &records);
    topology.deinit(allocator);
}

test "Highway topology remaps opaque IDs and covers every logical processor" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Topology, "simd_topology_remap"));
    }

    const records = [_]ProcessorRecord{
        .{
            .package_id = 9,
            .cluster_id = 42,
            .core_id = 100,
            .node = 3,
            .private_kib = 512,
            .shared_kib = 4096,
        },
        .{ .package_id = 9, .cluster_id = 42, .core_id = 100, .node = 3 },
        .{ .package_id = 9, .cluster_id = 42, .core_id = 101, .node = 3 },
        .{
            .package_id = 4,
            .cluster_id = 7,
            .core_id = 5,
            .node = 8,
            .private_kib = 1024,
        },
        .{ .package_id = 4, .cluster_id = 8, .core_id = 6, .node = 8 },
    };
    var topology = try Topology.initFromRecords(std.testing.allocator, &records);
    defer topology.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), topology.packages.len);
    try std.testing.expectEqual(@as(usize, 5), topology.lps.len);
    try std.testing.expectEqual(@as(usize, 1), topology.packages[0].clusters.len);
    try std.testing.expectEqual(@as(usize, 2), topology.packages[0].cores.len);
    try std.testing.expectEqual(@as(usize, 2), topology.packages[1].clusters.len);
    try std.testing.expectEqual(@as(usize, 2), topology.packages[1].cores.len);
    try std.testing.expectEqual(@as(u8, 0), topology.lps[0].smt);
    try std.testing.expectEqual(@as(u8, 1), topology.lps[1].smt);
    try std.testing.expectEqual(@as(u8, 8), topology.lps[4].node);
    try std.testing.expectEqual(@as(u64, 512), topology.packages[0].clusters[0].private_kib);
    try std.testing.expectEqual(@as(u64, 4096), topology.packages[0].clusters[0].shared_kib);
    try expectCoverage(&topology);
}

test "Highway topology keeps one persistent bounded allocation" {
    const records = [_]ProcessorRecord{
        .{ .package_id = 0, .cluster_id = 0, .core_id = 0 },
        .{ .package_id = 0, .cluster_id = 0, .core_id = 1 },
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var topology = try Topology.initFromRecords(failing.allocator(), &records);
    defer topology.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.steady, topology.phase);
    try std.testing.expectEqual(topology.capacity.storage_bytes, topology.allocatedBytes());
    try std.testing.expect(topology.allocatedBytes() >= @sizeOf(Cluster) + 2 * @sizeOf(Core));
}

test "Highway topology capacity matches its single-region placement" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Topology, "simd_topology_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Topology, "simd_topology_capacity_overload"),
        );
    }

    const records = [_]ProcessorRecord{
        .{ .package_id = 9, .cluster_id = 42, .core_id = 100 },
        .{ .package_id = 9, .cluster_id = 42, .core_id = 100 },
        .{ .package_id = 9, .cluster_id = 42, .core_id = 101 },
        .{ .package_id = 4, .cluster_id = 7, .core_id = 5 },
        .{ .package_id = 4, .cluster_id = 8, .core_id = 6 },
    };
    const capacity = try TopologyCapacity.derive(.{ .records = &records });
    try std.testing.expectEqual(@as(usize, 5), capacity.logical_processors);
    try std.testing.expectEqual(@as(usize, 2), capacity.packages);
    try std.testing.expectEqual(@as(usize, 3), capacity.clusters);
    try std.testing.expectEqual(@as(usize, 4), capacity.cores);
    var independent_bytes: usize = 0;
    independent_bytes = std.mem.Alignment.of(Package).forward(independent_bytes);
    independent_bytes += @sizeOf(Package) * capacity.packages;
    independent_bytes = std.mem.Alignment.of(Cluster).forward(independent_bytes);
    independent_bytes += @sizeOf(Cluster) * capacity.clusters;
    independent_bytes = std.mem.Alignment.of(Core).forward(independent_bytes);
    independent_bytes += @sizeOf(Core) * capacity.cores;
    independent_bytes = std.mem.Alignment.of(LP).forward(independent_bytes);
    independent_bytes += @sizeOf(LP) * capacity.logical_processors;
    try std.testing.expectEqual(independent_bytes, capacity.storage_bytes);
}

test "Highway topology rejects capacity violations before allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(
        error.EmptyTopology,
        Topology.initFromRecords(failing.allocator(), &.{}),
    );
    var oversized: [max_logical_processors + 1]ProcessorRecord = undefined;
    for (&oversized) |*record| record.* = .{
        .package_id = 0,
        .cluster_id = 0,
        .core_id = 0,
    };
    try std.testing.expectError(
        error.TooManyLogicalProcessors,
        Topology.initFromRecords(failing.allocator(), &oversized),
    );
    var packages: [max_packages + 1]ProcessorRecord = undefined;
    for (&packages, 0..) |*record, index| record.* = .{
        .package_id = index,
        .cluster_id = 0,
        .core_id = 0,
    };
    try std.testing.expectError(
        error.TooManyPackages,
        Topology.initFromRecords(failing.allocator(), &packages),
    );
    var siblings: [max_smt + 1]ProcessorRecord = undefined;
    for (&siblings) |*record| record.* = .{
        .package_id = 0,
        .cluster_id = 0,
        .core_id = 0,
    };
    try std.testing.expectError(
        error.TooManySiblings,
        Topology.initFromRecords(failing.allocator(), &siblings),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "Highway topology construction is transactional under allocation failure" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Topology, "simd_topology_oom"));
    }

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkInitFailures,
        .{},
    );
}

test "Highway cache sets derive from per-core geometry" {
    var cache = Cache{
        .size_kib = 1024,
        .bytes_per_line = 64,
        .associativity = 8,
        .cores_sharing = 1,
    };
    try std.testing.expect(computeCacheSets(&cache));
    try std.testing.expectEqual(@as(u32, 2048), cache.sets);
    cache.sets -= 1;
    try std.testing.expect(!computeCacheSets(&cache));
    cache.sets += 2;
    try std.testing.expect(computeCacheSets(&cache));
    cache.sets += 1;
    try std.testing.expect(!computeCacheSets(&cache));
    cache = .{};
    try std.testing.expect(computeCacheSets(&cache));
}

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(Topology);
}

comptime {
    std.debug.assert(@sizeOf(LP) == 8);
    std.debug.assert(@sizeOf(Cache) == 16);
    std.debug.assert(@sizeOf(LogicalProcessorSet) == 136);
}
