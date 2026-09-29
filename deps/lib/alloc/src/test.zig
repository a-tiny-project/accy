const std = @import("std");
const alloc = @import("root.zig");
const alloc_phase = @import("alloc_phase");
const diagnostics = @import("diagnostics.zig");
const policy = @import("policy.zig");

const test_allocator_mode = alloc.test_allocator_mode;
const allocator_diagnostics_mode = alloc.allocator_diagnostics_mode;
const process_phase_mode = alloc.process_phase_mode;
const longLivedProcessAllocator = alloc.longLivedProcessAllocator;
const interactiveSessionAllocator = alloc.interactiveSessionAllocator;
const standaloneProcessAllocator = alloc.standaloneProcessAllocator;
const workerAllocator = alloc.workerAllocator;
const threadedIoAllocator = alloc.threadedIoAllocator;
const temporaryScratchAllocator = alloc.temporaryScratchAllocator;
const testIntegrationAllocator = alloc.testIntegrationAllocator;
const diagnosticAllocatorConfig = alloc.diagnosticAllocatorConfig;
const diagnosticAllocatorReport = alloc.diagnosticAllocatorReport;
const sealProcessAllocatorPhase = alloc.sealProcessAllocatorPhase;
const beginProcessAllocatorTeardown = alloc.beginProcessAllocatorTeardown;
const processAllocatorPhase = alloc.processAllocatorPhase;
const processAllocatorPhaseViolations = alloc.processAllocatorPhaseViolations;
const processAllocatorPhaseViolationSites = alloc.processAllocatorPhaseViolationSites;
const ProcessAllocatorOwner = alloc.ProcessAllocatorOwner;
const ProcessAllocatorFinish = alloc.ProcessAllocatorFinish;
const RegionAllocator = alloc.RegionAllocator;

test "region allocator in-place construction matches Debug defaults and cleans failed capacity" {
    const testing = std.testing;
    const backing = try testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4 << 20);
    defer testing.allocator.free(backing);
    const reference = try testing.allocator.create(RegionAllocator);
    defer testing.allocator.destroy(reference);
    const actual = try testing.allocator.create(RegionAllocator);
    defer testing.allocator.destroy(actual);
    @memset(std.mem.asBytes(reference), 0xaa);
    @memset(std.mem.asBytes(actual), 0xaa);
    const start = @intFromPtr(backing.ptr);
    reference.* = .{
        .base = start,
        .section_bytes = backing.len,
        .reservation_bytes = backing.len,
        .small_zone_bytes = 1 << 20,
        .top = start + 4096,
        .metadata = testing.allocator,
        .discard_pages = false,
    };
    reference.extents[0] = .{ .start = start + (1 << 20), .len = backing.len - (1 << 20) };
    try reference.live.ensureTotalCapacity(testing.allocator, RegionAllocator.maximum_live_allocations);
    try actual.initInPlace(backing.ptr, backing.len, backing.len, 1 << 20, 4096, testing.allocator, false);
    try testing.expectEqual(reference.live.capacity(), actual.live.capacity());
    reference.live.deinit(testing.allocator);
    actual.live.deinit(testing.allocator);
    reference.live = .empty;
    actual.live = .empty;
    inline for (@typeInfo(RegionAllocator).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "extents")) {
            try testing.expectEqualDeep(reference.extents[0], actual.extents[0]);
        } else {
            try testing.expect(std.meta.eql(@field(reference.*, name), @field(actual.*, name)));
        }
    }

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    @memset(std.mem.asBytes(actual), 0xaa);
    try testing.expectError(error.OutOfMemory, actual.initInPlace(backing.ptr, backing.len, backing.len, 1 << 20, 4096, failing.allocator(), false));
    try testing.expectEqual(@as(usize, 0), actual.live.count());
    actual.deinit();
}

test "region allocator reuses size classes and clears free links on seal" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4 << 20);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0);
    var region = try RegionAllocator.init(backing.ptr, backing.len, backing.len, 1 << 20, 4096, std.testing.allocator, false);
    defer region.deinit();
    const allocator = region.allocator();
    const first = try allocator.alloc(u8, 17);
    allocator.free(first);
    const reused = try allocator.alloc(u8, 17);
    try std.testing.expectEqual(first.ptr, reused.ptr);
    allocator.free(reused);
    const used = try region.seal();
    try std.testing.expect(used < 8192);
    for (backing[4096..][0..32]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "region allocator keeps retained extents below temporary storage" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 16 << 20);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0);
    var region = try RegionAllocator.init(backing.ptr, 4 << 20, backing.len, 1 << 20, 4096, std.testing.allocator, false);
    defer region.deinit();
    const allocator = region.allocator();
    const temporary = try allocator.alloc(u8, 8 << 20);
    const retained = try allocator.alloc(u8, 2 << 20);
    try std.testing.expect(@intFromPtr(temporary.ptr) >= @intFromPtr(backing.ptr) + (8 << 20));
    try std.testing.expectEqual(@intFromPtr(backing.ptr) + (1 << 20), @intFromPtr(retained.ptr));
    allocator.free(temporary);
    try std.testing.expectEqual(@as(usize, 3 << 20), try region.seal());
}

test "region allocator refuses a retained extent beyond the image" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 8 << 20);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0);
    var region = try RegionAllocator.init(backing.ptr, 2 << 20, backing.len, 1 << 20, 4096, std.testing.allocator, false);
    defer region.deinit();
    _ = try region.allocator().alloc(u8, 2 << 20);
    try std.testing.expectError(error.RegionCapacity, region.seal());
}

test "region allocator refuses oversized lengths without changing live extents" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4 << 20);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0);
    var region = try RegionAllocator.init(backing.ptr, backing.len, backing.len, 1 << 20, 4096, std.testing.allocator, false);
    defer region.deinit();
    const allocator = region.allocator();
    const live = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(live);
    live[0] = 0xa5;
    const count = region.live.count();
    const extent_count = region.extent_count;
    const free_extent = region.extents[0];
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, backing.len - 1));
    try std.testing.expectEqual(count, region.live.count());
    try std.testing.expectEqual(extent_count, region.extent_count);
    try std.testing.expectEqual(free_extent.start, region.extents[0].start);
    try std.testing.expectEqual(free_extent.len, region.extents[0].len);
    try std.testing.expectEqual(@as(u8, 0xa5), live[0]);
}

test "region allocator resize and remap refuse growth past the boundary" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4 << 20);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0);
    var region = try RegionAllocator.init(backing.ptr, backing.len, backing.len, 1 << 20, 4096, std.testing.allocator, false);
    defer region.deinit();
    const allocator = region.allocator();
    const live = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(live);
    live[0] = 0x5a;
    const initial_extent = region.extents[0];
    try std.testing.expect(!allocator.resize(live, std.math.maxInt(usize)));
    try std.testing.expect(allocator.remap(live, std.math.maxInt(usize)) == null);
    try std.testing.expectEqual(@as(usize, 1 << 20), region.live.get(@intFromPtr(live.ptr)).?.requested);
    try std.testing.expectEqual(initial_extent.start, region.extents[0].start);
    try std.testing.expectEqual(initial_extent.len, region.extents[0].len);
    try std.testing.expect(allocator.resize(live, 3 << 20));
    try std.testing.expectEqual(@as(usize, 3 << 20), region.live.get(@intFromPtr(live.ptr)).?.requested);
    try std.testing.expect(!allocator.resize(live, (3 << 20) + 1));
    try std.testing.expect(allocator.remap(live, (3 << 20) + 1) == null);
    try std.testing.expectEqual(@as(usize, 3 << 20), region.live.get(@intFromPtr(live.ptr)).?.requested);
    try std.testing.expectEqual(@as(usize, 0), region.extent_count);
    try std.testing.expectEqual(@as(u8, 0x5a), live[0]);
}

test "region allocator compact replay preserves growth outcomes and packs retained data" {
    const profile_backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 64 << 20);
    defer std.testing.allocator.free(profile_backing);
    const replay_backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 64 << 20);
    defer std.testing.allocator.free(replay_backing);
    @memset(profile_backing, 0);
    @memset(replay_backing, 0);
    const trace = try std.testing.allocator.create(RegionAllocator.ProfileTrace);
    defer std.testing.allocator.destroy(trace);
    var profile: RegionAllocator = undefined;
    try profile.initProfileInPlace(profile_backing.ptr, profile_backing.len, profile_backing.len, 4096, std.testing.allocator, trace);
    defer profile.deinit();
    const original = profile.allocator();
    const temporary = try original.alloc(u8, 8 << 20);
    temporary[0] = 0xa5;
    original.free(temporary);
    const first = try original.alloc(u8, 1 << 20);
    first[0] = 0x37;
    try std.testing.expect(original.resize(first, (1 << 20) + 4096));
    var grown_first = first;
    grown_first.len = (1 << 20) + 4096;
    const second = try original.alloc(u8, 1 << 20);
    second[0] = 0x42;
    try std.testing.expect(!original.resize(grown_first, 2 << 20));
    _ = try profile.seal();
    const expected_bytes = try trace.compactedBytes(4096, replay_backing.len);
    try std.testing.expectEqual(@as(usize, 4096 + (1 << 20) + 4096 + (1 << 20)), expected_bytes);

    var replay: RegionAllocator = undefined;
    try replay.initCompactInPlace(replay_backing.ptr, 4 << 20, replay_backing.len, 4096, std.testing.allocator, trace);
    defer replay.deinit();
    const compact = replay.allocator();
    const replay_temporary = try compact.alloc(u8, 8 << 20);
    try std.testing.expect(@intFromPtr(replay_temporary.ptr) >= @intFromPtr(replay_backing.ptr) + (4 << 20));
    compact.free(replay_temporary);
    const replay_first = try compact.alloc(u8, 1 << 20);
    replay_first[0] = 0x37;
    try std.testing.expect(compact.resize(replay_first, (1 << 20) + 4096));
    var replay_grown_first = replay_first;
    replay_grown_first.len = (1 << 20) + 4096;
    const replay_second = try compact.alloc(u8, 1 << 20);
    replay_second[0] = 0x42;
    try std.testing.expect(!compact.resize(replay_grown_first, 2 << 20));
    try std.testing.expectEqual(expected_bytes, try replay.seal());
    try std.testing.expectEqual(@as(usize, @intFromPtr(replay_backing.ptr) + 4096), @intFromPtr(replay_first.ptr));
    try std.testing.expectEqual(@as(u8, 0x37), replay_first[0]);
    try std.testing.expectEqual(@as(u8, 0x42), replay_second[0]);
}

test "alloc package namespace" {
    std.testing.refAllDecls(alloc);
}

test "page namespace" {
    std.testing.refAllDecls(@import("page/root.zig"));
}

test "public phase allocator interoperates with internal phase consumers" {
    var phase: alloc_phase.SealedPhaseAllocator =
        try alloc.phase.SealedPhaseAllocator.init(std.testing.allocator);
    const expected = [_]u8{ 3, 1, 4, 1 };
    const storage = phase.initializationAllocator().alloc(u8, expected.len) catch |err| {
        phase.abortInitialization();
        phase.deinit();
        return err;
    };
    @memcpy(storage, &expected);

    phase.seal();
    const state: alloc.phase.capacity.Phase = phase.phase();
    const violations: alloc.phase.PhaseViolations = phase.violations();
    phase.beginTeardown();
    defer phase.deinit();
    defer phase.teardownAllocator().free(storage);

    try std.testing.expectEqual(.steady, state);
    try std.testing.expectEqual(@as(u64, 0), violations.total());
    try std.testing.expectEqualSlices(u8, &expected, storage);
}

fn expectSameAllocator(expected: std.mem.Allocator, actual: std.mem.Allocator) !void {
    try std.testing.expectEqual(expected.ptr, actual.ptr);
    try std.testing.expectEqual(expected.vtable, actual.vtable);
}

test "allocator policy separates fast integration tests from leak-checking tests" {
    const diagnostic_allocator = std.testing.allocator;
    const policy_allocator = policy.platformProcessAllocator();
    const expected_test_allocator = switch (test_allocator_mode) {
        .fast => policy_allocator,
        .leak_check => diagnostic_allocator,
    };

    try expectSameAllocator(policy_allocator, longLivedProcessAllocator());
    try expectSameAllocator(expected_test_allocator, interactiveSessionAllocator(diagnostic_allocator));
    try expectSameAllocator(expected_test_allocator, standaloneProcessAllocator());
    try expectSameAllocator(expected_test_allocator, testIntegrationAllocator());
    try expectSameAllocator(expected_test_allocator, workerAllocator());
    try expectSameAllocator(expected_test_allocator, threadedIoAllocator());
    try expectSameAllocator(expected_test_allocator, temporaryScratchAllocator());
}

test "allocator diagnostics mode is exposed as deadalloc config" {
    const config = diagnosticAllocatorConfig() orelse {
        try std.testing.expect(allocator_diagnostics_mode == null);
        return;
    };
    try std.testing.expect(config.diagnostics.enabled);
    try std.testing.expectEqual(allocator_diagnostics_mode.?, config.mode);
}

test "allocator diagnostics mode routes process allocations through deadalloc" {
    const config = diagnosticAllocatorConfig() orelse {
        try std.testing.expect(diagnosticAllocatorReport() == null);
        return;
    };

    const allocator = longLivedProcessAllocator();
    try std.testing.expect(allocator.ptr != diagnostics.baseProcessAllocator().ptr or allocator.vtable != diagnostics.baseProcessAllocator().vtable);

    const before = diagnosticAllocatorReport().?;
    const leaked = try allocator.alloc(u8, 32);
    @memset(leaked, 0x5a);
    const during = diagnosticAllocatorReport().?;
    try std.testing.expect(during.live_allocations >= before.live_allocations + 1);
    try std.testing.expect(during.live_bytes >= before.live_bytes + 32);
    allocator.free(leaked);

    const after = diagnosticAllocatorReport().?;
    try std.testing.expect(after.live_allocations <= during.live_allocations);
    try std.testing.expectEqual(config.mode, allocator_diagnostics_mode.?);
}

test "process allocator owner follows runtime diagnostics policy" {
    var process_owner = ProcessAllocatorOwner.init();
    const allocator = process_owner.allocator();
    const runtime_allocator = standaloneProcessAllocator();

    if (diagnosticAllocatorConfig() != null or process_phase_mode != .off) {
        try expectSameAllocator(runtime_allocator, allocator);
    } else {
        try std.testing.expect(allocator.ptr != runtime_allocator.ptr or allocator.vtable != runtime_allocator.vtable);
        try std.testing.expectEqual(ProcessAllocatorFinish.clean, process_owner.finish());
    }
}

test "process allocator owner returns deadalloc diagnostics" {
    const config = diagnosticAllocatorConfig() orelse return;
    var process_owner = ProcessAllocatorOwner.init();
    const allocator = process_owner.allocator();

    const before = diagnosticAllocatorReport().?;
    const leaked = try allocator.alloc(u8, 19);
    defer allocator.free(leaked);
    @memset(leaked, 0x71);

    const finish = process_owner.finish();
    const report = finish.diagnosticReport() orelse return error.ExpectedAllocatorDiagnostics;
    try std.testing.expectEqual(@as(u8, 1), finish.exitCode());
    try std.testing.expect(report.live_allocations >= before.live_allocations + 1);
    try std.testing.expect(report.live_bytes >= before.live_bytes + 19);
    try std.testing.expectEqual(config.mode, allocator_diagnostics_mode.?);
}

test "process allocator owner returns invalid free diagnostics" {
    const config = diagnosticAllocatorConfig() orelse return;
    var process_owner = ProcessAllocatorOwner.init();
    const allocator = process_owner.allocator();

    const before = diagnosticAllocatorReport().?;
    var stack_byte: u8 = 0;
    allocator.rawFree((&stack_byte)[0..1], .@"1", @returnAddress());

    const finish = process_owner.finish();
    const report = finish.diagnosticReport() orelse return error.ExpectedAllocatorDiagnostics;
    const issue = report.last_issue orelse return error.ExpectedAllocatorDiagnostics;
    try std.testing.expectEqual(@as(u8, 1), finish.exitCode());
    try std.testing.expect(report.counters.invalid_free >= before.counters.invalid_free + 1);
    try std.testing.expectEqual(.invalid_free, issue.kind);
    try std.testing.expectEqual(@intFromPtr(&stack_byte), issue.address);
    try std.testing.expectEqual(config.mode, allocator_diagnostics_mode.?);
}

test "process allocator owner returns overflow diagnostics" {
    const config = diagnosticAllocatorConfig() orelse return;
    var process_owner = ProcessAllocatorOwner.init();
    const allocator = process_owner.allocator();

    const before = diagnosticAllocatorReport().?;
    const ptr = allocator.rawAlloc(8, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    ptr[8] = 0xee;

    const finish = process_owner.finish();
    const report = finish.diagnosticReport() orelse return error.ExpectedAllocatorDiagnostics;
    const issue = report.last_issue orelse return error.ExpectedAllocatorDiagnostics;
    try std.testing.expectEqual(@as(u8, 1), finish.exitCode());
    try std.testing.expect(report.counters.buffer_overflow >= before.counters.buffer_overflow + 1);
    try std.testing.expect(report.live_allocations >= before.live_allocations + 1);
    try std.testing.expectEqual(.buffer_overflow, issue.kind);
    try std.testing.expectEqual(@intFromPtr(ptr), issue.address);
    try std.testing.expectEqual(@as(usize, 8), issue.offset);
    try std.testing.expectEqual(@as(usize, 8), issue.requested_len);
    try std.testing.expect(issue.allocation_id != 0);
    try std.testing.expectEqual(config.mode, allocator_diagnostics_mode.?);

    allocator.rawFree(ptr[0..8], .@"1", @returnAddress());
}

test "process allocator phase lifecycle" {
    switch (process_phase_mode) {
        .off => {
            try std.testing.expect(processAllocatorPhaseViolations() == null);
            try std.testing.expect(processAllocatorPhaseViolationSites() == null);
            try std.testing.expect(processAllocatorPhase() == null);
            sealProcessAllocatorPhase();
            beginProcessAllocatorTeardown();
        },
        .observe => {
            const allocator = policy.platformProcessAllocator();
            const startup = try allocator.alloc(u8, 24);
            @memset(startup, 0x11);
            const before = processAllocatorPhaseViolations().?;

            sealProcessAllocatorPhase();
            try std.testing.expectEqual(.steady, processAllocatorPhase().?);
            const steady = try allocator.alloc(u8, 24);
            @memset(steady, 0x22);
            allocator.free(steady);
            const during = processAllocatorPhaseViolations().?;
            try std.testing.expect(during.allocations >= before.allocations + 1);
            try std.testing.expect(during.frees >= before.frees + 1);
            try std.testing.expect(processAllocatorPhaseViolationSites().?.count >= 1);

            beginProcessAllocatorTeardown();
            try std.testing.expectEqual(.teardown, processAllocatorPhase().?);
            allocator.free(startup);
            const after = processAllocatorPhaseViolations().?;
            try std.testing.expectEqual(during.frees, after.frees);
        },
        .seal => {
            const allocator = policy.platformProcessAllocator();
            const startup = try allocator.alloc(u8, 24);
            @memset(startup, 0x33);
            try std.testing.expectEqual(.initialization, processAllocatorPhase().?);
            try std.testing.expect(processAllocatorPhaseViolationSites() == null);

            sealProcessAllocatorPhase();
            try std.testing.expectEqual(.steady, processAllocatorPhase().?);
            try std.testing.expectEqual(@as(u64, 0), processAllocatorPhaseViolations().?.total());

            beginProcessAllocatorTeardown();
            try std.testing.expectEqual(.teardown, processAllocatorPhase().?);
            allocator.free(startup);
            try std.testing.expectEqual(@as(u64, 0), processAllocatorPhaseViolations().?.total());
        },
    }
}

test "process allocator finish maps reports to exit codes" {
    const clean: ProcessAllocatorFinish = .clean;
    const leak: ProcessAllocatorFinish = .leak;
    try std.testing.expectEqual(@as(u8, 0), clean.exitCode());
    try std.testing.expectEqual(@as(u8, 1), leak.exitCode());
    try std.testing.expectEqual(@as(u8, 1), (ProcessAllocatorFinish{ .diagnostics = .{ .counters = .{ .invalid_free = 1 } } }).exitCode());
    try std.testing.expect((ProcessAllocatorFinish{ .diagnostics = .{} }).diagnosticReport() != null);
    try std.testing.expect(clean.diagnosticReport() == null);
}
