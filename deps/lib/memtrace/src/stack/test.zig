const std = @import("std");
const observe = @import("alloc_observe");
const memtrace = @import("../root.zig");
const report = @import("report.zig");
const roots = @import("roots.zig");

noinline fn exactShared(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.alloc(u8, 16);
}

noinline fn exactCallerA(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try exactShared(allocator);
    std.mem.doNotOptimizeAway(bytes.ptr);
    return bytes;
}

noinline fn exactCallerB(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try exactShared(allocator);
    std.mem.doNotOptimizeAway(bytes.len);
    return bytes;
}

test "exact allocation report verifies binary and separates shared callers" {
    var tracer = try memtrace.Tracer.init(std.testing.allocator, .{
        .record_events = true,
        .allocation_attribution = .stack,
    });
    defer tracer.deinit();
    var owned_observation: ?memtrace.OwnedObservation = if (comptime observe.enabled)
        try tracer.observeOwnedAllocators()
    else
        null;
    defer if (owned_observation) |*observation| observation.stop();
    var traced = try tracer.tracedAllocator(std.testing.allocator, "exact");
    const allocator = traced.allocator();
    var phase = try tracer.enter("phase");
    const first = try exactCallerA(allocator);
    phase.exit();
    const second = try exactCallerB(allocator);
    allocator.free(first);
    allocator.free(second);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try temporary.dir.realPathFileAlloc(
        std.Options.debug_io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root_path);
    const events_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_path, "events.jsonl" },
    );
    defer std.testing.allocator.free(events_path);
    try tracer.writeEventsBundlePath(events_path);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try report.writeFromPath(
        std.testing.allocator,
        events_path,
        &output.writer,
        .{ .top = 8, .frame_limit = 32 },
    );
    const expected_coverage = if (comptime observe.enabled)
        "status=process_memory_operation_incomplete " ++
            "universe=process_memory_operations_during_trace_epoch " ++
            "selection=allocations layer=backing calls=2"
    else
        "status=boundary_complete universe=registered_allocator_handles " ++
            "selection=allocations layer=backing calls=2";
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        expected_coverage,
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "exactCallerA",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "exactCallerB",
    ) != null);

    var operations_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer operations_output.deinit();
    try report.writeFromPath(
        std.testing.allocator,
        events_path,
        &operations_output.writer,
        .{ .top = 16, .frame_limit = 32, .selection = .all },
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        operations_output.written(),
        "selection=all layer=backing calls=4 successful=4 failed=0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        operations_output.written(),
        if (comptime observe.enabled)
            "sys_memory_operations=observed"
        else
            "sys_memory_operations=opaque",
    ) != null);

    var phase_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer phase_output.deinit();
    try report.writeFromPath(
        std.testing.allocator,
        events_path,
        &phase_output.writer,
        .{
            .top = 16,
            .frame_limit = 32,
            .window = .{ .scope = "root/phase" },
        },
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        phase_output.written(),
        "selection=allocations layer=backing calls=1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        phase_output.written(),
        "window_scope=\"root/phase\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        phase_output.written(),
        "exactCallerA",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        phase_output.written(),
        "exactCallerB",
    ) == null);

    if (comptime observe.enabled) {
        var roots_output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer roots_output.deinit();
        try roots.writeFromPath(
            std.testing.allocator,
            events_path,
            &roots_output.writer,
            .{ .top = 16, .frame_limit = 32 },
        );
        try std.testing.expect(std.mem.indexOf(
            u8,
            roots_output.written(),
            "selection=allocations sort=high_water roots=2 successful=2 " ++
                "failed=0",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            roots_output.written(),
            "exactCallerA",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            roots_output.written(),
            "exactCallerB",
        ) != null);

        var phase_roots = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer phase_roots.deinit();
        try roots.writeFromPath(
            std.testing.allocator,
            events_path,
            &phase_roots.writer,
            .{
                .top = 16,
                .frame_limit = 32,
                .window = .{ .scope = "root/phase" },
            },
        );
        try std.testing.expect(std.mem.indexOf(
            u8,
            phase_roots.written(),
            "selection=allocations sort=high_water roots=1",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            phase_roots.written(),
            "window_anchor=root_operation",
        ) != null);
    }

    const wrong_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root_path, "wrong.exe" },
    );
    defer std.testing.allocator.free(wrong_path);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = wrong_path,
        .data = "wrong executable",
    });
    try std.testing.expectError(
        error.ExecutableIdentityMismatch,
        report.writeFromPath(
            std.testing.allocator,
            events_path,
            &output.writer,
            .{ .binary_path = wrong_path },
        ),
    );
}
