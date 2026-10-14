const std = @import("std");
const invocation = @import("root.zig");

/// Every root build declares the launcher's options through the shared
/// registration, so a launch that passes them never meets an unknown option.
pub fn declare(b: *std.Build) void {
    std.debug.assert(b.isRoot());
    _ = b.option(
        []const u8,
        invocation.record.option,
        "SHA-256 of the compiler invocation record the launcher exported",
    );
    _ = b.option(
        []const u8,
        invocation.membership.option,
        "Repository membership the launcher stored under its digest",
    );
}

/// The configuration cache keys on the record digest the launcher passes, so a
/// cached graph built from one record never answers for another, and a raw
/// build, which passes none, never inherits a qualified graph. A digest whose
/// record is absent, or names other bytes, is a confused launch and fails. A
/// record this configure cannot qualify, such as one a bootstrap compiler
/// outside its binding runs, configures unqualified: publication is
/// withheld, and Zig is never blocked.
pub fn observe(b: *std.Build) !?invocation.Record {
    std.debug.assert(b.isRoot());
    std.debug.assert(b.available_options_map.contains(invocation.record.option));
    switch (b.graph.cache_poison) {
        .ignored, .disallowed => return null,
        .pure, .poisoned => {},
    }
    const named = b.user_input_options.get(invocation.record.option) orelse return null;
    const expected = switch (named) {
        .scalar => |text| text,
        else => return error.CompilerInvocationDigestInvalid,
    };
    const bytes = b.graph.environ_map.get(invocation.variable) orelse
        return error.CompilerInvocationMissing;
    const actual = invocation.record.digest(bytes);
    if (!std.mem.eql(u8, &actual, expected)) return error.CompilerInvocationDigestMismatch;
    const allocator = b.graph.arena;
    const directory = try std.process.currentPathAlloc(b.graph.io, allocator);
    const root = try b.root.joinString(allocator, "");
    const absolute_root = try std.fs.path.resolve(allocator, &.{ directory, root });
    const build_file = try std.fs.path.join(allocator, &.{ absolute_root, "build.zig" });
    return invocation.receive(allocator, &b.graph.environ_map, .{
        .compiler = b.graph.zig_exe,
        .directory = directory,
        .build_file = build_file,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
}

/// Takes the membership a launcher derived and named in the root's option.
/// The option keys the configuration cache and the file's name is its digest,
/// so validation loaders in every package read it without poisoning. A file
/// that is gone or malformed is passed over, and loaders derive it themselves.
pub fn adopt(b: *std.Build) void {
    std.debug.assert(b.isRoot());
    std.debug.assert(b.available_options_map.contains(invocation.membership.option));
    const named = b.user_input_options.get(invocation.membership.option) orelse return;
    const path = switch (named) {
        .scalar => |text| text,
        else => return,
    };
    const loaded = invocation.membership.load(b.graph.arena, b.graph.io, path) catch return;
    const owner = membershipOwner(b);
    const key = membershipKey(b, loaded.root);
    if (owner.named_writefiles.contains(key)) return;
    const created = owner.addNamedWriteFiles(key);
    _ = created.add("membership", loaded.paths);
}

/// The first generated file anchors one Build owner for this graph, as it does
/// for the compiler-binding registry, so loaders in every package find the
/// membership one root holds.
pub fn membershipOwner(b: *std.Build) *std.Build {
    return if (b.graph.generated_files.items.len == 0)
        b
    else
        b.graph.generated_files.items[0].owner;
}

pub fn membershipKey(b: *std.Build, root: []const u8) []const u8 {
    return b.fmt("tiny.validation-source-membership/v1/{s}", .{root});
}
