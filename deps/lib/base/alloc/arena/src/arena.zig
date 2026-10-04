const std = @import("std");
const observe = @import("alloc_observe");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// `Arena` groups allocations under one caller-controlled lifetime and releases
/// them together. When allocation observation is disabled, `Arena` aliases
/// `std.heap.ArenaAllocator`. When observation is enabled through
/// `-Dobserve-allocations=true`, it aliases `ObservedArena`, which wraps a
/// standard arena with an observation identity. Both variants provide `init`,
/// `allocator`, `deinit`, `queryCapacity`, `reset`, and the `ResetMode` union.
/// Standard library details such as `std.heap.ArenaAllocator.State`, `promote`,
/// and concrete struct fields are not guaranteed when observation is active.
///
/// The owner enforces no fixed byte or node capacity cap of its own, drawing
/// fresh blocks on demand from a backing allocator. An `Allocator` handle
/// returned by `allocator` stores a pointer back to the arena, requiring the
/// caller to keep the arena owner at a stable memory address while using that
/// handle. The caller must keep the backing allocator state alive until the
/// arena and all allocated memory are torn down, but the small handle value
/// itself can be copied freely.
///
/// Calling `reset` or `deinit` ends the lifetime of all existing allocations at
/// once and invalidates every slice previously handed out. The arena does not
/// invoke destructors on individual objects before reclaiming storage, and
/// physical release of memory to the operating system depends on the backing
/// allocator.
///
/// The allocation vtable is thread-safe when the backing allocator is
/// thread-safe. In contrast, `reset` and `deinit` mutate internal state, and
/// `queryCapacity` reads shared state without synchronization, requiring
/// callers to exclude concurrent operations during those calls. When
/// observation is active, the allocation vtable remains thread-safe if both the
/// backing allocator and observation sinks support concurrent calls, but
/// observation callbacks require their own synchronization.
pub const Arena = if (observe.enabled)
    ObservedArena
else
    std.heap.ArenaAllocator;

/// This wrapper embeds a standard library arena allocator and emits logical
/// memory operations and lifecycle events to the alloc_observe subsystem. The
/// wrapper assigns an immutable producer identity upon initialization that
/// survives moving the wrapper value in memory, though existing borrowed
/// Allocator handles continue to point to the owner's original memory address.
/// The wrapper acts as the sole owner of its inner storage and cannot be cloned
/// into an independent copy. Its observation generation counter begins at zero
/// and increments after every call to reset.
const ObservedArena = struct {
    /// The underlying standard library arena allocator that owns backing memory
    /// blocks and internal chunk bookkeeping, maintained directly by
    /// ObservedArena. Mutating this instance directly bypasses event emission
    /// and breaks lifecycle observation.
    inner: std.heap.ArenaAllocator,
    /// The `producerId` is a numeric identifier assigned at initialization from
    /// a process counter to identify the arena's operation stream. It is
    /// allocated whether or not an observation sink session is installed. The
    /// value derives an `owner_cookie` that is computed from this identifier
    /// rather than a memory address. This derivation keeps the cookie
    /// consistent when the owner moves in memory, but does not guarantee global
    /// collision freedom.
    producer_id: u64,
    /// The lifecycle generation counter tracks arena observation epochs,
    /// starting at 0 on initialization. The counter increments after each call
    /// to `reset`, including calls that return `false`, and panics on integer
    /// overflow.
    generation: u64 = 0,

    const Self = @This();

    /// Selects how the arena manages previously allocated storage during
    /// `reset`, aliasing `std.heap.ArenaAllocator.ResetMode`. The `free_all`
    /// mode returns all tracked memory nodes to the backing allocator and
    /// clears internal state to empty. The `retain_capacity` mode requests
    /// retention and preheating of existing buffer capacity for reuse, but does
    /// not guarantee that the immediate next allocation will avoid a backing
    /// request. The `retain_with_limit` mode requests an upper bound on
    /// retained payload capacity following the reset rather than establishing a
    /// lifetime memory cap. When `reset` fails and returns `false`, the arena
    /// may leave an old rewound node whose capacity exceeds the requested
    /// limit. The mode does not enforce a hard limit on future allocation
    /// requests or guarantee that unneeded storage is physically released to
    /// the operating system.
    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

    /// Creates an empty arena owner backed by the provided allocator,
    /// performing no backing block allocation during initialization. In the
    /// observed variant, this constructor assigns a new producer identity and
    /// sets the observation generation counter to 0.
    pub fn init(backing: Allocator) Self {
        return .{
            .inner = std.heap.ArenaAllocator.init(backing),
            .producer_id = observe.producerId(),
        };
    }

    /// Returns a borrowed std.mem.Allocator handle containing a pointer to this
    /// owner. The caller must keep the owner alive at a stable memory address
    /// for the duration of the handle's use, and retains ownership of the
    /// underlying backing allocator.
    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Releases all tracked backing memory blocks by calling deinit on the
    /// inner arena, and emits a lifecycle deinit event for the current
    /// observation generation. Every allocation handed out by the arena is
    /// immediately invalidated, and physical memory reclamation depends on the
    /// backing allocator. Any required destructor calls or object cleanup must
    /// occur before tearing down the arena storage. The operation cannot run
    /// concurrently with allocation, capacity queries, or resets, and does not
    /// reset internal state to permit reusing the instance afterward.
    pub fn deinit(self: *Self) void {
        var span = observe.beginLifecycle(
            self.identity(),
            .end,
            .deinit,
            @returnAddress(),
        );
        self.inner.deinit();
        span.finish(.{ .succeeded = true });
    }

    /// Returns the total payload capacity in bytes currently held across the
    /// arena's used and free chunk lists, excluding node header structures.
    /// This figure includes alignment padding and unallocated space within
    /// retained blocks, differing from the count of active payload bytes. The
    /// calculation provides no saturation guarantee against numeric overflow,
    /// and callers must serialize capacity queries with any concurrent
    /// mutations.
    pub fn queryCapacity(self: Self) usize {
        return self.inner.queryCapacity();
    }

    /// Ends the lifetime of all existing allocations, invalidating previously
    /// issued slices even if subsequent allocations reuse the same memory
    /// addresses. The return value indicates whether the requested retention or
    /// reallocation policy succeeded. When returning false, the arena remains
    /// functional but may leave an existing rewound chunk in place whose
    /// capacity exceeds the requested limit, while free_all always succeeds and
    /// returns true. Under observation, the method emits an invalidation event
    /// for the old generation reporting whether retention succeeded, then
    /// increments the generation counter, panicking on counter overflow.
    /// Callers must exclude all concurrent access while resetting the arena.
    pub fn reset(self: *Self, mode: ResetMode) bool {
        var span = observe.beginLifecycle(
            self.identity(),
            .invalidate,
            .reset,
            @returnAddress(),
        );
        const succeeded = self.inner.reset(mode);
        span.finish(.{ .succeeded = succeeded });
        self.generation = nextGeneration(self.generation);
        return succeeded;
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        var span = observe.beginOwned(
            self.identity(),
            .alloc,
            0,
            0,
            len,
            alignment.toByteUnits(),
            return_address,
        );
        const result = self.inner.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        );
        span.finish(.{
            .address = if (result) |ptr| @intFromPtr(ptr) else 0,
            .succeeded = result != null,
        });
        return result;
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        var span = observe.beginOwned(
            self.identity(),
            .resize,
            @intFromPtr(memory.ptr),
            memory.len,
            new_len,
            alignment.toByteUnits(),
            return_address,
        );
        const succeeded = self.inner.allocator().rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
        span.finish(.{
            .address = if (succeeded) @intFromPtr(memory.ptr) else 0,
            .succeeded = succeeded,
        });
        return succeeded;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        var span = observe.beginOwned(
            self.identity(),
            .remap,
            @intFromPtr(memory.ptr),
            memory.len,
            new_len,
            alignment.toByteUnits(),
            return_address,
        );
        const result = self.inner.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
        span.finish(.{
            .address = if (result) |ptr| @intFromPtr(ptr) else 0,
            .succeeded = result != null,
        });
        return result;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        var span = observe.beginOwned(
            self.identity(),
            .free,
            @intFromPtr(memory.ptr),
            memory.len,
            0,
            alignment.toByteUnits(),
            return_address,
        );
        self.inner.allocator().rawFree(
            memory,
            alignment,
            return_address,
        );
        span.finish(.{
            .address = @intFromPtr(memory.ptr),
            .succeeded = true,
        });
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn identity(self: *const Self) observe.Identity {
        return observe.Identity.movable(
            self.producer_id,
            .arena,
            self.generation,
        );
    }
};

fn nextGeneration(generation: u64) u64 {
    return std.math.add(u64, generation, 1) catch
        @panic("allocator observation generation exhausted");
}
