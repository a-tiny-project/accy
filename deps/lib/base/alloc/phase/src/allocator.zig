//! ## Package overview
//!
//! Systems programs often need to separate startup storage preparation from
//! subsequent operational work. Preparing a bounded data structure before
//! serving repeated tasks is a motivating case: an owner allocates tables and
//! buffers during startup, after which subsequent service loops must execute
//! without performing unexpected memory allocations. The runtime phase
//! allocators form the lifecycle-enforcement component of `alloc_phase`, which
//! also exports separate capacity declarations and `OneRegion` input storage.
//!
//! ## Storage boundaries and scope
//!
//! A caller places a phase allocator between an owner and a backing memory
//! provider to detect allocator vtable calls routed through the supplied handle
//! after the startup boundary. The guard checks raw calls routed through its
//! own handle and counts violations during forbidden phases. Calls routed
//! through separate allocator handles, global allocators, direct
//! operating-system interfaces, or the internal memory management of the
//! backing allocator sit outside its coverage, because the guard does not
//! provide automatic global interception. High-level zero-length or no-op
//! operations on `std.mem.Allocator` can return before reaching a vtable
//! function, so the wrapper observes only the operations that reach its vtable.
//!
//! The phase guard enforces no startup byte budget and offers no proof that all
//! possible runtime inputs fit within preallocated buffers. Sizing storage and
//! managing overload remain the responsibility of data structure owners and
//! dedicated capacity declarations.
//!
//! ## Lifecycle phases and handle ownership
//!
//! Each phase allocator tracks state through an internal control block
//! allocated from the backing allocator. The control block occupies one of
//! three explicit lifecycle phases: `initialization`, `steady`, or `teardown`.
//!
//! A caller initializes the allocator by invoking `init(backing)`, which
//! allocates a `Control` block from the caller-supplied backing allocator. This
//! call returns `error.OutOfMemory` when the backing allocator cannot satisfy
//! the request. The control block retains the backing allocator and sets all
//! violation counters to zero. While in `initialization`, the caller invokes
//! `initializationAllocator()` to obtain a `std.mem.Allocator` handle.
//!
//! Lifecycle transitions advance in one direction only:
//!
//! - `seal()` moves the allocator from `initialization` to `steady`. This
//!   transition occurs exactly once and cannot be reset.
//! - `beginTeardown()` moves the allocator from `steady` to `teardown`.
//! - `abortInitialization()` moves the allocator from `initialization` directly
//!   to `teardown` when storage preparation encounters an error. Calling
//!   `abortInitialization()` after `seal()` is invalid, and ordinary
//!   `beginTeardown()` cannot substitute for `abortInitialization()` during a
//!   startup failure.
//!
//! Attempting an invalid phase transition, repeating an existing transition,
//! requesting an allocator handle in the wrong phase, or invoking `deinit()`
//! before reaching `teardown` causes an immediate panic in all build modes.
//! Callers inspect the current lifecycle state by calling `phase()` while the
//! control block remains live.
//!
//! When work is complete, invoking `deinit()` requires the phase to be
//! `teardown`. Calling `deinit()` destroys only the `Control` block through the
//! backing allocator and marks the receiver undefined. Entering teardown does
//! not invalidate user allocation contents or free user storage. The phase
//! allocator does not manage user allocation lifetimes, perform automatic bulk
//! cleanup, or run object destructors: callers must explicitly free all user
//! allocations before destroying the control block. The backing allocator
//! remains caller-owned, and the caller must ensure it remains valid and stable
//! throughout the lifespan of the control block and any active allocations.
//!
//! The public wrapper struct stores a pointer to the separately allocated
//! `Control` block. When the wrapper creates a `std.mem.Allocator` handle, the
//! handle's `ptr` field points directly to the `Control` block rather than to
//! the wrapper's local address. Moving or copying the wrapper preserves all
//! existing handles. Copied wrappers act as aliases sharing the underlying
//! phase, counters, and backing allocator. An allocator handle obtained during
//! initialization reads the shared phase on every raw operation, so retaining
//! an earlier handle does not bypass a subsequent seal or teardown. The caller
//! must destroy the shared control block exactly once. Because the control
//! block provides no internal reference counting or protection against repeated
//! deinitialization, all aliases and issued handles must stop being used before
//! `deinit()` runs.
//!
//! ## Raw operations and violation policies
//!
//! A phase violation occurs whenever a raw vtable call arrives during a phase
//! that forbids the requested operation. Violations are recorded regardless of
//! whether the underlying backing allocator would have succeeded.
//!
//! The phase guard defines operation permissions at the raw vtable level:
//!
//! | Operation | Initialization Phase | Steady Phase | Teardown Phase |
//! | :--- | :--- | :--- | :--- |
//! | `alloc` | Permitted | Violation | Violation |
//! | `resize` | Permitted | Violation | Violation |
//! | `remap` | Permitted | Violation | Violation |
//! | `free` | Permitted | Violation | Permitted |
//!
//! An ordinary allocation failure during initialization, such as the backing
//! allocator returning out of memory, is a runtime error rather than a phase
//! violation. During teardown, attempting `alloc`, `resize`, or `remap` counts
//! as a phase violation. This restriction includes shrinking existing
//! allocations: `resize` and `remap` requests remain forbidden during teardown
//! even when requesting a smaller buffer.
//!
//! The package exports two public allocator types with distinct violation
//! policies. `SealedPhaseAllocator` halts execution upon detecting phase
//! misuse: it increments the violation counter and immediately panics before
//! dispatching the call to the backing allocator. It does not return null or
//! `error.OutOfMemory` to recover from a violation.
//!
//! By contrast, `ObservingPhaseAllocator` records unexpected operations while
//! allowing execution to proceed. Upon detecting a violation, it increments the
//! violation counter, attempts to record the return address in an available
//! call site slot, and forwards the operation to the backing allocator,
//! returning the backing allocator's result. That forwarded call can still fail
//! at the backing allocator if backing memory is exhausted. Both wrapper types
//! enforce identical lifecycle transition rules: an invalid transition or
//! premature deinitialization panics immediately under
//! `ObservingPhaseAllocator` just as it does under `SealedPhaseAllocator`.
//!
//! ## Concurrency, observation, and integration patterns
//!
//! Atomic fields govern the internal scalar state of the control block: the
//! phase tag, the four violation counters, and the return address slots each
//! use atomic values. These primitives protect their own scalar values, but
//! they do not make the backing allocator thread-safe or synchronize the
//! broader application lifecycle. The underlying backing allocator must be safe
//! for concurrent dispatch if calls overlap. Because `seal()` updates the phase
//! tag without draining or waiting for in-flight operations, a thread that read
//! the `initialization` phase can still dispatch and complete a backing
//! allocation after another thread has transitioned the state to `steady`. When
//! a strict boundary is required, the caller must coordinate startup completion
//! and phase changes externally. All threads and aliases must reach quiescence
//! before the control block is destroyed.
//!
//! The `violations()` function loads four native atomic counters separately
//! into `u64` snapshot fields `allocations`, `resizes`, `remaps`, and frees.
//! The `total()` method computes their sum using ordinary integer addition.
//! Although individual loads are atomic, concurrent updates can produce a
//! mixture of times across the fields. Callers can stop writers to obtain
//! stable values across the counters.
//!
//! For callers tracking where violations happen, `ObservingPhaseAllocator`
//! records up to 16 distinct nonzero raw return addresses, fixed by
//! `violation_site_capacity`. When additional call sites appear after these 16
//! slots fill, the allocator omits the new addresses while continuing to
//! increment the violation counters. The recorded list provides an
//! arrival-dependent sample of raw addresses rather than stack traces, symbol
//! names, or per-site counts, and concurrent inspection is not frozen during
//! recording. Calling `violationSites()` returns an owned snapshot value. The
//! `slice()` method borrows directly from this snapshot value, meaning the
//! caller must keep the snapshot alive and stable while reading the slice. For
//! `SealedPhaseAllocator`, `violationSites()` returns an empty snapshot because
//! sealed control blocks allocate no site storage. The constant
//! `control_footprint` reports the byte size and alignment of the underlying
//! `Control` block for the target architecture: it does not measure the wrapper
//! struct, total allocator footprint, backing overhead, or startup allocation
//! totals.
//!
//! Three consumers illustrate these patterns:
//!
//! - A language runtime's allocation test initializes
//!   pattern hydration storage through a guarded handle, seals before
//!   exercising hydration, checks for unchanged pointers and zero counters, and
//!   `frees` buffers during teardown before guard deinitialization.
//! - In `lib/testing/hypothesis/src/database.zig`, the test initializes a replay cursor
//!   through `ObservingPhaseAllocator`, seals for iteration, checks for
//!   unchanged buffer pointers and zero violations, and `frees` the cursor
//!   through a teardown handle.
//! - In `lib/base/alloc/src/process.zig`, the consumer selects off, observe, or seal
//!   with the `lib/base/alloc` build option `-Dallocator-phase` and wraps its chosen
//!   process backing allocator. This is not automatic process-wide
//!   interception, since tracking applies only to code routed through the
//!   wrapped instance. The `alloc_phase` observing type keeps counters and
//!   sites independently of `alloc_observe` `Sink` and `Session` callbacks as
//!   well as -Dobserve-allocations.
//!
//! ## Examples
//!
//! The following self-contained examples illustrate phase lifecycle management
//! and violation auditing for pinned Zig version `0.17.0`.
//!
//! ### Sealed phase lifecycle and wrapper aliasing
//!
//! This example demonstrates preparing memory during initialization, aliasing
//! the wrapper, and transitioning to steady state through that alias. The
//! cleanup block aborts initialization on failure, or transitions to teardown,
//! frees user storage through `teardownAllocator()`, and destroys the shared
//! control block.
//!
//! ```zig
//! const std = @import("std");
//! const alloc_phase = @import("alloc_phase");
//!
//! test "sealed phase preparation, wrapper aliasing, and cleanup" {
//!     var guard = try alloc_phase.SealedPhaseAllocator.init(std.testing.allocator);
//!     var memory: ?[]u8 = null;
//!     defer {
//!         switch (guard.phase()) {
//!             .initialization => guard.abortInitialization(),
//!             .steady => guard.beginTeardown(),
//!             .teardown => {},
//!         }
//!         if (memory) |slice| {
//!             guard.teardownAllocator().free(slice);
//!         }
//!         guard.deinit();
//!     }
//!
//!     const init_allocator = guard.initializationAllocator();
//!     const slice = try init_allocator.alloc(u8, 8);
//!     memory = slice;
//!     slice[0] = 42;
//!
//!     var alias = guard;
//!     alias.seal();
//!
//!     try std.testing.expect(guard.phase() == .steady);
//!     try std.testing.expectEqual(@as(u8, 42), memory.?[0]);
//!     try std.testing.expectEqual(@as(u64, 0), guard.violations().total());
//! }
//! ```
//!
//! Invoking `deinit()` on either `guard` or `alias` destroys the underlying
//! `Control` block and marks that wrapper undefined. The copied alias must not
//! be separately deinitialized, and all aliases become unusable once the shared
//! control block is destroyed. Entering teardown does not free user allocations
//! or invalidate their contents: the user slice becomes invalid only after its
//! explicit free through `teardownAllocator().free(slice)`.
//!
//! ### Observing forbidden allocation attempts
//!
//! This example demonstrates an audit with `ObservingPhaseAllocator` when the
//! backing allocator is configured to reject an allocation. The test seals the
//! allocator and calls `rawAlloc` directly, showing that the attempt increments
//! the violation count and forwards to the backing allocator without panicking.
//!
//! ```zig
//! const std = @import("std");
//! const alloc_phase = @import("alloc_phase");
//!
//! test "observing phase counts forbidden attempt when backing allocator rejects" {
//!     var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
//!     var guard = try alloc_phase.ObservingPhaseAllocator.init(backing.allocator());
//!     defer {
//!         switch (guard.phase()) {
//!             .initialization => guard.abortInitialization(),
//!             .steady => guard.beginTeardown(),
//!             .teardown => {},
//!         }
//!         guard.deinit();
//!     }
//!
//!     const allocator = guard.initializationAllocator();
//!     guard.seal();
//!
//!     backing.fail_index = backing.alloc_index;
//!     const result = allocator.rawAlloc(8, .@"1", @returnAddress());
//!     try std.testing.expect(result == null);
//!
//!     const violations = guard.violations();
//!     try std.testing.expectEqual(@as(u64, 1), violations.allocations);
//!     try std.testing.expectEqual(@as(u64, 1), violations.total());
//! }
//! ```
//!
//! Because the backing allocator rejected the call, no user memory was
//! allocated, so no slice cleanup is required.

const std = @import("std");
const capacity = @import("capacity");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Phase = capacity.Phase;

/// Represents a by-value snapshot of four operation counters: allocations,
/// resizes, remaps, and frees. Each field is an unsigned 64-bit integer
/// recording the number of times caller code attempted that raw allocator
/// operation outside the permitted lifecycle phase. These values count
/// attempted operations rather than allocated byte quantities or successful
/// allocations. Because the underlying control block maintains these counts in
/// native atomic variables that are read individually, a snapshot retrieved
/// during concurrent operations does not represent a single coherent point in
/// time across all four fields.
pub const PhaseViolations = struct {
    allocations: u64 = 0,
    resizes: u64 = 0,
    remaps: u64 = 0,
    frees: u64 = 0,

    /// Returns the combined count of allocations, resizes, remaps, and frees as
    /// an unsigned 64-bit integer. The calculation uses standard addition, so
    /// integer overflow follows Zig build safety rules rather than saturating
    /// or reporting an error.
    pub fn total(self: PhaseViolations) u64 {
        return self.allocations + self.resizes + self.remaps + self.frees;
    }
};

/// Defines the fixed capacity of 16 distinct nonzero return addresses recorded
/// by `ObservingPhaseAllocator`. Duplicate call sites do not consume additional
/// slots, and zero addresses are ignored. When new distinct sites arrive after
/// all 16 slots are full, the observing guard omits the new addresses while
/// continuing to increment its violation counters. `SealedPhaseAllocator` does
/// not record return addresses and allocates no site storage.
pub const violation_site_capacity = 16;

/// Represents an owned by-value snapshot of up to 16 distinct nonzero return
/// addresses captured during phase violations. The structure holds raw return
/// addresses and an active count without resolving symbols, capturing full
/// stack traces, or recording per-site occurrence counts. Because concurrent
/// threads race to register unrecorded sites into fixed slots, the retained set
/// reflects arrival order rather than a complete or ordered execution trace.
/// `SealedPhaseAllocator` maintains no site storage and always returns an empty
/// snapshot.
pub const ViolationSites = struct {
    addresses: [violation_site_capacity]usize = @splat(0),
    count: u8 = 0,

    /// Borrows the populated prefix `addresses[0..count]` from this snapshot as
    /// a slice of addresses. The returned slice directly references the memory
    /// of this `ViolationSites` instance rather than the guard control block,
    /// so the caller must keep the snapshot alive and unmoved while using the
    /// slice.
    pub fn slice(self: *const ViolationSites) []const usize {
        return self.addresses[0..self.count];
    }
};

const ViolationBehavior = enum {
    panic,
    record,
    observe,
};

/// Enforces strict lifecycle boundaries around a backing allocator by panicking
/// whenever caller code attempts a raw operation outside the permitted phase.
/// During initialization, the guard permits all four raw operations:
/// allocation, resizing, remapping, and freeing. Once sealed to the steady
/// phase, every raw allocator call is considered a violation: the guard
/// increments the corresponding violation counter and explicitly panics before
/// dispatching to the backing allocator, never returning `error.OutOfMemory` to
/// signal phase errors. During teardown, freeing remains permitted, but
/// allocation, remapping, and resizing are treated as violations and panic,
/// including requests that attempt to shrink existing allocations.
///
/// The guard stores its state in a separately allocated control block, allowing
/// wrapper copies and issued `std.mem.Allocator` handles to share the same
/// lifecycle phase, counters, and backing allocator. Because `Allocator.ptr`
/// references this shared control block directly, moving or copying the wrapper
/// preserves issued handles. Lifecycle transitions occur through explicit calls
/// to `seal`, `abortInitialization`, and `beginTeardown`, and any invalid or
/// duplicate transition panics in all build modes. This guard intercepts only
/// raw calls routed through its own handles: it does not observe global
/// allocator usage, distinct allocator handles, operating system calls, or
/// backing allocator internal operations. It enforces no startup allocation
/// byte budget and provides no guarantee that runtime workloads fit
/// preallocated memory.
pub const SealedPhaseAllocator = PhaseAllocator(.panic);
/// Audits phase compliance across an application lifecycle by recording
/// unauthorized raw operations in local counters and call site slots while
/// forwarding those requests to the backing allocator. When a caller attempts
/// an operation outside the permitted phase, the guard increments the
/// corresponding violation counter, attempts to record the return address in
/// one of 16 call site slots, and forwards the invocation to the backing
/// allocator. If the backing allocator fails the request, the violation counter
/// remains incremented because the attempt itself violated lifecycle rules.
///
/// The guard stores its state in a separately allocated control block, allowing
/// wrapper copies and issued `std.mem.Allocator` handles to share the same
/// lifecycle phase, counters, and backing allocator. This control block
/// includes atomic return address slots, giving it a larger memory footprint
/// than `SealedPhaseAllocator`. The guard enforces the same lifecycle rules as
/// `SealedPhaseAllocator`, so invalid phase transitions, duplicate transitions,
/// handle requests in the wrong phase, and premature deinitialization trigger
/// an explicit panic in all build modes. This mechanism operates entirely
/// through its own allocator handles and functions independently from
/// `alloc_observe` event sessions.
pub const ObservingPhaseAllocator = PhaseAllocator(.observe);

fn PhaseAllocator(comptime behavior: ViolationBehavior) type {
    return struct {
        control: *Control,

        const Self = @This();
        const SiteStorage = if (behavior == .observe)
            [violation_site_capacity]std.atomic.Value(usize)
        else
            void;
        const Control = struct {
            backing: Allocator,
            phase_state: std.atomic.Value(Phase),
            allocation_violations: std.atomic.Value(usize),
            resize_violations: std.atomic.Value(usize),
            remap_violations: std.atomic.Value(usize),
            free_violations: std.atomic.Value(usize),
            violation_sites: SiteStorage,
        };

        /// Provides the compile-time size and alignment of the separately
        /// allocated control block for this guard type on the target
        /// architecture. The control block for `ObservingPhaseAllocator`
        /// contains 16 atomic return address slots, whereas
        /// `SealedPhaseAllocator` omits site storage. This value measures only
        /// the internal control structure itself: it does not reflect the small
        /// wrapper struct, total allocator runtime footprint, backing allocator
        /// bookkeeping overhead, or user storage capacity.
        pub const control_footprint: struct { size: usize, alignment: usize } = .{
            .size = @sizeOf(Control),
            .alignment = @alignOf(Control),
        };

        /// Allocates a shared control block from the backing allocator, sets
        /// the initial phase to initialization, and returns a guard handle. If
        /// the control block allocation fails, the function returns
        /// `error.OutOfMemory` without constructing a guard. Initialization
        /// clears all violation counters, and for `ObservingPhaseAllocator` it
        /// also clears the 16 return address slots. The caller retains
        /// ownership of the backing allocator and must ensure it outlives both
        /// the control block and any active allocations.
        pub fn init(backing: Allocator) Allocator.Error!Self {
            const control = try backing.create(Control);
            control.* = .{
                .backing = backing,
                .phase_state = std.atomic.Value(Phase).init(.initialization),
                .allocation_violations = std.atomic.Value(usize).init(0),
                .resize_violations = std.atomic.Value(usize).init(0),
                .remap_violations = std.atomic.Value(usize).init(0),
                .free_violations = std.atomic.Value(usize).init(0),
                .violation_sites = if (comptime behavior == .observe) @splat(.init(0)) else {},
            };
            return .{ .control = control };
        }

        /// Destroys the shared control block through the backing allocator
        /// after verifying that the guard has reached teardown. Calling this
        /// method outside teardown triggers an explicit panic in all build
        /// modes. Deinitialization destroys only the control block: it does not
        /// free user allocations or run object cleanups, which must be
        /// performed by the caller before deinitialization. Because the control
        /// block provides neither reference counting nor double-free
        /// protection, the caller must ensure that all threads, aliases, and
        /// allocator handles have ceased operations before ending the control
        /// block exactly once. The method sets this wrapper to undefined and
        /// leaves any existing wrapper copies dangling.
        pub fn deinit(self: *Self) void {
            self.requirePhase(.teardown);
            const control = self.control;
            const backing = control.backing;
            self.* = undefined;
            backing.destroy(control);
        }

        /// Returns a `std.mem.Allocator` handle configured for preparation work
        /// during the initialization phase. The method panics explicitly in all
        /// build modes if called when the guard is not in initialization. The
        /// returned handle sets its context pointer directly to the shared
        /// control block, so copying or moving the wrapper preserves handle
        /// validity. Because raw vtable operations read the shared phase state
        /// on each invocation, retaining an initialization handle across a
        /// phase transition does not grant lasting permission to allocate. The
        /// caller must keep both the control block and the backing allocator
        /// live while using the returned handle.
        pub fn initializationAllocator(self: *Self) Allocator {
            self.requirePhase(.initialization);
            return self.allocator();
        }

        /// Transitions the guard atomically from initialization to the steady
        /// phase. The operation succeeds exactly once and panics explicitly in
        /// all build modes if the guard is not in initialization or has already
        /// been sealed. Sealing does not drain or wait for in-flight backing
        /// allocations initiated during startup, does not free acquired
        /// storage, and does not decouple copied wrappers. When application
        /// logic requires an exact boundary between storage setup and steady
        /// execution, the caller must coordinate concurrent threads externally
        /// before invoking this method.
        pub fn seal(self: *Self) void {
            const previous = self.control.phase_state.cmpxchgStrong(
                .initialization,
                .steady,
                .acq_rel,
                .acquire,
            );
            if (previous != null) {
                @panic("sealed phase allocator can only seal initialization");
            }
        }

        /// Transitions the guard atomically from initialization directly to
        /// teardown when preparation fails before sealing. The method panics
        /// explicitly in all build modes if called outside initialization or
        /// after the guard has been sealed. Advancing directly to teardown
        /// enables error recovery, allowing the caller to obtain a teardown
        /// allocator handle and free storage acquired during partial
        /// initialization before calling deinitialization. This transition does
        /// not release user allocations or run object destructors
        /// automatically, leaving resource cleanup to the caller.
        pub fn abortInitialization(self: *Self) void {
            if (self.control.phase_state.cmpxchgStrong(.initialization, .teardown, .acq_rel, .acquire) != null) {
                @panic("sealed phase allocator can only abort initialization");
            }
        }

        /// Transitions a live control block atomically from steady to teardown.
        /// Calling this method from any phase other than steady, or repeating
        /// the transition while the control block is alive, triggers an
        /// explicit panic in all build modes. Failed startup sequences must
        /// call `abortInitialization` instead. During teardown, raw free calls
        /// are permitted, whereas all other raw operations, including shrink
        /// and other resizes, count as phase violations under the chosen guard
        /// policy. The transition does not drain or synchronize concurrent
        /// tasks, so callers must finish all steady-state work externally
        /// before starting teardown.
        pub fn beginTeardown(self: *Self) void {
            if (self.control.phase_state.cmpxchgStrong(.steady, .teardown, .acq_rel, .acquire) != null) {
                @panic("sealed phase allocator teardown is terminal");
            }
        }

        /// Returns a `std.mem.Allocator` handle configured for teardown
        /// operations. The method panics explicitly in all build modes if the
        /// guard has not reached the teardown phase. The returned handle shares
        /// the control block pointer with earlier handles: it dispatches raw
        /// free requests directly to the backing allocator, but treats
        /// allocation, remapping, and resizing as phase violations even when a
        /// resize attempts to shrink memory. The underlying release of backing
        /// storage follows the policies of the backing allocator.
        pub fn teardownAllocator(self: *Self) Allocator {
            self.requirePhase(.teardown);
            return self.allocator();
        }

        /// Reads the current lifecycle phase from a live control block using an
        /// atomic acquire load. This operation provides acquire ordering for
        /// observed state, but it does not wait for in-flight operations to
        /// drain or confirm that concurrent threads have completed a phase. For
        /// example, a thread may read the initialization phase and then
        /// dispatch an allocation after a concurrent transition has already
        /// sealed the allocator.
        pub fn phase(self: *const Self) Phase {
            return self.control.phase_state.load(.acquire);
        }

        /// Loads the four internal violation counters individually with acquire
        /// ordering and returns them as a `PhaseViolations` snapshot. Because
        /// each native atomic counter is read in a separate operation, the
        /// returned values do not form a coherent instantaneous snapshot across
        /// all four fields if allocator calls execute concurrently. The
        /// counters provide neither a reset mechanism nor a saturation policy,
        /// so values increment continuously and can wrap if operations exceed
        /// numeric bounds. To obtain consistent counter readings within their
        /// numeric range, the caller must ensure all mutating threads are
        /// quiescent before inspecting violations.
        pub fn violations(self: *const Self) PhaseViolations {
            return .{
                .allocations = @intCast(self.control.allocation_violations.load(.acquire)),
                .resizes = @intCast(self.control.resize_violations.load(.acquire)),
                .remaps = @intCast(self.control.remap_violations.load(.acquire)),
                .frees = @intCast(self.control.free_violations.load(.acquire)),
            };
        }

        /// Returns an owned by-value `ViolationSites` snapshot containing up to
        /// 16 distinct nonzero return addresses captured during phase
        /// violations. When invoked on `ObservingPhaseAllocator`, the method
        /// scans its internal atomic site slots sequentially. Concurrent writes
        /// can therefore yield a partial view rather than an atomic snapshot of
        /// the entire table. Once all 16 slots are occupied, any new distinct
        /// addresses are omitted from the buffer while violation counters
        /// continue to advance. Calling the method on `SealedPhaseAllocator`
        /// always returns an empty snapshot because sealed allocators allocate
        /// no call site storage.
        pub fn violationSites(self: *const Self) ViolationSites {
            var sites = ViolationSites{};
            if (comptime behavior != .observe) return sites;
            for (&self.control.violation_sites) |*slot| {
                const address = slot.load(.acquire);
                if (address == 0) continue;
                sites.addresses[sites.count] = address;
                sites.count += 1;
            }
            return sites;
        }

        fn allocator(self: *Self) Allocator {
            return .{ .ptr = self.control, .vtable = &vtable };
        }

        fn requirePhase(self: *const Self, expected: Phase) void {
            if (self.phase() != expected) {
                @panic("sealed phase allocator used from the wrong phase");
            }
        }

        fn violation(self: *Self, operation: Operation, return_address: usize) void {
            switch (operation) {
                .allocation => _ = self.control.allocation_violations.fetchAdd(1, .monotonic),
                .resize => _ = self.control.resize_violations.fetchAdd(1, .monotonic),
                .remap => _ = self.control.remap_violations.fetchAdd(1, .monotonic),
                .free => _ = self.control.free_violations.fetchAdd(1, .monotonic),
            }
            self.recordViolationSite(return_address);
            if (comptime behavior == .panic) {
                switch (operation) {
                    .allocation => @panic("allocation attempted during sealed phase"),
                    .resize => @panic("resize attempted during sealed phase"),
                    .remap => @panic("remap attempted during sealed phase"),
                    .free => @panic("free attempted during sealed phase"),
                }
            }
        }

        fn recordViolationSite(self: *Self, return_address: usize) void {
            if (comptime behavior != .observe) return;
            if (return_address == 0) return;
            for (&self.control.violation_sites) |*slot| {
                const existing = slot.load(.acquire);
                if (existing == return_address) return;
                if (existing != 0) continue;
                const raced = slot.cmpxchgStrong(0, return_address, .acq_rel, .acquire) orelse return;
                if (raced == return_address) return;
            }
        }

        fn rawAlloc(
            context: *anyopaque,
            len: usize,
            alignment: Alignment,
            return_address: usize,
        ) ?[*]u8 {
            const control: *Control = @ptrCast(@alignCast(context));
            const self = Self{ .control = control };
            if (self.phase() != .initialization) {
                var mutable = self;
                mutable.violation(.allocation, return_address);
                if (comptime behavior != .observe) return null;
            }
            return control.backing.rawAlloc(len, alignment, return_address);
        }

        fn rawResize(
            context: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            const control: *Control = @ptrCast(@alignCast(context));
            var self = Self{ .control = control };
            if (self.phase() != .initialization) {
                self.violation(.resize, return_address);
                if (comptime behavior != .observe) return false;
            }
            return control.backing.rawResize(memory, alignment, new_len, return_address);
        }

        fn rawRemap(
            context: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            const control: *Control = @ptrCast(@alignCast(context));
            var self = Self{ .control = control };
            if (self.phase() != .initialization) {
                self.violation(.remap, return_address);
                if (comptime behavior != .observe) return null;
            }
            return control.backing.rawRemap(memory, alignment, new_len, return_address);
        }

        fn rawFree(
            context: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            return_address: usize,
        ) void {
            const control: *Control = @ptrCast(@alignCast(context));
            var self = Self{ .control = control };
            const active_phase = self.phase();
            if (active_phase != .initialization and active_phase != .teardown) {
                self.violation(.free, return_address);
                if (comptime behavior != .observe) return;
            }
            control.backing.rawFree(memory, alignment, return_address);
        }

        const Operation = enum {
            allocation,
            resize,
            remap,
            free,
        };

        const vtable: Allocator.VTable = .{
            .alloc = rawAlloc,
            .resize = rawResize,
            .remap = rawRemap,
            .free = rawFree,
        };
    };
}

test "sealed phase allocator permits initialization and terminal teardown" {
    var phase_allocator = try SealedPhaseAllocator.init(std.testing.allocator);
    const initialization_allocator = phase_allocator.initializationAllocator();
    const storage = try initialization_allocator.alloc(u8, 32);

    phase_allocator.seal();
    try std.testing.expectEqual(Phase.steady, phase_allocator.phase());
    try std.testing.expectEqual(@as(u64, 0), phase_allocator.violations().total());

    phase_allocator.beginTeardown();
    phase_allocator.teardownAllocator().free(storage);
    try std.testing.expectEqual(Phase.teardown, phase_allocator.phase());
    try std.testing.expectEqual(@as(u64, 0), phase_allocator.violations().total());
    phase_allocator.deinit();
}

test "sealed phase allocator can terminate failed initialization" {
    var phase_allocator = try SealedPhaseAllocator.init(std.testing.allocator);
    phase_allocator.abortInitialization();
    try std.testing.expectEqual(Phase.teardown, phase_allocator.phase());
    phase_allocator.deinit();
}

test "sealed phase allocator initialization failure is retryable" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        SealedPhaseAllocator.init(failing.allocator()),
    );

    failing.fail_index = std.math.maxInt(usize);
    var phase_allocator = try SealedPhaseAllocator.init(failing.allocator());
    phase_allocator.abortInitialization();
    phase_allocator.deinit();
}

test "sealed phase allocator records and denies every steady allocator operation" {
    const RecordingPhaseAllocator = PhaseAllocator(.record);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var phase_allocator = try RecordingPhaseAllocator.init(backing.allocator());
    const allocator = phase_allocator.initializationAllocator();
    const storage = try allocator.alloc(u8, 32);

    phase_allocator.seal();
    try std.testing.expect(allocator.rawAlloc(8, .@"1", @returnAddress()) == null);
    try std.testing.expect(!allocator.rawResize(storage, .@"1", 16, @returnAddress()));
    try std.testing.expect(allocator.rawRemap(storage, .@"1", 64, @returnAddress()) == null);
    allocator.rawFree(storage, .@"1", @returnAddress());

    try std.testing.expectEqual(PhaseViolations{
        .allocations = 1,
        .resizes = 1,
        .remaps = 1,
        .frees = 1,
    }, phase_allocator.violations());
    try std.testing.expectEqual(@as(usize, 0), backing.deallocations);

    phase_allocator.beginTeardown();
    phase_allocator.teardownAllocator().free(storage);
    try std.testing.expectEqual(@as(usize, 1), backing.deallocations);
    phase_allocator.deinit();
    try std.testing.expectEqual(@as(usize, 2), backing.deallocations);
}

test "copied sealed phase allocator handles share one control block" {
    const RecordingPhaseAllocator = PhaseAllocator(.record);
    var phase_allocator = try RecordingPhaseAllocator.init(std.testing.allocator);
    const allocator = phase_allocator.initializationAllocator();
    const storage = try allocator.alloc(u8, 32);

    var copied = phase_allocator;
    copied.seal();
    try std.testing.expectEqual(Phase.steady, phase_allocator.phase());
    try std.testing.expect(allocator.rawAlloc(8, .@"1", @returnAddress()) == null);
    try std.testing.expectEqual(@as(u64, 1), copied.violations().allocations);

    phase_allocator.beginTeardown();
    copied.teardownAllocator().free(storage);
    phase_allocator.deinit();
}

test "observing phase allocator counts and forwards every steady operation" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var phase_allocator = try ObservingPhaseAllocator.init(backing.allocator());
    const allocator = phase_allocator.initializationAllocator();
    const startup = try allocator.alloc(u8, 32);
    try std.testing.expectEqual(@as(u64, 0), phase_allocator.violations().total());

    phase_allocator.seal();
    const backing_allocations = backing.allocations;
    const steady_raw = allocator.rawAlloc(8, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    var steady: []u8 = steady_raw[0..8];
    try std.testing.expectEqual(backing_allocations + 1, backing.allocations);
    _ = allocator.rawResize(steady, .@"1", 8, @returnAddress());
    if (allocator.rawRemap(steady, .@"1", 8, @returnAddress())) |moved| steady = moved[0..8];
    allocator.rawFree(steady, .@"1", @returnAddress());
    try std.testing.expectEqual(@as(usize, 1), backing.deallocations);
    try std.testing.expectEqual(PhaseViolations{
        .allocations = 1,
        .resizes = 1,
        .remaps = 1,
        .frees = 1,
    }, phase_allocator.violations());

    phase_allocator.beginTeardown();
    phase_allocator.teardownAllocator().free(startup);
    try std.testing.expectEqual(@as(u64, 4), phase_allocator.violations().total());
    try std.testing.expectEqual(@as(usize, 2), backing.deallocations);
    phase_allocator.deinit();
}

test "observing phase allocator attributes violations to bounded distinct sites" {
    var phase_allocator = try ObservingPhaseAllocator.init(std.testing.allocator);
    const allocator = phase_allocator.initializationAllocator();
    phase_allocator.seal();
    try std.testing.expectEqual(@as(u8, 0), phase_allocator.violationSites().count);

    var repeat: u32 = 0;
    while (repeat < 4) : (repeat += 1) {
        const block = allocator.rawAlloc(8, .@"1", @returnAddress()) orelse return error.OutOfMemory;
        allocator.rawFree(block[0..8], .@"1", @returnAddress());
    }

    const sites = phase_allocator.violationSites();
    try std.testing.expect(sites.count >= 1);
    try std.testing.expect(sites.count <= 2);
    for (sites.slice()) |address| {
        try std.testing.expect(address != 0);
    }
    try std.testing.expectEqual(@as(u64, 8), phase_allocator.violations().total());

    phase_allocator.beginTeardown();
    phase_allocator.deinit();
}

test "sealed phase allocator reports no violation sites" {
    const RecordingPhaseAllocator = PhaseAllocator(.record);
    var phase_allocator = try RecordingPhaseAllocator.init(std.testing.allocator);
    const allocator = phase_allocator.initializationAllocator();
    phase_allocator.seal();
    try std.testing.expect(allocator.rawAlloc(8, .@"1", @returnAddress()) == null);
    try std.testing.expectEqual(@as(u8, 0), phase_allocator.violationSites().count);
    phase_allocator.beginTeardown();
    phase_allocator.deinit();
}

test "teardown denies growth operations and permits free" {
    const RecordingPhaseAllocator = PhaseAllocator(.record);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var phase_allocator = try RecordingPhaseAllocator.init(backing.allocator());
    const allocator = phase_allocator.initializationAllocator();
    const storage = try allocator.alloc(u8, 32);

    phase_allocator.seal();
    phase_allocator.beginTeardown();
    const teardown_allocator = phase_allocator.teardownAllocator();
    try std.testing.expect(teardown_allocator.rawAlloc(8, .@"1", @returnAddress()) == null);
    try std.testing.expect(!teardown_allocator.rawResize(storage, .@"1", 16, @returnAddress()));
    try std.testing.expect(teardown_allocator.rawRemap(storage, .@"1", 64, @returnAddress()) == null);
    teardown_allocator.rawFree(storage, .@"1", @returnAddress());

    try std.testing.expectEqual(PhaseViolations{
        .allocations = 1,
        .resizes = 1,
        .remaps = 1,
    }, phase_allocator.violations());
    phase_allocator.deinit();
}
