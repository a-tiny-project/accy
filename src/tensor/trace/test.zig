const std = @import("std");
const tensor = @import("../root.zig");
const trace = @import("root.zig");

const Builder = trace.Builder;
const Type = trace.Type;
const Value = trace.Value;
const define = trace.define;
const program_mod = tensor.program;

test {
    @import("test_discovery").discover(trace.builder);
    @import("test_discovery").discover(trace.definition);
    @import("test_discovery").discover(trace.value);
    @import("test_discovery").discover(trace);
}

test "tensor trace builder records an ergonomic dense program" {
    var builder = try Builder.init(std.testing.allocator, "dense");
    defer builder.deinit();

    const x = try builder.input(.f32, .{ .m = 4, .k = 8 });
    const w = try builder.input(.f32, .{ .k = 8, .n = 3 });
    const b = try builder.input(.f32, .{ .n = 3 });
    const linear = try x.contract(w, .k);
    const out = try (try linear.add(b)).tanh();
    var program = try builder.finish(&.{out});
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 7), program.valueCount());
    try std.testing.expectEqual(@as(usize, 3), program.parameters.len);
    try tensor.types.expectExtents(&.{ 4, 3 }, program.typeOf(program.outputs[0]));
    try std.testing.expectEqualStrings("m", program.typeOf(program.outputs[0]).dims[0].name);
    try std.testing.expectEqualStrings("n", program.typeOf(program.outputs[0]).dims[1].name);
}

test "tensor trace builder replays primitive operations" {
    var source = try define(std.testing.allocator, "source", &.{
        tensor.spec(.f32, .{ .lane = 4 }),
        tensor.spec(.f32, .{ .lane = 4 }),
    }, defineBody);
    defer source.deinit();

    var builder = try Builder.init(std.testing.allocator, "replay");
    defer builder.deinit();

    const x = try builder.operation(&source.operations[0], &.{});
    const y = try builder.operation(&source.operations[1], &.{});
    const sum = try builder.operation(&source.operations[2], &.{ x, y });
    const out = try builder.operation(&source.operations[3], &.{sum});
    var replayed = try builder.finish(&.{out});
    defer replayed.deinit();

    try std.testing.expectEqual(source.operationCount(), replayed.operationCount());
    try tensor.types.expectExtents(&.{4}, replayed.typeOf(replayed.outputs[0]));
    try std.testing.expectEqual(program_mod.Kind.unary, std.meta.activeTag(
        replayed.operation(replayed.outputs[0]).kind,
    ));
}

fn defineBody(_: *Builder, args: []const Value) !Value {
    const sum = try args[0].add(args[1]);
    return try sum.tanh();
}

test "tensor define traces a comptime body function" {
    var program = try define(std.testing.allocator, "body", &.{
        tensor.spec(.f32, .{ .lane = 4 }),
        tensor.spec(.f32, .{ .lane = 4 }),
    }, defineBody);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 4), program.valueCount());
    try tensor.types.expectExtents(&.{4}, program.typeOf(program.outputs[0]));
}

test "tensor values identify structural zeros" {
    var builder = try Builder.init(std.testing.allocator, "structural_zero");
    defer builder.deinit();

    const scalar_zero = try builder.zeros(.{ .dtype = .f32, .dims = &.{} });
    const input = try builder.input(.f32, .{ .lane = 4 });
    const zero = try builder.alignTo(scalar_zero, input.ty.dims);
    const product = try zero.mul(input);
    const one = try builder.full(.f32, .{ .lane = 4 }, 1.0);

    try std.testing.expect(scalar_zero.isStructuralZero());
    try std.testing.expect(zero.isStructuralZero());
    try std.testing.expect(product.isStructuralZero());
    try std.testing.expect(!input.isStructuralZero());
    try std.testing.expect(!one.isStructuralZero());
}

test "tensor value reduces sums with canonical inits by axis name" {
    var builder = try Builder.init(std.testing.allocator, "sum_inferred_zero");
    defer builder.deinit();

    const input = try builder.input(.f32, .{ .row = 2, .col = 3 });
    const row_sum = try input.sum(.col);
    const total = try input.sum(.{ .row, .col });
    var program = try builder.finish(&.{ row_sum, total });
    defer program.deinit();

    try tensor.types.expectExtents(&.{2}, program.typeOf(program.outputs[0]));
    try tensor.types.expectExtents(&.{}, program.typeOf(program.outputs[1]));
    try std.testing.expectEqualStrings("row", program.typeOf(program.outputs[0]).dims[0].name);
}

test "tensor select validates predicate dtype and accepts scalar masks" {
    var builder = try Builder.init(std.testing.allocator, "select_predicate");
    defer builder.deinit();

    const input = try builder.input(.f32, .{ .lane = 4 });
    const other = try builder.input(.f32, .{ .lane = 4 });
    try std.testing.expectError(error.DTypeMismatch, builder.select(input, input, other));

    const threshold = try builder.scalar(.f32, 0.0);
    const one = try builder.scalar(.f32, 1.0);
    const scalar_pred = try threshold.compare(.lt, one);
    const selected = try builder.select(scalar_pred, input, other);
    try tensor.types.expectExtents(&.{4}, selected.ty);
}

test "tensor custom calls validate kernel contract fields at trace construction" {
    var builder = try Builder.init(std.testing.allocator, "custom_call_contract");
    defer builder.deinit();

    const input = try builder.input(.f32, .{ .lane = 4 });
    try std.testing.expectError(
        error.InvalidCustomCallContract,
        builder.customCall("", 1, &.{input}, input.ty),
    );
    try std.testing.expectError(
        error.InvalidCustomCallContract,
        builder.customCall("accy.custom.scale", 0, &.{input}, input.ty),
    );
}

test "tensor custom calls align arity with kernel calls" {
    var builder = try Builder.init(std.testing.allocator, "custom_call_arity");
    defer builder.deinit();

    const result_ty = try Type.init(builder.arena.allocator(), .f32, &.{
        .{ .name = "lane", .extent = 4 },
    });
    const generated = try builder.customCall("accy.custom.generate", 1, &.{}, result_ty);
    try std.testing.expectEqual(
        @as(usize, 0),
        builder.operations.items[generated.id.index].kind.custom_call.operands.len,
    );

    const a = try builder.input(.f32, .{ .lane = 4 });
    const b = try builder.input(.f32, .{ .lane = 4 });
    const c = try builder.input(.f32, .{ .lane = 4 });
    const d = try builder.input(.f32, .{ .lane = 4 });
    const e = try builder.input(.f32, .{ .lane = 4 });
    try std.testing.expectError(
        error.UnsupportedCustomCallArity,
        builder.customCall("accy.custom.too_many", 1, &.{ a, b, c, d, e }, a.ty),
    );
}

test "accy tensor trace declaration coverage" {
    std.testing.refAllDecls(trace.builder);
    std.testing.refAllDecls(trace.definition);
    std.testing.refAllDecls(trace.value);
    std.testing.refAllDecls(trace);
}
