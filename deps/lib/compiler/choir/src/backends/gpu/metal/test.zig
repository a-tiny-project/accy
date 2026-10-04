const std = @import("std");
const fixture = @import("../fixture/root.zig");
const metal = @import("root.zig");

const expectContains = fixture.expectContains;

test "metal declaration coverage" {
    std.testing.refAllDecls(metal.msl);
    std.testing.refAllDecls(metal);
}

fn emit(source: []const u8, entry_name: []const u8) ![]u8 {
    return fixture.emitText(source, entry_name, null, metal.msl.emitMsl);
}

test "msl emitter lowers a parsed elementwise kernel" {
    const text = try emit(@embedFile("fixture/elementwise.txt"), "test_elementwise");
    defer std.testing.allocator.free(text);
    try expectContains(text, "kernel void test_elementwise");
    try expectContains(text, "device float* arg0 [[buffer(0)]]");
    try expectContains(text, "thread_position_in_grid");
    try expectContains(text, "if (");
    try expectContains(text, "floor(");
    try expectContains(text, "0x80000000u");
    try expectContains(text, "trunc(");
    try expectContains(text, "atan2(");
    try expectContains(text, "arg0[");
}

test "msl emitter lowers a parsed while loop with carried exits" {
    const text = try emit(@embedFile("fixture/loop.txt"), "test_loop");
    defer std.testing.allocator.free(text);
    try expectContains(text, "while (true) {");
    try expectContains(text, "if (!(");
    try expectContains(text, "break;");
    try std.testing.expect(std.mem.count(u8, text, "int l") >= 4);
}

test "msl emitter lowers parsed shared memory barriers and atomics" {
    const text = try emit(@embedFile("fixture/shared.txt"), "test_shared");
    defer std.testing.allocator.free(text);
    try expectContains(text, "threadgroup int shared");
    try expectContains(text, "threadgroup_barrier(mem_flags::mem_threadgroup)");
    try expectContains(text, "threadgroup atomic_int*");
}

test "msl emitter lowers parsed device compare and swap" {
    const text = try emit(@embedFile("fixture/exchange.txt"), "test_exchange");
    defer std.testing.allocator.free(text);
    try expectContains(text, "atomic_compare_exchange_weak_explicit");
    try expectContains(text, "device atomic_int*");
    try expectContains(text, "do {");
    try expectContains(text, "while (!");
}

test "msl emitter lowers parsed simdgroup ids scan and reduce" {
    const text = try emit(@embedFile("fixture/simdgroup.txt"), "test_simdgroup");
    defer std.testing.allocator.free(text);
    try expectContains(text, "thread_index_in_simdgroup");
    try expectContains(text, "simdgroup_index_in_threadgroup");
    try expectContains(text, "simd_prefix_inclusive_sum");
    try expectContains(text, "simd_sum");
}

test "msl emitter writes a signed remainder without the operator MSL leaves undefined" {
    const text = try emit(fixture.remainder, "test_remainder");
    defer std.testing.allocator.free(text);
    try expectContains(text, "const int v3 = v1 - (v1 / v2) * v2;");
    try expectContains(text, "const uint v6 = v4 % v5;");
    try expectContains(text, "as_type<int>(as_type<uint>(v0) % as_type<uint>(v7))");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, " % "));
}

test "msl emitter rejects a parsed shared f32 atomic add" {
    try std.testing.expectError(
        error.UnsupportedOperation,
        emit(@embedFile("fixture/rejection.txt"), "test_rejection"),
    );
}

const choir = @import("../../../root.zig");
const registration = @import("../registration.zig");
const stages = fixture.stages;

fn emitStages(source: []const u8, case: stages.Case) ![]u8 {
    const allocator = std.testing.allocator;
    var ctx = try choir.ir.Context.init(allocator, choir.ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try registration.prepareCompilationDialects(&ctx);
    const module = try fixture.lower(&ctx, source, null);
    defer module.erase();
    return stages.emitMsl(allocator, module, case);
}

/// `case`'s source with its one `needle` replaced. The caller owns it.
fn variant(case: stages.Case, needle: []const u8, replacement: []const u8) ![]u8 {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, case.source, needle));
    return std.mem.replaceOwned(u8, std.testing.allocator, case.source, needle, replacement);
}

test "msl emitter writes each stage module as its golden vertex and fragment source" {
    const goldens = [_][]const u8{
        @embedFile("fixture/textured.metal"),
        @embedFile("fixture/indexed.metal"),
        @embedFile("fixture/pushed.metal"),
    };
    for (stages.cases, goldens) |case, golden| {
        const text = try emitStages(case.source, case);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(golden, text);
    }
}

test "msl stage emission keeps static local arrays in thread address space" {
    const local = stages.alloca_case;
    const text = try emitStages(local.source, local);
    defer std.testing.allocator.free(text);
    try expectContains(text, "thread float v");
    try expectContains(text, "thread bool v");
    try expectContains(text, "[4];");
    try expectContains(text, "[1];");
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, text, "threadgroup float"));
}

test "msl stage emission refuses dynamic local arrays" {
    const local = stages.alloca_case;
    const source = try variant(
        local,
        "%16 = memref.alloca() : !memref<4,arith.f32,local>",
        "%16 = memref.alloca(%12) : !memref<?,arith.f32,local>",
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectError(error.UnsupportedStageMemory, emitStages(source, local));
}

test "msl stage calls define helpers once and refuse recursion" {
    const calls = stages.calls_case;
    const text = try emitStages(calls.source, calls);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "float invert("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "float nested_invert("));
    try expectContains(text, "= invert(");
    try expectContains(text, "= nested_invert(");
    try expectContains(text, "thread float v");
    const recursive = try variant(calls, "%9 = func.call(%8) {callee = @invert}", "%9 = func.call(%8) {callee = @nested_invert}");
    defer std.testing.allocator.free(recursive);
    try std.testing.expectError(error.UnsupportedOperation, emitStages(recursive, calls));
}

test "msl stage emission rejects ops outside their stage and texture groups past zero" {
    const indexed = stages.cases[1];
    const textured = stages.cases[0];
    const implicit_in_vertex = try variant(
        indexed,
        "gpu.sample_lod(%4, %2, %3, %5)",
        "gpu.sample(%4, %2, %3)",
    );
    defer std.testing.allocator.free(implicit_in_vertex);
    const implicit_result = emitStages(implicit_in_vertex, indexed);
    try std.testing.expectError(error.UnsupportedOperation, implicit_result);
    const second_group = try variant(
        textured,
        "{binding = 0:i64, group = 0:i64}",
        "{binding = 0:i64, group = 1:i64}",
    );
    defer std.testing.allocator.free(second_group);
    try std.testing.expectError(error.CapabilityMismatch, emitStages(second_group, textured));
    const split_slot = try variant(
        textured,
        "%12, %13, %14, %15 = gpu.stage_input() {location = 1:i64}",
        "%12, %13, %14, %15 = gpu.stage_input() {location = 0:i64}",
    );
    defer std.testing.allocator.free(split_slot);
    try std.testing.expectError(error.InvalidArtifact, emitStages(split_slot, textured));
}

test "msl block reads refuse uniforms past group zero or binding seven" {
    const pushed = stages.cases[2];
    const needle = "{binding = 1:i64, group = 0:i64, offset = 12:i64}";
    const refusals = [_][]const u8{
        "{binding = 1:i64, group = 1:i64, offset = 12:i64}",
        "{binding = 8:i64, group = 0:i64, offset = 12:i64}",
        "{binding = 1:i64, group = 0:i64, offset = 16384:i64}",
    };
    for (refusals) |replacement| {
        const source = try variant(pushed, needle, replacement);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.CapabilityMismatch, emitStages(source, pushed));
    }
}

test "msl kernel emission rejects stage ops" {
    const textured = stages.cases[0];
    const kernel = try variant(
        textured,
        "stage = #attr<gpu.stage>(\"vertex\")",
        "kernel = #attr<func.kernel>",
    );
    defer std.testing.allocator.free(kernel);
    try std.testing.expectError(error.UnsupportedOperation, emit(kernel, textured.vertex));
}
