const std = @import("std");
const alloc_arena = @import("alloc_arena");
const attribute = @import("attribute.zig");
const Attribute = attribute.Attribute;
const NamedAttribute = attribute.NamedAttribute;
const Operation = @import("operation/root.zig").Operation;
const Region = @import("region.zig").Region;
const interfaces = @import("interfaces/root.zig");

const AttributeReplacement = struct {
    attr: ?Attribute = null,
    replaced: usize = 0,
};

const SymbolTableSemanticError = error{
    DuplicateSymbol,
    InvalidSymbol,
    InvalidSymbolTable,
    InvalidSymbolDeclaration,
};

pub const SymbolTableError = SymbolTableSemanticError || std.mem.Allocator.Error;

pub const SymbolUse = struct {
    user: *Operation,
    attr_name: []const u8,
    symbol_ref: *const Attribute.SymbolRefAttr,
};

pub const SymbolUseRange = struct {
    uses: std.ArrayList(SymbolUse) = .empty,

    pub fn deinit(self: *SymbolUseRange, allocator: std.mem.Allocator) void {
        self.uses.deinit(allocator);
        self.* = .{};
    }

    pub fn items(self: *const SymbolUseRange) []const SymbolUse {
        return self.uses.items;
    }

    pub fn empty(self: *const SymbolUseRange) bool {
        return self.uses.items.len == 0;
    }

    fn append(self: *SymbolUseRange, allocator: std.mem.Allocator, use: SymbolUse) !void {
        try self.uses.append(allocator, use);
    }
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMapUnmanaged(*Operation),

    pub const symbol_attr_names = struct {
        pub const sym_name = "sym_name";
        pub const sym_visibility = "sym_visibility";
    };

    pub const Visibility = enum {
        public,
        private,
        nested,

        pub fn fromString(value: []const u8) ?Visibility {
            if (std.mem.eql(u8, value, "public")) return .public;
            if (std.mem.eql(u8, value, "private")) return .private;
            if (std.mem.eql(u8, value, "nested")) return .nested;
            return null;
        }

        pub fn toString(self: Visibility) []const u8 {
            return @tagName(self);
        }
    };

    pub const Collection = struct {
        allocator: std.mem.Allocator,
        tables: std.AutoArrayHashMapUnmanaged(*Operation, SymbolTable) = .empty,

        pub fn init(allocator: std.mem.Allocator) Collection {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Collection) void {
            for (self.tables.values()) |*table| {
                table.deinit();
            }
            self.tables.deinit(self.allocator);
            self.tables = .empty;
        }

        pub fn getSymbolTable(self: *Collection, op: *Operation) SymbolTableError!*SymbolTable {
            if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;

            const entry = try self.tables.getOrPut(self.allocator, op);
            if (!entry.found_existing) {
                entry.value_ptr.* = SymbolTable.init(self.allocator);
                entry.value_ptr.buildFromOperation(op) catch |err| {
                    entry.value_ptr.deinit();
                    _ = self.tables.swapRemove(op);
                    return err;
                };
            }
            return entry.value_ptr;
        }

        pub fn invalidateSymbolTable(self: *Collection, op: *Operation) void {
            if (self.tables.getPtr(op)) |table| {
                table.deinit();
                _ = self.tables.swapRemove(op);
            }
        }

        pub fn lookupSymbolIn(
            self: *Collection,
            op: *Operation,
            name: []const u8,
        ) SymbolTableError!?*Operation {
            if (!isSymbolTableOperation(op)) return null;
            const table = try self.getSymbolTable(op);
            return table.lookup(name);
        }

        pub fn lookupSymbolRefIn(
            self: *Collection,
            op: *Operation,
            symbol_ref: *const Attribute.SymbolRefAttr,
        ) SymbolTableError!?*Operation {
            var resolved = try self.lookupSymbolIn(op, symbol_ref.getRootReference()) orelse return null;
            for (symbol_ref.getNestedReferences()) |nested_ref| {
                resolved = try self.lookupSymbolIn(resolved, nested_ref) orelse return null;
                if (getSymbolVisibility(resolved) == .private) return null;
            }
            return resolved;
        }

        pub fn lookupNearestSymbolFrom(
            self: *Collection,
            from: *Operation,
            name: []const u8,
        ) SymbolTableError!?*Operation {
            const table_op = getNearestSymbolTable(from) orelse return null;
            return self.lookupSymbolIn(table_op, name);
        }

        pub fn lookupNearestSymbolRefFrom(
            self: *Collection,
            from: *Operation,
            symbol_ref: *const Attribute.SymbolRefAttr,
        ) SymbolTableError!?*Operation {
            const table_op = getNearestSymbolTable(from) orelse return null;
            return self.lookupSymbolRefIn(table_op, symbol_ref);
        }
    };

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .allocator = allocator,
            .symbols = .{},
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.symbols.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *SymbolTable) void {
        self.symbols.clearRetainingCapacity();
    }

    pub fn lookup(self: *const SymbolTable, name: []const u8) ?*Operation {
        return self.symbols.get(name);
    }

    pub fn iterator(self: *SymbolTable) std.StringHashMapUnmanaged(*Operation).Iterator {
        return self.symbols.iterator();
    }

    pub fn buildFromOperation(self: *SymbolTable, op: *Operation) SymbolTableError!void {
        self.clearRetainingCapacity();
        if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;
        if (op.regions.items.len != 1) return error.InvalidSymbolTable;
        const region = &op.regions.items[0];
        if (region.blocks.size != 1) return error.InvalidSymbolTable;
        try self.appendFromRegion(region);
    }

    fn appendFromRegion(self: *SymbolTable, region: *Region) SymbolTableError!void {
        const block = region.blocks.front() orelse return;
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (getSymbolName(op)) |name| {
                try self.addSymbol(name, op);
            }
        }
    }

    fn addSymbol(self: *SymbolTable, name: []const u8, op: *Operation) SymbolTableError!void {
        const entry = try self.symbols.getOrPut(self.allocator, name);
        if (entry.found_existing) return error.DuplicateSymbol;
        entry.value_ptr.* = op;
    }

    pub fn isSymbolTableOperation(op: *Operation) bool {
        return op.getTraits().is_symbol_table;
    }

    pub fn isSymbolOperation(op: *Operation) bool {
        return op.interface(interfaces.SymbolOpInterface) != null;
    }

    pub fn verifyOperation(op: *Operation) anyerror!void {
        var symbol_tables = Collection.init(op.allocator);
        defer symbol_tables.deinit();
        _ = try symbol_tables.getSymbolTable(op);
        try verifySymbols(op);
        try verifySymbolUsesInSymbolTable(&symbol_tables, op);
    }

    fn verifySymbols(op: *Operation) SymbolTableError!void {
        if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;
        if (op.regions.items.len != 1) return error.InvalidSymbolTable;
        const region = &op.regions.items[0];
        if (region.blocks.size != 1) return error.InvalidSymbolTable;
        const block = region.blocks.front() orelse return;
        var ops = block.getOperations();
        while (ops.next()) |candidate| {
            if (!isSymbolOperation(candidate)) continue;
            if (isDeclaration(candidate) and getSymbolVisibility(candidate) == .public) {
                return error.InvalidSymbolDeclaration;
            }
        }
    }

    pub fn lookupSymbolIn(op: *Operation, name: []const u8) ?*Operation {
        if (!isSymbolTableOperation(op)) return null;
        if (op.regions.items.len == 0) return null;
        const region = &op.regions.items[0];
        const block = region.blocks.front() orelse return null;
        var ops = block.getOperations();
        while (ops.next()) |candidate| {
            if (getSymbolName(candidate)) |symbol_name| {
                if (std.mem.eql(u8, symbol_name, name)) return candidate;
            }
        }
        return null;
    }

    pub fn lookupSymbolRefIn(op: *Operation, symbol_ref: *const Attribute.SymbolRefAttr) ?*Operation {
        var resolved = lookupSymbolIn(op, symbol_ref.getRootReference()) orelse return null;
        for (symbol_ref.getNestedReferences()) |nested_ref| {
            resolved = lookupSymbolIn(resolved, nested_ref) orelse return null;
            if (getSymbolVisibility(resolved) == .private) return null;
        }
        return resolved;
    }

    pub fn getNearestSymbolTable(from: *Operation) ?*Operation {
        var current: ?*Operation = from;
        while (current) |op| {
            if (isSymbolTableOperation(op)) return op;
            current = op.getParentOp();
        }
        return null;
    }

    pub fn lookupNearestSymbolFrom(from: *Operation, name: []const u8) ?*Operation {
        const table_op = getNearestSymbolTable(from) orelse return null;
        return lookupSymbolIn(table_op, name);
    }

    pub fn lookupNearestSymbolRefFrom(from: *Operation, symbol_ref: *const Attribute.SymbolRefAttr) ?*Operation {
        const table_op = getNearestSymbolTable(from) orelse return null;
        return lookupSymbolRefIn(table_op, symbol_ref);
    }

    pub fn collectSymbolUses(
        allocator: std.mem.Allocator,
        from: *Operation,
    ) anyerror!SymbolUseRange {
        var range = SymbolUseRange{};
        errdefer range.deinit(allocator);
        try appendSymbolUsesFromOperation(allocator, &range, from, null);
        return range;
    }

    pub fn collectSymbolUsesInRegion(
        allocator: std.mem.Allocator,
        from: *Region,
    ) anyerror!SymbolUseRange {
        var range = SymbolUseRange{};
        errdefer range.deinit(allocator);
        try appendSymbolUsesFromRegion(allocator, &range, from, null);
        return range;
    }

    pub fn collectSymbolUsesInSymbolTable(
        allocator: std.mem.Allocator,
        op: *Operation,
    ) anyerror!SymbolUseRange {
        if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;
        var range = SymbolUseRange{};
        errdefer range.deinit(allocator);
        for (op.regions.items) |*region| {
            try appendSymbolUsesFromRegion(allocator, &range, region, null);
        }
        return range;
    }

    pub fn collectSymbolUsesOf(
        allocator: std.mem.Allocator,
        from: *Operation,
        symbol_ref: *const Attribute.SymbolRefAttr,
    ) anyerror!SymbolUseRange {
        var range = SymbolUseRange{};
        errdefer range.deinit(allocator);
        try appendSymbolUsesFromOperation(allocator, &range, from, symbol_ref);
        return range;
    }

    pub fn collectSymbolUsesOfInRegion(
        allocator: std.mem.Allocator,
        from: *Region,
        symbol_ref: *const Attribute.SymbolRefAttr,
    ) anyerror!SymbolUseRange {
        var range = SymbolUseRange{};
        errdefer range.deinit(allocator);
        try appendSymbolUsesFromRegion(allocator, &range, from, symbol_ref);
        return range;
    }

    pub fn collectSymbolUsesOfInSymbolTable(
        allocator: std.mem.Allocator,
        op: *Operation,
        symbol_ref: *const Attribute.SymbolRefAttr,
    ) anyerror!SymbolUseRange {
        if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;
        var range = SymbolUseRange{};
        errdefer range.deinit(allocator);
        for (op.regions.items) |*region| {
            try appendSymbolUsesFromRegion(allocator, &range, region, symbol_ref);
        }
        return range;
    }

    pub fn symbolKnownUseEmpty(
        allocator: std.mem.Allocator,
        from: *Operation,
        symbol_ref: *const Attribute.SymbolRefAttr,
    ) anyerror!bool {
        var uses = try collectSymbolUsesOf(allocator, from, symbol_ref);
        defer uses.deinit(allocator);
        return uses.empty();
    }

    pub fn symbolKnownUseEmptyInRegion(
        allocator: std.mem.Allocator,
        from: *Region,
        symbol_ref: *const Attribute.SymbolRefAttr,
    ) anyerror!bool {
        var uses = try collectSymbolUsesOfInRegion(allocator, from, symbol_ref);
        defer uses.deinit(allocator);
        return uses.empty();
    }

    pub fn symbolKnownUseEmptyInSymbolTable(
        allocator: std.mem.Allocator,
        op: *Operation,
        symbol_ref: *const Attribute.SymbolRefAttr,
    ) anyerror!bool {
        var uses = try collectSymbolUsesOfInSymbolTable(allocator, op, symbol_ref);
        defer uses.deinit(allocator);
        return uses.empty();
    }

    pub fn replaceAllSymbolUsesInRegion(
        allocator: std.mem.Allocator,
        from: *Region,
        old_ref: *const Attribute.SymbolRefAttr,
        new_leaf: []const u8,
    ) anyerror!usize {
        return replaceSymbolUsesInRegion(allocator, from, old_ref, new_leaf);
    }

    pub fn replaceAllSymbolUsesInSymbolTable(
        allocator: std.mem.Allocator,
        op: *Operation,
        old_ref: *const Attribute.SymbolRefAttr,
        new_leaf: []const u8,
    ) anyerror!usize {
        if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;
        var replaced: usize = 0;
        for (op.regions.items) |*region| {
            replaced += try replaceSymbolUsesInRegion(allocator, region, old_ref, new_leaf);
        }
        return replaced;
    }

    pub fn renameSymbolInSymbolTable(
        allocator: std.mem.Allocator,
        op: *Operation,
        symbol: *Operation,
        new_name: []const u8,
    ) anyerror!usize {
        if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;
        if (symbol.getParentOp() != op) return error.InvalidSymbolTable;
        const old_name = getSymbolName(symbol) orelse return error.InvalidSymbol;
        if (std.mem.eql(u8, old_name, new_name)) return 0;
        if (lookupSymbolIn(op, new_name)) |existing| {
            if (existing != symbol) return error.DuplicateSymbol;
        }

        var symbol_tables = Collection.init(allocator);
        defer symbol_tables.deinit();
        var users = try SymbolUserMap.init(allocator, &symbol_tables, op);
        defer users.deinit();
        const replaced = try users.replaceAllUsesWith(symbol, new_name);
        try setSymbolName(symbol, new_name);
        symbol_tables.invalidateSymbolTable(op);
        return replaced;
    }

    pub fn getSymbolName(op: *Operation) ?[]const u8 {
        const iface = op.interface(interfaces.SymbolOpInterface) orelse return null;
        return iface.call(.getSymbolName, .{});
    }

    pub fn setSymbolName(op: *Operation, name: []const u8) anyerror!void {
        const iface = op.interface(interfaces.SymbolOpInterface) orelse return error.InvalidSymbol;
        try iface.call(.setSymbolName, .{name});
    }

    pub fn isDeclaration(op: *Operation) bool {
        const iface = op.interface(interfaces.SymbolOpInterface) orelse return false;
        return iface.call(.isDeclaration, .{});
    }

    pub fn getSymbolVisibility(op: *const Operation) Visibility {
        const string_attr = op.getAttrAs(Attribute.StringAttr, symbol_attr_names.sym_visibility) orelse return .public;
        return Visibility.fromString(string_attr.getValue()) orelse .public;
    }

    pub fn setSymbolVisibility(op: *Operation, visibility: Visibility) anyerror!void {
        if (!isSymbolOperation(op)) return error.InvalidSymbol;
        if (visibility == .public) {
            if (isDeclaration(op)) return error.InvalidSymbolDeclaration;
            _ = op.removeAttr(symbol_attr_names.sym_visibility);
            return;
        }
        try op.setAttr(
            symbol_attr_names.sym_visibility,
            try op.getContext().getStringAttr(visibility.toString()),
        );
    }

    fn appendSymbolRefsFromOperation(
        allocator: std.mem.Allocator,
        range: *SymbolUseRange,
        op: *Operation,
        target_ref: ?*const Attribute.SymbolRefAttr,
    ) anyerror!void {
        var attrs = op.getAttrs();
        while (attrs.next()) |attr| {
            try appendSymbolRefsFromAttribute(allocator, range, op, attr.name, attr.value, target_ref);
        }
    }

    fn appendSymbolRefsFromAttribute(
        allocator: std.mem.Allocator,
        range: *SymbolUseRange,
        op: *Operation,
        attr_name: []const u8,
        attr: Attribute,
        target_ref: ?*const Attribute.SymbolRefAttr,
    ) anyerror!void {
        if (getSymbolRefAttr(attr)) |symbol_ref| {
            if (target_ref) |target| {
                if (!isReferencePrefixOf(target, symbol_ref)) return;
            }
            try range.append(allocator, .{
                .user = op,
                .attr_name = attr_name,
                .symbol_ref = symbol_ref,
            });
            return;
        }

        const array_attr = getArrayAttr(attr) orelse return;
        for (array_attr.values) |child| {
            try appendSymbolRefsFromAttribute(allocator, range, op, attr_name, child, target_ref);
        }
    }

    fn appendSymbolUsesFromOperation(
        allocator: std.mem.Allocator,
        range: *SymbolUseRange,
        op: *Operation,
        target_ref: ?*const Attribute.SymbolRefAttr,
    ) anyerror!void {
        var state = SymbolUseWalkState{
            .allocator = allocator,
            .range = range,
            .target_ref = target_ref,
        };
        _ = try op.walk(.{ .order = .pre_order }, &state, SymbolUseWalkState.visit);
    }

    fn verifySymbolUsesInSymbolTable(symbol_tables: *Collection, op: *Operation) anyerror!void {
        if (!isSymbolTableOperation(op)) return error.InvalidSymbolTable;
        for (op.regions.items) |*region| {
            try verifySymbolUsesInRegion(symbol_tables, region);
        }
    }

    fn verifySymbolUsesFromOperation(symbol_tables: *Collection, op: *Operation) anyerror!void {
        var state = VerifySymbolUsesWalkState{ .symbol_tables = symbol_tables };
        _ = try op.walk(.{ .order = .pre_order }, &state, VerifySymbolUsesWalkState.visit);
    }

    fn verifySymbolUsesOnOperation(symbol_tables: *Collection, op: *Operation) anyerror!void {
        if (op.interface(interfaces.SymbolUserOpInterface)) |iface| {
            try iface.call(.verifySymbolUses, .{symbol_tables});
        }
        var attrs = op.getDiscardableAttrs();
        while (attrs.next()) |attr| {
            if (attr.value.interface(interfaces.SymbolUserAttrInterface)) |iface| {
                try iface.call(.verifySymbolUses, .{ op, symbol_tables });
            }
        }
    }

    fn verifySymbolUsesInRegion(symbol_tables: *Collection, region: *Region) anyerror!void {
        var state = VerifySymbolUsesWalkState{ .symbol_tables = symbol_tables };
        _ = try region.walkOperations(.{ .order = .pre_order }, &state, VerifySymbolUsesWalkState.visit);
    }

    fn appendSymbolUsesFromRegion(
        allocator: std.mem.Allocator,
        range: *SymbolUseRange,
        region: *Region,
        target_ref: ?*const Attribute.SymbolRefAttr,
    ) anyerror!void {
        var state = SymbolUseWalkState{
            .allocator = allocator,
            .range = range,
            .target_ref = target_ref,
        };
        _ = try region.walkOperations(.{ .order = .pre_order }, &state, SymbolUseWalkState.visit);
    }

    fn replaceSymbolUsesOnOperation(
        allocator: std.mem.Allocator,
        op: *Operation,
        old_ref: *const Attribute.SymbolRefAttr,
        new_leaf: []const u8,
    ) anyerror!usize {
        var replaced: usize = 0;
        var inline_snapshot: [4]NamedAttribute = undefined;
        const attr_count = op.getNumAttrs();
        const attr_snapshot = if (attr_count <= inline_snapshot.len)
            inline_snapshot[0..attr_count]
        else
            try allocator.alloc(NamedAttribute, attr_count);
        defer if (attr_count > inline_snapshot.len) allocator.free(attr_snapshot);
        var attrs = op.getAttrs();
        var attr_index: usize = 0;
        while (attrs.next()) |attr| : (attr_index += 1) {
            if (attr_index >= attr_snapshot.len) return error.OperationAttributesChanged;
            attr_snapshot[attr_index] = attr;
        }
        if (attr_index != attr_snapshot.len) return error.OperationAttributesChanged;
        for (attr_snapshot) |attr| {
            const result = try replaceSymbolUsesInAttribute(allocator, op, old_ref, attr.value, new_leaf);
            const replacement = result.attr orelse continue;
            try op.setAttr(attr.name, replacement);
            replaced += result.replaced;
        }
        return replaced;
    }

    fn replaceSymbolUsesInAttribute(
        allocator: std.mem.Allocator,
        op: *Operation,
        old_ref: *const Attribute.SymbolRefAttr,
        attr: Attribute,
        new_leaf: []const u8,
    ) anyerror!AttributeReplacement {
        if (getSymbolRefAttr(attr)) |symbol_ref| {
            const replacement = try replacementSymbolRefAttr(allocator, op, old_ref, symbol_ref, new_leaf) orelse return .{};
            return .{ .attr = replacement, .replaced = 1 };
        }

        const array_attr = getArrayAttr(attr) orelse return .{};
        var changed = false;
        var replaced: usize = 0;
        const values = try allocator.alloc(Attribute, array_attr.values.len);
        defer allocator.free(values);
        for (array_attr.values, 0..) |child, index| {
            const result = try replaceSymbolUsesInAttribute(allocator, op, old_ref, child, new_leaf);
            values[index] = result.attr orelse child;
            if (result.attr != null) changed = true;
            replaced += result.replaced;
        }
        if (!changed) return .{};
        return .{
            .attr = try op.getContext().getArrayAttr(values),
            .replaced = replaced,
        };
    }

    fn replaceSymbolUsesInOperation(
        allocator: std.mem.Allocator,
        op: *Operation,
        old_ref: *const Attribute.SymbolRefAttr,
        new_leaf: []const u8,
    ) anyerror!usize {
        var state = ReplaceSymbolUsesWalkState{
            .allocator = allocator,
            .old_ref = old_ref,
            .new_leaf = new_leaf,
        };
        _ = try op.walk(.{ .order = .pre_order }, &state, ReplaceSymbolUsesWalkState.visit);
        return state.replaced;
    }

    fn replaceSymbolUsesInRegion(
        allocator: std.mem.Allocator,
        region: *Region,
        old_ref: *const Attribute.SymbolRefAttr,
        new_leaf: []const u8,
    ) anyerror!usize {
        var state = ReplaceSymbolUsesWalkState{
            .allocator = allocator,
            .old_ref = old_ref,
            .new_leaf = new_leaf,
        };
        _ = try region.walkOperations(.{ .order = .pre_order }, &state, ReplaceSymbolUsesWalkState.visit);
        return state.replaced;
    }

    fn replacementSymbolRefAttr(
        allocator: std.mem.Allocator,
        op: *Operation,
        old_ref: *const Attribute.SymbolRefAttr,
        current_ref: *const Attribute.SymbolRefAttr,
        new_leaf: []const u8,
    ) anyerror!?Attribute {
        if (!isReferencePrefixOf(old_ref, current_ref)) return null;
        if (current_ref.getNestedReferences().len == 0) {
            return try op.getContext().getFlatSymbolRefAttr(new_leaf);
        }
        if (old_ref.getNestedReferences().len == 0) {
            return try op.getContext().getSymbolRefAttr(new_leaf, current_ref.getNestedReferences());
        }

        const nested = try allocator.dupe([]const u8, current_ref.getNestedReferences());
        defer allocator.free(nested);
        nested[old_ref.getNestedReferences().len - 1] = new_leaf;
        return try op.getContext().getSymbolRefAttr(current_ref.getRootReference(), nested);
    }

    fn symbolUsePrefix(use: SymbolUse, nested_len: usize) anyerror!SymbolUse {
        const attr = if (nested_len == 0)
            try use.user.getContext().getFlatSymbolRefAttr(use.symbol_ref.getRootReference())
        else
            try use.user.getContext().getSymbolRefAttr(
                use.symbol_ref.getRootReference(),
                use.symbol_ref.getNestedReferences()[0..nested_len],
            );
        const symbol_ref = attr.cast(Attribute.SymbolRefAttr).?;
        return .{
            .user = use.user,
            .attr_name = use.attr_name,
            .symbol_ref = symbol_ref,
        };
    }

    fn sameUse(a: SymbolUse, b: SymbolUse) bool {
        return a.user == b.user and
            std.mem.eql(u8, a.attr_name, b.attr_name) and
            symbolRefsEqual(a.symbol_ref, b.symbol_ref);
    }

    fn symbolRefsEqual(a: *const Attribute.SymbolRefAttr, b: *const Attribute.SymbolRefAttr) bool {
        if (a == b) return true;
        if (!std.mem.eql(u8, a.getRootReference(), b.getRootReference())) return false;
        const a_nested = a.getNestedReferences();
        const b_nested = b.getNestedReferences();
        if (a_nested.len != b_nested.len) return false;
        for (a_nested, b_nested) |a_ref, b_ref| {
            if (!std.mem.eql(u8, a_ref, b_ref)) return false;
        }
        return true;
    }

    fn isReferencePrefixOf(prefix: *const Attribute.SymbolRefAttr, symbol_ref: *const Attribute.SymbolRefAttr) bool {
        if (!std.mem.eql(u8, prefix.getRootReference(), symbol_ref.getRootReference())) return false;
        const prefix_nested = prefix.getNestedReferences();
        const ref_nested = symbol_ref.getNestedReferences();
        if (prefix_nested.len > ref_nested.len) return false;
        for (prefix_nested, 0..) |nested, index| {
            if (!std.mem.eql(u8, nested, ref_nested[index])) return false;
        }
        return true;
    }

    fn getSymbolRefAttr(attr: Attribute) ?*const Attribute.SymbolRefAttr {
        if (!std.mem.eql(u8, attr.abstract.name, attribute.builtin_attr_names.symbol_ref)) return null;
        return attr.cast(Attribute.SymbolRefAttr);
    }

    fn getArrayAttr(attr: Attribute) ?*const Attribute.ArrayAttr {
        if (!std.mem.eql(u8, attr.abstract.name, attribute.builtin_attr_names.array)) return null;
        return attr.cast(Attribute.ArrayAttr);
    }
};

const SymbolUserSet = struct {
    users: std.ArrayListUnmanaged(*Operation) = .empty,
    uses: std.ArrayListUnmanaged(SymbolUse) = .empty,

    fn deinit(self: *SymbolUserSet, allocator: std.mem.Allocator) void {
        self.users.deinit(allocator);
        self.uses.deinit(allocator);
        self.* = .{};
    }

    fn append(self: *SymbolUserSet, allocator: std.mem.Allocator, use: SymbolUse) !void {
        var found_user = false;
        for (self.users.items) |user| {
            if (user == use.user) {
                found_user = true;
                break;
            }
        }
        if (!found_user) try self.users.append(allocator, use.user);

        for (self.uses.items) |existing| {
            if (SymbolTable.sameUse(existing, use)) return;
        }
        try self.uses.append(allocator, use);
    }

    fn appendAll(
        self: *SymbolUserSet,
        allocator: std.mem.Allocator,
        other: *const SymbolUserSet,
    ) !void {
        for (other.uses.items) |use| {
            try self.append(allocator, use);
        }
    }
};

pub const SymbolUserMap = struct {
    allocator: std.mem.Allocator,
    symbol_tables: *SymbolTable.Collection,
    symbol_users: std.AutoArrayHashMapUnmanaged(*Operation, SymbolUserSet) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        symbol_tables: *SymbolTable.Collection,
        symbol_table_op: *Operation,
    ) anyerror!SymbolUserMap {
        if (!SymbolTable.isSymbolTableOperation(symbol_table_op)) return error.InvalidSymbolTable;
        var self = SymbolUserMap{
            .allocator = allocator,
            .symbol_tables = symbol_tables,
        };
        errdefer self.deinit();
        try self.appendFromSymbolTable(symbol_table_op);
        return self;
    }

    pub fn deinit(self: *SymbolUserMap) void {
        for (self.symbol_users.values()) |*users| {
            users.deinit(self.allocator);
        }
        self.symbol_users.deinit(self.allocator);
        self.symbol_users = .empty;
    }

    pub fn getUsers(self: *SymbolUserMap, symbol: *Operation) []const *Operation {
        if (self.symbol_users.getPtr(symbol)) |users| {
            return users.users.items;
        }
        return &.{};
    }

    pub fn useEmpty(self: *SymbolUserMap, symbol: *Operation) bool {
        return self.getUsers(symbol).len == 0;
    }

    pub fn replaceAllUsesWith(
        self: *SymbolUserMap,
        symbol: *Operation,
        new_name: []const u8,
    ) anyerror!usize {
        const old_name = SymbolTable.getSymbolName(symbol) orelse return error.InvalidSymbol;
        if (std.mem.eql(u8, old_name, new_name)) return 0;

        const users = self.symbol_users.getPtr(symbol) orelse return 0;
        var replaced: usize = 0;
        for (users.uses.items) |*use| {
            const replacement = try SymbolTable.replacementSymbolRefAttr(self.allocator, use.user, use.symbol_ref, use.symbol_ref, new_name) orelse continue;
            const replacement_ref = replacement.cast(Attribute.SymbolRefAttr).?;
            replaced += try SymbolTable.replaceSymbolUsesOnOperation(self.allocator, use.user, use.symbol_ref, new_name);
            use.symbol_ref = replacement_ref;
        }

        const new_symbol = blk: {
            const parent = symbol.getParentOp() orelse break :blk null;
            break :blk try self.symbol_tables.lookupSymbolIn(parent, new_name);
        };
        try self.moveUsers(symbol, new_symbol);
        return replaced;
    }

    fn appendFromSymbolTable(self: *SymbolUserMap, symbol_table_op: *Operation) anyerror!void {
        var uses = try SymbolTable.collectSymbolUsesInSymbolTable(self.allocator, symbol_table_op);
        defer uses.deinit(self.allocator);

        for (uses.items()) |use| {
            try self.appendResolvedUse(symbol_table_op, use);
        }

        try self.appendNestedSymbolTables(symbol_table_op);
    }

    fn appendNestedSymbolTables(self: *SymbolUserMap, op: *Operation) anyerror!void {
        var state = NestedSymbolTableWalkState{ .user_map = self };
        for (op.regions.items) |*region| {
            _ = try region.walkOperations(.{ .order = .pre_order }, &state, NestedSymbolTableWalkState.visit);
        }
    }

    fn appendResolvedUse(
        self: *SymbolUserMap,
        symbol_table_op: *Operation,
        use: SymbolUse,
    ) anyerror!void {
        var resolved = try self.symbol_tables.lookupSymbolIn(symbol_table_op, use.symbol_ref.getRootReference()) orelse return;
        try self.appendSymbolUse(resolved, try SymbolTable.symbolUsePrefix(use, 0));

        for (use.symbol_ref.getNestedReferences(), 0..) |nested_ref, index| {
            resolved = try self.symbol_tables.lookupSymbolIn(resolved, nested_ref) orelse return;
            if (SymbolTable.getSymbolVisibility(resolved) == .private) return;
            try self.appendSymbolUse(resolved, try SymbolTable.symbolUsePrefix(use, index + 1));
        }
    }

    fn appendSymbolUse(self: *SymbolUserMap, symbol: *Operation, use: SymbolUse) !void {
        const entry = try self.symbol_users.getOrPut(self.allocator, symbol);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        try entry.value_ptr.append(self.allocator, use);
    }

    fn moveUsers(self: *SymbolUserMap, old_symbol: *Operation, new_symbol: ?*Operation) !void {
        var old_users = self.symbol_users.getPtr(old_symbol).?.*;
        _ = self.symbol_users.swapRemove(old_symbol);
        var transferred = false;
        errdefer if (!transferred) old_users.deinit(self.allocator);

        if (new_symbol) |target| {
            if (self.symbol_users.getPtr(target)) |target_users| {
                try target_users.appendAll(self.allocator, &old_users);
                old_users.deinit(self.allocator);
                transferred = true;
                return;
            }

            const entry = try self.symbol_users.getOrPut(self.allocator, target);
            entry.value_ptr.* = old_users;
            transferred = true;
            return;
        }

        old_users.deinit(self.allocator);
        transferred = true;
    }
};

const NestedSymbolTableWalkState = struct {
    user_map: *SymbolUserMap,

    fn visit(self: *@This(), op: *Operation) anyerror!Operation.WalkResult {
        if (!SymbolTable.isSymbolTableOperation(op)) return .advance;
        try self.user_map.appendFromSymbolTable(op);
        return .skip;
    }
};

const SymbolUseWalkState = struct {
    allocator: std.mem.Allocator,
    range: *SymbolUseRange,
    target_ref: ?*const Attribute.SymbolRefAttr,

    fn visit(self: *@This(), op: *Operation) anyerror!Operation.WalkResult {
        try SymbolTable.appendSymbolRefsFromOperation(self.allocator, self.range, op, self.target_ref);
        if (SymbolTable.isSymbolTableOperation(op)) return .skip;
        return .advance;
    }
};

const VerifySymbolUsesWalkState = struct {
    symbol_tables: *SymbolTable.Collection,

    fn visit(self: *@This(), op: *Operation) anyerror!Operation.WalkResult {
        try SymbolTable.verifySymbolUsesOnOperation(self.symbol_tables, op);
        if (SymbolTable.isSymbolTableOperation(op)) return .skip;
        return .advance;
    }
};

const ReplaceSymbolUsesWalkState = struct {
    allocator: std.mem.Allocator,
    old_ref: *const Attribute.SymbolRefAttr,
    new_leaf: []const u8,
    replaced: usize = 0,

    fn visit(self: *@This(), op: *Operation) anyerror!Operation.WalkResult {
        self.replaced += try SymbolTable.replaceSymbolUsesOnOperation(self.allocator, op, self.old_ref, self.new_leaf);
        if (SymbolTable.isSymbolTableOperation(op)) return .skip;
        return .advance;
    }
};

const TestModuleSymbol = struct {
    fn getSymbolName(op_ptr: *const anyopaque) ?[]const u8 {
        const op: *const Operation = @ptrCast(@alignCast(op_ptr));
        const attr = op.getAttr("sym_name") orelse return null;
        if (!std.mem.eql(u8, attr.abstract.name, "test.string")) return null;
        const dialect_attr = attr.cast(Attribute.DialectAttr) orelse return null;
        return dialect_attr.payload;
    }

    fn setSymbolName(op_ptr: *const anyopaque, name: []const u8) anyerror!void {
        const op: *Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try op.setAttr("sym_name", try op.getContext().getDialectAttr("test.string", name));
    }

    fn isDeclaration(_: *const anyopaque) bool {
        return false;
    }

    const vtable = interfaces.SymbolOpInterface.VTable{
        .getSymbolName = getSymbolName,
        .setSymbolName = setSymbolName,
        .isDeclaration = isDeclaration,
    };
};

const TestSymbolUserAttribute = struct {
    fn verifySymbolUses(
        attr_ptr: *const anyopaque,
        op: *Operation,
        symbol_tables: *SymbolTable.Collection,
    ) anyerror!void {
        const attr: *const Attribute.DialectAttr = @ptrCast(@alignCast(attr_ptr));
        _ = try symbol_tables.lookupNearestSymbolFrom(op, attr.payload) orelse return error.UnresolvedAttrSymbol;
    }
};

const ReadOnlySymbolRefProperties = struct {
    value: ?Attribute = null,

    fn from(storage: *anyopaque) *@This() {
        return @ptrCast(@alignCast(storage));
    }

    fn fromConst(storage: *const anyopaque) *const @This() {
        return @ptrCast(@alignCast(storage));
    }

    fn init(storage: *anyopaque, _: std.mem.Allocator) anyerror!void {
        from(storage).* = .{};
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

    fn get(_: *const Operation, storage: *const anyopaque, name: []const u8) ?Attribute {
        if (!std.mem.eql(u8, name, "callee")) return null;
        return fromConst(storage).value;
    }

    fn getProperties(_: *const Operation, storage: *const anyopaque) ?Attribute {
        return fromConst(storage).value;
    }

    fn setProperties(_: *Operation, storage: *anyopaque, attr: Attribute) anyerror!void {
        from(storage).value = attr;
    }

    fn copyProperties(dest: *anyopaque, source: *const anyopaque) anyerror!void {
        from(dest).* = fromConst(source).*;
    }

    const model = interfaces.OperationPropertiesModel{
        .name = "test.read_only_symbol_ref.properties",
        .size = @sizeOf(@This()),
        .alignment = std.mem.Alignment.fromByteUnits(@alignOf(@This())),
        .init = init,
        .deinit = deinit,
        .getInherentAttr = get,
        .getPropertiesAsAttr = getProperties,
        .setPropertiesFromAttr = setProperties,
        .copyProperties = copyProperties,
    };
};
