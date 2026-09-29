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
        if (try rowSparseCrossEntropyDescriptorForInstance(backing_allocator, instance, query)) |descriptor| {
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
    var specialization = try loss.rowSparseCrossEntropyFamilySpecialization(backing_allocator, instance);
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

fn rowSparseCrossEntropyFamilyInstance(query: RowSparseCrossEntropyQuery) ?loss.RowSparseCrossEntropy {
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

test "catalog row sparse cross entropy family selection answers canonical queries" {
    const allocator = std.testing.allocator;

    var selected = (try selectRowSparseCrossEntropy(allocator, .{
        .dtype = .f32,
        .rows = 512,
        .classes = 1000,
    })) orelse return error.TestExpectedRowSparseCrossEntropyDescriptor;
    defer selected.deinit();
    try std.testing.expect(std.mem.startsWith(u8, selected.descriptor.metadata.target, "accy.kernel.loss.row_sparse_cross_entropy_family_"));
    try std.testing.expect(selected.descriptor.metadata.specialization.operationIs(.{ .loss = .row_sparse_cross_entropy }));

    var scheduled = (try selectRowSparseCrossEntropy(allocator, .{
        .dtype = .f32,
        .rows = 512,
        .classes = 1000,
        .schedule = .{ .thread_blocks = 64 },
    })) orelse return error.TestExpectedRowSparseCrossEntropyDescriptor;
    defer scheduled.deinit();
    try std.testing.expectEqualStrings("accy.kernel.loss.row_sparse_cross_entropy_family_64_f32", scheduled.descriptor.metadata.target);

    try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectRowSparseCrossEntropy(allocator, .{
        .dtype = .f16,
        .rows = 512,
        .classes = 1000,
    }));
    try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectRowSparseCrossEntropy(allocator, .{
        .dtype = .f32,
        .rows = 0,
        .classes = 1000,
    }));
}

test "catalog row sparse cross entropy candidates enumerate thread geometries" {
    const allocator = std.testing.allocator;

    var candidates = try selectRowSparseCrossEntropyCandidates(allocator, .{
        .dtype = .f32,
        .rows = 4096,
        .classes = 128,
    });
    defer candidates.deinit();
    try std.testing.expect(candidates.count >= 2);
    for (candidates.slice()) |candidate| {
        try std.testing.expect(candidate.descriptor.metadata.specialization.operationIs(.{ .loss = .row_sparse_cross_entropy }));
    }

    var pinned = try selectRowSparseCrossEntropyCandidates(allocator, .{
        .dtype = .f32,
        .rows = 4096,
        .classes = 128,
        .schedule = .{ .thread_blocks = 128 },
    });
    defer pinned.deinit();
    try std.testing.expectEqual(@as(usize, 1), pinned.count);
    try std.testing.expectEqualStrings(
        "accy.kernel.loss.row_sparse_cross_entropy_family_128_f32",
        pinned.slice()[0].descriptor.metadata.target,
    );
}
