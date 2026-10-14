const std = @import("std");
const command = @import("command.zig");
const Io = std.Io;

/// The most declared run-time inputs one test binary may copy into its tree.
pub const inputs_max = 64;

const root_name = "root";

pub const Input = struct {
    /// Repository-relative path the tests open through their working directory.
    path: []const u8,
    /// Build-resolved file whose bytes the build hashed into the run's cache key.
    source: []const u8,
};

/// Where a run's tree lives. `disk` is the cached output directory, on the checkout's
/// filesystem, where each forced write waits for the device. `memory` asks for a
/// memory-backed directory, where a force returns at once.
pub const Store = enum { disk, memory };

/// Why a run's tree is on disk.
pub const DiskReason = enum {
    /// Neither the build nor the environment asked for memory.
    not_requested,
    /// The override variable says `disk`.
    forced,
    unsupported_system,
    mount_absent,
    filesystem_unknown,
    /// The mount point exists on a filesystem that is not memory-backed.
    filesystem_not_memory,
    space_unknown,
    space_below_bound,
    directory_unavailable,
    /// The user's directory exists and is not a directory this user owns with mode 0700.
    directory_untrusted,
};

/// The free bytes a memory-backed filesystem must report before a run puts its tree there.
/// It is a floor on what is left when the run starts, not a cap on what the run writes.
pub const memory_free_bytes_min: u64 = 1024 * 1024 * 1024;
/// The type `statfs` reports for tmpfs, the one memory-backed filesystem a tree may use.
pub const tmpfs_type: u64 = 0x01021994;
/// The mode of the directory that holds one user's trees, and of each tree in it.
pub const memory_directory_mode: u32 = 0o700;

/// The store a run asks for, or the reason it stays on disk before any mount is read.
pub const Request = union(enum) {
    memory,
    disk: DiskReason,
};

/// Resolves a run's request from its build's store and the override variable's value.
/// `disk` forces the disk and `memory` asks for memory whatever the build asked. Any other
/// value leaves the build's request standing.
pub fn request(build: Store, override: ?[]const u8) Request {
    if (override) |named| {
        if (std.mem.eql(u8, named, "disk")) return .{ .disk = .forced };
        if (std.mem.eql(u8, named, "memory")) return .memory;
    }
    return if (build == .memory) .memory else .{ .disk = .not_requested };
}

/// Reports whether a run writes its tree line: its build asked for memory, or the override
/// variable is set. Every other run's output stays as it was.
pub fn reports(build: ?Store, override: ?[]const u8) bool {
    if (override != null) return true;
    return if (build) |store| store == .memory else false;
}

/// What the opened mount point reported. Null fields are values the system did not give.
pub const Mount = struct {
    filesystem_type: ?u64,
    available_bytes: ?u64,
};

/// Decides whether a mount point may hold a tree, before anything is created or removed
/// there. A null `mount` is a mount point that could not be opened.
pub fn mountRefusal(mount: ?Mount) ?DiskReason {
    const observed = mount orelse return .mount_absent;
    const filesystem_type = observed.filesystem_type orelse return .filesystem_unknown;
    if (filesystem_type != tmpfs_type) return .filesystem_not_memory;
    const available = observed.available_bytes orelse return .space_unknown;
    if (available < memory_free_bytes_min) return .space_below_bound;
    return null;
}

/// What the opened user directory reported about itself.
pub const Directory = struct {
    owner: u64,
    mode: u32,
};

/// Decides whether the user's directory may be used and swept. The mount is world-writable,
/// so a directory found there counts only when `user` owns it and its mode is exactly
/// `memory_directory_mode`. A null `found` is a name that could not be read as a directory.
pub fn directoryRefusal(found: ?Directory, user: u64) ?DiskReason {
    const observed = found orelse return .directory_untrusted;
    if (observed.owner != user) return .directory_untrusted;
    if (observed.mode != memory_directory_mode) return .directory_untrusted;
    return null;
}

/// Names a filesystem type as `statfs` reports it. An unlisted type prints as its number.
pub fn filesystemName(filesystem_type: ?u64, storage: *[24]u8) []const u8 {
    return switch (filesystem_type orelse return "unknown") {
        tmpfs_type => "tmpfs",
        0xEF53 => "ext2/ext3/ext4",
        0x9123683E => "btrfs",
        0x58465342 => "xfs",
        0x2FC12FC1 => "zfs",
        0x794C7630 => "overlayfs",
        0x6969 => "nfs",
        else => |other| std.fmt.bufPrint(storage, "0x{x}", .{other}) catch unreachable,
    };
}

/// Removes each entry of `shared` whose name is the identifier of a process `alive` reports
/// gone. A live process's tree and any entry that is not a process identifier stay.
pub fn removeDeadTrees(
    io: Io,
    shared: Io.Dir,
    context: anytype,
    comptime alive: fn (@TypeOf(context), u32) bool,
) void {
    var entries = shared.iterate();
    while (entries.next(io) catch return) |entry| {
        const process = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        if (alive(context, process)) continue;
        shared.deleteTree(io, entry.name) catch {};
    }
}

/// A private working tree that holds only the declared inputs of one cached test run.
pub const Plan = struct {
    output: []const u8,
    cwd: []const u8,
    /// The store the build asked for. The runner's environment can override it.
    store: Store = .disk,
    inputs: [inputs_max]Input = undefined,
    input_count: usize = 0,

    pub fn declared(self: *const Plan) []const Input {
        std.debug.assert(self.input_count <= inputs_max);
        return self.inputs[0..self.input_count];
    }
};

pub const PlanError = error{
    DuplicateTree,
    DuplicateCwd,
    MissingTree,
    MissingCwd,
    TooManyInputs,
    InvalidTreePath,
    InvalidTreeStore,
    DuplicateTreeStore,
    InvalidInput,
    DuplicateInput,
};

/// Reads the tree flags. A run without `--test-tree` keeps the caller's working directory.
pub fn plan(iterator: anytype) PlanError!?Plan {
    var output: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    var result: Plan = .{ .output = "", .cwd = "" };
    var any_input = false;
    var store: ?Store = null;
    while (iterator.next()) |argument| {
        if (value(argument, command.tree_flag, iterator)) |path| {
            if (output != null) return error.DuplicateTree;
            if (path.len == 0) return error.InvalidTreePath;
            output = path;
        } else if (value(argument, command.cwd_flag, iterator)) |path| {
            if (cwd != null) return error.DuplicateCwd;
            if (!relative(path)) return error.InvalidTreePath;
            cwd = path;
        } else if (value(argument, command.tree_store_flag, iterator)) |text| {
            if (store != null) return error.DuplicateTreeStore;
            store = std.meta.stringToEnum(Store, text) orelse return error.InvalidTreeStore;
        } else if (value(argument, command.input_flag, iterator)) |text| {
            any_input = true;
            const split = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidInput;
            const input: Input = .{ .path = text[0..split], .source = text[split + 1 ..] };
            if (!relative(input.path) or input.source.len == 0) return error.InvalidInput;
            for (result.declared()) |existing| {
                if (std.mem.eql(u8, existing.path, input.path)) return error.DuplicateInput;
            }
            if (result.input_count == inputs_max) return error.TooManyInputs;
            result.inputs[result.input_count] = input;
            result.input_count += 1;
        }
    }
    const tree = output orelse {
        if (cwd != null or any_input or store != null) return error.MissingTree;
        return null;
    };
    result.output = tree;
    result.cwd = cwd orelse return error.MissingCwd;
    result.store = store orelse .disk;
    return result;
}

fn value(argument: []const u8, flag: []const u8, iterator: anytype) ?[]const u8 {
    if (std.mem.eql(u8, argument, flag)) return iterator.next() orelse "";
    if (argument.len > flag.len and argument[flag.len] == '=' and
        std.mem.eql(u8, argument[0..flag.len], flag)) return argument[flag.len + 1 ..];
    return null;
}

/// Accepts a nonempty relative path whose every component names an entry below its base.
pub fn relative(path: []const u8) bool {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes or path[0] == '/') return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// A directory on a memory-backed filesystem that holds one run's tree in place of the
/// cached output directory. A forced write returns there without waiting for a device.
pub const Memory = struct {
    /// The directory every run's tree shares.
    shared: Io.Dir,
    /// This run's entry in `shared`, which the caller created.
    name: []const u8,
};

/// The prepared tree. Passing runs remove it so the cached output keeps only the report.
pub const Workspace = struct {
    output: Io.Dir,
    memory: ?Memory = null,

    /// Leaves the tree and deletes it with everything the tests wrote under it.
    pub fn finish(self: Workspace, io: Io) !void {
        try std.process.setCurrentDir(io, self.output);
        try self.output.deleteTree(io, root_name);
        self.output.close(io);
        if (self.memory) |memory| {
            try memory.shared.deleteDir(io, memory.name);
            memory.shared.close(io);
        }
    }
};

/// Copies each declared input to its repository-relative path under the tree, then makes
/// the tree's copy of `cwd` the working directory. Input sources resolve against the
/// working directory the build gave the run, before the change. With `memory`, the tree
/// lives in that directory and the cached output directory stays empty.
pub fn prepare(io: Io, selected: *const Plan, memory: ?Memory) !Workspace {
    const invoked = Io.Dir.cwd();
    var output = if (memory) |chosen|
        try chosen.shared.openDir(io, chosen.name, .{})
    else
        try invoked.openDir(io, selected.output, .{});
    errdefer output.close(io);
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    try output.deleteTree(io, root_name);
    const cwd_path = try std.fmt.bufPrint(&path_storage, root_name ++ "/{s}", .{selected.cwd});
    try output.createDirPath(io, cwd_path);
    for (selected.declared()) |input| {
        const destination = try std.fmt.bufPrint(&path_storage, root_name ++ "/{s}", .{input.path});
        if (std.fs.path.dirname(destination)) |parent| try output.createDirPath(io, parent);
        try Io.Dir.copyFile(invoked, input.source, output, destination, io, .{});
    }
    var working = try output.openDir(io, try std.fmt.bufPrint(
        &path_storage,
        root_name ++ "/{s}",
        .{selected.cwd},
    ), .{});
    defer working.close(io);
    try std.process.setCurrentDir(io, working);
    return .{ .output = output, .memory = memory };
}

const SliceIterator = struct {
    values: []const []const u8,
    index: usize = 0,

    fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index >= self.values.len) return null;
        defer self.index += 1;
        return self.values[self.index];
    }
};

fn planSlice(values: []const []const u8) PlanError!?Plan {
    var iterator = SliceIterator{ .values = values };
    return plan(&iterator);
}

fn expectRefused(expected: PlanError, values: []const []const u8) !void {
    try std.testing.expectError(expected, planSlice(values));
}
