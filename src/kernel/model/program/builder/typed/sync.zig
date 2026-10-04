const common = @import("common.zig");
const scalar = @import("scalar.zig");

const TypedValue = common.TypedValue;

pub fn activeMaskValue(owner: anytype) !TypedValue(.i32) {
    return scalar.typedValue(owner, .i32, try owner.activeMask());
}

pub fn allSyncValue(owner: anytype, predicate: anytype) !TypedValue(.i1) {
    const pred = try TypedValue(.i1).from(owner, predicate);
    return scalar.typedValue(owner, .i1, try owner.allSync(pred.raw()));
}

pub fn anySyncValue(owner: anytype, predicate: anytype) !TypedValue(.i1) {
    const pred = try TypedValue(.i1).from(owner, predicate);
    return scalar.typedValue(owner, .i1, try owner.anySync(pred.raw()));
}

pub fn ballotSyncValue(owner: anytype, predicate: anytype) !TypedValue(.i32) {
    const pred = try TypedValue(.i1).from(owner, predicate);
    return scalar.typedValue(owner, .i32, try owner.ballotSync(pred.raw()));
}
