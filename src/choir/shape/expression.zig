pub const SymbolId = u32;

pub const Term = struct {
    symbol: SymbolId,
    coefficient: i64 = 1,
};

pub const Expression = struct {
    constant: i64 = 0,
    terms: []const Term = &.{},

    pub fn eql(self: Expression, other: Expression) bool {
        if (self.constant != other.constant or self.terms.len != other.terms.len) return false;
        for (self.terms, other.terms) |lhs, rhs| {
            if (lhs.symbol != rhs.symbol or lhs.coefficient != rhs.coefficient) return false;
        }
        return true;
    }

    pub fn isConstant(self: Expression) bool {
        return self.terms.len == 0;
    }

    pub fn staticValue(self: Expression) ?u64 {
        if (!self.isConstant() or self.constant < 0) return null;
        return @intCast(self.constant);
    }
};

pub fn constant(value: i64) Expression {
    return .{ .constant = value };
}
