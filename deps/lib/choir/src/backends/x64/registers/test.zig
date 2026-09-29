const std = @import("std");
const registers = @import("root.zig");
const GPR = registers.GPR;
const XMM = registers.XMM;

test "GPR encoding" {
    const testing = std.testing;
    try testing.expectEqual(@as(u4, 0), GPR.rax.encode().toInt());
    try testing.expectEqual(@as(u4, 15), GPR.r15.encode().toInt());
    try testing.expectEqual(@as(u3, 0), GPR.r8.low3());
    try testing.expect(GPR.r8.rexBit());
}

test "GPR classification" {
    const testing = std.testing;
    try testing.expect(GPR.rax.isCallerSaved());
    try testing.expect(!GPR.rax.isCalleeSaved());
    try testing.expect(GPR.arg0.isArgument());

    try testing.expect(GPR.r12.isCalleeSaved());
    try testing.expect(!GPR.r12.isCallerSaved());
    try testing.expect(!GPR.r12.isArgument());
}

test "XMM encoding" {
    const testing = std.testing;
    try testing.expectEqual(@as(u4, 0), XMM.xmm0.encode().toInt());
    try testing.expectEqual(@as(u4, 15), XMM.xmm15.encode().toInt());
    try testing.expectEqual(@as(u3, 0), XMM.xmm8.low3());
    try testing.expect(XMM.xmm8.rexBit());
}

test "XMM classification" {
    const testing = std.testing;
    try testing.expect(XMM.xmm0.isCallerSaved());
    try testing.expect(!XMM.xmm0.isCalleeSaved());
    try testing.expect(XMM.xmm0.isArgument());
    try testing.expect(!XMM.xmm8.isArgument());
}
