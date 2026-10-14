const std = @import("std");

const descriptor_mod = @import("../root.zig");
const geometry = @import("../../root.zig").geometry;
const loss = @import("../../root.zig").loss;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const RowSparseCrossEntropyQuery = query_mod.RowSparseCrossEntropyQuery;

pub const RowSparseCrossEntropyCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const RowSparseCrossEntropyCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *RowSparseCrossEntropyCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectRowSparseCrossEntropy(
    backing_allocator: std.mem.Allocator,
    query: RowSparseCrossEntropyQuery,
) !?OwnedDescriptor {
    if (!canonicalRowSparseCrossEntropy(query)) return null;
    const instance = rowSparseCrossEntropyFamilyInstance(query) orelse return null;
    return try rowSparseCrossEntropyDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectRowSparseCrossEntropyCandidates(
    backing_allocator: std.mem.Allocator,
    query: RowSparseCrossEntropyQuery,
) !RowSparseCrossEntropyCandidateDescriptors {
    var result = RowSparseCrossEntropyCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalRowSparseCrossEntropy(query)) return result;
    if (query.schedule != null) {
        if (try selectRowSparseCrossEntropy(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = loss.rowSparseCrossEntropyThreadCandidatesForRows(query.rows);
    for (thread_candidates.slice()) |threads| {
        const instance = loss.RowSparseCrossEntropy{
            .rows = query.rows,
            .classes = query.classes,
            .dtype = query.dtype,
            .threads = threads,
        };
        if (!loss.rowSparseCrossEntropyInstanceValid(instance)) continue;
        if (result.count >= result.items.len) break;
        if (try rowSparseCrossEntropyDescriptorForInstance(
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

fn canonicalRowSparseCrossEntropy(query: RowSparseCrossEntropyQuery) bool {
    if (!loss.rowSparseCrossEntropyDTypeSupported(query.dtype)) return false;
    return query.rows != 0 and query.classes != 0;
}

fn rowSparseCrossEntropyDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: loss.RowSparseCrossEntropy,
    query: RowSparseCrossEntropyQuery,
) !?OwnedDescriptor {
    var specialization = try loss.rowSparseCrossEntropyFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try loss.rowSparseCrossEntropyFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try loss.rowSparseCrossEntropyFamilyTarget(lifetime_allocator, instance),
            .version = loss.row_sparse_cross_entropy_family_version,
            .layer = .logical,
            .category = .loss,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.rowSparseCrossEntropyDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn rowSparseCrossEntropyFamilyInstance(
    query: RowSparseCrossEntropyQuery,
) ?loss.RowSparseCrossEntropy {
    var instance = loss.RowSparseCrossEntropy{
        .rows = query.rows,
        .classes = query.classes,
        .dtype = query.dtype,
        .threads = loss.rowSparseCrossEntropyThreadsForRows(query.rows),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > instance.rows) return null;
                instance.threads = threads;
            },
        }
    }
    if (!loss.rowSparseCrossEntropyInstanceValid(instance)) return null;
    return instance;
}
