const std = @import("std");
const build_options = @import("build_options");
const deadalloc = @import("deadalloc");
const sys = @import("sys");

const Allocator = std.mem.Allocator;

pub const mode: ?deadalloc.Mode = parseMode();

var lock: std.atomic.Mutex = .unlocked;
var initialized = false;
var storage: deadalloc.DeadAllocator = undefined;

pub fn config() ?deadalloc.Config {
    const diagnostics_mode = mode orelse return null;
    return deadalloc.Config.diagnostic(diagnostics_mode);
}

pub fn report() ?deadalloc.Report {
    if (comptime mode == null) return null;
    lockInit();
    defer unlockInit();
    if (!initialized) return .{};
    return storage.report();
}

pub fn processAllocator(diagnostic_config: deadalloc.Config) Allocator {
    lockInit();
    defer unlockInit();
    if (!initialized) {
        storage = deadalloc.DeadAllocator.init(baseProcessAllocator(), diagnostic_config);
        initialized = true;
    }
    return storage.allocator();
}

pub fn baseProcessAllocator() Allocator {
    return sys.allocator.processAllocator();
}

fn parseMode() ?deadalloc.Mode {
    if (std.mem.eql(u8, build_options.allocator_diagnostics, "off")) return null;
    if (std.mem.eql(u8, build_options.allocator_diagnostics, "diehard")) return .diehard;
    if (std.mem.eql(u8, build_options.allocator_diagnostics, "dieharder")) return .dieharder;
    if (std.mem.eql(u8, build_options.allocator_diagnostics, "exterminator")) return .exterminator;
    @compileError("unknown allocator diagnostics mode");
}

fn lockInit() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

fn unlockInit() void {
    lock.unlock();
}
