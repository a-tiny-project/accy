const std = @import("std");
const linkage = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const SymbolKind = enum(u8) {
    unknown = 1,
    function = 2,
    data = 3,
    runtime = 4,
};

pub const SymbolBinding = enum(u8) {
    external = 1,
    local = 2,
    weak = 3,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind = .unknown,
    binding: SymbolBinding = .external,
    /// Parameter and result types of a function symbol whose producer records them.
    signature: ?linkage.Signature = null,

    pub fn dupe(self: Symbol, allocator: Allocator) Allocator.Error!Symbol {
        return .{
            .name = try linkage.slice.dupe(allocator, self.name),
            .kind = self.kind,
            .binding = self.binding,
            .signature = self.signature,
        };
    }

    pub fn deinit(self: Symbol, allocator: Allocator) void {
        linkage.slice.free(allocator, self.name);
    }

    pub fn eql(self: Symbol, other: Symbol) bool {
        return self.kind == other.kind and
            self.binding == other.binding and
            signaturesEql(self.signature, other.signature) and
            std.mem.eql(u8, self.name, other.name);
    }
};

fn signaturesEql(left: ?linkage.Signature, right: ?linkage.Signature) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(&right.?);
}
