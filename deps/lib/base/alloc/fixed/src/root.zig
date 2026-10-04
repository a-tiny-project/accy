//! ## Package overview
//!
//! Allocation strategies in this implementation package at `lib/base/alloc/fixed`
//! work over a buffer the caller provides or over an allocator upstream. A
//! reader chooses among the six strategies by what each one allocates from and
//! what that choice costs to reclaim. `Tracked` keeps the bump frontier offset
//! and records that a raw allocation ran out of room, while `used` reports the
//! current bump frontier offset.
//!
//! ### Tracked frontier accounting
//!
//! The struct `Tracked` keeps its numbers over a byte slice the caller
//! provides.
//!
//! ```zig
//! test "tutorial: tracked frontier accounting and reset" {
//!     const std = @import("std");
//!     const alloc_fixed = @import("alloc_fixed");
//!
//!     var storage: [64]u8 align(16) = undefined;
//!     var tracked = alloc_fixed.Tracked.init(&storage);
//!     const allocator = tracked.allocator();
//!
//!     // 1. Initial allocation advances the current frontier
//!     const first = try allocator.alloc(u8, 24);
//!     var status = tracked.status();
//!     try std.testing.expectEqual(@as(usize, 24), status.used_bytes);
//!     try std.testing.expectEqual(@as(usize, 24), status.peak_bytes);
//!     try std.testing.expectEqual(@as(usize, 24), status.high_water_bytes);
//!     try std.testing.expect(!status.exhausted);
//!
//!     // 2. Second allocation advances the frontier further
//!     const second = try allocator.alloc(u8, 24);
//!     status = tracked.status();
//!     try std.testing.expectEqual(@as(usize, 48), status.used_bytes);
//!     try std.testing.expectEqual(@as(usize, 48), status.peak_bytes);
//!
//!     // 3. Freeing the last allocation at the frontier reduces used_bytes
//!     allocator.free(second);
//!     status = tracked.status();
//!     try std.testing.expectEqual(@as(usize, 24), status.used_bytes);
//!     try std.testing.expectEqual(@as(usize, 48), status.peak_bytes);
//!
//!     // 4. Raw allocation failure sets the sticky exhausted flag
//!     try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 48));
//!     status = tracked.status();
//!     try std.testing.expect(status.exhausted);
//!
//!     allocator.free(first);
//!
//!     // 5. Reset rewinds the frontier and clears peak and exhausted
//!     tracked.reset();
//!     status = tracked.status();
//!     try std.testing.expectEqual(@as(usize, 0), status.used_bytes);
//!     try std.testing.expectEqual(@as(usize, 0), status.peak_bytes);
//!     try std.testing.expectEqual(@as(usize, 48), status.high_water_bytes);
//!     try std.testing.expect(!status.exhausted);
//! }
//! ```
//!
//! Callers wrap `Tracked` to hold a phase to its limit and read the sticky
//! record that a raw allocation came back empty for want of room through
//! `status().exhausted`, the *exhausted flag*.
//!
//! ### Allocation capabilities and owner stability
//!
//! In the Zig standard library a `std.mem.Allocator` is a pointer to the struct
//! that holds the storage and the bookkeeping behind an allocator handle, the
//! *owner*, paired with a pointer to a table of allocation functions, forming
//! the *allocator handle*:
//! - `ptr: *anyopaque` is the type-erased pointer to the owner that holds the
//!   state
//! - `vtable: *const VTable` points at the table of allocation functions
//!
//! The `allocator()` method borrows that handle from one of six owners:
//! `Tracked`, `Chunks`, `Recycling`, `Monotonic`, `Fallback`, or `FixedBuffer`.
//!
//! The duty of the caller to keep the owner alive and at one address for as
//! long as a handle points at it is *owner stability*. Copying the owner leaves
//! handles that already exist pointing at the original address, so working with
//! copies as independent allocators over the same storage drives their state
//! apart. Reaching a handle after the owner moves or goes away is undefined
//! behavior.
//!
//! ### Physical capacity, bump frontier, and alignment
//!
//! Four concepts govern the fixed-buffer and chunked strategies:
//!
//! 1. The whole byte slice an owner has to cut allocations from, which the
//!    caller provides or that comes from an upstream allocator, is the
//!    *physical capacity*.
//! 2. The byte offset reached so far inside a buffer, which every allocation
//!    advances, is the *bump frontier* (`used`). In `FixedBuffer` and `Tracked`
//!    it moves back when the newest allocation is freed or made smaller, but it
//!    stays where it is when an allocation is freed while later ones are still
//!    live.
//! 3. The bytes skipped to bring a pointer to the alignment a request asks for
//!    are the *alignment padding*. Padding carries the frontier past the
//!    requested length. Rewinding the frontier to zero with a *reset* makes
//!    that space available again, while freeing the most recent allocation
//!    first, a *LIFO free*, on its own leaves the alignment gaps behind.
//! 4. When memory comes back and how is the *reclamation policy*. In the bump
//!    and chunk strategies, freeing one allocation returns no interior hole, so
//!    memory comes back in bulk, through `reset`, `discard`, or the teardown of
//!    the arena behind the owner.
//!
//! ### Backing allocators and chunk retention
//!
//! Several strategies take memory from an upstream allocator supplied by the
//! caller, the *backing allocator* (`backing: Allocator`). A buffer obtained
//! from the backing allocator to serve multiple allocations is a *chunk*.
//! `Chunks`, `Recycling`, and `Monotonic` request chunks from this backing
//! allocator. By contrast, `Fallback` first uses its caller-supplied byte
//! slice and passes spill requests directly upstream.
//!
//! To track chunks, `Chunks` and `Recycling` each maintain at most 64 *chunk
//! descriptors*, where each descriptor records chunk storage and bookkeeping:
//! the buffer, its alignment, its active flag, and a count of live
//! allocations maintained only by `Recycling`. This fixed table bounds the
//! number of simultaneously tracked chunks rather than the total count of
//! allocation requests. That 64-descriptor bound applies only to `Chunks` and
//! `Recycling`: `Monotonic` retains only its current chunk descriptor, while
//! `Fallback` passes spill requests directly upstream.
//!
//! In `Recycling`, inactive chunk descriptors are kept for reuse and still
//! occupy slots in the table. In `Chunks`, calling `retain()` clears
//! descriptor tracking without freeing backing memory, so those committed
//! chunks no longer occupy its descriptor table.
//!
//! The next fresh chunk has `@max(scheduled_capacity, len)` bytes, taking the
//! larger of a planned size or the requested length. This planned capacity
//! starts at `initial_capacity`, doubles after each successful fresh chunk,
//! and stops growing at `maximum_capacity`, forming the *growth schedule*.
//! Reused chunks do not advance the schedule. Oversized requests are allowed
//! and do not change the doubling calculation to use their actual size. Thus
//! `maximum_capacity` caps the schedule, not individual requests or total
//! storage.
//!
//! - Clearing the descriptor table without freeing the backing memory through
//!   `retain()` commits the chunks to the lifetime of the upstream owner
//! - A language runtime uses that pattern to commit values
//!   it cloned into an outer arena
//! - Freeing every tracked chunk in reverse order back to the backing allocator
//!   and putting the growth schedule back where it started rolls the chunks
//!   back through `discard()`
//! - In `Recycling`, the number of allocations still outstanding in one chunk
//!   is tracked for each chunk as the *live allocation count*
//! - When frees bring the live count of the most recently activated chunk that
//!   every allocation tries first, the *tail chunk*, to zero, that chunk is
//!   deactivated by closing it and rewinding it, ready for the next allocation
//! - In `Recycling`, `rawRemap` returns `null` when it cannot grow the memory
//!   where it sits, and a caller going through `std.mem.Allocator.realloc` then
//!   gets the allocate, copy, and free path across chunks
//! - `rawResize` in `Chunks`, in `Recycling`, and in `Monotonic` answers `true`
//!   as soon as `new_len <= memory.len`, before it consults any chunk
//! - Shrinking therefore leaves the bump frontier where it was in those three,
//!   even for the most recent allocation
//! - Growing in place checks whether the memory belongs to the chunk currently
//!   open for allocation, the *active chunk*
//!
//! ### Strategy overview
//!
//! - `FixedBuffer`: the caller's slice, reclaimed by LIFO free or `reset()`
//! - `Tracked`: the caller's slice, with the frontier, the peak, the high-water
//!   mark, and the exhausted flag
//! - `Chunks`: a backing allocator, a doubling schedule, `retain()` to commit,
//!   and `discard()` to roll back
//! - `Recycling`: a backing allocator, tail chunk reuse, and the 64-descriptor
//!   limit
//! - `Monotonic`: a backing allocator, fixed chunks, the oversized bypass, and
//!   reclamation by arena teardown
//! - `Fallback`: the caller's slice with spillover to a backing allocator, and
//!   operations routed by provenance
//!
//! ### Primary literature and historical context
//!
//! - **David R. Hanson (1990):** *Fast Allocation and Deallocation of Memory
//!   Based on Object
//!   Lifetimes*, Software: Practice and Experience 20(1), pages 5–12, DOI:
//!   10.1002/spe.4380200104.
//!   [Author Scan](https://drhanson.s3.amazonaws.com/storage/documents/fastalloc.pdf).
//!
//!   Hanson grouped allocations by intended lifetime, allocated sequentially
//!   from a linked list of buffers, and deallocated each lifetime group
//!   together by resetting state to make backing buffers available for reuse
//!   instead of returning every block to the operating system. `Chunks`
//!   similarly groups allocations for a shared lifetime: `retain()` forgets
//!   tracked descriptors without freeing chunks and leaves committed storage
//!   to the upstream lifetime owner, while `discard()` issues backing frees
//!   for uncommitted chunks in reverse order. Actual physical reuse of the
//!   freed memory depends on the free policy of the backing allocator.
//!
//! - **Mads Tofte and Jean-Pierre Talpin (POPL 1994):** *Implementation of the
//!   Typed Call-by-Value
//!   lambda-Calculus using a Stack of Regions*, pages 188–201, DOI:
//!   10.1145/174675.177855.
//!   [Paper](https://www.cs.cmu.edu/afs/cs/academic/class/15745-s06/web/handouts/tofte-popl94.pdf).
//!
//!   Tofte and Talpin gave a proof that their translation, which annotates a
//!   program with regions, agrees with a store semantics built on regions, and
//!   their inference of regions and effects settles at compile time where
//!   memory is taken and given back. This package infers no region lifetimes
//!   and proves none: a caller manages memory through the borrowed handles
//!   instead.
//!
//! - **David Gay and Alex Aiken (PLDI 1998):** *Memory Management with Explicit
//!   Regions*,
//!   pages 313–323, DOI: 10.1145/277650.277748.
//!   [Author Site](https://theory.stanford.edu/~aiken/publications/papers/pldi98a.pdf).
//!
//!   Gay and Aiken designed safe regions by counting external region
//!   references through tracked region pointers, where `deleteregion` does
//!   nothing while the relevant reference count is nonzero. This mechanism
//!   tracks region pointers, so `deleteregion` does not account for region
//!   pointers cast to ordinary pointers. `Recycling` differs in purpose: its
//!   counts track outstanding allocations inside each chunk solely to find
//!   empty tails to deactivate and reuse. It tracks no references held
//!   outside and provides no dangling-pointer protection.
//!
//! ### Executable examples
//!
//! #### Transactional chunks commit and rollback (`Chunks`)
//!
//! The example rolls back after an injected failure from
//! `std.testing.FailingAllocator`, retries, commits with `retain()`, and shows
//! a request larger than `maximum_capacity` succeeding.
//!
//! ```zig
//! test "tutorial: transactional chunks rollback on injected failure and commit" {
//!     const std = @import("std");
//!     const alloc_fixed = @import("alloc_fixed");
//!
//!     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//!     defer arena.deinit();
//!
//!     // 1. Transaction failure scenario with injected allocation failure
//!     {
//!         var failing = std.testing.FailingAllocator.init(
//!             arena.allocator(),
//!             .{ .fail_index = 1 }, // Second backing allocation fails
//!         );
//!         var transaction = alloc_fixed.Chunks.init(failing.allocator(), 64, 128);
//!         errdefer transaction.discard();
//!
//!         // First chunk allocation (64 bytes) succeeds
//!         _ = try transaction.allocator().alloc(u8, 48);
//!         try std.testing.expectEqual(@as(usize, 1), failing.allocations);
//!         try std.testing.expectEqual(@as(usize, 64), failing.allocated_bytes);
//!
//!         // Second allocation (96 bytes) requires a new chunk; backing alloc returns null
//!         const failed_alloc = transaction.allocator().alloc(u8, 96);
//!         try std.testing.expectError(error.OutOfMemory, failed_alloc);
//!
//!         // Rollback frees the first chunk back to the backing allocator
//!         transaction.discard();
//!         try std.testing.expectEqual(@as(usize, 64), failing.freed_bytes);
//!         try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
//!     }
//!
//!     // 2. Transaction success scenario committing memory via retain()
//!     {
//!         var transaction = alloc_fixed.Chunks.init(arena.allocator(), 64, 128);
//!         const alloc = transaction.allocator();
//!
//!         const data1 = try alloc.alloc(u8, 48);
//!         const data2 = try alloc.alloc(u8, 96);
//!         // Requests exceeding maximum_capacity allocate max(scheduled, len)
//!         const oversized = try alloc.alloc(u8, 200);
//!
//!         @memset(data1, 0xAA);
//!         @memset(data2, 0xBB);
//!         @memset(oversized, 0xCC);
//!
//!         // Commit chunks to backing arena; transaction metadata is forgotten
//!         transaction.retain();
//!
//!         for (data1) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
//!         for (data2) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);
//!         for (oversized) |b| try std.testing.expectEqual(@as(u8, 0xCC), b);
//!     }
//! }
//! ```
//!
//! #### Tail-chunk recycling and metadata exhaustion (`Recycling`)
//!
//! The example follows the live allocation count, the tail chunk deactivating
//! so its memory is reused, and the 64-descriptor limit being reached while the
//! backing storage still has room.
//!
//! ```zig
//! test "tutorial: recycling tail deactivation and metadata exhaustion" {
//!     const std = @import("std");
//!     const alloc_fixed = @import("alloc_fixed");
//!
//!     var backing_bytes: [2048]u8 align(16) = undefined;
//!     var backing_tracked = alloc_fixed.Tracked.init(&backing_bytes);
//!
//!     var recycling = alloc_fixed.Recycling.init(
//!         backing_tracked.allocator(),
//!         64,
//!         128,
//!     );
//!     defer recycling.discard();
//!     const allocator = recycling.allocator();
//!
//!     const chunk1_slice = try allocator.alloc(u8, 48);
//!     const chunk2_slice = try allocator.alloc(u8, 80);
//!     try std.testing.expect(backing_tracked.status().used_bytes >= 144);
//!
//!     allocator.free(chunk2_slice);
//!     allocator.free(chunk1_slice);
//!
//!     const high_water_before = backing_tracked.status().high_water_bytes;
//!     const reused_slice = try allocator.alloc(u8, 48);
//!     defer allocator.free(reused_slice);
//!     try std.testing.expectEqual(high_water_before, backing_tracked.status().high_water_bytes);
//!
//!     var slot_tester = alloc_fixed.Recycling.init(
//!         backing_tracked.allocator(),
//!         16,
//!         16,
//!     );
//!     defer slot_tester.discard();
//!
//!     for (0..alloc_fixed.Recycling.maximum_chunk_count) |_| {
//!         _ = try slot_tester.allocator().alloc(u8, 16);
//!     }
//!
//!     try std.testing.expectError(error.OutOfMemory, slot_tester.allocator().alloc(u8, 16));
//!     try std.testing.expect(slot_tester.metadataExhausted());
//!     try std.testing.expect(!backing_tracked.status().exhausted);
//! }
//! ```
//!
//! #### Fixed buffer with backing spillover (`Fallback`)
//!
//! The example serves the first allocations from the fixed buffer, spills the
//! next to the caller's backing allocator, and checks which tier owns each
//! slice along with the count of backing allocations.
//!
//! ```zig
//! test "tutorial: fallback buffer with backing spillover" {
//!     const std = @import("std");
//!     const alloc_fixed = @import("alloc_fixed");
//!
//!     var storage: [64]u8 align(16) = undefined;
//!     var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
//!     var fallback = alloc_fixed.Fallback.init(&storage, counting.allocator());
//!     const allocator = fallback.allocator();
//!     const fixed_buf = try allocator.alloc(u8, 48);
//!     defer allocator.free(fixed_buf);
//!     @memset(fixed_buf, 0x11);
//!     try std.testing.expect(fallback.fixed.ownsSlice(fixed_buf));
//!     try std.testing.expectEqual(@as(usize, 0), counting.alloc_index);
//!     const backing_buf = try allocator.alloc(u8, 32);
//!     defer allocator.free(backing_buf);
//!     @memset(backing_buf, 0x22);
//!     try std.testing.expect(!fallback.fixed.ownsSlice(backing_buf));
//!     try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
//! }
//! ```
//!
//! #### Stream allocation with oversized bypass (`Monotonic`)
//!
//! The example fills fixed-capacity chunks while an oversized allocation goes
//! straight to the backing allocator, leaving the active tail chunk in place.
//!
//! ```zig
//! test "tutorial: monotonic stream allocation and preserved tail" {
//!     const std = @import("std");
//!     const alloc_fixed = @import("alloc_fixed");
//!     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//!     defer arena.deinit();
//!     var mono = alloc_fixed.Monotonic.init(arena.allocator(), 64);
//!     const allocator = mono.allocator();
//!     const first = try allocator.alloc(u8, 20);
//!     const second = try allocator.alloc(u8, 20);
//!     const oversized = try allocator.alloc(u8, 128);
//!     const tail = try allocator.alloc(u8, 16);
//!     @memset(first, 0x01);
//!     @memset(second, 0x02);
//!     @memset(oversized, 0x03);
//!     @memset(tail, 0x04);
//!     try std.testing.expectEqual(@intFromPtr(second.ptr) + second.len, @intFromPtr(tail.ptr));
//!     try std.testing.expect(@intFromPtr(oversized.ptr) != @intFromPtr(second.ptr) + second.len);
//!     try std.testing.expect(mono.isBackedBy(arena.allocator()));
//! }
//! ```

const fixed = @import("fixed.zig");

/// `Chunks` builds a result across several allocations, committing backing
/// chunks to an outer owner through `retain()` or invoking upstream frees for
/// rollback through `discard()`.
///
/// Fresh chunks requested from the backing allocator follow a growth schedule
/// that starts at `initial_capacity`, doubles after each successful fresh
/// chunk, and stops growing at `maximum_capacity`, with each fresh chunk
/// sized to `@max(scheduled_capacity, len)`. Requests larger than the
/// scheduled size are permitted without altering the doubling calculation,
/// but can fail from exhausted descriptor slots or backing allocation
/// failure.
///
/// The owner tracks at most 64 chunk descriptors simultaneously. Calling
/// `retain()` clears the descriptor table without freeing backing memory,
/// leaving committed storage for the upstream lifetime owner to reclaim.
pub const Chunks = fixed.Chunks;

/// When small work can run on the stack while larger requests spill to the
/// heap, `Fallback` tries a fixed storage buffer first and falls back to a
/// backing allocator. It adds no memory bound of its own, so the bound is
/// whatever the backing allocator imposes. Provenance routing sends every later
/// `free`, `resize`, or `remap` to the tier that owns the slice.
pub const Fallback = fixed.Fallback;

/// `FixedBuffer` is a fixed-capacity bump allocator that cuts allocations from
/// a caller-owned byte slice with no allocator behind it. With allocation
/// observation compiled in (`-Dobserve-allocations=true`) it resolves to
/// `ObservedFixedBuffer`, and with observation off it is
/// `std.heap.FixedBufferAllocator`.
pub const FixedBuffer = fixed.FixedBuffer;

/// To stream allocations inside an arena that will free everything at once,
/// `Monotonic` refills fixed-capacity chunks from a backing allocator. An
/// oversized allocation bypasses the chunk chain straight to backing storage,
/// leaving the active tail chunk in place. Built for growth inside an enclosing
/// arena lifetime, the owner has no `reset` and no `discard`, so the arena
/// behind it reclaims the memory.
pub const Monotonic = fixed.Monotonic;

/// `Recycling` reuses memory chunks across repeated workloads by tracking
/// outstanding allocations across up to 64 chunk descriptors, including
/// inactive chunks kept for reuse. When deallocations bring the live count of
/// the active tail chunk to zero, that chunk is deactivated and reset for
/// subsequent reuse. Because reusing an inactive chunk requires that its
/// capacity and alignment satisfy the new request, subsequent workloads may
/// still require new backing allocations if existing chunks lack sufficient
/// size or alignment.
pub const Recycling = fixed.Recycling;

/// `Tracked` provides fixed-capacity bump allocation over a caller-supplied
/// slice while measuring exact memory consumption. Bookkeeping records the
/// current bump frontier offset, the peak offset reached since the last reset,
/// the high-water mark over the owner's whole life, and the exhausted flag that
/// latches any raw allocation that ran out of room.
pub const Tracked = fixed.Tracked;

/// `used` reports in bytes how far the bump frontier of a `FixedBuffer` has
/// moved. That figure counts both payload bytes and alignment padding. The
/// figure stands above the bytes that are live once an allocation has been
/// freed ahead of a later one, and once alignment gaps remain behind.
pub const used = fixed.used;
