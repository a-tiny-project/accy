//! ## Layered allocation and operation hierarchy
//!
//! Observation of memory behavior across allocator layers needs to distinguish
//! a caller's logical request from the underlying acquisition of backing
//! memory. For example, a high-level allocator such as an arena or memory pool
//! satisfies requests by carving space out of larger regions that it already
//! holds. When an arena exhausts its available capacity, it requests an
//! additional chunk from a backing allocator. In that situation, a single
//! logical allocation at the arena layer can cause a second, nested allocation
//! underneath it.
//!
//! If an observer records only high-level requests, backing chunk acquisitions
//! remain invisible. If an observer records only backing calls, individual
//! logical objects cannot be tracked. Recording both layers without
//! distinguishing their roles can also mislead analysis, because summing
//! requested lengths across both layers as one memory total can count the same
//! storage relationship twice.
//!
//! The package connects instrumented allocators through one shared callback.
//! Within this system, a tracking interval is called a span. A span becomes
//! active only when observation is enabled, not suppressed on this thread, and
//! a sink is installed. Each active span reserves its own operation ID, saves
//! the current thread operation ID as parent, becomes current, and restores the
//! saved parent on finish. It has no duration bound, timeout, or automatic
//! finish.
//!
//! Spans finish in reverse order of their initiation. When an arena allocation
//! triggers a backing allocation, the inner backing operation finishes and
//! delivers its completion notice, or event, before the outer arena operation
//! finishes. Because operation identifiers are reserved at the start of an
//! operation, callback delivery order need not follow increasing identifier
//! order.
//!
//! Thread nesting is strictly local, with no global event ordering or
//! cross-thread context propagation. Callers must finish spans and silent
//! contexts in reverse initiation order on their originating thread. While
//! invoking finish on the same token twice is harmless, copying an active token
//! does not produce independent ownership, so callers must finish only one
//! authoritative token.
//!
//! Callers must not infer physical bytes released, total heap use, or complete
//! process coverage from logical allocation events. A free outcome marked as
//! succeeded indicates that the allocator operation completed, not that backing
//! pages were released to the operating system. An arena or pool can retain
//! freed memory internally for subsequent reuse.
//!
//! In one profiling workload, a `Counts` helper
//! filters only successful `.arena` allocation events, distinguishing root
//! requests with a parent ID of zero from nested arena requests with a non-zero
//! parent ID. In `lib/compiler/choir/src/core/operation/storage.zig`, test assertions
//! confirm that reusing a pool slot emits a logical allocation event even when
//! the pool requires no backing expansion.
//!
//! ## Synchronous notification and `Session` lifecycle
//!
//! Observation connects instrumented allocators to one caller-installed
//! callback. The package records no history itself, owns no event buffer, and
//! provides no export format or capacity policy. Observation relies on a
//! caller-provided destination, or sink, comprising an opaque context pointer
//! and a function pointer accepting an `Event` structure by value. The callback
//! returns `void`. Consequently, error recovery, bounded buffer allocation,
//! sample dropping policies, data aggregation, and thread synchronization
//! belong entirely to the sink implementation.
//!
//! Notification occurs synchronously when an active span finishes. In the
//! provided allocator adapters, the observed memory operation has already
//! returned before event delivery begins. Callback work participates directly
//! in the caller's execution path, without an asynchronous queue. When multiple
//! application threads allocate concurrently, event delivery from different
//! threads can overlap. A single installed sink serves the shared protocol
//! instance.
//!
//! An observation run, or session, borrows the caller's sink and its context
//! pointer. The `install` function registers the sink and returns
//! `error.AlreadyInstalled` if another session is already active. `Sink`
//! storage and callback context memory must remain valid and at stable
//! addresses until `Session.deinit` returns. This lifetime requirement applies
//! immediately during installation, because an emitter on another thread can
//! invoke the callback before `install` returns. Allocators can exist before
//! observation begins, and their subsequent operations are delivered once a
//! sink is active.
//!
//! Tearing down an enabled observation session requires calling
//! `Session.deinit` exactly once. The shutdown sequence first uninstalls the
//! sink and then spins until the shared count of active spans and contexts
//! reaches zero, without providing any timeout or cancellation mechanism.
//! Because outstanding tokens on the thread invoking shutdown cannot finish
//! while that thread spins, callers must finish all thread-local tokens before
//! initiating `deinit`. Callers must also invoke `Session.deinit` outside of
//! active callbacks and suppression scopes to satisfy internal assertions, and
//! without holding locks that concurrent callbacks require to make progress. In
//! addition, callers must serialize the complete shutdown of an old session
//! before installing a new one, as the lifecycle rules do not accommodate
//! overlapping transitions.
//!
//! To prevent infinite recursion, the protocol automatically suppresses
//! observation on the current thread while executing a sink callback. Callers
//! can also initiate manual suppression using `suppress`, which returns a token
//! whose `deinit` restores the previous suppression depth. `Suppression` skips
//! new spans and contexts without preventing the underlying allocation.
//! `Suppression` does not cancel already active spans, mute other threads, or
//! automatically suppress the separate `sys.memory` observer. Spans and
//! contexts initiated when no sink is installed remain inactive.
//!
//! Subsystems can track allocation boundaries through private event
//! representations rather than standard observer events. For example, the
//! `memtrace` tracing allocator assigns an identifier around a backing call but
//! records that boundary inside its own event structure. To accommodate this
//! pattern, `beginContext` reserves an identifier and participates in
//! same-thread nesting without emitting an `Event`. Consequently, a child event
//! may specify a `parent_operation_id` that has no matching event
//! `operation_id` in the observer stream. Downstream consumers can read
//! `Context.id` and `parentId` to connect that externally recorded boundary
//! with nested operations. On any context that was initially active, both
//! stored getter functions remain readable after `finish`.
//!
//! ## Producer `Identity` and lifecycle tracking
//!
//! Correlating allocation activity with specific program components requires
//! stable identifiers that persist across individual operations. The protocol
//! identifies each allocation source through a producer identifier, or producer
//! ID, allocated independently of whether an active observation session exists.
//!
//! When initializing a session, the system records an identifier boundary by
//! sampling the next producer identifier under the same registry lock that
//! serializes `producerId` allocations. Identifiers assigned prior to this
//! boundary fall strictly below the sampled value, whereas identifiers assigned
//! after installation are at or above it. This boundary does not filter
//! incoming events emitted by older producers. Instead, downstream consumers
//! such as `memtrace` use the boundary to qualify histories that may lack
//! allocation records from before observation began. A producer registered at
//! or above the boundary still does not guarantee a complete event history,
//! because active suppression scopes and sink recording policies can omit
//! events.
//!
//! Full emitter identity comprises four components: `producer_id`, a producer
//! kind (`Producer`), a generation number, and an owner cookie. The generation
//! is an owner-supplied lifetime number rather than a counter advanced by this
//! module, and the owner cookie provides an owner-supplied association value.
//! Callers use `beginOwned` to forward these attributes. The protocol forwards
//! owner-supplied values directly without advancing generations or validating
//! lifetime transitions. Standard `begin` calls supply generation zero and
//! cookie zero.
//!
//! The `Identity.movable` helper derives a non-zero owner cookie from a
//! non-zero producer ID rather than an owner memory address, preserving
//! association when the owner struct moves. However, this derivation does not
//! update allocator handles borrowing old owner addresses, and folding 64-bit
//! identifiers into `usize` gives no cookie uniqueness guarantee.
//!
//! Allocator invalidations and teardown phases are communicated through
//! lifecycle spans created via `beginLifecycle`. These spans record events with
//! operations set to `.lifecycle` and capture reasons such as `reset` or
//! `deinit`. The allocator owner supplies the outcome and actual lifetime
//! behavior. For example, the arena allocator wrapper emits a reset lifecycle
//! span using its current generation and increments the generation afterward,
//! even when reset returns false. Callers must not assume every adapter emits
//! lifecycle events, as generic `ObservedAllocator`, `debug.Allocator`, and
//! `buffer.First` do not emit teardown lifecycle records.
//!
//! ## Build configurations and allocator adapters
//!
//! The package module name is `alloc_observe`, an internal implementation
//! package rather than `tiny.alloc_observe`. In standalone builds,
//! `-Denabled=true` chooses the active implementation, which defaults to false.
//! Consumer build scripts across the repository commonly qualify observation
//! with `-Dobserve-allocations=true`, though individual packages do not enable
//! it identically. The test root compiles both enabled and disabled variants in
//! a single invocation.
//!
//! In disabled builds, session installation succeeds as an inert operation,
//! while calls to `begin`, `finish`, and `suppress` perform no work. Internal
//! data structures also adopt different memory layouts compared to enabled
//! builds. State queries reflect this disabled status: `producerId`,
//! `currentOperationId`, and context identifiers evaluate to zero, while
//! `suppressed` returns false. Because generic `ObservedAllocator.init` always
//! asserts a non-zero producer identifier, callers must not invoke it
//! unconditionally with `producerId()` in disabled configurations.
//!
//! An allocator type that tries a supplied buffer, then a fallback allocator,
//! is buffer.First. This buffer stores allocations, not recorded events. When
//! observation is disabled, the type aliases `std.heap.BufferFirstAllocator`,
//! while enabled observation wraps it. To obtain a diagnostic allocator,
//! invoking `debug.Allocator(options)` returns a type with init(backing),
//! allocator(), and deinit(), where deinit returns std.heap.Check. Around
//! backing raw calls, enabled adapters use `ObservedAllocator`, preserve
//! backing outcome, and add no lifetime policy. Allocator handles borrow stable
//! live owners and backing allocators. Sinks called from concurrent threads
//! must synchronize shared state themselves.
//!
//! ## Direct protocol execution
//!
//! Driving spans directly demonstrates how the protocol registers operations,
//! establishes parentage, and delivers completion events.
//!
//! In this test, the operation IDs and producer IDs are real identifiers
//! allocated by the protocol. Only the addresses and lengths are simulated
//! operation data rather than real memory allocations, and callers must never
//! dereference these synthetic addresses.
//!
//! The demonstration runs on a single thread. A local `Recorder` structure
//! provides bounded storage using a fixed array of two events, recording events
//! until capacity is reached and incrementing a dropped counter with saturating
//! addition thereafter. This recorder contains no synchronization. A sink
//! receiving events from concurrent producers requires synchronization to
//! protect its state.
//!
//! ```zig
//! const std = @import("std");
//! const observe = @import("alloc_observe");
//!
//! test "direct protocol event demonstration" {
//!     if (comptime !observe.enabled) return error.SkipZigTest;
//!
//!     const Recorder = struct {
//!         events: [2]observe.Event = undefined,
//!         count: usize = 0,
//!         dropped: usize = 0,
//!
//!         fn record(context: *anyopaque, event: observe.Event) void {
//!             const self: *@This() = @ptrCast(@alignCast(context));
//!             if (self.count < self.events.len) {
//!                 self.events[self.count] = event;
//!                 self.count += 1;
//!             } else {
//!                 self.dropped = self.dropped +| 1;
//!             }
//!         }
//!     };
//!
//!     var recorder = Recorder{};
//!     var sink = observe.Sink{
//!         .context = &recorder,
//!         .record = Recorder.record,
//!     };
//!
//!     var session = try observe.install(&sink);
//!     defer session.deinit();
//!
//!     const arena_id = observe.producerId();
//!     const backing_id = observe.producerId();
//!
//!     var outer = observe.begin(
//!         arena_id,
//!         .arena,
//!         .alloc,
//!         0,
//!         0,
//!         24,
//!         8,
//!         101,
//!     );
//!     defer outer.finish(.{ .address = 0, .succeeded = false });
//!
//!     var inner = observe.begin(
//!         backing_id,
//!         .boundary,
//!         .alloc,
//!         0,
//!         0,
//!         4096,
//!         16,
//!         202,
//!     );
//!     defer inner.finish(.{ .address = 0, .succeeded = false });
//!
//!     inner.finish(.{ .address = 0x2000, .succeeded = true });
//!     outer.finish(.{ .address = 0x2010, .succeeded = true });
//!
//!     try std.testing.expectEqual(@as(usize, 2), recorder.count);
//!     try std.testing.expectEqual(@as(usize, 0), recorder.dropped);
//!     try std.testing.expectEqual(
//!         recorder.events[1].operation_id,
//!         recorder.events[0].parent_operation_id,
//!     );
//!     try std.testing.expectEqual(
//!         @as(u64, 0),
//!         recorder.events[1].parent_operation_id,
//!     );
//!     try std.testing.expectEqual(@as(u64, 0), observe.currentOperationId());
//! }
//! ```

const protocol = @import("protocol.zig");

pub const buffer = @import("buffer.zig");
pub const debug = @import("debug.zig");

/// A generic adapter wrapping a supplied backing allocator, instrumenting
/// allocation, resizing, remapping, and deallocation virtual table calls while
/// returning backing allocator outcomes unchanged. The adapter emits no
/// lifecycle records and enforces no independent memory reclamation policy.
/// Callers must keep both the adapter and its backing allocator at stable
/// memory addresses throughout use, and must ensure the installed sink can
/// handle concurrent invocations when the backing allocator is accessed across
/// multiple threads.
pub const ObservedAllocator = @import("allocator.zig").ObservedAllocator;
/// A compile-time boolean indicating whether allocation observation is active.
/// Build options determine this setting: standalone builds default to `false`
/// unless configured with `-Denabled=true`, while consumers typically
/// forward `-Dobserve-allocations=true` through build scripts. When this flag
/// is `false`, installation succeeds inertly, identifier queries return zero,
/// suppression checks return `false`, and operations such as span tracking or
/// suppression perform no work. Public data structures and types differ in
/// concrete field layout between enabled and disabled builds, so they offer no
/// layout equivalence guarantee across build configurations.
pub const enabled = protocol.enabled;
/// An `Event` is a by-value notification delivered at span finish. This
/// notification conveys caller-supplied data rather than proof of actual
/// storage. Numeric addresses are diagnostic, providing no ownership,
/// capability, or dereference guarantee after an allocation expires. Ordinary
/// spans set lifecycle tags to none.
///
/// The exact fields and their meanings are:
///
/// - `operation_id`: operation identifier assigned at begin.
/// - `parent_operation_id`: identifier of the enclosing span or context on the
///   current thread, or zero if none exists.
/// - `producer_id`: numeric identifier of the producer.
/// - `producer`: kind of producer.
/// - `generation`: owner-supplied lifetime number.
/// - `owner_cookie`: owner association value.
/// - `operation`: executed allocation or lifecycle operation.
/// - `lifecycle_disposition`: lifecycle disposition tag, set to none for
///   ordinary spans.
/// - `lifecycle_reason`: lifecycle reason tag, set to none for ordinary spans.
/// - `address`: result address supplied to finish.
/// - `old_address`: prior address before the operation.
/// - `len`: requested or new length.
/// - `old_len`: prior length before the operation.
/// - `alignment`: alignment in bytes.
/// - `return_address`: caller instruction address.
/// - `succeeded`: producer result flag indicating success or failure.
///
/// When `beginLifecycle` opens a span, it sets old_address, old_len, and len to
/// zero, and alignment to one byte. That initialization does not dictate the
/// final result address supplied to finish. Nested spans on the same thread
/// deliver inner spans before outer spans, so operation identifiers do not
/// increase in delivery order. Concurrent callbacks have no globally serialized
/// order across threads. A silent context reserves an operation identifier but
/// emits no event, so a parent operation identifier can lack a matching event.
pub const Event = protocol.Event;
/// A silent thread-bound nesting token that reserves an operation identifier
/// and participates in thread hierarchy tracking without publishing an event
/// upon completion. An active context updates the thread current operation ID,
/// links to the prior parent, and increments the shared active operation
/// counter. Callers must finish contexts in last-in, first-out order on the
/// originating thread, treating each token as having a single authoritative
/// owner. When observation is disabled, suppressed, or executed without an
/// installed sink, the returned context is inactive and reports an identifier
/// of zero.
pub const Context = protocol.Context;
/// Identifies an allocation source by recording a producer identifier, a
/// producer kind, an owner-supplied generation number, and an owner-supplied
/// cookie value. When observation is enabled, starting a span requires a
/// nonzero producer identifier, and specifying a nonzero generation number
/// requires a nonzero cookie. The observation layer stores and forwards these
/// values as provided by the caller without automatically tracking lifetime
/// state or advancing generation numbers.
pub const Identity = protocol.Identity;
/// Specifies how a lifecycle event affects allocations belonging to the
/// emitting producer: none indicates a standard allocator operation, invalidate
/// marks earlier allocations as having lost validity, and end signals that the
/// producer owner lifetime has completed. The emitting allocator supplies this
/// disposition directly. The observation protocol forwards the value to the
/// installed sink without validating owner state or enforcing lifetime
/// guarantees.
pub const LifecycleDisposition = protocol.LifecycleDisposition;
/// Describes the motive for an allocator lifecycle transition: none, reset,
/// clear_and_free, clear_retaining_current, clear_retaining_largest,
/// clear_retaining_capacity, clear_retaining_capacity_limit, and deinit. Each
/// value represents an owner-supplied description of its action. The
/// enumeration conveys descriptive intent rather than implementing memory
/// retention, so actual buffer preservation or release depends entirely on the
/// owner allocator implementation.
pub const LifecycleReason = protocol.LifecycleReason;
/// Identifies raw allocator virtual table operations (alloc, resize, remap, and
/// free) alongside lifecycle transitions. Values represent logical actions
/// reported by an allocator interface rather than physical memory changes in
/// the operating system. A successful free event records that an allocator
/// finished its logical deallocation procedure, which does not guarantee that
/// underlying virtual address pages or physical bytes were returned to the
/// kernel.
pub const Operation = protocol.Operation;
/// An `Outcome` carries the result of an operation as supplied by the producer.
/// It contains a boolean succeeded flag and a usize address that defaults to
/// zero. This value represents an operation-specific result rather than a
/// simple return without an exception, and it provides no proof of physical
/// reclamation. Within the generic `ObservedAllocator`, a successful allocation
/// or remap produces the resulting address, a successful resize produces the
/// old address, a deallocation produces the old address, and an operation
/// failure produces zero. A caller invoking a lifecycle span may omit the
/// address so that it defaults to zero, but the protocol does not enforce that
/// a lifecycle result address must be zero. The `beginLifecycle` function
/// zeroes the old address and length metadata when opening the span, while
/// finish accepts the address supplied in the final Outcome.
pub const Outcome = protocol.Outcome;
/// Classifies the origin of an observed allocation event through tags: arena,
/// bump, buffer_first, fixed_buffer, debug, pool, process, phase, limit,
/// boundary, sys_memory, and custom. Each tag labels the reporting component
/// rather than guaranteeing how that component manages memory or whether its
/// reported operations cover all process allocations. For instance, an
/// allocator tagged as an arena describes its own interface layer rather than
/// certifying backing page reclamation or absence of uninstrumented memory
/// traffic.
pub const Producer = protocol.Producer;
/// Represents an installed observation interval, managing session duration
/// while borrowing caller-owned sink and context storage. Callers must ensure
/// sink and context storage remain allocated at stable memory addresses
/// throughout the session. The session must be explicitly terminated by calling
/// deinit exactly once, as no automatic teardown is performed on drop. In
/// disabled builds, the session is inert. Callers must serialize session
/// lifecycle transitions externally, because the protocol does not support
/// overlapping the shutdown of an old session with the installation of a new
/// one.
pub const Session = protocol.Session;
/// A delivery target holding a type-erased context pointer and a function
/// pointer that accepts an event by value and returns `void`. Delivery occurs
/// synchronously on the thread finishing an observed span, directly in the
/// caller execution path with no intermediate queue. Because events from
/// distinct threads can arrive concurrently, the callback implementation must
/// synchronize access to shared state. The sink provides no internal buffer,
/// capacity management, dropping strategy, or error reporting mechanism. The
/// caller must guarantee that the `Sink` struct storage itself, the callback
/// context, and the callback code remain stable and valid in memory until
/// session shutdown returns.
pub const Sink = protocol.Sink;
/// A thread-bound tracking token representing an active observation interval.
/// When created while observation is enabled, unsuppressed, and backed by an
/// installed sink, an active span records the current thread parent operation
/// ID, updates the thread current operation ID, increments the active operation
/// count, and captures the sink reference. Active spans must be finished
/// strictly in last-in, first-out order on their originating thread, and each
/// token must be owned and finished by a single authoritative holder. When
/// observation is disabled, suppressed, or running without an installed sink,
/// the token is inert. Concrete field layouts differ between enabled and
/// disabled builds.
pub const Span = protocol.Span;
/// A nesting depth token that suspends the creation of new spans and silent
/// contexts on the current thread while active. `Suppression` does not prevent
/// underlying memory allocations from proceeding, does not mute observation on
/// other threads, and does not cancel or modify spans that were already
/// initiated prior to suppression.
pub const Suppression = protocol.Suppression;

/// Initiates an ordinary observation span with generation and owner cookie
/// defaulted to zero, forwarding previous address, previous length, requested
/// length, byte alignment, and caller return address to the resulting token.
/// When observation is enabled, the caller must supply a nonzero producer
/// identifier even if observation is currently suppressed or no sink is
/// installed. The caller must finish the returned token with an outcome to
/// conclude the operation.
pub const begin = protocol.begin;
/// Reserves an operation identifier and establishes thread nesting without
/// publishing an event when finished. In enabled builds with an installed sink
/// and no active suppression, the context increments the active operation count
/// and links into the thread parent stack. In all other circumstances, it
/// returns an inert token with an identifier of zero. Callers must finish the
/// returned context on its originating thread, as active contexts contribute to
/// the session drain count during shutdown.
pub const beginContext = protocol.beginContext;
/// Initiates a lifecycle observation span for an allocator transition,
/// requiring disposition and reason values other than none even though disabled
/// builds ultimately discard the event. The span records a lifecycle operation
/// kind, sets prior address, prior length, and requested length to zero, sets
/// alignment to one, and forwards the supplied identity and return address. The
/// caller supplies the eventual outcome upon finishing the span. The
/// observation layer records this transition without modifying or managing
/// owner lifetime state.
pub const beginLifecycle = protocol.beginLifecycle;
/// Initiates an ordinary observation span using an explicit caller identity,
/// forwarding prior and requested buffer sizes, addresses, alignment, and
/// return address arguments. In enabled builds, this function asserts identity
/// validity rules by requiring a nonzero producer identifier and requiring a
/// nonzero cookie whenever the generation number is nonzero, but it performs no
/// automatic generation advancement or lifecycle state validation. If
/// observation is suppressed or no sink is present, the function returns an
/// inactive span. In disabled builds, it returns an inert span.
pub const beginOwned = protocol.beginOwned;
/// Returns the operation identifier currently active on the calling thread,
/// which belongs to either an active span or a silent context, or zero if no
/// operation is active or observation is disabled. Active suppression does not
/// clear an already established identifier.
pub const currentOperationId = protocol.currentOperationId;
/// Installs a borrowed sink and context as the active observation target,
/// returning an active session handle. If an enabled sink is already installed,
/// the function returns AlreadyInstalled. In disabled builds, installation
/// succeeds inertly. The caller must guarantee that sink storage and context
/// pointers remain valid and stationary, because registered producers on other
/// threads may deliver callbacks before install returns. The function must be
/// called outside existing callbacks and suppression scopes. Callers must
/// serialize session lifecycles externally, ensuring that prior session
/// teardown completes fully before a new session is installed.
pub const install = protocol.install;
/// Allocates a nonzero, monotonically increasing identifier for an allocator
/// producer when observation is enabled, or returns zero in disabled builds.
/// Identifiers are allocated independently of active sessions, protected by a
/// registry lock that serializes allocation with session floor sampling.
/// Exhaustion of the identifier space causes a panic rather than a recoverable
/// error. Generated values are unique only within the linked module instance,
/// providing no global uniqueness across separate processes or independently
/// loaded module binaries.
pub const producerId = protocol.producerId;
/// Increments the observation suppression depth counter on the current thread,
/// asserting that depth does not overflow an eight-bit integer, and returns a
/// suppression token that decrements the counter upon deinitialization. In
/// disabled builds, the call returns an inert token. Active suppression
/// prevents the creation of new spans and silent contexts on the calling thread
/// without altering spans that are already in progress.
pub const suppress = protocol.suppress;
/// Reports whether observation is currently suspended on the calling thread due
/// to an active callback execution or an explicit suppression scope, returning
/// false in disabled builds. This query reflects thread suppression depth
/// rather than indicating whether a sink is installed.
pub const suppressed = protocol.suppressed;
