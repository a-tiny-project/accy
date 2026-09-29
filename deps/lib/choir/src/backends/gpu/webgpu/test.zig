const std = @import("std");
const fixture = @import("../fixture/root.zig");
const webgpu = @import("root.zig");

const expectContains = fixture.expectContains;

test "webgpu declaration coverage" {
    std.testing.refAllDecls(webgpu.wgsl);
    std.testing.refAllDecls(webgpu);
}

fn emit(source: []const u8, entry_name: []const u8) ![]u8 {
    return fixture.emitText(source, entry_name, null, webgpu.wgsl.emitWgsl);
}

test "wgsl emitter lowers a parsed elementwise kernel" {
    const text = try emit(@embedFile("fixture/elementwise.txt"), "test_elementwise");
    defer std.testing.allocator.free(text);
    try expectContains(text, "@compute @workgroup_size");
    try expectContains(text, "fn test_elementwise");
    try expectContains(text, "@group(0) @binding(0) var<storage, read_write> arg0: array<f32>;");
    try expectContains(text, "@group(0) @binding(1) var<storage, read> arg1: array<f32>;");
    try expectContains(text, "@group(0) @binding(3) var<storage, read> arg3: array<i32>;");
    try expectContains(text, "@builtin(global_invocation_id)");
    try expectContains(text, "floor(");
    try expectContains(text, "trunc(");
    try expectContains(text, "atan2(");
}

test "wgsl emitter lowers parsed workgroup memory and barriers" {
    const text = try emit(@embedFile("fixture/shared.txt"), "test_shared");
    defer std.testing.allocator.free(text);
    try expectContains(text, "var<workgroup> shared0: array<f32, 16>;");
    try expectContains(text, "workgroupBarrier();");
}

test "wgsl emitter lowers parsed value producing if arms" {
    const text = try emit(@embedFile("fixture/branch.txt"), "test_branch");
    defer std.testing.allocator.free(text);
    try expectContains(text, "var l0: f32;");
    try expectContains(text, "} else {");
}

test "wgsl emitter lowers a parsed unsigned high multiply" {
    const text = try emit(@embedFile("fixture/mulhi.txt"), "test_mulhi");
    defer std.testing.allocator.free(text);
    try expectContains(text, "fn choir_umulhi_u32");
    try expectContains(text, "bitcast<i32>(choir_umulhi_u32");
    try expectContains(text, "fn test_mulhi");
}

test "wgsl emitter rejects a parsed barrier inside a while loop" {
    try std.testing.expectError(
        error.UnsupportedOperation,
        emit(@embedFile("fixture/barrier.txt"), "test_barrier"),
    );
}

test "wgsl emitter rejects parsed warp collectives" {
    try std.testing.expectError(
        error.UnsupportedOperation,
        emit(@embedFile("fixture/warp.txt"), "test_warp"),
    );
}
