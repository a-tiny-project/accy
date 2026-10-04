const gpu_abi = @import("gpu_abi");

const builder = @import("../../root.zig").builder;

const DType = gpu_abi.DType;

pub fn ConstantIntContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dtype: DType,
        value: i64,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.constantInt(self.dtype, self.value);
        }
    };
}

pub fn ConstantIndexContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        value: i64,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.constantIndex(self.value);
        }
    };
}

pub fn ConstantFloatContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        dtype: DType,
        value: f64,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.constantFloat(self.dtype, self.value);
        }
    };
}

pub fn ConstantBoolContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        value: bool,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.constantBool(self.value);
        }
    };
}

pub fn AddContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.add(self.lhs, self.rhs);
        }
    };
}

pub fn SubContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.sub(self.lhs, self.rhs);
        }
    };
}

pub fn MulContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.mul(self.lhs, self.rhs);
        }
    };
}

pub fn UmulhiContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.umulhi(self.lhs, self.rhs);
        }
    };
}

pub fn DivContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.div(self.lhs, self.rhs);
        }
    };
}

pub fn AndContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.and_(self.lhs, self.rhs);
        }
    };
}

pub fn OrContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.or_(self.lhs, self.rhs);
        }
    };
}

pub fn XorContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.xor(self.lhs, self.rhs);
        }
    };
}

pub fn NotContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.not(self.input);
        }
    };
}

pub fn PopCountContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.popcount(self.input);
        }
    };
}

pub fn ShlContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        value: builder.Value,
        shift: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.shl(self.value, self.shift);
        }
    };
}

pub fn ShrContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        value: builder.Value,
        shift: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.shr(self.value, self.shift);
        }
    };
}

pub fn UshrContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        value: builder.Value,
        shift: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.ushr(self.value, self.shift);
        }
    };
}

pub fn BitcastContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,
        dtype: DType,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.bitcast(self.input, self.dtype);
        }
    };
}

pub fn MinContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.min(self.lhs, self.rhs);
        }
    };
}

pub fn MaxContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.max(self.lhs, self.rhs);
        }
    };
}

pub fn NegContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.neg(self.input);
        }
    };
}

pub fn AbsContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.abs(self.input);
        }
    };
}

pub fn SinContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.sin(self.input);
        }
    };
}

pub fn CosContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.cos(self.input);
        }
    };
}

pub fn ExpContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.exp(self.input);
        }
    };
}

pub fn SqrtContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.sqrt(self.input);
        }
    };
}

pub fn LogContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.log(self.input);
        }
    };
}

pub fn TanhContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.tanh(self.input);
        }
    };
}

pub fn TanContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.tan(self.input);
        }
    };
}

pub fn FloorContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.floor(self.input);
        }
    };
}

pub fn RoundContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.round(self.input);
        }
    };
}

pub fn TruncContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.trunc(self.input);
        }
    };
}

pub fn PowContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        base: builder.Value,
        exponent: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.pow(self.base, self.exponent);
        }
    };
}

pub fn Atan2Context(comptime Handle: type) type {
    return struct {
        next: Handle,
        y: builder.Value,
        x: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.atan2(self.y, self.x);
        }
    };
}

pub fn FmaContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        a: builder.Value,
        b: builder.Value,
        c: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.fma(self.a, self.b, self.c);
        }
    };
}

pub fn CompareContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        predicate: builder.Compare,
        lhs: builder.Value,
        rhs: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.compare(self.predicate, self.lhs, self.rhs);
        }
    };
}

pub fn CastContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,
        dtype: DType,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.cast(self.input, self.dtype);
        }
    };
}

pub fn CastIndexContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        input: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.castIndex(self.input);
        }
    };
}

pub fn SelectContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        condition: builder.Value,
        true_value: builder.Value,
        false_value: builder.Value,

        pub fn default(self: *@This()) !builder.Value {
            return self.next.select(self.condition, self.true_value, self.false_value);
        }
    };
}

pub fn literalFloat(value: anytype) f64 {
    const Value = @TypeOf(value);
    return switch (comptime @typeInfo(Value)) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("float constants require numeric literals or numeric values"),
    };
}
