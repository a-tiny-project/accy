const std = @import("std");
const alloc_phase = @import("alloc_phase");
const namespace_owner = @import("root.zig");

const Capacity = namespace_owner.Capacity;
const Census = namespace_owner.Census;
const Limits = namespace_owner.Limits;
const Storage = namespace_owner.Storage;

fn testLimits() Limits {
    return .{
        .categories = 3,
        .label_bytes = 64,
        .joined_label_bytes = 64,
    };
}

test "Bounded Census summary and JSONL output preserve aggregate semantics" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "memtrace_census_output"),
        );
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const capacity = try Capacity.derive(testLimits());
    var storage = try Storage.init(counting.allocator(), testLimits());
    defer storage.deinit(counting.allocator());
    storage.activate();
    var census = try Census.init(&storage);
    defer census.deinit();

    try census.record("runtime.dictionary", 40);
    try census.record("runtime.dictionary", 2);
    try census.recordCount("runtime.string", 3, 9);
    try census.recordPrefixed("global.page.", "runtime.record", 4);

    var summary_bytes: [1024]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_bytes);
    try census.writeSummary(&summary, .{ .top = 8 });
    const text = summary.buffered();
    const expected_summary =
        "memtrace census categories=3\n" ++
        "runtime.dictionary items=2 bytes=42\n" ++
        "runtime.string items=3 bytes=9\n" ++
        "global.page.runtime.record items=1 bytes=4\n";
    try std.testing.expectEqualStrings(expected_summary, text);

    var jsonl_bytes: [1024]u8 = undefined;
    var jsonl = std.Io.Writer.fixed(&jsonl_bytes);
    try census.writeJsonl(&jsonl);
    const expected_jsonl =
        "{\"v\":3,\"seq\":1,\"kind\":\"census\"," ++
        "\"label\":\"global.page.runtime.record\",\"items\":1,\"bytes\":4}\n" ++
        "{\"v\":3,\"seq\":2,\"kind\":\"census\"," ++
        "\"label\":\"runtime.string\",\"items\":3,\"bytes\":9}\n" ++
        "{\"v\":3,\"seq\":3,\"kind\":\"census\"," ++
        "\"label\":\"runtime.dictionary\",\"items\":2,\"bytes\":42}\n";
    try std.testing.expectEqualStrings(expected_jsonl, jsonl.buffered());
    try std.testing.expectEqual(@as(usize, 3), census.status().categories);
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try std.testing.expectEqual(capacity.storage_bytes, counting.allocated_bytes);
}

test "Census rejects each storage dimension at max plus one before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "memtrace_census_boundary"),
        );
    }

    var storage = try Storage.init(std.testing.allocator, .{
        .categories = 2,
        .label_bytes = 5,
        .joined_label_bytes = 3,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    var census = try Census.init(&storage);
    defer census.deinit();

    try census.record("ab", 1);
    try census.recordPrefixed("a", "bc", 2);
    const first = census.status();
    try std.testing.expectError(
        error.JoinedLabelCapacityExceeded,
        census.recordPrefixed("abc", "d", 1),
    );
    try std.testing.expectEqual(first, census.status());

    const full = census.status();
    var full_bytes: [256]u8 = undefined;
    var full_summary = std.Io.Writer.fixed(&full_bytes);
    try census.writeSummary(&full_summary, .{});
    try std.testing.expectError(error.CategoryCapacityExceeded, census.record("f", 3));
    try std.testing.expectEqual(full, census.status());
    var rejected_bytes: [256]u8 = undefined;
    var rejected_summary = std.Io.Writer.fixed(&rejected_bytes);
    try census.writeSummary(&rejected_summary, .{});
    try std.testing.expectEqualSlices(u8, full_summary.buffered(), rejected_summary.buffered());

    var label_storage = try Storage.init(std.testing.allocator, .{
        .categories = 2,
        .label_bytes = 2,
        .joined_label_bytes = 2,
    });
    defer label_storage.deinit(std.testing.allocator);
    label_storage.activate();
    var label_census = try Census.init(&label_storage);
    defer label_census.deinit();
    try label_census.record("ab", 1);
    const label_full = label_census.status();
    var label_full_bytes: [128]u8 = undefined;
    var label_full_summary = std.Io.Writer.fixed(&label_full_bytes);
    try label_census.writeSummary(&label_full_summary, .{});
    try std.testing.expectError(error.LabelBytesCapacityExceeded, label_census.record("c", 1));
    try std.testing.expectEqual(label_full, label_census.status());
    var label_rejected_bytes: [128]u8 = undefined;
    var label_rejected_summary = std.Io.Writer.fixed(&label_rejected_bytes);
    try label_census.writeSummary(&label_rejected_summary, .{});
    try std.testing.expectEqualSlices(
        u8,
        label_full_summary.buffered(),
        label_rejected_summary.buffered(),
    );
}

test "Census rejects aggregate counter overflow before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "memtrace_census_overflow"),
        );
    }

    var storage = try Storage.init(std.testing.allocator, .{
        .categories = 1,
        .label_bytes = 1,
        .joined_label_bytes = 0,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    var census = try Census.init(&storage);
    defer census.deinit();

    try census.recordCount("x", std.math.maxInt(usize), std.math.maxInt(usize));
    const before = census.status();
    var before_bytes: [128]u8 = undefined;
    var before_summary = std.Io.Writer.fixed(&before_bytes);
    try census.writeSummary(&before_summary, .{});
    try std.testing.expectError(error.CensusCounterOverflow, census.record("x", 0));
    try std.testing.expectEqual(before, census.status());
    var after_bytes: [128]u8 = undefined;
    var after_summary = std.Io.Writer.fixed(&after_bytes);
    try census.writeSummary(&after_summary, .{});
    try std.testing.expectEqualSlices(u8, before_summary.buffered(), after_summary.buffered());
}

test "Census open addressing fills every admitted category" {
    const category_capacity = 32;
    var storage = try Storage.init(std.testing.allocator, .{
        .categories = category_capacity,
        .label_bytes = category_capacity * 4,
        .joined_label_bytes = 0,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    var census = try Census.init(&storage);
    defer census.deinit();

    for (0..category_capacity) |index| {
        var label_bytes: [4]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_bytes, "x{d:0>2}", .{index});
        try census.record(label, index);
    }
    for (0..category_capacity) |index| {
        var label_bytes: [4]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_bytes, "x{d:0>2}", .{index});
        try census.record(label, 1);
    }
    try std.testing.expectEqual(@as(usize, category_capacity), census.status().categories);
    try std.testing.expectEqual(
        @as(usize, category_capacity * 3),
        census.status().label_bytes_used,
    );
}

test "Census storage rejects concurrent acquisition and resets for reuse" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "memtrace_census_reuse"),
        );
    }

    var storage = try Storage.init(std.testing.allocator, testLimits());
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    var first = try Census.init(&storage);
    try first.record("old", 7);
    try std.testing.expectError(error.CensusStorageInUse, Census.init(&storage));
    first.deinit();

    var reused = try Census.init(&storage);
    defer reused.deinit();
    try std.testing.expectEqual(@as(usize, 0), reused.status().categories);
    try reused.record("new", 11);
    try std.testing.expectEqual(@as(usize, 1), reused.status().categories);
}

test "Maximum Census recording and output make no backing allocation after sealing" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "memtrace_census_sealed"),
        );
    }

    var sealed = try alloc_phase.SealedPhaseAllocator.init(std.testing.allocator);
    var storage = try Storage.init(sealed.initializationAllocator(), .{
        .categories = 3,
        .label_bytes = 6,
        .joined_label_bytes = 3,
    });
    storage.activate();
    var census = try Census.init(&storage);
    sealed.seal();

    try census.record("aa", 1);
    try census.recordCount("bb", 2, 3);
    try census.recordCountPrefixed("c", "c", 4, 5);
    try census.record("aa", 7);
    var summary_bytes: [512]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_bytes);
    try census.writeSummary(&summary, .{});
    var jsonl_bytes: [512]u8 = undefined;
    var jsonl = std.Io.Writer.fixed(&jsonl_bytes);
    try census.writeJsonl(&jsonl);
    try std.testing.expectEqual(@as(usize, 3), census.status().categories);
    try std.testing.expect(summary.buffered().len > 0);
    try std.testing.expect(jsonl.buffered().len > 0);

    census.deinit();
    sealed.beginTeardown();
    storage.deinit(sealed.teardownAllocator());
    sealed.deinit();
}
