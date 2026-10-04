const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Schema revision constant for specification input limits:
/// `input_bound_version` is a 16-bit integer constant with value 2, exported at
/// the package root as `spec_input_bound_version`. It identifies the
/// specification revision that expanded the maximum input capacity to 48. This
/// value tracks input bound sizing rather than the digest domain version or an
/// automatic schema conversion mechanism.
pub const input_bound_version: u16 = 2;
/// Historical limit for specification inputs: `inputs_max_v1` is an integer
/// constant set to 16, exported at the package root as `spec_inputs_max_v1`. It
/// records the earlier input capacity bound from initial specification
/// revisions. Current validation routines enforce `inputs_max` instead of this
/// historical threshold.
pub const inputs_max_v1: usize = 16;
/// Upper bound on specification inputs: `inputs_max` is an integer constant set
/// to 48, exported at the package root as `spec_inputs_max`. Specifications may
/// declare anywhere from zero up to 48 inputs inclusive. Validation returns an
/// error violation if an input list exceeds this bound.
pub const inputs_max: usize = 48;
/// Upper bound on specification type selectors: `type_selectors_max` is an
/// integer constant set to 16, exported at the package root as
/// `spec_type_selectors_max`. A specification may include an empty type
/// selector list or up to 16 selectors. Validation checks this limit during
/// structural inspection.
pub const type_selectors_max: usize = 16;
/// Upper bound on expression graph nodes: `nodes_max` is an integer constant
/// set to 64, exported at the package root as `spec_nodes_max`. A valid
/// specification requires at least one node and permits at most 64 nodes in its
/// ordered expression sequence.
pub const nodes_max: usize = 64;
/// Upper bound on specification assertions: `assertions_max` is an integer
/// constant set to 8, exported at the package root as `spec_assertions_max`. A
/// valid specification must contain at least one assertion and at most 8
/// assertions.
pub const assertions_max: usize = 8;
/// Maximum nesting depth for field navigation paths: `field_path_depth_max` is
/// an integer constant set to 8, exported at the package root as
/// `spec_field_path_depth_max`. It defines the maximum number of ordinal field
/// indices stored within a `BoundedFieldOrdinalPath`. Valid paths must contain
/// at least one ordinal and cannot exceed eight traversal steps.
pub const field_path_depth_max: usize = 8;
/// Maximum byte length for specification identifier symbols: `symbol_bytes_max`
/// is an integer constant set to 64. It constrains the raw byte length of input
/// and type selector identifier strings rather than counting Unicode
/// codepoints. Valid identifiers must have between 1 and 64 bytes, beginning
/// with a lowercase ASCII letter followed by lowercase ASCII letters, digits,
/// or underscores.
pub const symbol_bytes_max: usize = 64;
/// Maximum byte length for diagnostic field path strings:
/// `field_path_bytes_max` is an integer constant set to 256. It limits the
/// total byte length of the human-readable diagnostic path rather than bounding
/// nesting depth or field counts. A valid diagnostic string contains between 1
/// and 256 bytes formatted as dot-separated segments of ASCII alphanumeric
/// characters and underscores.
pub const field_path_bytes_max: usize = 256;
/// Byte length of the specification digest: `digest_bytes` is an integer
/// constant set to 32, exported at the package root as `spec_digest_bytes`. It
/// reflects the fixed 32-byte output length of the underlying SHA-256
/// cryptographic hash rather than the serialized length of the input data.
pub const digest_bytes: usize = Sha256.digest_length;
/// The `digest_domain` constant provides the exact byte sequence
/// `tiny.alloc.capacity-spec/v3` used as a length-framed initial domain in the
/// digest builder. This domain prefix isolates the specification hash stream
/// from inputs produced under alternative domain tags. Its version tag v3
/// designates the hashing protocol format and remains independent of the schema
/// `input_bound_version` constant.
pub const digest_domain = "tiny.alloc.capacity-spec/v3";

/// The `Measure` enumeration selects a quantity label within an `Assertion`
/// using tags `reserved`, `committed`, `live`, or `retained`. The measurement
/// tag belongs directly to the `Assertion` rather than to an expression node.
/// This module does not measure allocations or evaluate runtime quantities.
/// Scope and supporting evidence are supplied by an enclosing claim and
/// downstream analysis.
pub const Measure = enum {
    reserved,
    committed,
    live,
    retained,
};

/// Comparison intent for an asserted bound: `Relation` distinguishes whether an
/// expression represents an `upper_bound` or an `exact` quantity in an
/// `Assertion`. The tag declares the intended relation between the selected
/// `Measure` and the target expression node. Structural validation verifies
/// that the referenced expression node index falls within the defined node
/// array, but does not check whether the mathematical relationship holds true.
pub const Relation = enum {
    upper_bound,
    exact,
};

/// The `Scope` enumeration provides the sole tag `closure_total` to label the
/// evaluation scope of an `Assertion`. The module provides no evaluator,
/// automatic traversal of an owner graph, or proof of transitive coverage. A
/// source type alone does not establish a precise dynamic footprint for an
/// operation.
pub const Scope = enum {
    closure_total,
};

/// Compile-time type binding for input limits and type selectors:
/// `SemanticType` is an alias for the Zig language primitive `type`. It
/// captures compile-time type identity during specification definition rather
/// than serializing a runtime type identifier. This binding allows compile-time
/// validation to inspect memory layout properties directly from the type
/// system.
pub const SemanticType = type;

/// Category of data held at the termination of a field path: `LeafClass`
/// classifies inputs as `unsigned_integer`, `signed_integer`, `collection`, or
/// `byte_collection`. When resolving fields in `bindInput`, integers up to 64
/// bits produce integer classes, slices of `u8` yield `byte_collection`, and
/// slices of other element types become `collection`. Expression validation
/// enforces that `Node.input` references only integer classes, collection
/// length projections accept both slice classes, and byte count projections
/// target only `byte_collection`.
pub const LeafClass = enum {
    unsigned_integer,
    signed_integer,
    collection,
    byte_collection,
};

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
pub const BoundedFieldOrdinalPath = struct {
    ordinals: [field_path_depth_max]u16 = @splat(0),
    len: u8,
    diagnostic: []const u8,
};

/// `FieldPath` is a type alias for `BoundedFieldOrdinalPath`, providing eight
/// fixed field-index slots alongside an active length. The type maintains
/// identical ordinal constraints and shares the lifetime of its borrowed
/// diagnostic string without treating indices as memory offsets.
pub const FieldPath = BoundedFieldOrdinalPath;

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
pub const Input = struct {
    id: []const u8,
    limits_type: SemanticType,
    field_path: BoundedFieldOrdinalPath,
    leaf_class: LeafClass = .unsigned_integer,
};

/// Type-erased description of a specification input: `InputView` retains the
/// identifier string (`id`), ordinal path (`field_path`), and classification
/// tag (`leaf_class`) while omitting the compile-time type binding. It holds
/// borrowed string slices suitable for runtime inspection and digest
/// computation. Structural validation checks identifier syntax and path bounds,
/// but cannot verify whether the path corresponds to a field in any concrete
/// Zig type.
pub const InputView = struct {
    id: []const u8,
    field_path: BoundedFieldOrdinalPath,
    leaf_class: LeafClass = .unsigned_integer,
};

/// Compile-time metadata binding for a referenced memory type: `TypeSelector`
/// pairs an identifier string (`id`) with a compile-time type
/// (`selected_type`), a size in bytes (`byte_size`), and a byte alignment
/// requirement (`byte_alignment`). Identifiers must be unique across all
/// selectors in a specification. Constructing a selector through `bindType`
/// captures the results of `@sizeOf` and `@alignOf` without taking ownership of
/// the underlying type. Typed validation verifies that the stored size and
/// alignment match the type, and that alignment is a non-zero power of two.
pub const TypeSelector = struct {
    id: []const u8,
    selected_type: SemanticType,
    byte_size: u64,
    byte_alignment: u64,
};

/// `TypeSelectorView` exposes only a borrowed identifier while omitting
/// `selected_type`, `byte_size`, and `byte_alignment`. Structural validation
/// verifies identifier grammar and confirms uniqueness across all selectors in
/// the view. The digest incorporates the selector identifier without erased
/// semantic type or layout details. An entire specification digest cannot be
/// assumed independent of host layout because other graph nodes may encode
/// concrete layout values.
pub const TypeSelectorView = struct {
    id: []const u8,
};

/// Multiplication factor operand in a scaling expression: `Coefficient` is a
/// tagged union representing either a 64-bit constant (`literal`), an
/// unresolved integer parameter index (`unsigned_comptime_parameter`), a
/// generic type parameter index (`size_of_type_parameter`), or a concrete type
/// selector index (`size_of_concrete_type`). The parameter variants act as
/// declarative placeholders whose concrete values are not resolved by this
/// module. Structural validation checks that `size_of_concrete_type` references
/// an index within the specification type selector list. Construction and
/// validation do not compute products or perform arithmetic multiplication.
pub const Coefficient = union(enum) {
    literal: u64,
    unsigned_comptime_parameter: u16,
    size_of_type_parameter: u16,
    size_of_concrete_type: u16,
};

/// Binary operand reference for node expressions: `Pair` holds two 16-bit
/// unsigned integer indices, `left` and `right`. Both indices address earlier
/// nodes in the ordered expression array rather than input indices. Structural
/// validation enforces this directed acyclic graph ordering by requiring that
/// both indices strictly precede the position of the containing node.
pub const Pair = struct {
    left: u16,
    right: u16,
};

/// Symbolic multiplication of a node by a scaling factor: `Scale` combines a
/// 16-bit expression node index (`node`) with a `Coefficient` multiplier.
/// Validation requires that the referenced node index appears earlier in the
/// expression sequence, and enforces selector bounds if the coefficient
/// references a concrete type. The structure describes a mathematical scaling
/// operation without calculating a product or checking for integer overflow.
pub const Scale = struct {
    node: u16,
    coefficient: Coefficient,
};

/// The `Alignment` union represents an alignment requirement as either a
/// literal `u64` value or a `concrete_type` referencing a `u16` selector index.
/// Validation requires a literal value to be a non-zero power of two, or a
/// concrete index to reside within the valid selector range. Typed validation
/// examines selector size and alignment facts for concrete selections. A view
/// provides only the selector identifier for concrete selection, whereas a
/// literal `Alignment` retains its explicit numeric value. The type provides no
/// runtime allocation guarantee.
pub const Alignment = union(enum) {
    literal: u64,
    concrete_type: u16,
};

/// Symbolic rounding descriptor targeting a memory boundary: `Align` pairs a
/// 16-bit expression node index (`node`) with an `Alignment` rule. Structural
/// validation requires the target node index to strictly precede the position
/// of the current node. This struct describes a symbolic rounding calculation
/// for byte capacity expressions, rather than providing guarantees about
/// allocated pointer addresses.
pub const Align = struct {
    node: u16,
    alignment: Alignment,
};

/// Relational operator tag for conditional expressions: `Comparison` defines
/// the tags `equal`, `not_equal`, `less_than`, `less_or_equal`, `greater_than`,
/// and `greater_or_equal` for use inside a `Predicate`. Constructing a
/// comparison tag specifies the intended condition between two node values.
/// This module does not evaluate predicates or compare actual input values.
pub const Comparison = enum {
    equal,
    not_equal,
    less_than,
    less_or_equal,
    greater_than,
    greater_or_equal,
};

/// Comparison expression linking two node operands: `Predicate` combines a
/// `Comparison` operator with two 16-bit node indices, `left` and `right`. When
/// validated inside a `Conditional` node, both operand indices must strictly
/// precede the containing node index. The structure defines a declarative
/// relational test without evaluating operands or storing boolean results.
pub const Predicate = struct {
    comparison: Comparison,
    left: u16,
    right: u16,
};

/// Branching expression selecting between alternative expressions:
/// `Conditional` holds a `Predicate` condition together with two 16-bit node
/// indices, `when_true` and `when_false`. Validation requires all referenced
/// nodes, including both predicate operands and both branch targets, to appear
/// earlier in the expression sequence than the conditional node itself. The
/// structure represents branch selection declaratively without executing either
/// branch or verifying path reachability.
pub const Conditional = struct {
    predicate: Predicate,
    when_true: u16,
    when_false: u16,
};

/// Character occurrence counter for a byte slice: `ByteCount` pairs a 16-bit
/// input index (`input`) with an 8-bit byte value (`byte`). When referenced by
/// a collection projection node, validation verifies that the addressed input
/// exists and possesses a `byte_collection` leaf classification. The struct
/// declaratively describes counting occurrences of the specified byte within
/// the input slice without scanning memory or computing sums.
pub const ByteCount = struct {
    input: u16,
    byte: u8,
};

/// Measurement extraction from collection inputs: `CollectionProjection` is a
/// tagged union supporting either a `length` query taking a 16-bit input index
/// or a `byte_count` query holding a `ByteCount` descriptor. Unlike binary
/// arithmetic operators, these indices address entries in the specification
/// input list rather than expression nodes. Structural validation rejects
/// scalar integer inputs, permitting `length` on both general slices and byte
/// slices while restricting `byte_count` exclusively to byte slices.
pub const CollectionProjection = union(enum) {
    length: u16,
    byte_count: ByteCount,
};

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
pub const Node = union(enum) {
    constant: u64,
    input: u16,
    add: Pair,
    maximum: Pair,
    scale: Scale,
    product: Pair,
    alignment: Align,
    ceiling_division: Pair,
    conditional: Conditional,
    next_power_of_two: u16,
    collection: CollectionProjection,
};

/// Formal capacity claim for a completed expression: `Assertion` binds a
/// `Scope`, a `Measure`, and a `Relation` to a 16-bit node index
/// (`expression`). Structural validation checks that the referenced expression
/// index points to a valid node within the specification node array.
/// Constructing or validating an `Assertion` does not invoke runtime assertion
/// checks, evaluate expression values, or verify agreement with derived
/// allocation bounds.
pub const Assertion = struct {
    scope: Scope,
    measure: Measure,
    relation: Relation,
    expression: u16,
};

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
pub const Spec = struct {
    inputs: []const Input,
    nodes: []const Node,
    assertions: []const Assertion,
    type_selectors: []const TypeSelector = &.{},
};

/// Type-erased view of a capacity specification: `View`, re-exported at the
/// package root as `SpecView`, represents a specification using `InputView` and
/// `TypeSelectorView` slices alongside expression nodes and assertions. All
/// slices are borrowed, and callers can construct or provide a `View` at
/// runtime because it contains no compile-time type fields. The internal
/// compile-time `view` constructor produces view slices with static storage
/// lifetime, but arbitrary runtime instances do not own underlying memory or
/// guarantee static persistence.
pub const View = struct {
    inputs: []const InputView,
    nodes: []const Node,
    assertions: []const Assertion,
    type_selectors: []const TypeSelectorView = &.{},
};

/// Failure reason for capacity specification validation: `Violation`,
/// re-exported at the package root as `SpecViolation`, enumerates the first
/// structural or typed rule failure encountered during validation. The
/// specification does not enforce any rule that rejects unused or unreferenced
/// graph nodes. An invalid assertion expression failure specifically denotes a
/// referenced node index that is out of bounds rather than an arithmetic
/// evaluation error.
pub const Violation = enum {
    limits_type_mismatch,
    input_overflow,
    input_id_invalid,
    input_id_duplicate,
    input_field_path_invalid,
    type_selector_overflow,
    type_selector_id_invalid,
    type_selector_id_duplicate,
    type_selector_fact_invalid,
    nodes_missing,
    node_overflow,
    node_outside_fragment,
    assertions_missing,
    assertion_overflow,
    assertion_expression_invalid,
};

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
pub fn bindInput(
    comptime Limits: type,
    comptime id: []const u8,
    comptime field_path: []const u8,
) Input {
    @setEvalBranchQuota(10_000);
    if (comptime !symbolValid(id)) {
        @compileError("invalid capacity input id: " ++ id);
    }
    if (comptime !pathTextValid(field_path)) {
        @compileError("invalid Limits field path: " ++ field_path);
    }
    const resolved = resolveInput(Limits, field_path);
    return .{
        .id = id,
        .limits_type = Limits,
        .field_path = resolved.field_path,
        .leaf_class = resolved.leaf_class,
    };
}

/// Compile-time constructor capturing layout metrics for a named type:
/// `bindType` validates an identifier string at compile time and queries the
/// size and alignment of type `T` using `@sizeOf` and `@alignOf`. Invalid
/// identifier syntax or types that disallow size and alignment inspection
/// produce a compile error. The function records numeric layout metrics
/// directly without allocating memory, generating runtime type tokens, or
/// validating the enclosing `Spec`.
pub fn bindType(comptime T: type, comptime id: []const u8) TypeSelector {
    if (comptime !symbolValid(id)) {
        @compileError("invalid capacity type selector id: " ++ id);
    }
    return .{
        .id = id,
        .selected_type = T,
        .byte_size = @sizeOf(T),
        .byte_alignment = @alignOf(T),
    };
}

/// Compile-time converter from a typed specification to a type-erased view:
/// `view` is public within `spec.zig` but is not re-exported from the package
/// root. It transforms a compile-time `Spec` into a `View` by constructing
/// compile-time arrays of `InputView` and `TypeSelectorView` that remain valid
/// after the function returns. The conversion preserves node and assertion
/// slices while stripping compile-time types and numeric size facts, without
/// validating the input specification.
pub fn view(comptime value: Spec) View {
    const inputs = comptime inputViews(value.inputs);
    const type_selectors = comptime typeSelectorViews(value.type_selectors);
    return .{
        .inputs = &inputs,
        .nodes = value.nodes,
        .assertions = value.assertions,
        .type_selectors = &type_selectors,
    };
}

fn inputViews(comptime inputs: []const Input) [inputs.len]InputView {
    var result: [inputs.len]InputView = undefined;
    inline for (inputs, 0..) |input, index| {
        result[index] = .{
            .id = input.id,
            .field_path = input.field_path,
            .leaf_class = input.leaf_class,
        };
    }
    return result;
}

fn typeSelectorViews(
    comptime values: []const TypeSelector,
) [values.len]TypeSelectorView {
    var result: [values.len]TypeSelectorView = undefined;
    inline for (values, 0..) |value, index| {
        result[index] = .{ .id = value.id };
    }
    return result;
}

/// Compile-time validator for typed capacity specifications: `validate` is
/// public within `spec.zig` but is not exported from the package root. It
/// accepts a compile-time `Limits` type and a `Spec`, returning the first
/// encountered `Violation` or null when valid. The function verifies that every
/// input references the exact `Limits` type and that traversing its ordinals
/// matches the declared leaf classification, then confirms that type selector
/// sizes and alignments match their respective types with non-zero power-of-two
/// alignment before delegating to `validateView`. It does not execute
/// expressions or record claim metadata.
pub fn validate(comptime Limits: type, comptime value: Spec) ?Violation {
    inline for (value.inputs) |input| {
        if (input.limits_type != Limits) return .limits_type_mismatch;
        if (fieldPathClass(Limits, input.field_path) != input.leaf_class) {
            return .input_field_path_invalid;
        }
    }
    inline for (value.type_selectors) |selector| {
        if (selector.byte_size != @sizeOf(selector.selected_type) or
            selector.byte_alignment != @alignOf(selector.selected_type) or
            selector.byte_alignment == 0 or
            !std.math.isPowerOfTwo(selector.byte_alignment))
        {
            return .type_selector_fact_invalid;
        }
    }
    return validateView(view(value));
}

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
pub fn validateView(value: View) ?Violation {
    if (value.inputs.len > inputs_max) return .input_overflow;
    for (value.inputs, 0..) |input, index| {
        if (!symbolValid(input.id)) return .input_id_invalid;
        if (!fieldPathShapeValid(input.field_path)) {
            return .input_field_path_invalid;
        }
        for (value.inputs[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, input.id)) {
                return .input_id_duplicate;
            }
        }
    }
    if (value.type_selectors.len > type_selectors_max) {
        return .type_selector_overflow;
    }
    for (value.type_selectors, 0..) |selector, index| {
        if (!symbolValid(selector.id)) return .type_selector_id_invalid;
        for (value.type_selectors[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, selector.id)) {
                return .type_selector_id_duplicate;
            }
        }
    }
    if (value.nodes.len == 0) return .nodes_missing;
    if (value.nodes.len > nodes_max) return .node_overflow;
    for (value.nodes, 0..) |node, index| {
        if (!nodeValid(node, index, value.inputs, value.type_selectors.len)) {
            return .node_outside_fragment;
        }
    }
    if (value.assertions.len == 0) return .assertions_missing;
    if (value.assertions.len > assertions_max) return .assertion_overflow;
    for (value.assertions) |assertion| {
        if (assertion.expression >= value.nodes.len) {
            return .assertion_expression_invalid;
        }
    }
    return null;
}

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
pub fn digest(value: View) [digest_bytes]u8 {
    var builder = DigestBuilder.init();
    builder.addCount("inputs", value.inputs.len);
    for (value.inputs) |input| addInput(&builder, input);
    builder.addCount("type_selectors", value.type_selectors.len);
    for (value.type_selectors) |selector| {
        builder.addBytes("type_selector", selector.id);
    }
    builder.addCount("nodes", value.nodes.len);
    for (value.nodes) |node| addNode(&builder, node);
    builder.addCount("assertions", value.assertions.len);
    for (value.assertions) |assertion| addAssertion(&builder, assertion);
    return builder.finish();
}

const ResolvedInput = struct {
    field_path: FieldPath,
    leaf_class: LeafClass,
};

fn resolveInput(
    comptime Limits: type,
    comptime field_path: []const u8,
) ResolvedInput {
    return comptime result: {
        var path = BoundedFieldOrdinalPath{
            .len = 0,
            .diagnostic = field_path,
        };
        var current = Limits;
        var components = std.mem.splitScalar(u8, field_path, '.');
        while (components.next()) |component| {
            if (path.len == field_path_depth_max) {
                @compileError(
                    "Limits field path exceeds its depth bound: " ++ field_path,
                );
            }
            const resolved = resolveField(current, component) orelse {
                @compileError("invalid Limits field path: " ++ field_path);
            };
            path.ordinals[path.len] = resolved.ordinal;
            path.len += 1;
            current = resolved.field_type;
        }
        const leaf_class = classifyLeaf(current) orelse {
            @compileError(
                "Limits field path has an unsupported leaf: " ++ field_path,
            );
        };
        break :result .{ .field_path = path, .leaf_class = leaf_class };
    };
}

const ResolvedField = struct {
    ordinal: u16,
    field_type: type,
};

fn resolveField(comptime Container: type, comptime name: []const u8) ?ResolvedField {
    const info = @typeInfo(Container);
    if (info != .@"struct") return null;
    inline for (
        info.@"struct".field_names,
        info.@"struct".field_types,
        0..,
    ) |field_name, field_type, index| {
        if (std.mem.eql(u8, field_name, name)) {
            if (index > std.math.maxInt(u16)) return null;
            return .{ .ordinal = @intCast(index), .field_type = field_type };
        }
    }
    return null;
}

fn fieldPathClass(
    comptime Limits: type,
    comptime path: BoundedFieldOrdinalPath,
) ?LeafClass {
    if (!pathTextValid(path.diagnostic)) return null;
    if (path.len == 0 or path.len > field_path_depth_max) return null;
    inline for (path.ordinals[path.len..]) |ordinal| {
        if (ordinal != 0) return null;
    }
    comptime var current = Limits;
    inline for (path.ordinals[0..path.len]) |ordinal| {
        const info = @typeInfo(current);
        if (info != .@"struct") return null;
        if (ordinal >= info.@"struct".field_types.len) return null;
        current = info.@"struct".field_types[ordinal];
    }
    return classifyLeaf(current);
}

fn fieldPathShapeValid(path: BoundedFieldOrdinalPath) bool {
    if (!pathTextValid(path.diagnostic)) return false;
    if (path.len == 0 or path.len > field_path_depth_max) return false;
    for (path.ordinals[path.len..]) |ordinal| {
        if (ordinal != 0) return false;
    }
    return true;
}

fn nodeValid(
    node: Node,
    index: usize,
    inputs: []const InputView,
    type_selector_count: usize,
) bool {
    return switch (node) {
        .constant => true,
        .input => |input| input < inputs.len and
            inputs[input].leaf_class != .collection and
            inputs[input].leaf_class != .byte_collection,
        .add => |pair| priorPair(pair, index),
        .maximum => |pair| priorPair(pair, index),
        .scale => |scale| scale.node < index and
            coefficientValid(scale.coefficient, type_selector_count),
        .product => |pair| priorPair(pair, index),
        .alignment => |aligned| aligned.node < index and
            alignmentValid(aligned.alignment, type_selector_count),
        .ceiling_division => |pair| priorPair(pair, index),
        .conditional => |conditional| conditionalValid(conditional, index),
        .next_power_of_two => |value| value < index,
        .collection => |projection| collectionValid(projection, inputs),
    };
}

fn collectionValid(
    projection: CollectionProjection,
    inputs: []const InputView,
) bool {
    return switch (projection) {
        .length => |input| input < inputs.len and switch (inputs[input].leaf_class) {
            .collection, .byte_collection => true,
            .unsigned_integer, .signed_integer => false,
        },
        .byte_count => |count| count.input < inputs.len and
            inputs[count.input].leaf_class == .byte_collection,
    };
}

fn coefficientValid(value: Coefficient, type_selector_count: usize) bool {
    return switch (value) {
        .size_of_concrete_type => |selector| selector < type_selector_count,
        else => true,
    };
}

fn alignmentValid(value: Alignment, type_selector_count: usize) bool {
    return switch (value) {
        .literal => |alignment| alignment != 0 and
            std.math.isPowerOfTwo(alignment),
        .concrete_type => |selector| selector < type_selector_count,
    };
}

fn conditionalValid(value: Conditional, index: usize) bool {
    return value.predicate.left < index and value.predicate.right < index and
        value.when_true < index and value.when_false < index;
}

fn priorPair(pair: Pair, index: usize) bool {
    return pair.left < index and pair.right < index;
}

fn classifyLeaf(comptime T: type) ?LeafClass {
    return switch (@typeInfo(T)) {
        .int => |integer| if (integer.bits > 64) null else switch (integer.signedness) {
            .unsigned => .unsigned_integer,
            .signed => .signed_integer,
        },
        .pointer => |pointer| if (pointer.size == .slice)
            if (pointer.child == u8) .byte_collection else .collection
        else
            null,
        else => null,
    };
}

fn symbolValid(value: []const u8) bool {
    if (value.len == 0 or value.len > symbol_bytes_max) return false;
    if (value[0] < 'a' or value[0] > 'z') return false;
    for (value[1..]) |byte| {
        const lower = byte >= 'a' and byte <= 'z';
        const digit = byte >= '0' and byte <= '9';
        if (!lower and !digit and byte != '_') return false;
    }
    return true;
}

fn pathTextValid(value: []const u8) bool {
    if (value.len == 0 or value.len > field_path_bytes_max) return false;
    if (value[0] == '.' or value[value.len - 1] == '.') return false;
    var component_bytes: usize = 0;
    for (value) |byte| {
        if (byte == '.') {
            if (component_bytes == 0) return false;
            component_bytes = 0;
            continue;
        }
        const alpha = std.ascii.isAlphabetic(byte);
        if (!alpha and !std.ascii.isDigit(byte) and byte != '_') return false;
        component_bytes += 1;
    }
    return component_bytes != 0;
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

fn addInput(builder: *DigestBuilder, input: InputView) void {
    builder.addBytes("input_id", input.id);
    builder.addEnum("input_leaf_class", input.leaf_class);
    builder.addCount("field_path", input.field_path.len);
    for (input.field_path.ordinals[0..input.field_path.len]) |ordinal| {
        builder.addU64(ordinal);
    }
}

fn addNode(builder: *DigestBuilder, node: Node) void {
    builder.addEnum("node", node);
    switch (node) {
        .constant => |value| builder.addU64(value),
        .input => |value| builder.addU64(value),
        .add => |pair| addPair(builder, pair),
        .maximum => |pair| addPair(builder, pair),
        .scale => |scale| {
            builder.addU64(scale.node);
            builder.addEnum("coefficient", scale.coefficient);
            switch (scale.coefficient) {
                inline else => |value| builder.addU64(value),
            }
        },
        .product => |pair| addPair(builder, pair),
        .alignment => |aligned| {
            builder.addU64(aligned.node);
            builder.addEnum("alignment", aligned.alignment);
            switch (aligned.alignment) {
                inline else => |value| builder.addU64(value),
            }
        },
        .ceiling_division => |pair| addPair(builder, pair),
        .conditional => |conditional| {
            builder.addEnum("comparison", conditional.predicate.comparison);
            builder.addU64(conditional.predicate.left);
            builder.addU64(conditional.predicate.right);
            builder.addU64(conditional.when_true);
            builder.addU64(conditional.when_false);
        },
        .next_power_of_two => |value| builder.addU64(value),
        .collection => |projection| {
            builder.addEnum("collection_projection", projection);
            switch (projection) {
                .length => |input| builder.addU64(input),
                .byte_count => |count| {
                    builder.addU64(count.input);
                    builder.addU64(count.byte);
                },
            }
        },
    }
}

fn addPair(builder: *DigestBuilder, pair: Pair) void {
    builder.addU64(pair.left);
    builder.addU64(pair.right);
}

fn addAssertion(builder: *DigestBuilder, assertion: Assertion) void {
    builder.addEnum("scope", assertion.scope);
    builder.addEnum("measure", assertion.measure);
    builder.addEnum("relation", assertion.relation);
    builder.addU64(assertion.expression);
}

const ViewLifetimeFixture = struct {
    const Limits = struct { count: u16, bytes: u32 };
    const value: Spec = .{
        .inputs = &.{
            bindInput(Limits, "count", "count"),
            bindInput(Limits, "bytes", "bytes"),
        },
        .type_selectors = &.{bindType(u64, "word")},
        .nodes = &.{
            .{ .input = 0 },
            .{ .input = 1 },
            .{ .add = .{ .left = 0, .right = 1 } },
            .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 0 } } },
        },
        .assertions = &.{.{
            .scope = .closure_total,
            .measure = .retained,
            .relation = .exact,
            .expression = 3,
        }},
    };

    noinline fn returned() View {
        return view(value);
    }

    noinline fn reuseStack() void {
        var bytes: [4096]u8 = @splat(0xa5);
        std.mem.doNotOptimizeAway(&bytes);
    }
};
