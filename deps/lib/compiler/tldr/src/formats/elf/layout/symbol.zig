pub const SymbolRef = struct {
    object_index: usize,
    symbol_index: usize,

    pub fn eql(self: SymbolRef, other: SymbolRef) bool {
        return self.object_index == other.object_index and self.symbol_index == other.symbol_index;
    }
};

pub const GlobalSymbol = struct {
    ref: SymbolRef,
    ref_index: u32 = 0,
    weak: bool,
    common: bool,
};
