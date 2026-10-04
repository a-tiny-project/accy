const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const scan = @import("../../../root.zig").scan;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const ScanQuery = query_mod.ScanQuery;

pub const PrefixSumCandidateDescriptors = struct {
    count: usize = 0,
    items: [8]OwnedDescriptor = undefined,

    pub fn slice(self: *const PrefixSumCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *PrefixSumCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectPrefixSum(backing_allocator: std.mem.Allocator, query: ScanQuery) !?OwnedDescriptor {
    if (canonicalPrefixSum(query)) {
        const instance = prefixSumFamilyInstance(query) orelse return null;
        return try prefixSumDescriptorForInstance(backing_allocator, instance, query);
    }
    if (canonicalDeviceScan(query)) {
        const instance = deviceScanFamilyInstance(query) orelse return null;
        return try deviceScanDescriptorForInstance(backing_allocator, instance, query);
    }
    return null;
}

pub fn selectPrefixSumCandidates(
    backing_allocator: std.mem.Allocator,
    query: ScanQuery,
) !PrefixSumCandidateDescriptors {
    var result = PrefixSumCandidateDescriptors{};
    errdefer result.deinit();

    if (query.schedule != null) {
        if (try selectPrefixSum(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    if (canonicalPrefixSum(query)) {
        const thread_candidates = scan.prefixSumThreadCandidatesForExtent(query.extent);
        for (thread_candidates.slice()) |threads| {
            const instance = scan.PrefixSum{
                .extent = query.extent,
                .dtype = query.dtype,
                .mode = scan.PrefixSumMode.fromOperation(query.kind),
                .threads = threads,
            };
            if (try prefixSumDescriptorForInstance(
                backing_allocator,
                instance,
                query,
            )) |descriptor| {
                result.items[result.count] = descriptor;
                result.count += 1;
            }
        }
        return result;
    }

    if (canonicalDeviceScan(query)) {
        const thread_candidates = scan.deviceScanThreadCandidatesForExtent(query.extent);
        for (thread_candidates.slice()) |threads| {
            const instance = scan.DeviceScan{
                .extent = query.extent,
                .dtype = query.dtype,
                .mode = scan.PrefixSumMode.fromOperation(query.kind),
                .threads = threads,
            };
            if (try deviceScanDescriptorForInstance(
                backing_allocator,
                instance,
                query,
            )) |descriptor| {
                result.items[result.count] = descriptor;
                result.count += 1;
            }
        }
    }
    return result;
}

fn canonicalPrefixSum(query: ScanQuery) bool {
    if (!scan.prefixSumDTypeSupported(query.dtype)) return false;
    return query.extent != 0 and query.extent <= scan.prefix_sum_max_threads;
}

fn canonicalDeviceScan(query: ScanQuery) bool {
    if (!scan.deviceScanDTypeSupported(query.dtype)) return false;
    if (query.extent <= scan.prefix_sum_max_threads) return false;
    return scan.deviceScanThreadsForExtent(query.extent) != null;
}

fn deviceScanFamilyInstance(query: ScanQuery) ?scan.DeviceScan {
    var instance = scan.DeviceScan{
        .extent = query.extent,
        .dtype = query.dtype,
        .mode = scan.PrefixSumMode.fromOperation(query.kind),
        .threads = scan.deviceScanThreadsForExtent(query.extent) orelse return null,
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                instance.threads = threads;
            },
        }
    }
    if (!scan.deviceScanInstanceValid(instance)) return null;
    return instance;
}

fn deviceScanDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: scan.DeviceScan,
    query: ScanQuery,
) !?OwnedDescriptor {
    var specialization = try scan.deviceScanFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try scan.deviceScanFamilyTarget(lifetime_allocator, instance),
        .metadata = .{
            .target = try scan.deviceScanFamilyTarget(lifetime_allocator, instance),
            .version = scan.device_scan_family_version,
            .layer = .logical,
            .category = .scan,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.prefixSumDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn prefixSumDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: scan.PrefixSum,
    query: ScanQuery,
) !?OwnedDescriptor {
    var specialization = try scan.prefixSumFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try scan.prefixSumFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try scan.prefixSumFamilyTarget(lifetime_allocator, instance),
            .version = scan.prefix_sum_family_version,
            .layer = .logical,
            .category = .scan,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.prefixSumDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn prefixSumFamilyInstance(query: ScanQuery) ?scan.PrefixSum {
    var instance = scan.PrefixSum{
        .extent = query.extent,
        .dtype = query.dtype,
        .mode = scan.PrefixSumMode.fromOperation(query.kind),
        .threads = scan.prefixSumThreadsForExtent(query.extent) orelse return null,
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                instance.threads = threads;
            },
        }
    }
    if (!scan.prefixSumInstanceValid(instance)) return null;
    return instance;
}
