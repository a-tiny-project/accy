const std = @import("std");
const linkage = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const RelocationKind = enum(u8) {
    unknown = 1,
    call = 2,
    absolute = 3,
    relative = 4,
    got = 5,
    plt = 6,
};

pub const Relocation = struct {
    offset: u64,
    symbol: []const u8,
    kind: RelocationKind = .unknown,
    addend: i64 = 0,
    width_bits: ?u16 = null,

    pub fn dupe(self: Relocation, allocator: Allocator) Allocator.Error!Relocation {
        return .{
            .offset = self.offset,
            .symbol = try linkage.slice.dupe(allocator, self.symbol),
            .kind = self.kind,
            .addend = self.addend,
            .width_bits = self.width_bits,
        };
    }

    pub fn deinit(self: Relocation, allocator: Allocator) void {
        linkage.slice.free(allocator, self.symbol);
    }

    pub fn eql(self: Relocation, other: Relocation) bool {
        return self.offset == other.offset and
            self.kind == other.kind and
            self.addend == other.addend and
            self.width_bits == other.width_bits and
            std.mem.eql(u8, self.symbol, other.symbol);
    }
};
