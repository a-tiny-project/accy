const std = @import("std");
const adapter = @import("allocator.zig");
const protocol = @import("protocol.zig");

/// A generic debugging allocator type that forwards configured options to
/// `std.heap.DebugAllocator`, providing common `init`, `allocator`, and
/// `deinit` methods in both enabled and disabled builds. Only `deinit` returns
/// `std.heap.Check`. In enabled builds, virtual table operations forward
/// through an embedded adapter tagged with the `debug` producer kind.
/// Observation captures raw allocator virtual table calls only and adds no
/// lifecycle records.
pub fn Allocator(comptime options: std.heap.DebugAllocatorConfig) type {
    return if (protocol.enabled) Observed(options) else Unobserved(options);
}

fn Unobserved(comptime options: std.heap.DebugAllocatorConfig) type {
    return struct {
        inner: std.heap.DebugAllocator(options),

        const Self = @This();

        /// Initializes the underlying debug allocator with the supplied backing
        /// allocator, assigning a producer identifier when observation is
        /// enabled. The constructor forwards configuration options directly to
        /// the underlying implementation without introducing new tracking
        /// policies or altering memory validation behavior.
        pub fn init(backing: std.mem.Allocator) Self {
            return .{ .inner = .{ .backing_allocator = backing } };
        }

        /// Returns an allocator handle borrowing the instance, routing through
        /// an embedded adapter tagged with the debug producer kind when
        /// observation is enabled. The owning instance and its backing
        /// allocator must remain stable and valid throughout use. The method
        /// provides no thread-safety guarantee for concurrent invocations on
        /// the same instance.
        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.inner.allocator();
        }

        /// Deinitializes the underlying debug allocator and returns its
        /// underlying `std.heap.Check` status. Teardown emits no observation
        /// lifecycle events. All standard ownership and lifetime prerequisites
        /// of the underlying debug allocator apply to this call.
        pub fn deinit(self: *Self) std.heap.Check {
            return self.inner.deinit();
        }
    };
}

fn Observed(comptime options: std.heap.DebugAllocatorConfig) type {
    return struct {
        inner: std.heap.DebugAllocator(options),
        observed: adapter.ObservedAllocator = undefined,
        producer_id: u64,

        const Self = @This();

        /// Initializes the underlying debug allocator with the supplied backing
        /// allocator, assigning a producer identifier when observation is
        /// enabled. The constructor forwards configuration options directly to
        /// the underlying implementation without introducing new tracking
        /// policies or altering memory validation behavior.
        pub fn init(backing: std.mem.Allocator) Self {
            return .{
                .inner = .{ .backing_allocator = backing },
                .producer_id = protocol.producerId(),
            };
        }

        /// Returns an allocator handle borrowing the instance, routing through
        /// an embedded adapter tagged with the debug producer kind when
        /// observation is enabled. The owning instance and its backing
        /// allocator must remain stable and valid throughout use. The method
        /// provides no thread-safety guarantee for concurrent invocations on
        /// the same instance.
        pub fn allocator(self: *Self) std.mem.Allocator {
            self.observed = adapter.ObservedAllocator.init(
                self.inner.allocator(),
                self.producer_id,
                .debug,
            );
            return self.observed.allocator();
        }

        /// Deinitializes the underlying debug allocator and returns its
        /// underlying `std.heap.Check` status. Teardown emits no observation
        /// lifecycle events. All standard ownership and lifetime prerequisites
        /// of the underlying debug allocator apply to this call.
        pub fn deinit(self: *Self) std.heap.Check {
            return self.inner.deinit();
        }
    };
}
