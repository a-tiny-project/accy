//! ## Package overview
//!
//! A component can prepare storage before repeated operations, specify a
//! response when demand exceeds that storage, and state which resources its
//! budget covers. The alloc_phase.capacity module supplies type checks and
//! declarations for that purpose. Separate runtime phase allocator guards
//! detect allocator operations routed through their handles. This module checks
//! structures and declarations rather than enforcing actual numerical bounds.
//!
//! ## The two axes of owner shape
//!
//! Storage arrives either through an allocator passed to initialization, called
//! `allocator_backed`, or via aligned bytes supplied by the caller, called
//! `caller_provisioned`. Alongside this storage choice, `OwnerShape` classifies
//! the overload interface as either `exact` or `rejecting`. The four constants
//! are OwnerShape.allocator_exact, OwnerShape.allocator_rejecting,
//! OwnerShape.provisioned_exact, and OwnerShape.provisioned_rejecting. An exact
//! classification indicates only that the validator does not require an
//! Exhaustion declaration, which does not guarantee that workloads will always
//! fit or that all methods will succeed. A rejecting classification requires
//! Owner.Exhaustion to be a finite nonempty error set, and at least one
//! non-lifecycle pointer-receiver owner method must return that set directly or
//! return an error union containing it. These classifications serve as
//! interface checks and do not prove error reachability or validate a sizing
//! equation.
//!
//! Each owner shape requires `Owner.Limits` and `Owner.Capacity` declarations
//! plus runtime phase and capacity fields. The nested `Capacity` type provides
//! `Capacity.derive`, whereas `init`, `activate`, and `deinit` are methods of
//! the owner itself. Provisioned owners additionally require a Storage
//! declaration representing an aligned mutable byte slice, a stored
//! storage:Storage field, a runtime Capacity.storage_bytes field of type usize,
//! work_limits, and claim. For provisioned owners, derive and init signatures
//! return finite nonempty error unions, activate returns void, and deinit
//! returns Storage. Allocator-backed owners may omit claim. These signatures do
//! not establish that activate terminates successfully or that deinit returns
//! the original bytes. The caller retains responsibility for storage lifetime,
//! while actual implementation logic and supporting evidence determine runtime
//! behavior.
//!
//! Shape validation inspects field types and receiver-method signatures to
//! detect visible allocator capabilities. The scanning depth differs across
//! owner variants: the immediate scanner applied to allocator-backed types
//! inspects only shallow struct fields and method signatures, whereas the
//! recursive scanner applied to caller-provisioned owners traverses nested
//! definitions, including fields within `Limits` and `Capacity`. For example, a
//! struct containing a borrowed pointer to an inner struct with an `Allocator`
//! field passes the immediate scanner undetected but is caught by the recursive
//! scanner. These static inspections examine type declarations rather than
//! analyzing function bodies, tracking global state, or inspecting targets
//! behind type-erased pointers.
//!
//! ## Storage ownership and rejection
//!
//! The next example configures the public ProvisionedRejectingFixture with two
//! slots of two bytes inside caller-owned four-byte storage aligned to the
//! requirement of the fixture. The sequence initializes the fixture, activates
//! it, fills both slots, and then attempts a third submission. The test checks
//! for the Full error, verifies that the payload and the used count remain
//! unchanged, and inspects updated diagnostic counters.
//!
//! ```zig
//! const std = @import("std");
//! const capacity = @import("alloc_phase").capacity;
//!
//! test "caller storage ownership and rejection behavior" {
//!     comptime capacity.requireProvisionedRejectingOwnerShape(
//!         capacity.ProvisionedRejectingFixture,
//!     );
//!
//!     const limits = capacity.ProvisionedRejectingFixture.Limits{
//!         .slots = 2,
//!         .slot_bytes = 2,
//!     };
//!
//!     var buffer: [4]u8 align(capacity.ProvisionedRejectingFixture.storage_alignment) = @splat(0);
//!
//!     var owner = try capacity.ProvisionedRejectingFixture.init(&buffer, limits);
//!     owner.activate();
//!     defer _ = owner.deinit();
//!
//!     try owner.submit(0x11);
//!     try owner.submit(0x22);
//!
//!     const snapshot_buffer = buffer;
//!     const snapshot_used = owner.used;
//!     try std.testing.expectEqual(@as(usize, 2), snapshot_used);
//!
//!     try std.testing.expectError(error.Full, owner.submit(0x33));
//!
//!     try std.testing.expectEqualSlices(u8, &snapshot_buffer, &buffer);
//!     try std.testing.expectEqual(snapshot_used, owner.used);
//!     try std.testing.expectEqual(@as(usize, 3), owner.usage.submitted);
//!     try std.testing.expectEqual(@as(usize, 2), owner.usage.accepted);
//!     try std.testing.expectEqual(@as(usize, 1), owner.usage.rejected);
//!
//!     try std.testing.expect(owner.cleanupOne());
//!     try std.testing.expectEqual(@as(usize, 1), owner.used);
//!     try std.testing.expectEqual(@as(u8, 0x11), buffer[0]);
//!     try std.testing.expectEqual(@as(u8, 0x11), buffer[1]);
//!     try std.testing.expectEqual(@as(u8, 0), buffer[2]);
//!     try std.testing.expectEqual(@as(u8, 0), buffer[3]);
//! }
//! ```
//!
//! In this fixture, returning Full updates submitted and rejected counters
//! while preserving the payload and the used count. If AccountingOverflow
//! occurs, it returns before these counter changes take place. The
//! reject_before_mutation claim applies to the protected payload rather than
//! every field on the owner. Calling cleanupOne removes and zeroes one slot
//! without altering the owner.usage field, which has type Usage. The deinit
//! method returns the whole original slice and invalidates the owner without
//! automatically calling cleanupOne. The caller must keep backing storage alive
//! throughout this lifecycle. The declared cleanup call bound does not measure
//! CPU time, because zeroing work depends on slot_bytes.
//!
//! ## Capacity specifications and expression graphs
//!
//! A storage formula is structured as a `Spec` expression graph tied directly
//! to fields declared in an owner's `Limits` type. Within this directed graph,
//! `bindInput` resolves a named field path into a typed ordinal path within the
//! limits structure, while `bindType` registers static sizing facts for
//! associated data types. Every node references only predecessor nodes created
//! earlier in the sequence. For instance, expressing an `n + 1` byte bound
//! requires an input node representing `n`, an integer constant node
//! representing `1`, and an addition node referencing both predecessors. Sizing
//! assertions select a target quantity and declare either an exact match or an
//! upper-bound relation against the expression result. The package has no
//! expression evaluator, and arithmetic helpers are not how the graph is
//! evaluated. Implementations can separately use checked add and mul helpers,
//! which return error.CapacityOverflow when integer arithmetic overflows.
//!
//! A capacity `Declaration` places the sizing formula inside a `SourceEnvelope`
//! that records which resources the budget covers and excludes, the overload
//! strategy, risk classifications, obligation keys with their verification
//! roles, and optional work equations or dependencies. In parallel, a separate
//! `Bindings` record associates the owner type with default limits and
//! lifecycle function selectors. Owners operating under `phase_static`
//! lifecycles require explicit `seal` and `teardown` selectors within their
//! bindings, whereas `startup_static` owners omit these requirements.
//! Work.equation provides descriptive text and WorkLimits contains checked
//! literal bounds. Evidence about the implementation, including analysis or
//! suitable tests, is still needed to support the stated work bound.
//!
//! ```zig
//! const std = @import("std");
//! const capacity = @import("alloc_phase").capacity;
//!
//! test "authoring a claim declaration and verifying checked arithmetic" {
//!     const Owner = struct {
//!         pub const Limits = struct {
//!             message_bytes: usize,
//!         };
//!     };
//!
//!     const claim = comptime capacity.Declaration{
//!         .source = .{
//!             .id = "sample.pedagogic_owner",
//!             .kind = .startup_static,
//!             .limit_source = .caller,
//!             .storage = .{
//!                 .covered = &.{
//!                     .{
//!                         .id = "buffer",
//!                         .lifetime = .steady,
//!                         .detail = "message framing buffer",
//!                     },
//!                 },
//!                 .excluded = &.{
//!                     "operating system process arguments",
//!                     "network socket kernel buffers",
//!                 },
//!             },
//!             .capacity = .{
//!                 .inputs = &.{
//!                     capacity.bindInput(Owner.Limits, "message_bytes", "message_bytes"),
//!                 },
//!                 .type_selectors = &.{},
//!                 .nodes = &.{
//!                     .{ .input = 0 },
//!                     .{ .constant = 1 },
//!                     .{ .add = .{ .left = 0, .right = 1 } },
//!                 },
//!                 .assertions = &.{
//!                     .{
//!                         .scope = .closure_total,
//!                         .measure = .retained,
//!                         .relation = .exact,
//!                         .expression = 2,
//!                     },
//!                 },
//!             },
//!             .overload = .{
//!                 .kind = .reject_before_seal,
//!                 .detail = "rejects limits exceeding addressable memory before activation",
//!             },
//!             .risks = .{
//!                 .transitive = .{
//!                     .status = .open,
//!                     .detail = "callee allocations remain outside this owner claim",
//!                 },
//!                 .foreign = .{
//!                     .status = .open,
//!                     .detail = "external runtime resources remain unmanaged",
//!                 },
//!             },
//!             .obligations = &.{
//!                 .{ .key = "sample_capacity", .role = .capacity_model },
//!                 .{ .key = "sample_overload", .role = .overload },
//!             },
//!         },
//!         .bindings = .{
//!             .owner = Owner,
//!         },
//!     };
//!
//!     try std.testing.expect(
//!         capacity.validateDeclaration(
//!             Owner,
//!             claim,
//!             capacity.OwnerShape.allocator_exact,
//!         ) == null,
//!     );
//!
//!     const computed = try capacity.add(usize, 31, 1);
//!     try std.testing.expectEqual(@as(usize, 32), computed);
//!
//!     try std.testing.expectError(
//!         error.CapacityOverflow,
//!         capacity.add(usize, std.math.maxInt(usize), 1),
//!     );
//! }
//! ```
//!
//! The validateDeclaration function validates this typed declaration rather
//! than complete lifecycle-owner conformance. Furthermore, the arithmetic
//! assertions exercise add independently and never evaluate the graph. An
//! actual owner's derive method still needs domain checks and a capacity
//! implementation.
//!
//! ## Metadata registration and evidence witnessing
//!
//! An obligation key names a property for supporting evidence. The
//! witness(Owner,key) function checks that the key exists and returns an
//! annotation with the claim id, key, and role for `record`, but it does
//! not run or inspect the test. Similarly, the .witnessed risk status checks
//! that a matching role obligation exists, not that evidence passed. Phase
//! premise validation checks class, authority, and reference compatibility
//! rather than the truth of the premise or the existence of external evidence.
//!
//! A message server's ServerStorage type, for example, derives required sizes
//! from a configured message_bytes limit rather than actual incoming message
//! length, adding one reader byte, configured parse_bytes, and output_bytes.
//! The derivation uses checked addition and requires parse_bytes to be
//! positive, output_bytes to be at least 4096, and the total size to not exceed
//! 16MiB. Its regions() method returns disjoint contiguous prefixes for these
//! three required sizes. ServerStorage retains the whole supplied slice and
//! deinit returns it, even when the slice is larger than required. Its source
//! claim excludes arguments and help text, standard stream descriptors and
//! kernel pipe buffering, and inline question summaries.
//!
//! One test compares derive against independent u128 arithmetic on selected
//! limit tuples. Separate tests check exact caller storage acceptance along
//! with one-byte-short rejection, and another separate test checks region
//! lengths and pointer boundaries.
//!
//! When an owner provides a valid claim, shape validation records typed
//! metadata references through the Stardust observer. The module derives two
//! distinct SHA-256 digests: `capacitySpecDigest` identifies ordered expression
//! metadata while omitting diagnostic field spellings and semantic types or
//! sizes, whereas `declarationEnvelopeDigest` hashes the fields of the
//! `SourceEnvelope` while excluding accompanying `Bindings`. Independent typed
//! references are preserved alongside these hashes within the metadata
//! pipeline. Consequently, these digests establish identity for declared
//! specification content rather than confirming total implementation
//! correctness or certifying evidence acceptance.

const arithmetic = @import("arithmetic.zig");
const capability = @import("capability.zig");
const declaration = @import("declaration.zig");
const owner = @import("owner.zig");
const phase = @import("phase.zig");
const shape = @import("shape.zig");
const spec = @import("spec.zig");

/// Declaration couples a SourceEnvelope specification with its corresponding
/// compile-time Bindings. The struct acts as a typed metadata container rather
/// than a runtime resource allocation. Calling validateDeclaration checks the
/// declaration against a specified Owner type, expected OwnerShape, and source
/// constraints, but validating a declaration does not verify the whole owner
/// shape by itself. Constructing or validating a declaration installs no
/// automatic runtime enforcement.
pub const Declaration = declaration.Declaration;
/// Computes the checked sum of two integer values of type `T`. It delegates to
/// the `@addWithOverflow` builtin, returning `error.CapacityOverflow` if
/// arithmetic overflow or carry occurs. The function imposes no domain-specific
/// maximum bounds or byte limit policies, leaving application limits to owner
/// capacity derivation. On success, it returns the sum as a value of type `T`.
pub const add = arithmetic.add;
/// Computes the checked product of two integer values of type `T`. It delegates
/// to the `@mulWithOverflow` builtin, returning `error.CapacityOverflow` if
/// arithmetic overflow occurs. The function enforces no external range policies
/// or domain limits beyond the representation limits of type `T`. On success,
/// it returns the product as a value of type `T`.
pub const mul = arithmetic.mul;
/// Violation enumerates the failure categories returned by the source
/// declaration validator. When validation fails, the validator returns the
/// first detected violation category rather than reporting a runtime allocation
/// error. Malformed user types supplied in bindings may trigger Zig compile
/// errors before validation completes. In root.zig, this type is exported under
/// the public alias DeclarationViolation.
pub const DeclarationViolation = declaration.Violation;
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
pub const SourceEnvelope = declaration.SourceEnvelope;
/// EnvelopeView provides a structurally uniform representation of a
/// SourceEnvelope where the typed capacity specification is replaced by a
/// SpecView. The remaining borrowed metadata fields, including id, kind,
/// limit_source, storage, overload, risks, work, dependencies, and obligations,
/// remain identical. This view enables structural serialization and digest
/// computation without depending on semantic type coordinates. Slices
/// referenced by the view remain borrowed and are not owned by the view struct.
pub const EnvelopeView = declaration.EnvelopeView;
/// `Kind` specifies source classification as either `startup_static` or
/// `phase_static`. Validation of `phase_static` requires valid seal and
/// teardown bindings. In contrast, `startup_static` does not require or inspect
/// optional phase bindings in `validateBindings`. The tag describes a claim and
/// does not govern actual allocation behavior or enforce an operational
/// lifetime.
pub const Kind = declaration.Kind;
/// LimitSource indicates whether memory capacity limits originate from the
/// caller or from application defaults. Selecting caller forbids supplying a
/// default_limits selector binding. Selecting application_default requires
/// supplying a selector struct containing a public declaration member. The
/// declaration validator verifies that this selector struct exists, but it
/// checks no signature or value compatibility between that declaration and the
/// owner limits.
pub const LimitSource = declaration.LimitSource;
/// CoveredStorage describes a discrete memory region covered by an owner claim
/// through its id, lifetime, and detail fields. The id string must contain 1 to
/// 64 bytes, starting with a lowercase ASCII letter and followed only by
/// lowercase ASCII letters, digits, or underscores. Each id must be unique
/// within the containing covered list. The lifetime field holds a
/// StorageLifetime tag, and the detail string must contain 1 to 512 single-line
/// bytes without null bytes, carriage returns, or line feeds. The struct
/// borrows these slices without owning allocations or enforcing lifetimes at
/// runtime.
pub const CoveredStorage = declaration.CoveredStorage;
/// Storage specifies the memory coverage boundaries of a claim using covered
/// and excluded slices, rather than holding the backing storage buffer of an
/// owner. The covered list accepts 1 to 16 CoveredStorage records with unique
/// local identifiers. The excluded list accepts 1 to 16 descriptive strings,
/// each bounded to 1 to 512 single-line bytes excluding null bytes, carriage
/// returns, and line feeds. Excluded entries are not checked for uniqueness,
/// and their presence makes no claim that other process memory is absent. The
/// struct holds borrowed slices rather than copying text or managing memory.
pub const Storage = declaration.Storage;
/// StorageLifetime labels the operational stage of a covered storage region
/// using the initialization, steady, or transferred tags. These values provide
/// descriptive metadata about when an owner uses a memory region. The enum
/// performs no runtime lifetime tracking, memory management, or ownership
/// operations.
pub const StorageLifetime = declaration.StorageLifetime;
/// `Overload` describes declared overload behavior through its `kind` and
/// `detail` fields, where `detail` identifies protected state. Full declaration
/// validation checks that `kind` is compatible with `OwnerShape` and verifies
/// that `detail` contains 1 to 512 bytes excluding NUL, LF, and CR characters.
/// Merely constructing the record validates nothing and installs no dynamic
/// policy.
pub const Overload = declaration.Overload;
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
pub const OverloadKind = declaration.OverloadKind;
/// Risk pairs a RiskStatus tag with a descriptive detail string explaining an
/// operational boundary hazard. The detail string must contain 1 to 512
/// single-line bytes without null characters, carriage returns, or line feeds.
/// Declaration validation inspects the detail text grammar and verifies that
/// any risk marked witnessed has a corresponding obligation role declared in
/// the source envelope. The struct retains these values as source metadata
/// without executing checks at runtime.
pub const Risk = declaration.Risk;
/// Risks groups the operational hazards of an owner into transitive and foreign
/// Risk records. The transitive field documents risks originating within
/// callees or subsidiary components, while the foreign field documents risks
/// arising from external resources. The descriptive details define the actual
/// scope of each hazard. Declaration validation enforces grammar and witnessed
/// obligations for both fields, but it does not compute or audit a transitive
/// closure across components.
pub const Risks = declaration.Risks;
/// RiskStatus describes whether an identified hazard has evidentiary coverage
/// through the witnessed, excluded, or open tags. Setting status to witnessed
/// requires declaring a matching risk role obligation in the source envelope,
/// but it does not establish that a test passed. Setting status to excluded
/// documents that the hazard falls outside the operational scope of the claim.
/// Setting status to open documents an unresolved claim status without
/// satisfying an obligation requirement.
pub const RiskStatus = declaration.RiskStatus;
/// `Work` defines an `equation` field consisting of descriptive work bound text
/// between 1 and 512 bytes long, excluding NUL, LF, and CR characters. It is
/// required whenever an owner uses a caller-provisioned shape, and its presence
/// requires declaring an obligation with the work_bound role. The equation text
/// provides descriptive documentation that is neither parsed nor evaluated
/// during validation. This record differs from the WorkLimits structure, which
/// supplies concrete numeric limits.
pub const Work = declaration.Work;
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
pub const Bindings = declaration.Bindings;
/// PhaseBinding associates a lifecycle transition with an implementation seam
/// and an evidentiary premise through its family and premise fields. Both
/// fields default to null, but validating a phase_static declaration requires
/// both to be present. The family field must be a selector struct containing a
/// public declaration member that resolves to a function. Validation does not
/// inspect the function signature or body, nor does it require the function to
/// match Owner.activate or Owner.deinit. The struct stores compile-time type
/// and premise descriptors rather than a runtime callable closure.
pub const PhaseBinding = declaration.PhaseBinding;
/// Premise pairs a PremiseClass category with a PremiseAuthority variant to
/// justify a phase lifecycle binding. The validatePremise function checks that
/// the class and authority are mutually compatible, that selector identifiers
/// follow required canonical or local syntax, and that local theorem keys exist
/// within the source obligations. Validation confirms structural and syntactic
/// compatibility but produces no proof of the underlying fact.
pub const Premise = declaration.Premise;
/// PremiseClass names the form of basis that supports a phase binding. Its tags
/// distinguish between mathematical theorem domains, checked semantic or path
/// facts, certified claim summaries, and trusted user, external, or environment
/// assertions. Selecting a tag identifies the expected authority category
/// during premise validation, but the enum itself does not establish or
/// evaluate the underlying evidence.
pub const PremiseClass = declaration.PremiseClass;
/// PremiseAuthority specifies the justifying source for a premise as a tagged
/// union over checker, theorem, certified_claim, and trusted variants. Each
/// variant carries its respective selector, except checker, which carries no
/// payload. The authority must pair with a compatible PremiseClass during
/// validation: checker requires checked_semantic_fact or checked_path_fact,
/// theorem requires theorem_domain, certified_claim requires certified_summary,
/// and trusted requires trusted_user, trusted_extern, or trusted_environment.
pub const PremiseAuthority = declaration.PremiseAuthority;
/// Obligation pairs a claim-local identifier key with an ObligationRole tag.
/// The key string must contain 1 to 64 bytes, beginning with a lowercase ASCII
/// letter and containing only lowercase letters, digits, or underscores. The
/// source envelope accepts a list of 1 to 24 obligations, and every key must be
/// unique within that list. Validation mandates the capacity_model role in
/// every claim, the overload role unless overload is not applicable,
/// appropriate risk roles for witnessed risks, and the work_bound role when a
/// work equation is declared. Keys remain local to the enclosing claim rather
/// than resolving globally.
pub const Obligation = declaration.Obligation;
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
pub const ObligationRole = declaration.ObligationRole;
/// `WitnessAnnotation` holds `claim_id` and `obligation_key` slices alongside a
/// `role` value. The `witness` operation requires `Owner.claim` to have the
/// exact type `Declaration` and verifies that the obligation key exists, but it
/// does not validate the whole claim. Passing the returned annotation to
/// `record` associates it with the enclosing test. Constructing the annotation
/// alone does not record an association with a test or prove that a test
/// passed, and it performs no test execution or assertion inspection.
pub const WitnessAnnotation = declaration.WitnessAnnotation;
/// witness extracts a WitnessAnnotation for a specified Owner type and
/// obligation key at compile time. It requires that Owner declare a public
/// member named claim whose type is exactly Declaration, and that the
/// obligation key exists within the claim obligations list, failing compilation
/// if either condition is not met. It returns a WitnessAnnotation containing
/// the claim id, obligation key, and associated obligation role from the source
/// envelope. The function does not run full declaration validation, inspect
/// test logic, or execute tests.
pub const witness = declaration.witness;
/// `record` enters a witness annotation into the Stardust claim table for the
/// enclosing test. It is `inline`, so the test stays the compiler's analysis
/// owner. Without the Stardust observer, as in a release, it records nothing.
pub const record = declaration.record;
/// ObligationSelector identifies a claim-local obligation that grounds a
/// theorem premise through its key field. Validation checks that the key is a
/// valid local identifier and that it matches an obligation declared in the
/// current source envelope. The check enforces no role restriction on the
/// targeted obligation and performs no evaluation of the theorem.
pub const ObligationSelector = declaration.ObligationSelector;
/// ClaimSelector designates an external claim supporting a certified summary
/// premise through its id field. Validation confirms that the id string
/// satisfies the syntax of a canonical dotted identifier containing at least
/// two segments. The check verifies identifier syntax only and does not look up
/// or confirm the existence of the referenced claim.
pub const ClaimSelector = declaration.ClaimSelector;
/// TrustDeclarationSelector identifies a trust declaration supporting a trusted
/// user, external component, or environment premise through its id field.
/// Validation checks that the id string conforms to canonical dotted identifier
/// syntax. The validator performs no resolution of the external identifier and
/// does not validate the underlying trust declaration.
pub const TrustDeclarationSelector = declaration.TrustDeclarationSelector;
/// Typed capacity specification holding semantic bindings: `Spec` bundles
/// borrowed slices of typed `Input` definitions, ordered `Node` entries,
/// `Assertion` claims, and optional `TypeSelector` bindings. Valid
/// specifications contain up to 48 inputs, up to 16 type selectors, 1 to 64
/// nodes, and 1 to 8 assertions, with inputs and type selectors permitted to be
/// empty. Because `Input` and `TypeSelector` contain compile-time type
/// references, a `Spec` is constructed at compile time and does not validate
/// invariants upon instantiation. The enclosing owner declaration validation
/// routine invokes the internal typed `validate` function to check structural
/// and layout rules.
pub const Spec = spec.Spec;
/// Type-erased view of a capacity specification: `View`, re-exported at the
/// package root as `SpecView`, represents a specification using `InputView` and
/// `TypeSelectorView` slices alongside expression nodes and assertions. All
/// slices are borrowed, and callers can construct or provide a `View` at
/// runtime because it contains no compile-time type fields. The internal
/// compile-time `view` constructor produces view slices with static storage
/// lifetime, but arbitrary runtime instances do not own underlying memory or
/// guarantee static persistence.
pub const SpecView = spec.View;
/// Specification input parameter holding compile-time type information: `Input`
/// defines an external input with an identifier string (`id`), a compile-time
/// limit type (`limits_type`), a navigation path (`field_path`), and an
/// expected category (`leaf_class`). The identifier must contain 1 to 64 bytes
/// beginning with a lowercase ASCII letter followed by lowercase alphanumeric
/// characters or underscores, and must be unique across all inputs. Because
/// `limits_type` stores a compile-time type, constructing an `Input` occurs at
/// compile time, borrowing string slices for the identifier and path
/// diagnostic. Typed validation confirms that `limits_type` matches the
/// expected limits type and that following the ordinal path through that type
/// yields the declared `leaf_class`.
pub const Input = spec.Input;
/// Type-erased description of a specification input: `InputView` retains the
/// identifier string (`id`), ordinal path (`field_path`), and classification
/// tag (`leaf_class`) while omitting the compile-time type binding. It holds
/// borrowed string slices suitable for runtime inspection and digest
/// computation. Structural validation checks identifier syntax and path bounds,
/// but cannot verify whether the path corresponds to a field in any concrete
/// Zig type.
pub const InputView = spec.InputView;
/// Category of data held at the termination of a field path: `LeafClass`
/// classifies inputs as `unsigned_integer`, `signed_integer`, `collection`, or
/// `byte_collection`. When resolving fields in `bindInput`, integers up to 64
/// bits produce integer classes, slices of `u8` yield `byte_collection`, and
/// slices of other element types become `collection`. Expression validation
/// enforces that `Node.input` references only integer classes, collection
/// length projections accept both slice classes, and byte count projections
/// target only `byte_collection`.
pub const LeafClass = spec.LeafClass;
/// Compile-time metadata binding for a referenced memory type: `TypeSelector`
/// pairs an identifier string (`id`) with a compile-time type
/// (`selected_type`), a size in bytes (`byte_size`), and a byte alignment
/// requirement (`byte_alignment`). Identifiers must be unique across all
/// selectors in a specification. Constructing a selector through `bindType`
/// captures the results of `@sizeOf` and `@alignOf` without taking ownership of
/// the underlying type. Typed validation verifies that the stored size and
/// alignment match the type, and that alignment is a non-zero power of two.
pub const TypeSelector = spec.TypeSelector;
/// `TypeSelectorView` exposes only a borrowed identifier while omitting
/// `selected_type`, `byte_size`, and `byte_alignment`. Structural validation
/// verifies identifier grammar and confirms uniqueness across all selectors in
/// the view. The digest incorporates the selector identifier without erased
/// semantic type or layout details. An entire specification digest cannot be
/// assumed independent of host layout because other graph nodes may encode
/// concrete layout values.
pub const TypeSelectorView = spec.TypeSelectorView;
/// Compile-time type binding for input limits and type selectors:
/// `SemanticType` is an alias for the Zig language primitive `type`. It
/// captures compile-time type identity during specification definition rather
/// than serializing a runtime type identifier. This binding allows compile-time
/// validation to inspect memory layout properties directly from the type
/// system.
pub const SemanticType = spec.SemanticType;
/// `BoundedFieldOrdinalPath` represents a static path through nested structs
/// using a fixed array of eight `u16` field ordinals, an active `u8` length,
/// and a borrowed diagnostic string. The ordinals are zero-based field indices
/// in nested structs rather than memory byte offsets. The active length must
/// range from 1 to 8. The diagnostic string must consist of 1 to 256 bytes
/// formed by non-empty dot-separated ASCII segments containing letters, digits,
/// or underscores, with uppercase characters permitted. Typed validation
/// follows the actual field indices and verifies the leaf class. Structural
/// validation checks diagnostic syntax without resolving the diagnostic
/// spelling against field definitions. The computed hash covers the active
/// length and active ordinals while excluding the diagnostic string and unused
/// tail ordinals. The structure does not perform runtime navigation operations.
pub const BoundedFieldOrdinalPath = spec.BoundedFieldOrdinalPath;
/// `FieldPath` is a type alias for `BoundedFieldOrdinalPath`, providing eight
/// fixed field-index slots alongside an active length. The type maintains
/// identical ordinal constraints and shares the lifetime of its borrowed
/// diagnostic string without treating indices as memory offsets.
pub const FieldPath = spec.FieldPath;
/// Failure reason for capacity specification validation: `Violation`,
/// re-exported at the package root as `SpecViolation`, enumerates the first
/// structural or typed rule failure encountered during validation. The
/// specification does not enforce any rule that rejects unused or unreferenced
/// graph nodes. An invalid assertion expression failure specifically denotes a
/// referenced node index that is out of bounds rather than an arithmetic
/// evaluation error.
pub const SpecViolation = spec.Violation;
/// Expression graph node union: `Node` defines the operations of the capacity
/// expression language through tags `constant`, `input`, `add`, `maximum`,
/// `scale`, `product`, `alignment`, `ceiling_division`, `conditional`,
/// `next_power_of_two`, and `collection`. Nodes form an ordered acyclic graph
/// bounded to at most 64 entries in a valid specification. Structural
/// validation requires operand node indices to strictly precede the current
/// node position, while inputs and collection projections must address valid
/// inputs matching their required leaf classes. Validation does not evaluate
/// expressions, check for division by zero, guard against arithmetic overflow,
/// or verify value positivity.
pub const Node = spec.Node;
/// Binary operand reference for node expressions: `Pair` holds two 16-bit
/// unsigned integer indices, `left` and `right`. Both indices address earlier
/// nodes in the ordered expression array rather than input indices. Structural
/// validation enforces this directed acyclic graph ordering by requiring that
/// both indices strictly precede the position of the containing node.
pub const Pair = spec.Pair;
/// Symbolic multiplication of a node by a scaling factor: `Scale` combines a
/// 16-bit expression node index (`node`) with a `Coefficient` multiplier.
/// Validation requires that the referenced node index appears earlier in the
/// expression sequence, and enforces selector bounds if the coefficient
/// references a concrete type. The structure describes a mathematical scaling
/// operation without calculating a product or checking for integer overflow.
pub const Scale = spec.Scale;
/// The `Alignment` union represents an alignment requirement as either a
/// literal `u64` value or a `concrete_type` referencing a `u16` selector index.
/// Validation requires a literal value to be a non-zero power of two, or a
/// concrete index to reside within the valid selector range. Typed validation
/// examines selector size and alignment facts for concrete selections. A view
/// provides only the selector identifier for concrete selection, whereas a
/// literal `Alignment` retains its explicit numeric value. The type provides no
/// runtime allocation guarantee.
pub const Alignment = spec.Alignment;
/// Symbolic rounding descriptor targeting a memory boundary: `Align` pairs a
/// 16-bit expression node index (`node`) with an `Alignment` rule. Structural
/// validation requires the target node index to strictly precede the position
/// of the current node. This struct describes a symbolic rounding calculation
/// for byte capacity expressions, rather than providing guarantees about
/// allocated pointer addresses.
pub const Align = spec.Align;
/// Relational operator tag for conditional expressions: `Comparison` defines
/// the tags `equal`, `not_equal`, `less_than`, `less_or_equal`, `greater_than`,
/// and `greater_or_equal` for use inside a `Predicate`. Constructing a
/// comparison tag specifies the intended condition between two node values.
/// This module does not evaluate predicates or compare actual input values.
pub const Comparison = spec.Comparison;
/// Comparison expression linking two node operands: `Predicate` combines a
/// `Comparison` operator with two 16-bit node indices, `left` and `right`. When
/// validated inside a `Conditional` node, both operand indices must strictly
/// precede the containing node index. The structure defines a declarative
/// relational test without evaluating operands or storing boolean results.
pub const Predicate = spec.Predicate;
/// Branching expression selecting between alternative expressions:
/// `Conditional` holds a `Predicate` condition together with two 16-bit node
/// indices, `when_true` and `when_false`. Validation requires all referenced
/// nodes, including both predicate operands and both branch targets, to appear
/// earlier in the expression sequence than the conditional node itself. The
/// structure represents branch selection declaratively without executing either
/// branch or verifying path reachability.
pub const Conditional = spec.Conditional;
/// Character occurrence counter for a byte slice: `ByteCount` pairs a 16-bit
/// input index (`input`) with an 8-bit byte value (`byte`). When referenced by
/// a collection projection node, validation verifies that the addressed input
/// exists and possesses a `byte_collection` leaf classification. The struct
/// declaratively describes counting occurrences of the specified byte within
/// the input slice without scanning memory or computing sums.
pub const ByteCount = spec.ByteCount;
/// Measurement extraction from collection inputs: `CollectionProjection` is a
/// tagged union supporting either a `length` query taking a 16-bit input index
/// or a `byte_count` query holding a `ByteCount` descriptor. Unlike binary
/// arithmetic operators, these indices address entries in the specification
/// input list rather than expression nodes. Structural validation rejects
/// scalar integer inputs, permitting `length` on both general slices and byte
/// slices while restricting `byte_count` exclusively to byte slices.
pub const CollectionProjection = spec.CollectionProjection;
/// Multiplication factor operand in a scaling expression: `Coefficient` is a
/// tagged union representing either a 64-bit constant (`literal`), an
/// unresolved integer parameter index (`unsigned_comptime_parameter`), a
/// generic type parameter index (`size_of_type_parameter`), or a concrete type
/// selector index (`size_of_concrete_type`). The parameter variants act as
/// declarative placeholders whose concrete values are not resolved by this
/// module. Structural validation checks that `size_of_concrete_type` references
/// an index within the specification type selector list. Construction and
/// validation do not compute products or perform arithmetic multiplication.
pub const Coefficient = spec.Coefficient;
/// Formal capacity claim for a completed expression: `Assertion` binds a
/// `Scope`, a `Measure`, and a `Relation` to a 16-bit node index
/// (`expression`). Structural validation checks that the referenced expression
/// index points to a valid node within the specification node array.
/// Constructing or validating an `Assertion` does not invoke runtime assertion
/// checks, evaluate expression values, or verify agreement with derived
/// allocation bounds.
pub const Assertion = spec.Assertion;
/// The `Scope` enumeration provides the sole tag `closure_total` to label the
/// evaluation scope of an `Assertion`. The module provides no evaluator,
/// automatic traversal of an owner graph, or proof of transitive coverage. A
/// source type alone does not establish a precise dynamic footprint for an
/// operation.
pub const Scope = spec.Scope;
/// The `Measure` enumeration selects a quantity label within an `Assertion`
/// using tags `reserved`, `committed`, `live`, or `retained`. The measurement
/// tag belongs directly to the `Assertion` rather than to an expression node.
/// This module does not measure allocations or evaluate runtime quantities.
/// Scope and supporting evidence are supplied by an enclosing claim and
/// downstream analysis.
pub const Measure = spec.Measure;
/// Comparison intent for an asserted bound: `Relation` distinguishes whether an
/// expression represents an `upper_bound` or an `exact` quantity in an
/// `Assertion`. The tag declares the intended relation between the selected
/// `Measure` and the target expression node. Structural validation verifies
/// that the referenced expression node index falls within the defined node
/// array, but does not check whether the mathematical relationship holds true.
pub const Relation = spec.Relation;
/// This validator limit specifies a maximum of 64 bytes for canonical dotted
/// claim, dependency, or trust identifiers, under the root alias
/// `claim_id_bytes_max`.
pub const claim_id_bytes_max = declaration.id_bytes_max;
/// This constant defines the 32-byte SHA-256 output digest size corresponding
/// to the root alias `declaration_envelope_digest_bytes`. This value reflects
/// the fixed digest output length rather than the input envelope size.
pub const declaration_envelope_digest_bytes = declaration.digest_bytes;
/// Byte length of the specification digest: `digest_bytes` is an integer
/// constant set to 32, exported at the package root as `spec_digest_bytes`. It
/// reflects the fixed 32-byte output length of the underlying SHA-256
/// cryptographic hash rather than the serialized length of the input data.
pub const spec_digest_bytes = spec.digest_bytes;
/// This validator limit specifies a maximum of 16 covered storage records in
/// `SourceEnvelope.storage.covered`, requiring a valid list to be non-empty.
pub const declaration_covered_max = declaration.covered_max;
/// This validator limit defines a maximum of 16 excluded descriptive strings in
/// a valid non-empty list, without enforcing a uniqueness check.
pub const declaration_excluded_max = declaration.excluded_max;
/// This validator limit defines a maximum of 8 canonical dependency
/// identifiers, permitting an empty list.
pub const declaration_dependencies_max = declaration.dependencies_max;
/// This validator limit specifies a maximum of 24 named obligation records,
/// requiring a valid list to be non-empty.
pub const declaration_obligations_max = declaration.obligations_max;
/// identifierValid checks whether a byte slice adheres to canonical dotted
/// identifier grammar, returning true on success. The slice must contain 1 to
/// 64 bytes divided into at least two non-empty segments separated by dots.
/// Segment characters are restricted to lowercase ASCII letters, digits, and
/// underscores, and segments may begin with a digit or underscore. The function
/// validates canonical identifier syntax only, without performing external
/// registry lookups or enforcing claim-local key grammar.
pub const identifierValid = declaration.identifierValid;
/// Upper bound on specification inputs: `inputs_max` is an integer constant set
/// to 48, exported at the package root as `spec_inputs_max`. Specifications may
/// declare anywhere from zero up to 48 inputs inclusive. Validation returns an
/// error violation if an input list exceeds this bound.
pub const spec_inputs_max = spec.inputs_max;
/// Historical limit for specification inputs: `inputs_max_v1` is an integer
/// constant set to 16, exported at the package root as `spec_inputs_max_v1`. It
/// records the earlier input capacity bound from initial specification
/// revisions. Current validation routines enforce `inputs_max` instead of this
/// historical threshold.
pub const spec_inputs_max_v1 = spec.inputs_max_v1;
/// Schema revision constant for specification input limits:
/// `input_bound_version` is a 16-bit integer constant with value 2, exported at
/// the package root as `spec_input_bound_version`. It identifies the
/// specification revision that expanded the maximum input capacity to 48. This
/// value tracks input bound sizing rather than the digest domain version or an
/// automatic schema conversion mechanism.
pub const spec_input_bound_version = spec.input_bound_version;
/// Upper bound on specification type selectors: `type_selectors_max` is an
/// integer constant set to 16, exported at the package root as
/// `spec_type_selectors_max`. A specification may include an empty type
/// selector list or up to 16 selectors. Validation checks this limit during
/// structural inspection.
pub const spec_type_selectors_max = spec.type_selectors_max;
/// Upper bound on expression graph nodes: `nodes_max` is an integer constant
/// set to 64, exported at the package root as `spec_nodes_max`. A valid
/// specification requires at least one node and permits at most 64 nodes in its
/// ordered expression sequence.
pub const spec_nodes_max = spec.nodes_max;
/// Upper bound on specification assertions: `assertions_max` is an integer
/// constant set to 8, exported at the package root as `spec_assertions_max`. A
/// valid specification must contain at least one assertion and at most 8
/// assertions.
pub const spec_assertions_max = spec.assertions_max;
/// Maximum nesting depth for field navigation paths: `field_path_depth_max` is
/// an integer constant set to 8, exported at the package root as
/// `spec_field_path_depth_max`. It defines the maximum number of ordinal field
/// indices stored within a `BoundedFieldOrdinalPath`. Valid paths must contain
/// at least one ordinal and cannot exceed eight traversal steps.
pub const spec_field_path_depth_max = spec.field_path_depth_max;
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
pub const OwnerShape = owner.OwnerShape;
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
pub const OwnerShapeViolation = shape.OwnerShapeViolation;
/// Defines the lifecycle phases shared across allocator guards:
/// `initialization`, `steady`, and `teardown`. Runtime guards use these values
/// to classify incoming raw allocator calls. Under this classification,
/// `initialization` permits every raw operation, `steady` marks all raw
/// operations as violations, and `teardown` permits only deallocations while
/// marking allocations, resizes, and remaps as violations. Depending on the
/// selected guard type, a violation either triggers an immediate panic or
/// increments audit counters before forwarding the call to the backing
/// allocator. The enumeration itself is an unadorned data type that enforces no
/// transition rules or operational policies on other owners.
pub const Phase = phase.Phase;
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
pub const WorkLimits = owner.WorkLimits;
/// declarationEnvelopeDigest computes the digest of a compile-time Declaration
/// by converting its source envelope through sourceView and hashing the
/// resulting EnvelopeView with envelopeDigest. Because the view omits bindings,
/// changes to bindings such as the owner type, seam functions, or premises do
/// not affect the digest. The underlying capacity digest also omits semantic
/// types and sizing facts. The resulting hash establishes a content identity
/// for selected source specification fields rather than an identity for the
/// whole implementation or its evidence.
pub const declarationEnvelopeDigest = declaration.declarationEnvelopeDigest;
/// envelopeDigest hashes the content of an EnvelopeView using SHA-256 under the
/// domain tiny.alloc.claim-declaration/v2, and is exported from root.zig as
/// declarationSourceEnvelopeDigest. The digest builder length-frames every
/// field and ordered list element, incorporating storage details, the capacity
/// specification digest, overload policy, risks, optional work equations,
/// dependencies, and obligations. Because the view contains no bindings, all
/// typed bindings and premises are excluded from the digest. The function
/// performs no validation or formal proof, requiring callers to provide a valid
/// bounded view.
pub const declarationSourceEnvelopeDigest = declaration.envelopeDigest;
/// The `digest` function, corresponding to the root identifier
/// `capacitySpecDigest`, generates a 32-byte SHA-256 digest using the domain
/// string `tiny.alloc.capacity-spec/v3`. Serialization employs length framing
/// for field names and values while encoding numeric values as little-endian
/// `u64` words and preserving input list order. The digest incorporates input
/// identifiers, input classes, active ordinal paths, selector identifiers,
/// nodes, and assertions. It omits diagnostic strings, `Limits` type
/// identities, and selector concrete type identities along with their size and
/// alignment values. The function performs no internal sorting, algebraic
/// normalization, or structural validation, assuming the caller supplies a
/// valid bounded view. The resulting hash distinguishes only the selected
/// serialized fields and does not attest to overall semantic equivalence, full
/// implementation behavior, or supporting evidence.
pub const capacitySpecDigest = spec.digest;
/// The `validateView` function, known under the root name `validateSpecView`,
/// accepts a specification `View` and executes at compile time or runtime to
/// return an optional first `Violation` or null. The validator verifies
/// structural bounds requiring 0 to 48 inputs, 0 to 16 selectors, 1 to 64
/// nodes, and 1 to 8 assertions. Checks include identifier grammar and
/// uniqueness within each input and selector collection, path structure and
/// diagnostic syntax, references to strictly earlier node operands, input leaf
/// and projection compatibility, concrete selector index ranges, literal
/// power-of-two alignments, and in-bounds assertion node indices. The function
/// cannot inspect semantic `Limits` or concrete type facts that are omitted
/// from the view. The implementation does not evaluate arithmetic operations,
/// verify division denominator values, detect numerical overflow, or resolve
/// generic parameter values.
pub const validateSpecView = spec.validateView;
/// Compile-time constructor linking an input identifier to a nested struct
/// field: `bindInput` evaluates at compile time to validate the syntax of an
/// identifier and a dot-separated diagnostic path against a target `Limits`
/// type. It reflects over struct fields to build an ordinal navigation path and
/// deduce the field `LeafClass`. The function emits a compile error if a field
/// name does not exist, an intermediate element is not a struct, traversal
/// depth exceeds eight levels, or the leaf type is unsupported. Supported leaf
/// types include integers up to 64 bits and slices, while fixed-size arrays and
/// wider integers are rejected. Execution raises the compiler evaluation branch
/// quota to 10000 to resolve nested types, and does not inspect runtime values.
pub const bindInput = spec.bindInput;
/// Compile-time constructor capturing layout metrics for a named type:
/// `bindType` validates an identifier string at compile time and queries the
/// size and alignment of type `T` using `@sizeOf` and `@alignOf`. Invalid
/// identifier syntax or types that disallow size and alignment inspection
/// produce a compile error. The function records numeric layout metrics
/// directly without allocating memory, generating runtime type tokens, or
/// validating the enclosing `Spec`.
pub const bindType = spec.bindType;
/// selector takes any compile-time value and returns an anonymous struct type
/// containing a public constant named declaration initialized to that value.
/// This helper allows compile-time type fields to transport typed references
/// and values. The requirement that declaration resolve to a function is not
/// checked by selector itself, but is imposed only when validating a phase
/// binding family. The function neither validates the wrapped value nor creates
/// a callable runtime closure.
pub const selector = declaration.selector;
/// The current implementation of `declareDynamicUnbounded` checks a canonical
/// dotted `id` at compile time and discards `Owner`. It does not inspect
/// whether `Owner` actually allocates, install behavior, record observer
/// metadata, or register a proven bound.
pub const declareDynamicUnbounded = declaration.declareDynamicUnbounded;
/// declareWarmRetained declares a weak capacity owner associated with warm
/// retained memory. It checks at compile time that the provided id satisfies
/// canonical dotted identifier syntax and discards the Owner type parameter.
/// The function records no observer claims and performs no actual
/// retention policy, owner shape, or capacity bound checks.
pub const declareWarmRetained = declaration.declareWarmRetained;
/// This compile-time check validates an allocator_exact owner shape. It
/// inspects Limits and Capacity declarations, runtime phase and capacity
/// declarations, and allocator-backed lifecycle signatures. An immediate
/// capability scanner examines stored fields as well as known parameters and
/// results of non-lifecycle receiver methods, while lifecycle init and deinit
/// intentionally accept an Allocator. An optional claim is validated and
/// recorded through the Stardust observer. Any invalid declaration or shape
/// causes a compile error. The check does not run owner code.
pub const requireAllocatorExactOwnerShape = shape.requireAllocatorExactOwnerShape;
/// This compile-time check validates an allocator_rejecting owner shape. It
/// shares allocator-backed fields and lifecycle signatures with allocator_exact
/// but enforces different overload requirements rather than all exact
/// requirements. The owner must expose a finite nonempty Exhaustion error set
/// on a non-lifecycle pointer-receiver method. Any optional claim is checked
/// for compatibility under the rejecting shape and recorded. The validation
/// performs structural and type checks only.
pub const requireAllocatorRejectingOwnerShape = shape.requireAllocatorRejectingOwnerShape;
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
pub const requireProvisionedExactOwnerShape = shape.requireProvisionedExactOwnerShape;
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
pub const requireProvisionedRejectingOwnerShape = shape.requireProvisionedRejectingOwnerShape;
/// Recursively inspects a compile-time type to detect whether it exposes an
/// allocator capability. The traversal follows typed pointers, arrays, vectors,
/// optionals, error-union payloads, struct and union fields, and container
/// receiver methods whose return types lead to an allocator. It maintains a
/// compile-time tuple of visited containers to prevent infinite loops on
/// recursive data structures, and recognizes `std.mem.Allocator` as an
/// immediate capability. For bare function types, the check examines only the
/// return type, without scanning parameter lists. This public recursive
/// inspector differs from the narrower internal scanner used by
/// allocator-backed shapes, which inspects only immediate field types and
/// container allocator methods. The function does not inspect function bodies,
/// detect global allocator variables, or track capabilities through type-erased
/// pointers such as `*anyopaque`. It does not prove that runtime execution is
/// free from allocation side effects.
pub const typeHasAllocatorCapability = capability.typeHasAllocatorCapability;
/// Validates that an owner type conforms to `OwnerShape.allocator_exact`,
/// returning an optional `OwnerShapeViolation`. It uses an immediate shallow
/// capability scanner that inspects stored fields and method signatures for
/// direct references to `std.mem.Allocator` or container allocator factories.
/// If a valid typed `claim` is declared, the function records claim metadata at
/// compile time. A return value of `null` confirms that all structural checks
/// passed. It does not prove that owner methods avoid runtime heap allocation
/// or that dynamic memory behavior is infallible.
pub const validateAllocatorExactOwnerShape = shape.validateAllocatorExactOwnerShape;
/// This function validates an allocator_rejecting owner shape, returning the
/// first OwnerShapeViolation or null. It shares allocator-backed lifecycle and
/// field rules with the exact shape but does not require all exact claim
/// policies. It instead adds an Exhaustion surface requirement and verifies
/// claim compatibility for the rejecting shape when a claim is present. The
/// function executes a shallow capability scan, records any valid present
/// claim, and does not prove error reachability.
pub const validateAllocatorRejectingOwnerShape = shape.validateAllocatorRejectingOwnerShape;
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
pub const validateDeclaration = declaration.validate;
/// `validatePremise` accepts a compile-time `SourceEnvelope` and premise pair
/// and returns the first optional `Violation` or null. It checks classification
/// and authority compatibility between the supplied entities. For `theorem`,
/// the function validates the local key and its existence in source obligations
/// without applying role restrictions. Both `certified_claim` and `trusted`
/// validate canonical `id` syntax without performing a registry lookup. The
/// function does not validate the whole `SourceEnvelope` or inspect underlying
/// evidence.
pub const validatePremise = declaration.validatePremise;
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
pub const validateOwnerShape = shape.validateOwnerShape;
/// This function validates a provisioned_exact owner shape, returning the first
/// violation or null. It verifies runtime phase, capacity, and storage
/// declarations, ensuring an aligned Storage type and a Capacity.storage_bytes
/// field. It also verifies a typed claim and a work_limits declaration, noting
/// that work_limits is a compile-time declaration rather than a runtime field.
/// A recursive capability scan inspects the owner including Limits and
/// Capacity, and any valid claim is recorded. The function does not execute
/// lifecycle methods.
pub const validateProvisionedExactOwnerShape = shape.validateProvisionedExactOwnerShape;
/// This function validates a provisioned_rejecting owner shape, returning the
/// first violation or null. It applies shared provisioned storage, lifecycle,
/// and work rules while enforcing a different overload classification. The
/// owner must expose a finite nonempty Exhaustion error set on a
/// pointer-receiver method and declare a reject_before_mutation claim overload.
/// A recursive capability scan is performed, and any valid claim is recorded.
/// The function does not itself check payload preservation.
pub const validateProvisionedRejectingOwnerShape = shape.validateProvisionedRejectingOwnerShape;

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
pub const ProvisionedExactFixture = @import("fixture.zig").ExactOwner;
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
pub const ProvisionedRejectingFixture = @import("fixture.zig").RejectingOwner;
