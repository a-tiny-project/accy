const std = @import("std");
const alloc_arena = @import("alloc_arena");
const egraph = @import("root.zig");
const ir = @import("../core/root.zig");
const rewrite = ir.rewrite;
const dialects = @import("../dialects/root.zig");
const test_support = @import("../dialects/fixture/root.zig");
const ClassId = egraph.ClassId;
const Extraction = egraph.Extraction;
const Graph = egraph.Graph;
const Node = egraph.Node;
const RewriteContext = egraph.RewriteContext;
const RewriteSet = egraph.RewriteSet;
const Scalar = egraph.Scalar;
const TypeClass = egraph.TypeClass;
test {
    std.testing.refAllDecls(egraph.node);
    std.testing.refAllDecls(egraph.graph);
    std.testing.refAllDecls(egraph.rules);
    std.testing.refAllDecls(egraph.pattern);
    std.testing.refAllDecls(egraph.extract);
}

fn buildTestContext(allocator: std.mem.Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try test_support.registerTestDialect(&ctx);
    _ = try ctx.registerOperation("test.constant", .{});
    _ = try ctx.registerOperation("test.binary", .{ .is_commutative = true });
    return ctx;
}

const EGraphProperties = struct {
    payload: ?ir.Attribute = null,

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

    fn get(_: *const ir.Operation, storage: *const anyopaque, name: []const u8) ?ir.Attribute {
        const payload = fromConst(storage).payload orelse return null;
        const values = payload.cast(ir.Attribute.ArrayAttr).?.values;
        if (std.mem.eql(u8, name, "left")) return values[0];
        if (std.mem.eql(u8, name, "right")) return values[1];
        return null;
    }

    fn getProperties(_: *const ir.Operation, storage: *const anyopaque) ?ir.Attribute {
        return fromConst(storage).payload;
    }

    fn setProperties(_: *ir.Operation, storage: *anyopaque, attr: ir.Attribute) anyerror!void {
        const array = attr.cast(ir.Attribute.ArrayAttr) orelse return error.InvalidTestProperties;
        if (array.values.len != 2) return error.InvalidTestProperties;
        from(storage).payload = attr;
    }

    fn copyProperties(dest: *anyopaque, source: *const anyopaque) anyerror!void {
        from(dest).* = fromConst(source).*;
    }

    const model = ir.OperationPropertiesModel{
        .name = "test.egraph.properties",
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

fn registerEGraphProperties(context: *ir.Context) !void {
    _ = try context.registerOperation("test.egraph_properties", .{});
    try context.registerOperationInherentAttributeNames(
        "test.egraph_properties",
        &.{ "left", "right" },
    );
    try context.registerOperationPropertiesModel(
        "test.egraph_properties",
        EGraphProperties.model,
    );
}

test "egraph canonical dedup retains the first storage witness" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    var context = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer context.deinit(arena.allocator());

    const visible = try context.getI64Attr(11);
    const first_raw = try context.getI64Attr(99);
    const second_raw = try context.getI64Attr(100);
    const first_properties = try context.getI64Attr(7);
    const second_properties = try context.getI64Attr(8);
    var canonical = [_]ir.NamedAttribute{.{ .name = "value", .value = visible }};
    var first_storage = [_]ir.NamedAttribute{.{ .name = "value", .value = first_raw }};
    var second_storage = [_]ir.NamedAttribute{.{ .name = "value", .value = second_raw }};
    const first = Node{
        .kind = .operation,
        .op_name = "test.canonical",
        .attributes = &canonical,
        .raw_attributes = &first_storage,
        .properties = first_properties,
    };
    const second = Node{
        .kind = .operation,
        .op_name = "test.canonical",
        .attributes = &canonical,
        .raw_attributes = &second_storage,
        .properties = second_properties,
    };

    var graph = Graph.init(testing.allocator);
    defer graph.deinit();
    const first_class = try graph.addNode(&first);
    const second_class = try graph.addNode(&second);
    try testing.expect(first_class.eql(second_class));
    const retained = graph.nodes(first_class);
    try testing.expectEqual(@as(usize, 1), retained.len);
    try testing.expect(retained[0].properties.?.eql(first_properties));
    try testing.expect(retained[0].raw_attributes[0].value.eql(first_raw));
}

test "egraph extraction refuses unqualified properties and preserves source shadows" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var context = try buildTestContext(allocator);
    defer context.deinit(allocator);
    try registerEGraphProperties(&context);

    const location = ir.Location.getUnknown();
    const result_type = try test_support.TestDialect.getI64Type(&context);
    const left = try context.getI64Attr(11);
    const right = try context.getI64Attr(22);
    const payload = try context.getArrayAttr(&.{ left, right });
    const raw_left = try context.getI64Attr(99);
    const note = try context.getStringAttr("kept");
    const raw_attributes = [_]ir.NamedAttribute{
        .{ .name = "left", .value = raw_left },
        .{ .name = "debug.note", .value = note },
    };
    var source_state = ir.Operation.State.init("test.egraph_properties", location);
    source_state.addTypes(&.{result_type});
    source_state.addRawAttributes(&raw_attributes);
    try source_state.setPropertiesAttr(payload);
    const source = try context.createOperation(source_state);

    const module = try test_support.TestDialect.ModuleOp.create(&context, location);
    const block = module.getBodyBlock();
    try block.addOperation(source);
    const terminator = try test_support.TestDialect.ReturnOp.create(
        &context,
        location,
        &.{source.getResult(0).?},
    );
    try block.addOperation(terminator.op);

    var graph = Graph.init(allocator);
    defer graph.deinit();
    const class = try graph.addOperation(source, &.{}, 1, 0);
    var extraction = try Extraction.init(allocator, &graph, .{});
    defer extraction.deinit();
    extraction.analyze();
    var rewriter = rewrite.PatternRewriter.init(allocator, &context);
    defer rewriter.deinit();
    const result = try extraction.materialize(
        &rewriter,
        class,
        terminator.op,
        0,
        source.getResult(0).?,
    );
    try testing.expect(result == null);
    const materialized = source;

    try testing.expectEqual(
        @as(i64, 11),
        materialized.getAttr("left").?.cast(ir.Attribute.IntegerAttr).?.value,
    );
    try testing.expectEqual(
        @as(i64, 22),
        materialized.getAttr("right").?.cast(ir.Attribute.IntegerAttr).?.value,
    );
    try testing.expectEqual(@as(usize, 2), materialized.getRawDictionaryAttrs().len);
    try testing.expectEqual(
        @as(i64, 99),
        materialized.raw_dictionary_attrs.get("left").?.cast(ir.Attribute.IntegerAttr).?.value,
    );
    try testing.expectEqualStrings(
        "kept",
        materialized.getAttrAs(ir.Attribute.StringAttr, "debug.note").?.value,
    );
}
