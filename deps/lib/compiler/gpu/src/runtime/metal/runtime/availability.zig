const std = @import("std");
const sys = @import("sys");

const runtime = @import("root.zig");
const foundation = sys.apple.foundation;
const metal = sys.apple.metal;
const objc = sys.apple.objc;

pub fn detectAvailability() runtime.Availability {
    if (comptime !metal.available) return .unsupported_platform;

    var pool = foundation.AutoreleasePool.init() orelse return .runtime_missing;
    defer pool.deinit();
    const device = metal.systemDefaultDevice() orelse return .device_missing;
    defer objc.release(device);
    const queue = metal.newCommandQueue(device) orelse return .runtime_missing;
    objc.release(queue);
    return .available;
}
