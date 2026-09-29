const std = @import("std");
const runtime = @import("gpu_metal_runtime");

export fn gpu_metal_semantic_init() callconv(.c) void {
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var owned = runtime.Runtime.init(fixed.allocator()) catch return;
    owned.deinit();
}

export fn gpu_metal_semantic_load(owner: *runtime.Runtime) callconv(.c) void {
    var msl = owner.loadMsl(
        "kernel void semantic_probe() {}",
        "semantic_probe",
        0,
    ) catch return;
    msl.deinit();

    var metallib = owner.loadMetallib(
        &.{ 0xca, 0xfe, 0xba, 0xbe },
        "semantic_probe",
        0,
    ) catch return;
    metallib.deinit();
}

export fn gpu_metal_semantic_objects(
    owner: *runtime.Runtime,
    kernel: *runtime.LoadedKernel,
    buffer: *runtime.DeviceBuffer,
    stream: *runtime.Stream,
    event: *runtime.Event,
) callconv(.c) void {
    var bytes = [_]u8{ 1, 2, 3, 4 };
    buffer.write(&bytes) catch return;
    buffer.read(&bytes) catch return;
    event.record(stream) catch return;
    _ = event.query() catch return;
    event.synchronize() catch return;
    stream.synchronize() catch return;

    const buffers = [_]*runtime.DeviceBuffer{buffer};
    const scalars = [_]runtime.ScalarArgument{.{ .tag = .u32, .bits = 1 }};
    const waits = [_]*runtime.Event{event};
    owner.launch(
        kernel,
        &buffers,
        &scalars,
        stream,
        &waits,
        event,
        .{ 1, 1, 1 },
        .{ 1, 1, 1 },
    ) catch return;
    owner.synchronize() catch return;
    _ = owner.defaultStream() catch return;
}

export fn gpu_metal_semantic_ownership(owner: *runtime.Runtime) callconv(.c) void {
    var buffer = owner.allocBuffer(64) catch return;
    buffer.deinit();
    const stream = owner.createStream() catch return;
    owner.destroyStream(stream);
    const event = owner.createEvent() catch return;
    owner.destroyEvent(event);
}
