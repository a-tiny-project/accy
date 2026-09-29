const std = @import("std");
const gpu_abi = @import("gpu_abi");
const accy = @import("../../root.zig");
const tensor = @import("../root.zig");

const DType = tensor.DType;
const Dim = tensor.Dim;
const Type = tensor.Type;
const Value = tensor.Value;
const Builder = tensor.Builder;

pub const Algorithm = enum {
    philox,
};

pub const KeySpec = struct {
    algorithm: Algorithm = .philox,
    rounds: u32 = accy.kernel.library.random.philox_default_rounds,
    threads: u32 = 256,
};

pub const Key = struct {
    value: Value,
    spec: KeySpec,

    pub fn split(self: Key, dims_struct: anytype) !Key {
        var buffer: [tensor.types.dimCount(@TypeOf(dims_struct))]Dim = undefined;
        tensor.types.fillDims(dims_struct, &buffer);
        if (buffer.len != 1) return error.RankMismatch;
        return splitKey(self, buffer[0]);
    }

    pub fn splitDim(self: Key, dim: Dim) !Key {
        return splitKey(self, dim);
    }

    pub fn uniform(self: Key, dtype: DType) !Value {
        return uniformKey(self, dtype);
    }

    pub fn counterUniform(self: Key, counter: Value, dims_struct: anytype, dtype: DType) !Value {
        var buffer: [tensor.types.dimCount(@TypeOf(dims_struct))]Dim = undefined;
        tensor.types.fillDims(dims_struct, &buffer);
        if (buffer.len != 1) return error.RankMismatch;
        return uniformKeyCounter(self, counter, buffer[0], dtype);
    }

    pub fn counterUniformDim(self: Key, counter: Value, dim: Dim, dtype: DType) !Value {
        return uniformKeyCounter(self, counter, dim, dtype);
    }
};

pub fn input(builder: *Builder, dims: []const Dim, spec_value: KeySpec) !Key {
    return .{
        .value = try builder.inputDims(.key, dims),
        .spec = spec_value,
    };
}

pub fn seed(builder: *Builder, seed_value: u64, spec_value: KeySpec) !Key {
    var payload = [_]gpu_abi.Key{gpu_abi.Key.init(seed_value)};
    return .{
        .value = try builder.constantBytes(Type.scalar(.key), std.mem.sliceAsBytes(payload[0..])),
        .spec = spec_value,
    };
}

pub fn bind(value: Value, spec_value: KeySpec) !Key {
    if (value.ty.dtype != .key) return error.DTypeMismatch;
    return .{ .value = value, .spec = spec_value };
}

fn splitKey(source: Key, dim: Dim) !Key {
    if (dim.extent <= 0) return error.InvalidDimension;
    try tensor.types.validateAuthoredDims(&.{dim});
    if (source.value.ty.rank() != 0) return error.RankMismatch;
    const builder = source.value.builder;
    const count: u64 = @intCast(dim.extent);
    const ty = try Type.init(builder.arena.allocator(), .key, &.{dim});
    const target = switch (source.spec.algorithm) {
        .philox => try accy.kernel.library.random.philoxKeySplitFamilyTarget(
            builder.arena.allocator(),
            .{
                .count = count,
                .rounds = source.spec.rounds,
                .threads = source.spec.threads,
            },
        ),
    };
    return .{
        .value = try builder.customCall(target, philoxSplitVersion(source.spec), &.{source.value}, ty),
        .spec = source.spec,
    };
}

pub fn uniform(keys: Key, dtype: DType) !Value {
    return uniformKey(keys, dtype);
}

fn uniformKey(keys: Key, dtype: DType) !Value {
    if (!accy.kernel.library.random.randomDTypeSupported(dtype)) return error.UnsupportedDType;
    if (keys.value.ty.rank() == 0) return error.RankMismatch;
    const count = try keys.value.ty.elementCount();
    const builder = keys.value.builder;
    const ty = try Type.init(builder.arena.allocator(), dtype, keys.value.ty.dims);
    const target = switch (keys.spec.algorithm) {
        .philox => try accy.kernel.library.random.philoxKeyUniformFamilyTarget(
            builder.arena.allocator(),
            .{
                .count = count,
                .rounds = keys.spec.rounds,
                .dtype = dtype,
                .threads = keys.spec.threads,
            },
        ),
    };
    return builder.customCall(target, philoxUniformVersion(keys.spec), &.{keys.value}, ty);
}

fn uniformKeyCounter(key: Key, counter: Value, dim: Dim, dtype: DType) !Value {
    if (!accy.kernel.library.random.randomDTypeSupported(dtype)) return error.UnsupportedDType;
    if (dim.extent <= 0) return error.InvalidDimension;
    try tensor.types.validateAuthoredDims(&.{dim});
    if (key.value.ty.rank() != 0 or counter.ty.rank() != 0) return error.RankMismatch;
    if (counter.ty.dtype != .i32) return error.DTypeMismatch;
    const builder = key.value.builder;
    const count: u64 = @intCast(dim.extent);
    const ty = try Type.init(builder.arena.allocator(), dtype, &.{dim});
    const target = switch (key.spec.algorithm) {
        .philox => try accy.kernel.library.random.philoxKeyCounterUniformFamilyTarget(
            builder.arena.allocator(),
            .{
                .count = count,
                .rounds = key.spec.rounds,
                .dtype = dtype,
                .threads = key.spec.threads,
            },
        ),
    };
    return builder.customCall(target, philoxCounterUniformVersion(key.spec), &.{ key.value, counter }, ty);
}

fn philoxSplitVersion(spec_value: KeySpec) u32 {
    return switch (spec_value.algorithm) {
        .philox => accy.kernel.library.random.philox_key_split_family_version,
    };
}

fn philoxUniformVersion(spec_value: KeySpec) u32 {
    return switch (spec_value.algorithm) {
        .philox => accy.kernel.library.random.philox_key_uniform_family_version,
    };
}

fn philoxCounterUniformVersion(spec_value: KeySpec) u32 {
    return switch (spec_value.algorithm) {
        .philox => accy.kernel.library.random.philox_key_counter_uniform_family_version,
    };
}
