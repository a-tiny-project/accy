const std = @import("std");
const Allocator = std.mem.Allocator;
const artifact = @import("root.zig");
const slice = artifact.slice;

pub const VerificationState = enum(u8) {
    not_run = 1,
    passed = 2,
    failed = 3,
    skipped = 4,
};

pub const VerificationStatus = struct {
    state: VerificationState = .not_run,
    stage: ?[]const u8 = null,
    message: ?[]const u8 = null,

    pub fn dupe(self: VerificationStatus, allocator: Allocator) Allocator.Error!VerificationStatus {
        var out = VerificationStatus{ .state = self.state };
        errdefer out.deinit(allocator);
        out.stage = try slice.dupeOptional(allocator, self.stage);
        out.message = try slice.dupeOptional(allocator, self.message);
        return out;
    }

    pub fn deinit(self: *VerificationStatus, allocator: Allocator) void {
        slice.freeOptional(allocator, self.stage);
        slice.freeOptional(allocator, self.message);
        self.* = .{};
    }

    pub fn eql(self: VerificationStatus, other: VerificationStatus) bool {
        return self.state == other.state and
            slice.optionalEqual(self.stage, other.stage) and
            slice.optionalEqual(self.message, other.message);
    }

    pub fn replace(self: *VerificationStatus, allocator: Allocator, status: VerificationStatus) Allocator.Error!void {
        const owned = try status.dupe(allocator);
        self.deinit(allocator);
        self.* = owned;
    }
};
