const common = @import("common.zig");

const builder = common.builder;

pub fn globalId(owner: anytype, dim: builder.Dimension) !builder.Value {
    return owner.body.globalId(dim);
}

pub fn threadId(owner: anytype, dim: builder.Dimension) !builder.Value {
    return owner.body.threadId(dim);
}

pub fn blockId(owner: anytype, dim: builder.Dimension) !builder.Value {
    return owner.body.blockId(dim);
}

pub fn blockDim(owner: anytype, dim: builder.Dimension) !builder.Value {
    return owner.body.blockDim(dim);
}

pub fn gridDim(owner: anytype, dim: builder.Dimension) !builder.Value {
    return owner.body.gridDim(dim);
}

pub fn laneId(owner: anytype) !builder.Value {
    return owner.body.laneId();
}

pub fn warpId(owner: anytype) !builder.Value {
    return owner.body.warpId();
}
