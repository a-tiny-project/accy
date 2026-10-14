const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const diagnostics = @import("diagnostics.zig");
const heap = @import("heap.zig");
const process = @import("process.zig");

const Allocator = std.mem.Allocator;

pub const TestAllocatorMode = enum {
    fast,
    leak_check,
};

pub const test_allocator_mode: TestAllocatorMode = parseTestAllocatorMode();

/// Returns the allocator for storage that lives for the whole process. Which
/// allocator that is comes from the build's diagnostics setting and its phase
/// setting. Everything taken from it goes back through it before the process
/// finishes tearing down.
pub fn longLivedProcessAllocator() Allocator {
    return platformProcessAllocator();
}

/// Returns the allocator for storage that stays valid for the session around
/// the call. Memory taken from it goes back through the same allocator. It uses
/// the `fallback` the caller passes in two cases: a test build running the
/// leak-checking policy, and a WebAssembly target. Everywhere else it returns
/// the process allocator.
pub fn interactiveSessionAllocator(fallback: Allocator) Allocator {
    if (comptime builtin.is_test) return testAllocatorForMode(fallback);
    if (comptime diagnostics.config() != null) return platformProcessAllocator();
    if (comptime builtin.cpu.arch.isWasm()) return fallback;
    return platformProcessAllocator();
}

pub fn standaloneProcessAllocator() Allocator {
    if (comptime builtin.is_test) return testIntegrationAllocator();
    return platformProcessAllocator();
}

pub fn workerAllocator() Allocator {
    if (comptime builtin.is_test) return testIntegrationAllocator();
    return platformProcessAllocator();
}

pub fn threadedIoAllocator() Allocator {
    return workerAllocator();
}

pub fn temporaryScratchAllocator() Allocator {
    if (comptime builtin.is_test) return testIntegrationAllocator();
    return platformProcessAllocator();
}

pub fn testIntegrationAllocator() Allocator {
    if (comptime !builtin.is_test) @compileError("testIntegrationAllocator is test-only");
    return testAllocatorForMode(std.testing.allocator);
}

pub fn platformProcessAllocator() Allocator {
    if (comptime diagnostics.config()) |diagnostic_config| {
        if (@inComptime()) @compileError("allocator diagnostics require runtime allocator selection");
        return process.wrap(diagnostics.processAllocator(diagnostic_config));
    }
    if (comptime process.mode == .off) return heap.processHeapAllocator();
    if (@inComptime()) @compileError("allocator phase enforcement requires runtime allocator selection");
    return process.wrap(heap.processHeapAllocator());
}

/// Marks the moment startup is over, after which the package can tell a startup
/// allocation from a later one: it ends the initialization phase of the process
/// allocator. A caller makes this call once, after the storage it needs at
/// startup has been taken. What happens to an allocation that arrives after the
/// seal is decided by the process phase mode: under `observe` it is counted and
/// goes through, and under `seal` it panics. Under the `off` mode the call does
/// nothing.
pub fn sealProcessAllocatorPhase() void {
    if (comptime process.mode == .off) return;
    _ = platformProcessAllocator();
    process.seal();
}

/// Opens the teardown phase, so a free that follows counts as no violation and
/// a caller can release the storage taken at startup. A caller makes this call
/// after steady work has stopped and before releasing the storage that lives as
/// long as the process. Under the `off` mode the call does nothing.
pub fn beginProcessAllocatorTeardown() void {
    if (comptime process.mode == .off) return;
    _ = platformProcessAllocator();
    process.beginTeardown();
}

fn testAllocatorForMode(leak_allocator: Allocator) Allocator {
    if (comptime !builtin.is_test) @compileError("testAllocatorForMode is test-only");
    return switch (test_allocator_mode) {
        .fast => platformProcessAllocator(),
        .leak_check => leak_allocator,
    };
}

fn parseTestAllocatorMode() TestAllocatorMode {
    if (std.mem.eql(u8, build_options.test_allocator_mode, "fast")) return .fast;
    if (std.mem.eql(u8, build_options.test_allocator_mode, "leak_check")) return .leak_check;
    @compileError("unknown test allocator mode");
}
