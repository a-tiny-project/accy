const std = @import("std");
const adapter = @import("allocator.zig");
const protocol = @import("protocol.zig");

/// A buffer-first allocator type that manages allocations from an initial
/// caller-provided buffer before falling back to a secondary allocator. In
/// disabled builds, this type aliases `std.heap.BufferFirstAllocator`. In
/// enabled builds, it wraps that allocator and exposes only `init` and
/// `allocator`, forwarding allocation calls through an internal
/// `ObservedAllocator` tagged with the `buffer_first` producer kind. The
/// wrapper acts solely as an allocator adapter and adds no lifecycle records.
pub const First = if (protocol.enabled)
    ObservedFirst
else
    std.heap.BufferFirstAllocator;

const ObservedFirst = struct {
    inner: std.heap.BufferFirstAllocator,
    observed: adapter.ObservedAllocator = undefined,
    producer_id: u64,

    const Self = @This();

    /// Initializes the buffer-first allocator by passing the caller-supplied
    /// initial buffer slice and fallback allocator to the underlying
    /// implementation, assigning a unique producer identifier when observation
    /// is enabled. The allocator borrows the buffer without copying or taking
    /// ownership of it. Callers must ensure that both the initial memory buffer
    /// and the fallback allocator remain valid and stable for the entire
    /// operational lifetime of the instance.
    pub fn init(buffer: []u8, fallback: std.mem.Allocator) Self {
        return .{
            .inner = std.heap.BufferFirstAllocator.init(buffer, fallback),
            .producer_id = protocol.producerId(),
        };
    }

    /// Returns a borrowed allocator handle backed by the stable instance. In
    /// enabled builds, this call initializes an embedded adapter pointing to
    /// the underlying buffer-first allocator. The method offers no
    /// thread-safety guarantees for concurrent calls on the same instance, so
    /// callers must serialize access or complete handle creation before
    /// sharing.
    pub fn allocator(self: *Self) std.mem.Allocator {
        self.observed = adapter.ObservedAllocator.init(
            self.inner.allocator(),
            self.producer_id,
            .buffer_first,
        );
        return self.observed.allocator();
    }
};
