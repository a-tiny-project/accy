const std = @import("std");
const build_options = @import("build_options");

const phase = @import("alloc_phase");

const Allocator = std.mem.Allocator;

pub const ProcessPhaseMode = enum {
    off,
    observe,
    seal,
};

pub const mode: ProcessPhaseMode = parseMode();

const ProcessPhaseAllocator = switch (mode) {
    .off => void,
    .observe => phase.ObservingPhaseAllocator,
    .seal => phase.SealedPhaseAllocator,
};

var lock: std.atomic.Mutex = .unlocked;
var initialized = false;
var storage: ProcessPhaseAllocator = undefined;
var handle: Allocator = undefined;

pub fn wrap(backing: Allocator) Allocator {
    if (comptime mode == .off) return backing;
    lockInit();
    defer unlockInit();
    if (!initialized) {
        storage = ProcessPhaseAllocator.init(backing) catch
            @panic("out of memory initializing process allocator phase");
        handle = storage.initializationAllocator();
        initialized = true;
    }
    return handle;
}

pub fn seal() void {
    if (comptime mode == .off) return;
    lockInit();
    defer unlockInit();
    if (!initialized) @panic("process allocator phase sealed before first use");
    storage.seal();
}

pub fn beginTeardown() void {
    if (comptime mode == .off) return;
    lockInit();
    defer unlockInit();
    if (!initialized) @panic("process allocator phase teardown before first use");
    storage.beginTeardown();
}

pub fn violations() ?phase.PhaseViolations {
    if (comptime mode == .off) return null;
    lockInit();
    defer unlockInit();
    if (!initialized) return .{};
    return storage.violations();
}

pub fn violationSites() ?phase.ViolationSites {
    if (comptime mode != .observe) return null;
    lockInit();
    defer unlockInit();
    if (!initialized) return .{};
    return storage.violationSites();
}

pub fn currentPhase() ?phase.capacity.Phase {
    if (comptime mode == .off) return null;
    lockInit();
    defer unlockInit();
    if (!initialized) return .initialization;
    return storage.phase();
}

fn parseMode() ProcessPhaseMode {
    if (std.mem.eql(u8, build_options.allocator_phase, "off")) return .off;
    if (std.mem.eql(u8, build_options.allocator_phase, "observe")) return .observe;
    if (std.mem.eql(u8, build_options.allocator_phase, "seal")) return .seal;
    @compileError("unknown allocator phase mode");
}

fn lockInit() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

fn unlockInit() void {
    lock.unlock();
}
