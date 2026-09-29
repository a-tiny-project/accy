const std = @import("std");
const catalog_module = @import("catalog.zig");
const roots_module = @import("roots.zig");

const Catalog = catalog_module.Catalog;
const Format = catalog_module.Format;
const RootSet = roots_module.RootSet;

/// Hard ceiling of 16 levels on descent that caps two things: how many steps
/// the cycle guard climbs, and any `Options.depth_max` a caller sets for the
/// walk to assert against.
pub const depth_limit: u8 = 16;

/// Caps how many directory entries get read out of a single directory before
/// the walk moves on, so a caller reading statistics knows what one enormous
/// directory does to an enumeration in progress. A directory past this bound is
/// counted in `directories_truncated`, and the walk carries on with the next
/// one.
pub const entries_per_directory_max: u32 = 1 << 20;

/// The limits a caller sets on one walk.
pub const Options = struct {
    /// Sets how many levels beneath a root the walk goes, which a caller lowers
    /// to keep a walk shallow and cheap. The default is six, and zero reads the
    /// roots alone.
    depth_max: u8 = 6,
};

/// Provides a counter for each kind of thing the walk saw and passed over, so a
/// caller can tell a complete enumeration from one that skipped part of the
/// tree. Counters saturate at their maximum, so a reported maximum means at
/// least that many.
pub const Stats = struct {
    roots_visited: u32 = 0,
    roots_missing: u32 = 0,
    directories_visited: u32 = 0,
    directories_unreadable: u32 = 0,
    directories_depth_skipped: u32 = 0,
    directories_cycle_skipped: u32 = 0,
    directories_truncated: u32 = 0,
    files_seen: u32 = 0,
    files_unreadable: u32 = 0,
    paths_too_long: u32 = 0,
};

/// Combines the capacity refusals of the catalog with cancellation, so a caller
/// distinguishes a full catalog from a cancelled walk because nothing else
/// stops one. A cancellation from the io implementation travels out to the
/// caller.
pub const Error = Catalog.Exhaustion || error{Canceled};

/// Puts every font file found beneath the directories in `set` into `catalog`
/// and leaves an account of what it passed over in `stats`, so a caller can run
/// one enumeration and read the result out of its own catalog storage. The
/// roots are admitted first and the directories are then drained in admission
/// order, so the descent is breadth-first.
///
/// A directory that will not open, a file that disappears between the listing
/// and the stat, and a name too long for `std.Io.Dir.max_path_bytes` each add
/// to a counter and leave the walk running. Capacity refusal and cancellation
/// are the two things that stop the walk, and a refusal leaves the accepted
/// prefix in the catalog. The call overwrites `stats` at its start, and it
/// asserts an empty catalog and an `options.depth_max` within `depth_limit`.
pub fn enumerate(
    io: std.Io,
    catalog: *Catalog,
    set: *const RootSet,
    options: Options,
    stats: *Stats,
) Error!void {
    std.debug.assert(options.depth_max <= depth_limit);
    std.debug.assert(catalog.entryCount() == 0);
    std.debug.assert(catalog.directoryCount() == 0);
    stats.* = .{};
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (0..set.count) |index| {
        try admitRoot(io, catalog, set.path(@intCast(index)), @intCast(index), stats);
    }
    var drained: u32 = 0;
    while (catalog.takeDirectory()) |index| {
        std.debug.assert(drained < catalog.directoryCount());
        std.debug.assert(index == drained);
        drained += 1;
        try readDirectory(io, catalog, index, options, &path_buffer, stats);
    }
    std.debug.assert(drained == catalog.directoryCount());
    std.debug.assert(stats.roots_visited <= set.count);
}

fn admitRoot(
    io: std.Io,
    catalog: *Catalog,
    root_path: []const u8,
    root: u8,
    stats: *Stats,
) Error!void {
    std.debug.assert(root_path.len != 0);
    std.debug.assert(std.fs.path.isAbsolute(root_path));
    const stat = std.Io.Dir.cwd().statFile(io, root_path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            stats.roots_missing +|= 1;
            return;
        },
    };
    if (stat.kind != .directory) {
        stats.roots_missing +|= 1;
        return;
    }
    _ = try catalog.appendRoot(root_path, stat.inode, root);
    stats.roots_visited +|= 1;
}

fn readDirectory(
    io: std.Io,
    catalog: *Catalog,
    index: u32,
    options: Options,
    path_buffer: []u8,
    stats: *Stats,
) Error!void {
    const record = catalog.directoryAt(index);
    std.debug.assert(record.depth <= options.depth_max);
    const directory_path = catalog.directoryPath(record);
    std.debug.assert(directory_path.len != 0);
    std.debug.assert(path_buffer.len == std.Io.Dir.max_path_bytes);
    var directory = std.Io.Dir.openDirAbsolute(io, directory_path, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            stats.directories_unreadable +|= 1;
            return;
        },
    };
    defer directory.close(io);
    stats.directories_visited +|= 1;
    var iterator = directory.iterate();
    var seen: u32 = 0;
    while (seen < entries_per_directory_max) : (seen += 1) {
        const entry = iterator.next(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                stats.directories_unreadable +|= 1;
                return;
            },
        } orelse return;
        const child = join(path_buffer, directory_path, entry.name) orelse {
            stats.paths_too_long +|= 1;
            continue;
        };
        try admitChild(io, catalog, directory, index, entry, child, options, stats);
    }
    stats.directories_truncated +|= 1;
}

fn admitChild(
    io: std.Io,
    catalog: *Catalog,
    directory: std.Io.Dir,
    parent: u32,
    entry: std.Io.Dir.Entry,
    child_path: []const u8,
    options: Options,
    stats: *Stats,
) Error!void {
    const record = catalog.directoryAt(parent);
    std.debug.assert(entry.name.len != 0);
    std.debug.assert(child_path.len > entry.name.len);
    switch (entry.kind) {
        .directory => try admitDirectory(
            catalog,
            parent,
            entry.inode,
            child_path,
            options,
            stats,
        ),
        .file => try admitFile(io, catalog, directory, entry.name, child_path, record.root, stats),
        .sym_link, .unknown => {
            const stat = directory.statFile(io, entry.name, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    stats.files_unreadable +|= 1;
                    return;
                },
            };
            switch (stat.kind) {
                .directory => try admitDirectory(
                    catalog,
                    parent,
                    stat.inode,
                    child_path,
                    options,
                    stats,
                ),
                .file => try admitStatted(
                    catalog,
                    entry.name,
                    child_path,
                    stat,
                    record.root,
                    stats,
                ),
                else => {},
            }
        },
        else => {},
    }
}

fn admitDirectory(
    catalog: *Catalog,
    parent: u32,
    inode: u64,
    child_path: []const u8,
    options: Options,
    stats: *Stats,
) Error!void {
    const record = catalog.directoryAt(parent);
    std.debug.assert(options.depth_max <= depth_limit);
    std.debug.assert(record.depth <= options.depth_max);
    if (record.depth == options.depth_max) {
        stats.directories_depth_skipped +|= 1;
        return;
    }
    if (ancestorHolds(catalog, parent, inode)) {
        stats.directories_cycle_skipped +|= 1;
        return;
    }
    _ = try catalog.appendDirectory(
        child_path,
        inode,
        parent,
        record.depth + 1,
        record.root,
    );
}

fn admitFile(
    io: std.Io,
    catalog: *Catalog,
    directory: std.Io.Dir,
    name: []const u8,
    child_path: []const u8,
    root: u8,
    stats: *Stats,
) Error!void {
    std.debug.assert(name.len != 0);
    std.debug.assert(std.mem.endsWith(u8, child_path, name));
    stats.files_seen +|= 1;
    const format = Format.fromName(name) orelse return;
    const stat = directory.statFile(io, name, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            stats.files_unreadable +|= 1;
            return;
        },
    };
    if (stat.kind != .file) return;
    try catalog.appendEntry(child_path, stat.size, format, root);
}

fn admitStatted(
    catalog: *Catalog,
    name: []const u8,
    child_path: []const u8,
    stat: std.Io.File.Stat,
    root: u8,
    stats: *Stats,
) Error!void {
    std.debug.assert(name.len != 0);
    std.debug.assert(stat.kind == .file);
    stats.files_seen +|= 1;
    const format = Format.fromName(name) orelse return;
    try catalog.appendEntry(child_path, stat.size, format, root);
}

fn ancestorHolds(catalog: *const Catalog, from: u32, inode: u64) bool {
    std.debug.assert(from < catalog.directoryCount());
    var index = from;
    var steps: u8 = 0;
    while (steps <= depth_limit) : (steps += 1) {
        const record = catalog.directoryAt(index);
        std.debug.assert(record.parent <= index);
        if (record.inode == inode) return true;
        if (record.parent == index) return false;
        index = record.parent;
    }
    return false;
}

fn join(buffer: []u8, parent: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(parent.len != 0);
    std.debug.assert(name.len != 0);
    const total = parent.len + 1 + name.len;
    if (total > buffer.len) return null;
    @memcpy(buffer[0..parent.len], parent);
    buffer[parent.len] = '/';
    @memcpy(buffer[parent.len + 1 ..][0..name.len], name);
    std.debug.assert(buffer[parent.len] == '/');
    return buffer[0..total];
}
