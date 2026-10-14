const std = @import("std");
const linkage = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const Linkage = struct {
    allocator: Allocator,
    required_symbols: std.ArrayListUnmanaged(linkage.Symbol) = .empty,
    provided_symbols: std.ArrayListUnmanaged(linkage.Symbol) = .empty,
    relocations: std.ArrayListUnmanaged(linkage.Relocation) = .empty,

    pub fn init(allocator: Allocator) Linkage {
        return .{ .allocator = allocator };
    }

    pub fn addRequired(self: *Linkage, symbol: linkage.Symbol) Allocator.Error!void {
        try self.required_symbols.ensureTotalCapacity(self.allocator, self.required_symbols.items.len + 1);
        const owned = try symbol.dupe(self.allocator);
        self.required_symbols.appendAssumeCapacity(owned);
    }

    pub fn addProvided(self: *Linkage, symbol: linkage.Symbol) Allocator.Error!void {
        try self.provided_symbols.ensureTotalCapacity(self.allocator, self.provided_symbols.items.len + 1);
        const owned = try symbol.dupe(self.allocator);
        self.provided_symbols.appendAssumeCapacity(owned);
    }

    pub fn addRelocation(self: *Linkage, relocation: linkage.Relocation) Allocator.Error!void {
        try self.relocations.ensureTotalCapacity(self.allocator, self.relocations.items.len + 1);
        const owned = try relocation.dupe(self.allocator);
        self.relocations.appendAssumeCapacity(owned);
    }

    pub fn hasRequired(self: Linkage, name: []const u8) bool {
        return has(self.required_symbols.items, name);
    }

    pub fn hasProvided(self: Linkage, name: []const u8) bool {
        return has(self.provided_symbols.items, name);
    }

    pub fn cloneInto(self: Linkage, target: *Linkage) Allocator.Error!void {
        for (self.required_symbols.items) |symbol| try target.addRequired(symbol);
        for (self.provided_symbols.items) |symbol| try target.addProvided(symbol);
        for (self.relocations.items) |relocation| try target.addRelocation(relocation);
    }

    pub fn deinit(self: *Linkage) void {
        for (self.required_symbols.items) |symbol| symbol.deinit(self.allocator);
        self.required_symbols.deinit(self.allocator);
        for (self.provided_symbols.items) |symbol| symbol.deinit(self.allocator);
        self.provided_symbols.deinit(self.allocator);
        for (self.relocations.items) |relocation| relocation.deinit(self.allocator);
        self.relocations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn eql(self: Linkage, other: Linkage) bool {
        if (self.required_symbols.items.len != other.required_symbols.items.len or
            self.provided_symbols.items.len != other.provided_symbols.items.len or
            self.relocations.items.len != other.relocations.items.len)
        {
            return false;
        }
        for (self.required_symbols.items, other.required_symbols.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        for (self.provided_symbols.items, other.provided_symbols.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        for (self.relocations.items, other.relocations.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

fn has(symbols: []const linkage.Symbol, name: []const u8) bool {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return true;
    }
    return false;
}
