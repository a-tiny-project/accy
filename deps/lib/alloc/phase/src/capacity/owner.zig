/// Specifies the structural protocol expected of a memory owner across two
/// independent axes: storage acquisition, defined by `StorageSource`, and
/// exhaustion behavior, defined by `OverloadShape`. Four named constants
/// represent the valid combinations: `allocator_exact`, `allocator_rejecting`,
/// `provisioned_exact`, and `provisioned_rejecting`. This classification
/// constrains required container declarations, field layouts, and lifecycle
/// function signatures during compile-time shape validation. It does not
/// inspect function bodies, verify that resource bounds are maintained at
/// runtime, or prove the dynamic correctness of owner operations. An `exact`
/// classification indicates only that the shape contract requires no
/// steady-state exhaustion error. It does not promise that operational methods
/// are infallible or that runtime failures cannot occur.
pub const OwnerShape = struct {
    storage_source: StorageSource,
    overload_shape: OverloadShape,

    /// Selects the storage acquisition mechanism required during owner
    /// initialization. The `allocator_backed` variant requires the owner's
    /// `init` function to receive a standard `std.mem.Allocator` parameter. The
    /// `caller_provisioned` variant requires `init` to receive an aligned slice
    /// conforming to the owner's declared `Storage` type. The enumeration
    /// defines structural initialization signatures only. Neither variant
    /// enforces memory lifetimes or guarantees that callers retain backing
    /// storage for the required duration of the owner.
    pub const StorageSource = enum {
        allocator_backed,
        caller_provisioned,
    };

    /// The exact overload shape requires no Exhaustion declaration. The
    /// rejecting overload shape requires a finite nonempty Exhaustion error set
    /// and at least one non-lifecycle pointer-receiver method whose return type
    /// is an error set or error union containing all Exhaustion errors. The
    /// return type does not have to be an error union. This signature check
    /// does not prove error reachability.
    pub const OverloadShape = enum {
        exact,
        rejecting,
    };

    /// This shape value selects `allocator_backed` storage paired with an
    /// `exact` overload surface. This identifier serves as a declaration value
    /// describing the shape and does not run validation checks.
    pub const allocator_exact: OwnerShape = .{
        .storage_source = .allocator_backed,
        .overload_shape = .exact,
    };

    /// This shape value selects the pairing of `allocator_backed` storage with
    /// a `rejecting` overload surface.
    pub const allocator_rejecting: OwnerShape = .{
        .storage_source = .allocator_backed,
        .overload_shape = .rejecting,
    };

    /// This shape value selects the pairing of `caller_provisioned` storage
    /// with an `exact` overload surface.
    pub const provisioned_exact: OwnerShape = .{
        .storage_source = .caller_provisioned,
        .overload_shape = .exact,
    };

    /// This shape value selects the pairing of `caller_provisioned` storage
    /// with a `rejecting` overload surface.
    pub const provisioned_rejecting: OwnerShape = .{
        .storage_source = .caller_provisioned,
        .overload_shape = .rejecting,
    };
};

/// Defines three static bounds for owner lifecycle and maintenance work:
/// `transition_steps_max`, `cleanup_steps_per_call_max`, and
/// `cleanup_calls_at_capacity_max`. Structural validation requires
/// `transition_steps_max` to be greater than zero. The cleanup bounds must be
/// either both zero or both nonzero, and their arithmetic product must fit
/// within `usize` without overflow. These bounds are literal numeric
/// declarations checked solely for structural validity. Validation does not
/// measure CPU instructions, inspect loop constructs, or evaluate wall-clock
/// duration. In implementations providing cleanup routines, the work performed
/// by each cleanup step may depend on the extent of stored data rather than a
/// constant processing cost.
pub const WorkLimits = struct {
    transition_steps_max: usize,
    cleanup_steps_per_call_max: usize,
    cleanup_calls_at_capacity_max: usize,
};
