const std = @import("std");
const wasm = @import("root.zig");
const binary = @import("binary/test.zig");
const emission = @import("emission/test.zig");

test {
    std.testing.refAllDecls(wasm);
    _ = binary;
    _ = emission;
}
