const std = @import("std");
const validation = @import("../../validation/root.zig");
const launcher = @import("../invocation/root.zig");
const membership_file = launcher.membership;

/// The repository at `repository` from this build's root, as the loader reads
/// it. Every file and directory a load reads becomes a configure input.
pub fn tree(
    b: *std.Build,
    repository: []const u8,
    failure: *validation.source.Failure,
) validation.source.Tree {
    std.debug.assert(repository.len != 0);
    const cwd = std.process.currentPathAlloc(b.graph.io, b.allocator) catch @panic("OOM");
    const relative = b.root.joinString(b.allocator, repository) catch @panic("OOM");
    const root = std.fs.path.resolve(b.allocator, &.{ cwd, relative }) catch @panic("OOM");
    std.debug.assert(std.fs.path.isAbsolute(root));
    var checkout: validation.source.Tree = .{
        .io = b.graph.io,
        .root = root,
        .observer = .{ .context = b, .file = dependOnFile, .directory = dependOnDirectory },
        .failure = failure,
    };
    checkout.inventory = membership(b, checkout) catch |err|
        std.debug.panic("validation source membership: {s}", .{@errorName(err)});
    return checkout;
}

/// Each root owns one immutable inventory artifact, which a launcher's
/// membership may already have supplied. Hash and observer caches remain
/// local to each capture.
fn membership(
    b: *std.Build,
    checkout: validation.source.Tree,
) !?[]const u8 {
    const owner = launcher.configuration.membershipOwner(b);
    const key = launcher.configuration.membershipKey(b, checkout.root);
    const files = owner.named_writefiles.get(key) orelse create: {
        const bytes =
            (try validation.source.inventoryBytes(b.graph.arena, checkout)) orelse return null;
        // Git index and external ignore configuration are process inputs. The
        // request lets the launcher name them in an option for later builds.
        // It is written first, so a build that refuses poison fails only once.
        requestMembership(b, checkout.root);
        b.graph.poisonCache();
        const created = owner.addNamedWriteFiles(key);
        _ = created.add("membership", bytes);
        break :create created;
    };
    std.debug.assert(files.embeds.items.len == 1);
    const contents = files.embeds.items[0].contents;
    return b.graph.wip_configuration.string_bytes.items[contents.index..][0..contents.len];
}

/// The configuration that writes this poisons itself next, so the write is
/// never cached. A failed request only leaves later builds poisoned too.
fn requestMembership(b: *std.Build, root: []const u8) void {
    const cwd = std.process.currentPathAlloc(b.graph.io, b.allocator) catch return;
    membership_file.request(b.graph.io, cwd, root) catch {};
}

pub fn capture(
    b: *std.Build,
    repository: []const u8,
    paths: []const []const u8,
) []const validation.Source {
    var failure: validation.source.Failure = .{};
    const checkout = tree(b, repository, &failure);
    return validation.source.capture(b.allocator, checkout, paths) catch |err| {
        std.debug.panic("validation framework source {s}: {s}", .{
            failure.path(),
            @errorName(err),
        });
    };
}

fn dependOnFile(context: *anyopaque, path: []const u8) void {
    const b: *std.Build = @ptrCast(@alignCast(context));
    b.dependOnFileContents(b.graph.cwdRelativePath(path));
}

fn dependOnDirectory(context: *anyopaque, path: []const u8) void {
    const b: *std.Build = @ptrCast(@alignCast(context));
    b.dependOnDirectoryContents(b.graph.cwdRelativePath(path));
}
