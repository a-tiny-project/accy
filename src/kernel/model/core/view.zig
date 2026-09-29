const gpu_abi = @import("gpu_abi");

const builder = @import("builder.zig");
const typed = @import("typed.zig");

const DType = gpu_abi.DType;

pub const TypedValue = typed.Value;
pub const KeyValue = typed.KeyValue;

pub fn BufferView(comptime dtype: DType) type {
    if (dtype == .key) return KeyBufferView;
    return ElementBufferView(dtype);
}

pub const KeyBufferView = struct {
    value: builder.Value,

    const Self = @This();

    pub const element_dtype: DType = .key;

    pub fn init(value: builder.Value) Self {
        return .{ .value = value };
    }

    pub fn raw(self: Self) builder.Value {
        return self.value;
    }

    pub fn load(self: Self, k: anytype, index: anytype) !KeyValue {
        const base = try wordBase(k, index);
        const lo = try k.loadIndex(self.value, base);
        const hi = try k.loadIndex(self.value, try k.add(base, try k.constantIndex(1)));
        return .{ .lo = lo, .hi = hi };
    }

    pub fn store(self: Self, k: anytype, value: KeyValue, index: anytype) !void {
        const base = try wordBase(k, index);
        try k.storeIndex(value.lo, self.value, base);
        try k.storeIndex(value.hi, self.value, try k.add(base, try k.constantIndex(1)));
    }

    fn wordBase(k: anytype, index: anytype) !builder.Value {
        return k.mul(try k.linearIndex(index), try k.constantIndex(2));
    }
};

fn ElementBufferView(comptime dtype: DType) type {
    return struct {
        value: builder.Value,

        const Self = @This();

        pub const element_dtype = dtype;

        pub fn init(value: builder.Value) Self {
            return .{ .value = value };
        }

        pub fn raw(self: Self) builder.Value {
            return self.value;
        }

        pub fn load(self: Self, k: anytype, index: anytype) !TypedValue(dtype) {
            return k.typedValue(dtype, try k.loadIndex(self.value, index));
        }

        pub fn loadVector(self: Self, k: anytype, index: anytype, width: u32) !builder.Value {
            return k.loadVectorIndex(self.value, index, width);
        }

        pub fn store(self: Self, k: anytype, value: anytype, index: anytype) !void {
            try k.storeIndex((try TypedValue(dtype).from(k, value)).raw(), self.value, index);
        }

        pub fn storeVector(self: Self, k: anytype, value: builder.Value, index: anytype) !void {
            try k.storeIndex(value, self.value, index);
        }

        pub fn atomicRmw(
            self: Self,
            k: anytype,
            kind: builder.AtomicRmwKind,
            value: anytype,
            index: anytype,
        ) !TypedValue(dtype) {
            const operand = (try TypedValue(dtype).from(k, value)).raw();
            return k.typedValue(dtype, try k.atomicRmwIndex(kind, operand, self.value, index));
        }

        pub fn atomicCas(
            self: Self,
            k: anytype,
            expected: anytype,
            desired: anytype,
            index: anytype,
        ) !TypedValue(dtype) {
            const expected_operand = (try TypedValue(dtype).from(k, expected)).raw();
            const desired_operand = (try TypedValue(dtype).from(k, desired)).raw();
            return k.typedValue(dtype, try k.atomicCasIndex(expected_operand, desired_operand, self.value, index));
        }
    };
}
