const std = @import("std");
const pretty = @import("timing_runner_pretty");
const sys = @import("timing_runner_sys");

const options = @import("options.zig");
const semantic = @import("semantic.zig");
const execution = @import("execution.zig");
const pretty_json = pretty.json;

pub const schema = semantic.schema;
const maximum_token_bytes: usize = 128;
const maximum_receipt_bytes: usize = 4 * 1024 * 1024;

pub const Status = execution.Status;
pub const Row = execution.Row;

pub const Counts = struct {
    selected: usize,
    ok: usize,
    skipped: usize,
    failed: usize,
};

const Config = struct {
    directory: []const u8,
    token: []const u8,
    shard_count: usize,
    shard_index: usize,
};

const CompletionReceipt = struct {
    schema: []const u8,
    token: []const u8,
    selected_test_count: usize,
    executed_test_count: usize,
    failed_test_count: usize,
};

pub const RunCompletion = struct {
    failed: usize,
};

pub fn reset(
    allocator: std.mem.Allocator,
    directory: []const u8,
    token: []const u8,
) !void {
    try validateToken(token);
    try sys.fs.createDirPath(directory);
    const entries = try sys.fs.listDirAlloc(allocator, directory);
    defer sys.fs.freeEntries(allocator, entries);
    for (entries) |entry| if (runFile(entry.name, token, true)) {
        try sys.fs.deleteFile(entry.path);
    };
}

pub fn completion(
    allocator: std.mem.Allocator,
    directory: []const u8,
    token: []const u8,
    selected: usize,
) !?RunCompletion {
    try validateToken(token);
    const entries = try sys.fs.listDirAlloc(allocator, directory);
    defer sys.fs.freeEntries(allocator, entries);
    var path: ?[]const u8 = null;
    for (entries) |entry| {
        if (!runFile(entry.name, token, false)) continue;
        if (path != null) return error.DuplicateTimingReceipt;
        path = entry.path;
    }
    const final_path = path orelse return null;
    const text = try sys.fs.readFileAlloc(
        allocator,
        final_path,
        maximum_receipt_bytes,
    );
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(CompletionReceipt, allocator, text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const complete = std.mem.eql(u8, parsed.value.schema, schema) and
        std.mem.eql(u8, parsed.value.token, token) and
        parsed.value.selected_test_count == selected and
        parsed.value.executed_test_count == selected;
    if (!complete) return null;
    return .{ .failed = parsed.value.failed_test_count };
}

pub fn write(
    environ: sys.process.Environ,
    started_unix_ns: i128,
    finished_unix_ns: i128,
    counts: Counts,
    rows: []const Row,
) !void {
    const config = try loadConfig(environ) orelse return;
    try sys.fs.createDirPath(config.directory);
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "{s}/{s}-{d}-{d}.json",
        .{
            config.directory,
            config.token,
            started_unix_ns,
            config.shard_index,
        },
    );
    var pending_storage: [std.fs.max_path_bytes]u8 = undefined;
    const pending = try std.fmt.bufPrint(
        &pending_storage,
        "{s}.pending",
        .{path},
    );
    defer sys.fs.deleteFile(pending) catch {};
    var file = try sys.fs.createFile(pending, .{ .truncate = true });
    var open = true;
    defer if (open) file.close(sys.fs.debugIo());
    var buffer: [32 * 1024]u8 = undefined;
    var writer = file.writer(sys.fs.debugIo(), &buffer);
    var out = pretty_json.Writer.init(&writer.interface, .minified);
    try writeJson(
        &out,
        config,
        started_unix_ns,
        finished_unix_ns,
        counts,
        rows,
    );
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    file.close(sys.fs.debugIo());
    open = false;
    try sys.fs.rename(pending, path);
}

fn loadConfig(environ: sys.process.Environ) !?Config {
    const directory = sys.process.Environ.getPosix(
        environ,
        options.directory_environment,
    ) orelse return null;
    const token = sys.process.Environ.getPosix(
        environ,
        options.token_environment,
    ) orelse return error.MissingTimingReceiptToken;
    if (directory.len == 0 or directory.len >= std.fs.max_path_bytes) {
        return error.InvalidTimingReceiptDirectory;
    }
    try validateToken(token);
    const shard_count = try parseShard(
        sys.process.Environ.getPosix(
            environ,
            options.shard_count_environment,
        ) orelse "1",
    );
    const shard_index = try parseIndex(
        sys.process.Environ.getPosix(
            environ,
            options.shard_index_environment,
        ) orelse "0",
        shard_count,
    );
    return .{
        .directory = directory,
        .token = token,
        .shard_count = shard_count,
        .shard_index = shard_index,
    };
}

fn validateToken(token: []const u8) !void {
    if (token.len == 0 or token.len > maximum_token_bytes) {
        return error.InvalidTimingReceiptToken;
    }
    for (token) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-')
        {
            return error.InvalidTimingReceiptToken;
        }
    }
}

fn runFile(name: []const u8, token: []const u8, include_pending: bool) bool {
    if (!std.mem.startsWith(u8, name, token) or name.len <= token.len or
        name[token.len] != '-')
    {
        return false;
    }
    return std.mem.endsWith(u8, name, ".json") or
        (include_pending and std.mem.endsWith(u8, name, ".json.pending"));
}

fn parseShard(value: []const u8) !usize {
    const count = std.fmt.parseUnsigned(usize, value, 10) catch
        return error.InvalidTimingReceiptShardCount;
    if (count == 0 or count > 32) {
        return error.InvalidTimingReceiptShardCount;
    }
    return count;
}

fn parseIndex(value: []const u8, count: usize) !usize {
    const index = std.fmt.parseUnsigned(usize, value, 10) catch
        return error.InvalidTimingReceiptShardIndex;
    if (index >= count) return error.InvalidTimingReceiptShardIndex;
    return index;
}

fn writeJson(
    out: *pretty_json.Writer,
    config: Config,
    started_unix_ns: i128,
    finished_unix_ns: i128,
    counts: Counts,
    rows: []const Row,
) !void {
    const digest = semantic.digest(rows);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var total_test_ns: i128 = 0;
    var total_teardown_ns: i128 = 0;
    for (rows) |row| {
        total_test_ns += row.test_ns;
        total_teardown_ns += row.teardown_ns;
    }
    try out.beginObject();
    try field(out, "schema", schema);
    try field(out, "token", config.token);
    try field(out, "zig_version", @import("builtin").zig_version_string);
    try field(out, "started_unix_ns", started_unix_ns);
    try field(out, "finished_unix_ns", finished_unix_ns);
    try field(out, "shard_count", config.shard_count);
    try field(out, "shard_index", config.shard_index);
    try field(out, "selected_test_count", counts.selected);
    try field(out, "executed_test_count", rows.len);
    try field(out, "passed_test_count", counts.ok);
    try field(out, "skipped_test_count", counts.skipped);
    try field(out, "failed_test_count", counts.failed);
    try field(out, "test_ns_observed", total_test_ns);
    try field(out, "teardown_ns_observed", total_teardown_ns);
    try field(out, "semantic_sha256", hex[0..]);
    try out.objectField("tests");
    try out.beginArray();
    for (rows) |row| {
        try out.beginObject();
        try field(out, "name", row.name);
        try field(out, "status", @tagName(row.status));
        try field(out, "leaked", row.leaked);
        try field(out, "test_ns_observed", row.test_ns);
        try field(out, "teardown_ns_observed", row.teardown_ns);
        try out.endObject();
    }
    try out.endArray();
    try out.endObject();
}

fn field(
    out: *pretty_json.Writer,
    name: []const u8,
    value: anytype,
) !void {
    try out.objectField(name);
    try out.write(value);
}
