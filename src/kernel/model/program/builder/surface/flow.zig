const gpu_abi = @import("gpu_abi");
const core = @import("../../../core/root.zig");

const builder = core.builder;
const typed = core.typed;

const DType = gpu_abi.DType;

pub fn forDo(owner: anytype, lower: builder.Value, upper: builder.Value, step: builder.Value, context: anytype, comptime body: anytype) !builder.For {
    var scope = try owner.forScope(lower, upper, step, &.{}, &.{});
    errdefer scope.abort();
    try body(owner, scope.inductionVar(), context);
    try scope.leave(&.{});
    return scope.loop;
}

pub fn forValueDo(owner: anytype, comptime dtype: DType, lower: builder.Value, upper: builder.Value, step: builder.Value, context: anytype, comptime body: anytype) !builder.For {
    var scope = try owner.forScope(lower, upper, step, &.{}, &.{});
    errdefer scope.abort();
    try body(owner, try owner.castValue(scope.inductionVar(), dtype), context);
    try scope.leave(&.{});
    return scope.loop;
}

pub fn fold(owner: anytype, lower: builder.Value, upper: builder.Value, step: builder.Value, initial: anytype, context: anytype, comptime body: anytype) !@TypeOf(initial) {
    const raw_initial = typed.raw(initial);
    var scope = try owner.forScope(lower, upper, step, &.{raw_initial}, &.{raw_initial.valueType()});
    errdefer scope.abort();
    const next = try body(owner, try loopIndexLike(owner, initial, scope.inductionVar()), typed.wrapValueLike(initial, scope.iterArg(0).?), context);
    try scope.leave(&.{typed.raw(next)});
    return typed.wrapValueLike(initial, scope.result(0).?);
}

pub fn whileLoop(owner: anytype, initial: anytype, context: anytype, comptime condition: anytype, comptime body: anytype) !@TypeOf(initial) {
    const carry_count = comptime carryCount(@TypeOf(initial));
    if (comptime carry_count == 0) @compileError("whileLoop requires at least one carry value");
    var init_args: [carry_count]builder.Value = undefined;
    var init_index: usize = 0;
    collectCarryValues(initial, init_args[0..], &init_index);

    var result_types: [carry_count]builder.Type = undefined;
    for (init_args, &result_types) |value, *slot| slot.* = value.valueType();

    var scope = try owner.whileScope(init_args[0..], result_types[0..]);
    errdefer scope.abort();

    const before = carryFromScope(@TypeOf(initial), &scope, .before);
    const proceed = try condition(owner, before, context);
    var before_args: [carry_count]builder.Value = undefined;
    var before_index: usize = 0;
    collectCarryValues(before, before_args[0..], &before_index);
    try scope.condition(typed.raw(proceed), before_args[0..]);

    const after = carryFromScope(@TypeOf(initial), &scope, .after);
    const next = try body(owner, after, context);
    var next_args: [carry_count]builder.Value = undefined;
    var next_index: usize = 0;
    collectCarryValues(next, next_args[0..], &next_index);
    try scope.leave(next_args[0..]);

    return carryFromScope(@TypeOf(initial), &scope, .result);
}

pub fn forRangeDo(owner: anytype, lower: i64, upper: i64, step: i64, context: anytype, comptime body: anytype) !builder.For {
    const lower_value = try owner.constantIndex(lower);
    const upper_value = try owner.constantIndex(upper);
    const step_value = try owner.constantIndex(step);
    return forDo(owner, lower_value, upper_value, step_value, context, body);
}

pub fn forRangeValueDo(owner: anytype, comptime dtype: DType, lower: i64, upper: i64, step: i64, context: anytype, comptime body: anytype) !builder.For {
    const lower_value = try owner.constantIndex(lower);
    const upper_value = try owner.constantIndex(upper);
    const step_value = try owner.constantIndex(step);
    return forValueDo(owner, dtype, lower_value, upper_value, step_value, context, body);
}

pub fn foldRange(owner: anytype, lower: i64, upper: i64, step: i64, initial: anytype, context: anytype, comptime body: anytype) !@TypeOf(initial) {
    const lower_value = try owner.constantIndex(lower);
    const upper_value = try owner.constantIndex(upper);
    const step_value = try owner.constantIndex(step);
    return fold(owner, lower_value, upper_value, step_value, initial, context, body);
}

fn loopIndexLike(owner: anytype, prototype: anytype, index: builder.Value) !@TypeOf(prototype) {
    const Prototype = @TypeOf(prototype);
    if (comptime Prototype == builder.Value) return index;
    if (comptime !@hasDecl(Prototype, "scalar_dtype")) @compileError("typed loop indices require a scalar typed initial value");
    return typed.wrapValueLike(prototype, try owner.cast(index, Prototype.scalar_dtype));
}

const CarrySource = enum { before, after, result };

fn carryCount(comptime T: type) usize {
    if (comptime isCarryLeaf(T)) return 1;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| count: {
            var total: usize = 0;
            inline for (info.field_types, info.field_attrs) |field_type, field_attrs| {
                if (!field_attrs.@"comptime") total += carryCount(field_type);
            }
            break :count total;
        },
        .array => |info| info.len * carryCount(info.child),
        else => @compileError("whileLoop carries must be values, typed scalar values, structs, or arrays"),
    };
}

fn collectCarryValues(value: anytype, out: []builder.Value, index: *usize) void {
    const T = @TypeOf(value);
    if (comptime isCarryLeaf(T)) {
        out[index.*] = typed.raw(value);
        index.* += 1;
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_attrs) |field_name, field_attrs| {
            if (!field_attrs.@"comptime") collectCarryValues(@field(value, field_name), out, index);
        },
        .array => |info| inline for (0..info.len) |i| {
            collectCarryValues(value[i], out, index);
        },
        else => unreachable,
    }
}

fn carryFromScope(comptime T: type, scope: anytype, comptime source: CarrySource) T {
    var index: usize = 0;
    return carryFromScopeAt(T, scope, source, &index);
}

fn carryFromScopeAt(comptime T: type, scope: anytype, comptime source: CarrySource, index: *usize) T {
    if (comptime isCarryLeaf(T)) {
        const value = switch (source) {
            .before => scope.beforeArg(index.*).?,
            .after => scope.afterArg(index.*).?,
            .result => scope.result(index.*).?,
        };
        index.* += 1;
        return carryLeaf(T, value);
    }
    return switch (@typeInfo(T)) {
        .@"struct" => |info| result: {
            var value: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, field_attrs| {
                if (!field_attrs.@"comptime") @field(value, field_name) = carryFromScopeAt(field_type, scope, source, index);
            }
            break :result value;
        },
        .array => |info| result: {
            var value: T = undefined;
            inline for (0..info.len) |i| {
                value[i] = carryFromScopeAt(info.child, scope, source, index);
            }
            break :result value;
        },
        else => unreachable,
    };
}

fn carryLeaf(comptime T: type, value: builder.Value) T {
    if (comptime T == builder.Value) return value;
    return T.init(value);
}

fn isCarryLeaf(comptime T: type) bool {
    if (comptime T == builder.Value) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "raw")) @TypeOf(@as(T, undefined).raw()) == builder.Value else false,
        else => false,
    };
}
