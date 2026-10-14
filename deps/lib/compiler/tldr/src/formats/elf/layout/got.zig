const symbol = @import("symbol.zig");

const SymbolRef = symbol.SymbolRef;

pub const GotEntry = struct {
    ref: SymbolRef,
    offset: u64,
};

pub const GotLayout = struct {
    entries: []GotEntry = &.{},

    pub fn deinit(self: *GotLayout, allocator: anytype) void {
        if (self.entries.len != 0) allocator.free(self.entries);
    }

    pub fn entryOffset(self: GotLayout, ref: SymbolRef) ?u64 {
        for (self.entries) |entry| {
            if (entry.ref.eql(ref)) return entry.offset;
        }
        return null;
    }
};
