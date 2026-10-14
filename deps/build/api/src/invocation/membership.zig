//! The repository membership validation reads: tracked paths and the untracked
//! paths Git does not ignore, sorted, each NUL-terminated. Its inputs are the
//! index, ignore rules and directory listings, which Zig's configuration cache
//! cannot track. A launcher derives it, stores it under its digest, and names
//! the file in a `-D` option, which the cache does key on.
//!
//! Deriving it walks the worktree, 50 to 90 ms, nearly all of it Git's search
//! for untracked files. A launcher does so only where a configuration asked:
//! the configuration that reads membership without the option leaves a request
//! in its working directory, naming the checkout.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const option = "tiny-membership";
pub const schema = "tiny.membership/v1";
/// Below the working directory of the build that reads membership.
pub const directory = ".zig-cache/tiny/membership";
/// The request file inside `directory`; it holds the checkout root.
pub const request_name = "request";
const root_bytes_max = 4096;
pub const bytes_max = 32 * 1024 * 1024;
pub const entries_max = 32 * 1024;
/// Each distinct membership leaves one file of about a megabyte at today's
/// 21,000 paths. Publication evicts the oldest beyond this count.
pub const retained_max = 16;
pub const Digest = [Sha256.digest_length * 2]u8;

/// The Git query validation runs for a whole checkout.
pub fn arguments(root: []const u8) [10][]const u8 {
    std.debug.assert(std.fs.path.isAbsolute(root));
    return .{
        "git",                "-C", root, "ls-files", "-z", "--cached", "--others",
        "--exclude-standard", "--", ".",
    };
}

/// Sorts Git's NUL-separated output into the canonical form.
pub fn canonical(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len > bytes_max) return error.MembershipTooLarge;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var entries = std.mem.splitScalar(u8, raw, 0);
    while (entries.next()) |path| {
        if (path.len == 0) continue;
        if (paths.items.len == entries_max) return error.MembershipEntryLimit;
        try paths.append(allocator, path);
    }
    std.mem.sortUnstable([]const u8, paths.items, {}, less);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.ensureTotalCapacityPrecise(allocator, raw.len + 1);
    for (paths.items) |path| {
        bytes.appendSliceAssumeCapacity(path);
        bytes.appendAssumeCapacity(0);
    }
    return bytes.toOwnedSlice(allocator);
}

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Refuses bytes that are not sorted NUL-terminated paths, since validation
/// searches them as sorted records. Git lists an unmerged path once per stage.
pub fn check(bytes: []const u8) !void {
    if (bytes.len > bytes_max) return error.MembershipTooLarge;
    if (bytes.len != 0 and bytes[bytes.len - 1] != 0) return error.MembershipNotCanonical;
    var previous: ?[]const u8 = null;
    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, bytes, 0);
    while (entries.next()) |path| {
        if (entries.index == null) break;
        if (path.len == 0) return error.MembershipNotCanonical;
        if (previous) |before| {
            if (std.mem.lessThan(u8, path, before)) return error.MembershipNotCanonical;
        }
        count += 1;
        if (count > entries_max) return error.MembershipEntryLimit;
        previous = path;
    }
}

pub const Membership = struct {
    root: []const u8,
    paths: []const u8,
};

/// The stored form names its checkout, so a configure for another root never
/// reads it as its own. The writer proves the order once; a reader holds the
/// same bytes, by their digest.
pub fn encode(allocator: std.mem.Allocator, membership: Membership) ![]u8 {
    try checkRoot(membership.root);
    try check(membership.paths);
    return std.mem.concat(allocator, u8, &.{
        schema, "\n", membership.root, "\n", membership.paths,
    });
}

pub fn decode(bytes: []const u8) !Membership {
    const header_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse
        return error.MembershipNotCanonical;
    if (!std.mem.eql(u8, bytes[0..header_end], schema)) return error.MembershipNotCanonical;
    const rest = bytes[header_end + 1 ..];
    const root_end = std.mem.indexOfScalar(u8, rest, '\n') orelse
        return error.MembershipNotCanonical;
    const decoded = Membership{ .root = rest[0..root_end], .paths = rest[root_end + 1 ..] };
    try checkRoot(decoded.root);
    // Walking the order again would cost a Debug configurer about 10 ms.
    const paths = decoded.paths;
    if (paths.len != 0 and paths[paths.len - 1] != 0) return error.MembershipNotCanonical;
    return decoded;
}

fn checkRoot(root: []const u8) !void {
    if (root.len == 0 or root.len > root_bytes_max) return error.MembershipRootUnnamed;
    if (!std.fs.path.isAbsolute(root)) return error.MembershipRootUnnamed;
    if (std.mem.indexOfScalar(u8, root, '\n') != null) return error.MembershipRootUnnamed;
}

pub fn digest(bytes: []const u8) Digest {
    var raw: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

/// Stores encoded membership in `store` under its digest. A file already there
/// has the same bytes; its time is refreshed so eviction keeps what a launch
/// is about to name. The oldest files beyond `retained_max` are removed.
pub fn publish(io: std.Io, store: std.Io.Dir, encoded: []const u8) !Digest {
    const name = digest(encoded);
    if (store.access(io, &name, .{})) |_| {
        try store.setTimestampsNow(io, &name, .{});
    } else |err| switch (err) {
        error.FileNotFound => {
            var atomic = try store.createFileAtomic(io, &name, .{ .replace = true });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, encoded);
            try atomic.replace(io);
        },
        else => |e| return e,
    }
    try evict(io, store, &name);
    return name;
}

const Retained = struct { name: Digest, modified: std.Io.Timestamp };

fn evict(io: std.Io, store: std.Io.Dir, kept: *const Digest) !void {
    // Besides the kept file, the newest `retained_max - 1` others survive.
    var retained: [retained_max - 1]Retained = undefined;
    var count: usize = 0;
    var iterator = store.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len != @sizeOf(Digest)) continue;
        if (std.mem.eql(u8, entry.name, kept)) continue;
        const status = store.statFile(io, entry.name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        var candidate = Retained{ .name = undefined, .modified = status.mtime };
        @memcpy(&candidate.name, entry.name);
        if (count < retained.len) {
            retained[count] = candidate;
            count += 1;
            continue;
        }
        const oldest = oldestIndex(&retained);
        if (candidate.modified.nanoseconds > retained[oldest].modified.nanoseconds) {
            try remove(io, store, &retained[oldest].name);
            retained[oldest] = candidate;
        } else {
            try remove(io, store, &candidate.name);
        }
    }
    std.debug.assert(count + 1 <= retained_max);
}

fn oldestIndex(items: []const Retained) usize {
    std.debug.assert(items.len != 0);
    var oldest: usize = 0;
    for (items[1..], 1..) |item, index| {
        if (item.modified.nanoseconds < items[oldest].modified.nanoseconds) oldest = index;
    }
    return oldest;
}

fn remove(io: std.Io, store: std.Io.Dir, name: []const u8) !void {
    store.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

/// Reads a membership a launcher named by path. The file's name must be the
/// digest of its bytes.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Membership {
    const name = std.fs.path.basename(path);
    if (name.len != @sizeOf(Digest)) return error.MembershipUnnamed;
    const limit: std.Io.Limit = .limited(bytes_max + 4096);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
    const actual = digest(bytes);
    if (!std.mem.eql(u8, &actual, name)) return error.MembershipDigestMismatch;
    return decode(bytes);
}

/// Whether a launcher in `working_directory` derives membership of `root`:
/// only for the checkout it builds in.
pub fn contains(root: []const u8, working_directory: []const u8) bool {
    if (!std.mem.startsWith(u8, working_directory, root)) return false;
    const rest = working_directory[root.len..];
    return rest.len == 0 or rest[0] == '/' or std.mem.endsWith(u8, root, "/");
}

/// Asks the launcher of later builds in `working_directory` to derive the
/// membership of `root`. A request already naming `root` is left untouched,
/// and none is made for a checkout outside the working directory.
pub fn request(io: std.Io, working_directory: []const u8, root: []const u8) !void {
    try checkRoot(root);
    if (!contains(root, working_directory)) return;
    var cwd = try std.Io.Dir.openDirAbsolute(io, working_directory, .{});
    defer cwd.close(io);
    try cwd.createDirPath(io, directory);
    var store = try cwd.openDir(io, directory, .{});
    defer store.close(io);
    var existing: [root_bytes_max]u8 = undefined;
    if (store.readFile(io, request_name, &existing)) |named| {
        if (std.mem.eql(u8, named, root)) return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    var atomic = try store.createFileAtomic(io, request_name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, root);
    try atomic.replace(io);
}

/// The launcher's half: when a build in `working_directory` requested it,
/// derives the membership with the build's environment, publishes it, and
/// returns the stored file's absolute path. Null means no request.
pub fn derive(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    working_directory: []const u8,
) !?[]u8 {
    std.debug.assert(std.fs.path.isAbsolute(working_directory));
    var cwd = try std.Io.Dir.openDirAbsolute(io, working_directory, .{});
    defer cwd.close(io);
    var store = cwd.openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer store.close(io);
    var root_storage: [root_bytes_max]u8 = undefined;
    const root = store.readFile(io, request_name, &root_storage) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    try checkRoot(root);
    if (!contains(root, working_directory)) return error.MembershipRootUnnamed;
    const argv = arguments(root);
    const listed = try std.process.run(allocator, io, .{
        .argv = &argv,
        .environ_map = environment,
        .stdout_limit = .limited(bytes_max),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(listed.stdout);
    defer allocator.free(listed.stderr);
    switch (listed.term) {
        .exited => |status| if (status != 0) return error.MembershipQueryFailed,
        else => return error.MembershipQueryFailed,
    }
    const paths = try canonical(allocator, listed.stdout);
    defer allocator.free(paths);
    const encoded = try encode(allocator, .{ .root = root, .paths = paths });
    defer allocator.free(encoded);
    const name = try publish(io, store, encoded);
    return try std.fs.path.join(allocator, &.{ working_directory, directory, &name });
}
