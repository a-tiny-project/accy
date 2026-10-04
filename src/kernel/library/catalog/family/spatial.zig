const std = @import("std");

const descriptor_mod = @import("../root.zig");
const geometry = @import("../../root.zig").geometry;
const spatial_mod = @import("../../root.zig").spatial;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SpatialQuery = query_mod.SpatialQuery;

pub const SpatialCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const SpatialCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *SpatialCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectSpatial(backing_allocator: std.mem.Allocator, query: SpatialQuery) !?OwnedDescriptor {
    if (!canonicalSpatial(query)) return null;
    const threads = spatialQueryThreads(query) orelse return null;
    return try spatialDescriptorForThreads(backing_allocator, query, threads);
}

pub fn selectSpatialCandidates(
    backing_allocator: std.mem.Allocator,
    query: SpatialQuery,
) !SpatialCandidateDescriptors {
    var result = SpatialCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalSpatial(query)) return result;
    if (query.schedule != null) {
        if (try selectSpatial(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = spatial_mod.spatialThreadCandidatesForCount(query.count);
    for (thread_candidates.slice()) |threads| {
        if (result.count >= result.items.len) break;
        if (try spatialDescriptorForThreads(backing_allocator, query, threads)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn canonicalSpatial(query: SpatialQuery) bool {
    if (query.count == 0) return false;
    return switch (query.kind) {
        .grid_cells => query.dtype == .f32,
        .grid_count => |facts| query.dtype == .i32 and facts.cells != 0,
        .grid_neighbor_count => |facts| query.dtype == .f32 and
            facts.cells != 0 and facts.stride != 0,
    };
}

fn spatialQueryThreads(query: SpatialQuery) ?u32 {
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                return threads;
            },
        }
    }
    return spatial_mod.spatialThreadsForCount(query.count);
}

fn spatialDescriptorForThreads(
    backing_allocator: std.mem.Allocator,
    query: SpatialQuery,
    threads: u32,
) !?OwnedDescriptor {
    switch (query.kind) {
        .grid_cells => {
            const instance = spatial_mod.GridCells{ .count = query.count, .threads = threads };
            if (!spatial_mod.gridCellsInstanceValid(instance)) return null;
            var specialization = try spatial_mod.gridCellsFamilySpecialization(
                backing_allocator,
                instance,
            );
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try spatial_mod.gridCellsFamilyEntryName(lifetime_allocator, instance),
                .metadata = .{
                    .target = try spatial_mod.gridCellsFamilyTarget(lifetime_allocator, instance),
                    .version = spatial_mod.grid_cells_family_version,
                    .layer = .logical,
                    .category = .spatial,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.spatialDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
        .grid_count => |facts| {
            const instance = spatial_mod.GridCount{
                .count = query.count,
                .cells = facts.cells,
                .threads = threads,
            };
            if (!spatial_mod.gridCountInstanceValid(instance)) return null;
            var specialization = try spatial_mod.gridCountFamilySpecialization(
                backing_allocator,
                instance,
            );
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try spatial_mod.gridCountFamilyEntryName(lifetime_allocator, instance),
                .metadata = .{
                    .target = try spatial_mod.gridCountFamilyTarget(lifetime_allocator, instance),
                    .version = spatial_mod.grid_count_family_version,
                    .layer = .logical,
                    .category = .spatial,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.spatialDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
        .grid_neighbor_count => |facts| {
            const offsets_extent = @as(u64, facts.cells) * facts.stride;
            const instance = spatial_mod.GridNeighborCount{
                .count = query.count,
                .offsets_extent = offsets_extent,
                .threads = threads,
            };
            if (!spatial_mod.gridNeighborCountInstanceValid(instance)) return null;
            var specialization = try spatial_mod.gridNeighborCountFamilySpecialization(
                backing_allocator,
                instance,
            );
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try spatial_mod.gridNeighborCountFamilyEntryName(
                    lifetime_allocator,
                    instance,
                ),
                .metadata = .{
                    .target = try spatial_mod.gridNeighborCountFamilyTarget(
                        lifetime_allocator,
                        instance,
                    ),
                    .version = spatial_mod.grid_neighbor_count_family_version,
                    .layer = .logical,
                    .category = .spatial,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.spatialDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
    }
}

test "catalog spatial selection covers all three kernels" {
    const allocator = std.testing.allocator;

    var cells = (try selectSpatial(allocator, .{
        .dtype = .f32,
        .kind = .grid_cells,
        .count = 5000,
    })) orelse return error.TestExpectedSpatialDescriptor;
    defer cells.deinit();
    try std.testing.expectEqualStrings(
        "accy.kernel.spatial.grid_cells_family_32_f32",
        cells.descriptor.metadata.target,
    );
    try std.testing.expect(
        cells.descriptor.metadata.specialization.operationIs(.{ .spatial = .grid_cells }),
    );

    var count = (try selectSpatial(allocator, .{
        .dtype = .i32,
        .kind = .{ .grid_count = .{ .cells = 64 } },
        .count = 5000,
        .schedule = .{ .thread_blocks = 64 },
    })) orelse return error.TestExpectedSpatialDescriptor;
    defer count.deinit();
    try std.testing.expectEqualStrings(
        "accy.kernel.spatial.grid_count_family_64_64_i32",
        count.descriptor.metadata.target,
    );

    var neighbor = (try selectSpatial(allocator, .{
        .dtype = .f32,
        .kind = .{ .grid_neighbor_count = .{ .cells = 64, .stride = 79 } },
        .count = 5000,
        .schedule = .{ .thread_blocks = 64 },
    })) orelse return error.TestExpectedSpatialDescriptor;
    defer neighbor.deinit();
    try std.testing.expectEqualStrings(
        "accy.kernel.spatial.grid_neighbor_count_family_64_f32",
        neighbor.descriptor.metadata.target,
    );

    try std.testing.expectEqual(
        @as(?OwnedDescriptor, null),
        try selectSpatial(allocator, .{ .dtype = .i32, .kind = .grid_cells, .count = 5000 }),
    );
    try std.testing.expectEqual(
        @as(?OwnedDescriptor, null),
        try selectSpatial(allocator, .{ .dtype = .f32, .kind = .grid_cells, .count = 0 }),
    );
    try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSpatial(allocator, .{
        .dtype = .i32,
        .kind = .{ .grid_count = .{ .cells = 8192 } },
        .count = 5000,
    }));

    var candidates = try selectSpatialCandidates(allocator, .{
        .dtype = .f32,
        .kind = .grid_cells,
        .count = 8192,
    });
    defer candidates.deinit();
    try std.testing.expect(candidates.count >= 2);
    for (candidates.slice()) |candidate| {
        try std.testing.expect(
            candidate.descriptor.metadata.specialization.operationIs(.{ .spatial = .grid_cells }),
        );
    }
}
