const std = @import("std");
const choir = @import("choir");
const accy_root = @import("../../root.zig");

const emitWgsl = choir.backends.gpu.webgpu.wgsl.emitWgsl;

test "webgpu choir wgsl emitter lowers simple elementwise kernel" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_add", &params);
    errdefer builder.deinit();
    const out = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const count_buffer = builder.argument(3);
    const index = try builder.globalId(.x);
    const zero = try builder.constantIndex(0);
    const count = try builder.load(count_buffer, zero);
    const index_i32 = try builder.cast(index, .i32);
    const in_bounds = try builder.compare(.lt, index_i32, count);
    var if_op = try builder.if_(in_bounds, &.{});
    const previous = builder.insertionBlock();
    builder.setInsertionBlock(if_op.thenBlock());
    const left = try builder.load(lhs, index);
    const right = try builder.load(rhs, index);
    const sum = try builder.add(try builder.add(try builder.floor(left), try builder.trunc(right)), try builder.atan2(left, right));
    try builder.store(sum, out, index);
    try builder.yield_(&.{});
    builder.setInsertionBlock(if_op.elseBlock().?);
    try builder.yield_(&.{});
    builder.setInsertionBlock(previous);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitWgsl(testing.allocator, "accy_wgsl_test_add", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "@compute @workgroup_size") != null);
    try testing.expect(std.mem.indexOf(u8, text, "fn accy_wgsl_test_add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@group(0) @binding(0) var<storage, read_write> arg0: array<f32>;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@group(0) @binding(1) var<storage, read> arg1: array<f32>;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@group(0) @binding(2) var<storage, read> arg2: array<f32>;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@group(0) @binding(3) var<storage, read> arg3: array<i32>;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@builtin(global_invocation_id)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if (") != null);
    try testing.expect(std.mem.indexOf(u8, text, "floor(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "trunc(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atan2(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "arg0[") != null);
}

test "webgpu choir wgsl emitter lowers loop-carried reduction shape" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_reduce", &params);
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const zero_index = try builder.constantIndex(0);
    const upper = try builder.constantIndex(4);
    const step = try builder.constantIndex(1);
    const initial = try builder.constantFloat(.f32, 0.0);
    var loop_scope = try builder.forScope(zero_index, upper, step, &.{initial}, &.{initial.valueType()});
    errdefer loop_scope.abort();
    const value = try builder.load(input, loop_scope.inductionVar());
    const next = try builder.add(loop_scope.iterArg(0).?, value);
    try loop_scope.leave(&.{next});
    const result = loop_scope.result(0).?;
    try builder.store(result, out, zero_index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitWgsl(testing.allocator, "accy_wgsl_test_reduce", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "for (var") != null);
    try testing.expect(std.mem.indexOf(u8, text, ": i32 =") != null);
    try testing.expect(std.mem.indexOf(u8, text, " = ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "arg0[") != null);
}

test "webgpu choir wgsl emitter lowers workgroup memory and barriers" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_shared", &params);
    errdefer builder.deinit();
    const out = builder.argument(0);
    const shared = try builder.sharedBuffer(.f32, 16);
    const zero_index = try builder.constantIndex(0);
    const one = try builder.constantFloat(.f32, 1.0);
    try builder.store(one, shared, zero_index);
    try builder.barrier(.block);
    const value = try builder.load(shared, zero_index);
    try builder.store(value, out, zero_index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitWgsl(testing.allocator, "accy_wgsl_test_shared", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "var<workgroup> shared0: array<f32, 16>;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "workgroupBarrier();") != null);
}

test "webgpu choir wgsl emitter lowers unsigned high multiply" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_umulhi", &params);
    errdefer builder.deinit();
    const out = builder.argument(0);
    const lhs = builder.argument(1);
    const rhs = builder.argument(2);
    const index = try builder.globalId(.x);
    const left = try builder.load(lhs, index);
    const right = try builder.load(rhs, index);
    const high = try builder.umulhi(left, right);
    try builder.store(high, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitWgsl(testing.allocator, "accy_wgsl_test_umulhi", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "fn choir_umulhi_u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bitcast<i32>(choir_umulhi_u32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "fn accy_wgsl_test_umulhi") != null);
}

test "webgpu choir wgsl emitter lowers while loops with carried exits" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_while", &params);
    errdefer builder.deinit();
    const src = builder.argument(0);
    const dst = builder.argument(1);
    const index = try builder.globalId(.x);
    const start = try builder.load(src, index);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);

    var scope = try builder.whileScope(&.{ start, zero }, &.{ start.valueType(), zero.valueType() });
    errdefer scope.abort();
    const remaining = scope.beforeArg(0).?;
    const total = scope.beforeArg(1).?;
    const proceed = try builder.compare(.gt, remaining, zero);
    try scope.condition(proceed, &.{ remaining, total });
    const after_remaining = scope.afterArg(0).?;
    const after_total = scope.afterArg(1).?;
    const next_total = try builder.add(after_total, after_remaining);
    const next_remaining = try builder.sub(after_remaining, one);
    try scope.leave(&.{ next_remaining, next_total });

    try builder.store(scope.result(1).?, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitWgsl(testing.allocator, "accy_wgsl_test_while", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "loop {") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if (!(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "break;") != null);
    try testing.expect(std.mem.count(u8, text, "var l") >= 4);
}

test "webgpu choir wgsl emitter rejects barriers inside while loops" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_while_barrier", &params);
    errdefer builder.deinit();
    const dst = builder.argument(0);
    const index = try builder.globalId(.x);
    const start = try builder.cast(index, .i32);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);

    var scope = try builder.whileScope(&.{start}, &.{start.valueType()});
    errdefer scope.abort();
    const remaining = scope.beforeArg(0).?;
    const proceed = try builder.compare(.gt, remaining, zero);
    try scope.condition(proceed, &.{remaining});
    const after_remaining = scope.afterArg(0).?;
    try builder.barrier(.block);
    const next_remaining = try builder.sub(after_remaining, one);
    try scope.leave(&.{next_remaining});

    try builder.store(scope.result(0).?, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    try testing.expectError(
        error.UnsupportedOperation,
        emitWgsl(testing.allocator, "accy_wgsl_test_while_barrier", program.kernelModule()),
    );
}

test "webgpu choir wgsl emitter lowers value producing if arms" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_if_value", &params);
    errdefer builder.deinit();
    const dst = builder.argument(0);
    const src = builder.argument(1);
    const index = try builder.globalId(.x);
    const value = try builder.load(src, index);
    const zero = try builder.constantFloat(.f32, 0.0);
    const positive = try builder.compare(.gt, value, zero);

    var if_op = try builder.if_(positive, &.{value.valueType()});
    const previous = builder.insertionBlock();
    builder.setInsertionBlock(if_op.thenBlock());
    const doubled = try builder.add(value, value);
    try builder.yield_(&.{doubled});
    builder.setInsertionBlock(if_op.elseBlock().?);
    try builder.yield_(&.{zero});
    builder.setInsertionBlock(previous);

    try builder.store(if_op.result(0).?, dst, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitWgsl(testing.allocator, "accy_wgsl_test_if_value", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "var l0: f32;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "} else {") != null);
}

test "webgpu choir wgsl emitter rejects warp collectives" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(testing.allocator, builder_mod.Builder.Limits.testing, "accy_wgsl_test_warp_reject", &params);
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const lane = try builder.laneId();
    const value = try builder.load(input, lane);
    const reduced = try builder.warpReduce(.add, value);
    try builder.store(reduced, out, lane);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    try testing.expectError(
        error.UnsupportedOperation,
        emitWgsl(testing.allocator, "accy_wgsl_test_warp_reject", program.kernelModule()),
    );
}
