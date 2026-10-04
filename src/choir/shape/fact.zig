const expression = @import("expression.zig");

pub const Bounds = struct {
    min: ?u64 = null,
    opt: ?u64 = null,
    max: ?u64 = null,

    pub fn valid(self: Bounds) bool {
        if (self.min == null and self.opt == null and self.max == null) return false;
        if (self.min) |min| {
            if (self.opt) |opt| {
                if (min > opt) return false;
            }
            if (self.max) |max| {
                if (min > max) return false;
            }
        }
        if (self.opt) |opt| {
            if (self.max) |max| {
                if (opt > max) return false;
            }
        }
        return true;
    }
};

pub const Equality = struct {
    lhs: expression.Expression,
    rhs: expression.Expression,
};

pub const Bound = struct {
    value: expression.Expression,
    bounds: Bounds,
};

pub const Divisibility = struct {
    value: expression.Expression,
    divisor: u64,
};

pub const Predicate = union(enum) {
    equal: Equality,
    bound: Bound,
    divisible: Divisibility,
};

pub const Mode = enum {
    assume,
    assert,
};

pub const Fact = struct {
    mode: Mode,
    predicate: Predicate,
};
