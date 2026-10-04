//! One shard's results as the merge step reads them: which shard wrote them, how many tests
//! the binary selected, each warmup's time, and each executed test's status and times in
//! execution order. The runner writes the file inside the cached run; nothing parses the
//! pretty report.
const std = @import("std");
const balance = @import("balance.zig");

pub const header = "tiny-timing-rows-v1";

pub const Shard = struct {
    index: usize,
    count: usize,
    selected: usize,
};

pub const Warmup = struct {
    name: []const u8,
    ns: u64,
};

pub const Record = struct {
    status: []const u8,
    test_ns: u64,
    teardown_ns: u64,
    name: []const u8,
};

pub fn writeHeader(writer: *std.Io.Writer, shard: Shard) !void {
    std.debug.assert(shard.index < shard.count);
    std.debug.assert(shard.count <= balance.max_shards);
    std.debug.assert(shard.selected <= balance.max_tests);
    try writer.print("{s}\t{d}\t{d}\t{d}\n", .{ header, shard.index, shard.count, shard.selected });
}

pub fn writeWarmup(writer: *std.Io.Writer, warmup: Warmup) !void {
    std.debug.assert(warmup.name.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, warmup.name, '\n') == null);
    try writer.print("warmup\t{d}\t{s}\n", .{ warmup.ns, warmup.name });
}

pub fn writeRecord(writer: *std.Io.Writer, record: Record) !void {
    std.debug.assert(record.name.len > 0);
    std.debug.assert(record.status.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, record.name, '\n') == null);
    std.debug.assert(std.mem.indexOfScalar(u8, record.status, '\t') == null);
    std.debug.assert(std.mem.indexOfScalar(u8, record.status, '\n') == null);
    try writer.print("test\t{s}\t{d}\t{d}\t{s}\n", .{
        record.status,
        record.test_ns,
        record.teardown_ns,
        record.name,
    });
}

pub const ParseError = error{ MissingHeader, InvalidHeader, InvalidLine, TooManyRecords };

pub const Parsed = struct {
    shard: Shard,
    warmups: []const Warmup,
    records: []const Record,
};

/// Parses one rows file. Names and statuses borrow `text`. Storage bounds the lines.
pub fn parse(text: []const u8, warmups: []Warmup, records: []Record) ParseError!Parsed {
    std.debug.assert(warmups.len <= balance.max_tests);
    std.debug.assert(records.len <= balance.max_tests);
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next().?;
    if (first.len == 0) return error.MissingHeader;
    var fields = std.mem.splitScalar(u8, first, '\t');
    if (!std.mem.eql(u8, fields.next() orelse "", header)) return error.InvalidHeader;
    const shard = Shard{
        .index = try number(fields.next(), error.InvalidHeader),
        .count = try number(fields.next(), error.InvalidHeader),
        .selected = try number(fields.next(), error.InvalidHeader),
    };
    if (fields.next() != null or shard.count == 0 or shard.count > balance.max_shards or
        shard.index >= shard.count) return error.InvalidHeader;
    var warmup_count: usize = 0;
    var record_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.peek() == null) break;
            return error.InvalidLine;
        }
        var parts = std.mem.splitScalar(u8, line, '\t');
        const kind = parts.next().?;
        if (std.mem.eql(u8, kind, "warmup")) {
            if (warmup_count == warmups.len) return error.TooManyRecords;
            const ns = try number(parts.next(), error.InvalidLine);
            warmups[warmup_count] = .{ .ns = ns, .name = parts.rest() };
            warmup_count += 1;
        } else if (std.mem.eql(u8, kind, "test")) {
            if (record_count == records.len) return error.TooManyRecords;
            const status = parts.next() orelse return error.InvalidLine;
            const test_ns = try number(parts.next(), error.InvalidLine);
            const teardown_ns = try number(parts.next(), error.InvalidLine);
            const name = parts.rest();
            if (status.len == 0 or name.len == 0) return error.InvalidLine;
            records[record_count] = .{
                .status = status,
                .test_ns = test_ns,
                .teardown_ns = teardown_ns,
                .name = name,
            };
            record_count += 1;
        } else return error.InvalidLine;
    }
    std.debug.assert(warmup_count <= warmups.len);
    std.debug.assert(record_count <= records.len);
    return .{
        .shard = shard,
        .warmups = warmups[0..warmup_count],
        .records = records[0..record_count],
    };
}

fn number(field: ?[]const u8, comptime failure: anytype) @TypeOf(failure)!u64 {
    const text = field orelse return failure;
    return std.fmt.parseUnsigned(u64, text, 10) catch failure;
}
