const std = @import("std");
const ir = @import("../../core/root.zig");
const arith = @import("root.zig");
const types = arith.types;
const scalar = arith.scalar;
const facts = ir.interfaces.effects;

/// Each registered operation selects one declaration, independently of pass policy.
pub const Kind = enum {
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

pub fn entries(comptime kind: Kind) []const ir.interfaces.InterfaceEntry {
    return &.{facts.EffectOpInterface.entryFor(.{
        .capacity = .{ .entries = 6, .per_result = 1 },
        .enumerate = struct {
            fn enumerate(op: *const ir.Operation, collector: *facts.Collector) void {
                declare(op, collector, kind);
            }
        }.enumerate,
    })};
}

fn declare(op: *const ir.Operation, collector: *facts.Collector, kind: Kind) void {
    collector.valueResults(op);
    if (kind == .addo or kind == .subo or kind == .mulo) {
        if (op.getNumOperands() != 2 or op.getNumResults() != 2) return;
        if (op.regions.items.len != 0) return;
        for (op.getOperandValues()) |operand| {
            if (types.scalarKindFromType(operand.type) != .i64) return;
        }
        if (types.scalarKindFromType(op.results.items[0].type) != .i64) return;
        if (types.scalarKindFromType(op.results.items[1].type) != .bool) return;
        collector.complete = true;
        return;
    }
    if (op.getNumResults() != 1 or op.regions.items.len != 0) return;
    const typ = op.results.items[0].type;
    if (kind == .constant) {
        if (op.getNumOperands() != 0) return;
        collector.complete = constantMatches(op, types.scalarKindFromType(typ) orelse return);
        return;
    }
    if (vectorOperation(kind)) return declareVector(op, collector, kind);
    const result_kind = types.scalarKindFromType(typ) orelse return;
    if (kind == .cast or kind == .bitcast) return declareCast(op, collector, kind, result_kind);
    if (kind == .cmp) return declareComparison(op, collector, result_kind);
    if (kind == .select) return declareSelect(op, collector, result_kind);
    if (op.getNumOperands() != arity(kind)) return;
    for (op.getOperandValues()) |operand| if (!operand.type.eql(typ)) return;
    if (!supports(kind, result_kind)) return;
    collector.complete = true;
    if (types.scalarKindIsFloat(result_kind)) return floatingEnvironment(op, collector);
    switch (kind) {
        .div, .rem => division(op, collector, result_kind),
        .shl, .shr, .ushr => shift(op, collector, result_kind),
        else => {},
    }
}

fn arity(kind: Kind) usize {
    return switch (kind) {
        .neg,
        .abs,
        .not,
        .popcount,
        .sqrt,
        .exp,
        .log,
        .tanh,
        .sin,
        .cos,
        .tan,
        .floor,
        .round,
        .trunc,
        => 1,
        .fma => 3,
        else => 2,
    };
}

fn supports(kind: Kind, typ: types.ScalarKind) bool {
    const integer = types.scalarKindIsInteger(typ);
    const floating = types.scalarKindIsFloat(typ);
    return switch (kind) {
        .add, .sub, .mul, .div, .neg, .abs, .min, .max => integer or floating,
        .@"and", .@"or", .xor, .not => integer or typ == .bool,
        .rem, .popcount, .umulhi, .shl, .shr, .ushr => integer,
        .fma, .sqrt, .exp, .log, .tanh, .sin, .cos, .tan, .pow, .floor, .round, .trunc => floating,
        else => false,
    };
}

/// Ruling 36: every floating declaration uses this one Context premise.
fn floatingEnvironment(op: *const ir.Operation, collector: *facts.Collector) void {
    if (op.getContext().arithmetic_policy.permitsFloatingValues()) {
        collector.append(.{ .premise = .floating_environment });
        return;
    }
    collector.append(.{ .event = .{
        .kind = .state_observe,
        .resource = .{
            .subject = .{ .global = "arithmetic.environment" },
            .state_key = "floating_environment",
        },
    } });
    collector.append(.{ .requirement = .{ .kind = .execution_context, .subject = .operation } });
}

fn failure(
    collector: *facts.Collector,
    requirement: facts.RequirementKind,
    operand: usize,
    name: []const u8,
) void {
    collector.append(.{ .requirement = .{
        .kind = requirement,
        .subject = .{ .operand = operand },
    } });
    collector.append(.{ .event = .{ .kind = .failure, .failure_name = name } });
}

fn literal(value: *ir.Value) ?ir.Attribute {
    const raw = value.getDefiningOp() orelse return null;
    const definition: *ir.Operation = @ptrCast(@alignCast(raw));
    if (!std.mem.eql(u8, definition.name.name, "arith.constant")) return null;
    return definition.getAttr("value");
}

fn literalInt(op: *const ir.Operation, index: usize) ?i64 {
    const attr = literal(op.operands.items[index].value) orelse return null;
    return (attr.cast(ir.Attribute.IntegerAttr) orelse return null).getValue();
}

fn division(op: *const ir.Operation, collector: *facts.Collector, typ: types.ScalarKind) void {
    const bits = types.scalarBitWidth(typ);
    const rhs = literalInt(op, 1);
    const nonzero = if (rhs) |value| scalar.maskToBits(value, bits) != 0 else false;
    if (!nonzero) failure(collector, .nonzero, 1, "DivisionByZero");
    if (types.scalarKindIsUnsignedInteger(typ) or typ == .index) return;
    const representable = if (rhs) |right|
        scalar.truncate(right, bits) != -1 or if (literalInt(op, 0)) |left|
            @as(i128, scalar.truncate(left, bits)) != scalar.intLimits(bits).min
        else
            false
    else
        false;
    if (!representable) failure(collector, .quotient_representable, 0, "SignedDivisionOverflow");
}

fn shift(op: *const ir.Operation, collector: *facts.Collector, typ: types.ScalarKind) void {
    if (literalInt(op, 1)) |count| {
        if (scalar.shiftCount(count, types.scalarBitWidth(typ)) != null) return;
    }
    failure(collector, .in_bounds, 1, "InvalidShiftAmount");
}

fn constantMatches(op: *const ir.Operation, kind: types.ScalarKind) bool {
    const attr = op.getAttr("value") orelse return false;
    return switch (types.scalarDescriptor(kind).class) {
        .boolean => attr.cast(ir.Attribute.BoolAttr) != null or
            attr.cast(ir.Attribute.IntegerAttr) != null,
        .signed_integer, .unsigned_integer, .index => attr.cast(ir.Attribute.IntegerAttr) != null,
        .float => attr.cast(ir.Attribute.FloatAttr) != null,
    };
}

fn declareCast(
    op: *const ir.Operation,
    collector: *facts.Collector,
    kind: Kind,
    result: types.ScalarKind,
) void {
    if (op.getNumOperands() != 1) return;
    const source = types.scalarKindFromType(op.operands.items[0].value.type) orelse return;
    if (kind == .bitcast) {
        if (types.scalarBitWidth(source) != types.scalarBitWidth(result)) return;
    } else {
        if (source == .bool or result == .bool) {
            if (source != result) return;
        }
    }
    collector.complete = true;
    if (kind == .cast and types.scalarKindIsFloat(source) and types.scalarKindIsInteger(result)) {
        floatConversion(op, collector, source, result);
    }
    if (types.scalarKindIsFloat(source) or types.scalarKindIsFloat(result)) {
        floatingEnvironment(op, collector);
    }
}

fn floatConversion(
    op: *const ir.Operation,
    collector: *facts.Collector,
    source: types.ScalarKind,
    result: types.ScalarKind,
) void {
    const admitted = admitted: {
        const attr = literal(op.operands.items[0].value) orelse break :admitted false;
        const value = attr.cast(ir.Attribute.FloatAttr) orelse break :admitted false;
        const rounded = arith.eval.roundedFloat(value.getValue(), source) catch
            break :admitted false;
        break :admitted scalar.floatToInt(
            rounded,
            types.scalarBitWidth(result),
            types.scalarKindIsSignedInteger(result) and result != .index,
        ) != null;
    };
    if (!admitted) failure(collector, .conversion_representable, 0, "InvalidFloatToInteger");
}

fn validPredicate(op: *const ir.Operation, kind: types.ScalarKind) bool {
    const attr = op.getAttrAs(ir.Attribute.DialectAttr, "predicate") orelse return false;
    const predicate = std.meta.stringToEnum(arith.CmpPredicate, attr.payload) orelse return false;
    if (kind == .bool) return predicate == .eq or predicate == .ne;
    if (!types.scalarKindIsFloat(kind)) return true;
    return switch (predicate) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn declareComparison(
    op: *const ir.Operation,
    collector: *facts.Collector,
    result: types.ScalarKind,
) void {
    if (result != .bool or op.getNumOperands() != 2) return;
    const lhs = op.operands.items[0].value.type;
    if (!lhs.eql(op.operands.items[1].value.type)) return;
    const kind = types.scalarKindFromType(lhs) orelse return;
    if (!validPredicate(op, kind)) return;
    collector.complete = true;
    if (types.scalarKindIsFloat(kind)) floatingEnvironment(op, collector);
}

fn declareSelect(
    op: *const ir.Operation,
    collector: *facts.Collector,
    kind: types.ScalarKind,
) void {
    if (op.getNumOperands() != 3) return;
    if (types.scalarKindFromType(op.operands.items[0].value.type) != .bool) return;
    for (op.getOperandValues()[1..]) |operand| {
        if (!operand.type.eql(op.results.items[0].type)) return;
    }
    collector.complete = true;
    if (types.scalarKindIsFloat(kind)) floatingEnvironment(op, collector);
}

fn vectorOperation(kind: Kind) bool {
    return switch (kind) {
        .splat, .extract, .insert, .vec_cmp, .vec_shuffle, .vec_constant => true,
        else => false,
    };
}

fn vector(typ: ir.Type) ?types.VectorTypeInfo {
    return types.parseVectorTypeName(typ.getDialectTypeName() orelse return null);
}

fn declareVector(op: *const ir.Operation, collector: *facts.Collector, kind: Kind) void {
    const result = op.results.items[0].type;
    const shape = if (kind == .extract or kind == .vec_cmp) shape: {
        if (op.getNumOperands() != (if (kind == .extract) @as(usize, 1) else 2)) return;
        break :shape vector(op.operands.items[0].value.type) orelse return;
    } else vector(result) orelse return;
    const element = types.scalarKindFromTypeName(shape.elem_type_name).?;
    if (!validVector(op, kind, shape, element)) return;
    collector.complete = true;
    if (types.scalarKindIsFloat(element)) floatingEnvironment(op, collector);
}

fn validVector(
    op: *const ir.Operation,
    kind: Kind,
    shape: types.VectorTypeInfo,
    element: types.ScalarKind,
) bool {
    const result = op.results.items[0].type;
    switch (kind) {
        .vec_constant => return op.getNumOperands() == 0 and constantMatches(op, element),
        .splat => return op.getNumOperands() == 1 and
            types.scalarKindFromType(op.operands.items[0].value.type) == element,
        .extract => {
            if (types.scalarKindFromType(result) != element) return false;
            return validLane(op, shape.width);
        },
        .insert => {
            if (op.getNumOperands() != 2) return false;
            if (!op.operands.items[0].value.type.eql(result)) return false;
            if (types.scalarKindFromType(op.operands.items[1].value.type) != element) return false;
            return validLane(op, shape.width);
        },
        .vec_cmp => {
            if (op.getNumOperands() != 2) return false;
            if (!op.operands.items[0].value.type.eql(op.operands.items[1].value.type)) return false;
            const mask = vector(result) orelse return false;
            if (mask.width != shape.width) return false;
            const mask_kind = types.scalarKindFromTypeName(mask.elem_type_name) orelse return false;
            if (types.scalarBitWidth(mask_kind) != types.scalarBitWidth(element)) return false;
            if (mask_kind != element and !types.scalarKindIsInteger(mask_kind)) return false;
            return validPredicate(op, element);
        },
        .vec_shuffle => return validShuffle(op, shape, element),
        else => unreachable,
    }
}

fn validLane(op: *const ir.Operation, width: u32) bool {
    const attr = op.getAttrAs(ir.Attribute.IntegerAttr, "index") orelse return false;
    const index = attr.getValue();
    return index >= 0 and index < width;
}

fn validShuffle(
    op: *const ir.Operation,
    result: types.VectorTypeInfo,
    element: types.ScalarKind,
) bool {
    if (op.getNumOperands() != 1) return false;
    const source = vector(op.operands.items[0].value.type) orelse return false;
    if (types.scalarKindFromTypeName(source.elem_type_name) != element) return false;
    const attr = op.getAttrAs(ir.Attribute.StringAttr, "indices") orelse return false;
    var chunks = std.mem.splitScalar(u8, attr.value, ',');
    for (0..result.width) |_| {
        const chunk = chunks.next() orelse return false;
        const index = std.fmt.parseInt(i64, chunk, 10) catch return false;
        if (index < 0 or index >= source.width) return false;
    }
    return chunks.next() == null;
}
