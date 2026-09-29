const std = @import("std");
const alloc_arena = @import("alloc_arena");

const Attribute = @import("attribute.zig").Attribute;
const context_mod = @import("context/root.zig");
const Context = context_mod.Context;
const Location = @import("location.zig").Location;
const NamedAttribute = @import("attribute.zig").NamedAttribute;
const Operation = @import("operation/root.zig").Operation;
const Region = @import("region.zig").Region;
const Type = @import("type.zig").Type;
const Value = @import("value.zig").Value;
const dump = @import("dump.zig");
const interfaces = @import("interfaces/root.zig");

pub const ParseError = error{
    DuplicateValueId,
    ExpectedAttributeName,
    ExpectedBlock,
    ExpectedByte,
    ExpectedColon,
    ExpectedComma,
    ExpectedEquals,
    ExpectedHeaderTerminator,
    ExpectedListEnd,
    ExpectedNewline,
    ExpectedOperationName,
    ExpectedRegion,
    ExpectedString,
    ExpectedType,
    ExpectedValue,
    InvalidAttribute,
    InvalidBool,
    InvalidFloat,
    InvalidInteger,
    InvalidType,
    InvalidValue,
    MissingValue,
    TrailingInput,
    UnexpectedEnd,
    UnsupportedSuccessors,
};

const ParseTarget = union(enum) {
    operation: void,
    region: void,
    block: *Region,
};

const ParseResult = union(enum) {
    operation: *Operation,
    region: *Region,
    block: void,
};

pub const Source = struct {
    name: []const u8,
    text: []const u8,
};

pub fn operation(ctx: *Context, text: []const u8) anyerror!*Operation {
    return source(ctx, .{ .name = "<string>", .text = text });
}

/// Parses named text with Context-owned filenames and half-open byte ranges.
pub fn source(ctx: *Context, input: Source) anyerror!*Operation {
    var parser = try Parser.init(ctx, input);
    defer parser.deinit();
    const op = try parser.parseOperation();
    parser.skipBlankLines();
    if (!parser.atEnd()) return ParseError.TrailingInput;
    return op;
}

const Parser = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    operation_allocator: std.mem.Allocator,
    text: []const u8,
    source_name: []const u8,
    line_starts: std.ArrayList(usize),
    index: usize = 0,
    values: std.AutoHashMap(usize, *Value),

    fn init(ctx: *Context, input: Source) !Parser {
        const transient_allocator = context_mod.transientAllocator(ctx);
        const operation_allocator = context_mod.operationAllocator(ctx);
        var line_starts: std.ArrayList(usize) = .empty;
        errdefer line_starts.deinit(transient_allocator);
        try line_starts.append(transient_allocator, 0);
        for (input.text, 0..) |byte, index| {
            if (byte == '\n') try line_starts.append(transient_allocator, index + 1);
        }
        const source_name = try operation_allocator.dupe(u8, input.name);
        return .{
            .ctx = ctx,
            .allocator = transient_allocator,
            .operation_allocator = operation_allocator,
            .text = input.text,
            .source_name = source_name,
            .line_starts = line_starts,
            .values = std.AutoHashMap(usize, *Value).init(transient_allocator),
        };
    }

    fn deinit(self: *Parser) void {
        self.values.deinit();
        self.line_starts.deinit(self.allocator);
    }

    fn position(self: *const Parser, byte: usize) Location.FilePosition {
        std.debug.assert(byte <= self.text.len);
        var low: usize = 0;
        var high = self.line_starts.items.len;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            if (self.line_starts.items[middle] <= byte) {
                low = middle;
            } else {
                high = middle;
            }
        }
        return .{
            .byte = byte,
            .line = @intCast(low + 1),
            .column = @intCast(byte - self.line_starts.items[low] + 1),
        };
    }

    fn location(self: *const Parser, start: usize, end: usize) Location {
        return Location.getFileRange(self.source_name, self.position(start), self.position(end));
    }

    fn parseOperation(self: *Parser) anyerror!*Operation {
        const parsed = try self.parseStructure(.{ .operation = {} });
        return switch (parsed) {
            .operation => |op| op,
            else => unreachable,
        };
    }

    fn parseStructure(self: *Parser, target: ParseTarget) anyerror!ParseResult {
        switch (target) {
            .operation => {
                self.skipSpaces();
                const header_start = self.index;
                const header_length = std.mem.indexOfAny(u8, self.text[header_start..], "\r\n") orelse
                    self.text.len - header_start;
                const loc = self.location(header_start, header_start + header_length);

                var result_ids: std.ArrayListUnmanaged(usize) = .empty;
                defer result_ids.deinit(self.allocator);
                try self.parseResultIds(&result_ids);

                const op_name = try self.parseOperationName();
                try self.expectByte('(');

                var operands: std.ArrayListUnmanaged(*Value) = .empty;
                defer operands.deinit(self.allocator);
                try self.parseOperands(&operands);
                try self.expectByte(')');

                self.skipSpaces();
                if (self.consumeArrow()) return ParseError.UnsupportedSuccessors;

                var properties: ?Attribute = null;
                if (self.consumeLiteral("properties(")) {
                    properties = try self.parseAttribute();
                    self.skipSpaces();
                    try self.expectByte(')');
                }

                self.skipSpaces();
                var attrs: std.ArrayListUnmanaged(NamedAttribute) = .empty;
                defer attrs.deinit(self.allocator);
                if (self.peekByte() == '{' and !self.peekRegionStart()) {
                    try self.parseAttributes(&attrs);
                }

                self.skipSpaces();
                var result_types: std.ArrayListUnmanaged(Type) = .empty;
                defer result_types.deinit(self.allocator);
                if (self.consumeByte(':')) {
                    try self.parseTypeListUntilHeaderEnd(&result_types);
                }

                if (result_ids.items.len != result_types.items.len) return ParseError.InvalidValue;

                var regions: std.ArrayListUnmanaged(*Region) = .empty;
                defer {
                    for (regions.items) |region| {
                        region.deinit();
                        self.operation_allocator.destroy(region);
                    }
                    regions.deinit(self.allocator);
                }

                while (true) {
                    self.skipSpaces();
                    if (!self.peekRegionStart()) break;
                    const parsed = try self.parseStructure(.{ .region = {} });
                    const region = switch (parsed) {
                        .region => |region| region,
                        else => unreachable,
                    };
                    try regions.append(self.allocator, region);
                }

                self.consumeOperationEnd();

                var state = Operation.State.init(op_name, loc);
                state.addOperands(operands.items);
                state.addTypes(result_types.items);
                state.addRawAttributes(attrs.items);
                if (properties) |payload| try state.setPropertiesAttr(payload);
                state.addRegionBodies(regions.items);

                const op = try self.ctx.createOperation(state);
                errdefer op.erase();

                for (result_ids.items, 0..) |id, result_index| {
                    try self.recordValue(id, op.getResult(result_index) orelse return ParseError.InvalidValue);
                }

                return .{ .operation = op };
            },
            .region => {
                try self.expectByte('{');
                try self.expectNewline();

                const region = try self.operation_allocator.create(Region);
                region.* = Region.init(self.operation_allocator);
                errdefer {
                    region.deinit();
                    self.operation_allocator.destroy(region);
                }

                while (true) {
                    self.skipSpaces();
                    if (self.consumeByte('}')) break;
                    if (self.atEnd()) return ParseError.UnexpectedEnd;
                    _ = try self.parseStructure(.{ .block = region });
                }

                return .{ .region = region };
            },
            .block => |region| {
                self.skipSpaces();
                try self.expectByte('^');
                try self.expectLiteral("bb");
                _ = try self.parseUnsigned();

                const block = try region.addBlock();

                if (self.consumeByte('(')) {
                    self.skipSpaces();
                    if (!self.consumeByte(')')) {
                        while (true) {
                            const argument_start = self.index;
                            const id = try self.parseValueId();
                            try self.expectByte(':');
                            self.skipSpaces();
                            const typ = try self.parseType();
                            const loc = self.location(argument_start, self.index);
                            const arg = try block.addArgument(typ, loc);
                            try self.recordValue(id, arg);
                            self.skipSpaces();
                            if (self.consumeByte(')')) break;
                            try self.expectByte(',');
                            self.skipSpaces();
                        }
                    }
                }

                try self.expectByte(':');
                try self.expectNewline();

                while (true) {
                    self.skipSpaces();
                    switch (self.peekByte()) {
                        0 => return ParseError.UnexpectedEnd,
                        '^', '}' => return .{ .block = {} },
                        else => {},
                    }
                    const parsed = try self.parseStructure(.{ .operation = {} });
                    const op = switch (parsed) {
                        .operation => |op| op,
                        else => unreachable,
                    };
                    var inserted = false;
                    errdefer if (!inserted) op.erase();
                    try block.addOperation(op);
                    inserted = true;
                }
            },
        }
    }

    fn parseResultIds(self: *Parser, ids: *std.ArrayListUnmanaged(usize)) !void {
        if (self.peekByte() != '%') return;

        const start = self.index;
        while (true) {
            try ids.append(self.allocator, try self.parseValueId());
            self.skipSpaces();
            if (!self.consumeByte(',')) break;
            self.skipSpaces();
        }
        self.skipSpaces();
        if (self.consumeByte('=')) {
            self.skipSpaces();
            return;
        }

        ids.clearRetainingCapacity();
        self.index = start;
    }

    fn parseOperationName(self: *Parser) ![]const u8 {
        self.skipSpaces();
        const start = self.index;
        while (!self.atEnd() and self.peekByte() != '(' and !isNewline(self.peekByte())) {
            self.index += 1;
        }
        const name = std.mem.trim(u8, self.text[start..self.index], " \t\r");
        if (name.len == 0) return ParseError.ExpectedOperationName;
        return name;
    }

    fn parseOperands(self: *Parser, operands: *std.ArrayListUnmanaged(*Value)) !void {
        self.skipSpaces();
        if (self.peekByte() == ')') return;
        while (true) {
            const id = try self.parseValueId();
            const value = self.values.get(id) orelse return ParseError.MissingValue;
            try operands.append(self.allocator, value);
            self.skipSpaces();
            if (!self.consumeByte(',')) break;
            self.skipSpaces();
        }
    }

    fn parseAttributes(self: *Parser, attrs: *std.ArrayListUnmanaged(NamedAttribute)) !void {
        try self.expectByte('{');
        self.skipSpaces();
        if (self.consumeByte('}')) return;

        while (true) {
            const name = try self.parseAttributeName();
            self.skipSpaces();
            try self.expectByte('=');
            self.skipSpaces();
            const attr = try self.parseAttribute();
            try attrs.append(self.allocator, .{
                .name = name,
                .value = attr,
            });
            self.skipSpaces();
            if (self.consumeByte('}')) return;
            try self.expectByte(',');
            self.skipSpaces();
        }
    }

    fn parseAttributeName(self: *Parser) ![]const u8 {
        const start = self.index;
        while (!self.atEnd()) {
            const byte = self.peekByte();
            if (byte == '=' or byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') break;
            self.index += 1;
        }
        const name = self.text[start..self.index];
        if (name.len == 0) return ParseError.ExpectedAttributeName;
        return name;
    }

    fn parseAttribute(self: *Parser) anyerror!Attribute {
        self.skipSpaces();
        if (self.atEnd()) return ParseError.UnexpectedEnd;

        if (self.peekByte() == '"') {
            const value = try self.parseStringAlloc();
            defer self.allocator.free(value);
            return try self.ctx.getStringAttr(value);
        }

        if (self.consumeLiteral("true")) return try self.ctx.getBoolAttr(true);
        if (self.consumeLiteral("false")) return try self.ctx.getBoolAttr(false);

        if (self.peekByte() == '@') return try self.parseSymbolRefAttr();
        if (self.peekByte() == '[') {
            try self.expectByte('[');
            self.skipSpaces();
            if (self.consumeByte(']')) return try self.ctx.getStringListAttr(&.{});
            if (self.peekByte() == '!') return try self.parseTypeListAttr();
            if (self.peekByte() == '"') return try self.parseStringListAttr();

            var attrs: std.ArrayListUnmanaged(Attribute) = .empty;
            defer attrs.deinit(self.allocator);
            while (true) {
                try attrs.append(self.allocator, try self.parseAttribute());
                self.skipSpaces();
                if (self.consumeByte(']')) break;
                try self.expectByte(',');
                self.skipSpaces();
            }
            return try self.ctx.getArrayAttr(attrs.items);
        }
        if (self.peekByte() == '#') return try self.parseDialectAttr();
        return try self.parseNumericAttr();
    }

    fn parseSymbolRefAttr(self: *Parser) !Attribute {
        try self.expectByte('@');
        const root = try self.parseSymbolSegment();
        var nested: std.ArrayListUnmanaged([]const u8) = .empty;
        defer nested.deinit(self.allocator);

        while (self.consumeLiteral("::")) {
            try self.expectByte('@');
            try nested.append(self.allocator, try self.parseSymbolSegment());
        }

        return try self.ctx.getSymbolRefAttr(root, nested.items);
    }

    fn parseSymbolSegment(self: *Parser) ![]const u8 {
        const start = self.index;
        while (!self.atEnd()) {
            const byte = self.peekByte();
            if (byte == ':' or byte == ',' or byte == '}' or byte == ']' or byte == ')' or byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') break;
            self.index += 1;
        }
        const segment = self.text[start..self.index];
        if (segment.len == 0) return ParseError.InvalidAttribute;
        return segment;
    }

    fn parseTypeListAttr(self: *Parser) anyerror!Attribute {
        var types: std.ArrayListUnmanaged(Type) = .empty;
        defer types.deinit(self.allocator);
        while (true) {
            try types.append(self.allocator, try self.parseType());
            self.skipSpaces();
            if (self.consumeByte(']')) break;
            try self.expectByte(',');
            self.skipSpaces();
        }
        return try self.ctx.getTypeListAttr(types.items);
    }

    fn parseStringListAttr(self: *Parser) anyerror!Attribute {
        var strings: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (strings.items) |value| self.allocator.free(value);
            strings.deinit(self.allocator);
        }
        while (true) {
            try strings.append(self.allocator, try self.parseStringAlloc());
            self.skipSpaces();
            if (self.consumeByte(']')) break;
            try self.expectByte(',');
            self.skipSpaces();
        }
        return try self.ctx.getStringListAttr(strings.items);
    }

    fn parseDialectAttr(self: *Parser) !Attribute {
        try self.expectLiteral("#attr<");
        const name_start = self.index;
        while (!self.atEnd() and self.peekByte() != '>') self.index += 1;
        if (self.atEnd()) return ParseError.InvalidAttribute;
        const name = self.text[name_start..self.index];
        try self.expectByte('>');

        if (!self.consumeByte('(')) return try self.ctx.getDialectAttr(name, "");
        const payload = try self.parseStringAlloc();
        defer self.allocator.free(payload);
        try self.expectByte(')');
        return try self.ctx.getDialectAttr(name, payload);
    }

    fn parseNumericAttr(self: *Parser) !Attribute {
        const number_start = self.index;
        if (self.peekByte() == '-') self.index += 1;
        while (!self.atEnd() and isDigit(self.peekByte())) self.index += 1;
        if (self.peekByte() == '.') {
            self.index += 1;
            while (!self.atEnd() and isDigit(self.peekByte())) self.index += 1;
        }
        if (number_start == self.index) return ParseError.InvalidAttribute;
        const number = self.text[number_start..self.index];

        try self.expectByte(':');
        if (self.consumeByte('i')) {
            const width = try self.parseUnsigned();
            const value = std.fmt.parseInt(i64, number, 10) catch return ParseError.InvalidInteger;
            return try self.ctx.getIntegerAttr(value, @intCast(width), true);
        }
        if (self.consumeByte('f')) {
            const width = try self.parseUnsigned();
            const value = std.fmt.parseFloat(f64, number) catch return ParseError.InvalidFloat;
            return try self.ctx.getFloatAttr(value, @intCast(width));
        }
        return ParseError.InvalidAttribute;
    }

    fn parseTypeListUntilHeaderEnd(self: *Parser, types: *std.ArrayListUnmanaged(Type)) !void {
        while (true) {
            self.skipSpaces();
            try types.append(self.allocator, try self.parseType());
            self.skipSpaces();
            if (!self.consumeByte(',')) return;
        }
    }

    fn parseType(self: *Parser) !Type {
        self.skipSpaces();
        try self.expectByte('!');
        const name_start = self.index;
        while (!self.atEnd()) {
            const byte = self.peekByte();
            if (byte == '<' or byte == ',' or byte == ')' or byte == ']' or byte == '}' or byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') break;
            self.index += 1;
        }
        const name = self.text[name_start..self.index];
        if (name.len == 0) return ParseError.ExpectedType;

        var key: []const u8 = "";
        if (self.consumeByte('<')) {
            const key_start = self.index;
            while (!self.atEnd() and self.peekByte() != '>') self.index += 1;
            if (self.atEnd()) return ParseError.InvalidType;
            key = self.text[key_start..self.index];
            try self.expectByte('>');
        }

        return try self.ctx.getDialectTypeFromNameWithKey(name, key);
    }

    fn parseStringAlloc(self: *Parser) ![]u8 {
        try self.expectByte('"');
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            if (self.atEnd()) return ParseError.ExpectedString;
            const byte = self.nextByte();
            if (byte == '"') return try out.toOwnedSlice(self.allocator);
            if (byte != '\\') {
                try out.append(self.allocator, byte);
                continue;
            }
            if (self.atEnd()) return ParseError.ExpectedString;
            const escaped = self.nextByte();
            try out.append(self.allocator, switch (escaped) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return ParseError.ExpectedString,
            });
        }
    }

    fn parseValueId(self: *Parser) !usize {
        try self.expectByte('%');
        return try self.parseUnsigned();
    }

    fn parseUnsigned(self: *Parser) !usize {
        const start = self.index;
        while (!self.atEnd() and isDigit(self.peekByte())) self.index += 1;
        if (start == self.index) return ParseError.InvalidInteger;
        return std.fmt.parseUnsigned(usize, self.text[start..self.index], 10) catch ParseError.InvalidInteger;
    }

    fn recordValue(self: *Parser, id: usize, value: *Value) !void {
        if (self.values.contains(id)) return ParseError.DuplicateValueId;
        try self.values.put(id, value);
    }

    fn consumeOperationEnd(self: *Parser) void {
        self.skipSpaces();
        _ = self.consumeByte('\n');
    }

    fn consumeArrow(self: *Parser) bool {
        const start = self.index;
        if (!self.consumeByte('-')) return false;
        if (self.consumeByte('>')) return true;
        self.index = start;
        return false;
    }

    fn consumeByte(self: *Parser, byte: u8) bool {
        if (self.peekByte() != byte) return false;
        self.index += 1;
        return true;
    }

    fn consumeLiteral(self: *Parser, literal: []const u8) bool {
        if (!std.mem.startsWith(u8, self.text[self.index..], literal)) return false;
        self.index += literal.len;
        return true;
    }

    fn expectByte(self: *Parser, byte: u8) !void {
        if (!self.consumeByte(byte)) return ParseError.ExpectedByte;
    }

    fn expectLiteral(self: *Parser, literal: []const u8) !void {
        if (!self.consumeLiteral(literal)) return ParseError.ExpectedByte;
    }

    fn expectNewline(self: *Parser) !void {
        if (self.consumeByte('\n')) return;
        return ParseError.ExpectedNewline;
    }

    fn nextByte(self: *Parser) u8 {
        const byte = self.text[self.index];
        self.index += 1;
        return byte;
    }

    fn peekByte(self: *const Parser) u8 {
        if (self.index >= self.text.len) return 0;
        return self.text[self.index];
    }

    fn peekRegionStart(self: *const Parser) bool {
        if (self.peekByte() != '{') return false;
        const next = self.index + 1;
        return next < self.text.len and self.text[next] == '\n';
    }

    fn skipBlankLines(self: *Parser) void {
        while (!self.atEnd()) {
            self.skipSpaces();
            if (!self.consumeByte('\n')) return;
        }
    }

    fn skipSpaces(self: *Parser) void {
        while (!self.atEnd()) {
            switch (self.peekByte()) {
                ' ', '\t', '\r' => self.index += 1,
                else => return,
            }
        }
    }

    fn atEnd(self: *const Parser) bool {
        return self.index >= self.text.len;
    }
};

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isNewline(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

const TextProperties = struct {
    payload: ?Attribute = null,

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
        const payload = fromConst(storage).payload orelse return null;
        const values = payload.cast(Attribute.ArrayAttr).?.values;
        if (std.mem.eql(u8, name, "left")) return values[0];
        if (std.mem.eql(u8, name, "right")) return values[1];
        return null;
    }

    fn getProperties(_: *const Operation, storage: *const anyopaque) ?Attribute {
        return fromConst(storage).payload;
    }

    fn setProperties(_: *Operation, storage: *anyopaque, attr: Attribute) anyerror!void {
        const array = attr.cast(Attribute.ArrayAttr) orelse return error.InvalidTestProperties;
        if (array.values.len != 2) return error.InvalidTestProperties;
        from(storage).payload = attr;
    }

    fn copyProperties(dest: *anyopaque, original: *const anyopaque) anyerror!void {
        from(dest).* = fromConst(original).*;
    }

    const model = interfaces.OperationPropertiesModel{
        .name = "test.text.properties",
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

fn registerTextProperties(context: *Context) !void {
    try context.allowUnregistered();
    _ = try context.registerOperation("test.text_properties", .{});
    try context.registerOperationInherentAttributeNames(
        "test.text_properties",
        &.{ "left", "right" },
    );
    try context.registerOperationPropertiesModel(
        "test.text_properties",
        TextProperties.model,
    );
}

test "Choir parse round-trips properties and raw shadows" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = try Context.init(allocator, Context.Limits.testing);
    defer context.deinit(allocator);
    try registerTextProperties(&context);

    const left = try context.getI64Attr(11);
    const right = try context.getI64Attr(22);
    const payload = try context.getArrayAttr(&.{ left, right });
    const raw_left = try context.getI64Attr(99);
    const note = try context.getStringAttr("kept");
    const raw_attributes = [_]NamedAttribute{
        .{ .name = "left", .value = raw_left },
        .{ .name = "debug.note", .value = note },
    };
    var state = Operation.State.init("test.text_properties", Location.getUnknown());
    state.addRawAttributes(&raw_attributes);
    try state.setPropertiesAttr(payload);
    const original = try context.createOperation(state);

    const text = try dump.operationAlloc(allocator, original);
    const parsed = try operation(&context, text);
    defer parsed.erase();
    const reparsed = try dump.operationAlloc(allocator, parsed);
    try testing.expectEqualStrings(text, reparsed);
    try testing.expect(std.mem.indexOf(u8, text, "properties([11:i64, 22:i64])") != null);
    try testing.expectEqual(
        @as(i64, 11),
        parsed.getAttr("left").?.cast(Attribute.IntegerAttr).?.value,
    );
    try testing.expectEqual(
        @as(i64, 22),
        parsed.getAttr("right").?.cast(Attribute.IntegerAttr).?.value,
    );
    try testing.expectEqual(@as(usize, 2), parsed.getRawDictionaryAttrs().len);
    try testing.expectEqual(
        @as(i64, 99),
        parsed.raw_dictionary_attrs.get("left").?.cast(Attribute.IntegerAttr).?.value,
    );
}

test "Choir parse owns source names and block argument ranges" {
    const testing = std.testing;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    var name = "arguments.choir".*;
    const text =
        \\test.container() {
        \\  ^bb0(%0: !test.é, %1: !test.ty):
        \\    test.use(%0, %1)
        \\}
        \\
    ;
    const parsed = try source(&ctx, .{ .name = &name, .text = text });
    defer parsed.erase();
    @memset(&name, '?');
    const block = parsed.getRegion(0).?.getEntryBlock().?;
    const loc = block.getArgumentLocation(1).?;
    try testing.expect(loc == .file_range);
    const range = loc.file_range;
    try testing.expectEqualStrings("arguments.choir", range.filename);
    try testing.expectEqualDeep(
        Location.FilePosition{ .byte = 40, .line = 2, .column = 22 },
        range.start,
    );
    try testing.expectEqualDeep(
        Location.FilePosition{ .byte = 52, .line = 2, .column = 34 },
        range.end,
    );
    try testing.expectEqualStrings("%1: !test.ty", text[range.start.byte..range.end.byte]);
    try testing.expectEqualStrings("arguments.choir", parsed.location.file_range.filename);
    var ops = block.getOperations();
    const user = ops.next().?;
    try testing.expectEqualStrings("arguments.choir", user.location.file_range.filename);
}

test "Choir parse convenience names an unnamed source" {
    const testing = std.testing;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    const parsed = try operation(&ctx, "  test.noop()\n");
    defer parsed.erase();
    try testing.expect(parsed.location == .file_range);
    const range = parsed.location.file_range;
    try testing.expectEqualStrings("<string>", range.filename);
    try testing.expectEqualDeep(
        Location.FilePosition{ .byte = 2, .line = 1, .column = 3 },
        range.start,
    );
    try testing.expectEqualDeep(
        Location.FilePosition{ .byte = 13, .line = 1, .column = 14 },
        range.end,
    );
}
