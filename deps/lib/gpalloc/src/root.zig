//! `GpAllocator` provides a general-purpose heap over a caller-supplied
//! `std.mem.Allocator` stored at init and asked for pages and large blocks, the
//! *backing allocator*. A request up to 32 KiB takes the first class at least
//! as large as itself from a fixed list of 40 block sizes, its *size class*,
//! with blocks carved from a 64 KiB span, a *page*. Each thread keeps its own
//! array of free blocks per size class in thread-local storage, the *thread
//! cache*. With the thread cache on, an allocation pops a block from the
//! running thread's bin for that class and a free pushes one back, so the
//! common path takes no lock.
//!
//! Per-size-class state guarded by that class's mutex, the *bin*, holds that
//! class's pages. The bounded list inside the bin that collects blocks drained
//! from thread caches and refills them in batches is the *transfer list*. An
//! empty thread bin refills from it, drawing a batch of blocks from the
//! transfer list under the class mutex. A full thread bin drains a batch back
//! to that transfer list under the same mutex, and a block freed by a thread
//! other than the one that allocated it goes back the same way. Batching keeps
//! the class mutex out of the common path, because one lock covers a whole
//! batch of blocks.
//!
//! A request above the small range goes to the backing allocator through a
//! cache of retained blocks per class, the *large cache*, bounded by a byte
//! limit.
//!
//! Small pages come from the *page provider*, which is the backing allocator by
//! default, and `.page_provider = .os` maps them from the operating system.
//!
//! Counters are off by default, and turning them on with
//! `.collect_stats = true` also turns off the thread cache and the large cache,
//! so a run that collects counters measures a different path from the one that
//! runs without them.
//!
//! A thread that exits hands its cache back to the heap, and a thread the
//! runtime cannot hook does the same by calling
//! `flushThreadCacheForCurrentThread`.

const allocator_mod = @import("allocator.zig");
pub const cache = @import("cache/root.zig");
pub const class = @import("class.zig");
pub const config = @import("config.zig");
pub const large = @import("large/root.zig");
pub const page = @import("page/root.zig");
pub const stats = @import("stats.zig");

pub const Config = config.Config;
pub const PageProvider = config.PageProvider;
pub const RetainedEmptyPagePolicy = config.RetainedEmptyPagePolicy;
pub const Stats = stats.Stats;
pub const GpAllocator = allocator_mod.GpAllocator;
pub const class_sizes = config.class_sizes;
pub const max_small_size = config.max_small_size;
pub const min_alignment = config.min_alignment;
pub const page_size = config.page_size;
