//! The silent observer takes the same arguments as `stardust.zig` and records
//! nothing. The alloc_phase build selects it when `stardust.zig` is absent,
//! because the package manifest omits that file from `.paths`. Shipped sources
//! then compile without the Stardust compiler patch.
//! Claim validation and witness key checks still run in the callers.

/// `recording` is false because this root enters no claims.
pub const recording = false;

/// `declaration` accepts one claim registration and records nothing.
pub fn declaration(
    comptime claim: anytype,
    comptime init: anytype,
    comptime default_limits: anytype,
    comptime seal: anytype,
    comptime seal_premise: anytype,
    comptime teardown: anytype,
    comptime teardown_premise: anytype,
) void {
    _ = claim;
    _ = init;
    _ = default_limits;
    _ = seal;
    _ = seal_premise;
    _ = teardown;
    _ = teardown_premise;
}

/// `witness` accepts one test witness annotation and records nothing.
pub fn witness(comptime annotation: anytype) void {
    _ = annotation;
}
