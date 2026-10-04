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

test "lookupPosixEntries matches only exact names" {
    const entries = [_][*:0]const u8{
        "TINY_SYS_ENV_TEST=ok",
        "TINY_SYS_ENV_TEST_EXTRA=no",
    };
    try std.testing.expectEqualStrings("ok", lookupPosixEntries(&entries, "TINY_SYS_ENV_TEST").?);
}

test "lookupPosixEntries preserves empty values" {
    const entries = [_][*:0]const u8{"TINY_SYS_ENV_EMPTY="};
    try std.testing.expectEqualStrings("", lookupPosixEntries(&entries, "TINY_SYS_ENV_EMPTY").?);
}

test "containsNonEmpty distinguishes missing and empty values" {
    const entries = [_][*:0]const u8{"TINY_SYS_ENV_EMPTY="};
    try std.testing.expect(lookupPosixEntries(&entries, "TINY_SYS_ENV_MISSING") == null);
    try std.testing.expectEqual(@as(usize, 0), lookupPosixEntries(&entries, "TINY_SYS_ENV_EMPTY").?.len);
}

test "invalid names do not query the environment" {
    try std.testing.expect(!validPosixName(""));
    try std.testing.expect(!validPosixName("A=B"));
    try std.testing.expect(!validPosixName("A\x00B"));
}

test "getOwned duplicates installed process block values" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var map = Map.init(allocator);
    defer map.deinit();
    try map.put("TINY_SYS_ENV_OWNED", "from-block");

    const block = try map.createPosixBlock(allocator, .{});
    defer block.deinit(allocator);

    const previous = current();
    installProcessEnvironment(.{ .block = block });
    defer installProcessEnvironment(previous);

    try std.testing.expectEqualStrings("from-block", getConstant("TINY_SYS_ENV_OWNED").?);

    const value = (try getOwned(allocator, "TINY_SYS_ENV_OWNED")).?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("from-block", value);
}

test "claimIf removes one process value atomically from inherited child state" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var map = Map.init(allocator);
    defer map.deinit();
    try map.put("TINY_SYS_ENV_TAKE", "transferred");
    try map.put("TINY_SYS_ENV_RETAIN", "visible");

    const block = try map.createPosixBlock(allocator, .{});
    defer block.deinit(allocator);
    const previous = current();
    installProcessEnvironment(.{ .block = block });
    defer installProcessEnvironment(previous);

    var generation_entries: [2]?[*:0]const u8 = undefined;
    var generation = GenerationStorage.init(&generation_entries);
    var workers: [8]ClaimWorker = undefined;
    for (&workers) |*worker| worker.* = .{ .storage = &generation };
    var threads: [workers.len]std.Thread = undefined;
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, ClaimWorker.run, .{worker});
    }
    for (&threads) |*thread| thread.join();

    var transfers: usize = 0;
    for (workers) |worker| {
        try std.testing.expect(worker.failure == null);
        if (worker.claimed) {
            transfers += 1;
            try std.testing.expect(worker.saw_value);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), transfers);
    try std.testing.expect(generation.used);
    try std.testing.expect(getConstant("TINY_SYS_ENV_TAKE") == null);
    try std.testing.expectEqualStrings("visible", getConstant("TINY_SYS_ENV_RETAIN").?);

    var inherited = try createMap(allocator);
    defer inherited.deinit();
    try std.testing.expect(!inherited.contains("TINY_SYS_ENV_TAKE"));
    try std.testing.expectEqualStrings("visible", inherited.get("TINY_SYS_ENV_RETAIN").?);
}

test "claimIf leaves rejected process values and generation storage untouched" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var map = Map.init(allocator);
    defer map.deinit();
    try map.put("TINY_SYS_ENV_REJECT", "unchanged");

    const block = try map.createPosixBlock(allocator, .{});
    defer block.deinit(allocator);
    const previous = current();
    installProcessEnvironment(.{ .block = block });
    defer installProcessEnvironment(previous);

    var generation_entries: [1]?[*:0]const u8 = undefined;
    var generation = GenerationStorage.init(&generation_entries);
    try std.testing.expectError(
        error.ConditionRejected,
        claimIf(&generation, "TINY_SYS_ENV_REJECT", {}, rejectClaimValue),
    );
    try std.testing.expect(!generation.used);
    try std.testing.expectEqualStrings("unchanged", getConstant("TINY_SYS_ENV_REJECT").?);

    var inherited = try createMap(allocator);
    defer inherited.deinit();
    try std.testing.expectEqualStrings("unchanged", inherited.get("TINY_SYS_ENV_REJECT").?);
}

test "claimIf reserves exact generation capacity before condition effects" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var map = Map.init(allocator);
    defer map.deinit();
    try map.put("TINY_SYS_ENV_TAKE", "transferred");
    try map.put("TINY_SYS_ENV_RETAIN", "visible");

    const block = try map.createPosixBlock(allocator, .{});
    defer block.deinit(allocator);
    const previous = current();
    installProcessEnvironment(.{ .block = block });
    defer installProcessEnvironment(previous);

    var too_small_entries: [1]?[*:0]const u8 = undefined;
    var too_small = GenerationStorage.init(&too_small_entries);
    var condition_called = false;
    try std.testing.expectError(
        error.GenerationStorageTooSmall,
        claimIf(
            &too_small,
            "TINY_SYS_ENV_TAKE",
            &condition_called,
            recordClaimCondition,
        ),
    );
    try std.testing.expect(!condition_called);
    try std.testing.expect(!too_small.used);
    try std.testing.expectEqualStrings("transferred", getConstant("TINY_SYS_ENV_TAKE").?);

    var exact_entries: [2]?[*:0]const u8 = undefined;
    var exact = GenerationStorage.init(&exact_entries);
    try std.testing.expect(try claimIf(
        &exact,
        "TINY_SYS_ENV_TAKE",
        &condition_called,
        recordClaimCondition,
    ));
    try std.testing.expect(condition_called);
    try std.testing.expect(exact.used);
    try std.testing.expect(getConstant("TINY_SYS_ENV_TAKE") == null);
    try std.testing.expectEqualStrings("visible", getConstant("TINY_SYS_ENV_RETAIN").?);
}

test "claimIf never reuses a populated generation" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var first = Map.init(allocator);
    defer first.deinit();
    try first.put("TINY_SYS_ENV_FIRST", "first");
    const first_block = try first.createPosixBlock(allocator, .{});
    defer first_block.deinit(allocator);

    var second = Map.init(allocator);
    defer second.deinit();
    try second.put("TINY_SYS_ENV_SECOND", "second");
    const second_block = try second.createPosixBlock(allocator, .{});
    defer second_block.deinit(allocator);

    const previous = current();
    installProcessEnvironment(.{ .block = first_block });
    defer installProcessEnvironment(previous);

    var generation_entries: [1]?[*:0]const u8 = undefined;
    var generation = GenerationStorage.init(&generation_entries);
    try std.testing.expect(try claimIf(
        &generation,
        "TINY_SYS_ENV_FIRST",
        {},
        acceptClaimValue,
    ));

    installProcessEnvironment(.{ .block = second_block });
    try std.testing.expectError(
        error.GenerationStorageAlreadyUsed,
        claimIf(&generation, "TINY_SYS_ENV_SECOND", {}, acceptClaimValue),
    );
    try std.testing.expectEqualStrings("second", getConstant("TINY_SYS_ENV_SECOND").?);
}

test "createMap snapshots process blocks during concurrent removal" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var map = Map.init(allocator);
    defer map.deinit();
    try map.put("TINY_SYS_ENV_SNAPSHOT_TAKE", "transient");
    try map.put("TINY_SYS_ENV_SNAPSHOT_KEEP", "stable");

    const block = try map.createPosixBlock(allocator, .{});
    defer block.deinit(allocator);
    const previous = current();
    installProcessEnvironment(.{ .block = block });
    defer installProcessEnvironment(previous);

    var readers: [8]SnapshotReader = @splat(.{});
    var threads: [readers.len]std.Thread = undefined;
    for (&threads, &readers) |*thread, *reader| {
        thread.* = try std.Thread.spawn(.{}, SnapshotReader.run, .{reader});
    }
    var generation_entries: [2]?[*:0]const u8 = undefined;
    var generation = GenerationStorage.init(&generation_entries);
    try std.testing.expect(try claimIf(
        &generation,
        "TINY_SYS_ENV_SNAPSHOT_TAKE",
        {},
        acceptClaimValue,
    ));
    for (&threads) |*thread| thread.join();

    for (readers) |reader| try std.testing.expect(!reader.failed);
}

test "saved process environment generations survive later removals" {
    if (comptime !@hasDecl(std.process.Environ.Block, "view")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var first = Map.init(allocator);
    defer first.deinit();
    try first.put("WAYLAND_SOCKET", "11");
    try first.put("TINY_SYS_ENV_GENERATION_KEEP", "A");
    const first_block = try first.createPosixBlock(allocator, .{});
    defer first_block.deinit(allocator);

    var second = Map.init(allocator);
    defer second.deinit();
    try second.put("TINY_SYS_ENV_GENERATION_TAKE", "second");
    try second.put("TINY_SYS_ENV_GENERATION_KEEP", "B");
    const second_block = try second.createPosixBlock(allocator, .{});
    defer second_block.deinit(allocator);

    const initial = current();
    installProcessEnvironment(.{ .block = first_block });
    defer installProcessEnvironment(initial);

    var first_generation_entries: [2]?[*:0]const u8 = undefined;
    var first_generation = GenerationStorage.init(&first_generation_entries);
    try std.testing.expect(try claimIf(
        &first_generation,
        "WAYLAND_SOCKET",
        {},
        acceptClaimValue,
    ));
    const previous = current();

    installProcessEnvironment(.{ .block = second_block });
    var second_generation_entries: [2]?[*:0]const u8 = undefined;
    var second_generation = GenerationStorage.init(&second_generation_entries);
    try std.testing.expect(try claimIf(
        &second_generation,
        "TINY_SYS_ENV_GENERATION_TAKE",
        {},
        acceptClaimValue,
    ));
    installProcessEnvironment(previous);

    var restored = try createMap(allocator);
    defer restored.deinit();
    try std.testing.expect(!restored.contains("WAYLAND_SOCKET"));
    try std.testing.expect(!restored.contains("TINY_SYS_ENV_GENERATION_TAKE"));
    try std.testing.expectEqualStrings("A", restored.get("TINY_SYS_ENV_GENERATION_KEEP").?);
}
