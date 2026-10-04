const std = @import("std");
const common = @import("common.zig");
const literal = @import("literal.zig");

const builder = common.builder;
const DType = common.DType;

pub fn load(owner: anytype, memref: builder.Value, index: builder.Value) !builder.Value {
    return owner.body.load(memref, index);
}

pub fn loadVector(
    owner: anytype,
    memref: builder.Value,
    index: builder.Value,
    width: u32,
) !builder.Value {
    return owner.body.loadVector(memref, index, width);
}

pub fn linearIndex(owner: anytype, index: anytype) !builder.Value {
    const Index = @TypeOf(index);
    if (comptime Index == builder.Value) return index;
    switch (comptime @typeInfo(Index)) {
        .int, .comptime_int => return literal.constantIndex(
            owner,
            std.math.cast(i64, index) orelse return error.IntegerOutOfBounds,
        ),
        else => return index.linear(owner),
    }
}

pub fn loadIndex(owner: anytype, memref: builder.Value, index: anytype) !builder.Value {
    return load(owner, memref, try linearIndex(owner, index));
}

pub fn loadVectorIndex(
    owner: anytype,
    memref: builder.Value,
    index: anytype,
    width: u32,
) !builder.Value {
    return loadVector(owner, memref, try linearIndex(owner, index), width);
}

pub fn sharedBuffer(owner: anytype, dtype: DType, size: u64) !builder.Value {
    return owner.body.sharedBuffer(dtype, size);
}

pub fn dynamicSharedBuffer(
    owner: anytype,
    dtype: DType,
    size: u64,
    byte_offset: u64,
) !builder.Value {
    return owner.body.dynamicSharedBuffer(dtype, size, byte_offset);
}

pub fn store(
    owner: anytype,
    value: builder.Value,
    memref: builder.Value,
    index: builder.Value,
) !void {
    try owner.body.store(value, memref, index);
}

pub fn storeIndex(
    owner: anytype,
    value: builder.Value,
    memref: builder.Value,
    index: anytype,
) !void {
    try store(owner, value, memref, try linearIndex(owner, index));
}

pub fn atomicRmw(
    owner: anytype,
    kind: builder.AtomicRmwKind,
    value: builder.Value,
    memref: builder.Value,
    index: builder.Value,
) !builder.Value {
    return owner.body.atomicRmw(kind, value, memref, index);
}

pub fn atomicCas(
    owner: anytype,
    expected: builder.Value,
    desired: builder.Value,
    memref: builder.Value,
    index: builder.Value,
) !builder.Value {
    return owner.body.atomicCas(expected, desired, memref, index);
}
