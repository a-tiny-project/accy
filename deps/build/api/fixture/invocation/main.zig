const std = @import("std");
const compiler = @import("__tiny_compiled_inputs_v1");
const expected = @import("expected");

pub fn main() void {
    std.debug.assert(compiler.qualified == expected.qualified);
    if (compiler.qualified) {
        std.debug.assert(std.mem.startsWith(u8, compiler.bytes, "tiny.compiled-inputs/v1"));
        std.debug.assert(compiler.bytes.len > 32);
    } else {
        std.debug.assert(compiler.bytes.len == 0);
    }
}
