pub const Unhandled = struct {
    indexed: Action = .lower,
    regions: Action = .lower,

    pub const Action = enum {
        lower,
        bind,
    };
};

pub const lower = Unhandled{};
pub const indexed = Unhandled{ .indexed = .bind };
pub const transparent = Unhandled{ .indexed = .bind, .regions = .bind };

pub fn implUnhandled(comptime Impl: type, comptime fallback: Unhandled) Unhandled {
    if (comptime @hasDecl(Impl, "unhandled")) {
        const value: Unhandled = Impl.unhandled;
        return value;
    }
    return fallback;
}
