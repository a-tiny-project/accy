const std = @import("std");
const observer = @import("observer");
const owner = @import("owner.zig");
const spec = @import("spec.zig");

const OwnerShape = owner.OwnerShape;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// This validator limit specifies a maximum of 16 covered storage records in
/// `SourceEnvelope.storage.covered`, requiring a valid list to be non-empty.
pub const covered_max: usize = 16;
/// This validator limit defines a maximum of 16 excluded descriptive strings in
/// a valid non-empty list, without enforcing a uniqueness check.
pub const excluded_max: usize = 16;
/// This validator limit defines a maximum of 8 canonical dependency
/// identifiers, permitting an empty list.
pub const dependencies_max: usize = 8;
/// This validator limit specifies a maximum of 24 named obligation records,
/// requiring a valid list to be non-empty.
pub const obligations_max: usize = 24;
/// This validator limit specifies a maximum of 512 bytes for descriptive
/// detail, work, or exclusion text, requiring at least 1 byte and excluding
/// NUL, CR, and LF characters. This bound measures raw byte length rather than
/// Unicode character count.
pub const text_bytes_max: usize = 512;
/// This validator limit specifies a maximum of 64 bytes for canonical dotted
/// claim, dependency, or trust identifiers, under the root alias
/// `claim_id_bytes_max`.
pub const id_bytes_max: usize = 64;
/// This validator limit specifies a maximum of 64 bytes for local
/// covered-region and obligation keys, which must begin with a lowercase letter
/// followed by lowercase letters, digits, or underscores.
pub const local_id_bytes_max: usize = 64;
/// This constant defines the 32-byte SHA-256 output digest size corresponding
/// to the root alias `declaration_envelope_digest_bytes`. This value reflects
/// the fixed digest output length rather than the input envelope size.
pub const digest_bytes: usize = Sha256.digest_length;
/// This hash domain specifies the exact string
/// `tiny.alloc.claim-declaration/v2` used to separate framed format inputs. The
/// domain tag provides input framing separation but does not offer a
/// collision-proof guarantee.
pub const digest_domain = "tiny.alloc.claim-declaration/v2";

/// `Kind` specifies source classification as either `startup_static` or
/// `phase_static`. Validation of `phase_static` requires valid seal and
/// teardown bindings. In contrast, `startup_static` does not require or inspect
/// optional phase bindings in `validateBindings`. The tag describes a claim and
/// does not govern actual allocation behavior or enforce an operational
/// lifetime.
pub const Kind = enum {
    startup_static,
    phase_static,
};

/// LimitSource indicates whether memory capacity limits originate from the
/// caller or from application defaults. Selecting caller forbids supplying a
/// default_limits selector binding. Selecting application_default requires
/// supplying a selector struct containing a public declaration member. The
/// declaration validator verifies that this selector struct exists, but it
/// checks no signature or value compatibility between that declaration and the
/// owner limits.
pub const LimitSource = enum {
    caller,
    application_default,
};

/// StorageLifetime labels the operational stage of a covered storage region
/// using the initialization, steady, or transferred tags. These values provide
/// descriptive metadata about when an owner uses a memory region. The enum
/// performs no runtime lifetime tracking, memory management, or ownership
/// operations.
pub const StorageLifetime = enum {
    initialization,
    steady,
    transferred,
};

/// OverloadKind defines the policy an owner follows when an operation exceeds
/// capacity. Compatibility depends on the storage source and shape of the
/// owner. Exact shapes accept reject_before_seal or not_applicable. For
/// rejecting shapes, allocator-backed owners accept reject_before_mutation,
/// replace, drop, or terminal, while caller-provisioned owners accept only
/// reject_before_mutation. The accompanying detail string describes which
/// internal state is protected, such as allowing submitted and rejected
/// counters to increment in a full fixture. Validation checks compatibility
/// between the enum tag and the owner shape without inspecting operation
/// bodies.
pub const OverloadKind = enum {
    reject_before_seal,
    reject_before_mutation,
    replace,
    drop,
    terminal,
    not_applicable,
};

/// RiskStatus describes whether an identified hazard has evidentiary coverage
/// through the witnessed, excluded, or open tags. Setting status to witnessed
/// requires declaring a matching risk role obligation in the source envelope,
/// but it does not establish that a test passed. Setting status to excluded
/// documents that the hazard falls outside the operational scope of the claim.
/// Setting status to open documents an unresolved claim status without
/// satisfying an obligation requirement.
pub const RiskStatus = enum {
    witnessed,
    excluded,
    open,
};

/// CoveredStorage describes a discrete memory region covered by an owner claim
/// through its id, lifetime, and detail fields. The id string must contain 1 to
/// 64 bytes, starting with a lowercase ASCII letter and followed only by
/// lowercase ASCII letters, digits, or underscores. Each id must be unique
/// within the containing covered list. The lifetime field holds a
/// StorageLifetime tag, and the detail string must contain 1 to 512 single-line
/// bytes without null bytes, carriage returns, or line feeds. The struct
/// borrows these slices without owning allocations or enforcing lifetimes at
/// runtime.
pub const CoveredStorage = struct {
    id: []const u8,
    lifetime: StorageLifetime,
    detail: []const u8,
};

/// Storage specifies the memory coverage boundaries of a claim using covered
/// and excluded slices, rather than holding the backing storage buffer of an
/// owner. The covered list accepts 1 to 16 CoveredStorage records with unique
/// local identifiers. The excluded list accepts 1 to 16 descriptive strings,
/// each bounded to 1 to 512 single-line bytes excluding null bytes, carriage
/// returns, and line feeds. Excluded entries are not checked for uniqueness,
/// and their presence makes no claim that other process memory is absent. The
/// struct holds borrowed slices rather than copying text or managing memory.
pub const Storage = struct {
    covered: []const CoveredStorage,
    excluded: []const []const u8,
};

/// `Overload` describes declared overload behavior through its `kind` and
/// `detail` fields, where `detail` identifies protected state. Full declaration
/// validation checks that `kind` is compatible with `OwnerShape` and verifies
/// that `detail` contains 1 to 512 bytes excluding NUL, LF, and CR characters.
/// Merely constructing the record validates nothing and installs no dynamic
/// policy.
pub const Overload = struct {
    kind: OverloadKind,
    detail: []const u8,
};

/// Risk pairs a RiskStatus tag with a descriptive detail string explaining an
/// operational boundary hazard. The detail string must contain 1 to 512
/// single-line bytes without null characters, carriage returns, or line feeds.
/// Declaration validation inspects the detail text grammar and verifies that
/// any risk marked witnessed has a corresponding obligation role declared in
/// the source envelope. The struct retains these values as source metadata
/// without executing checks at runtime.
pub const Risk = struct {
    status: RiskStatus,
    detail: []const u8,
};

/// Risks groups the operational hazards of an owner into transitive and foreign
/// Risk records. The transitive field documents risks originating within
/// callees or subsidiary components, while the foreign field documents risks
/// arising from external resources. The descriptive details define the actual
/// scope of each hazard. Declaration validation enforces grammar and witnessed
/// obligations for both fields, but it does not compute or audit a transitive
/// closure across components.
pub const Risks = struct {
    transitive: Risk,
    foreign: Risk,
};

/// `Work` defines an `equation` field consisting of descriptive work bound text
/// between 1 and 512 bytes long, excluding NUL, LF, and CR characters. It is
/// required whenever an owner uses a caller-provisioned shape, and its presence
/// requires declaring an obligation with the work_bound role. The equation text
/// provides descriptive documentation that is neither parsed nor evaluated
/// during validation. This record differs from the WorkLimits structure, which
/// supplies concrete numeric limits.
pub const Work = struct {
    equation: []const u8,
};

/// ObligationRole classifies the evidentiary purpose of a named obligation
/// within a claim. Roles identify evidence requirements including
/// capacity_model, overload, work_bound, transitive_risk, foreign_risk, seal,
/// and teardown. Declaration validation enforces role presence rules for
/// selected source fields, requiring capacity_model for every claim, overload
/// unless overload handling is not applicable, work_bound when a work equation
/// is present, and matching risk roles when transitive or foreign risks are
/// witnessed. Assigning a role classifies the requirement within the
/// declaration but does not establish that evidence exists or that any test
/// passed.
pub const ObligationRole = enum {
    capacity_model,
    acquisition,
    initialization_failure,
    overload,
    seal,
    teardown,
    work_bound,
    transitive_risk,
    foreign_risk,
    integration,
    custom,
};

/// Obligation pairs a claim-local identifier key with an ObligationRole tag.
/// The key string must contain 1 to 64 bytes, beginning with a lowercase ASCII
/// letter and containing only lowercase letters, digits, or underscores. The
/// source envelope accepts a list of 1 to 24 obligations, and every key must be
/// unique within that list. Validation mandates the capacity_model role in
/// every claim, the overload role unless overload is not applicable,
/// appropriate risk roles for witnessed risks, and the work_bound role when a
/// work equation is declared. Keys remain local to the enclosing claim rather
/// than resolving globally.
pub const Obligation = struct {
    key: []const u8,
    role: ObligationRole,
};

/// `WitnessAnnotation` holds `claim_id` and `obligation_key` slices alongside a
/// `role` value. The `witness` operation requires `Owner.claim` to have the
/// exact type `Declaration` and verifies that the obligation key exists, but it
/// does not validate the whole claim. Passing the returned annotation to
/// `record` associates it with the enclosing test. Constructing the annotation
/// alone does not record an association with a test or prove that a test
/// passed, and it performs no test execution or assertion inspection.
pub const WitnessAnnotation = struct {
    claim_id: []const u8,
    obligation_key: []const u8,
    role: ObligationRole,
};

/// SourceEnvelope contains the primary specification metadata of a claim,
/// gathering its id, kind, limit_source, storage, capacity, overload, risks,
/// optional work, dependencies, and obligations. The `id` must be a canonical
/// identifier of 1 to 64 bytes consisting of at least two non-empty dot
/// segments composed of lowercase letters, digits, or underscores, where
/// leading digits and underscores are permitted. The `capacity` field is a
/// typed `Spec` with semantic type fields requiring a compile-time
/// representation rather than expression evaluation. The `dependencies` slice
/// accepts up to 8 canonical identifiers, rejects duplicates or
/// self-references, and performs no registry lookup or cycle analysis. The
/// envelope borrows its referenced slices rather than deep-copying runtime
/// strings.
pub const SourceEnvelope = struct {
    id: []const u8,
    kind: Kind,
    limit_source: LimitSource,
    storage: Storage,
    capacity: spec.Spec,
    overload: Overload,
    risks: Risks,
    work: ?Work = null,
    dependencies: []const []const u8 = &.{},
    obligations: []const Obligation,
};

/// EnvelopeView provides a structurally uniform representation of a
/// SourceEnvelope where the typed capacity specification is replaced by a
/// SpecView. The remaining borrowed metadata fields, including id, kind,
/// limit_source, storage, overload, risks, work, dependencies, and obligations,
/// remain identical. This view enables structural serialization and digest
/// computation without depending on semantic type coordinates. Slices
/// referenced by the view remain borrowed and are not owned by the view struct.
pub const EnvelopeView = struct {
    id: []const u8,
    kind: Kind,
    limit_source: LimitSource,
    storage: Storage,
    capacity: spec.View,
    overload: Overload,
    risks: Risks,
    work: ?Work = null,
    dependencies: []const []const u8 = &.{},
    obligations: []const Obligation,
};

/// PremiseClass names the form of basis that supports a phase binding. Its tags
/// distinguish between mathematical theorem domains, checked semantic or path
/// facts, certified claim summaries, and trusted user, external, or environment
/// assertions. Selecting a tag identifies the expected authority category
/// during premise validation, but the enum itself does not establish or
/// evaluate the underlying evidence.
pub const PremiseClass = enum {
    theorem_domain,
    checked_semantic_fact,
    checked_path_fact,
    certified_summary,
    trusted_user,
    trusted_extern,
    trusted_environment,
};

/// ObligationSelector identifies a claim-local obligation that grounds a
/// theorem premise through its key field. Validation checks that the key is a
/// valid local identifier and that it matches an obligation declared in the
/// current source envelope. The check enforces no role restriction on the
/// targeted obligation and performs no evaluation of the theorem.
pub const ObligationSelector = struct {
    key: []const u8,
};

/// ClaimSelector designates an external claim supporting a certified summary
/// premise through its id field. Validation confirms that the id string
/// satisfies the syntax of a canonical dotted identifier containing at least
/// two segments. The check verifies identifier syntax only and does not look up
/// or confirm the existence of the referenced claim.
pub const ClaimSelector = struct {
    id: []const u8,
};

/// TrustDeclarationSelector identifies a trust declaration supporting a trusted
/// user, external component, or environment premise through its id field.
/// Validation checks that the id string conforms to canonical dotted identifier
/// syntax. The validator performs no resolution of the external identifier and
/// does not validate the underlying trust declaration.
pub const TrustDeclarationSelector = struct {
    id: []const u8,
};

/// PremiseAuthority specifies the justifying source for a premise as a tagged
/// union over checker, theorem, certified_claim, and trusted variants. Each
/// variant carries its respective selector, except checker, which carries no
/// payload. The authority must pair with a compatible PremiseClass during
/// validation: checker requires checked_semantic_fact or checked_path_fact,
/// theorem requires theorem_domain, certified_claim requires certified_summary,
/// and trusted requires trusted_user, trusted_extern, or trusted_environment.
pub const PremiseAuthority = union(enum) {
    checker,
    theorem: ObligationSelector,
    certified_claim: ClaimSelector,
    trusted: TrustDeclarationSelector,
};

/// Premise pairs a PremiseClass category with a PremiseAuthority variant to
/// justify a phase lifecycle binding. The validatePremise function checks that
/// the class and authority are mutually compatible, that selector identifiers
/// follow required canonical or local syntax, and that local theorem keys exist
/// within the source obligations. Validation confirms structural and syntactic
/// compatibility but produces no proof of the underlying fact.
pub const Premise = struct {
    class: PremiseClass,
    authority: PremiseAuthority,
};

/// PhaseBinding associates a lifecycle transition with an implementation seam
/// and an evidentiary premise through its family and premise fields. Both
/// fields default to null, but validating a phase_static declaration requires
/// both to be present. The family field must be a selector struct containing a
/// public declaration member that resolves to a function. Validation does not
/// inspect the function signature or body, nor does it require the function to
/// match Owner.activate or Owner.deinit. The struct stores compile-time type
/// and premise descriptors rather than a runtime callable closure.
pub const PhaseBinding = struct {
    family: ?type = null,
    premise: ?Premise = null,
};

/// Bindings gathers compile-time type coordinates and lifecycle phase bindings
/// separate from the source envelope. Fields include owner, default_limits,
/// seal, teardown, and source, which all default to null. Validation requires
/// owner to match the Owner type supplied to validateDeclaration. The
/// default_limits binding is required for application_default limit sources and
/// forbidden for caller limit sources, while seal and teardown bindings are
/// required for phase_static declarations. The optional source type is retained
/// as metadata but is not inspected by the validator. Envelope digests exclude
/// all bindings and premises, and the struct owns no heap memory or reference
/// counts.
pub const Bindings = struct {
    owner: ?type = null,
    default_limits: ?type = null,
    seal: ?PhaseBinding = null,
    teardown: ?PhaseBinding = null,
    source: ?type = null,
};

/// Declaration couples a SourceEnvelope specification with its corresponding
/// compile-time Bindings. The struct acts as a typed metadata container rather
/// than a runtime resource allocation. Calling validateDeclaration checks the
/// declaration against a specified Owner type, expected OwnerShape, and source
/// constraints, but validating a declaration does not verify the whole owner
/// shape by itself. Constructing or validating a declaration installs no
/// automatic runtime enforcement.
pub const Declaration = struct {
    source: SourceEnvelope,
    bindings: Bindings,
};

/// Violation enumerates the failure categories returned by the source
/// declaration validator. When validation fails, the validator returns the
/// first detected violation category rather than reporting a runtime allocation
/// error. Malformed user types supplied in bindings may trigger Zig compile
/// errors before validation completes. In root.zig, this type is exported under
/// the public alias DeclarationViolation.
pub const Violation = enum {
    id_format,
    storage_covered_missing,
    storage_covered_overflow,
    storage_region_id_invalid,
    storage_region_duplicate,
    storage_detail_invalid,
    storage_excluded_missing,
    storage_excluded_overflow,
    storage_excluded_invalid,
    capacity_limits_mismatch,
    capacity_field_path_invalid,
    capacity_type_selector_invalid,
    capacity_node_outside_fragment,
    capacity_assertion_invalid,
    overload_detail_invalid,
    overload_shape_incompatible,
    risk_detail_invalid,
    risk_obligation_missing,
    work_missing,
    work_equation_invalid,
    work_obligation_missing,
    dependencies_overflow,
    dependency_format,
    dependency_duplicate,
    dependency_self,
    obligations_missing,
    obligations_overflow,
    obligation_key_invalid,
    obligation_key_duplicate,
    capacity_model_obligation_missing,
    overload_obligation_missing,
    owner_binding_missing,
    owner_binding_mismatch,
    default_limits_binding_missing,
    default_limits_binding_unexpected,
    default_limits_binding_invalid,
    seal_binding_missing,
    teardown_binding_missing,
    seam_family_missing,
    seam_family_invalid,
    premise_missing,
    premise_authority_mismatch,
    premise_selector_invalid,
    premise_obligation_unknown,
};

/// selector takes any compile-time value and returns an anonymous struct type
/// containing a public constant named declaration initialized to that value.
/// This helper allows compile-time type fields to transport typed references
/// and values. The requirement that declaration resolve to a function is not
/// checked by selector itself, but is imposed only when validating a phase
/// binding family. The function neither validates the wrapped value nor creates
/// a callable runtime closure.
pub fn selector(comptime value: anytype) type {
    return struct {
        pub const declaration = value;
    };
}

/// sourceView is an internal implementation function in declaration.zig that
/// converts a compile-time SourceEnvelope into an EnvelopeView, and it is not
/// exported from root.zig. It converts the typed capacity specification into a
/// SpecView using spec.view, transforming typed inputs and type selectors into
/// stable compile-time views while omitting semantic limit types and selected
/// type facts. Other source slices and metadata fields are transferred directly
/// into the view. The function performs no validation on the converted
/// envelope.
pub fn sourceView(comptime value: SourceEnvelope) EnvelopeView {
    return .{
        .id = value.id,
        .kind = value.kind,
        .limit_source = value.limit_source,
        .storage = value.storage,
        .capacity = spec.view(value.capacity),
        .overload = value.overload,
        .risks = value.risks,
        .work = value.work,
        .dependencies = value.dependencies,
        .obligations = value.obligations,
    };
}

/// envelopeDigest hashes the content of an EnvelopeView using SHA-256 under the
/// domain tiny.alloc.claim-declaration/v2, and is exported from root.zig as
/// declarationSourceEnvelopeDigest. The digest builder length-frames every
/// field and ordered list element, incorporating storage details, the capacity
/// specification digest, overload policy, risks, optional work equations,
/// dependencies, and obligations. Because the view contains no bindings, all
/// typed bindings and premises are excluded from the digest. The function
/// performs no validation or formal proof, requiring callers to provide a valid
/// bounded view.
pub fn envelopeDigest(value: EnvelopeView) [digest_bytes]u8 {
    var builder = DigestBuilder.init();
    builder.addBytes("id", value.id);
    builder.addEnum("kind", value.kind);
    builder.addEnum("limit_source", value.limit_source);
    addStorage(&builder, value.storage);
    builder.addDigest("capacity", spec.digest(value.capacity));
    addOverload(&builder, value.overload);
    addRisk(&builder, "transitive", value.risks.transitive);
    addRisk(&builder, "foreign", value.risks.foreign);
    addWork(&builder, value.work);
    addTextList(&builder, "dependencies", value.dependencies);
    addObligations(&builder, value.obligations);
    return builder.finish();
}

/// declarationEnvelopeDigest computes the digest of a compile-time Declaration
/// by converting its source envelope through sourceView and hashing the
/// resulting EnvelopeView with envelopeDigest. Because the view omits bindings,
/// changes to bindings such as the owner type, seam functions, or premises do
/// not affect the digest. The underlying capacity digest also omits semantic
/// types and sizing facts. The resulting hash establishes a content identity
/// for selected source specification fields rather than an identity for the
/// whole implementation or its evidence.
pub fn declarationEnvelopeDigest(comptime value: Declaration) [digest_bytes]u8 {
    return envelopeDigest(sourceView(value.source));
}

/// validate evaluates a compile-time Declaration against an Owner type and an
/// OwnerShape, returning the first detected Violation or null if validation
/// passes, and is exported from root.zig as validateDeclaration. It checks
/// identifier syntax, storage limits, the typed capacity specification against
/// Owner.Limits, overload compatibility and detail text, risks, work equations,
/// dependencies, obligations, and bindings. The function does not run the owner
/// shape validator or record observer claims. Returning null
/// indicates only that the declaration metadata is valid. The Owner type must
/// define a Limits type compatible with the capacity specification, and the
/// function makes no promise of universal safety for arbitrary type
/// introspection.
pub fn validate(
    comptime Owner: type,
    comptime value: Declaration,
    comptime shape: OwnerShape,
) ?Violation {
    if (!identifierValid(value.source.id)) return .id_format;
    if (validateStorage(value.source.storage)) |violation| return violation;
    if (spec.validate(Owner.Limits, value.source.capacity)) |violation| {
        return capacityViolation(violation);
    }
    if (!textValid(value.source.overload.detail)) {
        return .overload_detail_invalid;
    }
    if (!overloadCompatible(value.source.overload.kind, shape)) {
        return .overload_shape_incompatible;
    }
    if (validateRisk(value.source.risks.transitive)) |violation| return violation;
    if (validateRisk(value.source.risks.foreign)) |violation| return violation;
    if (validateWork(value.source.work, shape)) |violation| return violation;
    if (validateDependencies(value.source)) |violation| return violation;
    if (validateObligations(value.source)) |violation| return violation;
    if (validateBindings(Owner, value)) |violation| return violation;
    return null;
}

/// require is a public function within declaration.zig that is not re-exported
/// from root.zig. It executes the same compile-time checks as validate, but it
/// sets the evaluation branch quota to 1,000,000 and emits a compile error
/// containing the violation tag name upon failure instead of returning an
/// optional value. The function performs validation enforcement during
/// compilation and does not record claim metadata or test annotations.
pub fn require(
    comptime Owner: type,
    comptime value: Declaration,
    comptime shape: OwnerShape,
) void {
    @setEvalBranchQuota(1_000_000);
    if (comptime validate(Owner, value, shape)) |violation| {
        @compileError("invalid claim declaration: " ++ @tagName(violation));
    }
}

/// witness extracts a WitnessAnnotation for a specified Owner type and
/// obligation key at compile time. It requires that Owner declare a public
/// member named claim whose type is exactly Declaration, and that the
/// obligation key exists within the claim obligations list, failing compilation
/// if either condition is not met. It returns a WitnessAnnotation containing
/// the claim id, obligation key, and associated obligation role from the source
/// envelope. The function does not run full declaration validation, inspect
/// test logic, or execute tests.
pub fn witness(
    comptime Owner: type,
    comptime obligation_key: []const u8,
) WitnessAnnotation {
    if (comptime !@hasDecl(Owner, "claim") or
        @TypeOf(Owner.claim) != Declaration)
    {
        @compileError("test obligation owner lacks a typed claim declaration");
    }
    const role = comptime obligationRole(
        Owner.claim.source.obligations,
        obligation_key,
    ) orelse @compileError("test obligation key is not declared by its owner");
    return .{
        .claim_id = Owner.claim.source.id,
        .obligation_key = obligation_key,
        .role = role,
    };
}

/// `record` enters a witness annotation into the Stardust claim table for the
/// enclosing test. It is `inline`, so the test stays the compiler's analysis
/// owner and the recorded row names that test even outside `comptime`. Without
/// the Stardust observer, as under an unpatched compiler or in a release, the
/// call records nothing, while `witness` still checks the obligation key.
pub inline fn record(comptime annotation: WitnessAnnotation) void {
    comptime observer.witness(annotation);
}

/// `validatePremise` accepts a compile-time `SourceEnvelope` and premise pair
/// and returns the first optional `Violation` or null. It checks classification
/// and authority compatibility between the supplied entities. For `theorem`,
/// the function validates the local key and its existence in source obligations
/// without applying role restrictions. Both `certified_claim` and `trusted`
/// validate canonical `id` syntax without performing a registry lookup. The
/// function does not validate the whole `SourceEnvelope` or inspect underlying
/// evidence.
pub fn validatePremise(
    comptime source: SourceEnvelope,
    comptime premise: Premise,
) ?Violation {
    if (!premiseAuthorityCompatible(premise)) {
        return .premise_authority_mismatch;
    }
    switch (premise.authority) {
        .checker => {},
        .theorem => |selected| {
            if (!localIdentifierValid(selected.key)) {
                return .premise_selector_invalid;
            }
            if (!obligationKnown(source.obligations, selected.key)) {
                return .premise_obligation_unknown;
            }
        },
        .certified_claim => |selected| {
            if (!identifierValid(selected.id)) {
                return .premise_selector_invalid;
            }
        },
        .trusted => |selected| {
            if (!identifierValid(selected.id)) {
                return .premise_selector_invalid;
            }
        },
    }
    return null;
}

/// declareWarmRetained declares a weak capacity owner associated with warm
/// retained memory. It checks at compile time that the provided id satisfies
/// canonical dotted identifier syntax and discards the Owner type parameter.
/// The function records no observer claims and performs no actual
/// retention policy, owner shape, or capacity bound checks.
pub fn declareWarmRetained(comptime id: []const u8, comptime Owner: type) void {
    requireCanonicalId(id);
    _ = Owner;
}

/// The current implementation of `declareDynamicUnbounded` checks a canonical
/// dotted `id` at compile time and discards `Owner`. It does not inspect
/// whether `Owner` actually allocates, install behavior, record observer
/// metadata, or register a proven bound.
pub fn declareDynamicUnbounded(comptime id: []const u8, comptime Owner: type) void {
    requireCanonicalId(id);
    _ = Owner;
}

fn validateStorage(storage: Storage) ?Violation {
    if (storage.covered.len == 0) return .storage_covered_missing;
    if (storage.covered.len > covered_max) return .storage_covered_overflow;
    for (storage.covered, 0..) |region, index| {
        if (!localIdentifierValid(region.id)) return .storage_region_id_invalid;
        if (!textValid(region.detail)) return .storage_detail_invalid;
        for (storage.covered[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, region.id)) {
                return .storage_region_duplicate;
            }
        }
    }
    if (storage.excluded.len == 0) return .storage_excluded_missing;
    if (storage.excluded.len > excluded_max) return .storage_excluded_overflow;
    for (storage.excluded) |excluded| {
        if (!textValid(excluded)) return .storage_excluded_invalid;
    }
    return null;
}

fn obligationRole(
    comptime obligations: []const Obligation,
    comptime key: []const u8,
) ?ObligationRole {
    for (obligations) |obligation| {
        if (std.mem.eql(u8, obligation.key, key)) return obligation.role;
    }
    return null;
}

fn capacityViolation(violation: spec.Violation) Violation {
    return switch (violation) {
        .limits_type_mismatch => .capacity_limits_mismatch,
        .input_field_path_invalid => .capacity_field_path_invalid,
        .type_selector_overflow,
        .type_selector_id_invalid,
        .type_selector_id_duplicate,
        .type_selector_fact_invalid,
        => .capacity_type_selector_invalid,
        .node_outside_fragment => .capacity_node_outside_fragment,
        else => .capacity_assertion_invalid,
    };
}

fn validateRisk(risk: Risk) ?Violation {
    if (!textValid(risk.detail)) return .risk_detail_invalid;
    return null;
}

fn validateWork(work: ?Work, shape: OwnerShape) ?Violation {
    const value = work orelse {
        if (shape.storage_source == .caller_provisioned) return .work_missing;
        return null;
    };
    if (!textValid(value.equation)) return .work_equation_invalid;
    return null;
}

fn validateDependencies(source: SourceEnvelope) ?Violation {
    if (source.dependencies.len > dependencies_max) return .dependencies_overflow;
    for (source.dependencies, 0..) |dependency, index| {
        if (!identifierValid(dependency)) return .dependency_format;
        if (std.mem.eql(u8, dependency, source.id)) return .dependency_self;
        for (source.dependencies[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, dependency)) return .dependency_duplicate;
        }
    }
    return null;
}

fn validateObligations(source: SourceEnvelope) ?Violation {
    if (source.obligations.len == 0) return .obligations_missing;
    if (source.obligations.len > obligations_max) return .obligations_overflow;
    for (source.obligations, 0..) |obligation, index| {
        if (!localIdentifierValid(obligation.key)) return .obligation_key_invalid;
        for (source.obligations[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.key, obligation.key)) {
                return .obligation_key_duplicate;
            }
        }
    }
    if (!obligationRoleKnown(source.obligations, .capacity_model)) {
        return .capacity_model_obligation_missing;
    }
    if (source.overload.kind != .not_applicable and
        !obligationRoleKnown(source.obligations, .overload))
    {
        return .overload_obligation_missing;
    }
    if (source.risks.transitive.status == .witnessed and
        !obligationRoleKnown(source.obligations, .transitive_risk))
    {
        return .risk_obligation_missing;
    }
    if (source.risks.foreign.status == .witnessed and
        !obligationRoleKnown(source.obligations, .foreign_risk))
    {
        return .risk_obligation_missing;
    }
    if (source.work != null and
        !obligationRoleKnown(source.obligations, .work_bound))
    {
        return .work_obligation_missing;
    }
    return null;
}

fn validateBindings(comptime Owner: type, comptime value: Declaration) ?Violation {
    const bindings = value.bindings;
    const bound_owner = bindings.owner orelse return .owner_binding_missing;
    if (bound_owner != Owner) return .owner_binding_mismatch;
    switch (value.source.limit_source) {
        .caller => if (bindings.default_limits != null) {
            return .default_limits_binding_unexpected;
        },
        .application_default => {
            const Selector = bindings.default_limits orelse {
                return .default_limits_binding_missing;
            };
            if (!selectorValid(Selector)) return .default_limits_binding_invalid;
        },
    }
    if (value.source.kind == .phase_static) {
        const seal = bindings.seal orelse return .seal_binding_missing;
        const teardown = bindings.teardown orelse return .teardown_binding_missing;
        if (validatePhaseBinding(value.source, seal)) |violation| return violation;
        if (validatePhaseBinding(value.source, teardown)) |violation| return violation;
    }
    return null;
}

fn validatePhaseBinding(
    comptime source: SourceEnvelope,
    comptime binding: PhaseBinding,
) ?Violation {
    const Family = binding.family orelse return .seam_family_missing;
    if (!selectorValid(Family)) return .seam_family_invalid;
    if (@typeInfo(@TypeOf(Family.declaration)) != .@"fn") {
        return .seam_family_invalid;
    }
    const premise = binding.premise orelse return .premise_missing;
    return validatePremise(source, premise);
}

fn selectorValid(comptime Selector: type) bool {
    return @typeInfo(Selector) == .@"struct" and
        @hasDecl(Selector, "declaration");
}

fn premiseAuthorityCompatible(premise: Premise) bool {
    return switch (premise.authority) {
        .checker => premise.class == .checked_semantic_fact or
            premise.class == .checked_path_fact,
        .theorem => premise.class == .theorem_domain,
        .certified_claim => premise.class == .certified_summary,
        .trusted => premise.class == .trusted_user or
            premise.class == .trusted_extern or
            premise.class == .trusted_environment,
    };
}

fn overloadCompatible(kind: OverloadKind, shape: OwnerShape) bool {
    return switch (shape.storage_source) {
        .allocator_backed => switch (shape.overload_shape) {
            .exact => kind == .reject_before_seal or kind == .not_applicable,
            .rejecting => switch (kind) {
                .reject_before_mutation, .replace, .drop, .terminal => true,
                else => false,
            },
        },
        .caller_provisioned => switch (shape.overload_shape) {
            .exact => kind == .reject_before_seal or kind == .not_applicable,
            .rejecting => kind == .reject_before_mutation,
        },
    };
}

fn obligationKnown(obligations: []const Obligation, key: []const u8) bool {
    for (obligations) |obligation| {
        if (std.mem.eql(u8, obligation.key, key)) return true;
    }
    return false;
}

fn obligationRoleKnown(
    obligations: []const Obligation,
    role: ObligationRole,
) bool {
    for (obligations) |obligation| {
        if (obligation.role == role) return true;
    }
    return false;
}

fn localIdentifierValid(value: []const u8) bool {
    if (value.len == 0 or value.len > local_id_bytes_max) return false;
    if (value[0] < 'a' or value[0] > 'z') return false;
    for (value[1..]) |byte| {
        const lower = byte >= 'a' and byte <= 'z';
        const digit = byte >= '0' and byte <= '9';
        if (!lower and !digit and byte != '_') return false;
    }
    return true;
}

/// identifierValid checks whether a byte slice adheres to canonical dotted
/// identifier grammar, returning true on success. The slice must contain 1 to
/// 64 bytes divided into at least two non-empty segments separated by dots.
/// Segment characters are restricted to lowercase ASCII letters, digits, and
/// underscores, and segments may begin with a digit or underscore. The function
/// validates canonical identifier syntax only, without performing external
/// registry lookups or enforcing claim-local key grammar.
pub fn identifierValid(id: []const u8) bool {
    if (id.len == 0 or id.len > id_bytes_max) return false;
    var segments: usize = 1;
    var segment_length: usize = 0;
    for (id) |byte| {
        if (byte == '.') {
            if (segment_length == 0) return false;
            segments += 1;
            segment_length = 0;
            continue;
        }
        const lower = byte >= 'a' and byte <= 'z';
        const digit = byte >= '0' and byte <= '9';
        if (!lower and !digit and byte != '_') return false;
        segment_length += 1;
    }
    return segment_length != 0 and segments >= 2;
}

fn textValid(value: []const u8) bool {
    if (value.len == 0 or value.len > text_bytes_max) return false;
    for (value) |byte| {
        if (byte == 0 or byte == '\n' or byte == '\r') return false;
    }
    return true;
}

fn requireCanonicalId(comptime id: []const u8) void {
    if (comptime !identifierValid(id)) {
        @compileError("invalid memory owner id: " ++ id);
    }
}

const DigestBuilder = struct {
    state: Sha256,

    fn init() DigestBuilder {
        var result = DigestBuilder{ .state = Sha256.init(.{}) };
        result.addFramed(digest_domain);
        return result;
    }

    fn addBytes(self: *DigestBuilder, name: []const u8, value: []const u8) void {
        self.addFramed(name);
        self.addFramed(value);
    }

    fn addEnum(self: *DigestBuilder, name: []const u8, value: anytype) void {
        self.addBytes(name, @tagName(value));
    }

    fn addCount(self: *DigestBuilder, name: []const u8, value: usize) void {
        self.addFramed(name);
        self.addU64(value);
    }

    fn addDigest(
        self: *DigestBuilder,
        name: []const u8,
        value: [digest_bytes]u8,
    ) void {
        self.addBytes(name, &value);
    }

    fn addU64(self: *DigestBuilder, value: u64) void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .little);
        self.addFramed(&encoded);
    }

    fn finish(self: *DigestBuilder) [digest_bytes]u8 {
        var result: [digest_bytes]u8 = undefined;
        self.state.final(&result);
        return result;
    }

    fn addFramed(self: *DigestBuilder, value: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, value.len, .little);
        self.state.update(&length);
        self.state.update(value);
    }
};

fn addStorage(builder: *DigestBuilder, storage: Storage) void {
    builder.addCount("covered", storage.covered.len);
    for (storage.covered) |region| {
        builder.addBytes("region_id", region.id);
        builder.addEnum("lifetime", region.lifetime);
        builder.addBytes("detail", region.detail);
    }
    addTextList(builder, "excluded", storage.excluded);
}

fn addOverload(builder: *DigestBuilder, overload: Overload) void {
    builder.addEnum("overload_kind", overload.kind);
    builder.addBytes("overload_detail", overload.detail);
}

fn addRisk(builder: *DigestBuilder, name: []const u8, risk: Risk) void {
    builder.addBytes("risk", name);
    builder.addEnum("risk_status", risk.status);
    builder.addBytes("risk_detail", risk.detail);
}

fn addWork(builder: *DigestBuilder, work: ?Work) void {
    builder.addCount("work", @intFromBool(work != null));
    if (work) |value| builder.addBytes("work_equation", value.equation);
}

fn addTextList(
    builder: *DigestBuilder,
    name: []const u8,
    values: []const []const u8,
) void {
    builder.addCount(name, values.len);
    for (values) |value| builder.addBytes("item", value);
}

fn addObligations(builder: *DigestBuilder, values: []const Obligation) void {
    builder.addCount("obligations", values.len);
    for (values) |value| {
        builder.addBytes("obligation_key", value.key);
        builder.addEnum("obligation_role", value.role);
    }
}

const PremiseTestSource = SourceEnvelope{
    .id = "test.premises",
    .kind = .phase_static,
    .limit_source = .caller,
    .storage = .{
        .covered = &.{.{
            .id = "state",
            .lifetime = .steady,
            .detail = "test state",
        }},
        .excluded = &.{"caller values"},
    },
    .capacity = .{
        .inputs = &.{},
        .nodes = &.{.{ .constant = 1 }},
        .assertions = &.{.{
            .scope = .closure_total,
            .measure = .retained,
            .relation = .exact,
            .expression = 0,
        }},
    },
    .overload = .{
        .kind = .reject_before_seal,
        .detail = "test admission rejects",
    },
    .risks = .{
        .transitive = .{ .status = .open, .detail = "test callees remain open" },
        .foreign = .{ .status = .open, .detail = "test foreign state remains open" },
    },
    .obligations = &.{
        .{ .key = "capacity", .role = .capacity_model },
        .{ .key = "overload", .role = .overload },
        .{ .key = "theorem", .role = .seal },
    },
};

test "premise declarations cover every authority class" {
    const premises = [_]Premise{
        .{ .class = .theorem_domain, .authority = .{
            .theorem = .{ .key = "theorem" },
        } },
        .{ .class = .checked_semantic_fact, .authority = .checker },
        .{ .class = .checked_path_fact, .authority = .checker },
        .{ .class = .certified_summary, .authority = .{
            .certified_claim = .{ .id = "other.claim" },
        } },
        .{ .class = .trusted_user, .authority = .{
            .trusted = .{ .id = "trust.user" },
        } },
        .{ .class = .trusted_extern, .authority = .{
            .trusted = .{ .id = "trust.extern" },
        } },
        .{ .class = .trusted_environment, .authority = .{
            .trusted = .{ .id = "trust.environment" },
        } },
    };
    inline for (premises) |premise| {
        try std.testing.expect(validatePremise(PremiseTestSource, premise) == null);
    }
}

test "premise declarations reject unknown obligations" {
    const premise = Premise{
        .class = .theorem_domain,
        .authority = .{ .theorem = .{ .key = "missing" } },
    };
    try std.testing.expectEqual(
        Violation.premise_obligation_unknown,
        validatePremise(PremiseTestSource, premise).?,
    );
}

test "claim declaration envelope excludes typed binding coordinates" {
    const digest = envelopeDigest(sourceView(PremiseTestSource));
    comptime var changed = PremiseTestSource;
    changed.overload.detail = "changed overload intent";
    const changed_digest = envelopeDigest(sourceView(changed));
    try std.testing.expect(!std.mem.eql(u8, &digest, &changed_digest));
}

test "weak capacity owners use the canonical declaration API" {
    const Warm = struct {};
    const Dynamic = struct {};
    comptime {
        declareWarmRetained("test.warm", Warm);
        declareDynamicUnbounded("test.dynamic", Dynamic);
    }
}
