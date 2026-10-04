const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const rewrite = ir.rewrite;
const arith = @import("root.zig");

const ArithDialect = arith.ArithDialect;
const CmpPredicate = arith.CmpPredicate;
const ScalarClass = arith.ScalarClass;
const ScalarKind = arith.ScalarKind;
const ScalarSet = arith.ScalarSet;
const type_names = arith.type_names;
const scalarBitWidth = arith.scalarBitWidth;
const scalarDescriptor = arith.scalarDescriptor;
const scalarKindFromTypeName = arith.scalarKindFromTypeName;
const scalarKindFromSuffix = arith.scalarKindFromSuffix;
const scalarKindIsInteger = arith.scalarKindIsInteger;
const scalarKindIsSignedInteger = arith.scalarKindIsSignedInteger;
const scalarKindIsUnsignedInteger = arith.scalarKindIsUnsignedInteger;
const scalarKindIsFloat = arith.scalarKindIsFloat;
const vectorTypeName = arith.vectorTypeName;
const vectorTypeNameForElement = arith.vectorTypeNameForElement;
const parseVectorTypeName = arith.parseVectorTypeName;

test {
    std.testing.refAllDecls(arith);
}

test "ArithDialect.ConstantOp creates integer constant" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    var const_op = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 42);

    try testing.expectEqualStrings("arith.constant", const_op.op.name.name);
    try testing.expectEqual(@as(i64, 42), const_op.getIntValue().?);
}

test "ArithDialect registers unsigned u32 scalar and vector types" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const u32_type = try ArithDialect.getU32Type(&ctx);
    const vec4_type = (try ArithDialect.getVecType(&ctx, 4, type_names.uint32)).?;

    try testing.expectEqual(ScalarKind.u32, scalarKindFromTypeName(type_names.uint32).?);
    try testing.expectEqual(ScalarKind.u32, scalarKindFromSuffix("u32").?);
    try testing.expect(scalarKindIsInteger(.u32));
    try testing.expect(!scalarKindIsFloat(.u32));
    try testing.expectEqualStrings("arith.u32", u32_type.getDialectTypeName().?);
    try testing.expectEqualStrings("arith.vec4xu32", vec4_type.getDialectTypeName().?);
    try testing.expectEqualStrings(type_names.vec4xu32, vectorTypeName(4, .u32).?);
    try testing.expectEqualStrings(type_names.vec4xu32, vectorTypeNameForElement(4, type_names.uint32).?);

    const parsed = parseVectorTypeName(type_names.vec4xu32).?;
    try testing.expectEqual(@as(u32, 4), parsed.width);
    try testing.expectEqualStrings(type_names.uint32, parsed.elem_type_name);
}

test "ArithDialect registers unsigned u64 scalar and vector types" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const u64_type = try ArithDialect.getU64Type(&ctx);
    const vec4_type = (try ArithDialect.getVecType(&ctx, 4, type_names.uint64)).?;

    try testing.expectEqual(ScalarKind.u64, scalarKindFromTypeName(type_names.uint64).?);
    try testing.expectEqual(ScalarKind.u64, scalarKindFromSuffix("u64").?);
    try testing.expect(scalarKindIsInteger(.u64));
    try testing.expect(scalarKindIsUnsignedInteger(.u64));
    try testing.expect(!scalarKindIsFloat(.u64));
    try testing.expectEqualStrings("arith.u64", u64_type.getDialectTypeName().?);
    try testing.expectEqualStrings("arith.vec4xu64", vec4_type.getDialectTypeName().?);
    try testing.expectEqualStrings(type_names.vec4xu64, vectorTypeName(4, .u64).?);
    try testing.expectEqualStrings(type_names.vec4xu64, vectorTypeNameForElement(4, type_names.uint64).?);

    const parsed = parseVectorTypeName(type_names.vec4xu64).?;
    try testing.expectEqual(@as(u32, 4), parsed.width);
    try testing.expectEqualStrings(type_names.uint64, parsed.elem_type_name);
}

test "ArithDialect registers bf16 scalar and vector types" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const bf16_type = try ArithDialect.getBf16Type(&ctx);
    const vec4_type = (try ArithDialect.getVecType(&ctx, 4, type_names.bfloat16)).?;

    try testing.expectEqual(ScalarKind.bf16, scalarKindFromTypeName(type_names.bfloat16).?);
    try testing.expectEqual(ScalarKind.bf16, scalarKindFromSuffix("bf16").?);
    try testing.expect(scalarKindIsFloat(.bf16));
    try testing.expectEqualStrings("arith.bf16", bf16_type.getDialectTypeName().?);
    try testing.expectEqualStrings("arith.vec4xbf16", vec4_type.getDialectTypeName().?);
    try testing.expectEqualStrings(type_names.vec4xbf16, vectorTypeName(4, .bf16).?);
    try testing.expectEqualStrings(type_names.vec4xbf16, vectorTypeNameForElement(4, type_names.bfloat16).?);

    const parsed = parseVectorTypeName(type_names.vec4xbf16).?;
    try testing.expectEqual(@as(u32, 4), parsed.width);
    try testing.expectEqualStrings(type_names.bfloat16, parsed.elem_type_name);
}

test "ArithDialect.AddOp creates addition" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 10);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 20);
    var add = try ArithDialect.AddOp.create(&ctx, loc, c1.getResult(), c2.getResult());

    try testing.expectEqualStrings("arith.add", add.op.name.name);
    try testing.expect(add.getLhs() == c1.getResult());
    try testing.expect(add.getRhs() == c2.getResult());
}

test "ArithDialect.CmpOp creates comparison" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 10);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 20);
    var cmp = try ArithDialect.CmpOp.create(&ctx, loc, .lt, c1.getResult(), c2.getResult());

    try testing.expectEqualStrings("arith.cmp", cmp.op.name.name);
    try testing.expectEqual(CmpPredicate.lt, cmp.getPredicate().?);
}

test "ArithDialect.FmaOp creates fused multiply-add" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var a = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 2.0);
    var b = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 3.0);
    var c = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 4.0);
    var fma = try ArithDialect.FmaOp.create(&ctx, loc, a.getResult(), b.getResult(), c.getResult());

    try testing.expectEqualStrings("arith.fma", fma.op.name.name);
    try testing.expect(fma.getA() == a.getResult());
    try testing.expect(fma.getB() == b.getResult());
    try testing.expect(fma.getC() == c.getResult());
}

test "ArithDialect.SqrtOp creates square root" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var input = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 4.0);
    var sqrt = try ArithDialect.SqrtOp.create(&ctx, loc, input.getResult());

    try testing.expectEqualStrings("arith.sqrt", sqrt.op.name.name);
    try testing.expect(sqrt.getInput() == input.getResult());
}

test "ArithDialect.SinOp creates sine" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var input = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 0.0);
    var sin = try ArithDialect.SinOp.create(&ctx, loc, input.getResult());

    try testing.expectEqualStrings("arith.sin", sin.op.name.name);
    try testing.expect(sin.getInput() == input.getResult());
}

test "ArithDialect.FloorOp, RoundOp, and TruncOp create rounding ops" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var input = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, -1.5);
    var floor = try ArithDialect.FloorOp.create(&ctx, loc, input.getResult());
    var round = try ArithDialect.RoundOp.create(&ctx, loc, input.getResult());
    var trunc = try ArithDialect.TruncOp.create(&ctx, loc, input.getResult());

    try testing.expectEqualStrings("arith.floor", floor.op.name.name);
    try testing.expect(floor.getInput() == input.getResult());
    try testing.expectEqualStrings("arith.round", round.op.name.name);
    try testing.expect(round.getInput() == input.getResult());
    try testing.expectEqualStrings("arith.trunc", trunc.op.name.name);
    try testing.expect(trunc.getInput() == input.getResult());
}

test "ArithDialect.Atan2Op creates arctangent with quadrant operands" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var y = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var x = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, -1.0);
    var atan2 = try ArithDialect.Atan2Op.create(&ctx, loc, y.getResult(), x.getResult());

    try testing.expectEqualStrings("arith.atan2", atan2.op.name.name);
    try testing.expect(atan2.getLhs() == y.getResult());
    try testing.expect(atan2.getRhs() == x.getResult());
    try testing.expect(atan2.getResult().type.eql(f32_type));
}

test "ArithDialect.TanhOp creates hyperbolic tangent" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var input = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 0.5);
    var tanh = try ArithDialect.TanhOp.create(&ctx, loc, input.getResult());

    try testing.expectEqualStrings("arith.tanh", tanh.op.name.name);
    try testing.expect(tanh.getInput() == input.getResult());
    try testing.expect(tanh.getResult().type.eql(f32_type));
}

test "ArithDialect.MaxOp creates elementwise maximum" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var lhs = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 3);
    var rhs = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 7);
    var max_op = try ArithDialect.MaxOp.create(&ctx, loc, lhs.getResult(), rhs.getResult());

    try testing.expectEqualStrings("arith.max", max_op.op.name.name);
    try testing.expect(max_op.getLhs() == lhs.getResult());
    try testing.expect(max_op.getRhs() == rhs.getResult());
    try testing.expect(max_op.getResult().type.eql(i32_type));
}

test "ArithDialect.MinOp creates elementwise minimum" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getScalarType(&ctx, .f64);

    var lhs = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f64_type, 1.5);
    var rhs = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f64_type, 2.5);
    var min_op = try ArithDialect.MinOp.create(&ctx, loc, lhs.getResult(), rhs.getResult());

    try testing.expectEqualStrings("arith.min", min_op.op.name.name);
    try testing.expect(min_op.getLhs() == lhs.getResult());
    try testing.expect(min_op.getRhs() == rhs.getResult());
    try testing.expect(min_op.getResult().type.eql(f64_type));
}

test "ArithDialect.AndOp creates bitwise AND" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 0xFF);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 0x0F);
    const and_op = try ArithDialect.AndOp.create(&ctx, loc, c1.getResult(), c2.getResult());

    try testing.expectEqualStrings("arith.and", and_op.op.name.name);
}

test "ArithDialect.ShlOp creates shift left" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var value = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var shift = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 4);
    const shl = try ArithDialect.ShlOp.create(&ctx, loc, value.getResult(), shift.getResult());

    try testing.expectEqualStrings("arith.shl", shl.op.name.name);
}

test "ArithDialect.UmulhiOp creates unsigned multiply high" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var lhs = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 7);
    var rhs = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 9);
    const umulhi = try ArithDialect.UmulhiOp.create(&ctx, loc, lhs.getResult(), rhs.getResult());

    try testing.expectEqualStrings("arith.umulhi", umulhi.op.name.name);
}

test "ArithDialect.BitcastOp creates bitcast" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var input = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 0x40000000);
    var bitcast = try ArithDialect.BitcastOp.create(&ctx, loc, input.getResult(), f32_type);

    try testing.expectEqualStrings("arith.bitcast", bitcast.op.name.name);
    try testing.expect(bitcast.getInput() == input.getResult());
}

test "ArithDialect.SplatOp creates vector splat" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const vec4xf32_type = try ArithDialect.getVec4xF32Type(&ctx);

    var scalar = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var splat = try ArithDialect.SplatOp.create(&ctx, loc, scalar.getResult(), vec4xf32_type);

    try testing.expectEqualStrings("arith.splat", splat.op.name.name);
    try testing.expect(splat.getInput() == scalar.getResult());
}

test "ArithDialect.ExtractOp creates vector extract" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const vec4xf32_type = try ArithDialect.getVec4xF32Type(&ctx);

    var vec_const = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32_type, 2.0);
    var extract = try ArithDialect.ExtractOp.create(&ctx, loc, vec_const.getResult(), 2, f32_type);

    try testing.expectEqualStrings("arith.extract", extract.op.name.name);
    try testing.expectEqual(@as(i64, 2), extract.getIndex().?);
    try testing.expect(extract.getVector() == vec_const.getResult());
}

test "ArithDialect.InsertOp creates vector insert" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const vec4xf32_type = try ArithDialect.getVec4xF32Type(&ctx);

    var vec_const = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32_type, 0.0);
    var scalar = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 5.0);
    var insert = try ArithDialect.InsertOp.create(&ctx, loc, vec_const.getResult(), scalar.getResult(), 1);

    try testing.expectEqualStrings("arith.insert", insert.op.name.name);
    try testing.expectEqual(@as(i64, 1), insert.getIndex().?);
    try testing.expect(insert.getVector() == vec_const.getResult());
    try testing.expect(insert.getScalar() == scalar.getResult());
}

test "ArithDialect.VecShuffleOp creates vector shuffle" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const vec4xi32_type = try ArithDialect.getVec4xI32Type(&ctx);

    var vec_const = try ArithDialect.VecConstantOp.createInt(&ctx, loc, vec4xi32_type, 1);
    const indices = [_]i64{ 3, 1, 2, 0 };
    var shuffle = try ArithDialect.VecShuffleOp.create(&ctx, loc, vec_const.getResult(), vec4xi32_type, indices[0..]);

    try testing.expectEqualStrings("arith.vec_shuffle", shuffle.op.name.name);
    try testing.expect(shuffle.getVector() == vec_const.getResult());

    var buf: [4]i64 = undefined;
    const parsed = try shuffle.getIndices(&buf);
    try testing.expectEqual(@as(usize, indices.len), parsed.len);
    for (parsed, indices) |got, expected| {
        try testing.expectEqual(expected, got);
    }
}

test "ArithDialect.AddOp creates vector addition" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const vec4xf32_type = try ArithDialect.getVec4xF32Type(&ctx);

    var v1 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32_type, 1.0);
    var v2 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32_type, 2.0);
    var add = try ArithDialect.AddOp.create(&ctx, loc, v1.getResult(), v2.getResult());

    try testing.expectEqualStrings("arith.add", add.op.name.name);
    try testing.expect(add.getLhs() == v1.getResult());
    try testing.expect(add.getRhs() == v2.getResult());
}

test "ArithDialect.MulOp creates vector multiplication" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const vec4xi32_type = try ArithDialect.getVec4xI32Type(&ctx);

    var v1 = try ArithDialect.VecConstantOp.createInt(&ctx, loc, vec4xi32_type, 3);
    var v2 = try ArithDialect.VecConstantOp.createInt(&ctx, loc, vec4xi32_type, 4);
    const mul = try ArithDialect.MulOp.create(&ctx, loc, v1.getResult(), v2.getResult());

    try testing.expectEqualStrings("arith.mul", mul.op.name.name);
}

test "ArithDialect.NegOp creates vector negation" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const vec4xf32_type = try ArithDialect.getVec4xF32Type(&ctx);

    var v = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32_type, 5.0);
    var neg = try ArithDialect.NegOp.create(&ctx, loc, v.getResult());

    try testing.expectEqualStrings("arith.neg", neg.op.name.name);
    try testing.expect(neg.getInput() == v.getResult());
}

test "ArithDialect.VecConstantOp creates vector constant" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const vec4xf32_type = try ArithDialect.getVec4xF32Type(&ctx);

    var vec_const = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32_type, 3.14);

    try testing.expectEqualStrings("arith.vec_constant", vec_const.op.name.name);
    try testing.expectEqual(@as(usize, 0), vec_const.op.getRawDictionaryAttrs().len);
    try testing.expect((try vec_const.op.getPropertiesAsAttr()).?.eql(vec_const.op.getAttr("value").?));
    const val = vec_const.getFloatValue().?;
    try testing.expect(@abs(val - 3.14) < 0.001);
}

test "ArithDialect.getVecType returns correct types" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const vec4xf32 = try ArithDialect.getVecType(&ctx, 4, type_names.float32);
    try testing.expect(vec4xf32 != null);

    const vec8xi32 = try ArithDialect.getVecType(&ctx, 8, type_names.int32);
    try testing.expect(vec8xi32 != null);

    const invalid_width = try ArithDialect.getVecType(&ctx, 3, type_names.float32);
    try testing.expect(invalid_width == null);
}

test "arith scalar and vector type schema derives names and parse facts" {
    const testing = std.testing;

    try testing.expectEqual(ScalarKind.f32, scalarKindFromTypeName(type_names.float32).?);
    try testing.expectEqual(ScalarKind.index, scalarKindFromSuffix("index").?);
    try testing.expect(scalarKindIsInteger(.i64));
    try testing.expect(scalarKindIsUnsignedInteger(.u64));
    try testing.expect(!scalarKindIsInteger(.f32));
    try testing.expect(scalarKindIsFloat(.bf16));
    try testing.expect(scalarKindIsFloat(.f64));
    try testing.expectEqualStrings(type_names.vec4xf32, vectorTypeName(4, .f32).?);
    try testing.expectEqualStrings(type_names.vec8xindex, vectorTypeNameForElement(8, type_names.index).?);
    try testing.expect(vectorTypeName(16, .f64) == null);

    const parsed = parseVectorTypeName(type_names.vec8xi32) orelse return error.TestExpectedVectorType;
    try testing.expectEqual(@as(u32, 8), parsed.width);
    try testing.expectEqualStrings(type_names.int32, parsed.elem_type_name);
    try testing.expect(parseVectorTypeName("arith.vec16xf64") == null);
    try testing.expect(parseVectorTypeName("arith.vec0xi32") == null);
}

test "arith scalar descriptors exhaustively derive spelling class width and sets" {
    const testing = std.testing;
    var all: ScalarSet = .{};

    inline for (std.meta.tags(ScalarKind)) |kind| {
        const descriptor = scalarDescriptor(kind);
        all.insert(kind);
        try testing.expectEqual(kind, descriptor.kind);
        try testing.expectEqualStrings(@tagName(kind), descriptor.suffix);
        try testing.expect(std.mem.startsWith(u8, descriptor.name, "arith."));
        try testing.expectEqualStrings(descriptor.suffix, descriptor.name["arith.".len..]);
        try testing.expectEqual(descriptor.bit_width, scalarBitWidth(kind));
        try testing.expect(descriptor.bit_width > 0 and descriptor.bit_width <= 64);
        switch (descriptor.class) {
            ScalarClass.boolean => {
                try testing.expect(!scalarKindIsInteger(kind));
                try testing.expect(!scalarKindIsFloat(kind));
            },
            .signed_integer, .index => try testing.expect(scalarKindIsSignedInteger(kind)),
            .unsigned_integer => try testing.expect(scalarKindIsUnsignedInteger(kind)),
            .float => try testing.expect(scalarKindIsFloat(kind)),
        }
    }

    const integer = ScalarSet.init(&.{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index });
    const floating = ScalarSet.init(&.{ .f16, .bf16, .f32, .f64 });
    try testing.expect(all.containsAll(integer));
    try testing.expect(all.containsAll(floating));
    try testing.expect(!integer.contains(.f32));
    try testing.expect(!floating.contains(.bool));
}

test "arith dialect registers semantic and verifier traits for AddOp" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const info = ctx.lookupOperation("arith.add") orelse
        return error.TestExpectedOperationInfo;
    try testing.expect(info.getInterface(ir.interfaces.EffectOpInterface.id) != null);
    try testing.expect(info.traits.is_commutative);
    try testing.expect(info.shape.operands.allows(2));
    try testing.expect(!info.shape.operands.allows(1));
    try testing.expect(info.shape.results.allows(1));
    try testing.expect(!info.shape.results.allows(0));
    try testing.expect(info.shape.regions.allows(0));
    try testing.expect(!info.shape.regions.allows(1));
    try testing.expect(info.shape.successors.allows(0));
    try testing.expect(!info.shape.successors.allows(1));
    try testing.expect(info.hasTraitId(ir.traits.SameOperandsAndResultType.id));
    try testing.expect(info.hasInterface(ir.interfaces.FoldOpInterface.id));
    try expectCanonicalizationPatterns(&ctx);
    _ = try ArithDialect.getBoolAttr(&ctx, false);
    _ = try ArithDialect.getBoolAttr(&ctx, true);
    ctx.activate();
    try expectCanonicalizationPatterns(&ctx);
    try exerciseBooleanSelectRewrite(&ctx, allocator);
}

fn expectCanonicalizationPatterns(ctx: *ir.Context) !void {
    const hook = rewrite.DialectCanonicalizationInterface;
    const vtable_opaque = ctx.getDialectInterface(ArithDialect.name, hook.id) orelse
        return error.TestExpectedCanonicalizationInterface;
    const patterns = hook.fromOpaque(vtable_opaque).patterns;
    try std.testing.expectEqual(arith.canonicalization_patterns.len, patterns.len);
    try std.testing.expectEqual(arith.canonicalization_patterns[0..].ptr, patterns.ptr);
    try std.testing.expectEqualStrings(ArithDialect.SelectOp.operation_name, patterns[0].spec.root_op_name);
    try std.testing.expectEqualStrings(ArithDialect.NotOp.operation_name, patterns[1].spec.root_op_name);
}

fn exerciseBooleanSelectRewrite(ctx: *ir.Context, allocator: std.mem.Allocator) !void {
    const hook = rewrite.DialectCanonicalizationInterface;
    const patterns = hook.fromOpaque(ctx.getDialectInterface(ArithDialect.name, hook.id).?).patterns;
    var block = ir.Block.init(allocator);
    defer block.deinit();
    const boundary = ctx.operationCreationBoundary();
    defer {
        var operations = block.getOperations();
        while (operations.next()) |op| op.dropAllReferences();
        ctx.eraseOperationsCreatedSince(boundary);
    }
    const loc = ir.Location.getUnknown();
    const bool_type = try ArithDialect.getScalarType(ctx, .bool);
    const condition = try block.addArgument(bool_type, loc);
    const false_value = try ArithDialect.ConstantOp.createBool(ctx, loc, false);
    try block.addOperation(false_value.op);
    const true_value = try ArithDialect.ConstantOp.createBool(ctx, loc, true);
    try block.addOperation(true_value.op);
    const select = try ArithDialect.SelectOp.create(
        ctx,
        loc,
        condition,
        false_value.getResult(),
        true_value.getResult(),
    );
    try block.addOperation(select.op);
    const user = try ArithDialect.NotOp.create(ctx, loc, select.getResult());
    try block.addOperation(user.op);
    var rewriter = rewrite.PatternRewriter.init(allocator, ctx);
    defer rewriter.deinit();
    try std.testing.expect(patterns[0].matches(select.op));
    try std.testing.expect(rewrite.tryApplyRewritePattern(&patterns[0], select.op, &rewriter));
    rewriter.finalize(user.op);
    const result = user.op.getOperand(0).?;
    const inverse: *ir.Operation = @ptrCast(@alignCast(result.getDefiningOp().?));
    try std.testing.expectEqualStrings(ArithDialect.NotOp.operation_name, inverse.name.name);
    try std.testing.expectEqual(condition, inverse.getOperand(0).?);
}

test "arith dialect registers single-entity type constraints as operation metadata" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const cmp_info = ctx.lookupOperation(ArithDialect.CmpOp.operation_name) orelse
        return error.TestExpectedOperationInfo;
    try testing.expectEqual(@as(usize, 1), cmp_info.getResultTypeConstraints().len);
    try testing.expectEqual(@as(usize, 0), cmp_info.getResultTypeConstraints()[0].index);
    try testing.expectEqualStrings(type_names.boolean, cmp_info.getResultTypeConstraints()[0].type_name);
    try testing.expect(!cmp_info.getResultTypeConstraints()[0].allow_parameterized);
    try testing.expect(cmp_info.hasTraitId(ir.traits.SameTypeOperands.id));

    const select_info = ctx.lookupOperation(ArithDialect.SelectOp.operation_name) orelse
        return error.TestExpectedOperationInfo;
    try testing.expectEqual(@as(usize, 1), select_info.getOperandTypeConstraints().len);
    try testing.expectEqual(@as(usize, 0), select_info.getOperandTypeConstraints()[0].index);
    try testing.expectEqualStrings(type_names.boolean, select_info.getOperandTypeConstraints()[0].type_name);
    try testing.expect(!select_info.getOperandTypeConstraints()[0].allow_parameterized);
}

test "arith.add with matching i32 operands passes SameOperandsAndResultType verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 10);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 20);
    const add = try ArithDialect.AddOp.create(&ctx, loc, c1.getResult(), c2.getResult());

    try ir.verify.verifyOperation(add.op, .{ .recursive = false });
}

test "arith.add with mismatched i32/i64 operands fails SameOperandsAndResultType verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);

    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 10);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 20);
    const add = try ArithDialect.AddOp.create(&ctx, loc, c1.getResult(), c2.getResult());

    try testing.expectError(
        ir.traits.TraitError.SameOperandsAndResultTypeMismatch,
        ir.verify.verifyOperation(add.op, .{ .recursive = false }),
    );
}

test "arith.neg over matching operand passes verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);

    var c = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 5);
    const neg = try ArithDialect.NegOp.create(&ctx, loc, c.getResult());
    try ir.verify.verifyOperation(neg.op, .{ .recursive = false });
}

test "arith.select with mismatched true/false operand types fails verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const f64_type = try ArithDialect.getF64Type(&ctx);

    var cond = try ArithDialect.ConstantOp.createInt(&ctx, loc, bool_type, 1);
    var true_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var false_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f64_type, 2.0);
    const sel = try ArithDialect.SelectOp.create(&ctx, loc, cond.getResult(), true_val.getResult(), false_val.getResult());

    try testing.expectError(
        ir.traits.TraitError.TypesMatchWithMismatch,
        ir.verify.verifyOperation(sel.op, .{ .recursive = false }),
    );
}

test "arith.select with mismatched result vs. true operand type fails verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const f64_type = try ArithDialect.getF64Type(&ctx);

    var cond = try ArithDialect.ConstantOp.createInt(&ctx, loc, bool_type, 0);
    var true_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 3.0);
    var false_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 4.0);

    var state = ir.Operation.State.init(ArithDialect.SelectOp.operation_name, loc);
    state.addOperands(&.{ cond.getResult(), true_val.getResult(), false_val.getResult() });
    state.addTypes(&.{f64_type});
    const sel_op = try ctx.createOperation(state);

    try testing.expectError(
        ir.traits.TraitError.TypesMatchWithMismatch,
        ir.verify.verifyOperation(sel_op, .{ .recursive = false }),
    );
}

test "arith.select with non-bool cond operand fails verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var cond = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var true_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var false_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 2.0);
    const sel = try ArithDialect.SelectOp.create(&ctx, loc, cond.getResult(), true_val.getResult(), false_val.getResult());

    try testing.expectError(
        ir.VerifyError.OperandTypeConstraintMismatch,
        ir.verify.verifyOperation(sel.op, .{ .recursive = false }),
    );
}

test "arith.select with bool cond operand passes verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var cond = try ArithDialect.ConstantOp.createBool(&ctx, loc, true);
    var true_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var false_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 2.0);
    const sel = try ArithDialect.SelectOp.create(&ctx, loc, cond.getResult(), true_val.getResult(), false_val.getResult());

    try ir.verify.verifyOperation(sel.op, .{ .recursive = false });
}

test "arith.fma with mismatched 3rd operand fails verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const f64_type = try ArithDialect.getF64Type(&ctx);

    var ca = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var cb = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 2.0);
    var cc = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f64_type, 3.0);
    const fma = try ArithDialect.FmaOp.create(&ctx, loc, ca.getResult(), cb.getResult(), cc.getResult());

    try testing.expectError(
        ir.traits.TraitError.SameOperandsAndResultTypeMismatch,
        ir.verify.verifyOperation(fma.op, .{ .recursive = false }),
    );
}

test "arith.shl with mismatched count width fails verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);

    var v = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 5);
    var c64 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 2);
    const shl = try ArithDialect.ShlOp.create(&ctx, loc, v.getResult(), c64.getResult());

    try testing.expectError(
        ir.traits.TraitError.SameOperandsAndResultTypeMismatch,
        ir.verify.verifyOperation(shl.op, .{ .recursive = false }),
    );
}

test "arith.constant verifies cleanly without SameOperandsAndResultType (zero operands)" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const c = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 42);

    try ir.verify.verifyOperation(c.op, .{ .recursive = false });
}

test "arith.constant stores value as operation properties" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const c = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 42);

    try testing.expectEqual(@as(usize, 0), c.op.getRawDictionaryAttrs().len);
    try testing.expectEqual(@as(?i64, 42), c.getIntValue());
    try testing.expect((try c.op.getPropertiesAsAttr()).?.eql(c.op.getAttr("value").?));

    try c.op.setAttr("debug.note", try ctx.getI64Attr(7));
    try testing.expectEqual(@as(usize, 1), c.op.getRawDictionaryAttrs().len);
    try testing.expectEqualStrings("debug.note", c.op.getRawDictionaryAttrs()[0].name);

    try testing.expectEqual(@as(usize, 2), c.op.getNumAttrs());
    var attrs = c.op.getAttrs();
    try testing.expectEqualStrings("debug.note", attrs.next().?.name);
    const value = attrs.next().?;
    try testing.expectEqualStrings("value", value.name);
    try testing.expect(value.value.eql(c.op.getAttr("value").?));
    try testing.expect(attrs.next() == null);
}

test "arith.cmp verifies cleanly without SameOperandsAndResultType (bool result)" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    const cmp = try ArithDialect.CmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult());
    try ir.verify.verifyOperation(cmp.op, .{ .recursive = false });
}

test "arith.cmp with matching i32 operands passes SameTypeOperands verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    const cmp = try ArithDialect.CmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult());
    try ir.verify.verifyOperation(cmp.op, .{ .recursive = false });
}

test "arith.cmp with mismatched i32 / i64 operands fails SameTypeOperands verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 2);
    const cmp = try ArithDialect.CmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult());

    try testing.expectError(
        ir.traits.TraitError.SameTypeOperandsMismatch,
        ir.verify.verifyOperation(cmp.op, .{ .recursive = false }),
    );
}

test "arith.cmp with non-bool result fails type constraint verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);

    var state = ir.Operation.State.init(ArithDialect.CmpOp.operation_name, loc);
    state.addOperands(&.{ c1.getResult(), c2.getResult() });
    state.addTypes(&.{i32_type});
    const cmp_op = try ctx.createOperation(state);
    try cmp_op.setAttr("predicate", try ctx.getDialectAttr(ArithDialect.name ++ ".predicate", "eq"));

    try testing.expectError(
        ir.VerifyError.ResultTypeConstraintMismatch,
        ir.verify.verifyOperation(cmp_op, .{ .recursive = false }),
    );
}

test "arith.cmp with bool result passes type constraint verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);

    const cmp = try ArithDialect.CmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult());
    try ir.verify.verifyOperation(cmp.op, .{ .recursive = false });
}

test "arith.select with keyed-variant cond type fails type constraint verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const keyed_bool = try ctx.getDialectTypeFromNameWithKey("arith.bool", "custom-key");

    var c_cond_state = ir.Operation.State.init(ArithDialect.ConstantOp.operation_name, loc);
    c_cond_state.addTypes(&.{keyed_bool});
    const c_cond = try ctx.createOperation(c_cond_state);

    var t_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    var f_val = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 2.0);
    const sel = try ArithDialect.SelectOp.create(&ctx, loc, c_cond.getResult(0).?, t_val.getResult(), f_val.getResult());

    try testing.expectError(
        ir.VerifyError.OperandTypeConstraintMismatch,
        ir.verify.verifyOperation(sel.op, .{ .recursive = false }),
    );
}

test "arith.cmp with keyed-variant result type fails type constraint verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const keyed_bool = try ctx.getDialectTypeFromNameWithKey("arith.bool", "custom-key");
    var c1 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    var c2 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);

    var state = ir.Operation.State.init(ArithDialect.CmpOp.operation_name, loc);
    state.addOperands(&.{ c1.getResult(), c2.getResult() });
    state.addTypes(&.{keyed_bool});
    const cmp_op = try ctx.createOperation(state);
    try cmp_op.setAttr("predicate", try ctx.getDialectAttr(ArithDialect.name ++ ".predicate", "eq"));

    try testing.expectError(
        ir.VerifyError.ResultTypeConstraintMismatch,
        ir.verify.verifyOperation(cmp_op, .{ .recursive = false }),
    );
}

test "arith.vec_cmp with matching vec4xf32 operands passes SameTypeOperands verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const vec4xf32 = try ArithDialect.getVec4xF32Type(&ctx);

    var c1 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32, 1.0);
    var c2 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32, 2.0);
    const cmp = try ArithDialect.VecCmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult(), vec4xf32);
    try ir.verify.verifyOperation(cmp.op, .{ .recursive = false });
}

test "arith.vec_cmp with mismatched vector types fails SameTypeOperands verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const vec4xf32 = try ArithDialect.getVec4xF32Type(&ctx);
    const vec8xf32 = (try ArithDialect.getVecType(&ctx, 8, type_names.float32)).?;

    var c1 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32, 1.0);
    var c2 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec8xf32, 2.0);
    const cmp = try ArithDialect.VecCmpOp.create(&ctx, loc, .eq, c1.getResult(), c2.getResult(), vec4xf32);

    try testing.expectError(
        ir.traits.TraitError.SameTypeOperandsMismatch,
        ir.verify.verifyOperation(cmp.op, .{ .recursive = false }),
    );
}

test "arith.add over matching vec4xf32 operands passes verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const vec4xf32 = try ArithDialect.getVec4xF32Type(&ctx);

    var c1 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32, 1.0);
    var c2 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32, 2.0);
    const add = try ArithDialect.AddOp.create(&ctx, loc, c1.getResult(), c2.getResult());

    try ir.verify.verifyOperation(add.op, .{ .recursive = false });
}

test "arith.add with mismatched vector types fails verification" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const vec4xf32 = try ArithDialect.getVec4xF32Type(&ctx);
    const vec8xf32 = (try ArithDialect.getVecType(&ctx, 8, type_names.float32)).?;

    var c1 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32, 1.0);
    var c2 = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec8xf32, 2.0);
    const add = try ArithDialect.AddOp.create(&ctx, loc, c1.getResult(), c2.getResult());

    try testing.expectError(
        ir.traits.TraitError.SameOperandsAndResultTypeMismatch,
        ir.verify.verifyOperation(add.op, .{ .recursive = false }),
    );
}

test "arith.neg over matching vec4xf32 operand passes verification" {
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, arith.spec);

    const loc = ir.Location.getUnknown();
    const vec4xf32 = try ArithDialect.getVec4xF32Type(&ctx);

    var c = try ArithDialect.VecConstantOp.createFloat(&ctx, loc, vec4xf32, 5.0);
    const neg = try ArithDialect.NegOp.create(&ctx, loc, c.getResult());

    try ir.verify.verifyOperation(neg.op, .{ .recursive = false });
}

test "Precision1 arith constants and typed arithmetic declarations" {
    const effects = ir.interfaces.effects;
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const scalar_types = @import("types.zig");
    for (std.enums.values(scalar_types.ScalarKind)) |kind| {
        const typ = try ArithDialect.getScalarType(&ctx, kind);
        const constant = if (scalar_types.scalarKindIsFloat(kind))
            try ArithDialect.ConstantOp.createFloat(&ctx, .unknown, typ, 1.0)
        else if (kind == .bool)
            try ArithDialect.ConstantOp.createBool(&ctx, .unknown, true)
        else
            try ArithDialect.ConstantOp.createInt(&ctx, .unknown, typ, 1);
        var constant_facts = try effects.inspect(std.testing.allocator, constant.op);
        defer constant_facts.deinit(std.testing.allocator);
        try std.testing.expect(effects.repeatableExpression(constant_facts.facts));
        const add = try ArithDialect.AddOp.create(
            &ctx,
            .unknown,
            constant.getResult(),
            constant.getResult(),
        );
        var add_facts = try effects.inspect(std.testing.allocator, add.op);
        defer add_facts.deinit(std.testing.allocator);
        try std.testing.expectEqual(
            kind != .bool,
            effects.repeatableExpression(add_facts.facts),
        );
        const div = try ArithDialect.DivOp.create(
            &ctx,
            .unknown,
            constant.getResult(),
            constant.getResult(),
        );
        var div_facts = try effects.inspect(std.testing.allocator, div.op);
        defer div_facts.deinit(std.testing.allocator);
        try std.testing.expectEqual(kind != .bool, div_facts.facts.complete);
        try std.testing.expectEqual(kind != .bool, effects.speculate(div_facts.facts, true));
    }
}

const PrecisionRow = struct {
    name: []const u8,
    operands: usize,
    integer: bool = false,
    floating: bool = false,
    boolean: bool = false,
};

const precision_rows = [_]PrecisionRow{
    .{ .name = "add", .operands = 2, .integer = true, .floating = true },
    .{ .name = "sub", .operands = 2, .integer = true, .floating = true },
    .{ .name = "mul", .operands = 2, .integer = true, .floating = true },
    .{ .name = "div", .operands = 2, .integer = true, .floating = true },
    .{ .name = "rem", .operands = 2, .integer = true },
    .{ .name = "neg", .operands = 1, .integer = true, .floating = true },
    .{ .name = "abs", .operands = 1, .integer = true, .floating = true },
    .{ .name = "min", .operands = 2, .integer = true, .floating = true },
    .{ .name = "max", .operands = 2, .integer = true, .floating = true },
    .{ .name = "and", .operands = 2, .integer = true, .boolean = true },
    .{ .name = "or", .operands = 2, .integer = true, .boolean = true },
    .{ .name = "xor", .operands = 2, .integer = true, .boolean = true },
    .{ .name = "not", .operands = 1, .integer = true, .boolean = true },
    .{ .name = "popcount", .operands = 1, .integer = true },
    .{ .name = "umulhi", .operands = 2, .integer = true },
    .{ .name = "shl", .operands = 2, .integer = true },
    .{ .name = "shr", .operands = 2, .integer = true },
    .{ .name = "ushr", .operands = 2, .integer = true },
    .{ .name = "fma", .operands = 3, .floating = true },
    .{ .name = "sqrt", .operands = 1, .floating = true },
    .{ .name = "exp", .operands = 1, .floating = true },
    .{ .name = "log", .operands = 1, .floating = true },
    .{ .name = "tanh", .operands = 1, .floating = true },
    .{ .name = "sin", .operands = 1, .floating = true },
    .{ .name = "cos", .operands = 1, .floating = true },
    .{ .name = "tan", .operands = 1, .floating = true },
    .{ .name = "pow", .operands = 2, .floating = true },
    .{ .name = "floor", .operands = 1, .floating = true },
    .{ .name = "round", .operands = 1, .floating = true },
    .{ .name = "trunc", .operands = 1, .floating = true },
};

fn precisionOperation(
    ctx: *ir.Context,
    name: []const u8,
    operands: []const *ir.Value,
    result: ir.Type,
) !*ir.Operation {
    var buffer: [64]u8 = undefined;
    const operation_name = try std.fmt.bufPrint(&buffer, "arith.{s}", .{name});
    var state = ir.Operation.State.init(operation_name, .unknown);
    state.addOperands(operands);
    state.addTypes(&.{result});
    var builder = ir.OperationBuilder.init(ctx);
    return builder.create(state);
}

fn expectPrecisionPermissions(op: *ir.Operation, permitted: bool) !void {
    const effects = ir.interfaces.effects;
    var declaration = try effects.inspect(std.testing.allocator, op);
    defer declaration.deinit(std.testing.allocator);
    try std.testing.expectEqual(permitted, effects.discard(declaration.facts));
    try std.testing.expectEqual(permitted, effects.duplicate(declaration.facts, .{}));
    try std.testing.expectEqual(permitted, effects.speculate(declaration.facts, true));
    try std.testing.expectEqual(permitted, effects.repeatableExpression(declaration.facts));
}

test "Precision1 declaration roster checks every scalar type and floating policy negative" {
    const types = @import("types.zig");
    for (std.enums.values(types.ScalarKind)) |kind| {
        var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(std.testing.allocator);
        const typ = try ArithDialect.getScalarType(&ctx, kind);
        const value = if (types.scalarKindIsFloat(kind))
            (try ArithDialect.ConstantOp.createFloat(&ctx, .unknown, typ, 1.0)).getResult()
        else if (kind == .bool)
            (try ArithDialect.ConstantOp.createBool(&ctx, .unknown, true)).getResult()
        else
            (try ArithDialect.ConstantOp.createInt(&ctx, .unknown, typ, 1)).getResult();
        for (precision_rows) |row| {
            const operands = [_]*ir.Value{ value, value, value };
            const op = try precisionOperation(&ctx, row.name, operands[0..row.operands], typ);
            const expected = if (kind == .bool) row.boolean else if (types.scalarKindIsFloat(kind))
                row.floating
            else
                row.integer;
            try expectPrecisionPermissions(op, expected);
            ctx.arithmetic_policy.environment_observable = true;
            try expectPrecisionPermissions(op, expected and !types.scalarKindIsFloat(kind));
            ctx.arithmetic_policy.environment_observable = false;
        }
    }
}

test "Precision1 partial integer domains refuse variable zero overflow and bad shift counts" {
    var block = ir.Block.init(std.testing.allocator);
    defer block.deinit();
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const typ = try ArithDialect.getI8Type(&ctx);
    const variable = try block.addArgument(typ, .unknown);
    const cases = [_]struct { rhs: i64, division: bool, shift: bool }{
        .{ .rhs = 0, .division = false, .shift = true },
        .{ .rhs = 1, .division = true, .shift = true },
        .{ .rhs = 2, .division = true, .shift = true },
        .{ .rhs = 7, .division = true, .shift = true },
        .{ .rhs = 8, .division = true, .shift = false },
        .{ .rhs = -1, .division = false, .shift = false },
        .{ .rhs = 255, .division = false, .shift = false },
    };
    for (cases) |case| {
        const rhs = (try ArithDialect.ConstantOp.createInt(
            &ctx,
            .unknown,
            typ,
            case.rhs,
        )).getResult();
        for ([_][]const u8{ "div", "rem", "shl", "shr", "ushr" }, 0..) |name, index| {
            const op = try precisionOperation(&ctx, name, &.{ variable, rhs }, typ);
            try expectPrecisionPermissions(op, if (index < 2) case.division else case.shift);
        }
    }
    for ([_][]const u8{ "div", "rem", "shl", "shr", "ushr" }) |name| {
        try expectPrecisionPermissions(
            try precisionOperation(&ctx, name, &.{ variable, variable }, typ),
            false,
        );
    }
}

test "Precision1 floating declarations require all three Context policy fields" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const typ = try ArithDialect.getScalarType(&ctx, .f32);
    const input = try ArithDialect.ConstantOp.createFloat(&ctx, .unknown, typ, 4);
    const operation = try ArithDialect.SqrtOp.create(&ctx, .unknown, input.getResult());
    const Policy = ir.interfaces.effects.ArithmeticPolicy;
    for ([_]Policy{
        .{},
        .{ .exceptions_masked = false },
        .{ .default_rounding = false },
        .{ .environment_observable = true },
    }, 0..) |policy, index| {
        ctx.arithmetic_policy = policy;
        try expectPrecisionPermissions(operation.op, index == 0);
    }
}

test "Precision1 structural vector declarations check lanes masks shapes and floating policy" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const scalar_type = try ArithDialect.getScalarType(&ctx, .f32);
    const vector_type = try ArithDialect.getVec4xF32Type(&ctx);
    const mask_type = (try ArithDialect.getVecType(&ctx, 4, type_names.int32)).?;
    const short_mask = (try ArithDialect.getVecType(&ctx, 2, type_names.int32)).?;
    const scalar_value = try ArithDialect.ConstantOp.createFloat(&ctx, .unknown, scalar_type, 3);
    const vector_value = try ArithDialect.VecConstantOp.createFloat(&ctx, .unknown, vector_type, 3);
    try expectPrecisionPermissions(vector_value.op, true);
    const splat = try ArithDialect.SplatOp.create(
        &ctx,
        .unknown,
        scalar_value.getResult(),
        vector_type,
    );
    try expectPrecisionPermissions(splat.op, true);
    for ([_]i64{ -1, 0, 3, 4 }) |index| {
        const extract = try ArithDialect.ExtractOp.create(
            &ctx,
            .unknown,
            vector_value.getResult(),
            index,
            scalar_type,
        );
        const insert = try ArithDialect.InsertOp.create(
            &ctx,
            .unknown,
            vector_value.getResult(),
            scalar_value.getResult(),
            index,
        );
        try expectPrecisionPermissions(extract.op, index >= 0 and index < 4);
        try expectPrecisionPermissions(insert.op, index >= 0 and index < 4);
    }
    for ([_]ir.Type{ vector_type, mask_type, short_mask }, 0..) |result, index| {
        const cmp = try ArithDialect.VecCmpOp.create(
            &ctx,
            .unknown,
            .eq,
            vector_value.getResult(),
            vector_value.getResult(),
            result,
        );
        try expectPrecisionPermissions(cmp.op, index < 2);
        ctx.arithmetic_policy.environment_observable = true;
        try expectPrecisionPermissions(cmp.op, false);
        ctx.arithmetic_policy.environment_observable = false;
    }
    for ([_][4]i64{ .{ 3, 2, 1, 0 }, .{ 0, 1, 2, 4 } }, 0..) |indices, index| {
        const shuffle = try ArithDialect.VecShuffleOp.create(
            &ctx,
            .unknown,
            vector_value.getResult(),
            vector_type,
            &indices,
        );
        try expectPrecisionPermissions(shuffle.op, index == 0);
    }
}

test "Precision1 comparisons selects and scalar casts qualify only supported type shapes" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const input = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, i32_type, 1);
    const floating = try ArithDialect.ConstantOp.createFloat(&ctx, .unknown, f32_type, 1);
    const condition = try ArithDialect.ConstantOp.createBool(&ctx, .unknown, true);
    const cmp = try ArithDialect.CmpOp.create(
        &ctx,
        .unknown,
        .lt,
        input.getResult(),
        input.getResult(),
    );
    try expectPrecisionPermissions(cmp.op, true);
    const select = try ArithDialect.SelectOp.create(
        &ctx,
        .unknown,
        condition.getResult(),
        input.getResult(),
        input.getResult(),
    );
    try expectPrecisionPermissions(select.op, true);
    const cast = try ArithDialect.CastOp.create(&ctx, .unknown, input.getResult(), i64_type);
    try expectPrecisionPermissions(cast.op, true);
    const bitcast = try ArithDialect.BitcastOp.create(
        &ctx,
        .unknown,
        floating.getResult(),
        i32_type,
    );
    try expectPrecisionPermissions(bitcast.op, true);
    const wide = try ArithDialect.BitcastOp.create(&ctx, .unknown, input.getResult(), i64_type);
    try expectPrecisionPermissions(wide.op, false);
    const wrong = try precisionOperation(&ctx, "sub", &.{input.getResult()}, i32_type);
    try expectPrecisionPermissions(wrong, false);
}

test "overflow arithmetic verifies its two results and refuses every other scalar kind" {
    inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
        var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(std.testing.allocator);
        try ir.dialects.loadDialectSpec(&ctx, arith.spec);
        const integer = try ArithDialect.getScalarType(&ctx, .i64);
        const boolean = try ArithDialect.getScalarType(&ctx, .bool);
        const lhs = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer, 1);
        const rhs = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer, 2);
        const valid = try Op.create(&ctx, .unknown, lhs.getResult(), rhs.getResult());
        try ir.verifyOperation(valid.op, .{});
        try std.testing.expect(valid.getResult().type.eql(integer));
        try std.testing.expect(valid.getOverflow().type.eql(boolean));
        try std.testing.expect(valid.op.getInterface(ir.interfaces.FoldOpInterface) == null);

        for (std.enums.values(ScalarKind)) |kind| {
            if (kind == .i64) continue;
            const typ = try ArithDialect.getScalarType(&ctx, kind);
            const wrong = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, typ, 1);
            const rejected = try Op.create(&ctx, .unknown, wrong.getResult(), wrong.getResult());
            try std.testing.expectError(error.OperandTypeConstraintMismatch, ir.verifyOperation(rejected.op, .{}));
        }
        const mixed = try Op.create(&ctx, .unknown, lhs.getResult(), (try ArithDialect.ConstantOp.createBool(&ctx, .unknown, false)).getResult());
        try std.testing.expectError(error.OperandTypeConstraintMismatch, ir.verifyOperation(mixed.op, .{}));

        var state = ir.Operation.State.init(Op.operation_name, .unknown);
        state.addOperands(&.{lhs.getResult()});
        state.addTypes(&.{ integer, boolean });
        try std.testing.expectError(error.OperandCountMismatch, ir.verifyOperation(try ctx.createOperation(state), .{}));
        state = ir.Operation.State.init(Op.operation_name, .unknown);
        state.addOperands(&.{ lhs.getResult(), rhs.getResult() });
        state.addTypes(&.{integer});
        try std.testing.expectError(error.ResultCountMismatch, ir.verifyOperation(try ctx.createOperation(state), .{}));
        state = ir.Operation.State.init(Op.operation_name, .unknown);
        state.addOperands(&.{ lhs.getResult(), rhs.getResult() });
        state.addTypes(&.{ integer, integer });
        try std.testing.expectError(error.ResultTypeConstraintMismatch, ir.verifyOperation(try ctx.createOperation(state), .{}));

        var storage: [8]ir.interfaces.effects.Fact = undefined;
        const facts = try ir.interfaces.effects.collectInto(valid.op, &storage);
        try std.testing.expect(facts.complete);
        try std.testing.expectEqual(@as(usize, 2), facts.records.len);
        for (facts.records, 0..) |fact, index| {
            try std.testing.expect(fact == .result);
            try std.testing.expectEqual(index, fact.result.index);
        }
    }
}

test "overflow arithmetic evaluator returns value and flag without trapping" {
    const evaluator = @import("../../eval/root.zig");
    const inputs = [_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -9, -2, -1, 0, 1, 2, 3, 5, 9, 1 << 32, 1 << 62, std.math.maxInt(i64) };
    inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }, 0..) |Op, kind| {
        var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
        defer ctx.deinit(std.testing.allocator);
        try ir.dialects.loadDialectSpec(&ctx, arith.spec);
        const integer = try ArithDialect.getScalarType(&ctx, .i64);
        const lhs = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer, 0);
        const rhs = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer, 0);
        const operation = try Op.create(&ctx, .unknown, lhs.getResult(), rhs.getResult());
        const value_use = try ArithDialect.AddOp.create(&ctx, .unknown, operation.getResult(), lhs.getResult());
        const flag_use = try ArithDialect.SelectOp.create(&ctx, .unknown, operation.getOverflow(), lhs.getResult(), rhs.getResult());
        var machine = evaluator.Evaluator.init(std.testing.allocator, &ctx);
        defer machine.deinit();
        for (inputs) |a| for (inputs) |b| {
            try machine.setValue(lhs.getResult(), try ctx.getI64Attr(a));
            try machine.setValue(rhs.getResult(), try ctx.getI64Attr(b));
            const expected = switch (kind) {
                0 => @addWithOverflow(a, b),
                1 => @subWithOverflow(a, b),
                2 => @mulWithOverflow(a, b),
                else => unreachable,
            };
            const answer = try machine.evaluate(operation.op);
            const values = answer.interface(ir.interfaces.AttributeArrayInterface).?;
            try std.testing.expectEqual(@as(usize, 2), values.call(.getCount, .{}));
            try std.testing.expectEqual(expected[0], ArithDialect.getIntValue(values.call(.getElement, .{@as(usize, 0)}).?).?);
            try std.testing.expectEqual(expected[1] != 0, ArithDialect.getBoolValue(values.call(.getElement, .{@as(usize, 1)}).?).?);
        };
        try machine.setValue(lhs.getResult(), try ctx.getI64Attr(std.math.maxInt(i64)));
        try machine.setValue(rhs.getResult(), try ctx.getI64Attr(2));
        _ = try machine.evaluate(value_use.op);
        _ = try machine.evaluate(flag_use.op);
        try std.testing.expect(machine.getValue(operation.getResult()) != null);
        try std.testing.expect(machine.getValue(operation.getOverflow()) != null);
    }
}

test "overflow arithmetic preserves both results through cloning text CSE and dead code removal" {
    const dialects = @import("../root.zig");
    const passes = @import("../../passes/root.zig");
    inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
        for (0..4) |used| {
            var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
            defer ctx.deinit(std.testing.allocator);
            try dialects.registerAllDialects(&ctx);
            const integer = try ArithDialect.getScalarType(&ctx, .i64);
            const boolean = try ArithDialect.getScalarType(&ctx, .bool);
            const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, .unknown);
            var result_types: [2]ir.Type = undefined;
            var count: usize = 0;
            if (used & 1 != 0) {
                result_types[count] = integer;
                count += 1;
            }
            if (used & 2 != 0) {
                result_types[count] = boolean;
                count += 1;
            }
            const function = try dialects.FuncDialect.FuncOp.create(&ctx, .unknown, "checked", &.{ integer, integer }, result_types[0..count]);
            try module.getBodyBlock().addOperation(function.op);
            const block = function.getEntryBlock();
            const first = try Op.create(&ctx, .unknown, function.getArgument(0), function.getArgument(1));
            const second = try Op.create(&ctx, .unknown, function.getArgument(0), function.getArgument(1));
            try block.addOperation(first.op);
            try block.addOperation(second.op);
            var returns: [2]*ir.Value = undefined;
            count = 0;
            if (used & 1 != 0) {
                returns[count] = second.getResult();
                count += 1;
            }
            if (used & 2 != 0) {
                returns[count] = second.getOverflow();
                count += 1;
            }
            const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, .unknown, returns[0..count]);
            try block.addOperation(ret.op);
            try ir.verifyOperation(module.op, .{});
            const clone = try module.op.clone();
            try ir.verifyOperation(clone, .{});
            const text = try ir.dump.operationAlloc(std.testing.allocator, clone);
            defer std.testing.allocator.free(text);
            const parsed = try ir.parse.operation(&ctx, text);
            try ir.verifyOperation(parsed, .{});
            const round_trip = try ir.dump.operationAlloc(std.testing.allocator, parsed);
            defer std.testing.allocator.free(round_trip);
            try std.testing.expectEqualStrings(text, round_trip);
            var manager = passes.PassManager.init(std.testing.allocator);
            defer manager.deinit();
            try manager.addPass(passes.createCommonSubexpressionEliminationPass());
            try manager.addPass(passes.createDeadCodeEliminationPass());
            try std.testing.expectEqual(passes.PassResult.success, manager.run(module.op, &ctx));
            try ir.verifyOperation(module.op, .{});
            var operations = block.getOperations();
            if (used != 0) {
                try std.testing.expect(operations.next().? == first.op);
                for (ret.op.operands.items) |operand| {
                    try std.testing.expect(operand.value.getDefiningOp().? == @as(*anyopaque, @ptrCast(first.op)));
                }
            }
            try std.testing.expect(operations.next().? == ret.op);
            try std.testing.expect(operations.next() == null);
        }
    }
}

test "overflow arithmetic constant roots keep both results through the fold cache" {
    const dialects = @import("../root.zig");
    const passes = @import("../../passes/root.zig");
    inline for (.{ ArithDialect.AddoOp, ArithDialect.SuboOp, ArithDialect.MuloOp }) |Op| {
        for (1..4) |used| {
            var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
            defer ctx.deinit(std.testing.allocator);
            try dialects.registerAllDialects(&ctx);
            const integer = try ArithDialect.getScalarType(&ctx, .i64);
            const boolean = try ArithDialect.getScalarType(&ctx, .bool);
            const types: []const ir.Type = switch (used) {
                1 => &.{integer},
                2 => &.{boolean},
                3 => &.{ integer, boolean },
                else => unreachable,
            };
            const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, .unknown);
            const function = try dialects.FuncDialect.FuncOp.create(&ctx, .unknown, "constants", &.{}, types);
            try module.getBodyBlock().addOperation(function.op);
            const block = function.getEntryBlock();
            const lhs = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer, std.math.maxInt(i64));
            const rhs = try ArithDialect.ConstantOp.createInt(&ctx, .unknown, integer, 2);
            try block.addOperation(lhs.op);
            try block.addOperation(rhs.op);
            const checked = try Op.create(&ctx, .unknown, lhs.getResult(), rhs.getResult());
            try block.addOperation(checked.op);
            const values: []const *ir.Value = switch (used) {
                1 => &.{checked.getResult()},
                2 => &.{checked.getOverflow()},
                3 => &.{ checked.getResult(), checked.getOverflow() },
                else => unreachable,
            };
            const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, .unknown, values);
            try block.addOperation(ret.op);
            var manager = passes.PassManager.init(std.testing.allocator);
            defer manager.deinit();
            try manager.addPass(passes.createCanonicalizationPass());
            try manager.addPass(passes.createConstantFoldingPass());
            try manager.addPass(passes.createCommonSubexpressionEliminationPass());
            try manager.addPass(passes.createDeadCodeEliminationPass());
            try std.testing.expectEqual(passes.PassResult.success, manager.run(module.op, &ctx));
            try ir.verifyOperation(module.op, .{});
            try std.testing.expectEqual(@as(usize, 2), checked.op.getNumResults());
            try std.testing.expect(checked.getResult().type.eql(integer));
            try std.testing.expect(checked.getOverflow().type.eql(boolean));
            try std.testing.expectEqualSlices(*ir.Value, values, ret.op.getOperandValues());
            var operations = block.getOperations();
            try std.testing.expect(operations.next().? == lhs.op);
            try std.testing.expect(operations.next().? == rhs.op);
            try std.testing.expect(operations.next().? == checked.op);
            try std.testing.expect(operations.next().? == ret.op);
            try std.testing.expect(operations.next() == null);
        }
    }
}
