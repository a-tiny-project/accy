//! A sequential scope is an allocation owner that groups temporary allocations
//! made during a single operation and releases them together when the operation
//! completes. The scope requires sequential execution and relies on the caller
//! to prevent concurrent access.
//!
//! When serving an allocation request, the scope inspects its existing head
//! node first. If the request fits within the remaining space of that node, the
//! scope advances the head node frontier. If the request exceeds remaining
//! space, the scope attempts to expand the head node in place through
//! `rawResize`, requesting an expanded preferred size before falling back to
//! the exact required size. In-place expansion never relocates previously
//! published allocations.
//!
//! If the head node cannot expand in place, the scope allocates a fresh node
//! from the backing allocator using exact-first growth. Exact-first allocation
//! applies only to fresh nodes, satisfying the tight backing request before
//! requesting spare capacity. The scope requests the exact bytes needed for the
//! node header, requested payload, and alignment slack. If that initial backing
//! allocation succeeds, the scope optionally attempts to stretch the buffer to
//! a larger preferred size through `rawRemap`. Because no pointer has been
//! published from the fresh block yet, `rawRemap` may relocate the buffer to
//! find contiguous capacity. If the backing allocator refuses the remap, the
//! scope retains the successful exact allocation rather than failing the
//! request. A fresh node is not guaranteed to be larger than its predecessor,
//! and physical reclamation of released buffers depends on the child allocator.

const std = @import("std");
const observe = @import("alloc_observe");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// A compile-time alias selecting between ObservedSequentialScope when
/// allocation observation is enabled and UnobservedSequentialScope when
/// disabled. Both implementations provide identical public methods for init,
/// allocator, deinit, and queryCapacity. The type does not expose a reset
/// method, bounding all allocations to a single sequential lifetime ended by
/// calling deinit, which releases every backing node. The implementation is not
/// thread-safe and requires single-threaded access.
pub const SequentialScope = if (observe.enabled)
    ObservedSequentialScope
else
    UnobservedSequentialScope;

/// This allocator manages an intrusive linked list of backing memory buffers
/// supplied by a child allocator, dedicating the head node to the active
/// allocation frontier. The owner serves temporary allocations during a
/// caller-managed sequential lifetime and frees all nodes in reverse order of
/// allocation, newest first, when `deinit` is called. Fresh buffers follow an
/// exact-first growth policy, requesting the exact bytes needed first and
/// optionally attempting to remap to an expanded preferred size before
/// returning a pointer.
///
/// The scope enforces no intrinsic byte or node capacity limit beyond what the
/// backing allocator and address space supply. Each linked node begins with an
/// internal header spanning three `usize` words, enforced by a compile-time
/// assertion, but the struct offers no public guarantee of private field ABI
/// layout.
///
/// For allocation requests, if preferredNodeSize arithmetic overflows, the
/// scope skips that optional expansion attempt, allowing a valid exact
/// allocation to still succeed. A raw allocation request returns null if the
/// required size or alignment cannot be calculated, or if the backing allocator
/// cannot supply the required fresh block after the existing head path is
/// insufficient. High-level allocation then reports error.OutOfMemory. This
/// behavior applies specifically to allocation requests, as resizing or
/// remapping issued slices follows a separate contract.
///
/// An `Allocator` handle borrowed from the scope stores a pointer to this
/// owner, requiring the owner to remain at a stable memory address while that
/// handle is used. Individual `free` and shrink operations reclaim storage only
/// when the target allocation terminates exactly at the head node frontier.
/// Shrinking an earlier allocation succeeds without reclaiming storage,
/// non-tail growth requests return `false`, and alignment gaps remain
/// uncollected until teardown. The raw remap interface mirrors in-place
/// resizing and will not relocate published allocations, whereas higher-level
/// `Allocator.realloc` calls may allocate a new buffer, copy live data, and
/// free the prior allocation. Physical reclamation of freed storage depends on
/// the backing child allocator.
const UnobservedSequentialScope = struct {
    /// The backing `Allocator` handle is stored by value and used to acquire
    /// node blocks, perform in-place resizing, remap fresh allocations, and
    /// release storage. The caller must keep the underlying state owner of the
    /// backing allocator valid through all node operations and teardown through
    /// `deinit`. The caller does not need to maintain the temporary handle
    /// value itself at a stable memory address.
    child: Allocator,
    /// Pointer to the newest node in the linked list, or null when the scope
    /// has allocated no storage. This chain is maintained exclusively by the
    /// scope owner and cannot be copied or shared independently.
    first: ?*Node = null,

    const Self = @This();

    /// Initializes an empty sequential scope over the provided child allocator
    /// without allocating any backing memory blocks up front.
    pub fn init(child: Allocator) Self {
        return .{ .child = child };
    }

    /// Returns a borrowed std.mem.Allocator handle holding a pointer to this
    /// owner. The caller must ensure the scope instance remains alive and
    /// pinned at a stable memory address while the handle is in use.
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Traverses the node list from newest to oldest, recording each node's
    /// successor pointer before calling rawFree on the entire backing
    /// allocation slice including the node header, and sets the head pointer to
    /// null. Calling this method invalidates all memory slices previously
    /// issued by the scope without running individual object destructors.
    /// Physical reclamation of freed blocks depends on the child allocator, and
    /// the teardown process must be performed sequentially.
    pub fn deinit(self: *Self) void {
        var current = self.first;
        while (current) |node| {
            current = node.next;
            self.child.rawFree(
                node.allocatedSlice(),
                .of(Node),
                @returnAddress(),
            );
        }
        self.first = null;
    }

    /// The queryCapacity function sums each held node's payload capacity across
    /// the scope, excluding headers and including unused room and padding. It
    /// does not report live user bytes or represent a memory budget. Addition
    /// overflow saturates to std.math.maxInt(usize), the maximum value
    /// representable by usize. Because this query reads unsynchronized state,
    /// the caller must exclude all concurrent mutation, including allocation,
    /// free, and deinit operations.
    pub fn queryCapacity(self: *const Self) usize {
        var capacity: usize = 0;
        var current = self.first;
        while (current) |node| : (current = node.next) {
            capacity = std.math.add(
                usize,
                capacity,
                node.buffer().len,
            ) catch return std.math.maxInt(usize);
        }
        return capacity;
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        std.debug.assert(len > 0);
        var previous_buffer_len: usize = 0;
        if (self.first) |node| {
            previous_buffer_len = node.buffer().len;
            if (self.allocateFromNode(
                node,
                len,
                alignment,
                return_address,
            )) |result| return result;
        }
        return self.allocateNode(
            len,
            alignment,
            return_address,
            previous_buffer_len,
        );
    }

    /// Attempts to satisfy an allocation request from the existing head node.
    /// It computes the forward-aligned offset of the node's current frontier
    /// and returns a pointer immediately if the requested length fits within
    /// remaining capacity. When the node already has sufficient capacity,
    /// success advances the frontier offset only. When the node lacks
    /// sufficient capacity, it attempts to expand the backing block in place
    /// using `rawResize`, requesting an expanded preferred size first and
    /// falling back to the exact required size on refusal. An existing head
    /// node is never relocated through `rawRemap`. If a backing resize
    /// succeeds, the method updates the node size as well as the frontier. If
    /// both resize attempts are refused, allocation falls back to creating a
    /// fresh node.
    fn allocateFromNode(
        self: *Self,
        node: *Node,
        len: usize,
        alignment: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const buffer = node.buffer();
        const index = alignedIndex(
            buffer.ptr,
            node.end_index,
            alignment,
        ) orelse return null;
        const end = std.math.add(usize, index, len) catch return null;
        if (end <= buffer.len) {
            node.end_index = end;
            return buffer[index..end].ptr;
        }
        const size = std.math.add(usize, @sizeOf(Node), end) catch
            return null;
        const allocated = node.allocatedSlice();
        if (preferredNodeSize(buffer.len, len, alignment)) |preferred_size| {
            std.debug.assert(preferred_size >= size);
            if (preferred_size != size and self.child.rawResize(
                allocated,
                .of(Node),
                preferred_size,
                return_address,
            )) {
                node.size = preferred_size;
                node.end_index = end;
                return node.buffer()[index..end].ptr;
            }
        }
        if (!self.child.rawResize(
            allocated,
            .of(Node),
            size,
            return_address,
        )) return null;
        node.size = size;
        node.end_index = end;
        return node.buffer()[index..end].ptr;
    }

    /// Allocates a fresh node to fulfill a request that cannot fit in the
    /// existing head node. It first computes the exact size needed for the node
    /// header, requested payload length, and conservative alignment slack,
    /// returning null if arithmetic overflows or if the backing allocator's
    /// rawAlloc call fails. Once the exact block is secured, it optionally
    /// invokes rawRemap to expand the block to a preferred size. Unlike
    /// existing nodes whose published pointers prevent memory relocation, a
    /// fresh node has not yet issued any pointers to callers, allowing rawRemap
    /// to relocate the block in search of contiguous storage without breaking
    /// caller references. If remap is refused, the scope retains the original
    /// exact block. The node header is initialized only after the remap attempt
    /// finishes. If subsequent alignment checks or end index additions fail,
    /// the method frees the fresh block and returns null without linking it
    /// into the owner's chain. On complete success, the new node is linked as
    /// the list head and the memory pointer is published to the caller.
    fn allocateNode(
        self: *Self,
        len: usize,
        alignment: Alignment,
        return_address: usize,
        previous_buffer_len: usize,
    ) ?[*]u8 {
        const alignment_bytes = alignment.toByteUnits();
        const slack = if (alignment_bytes <= @alignOf(Node))
            0
        else
            alignment_bytes - 1;
        const payload = std.math.add(usize, len, slack) catch return null;
        const exact_size = std.math.add(usize, @sizeOf(Node), payload) catch
            return null;
        var raw = self.child.rawAlloc(
            exact_size,
            .of(Node),
            return_address,
        ) orelse return null;
        var size = exact_size;
        if (preferredNodeSize(
            previous_buffer_len,
            len,
            alignment,
        )) |preferred_size| {
            std.debug.assert(preferred_size >= exact_size);
            if (preferred_size != exact_size) {
                if (self.child.rawRemap(
                    raw[0..exact_size],
                    .of(Node),
                    preferred_size,
                    return_address,
                )) |preferred| {
                    raw = preferred;
                    size = preferred_size;
                }
            }
        }
        const node: *Node = @ptrCast(@alignCast(raw));
        node.* = .{
            .size = size,
            .end_index = 0,
            .next = self.first,
        };
        const buffer = node.buffer();
        const index = alignedIndex(buffer.ptr, 0, alignment) orelse {
            self.child.rawFree(
                node.allocatedSlice(),
                .of(Node),
                return_address,
            );
            return null;
        };
        const end = std.math.add(usize, index, len) catch {
            self.child.rawFree(
                node.allocatedSlice(),
                .of(Node),
                return_address,
            );
            return null;
        };
        std.debug.assert(end <= buffer.len);
        node.end_index = end;
        self.first = node;
        return buffer[index..end].ptr;
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = alignment;
        _ = return_address;
        std.debug.assert(memory.len > 0);
        std.debug.assert(new_len > 0);
        const node = self.first orelse return false;
        const buffer = node.buffer();
        if (buffer.ptr + node.end_index != memory.ptr + memory.len) {
            return new_len <= memory.len;
        }
        if (new_len <= memory.len) {
            node.end_index -= memory.len - new_len;
            return true;
        }
        const extra = new_len - memory.len;
        if (extra > buffer.len - node.end_index) return false;
        node.end_index += extra;
        return true;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        return if (rawResize(
            context,
            memory,
            alignment,
            new_len,
            return_address,
        )) memory.ptr else null;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = alignment;
        _ = return_address;
        std.debug.assert(memory.len > 0);
        const node = self.first orelse return;
        const buffer = node.buffer();
        if (buffer.ptr + node.end_index != memory.ptr + memory.len) return;
        node.end_index -= memory.len;
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

/// Calculates a preferred target node byte size to amortize future backing
/// allocator requests when growing or allocating a buffer. Let H equal
/// @sizeOf(Node), A represent the requested alignment in bytes, P be the
/// previous head node payload capacity, and L be the requested allocation
/// length. The calculation first computes a baseline biased size X = P + H +
/// A + L + 16 using checked addition. It then computes an expanded size Y = X +
/// floor(X / 2) and rounds Y up to an even byte boundary using Y + (Y & 1),
/// checking each step for integer overflow. If any intermediate addition
/// overflows, the function returns null. Returning null causes the caller to
/// skip the optional expansion attempt and proceed with the valid exact size
/// request rather than aborting the allocation. The actual capacity of the next
/// node is not guaranteed to be 1.5 times the previous node because requests
/// vary in length and backing allocators may refuse optional remap expansions.
fn preferredNodeSize(
    previous_buffer_len: usize,
    len: usize,
    alignment: Alignment,
) ?usize {
    const minimum_with_alignment = std.math.add(
        usize,
        @sizeOf(Node),
        alignment.toByteUnits(),
    ) catch return null;
    const minimum_size = std.math.add(
        usize,
        minimum_with_alignment,
        len,
    ) catch return null;
    const accumulated_size = std.math.add(
        usize,
        previous_buffer_len,
        minimum_size,
    ) catch return null;
    const biased_size = std.math.add(
        usize,
        accumulated_size,
        16,
    ) catch return null;
    const grown_size = std.math.add(
        usize,
        biased_size,
        biased_size / 2,
    ) catch return null;
    return std.math.add(
        usize,
        grown_size,
        grown_size & 1,
    ) catch null;
}

/// Represents an individual node in the scope's intrusive list, owning one
/// backing allocation composed of this header followed immediately by usable
/// payload bytes. Nodes are linked in reverse chronological order from newest
/// to oldest. The header occupies three usize words in the current verified
/// implementation layout, which is asserted at compile time but does not
/// constitute a portable public ABI guarantee. The scope owner maintains this
/// internal state directly, and the structure cannot be cloned or copied
/// independently.
const Node = struct {
    /// The total size in bytes of the backing memory allocation, including both
    /// the node header and its payload space. The scope uses this value when
    /// issuing rawResize and rawFree calls to the child allocator.
    size: usize,
    /// The byte offset within the node payload buffer where the current
    /// allocation frontier stands. This index includes alignment padding
    /// inserted between allocations, and does not represent a sum of surviving
    /// live payload bytes.
    end_index: usize,
    /// Pointer to the next older node in the scope's allocation chain, or null
    /// if this node is the oldest buffer. The scope saves this pointer prior to
    /// freeing the current node during teardown.
    next: ?*Node,

    fn allocatedSlice(self: *Node) []u8 {
        return @as([*]u8, @ptrCast(self))[0..self.size];
    }

    fn buffer(self: *Node) []u8 {
        return self.allocatedSlice()[@sizeOf(Node)..];
    }

    comptime {
        std.debug.assert(@sizeOf(Node) == 3 * @sizeOf(usize));
    }
};

fn alignedIndex(
    buffer: [*]u8,
    end_index: usize,
    alignment: Alignment,
) ?usize {
    const base = @intFromPtr(buffer);
    const address = std.math.add(usize, base, end_index) catch return null;
    const aligned = alignment.forward(address);
    if (aligned < address) return null;
    return aligned - base;
}

/// This wrapper embeds an `UnobservedSequentialScope` and reports logical
/// allocation operations and lifecycle `deinit` events to the `alloc_observe`
/// framework. The wrapper assigns an observation identity derived from a
/// process producer identifier rather than a pointer address. This derivation
/// keeps the identity consistent when the wrapper moves in memory, though
/// moving the wrapper does not repair existing `Allocator` handles that hold
/// the old address. The wrapper stores no generation counter, and `identity()`
/// supplies a literal 0 so all emitted events use generation 0. It requires the
/// caller to avoid concurrent mutation, matching the thread-safety requirements
/// of the underlying scope.
const ObservedSequentialScope = struct {
    /// The underlying unobserved sequential scope that owns node storage and
    /// linked list bookkeeping. Mutating this instance directly bypasses event
    /// emission and lifecycle tracking.
    inner: UnobservedSequentialScope,
    /// The numeric producer identifier assigned at initialization to tag
    /// observed allocation events. This identifier remains stable when the
    /// scope struct is moved in memory, though existing allocator handles are
    /// not retargeted and continue to reference the old address.
    producer_id: u64,

    const Self = @This();

    /// Initializes an empty sequential scope over the provided child allocator
    /// without allocating any backing memory blocks up front.
    pub fn init(child: Allocator) Self {
        return .{
            .inner = .init(child),
            .producer_id = observe.producerId(),
        };
    }

    /// Returns a borrowed std.mem.Allocator handle holding a pointer to this
    /// owner. The caller must ensure the scope instance remains alive and
    /// pinned at a stable memory address while the handle is in use.
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Emits a lifecycle deinit event through the observation framework while
    /// delegating storage reclamation to the inner scope's deinit method. All
    /// allocated blocks are released newest first under the standard sequential
    /// scope teardown policy, invalidating previously issued slices. Because
    /// the scope does not support resets, the event concludes the scope's
    /// single lifetime at generation zero.
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

    /// The queryCapacity function sums each held node's payload capacity across
    /// the scope, excluding headers and including unused room and padding. It
    /// does not report live user bytes or represent a memory budget. Addition
    /// overflow saturates to std.math.maxInt(usize), the maximum value
    /// representable by usize. Because this query reads unsynchronized state,
    /// the caller must exclude all concurrent mutation, including allocation,
    /// free, and deinit operations.
    pub fn queryCapacity(self: *const Self) usize {
        return self.inner.queryCapacity();
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
            .address = if (result) |pointer| @intFromPtr(pointer) else 0,
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
            .address = if (result) |pointer| @intFromPtr(pointer) else 0,
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
            0,
        );
    }
};
