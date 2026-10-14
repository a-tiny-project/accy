const builtin = @import("builtin");
const ir = @import("../../core/root.zig");
const arith = @import("root.zig");
const types = arith.types;
const scalar = arith.scalar;
const facts = ir.interfaces.effects;
const admission = arith.admission;

/// An operand's literal is the `value` of the `arith.constant` that defines it.
pub const literal = facts.LiteralSource{ .operation = "arith.constant", .attribute = "value" };

/// Tests read the declaration's own refusal here, because only core builds an `EffectSubject`.
pub threadlocal var refusal_probe: ?*?admission.Refusal = null;

pub fn entry(comptime operation: admission.Operation) ir.interfaces.InterfaceEntry {
    return facts.EffectOpInterface.entryFor(.{
        .capacity = .{ .entries = 6, .per_result = 1 },
        .literal = literal,
        .enumerate = struct {
            fn enumerate(subject: facts.EffectSubject, collector: *facts.Collector) void {
                declare(subject, collector, operation);
            }
        }.enumerate,
    });
}

/// A declaration is complete exactly when the dialect admits the shape. The facts below are the
/// admitted shape's: the floating premise for a float kind and the value-dependent requirements
/// of division, shifts and float to integer conversion. A lane-wise operation carries its
/// scalar operation's facts, and a requirement on a vector operand holds in every lane.
fn declare(
    subject: facts.EffectSubject,
    collector: *facts.Collector,
    operation: admission.Operation,
) void {
    collector.valueResults(subject);
    const shape = admission.classify(operation, subject) catch {
        if (builtin.is_test) {
            if (refusal_probe) |probe| probe.* = admission.refuse(operation, subject);
        }
        return;
    };
    collector.complete = true;
    switch (shape.form) {
        .constant, .overflow => {},
        .same => {
            if (types.scalarKindIsFloat(shape.element)) {
                return floatingEnvironment(subject, collector);
            }
            switch (operation) {
                .div, .rem => division(subject, collector, shape),
                .shl, .shr, .ushr => shift(subject, collector, shape),
                else => {},
            }
        },
        .cast, .bitcast => {
            const source = shape.source.?;
            if (shape.form == .cast and types.scalarKindIsFloat(source) and
                types.scalarKindIsInteger(shape.element))
            {
                floatConversion(subject, collector, source, shape.element);
            }
            if (types.scalarKindIsFloat(source) or types.scalarKindIsFloat(shape.element)) {
                floatingEnvironment(subject, collector);
            }
        },
        .compare,
        .select,
        .vector_constant,
        .splat,
        .extract,
        .insert,
        .vector_compare,
        .shuffle,
        => if (types.scalarKindIsFloat(shape.element)) floatingEnvironment(subject, collector),
    }
}

/// Every floating declaration uses this one Context premise.
fn floatingEnvironment(subject: facts.EffectSubject, collector: *facts.Collector) void {
    if (subject.arithmeticPolicy().permitsFloatingValues()) {
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

/// A literal operand discharges a requirement for a scalar only. Over lanes the requirement is
/// always declared.
fn division(
    subject: facts.EffectSubject,
    collector: *facts.Collector,
    shape: admission.Shape,
) void {
    const typ = shape.element;
    const bits = types.scalarBitWidth(typ);
    const rhs = if (shape.lanes == 1) subject.operandLiteralInt(1) else null;
    const nonzero = if (rhs) |value| scalar.maskToBits(value, bits) != 0 else false;
    if (!nonzero) failure(collector, .nonzero, 1, "DivisionByZero");
    if (types.scalarKindIsUnsignedInteger(typ) or typ == .index) return;
    const representable = if (rhs) |right|
        scalar.truncate(right, bits) != -1 or if (subject.operandLiteralInt(0)) |left|
            @as(i128, scalar.truncate(left, bits)) != scalar.intLimits(bits).min
        else
            false
    else
        false;
    if (!representable) failure(collector, .quotient_representable, 0, "SignedDivisionOverflow");
}

fn shift(subject: facts.EffectSubject, collector: *facts.Collector, shape: admission.Shape) void {
    if (shape.lanes == 1) {
        if (subject.operandLiteralInt(1)) |count| {
            if (scalar.shiftCount(count, types.scalarBitWidth(shape.element)) != null) return;
        }
    }
    failure(collector, .in_bounds, 1, "InvalidShiftAmount");
}

fn floatConversion(
    subject: facts.EffectSubject,
    collector: *facts.Collector,
    source: types.ScalarKind,
    result: types.ScalarKind,
) void {
    const admitted = admitted: {
        const value = subject.operandLiteralFloat(0) orelse break :admitted false;
        const rounded = arith.eval.roundedFloat(value, source) catch
            break :admitted false;
        break :admitted scalar.floatToInt(
            rounded,
            types.scalarBitWidth(result),
            types.scalarKindIsSignedInteger(result) and result != .index,
        ) != null;
    };
    if (!admitted) failure(collector, .conversion_representable, 0, "InvalidFloatToInteger");
}
