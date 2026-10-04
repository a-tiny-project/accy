const std = @import("std");

pub fn register(
    b: *std.Build,
    enabled: *std.Build.Module,
    disabled: *std.Build.Module,
    filters: []const []const u8,
) void {
    const parent = b.step("test", "Run allocator observer tests");
    inline for (.{
        .{ "alloc-observe-enabled-tests", enabled },
        .{ "alloc-observe-disabled-tests", disabled },
    }) |entry| {
        const artifact = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .filters = filters,
        });
        parent.dependOn(&b.addRunArtifact(artifact).step);
    }
}
