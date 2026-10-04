const gpu_abi = @import("gpu_abi");

const builder = @import("builder.zig");
const vector = @import("vector.zig");

const DType = gpu_abi.DType;

pub fn Value(comptime dtype: DType) type {
    return struct {
        value: builder.Value,

        const Self = @This();

        pub const scalar_dtype = dtype;

        const ShiftKind = enum { shl, shr, ushr };

        pub fn init(value: builder.Value) Self {
            return .{ .value = value };
        }

        pub fn raw(self: Self) builder.Value {
            return self.value;
        }

        pub fn from(k: anytype, input: anytype) !Self {
            const Input = @TypeOf(input);
            if (comptime Input == Self) return input;
            if (comptime Input == builder.Value) return Self.init(input);
            switch (comptime @typeInfo(Input)) {
                .int, .comptime_int, .float, .comptime_float => return k.constantValue(
                    dtype,
                    input,
                ),
                .bool => {
                    if (comptime dtype != .i1) {
                        @compileError("bool literal operands require dtype .i1");
                    }
                    return k.constantValue(dtype, input);
                },
                else => @compileError("typed scalar operands must be typed values, raw Choir " ++
                    "values, or scalar literals"),
            }
        }

        pub fn add(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return Self.init(try k.add(self.value, rhs_value.value));
        }

        pub fn sub(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return Self.init(try k.sub(self.value, rhs_value.value));
        }

        pub fn mul(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return Self.init(try k.mul(self.value, rhs_value.value));
        }

        pub fn umulhi(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            switch (comptime dtype) {
                .i32, .i64 => return Self.init(try k.umulhi(self.value, rhs_value.value)),
                else => @compileError("umulhi requires dtype .i32 or .i64"),
            }
        }

        pub fn div(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return Self.init(try k.div(self.value, rhs_value.value));
        }

        pub fn min(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return Self.init(try k.min(self.value, rhs_value.value));
        }

        pub fn max(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return Self.init(try k.max(self.value, rhs_value.value));
        }

        pub fn clamp(self: Self, k: anytype, lower: anytype, upper: anytype) !Self {
            return (try self.max(k, lower)).min(k, upper);
        }

        pub fn and_(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            switch (comptime dtype) {
                .i1 => return self.select(k, .i1, rhs_value, false),
                .i32, .i64 => return Self.init(try k.and_(self.value, rhs_value.value)),
                else => @compileError("and_ requires dtype .i1, .i32, or .i64"),
            }
        }

        pub fn or_(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            switch (comptime dtype) {
                .i1 => return self.select(k, .i1, true, rhs_value),
                .i32, .i64 => return Self.init(try k.or_(self.value, rhs_value.value)),
                else => @compileError("or_ requires dtype .i1, .i32, or .i64"),
            }
        }

        pub fn xor(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            switch (comptime dtype) {
                .i1 => return self.select(k, .i1, try rhs_value.not(k), rhs_value),
                .i32, .i64 => return Self.init(try k.xor(self.value, rhs_value.value)),
                else => @compileError("xor requires dtype .i1, .i32, or .i64"),
            }
        }

        pub fn not(self: Self, k: anytype) !Self {
            switch (comptime dtype) {
                .i1 => return self.select(k, .i1, false, true),
                .i32, .i64 => return Self.init(try k.not(self.value)),
                else => @compileError("not requires dtype .i1, .i32, or .i64"),
            }
        }

        pub fn shl(self: Self, k: anytype, rhs: anytype) !Self {
            return self.shift(k, rhs, .shl);
        }

        pub fn shr(self: Self, k: anytype, rhs: anytype) !Self {
            return self.shift(k, rhs, .shr);
        }

        pub fn ushr(self: Self, k: anytype, rhs: anytype) !Self {
            return self.shift(k, rhs, .ushr);
        }

        pub fn bitcast(self: Self, k: anytype, comptime result_dtype: DType) !Value(result_dtype) {
            switch (comptime dtype) {
                .i32, .f32 => if (comptime result_dtype != .i32 and result_dtype !=
                    .f32) @compileError("bitcast requires equal 32-bit scalar widths"),
                .i64, .f64 => if (comptime result_dtype != .i64 and result_dtype !=
                    .f64) @compileError("bitcast requires equal 64-bit scalar widths"),
                else => @compileError("bitcast requires dtype .i32, .f32, .i64, or .f64"),
            }
            return Value(result_dtype).init(try k.bitcast(self.value, result_dtype));
        }

        pub fn neg(self: Self, k: anytype) !Self {
            return Self.init(try k.neg(self.value));
        }

        pub fn abs(self: Self, k: anytype) !Self {
            return Self.init(try k.abs(self.value));
        }

        pub fn sqrt(self: Self, k: anytype) !Self {
            return Self.init(try k.sqrt(self.value));
        }

        pub fn exp(self: Self, k: anytype) !Self {
            return Self.init(try k.exp(self.value));
        }

        pub fn log(self: Self, k: anytype) !Self {
            return Self.init(try k.log(self.value));
        }

        pub fn tanh(self: Self, k: anytype) !Self {
            return Self.init(try k.tanh(self.value));
        }

        pub fn sin(self: Self, k: anytype) !Self {
            return Self.init(try k.sin(self.value));
        }

        pub fn cos(self: Self, k: anytype) !Self {
            return Self.init(try k.cos(self.value));
        }

        pub fn tan(self: Self, k: anytype) !Self {
            return Self.init(try k.tan(self.value));
        }

        pub fn floor(self: Self, k: anytype) !Self {
            return Self.init(try k.floor(self.value));
        }

        pub fn round(self: Self, k: anytype) !Self {
            return Self.init(try k.round(self.value));
        }

        pub fn trunc(self: Self, k: anytype) !Self {
            return Self.init(try k.trunc(self.value));
        }

        pub fn pow(self: Self, k: anytype, exponent: anytype) !Self {
            const exponent_value = try Self.from(k, exponent);
            return Self.init(try k.pow(self.value, exponent_value.value));
        }

        pub fn atan2(self: Self, k: anytype, x: anytype) !Self {
            const x_value = try Self.from(k, x);
            return Self.init(try k.atan2(self.value, x_value.value));
        }

        pub fn fma(self: Self, k: anytype, b: anytype, c: anytype) !Self {
            const b_value = try Self.from(k, b);
            const c_value = try Self.from(k, c);
            return Self.init(try k.fma(self.value, b_value.value, c_value.value));
        }

        pub fn cast(self: Self, k: anytype, comptime result_dtype: DType) !Value(result_dtype) {
            return Value(result_dtype).init(try k.cast(self.value, result_dtype));
        }

        pub fn compare(
            self: Self,
            k: anytype,
            predicate: builder.Compare,
            rhs: anytype,
        ) !Value(.i1) {
            const rhs_value = try Self.from(k, rhs);
            return Value(.i1).init(try k.compare(predicate, self.value, rhs_value.value));
        }

        pub fn select(
            self: Self,
            k: anytype,
            comptime result_dtype: DType,
            true_value: anytype,
            false_value: anytype,
        ) !Value(result_dtype) {
            if (dtype != .i1) @compileError("select condition must use dtype .i1");
            const Result = Value(result_dtype);
            const true_result = try Result.from(k, true_value);
            const false_result = try Result.from(k, false_value);
            return Result.init(try k.select(self.value, true_result.raw(), false_result.raw()));
        }

        pub fn warpReduce(self: Self, k: anytype, op_kind: builder.WarpOpKind) !Self {
            return Self.init(try k.warpReduce(op_kind, self.value));
        }

        pub fn warpScan(
            self: Self,
            k: anytype,
            op_kind: builder.WarpOpKind,
            mode: builder.WarpScanMode,
        ) !Self {
            return Self.init(try k.warpScan(op_kind, mode, self.value));
        }

        pub fn shuffleSync(
            self: Self,
            k: anytype,
            mode: builder.ShuffleMode,
            lane_or_delta: anytype,
        ) !Self {
            return k.shuffleSync(mode, self, lane_or_delta);
        }

        pub fn allSync(self: Self, k: anytype) !Value(.i1) {
            if (comptime dtype != .i1) @compileError("allSync requires dtype .i1");
            return k.allSyncValue(self);
        }

        pub fn anySync(self: Self, k: anytype) !Value(.i1) {
            if (comptime dtype != .i1) @compileError("anySync requires dtype .i1");
            return k.anySyncValue(self);
        }

        pub fn ballotSync(self: Self, k: anytype) !Value(.i32) {
            if (comptime dtype != .i1) @compileError("ballotSync requires dtype .i1");
            return k.ballotSyncValue(self);
        }

        fn shift(self: Self, k: anytype, rhs: anytype, comptime kind: ShiftKind) !Self {
            const rhs_value = try Self.from(k, rhs);
            switch (comptime dtype) {
                .i32, .i64 => {},
                else => @compileError("shift operations require dtype .i32 or .i64"),
            }
            return Self.init(switch (kind) {
                .shl => try k.shl(self.value, rhs_value.value),
                .shr => try k.shr(self.value, rhs_value.value),
                .ushr => try k.ushr(self.value, rhs_value.value),
            });
        }
    };
}

pub const KeyValue = struct {
    lo: builder.Value,
    hi: builder.Value,
};

pub fn raw(value: anytype) builder.Value {
    if (@TypeOf(value) == builder.Value) return value;
    return value.raw();
}

pub fn wrapValueLike(prototype: anytype, value: builder.Value) @TypeOf(prototype) {
    const Prototype = @TypeOf(prototype);
    if (Prototype == builder.Value) return value;
    return Prototype.init(value);
}

pub fn Vec2(comptime dtype: DType) type {
    return struct {
        x: Scalar,
        y: Scalar,

        const Self = @This();
        const Scalar: type = Value(dtype);

        pub const scalar_dtype = dtype;

        pub fn init(x: Scalar, y: Scalar) Self {
            return .{ .x = x, .y = y };
        }

        pub fn raw(self: Self) vector.Vec2 {
            return vector.Vec2.init(self.x.raw(), self.y.raw());
        }

        pub fn splat(value: Scalar) Self {
            return .{ .x = value, .y = value };
        }

        fn from(k: anytype, input: anytype) !Self {
            const Input = @TypeOf(input);
            if (comptime Input == Self) return input;
            return Self.splat(try Scalar.from(k, input));
        }

        pub fn add(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.add(k, rhs_value.x),
                .y = try self.y.add(k, rhs_value.y),
            };
        }

        pub fn sub(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.sub(k, rhs_value.x),
                .y = try self.y.sub(k, rhs_value.y),
            };
        }

        pub fn mul(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.mul(k, rhs_value.x),
                .y = try self.y.mul(k, rhs_value.y),
            };
        }

        pub fn div(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.div(k, rhs_value.x),
                .y = try self.y.div(k, rhs_value.y),
            };
        }

        pub fn scale(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Scalar.from(k, rhs);
            return .{
                .x = try self.x.mul(k, rhs_value),
                .y = try self.y.mul(k, rhs_value),
            };
        }

        pub fn abs(self: Self, k: anytype) !Self {
            return .{
                .x = try self.x.abs(k),
                .y = try self.y.abs(k),
            };
        }

        pub fn min(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.min(k, rhs_value.x),
                .y = try self.y.min(k, rhs_value.y),
            };
        }

        pub fn max(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.max(k, rhs_value.x),
                .y = try self.y.max(k, rhs_value.y),
            };
        }

        pub fn clamp(self: Self, k: anytype, lower: anytype, upper: anytype) !Self {
            return (try self.max(k, lower)).min(k, upper);
        }

        pub fn dot(self: Self, k: anytype, rhs: anytype) !Scalar {
            const rhs_value = try Self.from(k, rhs);
            const x_product = try self.x.mul(k, rhs_value.x);
            const y_product = try self.y.mul(k, rhs_value.y);
            return x_product.add(k, y_product);
        }

        pub fn lengthSquared(self: Self, k: anytype) !Scalar {
            return self.dot(k, self);
        }

        pub fn length(self: Self, k: anytype) !Scalar {
            return (try self.lengthSquared(k)).sqrt(k);
        }

        pub fn normalize(self: Self, k: anytype) !Self {
            switch (comptime dtype) {
                .f16, .bf16, .f32, .f64 => {},
                else => @compileError("normalize requires a floating dtype"),
            }
            return self.scale(k, try (try Scalar.from(k, 1.0)).div(k, try self.length(k)));
        }

        pub fn distance(self: Self, k: anytype, rhs: anytype) !Scalar {
            return (try self.sub(k, rhs)).length(k);
        }
    };
}

pub fn Vec3(comptime dtype: DType) type {
    return struct {
        x: Scalar,
        y: Scalar,
        z: Scalar,

        const Self = @This();
        const Scalar: type = Value(dtype);

        pub const scalar_dtype = dtype;

        pub fn init(x: Scalar, y: Scalar, z: Scalar) Self {
            return .{ .x = x, .y = y, .z = z };
        }

        pub fn raw(self: Self) vector.Vec3 {
            return vector.Vec3.init(self.x.raw(), self.y.raw(), self.z.raw());
        }

        pub fn splat(value: Scalar) Self {
            return .{ .x = value, .y = value, .z = value };
        }

        fn from(k: anytype, input: anytype) !Self {
            const Input = @TypeOf(input);
            if (comptime Input == Self) return input;
            return Self.splat(try Scalar.from(k, input));
        }

        pub fn add(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.add(k, rhs_value.x),
                .y = try self.y.add(k, rhs_value.y),
                .z = try self.z.add(k, rhs_value.z),
            };
        }

        pub fn sub(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.sub(k, rhs_value.x),
                .y = try self.y.sub(k, rhs_value.y),
                .z = try self.z.sub(k, rhs_value.z),
            };
        }

        pub fn mul(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.mul(k, rhs_value.x),
                .y = try self.y.mul(k, rhs_value.y),
                .z = try self.z.mul(k, rhs_value.z),
            };
        }

        pub fn div(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.div(k, rhs_value.x),
                .y = try self.y.div(k, rhs_value.y),
                .z = try self.z.div(k, rhs_value.z),
            };
        }

        pub fn scale(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Scalar.from(k, rhs);
            return .{
                .x = try self.x.mul(k, rhs_value),
                .y = try self.y.mul(k, rhs_value),
                .z = try self.z.mul(k, rhs_value),
            };
        }

        pub fn abs(self: Self, k: anytype) !Self {
            return .{
                .x = try self.x.abs(k),
                .y = try self.y.abs(k),
                .z = try self.z.abs(k),
            };
        }

        pub fn min(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.min(k, rhs_value.x),
                .y = try self.y.min(k, rhs_value.y),
                .z = try self.z.min(k, rhs_value.z),
            };
        }

        pub fn max(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            return .{
                .x = try self.x.max(k, rhs_value.x),
                .y = try self.y.max(k, rhs_value.y),
                .z = try self.z.max(k, rhs_value.z),
            };
        }

        pub fn clamp(self: Self, k: anytype, lower: anytype, upper: anytype) !Self {
            return (try self.max(k, lower)).min(k, upper);
        }

        pub fn dot(self: Self, k: anytype, rhs: anytype) !Scalar {
            const rhs_value = try Self.from(k, rhs);
            const x_product = try self.x.mul(k, rhs_value.x);
            const y_product = try self.y.mul(k, rhs_value.y);
            const z_product = try self.z.mul(k, rhs_value.z);
            const xy = try x_product.add(k, y_product);
            return xy.add(k, z_product);
        }

        pub fn cross(self: Self, k: anytype, rhs: anytype) !Self {
            const rhs_value = try Self.from(k, rhs);
            const yz = try self.y.mul(k, rhs_value.z);
            const zy = try self.z.mul(k, rhs_value.y);
            const zx = try self.z.mul(k, rhs_value.x);
            const xz = try self.x.mul(k, rhs_value.z);
            const xy = try self.x.mul(k, rhs_value.y);
            const yx = try self.y.mul(k, rhs_value.x);
            return .{
                .x = try yz.sub(k, zy),
                .y = try zx.sub(k, xz),
                .z = try xy.sub(k, yx),
            };
        }

        pub fn lengthSquared(self: Self, k: anytype) !Scalar {
            return self.dot(k, self);
        }

        pub fn length(self: Self, k: anytype) !Scalar {
            return (try self.lengthSquared(k)).sqrt(k);
        }

        pub fn normalize(self: Self, k: anytype) !Self {
            switch (comptime dtype) {
                .f16, .bf16, .f32, .f64 => {},
                else => @compileError("normalize requires a floating dtype"),
            }
            return self.scale(k, try (try Scalar.from(k, 1.0)).div(k, try self.length(k)));
        }

        pub fn distance(self: Self, k: anytype, rhs: anytype) !Scalar {
            return (try self.sub(k, rhs)).length(k);
        }
    };
}
