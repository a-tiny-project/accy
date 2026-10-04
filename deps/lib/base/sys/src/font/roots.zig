const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../root.zig");

const env = sys.env;

const native_os = builtin.os.tag;

/// The largest number of roots a root set retains, at 24. Past it the set
/// refuses roots and counts them in `dropped`.
pub const roots_max: u8 = 24;

/// The largest total byte count a root set retains for its root paths, at 4096.
/// Past it the set refuses roots and counts them in `dropped`.
pub const root_bytes_max: usize = 4096;

/// The reason a platform reports no font roots, read by a caller that got none.
pub const Unsupported = enum {
    /// `lib/base/sys` carries no list of font directories for this operating system.
    platform,
};

/// The outcome of resolving the platform's default roots, either the count of
/// roots written or the reason none were, so a caller can tell an empty
/// platform from an empty search.
pub const Support = union(enum) {
    supported: u8,
    unsupported: Unsupported,
};

/// Holds the three environment values that shape the Linux list: `HOME`,
/// `XDG_DATA_HOME`, and `XDG_DATA_DIRS`. A program fills it from the running
/// process with `hostEnvironment`, while a test fills it with literals so the
/// search order can be checked on any machine without touching the process
/// environment.
pub const Environment = struct {
    home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_data_dirs: ?[]const u8 = null,
};

const Span = struct {
    offset: u16,
    len: u16,
};

/// Keeps a list of absolute font directories in inline storage, ordered as the
/// search visits them, which a caller holds across a resolve and a walk with no
/// allocation anywhere in between. Once either bound is reached the set refuses
/// the next directory and adds one to `dropped`, which leaves a caller whose
/// machine lists more directories than the bound with the prefix that fits and
/// a count of what fell away.
pub const RootSet = struct {
    bytes: [root_bytes_max]u8 = undefined,
    spans: [roots_max]Span = @splat(.{ .offset = 0, .len = 0 }),
    count: u8 = 0,
    dropped: u16 = 0,
    used: u16 = 0,

    pub fn clear(self: *RootSet) void {
        self.count = 0;
        self.dropped = 0;
        self.used = 0;
    }

    pub fn path(self: *const RootSet, index: u8) []const u8 {
        std.debug.assert(index < self.count);
        const span = self.spans[index];
        std.debug.assert(span.len != 0);
        std.debug.assert(span.offset + span.len <= self.used);
        return self.bytes[span.offset..][0..span.len];
    }

    /// Adds `directory` to the end of the list, when the path is absolute, the
    /// list lacks it, and the bytes fit, and reports whether it went in. A
    /// caller uses it to add a root of its own to the platform's list. Trailing
    /// separators are trimmed before the comparison and the copy, while a
    /// relative, empty, or duplicate path returns false and leaves `dropped`
    /// alone so `dropped` counts capacity refusals only.
    pub fn append(self: *RootSet, directory: []const u8) bool {
        const trimmed = sys.path.trimTrailingSeparators(directory);
        if (trimmed.len == 0 or !sys.path.isAbsolute(trimmed)) return false;
        for (0..self.count) |index| {
            if (std.mem.eql(u8, self.path(@intCast(index)), trimmed)) return false;
        }
        if (self.count == roots_max or trimmed.len > root_bytes_max - self.used) {
            self.dropped +|= 1;
            return false;
        }
        const offset = self.used;
        @memcpy(self.bytes[offset..][0..trimmed.len], trimmed);
        self.spans[self.count] = .{ .offset = offset, .len = @intCast(trimmed.len) };
        self.count += 1;
        self.used = offset + @as(u16, @intCast(trimmed.len));
        std.debug.assert(self.count <= roots_max);
        std.debug.assert(self.used <= root_bytes_max);
        return true;
    }

    /// Joins `parent` and `child` with a single separator and adds the result.
    /// Platform lists build most of their roots this way, joining a directory
    /// from the environment to a fixed suffix. A join longer than the path
    /// buffer counts a drop and returns false.
    pub fn appendJoined(self: *RootSet, parent: []const u8, child: []const u8) bool {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const trimmed = sys.path.trimTrailingSeparators(parent);
        const joined = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ trimmed, child }) catch {
            self.dropped +|= 1;
            return false;
        };
        return self.append(joined);
    }
};

/// Looks up `HOME`, `XDG_DATA_HOME`, and `XDG_DATA_DIRS` in the running
/// process, for a caller running against the real host.
pub fn hostEnvironment() Environment {
    return .{
        .home = env.get("HOME"),
        .xdg_data_home = env.get("XDG_DATA_HOME"),
        .xdg_data_dirs = env.get("XDG_DATA_DIRS"),
    };
}

/// Fills `set` with the directories this machine's operating system keeps fonts
/// in, ordered as the search visits them. A caller enumerating host fonts
/// starts here.
pub fn defaultRoots(set: *RootSet, environment: Environment) Support {
    return rootsFor(set, native_os, environment);
}

/// Fills `set` for the operating system named by `os_tag` after clearing the
/// set first, so a test on one host can check another platform's search order
/// and the refusal an unlisted one produces. Linux and the BSD targets take the
/// XDG order, the Apple targets take the Library order, and every other target
/// reports itself unsupported.
pub fn rootsFor(
    set: *RootSet,
    os_tag: std.Target.Os.Tag,
    environment: Environment,
) Support {
    set.clear();
    return switch (os_tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos, .hurd => .{
            .supported = linuxRoots(set, environment),
        },
        .macos, .maccatalyst, .ios, .tvos, .watchos, .visionos => .{
            .supported = appleRoots(set, environment),
        },
        else => .{ .unsupported = .platform },
    };
}

fn linuxRoots(set: *RootSet, environment: Environment) u8 {
    std.debug.assert(set.count == 0);
    appendDataHome(set, environment);
    appendDataDirs(set, environment);
    _ = set.append("/usr/local/share/fonts");
    _ = set.append("/usr/share/fonts");
    if (nonEmpty(environment.home)) |home| {
        _ = set.appendJoined(home, ".local/share/fonts");
        _ = set.appendJoined(home, ".fonts");
    }
    std.debug.assert(set.count <= roots_max);
    return set.count;
}

fn appendDataHome(set: *RootSet, environment: Environment) void {
    if (nonEmpty(environment.xdg_data_home)) |directory| {
        _ = set.appendJoined(directory, "fonts");
        return;
    }
    if (nonEmpty(environment.home)) |home| {
        _ = set.appendJoined(home, ".local/share/fonts");
    }
}

fn appendDataDirs(set: *RootSet, environment: Environment) void {
    const configured = nonEmpty(environment.xdg_data_dirs) orelse
        "/usr/local/share:/usr/share";
    var entries = std.mem.splitScalar(u8, configured, ':');
    var visited: usize = 0;
    while (entries.next()) |entry| : (visited += 1) {
        std.debug.assert(visited <= configured.len + 1);
        if (entry.len == 0) continue;
        _ = set.appendJoined(entry, "fonts");
    }
}

fn appleRoots(set: *RootSet, environment: Environment) u8 {
    std.debug.assert(set.count == 0);
    if (nonEmpty(environment.home)) |home| {
        _ = set.appendJoined(home, "Library/Fonts");
    }
    _ = set.append("/Library/Fonts");
    _ = set.append("/System/Library/Fonts");
    _ = set.append("/System/Library/Fonts/Supplemental");
    _ = set.append("/Network/Library/Fonts");
    std.debug.assert(set.count <= roots_max);
    return set.count;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return text;
}

fn collect(set: *const RootSet, output: [][]const u8) [][]const u8 {
    std.debug.assert(output.len >= set.count);
    for (0..set.count) |index| output[index] = set.path(@intCast(index));
    return output[0..set.count];
}
