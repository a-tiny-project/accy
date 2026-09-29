const std = @import("std");
const alloc_arena = @import("alloc_arena");
const expression = @import("expression.zig");
const fact_mod = @import("fact.zig");
const tensor_mod = @import("tensor.zig");

pub const Error = error{
    DuplicateSymbol,
    DuplicateTensor,
    EmptyName,
    InvalidBounds,
    InvalidDivisor,
    InvalidExtent,
    UnknownSymbol,
};

pub const Symbol = struct {
    name: []const u8,
};

pub const Family = struct {
    backing_allocator: std.mem.Allocator,
    arena_state: *alloc_arena.Arena,
    name: []const u8,
    symbols: []const Symbol,
    tensors: []const tensor_mod.Tensor,
    facts: []const fact_mod.Fact,

    pub fn deinit(self: *Family) void {
        self.arena_state.deinit();
        self.backing_allocator.destroy(self.arena_state);
        self.* = undefined;
    }

    pub fn symbolIndex(self: Family, name: []const u8) ?expression.SymbolId {
        for (self.symbols, 0..) |item, index| {
            if (std.mem.eql(u8, item.name, name)) return @intCast(index);
        }
        return null;
    }

    pub fn tensor(self: Family, name: []const u8) ?tensor_mod.Tensor {
        for (self.tensors) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }
        return null;
    }

    pub fn assumedFactCount(self: Family) usize {
        var count: usize = 0;
        for (self.facts) |item| {
            if (item.mode == .assume) count += 1;
        }
        return count;
    }

    pub fn assertedFactCount(self: Family) usize {
        var count: usize = 0;
        for (self.facts) |item| {
            if (item.mode == .assert) count += 1;
        }
        return count;
    }
};

pub const Builder = struct {
    backing_allocator: std.mem.Allocator,
    arena_state: *alloc_arena.Arena,
    name: []const u8,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    tensors: std.ArrayListUnmanaged(tensor_mod.Tensor) = .empty,
    facts: std.ArrayListUnmanaged(fact_mod.Fact) = .empty,

    pub fn init(backing_allocator: std.mem.Allocator, name: []const u8) !Builder {
        if (name.len == 0) return Error.EmptyName;
        const arena_state = try backing_allocator.create(alloc_arena.Arena);
        errdefer backing_allocator.destroy(arena_state);
        arena_state.* = alloc_arena.Arena.init(backing_allocator);
        errdefer arena_state.deinit();
        const alloc = arena_state.allocator();
        return .{
            .backing_allocator = backing_allocator,
            .arena_state = arena_state,
            .name = try alloc.dupe(u8, name),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.arena_state.deinit();
        self.backing_allocator.destroy(self.arena_state);
        self.* = undefined;
    }

    pub fn symbol(self: *Builder, name: []const u8) !expression.SymbolId {
        if (name.len == 0) return Error.EmptyName;
        if (self.findSymbol(name) != null) return Error.DuplicateSymbol;
        const alloc = self.arena();
        const id: expression.SymbolId = @intCast(self.symbols.items.len);
        try self.symbols.append(alloc, .{ .name = try alloc.dupe(u8, name) });
        return id;
    }

    pub fn symbolExpression(self: *Builder, id: expression.SymbolId) !expression.Expression {
        try self.requireSymbol(id);
        const terms = try self.arena().alloc(expression.Term, 1);
        terms[0] = .{ .symbol = id };
        return .{ .terms = terms };
    }

    pub fn scaledSymbolExpression(self: *Builder, id: expression.SymbolId, coefficient: i64, constant: i64) !expression.Expression {
        try self.requireSymbol(id);
        const terms = try self.arena().alloc(expression.Term, 1);
        terms[0] = .{ .symbol = id, .coefficient = coefficient };
        return .{ .constant = constant, .terms = terms };
    }

    pub fn constantExpression(_: *Builder, value: i64) expression.Expression {
        return expression.constant(value);
    }

    pub fn addExpression(self: *Builder, lhs: expression.Expression, rhs: expression.Expression) !expression.Expression {
        try self.requireExpression(lhs);
        try self.requireExpression(rhs);
        const terms = try self.arena().alloc(expression.Term, lhs.terms.len + rhs.terms.len);
        @memcpy(terms[0..lhs.terms.len], lhs.terms);
        @memcpy(terms[lhs.terms.len..], rhs.terms);
        return .{ .constant = lhs.constant + rhs.constant, .terms = terms };
    }

    pub fn tensor(self: *Builder, name: []const u8, extents: []const expression.Expression) !usize {
        if (name.len == 0) return Error.EmptyName;
        if (self.findTensor(name) != null) return Error.DuplicateTensor;
        const alloc = self.arena();
        const id = self.tensors.items.len;
        const owned_extents = try alloc.alloc(expression.Expression, extents.len);
        for (extents, owned_extents) |extent, *owned_extent| owned_extent.* = try self.ownTensorExtent(extent);
        try self.tensors.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .extents = owned_extents,
        });
        return id;
    }

    pub fn assumeEqual(self: *Builder, lhs: expression.Expression, rhs: expression.Expression) !void {
        try self.appendFact(.assume, .{ .equal = .{ .lhs = lhs, .rhs = rhs } });
    }

    pub fn assertEqual(self: *Builder, lhs: expression.Expression, rhs: expression.Expression) !void {
        try self.appendFact(.assert, .{ .equal = .{ .lhs = lhs, .rhs = rhs } });
    }

    pub fn assumeBounds(self: *Builder, value: expression.Expression, bounds: fact_mod.Bounds) !void {
        try self.appendBounds(.assume, value, bounds);
    }

    pub fn assertBounds(self: *Builder, value: expression.Expression, bounds: fact_mod.Bounds) !void {
        try self.appendBounds(.assert, value, bounds);
    }

    pub fn assumeDivisible(self: *Builder, value: expression.Expression, divisor: u64) !void {
        try self.appendDivisible(.assume, value, divisor);
    }

    pub fn assertDivisible(self: *Builder, value: expression.Expression, divisor: u64) !void {
        try self.appendDivisible(.assert, value, divisor);
    }

    pub fn finish(self: *Builder) Family {
        const result = Family{
            .backing_allocator = self.backing_allocator,
            .arena_state = self.arena_state,
            .name = self.name,
            .symbols = self.symbols.items,
            .tensors = self.tensors.items,
            .facts = self.facts.items,
        };
        self.* = undefined;
        return result;
    }

    fn appendBounds(self: *Builder, mode: fact_mod.Mode, value: expression.Expression, bounds: fact_mod.Bounds) !void {
        if (!bounds.valid()) return Error.InvalidBounds;
        try self.appendFact(mode, .{ .bound = .{ .value = value, .bounds = bounds } });
    }

    fn appendDivisible(self: *Builder, mode: fact_mod.Mode, value: expression.Expression, divisor: u64) !void {
        if (divisor == 0) return Error.InvalidDivisor;
        try self.appendFact(mode, .{ .divisible = .{ .value = value, .divisor = divisor } });
    }

    fn appendFact(self: *Builder, mode: fact_mod.Mode, predicate: fact_mod.Predicate) !void {
        const owned_predicate = try self.ownPredicate(predicate);
        try self.facts.append(self.arena(), .{ .mode = mode, .predicate = owned_predicate });
    }

    fn arena(self: *Builder) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn findSymbol(self: *const Builder, name: []const u8) ?expression.SymbolId {
        for (self.symbols.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.name, name)) return @intCast(index);
        }
        return null;
    }

    fn findTensor(self: *const Builder, name: []const u8) ?usize {
        for (self.tensors.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.name, name)) return index;
        }
        return null;
    }

    fn requireSymbol(self: *const Builder, id: expression.SymbolId) !void {
        if (id >= self.symbols.items.len) return Error.UnknownSymbol;
    }

    fn requireExpression(self: *const Builder, value: expression.Expression) !void {
        for (value.terms) |term| try self.requireSymbol(term.symbol);
    }

    fn ownTensorExtent(self: *Builder, value: expression.Expression) !expression.Expression {
        const owned = try self.ownExpression(value);
        if (owned.terms.len == 0 and owned.constant < 0) return Error.InvalidExtent;
        return owned;
    }

    fn ownExpression(self: *Builder, value: expression.Expression) !expression.Expression {
        try self.requireExpression(value);
        if (value.terms.len == 0) return .{ .constant = value.constant };
        return .{
            .constant = value.constant,
            .terms = try self.arena().dupe(expression.Term, value.terms),
        };
    }

    fn ownPredicate(self: *Builder, predicate: fact_mod.Predicate) !fact_mod.Predicate {
        switch (predicate) {
            .equal => |value| return .{ .equal = .{
                .lhs = try self.ownExpression(value.lhs),
                .rhs = try self.ownExpression(value.rhs),
            } },
            .bound => |value| return .{ .bound = .{
                .value = try self.ownExpression(value.value),
                .bounds = value.bounds,
            } },
            .divisible => |value| return .{ .divisible = .{
                .value = try self.ownExpression(value.value),
                .divisor = value.divisor,
            } },
        }
    }
};
