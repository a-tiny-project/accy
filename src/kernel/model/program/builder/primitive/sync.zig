const common = @import("common.zig");

const builder = common.builder;

pub fn barrier(owner: anytype, scope: builder.Scope) !void {
    try owner.body.barrier(scope);
}

pub fn activeMask(owner: anytype) !builder.Value {
    return owner.body.activeMask();
}

pub fn syncWarp(owner: anytype) !void {
    try owner.body.syncWarp();
}

pub fn allSync(owner: anytype, predicate: builder.Value) !builder.Value {
    return owner.body.allSync(predicate);
}

pub fn anySync(owner: anytype, predicate: builder.Value) !builder.Value {
    return owner.body.anySync(predicate);
}

pub fn ballotSync(owner: anytype, predicate: builder.Value) !builder.Value {
    return owner.body.ballotSync(predicate);
}
