const core = @import("../../../core/root.zig");
const guard_mod = @import("../../guard/root.zig");
const typed = core.typed;

fn OwnerType(comptime OwnerPointer: type) type {
    return switch (@typeInfo(OwnerPointer)) {
        .pointer => |info| info.child,
        else => @compileError("builder guard helpers require a pointer owner"),
    };
}

fn GuardFor(comptime OwnerPointer: type) type {
    return guard_mod.Guard(OwnerType(OwnerPointer));
}

pub fn guard(owner: anytype, condition: anytype) !GuardFor(@TypeOf(owner)) {
    var if_op = try owner.if_(typed.raw(condition), &.{});
    const previous = owner.insertionBlock();
    owner.setInsertionBlock(if_op.thenBlock());
    return .{
        .owner = owner,
        .previous = previous,
        .else_block = if_op.elseBlock().?,
    };
}

pub fn guardIndex(owner: anytype, index: anytype) !GuardFor(@TypeOf(owner)) {
    const in_bounds = try owner.compare(.lt, index.index, index.bound);
    return guard(owner, in_bounds);
}

pub fn guardDo(owner: anytype, condition: anytype, context: anytype, comptime body: anytype) !void {
    var active_guard = try guard(owner, condition);
    errdefer active_guard.abort();
    try body(owner, context);
    try active_guard.leave();
}
