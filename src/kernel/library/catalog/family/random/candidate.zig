const descriptor_mod = @import("../../root.zig");
const geometry = @import("../../../root.zig").geometry;

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;

pub const RandomCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const RandomCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *RandomCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};
