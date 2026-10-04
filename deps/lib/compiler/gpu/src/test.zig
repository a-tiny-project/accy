const std = @import("std");
const gpu = @import("root.zig");

test {
    _ = @import("bindings.zig");
    _ = @import("push.zig");
    _ = @import("readback.zig");
    _ = @import("runtime/test.zig");
    _ = @import("runtime/cpu/raster.zig");
    _ = @import("runtime/cuda/test.zig");
    _ = @import("cuda.zig");
    _ = @import("runtime/metal/test.zig");
    _ = @import("runtime/vulkan/test.zig");
    _ = @import("vulkan.zig");
}

test "gpu declaration coverage" {
    std.testing.refAllDecls(gpu);
    std.testing.refAllDecls(gpu.contract);
}

test "backends without a render path refuse passes with typed errors" {
    const refusal = @import("refusal.zig");
    var wasm_state = gpu.wasm.State.init(std.testing.allocator);
    defer wasm_state.deinit();
    try refusal.expectRenderRefused(wasm_state.handle());
    var webgpu_state = gpu.webgpu.State.init(std.testing.allocator);
    defer webgpu_state.deinit();
    try refusal.expectRenderRefused(webgpu_state.handle());
}

test "sequence bounds refuse their first excess before device work" {
    const contract = gpu.contract;
    var state = gpu.wasm.State.init(std.testing.allocator);
    defer state.deinit();
    const handle = state.handle();
    var artifact = try contract.KernelArtifact.init(std.testing.allocator, .{
        .backend = .wasm,
        .format = .webassembly_module,
        .entry_name = "bound",
        .argument_count = 0,
    });
    defer artifact.deinit();
    const base = contract.SequenceDispatch{
        .name = "bound",
        .launch = .{
            .artifact = &artifact,
            .buffers = &.{},
            .geometry = .{ .grid = .{ 1, 1, 1 }, .threadgroup = .{ 1, 1, 1 } },
        },
    };
    var failure: contract.SequenceFailure = .{};
    try std.testing.expectError(error.LaunchArgumentMismatch, handle.recordSequence(.{ .dispatches = &.{}, .failure = &failure }));

    var over_dispatches: [contract.max_sequence_dispatches + 1]contract.SequenceDispatch = undefined;
    @memset(&over_dispatches, base);
    try std.testing.expectError(error.SequenceCapacityExceeded, handle.recordSequence(.{ .dispatches = &over_dispatches, .failure = &failure }));
    try std.testing.expectEqualStrings("max_sequence_dispatches", failure.limit_name.?);
    try std.testing.expectEqual(@as(usize, 16), failure.limit);
    try std.testing.expectEqual(@as(usize, 17), failure.requested);

    const bindings: [contract.max_sequence_arguments + 1]contract.BufferBinding = undefined;
    var over_args = base;
    over_args.launch.buffers = &bindings;
    try std.testing.expectError(error.SequenceCapacityExceeded, handle.recordSequence(.{ .dispatches = &.{over_args}, .failure = &failure }));
    try std.testing.expectEqualStrings("max_sequence_arguments", failure.limit_name.?);
    try std.testing.expectEqual(@as(usize, 32), failure.limit);
    try std.testing.expectEqual(@as(usize, 33), failure.requested);

    const scalars: [contract.max_sequence_scalar_bytes / @sizeOf(u64) + 1]@import("gpu_abi").ScalarArgument = @splat(.{ .u64 = 0 });
    var over_scalar_bytes = base;
    over_scalar_bytes.launch.scalar_arguments = &scalars;
    try std.testing.expectError(error.SequenceCapacityExceeded, handle.recordSequence(.{ .dispatches = &.{over_scalar_bytes}, .failure = &failure }));
    try std.testing.expectEqualStrings("max_sequence_scalar_bytes", failure.limit_name.?);
    try std.testing.expectEqual(@as(usize, 128), failure.limit);
    try std.testing.expectEqual(@as(usize, 136), failure.requested);

    var over_name = base;
    const name: [contract.max_sequence_name_bytes + 1]u8 = @splat('x');
    over_name.name = &name;
    try std.testing.expectError(error.SequenceCapacityExceeded, handle.recordSequence(.{ .dispatches = &.{over_name}, .failure = &failure }));
    try std.testing.expectEqualStrings("max_sequence_name_bytes", failure.limit_name.?);
    try std.testing.expectEqual(@as(usize, 64), failure.limit);
    try std.testing.expectEqual(@as(usize, 65), failure.requested);

    const Fake = struct {
        caps: contract.BackendCapabilities,
        records: usize = 0,

        fn query(ptr: *anyopaque) contract.BackendError!contract.BackendCapabilities {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.caps;
        }

        fn record(ptr: *anyopaque, request: contract.SequenceRecordRequest) contract.BackendError!contract.SequenceHandle {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.records += 1;
            return .{ .id = request.dispatches.len, .backend = .wasm };
        }
    };
    var fake = Fake{ .caps = try handle.queryCapabilities() };
    const vtable = contract.BackendVTable{ .query_capabilities = Fake.query, .record_sequence = Fake.record };
    const fake_handle = contract.BackendHandle{ .ptr = &fake, .vtable = &vtable, .kind = .wasm };
    const one = try fake_handle.recordSequence(.{ .dispatches = &.{base} });
    try std.testing.expectEqual(@as(contract.BackendObjectId, 1), one.id);
    const max = try fake_handle.recordSequence(.{ .dispatches = over_dispatches[0..contract.max_sequence_dispatches] });
    try std.testing.expectEqual(@as(contract.BackendObjectId, 16), max.id);
    try std.testing.expectEqual(@as(usize, 2), fake.records);
}

test "sequence dispatch capacity rounds the largest valid step" {
    const largest_step = @as(usize, 1) << (@bitSizeOf(usize) - 2);
    try std.testing.expectEqual(
        largest_step * 2,
        gpu.contract.sequenceDispatchCapacity(largest_step),
    );
}

const launch_measure_single_trials: usize = 101;
const launch_measure_back_trials: usize = 21;
const launch_measure_replays: usize = 256;
const launch_measure_max_dispatches: usize = 10;

const LaunchMeasure = struct {
    host_ns: u64,
    device_ns: ?u64,
};

fn measureLaunchTrial(
    handle: gpu.contract.BackendHandle,
    sequence: gpu.contract.SequenceHandle,
    launch_request: gpu.contract.LaunchRequest,
    count: usize,
    replays: usize,
    batched: bool,
    counter: gpu.contract.BufferHandle,
    stream: gpu.contract.StreamHandle,
    start_event: gpu.contract.EventHandle,
    end_event: gpu.contract.EventHandle,
) !LaunchMeasure {
    const sys = @import("sys");
    var zero: u32 = 0;
    try handle.writeBuffer(.{ .handle = counter, .bytes = std.mem.asBytes(&zero) });
    try handle.recordEvent(.{ .stream = stream, .event = start_event });
    const start_ns = (try sys.time.awakeNow()).asNanoseconds();
    for (0..replays) |_| {
        if (batched) {
            try handle.submitSequence(.{ .sequence = sequence, .stream = stream });
        } else {
            for (0..count) |_| try handle.launch(launch_request);
        }
    }
    try handle.recordEvent(.{ .stream = stream, .event = end_event });
    try handle.synchronize(.{ .scope = .event, .event = end_event });
    const host_ns = (try sys.time.awakeNow()).asNanoseconds() - start_ns;
    const device_ns: ?u64 = handle.elapsedEventNs(.{ .start = start_event, .end = end_event }) catch null;
    var actual: u32 = 0;
    try handle.readBuffer(.{ .handle = counter, .bytes = std.mem.asBytes(&actual) });
    try std.testing.expectEqual(@as(u32, @intCast(count * replays)), actual);
    return .{ .host_ns = @intCast(host_ns / replays), .device_ns = if (device_ns) |value| value / replays else null };
}

fn launchPercentiles(values: []u64) [3]u64 {
    std.debug.assert(values.len > 0);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{ values[values.len / 10], values[values.len / 2], values[(values.len * 9) / 10] };
}

fn measureBackend(handle: gpu.contract.BackendHandle, kind: gpu.contract.BackendKind) !void {
    const contract = gpu.contract;
    var artifact = try contract.KernelArtifact.init(std.testing.allocator, .{
        .backend = kind,
        .format = if (kind == .cuda) .cuda_ptx else .vulkan_spirv,
        .entry_name = "sequence_counter",
        .argument_count = 2,
    });
    defer artifact.deinit();
    if (kind == .cuda) {
        artifact.setBorrowedText(@import("runtime/cuda/fixture/counter.zig").ptx);
    } else {
        artifact.setBorrowedWords(&@import("runtime/vulkan/fixture/counter.zig").words);
    }
    const loaded = try handle.loadArtifact(&artifact);
    defer handle.destroyObject(loaded.id);
    const caps = try handle.queryCapabilities();
    const alignment = @max(@as(usize, 4), caps.memory.min_buffer_alignment);
    const counter = try handle.allocateBuffer(.{ .byte_size = 4, .alignment = alignment });
    defer handle.destroyObject(counter.id);
    const output = try handle.allocateBuffer(.{
        .byte_size = launch_measure_max_dispatches * launch_measure_replays * 4,
        .alignment = alignment,
    });
    defer handle.destroyObject(output.id);
    const stream = try handle.createStream(.{});
    defer handle.destroyObject(stream.id);
    const start_event = try handle.createEvent(.{});
    defer handle.destroyObject(start_event.id);
    const end_event = try handle.createEvent(.{});
    defer handle.destroyObject(end_event.id);
    const bindings = [_]contract.BufferBinding{
        .{ .handle = counter, .access = .read_write, .ownership = .backend, .byte_size = 4 },
        .{ .handle = output, .access = .write_only, .ownership = .backend, .byte_size = launch_measure_max_dispatches * launch_measure_replays * 4 },
    };
    const launch_request = contract.LaunchRequest{
        .artifact = &artifact,
        .loaded_artifact = loaded,
        .buffers = &bindings,
        .geometry = .{ .grid = .{ 1, 1, 1 }, .threadgroup = .{ 1, 1, 1 } },
        .stream = stream,
    };
    var recorded_request = launch_request;
    recorded_request.stream = null;
    const dispatch = contract.SequenceDispatch{ .name = "increment", .launch = recorded_request };
    var dispatches: [launch_measure_max_dispatches]contract.SequenceDispatch = undefined;
    @memset(&dispatches, dispatch);
    const ns = [_]usize{ 1, 2, 5, 10 };
    for (ns) |count| {
        const sequence = try handle.recordSequence(.{ .dispatches = dispatches[0..count] });
        defer handle.destroyObject(sequence.id);
        for (0..12) |trial| {
            _ = try measureLaunchTrial(handle, sequence, launch_request, count, 16, trial % 2 == 0, counter, stream, start_event, end_event);
        }
        inline for (.{ .{ "single", launch_measure_single_trials, @as(usize, 1) }, .{ "back", launch_measure_back_trials, launch_measure_replays } }) |mode| {
            var host: [2][mode[1]]u64 = undefined;
            var device: [2][mode[1]]u64 = undefined;
            var device_count: [2]usize = .{ 0, 0 };
            for (0..mode[1]) |trial| {
                for (0..2) |order| {
                    const form = (trial + order) % 2;
                    const sample = try measureLaunchTrial(handle, sequence, launch_request, count, mode[2], form == 0, counter, stream, start_event, end_event);
                    host[form][trial] = sample.host_ns;
                    if (sample.device_ns) |elapsed| {
                        device[form][device_count[form]] = elapsed;
                        device_count[form] += 1;
                    }
                }
            }
            for (0..2) |form| {
                const h = launchPercentiles(&host[form]);
                const d = if (device_count[form] != 0) launchPercentiles(device[form][0..device_count[form]]) else .{ 0, 0, 0 };
                std.log.warn("launchcost backend={s} mode={s} form={s} n={d} repeats={d} count={d} host_p10_ns={d} host_median_ns={d} host_p90_ns={d} device_count={d} device_p10_ns={d} device_median_ns={d} device_p90_ns={d}", .{
                    @tagName(kind), mode[0], if (form == 0) "batched" else "unbatched", count, mode[2], mode[1], h[0], h[1], h[2], device_count[form], d[0], d[1], d[2],
                });
            }
        }
    }
}

test "gpu sequence launch cost rows" {
    const sys = @import("sys");
    const build_options = @import("build_options");
    if (sys.env.get("TINY_GPU_SEQUENCE_MEASURE") == null) return error.SkipZigTest;
    if (!build_options.gpu_tests and !build_options.vulkan_tests) return error.SkipZigTest;
    if (build_options.gpu_tests) {
        var cuda_state = try gpu.cuda.State.initDevice(std.testing.allocator, 0);
        defer cuda_state.deinit();
        try measureBackend(cuda_state.handle(), .cuda);
    }
    if (build_options.vulkan_tests) {
        var vulkan_state = try gpu.vulkan.State.initDevice(std.testing.allocator, 0);
        defer vulkan_state.deinit();
        try measureBackend(vulkan_state.handle(), .vulkan);
    }
}
