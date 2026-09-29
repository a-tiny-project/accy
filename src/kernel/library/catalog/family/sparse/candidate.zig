const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const geometry = @import("../../../root.zig").geometry;

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;

pub const SparseCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const SparseCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *SparseCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn sparseCandidateTargetsContain(candidates: []const OwnedDescriptor, target: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.descriptor.metadata.target, target)) return true;
    }
    return false;
}
