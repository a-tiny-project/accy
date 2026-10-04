const vulkan = @import("root.zig");

test "gpu vulkan runtime namespace" {
    _ = vulkan.observation;
    _ = vulkan.memory;
    _ = vulkan.runtime;
    _ = vulkan.launch;
    _ = vulkan.raster;
    _ = vulkan.dmabuf;
}

const std = @import("std");
const driver = @import("sys").vulkan;

fn expectPipelineLedger(returned: usize, attempts: u32) !void {
    const ledger = vulkan.runtime.testing.snapshot().pipeline_ledger;
    try std.testing.expect(!ledger.overflow);
    try std.testing.expectEqual(attempts, ledger.raw_attempts);
    try std.testing.expectEqual(returned, ledger.returned_count);
    try std.testing.expectEqual(returned, ledger.destroyed_count);
    try std.testing.expectEqual(@as(usize, 0), ledger.live_count);
    try std.testing.expectEqual(@as(u32, 0), ledger.duplicate_or_unknown_destroys);
    try std.testing.expectEqualSlices(driver.VkPipeline, ledger.returned[0..returned], ledger.destroyed[0..returned]);
}

fn fakeKernel(runtime: *vulkan.runtime.Runtime) vulkan.launch.Kernel {
    return .{ ._runtime = runtime, ._module_handle = @ptrFromInt(1), ._set_layout = @ptrFromInt(2), ._pipeline_layout = @ptrFromInt(3), .num_buffers = 0, .push_constant_size = 0, .entry_point = "fill" };
}

test "pipeline success reuse teardown and append rollback preserve observed and null lifecycles" {
    for ([_]bool{ false, true }) |observed| {
        vulkan.runtime.testing.resetFake();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var runtime = vulkan.runtime.testing.fakeRuntime(failing.allocator());
        var observer: vulkan.observation.AllocationObservation = .{};
        if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
        var kernel = fakeKernel(&runtime);
        try std.testing.expectError(error.OutOfHostMemory, kernel.pipelineForWorkgroup(.{ 1, 1, 1 }));
        var calls = vulkan.runtime.testing.snapshot();
        try std.testing.expectEqual(@as(u32, 1), calls.compute_pipeline_creates);
        try std.testing.expectEqual(@as(u32, 1), calls.pipeline_destroys);
        try std.testing.expectEqual(@as(usize, 0), kernel._pipelines.items.len);
        if (observed) {
            try std.testing.expectEqual(@as(u64, 1), observer.resource(.pipeline).successes);
            try std.testing.expectEqual(@as(u64, 1), observer.resource(.pipeline).rollbacks);
            try expectNoLive(&observer);
        }
        try expectPipelineLedger(1, 1);
        kernel.deinit();
        try expectPipelineLedger(1, 1);
        runtime.allocator = std.testing.allocator;
        kernel = fakeKernel(&runtime);
        const first = try kernel.pipelineForWorkgroup(.{ 1, 1, 1 });
        try std.testing.expectEqual(first, try kernel.pipelineForWorkgroup(.{ 1, 1, 1 }));
        calls = vulkan.runtime.testing.snapshot();
        try std.testing.expectEqual(@as(u32, 2), calls.compute_pipeline_creates);
        kernel.deinit();
        calls = vulkan.runtime.testing.snapshot();
        try std.testing.expectEqual(@as(u32, 2), calls.pipeline_destroys);
        try expectPipelineLedger(2, 2);
        if (observed) try expectNoLive(&observer);
    }
}

test "pipeline raw failure preserves original error and releases only nonnull partial results" {
    for ([_]bool{ false, true }) |observed| for ([_]bool{ false, true }) |nonnull| {
        vulkan.runtime.testing.resetFake();
        vulkan.runtime.testing.setPipelineReturn(driver.VkResult.error_out_of_device_memory, nonnull);
        var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
        var observer: vulkan.observation.AllocationObservation = .{};
        if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
        var kernel = fakeKernel(&runtime);
        try std.testing.expectError(error.OutOfDeviceMemory, kernel.pipelineForWorkgroup(.{ 1, 1, 1 }));
        const calls = vulkan.runtime.testing.snapshot();
        try std.testing.expectEqual(@as(u32, 1), calls.compute_pipeline_creates);
        try std.testing.expectEqual(@as(u32, if (nonnull) 1 else 0), calls.pipeline_destroys);
        try std.testing.expectEqual(@as(usize, 0), kernel._pipelines.items.len);
        try expectPipelineLedger(if (nonnull) 1 else 0, 1);
        kernel.deinit();
        try expectPipelineLedger(if (nonnull) 1 else 0, 1);
        if (observed) {
            const counter = observer.resource(.pipeline);
            try std.testing.expectEqual(@as(u64, 1), counter.attempts);
            try std.testing.expectEqual(@as(u64, 1), counter.failures);
            try std.testing.expectEqual(@as(u64, 0), counter.successes);
            try std.testing.expectEqual(@as(u64, if (nonnull) 1 else 0), counter.partial_results);
            try std.testing.expectEqual(@as(u64, if (nonnull) 1 else 0), counter.rollbacks);
            try expectNoLive(&observer);
        }
    };
}

fn fakeTeardown(runtime: *vulkan.runtime.Runtime) void {
    vulkan.runtime.testing.releaseDefaultStream(runtime);
    runtime._shader_cache.deinit(runtime);
    runtime._pipeline_layout_cache.deinit(runtime);
    vulkan.runtime.testing.deinitMemoryBlocks(runtime);
    runtime._live_streams.deinit(runtime.allocator);
}

fn expectNoLive(observer: *const vulkan.observation.AllocationObservation) !void {
    try std.testing.expect(!observer.overflow);
    for (observer.resources) |counter| {
        try std.testing.expectEqual(@as(u64, 0), counter.live);
        try std.testing.expectEqual(@as(u64, 0), counter.live_bytes);
    }
    try std.testing.expectEqual(@as(u64, 0), observer.suballocations.live);
    for (observer.memory_types) |memory| {
        try std.testing.expectEqual(@as(u64, 0), memory.backing.live_bytes);
        try std.testing.expectEqual(@as(u64, 0), memory.mapped.live_bytes);
        try std.testing.expectEqual(@as(u64, 0), memory.suballocations.live_bytes);
    }
}

test "observed Vulkan mapped and staged transfers preserve backing and reuse until teardown" {
    for ([_]bool{ false, true }) |staged| {
        vulkan.runtime.testing.resetFake();
        if (staged) vulkan.runtime.testing.setStagedMemory();
        var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
        var observer: vulkan.observation.AllocationObservation = .{};
        vulkan.runtime.testing.observeFake(&runtime, &observer);
        var buffer = try vulkan.runtime.DeviceBuffer.alloc(&runtime, 16);
        try buffer.copyFromHost(&.{});
        try std.testing.expectEqual(@as(u64, 1), observer.upload_noops);
        try std.testing.expectEqual(@as(u64, 0), observer.transfers[@backingInt(if (staged) vulkan.observation.Route.staged_upload else .mapped_upload)].requested_bytes);
        try buffer.copyFromHost(&.{ 1, 2, 3, 4 });
        var out: [16]u8 = undefined;
        try buffer.copyToHost(&out);
        try std.testing.expectEqual(@as(u64, 1), observer.transfers[@backingInt(if (staged) vulkan.observation.Route.staged_upload else .mapped_upload)].completions);
        try std.testing.expectEqual(@as(u64, 4), observer.transfers[@backingInt(if (staged) vulkan.observation.Route.staged_upload else .mapped_upload)].completed_bytes);
        try std.testing.expectEqual(@as(u64, 16), observer.transfers[@backingInt(if (staged) vulkan.observation.Route.staged_download else .mapped_download)].completed_bytes);
        const blocks = observer.resource(.backing).successes;
        try std.testing.expectEqual(@as(u64, if (staged) 2 else 1), blocks);
        try std.testing.expectEqual(blocks * 64 * 1024 * 1024, observer.resource(.backing).live_bytes);
        try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), observer.resource(.mapped_backing).live_bytes);
        buffer.deinit();
        try std.testing.expectEqual(@as(u64, 0), observer.suballocations.live_bytes);
        try std.testing.expectEqual(blocks, observer.resource(.backing).live);
        var reused = try vulkan.runtime.DeviceBuffer.alloc(&runtime, 16);
        try std.testing.expectEqual(blocks, observer.resource(.backing).successes);
        reused.deinit();
        fakeTeardown(&runtime);
        try expectNoLive(&observer);
    }
}

test "observed Vulkan raw resource failures and bind rollback retain original errors" {
    const Failure = vulkan.runtime.testing.AllocationFailure;
    for ([_]Failure{ .buffer, .memory, .map, .bind }) |point| {
        vulkan.runtime.testing.resetFake();
        var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
        var observer: vulkan.observation.AllocationObservation = .{};
        vulkan.runtime.testing.observeFake(&runtime, &observer);
        vulkan.runtime.testing.setAllocationFailure(point);
        try std.testing.expectError(if (point == .map) error.MemoryMapFailed else error.OutOfDeviceMemory, vulkan.runtime.DeviceBuffer.alloc(&runtime, 16));
        try std.testing.expectEqual(@as(u64, 1), observer.resource(.buffer).attempts);
        try std.testing.expectEqual(@as(u64, if (point == .buffer) 0 else 1), observer.resource(.buffer).successes);
        try std.testing.expectEqual(@as(u64, if (point == .buffer) 0 else 1), observer.resource(.buffer).rollbacks);
        if (point == .map) {
            try std.testing.expectEqual(@as(u64, 1), observer.resource(.backing).successes);
            try std.testing.expectEqual(@as(u64, 1), observer.resource(.backing).rollbacks);
            try std.testing.expectEqual(@as(u64, 1), observer.resource(.mapped_backing).failures);
        }
        fakeTeardown(&runtime);
        try expectNoLive(&observer);
    }
}

test "observed Vulkan flush and invalidate failures never complete transfers" {
    const Failure = vulkan.runtime.testing.AllocationFailure;
    for ([_]Failure{ .flush, .invalidate }) |point| {
        vulkan.runtime.testing.resetFake();
        vulkan.runtime.testing.setNonCoherentMemory();
        var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
        var observer: vulkan.observation.AllocationObservation = .{};
        vulkan.runtime.testing.observeFake(&runtime, &observer);
        var buffer = try vulkan.runtime.DeviceBuffer.alloc(&runtime, 16);
        vulkan.runtime.testing.setAllocationFailure(point);
        var out: [16]u8 = undefined;
        if (point == .flush) try std.testing.expectError(error.DeviceLost, buffer.copyFromHost(&out)) else try std.testing.expectError(error.DeviceLost, buffer.copyToHost(&out));
        const route: vulkan.observation.Route = if (point == .flush) .mapped_upload else .mapped_download;
        const counter = observer.transfers[@backingInt(route)];
        try std.testing.expectEqual(@as(u64, 1), counter.attempts);
        try std.testing.expectEqual(@as(u64, 1), counter.failures);
        try std.testing.expectEqual(@as(u64, 0), counter.completions);
        buffer.deinit();
        fakeTeardown(&runtime);
        try expectNoLive(&observer);
    }
}

test "observed Vulkan host bookkeeping failure rolls back raw mapped backing" {
    vulkan.runtime.testing.resetFake();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var runtime = vulkan.runtime.testing.fakeRuntime(failing.allocator());
    var observer: vulkan.observation.AllocationObservation = .{};
    vulkan.runtime.testing.observeFake(&runtime, &observer);
    try std.testing.expectError(error.OutOfHostMemory, vulkan.runtime.DeviceBuffer.alloc(&runtime, 16));
    try std.testing.expectEqual(@as(u64, 1), observer.resource(.backing).successes);
    try std.testing.expectEqual(@as(u64, 1), observer.resource(.backing).rollbacks);
    try std.testing.expectEqual(@as(u64, 1), observer.resource(.mapped_backing).rollbacks);
    try std.testing.expectEqual(@as(u64, 1), observer.resource(.buffer).rollbacks);
    fakeTeardown(&runtime);
    try expectNoLive(&observer);
}

test "observed Vulkan different-sized mapped failures preserve requested volume and null parity" {
    const Failure = vulkan.runtime.testing.AllocationFailure;
    for ([_]bool{ false, true }) |observed| for ([_]usize{ 4, 16 }) |size| {
        for ([_]Failure{ .flush, .invalidate }) |point| {
            vulkan.runtime.testing.resetFake();
            vulkan.runtime.testing.setNonCoherentMemory();
            var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
            var observer: vulkan.observation.AllocationObservation = .{};
            if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
            var buffer = try vulkan.runtime.DeviceBuffer.alloc(&runtime, if (point == .flush) 32 else size);
            vulkan.runtime.testing.setAllocationFailure(point);
            var bytes: [16]u8 = @splat(7);
            if (point == .flush) try std.testing.expectError(error.DeviceLost, buffer.copyFromHost(bytes[0..size])) else try std.testing.expectError(error.DeviceLost, buffer.copyToHost(&bytes));
            if (observed) {
                const route: vulkan.observation.Route = if (point == .flush) .mapped_upload else .mapped_download;
                const counter = observer.transfers[@backingInt(route)];
                try std.testing.expectEqual(@as(u64, size), counter.requested_bytes);
                try std.testing.expectEqual(@as(u64, 1), counter.attempts);
                try std.testing.expectEqual(@as(u64, 1), counter.failures);
                try std.testing.expectEqual(@as(u64, 0), counter.completed_bytes);
                try std.testing.expectEqual(@as(u64, 0), counter.completions);
            }
            buffer.deinit();
            fakeTeardown(&runtime);
            if (observed) try expectNoLive(&observer);
        }
    };
}

test "observed Vulkan staged failures preserve requested volume rollback and null parity" {
    const Point = enum { create, memory, map, bind, flush, submit, wait, invalidate };
    for ([_]bool{ false, true }) |observed| for ([_]usize{ 4, 16 }) |size| {
        inline for (std.enums.values(Point)) |point| {
            vulkan.runtime.testing.resetFake();
            vulkan.runtime.testing.setNonCoherentMemory();
            vulkan.runtime.testing.setStagedMemory();
            var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
            var observer: vulkan.observation.AllocationObservation = .{};
            if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
            var buffer = try vulkan.runtime.DeviceBuffer.alloc(&runtime, if (point == .invalidate) size else 32);
            switch (point) {
                .create => vulkan.runtime.testing.setAllocationFailure(.buffer),
                .memory => vulkan.runtime.testing.setAllocationFailure(.memory),
                .map => vulkan.runtime.testing.setAllocationFailure(.map),
                .bind => vulkan.runtime.testing.setAllocationFailure(.bind),
                .flush => vulkan.runtime.testing.setAllocationFailure(.flush),
                .submit => vulkan.runtime.testing.setQueueSubmitReturn(.error_device_lost),
                .wait => vulkan.runtime.testing.setWaitReturn(.error_device_lost),
                .invalidate => vulkan.runtime.testing.setAllocationFailure(.invalidate),
            }
            var bytes: [16]u8 = @splat(7);
            const expected = switch (point) {
                .create, .memory, .bind => error.OutOfDeviceMemory,
                .map => error.MemoryMapFailed,
                else => error.DeviceLost,
            };
            if (point == .invalidate) try std.testing.expectError(expected, buffer.copyToHost(&bytes)) else try std.testing.expectError(expected, buffer.copyFromHost(bytes[0..size]));
            if (observed) {
                const route: vulkan.observation.Route = if (point == .invalidate) .staged_download else .staged_upload;
                const counter = observer.transfers[@backingInt(route)];
                try std.testing.expectEqual(@as(u64, size), counter.requested_bytes);
                try std.testing.expectEqual(@as(u64, 1), counter.attempts);
                try std.testing.expectEqual(@as(u64, 1), counter.failures);
                try std.testing.expectEqual(@as(u64, 0), counter.completions);
                try std.testing.expectEqual(@as(u64, 0), counter.completed_bytes);
                const staging = observer.resource(.transfer_buffer);
                try std.testing.expectEqual(@as(u64, size), staging.requested_bytes);
                try std.testing.expectEqual(@as(u64, 1), staging.attempts);
                try std.testing.expectEqual(@as(u64, if (point == .create) 0 else 1), staging.successes);
                try std.testing.expectEqual(@as(u64, if (point == .create) 0 else size), staging.successful_bytes);
                try std.testing.expectEqual(@as(u64, 0), staging.live);
                try std.testing.expectEqual(@as(u64, if (point == .memory or point == .map or point == .bind) 1 else 0), staging.rollbacks);
            }
            buffer.deinit();
            fakeTeardown(&runtime);
            if (observed) try expectNoLive(&observer);
        }
    };
}

fn expectRawReleased(ledger: anytype, attempts: u32, returned: usize) !void {
    try std.testing.expect(!ledger.overflow);
    try std.testing.expectEqual(attempts, ledger.attempts);
    try std.testing.expectEqual(returned, ledger.returned_count);
    try std.testing.expectEqual(returned, ledger.destroyed_count);
    try std.testing.expectEqual(@as(usize, 0), ledger.live_count);
    try std.testing.expectEqual(@as(u32, 0), ledger.unknown_destroys);
    for (ledger.returned[0..returned]) |handle| {
        var matches: usize = 0;
        for (ledger.destroyed[0..returned]) |destroyed| {
            if (destroyed == handle) matches += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
}

test "observed staged download request 17 has raw ownership parity at each failure" {
    const Point = enum { success, create, memory, map, bind, submit, wait, invalidate };
    for ([_]bool{ false, true }) |observed| {
        inline for (std.enums.values(Point)) |point| {
            vulkan.runtime.testing.resetFake();
            vulkan.runtime.testing.setNonCoherentMemory();
            vulkan.runtime.testing.setStagedMemory();
            var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
            var observer: vulkan.observation.AllocationObservation = .{};
            if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
            var buffer = try vulkan.runtime.DeviceBuffer.alloc(&runtime, 17);
            switch (point) {
                .success => {},
                .create => vulkan.runtime.testing.setAllocationFailure(.buffer),
                .memory => vulkan.runtime.testing.setAllocationFailure(.memory),
                .map => vulkan.runtime.testing.setAllocationFailure(.map),
                .bind => vulkan.runtime.testing.setAllocationFailure(.bind),
                .submit => vulkan.runtime.testing.setQueueSubmitReturn(.error_device_lost),
                .wait => vulkan.runtime.testing.setWaitReturn(.error_device_lost),
                .invalidate => vulkan.runtime.testing.setAllocationFailure(.invalidate),
            }
            var bytes: [17]u8 = @splat(7);
            if (point == .success) {
                try buffer.copyToHost(&bytes);
            } else {
                const expected = switch (point) {
                    .create, .memory, .bind => error.OutOfDeviceMemory,
                    .map => error.MemoryMapFailed,
                    else => error.DeviceLost,
                };
                try std.testing.expectError(expected, buffer.copyToHost(&bytes));
                try std.testing.expectEqualSlices(u8, &@as([17]u8, @splat(7)), &bytes);
            }
            if (observed) {
                const counter = observer.transfers[@backingInt(vulkan.observation.Route.staged_download)];
                try std.testing.expectEqual(@as(u64, 17), counter.requested_bytes);
                try std.testing.expectEqual(@as(u64, 1), counter.attempts);
                try std.testing.expectEqual(@as(u64, if (point == .success) 0 else 1), counter.failures);
                try std.testing.expectEqual(@as(u64, if (point == .success) 1 else 0), counter.completions);
                try std.testing.expectEqual(@as(u64, if (point == .success) 17 else 0), counter.completed_bytes);
            }
            buffer.deinit();
            fakeTeardown(&runtime);
            if (observed) try expectNoLive(&observer);
            const effects = vulkan.runtime.testing.rawEffects();
            try expectRawReleased(effects.buffer, 2, if (point == .create) 1 else 2);
            try expectRawReleased(effects.memory, if (point == .create) 1 else 2, if (point == .create or point == .memory) 1 else 2);
        }
    }
}

fn expectAllRawReleased() !void {
    const effects = vulkan.runtime.testing.rawEffects();
    inline for (comptime std.meta.fieldNames(@TypeOf(effects))) |name| {
        const ledger = @field(effects, name);
        try expectRawReleased(ledger, ledger.attempts, ledger.returned_count);
    }
}

test "observed object construction failures retain raw null parity and rollback" {
    const Point = enum {
        shader,
        descriptor_layout,
        pipeline_layout,
        query_pool,
        command_pool,
        semaphore,
        descriptor_pool,
        descriptor_set,
        command_buffer,
    };
    for ([_]bool{ false, true }) |observed| {
        inline for (std.enums.values(Point)) |point| {
            vulkan.runtime.testing.resetFake();
            var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
            runtime._queue_timestamp_valid_bits = 64;
            runtime._timestamp_period_ns = 1;
            var observer: vulkan.observation.AllocationObservation = .{};
            if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
            const stream: ?*vulkan.runtime.Stream = switch (point) {
                .descriptor_pool, .descriptor_set, .command_buffer => try runtime.createStream(),
                else => null,
            };
            vulkan.runtime.testing.setObjectFailure(@field(vulkan.runtime.testing.ObjectFailure, @tagName(point)));
            switch (point) {
                .shader => try std.testing.expectError(error.OutOfDeviceMemory, runtime._shader_cache.populateCache(&runtime, &.{ 1, 2, 3, 4 })),
                .descriptor_layout, .pipeline_layout => try std.testing.expectError(error.OutOfDeviceMemory, runtime._pipeline_layout_cache.getOrCreate(&runtime, .{ .num_buffers = 1, .push_constant_size = 0 })),
                .query_pool => try std.testing.expectError(error.OutOfDeviceMemory, runtime.createEvent()),
                .command_pool, .semaphore => try std.testing.expectError(error.OutOfDeviceMemory, runtime.createStream()),
                .descriptor_pool, .descriptor_set => try std.testing.expectError(error.OutOfDeviceMemory, vulkan.runtime.acquireStreamDescriptorSet(stream.?, @ptrFromInt(1))),
                .command_buffer => try std.testing.expectError(error.OutOfDeviceMemory, vulkan.runtime.acquireStreamCommandBuffer(stream.?)),
            }
            const effects = vulkan.runtime.testing.rawEffects();
            const failed = @field(effects, @tagName(point));
            try std.testing.expectEqual(@as(u32, 1), failed.attempts);
            try std.testing.expectEqual(@as(usize, 0), failed.returned_count);
            if (observed) {
                const resource = observer.resource(@field(vulkan.observation.Resource, @tagName(point)));
                try std.testing.expectEqual(@as(u64, 1), resource.attempts);
                try std.testing.expectEqual(@as(u64, 1), resource.failures);
                try std.testing.expectEqual(@as(u64, 0), resource.successes);
                try std.testing.expectEqual(@as(u64, 0), resource.requested_bytes);
                if (point == .semaphore) try std.testing.expectEqual(@as(u64, 1), observer.resource(.command_pool).rollbacks);
                if (point == .pipeline_layout) try std.testing.expectEqual(@as(u64, 1), observer.resource(.descriptor_layout).rollbacks);
            }
            if (stream) |value| runtime.destroyStream(value);
            fakeTeardown(&runtime);
            if (observed) try expectNoLive(&observer);
            try expectAllRawReleased();
        }
    }
}

test "observed cache insertion and stream registration rollback retain raw ownership" {
    const Point = enum { shader, layout, stream };
    for ([_]bool{ false, true }) |observed| {
        inline for (std.enums.values(Point)) |point| {
            vulkan.runtime.testing.resetFake();
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = if (point == .stream) 1 else 0 });
            var runtime = vulkan.runtime.testing.fakeRuntime(failing.allocator());
            var observer: vulkan.observation.AllocationObservation = .{};
            if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
            switch (point) {
                .shader => try std.testing.expectError(error.OutOfHostMemory, runtime._shader_cache.populateCache(&runtime, &.{ 1, 2, 3, 4 })),
                .layout => try std.testing.expectError(error.OutOfHostMemory, runtime._pipeline_layout_cache.getOrCreate(&runtime, .{ .num_buffers = 1, .push_constant_size = 0 })),
                .stream => try std.testing.expectError(error.OutOfHostMemory, runtime.createStream()),
            }
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 0), runtime._shader_cache.map.count());
            try std.testing.expectEqual(@as(usize, 0), runtime._pipeline_layout_cache.map.count());
            try std.testing.expectEqual(@as(usize, 0), runtime._live_streams.count());
            fakeTeardown(&runtime);
            if (observed) {
                try expectNoLive(&observer);
                switch (point) {
                    .shader => try std.testing.expectEqual(@as(u64, 1), observer.resource(.shader).rollbacks),
                    .layout => {
                        try std.testing.expectEqual(@as(u64, 1), observer.resource(.descriptor_layout).rollbacks);
                        try std.testing.expectEqual(@as(u64, 1), observer.resource(.pipeline_layout).rollbacks);
                    },
                    .stream => {
                        try std.testing.expectEqual(@as(u64, 1), observer.resource(.command_pool).releases);
                        try std.testing.expectEqual(@as(u64, 1), observer.resource(.semaphore).releases);
                    },
                }
            }
            const effects = vulkan.runtime.testing.rawEffects();
            switch (point) {
                .shader => try expectRawReleased(effects.shader, 1, 1),
                .layout => {
                    try expectRawReleased(effects.descriptor_layout, 1, 1);
                    try expectRawReleased(effects.pipeline_layout, 1, 1);
                },
                .stream => {
                    try expectRawReleased(effects.command_pool, 1, 1);
                    try expectRawReleased(effects.semaphore, 1, 1);
                },
            }
        }
    }
}

test "observed caches query and stream reuse retain one raw handle until teardown" {
    for ([_]bool{ false, true }) |observed| {
        vulkan.runtime.testing.resetFake();
        var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
        runtime._queue_timestamp_valid_bits = 64;
        runtime._timestamp_period_ns = 1;
        var observer: vulkan.observation.AllocationObservation = .{};
        if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
        const shader = try runtime._shader_cache.populateCache(&runtime, &.{ 1, 2, 3, 4 });
        try std.testing.expectEqual(shader, try runtime._shader_cache.populateCache(&runtime, &.{ 1, 2, 3, 4 }));
        const key: vulkan.runtime.PipelineLayoutCache.Key = .{ .num_buffers = 1, .push_constant_size = 4 };
        const layout = try runtime._pipeline_layout_cache.getOrCreate(&runtime, key);
        try std.testing.expectEqualDeep(layout, try runtime._pipeline_layout_cache.getOrCreate(&runtime, key));
        const event = try runtime.createEvent();
        runtime.destroyEvent(event);
        const stream = try runtime.defaultStream();
        try std.testing.expectEqual(stream, try runtime.defaultStream());
        const command = try vulkan.runtime.acquireStreamCommandBuffer(stream);
        vulkan.runtime.retireStreamCommandBuffer(stream, command, 1);
        const descriptor = try vulkan.runtime.acquireStreamDescriptorSet(stream, layout.set_layout);
        vulkan.runtime.retireStreamDescriptorSet(stream, descriptor, layout.set_layout, 1);
        vulkan.runtime.testing.setCounterValue(1);
        try std.testing.expectEqual(command, try vulkan.runtime.acquireStreamCommandBuffer(stream));
        try std.testing.expectEqual(descriptor, try vulkan.runtime.acquireStreamDescriptorSet(stream, layout.set_layout));
        fakeTeardown(&runtime);
        if (observed) try expectNoLive(&observer);
        const effects = vulkan.runtime.testing.rawEffects();
        inline for (.{ "shader", "descriptor_layout", "pipeline_layout", "query_pool", "command_pool", "semaphore", "descriptor_pool", "descriptor_set", "command_buffer" }) |name| {
            try expectRawReleased(@field(effects, name), 1, 1);
        }
        try std.testing.expectEqual(@as(u32, 1), vulkan.runtime.testing.snapshot().cb_resets);
    }
}

test "observed bounded descriptor reset and command reset failure retain pool ownership" {
    const Point = enum { descriptor_success, descriptor_failure, command_failure };
    for ([_]bool{ false, true }) |observed| {
        inline for (std.enums.values(Point)) |point| {
            vulkan.runtime.testing.resetFake();
            var runtime = vulkan.runtime.testing.fakeRuntime(std.testing.allocator);
            var observer: vulkan.observation.AllocationObservation = .{};
            if (observed) vulkan.runtime.testing.observeFake(&runtime, &observer);
            const stream = try runtime.createStream();
            if (point == .command_failure) {
                const command = try vulkan.runtime.acquireStreamCommandBuffer(stream);
                vulkan.runtime.retireStreamCommandBuffer(stream, command, 1);
                vulkan.runtime.testing.setCounterValue(1);
                vulkan.runtime.testing.setObjectFailure(.command_reset);
                try std.testing.expectError(error.DeviceLost, vulkan.runtime.acquireStreamCommandBuffer(stream));
                try std.testing.expectEqual(@as(u32, 1), vulkan.runtime.testing.snapshot().cb_resets);
            } else {
                const bound = stream._retired_descriptor_sets.len;
                for (0..bound) |index| {
                    const layout: driver.VkDescriptorSetLayout = @ptrFromInt(0x10_0000 + index * 0x10);
                    const descriptor = try vulkan.runtime.acquireStreamDescriptorSet(stream, layout);
                    vulkan.runtime.retireStreamDescriptorSet(stream, descriptor, layout, index + 1);
                }
                stream.counter = bound;
                if (point == .descriptor_failure) vulkan.runtime.testing.setObjectFailure(.descriptor_reset);
                if (point == .descriptor_success) {
                    _ = try vulkan.runtime.acquireStreamDescriptorSet(stream, @ptrFromInt(0x20_0000));
                    try std.testing.expectEqual(@as(usize, 0), stream._retired_descriptor_set_count);
                    if (observed) try std.testing.expectEqual(@as(u64, bound), observer.resource(.descriptor_set).releases);
                } else {
                    try std.testing.expectError(error.DeviceLost, vulkan.runtime.acquireStreamDescriptorSet(stream, @ptrFromInt(0x20_0000)));
                    try std.testing.expectEqual(bound, stream._retired_descriptor_set_count);
                    if (observed) try std.testing.expectEqual(@as(u64, 0), observer.resource(.descriptor_set).releases);
                }
            }
            runtime.destroyStream(stream);
            fakeTeardown(&runtime);
            if (observed) try expectNoLive(&observer);
            try expectAllRawReleased();
            const effects = vulkan.runtime.testing.rawEffects();
            const count: usize = if (point == .descriptor_success) 65 else 64;
            if (point == .command_failure) try expectRawReleased(effects.command_buffer, 1, 1) else try expectRawReleased(effects.descriptor_set, @intCast(count), count);
        }
    }
}
