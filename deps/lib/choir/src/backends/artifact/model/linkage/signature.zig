const std = @import("std");

/// A scalar type that crosses a function boundary.
pub const ScalarType = enum(u8) {
    i8 = 1,
    i16 = 2,
    i32 = 3,
    i64 = 4,
    u8 = 5,
    u16 = 6,
    u32 = 7,
    u64 = 8,
    index = 9,
    bool = 10,
    f32 = 11,
    f64 = 12,
};

/// A fixed number of lanes of one scalar type.
pub const VectorType = struct {
    element: ScalarType,
    lanes: u8,

    /// Most lanes one vector type holds.
    pub const max_lanes = 16;
};

/// The kind of a `ValueType`.
pub const ValueKind = enum(u8) {
    scalar = 1,
    memref = 2,
    vector = 3,
};

/// The type of one parameter or result of a machine-code function.
pub const ValueType = union(ValueKind) {
    scalar: ScalarType,
    /// An address passed as one 64-bit word, from a memref of any address space.
    memref,
    vector: VectorType,

    /// Reports whether a vector type holds between 1 and `VectorType.max_lanes` lanes.
    /// Scalar and memref types are always valid.
    pub fn isValid(self: ValueType) bool {
        return switch (self) {
            .scalar, .memref => true,
            .vector => |vector| vector.lanes != 0 and vector.lanes <= VectorType.max_lanes,
        };
    }

    pub fn eql(self: ValueType, other: ValueType) bool {
        return std.meta.eql(self, other);
    }
};

pub const SignatureError = error{ TooManyParameters, TooManyResults, InvalidValueType };

/// The parameter and result types of one machine-code function.
pub const Signature = struct {
    parameter_count: u8 = 0,
    result_count: u8 = 0,
    /// Entries past `parameter_count` hold `.memref`.
    parameter_types: [max_parameters]ValueType = @splat(.memref),
    /// Entries past `result_count` hold `.memref`.
    result_types: [max_results]ValueType = @splat(.memref),

    /// Most parameters one signature records.
    pub const max_parameters = 64;
    /// Most results one signature records.
    pub const max_results = 16;

    comptime {
        std.debug.assert(max_parameters <= std.math.maxInt(u8));
        std.debug.assert(max_results <= std.math.maxInt(u8));
        std.debug.assert(VectorType.max_lanes <= std.math.maxInt(u8));
    }

    /// Records `parameter_types` and `result_types`. Fails with `error.TooManyParameters` or
    /// `error.TooManyResults` when a list exceeds its maximum, and with `error.InvalidValueType`
    /// when a vector type holds no lanes or more than `VectorType.max_lanes`.
    pub fn init(
        parameter_types: []const ValueType,
        result_types: []const ValueType,
    ) SignatureError!Signature {
        if (parameter_types.len > max_parameters) return error.TooManyParameters;
        if (result_types.len > max_results) return error.TooManyResults;
        for (parameter_types) |value_type| {
            if (!value_type.isValid()) return error.InvalidValueType;
        }
        for (result_types) |value_type| {
            if (!value_type.isValid()) return error.InvalidValueType;
        }
        var signature = Signature{
            .parameter_count = @intCast(parameter_types.len),
            .result_count = @intCast(result_types.len),
        };
        @memcpy(signature.parameter_types[0..parameter_types.len], parameter_types);
        @memcpy(signature.result_types[0..result_types.len], result_types);
        std.debug.assert(signature.parameters().len == parameter_types.len);
        std.debug.assert(signature.results().len == result_types.len);
        std.debug.assert(signature.isValid());
        return signature;
    }

    pub fn parameters(self: *const Signature) []const ValueType {
        std.debug.assert(self.parameter_count <= max_parameters);
        return self.parameter_types[0..self.parameter_count];
    }

    pub fn results(self: *const Signature) []const ValueType {
        std.debug.assert(self.result_count <= max_results);
        return self.result_types[0..self.result_count];
    }

    /// Reports whether both counts are within their maximums and every recorded type is valid.
    /// Every signature from `init` is valid. Writes to the fields can break that.
    pub fn isValid(self: *const Signature) bool {
        if (self.parameter_count > max_parameters) return false;
        if (self.result_count > max_results) return false;
        for (self.parameter_types[0..self.parameter_count]) |value_type| {
            if (!value_type.isValid()) return false;
        }
        for (self.result_types[0..self.result_count]) |value_type| {
            if (!value_type.isValid()) return false;
        }
        return true;
    }

    /// Reports whether `self` and `other` record the same parameter and result types.
    /// Entries past either count do not take part.
    pub fn eql(self: *const Signature, other: *const Signature) bool {
        return typesEql(self.parameters(), other.parameters()) and
            typesEql(self.results(), other.results());
    }
};

fn typesEql(left: []const ValueType, right: []const ValueType) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_type, right_type| {
        if (!left_type.eql(right_type)) return false;
    }
    return true;
}

test "signatures compare only the types they record" {
    const int64 = ValueType{ .scalar = .i64 };
    const float64 = ValueType{ .scalar = .f64 };
    const pair = try Signature.init(&.{ int64, .memref }, &.{float64});
    var same = try Signature.init(&.{ int64, .memref }, &.{float64});
    try std.testing.expect(pair.eql(&same));
    same.parameter_types[Signature.max_parameters - 1] = int64;
    same.result_types[Signature.max_results - 1] = float64;
    try std.testing.expect(pair.eql(&same));

    const narrower = try Signature.init(&.{ .{ .scalar = .i32 }, .memref }, &.{float64});
    try std.testing.expect(!pair.eql(&narrower));
    const shorter = try Signature.init(&.{int64}, &.{float64});
    try std.testing.expect(!pair.eql(&shorter));
    const lanes4 = ValueType{ .vector = .{ .element = .f32, .lanes = 4 } };
    const lanes8 = ValueType{ .vector = .{ .element = .f32, .lanes = 8 } };
    const four = try Signature.init(&.{}, &.{lanes4});
    const eight = try Signature.init(&.{}, &.{lanes8});
    try std.testing.expect(!four.eql(&eight));
}

test "signatures refuse more types than they hold and empty vectors" {
    const many: [Signature.max_parameters + 1]ValueType = @splat(.memref);
    try std.testing.expectError(error.TooManyParameters, Signature.init(&many, &.{}));
    const results = many[0 .. Signature.max_results + 1];
    try std.testing.expectError(error.TooManyResults, Signature.init(&.{}, results));
    const empty = ValueType{ .vector = .{ .element = .u8, .lanes = 0 } };
    try std.testing.expectError(error.InvalidValueType, Signature.init(&.{empty}, &.{}));
    const wide = ValueType{ .vector = .{ .element = .u8, .lanes = VectorType.max_lanes + 1 } };
    try std.testing.expectError(error.InvalidValueType, Signature.init(&.{}, &.{wide}));

    const parameters = many[0..Signature.max_parameters];
    const full = try Signature.init(parameters, results[0..Signature.max_results]);
    try std.testing.expectEqual(@as(usize, Signature.max_parameters), full.parameters().len);
    try std.testing.expectEqual(@as(usize, Signature.max_results), full.results().len);
}

test "signatures changed after init report invalid counts and lanes" {
    const lanes4 = ValueType{ .vector = .{ .element = .f32, .lanes = 4 } };
    const valid = try Signature.init(&.{.memref}, &.{lanes4});
    try std.testing.expect(valid.isValid());

    var no_lanes = valid;
    no_lanes.result_types[0].vector.lanes = 0;
    try std.testing.expect(!no_lanes.isValid());
    var too_many = valid;
    too_many.parameter_count = Signature.max_parameters + 1;
    try std.testing.expect(!too_many.isValid());
    var unrecorded = valid;
    unrecorded.parameter_types[Signature.max_parameters - 1] = no_lanes.result_types[0];
    try std.testing.expect(unrecorded.isValid());
}
