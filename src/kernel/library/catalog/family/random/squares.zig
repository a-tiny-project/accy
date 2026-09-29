const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const random = @import("../../../root.zig").random;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const candidate_mod = @import("candidate.zig");

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const RandomCandidateDescriptors = candidate_mod.RandomCandidateDescriptors;
const RandomQuery = query_mod.RandomQuery;

pub fn select(backing_allocator: std.mem.Allocator, query: RandomQuery) !?OwnedDescriptor {
    return descriptorForInstance(backing_allocator, familyInstance(query) orelse return null, query);
}

pub fn appendCandidates(
    backing_allocator: std.mem.Allocator,
    query: RandomQuery,
    result: *RandomCandidateDescriptors,
) !void {
    const thread_candidates = random.squaresThreadCandidatesForCount(query.count);
    for (thread_candidates.slice()) |threads| {
        const instance = random.Squares{
            .count = query.count,
            .dtype = query.dtype,
            .threads = threads,
        };
        if (try descriptorForInstance(backing_allocator, instance, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
}

fn descriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: random.Squares,
    query: RandomQuery,
) !?OwnedDescriptor {
    var specialization = try random.squaresFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try random.squaresFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try random.squaresFamilyTarget(lifetime_allocator, instance),
            .version = random.squares_family_version,
            .layer = .logical,
            .category = .random,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.randomDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn familyInstance(query: RandomQuery) ?random.Squares {
    var instance = random.Squares{
        .count = query.count,
        .dtype = query.dtype,
        .threads = random.squaresThreadsForCount(query.count),
    };
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                if (@as(u64, threads) > instance.generators()) return null;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
