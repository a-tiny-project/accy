const dispatch = @import("layer.zig");
const policy = @import("policy.zig");
const program = @import("../program/root.zig");

pub const Graph = struct {};

pub fn graph() With(Graph) {
    return with(Graph{});
}

pub fn with(impl: anytype) With(@TypeOf(impl)) {
    return .{ .impl = impl };
}

pub fn InterpretSpec(comptime Initial: type) type {
    if (comptime @hasDecl(Initial, "attach")) return Initial;
    return With(Initial);
}

pub fn asSpec(initial: anytype) InterpretSpec(@TypeOf(initial)) {
    if (comptime @hasDecl(@TypeOf(initial), "attach")) return initial;
    return with(initial);
}

pub fn deinitIfPresent(value: anytype) void {
    const Value = @typeInfo(@TypeOf(value)).pointer.child;
    switch (@typeInfo(Value)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => if (comptime @hasDecl(Value, "deinit")) value.deinit(),
        else => {},
    }
}

pub fn With(comptime Impl: type) type {
    return WithPolicy(Impl, policy.implUnhandled(Impl, policy.lower));
}

pub fn bind(impl: anytype) WithPolicy(@TypeOf(impl), policy.transparent) {
    return .{ .impl = impl };
}

pub fn bindIndexed(impl: anytype) WithPolicy(@TypeOf(impl), policy.indexed) {
    return .{ .impl = impl };
}

pub fn WithPolicy(comptime Impl: type, comptime unhandled: policy.Unhandled) type {
    return struct {
        impl: Impl,

        pub fn attach(self: @This(), next: anytype) Layer(@TypeOf(next), Impl, unhandled) {
            return .{
                .next = next,
                .impl = self.impl,
            };
        }
    };
}

pub fn stack(specs: anytype) Stack(@TypeOf(specs)) {
    return .{ .specs = specs };
}

pub fn Stack(comptime Specs: type) type {
    _ = stackLength(Specs);
    return struct {
        specs: Specs,

        pub fn attach(self: @This(), next: anytype) StackAttach(0, Specs, @TypeOf(next)) {
            return attachFrom(0, self.specs, next);
        }
    };
}

pub fn layer(next: anytype, impl: anytype) Layer(@TypeOf(next), @TypeOf(impl), policy.implUnhandled(@TypeOf(impl), policy.lower)) {
    return .{
        .next = next,
        .impl = impl,
    };
}

pub fn State(comptime Spec: type) type {
    return @TypeOf(@as(Spec, undefined).attach(@as(*program.Builder, undefined)));
}

pub fn Result(comptime Spec: type) type {
    return State(Spec).Result;
}

pub fn Layer(comptime Next: type, comptime Impl: type, comptime unhandled: policy.Unhandled) type {
    return dispatch.Layer(Next, Impl, unhandled);
}

fn stackLength(comptime Specs: type) comptime_int {
    const info = @typeInfo(Specs);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("kernel.interpret.stack expects a tuple of interpreter specs");
    }
    if (info.@"struct".field_names.len == 0) {
        @compileError("kernel.interpret.stack expects at least one interpreter spec");
    }
    return info.@"struct".field_names.len;
}

fn StackAttach(comptime index: usize, comptime Specs: type, comptime Next: type) type {
    const len = stackLength(Specs);
    if (index == len) return Next;
    const Spec = @typeInfo(Specs).@"struct".field_types[index];
    return @TypeOf(@as(Spec, undefined).attach(@as(StackAttach(index + 1, Specs, Next), undefined)));
}

fn attachFrom(comptime index: usize, specs: anytype, next: anytype) StackAttach(index, @TypeOf(specs), @TypeOf(next)) {
    if (comptime index == stackLength(@TypeOf(specs))) return next;
    const inner = attachFrom(index + 1, specs, next);
    return @field(specs, @typeInfo(@TypeOf(specs)).@"struct".field_names[index]).attach(inner);
}
