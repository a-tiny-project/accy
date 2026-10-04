const std = @import("std");
const stack = @import("root.zig");

const prologue = [_]u8{ 0x55, 0x48, 0x89, 0xe5 };
const epilogue = [_]u8{ 0x5d, 0xc3 };

test "x64 stack convention accounts for return address saves and reserved bytes" {
    var workspace: [32]u8 = undefined;
    const empty = prologue ++ epilogue;
    const leaf = try stack.check(&empty, &workspace);
    try std.testing.expectEqual(@as(u32, 16), leaf.bytes);
    try std.testing.expectEqual(@as(u32, 4), leaf.instructions);
    const saved = prologue ++ [_]u8{
        0x53, 0x41, 0x54,
        0x48, 0x83, 0xec,
        0x20, 0x48, 0x89,
        0xf8, 0x48, 0x83,
        0xc4, 0x20, 0x41,
        0x5c, 0x5b,
    } ++ epilogue;
    const bound = try stack.check(&saved, &workspace);
    try std.testing.expectEqual(@as(u32, 64), bound.bytes);
    try std.testing.expectEqual(@as(u32, 11), bound.instructions);
}

test "x64 stack convention admits bounded reservation through signed loop branches" {
    const code = prologue ++ [_]u8{
        0x48, 0x83, 0xec, 0x10,
        0x48, 0x83, 0xf8, 0x00,
        0x0f, 0x8d, 0xf6, 0xff,
        0xff, 0xff, 0x48, 0x83,
        0xc4, 0x10,
    } ++ epilogue;
    var workspace: [4]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 32), (try stack.check(&code, &workspace)).bytes);
    try std.testing.expectError(error.StackWorkspaceExceeded, stack.check(&code, workspace[0..2]));
    try std.testing.expectEqual(@as(usize, 3), try stack.workspaceBytes(code.len));
}

test "x64 stack convention rejects branches into setup and partial restoration" {
    const setup = prologue ++ [_]u8{ 0xe9, 0xf7, 0xff, 0xff, 0xff } ++ epilogue;
    const partial = prologue ++ [_]u8{ 0xeb, 0x01 } ++ epilogue;
    const middle = prologue ++ [_]u8{ 0xeb, 0x01, 0x48, 0x89, 0xf8 } ++ epilogue;
    const outside = prologue ++ [_]u8{ 0xeb, 0x7f } ++ epilogue;
    var workspace: [8]u8 = undefined;
    for ([_][]const u8{ &setup, &partial, &middle, &outside }) |code| {
        try std.testing.expectError(error.InvalidStackBranch, stack.check(code, &workspace));
    }
}

test "x64 stack convention rejects hidden stack writes and unknown calls" {
    const bodies = [_][]const u8{
        &.{0x50},
        &.{ 0x48, 0x83, 0xec, 0xf8 },
        &.{ 0x40, 0xb4, 0x00 },
        &.{ 0x48, 0x89, 0xc5 },
        &.{ 0xff, 0xd0 },
        &.{ 0xe8, 0x00, 0x00, 0x00, 0x00 },
        &.{ 0x48, 0x83, 0xc4, 0x08 },
    };
    var storage: [32]u8 = undefined;
    var workspace: [4]u8 = undefined;
    for (bodies) |body| {
        @memcpy(storage[0..prologue.len], &prologue);
        storage[prologue.len] = 0x90;
        const start = prologue.len + 1;
        @memcpy(storage[start..][0..body.len], body);
        @memcpy(storage[start + body.len ..][0..epilogue.len], &epilogue);
        try std.testing.expectError(
            error.UnsupportedStackInstruction,
            stack.check(storage[0 .. start + body.len + epilogue.len], &workspace),
        );
    }
}

test "x64 stack convention checks frame widths restore sizes and terminal flow" {
    const wrong = prologue ++ [_]u8{
        0x48, 0x83, 0xec, 0x10, 0x48, 0x83, 0xc4, 0x08,
    } ++ epilogue;
    const partial = prologue ++ [_]u8{ 0x66, 0x5d, 0xc3 };
    const missing = prologue ++ [_]u8{0x90};
    var workspace: [8]u8 = undefined;
    try std.testing.expectError(error.UnsupportedStackInstruction, stack.check(&wrong, &workspace));
    try std.testing.expectError(
        error.UnsupportedStackInstruction,
        stack.check(&partial, &workspace),
    );
    try std.testing.expectError(error.StackFallthrough, stack.check(&missing, &workspace));
    try std.testing.expectError(error.StackWorkspaceExceeded, stack.check(&.{}, &workspace));
}
