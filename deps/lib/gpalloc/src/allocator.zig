const std = @import("std");
const sys = @import("sys");
const sys_thread = sys.thread;
const bin_mod = @import("bin.zig");
const cache_policy = @import("cache/root.zig");
const config_mod = @import("config.zig");
const large_cache_policy = @import("large/root.zig");
const page_mod = @import("page/root.zig");
const size_class = @import("class.zig");
const stats_mod = @import("stats.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const Config = config_mod.Config;
const Stats = stats_mod.Stats;
const min_alignment = config_mod.min_alignment;
const page_size = config_mod.page_size;
const max_small_size = config_mod.max_small_size;
const magic = page_mod.magic;
const Page = page_mod.Page;
const Bin = bin_mod.Bin;

const ThreadCache = cache_policy.ThreadCache;
const cpuCountThreadCacheActiveLimit = cache_policy.cpuCountThreadCacheActiveLimit;
const defaultThreadCacheActiveLimit = cache_policy.defaultThreadCacheActiveLimit;
const loadThreadCache = cache_policy.loadThreadCache;
const loadThreadCacheForAllocFastPath = cache_policy.loadThreadCacheForAllocFastPath;
const loadThreadCacheForSmallFastPath = cache_policy.loadThreadCacheForSmallFastPath;
const localThreadCacheBinCount = cache_policy.localThreadCacheBinCount;
const popLocalThreadCacheBin = cache_policy.popLocalThreadCacheBin;
const pushLocalThreadCacheBin = cache_policy.pushLocalThreadCacheBin;
const storeThreadCache = cache_policy.storeThreadCache;

const ThreadCacheReleaseMode = enum {
    unregister,
    destructor,
};

const PageCreateResult = struct {
    page: *Page,
    mapped: bool,
};

const ThreadCacheExit = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var initialized: bool = false;
    var available: bool = false;
    var key: sys.thread.ThreadSpecificKey = .{};

    fn ensureKey() ?sys.thread.ThreadSpecificKey {
        if (!sys.thread.threadSpecificDestructorsSupported()) return null;

        lock();
        defer unlock();

        if (!initialized) {
            key = sys.thread.createThreadSpecificKey(threadCacheExitDestructor) catch {
                initialized = true;
                available = false;
                return null;
            };
            initialized = true;
            available = true;
        }
        return if (available) key else null;
    }

    fn currentKey() ?sys.thread.ThreadSpecificKey {
        if (!sys.thread.threadSpecificDestructorsSupported()) return null;

        lock();
        defer unlock();

        return if (initialized and available) key else null;
    }

    fn lock() void {
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock() void {
        mutex.unlock();
    }
};

fn threadCacheExitDestructor(value: *anyopaque) callconv(.c) void {
    const self: *GpAllocator = @ptrCast(@alignCast(value));
    const cache = loadThreadCache() orelse return;
    if (cache.owner != threadCacheOwner(self)) return;
    self.releaseThreadCache(cache, .destructor, @returnAddress());
}

fn threadCacheOwner(self: *GpAllocator) *anyopaque {
    return @ptrCast(self);
}

fn threadCacheAllocator(owner: *anyopaque) *GpAllocator {
    return @ptrCast(@alignCast(owner));
}

fn assertSmallBlockClass(ptr: [*]u8, class_index: usize) void {
    if (comptime !std.debug.runtime_safety) return;
    const page = page_mod.fromBlock(ptr);
    assert(page.magic == magic);
    assert(page.class_index == class_index);
}

pub const GpAllocator = struct {
    backing_allocator: Allocator,
    config: Config,
    backing_mutex: std.atomic.Mutex,
    bin_mutexes: [size_class.count]std.atomic.Mutex,
    bins: [size_class.count]Bin,
    active_thread_cache_limit: usize,
    active_thread_cache_count: usize,
    retained_thread_caches: ?*ThreadCache,
    retained_thread_cache_count: usize,
    cached_empty_pages: ?*Page,
    cached_empty_page_count: usize,
    large_cache: large_cache_policy.Cache,
    stats_data: stats_mod.AtomicStats,
    medium_large_cache: ?*large_cache_policy.MediumCache,

    const Self = @This();

    pub fn init(backing_allocator: Allocator, config: Config) Self {
        var effective_config = config;
        if (effective_config.collect_stats) {
            effective_config.thread_cache = false;
            effective_config.large_cache = false;
        }

        return .{
            .backing_allocator = backing_allocator,
            .config = effective_config,
            .backing_mutex = .unlocked,
            .bin_mutexes = @as([size_class.count]std.atomic.Mutex, @splat(.unlocked)),
            .bins = @as([size_class.count]Bin, @splat(.{})),
            .active_thread_cache_limit = effective_config.thread_cache_active_limit,
            .active_thread_cache_count = 0,
            .retained_thread_caches = null,
            .retained_thread_cache_count = 0,
            .cached_empty_pages = null,
            .cached_empty_page_count = 0,
            .large_cache = .{},
            .stats_data = .{},
            .medium_large_cache = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.releaseCurrentThreadCache(@returnAddress());

        self.lockAllBins();
        defer self.unlockAllBins();

        for (&self.bins) |*bin| {
            self.destroyBinPages(bin, @returnAddress());
        }
        self.lockBacking();
        defer self.unlockBacking();
        self.large_cache.destroyAll(self.backing_allocator, @returnAddress());
        self.destroyMediumLargeCache(@returnAddress());
        self.destroyCachedEmptyPages(@returnAddress());
        self.destroyRetainedThreadCaches();
        self.stats_data.reset();
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn rawAlloc(self: *Self, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        assert(len > 0);

        if (size_class.indexFor(len, alignment)) |class_index| {
            if (self.useThreadCache()) {
                if (loadThreadCacheForAllocFastPath()) |cache| {
                    if (cache.owner == threadCacheOwner(self)) {
                        if (popLocalThreadCacheBin(cache, class_index)) |ptr| return ptr;
                    }
                }
            }
            return self.rawAllocSmallSlow(class_index, len, ret_addr);
        }

        return self.rawAllocLarge(len, alignment, ret_addr);
    }

    noinline fn rawAllocSmallSlow(self: *Self, class_index: usize, len: usize, ret_addr: usize) ?[*]u8 {
        if (self.useThreadCache()) {
            return self.allocSmallThreadCached(class_index, ret_addr);
        }
        self.lockBin(class_index);
        defer self.unlockBin(class_index);
        return self.allocSmall(class_index, len, ret_addr);
    }

    noinline fn rawAllocLarge(self: *Self, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const large_class = if (self.useLargeCache()) large_cache_policy.classFor(len, alignment) else null;
        self.lockBacking();
        defer self.unlockBacking();
        const ptr = if (large_class) |class| blk: {
            const entry = self.large_cache.popAtLeast(class) orelse large_cache_policy.Entry{
                .class = class,
                .ptr = self.backing_allocator.rawAlloc(large_cache_policy.backingSize(class), large_cache_policy.alignment, ret_addr) orelse return null,
            };
            break :blk large_cache_policy.initializeHeader(entry.ptr, entry.class);
        } else if (self.useMediumLargeCache(len, alignment)) blk: {
            const class = large_cache_policy.mediumClassFor(len, alignment).?;
            const entry = if (self.medium_large_cache) |cache|
                cache.popAtLeast(class) orelse large_cache_policy.Entry{
                    .class = class,
                    .ptr = self.backing_allocator.rawAlloc(large_cache_policy.mediumBackingSize(class), large_cache_policy.alignment, ret_addr) orelse return null,
                }
            else
                large_cache_policy.Entry{
                    .class = class,
                    .ptr = self.backing_allocator.rawAlloc(large_cache_policy.mediumBackingSize(class), large_cache_policy.alignment, ret_addr) orelse return null,
                };
            break :blk large_cache_policy.initializeMediumHeader(entry.ptr, entry.class);
        } else (self.backing_allocator.rawAlloc(len, alignment, ret_addr) orelse return null);
        self.addStatU64(&self.stats_data.large_allocations, 1);
        self.addStatUsize(&self.stats_data.active_large_bytes, len);
        return ptr;
    }

    pub fn rawResize(self: *Self, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        assert(memory.len > 0);
        assert(new_len > 0);

        if (size_class.indexFor(memory.len, alignment)) |class_index| {
            assertSmallBlockClass(memory.ptr, class_index);
            const new_class = size_class.indexFor(new_len, alignment) orelse return false;
            if (new_class != class_index) return false;
            if (self.useThreadCache()) {
                return true;
            }
            self.lockBin(class_index);
            defer self.unlockBin(class_index);
            self.resizeSmall(memory.len, new_len);
            return true;
        }

        return self.rawResizeLarge(memory, alignment, new_len);
    }

    noinline fn rawResizeLarge(self: *Self, memory: []u8, alignment: Alignment, new_len: usize) bool {
        const new_class = size_class.indexFor(new_len, alignment);
        if (new_class != null) return false;
        if (self.useLargeCache() and large_cache_policy.classFor(memory.len, alignment) != null) {
            const header = large_cache_policy.headerFromUserPointer(memory.ptr);
            const class = large_cache_policy.classFromHeader(header) orelse unreachable;
            if (large_cache_policy.classFor(new_len, alignment) == null) return false;
            if (new_len <= class.size) {
                self.resizeLarge(memory.len, new_len);
                return true;
            }
            return false;
        }
        if (self.useMediumLargeCache(memory.len, alignment)) {
            const header = large_cache_policy.mediumHeaderFromUserPointer(memory.ptr);
            const class = large_cache_policy.mediumClassFromHeader(header) orelse unreachable;
            if (large_cache_policy.mediumClassFor(new_len, alignment) == null) return false;
            if (new_len <= class.size) {
                self.resizeLarge(memory.len, new_len);
                return true;
            }
            return false;
        }

        if (self.usesCachedLargeRepresentation(new_len, alignment)) return false;
        self.lockBacking();
        defer self.unlockBacking();
        if (!self.backing_allocator.rawResize(memory, alignment, new_len, @returnAddress())) return false;
        self.resizeLarge(memory.len, new_len);
        return true;
    }

    pub fn rawRemap(self: *Self, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        assert(memory.len > 0);
        assert(new_len > 0);

        if (size_class.indexFor(memory.len, alignment)) |class_index| {
            assertSmallBlockClass(memory.ptr, class_index);
            const new_class = size_class.indexFor(new_len, alignment) orelse return null;
            if (new_class != class_index) return null;
            if (self.useThreadCache()) {
                return memory.ptr;
            }
            self.lockBin(class_index);
            defer self.unlockBin(class_index);
            self.resizeSmall(memory.len, new_len);
            return memory.ptr;
        }

        return self.rawRemapLarge(memory, alignment, new_len, ret_addr);
    }

    noinline fn rawRemapLarge(self: *Self, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const new_class = size_class.indexFor(new_len, alignment);
        if (new_class != null) return null;
        if (self.useLargeCache() and large_cache_policy.classFor(memory.len, alignment) != null) {
            const header = large_cache_policy.headerFromUserPointer(memory.ptr);
            const class = large_cache_policy.classFromHeader(header) orelse unreachable;
            if (large_cache_policy.classFor(new_len, alignment) == null) return null;
            if (new_len <= class.size) {
                self.resizeLarge(memory.len, new_len);
                return memory.ptr;
            }
            return null;
        }
        if (self.useMediumLargeCache(memory.len, alignment)) {
            const header = large_cache_policy.mediumHeaderFromUserPointer(memory.ptr);
            const class = large_cache_policy.mediumClassFromHeader(header) orelse unreachable;
            if (large_cache_policy.mediumClassFor(new_len, alignment) == null) return null;
            if (new_len <= class.size) {
                self.resizeLarge(memory.len, new_len);
                return memory.ptr;
            }
            return null;
        }

        if (self.usesCachedLargeRepresentation(new_len, alignment)) return null;
        self.lockBacking();
        defer self.unlockBacking();
        const ptr = self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resizeLarge(memory.len, new_len);
        return ptr;
    }

    pub fn rawFree(self: *Self, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        assert(memory.len > 0);

        if (size_class.indexFor(memory.len, alignment)) |class_index| {
            assertSmallBlockClass(memory.ptr, class_index);
            if (self.useThreadCache()) {
                if (loadThreadCacheForSmallFastPath()) |cache| {
                    if (cache.owner == threadCacheOwner(self)) {
                        const cache_limit = cache_policy.threadClassLimit(class_index);
                        if (pushLocalThreadCacheBin(cache, class_index, memory.ptr, cache_limit)) return;
                    }
                }
            }
            self.rawFreeSmallSlow(class_index, memory, ret_addr);
            return;
        }

        self.rawFreeLarge(memory, alignment, ret_addr);
    }

    noinline fn rawFreeSmallSlow(self: *Self, class_index: usize, memory: []u8, ret_addr: usize) void {
        if (self.useThreadCache()) {
            self.freeSmallThreadCached(class_index, memory.ptr, ret_addr);
            return;
        }
        self.lockBin(class_index);
        defer self.unlockBin(class_index);
        self.freeSmall(page_mod.fromBlock(memory.ptr), class_index, memory, ret_addr);
    }

    noinline fn rawFreeLarge(self: *Self, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        self.addStatU64(&self.stats_data.large_frees, 1);
        self.subStatUsize(&self.stats_data.active_large_bytes, memory.len);
        const large_class = if (self.useLargeCache()) large_cache_policy.classFor(memory.len, alignment) else null;
        self.lockBacking();
        defer self.unlockBacking();
        if (large_class != null) {
            const header = large_cache_policy.headerFromUserPointer(memory.ptr);
            const class = large_cache_policy.classFromHeader(header) orelse unreachable;
            const base = large_cache_policy.baseFromUserPointer(memory.ptr);
            if (self.large_cache.push(class, base, self.config.large_cache_limit_bytes, self.backing_allocator, ret_addr)) return;
            self.backing_allocator.rawFree(base[0..large_cache_policy.backingSize(class)], large_cache_policy.alignment, ret_addr);
            return;
        }
        if (self.useMediumLargeCache(memory.len, alignment)) {
            const header = large_cache_policy.mediumHeaderFromUserPointer(memory.ptr);
            const class = large_cache_policy.mediumClassFromHeader(header) orelse unreachable;
            const base = large_cache_policy.mediumBaseFromUserPointer(memory.ptr);
            if (self.mediumLargeCacheLocked()) |cache| {
                if (cache.push(class, base, self.mediumLargeCacheLimit(), self.backing_allocator, ret_addr)) return;
            }
            self.backing_allocator.rawFree(base[0..large_cache_policy.mediumBackingSize(class)], large_cache_policy.alignment, ret_addr);
            return;
        }
        self.backing_allocator.rawFree(memory, alignment, ret_addr);
    }

    pub fn rawFreeThreadCachedSmallBlock(self: *Self, ptr: [*]u8, ret_addr: usize) void {
        assert(self.useThreadCache());
        const page = page_mod.fromBlock(ptr);
        self.freeSmallThreadCached(@intCast(page.class_index), ptr, ret_addr);
    }

    pub fn stats(self: *Self) Stats {
        return self.stats_data.snapshot();
    }

    pub fn flushThreadCacheForCurrentThread(self: *Self) void {
        self.releaseCurrentThreadCache(@returnAddress());
    }

    fn destroyBinPages(self: *Self, bin: *Bin, ret_addr: usize) void {
        var page = bin.all;
        while (page) |current| {
            const next = current.next_all;
            self.destroyPage(current, ret_addr);
            page = next;
        }
        bin.clear();
    }

    fn lockBin(self: *Self, class_index: usize) void {
        if (!self.config.thread_safe) return;
        while (!self.bin_mutexes[class_index].tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockBin(self: *Self, class_index: usize) void {
        if (self.config.thread_safe) self.bin_mutexes[class_index].unlock();
    }

    fn lockBacking(self: *Self) void {
        if (!self.config.thread_safe) return;
        while (!self.backing_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockBacking(self: *Self) void {
        if (self.config.thread_safe) self.backing_mutex.unlock();
    }

    fn lockAllBins(self: *Self) void {
        if (!self.config.thread_safe) return;
        for (0..self.bin_mutexes.len) |class_index| self.lockBin(class_index);
    }

    fn unlockAllBins(self: *Self) void {
        if (!self.config.thread_safe) return;
        var index = self.bins.len;
        while (index > 0) {
            index -= 1;
            self.unlockBin(index);
        }
    }

    fn useThreadCache(self: *Self) bool {
        return self.config.thread_cache;
    }

    fn allocSmall(self: *Self, class_index: usize, requested_len: usize, ret_addr: usize) ?[*]u8 {
        const ptr = self.reserveSmallBlock(class_index, ret_addr) orelse return null;
        self.recordSmallAllocation(requested_len);
        return ptr;
    }

    fn reserveSmallBlock(self: *Self, class_index: usize, ret_addr: usize) ?[*]u8 {
        const bin = &self.bins[class_index];
        if (bin.partial == null) {
            const created = self.createPage(class_index, ret_addr) orelse return null;
            const page = created.page;
            bin.addPage(page);
            if (created.mapped) {
                self.addStatU64(&self.stats_data.pages_allocated, 1);
                self.addStatUsize(&self.stats_data.mapped_small_bytes, page.mappedBytes());
            }
        }

        const page = bin.partial.?;
        if (page.live_count == 0) {
            self.restoreDiscardedPage(page);
            if (bin.empty_count > 0) {
                bin.empty_count -= 1;
                self.subStatUsize(&self.stats_data.retained_empty_pages, 1);
            }
        }
        const ptr = page.allocate();
        bin.popIfFull(page);
        return ptr;
    }

    fn freeSmall(self: *Self, page: *Page, class_index: usize, memory: []u8, ret_addr: usize) void {
        self.releaseSmallBlockFromPage(page, class_index, memory.ptr, ret_addr);
        self.recordSmallFree(memory.len);
    }

    fn releaseSmallBlock(self: *Self, class_index: usize, ptr: [*]u8, ret_addr: usize) void {
        self.releaseSmallBlockFromPage(page_mod.fromBlock(ptr), class_index, ptr, ret_addr);
    }

    fn releaseSmallBlockFromPage(self: *Self, page: *Page, class_index: usize, ptr: [*]u8, ret_addr: usize) void {
        const bin = &self.bins[class_index];
        assert(page.magic == magic);
        assert(page.class_index == class_index);

        const was_full = page.free_count == 0;
        page.free(ptr);
        if (was_full) bin.pushPartial(page);

        if (page.live_count == 0) {
            if (bin.empty_count < self.config.empty_page_retention_limit) {
                bin.empty_count += 1;
                self.addStatUsize(&self.stats_data.retained_empty_pages, 1);
                self.discardRetainedEmptyPage(page);
            } else {
                bin.removePartial(page);
                bin.removeAll(page);
                if (self.retainCachedEmptyPage(page)) {
                    self.addStatUsize(&self.stats_data.retained_empty_pages, 1);
                    return;
                }

                const mapped_bytes = page.mappedBytes();
                self.destroyPage(page, ret_addr);
                self.addStatU64(&self.stats_data.pages_freed, 1);
                self.subStatUsize(&self.stats_data.mapped_small_bytes, mapped_bytes);
            }
        }
    }

    fn discardRetainedEmptyPage(self: *Self, page: *Page) void {
        if (self.config.page_provider != .os) return;
        if (self.config.retained_empty_page_policy != .discard_unused) return;
        const discarded_len = page_mod.discardUnused(page) orelse return;
        self.addStatU64(&self.stats_data.empty_page_discards, 1);
        self.addStatUsize(&self.stats_data.discarded_small_bytes, discarded_len);
    }

    fn restoreDiscardedPage(self: *Self, page: *Page) void {
        const discarded_bytes = page_mod.restoreDiscarded(page) orelse return;
        self.subStatUsize(&self.stats_data.discarded_small_bytes, discarded_bytes);
    }

    fn recordSmallAllocation(self: *Self, requested_len: usize) void {
        self.addStatU64(&self.stats_data.small_allocations, 1);
        self.addStatUsize(&self.stats_data.active_small_bytes, requested_len);
    }

    fn recordSmallFree(self: *Self, released_len: usize) void {
        self.addStatU64(&self.stats_data.small_frees, 1);
        self.subStatUsize(&self.stats_data.active_small_bytes, released_len);
    }

    fn allocSmallThreadCached(self: *Self, class_index: usize, ret_addr: usize) ?[*]u8 {
        const cache = self.currentThreadCache(ret_addr) orelse {
            self.lockBin(class_index);
            defer self.unlockBin(class_index);
            return self.reserveSmallBlock(class_index, ret_addr);
        };
        if (popLocalThreadCacheBin(cache, class_index)) |ptr| return ptr;

        return self.allocSmallThreadCachedSlow(cache, class_index, ret_addr);
    }

    noinline fn allocSmallThreadCachedSlow(
        self: *Self,
        cache: *ThreadCache,
        class_index: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        self.refillThreadCacheBin(cache, class_index, ret_addr);
        return popLocalThreadCacheBin(cache, class_index);
    }

    fn freeSmallThreadCached(self: *Self, class_index: usize, ptr: [*]u8, ret_addr: usize) void {
        const cache = self.currentThreadCacheSmallFastPath(ret_addr) orelse {
            self.lockBin(class_index);
            defer self.unlockBin(class_index);
            self.releaseSmallBlock(class_index, ptr, ret_addr);
            return;
        };

        const cache_limit = cache_policy.threadClassLimit(class_index);
        if (pushLocalThreadCacheBin(cache, class_index, ptr, cache_limit)) return;

        self.freeSmallThreadCachedSlow(cache, class_index, ptr, cache_limit, ret_addr);
    }

    noinline fn freeSmallThreadCachedSlow(
        self: *Self,
        cache: *ThreadCache,
        class_index: usize,
        ptr: [*]u8,
        cache_limit: u16,
        ret_addr: usize,
    ) void {
        self.drainLocalThreadCacheBin(cache, class_index, cache_policy.threadDrainCount(cache_limit), ret_addr);
        if (pushLocalThreadCacheBin(cache, class_index, ptr, cache_limit)) return;

        self.lockBin(class_index);
        defer self.unlockBin(class_index);
        self.releaseSmallBlock(class_index, ptr, ret_addr);
    }

    inline fn currentThreadCache(self: *Self, ret_addr: usize) ?*ThreadCache {
        if (loadThreadCache()) |cache| {
            if (cache.owner == threadCacheOwner(self)) return cache;
        }
        return self.currentThreadCacheSlow(ret_addr);
    }

    inline fn currentThreadCacheSmallFastPath(self: *Self, ret_addr: usize) ?*ThreadCache {
        if (loadThreadCacheForSmallFastPath()) |cache| {
            if (cache.owner == threadCacheOwner(self)) return cache;
        }
        return self.currentThreadCacheSlow(ret_addr);
    }

    noinline fn currentThreadCacheSlow(self: *Self, ret_addr: usize) ?*ThreadCache {
        if (loadThreadCache()) |cache| {
            if (cache.owner) |owner| {
                threadCacheAllocator(owner).releaseThreadCache(cache, .unregister, ret_addr);
            } else {
                const storage_owner = cache.storage_owner orelse threadCacheOwner(self);
                threadCacheAllocator(storage_owner).retireThreadCache(cache);
                storeThreadCache(null);
            }
        }

        const cache = self.createThreadCache() orelse return null;
        cache.owner = threadCacheOwner(self);
        storeThreadCache(cache);
        self.registerThreadCacheExit();
        return cache;
    }

    fn flushCurrentThreadCache(self: *Self, ret_addr: usize) void {
        const cache = loadThreadCache() orelse return;
        if (cache.owner != threadCacheOwner(self)) return;
        self.flushThreadCache(cache, ret_addr);
    }

    fn releaseCurrentThreadCache(self: *Self, ret_addr: usize) void {
        const cache = loadThreadCache() orelse return;
        if (cache.owner == threadCacheOwner(self)) {
            self.releaseThreadCache(cache, .unregister, ret_addr);
            return;
        }
        if (cache.storage_owner != threadCacheOwner(self)) return;
        self.unregisterThreadCacheExit();
        self.retireThreadCache(cache);
        storeThreadCache(null);
    }

    fn flushThreadCache(self: *Self, cache: *ThreadCache, ret_addr: usize) void {
        for (0..size_class.count) |class_index| {
            self.drainLocalThreadCacheBin(cache, class_index, std.math.maxInt(usize), ret_addr);
        }
        if (cache.owner == threadCacheOwner(self)) cache.owner = null;
    }

    fn releaseThreadCache(
        self: *Self,
        cache: *ThreadCache,
        mode: ThreadCacheReleaseMode,
        ret_addr: usize,
    ) void {
        self.flushThreadCache(cache, ret_addr);
        if (mode == .unregister) self.unregisterThreadCacheExit();
        self.retireThreadCache(cache);
        if (loadThreadCache() == cache) {
            storeThreadCache(null);
        }
    }

    fn createThreadCache(self: *Self) ?*ThreadCache {
        self.lockBacking();
        defer self.unlockBacking();

        const active_limit = self.resolveThreadCacheActiveLimit();
        if (self.active_thread_cache_count >= active_limit) return null;

        if (self.retained_thread_caches) |cache| {
            self.retained_thread_caches = cache.next_retained;
            self.retained_thread_cache_count -= 1;
            self.active_thread_cache_count += 1;
            cache.reset(threadCacheOwner(self));
            return cache;
        }

        const cache = self.backing_allocator.create(ThreadCache) catch return null;
        self.active_thread_cache_count += 1;
        cache.reset(threadCacheOwner(self));
        return cache;
    }

    fn resolveThreadCacheActiveLimit(self: *Self) usize {
        if (self.active_thread_cache_limit == 0) {
            self.active_thread_cache_limit = defaultThreadCacheActiveLimit();
        }
        return self.active_thread_cache_limit;
    }

    fn retireThreadCache(self: *Self, cache: *ThreadCache) void {
        assert(cache.owner == null);
        assert(cache.storage_owner == threadCacheOwner(self));
        self.lockBacking();
        defer self.unlockBacking();

        assert(self.active_thread_cache_count > 0);
        self.active_thread_cache_count -= 1;

        if (self.retained_thread_cache_count < self.config.thread_cache_retention_limit) {
            cache.next_retained = self.retained_thread_caches;
            self.retained_thread_caches = cache;
            self.retained_thread_cache_count += 1;
            return;
        }

        cache.storage_owner = null;
        self.backing_allocator.destroy(cache);
    }

    fn destroyRetainedThreadCaches(self: *Self) void {
        var cache = self.retained_thread_caches;
        while (cache) |current| {
            const next = current.next_retained;
            current.storage_owner = null;
            self.backing_allocator.destroy(current);
            cache = next;
        }
        self.retained_thread_caches = null;
        self.retained_thread_cache_count = 0;
    }

    fn registerThreadCacheExit(self: *Self) void {
        if (!self.config.flush_thread_cache_on_thread_exit) return;
        const key = ThreadCacheExit.ensureKey() orelse return;
        _ = sys.thread.setThreadSpecificValue(key, self);
    }

    fn unregisterThreadCacheExit(self: *Self) void {
        const key = ThreadCacheExit.currentKey() orelse return;
        if (sys.thread.getThreadSpecificValue(key)) |value| {
            if (value != @as(*anyopaque, @ptrCast(self))) return;
            _ = sys.thread.setThreadSpecificValue(key, null);
        }
    }

    fn refillThreadCacheBin(self: *Self, cache: *ThreadCache, class_index: usize, ret_addr: usize) void {
        self.lockBin(class_index);
        defer self.unlockBin(class_index);

        const cache_limit = cache_policy.threadClassLimit(class_index);
        const cached_count = localThreadCacheBinCount(cache, class_index);
        const refill_count = @min(cache_policy.threadRefillCount(class_index), @as(usize, cache_limit) - cached_count);
        const bin = &self.bins[class_index];
        var count: usize = 0;
        while (count < refill_count) {
            const ptr = bin.local_transfer.pop() orelse break;
            assert(pushLocalThreadCacheBin(cache, class_index, ptr, cache_limit));
            count += 1;
        }
        while (count < refill_count) {
            const reserved = self.reserveSmallBlocksForThreadCache(
                cache,
                class_index,
                refill_count - count,
                cache_limit,
                ret_addr,
            );
            if (reserved == 0) return;
            count += reserved;
        }
    }

    fn reserveSmallBlocksForThreadCache(
        self: *Self,
        cache: *ThreadCache,
        class_index: usize,
        limit: usize,
        cache_limit: u16,
        ret_addr: usize,
    ) usize {
        const bin = &self.bins[class_index];
        if (bin.partial == null) {
            const created = self.createPage(class_index, ret_addr) orelse return 0;
            const page = created.page;
            bin.addPage(page);
            if (created.mapped) {
                self.addStatU64(&self.stats_data.pages_allocated, 1);
                self.addStatUsize(&self.stats_data.mapped_small_bytes, page.mappedBytes());
            }
        }

        const page = bin.partial.?;
        if (page.live_count == 0) {
            self.restoreDiscardedPage(page);
            if (bin.empty_count > 0) {
                bin.empty_count -= 1;
                self.subStatUsize(&self.stats_data.retained_empty_pages, 1);
            }
        }

        const batch_count = @min(limit, @as(usize, page.free_count));
        var count: usize = 0;
        while (count < batch_count) : (count += 1) {
            const ptr = page.allocate();
            assert(pushLocalThreadCacheBin(cache, class_index, ptr, cache_limit));
        }
        bin.popIfFull(page);
        return count;
    }

    fn drainLocalThreadCacheBin(
        self: *Self,
        cache: *ThreadCache,
        class_index: usize,
        limit: usize,
        ret_addr: usize,
    ) void {
        if (localThreadCacheBinCount(cache, class_index) == 0) return;

        self.lockBin(class_index);
        defer self.unlockBin(class_index);

        const bin = &self.bins[class_index];
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            const ptr = popLocalThreadCacheBin(cache, class_index) orelse return;
            self.releaseLocalCachedBlockToCentral(bin, class_index, ptr, ret_addr);
        }
    }

    fn releaseLocalCachedBlockToCentral(
        self: *Self,
        bin: *Bin,
        class_index: usize,
        ptr: [*]u8,
        ret_addr: usize,
    ) void {
        if (bin.local_transfer.push(ptr, cache_policy.transferClassLimit(class_index))) return;
        self.releaseSmallBlock(class_index, ptr, ret_addr);
    }

    fn resizeSmall(self: *Self, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.addStatUsize(&self.stats_data.active_small_bytes, new_len - old_len);
        } else {
            self.subStatUsize(&self.stats_data.active_small_bytes, old_len - new_len);
        }
    }

    fn resizeLarge(self: *Self, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.addStatUsize(&self.stats_data.active_large_bytes, new_len - old_len);
        } else {
            self.subStatUsize(&self.stats_data.active_large_bytes, old_len - new_len);
        }
    }

    fn createPage(self: *Self, class_index: usize, ret_addr: usize) ?PageCreateResult {
        return switch (self.config.page_provider) {
            .backing_allocator => blk: {
                self.lockBacking();
                defer self.unlockBacking();
                if (self.popCachedEmptyPage(class_index)) |page| {
                    break :blk .{ .page = page, .mapped = false };
                }
                break :blk .{
                    .page = page_mod.createFromBacking(self.backing_allocator, class_index, ret_addr) orelse return null,
                    .mapped = true,
                };
            },
            .os => .{ .page = page_mod.createFromOs(class_index) orelse return null, .mapped = true },
        };
    }

    fn destroyPage(self: *Self, page: *Page, ret_addr: usize) void {
        switch (self.config.page_provider) {
            .backing_allocator => {
                self.lockBacking();
                defer self.unlockBacking();
                page_mod.destroyInBacking(self.backing_allocator, page, ret_addr);
            },
            .os => page_mod.destroyFromOs(page),
        }
    }

    fn popCachedEmptyPage(self: *Self, class_index: usize) ?*Page {
        const page = self.cached_empty_pages orelse return null;
        self.cached_empty_pages = page.next_cached;
        self.cached_empty_page_count -= 1;
        self.subStatUsize(&self.stats_data.retained_empty_pages, 1);
        const mapping_base = page.mapping_base;
        const mapping_len = page.mapping_len;
        Page.init(page, class_index, mapping_base, mapping_len);
        return page;
    }

    fn retainCachedEmptyPage(self: *Self, page: *Page) bool {
        if (self.config.page_provider != .backing_allocator) return false;
        if (self.config.empty_page_retention_limit == 0) return false;
        if (self.config.empty_page_reuse_limit == 0) return false;

        self.lockBacking();
        defer self.unlockBacking();

        if (self.cached_empty_page_count >= self.config.empty_page_reuse_limit) return false;

        page.magic = 0;
        page.next_all = null;
        page.previous_all = null;
        page.next_partial = null;
        page.next_cached = self.cached_empty_pages;
        self.cached_empty_pages = page;
        self.cached_empty_page_count += 1;
        return true;
    }

    fn destroyCachedEmptyPages(self: *Self, ret_addr: usize) void {
        var page = self.cached_empty_pages;
        while (page) |current| {
            const next = current.next_cached;
            switch (self.config.page_provider) {
                .backing_allocator => page_mod.destroyInBacking(self.backing_allocator, current, ret_addr),
                .os => page_mod.destroyFromOs(current),
            }
            page = next;
        }
        self.cached_empty_pages = null;
        self.cached_empty_page_count = 0;
    }

    fn addStatU64(self: *Self, counter: *stats_mod.AtomicU64, amount: u64) void {
        if (!self.config.collect_stats) return;
        stats_mod.addU64(counter, amount);
    }

    fn addStatUsize(self: *Self, counter: *stats_mod.AtomicUsize, amount: usize) void {
        if (!self.config.collect_stats) return;
        stats_mod.addUsize(counter, amount);
    }

    fn subStatUsize(self: *Self, counter: *stats_mod.AtomicUsize, amount: usize) void {
        if (!self.config.collect_stats) return;
        stats_mod.subUsize(counter, amount);
    }

    fn useLargeCache(self: *Self) bool {
        return self.config.large_cache;
    }

    fn useMediumLargeCache(self: *Self, len: usize, alignment: Alignment) bool {
        return self.config.large_cache and large_cache_policy.mediumClassFor(len, alignment) != null;
    }

    fn usesCachedLargeRepresentation(self: *Self, len: usize, alignment: Alignment) bool {
        if (!self.useLargeCache()) return false;
        return large_cache_policy.classFor(len, alignment) != null or self.useMediumLargeCache(len, alignment);
    }

    fn mediumLargeCacheLimit(self: *Self) usize {
        return @min(self.config.large_cache_limit_bytes, large_cache_policy.medium_default_limit_bytes);
    }

    fn mediumLargeCacheLocked(self: *Self) ?*large_cache_policy.MediumCache {
        if (self.medium_large_cache) |cache| return cache;
        const cache = self.backing_allocator.create(large_cache_policy.MediumCache) catch return null;
        cache.* = .{};
        self.medium_large_cache = cache;
        return cache;
    }

    fn destroyMediumLargeCache(self: *Self, ret_addr: usize) void {
        const cache = self.medium_large_cache orelse return;
        cache.destroyAll(self.backing_allocator, ret_addr);
        self.backing_allocator.destroy(cache);
        self.medium_large_cache = null;
    }
};

const vtable: Allocator.VTable = .{
    .alloc = allocatorAlloc,
    .resize = allocatorResize,
    .remap = allocatorRemap,
    .free = allocatorFree,
};

fn allocatorAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *GpAllocator = @ptrCast(@alignCast(ctx));
    return self.rawAlloc(len, alignment, ret_addr);
}

fn allocatorResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *GpAllocator = @ptrCast(@alignCast(ctx));
    return self.rawResize(memory, alignment, new_len, ret_addr);
}

fn allocatorRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *GpAllocator = @ptrCast(@alignCast(ctx));
    return self.rawRemap(memory, alignment, new_len, ret_addr);
}

fn allocatorFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *GpAllocator = @ptrCast(@alignCast(ctx));
    self.rawFree(memory, alignment, ret_addr);
}

const threaded_test_threads = 4;
const threaded_test_batch = 128;
const threaded_test_rounds = 16;
const thread_cache_remote_test_batch = 128;
const thread_cache_flush_test_batch = 256;
const sys_thread_exit_batch = 256;
const cross_thread_free_batch = 64;

const ThreadedTestWork = struct {
    allocator: Allocator,
    len: usize,
    seed: u8,
};

const ThreadCacheRemoteWork = struct {
    heap: *GpAllocator,
    allocator: Allocator,
    handoff: *std.atomic.Value(u32),
    records: *[thread_cache_remote_test_batch][]u8,
};

const ThreadCacheFlushWork = struct {
    heap: *GpAllocator,
    allocator: Allocator,
    records: *[thread_cache_flush_test_batch][]u8,
};

const SysThreadExitWorker = struct {
    allocator: Allocator,
    records: *[sys_thread_exit_batch][]u8,

    fn allocateAndFree(work: *SysThreadExitWorker) void {
        for (work.records, 0..) |*record, index| {
            const bytes = work.allocator.alloc(u8, 48) catch @panic("allocation failed");
            bytes[0] = @truncate(index);
            record.* = bytes;
        }
        for (work.records.*) |record| {
            work.allocator.free(record);
        }
    }
};

const ActiveThreadCacheLimitWorker = struct {
    heap: *GpAllocator,
    allocator: Allocator,
    used_cache: bool = false,

    fn allocateAndFree(work: *ActiveThreadCacheLimitWorker) void {
        const bytes = work.allocator.alloc(u8, 48) catch @panic("allocation failed");
        work.allocator.free(bytes);
        work.used_cache = if (loadThreadCache()) |cache| cache.owner == @as(*anyopaque, @ptrCast(work.heap)) else false;
        work.heap.flushThreadCacheForCurrentThread();
    }
};

const CrossThreadFreeWorker = struct {
    heap: *GpAllocator,
    records: *[cross_thread_free_batch][]u8,
    allocator: Allocator,

    fn freeAll(work: *CrossThreadFreeWorker) void {
        for (work.records.*) |record| work.allocator.free(record);
        work.heap.flushThreadCacheForCurrentThread();
    }
};

test "small allocations are aligned and mutable" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    inline for (.{ 1, 2, 4, 8, 16, 32, 64, 256 }) |alignment| {
        const bytes = try allocator_instance.alignedAlloc(u8, .fromByteUnits(alignment), 37);
        defer allocator_instance.free(bytes);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % alignment);
        @memset(bytes, 0xa5);
        try std.testing.expectEqual(@as(u8, 0xa5), bytes[0]);
    }
}

test "small freed blocks are reused while the page remains active" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    const first = try allocator_instance.alloc(u8, 64);
    const second = try allocator_instance.alloc(u8, 64);
    allocator_instance.free(first);
    const third = try allocator_instance.alloc(u8, 64);
    defer allocator_instance.free(third);
    defer allocator_instance.free(second);

    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(third.ptr));
}

test "stats mode stores cache-disabled effective config" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .collect_stats = true });
    defer heap.deinit();

    try std.testing.expect(heap.config.collect_stats);
    try std.testing.expect(!heap.config.thread_cache);
    try std.testing.expect(!heap.config.large_cache);
}

test "empty small pages are retained by default" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .collect_stats = true });
    const allocator_instance = heap.allocator();

    const first = try allocator_instance.alloc(u8, 16);
    allocator_instance.free(first);

    var stats = heap.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.pages_allocated);
    try std.testing.expectEqual(@as(u64, 0), stats.pages_freed);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_empty_pages);
    try std.testing.expectEqual(page_size, stats.mapped_small_bytes);

    const second = try allocator_instance.alloc(u8, 16);
    stats = heap.stats();
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(usize, 0), stats.retained_empty_pages);
    allocator_instance.free(second);

    heap.deinit();
}

test "empty small pages can be released immediately" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .empty_page_retention_limit = 0, .collect_stats = true });
    const allocator_instance = heap.allocator();

    const bytes = try allocator_instance.alloc(u8, 16);
    allocator_instance.free(bytes);

    const stats = heap.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.pages_allocated);
    try std.testing.expectEqual(@as(u64, 1), stats.pages_freed);
    try std.testing.expectEqual(@as(usize, 0), stats.retained_empty_pages);
    try std.testing.expectEqual(@as(usize, 0), stats.mapped_small_bytes);
    heap.deinit();
}

test "empty page retention limit releases excess pages" {
    var heap = GpAllocator.init(std.testing.allocator, .{
        .empty_page_retention_limit = 1,
        .empty_page_reuse_limit = 0,
        .collect_stats = true,
    });
    const allocator_instance = heap.allocator();

    var blocks: std.ArrayList([]u8) = .empty;
    defer blocks.deinit(std.testing.allocator);

    var index: usize = 0;
    while (index < 9000) : (index += 1) {
        try blocks.append(std.testing.allocator, try allocator_instance.alloc(u8, 16));
    }
    for (blocks.items) |block| allocator_instance.free(block);

    const stats = heap.stats();
    try std.testing.expect(stats.pages_allocated > 1);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_empty_pages);
    try std.testing.expectEqual(stats.pages_allocated - 1, stats.pages_freed);

    heap.deinit();
}

test "empty page cache reuses excess pages across classes" {
    var heap = GpAllocator.init(std.testing.allocator, .{
        .empty_page_retention_limit = 1,
        .empty_page_reuse_limit = 1,
        .collect_stats = true,
    });
    const allocator_instance = heap.allocator();

    var blocks: std.ArrayList([]u8) = .empty;
    defer blocks.deinit(std.testing.allocator);

    var index: usize = 0;
    while (index < 9000) : (index += 1) {
        try blocks.append(std.testing.allocator, try allocator_instance.alloc(u8, 16));
    }
    for (blocks.items) |block| allocator_instance.free(block);

    var stats = heap.stats();
    try std.testing.expect(stats.pages_allocated > 1);
    try std.testing.expectEqual(@as(usize, 2), stats.retained_empty_pages);
    try std.testing.expectEqual(stats.pages_allocated - 2, stats.pages_freed);

    const pages_allocated = stats.pages_allocated;
    const reused = try allocator_instance.alloc(u8, 32);
    stats = heap.stats();
    try std.testing.expectEqual(pages_allocated, stats.pages_allocated);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_empty_pages);
    allocator_instance.free(reused);

    heap.deinit();
}

test "large allocations bypass small pages" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .collect_stats = true });
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    const bytes = try allocator_instance.alloc(u8, max_small_size + 1);
    @memset(bytes, 0x7c);
    allocator_instance.free(bytes);

    const stats = heap.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.large_allocations);
    try std.testing.expectEqual(@as(u64, 1), stats.large_frees);
    try std.testing.expectEqual(@as(u64, 0), stats.pages_allocated);
}

test "realloc preserves data across class changes" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    var bytes = try allocator_instance.alloc(u8, 24);
    @memset(bytes, 0x2a);
    bytes = try allocator_instance.realloc(bytes, 200);
    defer allocator_instance.free(bytes);

    for (bytes[0..24]) |byte| {
        try std.testing.expectEqual(@as(u8, 0x2a), byte);
    }
}

test "realloc moves small shrinks to the length size class" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .collect_stats = true });
    const allocator_instance = heap.allocator();

    var bytes = try allocator_instance.alloc(u8, 200);
    @memset(bytes, 0x5d);
    const ptr = bytes.ptr;

    bytes = try allocator_instance.realloc(bytes, 24);
    try std.testing.expect(@intFromPtr(ptr) != @intFromPtr(bytes.ptr));
    try std.testing.expectEqual(@as(usize, 24), heap.stats().active_small_bytes);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0x5d), byte);

    bytes = try allocator_instance.realloc(bytes, 128);
    try std.testing.expectEqual(@as(usize, 128), heap.stats().active_small_bytes);
    for (bytes[0..24]) |byte| try std.testing.expectEqual(@as(u8, 0x5d), byte);

    allocator_instance.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), heap.stats().active_small_bytes);
    heap.deinit();
}

test "small resize stays inside the length size class" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .flush_thread_cache_on_thread_exit = false });
    const allocator_instance = heap.allocator();

    var bytes = try allocator_instance.alloc(u8, 200);
    const ptr = bytes.ptr;
    try std.testing.expect(allocator_instance.resize(bytes, 196));
    bytes.len = 196;
    try std.testing.expect(allocator_instance.resize(bytes, 224));
    bytes.len = 224;
    try std.testing.expect(!allocator_instance.resize(bytes, 24));
    try std.testing.expect(!allocator_instance.resize(bytes, 225));

    bytes = try allocator_instance.realloc(bytes, 24);
    try std.testing.expect(@intFromPtr(ptr) != @intFromPtr(bytes.ptr));
    allocator_instance.free(bytes);

    const reused = try allocator_instance.alloc(u8, 200);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(reused.ptr));
    allocator_instance.free(reused);
    heap.deinit();
}

test "thread-safe small allocations run across size classes" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .collect_stats = true });
    const allocator_instance = heap.allocator();

    const sizes = [_]usize{ 16, 48, 256, 2048 };
    var work: [threaded_test_threads]ThreadedTestWork = undefined;
    var threads: [threaded_test_threads]sys_thread.JoinHandle = undefined;

    for (&threads, 0..) |*thread, index| {
        work[index] = .{
            .allocator = allocator_instance,
            .len = sizes[index],
            .seed = @truncate(index * 17),
        };
        thread.* = try sys_thread.spawn(threadedStressWorker, .{&work[index]});
    }
    for (threads) |thread| thread.join();

    const stats = heap.stats();
    const expected = threaded_test_threads * threaded_test_batch * threaded_test_rounds;
    try std.testing.expectEqual(@as(u64, expected), stats.small_allocations);
    try std.testing.expectEqual(@as(u64, expected), stats.small_frees);
    try std.testing.expectEqual(@as(usize, 0), stats.active_small_bytes);

    heap.deinit();
}

test "thread cache tolerates freeing on another thread" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    const allocator_instance = heap.allocator();

    var handoff = std.atomic.Value(u32).init(0);
    var records: [thread_cache_remote_test_batch][]u8 = undefined;
    const work: ThreadCacheRemoteWork = .{
        .heap = &heap,
        .allocator = allocator_instance,
        .handoff = &handoff,
        .records = &records,
    };
    const consumer = try sys_thread.spawn(threadCacheRemoteFreeWorker, .{&work});

    for (&records, 0..) |*record, index| {
        const bytes = try allocator_instance.alloc(u8, 48);
        @memset(bytes, @truncate(index));
        record.* = bytes;
    }
    handoff.store(1, .release);
    while (handoff.load(.acquire) != 2) {
        std.atomic.spinLoopHint();
    }
    consumer.join();

    heap.deinit();
}

test "worker can explicitly flush its thread cache before exit" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    var freed_records: [thread_cache_flush_test_batch][]u8 = undefined;
    var work: ThreadCacheFlushWork = .{
        .heap = &heap,
        .allocator = allocator_instance,
        .records = &freed_records,
    };

    const thread = try sys_thread.spawn(threadCacheFlushWorker, .{&work});
    thread.join();

    var reused_count: usize = 0;
    var allocated_records: [thread_cache_flush_test_batch][]u8 = undefined;
    for (&allocated_records) |*record| {
        const bytes = try allocator_instance.alloc(u8, 48);
        record.* = bytes;
        if (containsTestPointer(thread_cache_flush_test_batch, &freed_records, bytes.ptr)) reused_count += 1;
    }
    for (allocated_records) |record| allocator_instance.free(record);

    try std.testing.expectEqual(@as(usize, thread_cache_flush_test_batch), reused_count);
}

test "small pages can be provisioned directly from the OS" {
    if (!sys.memory.anonymousMappingSupported()) return error.SkipZigTest;

    var heap = GpAllocator.init(std.testing.allocator, .{
        .empty_page_retention_limit = 0,
        .collect_stats = true,
        .page_provider = .os,
    });
    const allocator_instance = heap.allocator();

    const bytes = try allocator_instance.alloc(u8, 16);
    @memset(bytes, 0x6d);

    var stats = heap.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.pages_allocated);
    try std.testing.expectEqual(page_size, stats.mapped_small_bytes);

    allocator_instance.free(bytes);
    stats = heap.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.pages_freed);
    try std.testing.expectEqual(@as(usize, 0), stats.mapped_small_bytes);

    heap.deinit();
}

test "retained OS pages can discard unused block memory" {
    if (!sys.memory.anonymousMappingSupported()) return error.SkipZigTest;

    var heap = GpAllocator.init(std.testing.allocator, .{
        .collect_stats = true,
        .page_provider = .os,
        .retained_empty_page_policy = .discard_unused,
    });
    const allocator_instance = heap.allocator();

    const first = try allocator_instance.alloc(u8, 16);
    allocator_instance.free(first);

    var stats = heap.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.pages_allocated);
    try std.testing.expectEqual(@as(u64, 0), stats.pages_freed);
    try std.testing.expectEqual(@as(u64, 1), stats.empty_page_discards);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_empty_pages);
    try std.testing.expect(stats.discarded_small_bytes > 0);
    try std.testing.expect(stats.discarded_small_bytes < page_size);

    const second = try allocator_instance.alloc(u8, 16);
    @memset(second, 0x73);
    stats = heap.stats();
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(second.ptr));
    try std.testing.expectEqual(@as(usize, 0), stats.retained_empty_pages);
    try std.testing.expectEqual(@as(usize, 0), stats.discarded_small_bytes);
    allocator_instance.free(second);

    heap.deinit();
}

test "sys thread exit hook flushes partial local thread cache" {
    if (!sys.thread.threadSpecificDestructorsSupported()) return error.SkipZigTest;

    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    var freed_records: [sys_thread_exit_batch][]u8 = undefined;
    var work: SysThreadExitWorker = .{
        .allocator = allocator_instance,
        .records = &freed_records,
    };

    const thread = try sys_thread.spawn(SysThreadExitWorker.allocateAndFree, .{&work});
    thread.join();

    var reused_count: usize = 0;
    var allocated_records: [sys_thread_exit_batch][]u8 = undefined;
    for (&allocated_records) |*record| {
        const bytes = try allocator_instance.alloc(u8, 48);
        record.* = bytes;
        if (containsTestPointer(sys_thread_exit_batch, &freed_records, bytes.ptr)) reused_count += 1;
    }
    for (allocated_records) |record| allocator_instance.free(record);

    try std.testing.expectEqual(@as(usize, sys_thread_exit_batch), reused_count);
}

fn threadedStressWorker(work: *const ThreadedTestWork) void {
    var records: [threaded_test_batch][]u8 = undefined;
    var round: usize = 0;
    while (round < threaded_test_rounds) : (round += 1) {
        for (&records, 0..) |*record, index| {
            const bytes = work.allocator.alloc(u8, work.len) catch @panic("allocation failed");
            @memset(bytes, @truncate(index + round + work.seed));
            record.* = bytes;
        }
        for (records) |record| {
            std.mem.doNotOptimizeAway(record.ptr);
            work.allocator.free(record);
        }
    }
}

fn threadCacheRemoteFreeWorker(work: *const ThreadCacheRemoteWork) void {
    while (work.handoff.load(.acquire) == 0) {
        std.atomic.spinLoopHint();
    }
    for (work.records.*) |record| {
        std.mem.doNotOptimizeAway(record.ptr);
        work.allocator.free(record);
    }
    work.handoff.store(2, .release);
    work.heap.flushThreadCacheForCurrentThread();
}

fn threadCacheFlushWorker(work: *const ThreadCacheFlushWork) void {
    for (work.records, 0..) |*record, index| {
        const bytes = work.allocator.alloc(u8, 48) catch @panic("allocation failed");
        bytes[0] = @truncate(index);
        record.* = bytes;
    }
    for (work.records.*) |record| work.allocator.free(record);
    work.heap.flushThreadCacheForCurrentThread();
}

fn containsTestPointer(comptime count: usize, records: *const [count][]u8, ptr: [*]u8) bool {
    for (records.*) |record| {
        if (record.ptr == ptr) return true;
    }
    return false;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(size_class);
    std.testing.refAllDecls(cache_policy);
    std.testing.refAllDecls(large_cache_policy);
    std.testing.refAllDecls(stats_mod);
}

test "thread cache refill batches small classes more aggressively" {
    const small_class = size_class.indexFor(48, .@"1").?;
    const medium_class = size_class.indexFor(200, .@"1").?;
    const large_class = size_class.indexFor(2048, .@"1").?;

    try std.testing.expectEqual(@as(usize, cache_policy.thread_extra_class_refill_max), cache_policy.threadRefillCount(small_class));
    try std.testing.expectEqual(@as(usize, 256), cache_policy.threadRefillCount(medium_class));
    try std.testing.expectEqual(@as(usize, cache_policy.threadClassLimit(large_class)), cache_policy.threadRefillCount(large_class));
}

test "thread cache drain stages blocks in central transfer cache" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .flush_thread_cache_on_thread_exit = false });
    const allocator_instance = heap.allocator();
    const class_index = comptime size_class.indexFor(48, .@"1").?;
    const record_count = comptime cache_policy.transferClassLimit(class_index);

    var records: [record_count][]u8 = undefined;
    for (&records, 0..) |*record, index| {
        const bytes = try allocator_instance.alloc(u8, 48);
        bytes[0] = @truncate(index);
        record.* = bytes;
    }
    for (records) |record| allocator_instance.free(record);

    heap.flushCurrentThreadCache(@returnAddress());
    try std.testing.expectEqual(@as(usize, cache_policy.transferClassLimit(class_index)), heap.bins[class_index].local_transfer.count);

    for (records[0..cache_policy.transferClassLimit(class_index)]) |*record| {
        record.* = try allocator_instance.alloc(u8, 48);
    }
    try std.testing.expectEqual(@as(usize, 0), heap.bins[class_index].local_transfer.count);

    for (records[0..cache_policy.transferClassLimit(class_index)]) |record| allocator_instance.free(record);
    heap.deinit();
}

test "public thread-cache flush releases heap-owned cache storage" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .flush_thread_cache_on_thread_exit = false });
    const allocator_instance = heap.allocator();

    const bytes = try allocator_instance.alloc(u8, 48);
    allocator_instance.free(bytes);
    try std.testing.expect(loadThreadCache() != null);
    try std.testing.expectEqual(@as(usize, 1), heap.active_thread_cache_count);

    heap.flushThreadCacheForCurrentThread();
    try std.testing.expect(loadThreadCache() == null);
    try std.testing.expectEqual(@as(usize, 0), heap.active_thread_cache_count);
    try std.testing.expectEqual(@as(usize, 1), heap.retained_thread_cache_count);

    const second = try allocator_instance.alloc(u8, 48);
    allocator_instance.free(second);
    try std.testing.expect(loadThreadCache() != null);
    try std.testing.expectEqual(@as(usize, 1), heap.active_thread_cache_count);
    try std.testing.expectEqual(@as(usize, 0), heap.retained_thread_cache_count);

    heap.deinit();
    try std.testing.expect(loadThreadCache() == null);
    try std.testing.expectEqual(@as(usize, 0), heap.active_thread_cache_count);
}

test "default active thread-cache limit resolves from CPU count" {
    var heap = GpAllocator.init(std.testing.allocator, .{ .flush_thread_cache_on_thread_exit = false });
    const allocator_instance = heap.allocator();

    try std.testing.expectEqual(@as(usize, 0), heap.active_thread_cache_limit);

    const bytes = try allocator_instance.alloc(u8, 48);
    allocator_instance.free(bytes);

    try std.testing.expectEqual(defaultThreadCacheActiveLimit(), heap.active_thread_cache_limit);
    try std.testing.expectEqual(cpuCountThreadCacheActiveLimit(), heap.active_thread_cache_limit);

    heap.deinit();
}

test "active thread-cache limit falls back to central bins" {
    var heap = GpAllocator.init(std.testing.allocator, .{
        .flush_thread_cache_on_thread_exit = false,
        .thread_cache_active_limit = 1,
    });
    const allocator_instance = heap.allocator();

    const bytes = try allocator_instance.alloc(u8, 48);
    allocator_instance.free(bytes);
    try std.testing.expect(loadThreadCache().?.owner == @as(*anyopaque, @ptrCast(&heap)));
    try std.testing.expectEqual(@as(usize, 1), heap.active_thread_cache_limit);
    try std.testing.expectEqual(@as(usize, 1), heap.active_thread_cache_count);

    var work: ActiveThreadCacheLimitWorker = .{
        .heap = &heap,
        .allocator = allocator_instance,
    };
    const thread = try sys_thread.spawn(ActiveThreadCacheLimitWorker.allocateAndFree, .{&work});
    thread.join();

    try std.testing.expect(!work.used_cache);
    try std.testing.expectEqual(@as(usize, 1), heap.active_thread_cache_count);

    heap.flushThreadCacheForCurrentThread();
    try std.testing.expectEqual(@as(usize, 0), heap.active_thread_cache_count);
    try std.testing.expectEqual(@as(usize, 1), heap.retained_thread_cache_count);

    heap.deinit();
}

test "large cache retains reusable large blocks" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    const allocator_instance = heap.allocator();
    const len = max_small_size + 512;

    const first = try allocator_instance.alloc(u8, len);
    const ptr = first.ptr;
    allocator_instance.free(first);
    try std.testing.expect(heap.large_cache.cached_bytes > 0);

    const second = try allocator_instance.alloc(u8, len);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(second.ptr));
    allocator_instance.free(second);
    heap.deinit();
}

test "large cache resizes only inside the same large class" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    const len = max_small_size + 512;
    const bytes = try allocator_instance.alloc(u8, len);
    try std.testing.expect(allocator_instance.resize(bytes, len + 256));
    try std.testing.expect(!allocator_instance.resize(bytes, len + 4096));
    allocator_instance.free(bytes);
}

test "large cache preserves actual class when reusing a larger block" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    const larger_len = max_small_size + 32 * 1024;
    const smaller_len = max_small_size + 512;
    const first = try allocator_instance.alloc(u8, larger_len);
    const ptr = first.ptr;
    allocator_instance.free(first);

    const second = try allocator_instance.alloc(u8, smaller_len);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(second.ptr));
    try std.testing.expect(allocator_instance.resize(second, larger_len));
    const grown: []u8 = second.ptr[0..larger_len];
    allocator_instance.free(grown);
}

test "medium large cache retains Barnes-sized page runs" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    const allocator_instance = heap.allocator();
    const len = 400 * 1024;

    const first = try allocator_instance.alloc(u8, len);
    const ptr = first.ptr;
    allocator_instance.free(first);
    try std.testing.expect(heap.medium_large_cache != null);
    try std.testing.expect(heap.medium_large_cache.?.cached_bytes > 0);

    const second = try allocator_instance.alloc(u8, len);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(second.ptr));
    allocator_instance.free(second);
    heap.deinit();
}

test "medium large cache resizes only inside medium classes" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    const len = 400 * 1024;
    const bytes = try allocator_instance.alloc(u8, len);
    const resized_len = len + 1024;
    try std.testing.expect(allocator_instance.resize(bytes, resized_len));
    var resized = bytes;
    resized.len = resized_len;
    try std.testing.expect(!allocator_instance.resize(resized, large_cache_policy.max_small_cached_size));
    try std.testing.expect(!allocator_instance.resize(resized, large_cache_policy.max_medium_cached_size + 1));
    allocator_instance.free(resized);
}

test "uncached large remap does not shrink into medium cache representation" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    const uncached_len = large_cache_policy.max_medium_cached_size + 64 * 1024;
    const medium_len = 400 * 1024;
    var bytes = try allocator_instance.alloc(u8, uncached_len);
    @memset(bytes[0..medium_len], 0xa5);

    try std.testing.expect(allocator_instance.remap(bytes, medium_len) == null);
    bytes = try allocator_instance.realloc(bytes, medium_len);
    defer allocator_instance.free(bytes);
    try std.testing.expectEqual(@as(usize, medium_len), bytes.len);
    for (bytes[0..1024]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

test "array list owned slice from uncached large capacity frees as medium cache allocation" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    defer heap.deinit();
    const allocator_instance = heap.allocator();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator_instance);
    try list.ensureTotalCapacityPrecise(allocator_instance, large_cache_policy.max_medium_cached_size + 64 * 1024);
    try list.appendNTimes(allocator_instance, 0x6e, 400 * 1024);

    const owned = try list.toOwnedSlice(allocator_instance);
    defer allocator_instance.free(owned);
    try std.testing.expectEqual(@as(usize, 400 * 1024), owned.len);
    for (owned[0..1024]) |byte| try std.testing.expectEqual(@as(u8, 0x6e), byte);
}

test "cross-thread free drains through the freeing thread cache" {
    var heap = GpAllocator.init(std.testing.allocator, .{});
    const allocator_instance = heap.allocator();

    var records: [cross_thread_free_batch][]u8 = undefined;
    for (&records, 0..) |*record, index| {
        const bytes = try allocator_instance.alloc(u8, 48);
        bytes[0] = @truncate(index);
        record.* = bytes;
    }

    heap.flushCurrentThreadCache(@returnAddress());
    const page = page_mod.fromBlock(records[0].ptr);
    try std.testing.expectEqual(@as(u16, @intCast(cache_policy.threadRefillCount(page.class_index))), page.live_count);

    var work: CrossThreadFreeWorker = .{
        .heap = &heap,
        .records = &records,
        .allocator = allocator_instance,
    };
    const thread = try sys_thread.spawn(CrossThreadFreeWorker.freeAll, .{&work});
    thread.join();

    const expected_refill = cache_policy.threadRefillCount(page.class_index);
    try std.testing.expectEqual(expected_refill, heap.bins[page.class_index].local_transfer.count);
    heap.deinit();
}
