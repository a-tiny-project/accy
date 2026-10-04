const size_class = @import("class.zig");

const default_large_cache_limit_bytes: usize = 256 * 1024 * 1024;

pub const PageProvider = enum {
    backing_allocator,
    os,
};

pub const RetainedEmptyPagePolicy = enum {
    keep_committed,
    discard_unused,
};

pub const Config = struct {
    thread_safe: bool = true,
    empty_page_retention_limit: usize = 1,
    empty_page_reuse_limit: usize = 512,
    thread_cache: bool = true,
    flush_thread_cache_on_thread_exit: bool = true,
    thread_cache_active_limit: usize = 0,
    thread_cache_retention_limit: usize = 8,
    large_cache: bool = true,
    large_cache_limit_bytes: usize = default_large_cache_limit_bytes,
    collect_stats: bool = false,
    page_provider: PageProvider = .backing_allocator,
    retained_empty_page_policy: RetainedEmptyPagePolicy = .keep_committed,
};

pub const min_alignment = size_class.min_alignment;
pub const page_size = size_class.page_size;
pub const max_small_size = size_class.max_small_size;
pub const class_sizes = size_class.sizes;
