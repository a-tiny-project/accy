const std = @import("std");
const builtin = @import("builtin");
const gpalloc = @import("gpalloc");
const sys = @import("sys");

const Allocator = std.mem.Allocator;

const process_heap_supported =
    !builtin.cpu.arch.isWasm() and
    !(builtin.output_mode == .Lib and builtin.link_mode == .dynamic);

var process_heap_cell: std.atomic.Value(?*gpalloc.GpAllocator) = .init(null);
var process_heap_lock: sys.thread.Mutex = .{};

pub fn processHeapAllocator() Allocator {
    if (comptime !process_heap_supported) return sys.allocator.processAllocator();
    return ensureProcessHeap().allocator();
}

fn ensureProcessHeap() *gpalloc.GpAllocator {
    if (process_heap_cell.load(.acquire)) |existing| return existing;
    process_heap_lock.lock();
    defer process_heap_lock.unlock();
    if (process_heap_cell.load(.acquire)) |existing| return existing;
    const created = sys.allocator.processAllocator().create(gpalloc.GpAllocator) catch
        @panic("out of memory allocating process heap");
    created.* = gpalloc.GpAllocator.init(sys.memory.page_allocator, .{
        .page_provider = .os,
    });
    process_heap_cell.store(created, .release);
    return created;
}
