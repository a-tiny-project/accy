const std = @import("std");
const builtin = @import("builtin");
const tls = @import("gpalloc_thread_cache_slot");
const sys = @import("sys");
const page_mod = @import("../page/root.zig");
const pointer = @import("pointer.zig");
const size_class = @import("../root.zig").class;
const thread = @import("thread.zig");

const sys_thread = sys.thread;
const FreeNode = page_mod.FreeNode;
const invalid_extra_class_index = std.math.maxInt(u8);
const ThreadCacheBin = pointer.PointerBin(thread.capacity);
const ExtraThreadCacheBin = pointer.PointerBin(thread.extra_bin_capacity);
const linked_class_count = size_class.count - thread.fixed_class_count;
const preload_build = builtin.output_mode == .Lib and builtin.link_mode == .dynamic;
const preload_extra_class_lookup = buildPreloadExtraClassLookup();

pub const ThreadCache = struct {
    owner: ?*anyopaque = null,
    storage_owner: ?*anyopaque = null,
    next_retained: ?*ThreadCache = null,
    bins: [thread.fixed_class_count]ThreadCacheBin = @as([thread.fixed_class_count]ThreadCacheBin, @splat(.{})),
    extra_bins: [thread.extra_class_count]ExtraThreadCacheBin =
        @as([thread.extra_class_count]ExtraThreadCacheBin, @splat(.{})),
    linked_heads: [linked_class_count]?*FreeNode = @as([linked_class_count]?*FreeNode, @splat(null)),
    linked_counts: [linked_class_count]u16 = @as([linked_class_count]u16, @splat(0)),

    pub fn reset(cache: *ThreadCache, owner: *anyopaque) void {
        cache.owner = owner;
        cache.storage_owner = owner;
        cache.next_retained = null;
        for (&cache.bins) |*bin| bin.count = 0;
        for (&cache.extra_bins) |*bin| bin.count = 0;
        @memset(&cache.linked_heads, null);
        @memset(&cache.linked_counts, 0);
    }
};

pub inline fn loadThreadCache() ?*ThreadCache {
    return @ptrCast(@alignCast(tls.load()));
}

pub inline fn loadThreadCacheForSmallFastPath() ?*ThreadCache {
    return loadThreadCache();
}

pub inline fn loadThreadCacheForAllocFastPath() ?*ThreadCache {
    return loadThreadCache();
}

pub inline fn storeThreadCache(cache: ?*ThreadCache) void {
    tls.store(cache);
}

pub inline fn localThreadCacheBinCount(cache: *const ThreadCache, class_index: usize) usize {
    if (class_index < thread.fixed_class_count) {
        var count: usize = cache.bins[class_index].count;
        if (threadExtraClassIndex(class_index)) |extra_index| {
            count += cache.extra_bins[extra_index].count;
        }
        return count;
    }
    return cache.linked_counts[class_index - thread.fixed_class_count];
}

pub inline fn popLocalThreadCacheBin(cache: *ThreadCache, class_index: usize) ?[*]u8 {
    if (class_index < thread.fixed_class_count) {
        if (cache.bins[class_index].pop()) |ptr| return ptr;
        if (threadExtraClassIndex(class_index)) |extra_index| {
            if (cache.extra_bins[extra_index].pop()) |ptr| return ptr;
        }
        return null;
    }

    const linked_index = class_index - thread.fixed_class_count;
    const node = cache.linked_heads[linked_index] orelse return null;
    cache.linked_heads[linked_index] = node.next;
    cache.linked_counts[linked_index] -= 1;
    return @ptrCast(node);
}

pub inline fn pushLocalThreadCacheBin(
    cache: *ThreadCache,
    class_index: usize,
    ptr: [*]u8,
    cache_limit: u16,
) bool {
    if (class_index < thread.fixed_class_count) {
        const base_limit = @min(thread.capacity, cache_limit);
        if (cache.bins[class_index].push(ptr, base_limit)) return true;

        const extra_limit = cache_limit - base_limit;
        if (extra_limit == 0) return false;
        const extra_index = threadExtraClassIndex(class_index) orelse return false;
        return cache.extra_bins[extra_index].push(ptr, extra_limit);
    }

    const linked_index = class_index - thread.fixed_class_count;
    const count = cache.linked_counts[linked_index];
    if (count >= cache_limit) return false;
    const node: *FreeNode = @ptrCast(@alignCast(ptr));
    node.* = .{ .next = cache.linked_heads[linked_index] };
    cache.linked_heads[linked_index] = node;
    cache.linked_counts[linked_index] = count + 1;
    return true;
}

pub inline fn threadExtraClassIndex(class_index: usize) ?usize {
    if (comptime preload_build) {
        const extra_index = preload_extra_class_lookup[class_index];
        return if (extra_index == invalid_extra_class_index) null else extra_index;
    }
    return thread.extraClassIndex(class_index);
}

pub fn cpuCountThreadCacheActiveLimit() usize {
    return sys_thread.cpuCount();
}

pub fn defaultThreadCacheActiveLimit() usize {
    return cpuCountThreadCacheActiveLimit();
}

fn buildPreloadExtraClassLookup() [size_class.count]u8 {
    var lookup = @as([size_class.count]u8, @splat(invalid_extra_class_index));
    for (0..size_class.count) |class_index| {
        if (thread.extraClassIndex(class_index)) |extra_index| {
            lookup[class_index] = @intCast(extra_index);
        }
    }
    return lookup;
}

test "thread-cache bins size local overflow separately by class" {
    var cache: ThreadCache = .{};
    const tiny_class = size_class.indexFor(32, .@"1").?;
    const small_class = size_class.indexFor(48, .@"1").?;
    const linked_class = size_class.indexFor(2048, .@"1").?;

    try std.testing.expect(@sizeOf(ThreadCache) < (size_class.count * thread.capacity * @sizeOf([*]u8)));
    try std.testing.expectEqual(thread.capacity, cache.bins[0].items.len);
    try std.testing.expectEqual(thread.extra_bin_capacity, cache.extra_bins[0].items.len);
    try std.testing.expectEqual(@as(usize, 1024), size_class.size(thread.fixed_class_count - 1));
    try std.testing.expectEqual(@as(usize, 1280), size_class.size(thread.fixed_class_count));
    try std.testing.expectEqual(
        @as(u16, thread.capacity + thread.extraCapacity(tiny_class)),
        thread.classLimit(tiny_class),
    );
    try std.testing.expectEqual(
        @as(u16, @min(
            thread.target_bytes / size_class.size(small_class),
            thread.capacity + thread.extraCapacity(small_class),
        )),
        thread.classLimit(small_class),
    );

    var storage: usize = 0;
    const ptr: [*]u8 = @ptrCast(&storage);
    const cache_limit = thread.classLimit(small_class);
    var index: usize = 0;
    while (index < cache_limit) : (index += 1) {
        try std.testing.expect(pushLocalThreadCacheBin(&cache, small_class, ptr, cache_limit));
    }
    try std.testing.expectEqual(@as(usize, cache_limit), localThreadCacheBinCount(&cache, small_class));
    try std.testing.expect(!pushLocalThreadCacheBin(&cache, small_class, ptr, cache_limit));

    var linked_storage: [thread.capacity]usize = undefined;
    const linked_limit = thread.classLimit(linked_class);
    index = 0;
    while (index < linked_limit) : (index += 1) {
        const linked_ptr: [*]u8 = @ptrCast(&linked_storage[index]);
        try std.testing.expect(pushLocalThreadCacheBin(&cache, linked_class, linked_ptr, linked_limit));
    }
    try std.testing.expectEqual(@as(usize, linked_limit), localThreadCacheBinCount(&cache, linked_class));
    try std.testing.expect(!pushLocalThreadCacheBin(&cache, linked_class, ptr, linked_limit));
}
