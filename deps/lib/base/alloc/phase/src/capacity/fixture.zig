const std = @import("std");
const capacity = @import("capacity");

/// Demonstrates an implementation of the caller-provisioned exact owner
/// protocol, re-exported from the package root as `ProvisionedExactFixture`.
/// The owner accepts requested capacities from 1 to 64 bytes and requires
/// caller-provided storage at least as long as the requested count. It retains
/// the entire caller slice across its active lifecycle and returns that exact
/// slice upon deinitialization, even when the provided buffer exceeds the
/// requested capacity. Lifecycle transitions are guarded by debug assertions
/// across `initialization`, `steady`, and `teardown` phases without allocating
/// memory or holding an internal allocator. The instance remains caller-backed
/// throughout its existence. It represents a concrete demonstration fixture, so
/// its specific buffer retention and assertion choices should not be taken as
/// universal requirements for all provisioned owners.
pub const ExactOwner = struct {
    /// This constant defines the 16-byte storage alignment required by
    /// `ExactOwner.Storage`, which the caller must satisfy by supplying an
    /// aligned slice.
    pub const storage_alignment: usize = 16;
    /// This type is a mutable caller-provided slice of []align(16)u8 borrowed
    /// until owner deinit. It may be backed by a caller heap allocation or
    /// another suitable buffer. The fixture does not own or free the underlying
    /// allocation.
    pub const Storage = []align(storage_alignment) u8;
    /// Specifies the input limit configuration for `ExactOwner`, containing a
    /// single `bytes: usize` field. For this demonstration fixture, valid
    /// values are restricted to the range from 1 through 64 bytes.
    pub const Limits = struct {
        bytes: usize,
    };
    /// Represents the derived capacity of `ExactOwner`, storing the required
    /// byte count in `storage_bytes: usize`. This value reflects the storage
    /// quantity computed from the input limits, rather than the total length of
    /// the backing slice supplied by the caller.
    pub const Capacity = struct {
        storage_bytes: usize,

        /// This derivation error reports `EmptyStorage` for 0 requested bytes
        /// and `CapacityExceeded` when requested bytes exceed 64. The error set
        /// represents capacity derivation limits and does not include
        /// allocation failure.
        pub const DeriveError = error{
            EmptyStorage,
            CapacityExceeded,
        };

        /// Calculates the required `Capacity` from the provided `Limits`
        /// without performing memory allocation. Returns `error.EmptyStorage`
        /// when `limits.bytes` is zero, and `error.CapacityExceeded` when
        /// `limits.bytes` exceeds 64. For valid inputs between 1 and 64, it
        /// returns a `Capacity` instance whose `storage_bytes` equals
        /// `limits.bytes`.
        pub fn derive(limits: Limits) DeriveError!Capacity {
            if (limits.bytes == 0) return error.EmptyStorage;
            if (limits.bytes > storage_bytes_max) return error.CapacityExceeded;
            return .{ .storage_bytes = limits.bytes };
        }
    };
    /// Defines the error set returned by `init`, formed as the union of
    /// `Capacity.DeriveError` (`error{EmptyStorage, CapacityExceeded}`) and
    /// `error{StorageTooShort}`. Because initialization relies entirely on
    /// caller-provided memory without invoking dynamic allocators, the error
    /// set excludes `error.OutOfMemory`.
    pub const InitError = Capacity.DeriveError || error{StorageTooShort};
    /// This declaration specifies literal declared work bounds with
    /// transition_steps_max set to 1, cleanup_steps_per_call_max set to 0, and
    /// cleanup_calls_at_capacity_max set to 0. These values represent
    /// structural bounds whose numeric shape passes validation rather than
    /// measured CPU counts or independently established semantic unit proofs.
    pub const work_limits: capacity.WorkLimits = .{
        .transition_steps_max = 1,
        .cleanup_steps_per_call_max = 0,
        .cleanup_calls_at_capacity_max = 0,
    };
    /// Declares the compile-time `Declaration` capturing formal specification
    /// metadata for `ExactOwner`. It records the source envelope and typed
    /// bindings, specifying the capacity model, the overload policy
    /// `reject_before_seal`, open risk statuses for transitive and foreign
    /// risks, the transition work equation, and obligation keys. This
    /// declaration documents formal properties and links verification
    /// obligations for external analysis tools. The presence of the declaration
    /// does not itself prove that the implementation satisfies the stated
    /// invariants.
    pub const claim: capacity.Declaration = .{
        .source = .{
            .id = "alloc.provisioned_exact_fixture",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "caller_byte_storage",
                        .lifetime = .transferred,
                        .detail = "caller byte storage",
                    },
                },
                .excluded = &.{
                    "caller-owned payloads",
                },
            },
            .capacity = .{
                .inputs = &.{
                    capacity.bindInput(Limits, "bytes", "bytes"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 0,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "short storage rejects before owner construction",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "fixture has no callees",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "fixture has no foreign resources",
                },
            },
            .work = .{ .equation = "transition_steps <= transition_steps_max" },
            .obligations = &.{
                .{ .key = "alloc_provisioned_exact_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "alloc_provisioned_exact_capacity_overload", .role = .overload },
                .{ .key = "alloc_provisioned_exact_capacity_work_bound", .role = .work_bound },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: capacity.Phase,
    capacity: Capacity,
    storage: Storage,

    const storage_bytes_max: usize = 64;

    /// Initializes an `ExactOwner` instance using caller-supplied storage and
    /// configuration limits. It executes `Capacity.derive` first, returning
    /// `error.StorageTooShort` without constructing an owner instance if
    /// `storage.len` is less than `derived.storage_bytes`. On success, it
    /// retains the entire caller slice, sets the internal phase to
    /// `initialization`, and records the derived capacity. The function
    /// performs no heap allocations.
    pub fn init(storage: Storage, limits: Limits) InitError!ExactOwner {
        const derived = try Capacity.derive(limits);
        if (storage.len < derived.storage_bytes) return error.StorageTooShort;
        return .{
            .phase = .initialization,
            .capacity = derived,
            .storage = storage,
        };
    }

    /// Transitions the owner from `initialization` to `steady` phase. It
    /// verifies that the current phase is `initialization` using a debug
    /// assertion, which may be disabled in non-debug compilation modes and
    /// therefore does not guarantee a panic in all release configurations.
    /// Activation acquires no system resources and performs no memory
    /// allocations.
    pub fn activate(self: *ExactOwner) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    /// Returns the active byte capacity of the owner, guarded by a debug
    /// assertion that the owner is in the `steady` phase. The returned value is
    /// `capacity.storage_bytes`, representing the required count derived from
    /// initialization limits, rather than the length of the underlying storage
    /// slice.
    pub fn bytes(self: *const ExactOwner) usize {
        std.debug.assert(self.phase == .steady);
        return self.capacity.storage_bytes;
    }

    /// Deinitializes the owner, transitioning the internal phase from `steady`
    /// to `teardown`, invalidating the owner instance by setting it to
    /// `undefined`, and returning the original caller-supplied slice in its
    /// entirety. The function relies on a debug assertion to check the `steady`
    /// phase prerequisite. It performs no implicit cleanup or byte zeroing and
    /// does not free memory, leaving full ownership and custody of the returned
    /// buffer with the caller.
    pub fn deinit(self: *ExactOwner) Storage {
        std.debug.assert(self.phase == .steady);
        self.phase = .teardown;
        const storage = self.storage;
        self.* = undefined;
        return storage;
    }
};

/// Demonstrates an implementation of the caller-provisioned rejecting owner
/// protocol, re-exported from the package root as
/// `ProvisionedRejectingFixture`. The owner manages a bounded number of slots,
/// up to 8, with each slot having a positive byte width, backed by
/// caller-supplied 16-byte aligned memory. Calling submit when full returns
/// Full after incrementing both submitted and rejected counts if both
/// increments fit, or returns AccountingOverflow before mutation if an
/// increment would overflow usize. The payload is preserved along either
/// rejection path. Calling cleanupOne pops and zeroes a single slot, while
/// deinit returns the entire original slice without executing a cleanup loop,
/// requiring the caller to keep borrowed bytes alive.
pub const RejectingOwner = struct {
    /// This constant specifies a maximum of 8 allowed slots for
    /// `RejectingOwner`. This slot limit applies regardless of the slot width,
    /// which must be positive and yield a product that fits in `usize`.
    pub const slots_max: usize = 8;
    /// This constant specifies the 16-byte storage alignment required by
    /// `RejectingOwner.Storage`, which remains the responsibility of the caller
    /// to supply.
    pub const storage_alignment: usize = 16;
    /// Defines the storage type accepted and used by `RejectingOwner`, declared
    /// as `[]align(16) u8`. This slice represents a mutable buffer borrowed
    /// from the caller for the duration of the owner's active life. Ownership
    /// of the memory remains with the caller.
    pub const Storage = []align(storage_alignment) u8;
    /// Specifies the configuration limits for `RejectingOwner`, containing
    /// `slots: usize` and `slot_bytes: usize`. Valid limits require both fields
    /// to be positive, `slots` to be less than or equal to 8, and their
    /// arithmetic product to fit within `usize` without overflow.
    pub const Limits = struct {
        slots: usize,
        slot_bytes: usize,
    };
    /// Stores the derived dimensional parameters of `RejectingOwner`, including
    /// `slots: usize`, `slot_bytes: usize`, and `storage_bytes: usize`. The
    /// `storage_bytes` field holds the exact product of `slots` and
    /// `slot_bytes`, representing the total storage required by the owner.
    pub const Capacity = struct {
        slots: usize,
        slot_bytes: usize,
        storage_bytes: usize,

        /// This error type reports `InvalidLimit` on zero slots or width,
        /// `CapacityOverflow` if their product overflows `usize`, and
        /// `CapacityExceeded` if the slot count exceeds 8 after the product
        /// check. These outcomes represent derivation failures rather than
        /// domain `Exhaustion` conditions like `Full` or `AccountingOverflow`.
        pub const DeriveError = error{
            InvalidLimit,
            CapacityOverflow,
            CapacityExceeded,
        };

        /// Derives the required `Capacity` from input `Limits` without
        /// performing memory allocation. It evaluates error conditions in a
        /// strict sequence: returns `error.InvalidLimit` if either `slots` or
        /// `slot_bytes` is zero, returns `error.CapacityOverflow` if computing
        /// `slots * slot_bytes` overflows `usize`, and returns
        /// `error.CapacityExceeded` if `slots` exceeds 8 after the checked
        /// product succeeds. On valid inputs, it returns a `Capacity` instance
        /// recording the slot count, slot width, and computed storage byte
        /// count.
        pub fn derive(limits: Limits) DeriveError!Capacity {
            if (limits.slots == 0 or limits.slot_bytes == 0) {
                return error.InvalidLimit;
            }
            const storage_bytes = try capacity.mul(
                usize,
                limits.slots,
                limits.slot_bytes,
            );
            if (limits.slots > slots_max) return error.CapacityExceeded;
            return .{
                .slots = limits.slots,
                .slot_bytes = limits.slot_bytes,
                .storage_bytes = storage_bytes,
            };
        }
    };
    /// This error set comprises Full and AccountingOverflow. Full indicates
    /// that all slots are occupied and the attempt is successfully recorded in
    /// submitted and rejected counters while payload and used count remain
    /// unchanged. AccountingOverflow occurs when an increment required by the
    /// selected submission path would exceed usize, rather than when a valid
    /// increment merely reaches the maximum value. This error returns before
    /// any payload or counter mutation occurs. Only counters relevant to the
    /// selected path are checked, specifically submitted and rejected for full
    /// rejection, or submitted and accepted for successful admission.
    pub const Exhaustion = error{
        Full,
        AccountingOverflow,
    };
    /// Specifies the error set returned by `init`, formed as the union of
    /// `Capacity.DeriveError` (`error{InvalidLimit, CapacityOverflow,
    /// CapacityExceeded}`) and `error{StorageTooShort}`. It captures failure
    /// during limit derivation or when the supplied caller storage slice
    /// contains fewer bytes than derived `storage_bytes`.
    pub const InitError = Capacity.DeriveError || error{StorageTooShort};
    /// Maintains diagnostic accounting counters for `RejectingOwner`, tracking
    /// `submitted`, `accepted`, and `rejected` operations initialized to zero.
    /// Submissions increment counters only along execution paths where
    /// arithmetic fits within `usize` without overflow. An attempt that fails
    /// because the owner is full is recorded by incrementing both `submitted`
    /// and `rejected`, leaving `accepted` unchanged.
    pub const Usage = struct {
        submitted: usize = 0,
        accepted: usize = 0,
        rejected: usize = 0,
    };
    /// Declares the static `WorkLimits` for `RejectingOwner`, configuring
    /// `transition_steps_max` as 1, `cleanup_steps_per_call_max` as 1, and
    /// `cleanup_calls_at_capacity_max` as 8. These numbers represent declared
    /// owner work units rather than elapsed execution time or hardware cycle
    /// counts. In particular, each cleanup invocation executes `@memset` across
    /// an entire slot, so the actual runtime work scales with `slot_bytes`.
    pub const work_limits: capacity.WorkLimits = .{
        .transition_steps_max = 1,
        .cleanup_steps_per_call_max = 1,
        .cleanup_calls_at_capacity_max = slots_max,
    };
    /// Declares the compile-time `Declaration` capturing formal specification
    /// metadata for `RejectingOwner`. It binds the slot product capacity model,
    /// the overload policy `reject_before_mutation` documenting payload
    /// preservation alongside diagnostic counter updates, open risk statuses
    /// for transitive and foreign risks, the bounded cleanup work equation, and
    /// obligation keys. This declaration documents design contracts and
    /// provides metadata for verification tools without executing runtime
    /// checks or proving implementation correctness.
    pub const claim: capacity.Declaration = .{
        .source = .{
            .id = "alloc.provisioned_rejecting_fixture",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "caller_slot_storage",
                        .lifetime = .transferred,
                        .detail = "caller slot storage",
                    },
                },
                .excluded = &.{
                    "caller-owned payloads",
                },
            },
            .capacity = .{
                .inputs = &.{
                    capacity.bindInput(Limits, "slots", "slots"),
                    capacity.bindInput(Limits, "slot_bytes", "slot_bytes"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .product = .{ .left = 0, .right = 1 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 2,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "full submission changes only submitted and rejected counters",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "fixture has no callees",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "fixture has no foreign resources",
                },
            },
            .work = .{ .equation = "transition <= 1 and cleanup <= slots" },
            .obligations = &.{
                .{ .key = "alloc_provisioned_rejecting_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "alloc_provisioned_rejecting_capacity_overload", .role = .overload },
                .{ .key = "alloc_provisioned_rejecting_capacity_work_bound", .role = .work_bound },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: capacity.Phase,
    capacity: Capacity,
    storage: Storage,
    used: usize = 0,
    usage: Usage = .{},

    /// Initializes a `RejectingOwner` instance using caller storage and
    /// configuration limits. It executes `Capacity.derive` first and then
    /// checks that `storage.len` is at least `derived.storage_bytes`, returning
    /// `error.StorageTooShort` if the buffer is insufficient. On success, it
    /// preserves the original storage slice, sets `phase` to `initialization`,
    /// initializes `used` to 0, and sets `usage` counters to 0. The function
    /// performs no dynamic memory allocation.
    pub fn init(storage: Storage, limits: Limits) InitError!RejectingOwner {
        const derived = try Capacity.derive(limits);
        if (storage.len < derived.storage_bytes) return error.StorageTooShort;
        return .{
            .phase = .initialization,
            .capacity = derived,
            .storage = storage,
        };
    }

    /// Transitions the owner from `initialization` to `steady` phase. It
    /// verifies that the current phase is `initialization` using a debug
    /// assertion. Activation acquires no system resources and performs no
    /// memory allocations.
    pub fn activate(self: *RejectingOwner) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    /// Submits a byte value into the owner, guarded by a debug assertion that
    /// the current phase is `steady`. When capacity is exhausted because `used`
    /// equals `capacity.slots`, the function checks that `submitted` and
    /// `rejected` will not overflow `std.math.maxInt(usize)`. If accounting
    /// fits, it increments both counters and returns `error.Full` while
    /// preserving stored payload and slot count. If any counter addition would
    /// overflow `usize`, it returns `error.AccountingOverflow` before any
    /// mutation occurs. On successful submission, it increments
    /// `usage.submitted`, fills all bytes of the next slot with `byte`,
    /// increments `used`, and increments `usage.accepted`. The operation
    /// performs no hidden allocations and provides no automatic state reset or
    /// buffer reuse beyond calling `cleanupOne`.
    pub fn submit(self: *RejectingOwner, byte: u8) Exhaustion!void {
        std.debug.assert(self.phase == .steady);
        if (self.used == self.capacity.slots) {
            if (self.usage.submitted == std.math.maxInt(usize)) {
                return error.AccountingOverflow;
            }
            if (self.usage.rejected == std.math.maxInt(usize)) {
                return error.AccountingOverflow;
            }
            self.usage.submitted += 1;
            self.usage.rejected += 1;
            return error.Full;
        }
        if (self.usage.submitted == std.math.maxInt(usize)) {
            return error.AccountingOverflow;
        }
        if (self.usage.accepted == std.math.maxInt(usize)) {
            return error.AccountingOverflow;
        }
        self.usage.submitted += 1;
        const offset = self.used * self.capacity.slot_bytes;
        @memset(self.storage[offset..][0..self.capacity.slot_bytes], byte);
        self.used += 1;
        self.usage.accepted += 1;
    }

    /// Removes a single slot from the owner, guarded by a debug assertion that
    /// the phase is `steady`. If `used` is 0, it returns `false` without
    /// modifying state. When slots are present, it decrements `used`, zeroes
    /// all bytes in the removed slot using `@memset`, and returns `true`. The
    /// function leaves `usage` accounting counters unchanged. It performs no
    /// dynamic memory allocation, does not terminate or teardown the owner, and
    /// executes cleanup work that scales with `slot_bytes`.
    pub fn cleanupOne(self: *RejectingOwner) bool {
        std.debug.assert(self.phase == .steady);
        if (self.used == 0) return false;
        self.used -= 1;
        const offset = self.used * self.capacity.slot_bytes;
        @memset(self.storage[offset..][0..self.capacity.slot_bytes], 0);
        return true;
    }

    /// Deinitializes the owner, asserting that the owner is in the `steady`
    /// phase. It transitions `phase` to `teardown`, sets the owner instance to
    /// `undefined`, and returns the original caller-supplied slice in its
    /// entirety. The function does not call `cleanupOne` or zero out remaining
    /// occupied slot payloads, leaving any required scrubbing or memory
    /// sanitization to the caller.
    pub fn deinit(self: *RejectingOwner) Storage {
        std.debug.assert(self.phase == .steady);
        self.phase = .teardown;
        const storage = self.storage;
        self.* = undefined;
        return storage;
    }
};

comptime {
    capacity.requireProvisionedExactOwnerShape(ExactOwner);
}

comptime {
    capacity.requireProvisionedRejectingOwnerShape(RejectingOwner);
}
