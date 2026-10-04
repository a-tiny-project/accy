//! ## Package overview
//!
//! When we design a program that obtains storage before executing recurring
//! work, we must answer three separate concerns: which allocator operations
//! still occur during that work, how bounded input can reuse storage, and what
//! capacity or ownership assumptions are declared and structurally checked. The
//! `alloc_phase` package supplies independent tools for those questions:
//! runtime phase allocators, reusable input regions, and compile-time capacity
//! declarations. We can use each tool on its own. None of them provides a
//! universal proof of zero process allocation or bounded latency across an
//! entire program.
//!
//! Within the repository, `alloc_phase` operates as an internal implementation
//! module. It has no public facade export under `tiny`.
//!
//! ## Runtime phase allocators
//!
//! To detect allocator calls that arrive after startup, we wrap a
//! caller-supplied backing allocator in a runtime phase guard:
//! `SealedPhaseAllocator` or `ObservingPhaseAllocator`. Both wrappers manage
//! state through a separately allocated control block, which can itself fail
//! allocation during initialization. The guard enforces operation permissions
//! at the raw vtable boundary. Initialization permits raw allocation, resizing,
//! remapping, and deallocation. Steady state forbids all four operations.
//! Teardown permits deallocation only. Calling `seal` advances the guard from
//! initialization to steady state, `beginTeardown` transitions from steady
//! state to teardown, and `abortInitialization` transitions directly from a
//! failed initialization to teardown. Callers must free all user allocations
//! before calling `deinit`, which destroys the control block.
//!
//! The two runtime wrappers enforce distinct violation policies.
//! `SealedPhaseAllocator` increments a violation counter and panics before
//! calling the backing allocator, and the call is not forwarded. By contrast,
//! `ObservingPhaseAllocator` increments the counter, samples up to 16 distinct
//! nonzero return addresses into fixed slots, and forwards the operation to the
//! backing allocator, returning its result or failure. Neither wrapper
//! intercepts operations routed through other allocator handles or standard
//! library calls that return before entering the vtable. While internal atomic
//! scalars protect phase tags and violation counters, this bookkeeping does not
//! drain concurrent in-flight operations or make an arbitrary backing allocator
//! thread-safe. Callers must synchronize phase boundaries and cleanup
//! externally. For implementation details and API signatures, see
//! [allocator.zig](allocator.zig).
//!
//! ## Bounded reusable input storage
//!
//! For stream and file ingestion, the `input.OneRegion` container configures a
//! single owned, reusable byte slice. To determine whether an incoming payload
//! fits within a configured limit of `n` bytes without allocating a secondary
//! buffer, the standard capacity derivation helper `deriveCapacity` computes
//! `n + 1` bytes using checked addition. If a source yields `n + 1` bytes, the
//! input exceeds the limit and is rejected. While a custom `Capacity.derive`
//! function can describe a larger storage size, the standard helper sizes the
//! requirement to `n + 1`. Calling `init` allocates this buffer from a
//! caller-supplied allocator, `activate` enters steady state, and `deinit`
//! frees the storage using the initialization allocator provided that no borrow
//! remains active. When an input fits within the limit, acquisition grants an
//! exclusive borrow of the slice, which marks the owner busy even when the
//! admitted payload contains zero bytes. Calling `release` clears the busy
//! state so subsequent operations can reuse the buffer. Lifecycle transitions
//! rely on debug assertions instead of explicit panic enforcement, and this
//! owner exposes neither `beginTeardown` nor `abortInitialization`.
//!
//! An input owner responds to oversized inputs according to its overload
//! policy: a recoverable owner increments a rejection counter and preserves
//! storage for subsequent attempts, while a terminal owner latches a terminal
//! flag and blocks all future reads. Because read operations can consume source
//! bytes or modify buffer contents before reporting an error, recovery
//! indicates permission to reuse the buffer for a future request. Stream
//! framing and transaction management sit with the caller. For files,
//! `readFile` reads into the bounded buffer for whole-file admission: if an
//! input exceeds the limit, the reader rejects it after reading a bounded
//! prefix rather than consuming the entire file. When inputs exceed buffer
//! capacity, `readFileWindow` serves bounded portions of larger files. Consumer
//! tools illustrate these boundaries: Glom coordinates windowed reads and
//! parses newline records outside the owner, Issue manages terminal bodies for
//! commands, and Peek decodes image files into external structures using a
//! recoverable buffer. In all cases, the owner manages only its own buffer,
//! leaving decoder, parser, and stream internals to the caller. For the full
//! interface, see [input/root.zig](input/root.zig).
//!
//! ## Capacity declarations and shape verification
//!
//! The `capacity` module describes owner shapes and validates declarations at
//! compile time. It classifies owner shapes along two axes: storage source
//! (allocator-backed versus caller-provisioned) and overload interface (exact
//! versus rejecting). An exact classification indicates only that the validator
//! does not require an Exhaustion declaration, which does not guarantee that
//! workloads will always fit or that all methods will succeed. A rejecting
//! classification requires Owner.Exhaustion to be a finite nonempty error set,
//! and at least one non-lifecycle pointer-receiver owner method must return
//! that set directly or return an error union containing it.
//!
//! A capacity declaration records covered and excluded storage, an expression
//! graph describing sizing formulas, overload policies, risk classifications,
//! obligation keys for external verification, and typed lifecycle bindings. The
//! module also provides checked arithmetic helpers for computing bounds during
//! allocation. Validating a declaration verifies the grammar and type structure
//! of the expression graph: evaluating the formula, proving allocation closure,
//! establishing the truth of bounds, and checking external evidence remain
//! separate verification activities. For the specification grammar and
//! validation rules, see [capacity/root.zig](capacity/root.zig).

const allocator = @import("allocator.zig");

/// Compile-time capacity declarations and owner shape validation. Classifies
/// storage ownership and overload policies, validates declaration structure and
/// expression graph grammar, and registers static claims. See
/// [capacity/root.zig](capacity/root.zig).
pub const capacity = @import("capacity");
/// Bounded reusable input buffer storage (`OneRegion`). Configures a reusable
/// byte buffer, enforces exclusive borrow and release discipline, and provides
/// recoverable or terminal overload options. See
/// [input/root.zig](input/root.zig).
pub const input = @import("input/root.zig");
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
pub const ObservingPhaseAllocator = allocator.ObservingPhaseAllocator;
/// Represents a by-value snapshot of four operation counters: allocations,
/// resizes, remaps, and frees. Each field is an unsigned 64-bit integer
/// recording the number of times caller code attempted that raw allocator
/// operation outside the permitted lifecycle phase. These values count
/// attempted operations rather than allocated byte quantities or successful
/// allocations. Because the underlying control block maintains these counts in
/// native atomic variables that are read individually, a snapshot retrieved
/// during concurrent operations does not represent a single coherent point in
/// time across all four fields.
pub const PhaseViolations = allocator.PhaseViolations;
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
pub const SealedPhaseAllocator = allocator.SealedPhaseAllocator;
/// Represents an owned by-value snapshot of up to 16 distinct nonzero return
/// addresses captured during phase violations. The structure holds raw return
/// addresses and an active count without resolving symbols, capturing full
/// stack traces, or recording per-site occurrence counts. Because concurrent
/// threads race to register unrecorded sites into fixed slots, the retained set
/// reflects arrival order rather than a complete or ordered execution trace.
/// `SealedPhaseAllocator` maintains no site storage and always returns an empty
/// snapshot.
pub const ViolationSites = allocator.ViolationSites;
/// Defines the fixed capacity of 16 distinct nonzero return addresses recorded
/// by `ObservingPhaseAllocator`. Duplicate call sites do not consume additional
/// slots, and zero addresses are ignored. When new distinct sites arrive after
/// all 16 slots are full, the observing guard omits the new addresses while
/// continuing to increment its violation counters. `SealedPhaseAllocator` does
/// not record return addresses and allocates no site storage.
pub const violation_site_capacity = allocator.violation_site_capacity;
