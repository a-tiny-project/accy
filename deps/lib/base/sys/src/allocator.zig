const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const memory = @import("memory.zig");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;

pub const required_capabilities = capabilities.noLibc(&.{.allocator});

/// The installed override's handle address, zero for none, or
/// `transition_address` while one is being removed.
var process_allocator_override = std.atomic.Value(usize).init(0);
/// Calls inside an installed override. Calls into the base allocator, which
/// is never freed, are not counted.
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

    /// Removes the override. It returns only after every call that selected
    /// `handle` has returned, so the caller may then free `handle` and what
    /// it names. A call that starts during the removal spins until the
    /// removal completes, then uses the base allocator.
    pub fn deinit(self: *ProcessAllocatorOverride) void {
        if (!self.active) return;
        const address = @intFromPtr(self.handle);
        // Sequentially consistent with a reader's count and recheck: either
        // this drain sees the reader counted, or the reader's recheck sees
        // the transition and backs off.
        const previous = process_allocator_override.cmpxchgStrong(
            address,
            transition_address,
            .seq_cst,
            .seq_cst,
        );
        std.debug.assert(previous == null);
        while (process_allocator_readers.load(.seq_cst) != 0) {
            std.atomic.spinLoopHint();
        }
        // Only this removal leaves the transition.
        std.debug.assert(process_allocator_override.load(.monotonic) == transition_address);
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

/// Routes process allocator calls through `handle` until the returned
/// override's `deinit`. The install takes effect at its store: a call that
/// read the empty override before it completes in the base allocator, even
/// after this returns, and a call ordered after this returns uses `handle`.
/// Blocks cross the boundary both ways. A block the base allocator gave out
/// before the install, or to a call that read the empty override, may reach
/// `handle` to be resized or freed, and a block `handle` gave out may reach
/// the base allocator after `deinit`. So `handle` must accept the base
/// allocator's blocks, or be installed only where no such block is live.
pub fn installProcessAllocatorOverride(
    handle: *const Allocator,
) error{AlreadyInstalled}!ProcessAllocatorOverride {
    const address = @intFromPtr(handle);
    std.debug.assert(address > transition_address);
    if (process_allocator_override.cmpxchgStrong(
        0,
        address,
        .release,
        .monotonic,
    ) != null) {
        return error.AlreadyInstalled;
    }
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
    counted: bool,

    fn release(selection: @This()) void {
        if (!selection.counted) return;
        const previous = process_allocator_readers.fetchSub(1, .release);
        std.debug.assert(previous > 0);
    }
};

/// The allocator a call uses. With no override installed this is one load
/// and no shared write. Only a call into an override is counted, since only
/// an override can be freed under it.
fn selectProcessAllocator() ProcessAllocatorSelection {
    while (true) {
        const address = process_allocator_override.load(.acquire);
        if (address == 0) return .{ .allocator = baseProcessAllocator(), .counted = false };
        if (address == transition_address) {
            std.atomic.spinLoopHint();
            continue;
        }
        _ = process_allocator_readers.fetchAdd(1, .seq_cst);
        if (process_allocator_override.load(.seq_cst) == address) {
            return .{
                .allocator = @as(*const Allocator, @ptrFromInt(address)).*,
                .counted = true,
            };
        }
        const previous = process_allocator_readers.fetchSub(1, .release);
        std.debug.assert(previous > 0);
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

/// An override that delegates every call to the base allocator, so blocks
/// crossing between the two in either direction are legitimate here. Its
/// allocations wait inside it until `released`.
const HeldOverride = struct {
    inside: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *HeldOverride) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *HeldOverride = @ptrCast(@alignCast(context));
        self.inside.store(true, .release);
        while (!self.released.load(.acquire)) std.atomic.spinLoopHint();
        return baseProcessAllocator().rawAlloc(len, alignment, return_address);
    }

    fn resize(
        _: *anyopaque,
        slice: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        return baseProcessAllocator().rawResize(slice, alignment, new_len, return_address);
    }

    fn remap(
        _: *anyopaque,
        slice: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        return baseProcessAllocator().rawRemap(slice, alignment, new_len, return_address);
    }

    fn free(_: *anyopaque, slice: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        baseProcessAllocator().rawFree(slice, alignment, return_address);
    }
};

fn allocateOnce() void {
    const bytes = processAllocator().alloc(u8, 16) catch
        @panic("process allocator test allocation failed");
    processAllocator().free(bytes);
}

fn removeOverride(session: *ProcessAllocatorOverride, removed: *std.atomic.Value(bool)) void {
    session.deinit();
    removed.store(true, .release);
}
