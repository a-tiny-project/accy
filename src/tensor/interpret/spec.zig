const dispatch = @import("layer.zig");

pub fn with(impl: anytype) With(@TypeOf(impl)) {
    return .{ .impl = impl };
}

pub fn bind(impl: anytype) With(@TypeOf(impl)) {
    return with(impl);
}

pub fn With(comptime Impl: type) type {
    return struct {
        impl: Impl,

        pub fn attach(self: @This(), next: anytype) Layer(stateValue(@TypeOf(next)), @TypeOf(next), Impl) {
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

pub fn layer(comptime BoundValue: type, next: anytype, impl: anytype) Layer(BoundValue, @TypeOf(next), @TypeOf(impl)) {
    return .{
        .next = next,
        .impl = impl,
    };
}

pub fn Layer(comptime BoundValue: type, comptime Next: type, comptime Impl: type) type {
    return dispatch.Layer(BoundValue, Next, Impl);
}

fn stateValue(comptime StateType: type) type {
    return switch (@typeInfo(StateType)) {
        .pointer => |info| info.child.Value,
        else => StateType.Value,
    };
}

fn stackLength(comptime Specs: type) comptime_int {
    const info = @typeInfo(Specs);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("tensor.interpret.stack expects a tuple of interpreter specs");
    }
    if (info.@"struct".field_names.len == 0) {
        @compileError("tensor.interpret.stack expects at least one interpreter spec");
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
