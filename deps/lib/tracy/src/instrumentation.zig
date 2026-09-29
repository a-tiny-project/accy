const std = @import("std");
const build_options = @import("build_options");
const allocator_mod = @import("allocator.zig");
const runtime = @import("runtime.zig");
const summary = @import("summary.zig");

const SourceLocation = std.builtin.SourceLocation;
const ContextSwitchOptions = runtime.ContextSwitchOptions;
const CpuTopology = runtime.CpuTopology;
const Fiber = runtime.Fiber;
const GpuContext = runtime.GpuContext;
const GpuContextOptions = runtime.GpuContextOptions;
const HardwareSampleKind = runtime.HardwareSampleKind;
const Lock = runtime.Lock;
const PlotConfig = runtime.PlotConfig;
const SampleFrame = runtime.SampleFrame;
const SampleKind = runtime.SampleKind;
const StartOptions = runtime.StartOptions;
const ThreadWakeupOptions = runtime.ThreadWakeupOptions;
const TracedAllocator = allocator_mod.TracedAllocator;
const Zone = runtime.Zone;

pub fn start(writer: *std.Io.Writer, options: StartOptions) !bool {
    return try runtime.start(writer, options);
}

pub fn stop() void {
    runtime.stop();
}

pub fn tracedAllocator(backing: std.mem.Allocator) TracedAllocator {
    return allocator_mod.trace(backing);
}

pub fn namedAllocator(backing: std.mem.Allocator, name: []const u8) TracedAllocator {
    return allocator_mod.traceNamed(backing, name);
}

pub inline fn zone(comptime name: [:0]const u8) Zone {
    return zoneAt(name, @src());
}

pub inline fn zoneAt(comptime name: [:0]const u8, comptime src: SourceLocation) Zone {
    return runtime.zoneAt(name, src, null);
}

pub inline fn zoneColor(comptime name: [:0]const u8, comptime color: u32) Zone {
    return zoneColorAt(name, color, @src());
}

pub inline fn zoneColorAt(comptime name: [:0]const u8, comptime color: u32, comptime src: SourceLocation) Zone {
    return runtime.zoneAt(name, src, color);
}

pub inline fn lockable(comptime name: [:0]const u8) Lock {
    return lockableAt(name, @src());
}

pub inline fn lockableAt(comptime name: [:0]const u8, comptime src: SourceLocation) Lock {
    return runtime.lockableAt(name, src);
}

pub inline fn sharedLockable(comptime name: [:0]const u8) Lock {
    return sharedLockableAt(name, @src());
}

pub inline fn sharedLockableAt(comptime name: [:0]const u8, comptime src: SourceLocation) Lock {
    return runtime.sharedLockableAt(name, src);
}

pub inline fn frameMark() void {
    runtime.frame(null);
}

pub inline fn frameMarkNamed(comptime name: [:0]const u8) void {
    runtime.frame(name);
}

pub inline fn sample(comptime name: [:0]const u8) void {
    runtime.sampleAt(name, .manual, @src());
}

pub inline fn sampleKind(comptime name: [:0]const u8, kind: SampleKind) void {
    runtime.sampleAt(name, kind, @src());
}

pub inline fn sampleWeighted(comptime name: [:0]const u8, kind: SampleKind, weight: u64) void {
    runtime.sampleWeightedAt(name, kind, weight, @src());
}

pub inline fn sampleStack(name: []const u8, kind: SampleKind, frames: []const SampleFrame) void {
    runtime.sampleStack(name, kind, frames);
}

pub inline fn sampleStackWeighted(name: []const u8, kind: SampleKind, frames: []const SampleFrame, weight: u64) void {
    runtime.sampleStackWeighted(name, kind, frames, weight);
}

pub inline fn newFiber(comptime name: [:0]const u8) Fiber {
    return runtime.fiber(name, 0);
}

pub inline fn newFiberHint(comptime name: [:0]const u8, comptime group_hint: i32) Fiber {
    return runtime.fiber(name, group_hint);
}

pub inline fn newFiberNamed(name: []const u8) Fiber {
    return runtime.fiber(name, 0);
}

pub inline fn newFiberNamedHint(name: []const u8, group_hint: i32) Fiber {
    return runtime.fiber(name, group_hint);
}

pub inline fn gpuContext(options: GpuContextOptions) GpuContext {
    return runtime.gpuContext(options);
}

pub inline fn contextSwitch(options: ContextSwitchOptions) void {
    runtime.contextSwitch(options);
}

pub inline fn threadWakeup(options: ThreadWakeupOptions) void {
    runtime.threadWakeup(options);
}

pub inline fn threadContext(thread: u64, name: ?[]const u8) void {
    runtime.threadContext(thread, name);
}

pub inline fn threadPid(thread: u64, pid: u64) void {
    runtime.threadPid(thread, pid);
}

pub inline fn cpuTopology(topology: CpuTopology) void {
    runtime.cpuTopology(topology);
}

pub inline fn systemTime(value: f64) void {
    runtime.systemTime(value);
}

pub inline fn systemPower(name: []const u8, delta_uj: u64) void {
    runtime.systemPower(name, delta_uj);
}

pub inline fn hardwareSample(kind: HardwareSampleKind, address: u64) void {
    runtime.hardwareSample(kind, address);
}

pub inline fn message(text: []const u8) void {
    runtime.message(text);
}

pub inline fn appInfo(text: []const u8) void {
    runtime.appInfo(text);
}

pub inline fn plotConfig(comptime name: [:0]const u8, config: PlotConfig) void {
    runtime.plotConfig(name, config);
}

pub inline fn plot(comptime name: [:0]const u8, value: f64) void {
    runtime.plotFloat(name, value);
}

pub inline fn plotFloat(comptime name: [:0]const u8, value: f32) void {
    runtime.plotFloat(name, @floatCast(value));
}

pub inline fn plotInt(comptime name: [:0]const u8, value: i64) void {
    runtime.plotInt(name, value);
}

pub inline fn alloc(ptr: ?*const anyopaque, size: usize) void {
    runtime.alloc(ptr, size);
}

pub inline fn allocNamed(ptr: ?*const anyopaque, size: usize, name: []const u8) void {
    runtime.allocNamed(ptr, size, name);
}

pub inline fn free(ptr: ?*const anyopaque) void {
    runtime.free(ptr);
}

pub inline fn freeNamed(ptr: ?*const anyopaque, name: []const u8) void {
    runtime.freeNamed(ptr, name);
}

pub inline fn freeSized(ptr: ?*const anyopaque, size: usize) void {
    runtime.freeSized(ptr, size);
}

pub inline fn freeSizedNamed(ptr: ?*const anyopaque, size: usize, name: []const u8) void {
    runtime.freeSizedNamed(ptr, size, name);
}

pub inline fn setThreadName(comptime name: [:0]const u8) void {
    runtime.threadName(name);
}

pub inline fn isConnected() bool {
    return runtime.isActive();
}

test "instrumentation calls compile" {
    setThreadName("tracy-test");
    appInfo("tracy package test");
    message("tracy message");
    plotConfig("tracy.plot", .{ .unit = .nanoseconds, .step = true });
    plot("tracy.plot", 1.25);
    plotFloat("tracy.plot_float", 1.5);
    plotInt("tracy.plot_int", 2);
    frameMark();
    frameMarkNamed("tracy.frame");
    sample("tracy.sample");
    sampleKind("tracy.cpu.sample", .cpu);
    sampleWeighted("tracy.wall.sample", .wall, 3);
    sampleStack("tracy.stack.sample", .manual, &.{
        .{ .name = "root", .function = "root", .file = "root.zig", .line = 1 },
        .{ .name = "leaf", .function = "leaf", .file = "leaf.zig", .line = 2 },
    });
    const profiled_fiber = newFiberHint("tracy.fiber", 7);
    profiled_fiber.enter();
    message("tracy fiber message");
    profiled_fiber.leave();
    const dynamic_fiber = newFiberNamed("tracy.dynamic_fiber");
    dynamic_fiber.enter();
    dynamic_fiber.leave();
    const profiled_gpu = gpuContext(.{ .name = "tracy.gpu", .context_type = .vulkan, .period = 1.0, .gpu_time = 0 });
    profiled_gpu.setName("tracy dynamic gpu");
    profiled_gpu.sync(0);
    profiled_gpu.calibrate(1, 1);
    profiled_gpu.annotationName(7, "occupancy");
    profiled_gpu.annotate(7, 0.5);
    const gpu_query = profiled_gpu.nextQuery();
    const gpu_zone = profiled_gpu.zoneQuery("tracy.gpu.zone", gpu_query);
    gpu_zone.annotate(7, 0.75);
    gpu_zone.endQueryWithTimes(profiled_gpu.nextQuery(), 1, 3);
    contextSwitch(.{ .cpu = 0, .prev_thread = 1, .next_thread = 2, .reason = "WrPreempted", .state = "Ready" });
    threadWakeup(.{ .thread = 1, .cpu = 0, .reason = "Unwait" });
    threadContext(2, "worker");
    threadPid(2, 900);
    cpuTopology(.{ .cpu = 0, .package = 0, .die = 0, .core = 0 });
    systemTime(0.25);
    systemPower("package", 100);
    hardwareSample(.cache_miss, 0x1234);

    const active_zone = zone("tracy.zone");
    active_zone.setName("tracy dynamic zone");
    active_zone.setText("tracy zone text");
    active_zone.setColor(0x44aa88);
    active_zone.setValue(42);
    active_zone.end();

    const profiled_lock = lockable("tracy.lock");
    profiled_lock.wait();
    profiled_lock.obtain();
    profiled_lock.markAt(@src());
    profiled_lock.setName("tracy dynamic lock");
    profiled_lock.release();
    profiled_lock.terminate();

    const profiled_shared_lock = sharedLockable("tracy.shared_lock");
    profiled_shared_lock.sharedWait();
    profiled_shared_lock.sharedObtain();
    profiled_shared_lock.sharedRelease();
    profiled_shared_lock.terminate();

    alloc(null, 0);
    allocNamed(null, 0, "tracy.named.alloc");
    free(null);
    freeNamed(null, "tracy.named.free");
    freeSized(null, 0);
    freeSizedNamed(null, 0, "tracy.named.free_sized");
    _ = isConnected();
}

test "enabled trace records analyzable zones" {
    if (!build_options.enabled) return;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expect(try start(&out.writer, .{ .name = "root test" }));
    defer stop();
    const active_zone = zone("root.test.zone");
    active_zone.setValue(12);
    active_zone.end();
    const profiled_lock = lockable("root.test.lock");
    profiled_lock.wait();
    profiled_lock.obtain();
    profiled_lock.release();
    profiled_lock.terminate();
    message("root test message");
    sample("root.test.sample");
    const profiled_fiber = newFiberHint("root.test.fiber", 2);
    profiled_fiber.enter();
    message("root fiber message");
    profiled_fiber.leave();
    contextSwitch(.{ .cpu = 0, .prev_thread = 1, .next_thread = 2, .reason = "WrPreempted", .state = "Ready" });
    threadWakeup(.{ .thread = 1, .cpu = 0, .reason = "Unwait" });
    plotInt("root.test.plot", 7);
    stop();

    var analyzer = summary.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(out.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.completed_zones);
    try std.testing.expectEqual(@as(u64, 2), analyzer.counters.messages);
    try std.testing.expectEqual(@as(u64, 1), analyzer.samples.counters.samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.fibers.counters.names);
    try std.testing.expectEqual(@as(u64, 1), analyzer.fibers.counters.enters);
    try std.testing.expectEqual(@as(u64, 1), analyzer.fibers.counters.leaves);
    try std.testing.expectEqual(@as(u64, 1), analyzer.context.counters.switches);
    try std.testing.expectEqual(@as(u64, 1), analyzer.context.counters.wakeups);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.plots);
    try std.testing.expectEqual(@as(usize, 1), analyzer.locks.locks.count());
    try std.testing.expectEqual(@as(u64, 1), analyzer.locks.counters.completed_waits);
    try std.testing.expectEqual(@as(u64, 1), analyzer.locks.counters.completed_holds);
}

test {
    std.testing.refAllDecls(@This());
}
