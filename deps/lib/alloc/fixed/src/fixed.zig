const std = @import("std");
const observe = @import("alloc_observe");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// This owner allocates from a byte slice the caller already owns, with no
/// allocator behind it, providing a fixed-capacity buffer allocator over that
/// slice. With observation left off (`-Dobserve-allocations=false`), it is
/// `std.heap.FixedBufferAllocator` itself. With observation compiled in
/// (`-Dobserve-allocations=true`), it is `ObservedFixedBuffer`, a wrapper
/// holding a `std.heap.FixedBufferAllocator` and a producer identity.
///
/// ### Owner stability and address requirements
/// The owner struct stays alive and at one memory address while a borrowed
/// allocator handle is in use. One owner serves one buffer, and the caller
/// takes no copy of it to act as a second allocator over that same storage.
///
/// ### Memory operations and reclamation
/// Memory is cut in order from the start of the buffer up to the byte offset
/// the allocations have reached inside the buffer, the *bump frontier*. Freeing
/// or shrinking the most recent allocation lowers the frontier. Freeing an
/// earlier allocation leaves its space taken until `reset()` rewinds the
/// frontier. Calling `reset()` rewinds the frontier to zero and leaves every
/// active allocation invalid, so the space can be used again.
///
/// ### Concurrency and thread safety
/// The ordinary `allocator()` handle needs the caller to serialize access. The
/// `threadSafeAllocator()` handle advances the frontier with lock-free
/// compare-and-swap inside the standard library allocator. With observation on,
/// the instrumented callbacks and the observation bookkeeping carry no such
/// guarantee and handle their own concurrency. Calling `used()` or reading the
/// owner's fields while thread-safe operations run leaves a data race. A caller
/// keeps concurrent calls to `allocator()` and to `threadSafeAllocator()`
/// apart, and leaves `reset()` alone while thread-safe operations may be
/// running. Calling `Tracked.status()` needs the caller's own serialization.
pub const FixedBuffer = if (observe.enabled)
    ObservedFixedBuffer
else
    std.heap.FixedBufferAllocator;

/// Reports in bytes how far the bump frontier of a `FixedBuffer` has moved. The
/// figure is the end index reached in the backing buffer, counting the payload
/// bytes and the alignment padding. Freeing or shrinking the most recent
/// allocation lowers it. The figure stands above the bytes that are live once
/// an allocation has been freed ahead of a later one, and once alignment gaps
/// remain behind.
pub fn used(owner: *const FixedBuffer) usize {
    return if (comptime observe.enabled)
        owner.inner.end_index
    else
        owner.end_index;
}

/// When a caller allocates from its own slice and needs to find out afterwards
/// how much memory the work took, this fixed-capacity buffer allocator records
/// usage figures alongside a sticky record of any raw allocation that ran out
/// of room. It wraps a `FixedBuffer` and records the current bump frontier
/// offset, the peak since the last reset, the high-water mark over its life,
/// and the allocation failure.
///
/// ### Owner stability
/// The instance stays alive at one memory address for as long as any handle
/// from `allocator()` is in use. One instance owns one set of numbers, and the
/// caller takes no copy of it to act as a second allocator over that same
/// state.
pub const Tracked = struct {
    /// The fixed-buffer storage owner whose frontier every other field counts,
    /// maintained by `Tracked`.
    fixed: FixedBuffer,
    /// Furthest the bump frontier has reached in the current interval, which
    /// starts when the instance starts and again at every `reset()`.
    peak_bytes: usize = 0,
    /// Furthest the bump frontier has reached at any point in the life of the
    /// struct, the figure for sizing the buffer. A `reset()` leaves it
    /// standing.
    high_water_bytes: usize = 0,
    /// Set to `true` exactly when `rawAlloc` returns `null` for want of room in
    /// the buffer, separating a buffer too small from work that fits. A failed
    /// `rawResize` or `rawRemap` leaves it alone. Calling `reset()` clears it
    /// to `false`.
    exhausted: bool = false,

    const Self = @This();

    /// A point-in-time snapshot of the numbers a `Tracked` allocator records,
    /// used to read every figure at once as it stood when taken.
    pub const Status = struct {
        /// Current bump frontier offset in bytes, counting the payload and the
        /// alignment padding.
        used_bytes: usize,
        /// Furthest the bump frontier reached in the interval that ends here,
        /// which began at the last reset, or at initialization when there was
        /// none.
        peak_bytes: usize,
        /// Furthest the bump frontier reached at any point, with every reset
        /// behind it counted.
        high_water_bytes: usize,
        /// Indicates whether a raw allocation failure happened since
        /// initialization or the last reset. A failed in-place resize or remap
        /// leaves it unchanged.
        exhausted: bool,
    };

    /// Starts a `Tracked` instance over a byte slice the caller supplies. The
    /// caller keeps ownership of `bytes`. It performs no backing allocation.
    pub fn init(bytes: []u8) Self {
        return .{ .fixed = FixedBuffer.init(bytes) };
    }

    /// Hands the whole buffer back to the next round of work by resetting the
    /// bump frontier, the peak offset, and the exhausted flag. It rewinds the
    /// frontier to zero, sets `peak_bytes` to 0, and sets `exhausted` to
    /// `false`. It leaves `high_water_bytes` standing across resets. Every
    /// active allocation becomes invalid, and the space is available again.
    pub fn reset(self: *Self) void {
        self.fixed.reset();
        self.peak_bytes = 0;
        self.exhausted = false;
    }

    /// Returns a borrowed `std.mem.Allocator` handle pointing at `self` to pass
    /// to code that allocates. The `self` instance stays alive at one memory
    /// address while the handle is in use.
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Returns a snapshot of the current usage numbers by value so a caller can
    /// inspect them. The caller serializes access, because the read is unsafe
    /// while another thread mutates the allocator.
    pub fn status(self: *const Self) Status {
        return .{
            .used_bytes = used(&self.fixed),
            .peak_bytes = self.peak_bytes,
            .high_water_bytes = self.high_water_bytes,
            .exhausted = self.exhausted,
        };
    }

    fn observeUsage(self: *Self) void {
        const used_bytes = used(&self.fixed);
        self.peak_bytes = @max(self.peak_bytes, used_bytes);
        self.high_water_bytes = @max(self.high_water_bytes, used_bytes);
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        const result = self.fixed.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        ) orelse {
            self.exhausted = true;
            return null;
        };
        self.observeUsage();
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
        const resized = self.fixed.allocator().rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
        if (resized) self.observeUsage();
        return resized;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        const result = self.fixed.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
        if (result != null) self.observeUsage();
        return result;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.fixed.allocator().rawFree(
            memory,
            alignment,
            return_address,
        );
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

fn storage(owner: *const FixedBuffer) []u8 {
    return if (comptime observe.enabled)
        owner.inner.buffer
    else
        owner.buffer;
}

fn fits(owner: *const FixedBuffer, len: usize, alignment: Alignment) bool {
    const bytes = storage(owner);
    const unaligned = std.math.add(
        usize,
        @intFromPtr(bytes.ptr),
        used(owner),
    ) catch return false;
    const start = alignment.forward(unaligned) - @intFromPtr(bytes.ptr);
    const end = std.math.add(usize, start, len) catch return false;
    return end <= bytes.len;
}

/// A chunked allocator that builds a result across several allocations and
/// then either commits backing chunks to an outer owner through `retain()` or
/// invokes upstream frees for rollback through `discard()`. It requests
/// chunks from an upstream backing allocator as needed, tracking at most 64
/// chunk descriptors simultaneously in an array fixed at compile time.
/// Initializing an instance performs no initial backing allocation, acquiring
/// chunks only as requests demand them.
///
/// ### Growth schedule and capacity bounds
/// Fresh chunks follow a growth schedule that starts at `initial_capacity`,
/// doubles after each successful fresh chunk, and stops growing at
/// `maximum_capacity`. Each fresh chunk has `@max(scheduled_capacity, len)`
/// bytes, so requests larger than `maximum_capacity` are allowed but need
/// both a free descriptor and a successful backing allocation. Because
/// doubling calculations use the scheduled capacity rather than the actual
/// requested length, oversized requests do not advance the growth progression
/// faster. The `maximum_capacity` parameter caps the growth schedule itself
/// rather than limiting individual request sizes or total storage.
///
/// Calling `retain()` clears this descriptor table without freeing backing
/// memory, so committed chunks no longer occupy slots in the table and more
/// than 64 total chunks can be allocated across successive retain cycles. The
/// upstream lifetime owner must reclaim that committed memory. When an
/// allocation fails, the failure stems either from the backing allocator
/// returning `null` or from exhausting the 64 descriptor slots. Both
/// conditions return an allocation failure to the caller.
///
/// ### Transaction discipline
/// - Calling `retain()` commits every chunk it holds to the backing lifetime
///   owner, such as an enclosing `std.heap.ArenaAllocator`.
/// - Calling `retain()` clears the descriptor tracking without freeing the
///   backing memory.
/// - A chunk that was retained can no longer be freed through
///   `Chunks.discard()`.
/// - Calling `discard()` frees every tracked chunk in reverse order back to the
///   upstream allocator and puts the growth schedule back at
///   `initial_capacity`.
///
/// ### Resize behavior
/// In `rawResize`, shrinking returns `true` at once without consulting the
/// active chunk buffer, leaving the bump frontier where it was. Growing in
/// place looks at the active tail chunk alone, `self.current()`. A slice
/// allocated in an earlier chunk cannot grow in place.
pub const Chunks = struct {
    /// Internal chunk storage holding the buffer descriptors and the growth
    /// state that the methods work through. The owner maintains it, so a caller
    /// accesses storage through `retain` and `discard` and takes no copy of it
    /// and makes no direct changes.
    inner: ChunkStorage,

    const Self = @This();
    /// Number of chunk descriptors tracked at one time, fixed at 64 to cap how
    /// many chunks one instance holds at a time.
    pub const maximum_chunk_count = ChunkStorage.maximum_chunk_count;

    /// Starts a `Chunks` instance to open an allocation transaction over an
    /// allocator the caller already has. It asserts that `initial_capacity > 0`
    /// and that `maximum_capacity >= initial_capacity`. It allocates nothing
    /// here: chunks are requested from the backing allocator as they are
    /// needed.
    pub fn init(
        backing: Allocator,
        initial_capacity: usize,
        maximum_capacity: usize,
    ) Self {
        return .{ .inner = .init(
            backing,
            initial_capacity,
            maximum_capacity,
        ) };
    }

    /// Returns a borrowed `std.mem.Allocator` handle pointing at `self` to pass
    /// to code that allocates. The `self` instance stays alive at one memory
    /// address while the handle is in use.
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Reports whether a given handle came from a `Chunks` instance, allowing a
    /// caller to allocate straight into an open transaction when handed one. It
    /// compares the candidate's vtable pointer against the `Chunks` vtable.
    pub fn isAllocator(candidate: Allocator) bool {
        return candidate.vtable == &vtable;
    }

    /// Commits every tracked chunk to the upstream backing owner and clears
    /// tracking metadata when work succeeds. It sets the chunk descriptor count
    /// to zero without freeing any backing memory. It leaves the current growth
    /// schedule, `next_capacity`, as it is. Once retained, the backing memory
    /// can no longer be freed through `Chunks.discard()`, and reclaiming it
    /// belongs to the upstream backing owner.
    pub fn retain(self: *Self) void {
        self.inner.retain();
    }

    /// Rolls back an uncommitted transaction after failure by freeing all
    /// tracked chunks to the backing allocator in reverse order. This
    /// invalidates any allocations residing in those chunks and resets
    /// `next_capacity` to `initial_capacity`. Chunks committed by an earlier
    /// call to `retain()` are untouched and remain allocated. Actual physical
    /// reuse of the freed memory depends on the free policy of the backing
    /// allocator.
    pub fn discard(self: *Self) void {
        self.inner.discard();
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.inner.allocate(.retained, len, alignment, return_address);
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.inner.resize(memory, alignment, new_len, return_address);
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.inner.remap(
            .retained,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.inner.free(.retained, memory, alignment, return_address);
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

/// `Recycling` reuses memory chunks across repeated workloads to reduce
/// allocation calls to an upstream backing allocator. It tracks the count of
/// outstanding live allocations within each chunk. When deallocations bring
/// the live count of the active tail chunk to zero, that chunk is deactivated
/// and reset for subsequent reuse. Because reusing an inactive chunk requires
/// that its capacity and alignment satisfy the new request, subsequent
/// workloads may still require new backing allocations if existing chunks
/// lack sufficient size or alignment.
///
/// ### Chunk deactivation and reuse constraints
/// - It compacts no holes, so a chunk that sits before the tail and has emptied
///   waits for every chunk behind it to empty too.
/// - Reusing an inactive chunk needs the alignment it was allocated at to meet
///   or exceed the requested alignment, and needs room for the request.
/// - In `rawRemap`, growth that cannot happen in place returns `null`, and a
///   caller going through `std.mem.Allocator.realloc` gets the allocate, copy,
///   and free path, which is how a reallocation crosses chunks.
/// - In `rawResize`, shrinking returns `true` at once and leaves the frontier
///   where it was, and growing in place looks at the active tail chunk alone.
pub const Recycling = struct {
    /// Internal chunk storage holding the buffer descriptors and the live
    /// allocation counts that the methods work through. The owner maintains it,
    /// so a caller accesses storage through `reset` and `discard` and takes no
    /// copy of it and makes no direct changes.
    inner: ChunkStorage,

    const Self = @This();
    /// Ceiling on how many chunks one instance holds at a time, fixed at 64
    /// chunk descriptors and counting the inactive chunks kept for reuse.
    pub const maximum_chunk_count = ChunkStorage.maximum_chunk_count;

    /// Starts a `Recycling` instance over an allocator the caller already has.
    /// It asserts that `initial_capacity > 0` and that
    /// `maximum_capacity >= initial_capacity`. It allocates nothing here: the
    /// first request that needs backing memory takes it.
    pub fn init(
        backing: Allocator,
        initial_capacity: usize,
        maximum_capacity: usize,
    ) Self {
        return .{ .inner = .init(
            backing,
            initial_capacity,
            maximum_capacity,
        ) };
    }

    /// Returns a borrowed `std.mem.Allocator` handle pointing at `self` to pass
    /// to code that allocates. The `self` instance stays alive at one memory
    /// address while the handle is in use.
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Resets every tracked chunk and deactivates them for reuse so the next
    /// round of work can start with the chunks it already has. It rewinds the
    /// bump frontier of every tracked chunk and sets its live allocation count
    /// to zero. The backing memory stays where it is, so later allocations
    /// reuse the existing chunks when the size and the alignment fit. It leaves
    /// `next_capacity` as it is and clears the descriptor exhaustion flag.
    /// Every allocation returned before becomes invalid.
    pub fn reset(self: *Self) void {
        self.inner.reset();
    }

    /// Returns every tracked chunk back to the allocator it came from and
    /// starts the growth schedule over. It frees in reverse order, puts
    /// `next_capacity` back at `initial_capacity`, and clears the descriptor
    /// exhaustion flag.
    pub fn discard(self: *Self) void {
        self.inner.discard();
    }

    /// Reports whether an allocation failed because all 64 chunk descriptors
    /// were taken, helping a caller separate a full descriptor table from an
    /// exhausted backing allocator because the two need different fixes. It
    /// stays set until `reset()` or `discard()`.
    pub fn metadataExhausted(self: *const Self) bool {
        return self.inner.metadata_exhausted;
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.inner.allocate(.recycling, len, alignment, return_address);
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.inner.resize(memory, alignment, new_len, return_address);
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.inner.remap(
            .recycling,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.inner.free(.recycling, memory, alignment, return_address);
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

const ChunkMode = enum {
    retained,
    recycling,
};

const ChunkStorage = struct {
    backing: Allocator,
    initial_capacity: usize,
    maximum_capacity: usize,
    next_capacity: usize,
    chunks: [maximum_chunk_count]Chunk = undefined,
    chunk_count: usize = 0,
    active_indices: [maximum_chunk_count]u8 = undefined,
    active_chunk_count: usize = 0,
    metadata_exhausted: bool = false,

    const Self = @This();
    const maximum_chunk_count = 64;

    const Chunk = struct {
        fixed: FixedBuffer,
        alignment: Alignment,
        live_allocations: usize,
        active: bool,
    };

    fn init(
        backing: Allocator,
        initial_capacity: usize,
        maximum_capacity: usize,
    ) Self {
        std.debug.assert(initial_capacity > 0);
        std.debug.assert(maximum_capacity >= initial_capacity);
        return .{
            .backing = backing,
            .initial_capacity = initial_capacity,
            .maximum_capacity = maximum_capacity,
            .next_capacity = initial_capacity,
        };
    }

    fn reset(self: *Self) void {
        for (self.chunks[0..self.chunk_count]) |*chunk| {
            chunk.fixed.reset();
            chunk.live_allocations = 0;
            chunk.active = false;
        }
        self.active_chunk_count = 0;
        self.metadata_exhausted = false;
    }

    fn retain(self: *Self) void {
        self.chunk_count = 0;
        self.active_chunk_count = 0;
        self.metadata_exhausted = false;
    }

    fn discard(self: *Self) void {
        while (self.chunk_count != 0) {
            self.chunk_count -= 1;
            const chunk = &self.chunks[self.chunk_count];
            self.backing.rawFree(
                storage(&chunk.fixed),
                chunk.alignment,
                @returnAddress(),
            );
        }
        self.active_chunk_count = 0;
        self.next_capacity = self.initial_capacity;
        self.metadata_exhausted = false;
    }

    fn allocate(
        self: *Self,
        mode: ChunkMode,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        if (self.current()) |active| {
            if (fits(&active.fixed, len, alignment)) {
                return allocateFrom(
                    mode,
                    active,
                    len,
                    alignment,
                    return_address,
                ) orelse unreachable;
            }
        }
        if (!self.refill(mode, len, alignment)) return null;
        return allocateFrom(
            mode,
            self.current().?,
            len,
            alignment,
            return_address,
        ) orelse unreachable;
    }

    fn resize(
        self: *Self,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        if (new_len <= memory.len) return true;
        if (self.current()) |active| {
            if (active.fixed.ownsSlice(memory)) {
                return active.fixed.allocator().rawResize(
                    memory,
                    alignment,
                    new_len,
                    return_address,
                );
            }
        }
        return false;
    }

    fn remap(
        self: *Self,
        mode: ChunkMode,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        if (new_len <= memory.len) return memory.ptr;
        if (self.current()) |active| {
            if (active.fixed.ownsSlice(memory)) {
                if (active.fixed.allocator().rawRemap(
                    memory,
                    alignment,
                    new_len,
                    return_address,
                )) |result| return result;
            }
        }
        if (mode == .recycling) return null;
        const result = self.allocate(
            mode,
            new_len,
            alignment,
            return_address,
        ) orelse return null;
        @memcpy(result[0..memory.len], memory);
        return result;
    }

    fn free(
        self: *Self,
        mode: ChunkMode,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        if (mode == .retained) {
            if (self.current()) |active| {
                if (!active.fixed.ownsSlice(memory)) return;
                active.fixed.allocator().rawFree(
                    memory,
                    alignment,
                    return_address,
                );
            }
            return;
        }

        var active_position = self.active_chunk_count;
        while (active_position != 0) {
            active_position -= 1;
            const active_index = self.active_indices[active_position];
            const active = &self.chunks[active_index];
            if (!active.fixed.ownsSlice(memory)) continue;
            std.debug.assert(active.live_allocations > 0);
            active.fixed.allocator().rawFree(
                memory,
                alignment,
                return_address,
            );
            active.live_allocations -= 1;
            self.deactivateEmptyTail();
            return;
        }
    }

    fn current(self: *Self) ?*Chunk {
        if (self.active_chunk_count == 0) return null;
        const active_index = self.active_indices[self.active_chunk_count - 1];
        return &self.chunks[active_index];
    }

    noinline fn refill(
        self: *Self,
        mode: ChunkMode,
        len: usize,
        alignment: Alignment,
    ) bool {
        var retained_index: usize = 0;
        while (retained_index < self.chunk_count) : (retained_index += 1) {
            const retained = &self.chunks[retained_index];
            if (retained.active) continue;
            retained.fixed.reset();
            if (mode == .recycling and
                retained.alignment.toByteUnits() < alignment.toByteUnits())
            {
                continue;
            }
            if (!fits(&retained.fixed, len, alignment)) continue;
            self.activate(retained_index);
            return true;
        }
        if (self.chunk_count == self.chunks.len) {
            if (mode == .recycling) self.metadata_exhausted = true;
            return false;
        }
        const scheduled_capacity = self.next_capacity;
        const capacity = @max(scheduled_capacity, len);
        const chunk_alignment = Alignment.max(alignment, .@"16");
        const pointer = self.backing.rawAlloc(
            capacity,
            chunk_alignment,
            @returnAddress(),
        ) orelse return false;
        const bytes = pointer[0..capacity];
        self.chunks[self.chunk_count] = .{
            .fixed = FixedBuffer.init(bytes),
            .alignment = chunk_alignment,
            .live_allocations = 0,
            .active = false,
        };
        self.chunk_count += 1;
        self.activate(self.chunk_count - 1);
        const doubled = std.math.mul(usize, scheduled_capacity, 2) catch
            std.math.maxInt(usize);
        self.next_capacity = @min(doubled, self.maximum_capacity);
        return true;
    }

    fn activate(self: *Self, chunk_index: usize) void {
        std.debug.assert(chunk_index < self.chunk_count);
        std.debug.assert(!self.chunks[chunk_index].active);
        std.debug.assert(self.chunks[chunk_index].live_allocations == 0);
        std.debug.assert(self.active_chunk_count < self.active_indices.len);
        self.chunks[chunk_index].active = true;
        self.active_indices[self.active_chunk_count] = @intCast(chunk_index);
        self.active_chunk_count += 1;
    }

    fn deactivateEmptyTail(self: *Self) void {
        while (self.current()) |active| {
            if (active.live_allocations != 0) return;
            active.fixed.reset();
            active.active = false;
            self.active_chunk_count -= 1;
        }
    }

    fn allocateFrom(
        mode: ChunkMode,
        chunk: *Chunk,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const result = chunk.fixed.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        ) orelse return null;
        if (mode == .recycling) {
            std.debug.assert(
                chunk.live_allocations < std.math.maxInt(usize),
            );
            chunk.live_allocations += 1;
        }
        return result;
    }
};

/// A stream allocator with a bypass for oversized allocations, used inside an
/// arena that frees everything at once and keeps a large allocation from
/// throwing away the chunk in use. It refills fixed-capacity chunks of
/// `chunk_capacity` bytes from an upstream allocator for ordinary allocations.
/// A request longer than `chunk_capacity` goes straight to the backing
/// allocator, and the active tail chunk stays where it is.
///
/// ### Reclamation and lifetime
/// It keeps metadata for the chunk in `current` alone. It has no `reset`,
/// `deinit`, or `discard` method. The backing allocator, typically an enclosing
/// `std.heap.ArenaAllocator`, reclaims the chunk memory when the owner around
/// it is torn down.
///
/// ### Resize behavior
/// Shrinking returns `true` at once, leaving the frontier where it was. Growing
/// in place looks at `current` alone. Growth returns `false` for memory that
/// sits in an earlier chunk or came from the oversized bypass.
pub const Monotonic = struct {
    /// Upstream allocator that provides the memory for chunks and for oversized
    /// allocations.
    backing: Allocator,
    /// Fixed byte capacity of an ordinary chunk, which sets the length above
    /// which a request bypasses the chunk.
    chunk_capacity: usize,
    /// The fixed buffer chunk in use that ordinary allocations are cut from,
    /// which is `null` before the first allocation.
    current: ?FixedBuffer = null,

    const Self = @This();

    /// Starts a `Monotonic` instance with a fixed chunk size to open a stream
    /// allocator over an arena the caller already has. It asserts that
    /// `chunk_capacity > 0`. It allocates nothing here.
    pub fn init(backing: Allocator, chunk_capacity: usize) Self {
        std.debug.assert(chunk_capacity > 0);
        return .{
            .backing = backing,
            .chunk_capacity = chunk_capacity,
        };
    }

    /// Returns a borrowed `std.mem.Allocator` handle pointing at `self` to pass
    /// to code that allocates. The `self` instance stays alive at one memory
    /// address while the handle is in use.
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Confirms whether a given handle is this instance's backing allocator so
    /// a caller knows the allocator hands memory to the arena expected to free
    /// it. It checks the type-erased state pointer and the vtable pointer,
    /// both.
    pub fn isBackedBy(self: *const Self, candidate: Allocator) bool {
        return self.backing.ptr == candidate.ptr and
            self.backing.vtable == candidate.vtable;
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.current) |*current| {
            if (fits(current, len, alignment)) {
                return current.allocator().rawAlloc(
                    len,
                    alignment,
                    return_address,
                ) orelse unreachable;
            }
        }
        if (len > self.chunk_capacity) {
            return self.backing.rawAlloc(
                len,
                alignment,
                @returnAddress(),
            );
        }
        const chunk_alignment = Alignment.max(alignment, .@"16");
        const pointer = self.backing.rawAlloc(
            self.chunk_capacity,
            chunk_alignment,
            @returnAddress(),
        ) orelse return null;
        self.current = FixedBuffer.init(pointer[0..self.chunk_capacity]);
        return self.current.?.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        ) orelse unreachable;
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        if (new_len <= memory.len) return true;
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.current) |*current| {
            if (current.ownsSlice(memory)) {
                return current.allocator().rawResize(
                    memory,
                    alignment,
                    new_len,
                    return_address,
                );
            }
        }
        return false;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        if (new_len <= memory.len) return memory.ptr;
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.current) |*current| {
            if (current.ownsSlice(memory)) {
                if (current.allocator().rawRemap(
                    memory,
                    alignment,
                    new_len,
                    return_address,
                )) |result| return result;
            }
        }
        const result = rawAlloc(
            self,
            new_len,
            alignment,
            return_address,
        ) orelse return null;
        @memcpy(result[0..memory.len], memory);
        return result;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.current) |*current| {
            if (current.ownsSlice(memory)) {
                current.allocator().rawFree(
                    memory,
                    alignment,
                    return_address,
                );
            }
        }
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

/// A two-tier allocator that serves small work from bytes the caller already
/// has and lets larger work reach the allocator behind it without the caller
/// choosing between them. It serves a request from `fixed` while the room and
/// the alignment fit, and hands the request to `backing` otherwise.
///
/// ### Bounds and provenance routing
/// - The `backing` allocator is any allocator the caller chooses, and
///   `Fallback` adds no memory bound of its own, so a bounded backing allocator
///   bounds the pair.
/// - The `free` operation asks `fixed.ownsSlice(memory)`, and calls
///   `fixed.allocator().rawFree()` for memory the fixed buffer owns and
///   `backing.rawFree()` for the rest.
/// - The `resize` operation tries to grow or shrink in place in the tier that
///   owns the memory.
/// - The `remap` operation on memory that started in `fixed` and cannot be
///   resized in place allocates elsewhere, which may spill to `backing`, copies
///   the bytes over, and frees the old memory from `fixed`, while memory that
///   started in `backing` has its remap handed straight to `backing`.
pub const Fallback = struct {
    /// Primary fixed-buffer storage owner that serves allocation requests
    /// first.
    fixed: FixedBuffer,
    /// Secondary backing allocator that takes requests once the primary fixed
    /// storage cannot fit them.
    backing: Allocator,

    const Self = @This();

    /// Starts a `Fallback` instance over a fixed storage buffer the caller
    /// supplies and a backing allocator.
    pub fn init(storage_bytes: []u8, backing: Allocator) Self {
        return .{
            .fixed = FixedBuffer.init(storage_bytes),
            .backing = backing,
        };
    }

    /// Returns a borrowed `std.mem.Allocator` handle pointing at `self` to pass
    /// to code that allocates. The `self` instance stays alive at one memory
    /// address while the handle is in use.
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        if (fits(&self.fixed, len, alignment)) {
            return self.fixed.allocator().rawAlloc(
                len,
                alignment,
                return_address,
            ) orelse unreachable;
        }
        return self.backing.rawAlloc(
            len,
            alignment,
            return_address,
        );
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.fixed.ownsSlice(memory)) {
            return self.fixed.allocator().rawResize(
                memory,
                alignment,
                new_len,
                return_address,
            );
        }
        return self.backing.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!self.fixed.ownsSlice(memory)) {
            return self.backing.rawRemap(
                memory,
                alignment,
                new_len,
                return_address,
            );
        }
        if (self.fixed.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        )) |result| return result;
        const result = rawAlloc(
            self,
            new_len,
            alignment,
            return_address,
        ) orelse return null;
        @memcpy(result[0..@min(memory.len, new_len)], memory[0..@min(memory.len, new_len)]);
        self.fixed.allocator().rawFree(
            memory,
            alignment,
            return_address,
        );
        return result;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (self.fixed.ownsSlice(memory)) {
            self.fixed.allocator().rawFree(
                memory,
                alignment,
                return_address,
            );
            return;
        }
        self.backing.rawFree(
            memory,
            alignment,
            return_address,
        );
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

/// Stand-in for `FixedBuffer` when the build turns allocation observation on,
/// wrapping `std.heap.FixedBufferAllocator` and publishing an event for every
/// operation to `alloc_observe`.
const ObservedFixedBuffer = struct {
    /// Wrapped standard library fixed buffer allocator performing the work
    /// behind the instrumentation. The owner maintains it, and changing its
    /// fields directly is unsupported.
    inner: std.heap.FixedBufferAllocator,
    /// Producer identity assigned by `alloc_observe.producerId()` to attribute
    /// the events of one session.
    producer_id: u64,

    const Self = @This();

    /// Puts an instrumented allocator over `buffer` and gives it the identity
    /// its events carry for the session.
    pub fn init(buffer: []u8) Self {
        return .{
            .inner = std.heap.FixedBufferAllocator.init(buffer),
            .producer_id = observe.producerId(),
        };
    }

    /// Returns a single-threaded `std.mem.Allocator` handle instrumented with
    /// allocation events.
    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &VTable(false).vtable,
        };
    }

    /// Returns a thread-safe `std.mem.Allocator` handle instrumented with
    /// allocation events so concurrent threads can allocate from one buffer.
    /// The `FixedBufferAllocator` underneath advances the bump frontier with
    /// lock-free compare-and-swap. The instrumented events reach the
    /// observation sink callbacks the build configured, and those callbacks
    /// answer for their own concurrency and locking. A caller keeps concurrent
    /// use apart from `allocator()` and leaves `reset()` alone while
    /// thread-safe operations may be running.
    pub fn threadSafeAllocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &VTable(true).vtable,
        };
    }

    /// Returns `true` when the pointer sits inside the backing buffer, telling
    /// memory from this buffer apart from memory that came from elsewhere.
    pub fn ownsPtr(self: *Self, ptr: [*]u8) bool {
        return self.inner.ownsPtr(ptr);
    }

    /// Returns `true` when the whole slice sits inside the backing buffer,
    /// allowing a caller to route a free or a resize to the tier that owns the
    /// memory.
    pub fn ownsSlice(self: *Self, slice: []u8) bool {
        return self.inner.ownsSlice(slice);
    }

    /// Returns `true` for the allocation that ends exactly at the frontier, the
    /// one made most recently, which is the test for whether an allocation can
    /// grow in place or be freed back. It forwards the standard library's
    /// endpoint check, `buf.ptr + buf.len == buffer.ptr + end_index`. A fresh
    /// allocation always matches `end_index`. It answers `false` for an
    /// allocation that is the most recent live one, once a later aligned
    /// allocation has been freed: that free lowers `end_index` by the payload
    /// length alone and leaves the alignment padding behind, so the earlier
    /// allocation's endpoint ends below `end_index`.
    pub fn isLastAllocation(self: *Self, buffer: []u8) bool {
        return self.inner.isLastAllocation(buffer);
    }

    /// Rewinds the bump frontier to zero to hand the whole buffer back to the
    /// next round of work.
    pub fn reset(self: *Self) void {
        self.inner.reset();
    }

    fn VTable(comptime thread_safe: bool) type {
        return struct {
            const vtable: Allocator.VTable = .{
                .alloc = rawAlloc,
                .resize = rawResize,
                .remap = rawRemap,
                .free = rawFree,
            };

            fn innerAllocator(self: *Self) Allocator {
                return if (thread_safe)
                    self.inner.threadSafeAllocator()
                else
                    self.inner.allocator();
            }

            fn rawAlloc(
                context: *anyopaque,
                len: usize,
                alignment: Alignment,
                return_address: usize,
            ) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(context));
                var span = observe.begin(
                    self.producer_id,
                    .fixed_buffer,
                    .alloc,
                    0,
                    0,
                    len,
                    alignment.toByteUnits(),
                    return_address,
                );
                const result = innerAllocator(self).rawAlloc(
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
                var span = observe.begin(
                    self.producer_id,
                    .fixed_buffer,
                    .resize,
                    @intFromPtr(memory.ptr),
                    memory.len,
                    new_len,
                    alignment.toByteUnits(),
                    return_address,
                );
                const succeeded = innerAllocator(self).rawResize(
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
                var span = observe.begin(
                    self.producer_id,
                    .fixed_buffer,
                    .remap,
                    @intFromPtr(memory.ptr),
                    memory.len,
                    new_len,
                    alignment.toByteUnits(),
                    return_address,
                );
                const result = innerAllocator(self).rawRemap(
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
                var span = observe.begin(
                    self.producer_id,
                    .fixed_buffer,
                    .free,
                    @intFromPtr(memory.ptr),
                    memory.len,
                    0,
                    alignment.toByteUnits(),
                    return_address,
                );
                innerAllocator(self).rawFree(
                    memory,
                    alignment,
                    return_address,
                );
                span.finish(.{
                    .address = @intFromPtr(memory.ptr),
                    .succeeded = true,
                });
            }
        };
    }
};
