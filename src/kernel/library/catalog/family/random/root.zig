const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const random = @import("../../../root.zig").random;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const candidate = @import("candidate.zig");
const philox = @import("philox.zig");
const squares = @import("squares.zig");
const threefry = @import("threefry.zig");

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const RandomQuery = query_mod.RandomQuery;

pub const RandomCandidateDescriptors = candidate.RandomCandidateDescriptors;

pub fn selectRandom(backing_allocator: std.mem.Allocator, query: RandomQuery) !?OwnedDescriptor {
    if (!canonicalRandom(query)) return null;
    return switch (query.algorithm) {
        .philox => philox.select(backing_allocator, query),
        .threefry => threefry.select(backing_allocator, query),
        .squares => squares.select(backing_allocator, query),
    };
}

pub fn selectRandomCandidates(
    backing_allocator: std.mem.Allocator,
    query: RandomQuery,
) !RandomCandidateDescriptors {
    var result = RandomCandidateDescriptors{};
    errdefer result.deinit();

    if (!canonicalRandom(query)) return result;
    if (query.schedule != null) {
        if (try selectRandom(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    switch (query.algorithm) {
        .philox => try philox.appendCandidates(backing_allocator, query, &result),
        .threefry => try threefry.appendCandidates(backing_allocator, query, &result),
        .squares => try squares.appendCandidates(backing_allocator, query, &result),
    }
    return result;
}

fn canonicalRandom(query: RandomQuery) bool {
    if (!random.randomDTypeSupported(query.dtype)) return false;
    if (query.count == 0) return false;
    const rounds = match_mod.randomEffectiveRounds(query);
    return switch (query.algorithm) {
        .philox => rounds >= 1 and rounds <= random.philox_max_rounds,
        .threefry => rounds >= 1 and rounds <= random.threefry_max_rounds,
        .squares => query.rounds == 0,
    };
}
