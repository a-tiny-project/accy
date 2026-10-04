const std = @import("std");
const fixture = @import("../fixture/root.zig");
const nvptx = @import("root.zig");

const expectAbsent = fixture.expectAbsent;
const expectContains = fixture.expectContains;

test "nvptx declaration coverage" {
    std.testing.refAllDecls(nvptx.dialect);
    std.testing.refAllDecls(nvptx.conversion);
    std.testing.refAllDecls(nvptx.ptx);
    std.testing.refAllDecls(nvptx);
}

fn emit(source: []const u8, entry_name: []const u8) ![]u8 {
    return fixture.emitText(source, entry_name, .nvptx, nvptx.ptx.emitPtx);
}

test "ptx emitter lowers a parsed elementwise kernel through the nvptx pipeline" {
    const text = try emit(@embedFile("fixture/elementwise.txt"), "test_elementwise");
    defer std.testing.allocator.free(text);
    try expectContains(text, ".visible .entry test_elementwise");
    try expectContains(text, "ld.global.f32");
    try expectContains(text, "add.f32");
    try expectContains(text, "st.global.f32");
    try std.testing.expect(std.mem.endsWith(u8, text, "}\n"));
    try std.testing.expectEqual(std.mem.count(u8, text, "{"), std.mem.count(u8, text, "}"));
}

test "ptx emitter places parsed dynamic shared allocations at their byte offsets" {
    const text = try emit(@embedFile("fixture/dynamic.txt"), "test_dynamic");
    defer std.testing.allocator.free(text);
    try expectContains(text, ".extern .shared .align 16 .b8 __choir_dynamic_shared[]");
    try expectAbsent(text, ".shared .align 16 .b8 __choir_shared");
    try expectContains(text, "+64]");
    try expectContains(text, "st.shared.f32");
    try expectContains(text, "ld.shared.f32");
}

test "ptx emitter lowers parsed warp control intrinsics" {
    const text = try emit(@embedFile("fixture/warp.txt"), "test_warp");
    defer std.testing.allocator.free(text);
    try expectContains(text, ".version 6.2");
    try expectContains(text, "%laneid");
    try expectAbsent(text, "%warpid");
    try expectContains(text, "%tid.z");
    try expectContains(text, "activemask.b32");
    try expectContains(text, "vote.sync.all.pred");
    try expectContains(text, "vote.sync.any.pred");
    try expectContains(text, "vote.sync.ballot.b32");
    try expectContains(text, "shfl.sync.bfly.b32");
    try expectContains(text, "shfl.sync.down.b32");
    try expectContains(text, "bar.warp.sync");
    try expectContains(text, "bar.sync");
}

test "ptx emitter compares floats for != unordered and integers exactly" {
    const text = try emit(@embedFile("fixture/compare.txt"), "test_compare");
    defer std.testing.allocator.free(text);
    try expectContains(text, "setp.neu.f32");
    try expectContains(text, "setp.neu.f64");
    try expectAbsent(text, "setp.ne.f32");
    try expectAbsent(text, "setp.ne.f64");
    try expectContains(text, "setp.ne.s32");
}

test "ptx emitter lowers parsed global atomics" {
    const text = try emit(@embedFile("fixture/atomics.txt"), "test_atomics");
    defer std.testing.allocator.free(text);
    try expectContains(text, "red.global.add.f32");
    try expectAbsent(text, "atom.global.add.f32");
    try expectContains(text, "atom.global.add.u32");
    try expectContains(text, "atom.global.min.s32");
    try expectContains(text, "atom.global.max.s32");
    try expectContains(text, "atom.global.and.b32");
    try expectContains(text, "atom.global.or.b32");
    try expectContains(text, "atom.global.xor.b32");
    try expectContains(text, "atom.global.cas.b32");
    try expectContains(text, "atom.global.exch.b32");
    try expectContains(text, "red.global.or.b32");
    try expectAbsent(text, "red.global.exch");
}
