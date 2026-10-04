const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const memory = @import("memory.zig");

const Allocator = std.mem.Allocator;

pub const required_capabilities = capabilities.noLibc(&.{.allocator});

var process_allocator_override = std.atomic.Value(usize).init(0);
var process_allocator_readers = std.atomic.Value(usize).init(0);
var process_allocator_context: u8 = 0;

const transition_address = 1;

const process_allocator: Allocator = .{
    .ptr = &process_allocator_context,
    .vtable = &process_allocator_vtable,
};

pub const ProcessAllocatorOverride = struct {
    handle: *const Allocator,
    active: bool = true,

    pub fn deinit(self: *ProcessAllocatorOverride) void {
        if (!self.active) return;
        const address = @intFromPtr(self.handle);
        const previous = process_allocator_override.cmpxchgStrong(
            address,
            transition_address,
            .acq_rel,
            .acquire,
        );
        std.debug.assert(previous == null);
        while (process_allocator_readers.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
        process_allocator_override.store(0, .release);
        self.active = false;
    }
};

pub fn processAllocator() Allocator {
    return process_allocator;
}

pub fn observerControlAllocator() Allocator {
    return baseProcessAllocator();
}

pub fn installProcessAllocatorOverride(
    handle: *const Allocator,
) error{AlreadyInstalled}!ProcessAllocatorOverride {
    const address = @intFromPtr(handle);
    std.debug.assert(address > transition_address);
    if (process_allocator_override.cmpxchgStrong(
        0,
        transition_address,
        .acq_rel,
        .acquire,
    ) != null) {
        return error.AlreadyInstalled;
    }
    while (process_allocator_readers.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
    }
    process_allocator_override.store(address, .release);
    return .{ .handle = handle };
}

pub fn hostInteropAllocator() Allocator {
    return processAllocator();
}

pub fn hostInteropFreeRaw(ptr: ?*anyopaque) void {
    _ = ptr;
}

pub fn hostInteropRawFreeAvailable() bool {
    return false;
}

pub fn wasmHostAllocator(fallback: Allocator) Allocator {
    if (comptime builtin.cpu.arch.isWasm()) {
        return fallback;
    }
    return processAllocator();
}

pub fn hostOwnedAllocator() Allocator {
    if (comptime builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding) {
        return std.heap.wasm_allocator;
    }
    return hostInteropAllocator();
}

pub fn requiredHostInteropAllocator(comptime _: []const u8) Allocator {
    return hostInteropAllocator();
}

pub fn benchmarkAllocator() Allocator {
    return processAllocator();
}

pub fn moduleLocalAbiAllocator() Allocator {
    return processAllocator();
}

pub fn preloadBackingAllocator() Allocator {
    return processAllocator();
}

pub fn debugInfoScratchAllocator() Allocator {
    return memory.page_allocator;
}

const ProcessAllocatorSelection = struct {
    allocator: Allocator,

    fn release(_: @This()) void {
        _ = process_allocator_readers.fetchSub(1, .release);
    }
};

fn selectProcessAllocator() ProcessAllocatorSelection {
    while (true) {
        const address = process_allocator_override.load(.acquire);
        if (address == transition_address) {
            std.atomic.spinLoopHint();
            continue;
        }
        _ = process_allocator_readers.fetchAdd(1, .acquire);
        if (process_allocator_override.load(.acquire) == address) {
            return .{
                .allocator = if (address == 0)
                    baseProcessAllocator()
                else
                    @as(*const Allocator, @ptrFromInt(address)).*,
            };
        }
        _ = process_allocator_readers.fetchSub(1, .release);
    }
}

fn processAllocatorAlloc(
    _: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    return_address: usize,
) ?[*]u8 {
    const selected = selectProcessAllocator();
    defer selected.release();
    return selected.allocator.rawAlloc(len, alignment, return_address);
}

fn processAllocatorResize(
    _: *anyopaque,
    memory_slice: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    const selected = selectProcessAllocator();
    defer selected.release();
    return selected.allocator.rawResize(
        memory_slice,
        alignment,
        new_len,
        return_address,
    );
}

fn processAllocatorRemap(
    _: *anyopaque,
    memory_slice: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    const selected = selectProcessAllocator();
    defer selected.release();
    return selected.allocator.rawRemap(
        memory_slice,
        alignment,
        new_len,
        return_address,
    );
}

fn processAllocatorFree(
    _: *anyopaque,
    memory_slice: []u8,
    alignment: std.mem.Alignment,
    return_address: usize,
) void {
    const selected = selectProcessAllocator();
    defer selected.release();
    selected.allocator.rawFree(
        memory_slice,
        alignment,
        return_address,
    );
}

const process_allocator_vtable: Allocator.VTable = .{
    .alloc = processAllocatorAlloc,
    .resize = processAllocatorResize,
    .remap = processAllocatorRemap,
    .free = processAllocatorFree,
};

fn baseProcessAllocator() Allocator {
    if (comptime builtin.cpu.arch.isWasm()) return std.heap.wasm_allocator;
    return std.heap.smp_allocator;
}

fn expectSameAllocator(expected: Allocator, actual: Allocator) !void {
    try std.testing.expectEqual(expected.ptr, actual.ptr);
    try std.testing.expectEqual(expected.vtable, actual.vtable);
}
