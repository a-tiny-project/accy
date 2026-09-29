const std = @import("std");

pub const maximum_inputs: usize = 32;
pub const maximum_name_bytes: usize = 128;

pub fn main(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer arguments.deinit();
    std.debug.assert(arguments.skip());
    const output_path = arguments.next() orelse return error.MissingOutputPath;
    std.debug.assert(std.fs.path.isAbsolute(output_path));
    const output = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer output.close(init.io);
    var buffer: [4096]u8 = undefined;
    var writer = output.writer(init.io, &buffer);
    for (0..maximum_inputs) |_| {
        const name = arguments.next() orelse break;
        if (name.len == 0 or name.len > maximum_name_bytes) return error.InvalidOptionName;
        const directory = arguments.next() orelse return error.MissingDirectory;
        if (!std.fs.path.isAbsolute(directory)) return error.RelativeDirectory;
        if (directory.len > std.fs.max_path_bytes) return error.DirectoryPathTooLong;
        try writer.interface.print("pub const {f}: []const u8 = \"{f}\";\n", .{
            std.zig.fmtId(name), std.zig.fmtString(directory),
        });
    }
    if (arguments.next() != null) return error.TooManyDirectories;
    try writer.interface.flush();
}
