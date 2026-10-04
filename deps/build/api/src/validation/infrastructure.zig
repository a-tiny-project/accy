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
    const catalog = validation.infrastructure.load(b.allocator, tree, package_roots) catch |err|
        refuse(err, &failure);
    // Only the root graph, which holds the whole tree, loads the infrastructure
    // owners. Its own root list must name only files it has. The shared capture
    // skips an absent root for an installed reader compiled from an older list.
    if (catalog) |loaded| {
        validation.source.require(b.allocator, tree, loaded.source_roots) catch |err|
            refuse(err, &failure);
    }
    return catalog;
}

fn refuse(err: anyerror, failure: *const validation.source.Failure) noreturn {
    std.debug.panic("infrastructure declaration: {s} at {s}", .{ @errorName(err), failure.path() });
}
