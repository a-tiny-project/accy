const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ProvenanceSpec = struct {
    path: []const u8,
    symbol: []const u8,
    line: u32 = 0,
    column: u32 = 0,
};

pub const Provenance = struct {
    path: []const u8,
    symbol: []const u8,
    line: u32,
    column: u32,

    pub fn init(allocator: Allocator, spec: ProvenanceSpec) Allocator.Error!Provenance {
        const path = try allocator.dupe(u8, spec.path);
        errdefer allocator.free(path);
        return .{
            .path = path,
            .symbol = try allocator.dupe(u8, spec.symbol),
            .line = spec.line,
            .column = spec.column,
        };
    }

    pub fn clone(self: Provenance, allocator: Allocator) Allocator.Error!Provenance {
        return try init(allocator, .{
            .path = self.path,
            .symbol = self.symbol,
            .line = self.line,
            .column = self.column,
        });
    }

    pub fn deinit(self: *Provenance, allocator: Allocator) void {
        allocator.free(self.symbol);
        allocator.free(self.path);
        self.* = undefined;
    }
};
