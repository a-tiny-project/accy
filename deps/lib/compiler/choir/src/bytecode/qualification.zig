const std = @import("std");
const ir = @import("../core/root.zig");
const bytecode = @import("root.zig");

pub const Limits = struct {
    operations: u32,
    entities: u32,
    fields: u32,
    depth: u16,
};

/// Encode with the bytecode owner, then compare every supported semantic field.
/// The caller owns and configures an independent decoding Context.
pub fn encode(
    allocator: std.mem.Allocator,
    source: *ir.Operation,
    resources: []const bytecode.Resource,
    decode_context: *ir.Context,
    limits: Limits,
) ![]u8 {
    if (source.context == decode_context) return error.IsolatedDecodeRequired;
    const ordered = try sortedResources(allocator, resources, limits);
    defer allocator.free(ordered);
    try compare(allocator, source, source, ordered, ordered, limits);
    const bytes = bytecode.encodeModuleWithResources(allocator, source, ordered) catch |err| {
        return encodingError(err);
    };
    errdefer allocator.free(bytes);
    var decoded = bytecode.decodeModule(allocator, decode_context, bytes) catch |err| {
        return encodingError(err);
    };
    defer decoded.deinit();
    try compare(allocator, source, decoded.module, ordered, decoded.resources, limits);
    return bytes;
}

fn sortedResources(
    allocator: std.mem.Allocator,
    resources: []const bytecode.Resource,
    limits: Limits,
) ![]bytecode.Resource {
    if (resources.len > limits.fields) return error.UnencodableProduct;
    const copy = try allocator.dupe(bytecode.Resource, resources);
    errdefer allocator.free(copy);
    std.mem.sort(bytecode.Resource, copy, {}, resourceLess);
    for (copy, 0..) |item, index| {
        if (index == 0) continue;
        if (!resourceLess({}, copy[index - 1], item)) return error.UnencodableProduct;
    }
    return copy;
}

fn resourceLess(_: void, first: bytecode.Resource, second: bytecode.Resource) bool {
    const namespace = std.mem.order(u8, first.namespace, second.namespace);
    if (namespace != .eq) return namespace == .lt;
    return std.mem.lessThan(u8, first.name, second.name);
}

fn encodingError(err: anyerror) anyerror {
    return if (err == error.OutOfMemory) err else error.UnencodableProduct;
}

pub fn compare(
    allocator: std.mem.Allocator,
    source: *ir.Operation,
    decoded: *ir.Operation,
    source_resources: []const bytecode.Resource,
    decoded_resources: []const bytecode.Resource,
    limits: Limits,
) !void {
    var before = try Tree.collect(allocator, source, limits);
    defer before.deinit();
    var after = try Tree.collect(allocator, decoded, limits);
    defer after.deinit();
    if (before.operations.items.len != after.operations.items.len or
        before.blocks.items.len != after.blocks.items.len or
        before.values.items.len != after.values.items.len) return error.UnencodableProduct;
    var fields = Fields{ .allocator = allocator, .limits = limits };
    defer fields.tasks.deinit(allocator);
    for (before.operations.items, after.operations.items) |first, second| {
        try compareOperation(&fields, &before, &after, first, second);
    }
    for (before.blocks.items, after.blocks.items) |first, second| {
        try compareBlock(&fields, first, second);
    }
    try fields.drain();
    try compareResources(source_resources, decoded_resources);
}

const Tree = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    root: *ir.Operation,
    operations: std.ArrayListUnmanaged(*ir.Operation) = .empty,
    blocks: std.ArrayListUnmanaged(*ir.Block) = .empty,
    values: std.ArrayListUnmanaged(*ir.Value) = .empty,

    fn collect(allocator: std.mem.Allocator, root: *ir.Operation, limits: Limits) !Tree {
        var result = Tree{ .allocator = allocator, .limits = limits, .root = root };
        errdefer result.deinit();
        _ = try root.walk(.{ .order = .pre_order }, &result, visit);
        return result;
    }

    fn deinit(self: *Tree) void {
        self.operations.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    fn visit(self: *Tree, op: *ir.Operation) !ir.WalkResult {
        if (self.operations.items.len == self.limits.operations) return error.UnencodableProduct;
        try self.validateDepth(op);
        try validateOperationStorage(op);
        try self.operations.append(self.allocator, op);
        for (op.results.items) |*value| try self.addValue(value);
        for (op.regions.items) |*region| {
            var count: usize = 0;
            var blocks = region.getBlocks();
            while (blocks.next()) |block| {
                if (self.blocks.items.len == self.limits.entities) return error.UnencodableProduct;
                try self.blocks.append(self.allocator, block);
                try validateBlockStorage(block);
                for (block.arguments.items) |value| try self.addValue(value);
                count += 1;
            }
            if (count != region.blocks.size) return error.UnencodableProduct;
        }
        return .advance;
    }

    fn validateDepth(self: *const Tree, op: *ir.Operation) !void {
        var current = op;
        var depth: usize = 0;
        while (current != self.root) : (depth += 1) {
            if (depth == self.limits.depth) return error.UnencodableProduct;
            current = current.getParentOp() orelse return error.UnencodableProduct;
        }
    }

    fn addValue(self: *Tree, value: *ir.Value) !void {
        if (self.values.items.len == self.limits.entities) return error.UnencodableProduct;
        try self.values.append(self.allocator, value);
    }

    fn valueOrdinal(self: *const Tree, value: *const ir.Value) !usize {
        for (self.values.items, 0..) |candidate, ordinal| {
            if (candidate == value) return ordinal;
        }
        return error.UnboundProductInput;
    }

    fn blockOrdinal(self: *const Tree, block: ?*const ir.Block) !?usize {
        const expected = block orelse return null;
        for (self.blocks.items, 0..) |candidate, ordinal| {
            if (candidate == expected) return ordinal;
        }
        return error.UnboundProductInput;
    }
};

fn validateOperationStorage(op: *ir.Operation) !void {
    if (op.operand_values.len != op.operands.items.len or
        op.result_types.len != op.results.items.len) return error.UnencodableProduct;
    for (op.operands.items, op.operand_values, 0..) |operand, value, index| {
        if (operand.value != value or operand.operand_number != index or
            operand.owner != @as(*anyopaque, @ptrCast(op))) return error.UnencodableProduct;
        if (operand.operand_value_slot != &op.operand_values[index]) {
            return error.UnencodableProduct;
        }
    }
    for (op.results.items, op.result_types, 0..) |value, typ, index| {
        if (!value.type.eql(typ) or value.kind != .op_result) return error.UnencodableProduct;
        const info = value.kind.op_result;
        if (info.result_number != index or info.owner != @as(*anyopaque, @ptrCast(op))) {
            return error.UnencodableProduct;
        }
    }
}

fn validateBlockStorage(block: *ir.Block) !void {
    if (block.arguments.items.len != block.argument_locations.items.len) {
        return error.UnencodableProduct;
    }
    for (block.arguments.items, 0..) |argument, index| {
        if (argument.kind != .block_argument) return error.UnencodableProduct;
        const info = argument.kind.block_argument;
        if (info.arg_number != index or info.owner != @as(*anyopaque, @ptrCast(block))) {
            return error.UnencodableProduct;
        }
    }
}

fn compareOperation(
    fields: *Fields,
    before: *const Tree,
    after: *const Tree,
    first: *ir.Operation,
    second: *ir.Operation,
) !void {
    try equalBytes(first.name.name, second.name.name);
    if (first.operands.items.len != second.operands.items.len or
        first.results.items.len != second.results.items.len or
        first.regions.items.len != second.regions.items.len or
        first.successors.items.len != second.successors.items.len) return error.UnencodableProduct;
    try fields.push(.{ .location = .{ .first = first.location, .second = second.location } });
    for (first.results.items, second.results.items) |a, b| try equalType(a.type, b.type);
    for (first.operands.items, second.operands.items) |a, b| {
        if (try before.valueOrdinal(a.value) != try after.valueOrdinal(b.value)) {
            return error.UnencodableProduct;
        }
        try equalType(a.value.type, b.value.type);
    }
    for (first.successors.items, second.successors.items) |a, b| {
        if (try before.blockOrdinal(a) != try after.blockOrdinal(b)) {
            return error.UnencodableProduct;
        }
    }
    if (first != before.operations.items[0]) {
        const source_parent = try before.blockOrdinal(first.parent_block);
        const decoded_parent = try after.blockOrdinal(second.parent_block);
        if (source_parent != decoded_parent) return error.UnencodableProduct;
    }
    for (first.regions.items, second.regions.items) |*a, *b| {
        if (a.blocks.size != b.blocks.size) return error.UnencodableProduct;
        if (try before.blockOrdinal(a.blocks.head) != try after.blockOrdinal(b.blocks.head)) {
            return error.UnencodableProduct;
        }
    }
    try compareDictionary(fields, first.getRawDictionaryAttrs(), second.getRawDictionaryAttrs());
    try compareProperties(fields, first, second);
}

fn compareBlock(fields: *Fields, first: *ir.Block, second: *ir.Block) !void {
    if (first.arguments.items.len != second.arguments.items.len) return error.UnencodableProduct;
    if (first.argument_locations.items.len != first.arguments.items.len or
        second.argument_locations.items.len != second.arguments.items.len)
    {
        return error.UnencodableProduct;
    }
    for (first.arguments.items, second.arguments.items, 0..) |a, b, index| {
        try equalType(a.type, b.type);
        try fields.push(.{ .location = .{
            .first = first.argument_locations.items[index],
            .second = second.argument_locations.items[index],
        } });
    }
}

fn compareDictionary(
    fields: *Fields,
    first: []const ir.NamedAttribute,
    second: []const ir.NamedAttribute,
) !void {
    if (first.len != second.len) return error.UnencodableProduct;
    for (first, second) |a, b| {
        try equalBytes(a.name, b.name);
        try fields.push(.{ .attribute = .{ .first = a.value, .second = b.value } });
    }
}

fn compareProperties(fields: *Fields, first: *ir.Operation, second: *ir.Operation) !void {
    const model = first.properties.model orelse {
        if (second.properties.model != null) return error.UnencodableProduct;
        return;
    };
    const decoded_model = second.properties.model orelse return error.UnencodableProduct;
    if (model.serialization != .single_attribute or
        decoded_model.serialization != .single_attribute) return error.UnencodableProduct;
    try equalBytes(model.name, decoded_model.name);
    const original = (first.getPropertiesAsAttr() catch return error.UnencodableProduct) orelse {
        if (try second.getPropertiesAsAttr() != null) return error.UnencodableProduct;
        return;
    };
    const decoded = (second.getPropertiesAsAttr() catch return error.UnencodableProduct) orelse {
        return error.UnencodableProduct;
    };
    try fields.push(.{ .attribute = .{ .first = original, .second = decoded } });
}

fn equalBytes(first: []const u8, second: []const u8) !void {
    if (!std.mem.eql(u8, first, second)) return error.UnencodableProduct;
}

fn equalType(first: ir.Type, second: ir.Type) !void {
    const a = first.getDialectStorage() orelse return error.UnencodableProduct;
    const b = second.getDialectStorage() orelse return error.UnencodableProduct;
    comptime std.debug.assert(@typeInfo(ir.Type.DialectTypeStorage).@"struct".field_names.len == 5);
    try equalBytes(a.name, b.name);
    try equalBytes(a.param_key, b.param_key);
}

fn compareResources(first: []const bytecode.Resource, second: []const bytecode.Resource) !void {
    if (first.len != second.len) return error.UnencodableProduct;
    for (first, second) |a, b| {
        inline for (@typeInfo(bytecode.Resource).@"struct".field_names) |field| {
            try equalBytes(@field(a, field), @field(b, field));
        }
    }
}

fn Pair(comptime T: type) type {
    return struct { first: T, second: T, depth: u16 = 0 };
}

const Task = union(enum) {
    attribute: Pair(ir.Attribute),
    location: Pair(ir.Location),
};

const Fields = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    tasks: std.ArrayListUnmanaged(Task) = .empty,

    fn push(self: *Fields, task: Task) !void {
        const depth = switch (task) {
            inline else => |pair| pair.depth,
        };
        if (self.tasks.items.len == self.limits.fields or depth > self.limits.depth) {
            return error.UnencodableProduct;
        }
        try self.tasks.append(self.allocator, task);
    }

    fn drain(self: *Fields) !void {
        var index: usize = 0;
        while (index < self.tasks.items.len) : (index += 1) {
            switch (self.tasks.items[index]) {
                .attribute => |pair| try self.attribute(pair),
                .location => |pair| try self.location(pair),
            }
        }
    }

    fn attribute(self: *Fields, pair: Pair(ir.Attribute)) !void {
        const first = pair.first;
        const second = pair.second;
        try equalBytes(first.abstract.name, second.abstract.name);
        inline for (.{
            ir.Attribute.IntegerAttr,  ir.Attribute.FloatAttr,     ir.Attribute.BoolAttr,
            ir.Attribute.StringAttr,   ir.Attribute.SymbolRefAttr, ir.Attribute.StringListAttr,
            ir.Attribute.TypeListAttr, ir.Attribute.ArrayAttr,
        }) |T| {
            if (first.cast(T)) |a| {
                const b = second.cast(T) orelse return error.UnencodableProduct;
                try self.attributeFields(T, a, b, pair.depth);
                return;
            }
        }
        const a = first.cast(ir.Attribute.DialectAttr) orelse return error.UnencodableProduct;
        const b = second.cast(ir.Attribute.DialectAttr) orelse return error.UnencodableProduct;
        try self.attributeFields(ir.Attribute.DialectAttr, a, b, pair.depth);
    }

    fn attributeFields(
        self: *Fields,
        comptime T: type,
        first: *const T,
        second: *const T,
        depth: u16,
    ) !void {
        inline for (@typeInfo(T).@"struct".field_names) |field| {
            if (comptime std.mem.eql(u8, field, "context")) continue;
            const a = @field(first, field);
            const b = @field(second, field);
            const Field = @TypeOf(a);
            if (Field == []const u8) {
                try equalBytes(a, b);
            } else if (Field == f64) {
                if (@as(u64, @bitCast(a)) != @as(u64, @bitCast(b))) return error.UnencodableProduct;
            } else if (Field == []const ir.Attribute or Field == []const ir.Type or
                Field == []const []const u8)
            {
                if (a.len != b.len) return error.UnencodableProduct;
                for (a, b) |x, y| {
                    if (Field == []const ir.Attribute) {
                        if (depth == std.math.maxInt(u16)) return error.UnencodableProduct;
                        try self.push(.{ .attribute = .{
                            .first = x,
                            .second = y,
                            .depth = depth + 1,
                        } });
                    } else if (Field == []const ir.Type) {
                        try equalType(x, y);
                    } else try equalBytes(x, y);
                }
            } else {
                switch (@typeInfo(Field)) {
                    .int, .bool => if (a != b) return error.UnencodableProduct,
                    else => @compileError("classify the new attribute field for complete capture"),
                }
            }
        }
    }

    fn location(self: *Fields, pair: Pair(ir.Location)) !void {
        const a = pair.first;
        const b = pair.second;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.UnencodableProduct;
        switch (a) {
            .unknown => {},
            .file => |file| {
                try equalBytes(file.filename, b.file.filename);
                if (file.line != b.file.line or file.column != b.file.column) {
                    return error.UnencodableProduct;
                }
            },
            .file_range => |range| {
                try equalBytes(range.filename, b.file_range.filename);
                if (!std.meta.eql(range.start, b.file_range.start) or
                    !std.meta.eql(range.end, b.file_range.end)) return error.UnencodableProduct;
            },
            .name => |name| {
                try equalBytes(name.name, b.name.name);
                if (name.child) |child| {
                    const other = b.name.child orelse return error.UnencodableProduct;
                    try self.childLocation(child.*, other.*, pair.depth);
                } else if (b.name.child != null) return error.UnencodableProduct;
            },
            .fused => |fused| {
                if (fused.metadata != null or b.fused.metadata != null or
                    fused.locations.len != b.fused.locations.len) return error.UnencodableProduct;
                for (fused.locations, b.fused.locations) |x, y| {
                    try self.childLocation(x, y, pair.depth);
                }
            },
            .call_site => |site| {
                try self.childLocation(site.callee.*, b.call_site.callee.*, pair.depth);
                try self.childLocation(site.caller.*, b.call_site.caller.*, pair.depth);
            },
        }
    }

    fn childLocation(self: *Fields, first: ir.Location, second: ir.Location, depth: u16) !void {
        if (depth == std.math.maxInt(u16)) return error.UnencodableProduct;
        try self.push(.{ .location = .{ .first = first, .second = second, .depth = depth + 1 } });
    }
};

const test_limits = Limits{ .operations = 100, .entities = 100, .fields = 1000, .depth = 32 };

fn testContext(allocator: std.mem.Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try ctx.allowUnregistered();
    return ctx;
}

fn testModule(ctx: *ir.Context) !*ir.Operation {
    var state = ir.Operation.State.init("test.module", .getFile("source", 2, 3));
    state.addRegion();
    const module = try ctx.createOperation(state);
    const block = try module.getRegion(0).?.addBlock();
    const typ = try ctx.getDialectTypeFromNameWithKey("test.word", "32");
    const argument = try block.addArgument(typ, .getFile("argument", 4, 5));
    const float = try ctx.getF64Attr(@bitCast(@as(u64, 0x7ff8000000000042)));
    const text = try ctx.getStringAttr("owned bytes");
    const array = try ctx.getArrayAttr(&.{ float, text });
    var operation = ir.Operation.State.init("test.use", .getFile("use", 7, 8));
    operation.addOperands(&.{argument});
    operation.addTypes(&.{typ});
    operation.addAttributes(&.{.{ .name = "payload", .value = array }});
    const child = try ctx.createOperation(operation);
    try block.addOperation(child);
    return module;
}

test "bytecode qualification compares block argument locations and resource bytes" {
    const allocator = std.testing.allocator;
    var source_ctx = try testContext(allocator);
    defer source_ctx.deinit(allocator);
    var decode_ctx = try testContext(allocator);
    defer decode_ctx.deinit(allocator);
    const source = try testModule(&source_ctx);
    const resources = [_]bytecode.Resource{.{
        .namespace = "test",
        .name = "resource",
        .type_id = "bytes/v1",
        .data = "original",
    }};
    const bytes = try encode(allocator, source, &resources, &decode_ctx, test_limits);
    defer allocator.free(bytes);
    var decoded = try bytecode.decodeModule(allocator, &decode_ctx, bytes);
    defer decoded.deinit();
    try compare(allocator, source, decoded.module, &resources, decoded.resources, test_limits);
    const block = decoded.module.getRegion(0).?.getEntryBlock().?;
    const previous = block.getArgumentLocation(0).?;
    block.setArgumentLocation(0, .getFile("changed", 1, 1));
    try std.testing.expectError(error.UnencodableProduct, compare(
        allocator,
        source,
        decoded.module,
        &resources,
        decoded.resources,
        test_limits,
    ));
    block.setArgumentLocation(0, previous);
    var changed = resources;
    changed[0].data = "changed";
    try std.testing.expectError(error.UnencodableProduct, compare(
        allocator,
        source,
        decoded.module,
        &changed,
        decoded.resources,
        test_limits,
    ));
}

test "bytecode qualification refuses fused metadata that ordinary round trips omit" {
    const allocator = std.testing.allocator;
    var source_ctx = try testContext(allocator);
    defer source_ctx.deinit(allocator);
    var decode_ctx = try testContext(allocator);
    defer decode_ctx.deinit(allocator);
    const source = try testModule(&source_ctx);
    const metadata: u32 = 42;
    source.location = .{ .fused = .{ .locations = &.{.unknown}, .metadata = &metadata } };
    const bytes = try bytecode.encodeModule(allocator, source);
    defer allocator.free(bytes);
    var decoded = try bytecode.decodeModule(allocator, &decode_ctx, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(null, decoded.module.location.fused.metadata);
    try std.testing.expectError(error.UnencodableProduct, encode(
        allocator,
        source,
        &.{},
        &decode_ctx,
        test_limits,
    ));
}

test "bytecode qualification refuses undeclared free values and shared decoding contexts" {
    const allocator = std.testing.allocator;
    var source_ctx = try testContext(allocator);
    defer source_ctx.deinit(allocator);
    var decode_ctx = try testContext(allocator);
    defer decode_ctx.deinit(allocator);
    const source = try testModule(&source_ctx);
    try std.testing.expectError(error.IsolatedDecodeRequired, encode(
        allocator,
        source,
        &.{},
        &source_ctx,
        test_limits,
    ));
    var operations = source.getRegion(0).?.getEntryBlock().?.getOperations();
    const child = operations.next().?;
    try std.testing.expectError(error.UnboundProductInput, encode(
        allocator,
        child,
        &.{},
        &decode_ctx,
        test_limits,
    ));
}

fn classify(
    comptime T: type,
    comptime semantic: []const []const u8,
    comptime derived: []const []const u8,
    comptime process: []const []const u8,
) void {
    comptime {
        const fields = @typeInfo(T).@"struct".field_names;
        if (fields.len != semantic.len + derived.len + process.len) {
            @compileError("classify every owner field before qualifying bytecode capture");
        }
        std.debug.assert(fields.len <= 64);
        const Field = std.meta.FieldEnum(T);
        var seen: u64 = 0;
        for (.{ semantic, derived, process }) |group| {
            for (group) |name| {
                const ordinal: u6 = @intCast(@backingInt(@field(Field, name)));
                const bit = @as(u64, 1) << ordinal;
                if (seen & bit != 0) @compileError("multiply classified owner field: " ++ name);
                seen |= bit;
            }
        }
    }
}

test "bytecode qualification classifies semantic derived and process storage fields" {
    classify(ir.Operation, &.{
        "name",       "location", "operands",   "results", "raw_dictionary_attrs",
        "properties", "regions",  "successors",
    }, &.{
        "operand_values", "result_types", "parent_block", "prev_op", "next_op", "order",
    }, &.{
        "allocator",     "storage",       "operand_storage", "context", "lifecycle_state",
        "tracking_prev", "tracking_next",
    });
    classify(ir.Block, &.{
        "arguments", "argument_locations", "operations",
    }, &.{ "parent", "prev", "next", "predecessors", "op_order_valid" }, &.{ "allocator", "id" });
    classify(ir.Region, &.{"blocks"}, &.{"parent"}, &.{"allocator"});
    classify(ir.Value, &.{"type"}, &.{ "kind", "first_use" }, &.{"id"});
    classify(ir.Type, &.{"type_id"}, &.{}, &.{"impl"});
    classify(ir.Type.DialectTypeStorage, &.{ "name", "param_key" }, &.{}, &.{
        "type_info", "print_fn", "unique_id",
    });
    classify(ir.Attribute, &.{}, &.{}, &.{ "attr_id", "impl", "abstract" });
    classify(ir.OpOperand, &.{"value"}, &.{
        "owner", "operand_number", "operand_value_slot", "next_use", "back",
    }, &.{});
    classify(ir.Location.FileLocation, &.{ "filename", "line", "column" }, &.{}, &.{});
    classify(ir.Location.FilePosition, &.{ "byte", "line", "column" }, &.{}, &.{});
    classify(ir.Location.FileRangeLocation, &.{ "filename", "start", "end" }, &.{}, &.{});
    classify(ir.Location.NameLocation, &.{ "name", "child" }, &.{}, &.{});
    classify(ir.Location.FusedLocation, &.{ "locations", "metadata" }, &.{}, &.{});
    classify(ir.Location.CallSiteLocation, &.{ "callee", "caller" }, &.{}, &.{});
}

fn registerTestProperty(ctx: *ir.Context) !void {
    _ = try ctx.registerOperation("test.property", .{});
    try ctx.registerOperationInherentAttributeNames("test.property", &.{"value"});
    try ctx.registerOperationPropertiesModel("test.property", ir.singleAttributePropertiesModel(
        "test.property.storage",
        "value",
    ));
}

test "bytecode qualification preserves complete single attribute properties and raw shadows" {
    const allocator = std.testing.allocator;
    var source_ctx = try testContext(allocator);
    defer source_ctx.deinit(allocator);
    var decode_ctx = try testContext(allocator);
    defer decode_ctx.deinit(allocator);
    try registerTestProperty(&source_ctx);
    try registerTestProperty(&decode_ctx);
    var state = ir.Operation.State.init("test.property", .unknown);
    const original = try source_ctx.getI64Attr(11);
    try state.setPropertiesAttr(original);
    const shadow = try source_ctx.getI64Attr(99);
    state.addRawAttributes(&.{.{ .name = "value", .value = shadow }});
    const source = try source_ctx.createOperation(state);
    const bytes = try encode(allocator, source, &.{}, &decode_ctx, test_limits);
    defer allocator.free(bytes);
    var decoded = try bytecode.decodeModule(allocator, &decode_ctx, bytes);
    defer decoded.deinit();
    try compare(allocator, source, decoded.module, &.{}, &.{}, test_limits);
    const changed = try source_ctx.getI64Attr(12);
    try source.setPropertiesFromAttr(changed);
    try std.testing.expectError(error.UnencodableProduct, compare(
        allocator,
        source,
        decoded.module,
        &.{},
        &.{},
        test_limits,
    ));
    try std.testing.expectEqual(11, (try decoded.module.getPropertiesAsAttr()).?.cast(
        ir.Attribute.IntegerAttr,
    ).?.value);
    try std.testing.expectEqual(99, decoded.module.raw_dictionary_attrs.get("value").?.cast(
        ir.Attribute.IntegerAttr,
    ).?.value);
}

test "bytecode qualification canonicalizes resource maps and rejects duplicate identities" {
    const allocator = std.testing.allocator;
    var first_context = try testContext(allocator);
    defer first_context.deinit(allocator);
    var second_context = try testContext(allocator);
    defer second_context.deinit(allocator);
    var decode_context = try testContext(allocator);
    defer decode_context.deinit(allocator);
    const first = try testModule(&first_context);
    const second = try testModule(&second_context);
    const resources = [_]bytecode.Resource{
        .{ .namespace = "z", .name = "a", .type_id = "bytes", .data = "second" },
        .{ .namespace = "a", .name = "z", .type_id = "bytes", .data = "first" },
    };
    const reversed = [_]bytecode.Resource{ resources[1], resources[0] };
    const a = try encode(allocator, first, &resources, &decode_context, test_limits);
    defer allocator.free(a);
    const b = try encode(allocator, second, &reversed, &decode_context, test_limits);
    defer allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expectError(error.UnencodableProduct, encode(
        allocator,
        first,
        &.{ resources[0], resources[0] },
        &decode_context,
        test_limits,
    ));
}

test "bytecode qualification rejects inconsistent derived argument and operand identities" {
    const allocator = std.testing.allocator;
    var context = try testContext(allocator);
    defer context.deinit(allocator);
    var decode_context = try testContext(allocator);
    defer decode_context.deinit(allocator);
    const source = try testModule(&context);
    const block = source.getRegion(0).?.getEntryBlock().?;
    const argument = block.arguments.items[0];
    argument.kind.block_argument.arg_number = 1;
    try std.testing.expectError(error.UnencodableProduct, encode(
        allocator,
        source,
        &.{},
        &decode_context,
        test_limits,
    ));
    argument.kind.block_argument.arg_number = 0;
    var operations = block.getOperations();
    const operation = operations.next().?;
    operation.operands.items[0].operand_number = 1;
    try std.testing.expectError(error.UnencodableProduct, encode(
        allocator,
        source,
        &.{},
        &decode_context,
        test_limits,
    ));
    operation.operands.items[0].operand_number = 0;
    var limited = test_limits;
    limited.depth = 0;
    try std.testing.expectError(error.UnencodableProduct, encode(
        allocator,
        source,
        &.{},
        &decode_context,
        limited,
    ));
}
