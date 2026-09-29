const std = @import("std");
const shared = @import("shared");
const alias = @import("alias");
const expected = @import("expected");

pub fn main(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer arguments.deinit();
    std.debug.assert(arguments.skip());
    const output = arguments.next() orelse return error.MissingIdentityOutput;
    std.debug.assert(arguments.next() == null);
    std.debug.assert(shared.Identity == alias.Identity);
    const compiler = shared.compiler;
    std.debug.assert(compiler.qualified == expected.qualified);
    if (compiler.qualified) {
        std.debug.assert(std.mem.startsWith(u8, compiler.bytes, "tiny.compiled-inputs/v1"));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(compiler.bytes, &digest, .{});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = &digest });
    } else {
        std.debug.assert(compiler.bytes.len == 0);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = "" });
    }
}
