const std = @import("std");
const validation = @import("../../validation/root.zig");
const declaration = @import("declaration.zig");
const source = @import("source.zig");

/// The catalog of the repository at `repository`. validation.catalog.load
/// owns the inventory rules, and the run-time loader shares them.
pub fn collect(b: *std.Build, repository: []const u8, tool_catalog: []const u8) declaration.Catalog {
    return collectSelected(b, repository, tool_catalog, null);
}

/// Build-surface tool seeds; whole-tree callers keep using collect.
pub fn collectSelected(
    b: *std.Build,
    repository: []const u8,
    tool_catalog: []const u8,
    selected_tool_roots: ?[]const []const u8,
) declaration.Catalog {
    std.debug.assert(repository.len != 0);
    var failure: validation.source.Failure = .{};
    const tree = source.tree(b, repository, &failure);
    return validation.catalog.loadSelected(
        b.allocator,
        tree,
        tool_catalog,
        selected_tool_roots,
    ) catch |err| {
        std.debug.panic("validation package inventory: {s} at {s}", .{ @errorName(err), failure.path() });
    };
}

pub fn load(
    b: *std.Build,
    repository: []const u8,
    tool_catalog: []const u8,
) !declaration.Catalog {
    std.debug.assert(repository.len != 0);
    var failure: validation.source.Failure = .{};
    return validation.catalog.load(b.allocator, source.tree(b, repository, &failure), tool_catalog);
}
