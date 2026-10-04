const std = @import("std");
const options = @import("directory_options");

test "directory options preserve source and generated directory identities" {
    const roots = [_][]const u8{ options.source, options.@"generated directory" };
    const contents = [_][]const u8{ "source directory\n", "generated directory\n" };
    for (roots, contents) |path, expected| {
        try std.testing.expect(std.fs.path.isAbsolute(path));
        var directory = try std.Io.Dir.openDirAbsolute(std.testing.io, path, .{});
        defer directory.close(std.testing.io);
        var buffer: [64]u8 = undefined;
        const actual = try directory.readFile(std.testing.io, "value.txt", &buffer);
        try std.testing.expectEqualStrings(expected, actual);
    }
}
