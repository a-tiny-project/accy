const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const geometry = @import("../../../root.zig").geometry;
const indexing = @import("../../../root.zig").indexing;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const ScatterAddQuery = query_mod.ScatterAddQuery;

pub const ScatterAddCandidateDescriptors = struct {
    count: usize = 0,
    items: [2 * geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const ScatterAddCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *ScatterAddCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectScatterAdd(
    backing_allocator: std.mem.Allocator,
    query: ScatterAddQuery,
) !?OwnedDescriptor {
    if (!canonicalScatterAdd(query)) return null;
    const instance = scatterAddFamilyInstance(query) orelse return null;
    return try scatterAddDescriptorForInstance(backing_allocator, instance, query);
}

pub fn selectScatterAddCandidates(
    backing_allocator: std.mem.Allocator,
    query: ScatterAddQuery,
) !ScatterAddCandidateDescriptors {
    var result = ScatterAddCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalScatterAdd(query)) return result;
    if (query.schedule != null) {
        if (try selectScatterAdd(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const query_total = scatterAddQueryTotal(query) orelse return result;
    const thread_candidates = indexing.scatterAddThreadCandidatesForTotal(query_total);
    const variants = [_]indexing.ScatterAddVariant{ .direct, .shared_bins };
    for (variants) |variant| {
        for (thread_candidates.slice()) |threads| {
            const instance = indexing.ScatterAdd{
                .outer = query.outer,
                .axis_size = query.axis_size,
                .updates = query.updates,
                .inner = query.inner,
                .dtype = query.dtype,
                .variant = variant,
                .threads = threads,
            };
            if (!indexing.scatterAddInstanceValid(instance)) continue;
            if (result.count >= result.items.len) break;
            if (try scatterAddDescriptorForInstance(
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

fn canonicalScatterAdd(query: ScatterAddQuery) bool {
    if (!indexing.scatterAddDTypeSupported(query.dtype)) return false;
    return query.outer != 0 and query.axis_size != 0 and query.updates != 0 and query.inner != 0;
}

fn scatterAddDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: indexing.ScatterAdd,
    query: ScatterAddQuery,
) !?OwnedDescriptor {
    var specialization = try indexing.scatterAddFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try indexing.scatterAddFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try indexing.scatterAddFamilyTarget(lifetime_allocator, instance),
            .version = indexing.scatter_add_family_version,
            .layer = .logical,
            .category = .indexing,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.scatterAddDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn scatterAddFamilyInstance(query: ScatterAddQuery) ?indexing.ScatterAdd {
    var instance = indexing.ScatterAdd{
        .outer = query.outer,
        .axis_size = query.axis_size,
        .updates = query.updates,
        .inner = query.inner,
        .dtype = query.dtype,
        .threads = indexing.scatterAddThreadsForTotal(
            scatterAddQueryTotal(query) orelse return null,
        ),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > instance.total()) return null;
                instance.threads = threads;
            },
            .shared_bins => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > instance.total()) return null;
                instance.variant = .shared_bins;
                instance.threads = threads;
            },
        }
    }
    if (!indexing.scatterAddInstanceValid(instance)) return null;
    return instance;
}

fn scatterAddQueryTotal(query: ScatterAddQuery) ?u64 {
    const outer_updates = std.math.mul(u64, query.outer, query.updates) catch return null;
    return std.math.mul(u64, outer_updates, query.inner) catch return null;
}

test "catalog scatter add family selection answers canonical queries" {
    const allocator = std.testing.allocator;

    var selected = (try selectScatterAdd(allocator, .{
        .dtype = .i32,
        .axis_size = 256,
        .updates = 1024,
    })) orelse return error.TestExpectedScatterAddDescriptor;
    defer selected.deinit();
    try std.testing.expect(std.mem.startsWith(
        u8,
        selected.descriptor.metadata.target,
        "accy.kernel.indexing.scatter_add_family_",
    ));
    try std.testing.expect(
        selected.descriptor.metadata.specialization.operationIs(.{ .indexing = .scatter_add }),
    );

    var scheduled = (try selectScatterAdd(allocator, .{
        .dtype = .i32,
        .axis_size = 256,
        .updates = 1024,
        .schedule = .{ .thread_blocks = 64 },
    })) orelse return error.TestExpectedScatterAddDescriptor;
    defer scheduled.deinit();
    try std.testing.expectEqualStrings(
        "accy.kernel.indexing.scatter_add_family_64_i32",
        scheduled.descriptor.metadata.target,
    );

    var single = (try selectScatterAdd(allocator, .{
        .dtype = .f32,
        .axis_size = 256,
        .updates = 1024,
    })) orelse return error.TestExpectedScatterAddDescriptor;
    defer single.deinit();
    try std.testing.expect(std.mem.endsWith(u8, single.descriptor.metadata.target, "_f32"));

    try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectScatterAdd(allocator, .{
        .dtype = .f16,
        .axis_size = 256,
        .updates = 1024,
    }));
    try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectScatterAdd(allocator, .{
        .dtype = .i32,
        .axis_size = 0,
        .updates = 1024,
    }));
}

test "catalog scatter add family candidates enumerate thread geometries" {
    const allocator = std.testing.allocator;

    var candidates = try selectScatterAddCandidates(allocator, .{
        .dtype = .i32,
        .axis_size = 128,
        .updates = 4096,
    });
    defer candidates.deinit();
    try std.testing.expect(candidates.count >= 2);
    for (candidates.slice()) |candidate| {
        try std.testing.expect(
            candidate.descriptor.metadata.specialization.operationIs(.{ .indexing = .scatter_add }),
        );
    }

    var pinned = try selectScatterAddCandidates(allocator, .{
        .dtype = .i32,
        .axis_size = 128,
        .updates = 4096,
        .schedule = .{ .thread_blocks = 128 },
    });
    defer pinned.deinit();
    try std.testing.expectEqual(@as(usize, 1), pinned.count);
    try std.testing.expectEqualStrings(
        "accy.kernel.indexing.scatter_add_family_128_i32",
        pinned.slice()[0].descriptor.metadata.target,
    );
}

test "catalog scatter add candidates enumerate both schedule structures" {
    const allocator = std.testing.allocator;

    var candidates = try selectScatterAddCandidates(allocator, .{
        .dtype = .i32,
        .axis_size = 128,
        .updates = 4096,
    });
    defer candidates.deinit();

    var direct_count: usize = 0;
    var shared_count: usize = 0;
    for (candidates.slice()) |candidate| {
        if (candidate.descriptor.metadata.specialization.structureIs("shared_bins")) {
            shared_count += 1;
        } else {
            direct_count += 1;
        }
    }
    try std.testing.expect(direct_count >= 2);
    try std.testing.expectEqual(direct_count, shared_count);

    var capped = try selectScatterAddCandidates(allocator, .{
        .dtype = .i32,
        .axis_size = indexing.scatter_add_shared_bins_cap + 1,
        .updates = 4096,
    });
    defer capped.deinit();
    for (capped.slice()) |candidate| {
        try std.testing.expect(
            !candidate.descriptor.metadata.specialization.structureIs("shared_bins"),
        );
    }

    var pinned = (try selectScatterAdd(allocator, .{
        .dtype = .i32,
        .axis_size = 128,
        .updates = 4096,
        .schedule = .{ .shared_bins = 128 },
    })) orelse return error.TestExpectedScatterAddDescriptor;
    defer pinned.deinit();
    try std.testing.expectEqualStrings(
        "accy.kernel.indexing.scatter_add_family_shared128_128_i32",
        pinned.descriptor.metadata.target,
    );
}
