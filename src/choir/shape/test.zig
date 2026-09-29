const std = @import("std");
const tensor = @import("tensor.zig");
const namespace = @import("root.zig");
const Term = namespace.Term;
const Expression = namespace.Expression;
const Builder = namespace.Builder;
const Error = namespace.Error;
const constant = namespace.constant;
const fingerprint = namespace.fingerprint;

test {
    @import("test_discovery").discover(namespace);
}

test "shape family records symbolic matmul constraints" {
    var builder = try Builder.init(std.testing.allocator, "matmul");
    errdefer builder.deinit();

    const m = try builder.symbol("M");
    const k = try builder.symbol("K");
    const n = try builder.symbol("N");

    const m_expr = try builder.symbolExpression(m);
    const k_expr = try builder.symbolExpression(k);
    const n_expr = try builder.symbolExpression(n);

    _ = try builder.tensor("lhs", &.{ m_expr, k_expr });
    _ = try builder.tensor("rhs", &.{ k_expr, n_expr });
    _ = try builder.tensor("out", &.{ m_expr, n_expr });
    try builder.assumeBounds(m_expr, .{ .min = 1, .opt = 128, .max = 4096 });
    try builder.assumeBounds(k_expr, .{ .min = 1, .opt = 128, .max = 4096 });
    try builder.assumeBounds(n_expr, .{ .min = 1, .opt = 128, .max = 4096 });
    try builder.assumeDivisible(k_expr, 16);
    try builder.assertBounds(m_expr, .{ .min = 1 });

    var value = builder.finish();
    defer value.deinit();

    try std.testing.expectEqual(@as(usize, 3), value.symbols.len);
    try std.testing.expectEqual(@as(usize, 3), value.tensors.len);
    try std.testing.expectEqual(@as(usize, 4), value.assumedFactCount());
    try std.testing.expectEqual(@as(usize, 1), value.assertedFactCount());
    try std.testing.expectEqual(k, value.symbolIndex("K").?);

    const out = value.tensor("out").?;
    try std.testing.expectEqual(@as(usize, 2), out.rank());
    try std.testing.expect(out.extents[0].eql(m_expr));
    try std.testing.expect(out.extents[1].eql(n_expr));
}

test "shape family expressions compose affine extent values" {
    var builder = try Builder.init(std.testing.allocator, "flatten");
    errdefer builder.deinit();

    const n = try builder.symbol("N");
    const n_expr = try builder.symbolExpression(n);
    const four_n = try builder.scaledSymbolExpression(n, 4, 0);
    const four_n_plus_one = try builder.addExpression(four_n, builder.constantExpression(1));

    _ = try builder.tensor("input", &.{ n_expr, builder.constantExpression(4) });
    _ = try builder.tensor("flat", &.{four_n});
    try builder.assertEqual(four_n_plus_one, try builder.addExpression(four_n, builder.constantExpression(1)));

    var value = builder.finish();
    defer value.deinit();

    const flat = value.tensor("flat").?;
    try std.testing.expectEqual(@as(i64, 4), flat.extents[0].terms[0].coefficient);
    try std.testing.expectEqual(@as(usize, 1), value.assertedFactCount());
}

test "shape family validates names bounds symbols and divisors" {
    try std.testing.expectError(Error.EmptyName, Builder.init(std.testing.allocator, ""));

    var builder = try Builder.init(std.testing.allocator, "invalid");
    defer builder.deinit();

    const n = try builder.symbol("N");
    try std.testing.expectError(Error.DuplicateSymbol, builder.symbol("N"));

    const n_expr = try builder.symbolExpression(n);
    try std.testing.expectError(Error.InvalidBounds, builder.assumeBounds(n_expr, .{}));
    try std.testing.expectError(Error.InvalidBounds, builder.assumeBounds(n_expr, .{ .min = 8, .opt = 4 }));
    try std.testing.expectError(Error.InvalidDivisor, builder.assumeDivisible(n_expr, 0));
    try std.testing.expectError(Error.UnknownSymbol, builder.symbolExpression(999));
    try std.testing.expectError(Error.UnknownSymbol, builder.addExpression(n_expr, .{ .terms = &.{.{ .symbol = 999 }} }));
    try std.testing.expectError(Error.InvalidExtent, builder.tensor("bad", &.{builder.constantExpression(-1)}));
    _ = try builder.tensor("valid", &.{builder.constantExpression(1)});
    try std.testing.expectError(Error.DuplicateTensor, builder.tensor("valid", &.{builder.constantExpression(1)}));
}

test "shape family owns expression terms at storage boundaries" {
    var builder = try Builder.init(std.testing.allocator, "ownership");
    errdefer builder.deinit();

    const n = try builder.symbol("N");
    var borrowed_terms = [_]Term{.{ .symbol = n, .coefficient = 2 }};
    const borrowed = Expression{ .constant = 3, .terms = &borrowed_terms };
    _ = try builder.tensor("scaled", &.{borrowed});
    try builder.assertEqual(borrowed, builder.constantExpression(7));

    var value = builder.finish();
    defer value.deinit();

    borrowed_terms[0].coefficient = 99;

    const scaled = value.tensor("scaled").?;
    try std.testing.expectEqual(@as(i64, 2), scaled.extents[0].terms[0].coefficient);
    switch (value.facts[0].predicate) {
        .equal => |equal| try std.testing.expectEqual(@as(i64, 2), equal.lhs.terms[0].coefficient),
        else => return error.UnexpectedPredicate,
    }
}

test "shape family fingerprint is stable and semantic" {
    var first_builder = try Builder.init(std.testing.allocator, "matmul");
    errdefer first_builder.deinit();
    const first_m = try first_builder.symbol("M");
    const first_n = try first_builder.symbol("N");
    const first_m_expr = try first_builder.symbolExpression(first_m);
    const first_n_expr = try first_builder.symbolExpression(first_n);
    _ = try first_builder.tensor("out", &.{ first_m_expr, first_n_expr });
    try first_builder.assumeBounds(first_n_expr, .{ .min = 1, .max = 4096 });
    var first = first_builder.finish();
    defer first.deinit();

    var same_builder = try Builder.init(std.testing.allocator, "matmul");
    errdefer same_builder.deinit();
    const same_m = try same_builder.symbol("M");
    const same_n = try same_builder.symbol("N");
    const same_m_expr = try same_builder.symbolExpression(same_m);
    const same_n_expr = try same_builder.symbolExpression(same_n);
    _ = try same_builder.tensor("out", &.{ same_m_expr, same_n_expr });
    try same_builder.assumeBounds(same_n_expr, .{ .min = 1, .max = 4096 });
    var same = same_builder.finish();
    defer same.deinit();

    var changed_builder = try Builder.init(std.testing.allocator, "matmul");
    errdefer changed_builder.deinit();
    const changed_m = try changed_builder.symbol("M");
    const changed_n = try changed_builder.symbol("N");
    const changed_m_expr = try changed_builder.symbolExpression(changed_m);
    const changed_n_expr = try changed_builder.symbolExpression(changed_n);
    _ = try changed_builder.tensor("out", &.{ changed_m_expr, changed_n_expr });
    try changed_builder.assumeBounds(changed_n_expr, .{ .min = 1, .max = 2048 });
    var changed = changed_builder.finish();
    defer changed.deinit();

    try std.testing.expectEqual(fingerprint(first), fingerprint(same));
    try std.testing.expect(fingerprint(first) != fingerprint(changed));
}

test "accy choir shape declaration coverage" {
    std.testing.refAllDecls(namespace);
}
