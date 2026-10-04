const std = @import("std");
const build_api = @import("../root.zig");
const validation = @import("../../validation/root.zig");
const source = @import("source.zig");

pub const Spec = validation.catalog.Spec;
pub const RecipeSpec = validation.catalog.RecipeSpec;
pub const Catalog = validation.catalog.Catalog;

comptime {
    std.debug.assert(std.mem.eql(
        u8,
        validation.catalog.cache_directory_argument,
        build_api.child_cache_directory_argument,
    ));
}

pub fn load(b: *std.Build, repository: []const u8, owner: []const u8) ?Catalog {
    std.debug.assert(repository.len != 0);
    std.debug.assert(owner.len != 0);
    var failure: validation.source.Failure = .{};
    const tree = source.tree(b, repository, &failure);
    return validation.catalog.package(b.allocator, tree, owner) catch |err| {
        std.debug.panic("validation declaration {s}: {s} at {s}", .{ owner, @errorName(err), failure.path() });
    };
}

/// Both package execution and catalog export derive the same recipe identity.
pub fn configure(b: *std.Build, repository: []const u8, spec: Spec) Catalog {
    std.debug.assert(repository.len != 0);
    var failure: validation.source.Failure = .{};
    const tree = source.tree(b, repository, &failure);
    return validation.catalog.configure(b.allocator, tree, spec) catch |err| {
        std.debug.panic("validation declaration {s}: {s} at {s}", .{ spec.owner, @errorName(err), failure.path() });
    };
}
