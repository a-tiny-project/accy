const std = @import("std");
const validation = @import("../../validation/root.zig");
const source = @import("source.zig");

pub const declaration_path = validation.infrastructure.declaration_path;
pub const OwnerSpec = validation.infrastructure.OwnerSpec;
pub const DependencySource = validation.infrastructure.DependencySource;
pub const Catalog = validation.infrastructure.Catalog;
pub const validateRoots = validation.infrastructure.validateRoots;

pub fn load(
    b: *std.Build,
    repository: []const u8,
    package_roots: []const validation.plan.Owner,
) ?Catalog {
    std.debug.assert(repository.len != 0);
    var failure: validation.source.Failure = .{};
    const tree = source.tree(b, repository, &failure);
    return validation.infrastructure.load(b.allocator, tree, package_roots) catch |err| {
        std.debug.panic("infrastructure declaration: {s} at {s}", .{ @errorName(err), failure.path() });
    };
}
