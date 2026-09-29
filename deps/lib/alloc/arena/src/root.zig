//! ## Shared temporary lifetimes
//!
//! Many temporary values created during an operation share an end-of-life
//! point. The package `alloc_arena` provides lifetime-scoped memory owners that
//! manage groups of allocations through an underlying allocator supplied by the
//! caller, termed the *backing allocator*. The owner requests buffers from the
//! backing allocator to serve individual slice requests and returns those
//! buffers when the owner terminates at `deinit`. Physical memory reclamation
//! depends on the policy of that chosen backing allocator.
//!
//! Callers interact with an owner through a borrowed `std.mem.Allocator`
//! handle, which pairs a pointer to the owner instance with an allocation
//! virtual table. For this handle to stay valid, both the owner instance and
//! the state backing its child allocator must remain valid at stable memory
//! locations while the handle is in use. The `std.mem.Allocator` value itself
//! is a small interface handle that callers can pass and copy by value without
//! pinning. Copying an owner struct duplicates its scalar fields rather than
//! the underlying buffer ownership, and moving an owner object leaves existing
//! borrowed handles pointing to the old address. In addition, bulk owner
//! reclamation frees raw storage without invoking object destructors. Any
//! resource managing external state, such as an open file descriptor, must be
//! released explicitly before the owner terminates.
//!
//! When a temporary owner terminates, returning data to an outer scope requires
//! a strategy for extending values past that lifetime boundary. One concrete
//! approach is copy-out: duplicating the final result into memory managed by an
//! independent allocator before destroying the temporary owner. In a
//! diagnostic renderer, for example, `renderAlloc`
//! instantiates a temporary `Arena` to build formatted diagnostic text, copies
//! the finished bytes into the caller's allocator with `dupe`, and releases the
//! temporary arena through a deferred `deinit`.
//!
//! ```zig
//! const std = @import("std");
//! const alloc_arena = @import("alloc_arena");
//!
//! fn renderDiagnostic(output: std.mem.Allocator) ![]u8 {
//!     var arena = alloc_arena.Arena.init(output);
//!     defer arena.deinit();
//!
//!     const temporary = try arena.allocator().dupe(u8, "diagnostic report payload");
//!     return try output.dupe(u8, temporary);
//! }
//!
//! test "owned output survives temporary arena teardown" {
//!     const slice = try renderDiagnostic(std.testing.allocator);
//!     defer std.testing.allocator.free(slice);
//!
//!     try std.testing.expectEqualStrings("diagnostic report payload", slice);
//! }
//! ```
//!
//! ## Reusing an arena
//!
//! The package provides `Arena` for workloads that benefit from reusing
//! capacity. `Arena` tracks the standard library implementation
//! `std.heap.ArenaAllocator` pinned at Zig 0.17.0-dev.1465+8b2d0ce21. In
//! unobserved builds, `Arena` is a direct type alias for
//! `std.heap.ArenaAllocator`. Under `-Dobserve-allocations=true`, it wraps that
//! standard implementation to publish lifecycle and allocation events. Code
//! designed to run in both configurations relies on the shared common surface:
//! `init`, `allocator`, `deinit`, `queryCapacity`, `reset`, and `ResetMode`.
//! Caller code targeting the unobserved configuration specifically may still
//! access standard library features such as internal allocator state or
//! promotion when those facilities are available.
//!
//! Capacity reporting in `Arena` measures buffer capacity rather than active
//! allocations. The function `queryCapacity` computes the sum of payload
//! capacities across all held buffer nodes, excluding internal node metadata
//! headers. This total includes alignment padding between allocations and
//! unallocated space at the end of buffers, but does not track the live byte
//! count requested by callers.
//!
//! Calling `reset` terminates the lifetime of all existing allocations and
//! invalidates every previously issued slice, regardless of whether the
//! function returns `true` or `false`. The returned boolean indicates whether
//! the requested retention or buffer reallocation succeeded. Even when `reset`
//! returns `false`, the arena remains valid and ready to serve new allocations.
//!
//! The behavior of `reset` depends on the selected mode:
//!
//! - `free_all` releases all tracked nodes to the child allocator, resets
//!   internal state to empty, and always returns `true`.
//! - `retain_capacity` requests retention and preheating of current buffer
//!   capacity to service subsequent requests. Retaining capacity does not
//!   guarantee that future allocations will avoid calls to the backing
//!   allocator.
//! - `retain_with_limit` requests an upper bound on retained payload capacity
//!   after the reset rather than establishing a lifetime memory budget. If
//!   resizing or allocating a replacement node fails, `reset` returns `false`
//!   and may leave an existing rewound node whose capacity exceeds the
//!   requested limit.
//!
//! ## Fitting fresh requests in sequential scopes
//!
//! For tasks that do not require intermediate resets, `SequentialScope`
//! provides an independent, sequential implementation. Its interface exposes
//! `init`, `allocator`, `deinit`, and `queryCapacity`. Unlike `Arena`,
//! `SequentialScope` does not provide a reset function or capacity retention
//! modes. It enforces no intrinsic fixed limit on total bytes or node counts,
//! so overall memory consumption remains bounded by backing allocator capacity.
//!
//! When serving an allocation request, `SequentialScope` checks the current
//! head buffer first. If that buffer contains sufficient room, the scope carves
//! the requested slice directly from it. When the head buffer cannot satisfy
//! the request, the owner attempts to enlarge that existing node in place
//! through the backing allocator's `rawResize`, testing a larger preferred size
//! before falling back to the exact required size. The scope never calls
//! `rawRemap` on an existing node, ensuring that addresses already issued to
//! callers stay in place.
//!
//! If in-place enlargement fails, the scope requests a fresh node from the
//! backing allocator using `rawAlloc`. This initial request covers the exact
//! space needed for the node header, the requested slice length, and
//! conservative alignment padding. Only after this exact allocation succeeds
//! does the scope attempt to expand the node to a larger preferred size through
//! `rawRemap`. Because no caller pointers have been issued into the fresh node
//! yet, relocation during this remap cannot disrupt caller addresses. If the
//! backing allocator refuses the remap, the smaller exact block still serves
//! the request, and the scope links the node at the list head before publishing
//! the pointer. Because request sizes and alignment requirements vary, new
//! nodes need not be successively larger than their predecessors.
//!
//! SequentialScope satisfies individual allocations out of existing nodes by
//! advancing a frontier offset within the current head node buffer. The
//! frontier is the byte offset delimiting the portion of the current head
//! buffer already used for allocations, including padding and holes left by
//! earlier frees, rather than the sum of active allocations. A free operation
//! rewinds this frontier only if the released slice ends at the current head
//! frontier. Consequently, shrinking a non-tail allocation succeeds without
//! reclaiming buffer space, and a non-tail allocation cannot grow in place.
//! Alignment gaps created by earlier requests may remain within the node.
//!
//! When callers invoke `rawRemap` on an issued allocation, the scope delegates
//! to `rawResize` and will not move an existing allocation. It does not invoke
//! child.rawResize or grow a backing node. The child allocator's rawResize is
//! instead used when satisfying a new allocation via allocateFromNode, which is
//! a separate operation. Calling `std.mem.Allocator.realloc` on an interior
//! slice may therefore fall back to an allocate-copy-free sequence. Finally,
//! scope deinit returns entire backing nodes in newest-first order, where
//! physical reuse of that memory depends on the child allocator.
//!
//! The following test verifies exact-first allocation when a backing allocator
//! lacks space for opportunistic growth. A fixed buffer allocator provides
//! storage for one node header and payload, but rejects the larger preferred
//! expansion. The scope accepts the exact allocation, consumes the backing
//! buffer, and releases its memory upon deinitialization. The test fixture's
//! three-word header reflects the current internal implementation layout rather
//! than a stable ABI:
//!
//! ```zig
//! const std = @import("std");
//! const alloc_arena = @import("alloc_arena");
//!
//! test "fresh exact allocation fits fixed child when preferred expansion is refused" {
//!     var storage: [96]u8 align(@alignOf(usize)) = undefined;
//!     var child = std.heap.FixedBufferAllocator.init(&storage);
//!
//!     const header_len = 3 * @sizeOf(usize);
//!     const payload_len = storage.len - header_len;
//!
//!     {
//!         var scope = alloc_arena.SequentialScope.init(child.allocator());
//!         defer scope.deinit();
//!
//!         const scoped = scope.allocator();
//!         const allocation = try scoped.alignedAlloc(u8, .of(usize), payload_len);
//!
//!         try std.testing.expectEqual(payload_len, allocation.len);
//!         try std.testing.expectEqual(payload_len, scope.queryCapacity());
//!         try std.testing.expectEqual(storage.len, child.end_index);
//!
//!         try std.testing.expectError(error.OutOfMemory, scoped.alloc(u8, 1));
//!     }
//!
//!     try std.testing.expectEqual(@as(usize, 0), child.end_index);
//! }
//! ```
//!
//! ## Allocation observation and concurrency
//!
//! When compiled with `-Dobserve-allocations=true`, both `Arena` and
//! `SequentialScope` publish allocation events and lifecycle spans to an event
//! consumer through `alloc_observe`. An event's `succeeded` flag indicates
//! whether the allocator operation succeeded, rather than whether physical
//! bytes were released by the host operating system. Calling `Arena.reset`
//! emits an invalidate lifecycle span for the previous generation and advances
//! the generation counter, even when `reset` returns `false`. If a subsequent
//! allocation receives a memory address previously held by an earlier
//! allocation, the new slice represents an independent lifetime rather than a
//! revival of the earlier pointer. Calling `Arena.deinit` emits an end
//! lifecycle span.
//!
//! The standard `Arena` allocation vtable supports concurrent allocation when
//! the underlying child allocator is thread-safe and the arena remains pinned
//! at a stable address. When observation is active, observation callbacks must
//! also support concurrent delivery. In contrast, `reset` and `deinit` mutate
//! internal state and require exclusive access. The `queryCapacity` method only
//! reads state rather than mutating it, but callers must still exclude
//! concurrent mutation during the query.
//!
//! `SequentialScope` is not thread-safe and contains no internal locks or
//! runtime concurrency guards, even when wrapped for observation. Callers must
//! ensure all operations remain sequential. If multiple threads interact with
//! the same scope, the caller must provide external synchronization to
//! serialize access.
//!
//! ## Related lifetime models
//!
//! Lifetime-scoped allocation groups object lifetimes under explicit
//! programmatic control. In [Hanson
//! (1990)](https://drhanson.s3.amazonaws.com/storage/documents/fastalloc.pdf),
//! dynamic storage allocation organizes memory through linked buffers that are
//! deallocated together or retained across cycles. By contrast, static region
//! inference, as formalized by [Tofte and Talpin
//! (1994)](https://www.cs.cmu.edu/afs/cs/academic/class/15745-s06/web/handouts/tofte-popl94.pdf),
//! deduces region lifetimes automatically at compile time and inserts
//! allocation and deallocation operations without programmer intervention. The
//! package `alloc_arena` operates within the manual model: callers determine
//! lifetime boundaries at runtime, manage owner lifecycles explicitly, and
//! select when to release or retain storage.

const arena = @import("arena.zig");
const sequential = @import("sequential.zig");

/// Exports the primary arena allocator, which groups multiple allocations under
/// a single caller-managed lifetime and supports resetting capacity for reuse.
/// At compile time, this alias resolves to ObservedArena when allocation
/// observation is enabled and to std.heap.ArenaAllocator when disabled.
pub const Arena = arena.Arena;
/// The root SequentialScope export provides a caller-controlled sequential
/// temporary lifetime ended by deinit, and the caller must serialize all use.
/// For fresh nodes, the initial allocation covers the current request including
/// the node header and conservative alignment room before optional spare
/// capacity expansion, meaning exact-first sizing is not payload-only and is
/// not the order for growing an existing node.
pub const SequentialScope = sequential.SequentialScope;
