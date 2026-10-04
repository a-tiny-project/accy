const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ExportSpec = struct {
    name: []const u8,
    symbol: []const u8,
    abi_version: u32,
};

pub const Export = struct {
    name: []const u8,
    symbol: []const u8,
    abi_version: u32,

    pub fn init(allocator: Allocator, spec: ExportSpec) Allocator.Error!Export {
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        return .{
            .name = name,
            .symbol = try allocator.dupe(u8, spec.symbol),
            .abi_version = spec.abi_version,
        };
    }

    pub fn deinit(self: *Export, allocator: Allocator) void {
        allocator.free(self.symbol);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ImportKind = enum(u32) {
    fragment = 1,
    runtime = 2,
};

pub const ImportSpec = struct {
    name: []const u8,
    symbol: []const u8,
    abi_version: u32,
    kind: ImportKind,
};

pub const Import = struct {
    name: []const u8,
    symbol: []const u8,
    abi_version: u32,
    kind: ImportKind,

    pub fn init(allocator: Allocator, spec: ImportSpec) Allocator.Error!Import {
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        return .{
            .name = name,
            .symbol = try allocator.dupe(u8, spec.symbol),
            .abi_version = spec.abi_version,
            .kind = spec.kind,
        };
    }

    pub fn deinit(self: *Import, allocator: Allocator) void {
        allocator.free(self.symbol);
        allocator.free(self.name);
        self.* = undefined;
    }
};
