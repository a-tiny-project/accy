const std = @import("std");
const build_options = @import("build_options");
const Channel = @import("alloc_observe_channel").Channel(Event);

/// A compile-time boolean indicating whether allocation observation is active.
/// Build options determine this setting: standalone builds default to `false`
/// unless configured with `-Denabled=true`, while consumers typically
/// forward `-Dobserve-allocations=true` through build scripts. When this flag
/// is `false`, installation succeeds inertly, identifier queries return zero,
/// suppression checks return `false`, and operations such as span tracking or
/// suppression perform no work. Public data structures and types differ in
/// concrete field layout between enabled and disabled builds, so they offer no
/// layout equivalence guarantee across build configurations.
pub const enabled: bool = build_options.allocation_observation_enabled;

/// Classifies the origin of an observed allocation event through tags: arena,
/// bump, buffer_first, fixed_buffer, debug, pool, process, phase, limit,
/// boundary, sys_memory, and custom. Each tag labels the reporting component
/// rather than guaranteeing how that component manages memory or whether its
/// reported operations cover all process allocations. For instance, an
/// allocator tagged as an arena describes its own interface layer rather than
/// certifying backing page reclamation or absence of uninstrumented memory
/// traffic.
pub const Producer = enum(u8) {
    arena,
    bump,
    buffer_first,
    fixed_buffer,
    debug,
    pool,
    process,
    phase,
    limit,
    boundary,
    sys_memory,
    custom,
};

/// Identifies raw allocator virtual table operations (alloc, resize, remap, and
/// free) alongside lifecycle transitions. Values represent logical actions
/// reported by an allocator interface rather than physical memory changes in
/// the operating system. A successful free event records that an allocator
/// finished its logical deallocation procedure, which does not guarantee that
/// underlying virtual address pages or physical bytes were returned to the
/// kernel.
pub const Operation = enum(u8) {
    alloc,
    resize,
    remap,
    free,
    lifecycle,
};

/// Specifies how a lifecycle event affects allocations belonging to the
/// emitting producer: none indicates a standard allocator operation, invalidate
/// marks earlier allocations as having lost validity, and end signals that the
/// producer owner lifetime has completed. The emitting allocator supplies this
/// disposition directly. The observation protocol forwards the value to the
/// installed sink without validating owner state or enforcing lifetime
/// guarantees.
pub const LifecycleDisposition = enum(u8) {
    none,
    invalidate,
    end,
};

/// Describes the motive for an allocator lifecycle transition: none, reset,
/// clear_and_free, clear_retaining_current, clear_retaining_largest,
/// clear_retaining_capacity, clear_retaining_capacity_limit, and deinit. Each
/// value represents an owner-supplied description of its action. The
/// enumeration conveys descriptive intent rather than implementing memory
/// retention, so actual buffer preservation or release depends entirely on the
/// owner allocator implementation.
pub const LifecycleReason = enum(u8) {
    none,
    reset,
    clear_and_free,
    clear_retaining_current,
    clear_retaining_largest,
    clear_retaining_capacity,
    clear_retaining_capacity_limit,
    deinit,
};

/// Identifies an allocation source by recording a producer identifier, a
/// producer kind, an owner-supplied generation number, and an owner-supplied
/// cookie value. When observation is enabled, starting a span requires a
/// nonzero producer identifier, and specifying a nonzero generation number
/// requires a nonzero cookie. The observation layer stores and forwards these
/// values as provided by the caller without automatically tracking lifetime
/// state or advancing generation numbers.
pub const Identity = struct {
    producer_id: u64,
    producer: Producer,
    generation: u64,
    owner_cookie: usize,

    /// Derives an identity whose cookie is computed from a nonzero producer
    /// identifier rather than a memory address. The constructor requires a
    /// nonzero producer identifier, folds the identifier into a `usize` by
    /// XORing the high word on narrower targets and truncating, and substitutes
    /// one whenever the folded result is zero. Deriving the cookie from an
    /// identifier allows owner structs to move in memory without altering their
    /// identity. This derivation does not guarantee collision-free cookie
    /// values and does not update existing allocator handles that continue to
    /// borrow old owner addresses.
    pub fn movable(
        producer_id: u64,
        producer: Producer,
        generation: u64,
    ) Identity {
        std.debug.assert(producer_id != 0);
        const folded = if (comptime @bitSizeOf(usize) < @bitSizeOf(u64))
            producer_id ^ (producer_id >> @bitSizeOf(usize))
        else
            producer_id;
        const cookie: usize = @truncate(folded);
        return .{
            .producer_id = producer_id,
            .producer = producer,
            .generation = generation,
            .owner_cookie = if (cookie == 0) 1 else cookie,
        };
    }
};

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
pub const Outcome = struct {
    address: usize = 0,
    succeeded: bool,
};

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
pub const Event = struct {
    operation_id: u64,
    parent_operation_id: u64,
    producer_id: u64,
    producer: Producer,
    generation: u64,
    owner_cookie: usize,
    operation: Operation,
    lifecycle_disposition: LifecycleDisposition,
    lifecycle_reason: LifecycleReason,
    address: usize,
    old_address: usize,
    len: usize,
    old_len: usize,
    alignment: usize,
    return_address: usize,
    succeeded: bool,
};

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
pub const Sink = Channel.Sink;

const EnabledSpan = struct {
    sink: *const Sink,
    operation_id: u64,
    parent_operation_id: u64,
    producer_id: u64,
    producer: Producer,
    generation: u64,
    owner_cookie: usize,
    operation: Operation,
    lifecycle_disposition: LifecycleDisposition,
    lifecycle_reason: LifecycleReason,
    old_address: usize,
    old_len: usize,
    len: usize,
    alignment: usize,
    return_address: usize,
    active: bool = true,

    /// An inactive or disabled token does nothing when finish is called. An
    /// active token must finish on its originating thread in reverse nesting
    /// order. Completes the observed span and delivers an event carrying the
    /// supplied outcome to the sink captured at initiation. During delivery,
    /// observation is automatically suppressed on the calling thread to prevent
    /// recursive callbacks. Once delivery concludes, this method restores the
    /// previous thread parent operation ID and decrements the shared active
    /// operation counter. Repeated calls on the same token after finish do
    /// nothing, and a copied active token is not independently finishable.
    /// Callers must finish all same-thread tokens before `Session.deinit`,
    /// because shutdown cannot progress while active tokens remain.
    pub fn finish(self: *EnabledSpan, outcome: Outcome) void {
        if (!self.active) return;
        std.debug.assert(self.active);
        std.debug.assert(current_operation_id == self.operation_id);
        Channel.deliver(self.sink, .{
            .operation_id = self.operation_id,
            .parent_operation_id = self.parent_operation_id,
            .producer_id = self.producer_id,
            .producer = self.producer,
            .generation = self.generation,
            .owner_cookie = self.owner_cookie,
            .operation = self.operation,
            .lifecycle_disposition = self.lifecycle_disposition,
            .lifecycle_reason = self.lifecycle_reason,
            .address = outcome.address,
            .old_address = self.old_address,
            .len = self.len,
            .old_len = self.old_len,
            .alignment = self.alignment,
            .return_address = self.return_address,
            .succeeded = outcome.succeeded,
        });
        current_operation_id = self.parent_operation_id;
        self.active = false;
        Channel.release();
    }
};

const DisabledSpan = struct {
    /// An inactive or disabled token does nothing when finish is called. An
    /// active token must finish on its originating thread in reverse nesting
    /// order. Completes the observed span and delivers an event carrying the
    /// supplied outcome to the sink captured at initiation. During delivery,
    /// observation is automatically suppressed on the calling thread to prevent
    /// recursive callbacks. Once delivery concludes, this method restores the
    /// previous thread parent operation ID and decrements the shared active
    /// operation counter. Repeated calls on the same token after finish do
    /// nothing, and a copied active token is not independently finishable.
    /// Callers must finish all same-thread tokens before `Session.deinit`,
    /// because shutdown cannot progress while active tokens remain.
    pub inline fn finish(_: *DisabledSpan, outcome: Outcome) void {
        _ = outcome;
    }
};

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
pub const Span = if (enabled) EnabledSpan else DisabledSpan;

const EnabledContext = struct {
    operation_id: u64,
    parent_operation_id: u64,
    active: bool = true,

    /// Returns the stored operation identifier for this context, which remains
    /// readable after `finish` marks the context inactive. This method returns
    /// zero only if the context was created inactive or allocation observation
    /// is disabled.
    pub fn id(self: EnabledContext) u64 {
        return self.operation_id;
    }

    /// Returns the parent operation identifier active on the originating thread
    /// when this context began, which remains readable after `finish` marks the
    /// context inactive. This method returns zero if no parent operation was
    /// active at creation, the context was created inactive, or allocation
    /// observation is disabled.
    pub fn parentId(self: EnabledContext) u64 {
        return self.parent_operation_id;
    }

    /// Concludes the silent context, restoring the enclosing parent operation
    /// identifier on the originating thread and decrementing the shared active
    /// operation count without delivering an event. Tokens must be finished in
    /// reverse order of creation on their originating thread. Calling finish
    /// more than once on the same token is safe and produces no further state
    /// changes, but copies of an active token must not be finished
    /// independently.
    pub fn finish(self: *EnabledContext) void {
        if (!self.active) return;
        std.debug.assert(current_operation_id == self.operation_id);
        current_operation_id = self.parent_operation_id;
        self.active = false;
        Channel.release();
    }
};

const DisabledContext = struct {
    /// Returns the stored operation identifier for this context, which remains
    /// readable after `finish` marks the context inactive. This method returns
    /// zero only if the context was created inactive or allocation observation
    /// is disabled.
    pub inline fn id(_: DisabledContext) u64 {
        return 0;
    }

    /// Returns the parent operation identifier active on the originating thread
    /// when this context began, which remains readable after `finish` marks the
    /// context inactive. This method returns zero if no parent operation was
    /// active at creation, the context was created inactive, or allocation
    /// observation is disabled.
    pub inline fn parentId(_: DisabledContext) u64 {
        return 0;
    }

    /// Concludes the silent context, restoring the enclosing parent operation
    /// identifier on the originating thread and decrementing the shared active
    /// operation count without delivering an event. Tokens must be finished in
    /// reverse order of creation on their originating thread. Calling finish
    /// more than once on the same token is safe and produces no further state
    /// changes, but copies of an active token must not be finished
    /// independently.
    pub inline fn finish(_: *DisabledContext) void {}
};

/// A silent thread-bound nesting token that reserves an operation identifier
/// and participates in thread hierarchy tracking without publishing an event
/// upon completion. An active context updates the thread current operation ID,
/// links to the prior parent, and increments the shared active operation
/// counter. Callers must finish contexts in last-in, first-out order on the
/// originating thread, treating each token as having a single authoritative
/// owner. When observation is disabled, suppressed, or executed without an
/// installed sink, the returned context is inactive and reports an identifier
/// of zero.
pub const Context = if (enabled) EnabledContext else DisabledContext;

const DisabledSuppression = struct {
    /// Restores observation depth by decrementing the current thread
    /// suppression counter by one level. The token must be deinitialized on its
    /// originating thread. Calling this method repeatedly on the same token is
    /// an idempotent no-op after the first invocation, but duplicate copies of
    /// an active token must not be deinitialized independently.
    pub inline fn deinit(_: *DisabledSuppression) void {}
};

/// A nesting depth token that suspends the creation of new spans and silent
/// contexts on the current thread while active. `Suppression` does not prevent
/// underlying memory allocations from proceeding, does not mute observation on
/// other threads, and does not cancel or modify spans that were already
/// initiated prior to suppression.
pub const Suppression = if (enabled)
    Channel.Suppression
else
    DisabledSuppression;

/// Represents an installed observation interval, managing session duration
/// while borrowing caller-owned sink and context storage. Callers must ensure
/// sink and context storage remain allocated at stable memory addresses
/// throughout the session. The session must be explicitly terminated by calling
/// deinit exactly once, as no automatic teardown is performed on drop. In
/// disabled builds, the session is inert. Callers must serialize session
/// lifecycle transitions externally, because the protocol does not support
/// overlapping the shutdown of an old session with the installation of a new
/// one.
pub const Session = struct {
    channel: if (enabled) Channel.Session else void =
        if (enabled) .{} else {},
    producer_id_floor: if (enabled) u64 else void =
        if (enabled) 0 else {},

    /// Terminates an active session by unregistering the sink and spinning
    /// until the shared count of active spans and contexts drains to zero. The
    /// spin loop contains no timeout or cancellation path, requiring all
    /// concurrent operations to finish. Callers must invoke deinit outside
    /// callbacks and outside active suppression scopes (which trigger
    /// assertions if violated), and must ensure no outstanding spans or
    /// contexts remain open on the calling thread, or shutdown will spin
    /// indefinitely. Callers must also avoid holding locks required by
    /// in-flight callbacks. `Sink` memory and callback context pointers must
    /// remain valid and stable until this function returns. An enabled session
    /// must be deinitialized exactly once. In disabled builds, this call is an
    /// inert no-op.
    pub fn deinit(self: *Session) void {
        if (comptime !enabled) return;
        self.channel.deinit();
    }

    /// Reports the next producer identifier captured during session
    /// installation under the registry lock, or zero when observation is
    /// disabled. This boundary value separates producers registered prior to
    /// installation from those registered subsequently. Falling at or above
    /// this threshold indicates registration after the session began, but does
    /// not prove that an emitter event history is complete, because thread
    /// suppression or incomplete sink coverage may have omitted events.
    pub fn producerIdFloor(self: *const Session) u64 {
        if (comptime !enabled) return 0;
        return self.producer_id_floor;
    }
};

var next_operation_id = std.atomic.Value(u64).init(1);
var next_producer_id = std.atomic.Value(u64).init(1);
var producer_registry_lock: std.atomic.Mutex = .unlocked;
threadlocal var current_operation_id: u64 = 0;

/// Installs a borrowed sink and context as the active observation target,
/// returning an active session handle. If an enabled sink is already installed,
/// the function returns AlreadyInstalled. In disabled builds, installation
/// succeeds inertly. The caller must guarantee that sink storage and context
/// pointers remain valid and stationary, because registered producers on other
/// threads may deliver callbacks before install returns. The function must be
/// called outside existing callbacks and suppression scopes. Callers must
/// serialize session lifecycles externally, ensuring that prior session
/// teardown completes fully before a new session is installed.
pub fn install(sink: *const Sink) error{AlreadyInstalled}!Session {
    if (comptime !enabled) {
        return .{};
    }
    lockProducerRegistry();
    defer producer_registry_lock.unlock();
    const producer_id_floor = next_producer_id.load(.acquire);
    return .{
        .channel = try Channel.install(sink),
        .producer_id_floor = producer_id_floor,
    };
}

/// Allocates a nonzero, monotonically increasing identifier for an allocator
/// producer when observation is enabled, or returns zero in disabled builds.
/// Identifiers are allocated independently of active sessions, protected by a
/// registry lock that serializes allocation with session floor sampling.
/// Exhaustion of the identifier space causes a panic rather than a recoverable
/// error. Generated values are unique only within the linked module instance,
/// providing no global uniqueness across separate processes or independently
/// loaded module binaries.
pub inline fn producerId() u64 {
    if (comptime !enabled) return 0;
    lockProducerRegistry();
    defer producer_registry_lock.unlock();
    return takeId(&next_producer_id);
}

/// Returns the operation identifier currently active on the calling thread,
/// which belongs to either an active span or a silent context, or zero if no
/// operation is active or observation is disabled. Active suppression does not
/// clear an already established identifier.
pub inline fn currentOperationId() u64 {
    if (comptime !enabled) return 0;
    return current_operation_id;
}

/// Reports whether observation is currently suspended on the calling thread due
/// to an active callback execution or an explicit suppression scope, returning
/// false in disabled builds. This query reflects thread suppression depth
/// rather than indicating whether a sink is installed.
pub inline fn suppressed() bool {
    if (comptime !enabled) return false;
    return Channel.suppressed();
}

/// Initiates an ordinary observation span with generation and owner cookie
/// defaulted to zero, forwarding previous address, previous length, requested
/// length, byte alignment, and caller return address to the resulting token.
/// When observation is enabled, the caller must supply a nonzero producer
/// identifier even if observation is currently suppressed or no sink is
/// installed. The caller must finish the returned token with an outcome to
/// conclude the operation.
pub inline fn begin(
    producer_id: u64,
    producer: Producer,
    operation: Operation,
    old_address: usize,
    old_len: usize,
    len: usize,
    alignment: usize,
    return_address: usize,
) Span {
    return beginOwned(
        .{
            .producer_id = producer_id,
            .producer = producer,
            .generation = 0,
            .owner_cookie = 0,
        },
        operation,
        old_address,
        old_len,
        len,
        alignment,
        return_address,
    );
}

/// Initiates an ordinary observation span using an explicit caller identity,
/// forwarding prior and requested buffer sizes, addresses, alignment, and
/// return address arguments. In enabled builds, this function asserts identity
/// validity rules by requiring a nonzero producer identifier and requiring a
/// nonzero cookie whenever the generation number is nonzero, but it performs no
/// automatic generation advancement or lifecycle state validation. If
/// observation is suppressed or no sink is present, the function returns an
/// inactive span. In disabled builds, it returns an inert span.
pub inline fn beginOwned(
    identity: Identity,
    operation: Operation,
    old_address: usize,
    old_len: usize,
    len: usize,
    alignment: usize,
    return_address: usize,
) Span {
    return beginEvent(
        identity,
        operation,
        .none,
        .none,
        old_address,
        old_len,
        len,
        alignment,
        return_address,
    );
}

/// Initiates a lifecycle observation span for an allocator transition,
/// requiring disposition and reason values other than none even though disabled
/// builds ultimately discard the event. The span records a lifecycle operation
/// kind, sets prior address, prior length, and requested length to zero, sets
/// alignment to one, and forwards the supplied identity and return address. The
/// caller supplies the eventual outcome upon finishing the span. The
/// observation layer records this transition without modifying or managing
/// owner lifetime state.
pub inline fn beginLifecycle(
    identity: Identity,
    disposition: LifecycleDisposition,
    reason: LifecycleReason,
    return_address: usize,
) Span {
    std.debug.assert(disposition != .none);
    std.debug.assert(reason != .none);
    return beginEvent(
        identity,
        .lifecycle,
        disposition,
        reason,
        0,
        0,
        0,
        1,
        return_address,
    );
}

inline fn beginEvent(
    identity: Identity,
    operation: Operation,
    lifecycle_disposition: LifecycleDisposition,
    lifecycle_reason: LifecycleReason,
    old_address: usize,
    old_len: usize,
    len: usize,
    alignment: usize,
    return_address: usize,
) Span {
    if (comptime !enabled) {
        return .{};
    }
    std.debug.assert(identity.producer_id != 0);
    if (identity.owner_cookie == 0) {
        std.debug.assert(identity.generation == 0);
    }
    const sink = Channel.acquire() orelse return inactiveSpan();
    const operation_id = takeId(&next_operation_id);
    const parent_operation_id = current_operation_id;
    current_operation_id = operation_id;
    return .{
        .sink = sink,
        .operation_id = operation_id,
        .parent_operation_id = parent_operation_id,
        .producer_id = identity.producer_id,
        .producer = identity.producer,
        .generation = identity.generation,
        .owner_cookie = identity.owner_cookie,
        .operation = operation,
        .lifecycle_disposition = lifecycle_disposition,
        .lifecycle_reason = lifecycle_reason,
        .old_address = old_address,
        .old_len = old_len,
        .len = len,
        .alignment = alignment,
        .return_address = return_address,
    };
}

/// Reserves an operation identifier and establishes thread nesting without
/// publishing an event when finished. In enabled builds with an installed sink
/// and no active suppression, the context increments the active operation count
/// and links into the thread parent stack. In all other circumstances, it
/// returns an inert token with an identifier of zero. Callers must finish the
/// returned context on its originating thread, as active contexts contribute to
/// the session drain count during shutdown.
pub inline fn beginContext() Context {
    if (comptime !enabled) return .{};
    _ = Channel.acquire() orelse return inactiveContext();
    const operation_id = takeId(&next_operation_id);
    const parent_operation_id = current_operation_id;
    current_operation_id = operation_id;
    return .{
        .operation_id = operation_id,
        .parent_operation_id = parent_operation_id,
    };
}

/// Increments the observation suppression depth counter on the current thread,
/// asserting that depth does not overflow an eight-bit integer, and returns a
/// suppression token that decrements the counter upon deinitialization. In
/// disabled builds, the call returns an inert token. Active suppression
/// prevents the creation of new spans and silent contexts on the calling thread
/// without altering spans that are already in progress.
pub inline fn suppress() Suppression {
    if (comptime !enabled) return .{};
    return Channel.suppress();
}

fn inactiveSpan() EnabledSpan {
    return .{
        .sink = undefined,
        .operation_id = 0,
        .parent_operation_id = 0,
        .producer_id = 0,
        .producer = .custom,
        .generation = 0,
        .owner_cookie = 0,
        .operation = .alloc,
        .lifecycle_disposition = .none,
        .lifecycle_reason = .none,
        .old_address = 0,
        .old_len = 0,
        .len = 0,
        .alignment = 0,
        .return_address = 0,
        .active = false,
    };
}

fn lockProducerRegistry() void {
    while (!producer_registry_lock.tryLock()) std.atomic.spinLoopHint();
}

fn inactiveContext() EnabledContext {
    return .{
        .operation_id = 0,
        .parent_operation_id = 0,
        .active = false,
    };
}

fn takeId(counter: *std.atomic.Value(u64)) u64 {
    const id = counter.fetchAdd(1, .monotonic);
    if (id == 0 or id == std.math.maxInt(u64)) {
        @panic("allocator observation identifier exhausted");
    }
    return id;
}
