const std = @import("std");
const manifest = @import("root.zig");

/// Ceilings and defaults for one configure. `Walks.init` accepts no limit above
/// its ceiling, so these bound what a caller can make it allocate. The largest use over the root configure and the
/// gate's 13 Nix profiles is lib/research/chic: 158 roots, 1,233 directories, 8,827
/// remembered files and 173,768 walk bytes. Each default is over ten times that.
pub const maximum_roots: u32 = 4096;
pub const maximum_directories: u32 = 16384;
pub const maximum_remembered: u32 = 4 * manifest.model.maximum_entries;
pub const maximum_walk_bytes: u32 = 4 * 1024 * 1024;

/// Capacities of one configure's remembered walks. Callers size them, read
/// them back from `Walks.limits`, and compare them with `Walks.use`.
pub const Limits = struct {
    /// Distinct directories that compile units name as a source root.
    roots: u32 = maximum_roots,
    /// Distinct directories registered as configure dependencies.
    directories: u32 = maximum_directories,
    /// Files remembered across all roots.
    remembered: u32 = maximum_remembered,
    /// Working bytes of one walk, reused by every walk.
    walk_bytes: u32 = maximum_walk_bytes,
    /// Runs of one unit's file list, one per call that appends files.
    runs: u32 = maximum_runs,
};

pub const Limit = enum { roots, directories, remembered, walk_bytes };

/// The request that did not fit, kept for the refusal that names it.
pub const Overload = struct {
    limit: Limit,
    capacity: u64,
    used: u64,
    requested: u64,
};

pub const Use = struct {
    roots: u32,
    directories: u32,
    remembered: u32,
    walk_bytes: u32,
    walks: u32,
};

const Key = struct {
    owner: ?*std.Build,
    path: []const u8,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var hasher = std.hash.Wyhash.init(if (key.owner) |owner| @intFromPtr(owner) else 0);
        hasher.update(key.path);
        return hasher.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.owner == b.owner and std.mem.eql(u8, a.path, b.path);
    }
};

const Entry = struct {
    relative: []const u8,
    path: std.Build.LazyPath,
};

const Root = struct {
    owner: ?*std.Build,
    path: []const u8,
    base: std.Build.LazyPath,

    fn key(self: Root) Key {
        return .{ .owner = self.owner, .path = self.path };
    }
};

/// One configure's source enumeration. Each root is walked once and each
/// directory is registered once; every compile unit that names the root reads
/// the same sorted entries. A failed walk keeps only the directories it
/// registered before it failed, which `Limits.directories` bounds.
pub const Walks = struct {
    limits: Limits,
    roots: std.HashMapUnmanaged(Key, []const Entry, KeyContext, 80) = .empty,
    directories: std.HashMapUnmanaged(Key, void, KeyContext, 80) = .empty,
    scratch: []align(scratch_alignment.toByteUnits()) u8,
    remembered: u32 = 0,
    walk_bytes: u32 = 0,
    walks: u32 = 0,
    overload: ?Overload = null,

    pub fn init(arena: std.mem.Allocator, limits: Limits) !Walks {
        std.debug.assert(limits.roots <= maximum_roots);
        std.debug.assert(limits.directories <= maximum_directories);
        std.debug.assert(limits.remembered <= maximum_remembered);
        std.debug.assert(limits.walk_bytes <= maximum_walk_bytes);
        var self = Walks{ .limits = limits, .scratch = try arena.alignedAlloc(u8, scratch_alignment, limits.walk_bytes) };
        try self.roots.ensureTotalCapacityContext(arena, limits.roots, .{});
        try self.directories.ensureTotalCapacityContext(arena, limits.directories, .{});
        return self;
    }

    pub fn use(self: *const Walks) Use {
        return .{
            .roots = self.roots.count(),
            .directories = self.directories.count(),
            .remembered = self.remembered,
            .walk_bytes = self.walk_bytes,
            .walks = self.walks,
        };
    }

    fn capacity(self: *const Walks, limit: Limit) u32 {
        return switch (limit) {
            .roots => self.limits.roots,
            .directories => self.limits.directories,
            .remembered => self.limits.remembered,
            .walk_bytes => self.limits.walk_bytes,
        };
    }

    fn refuse(self: *Walks, limit: Limit, used: u64, requested: u64) Refusal {
        self.overload = .{
            .limit = limit,
            .capacity = self.capacity(limit),
            .used = used,
            .requested = requested,
        };
        return switch (limit) {
            .roots => error.CompilerSourceRootCountExceeded,
            .directories => error.CompilerSourceDirectoryCountExceeded,
            .remembered => error.CompilerRememberedSourceCountExceeded,
            .walk_bytes => error.CompilerSourceWalkBytesExceeded,
        };
    }

    fn register(self: *Walks, b: *std.Build, path: std.Build.LazyPath) void {
        std.debug.assert(self.directories.count() < self.limits.directories);
        b.dependOnDirectoryContents(path);
        self.directories.putAssumeCapacityNoClobberContext(directoryKey(path), {}, .{});
    }

    fn entries(self: *Walks, b: *std.Build, root: Root) ![]const Entry {
        std.debug.assert(self.roots.count() <= self.limits.roots);
        std.debug.assert(self.directories.count() <= self.limits.directories);
        std.debug.assert(self.remembered <= self.limits.remembered);
        if (self.roots.getContext(root.key(), .{})) |found| return found;
        if (self.roots.count() == self.limits.roots) {
            return self.refuse(.roots, self.roots.count(), 1);
        }
        if (!self.directories.containsContext(root.key(), .{})) {
            if (self.directories.count() == self.limits.directories) {
                return self.refuse(.directories, self.directories.count(), 1);
            }
            self.register(b, root.base);
        }
        var source = if (root.owner) |owner|
            try owner.root.openDir(b.graph.io, if (root.path.len == 0) "." else root.path, .{ .iterate = true })
        else
            try std.Io.Dir.cwd().openDir(b.graph.io, root.path, .{ .iterate = true });
        defer source.close(b.graph.io);

        var scratch = Scratch{ .buffer = self.scratch };
        const names = self.scan(b, &scratch, source, root) catch |err| switch (err) {
            error.OutOfMemory => return self.refuse(.walk_bytes, scratch.end, scratch.refused),
            else => return err,
        };
        std.debug.assert(scratch.end <= self.limits.walk_bytes);
        if (names.len > self.limits.remembered - self.remembered) {
            return self.refuse(.remembered, self.remembered, names.len);
        }
        std.mem.sort([]const u8, names, {}, lessName);

        const arena = b.graph.arena;
        const remembered = try arena.alloc(Entry, names.len);
        for (remembered, names) |*entry, name| {
            const path = root.base.path(b, name);
            const full = directoryKey(path).path;
            std.debug.assert(std.mem.endsWith(u8, full, name));
            entry.* = .{ .relative = full[full.len - name.len ..], .path = path };
        }
        self.roots.putAssumeCapacityNoClobberContext(
            .{ .owner = root.owner, .path = try arena.dupe(u8, root.path) },
            remembered,
            .{},
        );
        self.remembered += @intCast(names.len);
        self.walks += 1;
        return remembered;
    }

    /// Everything allocated here lives in the walk's scratch, so a walk that
    /// fails late leaves nothing behind but the directories it registered.
    fn scan(
        self: *Walks,
        b: *std.Build,
        scratch: *Scratch,
        source: std.Io.Dir,
        root: Root,
    ) ![][]const u8 {
        const allocator = scratch.allocator();
        var walker = try source.walk(allocator);
        defer walker.deinit();
        defer self.walk_bytes = @max(self.walk_bytes, @as(u32, @intCast(scratch.end)));
        var names: std.ArrayList([]const u8) = .empty;
        var visited: u32 = 0;
        while (try walker.next(b.graph.io)) |entry| {
            if (visited == manifest.model.maximum_entries) return error.CompilerInputCountExceeded;
            visited += 1;
            if (entry.kind == .directory) {
                const resolved = try std.fs.path.resolve(allocator, &.{ root.path, entry.path });
                if (self.directories.containsContext(.{ .owner = root.owner, .path = resolved }, .{})) continue;
                if (self.directories.count() == self.limits.directories) {
                    return self.refuse(.directories, self.directories.count(), 1);
                }
                const path = root.base.path(b, entry.path);
                std.debug.assert(std.mem.eql(u8, directoryKey(path).path, resolved));
                self.register(b, path);
                continue;
            }
            if (entry.kind != .file) return error.UnsupportedCompilerSource;
            try names.append(allocator, try allocator.dupe(u8, entry.path));
        }
        return names.items;
    }
};

/// Bump storage for one walk. Nothing is reclaimed before the walk ends, so
/// `end` is the walk's high-water mark and a refusal knows its request.
const scratch_alignment: std.mem.Alignment = .@"16";

const Scratch = struct {
    buffer: []align(scratch_alignment.toByteUnits()) u8,
    end: usize = 0,
    refused: usize = 0,

    fn allocator(self: *Scratch) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(context));
        // Offsets align within the buffer, so a walk's use does not depend on its address.
        std.debug.assert(alignment.compare(.lte, scratch_alignment));
        const start = alignment.forward(self.end);
        if (start > self.buffer.len or len > self.buffer.len - start) {
            self.refused = len;
            return null;
        }
        self.end = start + len;
        return self.buffer.ptr + start;
    }

    fn resize(context: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *Scratch = @ptrCast(@alignCast(context));
        if (new_len <= memory.len) return true;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(self.buffer.ptr);
        std.debug.assert(start + memory.len <= self.end);
        if (start + memory.len != self.end) return false;
        if (new_len > self.buffer.len - start) return false;
        self.end = start + new_len;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, address: usize) ?[*]u8 {
        return if (resize(context, memory, alignment, new_len, address)) memory.ptr else null;
    }

    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
};

const Refusal = error{
    CompilerSourceRootCountExceeded,
    CompilerSourceDirectoryCountExceeded,
    CompilerRememberedSourceCountExceeded,
    CompilerSourceWalkBytesExceeded,
};

/// The registered path itself is the key, so the configure dependencies are
/// the earlier list with its repeats dropped.
fn directoryKey(path: std.Build.LazyPath) Key {
    return switch (path) {
        .src_path => |source| .{ .owner = source.owner, .path = source.sub_path },
        .cwd_relative => |absolute| .{ .owner = null, .path = absolute },
        else => unreachable,
    };
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Enumerate source names during configuration; hashing remains a make-phase job.
/// Directory dependencies invalidate additions, removals and renames. Individual
/// LazyPath file inputs invalidate content edits without rerunning configuration.
pub fn collect(
    walks: *Walks,
    b: *std.Build,
    path: std.Build.LazyPath,
    name: []const u8,
    files: *std.ArrayList(manifest.File),
) !void {
    try manifest.model.validatePath(name);
    const root: Root = switch (path) {
        .src_path => |source| .{
            .owner = source.owner,
            .path = source.sub_path,
            .base = source.owner.path(source.sub_path),
        },
        .dependency => |source| .{
            .owner = source.dependency.builder,
            .path = source.sub_path,
            .base = source.dependency.builder.path(source.sub_path),
        },
        .cwd_relative => |absolute| if (std.fs.path.isAbsolute(absolute))
            .{ .owner = null, .path = absolute, .base = path }
        else
            return error.UnqualifiedCompilerSourceDirectory,
        else => return error.UnqualifiedCompilerSourceDirectory,
    };
    const entries = try walks.entries(b, root);
    std.debug.assert(files.items.len <= manifest.model.maximum_entries);
    if (entries.len > manifest.model.maximum_entries - files.items.len) {
        return error.CompilerInputCountExceeded;
    }
    for (entries) |entry| {
        try append(b, files, .{
            .identity = .{ .path = b.pathJoin(&.{ name, entry.relative }) },
            .path = entry.path,
        });
    }
}

pub fn append(b: *std.Build, files: *std.ArrayList(manifest.File), input: manifest.File) !void {
    if (files.items.len == manifest.model.maximum_entries) return error.CompilerInputCountExceeded;
    try files.append(b.graph.arena, input);
}

/// One more than a unit's references: qualification adds the captured
/// snapshot as one run beside the references it counts.
pub const maximum_runs: u32 = manifest.model.maximum_references + 1;

/// The files one call appended to a unit, as a stretch of the unit's list.
pub const Run = struct { start: u32, len: u32 };

/// The runs of one unit's file list in append order, in caller-owned storage.
pub const Runs = struct {
    storage: []Run,
    len: usize = 0,

    /// Claim the next descriptor before its files are appended.
    pub fn begin(self: *Runs, files: *const std.ArrayList(manifest.File)) !u32 {
        std.debug.assert(self.len <= self.storage.len);
        if (self.len == self.storage.len) return error.CompilerInputRunCountExceeded;
        return @intCast(files.items.len);
    }

    /// Record the files appended since `begin`. An empty run records nothing.
    pub fn end(self: *Runs, files: *const std.ArrayList(manifest.File), start: u32) void {
        std.debug.assert(self.len < self.storage.len);
        std.debug.assert(files.items.len >= start);
        if (files.items.len == start) return;
        self.storage[self.len] = .{ .start = start, .len = @intCast(files.items.len - start) };
        self.len += 1;
    }

    pub fn items(self: *Runs) []Run {
        return self.storage[0..self.len];
    }
};

/// How many units and files took each path through `merge`.
pub const Merged = struct {
    fast_units: u32 = 0,
    fast_files: u64 = 0,
    fallback_units: u32 = 0,
    fallback_files: u64 = 0,
};

/// Put one unit's files in the order `sort` gives them. `runs` partition
/// `files` in append order. When every run is sorted and the runs, ordered by
/// first identity, end strictly before the next begins, their concatenation is
/// that order: no identity repeats across runs, and a run keeps its own ties.
/// Any other shape takes `sort` over the untouched append order. `runs` is
/// reordered either way. `scratch` holds the unit's files during the copy.
pub fn merge(files: []manifest.File, runs: []Run, scratch: []manifest.File, merged: *Merged) void {
    std.debug.assert(files.len <= manifest.model.maximum_entries);
    std.debug.assert(files.len <= scratch.len);
    var next: usize = 0;
    for (runs) |run| {
        std.debug.assert(run.len != 0);
        std.debug.assert(run.start == next);
        next += run.len;
    }
    std.debug.assert(next == files.len);
    if (!separable(files, runs)) {
        sort(files);
        merged.fallback_units += 1;
        merged.fallback_files += files.len;
        return;
    }
    merged.fast_units += 1;
    merged.fast_files += files.len;
    var moved = false;
    var end: usize = 0;
    for (runs) |run| {
        if (run.start != end) moved = true;
        @memcpy(scratch[end..][0..run.len], files[run.start..][0..run.len]);
        end += run.len;
    }
    std.debug.assert(end == files.len);
    if (moved) @memcpy(files, scratch[0..files.len]);
}

/// Orders `runs` by first identity and reports whether each is sorted and
/// ends strictly before the next begins. `files` is only read.
fn separable(files: []const manifest.File, runs: []Run) bool {
    for (runs) |run| {
        const run_files = files[run.start..][0..run.len];
        for (run_files[0 .. run_files.len - 1], run_files[1..]) |earlier, later| {
            if (less({}, later, earlier)) return false;
        }
    }
    std.mem.sort(Run, runs, files, firstLess);
    if (runs.len == 0) return true;
    for (runs[0 .. runs.len - 1], runs[1..]) |earlier, later| {
        if (!less({}, files[earlier.start + earlier.len - 1], files[later.start])) return false;
    }
    return true;
}

fn firstLess(files: []const manifest.File, a: Run, b: Run) bool {
    return less({}, files[a.start], files[b.start]);
}

pub fn sort(files: []manifest.File) void {
    std.mem.sort(manifest.File, files, {}, less);
}

fn less(_: void, a: manifest.File, b: manifest.File) bool {
    return std.mem.lessThan(u8, a.identity.path, b.identity.path);
}
