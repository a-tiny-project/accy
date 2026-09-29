const std = @import("std");
const hypothesis = @import("hypothesis");

const Allocator = std.mem.Allocator;
const ConjectureData = hypothesis.ConjectureData;
const ChoiceNode = hypothesis.ChoiceNode;
const ReplayCursor = hypothesis.database.ReplayCursor;
const Sha256 = std.crypto.hash.sha2.Sha256;

const maximum_failures: usize = 12;
const maximum_noise: usize = 12;
const digest_text_bytes: usize = Sha256.digest_length * 2;
const failure_extension = ".jhyp";
const failure_name_bytes: usize = digest_text_bytes + failure_extension.len;
const FailureName = [failure_name_bytes]u8;

const ModelEntry = struct {
    name: FailureName,
    value: u64,
    valid: bool = true,
};

const CursorModelProperty = struct {
    pub fn property(data: *ConjectureData, allocator: Allocator) !void {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
        defer allocator.free(path);
        const count: usize = @intCast(try data.drawInteger(1, maximum_failures, 1));
        var blocks: [maximum_failures]u8 = undefined;
        for (blocks[0..count]) |*byte| {
            byte.* = @intCast(try data.drawInteger(0, 255, 0));
        }
        try saveFailures(allocator, path, blocks[0..count]);
        var model: [maximum_failures]ModelEntry = undefined;
        try inspectModel(allocator, tmp.dir, model[0..count]);
        std.mem.sort(ModelEntry, model[0..count], {}, modelLessThan);
        const mask_limit = (@as(u16, 1) << @intCast(count)) - 1;
        const corrupt_mask: u16 = @intCast(try data.drawInteger(0, mask_limit, 0));
        try corruptSelected(allocator, tmp.dir, model[0..count], corrupt_mask);

        var cursor = try ReplayCursor.init(allocator, .{
            .db_path = path,
            .namespace = null,
            .max_entries = count,
            .max_choices = 1,
            .max_byte_blocks = 1,
        });
        defer cursor.deinit(allocator);
        cursor.activate();
        var expected_index: usize = 0;
        while (try cursor.next()) |failure| {
            while (expected_index < count and !model[expected_index].valid) {
                expected_index += 1;
            }
            try std.testing.expect(expected_index < count);
            try std.testing.expectEqual(model[expected_index].value, failure.choices[0].value);
            expected_index += 1;
        }
        while (expected_index < count and !model[expected_index].valid) expected_index += 1;
        try std.testing.expectEqual(count, expected_index);
        try std.testing.expectEqual(
            @as(usize, @popCount(corrupt_mask)),
            cursor.status().failures_rejected,
        );
    }
};

const ScanBudgetProperty = struct {
    pub fn property(data: *ConjectureData, allocator: Allocator) !void {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
        defer allocator.free(path);
        const failures: usize = @intCast(try data.drawInteger(1, maximum_failures, 1));
        const noise: usize = @intCast(try data.drawInteger(0, maximum_noise, 0));
        var blocks: [maximum_failures]u8 = undefined;
        @memset(blocks[0..failures], 0);
        try saveFailures(allocator, path, blocks[0..failures]);
        try writeNoise(tmp.dir, noise);
        const total = failures + noise;
        const budget: usize = @intCast(try data.drawInteger(0, total, 0));
        var cursor = try ReplayCursor.init(allocator, .{
            .db_path = path,
            .namespace = null,
            .max_entries = budget,
            .max_choices = 1,
            .max_byte_blocks = 1,
        });
        defer cursor.deinit(allocator);
        cursor.activate();
        var loaded: usize = 0;
        while (try cursor.next()) |_| loaded += 1;
        const status = cursor.status();
        try std.testing.expectEqual(budget, status.entries_scanned);
        try std.testing.expect(status.candidate_files <= budget);
        try std.testing.expect(loaded <= budget);
        try std.testing.expectEqual(budget > 0, status.scan_budget_saturated);
    }
};

fn saveFailures(allocator: Allocator, path: []const u8, blocks: []const u8) !void {
    for (blocks, 0..) |byte, index| {
        const choice = ChoiceNode{
            .kind = .integer,
            .value = index + 1,
            .min = 0,
            .max = maximum_failures,
        };
        try hypothesis.database.saveFailure(allocator, path, null, &.{choice}, &.{byte});
    }
}

fn inspectModel(allocator: Allocator, dir: std.Io.Dir, model: []ModelEntry) !void {
    var directory = try dir.openDir(std.Options.debug_io, ".", .{ .iterate = true });
    defer directory.close(std.Options.debug_io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file or entry.name.len != failure_name_bytes) continue;
        const encoded = try directory.readFileAlloc(
            std.Options.debug_io,
            entry.name,
            allocator,
            .limited(1024),
        );
        defer allocator.free(encoded);
        var name: FailureName = undefined;
        @memcpy(&name, entry.name);
        model[count] = .{
            .name = name,
            .value = std.mem.readInt(u64, encoded[24..32], .little),
        };
        count += 1;
    }
    try std.testing.expectEqual(model.len, count);
}

fn corruptSelected(
    allocator: Allocator,
    dir: std.Io.Dir,
    model: []ModelEntry,
    mask: u16,
) !void {
    for (model, 0..) |*entry, index| {
        if (mask & (@as(u16, 1) << @intCast(index)) == 0) continue;
        const encoded = try dir.readFileAlloc(
            std.Options.debug_io,
            &entry.name,
            allocator,
            .limited(1024),
        );
        defer allocator.free(encoded);
        encoded[0] ^= 0xff;
        try dir.writeFile(std.Options.debug_io, .{
            .sub_path = &entry.name,
            .data = encoded,
        });
        entry.valid = false;
    }
}

fn writeNoise(dir: std.Io.Dir, count: usize) !void {
    for (0..count) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "noise-{d}", .{index});
        try dir.writeFile(std.Options.debug_io, .{ .sub_path = name, .data = "noise" });
    }
}

fn modelLessThan(_: void, left: ModelEntry, right: ModelEntry) bool {
    return std.mem.order(u8, &left.name, &right.name) == .lt;
}

test "fuzz: replay cursor matches sorted corruption model" {
    try hypothesis.checkNamed(CursorModelProperty, "hypothesis-replay-cursor-model", .{
        .max_examples = 32,
        .max_replays = 0,
        .target_examples = 0,
        .report_failure = false,
        .seed = 0x4859_5043_5552_534f,
    });
}

test "fuzz: every directory entry consumes replay scan budget" {
    try hypothesis.checkNamed(ScanBudgetProperty, "hypothesis-replay-scan-budget", .{
        .max_examples = 32,
        .max_replays = 0,
        .target_examples = 0,
        .report_failure = false,
        .seed = 0x4859_5053_4341_4e42,
    });
}
