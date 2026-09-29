const std = @import("std");
const coz = @import("coz");
const deadalloc = @import("deadalloc");
const preload_options = @import("preload_options");
const sys = @import("sys");

pub const c_alignment = 16;

const Metadata = struct {
    requested_len: usize,
    allocation_len: usize,
    alignment: usize,
    owner_thread: sys.thread.Id,
};

const RemoteFree = struct {
    address: usize,
    metadata: Metadata,
};

var preload_lock: std.atomic.Mutex = .unlocked;
var heap: deadalloc.DeadAllocator = deadalloc.DeadAllocator.init(
    sys.allocator.preloadBackingAllocator(),
    preloadConfig(),
);
var live_allocations: std.AutoHashMapUnmanaged(usize, Metadata) = .empty;
var freed_allocations: std.AutoHashMapUnmanaged(usize, Metadata) = .empty;
var pending_remote_frees: std.ArrayListUnmanaged(RemoteFree) = .empty;

pub fn allocate(requested_size: usize, requested_alignment: usize) ?*anyopaque {
    lockPreload();
    defer unlockPreload();
    return allocateLocked(requested_size, requested_alignment);
}

pub fn deallocate(ptr: ?*anyopaque) void {
    lockPreload();
    defer unlockPreload();
    deallocateLocked(ptr);
}

pub fn reallocate(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    const phase = coz.scope("deadalloc.preload.realloc");
    defer phase.end();

    lockPreload();
    defer unlockPreload();

    const old_ptr = ptr orelse return allocateLocked(size, c_alignment);
    if (size == 0) {
        deallocateLocked(old_ptr);
        return null;
    }

    const address = @intFromPtr(old_ptr);
    const old_metadata = live_allocations.get(address) orelse {
        reportNonLiveReallocLocked(old_ptr, address);
        return null;
    };
    const new_allocation_len = allocationLen(size);
    const alignment = std.mem.Alignment.fromByteUnits(old_metadata.alignment);
    const old_bytes = asBytes(old_ptr, old_metadata.allocation_len);
    if (heap.rawResize(old_bytes, alignment, new_allocation_len, @returnAddress())) {
        const metadata = live_allocations.getPtr(address) orelse return null;
        metadata.* = .{
            .requested_len = size,
            .allocation_len = new_allocation_len,
            .alignment = old_metadata.alignment,
            .owner_thread = old_metadata.owner_thread,
        };
        return old_ptr;
    }

    const new_ptr = allocateLocked(size, old_metadata.alignment) orelse return null;
    const copy_len = @min(size, old_metadata.requested_len);
    @memcpy(asBytes(new_ptr, copy_len), asBytes(old_ptr, copy_len));
    deallocateLocked(old_ptr);
    return new_ptr;
}

pub fn usableSize(ptr: ?*anyopaque) usize {
    lockPreload();
    defer unlockPreload();
    const user_ptr = ptr orelse return 0;
    return if (live_allocations.get(@intFromPtr(user_ptr))) |metadata| metadata.requested_len else 0;
}

pub fn report() deadalloc.Report {
    lockPreload();
    defer unlockPreload();
    return heap.report();
}

pub fn pendingRemoteFreeCount() usize {
    lockPreload();
    defer unlockPreload();
    return pending_remote_frees.items.len;
}

fn allocateLocked(requested_size: usize, requested_alignment: usize) ?*anyopaque {
    const phase = coz.scope("deadalloc.preload.allocate");
    defer phase.end();

    const alignment_bytes = @max(requested_alignment, c_alignment);
    if (!validAlignment(alignment_bytes)) return null;
    drainRemoteFreesForCurrentThread();
    const allocation_len = allocationLen(requested_size);
    const alignment = std.mem.Alignment.fromByteUnits(alignment_bytes);
    const ptr = heap.rawAlloc(allocation_len, alignment, @returnAddress()) orelse return null;
    const address = @intFromPtr(ptr);
    live_allocations.put(
        metadataAllocator(),
        address,
        .{
            .requested_len = requested_size,
            .allocation_len = allocation_len,
            .alignment = alignment_bytes,
            .owner_thread = currentThreadId(),
        },
    ) catch {
        heap.rawFree(ptr[0..allocation_len], alignment, @returnAddress());
        return null;
    };
    _ = freed_allocations.remove(address);
    coz.progressNamed("deadalloc.preload.allocate.complete");
    return @ptrCast(ptr);
}

fn deallocateLocked(ptr: ?*anyopaque) void {
    const phase = coz.scope("deadalloc.preload.free");
    defer phase.end();

    const user_ptr = ptr orelse return;
    const address = @intFromPtr(user_ptr);
    const bytes: [*]u8 = @ptrCast(user_ptr);
    if (live_allocations.fetchRemove(address)) |entry| {
        if (queueRemoteFree(address, entry.value)) return;
        freed_allocations.put(metadataAllocator(), address, entry.value) catch {};
        heap.rawFree(
            bytes[0..entry.value.allocation_len],
            std.mem.Alignment.fromByteUnits(entry.value.alignment),
            @returnAddress(),
        );
        coz.progressNamed("deadalloc.preload.free.live_complete");
        return;
    }
    if (freed_allocations.get(address)) |metadata| {
        if (shouldDeferRemoteFree(metadata)) return;
        const freed_metadata = removePendingRemoteFree(address) orelse metadata;
        heap.rawFree(
            bytes[0..freed_metadata.allocation_len],
            std.mem.Alignment.fromByteUnits(freed_metadata.alignment),
            @returnAddress(),
        );
        coz.progressNamed("deadalloc.preload.free.diagnostic_complete");
        return;
    }
    heap.rawFree(bytes[0..0], std.mem.Alignment.fromByteUnits(c_alignment), @returnAddress());
    coz.progressNamed("deadalloc.preload.free.invalid_complete");
}

fn queueRemoteFree(address: usize, metadata: Metadata) bool {
    if (!shouldDeferRemoteFree(metadata)) return false;
    pending_remote_frees.append(metadataAllocator(), .{
        .address = address,
        .metadata = metadata,
    }) catch return false;
    freed_allocations.put(metadataAllocator(), address, metadata) catch {};
    coz.progressNamed("deadalloc.preload.remote_free.queued");
    return true;
}

fn removePendingRemoteFree(address: usize) ?Metadata {
    var index: usize = 0;
    while (index < pending_remote_frees.items.len) : (index += 1) {
        if (pending_remote_frees.items[index].address != address) continue;
        const removed = pending_remote_frees.swapRemove(index);
        return removed.metadata;
    }
    return null;
}

fn reportNonLiveReallocLocked(ptr: *anyopaque, address: usize) void {
    const bytes: [*]u8 = @ptrCast(ptr);
    if (freed_allocations.get(address)) |metadata| {
        if (shouldDeferRemoteFree(metadata)) return;
        const freed_metadata = removePendingRemoteFree(address) orelse metadata;
        heap.rawFree(
            bytes[0..freed_metadata.allocation_len],
            std.mem.Alignment.fromByteUnits(freed_metadata.alignment),
            @returnAddress(),
        );
        return;
    }
    heap.rawFree(bytes[0..0], std.mem.Alignment.fromByteUnits(c_alignment), @returnAddress());
}

fn drainRemoteFreesForCurrentThread() void {
    if (!dieharderPreload()) return;
    const phase = coz.scope("deadalloc.preload.remote_free_drain");
    defer phase.end();

    const thread_id = currentThreadId();
    var index: usize = 0;
    while (index < pending_remote_frees.items.len) {
        const pending = pending_remote_frees.items[index];
        if (pending.metadata.owner_thread != thread_id) {
            index += 1;
            continue;
        }
        const removed = pending_remote_frees.swapRemove(index);
        const bytes: [*]u8 = @ptrFromInt(removed.address);
        heap.rawFree(
            bytes[0..removed.metadata.allocation_len],
            std.mem.Alignment.fromByteUnits(removed.metadata.alignment),
            @returnAddress(),
        );
        coz.progressNamed("deadalloc.preload.remote_free_drain.item");
    }
}

fn shouldDeferRemoteFree(metadata: Metadata) bool {
    return dieharderPreload() and metadata.owner_thread != currentThreadId();
}

fn allocationLen(requested_size: usize) usize {
    return @max(requested_size, 1);
}

pub fn asBytes(ptr: *anyopaque, len: usize) []u8 {
    const bytes: [*]u8 = @ptrCast(ptr);
    return bytes[0..len];
}

pub fn validAlignment(alignment: usize) bool {
    return alignment != 0 and std.math.isPowerOfTwo(alignment);
}

pub fn alignPageLen(size: usize) ?usize {
    const adjusted = std.math.add(usize, size, deadalloc.page_size - 1) catch return null;
    return std.mem.alignBackward(usize, adjusted, deadalloc.page_size);
}

pub fn boundedStringLen(s: [*]const u8, max_len: usize) usize {
    var len: usize = 0;
    while (len < max_len and s[len] != 0) : (len += 1) {}
    return len;
}

fn metadataAllocator() std.mem.Allocator {
    return sys.allocator.preloadBackingAllocator();
}

fn preloadConfig() deadalloc.Config {
    if (comptime std.mem.eql(u8, preload_options.mode, "diehard")) return .{ .mode = .diehard };
    if (comptime std.mem.eql(u8, preload_options.mode, "dieharder")) return .{ .mode = .dieharder };
    if (comptime std.mem.eql(u8, preload_options.mode, "exterminator")) return deadalloc.Config.diagnostic(.exterminator);
    @compileError("unknown deadalloc preload mode");
}

pub fn dieharderPreload() bool {
    return comptime std.mem.eql(u8, preload_options.mode, "dieharder");
}

pub fn diagnosticsEnabled() bool {
    return comptime std.mem.eql(u8, preload_options.mode, "exterminator");
}

fn currentThreadId() sys.thread.Id {
    return sys.thread.currentId();
}

fn lockPreload() void {
    while (!preload_lock.tryLock()) std.atomic.spinLoopHint();
}

fn unlockPreload() void {
    preload_lock.unlock();
}
