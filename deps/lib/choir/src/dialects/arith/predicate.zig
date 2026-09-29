pub const CmpPredicate = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    slt,
    sle,
    sgt,
    sge,
    ult,
    ule,
    ugt,
    uge,

    pub fn toString(self: CmpPredicate) []const u8 {
        return @tagName(self);
    }
};
