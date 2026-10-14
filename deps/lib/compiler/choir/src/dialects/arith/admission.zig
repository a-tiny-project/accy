//! The one owner of "operation O admits shape S" for the arith dialect. A shape is an
//! operation's operand and result types plus the attributes that select its meaning. The effect
//! declaration, the verifier entry and the evaluator's admission each ask `refuse` and keep no
//! copy of the rule.
const std = @import("std");
const ir = @import("../../core/root.zig");
const arith = @import("root.zig");
const types = arith.types;
const CmpPredicate = arith.CmpPredicate;
const ScalarKind = types.ScalarKind;
const ScalarSet = types.ScalarSet;
const Constraint = ir.interfaces.OperationTypeConstraint;

/// One value per arith operation that carries an effect declaration.
pub const Operation = enum {
    constant,
    add,
    sub,
    mul,
    div,
    rem,
    neg,
    abs,
    min,
    max,
    umulhi,
    @"and",
    @"or",
    xor,
    not,
    popcount,
    shl,
    shr,
    ushr,
    fma,
    sqrt,
    exp,
    log,
    log1p,
    expm1,
    tanh,
    sin,
    cos,
    tan,
    pow,
    floor,
    round,
    trunc,
    cmp,
    select,
    cast,
    bitcast,
    splat,
    extract,
    insert,
    vec_cmp,
    vec_shuffle,
    vec_constant,
    addo,
    subo,
    mulo,
};

/// Which positions an operation's kinds occupy, and which rule relates them.
pub const Form = enum {
    /// Every operand type equals the one result type.
    same,
    constant,
    compare,
    select,
    cast,
    bitcast,
    overflow,
    vector_constant,
    splat,
    extract,
    insert,
    vector_compare,
    shuffle,
};

pub const Row = struct {
    form: Form,
    operands: u8,
    results: u8 = 1,
    /// The scalar kinds the form's ruling position admits.
    scalars: ScalarSet = .{},
    /// The element kinds admitted when that position is a vector type.
    lanes: ScalarSet = .{},
};

const integers = ScalarSet.init(&.{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index });
const floats = ScalarSet.init(&.{ .f16, .bf16, .f32, .f64 });
const numeric = ScalarSet{ .bits = integers.bits | floats.bits };
const logical = ScalarSet{ .bits = integers.bits | ScalarSet.init(&.{.bool}).bits };
const every = ScalarSet{ .bits = numeric.bits | logical.bits };

fn same(operands: u8, scalars: ScalarSet, lanes: ScalarSet) Row {
    return .{ .form = .same, .operands = operands, .scalars = scalars, .lanes = lanes };
}

fn derive(operation: Operation) Row {
    return switch (operation) {
        .add, .sub, .mul, .div => same(2, numeric, numeric),
        .neg => same(1, numeric, numeric),
        .min, .max => same(2, numeric, integers),
        .abs => same(1, numeric, .{}),
        .@"and", .@"or", .xor => same(2, logical, integers),
        .not => same(1, logical, integers),
        .shl, .shr, .ushr, .umulhi => same(2, integers, integers),
        .popcount => same(1, integers, integers),
        .rem => same(2, integers, .{}),
        .fma => same(3, floats, .{}),
        .pow => same(2, floats, .{}),
        .sqrt, .exp, .log, .log1p, .expm1, .tanh, .sin, .cos, .tan, .floor, .round, .trunc => same(1, floats, .{}),
        .constant => .{ .form = .constant, .operands = 0, .scalars = every },
        .cmp => .{ .form = .compare, .operands = 2, .scalars = every },
        .select => .{ .form = .select, .operands = 3, .scalars = every, .lanes = numeric },
        .cast => .{ .form = .cast, .operands = 1, .scalars = every },
        .bitcast => .{ .form = .bitcast, .operands = 1, .scalars = every },
        .addo, .subo, .mulo => .{
            .form = .overflow,
            .operands = 2,
            .results = 2,
            .scalars = ScalarSet.init(&.{.i64}),
        },
        .vec_constant => .{ .form = .vector_constant, .operands = 0, .lanes = numeric },
        .splat => .{ .form = .splat, .operands = 1, .lanes = numeric },
        .extract => .{ .form = .extract, .operands = 1, .lanes = numeric },
        .insert => .{ .form = .insert, .operands = 2, .lanes = numeric },
        .vec_cmp => .{ .form = .vector_compare, .operands = 2, .lanes = numeric },
        .vec_shuffle => .{ .form = .shuffle, .operands = 1, .lanes = numeric },
    };
}

const rows = table: {
    const operations = std.enums.values(Operation);
    var table: [operations.len]Row = undefined;
    for (operations) |operation| table[@backingInt(operation)] = derive(operation);
    break :table table;
};

/// 44 rows of read-only data, one load per question.
pub fn row(operation: Operation) Row {
    return rows[@backingInt(operation)];
}

const boolean_position = [_]Constraint{.{ .index = 0, .type_name = types.type_names.boolean }};
const overflow_operands = [_]Constraint{
    .{ .index = 0, .type_name = types.type_names.int64 },
    .{ .index = 1, .type_name = types.type_names.int64 },
};
const overflow_results = [_]Constraint{
    .{ .index = 0, .type_name = types.type_names.int64 },
    .{ .index = 1, .type_name = types.type_names.boolean },
};

/// The operand positions a form fixes to one unparameterized type. The operation spec registers
/// these as its type constraints and `refuse` checks the same list.
pub fn exactOperands(form: Form) []const Constraint {
    return switch (form) {
        .select => &boolean_position,
        .overflow => &overflow_operands,
        else => &.{},
    };
}

/// The result positions a form fixes to one unparameterized type.
pub fn exactResults(form: Form) []const Constraint {
    return switch (form) {
        .compare => &boolean_position,
        .overflow => &overflow_results,
        else => &.{},
    };
}

pub const PredicateSet = std.EnumSet(CmpPredicate);

/// The predicates a comparison admits over operands or lanes of `kind`.
pub fn predicates(kind: ScalarKind) PredicateSet {
    if (kind == .bool) return PredicateSet.initMany(&.{ .eq, .ne });
    if (floats.contains(kind)) return PredicateSet.initMany(&.{ .eq, .ne, .lt, .le, .gt, .ge });
    return .full;
}

pub const ArithVerifyError = error{
    ArithOperandCountMismatch,
    ArithResultCountMismatch,
    ArithRegionNotAdmitted,
    ArithExactTypeMismatch,
    ArithOperandTypeMismatch,
    ArithTypeNotArith,
    ArithKindNotAdmitted,
    ArithCastKindMismatch,
    ArithBitcastWidthMismatch,
    ArithPredicateNotAdmitted,
    ArithConstantClassMismatch,
    ArithVectorLaneOutOfRange,
    ArithVectorShapeMismatch,
    ArithShuffleIndicesInvalid,
};

/// Why a shape is refused. `refuse` checks in this order and returns the first that applies.
pub const Reason = enum {
    operand_count_mismatch,
    result_count_mismatch,
    region_not_admitted,
    exact_type_mismatch,
    operand_type_mismatch,
    type_not_arith,
    kind_not_admitted,
    cast_kind_mismatch,
    bitcast_width_mismatch,
    predicate_not_admitted,
    constant_class_mismatch,
    vector_lane_out_of_range,
    vector_shape_mismatch,
    shuffle_indices_invalid,

    pub fn toError(self: Reason) ArithVerifyError {
        return switch (self) {
            .operand_count_mismatch => error.ArithOperandCountMismatch,
            .result_count_mismatch => error.ArithResultCountMismatch,
            .region_not_admitted => error.ArithRegionNotAdmitted,
            .exact_type_mismatch => error.ArithExactTypeMismatch,
            .operand_type_mismatch => error.ArithOperandTypeMismatch,
            .type_not_arith => error.ArithTypeNotArith,
            .kind_not_admitted => error.ArithKindNotAdmitted,
            .cast_kind_mismatch => error.ArithCastKindMismatch,
            .bitcast_width_mismatch => error.ArithBitcastWidthMismatch,
            .predicate_not_admitted => error.ArithPredicateNotAdmitted,
            .constant_class_mismatch => error.ArithConstantClassMismatch,
            .vector_lane_out_of_range => error.ArithVectorLaneOutOfRange,
            .vector_shape_mismatch => error.ArithVectorShapeMismatch,
            .shuffle_indices_invalid => error.ArithShuffleIndicesInvalid,
        };
    }
};

pub const Position = union(enum) {
    operation,
    operand: u8,
    result: u8,
};

pub const Refusal = struct {
    reason: Reason,
    position: Position = .operation,
    /// The scalar or element kind found at `position`, when the position holds an arith type.
    found: ?ScalarKind = null,
    /// The kinds the row admits there, when the refusal is about a kind.
    admitted: ScalarSet = .{},
};

/// What an admitted operation's readers need afterwards, so none of them reclassifies a type.
pub const Shape = struct {
    form: Form,
    /// The scalar kind the form's rule ranges over: the result's kind or element kind, and for
    /// a comparison, an extract or a vector comparison the operand's.
    element: ScalarKind,
    /// 1 for a scalar shape.
    lanes: u8 = 1,
    /// The operand's kind, for a cast or a bitcast.
    source: ?ScalarKind = null,
};

const Outcome = union(enum) {
    admitted: Shape,
    refused: Refusal,
};

/// The verifier's and the evaluator's view of an operation. It answers exactly as the effect
/// declaration's `EffectSubject` does, so one body of `refuse` serves both.
pub const OperationView = struct {
    operation: *const ir.Operation,

    pub fn operandCount(self: OperationView) usize {
        return self.operation.getNumOperands();
    }

    pub fn resultCount(self: OperationView) usize {
        return self.operation.getNumResults();
    }

    pub fn regionCount(self: OperationView) usize {
        return self.operation.getNumRegions();
    }

    pub fn operandType(self: OperationView, index: usize) ir.Type {
        return self.operation.operands.items[index].value.type;
    }

    pub fn resultType(self: OperationView, index: usize) ir.Type {
        return self.operation.results.items[index].type;
    }

    pub fn attr(self: OperationView, name: []const u8) ?ir.Attribute {
        return self.operation.getAttr(name);
    }

    pub fn attrAs(self: OperationView, comptime T: type, name: []const u8) ?*const T {
        return self.operation.getAttrAs(T, name);
    }
};

/// The first reason `operation` does not admit the shape `view` shows, or null. `view` supplies
/// `operandCount`, `resultCount`, `regionCount`, `operandType`, `resultType`, `attr` and
/// `attrAs`. Counts and regions are checked first, so no absent position is indexed and the
/// answer holds for an operation no verifier has seen.
pub fn refuse(operation: Operation, view: anytype) ?Refusal {
    return switch (resolve(operation, view)) {
        .admitted => null,
        .refused => |refusal| refusal,
    };
}

pub fn classify(operation: Operation, view: anytype) ArithVerifyError!Shape {
    return switch (resolve(operation, view)) {
        .admitted => |shape| shape,
        .refused => |refusal| refusal.reason.toError(),
    };
}

fn resolve(operation: Operation, view: anytype) Outcome {
    const rule = row(operation);
    std.debug.assert(rule.operands <= 3);
    std.debug.assert(rule.results >= 1);
    std.debug.assert(rule.results <= 2);
    if (view.operandCount() != rule.operands) return refused(.operand_count_mismatch, .operation);
    if (view.resultCount() != rule.results) return refused(.result_count_mismatch, .operation);
    if (view.regionCount() != 0) return refused(.region_not_admitted, .operation);
    for (exactOperands(rule.form)) |constraint| {
        if (!exactType(view.operandType(constraint.index), constraint)) {
            return refused(.exact_type_mismatch, .{ .operand = @intCast(constraint.index) });
        }
    }
    for (exactResults(rule.form)) |constraint| {
        if (!exactType(view.resultType(constraint.index), constraint)) {
            return refused(.exact_type_mismatch, .{ .result = @intCast(constraint.index) });
        }
    }
    return switch (rule.form) {
        .same => resolveSame(rule, view),
        .constant => resolveConstant(rule, view),
        .compare => resolveCompare(rule, view),
        .select => resolveSelect(rule, view),
        .cast => resolveCast(rule, view),
        .bitcast => resolveBitcast(rule, view),
        .overflow => .{ .admitted = .{ .form = .overflow, .element = .i64 } },
        .vector_constant => resolveVectorConstant(rule, view),
        .splat => resolveSplat(rule, view),
        .extract => resolveExtract(rule, view),
        .insert => resolveInsert(rule, view),
        .vector_compare => resolveVectorCompare(rule, view),
        .shuffle => resolveShuffle(rule, view),
    };
}

/// The verifier's exact constraint, repeated here because a declaration can be inspected and an
/// operation evaluated with no verifier before them.
fn exactType(typ: ir.Type, constraint: Constraint) bool {
    const name = typ.getDialectTypeName() orelse return false;
    if (!std.mem.eql(u8, name, constraint.type_name)) return false;
    return constraint.allow_parameterized or typ.getDialectParamKey() == null;
}

const Vector = struct { element: ScalarKind, lanes: u8 };

const Class = union(enum) {
    scalar: ScalarKind,
    vector: Vector,
    other,
};

fn classOf(typ: ir.Type) Class {
    const name = typ.getDialectTypeName() orelse return .other;
    if (types.scalarKindFromTypeName(name)) |kind| return .{ .scalar = kind };
    const info = types.parseVectorTypeName(name) orelse return .other;
    std.debug.assert(info.width >= 2);
    std.debug.assert(info.width <= 16);
    return .{ .vector = .{
        .element = types.scalarKindFromTypeName(info.elem_type_name).?,
        .lanes = @intCast(info.width),
    } };
}

fn refused(reason: Reason, position: Position) Outcome {
    return .{ .refused = .{ .reason = reason, .position = position } };
}

fn refusedKind(reason: Reason, position: Position, found: ScalarKind, admitted: ScalarSet) Outcome {
    return .{ .refused = .{
        .reason = reason,
        .position = position,
        .found = found,
        .admitted = admitted,
    } };
}

fn resolveSame(rule: Row, view: anytype) Outcome {
    const result = view.resultType(0);
    for (0..rule.operands) |index| {
        if (!view.operandType(index).eql(result)) {
            return refused(.operand_type_mismatch, .{ .operand = @intCast(index) });
        }
    }
    switch (classOf(result)) {
        .other => return refused(.type_not_arith, .{ .result = 0 }),
        .scalar => |kind| {
            if (!rule.scalars.contains(kind)) {
                return refusedKind(.kind_not_admitted, .{ .result = 0 }, kind, rule.scalars);
            }
            return .{ .admitted = .{ .form = .same, .element = kind } };
        },
        .vector => |vector| {
            if (!rule.lanes.contains(vector.element)) {
                const found = vector.element;
                return refusedKind(.kind_not_admitted, .{ .result = 0 }, found, rule.lanes);
            }
            return .{ .admitted = .{
                .form = .same,
                .element = vector.element,
                .lanes = vector.lanes,
            } };
        },
    }
}

fn resolveConstant(rule: Row, view: anytype) Outcome {
    const kind = switch (classOf(view.resultType(0))) {
        .other => return refused(.type_not_arith, .{ .result = 0 }),
        .vector => |vector| return refusedKind(
            .kind_not_admitted,
            .{ .result = 0 },
            vector.element,
            rule.scalars,
        ),
        .scalar => |kind| kind,
    };
    if (!constantMatches(view, kind)) {
        return refusedKind(.constant_class_mismatch, .operation, kind, rule.scalars);
    }
    return .{ .admitted = .{ .form = .constant, .element = kind } };
}

fn resolveCompare(rule: Row, view: anytype) Outcome {
    const operand = view.operandType(0);
    if (!operand.eql(view.operandType(1))) {
        return refused(.operand_type_mismatch, .{ .operand = 1 });
    }
    const kind = switch (classOf(operand)) {
        .other => return refused(.type_not_arith, .{ .operand = 0 }),
        .vector => |vector| return refusedKind(
            .kind_not_admitted,
            .{ .operand = 0 },
            vector.element,
            rule.scalars,
        ),
        .scalar => |kind| kind,
    };
    if (!predicateAdmitted(view, kind)) {
        return refusedKind(.predicate_not_admitted, .operation, kind, rule.scalars);
    }
    return .{ .admitted = .{ .form = .compare, .element = kind } };
}

fn resolveSelect(rule: Row, view: anytype) Outcome {
    const result = view.resultType(0);
    for (1..3) |index| {
        if (!view.operandType(index).eql(result)) {
            return refused(.operand_type_mismatch, .{ .operand = @intCast(index) });
        }
    }
    switch (classOf(result)) {
        .other => return refused(.type_not_arith, .{ .result = 0 }),
        .scalar => |kind| return .{ .admitted = .{ .form = .select, .element = kind } },
        .vector => |vector| {
            if (!rule.lanes.contains(vector.element)) {
                const found = vector.element;
                return refusedKind(.kind_not_admitted, .{ .result = 0 }, found, rule.lanes);
            }
            return .{ .admitted = .{
                .form = .select,
                .element = vector.element,
                .lanes = vector.lanes,
            } };
        },
    }
}

fn resolveCast(rule: Row, view: anytype) Outcome {
    const source = switch (classOf(view.operandType(0))) {
        .other => return refused(.type_not_arith, .{ .operand = 0 }),
        .vector => return refused(.cast_kind_mismatch, .{ .operand = 0 }),
        .scalar => |kind| kind,
    };
    const result = switch (classOf(view.resultType(0))) {
        .other => return refused(.type_not_arith, .{ .result = 0 }),
        .vector => return refused(.cast_kind_mismatch, .{ .result = 0 }),
        .scalar => |kind| kind,
    };
    if ((source == .bool) != (result == .bool)) {
        return refusedKind(.cast_kind_mismatch, .{ .operand = 0 }, source, rule.scalars);
    }
    return .{ .admitted = .{ .form = .cast, .element = result, .source = source } };
}

fn resolveBitcast(rule: Row, view: anytype) Outcome {
    const source = switch (classOf(view.operandType(0))) {
        .other => return refused(.type_not_arith, .{ .operand = 0 }),
        .vector => |vector| return refusedKind(
            .kind_not_admitted,
            .{ .operand = 0 },
            vector.element,
            rule.scalars,
        ),
        .scalar => |kind| kind,
    };
    const result = switch (classOf(view.resultType(0))) {
        .other => return refused(.type_not_arith, .{ .result = 0 }),
        .vector => |vector| return refusedKind(
            .kind_not_admitted,
            .{ .result = 0 },
            vector.element,
            rule.scalars,
        ),
        .scalar => |kind| kind,
    };
    if (types.scalarBitWidth(source) != types.scalarBitWidth(result)) {
        return refusedKind(.bitcast_width_mismatch, .{ .operand = 0 }, source, rule.scalars);
    }
    return .{ .admitted = .{ .form = .bitcast, .element = result, .source = source } };
}

const VectorAt = union(enum) {
    vector: Vector,
    refused: Outcome,
};

/// A position that must hold a vector type.
fn vectorAt(typ: ir.Type, position: Position) VectorAt {
    return switch (classOf(typ)) {
        .other => .{ .refused = refused(.type_not_arith, position) },
        .scalar => .{ .refused = refused(.vector_shape_mismatch, position) },
        .vector => |vector| .{ .vector = vector },
    };
}

/// A position that must hold the scalar type of a vector's element kind.
fn elementAt(typ: ir.Type, position: Position, element: ScalarKind) ?Outcome {
    return switch (classOf(typ)) {
        .other => refused(.type_not_arith, position),
        .vector => refused(.vector_shape_mismatch, position),
        .scalar => |kind| if (kind == element) null else refused(.vector_shape_mismatch, position),
    };
}

fn admittedVector(form: Form, vector: Vector) Outcome {
    return .{ .admitted = .{ .form = form, .element = vector.element, .lanes = vector.lanes } };
}

fn resolveVectorConstant(rule: Row, view: anytype) Outcome {
    const result = switch (vectorAt(view.resultType(0), .{ .result = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    if (!constantMatches(view, result.element)) {
        return refusedKind(.constant_class_mismatch, .operation, result.element, rule.lanes);
    }
    return admittedVector(.vector_constant, result);
}

fn resolveSplat(_: Row, view: anytype) Outcome {
    const result = switch (vectorAt(view.resultType(0), .{ .result = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    if (elementAt(view.operandType(0), .{ .operand = 0 }, result.element)) |outcome| return outcome;
    return admittedVector(.splat, result);
}

fn resolveExtract(_: Row, view: anytype) Outcome {
    const source = switch (vectorAt(view.operandType(0), .{ .operand = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    if (elementAt(view.resultType(0), .{ .result = 0 }, source.element)) |outcome| return outcome;
    if (!laneInRange(view, source.lanes)) return refused(.vector_lane_out_of_range, .operation);
    return admittedVector(.extract, source);
}

fn resolveInsert(_: Row, view: anytype) Outcome {
    const result = switch (vectorAt(view.resultType(0), .{ .result = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    if (!view.operandType(0).eql(view.resultType(0))) {
        return refused(.vector_shape_mismatch, .{ .operand = 0 });
    }
    if (elementAt(view.operandType(1), .{ .operand = 1 }, result.element)) |outcome| return outcome;
    if (!laneInRange(view, result.lanes)) return refused(.vector_lane_out_of_range, .operation);
    return admittedVector(.insert, result);
}

/// A mask lane has its operand lane's width and is either the operand's own kind or an integer.
fn resolveVectorCompare(rule: Row, view: anytype) Outcome {
    const operand = view.operandType(0);
    if (!operand.eql(view.operandType(1))) {
        return refused(.operand_type_mismatch, .{ .operand = 1 });
    }
    const source = switch (vectorAt(operand, .{ .operand = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    const mask = switch (vectorAt(view.resultType(0), .{ .result = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    const fits = mask.lanes == source.lanes and
        types.scalarBitWidth(mask.element) == types.scalarBitWidth(source.element) and
        (mask.element == source.element or integers.contains(mask.element));
    if (!fits) return refused(.vector_shape_mismatch, .{ .result = 0 });
    if (!predicateAdmitted(view, source.element)) {
        return refusedKind(.predicate_not_admitted, .operation, source.element, rule.lanes);
    }
    return admittedVector(.vector_compare, source);
}

fn resolveShuffle(_: Row, view: anytype) Outcome {
    const result = switch (vectorAt(view.resultType(0), .{ .result = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    const source = switch (vectorAt(view.operandType(0), .{ .operand = 0 })) {
        .refused => |outcome| return outcome,
        .vector => |vector| vector,
    };
    if (source.element != result.element) return refused(.vector_shape_mismatch, .{ .operand = 0 });
    if (!shuffleIndicesValid(view, source.lanes, result.lanes)) {
        return refused(.shuffle_indices_invalid, .operation);
    }
    return admittedVector(.shuffle, result);
}

fn constantMatches(view: anytype, kind: ScalarKind) bool {
    const attr = view.attr("value") orelse return false;
    return switch (types.scalarDescriptor(kind).class) {
        .boolean => attr.cast(ir.Attribute.BoolAttr) != null or
            attr.cast(ir.Attribute.IntegerAttr) != null,
        .signed_integer, .unsigned_integer, .index => attr.cast(ir.Attribute.IntegerAttr) != null,
        .float => attr.cast(ir.Attribute.FloatAttr) != null,
    };
}

fn predicateAdmitted(view: anytype, kind: ScalarKind) bool {
    const attr = view.attrAs(ir.Attribute.DialectAttr, "predicate") orelse return false;
    const predicate = std.meta.stringToEnum(CmpPredicate, attr.payload) orelse return false;
    return predicates(kind).contains(predicate);
}

fn laneInRange(view: anytype, lanes: u8) bool {
    const attr = view.attrAs(ir.Attribute.IntegerAttr, "index") orelse return false;
    const index = attr.getValue();
    return index >= 0 and index < lanes;
}

/// One decimal index per result lane, each naming a source lane. The work is the result's lane
/// count plus the bytes of the index string.
fn shuffleIndicesValid(view: anytype, source_lanes: u8, result_lanes: u8) bool {
    std.debug.assert(source_lanes <= 16);
    std.debug.assert(result_lanes <= 16);
    const attr = view.attrAs(ir.Attribute.StringAttr, "indices") orelse return false;
    var chunks = std.mem.splitScalar(u8, attr.value, ',');
    for (0..result_lanes) |_| {
        const chunk = chunks.next() orelse return false;
        const index = std.fmt.parseInt(i64, chunk, 10) catch return false;
        if (index < 0 or index >= source_lanes) return false;
    }
    return chunks.next() == null;
}

/// The verifier entry runs these in this order and the first refusal wins. Each landing turns on
/// the check it owns: `shape` refuses what `refuse` returns, `predicate` refuses a comparison
/// whose predicate does not state its order for the operand's kind, and `word` refuses an integer
/// constant whose word is not the canonical one for its kind.
pub const Check = enum { shape, predicate, word };

pub const enabled = std.EnumSet(Check).empty;

fn run(comptime check: Check, operation: Operation, view: OperationView) ArithVerifyError!void {
    switch (check) {
        .shape => if (refuse(operation, view)) |refusal| return refusal.reason.toError(),
        .predicate => @compileError("the predicate check is not written yet"),
        .word => @compileError("the constant word check is not written yet"),
    }
}

fn Verifier(comptime operation: Operation) type {
    return struct {
        fn verify(op_ptr: *const anyopaque) anyerror!void {
            const view = OperationView{ .operation = @ptrCast(@alignCast(op_ptr)) };
            inline for (comptime std.enums.values(Check)) |check| {
                if (comptime enabled.contains(check)) try run(check, operation, view);
            }
        }
    };
}

/// Every declared arith operation carries these two entries: its effect declaration and the one
/// common verifier entry. No arith operation type writes its own `verify`, which an explicit
/// verifier entry would silently replace.
pub fn entries(comptime operation: Operation) []const ir.interfaces.InterfaceEntry {
    return &.{
        arith.effects.entry(operation),
        ir.VerifyOpInterface.entryFor(Verifier(operation).verify),
    };
}

/// Fails the build when an operation type of `Dialect` declares `verify`.
pub fn assertCommonVerifier(comptime Dialect: type) void {
    for (std.meta.declarations(Dialect)) |name| {
        const Declared = @TypeOf(@field(Dialect, name));
        if (Declared != type) continue;
        const Candidate = @field(Dialect, name);
        if (@typeInfo(Candidate) != .@"struct") continue;
        if (@hasDecl(Candidate, "operation_spec") and @hasDecl(Candidate, "verify")) {
            @compileError("arith." ++ name ++ " declares verify: add a check to admission.zig");
        }
    }
}
