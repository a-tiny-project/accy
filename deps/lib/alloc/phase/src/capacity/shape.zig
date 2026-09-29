//! This module validates owner declarations, fields, lifecycle, method
//! capabilities, exhaustion, and optional or required claims in that exact
//! order. The `require` functions convert validation failures into compile
//! errors and inspect the claim first to produce detailed diagnostics. A
//! successful present claim records typed references through the Stardust
//! observer, performing structural and type inspection without function body
//! effects or bound proofs.

const std = @import("std");
const capability = @import("capability.zig");
const declaration = @import("declaration.zig");
const observer = @import("observer");
const owner = @import("owner.zig");
const phase = @import("phase.zig");
const signature = @import("signature.zig");

const OwnerShape = owner.OwnerShape;
const Phase = phase.Phase;

/// Enumerates the first structural check failure detected when validating an
/// owner type against an expected `OwnerShape`. Tags cover missing or malformed
/// declarations, incorrect runtime fields, mismatched lifecycle signatures,
/// prohibited allocator capabilities, invalid exhaustion declarations, and
/// missing or invalid claims. When an owner declares an invalid claim,
/// `validateOwnerShape` collapses the underlying `DeclarationViolation` into
/// the single tag `invalid_claim`. In contrast, `requireOwnerShape` validates
/// the claim directly through `declaration.require` before running shape
/// checks, emitting detailed compile errors for specific declaration failures.
/// Because compile-time reflection can encounter malformed syntax or illegal
/// type definitions in user declarations, passing arbitrary malformed types to
/// validation functions may produce compiler errors rather than returning an
/// optional violation cleanly.
pub const OwnerShapeViolation = enum {
    owner_not_struct,
    missing_phase,
    wrong_phase_type,
    comptime_phase,
    missing_capacity,
    wrong_capacity_type,
    comptime_capacity,
    missing_limits_declaration,
    wrong_limits_declaration,
    missing_capacity_declaration,
    wrong_capacity_declaration,
    missing_storage_alignment,
    wrong_storage_alignment,
    invalid_storage_alignment,
    missing_storage_declaration,
    wrong_storage_declaration,
    missing_storage,
    wrong_storage_type,
    comptime_storage,
    missing_storage_bytes,
    wrong_storage_bytes,
    comptime_storage_bytes,
    missing_work_limits,
    wrong_work_limits,
    invalid_work_limits,
    missing_claim_declaration,
    wrong_claim_declaration,
    invalid_claim,
    missing_exhaustion_declaration,
    wrong_exhaustion_declaration,
    exhaustion_not_observable,
    stored_allocator,
    missing_capacity_derive,
    wrong_capacity_derive,
    missing_init,
    wrong_init,
    missing_activate,
    wrong_activate,
    missing_deinit,
    wrong_deinit,
    steady_allocator_parameter,
    steady_allocator_result,
};

/// This compile-time check validates an allocator_exact owner shape. It
/// inspects Limits and Capacity declarations, runtime phase and capacity
/// declarations, and allocator-backed lifecycle signatures. An immediate
/// capability scanner examines stored fields as well as known parameters and
/// results of non-lifecycle receiver methods, while lifecycle init and deinit
/// intentionally accept an Allocator. An optional claim is validated and
/// recorded through the Stardust observer. Any invalid declaration or shape
/// causes a compile error. The check does not run owner code.
pub fn requireAllocatorExactOwnerShape(comptime Owner: type) void {
    requireOwnerShape(Owner, OwnerShape.allocator_exact);
}

/// This compile-time check validates an allocator_rejecting owner shape. It
/// shares allocator-backed fields and lifecycle signatures with allocator_exact
/// but enforces different overload requirements rather than all exact
/// requirements. The owner must expose a finite nonempty Exhaustion error set
/// on a non-lifecycle pointer-receiver method. Any optional claim is checked
/// for compatibility under the rejecting shape and recorded. The validation
/// performs structural and type checks only.
pub fn requireAllocatorRejectingOwnerShape(comptime Owner: type) void {
    requireOwnerShape(Owner, OwnerShape.allocator_rejecting);
}

/// Enforces at compile time that an owner type conforms to the
/// caller-provisioned exact protocol (`OwnerShape.provisioned_exact`). The
/// owner must declare a positive power-of-two `storage_alignment`, matching
/// aligned slice `Storage`, and typed `work_limits`. Runtime fields must
/// include `phase: Phase`, `capacity: Capacity` (containing a runtime
/// `storage_bytes: usize`), and `storage: Storage`. Lifecycle functions must
/// implement specific signatures: `Capacity.derive` and `init` must return
/// finite nonempty error unions, `activate` must return `void` exactly, and
/// `deinit` must return `Storage` exactly. A typed `claim` declaration is
/// mandatory and validated. Recursive capability checks verify that stored
/// fields, `Limits`, `Capacity`, and non-lifecycle method signatures contain no
/// allocator capabilities. Any violation causes a compile error. Conformance
/// does not execute owner code or verify runtime buffer management.
pub fn requireProvisionedExactOwnerShape(comptime Owner: type) void {
    requireOwnerShape(Owner, OwnerShape.provisioned_exact);
}

/// This compile-time check validates a provisioned_rejecting owner shape. It
/// shares provisioned storage, fields, lifecycle, and work rules with
/// provisioned_exact, but enforces distinct overload requirements instead of
/// all exact requirements. The owner must expose a finite nonempty Exhaustion
/// error set on a non-lifecycle pointer-receiver method, and its claim overload
/// kind must be reject_before_mutation. The validator verifies this
/// classification and records a valid claim without inspecting actual protected
/// payload or diagnostic mutation. Callers should read the owner claim detail
/// to identify protected state. Any failed declaration or shape triggers a
/// compile error.
pub fn requireProvisionedRejectingOwnerShape(comptime Owner: type) void {
    requireOwnerShape(Owner, OwnerShape.provisioned_rejecting);
}

fn requireOwnerShape(comptime Owner: type, comptime expected: OwnerShape) void {
    @setEvalBranchQuota(1_000_000);
    if (comptime @typeInfo(Owner) == .@"struct" and
        @hasDecl(Owner, "Limits") and
        @hasDecl(Owner, "claim") and
        @TypeOf(Owner.claim) == declaration.Declaration)
    {
        declaration.require(Owner, Owner.claim, expected);
    }
    if (comptime validateOwnerShape(Owner, expected)) |violation| {
        @compileError("invalid owner shape: " ++ @tagName(violation));
    }
}

/// Validates that an owner type conforms to `OwnerShape.allocator_exact`,
/// returning an optional `OwnerShapeViolation`. It uses an immediate shallow
/// capability scanner that inspects stored fields and method signatures for
/// direct references to `std.mem.Allocator` or container allocator factories.
/// If a valid typed `claim` is declared, the function records claim metadata at
/// compile time. A return value of `null` confirms that all structural checks
/// passed. It does not prove that owner methods avoid runtime heap allocation
/// or that dynamic memory behavior is infallible.
pub fn validateAllocatorExactOwnerShape(comptime Owner: type) ?OwnerShapeViolation {
    return validateOwnerShape(Owner, OwnerShape.allocator_exact);
}

/// This function validates an allocator_rejecting owner shape, returning the
/// first OwnerShapeViolation or null. It shares allocator-backed lifecycle and
/// field rules with the exact shape but does not require all exact claim
/// policies. It instead adds an Exhaustion surface requirement and verifies
/// claim compatibility for the rejecting shape when a claim is present. The
/// function executes a shallow capability scan, records any valid present
/// claim, and does not prove error reachability.
pub fn validateAllocatorRejectingOwnerShape(comptime Owner: type) ?OwnerShapeViolation {
    return validateOwnerShape(Owner, OwnerShape.allocator_rejecting);
}

/// This function validates a provisioned_exact owner shape, returning the first
/// violation or null. It verifies runtime phase, capacity, and storage
/// declarations, ensuring an aligned Storage type and a Capacity.storage_bytes
/// field. It also verifies a typed claim and a work_limits declaration, noting
/// that work_limits is a compile-time declaration rather than a runtime field.
/// A recursive capability scan inspects the owner including Limits and
/// Capacity, and any valid claim is recorded. The function does not execute
/// lifecycle methods.
pub fn validateProvisionedExactOwnerShape(comptime Owner: type) ?OwnerShapeViolation {
    return validateOwnerShape(Owner, OwnerShape.provisioned_exact);
}

/// This function validates a provisioned_rejecting owner shape, returning the
/// first violation or null. It applies shared provisioned storage, lifecycle,
/// and work rules while enforcing a different overload classification. The
/// owner must expose a finite nonempty Exhaustion error set on a
/// pointer-receiver method and declare a reject_before_mutation claim overload.
/// A recursive capability scan is performed, and any valid claim is recorded.
/// The function does not itself check payload preservation.
pub fn validateProvisionedRejectingOwnerShape(comptime Owner: type) ?OwnerShapeViolation {
    return validateOwnerShape(Owner, OwnerShape.provisioned_rejecting);
}

/// Inspects a type at compile time against an expected `OwnerShape`, returning
/// `null` if the type satisfies the protocol or the first `OwnerShapeViolation`
/// if a check fails. If the owner provides a valid typed `claim`, the function
/// records claim metadata through the Stardust observer, linking the claim to
/// `init`, default limits, and lifecycle family declarations. Allocator-backed
/// owners may omit a claim, in which case validation succeeds without recording
/// claim metadata. Provisioned owners require a valid claim. Validation
/// examines types, declarations, and signatures without executing owner
/// functions, allocating resources, or verifying that declared formal
/// obligations are mathematically discharged.
pub fn validateOwnerShape(
    comptime Owner: type,
    comptime expected: OwnerShape,
) ?OwnerShapeViolation {
    const owner_info = @typeInfo(Owner);
    if (comptime owner_info != .@"struct") return .owner_not_struct;
    if (comptime validateDeclarations(Owner, expected)) |violation| return violation;
    if (comptime validateFields(Owner, expected)) |violation| return violation;
    if (comptime validateLifecycle(Owner, expected)) |violation| return violation;
    if (comptime validateMethodCapabilities(Owner, expected)) |violation| {
        return violation;
    }
    if (expected.overload_shape == .rejecting) {
        if (comptime validateExhaustion(Owner)) |violation| return violation;
    }
    if (comptime validateOwnerClaim(Owner, expected)) |violation| return violation;
    return null;
}

fn validateDeclarations(
    comptime Owner: type,
    comptime expected: OwnerShape,
) ?OwnerShapeViolation {
    if (comptime !@hasDecl(Owner, "Limits")) return .missing_limits_declaration;
    if (comptime @TypeOf(Owner.Limits) != type) return .wrong_limits_declaration;
    if (comptime !signature.declarationContainer(Owner.Limits)) {
        return .wrong_limits_declaration;
    }
    if (comptime !@hasDecl(Owner, "Capacity")) return .missing_capacity_declaration;
    if (comptime @TypeOf(Owner.Capacity) != type) return .wrong_capacity_declaration;
    if (comptime !signature.declarationContainer(Owner.Capacity)) {
        return .wrong_capacity_declaration;
    }
    if (expected.storage_source == .caller_provisioned) {
        if (comptime @typeInfo(Owner.Capacity) != .@"struct") {
            return .wrong_capacity_declaration;
        }
        if (comptime capability.typeHasAllocatorCapability(Owner.Limits)) {
            return .stored_allocator;
        }
        if (comptime capability.typeHasAllocatorCapability(Owner.Capacity)) {
            return .stored_allocator;
        }
        if (comptime validateProvisionedDeclarations(Owner)) |violation| {
            return violation;
        }
    }
    return null;
}

fn validateProvisionedDeclarations(comptime Owner: type) ?OwnerShapeViolation {
    if (comptime !@hasDecl(Owner, "storage_alignment")) {
        return .missing_storage_alignment;
    }
    if (comptime @TypeOf(Owner.storage_alignment) != usize) {
        return .wrong_storage_alignment;
    }
    if (comptime Owner.storage_alignment == 0) return .invalid_storage_alignment;
    if (comptime !std.math.isPowerOfTwo(Owner.storage_alignment)) {
        return .invalid_storage_alignment;
    }
    if (comptime !@hasDecl(Owner, "Storage")) return .missing_storage_declaration;
    if (comptime @TypeOf(Owner.Storage) != type) return .wrong_storage_declaration;
    if (comptime !signature.provisionedStorageTypeValid(Owner)) {
        return .wrong_storage_declaration;
    }
    if (comptime !@hasDecl(Owner, "work_limits")) return .missing_work_limits;
    if (comptime @TypeOf(Owner.work_limits) != owner.WorkLimits) {
        return .wrong_work_limits;
    }
    if (comptime !workLimitsValid(Owner.work_limits)) return .invalid_work_limits;
    return null;
}

fn validateFields(
    comptime Owner: type,
    comptime expected: OwnerShape,
) ?OwnerShapeViolation {
    if (comptime !@hasField(Owner, "phase")) return .missing_phase;
    if (comptime @FieldType(Owner, "phase") != Phase) return .wrong_phase_type;
    if (comptime !runtimeField(Owner, "phase")) return .comptime_phase;
    if (comptime !@hasField(Owner, "capacity")) return .missing_capacity;
    if (comptime @FieldType(Owner, "capacity") != Owner.Capacity) {
        return .wrong_capacity_type;
    }
    if (comptime !runtimeField(Owner, "capacity")) return .comptime_capacity;
    if (expected.storage_source == .caller_provisioned) {
        if (comptime !@hasField(Owner.Capacity, "storage_bytes")) {
            return .missing_storage_bytes;
        }
        if (comptime @FieldType(Owner.Capacity, "storage_bytes") != usize) {
            return .wrong_storage_bytes;
        }
        if (comptime !runtimeField(Owner.Capacity, "storage_bytes")) {
            return .comptime_storage_bytes;
        }
        if (comptime !@hasField(Owner, "storage")) return .missing_storage;
        if (comptime @FieldType(Owner, "storage") != Owner.Storage) {
            return .wrong_storage_type;
        }
        if (comptime !runtimeField(Owner, "storage")) return .comptime_storage;
    }
    inline for (@typeInfo(Owner).@"struct".field_types) |field_type| {
        if (comptime ownerTypeHasAllocatorCapability(field_type, expected)) {
            return .stored_allocator;
        }
    }
    return null;
}

fn runtimeField(comptime Container: type, comptime name: []const u8) bool {
    const info = @typeInfo(Container).@"struct";
    inline for (info.field_names, info.field_attrs) |field_name, field_attrs| {
        if (comptime std.mem.eql(u8, field_name, name)) {
            return !field_attrs.@"comptime";
        }
    }
    return false;
}

fn validateLifecycle(
    comptime Owner: type,
    comptime expected: OwnerShape,
) ?OwnerShapeViolation {
    if (comptime !@hasDecl(Owner.Capacity, "derive")) return .missing_capacity_derive;
    const derive_valid = comptime switch (expected.storage_source) {
        .allocator_backed => signature.capacityDeriveValid(Owner),
        .caller_provisioned => signature.provisionedCapacityDeriveValid(Owner),
    };
    if (comptime !derive_valid) return .wrong_capacity_derive;
    if (comptime !@hasDecl(Owner, "init")) return .missing_init;
    const init_valid = comptime switch (expected.storage_source) {
        .allocator_backed => signature.allocatorOwnerInitValid(Owner),
        .caller_provisioned => signature.provisionedOwnerInitValid(Owner),
    };
    if (comptime !init_valid) return .wrong_init;
    if (comptime !@hasDecl(Owner, "activate")) return .missing_activate;
    const activate_valid = comptime switch (expected.storage_source) {
        .allocator_backed => signature.ownerActivateValid(Owner),
        .caller_provisioned => signature.provisionedOwnerActivateValid(Owner),
    };
    if (comptime !activate_valid) return .wrong_activate;
    if (comptime !@hasDecl(Owner, "deinit")) return .missing_deinit;
    const deinit_valid = comptime switch (expected.storage_source) {
        .allocator_backed => signature.allocatorOwnerDeinitValid(Owner),
        .caller_provisioned => signature.provisionedOwnerDeinitValid(Owner),
    };
    if (comptime !deinit_valid) return .wrong_deinit;
    return null;
}

fn validateMethodCapabilities(
    comptime Owner: type,
    comptime expected: OwnerShape,
) ?OwnerShapeViolation {
    inline for (@typeInfo(Owner).@"struct".decl_names) |declaration_name| {
        if (comptime std.mem.eql(u8, declaration_name, "init")) continue;
        if (comptime std.mem.eql(u8, declaration_name, "activate")) continue;
        if (comptime std.mem.eql(u8, declaration_name, "deinit")) continue;
        const declaration_type = @TypeOf(@field(Owner, declaration_name));
        if (comptime @typeInfo(declaration_type) != .@"fn") continue;
        const function_info = @typeInfo(declaration_type).@"fn";
        if (comptime function_info.param_types.len == 0) continue;
        const receiver = function_info.param_types[0] orelse continue;
        if (comptime receiver != Owner and
            !signature.ownerReceiver(receiver, Owner))
        {
            continue;
        }
        inline for (function_info.param_types[1..]) |parameter_type_optional| {
            if (parameter_type_optional) |parameter_type| {
                if (ownerTypeHasAllocatorCapability(parameter_type, expected)) {
                    return .steady_allocator_parameter;
                }
            }
        }
        if (function_info.return_type) |return_type| {
            if (ownerTypeHasAllocatorCapability(return_type, expected)) {
                return .steady_allocator_result;
            }
        }
    }
    return null;
}

fn ownerTypeHasAllocatorCapability(
    comptime T: type,
    comptime expected: OwnerShape,
) bool {
    return switch (expected.storage_source) {
        .allocator_backed => capability.typeHasImmediateAllocatorCapability(T),
        .caller_provisioned => capability.typeHasAllocatorCapability(T),
    };
}

fn validateExhaustion(comptime Owner: type) ?OwnerShapeViolation {
    if (comptime !@hasDecl(Owner, "Exhaustion")) {
        return .missing_exhaustion_declaration;
    }
    if (comptime @TypeOf(Owner.Exhaustion) != type) {
        return .wrong_exhaustion_declaration;
    }
    if (comptime !signature.exhaustionSetValid(Owner.Exhaustion)) {
        return .wrong_exhaustion_declaration;
    }
    if (comptime !exhaustionObservable(Owner)) return .exhaustion_not_observable;
    return null;
}

fn validateOwnerClaim(
    comptime Owner: type,
    comptime expected: OwnerShape,
) ?OwnerShapeViolation {
    if (comptime !@hasDecl(Owner, "claim")) {
        if (expected.storage_source == .caller_provisioned) {
            return .missing_claim_declaration;
        }
        return null;
    }
    @setEvalBranchQuota(1_000_000);
    if (comptime @TypeOf(Owner.claim) != declaration.Declaration) {
        return .wrong_claim_declaration;
    }
    if (comptime declaration.validate(Owner, Owner.claim, expected) != null) {
        return .invalid_claim;
    }
    recordTypedClaim(Owner);
    return null;
}

fn recordTypedClaim(comptime Owner: type) void {
    const value = Owner.claim;
    if (comptime value.bindings.default_limits) |DefaultLimits| {
        recordTypedClaimReferences(Owner, DefaultLimits.declaration);
    } else {
        recordTypedClaimReferences(Owner, null);
    }
}

fn recordTypedClaimReferences(
    comptime Owner: type,
    comptime default_limits: anytype,
) void {
    const value = Owner.claim;
    if (comptime value.bindings.seal != null and value.bindings.teardown != null) {
        const Seal = value.bindings.seal.?.family.?;
        const Teardown = value.bindings.teardown.?.family.?;
        comptime observer.declaration(
            value,
            Owner.init,
            default_limits,
            Seal.declaration,
            value.bindings.seal.?.premise,
            Teardown.declaration,
            value.bindings.teardown.?.premise,
        );
    } else if (comptime value.bindings.seal != null) {
        const Seal = value.bindings.seal.?.family.?;
        comptime observer.declaration(
            value,
            Owner.init,
            default_limits,
            Seal.declaration,
            value.bindings.seal.?.premise,
            null,
            null,
        );
    } else if (comptime value.bindings.teardown != null) {
        const Teardown = value.bindings.teardown.?.family.?;
        comptime observer.declaration(
            value,
            Owner.init,
            default_limits,
            null,
            null,
            Teardown.declaration,
            value.bindings.teardown.?.premise,
        );
    } else {
        comptime observer.declaration(
            value,
            Owner.init,
            default_limits,
            null,
            null,
            null,
            null,
        );
    }
}

fn exhaustionObservable(comptime Owner: type) bool {
    inline for (@typeInfo(Owner).@"struct".decl_names) |declaration_name| {
        if (comptime std.mem.eql(u8, declaration_name, "init")) continue;
        if (comptime std.mem.eql(u8, declaration_name, "activate")) continue;
        if (comptime std.mem.eql(u8, declaration_name, "deinit")) continue;
        const declaration_type = @TypeOf(@field(Owner, declaration_name));
        if (comptime @typeInfo(declaration_type) != .@"fn") continue;
        const function_info = @typeInfo(declaration_type).@"fn";
        if (comptime function_info.param_types.len == 0) continue;
        if (comptime !signature.ownerReceiver(function_info.param_types[0], Owner)) continue;
        if (signature.functionReturnsExhaustion(declaration_type, Owner.Exhaustion)) return true;
    }
    return false;
}

fn workLimitsValid(limits: owner.WorkLimits) bool {
    if (limits.transition_steps_max == 0) return false;
    const cleanup_steps_zero = limits.cleanup_steps_per_call_max == 0;
    const cleanup_calls_zero = limits.cleanup_calls_at_capacity_max == 0;
    if (cleanup_steps_zero != cleanup_calls_zero) return false;
    _ = std.math.mul(
        usize,
        limits.cleanup_steps_per_call_max,
        limits.cleanup_calls_at_capacity_max,
    ) catch return false;
    return true;
}
