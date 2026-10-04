const std = @import("std");
const choir = @import("choir");
const accy_root = @import("../../root.zig");

const emitMsl = choir.backends.gpu.metal.msl.emitMsl;

test "metal choir msl emitter lowers simple elementwise kernel" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_add",
        &params,
    );
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
    const rounded = try builder.add(
        try builder.add(try builder.floor(left), try builder.round(left)),
        try builder.trunc(right),
    );
    const sum = try builder.add(rounded, try builder.atan2(left, right));
    try builder.store(sum, out, index);
    try builder.yield_(&.{});
    builder.setInsertionBlock(if_op.elseBlock().?);
    try builder.yield_(&.{});
    builder.setInsertionBlock(previous);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(testing.allocator, "accy_choir_test_add", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "kernel void accy_choir_test_add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "device float* arg0 [[buffer(0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "thread_position_in_grid") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if (") != null);
    try testing.expect(std.mem.indexOf(u8, text, "floor(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0x80000000u") != null);
    try testing.expect(std.mem.indexOf(u8, text, "trunc(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atan2(") != null);
    try testing.expect(std.mem.indexOf(u8, text, " + ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "arg0[") != null);
}

test "metal choir msl emitter lowers loop-carried reduction shape" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_reduce",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const zero_index = try builder.constantIndex(0);
    const upper = try builder.constantIndex(4);
    const step = try builder.constantIndex(1);
    const initial = try builder.constantFloat(.f32, 0.0);
    var loop_scope = try builder.forScope(
        zero_index,
        upper,
        step,
        &.{initial},
        &.{initial.valueType()},
    );
    errdefer loop_scope.abort();
    const value = try builder.load(input, loop_scope.inductionVar());
    const next = try builder.add(loop_scope.iterArg(0).?, value);
    try loop_scope.leave(&.{next});
    const result = loop_scope.result(0).?;
    try builder.store(result, out, zero_index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(testing.allocator, "accy_choir_test_reduce", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "for (int") != null);
    try testing.expect(std.mem.indexOf(u8, text, " += ") != null);
    try testing.expect(std.mem.indexOf(u8, text, " = v") != null);
    try testing.expect(std.mem.indexOf(u8, text, "arg0[") != null);
}

test "metal choir msl emitter lowers while loops with carried exits" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_while",
        &params,
    );
    errdefer builder.deinit();
    const dst = builder.argument(0);
    const index = try builder.globalId(.x);
    const start = try builder.cast(index, .i32);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);

    var scope = try builder.whileScope(
        &.{ start, zero },
        &.{ start.valueType(), zero.valueType() },
    );
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
    const text = try emitMsl(testing.allocator, "accy_choir_test_while", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "while (true) {") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if (!(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "break;") != null);
    try testing.expect(std.mem.count(u8, text, "int l") >= 4);
}

test "metal choir msl emitter keeps index arithmetic signed" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_index_clamp",
        &.{},
    );
    errdefer builder.deinit();
    const negative = try builder.constantInt(.i32, -2);
    const index = try builder.castIndex(negative);
    const zero = try builder.constantIndex(0);
    const one = try builder.constantIndex(1);
    _ = try builder.min(try builder.max(index, zero), one);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_index_clamp",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "const int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "int(-2)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "min(") != null);
    try testing.expect(std.mem.indexOf(u8, text, "const uint") == null);
}

test "metal choir msl emitter lowers u32 data operations" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.u32),
        builder_mod.dynamicBuffer(.u32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_u32",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const index = try builder.globalId(.x);
    const loaded = try builder.load(input, index);
    const bias = try builder.constantInt(.u32, 7);
    const value = try builder.max(
        try builder.add(try builder.neg(loaded), bias),
        try builder.not(bias),
    );
    try builder.store(value, out, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(testing.allocator, "accy_choir_test_u32", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "device uint* arg0 [[buffer(0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "const uint") != null);
    try testing.expect(std.mem.indexOf(u8, text, "uint(7)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "max(") != null);
    try testing.expect(std.mem.indexOf(u8, text, " = ~") != null);
}

test "metal choir msl emitter lowers logical right shift through unsigned bits" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_ushr",
        &.{},
    );
    errdefer builder.deinit();
    const value = try builder.constantInt(.i32, -16);
    const shift = try builder.constantInt(.i32, 1);
    _ = try builder.ushr(value, shift);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(testing.allocator, "accy_choir_test_ushr", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "as_type<uint>") != null);
    try testing.expect(std.mem.indexOf(u8, text, ">>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "as_type<int>") != null);
}

test "metal choir msl emitter lowers device atomic add" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_atomic_add",
        &params,
    );
    errdefer builder.deinit();
    const bins = builder.argument(0);
    const index = try builder.globalId(.x);
    const one = try builder.constantInt(.i32, 1);
    _ = try builder.atomicRmw(.add, one, bins, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_atomic_add",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_add_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "device atomic_int*") != null);
    try testing.expect(std.mem.indexOf(u8, text, "memory_order_relaxed") != null);
}

test "metal choir msl emitter lowers device integer atomic rmw matrix" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_atomic_rmw_matrix",
        &params,
    );
    errdefer builder.deinit();
    const bins = builder.argument(0);
    const index = try builder.globalId(.x);
    const one = try builder.constantInt(.i32, 1);
    const add = try builder.atomicRmw(.add, one, bins, index);
    const min = try builder.atomicRmw(.min, add, bins, index);
    const max = try builder.atomicRmw(.max, min, bins, index);
    const bit_and = try builder.atomicRmw(.bit_and, max, bins, index);
    const bit_or = try builder.atomicRmw(.bit_or, bit_and, bins, index);
    const bit_xor = try builder.atomicRmw(.bit_xor, bit_or, bins, index);
    _ = try builder.atomicRmw(.exchange, bit_xor, bins, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_atomic_rmw_matrix",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_add_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_min_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_max_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_and_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_or_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_xor_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_exchange_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "device atomic_int*") != null);
}

test "metal choir msl emitter lowers device atomic cas" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_atomic_cas",
        &params,
    );
    errdefer builder.deinit();
    const bins = builder.argument(0);
    const index = try builder.globalId(.x);
    const expected = try builder.constantInt(.i32, 0);
    const desired = try builder.constantInt(.i32, 7);
    const old = try builder.atomicCas(expected, desired, bins, index);
    try builder.store(old, bins, index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_atomic_cas",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "atomic_compare_exchange_weak_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "device atomic_int*") != null);
    try testing.expect(std.mem.indexOf(u8, text, "do {") != null);
    try testing.expect(std.mem.indexOf(u8, text, "while (!") != null);
}

test "metal choir msl emitter lowers shared allocation barriers and atomic add" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_shared_atomic_add",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const shared = try builder.sharedBuffer(.i32, 16);
    const zero_index = try builder.constantIndex(0);
    const zero = try builder.constantInt(.i32, 0);
    const one = try builder.constantInt(.i32, 1);
    try builder.store(zero, shared, zero_index);
    try builder.barrier(.block);
    _ = try builder.atomicRmw(.add, one, shared, zero_index);
    try builder.barrier(.block);
    const value = try builder.load(shared, zero_index);
    try builder.store(value, out, zero_index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_shared_atomic_add",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "threadgroup int shared") != null);
    try testing.expect(
        std.mem.indexOf(u8, text, "threadgroup_barrier(mem_flags::mem_threadgroup)") != null,
    );
    try testing.expect(std.mem.indexOf(u8, text, "threadgroup atomic_int*") != null);
}

test "metal choir msl emitter lowers shared integer atomic rmw matrix" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_shared_atomic_rmw_matrix",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const shared = try builder.sharedBuffer(.i32, 16);
    const zero_index = try builder.constantIndex(0);
    const one = try builder.constantInt(.i32, 1);
    try builder.store(one, shared, zero_index);
    try builder.barrier(.block);
    const add = try builder.atomicRmw(.add, one, shared, zero_index);
    const min = try builder.atomicRmw(.min, add, shared, zero_index);
    const max = try builder.atomicRmw(.max, min, shared, zero_index);
    const bit_and = try builder.atomicRmw(.bit_and, max, shared, zero_index);
    const bit_or = try builder.atomicRmw(.bit_or, bit_and, shared, zero_index);
    const bit_xor = try builder.atomicRmw(.bit_xor, bit_or, shared, zero_index);
    const old = try builder.atomicRmw(.exchange, bit_xor, shared, zero_index);
    try builder.store(old, out, zero_index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_shared_atomic_rmw_matrix",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_add_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_min_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_max_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_and_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_or_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_fetch_xor_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "atomic_exchange_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "threadgroup atomic_int*") != null);
}

test "metal choir msl emitter rejects shared f32 atomic add without feature contract" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_shared_atomic_f32_reject",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const shared = try builder.sharedBuffer(.f32, 16);
    const zero_index = try builder.constantIndex(0);
    const delta = try builder.constantFloat(.f32, 1.0);
    const old = try builder.atomicRmw(.add, delta, shared, zero_index);
    try builder.store(old, out, zero_index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    try testing.expectError(
        error.UnsupportedOperation,
        emitMsl(
            testing.allocator,
            "accy_choir_test_shared_atomic_f32_reject",
            program.kernelModule(),
        ),
    );
}

test "metal choir msl emitter lowers shared atomic cas" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_shared_atomic_cas",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const shared = try builder.sharedBuffer(.i32, 16);
    const zero_index = try builder.constantIndex(0);
    const expected = try builder.constantInt(.i32, 0);
    const desired = try builder.constantInt(.i32, 11);
    try builder.store(expected, shared, zero_index);
    try builder.barrier(.block);
    const old = try builder.atomicCas(expected, desired, shared, zero_index);
    try builder.store(old, out, zero_index);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_shared_atomic_cas",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "atomic_compare_exchange_weak_explicit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "threadgroup atomic_int*") != null);
    try testing.expect(
        std.mem.indexOf(u8, text, "threadgroup_barrier(mem_flags::mem_threadgroup)") != null,
    );
}

test "metal choir msl emitter lowers simdgroup ids scan and reduce" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.f32),
        builder_mod.dynamicBuffer(.f32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_simdgroup",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const lane = try builder.laneId();
    _ = try builder.warpId();
    const value = try builder.load(input, lane);
    const scanned = try builder.warpScan(.add, .inclusive, value);
    const reduced = try builder.warpReduce(.add, value);
    try builder.store(try builder.add(scanned, reduced), out, lane);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_simdgroup",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "thread_index_in_simdgroup") != null);
    try testing.expect(std.mem.indexOf(u8, text, "simdgroup_index_in_threadgroup") != null);
    try testing.expect(std.mem.indexOf(u8, text, "simd_prefix_inclusive_sum") != null);
    try testing.expect(std.mem.indexOf(u8, text, "simd_sum") != null);
}

test "metal choir msl emitter lowers integer exclusive simdgroup scan" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;
    const params = [_]builder_mod.Param{
        builder_mod.dynamicBuffer(.i32),
        builder_mod.dynamicBuffer(.i32),
    };

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_simdgroup_i32",
        &params,
    );
    errdefer builder.deinit();
    const out = builder.argument(0);
    const input = builder.argument(1);
    const lane = try builder.laneId();
    const value = try builder.load(input, lane);
    const scanned = try builder.warpScan(.add, .exclusive, value);
    try builder.store(scanned, out, lane);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(
        testing.allocator,
        "accy_choir_test_simdgroup_i32",
        program.kernelModule(),
    );
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "const int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "simd_prefix_exclusive_sum") != null);
}

test "metal choir msl emitter derives grid dimensions and boolean not" {
    const testing = std.testing;
    const builder_mod = accy_root.kernel;

    var builder = try builder_mod.Builder.init(
        testing.allocator,
        builder_mod.Builder.Limits.testing,
        "accy_choir_test_grid",
        &.{},
    );
    errdefer builder.deinit();
    const grid = try builder.gridDim(.x);
    const group = try builder.blockDim(.x);
    _ = try builder.add(grid, group);
    const flag = try builder.constantBool(true);
    _ = try builder.not(flag);
    try builder.return_();

    var program = try builder.finish();
    defer program.deinit();
    const text = try emitMsl(testing.allocator, "accy_choir_test_grid", program.kernelModule());
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "threads_per_grid") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/ choir_threads_per_threadgroup.x") != null);
    try testing.expect(std.mem.indexOf(u8, text, " = !") != null);
}
