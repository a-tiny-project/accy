const entry = @import("../root.zig").entry;

pub const Descriptor = struct {
    name: []const u8,
    metadata: entry.Metadata,
};

pub const OwnedDescriptor = struct {
    descriptor: Descriptor,
    specialization: ?entry.OwnedSpecialization = null,

    pub fn deinit(self: *OwnedDescriptor) void {
        if (self.specialization) |*specialization| specialization.deinit();
        self.* = undefined;
    }
};
