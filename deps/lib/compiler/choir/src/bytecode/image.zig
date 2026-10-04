const std = @import("std");
const bytecode = @import("root.zig");
const Reader = bytecode.Reader;

pub const Limits = struct { bytes: u32, entities: u32, depth: u16 };
pub const Range = struct { start: u32, count: u32 };

/// A counted sequence in the existing bytecode format, borrowing immutable bytes.
pub const Ids = struct {
    bytes: []const u8,
    count: u32,

    pub fn at(self: Ids, index: u32) ?u32 {
        if (index >= self.count) return null;
        var reader = Reader.init(self.bytes);
        for (0..index) |_| _ = reader.readULEBToU32() catch return null;
        return reader.readULEBToU32() catch null;
    }
};

pub const Operation = struct {
    name: []const u8,
    location: u32,
    parent_block: ?u32,
    results: Range,
    operands: Ids,
    attributes: []const u8,
    attribute_count: u32,
    properties: ?u32,
    successors: Ids,
    region_count: u32,
    encoded: []const u8,
};

pub const Region = struct { operation: u32, position: u32, block_count: u32 };
pub const Block = struct { region: u32, position: u32, arguments: Range, operation_count: u32 };
pub const Value = struct {
    owner: union(enum) { operation: u32, block: u32 },
    position: u32,
    type: u32,
    location: u32,
};

/// All ordinals and table records refer to this one bytecode image.
pub const View = struct {
    bytes: []const u8,
    operations: []const Operation,
    regions: []const Region,
    blocks: []const Block,
    values: []const Value,
    strings: []const []const u8,
    dialects: []const bytecode.DialectEntry,
    types: []const []const u8,
    attributes: []const []const u8,
    locations: []const []const u8,
    resources: []const bytecode.Resource,

    pub fn region(self: View, operation: u32, position: u32) ?u32 {
        for (self.regions, 0..) |item, ordinal| {
            if (item.operation == operation and item.position == position) return @intCast(ordinal);
        }
        return null;
    }

    pub fn block(self: View, region_ordinal: u32, position: u32) ?u32 {
        for (self.blocks, 0..) |item, ordinal| {
            if (item.region == region_ordinal and item.position == position) {
                return @intCast(ordinal);
            }
        }
        return null;
    }

    pub fn successor(self: View, operation: u32, position: u32) ?u32 {
        if (operation >= self.operations.len) return null;
        const op = self.operations[operation];
        const parent = op.parent_block orelse return null;
        const local = op.successors.at(position) orelse return null;
        return self.block(self.blocks[parent].region, local);
    }
};

/// Owns only lookup metadata. The caller keeps the immutable bytecode bytes alive.
pub const Index = opaque {
    pub fn create(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !*Index {
        if (bytes.len > limits.bytes) return error.ImageLimit;
        const state = try allocator.create(Data);
        state.* = .{ .allocator = allocator, .bytes = bytes, .limits = limits };
        errdefer state.destroy();
        try state.read();
        return @ptrCast(state);
    }

    pub fn destroy(self: *Index) void {
        data(self).destroy();
    }

    pub fn view(self: *const Index) View {
        const state: *const Data = @ptrCast(@alignCast(self));
        return .{
            .bytes = state.bytes,
            .operations = state.operations.items,
            .regions = state.regions.items,
            .blocks = state.blocks.items,
            .values = state.values.items,
            .strings = state.strings.items,
            .dialects = state.dialects.items,
            .types = state.types.items,
            .attributes = state.attributes.items,
            .locations = state.locations.items,
            .resources = state.resources.items,
        };
    }
};

const Data = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
    entities: u32 = 0,
    operations: std.ArrayList(Operation) = .empty,
    regions: std.ArrayList(Region) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    values: std.ArrayList(Value) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    dialects: std.ArrayList(bytecode.DialectEntry) = .empty,
    types: std.ArrayList([]const u8) = .empty,
    attributes: std.ArrayList([]const u8) = .empty,
    locations: std.ArrayList([]const u8) = .empty,
    resources: std.ArrayList(bytecode.Resource) = .empty,

    fn destroy(self: *Data) void {
        inline for (.{
            "operations", "regions",    "blocks",    "values",    "strings", "dialects",
            "types",      "attributes", "locations", "resources",
        }) |field| @field(self, field).deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn append(self: *Data, comptime field: []const u8, value: anytype) !u32 {
        if (self.entities == self.limits.entities) return error.ImageLimit;
        const list = &@field(self, field);
        const ordinal: u32 = @intCast(list.items.len);
        try list.append(self.allocator, value);
        self.entities += 1;
        return ordinal;
    }

    fn count(self: *const Data, reader: *Reader) !u32 {
        const result = try reader.readULEBToU32();
        if (result > self.limits.entities) return error.ImageLimit;
        return result;
    }

    fn read(self: *Data) !void {
        const sections = try bytecode.inspectSections(self.bytes);
        try self.readStrings(sections.strings orelse return error.MissingStrings);
        if (sections.dialects) |bytes| try self.readDialects(bytes);
        if (sections.types) |bytes| try self.readTable(bytes, "types", readType);
        if (sections.attrs) |bytes| try self.readTable(bytes, "attributes", readAttribute);
        if (sections.locs) |bytes| try self.readTable(bytes, "locations", readLocation);
        if (sections.resources) |bytes| try self.readResources(bytes);
        var reader = Reader.init(sections.module orelse return error.MissingModule);
        try self.readOperation(&reader, null, 0, 0);
        try atEnd(reader);
    }

    fn readStrings(self: *Data, bytes: []const u8) !void {
        var reader = Reader.init(bytes);
        const length = try self.count(&reader);
        for (0..length) |_| _ = try self.append("strings", try reader.readBytesWithLen());
        try atEnd(reader);
    }

    fn readDialects(self: *Data, bytes: []const u8) !void {
        var reader = Reader.init(bytes);
        const length = try self.count(&reader);
        for (0..length) |_| {
            const name = try self.string(&reader);
            _ = try self.append("dialects", bytecode.DialectEntry{
                .name = name,
                .version = try reader.readULEBToU32(),
                .flags = try reader.readULEBToU32(),
            });
        }
        try atEnd(reader);
    }

    fn readTable(
        self: *Data,
        bytes: []const u8,
        comptime field: []const u8,
        comptime parse: anytype,
    ) !void {
        var reader = Reader.init(bytes);
        const length = try self.count(&reader);
        for (0..length) |_| {
            const start = reader.offset;
            try parse(self, &reader);
            _ = try self.append(field, bytes[start..reader.offset]);
        }
        try atEnd(reader);
    }

    fn string(self: *const Data, reader: *Reader) ![]const u8 {
        return self.strings.items[try reference(reader, self.strings.items.len)];
    }

    fn readType(self: *Data, reader: *Reader) !void {
        switch (try tag(bytecode.TypeKind, reader)) {
            .builtin_scalar => {
                _ = try tag(bytecode.BuiltinScalarKind, reader);
                _ = try reader.readByte();
            },
            .dialect, .dialect_only => |kind| {
                _ = try reference(reader, self.dialects.items.len);
                if (kind == .dialect) _ = try self.string(reader);
                if (try boolean(reader)) _ = try self.string(reader);
            },
        }
    }

    fn readAttribute(self: *Data, reader: *Reader) !void {
        switch (try tag(bytecode.AttrKind, reader)) {
            .integer => {
                _ = try reader.readSLEB();
                _ = try reader.readByte();
                _ = try boolean(reader);
            },
            .float_ => {
                _ = try reader.readU64();
                _ = try reader.readByte();
            },
            .bool_ => _ = try boolean(reader),
            .string => _ = try reader.readBytesWithLen(),
            .symbol_ref => {
                _ = try reader.readBytesWithLen();
                try self.readStringsList(reader);
            },
            .string_list => try self.readStringsList(reader),
            .type_list => _ = try self.ids(reader, self.types.items.len),
            .array => _ = try self.ids(reader, self.attributes.items.len),
            .dialect => {
                _ = try reference(reader, self.dialects.items.len);
                _ = try self.string(reader);
                _ = try reader.readBytesWithLen();
            },
        }
    }

    fn readStringsList(self: *const Data, reader: *Reader) !void {
        const length = try self.count(reader);
        for (0..length) |_| _ = try reader.readBytesWithLen();
    }

    fn readLocation(self: *Data, reader: *Reader) !void {
        const previous = self.locations.items.len;
        switch (try tag(bytecode.LocationKind, reader)) {
            .unknown => {},
            .file => {
                _ = try self.string(reader);
                _ = try reader.readULEBToU32();
                _ = try reader.readULEBToU32();
            },
            .file_range => {
                _ = try self.string(reader);
                const start = try reader.readULEB();
                _ = try reader.readULEBToU32();
                _ = try reader.readULEBToU32();
                if (start > try reader.readULEB()) return error.InvalidTable;
                _ = try reader.readULEBToU32();
                _ = try reader.readULEBToU32();
            },
            .name => {
                _ = try self.string(reader);
                if (try boolean(reader)) _ = try reference(reader, previous);
            },
            .fused => _ = try self.ids(reader, previous),
            .call_site => {
                _ = try reference(reader, previous);
                _ = try reference(reader, previous);
            },
        }
    }

    fn readResources(self: *Data, bytes: []const u8) !void {
        var reader = Reader.init(bytes);
        const length = try self.count(&reader);
        for (0..length) |_| {
            var value: bytecode.Resource = undefined;
            inline for (@typeInfo(bytecode.Resource).@"struct".field_names) |field| {
                @field(value, field) = try reader.readBytesWithLen();
            }
            _ = try self.append("resources", value);
        }
        try atEnd(reader);
    }

    fn ids(self: *const Data, reader: *Reader, bound: usize) !Ids {
        const length = try self.count(reader);
        const start = reader.offset;
        for (0..length) |_| _ = try reference(reader, bound);
        return .{ .count = length, .bytes = reader.bytes[start..reader.offset] };
    }

    fn readOperation(
        self: *Data,
        reader: *Reader,
        parent: ?u32,
        blocks: u32,
        depth: u16,
    ) anyerror!void {
        if (depth > self.limits.depth) return error.ImageLimit;
        const start = reader.offset;
        const ordinal = try self.append("operations", @as(Operation, undefined));
        const name = try self.string(reader);
        const location = try reference(reader, self.locations.items.len);
        const types = try self.ids(reader, self.types.items.len);
        const operands = try self.ids(reader, self.values.items.len);
        const attributes = try self.readNamedAttributes(reader);
        const properties = if (try boolean(reader))
            try reference(reader, self.attributes.items.len)
        else
            null;
        const successors = try self.ids(reader, blocks);
        const regions = try self.count(reader);
        const results = try self.defineResults(types, ordinal, location);
        for (0..regions) |position| try self.readRegion(reader, ordinal, @intCast(position), depth);
        self.operations.items[ordinal] = .{
            .name = name,
            .location = location,
            .parent_block = parent,
            .results = results,
            .operands = operands,
            .attributes = attributes.bytes,
            .attribute_count = attributes.count,
            .properties = properties,
            .successors = successors,
            .region_count = regions,
            .encoded = reader.bytes[start..reader.offset],
        };
    }

    fn readNamedAttributes(self: *Data, reader: *Reader) !Ids {
        const length = try self.count(reader);
        const start = reader.offset;
        var previous: ?[]const u8 = null;
        for (0..length) |_| {
            const name = try self.string(reader);
            if (previous) |prior| {
                if (!std.mem.lessThan(u8, prior, name)) return error.InvalidTable;
            }
            previous = name;
            _ = try reference(reader, self.attributes.items.len);
        }
        return .{ .count = length, .bytes = reader.bytes[start..reader.offset] };
    }

    fn defineResults(self: *Data, types: Ids, operation: u32, location: u32) !Range {
        const range = Range{ .start = @intCast(self.values.items.len), .count = types.count };
        var reader = Reader.init(types.bytes);
        for (0..types.count) |position| {
            _ = try self.append("values", Value{
                .owner = .{ .operation = operation },
                .position = @intCast(position),
                .type = try reader.readULEBToU32(),
                .location = location,
            });
        }
        return range;
    }

    fn readRegion(self: *Data, reader: *Reader, operation: u32, position: u32, depth: u16) !void {
        const length = try self.count(reader);
        const ordinal = try self.append("regions", Region{
            .operation = operation,
            .position = position,
            .block_count = length,
        });
        for (0..length) |index| try self.readBlock(reader, ordinal, @intCast(index), length, depth);
    }

    fn readBlock(
        self: *Data,
        reader: *Reader,
        region: u32,
        position: u32,
        blocks: u32,
        depth: u16,
    ) !void {
        const ordinal = try self.append("blocks", @as(Block, undefined));
        const length = try self.count(reader);
        const range = Range{ .start = @intCast(self.values.items.len), .count = length };
        for (0..length) |index| {
            _ = try self.append("values", Value{
                .owner = .{ .block = ordinal },
                .position = @intCast(index),
                .type = try reference(reader, self.types.items.len),
                .location = try reference(reader, self.locations.items.len),
            });
        }
        const operations = try self.count(reader);
        self.blocks.items[ordinal] = .{
            .region = region,
            .position = position,
            .arguments = range,
            .operation_count = operations,
        };
        if (operations > 0 and depth == std.math.maxInt(u16)) return error.ImageLimit;
        for (0..operations) |_| try self.readOperation(reader, ordinal, blocks, depth + 1);
    }
};

fn reference(reader: *Reader, bound: usize) !u32 {
    const ordinal = try reader.readULEBToU32();
    if (ordinal >= bound) return error.InvalidTable;
    return ordinal;
}

fn boolean(reader: *Reader) !bool {
    return switch (try reader.readByte()) {
        0 => false,
        1 => true,
        else => error.InvalidTable,
    };
}

fn tag(comptime T: type, reader: *Reader) !T {
    return std.enums.fromInt(T, try reader.readByte()) orelse error.InvalidTable;
}

fn atEnd(reader: Reader) !void {
    if (reader.offset != reader.bytes.len) return error.InvalidTable;
}

fn data(index: *Index) *Data {
    return @ptrCast(@alignCast(index));
}

fn testBytes(allocator: std.mem.Allocator) ![]u8 {
    const ir = @import("../core/root.zig");
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try context.allowUnregistered();
    var state = ir.Operation.State.init("test.function", .getFile("test", 1, 1));
    state.addRegion();
    const root = try context.createOperation(state);
    const block = try root.getRegion(0).?.addBlock();
    const typ = try context.getDialectTypeFromNameWithKey("test.word", "32");
    const argument = try block.addArgument(typ, .getFile("argument", 2, 3));
    var child_state = ir.Operation.State.init("test.add", .getFile("operation", 4, 5));
    child_state.addOperands(&.{ argument, argument });
    child_state.addTypes(&.{typ});
    child_state.addAttributes(&.{.{ .name = "answer", .value = try context.getI64Attr(42) }});
    const child = try context.createOperation(child_state);
    try block.addOperation(child);
    const resources = [_]bytecode.Resource{.{
        .namespace = "test",
        .name = "data",
        .type_id = "bytes",
        .data = "resource",
    }};
    return bytecode.encodeModuleWithResources(allocator, root, &resources);
}

const test_limits = Limits{ .bytes = 65536, .entities = 1024, .depth = 32 };

test "bytecode image exposes immutable entities after originating Context destruction" {
    const allocator = std.testing.allocator;
    const bytes = try testBytes(allocator);
    defer allocator.free(bytes);
    const index = try Index.create(allocator, bytes, test_limits);
    defer index.destroy();
    const view = index.view();
    try std.testing.expectEqual(2, view.operations.len);
    try std.testing.expectEqual(1, view.blocks.len);
    try std.testing.expectEqual(1, view.regions.len);
    try std.testing.expectEqual(2, view.values.len);
    try std.testing.expectEqualStrings("test.function", view.operations[0].name);
    try std.testing.expectEqualStrings("test.add", view.operations[1].name);
    try std.testing.expectEqual(0, view.operations[1].parent_block.?);
    try std.testing.expectEqual(0, view.operations[1].operands.at(0).?);
    try std.testing.expectEqual(0, view.operations[1].operands.at(1).?);
    try std.testing.expectEqual(1, view.operations[1].results.start);
    try std.testing.expectEqual(0, view.region(0, 0).?);
    try std.testing.expectEqual(0, view.block(0, 0).?);
    try std.testing.expectEqualStrings("resource", view.resources[0].data);
    var location = Reader.init(view.locations[view.values[0].location]);
    try std.testing.expectEqual(
        bytecode.LocationKind.file,
        try tag(bytecode.LocationKind, &location),
    );
    try std.testing.expectEqualStrings("argument", view.strings[try location.readULEBToU32()]);
    try std.testing.expectEqual(2, try location.readULEBToU32());
    try std.testing.expectEqual(3, try location.readULEBToU32());
    var attribute = Reader.init(view.attributes[0]);
    try std.testing.expectEqual(bytecode.AttrKind.integer, try tag(bytecode.AttrKind, &attribute));
    try std.testing.expectEqual(42, try attribute.readSLEB());
}

fn allocationScenario(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const index = try Index.create(allocator, bytes, test_limits);
    defer index.destroy();
    try std.testing.expectEqual(2, index.view().operations.len);
}

test "bytecode image bounds malformed input and cleans every indexing allocation failure" {
    const allocator = std.testing.allocator;
    const bytes = try testBytes(allocator);
    defer allocator.free(bytes);
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{bytes});
    var limits = test_limits;
    limits.entities = 1;
    try std.testing.expectError(error.ImageLimit, Index.create(allocator, bytes, limits));
    limits = test_limits;
    limits.depth = 0;
    try std.testing.expectError(error.ImageLimit, Index.create(allocator, bytes, limits));
    try std.testing.expectError(
        error.InvalidSection,
        Index.create(allocator, bytes[0 .. bytes.len - 1], test_limits),
    );
}
