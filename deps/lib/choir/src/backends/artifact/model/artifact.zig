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

test "artifact owns provided symbol names" {
    var value = try Artifact.init(std.testing.allocator, .{
        .kind = .container,
        .producer = "test",
    });
    defer value.deinit();

    var name = [_]u8{ 'e', 'n', 't', 'r', 'y' };
    try value.linkage.addProvided(.{ .name = &name, .kind = .function });
    name[0] = 'x';

    try std.testing.expectEqualStrings("entry", value.linkage.provided_symbols.items[0].name);
    try std.testing.expect(value.linkage.hasProvided("entry"));
}

test "artifact clone survives every allocation failure" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            var value = try Artifact.init(allocator, .{
                .kind = .object_file,
                .producer = "allocation",
                .target = .{ .architecture = .x86_64, .triple = "x86_64-linux", .features = &.{"sse2"} },
                .abi = .{ .name = "sysv", .calling_convention = "c", .object_format = "elf" },
            });
            defer value.deinit();
            try value.options.add(.{ .key = "opt", .value = .{ .text = "speed" } });
            try value.linkage.addRequired(.{ .name = "runtime", .kind = .runtime });
            try value.linkage.addProvided(.{ .name = "entry", .kind = .function });
            try value.linkage.addRelocation(.{ .offset = 0, .symbol = "runtime" });
            try value.payload.addDebugRecord(.{ .name = "lines", .kind = .line_table, .bytes = &.{1} });
            try value.payload.addBuffer(.{ .name = "entry.o", .format = .object_file, .bytes = &.{2} });
            try value.payload.addTextDump(.{ .name = "ir", .contents = "entry" });
            try value.verification.replace(value.allocator, .{ .state = .passed, .stage = "verify", .message = "ok" });

            var copy = try value.clone(allocator);
            defer copy.deinit();
            try std.testing.expect(copy.linkage.hasProvided("entry"));
            try std.testing.expectEqualStrings("verify", copy.verification.stage.?);
            try std.testing.expect(value.eql(copy));
            copy.metadata.kind = .container;
            try std.testing.expect(!value.eql(copy));
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
