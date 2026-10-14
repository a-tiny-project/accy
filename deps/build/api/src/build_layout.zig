const std = @import("std");

pub const BuildLayout = struct {
    local_cache_dir: std.Build.LazyPath,
    install_prefix: std.Build.LazyPath,

    pub fn init(b: *std.Build) BuildLayout {
        return .{
            .local_cache_dir = std.Build.LazyPath.cache_root,
            .install_prefix = b.graph.path(.install_prefix, ""),
        };
    }

    pub fn scoped(self: BuildLayout, b: *std.Build, scope: []const u8) BuildLayout {
        return .{
            .local_cache_dir = self.local_cache_dir.path(b, b.pathJoin(&.{ "children", scope })),
            .install_prefix = self.install_prefix.path(b, scope),
        };
    }

    pub fn package(self: BuildLayout, b: *std.Build, scope: []const u8) BuildLayout {
        const cache_path = b.root.joinString(
            b.allocator,
            b.pathJoin(&.{ scope, ".zig-cache" }),
        ) catch @panic("out of memory");
        return .{
            .local_cache_dir = .{ .cwd_relative = cache_path },
            .install_prefix = self.install_prefix.path(b, scope),
        };
    }

    pub fn artifactPath(self: BuildLayout, b: *std.Build, relative_path: []const u8) std.Build.LazyPath {
        return self.install_prefix.path(b, relative_path);
    }
};
