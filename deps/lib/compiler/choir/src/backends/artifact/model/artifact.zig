const std = @import("std");
const artifact = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const Artifact = struct {
    allocator: Allocator,
    metadata: artifact.Metadata,
    options: artifact.Options,
    linkage: artifact.Linkage,
    payload: artifact.Payload,
    verification: artifact.VerificationStatus = .{},

    pub fn init(allocator: Allocator, metadata: artifact.Metadata) Allocator.Error!Artifact {
        return .{
            .allocator = allocator,
            .metadata = try metadata.dupe(allocator),
            .options = .init(allocator),
            .linkage = .init(allocator),
            .payload = .init(allocator),
        };
    }

    pub fn clone(self: Artifact, allocator: Allocator) Allocator.Error!Artifact {
        var copy = try Artifact.init(allocator, self.metadata);
        errdefer copy.deinit();
        try self.options.cloneInto(&copy.options);
        try self.linkage.cloneInto(&copy.linkage);
        try self.payload.cloneInto(&copy.payload);
        try copy.verification.replace(copy.allocator, self.verification);
        return copy;
    }

    pub fn eql(self: Artifact, other: Artifact) bool {
        return self.metadata.eql(other.metadata) and
            self.options.eql(other.options) and
            self.linkage.eql(other.linkage) and
            self.payload.eql(other.payload) and
            self.verification.eql(other.verification);
    }

    pub fn deinit(self: *Artifact) void {
        self.options.deinit();
        self.linkage.deinit();
        self.payload.deinit();
        self.verification.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
        self.* = undefined;
    }
};
