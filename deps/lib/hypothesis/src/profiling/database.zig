const std = @import("std");
const bench = @import("bench");
const hypothesis = @import("hypothesis");

const Allocator = std.mem.Allocator;
const FailureEntry = hypothesis.database.FailureEntry;

pub const failure_count: usize = 64;
pub const overflow_failure_count: usize = 1024;
pub const choices_per_failure: usize = 64;
pub const block_bytes: usize = 128;
const load_namespace = "profile-load";
const overflow_namespace = "profile-overflow";
const save_namespace = "profile-save";

pub const Fixture = struct {
    allocator: Allocator,
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    choices: [choices_per_failure]hypothesis.ChoiceNode,
    blocks: [block_bytes]u8,

    pub fn init(allocator: Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
        errdefer allocator.free(path);
        var fixture = Fixture{
            .allocator = allocator,
            .tmp = tmp,
            .path = path,
            .choices = undefined,
            .blocks = undefined,
        };
        for (0..failure_count) |failure_index| {
            fixture.prepare(failure_index);
            try hypothesis.database.saveFailure(
                allocator,
                path,
                load_namespace,
                &fixture.choices,
                &fixture.blocks,
            );
        }
        for (0..overflow_failure_count) |failure_index| {
            fixture.prepare(failure_index + failure_count);
            try hypothesis.database.saveFailure(
                allocator,
                path,
                overflow_namespace,
                &fixture.choices,
                &fixture.blocks,
            );
        }
        fixture.prepare(failure_count);
        try hypothesis.database.saveFailure(
            allocator,
            path,
            save_namespace,
            &fixture.choices,
            &fixture.blocks,
        );
        return fixture;
    }

    pub fn deinit(self: *Fixture) void {
        self.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn prepare(self: *Fixture, failure_index: usize) void {
        for (&self.choices, 0..) |*node, choice_index| {
            node.* = .{
                .kind = .integer,
                .value = @intCast((failure_index *% 257 +% choice_index *% 17) % 65_536),
                .min = 0,
                .max = 65_535,
                .shrink_towards = @intCast(failure_index % 7),
                .was_forced = choice_index % 11 == 0,
            };
        }
        self.choices[choices_per_failure - 1] = .{
            .kind = .integer,
            .value = block_bytes,
            .min = block_bytes,
            .max = block_bytes,
            .shrink_towards = block_bytes,
        };
        for (&self.blocks, 0..) |*byte, index| {
            byte.* = @truncate(failure_index *% 29 +% index *% 13);
        }
    }
};

var active_fixture: ?*const Fixture = null;

pub fn activate(fixture: *const Fixture) void {
    std.debug.assert(active_fixture == null);
    active_fixture = fixture;
}

pub fn deactivate() void {
    std.debug.assert(active_fixture != null);
    active_fixture = null;
}

pub fn load(sample_allocator: Allocator) void {
    const fixture = active_fixture orelse unreachable;
    var cursor = hypothesis.database.ReplayCursor.init(
        sample_allocator,
        replayLimits(fixture.path, load_namespace, failure_count),
    ) catch @panic("hypothesis database load benchmark failed");
    defer cursor.deinit(sample_allocator);
    cursor.activate();
    var count: usize = 0;
    var digest: u64 = 0;
    while (cursor.next() catch @panic("hypothesis database load benchmark failed")) |failure| {
        count += 1;
        digest +%= failureDigest(failure);
    }
    if (count != failure_count) {
        @panic("hypothesis database load benchmark count failed");
    }
    std.mem.doNotOptimizeAway(digest);
    bench.coz.progressNamed("hypothesis.database.load.complete");
}

pub fn loadReplay(sample_allocator: Allocator) void {
    const fixture = active_fixture orelse unreachable;
    var cursor = hypothesis.database.ReplayCursor.init(
        sample_allocator,
        replayLimits(fixture.path, load_namespace, failure_count),
    ) catch @panic("hypothesis database replay benchmark failed");
    defer cursor.deinit(sample_allocator);
    cursor.activate();
    var count: usize = 0;
    var digest: u64 = 0;
    while (cursor.next() catch @panic("hypothesis database replay benchmark failed")) |failure| {
        count += 1;
        digest +%= replayFailure(sample_allocator, failure);
    }
    if (count != failure_count) {
        @panic("hypothesis database replay benchmark count failed");
    }
    std.mem.doNotOptimizeAway(digest);
    bench.coz.progressNamed("hypothesis.database.load_replay.complete");
}

pub fn loadBoundedOverflow(sample_allocator: Allocator) void {
    const fixture = active_fixture orelse unreachable;
    var cursor = hypothesis.database.ReplayCursor.init(
        sample_allocator,
        replayLimits(fixture.path, overflow_namespace, failure_count),
    ) catch @panic("hypothesis bounded database load benchmark failed");
    defer cursor.deinit(sample_allocator);
    cursor.activate();
    var count: usize = 0;
    var digest: u64 = 0;
    while (cursor.next() catch
        @panic("hypothesis bounded database load benchmark failed")) |failure|
    {
        count += 1;
        digest +%= failureDigest(failure);
    }
    if (count != failure_count or !cursor.status().scan_budget_saturated) {
        @panic("hypothesis bounded database load benchmark count failed");
    }
    std.mem.doNotOptimizeAway(digest);
    bench.coz.progressNamed("hypothesis.database.bounded_overflow.complete");
}

pub fn save(sample_allocator: Allocator) void {
    const fixture = active_fixture orelse unreachable;
    hypothesis.database.saveFailure(
        sample_allocator,
        fixture.path,
        save_namespace,
        &fixture.choices,
        &fixture.blocks,
    ) catch @panic("hypothesis database save benchmark failed");
    bench.coz.progressNamed("hypothesis.database.save.complete");
}

fn failureDigest(failure: FailureEntry) u64 {
    var digest: u64 = 0;
    for (failure.choices) |choice| digest +%= choice.value;
    if (failure.byte_blocks) |blocks| {
        for (blocks) |byte| digest +%= byte;
    }
    return digest;
}

fn replayLimits(
    path: []const u8,
    namespace: []const u8,
    max_entries: usize,
) hypothesis.database.ReplayCursor.Limits {
    return .{
        .db_path = path,
        .namespace = namespace,
        .max_entries = max_entries,
        .max_choices = choices_per_failure,
        .max_byte_blocks = block_bytes,
    };
}

fn replayFailure(allocator: Allocator, failure: FailureEntry) u64 {
    var data = hypothesis.ConjectureData.initReplay(
        allocator,
        failure.choices,
        failure.byte_blocks,
    );
    defer data.deinit();
    var digest: u64 = 0;
    for (0..choices_per_failure - 1) |_| {
        digest +%= data.drawInteger(0, 65_535, 0) catch
            @panic("hypothesis database integer replay failed");
    }
    const bytes = data.drawBytes(block_bytes, block_bytes) catch
        @panic("hypothesis database byte replay failed");
    for (bytes) |byte| digest +%= byte;
    return digest;
}

test "bench: database fixture loads and replays every failure" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var cursor = try hypothesis.database.ReplayCursor.init(
        std.testing.allocator,
        replayLimits(fixture.path, load_namespace, failure_count),
    );
    defer cursor.deinit(std.testing.allocator);
    cursor.activate();
    var count: usize = 0;
    var digest: u64 = 0;
    while (try cursor.next()) |failure| {
        count += 1;
        digest +%= replayFailure(std.testing.allocator, failure);
    }
    try std.testing.expectEqual(failure_count, count);
    try std.testing.expect(digest != 0);
}
