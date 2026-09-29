const std = @import("std");
const subject = @import("root.zig");

const Catalog = subject.Catalog;
const Format = subject.Format;
const RootSet = subject.RootSet;
const Stats = subject.Stats;
const fixture = subject.fixture;

const debug_io = std.Options.debug_io;
const storage_bytes = 64 * 16 + 32 * 24 + 8192;

const limits: Catalog.Limits = .{
    .entries = 64,
    .directories = 32,
    .path_bytes = 8192,
};

const Harness = struct {
    tmp: std.testing.TmpDir,
    layout: fixture.Layout,
    set: RootSet,
    storage: [storage_bytes]u8 align(Catalog.storage_alignment),
    path_buffer: [std.Io.Dir.max_path_bytes]u8,

    fn init(self: *Harness) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.layout = try fixture.create(debug_io, self.tmp.dir);
        const used = try self.tmp.dir.realPath(debug_io, &self.path_buffer);
        self.set = .{};
        try std.testing.expect(self.set.append(self.path_buffer[0..used]));
    }

    fn deinit(self: *Harness) void {
        fixture.release(debug_io, self.tmp.dir);
        self.tmp.cleanup();
    }

    fn walk(self: *Harness, catalog: *Catalog, depth_max: u8, stats: *Stats) !void {
        try subject.enumerate(debug_io, catalog, &self.set, .{ .depth_max = depth_max }, stats);
    }
};

fn find(catalog: *const Catalog, suffix: []const u8) ?subject.Entry {
    for (catalog.entries()) |entry| {
        if (std.mem.endsWith(u8, catalog.entryPath(entry), suffix)) return entry;
    }
    return null;
}

fn totalBytes(catalog: *const Catalog) u64 {
    var total: u64 = 0;
    for (catalog.entries()) |entry| total += entry.size_bytes;
    return total;
}

test "font enumeration admits every font below the depth bound" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var catalog = try Catalog.init(&harness.storage, limits);
    catalog.activate();
    defer _ = catalog.deinit();
    var stats: Stats = .{};
    try harness.walk(&catalog, fixture.visible_depth, &stats);

    try std.testing.expectEqual(harness.layout.fonts, catalog.entryCount());
    try std.testing.expectEqual(harness.layout.bytes, totalBytes(&catalog));
    try std.testing.expectEqual(@as(u32, 1), stats.roots_visited);
    try std.testing.expectEqual(@as(u32, 1), stats.directories_cycle_skipped);
    try std.testing.expectEqual(@as(u32, 1), stats.directories_depth_skipped);
    try std.testing.expectEqual(@as(u32, 0), stats.paths_too_long);
    const unreadable: u32 = if (harness.layout.locked_readable) 0 else 1;
    try std.testing.expectEqual(unreadable, stats.directories_unreadable);
    try std.testing.expectEqual(@as(?subject.Entry, null), find(&catalog, "/Notes.txt"));
    try std.testing.expectEqual(@as(?subject.Entry, null), find(&catalog, "/TooDeep.ttf"));
}

test "font enumeration reports format, size, and root for every admitted file" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var catalog = try Catalog.init(&harness.storage, limits);
    catalog.activate();
    defer _ = catalog.deinit();
    var stats: Stats = .{};
    try harness.walk(&catalog, fixture.visible_depth, &stats);

    const regular = find(&catalog, "/Regular.ttf").?;
    try std.testing.expectEqual(Format.truetype, regular.format);
    try std.testing.expectEqual(@as(u64, 64), regular.size_bytes);
    try std.testing.expectEqual(@as(u8, 0), regular.root);
    try std.testing.expectEqual(Format.opentype, find(&catalog, "/Italic.OTF").?.format);
    try std.testing.expectEqual(@as(u64, 64), find(&catalog, "/link.ttf").?.size_bytes);
    const bold = find(&catalog, "/nested/Bold.otf").?;
    try std.testing.expectEqual(@as(u64, 16), bold.size_bytes);
    const deep = find(&catalog, "/nested/deep/Deep.ttc").?;
    try std.testing.expectEqual(Format.truetype_collection, deep.format);
    try std.testing.expectEqual(Format.type1, find(&catalog, "/loop/Loop.pfb").?.format);
    try std.testing.expect(std.mem.startsWith(u8, catalog.entryPath(regular), "/"));
}

test "font enumeration at depth zero reads roots only" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var catalog = try Catalog.init(&harness.storage, limits);
    catalog.activate();
    defer _ = catalog.deinit();
    var stats: Stats = .{};
    try harness.walk(&catalog, 0, &stats);

    try std.testing.expectEqual(@as(u32, 3), catalog.entryCount());
    try std.testing.expectEqual(@as(u32, 3), stats.directories_depth_skipped);
    try std.testing.expectEqual(@as(u32, 0), stats.directories_cycle_skipped);
    try std.testing.expectEqual(@as(u32, 1), stats.directories_visited);
}

test "font enumeration rejects at the entry bound and keeps the accepted prefix" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var catalog = try Catalog.init(&harness.storage, .{
        .entries = 3,
        .directories = 32,
        .path_bytes = 8192,
    });
    catalog.activate();
    defer _ = catalog.deinit();
    var stats: Stats = .{};
    try std.testing.expectError(
        error.FontEntriesExhausted,
        harness.walk(&catalog, fixture.visible_depth, &stats),
    );
    try std.testing.expectEqual(@as(u32, 3), catalog.entryCount());
    for (catalog.entries()) |entry| {
        try std.testing.expect(Format.fromName(catalog.entryPath(entry)) != null);
    }
}

test "font enumeration rejects at the directory bound" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var catalog = try Catalog.init(&harness.storage, .{
        .entries = 64,
        .directories = 2,
        .path_bytes = 8192,
    });
    catalog.activate();
    defer _ = catalog.deinit();
    var stats: Stats = .{};
    try std.testing.expectError(
        error.FontDirectoriesExhausted,
        harness.walk(&catalog, fixture.visible_depth, &stats),
    );
    try std.testing.expectEqual(@as(u32, 2), catalog.directoryCount());
}

test "font enumeration over an unsupported platform walks nothing" {
    var set: RootSet = .{};
    const support = subject.rootsFor(&set, .windows, .{ .home = "C:/Users/u" });
    try std.testing.expectEqual(subject.Unsupported.platform, support.unsupported);
    var storage: [storage_bytes]u8 align(Catalog.storage_alignment) = undefined;
    var catalog = try Catalog.init(&storage, limits);
    catalog.activate();
    defer _ = catalog.deinit();
    var stats: Stats = .{};
    try subject.enumerate(debug_io, &catalog, &set, .{}, &stats);
    try std.testing.expectEqual(@as(u32, 0), catalog.entryCount());
    try std.testing.expectEqual(@as(u32, 0), stats.roots_visited);
    try std.testing.expectEqual(@as(u32, 0), stats.directories_visited);
}

test "host font enumeration terminates over the installed roots" {
    var set: RootSet = .{};
    const support = subject.defaultRoots(&set, subject.hostEnvironment());
    switch (support) {
        .unsupported => return error.SkipZigTest,
        .supported => |count| if (count == 0) return error.SkipZigTest,
    }
    const host_limits: Catalog.Limits = .{
        .entries = 16384,
        .directories = 8192,
        .path_bytes = 4 << 20,
    };
    const derived = try Catalog.Capacity.derive(host_limits);
    const storage = try std.testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(Catalog.storage_alignment),
        derived.storage_bytes,
    );
    defer std.testing.allocator.free(storage);
    var catalog = try Catalog.init(storage, host_limits);
    catalog.activate();
    defer _ = catalog.deinit();
    var stats: Stats = .{};
    subject.enumerate(debug_io, &catalog, &set, .{}, &stats) catch |err| switch (err) {
        error.Canceled => return err,
        else => return error.SkipZigTest,
    };
    if (stats.roots_visited == 0) return error.SkipZigTest;
    try std.testing.expectEqual(stats.roots_visited + stats.roots_missing, set.count);
    try std.testing.expect(stats.directories_visited >= stats.roots_visited);
    try std.testing.expect(catalog.pathBytesUsed() <= host_limits.path_bytes);
    for (catalog.entries()) |entry| {
        const path = catalog.entryPath(entry);
        try std.testing.expect(path.len != 0 and path[0] == '/');
        try std.testing.expectEqual(entry.format, Format.fromName(path).?);
    }
}
