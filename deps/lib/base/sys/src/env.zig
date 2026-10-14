const std = @import("std");
const capabilities = @import("capabilities.zig");
const memory = @import("memory.zig");

const Allocator = std.mem.Allocator;

pub const required_capabilities = capabilities.host(&.{.environment});

pub const Map = std.process.Environ.Map;
pub const CreateMapError = std.process.Environ.CreateMapError;
pub const ClaimError = error{
    ConditionRejected,
    GenerationStorageAlreadyUsed,
    GenerationStorageTooSmall,
};

pub const GenerationStorage = struct {
    entries: []?[*:0]const u8,
    used: bool = false,

    pub fn init(entries: []?[*:0]const u8) GenerationStorage {
        return .{ .entries = entries };
    }
};

pub fn get(name: [:0]const u8) ?[]const u8 {
    if (!validPosixName(name)) return null;
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return null;
    const threaded = std.Options.debug_threaded_io orelse return null;
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    return lookupPosixEntries(threaded.environ.process_environ.block.view().slice, name);
}

pub fn getConstant(comptime name: []const u8) ?[]const u8 {
    const name_z: [:0]const u8 = name ++ "";
    return get(name_z);
}

pub fn contains(name: [:0]const u8) bool {
    return get(name) != null;
}

pub fn containsNonEmpty(name: [:0]const u8) bool {
    const value = get(name) orelse return false;
    return value.len != 0;
}

pub fn installProcessEnvironment(environ: std.process.Environ) void {
    const threaded = std.Options.debug_threaded_io orelse return;
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    threaded.environ = .{ .process_environ = environ };
    threaded.environ_initialized = environ.block.isEmpty();
}

pub fn processEnviron() std.process.Environ {
    const threaded = std.Options.debug_threaded_io orelse return .empty;
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    return threaded.environ.process_environ;
}

pub fn getOwned(allocator: Allocator, name: []const u8) Allocator.Error!?[]u8 {
    if (!validPosixName(name)) return null;
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return null;
    const threaded = std.Options.debug_threaded_io orelse return null;
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    const block = threaded.environ.process_environ.block;
    if (lookupPosixEntries(block.view().slice, name)) |value| return try allocator.dupe(u8, value);
    return null;
}

pub fn claimIf(
    storage: *GenerationStorage,
    name: []const u8,
    context: anytype,
    comptime condition: fn (@TypeOf(context), []const u8) bool,
) ClaimError!bool {
    if (!validPosixName(name)) return false;
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return false;
    const threaded = std.Options.debug_threaded_io orelse return false;
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);

    const entries = threaded.environ.process_environ.block.view().slice;
    const match = findPosixEntry(entries, name) orelse return false;
    if (storage.used) return error.GenerationStorageAlreadyUsed;
    if (entries.len > storage.entries.len) return error.GenerationStorageTooSmall;
    if (!condition(context, match.value)) return error.ConditionRejected;
    commitClaim(storage, threaded, entries, match);
    return true;
}

fn commitClaim(
    storage: *GenerationStorage,
    threaded: *std.Io.Threaded,
    entries: []const [*:0]const u8,
    match: PosixEntry,
) void {
    std.debug.assert(!storage.used);
    std.debug.assert(entries.len <= storage.entries.len);
    var write_index: usize = 0;
    for (entries, 0..) |entry, read_index| {
        if (read_index == match.index) continue;
        storage.entries[write_index] = entry;
        write_index += 1;
    }
    storage.entries[write_index] = null;
    storage.used = true;
    const slice: [:null]const ?[*:0]const u8 = storage.entries[0..write_index :null];
    threaded.environ = .{ .process_environ = .{ .block = .{ .slice = slice } } };
    threaded.environ_initialized = slice.len == 0;
}

pub fn createMap(allocator: Allocator) CreateMapError!Map {
    const threaded = std.Options.debug_threaded_io orelse return .init(allocator);
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    return threaded.environ.process_environ.createMap(allocator);
}

pub fn current() std.process.Environ {
    const threaded = std.Options.debug_threaded_io orelse return .empty;
    std.Io.Threaded.mutexLockUncancelable(&threaded.mutex);
    defer std.Io.Threaded.mutexUnlock(&threaded.mutex);
    return threaded.environ.process_environ;
}

fn lookupPosixEntries(entries: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    return if (findPosixEntry(entries, name)) |match| match.value else null;
}

const PosixEntry = struct {
    index: usize,
    value: []const u8,
};

fn findPosixEntry(entries: []const [*:0]const u8, name: []const u8) ?PosixEntry {
    for (entries, 0..) |entry, index| {
        var separator_index: usize = 0;
        while (entry[separator_index] != 0 and entry[separator_index] != '=') : (separator_index += 1) {}
        if (entry[separator_index] != '=') continue;
        if (!std.mem.eql(u8, name, entry[0..separator_index])) continue;

        const value_start = separator_index + 1;
        var value_end = value_start;
        while (entry[value_end] != 0) : (value_end += 1) {}
        return .{ .index = index, .value = entry[value_start..value_end] };
    }
    return null;
}

fn validPosixName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfAny(u8, name, "\x00=") == null;
}

const ClaimWorker = struct {
    storage: *GenerationStorage,
    claimed: bool = false,
    saw_value: bool = false,
    failure: ?ClaimError = null,

    fn run(self: *@This()) void {
        self.claimed = claimIf(
            self.storage,
            "TINY_SYS_ENV_TAKE",
            self,
            accept,
        ) catch |failure| {
            self.failure = failure;
            return;
        };
    }

    fn accept(self: *@This(), value: []const u8) bool {
        self.saw_value = std.mem.eql(u8, value, "transferred");
        return self.saw_value;
    }
};

fn acceptClaimValue(_: void, _: []const u8) bool {
    return true;
}

fn rejectClaimValue(_: void, _: []const u8) bool {
    return false;
}

fn recordClaimCondition(called: *bool, _: []const u8) bool {
    called.* = true;
    return true;
}

const SnapshotReader = struct {
    failed: bool = false,

    fn run(self: *@This()) void {
        for (0..64) |_| {
            var snapshot = createMap(memory.page_allocator) catch {
                self.failed = true;
                return;
            };
            defer snapshot.deinit();
            const stable = snapshot.get("TINY_SYS_ENV_SNAPSHOT_KEEP") orelse {
                self.failed = true;
                return;
            };
            if (!std.mem.eql(u8, stable, "stable")) {
                self.failed = true;
                return;
            }
            if (snapshot.get("TINY_SYS_ENV_SNAPSHOT_TAKE")) |transient| {
                if (!std.mem.eql(u8, transient, "transient")) {
                    self.failed = true;
                    return;
                }
            }
        }
    }
};
