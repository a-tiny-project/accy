const common = @import("common.zig");

const builder = common.builder;
const TypedValue = common.TypedValue;
const typed = common.typed;

pub fn warpReduce(owner: anytype, op_kind: builder.WarpOpKind, value: anytype) !@TypeOf(value) {
    return typed.wrapValueLike(value, try owner.body.warpReduce(op_kind, typed.raw(value)));
}

pub fn warpScan(
    owner: anytype,
    op_kind: builder.WarpOpKind,
    mode: builder.WarpScanMode,
    value: anytype,
) !@TypeOf(value) {
    return typed.wrapValueLike(value, try owner.body.warpScan(op_kind, mode, typed.raw(value)));
}

pub fn shuffleSync(
    owner: anytype,
    mode: builder.ShuffleMode,
    value: anytype,
    lane_or_delta: anytype,
) !@TypeOf(value) {
    const lane = try TypedValue(.i32).from(owner, lane_or_delta);
    return typed.wrapValueLike(
        value,
        try owner.body.shuffleSync(mode, typed.raw(value), lane.raw()),
    );
}
