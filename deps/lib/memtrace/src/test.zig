const std = @import("std");
const alloc_phase = @import("alloc_phase");
const census_test = @import("census/test.zig");
const stack_test = @import("stack/test.zig");
const namespace_owner = @import("root.zig");

const Census = namespace_owner.Census;
const CensusCapacity = namespace_owner.CensusCapacity;
const CensusLimits = namespace_owner.CensusLimits;
const CensusStorage = namespace_owner.CensusStorage;

test "memtrace: package namespace" {
    std.testing.refAllDecls(namespace_owner);
    _ = census_test;
    _ = stack_test;
}

test "Memtrace root composes caller-selected Census limits and storage" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./census/root.zig").Storage, "memtrace_census_root"),
        );
    }

    const limits = CensusLimits{
        .categories = 2,
        .label_bytes = 16,
        .joined_label_bytes = 8,
    };
    const capacity = try CensusCapacity.derive(limits);
    var storage = try CensusStorage.init(std.testing.allocator, limits);
    defer storage.deinit(std.testing.allocator);
    try std.testing.expectEqual(capacity.storage_bytes, storage.status().storage_bytes);
    storage.activate();
    var actual = try Census.init(&storage);
    defer actual.deinit();
    try actual.record("root", 4);
    try std.testing.expectEqual(@as(usize, 1), actual.status().categories);
}
