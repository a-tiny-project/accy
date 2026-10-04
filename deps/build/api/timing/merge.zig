//! Merges the rows files of one sharded timing run. It refuses a merge unless the shards
//! agree on their count and selection, each index appears once, and the executed tests
//! cover the selection exactly once. It then writes one report in the serial runner's
//! summary format, with each shard's predicted and actual time, and a regenerated weights
//! table. Usage: merge --weights TABLE --report OUT --table OUT ROWS...
const std = @import("std");
const balance = @import("balance.zig");
const rows = @import("rows.zig");

const fs_io = std.Options.debug_io;
const max_rows_bytes: usize = balance.max_tests * (balance.max_name_bytes + 64) + 64;
/// A shard whose actual time exceeds its prediction by this factor marks the table stale.
const stale_percent: u64 = 125;

/// A refused merge returns its error. The start code reports it by name and exits 1.
pub fn main(init: std.process.Init) !void {
    try run(init);
}

const Cli = struct {
    weights: []const u8 = "",
    report: []const u8 = "",
    table: []const u8 = "",
    shards: []const []const u8 = &.{},
};

fn parseArgs(arena: std.mem.Allocator, process_args: std.process.Args) !Cli {
    const args = try process_args.toSlice(arena);
    std.debug.assert(args.len >= 1);
    var cli = Cli{};
    var shards: std.ArrayList([]const u8) = .empty;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        const target: ?*[]const u8 = if (std.mem.eql(u8, arg, "--weights"))
            &cli.weights
        else if (std.mem.eql(u8, arg, "--report"))
            &cli.report
        else if (std.mem.eql(u8, arg, "--table"))
            &cli.table
        else
            null;
        if (target) |value| {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            value.* = args[index];
        } else {
            try shards.append(arena, arg);
        }
    }
    if (cli.weights.len == 0 or cli.report.len == 0 or cli.table.len == 0)
        return error.MissingArgument;
    if (shards.items.len == 0 or shards.items.len > balance.max_shards)
        return error.InvalidShardCount;
    cli.shards = shards.items;
    std.debug.assert(cli.shards.len > 0);
    std.debug.assert(cli.shards.len <= balance.max_shards);
    std.debug.assert(cli.weights.len > 0);
    std.debug.assert(cli.report.len > 0);
    std.debug.assert(cli.table.len > 0);
    return cli;
}

fn run(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cli = try parseArgs(arena, init.minimal.args);
    const cwd = std.Io.Dir.cwd();
    const table_limit: std.Io.Limit = .limited(balance.max_table_bytes);
    const table_text = try cwd.readFileAlloc(fs_io, cli.weights, arena, table_limit);
    const table = try balance.parse(
        table_text,
        try arena.alloc([]const u8, balance.max_tests),
        try arena.alloc(u64, balance.max_tests),
    );
    std.debug.assert(table.names.len == table.micros.len);
    const parsed = try arena.alloc(rows.Parsed, cli.shards.len);
    for (cli.shards, parsed) |path, *shard| {
        const text = try cwd.readFileAlloc(fs_io, path, arena, .limited(max_rows_bytes));
        shard.* = try rows.parse(
            text,
            try arena.alloc(rows.Warmup, balance.max_tests),
            try arena.alloc(rows.Record, balance.max_tests),
        );
    }
    std.debug.assert(parsed.len == cli.shards.len);
    const merged = try verify(arena, parsed);
    std.debug.assert(merged.len == parsed[0].shard.selected);
    try writeFile(cwd, cli.report, arena, merged, &table, parsed, .report);
    try writeFile(cwd, cli.table, arena, merged, &table, parsed, .table);
}

/// One executed test with the shard that ran it.
pub const Entry = struct {
    record: rows.Record,
    shard: usize,

    fn total(self: Entry) u64 {
        std.debug.assert(self.shard < balance.max_shards);
        return self.record.test_ns +| self.record.teardown_ns;
    }
};

pub const VerifyError = error{
    ShardCountMismatch,
    DuplicateShard,
    SelectionMismatch,
    CoverageMismatch,
    DuplicateTest,
};

/// Checks that the shards form one complete run and returns every executed test, sorted
/// by name.
pub fn verify(
    arena: std.mem.Allocator,
    shards: []const rows.Parsed,
) (VerifyError || std.mem.Allocator.Error)![]Entry {
    std.debug.assert(shards.len > 0);
    std.debug.assert(shards.len <= balance.max_shards);
    var present: [balance.max_shards]bool = @splat(false);
    const selected = shards[0].shard.selected;
    var executed: usize = 0;
    for (shards) |shard| {
        if (shard.shard.count != shards.len) return error.ShardCountMismatch;
        if (present[shard.shard.index]) return error.DuplicateShard;
        present[shard.shard.index] = true;
        if (shard.shard.selected != selected) return error.SelectionMismatch;
        executed += shard.records.len;
    }
    if (executed != selected) return error.CoverageMismatch;
    std.debug.assert(executed <= balance.max_tests);
    const entries = try arena.alloc(Entry, executed);
    errdefer arena.free(entries);
    var cursor: usize = 0;
    for (shards) |shard| for (shard.records) |record| {
        entries[cursor] = .{ .record = record, .shard = shard.shard.index };
        cursor += 1;
    };
    std.debug.assert(cursor == entries.len);
    std.sort.pdq(Entry, entries, {}, byName);
    if (entries.len > 1) for (entries[1..], entries[0 .. entries.len - 1]) |next, previous| {
        if (std.mem.eql(u8, next.record.name, previous.record.name)) return error.DuplicateTest;
    };
    for (present[0..shards.len]) |seen| std.debug.assert(seen);
    return entries;
}

fn byName(_: void, a: Entry, b: Entry) bool {
    std.debug.assert(a.record.name.len > 0);
    std.debug.assert(b.record.name.len > 0);
    return std.mem.order(u8, a.record.name, b.record.name) == .lt;
}

fn byTotalDescending(_: void, a: Entry, b: Entry) bool {
    std.debug.assert(a.record.name.len > 0);
    std.debug.assert(b.record.name.len > 0);
    if (a.total() != b.total()) return a.total() > b.total();
    return std.mem.order(u8, a.record.name, b.record.name) == .lt;
}

fn writeFile(
    dir: std.Io.Dir,
    path: []const u8,
    arena: std.mem.Allocator,
    entries: []const Entry,
    table: *const balance.Table,
    shards: []const rows.Parsed,
    output: enum { report, table },
) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(shards.len > 0);
    std.debug.assert(shards.len <= balance.max_shards);
    var file = try dir.createFile(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(fs_io, &buffer);
    switch (output) {
        .report => try writeReport(&writer.interface, arena, entries, table, shards),
        .table => try writeTable(&writer.interface, entries, shards),
    }
    try writer.interface.flush();
}

fn failed(status: []const u8) bool {
    std.debug.assert(status.len > 0);
    return !std.mem.eql(u8, status, "ok") and !std.mem.eql(u8, status, "skip");
}

/// Writes the per-shard balance, the unweighted tests, every test by total time, and the
/// serial runner's summary line.
pub fn writeReport(
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    entries: []const Entry,
    table: *const balance.Table,
    shards: []const rows.Parsed,
) !void {
    std.debug.assert(shards.len > 0);
    std.debug.assert(shards.len <= balance.max_shards);
    std.debug.assert(entries.len <= balance.max_tests);
    try out.print("merged timing: {d} shards, {d} tests\n", .{ shards.len, entries.len });
    for (0..shards.len) |index| {
        const shard = for (shards) |candidate| {
            if (candidate.shard.index == index) break candidate;
        } else unreachable;
        try writeShardLine(out, entries, table, shard);
    }
    var unweighted: usize = 0;
    for (entries) |entry| {
        if (table.find(entry.record.name) != null) continue;
        if (unweighted == 0) try out.writeAll("unweighted tests:\n");
        unweighted += 1;
        try out.print("  {s}\n", .{entry.record.name});
    }
    const ranked = try arena.dupe(Entry, entries);
    std.sort.pdq(Entry, ranked, {}, byTotalDescending);
    try out.print("per-test timing: {d} tests sorted by total duration\n", .{ranked.len});
    var ok: usize = 0;
    var skipped: usize = 0;
    var failures: usize = 0;
    var total_ns: u64 = 0;
    for (ranked, 1..) |entry, rank| {
        total_ns +|= entry.total();
        if (std.mem.eql(u8, entry.record.status, "ok")) ok += 1;
        if (std.mem.eql(u8, entry.record.status, "skip")) skipped += 1;
        if (failed(entry.record.status)) failures += 1;
        try out.print("  {d}. {s}: total={d} us; status={s}; shard={d}\n", .{
            rank,
            entry.record.name,
            entry.total() / std.time.ns_per_us,
            entry.record.status,
            entry.shard + 1,
        });
    }
    std.debug.assert(ok + skipped + failures == ranked.len);
    try out.print("test timing: total={d} ms; ok={d}; skip={d}; fail={d}; count={d}\n", .{
        total_ns / std.time.ns_per_ms,
        ok,
        skipped,
        failures,
        ranked.len,
    });
}

/// Writes one shard's predicted and actual time. Predicted is the per-shard constant plus
/// the table weight of every test the shard ran. Actual includes the shard's warmups.
fn writeShardLine(
    out: *std.Io.Writer,
    entries: []const Entry,
    table: *const balance.Table,
    shard: rows.Parsed,
) !void {
    std.debug.assert(shard.shard.index < shard.shard.count);
    std.debug.assert(shard.records.len <= entries.len);
    var warmup_ns: u64 = 0;
    for (shard.warmups) |warmup| warmup_ns +|= warmup.ns;
    var actual_ns: u64 = warmup_ns;
    var predicted_us: u64 = table.shard_us;
    for (shard.records) |record| {
        actual_ns +|= record.test_ns +| record.teardown_ns;
        predicted_us +|= table.weight(record.name);
    }
    std.debug.assert(actual_ns >= warmup_ns);
    const actual_us = actual_ns / std.time.ns_per_us;
    const stale = actual_us *| 100 > predicted_us *| stale_percent;
    try out.print("shard {d}/{d}: predicted={d} ms; actual={d} ms; " ++
        "warmup={d} ms; tests={d}{s}\n", .{
        shard.shard.index + 1,
        shard.shard.count,
        predicted_us / std.time.us_per_ms,
        actual_us / std.time.us_per_ms,
        warmup_ns / std.time.ns_per_ms,
        shard.records.len,
        if (stale) "; stale" else "",
    });
}

/// Writes a weights table from this run: every test's measured microseconds, and the
/// slowest shard's warmup as the per-shard constant.
pub fn writeTable(out: *std.Io.Writer, entries: []const Entry, shards: []const rows.Parsed) !void {
    std.debug.assert(shards.len > 0);
    std.debug.assert(shards.len <= balance.max_shards);
    std.debug.assert(entries.len <= balance.max_tests);
    var shard_ns: u64 = 0;
    for (shards) |shard| {
        var warmup_ns: u64 = 0;
        for (shard.warmups) |warmup| warmup_ns +|= warmup.ns;
        shard_ns = @max(shard_ns, warmup_ns);
    }
    try out.print("{s}\t{d}\n", .{ balance.header, shard_ns / std.time.ns_per_us });
    for (entries) |entry| {
        std.debug.assert(entry.shard < shards.len);
        try out.print("{s}\t{d}\n", .{ entry.record.name, entry.total() / std.time.ns_per_us });
    }
}

fn shardOf(index: usize, count: usize, selected: usize, records: []const rows.Record) rows.Parsed {
    std.debug.assert(index < count);
    return .{
        .shard = .{ .index = index, .count = count, .selected = selected },
        .warmups = &.{},
        .records = records,
    };
}

test "verify accepts a complete disjoint run and orders it by name" {
    const first = [_]rows.Record{.{ .status = "ok", .test_ns = 5, .teardown_ns = 0, .name = "b" }};
    const second = [_]rows.Record{
        .{ .status = "ok", .test_ns = 7, .teardown_ns = 1, .name = "c" },
        .{ .status = "skip", .test_ns = 0, .teardown_ns = 0, .name = "a" },
    };
    const shards = [_]rows.Parsed{ shardOf(1, 2, 3, &second), shardOf(0, 2, 3, &first) };
    const entries = try verify(std.testing.allocator, &shards);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqualStrings("a", entries[0].record.name);
    try std.testing.expectEqual(@as(usize, 0), entries[1].shard);
    try std.testing.expectEqual(@as(usize, 1), entries[2].shard);
}

test "verify refuses a missing, duplicated or foreign shard and a partial or repeated test" {
    const one = [_]rows.Record{.{ .status = "ok", .test_ns = 1, .teardown_ns = 0, .name = "a" }};
    const other = [_]rows.Record{.{ .status = "ok", .test_ns = 1, .teardown_ns = 0, .name = "b" }};
    const allocator = std.testing.allocator;
    const missing = [_]rows.Parsed{shardOf(0, 2, 1, &one)};
    try std.testing.expectError(error.ShardCountMismatch, verify(allocator, &missing));
    const repeated = [_]rows.Parsed{ shardOf(0, 2, 2, &one), shardOf(0, 2, 2, &other) };
    try std.testing.expectError(error.DuplicateShard, verify(allocator, &repeated));
    const foreign = [_]rows.Parsed{ shardOf(0, 2, 2, &one), shardOf(1, 2, 3, &other) };
    try std.testing.expectError(error.SelectionMismatch, verify(allocator, &foreign));
    const partial = [_]rows.Parsed{ shardOf(0, 2, 3, &one), shardOf(1, 2, 3, &other) };
    try std.testing.expectError(error.CoverageMismatch, verify(allocator, &partial));
    const twice = [_]rows.Parsed{ shardOf(0, 2, 2, &one), shardOf(1, 2, 2, &one) };
    try std.testing.expectError(error.DuplicateTest, verify(allocator, &twice));
}

test "the report keeps the serial summary line and flags a stale shard" {
    const records = [_]rows.Record{
        .{ .status = "ok", .test_ns = 3 * std.time.ns_per_ms, .teardown_ns = 0, .name = "slow" },
        .{ .status = "fail", .test_ns = std.time.ns_per_ms, .teardown_ns = 0, .name = "new" },
    };
    const warmups = [_]rows.Warmup{.{ .name = "kernel", .ns = std.time.ns_per_ms }};
    const shards = [_]rows.Parsed{.{
        .shard = .{ .index = 0, .count = 1, .selected = 2 },
        .warmups = &warmups,
        .records = &records,
    }};
    const names = [_][]const u8{"slow"};
    const micros = [_]u64{1000};
    const table = balance.Table{ .names = &names, .micros = &micros };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = try verify(arena_state.allocator(), &shards);
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeReport(&writer, arena_state.allocator(), entries, &table, &shards);
    const text = writer.buffered();
    const shard_line = "shard 1/1: predicted=2 ms; actual=5 ms; warmup=1 ms; tests=2; stale\n";
    try std.testing.expect(std.mem.indexOf(u8, text, shard_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unweighted tests:\n  new\n") != null);
    const summary = "test timing: total=4 ms; ok=1; skip=0; fail=1; count=2\n";
    try std.testing.expect(std.mem.endsWith(u8, text, summary));
    var table_buffer: [256]u8 = undefined;
    var table_writer: std.Io.Writer = .fixed(&table_buffer);
    try writeTable(&table_writer, entries, &shards);
    const expected_table = balance.header ++ "\t1000\nnew\t1000\nslow\t3000\n";
    try std.testing.expectEqualStrings(expected_table, table_writer.buffered());
}
